//
//  TimeEntry.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import Foundation

struct TimeEntry: Identifiable, Codable {
    let id: UUID
    let templateId: UUID
    var templateName: String
    var startTime: Date
    var endTime: Date?
    var colorHex: String
    var syncedToCalendar: Bool
    var calendarEventId: String?

    init(
        id: UUID = UUID(),
        templateId: UUID,
        templateName: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        colorHex: String,
        syncedToCalendar: Bool = false,
        calendarEventId: String? = nil
    ) {
        self.id = id
        self.templateId = templateId
        self.templateName = templateName
        self.startTime = startTime
        self.endTime = endTime
        self.colorHex = colorHex
        self.syncedToCalendar = syncedToCalendar
        self.calendarEventId = calendarEventId
    }

    var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    var isActive: Bool {
        endTime == nil
    }

    var durationString: String {
        guard let duration = duration else {
            return "In progress"
        }
        return duration.formatAsHoursMinutes()
    }
}
