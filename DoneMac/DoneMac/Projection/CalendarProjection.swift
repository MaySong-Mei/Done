//
//  CalendarProjection.swift
//  DoneMac
//
//  The derived layer (#219 concept 2): day models are pure functions of
//  (events, dayKey) with `now` deliberately absent — the now-line is a
//  separate overlay keyed on the minute bucket, so a clock tick re-derives
//  one small struct, never a day. `timerStartedAt` is neutralized before
//  layout because the shared occurrencesForDate would bake a Date() read
//  into the cached model (round-2 review #8); Mac renders stored ranges
//  until a live-timer surface exists. Cache invalidation is delta-driven:
//  a commit drops exactly its affectedDayKeys (or everything on a bulk
//  delta); untouched days stay cached across generations.
//
//  Geometry is FRACTIONS of the 24h day window (the shared
//  calendarTimelineYFraction contract with zero extension hours), so
//  window resize and zoom re-position blocks without touching this layer.
//

import SwiftUI

struct DayBlockModel: Equatable, Identifiable {
    let id: String
    let eventID: UUID
    /// The occurrence range this block renders — the drag anchor (round-3
    /// review F1: gestures must anchor on the GRABBED range, never
    /// seeds.first).
    let range: Event.TimeRange
    let title: String
    /// "start - end" in both of the phone's clock styles; the canvas picks
    /// one from the synced 12h/24h setting at draw time, so flipping it
    /// needs no projection rebuild.
    let timeText24: String
    let timeText12: String
    let yFraction: CGFloat
    let heightFraction: CGFloat
    let xOffsetFraction: CGFloat
    let widthFraction: CGFloat
    let zIndex: Double
    let isTodo: Bool
    /// A completed todo, so the canvas can fade it — the phone's deferred
    /// done-fade. now-free: completion is a stored fact, not a clock read.
    let isDone: Bool
    /// Whether this block's top / bottom is the occurrence's REAL start / end
    /// rather than a midnight CLIP line. A resize handle is offered only at a
    /// real edge, so dragging a cross-midnight event's clipped edge can't
    /// silently collapse its head/tail (B2 review F1 — fixes both edges).
    let topIsRealStart: Bool
    let bottomIsRealEnd: Bool
    let color: Color
    /// The iPhone block's other inputs (CalendarDayLayerView): the effort bar
    /// width, the todo urgency border, the interrupt's tighter corners.
    let colorDepth: Double
    let deadline: Date?
    let isInterrupt: Bool
    /// A running timer — the phone's diagonal hatch.
    let isTimerActive: Bool
    /// The agentic intake phase: analyzing paints the block in the now-line
    /// color; queued/analyzing adds the shimmer and spinner; failed prefixes
    /// the title with "⚠️".
    let agenticPhase: AgenticIntakeProcessingPhase?
    /// Extra types beyond the primary — the multi-type corner triangle — and
    /// "A · B" for the subtitle ("" under two types). Both gated at draw time
    /// by the experimental multi-type setting, as on the phone.
    let hasAdditionalTypes: Bool
    let typeSubtitle: String
    /// An embedded interrupt child: drawn on its parent's column (the slot
    /// fractions above are the PARENT's), inset by the phone's child-overlay
    /// geometry, one z above the parent.
    let isEmbeddedInterruptChild: Bool
    /// An interrupt parent's embedded children's ranges (clipped to the day
    /// window only, as on the phone) and its own range clipped to this day:
    /// the canvas cuts a moat around each child at draw time, in points.
    /// Empty / nil for every other block.
    let interruptChildRanges: [Event.TimeRange]
    let compoundParentRange: Event.TimeRange?

    func timeText(is24: Bool) -> String { is24 ? timeText24 : timeText12 }
}

struct AllDayChipModel: Equatable, Identifiable {
    let id: String
    let title: String
    let color: Color
}

struct DayModel: Equatable {
    let key: DayKey
    let blocks: [DayBlockModel]
    let allDayChips: [AllDayChipModel]
}

struct NowLineModel: Equatable {
    let dayKey: DayKey
    let yFraction: CGFloat
}

