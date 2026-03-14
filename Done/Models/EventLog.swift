import Foundation

enum EventLogTemplateID: String, CaseIterable, Codable, Hashable, Identifiable {
    case deepWork = "deep_work"
    case meeting
    case workout
    case studySession = "study_session"
    case personalCare = "personal_care"

    var id: String { rawValue }
}

enum EventLogCompletionStatus: String, Codable, Hashable, CaseIterable, Identifiable {
    case completed
    case partial
    case skipped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .completed:
            return "Completed"
        case .partial:
            return "Partial"
        case .skipped:
            return "Skipped"
        }
    }
}

enum EventLogFieldKind: String, Codable, Hashable {
    case singleSelect
    case multiSelect
    case rating
    case shortText
    case longText
}

struct EventLogTemplateFieldOption: Codable, Hashable, Identifiable {
    var id: String
    var title: String
}

struct EventLogTemplateFieldDefinition: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var kind: EventLogFieldKind
    var options: [EventLogTemplateFieldOption]
    var placeholder: String?

    init(
        id: String,
        title: String,
        kind: EventLogFieldKind,
        options: [EventLogTemplateFieldOption] = [],
        placeholder: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.options = options
        self.placeholder = placeholder
    }
}

struct EventLogTemplateDefinition: Codable, Hashable, Identifiable {
    var id: EventLogTemplateID
    var title: String
    var familyTitle: String
    var fields: [EventLogTemplateFieldDefinition]
}

enum EventLogAnswerValue: Codable, Hashable {
    case string(String)
    case strings([String])
    case int(Int)

    private enum CodingKeys: String, CodingKey {
        case type
        case stringValue
        case stringArrayValue
        case intValue
    }

    private enum ValueType: String, Codable {
        case string
        case strings
        case int
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .string:
            self = .string(try container.decode(String.self, forKey: .stringValue))
        case .strings:
            self = .strings(try container.decode([String].self, forKey: .stringArrayValue))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .intValue))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .stringValue)
        case .strings(let values):
            try container.encode(ValueType.strings, forKey: .type)
            try container.encode(values, forKey: .stringArrayValue)
        case .int(let value):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(value, forKey: .intValue)
        }
    }
}

struct EventLogTimelineNote: Codable, Hashable, Identifiable {
    var id: UUID
    var text: String
    /// Snapshot time chosen on the event timeline. This can fall outside the scheduled event range.
    var createdAt: Date
    var source: String

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        source: String
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.source = source
    }
}

struct CalendarEventLogRecord: Codable, Hashable, Identifiable {
    var id: CalendarOccurrenceKey
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
    var timelineNotes: [EventLogTimelineNote]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: CalendarOccurrenceKey,
        eventID: UUID,
        baseSeriesEventID: UUID?,
        occurrenceDate: Date,
        suggestedTemplateID: String? = nil,
        selectedTemplateID: String? = nil,
        completionStatus: EventLogCompletionStatus? = nil,
        actualDurationMinutes: Int? = nil,
        summary: String = "",
        note: String = "",
        effort: Int? = nil,
        emotions: [String] = [],
        behaviors: [String] = [],
        templateAnswers: [String: EventLogAnswerValue] = [:],
        timelineNotes: [EventLogTimelineNote] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.eventID = eventID
        self.baseSeriesEventID = baseSeriesEventID
        self.occurrenceDate = occurrenceDate
        self.suggestedTemplateID = suggestedTemplateID
        self.selectedTemplateID = selectedTemplateID
        self.completionStatus = completionStatus
        self.actualDurationMinutes = actualDurationMinutes
        self.summary = summary
        self.note = note
        self.effort = effort
        self.emotions = emotions
        self.behaviors = behaviors
        self.templateAnswers = templateAnswers
        self.timelineNotes = timelineNotes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct CalendarEventLogDraft: Hashable {
    var suggestedTemplateID: EventLogTemplateID?
    var selectedTemplateID: EventLogTemplateID?
    var completionStatus: EventLogCompletionStatus?
    var actualDurationMinutes: Int?
    var summary: String
    var note: String
    var effort: Int?
    var emotions: [String]
    var behaviors: [String]
    var templateAnswers: [String: EventLogAnswerValue]
    var timelineNotes: [EventLogTimelineNote]

    var effectiveTemplateID: EventLogTemplateID? {
        selectedTemplateID ?? suggestedTemplateID
    }
}

extension CalendarEventLogDraft {
    static let empty = CalendarEventLogDraft(
        suggestedTemplateID: nil,
        selectedTemplateID: nil,
        completionStatus: nil,
        actualDurationMinutes: nil,
        summary: "",
        note: "",
        effort: nil,
        emotions: [],
        behaviors: [],
        templateAnswers: [:],
        timelineNotes: []
    )
}
