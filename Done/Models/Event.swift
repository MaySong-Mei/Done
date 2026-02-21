//
//  Event.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation

struct Event: Identifiable, Codable, Hashable {
    struct TimeRange: Codable, Hashable {
        var start: Date
        var end: Date
    }
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

    var id: UUID
    var title: String
    var note: String
    var startTime: Date?
    var endTime: Date?
    var timeRanges: [TimeRange] = []
    var deadline: Date?
    var repeatUnit: RepeatUnit
    var isAllDay: Bool
    var isDone: Bool
    var repeatInterval: Int
    var repeatEndType: RepeatEndType
    var repeatEndDate: Date?
    var repeatEndCount: Int?
    var gridWidth: Int
    var gridHeight: Int
    var gridOrder: Int
    var gridX: Int?
    var gridY: Int?
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
    var timerStartedAt: Date?
    var linkedCalendarEventId: UUID?
    var linkedTodoEventId: UUID?
    var listID: UUID?

    var isTimerActive: Bool {
        timerStartedAt != nil
    }

    // Custom Decodable init for backward compatibility — isAllDay may be missing in old data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        note = try container.decode(String.self, forKey: .note)
        startTime = try container.decodeIfPresent(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        timeRanges = try container.decodeIfPresent([TimeRange].self, forKey: .timeRanges) ?? []
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        repeatUnit = try container.decode(RepeatUnit.self, forKey: .repeatUnit)
        isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        isDone = try container.decode(Bool.self, forKey: .isDone)
        repeatInterval = try container.decode(Int.self, forKey: .repeatInterval)
        repeatEndType = try container.decode(RepeatEndType.self, forKey: .repeatEndType)
        repeatEndDate = try container.decodeIfPresent(Date.self, forKey: .repeatEndDate)
        repeatEndCount = try container.decodeIfPresent(Int.self, forKey: .repeatEndCount)
        gridWidth = try container.decode(Int.self, forKey: .gridWidth)
        gridHeight = try container.decode(Int.self, forKey: .gridHeight)
        gridOrder = try container.decode(Int.self, forKey: .gridOrder)
        gridX = try container.decodeIfPresent(Int.self, forKey: .gridX)
        gridY = try container.decodeIfPresent(Int.self, forKey: .gridY)
        priority = try container.decode(Int.self, forKey: .priority)
        status = try container.decode(Status.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completeAt = try container.decodeIfPresent(Date.self, forKey: .completeAt)
        tags = try container.decode([String].self, forKey: .tags)
        type = try container.decode(String.self, forKey: .type)
        colorDepth = try container.decode(Double.self, forKey: .colorDepth)
        recurrenceParentId = try container.decodeIfPresent(UUID.self, forKey: .recurrenceParentId)
        recurrenceInstanceDate = try container.decodeIfPresent(Date.self, forKey: .recurrenceInstanceDate)
        recurrenceExceptionDates = try container.decodeIfPresent([Date].self, forKey: .recurrenceExceptionDates) ?? []
        timerStartedAt = try container.decodeIfPresent(Date.self, forKey: .timerStartedAt)
        linkedCalendarEventId = try container.decodeIfPresent(UUID.self, forKey: .linkedCalendarEventId)
        linkedTodoEventId = try container.decodeIfPresent(UUID.self, forKey: .linkedTodoEventId)
        listID = try container.decodeIfPresent(UUID.self, forKey: .listID)
    }

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        startTime: Date? = nil,
        endTime: Date? = nil,
        timeRanges: [TimeRange] = [],
        deadline: Date? = nil,
        repeatUnit: RepeatUnit = .none,
        isAllDay: Bool = false,
        isDone: Bool = false,
        repeatInterval: Int = 1,
        repeatEndType: RepeatEndType = .none,
        repeatEndDate: Date? = nil,
        repeatEndCount: Int? = nil,
        gridWidth: Int = 8,
        gridHeight: Int = 8,
        gridOrder: Int = 0,
        gridX: Int? = nil,
        gridY: Int? = nil,
        priority: Int = 1,
        status: Status = .active,
        createdAt: Date = Date(),
        completeAt: Date? = nil,
        tags: [String] = [],
        type: String = "",
        colorDepth: Double = 0.0,
        recurrenceParentId: UUID? = nil,
        recurrenceInstanceDate: Date? = nil,
        recurrenceExceptionDates: [Date] = [],
        timerStartedAt: Date? = nil,
        linkedCalendarEventId: UUID? = nil,
        linkedTodoEventId: UUID? = nil,
        listID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.startTime = startTime
        self.endTime = endTime
        self.timeRanges = timeRanges
        self.deadline = deadline
        self.repeatUnit = repeatUnit
        self.isAllDay = isAllDay
        self.isDone = isDone
        self.repeatInterval = repeatInterval
        self.repeatEndType = repeatEndType
        self.repeatEndDate = repeatEndDate
        self.repeatEndCount = repeatEndCount
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.gridOrder = gridOrder
        self.gridX = gridX
        self.gridY = gridY
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
        self.timerStartedAt = timerStartedAt
        self.linkedCalendarEventId = linkedCalendarEventId
        self.linkedTodoEventId = linkedTodoEventId
        self.listID = listID
    }

    var isRecurringSeries: Bool {
        repeatUnit != .none && recurrenceParentId == nil && recurrenceInstanceDate == nil
    }

    var isExceptionInstance: Bool {
        recurrenceParentId != nil && recurrenceInstanceDate != nil
    }

    var duration: TimeInterval {
        guard let range = primaryTimeRange else {
            return 0
        }
        return range.end.timeIntervalSince(range.start)
    }

    var effectiveTimeRanges: [TimeRange] {
        if !timeRanges.isEmpty {
            return timeRanges
        }
        guard let startTime, let endTime else {
            return []
        }
        return [TimeRange(start: startTime, end: endTime)]
    }

    var primaryTimeRange: TimeRange? {
        effectiveTimeRanges.first
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
        let occurrenceStart = dateByCombining(
            day: occurrenceDay,
            timeFrom: series.primaryTimeRange?.start,
            calendar: calendar
        )
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
            instance.timeRanges = [TimeRange(start: occurrenceStart, end: occurrenceEnd)]
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
            newSeries.timeRanges = [TimeRange(start: occurrenceStart, end: occurrenceEnd)]
            newSeries.createdAt = Date()
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

    static func dateByCombining(
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
