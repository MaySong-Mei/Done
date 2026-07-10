//
//  CalendarPageHandlerHelpersTests.swift
//  DoneTests
//
//  Unit tests for the pure helpers extracted from `CalendarPageView.swift`
//  per §4 + §5 of `Docs/calendar-page-state-map.md` (v3).
//
//  These tests cover the three "Pure XCTest" rows from §5's test matrix
//  (predicate tests on §4b + §4c) plus coverage of `computeAbandonedFadeCurves`
//  (§4a) — nil-rawState early returns, leading-only / trailing-only fade
//  output, and the multiply-complement combine identity.
//
//  Two §5 rows (`testDragAcrossMidnightTriggersBoundaryExtension`,
//  `testMidnightShiftFiresAfterDragEnd`) are explicit dogfood gates per §5a
//  and live outside this file.
//

import XCTest
import CoreGraphics
@testable import Done

final class CalendarPageHandlerHelpersTests: XCTestCase {

    // MARK: - Fixtures

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    private func makeResizeGrace() -> CalendarResizeGraceState {
        CalendarResizeGraceState(
            eventID: UUID(),
            occurrenceID: nil,
            startedAt: Date(),
            deadline: Date().addingTimeInterval(0.6),
            fadeStartAt: Date(),
            handleOpacity: 1,
            trigger: .longPressRelease
        )
    }

    private func makeExtensionState(
        leadingHours: Int,
        trailingHours: Int,
        source: TimelineEditMappingSource? = nil
    ) -> TimelineBoundaryExtensionState {
        TimelineBoundaryExtensionState(
            leadingHours: leadingHours,
            trailingHours: trailingHours,
            source: source,
            anchorDayOffset: nil
        )
    }

    // MARK: - §5: testRangeModeChangeClearsBoundaryExtension (§4c)

    func testBoundaryExtensionClearedWhenLeavingDayWithOpenExtension() {
        let open = makeExtensionState(leadingHours: 2, trailingHours: 0)
        XCTAssertTrue(
            boundaryExtensionShouldClearOnRangeModeChange(
                newMode: .threeDay,
                currentExtensionState: open
            )
        )
    }

    func testBoundaryExtensionNotClearedWhenAlreadyClosedEvenInNonDayMode() {
        XCTAssertFalse(
            boundaryExtensionShouldClearOnRangeModeChange(
                newMode: .week,
                currentExtensionState: .none
            )
        )
    }

    func testBoundaryExtensionNotClearedWhenStayingInDayMode() {
        let open = makeExtensionState(leadingHours: 0, trailingHours: 3)
        XCTAssertFalse(
            boundaryExtensionShouldClearOnRangeModeChange(
                newMode: .day,
                currentExtensionState: open
            )
        )
    }

    func testBoundaryExtensionClearTriggeredAcrossAllNonDayModes() {
        let open = makeExtensionState(leadingHours: 1, trailingHours: 0)
        for mode in [RangeMode.threeDay, .week, .month, .stream] {
            XCTAssertTrue(
                boundaryExtensionShouldClearOnRangeModeChange(
                    newMode: mode,
                    currentExtensionState: open
                ),
                "Expected predicate to require a clear when leaving .day for \(mode)"
            )
        }
    }

    // MARK: - §5: testMidnightShiftBlockedDuringResizeGrace (§4b)

    func testMidnightShiftBlockedDuringResizeGrace() {
        XCTAssertFalse(
            shouldAllowMidnightShift(
                draggingEventID: nil,
                resizeGrace: makeResizeGrace()
            )
        )
    }

    // MARK: - §4b: additional coverage

    func testMidnightShiftAllowedWhenAllGatesAreClear() {
        XCTAssertTrue(
            shouldAllowMidnightShift(
                draggingEventID: nil,
                resizeGrace: nil
            )
        )
    }

    func testMidnightShiftBlockedDuringActiveDrag() {
        XCTAssertFalse(
            shouldAllowMidnightShift(
                draggingEventID: UUID(),
                resizeGrace: nil
            )
        )
    }

