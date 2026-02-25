import XCTest
@testable import Done

final class AgenticCalendarAutofillNormalizerTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    func testDragCreateLocksTimeRange() {
        let dragRange = Event.TimeRange(
            start: date(2026, 2, 24, 9, 0),
            end: date(2026, 2, 24, 10, 0)
        )
        let pending = PendingEventCreation(
            date: dragRange.start,
            timeRange: dragRange,
            source: .dragCreate,
            anchorVisibleDate: dragRange.start
        )
        let context = AgenticCalendarContext(visibleDate: dragRange.start, nearbyEventsSummary: "")
        let input = sampleResult(start: date(2026, 2, 25, 13, 7), end: date(2026, 2, 25, 15, 7))

        let output = AgenticCalendarAutofillNormalizer.normalize(input, pendingCreate: pending, context: context, calendar: calendar)

        XCTAssertEqual(output.startTime, dragRange.start)
        XCTAssertEqual(output.endTime, dragRange.end)
        XCTAssertFalse(output.isAllDay)
    }

    func testQuickAddOutOfRangeDateFallsBackToPendingRange() {
        let pendingRange = Event.TimeRange(
            start: date(2026, 2, 24, 14, 0),
            end: date(2026, 2, 24, 15, 0)
        )
        let pending = PendingEventCreation(
            date: pendingRange.start,
            timeRange: pendingRange,
            source: .quickAdd,
            anchorVisibleDate: date(2026, 2, 24, 0, 0)
        )
        let context = AgenticCalendarContext(visibleDate: date(2026, 2, 24, 0, 0), nearbyEventsSummary: "", now: date(2026, 2, 24, 12, 0), timeZoneIdentifier: "UTC")
        let input = sampleResult(start: date(2026, 3, 20, 9, 0), end: date(2026, 3, 20, 10, 0))

        let output = AgenticCalendarAutofillNormalizer.normalize(input, pendingCreate: pending, context: context, calendar: calendar)

        XCTAssertEqual(output.startTime, pendingRange.start)
        XCTAssertEqual(output.endTime, pendingRange.end)
        XCTAssertTrue(output.warnings.contains { $0.contains("too far") })
    }

    func testInvalidDurationIsRepairedAndRoundedToQuarterHour() {
        let pendingRange = Event.TimeRange(start: date(2026, 2, 24, 8, 0), end: date(2026, 2, 24, 9, 0))
        let pending = PendingEventCreation(
            date: pendingRange.start,
            timeRange: pendingRange,
            source: .quickAdd,
            anchorVisibleDate: pendingRange.start
        )
        let context = AgenticCalendarContext(visibleDate: pendingRange.start, nearbyEventsSummary: "")
        let input = sampleResult(start: date(2026, 2, 24, 10, 7), end: date(2026, 2, 24, 10, 3))

        let output = AgenticCalendarAutofillNormalizer.normalize(input, pendingCreate: pending, context: context, calendar: calendar)

        XCTAssertEqual(calendar.component(.minute, from: output.startTime) % 15, 0)
        XCTAssertEqual(calendar.component(.minute, from: output.endTime) % 15, 0)
        XCTAssertGreaterThan(output.endTime, output.startTime)
    }

    private func sampleResult(start: Date, end: Date) -> AgenticCalendarAutofillResult {
        AgenticCalendarAutofillResult(
            title: "测试事件",
            typeTitle: "Study",
            note: "note",
            location: "",
            startTime: start,
            endTime: end,
            isAllDay: false,
            repeatUnit: .none,
            repeatInterval: 1,
            repeatEndType: .none,
            repeatEndDate: nil,
            repeatEndCount: nil,
            confidence: 0.7,
            warnings: [],
            usedVision: false,
            providerName: "openai",
            providerModel: "gpt-4o"
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
