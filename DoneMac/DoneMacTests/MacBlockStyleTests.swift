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

    func testHourAxisLabels() {
        XCTAssertEqual(calendarHourAxisLabel(hour24: 0, is24: true), "0:00")
        XCTAssertEqual(calendarHourAxisLabel(hour24: 9, is24: true), "9:00")
        XCTAssertEqual(calendarHourAxisLabel(hour24: 0, is24: false), "12 am")
        XCTAssertEqual(calendarHourAxisLabel(hour24: 12, is24: false), "12 pm")
        XCTAssertEqual(calendarHourAxisLabel(hour24: 18, is24: false), "6 pm")
    }

    /// The todo border redraws at the two instants its urgency changes; the
    /// urgency a second after each differs from a second before.
    func testUrgencyTransitionsLandOnTheBoundaries() {
        let deadline = now.addingTimeInterval(30 * 3600)
        let marks = DayColumnView.urgencyTransitions(deadline: deadline, now: now)
        XCTAssertEqual(marks, [now.addingTimeInterval(6 * 3600 + 1), now.addingTimeInterval(30 * 3600 + 1)])
        typealias U = CalendarTodoBorderUrgency
        XCTAssertEqual(U(deadline: deadline, isDone: false, now: marks[0].addingTimeInterval(-2)), .normal)
        XCTAssertEqual(U(deadline: deadline, isDone: false, now: marks[0]), .dueSoon)
        XCTAssertEqual(U(deadline: deadline, isDone: false, now: marks[1].addingTimeInterval(-2)), .dueSoon)
        XCTAssertEqual(U(deadline: deadline, isDone: false, now: marks[1]), .overdue)
        // Past boundaries drop out; no deadline, no redraws.
        XCTAssertEqual(DayColumnView.urgencyTransitions(deadline: now.addingTimeInterval(3600), now: now),
                       [now.addingTimeInterval(3601)])
        XCTAssertEqual(DayColumnView.urgencyTransitions(deadline: nil, now: now), [])
    }

    func testTypeSubtitleNeedsTwoTypes() {
        var e = Event(id: UUID(), title: "E", timeRanges: [], kind: .event)
        e.type = "Work"
        XCTAssertEqual(CalendarProjection.typeSubtitle(for: e), "")
        e.additionalTypes = ["Study"]
        XCTAssertEqual(CalendarProjection.typeSubtitle(for: e), "Work · Study")
    }

    /// A 1h child inside a 3h parent, 120x180pt: the moat cut runs from
    /// 60-2 to 120+2pt, leaving a 5pt spine (8pt child inset less the 3pt
    /// moat); the parent's text takes the top region.
    func testCompoundParentGeometryAndTextRect() {
        let start = now
        let parent = Event.TimeRange(start: start, end: start.addingTimeInterval(3 * 3600))
        let child = Event.TimeRange(start: start.addingTimeInterval(3600), end: start.addingTimeInterval(7200))
        let geo = calendarInterruptParentCompoundGeometry(parentRange: parent, childRanges: [child],
                                                          parentWidth: 120, parentHeight: 180,
                                                          horizontalGap: 3, verticalGap: 2)
        XCTAssertEqual(geo.cutouts.map(\.rect), [CGRect(x: 5, y: 58, width: 115, height: 64)])
        XCTAssertEqual(geo.contentRects, [CGRect(x: 0, y: 0, width: 120, height: 58),
                                          CGRect(x: 0, y: 58, width: 5, height: 64),
                                          CGRect(x: 0, y: 122, width: 120, height: 58)])
        let insets = calendarEventBlockInsets(isWeekMode: false, isThreeDayMode: false)
        XCTAssertEqual(MacBlockTextLayout.compoundTextRect(geo.contentRects, insets: insets, titleLineHeight: 14),
                       CGRect(x: 0, y: 0, width: 120, height: 58))
        // Child starting at the parent's top: the cut runs 0...124 (no top
        // lobe), only the 5pt spine is left beside it, and the text drops to
        // the region below.
        let early = calendarInterruptParentCompoundGeometry(
            parentRange: parent, childRanges: [Event.TimeRange(start: start, end: child.end)],
            parentWidth: 120, parentHeight: 180, horizontalGap: 3, verticalGap: 2)
        XCTAssertEqual(MacBlockTextLayout.compoundTextRect(early.contentRects, insets: insets, titleLineHeight: 14),
                       CGRect(x: 0, y: 124, width: 120, height: 56))
    }

    func testEmbeddedChildRectInsetsIntoParentColumn() {
        let size = CGSize(width: 200, height: 2400)
        func block(embedded: Bool) -> DayBlockModel {
            DayBlockModel(id: "x", eventID: UUID(), range: .init(start: now, end: now.addingTimeInterval(3600)),
                          title: "", timeText24: "", timeText12: "", yFraction: 0.5, heightFraction: 0.1,
                          xOffsetFraction: 0.5, widthFraction: 0.5, zIndex: 0, isTodo: false, isDone: false,
                          topIsRealStart: true, bottomIsRealEnd: true, color: .blue, colorDepth: 0,
                          deadline: nil, isInterrupt: embedded, isTimerActive: false, agenticPhase: nil,
                          hasAdditionalTypes: false, typeSubtitle: "", isEmbeddedInterruptChild: embedded,
                          interruptChildRanges: [], compoundParentRange: nil)
        }
        XCTAssertEqual(DayColumnView.blockRect(block(embedded: false), in: size),
                       CGRect(x: 101, y: 1200, width: 98, height: 239))
        XCTAssertEqual(DayColumnView.blockRect(block(embedded: true), in: size),
                       CGRect(x: 109, y: 1200, width: 90, height: 239))
    }
}
