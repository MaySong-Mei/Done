import Foundation

struct CloudMCPServerConfig: Hashable, Codable {
    enum DataSource: String, Hashable, Codable {
        case rawMirror
        case queryProjection
    }

    var bindHost: String
    var port: Int
    var schemaVersion: Int
    var dataSource: DataSource
    var auditLoggingEnabled: Bool

    init(
        bindHost: String = "127.0.0.1",
        port: Int = 8080,
        schemaVersion: Int = 1,
        dataSource: DataSource = .queryProjection,
        auditLoggingEnabled: Bool = true
    ) {
        self.bindHost = bindHost
        self.port = port
        self.schemaVersion = schemaVersion
        self.dataSource = dataSource
        self.auditLoggingEnabled = auditLoggingEnabled
    }
}

enum CloudMCPTokenScope: String, Codable, Hashable {
    case syncWrite
    case mcpRead
}

struct CloudMCPTokenRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var userID: UUID
    var label: String
    var rawToken: String
    var scope: CloudMCPTokenScope
    var createdAt: Date
    var revokedAt: Date?

    init(
        id: UUID = UUID(),
        userID: UUID,
        label: String,
        rawToken: String,
        scope: CloudMCPTokenScope,
        createdAt: Date = Date(),
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.label = label
        self.rawToken = rawToken
        self.scope = scope
        self.createdAt = createdAt
        self.revokedAt = revokedAt
    }

    var isRevoked: Bool {
        revokedAt != nil
    }

    func authorizes(_ requiredScope: CloudMCPTokenScope) -> Bool {
        revokedAt == nil && scope == requiredScope
    }
}

struct CloudMCPTokenRegistry: Codable, Hashable {
    private(set) var tokensByRawValue: [String: CloudMCPTokenRecord] = [:]

    mutating func register(_ token: CloudMCPTokenRecord) {
        tokensByRawValue[token.rawToken] = token
    }

    mutating func revoke(rawToken: String, at date: Date = Date()) -> Bool {
        guard var token = tokensByRawValue[rawToken], token.revokedAt == nil else {
            return false
        }
        token.revokedAt = date
        tokensByRawValue[rawToken] = token
        return true
    }

    func authorizedToken(
        rawToken: String,
        requiredScope: CloudMCPTokenScope
    ) -> CloudMCPTokenRecord? {
        guard let token = tokensByRawValue[rawToken], token.authorizes(requiredScope) else {
            return nil
        }
        return token
    }
}

enum CloudMCPServerError: Error, Equatable {
    case unauthorized
    case mixedUsersInBatch
    case schemaVersionMismatch(expected: Int, received: Int)
    case missingPayload(CloudMCPSyncEntityType)
    case unexpectedPayloadForDelete(CloudMCPSyncEntityType)
    case payloadTypeMismatch(expected: CloudMCPSyncEntityType)
    case entityIDMismatch(expected: String, received: String)
    case invalidEntityID(String)
}

enum CloudMCPSyncEntityType: String, Codable, Hashable {
    case calendarEvent
    case occurrenceLog
}

enum CloudMCPSyncOperation: String, Codable, Hashable {
    case upsert
    case delete
}

enum CloudMCPSyncPayload: Codable, Hashable {
    case calendarEvent(Event)
    case occurrenceLog(CalendarEventLogRecord)

    private enum CodingKeys: String, CodingKey {
        case kind
        case calendarEvent
        case occurrenceLog
    }

    private enum Kind: String, Codable {
        case calendarEvent
        case occurrenceLog
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .calendarEvent:
            self = .calendarEvent(try container.decode(Event.self, forKey: .calendarEvent))
        case .occurrenceLog:
            self = .occurrenceLog(try container.decode(CalendarEventLogRecord.self, forKey: .occurrenceLog))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .calendarEvent(let event):
            try container.encode(Kind.calendarEvent, forKey: .kind)
            try container.encode(event, forKey: .calendarEvent)
        case .occurrenceLog(let record):
            try container.encode(Kind.occurrenceLog, forKey: .kind)
            try container.encode(record, forKey: .occurrenceLog)
        }
    }

    var entityType: CloudMCPSyncEntityType {
        switch self {
        case .calendarEvent:
            return .calendarEvent
        case .occurrenceLog:
            return .occurrenceLog
        }
    }

    var calendarEventValue: Event? {
        guard case .calendarEvent(let event) = self else { return nil }
        return event
    }

    var occurrenceLogValue: CalendarEventLogRecord? {
        guard case .occurrenceLog(let record) = self else { return nil }
        return record
    }
}

struct CloudMCPSyncEnvelope: Identifiable, Codable, Hashable {
    var userID: UUID
    var deviceID: UUID
    var schemaVersion: Int
    var sentAt: Date
    var entityType: CloudMCPSyncEntityType
    var entityID: String
    var updatedAt: Date
    var operation: CloudMCPSyncOperation
    var payload: CloudMCPSyncPayload?

    var id: String {
        "\(entityType.rawValue)-\(entityID)-\(Int(updatedAt.timeIntervalSince1970))-\(operation.rawValue)"
    }

    init(
        userID: UUID,
        deviceID: UUID,
        schemaVersion: Int,
        sentAt: Date,
        entityType: CloudMCPSyncEntityType,
        entityID: String,
        updatedAt: Date,
        operation: CloudMCPSyncOperation,
        payload: CloudMCPSyncPayload?
    ) throws {
        self.userID = userID
        self.deviceID = deviceID
        self.schemaVersion = schemaVersion
        self.sentAt = sentAt
        self.entityType = entityType
        self.entityID = entityID
        self.updatedAt = updatedAt
        self.operation = operation
        self.payload = payload
        try validate()
    }

    static func upsertEvent(
        _ event: Event,
        userID: UUID,
        deviceID: UUID,
        schemaVersion: Int,
        sentAt: Date,
        updatedAt: Date
    ) throws -> CloudMCPSyncEnvelope {
        try CloudMCPSyncEnvelope(
            userID: userID,
            deviceID: deviceID,
            schemaVersion: schemaVersion,
            sentAt: sentAt,
            entityType: .calendarEvent,
            entityID: event.id.uuidString,
            updatedAt: updatedAt,
            operation: .upsert,
            payload: .calendarEvent(event)
        )
    }