struct CanvasFrame: Equatable {
    var days: [DayModel] = []
    var nowLine: NowLineModel?
}

@MainActor
final class CalendarProjection {
    private let calendar: Calendar
    private let bill: MacWorkBill
    private var index: OccurrenceIndex
    private var cache: [DayKey: DayModel] = [:]
    private let timeFormatter24: DateFormatter
    private let timeFormatter12: DateFormatter

    init(calendar: Calendar, bill: MacWorkBill) {
        self.calendar = calendar
        self.bill = bill
        self.index = OccurrenceIndex(calendar: calendar)
        // Built once, not per pass — the gh#219 render-read lesson.
        // The phone's two block formats (CalendarDayLayerView.timeFormatter).
        let formatter24 = DateFormatter()
        formatter24.calendar = calendar
        formatter24.timeZone = calendar.timeZone
        formatter24.dateFormat = "H:mm"
        self.timeFormatter24 = formatter24
        let formatter12 = DateFormatter()
        formatter12.calendar = calendar
        formatter12.timeZone = calendar.timeZone
        formatter12.locale = Locale(identifier: "en_US_POSIX")
        formatter12.dateFormat = "h:mm a"
        formatter12.amSymbol = "am"
        formatter12.pmSymbol = "pm"
        self.timeFormatter12 = formatter12
    }

    // MARK: - Truth intake

    func rebuildIndex(from events: [Event]) {
        index = OccurrenceIndex.built(from: events, calendar: calendar)
        cache.removeAll()
    }

    /// Drop the day-model cache WITHOUT rebuilding the occurrence index: a
    /// type recolor/rename changes the color baked into each DayModel but not
    /// which occurrences fall on which day, so the index stands and only the
    /// cached (color-carrying) models must be rebuilt (A2 review #1 — the
    /// catalog is an input to the projection's output, so a catalog change
    /// must invalidate it, like a bulk delta).
    /// The phone's multiTypeSubtitleText: every effective type, " · "-joined,
    /// only when there are at least two.
    nonisolated static func typeSubtitle(for event: Event) -> String {
        let types = event.effectiveTypes.filter { !$0.isEmpty }
        return types.count >= 2 ? types.joined(separator: " · ") : ""
    }

    func invalidateColors() {
        cache.removeAll()
    }

    func apply(_ delta: CommitDelta, events: [Event]) {
        guard delta.slot == .calendarEvents else { return }
        guard let affected = delta.affectedDayKeys else {
            rebuildIndex(from: events)
            return
        }
        index.apply(changedIDs: delta.changedIDs, events: events)
        for key in affected {
            cache.removeValue(forKey: key)
        }
        #if DEBUG
        // Shadow-compare, both halves (plan risk #6; round-2 review #3):
        // the incremental INDEX must equal a full rebuild, and every
        // still-cached DAY MODEL must equal a fresh build — a delta that
        // underclaims its days leaves the index right and the cache wrong,
        // which the index check alone cannot see. DEBUG-only cost; release
        // has no shadow (the test gate is the defense there).
        let rebuilt = OccurrenceIndex.built(from: events, calendar: calendar)
        if !index.matches(rebuilt) {
            bill.bump(.indexShadowMismatches)
            index = rebuilt
            cache.removeAll()
            return
        }
        let cachedKeys = Array(cache.keys)
        if !cachedKeys.isEmpty {
            var byID: [UUID: Event] = [:]
            let wanted = cachedKeys.reduce(into: Set<UUID>()) { acc, key in
                acc.formUnion(index.candidates(for: key))
            }
            for event in events where wanted.contains(event.id) {
                byID[event.id] = event
            }
            for key in cachedKeys {
                if cache[key] != build(key: key, byID: byID) {
                    bill.bump(.indexShadowMismatches)
                    cache.removeValue(forKey: key)
                }
            }
        }
        #endif
    }

    // MARK: - Day models (L1+L2, now-free)

