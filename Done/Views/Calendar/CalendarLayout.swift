//
//  CalendarLayout.swift
//  Done
//
//  Presentation-layer layout helpers for the calendar timeline.
//  Keeps date filtering and geometry calculations out of SwiftUI view bodies.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import Foundation
import SwiftUI

/// 功能： Provides layout helpers for calendar timelines (filtering, geometry, and styling).
enum CalendarLayout {
    /// 功能： Default day range (relative to today) for timeline pagination.
    static let defaultDayRange: ClosedRange<Int> = -30...30

    /// Minimum visible duration for an active-timer block.  Paired with the
    /// 30s `Timer.publish` cadence in `CalendarPageView.updateTimerRefresh`
    /// so that the block stays continuously visible between cache rebuilds
    /// — without this the block would be 0pt tall for the first 30 seconds
    /// after starting a timer (when `Date() == timerStartedAt`).
    static let timerMinimumVisibleDuration: TimeInterval = 30

    /// 功能： Describes a specific event time range to render on a given day.
    struct EventOccurrence: Identifiable, Equatable {
        let id: String
        let event: Event
        let range: Event.TimeRange
    }

    /// 功能： Checks if a recurring series event has an occurrence on the given date.
    /// Returns the time range for that occurrence if it matches, nil otherwise.
    static func recurrenceOccurrence(
        for event: Event,
        on date: Date,
        calendar: Calendar = .current
    ) -> Event.TimeRange? {
        guard event.isRecurringSeries,
              let seriesStart = event.primaryTimeRange?.start else { return nil }

        let targetDay = calendar.startOfDay(for: date)
        let seriesDay = calendar.startOfDay(for: seriesStart)

        // Exception suppression by nominal day-KEY identity (gh#127 item 1).
        // The old read — `calendar.isDate(storedDate, inSameDayAs: targetDay)`
        // — reinterpreted an absolute midnight minted under the CREATION-time
        // zone through the CURRENT calendar: after a system tz change the
        // instant re-buckets into an adjacent local day, the suppressed
        // occurrence reappears (a visible duplicate beside its detached
        // replacement) and the neighboring day goes dark (a hole). Day keys
        // are components-in-the-naming-calendar, so this comparison cannot
        // drift.
        if event.suppressesRecurrenceOccurrence(onDay: targetDay, calendar: calendar) {
            return nil
        }

        // Defense in depth: the repeat fields are `var`, so an in-memory event
        // can still carry a value-less / degenerate rule that decode-time repair
        // never saw (e.g. `.afterCount` with a nil count, or `interval <= 0`).
        // Repair it here against the SAME normalizer both ingress paths use, so
        // render can't interpret an invalid bounded rule as infinite or erase
        // the seed.
        let rule = Event.normalizedRecurrenceRule(
            interval: event.repeatInterval,
            endType: event.repeatEndType,
            endDate: event.repeatEndDate,
            endCount: event.repeatEndCount,
            seriesStart: seriesStart,
            calendar: calendar
        )

        // Check end conditions
        switch rule.endType {
        case .onDate:
            if let endDate = rule.endDate, targetDay > calendar.startOfDay(for: endDate) {
                return nil
            }
        case .afterCount:
            // Will be checked below after computing occurrence index
            break
        case .none:
            break
        }

        // Must be on or after series start
        guard targetDay >= seriesDay else { return nil }

        // Check if target date matches the recurrence pattern
        let matches: Bool
        let interval = rule.interval
        guard interval > 0 else { return nil }

        switch event.repeatUnit {
        case .none:
            return nil
        case .day:
            let daysBetween = calendar.dateComponents([.day], from: seriesDay, to: targetDay).day ?? 0
            matches = daysBetween >= 0 && daysBetween % interval == 0
            if matches, rule.endType == .afterCount, let count = rule.endCount {
                if Event.recurrenceOccurrenceIndex(seriesStart: seriesStart, day: targetDay, unit: .day, interval: interval, calendar: calendar, cappedAt: count) >= count { return nil }
            }
        case .week:
            let daysBetween = calendar.dateComponents([.day], from: seriesDay, to: targetDay).day ?? 0
            let weeksBetween = daysBetween / 7
            matches = daysBetween >= 0 && daysBetween % 7 == 0 && weeksBetween % interval == 0
            if matches, rule.endType == .afterCount, let count = rule.endCount {
                if Event.recurrenceOccurrenceIndex(seriesStart: seriesStart, day: targetDay, unit: .week, interval: interval, calendar: calendar, cappedAt: count) >= count { return nil }
            }
        case .month:
            let monthsBetween = (calendar.dateComponents([.month], from: seriesDay, to: targetDay).month ?? 0)
            let seriesDayOfMonth = calendar.component(.day, from: seriesDay)
            let targetDayOfMonth = calendar.component(.day, from: targetDay)
            matches = monthsBetween >= 0 && monthsBetween % interval == 0 && targetDayOfMonth == seriesDayOfMonth
            if matches, rule.endType == .afterCount, let count = rule.endCount {
                // Count REALIZED occurrences, not calendar months — a Jan-31
                // monthly series skips Feb/Apr/… so those steps must not consume
                // the afterCount budget.
                if Event.recurrenceOccurrenceIndex(seriesStart: seriesStart, day: targetDay, unit: .month, interval: interval, calendar: calendar, cappedAt: count) >= count { return nil }
            }
        case .year:
            let yearsBetween = calendar.dateComponents([.year], from: seriesDay, to: targetDay).year ?? 0
            let seriesMonth = calendar.component(.month, from: seriesDay)
            let seriesDayOfMonth = calendar.component(.day, from: seriesDay)
            let targetMonth = calendar.component(.month, from: targetDay)
            let targetDayOfMonth = calendar.component(.day, from: targetDay)
            matches = yearsBetween >= 0 && yearsBetween % interval == 0 && targetMonth == seriesMonth && targetDayOfMonth == seriesDayOfMonth
            if matches, rule.endType == .afterCount, let count = rule.endCount {
                // Realized occurrences only — a Feb-29 yearly series skips
                // non-leap years, which must not consume the afterCount budget.
                if Event.recurrenceOccurrenceIndex(seriesStart: seriesStart, day: targetDay, unit: .year, interval: interval, calendar: calendar, cappedAt: count) >= count { return nil }
            }
        }

        guard matches else { return nil }

        // Build the occurrence time range for this day.
        //
        // ALL-DAY: derive the end civilly (`Event.allDayCivilEnd`, gh#211 —
        // extended here at gh#212), never as `start + duration` raw seconds.
        // Every consumer of an expanded series occurrence inherits this
        // range — the full call-site set, grep-verified at gh#212 round 2:
        // the timed canvas and the all-day strip in this file
        // (`occurrencesForDate`, `allDayOccurrencesForDate`), the widget
        // snapshot builder and the interrupt parent-range resolver and the
        // gh#209 active-occurrence probe (all `EventStore`), the edit
        // sheets' occurrence seed (`occurrenceSeedRange`), the detail
        // view's occurrence resolution and display range
        // (`CalendarEventDetailTypes`), and the report expander's timed
        // walk (`ReportStatsBuilder.expandOccurrences`; it skips all-day
        // events) — so a raw end expanding onto a 23-hour spring-forward
        // day would hand all of them a next-day-00:59:59 leak the stored-row
        // writers can no longer produce (gh#188/#207/#211). TIMED expansion
        // keeps the raw duration: absolute length across a DST day is the
        // correct semantic there.
        let occurrenceStart = Event.dateByCombining(day: targetDay, timeFrom: event.primaryTimeRange?.start, calendar: calendar)
        let occurrenceEnd = event.isAllDay
            ? Event.allDayCivilEnd(
                anchoredAt: calendar.startOfDay(for: occurrenceStart),
                rawDuration: event.duration,
                calendar: calendar
            )
            : occurrenceStart.addingTimeInterval(event.duration)
        return Event.TimeRange(start: occurrenceStart, end: occurrenceEnd)
    }