    static func deleteEvent(
        eventID: UUID,
        userID: UUID,
        deviceID: UUID,
        schemaVersion: Int,
        sentAt: Date,
        updatedAt: Date
    ) throws -> CloudMCPSyncEnvelope {
        try CloudMCPSyncEnvelope(
            userID: userID,
            deviceID: deviceID,
            schemaVersion: schemaVersion,
            sentAt: sentAt,
            entityType: .calendarEvent,
            entityID: eventID.uuidString,
            updatedAt: updatedAt,
            operation: .delete,
            payload: nil
        )
    }

    static func upsertOccurrenceLog(
        _ record: CalendarEventLogRecord,
        userID: UUID,
        deviceID: UUID,
        schemaVersion: Int,
        sentAt: Date,
        updatedAt: Date
    ) throws -> CloudMCPSyncEnvelope {
        try CloudMCPSyncEnvelope(
            userID: userID,
            deviceID: deviceID,
            schemaVersion: schemaVersion,
            sentAt: sentAt,
            entityType: .occurrenceLog,
            entityID: record.id.cloudMCPEntityID,
            updatedAt: updatedAt,
            operation: .upsert,
            payload: .occurrenceLog(record)
        )
    }

    static func deleteOccurrenceLog(
        occurrenceKey: CalendarOccurrenceKey,
        userID: UUID,
        deviceID: UUID,
        schemaVersion: Int,
        sentAt: Date,
        updatedAt: Date
    ) throws -> CloudMCPSyncEnvelope {
        try CloudMCPSyncEnvelope(
            userID: userID,
            deviceID: deviceID,
            schemaVersion: schemaVersion,
            sentAt: sentAt,
            entityType: .occurrenceLog,
            entityID: occurrenceKey.cloudMCPEntityID,
            updatedAt: updatedAt,
            operation: .delete,
            payload: nil
        )
    }

    private func validate() throws {
        switch operation {
        case .upsert:
            guard let payload else {
                throw CloudMCPServerError.missingPayload(entityType)
            }
            guard payload.entityType == entityType else {
                throw CloudMCPServerError.payloadTypeMismatch(expected: entityType)
            }
            switch payload {
            case .calendarEvent(let event):
                let expected = event.id.uuidString
                guard expected == entityID else {
                    throw CloudMCPServerError.entityIDMismatch(expected: expected, received: entityID)
                }
            case .occurrenceLog(let record):
                let expected = record.id.cloudMCPEntityID
                guard expected == entityID else {
                    throw CloudMCPServerError.entityIDMismatch(expected: expected, received: entityID)
                }
            }
        case .delete:
            guard payload == nil else {
                throw CloudMCPServerError.unexpectedPayloadForDelete(entityType)
            }
        }
    }
}

struct CloudMCPSyncBatch: Codable, Hashable {
    var schemaVersion: Int
    var sentAt: Date
    var envelopes: [CloudMCPSyncEnvelope]

    @MainActor
    static func fullSnapshot(
        from store: EventStore,
        userID: UUID,
        deviceID: UUID,
        schemaVersion: Int = 1,
        sentAt: Date = Date()
    ) throws -> CloudMCPSyncBatch {
        let eventEnvelopes = try store.calendarEvents.map { event in
            try CloudMCPSyncEnvelope.upsertEvent(
                event,
                userID: userID,
                deviceID: deviceID,
                schemaVersion: schemaVersion,
                sentAt: sentAt,
                updatedAt: sentAt
            )
        }
        let logEnvelopes = try store.calendarEventLogRecords.map { record in
            try CloudMCPSyncEnvelope.upsertOccurrenceLog(
                record,
                userID: userID,
                deviceID: deviceID,
                schemaVersion: schemaVersion,
                sentAt: sentAt,
                updatedAt: record.updatedAt
            )
        }
        return CloudMCPSyncBatch(
            schemaVersion: schemaVersion,
            sentAt: sentAt,
            envelopes: (eventEnvelopes + logEnvelopes).sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.entityID < $1.entityID
                }
                return $0.updatedAt < $1.updatedAt
            }
        )
    }
}

struct CloudMirroredCalendarEventRecord: Codable, Hashable {
    var entityID: UUID
    var event: Event?
    var updatedAt: Date
    var deletedAt: Date?
    var sourceDeviceID: UUID
    var sentAt: Date

    var isDeleted: Bool {
        deletedAt != nil || event == nil
    }
}

struct CloudMirroredOccurrenceLogRecord: Codable, Hashable {
    var entityID: String
    var occurrenceKey: CalendarOccurrenceKey
    var record: CalendarEventLogRecord?
    var updatedAt: Date
    var deletedAt: Date?
    var sourceDeviceID: UUID
    var sentAt: Date

    var isDeleted: Bool {
        deletedAt != nil || record == nil
    }
}

struct CloudEventRawMirrorApplyResult: Codable, Hashable {
    var appliedCount: Int
    var ignoredCount: Int
}

struct CloudEventRawMirrorStore: Codable, Hashable {
    var userID: UUID
    var schemaVersion: Int
    private(set) var calendarEventRecords: [UUID: CloudMirroredCalendarEventRecord]
    private(set) var occurrenceLogRecords: [String: CloudMirroredOccurrenceLogRecord]

    init(
        userID: UUID,
        schemaVersion: Int,
        calendarEventRecords: [UUID: CloudMirroredCalendarEventRecord] = [:],
        occurrenceLogRecords: [String: CloudMirroredOccurrenceLogRecord] = [:]
    ) {
        self.userID = userID
        self.schemaVersion = schemaVersion
        self.calendarEventRecords = calendarEventRecords
        self.occurrenceLogRecords = occurrenceLogRecords
    }

