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
            let ranges: [Event.TimeRange]
            if let timerStart = event.timerStartedAt {
                ranges = [Event.TimeRange(start: timerStart, end: Date())]
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
        peekFraction: CGFloat = 0,
        peerTolerance: TimeInterval = 0
    ) -> [String: EventOverlapSlot] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return overlapLayout(
            for: occurrences,
            visibleStart: dayStart,
            visibleEnd: dayEnd,
            calendar: calendar,
            peekFraction: peekFraction,
            peerTolerance: peerTolerance
        )
    }

    /// Computes overlap layout slots for a set of occurrences clipped to an
    /// arbitrary visible interval.
    ///
    /// `peekFraction` switches between two layout modes:
    ///  - `0`  → equal-split column layout (legacy): cluster gets divided into
    ///    columns of uniform width, with rightward expansion into free columns.
    ///  - `> 0` → stack-with-peek: longest event occupies depth 0 (full sub-canvas);
    ///    each shallower-depth sibling is offset right by `peekFraction` and
    ///    z-stacked on top. Events at the same column (no time-overlap) share
    ///    a depth. `coverRanges` on each slot reports the time intervals where
    ///    that event is visually obscured by a higher-depth sibling.
    ///
    /// `peerTolerance` (seconds) controls when two stack-peek groups are
    /// treated as time-equal "peers" that share a depth and split width
    /// equally instead of stacking. Both starts AND both ends must lie
    /// within the tolerance. `0` means strict equality. Typical values
    /// are 5-15 minutes — large enough to absorb minor user-edit drift
    /// but small enough to keep genuinely staircased events distinct.
    /// Has no effect in equal-split mode (`peekFraction == 0`).
    static func overlapLayout(
        for occurrences: [EventOccurrence],
        visibleStart: Date,
        visibleEnd: Date,
        calendar: Calendar = .current,
        peekFraction: CGFloat = 0,
        peerTolerance: TimeInterval = 0
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
                    calendar: calendar,
                    peekFraction: peekFraction,
                    peerTolerance: peerTolerance
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

        // Check pairwise overlap
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

    /// Lays out a cluster of overlapping events. When `peekFraction == 0`,
    /// uses the legacy greedy column packing with rightward expansion. When
    /// `peekFraction > 0`, uses stack-with-peek: longest group at depth 0,
    /// shallower-depth groups offset by `peekFraction` and z-stacked on top.
    private static func layoutCluster(
        _ cluster: [EventOccurrence],
        visibleStart: Date,
        visibleEnd: Date,
        xStart: CGFloat,
        width: CGFloat,
        baseZ: Double,
        calendar: Calendar,
        peekFraction: CGFloat = 0,
        peerTolerance: TimeInterval = 0
    ) -> [(String, EventOverlapSlot)] {
        guard !cluster.isEmpty else { return [] }
        if cluster.count == 1 {
            return [(cluster[0].id, EventOverlapSlot(xOffsetFraction: xStart, widthFraction: width, zIndex: baseZ))]
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
                        zIndex: baseZ
                    )
                )
            }
        }

        // Phase 1: Greedy column packing — minimize total columns.
        // Processing order is start-time ascending in both modes: earlier
        // events occupy the lower (back) depth, later overlapping events
        // get pushed to a higher depth. In stack-peek this means later
        // events render *on top* during overlap, which matches the natural
        // "newer thing comes in over the older one" reading.
        // The upstream `groups` array is already sorted start-asc with
        // end-desc tiebreaker (so when starts coincide, the longer event
        // lands at the lower depth).
        var groupColumnAssignment: [String: Int] = [:]
        var columns: [[OverlapPackingGroup]] = []

        let processingOrder: [OverlapPackingGroup] = groups

        // Stack-peek treats groups with near-identical time ranges as a
        // single peer-set sharing a depth and splitting width equally.
        // Both ends must lie within `peerTolerance` of each other; a
        // tolerance of 0 collapses to strict equality. The relation is
        // intentionally NOT transitive — events near a peer-set boundary
        // either join the closest existing column or start a new one.
        let peerTimeMatch: (OverlapPackingGroup, OverlapPackingGroup) -> Bool = { a, b in
            let startDelta = abs(a.start.timeIntervalSince(b.start))
            let endDelta = abs(a.end.timeIntervalSince(b.end))
            return startDelta <= peerTolerance && endDelta <= peerTolerance
        }

        for group in processingOrder {
            var assigned = false
            for col in 0..<columns.count {
                let blocked = columns[col].contains { other in
                    let overlaps = group.start < other.end && other.start < group.end
                    if !overlaps { return false }
                    if peekFraction > 0, peerTimeMatch(group, other) {
                        return false  // peers may share a column
                    }
                    return true
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

        if peekFraction > 0 {
            // Stack-peek mode: depth = column index. Each event sits at
            // (xStart + depth * peek) with width (canvasWidth - depth * peek).
            // Identical-time peers at the same depth sub-divide that width
            // equally so they read as true peers, not stacked. Cover ranges
            // record the time intervals where this event is visually
            // obscured by higher-depth siblings (peers don't cover peers).
            struct EventLayoutEntry {
                let occurrence: EventOccurrence
                let depth: Int
                let peerCount: Int
                let peerIndex: Int
            }

            var entries: [EventLayoutEntry] = []
            for group in groups {
                let depth = groupColumnAssignment[group.id] ?? 0
                let peerGroups = columns[depth]
                    .filter { peerTimeMatch(group, $0) }
                    .sorted { $0.id < $1.id }
                let peerCount = max(1, peerGroups.count)
                let peerIndex = peerGroups.firstIndex(where: { $0.id == group.id }) ?? 0
                for member in group.members {
                    entries.append(EventLayoutEntry(
                        occurrence: member,
                        depth: depth,
                        peerCount: peerCount,
                        peerIndex: peerIndex
                    ))
                }
            }

            var result: [(String, EventOverlapSlot)] = []
            for entry in entries {
                let myStart = max(entry.occurrence.range.start, visibleStart)
                let myEnd = min(entry.occurrence.range.end, visibleEnd)
                guard myEnd > myStart else {
                    result.append((entry.occurrence.id, .default))
                    continue
                }

                // Collect raw cover intervals from higher-depth events.
                // (Peers at same depth never cover each other.)
                var rawCovers: [Event.TimeRange] = []
                for other in entries where other.depth > entry.depth {
                    let oStart = max(other.occurrence.range.start, visibleStart)
                    let oEnd = min(other.occurrence.range.end, visibleEnd)
                    let overlapStart = max(myStart, oStart)
                    let overlapEnd = min(myEnd, oEnd)
                    guard overlapEnd > overlapStart else { continue }
                    rawCovers.append(Event.TimeRange(start: overlapStart, end: overlapEnd))
                }
                let mergedCovers = mergeTimeRanges(rawCovers)

                let depthFloat = CGFloat(entry.depth)
                let depthXStart = xStart + depthFloat * peekFraction
                let depthWidth = max(0, width - depthFloat * peekFraction)
                let myWidth = depthWidth / CGFloat(entry.peerCount)
                let myXOffset = depthXStart + CGFloat(entry.peerIndex) * myWidth
                let z = baseZ + Double(entry.depth) * 0.01

                let slot = EventOverlapSlot(
                    xOffsetFraction: myXOffset,
                    widthFraction: myWidth,
                    zIndex: z,
                    depth: entry.depth,
                    coverRanges: mergedCovers
                )
                result.append((entry.occurrence.id, slot))
            }
            return result
        }

        // Phase 2 (equal-split): Expand each packing group rightward into adjacent free columns
        var groupSpanEnd: [String: Int] = [:] // group.id → last column index (inclusive)
        for group in groups {
            let col = groupColumnAssignment[group.id] ?? 0

            var expandTo = col
            for nextCol in (col + 1)..<totalCols {
                // Check if any group in nextCol overlaps with this group.
                let blocked = columns[nextCol].contains { other in
                    group.start < other.end && other.start < group.end
                }
                if blocked { break }
                expandTo = nextCol
            }
            groupSpanEnd[group.id] = expandTo
        }

        // Phase 3 (equal-split): Build slots
        let colWidth = width / CGFloat(totalCols)
        var result: [(String, EventOverlapSlot)] = []
        for group in groups {
            let col = groupColumnAssignment[group.id] ?? 0
            let end = groupSpanEnd[group.id] ?? col
            let span = CGFloat(end - col + 1)
            let x = xStart + colWidth * CGFloat(col)
            let w = colWidth * span
            let slot = EventOverlapSlot(xOffsetFraction: x, widthFraction: w, zIndex: baseZ)
            for member in group.members {
                result.append((member.id, slot))
            }
        }

        return result
    }

    /// Merges overlapping/adjacent `Event.TimeRange` values into a minimal
    /// disjoint set, sorted by start. Used by stack-peek to consolidate cover
    /// intervals from multiple higher-depth siblings.
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
