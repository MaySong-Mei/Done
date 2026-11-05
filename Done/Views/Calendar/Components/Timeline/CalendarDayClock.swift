//
//  CalendarDayClock.swift
//  Done
//
//  One civil day under a time zone, as the timeline draws it (gh#284 / #285).
//  Compiled into both Done (iOS) and DoneMac; UIKit-free.
//

import Foundation

/// One civil day under a zone: where it starts, where it ends, and how the
/// zone's offset moves inside it. A column positions an instant as
/// (instant − start) / length, hour lines sit at whole hours after `start`,
/// and the day boundary is `end` — so this is the only day geometry the
/// timeline needs, and every consumer reads it from here rather than
/// adding a day's worth of seconds to its start.
struct DayClock: Hashable {
    /// The first instant of the day.
    let start: Date
    /// The first instant of the next day.
    let end: Date
    /// The instant at which the zone's offset changes inside this day, if
    /// it does. `offsetChange` is the change in seconds from GMT at that
    /// instant: positive when the clock jumps forward (a stretch of wall
    /// clock time does not exist), negative when it falls back (a stretch is
    /// visited twice).
    let transition: Date?
    let offsetChange: TimeInterval

    /// The length of a day without a transition.
    static let standardLength: TimeInterval = 24 * 60 * 60

    var length: TimeInterval { end.timeIntervalSince(start) }

    /// A plain day: no offset change and the standard length.
    var isStandard: Bool {
        transition == nil && abs(length - Self.standardLength) < 1
    }

    /// The instants whose wall clock time the day visits twice: the first
    /// half is the first pass, the second half the second. Nil unless the
    /// clock falls back inside this day.
    var repeatedRange: DateInterval? {
        guard let transition, offsetChange < 0 else { return nil }
        return DateInterval(
            start: transition.addingTimeInterval(offsetChange),
            end: transition.addingTimeInterval(-offsetChange)
        )
    }

    /// The wall clock stretch that does not exist, as the instants its wall
    /// times would denote under the offset in force just before the jump.
    /// Nil unless the clock jumps forward inside this day.
    var missingRange: DateInterval? {
        guard let transition, offsetChange > 0 else { return nil }
        return DateInterval(start: transition, duration: offsetChange)
    }

    /// Whether `instant` belongs to this day.
    func contains(_ instant: Date) -> Bool {
        instant >= start && instant < end
    }

    /// Which pass of a twice-visited wall clock time `instant` is on: 1 for
    /// the first, 2 for the second; nil when its wall clock time is unique.
    func repeatedPass(of instant: Date) -> Int? {
        guard let transition, let repeatedRange, repeatedRange.contains(instant) else { return nil }
        return instant < transition ? 1 : 2
    }

    /// The day as the timeline drew it before gh#285: the standard length
    /// from `start`, whatever the zone does. The Mac canvas still draws this.
    static func legacy24h(start: Date) -> DayClock {
        DayClock(start: start, end: start.addingTimeInterval(standardLength), transition: nil, offsetChange: 0)
    }

    /// The real day containing `date` under `calendar`.
    static func actual(containing date: Date, calendar: Calendar) -> DayClock {
        let dayStart = calendar.startOfDay(for: date)
        guard let interval = calendar.dateInterval(of: .day, for: dayStart) else {
            return legacy24h(start: dayStart)
        }
        let zone = calendar.timeZone
        // `after:` is exclusive, and a day that has no midnight starts ON its
        // transition (America/Santiago, gh#221), so the search begins just
        // before the start.
        var transition: Date? = nil
        var change: TimeInterval = 0
        if let candidate = zone.nextDaylightSavingTimeTransition(after: interval.start.addingTimeInterval(-1)),
           candidate < interval.end {
            let before = zone.secondsFromGMT(for: candidate.addingTimeInterval(-1))
            let after = zone.secondsFromGMT(for: candidate)
            if before != after {
                transition = candidate
                change = TimeInterval(after - before)
            }
        }
        return DayClock(start: interval.start, end: interval.end, transition: transition, offsetChange: change)
    }
}

/// The clock of a zone: makes the `DayClock` of any day. Holds the calendar
/// (hence the zone) and the switch between real and legacy day lengths.
/// Built fresh from `.current` wherever `Calendar.current` used to be read,
/// so a zone change while the app runs reaches the next read the way it
/// always did; handling the change in place is left for later and would
/// land here.
struct CalendarZoneClock: Equatable {
    let calendar: Calendar
    /// False draws every day the legacy way: the standard length from its
    /// start. This is the developer kill switch of the day-clock seam; see
    /// `AppSettingsKeys.calendarDayClockEnabled`.
    let usesActualDayLength: Bool

    init(calendar: Calendar = .current, usesActualDayLength: Bool = CalendarZoneClock.dayClockEnabled) {
        self.calendar = calendar
        self.usesActualDayLength = usesActualDayLength
    }

    /// The zone the app is in right now, with the kill switch as set.
    static var current: CalendarZoneClock { CalendarZoneClock() }

    /// What the kill switch defaults to when nothing has set it.
    static let dayClockEnabledByDefault = false

    /// The kill switch as set in `UserDefaults`.
    static var dayClockEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.calendarDayClockEnabled) as? Bool
            ?? dayClockEnabledByDefault
    }

    /// The day containing `date`.
    func day(containing date: Date) -> DayClock {
        usesActualDayLength
            ? DayClock.actual(containing: date, calendar: calendar)
            : DayClock.legacy24h(start: calendar.startOfDay(for: date))
    }

    /// The day `offset` civil days away from `clock`'s day.
    func day(_ offset: Int, from clock: DayClock) -> DayClock {
        let target = calendar.date(byAdding: .day, value: offset, to: clock.start) ?? clock.start
        return day(containing: target)
    }
}