    var activeCalendarEventRecords: [CloudMirroredCalendarEventRecord] {
        calendarEventRecords.values
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                let lhsStart = lhs.event?.primaryTimeRange?.start ?? lhs.event?.createdAt ?? .distantPast
                let rhsStart = rhs.event?.primaryTimeRange?.start ?? rhs.event?.createdAt ?? .distantPast
                if lhsStart == rhsStart {
                    return lhs.entityID.uuidString < rhs.entityID.uuidString
                }
                return lhsStart < rhsStart
            }
    }

    var activeOccurrenceLogRecords: [CloudMirroredOccurrenceLogRecord] {
        occurrenceLogRecords.values
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                let lhsDate = lhs.record?.occurrenceDate ?? .distantPast
                let rhsDate = rhs.record?.occurrenceDate ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.entityID < rhs.entityID
                }
                return lhsDate < rhsDate
            }
    }

    mutating func apply(_ envelopes: [CloudMCPSyncEnvelope]) throws -> CloudEventRawMirrorApplyResult {
        var appliedCount = 0
        var ignoredCount = 0

        for envelope in envelopes {
            guard envelope.userID == userID else {
                throw CloudMCPServerError.mixedUsersInBatch
            }
            guard envelope.schemaVersion == schemaVersion else {
                throw CloudMCPServerError.schemaVersionMismatch(
                    expected: schemaVersion,
                    received: envelope.schemaVersion
                )
            }

            let didApply: Bool
            switch envelope.entityType {
            case .calendarEvent:
                didApply = try applyCalendarEventEnvelope(envelope)
            case .occurrenceLog:
                didApply = try applyOccurrenceLogEnvelope(envelope)
            }

            if didApply {
                appliedCount += 1
            } else {
                ignoredCount += 1
            }
        }

        return CloudEventRawMirrorApplyResult(
            appliedCount: appliedCount,
            ignoredCount: ignoredCount
        )
    }

    private mutating func applyCalendarEventEnvelope(_ envelope: CloudMCPSyncEnvelope) throws -> Bool {
        let entityID = try parseEventID(envelope.entityID)
        let existing = calendarEventRecords[entityID]
        if let existing, existing.updatedAt > envelope.updatedAt {
            return false
        }

        switch envelope.operation {
        case .upsert:
            guard let event = envelope.payload?.calendarEventValue else {
                throw CloudMCPServerError.missingPayload(.calendarEvent)
            }
            if let existing,
               existing.updatedAt == envelope.updatedAt,
               existing.deletedAt == nil,
               existing.event == event {
                return false
            }
            calendarEventRecords[entityID] = CloudMirroredCalendarEventRecord(
                entityID: entityID,
                event: event,
                updatedAt: envelope.updatedAt,
                deletedAt: nil,
                sourceDeviceID: envelope.deviceID,
                sentAt: envelope.sentAt
            )
            return true
        case .delete:
            if let existing, existing.updatedAt == envelope.updatedAt, existing.isDeleted {
                return false
            }
            calendarEventRecords[entityID] = CloudMirroredCalendarEventRecord(
                entityID: entityID,
                event: nil,
                updatedAt: envelope.updatedAt,
                deletedAt: envelope.updatedAt,
                sourceDeviceID: envelope.deviceID,
                sentAt: envelope.sentAt
            )
            return true
        }
    }

    private mutating func applyOccurrenceLogEnvelope(_ envelope: CloudMCPSyncEnvelope) throws -> Bool {
        let occurrenceKey = try parseOccurrenceKey(envelope.entityID)
        let existing = occurrenceLogRecords[occurrenceKey.cloudMCPEntityID]
        if let existing, existing.updatedAt > envelope.updatedAt {
            return false
        }

        switch envelope.operation {
        case .upsert:
            guard let record = envelope.payload?.occurrenceLogValue else {
                throw CloudMCPServerError.missingPayload(.occurrenceLog)
            }
            if let existing,
               existing.updatedAt == envelope.updatedAt,
               existing.deletedAt == nil,
               existing.record == record {
                return false
            }
            occurrenceLogRecords[occurrenceKey.cloudMCPEntityID] = CloudMirroredOccurrenceLogRecord(
                entityID: occurrenceKey.cloudMCPEntityID,
                occurrenceKey: occurrenceKey,
                record: record,
                updatedAt: envelope.updatedAt,
                deletedAt: nil,
                sourceDeviceID: envelope.deviceID,
                sentAt: envelope.sentAt
            )
            return true
        case .delete:
            if let existing, existing.updatedAt == envelope.updatedAt, existing.isDeleted {
                return false
            }
            occurrenceLogRecords[occurrenceKey.cloudMCPEntityID] = CloudMirroredOccurrenceLogRecord(
                entityID: occurrenceKey.cloudMCPEntityID,
                occurrenceKey: occurrenceKey,
                record: nil,
                updatedAt: envelope.updatedAt,
                deletedAt: envelope.updatedAt,
                sourceDeviceID: envelope.deviceID,
                sentAt: envelope.sentAt
            )
            return true
        }
    }

    private func parseEventID(_ rawValue: String) throws -> UUID {
        guard let uuid = UUID(uuidString: rawValue) else {
            throw CloudMCPServerError.invalidEntityID(rawValue)
        }
        return uuid
    }

    private func parseOccurrenceKey(_ rawValue: String) throws -> CalendarOccurrenceKey {
        guard let key = CalendarOccurrenceKey(cloudMCPEntityID: rawValue) else {
            throw CloudMCPServerError.invalidEntityID(rawValue)
        }
        return key
    }
}

struct CloudMCPProjectedEvent: Codable, Hashable, Identifiable {
    var event: Event
    var mirroredAt: Date
    var sourceDeviceID: UUID

    var id: UUID {
        event.id
    }

    var snapshot: CloudCalendarEventSnapshot {
        CloudCalendarEventSnapshot(
            id: event.id,
            title: event.title,
            note: event.note,
            location: event.location,
            timeRanges: event.timeRanges,
            deadline: event.deadline,
            repeatUnit: event.repeatUnit,
            isAllDay: event.isAllDay,
            isDone: event.isDone,
            repeatInterval: event.repeatInterval,
            repeatEndType: event.repeatEndType,
            repeatEndDate: event.repeatEndDate,
            repeatEndCount: event.repeatEndCount,
            priority: event.priority,
            status: event.status,
            createdAt: event.createdAt,
            completeAt: event.completeAt,
            tags: event.tags,
            type: event.type,
            recurrenceParentId: event.recurrenceParentId,
            recurrenceInstanceDate: event.recurrenceInstanceDate,
            displayKind: event.displayKind,
            interruptRelation: event.interruptRelation,
            mirroredAt: mirroredAt,
            sourceDeviceID: sourceDeviceID
        )
    }
}

