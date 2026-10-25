//
//  MacBlockStyleTests.swift
//  DoneMacTests
//
//  The shared block metrics both renderers read, and the Mac's port of the
//  phone's text gate. Expected values are hand-computed literals.
//

import XCTest
@testable import Done

final class MacBlockStyleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_773_100_800)

    func testTodoUrgencyBoundaries() {
        typealias U = CalendarTodoBorderUrgency
        XCTAssertEqual(U(deadline: nil, isDone: false, now: now), .normal)
        XCTAssertEqual(U(deadline: now.addingTimeInterval(-60), isDone: true, now: now), .normal)
        XCTAssertEqual(U(deadline: now.addingTimeInterval(-1), isDone: false, now: now), .overdue)
        XCTAssertEqual(U(deadline: now, isDone: false, now: now), .dueSoon)
        XCTAssertEqual(U(deadline: now.addingTimeInterval(86_399), isDone: false, now: now), .dueSoon)
        XCTAssertEqual(U(deadline: now.addingTimeInterval(86_400), isDone: false, now: now), .normal)
    }

    func testStrokeCornerAndEffortBar() {
        XCTAssertEqual(calendarEventBlockCornerRadius(isInterrupt: false), 4)
        XCTAssertEqual(calendarEventBlockCornerRadius(isInterrupt: true), 3)
        XCTAssertEqual(calendarEventBlockStrokeWidth(isInterrupt: false), 1.2, accuracy: 0.0001)
        XCTAssertEqual(calendarEventBlockStrokeWidth(isInterrupt: true), 1.4, accuracy: 0.0001)
        XCTAssertEqual(calendarEventEffortBarWidth(colorDepth: 0.4, isWeekMode: false), 2.5, accuracy: 0.0001)
        XCTAssertEqual(calendarEventEffortBarWidth(colorDepth: 0.4, isWeekMode: true), 1.6, accuracy: 0.0001)
    }

    // Day-view insets (12/8/8), spacing 2, title line 14, time line 12:
    // the time row needs 8+8 + 14 + 2 + 12 = 44pt and 48pt of width.
    private func layout(_ w: CGFloat, _ h: CGFloat, setting: Bool = true,
                        selected: Bool = false) -> MacBlockTextLayout {
        MacBlockTextLayout(size: CGSize(width: w, height: h),
                           insets: calendarEventBlockInsets(isWeekMode: false, isThreeDayMode: false),
                           spacing: 2, titleLineHeight: 14, timeLineHeight: 12,
                           showTimeBelowTitle: setting, isSelected: selected)
    }

    func testTimeRowNeedsItsGeometry() {
        XCTAssertTrue(layout(100, 44).showsTime)
        XCTAssertFalse(layout(100, 43.9).showsTime)
        XCTAssertFalse(layout(47.9, 80).showsTime)
        // 41 min at 28pt/hour ≈ 19pt: title only, centred (19 < 8+8+14 = 30).
        let short = layout(100, 19)
        XCTAssertTrue(short.showsText)
        XCTAssertFalse(short.showsTime)
        XCTAssertTrue(short.centersVertically)
        XCTAssertFalse(layout(100, 30).centersVertically)
    }

    func testNoTextBelowFloor() {
        XCTAssertFalse(layout(27.9, 40).showsText)
        XCTAssertFalse(layout(100, 15.9).showsText)
        XCTAssertFalse(layout(100, 15.9).showsTime)
    }

    func testSettingOffShowsTimeOnlyOnSelectedLargeBlock() {
        XCTAssertFalse(layout(200, 100, setting: false).showsTime)
        XCTAssertTrue(layout(88, 42, setting: false, selected: true).showsTime)
        XCTAssertFalse(layout(87.9, 42, setting: false, selected: true).showsTime)
    }

    func testNarrowTitleLineLimits() {
        XCTAssertEqual(layout(40, 40).titleLineLimit, 3)
        XCTAssertEqual(layout(40, 28).titleLineLimit, 2)
        XCTAssertEqual(layout(40, 27).titleLineLimit, 1)
        XCTAssertEqual(layout(48, 100).titleLineLimit, 2)
    }
}
