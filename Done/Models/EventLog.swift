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

struct EventLogInterruptReference: Codable, Hashable, Identifiable {
    var id: UUID
    var childEventID: UUID
    var createdAt: Date

    init(
        id: UUID = UUID(),
        childEventID: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.childEventID = childEventID
        self.createdAt = createdAt
    }
}

enum EventLogTimelineItem: Codable, Hashable, Identifiable {
    case note(EventLogTimelineNote)
    case interruptRef(EventLogInterruptReference)

    private enum CodingKeys: String, CodingKey {
        case kind
        case note
        case interruptRef
    }

    private enum Kind: String, Codable {
        case note
        case interruptRef
    }

    var id: String {
        switch self {
        case .note(let note):
            return "note-\(note.id.uuidString)"
        case .interruptRef(let reference):
            return "interrupt-\(reference.id.uuidString)"
        }
    }

    var createdAt: Date {
        switch self {
        case .note(let note):
            return note.createdAt
        case .interruptRef(let reference):
            return reference.createdAt
        }
    }

    var noteValue: EventLogTimelineNote? {
        guard case .note(let note) = self else { return nil }
        return note
    }

    var interruptReferenceValue: EventLogInterruptReference? {
        guard case .interruptRef(let reference) = self else { return nil }
        return reference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .note:
            self = .note(try container.decode(EventLogTimelineNote.self, forKey: .note))
        case .interruptRef:
            self = .interruptRef(try container.decode(EventLogInterruptReference.self, forKey: .interruptRef))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .note(let note):
            try container.encode(Kind.note, forKey: .kind)
            try container.encode(note, forKey: .note)
        case .interruptRef(let reference):
            try container.encode(Kind.interruptRef, forKey: .kind)
            try container.encode(reference, forKey: .interruptRef)
        }
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
    var timelineItems: [EventLogTimelineItem]
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case eventID
        case baseSeriesEventID
        case occurrenceDate
        case suggestedTemplateID
        case selectedTemplateID
        case completionStatus
        case actualDurationMinutes
        case summary
        case note
        case effort
        case emotions
        case behaviors
        case templateAnswers
        case timelineItems
        case timelineNotes
        case createdAt
        case updatedAt
    }

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
        timelineItems: [EventLogTimelineItem] = [],
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
        self.timelineItems = timelineItems
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CalendarOccurrenceKey.self, forKey: .id)
        eventID = try container.decode(UUID.self, forKey: .eventID)
        baseSeriesEventID = try container.decodeIfPresent(UUID.self, forKey: .baseSeriesEventID)
        occurrenceDate = try container.decode(Date.self, forKey: .occurrenceDate)
        suggestedTemplateID = try container.decodeIfPresent(String.self, forKey: .suggestedTemplateID)
        selectedTemplateID = try container.decodeIfPresent(String.self, forKey: .selectedTemplateID)
        completionStatus = try container.decodeIfPresent(EventLogCompletionStatus.self, forKey: .completionStatus)
        actualDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .actualDurationMinutes)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        effort = try container.decodeIfPresent(Int.self, forKey: .effort)
        emotions = try container.decodeIfPresent([String].self, forKey: .emotions) ?? []
        behaviors = try container.decodeIfPresent([String].self, forKey: .behaviors) ?? []
        templateAnswers = try container.decodeIfPresent([String: EventLogAnswerValue].self, forKey: .templateAnswers) ?? [:]
        if let decodedItems = try container.decodeIfPresent([EventLogTimelineItem].self, forKey: .timelineItems) {
            timelineItems = decodedItems
        } else {
            let legacyNotes = try container.decodeIfPresent([EventLogTimelineNote].self, forKey: .timelineNotes) ?? []
            timelineItems = legacyNotes.map(EventLogTimelineItem.note)
        }
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(eventID, forKey: .eventID)
        try container.encodeIfPresent(baseSeriesEventID, forKey: .baseSeriesEventID)
        try container.encode(occurrenceDate, forKey: .occurrenceDate)
        try container.encodeIfPresent(suggestedTemplateID, forKey: .suggestedTemplateID)
        try container.encodeIfPresent(selectedTemplateID, forKey: .selectedTemplateID)
        try container.encodeIfPresent(completionStatus, forKey: .completionStatus)
        try container.encodeIfPresent(actualDurationMinutes, forKey: .actualDurationMinutes)
        try container.encode(summary, forKey: .summary)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encode(emotions, forKey: .emotions)
        try container.encode(behaviors, forKey: .behaviors)
        try container.encode(templateAnswers, forKey: .templateAnswers)
        try container.encode(timelineItems, forKey: .timelineItems)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Backward-compatible note access layered on top of typed timeline items.
    var timelineNotes: [EventLogTimelineNote] {
        get { timelineItems.compactMap(\.noteValue) }
        set {
            let interruptItems = timelineItems.compactMap { item -> EventLogTimelineItem? in
                guard case .interruptRef = item else { return nil }
                return item
            }
            timelineItems = newValue.map(EventLogTimelineItem.note) + interruptItems
        }
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