    /// 功能： Filters events that intersect with the provided day and sorts them for layout.
    static func occurrencesForDate(
        _ events: [Event],
        date: Date,
        calendar: Calendar = .current
    ) -> [EventOccurrence] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        var occurrences: [EventOccurrence] = []
        for event in events {
            // Skip all-day events — they render in the all-day section
            if event.isAllDay { continue }

            // Handle recurring series: expand into virtual occurrences
            if event.isRecurringSeries {
                if let range = recurrenceOccurrence(for: event, on: date, calendar: calendar) {
                    let dayTimestamp = Int(dayStart.timeIntervalSince1970)
                    let id = "\(event.id.uuidString)-recur-\(dayTimestamp)"
                    occurrences.append(EventOccurrence(id: id, event: event, range: range))
                }
                continue
            }

            // For timer-active events, use timerStartedAt → now as the effective range
            // — but clamp `end` to at least `timerStart + calendarTimerMinimumVisibleDuration`
            // so the block has visible height immediately on start, instead of
            // appearing as a 0pt slice until the next 30s timer tick rebuilds
            // the cache.  See `CalendarPageView.updateTimerRefresh`.
            let ranges: [Event.TimeRange]
            if let timerStart = event.timerStartedAt {
                let minimumEnd = timerStart.addingTimeInterval(CalendarLayout.timerMinimumVisibleDuration)
                ranges = [Event.TimeRange(start: timerStart, end: max(Date(), minimumEnd))]
            } else {
                // Render-frame ranges, not raw stored instants: a detached
                // exception instance is pinned to its NOMINAL day (gh#127
                // items 2/5). Series suppression above is day-key nominal, so
                // placing the replacement by its absolute instant would split
                // the pair after a tz change — the replacement re-buckets next
                // to the neighboring day's own occurrence (duplicate) while
                // the suppressed day renders empty (hole). Identical to
                // `effectiveTimeRanges` for every non-instance event and for
                // every instance whose minting frame is the current frame.
                ranges = event.renderTimeRanges(calendar: calendar)
            }
            for range in ranges {
                if range.end > dayStart && range.start < dayEnd {
                    let id: String
                    if event.timerStartedAt != nil {
                        id = "\(event.id.uuidString)-timer"
                    } else {
                        id = "\(event.id.uuidString)-\(range.start.timeIntervalSince1970)-\(range.end.timeIntervalSince1970)"
                    }
                    occurrences.append(EventOccurrence(id: id, event: event, range: range))
                }
            }
        }
        return occurrences
    }

    /// 功能： Builds a cache of occurrences for each day offset within the given range.
    static func occurrencesByOffset(
        _ events: [Event],
        dayRange: ClosedRange<Int>,
        calendar: Calendar = .current,
        reference: Date = Date()
    ) -> [Int: [EventOccurrence]] {
        var cache: [Int: [EventOccurrence]] = [:]
        for offset in dayRange {
            let date = calendar.date(byAdding: .day, value: offset, to: reference) ?? reference
            cache[offset] = occurrencesForDate(events, date: date, calendar: calendar)
        }
        return cache
    }

    /// A day column's visible occurrence list in DEFERRED form: a cheap
    /// structural `key` plus the `build` closure that produces the list
    /// (gh#201 fix 2).
    ///
    /// Why this exists. The eager form ran
    /// `timelineVisibleOccurrences` — a dictionary merge plus a sort — once
    /// per mounted column per `CalendarPageView.body` pass, and the day layer
    /// then compared the resulting Model against the one it already held and
    /// threw it away.
    ///
    /// The device numbers, split by how each was obtained, because an
    /// earlier version of this comment ran the two together and a later
    /// pass then "reconciled" a measured row out of existence.
    ///
    /// MEASURED, per gesture, from the round-3 device runs' harness JSONL,
    /// whose `pageBody` column counts that gesture's `CalendarPageView.body`
    /// passes and whose `dayLayer` column counts day-column model
    /// constructions. Effort taps span 45–240 constructions. Both ends are
    /// recorded rows, not extrapolations — 240 is run 5AC4A02C gesture 10
    /// (pageBody 14, dayLayer 240). Measured separately, and as SESSION
    /// totals rather than per-tap figures — every tap plus every other
    /// body-invalidating event in that session — the day layer's own
    /// `applied/asked` counters: 7/1125 and 11/1920. Those are what
    /// establish the ratio, ≥99% of the work built, compared, and
    /// discarded.
    ///
    /// MODELLED, and only modelled: "15 mounted columns", i.e.
    /// `dayLayer ≈ pageBody × 15`. It accounts for most rows and is not an
    /// identity. Observed ratios run roughly 13–17 (run 99743ED9 gesture 3:
    /// 11 → 165, ratio 15.0; run 5AC4A02C gesture 10: 14 → 240, ratio
    /// 17.1), and one drag row sits well outside it (196 → 375). So
    /// 14 × 15 = 210 failing to reproduce the measured 240 is a fact about
    /// the multiplier, not an error in the measurement: the mounted column
    /// count is not constant. Do not adjust a measured row to fit the
    /// model.
    ///
    /// Why the key is sound rather than a heuristic. The visible list is a
    /// pure function of (a) the raw per-offset cached arrays for the
    /// candidate offsets, (b) the column's anchor day, (c) the two
    /// boundary-extension hour counts, and (d) the `calendar`. `Key` carries
    /// the first three verbatim; (d) is ABSORBED, and the absorption is
    /// written out here rather than left implicit because "carries exactly
    /// those three" would otherwise be a universal the type does not earn.
    ///
    /// The absorption: in the deferred build, `calendar` reaches the result
    /// only through `calendarTimelineVisibleStart/End(containing: anchorDate,
    /// calendar:)`, i.e. only as `calendar.startOfDay(for: anchorDate)` —
    /// the `reference` leg is computed and discarded once `anchorDate` is
    /// passed explicitly. And `anchorDate` is not independent of the
    /// calendar: the caller derives it as
    /// `calendar.startOfDay(for: Date()) + offset days`
    /// (`TimelineView.dayDate(forOffset:)`, `.current` on both sides), so it
    /// is already that calendar's start-of-day and the call is normally the
    /// identity. Two keys can therefore only straddle a calendar change —
    /// a time-zone change — and that moves `startOfDay(Date())`, hence the
    /// `anchorDate` the caller computes, which IS in the key.
    ///
    /// What that argument does NOT cover, said plainly so the claim is not
    /// read as stronger than it is: two calendars that agree on today's
    /// start-of-day but disagree on some later day's (a DST-rule
    /// difference rather than an offset one) would move
    /// `startOfDay(anchorDate)` for a far offset without moving
    /// `anchorDate`. That needs two different `Calendar` values in play;
    /// production has exactly one (`.current`, the parameter default on
    /// every path here), so the shape is unreachable rather than defended.
    ///
    /// Why it is CHEAP despite carrying arrays. `sources` holds the very
    /// array values the cache stores, not copies built per pass, so two keys
    /// taken while the cache entry is untouched compare through
    /// `Array`'s buffer-identity fast path — O(candidates), no element
    /// comparison. When a cache entry HAS been rewritten the buffers differ
    /// and the comparison falls through to an exact elementwise compare,
    /// which is correct (never a false "equal") and no more expensive than
    /// what the eager path already paid.
    struct DayOccurrenceSource {
        struct Key: Equatable {
            let anchorDate: Date
            let leadingExtendedHours: Int
            let trailingExtendedHours: Int
            let sources: [[EventOccurrence]]
        }

        let key: Key
        let build: () -> [EventOccurrence]
    }

    /// Deferred counterpart of `timelineVisibleOccurrences`.
    ///
    /// `build` reads back the SAME snapshot arrays the key was computed from
    /// rather than re-reading `occurrencesForOffset`, so the list a caller
    /// eventually gets is the list the key described even if the cache moved
    /// on in between. That is the property that makes "key unchanged ⇒ skip"
    /// safe rather than merely usually-right.
    static func timelineVisibleOccurrenceSource(
        forDayOffset offset: Int,
        anchorDate: Date,
        leadingExtendedHours: Int = 0,
        trailingExtendedHours: Int = 0,
        calendar: Calendar = .current,
        occurrencesForOffset: (Int) -> [EventOccurrence]
    ) -> DayOccurrenceSource {
        let candidateOffsets = timelineCandidateDayOffsets(
            forDayOffset: offset,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
        let sources = candidateOffsets.map(occurrencesForOffset)
        return DayOccurrenceSource(
            key: DayOccurrenceSource.Key(
                anchorDate: anchorDate,
                leadingExtendedHours: leadingExtendedHours,
                trailingExtendedHours: trailingExtendedHours,
                sources: sources
            ),
            build: {
                timelineVisibleOccurrences(
                    forDayOffset: offset,
                    leadingExtendedHours: leadingExtendedHours,
                    trailingExtendedHours: trailingExtendedHours,
                    calendar: calendar,
                    anchorDate: anchorDate,
                    occurrencesForOffset: { candidateOffset in
                        guard let index = candidateOffsets.firstIndex(of: candidateOffset) else {
                            return []
                        }
                        return sources[index]
                    }
                )
            }
        )
    }

    /// The day offsets whose cached occurrence lists a column's visible set is
    /// built from: the column's own offset, plus each adjacent day a live
    /// boundary extension pulls into view.
    ///
    /// Extracted so `timelineVisibleOccurrences` and the deferred
    /// `timelineVisibleOccurrenceSource` below cannot disagree about which
    /// inputs the result depends on — the source snapshots exactly these
    /// offsets for its key, and a key computed over a different offset set
    /// than the value is built from is precisely the silent staleness the
    /// deferred form has to be safe against (gh#201 fix 2).
    static func timelineCandidateDayOffsets(
        forDayOffset offset: Int,
        leadingExtendedHours: Int,
        trailingExtendedHours: Int
    ) -> [Int] {
        var candidateOffsets = [offset]
        if leadingExtendedHours > 0 {
            candidateOffsets.insert(offset - 1, at: 0)
        }
        if trailingExtendedHours > 0 {
            candidateOffsets.append(offset + 1)
        }
        return candidateOffsets
    }

    /// Builds the visible timed-event set for a timeline column, including
    /// adjacent-day occurrences when temporary boundary extension is active.
    ///
    /// `anchorDate`: the column's own start-of-day. Defaults to nil, which
    /// derives it from `reference` + `offset` exactly as before. The deferred
    /// form passes the anchor the caller already computed
    /// (`TimelineView.dayDate(forOffset:)`) so the key and the value it
    /// admits are computed against the SAME day, not two `Date()` reads that
    /// a midnight crossing could separate.
    static func timelineVisibleOccurrences(
        forDayOffset offset: Int,
        leadingExtendedHours: Int = 0,
        trailingExtendedHours: Int = 0,
        reference: Date = Date(),
        calendar: Calendar = .current,
        anchorDate anchorDateOverride: Date? = nil,
        occurrencesForOffset: (Int) -> [EventOccurrence]
    ) -> [EventOccurrence] {
        let referenceDay = calendar.startOfDay(for: reference)
        let anchorDate = anchorDateOverride
            ?? calendar.date(byAdding: .day, value: offset, to: referenceDay)
            ?? referenceDay
        let visibleStart = calendarTimelineVisibleStart(
            containing: anchorDate,
            leadingExtendedHours: leadingExtendedHours,
            calendar: calendar
        )
        let visibleEnd = calendarTimelineVisibleEnd(
            containing: anchorDate,
            trailingExtendedHours: trailingExtendedHours,
            calendar: calendar
        )

        let candidateOffsets = timelineCandidateDayOffsets(
            forDayOffset: offset,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )

        var mergedByID: [String: EventOccurrence] = [:]
        for candidateOffset in candidateOffsets {
            for occurrence in occurrencesForOffset(candidateOffset)
            where occurrence.range.end > visibleStart && occurrence.range.start < visibleEnd {
                if let existing = mergedByID[occurrence.id] {
                    mergedByID[occurrence.id] = EventOccurrence(
                        id: occurrence.id,
                        event: occurrence.event,
                        range: Event.TimeRange(
                            start: min(existing.range.start, occurrence.range.start),
                            end: max(existing.range.end, occurrence.range.end)
                        )
                    )
                } else {
                    mergedByID[occurrence.id] = occurrence
                }
            }
        }

        return mergedByID.values.sorted { lhs, rhs in
            if lhs.range.start != rhs.range.start {
                return lhs.range.start < rhs.range.start
            }
            if lhs.range.end != rhs.range.end {
                return lhs.range.end < rhs.range.end
            }
            let lhsCreated = calendarCreatedAtOrderingValue(for: lhs.event)
            let rhsCreated = calendarCreatedAtOrderingValue(for: rhs.event)
            if lhsCreated != rhsCreated {
                return lhsCreated < rhsCreated
            }
            return lhs.id < rhs.id
        }
    }

    /// 功能： Calculates the vertical offset for an event block by measuring how far past midnight it starts.
    static func yOffset(
        for range: Event.TimeRange,
        on date: Date,
        headerHeight: CGFloat,
        hourHeight: CGFloat,
        calendar: Calendar = .current
    ) -> CGFloat {
        let dayStart = calendar.startOfDay(for: date)
        let start = max(range.start, dayStart)
        let seconds = max(0, start.timeIntervalSince(dayStart))
        return headerHeight + CGFloat(seconds / 3600) * hourHeight
    }

    /// 功能： Converts an event duration into a height in the timeline while enforcing a minimum visual size.
    static func eventHeight(
        for range: Event.TimeRange,
        on date: Date,
        minimumHeight: CGFloat,
        hourHeight: CGFloat,
        extendedDay: Bool = false,
        calendar: Calendar = .current
    ) -> CGFloat {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = dayStart.addingTimeInterval(TimeInterval(calendarTimelineBaseVisibleHours * 3600))
        let start = max(range.start, dayStart)
        let end = min(range.end, dayEnd)
        let seconds = max(0, end.timeIntervalSince(start))
        return max(minimumHeight, CGFloat(seconds / 3600) * hourHeight)
    }

    /// 功能： Maps semantic event types to consistent colors used in the timeline.
    /// Empty type resolves to the deliberate "uncategorized" neutral inside
    /// `EventTypeTemplateStore` (a single source shared with list mode, the
    /// share card, and the detail dot/badges), so a typeless item reads the
    /// same everywhere; analytics color the "Other" bucket separately.
    static func eventColor(for event: Event) -> Color {
        EventTypeTemplateStore.color(for: event.type)
            .opacity(event.colorOpacityMultiplier)
    }

    /// Filters all-day events that fall on the provided day.
    static func allDayOccurrencesForDate(
        _ events: [Event],
        date: Date,
        calendar: Calendar = .current
    ) -> [EventOccurrence] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        var occurrences: [EventOccurrence] = []
        for event in events {
            guard event.isAllDay else { continue }

            if event.isRecurringSeries {
                if let range = recurrenceOccurrence(for: event, on: date, calendar: calendar) {
                    let dayTimestamp = Int(dayStart.timeIntervalSince1970)
                    let id = "\(event.id.uuidString)-allday-recur-\(dayTimestamp)"
                    occurrences.append(EventOccurrence(id: id, event: event, range: range))
                }
                continue
            }

            // Same nominal-day pinning as `occurrencesForDate` (gh#127 items
            // 2/5): an all-day detached instance follows its day key too.
            let ranges = event.renderTimeRanges(calendar: calendar)
            for range in ranges {
                if range.end > dayStart && range.start < dayEnd {
                    let id = "\(event.id.uuidString)-allday-\(range.start.timeIntervalSince1970)"
                    occurrences.append(EventOccurrence(id: id, event: event, range: range))
                }
            }
        }
        return occurrences
    }

    /// Builds a cache of all-day occurrences for each day offset within the given range.
    static func allDayOccurrencesByOffset(
        _ events: [Event],
        dayRange: ClosedRange<Int>,
        calendar: Calendar = .current,
        reference: Date = Date()
    ) -> [Int: [EventOccurrence]] {
        var cache: [Int: [EventOccurrence]] = [:]
        for offset in dayRange {
            let date = calendar.date(byAdding: .day, value: offset, to: reference) ?? reference
            let occ = allDayOccurrencesForDate(events, date: date, calendar: calendar)
            if !occ.isEmpty {
                cache[offset] = occ
            }
        }
        return cache
    }

    // MARK: - Overlapping Event Layout

    /// Describes the horizontal position and z-ordering of an event within an overlap group.
    /// `coverRanges` lists absolute time intervals during which this event is visually
    /// covered by another event sitting on top in the stack-peek layering. EventBlock
    /// uses them to derive a visible region for text fitting (so titles don't render
    /// underneath an overlay). Empty when the event is unobstructed (depth 0 with no
    /// higher-depth siblings) or when stack-peek is disabled.
    struct EventOverlapSlot: Equatable {
        let xOffsetFraction: CGFloat  // [0, 1)
        let widthFraction: CGFloat    // (0, 1]
        let zIndex: Double
        let depth: Int
        let coverRanges: [Event.TimeRange]

        init(
            xOffsetFraction: CGFloat,
            widthFraction: CGFloat,
            zIndex: Double,
            depth: Int = 0,
            coverRanges: [Event.TimeRange] = []
        ) {
            self.xOffsetFraction = xOffsetFraction
            self.widthFraction = widthFraction
            self.zIndex = zIndex
            self.depth = depth
            self.coverRanges = coverRanges
        }

        static let `default` = EventOverlapSlot(xOffsetFraction: 0, widthFraction: 1, zIndex: 1)
    }

    /// Selects which layout policy `overlapLayout` applies within each cluster.
    /// `.auto` keeps the adaptive peer-vs-peek decision (default for static
    /// renders). `.equalSplit` forces greedy equal-split column packing —
    /// callers pass it during MOVE/RESIZE/drag-create flows so the per-frame
    /// mode + host-pick decisions can't flip mid-drag (the dual-pass
    /// disagreement bug and the host-identity flip on resize).
    ///
    /// `.equalSplit` is ALSO the contract for preview-style renderers that
    /// don't honor `coverRanges` — e.g. the mini-day timeline in the event
    /// detail view, the daily share card, and the focus event flow.
    /// Callers whose render path consumes only `widthFraction` /
    /// `xOffsetFraction` MUST pass `.equalSplit`; otherwise `.auto` may
    /// pick stack-peek and return a host slot with `widthFraction = 1.0`
    /// whose sibling time-ranges are encoded in `coverRanges` — those
    /// siblings would then render fully covered by the host.
    enum OverlapMode {
        case auto
        case equalSplit
    }

    /// Returns the effective duration of an occurrence clipped to a single day.
    static func clippedDuration(
        for occurrence: EventOccurrence,
        on date: Date,
        calendar: Calendar = .current
    ) -> TimeInterval {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let start = max(occurrence.range.start, dayStart)
        let end = min(occurrence.range.end, dayEnd)
        return max(0, end.timeIntervalSince(start))
    }

    /// Computes overlap layout slots for a set of occurrences on a given day.
    /// Returns a mapping from occurrence ID to its overlap slot.
    static func overlapLayout(
        for occurrences: [EventOccurrence],
        on date: Date,
        calendar: Calendar = .current,
        mode: OverlapMode = .auto
    ) -> [String: EventOverlapSlot] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return overlapLayout(
            for: occurrences,
            visibleStart: dayStart,
            visibleEnd: dayEnd,
            calendar: calendar,
            mode: mode
        )
    }

    /// Computes overlap layout slots for a set of occurrences clipped to an
    /// arbitrary visible interval.
    ///
    /// Behavior depends on `mode`:
    /// - `.auto` (default): adaptive per cluster. When column heights are
    ///   even (longest:shortest ratio < 1.5) the cluster equal-splits via
    ///   greedy column packing with rightward expansion and `coverRanges`
    ///   stays empty. When heights are uneven, the longest group becomes
    ///   the depth-0 host at full width (with non-empty `coverRanges`
    ///   describing the time spans behind peers) and the remainder
    ///   recurses into a 50% right strip — see the stack-peek branch in
    ///   `layoutCluster(...)`.
    /// - `.equalSplit`: forces greedy column-packing for every cluster
    ///   regardless of column ratio — no host pick, no recursion, every
    ///   member at depth 0 with empty `coverRanges`. Drag callers pass
    ///   this to freeze geometry during a gesture (see
    ///   `CalendarDayLayerView.render()` — it derives an `overlapMode` from
    ///   its drag signals before the live + stable `overlapLayout` calls)
    ///   so per-frame mode/host flips can't fire.
    static func overlapLayout(
        for occurrences: [EventOccurrence],
        visibleStart: Date,
        visibleEnd: Date,
        calendar: Calendar = .current,
        mode: OverlapMode = .auto
    ) -> [String: EventOverlapSlot] {
        guard occurrences.count > 1 else {
            var result: [String: EventOverlapSlot] = [:]
            for occ in occurrences {
                result[occ.id] = .default
            }
            return result
        }

        // Phase 1: Find overlap clusters via adjacency + DFS
        let clusters = findOverlapClusters(
            occurrences,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar
        )

        // Phase 2: Layout each cluster
        var result: [String: EventOverlapSlot] = [:]
        for cluster in clusters {
            if cluster.count == 1 {
                result[cluster[0].id] = .default
            } else {
                let slots = layoutCluster(
                    cluster,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    xStart: 0,
                    width: 1,
                    baseZ: 1,
                    depth: 0,
                    calendar: calendar,
                    mode: mode
                )
                for (id, slot) in slots {
                    result[id] = slot
                }
            }
        }

        // Fill defaults for any not assigned (shouldn't happen but safety)
        for occ in occurrences where result[occ.id] == nil {
            result[occ.id] = .default
        }

        return result
    }

    /// Groups occurrences into connected components based on time overlap.
    private static func findOverlapClusters(
        _ occurrences: [EventOccurrence],
        visibleStart: Date,
        visibleEnd: Date,
        calendar: Calendar
    ) -> [[EventOccurrence]] {
        _ = calendar
        let n = occurrences.count
        var parent = Array(0..<n)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Check pairwise overlap. All kinds (event ↔ event, event ↔
        // todo, todo ↔ todo) participate in the same cluster /
        // stack-peek layout. An earlier slice (0c32463) tried to skip
        // todo↔todo union — user feedback revealed that broke the
        // expected layout: two overlapping todos rendered with full
        // width each and visually covered each other. Restored to the
        // original behavior.
        for i in 0..<n {
            let si = max(occurrences[i].range.start, visibleStart)
            let ei = min(occurrences[i].range.end, visibleEnd)
            for j in (i + 1)..<n {
                let sj = max(occurrences[j].range.start, visibleStart)
                let ej = min(occurrences[j].range.end, visibleEnd)
                if si < ej && sj < ei {
                    union(i, j)
                }
            }
        }

        // Group by root
        var groups: [Int: [EventOccurrence]] = [:]
        for i in 0..<n {
            groups[find(i), default: []].append(occurrences[i])
        }
        return Array(groups.values)
    }

    /// Lays out a cluster of overlapping events via greedy column packing
    /// with rightward expansion: each group is assigned to the lowest column
    /// it doesn't conflict with, then expands rightward into any adjacent
    /// columns whose contents don't time-overlap it. Two events never sit
    /// on top of each other — every group gets a visible slice proportional
    /// to the cluster's column count.
    private static func layoutCluster(
        _ cluster: [EventOccurrence],
        visibleStart: Date,
        visibleEnd: Date,
        xStart: CGFloat,
        width: CGFloat,
        baseZ: Double,
        depth: Int,
        calendar: Calendar,
        mode: OverlapMode = .auto
    ) -> [(String, EventOverlapSlot)] {
        guard !cluster.isEmpty else { return [] }
        if cluster.count == 1 {
            return [(cluster[0].id, EventOverlapSlot(
                xOffsetFraction: xStart,
                widthFraction: width,
                zIndex: baseZ,
                depth: depth
            ))]
        }

        let embeddedInterruptParentIDs = Set(
            cluster.compactMap { occurrence -> UUID? in
                guard let relation = occurrence.event.interruptRelation,
                      relation.state == .embedded else {
                    return nil
                }
                return relation.parentEventID
            }
        )

        // Cross-group ordering must be a pure function of the packing-group
        // key, so each key carries one representative creation stamp: the
        // earliest family-parent stamp for an interrupt-family key (one
        // anchor can carry several non-embedded events — a `.following`
        // split mints a fresh stamp while its re-parented detached
        // instances keep the original), the occurrence's own otherwise.
        // A family key with no parent in the cluster takes the earliest
        // member stamp. The first parent replaces any child-derived value,
        // later parents min in, and children stop contributing once a
        // parent is seen — min over parent stamps when a parent is
        // present, min over member stamps otherwise.
        var groupCreatedAtOrder: [String: Int64] = [:]
        var groupHasParentRepresentative: Set<String> = []
        for occurrence in cluster {
            let key = calendarInterruptPackingGroupKey(
                for: occurrence,
                embeddedInterruptParentIDs: embeddedInterruptParentIDs
            )
            let createdAtOrder = calendarCreatedAtOrderingValue(for: occurrence.event)
            let isFamilyParent = occurrence.event.interruptRelation?.state != .embedded
                && embeddedInterruptParentIDs.contains(
                    calendarInterruptAnchorEventID(for: occurrence.event)
                )
            if isFamilyParent {
                if groupHasParentRepresentative.contains(key) {
                    groupCreatedAtOrder[key] = min(
                        groupCreatedAtOrder[key] ?? createdAtOrder,
                        createdAtOrder
                    )
                } else {
                    groupCreatedAtOrder[key] = createdAtOrder
                    groupHasParentRepresentative.insert(key)
                }
            } else if !groupHasParentRepresentative.contains(key) {
                groupCreatedAtOrder[key] = min(
                    groupCreatedAtOrder[key] ?? createdAtOrder,
                    createdAtOrder
                )
            }
        }

        // Sort by start time; equal starts order across groups by the group
        // representative's creation stamp (earlier-created further left),
        // keeping parent + interrupt children adjacent because they share a
        // packing-group key.
        let sorted = cluster.sorted { a, b in
            let sa = max(a.range.start, visibleStart)
            let sb = max(b.range.start, visibleStart)
            if sa != sb { return sa < sb }

            let groupA = calendarInterruptPackingGroupKey(
                for: a,
                embeddedInterruptParentIDs: embeddedInterruptParentIDs
            )
            let groupB = calendarInterruptPackingGroupKey(
                for: b,
                embeddedInterruptParentIDs: embeddedInterruptParentIDs
            )
            if groupA != groupB {
                let createdA = groupCreatedAtOrder[groupA] ?? .max
                let createdB = groupCreatedAtOrder[groupB] ?? .max
                if createdA != createdB {
                    return createdA < createdB
                }
                return groupA < groupB
            }

            let rankA = calendarInterruptGroupRank(for: a)
            let rankB = calendarInterruptGroupRank(for: b)
            if rankA != rankB {
                return rankA < rankB
            }

            let da = min(a.range.end, visibleEnd).timeIntervalSince(sa)
            let db = min(b.range.end, visibleEnd).timeIntervalSince(sb)
            if da != db {
                return da > db
            }

            let createdA = calendarCreatedAtOrderingValue(for: a.event)
            let createdB = calendarCreatedAtOrderingValue(for: b.event)
            if createdA != createdB {
                return createdA < createdB
            }
            return a.id < b.id
        }

        struct OverlapPackingGroup {
            let id: String
            let members: [EventOccurrence]
            let start: Date
            let end: Date
            let firstSeenIndex: Int
        }

        var groupedMembers: [String: [EventOccurrence]] = [:]
        var groupFirstSeenIndex: [String: Int] = [:]
        for (index, occurrence) in sorted.enumerated() {
            let groupID = calendarInterruptPackingGroupKey(
                for: occurrence,
                embeddedInterruptParentIDs: embeddedInterruptParentIDs
            )
            groupedMembers[groupID, default: []].append(occurrence)
            groupFirstSeenIndex[groupID] = min(groupFirstSeenIndex[groupID] ?? index, index)
        }

        let groups = groupedMembers.compactMap { groupID, members -> OverlapPackingGroup? in
            guard let firstMember = members.first else { return nil }
            let firstSeenIndex = groupFirstSeenIndex[groupID] ?? 0
            let start = members.reduce(max(firstMember.range.start, visibleStart)) { partialResult, occurrence in
                min(partialResult, max(occurrence.range.start, visibleStart))
            }
            let end = members.reduce(min(firstMember.range.end, visibleEnd)) { partialResult, occurrence in
                max(partialResult, min(occurrence.range.end, visibleEnd))
            }
            return OverlapPackingGroup(
                id: groupID,
                members: members,
                start: start,
                end: end,
                firstSeenIndex: firstSeenIndex
            )
        }.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.firstSeenIndex < b.firstSeenIndex
        }

        if groups.count == 1 {
            return groups[0].members.map {
                (
                    $0.id,
                    EventOverlapSlot(
                        xOffsetFraction: xStart,
                        widthFraction: width,
                        zIndex: baseZ,
                        depth: depth
                    )
                )
            }
        }

        // Phase 1: Greedy column packing — minimize total columns. Processing
        // order is start-time ascending; the upstream `groups` array is
        // already sorted start-asc with end-desc tiebreaker (so when starts
        // coincide, the longer event lands at the lower column index).
        var groupColumnAssignment: [String: Int] = [:]
        var columns: [[OverlapPackingGroup]] = []
        for group in groups {
            var assigned = false
            for col in 0..<columns.count {
                let blocked = columns[col].contains { other in
                    group.start < other.end && other.start < group.end
                }
                if !blocked {
                    groupColumnAssignment[group.id] = col
                    columns[col].append(group)
                    assigned = true
                    break
                }
            }
            if !assigned {
                groupColumnAssignment[group.id] = columns.count
                columns.append([group])
            }
        }
        let totalCols = columns.count

        // Mode decision: when columns hold roughly the same total event-time
        // the cluster is a "peer set" (same-duration peers, or chains where
        // events pack evenly) — equal-split reads cleanly. When one column
        // dominates by more than ~50%, the shorter column would leave a
        // visible tail-blank under equal-split; switch to stack-peek with
        // a 50% strip so the longest event acts as a background filling
        // the remaining vertical space.
        //
        // The threshold lives in ratio space (`maxCol / minCol`) so it
        // scales naturally — a 60min/50min pair (ratio 1.2) reads as
        // peers; a 2h/1h pair (ratio 2) triggers peek; a Work/meeting
        // background (ratio 3+) clearly recurses.
        // `.equalSplit` short-circuits the adaptive decision so callers can
        // freeze the mode during a drag — there's no host pick, no recursion,
        // and the per-frame mode/host flip bugs (PR #59 #1 + #2) can't fire.
        let columnsEven: Bool
        switch mode {
        case .equalSplit:
            columnsEven = true
        case .auto:
            let columnTotalSeconds = columns.map { col in
                col.reduce(0.0) { partial, g in
                    partial + g.end.timeIntervalSince(g.start)
                }
            }
            let maxColTime = columnTotalSeconds.max() ?? 0
            let minColTime = columnTotalSeconds.min() ?? 0
            let columnHeightRatio = minColTime > 1.0
                ? maxColTime / minColTime
                : Double.infinity
            let peerHeightRatioThreshold = 1.5
            columnsEven = columnHeightRatio < peerHeightRatioThreshold
        }

        if columnsEven {
            // Phase 2 (equal-split): expand each group rightward into adjacent
            // free columns (a group whose neighbor column is unoccupied during
            // its time range can span both, so a sparse cluster reads less
            // crowded).
            var groupSpanEnd: [String: Int] = [:]
            for group in groups {
                let col = groupColumnAssignment[group.id] ?? 0
                var expandTo = col
                for nextCol in (col + 1)..<totalCols {
                    let blocked = columns[nextCol].contains { other in
                        group.start < other.end && other.start < group.end
                    }
                    if blocked { break }
                    expandTo = nextCol
                }
                groupSpanEnd[group.id] = expandTo
            }
            // Phase 3 (equal-split): build slots
            let colWidth = totalCols > 0 ? width / CGFloat(totalCols) : width
            var result: [(String, EventOverlapSlot)] = []
            for group in groups {
                let col = groupColumnAssignment[group.id] ?? 0
                let end = groupSpanEnd[group.id] ?? col
                let span = CGFloat(end - col + 1)
                let x = xStart + colWidth * CGFloat(col)
                let w = colWidth * span
                let slot = EventOverlapSlot(
                    xOffsetFraction: x,
                    widthFraction: w,
                    zIndex: baseZ,
                    depth: depth
                )
                for member in group.members {
                    result.append((member.id, slot))
                }
            }
            return result
        }

        // Stack-peek branch: the longest group is the "host" and occupies the
        // full column at this depth; the remaining events sit in a 50%-wide
        // strip at the right and recurse — events that don't actually overlap
        // each other (only overlapped the host) become singleton sub-clusters
        // that each fill the strip's width. `coverRanges` reports the time
        // intervals where the host is visually obscured so the renderer can
        // place its title in an uncovered region.
        let host = groups.max { lhs, rhs in
            let lDur = lhs.end.timeIntervalSince(lhs.start)
            let rDur = rhs.end.timeIntervalSince(rhs.start)
            if lDur != rDur { return lDur < rDur }
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            let lCreated = groupCreatedAtOrder[lhs.id] ?? .max
            let rCreated = groupCreatedAtOrder[rhs.id] ?? .max
            if lCreated != rCreated { return lCreated > rCreated }
            return lhs.id > rhs.id
        }!
        let restGroups = groups.filter { $0.id != host.id }

        var rawCovers: [Event.TimeRange] = []
        for other in restGroups {
            let oStart = max(other.start, visibleStart)
            let oEnd = min(other.end, visibleEnd)
            guard oEnd > oStart else { continue }
            rawCovers.append(Event.TimeRange(start: oStart, end: oEnd))
        }
        let mergedCovers = mergeTimeRanges(rawCovers)

        var result: [(String, EventOverlapSlot)] = []
        let hostSlot = EventOverlapSlot(
            xOffsetFraction: xStart,
            widthFraction: width,
            zIndex: baseZ,
            depth: depth,
            coverRanges: mergedCovers
        )
        for member in host.members {
            result.append((member.id, hostSlot))
        }

        // Rest in the right 50% strip — recurse so a sub-cluster with its own
        // peer-vs-uneven shape is handled the same way at the next level.
        let stripFraction: CGFloat = 0.5
        let subXStart = xStart + width * stripFraction
        let subWidth = width * stripFraction

        let restOccurrences = restGroups.flatMap { $0.members }
        let subClusters = findOverlapClusters(
            restOccurrences,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar
        )
        for subCluster in subClusters {
            let subSlots = layoutCluster(
                subCluster,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                xStart: subXStart,
                width: subWidth,
                baseZ: baseZ + 0.01,
                depth: depth + 1,
                calendar: calendar,
                mode: mode
            )
            result.append(contentsOf: subSlots)
        }
        return result
    }

    /// Merges overlapping/adjacent `Event.TimeRange` values into a minimal
    /// disjoint set, sorted by start. Used by the stack-peek branch to
    /// consolidate cover intervals for the host event.
    private static func mergeTimeRanges(_ ranges: [Event.TimeRange]) -> [Event.TimeRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
        var merged: [Event.TimeRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            let lastIndex = merged.index(before: merged.endIndex)
            if range.start <= merged[lastIndex].end {
                merged[lastIndex].end = max(merged[lastIndex].end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Millisecond-granularity creation stamp for true-peer ordering —
    /// every lane-deciding comparison must reduce `createdAt` through this
    /// same key before falling back to id.
    private static func calendarCreatedAtOrderingValue(for event: Event) -> Int64 {
        Int64((event.createdAt.timeIntervalSince1970 * 1000).rounded())
    }

    private static func calendarInterruptPackingGroupKey(
        for occurrence: EventOccurrence,
        embeddedInterruptParentIDs: Set<UUID>
    ) -> String {
        let anchorID = calendarInterruptAnchorEventID(for: occurrence.event)
        if let relation = occurrence.event.interruptRelation,
           relation.state == .embedded {
            return "interrupt-family:\(relation.parentEventID.uuidString)"
        }
        if embeddedInterruptParentIDs.contains(anchorID) {
            return "interrupt-family:\(anchorID.uuidString)"
        }
        return "occurrence:\(occurrence.id)"
    }

    private static func calendarInterruptAnchorEventID(
        for event: Event
    ) -> UUID {
        event.recurrenceParentId ?? event.id
    }

    private static func calendarInterruptGroupRank(
        for occurrence: EventOccurrence
    ) -> Int {
        if occurrence.event.isInterrupt {
            return 1
        }
        return 0
    }

    /// 功能： Converts a Y position in the timeline back to a Date, with optional snapping.
    static func timeFromYOffset(
        yOffset: CGFloat,
        on date: Date,
        headerHeight: CGFloat,
        hourHeight: CGFloat,
        snapMinutes: Int = 15,
        calendar: Calendar = .current
    ) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let pixelsAfterHeader = max(0, yOffset - headerHeight)
        let totalMinutes = (pixelsAfterHeader / hourHeight) * 60

        // Snap to specified minute interval
        let snappedMinutes = round(totalMinutes / Double(snapMinutes)) * Double(snapMinutes)
        let clampedMinutes = max(0, min(Double(calendarTimelineBaseVisibleHours * 60), snappedMinutes))

        return dayStart.addingTimeInterval(clampedMinutes * 60)
    }
}
