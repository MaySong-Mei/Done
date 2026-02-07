import XCTest
@testable import Done

final class CalendarDragLogicTests: XCTestCase {
    func testDayOffsetSingleDayDeadZoneAndMultiPage() {
        let contentWidth: CGFloat = 300
        let dayWidth: CGFloat = 300
        let daySpacing: CGFloat = 12

        XCTAssertEqual(
            calendarDayOffsetFromDragX(
                offsetX: 89,
                daysCount: 1,
                contentWidth: contentWidth,
                dayWidth: dayWidth,
                daySpacing: daySpacing
            ),
            0
        )

        XCTAssertEqual(
            calendarDayOffsetFromDragX(
                offsetX: 301,
                daysCount: 1,
                contentWidth: contentWidth,
                dayWidth: dayWidth,
                daySpacing: daySpacing
            ),
            1
        )

        XCTAssertEqual(
            calendarDayOffsetFromDragX(
                offsetX: 620,
                daysCount: 1,
                contentWidth: contentWidth,
                dayWidth: dayWidth,
                daySpacing: daySpacing
            ),
            2
        )

        XCTAssertEqual(
            calendarDayOffsetFromDragX(
                offsetX: -620,
                daysCount: 1,
                contentWidth: contentWidth,
                dayWidth: dayWidth,
                daySpacing: daySpacing
            ),
            -2
        )
    }

    func testDayOffsetMultiDayUsesColumnStep() {
        XCTAssertEqual(
            calendarDayOffsetFromDragX(
                offsetX: 225,
                daysCount: 3,
                contentWidth: 360,
                dayWidth: 100,
                daySpacing: 12
            ),
            2
        )

        XCTAssertEqual(
            calendarDayOffsetFromDragX(
                offsetX: -170,
                daysCount: 7,
                contentWidth: 360,
                dayWidth: 42,
                daySpacing: 12
            ),
            -3
        )
    }

    func testActiveDraggedOccurrenceMatching() {
        XCTAssertFalse(
            isActiveDraggedOccurrence(
                occurrenceID: nil,
                draggingOccurrenceID: "abc",
                dragMode: .move
            )
        )

        XCTAssertFalse(
            isActiveDraggedOccurrence(
                occurrenceID: "occ-1",
                draggingOccurrenceID: "occ-2",
                dragMode: .move
            )
        )

        XCTAssertFalse(
            isActiveDraggedOccurrence(
                occurrenceID: "occ-1",
                draggingOccurrenceID: "occ-1",
                dragMode: .resizeTop
            )
        )

        XCTAssertTrue(
            isActiveDraggedOccurrence(
                occurrenceID: "occ-1",
                draggingOccurrenceID: "occ-1",
                dragMode: .move
            )
        )
    }

    func testAutoScrollVelocityUsesEdgeZonesAndCapsSpeed() {
        let minOffset: CGFloat = 0
        let maxOffset: CGFloat = 2000
        let viewport: CGFloat = 300
        let edgeInset: CGFloat = 72
        let maxSpeed: CGFloat = 620

        XCTAssertEqual(
            calendarAutoScrollVelocity(
                locationInViewport: 150,
                viewportLength: viewport,
                currentOffset: 1000,
                minOffset: minOffset,
                maxOffset: maxOffset,
                edgeInset: edgeInset,
                maxSpeed: maxSpeed
            ),
            0
        )

        let nearLeft = calendarAutoScrollVelocity(
            locationInViewport: 10,
            viewportLength: viewport,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: edgeInset,
            maxSpeed: maxSpeed
        )
        XCTAssertLessThan(nearLeft, 0)
        XCTAssertGreaterThanOrEqual(nearLeft, -maxSpeed)

        let farOutsideLeft = calendarAutoScrollVelocity(
            locationInViewport: -2000,
            viewportLength: viewport,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: edgeInset,
            maxSpeed: maxSpeed
        )
        XCTAssertEqual(farOutsideLeft, -maxSpeed)

        let nearRight = calendarAutoScrollVelocity(
            locationInViewport: 295,
            viewportLength: viewport,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: edgeInset,
            maxSpeed: maxSpeed
        )
        XCTAssertGreaterThan(nearRight, 0)
        XCTAssertLessThanOrEqual(nearRight, maxSpeed)
    }

    func testAutoScrollVelocityStopsAtBounds() {
        let velocityAtMin = calendarAutoScrollVelocity(
            locationInViewport: 0,
            viewportLength: 300,
            currentOffset: 0,
            minOffset: 0,
            maxOffset: 1200,
            edgeInset: 72,
            maxSpeed: 620
        )
        XCTAssertEqual(velocityAtMin, 0)

        let velocityAtMax = calendarAutoScrollVelocity(
            locationInViewport: 300,
            viewportLength: 300,
            currentOffset: 1200,
            minOffset: 0,
            maxOffset: 1200,
            edgeInset: 72,
            maxSpeed: 620
        )
        XCTAssertEqual(velocityAtMax, 0)
    }

    func testQuantizedStepDeltaAccumulatesUntilUnit() {
        let first = calendarQuantizedStepDelta(
            proposedDelta: 6,
            unitStep: 14,
            carryIn: 0
        )
        XCTAssertEqual(first.applied, 0)
        XCTAssertEqual(first.carryOut, 6)

        let second = calendarQuantizedStepDelta(
            proposedDelta: 5,
            unitStep: 14,
            carryIn: first.carryOut
        )
        XCTAssertEqual(second.applied, 0)
        XCTAssertEqual(second.carryOut, 11)

        let third = calendarQuantizedStepDelta(
            proposedDelta: 5,
            unitStep: 14,
            carryIn: second.carryOut
        )
        XCTAssertEqual(third.applied, 14)
        XCTAssertEqual(third.carryOut, 2)
    }

    func testQuantizedStepDeltaHandlesNegativeAndInvalidStep() {
        let negative = calendarQuantizedStepDelta(
            proposedDelta: -30,
            unitStep: 14,
            carryIn: 0
        )
        XCTAssertEqual(negative.applied, -28)
        XCTAssertEqual(negative.carryOut, -2)

        let passthrough = calendarQuantizedStepDelta(
            proposedDelta: 12,
            unitStep: 0,
            carryIn: 5
        )
        XCTAssertEqual(passthrough.applied, 12)
        XCTAssertEqual(passthrough.carryOut, 0)
    }

}