    func testMidnightShiftBlockedWhenBothGatesAreActive() {
        XCTAssertFalse(
            shouldAllowMidnightShift(
                draggingEventID: UUID(),
                resizeGrace: makeResizeGrace()
            )
        )
    }

    // MARK: - §4a: computeAbandonedFadeCurves

    /// Baseline fixture: a drag is active (`raw.source != nil`), the user has
    /// pulled the intent back OUT of the trigger zone (`raw.hasAnyExtension =
    /// false`), but the band stays applied (`applied.hasAnyExtension`). This
    /// is the scenario the helper exists for.
    private func makeBaselineInputs(
        leading: Int = 4,
        trailing: Int = 0,
        dragOffsetY: CGFloat = 0,
        scrollY: CGFloat = 0
    ) -> AbandonedFadeInputs {
        let originalStart = date(2026, 5, 1, 22, 0)
        let originalEnd = date(2026, 5, 2, 1, 0)
        return AbandonedFadeInputs(
            rawState: makeExtensionState(
                leadingHours: 0,
                trailingHours: 0,
                source: .moveDrag
            ),
            appliedState: makeExtensionState(
                leadingHours: leading,
                trailingHours: trailing,
                source: nil
            ),
            dragOriginalRange: Event.TimeRange(start: originalStart, end: originalEnd),
            dragOffsetY: dragOffsetY,
            hourHeight: 40,
            extensionOriginY: 100,
            scrollY: scrollY,
            viewportHeight: 600,
            baseVisibleHours: 24
        )
    }

    func testComputeFadeCurvesEarlyReturnsWhenAppliedStateIsNone() {
        var input = makeBaselineInputs(leading: 0, trailing: 0)
        // Override applied to truly `.none`.
        input = AbandonedFadeInputs(
            rawState: input.rawState,
            appliedState: .none,
            dragOriginalRange: input.dragOriginalRange,
            dragOffsetY: input.dragOffsetY,
            hourHeight: input.hourHeight,
            extensionOriginY: input.extensionOriginY,
            scrollY: input.scrollY,
            viewportHeight: input.viewportHeight,
            baseVisibleHours: input.baseVisibleHours
        )
        let curves = computeAbandonedFadeCurves(input)
        XCTAssertNil(curves.leading)
        XCTAssertNil(curves.trailing)
    }

    func testComputeFadeCurvesEarlyReturnsWhenRawSourceIsNil() {
        var input = makeBaselineInputs()
        input = AbandonedFadeInputs(
            rawState: .none,  // source: nil
            appliedState: input.appliedState,
            dragOriginalRange: input.dragOriginalRange,
            dragOffsetY: input.dragOffsetY,
            hourHeight: input.hourHeight,
            extensionOriginY: input.extensionOriginY,
            scrollY: input.scrollY,
            viewportHeight: input.viewportHeight,
            baseVisibleHours: input.baseVisibleHours
        )
        let curves = computeAbandonedFadeCurves(input)
        XCTAssertNil(curves.leading, "rawState.source == nil ⇒ no dissolve writes")
        XCTAssertNil(curves.trailing, "rawState.source == nil ⇒ no dissolve writes")
    }

    func testComputeFadeCurvesEarlyReturnsWhenRawStateIsItselfOpen() {
        // raw.hasAnyExtension means the drag is back IN the zone — the
        // dissolve path doesn't apply.
        let input = AbandonedFadeInputs(
            rawState: makeExtensionState(leadingHours: 2, trailingHours: 0, source: .moveDrag),
            appliedState: makeExtensionState(leadingHours: 2, trailingHours: 0),
            dragOriginalRange: Event.TimeRange(
                start: date(2026, 5, 1, 22, 0),
                end: date(2026, 5, 2, 1, 0)
            ),
            dragOffsetY: 0,
            hourHeight: 40,
            extensionOriginY: 100,
            scrollY: 0,
            viewportHeight: 600,
            baseVisibleHours: 24
        )
        let curves = computeAbandonedFadeCurves(input)
        XCTAssertNil(curves.leading)
        XCTAssertNil(curves.trailing)
    }

