import Foundation

enum CalendarEffortRating: Int, CaseIterable, Codable, Hashable, Identifiable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var id: Int { rawValue }
}

enum CalendarEmotionTag: String, CaseIterable, Codable, Hashable, Identifiable {
    case calm
    case focused
    case energized
    case happy
    case neutral
    case stressed
    case anxious
    case frustrated
    case tired
    case overwhelmed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calm: return "Calm"
        case .focused: return "Focused"
        case .energized: return "Energized"
        case .happy: return "Happy"
        case .neutral: return "Neutral"
        case .stressed: return "Stressed"
        case .anxious: return "Anxious"
        case .frustrated: return "Frustrated"
        case .tired: return "Tired"
        case .overwhelmed: return "Overwhelmed"
        }
    }
}

enum CalendarBehaviorTag: String, CaseIterable, Codable, Hashable, Identifiable {
    case deepWork = "deep_work"
    case distracted
    case proactive
    case avoidant
    case consistent
    case rushed
    case interrupted
    case collaborative
    case delayed
    case asPlanned = "as_planned"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepWork: return "Deep Work"
        case .distracted: return "Distracted"
        case .proactive: return "Proactive"
        case .avoidant: return "Avoidant"
        case .consistent: return "Consistent"
        case .rushed: return "Rushed"
        case .interrupted: return "Interrupted"
        case .collaborative: return "Collaborative"
        case .delayed: return "Delayed"
        case .asPlanned: return "As Planned"
        }
    }
}

struct CalendarOccurrenceKey: Hashable, Codable {
    enum Kind: String, Codable, Hashable {
        case singleEvent = "single"
        case seriesOccurrence
    }

    var eventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date
    var kind: Kind
}

struct CalendarEventLogEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
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

struct CalendarEventFeedbackRecord: Identifiable, Codable, Hashable {
    var id: CalendarOccurrenceKey
    var eventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date
    var effort: Int?
    var emotions: [String]
    var behaviors: [String]
    var selfNote: String
    var logs: [CalendarEventLogEntry]
    var chatConversationID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: CalendarOccurrenceKey,
        eventID: UUID,
        baseSeriesEventID: UUID?,
        occurrenceDate: Date,
        effort: Int? = nil,
        emotions: [String] = [],
        behaviors: [String] = [],
        selfNote: String = "",
        logs: [CalendarEventLogEntry] = [],
        chatConversationID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.eventID = eventID
        self.baseSeriesEventID = baseSeriesEventID
        self.occurrenceDate = occurrenceDate
        self.effort = effort
        self.emotions = emotions
        self.behaviors = behaviors
        self.selfNote = selfNote
        self.logs = logs
        self.chatConversationID = chatConversationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension CalendarOccurrenceKey {
    static func make(
        for event: Event,
        occurrenceDate: Date,
        calendar: Calendar = .current
    ) -> CalendarOccurrenceKey {
        let day = calendar.startOfDay(for: occurrenceDate)
        let baseSeriesEventID = event.recurrenceParentId ?? (event.isRecurringSeries ? event.id : nil)
        let kind: Kind = baseSeriesEventID == nil ? .singleEvent : .seriesOccurrence
        // Recurring series + exception instances intentionally share the same
        // key anchor (series ID + day) so feedback/log/chat mapping stays
        // attached to the occurrence even if it becomes an exception.
        let keyEventID = baseSeriesEventID ?? event.id
        return CalendarOccurrenceKey(
            eventID: keyEventID,
            baseSeriesEventID: baseSeriesEventID,
            occurrenceDate: day,
            kind: kind
        )
    }
}
