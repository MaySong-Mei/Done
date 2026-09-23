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
    // Single events have exactly one occurrence, so dayKey is redundant for
    // identity — including it would orphan legacy records whose dayKey was
    // computed under a different system tz, or whose event was later edited
    // to a different day. Recurring series still depend on dayKey to
    // disambiguate occurrences within the same series.
    static func == (lhs: CalendarOccurrenceKey, rhs: CalendarOccurrenceKey) -> Bool {
        guard lhs.kind == rhs.kind, lhs.eventID == rhs.eventID else { return false }
        switch lhs.kind {
        case .singleEvent:
            return true
        case .seriesOccurrence:
            return lhs.baseSeriesEventID == rhs.baseSeriesEventID
                && lhs.dayKey == rhs.dayKey
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(eventID)
        hasher.combine(kind)
        switch kind {
        case .singleEvent:
            break
        case .seriesOccurrence:
            hasher.combine(baseSeriesEventID)
            hasher.combine(dayKey)
        }
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

    /// Re-home this occurrence record onto a different series (a "this and
    /// following" split mints a new series id for days ≥ split). Rewrites both
    /// the identity key and the mirror fields so a lookup against the new series
    /// matches; day (`dayKey`/`occurrenceDate`) and content are untouched.
    mutating func reanchor(toSeriesID newSeriesID: UUID) {
        id.eventID = newSeriesID
        id.baseSeriesEventID = newSeriesID
        eventID = newSeriesID
        baseSeriesEventID = newSeriesID
    }
}

extension CalendarOccurrenceKey {
    /// Test-only override. When set, takes precedence over the
    /// UserDefaults-backed `referenceTimeZone`.
    nonisolated(unsafe) static var referenceTimeZoneOverride: TimeZone?

    /// The key the frozen identifier USED to live under, and still travels
    /// under on the wire: it stays in `SyncedSettings.allKeys` (cross-device
    /// `dayKey` agreement depends on it) but is bridged to
    /// `OccurrenceKeyMetadataStore` rather than read from `UserDefaults`. As a
    /// `UserDefaults` key it is now a migration source and a rollback net —
    /// never rewritten, never deleted.
    static let referenceTimeZoneDefaultsKey = "occurrenceKeyReferenceTimeZoneIdentifier"

    /// Time zone used to derive `dayKey` from a `Date`. Frozen on first access
    /// so that subsequent system time zone changes do not alter the hash of an
    /// existing occurrence key. Returning a stable value here is what makes
    /// timeline/feedback record lookup robust to travel.
    ///
    /// It lived in `UserDefaults`, which meant the freeze could be lost in the
    /// same cfprefsd flush window as everything else in gh#141 — and losing it
    /// is not "one small value gone". The next launch freezes a DIFFERENT zone,
    /// records already on disk keep their stored `dayKey`, and newly derived
    /// keys stop matching them. See `OccurrenceKeyMetadataStore`, which also
    /// explains why an unreadable file serves rather than re-freezes.
    static var referenceTimeZone: TimeZone {
        if let override = referenceTimeZoneOverride { return override }
        return OccurrenceKeyMetadataStore.shared.referenceTimeZone
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
        dayKey(from: date, in: referenceCalendar)
    }

    /// The same `YYYYMMDD` reduction against an EXPLICIT calendar — but only
    /// its TIME ZONE. Nominal day identities — recurrence exception / instance
    /// day keys — mint through this with the calendar that NAMED the day (the
    /// canvas' current calendar), because "skip the Aug 10 occurrence" is a
    /// statement about a local calendar day, not about an instant: reducing to
    /// components in the naming zone is what survives any later time-zone
    /// change.
    ///
    /// The reduction itself is PINNED to the Gregorian calendar. The naming
    /// calendar's zone decides WHICH civil day the instant falls on (day
    /// boundaries are identical across Foundation calendar identifiers), but
    /// its identifier must not leak into the integer: `Calendar.current` on a
    /// th_TH device is `.buddhist` (2026-08-10 → 25690810), on ar_SA
    /// `.islamicUmmAlQura` (→ 14480226), and `.japanese` years are era-relative
    /// (→ 80810, colliding across eras) — keys minted that way never match a
    /// Gregorian-backfilled key for the same day, don't survive the user
    /// switching Settings > General > Language & Region > Calendar, and don't
    /// order like the days they name. Pinning keeps every key in this type's
    /// reference `dayKey` wire shape regardless of region-calendar settings.
    /// The reference-calendar overload above stays the day system for
    /// occurrence RECORD identity.
    static func dayKey(from date: Date, in calendar: Calendar) -> Int {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let comps = gregorian.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 1970
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        return year * 10_000 + month * 100 + day
    }

    /// Inverse of `dayKey(from:in:)`: the first instant of the named Gregorian
    /// day in `calendar`'s time zone. Render math uses it to project a nominal
    /// day identity back into the frame the canvas is currently drawing in.
    static func dayStart(forDayKey key: Int, in calendar: Calendar) -> Date? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(
            year: key / 10_000,
            month: (key / 100) % 100,
            day: key % 100
        ))
    }

    static func make(
        for event: Event,
        occurrenceDate: Date,
        calendar: Calendar? = nil
    ) -> CalendarOccurrenceKey {
        let baseSeriesEventID = event.recurrenceParentId ?? (event.isRecurringSeries ? event.id : nil)
        let kind: Kind = baseSeriesEventID == nil ? .singleEvent : .seriesOccurrence
        // For single events, anchor the day on the event's own start instant
        // rather than the caller-supplied date. Many callers (timeline-tap,
        // drag handlers) pre-normalize the date via `Calendar.current.startOfDay`,
        // which silently shifts the day when the user travels across tz
        // boundaries — the ref-tz normalization below would then snap to the
        // wrong calendar day. Recurring series still trust the caller because
        // the per-occurrence date comes from RRULE expansion, not the event.
        let refCalendar = referenceCalendar
        let anchor: Date = {
            if baseSeriesEventID == nil, let start = event.primaryTimeRange?.start {
                return start
            }
            return occurrenceDate
        }()
        let day = refCalendar.startOfDay(for: anchor)
        let key = dayKey(from: day)
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