    func testComputeFadeCurvesEarlyReturnsWhenHourHeightIsZero() {
        let input = AbandonedFadeInputs(
            rawState: makeExtensionState(leadingHours: 0, trailingHours: 0, source: .moveDrag),
            appliedState: makeExtensionState(leadingHours: 2, trailingHours: 0),
            dragOriginalRange: Event.TimeRange(
                start: date(2026, 5, 1, 22, 0),
                end: date(2026, 5, 2, 1, 0)
            ),
            dragOffsetY: 0,
            hourHeight: 0,  // degenerate
            extensionOriginY: 100,
            scrollY: 0,
            viewportHeight: 600,
            baseVisibleHours: 24
        )
        let curves = computeAbandonedFadeCurves(input)
        XCTAssertNil(curves.leading)
        XCTAssertNil(curves.trailing)
    }

    func testComputeFadeCurvesWritesOnlyLeadingWhenLeadingOnly() {
        let input = makeBaselineInputs(leading: 4, trailing: 0)
        let curves = computeAbandonedFadeCurves(input)
        XCTAssertNotNil(curves.leading)
        XCTAssertNil(curves.trailing, "trailing == 0 ⇒ no trailing write")
    }

    func testComputeFadeCurvesWritesOnlyTrailingWhenTrailingOnly() {
        let input = makeBaselineInputs(leading: 0, trailing: 4)
        let curves = computeAbandonedFadeCurves(input)
        XCTAssertNil(curves.leading, "leading == 0 ⇒ no leading write")
        XCTAssertNotNil(curves.trailing)
    }

    func testComputeFadeCurvesWritesBothWhenBothSidesOpen() {
        let input = makeBaselineInputs(leading: 4, trailing: 4)
        let curves = computeAbandonedFadeCurves(input)
        XCTAssertNotNil(curves.leading)
        XCTAssertNotNil(curves.trailing)
    }

    /// Multiply-complement combine identity:
    ///   combine(s1, s2) = 1 - (1 - s1)(1 - s2)
    ///
    /// Exercise this through the helper:
    /// - When s2 saturates to 1 (boundary at viewport edge or past), result = 1
    ///   regardless of s1.
    /// - When both stages contribute partially, both must be < 1.
    /// Verifies the helper's stage composition matches the documented formula
    /// without exposing the nested `combineFades` symbol.
    func testCombineFadesSaturatesToOneWhenStage2Saturates() {
        // Pick scrollY so the 0:00 line sits above the viewport top by a lot —
        // that is, leading boundary span d < 0 → s2 clamps to 1.
        //   visibleTop = max(0, scrollY)
        //   d = (extensionOriginY + bandHeight) - visibleTop
        // To force d ≤ 0 we need scrollY ≥ extensionOriginY + bandHeight.
        let leading = 4
        let hh: CGFloat = 40
        let extensionOriginY: CGFloat = 100
        let bandHeight = CGFloat(leading) * hh
        let scrollY = extensionOriginY + bandHeight + 10  // d = -10 → s2 clamps to 1.

        let input = AbandonedFadeInputs(
            rawState: makeExtensionState(leadingHours: 0, trailingHours: 0, source: .moveDrag),
            appliedState: makeExtensionState(leadingHours: leading, trailingHours: 0),
            dragOriginalRange: Event.TimeRange(
                start: date(2026, 5, 1, 22, 0),
                end: date(2026, 5, 2, 1, 0)
            ),
            dragOffsetY: 0,
            hourHeight: hh,
            extensionOriginY: extensionOriginY,
            scrollY: scrollY,
            viewportHeight: 600,
            baseVisibleHours: 24
        )
        let curves = computeAbandonedFadeCurves(input)
        // Combine identity: when either stage saturates to 1, result is 1.
        XCTAssertEqual(curves.leading ?? -1, 1, accuracy: 0.0001)
    }

