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
