import XCTest
import SwiftUI
import UIKit
@testable import Done

final class CalendarDragLogicTests: XCTestCase {
    func testIdleTimerPolicyDisablesOnlyForActiveLandscapeFocusMode() {
        XCTAssertTrue(
            doneShouldDisableIdleTimer(
                isLandscape: true,
                landscapeFocusModeEnabled: true,
                landscapeFocusKeepAwakeEnabled: true,
                showSplash: false,
                scenePhase: .active
            )
        )
    }

    func testIdleTimerPolicyStaysEnabledDuringSplash() {
        XCTAssertFalse(
            doneShouldDisableIdleTimer(
                isLandscape: true,
                landscapeFocusModeEnabled: true,
                landscapeFocusKeepAwakeEnabled: true,
                showSplash: true,
                scenePhase: .active
            )
        )
    }

    func testIdleTimerPolicyStaysEnabledWhenFocusModeSettingIsOff() {
        XCTAssertFalse(
            doneShouldDisableIdleTimer(
                isLandscape: true,
                landscapeFocusModeEnabled: false,
                landscapeFocusKeepAwakeEnabled: true,
                showSplash: false,
                scenePhase: .active
            )
        )
    }

    func testIdleTimerPolicyStaysEnabledWhenKeepAwakeSettingIsOff() {
        XCTAssertFalse(
            doneShouldDisableIdleTimer(
                isLandscape: true,
                landscapeFocusModeEnabled: true,
                landscapeFocusKeepAwakeEnabled: false,
                showSplash: false,
                scenePhase: .active
            )
        )
    }

    func testIdleTimerPolicyStaysEnabledWhenSceneIsInactive() {
        XCTAssertFalse(
            doneShouldDisableIdleTimer(
                isLandscape: true,
                landscapeFocusModeEnabled: true,
                landscapeFocusKeepAwakeEnabled: true,
                showSplash: false,
                scenePhase: .background
            )
        )
        XCTAssertFalse(
            doneShouldDisableIdleTimer(
                isLandscape: true,
                landscapeFocusModeEnabled: true,
                landscapeFocusKeepAwakeEnabled: true,
                showSplash: false,
                scenePhase: .inactive
            )
        )
    }