    func testCombineFadesProducesZeroWhenBothStagesAreZero() {
        // Stage 1 is zero when the dragged edge hasn't moved (offsetHours = 0)
        // — `liveStart - dayStart` = 22h, that's > stage1Start(4) + stage1Range(4)
        // → stage1 hits the cap of 0.6. So combine(0.6, 0) = 0.6, not 0.
        //
        // For both stages to be zero, we need an event that starts EXACTLY at
        // dayStart and no drag offset. Then distHours = 0, fingerStage1Fade
        // formula yields min(0.6, max(0, min(1, -1))) = 0.
        //
        // The helper uses `Calendar.current` (host timezone) internally for
        // `startOfDay`, so anchor `originalStart` to the host's startOfDay
        // explicitly — using a UTC date here would be off by the host's
        // UTC offset and distHours would land at 20+h instead of 0.
        let originalStart = Calendar.current.startOfDay(for: date(2026, 5, 1, 12, 0))
        let originalEnd = originalStart.addingTimeInterval(3600)
        // s2: pick scrollY so leading boundary span d == bandHeight → s2 = 0.
        // d = (extensionOriginY + bandHeight) - visibleTop = bandHeight
        // → visibleTop = extensionOriginY → scrollY = extensionOriginY.
        let leading = 4
        let hh: CGFloat = 40
        let extensionOriginY: CGFloat = 100
        let input = AbandonedFadeInputs(
            rawState: makeExtensionState(leadingHours: 0, trailingHours: 0, source: .moveDrag),
            appliedState: makeExtensionState(leadingHours: leading, trailingHours: 0),
            dragOriginalRange: Event.TimeRange(start: originalStart, end: originalEnd),
            dragOffsetY: 0,
            hourHeight: hh,
            extensionOriginY: extensionOriginY,
            scrollY: extensionOriginY,
            viewportHeight: 600,
            baseVisibleHours: 24
        )
        let curves = computeAbandonedFadeCurves(input)
        XCTAssertEqual(curves.leading ?? -1, 0, accuracy: 0.0001)
    }

    /// Verifies that when both stages produce nonzero-but-partial output,
    /// the combined result follows `1 - (1 - s1)(1 - s2)`. This pins the
    /// multiply-complement contract: result > max(s1, s2) (over-blend), and
    /// result < s1 + s2 (no double-counting).
    func testCombineFadesProducesOverBlendOfBothStages() {
        // Pick stage-1 ≈ 0.6 (the cap): an event starting late in the day
        // with no drag offset gives `liveStart - dayStart` = 22h → far past
        // the cap range → stage1 = 0.6.
        //
        // Pick stage-2 partial: 0 < d < bandHeight → 0 < s2 < 1.
        // bandHeight = 4 * 40 = 160. extensionOriginY = 100. Choose scrollY
        // so visibleTop = 100 + 80 = 180. Then d = 100 + 160 - 180 = 80,
        // s2 = 1 - 80/160 = 0.5.
        let originalStart = date(2026, 5, 1, 22, 0)
        let originalEnd = date(2026, 5, 2, 1, 0)
        let leading = 4
        let hh: CGFloat = 40
        let extensionOriginY: CGFloat = 100
        let input = AbandonedFadeInputs(
            rawState: makeExtensionState(leadingHours: 0, trailingHours: 0, source: .moveDrag),
            appliedState: makeExtensionState(leadingHours: leading, trailingHours: 0),
            dragOriginalRange: Event.TimeRange(start: originalStart, end: originalEnd),
            dragOffsetY: 0,
            hourHeight: hh,
            extensionOriginY: extensionOriginY,
            scrollY: 180,
            viewportHeight: 600,
            baseVisibleHours: 24
        )
        let curves = computeAbandonedFadeCurves(input)
        // s1 = 0.6, s2 = 0.5 ⇒ combine = 1 - 0.4 * 0.5 = 1 - 0.2 = 0.8.
        XCTAssertEqual(curves.leading ?? -1, 0.8, accuracy: 0.0001)
    }
}
