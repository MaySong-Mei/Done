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
