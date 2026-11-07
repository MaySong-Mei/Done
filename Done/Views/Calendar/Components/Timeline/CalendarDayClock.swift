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

    /// What a legend of this day would draw, as a value: two clocks whose
    /// rows would read the same compare equal, two whose rows would not
    /// compare unequal. Every standard day is one shape; a 25h day and a
    /// 24h day are two, as are a 23h day and a 25h day, or two 25h days
    /// whose clocks fall back at different hours. Compared, never rendered.
    struct Shape: Hashable {
        let isStandard: Bool
        let length: TimeInterval
        /// How far into the day the offset changes; nil without a change.
        let transitionOffset: TimeInterval?
        let offsetChange: TimeInterval
    }

    var shape: Shape {
        guard !isStandard else {
            return Shape(isStandard: true, length: Self.standardLength, transitionOffset: nil, offsetChange: 0)
        }
        return Shape(
            isStandard: false,
            length: length,
            transitionOffset: transition?.timeIntervalSince(start),
            offsetChange: offsetChange
        )
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
/// the pass the original instant is on when it is on this day's second
/// pass, so an edit that re-derives a time leaves the instant where it
/// was; a time derived from any other instant takes the first occurrence,
/// RFC 5545's rule for an ambiguous time — an anchor in standard time on
/// some other day shares the second pass's offset but is not on it. A wall
/// time the day skips resolves to the first instant after the jump
/// (gh#223's policy), not to the components carried past the gap.
nonisolated enum CalendarWallTime {
    /// The instant at `hour:minute:second` on the civil day of `day`.
    /// `original` is the instant the wall time was read off, if any: when the
    /// wall time is ambiguous and `original` is on this day's second pass,
    /// the second pass is returned. Nil only when the calendar cannot make
    /// a date at all.
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
        guard clock.repeatedPass(of: first) == 1, let original,
              clock.repeatedPass(of: original) == 2 else { return first }
        return first.addingTimeInterval(-clock.offsetChange)
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

/// Which columns of a multi-day window start an hour legend under the
/// `grouped` rule. Consecutive standard days share one legend; a day whose
/// clock is not standard has one of its own, and the standard days after
/// it start afresh. The first column always starts a group, and its legend
/// is the timeline's fixed axis — only later group starts draw a legend
/// inside their column.
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

/// Which column's clock the fixed axis draws, and which columns draw a
/// legend of their own beside it. Two rules are kept while the user
/// compares them on the device; the loser is deleted afterwards.
nonisolated enum CalendarLegendRule: String, CaseIterable {
    /// The fixed axis draws the leftmost column's clock, and every distinct
    /// clock shape in the window gets exactly one legend, carried by the
    /// first column that has it: a column draws a legend iff its rows
    /// differ from the axis's and no earlier column has the same rows. A
    /// column whose rows are the axis's never draws one, so the axis never
    /// has a legend beside it and a neighbour always lines up with it.
    case oneLegendPerClock
    /// The fixed axis draws the leftmost column's clock; every later column
    /// that starts a group (`LegendGroups`) draws its own legend.
    case grouped

    static let standard: CalendarLegendRule = .oneLegendPerClock

    /// The `UserDefaults` key the DEBUG launch argument `-dstLegendRule`
    /// writes through the argument domain. Not a setting: never written by
    /// the app, not synced, not reset, read by DEBUG builds only.
    static let debugDefaultsKey = "dstLegendRule"

    /// Tolerant of a value nothing wrote or nothing recognises: the default.
    init(stored: String?) {
        self = stored.flatMap(CalendarLegendRule.init(rawValue:)) ?? .standard
    }

    /// The rule this process draws with: in a DEBUG build the launch
    /// argument's, when one is given; a release build is hard-wired to the
    /// standard rule.
    static var current: CalendarLegendRule {
        #if DEBUG
        return CalendarLegendRule(stored: UserDefaults.standard.string(forKey: debugDefaultsKey))
        #else
        return .standard
        #endif
    }
}

/// The settled visible window of the timeline as its legends see it: the
/// clocks of its columns in order, and under the window's rule which
/// column the fixed axis draws and which columns draw a legend of their
/// own; the now-legend reads the window through `CalendarNowLegendWindow`.
nonisolated struct CalendarLegendWindow: Equatable {
    let rule: CalendarLegendRule
    /// The day offset of the first column.
    let leadingOffset: Int
    let clocks: [DayClock]
    /// The index of the column whose clock the fixed axis draws.
    let axisIndex: Int
    /// Per column, the index of the column whose legend it reads: itself
    /// when it draws one, else the column whose legend serves it — the
    /// first column of its shape, or under `grouped` its group's start.
    private let legendColumns: [Int]

    init(leadingOffset: Int, clocks: [DayClock], rule: CalendarLegendRule) {
        self.rule = rule
        self.leadingOffset = leadingOffset
        self.clocks = clocks
        switch rule {
        case .oneLegendPerClock:
            axisIndex = 0
            var firstColumnOfShape: [DayClock.Shape: Int] = [:]
            legendColumns = clocks.indices.map { index in
                let shape = clocks[index].shape
                if let first = firstColumnOfShape[shape] { return first }
                firstColumnOfShape[shape] = index
                return index
            }
        case .grouped:
            let groups = LegendGroups(clocks: clocks)
            axisIndex = 0
            legendColumns = clocks.indices.map(groups.legendColumn(for:))
        }
    }

    init(leadingOffset: Int, leadingClock: DayClock, daysCount: Int, zoneClock: CalendarZoneClock, rule: CalendarLegendRule) {
        var clocks = [leadingClock]
        if daysCount > 1 {
            for offset in 1..<daysCount {
                clocks.append(zoneClock.day(offset, from: leadingClock))
            }
        }
        self.init(leadingOffset: leadingOffset, clocks: clocks, rule: rule)
    }

    /// The clock the fixed axis is drawn for.
    var axisClock: DayClock { clocks[axisIndex] }

    /// The day offset of the column the fixed axis draws.
    var axisOffset: Int { leadingOffset + axisIndex }

    /// The instants the window covers, half-open at its end.
    var interval: DateInterval {
        DateInterval(start: clocks[0].start, end: clocks[clocks.count - 1].end)
    }

    private func index(ofOffset offset: Int) -> Int? {
        let index = offset - leadingOffset
        return clocks.indices.contains(index) ? index : nil
    }

    /// Whether the column at `offset` draws its own legend: it reads
    /// itself and is not the axis column, whose legend is the fixed axis.
    func drawsLegend(atOffset offset: Int) -> Bool {
        guard let index = index(ofOffset: offset) else { return false }
        return index != axisIndex && legendColumns[index] == index
    }

    /// The day offset of the column whose legend the column at `offset`
    /// reads — itself when it draws one, else the first column of its
    /// shape (the axis column, when that is the axis's shape), under
    /// `grouped` its group's start; nil outside the window.
    func legendColumn(atOffset offset: Int) -> Int? {
        index(ofOffset: offset).map { leadingOffset + legendColumns[$0] }
    }

    /// How many legends the window shows: the fixed axis and every column
    /// that draws its own.
    var legendCount: Int {
        1 + clocks.indices.filter { drawsLegend(atOffset: leadingOffset + $0) }.count
    }

    /// Whether the column at `offset` is one of the window's.
    func contains(offset: Int) -> Bool {
        (leadingOffset..<(leadingOffset + clocks.count)).contains(offset)
    }

    /// A single-day page: the window is the page's day alone.
    var isSingleDay: Bool { clocks.count == 1 }
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

/// The legends' settled window as the pager keeps it from one pass to the
/// next. The pager hands it the live window and the gesture state on every
/// reconcile; whether that window is taken is decided here, not in the
/// view, so the gate can be tested where it is applied.
nonisolated struct CalendarLegendWindowKeeper: Equatable {
    /// The window the legends are drawn for; nil before the first reconcile.
    private(set) var window: CalendarLegendWindow? = nil

    init() {}

    /// Takes `live` once paging rests with no pinch and no drag in
    /// progress; otherwise keeps what it had. Returns whether the window
    /// changed, so the pager writes its state only then.
    mutating func reconcile(
        live: CalendarLegendWindow,
        isPinchActive: Bool,
        isScrollInteracting: Bool,
        draggingEventID: UUID?
    ) -> Bool {
        let canSettle = calendarLegendWindowCanSettle(
            isPinchActive: isPinchActive,
            isScrollInteracting: isScrollInteracting,
            draggingEventID: draggingEventID
        )
        let next = calendarSettledLegendWindow(previous: window, live: live, canSettle: canSettle)
        guard next != window else { return false }
        window = next
        return true
    }

    /// The window to draw: the settled one, else the live one (built only
    /// when needed) before anything has settled.
    func window(orLive live: @autoclosure () -> CalendarLegendWindow) -> CalendarLegendWindow {
        window ?? live()
    }
}

// MARK: - The now-legend (gh#285 S2, round 2)

/// The settled window as the now-legend reads it: the instants its columns
/// cover, whether the page is a single day, and how the columns' hour
/// heights follow their days — so the legend can take the hour height of
/// the column it sits on.
nonisolated struct CalendarNowLegendWindow: Equatable {
    let interval: DateInterval
    let isSingleDay: Bool
    /// The timeline's own hour height and the day-length mode: a column's
    /// hour height is derived from them, as the pager derives it.
    let hourHeight: CGFloat
    let mode: DayLengthMode

    init(window: CalendarLegendWindow, hourHeight: CGFloat, mode: DayLengthMode) {
        interval = window.interval
        isSingleDay = window.isSingleDay
        self.hourHeight = hourHeight
        self.mode = mode
    }

    /// A single-day page drawn for `day` alone at `hourHeight`, the hour
    /// height its one column is drawn with.
    init(day: DayClock, hourHeight: CGFloat) {
        interval = DateInterval(start: day.start, end: day.end)
        isSingleDay = true
        self.hourHeight = hourHeight
        mode = .actual
    }

    /// Whether `now` falls on one of the window's days (half-open at the end).
    func contains(_ now: Date) -> Bool {
        now >= interval.start && now < interval.end
    }

    /// The hour height a column of `clock` is drawn with.
    func columnHourHeight(for clock: DayClock) -> CGFloat {
        calendarColumnHourHeight(hourHeight, clock: clock, mode: mode)
    }
}

/// Whether the axis shows the now-legend. A single-day page shows it only
/// while now is on that page's day, as before. A multi-day window shows it
/// whether or not today is one of its columns, as the timeline always has;
/// with today outside the window the legend reads now's wall time on the
/// axis (`calendarNowLegendPlacement`).
nonisolated func calendarNowLegendIsShown(now: Date, window: CalendarNowLegendWindow) -> Bool {
    !window.isSingleDay || window.contains(now)
}

/// Where the now-legend sits: the instant it marks, the day clock that
/// instant is positioned on, and the hour height that clock's column is
/// drawn with — the legend is level with that column's now-line, so it is
/// positioned at that column's hour height, not the axis column's.
nonisolated struct CalendarNowLegendPlacement: Equatable {
    let instant: Date
    let clock: DayClock
    let hourHeight: CGFloat
}

/// The now-legend's placement for both axis render paths (gh#80: every
/// consumer derives from this one optional); nil when the legend is not
/// shown. While today is one of the window's days the legend sits at now
/// on today's own clock, level with the now-line in today's column. When
/// today is outside the window there is no now-line, and the legend sits
/// where the axis reads now's wall time: that hour, minute and second on
/// the axis day — the first pass of a wall time the day visits twice, the
/// first instant after a jump for one it skips, the resolver's own rules.
/// On a plain axis day that is the same elapsed time since the day's
/// start as on today, so nothing moves there.
nonisolated func calendarNowLegendPlacement(
    now: Date,
    window: CalendarNowLegendWindow,
    axisClock: DayClock,
    zoneClock: CalendarZoneClock
) -> CalendarNowLegendPlacement? {
    guard calendarNowLegendIsShown(now: now, window: window) else { return nil }
    if window.contains(now) {
        let clock = axisClock.contains(now) ? axisClock : zoneClock.day(containing: now)
        return CalendarNowLegendPlacement(instant: now, clock: clock, hourHeight: window.columnHourHeight(for: clock))
    }
    let calendar = zoneClock.calendar
    let wall = calendar.dateComponents([.hour, .minute, .second], from: now)
    let instant = CalendarWallTime.instant(
        hour: wall.hour ?? 0,
        minute: wall.minute ?? 0,
        second: wall.second ?? 0,
        on: axisClock.start,
        keepingOffsetOf: nil,
        calendar: calendar
    ) ?? axisClock.start
    return CalendarNowLegendPlacement(instant: instant, clock: axisClock, hourHeight: window.columnHourHeight(for: axisClock))
}

// MARK: - Day length mode (gh#285 S1.5)

/// How a column's height follows its day's length. `actual` draws every
/// hour at one height, so a 23h day is short, a 25h day tall, and the
/// content grows to the longest day in reach; `normalized` draws every
/// column a standard day tall, a special day's hours scaled by
/// standard / length. Both place an instant at elapsed / length and draw
/// the same legends; only the column height differs.
nonisolated enum DayLengthMode: String, CaseIterable, Identifiable {
    case actual
    case normalized

    var id: String { rawValue }

    static let standard: DayLengthMode = .actual

    /// Tolerant of a value nothing wrote or nothing recognises: the default.
    init(stored: String?) {
        self = stored.flatMap(DayLengthMode.init(rawValue:)) ?? .standard
    }

    /// The mode as set in `UserDefaults`.
    static var current: DayLengthMode {
        DayLengthMode(stored: UserDefaults.standard.string(forKey: AppSettingsKeys.calendarDayLengthMode))
    }
}

/// The hour height a column of `clock` is drawn with: the timeline's own in
/// `actual`; in `normalized`, scaled by standard / length so the column is
/// a standard day tall whatever its length.
nonisolated func calendarColumnHourHeight(_ hourHeight: CGFloat, clock: DayClock, mode: DayLengthMode) -> CGFloat {
    guard mode == .normalized, clock.length > 0 else { return hourHeight }
    return hourHeight * CGFloat(DayClock.standardLength / clock.length)
}

/// The length the content is sized for: the longest day in reach in
/// `actual`, a standard day always in `normalized`.
nonisolated func calendarTimelineCanvasLength(longestInReach: TimeInterval, mode: DayLengthMode) -> TimeInterval {
    mode == .normalized ? DayClock.standardLength : longestInReach
}

/// What the pager derives from the settled window, the selected day and the
/// mode on every pass: the day the fixed axis is drawn for and at what hour
/// height, the window the now-legend reads, the day the scroll content is
/// sized for, and each column's hour height and length. The decisions live
/// here, where they can be tested; the pager builds this once per read and
/// only forwards its fields. The page builds one too, without a window:
/// its finger→time mappings and its content height read the selected
/// column's hour height and the canvas from it, so they agree with what
/// the pager draws.
nonisolated struct CalendarTimelineGeometry: Equatable {
    /// The settled legend window; nil for the page's geometry, which is
    /// anchored on the selected day alone and reads no axis field — the
    /// axis fields then describe a single-day page on that day.
    let window: CalendarLegendWindow?
    /// The selected day: what the canvas is anchored on.
    let selectedDayClock: DayClock
    /// The longest day the page holds, if it holds one longer than the
    /// selected day (the actual mode's canvas).
    let longestInReach: TimeInterval?
    /// The timeline's own hour height.
    let hourHeight: CGFloat
    let mode: DayLengthMode

    /// The day the fixed axis is drawn for: the leftmost column of the
    /// settled window (the selected day in single-day mode).
    var axisClock: DayClock { window?.axisClock ?? selectedDayClock }

    /// The hour height the fixed axis is drawn with: its day's column
    /// hour height, so a scaled special day's rows line up with its column.
    var axisHourHeight: CGFloat { columnHourHeight(for: axisClock) }

    var nowLegendWindow: CalendarNowLegendWindow {
        guard let window else {
            return CalendarNowLegendWindow(day: selectedDayClock, hourHeight: selectedColumnHourHeight)
        }
        return CalendarNowLegendWindow(window: window, hourHeight: hourHeight, mode: mode)
    }

    /// The hour height the selected day's column is drawn with. On the
    /// single-day page that column is the one under the finger, so every
    /// finger→time mapping there and every band judgement reads this, not
    /// the timeline's own hour height, which the normalized mode scales.
    var selectedColumnHourHeight: CGFloat { columnHourHeight(for: selectedDayClock) }

    /// The day the scroll content is sized for: the selected day's start,
    /// stretched to the longest day in reach when the page holds a longer
    /// one, so a column never has less room than it needs and a shorter
    /// day's tail is drawn as not this day; a standard day in `normalized`.
    var canvasClock: DayClock {
        let length: TimeInterval
        switch mode {
        case .actual: length = max(selectedDayClock.length, longestInReach ?? 0)
        case .normalized: length = DayClock.standardLength
        }
        guard abs(length - selectedDayClock.length) > 1 else { return selectedDayClock }
        return DayClock(
            start: selectedDayClock.start,
            end: selectedDayClock.start.addingTimeInterval(length),
            transition: nil,
            offsetChange: 0
        )
    }

    /// The hour height a column of `clock` is drawn with.
    func columnHourHeight(for clock: DayClock) -> CGFloat {
        calendarColumnHourHeight(hourHeight, clock: clock, mode: mode)
    }

    /// What a column of `clock` is sized for: the canvas in the actual mode
    /// (a shorter day draws its tail as not this day), itself in the
    /// normalized mode (every column fills the canvas).
    func columnCanvasLength(for clock: DayClock) -> TimeInterval {
        mode == .normalized ? clock.length : canvasClock.length
    }
}