struct CloudMCPProjectedOccurrenceLog: Codable, Hashable, Identifiable {
    var occurrenceKey: CalendarOccurrenceKey
    var record: CalendarEventLogRecord
    var mirroredAt: Date
    var sourceDeviceID: UUID

    var id: String {
        occurrenceKey.cloudMCPEntityID
    }

    var snapshot: CloudOccurrenceLogSnapshot {
        CloudOccurrenceLogSnapshot(
            occurrenceKey: occurrenceKey,
            eventID: record.eventID,
            baseSeriesEventID: record.baseSeriesEventID,
            occurrenceDate: record.occurrenceDate,
            suggestedTemplateID: record.suggestedTemplateID,
            selectedTemplateID: record.selectedTemplateID,
            completionStatus: record.completionStatus,
            actualDurationMinutes: record.actualDurationMinutes,
            summary: record.summary,
            note: record.note,
            effort: record.effort,
            emotions: record.emotions,
            behaviors: record.behaviors,
            templateAnswers: record.templateAnswers,
            timelineItems: record.timelineItems.sorted { $0.createdAt > $1.createdAt },
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            mirroredAt: mirroredAt,
            sourceDeviceID: sourceDeviceID
        )
    }
}

struct CloudMCPProjection: Codable, Hashable {
    var userID: UUID
    var schemaVersion: Int
    var rebuiltAt: Date
    var eventsByID: [UUID: CloudMCPProjectedEvent]
    var occurrenceLogsByID: [String: CloudMCPProjectedOccurrenceLog]

    var dataUpdatedAt: Date? {
        let eventDates = eventsByID.values.map(\.mirroredAt)
        let logDates = occurrenceLogsByID.values.map(\.mirroredAt)
        return (eventDates + logDates).max()
    }
}

enum CloudMCPProjectionBuilder {
    static func build(
        from rawMirror: CloudEventRawMirrorStore,
        rebuiltAt: Date = Date()
    ) -> CloudMCPProjection {
        let projectedEventsPairs: [(UUID, CloudMCPProjectedEvent)] = rawMirror.activeCalendarEventRecords.compactMap { record in
            guard let event = record.event else { return nil }
            let projected = CloudMCPProjectedEvent(
                event: event,
                mirroredAt: record.updatedAt,
                sourceDeviceID: record.sourceDeviceID
            )
            return (projected.id, projected)
        }
        let projectedEvents = Dictionary(uniqueKeysWithValues: projectedEventsPairs)

        let activeEventIDs = Set(projectedEvents.keys)
        let projectedLogPairs: [(String, CloudMCPProjectedOccurrenceLog)] = rawMirror.activeOccurrenceLogRecords.compactMap { record in
            guard let logRecord = record.record else { return nil }
            let anchorEventID = logRecord.baseSeriesEventID ?? logRecord.eventID
            guard activeEventIDs.contains(anchorEventID) || activeEventIDs.contains(logRecord.eventID) else {
                return nil
            }
            let projected = CloudMCPProjectedOccurrenceLog(
                occurrenceKey: record.occurrenceKey,
                record: logRecord,
                mirroredAt: record.updatedAt,
                sourceDeviceID: record.sourceDeviceID
            )
            return (projected.id, projected)
        }
        let projectedLogs = Dictionary(uniqueKeysWithValues: projectedLogPairs)

        return CloudMCPProjection(
            userID: rawMirror.userID,
            schemaVersion: rawMirror.schemaVersion,
            rebuiltAt: rebuiltAt,
            eventsByID: projectedEvents,
            occurrenceLogsByID: projectedLogs
        )
    }
}

struct CloudCalendarEventSnapshot: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var note: String
    var location: String
    var timeRanges: [Event.TimeRange]
    var deadline: Date?
    var repeatUnit: Event.RepeatUnit
    var isAllDay: Bool
    var isDone: Bool
    var repeatInterval: Int
    var repeatEndType: Event.RepeatEndType
    var repeatEndDate: Date?
    var repeatEndCount: Int?
    var priority: Int
    var status: Event.Status
    var createdAt: Date
    var completeAt: Date?
    var tags: [String]
    var type: String
    var recurrenceParentId: UUID?
    var recurrenceInstanceDate: Date?
    var displayKind: EventDisplayKind
    var interruptRelation: EventInterruptRelation?
    var mirroredAt: Date
    var sourceDeviceID: UUID

    var isRecurringSeries: Bool {
        repeatUnit != .none && recurrenceParentId == nil && recurrenceInstanceDate == nil
    }
}

struct CloudCalendarOccurrenceSnapshot: Identifiable, Codable, Hashable {
    var eventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date
    var title: String
    var type: String
    var tags: [String]
    var start: Date
    var end: Date
    var isAllDay: Bool
    var displayKind: EventDisplayKind
    var interruptRelation: EventInterruptRelation?
    var hasLog: Bool
    var logUpdatedAt: Date?
    var mirroredAt: Date

    var id: String {
        "\(eventID.uuidString)-\(Int(occurrenceDate.timeIntervalSince1970))-\(Int(start.timeIntervalSince1970))"
    }
}

struct CloudOccurrenceLogSnapshot: Identifiable, Codable, Hashable {
    var occurrenceKey: CalendarOccurrenceKey
    var eventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date
    var suggestedTemplateID: String?
    var selectedTemplateID: String?
    var completionStatus: EventLogCompletionStatus?
    var actualDurationMinutes: Int?
    var summary: String
    var note: String
    var effort: Int?
    var emotions: [String]
    var behaviors: [String]
    var templateAnswers: [String: EventLogAnswerValue]
    var timelineItems: [EventLogTimelineItem]
    var createdAt: Date
    var updatedAt: Date
    var mirroredAt: Date
    var sourceDeviceID: UUID

    var id: String {
        occurrenceKey.cloudMCPEntityID
    }
}

