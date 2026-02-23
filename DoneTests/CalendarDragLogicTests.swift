import XCTest
import UIKit
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

    func testDroppedRangeUsesSameOffsetSnapModelAsPreview() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 7))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 37))!
        let range = Event.TimeRange(start: start, end: end)

        // 8 minutes drag should snap to +15 minutes offset (not to absolute :00/:15 grid).
        let hourHeight: CGFloat = 56
        let offsetY = hourHeight * (8.0 / 60.0)
        let dropped = calendarDroppedRangeFromDrag(
            draggedRange: range,
            dayOffsetFromDrag: 0,
            offsetY: offsetY,
            hourHeight: hourHeight,
            calendar: calendar
        )

        XCTAssertEqual(dropped.start, start.addingTimeInterval(15 * 60))
        XCTAssertEqual(dropped.end, end.addingTimeInterval(15 * 60))
    }

    func testDroppedRangeKeepsBoundaryUnsnappedAndAppliesDayShift() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 23, minute: 50))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 23, minute: 55))!
        let range = Event.TimeRange(start: start, end: end)

        // 8 minutes drag would snap across midnight; keep unsnapped in boundary case.
        let hourHeight: CGFloat = 56
        let offsetY = hourHeight * (8.0 / 60.0)
        let dropped = calendarDroppedRangeFromDrag(
            draggedRange: range,
            dayOffsetFromDrag: 2,
            offsetY: offsetY,
            hourHeight: hourHeight,
            calendar: calendar
        )

        let shiftedStart = calendar.date(byAdding: .day, value: 2, to: start)!
        let shiftedEnd = calendar.date(byAdding: .day, value: 2, to: end)!
        XCTAssertEqual(dropped.start, shiftedStart.addingTimeInterval(8 * 60))
        XCTAssertEqual(dropped.end, shiftedEnd.addingTimeInterval(8 * 60))
    }

    func testTimelineColumnsUseNonLazyInEditMode() {
        XCTAssertFalse(calendarShouldUseLazyTimelineColumns(mode: .edit, daysCount: 7))
    }

    func testTimelineColumnsUseNonLazyInPreviewMode() {
        XCTAssertFalse(calendarShouldUseLazyTimelineColumns(mode: .preview, daysCount: 3))
    }

    func testTimelineColumnsUseNonLazyInSingleDayPreviewMode() {
        XCTAssertFalse(calendarShouldUseLazyTimelineColumns(mode: .preview, daysCount: 1))
    }

    func testIsMoveDragActive() {
        XCTAssertFalse(
            calendarIsMoveDragActive(
                draggingEventID: nil,
                dragMode: .move
            )
        )
        XCTAssertFalse(
            calendarIsMoveDragActive(
                draggingEventID: UUID(),
                dragMode: .resizeTop
            )
        )
        XCTAssertTrue(
            calendarIsMoveDragActive(
                draggingEventID: UUID(),
                dragMode: .move
            )
        )
    }

    @MainActor
    func testDragTerminalStateAndDropForwarding() {
        XCTAssertEqual(calendarDragTerminalState(for: .ended), .completed)
        XCTAssertEqual(calendarDragTerminalState(for: .cancelled), .cancelled)
        XCTAssertEqual(calendarDragTerminalState(for: .failed), .cancelled)
        XCTAssertNil(calendarDragTerminalState(for: .changed))

        XCTAssertTrue(
            calendarShouldForwardDrop(for: .completed)
        )
        XCTAssertFalse(
            calendarShouldForwardDrop(for: .cancelled)
        )
    }

    func testSharedEventDragDefaultsAreCleared() {
        let defaults = calendarSharedEventDragDefaults()

        XCTAssertNil(defaults.draggingEventID)
        XCTAssertNil(defaults.draggingOccurrenceID)
        XCTAssertNil(defaults.draggingEvent)
        XCTAssertNil(defaults.draggingOriginalRange)
        XCTAssertEqual(defaults.dragOffset, .zero)
        XCTAssertEqual(defaults.dragMode, .move)
        XCTAssertFalse(defaults.isHorizontalEdgeDragging)
        XCTAssertFalse(defaults.isHorizontalAutoScrolling)
    }

    func testGeneralHorizontalSlotSnapDisabledDuringActiveMoveDrag() {
        XCTAssertFalse(
            calendarShouldRunGeneralHorizontalSlotSnap(
                isMoveDragActive: true
            )
        )
        XCTAssertTrue(
            calendarShouldRunGeneralHorizontalSlotSnap(
                isMoveDragActive: false
            )
        )
    }

    func testConsumePendingAutoStopSnapIgnoresSnapDisableFlags() {
        XCTAssertTrue(
            calendarShouldConsumePendingAutoStopSnap(
                pendingSnapAfterAutoScrollStop: true,
                isRestoringScroll: false
            )
        )
        XCTAssertFalse(
            calendarShouldConsumePendingAutoStopSnap(
                pendingSnapAfterAutoScrollStop: false,
                isRestoringScroll: false
            )
        )
        XCTAssertFalse(
            calendarShouldConsumePendingAutoStopSnap(
                pendingSnapAfterAutoScrollStop: true,
                isRestoringScroll: true
            )
        )
    }

    func testDisableHorizontalScrollSnapWhileHorizontalBoundaryDragging() {
        XCTAssertTrue(
            calendarShouldDisableHorizontalScrollSnap(
                isHorizontalEdgeDragging: true,
                isHorizontalAutoScrolling: false
            )
        )
        XCTAssertTrue(
            calendarShouldDisableHorizontalScrollSnap(
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: true
            )
        )
        XCTAssertFalse(
            calendarShouldDisableHorizontalScrollSnap(
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: false
            )
        )
    }

    func testShouldSnapImmediatelyAfterHorizontalAutoScrollStop() {
        XCTAssertTrue(
            calendarShouldSnapImmediatelyAfterHorizontalAutoScrollStop(
                previousIsHorizontalAutoScrolling: true,
                currentIsHorizontalAutoScrolling: false
            )
        )
        XCTAssertFalse(
            calendarShouldSnapImmediatelyAfterHorizontalAutoScrollStop(
                previousIsHorizontalAutoScrolling: false,
                currentIsHorizontalAutoScrolling: false
            )
        )
        XCTAssertFalse(
            calendarShouldSnapImmediatelyAfterHorizontalAutoScrollStop(
                previousIsHorizontalAutoScrolling: true,
                currentIsHorizontalAutoScrolling: true
            )
        )
    }

    func testNearestLeadingDayOffsetRoundsAndClamps() {
        XCTAssertEqual(
            calendarNearestLeadingDayOffset(
                contentOffsetX: 164,
                step: 100,
                leadingRange: -10...10
            ),
            -8
        )
        XCTAssertEqual(
            calendarNearestLeadingDayOffset(
                contentOffsetX: -1000,
                step: 100,
                leadingRange: -3...3
            ),
            -3
        )
        XCTAssertEqual(
            calendarNearestLeadingDayOffset(
                contentOffsetX: 1000,
                step: 100,
                leadingRange: -3...3
            ),
            3
        )
        XCTAssertEqual(
            calendarNearestLeadingDayOffset(
                contentOffsetX: 500,
                step: 0,
                leadingRange: -5...5
            ),
            -5
        )
    }

    func testCenteredDayOffsetRangeReservesBothSidesForMultiDayViewport() {
        XCTAssertEqual(
            calendarCenteredDayOffsetRange(
                dayRange: -10...10,
                daysCount: 1
            ),
            -10...10
        )
        XCTAssertEqual(
            calendarCenteredDayOffsetRange(
                dayRange: -10...10,
                daysCount: 3
            ),
            -9...9
        )
        XCTAssertEqual(
            calendarCenteredDayOffsetRange(
                dayRange: -10...10,
                daysCount: 7
            ),
            -7...7
        )
    }

    func testLeadingAndCenteredDayOffsetConversionForThreeDayAndWeek() {
        let threeDayLeadingRange = -10...8
        let threeDayCenteredRange = -9...9

        XCTAssertEqual(
            calendarLeadingDayOffsetFromCentered(
                centeredDayOffset: 5,
                daysCount: 3,
                leadingRange: threeDayLeadingRange
            ),
            4
        )
        XCTAssertEqual(
            calendarCenteredDayOffsetFromLeading(
                leadingDayOffset: 4,
                daysCount: 3,
                centeredRange: threeDayCenteredRange
            ),
            5
        )
        XCTAssertEqual(
            calendarLeadingDayOffsetFromCentered(
                centeredDayOffset: 99,
                daysCount: 3,
                leadingRange: threeDayLeadingRange
            ),
            8
        )
        XCTAssertEqual(
            calendarCenteredDayOffsetFromLeading(
                leadingDayOffset: -99,
                daysCount: 3,
                centeredRange: threeDayCenteredRange
            ),
            -9
        )

        let weekLeadingRange = -10...4
        let weekCenteredRange = -7...7
        XCTAssertEqual(
            calendarLeadingDayOffsetFromCentered(
                centeredDayOffset: 2,
                daysCount: 7,
                leadingRange: weekLeadingRange
            ),
            -1
        )
        XCTAssertEqual(
            calendarCenteredDayOffsetFromLeading(
                leadingDayOffset: -1,
                daysCount: 7,
                centeredRange: weekCenteredRange
            ),
            2
        )
    }

    func testContinuousCenteredDayOffsetTracksScrollProgressAndClamps() {
        XCTAssertEqual(
            calendarContinuousCenteredDayOffset(
                contentOffsetX: 0,
                step: 100,
                leadingRange: -10...8,
                daysCount: 3,
                centeredRange: -9...9
            ),
            -9
        )
        XCTAssertEqual(
            calendarContinuousCenteredDayOffset(
                contentOffsetX: 150,
                step: 100,
                leadingRange: -10...8,
                daysCount: 3,
                centeredRange: -9...9
            ),
            -7.5
        )
        XCTAssertEqual(
            calendarContinuousCenteredDayOffset(
                contentOffsetX: -500,
                step: 100,
                leadingRange: -10...8,
                daysCount: 3,
                centeredRange: -9...9
            ),
            -9
        )
        XCTAssertEqual(
            calendarContinuousCenteredDayOffset(
                contentOffsetX: 5000,
                step: 100,
                leadingRange: -10...8,
                daysCount: 3,
                centeredRange: -9...9
            ),
            9
        )
    }

    func testLegendTrackOffsetsIncludeOverscanAroundVisibleWindow() {
        XCTAssertEqual(
            calendarLegendTrackOffsets(anchor: 5, visibleCount: 1, overscan: 1),
            [4, 5, 6]
        )
        XCTAssertEqual(
            calendarLegendTrackOffsets(anchor: 5, visibleCount: 3, overscan: 1),
            [3, 4, 5, 6, 7]
        )
        XCTAssertEqual(
            calendarLegendTrackOffsets(anchor: 5, visibleCount: 7, overscan: 1),
            [1, 2, 3, 4, 5, 6, 7, 8, 9]
        )
    }

    func testLegendTrackTranslationUsesFractionAndStep() {
        XCTAssertEqual(
            calendarLegendTrackTranslation(
                fraction: 0,
                dayStep: 120
            ),
            0
        )
        XCTAssertEqual(
            calendarLegendTrackTranslation(
                fraction: 0.25,
                dayStep: 120
            ),
            -30
        )
        XCTAssertEqual(
            calendarLegendTrackTranslation(
                fraction: 1,
                dayStep: 120
            ),
            -120
        )
        XCTAssertEqual(
            calendarLegendTrackTranslation(
                fraction: 2.4,
                dayStep: 120
            ),
            -120
        )
        XCTAssertEqual(
            calendarLegendTrackTranslation(
                fraction: -0.5,
                dayStep: 120
            ),
            0
        )
    }

    func testDisableTimeslotSnapWhileHorizontalBoundaryDragging() {
        XCTAssertTrue(
            calendarShouldDisableTimeslotSnap(
                isHorizontalEdgeDragging: true,
                isHorizontalAutoScrolling: false
            )
        )
        XCTAssertTrue(
            calendarShouldDisableTimeslotSnap(
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: true
            )
        )
        XCTAssertFalse(
            calendarShouldDisableTimeslotSnap(
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: false
            )
        )
    }

    func testPreviewOffsetDisablesSnapAtHorizontalBoundary() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 30))!
        let disableSnap = calendarShouldDisableTimeslotSnap(
            isHorizontalEdgeDragging: true,
            isHorizontalAutoScrolling: false
        )
        let offsetSeconds = calendarPreviewOffsetSeconds(
            rawOffsetSeconds: 8 * 60,
            range: Event.TimeRange(start: start, end: end),
            isHorizontalAutoScrolling: disableSnap,
            calendar: calendar
        )
        XCTAssertEqual(offsetSeconds, 8 * 60)
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

    func testAutoScrollDefaultsRespectConfiguredHorizontalAndVerticalInsets() {
        let minOffset: CGFloat = 0
        let maxOffset: CGFloat = 2000

        let horizontalInside = calendarAutoScrollVelocity(
            locationInViewport: 60,
            viewportLength: 360,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: calendarHorizontalAutoScrollEdgeInsetDefault,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        let horizontalOutside = calendarAutoScrollVelocity(
            locationInViewport: 70,
            viewportLength: 360,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: calendarHorizontalAutoScrollEdgeInsetDefault,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        XCTAssertLessThan(horizontalInside, 0)
        XCTAssertEqual(horizontalOutside, 0, accuracy: 0.0001)

        let verticalInside = calendarAutoScrollVelocity(
            locationInViewport: 156,
            viewportLength: 700,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: calendarVerticalAutoScrollEdgeInsetDefault,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        let verticalOutside = calendarAutoScrollVelocity(
            locationInViewport: 176,
            viewportLength: 700,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: calendarVerticalAutoScrollEdgeInsetDefault,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        XCTAssertLessThan(verticalInside, 0)
        XCTAssertEqual(verticalOutside, 0, accuracy: 0.0001)
    }

    func testAutoScrollVelocityCurveIsMoreResponsiveThanSquaredCurve() {
        let maxSpeed: CGFloat = 620
        let velocity = calendarAutoScrollVelocity(
            locationInViewport: 36, // exactly half-way into a 72pt edge inset
            viewportLength: 300,
            currentOffset: 1000,
            minOffset: 0,
            maxOffset: 2000,
            edgeInset: 72,
            maxSpeed: maxSpeed
        )

        let progress: CGFloat = 0.5
        let legacySquaredMagnitude = maxSpeed * progress * progress
        XCTAssertGreaterThan(abs(velocity), legacySquaredMagnitude)
        XCTAssertLessThanOrEqual(abs(velocity), maxSpeed)
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

    func testHorizontalAutoScrollDeltaIsContinuous() {
        let delta = calendarHorizontalAutoScrollDelta(
            velocityX: 620,
            deltaTime: 1.0 / 120.0
        )
        XCTAssertEqual(delta, 5.1666667, accuracy: 0.0001)

        XCTAssertEqual(
            calendarHorizontalAutoScrollDelta(
                velocityX: 620,
                deltaTime: 0
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarHorizontalAutoScrollDelta(
                velocityX: 620,
                deltaTime: -0.1
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testMoveOffsetXSnapInNormalDrag() {
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 66,
                dayColumnStep: 100,
                isHorizontalAutoScrolling: false
            ),
            100
        )
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 32,
                dayColumnStep: 0,
                isHorizontalAutoScrolling: false
            ),
            0
        )
    }

    func testMoveOffsetXNoSnapDuringHorizontalAutoScroll() {
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 66,
                dayColumnStep: 100,
                isHorizontalAutoScrolling: true
            ),
            66
        )
    }

    func testDisableDaySlotSnapWhileHorizontalBoundaryDragging() {
        XCTAssertTrue(
            calendarShouldDisableDaySlotSnap(
                isHorizontalEdgeDragging: true,
                isHorizontalAutoScrolling: false
            )
        )
        XCTAssertTrue(
            calendarShouldDisableDaySlotSnap(
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: true
            )
        )
        XCTAssertFalse(
            calendarShouldDisableDaySlotSnap(
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: false
            )
        )
    }

    func testCreationRequiresDragBeyondThresholdAfterLongPress() {
        XCTAssertFalse(
            calendarShouldActivateCreationAfterLongPress(
                dragDeltaY: 17.9,
                threshold: 18
            )
        )
        XCTAssertFalse(
            calendarShouldActivateCreationAfterLongPress(
                dragDeltaY: -17.9,
                threshold: 18
            )
        )
        XCTAssertTrue(
            calendarShouldActivateCreationAfterLongPress(
                dragDeltaY: 18,
                threshold: 18
            )
        )
        XCTAssertTrue(
            calendarShouldActivateCreationAfterLongPress(
                dragDeltaY: -18,
                threshold: 18
            )
        )
    }

    func testFocusVisualContextActiveWheneverFocusedEventExists() {
        let focusedID = UUID()
        XCTAssertTrue(
            calendarIsFocusVisualContextActive(
                focusedEventID: focusedID,
                visibleEventIDs: []
            )
        )
        XCTAssertTrue(
            calendarIsFocusVisualContextActive(
                focusedEventID: focusedID,
                visibleEventIDs: [focusedID]
            )
        )
    }

    func testFocusVisualContextInactiveWhenFocusedEventMissing() {
        let focusedID = UUID()
        XCTAssertFalse(
            calendarIsFocusVisualContextActive(
                focusedEventID: nil,
                visibleEventIDs: [focusedID]
            )
        )
    }

    func testFocusVisualContextIgnoresDraggingStateWhenFocusedEventExists() {
        let focusedID = UUID()
        XCTAssertTrue(
            calendarIsFocusVisualContextActive(
                focusedEventID: focusedID,
                visibleEventIDs: [],
                draggingEventID: focusedID,
                isMoveDragActive: true
            )
        )
        XCTAssertTrue(
            calendarIsFocusVisualContextActive(
                focusedEventID: focusedID,
                visibleEventIDs: [],
                draggingEventID: UUID(),
                isMoveDragActive: true
            )
        )
        XCTAssertTrue(
            calendarIsFocusVisualContextActive(
                focusedEventID: focusedID,
                visibleEventIDs: [],
                draggingEventID: focusedID,
                isMoveDragActive: false
            )
        )
    }

    func testEventInteractionAllowedWhenFocusContextInactive() {
        let focusedID = UUID()
        XCTAssertTrue(
            calendarShouldAllowEventInteraction(
                focusedEventID: focusedID,
                candidateEventID: UUID(),
                isFocusContextActive: false
            )
        )
    }

    func testEventInteractionAllowedForFocusedEventInFocusContext() {
        let focusedID = UUID()
        XCTAssertTrue(
            calendarShouldAllowEventInteraction(
                focusedEventID: focusedID,
                candidateEventID: focusedID,
                isFocusContextActive: true
            )
        )
    }

    func testEventInteractionBlockedForNonFocusedEventInFocusContext() {
        let focusedID = UUID()
        XCTAssertFalse(
            calendarShouldAllowEventInteraction(
                focusedEventID: focusedID,
                candidateEventID: UUID(),
                isFocusContextActive: true
            )
        )
    }

    func testRangeModeMenuIncludesDayThreeDayWeek() {
        XCTAssertEqual(
            calendarRangeModeMenuOptions(),
            [.day, .threeDay, .week]
        )
    }

    func testAutoScrollEdgeZoneDetection() {
        XCTAssertTrue(
            calendarIsInAutoScrollEdgeZone(
                locationInViewport: 10,
                viewportLength: 300,
                edgeInset: 72
            )
        )
        XCTAssertTrue(
            calendarIsInAutoScrollEdgeZone(
                locationInViewport: 295,
                viewportLength: 300,
                edgeInset: 72
            )
        )
        XCTAssertFalse(
            calendarIsInAutoScrollEdgeZone(
                locationInViewport: 150,
                viewportLength: 300,
                edgeInset: 72
            )
        )
    }

    func testEdgeActiveWithGraceStaysActiveUntilDeadline() {
        let initial = calendarEdgeActiveWithGrace(
            rawEdgeActive: true,
            now: 1.0,
            graceDeadline: 0,
            releaseGrace: 0.12
        )
        XCTAssertTrue(initial.isActive)

        let held = calendarEdgeActiveWithGrace(
            rawEdgeActive: false,
            now: 1.05,
            graceDeadline: initial.nextGraceDeadline,
            releaseGrace: 0.12
        )
        XCTAssertTrue(held.isActive)
        XCTAssertEqual(held.nextGraceDeadline, initial.nextGraceDeadline, accuracy: 0.0001)
    }

    func testEdgeActiveWithGraceEndsAfterDeadline() {
        let initial = calendarEdgeActiveWithGrace(
            rawEdgeActive: true,
            now: 1.0,
            graceDeadline: 0,
            releaseGrace: 0.12
        )

        let released = calendarEdgeActiveWithGrace(
            rawEdgeActive: false,
            now: 1.2,
            graceDeadline: initial.nextGraceDeadline,
            releaseGrace: 0.12
        )
        XCTAssertFalse(released.isActive)
        XCTAssertEqual(released.nextGraceDeadline, 0, accuracy: 0.0001)
    }

    func testHorizontalSnapSuppressionStaysOnInEdgeOrAutoScroll() {
        XCTAssertTrue(
            calendarShouldSuppressHorizontalSnap(
                wasSuppressed: false,
                isInHorizontalEdgeZone: true,
                isHorizontalAutoScrolling: false,
                isHorizontallyAlignedToStep: true
            )
        )
        XCTAssertTrue(
            calendarShouldSuppressHorizontalSnap(
                wasSuppressed: false,
                isInHorizontalEdgeZone: false,
                isHorizontalAutoScrolling: true,
                isHorizontallyAlignedToStep: true
            )
        )
    }

    func testHorizontalSnapSuppressionLatchesUntilAlignedAfterBoundaryStops() {
        let started = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: false,
            isInHorizontalEdgeZone: true,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: true
        )
        XCTAssertTrue(started)

        let stillSuppressed = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: started,
            isInHorizontalEdgeZone: false,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: false
        )
        XCTAssertTrue(stillSuppressed)

        let released = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: stillSuppressed,
            isInHorizontalEdgeZone: false,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: true
        )
        XCTAssertFalse(released)
    }

    func testMoveOffsetXNoSnapOnFirstEdgeFrameBeforeAutoScrollVelocityBuilds() {
        let suppression = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: false,
            isInHorizontalEdgeZone: true,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: false
        )
        XCTAssertTrue(suppression)
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 66,
                dayColumnStep: 100,
                isHorizontalAutoScrolling: suppression
            ),
            66
        )
    }

    func testResolvedDragOffsetSnapsMoveXWhenSuppressionDisabled() {
        let resolved = calendarResolvedDragOffset(
            rawOffset: DragOffset(x: 166, y: 20),
            dragMode: .move,
            dayColumnStep: 100,
            suppressHorizontalSnap: false
        )
        XCTAssertEqual(resolved.x, 200)
        XCTAssertEqual(resolved.y, 20)
    }

    func testResolvedDragOffsetKeepsMoveXRawWhenSuppressed() {
        let resolved = calendarResolvedDragOffset(
            rawOffset: DragOffset(x: 166, y: 20),
            dragMode: .move,
            dayColumnStep: 100,
            suppressHorizontalSnap: true
        )
        XCTAssertEqual(resolved.x, 166)
        XCTAssertEqual(resolved.y, 20)
    }

    func testResolvedDragOffsetForResizeModeKeepsOnlyY() {
        let resolvedTop = calendarResolvedDragOffset(
            rawOffset: DragOffset(x: 166, y: 20),
            dragMode: .resizeTop,
            dayColumnStep: 100,
            suppressHorizontalSnap: true
        )
        XCTAssertEqual(resolvedTop.x, 0)
        XCTAssertEqual(resolvedTop.y, 20)
    }

    func testMoveOffsetXRemainsUnsnappedUntilHorizontalAlignmentRecovers() {
        var suppressed = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: false,
            isInHorizontalEdgeZone: true,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: false
        )
        XCTAssertTrue(suppressed)
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 166,
                dayColumnStep: 100,
                isHorizontalAutoScrolling: suppressed
            ),
            166
        )

        // Finger leaves edge and auto-scroll already stopped, but still between slots:
        // suppression should remain active and keep unsnapped.
        suppressed = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: suppressed,
            isInHorizontalEdgeZone: false,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: false
        )
        XCTAssertTrue(suppressed)
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 166,
                dayColumnStep: 100,
                isHorizontalAutoScrolling: suppressed
            ),
            166
        )
    }

    func testMoveOffsetXResnapsImmediatelyAfterSuppressionRelease() {
        let suppressionReleased = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: true,
            isInHorizontalEdgeZone: false,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: true
        )
        XCTAssertFalse(suppressionReleased)
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 166,
                dayColumnStep: 100,
                isHorizontalAutoScrolling: suppressionReleased
            ),
            200
        )
    }

    func testHorizontalSnapSuppressionDoesNotStartWithoutEdgeOrAutoScroll() {
        XCTAssertFalse(
            calendarShouldSuppressHorizontalSnap(
                wasSuppressed: false,
                isInHorizontalEdgeZone: false,
                isHorizontalAutoScrolling: false,
                isHorizontallyAlignedToStep: false
            )
        )
    }

    func testHorizontalSnapSuppressionReleaseDeadlineExtendsWhileBoundaryActive() {
        let deadlineFromEdge = calendarHorizontalSnapSuppressionReleaseDeadline(
            now: 10.0,
            currentDeadline: 0,
            isInHorizontalEdgeZone: true,
            isHorizontalAutoScrolling: false,
            holdDuration: 0.22
        )
        XCTAssertEqual(deadlineFromEdge, 10.22, accuracy: 0.0001)

        let deadlineFromAuto = calendarHorizontalSnapSuppressionReleaseDeadline(
            now: 11.0,
            currentDeadline: deadlineFromEdge,
            isInHorizontalEdgeZone: false,
            isHorizontalAutoScrolling: true,
            holdDuration: 0.22
        )
        XCTAssertEqual(deadlineFromAuto, 11.22, accuracy: 0.0001)
    }

    func testHorizontalSnapSuppressionHoldPreventsEarlyReleaseEvenWhenAligned() {
        let deadline = calendarHorizontalSnapSuppressionReleaseDeadline(
            now: 5.0,
            currentDeadline: 0,
            isInHorizontalEdgeZone: true,
            isHorizontalAutoScrolling: false,
            holdDuration: 0.22
        )
        let canReleaseEarly = 5.1 >= deadline
        XCTAssertFalse(canReleaseEarly)

        let stillSuppressed = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: true,
            isInHorizontalEdgeZone: false,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: true && canReleaseEarly
        )
        XCTAssertTrue(stillSuppressed)

        let canReleaseLater = 5.3 >= deadline
        XCTAssertTrue(canReleaseLater)
        let released = calendarShouldSuppressHorizontalSnap(
            wasSuppressed: true,
            isInHorizontalEdgeZone: false,
            isHorizontalAutoScrolling: false,
            isHorizontallyAlignedToStep: true && canReleaseLater
        )
        XCTAssertFalse(released)
    }

    func testPreviewOffsetUsesSnappedOffsetAwayFromDayBoundary() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 30))!

        // 8 minutes drag -> should snap to 15 minutes (away from day boundary).
        let offset = calendarPreviewOffsetSeconds(
            rawOffsetSeconds: 8 * 60,
            range: Event.TimeRange(start: start, end: end),
            calendar: calendar
        )
        XCTAssertEqual(offset, 15 * 60)
    }

    func testPreviewOffsetKeepsUnsnappedDuringHorizontalAutoScroll() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 30))!

        let unsnappedSeconds = TimeInterval(8 * 60)
        let offset = calendarPreviewOffsetSeconds(
            rawOffsetSeconds: unsnappedSeconds,
            range: Event.TimeRange(start: start, end: end),
            isHorizontalAutoScrolling: true,
            calendar: calendar
        )
        XCTAssertEqual(offset, unsnappedSeconds)
    }

    func testPreviewOffsetKeepsUnsnappedWhenSnapWouldCrossDayBoundary() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 23, minute: 50))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 23, minute: 55))!

        // 8 minutes drag: unsnapped stays in same day, snapped would jump to next day.
        let unsnappedSeconds = TimeInterval(8 * 60)
        let offset = calendarPreviewOffsetSeconds(
            rawOffsetSeconds: unsnappedSeconds,
            range: Event.TimeRange(start: start, end: end),
            calendar: calendar
        )
        XCTAssertEqual(offset, unsnappedSeconds)
    }

    func testAdjustedOccurrenceRangeClipsIntersectingPreview() {
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let occurrence = Event.TimeRange(
            start: dayStart.addingTimeInterval(9 * 3600),
            end: dayStart.addingTimeInterval(10 * 3600)
        )
        let preview = Event.TimeRange(
            start: dayStart.addingTimeInterval(-3600),
            end: dayStart.addingTimeInterval(2 * 3600)
        )

        let adjusted = calendarAdjustedOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: occurrence,
            draggingOccurrenceID: "occ-1",
            dragMode: .move,
            previewRange: preview,
            dayStart: dayStart,
            dayEnd: dayEnd
        )

        XCTAssertEqual(adjusted?.start, dayStart)
        XCTAssertEqual(adjusted?.end, dayStart.addingTimeInterval(2 * 3600))
    }

    func testAdjustedOccurrenceRangePinsWhenPreviewLeavesDay() {
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let occurrence = Event.TimeRange(
            start: dayStart.addingTimeInterval(9 * 3600),
            end: dayStart.addingTimeInterval(10 * 3600)
        )

        let afterPreview = Event.TimeRange(
            start: dayEnd.addingTimeInterval(3600),
            end: dayEnd.addingTimeInterval(2 * 3600)
        )
        let pinnedToEnd = calendarAdjustedOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: occurrence,
            draggingOccurrenceID: "occ-1",
            dragMode: .move,
            previewRange: afterPreview,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        XCTAssertEqual(pinnedToEnd?.start, dayEnd.addingTimeInterval(-15 * 60))
        XCTAssertEqual(pinnedToEnd?.end, dayEnd)

        let beforePreview = Event.TimeRange(
            start: dayStart.addingTimeInterval(-2 * 3600),
            end: dayStart.addingTimeInterval(-3600)
        )
        let pinnedToStart = calendarAdjustedOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: occurrence,
            draggingOccurrenceID: "occ-1",
            dragMode: .move,
            previewRange: beforePreview,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        XCTAssertEqual(pinnedToStart?.start, dayStart)
        XCTAssertEqual(pinnedToStart?.end, dayStart.addingTimeInterval(15 * 60))
    }

    func testAdjustedOccurrenceRangeKeepsOriginalForNonActiveOccurrence() {
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let occurrence = Event.TimeRange(
            start: dayStart.addingTimeInterval(9 * 3600),
            end: dayStart.addingTimeInterval(10 * 3600)
        )
        let preview = Event.TimeRange(
            start: dayEnd.addingTimeInterval(3600),
            end: dayEnd.addingTimeInterval(2 * 3600)
        )

        let adjusted = calendarAdjustedOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: occurrence,
            draggingOccurrenceID: "occ-2",
            dragMode: .move,
            previewRange: preview,
            dayStart: dayStart,
            dayEnd: dayEnd
        )

        XCTAssertEqual(adjusted?.start, occurrence.start)
        XCTAssertEqual(adjusted?.end, occurrence.end)
    }

    @objc func testLegendSlotMinutesThresholds() {
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 96), 30)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 76), 30)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 75), 60)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 56), 60)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 45), 60)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 44), 120)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 18), 120)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 36), 120)
    }

    @objc func testLegendHourLabelCollisionHidesNearCurrentTime() {
        // 5:04 should collide with 5:00 label and hide it.
        XCTAssertTrue(
            calendarShouldHideLegendHourLabel(
                legendTotalMinutes: 17 * 60,
                nowTotalMinutes: CGFloat(17 * 60 + 4),
                hourHeight: 56
            )
        )

        // 5:20 should be far enough to keep the 5:00 label visible.
        XCTAssertFalse(
            calendarShouldHideLegendHourLabel(
                legendTotalMinutes: 17 * 60,
                nowTotalMinutes: CGFloat(17 * 60 + 20),
                hourHeight: 56
            )
        )
    }

    @objc func testLegendHourLabelCollisionReturnsFalseForInvalidHourHeight() {
        XCTAssertFalse(
            calendarShouldHideLegendHourLabel(
                legendTotalMinutes: 17 * 60,
                nowTotalMinutes: CGFloat(17 * 60 + 4),
                hourHeight: 0
            )
        )
    }

    @objc func testTemporalStretchVelocity() {
        XCTAssertEqual(calendarTemporalStretchVelocity(dragDeltaY: 0), 0)
        XCTAssertEqual(calendarTemporalStretchVelocity(dragDeltaY: 9), 0)
        XCTAssertEqual(calendarTemporalStretchVelocity(dragDeltaY: -10), 0)

        let expandVelocity = calendarTemporalStretchVelocity(dragDeltaY: -100)
        let shrinkVelocity = calendarTemporalStretchVelocity(dragDeltaY: 100)
        XCTAssertGreaterThan(expandVelocity, 0)
        XCTAssertLessThan(shrinkVelocity, 0)

        let saturatedExpand = calendarTemporalStretchVelocity(dragDeltaY: -9999)
        let saturatedShrink = calendarTemporalStretchVelocity(dragDeltaY: 9999)
        XCTAssertEqual(saturatedExpand, 48, accuracy: 0.0001)
        XCTAssertEqual(saturatedShrink, -48, accuracy: 0.0001)
    }

    @objc func testTemporalStretchHourHeightAfterTick() {
        let expanded = calendarTemporalStretchHourHeightAfterTick(
            currentHourHeight: 56,
            dragDeltaY: -220,
            deltaTime: 0.5
        )
        XCTAssertEqual(expanded, 80, accuracy: 0.0001)

        let shrunk = calendarTemporalStretchHourHeightAfterTick(
            currentHourHeight: 56,
            dragDeltaY: 220,
            deltaTime: 0.5
        )
        XCTAssertEqual(shrunk, 32, accuracy: 0.0001)

        let clampedMax = calendarTemporalStretchHourHeightAfterTick(
            currentHourHeight: 95,
            dragDeltaY: -220,
            deltaTime: 1.0
        )
        XCTAssertEqual(clampedMax, 96, accuracy: 0.0001)

        let noAdvanceWhenDeltaIsZero = calendarTemporalStretchHourHeightAfterTick(
            currentHourHeight: 60,
            dragDeltaY: -220,
            deltaTime: 0
        )
        XCTAssertEqual(noAdvanceWhenDeltaIsZero, 60, accuracy: 0.0001)

        let clampedMin = calendarTemporalStretchHourHeightAfterTick(
            currentHourHeight: 20,
            dragDeltaY: 220,
            deltaTime: 1.0
        )
        XCTAssertEqual(clampedMin, 18, accuracy: 0.0001)
    }

    @objc func testRangeModeStepFromPinchScaleAndMapping() {
        XCTAssertEqual(calendarRangeModeStepFromPinchScale(scale: 1), 0)
        XCTAssertEqual(calendarRangeModeStepFromPinchScale(scale: 0.9), 0)
        XCTAssertEqual(calendarRangeModeStepFromPinchScale(scale: 0.88), -1)
        XCTAssertEqual(calendarRangeModeStepFromPinchScale(scale: 1.12), 1)
        XCTAssertEqual(calendarRangeModeStepFromPinchScale(scale: -1), 0)

        XCTAssertEqual(
            calendarRangeModeAfterPinchStep(current: .day, step: -1),
            .day
        )
        XCTAssertEqual(
            calendarRangeModeAfterPinchStep(current: .day, step: 1),
            .threeDay
        )
        XCTAssertEqual(
            calendarRangeModeAfterPinchStep(current: .threeDay, step: -1),
            .day
        )
        XCTAssertEqual(
            calendarRangeModeAfterPinchStep(current: .threeDay, step: 1),
            .week
        )
        XCTAssertEqual(
            calendarRangeModeAfterPinchStep(current: .week, step: 1),
            .week
        )
        XCTAssertEqual(
            calendarRangeModeAfterPinchStep(current: .week, step: -1),
            .threeDay
        )
    }

    @objc func testPinchBoundaryResistanceProgressAndVisualScale() {
        XCTAssertEqual(
            calendarPinchBoundaryResistanceProgress(scale: 1.1, step: -1),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarPinchBoundaryResistanceProgress(scale: 0.9, step: 1),
            0,
            accuracy: 0.0001
        )

        let inResistance = calendarPinchBoundaryResistanceProgress(scale: 0.7, step: -1)
        let outResistance = calendarPinchBoundaryResistanceProgress(scale: 1.3, step: 1)
        XCTAssertGreaterThan(inResistance, 0)
        XCTAssertGreaterThan(outResistance, 0)

        XCTAssertEqual(
            calendarPinchBoundaryResistanceProgress(scale: 0.1, step: -1),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarPinchBoundaryResistanceProgress(scale: 2.0, step: 1),
            1,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            calendarPinchBoundaryVisualScale(step: 0, resistanceProgress: 1),
            1,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            calendarPinchBoundaryVisualScale(step: -1, resistanceProgress: 1),
            1
        )
        XCTAssertGreaterThan(
            calendarPinchBoundaryVisualScale(step: 1, resistanceProgress: 1),
            1
        )
    }

    func testFreezeSelectedDayOffsetDuringMoveDrag() {
        XCTAssertTrue(
            calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
                isMoveDragActive: true,
                isHorizontalAutoScrolling: false
            )
        )
        XCTAssertFalse(
            calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
                isMoveDragActive: true,
                isHorizontalAutoScrolling: true
            )
        )
        XCTAssertFalse(
            calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
                isMoveDragActive: true,
                isHorizontalEdgeDragging: true,
                isHorizontalAutoScrolling: false
            )
        )
        XCTAssertFalse(
            calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
                isMoveDragActive: false,
                isHorizontalAutoScrolling: false
            )
        )
    }

    func testPersistentHorizontalSlotSnapAlwaysEnabled() {
        XCTAssertTrue(
            calendarShouldEnablePersistentHorizontalSlotSnap(
                isMoveDragActive: false,
                isHorizontalSlotSnapDisabled: false
            )
        )
        XCTAssertTrue(
            calendarShouldEnablePersistentHorizontalSlotSnap(
                isMoveDragActive: true,
                isHorizontalSlotSnapDisabled: true
            )
        )
    }

    func testNowIndicatorOnlyShownOnTodayColumn() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 0))!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        XCTAssertTrue(calendarShouldShowNowIndicator(for: today, now: now, calendar: calendar))
        XCTAssertFalse(calendarShouldShowNowIndicator(for: yesterday, now: now, calendar: calendar))
    }

    func testNowIndicatorYOffsetClampsWithinDayBounds() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14))!
        let hourHeight: CGFloat = 60
        let headerHeight: CGFloat = 20

        let before = day.addingTimeInterval(-3600)
        let after = day.addingTimeInterval(25 * 3600)
        let mid = day.addingTimeInterval(6.5 * 3600)

        XCTAssertEqual(
            calendarNowIndicatorYOffset(
                now: before,
                day: day,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                calendar: calendar
            ),
            headerHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            calendarNowIndicatorYOffset(
                now: after,
                day: day,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                calendar: calendar
            ),
            headerHeight + 24 * hourHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            calendarNowIndicatorYOffset(
                now: mid,
                day: day,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                calendar: calendar
            ),
            headerHeight + 6.5 * hourHeight,
            accuracy: 0.001
        )
    }

    func testTimelineTopAndBottomInsetsProvideBreathingSpace() {
        let compactTop = calendarTimelineTopInset(hourHeight: 24)
        let compactBottom = calendarTimelineBottomInset(hourHeight: 24)
        let regularTop = calendarTimelineTopInset(hourHeight: 56)
        let regularBottom = calendarTimelineBottomInset(hourHeight: 56)

        XCTAssertGreaterThanOrEqual(compactTop, 14)
        XCTAssertGreaterThanOrEqual(compactBottom, 20)
        XCTAssertGreaterThan(regularTop, compactTop)
        XCTAssertGreaterThan(regularBottom, compactBottom)
    }

    func testHeaderCapsuleVisibilityUsesDualThresholdHysteresis() {
        XCTAssertTrue(
            calendarNextHeaderCapsuleVisibility(
                scrollY: 63,
                currentlyVisible: true,
                hideThreshold: 64,
                showThreshold: 52
            )
        )
        XCTAssertFalse(
            calendarNextHeaderCapsuleVisibility(
                scrollY: 64,
                currentlyVisible: true,
                hideThreshold: 64,
                showThreshold: 52
            )
        )
        XCTAssertFalse(
            calendarNextHeaderCapsuleVisibility(
                scrollY: 60,
                currentlyVisible: false,
                hideThreshold: 64,
                showThreshold: 52
            )
        )
        XCTAssertTrue(
            calendarNextHeaderCapsuleVisibility(
                scrollY: 52,
                currentlyVisible: false,
                hideThreshold: 64,
                showThreshold: 52
            )
        )
    }

    func testHeaderCapsuleVisibilitySanitizesInputs() {
        XCTAssertTrue(
            calendarNextHeaderCapsuleVisibility(
                scrollY: .nan,
                currentlyVisible: true
            )
        )
        XCTAssertFalse(
            calendarNextHeaderCapsuleVisibility(
                scrollY: 1000,
                currentlyVisible: true,
                hideThreshold: .nan,
                showThreshold: .infinity
            )
        )
        XCTAssertTrue(
            calendarNextHeaderCapsuleVisibility(
                scrollY: 0,
                currentlyVisible: false,
                hideThreshold: 52,
                showThreshold: 64
            )
        )
    }

    func testCapsuleVisibleHeightUsesBinaryVisibility() {
        XCTAssertEqual(calendarCapsuleVisibleHeight(isVisible: true), 52, accuracy: 0.0001)
        XCTAssertEqual(calendarCapsuleVisibleHeight(isVisible: false), 0, accuracy: 0.0001)
        XCTAssertEqual(
            calendarCapsuleVisibleHeight(isVisible: true, expandedHeight: 40),
            40,
            accuracy: 0.0001
        )
    }

    func testCapsuleVisibleHeightTreatsNonFiniteExpandedHeightAsSafeValue() {
        XCTAssertEqual(
            calendarCapsuleVisibleHeight(isVisible: true, expandedHeight: .nan),
            52,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarCapsuleVisibleHeight(isVisible: false, expandedHeight: .nan),
            0,
            accuracy: 0.0001
        )
    }

    func testTopOverlayInsetIncludesSafeAreaLegendCapsuleAndGap() {
        XCTAssertEqual(
            calendarTopOverlayInset(
                safeAreaTop: 47,
                isCapsuleVisible: true,
                legendBandHeight: 34,
                overlayGap: 6,
                capsuleExpandedHeight: 52
            ),
            139,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            calendarTopOverlayInset(
                safeAreaTop: 47,
                isCapsuleVisible: false,
                legendBandHeight: 34,
                overlayGap: 6,
                capsuleExpandedHeight: 52
            ),
            87,
            accuracy: 0.0001
        )
    }

    func testTopOverlayInsetMinimumKeepsLegendPinnedWhenCollapsed() {
        XCTAssertEqual(
            calendarTopOverlayInset(
                safeAreaTop: 59,
                isCapsuleVisible: false,
                legendBandHeight: 34,
                overlayGap: 6,
                capsuleExpandedHeight: 52
            ),
            99,
            accuracy: 0.0001
        )

        // Hidden state should not be affected by expanded height.
        XCTAssertEqual(
            calendarTopOverlayInset(
                safeAreaTop: 59,
                isCapsuleVisible: false,
                legendBandHeight: 34,
                overlayGap: 6,
                capsuleExpandedHeight: .nan
            ),
            99,
            accuracy: 0.0001
        )
    }

    func testTopOverlayInsetSanitizesNonFiniteInputs() {
        XCTAssertEqual(
            calendarTopOverlayInset(
                safeAreaTop: .nan,
                isCapsuleVisible: true,
                legendBandHeight: .infinity,
                overlayGap: .nan,
                capsuleExpandedHeight: .nan
            ),
            52,
            accuracy: 0.0001
        )
    }

    func testResolvedSafeAreaInsetUsesLargerValueAndSanitizesInput() {
        XCTAssertEqual(
            calendarResolvedSafeAreaInset(proxyInset: 0, windowInset: 59),
            59,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarResolvedSafeAreaInset(proxyInset: 34, windowInset: 21),
            34,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarResolvedSafeAreaInset(proxyInset: .nan, windowInset: 21),
            21,
            accuracy: 0.0001
        )
    }

    @objc func testShouldOpenEventCardOnTapOnlyForFocusedEvent() {
        let focusedID = UUID()
        let otherID = UUID()

        XCTAssertFalse(
            calendarShouldOpenEventCardOnTap(
                focusedEventID: nil,
                tappedEventID: focusedID
            )
        )
        XCTAssertTrue(
            calendarShouldOpenEventCardOnTap(
                focusedEventID: focusedID,
                tappedEventID: focusedID
            )
        )
        XCTAssertFalse(
            calendarShouldOpenEventCardOnTap(
                focusedEventID: focusedID,
                tappedEventID: otherID
            )
        )
    }

    func testOverlayFadeMaskStartClampsAcrossHeightRatios() {
        XCTAssertEqual(
            calendarOverlayFadeMaskStart(totalHeight: 100, fadeHeight: 12),
            0.88,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarOverlayFadeMaskStart(totalHeight: 8, fadeHeight: 12),
            0,
            accuracy: 0.0001
        )
    }

    func testOverlayFadeMaskStartDisablesFadeForNonPositiveFadeHeight() {
        XCTAssertEqual(
            calendarOverlayFadeMaskStart(totalHeight: 100, fadeHeight: 0),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarOverlayFadeMaskStart(totalHeight: .nan, fadeHeight: 12),
            1,
            accuracy: 0.0001
        )
    }

    func testLegendTitleRespondsToRangeModes() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9))!

        let dayTitle = calendarLegendTitle(
            selectedDayOffset: 0,
            rangeMode: .day,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let threeDayTitle = calendarLegendTitle(
            selectedDayOffset: 0,
            rangeMode: .threeDay,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let weekTitle = calendarLegendTitle(
            selectedDayOffset: 0,
            rangeMode: .week,
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertFalse(dayTitle.isEmpty)
        XCTAssertFalse(threeDayTitle.isEmpty)
        XCTAssertTrue(threeDayTitle.contains("-"))
        XCTAssertTrue(weekTitle.contains("Week"))
        XCTAssertNotEqual(dayTitle, threeDayTitle)
    }

    func testVisibleDatesRespectCenterAnchorForRanges() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14))!

        let day = calendarVisibleDatesForRange(
            selectedDayOffset: 0,
            rangeMode: .day,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let threeDay = calendarVisibleDatesForRange(
            selectedDayOffset: 2,
            rangeMode: .threeDay,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let week = calendarVisibleDatesForRange(
            selectedDayOffset: -3,
            rangeMode: .week,
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(day.count, 1)
        XCTAssertEqual(threeDay.count, 3)
        XCTAssertEqual(week.count, 7)

        let threeDayCenter = threeDay[1]
        let today = calendar.startOfDay(for: referenceDate)
        let expectedCenter = calendar.date(byAdding: .day, value: 2, to: today)!
        XCTAssertTrue(calendar.isDate(threeDayCenter, inSameDayAs: expectedCenter))
    }

    func testUpdatedRangesAfterDropKeepsOtherRanges() {
        let calendar = Calendar(identifier: .gregorian)
        let first = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 8))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9))!
        )
        let second = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11))!
        )
        let droppedSecond = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 12))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 13))!
        )

        let updated = calendarUpdatedRangesAfterDrop(
            existingRanges: [first, second],
            draggedRange: second,
            droppedRange: droppedSecond,
            occurrenceID: nil
        )

        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated.first?.start, first.start)
        XCTAssertEqual(updated.last?.start, droppedSecond.start)
    }

    func testUpdatedRangesAfterDropMatchesOccurrenceHintBeforeFallback() {
        let calendar = Calendar(identifier: .gregorian)
        let first = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 8))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9))!
        )
        let second = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11))!
        )
        let droppedSecond = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 14))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 15))!
        )
        let occurrenceID = "event-\(second.start.timeIntervalSince1970)-\(second.end.timeIntervalSince1970)"
        let fuzzyDragged = Event.TimeRange(
            start: second.start.addingTimeInterval(7),
            end: second.end.addingTimeInterval(7)
        )

        let updated = calendarUpdatedRangesAfterDrop(
            existingRanges: [first, second],
            draggedRange: fuzzyDragged,
            droppedRange: droppedSecond,
            occurrenceID: occurrenceID
        )

        XCTAssertEqual(updated.count, 2)
        XCTAssertTrue(updated.contains(where: { $0.start == first.start && $0.end == first.end }))
        XCTAssertTrue(updated.contains(where: { $0.start == droppedSecond.start && $0.end == droppedSecond.end }))
    }

    func testOccurrenceIDForRangeUsesStartEndForNormalEvents() {
        let calendar = Calendar(identifier: .gregorian)
        let id = UUID()
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 15))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11, minute: 0))!
        )
        let event = Event(
            id: id,
            title: "Normal",
            startTime: range.start,
            endTime: range.end
        )

        let occurrenceID = calendarOccurrenceIDForRange(
            event: event,
            range: range,
            calendar: calendar
        )

        XCTAssertEqual(
            occurrenceID,
            "\(id.uuidString)-\(range.start.timeIntervalSince1970)-\(range.end.timeIntervalSince1970)"
        )
    }

    func testOccurrenceIDForRangeUsesSeriesDayStampForRecurringSeries() {
        let calendar = Calendar(identifier: .gregorian)
        let id = UUID()
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11))!
        )
        let event = Event(
            id: id,
            title: "Recurring",
            startTime: range.start,
            endTime: range.end,
            repeatUnit: .week
        )

        let occurrenceID = calendarOccurrenceIDForRange(
            event: event,
            range: range,
            calendar: calendar
        )
        let dayTimestamp = Int(calendar.startOfDay(for: range.start).timeIntervalSince1970)

        XCTAssertEqual(occurrenceID, "\(id.uuidString)-recur-\(dayTimestamp)")
    }

    func testOccurrenceIDForRangeUsesTimerIdentifierForTimerEvents() {
        let calendar = Calendar(identifier: .gregorian)
        let id = UUID()
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11))!
        )
        let event = Event(
            id: id,
            title: "Timer",
            startTime: range.start,
            endTime: range.end,
            timerStartedAt: range.start
        )

        let occurrenceID = calendarOccurrenceIDForRange(
            event: event,
            range: range,
            calendar: calendar
        )

        XCTAssertEqual(occurrenceID, "\(id.uuidString)-timer")
    }

    func testResolvedFocusedOccurrenceIDReturnsIDWhenPreferredRangeExists() {
        let calendar = Calendar(identifier: .gregorian)
        let first = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 8))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9))!
        )
        let resized = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 30))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 12))!
        )
        let event = Event(
            title: "Focus",
            startTime: first.start,
            endTime: first.end,
            timeRanges: [first, resized]
        )

        let resolved = calendarResolvedFocusedOccurrenceID(
            event: event,
            preferredRange: resized,
            calendar: calendar
        )

        XCTAssertEqual(
            resolved,
            "\(event.id.uuidString)-\(resized.start.timeIntervalSince1970)-\(resized.end.timeIntervalSince1970)"
        )
    }

    func testResolvedFocusedOccurrenceIDReturnsNilWhenPreferredRangeMissing() {
        let calendar = Calendar(identifier: .gregorian)
        let existing = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 8))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9))!
        )
        let missing = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 12))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 13))!
        )
        let event = Event(
            title: "Focus",
            startTime: existing.start,
            endTime: existing.end,
            timeRanges: [existing]
        )

        let resolved = calendarResolvedFocusedOccurrenceID(
            event: event,
            preferredRange: missing,
            calendar: calendar
        )

        XCTAssertNil(resolved)
    }

    func testRangesApproximatelyEqualWithinTolerance() {
        let calendar = Calendar(identifier: .gregorian)
        let base = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11))!
        )
        let close = Event.TimeRange(
            start: base.start.addingTimeInterval(0.4),
            end: base.end.addingTimeInterval(-0.4)
        )
        let far = Event.TimeRange(
            start: base.start.addingTimeInterval(0.8),
            end: base.end
        )

        XCTAssertTrue(calendarRangesApproximatelyEqual(lhs: base, rhs: close))
        XCTAssertFalse(calendarRangesApproximatelyEqual(lhs: base, rhs: far))
    }

    func testEventBlockScaleCapsAt102DuringMoveDrag() {
        XCTAssertEqual(
            calendarEventBlockScale(
                isMoveDragging: true,
                isFocused: true,
                isDimmedByFocus: false
            ),
            1.02,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarEventBlockScale(
                isMoveDragging: false,
                isFocused: true,
                isDimmedByFocus: false
            ),
            1.01,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarEventBlockScale(
                isMoveDragging: false,
                isFocused: false,
                isDimmedByFocus: true
            ),
            1.0,
            accuracy: 0.0001
        )
    }

    func testResolveEditMappingStatePriorityCreationOverDragOverFocus() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14))!
        let creationRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10))!
        )
        let dragRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 12))!
        )
        let focusedRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 13))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 14))!
        )

        let resolvedWithCreation = calendarResolveEditMappingState(
            creation: (date: anchor, range: creationRange),
            drag: (source: .moveDrag, date: anchor, range: dragRange),
            focused: (date: anchor, range: focusedRange)
        )
        XCTAssertEqual(resolvedWithCreation?.source, .creation)
        XCTAssertEqual(resolvedWithCreation?.range.start, creationRange.start)

        let resolvedWithDrag = calendarResolveEditMappingState(
            creation: nil,
            drag: (source: .resizeTop, date: anchor, range: dragRange),
            focused: (date: anchor, range: focusedRange)
        )
        XCTAssertEqual(resolvedWithDrag?.source, .resizeTop)
        XCTAssertEqual(resolvedWithDrag?.range.start, dragRange.start)

        let resolvedFocusedOnly = calendarResolveEditMappingState(
            creation: nil,
            drag: nil,
            focused: (date: anchor, range: focusedRange)
        )
        XCTAssertEqual(resolvedFocusedOnly?.source, .focused)
        XCTAssertEqual(resolvedFocusedOnly?.range.start, focusedRange.start)
    }

    func testResolveDragEditRangeForResizeTopAndResizeBottom() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11, minute: 0))!
        let range = Event.TimeRange(start: start, end: end)
        let hourHeight: CGFloat = 56
        let halfHourOffset = DragOffset(x: 0, y: 28)

        let top = calendarResolvedDragEditRange(
            draggingOriginalRange: range,
            dragOffset: halfHourOffset,
            dragMode: .resizeTop,
            hourHeight: hourHeight,
            calendar: calendar
        )
        XCTAssertEqual(top?.start, start.addingTimeInterval(30 * 60))
        XCTAssertEqual(top?.end, end)

        let bottom = calendarResolvedDragEditRange(
            draggingOriginalRange: range,
            dragOffset: halfHourOffset,
            dragMode: .resizeBottom,
            hourHeight: hourHeight,
            calendar: calendar
        )
        XCTAssertEqual(bottom?.start, start)
        XCTAssertEqual(bottom?.end, end.addingTimeInterval(30 * 60))
    }

    func testResolveAxisMarkerPresentationCollapsesShortRange() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 15))!
        let state = TimelineEditMappingState(
            source: .focused,
            anchorDate: anchor,
            range: Event.TimeRange(start: start, end: end)
        )

        let presentation = calendarResolveAxisMarkerPresentation(
            mappingState: state,
            headerHeight: 14,
            hourHeight: 56,
            collapseThreshold: 20,
            calendar: calendar
        )

        XCTAssertNotNil(presentation)
        XCTAssertTrue(presentation?.isCollapsed ?? false)
        XCTAssertEqual(presentation?.collapsedText, "10:00 - 10:15")
    }

    func testResolveFocusedEditRangeByOccurrenceID() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14))!
        let focusedEventID = UUID()
        let otherEventID = UUID()

        let firstRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 0))!
        )
        let secondRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 14, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 15, minute: 0))!
        )

        let focusedEvent = Event(
            id: focusedEventID,
            title: "Focused",
            startTime: firstRange.start,
            endTime: firstRange.end
        )
        let otherEvent = Event(
            id: otherEventID,
            title: "Other",
            startTime: firstRange.start,
            endTime: firstRange.end
        )

        let occurrencesByOffset: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [
                CalendarLayout.EventOccurrence(id: "focused-0", event: focusedEvent, range: firstRange),
                CalendarLayout.EventOccurrence(id: "other-0", event: otherEvent, range: firstRange)
            ],
            1: [
                CalendarLayout.EventOccurrence(id: "focused-1", event: focusedEvent, range: secondRange)
            ]
        ]

        let resolved = calendarResolvedFocusedEditRange(
            focusedEventID: focusedEventID,
            focusedOccurrenceID: "focused-1",
            visibleOffsets: [0, 1],
            occurrencesForOffset: { occurrencesByOffset[$0] ?? [] },
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(resolved?.range.start, secondRange.start)
        XCTAssertEqual(resolved?.range.end, secondRange.end)
        let expectedDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate))!
        XCTAssertTrue(calendar.isDate(resolved?.date ?? Date.distantPast, inSameDayAs: expectedDay))
    }

    func testMoveDragMappingUpdatesRangeInRealtime() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 30))!
        let range = Event.TimeRange(start: start, end: end)

        let snappedMove = calendarResolvedDragEditRange(
            draggingOriginalRange: range,
            dragOffset: DragOffset(x: 0, y: 20),
            dragMode: .move,
            hourHeight: 60,
            isHorizontalAutoScrolling: false,
            calendar: calendar
        )
        XCTAssertEqual(snappedMove?.start, start.addingTimeInterval(15 * 60))
        XCTAssertEqual(snappedMove?.end, end.addingTimeInterval(15 * 60))

        let rawMove = calendarResolvedDragEditRange(
            draggingOriginalRange: range,
            dragOffset: DragOffset(x: 0, y: 20),
            dragMode: .move,
            hourHeight: 60,
            isHorizontalAutoScrolling: true,
            calendar: calendar
        )
        XCTAssertEqual(rawMove?.start, start.addingTimeInterval(20 * 60))
        XCTAssertEqual(rawMove?.end, end.addingTimeInterval(20 * 60))
    }

    func testShouldRevealTodoPanelAtHardThreshold() {
        XCTAssertFalse(
            calendarShouldRevealTodoPanel(
                pullDistance: 95,
                threshold: 96
            )
        )
        XCTAssertTrue(
            calendarShouldRevealTodoPanel(
                pullDistance: 96,
                threshold: 96
            )
        )
    }

    func testTodoRevealInteractiveHeightIsZeroBelowThreshold() {
        XCTAssertEqual(
            calendarTodoRevealInteractiveHeight(
                pullDistance: 95,
                threshold: 96,
                maxHeight: 320
            ),
            0
        )
    }

    func testTodoRevealInteractiveHeightGrowsAfterThresholdAndClamps() {
        XCTAssertEqual(
            calendarTodoRevealInteractiveHeight(
                pullDistance: 120,
                threshold: 96,
                maxHeight: 320
            ),
            24
        )
        XCTAssertEqual(
            calendarTodoRevealInteractiveHeight(
                pullDistance: 600,
                threshold: 96,
                maxHeight: 180
            ),
            180
        )
    }

    func testTodoRevealExpandedHeightUsesHalfVisibleContent() {
        XCTAssertEqual(
            calendarTodoRevealExpandedHeight(
                visibleContentHeight: 640,
                fraction: 0.5
            ),
            320
        )
        XCTAssertEqual(
            calendarTodoRevealExpandedHeight(
                visibleContentHeight: -10,
                fraction: 0.5
            ),
            0
        )
    }

    func testTodoDrawerTargetExpandedHeightUsesContentAdaptiveWithHalfPageCap() {
        XCTAssertEqual(
            calendarTodoDrawerTargetExpandedHeight(
                contentHeight: 220,
                halfPageCapHeight: 160,
                minimumHeight: 96
            ),
            160
        )
    }

    func testTodoDrawerTargetExpandedHeightAppliesMinimumHeight() {
        XCTAssertEqual(
            calendarTodoDrawerTargetExpandedHeight(
                contentHeight: 24,
                halfPageCapHeight: 320,
                minimumHeight: 96
            ),
            96
        )
    }

    func testTodoDrawerBlockHeightUsesCompressedLinearMapping() {
        let oneHour = calendarTodoDrawerBlockHeight(
            durationMinutes: 60,
            timelineHourHeight: 60
        )
        let twoHours = calendarTodoDrawerBlockHeight(
            durationMinutes: 120,
            timelineHourHeight: 60
        )

        XCTAssertEqual(oneHour, 19.2, accuracy: 0.001)
        XCTAssertEqual(twoHours, 38.4, accuracy: 0.001)
    }

    func testTodoDrawerBlockHeightClampsMinAndMax() {
        XCTAssertEqual(
            calendarTodoDrawerBlockHeight(
                durationMinutes: 5,
                timelineHourHeight: 56
            ),
            18,
            accuracy: 0.001
        )
        XCTAssertEqual(
            calendarTodoDrawerBlockHeight(
                durationMinutes: 24 * 60,
                timelineHourHeight: 56
            ),
            88,
            accuracy: 0.001
        )
    }

    func testShouldShowCollapsedTodoMarkersRequiresDrawerSeenAndCollapsed() {
        XCTAssertFalse(
            calendarShouldShowCollapsedTodoMarkers(
                isDrawerPresented: true,
                hasViewedDrawer: true,
                hasVisibleTodos: true
            )
        )
        XCTAssertFalse(
            calendarShouldShowCollapsedTodoMarkers(
                isDrawerPresented: false,
                hasViewedDrawer: false,
                hasVisibleTodos: true
            )
        )
        XCTAssertFalse(
            calendarShouldShowCollapsedTodoMarkers(
                isDrawerPresented: false,
                hasViewedDrawer: true,
                hasVisibleTodos: false
            )
        )
        XCTAssertTrue(
            calendarShouldShowCollapsedTodoMarkers(
                isDrawerPresented: false,
                hasViewedDrawer: true,
                hasVisibleTodos: true
            )
        )
    }

    func testCollapsedTodoMarkersAggregateVisibleDatesOnly() {
        let eventA = Event(title: "A", type: "Study")
        let eventB = Event(title: "B", type: "Work")
        let eventC = Event(title: "C", type: "Life")

        let lanes = calendarCollapsedTodoMarkersForVisibleDates(
            visibleDayOffsets: [-1, 0, 1],
            plannedEventsByDayOffset: [
                -1: [eventA, eventB],
                1: [eventC],
                7: [Event(title: "Outside", type: "Study")]
            ],
            maxMarkersPerLane: 4
        )

        XCTAssertEqual(lanes.map(\.dayOffset), [-1, 0, 1])
        XCTAssertEqual(lanes[0].colorKeys, ["Study", "Work"])
        XCTAssertEqual(lanes[1].colorKeys, [])
        XCTAssertEqual(lanes[2].colorKeys, ["Life"])
    }

    func testMarkerTapTargetSelectedDayOffsetCentersTappedDateWhenPossible() {
        XCTAssertEqual(
            calendarTodoMarkerTapTargetSelectedDayOffset(
                tappedDayOffset: 3,
                dayRange: -10...10
            ),
            3
        )
        XCTAssertEqual(
            calendarTodoMarkerTapTargetSelectedDayOffset(
                tappedDayOffset: 99,
                dayRange: -10...10
            ),
            10
        )
    }

    func testTodoRevealDisplayHeightUsesInteractiveWhenCollapsed() {
        XCTAssertEqual(
            calendarTodoRevealDisplayHeight(
                isPresented: false,
                expandedHeight: 320,
                interactiveHeight: 42,
                panelDragY: -80
            ),
            42
        )
    }

    func testTodoRevealDisplayHeightTracksUpwardDragWhenExpanded() {
        XCTAssertEqual(
            calendarTodoRevealDisplayHeight(
                isPresented: true,
                expandedHeight: 320,
                interactiveHeight: 10,
                panelDragY: -60
            ),
            260
        )
        XCTAssertEqual(
            calendarTodoRevealDisplayHeight(
                isPresented: true,
                expandedHeight: 320,
                interactiveHeight: 10,
                panelDragY: 24
            ),
            320
        )
        XCTAssertEqual(
            calendarTodoRevealDisplayHeight(
                isPresented: true,
                expandedHeight: 320,
                interactiveHeight: 10,
                panelDragY: -600
            ),
            0
        )
    }

    func testShouldCloseTodoPanelWithUpwardThreshold() {
        XCTAssertFalse(
            calendarShouldCloseTodoPanel(
                translationY: -71,
                threshold: 72
            )
        )
        XCTAssertTrue(
            calendarShouldCloseTodoPanel(
                translationY: -72,
                threshold: 72
            )
        )
    }

    func testMapTimelineDropToStartDateUsesDropSlotAndDayColumn() {
        let calendar = Calendar(identifier: .gregorian)
        let reference = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 12))!
        let geometry = TimelineDropGeometry(
            timelineGlobalFrame: CGRect(x: 0, y: 0, width: 360, height: 640),
            dropContentGlobalFrame: CGRect(x: 40, y: 80, width: 300, height: 500),
            daysCount: 3,
            dayWidth: 92,
            daySpacing: 12,
            headerHeight: 16,
            hourHeight: 56,
            selectedDayOffset: 0,
            leadingDayOffset: -1
        )

        // Second column (center day), around 08:30 within content frame bounds.
        let drop = CGPoint(x: 40 + 92 + 12 + 10, y: 80 + 16 + 56 * 8.5)
        let mapped = calendarMapTimelineDropToStartDate(
            dropLocation: drop,
            geometry: geometry,
            referenceDate: reference,
            calendar: calendar,
            snapMinutes: 15
        )
        let expectedDay = calendar.date(byAdding: .day, value: 0, to: calendar.startOfDay(for: reference))!
        XCTAssertNotNil(mapped)
        XCTAssertTrue(calendar.isDate(mapped ?? .distantPast, inSameDayAs: expectedDay))
        let components = calendar.dateComponents([.hour, .minute], from: mapped ?? .distantPast)
        XCTAssertEqual(components.hour, 8)
        XCTAssertEqual(components.minute, 30)
    }

    func testTodoDurationFromCreationDragSnapsTo15Minutes() {
        XCTAssertEqual(
            calendarResolveTodoDurationFromCreationDrag(
                dragDeltaY: 28,
                hourHeight: 56
            ),
            30
        )
        XCTAssertEqual(
            calendarResolveTodoDurationFromCreationDrag(
                dragDeltaY: 2,
                hourHeight: 56
            ),
            15
        )
    }

    func testCalendarToTodoTerminalDropInsidePanelConsumesCalendarCommit() {
        let target = UUID()
        XCTAssertTrue(
            calendarShouldConsumeCalendarDropCommit(
                suppressedEventID: target,
                incomingEventID: target
            )
        )
        XCTAssertFalse(
            calendarShouldConsumeCalendarDropCommit(
                suppressedEventID: UUID(),
                incomingEventID: target
            )
        )
    }

    func testResizeHandlesOnlyVisibleInEditStyle() {
        XCTAssertFalse(calendarShouldShowResizeHandles(style: .preview))
        XCTAssertTrue(calendarShouldShowResizeHandles(style: .edit))
    }

}