    /// One truth scan builds every missing day in the batch; cached days
    /// cost a dictionary hit.
    func dayModels(for keys: [DayKey], events: [Event]) -> [DayModel] {
        var missing: [DayKey] = []
        for key in keys where cache[key] == nil {
            missing.append(key)
        }
        if !missing.isEmpty {
            var byID: [UUID: Event] = [:]
            let wanted = missing.reduce(into: Set<UUID>()) { acc, key in
                acc.formUnion(index.candidates(for: key))
            }
            for event in events where wanted.contains(event.id) {
                byID[event.id] = event
            }
            for key in missing {
                bill.bump(.dayModelBuilds)
                cache[key] = build(key: key, byID: byID)
            }
        }
        return keys.compactMap { key in
            if let model = cache[key] {
                bill.bump(.dayModelHits)
                return model
            }
            return nil
        }
    }

    private func build(key: DayKey, byID: [UUID: Event]) -> DayModel {
        guard let dayStart = key.startOfDay(calendar: calendar) else {
            return DayModel(key: key, blocks: [], allDayChips: [])
        }
        // Sorted for deterministic block order (Set iteration is hash-order
        // — review #12); timerStartedAt neutralized (header note).
        // The hatch still needs to know a timer runs, so that is read first.
        var timerActiveIDs = Set<UUID>()
        let candidates = index.candidates(for: key)
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { id -> Event? in
                guard var event = byID[id] else { return nil }
                if event.timerStartedAt != nil { timerActiveIDs.insert(id) }
                event.timerStartedAt = nil
                return event
            }
        let occurrences = CalendarLayout.occurrencesForDate(candidates, date: dayStart, calendar: calendar)
        // .equalSplit per the shared OverlapMode contract: renderers that
        // consume only x/width (no coverRanges text-fitting) must not take
        // the stack-peek host layout (review #11 / QA3 F5).
        let slots = CalendarLayout.overlapLayout(
            for: occurrences, on: dayStart, calendar: calendar, mode: .equalSplit
        )
        let effortOpacity = Event.effortOpacityEnabledFromDefaults
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)

        let family = InterruptFamily(occurrences: occurrences)

        let blocks = occurrences.map { occurrence -> DayBlockModel in
            let parent = family.embeddedParent(of: occurrence)
            let ownSlot = slots[occurrence.id] ?? .default
            // An embedded child takes its parent's column (phone:
            // parentSlotContext) and paints just above it.
            let slot = parent.flatMap { slots[$0.id] } ?? ownSlot
            let zIndex = parent.flatMap { slots[$0.id] }.map { $0.zIndex + 1 } ?? ownSlot.zIndex
            let childRanges = family.childRanges(of: occurrence, dayStart: dayStart, dayEnd: dayEnd)
            let clippedStart = max(occurrence.range.start, dayStart)
            let y = calendarTimelineYFraction(for: clippedStart, containing: dayStart, calendar: calendar)
            let height = calendarTimelineDurationFraction(
                seconds: Self.clippedDuration(for: occurrence, on: dayStart, calendar: calendar)
            )
            return DayBlockModel(
                id: occurrence.id,
                eventID: occurrence.event.id,
                range: occurrence.range,
                title: occurrence.event.title,
                // "start - end", as the phone's block prints it.
                timeText24: "\(timeFormatter24.string(from: occurrence.range.start)) - \(timeFormatter24.string(from: occurrence.range.end))",
                timeText12: "\(timeFormatter12.string(from: occurrence.range.start)) - \(timeFormatter12.string(from: occurrence.range.end))",
                yFraction: y,
                heightFraction: height,
                xOffsetFraction: slot.xOffsetFraction,
                widthFraction: slot.widthFraction,
                zIndex: zIndex,
                isTodo: occurrence.event.kind == .todo,
                isDone: occurrence.event.isDone,
                topIsRealStart: occurrence.range.start >= dayStart,
                bottomIsRealEnd: occurrence.range.end <= dayEnd,
                color: CalendarLayout.eventColor(for: occurrence.event, effortOpacityEnabled: effortOpacity),
                colorDepth: occurrence.event.colorDepth,
                deadline: occurrence.event.deadline,
                isInterrupt: occurrence.event.isInterrupt,
                isTimerActive: timerActiveIDs.contains(occurrence.event.id),
                agenticPhase: occurrence.event.agenticIntake?.processingPhase,
                hasAdditionalTypes: occurrence.event.additionalTypes?.isEmpty == false,
                typeSubtitle: Self.typeSubtitle(for: occurrence.event),
                isEmbeddedInterruptChild: parent != nil,
                interruptChildRanges: childRanges,
                compoundParentRange: childRanges.isEmpty ? nil : Event.TimeRange(
                    start: max(occurrence.range.start, dayStart),
                    end: min(occurrence.range.end, dayEnd)
                )
            )
        }