struct CloudTimelineNoteSearchHit: Identifiable, Codable, Hashable {
    var note: EventLogTimelineNote
    var eventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date
    var eventTitle: String
    var eventType: String

    var id: UUID {
        note.id
    }
}

enum CloudEventTextField: String, CaseIterable, Codable, Hashable {
    case eventNote
    case logSummary
    case logNote
    case timelineNote
}

struct CloudEventTextSearchHit: Identifiable, Codable, Hashable {
    var field: CloudEventTextField
    var eventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date?
    var eventTitle: String
    var text: String

    var id: String {
        let occurrenceToken = occurrenceDate.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "\(field.rawValue)-\(eventID.uuidString)-\(occurrenceToken)-\(text.hashValue)"
    }
}

struct CloudDayScheduleSnapshot: Codable, Hashable {
    var date: Date
    var allDayOccurrences: [CloudCalendarOccurrenceSnapshot]
    var timedOccurrences: [CloudCalendarOccurrenceSnapshot]
}

struct CloudCalendarOccurrenceFilters: Hashable, Codable {
    var eventID: UUID?
    var type: String?
    var tags: [String]
    var updatedSince: Date?

    init(
        eventID: UUID? = nil,
        type: String? = nil,
        tags: [String] = [],
        updatedSince: Date? = nil
    ) {
        self.eventID = eventID
        self.type = type
        self.tags = tags
        self.updatedSince = updatedSince
    }
}

struct CloudMCPQueryService {
    let projection: CloudMCPProjection
    let calendar: Calendar

    init(
        projection: CloudMCPProjection,
        calendar: Calendar = .current
    ) {
        self.projection = projection
        self.calendar = calendar
    }

    func getCalendarEvent(id: UUID) -> CloudCalendarEventSnapshot? {
        projection.eventsByID[id]?.snapshot
    }

    func getOccurrenceLog(
        eventID: UUID,
        occurrenceDate: Date
    ) -> CloudOccurrenceLogSnapshot? {
        let day = calendar.startOfDay(for: occurrenceDate)

        if let event = projection.eventsByID[eventID]?.event {
            let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: day, calendar: calendar)
            if let snapshot = projection.occurrenceLogsByID[key.cloudMCPEntityID]?.snapshot {
                return snapshot
            }
        }

