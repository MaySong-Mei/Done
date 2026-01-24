//
//  TimelineInteractions.swift
//  Done
//
//  Shared helpers for mapping timeline gestures to dates and events.
//

import Foundation
import SwiftUI

enum TimelineInteractions {
    static func snappedDate(
        at locationY: CGFloat,
        day: Date,
        timelineTopInset: CGFloat,
        headerHeight: CGFloat,
        hourHeight: CGFloat,
        snapMinutes: Int,
        calendar: Calendar = .current
    ) -> Date? {
        let y = locationY - timelineTopInset - headerHeight
        guard hourHeight > 0 else { return nil }
        let minutesRaw = Int((y / hourHeight) * 60)
        let minutesClamped = max(0, min(24 * 60, minutesRaw))
        let snappedMinutes = snapMinutes > 0
            ? Int(round(Double(minutesClamped) / Double(snapMinutes))) * snapMinutes
            : minutesClamped
        return date(byAddingMinutes: snappedMinutes, to: calendar.startOfDay(for: day), calendar: calendar)
    }

    static func normalizedRange(
        start: Date,
        end: Date,
        minDurationMinutes: Int,
        snapMinutes: Int,
        calendar: Calendar = .current
    ) -> Event.TimeRange {
        var s = start
        var e = end
        if e < s {
            swap(&s, &e)
        }
        if snapMinutes > 0 {
            s = snap(date: s, minutes: snapMinutes, calendar: calendar)
            e = snap(date: e, minutes: snapMinutes, calendar: calendar)
        }
        if e <= s, minDurationMinutes > 0 {
            e = date(byAddingMinutes: minDurationMinutes, to: s, calendar: calendar)
        }
        return Event.TimeRange(start: s, end: e)
    }

    static func updateEvent(
        _ event: Event,
        replacing original: Event.TimeRange,
        with updated: Event.TimeRange
    ) -> Event {
        var updatedEvent = event
        if let index = updatedEvent.timeRanges.firstIndex(where: { $0.start == original.start && $0.end == original.end }) {
            updatedEvent.timeRanges[index] = updated
        } else if updatedEvent.timeRanges.isEmpty {
            updatedEvent.timeRanges = [updated]
        } else {
            updatedEvent.timeRanges.append(updated)
        }
        updatedEvent.timeRanges.sort { $0.start < $1.start }
        updatedEvent.startTime = updatedEvent.timeRanges.first?.start
        updatedEvent.endTime = updatedEvent.timeRanges.first?.end
        return updatedEvent
    }

    static func eventFrame(
        occurrence: CalendarLayout.EventOccurrence,
        date: Date,
        columnX: CGFloat,
        columnWidth: CGFloat,
        timelineTopInset: CGFloat,
        headerHeight: CGFloat,
        hourHeight: CGFloat,
        horizontalInset: CGFloat
    ) -> CGRect {
        let height = CalendarLayout.eventHeight(
            for: occurrence.range,
            on: date,
            minimumHeight: 12,
            hourHeight: hourHeight
        )
        let y = CalendarLayout.yOffset(
            for: occurrence.range,
            on: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight
        )
        return CGRect(
            x: columnX + horizontalInset,
            y: timelineTopInset + y,
            width: max(0, columnWidth - horizontalInset * 2),
            height: height
        )
    }

    static func snap(date: Date, minutes: Int, calendar: Calendar = .current) -> Date {
        guard minutes > 0 else { return date }
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        let snapped = Int(round(Double(minute) / Double(minutes))) * minutes
        var adjusted = DateComponents()
        adjusted.year = components.year
        adjusted.month = components.month
        adjusted.day = components.day
        adjusted.hour = components.hour
        adjusted.minute = snapped
        return calendar.date(from: adjusted) ?? date
    }

    static func date(byAddingMinutes minutes: Int, to date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .minute, value: minutes, to: date) ?? date
    }

    static func combine(day: Date, time: Date, calendar: Calendar = .current) -> Date {
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: time)
        var combined = DateComponents()
        combined.year = dayComponents.year
        combined.month = dayComponents.month
        combined.day = dayComponents.day
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute
        combined.second = timeComponents.second
        return calendar.date(from: combined) ?? day
    }
}
