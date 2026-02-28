import XCTest
@testable import Done

final class OverlapLayoutTests: XCTestCase {

    private let calendar = Calendar.current
    private lazy var today: Date = calendar.startOfDay(for: Date())

    private func makeOccurrence(
        id: String,
        startHour: Int, startMin: Int = 0,
        endHour: Int, endMin: Int = 0
    ) -> CalendarLayout.EventOccurrence {
        let start = calendar.date(bySettingHour: startHour, minute: startMin, second: 0, of: today)!
        let end = calendar.date(bySettingHour: endHour, minute: endMin, second: 0, of: today)!
        let event = Event(title: id, timeRanges: [Event.TimeRange(start: start, end: end)])
        return CalendarLayout.EventOccurrence(id: id, event: event, range: Event.TimeRange(start: start, end: end))
    }

    // MARK: - Empty / Single

    func testEmptyOccurrences() {
        let result = CalendarLayout.overlapLayout(for: [], on: today)
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleEvent() {
        let occ = makeOccurrence(id: "A", startHour: 9, endHour: 10)
        let result = CalendarLayout.overlapLayout(for: [occ], on: today)
        let slot = result["A"]!
        XCTAssertEqual(slot.xOffsetFraction, 0)
        XCTAssertEqual(slot.widthFraction, 1)
    }

    // MARK: - Two Events

    func testTwoEqualDurationSideBySide() {
        // Both 1h → ratio = 1.0 ≥ 0.5 → side by side
        let a = makeOccurrence(id: "A", startHour: 9, endHour: 10)
        let b = makeOccurrence(id: "B", startHour: 9, startMin: 30, endHour: 10, endMin: 30)
        let result = CalendarLayout.overlapLayout(for: [a, b], on: today)

        let slotA = result["A"]!
        let slotB = result["B"]!

        // They should share the width equally
        XCTAssertEqual(slotA.widthFraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(slotB.widthFraction, 0.5, accuracy: 0.01)
        // One starts at 0, other at 0.5
        XCTAssertEqual(slotA.xOffsetFraction + slotB.xOffsetFraction, 0.5, accuracy: 0.01)
        // Same z-index
        XCTAssertEqual(slotA.zIndex, slotB.zIndex)
    }

    func testTwoEventsLargeDurationDifference() {
        // A: 3h, B: 1h → ratio = 1/3 < 0.5 → B is floater
        let a = makeOccurrence(id: "A", startHour: 9, endHour: 12)
        let b = makeOccurrence(id: "B", startHour: 10, endHour: 11)
        let result = CalendarLayout.overlapLayout(for: [a, b], on: today)

        let slotA = result["A"]!
        let slotB = result["B"]!

        // A is full width anchor
        XCTAssertEqual(slotA.xOffsetFraction, 0, accuracy: 0.01)
        XCTAssertEqual(slotA.widthFraction, 1, accuracy: 0.01)

        // B is floater in right 3/4
        XCTAssertEqual(slotB.xOffsetFraction, 1.0 / 4.0, accuracy: 0.01)
        XCTAssertEqual(slotB.widthFraction, 3.0 / 4.0, accuracy: 0.01)

        // B has higher z-index
        XCTAssertGreaterThan(slotB.zIndex, slotA.zIndex)
    }

    // MARK: - Three Events

    func testThreeEventsMixedDurations() {
        // A: 9-12 (3h), B: 10-11 (1h), C: 10:30-11:30 (1h)
        // A is anchor; B,C ratio = 1/3 → floaters
        // B,C equal duration → side by side in right 2/3
        let a = makeOccurrence(id: "A", startHour: 9, endHour: 12)
        let b = makeOccurrence(id: "B", startHour: 10, endHour: 11)
        let c = makeOccurrence(id: "C", startHour: 10, startMin: 30, endHour: 11, endMin: 30)
        let result = CalendarLayout.overlapLayout(for: [a, b, c], on: today)

        let slotA = result["A"]!
        let slotB = result["B"]!
        let slotC = result["C"]!

        // A: full width
        XCTAssertEqual(slotA.widthFraction, 1, accuracy: 0.01)
        XCTAssertEqual(slotA.xOffsetFraction, 0, accuracy: 0.01)

        // B and C: each gets half of the right 3/4
        XCTAssertEqual(slotB.widthFraction, 3.0 / 8.0, accuracy: 0.01)
        XCTAssertEqual(slotC.widthFraction, 3.0 / 8.0, accuracy: 0.01)

        // B and C are at higher z-index than A
        XCTAssertGreaterThan(slotB.zIndex, slotA.zIndex)
        XCTAssertGreaterThan(slotC.zIndex, slotA.zIndex)
    }

    func testThreeEqualDurationEvents() {
        // All 1h, overlapping → 3 equal columns
        let a = makeOccurrence(id: "A", startHour: 9, endHour: 10)
        let b = makeOccurrence(id: "B", startHour: 9, startMin: 15, endHour: 10, endMin: 15)
        let c = makeOccurrence(id: "C", startHour: 9, startMin: 30, endHour: 10, endMin: 30)
        let result = CalendarLayout.overlapLayout(for: [a, b, c], on: today)

        let slots = [result["A"]!, result["B"]!, result["C"]!]
        for slot in slots {
            XCTAssertEqual(slot.widthFraction, 1.0 / 3.0, accuracy: 0.01)
        }
    }

    // MARK: - Non-Overlapping Events

    func testNonOverlappingEventsGetFullWidth() {
        let a = makeOccurrence(id: "A", startHour: 9, endHour: 10)
        let b = makeOccurrence(id: "B", startHour: 11, endHour: 12)
        let result = CalendarLayout.overlapLayout(for: [a, b], on: today)

        XCTAssertEqual(result["A"]!.widthFraction, 1, accuracy: 0.01)
        XCTAssertEqual(result["B"]!.widthFraction, 1, accuracy: 0.01)
    }

    // MARK: - Bridge Case (ratio exactly 0.5)

    func testBridgeCaseRatioExactlyHalf() {
        // A: 2h, B: 1h → ratio = 0.5 → similar (side by side)
        let a = makeOccurrence(id: "A", startHour: 9, endHour: 11)
        let b = makeOccurrence(id: "B", startHour: 10, endHour: 11)
        let result = CalendarLayout.overlapLayout(for: [a, b], on: today)

        let slotA = result["A"]!
        let slotB = result["B"]!

        // Both should be side by side (equal width)
        XCTAssertEqual(slotA.widthFraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(slotB.widthFraction, 0.5, accuracy: 0.01)
    }

    // MARK: - Clipped Duration

    func testClippedDuration() {
        // Event spans midnight: yesterday 22:00 to today 02:00 → clipped to 2h on today
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let start = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: yesterday)!
        let end = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: today)!
        let event = Event(title: "overnight", timeRanges: [Event.TimeRange(start: start, end: end)])
        let occ = CalendarLayout.EventOccurrence(id: "overnight", event: event, range: Event.TimeRange(start: start, end: end))

        let duration = CalendarLayout.clippedDuration(for: occ, on: today)
        XCTAssertEqual(duration, 2 * 3600, accuracy: 1) // 2 hours
    }
}