        return projection.occurrenceLogsByID.values.first(where: { projected in
            calendar.isDate(projected.record.occurrenceDate, inSameDayAs: day)
                && (projected.record.eventID == eventID || projected.record.baseSeriesEventID == eventID)
        })?.snapshot
    }

    func listCalendarOccurrences(
        in interval: DateInterval,
        filters: CloudCalendarOccurrenceFilters = CloudCalendarOccurrenceFilters()
    ) -> [CloudCalendarOccurrenceSnapshot] {
        guard interval.duration > 0 else { return [] }

        var snapshots: [CloudCalendarOccurrenceSnapshot] = []
        for day in dayStarts(in: interval) {
            let timed = CalendarLayout.occurrencesForDate(activeEvents, date: day, calendar: calendar)
            let allDay = CalendarLayout.allDayOccurrencesForDate(activeEvents, date: day, calendar: calendar)
            for occurrence in timed + allDay {
                guard occurrence.range.end > interval.start, occurrence.range.start < interval.end else {
                    continue
                }
                let snapshot = makeOccurrenceSnapshot(for: occurrence)
                guard matchesFilters(snapshot, filters: filters) else {
                    continue
                }
                snapshots.append(snapshot)
            }
        }

        return snapshots.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay {
                return lhs.isAllDay && !rhs.isAllDay
            }
            if lhs.start == rhs.start {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.start < rhs.start
        }
    }

    func getScheduleForDate(_ date: Date) -> CloudDayScheduleSnapshot {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let interval = DateInterval(start: dayStart, end: dayEnd)
        let occurrences = listCalendarOccurrences(in: interval)
        return CloudDayScheduleSnapshot(
            date: dayStart,
            allDayOccurrences: occurrences.filter(\.isAllDay),
            timedOccurrences: occurrences.filter { !$0.isAllDay }
        )
    }

    func searchTimelineNotes(
        matching query: String,
        in interval: DateInterval? = nil,
        eventID: UUID? = nil,
        type: String? = nil
    ) -> [CloudTimelineNoteSearchHit] {
        guard let normalizedQuery = normalizedSearchQuery(query) else { return [] }

        return projection.occurrenceLogsByID.values.flatMap { projected -> [CloudTimelineNoteSearchHit] in
            let event = resolvedEvent(for: projected.record)
            if let eventID, event?.id != eventID, projected.record.eventID != eventID, projected.record.baseSeriesEventID != eventID {
                return []
            }
            if let type, event?.type != type {
                return []
            }
            let matchingNotes = projected.record.timelineItems.compactMap(\.noteValue).filter { note in
                textMatchesQuery(note.text, normalizedQuery: normalizedQuery)
                    && intervalContains(interval, candidate: note.createdAt)
            }
            guard !matchingNotes.isEmpty else {
                return []
            }
            return matchingNotes.map { note in
                CloudTimelineNoteSearchHit(
                    note: note,
                    eventID: event?.id ?? projected.record.eventID,
                    baseSeriesEventID: projected.record.baseSeriesEventID,
                    occurrenceDate: projected.record.occurrenceDate,
                    eventTitle: event?.title ?? "",
                    eventType: event?.type ?? ""
                )
            }
        }
        .sorted { $0.note.createdAt > $1.note.createdAt }
    }

    func searchEventText(
        matching query: String,
        in interval: DateInterval? = nil,
        fields: Set<CloudEventTextField> = Set(CloudEventTextField.allCases)
    ) -> [CloudEventTextSearchHit] {
        guard let normalizedQuery = normalizedSearchQuery(query) else { return [] }

        var hits: [CloudEventTextSearchHit] = []

        if fields.contains(.eventNote) {
            for projected in projection.eventsByID.values where !projected.event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard textMatchesQuery(projected.event.note, normalizedQuery: normalizedQuery) else { continue }
                guard eventIntersectsInterval(projected.event, interval: interval) else { continue }
                hits.append(
                    CloudEventTextSearchHit(
                        field: .eventNote,
                        eventID: projected.event.id,
                        baseSeriesEventID: projected.event.recurrenceParentId,
                        occurrenceDate: nil,
                        eventTitle: projected.event.title,
                        text: projected.event.note
                    )
                )
            }
        }

        for projected in projection.occurrenceLogsByID.values {
            let event = resolvedEvent(for: projected.record)
            let eventTitle = event?.title ?? ""
            let eventIdentifier = event?.id ?? projected.record.eventID
            let baseSeriesEventID = projected.record.baseSeriesEventID

            if fields.contains(.logSummary),
               !projected.record.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               textMatchesQuery(projected.record.summary, normalizedQuery: normalizedQuery),
               intervalContains(interval, candidate: projected.record.occurrenceDate) {
                hits.append(
                    CloudEventTextSearchHit(
                        field: .logSummary,
                        eventID: eventIdentifier,
                        baseSeriesEventID: baseSeriesEventID,
                        occurrenceDate: projected.record.occurrenceDate,
                        eventTitle: eventTitle,
                        text: projected.record.summary
                    )
                )
            }

            if fields.contains(.logNote),
               !projected.record.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               textMatchesQuery(projected.record.note, normalizedQuery: normalizedQuery),
               intervalContains(interval, candidate: projected.record.occurrenceDate) {
                hits.append(
                    CloudEventTextSearchHit(
                        field: .logNote,
                        eventID: eventIdentifier,
                        baseSeriesEventID: baseSeriesEventID,
                        occurrenceDate: projected.record.occurrenceDate,
                        eventTitle: eventTitle,
                        text: projected.record.note
                    )
                )
            }

            if fields.contains(.timelineNote) {
                for note in projected.record.timelineItems.compactMap(\.noteValue) where !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard textMatchesQuery(note.text, normalizedQuery: normalizedQuery) else { continue }
                    guard intervalContains(interval, candidate: note.createdAt) else { continue }
                    hits.append(
                        CloudEventTextSearchHit(
                            field: .timelineNote,
                            eventID: eventIdentifier,
                            baseSeriesEventID: baseSeriesEventID,
                            occurrenceDate: projected.record.occurrenceDate,
                            eventTitle: eventTitle,
                            text: note.text
                        )
                    )
                }
            }
        }

        return hits.sorted { lhs, rhs in
            let lhsDate = lhs.occurrenceDate ?? .distantPast
            let rhsDate = rhs.occurrenceDate ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.field.rawValue < rhs.field.rawValue
            }
            return lhsDate > rhsDate
        }
    }

    private var activeEvents: [Event] {
        projection.eventsByID.values
            .map(\.event)
            .sorted { lhs, rhs in
                let lhsStart = lhs.primaryTimeRange?.start ?? lhs.createdAt
                let rhsStart = rhs.primaryTimeRange?.start ?? rhs.createdAt
                if lhsStart == rhsStart {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhsStart < rhsStart
            }
    }

    private func makeOccurrenceSnapshot(
        for occurrence: CalendarLayout.EventOccurrence
    ) -> CloudCalendarOccurrenceSnapshot {
        let occurrenceKey = CalendarOccurrenceKey.make(
            for: occurrence.event,
            occurrenceDate: occurrence.range.start,
            calendar: calendar
        )
        let log = projection.occurrenceLogsByID[occurrenceKey.cloudMCPEntityID]
        let mirroredAt = projection.eventsByID[occurrence.event.id]?.mirroredAt ?? occurrence.event.createdAt
        return CloudCalendarOccurrenceSnapshot(
            eventID: occurrence.event.id,
            baseSeriesEventID: occurrenceKey.baseSeriesEventID,
            occurrenceDate: calendar.startOfDay(for: occurrence.range.start),
            title: occurrence.event.title,
            type: occurrence.event.type,
            tags: occurrence.event.tags,
            start: occurrence.range.start,
            end: occurrence.range.end,
            isAllDay: occurrence.event.isAllDay,
            displayKind: occurrence.event.displayKind,
            interruptRelation: occurrence.event.interruptRelation,
            hasLog: log != nil,
            logUpdatedAt: log?.record.updatedAt,
            mirroredAt: mirroredAt
        )
    }

    private func matchesFilters(
        _ snapshot: CloudCalendarOccurrenceSnapshot,
        filters: CloudCalendarOccurrenceFilters
    ) -> Bool {
        if let eventID = filters.eventID, snapshot.eventID != eventID, snapshot.baseSeriesEventID != eventID {
            return false
        }
        if let type = filters.type, snapshot.type != type {
            return false
        }
        if !filters.tags.isEmpty, !Set(filters.tags).isSubset(of: Set(snapshot.tags)) {
            return false
        }
        if let updatedSince = filters.updatedSince {
            let candidate = snapshot.logUpdatedAt ?? snapshot.mirroredAt
            if candidate < updatedSince {
                return false
            }
        }
        return true
    }

    private func resolvedEvent(for record: CalendarEventLogRecord) -> Event? {
        if let direct = projection.eventsByID[record.eventID]?.event {
            return direct
        }
        if let baseSeriesEventID = record.baseSeriesEventID,
           let series = projection.eventsByID[baseSeriesEventID]?.event {
            return series
        }
        return nil
    }

    private func normalizedSearchQuery(_ query: String) -> [String]? {
        let normalized = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return normalized.isEmpty ? nil : normalized
    }

    private func textMatchesQuery(
        _ text: String,
        normalizedQuery: [String]
    ) -> Bool {
        let haystack = text.lowercased()
        return normalizedQuery.allSatisfy { haystack.contains($0) }
    }

    private func dayStarts(in interval: DateInterval) -> [Date] {
        var days: [Date] = []
        var current = calendar.startOfDay(for: interval.start)
        let endBoundary = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        while current <= endBoundary {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else {
                break
            }
            current = next
        }
        return days
    }

    private func intervalContains(_ interval: DateInterval?, candidate: Date) -> Bool {
        guard let interval else { return true }
        return candidate >= interval.start && candidate < interval.end
    }

    private func eventIntersectsInterval(_ event: Event, interval: DateInterval?) -> Bool {
        guard let interval else { return true }
        if event.isRecurringSeries {
            return dayStarts(in: interval).contains { day in
                guard let range = CalendarLayout.recurrenceOccurrence(for: event, on: day, calendar: calendar) else {
                    return false
                }
                return range.end > interval.start && range.start < interval.end
            }
        }
        let ranges = event.effectiveTimeRanges
        if ranges.isEmpty {
            return event.createdAt >= interval.start && event.createdAt < interval.end
        }
        return ranges.contains { $0.end > interval.start && $0.start < interval.end }
    }
}

