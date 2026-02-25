//
//  Event.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation

enum AgenticCreateSource: String, Codable, Hashable {
    case quickAdd
    case dragCreate
    case classicFallback
}

struct AgenticIntakeImageRef: Codable, Hashable, Identifiable {
    var id: UUID
    var relativePath: String
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSizeBytes: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        relativePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fileSizeBytes: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSizeBytes = fileSizeBytes
        self.createdAt = createdAt
    }
}

struct AgenticProviderMetadata: Codable, Hashable {
    var provider: String
    var model: String?
    var usedVision: Bool
    var createdAt: Date
    var sdkVersion: String?

    init(
        provider: String,
        model: String? = nil,
        usedVision: Bool,
        createdAt: Date = Date(),
        sdkVersion: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.usedVision = usedVision
        self.createdAt = createdAt
        self.sdkVersion = sdkVersion
    }
}

struct AgenticIntakeRecord: Codable, Hashable {
    var rawText: String
    var images: [AgenticIntakeImageRef]
    var source: AgenticCreateSource
    var providerMetadata: AgenticProviderMetadata?
    var warnings: [String]
    var createdAt: Date

    init(
        rawText: String,
        images: [AgenticIntakeImageRef] = [],
        source: AgenticCreateSource,
        providerMetadata: AgenticProviderMetadata? = nil,
        warnings: [String] = [],
        createdAt: Date = Date()
    ) {
        self.rawText = rawText
        self.images = images
        self.source = source
        self.providerMetadata = providerMetadata
        self.warnings = warnings
        self.createdAt = createdAt
    }
}

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
    var location: String
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
    var agenticIntake: AgenticIntakeRecord?

    var isTimerActive: Bool {
        timerStartedAt != nil
    }

    // Explicit CodingKeys — includes legacy grid fields so old data can still decode
    private enum CodingKeys: String, CodingKey {
        case id, title, note, location, startTime, endTime, timeRanges, deadline
        case repeatUnit, isAllDay, isDone, repeatInterval
        case repeatEndType, repeatEndDate, repeatEndCount
        case gridWidth, gridHeight, gridOrder, gridX, gridY // legacy, ignored
        case priority, status, createdAt, completeAt, tags, type, colorDepth
        case recurrenceParentId, recurrenceInstanceDate, recurrenceExceptionDates
        case timerStartedAt, linkedCalendarEventId, linkedTodoEventId, listID
        case agenticIntake
    }

    // Custom Decodable init for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        note = try container.decode(String.self, forKey: .note)
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
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
        // Legacy grid fields — skip during decoding (old data may contain them)
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
        agenticIntake = try container.decodeIfPresent(AgenticIntakeRecord.self, forKey: .agenticIntake)
    }

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        location: String = "",
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
        listID: UUID? = nil,
        agenticIntake: AgenticIntakeRecord? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.location = location
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
        self.agenticIntake = agenticIntake
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(note, forKey: .note)
        try container.encode(location, forKey: .location)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encode(timeRanges, forKey: .timeRanges)
        try container.encodeIfPresent(deadline, forKey: .deadline)
        try container.encode(repeatUnit, forKey: .repeatUnit)
        try container.encode(isAllDay, forKey: .isAllDay)
        try container.encode(isDone, forKey: .isDone)
        try container.encode(repeatInterval, forKey: .repeatInterval)
        try container.encode(repeatEndType, forKey: .repeatEndType)
        try container.encodeIfPresent(repeatEndDate, forKey: .repeatEndDate)
        try container.encodeIfPresent(repeatEndCount, forKey: .repeatEndCount)
        // grid fields intentionally omitted
        try container.encode(priority, forKey: .priority)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completeAt, forKey: .completeAt)
        try container.encode(tags, forKey: .tags)
        try container.encode(type, forKey: .type)
        try container.encode(colorDepth, forKey: .colorDepth)
        try container.encodeIfPresent(recurrenceParentId, forKey: .recurrenceParentId)
        try container.encodeIfPresent(recurrenceInstanceDate, forKey: .recurrenceInstanceDate)
        try container.encode(recurrenceExceptionDates, forKey: .recurrenceExceptionDates)
        try container.encodeIfPresent(timerStartedAt, forKey: .timerStartedAt)
        try container.encodeIfPresent(linkedCalendarEventId, forKey: .linkedCalendarEventId)
        try container.encodeIfPresent(linkedTodoEventId, forKey: .linkedTodoEventId)
        try container.encodeIfPresent(listID, forKey: .listID)
        try container.encodeIfPresent(agenticIntake, forKey: .agenticIntake)
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
