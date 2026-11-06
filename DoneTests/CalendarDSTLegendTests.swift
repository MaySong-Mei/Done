//
//  CalendarDSTLegendTests.swift
//  DoneTests
//
//  The multi-day legends (gh#284 / #285 S2): which columns of a window
//  start a legend group, what the fixed axis and an in-column legend draw,
//  when the window settles and how the pager's geometry reads it, where
//  the now-legend sits, and the three render paths' agreement on the
//  legend inset.
//

import XCTest
import UIKit
@testable import Done

final class CalendarDSTLegendTests: XCTestCase {

    private func calendar(_ zoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID)!
        return calendar
    }

    private var newYork: Calendar { calendar("America/New_York") }
    private var cairo: Calendar { calendar("Africa/Cairo") }

    private func zone(_ calendar: Calendar) -> CalendarZoneClock {
        CalendarZoneClock(calendar: calendar, usesActualDayLength: true)
    }

    private func day(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int) -> DayClock {
        zone(calendar).day(containing: calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!)
    }

    /// A window of `daysCount` columns starting on the given New York day.
    private func newYorkWindow(_ year: Int, _ month: Int, _ dayOfMonth: Int, daysCount: Int, leadingOffset: Int = 0) -> CalendarLegendWindow {
        CalendarLegendWindow(
            leadingOffset: leadingOffset,
            leadingClock: day(newYork, year, month, dayOfMonth),
            daysCount: daysCount,
            zoneClock: zone(newYork)
        )
    }

    /// A standard day and a special one made by hand, for windows the real
    /// zones do not offer (two specials side by side).
    private let standard = DayClock.legacy24h(start: Date(timeIntervalSince1970: 1_700_000_000))
    private var special: DayClock {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return DayClock(
            start: start,
            end: start.addingTimeInterval(25 * 3600),
            transition: start.addingTimeInterval(2 * 3600),
            offsetChange: -3600
        )
    }

    // MARK: Grouping (A4)

    func testTheFiveThreeDayWindowsAroundTheFallBackDayGroupAsDecided() {
        // 24-24-24, then the 25h day walks through: [24-24][25],
        // [24][25][24], [25][24-24], and 24-24-24 again.
        XCTAssertEqual(newYorkWindow(2026, 10, 29, daysCount: 3).groups.groups, [0..<3])
        XCTAssertEqual(newYorkWindow(2026, 10, 30, daysCount: 3).groups.groups, [0..<2, 2..<3])
        XCTAssertEqual(newYorkWindow(2026, 10, 31, daysCount: 3).groups.groups, [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(newYorkWindow(2026, 11, 1, daysCount: 3).groups.groups, [0..<1, 1..<3])
        XCTAssertEqual(newYorkWindow(2026, 11, 2, daysCount: 3).groups.groups, [0..<3])
    }

    func testTheSpringForwardDayGroupsTheSameWay() {
        XCTAssertEqual(newYorkWindow(2026, 3, 5, daysCount: 3).groups.groups, [0..<3])
        XCTAssertEqual(newYorkWindow(2026, 3, 6, daysCount: 3).groups.groups, [0..<2, 2..<3])
        XCTAssertEqual(newYorkWindow(2026, 3, 7, daysCount: 3).groups.groups, [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(newYorkWindow(2026, 3, 8, daysCount: 3).groups.groups, [0..<1, 1..<3])
        XCTAssertEqual(newYorkWindow(2026, 3, 9, daysCount: 3).groups.groups, [0..<3])
    }

    func testACairoWeekWithAMidWeekTwentyFiveHourThursdayHasThreeGroups() {
        // Monday 2026-10-26 … Sunday 2026-11-01; Thursday is the fourth column.
        let week = CalendarLegendWindow(
            leadingOffset: 10, leadingClock: day(cairo, 2026, 10, 26), daysCount: 7, zoneClock: zone(cairo)
        )
        XCTAssertEqual(week.clocks.count, 7)
        XCTAssertEqual(week.clocks[3].length, 25 * 3600, "Thursday is the long day")
        XCTAssertEqual(week.groups.groups, [0..<3, 3..<4, 4..<7])
        XCTAssertEqual(week.groups.groupCount, 3)
        XCTAssertEqual(week.axisClock, week.clocks[0])
        XCTAssertEqual((10..<17).filter { week.drawsLegend(atOffset: $0) }, [13, 14],
                       "Thursday and the Friday after it draw their own legends")
    }

    func testAPlainWeekIsOneGroupWithNoInColumnLegend() {
        let week = newYorkWindow(2026, 11, 9, daysCount: 7, leadingOffset: -3)
        XCTAssertEqual(week.groups.groups, [0..<7])
        XCTAssertTrue((-3..<4).allSatisfy { !week.drawsLegend(atOffset: $0) })
        XCTAssertEqual(week.interval.start, week.clocks[0].start)
        XCTAssertEqual(week.interval.end, week.clocks[6].end)
        XCTAssertEqual(week.interval.duration, 7 * 24 * 3600)
        XCTAssertTrue(week.contains(offset: -3))
        XCTAssertTrue(week.contains(offset: 3))
        XCTAssertFalse(week.contains(offset: 4))
    }

    func testASpecialDayFirstOrLastAndTwoSpecialsInOneWindow() {
        XCTAssertEqual(LegendGroups(clocks: [special, standard, standard]).groups, [0..<1, 1..<3])
        XCTAssertEqual(LegendGroups(clocks: [standard, standard, special]).groups, [0..<2, 2..<3])
        XCTAssertEqual(LegendGroups(clocks: [standard, special, special, standard]).groups,
                       [0..<1, 1..<2, 2..<3, 3..<4])
        XCTAssertEqual(LegendGroups(clocks: [special, special]).groups, [0..<1, 1..<2])
        XCTAssertEqual(LegendGroups(clocks: [standard]).groups, [0..<1])
        XCTAssertEqual(LegendGroups(clocks: [special]).groups, [0..<1])
        XCTAssertEqual(LegendGroups(clocks: []).groups, [])
        XCTAssertEqual(LegendGroups(clocks: []).groupCount, 0)
    }

    func testEveryColumnReadsTheLegendOfItsGroupStart() {
        let groups = LegendGroups(clocks: [standard, standard, special, standard, standard])
        XCTAssertEqual(groups.groupStartIndices, [0, 2, 3])
        XCTAssertEqual((0..<5).map(groups.legendColumn(for:)), [0, 0, 2, 3, 3])
        XCTAssertTrue(groups.startsGroup(at: 0))
        XCTAssertFalse(groups.startsGroup(at: 1))
        XCTAssertFalse(groups.startsGroup(at: 9), "out of range starts nothing")
        XCTAssertEqual(LegendGroups(clocks: []).legendColumn(for: 3), 0)
    }

    // MARK: The fixed axis and the now-legend (A4, A7)

    func testTheFixedAxisReadsTheLeftmostColumnOfTheSettledWindow() {
        let octThirty = newYorkWindow(2026, 10, 30, daysCount: 3)
        XCTAssertEqual(octThirty.axisClock, day(newYork, 2026, 10, 30))
        XCTAssertTrue(octThirty.axisClock.isStandard)
        XCTAssertEqual(octThirty.clocks[2].length, 25 * 3600, "the long day is in the window but not on the axis")

        let octThirtyOne = newYorkWindow(2026, 10, 31, daysCount: 3)
        XCTAssertEqual(octThirtyOne.axisClock, day(newYork, 2026, 10, 31))
        XCTAssertTrue(octThirtyOne.axisClock.isStandard)

        let novOne = newYorkWindow(2026, 11, 1, daysCount: 3)
        XCTAssertEqual(novOne.axisClock, day(newYork, 2026, 11, 1))
        XCTAssertEqual(novOne.axisClock.length, 25 * 3600, "the long day leads, so the axis is the long one")

        // A single day's window is the day itself, with no in-column legend.
        let single = newYorkWindow(2026, 11, 1, daysCount: 1, leadingOffset: 4)
        XCTAssertEqual(single.axisClock, day(newYork, 2026, 11, 1))
        XCTAssertEqual(single.clocks.count, 1)
        XCTAssertFalse(single.drawsLegend(atOffset: 4))
        XCTAssertEqual(single.interval, DateInterval(start: single.axisClock.start, end: single.axisClock.end))
    }

    /// A New York instant by its wall clock; `pass` picks the second visit
    /// of a repeated time.
    private func newYorkInstant(_ month: Int, _ dayOfMonth: Int, _ hour: Int, _ minute: Int, second: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: month, day: dayOfMonth, hour: hour, minute: minute, second: second))!
    }

    private func placement(
        now: Date, window: CalendarLegendWindow, hourHeight: CGFloat = 56, mode: DayLengthMode = .actual
    ) -> CalendarNowLegendPlacement? {
        calendarNowLegendPlacement(
            now: now,
            window: CalendarNowLegendWindow(window: window, hourHeight: hourHeight, mode: mode),
            axisClock: window.axisClock,
            zoneClock: zone(newYork)
        )
    }

    func testTheNowLegendShowsInAnyMultiDayWindowAndOnlyOnTodaysSingleDayPage() {
        // Today is Nov 6; the window is Oct 30–Nov 1.
        let window = newYorkWindow(2026, 10, 30, daysCount: 3)
        let today = newYorkInstant(11, 6, 12, 35)
        let lastEveningOfTheWindow = Date(timeIntervalSince1970: 1_793_593_800)   // Nov 1 23:30 EST
        let firstInstantAfter = Date(timeIntervalSince1970: 1_793_595_600)        // Nov 2 00:00 EST
        let theDayBefore = Date(timeIntervalSince1970: 1_793_332_800 - 60)        // Oct 29 23:59 EDT
        let multi = CalendarNowLegendWindow(window: window, hourHeight: 56, mode: .actual)
        XCTAssertFalse(multi.isSingleDay)
        for now in [today, lastEveningOfTheWindow, firstInstantAfter, theDayBefore, window.interval.start] {
            XCTAssertTrue(calendarNowLegendIsShown(now: now, window: multi), "multi-day shows it at \(now)")
            XCTAssertNotNil(placement(now: now, window: window), "and places it at \(now)")
        }
        XCTAssertTrue(multi.contains(lastEveningOfTheWindow))
        XCTAssertFalse(multi.contains(firstInstantAfter), "half-open at the end")

        // A single-day page: only today's page shows it (the old gate).
        let single = CalendarNowLegendWindow(window: newYorkWindow(2026, 11, 1, daysCount: 1), hourHeight: 56, mode: .actual)
        XCTAssertTrue(single.isSingleDay)
        XCTAssertEqual(single, CalendarNowLegendWindow(day: day(newYork, 2026, 11, 1), hourHeight: 56), "the axis's own day is the same window")
        XCTAssertTrue(calendarNowLegendIsShown(now: lastEveningOfTheWindow, window: single))
        XCTAssertFalse(calendarNowLegendIsShown(now: firstInstantAfter, window: single))
        XCTAssertFalse(calendarNowLegendIsShown(now: today, window: single))
        XCTAssertNil(placement(now: today, window: newYorkWindow(2026, 11, 1, daysCount: 1)))
        XCTAssertNotNil(placement(now: lastEveningOfTheWindow, window: newYorkWindow(2026, 11, 1, daysCount: 1)))
    }

    func testWithTodayOutsideTheWindowTheLegendReadsNowsWallTimeOnTheAxisDay() throws {
        // The axis is the 25h day; now is 12:35 on a plain day five days
        // later. The legend sits on the row the axis labels 12:00 plus 35
        // minutes — one hour lower than now's elapsed time since its own
        // midnight, because the axis day has the repeated hour before it.
        let window = newYorkWindow(2026, 11, 1, daysCount: 3)
        XCTAssertEqual(window.axisClock.length, 25 * 3600, "fixture: the axis is the long day")
        let now = newYorkInstant(11, 6, 12, 35)
        XCTAssertEqual(now.timeIntervalSince1970, 1_793_986_500, "fixture: Nov 6 12:35 EST")
        let placed = try XCTUnwrap(placement(now: now, window: window))
        XCTAssertEqual(placed.clock, window.axisClock)
        XCTAssertEqual(placed.instant, newYorkInstant(11, 1, 12, 35))
        XCTAssertEqual(placed.instant.timeIntervalSince(window.axisClock.start), 13.5833 * 3600, accuracy: 1)

        let hourHeight: CGFloat = 56
        let header: CGFloat = 16
        let legendY = calendarTimelineNowLegendY(for: placed.instant, clock: placed.clock, headerHeight: header, hourHeight: hourHeight)
        let onTodaysClock = calendarTimelineNowLegendY(
            for: now, clock: zone(newYork).day(containing: now), headerHeight: header, hourHeight: hourHeight
        )
        XCTAssertEqual(legendY!, onTodaysClock! + hourHeight, accuracy: 0.001, "one hour lower than elapsed-since-midnight")
        // The row the axis labels 12:00 is the fourteenth (0, 1 EDT, 1 EST, 2 … 12).
        let rows = axisRows(clock: window.axisClock, slotMinutes: 60)
        let twelve = try XCTUnwrap(rows.first { $0.1.text == "12:00" })
        XCTAssertEqual(twelve.0, 13)
        let rowLineY = header + CGFloat(twelve.0) * hourHeight
        XCTAssertEqual(legendY!, rowLineY + 35.0 / 60 * hourHeight - calendarTimelineNowLegendLabelHeight / 2, accuracy: 0.001)

        // Control: a plain axis day reads the same as today's clock would.
        let plainWindow = newYorkWindow(2026, 11, 10, daysCount: 3)
        let plainPlaced = try XCTUnwrap(placement(now: now, window: plainWindow))
        XCTAssertEqual(plainPlaced.clock, plainWindow.axisClock)
        XCTAssertEqual(
            calendarTimelineNowLegendY(for: plainPlaced.instant, clock: plainPlaced.clock, headerHeight: header, hourHeight: hourHeight)!,
            onTodaysClock!, accuracy: 0.001, "a plain axis day: identical to the old position"
        )
    }

    func testAnAmbiguousWallTimeSitsOnTheFirstRepeatedRowOfTheAxisDay() throws {
        // Now is 01:30 on a plain day; the axis is the fall-back day, which
        // has two 1:00 rows. The legend takes the first (EDT) one.
        let window = newYorkWindow(2026, 11, 1, daysCount: 3)
        let now = newYorkInstant(11, 6, 1, 30)
        let placed = try XCTUnwrap(placement(now: now, window: window))
        XCTAssertEqual(placed.clock, window.axisClock)
        XCTAssertEqual(window.axisClock.repeatedPass(of: placed.instant), 1)
        XCTAssertEqual(placed.instant.timeIntervalSince(window.axisClock.start), 1.5 * 3600, accuracy: 0.001)
        let rows = axisRows(clock: window.axisClock, slotMinutes: 60)
        XCTAssertEqual(rows[1].1.text, "1:00")
        XCTAssertEqual(rows[1].1.zoneAbbreviation, "EDT")
        XCTAssertEqual(rows[2].1.zoneAbbreviation, "EST")
        let legendY = calendarTimelineNowLegendY(for: placed.instant, clock: placed.clock, headerHeight: 16, hourHeight: 56)
        XCTAssertEqual(legendY!, 16 + 1.5 * 56 - calendarTimelineNowLegendLabelHeight / 2, accuracy: 0.001)

        // A skipped wall time lands on the first instant after the jump:
        // 02:30 on the spring-forward axis is the 3:00 row.
        let spring = newYorkWindow(2026, 3, 8, daysCount: 3)
        let springPlaced = try XCTUnwrap(placement(now: newYorkInstant(11, 6, 2, 30), window: spring))
        XCTAssertEqual(springPlaced.instant, try XCTUnwrap(spring.axisClock.transition))
        XCTAssertEqual(springPlaced.instant.timeIntervalSince(spring.axisClock.start), 2 * 3600, accuracy: 0.001)
    }

    func testWithTodayInsideTheWindowTheLegendSitsOnTodaysOwnClock() throws {
        // Nov 5–7 with today Nov 6: the axis is Nov 5, today is the middle
        // column, and the legend aligns with the now-line there, as before.
        let window = newYorkWindow(2026, 11, 5, daysCount: 3)
        let now = newYorkInstant(11, 6, 12, 35)
        let placed = try XCTUnwrap(placement(now: now, window: window))
        XCTAssertEqual(placed.instant, now)
        XCTAssertEqual(placed.clock, day(newYork, 2026, 11, 6))
        XCTAssertNotEqual(placed.clock, window.axisClock)
        XCTAssertEqual(
            calendarTimelineNowLegendY(for: placed.instant, clock: placed.clock, headerHeight: 16, hourHeight: 56)!,
            16 + 12.5833 * 56 - calendarTimelineNowLegendLabelHeight / 2, accuracy: 0.1
        )
        // Today on the axis itself: the axis clock.
        let onAxis = try XCTUnwrap(placement(now: now, window: newYorkWindow(2026, 11, 6, daysCount: 3)))
        XCTAssertEqual(onAxis.clock, day(newYork, 2026, 11, 6))
        XCTAssertEqual(onAxis.instant, now)
        // The fall-back day as today, inside its window: its own 25h clock,
        // so the evening sits past the repeated hour.
        let fallBackEvening = Date(timeIntervalSince1970: 1_793_593_800)   // Nov 1 23:30 EST
        let onFallBack = try XCTUnwrap(placement(now: fallBackEvening, window: newYorkWindow(2026, 10, 30, daysCount: 3)))
        XCTAssertEqual(onFallBack.clock, fallBack)
        XCTAssertEqual(onFallBack.instant.timeIntervalSince(fallBack.start), 24.5 * 3600, accuracy: 1)
    }

    func testTheLayerAxisShowsTheLegendForAMultiDayWindowWithoutTodayAndHidesItOnAnotherDaysSinglePage() {
        // The CALayer axis wired to real inputs: the legend's shown state
        // and frame follow the placement, so a window gate put back in
        // `updateNowLegend` would hide what this test sees.
        let axis = TimeAxisLayerView(frame: CGRect(x: 0, y: 0, width: 26, height: 3000))
        let now = newYorkInstant(11, 6, 12, 35)
        let header: CGFloat = 16
        let hourHeight: CGFloat = 56
        let labelTop = calendarTimelineNowLegendLabelHeight / 2

        // Oct 30–Nov 1, today outside: shown, at 12:35 read on Oct 30.
        let octWindow = newYorkWindow(2026, 10, 30, daysCount: 3)
        applyAxis(axis, clock: octWindow.axisClock, nowLegendWindow: CalendarNowLegendWindow(window: octWindow, hourHeight: 56, mode: .actual))
        axis.debugRefreshNowDependentState(now: now)
        var legend = axis.debugNowLegend()
        XCTAssertTrue(legend.isVisible, "a multi-day window shows the legend without today in it")
        XCTAssertEqual(legend.frame.minY, header + 12.5833 * hourHeight - labelTop, accuracy: 0.1)
        XCTAssertEqual(legend.frame.height, calendarTimelineNowLegendLabelHeight)
        XCTAssertEqual(legend.text, TimeAxisLayerView.currentTimeText(for: now))

        // Nov 1–3, today outside: on the 25h axis the same wall time is a
        // row lower, and the 12:00 label yields to it.
        let novWindow = newYorkWindow(2026, 11, 1, daysCount: 3)
        applyAxis(axis, clock: novWindow.axisClock, nowLegendWindow: CalendarNowLegendWindow(window: novWindow, hourHeight: 56, mode: .actual))
        axis.debugRefreshNowDependentState(now: now)
        legend = axis.debugNowLegend()
        XCTAssertTrue(legend.isVisible)
        XCTAssertEqual(legend.frame.minY, header + 13.5833 * hourHeight - labelTop, accuracy: 0.1)
        let twelve = axis.debugHourLabels().first { $0.text == "12:00" }
        XCTAssertEqual(twelve?.slotIndex, 13)
        XCTAssertEqual(legend.frame.minY, (twelve?.frame.minY ?? 0) + 2 + 35.0 / 60 * hourHeight - labelTop, accuracy: 0.1)

        // Nov 5–7, today inside but not on the axis: today's own clock.
        let thisWindow = newYorkWindow(2026, 11, 5, daysCount: 3)
        applyAxis(axis, clock: thisWindow.axisClock, nowLegendWindow: CalendarNowLegendWindow(window: thisWindow, hourHeight: 56, mode: .actual))
        axis.debugRefreshNowDependentState(now: now)
        legend = axis.debugNowLegend()
        XCTAssertTrue(legend.isVisible)
        XCTAssertEqual(legend.frame.minY, header + 12.5833 * hourHeight - labelTop, accuracy: 0.1)

        // A single-day page that is not today: hidden.
        applyAxis(axis, clock: day(newYork, 2026, 10, 30), nowLegendWindow: CalendarNowLegendWindow(day: day(newYork, 2026, 10, 30), hourHeight: 56))
        axis.debugRefreshNowDependentState(now: now)
        XCTAssertFalse(axis.debugNowLegend().isVisible, "another day's single page shows no legend")
        // Today's single page: shown again.
        applyAxis(axis, clock: day(newYork, 2026, 11, 6), nowLegendWindow: CalendarNowLegendWindow(day: day(newYork, 2026, 11, 6), hourHeight: 56))
        axis.debugRefreshNowDependentState(now: now)
        legend = axis.debugNowLegend()
        XCTAssertTrue(legend.isVisible)
        XCTAssertEqual(legend.frame.minY, header + 12.5833 * hourHeight - labelTop, accuracy: 0.1)
    }

    func testInTheNormalizedModeTheLegendOnAnotherColumnSitsAtThatColumnsHourHeight() throws {
        // Nov 1–3 drawn normalized: the axis is the 25h day at hh × 24/25;
        // today is Nov 2, a plain column at hh. The legend sits level with
        // today's now-line — twenty hours down at hh, not at the axis's
        // scaled hour height — and the axis label it covers is the one at
        // that height: the 25h axis's "20:00" row, an elapsed hour lower
        // than a plain axis's. (review round 3, F6)
        let axis = TimeAxisLayerView(frame: CGRect(x: 0, y: 0, width: 26, height: 3000))
        let window = newYorkWindow(2026, 11, 1, daysCount: 3)
        let hourHeight: CGFloat = 56
        let axisHourHeight = calendarColumnHourHeight(hourHeight, clock: window.axisClock, mode: .normalized)
        XCTAssertEqual(axisHourHeight, 56 * 24 / 25, accuracy: 0.0001, "fixture: the axis column is scaled")
        applyAxis(
            axis, clock: window.axisClock, hourHeight: axisHourHeight,
            nowLegendWindow: CalendarNowLegendWindow(window: window, hourHeight: hourHeight, mode: .normalized)
        )
        let now = newYorkInstant(11, 2, 20, 0)
        axis.debugRefreshNowDependentState(now: now)
        let legend = axis.debugNowLegend()
        XCTAssertTrue(legend.isVisible)
        XCTAssertEqual(
            legend.frame.minY, 16 + 20 * hourHeight - calendarTimelineNowLegendLabelHeight / 2, accuracy: 0.1,
            "level with today's now-line, at today's column hour height"
        )
        let labels = axis.debugHourLabels()
        let twenty = try XCTUnwrap(labels.first { $0.text == "20:00" })
        XCTAssertEqual(twenty.slotIndex, 21, "fixture: on the 25h axis the 20:00 row is an elapsed hour lower")
        XCTAssertEqual(twenty.frame.minY, 16 + 21 * axisHourHeight - 2, accuracy: 0.1, "fixture: drawn at the axis's scaled hour height")
        XCTAssertLessThan(abs(twenty.frame.minY + 2 - (legend.frame.minY + calendarTimelineNowLegendLabelHeight / 2)), 10, "fixture: the row the legend covers")
        XCTAssertEqual(twenty.alpha, 0, "the row the legend covers yields")
        XCTAssertEqual(labels.first { $0.text == "19:00" }?.alpha, 1, "the row an elapsed hour above, which the unscaled reading would have hidden, does not")
        XCTAssertEqual(labels.first { $0.text == "21:00" }?.alpha, 1)

        // Control: the same window in the actual mode, every column at hh —
        // the legend and the yielding row are where round 2 left them.
        applyAxis(
            axis, clock: window.axisClock, hourHeight: hourHeight,
            nowLegendWindow: CalendarNowLegendWindow(window: window, hourHeight: hourHeight, mode: .actual)
        )
        axis.debugRefreshNowDependentState(now: now)
        XCTAssertEqual(axis.debugNowLegend().frame.minY, 16 + 20 * hourHeight - calendarTimelineNowLegendLabelHeight / 2, accuracy: 0.1)
        XCTAssertEqual(axis.debugHourLabels().first { $0.text == "19:00" }?.alpha, 0, "actual: twenty hours down is the 19:00 row of the 25h axis")
        XCTAssertEqual(axis.debugHourLabels().first { $0.text == "20:00" }?.alpha, 1)
    }

    func testThePlacementCarriesTheHourHeightOfTheColumnItSitsOn() throws {
        // Normalized, Nov 1–3, today Nov 2 20:00: the legend is on today's
        // plain column, at the timeline's hour height, while the axis
        // column is scaled; its Y is today's now-line, and read back in the
        // axis's minutes it is past the axis's twenty-first hour.
        let window = newYorkWindow(2026, 11, 1, daysCount: 3)
        let hourHeight: CGFloat = 56
        let axisHourHeight = calendarColumnHourHeight(hourHeight, clock: window.axisClock, mode: .normalized)
        let now = newYorkInstant(11, 2, 20, 0)
        let onToday = try XCTUnwrap(placement(now: now, window: window, hourHeight: hourHeight, mode: .normalized))
        XCTAssertEqual(onToday.clock, day(newYork, 2026, 11, 2))
        XCTAssertEqual(onToday.hourHeight, hourHeight, "a plain column is unscaled")
        XCTAssertNotEqual(onToday.hourHeight, axisHourHeight)
        let legendY = try XCTUnwrap(calendarTimelineNowLegendY(for: onToday.instant, clock: onToday.clock, headerHeight: 16, hourHeight: onToday.hourHeight))
        XCTAssertEqual(legendY, 16 + 20 * hourHeight - calendarTimelineNowLegendLabelHeight / 2, accuracy: 0.001)
        let axisMinutes = calendarNowLegendAxisMinutes(placement: onToday, axisHourHeight: axisHourHeight)
        XCTAssertEqual(axisMinutes, 20 * 60 * 25 / 24, accuracy: 0.001)
        XCTAssertTrue(calendarShouldHideLegendHourLabel(legendTotalMinutes: 21 * 60, nowTotalMinutes: axisMinutes, hourHeight: axisHourHeight), "the 20:00 row of the 25h axis")
        XCTAssertFalse(calendarShouldHideLegendHourLabel(legendTotalMinutes: 20 * 60, nowTotalMinutes: axisMinutes, hourHeight: axisHourHeight), "not the 19:00 row")

        // Today on the axis column itself: the axis's scaled hour height.
        let onAxis = try XCTUnwrap(placement(now: newYorkInstant(11, 1, 20, 0), window: window, hourHeight: hourHeight, mode: .normalized))
        XCTAssertEqual(onAxis.clock, window.axisClock)
        XCTAssertEqual(onAxis.hourHeight, axisHourHeight, accuracy: 0.0001)
        XCTAssertEqual(calendarNowLegendAxisMinutes(placement: onAxis, axisHourHeight: axisHourHeight), 21 * 60, accuracy: 0.001, "20:00 EST is the twenty-first elapsed hour")
        // Today outside the window: read on the axis, at the axis's.
        let outside = try XCTUnwrap(placement(now: newYorkInstant(11, 6, 12, 35), window: window, hourHeight: hourHeight, mode: .normalized))
        XCTAssertEqual(outside.clock, window.axisClock)
        XCTAssertEqual(outside.hourHeight, axisHourHeight, accuracy: 0.0001)
        // The actual mode: the timeline's hour height everywhere, and the
        // axis minutes are the plain elapsed minutes.
        let actual = try XCTUnwrap(placement(now: now, window: window, hourHeight: hourHeight, mode: .actual))
        XCTAssertEqual(actual.hourHeight, hourHeight)
        XCTAssertEqual(calendarNowLegendAxisMinutes(placement: actual, axisHourHeight: hourHeight), 20 * 60, accuracy: 0.001)
        // A single-day page: the one column's hour height, as given.
        let single = CalendarNowLegendWindow(day: window.axisClock, hourHeight: axisHourHeight)
        let onPage = try XCTUnwrap(calendarNowLegendPlacement(now: newYorkInstant(11, 1, 20, 0), window: single, axisClock: window.axisClock, zoneClock: zone(newYork)))
        XCTAssertEqual(onPage.hourHeight, axisHourHeight, accuracy: 0.0001)
    }

    // MARK: Settle gating (A5)

    func testTheKeeperTakesTheLiveWindowOnlyOnSettleAndReportsTheChange() {
        // The pager hands the keeper the live window and the gesture state;
        // the keeper applies the gate, so a bypass of it fails here.
        var keeper = CalendarLegendWindowKeeper()
        XCTAssertNil(keeper.window)
        let first = newYorkWindow(2026, 10, 30, daysCount: 3, leadingOffset: -7)
        let second = newYorkWindow(2026, 10, 31, daysCount: 3, leadingOffset: -6)
        XCTAssertEqual(keeper.window(orLive: first), first, "nothing settled yet: the live window stands in")
        XCTAssertTrue(
            keeper.reconcile(live: first, isPinchActive: false, isScrollInteracting: true, draggingEventID: nil),
            "with nothing settled the live window is taken even mid-swipe"
        )
        XCTAssertEqual(keeper.window, first)

        XCTAssertFalse(keeper.reconcile(live: second, isPinchActive: false, isScrollInteracting: true, draggingEventID: nil), "mid-swipe: kept")
        XCTAssertFalse(keeper.reconcile(live: second, isPinchActive: true, isScrollInteracting: false, draggingEventID: nil), "pinching: kept")
        XCTAssertFalse(keeper.reconcile(live: second, isPinchActive: false, isScrollInteracting: false, draggingEventID: UUID()), "dragging: kept")
        XCTAssertEqual(keeper.window, first)
        XCTAssertEqual(keeper.window(orLive: second), first, "the legends draw the kept window, not the live one")
        XCTAssertEqual(
            keeper.window(orLive: { () -> CalendarLegendWindow in XCTFail("the live window is not built once one has settled"); return second }()), first
        )

        XCTAssertTrue(keeper.reconcile(live: second, isPinchActive: false, isScrollInteracting: false, draggingEventID: nil), "at rest: taken")
        XCTAssertEqual(keeper.window, second)
        XCTAssertFalse(keeper.reconcile(live: second, isPinchActive: false, isScrollInteracting: false, draggingEventID: nil), "the same window is no change")
    }

    func testTheWindowIsFrozenWhileSwipingPinchingOrDraggingAndMovesOnSettle() {
        XCTAssertTrue(calendarLegendWindowCanSettle(isPinchActive: false, isScrollInteracting: false, draggingEventID: nil))
        XCTAssertFalse(calendarLegendWindowCanSettle(isPinchActive: true, isScrollInteracting: false, draggingEventID: nil))
        XCTAssertFalse(calendarLegendWindowCanSettle(isPinchActive: false, isScrollInteracting: true, draggingEventID: nil))
        XCTAssertFalse(calendarLegendWindowCanSettle(isPinchActive: false, isScrollInteracting: false, draggingEventID: UUID()))

        let before = newYorkWindow(2026, 10, 30, daysCount: 3, leadingOffset: -7)
        let live = newYorkWindow(2026, 10, 31, daysCount: 3, leadingOffset: -6)
        XCTAssertEqual(calendarSettledLegendWindow(previous: before, live: live, canSettle: false), before,
                       "mid-swipe the legends keep the old grouping")
        XCTAssertEqual(calendarSettledLegendWindow(previous: before, live: live, canSettle: true), live,
                       "on settle they take the new one")
        XCTAssertEqual(calendarSettledLegendWindow(previous: nil, live: live, canSettle: false), live,
                       "with nothing settled yet the live window stands in")
    }

    // MARK: The pager's geometry (A4, A8)

    private var plain: DayClock { day(newYork, 2026, 11, 10) }
    private var springForward: DayClock { day(newYork, 2026, 3, 8) }

    func testTheGeometryDrawsTheAxisForTheWindowsLeftmostDayAtItsColumnsHourHeight() {
        // Oct 30–Nov 1 with Oct 31 selected: the axis is Oct 30, not the
        // selected day, and a plain axis day is unscaled in both modes.
        let window = newYorkWindow(2026, 10, 30, daysCount: 3, leadingOffset: -7)
        let selected = day(newYork, 2026, 10, 31)
        for mode in DayLengthMode.allCases {
            let geometry = CalendarTimelineGeometry(
                window: window, selectedDayClock: selected, longestInReach: 25 * 3600, hourHeight: 56, mode: mode
            )
            XCTAssertEqual(geometry.axisClock, day(newYork, 2026, 10, 30), "\(mode)")
            XCTAssertNotEqual(geometry.axisClock, selected, "\(mode): not the selected day")
            XCTAssertEqual(geometry.axisHourHeight, 56, "\(mode): a plain axis day keeps the hour height")
            XCTAssertEqual(geometry.nowLegendWindow, CalendarNowLegendWindow(window: window, hourHeight: 56, mode: mode), "\(mode)")
        }

        // Nov 1–3 with Nov 2 selected: the axis is the 25h day. Actual
        // keeps its hour height; normalized scales the axis with its column.
        let long = newYorkWindow(2026, 11, 1, daysCount: 3, leadingOffset: -5)
        let novTwo = day(newYork, 2026, 11, 2)
        let actual = CalendarTimelineGeometry(window: long, selectedDayClock: novTwo, longestInReach: 25 * 3600, hourHeight: 56, mode: .actual)
        XCTAssertEqual(actual.axisClock.length, 25 * 3600)
        XCTAssertEqual(actual.axisHourHeight, 56)
        XCTAssertEqual(actual.columnHourHeight(for: fallBack), 56)
        XCTAssertEqual(actual.columnHourHeight(for: springForward), 56)
        XCTAssertEqual(actual.columnHourHeight(for: plain), 56)

        let normalized = CalendarTimelineGeometry(window: long, selectedDayClock: novTwo, longestInReach: 25 * 3600, hourHeight: 56, mode: .normalized)
        XCTAssertEqual(normalized.axisHourHeight, 56 * 24 / 25, accuracy: 0.0001)
        XCTAssertEqual(normalized.columnHourHeight(for: fallBack), 56 * 24 / 25, accuracy: 0.0001)
        XCTAssertEqual(normalized.columnHourHeight(for: springForward), 56 * 24 / 23, accuracy: 0.0001)
        XCTAssertEqual(normalized.columnHourHeight(for: plain), 56)
        XCTAssertEqual(
            normalized.axisHourHeight, normalized.columnHourHeight(for: normalized.axisClock),
            "the axis is drawn at its own column's hour height"
        )

        // The canvas: actual stretches the selected day to the longest in
        // reach and sizes every column to it; normalized is a standard day
        // and each column is itself.
        XCTAssertEqual(actual.canvasClock.start, novTwo.start)
        XCTAssertEqual(actual.canvasClock.length, 25 * 3600)
        XCTAssertNil(actual.canvasClock.transition)
        XCTAssertEqual(actual.columnCanvasLength(for: novTwo), 25 * 3600, "a plain column draws the extra hour as a tail")
        XCTAssertEqual(actual.columnCanvasLength(for: fallBack), 25 * 3600)
        XCTAssertEqual(normalized.canvasClock.length, 24 * 3600)
        XCTAssertEqual(normalized.columnCanvasLength(for: fallBack), 25 * 3600, "normalized: a column is its own day")
        XCTAssertEqual(normalized.columnCanvasLength(for: springForward), 23 * 3600)
        XCTAssertEqual(normalized.columnCanvasLength(for: plain), 24 * 3600)
        // Nothing longer in reach: the selected day itself, transition kept.
        let onLong = CalendarTimelineGeometry(window: long, selectedDayClock: fallBack, longestInReach: nil, hourHeight: 56, mode: .actual)
        XCTAssertEqual(onLong.canvasClock, fallBack)
        let shorterInReach = CalendarTimelineGeometry(window: long, selectedDayClock: fallBack, longestInReach: 24 * 3600, hourHeight: 56, mode: .actual)
        XCTAssertEqual(shorterInReach.canvasClock, fallBack)
    }

    // MARK: In-column legend rows (S2 §2)

    private func occurrence(_ title: String, epoch: TimeInterval, seconds: TimeInterval) -> CalendarLayout.EventOccurrence {
        let range = Event.TimeRange(
            start: Date(timeIntervalSince1970: epoch),
            end: Date(timeIntervalSince1970: epoch + seconds)
        )
        let id = UUID()
        return CalendarLayout.EventOccurrence(
            id: "\(title)-\(id.uuidString)",
            event: Event(id: id, title: title, timeRanges: [range], type: "Work"),
            range: range
        )
    }

    private func model(
        _ occurrences: [CalendarLayout.EventOccurrence],
        clock: DayClock,
        hourHeight: CGFloat,
        legend: CalendarColumnLegend?,
        leading: Int = 0,
        drawableLeading: Int = 0
    ) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: clock.start,
            dayClock: clock,
            canvasLength: 25 * 3600,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: 16,
            hourHeight: hourHeight,
            eventHorizontalInset: 8,
            legend: legend,
            leadingExtendedHours: leading,
            trailingExtendedHours: 0,
            drawableLeadingHours: drawableLeading,
            drawableTrailingHours: 0,
            useImperativeDayLayerModel: false,
            showEventText: true,
            isWeekMode: false,
            isThreeDayMode: true,
            titleFontSizeSetting: 13,
            showTimeBelowTitle: true,
            multiTypeEnabled: false,
            nearFutureHorizonDays: 7,
            isPinchActive: false,
            frozenSlotMinutes: nil
        )
    }

    private var fallBack: DayClock { day(newYork, 2026, 11, 1) }

    private func axisRows(clock: DayClock, slotMinutes: Int, leading: Int = 0, is24: Bool = true) -> [(Int, CalendarAxisHourLabel)] {
        let slotCount = calendarTimelineVisibleMinutes(clock: clock, leadingExtendedHours: leading) / slotMinutes + 1
        return (0..<slotCount).compactMap { index in
            TimeAxisLayerView.labelText(
                forSlot: index, slotMinutes: slotMinutes, leadingExtendedHours: leading,
                clock: clock, zoneClock: zone(newYork), is24: is24
            ).map { (index, $0) }
        }
    }

    func testAnInColumnLegendDrawsTheRowsTheFixedAxisWouldForTheSameClock() {
        let legend = CalendarColumnLegend.standard(zoneClock: zone(newYork))
        for (hourHeight, slotMinutes) in [(CGFloat(56), 60), (CGFloat(80), 30)] {
            let rows = DayLayerHostView.legendRows(
                model: model([], clock: fallBack, hourHeight: hourHeight, legend: legend), is24: true
            )
            let axis = axisRows(clock: fallBack, slotMinutes: slotMinutes)
            XCTAssertEqual(rows.count, 26, "slot \(slotMinutes): twenty-six rows on the 25h day")
            XCTAssertEqual(rows.map(\.slotIndex), axis.map { $0.0 }, "slot \(slotMinutes): the same slots")
            XCTAssertEqual(rows.map(\.label), axis.map { $0.1 }, "slot \(slotMinutes): the same labels")
            XCTAssertEqual(rows[1].label.zoneAbbreviation, "EDT")
            XCTAssertEqual(rows[2].label.zoneAbbreviation, "EST")
        }
        // The band above is labelled by the previous day's clock, as on the axis.
        let banded = DayLayerHostView.legendRows(
            model: model([], clock: fallBack, hourHeight: 56, legend: legend, leading: 12, drawableLeading: 12), is24: true
        )
        let bandedAxis = axisRows(clock: fallBack, slotMinutes: 60, leading: 12)
        XCTAssertEqual(banded.count, 38)
        XCTAssertEqual(banded.map(\.label), bandedAxis.map { $0.1 })
        XCTAssertEqual(banded[0].label.text, "12:00")
    }

    func testTheNarrowLegendShowsTheHourNumberAlone() {
        let narrow = CalendarColumnLegend.narrow(zoneClock: zone(newYork))
        let rows = DayLayerHostView.legendRows(model: model([], clock: fallBack, hourHeight: 56, legend: narrow), is24: true)
        XCTAssertEqual(rows.map { narrow.text(of: $0.label) }, ["0", "1", "1"] + (2...23).map(String.init) + ["0"])
        let twelveHour = DayLayerHostView.legendRows(model: model([], clock: fallBack, hourHeight: 56, legend: narrow), is24: false)
        let morning: [String] = (2...11).map { String($0) }
        let afternoon: [String] = (1...11).map { String($0) }
        let expectedTwelveHour: [String] = ["12", "1", "1"] + morning + ["12"] + afternoon + ["12"]
        XCTAssertEqual(twelveHour.map { narrow.text(of: $0.label) }, expectedTwelveHour)
        XCTAssertEqual(twelveHour[1].label.text, "1 am", "the full text is still there for the wide form")
        XCTAssertEqual(rows[2].label.zoneAbbreviation, "EST", "the narrow form keeps the zone")
    }

    func testAStandardColumnHasNoLegendAndTheEventAreaIsUnchanged() {
        let plain = model([], clock: day(newYork, 2026, 11, 10), hourHeight: 56, legend: nil)
        XCTAssertTrue(DayLayerHostView.legendRows(model: plain, is24: true).isEmpty)
        XCTAssertEqual(plain.eventAreaLeadingInset, 8)
        XCTAssertEqual(plain.eventAreaWidth, 344)

        let block = occurrence("plain", epoch: day(newYork, 2026, 11, 10).start.timeIntervalSince1970 + 9 * 3600, seconds: 3600)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
        host.apply(model([block], clock: day(newYork, 2026, 11, 10), hourHeight: 56, legend: nil))
        host.layoutIfNeeded()
        let state = host.debugLegendState()
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.opacity, 0)
        XCTAssertFalse(state.fading)
        XCTAssertEqual(host.debugHitFrame(of: block.id)?.minX, 8)
        XCTAssertEqual(host.debugHitFrame(of: block.id)?.width, 344)
        XCTAssertEqual(host.debugGridSpan()?.x, 8)
        XCTAssertEqual(host.debugGridSpan()?.width, 344)
    }

    func testTheLegendTextsFitTheirInsets() {
        let inset: CGFloat = 4   // the multi-day column inset
        func width(_ text: String, size: CGFloat) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: .semibold)]).width
        }
        let standard = CalendarColumnLegend.standard(zoneClock: zone(newYork))
        let narrow = CalendarColumnLegend.narrow(zoneClock: zone(newYork))
        let standardRoom = inset + standard.width - CalendarColumnLegend.trailingPadding
        let narrowRoom = inset + narrow.width - CalendarColumnLegend.trailingPadding
        for hour in 0...23 {
            for is24 in [true, false] {
                let label = CalendarAxisHourLabel(
                    text: calendarHourAxisLabel(hour24: hour, is24: is24),
                    narrowText: calendarHourAxisNarrowLabel(hour24: hour, is24: is24),
                    zoneAbbreviation: nil
                )
                XCTAssertLessThanOrEqual(width(standard.text(of: label), size: standard.hourFontSize), standardRoom, "\(label.text)")
                XCTAssertLessThanOrEqual(width(narrow.text(of: label), size: narrow.hourFontSize), narrowRoom, "\(label.narrowText)")
            }
        }
        // Named zones, and the nameless "GMT±N" form Foundation gives zones
        // such as Africa/Cairo, which the narrow legend folds to its offset.
        for zone in ["EDT", "EST", "CEST", "EEST", "AEDT", "BST", "GMT+2", "GMT+3", "GMT+12", "GMT-3:30"] {
            let label = CalendarAxisHourLabel(text: "1:00", narrowText: "1", zoneAbbreviation: zone)
            XCTAssertLessThanOrEqual(width(standard.zoneText(of: label)!, size: standard.zoneFontSize), standardRoom, zone)
            XCTAssertLessThanOrEqual(width(narrow.zoneText(of: label)!, size: narrow.zoneFontSize), narrowRoom, zone)
        }
        XCTAssertEqual(calendarNarrowZoneAbbreviation("GMT+3"), "+3")
        XCTAssertEqual(calendarNarrowZoneAbbreviation("GMT-3:30"), "-3:30")
        XCTAssertEqual(calendarNarrowZoneAbbreviation("EDT"), "EDT")
        XCTAssertEqual(calendarNarrowZoneAbbreviation("GMT"), "GMT")
        let cairo = CalendarAxisHourLabel(text: "23:00", narrowText: "23", zoneAbbreviation: "GMT+3")
        XCTAssertEqual(narrow.zoneText(of: cairo), "+3")
        XCTAssertEqual(standard.zoneText(of: cairo), "+3", "the wide form folds too; only the fixed axis has room for the prefix")
        let named = CalendarAxisHourLabel(text: "1:00", narrowText: "1", zoneAbbreviation: "EDT")
        XCTAssertEqual(standard.zoneText(of: named), "EDT")
        XCTAssertEqual(narrow.zoneText(of: named), "EDT")
        XCTAssertNil(narrow.zoneText(of: CalendarAxisHourLabel(text: "2:00", narrowText: "2", zoneAbbreviation: nil)))
    }

    // MARK: The three render paths agree on the legend inset

    func testRenderRepaintAndCullAllPlaceBlocksPastTheLegend() {
        // A9 09:00–10:00 EST, B1 01:15–01:45 EDT, C1 01:15–01:45 EST.
        let a9 = occurrence("A9", epoch: 1_793_541_600, seconds: 3600)
        let b1 = occurrence("B1", epoch: 1_793_510_100, seconds: 1800)
        let c1 = occurrence("C1", epoch: 1_793_513_700, seconds: 1800)
        let all = [a9, b1, c1]
        let legend = CalendarColumnLegend.standard(zoneClock: zone(newYork))
        let leadingInset: CGFloat = 8 + 26
        let areaWidth: CGFloat = 360 - 16 - 26

        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
        scroll.contentSize = host.bounds.size
        scroll.addSubview(host)

        func expectGeometry(hourHeight hh: CGFloat, path: String, onScreen: [CalendarLayout.EventOccurrence]) {
            for occ in all {
                let hit = host.debugHitFrame(of: occ.id)
                XCTAssertEqual(hit?.minX ?? -1, leadingInset, accuracy: 0.01, "\(path): \(occ.event.title) starts past the legend")
                XCTAssertEqual(hit?.width ?? -1, areaWidth, accuracy: 0.01, "\(path): \(occ.event.title) spans the narrowed area")
                guard onScreen.contains(where: { $0.id == occ.id }) else { continue }
                let container = host.debugPieceContainers(of: occ.id)[occ.id]
                XCTAssertEqual(container?.frame.minX ?? -1, leadingInset, accuracy: 0.01, "\(path): \(occ.event.title) layer")
                XCTAssertEqual(container?.frame.width ?? -1, areaWidth, accuracy: 0.01, "\(path): \(occ.event.title) layer width")
            }
            let state = host.debugLegendState()
            XCTAssertEqual(state.rows.count, 26, "\(path): the legend has the 25h day's rows")
            XCTAssertEqual(state.opacity, 1, "\(path): the legend is shown")
            let slotHeight = hh * CGFloat(calendarLegendSlotMinutes(forHourHeight: hh)) / 60
            for row in state.rows {
                XCTAssertEqual(row.frame.minY, 16 + CGFloat(row.slotIndex) * slotHeight - 2, accuracy: 0.01,
                               "\(path): row \(row.text) sits on its hour line like an axis label")
                XCTAssertEqual(row.frame.maxX, leadingInset - CalendarColumnLegend.trailingPadding, accuracy: 0.01,
                               "\(path): row \(row.text) ends at the padding before the event area")
            }
            XCTAssertEqual(host.debugGridSpan()?.x ?? -1, leadingInset, accuracy: 0.01, "\(path): the grid starts past the legend")
            XCTAssertEqual(host.debugGridSpan()?.width ?? -1, areaWidth, accuracy: 0.01, "\(path): the grid spans the area")
        }

        host.apply(model(all, clock: fallBack, hourHeight: 56, legend: legend))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugPaintCounts.render, 1, "fixture: the full render drew it")
        XCTAssertFalse(host.debugLegendState().fading, "a column's first paint shows its legend at once")
        expectGeometry(hourHeight: 56, path: "render", onScreen: [b1, c1])

        host.apply(model(all, clock: fallBack, hourHeight: 80, legend: legend))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugPaintCounts.render, 1, "fixture: no full render")
        XCTAssertEqual(host.debugPaintCounts.repaintVertical, 1, "fixture: the cheap path drew it")
        expectGeometry(hourHeight: 80, path: "repaintVertical", onScreen: [b1, c1])

        scroll.contentOffset = CGPoint(x: 0, y: 16 + 9 * 80)
        let culls = host.debugPaintCounts.cull
        XCTAssertTrue(host.debugRunCullPass())
        XCTAssertEqual(host.debugPaintCounts.cull, culls + 1, "fixture: the cull ran")
        XCTAssertEqual(host.debugPaintCounts.render, 1, "fixture: no full render")
        expectGeometry(hourHeight: 80, path: "cullViewport", onScreen: [a9])
    }

    func testASplitFadesTheLegendInAndGlidesTheBlocksAndAMergeFadesItOut() throws {
        try XCTSkipIf(calendarReduceMotionEnabled, "the fades and glides are substituted under Reduce Motion")
        let a9 = occurrence("A9", epoch: 1_793_541_600, seconds: 3600)
        let legend = CalendarColumnLegend.standard(zoneClock: zone(newYork))
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))

        host.apply(model([a9], clock: fallBack, hourHeight: 56, legend: nil))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugHitFrame(of: a9.id)?.minX, 8)
        XCTAssertEqual(host.debugLegendState().opacity, 0)

        // Split: the settle gave this column a legend.
        host.apply(model([a9], clock: fallBack, hourHeight: 56, legend: legend))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugPaintCounts.render, 2, "a legend change is a full render, not the cheap path")
        let split = host.debugLegendState()
        XCTAssertEqual(split.opacity, 1)
        XCTAssertTrue(split.fading, "the legend fades in")
        XCTAssertTrue(split.gridGliding, "the grid glides to its shorter span")
        XCTAssertEqual(host.debugHitFrame(of: a9.id)?.minX, 8 + 26)
        let container = try XCTUnwrap(host.debugPieceContainers(of: a9.id)[a9.id])
        XCTAssertNotNil(container.animation(forKey: "s5.reflow.position"), "the block glides over by the reflow spring")

        // Merge: the settle took the legend away.
        host.apply(model([a9], clock: fallBack, hourHeight: 56, legend: nil))
        host.layoutIfNeeded()
        let merge = host.debugLegendState()
        XCTAssertEqual(merge.opacity, 0)
        XCTAssertTrue(merge.fading, "the legend fades out")
        XCTAssertEqual(merge.rows.count, 26, "over the rows it last drew")
        XCTAssertEqual(host.debugHitFrame(of: a9.id)?.minX, 8)
        XCTAssertEqual(host.debugGridSpan()?.x, 8)
    }

    // MARK: The fixed axis crossfades only when its clock changes the rows

    private func applyAxis(
        _ axis: TimeAxisLayerView, clock: DayClock, hourHeight: CGFloat = 56, leading: Int = 0,
        nowLegendWindow: CalendarNowLegendWindow? = nil
    ) {
        axis.apply(
            clock: clock,
            zoneClock: zone(newYork),
            headerHeight: 16,
            hourHeight: hourHeight,
            slotMinutes: calendarLegendSlotMinutes(forHourHeight: hourHeight),
            leadingExtendedHours: leading,
            trailingExtendedHours: 0,
            drawableLeadingHours: leading,
            drawableTrailingHours: 0,
            editMappingPresentation: nil,
            leadingFadeProgress: 0,
            trailingFadeProgress: 0,
            nowLegendWindow: nowLegendWindow ?? CalendarNowLegendWindow(day: clock, hourHeight: hourHeight)
        )
    }

    func testTheAxisCrossfadesWhenASettledClockChangesItsRowsAndNotForAPinchOrABand() {
        let axis = TimeAxisLayerView(frame: CGRect(x: 0, y: 0, width: 26, height: 3000))
        applyAxis(axis, clock: day(newYork, 2026, 10, 30))
        XCTAssertEqual(axis.debugAxisCrossfadeCount, 0, "the first clock has nothing to crossfade from")
        applyAxis(axis, clock: day(newYork, 2026, 10, 31))
        XCTAssertEqual(axis.debugAxisCrossfadeCount, 0, "a plain day after a plain day keeps every row")
        applyAxis(axis, clock: day(newYork, 2026, 11, 1))
        XCTAssertEqual(axis.debugAxisCrossfadeCount, 1, "the 25h day brings a row and the zones")
        applyAxis(axis, clock: day(newYork, 2026, 11, 1), hourHeight: 80)
        XCTAssertEqual(axis.debugAxisCrossfadeCount, 1, "a pinch is not a crossfade")
        applyAxis(axis, clock: day(newYork, 2026, 11, 1), hourHeight: 80, leading: 12)
        XCTAssertEqual(axis.debugAxisCrossfadeCount, 1, "a band opening is not a crossfade")
        applyAxis(axis, clock: day(newYork, 2026, 11, 2), hourHeight: 80, leading: 12)
        XCTAssertEqual(axis.debugAxisCrossfadeCount, 2, "back to a plain day's rows")
    }

    // MARK: The zone sublabel at the smallest zoom (QA F4, mutation h)

    /// The day view's pinch floor for a canvas of `dayHours`, the way the
    /// page computes it in `applyDynamicPinchMinIfNeeded`: its top overlay
    /// inset for the day view, and the tab bar and a margin below the safe
    /// area.
    private func dayViewPinchFloor(
        viewportHeight: CGFloat, safeAreaTop: CGFloat, safeAreaBottom: CGFloat, dayHours: CGFloat
    ) -> CGFloat {
        let topOverlayInset = calendarTopOverlayInset(
            safeAreaTop: safeAreaTop,
            isCapsuleVisible: calendarTopOverlayCapsulesVisible(rangeMode: .day, storedVisibility: true),
            legendBandHeight: calendarTopOverlayLegendBandHeight(for: .day)
        )
        return calendarPinchEffectiveMinHourHeight(
            viewportHeight: viewportHeight,
            contentTopInset: topOverlayInset,
            contentBottomInset: safeAreaBottom + 49 + 16,
            allDayHeight: 0,
            safetyFloor: calendarTimelineHourHeightMin,
            dayHours: dayHours
        )
    }

    /// The phones the app runs on, from the smallest screen to the tallest:
    /// the height the timeline's scroll view gets and the safe areas.
    private let phones: [(name: String, viewport: CGFloat, safeTop: CGFloat, safeBottom: CGFloat)] = [
        ("4.7-inch", 667, 20, 0),
        ("5.4-inch", 812, 50, 34),
        ("6.1-inch", 852, 59, 34),
        ("6.3-inch", 874, 62, 34),
        ("6.9-inch", 956, 62, 34),
    ]

    func testTheZoneSublabelShowsAtTheSmallestZoomOfATwentyFiveHourCanvas() {
        // Pinched all the way in on a 25h canvas, the two 1:00 rows are told
        // apart by the sublabel alone, so it has to show at the floor —
        // on the fixed axis and in an in-column legend — on every phone.
        let legend = CalendarColumnLegend.standard(zoneClock: zone(newYork))
        for phone in phones {
            let floor = dayViewPinchFloor(
                viewportHeight: phone.viewport, safeAreaTop: phone.safeTop, safeAreaBottom: phone.safeBottom, dayHours: 25
            )
            XCTAssertGreaterThan(floor, calendarTimelineHourHeightMin, "\(phone.name): fixture — the fit, not the safety floor")
            XCTAssertGreaterThanOrEqual(
                floor, TimeAxisLayerView.zoneSublabelMinimumHourHeight,
                "\(phone.name): the floor (\(floor)) is not below the sublabel's bound"
            )

            let axis = TimeAxisLayerView(frame: CGRect(x: 0, y: 0, width: 26, height: 3000))
            applyAxis(axis, clock: fallBack, hourHeight: floor)
            let zones = axis.debugZoneLabels()
            XCTAssertEqual(zones.map(\.text), ["EDT", "EST"], phone.name)
            XCTAssertTrue(zones.allSatisfy { !$0.isHidden }, "\(phone.name): the axis shows both zones at the floor")

            let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
            host.apply(model([], clock: fallBack, hourHeight: floor, legend: legend))
            host.layoutIfNeeded()
            let legendZones = host.debugLegendZoneLayers()
            XCTAssertEqual(legendZones.map(\.text), ["EDT", "EST"], phone.name)
            XCTAssertTrue(legendZones.allSatisfy { !$0.isHidden }, "\(phone.name): the legend shows both zones at the floor")

            // Normalized: the canvas is a standard day, so the floor is the
            // 24h fit, and the 25h column (here the axis of Nov 1–3) is
            // drawn at that floor scaled by 24/25 — which is the 25h fit
            // again, so the sublabel clears its bound by the same margin.
            let standardFloor = dayViewPinchFloor(
                viewportHeight: phone.viewport, safeAreaTop: phone.safeTop, safeAreaBottom: phone.safeBottom, dayHours: 24
            )
            let normalized = CalendarTimelineGeometry(
                window: newYorkWindow(2026, 11, 1, daysCount: 3), selectedDayClock: day(newYork, 2026, 11, 2),
                longestInReach: nil, hourHeight: standardFloor, mode: .normalized
            )
            let scaledFloor = normalized.axisHourHeight
            XCTAssertEqual(scaledFloor, floor, accuracy: 0.001, "\(phone.name): the scaled 24h floor is the 25h floor")
            XCTAssertGreaterThanOrEqual(
                scaledFloor, TimeAxisLayerView.zoneSublabelMinimumHourHeight,
                "\(phone.name): normalized at the smallest zoom (\(scaledFloor)) keeps the sublabel"
            )
            let normalizedAxis = TimeAxisLayerView(frame: CGRect(x: 0, y: 0, width: 26, height: 3000))
            applyAxis(normalizedAxis, clock: fallBack, hourHeight: scaledFloor)
            XCTAssertEqual(normalizedAxis.debugZoneLabels().map(\.text), ["EDT", "EST"], phone.name)
            XCTAssertTrue(normalizedAxis.debugZoneLabels().allSatisfy { !$0.isHidden }, "\(phone.name): normalized axis")
            host.apply(model([], clock: fallBack, hourHeight: normalized.columnHourHeight(for: fallBack), legend: legend))
            host.layoutIfNeeded()
            XCTAssertTrue(host.debugLegendZoneLayers().allSatisfy { !$0.isHidden }, "\(phone.name): normalized legend")
        }
    }

    func testTheZoneSublabelBoundIsHonouredAndKeepsClearOfTheNextRow() {
        let bound = TimeAxisLayerView.zoneSublabelMinimumHourHeight
        let axis = TimeAxisLayerView(frame: CGRect(x: 0, y: 0, width: 26, height: 3000))

        // At the bound: shown, under its own hour label and above the next.
        applyAxis(axis, clock: fallBack, hourHeight: bound)
        let hours = axis.debugHourLabels()
        let zones = axis.debugZoneLabels()
        XCTAssertEqual(zones.map(\.text), ["EDT", "EST"])
        for zone in zones {
            XCTAssertFalse(zone.isHidden, zone.text)
            let own = hours.first { $0.slotIndex == zone.slotIndex }
            let next = hours.first { $0.slotIndex == zone.slotIndex + 1 }
            XCTAssertNotNil(own, zone.text)
            XCTAssertNotNil(next, zone.text)
            XCTAssertGreaterThan(zone.frame.minY, own?.frame.minY ?? .infinity, "\(zone.text) sits under its hour")
            XCTAssertLessThanOrEqual(
                zone.frame.maxY, next?.frame.minY ?? -.infinity, "\(zone.text) stays clear of the next row's label"
            )
        }
        // Just below the bound: hidden — it is a bound, not always on.
        applyAxis(axis, clock: fallBack, hourHeight: bound - 0.5)
        let below = axis.debugZoneLabels()
        XCTAssertEqual(below.count, 2)
        XCTAssertTrue(below.allSatisfy(\.isHidden))
        // Well above: shown.
        applyAxis(axis, clock: fallBack, hourHeight: 96)
        XCTAssertTrue(axis.debugZoneLabels().allSatisfy { !$0.isHidden })

        // Both in-column legend forms honour the same bound, with the same
        // clearance.
        for legend in [CalendarColumnLegend.standard(zoneClock: zone(newYork)), CalendarColumnLegend.narrow(zoneClock: zone(newYork))] {
            let form = legend.isNarrow ? "narrow" : "standard"
            let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
            host.apply(model([], clock: fallBack, hourHeight: bound, legend: legend))
            host.layoutIfNeeded()
            let rows = host.debugLegendState().rows
            let legendZones = host.debugLegendZoneLayers()
            XCTAssertEqual(legendZones.map(\.text), ["EDT", "EST"], form)
            for zone in legendZones {
                XCTAssertFalse(zone.isHidden, "\(form) \(zone.text)")
                let own = rows.first { $0.slotIndex == zone.slotIndex }
                let next = rows.first { $0.slotIndex == zone.slotIndex + 1 }
                XCTAssertGreaterThan(zone.frame.minY, own?.frame.minY ?? .infinity, "\(form): \(zone.text) sits under its hour")
                XCTAssertLessThanOrEqual(
                    zone.frame.maxY, next?.frame.minY ?? -.infinity, "\(form): \(zone.text) stays clear of the next row"
                )
            }
            host.apply(model([], clock: fallBack, hourHeight: bound - 0.5, legend: legend))
            host.layoutIfNeeded()
            XCTAssertTrue(host.debugLegendZoneLayers().allSatisfy(\.isHidden), "\(form): hidden just below the bound")
        }
    }
}
