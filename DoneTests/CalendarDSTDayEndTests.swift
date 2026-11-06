//
//  CalendarDSTDayEndTests.swift
//  DoneTests
//
//  The end of a day whose clock is not 24h (gh#284 / #285): the readers of
//  the day's end — the visible window, the touch gate, the block clip and
//  the band split — all take it from the clock, not from the start plus a
//  standard day. Each test here fails when one of them is put back.
//

import XCTest
import UIKit
@testable import Done

final class CalendarDSTDayEndTests: XCTestCase {

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private var zone: CalendarZoneClock { CalendarZoneClock(calendar: newYork, usesActualDayLength: true) }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> DayClock {
        zone.day(containing: newYork.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!)
    }

    /// The 25h fall-back day, 2026-11-01.
    private var fallBack: DayClock { day(2026, 11, 1) }
    /// The 23h spring-forward day, 2026-03-08.
    private var springForward: DayClock { day(2026, 3, 8) }

    private let header: CGFloat = 16
    private let hourHeight: CGFloat = 56

    private func occurrence(
        _ title: String, elapsedHours: Double, of clock: DayClock, hours: Double
    ) -> CalendarLayout.EventOccurrence {
        let range = Event.TimeRange(
            start: clock.start.addingTimeInterval(elapsedHours * 3600),
            end: clock.start.addingTimeInterval((elapsedHours + hours) * 3600)
        )
        let id = UUID()
        return CalendarLayout.EventOccurrence(
            id: "\(title)-\(id.uuidString)",
            event: Event(id: id, title: title, timeRanges: [range], type: "Work"),
            range: range
        )
    }

