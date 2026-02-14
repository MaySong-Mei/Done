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
        XCTAssertFalse(calendarShouldUseLazyTimelineColumns(mode: .edit))
    }

    func testTimelineColumnsUseLazyInPreviewMode() {
        XCTAssertTrue(calendarShouldUseLazyTimelineColumns(mode: .preview))
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
        XCTAssertTrue(
            calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
                isMoveDragActive: true,
                isHorizontalAutoScrolling: true
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

}
