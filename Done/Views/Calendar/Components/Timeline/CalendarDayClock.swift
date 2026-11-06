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
nonisolated struct DayClock: Hashable {
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
        // Half-open on purpose: `DateInterval.contains` admits its end, and
        // the instant at the end of the repeated stretch is the first unique
        // one after it.
        guard let transition, let repeatedRange,
              instant >= repeatedRange.start, instant < repeatedRange.end else { return nil }
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
nonisolated struct CalendarZoneClock: Equatable {
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

    /// What the kill switch defaults to when nothing has set it: the real
    /// day length (S1); off only as a developer escape hatch.
    static let dayClockEnabledByDefault = true

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

/// Wall clock time to instant (gh#285). Foundation resolves a wall time the
/// day visits twice to its first occurrence, so rebuilding a date from its
/// components merged the second 01:15 into the first. This resolver keeps
/// the offset the original instant had when the wall time is ambiguous, so
/// an edit that re-derives a time leaves the instant where it was, and a
/// brand-new time takes the first occurrence. A wall time the day skips
/// resolves to the first instant after the jump (gh#223's policy), not to
/// the components carried past the gap.
nonisolated enum CalendarWallTime {
    /// The instant at `hour:minute:second` on the civil day of `day`.
    /// `original` is the instant the wall time was read off, if any: when the
    /// wall time is ambiguous and `original` sits at the second pass's
    /// offset, the second pass is returned. Nil only when the calendar
    /// cannot make a date at all.
    static func instant(
        hour: Int,
        minute: Int,
        second: Int = 0,
        on day: Date,
        keepingOffsetOf original: Date?,
        calendar: Calendar
    ) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let first = calendar.date(from: components) else { return nil }
        let clock = DayClock.actual(containing: day, calendar: calendar)
        let landed = calendar.dateComponents([.hour, .minute], from: first)
        if landed.hour != hour || landed.minute != minute {
            // The day has no such wall time; Foundation carried the
            // components past the gap. The first instant after the jump
            // is the honest resolution.
            if let transition = clock.transition, clock.offsetChange > 0 { return transition }
            return first
        }
        guard clock.repeatedPass(of: first) == 1, let original else { return first }
        let second = first.addingTimeInterval(-clock.offsetChange)
        let zone = calendar.timeZone
        return zone.secondsFromGMT(for: original) == zone.secondsFromGMT(for: second) ? second : first
    }

    /// `date` with its hour or minute replaced and its seconds dropped, the
    /// way a wheel picker edits a time: the instant keeps its offset when
    /// the new wall time is ambiguous.
    static func replacing(hour: Int? = nil, minute: Int? = nil, of date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return instant(
            hour: hour ?? components.hour ?? 0,
            minute: minute ?? components.minute ?? 0,
            on: date,
            keepingOffsetOf: date,
            calendar: calendar
        ) ?? date
    }

    /// Whether `date`'s wall clock time occurs twice on its day, so a
    /// display of that time needs the zone to be unambiguous.
    static func isAmbiguous(_ date: Date, calendar: Calendar) -> Bool {
        DayClock.actual(containing: date, calendar: calendar).repeatedPass(of: date) != nil
    }
}

// MARK: - Legend groups (gh#285 S2)

/// Which columns of a multi-day window start an hour legend. Consecutive
/// standard days share one legend; a day whose clock is not standard has
/// one of its own, and the standard days after it start afresh. The first
/// column always starts a group, and its legend is the timeline's fixed
/// axis — only later group starts draw a legend inside their column.
nonisolated struct LegendGroups: Equatable {
    /// Per column, whether it starts a group.
    let startsGroup: [Bool]

    init(clocks: [DayClock]) {
        var starts: [Bool] = []
        starts.reserveCapacity(clocks.count)
        for (index, clock) in clocks.enumerated() {
            let previousIsStandard = index > 0 && clocks[index - 1].isStandard
            starts.append(index == 0 || !clock.isStandard || !previousIsStandard)
        }
        startsGroup = starts
    }

    var columnCount: Int { startsGroup.count }
    var groupCount: Int { startsGroup.filter { $0 }.count }
    var groupStartIndices: [Int] { startsGroup.indices.filter { startsGroup[$0] } }

    /// The columns of each group, in order.
    var groups: [Range<Int>] {
        let starts = groupStartIndices
        return starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : columnCount
            return starts[index]..<end
        }
    }

    func startsGroup(at index: Int) -> Bool {
        startsGroup.indices.contains(index) && startsGroup[index]
    }

    /// The column whose legend column `index` reads: itself when it starts
    /// a group, else the nearest group start before it.
    func legendColumn(for index: Int) -> Int {
        guard !startsGroup.isEmpty else { return 0 }
        var column = min(max(index, 0), columnCount - 1)
        while column > 0, !startsGroup[column] { column -= 1 }
        return column
    }
}

/// The settled visible window of the timeline as its legends see it: the
/// clocks of its columns in order, grouped. The fixed axis draws the first
/// column's clock; every later column that starts a group draws its own
/// legend; the now-legend shows only while now is inside the window.
nonisolated struct CalendarLegendWindow: Equatable {
    /// The day offset of the first column.
    let leadingOffset: Int
    let clocks: [DayClock]
    let groups: LegendGroups

    init(leadingOffset: Int, leadingClock: DayClock, daysCount: Int, zoneClock: CalendarZoneClock) {
        self.leadingOffset = leadingOffset
        var clocks = [leadingClock]
        if daysCount > 1 {
            for offset in 1..<daysCount {
                clocks.append(zoneClock.day(offset, from: leadingClock))
            }
        }
        self.clocks = clocks
        groups = LegendGroups(clocks: clocks)
    }

    /// The clock the fixed axis is drawn for.
    var axisClock: DayClock { clocks[0] }

    /// The instants the window covers, half-open at its end.
    var interval: DateInterval {
        DateInterval(start: clocks[0].start, end: clocks[clocks.count - 1].end)
    }

    /// Whether the column at `offset` draws its own legend: it starts a
    /// group and is not the first column, whose legend is the fixed axis.
    func drawsLegend(atOffset offset: Int) -> Bool {
        let index = offset - leadingOffset
        return index > 0 && groups.startsGroup(at: index)
    }

    /// Whether the column at `offset` is one of the window's.
    func contains(offset: Int) -> Bool {
        (leadingOffset..<(leadingOffset + clocks.count)).contains(offset)
    }
}

/// Whether the legends may take a new window: only once paging rests, with
/// no pinch and no drag in progress. Until then the previous window stays.
nonisolated func calendarLegendWindowCanSettle(
    isPinchActive: Bool,
    isScrollInteracting: Bool,
    draggingEventID: UUID?
) -> Bool {
    !isPinchActive && !isScrollInteracting && draggingEventID == nil
}

/// The window the legends draw after this pass: the live one once settled,
/// else whatever they were drawing (the live one when nothing was yet).
nonisolated func calendarSettledLegendWindow(
    previous: CalendarLegendWindow?,
    live: CalendarLegendWindow,
    canSettle: Bool
) -> CalendarLegendWindow {
    guard let previous, !canSettle else { return live }
    return previous
}

/// Whether the axis shows the now-legend: only while `now` is inside the
/// window the legend is drawn for. A single day's window is the day itself,
/// so a page that is not today shows none, as before.
nonisolated func calendarNowLegendIsShown(now: Date, window: DateInterval) -> Bool {
    now >= window.start && now < window.end
}
