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

enum CalendarLayout {
    /// Filters events that intersect with the provided day and sorts them for layout.
    static func eventsForDate(_ events: [Event], date: Date, calendar: Calendar = .current) -> [Event] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return events.filter { event in
            guard let start = event.startTime, let end = event.endTime else { return false }
            return end > dayStart && start < dayEnd
        }
    }

    /// Calculates the vertical offset for an event block by measuring how far past midnight it starts.
    static func yOffset(
        for event: Event,
        on date: Date,
        headerHeight: CGFloat,
        hourHeight: CGFloat,
        calendar: Calendar = .current
    ) -> CGFloat {
        let dayStart = calendar.startOfDay(for: date)
        let start = max(event.startTime ?? dayStart, dayStart)
        let seconds = max(0, start.timeIntervalSince(dayStart))
        return headerHeight + CGFloat(seconds / 3600) * hourHeight
    }

    /// Converts an event duration into a height in the timeline while enforcing a minimum visual size.
    static func eventHeight(
        for event: Event,
        on date: Date,
        minimumHeight: CGFloat,
        hourHeight: CGFloat,
        calendar: Calendar = .current
    ) -> CGFloat {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let start = max(event.startTime ?? dayStart, dayStart)
        let end = min(event.endTime ?? dayStart, dayEnd)
        let seconds = max(0, end.timeIntervalSince(start))
        return max(minimumHeight, CGFloat(seconds / 3600) * hourHeight)
    }

    /// Maps semantic event types to consistent colors used in the timeline.
    static func eventColor(for event: Event) -> Color {
        switch event.type {
        case "Study":
            return .green
        case "Work":
            return .blue
        case "Exercise":
            return .yellow
        case "Sleep":
            return .purple
        default:
            return Color(.systemGray5)
        }
    }
}
