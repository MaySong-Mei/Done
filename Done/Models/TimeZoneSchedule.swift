import Foundation

/// One step in the user's time-zone history. Read as: "from `startDate`
/// onward (until the next entry), my home time zone was `timeZoneIdentifier`."
///
/// Used in two places:
/// 1. As a default-time-zone provider when a new event is being created or
///    edited — the picker pre-selects whichever entry covers the event's
///    start instant.
/// 2. As the rendering lens for the calendar grid: each segment defines
///    which tz the day columns are sliced in. Cutover days appear twice
///    on the calendar (once per adjacent lens) so that "subjective time"
///    on either side of the cutover is preserved.
///
/// The schedule is *not* the source of truth for an event's tz once the
/// event has been saved — every event carries its own `timeZoneIdentifier`.
/// Schedule changes therefore do not silently reinterpret existing events.
struct TimeZoneScheduleEntry: Identifiable, Codable, Hashable {
    var id: UUID
    /// Wall-clock start anchor, stored as start-of-day in
    /// `CalendarOccurrenceKey.referenceTimeZone`. Two entries with the same
    /// calendar day collapse to the most recently saved one.
    var startDate: Date
    var timeZoneIdentifier: String
    /// Free-form label ("Shanghai trip", "Moved to NY") shown in the
    /// schedule editor. Does not participate in lookup.
    var note: String

    init(
        id: UUID = UUID(),
        startDate: Date,
        timeZoneIdentifier: String,
        note: String = ""
    ) {
        self.id = id
        self.startDate = startDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.note = note
    }

    /// Resolved `TimeZone` for this entry. Falls back to the frozen
    /// reference tz if the identifier is unknown to the system.
    var resolvedTimeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? CalendarOccurrenceKey.referenceTimeZone
    }
}

extension Array where Element == TimeZoneScheduleEntry {
    /// Find the entry whose `startDate` is the latest one not after `instant`.
    /// Returns nil if no entry covers the instant (i.e., the schedule is
    /// empty or every entry starts strictly after `instant`).
    func entry(coveringInstant instant: Date) -> TimeZoneScheduleEntry? {
        sorted { $0.startDate < $1.startDate }
            .last { $0.startDate <= instant }
    }

    /// Resolved time zone covering `instant`. Returns
    /// `CalendarOccurrenceKey.referenceTimeZone` if no entry applies.
    func timeZone(coveringInstant instant: Date) -> TimeZone {
        entry(coveringInstant: instant)?.resolvedTimeZone
            ?? CalendarOccurrenceKey.referenceTimeZone
    }
}