    private func model(
        _ occurrences: [CalendarLayout.EventOccurrence], clock: DayClock, trailing: Int = 0
    ) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: clock.start,
            dayClock: clock,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: header,
            hourHeight: hourHeight,
            eventHorizontalInset: 8,
            leadingExtendedHours: 0,
            trailingExtendedHours: trailing,
            drawableLeadingHours: 0,
            drawableTrailingHours: trailing,
            useImperativeDayLayerModel: false,
            showEventText: true,
            isWeekMode: false,
            isThreeDayMode: false,
            titleFontSizeSetting: 13,
            showTimeBelowTitle: true,
            multiTypeEnabled: false,
            nearFutureHorizonDays: 7,
            isPinchActive: false,
            frozenSlotMinutes: nil
        )
    }

    private func y(elapsedHours: Double) -> CGFloat {
        header + CGFloat(elapsedHours) * hourHeight
    }

    // MARK: The visible end and the touch gate (QA mutation c2)

    func testTheVisibleEndOfADayIsItsRealEndNotAStandardDayOn() {
        // 25h: the window ends 25h after the start; a band below adds to that.
        XCTAssertEqual(calendarTimelineVisibleEnd(clock: fallBack), fallBack.start.addingTimeInterval(25 * 3600))
        XCTAssertEqual(calendarTimelineVisibleEnd(clock: fallBack), fallBack.end)
        XCTAssertEqual(
            calendarTimelineVisibleEnd(clock: fallBack, trailingExtendedHours: 12),
            fallBack.start.addingTimeInterval(37 * 3600)
        )
        // 23h, and for symmetry a plain day.
        XCTAssertEqual(calendarTimelineVisibleEnd(clock: springForward), springForward.start.addingTimeInterval(23 * 3600))
        XCTAssertEqual(
            calendarTimelineVisibleEnd(clock: springForward, trailingExtendedHours: 12),
            springForward.start.addingTimeInterval(35 * 3600)
        )
        let plain = day(2026, 11, 2)
        XCTAssertEqual(calendarTimelineVisibleEnd(clock: plain), plain.start.addingTimeInterval(24 * 3600))
    }

    func testTheLastHourOfTheFallBackDayTakesATouchAndTheHourAfterTheSpringDayDoesNot() {
        // 24h30m into the 25h day is 23:30 EST, the day's own: accepted.
        // 25h in is the next day's first instant: not this day, unless the
        // band below is open.
        let lastHalfHour = fallBack.start.addingTimeInterval(24.5 * 3600)
        XCTAssertEqual(newYork.component(.hour, from: lastHalfHour), 23, "fixture: 23:30 on the wall")
        XCTAssertTrue(calendarTimelineColumnAccepts(instant: lastHalfHour, clock: fallBack))
        XCTAssertFalse(calendarTimelineColumnAccepts(instant: fallBack.end, clock: fallBack))
        XCTAssertTrue(calendarTimelineColumnAccepts(instant: fallBack.end, clock: fallBack, trailingExtendedHours: 1))
        // The same through the Y mapping a touch goes through, unclamped as
        // the host maps it.
        let touched = calendarTimelineDateFromYPosition(
            y(elapsedHours: 24.5), clock: fallBack, headerHeight: header, hourHeight: hourHeight,
            snapMinutes: 1, clampToExtension: false
        )
        XCTAssertEqual(touched, lastHalfHour)
        XCTAssertTrue(calendarTimelineColumnAccepts(instant: touched, clock: fallBack))

        // 23h: 22h30m in is the day's last half hour; 23h in is the next day.
        let springLast = springForward.start.addingTimeInterval(22.5 * 3600)
        XCTAssertEqual(newYork.component(.hour, from: springLast), 23, "fixture: 23:30 on the wall")
        XCTAssertTrue(calendarTimelineColumnAccepts(instant: springLast, clock: springForward))
        XCTAssertFalse(calendarTimelineColumnAccepts(instant: springForward.end, clock: springForward))
        XCTAssertFalse(
            calendarTimelineColumnAccepts(instant: springForward.start.addingTimeInterval(23.5 * 3600), clock: springForward),
            "the hour a standard day would still have is the next day's"
        )
    }

    func testTheLastHourOfTheFallBackDayIsDrawnWhole() {
        // 23:00–00:00 EST on Nov 1, elapsed 24h–25h: a full hour's block,
        // clipped by the day's real end and so not clipped at all.
        let last = occurrence("Last", elapsedHours: 24, of: fallBack, hours: 1)
        XCTAssertEqual(newYork.component(.hour, from: last.range.start), 23, "fixture: 23:00 on the wall")
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
        host.apply(model([last], clock: fallBack))
        host.layoutIfNeeded()
        let hit = host.debugHitFrame(of: last.id)
        XCTAssertEqual(hit?.minY ?? -1, y(elapsedHours: 24) + 1.5, accuracy: 0.01)
        XCTAssertEqual(hit?.height ?? -1, hourHeight - 3, accuracy: 0.01, "the whole hour, not clipped at a standard day's end")
        let container = host.debugPieceContainers(of: last.id)[last.id]
        XCTAssertNotNil(container, "the block is drawn")
        XCTAssertEqual(container?.frame.minY ?? -1, y(elapsedHours: 24) + 1.5, accuracy: 0.01)
        XCTAssertEqual(container?.frame.height ?? -1, hourHeight - 3, accuracy: 0.01)
    }

    // MARK: A model built without a page (review round 3, F7)

    func testAModelBuiltWithoutAPageIsItsOwnLengthAndHasNoTail() {
        // The coordinator builds its model without a page's canvas. A 23h
        // day built that way is sized to itself: the stretch a standard
        // day would still have below its end is the bottom inset, which a
        // column sized to itself always took a touch in, and no tail is
        // drawn there. With a page's standard-day canvas that stretch is
        // the tail: drawn, and refusing the touch.
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
        var model = self.model([], clock: springForward)
        host.apply(model)
        host.layoutIfNeeded()
        XCTAssertTrue(host.acceptsTouch(atY: y(elapsedHours: 22.5)), "the day's own last half hour")
        XCTAssertTrue(host.acceptsTouch(atY: y(elapsedHours: 23.5)), "below its end, a column sized to itself takes the touch as it always did")
        XCTAssertNil(host.debugNotThisDayTail(), "no tail without a page")
        XCTAssertEqual(model.drawnCanvasLength, springForward.length)

        model.canvasLength = 24 * 3600
        host.apply(model)
        host.layoutIfNeeded()
        XCTAssertTrue(host.acceptsTouch(atY: y(elapsedHours: 22.5)))
        XCTAssertFalse(host.acceptsTouch(atY: y(elapsedHours: 23.5)), "with a page's standard-day canvas the hour below the end is the tail")
        let tail = host.debugNotThisDayTail()
        XCTAssertEqual(tail?.minY ?? -1, y(elapsedHours: 23), accuracy: 0.01, "the tail starts at the day's end")
        XCTAssertEqual(tail?.height ?? -1, hourHeight, accuracy: 0.01, "and is the hour the canvas has past it")

        // The 25h day is never shorter than a standard-day canvas: no tail
        // either way, and its last hour is touched.
        var long = self.model([], clock: fallBack)
        host.apply(long)
        host.layoutIfNeeded()
        XCTAssertNil(host.debugNotThisDayTail())
        XCTAssertTrue(host.acceptsTouch(atY: y(elapsedHours: 24.5)))
        long.canvasLength = 24 * 3600
        host.apply(long)
        host.layoutIfNeeded()
        XCTAssertNil(host.debugNotThisDayTail())
        XCTAssertTrue(host.acceptsTouch(atY: y(elapsedHours: 24.5)))
    }

    // MARK: The band split at the day's end (QA mutation c1)

    func testBlocksSplitAtTheTwentyFiveHourDaysEndWhenTheBandBelowIsOpen() {
        // With the band below Nov 1 open: a block over the day's end (23:30
        // EST to 00:30 EST on Nov 2, elapsed 24h30m–25h30m) splits at 25h,
        // and a block in the day's last hours (22:30–23:30 EST, elapsed
        // 23h30m–24h30m) stays whole, as it crosses nothing.
        let crossing = occurrence("Crossing", elapsedHours: 24.5, of: fallBack, hours: 1)
        let inside = occurrence("Inside", elapsedHours: 23.5, of: fallBack, hours: 1)
        XCTAssertTrue(fallBack.contains(crossing.range.start), "fixture")
        XCTAssertFalse(fallBack.contains(crossing.range.end.addingTimeInterval(-1)), "fixture: it ends in the band")
        XCTAssertTrue(fallBack.contains(inside.range.end.addingTimeInterval(-1)), "fixture: it ends inside the day")

        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
        host.apply(model([crossing, inside], clock: fallBack, trailing: 12))
        host.layoutIfNeeded()

        let pieces = host.debugPieceContainers(of: crossing.id)
        XCTAssertEqual(pieces.count, 2, "today's piece and the band's")
        let today = pieces[crossing.id]
        let after = pieces[crossing.id + "\u{1F}after"]
        XCTAssertNotNil(today)
        XCTAssertNotNil(after)
        XCTAssertEqual(today?.frame.minY ?? -1, y(elapsedHours: 24.5) + 1.5, accuracy: 0.01)
        XCTAssertEqual(today?.frame.height ?? -1, hourHeight / 2 - 3, accuracy: 0.01, "today's piece ends on the day's end")
        XCTAssertEqual(after?.frame.minY ?? -1, y(elapsedHours: 25) + 1.5, accuracy: 0.01, "the band's piece starts on the day's end")
        XCTAssertEqual(after?.frame.height ?? -1, hourHeight / 2 - 3, accuracy: 0.01)

        let whole = host.debugPieceContainers(of: inside.id)
        XCTAssertEqual(whole.count, 1, "a block inside the day is not split")
        XCTAssertEqual(whole[inside.id]?.frame.minY ?? -1, y(elapsedHours: 23.5) + 1.5, accuracy: 0.01)
        XCTAssertEqual(whole[inside.id]?.frame.height ?? -1, hourHeight - 3, accuracy: 0.01)
    }
}