        let allDay = CalendarLayout.allDayOccurrencesForDate(candidates, date: dayStart, calendar: calendar)
            .map { occurrence in
                AllDayChipModel(
                    id: occurrence.id,
                    title: occurrence.event.title,
                    color: CalendarLayout.eventColor(for: occurrence.event, effortOpacityEnabled: effortOpacity)
                )
            }

        return DayModel(key: key, blocks: blocks, allDayChips: allDay)
    }

    // MARK: - Now overlay (the ONLY consumer of now)

    func nowLine(now: Date) -> NowLineModel {
        let key = DayKey(date: now, calendar: calendar)
        let dayStart = key.startOfDay(calendar: calendar) ?? calendar.startOfDay(for: now)
        return NowLineModel(
            dayKey: key,
            yFraction: calendarTimelineYFraction(for: now, containing: dayStart, calendar: calendar)
        )
    }
}

extension CalendarProjection {
    /// Seconds of `occurrence` inside the civil day starting at `date`'s
    /// midnight, half-open [dayStart, next dayStart). Mac-local since king
    /// deleted the shared `CalendarLayout.clippedDuration` as dead on iOS
    /// (43712ca, gh#224 slice 2); this body is that function verbatim.
    static func clippedDuration(
        for occurrence: CalendarLayout.EventOccurrence,
        on date: Date,
        calendar: Calendar
    ) -> TimeInterval {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let start = max(occurrence.range.start, dayStart)
        let end = min(occurrence.range.end, dayEnd)
        return max(0, end.timeIntervalSince(start))
    }
}

/// The phone's InterruptContext (CalendarDayLayerView), over one day's
/// occurrences: parents by anchor id, embedded children by parent, and the
/// children that actually overlap a present parent.
struct InterruptFamily {
    private var parents: [UUID: CalendarLayout.EventOccurrence] = [:]
    private var children: [UUID: [CalendarLayout.EventOccurrence]] = [:]
    private var embeddedIDs = Set<String>()

    init(occurrences: [CalendarLayout.EventOccurrence]) {
        for occ in occurrences where !occ.event.isInterrupt {
            parents[Self.anchorID(for: occ.event)] = occ
        }
        for occ in occurrences {
            guard let rel = occ.event.interruptRelation, rel.state == .embedded else { continue }
            children[rel.parentEventID, default: []].append(occ)
        }
        for occ in occurrences {
            guard occ.event.isInterrupt,
                  let rel = occ.event.interruptRelation, rel.state == .embedded,
                  let parent = parents[rel.parentEventID] else { continue }
            if occ.range.end > parent.range.start && occ.range.start < parent.range.end {
                embeddedIDs.insert(occ.id)
            }
        }
    }

    static func anchorID(for event: Event) -> UUID {
        event.recurrenceParentId ?? event.id
    }

    /// The parent an embedded child is drawn on, nil for everything else.
    func embeddedParent(of occurrence: CalendarLayout.EventOccurrence) -> CalendarLayout.EventOccurrence? {
        guard embeddedIDs.contains(occurrence.id),
              let rel = occurrence.event.interruptRelation else { return nil }
        return parents[rel.parentEventID]
    }

    /// A parent's children's ranges, clipped only to the day window.
    func childRanges(of occurrence: CalendarLayout.EventOccurrence,
                     dayStart: Date, dayEnd: Date) -> [Event.TimeRange] {
        guard !occurrence.event.isInterrupt,
              let kids = children[Self.anchorID(for: occurrence.event)] else { return [] }
        return kids.compactMap { child in
            child.range.end > dayStart && child.range.start < dayEnd ? child.range : nil
        }
    }
}
