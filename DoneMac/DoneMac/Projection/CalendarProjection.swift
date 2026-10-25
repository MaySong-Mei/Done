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
    let timeText: String
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
    private let timeFormatter: DateFormatter

    init(calendar: Calendar, bill: MacWorkBill) {
        self.calendar = calendar
        self.bill = bill
        self.index = OccurrenceIndex(calendar: calendar)
        // Built once, not per pass — the gh#219 render-read lesson.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "H:mm"
        self.timeFormatter = formatter
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
        let candidates = index.candidates(for: key)
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { id -> Event? in
                guard var event = byID[id] else { return nil }
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

        let blocks = occurrences.map { occurrence -> DayBlockModel in
            let slot = slots[occurrence.id] ?? .default
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
                timeText: timeFormatter.string(from: occurrence.range.start),
                yFraction: y,
                heightFraction: height,
                xOffsetFraction: slot.xOffsetFraction,
                widthFraction: slot.widthFraction,
                zIndex: slot.zIndex,
                isTodo: occurrence.event.kind == .todo,
                isDone: occurrence.event.isDone,
                topIsRealStart: occurrence.range.start >= dayStart,
                bottomIsRealEnd: occurrence.range.end <= dayEnd,
                color: CalendarLayout.eventColor(for: occurrence.event, effortOpacityEnabled: effortOpacity)
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
