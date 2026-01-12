//
//  Event.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation

struct Event: Identifiable, Codable, Hashable {
    enum RepeatUnit: String, Codable, Hashable {
        case none
        case day
        case week
        case month
        case year
    }

    enum RepeatEndType: String, Codable, Hashable {
        case none
        case onDate
        case afterCount
    }

    enum Status: String, Codable, Hashable {
        case active
        case completed
        case archived
    }

    enum RecurrenceEditScope {
        case single
        case following
        case all
    }

    struct RecurrenceEditResult {
        var updatedSeries: Event?
        var newSeries: Event?
        var exceptionInstance: Event?
    }

    let id: UUID
    var title: String
    var note: String
    var startTime: Date?
    var endTime: Date?
    var repeatUnit: RepeatUnit
    var isDone: Bool
    var repeatInterval: Int
    var repeatEndType: RepeatEndType
    var repeatEndDate: Date?
    var repeatEndCount: Int?
    var gridSize: Int
    var gridOrder: Int
    var priority: Int
    var status: Status
    var createdAt: Date
    var completeAt: Date?
    var tags: [String]
    var type: String
    var colorDepth: Double
    var recurrenceParentId: UUID?
    var recurrenceInstanceDate: Date?
    var recurrenceExceptionDates: [Date]

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        startTime: Date? = nil,
        endTime: Date? = nil,
        repeatUnit: RepeatUnit = .none,
        isDone: Bool = false,
        repeatInterval: Int = 1,
        repeatEndType: RepeatEndType = .none,
        repeatEndDate: Date? = nil,
        repeatEndCount: Int? = nil,
        gridSize: Int = 1,
        gridOrder: Int = 0,
        priority: Int = 1,
        status: Status = .active,
        createdAt: Date = Date(),
        completeAt: Date? = nil,
        tags: [String] = [],
        type: String = "",
        colorDepth: Double = 0.0,
        recurrenceParentId: UUID? = nil,
        recurrenceInstanceDate: Date? = nil,
        recurrenceExceptionDates: [Date] = []
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.startTime = startTime
        self.endTime = endTime
        self.repeatUnit = repeatUnit
        self.isDone = isDone
        self.repeatInterval = repeatInterval
        self.repeatEndType = repeatEndType
        self.repeatEndDate = repeatEndDate
        self.repeatEndCount = repeatEndCount
        self.gridSize = gridSize
        self.gridOrder = gridOrder
        self.priority = priority
        self.status = status
        self.createdAt = createdAt
        self.completeAt = completeAt
        self.tags = tags
        self.type = type
        self.colorDepth = colorDepth
        self.recurrenceParentId = recurrenceParentId
        self.recurrenceInstanceDate = recurrenceInstanceDate
        self.recurrenceExceptionDates = recurrenceExceptionDates
    }

    var isRecurringSeries: Bool {
        repeatUnit != .none && recurrenceParentId == nil && recurrenceInstanceDate == nil
    }

    var isExceptionInstance: Bool {
        recurrenceParentId != nil && recurrenceInstanceDate != nil
    }

    var duration: TimeInterval {
        guard let startTime, let endTime else {
            return 0
        }
        return endTime.timeIntervalSince(startTime)
    }

    static func applyEdit(
        series: Event,
        occurrenceDate: Date,
        scope: RecurrenceEditScope,
        edit: (inout Event) -> Void,
        calendar: Calendar = .current
    ) -> RecurrenceEditResult {
        guard series.isRecurringSeries else {
            var updated = series
            edit(&updated)
            return RecurrenceEditResult(updatedSeries: updated, newSeries: nil, exceptionInstance: nil)
        }

        let occurrenceDay = calendar.startOfDay(for: occurrenceDate)
        let occurrenceStart = dateByCombining(day: occurrenceDay, timeFrom: series.startTime, calendar: calendar)
        let occurrenceEnd = occurrenceStart.addingTimeInterval(series.duration)

        switch scope {
        case .all:
            var updated = series
            edit(&updated)
            return RecurrenceEditResult(updatedSeries: updated, newSeries: nil, exceptionInstance: nil)

        case .single:
            var updatedSeries = series
            updatedSeries.recurrenceExceptionDates.append(occurrenceDay)

            var instance = series
            instance.id = UUID()
            instance.startTime = occurrenceStart
            instance.endTime = occurrenceEnd
            instance.repeatUnit = .none
            instance.repeatInterval = 1
            instance.repeatEndType = .none
            instance.repeatEndDate = nil
            instance.repeatEndCount = nil
            instance.recurrenceParentId = series.id
            instance.recurrenceInstanceDate = occurrenceDay
            instance.recurrenceExceptionDates = []
            edit(&instance)

            return RecurrenceEditResult(
                updatedSeries: updatedSeries,
                newSeries: nil,
                exceptionInstance: instance
            )

        case .following:
            var updatedSeries = series
            let endCutoff = calendar.date(byAdding: .day, value: -1, to: occurrenceDay)
            updatedSeries.repeatEndType = .onDate
            updatedSeries.repeatEndDate = endCutoff

            var newSeries = series
            newSeries.id = UUID()
            newSeries.startTime = occurrenceStart
            newSeries.endTime = occurrenceEnd
            newSeries.createAt = Date()
            newSeries.recurrenceParentId = nil
            newSeries.recurrenceInstanceDate = nil
            newSeries.recurrenceExceptionDates = []
            edit(&newSeries)

            return RecurrenceEditResult(
                updatedSeries: updatedSeries,
                newSeries: newSeries,
                exceptionInstance: nil
            )
        }
    }

    private static func dateByCombining(
        day: Date,
        timeFrom: Date?,
        calendar: Calendar
    ) -> Date {
        guard let timeFrom else {
            return day
        }
        let time = calendar.dateComponents([.hour, .minute, .second], from: timeFrom)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: day
        ) ?? day
    }
}
