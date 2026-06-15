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

        // Check exception dates
        for exceptionDate in event.recurrenceExceptionDates {
            if calendar.isDate(exceptionDate, inSameDayAs: targetDay) {
                return nil
            }
        }

        // Check end conditions
        switch event.repeatEndType {
        case .onDate:
            if let endDate = event.repeatEndDate, targetDay > calendar.startOfDay(for: endDate) {
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
        let interval = event.repeatInterval
        guard interval > 0 else { return nil }

        switch event.repeatUnit {
        case .none:
            return nil
        case .day:
            let daysBetween = calendar.dateComponents([.day], from: seriesDay, to: targetDay).day ?? 0
            matches = daysBetween >= 0 && daysBetween % interval == 0
            if matches, event.repeatEndType == .afterCount, let count = event.repeatEndCount {
                if daysBetween / interval >= count { return nil }
            }
        case .week:
            let daysBetween = calendar.dateComponents([.day], from: seriesDay, to: targetDay).day ?? 0
            let weeksBetween = daysBetween / 7
            matches = daysBetween >= 0 && daysBetween % 7 == 0 && weeksBetween % interval == 0
            if matches, event.repeatEndType == .afterCount, let count = event.repeatEndCount {
                if weeksBetween / interval >= count { return nil }
            }
        case .month:
            let monthsBetween = (calendar.dateComponents([.month], from: seriesDay, to: targetDay).month ?? 0)
            let seriesDayOfMonth = calendar.component(.day, from: seriesDay)
            let targetDayOfMonth = calendar.component(.day, from: targetDay)
            matches = monthsBetween >= 0 && monthsBetween % interval == 0 && targetDayOfMonth == seriesDayOfMonth
            if matches, event.repeatEndType == .afterCount, let count = event.repeatEndCount {
                if monthsBetween / interval >= count { return nil }
            }
        case .year:
            let yearsBetween = calendar.dateComponents([.year], from: seriesDay, to: targetDay).year ?? 0
            let seriesMonth = calendar.component(.month, from: seriesDay)
            let seriesDayOfMonth = calendar.component(.day, from: seriesDay)
            let targetMonth = calendar.component(.month, from: targetDay)
            let targetDayOfMonth = calendar.component(.day, from: targetDay)
            matches = yearsBetween >= 0 && yearsBetween % interval == 0 && targetMonth == seriesMonth && targetDayOfMonth == seriesDayOfMonth
            if matches, event.repeatEndType == .afterCount, let count = event.repeatEndCount {
                if yearsBetween / interval >= count { return nil }
            }
        }

        guard matches else { return nil }

        // Build the occurrence time range for this day
        let occurrenceStart = Event.dateByCombining(day: targetDay, timeFrom: event.primaryTimeRange?.start, calendar: calendar)
        let occurrenceEnd = occurrenceStart.addingTimeInterval(event.duration)
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
                ranges = event.effectiveTimeRanges
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

    /// Builds the visible timed-event set for a timeline column, including
    /// adjacent-day occurrences when temporary boundary extension is active.
    static func timelineVisibleOccurrences(
        forDayOffset offset: Int,
        leadingExtendedHours: Int = 0,
        trailingExtendedHours: Int = 0,
        reference: Date = Date(),
        calendar: Calendar = .current,
        occurrencesForOffset: (Int) -> [EventOccurrence]
    ) -> [EventOccurrence] {
        let referenceDay = calendar.startOfDay(for: reference)
        let anchorDate = calendar.date(byAdding: .day, value: offset, to: referenceDay) ?? referenceDay
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

        var candidateOffsets = [offset]
        if leadingExtendedHours > 0 {
            candidateOffsets.insert(offset - 1, at: 0)
        }
        if trailingExtendedHours > 0 {
            candidateOffsets.append(offset + 1)
        }

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

            let ranges = event.effectiveTimeRanges
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
    ///   `CalendarDayLayerView.render()` and `TimelineDayView.body` —
    ///   each derives an `overlapMode` from its drag signals before the
    ///   live + stable `overlapLayout` calls) so per-frame mode/host
    ///   flips can't fire.
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

        // Sort by start time, then keep parent + interrupt children adjacent when possible.
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
