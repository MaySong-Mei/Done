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

struct CalendarOccurrenceKey: Codable {
    enum Kind: String, Codable, Hashable {
        case singleEvent = "single"
        case seriesOccurrence
    }

    var eventID: UUID
    var baseSeriesEventID: UUID?
    /// Wall-clock anchor for the occurrence (start-of-day in the reference
    /// time zone). Retained for display, sync ID encoding, and back-compat.
    /// NOT part of identity — see `dayKey`.
    var occurrenceDate: Date
    var kind: Kind
    /// Time-zone-stable identity field. `YYYYMMDD` integer derived from
    /// `occurrenceDate` using the frozen reference time zone (see
    /// `referenceTimeZone`). Two keys for the same event-on-the-same-day
    /// must produce the same `dayKey` regardless of the device's current
    /// system time zone, otherwise log/feedback record lookups break when
    /// the user travels.
    var dayKey: Int

    private enum CodingKeys: String, CodingKey {
        case eventID
        case baseSeriesEventID
        case occurrenceDate
        case kind
        case dayKey
    }

    init(
        eventID: UUID,
        baseSeriesEventID: UUID?,
        occurrenceDate: Date,
        kind: Kind,
        dayKey: Int
    ) {
        self.eventID = eventID
        self.baseSeriesEventID = baseSeriesEventID
        self.occurrenceDate = occurrenceDate
        self.kind = kind
        self.dayKey = dayKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(UUID.self, forKey: .eventID)
        baseSeriesEventID = try container.decodeIfPresent(UUID.self, forKey: .baseSeriesEventID)
        occurrenceDate = try container.decode(Date.self, forKey: .occurrenceDate)
        kind = try container.decode(Kind.self, forKey: .kind)
        if let stored = try container.decodeIfPresent(Int.self, forKey: .dayKey) {
            dayKey = stored
        } else {
            // Legacy record: derive from occurrenceDate using the frozen
            // reference time zone. For users who haven't traveled this
            // matches the original write; for users who have, the dayKey
            // is at least stable from now on.
            dayKey = CalendarOccurrenceKey.dayKey(from: occurrenceDate)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encodeIfPresent(baseSeriesEventID, forKey: .baseSeriesEventID)
        try container.encode(occurrenceDate, forKey: .occurrenceDate)
        try container.encode(kind, forKey: .kind)
        try container.encode(dayKey, forKey: .dayKey)
    }
}

extension CalendarOccurrenceKey: Hashable {
    static func == (lhs: CalendarOccurrenceKey, rhs: CalendarOccurrenceKey) -> Bool {
        lhs.eventID == rhs.eventID
            && lhs.baseSeriesEventID == rhs.baseSeriesEventID
            && lhs.kind == rhs.kind
            && lhs.dayKey == rhs.dayKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(eventID)
        hasher.combine(baseSeriesEventID)
        hasher.combine(kind)
        hasher.combine(dayKey)
    }
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
    /// Test-only override. When set, takes precedence over the
    /// UserDefaults-backed `referenceTimeZone`.
    nonisolated(unsafe) static var referenceTimeZoneOverride: TimeZone?

    /// User-defaults key for the frozen reference time zone identifier.
    static let referenceTimeZoneDefaultsKey = "occurrenceKeyReferenceTimeZoneIdentifier"

    /// Time zone used to derive `dayKey` from a `Date`. Frozen on first
    /// access (persisted in `UserDefaults.standard`) so that subsequent
    /// system time zone changes do not alter the hash of an existing
    /// occurrence key. Returning a stable value here is what makes
    /// timeline/feedback record lookup robust to travel.
    static var referenceTimeZone: TimeZone {
        if let override = referenceTimeZoneOverride { return override }
        let defaults = UserDefaults.standard
        if let identifier = defaults.string(forKey: referenceTimeZoneDefaultsKey),
           let stored = TimeZone(identifier: identifier) {
            return stored
        }
        let current = TimeZone.current
        defaults.set(current.identifier, forKey: referenceTimeZoneDefaultsKey)
        return current
    }

    /// Calendar configured to use the frozen reference time zone.
    static var referenceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = referenceTimeZone
        return calendar
    }

    /// Derive a `YYYYMMDD` integer for the calendar day that the supplied
    /// instant falls on, using the reference time zone.
    static func dayKey(from date: Date) -> Int {
        let comps = referenceCalendar.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 1970
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        return year * 10_000 + month * 100 + day
    }

    static func make(
        for event: Event,
        occurrenceDate: Date,
        calendar: Calendar? = nil
    ) -> CalendarOccurrenceKey {
        // Always derive the day anchor in the frozen reference tz, ignoring
        // the supplied calendar's time zone. This is the whole point of the
        // fix: lookups must produce the same key as the original write even
        // if the system time zone has since changed.
        let refCalendar = referenceCalendar
        let day = refCalendar.startOfDay(for: occurrenceDate)
        let key = dayKey(from: day)
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
            kind: kind,
            dayKey: key
        )
    }
}