struct CloudMCPSyncBatchResult: Codable, Hashable {
    var userID: UUID
    var appliedCount: Int
    var ignoredCount: Int
    var eventCount: Int
    var occurrenceLogCount: Int
    var rebuiltAt: Date
}

struct CloudMCPAuditEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var requestName: String
    var scope: CloudMCPTokenScope
    var userID: UUID?
    var tokenID: UUID?
    var succeeded: Bool
    var createdAt: Date
    var failureReason: String?

    init(
        id: UUID = UUID(),
        requestName: String,
        scope: CloudMCPTokenScope,
        userID: UUID?,
        tokenID: UUID?,
        succeeded: Bool,
        createdAt: Date = Date(),
        failureReason: String? = nil
    ) {
        self.id = id
        self.requestName = requestName
        self.scope = scope
        self.userID = userID
        self.tokenID = tokenID
        self.succeeded = succeeded
        self.createdAt = createdAt
        self.failureReason = failureReason
    }
}

struct CloudMCPInMemoryServer {
    var config: CloudMCPServerConfig
    private(set) var tokenRegistry: CloudMCPTokenRegistry
    private(set) var rawMirrorsByUserID: [UUID: CloudEventRawMirrorStore]
    private(set) var auditEntries: [CloudMCPAuditEntry]

    init(
        config: CloudMCPServerConfig = CloudMCPServerConfig(),
        tokenRegistry: CloudMCPTokenRegistry = CloudMCPTokenRegistry(),
        rawMirrorsByUserID: [UUID: CloudEventRawMirrorStore] = [:],
        auditEntries: [CloudMCPAuditEntry] = []
    ) {
        self.config = config
        self.tokenRegistry = tokenRegistry
        self.rawMirrorsByUserID = rawMirrorsByUserID
        self.auditEntries = auditEntries
    }

    mutating func registerToken(_ token: CloudMCPTokenRecord) {
        tokenRegistry.register(token)
    }

    @discardableResult
    mutating func revokeToken(rawToken: String, at date: Date = Date()) -> Bool {
        tokenRegistry.revoke(rawToken: rawToken, at: date)
    }

    mutating func applySyncBatch(
        _ batch: CloudMCPSyncBatch,
        rawToken: String,
        receivedAt: Date = Date()
    ) throws -> CloudMCPSyncBatchResult {
        let token = try authorize(
            rawToken: rawToken,
            requiredScope: .syncWrite,
            requestName: "sync.batch",
            failureDate: receivedAt
        )

        guard batch.schemaVersion == config.schemaVersion else {
            let error = CloudMCPServerError.schemaVersionMismatch(
                expected: config.schemaVersion,
                received: batch.schemaVersion
            )
            recordAuditFailure(requestName: "sync.batch", scope: .syncWrite, token: token, error: error, createdAt: receivedAt)
            throw error
        }

        guard batch.envelopes.allSatisfy({ $0.userID == token.userID }) else {
            let error = CloudMCPServerError.mixedUsersInBatch
            recordAuditFailure(requestName: "sync.batch", scope: .syncWrite, token: token, error: error, createdAt: receivedAt)
            throw error
        }

        var rawMirror = rawMirrorsByUserID[token.userID] ?? CloudEventRawMirrorStore(
            userID: token.userID,
            schemaVersion: config.schemaVersion
        )
        let applyResult = try rawMirror.apply(batch.envelopes)
        rawMirrorsByUserID[token.userID] = rawMirror
        let projection = CloudMCPProjectionBuilder.build(from: rawMirror, rebuiltAt: receivedAt)
        recordAuditSuccess(requestName: "sync.batch", scope: .syncWrite, token: token, createdAt: receivedAt)
        return CloudMCPSyncBatchResult(
            userID: token.userID,
            appliedCount: applyResult.appliedCount,
            ignoredCount: applyResult.ignoredCount,
            eventCount: projection.eventsByID.count,
            occurrenceLogCount: projection.occurrenceLogsByID.count,
            rebuiltAt: projection.rebuiltAt
        )
    }

    mutating func listCalendarOccurrences(
        in interval: DateInterval,
        filters: CloudCalendarOccurrenceFilters = CloudCalendarOccurrenceFilters(),
        rawToken: String,
        calendar: Calendar = .current,
        requestedAt: Date = Date()
    ) throws -> [CloudCalendarOccurrenceSnapshot] {
        let token = try authorize(
            rawToken: rawToken,
            requiredScope: .mcpRead,
            requestName: "list_calendar_occurrences",
            failureDate: requestedAt
        )
        let results = queryService(for: token.userID, calendar: calendar)
            .listCalendarOccurrences(in: interval, filters: filters)
        recordAuditSuccess(requestName: "list_calendar_occurrences", scope: .mcpRead, token: token, createdAt: requestedAt)
        return results
    }

    mutating func getCalendarEvent(
        id: UUID,
        rawToken: String,
        calendar: Calendar = .current,
        requestedAt: Date = Date()
    ) throws -> CloudCalendarEventSnapshot? {
        let token = try authorize(
            rawToken: rawToken,
            requiredScope: .mcpRead,
            requestName: "get_calendar_event",
            failureDate: requestedAt
        )
        let result = queryService(for: token.userID, calendar: calendar).getCalendarEvent(id: id)
        recordAuditSuccess(requestName: "get_calendar_event", scope: .mcpRead, token: token, createdAt: requestedAt)
        return result
    }

