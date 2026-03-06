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
    struct EventOccurrence: Identifiable {
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
        calendar: Calendar = .current
    ) -> CGFloat {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let start = max(range.start, dayStart)
        let end = min(range.end, dayEnd)
        let seconds = max(0, end.timeIntervalSince(start))
        return max(minimumHeight, CGFloat(seconds / 3600) * hourHeight)
    }

    /// 功能： Maps semantic event types to consistent colors used in the timeline.
    static func eventColor(for event: Event) -> Color {
        EventTypeTemplateStore.color(for: event.type)
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
    struct EventOverlapSlot {
        let xOffsetFraction: CGFloat  // [0, 1)
        let widthFraction: CGFloat    // (0, 1]
        let zIndex: Double

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
        calendar: Calendar = .current
    ) -> [String: EventOverlapSlot] {
        guard occurrences.count > 1 else {
            var result: [String: EventOverlapSlot] = [:]
            for occ in occurrences {
                result[occ.id] = .default
            }
            return result
        }

        // Phase 1: Find overlap clusters via adjacency + DFS
        let clusters = findOverlapClusters(occurrences, on: date, calendar: calendar)

        // Phase 2: Layout each cluster
        var result: [String: EventOverlapSlot] = [:]
        for cluster in clusters {
            if cluster.count == 1 {
                result[cluster[0].id] = .default
            } else {
                let slots = layoutCluster(cluster, on: date, xStart: 0, width: 1, baseZ: 1, calendar: calendar)
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
        on date: Date,
        calendar: Calendar
    ) -> [[EventOccurrence]] {
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

        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Check pairwise overlap
        for i in 0..<n {
            let si = max(occurrences[i].range.start, dayStart)
            let ei = min(occurrences[i].range.end, dayEnd)
            for j in (i + 1)..<n {
                let sj = max(occurrences[j].range.start, dayStart)
                let ej = min(occurrences[j].range.end, dayEnd)
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

    /// Lays out a cluster of overlapping events using greedy column packing
    /// with rightward expansion into free adjacent columns.
    private static func layoutCluster(
        _ cluster: [EventOccurrence],
        on date: Date,
        xStart: CGFloat,
        width: CGFloat,
        baseZ: Double,
        calendar: Calendar
    ) -> [(String, EventOverlapSlot)] {
        guard !cluster.isEmpty else { return [] }
        if cluster.count == 1 {
            return [(cluster[0].id, EventOverlapSlot(xOffsetFraction: xStart, widthFraction: width, zIndex: baseZ))]
        }

        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Sort by start time, then by duration descending (longer events first)
        let sorted = cluster.sorted { a, b in
            let sa = max(a.range.start, dayStart)
            let sb = max(b.range.start, dayStart)
            if sa != sb { return sa < sb }
            let da = min(a.range.end, dayEnd).timeIntervalSince(sa)
            let db = min(b.range.end, dayEnd).timeIntervalSince(sb)
            return da > db
        }

        // Phase 1: Greedy column packing — minimize total columns
        var columnAssignment: [String: Int] = [:]
        var columns: [[EventOccurrence]] = [] // events in each column
        var columnEnds: [Date] = []

        for occ in sorted {
            let start = max(occ.range.start, dayStart)
            let end = min(occ.range.end, dayEnd)
            var assigned = false
            for col in 0..<columnEnds.count {
                if start >= columnEnds[col] {
                    columnAssignment[occ.id] = col
                    columns[col].append(occ)
                    columnEnds[col] = end
                    assigned = true
                    break
                }
            }
            if !assigned {
                columnAssignment[occ.id] = columns.count
                columns.append([occ])
                columnEnds.append(end)
            }
        }

        let totalCols = columns.count

        // Phase 2: Expand each event rightward into adjacent free columns
        var spanEnd: [String: Int] = [:] // occ.id → last column index (inclusive)
        for occ in cluster {
            let col = columnAssignment[occ.id] ?? 0
            let occStart = max(occ.range.start, dayStart)
            let occEnd = min(occ.range.end, dayEnd)

            var expandTo = col
            for nextCol in (col + 1)..<totalCols {
                // Check if any event in nextCol overlaps with this event
                let blocked = columns[nextCol].contains { other in
                    let otherStart = max(other.range.start, dayStart)
                    let otherEnd = min(other.range.end, dayEnd)
                    return occStart < otherEnd && otherStart < occEnd
                }
                if blocked { break }
                expandTo = nextCol
            }
            spanEnd[occ.id] = expandTo
        }

        // Phase 3: Build slots
        let colWidth = width / CGFloat(totalCols)
        var result: [(String, EventOverlapSlot)] = []
        for occ in cluster {
            let col = columnAssignment[occ.id] ?? 0
            let end = spanEnd[occ.id] ?? col
            let span = CGFloat(end - col + 1)
            let x = xStart + colWidth * CGFloat(col)
            let w = colWidth * span
            result.append((occ.id, EventOverlapSlot(xOffsetFraction: x, widthFraction: w, zIndex: baseZ)))
        }

        return result
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
        let clampedMinutes = max(0, min(24 * 60, snappedMinutes))

        return dayStart.addingTimeInterval(clampedMinutes * 60)
    }
}
