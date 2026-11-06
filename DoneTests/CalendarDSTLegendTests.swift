//
//  CalendarDSTLegendTests.swift
//  DoneTests
//
//  The multi-day legends (gh#284 / #285 S2): which columns of a window
//  start a legend group, what the fixed axis and an in-column legend draw,
//  when the window settles, how the now-legend is gated, and the three
//  render paths' agreement on the legend inset.
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

    func testTheNowLegendShowsOnlyWhileNowIsInsideTheWindow() {
        let window = newYorkWindow(2026, 10, 30, daysCount: 3).interval
        let lastEveningOfTheWindow = Date(timeIntervalSince1970: 1_793_593_800)   // Nov 1 23:30 EST
        let firstInstantAfter = Date(timeIntervalSince1970: 1_793_595_600)        // Nov 2 00:00 EST
        let theDayBefore = Date(timeIntervalSince1970: 1_793_332_800 - 60)        // Oct 29 23:59 EDT
        XCTAssertTrue(calendarNowLegendIsShown(now: window.start, window: window))
        XCTAssertTrue(calendarNowLegendIsShown(now: lastEveningOfTheWindow, window: window))
        XCTAssertFalse(calendarNowLegendIsShown(now: firstInstantAfter, window: window), "half-open at the end")
        XCTAssertFalse(calendarNowLegendIsShown(now: theDayBefore, window: window))

        let single = newYorkWindow(2026, 11, 1, daysCount: 1).interval
        XCTAssertTrue(calendarNowLegendIsShown(now: lastEveningOfTheWindow, window: single))
        XCTAssertFalse(calendarNowLegendIsShown(now: firstInstantAfter, window: single))
    }

    // MARK: Settle gating (A5)

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
        for zone in ["EDT", "EST", "CEST", "EEST", "AEDT", "BST"] {
            XCTAssertLessThanOrEqual(width(zone, size: standard.zoneFontSize), standardRoom, zone)
            XCTAssertLessThanOrEqual(width(zone, size: narrow.zoneFontSize), narrowRoom, zone)
        }
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

    private func applyAxis(_ axis: TimeAxisLayerView, clock: DayClock, hourHeight: CGFloat = 56, leading: Int = 0) {
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
            nowLegendWindow: DateInterval(start: clock.start, end: clock.end)
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
}