    func testAdjustedRangeForDurationDeltaExtendsBy15Minutes() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 11, minute: 0))!
        let range = Event.TimeRange(start: start, end: end)

        let adjusted = calendarEventAdjustedRangeForDurationDelta(
            range: range,
            deltaMinutes: 15
        )

        XCTAssertEqual(adjusted?.start, start)
        XCTAssertEqual(adjusted?.end, end.addingTimeInterval(15 * 60))
    }

    func testAdjustedRangeForDurationDeltaClampsToMinimum15Minutes() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 20))!
        let range = Event.TimeRange(start: start, end: end)

        let adjusted = calendarEventAdjustedRangeForDurationDelta(
            range: range,
            deltaMinutes: -15
        )

        XCTAssertEqual(adjusted?.start, start)
        XCTAssertEqual(adjusted?.end, start.addingTimeInterval(15 * 60))
    }

    func testCanDecreaseDurationReturnsFalseAtMinimum15Minutes() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 15))!
        let range = Event.TimeRange(start: start, end: end)

        XCTAssertFalse(
            calendarEventCanDecreaseDuration(range: range)
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

    func testResizedRangeFromDragAllowsCrossingIntoPreviousDay() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 0, minute: 30))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 1, minute: 30))!
        let range = Event.TimeRange(start: start, end: end)

        let resized = calendarResizedRangeFromDrag(
            draggedRange: range,
            dragMode: .resizeTop,
            offsetY: -56,
            hourHeight: 56,
            calendar: calendar
        )

        XCTAssertEqual(
            resized.start,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 23, minute: 30))!
        )
        XCTAssertEqual(resized.end, end)
    }

    func testResizedRangeFromDragAllowsCrossingIntoNextDay() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 23, minute: 15))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 23, minute: 45))!
        let range = Event.TimeRange(start: start, end: end)

        let resized = calendarResizedRangeFromDrag(
            draggedRange: range,
            dragMode: .resizeBottom,
            offsetY: 56,
            hourHeight: 56,
            calendar: calendar
        )

        XCTAssertEqual(resized.start, start)
        XCTAssertEqual(
            resized.end,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 0, minute: 45))!
        )
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

    func testBoundaryExtensionAnimationDisablesDuringMoveDrag() {
        XCTAssertTrue(
            calendarShouldAnimateTimelineBoundaryExtension(
                isMoveDragActive: false,
                isCreationDragActive: false,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            calendarShouldAnimateTimelineBoundaryExtension(
                isMoveDragActive: true,
                isCreationDragActive: false,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            calendarShouldAnimateTimelineBoundaryExtension(
                isMoveDragActive: false,
                isCreationDragActive: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            calendarShouldAnimateTimelineBoundaryExtension(
                isMoveDragActive: false,
                isCreationDragActive: false,
                reduceMotion: true
            )
        )
    }

    func testCreationDragYCompensatesWhenLeadingBoundaryExtensionChanges() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        let headerHeight: CGFloat = 14
        let hourHeight: CGFloat = 56
        let originalStartY = headerHeight + 10 * hourHeight
        let originalCurrentY = headerHeight - hourHeight

        let originalStart = calendarTimelineDateFromYPosition(
            originalStartY,
            containing: anchor,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: 0,
            trailingExtendedHours: 0,
            snapMinutes: 15,
            calendar: calendar
        )
        let originalCurrent = calendarTimelineDateFromYPosition(
            originalCurrentY,
            containing: anchor,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: 0,
            trailingExtendedHours: 0,
            snapMinutes: 15,
            calendar: calendar
        )

        let adjustedStartY = calendarAdjustedCreationDragYForLeadingBoundaryExtensionChange(
            originalStartY,
            previousLeadingHours: 0,
            currentLeadingHours: 12,
            hourHeight: hourHeight
        )
        let adjustedCurrentY = calendarAdjustedCreationDragYForLeadingBoundaryExtensionChange(
            originalCurrentY,
            previousLeadingHours: 0,
            currentLeadingHours: 12,
            hourHeight: hourHeight
        )

        let adjustedStart = calendarTimelineDateFromYPosition(
            adjustedStartY,
            containing: anchor,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: 12,
            trailingExtendedHours: 0,
            snapMinutes: 15,
            calendar: calendar
        )
        let adjustedCurrent = calendarTimelineDateFromYPosition(
            adjustedCurrentY,
            containing: anchor,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: 12,
            trailingExtendedHours: 0,
            snapMinutes: 15,
            calendar: calendar
        )

        XCTAssertEqual(adjustedStart, originalStart)
        XCTAssertEqual(adjustedCurrent, originalCurrent)
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

    func testDragGestureTerminalRecoveryOnlyTriggersForActiveInteraction() {
        XCTAssertFalse(
            calendarDragGestureNeedsTerminalRecovery(
                hasActiveGesture: false,
                isDragging: false,
                hasMovedAfterLongPress: false,
                hasPromotedManipulation: false,
                dragOffset: .zero,
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: false
            )
        )
        XCTAssertTrue(
            calendarDragGestureNeedsTerminalRecovery(
                hasActiveGesture: false,
                isDragging: false,
                hasMovedAfterLongPress: true,
                hasPromotedManipulation: false,
                dragOffset: .zero,
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: false
            )
        )
        XCTAssertTrue(
            calendarDragGestureNeedsTerminalRecovery(
                hasActiveGesture: false,
                isDragging: false,
                hasMovedAfterLongPress: false,
                hasPromotedManipulation: false,
                dragOffset: DragOffset(x: 0, y: 24),
                isHorizontalEdgeDragging: false,
                isHorizontalAutoScrolling: false
            )
        )
    }

    func testCompoundInterruptParentShapeStaysEnabledAcrossDragModes() {
        XCTAssertTrue(
            calendarShouldRenderCompoundInterruptParentShape(
                isCompoundParentEvent: true,
                isInDragState: false,
                dragMode: .move
            )
        )
        XCTAssertTrue(
            calendarShouldRenderCompoundInterruptParentShape(
                isCompoundParentEvent: true,
                isInDragState: true,
                dragMode: .move
            )
        )
        XCTAssertTrue(
            calendarShouldRenderCompoundInterruptParentShape(
                isCompoundParentEvent: true,
                isInDragState: true,
                dragMode: .resizeTop
            )
        )
        XCTAssertFalse(
            calendarShouldRenderCompoundInterruptParentShape(
                isCompoundParentEvent: false,
                isInDragState: true,
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

    func testTimelineResolvedCenteredDayOffsetDefersOutOfRangeSelectionUntilRangeExpands() {
        XCTAssertNil(
            calendarTimelineResolvedCenteredDayOffset(
                requestedDayOffset: 18,
                centeredRange: -7...7
            )
        )
        XCTAssertEqual(
            calendarTimelineResolvedCenteredDayOffset(
                requestedDayOffset: 18,
                centeredRange: -30...30
            ),
            18
        )
    }

    func testTimelineResolvedCenteredDayOffsetCanClampImmediatelyWhenDeferralDisabled() {
        XCTAssertEqual(
            calendarTimelineResolvedCenteredDayOffset(
                requestedDayOffset: 18,
                centeredRange: -7...7,
                deferOutOfRangeSelection: false
            ),
            7
        )
        XCTAssertEqual(
            calendarTimelineResolvedCenteredDayOffset(
                requestedDayOffset: -2,
                centeredRange: -7...7
            ),
            -2
        )
    }

    func testExpandedDayRangeImmediatelyIncludesFarSelectedOffset() {
        XCTAssertEqual(
            calendarExpandedDayRange(
                currentRange: -30...30,
                selectedDayOffset: 90
            ),
            -30...104
        )
        XCTAssertEqual(
            calendarExpandedDayRange(
                currentRange: -30...30,
                selectedDayOffset: -90
            ),
            -104...30
        )
    }

    func testExpandedDayRangeStillAddsLookaheadWhenSelectionNearCurrentEdge() {
        XCTAssertEqual(
            calendarExpandedDayRange(
                currentRange: -30...30,
                selectedDayOffset: 25
            ),
            -30...60
        )
    }

    func testTimelineTotalVisibleHoursUse24HourBaseWindow() {
        XCTAssertEqual(
            calendarTimelineTotalVisibleHours(),
            24
        )
        XCTAssertEqual(
            calendarTimelineTotalVisibleHours(
                leadingExtendedHours: 2,
                trailingExtendedHours: 3
            ),
            29
        )
    }

    func testTimelineBoundaryExtensionHoursExpandsBeforeAndAfterDayBounds() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 22, minute: 30))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 2, minute: 15))!
        )
        let mappingState = TimelineEditMappingState(
            source: .creation,
            anchorDate: anchor,
            range: range
        )

        let extensionHours = calendarTimelineBoundaryExtensionHours(
            mappingState: mappingState,
            maxExtensionHours: 6,
            calendar: calendar
        )

        XCTAssertEqual(extensionHours.leading, 6)
        XCTAssertEqual(extensionHours.trailing, 6)
    }

    func testTimelineBoundaryExtensionDefaultCapIsTwelveHours() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 8))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 16))!
        )

        let extensionHours = calendarTimelineBoundaryExtensionHours(
            mappingState: TimelineEditMappingState(
                source: .moveDrag,
                anchorDate: anchor,
                range: range
            ),
            calendar: calendar
        )

        XCTAssertEqual(extensionHours.leading, 12)
        XCTAssertEqual(extensionHours.trailing, 12)
    }

    func testTimelineBoundaryExtensionUsesFixedTwelveHourChunksOnceBoundaryIsCrossed() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 22))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 2))!
        )

        let extensionHours = calendarTimelineBoundaryExtensionHours(
            mappingState: TimelineEditMappingState(
                source: .creation,
                anchorDate: anchor,
                range: range
            ),
            calendar: calendar
        )

        XCTAssertEqual(extensionHours.leading, 12)
        XCTAssertEqual(extensionHours.trailing, 12)
    }

    func testResolvedCreationEditMappingFallsBackToPendingDragCreatePreview() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        let pendingRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 23, minute: 15))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 1, minute: 0))!
        )
        let pendingCreate = PendingEventCreation(
            date: referenceDate,
            timeRange: pendingRange,
            source: .dragCreate,
            anchorVisibleDate: referenceDate
        )

        let mapping = calendarResolvedCreationEditMapping(
            creationPreviewByDay: [:],
            selectedDayOffset: 0,
            pendingCreate: pendingCreate,
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(mapping?.date, referenceDate)
        XCTAssertEqual(mapping?.range, pendingRange)
        XCTAssertEqual(
            calendarTimelineBoundaryExtensionHours(
                mappingState: mapping.map {
                    TimelineEditMappingState(
                        source: .creation,
                        anchorDate: $0.date,
                        range: $0.range
                    )
                },
                calendar: calendar
            ).leading,
            12
        )
    }

    func testResolvedCreationEditMappingIgnoresPendingQuickAddPreview() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        let pendingCreate = PendingEventCreation(
            date: referenceDate,
            timeRange: Event.TimeRange(
                start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 23, minute: 15))!,
                end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 1, minute: 0))!
            ),
            source: .quickAdd,
            anchorVisibleDate: referenceDate
        )

        XCTAssertNil(
            calendarResolvedCreationEditMapping(
                creationPreviewByDay: [:],
                selectedDayOffset: 0,
                pendingCreate: pendingCreate,
                referenceDate: referenceDate,
                calendar: calendar
            )
        )
    }

    func testPendingCreationCompletionNavigationFocusesNormalDragCreate() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 23, minute: 30))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 0, minute: 30))!
        )

        XCTAssertEqual(
            calendarPendingEventCreationCompletionNavigation(
                source: .dragCreate,
                anchorVisibleDate: anchor,
                timeRange: range,
                calendar: calendar
            ),
            .focusCreatedEvent
        )
    }

    func testPendingCreationCompletionNavigationStaysOnAnchorForPreviousDayExtensionRange() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 22, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 23, minute: 30))!
        )

        XCTAssertEqual(
            calendarPendingEventCreationCompletionNavigation(
                source: .dragCreate,
                anchorVisibleDate: anchor,
                timeRange: range,
                calendar: calendar
            ),
            .stayOnAnchorVisibleDate
        )
    }

    func testPendingCreationCompletionNavigationStaysOnAnchorForNextDayExtensionRange() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 1, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 2, minute: 30))!
        )

        XCTAssertEqual(
            calendarPendingEventCreationCompletionNavigation(
                source: .dragCreate,
                anchorVisibleDate: anchor,
                timeRange: range,
                calendar: calendar
            ),
            .stayOnAnchorVisibleDate
        )
    }

    func testPendingCreationCompletionNavigationIgnoresQuickAddForAdjacentDayRange() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!
        let range = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 1, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 2, minute: 30))!
        )

        XCTAssertEqual(
            calendarPendingEventCreationCompletionNavigation(
                source: .quickAdd,
                anchorVisibleDate: anchor,
                timeRange: range,
                calendar: calendar
            ),
            .focusCreatedEvent
        )
    }

    func testBoundaryExtensionMappingIgnoresFocusedState() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        let focusedRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 23, minute: 30))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 1, minute: 30))!
        )

        let mappingState = calendarResolveBoundaryExtensionMappingState(
            creation: nil,
            drag: nil
        )

        XCTAssertNil(mappingState)
        XCTAssertEqual(
            calendarTimelineBoundaryExtensionHours(
                mappingState: mappingState,
                calendar: calendar
            ).leading,
            0
        )
        XCTAssertEqual(
            calendarResolveEditMappingState(
                creation: nil,
                drag: nil,
                focused: (anchor, focusedRange)
            )?.source,
            .focused
        )
    }

    func testResolvedDragAnchorDateKeepsSourceDayDuringVerticalBoundaryResize() {
        let calendar = Calendar(identifier: .gregorian)
        let originalRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 0, minute: 30))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 1, minute: 30))!
        )

        let anchorDate = calendarResolvedDragAnchorDate(
            draggingOriginalRange: originalRange,
            dragOffset: DragOffset(x: 0, y: -56),
            dragMode: .resizeTop,
            calendar: calendar
        )

        XCTAssertEqual(
            anchorDate,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        )
    }

    func testResolvedDragAnchorDateFollowsHorizontalDayMoveWithoutUsingPreviewStart() {
        let calendar = Calendar(identifier: .gregorian)
        let originalRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 23, minute: 30))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 0, minute: 30))!
        )

        let anchorDate = calendarResolvedDragAnchorDate(
            draggingOriginalRange: originalRange,
            dragOffset: DragOffset(x: 120, y: 0),
            dragMode: .move,
            dayColumnStep: 120,
            calendar: calendar
        )

        XCTAssertEqual(
            anchorDate,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 28))!
        )
    }

    func testLeadingTimelineExtensionCompensatesVerticalScrollLikeAutoScrollUp() {
        XCTAssertEqual(
            calendarAdjustedVerticalScrollOffsetForLeadingTimelineExtension(
                currentOffsetY: 320,
                previousLeadingHours: 0,
                currentLeadingHours: 2,
                hourHeight: 56
            ),
            432
        )
    }

    func testLeadingTimelineExtensionRemovalReturnsScrollTowardNormalDayRange() {
        XCTAssertEqual(
            calendarAdjustedVerticalScrollOffsetForLeadingTimelineExtension(
                currentOffsetY: 84,
                previousLeadingHours: 2,
                currentLeadingHours: 0,
                hourHeight: 56
            ),
            0
        )
        XCTAssertEqual(
            calendarAdjustedVerticalScrollOffsetForLeadingTimelineExtension(
                currentOffsetY: 200,
                previousLeadingHours: 1,
                currentLeadingHours: 0,
                hourHeight: 56
            ),
            144
        )
    }

    func testRetainedBoundaryExtensionKeepsTriggeredLeadingSideAfterRawStateClears() {
        let currentState = TimelineBoundaryExtensionState(
            leadingHours: 12,
            trailingHours: 0,
            source: .creation
        )

        XCTAssertEqual(
            calendarRetainedTimelineBoundaryExtensionState(
                currentState: currentState,
                rawState: .none
            ),
            TimelineBoundaryExtensionState(
                leadingHours: 12,
                trailingHours: 0,
                source: nil
            )
        )
    }

    func testRetainedBoundaryExtensionLatchesTrailingSideWhileInteractionContinues() {
        let currentState = TimelineBoundaryExtensionState(
            leadingHours: 12,
            trailingHours: 0,
            source: .moveDrag
        )
        let rawState = TimelineBoundaryExtensionState(
            leadingHours: 0,
            trailingHours: 12,
            source: .moveDrag
        )

        XCTAssertEqual(
            calendarRetainedTimelineBoundaryExtensionState(
                currentState: currentState,
                rawState: rawState
            ),
            TimelineBoundaryExtensionState(
                leadingHours: 12,
                trailingHours: 12,
                source: .moveDrag
            )
        )
    }

    func testBoundaryExtensionRemovalDoesNotRestoreScrollBaseline() {
        let previousState = TimelineBoundaryExtensionState(
            leadingHours: 0,
            trailingHours: 12,
            source: nil
        )

        XCTAssertNil(
            calendarResolvedVerticalScrollOffsetForBoundaryExtensionChange(
                currentOffsetY: 612,
                previousState: previousState,
                newState: .none,
                hourHeight: 56
            )
        )
    }

    func testLeadingBoundaryExtensionRemovalDoesNotSnapScrollToSpecificTime() {
        let previousState = TimelineBoundaryExtensionState(
            leadingHours: 12,
            trailingHours: 0,
            source: nil
        )

        XCTAssertNil(
            calendarResolvedVerticalScrollOffsetForBoundaryExtensionChange(
                currentOffsetY: 432,
                previousState: previousState,
                newState: .none,
                hourHeight: 56
            )
        )
    }

    func testBoundaryExtensionChangeKeepsLeadingCompensationWhileStillExtended() {
        let previousState = TimelineBoundaryExtensionState(
            leadingHours: 12,
            trailingHours: 0,
            source: .resizeTop
        )

        XCTAssertNil(
            calendarResolvedVerticalScrollOffsetForBoundaryExtensionChange(
                currentOffsetY: 432,
                previousState: previousState,
                newState: TimelineBoundaryExtensionState(
                    leadingHours: 12,
                    trailingHours: 0,
                    source: nil
                ),
                hourHeight: 56
            )
        )
    }

    func testCreationBoundaryExtensionScrollCompensationAppliesImmediately() {
        XCTAssertTrue(
            calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: .creation)
        )
        XCTAssertFalse(
            calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: .moveDrag)
        )
        XCTAssertFalse(
            calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: .resizeTop)
        )
        XCTAssertFalse(
            calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: nil)
        )
    }

    func testBoundaryExtensionVisibilityDetectsWhenBothExtendedRegionsAreOffscreen() {
        let visibility = calendarTimelineBoundaryExtensionVisibility(
            currentOffsetY: 900,
            viewportHeight: 300,
            contentTopInset: 80,
            allDayHeight: 0,
            headerHeight: 14,
            hourHeight: 56,
            state: TimelineBoundaryExtensionState(
                leadingHours: 12,
                trailingHours: 12,
                source: nil
            )
        )

        XCTAssertFalse(visibility.leadingVisible)
        XCTAssertFalse(visibility.trailingVisible)
    }

    func testCollapsedBoundaryExtensionStateRemovesOnlyOffscreenSide() {
        let currentState = TimelineBoundaryExtensionState(
            leadingHours: 12,
            trailingHours: 12,
            source: nil
        )

        XCTAssertEqual(
            calendarCollapsedTimelineBoundaryExtensionState(
                currentState: currentState,
                leadingVisible: false,
                trailingVisible: true
            ),
            TimelineBoundaryExtensionState(
                leadingHours: 0,
                trailingHours: 12,
                source: nil
            )
        )
    }

    func testSelectedDayOffsetChangeRetainsPassiveBoundaryExtensionState() {
        XCTAssertTrue(
            calendarShouldRetainTimelineBoundaryExtensionOnSelectedDayOffsetChange(
                currentState: TimelineBoundaryExtensionState(
                    leadingHours: 12,
                    trailingHours: 12,
                    source: nil
                ),
                rawState: .none
            )
        )
    }

    func testSelectedDayOffsetChangeRetainsActiveBoundaryExtensionState() {
        XCTAssertTrue(
            calendarShouldRetainTimelineBoundaryExtensionOnSelectedDayOffsetChange(
                currentState: .none,
                rawState: TimelineBoundaryExtensionState(
                    leadingHours: 12,
                    trailingHours: 0,
                    source: .creation
                )
            )
        )
    }

    func testSelectedDayOffsetChangeClearsWhenNoBoundaryExtensionIsActive() {
        XCTAssertFalse(
            calendarShouldRetainTimelineBoundaryExtensionOnSelectedDayOffsetChange(
                currentState: .none,
                rawState: .none
            )
        )
    }

    func testResolvedHeaderDisplayDateUsesPreviousDayWhenScrollEntersLeadingExtension() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!

        let resolvedDate = calendarResolvedHeaderDisplayDate(
            selectedDayOffset: 0,
            rangeMode: .day,
            currentScrollY: 60,
            headerHeight: 20,
            hourHeight: 60,
            boundaryExtensionState: TimelineBoundaryExtensionState(
                leadingHours: 12,
                trailingHours: 0,
                source: nil
            ),
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(
            resolvedDate,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 26))!
        )
    }

    func testResolvedHeaderDisplayDateUsesNextDayWhenScrollEntersTrailingExtension() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!

        let resolvedDate = calendarResolvedHeaderDisplayDate(
            selectedDayOffset: 0,
            rangeMode: .day,
            currentScrollY: 24 * 60 + 30,
            headerHeight: 20,
            hourHeight: 60,
            boundaryExtensionState: TimelineBoundaryExtensionState(
                leadingHours: 0,
                trailingHours: 12,
                source: nil
            ),
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(
            resolvedDate,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 28))!
        )
    }

    func testResolvedHeaderDisplayDateDoesNotAdvanceIntoNextDayWithoutTrailingExtension() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!

        let resolvedDate = calendarResolvedHeaderDisplayDate(
            selectedDayOffset: 0,
            rangeMode: .day,
            currentScrollY: 30 * 60,
            headerHeight: 20,
            hourHeight: 60,
            boundaryExtensionState: .none,
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(
            resolvedDate,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        )
    }

    func testResolvedHeaderDisplayDatePrefersPreviousDayFromDragTouchInSingleDayMode() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!

        let resolvedDate = calendarResolvedHeaderDisplayDate(
            selectedDayOffset: 0,
            rangeMode: .day,
            currentScrollY: 10 * 60,
            headerHeight: 20,
            hourHeight: 60,
            boundaryExtensionState: TimelineBoundaryExtensionState(
                leadingHours: 12,
                trailingHours: 0,
                source: .moveDrag
            ),
            draggingEventID: UUID(),
            dragMode: .move,
            dragTouchPointGlobal: CGPoint(x: 150, y: 100 + 20 + 60),
            timelineFrameGlobal: CGRect(x: 0, y: 100, width: 320, height: 1600),
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(
            resolvedDate,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 26))!
        )
    }

    func testResolvedHeaderDisplayDatePrefersNextDayFromDragTouchInSingleDayMode() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!

        let resolvedDate = calendarResolvedHeaderDisplayDate(
            selectedDayOffset: 0,
            rangeMode: .day,
            currentScrollY: 10 * 60,
            headerHeight: 20,
            hourHeight: 60,
            boundaryExtensionState: TimelineBoundaryExtensionState(
                leadingHours: 0,
                trailingHours: 12,
                source: .moveDrag
            ),
            draggingEventID: UUID(),
            dragMode: .move,
            dragTouchPointGlobal: CGPoint(x: 150, y: 100 + 20 + 25 * 60),
            timelineFrameGlobal: CGRect(x: 0, y: 100, width: 320, height: 2300),
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(
            resolvedDate,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 28))!
        )
    }

    func testResolvedHeaderDisplayDateFallsBackToScrollWhenMoveDragIsInactive() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!

        let resolvedDate = calendarResolvedHeaderDisplayDate(
            selectedDayOffset: 0,
            rangeMode: .day,
            currentScrollY: 10 * 60,
            headerHeight: 20,
            hourHeight: 60,
            boundaryExtensionState: .none,
            draggingEventID: nil,
            dragMode: .move,
            dragTouchPointGlobal: CGPoint(x: 150, y: 100 + 20 + 60),
            timelineFrameGlobal: CGRect(x: 0, y: 100, width: 320, height: 1600),
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(
            resolvedDate,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        )
    }

    func testTimelineBoundaryDayHintPlacementsUseAdjacentDates() {
        let calendar = Calendar(identifier: .gregorian)
        let anchorDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!

        let placements = calendarTimelineBoundaryDayHintPlacements(
            anchorDate: anchorDate,
            headerHeight: 20,
            hourHeight: 60,
            leadingExtendedHours: 12,
            trailingExtendedHours: 12,
            calendar: calendar
        )

        XCTAssertEqual(
            placements.leading?.date,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 26))!
        )
        XCTAssertEqual(
            placements.trailing?.date,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 28))!
        )
    }

    func testTimelineBoundaryDayHintPlacementsPositionTrailingHintAfterBaseDay() {
        let calendar = Calendar(identifier: .gregorian)
        let anchorDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 9))!

        let placements = calendarTimelineBoundaryDayHintPlacements(
            anchorDate: anchorDate,
            headerHeight: 20,
            hourHeight: 60,
            leadingExtendedHours: 12,
            trailingExtendedHours: 12,
            hintInset: 8,
            calendar: calendar
        )

        XCTAssertEqual(placements.leading?.originY ?? 0, 28, accuracy: 0.001)
        XCTAssertEqual(placements.trailing?.originY ?? 0, 20 + CGFloat(36 * 60) + 8, accuracy: 0.001)
        XCTAssertEqual(placements.trailing?.isTrailingEdge, true)
    }

    func testTimelineDateFromYPositionAllowsBoundaryOvershootBeforeTimelineExtends() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!

        let resolved = calendarTimelineDateFromYPosition(
            CGFloat(14 - 56),
            containing: anchor,
            headerHeight: 14,
            hourHeight: 56,
            leadingExtendedHours: 0,
            trailingExtendedHours: 0,
            snapMinutes: 15,
            maxBoundaryExtensionHours: 6,
            calendar: calendar
        )

        XCTAssertEqual(
            resolved,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 23))!
        )
    }

    func testTimelineDateFromYPositionAllowsBoundaryOvershootAfterTimelineEnd() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!

        let resolved = calendarTimelineDateFromYPosition(
            CGFloat(14 + 26 * 56),
            containing: anchor,
            headerHeight: 14,
            hourHeight: 56,
            leadingExtendedHours: 0,
            trailingExtendedHours: 0,
            snapMinutes: 15,
            maxBoundaryExtensionHours: 6,
            calendar: calendar
        )

        XCTAssertEqual(
            resolved,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 2))!
        )
    }

    func testTimelineVisibleOccurrencesIncludeAdjacentDayEventsDuringExtension() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!

        let previousRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 22, minute: 15))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 26, hour: 23, minute: 0))!
        )
        let currentRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 10))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 11))!
        )
        let nextRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 0, minute: 30))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 1, minute: 15))!
        )

        let previousEvent = Event(title: "Previous", timeRanges: [previousRange])
        let currentEvent = Event(title: "Current", timeRanges: [currentRange])
        let nextEvent = Event(title: "Next", timeRanges: [nextRange])
        let allEvents = [previousEvent, currentEvent, nextEvent]
        let cache = CalendarLayout.occurrencesByOffset(
            allEvents,
            dayRange: -1...1,
            calendar: calendar,
            reference: anchor
        )

        let visible = CalendarLayout.timelineVisibleOccurrences(
            forDayOffset: 0,
            leadingExtendedHours: 2,
            trailingExtendedHours: 2,
            reference: anchor,
            calendar: calendar
        ) { cache[$0] ?? [] }

        XCTAssertEqual(visible.map(\.event.title), ["Previous", "Current", "Next"])
    }

    func testScrollDrivenDayOffsetRequiresInteractionOrDragMotion() {
        XCTAssertFalse(
            calendarShouldAdoptScrollDrivenDayOffset(
                isScrollInteracting: false
            )
        )
        XCTAssertTrue(
            calendarShouldAdoptScrollDrivenDayOffset(
                isScrollInteracting: true
            )
        )
        XCTAssertTrue(
            calendarShouldAdoptScrollDrivenDayOffset(
                isScrollInteracting: false,
                isHorizontalEdgeDragging: true
            )
        )
        XCTAssertTrue(
            calendarShouldAdoptScrollDrivenDayOffset(
                isScrollInteracting: false,
                isHorizontalAutoScrolling: true
            )
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
        let horizontalInset = calendarHorizontalAutoScrollEdgeInsetDefault
        let verticalInset = calendarVerticalAutoScrollEdgeInsetDefault

        let horizontalInside = calendarAutoScrollVelocity(
            locationInViewport: horizontalInset - 2,
            viewportLength: 360,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: horizontalInset,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        let horizontalOutside = calendarAutoScrollVelocity(
            locationInViewport: horizontalInset + 2,
            viewportLength: 360,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: horizontalInset,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        XCTAssertLessThan(horizontalInside, 0)
        XCTAssertEqual(horizontalOutside, 0, accuracy: 0.0001)

        let verticalInside = calendarAutoScrollVelocity(
            locationInViewport: verticalInset - 12,
            viewportLength: 700,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: verticalInset,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        let verticalOutside = calendarAutoScrollVelocity(
            locationInViewport: verticalInset + 8,
            viewportLength: 700,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: verticalInset,
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
                suppressSnap: false
            ),
            100
        )
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 32,
                dayColumnStep: 0,
                suppressSnap: false
            ),
            0
        )
    }

    func testMoveOffsetXNoSnapDuringHorizontalAutoScroll() {
        XCTAssertEqual(
            calendarMoveOffsetX(
                rawOffsetX: 66,
                dayColumnStep: 100,
                suppressSnap: true
            ),
            66
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

    func testExpressMenuAdditionalHoldDurationMatchesCurrentPressDurations() {
        XCTAssertEqual(
            calendarEventManipulationLongPressDuration,
            0.35,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarEventExpressMenuLongPressDuration,
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarEventExpressMenuAdditionalHoldDuration(),
            0.65,
            accuracy: 0.0001
        )
    }

    func testResizeHandlesAppearDuringLongPressBeforeFocusOrRelease() {
        XCTAssertTrue(
            calendarShouldShowResizeHandles(
                style: .preview,
                showsResizeHandles: false,
                isLongPressing: true
            )
        )
        XCTAssertFalse(
            calendarShouldShowResizeHandles(
                style: .preview,
                showsResizeHandles: false,
                isLongPressing: false
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

    func testRangeModeMenuMatchesSupportedTimelineModes() {
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
            draggingOriginalRange: occurrence,
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
            draggingOriginalRange: occurrence,
            dragMode: .move,
            previewRange: afterPreview,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        // When preview leaves the day, the original range is preserved to keep
        // the block's frame stable and prevent SwiftUI from tearing down the gesture.
        XCTAssertEqual(pinnedToEnd?.start, occurrence.start)
        XCTAssertEqual(pinnedToEnd?.end, occurrence.end)

        let beforePreview = Event.TimeRange(
            start: dayStart.addingTimeInterval(-2 * 3600),
            end: dayStart.addingTimeInterval(-3600)
        )
        let pinnedToStart = calendarAdjustedOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: occurrence,
            draggingOccurrenceID: "occ-1",
            draggingOriginalRange: occurrence,
            dragMode: .move,
            previewRange: beforePreview,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        XCTAssertEqual(pinnedToStart?.start, occurrence.start)
        XCTAssertEqual(pinnedToStart?.end, occurrence.end)
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
            draggingOriginalRange: occurrence,
            dragMode: .move,
            previewRange: preview,
            dayStart: dayStart,
            dayEnd: dayEnd
        )

        XCTAssertEqual(adjusted?.start, occurrence.start)
        XCTAssertEqual(adjusted?.end, occurrence.end)
    }

    func testResolvedLiveOccurrenceRangeTracksMoveAndResize() {
        let calendar = Calendar(identifier: .gregorian)
        let range = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )

        let move = calendarResolvedLiveOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: range,
            draggingOccurrenceID: "occ-1",
            draggingOriginalRange: range,
            dragOffset: DragOffset(x: 120, y: 28),
            dragMode: .move,
            hourHeight: 56,
            dayColumnStep: 120
        )
        XCTAssertEqual(
            move.start,
            calendar.date(byAdding: .day, value: 1, to: makeTimelineDate(hour: 10, minute: 30))!
        )
        XCTAssertEqual(
            move.end,
            calendar.date(byAdding: .day, value: 1, to: makeTimelineDate(hour: 11, minute: 30))!
        )

        let resizeTop = calendarResolvedLiveOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: range,
            draggingOccurrenceID: "occ-1",
            draggingOriginalRange: range,
            dragOffset: DragOffset(x: 0, y: 28),
            dragMode: .resizeTop,
            hourHeight: 56
        )
        XCTAssertEqual(resizeTop.start, makeTimelineDate(hour: 10, minute: 30))
        XCTAssertEqual(resizeTop.end, range.end)

        let resizeBottom = calendarResolvedLiveOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: range,
            draggingOccurrenceID: "occ-1",
            draggingOriginalRange: range,
            dragOffset: DragOffset(x: 0, y: 28),
            dragMode: .resizeBottom,
            hourHeight: 56
        )
        XCTAssertEqual(resizeBottom.start, range.start)
        XCTAssertEqual(resizeBottom.end, makeTimelineDate(hour: 11, minute: 30))
    }

    func testDraggedInterruptFallsBackToNormalOverlayGeometryWhileMoving() {
        XCTAssertTrue(
            calendarShouldUseEmbeddedInterruptOverlay(
                interruptIsCurrentlyEmbedded: true,
                isActiveDraggedOccurrence: false,
                dragMode: .move
            )
        )
        XCTAssertFalse(
            calendarShouldUseEmbeddedInterruptOverlay(
                interruptIsCurrentlyEmbedded: true,
                isActiveDraggedOccurrence: true,
                dragMode: .move
            )
        )
        XCTAssertTrue(
            calendarShouldUseEmbeddedInterruptOverlay(
                interruptIsCurrentlyEmbedded: true,
                isActiveDraggedOccurrence: true,
                dragMode: .resizeTop
            )
        )
        XCTAssertFalse(
            calendarShouldUseEmbeddedInterruptOverlay(
                interruptIsCurrentlyEmbedded: false,
                isActiveDraggedOccurrence: true,
                dragMode: .move
            )
        )
    }

    func testDraggedInterruptKeepsSourceFrameWhileMoving() {
        XCTAssertTrue(
            calendarShouldUseInterruptDragSourceFrame(
                isInterruptEvent: true,
                relationState: .embedded,
                isActiveDraggedOccurrence: true,
                dragMode: .move
            )
        )
        XCTAssertFalse(
            calendarShouldUseInterruptDragSourceFrame(
                isInterruptEvent: true,
                relationState: .detached,
                isActiveDraggedOccurrence: true,
                dragMode: .move
            )
        )
        XCTAssertFalse(
            calendarShouldUseInterruptDragSourceFrame(
                isInterruptEvent: false,
                relationState: .embedded,
                isActiveDraggedOccurrence: true,
                dragMode: .move
            )
        )
        XCTAssertFalse(
            calendarShouldUseInterruptDragSourceFrame(
                isInterruptEvent: true,
                relationState: .embedded,
                isActiveDraggedOccurrence: true,
                dragMode: .resizeTop
            )
        )
    }

    func testResolvedLiveOccurrenceRangeKeepsOriginalForNonDraggedOccurrence() {
        let range = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )

        let live = calendarResolvedLiveOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: range,
            draggingOccurrenceID: "occ-2",
            draggingOriginalRange: makeTimelineRange(
                startHour: 12,
                startMinute: 0,
                endHour: 13,
                endMinute: 0
            ),
            dragOffset: DragOffset(x: 0, y: 56),
            dragMode: .move,
            hourHeight: 56
        )

        XCTAssertEqual(live.start, range.start)
        XCTAssertEqual(live.end, range.end)
    }

    @objc func testLegendSlotMinutesThresholds() {
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 96), 30)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 76), 30)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 75), 60)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 56), 60)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 45), 60)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 44), 60)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 18), 60)
        XCTAssertEqual(calendarLegendSlotMinutes(forHourHeight: 36), 60)
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

    @objc func testPinchDirectionAndHourHeightScaling() {
        XCTAssertEqual(calendarPinchDirectionFromScale(scale: 1), 0)
        XCTAssertEqual(calendarPinchDirectionFromScale(scale: 0.98), 0)
        XCTAssertEqual(calendarPinchDirectionFromScale(scale: 0.95), 1)
        XCTAssertEqual(calendarPinchDirectionFromScale(scale: 1.05), -1)
        XCTAssertEqual(calendarPinchDirectionFromScale(scale: -1), 0)

        XCTAssertEqual(
            calendarTimelineHourHeightAfterPinchScale(
                initialHourHeight: 56,
                scale: 1.25
            ),
            70,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarTimelineHourHeightAfterPinchScale(
                initialHourHeight: 56,
                scale: 0.5
            ),
            calendarTimelineHourHeightMin,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarTimelineHourHeightAfterPinchScale(
                initialHourHeight: 90,
                scale: 2
            ),
            calendarTimelineHourHeightMax,
            accuracy: 0.0001
        )
    }

    @objc func testPinchBoundaryResistanceProgressAndVisualScale() {
        XCTAssertEqual(
            calendarPinchBoundaryResistanceProgress(scale: 0.9, step: -1),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarPinchBoundaryResistanceProgress(scale: 1.1, step: 1),
            0,
            accuracy: 0.0001
        )

        let inResistance = calendarPinchBoundaryResistanceProgress(scale: 1.3, step: -1)
        let outResistance = calendarPinchBoundaryResistanceProgress(scale: 0.7, step: 1)
        XCTAssertGreaterThan(inResistance, 0)
        XCTAssertGreaterThan(outResistance, 0)

        XCTAssertEqual(
            calendarPinchBoundaryResistanceProgress(scale: 2.0, step: -1),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarPinchBoundaryResistanceProgress(scale: 0.1, step: 1),
            1,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            calendarPinchBoundaryVisualScale(step: 0, resistanceProgress: 1),
            1,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            calendarPinchBoundaryVisualScale(step: 1, resistanceProgress: 1),
            1
        )
        XCTAssertGreaterThan(
            calendarPinchBoundaryVisualScale(step: -1, resistanceProgress: 1),
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
        let after = day.addingTimeInterval(26 * 3600)
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

    func testSingleDayOverlayDropsLegendHeight() {
        XCTAssertEqual(calendarTopOverlayLegendBandHeight(for: .day), 0, accuracy: 0.0001)
        XCTAssertEqual(calendarTopOverlayLegendBandHeight(for: .threeDay), 34, accuracy: 0.0001)
        XCTAssertEqual(calendarTopOverlayLegendBandHeight(for: .week), 34, accuracy: 0.0001)
    }

    func testSingleDayTopOverlayKeepsLeftCapsuleVisibleWhenStoredVisibilityIsFalse() {
        XCTAssertTrue(
            calendarTopOverlayCapsulesVisible(
                rangeMode: .day,
                storedVisibility: false
            )
        )
        XCTAssertFalse(
            calendarTopOverlayCapsulesVisible(
                rangeMode: .threeDay,
                storedVisibility: false
            )
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

    func testSingleDayTopOverlayInsetKeepsCapsuleButNoLegend() {
        XCTAssertEqual(
            calendarTopOverlayInset(
                safeAreaTop: 47,
                isCapsuleVisible: true,
                legendBandHeight: calendarTopOverlayLegendBandHeight(for: .day),
                overlayGap: 6,
                capsuleExpandedHeight: 52
            ),
            105,
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
        let monthTitle = calendarLegendTitle(
            selectedDayOffset: 0,
            rangeMode: .month,
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertFalse(dayTitle.isEmpty)
        XCTAssertFalse(threeDayTitle.isEmpty)
        XCTAssertTrue(threeDayTitle.contains("-"))
        XCTAssertTrue(weekTitle.contains("Week"))
        XCTAssertEqual(monthTitle, "2026")
        XCTAssertNotEqual(dayTitle, threeDayTitle)
    }

    func testVisibleDatesRespectCenterAnchorForRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
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
        let month = calendarVisibleDatesForRange(
            selectedDayOffset: 0,
            rangeMode: .month,
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(day.count, 1)
        XCTAssertEqual(threeDay.count, 3)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(month.count, 42)

        let threeDayCenter = threeDay[1]
        let today = calendar.startOfDay(for: referenceDate)
        let expectedCenter = calendar.date(byAdding: .day, value: 2, to: today)!
        XCTAssertTrue(calendar.isDate(threeDayCenter, inSameDayAs: expectedCenter))
        XCTAssertEqual(calendar.component(.weekday, from: month[0]), calendar.firstWeekday)
        XCTAssertEqual(calendar.component(.month, from: month[13]), 2)
    }

    func testSelectedDayOffsetShiftsByMonthWithClampingAndYearBoundaries() {
        let calendar = Calendar(identifier: .gregorian)

        let januaryReference = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 9))!
        XCTAssertEqual(
            calendarShiftSelectedDayOffsetByMonth(
                selectedDayOffset: 0,
                deltaMonths: 1,
                referenceDate: januaryReference,
                calendar: calendar
            ),
            28
        )

        let leapReference = calendar.date(from: DateComponents(year: 2024, month: 1, day: 31, hour: 9))!
        XCTAssertEqual(
            calendarShiftSelectedDayOffsetByMonth(
                selectedDayOffset: 0,
                deltaMonths: 1,
                referenceDate: leapReference,
                calendar: calendar
            ),
            29
        )

        let decemberReference = calendar.date(from: DateComponents(year: 2026, month: 12, day: 15, hour: 9))!
        let shiftedOffset = calendarShiftSelectedDayOffsetByMonth(
            selectedDayOffset: 0,
            deltaMonths: 1,
            referenceDate: decemberReference,
            calendar: calendar
        )
        let shiftedDate = calendar.date(
            byAdding: .day,
            value: shiftedOffset,
            to: calendar.startOfDay(for: decemberReference)
        )!
        XCTAssertEqual(calendar.component(.year, from: shiftedDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: shiftedDate), 1)
        XCTAssertEqual(calendar.component(.day, from: shiftedDate), 15)
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
            timeRanges: [range]
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
            timeRanges: [range],
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
            timeRanges: [range],
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

    func testEventBlockScaleStaysNeutral() {
        XCTAssertEqual(
            calendarEventBlockScale(
                isMoveDragging: true,
                isFocused: true,
                isDimmedByFocus: false
            ),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            calendarEventBlockScale(
                isMoveDragging: false,
                isFocused: true,
                isDimmedByFocus: false
            ),
            1.0,
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
            timeRanges: [firstRange]
        )
        let otherEvent = Event(
            id: otherEventID,
            title: "Other",
            timeRanges: [firstRange]
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
            calendar: calendar
        )
        XCTAssertEqual(snappedMove?.start, start.addingTimeInterval(15 * 60))
        XCTAssertEqual(snappedMove?.end, end.addingTimeInterval(15 * 60))
    }

    func testResizeHandlesVisibleForEditOrExplicitGraceState() {
        XCTAssertFalse(calendarShouldShowResizeHandles(style: .preview, showsResizeHandles: false))
        XCTAssertTrue(calendarShouldShowResizeHandles(style: .edit, showsResizeHandles: false))
        XCTAssertTrue(calendarShouldShowResizeHandles(style: .preview, showsResizeHandles: true))
    }

    func testLongPressManipulationPromotionAllowsMoveOnlyWhenCanMoveAndAlwaysAllowsResize() {
        XCTAssertTrue(
            calendarShouldPromoteLongPressToManipulation(
                dragMode: .move,
                canMove: true,
                movementExceededThreshold: true
            )
        )
        XCTAssertFalse(
            calendarShouldPromoteLongPressToManipulation(
                dragMode: .move,
                canMove: false,
                movementExceededThreshold: true
            )
        )
        XCTAssertTrue(
            calendarShouldPromoteLongPressToManipulation(
                dragMode: .resizeTop,
                canMove: false,
                movementExceededThreshold: true
            )
        )
        XCTAssertTrue(
            calendarShouldPromoteLongPressToManipulation(
                dragMode: .resizeBottom,
                canMove: false,
                movementExceededThreshold: true
            )
        )
        XCTAssertFalse(
            calendarShouldPromoteLongPressToManipulation(
                dragMode: .resizeTop,
                canMove: true,
                movementExceededThreshold: false
            )
        )
    }

    func testTypeChipAutoFocusTargetReturnsChangedSelection() {
        XCTAssertEqual(
            calendarTypeChipAutoFocusTarget(
                previousSelectedTypeTitle: "Study",
                nextSelectedTypeTitle: "Work"
            ),
            "Work"
        )
        XCTAssertEqual(
            calendarTypeChipAutoFocusTarget(
                previousSelectedTypeTitle: "",
                nextSelectedTypeTitle: "Exercise"
            ),
            "Exercise"
        )
    }

    func testTypeChipAutoFocusTargetSkipsUnchangedOrBlankSelection() {
        XCTAssertNil(
            calendarTypeChipAutoFocusTarget(
                previousSelectedTypeTitle: "Work",
                nextSelectedTypeTitle: "Work"
            )
        )
        XCTAssertNil(
            calendarTypeChipAutoFocusTarget(
                previousSelectedTypeTitle: "Work",
                nextSelectedTypeTitle: "   "
            )
        )
    }

    func testEventTimelineLiveStateBeforeStartClampsToLeadingEndpointAndKeepsRealtimeSnapshot() {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let now = makeTimelineDate(hour: 9, minute: 47)

        let resolved = calendarEventTimelineResolvedState(
            mode: .live,
            manualProgress: 0.4,
            now: now,
            range: range
        )

        XCTAssertEqual(resolved.mode, .live)
        XCTAssertEqual(resolved.displayProgress, 0, accuracy: 0.0001)
        XCTAssertEqual(resolved.snapshotDate, now)
    }

    func testEventTimelineLiveStateDuringEventTracksRealtimeProgressInline() {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let now = makeTimelineDate(hour: 10, minute: 21)

        let resolved = calendarEventTimelineResolvedState(
            mode: .live,
            manualProgress: 0,
            now: now,
            range: range
        )

        XCTAssertEqual(resolved.displayProgress, 21.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(resolved.snapshotDate, now)
    }

    func testEventTimelineLiveStateAfterEndClampsToTrailingEndpointAndKeepsRealtimeSnapshot() {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let now = makeTimelineDate(hour: 11, minute: 21)

        let resolved = calendarEventTimelineResolvedState(
            mode: .live,
            manualProgress: 0,
            now: now,
            range: range
        )

        XCTAssertEqual(resolved.mode, .live)
        XCTAssertEqual(resolved.displayProgress, 1, accuracy: 0.0001)
        XCTAssertEqual(resolved.snapshotDate, now)
    }

    func testEventTimelineManualStateUsesInlineThumbPositionSnapshot() {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)

        let resolved = calendarEventTimelineResolvedState(
            mode: .manual,
            manualProgress: 34.0 / 60.0,
            now: makeTimelineDate(hour: 11, minute: 21),
            range: range
        )

        XCTAssertEqual(resolved.mode, .manual)
        XCTAssertEqual(resolved.displayProgress, 34.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(resolved.snapshotDate, makeTimelineDate(hour: 10, minute: 34))
    }

    func testEventTimelineDragBeforeStartIntoTrackEntersManual() {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let now = makeTimelineDate(hour: 9, minute: 47)

        let resolution = calendarEventTimelineResolveDrag(
            rawProgress: 0.25,
            range: range,
            notes: [],
            now: now,
            currentMode: .live,
            wasSnappedToNote: false,
            previousSelectedMinute: -1
        )

        XCTAssertEqual(resolution.mode, .manual)
        XCTAssertEqual(resolution.progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(resolution.snapshotDate, makeTimelineDate(hour: 10, minute: 15))
        XCTAssertEqual(resolution.feedback, .selection)
    }

    func testEventTimelineDragBackToLiveResumesAutomaticTrackingWithDistinctFeedback() {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let now = makeTimelineDate(hour: 10, minute: 21)

        let resolution = calendarEventTimelineResolveDrag(
            rawProgress: 21.0 / 60.0,
            range: range,
            notes: [],
            now: now,
            currentMode: .manual,
            wasSnappedToNote: false,
            previousSelectedMinute: 5
        )

        XCTAssertEqual(resolution.mode, .live)
        XCTAssertEqual(resolution.progress, 21.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(resolution.snapshotDate, now)
        XCTAssertEqual(resolution.feedback, .resumeLive)
        XCTAssertFalse(resolution.isSnappedToNote)
    }

    func testEventTimelineAfterEndDraggingToEndpointStaysManual() {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let now = makeTimelineDate(hour: 11, minute: 21)

        let resolution = calendarEventTimelineResolveDrag(
            rawProgress: 1,
            range: range,
            notes: [],
            now: now,
            currentMode: .manual,
            wasSnappedToNote: false,
            previousSelectedMinute: 30
        )

        XCTAssertEqual(resolution.mode, .manual)
        XCTAssertEqual(resolution.progress, 1, accuracy: 0.0001)
        XCTAssertEqual(resolution.snapshotDate, makeTimelineDate(hour: 11, minute: 0))
        XCTAssertEqual(resolution.feedback, .selection)
    }

    func testEventTimelineAfterEndDraggingPastTrailingEndpointStillStaysManual() {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let now = makeTimelineDate(hour: 11, minute: 21)

        let resolution = calendarEventTimelineResolveDrag(
            rawProgress: 1.08,
            range: range,
            notes: [],
            now: now,
            currentMode: .manual,
            wasSnappedToNote: false,
            previousSelectedMinute: 45
        )

        XCTAssertEqual(resolution.mode, .manual)
        XCTAssertEqual(resolution.progress, 1, accuracy: 0.0001)
        XCTAssertEqual(resolution.snapshotDate, makeTimelineDate(hour: 11, minute: 0))
        XCTAssertEqual(resolution.feedback, .selection)
    }

    func testEventTimelineTrackNotesIncludeOutsideHistoryAndSnapClampsToEndpoints() throws {
        let range = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let outsideNote = EventLogTimelineNote(text: "Before", createdAt: makeTimelineDate(hour: 9, minute: 47), source: "test")
        let inlineNote = EventLogTimelineNote(text: "Inside", createdAt: makeTimelineDate(hour: 10, minute: 34), source: "test")
        let trailingNote = EventLogTimelineNote(text: "After", createdAt: makeTimelineDate(hour: 11, minute: 21), source: "test")
        let notes = [outsideNote, inlineNote, trailingNote]

        let trackNotes = calendarEventTimelineTrackNotes(from: notes, range: range)
        let leadingSnap = calendarEventTimelineSnapProgress(
            rawProgress: 0,
            notes: notes,
            range: range
        )
        let inlineSnap = calendarEventTimelineSnapProgress(
            rawProgress: 34.0 / 60.0,
            notes: notes,
            range: range
        )
        let trailingSnap = calendarEventTimelineSnapProgress(
            rawProgress: 1,
            notes: notes,
            range: range
        )

        XCTAssertEqual(trackNotes.map(\.text), ["Before", "Inside", "After"])
        XCTAssertEqual(try XCTUnwrap(leadingSnap), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(inlineSnap), 34.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(trailingSnap), 1, accuracy: 0.0001)
    }

    func testEventTimelineLiveProgressRecomputesWhenEventRangeChanges() {
        let now = makeTimelineDate(hour: 9, minute: 47)
        let originalRange = makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)
        let movedRange = makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)

        let original = calendarEventTimelineResolvedState(
            mode: .live,
            manualProgress: 0,
            now: now,
            range: originalRange
        )
        let moved = calendarEventTimelineResolvedState(
            mode: .live,
            manualProgress: 0,
            now: now,
            range: movedRange
        )

        XCTAssertEqual(original.displayProgress, 0, accuracy: 0.0001)
        XCTAssertEqual(moved.displayProgress, 47.0 / 60.0, accuracy: 0.0001)
    }

    func testEventTimelineManualStateAutoResumesAfterThirtySecondsOfIdleTime() {
        let lastInteractionAt = makeTimelineDate(hour: 10, minute: 20)
        let now = lastInteractionAt.addingTimeInterval(30)

        XCTAssertTrue(
            calendarEventTimelineShouldAutoResumeLive(
                mode: .manual,
                lastInteractionAt: lastInteractionAt,
                now: now
            )
        )
    }

    func testEventTimelineManualStateDoesNotAutoResumeBeforeThirtySeconds() {
        let lastInteractionAt = makeTimelineDate(hour: 10, minute: 20)
        let now = lastInteractionAt.addingTimeInterval(29)

        XCTAssertFalse(
            calendarEventTimelineShouldAutoResumeLive(
                mode: .manual,
                lastInteractionAt: lastInteractionAt,
                now: now
            )
        )
    }

    func testEventTimelineLiveStateDoesNotAutoResumeWhileAlreadyRealtime() {
        let lastInteractionAt = makeTimelineDate(hour: 10, minute: 20)
        let now = lastInteractionAt.addingTimeInterval(45)

        XCTAssertFalse(
            calendarEventTimelineShouldAutoResumeLive(
                mode: .live,
                lastInteractionAt: lastInteractionAt,
                now: now
            )
        )
    }

    func testInterruptDefaultQuickRangeUsesCurrentMinuteInsideParentRange() {
        let calendar = Calendar(identifier: .gregorian)
        let parentRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 5))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 11, minute: 0))!
        )
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 8, second: 42))!

        let quickRange = calendarInterruptDefaultQuickRange(
            now: now,
            parentRange: parentRange,
            durationMinutes: calendarInterruptDefaultDurationMinutes,
            calendar: calendar
        )

        XCTAssertEqual(quickRange.start, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 8))!)
        XCTAssertEqual(quickRange.end, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 38))!)
    }

    func testInterruptAgenticCreateRequiresSemanticInput() {
        XCTAssertFalse(
            calendarInterruptShouldUseAgenticCreate(
                isEnabled: true,
                title: "   ",
                type: "\n"
            )
        )
        XCTAssertTrue(
            calendarInterruptShouldUseAgenticCreate(
                isEnabled: true,
                title: "Interrupt",
                type: ""
            )
        )
        XCTAssertTrue(
            calendarInterruptShouldUseAgenticCreate(
                isEnabled: true,
                title: "",
                type: "Errand"
            )
        )
        XCTAssertFalse(
            calendarInterruptShouldUseAgenticCreate(
                isEnabled: false,
                title: "Interrupt",
                type: "Errand"
            )
        )
    }

    func testInterruptAgenticRawTextPreservesTitleAndExplicitTypeHint() {
        XCTAssertEqual(
            calendarInterruptAgenticRawText(
                title: "Call supplier",
                type: "Errand"
            ),
            """
            Call supplier
            type use Errand
            """
        )
        XCTAssertEqual(
            calendarInterruptAgenticRawText(
                title: "   ",
                type: "Urgent"
            ),
            """
            Interrupt
            type use Urgent
            """
        )
        XCTAssertEqual(
            calendarInterruptAgenticRawText(
                title: "Deep work",
                type: ""
            ),
            "Deep work"
        )
    }

    func testInterruptDefaultQuickRangeUsesParentTailWhenNowOutsideAndNoOccupiedRanges() {
        let calendar = Calendar(identifier: .gregorian)
        let parentRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 11, minute: 0))!
        )
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 12, minute: 0))!

        let quickRange = calendarInterruptDefaultQuickRange(
            now: now,
            parentRange: parentRange,
            durationMinutes: calendarInterruptDefaultDurationMinutes,
            calendar: calendar
        )

        XCTAssertEqual(quickRange.start, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 30))!)
        XCTAssertEqual(quickRange.end, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 11, minute: 0))!)
    }

    func testInterruptDefaultQuickRangeUsesLargestAvailableSegmentOutsideParentRange() {
        let calendar = Calendar(identifier: .gregorian)
        let parentRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 11, minute: 0))!
        )
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 12, minute: 0))!
        let occupiedRanges = [
            Event.TimeRange(
                start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 0))!,
                end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 10))!
            ),
            Event.TimeRange(
                start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 20))!,
                end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 30))!
            ),
            Event.TimeRange(
                start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 45))!,
                end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 50))!
            )
        ]

        let quickRange = calendarInterruptDefaultQuickRange(
            now: now,
            parentRange: parentRange,
            durationMinutes: 15,
            occupiedRanges: occupiedRanges,
            calendar: calendar
        )

        XCTAssertEqual(quickRange.start, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 30))!)
        XCTAssertEqual(quickRange.end, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 45))!)
    }

    func testInterruptDefaultQuickRangePrefersLaterSegmentWhenLargestFreeSpacesTie() {
        let calendar = Calendar(identifier: .gregorian)
        let parentRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 11, minute: 0))!
        )
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 12, minute: 0))!
        let occupiedRanges = [
            Event.TimeRange(
                start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 15))!,
                end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 30))!
            ),
            Event.TimeRange(
                start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 45))!,
                end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 50))!
            )
        ]

        let quickRange = calendarInterruptDefaultQuickRange(
            now: now,
            parentRange: parentRange,
            durationMinutes: 15,
            occupiedRanges: occupiedRanges,
            calendar: calendar
        )

        XCTAssertEqual(quickRange.start, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 30))!)
        XCTAssertEqual(quickRange.end, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 45))!)
    }

    func testInterruptClampedRangePinsTrailingEdgeInsideParentRange() {
        let calendar = Calendar(identifier: .gregorian)
        let parentRange = Event.TimeRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 0))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 30))!
        )
        let desiredStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 25))!

        let clamped = calendarInterruptClampedRange(
            parentRange: parentRange,
            desiredStart: desiredStart,
            durationMinutes: 15
        )

        XCTAssertEqual(clamped.start, calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10, minute: 15))!)
        XCTAssertEqual(clamped.end, parentRange.end)
    }

    func testInterruptVisualModeSelectsEmbeddedMoatAndOtherwiseFallsBackToNone() {
        XCTAssertEqual(
            calendarInterruptVisualMode(
                isInterruptEvent: false,
                relationState: nil,
                isCurrentlyEmbedded: false,
                hasParentColor: false
            ),
            .none
        )
        XCTAssertEqual(
            calendarInterruptVisualMode(
                isInterruptEvent: true,
                relationState: .embedded,
                isCurrentlyEmbedded: true,
                hasParentColor: true
            ),
            .embeddedMoat
        )
        XCTAssertEqual(
            calendarInterruptVisualMode(
                isInterruptEvent: true,
                relationState: .embedded,
                isCurrentlyEmbedded: true,
                hasParentColor: false
            ),
            .none
        )
        XCTAssertEqual(
            calendarInterruptVisualMode(
                isInterruptEvent: true,
                relationState: .detached,
                isCurrentlyEmbedded: false,
                hasParentColor: true
            ),
            .none
        )
        XCTAssertEqual(
            calendarInterruptVisualMode(
                isInterruptEvent: true,
                relationState: .orphaned,
                isCurrentlyEmbedded: false,
                hasParentColor: true
            ),
            .none
        )
    }

    func testInterruptMoatWidthUsesCurrentHorizontalAndVerticalConstants() {
        XCTAssertEqual(
            calendarInterruptMoatWidthHorizontal(
                availableWidth: 80,
                availableHeight: 32
            ),
            3
        )
        XCTAssertEqual(
            calendarInterruptMoatWidthHorizontal(
                availableWidth: 44,
                availableHeight: 32
            ),
            3
        )
        XCTAssertEqual(
            calendarInterruptMoatWidthVertical(
                availableWidth: 80,
                availableHeight: 24
            ),
            2
        )
    }

    func testInterruptOverlayGeometryLeavesSmallLeadingInsetAndFlushesTrailingEdge() {
        let regular = calendarInterruptOverlayGeometry(parentWidth: 180)
        XCTAssertEqual(regular.width, 172, accuracy: 0.001)
        XCTAssertEqual(regular.xOffset, 8, accuracy: 0.001)

        let compact = calendarInterruptOverlayGeometry(parentWidth: 70)
        XCTAssertEqual(compact.width, 62, accuracy: 0.001)
        XCTAssertEqual(compact.xOffset, 8, accuracy: 0.001)
    }

    func testInterruptChildOverlayGeometryKeepsLeadingInsetAndShortensChildWidth() {
        let regular = calendarInterruptChildOverlayGeometry(parentWidth: 180)
        XCTAssertEqual(regular.width, 172, accuracy: 0.001)
        XCTAssertEqual(regular.xOffset, 8, accuracy: 0.001)

        let compact = calendarInterruptChildOverlayGeometry(parentWidth: 70)
        XCTAssertEqual(compact.width, 62, accuracy: 0.001)
        XCTAssertEqual(compact.xOffset, 8, accuracy: 0.001)
    }

    func testInterruptCutoutGeometryKeepsConsistentGapAroundChildAndStillFlushesTrailingEdge() {
        let regular = calendarInterruptCutoutGeometry(parentWidth: 180, moatWidth: 3)
        let regularChild = calendarInterruptChildOverlayGeometry(parentWidth: 180)
        XCTAssertEqual(regular.width, 175, accuracy: 0.001)
        XCTAssertEqual(regular.xOffset, 5, accuracy: 0.001)
        XCTAssertEqual(regularChild.xOffset - regular.xOffset, 3, accuracy: 0.001)

        let compact = calendarInterruptCutoutGeometry(parentWidth: 70, moatWidth: 2)
        let compactChild = calendarInterruptChildOverlayGeometry(parentWidth: 70)
        XCTAssertEqual(compact.width, 64, accuracy: 0.001)
        XCTAssertEqual(compact.xOffset, 6, accuracy: 0.001)
        XCTAssertEqual(compactChild.xOffset - compact.xOffset, 2, accuracy: 0.001)
    }

    func testCompoundParentHitAreaExcludesTransparentCutout() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let childRange = makeTimelineRange(
            startHour: 10,
            startMinute: 15,
            endHour: 10,
            endMinute: 45
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [childRange],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 120)
        let excludedRects = geometry.cutouts.map(\.rect)

        XCTAssertEqual(excludedRects.count, 1)
        XCTAssertFalse(
            calendarExtendedHitAreaContains(
                point: CGPoint(x: excludedRects[0].midX, y: excludedRects[0].midY),
                bounds: bounds,
                verticalExtension: 0,
                excludedHitRects: excludedRects
            )
        )
        XCTAssertTrue(
            calendarExtendedHitAreaContains(
                point: CGPoint(x: 2, y: excludedRects[0].midY),
                bounds: bounds,
                verticalExtension: 0,
                excludedHitRects: excludedRects
            )
        )
        XCTAssertTrue(
            calendarExtendedHitAreaContains(
                point: CGPoint(x: 120, y: 6),
                bounds: bounds,
                verticalExtension: 0,
                excludedHitRects: excludedRects
            )
        )
    }

    func testInterruptMergedRangesClipAndMergeOverlappingChildren() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let childRanges = [
            makeTimelineRange(startHour: 9, startMinute: 50, endHour: 10, endMinute: 15),
            makeTimelineRange(startHour: 10, startMinute: 10, endHour: 10, endMinute: 25),
            makeTimelineRange(startHour: 10, startMinute: 40, endHour: 11, endMinute: 10)
        ]

        let segments = calendarInterruptMergedRanges(
            parentRange: parentRange,
            childRanges: childRanges
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, makeTimelineDate(hour: 10, minute: 0))
        XCTAssertEqual(segments[0].end, makeTimelineDate(hour: 10, minute: 25))
        XCTAssertEqual(segments[1].start, makeTimelineDate(hour: 10, minute: 40))
        XCTAssertEqual(segments[1].end, makeTimelineDate(hour: 11, minute: 0))
    }

    func testInterruptParentCompoundGeometryForMiddleSegmentHasTopAndBottomLobes() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [
                makeTimelineRange(startHour: 10, startMinute: 20, endHour: 10, endMinute: 40)
            ],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )

        XCTAssertEqual(geometry.spineRect.width, 5, accuracy: 0.001)
        XCTAssertEqual(geometry.spineRect.height, 120, accuracy: 0.001)
        XCTAssertEqual(geometry.cutouts.count, 1)
        XCTAssertEqual(geometry.cutouts[0].rect.minX, 5, accuracy: 0.001)
        XCTAssertEqual(geometry.cutouts[0].rect.width, 175, accuracy: 0.001)
        XCTAssertEqual(geometry.cutouts[0].rect.minY, 38, accuracy: 0.001)
        XCTAssertEqual(geometry.cutouts[0].rect.height, 44, accuracy: 0.001)
        XCTAssertTrue(geometry.cutouts[0].hasTopLobe)
        XCTAssertTrue(geometry.cutouts[0].hasBottomLobe)
        XCTAssertFalse(geometry.isStandaloneSpine)
        XCTAssertEqual(geometry.visibleSegments.count, 3)
        XCTAssertEqual(geometry.visibleSegments[0].width, 180, accuracy: 0.001)
        XCTAssertEqual(geometry.visibleSegments[1].width, 5, accuracy: 0.001)
        XCTAssertEqual(geometry.visibleSegments[2].width, 180, accuracy: 0.001)
    }

    func testInterruptParentCompoundGeometryForTopAttachedSegmentRemovesTopLobe() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [
                makeTimelineRange(startHour: 10, startMinute: 0, endHour: 10, endMinute: 20)
            ],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )

        XCTAssertEqual(geometry.cutouts.count, 1)
        XCTAssertEqual(geometry.cutouts[0].rect.minY, 0, accuracy: 0.001)
        XCTAssertFalse(geometry.cutouts[0].hasTopLobe)
        XCTAssertTrue(geometry.cutouts[0].hasBottomLobe)
        XCTAssertEqual(geometry.visibleSegments.count, 2)
        XCTAssertEqual(geometry.visibleSegments[0].width, 5, accuracy: 0.001)
        XCTAssertEqual(geometry.visibleSegments[1].width, 180, accuracy: 0.001)
    }

    func testInterruptParentCompoundGeometryForFullHeightSegmentBecomesStandaloneSpine() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [parentRange],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )

        XCTAssertEqual(geometry.cutouts.count, 1)
        XCTAssertFalse(geometry.cutouts[0].hasTopLobe)
        XCTAssertFalse(geometry.cutouts[0].hasBottomLobe)
        XCTAssertTrue(geometry.isStandaloneSpine)
        XCTAssertEqual(geometry.visibleSegments.count, 1)
        XCTAssertEqual(geometry.visibleSegments[0].width, 5, accuracy: 0.001)
    }

    func testInterruptParentCompoundGeometryCreatesTwoCutoutsForSeparatedInterrupts() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [
                makeTimelineRange(startHour: 10, startMinute: 10, endHour: 10, endMinute: 15),
                makeTimelineRange(startHour: 10, startMinute: 45, endHour: 10, endMinute: 50)
            ],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )

        XCTAssertEqual(geometry.cutouts.count, 2)
        XCTAssertTrue(geometry.cutouts.allSatisfy { $0.hasTopLobe })
        XCTAssertTrue(geometry.cutouts.allSatisfy { $0.hasBottomLobe })
        XCTAssertEqual(geometry.visibleSegments.count, 5)
        XCTAssertEqual(
            geometry.visibleSegments.map(\.width),
            [180, 5, 180, 5, 180]
        )
    }

    func testInterruptParentCompoundGeometryMergesExpandedCutoutsWhenTheyOverlap() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [
                makeTimelineRange(startHour: 10, startMinute: 10, endHour: 10, endMinute: 20),
                makeTimelineRange(startHour: 10, startMinute: 21, endHour: 10, endMinute: 30)
            ],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )

        XCTAssertEqual(geometry.cutouts.count, 1)
        XCTAssertTrue(geometry.cutouts[0].hasTopLobe)
        XCTAssertTrue(geometry.cutouts[0].hasBottomLobe)
        XCTAssertEqual(geometry.visibleSegments.count, 3)
        XCTAssertEqual(geometry.visibleSegments[1].width, 5, accuracy: 0.001)
    }

    func testEventTextLayoutCentersWithoutTimeInTightRect() {
        let layout = calendarEventTextLayout(
            in: CGRect(x: 0, y: 0, width: 64, height: 24),
            title: "Interrupt",
            requireTitleFit: false,
            styleShowTimeRange: true
        )

        XCTAssertEqual(layout?.titleLineLimit, 2)
        XCTAssertEqual(layout?.showsTimeRange, false)
        XCTAssertEqual(layout?.verticalCenter, true)
    }

    func testEventTextLayoutUsesTwoLinesAndTimeInLargeRect() {
        let layout = calendarEventTextLayout(
            in: CGRect(x: 0, y: 0, width: 120, height: 56),
            title: "Meeting with Linear VC",
            requireTitleFit: false,
            styleShowTimeRange: true
        )

        XCTAssertEqual(layout?.titleLineLimit, 2)
        XCTAssertEqual(layout?.showsTimeRange, true)
        XCTAssertEqual(layout?.verticalCenter, false)
    }

    func testInterruptParentTextLayoutPrefersTopLobeWhenTitleFits() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [
                makeTimelineRange(startHour: 10, startMinute: 20, endHour: 10, endMinute: 30)
            ],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )

        let layout = calendarInterruptParentTextLayout(
            geometry: geometry,
            title: "Meeting with Linear VC",
            styleShowTimeRange: true
        )

        XCTAssertLessThan(layout?.contentRect.maxY ?? 0, geometry.cutouts[0].rect.minY)
        XCTAssertEqual(layout?.titleLineLimit, 2)
        XCTAssertEqual(layout?.showsTimeRange, false)
    }

    func testInterruptParentTextLayoutHidesWhenOnlySpineRemains() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [parentRange],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )

        XCTAssertNil(
            calendarInterruptParentTextLayout(
                geometry: geometry,
                title: "Meeting with Linear VC",
                styleShowTimeRange: true
            )
        )
    }

    func testInterruptParentTextLayoutFallsBackBelowWhenTopCannotFitTitle() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [
                makeTimelineRange(startHour: 10, startMinute: 5, endHour: 10, endMinute: 20)
            ],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )

        let layout = calendarInterruptParentTextLayout(
            geometry: geometry,
            title: "Meeting with Linear VC",
            styleShowTimeRange: true
        )

        XCTAssertGreaterThan(layout?.contentRect.minY ?? 0, geometry.cutouts[0].rect.maxY)
    }

    func testEventDecodeDefaultsInterruptFieldsWhenMissing() throws {
        let original = Event(
            title: "Parent",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)]
        )
        let encoded = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "displayKind")
        json.removeValue(forKey: "interruptRelation")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Event.self, from: legacyData)

        XCTAssertEqual(decoded.displayKind, .regular)
        XCTAssertNil(decoded.interruptRelation)
    }

    func testLogRecordDecodesLegacyTimelineNotesIntoTimelineItems() throws {
        let note = EventLogTimelineNote(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            text: "legacy note",
            createdAt: makeTimelineDate(hour: 10, minute: 15),
            source: "test"
        )
        let record = CalendarEventLogRecord(
            id: CalendarOccurrenceKey(
                eventID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                baseSeriesEventID: nil,
                occurrenceDate: makeTimelineDate(hour: 0, minute: 0),
                kind: .singleEvent
            ),
            eventID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            baseSeriesEventID: nil,
            occurrenceDate: makeTimelineDate(hour: 0, minute: 0)
        )

        let encoded = try JSONEncoder().encode(record)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedNote = try JSONEncoder().encode([note])
        json["timelineNotes"] = try JSONSerialization.jsonObject(with: encodedNote)
        json.removeValue(forKey: "timelineItems")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(CalendarEventLogRecord.self, from: legacyData)

        XCTAssertEqual(decoded.timelineItems.count, 1)
        XCTAssertEqual(decoded.timelineItems.first?.noteValue?.text, "legacy note")
    }

    @MainActor
    func testCreateInterruptTracksRelationLogAndStateTransitions() {
        let suiteName = "CalendarDragLogicTests.createInterrupt"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let store = EventStore(defaults: suite)
        let parent = Event(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Parent",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)],
            type: "Study"
        )
        store.addCalendarEvent(parent)

        let interrupt = store.createInterrupt(
            parentEvent: parent,
            occurrenceDate: makeTimelineDate(hour: 10, minute: 0),
            title: "Interrupt",
            timeRange: makeTimelineRange(startHour: 10, startMinute: 15, endHour: 10, endMinute: 30)
        )

        XCTAssertEqual(interrupt?.displayKind, .interrupt)
        XCTAssertEqual(store.findCalendarEvent(id: interrupt!.id)?.interruptRelation?.state, .embedded)
        XCTAssertEqual(
            store.logRecord(
                for: CalendarEventOccurrenceContext(
                    eventID: parent.id,
                    occurrenceDate: makeTimelineDate(hour: 10, minute: 0),
                    occurrenceID: nil,
                    isAllDay: false,
                    source: .timelineLongPress
                )
            )?.timelineItems.compactMap { $0.interruptReferenceValue }.count,
            1
        )

        var moved = interrupt!
        moved.timeRanges = [makeTimelineRange(startHour: 11, startMinute: 15, endHour: 11, endMinute: 30)]
        store.updateCalendarEvent(moved)
        XCTAssertEqual(store.findCalendarEvent(id: moved.id)?.interruptRelation?.state, .detached)

        store.deleteCalendarEvent(parent)
        XCTAssertEqual(store.findCalendarEvent(id: moved.id)?.interruptRelation?.state, .orphaned)
    }

    @MainActor
    func testCreateInterruptUsesExplicitTypeWhenProvided() {
        let suiteName = "CalendarDragLogicTests.createInterrupt.explicitType"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let store = EventStore(defaults: suite)
        let parent = Event(
            id: UUID(uuidString: "23232323-2323-2323-2323-232323232323")!,
            title: "Parent",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)],
            type: "Study"
        )
        store.addCalendarEvent(parent)

        let interrupt = store.createInterrupt(
            parentEvent: parent,
            occurrenceDate: makeTimelineDate(hour: 10, minute: 0),
            title: "Interrupt",
            type: "Errand",
            timeRange: makeTimelineRange(startHour: 10, startMinute: 15, endHour: 10, endMinute: 45)
        )

        XCTAssertEqual(interrupt?.type, "Errand")
        XCTAssertEqual(store.findCalendarEvent(id: interrupt!.id)?.type, "Errand")
    }

    @MainActor
    func testRecurringInterruptRemainsAnchoredAfterSingleOccurrenceBecomesException() {
        let suiteName = "CalendarDragLogicTests.recurringInterrupt"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let store = EventStore(defaults: suite)
        let occurrenceDate = makeTimelineDate(hour: 0, minute: 0)
        let series = Event(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: "Series",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        let interrupt = store.createInterrupt(
            parentEvent: series,
            occurrenceDate: occurrenceDate,
            title: "Interrupt",
            timeRange: makeTimelineRange(startHour: 9, startMinute: 15, endHour: 9, endMinute: 30)
        )

        store.applyRecurringEdit(
            seriesEvent: series,
            occurrenceDate: occurrenceDate,
            scope: .single
        ) { instance in
            instance.timeRanges = [self.makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 30)]
        }

        XCTAssertEqual(store.findCalendarEvent(id: interrupt!.id)?.interruptRelation?.state, .embedded)
    }

    @MainActor
    func testMultipleEmbeddedInterruptsRetainMoatVisualMode() {
        let suiteName = "CalendarDragLogicTests.multipleEmbeddedInterrupts"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let store = EventStore(defaults: suite)
        let parent = Event(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            title: "Parent",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)],
            type: "Study"
        )
        store.addCalendarEvent(parent)

        let first = store.createInterrupt(
            parentEvent: parent,
            occurrenceDate: makeTimelineDate(hour: 10, minute: 0),
            title: "Interrupt A",
            timeRange: makeTimelineRange(startHour: 10, startMinute: 10, endHour: 10, endMinute: 20)
        )
        let second = store.createInterrupt(
            parentEvent: parent,
            occurrenceDate: makeTimelineDate(hour: 10, minute: 0),
            title: "Interrupt B",
            timeRange: makeTimelineRange(startHour: 10, startMinute: 25, endHour: 10, endMinute: 35)
        )

        let storedInterrupts = [first, second].compactMap { created in
            created.flatMap { store.findCalendarEvent(id: $0.id) }
        }

        XCTAssertEqual(storedInterrupts.count, 2)
        for interrupt in storedInterrupts {
            XCTAssertEqual(interrupt.interruptRelation?.state, .embedded)
            XCTAssertEqual(
                calendarInterruptVisualMode(
                    isInterruptEvent: interrupt.isInterrupt,
                    relationState: interrupt.interruptRelation?.state,
                    isCurrentlyEmbedded: interrupt.interruptRelation?.state == .embedded,
                    hasParentColor: true
                ),
                .embeddedMoat
            )
        }
    }

    func testRelationAwareOverlapLayoutSharesSlotBetweenParentAndInterrupt() {
        let date = makeTimelineDate(hour: 0, minute: 0)
        let parent = Event(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            title: "Parent",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)],
            type: "Study"
        )
        let interrupt = Event(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            title: "Interrupt",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 10, endMinute: 30)],
            type: "Study",
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: parent.id,
                occurrenceDate: date
            )
        )
        let other = Event(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            title: "Other",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 10, endMinute: 30)],
            type: "Work"
        )
        let occurrences = [
            CalendarLayout.EventOccurrence(id: "parent", event: parent, range: parent.primaryTimeRange!),
            CalendarLayout.EventOccurrence(id: "interrupt", event: interrupt, range: interrupt.primaryTimeRange!),
            CalendarLayout.EventOccurrence(id: "other", event: other, range: other.primaryTimeRange!)
        ]

        let layout = CalendarLayout.overlapLayout(for: occurrences, on: date)
        let parentX = layout["parent"]?.xOffsetFraction ?? -1
        let parentWidth = layout["parent"]?.widthFraction ?? -1
        let interruptX = layout["interrupt"]?.xOffsetFraction ?? -1
        let interruptWidth = layout["interrupt"]?.widthFraction ?? -1
        let otherX = layout["other"]?.xOffsetFraction ?? -1
        let otherWidth = layout["other"]?.widthFraction ?? -1

        XCTAssertNotEqual(parentX, -1)
        XCTAssertNotEqual(interruptX, -1)
        XCTAssertNotEqual(otherX, -1)
        XCTAssertEqual(parentX, interruptX, accuracy: 0.0001)
        XCTAssertEqual(parentWidth, interruptWidth, accuracy: 0.0001)
        XCTAssertEqual(parentWidth, 0.5, accuracy: 0.0001)
        XCTAssertEqual(otherWidth, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(abs(parentX - otherX), 0.0001)
    }

    func testEmbeddedInterruptDoesNotSplitParentIntoHalfWidthWithoutOtherOverlap() {
        let date = makeTimelineDate(hour: 0, minute: 0)
        let parent = Event(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            title: "Parent",
            timeRanges: [makeTimelineRange(startHour: 14, startMinute: 0, endHour: 15, endMinute: 0)],
            type: "Study"
        )
        let interrupt = Event(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            title: "Interrupt",
            timeRanges: [makeTimelineRange(startHour: 14, startMinute: 10, endHour: 14, endMinute: 40)],
            type: "Study",
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: parent.id,
                occurrenceDate: date
            )
        )
        let occurrences = [
            CalendarLayout.EventOccurrence(id: "parent", event: parent, range: parent.primaryTimeRange!),
            CalendarLayout.EventOccurrence(id: "interrupt", event: interrupt, range: interrupt.primaryTimeRange!)
        ]

        let layout = CalendarLayout.overlapLayout(for: occurrences, on: date)
        let parentX = layout["parent"]?.xOffsetFraction ?? -1
        let interruptX = layout["interrupt"]?.xOffsetFraction ?? -1
        let parentWidth = layout["parent"]?.widthFraction ?? -1
        let interruptWidth = layout["interrupt"]?.widthFraction ?? -1
        XCTAssertEqual(parentX, 0, accuracy: 0.0001)
        XCTAssertEqual(interruptX, 0, accuracy: 0.0001)
        XCTAssertEqual(parentWidth, 1, accuracy: 0.0001)
        XCTAssertEqual(interruptWidth, 1, accuracy: 0.0001)
    }

    // MARK: - Drag Mode Detection (calendarResolveDragMode)

    // Helper: event width 300, handle = min(300*0.4, 36) = 36, center = 150
    // Handle hit zone: 150 - 18 - 12 = 120  to  150 + 18 + 12 = 180
    private let w: CGFloat = 300
    private let handleCenter: CGFloat = 150 // w / 2

    /// Touch on handle at top edge → resizeTop; at bottom → resizeBottom.
    func testDragModeResizeOnHandle() {
        let h: CGFloat = 56 // 1 hr, threshold = 10
        // Top edge, on handle center
        XCTAssertEqual(calendarResolveDragMode(locationX: handleCenter, locationY: 0, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .resizeTop)
        XCTAssertEqual(calendarResolveDragMode(locationX: handleCenter, locationY: 9, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .resizeTop)
        // Bottom edge, on handle center
        XCTAssertEqual(calendarResolveDragMode(locationX: handleCenter, locationY: 47, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .resizeBottom)
        XCTAssertEqual(calendarResolveDragMode(locationX: handleCenter, locationY: 56, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .resizeBottom)
    }

    /// Touch at top/bottom edge but AWAY from handle → move (not resize).
    func testDragModeMoveWhenOffHandle() {
        let h: CGFloat = 56
        // Top edge, far left (x=10, outside handle hit zone 120-180)
        XCTAssertEqual(calendarResolveDragMode(locationX: 10, locationY: 0, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .move)
        // Top edge, far right
        XCTAssertEqual(calendarResolveDragMode(locationX: 280, locationY: 0, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .move)
        // Bottom edge, far left
        XCTAssertEqual(calendarResolveDragMode(locationX: 10, locationY: 55, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .move)
    }

    /// Middle of event is always move regardless of x position.
    func testDragModeMiddleAlwaysMove() {
        let h: CGFloat = 56
        XCTAssertEqual(calendarResolveDragMode(locationX: handleCenter, locationY: 28, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .move)
        XCTAssertEqual(calendarResolveDragMode(locationX: 10, locationY: 28, viewWidth: w, viewHeight: h, edgeThreshold: 10, canResizeTop: true, canResizeBottom: true), .move)
    }

    /// Short event (30 min) on handle → resize works.
    /// When canResize is false, edge + handle → still move.
    func testDragModeResizeDisabled() {
        XCTAssertEqual(calendarResolveDragMode(locationX: handleCenter, locationY: 0, viewWidth: w, viewHeight: 56, edgeThreshold: 10, canResizeTop: false, canResizeBottom: true), .move)
        XCTAssertEqual(calendarResolveDragMode(locationX: handleCenter, locationY: 55, viewWidth: w, viewHeight: 56, edgeThreshold: 10, canResizeTop: true, canResizeBottom: false), .move)
    }

    func testCompoundBottomResizeHandleUsesVisibleSpine() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let childRange = makeTimelineRange(
            startHour: 10,
            startMinute: 30,
            endHour: 11,
            endMinute: 0
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [childRange],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )
        let placement = calendarResizeHandlePlacement(
            viewWidth: 180,
            compoundGeometry: geometry,
            edge: .bottom
        )

        XCTAssertEqual(geometry.visibleSegments.last?.width ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(placement.centerX, 2.5, accuracy: 0.001)
        XCTAssertEqual(placement.width, 4, accuracy: 0.001)
        XCTAssertEqual(
            calendarResolveDragMode(
                locationX: placement.centerX,
                locationY: 119,
                viewWidth: 180,
                viewHeight: 120,
                edgeThreshold: 10,
                canResizeTop: true,
                canResizeBottom: true,
                bottomHandlePlacement: placement
            ),
            .resizeBottom
        )
        XCTAssertEqual(
            calendarResolveDragMode(
                locationX: 90,
                locationY: 119,
                viewWidth: 180,
                viewHeight: 120,
                edgeThreshold: 10,
                canResizeTop: true,
                canResizeBottom: true,
                bottomHandlePlacement: placement
            ),
            .move
        )
    }

    func testCompoundTopResizeHandleUsesVisibleSpine() {
        let parentRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 11,
            endMinute: 0
        )
        let childRange = makeTimelineRange(
            startHour: 10,
            startMinute: 0,
            endHour: 10,
            endMinute: 30
        )
        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange,
            childRanges: [childRange],
            parentWidth: 180,
            parentHeight: 120,
            horizontalGap: 3,
            verticalGap: 2
        )
        let placement = calendarResizeHandlePlacement(
            viewWidth: 180,
            compoundGeometry: geometry,
            edge: .top
        )

        XCTAssertEqual(geometry.visibleSegments.first?.width ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(placement.centerX, 2.5, accuracy: 0.001)
        XCTAssertEqual(
            calendarResolveDragMode(
                locationX: placement.centerX,
                locationY: 0,
                viewWidth: 180,
                viewHeight: 120,
                edgeThreshold: 10,
                canResizeTop: true,
                canResizeBottom: true,
                topHandlePlacement: placement
            ),
            .resizeTop
        )
    }

    func testSearchResultsIncludeEventFieldsAndOccurrenceLogMatches() {
        let occurrenceDate = makeSearchDate(2026, 3, 14, 9, 0)
        let event = makeSearchEvent(
            title: "Focus Block",
            note: "Parser cleanup notes",
            occurrenceDate: occurrenceDate
        )
        let record = makeSearchLogRecord(
            event: event,
            occurrenceDate: occurrenceDate,
            summary: "Parser summary",
            note: "Parser insights",
            timelineNotes: [
                EventLogTimelineNote(
                    text: "Timeline parser checkpoint",
                    createdAt: occurrenceDate.addingTimeInterval(300),
                    source: "manual"
                )
            ]
        )

        let results = calendarSearchResults(
            query: "parser",
            events: [event],
            logRecords: [record],
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].eventMatches.map(\.source), [.eventNote])
        XCTAssertEqual(
            results[0].occurrenceMatches.first?.sources,
            [.timelineNote, .logNote, .logSummary]
        )
    }

    func testSearchResultsAggregateMultipleRecurringOccurrencesIntoSingleCard() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstDay = makeSearchDate(2026, 4, 2, 8, 0)
        let secondDay = makeSearchDate(2026, 4, 3, 8, 0)
        let event = makeSearchEvent(
            title: "Daily Review",
            occurrenceDate: firstDay,
            repeatUnit: .day
        )
        let firstRecord = makeSearchLogRecord(
            event: event,
            occurrenceDate: firstDay,
            note: "review note alpha"
        )
        let secondRecord = makeSearchLogRecord(
            event: event,
            occurrenceDate: secondDay,
            note: "review note alpha"
        )

        let results = calendarSearchResults(
            query: "alpha",
            events: [event],
            logRecords: [firstRecord, secondRecord],
            calendar: calendar
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].occurrenceMatches.count, 2)
        XCTAssertEqual(results[0].occurrenceMatches[0].occurrenceDate, calendar.startOfDay(for: secondDay))
        XCTAssertEqual(results[0].occurrenceMatches[1].occurrenceDate, calendar.startOfDay(for: firstDay))

        let context = results[0].occurrenceMatches[0].context(for: event, calendar: calendar)
        let expectedRange = try XCTUnwrap(
            calendarOccurrenceDisplayRange(event: event, occurrenceDate: secondDay, calendar: calendar)
        )
        XCTAssertEqual(context.occurrenceDate, calendar.startOfDay(for: secondDay))
        XCTAssertEqual(
            context.occurrenceID,
            calendarOccurrenceIDForRange(
                event: event,
                range: expectedRange,
                occurrenceDate: secondDay,
                calendar: calendar
            )
        )
    }

    func testSearchResultsSortOccurrenceHitsAheadOfEventOnlyHits() {
        let eventOnly = makeSearchEvent(
            title: "Plan",
            note: "needle in event note",
            occurrenceDate: makeSearchDate(2026, 5, 1, 9, 0)
        )
        let logEvent = makeSearchEvent(
            title: "Retro",
            occurrenceDate: makeSearchDate(2026, 4, 30, 11, 0)
        )
        let logRecord = makeSearchLogRecord(
            event: logEvent,
            occurrenceDate: makeSearchDate(2026, 4, 30, 11, 0),
            note: "needle in log note"
        )

        let results = calendarSearchResults(
            query: "needle",
            events: [eventOnly, logEvent],
            logRecords: [logRecord],
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(results.map(\.event.id), [logEvent.id, eventOnly.id])
    }

    func testSearchResultsIgnoreOrphanLogRecords() {
        let orphanEventID = UUID()
        let orphanDate = makeSearchDate(2026, 6, 1, 0, 0)
        let record = CalendarEventLogRecord(
            id: CalendarOccurrenceKey(
                eventID: orphanEventID,
                baseSeriesEventID: nil,
                occurrenceDate: orphanDate,
                kind: .singleEvent
            ),
            eventID: orphanEventID,
            baseSeriesEventID: nil,
            occurrenceDate: orphanDate,
            note: "ghost note"
        )

        let results = calendarSearchResults(
            query: "ghost",
            events: [],
            logRecords: [record],
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testSearchResultsIncludeLegacyFeedbackNotes() {
        let occurrenceDate = makeSearchDate(2026, 7, 8, 14, 0)
        let event = makeSearchEvent(
            title: "Legacy Review",
            occurrenceDate: occurrenceDate
        )
        let feedback = makeSearchFeedbackRecord(
            event: event,
            occurrenceDate: occurrenceDate,
            selfNote: "legacy needle note",
            logs: [
                CalendarEventLogEntry(
                    text: "timeline legacy needle",
                    createdAt: occurrenceDate.addingTimeInterval(120),
                    source: "legacy"
                )
            ]
        )

        let results = calendarSearchResults(
            query: "needle",
            events: [event],
            logRecords: [],
            feedbackRecords: [feedback],
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].occurrenceMatches.count, 1)
        XCTAssertEqual(
            results[0].occurrenceMatches[0].sources,
            [.timelineNote, .logNote]
        )
    }

    private func makeSearchDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private func makeSearchEvent(
        title: String,
        note: String = "",
        occurrenceDate: Date,
        repeatUnit: Event.RepeatUnit = .none
    ) -> Event {
        Event(
            title: title,
            note: note,
            timeRanges: [
                Event.TimeRange(
                    start: occurrenceDate,
                    end: occurrenceDate.addingTimeInterval(3600)
                )
            ],
            repeatUnit: repeatUnit,
            tags: ["focus"],
            type: "Work"
        )
    }

    private func makeSearchLogRecord(
        event: Event,
        occurrenceDate: Date,
        summary: String = "",
        note: String = "",
        timelineNotes: [EventLogTimelineNote] = []
    ) -> CalendarEventLogRecord {
        let calendar = Calendar(identifier: .gregorian)
        let key = CalendarOccurrenceKey.make(
            for: event,
            occurrenceDate: occurrenceDate,
            calendar: calendar
        )

        return CalendarEventLogRecord(
            id: key,
            eventID: key.eventID,
            baseSeriesEventID: key.baseSeriesEventID,
            occurrenceDate: calendar.startOfDay(for: occurrenceDate),
            summary: summary,
            note: note,
            timelineItems: timelineNotes.map(EventLogTimelineItem.note)
        )
    }

    private func makeSearchFeedbackRecord(
        event: Event,
        occurrenceDate: Date,
        selfNote: String,
        logs: [CalendarEventLogEntry]
    ) -> CalendarEventFeedbackRecord {
        let calendar = Calendar(identifier: .gregorian)
        let key = CalendarOccurrenceKey.make(
            for: event,
            occurrenceDate: occurrenceDate,
            calendar: calendar
        )

        return CalendarEventFeedbackRecord(
            id: key,
            eventID: key.eventID,
            baseSeriesEventID: key.baseSeriesEventID,
            occurrenceDate: calendar.startOfDay(for: occurrenceDate),
            selfNote: selfNote,
            logs: logs
        )
    }

    private func makeTimelineDate(hour: Int, minute: Int) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 3, day: 14, hour: hour, minute: minute)
        )!
    }

    private func makeTimelineRange(
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int
    ) -> Event.TimeRange {
        Event.TimeRange(
            start: makeTimelineDate(hour: startHour, minute: startMinute),
            end: makeTimelineDate(hour: endHour, minute: endMinute)
        )
    }

}

final class CalendarEventDetailGestureTests: XCTestCase {
    func testNativeInteractivePopGestureEnabledForPushedDetail() {
        XCTAssertTrue(
            calendarEventShouldEnableNativeInteractivePopGesture(
                viewControllerCount: 2
            )
        )
        XCTAssertTrue(
            calendarEventShouldEnableNativeInteractivePopGesture(
                viewControllerCount: 4
            )
        )
    }

    func testNativeInteractivePopGestureDisabledAtRoot() {
        XCTAssertFalse(
            calendarEventShouldEnableNativeInteractivePopGesture(
                viewControllerCount: 1
            )
        )
        XCTAssertFalse(
            calendarEventShouldEnableNativeInteractivePopGesture(
                viewControllerCount: 0
            )
        )
    }
}