    mutating func getOccurrenceLog(
        eventID: UUID,
        occurrenceDate: Date,
        rawToken: String,
        calendar: Calendar = .current,
        requestedAt: Date = Date()
    ) throws -> CloudOccurrenceLogSnapshot? {
        let token = try authorize(
            rawToken: rawToken,
            requiredScope: .mcpRead,
            requestName: "get_occurrence_log",
            failureDate: requestedAt
        )
        let result = queryService(for: token.userID, calendar: calendar)
            .getOccurrenceLog(eventID: eventID, occurrenceDate: occurrenceDate)
        recordAuditSuccess(requestName: "get_occurrence_log", scope: .mcpRead, token: token, createdAt: requestedAt)
        return result
    }

    mutating func searchTimelineNotes(
        matching query: String,
        in interval: DateInterval? = nil,
        eventID: UUID? = nil,
        type: String? = nil,
        rawToken: String,
        calendar: Calendar = .current,
        requestedAt: Date = Date()
    ) throws -> [CloudTimelineNoteSearchHit] {
        let token = try authorize(
            rawToken: rawToken,
            requiredScope: .mcpRead,
            requestName: "search_timeline_notes",
            failureDate: requestedAt
        )
        let results = queryService(for: token.userID, calendar: calendar)
            .searchTimelineNotes(matching: query, in: interval, eventID: eventID, type: type)
        recordAuditSuccess(requestName: "search_timeline_notes", scope: .mcpRead, token: token, createdAt: requestedAt)
        return results
    }

    mutating func getScheduleForDate(
        _ date: Date,
        rawToken: String,
        calendar: Calendar = .current,
        requestedAt: Date = Date()
    ) throws -> CloudDayScheduleSnapshot {
        let token = try authorize(
            rawToken: rawToken,
            requiredScope: .mcpRead,
            requestName: "get_schedule_for_date",
            failureDate: requestedAt
        )
        let result = queryService(for: token.userID, calendar: calendar).getScheduleForDate(date)
        recordAuditSuccess(requestName: "get_schedule_for_date", scope: .mcpRead, token: token, createdAt: requestedAt)
        return result
    }

    mutating func searchEventText(
        matching query: String,
        in interval: DateInterval? = nil,
        fields: Set<CloudEventTextField> = Set(CloudEventTextField.allCases),
        rawToken: String,
        calendar: Calendar = .current,
        requestedAt: Date = Date()
    ) throws -> [CloudEventTextSearchHit] {
        let token = try authorize(
            rawToken: rawToken,
            requiredScope: .mcpRead,
            requestName: "search_event_text",
            failureDate: requestedAt
        )
        let results = queryService(for: token.userID, calendar: calendar)
            .searchEventText(matching: query, in: interval, fields: fields)
        recordAuditSuccess(requestName: "search_event_text", scope: .mcpRead, token: token, createdAt: requestedAt)
        return results
    }

    func rawMirror(for userID: UUID) -> CloudEventRawMirrorStore? {
        rawMirrorsByUserID[userID]
    }

    func projection(for userID: UUID) -> CloudMCPProjection? {
        guard let mirror = rawMirrorsByUserID[userID] else {
            return nil
        }
        return CloudMCPProjectionBuilder.build(from: mirror)
    }

    private func queryService(
        for userID: UUID,
        calendar: Calendar
    ) -> CloudMCPQueryService {
        let projection = rawMirrorsProjection(for: userID)
        return CloudMCPQueryService(projection: projection, calendar: calendar)
    }

    private func rawMirrorsProjection(for userID: UUID) -> CloudMCPProjection {
        let mirror = rawMirrorsByUserID[userID] ?? CloudEventRawMirrorStore(
            userID: userID,
            schemaVersion: config.schemaVersion
        )
        return CloudMCPProjectionBuilder.build(from: mirror)
    }

    private mutating func authorize(
        rawToken: String,
        requiredScope: CloudMCPTokenScope,
        requestName: String,
        failureDate: Date
    ) throws -> CloudMCPTokenRecord {
        guard let token = tokenRegistry.authorizedToken(rawToken: rawToken, requiredScope: requiredScope) else {
            recordAuditFailure(
                requestName: requestName,
                scope: requiredScope,
                token: nil,
                error: CloudMCPServerError.unauthorized,
                createdAt: failureDate
            )
            throw CloudMCPServerError.unauthorized
        }
        return token
    }

    private mutating func recordAuditSuccess(
        requestName: String,
        scope: CloudMCPTokenScope,
        token: CloudMCPTokenRecord,
        createdAt: Date
    ) {
        guard config.auditLoggingEnabled else { return }
        auditEntries.append(
            CloudMCPAuditEntry(
                requestName: requestName,
                scope: scope,
                userID: token.userID,
                tokenID: token.id,
                succeeded: true,
                createdAt: createdAt
            )
        )
    }

    private mutating func recordAuditFailure(
        requestName: String,
        scope: CloudMCPTokenScope,
        token: CloudMCPTokenRecord?,
        error: Error,
        createdAt: Date
    ) {
        guard config.auditLoggingEnabled else { return }
        auditEntries.append(
            CloudMCPAuditEntry(
                requestName: requestName,
                scope: scope,
                userID: token?.userID,
                tokenID: token?.id,
                succeeded: false,
                createdAt: createdAt,
                failureReason: String(describing: error)
            )
        )
    }
}

extension CalendarOccurrenceKey {
    var cloudMCPEntityID: String {
        let baseSeriesID = baseSeriesEventID?.uuidString ?? "nil"
        let day = Int(occurrenceDate.timeIntervalSince1970)
        return "\(eventID.uuidString)|\(baseSeriesID)|\(day)|\(kind.rawValue)"
    }

    init?(cloudMCPEntityID: String) {
        let parts = cloudMCPEntityID.split(separator: "|").map(String.init)
        guard parts.count == 4,
              let eventID = UUID(uuidString: parts[0]),
              let seconds = TimeInterval(parts[2]),
              let kind = Kind(rawValue: parts[3]) else {
            return nil
        }
        let baseSeriesEventID = parts[1] == "nil" ? nil : UUID(uuidString: parts[1])
        self.init(
            eventID: eventID,
            baseSeriesEventID: baseSeriesEventID,
            occurrenceDate: Date(timeIntervalSince1970: seconds),
            kind: kind
        )
    }
}
