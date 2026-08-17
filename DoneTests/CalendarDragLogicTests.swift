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

    // MARK: - Focus mode orientation gate

    func testFocusOrientationMaskLocksToPortraitWhenLandscapeNotAllowed() {
        let mask = focusOrientationMask(allowsLandscape: false)
        XCTAssertEqual(mask, .portrait)
    }

    func testFocusOrientationMaskAllowsBothPortraitAndLandscapeWhenOpen() {
        let mask = focusOrientationMask(allowsLandscape: true)
        // Portrait must remain in the supported set even while focus is
        // active, otherwise UIKit force-rotates an upright device.
        XCTAssertTrue(mask.contains(.portrait))
        XCTAssertTrue(mask.contains(.landscapeLeft))
        XCTAssertTrue(mask.contains(.landscapeRight))
    }

    // MARK: - Focus mode swipe-to-dismiss

    func testFocusDismissProjectionScalesWithTallSurface() {
        // A phone in portrait: a fifth of the surface, which is well past
        // the floor, so the gate tracks the surface rather than a constant.
        XCTAssertEqual(focusDismissProjection(surfaceHeight: 900), 180, accuracy: 0.001)
        XCTAssertEqual(focusDismissProjection(surfaceHeight: 1000), 200, accuracy: 0.001)
    }

    func testFocusDismissProjectionFloorsAt120OnShortSurfaces() {
        // Landscape on a phone is short enough that 0.2 of it would be a
        // hair trigger — the floor is what the old raw-distance gate
        // demanded and it must not fall under that.
        XCTAssertEqual(focusDismissProjection(surfaceHeight: 400), 120, accuracy: 0.001)
        XCTAssertEqual(focusDismissProjection(surfaceHeight: 0), 120, accuracy: 0.001)
    }

    func testFocusDismissProjectionCrossoverIsAt600() {
        // Below 600pt the floor wins, above it the proportion does; the
        // two agree exactly at the crossover.
        XCTAssertEqual(focusDismissProjection(surfaceHeight: 600), 120, accuracy: 0.001)
        XCTAssertEqual(focusDismissProjection(surfaceHeight: 599), 120, accuracy: 0.001)
        XCTAssertEqual(focusDismissProjection(surfaceHeight: 601), 120.2, accuracy: 0.001)
    }

    func testFocusDismissProjectionNeverNegativeForNonsenseHeights() {
        XCTAssertEqual(focusDismissProjection(surfaceHeight: -1000), 120, accuracy: 0.001)
    }

    func testFocusDismissCommitsOnlyPastTheProjectedGate() {
        // Strictly greater: landing exactly on the gate is not a commit.
        XCTAssertFalse(
            focusDismissCommits(
                projectedTranslationY: 180,
                surfaceHeight: 900,
                canExitBySwipe: true
            )
        )
        XCTAssertTrue(
            focusDismissCommits(
                projectedTranslationY: 181,
                surfaceHeight: 900,
                canExitBySwipe: true
            )
        )
    }

    func testFocusDismissDoesNotCommitOnUpwardOrShortDrags() {
        XCTAssertFalse(
            focusDismissCommits(
                projectedTranslationY: -400,
                surfaceHeight: 900,
                canExitBySwipe: true
            )
        )
        XCTAssertFalse(
            focusDismissCommits(
                projectedTranslationY: 60,
                surfaceHeight: 900,
                canExitBySwipe: true
            )
        )
    }

    func testFocusDismissNeverCommitsWhileSwipeCannotEndTheSession() {
        // Rotation-driven focus: `onExit` only clears the manual flag, so
        // committing would fling the surface off-screen and strand it with
        // the overlay still mounted. No projection is big enough.
        XCTAssertFalse(
            focusDismissCommits(
                projectedTranslationY: 5000,
                surfaceHeight: 900,
                canExitBySwipe: false
            )
        )
    }

    // MARK: - Focus mode drag activation latch

    func testFocusDragDoesNotTrackBeforeActivationDistance() {
        XCTAssertFalse(
            focusDragShouldTrack(isTracking: false, translationY: 0, activationDistance: 20)
        )
        XCTAssertFalse(
            focusDragShouldTrack(isTracking: false, translationY: 20, activationDistance: 20)
        )
    }

    func testFocusDragStartsTrackingPastActivationDistance() {
        XCTAssertTrue(
            focusDragShouldTrack(isTracking: false, translationY: 21, activationDistance: 20)
        )
    }

    func testFocusDragLatchStaysTrackingWhenTheDragReverses() {
        // The point of the latch: a drag that goes 40pt down and comes back
        // to 5pt is still the same drag. Re-testing the distance here would
        // drop the surface out from under the finger on the way back up.
        XCTAssertTrue(
            focusDragShouldTrack(isTracking: true, translationY: 5, activationDistance: 20)
        )
        XCTAssertTrue(
            focusDragShouldTrack(isTracking: true, translationY: -300, activationDistance: 20)
        )
    }

    func testFocusDragNeverActivatesOnUpwardTravel() {
        // Swiping up out of a full-screen surface is not a dismissal, and
        // it must not arm one either.
        XCTAssertFalse(
            focusDragShouldTrack(isTracking: false, translationY: -100, activationDistance: 20)
        )
    }

    // MARK: - Focus mode gesture identity (stranded-latch recovery)

    func testFocusDragTreatsTheFirstTouchAfterAnEndedGestureAsNew() {
        // `onEnded` clears the record, so every ordinary touch arrives
        // with nothing latched and must be seen as a new gesture.
        XCTAssertTrue(
            focusDragIsNewGesture(latchedStart: nil, updateStart: CGPoint(x: 100, y: 300))
        )
    }

    func testFocusDragDoesNotRestartWithinTheSameGesture() {
        // `startLocation` is fixed for the life of a DragGesture. If this
        // ever read as "new" mid-drag, the latch would be cleared under
        // the finger and the surface would freeze at its far point.
        let start = CGPoint(x: 100, y: 300)
        XCTAssertFalse(focusDragIsNewGesture(latchedStart: start, updateStart: start))
    }

    func testFocusDragTreatsATouchAfterACancelledGestureAsNew() {
        // The hazard this exists for: the system cancels a gesture, so
        // `onEnded` never runs and the latch survives. The next touch —
        // which lands somewhere else — has to clear it, otherwise
        // `onEnded`'s "a tap decides nothing" guard passes for a tap and
        // an 8pt tap flicked at ~900pt/s projects past the exit gate.
        XCTAssertTrue(
            focusDragIsNewGesture(
                latchedStart: CGPoint(x: 100, y: 300),
                updateStart: CGPoint(x: 210, y: 480)
            )
        )
    }

    func testFocusDragTellsGesturesApartOnEitherAxisAlone() {
        let start = CGPoint(x: 100, y: 300)
        XCTAssertTrue(
            focusDragIsNewGesture(latchedStart: start, updateStart: CGPoint(x: 100.5, y: 300))
        )
        XCTAssertTrue(
            focusDragIsNewGesture(latchedStart: start, updateStart: CGPoint(x: 100, y: 300.5))
        )
    }

    // MARK: - Focus mode settle residual

    /// The spring the focus surface settles on. Same value as
    /// `FocusModeView.settleSpring`; the test below pins its constants so
    /// changing it there cannot silently move the handoff gate.
    private static let focusSettleSpring = Spring(duration: 0.4, bounce: 0.2)

    /// A tracked write lands on the finger, which has cleared the 20pt
    /// activation deadband — so this is the offset every "first update of
    /// a gesture" case below is decided at.
    private static let focusFirstTrackedOffset: CGFloat = 21

    func testFocusSettleSpringHasTheConstantsTheResidualEstimateAssumes() {
        // ζ = 1 - bounce = 0.8 and ω_n = 2π/duration = 15.708, so the
        // decay rate the estimate reads off the spring is ζω_n = 12.566
        // and the envelope gain is 1/√(1-ζ²) = 1.667. Every number in
        // the handoff's doc comments is derived from these two.
        let spring = Self.focusSettleSpring
        XCTAssertEqual(spring.dampingRatio, 0.8, accuracy: 0.001)
        XCTAssertEqual(spring.damping / (2 * spring.mass), 12.566, accuracy: 0.01)
    }

    func testFocusSettleResidualStartsAtTheEnvelopeGainAndDecays() {
        let spring = Self.focusSettleSpring
        // At t=0 the envelope is displacement/√(1-ζ²) — above the
        // displacement itself, because it bounds the overshoot too.
        XCTAssertEqual(
            focusSettleResidualEstimate(displacement: 300, elapsed: 0, spring: spring),
            500,
            accuracy: 0.5
        )
        // The envelope is 7.20% of the displacement at 0.25s. The true
        // residual is that times |sin(ω_d·t + φ)| — 0.1415 at this
        // instant, so 1.02%, which on a 300pt settle is the "within 3pt
        // by 0.25s" an earlier fixed 0.3s window quoted as an absolute.
        // It is a percentage, and the envelope is what bounds it whatever
        // phase the sine happens to be at.
        XCTAssertEqual(
            focusSettleResidualEstimate(displacement: 300, elapsed: 0.25, spring: spring),
            21.6,
            accuracy: 0.5
        )
        // Monotone: the true residual passes through zero every half
        // period, and a gate on it would flicker.
        var previous = CGFloat.greatestFiniteMagnitude
        for step in 0...40 {
            let residual = focusSettleResidualEstimate(
                displacement: 874,
                elapsed: Double(step) * 0.01,
                spring: spring
            )
            XCTAssertLessThan(residual, previous)
            previous = residual
        }
    }

    func testFocusSettleResidualIsProportionalToTheDisplacement() {
        let spring = Self.focusSettleSpring
        // Why a fixed time window cannot bound the jump: at the same age,
        // an iPad's `exitTravel` leaves 1.56x the residual an iPhone's
        // does, in proportion to the two long edges.
        let phone = focusSettleResidualEstimate(displacement: 874, elapsed: 0.3, spring: spring)
        let pad = focusSettleResidualEstimate(displacement: 1366, elapsed: 0.3, spring: spring)
        XCTAssertEqual(pad / phone, 1366.0 / 874.0, accuracy: 0.001)
    }

    func testFocusSettleResidualIgnoresSignAndNegativeElapsed() {
        let spring = Self.focusSettleSpring
        XCTAssertEqual(
            focusSettleResidualEstimate(displacement: -400, elapsed: 0.1, spring: spring),
            focusSettleResidualEstimate(displacement: 400, elapsed: 0.1, spring: spring)
        )
        // Clamped, so a clock that somehow reads backwards cannot inflate
        // the estimate past its t=0 value.
        XCTAssertEqual(
            focusSettleResidualEstimate(displacement: 400, elapsed: -5, spring: spring),
            focusSettleResidualEstimate(displacement: 400, elapsed: 0, spring: spring)
        )
    }

    // MARK: - Focus mode tracked-write handoff

    private func focusHandoff(
        _ motion: FocusSurfaceMotion?,
        at elapsed: CFTimeInterval,
        offset: CGFloat = CalendarDragLogicTests.focusFirstTrackedOffset
    ) -> (animate: Bool, motion: FocusSurfaceMotion?) {
        focusSurfaceHandoff(
            motion: motion,
            trackedOffset: offset,
            spring: Self.focusSettleSpring,
            visibilityMargin: 20,
            now: elapsed
        )
    }

    func testFocusHandoffWritesBareWhenTheSurfaceHasNeverMoved() {
        // The measured-good path: nothing in flight, so following the
        // finger is an unanimated write and tracks exactly.
        let handoff = focusHandoff(nil, at: 0)
        XCTAssertFalse(handoff.animate)
        XCTAssertNil(handoff.motion)
    }

    func testFocusHandoffSpringsACaughtDismissal() {
        // The defect this whole mechanism exists for. A commit puts the
        // model at `exitTravel` (874pt on the QA device) and the catch
        // settles from there while the presentation is still most of the
        // way down the screen; a bare write would snap the two together.
        // Measured at +60ms the surface sat at 247.94 with the finger at
        // ~21 — and under the old bug it went to ~21 in one frame.
        let handoff = focusHandoff(.settling(displacement: 874, recordedAt: 0), at: 0.06)
        XCTAssertTrue(handoff.animate)
        XCTAssertEqual(handoff.motion, .smoothing)
    }

    func testFocusHandoffSpringsACaughtDismissalThatTookAWhileToActivate() {
        // The 20pt activation deadband is finger travel, not time, so the
        // first tracked write can be a long way behind the catch. All
        // four catch delays QA traced (+60/+100/+150/+200ms) decide here.
        for elapsed in [0.06, 0.10, 0.15, 0.20, 0.25] {
            let handoff = focusHandoff(
                .settling(displacement: 874, recordedAt: 0),
                at: elapsed
            )
            XCTAssertTrue(handoff.animate, "874pt settle at \(elapsed)s")
        }
        // An iPad's `exitTravel` is larger, so its window is longer, in
        // proportion — which is the point: the bound is on the residual.
        XCTAssertTrue(
            focusHandoff(.settling(displacement: 1366, recordedAt: 0), at: 0.30).animate
        )
    }

    func testFocusHandoffWritesBareForAnOrdinaryReSwipe() {
        // The regression the fixed 0.3s window shipped. A swipe that does
        // not commit settles from the distance it was dragged, ~100pt;
        // lift-and-replace is 100-150ms and clearing the activation
        // deadband costs at least another frame. QA measured 61.37pt of
        // trailing lag on the 150ms case, on a gesture that should have
        // tracked exactly.
        for elapsed in [0.1167, 0.125, 0.15, 0.175, 0.20, 0.25] {
            let handoff = focusHandoff(
                .settling(displacement: 100, recordedAt: 0),
                at: elapsed
            )
            XCTAssertFalse(handoff.animate, "100pt settle re-grabbed at \(elapsed)s")
            XCTAssertNil(handoff.motion, "100pt settle re-grabbed at \(elapsed)s")
        }
    }

    func testFocusHandoffWritesBareForTheLargestReSwipeAnIPhoneAllows() {
        // A swipe that did not commit cannot have travelled past
        // `focusDismissProjection` — 174.8pt on an 874pt surface — so
        // this is the worst case the re-swipe path can present.
        XCTAssertEqual(focusDismissProjection(surfaceHeight: 874), 174.8, accuracy: 0.1)
        XCTAssertFalse(
            focusHandoff(.settling(displacement: 174.8, recordedAt: 0), at: 0.175).animate
        )
    }

    func testFocusHandoffStillSpringsAReGrabTakenBeforeTheSettleHasRun() {
        // Not a time gate in disguise: the same 100pt settle re-grabbed
        // at 75ms IS still 63pt from home, so a bare write would haul the
        // surface backwards past the finger and this must spring.
        XCTAssertTrue(
            focusHandoff(.settling(displacement: 100, recordedAt: 0), at: 0.075).animate
        )
    }

    func testFocusHandoffBoundsTheJumpItLetsThroughOnEveryScreenSize() {
        // What E3 asked for: past the window the unanimated write costs a
        // *backwards* step of at most the margin, whatever the surface is
        // — where a fixed 0.3s window let 1.24% of the displacement
        // through, which is 17pt of pop on an iPad and unbounded in
        // principle.
        let spring = Self.focusSettleSpring
        let offset = Self.focusFirstTrackedOffset
        for displacement in [174.8, 667, 874, 1366, 4000] as [CGFloat] {
            var elapsed = 0.0
            while focusHandoff(
                .settling(displacement: displacement, recordedAt: 0),
                at: elapsed
            ).animate {
                elapsed += 0.001
                XCTAssertLessThan(elapsed, 2, "window never closed for \(displacement)pt")
            }
            let residual = focusSettleResidualEstimate(
                displacement: displacement,
                elapsed: elapsed,
                spring: spring
            )
            // +1 for the 1ms search step: the envelope is falling at
            // ~515pt/s as it crosses, so one step overshoots by ~0.5pt.
            XCTAssertLessThanOrEqual(residual - offset, 20 + 1, "\(displacement)pt")
        }
    }

    func testFocusHandoffAccountsForHowFarTheFingerItselfHasTravelled() {
        // A bare write lands the surface on the finger. When the finger
        // is already past the residual there is nothing to teleport over
        // — the surface catches down, the direction it was going.
        let motion = FocusSurfaceMotion.settling(displacement: 874, recordedAt: 0)
        XCTAssertTrue(focusHandoff(motion, at: 0.25, offset: 21).animate)
        XCTAssertFalse(focusHandoff(motion, at: 0.25, offset: 300).animate)
    }

    func testFocusHandoffLatchesForTheRestOfTheGesture() {
        // Handing back to a bare write partway through a gesture would
        // only move the jump to the frame it happened on, so once a
        // gesture is being smoothed it stays smoothed — regardless of how
        // far the finger has since travelled or how long it has been.
        let handoff = focusHandoff(.smoothing, at: 99, offset: 5000)
        XCTAssertTrue(handoff.animate)
        XCTAssertEqual(handoff.motion, .smoothing)
    }

    func testFocusHandoffForgetsASettleItDecidedAgainst() {
        // Deciding "bare" clears the record, so the rest of the gesture
        // does not re-evaluate a settle that is over.
        let handoff = focusHandoff(.settling(displacement: 100, recordedAt: 0), at: 0.2)
        XCTAssertFalse(handoff.animate)
        XCTAssertNil(handoff.motion)
    }

    func testFocusHandoffWritesBareForASettleThatNeverMoved() {
        // `settleSurfaceHome` is reachable with the surface already at
        // rest; a zero displacement has no residual to hand off.
        XCTAssertFalse(
            focusHandoff(.settling(displacement: 0, recordedAt: 0), at: 0).animate
        )
    }

    // MARK: - Focus mode dropped-dismissal backstop

    func testFocusDismissRecoveryDoesNothingWithoutABackgroundRoundTrip() {
        // Control Center over a dismissal in flight passes through
        // `.inactive` and back while the animation runs perfectly well —
        // acting there would tear the overlay down mid-flight.
        XCTAssertEqual(
            focusDismissRecoveryOnForeground(
                hasPendingDismiss: true,
                canExitBySwipe: true,
                returnedFromBackground: false
            ),
            .none
        )
    }

    func testFocusDismissRecoveryDoesNothingWhenNoDismissalIsOutstanding() {
        // The ordinary case: the completion ran, cleared the id and fired
        // `onExit` before the app ever went away.
        XCTAssertEqual(
            focusDismissRecoveryOnForeground(
                hasPendingDismiss: false,
                canExitBySwipe: true,
                returnedFromBackground: true
            ),
            .none
        )
    }

    func testFocusDismissRecoveryHonoursTheCommitAfterABackgroundRoundTrip() {
        // The completion is `onExit`'s only caller. If it never ran, the
        // model is stuck at `exitTravel` — surface off-screen, unhittable,
        // nothing else writes it — and the user cannot end the session.
        XCTAssertEqual(
            focusDismissRecoveryOnForeground(
                hasPendingDismiss: true,
                canExitBySwipe: true,
                returnedFromBackground: true
            ),
            .exit
        )
    }

    func testFocusDismissRecoveryBringsTheSurfaceBackWhenTheGateHasClosed() {
        // Under rotation-driven focus `onExit` only clears the manual
        // flag, so firing it would leave the surface exactly where the
        // dropped completion did.
        XCTAssertEqual(
            focusDismissRecoveryOnForeground(
                hasPendingDismiss: true,
                canExitBySwipe: false,
                returnedFromBackground: true
            ),
            .settle
        )
    }

    // MARK: - Focus mode quick action eligibility

    func testFocusQuickActionAllowedForPlainEvent() {
        let event = Event(title: "Plain", type: "Work")
        XCTAssertTrue(focusQuickActionAllowedForEvent(event))
    }

    func testFocusQuickActionDisallowedForRecurringSeries() {
        var event = Event(title: "Standup", type: "Work")
        event.repeatUnit = .week
        // Sanity: this is what the helper inspects.
        XCTAssertTrue(event.isRecurringSeries)
        XCTAssertFalse(focusQuickActionAllowedForEvent(event))
    }

    func testFocusQuickActionDisallowedForRecurringExceptionOccurrence() {
        var event = Event(title: "Standup (today)", type: "Work")
        event.recurrenceParentId = UUID()
        event.recurrenceInstanceDate = Date()
        XCTAssertFalse(focusQuickActionAllowedForEvent(event))
    }

    // MARK: - Focus mode inline title commit

    func testFocusTitleCommitValueReturnsNilWhenUnchanged() {
        XCTAssertNil(focusTitleCommitValue(draft: "Work", current: "Work"))
    }

    func testFocusTitleCommitValueReturnsTrimmedDraft() {
        XCTAssertEqual(
            focusTitleCommitValue(draft: "  Refactor auth  ", current: "Work"),
            "Refactor auth"
        )
    }

    func testFocusTitleCommitValueAllowsClearingToEmpty() {
        // Clearing a title is a valid edit — data layer accepts empty
        // and the view falls back to a placeholder for display.
        XCTAssertEqual(focusTitleCommitValue(draft: "", current: "Work"), "")
    }

    func testFocusTitleCommitValueTreatsWhitespaceOnlyDraftAsEmpty() {
        XCTAssertEqual(
            focusTitleCommitValue(draft: "   \n  ", current: "Work"),
            ""
        )
    }

    func testFocusTitleCommitValueTreatsTrimmedEqualAsUnchanged() {
        // "  Work  " trimmed equals current "Work" — should skip commit.
        XCTAssertNil(focusTitleCommitValue(draft: "  Work  ", current: "Work"))
    }

    // MARK: - Focus mode timeline note commit

    func testFocusNoteCommitTextReturnsNilForEmptyDraft() {
        XCTAssertNil(focusNoteCommitText(draft: ""))
    }

    func testFocusNoteCommitTextReturnsNilForWhitespaceOnlyDraft() {
        XCTAssertNil(focusNoteCommitText(draft: "   \n  \t  "))
    }

    func testFocusNoteCommitTextTrimsAndReturnsContent() {
        XCTAssertEqual(
            focusNoteCommitText(draft: "  Hit a wall on auth refactor  "),
            "Hit a wall on auth refactor"
        )
    }

    func testFocusNoteCommitTextPreservesInternalWhitespace() {
        // Newlines and double spaces inside the body are content, not noise.
        XCTAssertEqual(
            focusNoteCommitText(draft: "line one\nline two"),
            "line one\nline two"
        )
    }

    // MARK: - Calendar 15-min grid snap

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        )!
    }

    func testCalendarSnapDateLeavesGridAlignedDateUnchanged() {
        let onGrid = date(year: 2026, month: 5, day: 3, hour: 10, minute: 15)
        XCTAssertEqual(calendarSnapDateToMinuteGrid(onGrid), onGrid)
    }

    func testCalendarSnapDateRoundsUpWhenPastHalfway() {
        // 10:08 → closer to 10:15 than 10:00 → 10:15
        let raw = date(year: 2026, month: 5, day: 3, hour: 10, minute: 8)
        let expected = date(year: 2026, month: 5, day: 3, hour: 10, minute: 15)
        XCTAssertEqual(calendarSnapDateToMinuteGrid(raw), expected)
    }

    func testCalendarSnapDateRoundsDownWhenBeforeHalfway() {
        // 10:07 → closer to 10:00 than 10:15 (by 30s) → 10:00
        let raw = date(year: 2026, month: 5, day: 3, hour: 10, minute: 7)
        let expected = date(year: 2026, month: 5, day: 3, hour: 10, minute: 0)
        XCTAssertEqual(calendarSnapDateToMinuteGrid(raw), expected)
    }

    func testCalendarSnapDateIsIdempotent() {
        let raw = date(year: 2026, month: 5, day: 3, hour: 10, minute: 22, second: 47)
        let once = calendarSnapDateToMinuteGrid(raw)
        let twice = calendarSnapDateToMinuteGrid(once)
        XCTAssertEqual(once, twice)
    }

    func testCalendarSnapDateRespectsCustomGranularity() {
        // 10:23 with 30-min granularity → 10:30
        let raw = date(year: 2026, month: 5, day: 3, hour: 10, minute: 23)
        let expected = date(year: 2026, month: 5, day: 3, hour: 10, minute: 30)
        XCTAssertEqual(
            calendarSnapDateToMinuteGrid(raw, granularityMinutes: 30),
            expected
        )
    }

    // MARK: - Focus mode current-occurrence resolution (with overrun grace)

    private func makeOccurrence(
        title: String,
        startMinute: Int,
        endMinute: Int
    ) -> CalendarLayout.EventOccurrence {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        let start = calendar.date(byAdding: .minute, value: startMinute, to: day)!
        let end = calendar.date(byAdding: .minute, value: endMinute, to: day)!
        let event = Event(
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: "Work"
        )
        return CalendarLayout.EventOccurrence(
            id: event.id.uuidString,
            event: event,
            range: Event.TimeRange(start: start, end: end)
        )
    }

    func testFocusCurrentOccurrencePrefersInProgressOverRecentlyEnded() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        let now = calendar.date(byAdding: .minute, value: 615, to: day)! // 10:15
        let inProgress = makeOccurrence(title: "Coding", startMinute: 600, endMinute: 660) // 10:00–11:00
        let recentlyEnded = makeOccurrence(title: "Reading", startMinute: 540, endMinute: 600) // 9:00–10:00

        let resolved = focusCurrentOccurrence(
            in: [recentlyEnded, inProgress],
            now: now,
            overrunGrace: 5 * 60
        )
        XCTAssertEqual(resolved?.event.title, "Coding")
    }

    func testFocusCurrentOccurrenceFallsBackToRecentlyEndedWithinGrace() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        // Now is 4 min after Reading ended (within 5-min grace).
        let now = calendar.date(byAdding: .minute, value: 604, to: day)!
        let recentlyEnded = makeOccurrence(title: "Reading", startMinute: 540, endMinute: 600)

        let resolved = focusCurrentOccurrence(
            in: [recentlyEnded],
            now: now,
            overrunGrace: 5 * 60
        )
        XCTAssertEqual(resolved?.event.title, "Reading")
    }

    func testFocusCurrentOccurrenceReturnsNilWhenAllEventsOutsideGrace() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        // Now is 6 min after Reading ended — past the 5-min grace.
        let now = calendar.date(byAdding: .minute, value: 606, to: day)!
        let recentlyEnded = makeOccurrence(title: "Reading", startMinute: 540, endMinute: 600)

        let resolved = focusCurrentOccurrence(
            in: [recentlyEnded],
            now: now,
            overrunGrace: 5 * 60
        )
        XCTAssertNil(resolved)
    }

    func testFocusCurrentOccurrencePicksMostRecentEndedOnTie() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        let now = calendar.date(byAdding: .minute, value: 602, to: day)!
        let earlier = makeOccurrence(title: "First", startMinute: 540, endMinute: 580) // ended 22min ago — outside grace
        let later = makeOccurrence(title: "Second", startMinute: 580, endMinute: 600) // ended 2min ago

        let resolved = focusCurrentOccurrence(
            in: [earlier, later],
            now: now,
            overrunGrace: 5 * 60
        )
        XCTAssertEqual(resolved?.event.title, "Second")
    }

    private func makeInterruptOccurrence(
        title: String,
        startMinute: Int,
        endMinute: Int,
        parentID: UUID
    ) -> CalendarLayout.EventOccurrence {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        let start = calendar.date(byAdding: .minute, value: startMinute, to: day)!
        let end = calendar.date(byAdding: .minute, value: endMinute, to: day)!
        var event = Event(
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: "Interrupt",
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: parentID,
                occurrenceDate: start,
                state: .embedded
            )
        )
        _ = event
        return CalendarLayout.EventOccurrence(
            id: event.id.uuidString,
            event: event,
            range: Event.TimeRange(start: start, end: end)
        )
    }

    func testFocusCurrentOccurrencePrefersEmbeddedInterruptOverParent() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        let now = calendar.date(byAdding: .minute, value: 612, to: day)! // 10:12

        let parent = makeOccurrence(title: "Coding", startMinute: 600, endMinute: 660) // 10:00–11:00
        // Interrupt overlapping parent, started 2 min ago, lasts 15 min.
        let interrupt = makeInterruptOccurrence(
            title: "Phone call",
            startMinute: 610,
            endMinute: 625,
            parentID: parent.event.id
        )

        let resolved = focusCurrentOccurrence(
            in: [parent, interrupt],
            now: now,
            overrunGrace: 5 * 60
        )
        XCTAssertEqual(resolved?.event.title, "Phone call")
    }

    func testFocusCurrentOccurrenceFallsBackToParentAfterInterruptEnds() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        let now = calendar.date(byAdding: .minute, value: 630, to: day)! // 10:30

        let parent = makeOccurrence(title: "Coding", startMinute: 600, endMinute: 660)
        // Interrupt already ended at 10:25.
        let interrupt = makeInterruptOccurrence(
            title: "Phone call",
            startMinute: 610,
            endMinute: 625,
            parentID: parent.event.id
        )

        let resolved = focusCurrentOccurrence(
            in: [parent, interrupt],
            now: now,
            overrunGrace: 5 * 60
        )
        // Interrupt no longer in-progress → resolution falls back to parent.
        XCTAssertEqual(resolved?.event.title, "Coding")
    }

    func testFocusCurrentOccurrenceWithZeroGraceMatchesStrictInProgressOnly() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        let now = calendar.date(byAdding: .minute, value: 601, to: day)! // just past 10:00
        let recentlyEnded = makeOccurrence(title: "Reading", startMinute: 540, endMinute: 600)

        let resolved = focusCurrentOccurrence(
            in: [recentlyEnded],
            now: now,
            overrunGrace: 0
        )
        XCTAssertNil(resolved)
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
        // Move-drag suppresses SwiftUI's leading spring; the OPEN animation
        // is driven externally by a CADisplayLink that updates scrollTo and
        // a visual y-offset modifier in lockstep (#55).
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

    // MARK: - Render Gating

    func testRenderGatingIncludesVisibleRange() {
        // Offsets within renderCenter ± renderBuffer should be rendered
        for offset in -5...5 {
            XCTAssertTrue(
                calendarShouldRenderFullDayColumn(
                    offset: offset,
                    renderCenter: 0,
                    renderBuffer: 5,
                    dragSourceDayOffset: nil
                ),
                "offset \(offset) should be in render range"
            )
        }
    }

    func testRenderGatingExcludesDistantOffset() {
        XCTAssertFalse(
            calendarShouldRenderFullDayColumn(
                offset: 20,
                renderCenter: 0,
                renderBuffer: 5,
                dragSourceDayOffset: nil
            )
        )
        XCTAssertFalse(
            calendarShouldRenderFullDayColumn(
                offset: -20,
                renderCenter: 0,
                renderBuffer: 5,
                dragSourceDayOffset: nil
            )
        )
    }

    func testRenderGatingAlwaysIncludesDragSource() {
        // Drag source at offset 20, far outside buffer of 5 around center 0
        XCTAssertTrue(
            calendarShouldRenderFullDayColumn(
                offset: 20,
                renderCenter: 0,
                renderBuffer: 5,
                dragSourceDayOffset: 20
            )
        )
    }

    func testRenderGatingDragSourceNilWhenNoDrag() {
        // Without active drag, distant offset is excluded
        XCTAssertFalse(
            calendarShouldRenderFullDayColumn(
                offset: 20,
                renderCenter: 0,
                renderBuffer: 5,
                dragSourceDayOffset: nil
            )
        )
    }

    func testRenderGatingBufferCoversWeekMode() {
        // Week mode: daysCount=7, buffer should be 7
        let buffer = calendarRenderBuffer(daysCount: 7)
        XCTAssertEqual(buffer, 7)
        // All 7 visible days (center ± 3) should be within buffer of 5
        for offset in -3...3 {
            XCTAssertTrue(
                calendarShouldRenderFullDayColumn(
                    offset: offset,
                    renderCenter: 0,
                    renderBuffer: buffer,
                    dragSourceDayOffset: nil
                ),
                "week mode visible offset \(offset) should be rendered"
            )
        }
    }

    func testRenderGatingBoundaryExact() {
        // Exactly at buffer boundary → included
        XCTAssertTrue(
            calendarShouldRenderFullDayColumn(
                offset: 5,
                renderCenter: 0,
                renderBuffer: 5,
                dragSourceDayOffset: nil
            )
        )
        // buffer + 1 → excluded
        XCTAssertFalse(
            calendarShouldRenderFullDayColumn(
                offset: 6,
                renderCenter: 0,
                renderBuffer: 5,
                dragSourceDayOffset: nil
            )
        )
    }

    func testRenderBufferSizeForAllModes() {
        // Day mode
        XCTAssertEqual(calendarRenderBuffer(daysCount: 1), 7)
        // 3-day mode
        XCTAssertEqual(calendarRenderBuffer(daysCount: 3), 7)
        // Week mode
        XCTAssertEqual(calendarRenderBuffer(daysCount: 7), 7)
    }

    // MARK: - Visible Viewport Gate

    func testVisibleViewportSingleDay() {
        // Day mode: only the selected day is visible
        XCTAssertTrue(
            calendarIsDayInVisibleViewport(offset: 5, selectedDayOffset: 5, daysCount: 1)
        )
        XCTAssertFalse(
            calendarIsDayInVisibleViewport(offset: 4, selectedDayOffset: 5, daysCount: 1)
        )
        XCTAssertFalse(
            calendarIsDayInVisibleViewport(offset: 6, selectedDayOffset: 5, daysCount: 1)
        )
    }

    func testVisibleViewportThreeDay() {
        // 3-day mode: selected ± 1 are visible
        for offset in 4...6 {
            XCTAssertTrue(
                calendarIsDayInVisibleViewport(offset: offset, selectedDayOffset: 5, daysCount: 3)
            )
        }
        XCTAssertFalse(
            calendarIsDayInVisibleViewport(offset: 3, selectedDayOffset: 5, daysCount: 3)
        )
        XCTAssertFalse(
            calendarIsDayInVisibleViewport(offset: 7, selectedDayOffset: 5, daysCount: 3)
        )
    }

    func testVisibleViewportWeek() {
        // Week mode: selected ± 3 are visible
        for offset in 2...8 {
            XCTAssertTrue(
                calendarIsDayInVisibleViewport(offset: offset, selectedDayOffset: 5, daysCount: 7)
            )
        }
        XCTAssertFalse(
            calendarIsDayInVisibleViewport(offset: 1, selectedDayOffset: 5, daysCount: 7)
        )
        XCTAssertFalse(
            calendarIsDayInVisibleViewport(offset: 9, selectedDayOffset: 5, daysCount: 7)
        )
    }

    func testVisibleViewportRenderBufferDaysAreNotVisible() {
        // Days inside the render buffer (selected ± 5) but outside the
        // visible viewport (selected ± 0 in single-day mode) must NOT be
        // considered visible.  This is the key invariant for the drag
        // preview optimization.
        XCTAssertFalse(
            calendarIsDayInVisibleViewport(offset: 3, selectedDayOffset: 5, daysCount: 1)
        )
        XCTAssertFalse(
            calendarIsDayInVisibleViewport(offset: 7, selectedDayOffset: 5, daysCount: 1)
        )
    }

    // MARK: - Pinch Anchor Math

    func testPinchAnchorTimeAtViewportCenter() {
        // Viewport: 800px tall, scrolled to Y=200
        // topOverlayInset = 100, hourHeight = 56
        // Center Y in scroll content = 200 + 400 = 600
        // Time = (600 - 100) / 56 = 8.928... hours
        let anchor = calendarPinchAnchorTimeHours(
            scrollY: 200,
            viewportHeight: 800,
            topOverlayInset: 100,
            hourHeight: 56
        )
        XCTAssertEqual(anchor, 500.0 / 56, accuracy: 0.001)
    }

    func testPinchAnchorRoundTripPreservesCenter() {
        // Capture anchor at H1, then compute scrollY at H2 — the resulting
        // viewport center should map back to the same anchor time.
        let scrollY: CGFloat = 300
        let viewportHeight: CGFloat = 700
        let topInset: CGFloat = 80
        let h1: CGFloat = 56
        let h2: CGFloat = 84  // zoom in 1.5x

        let anchor = calendarPinchAnchorTimeHours(
            scrollY: scrollY,
            viewportHeight: viewportHeight,
            topOverlayInset: topInset,
            hourHeight: h1
        )
        let newScrollY = calendarPinchAdjustedScrollY(
            anchorTimeHours: anchor,
            viewportHeight: viewportHeight,
            topOverlayInset: topInset,
            hourHeight: h2
        )
        let newAnchor = calendarPinchAnchorTimeHours(
            scrollY: newScrollY,
            viewportHeight: viewportHeight,
            topOverlayInset: topInset,
            hourHeight: h2
        )
        XCTAssertEqual(anchor, newAnchor, accuracy: 0.0001)
    }

    func testPinchAnchorZoomInMovesScrollDown() {
        // Zooming in (hourHeight grows) at the middle of the day should
        // increase scrollY because the same time is now further from the top.
        let scrollY: CGFloat = 400
        let anchor = calendarPinchAnchorTimeHours(
            scrollY: scrollY,
            viewportHeight: 600,
            topOverlayInset: 50,
            hourHeight: 56
        )
        let newScrollY = calendarPinchAdjustedScrollY(
            anchorTimeHours: anchor,
            viewportHeight: 600,
            topOverlayInset: 50,
            hourHeight: 96  // zoom in
        )
        XCTAssertGreaterThan(newScrollY, scrollY)
    }

    func testPinchAnchorZoomOutMovesScrollUp() {
        // Zooming out (hourHeight shrinks) at the middle of the day should
        // decrease scrollY.
        let scrollY: CGFloat = 800
        let anchor = calendarPinchAnchorTimeHours(
            scrollY: scrollY,
            viewportHeight: 600,
            topOverlayInset: 50,
            hourHeight: 56
        )
        let newScrollY = calendarPinchAdjustedScrollY(
            anchorTimeHours: anchor,
            viewportHeight: 600,
            topOverlayInset: 50,
            hourHeight: 34  // zoom out
        )
        XCTAssertLessThan(newScrollY, scrollY)
    }

    func testPinchAnchorZeroHourHeightSafe() {
        // Defensive: should not crash on zero hourHeight
        XCTAssertEqual(
            calendarPinchAnchorTimeHours(
                scrollY: 100, viewportHeight: 500, topOverlayInset: 50, hourHeight: 0
            ),
            0
        )
    }

    // MARK: - Pinch Fit Hour Height (mode-aware "whole day fits above tab bar" snap point)

    func testPinchFitTypicalPhoneDayMode() {
        // iPhone Pro day mode: viewport=852, topInset=108 (no legend),
        // bottomInset=34 (home indicator + tab bar), no all-day events.
        // available = 852 - 108 - 34 - 0 - 22 = 688.  fitH = (688/24) × 1.02 ≈ 29.24
        // The ×1.02 is the min-scroll-headroom factor added in 62e5f60 (so content
        // is slightly taller than the viewport at max pinch → autoscroll/boundary
        // extension still work). This test predated that factor.
        let fit = calendarPinchFitHourHeight(
            viewportHeight: 852,
            contentTopInset: 108,
            contentBottomInset: 34,
            allDayHeight: 0
        )
        XCTAssertEqual(fit, (688.0 / 24) * 1.02, accuracy: 0.01)
    }

    func testPinchFitAccountsForBottomSafeArea() {
        // Adding bottom safe area inset (e.g. tab bar) reduces fit
        let noTabBar = calendarPinchFitHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 0, allDayHeight: 0
        )
        let withTabBar = calendarPinchFitHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 34, allDayHeight: 0
        )
        XCTAssertGreaterThan(noTabBar, withTabBar)
        // Difference is scaled by the ×1.02 min-scroll-headroom factor (62e5f60).
        XCTAssertEqual(noTabBar - withTabBar, (34.0 / 24) * 1.02, accuracy: 0.01)
    }

    func testPinchFitAccountsForAllDayHeight() {
        let withAllDay = calendarPinchFitHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 34, allDayHeight: 60
        )
        let withoutAllDay = calendarPinchFitHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 34, allDayHeight: 0
        )
        XCTAssertLessThan(withAllDay, withoutAllDay)
    }

    func testPinchFitDifferentInThreeDayMode() {
        // 3-day mode adds the 34-px date legend bar to the top inset.
        let dayMode = calendarPinchFitHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 34, allDayHeight: 0
        )
        let threeDayMode = calendarPinchFitHourHeight(
            viewportHeight: 852, contentTopInset: 142, contentBottomInset: 34, allDayHeight: 0
        )
        XCTAssertGreaterThan(dayMode, threeDayMode)
        // Difference is scaled by the ×1.02 min-scroll-headroom factor (62e5f60).
        XCTAssertEqual(dayMode - threeDayMode, (34.0 / 24) * 1.02, accuracy: 0.01)
    }

    func testPinchFitLargerOnIpad() {
        let phone = calendarPinchFitHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 34, allDayHeight: 0
        )
        let ipad = calendarPinchFitHourHeight(
            viewportHeight: 1366, contentTopInset: 108, contentBottomInset: 20, allDayHeight: 0
        )
        XCTAssertGreaterThan(ipad, phone)
    }

    func testPinchFitReturnsZeroForDegenerateInputs() {
        XCTAssertEqual(
            calendarPinchFitHourHeight(
                viewportHeight: 0, contentTopInset: 0, contentBottomInset: 0, allDayHeight: 0
            ),
            0
        )
        XCTAssertEqual(
            calendarPinchFitHourHeight(
                viewportHeight: 100, contentTopInset: 200, contentBottomInset: 0, allDayHeight: 0
            ),
            0
        )
    }

    // MARK: - Pinch Effective Min Hour Height

    func testPinchEffectiveMinEqualsFitWhenAboveFloor() {
        // Phone day mode: fitH ≈ 28.67, well above safety floor → min = fitH
        let fit = calendarPinchFitHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 34, allDayHeight: 0
        )
        let min = calendarPinchEffectiveMinHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 34, allDayHeight: 0
        )
        XCTAssertEqual(min, fit, accuracy: 0.01)
    }

    func testPinchEffectiveMinDifferentByMode() {
        let day = calendarPinchEffectiveMinHourHeight(
            viewportHeight: 852, contentTopInset: 108, contentBottomInset: 34, allDayHeight: 0
        )
        let threeDay = calendarPinchEffectiveMinHourHeight(
            viewportHeight: 852, contentTopInset: 142, contentBottomInset: 34, allDayHeight: 0
        )
        XCTAssertGreaterThan(day, threeDay)
    }

    func testPinchEffectiveMinFallsBackToSafetyFloor() {
        // Tiny viewport: fit is below floor, return floor
        XCTAssertEqual(
            calendarPinchEffectiveMinHourHeight(
                viewportHeight: 200,
                contentTopInset: 100,
                contentBottomInset: 34,
                allDayHeight: 0,
                safetyFloor: 14
            ),
            14
        )
    }

    func testPinchEffectiveMinAcceptsCustomFloor() {
        XCTAssertEqual(
            calendarPinchEffectiveMinHourHeight(
                viewportHeight: 200,
                contentTopInset: 100,
                contentBottomInset: 34,
                allDayHeight: 0,
                safetyFloor: 20
            ),
            20
        )
    }

    func testPinchHourHeightClampsAtSafetyFloor() {
        // 20 * 0.1 = 2, below safety floor (12), clamps to 12.
        let nextH = calendarTimelineHourHeightAfterPinchScale(
            initialHourHeight: 20,
            scale: 0.1,
            minHourHeight: calendarTimelineHourHeightMin
        )
        XCTAssertEqual(nextH, calendarTimelineHourHeightMin, accuracy: 0.0001)
    }

    func testDragSourceDayOffsetComputesCorrectly() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let range = Event.TimeRange(
            start: twoDaysAgo,
            end: twoDaysAgo.addingTimeInterval(3600)
        )
        let offset = calendarDragSourceDayOffset(
            draggingOriginalRange: range,
            reference: Date(),
            calendar: calendar
        )
        XCTAssertEqual(offset, -2)
    }

    func testDragSourceDayOffsetNilWhenNoRange() {
        XCTAssertNil(
            calendarDragSourceDayOffset(
                draggingOriginalRange: nil
            )
        )
    }

    // MARK: - Max All-Day Count Cache

    private func makeAllDayOccurrence() -> CalendarLayout.EventOccurrence {
        let now = Date()
        let event = Event(
            id: UUID(), title: "All-day", note: "", location: "",
            timeRanges: [Event.TimeRange(start: now, end: now.addingTimeInterval(86400))],
            deadline: nil, repeatUnit: .none, isAllDay: true,
            isDone: false, repeatInterval: 0, repeatEndType: .none,
            repeatEndDate: nil, repeatEndCount: nil, priority: 0,
            status: .active, createdAt: now, completeAt: nil,
            tags: [], type: "work", colorDepth: 0.5,
            recurrenceParentId: nil, recurrenceInstanceDate: nil,
            recurrenceExceptionDates: [],
            timerStartedAt: nil, linkedCalendarEventId: nil,
            linkedTodoEventId: nil, listID: nil, agenticIntake: nil,
            suggestedLogTemplateID: nil, suggestedLogTemplateConfidence: nil,
            suggestedLogTemplateUpdatedAt: nil, suggestedLogTemplateSource: nil,
            displayKind: .regular, interruptRelation: nil
        )
        return CalendarLayout.EventOccurrence(
            id: event.id.uuidString,
            event: event,
            range: Event.TimeRange(start: now, end: now.addingTimeInterval(86400))
        )
    }

    func testMaxAllDayCountReturnsZeroForEmptyCache() {
        XCTAssertEqual(calendarMaxAllDayCount(in: [:]), 0)
    }

    func testMaxAllDayCountReturnsZeroWhenAllDaysEmpty() {
        let cache: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [],
            1: [],
            2: []
        ]
        XCTAssertEqual(calendarMaxAllDayCount(in: cache), 0)
    }

    func testMaxAllDayCountReturnsHighestDayCount() {
        let cache: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [makeAllDayOccurrence()],
            1: [makeAllDayOccurrence(), makeAllDayOccurrence(), makeAllDayOccurrence()],
            2: [makeAllDayOccurrence(), makeAllDayOccurrence()]
        ]
        XCTAssertEqual(calendarMaxAllDayCount(in: cache), 3)
    }

    func testMaxAllDayCountIgnoresMissingOffsets() {
        // Sparse cache: only some offsets populated
        let cache: [Int: [CalendarLayout.EventOccurrence]] = [
            -10: [makeAllDayOccurrence(), makeAllDayOccurrence()],
            5: [makeAllDayOccurrence()]
        ]
        XCTAssertEqual(calendarMaxAllDayCount(in: cache), 2)
    }

    // MARK: - Render Gating Performance Benchmark

    /// Simulates the before/after difference: how many day columns would be
    /// fully rendered with vs without render gating.
    func testRenderGatingReducesDayColumnCount() {
        let dayRange = -30...30  // 61 days total
        let center = 0
        let buffer = calendarRenderBuffer(daysCount: 1)

        let beforeCount = dayRange.count  // 61
        let afterCount = dayRange.filter { offset in
            calendarShouldRenderFullDayColumn(
                offset: offset,
                renderCenter: center,
                renderBuffer: buffer,
                dragSourceDayOffset: nil
            )
        }.count

        XCTAssertEqual(beforeCount, 61, "Before: all 61 days rendered")
        XCTAssertEqual(afterCount, 15, "After: only 15 days rendered (center ± 7)")
        let reduction = Double(beforeCount - afterCount) / Double(beforeCount) * 100
        // Print for visibility in test logs
        print("📊 Render gating: \(beforeCount) → \(afterCount) day columns (\(String(format: "%.0f", reduction))% reduction)")
    }

    /// Measures overlapLayout time with synthetic events to demonstrate the
    /// computational savings of conditional stableOverlapSlots.
    func testOverlapLayoutConditionalSavesComputation() {
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 6))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        // Create 8 overlapping events for a busy day
        var events: [CalendarLayout.EventOccurrence] = []
        for i in 0..<8 {
            let start = calendar.date(from: DateComponents(
                year: 2026, month: 4, day: 6, hour: 9 + (i % 4), minute: 0
            ))!
            let end = start.addingTimeInterval(3600 * 2)
            let event = Event(
                id: UUID(), title: "Event \(i)", note: "", location: "",
                timeRanges: [Event.TimeRange(start: start, end: end)],
                deadline: nil, repeatUnit: .none, isAllDay: false,
                isDone: false, repeatInterval: 0, repeatEndType: .none,
                repeatEndDate: nil, repeatEndCount: nil, priority: 0,
                status: .active, createdAt: Date(), completeAt: nil,
                tags: [], type: "work", colorDepth: 0.5,
                recurrenceParentId: nil, recurrenceInstanceDate: nil,
                recurrenceExceptionDates: [],
                timerStartedAt: nil, linkedCalendarEventId: nil,
                linkedTodoEventId: nil, listID: nil, agenticIntake: nil,
                suggestedLogTemplateID: nil, suggestedLogTemplateConfidence: nil,
                suggestedLogTemplateUpdatedAt: nil, suggestedLogTemplateSource: nil,
                displayKind: .regular, interruptRelation: nil
            )
            events.append(CalendarLayout.EventOccurrence(
                id: "\(event.id)-\(i)",
                event: event,
                range: Event.TimeRange(start: start, end: end)
            ))
        }

        // Before: 2 overlapLayout calls × 61 days = 122 calls
        // After (idle): 1 call × 11 days = 11 calls
        // After (drag): 2 calls × 11 days = 22 calls

        let iterations = 122  // simulate "before" total
        let startBefore = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = CalendarLayout.overlapLayout(
                for: events, visibleStart: dayStart, visibleEnd: dayEnd
            )
        }
        let timeBefore = CFAbsoluteTimeGetCurrent() - startBefore

        let iterationsAfterIdle = 11  // simulate "after" idle total
        let startAfterIdle = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterationsAfterIdle {
            _ = CalendarLayout.overlapLayout(
                for: events, visibleStart: dayStart, visibleEnd: dayEnd
            )
        }
        let timeAfterIdle = CFAbsoluteTimeGetCurrent() - startAfterIdle

        let iterationsAfterDrag = 22  // simulate "after" drag total
        let startAfterDrag = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterationsAfterDrag {
            _ = CalendarLayout.overlapLayout(
                for: events, visibleStart: dayStart, visibleEnd: dayEnd
            )
        }
        let timeAfterDrag = CFAbsoluteTimeGetCurrent() - startAfterDrag

        let speedupIdle = timeBefore / max(timeAfterIdle, 0.000001)
        let speedupDrag = timeBefore / max(timeAfterDrag, 0.000001)

        print("📊 overlapLayout benchmark (8 overlapping events):")
        print("   Before:      122 calls = \(String(format: "%.3f", timeBefore * 1000))ms")
        print("   After idle:   11 calls = \(String(format: "%.3f", timeAfterIdle * 1000))ms (\(String(format: "%.1f", speedupIdle))x faster)")
        print("   After drag:   22 calls = \(String(format: "%.3f", timeAfterDrag * 1000))ms (\(String(format: "%.1f", speedupDrag))x faster)")

        // Verify meaningful speedup
        XCTAssertGreaterThan(speedupIdle, 5, "Idle mode should be >5x faster")
        XCTAssertGreaterThan(speedupDrag, 3, "Drag mode should be >3x faster")
    }

    /// Measures incremental vs full cache rebuild to verify the savings.
    func testIncrementalCacheRebuildFasterThanFull() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())

        // Create some synthetic events
        var events: [Event] = []
        for i in 0..<20 {
            let dayOffset = (i % 61) - 30
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            let start = calendar.date(byAdding: .hour, value: 9, to: day)!
            let end = start.addingTimeInterval(3600)
            events.append(Event(
                id: UUID(), title: "Event \(i)", note: "", location: "",
                timeRanges: [Event.TimeRange(start: start, end: end)],
                deadline: nil, repeatUnit: .none, isAllDay: false,
                isDone: false, repeatInterval: 0, repeatEndType: .none,
                repeatEndDate: nil, repeatEndCount: nil, priority: 0,
                status: .active, createdAt: Date(), completeAt: nil,
                tags: [], type: "work", colorDepth: 0.5,
                recurrenceParentId: nil, recurrenceInstanceDate: nil,
                recurrenceExceptionDates: [],
                timerStartedAt: nil, linkedCalendarEventId: nil,
                linkedTodoEventId: nil, listID: nil, agenticIntake: nil,
                suggestedLogTemplateID: nil, suggestedLogTemplateConfidence: nil,
                suggestedLogTemplateUpdatedAt: nil, suggestedLogTemplateSource: nil,
                displayKind: .regular, interruptRelation: nil
            ))
        }

        // Full rebuild: -30...30 (61 days)
        let startFull = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            _ = CalendarLayout.occurrencesByOffset(events, dayRange: -30...30, calendar: calendar, reference: today)
        }
        let timeFull = (CFAbsoluteTimeGetCurrent() - startFull) / 10

        // Incremental: expand from -30...30 to -40...30 (only 10 new days)
        let startIncremental = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            for offset in -40 ... -31 {
                let day = calendar.date(byAdding: .day, value: offset, to: today)!
                _ = CalendarLayout.occurrencesForDate(events, date: day, calendar: calendar)
            }
        }
        let timeIncremental = (CFAbsoluteTimeGetCurrent() - startIncremental) / 10

        let speedup = timeFull / max(timeIncremental, 0.000001)

        print("📊 Cache rebuild benchmark (20 events):")
        print("   Full (61 days):        \(String(format: "%.3f", timeFull * 1000))ms")
        print("   Incremental (10 days): \(String(format: "%.3f", timeIncremental * 1000))ms (\(String(format: "%.1f", speedup))x faster)")

        XCTAssertGreaterThan(speedup, 3, "Incremental should be >3x faster than full rebuild")
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

    func testBoundaryExtensionScrollCompensationAppliesToAllActiveEditSources() {
        // All active edit sources (creation, moveDrag, resize) apply
        // compensation immediately so the viewport compensates in the
        // same frame. Only .focused uses deferred compensation.
        XCTAssertTrue(
            calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: .creation)
        )
        XCTAssertTrue(
            calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: .moveDrag)
        )
        XCTAssertTrue(
            calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: .resizeTop)
        )
        XCTAssertTrue(
            calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: .resizeBottom)
        )
        // nil source (no active edit) — still immediate
        XCTAssertTrue(
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

    func testAutoScrollDefaultsRespectConfiguredInsets() {
        let minOffset: CGFloat = 0
        let maxOffset: CGFloat = 2000

        // Verify that a position inside the safe margin triggers auto-scroll
        // (calendarAutoScrollSafeMargin = 80, takes precedence over insets).
        let insideSafeMargin = calendarAutoScrollVelocity(
            locationInViewport: calendarAutoScrollSafeMargin - 2,
            viewportLength: 600,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: calendarHorizontalAutoScrollEdgeInsetDefault,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        XCTAssertLessThan(insideSafeMargin, 0, "Inside safe margin should trigger auto-scroll")

        // Verify that a position well beyond both safe margin and inset
        // produces zero velocity.
        let verticalInset = calendarVerticalAutoScrollEdgeInsetDefault
        let outsideEverything = calendarAutoScrollVelocity(
            locationInViewport: verticalInset + 20,
            viewportLength: 900,
            currentOffset: 1000,
            minOffset: minOffset,
            maxOffset: maxOffset,
            edgeInset: verticalInset,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
        XCTAssertEqual(outsideEverything, 0, accuracy: 0.0001, "Beyond inset should have zero velocity")
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
            calendarIsFocusVisualContextActive(focusedEventID: focusedID)
        )
    }

    func testFocusVisualContextInactiveWhenFocusedEventMissing() {
        XCTAssertFalse(
            calendarIsFocusVisualContextActive(focusedEventID: nil)
        )
    }

    func testFocusVisualContextIgnoresDraggingStateWhenFocusedEventExists() {
        let focusedID = UUID()
        XCTAssertTrue(
            calendarIsFocusVisualContextActive(
                focusedEventID: focusedID,
                draggingEventID: focusedID,
                isMoveDragActive: true
            )
        )
        XCTAssertTrue(
            calendarIsFocusVisualContextActive(
                focusedEventID: focusedID,
                draggingEventID: UUID(),
                isMoveDragActive: true
            )
        )
        XCTAssertTrue(
            calendarIsFocusVisualContextActive(
                focusedEventID: focusedID,
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
            calendarRangeModeTimelineOptions(),
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

    func testClampedMoveDragOffsetYStopsAtConfiguredBounds() {
        XCTAssertEqual(
            calendarClampedMoveDragOffsetY(
                rawOffsetY: -180,
                dragMode: .move,
                verticalDragBounds: (-120)...240
            ),
            -120
        )
        XCTAssertEqual(
            calendarClampedMoveDragOffsetY(
                rawOffsetY: 320,
                dragMode: .move,
                verticalDragBounds: (-120)...240
            ),
            240
        )
        XCTAssertEqual(
            calendarClampedMoveDragOffsetY(
                rawOffsetY: 320,
                dragMode: .resizeBottom,
                verticalDragBounds: (-120)...240
            ),
            320
        )
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

    func testAdjustedOccurrenceRangeReturnsNilForSecondaryProjectionWhenPreviewLeavesDay() {
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let occurrence = Event.TimeRange(
            start: dayStart.addingTimeInterval(9 * 3600),
            end: dayStart.addingTimeInterval(10 * 3600)
        )
        let nextDayPreview = Event.TimeRange(
            start: dayEnd.addingTimeInterval(2 * 3600),
            end: dayEnd.addingTimeInterval(4 * 3600)
        )

        let adjusted = calendarAdjustedOccurrenceRange(
            occurrenceID: "occ-1",
            occurrenceRange: occurrence,
            draggingOccurrenceID: "occ-1",
            draggingOriginalRange: occurrence,
            dragMode: .move,
            previewRange: nextDayPreview,
            dayStart: dayStart,
            dayEnd: dayEnd,
            keepOriginalWhenPreviewLeavesDay: false
        )

        XCTAssertNil(adjusted)
    }

    func testResolvedPrimaryDragRenderDayStartMovesWithBoundaryPaging() {
        let calendar = Calendar(identifier: .gregorian)
        let sourceDay = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27))!

        let pagedDay = calendarResolvedPrimaryDragRenderDayStart(
            sourceDayStart: sourceDay,
            dragOffset: DragOffset(x: 120, y: 0),
            dayStep: 120,
            usesHorizontalBoundaryPaging: true,
            calendar: calendar
        )
        XCTAssertEqual(
            pagedDay,
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 28))!
        )

        let fixedDay = calendarResolvedPrimaryDragRenderDayStart(
            sourceDayStart: sourceDay,
            dragOffset: DragOffset(x: 120, y: 0),
            dayStep: 120,
            usesHorizontalBoundaryPaging: false,
            calendar: calendar
        )
        XCTAssertEqual(fixedDay, sourceDay)
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
        // 56 * 0.5 = 28, above static min (14), no clamping
        XCTAssertEqual(
            calendarTimelineHourHeightAfterPinchScale(
                initialHourHeight: 56,
                scale: 0.5
            ),
            28,
            accuracy: 0.0001
        )
        // 56 * 0.1 = 5.6, below static min (8), clamps to min
        XCTAssertEqual(
            calendarTimelineHourHeightAfterPinchScale(
                initialHourHeight: 56,
                scale: 0.1
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
        XCTAssertGreaterThanOrEqual(compactBottom, 4)
        XCTAssertGreaterThan(regularTop, compactTop)
        XCTAssertGreaterThanOrEqual(regularBottom, compactBottom)
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

    func testResolveDragEditRangeFlipsWhenEdgesCross() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11, minute: 0))!
        let range = Event.TimeRange(start: start, end: end)
        let hourHeight: CGFloat = 56

        // Drag the BOTTOM edge UP by 90 min: the dragged end (11:00 - 90m =
        // 09:30) crosses ABOVE the anchor start (10:00). Result must FLIP to a
        // sorted range anchored at the original start: 09:30 → 10:00.
        let bottomCrossesUp = calendarResolvedDragEditRange(
            draggingOriginalRange: range,
            dragOffset: DragOffset(x: 0, y: -hourHeight * 1.5),
            dragMode: .resizeBottom,
            hourHeight: hourHeight,
            calendar: calendar
        )
        XCTAssertEqual(bottomCrossesUp?.start, end.addingTimeInterval(-90 * 60))
        XCTAssertEqual(bottomCrossesUp?.end, start)

        // Drag the TOP edge DOWN by 90 min: the dragged start (10:00 + 90m =
        // 11:30) crosses BELOW the anchor end (11:00). Result flips, anchored at
        // the original end: 11:00 → 11:30.
        let topCrossesDown = calendarResolvedDragEditRange(
            draggingOriginalRange: range,
            dragOffset: DragOffset(x: 0, y: hourHeight * 1.5),
            dragMode: .resizeTop,
            hourHeight: hourHeight,
            calendar: calendar
        )
        XCTAssertEqual(topCrossesDown?.start, end)
        XCTAssertEqual(topCrossesDown?.end, start.addingTimeInterval(90 * 60))
    }

    func testResizedRangeFromDragAppliesMinDurationAfterFlip() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 11, minute: 0))!
        let range = Event.TimeRange(start: start, end: end)
        let hourHeight: CGFloat = 56

        // Bottom edge dragged exactly onto the start (offset = -60 min): the
        // sorted span collapses to zero → the commit floor expands it to 15 min
        // anchored at the original start (10:00), settling 10:00 → 10:15.
        let flooredBottom = calendarResizedRangeFromDrag(
            draggedRange: range,
            dragMode: .resizeBottom,
            offsetY: -hourHeight,
            hourHeight: hourHeight,
            calendar: calendar
        )
        XCTAssertEqual(flooredBottom.start, start)
        XCTAssertEqual(flooredBottom.end, start.addingTimeInterval(15 * 60))

        // Top edge dragged exactly onto the end (offset = +60 min): floor expands
        // 15 min anchored at the original end (11:00), settling 10:45 → 11:00.
        let flooredTop = calendarResizedRangeFromDrag(
            draggedRange: range,
            dragMode: .resizeTop,
            offsetY: hourHeight,
            hourHeight: hourHeight,
            calendar: calendar
        )
        XCTAssertEqual(flooredTop.start, end.addingTimeInterval(-15 * 60))
        XCTAssertEqual(flooredTop.end, end)
    }

    func testResizedRangeFromDragFlipFloorPastCrossing() {
        // A 50-min event (NOT a 15-min-aligned duration) so a snapped offset can
        // land the flipped span strictly between 0 and 15 min — the only case
        // that exercises the flip-aware floor's anchor side. Regression guard for
        // the floor expanding on the wrong side after a true crossing.
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 50))!
        let range = Event.TimeRange(start: start, end: end)
        let hourHeight: CGFloat = 56  // snapSize = 14pt = 15 min

        // Drag bottom edge up by 60 min → dragged end = 9:50, i.e. 10 min PAST
        // the start (flipped, span 10 min < 15). Floor anchors at the original
        // start and expands UPWARD → 9:45 → 10:00.
        let floored = calendarResizedRangeFromDrag(
            draggedRange: range,
            dragMode: .resizeBottom,
            offsetY: -hourHeight,  // -60 min
            hourHeight: hourHeight,
            calendar: calendar
        )
        XCTAssertEqual(floored.start, start.addingTimeInterval(-15 * 60))
        XCTAssertEqual(floored.end, start)
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

    func testLongPressManipulationPromotionRequiresMovementThreshold() {
        for dragMode: EventDragMode in [.move, .resizeTop, .resizeBottom] {
            XCTAssertTrue(
                calendarShouldPromoteLongPressToManipulation(
                    dragMode: dragMode,
                    movementExceededThreshold: true
                ),
                "\(dragMode) should promote once movement crosses threshold"
            )
            XCTAssertFalse(
                calendarShouldPromoteLongPressToManipulation(
                    dragMode: dragMode,
                    movementExceededThreshold: false
                ),
                "\(dragMode) must not promote before threshold"
            )
        }
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
                kind: .singleEvent,
                dayKey: CalendarOccurrenceKey.dayKey(from: makeTimelineDate(hour: 0, minute: 0))
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
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
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
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
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
    func testCreateInterruptClampsRangeToParentWhenInputOverflowsParentEnd() {
        let suiteName = "CalendarDragLogicTests.createInterrupt.clampOverflowEnd"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let parent = Event(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            title: "Parent",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)],
            type: "Study"
        )
        store.addCalendarEvent(parent)

        // Mimics a live interrupt the user kept running 15 min past parent end.
        let interrupt = store.createInterrupt(
            parentEvent: parent,
            occurrenceDate: makeTimelineDate(hour: 10, minute: 0),
            title: "Live overrun",
            timeRange: makeTimelineRange(startHour: 10, startMinute: 45, endHour: 11, endMinute: 15)
        )

        let stored = interrupt.flatMap { store.findCalendarEvent(id: $0.id) }
        XCTAssertEqual(stored?.timeRanges.first?.start, makeTimelineDate(hour: 10, minute: 45))
        XCTAssertEqual(stored?.timeRanges.first?.end, makeTimelineDate(hour: 11, minute: 0))
    }

    func testInterruptParentCompoundGeometryCutoutAlignsToTodaySliceForCrossDayParent() {
        // Repro of the cross-day misalignment: parent 22:30 yesterday →
        // 01:30 today, child interrupt 23:45 yesterday → 00:30 today.
        // On today's slice the rendered parent block is just [00:00, 01:30]
        // (90 min). The cutout for the child must land at the *top* of
        // that sliced block, not where (childStart-fullParentStart) /
        // fullParentDuration would project it onto the sliced height.
        let calendar = Calendar(identifier: .gregorian)
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!
        let today = calendar.date(byAdding: .day, value: 1, to: yesterday)!
        let parentSliceForToday = Event.TimeRange(
            start: today,                                                   // today 00:00
            end: today.addingTimeInterval(90 * 60)                          // today 01:30
        )
        let childFullRange = Event.TimeRange(
            start: yesterday.addingTimeInterval((23 * 60 + 45) * 60),       // yesterday 23:45
            end: today.addingTimeInterval(30 * 60)                          // today 00:30
        )

        let geometry = calendarInterruptParentCompoundGeometry(
            parentRange: parentSliceForToday,
            childRanges: [childFullRange],
            parentWidth: 180,
            parentHeight: 87,                                               // 90 min * 1 px/min - 3
            horizontalGap: 3,
            verticalGap: 2
        )

        XCTAssertEqual(geometry.cutouts.count, 1)
        // Cutout starts at slice top (child began before today, gets clipped to 00:00)
        XCTAssertEqual(geometry.cutouts[0].rect.minY, 0, accuracy: 0.5)
        // Cutout maxY ≈ 30 min worth (29) + verticalGap*2 (4) = 33; well
        // before parent slice end at 87 (1:30) so a bottom lobe must remain.
        XCTAssertLessThan(geometry.cutouts[0].rect.maxY, 50)
        XCTAssertFalse(geometry.cutouts[0].hasTopLobe)
        XCTAssertTrue(geometry.cutouts[0].hasBottomLobe)
    }

    @MainActor
    func testCreateInterruptRejectsRangeWithNoParentOverlap() {
        let suiteName = "CalendarDragLogicTests.createInterrupt.noOverlap"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let parent = Event(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            title: "Parent",
            timeRanges: [makeTimelineRange(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0)],
            type: "Study"
        )
        store.addCalendarEvent(parent)

        let interrupt = store.createInterrupt(
            parentEvent: parent,
            occurrenceDate: makeTimelineDate(hour: 10, minute: 0),
            title: "Stranded",
            timeRange: makeTimelineRange(startHour: 12, startMinute: 0, endHour: 12, endMinute: 30)
        )

        XCTAssertNil(interrupt)
    }

    @MainActor
    func testRecurringInterruptRemainsAnchoredAfterSingleOccurrenceBecomesException() {
        let suiteName = "CalendarDragLogicTests.recurringInterrupt"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
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

    /// Drives the exact two-step the detail view's `editOccurrence` runs —
    /// resolve the occurrence via `calendarResolvedEventForOccurrenceContext`,
    /// then `applyRecurringEdit(.single)` — and does it TWICE with the same
    /// series-id context (as a repeated gesture like the deadline wheel would).
    /// Locks in: (1) the first edit materializes one exception and leaves the
    /// series active; (2) the re-resolve now returns that exception so the
    /// second edit REUSES it instead of spawning a duplicate (the idempotency
    /// the routing depends on). Also fixes the previously-parked toggleTodoDone
    /// series-completion bug.
    @MainActor
    func testRecurringTodoOccurrenceEditMaterializesThenReusesOneException() {
        let suiteName = "CalendarDragLogicTests.recurringTodoDone"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let occurrenceDate = makeTimelineDate(hour: 0, minute: 0)
        let series = Event(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            title: "Daily todo",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        // The context editOccurrence builds (series id + the displayed day).
        let context = CalendarEventOccurrenceContext(
            eventID: series.id,
            occurrenceDate: occurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )

        // First edit (mark done) — resolves to the series, materializes one exception.
        let firstTarget = calendarResolvedEventForOccurrenceContext(context, in: store.rawCalendarEvents)
        XCTAssertEqual(firstTarget?.id, series.id, "first resolve targets the series")
        store.applyRecurringEdit(seriesEvent: firstTarget!, occurrenceDate: occurrenceDate, scope: .single) {
            $0.isDone = true
            $0.status = .completed
            $0.completeAt = self.makeTimelineDate(hour: 9, minute: 30)
        }

        let seriesAfterFirst = store.findCalendarEvent(id: series.id)
        XCTAssertFalse(seriesAfterFirst?.isDone ?? true, "series stays active")
        XCTAssertEqual(
            seriesAfterFirst?.recurrenceExceptionDates.filter {
                Calendar.current.isDate($0, inSameDayAs: occurrenceDate)
            }.count,
            1, "edited day excepted exactly once")
        var exceptions = store.rawCalendarEvents.filter { $0.recurrenceParentId == series.id }
        XCTAssertEqual(exceptions.count, 1, "one exception after the first edit")
        XCTAssertTrue(exceptions.first?.isDone ?? false)
        XCTAssertEqual(exceptions.first?.status, .completed)
        XCTAssertFalse(exceptions.first?.isRecurringSeries ?? true)

        // Second edit (change type) via the SAME series-id context — the resolver
        // must now return the exception, so the edit accumulates on it, not a dup.
        let secondTarget = calendarResolvedEventForOccurrenceContext(context, in: store.rawCalendarEvents)
        XCTAssertEqual(secondTarget?.recurrenceParentId, series.id, "re-resolve returns the exception")
        XCTAssertNotEqual(secondTarget?.id, series.id)
        store.applyRecurringEdit(seriesEvent: secondTarget!, occurrenceDate: occurrenceDate, scope: .single) {
            $0.type = "Focus"
        }

        exceptions = store.rawCalendarEvents.filter { $0.recurrenceParentId == series.id }
        XCTAssertEqual(exceptions.count, 1, "repeated edit reuses the one exception (idempotent)")
        XCTAssertEqual(exceptions.first?.type, "Focus", "second edit accumulated on the same instance")
        XCTAssertTrue(exceptions.first?.isDone ?? false, "first edit's done state preserved")
        XCTAssertEqual(
            store.findCalendarEvent(id: series.id)?.recurrenceExceptionDates.filter {
                Calendar.current.isDate($0, inSameDayAs: occurrenceDate)
            }.count,
            1, "day still excepted exactly once, not twice")

        // A different day is untouched — still produced as an active occurrence.
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: occurrenceDate)!
        XCTAssertNotNil(
            CalendarLayout.recurrenceOccurrence(for: store.findCalendarEvent(id: series.id)!, on: nextDay),
            "unedited day still rendered by the rule")
    }

    /// Bug fix: "delete this and following" must remove materialized exceptions
    /// on/after the cutoff. A previously single-edited day ≥ cutoff is a
    /// standalone event NOT bounded by the series end date, so it used to keep
    /// rendering after the delete (only exceptions BEFORE the cutoff survive).
    @MainActor
    func testDeleteFollowingSweepsExceptionsOnOrAfterCutoff() {
        let suiteName = "CalendarDragLogicTests.deleteFollowingSweep"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day0)! }
        let series = Event(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            title: "Daily",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        // Materialize an exception BEFORE the cutoff (day1, survives) and one
        // ON/AFTER the cutoff (day3, must be swept). Cutoff = day2.
        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(1), scope: .single) { $0.type = "A" }
        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(3), scope: .single) { $0.type = "B" }
        XCTAssertEqual(store.rawCalendarEvents.filter { $0.recurrenceParentId == series.id }.count, 2)

        store.deleteRecurringCalendarEvent(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(2), scope: .following)

        // day3 exception swept, day1 exception survives.
        let survivors = store.rawCalendarEvents.filter { $0.recurrenceParentId == series.id }
        XCTAssertEqual(survivors.count, 1, "only the pre-cutoff exception survives")
        XCTAssertTrue(survivors.first?.recurrenceInstanceDate.map { cal.isDate($0, inSameDayAs: day(1)) } ?? false)
        // Series capped at the cutoff.
        let capped = store.findCalendarEvent(id: series.id)!
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: capped, on: day0))
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: capped, on: day(2)))
    }

    /// Bug fix: editing "this and following" on an `.afterCount(N)` series must
    /// give the split-off series the REMAINING count (N − elapsed), not a fresh
    /// N — otherwise the total number of occurrences inflates.
    @MainActor
    func testEditFollowingDecrementsAfterCount() {
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day0)! }
        var series = Event(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            title: "Five times",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.repeatEndType = .afterCount
        series.repeatEndCount = 5

        // Split at day2 (occurrence index 2) → old series keeps indices 0..1,
        // new series must run the remaining 3 (indices 0..2 = day2,3,4).
        let result = Event.applyEdit(series: series, occurrenceDate: day(2), scope: .following) { $0.title = "New" }
        let newSeries = result.newSeries!
        XCTAssertEqual(newSeries.repeatEndType, .afterCount)
        XCTAssertEqual(newSeries.repeatEndCount, 3, "remaining = 5 − 2 elapsed")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: newSeries, on: day(2)))
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: newSeries, on: day(4)))
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: newSeries, on: day(5)), "no inflation past the original count")
        // Old series capped by date at the day before the split.
        let old = result.updatedSeries!
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: old, on: day(1)))
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: old, on: day(2)))
    }

    // MARK: - gh#126: "After N occurrences" counts the SPLIT-OFF series

    /// A daily `.afterCount` series anchored on the timeline fixture day, so a
    /// "this and following" split at day N has exactly N elapsed occurrences.
    private func afterCountDailySeries(id: String, count: Int) -> Event {
        var series = Event(
            id: UUID(uuidString: id)!,
            title: "Five times",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.repeatEndType = .afterCount
        series.repeatEndCount = count
        return series
    }

    /// The form data the edit sheet hands its save closure, with the sheet's
    /// `.following` time seed (the tapped occurrence, not the series seed day).
    private func editSheetForm(startingOn day: Date, count: Int?) -> CalendarEventFormData {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        return CalendarEventFormData(
            title: "New",
            typeTitle: "Study",
            note: "",
            location: "",
            startTime: start,
            endTime: start.addingTimeInterval(3600),
            isAllDay: false,
            repeatUnit: .day,
            repeatInterval: 1,
            repeatEndType: count == nil ? .none : .afterCount,
            repeatEndDate: nil,
            repeatEndCount: count,
            didExplicitlySelectType: true
        )
    }

    /// The seed: in a `.following` edit the tapped occurrence becomes the FIRST
    /// occurrence of a newly split series, so "After N occurrences" means N of
    /// that new series. Original 5, split at occurrence #3 (elapsed 2) → 3.
    /// Both surfaces read the one shared helper, and it is the same number the
    /// split actually persists.
    @MainActor
    func testFollowingScopeSeedsTheSplitOffRemainingCount() {
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        let split = cal.date(byAdding: .day, value: 2, to: day0)!  // occurrence #3
        let series = afterCountDailySeries(id: "12612600-0000-0000-0000-000000000001", count: 5)

        XCTAssertEqual(
            Event.splitOffRemainingCount(series: series, occurrenceDate: split), 3,
            "5 total − 2 elapsed = 3 remaining, starting at the tapped occurrence")

        // Scope-aware seed: only `.following` re-means the field.
        XCTAssertEqual(Event.scopedRepeatEndCount(series: series, occurrenceDate: split, requestedScope: .following), 3)
        XCTAssertEqual(Event.scopedRepeatEndCount(series: series, occurrenceDate: split, requestedScope: .all), 5)
        XCTAssertEqual(Event.scopedRepeatEndCount(series: series, occurrenceDate: split, requestedScope: .single), 5)
        XCTAssertEqual(
            Event.scopedRepeatEndCount(series: series, occurrenceDate: nil, requestedScope: nil), 5,
            "the plain non-recurring edit path still shows the event's own count")

        // Surface 1 — the full edit sheet, which knows its scope at construction.
        XCTAssertEqual(
            EditCalendarEventView.seededRepeatEndCount(event: series, occurrenceDate: split, recurrenceScope: .following),
            3)
        XCTAssertEqual(
            EditCalendarEventView.seededRepeatEndCount(event: series, occurrenceDate: split, recurrenceScope: .all),
            5)

        // Surface 2 — the rule editor, whose scope changes live, so it holds
        // BOTH meanings side by side.
        let counts = CalendarRecurrenceRuleEditor.ScopedEndCount(series: series, occurrenceDate: split)
        XCTAssertEqual(counts.value(following: true), 3)
        XCTAssertEqual(counts.value(following: false), 5)

        // WYSIWYG: the seed is exactly what the split writes.
        let result = Event.applyEdit(series: series, occurrenceDate: split, scope: .following) { _ in }
        XCTAssertEqual(result.newSeries?.repeatEndCount, 3, "displayed seed == persisted count")
    }

    /// Edit sheet arithmetic, driven through the real `CalendarEventFormData`
    /// apply the save closure uses: untouched / step up / step down / set to 1.
    @MainActor
    func testEditSheetFollowingCountArithmetic() {
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day0)! }
        let split = day(2)
        let series = afterCountDailySeries(id: "12612600-0000-0000-0000-000000000002", count: 5)

        let seed = EditCalendarEventView.seededRepeatEndCount(
            event: series, occurrenceDate: split, recurrenceScope: .following)
        XCTAssertEqual(seed, 3, "the stepper opens on the remaining count")

        // The sheet's `.following` save: applyEdit splits, then form.apply
        // re-stamps the field the user actually saw.
        func save(stepper: Int) -> Event {
            Event.applyEdit(
                series: series,
                occurrenceDate: split,
                scope: .following,
                edit: EditCalendarEventView.recurringEdit(
                    form: editSheetForm(startingOn: split, count: stepper),
                    scope: .following,
                    occurrenceDate: split
                )
            ).newSeries!
        }

        XCTAssertEqual(save(stepper: 3).repeatEndCount, 3, "untouched → 3")
        XCTAssertEqual(save(stepper: 4).repeatEndCount, 4, "step up → 4")
        XCTAssertEqual(save(stepper: 2).repeatEndCount, 2, "step down → 2")
        XCTAssertEqual(save(stepper: 1).repeatEndCount, 1, "set to 1 → 1")

        // What those counts mean on the canvas.
        let untouched = save(stepper: 3)
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: untouched, on: day(4)), "third remaining occurrence renders")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: untouched, on: day(5)), "no phantom fourth")
        let steppedUp = save(stepper: 4)
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: steppedUp, on: day(5)), "one step up adds exactly one occurrence")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: steppedUp, on: day(6)))
        let onlyThisOne = save(stepper: 1)
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: onlyThisOne, on: day(2)))
        XCTAssertNil(
            CalendarLayout.recurrenceOccurrence(for: onlyThisOne, on: day(3)),
            "set to 1 → only the selected occurrence remains in the new series")
    }

    /// gh#126 regression — FAILS on pre-fix code by construction.
    ///
    /// Pre-fix the sheet seeded the ORIGINAL whole-series N (5) while a
    /// value-equality guard re-applied `applyEdit`'s remaining 3 only while the
    /// field still equalled that seed. So the rendered count was non-monotonic
    /// around the seed: stepper 4 / 5 / 6 → 4 / 3 / 6 (one step DOWN raised it,
    /// one step UP doubled it, and every touched value over-rendered). Now the
    /// field means what it says, so the persisted count tracks the stepper 1:1.
    @MainActor
    func testFollowingCountIsMonotonicAroundTheSeed() {
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        let split = cal.date(byAdding: .day, value: 2, to: day0)!
        let series = afterCountDailySeries(id: "12612600-0000-0000-0000-000000000003", count: 5)

        func save(stepper: Int) -> Int? {
            Event.applyEdit(
                series: series,
                occurrenceDate: split,
                scope: .following,
                edit: EditCalendarEventView.recurringEdit(
                    form: editSheetForm(startingOn: split, count: stepper),
                    scope: .following,
                    occurrenceDate: split
                )
            ).newSeries?.repeatEndCount
        }

        // The documented pre-fix triple: these three raw stepper values rendered
        // 4 / 3 / 6. They now mean what they say.
        XCTAssertEqual([4, 5, 6].map(save), [4, 5, 6], "no equality exception hiding in the middle value")

        // And around whatever the field actually seeds with, ±1 is ±1.
        let seed = EditCalendarEventView.seededRepeatEndCount(
            event: series, occurrenceDate: split, recurrenceScope: .following)!
        for delta in [-1, 0, 1] {
            XCTAssertEqual(
                save(stepper: seed + delta), seed + delta,
                "stepping \(delta) from the seed \(seed) must move the persisted count by \(delta)")
        }
    }

    /// The rule editor changes scope LIVE via the "Apply to" picker, so its
    /// count is scope-specific state: flipping the picker swaps which meaning is
    /// shown and never leaks one number into the other.
    @MainActor
    func testRuleEditorScopedCountDoesNotLeakBetweenScopes() {
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        let split = cal.date(byAdding: .day, value: 2, to: day0)!
        let series = afterCountDailySeries(id: "12612600-0000-0000-0000-000000000004", count: 5)

        var counts = CalendarRecurrenceRuleEditor.ScopedEndCount(series: series, occurrenceDate: split)
        XCTAssertEqual(counts.all, 5, "All events → the whole series' total")
        XCTAssertEqual(counts.following, 3, "This and following → the split-off series' remaining")

        // Nudge in "This and following"; switch back to "All events".
        counts.set(4, following: true)
        XCTAssertEqual(counts.value(following: true), 4)
        XCTAssertEqual(counts.value(following: false), 5, "the whole-series meaning is untouched")

        // Nudge in "All events"; switch back to "This and following".
        counts.set(9, following: false)
        XCTAssertEqual(counts.value(following: false), 9)
        XCTAssertEqual(counts.value(following: true), 4, "the following count survives the round trip")
    }

    /// Rule editor arithmetic, driven through the pure save mutation the sheet
    /// hands `applyRecurringEdit` — same seed / step up / step down / set-to-1
    /// answers as the edit sheet, and `.all` still writes the whole-series N.
    @MainActor
    func testRuleEditorFollowingSaveWritesTheSteppedRemainingCount() {
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day0)! }
        let split = day(2)
        let series = afterCountDailySeries(id: "12612600-0000-0000-0000-000000000005", count: 5)

        // The stepper only moves the count, so the end SHAPE is untouched — the
        // branch that used to hide the decrement behind a value comparison.
        func save(stepper: Int, scope: Event.RecurrenceEditScope) -> Event {
            let edit = CalendarRecurrenceRuleEditor.ruleEdit(
                repeatUnit: .day,
                repeatInterval: 1,
                repeatEndType: .afterCount,
                repeatEndDate: split,
                endCount: stepper,
                scope: scope,
                endShapeChanged: false
            )
            let result = Event.applyEdit(series: series, occurrenceDate: split, scope: scope, edit: edit)
            return scope == .following ? result.newSeries! : result.updatedSeries!
        }

        let seeds = CalendarRecurrenceRuleEditor.ScopedEndCount(series: series, occurrenceDate: split)
        XCTAssertEqual(save(stepper: seeds.following, scope: .following).repeatEndCount, 3, "untouched → 3")
        XCTAssertEqual(save(stepper: 4, scope: .following).repeatEndCount, 4, "step up → 4")
        XCTAssertEqual(save(stepper: 2, scope: .following).repeatEndCount, 2, "step down → 2")

        let onlyThisOne = save(stepper: 1, scope: .following)
        XCTAssertEqual(onlyThisOne.repeatEndCount, 1)
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: onlyThisOne, on: day(2)))
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: onlyThisOne, on: day(3)))

        // Parity: both surfaces answer the same for the same user gesture.
        let sheetStepUp = Event.applyEdit(
            series: series,
            occurrenceDate: split,
            scope: .following,
            edit: EditCalendarEventView.recurringEdit(
                form: editSheetForm(startingOn: split, count: 4),
                scope: .following,
                occurrenceDate: split
            )
        ).newSeries!
        XCTAssertEqual(
            sheetStepUp.repeatEndCount, save(stepper: 4, scope: .following).repeatEndCount,
            "edit sheet and rule editor must agree")

        // `.all` is unchanged: the field there is still the whole series' total.
        XCTAssertEqual(save(stepper: seeds.all, scope: .all).repeatEndCount, 5, "All events untouched → 5")
        XCTAssertEqual(save(stepper: 6, scope: .all).repeatEndCount, 6, "All events step up → 6 total")
    }

    /// Composes with gh#124: from the FIRST occurrence, `.following` is coerced
    /// to `.all`, so the field means the original total again. Routed through
    /// `resolvedRecurrenceEditScope` — not a separate `elapsed == 0` branch.
    @MainActor
    func testFirstOccurrenceFollowingSeedIsTheOriginalTotal() {
        let day0 = makeTimelineDate(hour: 0, minute: 0)  // the series' seed day
        let series = afterCountDailySeries(id: "12612600-0000-0000-0000-000000000006", count: 5)

        XCTAssertEqual(
            Event.resolvedRecurrenceEditScope(requested: .following, series: series, occurrenceDate: day0),
            .all, "gh#124 precondition")
        XCTAssertEqual(
            Event.scopedRepeatEndCount(series: series, occurrenceDate: day0, requestedScope: .following), 5,
            "a coerced `.all` edits the whole series, so the field is the total")
        XCTAssertEqual(
            EditCalendarEventView.seededRepeatEndCount(event: series, occurrenceDate: day0, recurrenceScope: .following),
            5)
        let counts = CalendarRecurrenceRuleEditor.ScopedEndCount(series: series, occurrenceDate: day0)
        XCTAssertEqual(counts.all, 5)
        XCTAssertEqual(counts.following, 5, "elapsed == 0 → the two meanings coincide")
        XCTAssertFalse(
            CalendarRecurrenceRuleEditor.canApplyFollowing(series: series, occurrenceDate: day0),
            "and the split isn't even offered there")
    }

    /// The seed uses the same REALIZED-occurrence index as the split, so a
    /// monthly series whose steps land on nonexistent dates agrees with what
    /// renders. Jan 31 monthly ×5 realizes Jan 31 / Mar 31 / May 31 / Jul 31 /
    /// Aug 31 — splitting at Jul 31 leaves 2, not the 5 − 6 calendar months a
    /// naive elapsed would compute.
    @MainActor
    func testMonthlySeedCountsRealizedOccurrencesLikeTheSplit() {
        let seed = recurrenceDate(2026, 1, 31)
        var series = Event(
            id: UUID(uuidString: "12612600-0000-0000-0000-000000000007")!,
            title: "Month end",
            timeRanges: [Event.TimeRange(start: seed, end: seed.addingTimeInterval(3600))],
            repeatUnit: .month,
            repeatInterval: 1,
            type: "Study"
        )
        series.repeatEndType = .afterCount
        series.repeatEndCount = 5
        let split = recurrenceDate(2026, 7, 31)  // realized occurrence index 3

        XCTAssertEqual(
            Event.splitOffRemainingCount(series: series, occurrenceDate: split), 2,
            "Feb/Apr/Jun are skipped steps and must not consume the count")
        XCTAssertEqual(
            EditCalendarEventView.seededRepeatEndCount(event: series, occurrenceDate: split, recurrenceScope: .following),
            2)
        XCTAssertEqual(
            CalendarRecurrenceRuleEditor.ScopedEndCount(series: series, occurrenceDate: split).following, 2)

        let newSeries = Event.applyEdit(series: series, occurrenceDate: split, scope: .following) { _ in }.newSeries!
        XCTAssertEqual(newSeries.repeatEndCount, 2, "seed == what the split persists")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: newSeries, on: recurrenceDate(2026, 8, 31)))
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: newSeries, on: recurrenceDate(2026, 10, 31)))
    }

    /// Bug fix: exceptions and `.following` split-siblings inherit the parent's
    /// image refs BY VALUE (same files on disk). Asset purge on delete must be
    /// ref-counted so deleting one never erases a file a survivor still shows.
    @MainActor
    func testOrphanedImageRefsPreservesSharedInheritedFiles() {
        let shared = AgenticIntakeImageRef(relativePath: "A/img1.jpg", pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1)
        let ownB = AgenticIntakeImageRef(relativePath: "B/img2.jpg", pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1)
        let aID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let bID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
        var a = Event(id: aID, title: "A", timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)], type: "Study")
        a.agenticIntake = AgenticIntakeRecord(rawText: "", images: [shared], source: .classicFallback)
        var b = Event(id: bID, title: "B", timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)], type: "Study")
        b.agenticIntake = AgenticIntakeRecord(rawText: "", images: [shared, ownB], source: .classicFallback)

        // Delete B → only B's own file orphans; the shared file A still uses is kept.
        XCTAssertEqual(
            EventStore.orphanedImageRefs(deleting: [bID], from: [a, b]).map(\.relativePath),
            ["B/img2.jpg"]
        )
        // Delete A → its only file is still used by B, so nothing orphans.
        XCTAssertTrue(EventStore.orphanedImageRefs(deleting: [aID], from: [a, b]).isEmpty)
        // Delete both → everything orphans.
        XCTAssertEqual(
            Set(EventStore.orphanedImageRefs(deleting: [aID, bID], from: [a, b]).map(\.relativePath)),
            ["A/img1.jpg", "B/img2.jpg"]
        )
    }

    /// "This and following" re-homes days ≥ split onto the new series: their days
    /// are excepted on it (no double-render vs a default occurrence), the
    /// materialized exceptions are re-parented to it, and a bare skip is carried;
    /// days BEFORE the split stay on the old series.
    @MainActor
    func testEditFollowingRehomesCustomizedDaysToNewSeries() {
        let suiteName = "CalendarDragLogicTests.editFollowingReparent"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day0)! }
        let series = Event(
            id: UUID(uuidString: "77777777-8888-8888-8888-888888888888")!,
            title: "Daily",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        // Customize day1 (before the split, stays) and day5 (>= split, carried).
        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(1), scope: .single) { $0.type = "A" }
        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(5), scope: .single) { $0.type = "B" }
        // Delete day4 — a bare skip (exception date, no materialized instance), >= split.
        store.deleteRecurringCalendarEvent(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(4), scope: .single)

        // Edit "this and following" from day3.
        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(3), scope: .following) { $0.title = "New" }

        let newSeries = store.rawCalendarEvents.first { $0.isRecurringSeries && $0.id != series.id }
        XCTAssertNotNil(newSeries, "a split-off series exists")
        func exception(on date: Date) -> Event? {
            store.rawCalendarEvents.first { $0.recurrenceInstanceDate.map { cal.isDate($0, inSameDayAs: date) } ?? false }
        }
        // The new series excepts day5 so it won't double-render a default
        // occurrence on top of the customized day's standalone exception.
        XCTAssertTrue(newSeries?.recurrenceExceptionDates.contains { cal.isDate($0, inSameDayAs: day(5)) } ?? false)
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: newSeries!, on: day(5)), "no default occurrence on the customized day")
        // The bare skip on day4 is carried too, so a deleted occurrence doesn't reappear.
        XCTAssertTrue(newSeries?.recurrenceExceptionDates.contains { cal.isDate($0, inSameDayAs: day(4)) } ?? false)
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: newSeries!, on: day(4)), "deleted day stays deleted after the split")
        // day5 (≥ split) is re-parented to the new series; day1 (< split) stays
        // on the old series.
        XCTAssertEqual(exception(on: day(5))?.recurrenceParentId, newSeries?.id)
        XCTAssertEqual(exception(on: day(1))?.recurrenceParentId, series.id)
    }

    /// Option A: a "this and following" edit migrates a day's occurrence RECORDS
    /// (logs/feedback) and INTERRUPT relations onto the new series, so nothing
    /// keyed to the old series id detaches for days ≥ split.
    @MainActor
    func testEditFollowingMigratesOccurrenceRecordsAndInterrupts() {
        let suiteName = "CalendarDragLogicTests.editFollowingMigrate"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day0)! }
        let series = Event(
            id: UUID(uuidString: "CCCCCCCC-2222-2222-2222-222222222222")!,
            title: "Daily",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        // A logged note + an interrupt on day5 (≥ split), both keyed to the series.
        let occ5 = CalendarEventOccurrenceContext(eventID: series.id, occurrenceDate: day(5), occurrenceID: nil, isAllDay: false, source: .timelineTap)
        store.upsertLogRecord(for: occ5) { $0.note = "day5 note" }
        // Interrupt time range must fall on day5 (within the parent occurrence),
        // or createInterrupt's clamp collapses it to nothing.
        let iStart = Event.dateByCombining(day: day(5), timeFrom: makeTimelineDate(hour: 9, minute: 15), calendar: cal)
        let iEnd = Event.dateByCombining(day: day(5), timeFrom: makeTimelineDate(hour: 9, minute: 30), calendar: cal)
        _ = store.createInterrupt(parentEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(5), title: "Interrupt", timeRange: Event.TimeRange(start: iStart, end: iEnd))
        // A note on day1 (< split) that MUST stay on the old series.
        let occ1 = CalendarEventOccurrenceContext(eventID: series.id, occurrenceDate: day(1), occurrenceID: nil, isAllDay: false, source: .timelineTap)
        store.upsertLogRecord(for: occ1) { $0.note = "day1 note" }

        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(3), scope: .following) { $0.title = "New" }
        let newSeries = store.rawCalendarEvents.first { $0.isRecurringSeries && $0.id != series.id }
        XCTAssertNotNil(newSeries)

        // The day5 log record followed to the new series (history didn't detach) —
        // both the mirror field and the identity key are re-homed.
        let rec = store.calendarEventLogRecords.first { cal.isDate($0.occurrenceDate, inSameDayAs: day(5)) }
        XCTAssertEqual(rec?.note, "day5 note")
        XCTAssertEqual(rec?.baseSeriesEventID, newSeries?.id)
        XCTAssertEqual(rec?.id.baseSeriesEventID, newSeries?.id)
        // The interrupt on day5 re-anchored to the new series.
        let interruptChild = store.rawCalendarEvents.first {
            $0.interruptRelation.map { cal.isDate($0.occurrenceDate, inSameDayAs: day(5)) } ?? false
        }
        XCTAssertEqual(interruptChild?.interruptRelation?.parentEventID, newSeries?.id)
        // The day1 note (< split) stayed on the OLD series — the onOrAfter filter
        // is respected, not a blanket re-home.
        let recBefore = store.calendarEventLogRecords.first { cal.isDate($0.occurrenceDate, inSameDayAs: day(1)) }
        XCTAssertEqual(recBefore?.note, "day1 note")
        XCTAssertEqual(recBefore?.baseSeriesEventID, series.id)
    }

    // MARK: - COMMIT 2 (gh#124): "this and following" from the FIRST occurrence

    /// The pure resolver: a `.following` from the series' first realized
    /// occurrence collapses to `.all`; a later occurrence stays `.following`;
    /// other scopes pass through untouched.
    @MainActor
    func testResolvedRecurrenceEditScopeCollapsesFirstOccurrenceFollowing() {
        let series = Event(
            id: UUID(uuidString: "12121212-0000-0000-0000-000000000009")!,
            title: "Weekly",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .week,
            repeatInterval: 1,
            type: "Study"
        )
        let seedDay = makeTimelineDate(hour: 0, minute: 0)
        let cal = Calendar.current

        XCTAssertEqual(
            Event.resolvedRecurrenceEditScope(requested: .following, series: series, occurrenceDate: seedDay),
            .all, "first occurrence collapses to .all")
        let week1 = cal.date(byAdding: .day, value: 7, to: seedDay)!
        XCTAssertEqual(
            Event.resolvedRecurrenceEditScope(requested: .following, series: series, occurrenceDate: week1),
            .following, "a later occurrence stays .following")
        XCTAssertEqual(
            Event.resolvedRecurrenceEditScope(requested: .single, series: series, occurrenceDate: seedDay),
            .single, ".single passes through")
        XCTAssertEqual(
            Event.resolvedRecurrenceEditScope(requested: .all, series: series, occurrenceDate: seedDay),
            .all, ".all passes through")
    }

    /// A first-occurrence `.following` EDIT must resolve to `.all`: the original
    /// series is edited in place — no duplicate series minted, and the old
    /// series is not zombie-capped to `seriesStart − 1`.
    @MainActor
    func testFollowingEditFromFirstOccurrenceResolvesToAll() {
        let suiteName = "CalendarDragLogicTests.followingFirstOccEdit"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let cal = Calendar.current
        let seedDay = makeTimelineDate(hour: 0, minute: 0)  // the series start day
        let series = Event(
            id: UUID(uuidString: "12121212-0000-0000-0000-000000000001")!,
            title: "Daily",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: seedDay, scope: .following) { $0.title = "Renamed" }

        let seriesList = store.rawCalendarEvents.filter { $0.isRecurringSeries }
        XCTAssertEqual(seriesList.count, 1, "no duplicate series minted")
        let edited = store.findCalendarEvent(id: series.id)
        XCTAssertEqual(edited?.title, "Renamed", "the original series is edited in place")
        XCTAssertNil(edited?.repeatEndDate, "old series not zombie-capped to seriesStart-1")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: edited!, on: seedDay), "seed day still renders")
        let nextDay = cal.date(byAdding: .day, value: 1, to: seedDay)!
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: edited!, on: nextDay), "series still recurs after the split day")
    }

    /// A first-occurrence `.following` DELETE must resolve to `.all`: the series
    /// is fully removed, leaving nothing in the recurring-series list — not a
    /// zombie capped to `seriesStart − 1`.
    @MainActor
    func testFollowingDeleteFromFirstOccurrenceResolvesToAll() {
        let suiteName = "CalendarDragLogicTests.followingFirstOccDelete"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let seedDay = makeTimelineDate(hour: 0, minute: 0)
        let series = Event(
            id: UUID(uuidString: "12121212-0000-0000-0000-000000000002")!,
            title: "Daily",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        store.deleteRecurringCalendarEvent(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: seedDay, scope: .following)

        XCTAssertNil(store.findCalendarEvent(id: series.id), "series fully removed")
        XCTAssertTrue(store.rawCalendarEvents.filter { $0.isRecurringSeries }.isEmpty, "nothing left in the recurring-series list")
    }

    /// A mid-series `.following` (index > 0) is unaffected — it still splits the
    /// series in two the way it always did.
    @MainActor
    func testFollowingEditFromMidSeriesStillSplits() {
        let suiteName = "CalendarDragLogicTests.followingMidSplit"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let cal = Calendar.current
        let seedDay = makeTimelineDate(hour: 0, minute: 0)
        let day3 = cal.date(byAdding: .day, value: 3, to: seedDay)!
        let series = Event(
            id: UUID(uuidString: "12121212-0000-0000-0000-000000000003")!,
            title: "Daily",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day3, scope: .following) { $0.title = "New" }

        let seriesList = store.rawCalendarEvents.filter { $0.isRecurringSeries }
        XCTAssertEqual(seriesList.count, 2, "mid-series following splits into two series")
        // Old series capped before the split; new series carries the edit.
        let old = store.findCalendarEvent(id: series.id)
        XCTAssertEqual(old?.repeatEndType, .onDate, "old series capped at the split boundary")
        let newSeries = store.rawCalendarEvents.first { $0.isRecurringSeries && $0.id != series.id }
        XCTAssertEqual(newSeries?.title, "New", "new split series carries the edit")
    }

    /// The rule editor's "This and future" gate must be DEFINED by the store's
    /// scope resolver, not by a parallel day comparison. The resolver is
    /// occurrence-INDEX based, so a weekly series' off-pattern days +1…+6
    /// (reachable via Manage Repeat opened from a detached exception whose day
    /// was moved off-pattern) sit AFTER the seed day but still at occurrence
    /// index 0: the old `occurrenceDate > seriesStart` gate offered "This and
    /// future" there while the store silently coerced the save to `.all` —
    /// the user's rule change rewrote the whole series, past included, with
    /// no split.
    @MainActor
    func testRuleEditorFollowingGateMatchesStoreResolver() {
        let cal = Calendar.current
        let seed = recurrenceDate(2026, 3, 1)
        let series = Event(
            id: UUID(uuidString: "12121212-0000-0000-0000-000000000004")!,
            title: "Weekly",
            timeRanges: [Event.TimeRange(start: seed, end: seed.addingTimeInterval(3600))],
            repeatUnit: .week,
            repeatInterval: 1,
            type: "Study"
        )

        for offset in 0...14 {
            let day = cal.date(byAdding: .day, value: offset, to: seed)!
            let gate = CalendarRecurrenceRuleEditor.canApplyFollowing(series: series, occurrenceDate: day)
            let resolved = Event.resolvedRecurrenceEditScope(requested: .following, series: series, occurrenceDate: day)
            XCTAssertEqual(gate, resolved == .following,
                           "gate and store resolver must agree at day offset \(offset) — the editor may only OFFER what the store will EXECUTE")
            XCTAssertEqual(gate, offset >= 7,
                           "weekly series: days +1…+6 are occurrence index 0 and must not offer a split (offset \(offset))")
        }

        // A non-recurring event never offers "This and future".
        let single = Event(
            id: UUID(uuidString: "12121212-0000-0000-0000-000000000005")!,
            title: "Once",
            timeRanges: [Event.TimeRange(start: seed, end: seed.addingTimeInterval(3600))],
            type: "Study"
        )
        XCTAssertFalse(CalendarRecurrenceRuleEditor.canApplyFollowing(series: single, occurrenceDate: seed))
    }

    // MARK: - COMMIT 3 (gh#127-item5): reindex keys off the frozen dayKey

    /// Builds a log record exactly the way the app does: identity through the
    /// production `CalendarOccurrenceKey.make`, with the `occurrenceDate`
    /// mirror carrying the key's reference-tz midnight (the shape sync-restored
    /// and legacy records hold). No hand-assembled key/date combinations —
    /// gh#127-item5's original regression test was rejected for pairing a
    /// `dayKey` with an `occurrenceDate` that `make` can never co-produce.
    @MainActor
    private func productionLogRecord(
        series: Event,
        occurrenceDate: Date,
        note: String
    ) -> CalendarEventLogRecord {
        let key = CalendarOccurrenceKey.make(for: series, occurrenceDate: occurrenceDate)
        return CalendarEventLogRecord(
            id: key,
            eventID: key.eventID,
            baseSeriesEventID: key.baseSeriesEventID,
            occurrenceDate: key.occurrenceDate,
            note: note
        )
    }

    /// The `.following` record migration must classify records in the SAME
    /// frame record lookups use: each record's frozen
    /// `CalendarOccurrenceKey.dayKey` against the ref-tz key of the split day's
    /// CURRENT-tz midnight. Records are minted through the production `make`
    /// on the canvas' `startOfDay` dates, under a reference tz (Pacific/Apia,
    /// UTC+13) pinned far from the host tz; the split is issued with a MID-DAY
    /// occurrence instant. Without normalizing the threshold to the split
    /// day's current-tz midnight, the mid-day instant's ref-tz projection
    /// crosses Apia midnight (on hosts west of UTC+4) and lands the threshold
    /// a day late: the split-day record then stays on the capped old series
    /// while its rendered day moves to the new one — and the one lookup that
    /// finds it goes dark.
    @MainActor
    func testReindexMovesBoundaryRecordMintedByProductionKey() {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "Pacific/Apia")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }

        let suiteName = "CalendarDragLogicTests.reindexDayKey"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let cal = Calendar.current
        func hostDay(_ d: Int, hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 3, day: d, hour: hour))! }
        func hostMidnight(_ d: Int) -> Date { cal.startOfDay(for: hostDay(d, hour: 12)) }

        // Series starts day 10, so a day-13 split is mid-series (index 3 > 0):
        // it actually splits (the gh#124 first-occurrence collapse won't fire).
        let series = Event(
            id: UUID(uuidString: "13131313-0000-0000-0000-000000000001")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: hostDay(10, hour: 9), end: hostDay(10, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)

        store.calendarEventLogRecords = [
            productionLogRecord(series: series, occurrenceDate: hostMidnight(12), note: "before"),
            productionLogRecord(series: series, occurrenceDate: hostMidnight(13), note: "boundary"),
            productionLogRecord(series: series, occurrenceDate: hostMidnight(14), note: "after"),
        ]

        // Split at the occurrence's mid-day instant, not a pre-normalized
        // midnight — the store must do its own startOfDay before keying.
        store.applyRecurringEdit(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: hostDay(13, hour: 12), scope: .following) { $0.title = "New" }
        let newSeries = store.rawCalendarEvents.first { $0.isRecurringSeries && $0.id != series.id }
        XCTAssertNotNil(newSeries, "a split-off series exists")

        func owner(_ note: String) -> UUID? {
            store.calendarEventLogRecords.first { $0.note == note }?.baseSeriesEventID
        }
        XCTAssertEqual(owner("before"), series.id, "a before-split record stays on the old series")
        XCTAssertEqual(owner("boundary"), newSeries?.id, "the split-day record follows its day onto the new series")
        XCTAssertEqual(owner("after"), newSeries?.id, "an after-split record follows onto the new series")

        // The invariant the frame choice protects: every rendered day still
        // FINDS its record via the same `make` lookup the canvas runs,
        // against the series that serves that day post-split.
        let beforeKey = CalendarOccurrenceKey.make(for: store.findCalendarEvent(id: series.id)!, occurrenceDate: hostMidnight(12))
        XCTAssertEqual(store.calendarEventLogRecords.first { $0.id == beforeKey }?.note, "before",
                       "day 12's lookup still hits on the old series")
        let boundaryKey = CalendarOccurrenceKey.make(for: newSeries!, occurrenceDate: hostMidnight(13))
        XCTAssertEqual(store.calendarEventLogRecords.first { $0.id == boundaryKey }?.note, "boundary",
                       "day 13's lookup hits on the NEW series — the record moved with its day")
    }

    /// delete-`.following` and edit-`.following` must classify the SAME
    /// boundary record identically. The prune used to compare the record's
    /// wall-clock `occurrenceDate` (a reference-tz midnight on sync-restored /
    /// legacy records) against a `Calendar.current` day — which drifts by a
    /// day whenever the frozen reference tz and the device tz disagree, so a
    /// record the split would migrate survived its own deletion as a dangling
    /// history row. Both scopes now classify by the frozen `dayKey`, the same
    /// frame `reindexOccurrenceRecords` uses.
    @MainActor
    func testDeleteFollowingPruneAgreesWithReindexBoundary() {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "Pacific/Apia")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }

        let cal = Calendar.current
        func hostDay(_ d: Int, hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 3, day: d, hour: hour))! }
        func hostMidnight(_ d: Int) -> Date { cal.startOfDay(for: hostDay(d, hour: 12)) }

        let series = Event(
            id: UUID(uuidString: "13131313-0000-0000-0000-000000000002")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: hostDay(10, hour: 9), end: hostDay(10, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        let records = [
            productionLogRecord(series: series, occurrenceDate: hostMidnight(12), note: "before"),
            productionLogRecord(series: series, occurrenceDate: hostMidnight(13), note: "boundary"),
            productionLogRecord(series: series, occurrenceDate: hostMidnight(14), note: "after"),
        ]

        let followingSurvivors = EventStore.recordsSurviving(
            records,
            afterDeletingSeries: series,
            occurrenceDate: hostDay(13, hour: 12),
            scope: .following
        )
        XCTAssertEqual(followingSurvivors?.map(\.note), ["before"],
                       "delete-following prunes the boundary record the split reindex would migrate — not just the days after it")

        let singleSurvivors = EventStore.recordsSurviving(
            records,
            afterDeletingSeries: series,
            occurrenceDate: hostDay(13, hour: 12),
            scope: .single
        )
        XCTAssertEqual(singleSurvivors?.map(\.note), ["before", "after"],
                       "delete-single prunes exactly the boundary day's record")
    }

    // MARK: - COMMIT 4 (gh#127-item4): split must not copy partner-link ids

    /// A recurrence split copies the whole series, but the one-to-one partner
    /// links (`linkedCalendarEventId` / `linkedTodoEventId`) must NOT ride
    /// along — a duplicate would forge a second, false owner of the same
    /// partner. Both the `.single` exception instance and the `.following` new
    /// series clear them; the original is untouched.
    ///
    /// `absorbedIntoEventID` is the opposite: it MUST survive the copy. The
    /// recurring-todo absorption invariant is an OPEN decision (gh#127 third
    /// audit approved clearing only the two partner links), and clearing the
    /// absorption ref would flip `isCanvasRenderable` on the copy — a `.single`
    /// edit of an absorbed recurring todo's occurrence would pop that day out
    /// of its absorbing parent onto the canvas. This test locks the
    /// keep-until-decided behavior.
    @MainActor
    func testRecurrenceSplitDropsPartnerLinkIds() {
        let cal = Calendar.current
        let day0 = makeTimelineDate(hour: 0, minute: 0)
        let day2 = cal.date(byAdding: .day, value: 2, to: day0)!
        let linkedCal = UUID()
        let linkedTodo = UUID()
        let absorbedParent = UUID()
        var series = Event(
            id: UUID(uuidString: "14141414-0000-0000-0000-000000000001")!,
            title: "Daily",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.linkedCalendarEventId = linkedCal
        series.linkedTodoEventId = linkedTodo
        series.absorbedIntoEventID = absorbedParent

        let instance = Event.applyEdit(series: series, occurrenceDate: day2, scope: .single) { _ in }.exceptionInstance
        XCTAssertNotNil(instance)
        XCTAssertNil(instance?.linkedCalendarEventId, ".single exception drops the calendar partner link")
        XCTAssertNil(instance?.linkedTodoEventId, ".single exception drops the todo partner link")
        XCTAssertEqual(instance?.absorbedIntoEventID, absorbedParent,
                       ".single exception KEEPS the absorption ref — clearing it would pop the day out of its absorbing parent (open invariant, gh#127 third audit)")

        let newSeries = Event.applyEdit(series: series, occurrenceDate: day2, scope: .following) { _ in }.newSeries
        XCTAssertNotNil(newSeries)
        XCTAssertNil(newSeries?.linkedCalendarEventId, ".following new series drops the calendar partner link")
        XCTAssertNil(newSeries?.linkedTodoEventId, ".following new series drops the todo partner link")
        XCTAssertEqual(newSeries?.absorbedIntoEventID, absorbedParent,
                       ".following new series KEEPS the absorption ref — the tail inherits the series' absorption state until the invariant is decided")

        // The original series keeps its own links — only the copies are cleared.
        XCTAssertEqual(series.linkedCalendarEventId, linkedCal)
        XCTAssertEqual(series.linkedTodoEventId, linkedTodo)
        XCTAssertEqual(series.absorbedIntoEventID, absorbedParent)
    }

    // MARK: - gh#127 item 1: exception day-key identity survives time-zone changes

    /// THE item-1 repro. An exception minted under UTC+13 (Pacific/Apia) and
    /// read under UTC−5 (New York) used to re-bucket: the stored absolute
    /// midnight reads as the PREVIOUS local day through the new calendar, so
    /// the suppressed day reappeared (a duplicate beside its detached
    /// replacement) while the adjacent day was wrongly suppressed (a hole).
    /// Day-key identity makes the suppression nominal — this test fails on
    /// the pre-fix `isDate(_:inSameDayAs:)` read.
    @MainActor
    func testExceptionCreatedFarEastStillSuppressesReadFarWest() {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "UTC")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }

        var calA = Calendar(identifier: .gregorian)
        calA.timeZone = TimeZone(identifier: "Pacific/Apia")!      // UTC+13
        var calB = Calendar(identifier: .gregorian)
        calB.timeZone = TimeZone(identifier: "America/New_York")!  // UTC−5 (EDT −4)

        func dayA(_ d: Int, hour: Int) -> Date { calA.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func dayB(_ d: Int) -> Date { calB.date(from: DateComponents(year: 2026, month: 8, day: d))! }

        let series = Event(
            id: UUID(uuidString: "17171717-0000-0000-0000-000000000001")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: dayA(3, hour: 9), end: dayA(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )

        // Under tz A: detach Aug 10 (.single edit at the occurrence's own instant).
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: dayA(10, hour: 9),
            scope: .single,
            edit: { $0.title = "Moved" },
            calendar: calA
        )
        let updatedSeries = result.updatedSeries
        XCTAssertNotNil(updatedSeries)
        XCTAssertEqual(updatedSeries?.recurrenceExceptionDayKeys, [20_260_810],
                       "the exception is the NOMINAL day Aug 10, keyed in the calendar that named it")
        XCTAssertEqual(updatedSeries?.recurrenceExceptionDates.count, 1,
                       "the legacy mirror date is written in step (rollback net)")

        // Read under tz B: still suppressed, no duplicate...
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: updatedSeries!, on: dayB(10), calendar: calB),
                     "Aug 10 stays suppressed after the tz change — the pre-fix read re-buckets the stored midnight to Aug 9 and lets the occurrence reappear")
        // ...and no hole on the neighbors.
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: updatedSeries!, on: dayB(9), calendar: calB),
                        "Aug 9 still renders — pre-fix it went dark (the hole beside the duplicate)")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: updatedSeries!, on: dayB(11), calendar: calB),
                        "Aug 11 still renders")
        // Sanity: the home-zone read is unchanged.
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: updatedSeries!, on: calA.startOfDay(for: dayA(10, hour: 9)), calendar: calA))

        // The detached replacement still exists exactly once. Its STORED
        // range keeps the absolute creation instant (never rewritten — the
        // rollback net), but the canvas places it by `renderTimeRanges`,
        // which pins it to the same nominal day the suppression key names —
        // the composed-canvas pairing is pinned in
        // `testComposedCanvasPairsReplacementWithSuppressedDayAcrossTimeZones`.
        let instance = result.exceptionInstance
        XCTAssertNotNil(instance)
        XCTAssertEqual(instance?.recurrenceParentId, series.id)
        XCTAssertEqual(instance?.recurrenceInstanceDayKey, 20_260_810,
                       "the instance carries the SAME nominal day key its parent's exception holds")
        XCTAssertEqual(instance?.repeatUnit, Event.RepeatUnit.none)
        XCTAssertFalse(instance?.isRecurringSeries ?? true)
        XCTAssertEqual(instance?.primaryTimeRange?.start, dayA(10, hour: 9),
                       "the replacement keeps the occurrence's absolute instant in STORAGE")
    }

    /// Old-format blob (absolute dates only, no day-key field) must decode
    /// and suppress correctly, and the backfill must be DETERMINISTIC: the
    /// day keys are backfilled lazily at the decode seam via the frozen
    /// REFERENCE calendar — no eager rewrite, and never `Calendar.current`
    /// (review PROBE Q3/Q9: a current-frame backfill freezes whatever zone
    /// the user was passing through on migration day into a permanent
    /// identity, so an Apia-home user upgrading during a New York trip came
    /// home to a duplicate on the day they detached and a hole on the day
    /// before it, forever — the pre-migration `isDate` read at least healed
    /// on return).
    @MainActor
    func testLegacyExceptionBlobBackfillIsDeterministicViaFrozenReferenceCalendar() throws {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        // Home = first-launch zone = the zone the legacy midnights were
        // minted in (the no-travel-before-migration population).
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "Pacific/Apia")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }
        let priorDefaultTZ = NSTimeZone.default
        defer { NSTimeZone.default = priorDefaultTZ }

        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        func apiaDay(_ d: Int, hour: Int = 0) -> Date { apia.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        var series = Event(
            id: UUID(uuidString: "17171717-0000-0000-0000-000000000002")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: apiaDay(3, hour: 9), end: apiaDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.appendRecurrenceException(onDay: apiaDay(10), calendar: apia)

        // Strip the new fields to fake a blob written by a pre-migration build.
        let encoded = try JSONEncoder().encode(series)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(dict["recurrenceExceptionDayKeys"], "new blobs carry the day-key field")
        dict.removeValue(forKey: "recurrenceExceptionDayKeys")
        let legacyBlob = try JSONSerialization.data(withJSONObject: dict)

        // PROBE Q9: the upgrade/restore happens to run mid-trip in New York.
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let decodedTraveling = try JSONDecoder().decode(Event.self, from: legacyBlob)
        XCTAssertEqual(decodedTraveling.recurrenceExceptionDayKeys, [20_260_810],
                       "backfill reduces the mirror in the frozen home frame — a Calendar.current"
                       + " backfill would freeze 20260809 as the identity permanently")
        XCTAssertEqual(decodedTraveling.recurrenceExceptionDates, series.recurrenceExceptionDates,
                       "the legacy dates themselves are untouched (rollback net, GOTCHA 3)")

        // PROBE Q3: the same blob resolves to the same identity no matter
        // where the device sits when it decodes.
        NSTimeZone.default = TimeZone(identifier: "Pacific/Apia")!
        let decodedHome = try JSONDecoder().decode(Event.self, from: legacyBlob)
        XCTAssertEqual(decodedHome.recurrenceExceptionDayKeys,
                       decodedTraveling.recurrenceExceptionDayKeys,
                       "one blob, one identity, regardless of Calendar.current")

        // Back home, the canvas is what the user left: the detached day dark,
        // its neighbors intact — no duplicate on Aug 10, no hole on Aug 9.
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: decodedTraveling, on: apiaDay(10), calendar: apia),
                     "an old-format event still suppresses its exception day at home")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: decodedTraveling, on: apiaDay(9), calendar: apia))
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: decodedTraveling, on: apiaDay(11), calendar: apia))

        // The instance-day twin takes the same deterministic trip: a legacy
        // detached instance (mirror date, no key field) backfills to the
        // same nominal day its parent's exception key names.
        let instance = Event(
            id: UUID(uuidString: "17171717-0000-0000-0000-000000000005")!,
            title: "Moved",
            timeRanges: [Event.TimeRange(start: apiaDay(10, hour: 9), end: apiaDay(10, hour: 10))],
            type: "Study",
            recurrenceParentId: series.id,
            recurrenceInstanceDate: apia.startOfDay(for: apiaDay(10)),
            recurrenceInstanceDayKey: 20_260_810
        )
        var instanceDict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(instance)) as? [String: Any]
        )
        instanceDict.removeValue(forKey: "recurrenceInstanceDayKey")
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let decodedInstance = try JSONDecoder().decode(
            Event.self,
            from: JSONSerialization.data(withJSONObject: instanceDict)
        )
        XCTAssertEqual(decodedInstance.recurrenceInstanceDayKey, 20_260_810,
                       "the legacy instance mirror backfills in the same frozen frame as the exception")
    }

    /// Write-both pinned: every encode emits the legacy absolute dates AND
    /// the day keys, so a pre-migration build can still decode-and-suppress
    /// (it just ignores the unknown key) while this build reads keys only.
    @MainActor
    func testExceptionEncodingWritesBothLegacyDatesAndDayKeys() throws {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "UTC")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2026, month: 8, day: 10))!

        var series = Event(
            id: UUID(uuidString: "17171717-0000-0000-0000-000000000003")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(10 * 3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.appendRecurrenceException(onDay: day, calendar: utc)

        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(series)) as? [String: Any]
        )
        let dates = try XCTUnwrap(dict["recurrenceExceptionDates"] as? [Double],
                                  "legacy absolute-date field is still written")
        XCTAssertEqual(dates.count, 1)
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: dates[0]), utc.startOfDay(for: day),
                       "the legacy date is the same midnight a pre-migration writer would have stored")
        XCTAssertEqual(dict["recurrenceExceptionDayKeys"] as? [Int], [20_260_810],
                       "the day-key field is written alongside")
    }

    /// The precedence rule, pinned at its single source AND through the
    /// decode wiring: when both representations are present, the day keys ARE
    /// the identity and the legacy dates are ignored.
    @MainActor
    func testDayKeysOutrankLegacyDatesWhenBothPresent() throws {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "UTC")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func utcDay(_ d: Int, hour: Int = 0) -> Date { utc.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        // The rule itself — the one place both ingress seams resolve through.
        XCTAssertEqual(
            Event.resolvedRecurrenceExceptionDayKeys(dayKeys: [20_260_810], legacyDates: [utcDay(9)]),
            [20_260_810],
            "day keys present: they win, the dates are not consulted"
        )
        XCTAssertEqual(
            Event.resolvedRecurrenceExceptionDayKeys(dayKeys: nil, legacyDates: [utcDay(9)]),
            [20_260_809],
            "day keys absent: backfill from the dates via the frozen reference calendar (UTC here)"
        )

        // And through decode: a blob whose date says Aug 9 but whose key says
        // Aug 10 suppresses Aug 10, not Aug 9.
        var series = Event(
            id: UUID(uuidString: "17171717-0000-0000-0000-000000000004")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: utcDay(3, hour: 9), end: utcDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.appendRecurrenceException(onDay: utcDay(9), calendar: utc)
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(series)) as? [String: Any]
        )
        dict["recurrenceExceptionDayKeys"] = [20_260_810]
        let decoded = try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(decoded.recurrenceExceptionDayKeys, [20_260_810])
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: decoded, on: utcDay(10), calendar: utc),
                     "suppression follows the day key")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: decoded, on: utcDay(9), calendar: utc),
                        "the disagreeing legacy date is ignored")
    }

    /// The `.following` split's exception carry classifies by day key, not by
    /// reinterpreting the legacy mirror date through the current calendar. A
    /// boundary exception whose mirror instant was minted in an eastern zone
    /// reads as the PREVIOUS local day here — the pre-fix date filter left it
    /// behind on the capped old series, so the new series rendered a default
    /// occurrence on a day the user had detached (duplicate).
    @MainActor
    func testFollowingSplitCarriesBoundaryExceptionByDayKey() {
        let suiteName = "CalendarDragLogicTests.exceptionCarryDayKey"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let cal = Calendar.current
        func hostDay(_ d: Int, hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 3, day: d, hour: hour))! }
        func hostMidnight(_ d: Int) -> Date { cal.startOfDay(for: hostDay(d, hour: 12)) }
        func key(_ d: Int) -> Int { Event.recurrenceDayKey(for: hostMidnight(d), calendar: cal) }

        // Exceptions on day 12 (stays) and day 14 (the split boundary). Day
        // 14's mirror date is 6h before local midnight — exactly how a mirror
        // minted under a zone east of here reads — so the old
        // `startOfDay >= splitDay` filter classified it as day 13 and dropped it.
        let series = Event(
            id: UUID(uuidString: "17171717-0000-0000-0000-000000000005")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: hostDay(10, hour: 9), end: hostDay(10, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study",
            recurrenceExceptionDates: [hostMidnight(12), hostMidnight(14).addingTimeInterval(-6 * 3600)],
            recurrenceExceptionDayKeys: [key(12), key(14)]
        )
        store.addCalendarEvent(series)

        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: series.id)!,
            occurrenceDate: hostDay(14, hour: 12),
            scope: .following
        ) { $0.title = "New" }

        let newSeries = store.rawCalendarEvents.first { $0.isRecurringSeries && $0.id != series.id }
        XCTAssertNotNil(newSeries, "a split-off series exists")
        XCTAssertEqual(newSeries?.recurrenceExceptionDayKeys, [key(14)],
                       "the boundary exception follows its day onto the new series — classified by day key")
        XCTAssertEqual(newSeries?.recurrenceExceptionDates, [hostMidnight(14).addingTimeInterval(-6 * 3600)],
                       "its paired legacy mirror rides along untouched")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: newSeries!, on: hostMidnight(14)),
                     "the detached day stays suppressed on the new series — no duplicate")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: newSeries!, on: hostMidnight(15)),
                        "the day after renders normally")
    }

    // MARK: - gh#127 item 1 review round: calendar identity, composed canvas, instance day keys

    /// Review finding 1/4 (mint side): a day key must be the same integer no
    /// matter WHICH region calendar `Calendar.current` happens to be — the
    /// th_TH default is `.buddhist` (year 2569), ar_SA `.islamicUmmAlQura`,
    /// and `.japanese` years are era-relative. Only the naming calendar's
    /// TIME ZONE may decide the day; the reduction is pinned to Gregorian, so
    /// keys match Gregorian backfills, survive the user switching
    /// Settings > Language & Region > Calendar, and order like the days they
    /// name (the `>=` split carry is meaningless across mixed provenance).
    @MainActor
    func testExceptionDayKeyIsCalendarIdentityStable() {
        let zone = TimeZone(identifier: "Asia/Bangkok")!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        let day = gregorian.date(from: DateComponents(year: 2026, month: 8, day: 10))!

        for identifier: Calendar.Identifier in [.gregorian, .buddhist, .japanese, .islamicUmmAlQura] {
            var naming = Calendar(identifier: identifier)
            naming.timeZone = zone
            XCTAssertEqual(
                Event.recurrenceDayKey(for: day, calendar: naming),
                20_260_810,
                "the \(identifier) region calendar must not leak its year system into the key"
            )
        }

        // PROBE 4: a key minted while the device calendar was Gregorian keeps
        // suppressing after the user switches the region calendar to Buddhist
        // (and the reverse mint reads back under Gregorian).
        let series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000001")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(
                start: gregorian.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))!,
                end: gregorian.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 10))!
            )],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = zone

        var mintedGregorian = series
        mintedGregorian.appendRecurrenceException(onDay: day, calendar: gregorian)
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: mintedGregorian, on: day, calendar: buddhist),
                     "Gregorian-minted key still suppresses under a Buddhist region calendar")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(
            for: mintedGregorian,
            on: gregorian.date(byAdding: .day, value: 1, to: day)!,
            calendar: buddhist
        ))

        var mintedBuddhist = series
        mintedBuddhist.appendRecurrenceException(onDay: day, calendar: buddhist)
        XCTAssertEqual(mintedBuddhist.recurrenceExceptionDayKeys, [20_260_810],
                       "Buddhist-minted keys are already in the Gregorian wire shape")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: mintedBuddhist, on: day, calendar: gregorian),
                     "Buddhist-minted key still suppresses after switching back to Gregorian")
    }

    /// Review finding 1/4 (backfill side, PROBE 3): on a non-Gregorian-region
    /// device that never traveled, a LEGACY blob's backfilled keys must equal
    /// the keys the reader mints for the same rendered days — the pre-fix
    /// `isDate(_:inSameDayAs:)` read was calendar-identity-agnostic and
    /// handled this population correctly, so anything less is a migration-day
    /// regression: every previously detached/deleted occurrence would
    /// reappear beside its replacement, travel-free.
    @MainActor
    func testLegacyExceptionBlobBackfillMatchesNonGregorianReader() throws {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        // Never-traveled device: the frozen reference zone IS the home zone
        // that minted the legacy midnights — the population whose backfill
        // must be exact.
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "Asia/Bangkok")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Bangkok")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        func bkkDay(_ d: Int, hour: Int = 0) -> Date {
            gregorian.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))!
        }

        // Control (the probe's green assertion): the buddhist calendar
        // agrees the stored legacy midnight IS the target day — the pre-fix
        // read got this right, which is what makes the backfill's burden
        // "don't regress", not "best effort".
        XCTAssertTrue(buddhist.isDate(bkkDay(10), inSameDayAs: bkkDay(10, hour: 12)))

        var series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000002")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: bkkDay(3, hour: 9), end: bkkDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.appendRecurrenceException(onDay: bkkDay(10), calendar: buddhist)

        // Fake a pre-migration blob: absolute dates only, no day-key field.
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(series)) as? [String: Any]
        )
        dict.removeValue(forKey: "recurrenceExceptionDayKeys")
        let decoded = try JSONDecoder().decode(
            Event.self,
            from: JSONSerialization.data(withJSONObject: dict)
        )

        XCTAssertEqual(decoded.recurrenceExceptionDayKeys, [20_260_810],
                       "legacy backfill lands in the Gregorian wire shape, not 25690810 or a shifted day")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: decoded, on: bkkDay(10), calendar: buddhist),
                     "the migrated exception still suppresses on the Buddhist-region device")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: decoded, on: bkkDay(9), calendar: buddhist))
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: decoded, on: bkkDay(11), calendar: buddhist))
    }

    /// Review finding 2/5 (PROBE 1): the COMPOSED canvas — series and its
    /// detached replacement rendered together through `occurrencesForDate` —
    /// for the exact Apia-write/New-York-read scenario the item-1 fix was
    /// built around. Nominal suppression alone made this strictly worse than
    /// pre-fix: the replacement's absolute instant re-bucketed onto Aug 9
    /// beside the series' own Aug 9 occurrence (2 blocks) while Aug 10 went
    /// dark (0 blocks). `renderTimeRanges` pins the replacement to the same
    /// nominal day the suppression key names, at the same wall-clock the
    /// series' own expansion uses.
    @MainActor
    func testComposedCanvasPairsReplacementWithSuppressedDayAcrossTimeZones() {
        var calA = Calendar(identifier: .gregorian)
        calA.timeZone = TimeZone(identifier: "Pacific/Apia")!      // UTC+13
        var calB = Calendar(identifier: .gregorian)
        calB.timeZone = TimeZone(identifier: "America/New_York")!  // EDT −4
        func dayA(_ d: Int, hour: Int) -> Date { calA.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func dayB(_ d: Int, hour: Int = 0) -> Date { calB.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        let series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000003")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: dayA(3, hour: 9), end: dayA(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: dayA(10, hour: 9),
            scope: .single,
            edit: { $0.title = "Moved" },
            calendar: calA
        )
        let events = [result.updatedSeries!, result.exceptionInstance!]

        // Home-frame read is bit-exact — the fast path returns stored ranges.
        let homeAug10 = CalendarLayout.occurrencesForDate(events, date: dayA(10, hour: 0), calendar: calA)
        XCTAssertEqual(homeAug10.map(\.event.title), ["Moved"])
        XCTAssertEqual(homeAug10.first?.range.start, dayA(10, hour: 9))

        // New York read: one block per day, the replacement ON the
        // suppressed day, at the same wall-clock as its sibling occurrences.
        let aug9 = CalendarLayout.occurrencesForDate(events, date: dayB(9), calendar: calB)
        XCTAssertEqual(aug9.map(\.event.title), ["Daily"],
                       "Aug 9 renders the series' own occurrence ONLY — pre-renderTimeRanges the"
                       + " replacement's absolute instant re-bucketed here too (the duplicate)")
        let aug10 = CalendarLayout.occurrencesForDate(events, date: dayB(10), calendar: calB)
        XCTAssertEqual(aug10.map(\.event.title), ["Moved"],
                       "Aug 10 renders the replacement — nominal suppression without nominal"
                       + " placement left this day dark (the hole)")
        XCTAssertEqual(aug10.first?.range.start, dayB(10, hour: 16),
                       "the replacement sits at the series' own wall-clock in this frame"
                       + " (09:00 Apia ≡ 16:00 EDT), on its nominal day")
        let aug11 = CalendarLayout.occurrencesForDate(events, date: dayB(11), calendar: calB)
        XCTAssertEqual(aug11.map(\.event.title), ["Daily"])
    }

    /// Review finding 2/5 (PROBE 2): the ordinary one-hour westward delta
    /// (Berlin → London) stays correct — one block per day, replacement on
    /// its nominal day at the siblings' wall-clock.
    @MainActor
    func testComposedCanvasOrdinaryWestwardDeltaStaysPaired() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        func deDay(_ d: Int, hour: Int) -> Date { berlin.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func ukDay(_ d: Int, hour: Int = 0) -> Date { london.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        let series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000004")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: deDay(3, hour: 9), end: deDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: deDay(10, hour: 9),
            scope: .single,
            edit: { $0.title = "Moved" },
            calendar: berlin
        )
        let events = [result.updatedSeries!, result.exceptionInstance!]

        XCTAssertEqual(
            CalendarLayout.occurrencesForDate(events, date: ukDay(9), calendar: london).map(\.event.title),
            ["Daily"]
        )
        let aug10 = CalendarLayout.occurrencesForDate(events, date: ukDay(10), calendar: london)
        XCTAssertEqual(aug10.map(\.event.title), ["Moved"])
        XCTAssertEqual(aug10.first?.range.start, ukDay(10, hour: 8),
                       "09:00 Berlin ≡ 08:00 London — the replacement matches its siblings' wall-clock")
        XCTAssertEqual(
            CalendarLayout.occurrencesForDate(events, date: ukDay(11), calendar: london).map(\.event.title),
            ["Daily"]
        )
    }

    /// A replacement the user deliberately MOVED to another day keeps its
    /// move across a tz change: the whole-day offset from its nominal day is
    /// part of the user's edit and rides the day-shift term of
    /// `renderTimeRanges`, so it must not snap back to the suppressed day.
    @MainActor
    func testMovedReplacementKeepsItsCrossDayMoveAfterTravel() {
        var calA = Calendar(identifier: .gregorian)
        calA.timeZone = TimeZone(identifier: "Pacific/Apia")!
        var calB = Calendar(identifier: .gregorian)
        calB.timeZone = TimeZone(identifier: "America/New_York")!
        func dayA(_ d: Int, hour: Int) -> Date { calA.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func dayB(_ d: Int) -> Date { calB.date(from: DateComponents(year: 2026, month: 8, day: d))! }

        let series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000005")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: dayA(3, hour: 9), end: dayA(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        // Detach Aug 10 and move the replacement to Aug 11 (the drag-move edit
        // writes the new absolute range in the creation frame).
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: dayA(10, hour: 9),
            scope: .single,
            edit: {
                $0.title = "Moved"
                $0.timeRanges = [Event.TimeRange(start: dayA(11, hour: 9), end: dayA(11, hour: 10))]
            },
            calendar: calA
        )
        let events = [result.updatedSeries!, result.exceptionInstance!]

        // Home frame: Aug 10 empty (occurrence moved away), Aug 11 stacked
        // (its own occurrence + the moved replacement).
        XCTAssertEqual(CalendarLayout.occurrencesForDate(events, date: calA.startOfDay(for: dayA(10, hour: 0)), calendar: calA).count, 0)
        XCTAssertEqual(CalendarLayout.occurrencesForDate(events, date: calA.startOfDay(for: dayA(11, hour: 0)), calendar: calA).count, 2)

        // Traveled frame: the same picture, on the same nominal days.
        XCTAssertEqual(CalendarLayout.occurrencesForDate(events, date: dayB(10), calendar: calB).count, 0,
                       "the moved-away day stays empty — the replacement must not snap back onto it")
        XCTAssertEqual(CalendarLayout.occurrencesForDate(events, date: dayB(11), calendar: calB).count, 2,
                       "the move to Aug 11 survives the tz change")
    }

    /// Review findings 2/4 (PROBE Q7): an ALL-DAY detached instance renders
    /// exactly once after a tz change. The stored all-day shape is
    /// [startOfDay, startOfDay+86399] in the MINT frame; projecting the
    /// mint-frame time-of-day (Apia midnight ≡ 07:00 New York) hands the
    /// all-day strip's pure overlap test a range spanning two days, so the
    /// instance rendered beside the series' own occurrence on the following
    /// day — the literal gh#127 duplicate, on the all-day strip.
    /// `renderTimeRanges` snaps an all-day range to the current frame's own
    /// midnight of its nominal day, duration preserved.
    @MainActor
    func testAllDayDetachedInstanceRendersExactlyOnceAfterTravel() {
        var calA = Calendar(identifier: .gregorian)
        calA.timeZone = TimeZone(identifier: "Pacific/Apia")!      // UTC+13
        var calB = Calendar(identifier: .gregorian)
        calB.timeZone = TimeZone(identifier: "America/New_York")!  // EDT −4
        func dayA(_ d: Int, hour: Int = 0) -> Date { calA.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func dayB(_ d: Int) -> Date { calB.date(from: DateComponents(year: 2026, month: 8, day: d))! }

        // The composer's all-day shape: [startOfDay, startOfDay + 86_399].
        let series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-00000000000B")!,
            title: "AllDay",
            timeRanges: [Event.TimeRange(start: dayA(3), end: dayA(3).addingTimeInterval(86_399))],
            repeatUnit: .day,
            isAllDay: true,
            repeatInterval: 1,
            type: "Study"
        )
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: dayA(10),
            scope: .single,
            edit: { $0.title = "MovedAllDay" },
            calendar: calA
        )
        let events = [result.updatedSeries!, result.exceptionInstance!]
        XCTAssertTrue(result.exceptionInstance?.isAllDay ?? false)

        // Home strip: unchanged — the fast path returns stored ranges.
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate(events, date: dayA(9), calendar: calA).map(\.event.title), ["AllDay"])
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate(events, date: dayA(10), calendar: calA).map(\.event.title), ["MovedAllDay"])
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate(events, date: dayA(11), calendar: calA).map(\.event.title), ["AllDay"])

        // New York strip: exactly one badge per day. The probe's red pattern
        // was Aug 11 → ["AllDay", "MovedAllDay"].
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate(events, date: dayB(9), calendar: calB).map(\.event.title), ["AllDay"])
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate(events, date: dayB(10), calendar: calB).map(\.event.title), ["MovedAllDay"],
                       "the detached all-day badge sits on its nominal day")
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate(events, date: dayB(11), calendar: calB).map(\.event.title), ["AllDay"],
                       "…and ONLY on its nominal day — no duplicate beside the series' own badge")
    }

    /// Review finding 5: deleting a detached instance prunes its records by
    /// the instance's NOMINAL day key, not by reinterpreting the mirror
    /// midnight through `Calendar.current`. Common case pinned here: device
    /// at its own frozen reference zone (never-traveled New York user whose
    /// instance was minted during an Apia trip). The old
    /// `startOfDay(mirror)` + `isDate` read classified the instance as its
    /// NEIGHBORING local day, so the delete pruned the surviving Aug 9
    /// occurrence's logged history (permanent loss, the gh#145 direction)
    /// while the instance's own Aug 10 records leaked.
    @MainActor
    func testDeleteDetachedInstancePrunesRecordsByNominalDayKeyNotMirror() {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "America/New_York")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        func nyDay(_ d: Int, hour: Int = 0) -> Date { ny.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        let series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-00000000000C")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: nyDay(3, hour: 9), end: nyDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        // Detached during the trip: mirror = Apia Aug 10 midnight (reads as
        // NY Aug 9 through Calendar.current), key = the day the user acted
        // on, Aug 10.
        let instance = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-00000000000D")!,
            title: "Moved",
            timeRanges: [Event.TimeRange(
                start: apia.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))!,
                end: apia.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10))!
            )],
            type: "Study",
            recurrenceParentId: series.id,
            recurrenceInstanceDate: apia.date(from: DateComponents(year: 2026, month: 8, day: 10))!,
            recurrenceInstanceDayKey: 20_260_810
        )

        // Records minted back home through the production key path, one for
        // the series' legitimate Aug 9 occurrence and one for the instance's
        // own rendered day (nominal Aug 10).
        let neighborRecord = productionLogRecord(series: series, occurrenceDate: nyDay(9), note: "neighbor-day-9")
        let ownRecord = productionLogRecord(series: series, occurrenceDate: nyDay(10), note: "own-day-10")

        let survivors = EventStore.recordsSurviving(
            [neighborRecord, ownRecord],
            afterDeleting: instance
        )
        XCTAssertEqual(survivors?.map(\.note), ["neighbor-day-9"],
                       "deleting the detached Aug 10 instance removes Aug 10's records and ONLY"
                       + " Aug 10's — the mirror's Calendar.current reading (Aug 9) pruned the"
                       + " neighboring day's history and leaked the instance's own")
    }

    /// Cross-cutting review finding 1 (gh#127 residual, measured by the
    /// rtprobe): a drop committed in the CURRENT frame onto an instance whose
    /// mirror still sits in its mint frame must land where the finger
    /// released. Mint frame WEST of the device (New York mint, Shanghai
    /// device): the stale mirror reads as MID-DAY Shanghai, so a drop in the
    /// whole first half of the nominal day got `dayShift = -1` and rendered a
    /// full day EARLIER — replacement beside Aug 9's own occurrence
    /// (duplicate) while the key-suppressed Aug 10 rendered empty (hole).
    /// The write seam (`EventStore.mutateCalendarEvent`) now pairs every
    /// instance-range write with the mirror rebase.
    @MainActor
    func testTraveledInstanceDropOnItsNominalDayLandsWhereDropped() {
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        var sh = Calendar(identifier: .gregorian)
        sh.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func nyDay(_ d: Int, hour: Int) -> Date { ny.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func shDay(_ d: Int, hour: Int = 0) -> Date { sh.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        let suiteName = "CalendarDragLogicTests.traveledDropWestMint"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let series = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-000000000001")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: nyDay(3, hour: 9), end: nyDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        // Detached in the mint frame: mirror = NY Aug 10 midnight, key 20260810.
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: nyDay(10, hour: 9),
            scope: .single,
            edit: { $0.title = "Moved" },
            calendar: ny
        )
        store.addCalendarEvent(result.updatedSeries!)
        store.addCalendarEvent(result.exceptionInstance!)
        let instance = store.findCalendarEvent(id: result.exceptionInstance!.id)!

        // The user drops the block at 06:00 on its OWN nominal day — inside
        // the half of the day the stale-mirror math broke (probe: 00:00,
        // 06:00, 09:00, 11:00 Shanghai all rendered Aug 9).
        let dropped = Event.TimeRange(start: shDay(10, hour: 6), end: shDay(10, hour: 7))
        var updated = instance
        updated.timeRanges = calendarUpdatedRangesAfterDrop(
            existingRanges: instance.timeRanges,
            draggedRange: instance.renderTimeRanges(calendar: sh).first!,
            droppedRange: dropped,
            occurrenceID: nil
        )
        store.updateCalendarEvent(updated)

        let committed = store.findCalendarEvent(id: instance.id)!
        XCTAssertEqual(committed.recurrenceInstanceDayKey, 20_260_810,
                       "the nominal identity never moves — rebasing the mirror must not re-key the day")
        XCTAssertEqual(committed.recurrenceInstanceDate, shDay(10),
                       "the mirror moved WITH the current-frame write: current-frame midnight of the day key")
        XCTAssertEqual(committed.renderTimeRanges(calendar: sh), [dropped],
                       "a coherent (ranges, mirror) pair renders bit-for-bit — the drop stays under the finger")

        let events = [store.findCalendarEvent(id: series.id)!, committed]
        let aug9 = CalendarLayout.occurrencesForDate(events, date: shDay(9), calendar: sh)
        XCTAssertEqual(aug9.map(\.event.title), ["Daily"],
                       "Aug 9 keeps only its own occurrence — the stale mirror re-bucketed the"
                       + " replacement here (the gh#127 duplicate)")
        let aug10 = CalendarLayout.occurrencesForDate(events, date: shDay(10), calendar: sh)
        XCTAssertEqual(aug10.map(\.event.title), ["Moved"],
                       "the key-suppressed nominal day renders the replacement, not a hole")
        XCTAssertEqual(aug10.first?.range.start, dropped.start)
    }

    /// Cross-cutting review finding 4, the +1 direction: mint frame EAST of
    /// the device (Apia mint, New York device). The instance correctly
    /// renders on nominal Aug 10; the user drags it to 09:00 on that same
    /// day. Pre-fix, `dayShift = floor((Aug 10 09:00 − Aug 9 07:00) / 24h)
    /// = 1` re-projected the committed range onto Aug 11 — a full day from
    /// the finger, re-bucketed beside the series' own Aug 11 occurrence.
    @MainActor
    func testTraveledInstanceDragFromEastwardMintLandsWhereDropped() {
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        func apiaDay(_ d: Int, hour: Int) -> Date { apia.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func nyDay(_ d: Int, hour: Int = 0) -> Date { ny.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        let suiteName = "CalendarDragLogicTests.traveledDropEastMint"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let series = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-000000000002")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: apiaDay(3, hour: 9), end: apiaDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: apiaDay(10, hour: 9),
            scope: .single,
            edit: { $0.title = "Moved" },
            calendar: apia
        )
        store.addCalendarEvent(result.updatedSeries!)
        store.addCalendarEvent(result.exceptionInstance!)
        let instance = store.findCalendarEvent(id: result.exceptionInstance!.id)!

        let dropped = Event.TimeRange(start: nyDay(10, hour: 9), end: nyDay(10, hour: 10))
        var updated = instance
        updated.timeRanges = calendarUpdatedRangesAfterDrop(
            existingRanges: instance.timeRanges,
            draggedRange: instance.renderTimeRanges(calendar: ny).first!,
            droppedRange: dropped,
            occurrenceID: nil
        )
        store.updateCalendarEvent(updated)

        let committed = store.findCalendarEvent(id: instance.id)!
        XCTAssertEqual(committed.recurrenceInstanceDate, nyDay(10))
        XCTAssertEqual(committed.renderTimeRanges(calendar: ny), [dropped])

        let events = [store.findCalendarEvent(id: series.id)!, committed]
        XCTAssertEqual(CalendarLayout.occurrencesForDate(events, date: nyDay(10), calendar: ny).map(\.event.title),
                       ["Moved"])
        XCTAssertEqual(CalendarLayout.occurrencesForDate(events, date: nyDay(11), calendar: ny).map(\.event.title),
                       ["Daily"],
                       "the committed drop must not re-project a day late beside Aug 11's own occurrence")
    }

    /// The reason the fix is a mirror REBASE and not a `dayShift >= 0` clamp:
    /// a deliberate move to an EARLIER day is a legitimate negative shift and
    /// must survive the write. Same traveled fixture as above; the user drags
    /// the replacement one day before its nominal day.
    @MainActor
    func testDeliberateEarlierDayMoveOfTraveledInstanceIsNotClamped() {
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        func apiaDay(_ d: Int, hour: Int) -> Date { apia.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func nyDay(_ d: Int, hour: Int = 0) -> Date { ny.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        let suiteName = "CalendarDragLogicTests.traveledEarlierDayMove"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let series = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-000000000003")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: apiaDay(3, hour: 9), end: apiaDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: apiaDay(10, hour: 9),
            scope: .single,
            edit: { $0.title = "Moved" },
            calendar: apia
        )
        store.addCalendarEvent(result.updatedSeries!)
        store.addCalendarEvent(result.exceptionInstance!)
        let instance = store.findCalendarEvent(id: result.exceptionInstance!.id)!

        let dropped = Event.TimeRange(start: nyDay(9, hour: 9), end: nyDay(9, hour: 10))
        var updated = instance
        updated.timeRanges = [dropped]
        store.updateCalendarEvent(updated)

        let committed = store.findCalendarEvent(id: instance.id)!
        XCTAssertEqual(committed.recurrenceInstanceDate, nyDay(10),
                       "the mirror is the NOMINAL day's midnight — the replacement's whole-day"
                       + " offset from it is the user's edit, not the mirror's business")
        XCTAssertEqual(committed.renderTimeRanges(calendar: ny), [dropped],
                       "a legitimate deliberate move to the earlier day survives (dayShift = -1)")

        let events = [store.findCalendarEvent(id: series.id)!, committed]
        XCTAssertEqual(Set(CalendarLayout.occurrencesForDate(events, date: nyDay(9), calendar: ny).map(\.event.title)),
                       ["Daily", "Moved"],
                       "Aug 9 stacks its own occurrence plus the deliberately moved replacement")
        XCTAssertEqual(CalendarLayout.occurrencesForDate(events, date: nyDay(10), calendar: ny).count, 0,
                       "the nominal day is suppressed and its replacement moved away")
        XCTAssertEqual(CalendarLayout.occurrencesForDate(events, date: nyDay(11), calendar: ny).map(\.event.title),
                       ["Daily"])
    }

    /// Negative control for the write-side rebase: a write that does NOT
    /// touch the ranges (title edit) must leave the mirror in its mint frame
    /// — the stored ranges are still mint-frame instants, and rebasing the
    /// mirror without them would hand `renderTimeRanges` an incoherent pair
    /// (the exact breakage the rebase exists to prevent, from the other side).
    @MainActor
    func testRangeUntouchedWriteKeepsTheReadSideProjection() {
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        func apiaDay(_ d: Int, hour: Int) -> Date { apia.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func nyDay(_ d: Int, hour: Int = 0) -> Date { ny.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        let suiteName = "CalendarDragLogicTests.traveledTitleOnlyWrite"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let series = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-000000000004")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: apiaDay(3, hour: 9), end: apiaDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: apiaDay(10, hour: 9),
            scope: .single,
            edit: { $0.title = "Moved" },
            calendar: apia
        )
        store.addCalendarEvent(result.updatedSeries!)
        store.addCalendarEvent(result.exceptionInstance!)
        let instance = store.findCalendarEvent(id: result.exceptionInstance!.id)!

        var renamed = instance
        renamed.title = "Renamed"
        store.updateCalendarEvent(renamed)

        let committed = store.findCalendarEvent(id: instance.id)!
        XCTAssertEqual(committed.recurrenceInstanceDate, apia.date(from: DateComponents(year: 2026, month: 8, day: 10)),
                       "no range write, no rebase — the mint-frame pair stays coherent")
        XCTAssertEqual(committed.renderPrimaryTimeRange(calendar: ny)?.start, nyDay(10, hour: 16),
                       "the projection still places the untouched ranges on the nominal day"
                       + " at the siblings' wall-clock (09:00 Apia ≡ 16:00 EDT)")
    }

    /// Helper-level contract of `rebasedExceptionInstanceAfterRangeWrite`:
    /// (1) a range the write did not touch commits at its PROJECTION, so it
    /// does not move on screen when the mirror moves; (2) a write that moved
    /// the recurrence identity itself (a re-mint) is left alone — the minter
    /// knows its own frame.
    @MainActor
    func testRebaseProjectsUntouchedRangesAndRespectsIdentityWrites() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        var sh = Calendar(identifier: .gregorian)
        sh.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func nyDay(_ d: Int, hour: Int) -> Date { ny.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func shDay(_ d: Int, hour: Int = 0) -> Date { sh.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }

        let seriesID = UUID(uuidString: "19191919-0000-0000-0000-000000000005")!
        let untouched = Event.TimeRange(start: nyDay(10, hour: 9), end: nyDay(10, hour: 10))
        let replaced = Event.TimeRange(start: nyDay(10, hour: 14), end: nyDay(10, hour: 15))
        let previous = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-000000000006")!,
            title: "Moved",
            timeRanges: [untouched, replaced],
            type: "Study",
            recurrenceParentId: seriesID,
            recurrenceInstanceDate: ny.date(from: DateComponents(year: 2026, month: 8, day: 10))!,
            recurrenceInstanceDayKey: 20_260_810
        )

        let newRange = Event.TimeRange(start: shDay(10, hour: 20), end: shDay(10, hour: 21))
        var updated = previous
        updated.timeRanges = [untouched, newRange]

        let rebased = Event.rebasedExceptionInstanceAfterRangeWrite(updated, previous: previous, calendar: sh)
        XCTAssertEqual(rebased.recurrenceInstanceDate, shDay(10))
        XCTAssertEqual(rebased.recurrenceInstanceDayKey, 20_260_810)
        XCTAssertEqual(
            rebased.timeRanges,
            [
                // NY Aug 10 09:00 EDT ≡ Shanghai Aug 10 21:00 — exactly where
                // `renderTimeRanges` was already drawing it.
                Event.TimeRange(start: shDay(10, hour: 21), end: shDay(10, hour: 22)),
                newRange
            ],
            "the untouched mint-frame range commits at its projection; the new range rides as written"
        )

        // A write that re-minted the identity is not second-guessed.
        var reMinted = previous
        reMinted.timeRanges = [newRange]
        reMinted.recurrenceInstanceDate = shDay(10)
        XCTAssertEqual(
            Event.rebasedExceptionInstanceAfterRangeWrite(reMinted, previous: previous, calendar: sh),
            reMinted,
            "identity moved by the caller — the rebase must not fight applyEdit"
        )
    }

    /// Cross-cutting review finding 3 (gh#127 family): deleting a traveled
    /// detached instance classifies the day its interrupt children live on
    /// by the instance's NOMINAL day key projected into the current frame —
    /// the same conversion `recordsSurviving(afterDeleting:)` makes — not by
    /// `startOfDay(mirror)`, which reads one day off after travel and (in
    /// the classifier) marked the SERIES' surviving neighbor-day children
    /// while missing the instance's own. The persisted outcome is pinned
    /// here end-to-end: the instance's own-day child orphans, the neighbor
    /// day's child stays embedded.
    @MainActor
    func testDeleteTraveledDetachedInstanceOrphansItsOwnDaysChildrenOnly() {
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        func apiaDay(_ d: Int, hour: Int) -> Date { apia.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))! }
        func nyDay(_ d: Int, hour: Int, minute: Int = 0) -> Date { ny.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour, minute: minute))! }

        let suiteName = "CalendarDragLogicTests.traveledDeleteOrphans"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let series = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-000000000007")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: apiaDay(3, hour: 9), end: apiaDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        // Minted during the trip: mirror = Apia Aug 10 midnight (reads as NY
        // Aug 9 07:00 through Calendar.current), key = Aug 10.
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: apiaDay(10, hour: 9),
            scope: .single,
            edit: { $0.title = "Moved" },
            calendar: apia
        )
        store.addCalendarEvent(result.updatedSeries!)
        store.addCalendarEvent(result.exceptionInstance!)
        let instance = store.findCalendarEvent(id: result.exceptionInstance!.id)!

        // Interrupts created back home, in the current frame (09:00 Apia ≡
        // 16:00 EDT is where both parents render). Relations anchor on the
        // series id, exactly as `createInterrupt` stamps them for occurrences.
        let neighborChild = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-000000000008")!,
            title: "InterruptAug9",
            timeRanges: [Event.TimeRange(start: nyDay(9, hour: 16, minute: 15), end: nyDay(9, hour: 16, minute: 45))],
            type: "Study",
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: series.id,
                baseSeriesEventID: series.id,
                occurrenceDate: nyDay(9, hour: 16)
            )
        )
        let ownChild = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-000000000009")!,
            title: "InterruptAug10",
            timeRanges: [Event.TimeRange(start: nyDay(10, hour: 16, minute: 15), end: nyDay(10, hour: 16, minute: 45))],
            type: "Study",
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: series.id,
                baseSeriesEventID: series.id,
                occurrenceDate: nyDay(10, hour: 16)
            )
        )
        store.addCalendarEvent(neighborChild)
        store.addCalendarEvent(ownChild)
        XCTAssertEqual(store.findCalendarEvent(id: neighborChild.id)?.interruptRelation?.state, .embedded)
        XCTAssertEqual(store.findCalendarEvent(id: ownChild.id)?.interruptRelation?.state, .embedded)

        store.deleteCalendarEvent(instance)

        XCTAssertEqual(store.findCalendarEvent(id: ownChild.id)?.interruptRelation?.state, .orphaned,
                       "the deleted instance's own-day child loses its parent")
        XCTAssertEqual(store.findCalendarEvent(id: neighborChild.id)?.interruptRelation?.state, .embedded,
                       "the series' surviving Aug 9 occurrence keeps its child — the mirror's"
                       + " Calendar.current reading (Aug 9) must not claim the neighbor day")
    }

    /// gh#150 review (isolation contract): the zombie predicates are
    /// documented as shared, pure and `nonisolated` — this test EXERCISES
    /// that contract off the main actor, which compiles only while the
    /// predicates and the two computed properties they reduce
    /// (`isRecurringSeries`, `primaryTimeRange`) are really nonisolated.
    func testZombiePredicatesEvaluateOffTheMainActor() async {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let seed = utc.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))!
        let zombie = Event(
            id: UUID(uuidString: "19191919-0000-0000-0000-00000000000A")!,
            title: "Zombie",
            timeRanges: [Event.TimeRange(start: seed, end: seed.addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            repeatEndType: .onDate,
            repeatEndDate: utc.date(from: DateComponents(year: 2026, month: 8, day: 9))!,
            type: "Study"
        )
        let (gap, separation) = await Task.detached {
            (
                Event.zombieRecurrenceSignatureDayGap(zombie, calendar: utc),
                Event.zombieRecurrenceEndToSeedSeparation(zombie)
            )
        }.value
        XCTAssertEqual(gap, 1)
        XCTAssertEqual(separation, 33 * 3600)
    }

    /// Review finding 6: the `.following` split classifies a materialized
    /// instance by its frozen day KEY — the same frame as the exception-key
    /// carry in the same transaction. A mirror midnight minted east of here
    /// reads as the previous local day, so the old
    /// `startOfDay(instanceDate) >= splitDay` filter left the boundary day's
    /// INSTANCE parented to the capped series while its exception KEY moved
    /// to the new one: `.all`-deleting the new series leaked the instance as
    /// a zombie and delete-old swept a day it no longer owned.
    @MainActor
    func testFollowingSplitReparentsBoundaryInstanceByDayKey() {
        let suiteName = "CalendarDragLogicTests.instanceReparentDayKey"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let cal = Calendar.current
        func hostDay(_ d: Int, hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 3, day: d, hour: hour))! }
        func hostMidnight(_ d: Int) -> Date { cal.startOfDay(for: hostDay(d, hour: 12)) }
        func key(_ d: Int) -> Int { Event.recurrenceDayKey(for: hostMidnight(d), calendar: cal) }

        var series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000006")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: hostDay(10, hour: 9), end: hostDay(10, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        // The boundary day 14 was already detached: exception key on the
        // series + a materialized instance whose mirror was minted 6h east
        // (reads as day 13 through the current calendar).
        series.recurrenceExceptionDates = [hostMidnight(14).addingTimeInterval(-6 * 3600)]
        series.recurrenceExceptionDayKeys = [key(14)]
        let instance = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000007")!,
            title: "Moved",
            timeRanges: [Event.TimeRange(start: hostDay(14, hour: 11), end: hostDay(14, hour: 12))],
            type: "Study",
            recurrenceParentId: series.id,
            recurrenceInstanceDate: hostMidnight(14).addingTimeInterval(-6 * 3600),
            recurrenceInstanceDayKey: key(14)
        )
        // Identity sanity: the key matches day 14, not the mirror's
        // current-calendar reading (day 13).
        XCTAssertTrue(instance.recurrenceInstanceMatches(day: hostMidnight(14), calendar: cal))
        XCTAssertFalse(instance.recurrenceInstanceMatches(day: hostMidnight(13), calendar: cal))

        store.addCalendarEvent(series)
        store.addCalendarEvent(instance)

        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: series.id)!,
            occurrenceDate: hostDay(14, hour: 12),
            scope: .following
        ) { $0.title = "New" }

        let newSeries = store.rawCalendarEvents.first { $0.isRecurringSeries && $0.id != series.id }
        XCTAssertNotNil(newSeries)
        XCTAssertEqual(
            store.findCalendarEvent(id: instance.id)?.recurrenceParentId,
            newSeries?.id,
            "the boundary instance follows its day onto the new series, in step with its exception key"
        )
    }

    /// Review finding 6: "delete this and following" sweeps materialized
    /// instances by frozen day KEY. The boundary instance whose mirror reads
    /// as the previous local day used to survive the sweep and keep rendering
    /// after the series was capped.
    @MainActor
    func testDeleteFollowingSweepsBoundaryInstanceByDayKey() {
        let suiteName = "CalendarDragLogicTests.instanceSweepDayKey"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))

        let cal = Calendar.current
        func hostDay(_ d: Int, hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 3, day: d, hour: hour))! }
        func hostMidnight(_ d: Int) -> Date { cal.startOfDay(for: hostDay(d, hour: 12)) }
        func key(_ d: Int) -> Int { Event.recurrenceDayKey(for: hostMidnight(d), calendar: cal) }

        let series = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000008")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: hostDay(10, hour: 9), end: hostDay(10, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        let boundaryInstance = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-000000000009")!,
            title: "Boundary",
            timeRanges: [Event.TimeRange(start: hostDay(14, hour: 11), end: hostDay(14, hour: 12))],
            type: "Study",
            recurrenceParentId: series.id,
            recurrenceInstanceDate: hostMidnight(14).addingTimeInterval(-6 * 3600),
            recurrenceInstanceDayKey: key(14)
        )
        let keptInstance = Event(
            id: UUID(uuidString: "18181818-0000-0000-0000-00000000000A")!,
            title: "Kept",
            timeRanges: [Event.TimeRange(start: hostDay(12, hour: 11), end: hostDay(12, hour: 12))],
            type: "Study",
            recurrenceParentId: series.id,
            recurrenceInstanceDate: hostMidnight(12),
            recurrenceInstanceDayKey: key(12)
        )
        store.addCalendarEvent(series)
        store.addCalendarEvent(boundaryInstance)
        store.addCalendarEvent(keptInstance)

        store.deleteRecurringCalendarEvent(
            seriesEvent: store.findCalendarEvent(id: series.id)!,
            occurrenceDate: hostDay(14, hour: 12),
            scope: .following
        )

        XCTAssertNil(store.findCalendarEvent(id: boundaryInstance.id),
                     "the boundary-day instance is swept with the days being deleted")
        XCTAssertNotNil(store.findCalendarEvent(id: keptInstance.id),
                        "an instance before the cutoff survives")
    }

    /// Code-review: the `.single` edit-sheet day-lock + repeat-clear is extracted
    /// to `Event.normalizedSingleOccurrenceException` — verify it locks the time
    /// ranges to the edited day (preserving time-of-day + duration) and strips
    /// the series repeat fields.
    @MainActor
    func testNormalizedSingleOccurrenceExceptionLocksDayAndClearsRepeat() {
        let cal = Calendar.current
        let occDay = makeTimelineDate(hour: 0, minute: 0)
        let otherDay = cal.date(byAdding: .day, value: 3, to: occDay)!
        var instance = Event(
            id: UUID(uuidString: "DDDDDDDD-3333-3333-3333-333333333333")!,
            title: "X",
            timeRanges: [Event.TimeRange(
                start: Event.dateByCombining(day: otherDay, timeFrom: makeTimelineDate(hour: 14, minute: 0), calendar: cal),
                end: Event.dateByCombining(day: otherDay, timeFrom: makeTimelineDate(hour: 15, minute: 30), calendar: cal)
            )],
            repeatUnit: .day,
            repeatInterval: 2,
            type: "Study"
        )
        instance.repeatEndType = .afterCount
        instance.repeatEndCount = 5

        let normalized = Event.normalizedSingleOccurrenceException(instance, lockedTo: occDay, calendar: cal)

        XCTAssertEqual(normalized.repeatUnit, .none)
        XCTAssertEqual(normalized.repeatEndType, .none)
        XCTAssertNil(normalized.repeatEndDate)
        XCTAssertNil(normalized.repeatEndCount)
        // Locked to occDay, but time-of-day (14:00) and duration (90m) preserved.
        let range = normalized.timeRanges.first!
        XCTAssertTrue(cal.isDate(range.start, inSameDayAs: occDay))
        XCTAssertEqual(cal.component(.hour, from: range.start), 14)
        XCTAssertEqual(cal.component(.minute, from: range.start), 0)
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 90 * 60)
    }

    /// BUG 1: deleting a recurring series must release todos absorbed into it,
    /// like the single-event delete does — else they keep a dead
    /// absorbedIntoEventID and silently vanish from the canvas.
    @MainActor
    func testDeleteRecurringSeriesReleasesAbsorbedTodos() {
        let suiteName = "CalendarDragLogicTests.absorbedRelease"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
        let series = Event(
            id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-111111111111")!,
            title: "Daily",
            timeRanges: [makeTimelineRange(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        store.addCalendarEvent(series)
        let todoID = UUID(uuidString: "BBBBBBBB-1111-1111-1111-111111111111")!
        var todo = Event(id: todoID, title: "Absorbed", timeRanges: [makeTimelineRange(startHour: 11, startMinute: 0, endHour: 12, endMinute: 0)], type: "Study")
        todo.kind = .todo
        todo.absorbedIntoEventID = series.id
        store.addCalendarEvent(todo)

        store.deleteRecurringCalendarEvent(seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: makeTimelineDate(hour: 0, minute: 0), scope: .all)

        XCTAssertNil(store.findCalendarEvent(id: series.id), "series deleted")
        let released = store.findCalendarEvent(id: todoID)
        XCTAssertNotNil(released, "absorbed todo survives the series delete")
        XCTAssertNil(released?.absorbedIntoEventID, "and is released back to the canvas")
    }

    /// BUG 2: `.afterCount` must count REALIZED occurrences, not calendar steps.
    /// A Jan-31 monthly "5 times" renders Jan/Mar/May/Jul/Aug 31 (Feb/Apr/Jun
    /// skip), not just the first 3.
    @MainActor
    func testAfterCountMonthlyCountsRealizedOccurrences() {
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
        }
        var series = Event(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            title: "Month-end",
            timeRanges: [Event.TimeRange(start: date(2026, 1, 31), end: date(2026, 1, 31).addingTimeInterval(3600))],
            repeatUnit: .month,
            repeatInterval: 1,
            type: "Study"
        )
        series.repeatEndType = .afterCount
        series.repeatEndCount = 5

        for (y, m) in [(2026, 1), (2026, 3), (2026, 5), (2026, 7), (2026, 8)] {
            XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: series, on: date(y, m, 31)), "\(y)-\(m)-31 should render")
        }
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: series, on: date(2026, 10, 31)), "Oct 31 is the 6th realized occurrence, past afterCount 5")
        // Jul 31 is the 4th occurrence (index 3), not calendar step 6.
        XCTAssertEqual(Event.recurrenceOccurrenceIndex(seriesStart: date(2026, 1, 31), day: date(2026, 7, 31), unit: .month, interval: 1), 3)
    }

    // MARK: - COMMIT 1 (gh#125 / #127-item3): value-less / degenerate rules

    private func recurrenceDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
    }

    /// An `.afterCount` series whose count decoded/reconstructed as nil must NOT
    /// render forever (the pre-fix `if let count` end check no-ops on nil). The
    /// render gate repairs it to the seed — exactly one occurrence.
    @MainActor
    func testAfterCountNilCountRendersOnlySeed() {
        var series = Event(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            title: "Value-less afterCount",
            timeRanges: [Event.TimeRange(start: recurrenceDate(2026, 3, 1), end: recurrenceDate(2026, 3, 1).addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.repeatEndType = .afterCount
        series.repeatEndCount = nil  // value-less: would render forever pre-fix

        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: series, on: recurrenceDate(2026, 3, 1)), "the seed day renders")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: series, on: recurrenceDate(2026, 3, 2)), "day after the seed does not render (count repaired to 1)")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: series, on: recurrenceDate(2026, 4, 1)), "no far-future occurrence")
    }

    /// An `.onDate` series whose end date decoded as nil must render only the
    /// seed day — the render gate clamps the missing end to the series start.
    @MainActor
    func testOnDateNilEndDateRendersOnlySeedDay() {
        var series = Event(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            title: "Value-less onDate",
            timeRanges: [Event.TimeRange(start: recurrenceDate(2026, 3, 1), end: recurrenceDate(2026, 3, 1).addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.repeatEndType = .onDate
        series.repeatEndDate = nil  // value-less: clamps to the series start day

        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: series, on: recurrenceDate(2026, 3, 1)), "the seed day renders")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: series, on: recurrenceDate(2026, 3, 2)), "next day does not render (end clamped to seed day)")
    }

    /// A PRESENT `.onDate` end date before the series start is NOT the
    /// value-less gh#125 case — it is the exact shape pre-fix gh#124
    /// first-occurrence ".following" edits/deletes persisted
    /// (`repeatEndDate == seriesStart − 1`), and gh#124's landed scope defers
    /// existing zombies to a separate cleanup migration. The normalizer must
    /// pass it through: the zombie renders NOTHING (a delete-path zombie must
    /// not resurrect the occurrence the user deleted), and its
    /// `repeatEndDate < seriesStart` signature — which that migration keys on —
    /// must survive every persisted ingress unlaundered.
    @MainActor
    func testExistingZombieSeriesStaysDormantAndKeepsMigrationSignature() throws {
        let cal = Calendar(identifier: .gregorian)
        let seed = recurrenceDate(2026, 3, 10)
        let seedDay = cal.startOfDay(for: seed)
        var zombie = Event(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            title: "Zombie",
            timeRanges: [Event.TimeRange(start: seed, end: seed.addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        zombie.repeatEndType = .onDate
        zombie.repeatEndDate = cal.date(byAdding: .day, value: -1, to: seedDay)!

        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: zombie, on: seed),
                     "the seed day the user split/deleted away from must not resurrect")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: zombie, on: recurrenceDate(2026, 3, 11)),
                     "no later day renders either")

        // Codable ingress (every launch load): the same series must decode
        // dormant AND keep its end date byte-for-byte — a clamped write-back
        // would permanently erase the migration predicate.
        let decoded = try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(zombie))
        XCTAssertEqual(decoded.repeatEndType, .onDate)
        XCTAssertEqual(decoded.repeatEndDate, zombie.repeatEndDate,
                       "decode must not launder repeatEndDate < seriesStart")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: decoded, on: seed))

        // Supabase restore ingress: same contract.
        let native = SupabaseSyncService().eventToRow(zombie, kind: "calendar")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: native), options: []) as? [String: Any])
        let restored = try XCTUnwrap(SupabaseSyncService.rowToEvent(row))
        XCTAssertEqual(restored.repeatEndType, .onDate)
        let restoredEnd = try XCTUnwrap(restored.repeatEndDate)
        XCTAssertTrue(restoredEnd < seedDay, "restore must not clamp the zombie's end date up to the seed")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: restored, on: seed))
    }

    /// The edit-path gh#124 zombie has a sibling: the replacement series the
    /// old bug minted on the SAME day with the same times. Repairing the
    /// zombie's end date would render both — the user who already hit gh#124
    /// would see a duplicate block appear on a day that showed one. Exactly
    /// one block may render.
    @MainActor
    func testExistingZombieDoesNotDuplicateItsReplacementSeries() {
        let cal = Calendar(identifier: .gregorian)
        let seed = recurrenceDate(2026, 3, 10)
        var zombie = Event(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000006")!,
            title: "Old series (zombie)",
            timeRanges: [Event.TimeRange(start: seed, end: seed.addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        zombie.repeatEndType = .onDate
        zombie.repeatEndDate = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: seed))!
        let replacement = Event(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000007")!,
            title: "Replacement",
            timeRanges: [Event.TimeRange(start: seed, end: seed.addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )

        let blocks = CalendarLayout.occurrencesForDate([zombie, replacement], date: seed)
        XCTAssertEqual(blocks.count, 1, "one block on the seed day — the replacement's, not a resurrected zombie")
        XCTAssertEqual(blocks.first?.event.id, replacement.id)
    }

    /// A degenerate `repeatInterval <= 0` erased even the seed pre-fix
    /// (`guard interval > 0 else { return nil }`). The gate repairs it to 1 so
    /// the seed still renders.
    @MainActor
    func testZeroIntervalRendersSeedNotEmpty() {
        let series = Event(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            title: "Degenerate interval",
            timeRanges: [Event.TimeRange(start: recurrenceDate(2026, 3, 1), end: recurrenceDate(2026, 3, 1).addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 0,  // degenerate: pre-fix erased even the seed
            type: "Study"
        )
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: series, on: recurrenceDate(2026, 3, 1)), "interval repaired to 1 — the seed still renders")
    }

    /// The Supabase restore path builds an Event memberwise (bypassing Codable),
    /// so a null `repeat_end_count` column arrives as a nil count. `rowToEvent`
    /// must fail closed: the restored series stays `.afterCount` but bounded to
    /// the seed, not rendered forever.
    @MainActor
    func testRowToEventNullAfterCountIsBounded() throws {
        var series = Event(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
            title: "Synced series",
            timeRanges: [Event.TimeRange(start: recurrenceDate(2026, 3, 1), end: recurrenceDate(2026, 3, 1).addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.repeatEndType = .afterCount
        series.repeatEndCount = 3

        // Round-trip through the row shape PostgREST delivers, then null the
        // count column (the bug's ingress).
        let native = SupabaseSyncService().eventToRow(series, kind: "calendar")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: native), options: []) as? [String: Any])
        row["repeat_end_count"] = NSNull()

        let restored = try XCTUnwrap(SupabaseSyncService.rowToEvent(row))
        XCTAssertEqual(restored.repeatEndType, .afterCount, "end type preserved, not coerced to .none")
        XCTAssertEqual(restored.repeatEndCount, 1, "null count repaired to the seed-only bound")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: restored, on: recurrenceDate(2026, 3, 1)), "the seed renders")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: restored, on: recurrenceDate(2026, 3, 2)), "bounded to the seed, not forever")
    }

    @MainActor
    func testMultipleEmbeddedInterruptsRetainMoatVisualMode() {
        let suiteName = "CalendarDragLogicTests.multipleEmbeddedInterrupts"
        let suite = UserDefaults(suiteName: suiteName)!
        TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: suite, storage: .isolated(name: suiteName))
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

    func testSearchResultsSortByTimeNewestFirstAcrossMatchKinds() {
        // Time order wins over match-source kind: the newer event-note hit
        // must rank above the older log hit.
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

        XCTAssertEqual(results.map(\.event.id), [eventOnly.id, logEvent.id])
    }

    func testSearchResultsIgnoreOrphanLogRecords() {
        let orphanEventID = UUID()
        let orphanDate = makeSearchDate(2026, 6, 1, 0, 0)
        let record = CalendarEventLogRecord(
            id: CalendarOccurrenceKey(
                eventID: orphanEventID,
                baseSeriesEventID: nil,
                occurrenceDate: orphanDate,
                kind: .singleEvent,
                dayKey: CalendarOccurrenceKey.dayKey(from: orphanDate)
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

    // MARK: - gh#150: the zombie-series cleanup sweep

    private var zombieSweepCalendar: Calendar { Calendar(identifier: .gregorian) }

    /// A gh#124 zombie in exactly the shape the two mint sites write one:
    /// an `.onDate` series capped at `startOfDay(start) − gapDays`.
    private func makeZombieSeries(
        id: UUID,
        title: String = "Zombie",
        start: Date,
        gapDays: Int = 1
    ) -> Event {
        let cal = zombieSweepCalendar
        var zombie = Event(
            id: id,
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        zombie.repeatEndType = .onDate
        zombie.repeatEndDate = cal.date(
            byAdding: .day, value: -gapDays, to: cal.startOfDay(for: start)
        )!
        return zombie
    }

    private func makeHealthySeries(id: UUID, title: String, start: Date) -> Event {
        Event(
            id: id,
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
    }

    /// The other half of a gh#124 EDIT mint: the replacement series the split
    /// appends beside the row it caps — same title, same rule, seeded on the
    /// zombie's own seed day. Without one standing there the sweep reports the
    /// zombie as KEPT, so every "this row classifies as deletable" fixture has
    /// to include it.
    private func makeMintPartner(
        id: UUID,
        of zombie: Event,
        start: Date
    ) -> Event {
        makeHealthySeries(id: id, title: zombie.title, start: start)
    }

    /// The reachable NON-mint row the gh#150 panel named, built by the real edit
    /// path: a legitimate "ends on its own start day" series whose seed an
    /// `.all` edit then drags one day later. Its end now sits 33h before its
    /// seed — inside `zombieMintShapeSeparation`, and too wide for any zone to
    /// witness away — so shape alone would classify it deletable and only the
    /// twin requirement keeps it.
    private func makeDraggedPastItsOwnEndRow(id: UUID, title: String) throws -> Event {
        let cal = zombieSweepCalendar
        let seed = recurrenceDate(2026, 3, 10)      // 09:00
        var series = makeHealthySeries(id: id, title: title, start: seed)
        series.repeatEndType = .onDate
        series.repeatEndDate = cal.startOfDay(for: seed)
        let movedStart = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: seed))
        return try XCTUnwrap(Event.applyEdit(
            series: series,
            occurrenceDate: seed,
            scope: .all,
            edit: {
                $0.timeRanges = [Event.TimeRange(start: movedStart, end: movedStart.addingTimeInterval(3600))]
            },
            calendar: cal
        ).updatedSeries)
    }

    @MainActor
    private func makeZombieSweepStore(
        _ suiteName: String,
        _ location: EventStorageLocation
    ) -> EventStore {
        EventStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            storage: location,
            seedsSampleDataIfEmpty: false
        )
    }

    private func zombieSweepOccurrence(_ eventID: UUID, on date: Date) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: date,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    /// The diagnostic trail's current end offset, to be handed back to
    /// `zombieSweepTrailAppended(since:)`.
    private func zombieSweepTrailMark() -> UInt64 {
        let size = try? FileManager.default
            .attributesOfItem(atPath: DiagnosticTrail.liveURL.path)[.size] as? UInt64
        return size.flatMap { $0 } ?? 0
    }

    /// Exactly the trail text appended since `mark`. The sweep's whole product
    /// is now this text, so every caller reads it.
    ///
    /// It used to return `nil` when the live file rotated in between (192 KB of
    /// unrelated persistence lines), and every caller wrapped the result in
    /// `if let` — which quietly turned the assertions inside into a no-op on
    /// exactly the runs where the trail was busiest. It never returns `nil`
    /// now. One rotation renames the live file to `trail.1.log` without
    /// touching a byte, so the same offset still indexes into the oldest-first
    /// concatenation of the two files; only losing the marked bytes outright is
    /// unrecoverable, and that FAILS rather than passing silently.
    private func zombieSweepTrailAppended(
        since mark: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let live = (try? Data(contentsOf: DiagnosticTrail.liveURL)) ?? Data()
        if live.count >= Int(mark) {
            return String(decoding: live.dropFirst(Int(mark)), as: UTF8.self)
        }
        let rotated = (try? Data(contentsOf: DiagnosticTrail.rotatedURL)) ?? Data()
        let combined = rotated + live
        guard combined.count >= Int(mark) else {
            XCTFail(
                "the diagnostic trail rotated past the mark — every assertion on it"
                + " would have been vacuous, so this fails instead",
                file: file, line: line
            )
            return ""
        }
        return String(decoding: combined.dropFirst(Int(mark)), as: UTF8.self)
    }

    /// The sweep's own lines out of that text, stripped of the timestamp and
    /// session-id prefix each entry carries, in order. That leaves the report
    /// itself — the part that is supposed to be identical launch after launch.
    private func zombieSweepReport(
        since mark: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String] {
        zombieSweepTrailAppended(since: mark, file: file, line: line)
            .split(separator: "\n")
            .compactMap { entry in
                guard let marker = entry.range(of: "ZombieSweep ") else { return nil }
                return String(entry[marker.upperBound...])
            }
    }

    // MARK: gh#150 — the predicate

    /// The mint writes `startOfDay(seriesStart) − 1 day`. Reinterpreting those
    /// two instants under another time zone can push the pair across a second
    /// midnight, which is the whole reason the bound is 2 rather than an exact
    /// `−1 day` test.
    func testZombieSignatureGapMatchesMintShape() {
        let cal = zombieSweepCalendar
        let start = recurrenceDate(2026, 3, 10)
        let oneDay = makeZombieSeries(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!, start: start, gapDays: 1
        )
        let twoDays = makeZombieSeries(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!, start: start, gapDays: 2
        )
        XCTAssertEqual(Event.zombieRecurrenceSignatureDayGap(oneDay, calendar: cal), 1)
        XCTAssertEqual(Event.zombieRecurrenceSignatureDayGap(twoDays, calendar: cal), 2)

        // The gap is the CANDIDATE filter. What authorizes a delete is the
        // separation, which no reading zone can move: a 09:00 seed one day past
        // its own end is 33h, comfortably inside the mint window.
        let separation = Event.zombieRecurrenceEndToSeedSeparation(oneDay) ?? 0
        XCTAssertEqual(separation / 3600, 33, accuracy: 1)
        XCTAssertNil(Event.zombieMintShapeRefusal(oneDay, calendar: cal),
                     "a one-day mint at 09:00 is provably a mint")

        // Two days of gap MINTED that way is not a mint at all — the split only
        // ever writes one. A real mint reaches a gap of 2 by being REINTERPRETED
        // in another zone, which leaves its separation where it was; this row's
        // separation is 57h, past the ceiling, so it is a user-authored date.
        let blocker = Event.zombieMintShapeRefusal(twoDays, calendar: cal) ?? ""
        XCTAssertTrue(blocker.contains("beyond the mint shape"), "blocker was: \(blocker)")
    }

    /// The predicate must match what the SPLIT ACTUALLY MINTS, not a lookalike
    /// of it: run the pre-c19aa55 first-occurrence `.following` edit and feed
    /// its own output back in.
    func testZombieSignatureMatchesWhatTheSplitActuallyMints() {
        let cal = zombieSweepCalendar
        let start = recurrenceDate(2026, 3, 10)
        let series = makeHealthySeries(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000003")!, title: "Daily", start: start
        )

        let result = Event.applyEdit(
            series: series, occurrenceDate: start, scope: .following, edit: { _ in }, calendar: cal
        )

        let capped = result.updatedSeries
        XCTAssertEqual(capped.flatMap { Event.zombieRecurrenceSignatureDayGap($0, calendar: cal) }, 1,
                       "the capped old series is the zombie the sweep must find")
        let replacement = result.newSeries
        XCTAssertNotNil(replacement, "the split mints a replacement series beside the zombie")
        XCTAssertNil(replacement.flatMap { Event.zombieRecurrenceSignatureDayGap($0, calendar: cal) },
                     "and that replacement is healthy — the sweep must never touch it")
    }

    /// "Ends on the day it starts" is a legitimate single-occurrence rule: the
    /// end is stored as MIDNIGHT of D while the seed starts 09:00 of D, so a
    /// raw-instant `endDate < seriesStart` test would delete it. In the zone
    /// that wrote it the day reduction makes that a gap of zero — but only
    /// there, which is what the probes below are about.
    func testZombieSignatureIgnoresEndOnStartDay() {
        let cal = zombieSweepCalendar
        let start = recurrenceDate(2026, 3, 10)   // 09:00
        var legit = makeHealthySeries(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000004")!, title: "One day only", start: start
        )
        legit.repeatEndType = .onDate
        legit.repeatEndDate = cal.startOfDay(for: start)

        XCTAssertLessThan(legit.repeatEndDate!, start, "the raw instants really do compare 'end before start'")
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(legit, calendar: cal),
                     "a single-occurrence day rule must never be swept")
        XCTAssertNotNil(Event.zombieMintShapeRefusal(legit, calendar: cal),
                        "and it is refused on the delete side too, not merely unmatched")
    }

    // MARK: gh#150 — the reading zone is not the authoring zone

    /// One Gregorian calendar per IANA zone: every frame a device on this
    /// planet can read a stored instant in.
    private var everyIANAReadingCalendar: [(id: String, calendar: Calendar)] {
        TimeZone.knownTimeZoneIdentifiers.sorted().compactMap { id in
            guard let zone = TimeZone(identifier: id) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return (id, calendar)
        }
    }

    /// PROBE (gh#150 review, blocking). A legitimate single-occurrence series —
    /// exactly the shape `normalizedRecurrenceRule`'s gh#125 repair mints for
    /// every value-less `.onDate` rule — must survive being read in EVERY zone
    /// on the planet, not just the one that wrote it.
    ///
    /// The row is minted in Asia/Shanghai: seed 2026-06-15 09:00, end =
    /// `startOfDay(seed)`. Both are absolute instants, so 9 hours of westward
    /// reading puts them either side of a midnight and the day-gap signature —
    /// the whole of the original auto-delete test — reports a mint-shaped gap
    /// of 1 in 200 of the 443 IANA zones. The separation (9h) and the fact that
    /// Asia/Shanghai itself reads the end as the start of the seed's day are
    /// the two things that do NOT move, and they are what the classification
    /// now rests on.
    func testProbeLegitSingleDaySeriesAcrossEveryIANAZone() {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let seed = shanghai.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!

        var legit = makeHealthySeries(
            id: UUID(uuidString: "5C000000-0000-0000-0000-000000000001")!,
            title: "One day only", start: seed
        )
        legit.repeatEndType = .onDate
        legit.repeatEndDate = shanghai.startOfDay(for: seed)

        // This IS the gh#125 repair's own output, not a lookalike of it.
        let repaired = Event.normalizedRecurrenceRule(
            interval: 1, endType: .onDate, endDate: nil, endCount: nil,
            seriesStart: seed, calendar: shanghai
        )
        XCTAssertEqual(repaired.endDate, legit.repeatEndDate,
                       "the probe's fixture is exactly what the value-less .onDate repair mints")

        var signatureMatches: [String] = []
        var deletable: [String] = []
        for (id, calendar) in everyIANAReadingCalendar {
            if Event.zombieRecurrenceSignatureDayGap(legit, calendar: calendar) != nil {
                signatureMatches.append(id)
            }
            if Event.zombieMintShapeRefusal(legit, calendar: calendar) == nil {
                deletable.append(id)
            }
        }

        XCTAssertEqual(deletable, [],
                       "a legitimate ends-on-start-day series was auto-deletable in \(deletable.count) zone(s),"
                       + " e.g. \(deletable.prefix(5).joined(separator: ", "))")
        // The regression's own fingerprint: the day gap alone really does flag
        // this row, in most of the world. If this ever stops being true the
        // separation floor is no longer load-bearing and the reason it exists
        // has changed.
        XCTAssertFalse(signatureMatches.isEmpty,
                       "the day-gap signature is supposed to be frame-dependent — that is why it cannot license a delete")
    }

    /// PROBE (gh#150 review, blocking). The same thing end to end through the
    /// real store: seed the legitimate row as a device ONE HOUR EAST would have
    /// written it, then let this device load it. Before the separation floor
    /// the row was gone from memory and from the committed slot file, and the
    /// next `diffSync` mirrored that deletion to every other device the user
    /// owns.
    @MainActor
    func testProbeLegitSingleDaySeriesSurvivesAOneHourWestwardMove() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.westward"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let legitID = UUID(uuidString: "5C000000-0000-0000-0000-000000000002")!
        let start = recurrenceDate(2026, 6, 15)   // 09:00 here

        // The zone the row was authored in: one hour east of this device, so
        // this device reads it one hour west. A named neighbour where one
        // exists (Shanghai→Bangkok, Berlin→London); otherwise the fixed offset,
        // which is the same instant arithmetic under a different label.
        let deviceOffset = TimeZone.current.secondsFromGMT(for: start)
        let authoringZone = TimeZone.knownTimeZoneIdentifiers.sorted()
            .compactMap(TimeZone.init(identifier:))
            .first { $0.secondsFromGMT(for: start) == deviceOffset + 3600 }
            ?? TimeZone(secondsFromGMT: deviceOffset + 3600)!
        var authoring = Calendar(identifier: .gregorian)
        authoring.timeZone = authoringZone

        var legit = makeHealthySeries(id: legitID, title: "One day only", start: start)
        legit.repeatEndType = .onDate
        legit.repeatEndDate = authoring.startOfDay(for: start)
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(legit, calendar: authoring),
                     "it is not a candidate at home, in \(authoringZone.identifier)")
        XCTAssertEqual(Event.zombieRecurrenceSignatureDayGap(legit, calendar: zombieSweepCalendar), 1,
                       "and it IS one hour west, which is the whole bug")

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(legit)
        XCTAssertNotNil(seeded.findCalendarEvent(id: legitID))

        let relaunched = makeZombieSweepStore(suiteName, location)
        XCTAssertNotNil(relaunched.findCalendarEvent(id: legitID),
                        "a legitimate single-occurrence series must survive a westward move")
        let third = makeZombieSweepStore(suiteName, location)
        XCTAssertNotNil(third.findCalendarEvent(id: legitID),
                        "and it must still be in the committed slot file, not just in memory")
    }

    /// PROBE (gh#150 review, major). The auto-delete bound used to be stated in
    /// DAYS ("an exhaustive sweep of every IANA zone tops the reinterpreted gap
    /// out at exactly 2"), which is not a property of the data: a real mint
    /// from Pacific/Chatham the day after its fall-back, read from Pacific/Apia,
    /// reports a gap of 3 and fell off the auto-delete side of that bound.
    ///
    /// The bound is now the raw end→seed separation, which is invariant, so the
    /// same mint classifies the same way from every zone that sees it as a
    /// candidate at all — and a reading zone can still only push a mint to the
    /// KEPT side (by seeing the pair inside one of its own days), never the
    /// other way.
    func testProbeMintShapeGapCeilingAcrossEveryIANAZone() {
        // Real mints, written the way both mint sites write one:
        // `startOfDay(seed) − 1 day`, in the zone the device held at the time.
        let mintSpecs: [(zone: String, day: DateComponents)] = [
            ("Pacific/Chatham", DateComponents(year: 2026, month: 4, day: 5, hour: 23, minute: 59)),
            ("Pacific/Chatham", DateComponents(year: 2026, month: 4, day: 6, hour: 23, minute: 59)),
            ("America/New_York", DateComponents(year: 2025, month: 11, day: 3, hour: 9)),
            ("Europe/Berlin", DateComponents(year: 2026, month: 10, day: 26, hour: 23)),
            ("Asia/Shanghai", DateComponents(year: 2026, month: 6, day: 15, hour: 9)),
            ("Australia/Lord_Howe", DateComponents(year: 2026, month: 4, day: 6, hour: 12))
        ]
        let readers = everyIANAReadingCalendar
        var widestGap = 0
        var widestGapWhere = ""

        for spec in mintSpecs {
            var mintCalendar = Calendar(identifier: .gregorian)
            mintCalendar.timeZone = TimeZone(identifier: spec.zone)!
            guard let seed = mintCalendar.date(from: spec.day) else {
                XCTFail("no such instant in \(spec.zone)"); continue
            }
            var mint = makeHealthySeries(
                id: UUID(uuidString: "5C000000-0000-0000-0000-000000000003")!, title: "Mint", start: seed
            )
            mint.repeatEndType = .onDate
            mint.repeatEndDate = mintCalendar.date(
                byAdding: .day, value: -1, to: mintCalendar.startOfDay(for: seed)
            )!
            let atHome = Event.zombieMintShapeRefusal(mint, calendar: mintCalendar)
            XCTAssertNil(atHome, "\(spec.zone) mint is not deletable in its own zone: \(atHome ?? "")")

            for (id, calendar) in readers {
                if let gap = Event.zombieRecurrenceSignatureDayGap(mint, calendar: calendar) {
                    if gap > widestGap { widestGap = gap; widestGapWhere = "\(spec.zone) read in \(id)" }
                    XCTAssertNil(Event.zombieMintShapeRefusal(mint, calendar: calendar),
                                 "\(spec.zone) mint stopped being a mint when read in \(id) (gap=\(gap))")
                } else {
                    // The only drift a reading zone is allowed: it sees the pair
                    // inside one of its own days and the row is KEPT.
                    XCTAssertNotNil(Event.zombieMintShapeRefusal(mint, calendar: calendar))
                }
            }
        }

        XCTAssertGreaterThan(widestGap, 2,
                             "no reading zone stretched a real mint past a 2-day gap, so the day-gap ceiling this"
                             + " replaced would have looked sound again — widest seen was \(widestGap)d"
                             + " (\(widestGapWhere)); re-derive the bound before trusting it")
    }

    // MARK: gh#150 — the ends-on-start-day witness

    /// The longest day the tz database holds between 2015 and 2040, measured
    /// rather than asserted: `(authoring zone, its start instant, its length)`.
    ///
    /// A legitimate "ends on its own start day" rule stores `startOfDay(seed)`,
    /// so its end→seed separation is the seed's time of day — under 24 h on an
    /// ordinary day, which `zombieMintShapeSeparation`'s floor already keeps on
    /// the KEPT side. The only legitimate rows that reach the witness arm at all
    /// are the ones authored on a day LONGER than 24 h, where a late seed is
    /// more than a full day past its own midnight. That day exists (a 3-hour
    /// fall-back in Antarctica/Casey makes 27 h), and finding it here rather
    /// than hard-coding it means a future tzdata that moves it moves the fixture
    /// with it.
    private func longestTimeZoneDatabaseDay() -> (zone: TimeZone, dayStart: Date, length: TimeInterval)? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let from = gregorian.date(from: DateComponents(year: 2015, month: 1, day: 1)),
              let until = gregorian.date(from: DateComponents(year: 2040, month: 1, day: 1)) else { return nil }
        var best: (zone: TimeZone, dayStart: Date, length: TimeInterval)?
        for id in TimeZone.knownTimeZoneIdentifiers.sorted() {
            guard let zone = TimeZone(identifier: id) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            var cursor = from
            while let transition = zone.nextDaylightSavingTimeTransition(after: cursor), transition < until {
                let dayStart = calendar.startOfDay(for: transition.addingTimeInterval(-1))
                if let next = calendar.date(byAdding: .day, value: 1, to: dayStart) {
                    let length = next.timeIntervalSince(dayStart)
                    if length > (best?.length ?? 0) {
                        best = (zone, dayStart, length)
                    }
                }
                cursor = transition.addingTimeInterval(3600)
            }
        }
        return best
    }

    /// The witness arm, alone on the stand. A legitimate ends-on-start-day rule
    /// authored on the longest day the tz database has — seed late enough in it
    /// that the end sits MORE than 24 h back — clears the separation floor and
    /// so would classify deletable on shape alone. The only thing that keeps it is
    /// `zombieEndsOnStartDayWitness`: mutate that to `return nil` and every
    /// assertion below about a non-nil refusal fails, which is the point.
    func testWitnessAloneKeepsLegitEndsOnStartDayRuleThatClearsTheSeparationFloor() throws {
        let longest = try XCTUnwrap(longestTimeZoneDatabaseDay(),
                                    "the tz database has no DST transitions at all — re-derive this fixture")
        XCTAssertGreaterThanOrEqual(
            longest.length, 25 * 3600,
            "the longest day in 2015–2040 is \(longest.length / 3600)h (\(longest.zone.identifier));"
            + " under 25h no legitimate row can reach the witness arm and this test is vacuous"
        )
        var authoring = Calendar(identifier: .gregorian)
        authoring.timeZone = longest.zone

        // Seeded an hour before that long day ends, i.e. more than 24h after its
        // own midnight — the shape only a >24h day can produce.
        let seed = longest.dayStart.addingTimeInterval(longest.length - 3600)
        var legit = makeHealthySeries(
            id: UUID(uuidString: "5D000000-0000-0000-0000-000000000001")!,
            title: "One day only", start: seed
        )
        legit.repeatEndType = .onDate
        legit.repeatEndDate = authoring.startOfDay(for: seed)
        XCTAssertEqual(legit.repeatEndDate, longest.dayStart,
                       "the fixture must be the authoring zone's own startOfDay, not a lookalike")

        let separation = try XCTUnwrap(Event.zombieRecurrenceEndToSeedSeparation(legit))
        XCTAssertTrue(
            Event.zombieMintShapeSeparation.contains(separation),
            "the separation arm is supposed to be POWERLESS here (\(separation / 3600)h);"
            + " if it now excludes this row the witness has stopped being load-bearing"
        )

        let witness = try XCTUnwrap(Event.zombieEndsOnStartDayWitness(legit),
                                    "the authoring zone is always its own witness")
        XCTAssertNotNil(TimeZone(identifier: witness), "the witness names a real zone")

        // Every zone on the planet, and the count of the ones where nothing but
        // the witness stands between this row and a `deletable` verdict.
        var witnessOnlyDefence = 0
        for (id, calendar) in everyIANAReadingCalendar {
            let refusal = Event.zombieMintShapeRefusal(legit, calendar: calendar)
            XCTAssertNotNil(refusal, "a legitimate ends-on-start-day rule was auto-deletable read from \(id)")
            if Event.zombieRecurrenceSignatureDayGap(legit, calendar: calendar) != nil {
                witnessOnlyDefence += 1
                XCTAssertTrue(
                    refusal?.contains("reads the end as the start of the seed's own day") == true,
                    "read from \(id) the refusal must be the WITNESS, not another arm: \(refusal ?? "nil")"
                )
            }
        }
        XCTAssertGreaterThan(witnessOnlyDefence, 0,
                             "no reading zone even made this row a candidate — the test proves nothing")
    }

    // MARK: gh#150 — the twin (the mint's other half)

    /// The partner test matches what the SPLIT ACTUALLY MINTS, and nothing
    /// looser: run the pre-c19aa55 first-occurrence `.following` edit and hand
    /// its own two rows back in, then take one element away at a time.
    func testZombieMintPartnerMatchesTheSplitsOwnPairAndNothingLooser() throws {
        let cal = zombieSweepCalendar
        let start = recurrenceDate(2026, 3, 10)
        let series = makeHealthySeries(
            id: UUID(uuidString: "5E000000-0000-0000-0000-000000000001")!, title: "Gym", start: start
        )
        let result = Event.applyEdit(
            series: series, occurrenceDate: start, scope: .following, edit: { _ in }, calendar: cal
        )
        let capped = try XCTUnwrap(result.updatedSeries)
        let replacement = try XCTUnwrap(result.newSeries)
        XCTAssertNil(Event.zombieMintShapeRefusal(capped, calendar: cal), "the capped half is mint-shaped")

        XCTAssertEqual(Event.zombieMintPartner(of: capped, among: [capped, replacement])?.id,
                       replacement.id,
                       "the mint's own other half must be recognizable as the partner")
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped]),
                     "a lone capped row has no partner — that is the whole defect this closes")

        // Each element of the match, removed one at a time.
        var renamed = replacement
        renamed.title = "Gym (moved)"
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, renamed]),
                     "a renamed replacement is not provably the partner — kept is the safe failure")

        var rescheduled = replacement
        rescheduled.repeatUnit = .week
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, rescheduled]),
                     "a different rule is a different series")

        var strided = replacement
        strided.repeatInterval = 2
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, strided]),
                     "so is a different interval")

        var nextWeek = replacement
        let movedStart = try XCTUnwrap(cal.date(byAdding: .day, value: 7, to: start))
        nextWeek.timeRanges = [Event.TimeRange(start: movedStart, end: movedStart.addingTimeInterval(3600))]
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, nextWeek]),
                     "a series seeded a week away was not split off at this seed")

        // The LOOSE EDGE of the seed clause, which "+7 days" never pinned
        // (gh#150 review round 2, finding 4): the split writes the two seeds
        // equal to the second, so one second of drift in either direction is
        // already not the split's own output.
        for drift in [1.0, -1.0, 3600.0, -3600.0] {
            var nudged = replacement
            let nudgedStart = start.addingTimeInterval(drift)
            nudged.timeRanges = [Event.TimeRange(start: nudgedStart, end: nudgedStart.addingTimeInterval(3600))]
            XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, nudged]),
                         "a seed \(drift)s off the candidate's own is not the instant the split wrote")
        }

        // Every remaining field the split copies BY VALUE. Each one alone is
        // enough to say "this was authored separately" — the old predicate
        // ignored all of them and paired on {title, unit, interval}.
        var otherType = replacement
        otherType.type = "Life"
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, otherType]),
                     "the split never changes the type")

        var otherKind = replacement
        otherKind.kind = .todo
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, otherKind]),
                     "and never crosses .event/.todo")

        var otherDepth = replacement
        otherDepth.colorDepth = capped.colorDepth + 0.9
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, otherDepth]),
                     "and never restyles")

        var otherDuration = replacement
        otherDuration.timeRanges = [Event.TimeRange(start: start, end: start.addingTimeInterval(4 * 3600))]
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, otherDuration]),
                     "and never resizes")

        var otherAllDay = replacement
        otherAllDay.isAllDay = !capped.isAllDay
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, otherAllDay]),
                     "and never flips all-day")

        var secondZombie = replacement
        secondZombie.repeatEndType = .onDate
        secondZombie.repeatEndDate = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: start))
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, secondZombie]),
                     "two capped rows must not vouch for each other")

        var exceptionInstance = replacement
        exceptionInstance.recurrenceParentId = capped.id
        exceptionInstance.recurrenceInstanceDate = cal.startOfDay(for: start)
        XCTAssertNil(Event.zombieMintPartner(of: capped, among: [capped, exceptionInstance]),
                     "a materialized instance is not a series and cannot be the replacement")

        // Frame discipline (2fe145e): the decision is a difference of two stored
        // instants and a handful of copied fields, so the predicate takes no
        // Calendar at all and no reading zone can move it. Two rows minted in
        // Antarctica/Casey pair up identically when this device is in Apia.
        var casey = Calendar(identifier: .gregorian)
        casey.timeZone = try XCTUnwrap(TimeZone(identifier: "Antarctica/Casey"))
        let caseySeed = try XCTUnwrap(casey.date(from: DateComponents(year: 2026, month: 4, day: 6, hour: 9)))
        let caseySeries = makeHealthySeries(
            id: UUID(uuidString: "5E000000-0000-0000-0000-000000000003")!, title: "Gym", start: caseySeed
        )
        let caseyMint = Event.applyEdit(
            series: caseySeries, occurrenceDate: caseySeed, scope: .following, edit: { _ in }, calendar: casey
        )
        let caseyCapped = try XCTUnwrap(caseyMint.updatedSeries)
        let caseyReplacement = try XCTUnwrap(caseyMint.newSeries)
        XCTAssertEqual(Event.zombieMintPartner(of: caseyCapped, among: [caseyCapped, caseyReplacement])?.id,
                       caseyReplacement.id,
                       "a pair minted 11 zones away still pairs up here, with no calendar passed in")
    }

    /// gh#150 review round 2, finding 1/3 (blocking): two rows that never came
    /// out of any split must not vouch for each other.
    ///
    /// The candidate is the panel's own reachable shape — a legitimate "ends on
    /// its own start day" series whose seed an `.all` edit drags one day later —
    /// and the would-be voucher is ONE independently created "Gym" daily, the
    /// natural recovery when the first row renders nothing. Under the old
    /// {title, unit, interval} match this pair authorized a hard DELETE of the
    /// dragged row.
    func testQAProbeTwoUnrelatedLookalikeSeriesMustNotVouchForEachOther() throws {
        let cal = zombieSweepCalendar
        let dragged = try makeDraggedPastItsOwnEndRow(
            id: UUID(uuidString: "5B000000-0000-0000-0000-000000000001")!, title: "Gym"
        )
        XCTAssertNil(Event.zombieMintShapeRefusal(dragged, calendar: cal),
                     "the fixture must be mint-SHAPED or this probe proves nothing")
        let draggedSeed = try XCTUnwrap(dragged.primaryTimeRange?.start)

        // (a) Created on the same day, at the hour the user happened to pick.
        let eveningSeed = try XCTUnwrap(cal.date(byAdding: .hour, value: 9, to: draggedSeed))
        let evening = makeHealthySeries(
            id: UUID(uuidString: "5B000000-0000-0000-0000-000000000002")!, title: "Gym", start: eveningSeed
        )
        XCTAssertNil(Event.zombieMintPartner(of: dragged, among: [dragged, evening]),
                     "a series seeded 9h away was not split off at this seed")

        // (b) Same morning, same hour — but authored with the user's own type
        // and length, which the split would have copied verbatim.
        var sameHour = makeHealthySeries(
            id: UUID(uuidString: "5B000000-0000-0000-0000-000000000003")!, title: "Gym", start: draggedSeed
        )
        sameHour.type = "Life"
        sameHour.timeRanges = [Event.TimeRange(start: draggedSeed, end: draggedSeed.addingTimeInterval(4 * 3600))]
        XCTAssertNil(Event.zombieMintPartner(of: dragged, among: [dragged, sameHour]),
                     "a row authored with its own type and length is not the mint's other half")

        // Both at once is still nothing.
        XCTAssertNil(Event.zombieMintPartner(of: dragged, among: [dragged, evening, sameHour]),
                     "two lookalikes are not better evidence than one")
    }

    /// gh#150 review round 2, finding 3 (sharpest sub-case): `"" == ""` is a
    /// clause that vouches for nothing, and this app persists untitled captures
    /// by design. An untitled candidate can never find a partner.
    func testQAProbeUntitledRowsMustNotVouchForEachOther() throws {
        let cal = zombieSweepCalendar
        for title in ["", "   "] {
            let untitled = try makeDraggedPastItsOwnEndRow(
                id: UUID(uuidString: "5B000000-0000-0000-0000-000000000004")!, title: title
            )
            XCTAssertNil(Event.zombieMintShapeRefusal(untitled, calendar: cal),
                         "the fixture must be mint-SHAPED or this probe proves nothing")
            let seed = try XCTUnwrap(untitled.primaryTimeRange?.start)
            let otherUntitled = makeHealthySeries(
                id: UUID(uuidString: "5B000000-0000-0000-0000-000000000005")!, title: title, start: seed
            )
            XCTAssertNil(Event.zombieMintPartner(of: untitled, among: [untitled, otherUntitled]),
                         "two untitled dailies seeded the same morning must not vouch for each other")
        }
    }

    /// gh#150 review round 2, finding 1: the predicate compared 3 of the ~12
    /// fields `applyEdit(.following)` copies BY VALUE, so a lookalike differing
    /// in type, colour AND length still vouched as the mint's other half. It
    /// must not.
    func testQAProbePartnerRequiresTheCopiedFieldsBeyondTitleAndRule() throws {
        let cal = zombieSweepCalendar
        var candidate = try makeDraggedPastItsOwnEndRow(
            id: UUID(uuidString: "5B000000-0000-0000-0000-000000000006")!, title: "Gym"
        )
        candidate.type = "Study"
        candidate.colorDepth = 0.0
        XCTAssertNil(Event.zombieMintShapeRefusal(candidate, calendar: cal))
        let seed = try XCTUnwrap(candidate.primaryTimeRange?.start)

        var lookalike = makeHealthySeries(
            id: UUID(uuidString: "5B000000-0000-0000-0000-000000000007")!, title: "Gym", start: seed
        )
        lookalike.type = "Life"
        lookalike.colorDepth = 0.9
        lookalike.timeRanges = [Event.TimeRange(start: seed, end: seed.addingTimeInterval(4 * 3600))]
        XCTAssertNil(Event.zombieMintPartner(of: candidate, among: [candidate, lookalike]),
                     "type, colour and length all differ — nothing about this row says 'split copy'")

        // The same row with every copied field restored IS the twin, so the
        // probe is measuring the fields and not some unrelated guard.
        var twin = lookalike
        twin.type = candidate.type
        twin.colorDepth = candidate.colorDepth
        twin.timeRanges = [Event.TimeRange(start: seed, end: seed.addingTimeInterval(candidate.duration))]
        XCTAssertEqual(Event.zombieMintPartner(of: candidate, among: [candidate, twin])?.id, twin.id,
                       "restore what the split copies and the pairing comes back")
    }

    /// gh#150 review round 2, finding 2/4 (major): measuring the partner from
    /// the candidate's END only pinned it to within ±27h of the candidate's
    /// SEED, so a row seeded a whole calendar day later still vouched — while
    /// the doc claimed "inside the candidate's own seed day". The clause is now
    /// the seed instant the split actually writes.
    func testQAProbePartnerMayNotBeAWholeDayAfterTheCandidateSeed() throws {
        let cal = zombieSweepCalendar
        let seed = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let end = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 4, day: 14)))
        var candidate = makeHealthySeries(
            id: UUID(uuidString: "5B000000-0000-0000-0000-000000000008")!, title: "Gym", start: seed
        )
        candidate.repeatEndType = .onDate
        candidate.repeatEndDate = end
        XCTAssertEqual(try XCTUnwrap(Event.zombieRecurrenceEndToSeedSeparation(candidate)) / 3600, 24,
                       accuracy: 0.001, "the candidate sits on the floor of the mint band")
        XCTAssertNil(Event.zombieMintShapeRefusal(candidate, calendar: cal),
                     "mint-shaped, unwitnessable — the fixture the finding measured")

        // end + 51h: the far edge of the OLD band, one full calendar day after
        // the candidate's own seed.
        let dayLater = try XCTUnwrap(cal.date(byAdding: .hour, value: 51, to: end))
        XCTAssertEqual(cal.dateComponents([.day], from: cal.startOfDay(for: seed),
                                          to: cal.startOfDay(for: dayLater)).day, 1,
                       "the fixture must really be a different calendar day")
        let far = makeHealthySeries(
            id: UUID(uuidString: "5B000000-0000-0000-0000-000000000009")!, title: "Gym", start: dayLater
        )
        XCTAssertTrue(Event.zombieMintShapeSeparation.contains(dayLater.timeIntervalSince(end)),
                      "it WAS inside the old end-anchored band — that is the defect")
        XCTAssertNil(Event.zombieMintPartner(of: candidate, among: [candidate, far]),
                     "a seed a whole day past the candidate's own is not what the split wrote")

        let twin = makeHealthySeries(
            id: UUID(uuidString: "5B00000A-0000-0000-0000-000000000001")!, title: "Gym", start: seed
        )
        XCTAssertEqual(Event.zombieMintPartner(of: candidate, among: [candidate, far, twin])?.id, twin.id,
                       "the real twin — same seed instant — still pairs")
    }

    /// The reachable shape the shape tests cannot tell from a mint, built by the
    /// real edit path: a legitimate "ends on its own start day" series whose
    /// seed an `.all` edit then drags one day LATER. The end is now 33h before
    /// the seed — inside `zombieMintShapeSeparation`, and no zone has a day long
    /// enough to witness a 33h gap away — so shape alone says DELETE.
    func testAllEditThatMovesTheSeedPastItsOwnEndIsMintShapedAndPartnerless() throws {
        let cal = zombieSweepCalendar
        let seed = recurrenceDate(2026, 3, 10)      // 09:00
        var series = makeHealthySeries(
            id: UUID(uuidString: "5E000000-0000-0000-0000-000000000002")!, title: "Gym", start: seed
        )
        series.repeatEndType = .onDate
        series.repeatEndDate = cal.startOfDay(for: seed)
        XCTAssertNotNil(Event.zombieMintShapeRefusal(series, calendar: cal),
                        "before the edit it is a legitimate single-occurrence rule")

        let movedStart = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: seed))
        let moved = try XCTUnwrap(Event.applyEdit(
            series: series, occurrenceDate: seed, scope: .all,
            edit: { $0.timeRanges = [Event.TimeRange(start: movedStart, end: movedStart.addingTimeInterval(3600))] },
            calendar: cal
        ).updatedSeries)

        let separation = try XCTUnwrap(Event.zombieRecurrenceEndToSeedSeparation(moved))
        XCTAssertEqual(separation / 3600, 33, accuracy: 1)
        XCTAssertNil(Event.zombieEndsOnStartDayWitness(moved),
                     "no zone has a day long enough to swallow 33h — the witness cannot save this row")
        XCTAssertNil(Event.zombieMintShapeRefusal(moved, calendar: cal),
                     "shape alone says DELETE, which is exactly the hole")
        XCTAssertNil(Event.zombieMintPartner(of: moved, among: [moved]),
                     "and the twin requirement is what closes it")
    }

    func testZombieSignatureIgnoresNonMatches() {
        let cal = zombieSweepCalendar
        let start = recurrenceDate(2026, 3, 10)
        let beforeStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: start))!
        let base = makeZombieSeries(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!, start: start
        )
        XCTAssertNotNil(Event.zombieRecurrenceSignatureDayGap(base, calendar: cal), "control")

        var exception = base
        exception.recurrenceParentId = UUID()
        exception.recurrenceInstanceDate = cal.startOfDay(for: start)
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(exception, calendar: cal),
                     "a materialized exception instance is not a series")

        var plain = base
        plain.repeatUnit = .none
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(plain, calendar: cal),
                     "a non-repeating event is not a series")

        var afterCount = base
        afterCount.repeatEndType = .afterCount
        afterCount.repeatEndCount = 3
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(afterCount, calendar: cal),
                     "an `.afterCount` rule's stale end date means nothing")

        var neverEnds = base
        neverEnds.repeatEndType = .none
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(neverEnds, calendar: cal))

        var nilEnd = base
        nilEnd.repeatEndDate = nil
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(nilEnd, calendar: cal),
                     "the value-less gh#125 shape belongs to normalizedRecurrenceRule, not here")

        var endsLater = base
        endsLater.repeatEndDate = cal.date(byAdding: .day, value: 30, to: start)!
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(endsLater, calendar: cal))

        var noSeed = base
        noSeed.timeRanges = []
        noSeed.repeatEndDate = beforeStart
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(noSeed, calendar: cal),
                     "no seed instant means nothing to compare against")
    }

    // MARK: gh#150 — the sweep

    /// The headline, and it is the opposite of what it used to be: a
    /// satellite-free zombie is REPORTED as deletable on the next launch and is
    /// still there afterwards — in memory and in the committed slot file. The
    /// delete arm is parked because a mint pair and a hand-made duplicate are
    /// the same bytes, so "no user data is destroyed" has to be a tested
    /// property rather than a promise. Nothing standing beside it moves either.
    @MainActor
    func testSweepReportsSatelliteFreeZombieAsDeletableWithoutRemovingIt() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.removes"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
        let siblingID = UUID(uuidString: "51000000-0000-0000-0000-000000000002")!
        let plainID = UUID(uuidString: "51000000-0000-0000-0000-000000000003")!

        let seeded = makeZombieSweepStore(suiteName, location)
        let zombie = makeZombieSeries(id: zombieID, start: start)
        seeded.addCalendarEvent(zombie)
        seeded.addCalendarEvent(makeMintPartner(id: siblingID, of: zombie, start: start))
        seeded.addCalendarEvent(Event(
            id: plainID,
            title: "Lunch",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(1800))],
            type: "Study"
        ))
        XCTAssertEqual(seeded.rawCalendarEvents.count, 3, "the seeding store must not sweep its own writes")

        let gap = Event.zombieRecurrenceSignatureDayGap(zombie) ?? -1
        let mark = zombieSweepTrailMark()
        let relaunched = makeZombieSweepStore(suiteName, location)

        XCTAssertNotNil(relaunched.findCalendarEvent(id: zombieID),
                        "the sweep reports; it does not remove")
        XCTAssertNotNil(relaunched.findCalendarEvent(id: siblingID), "its replacement series is untouched")
        XCTAssertNotNil(relaunched.findCalendarEvent(id: plainID), "and so is everything unrelated")
        XCTAssertEqual(relaunched.rawCalendarEvents.count, 3, "no row left the store")

        // The classification is still exactly what it was — only the arm that
        // acted on it is gone.
        XCTAssertNil(relaunched.findCalendarEvent(id: zombieID).flatMap { relaunched.zombieSweepBlocker(for: $0) },
                     "nothing blocks it; it is the class the delete arm existed for")
        XCTAssertEqual(zombieSweepReport(since: mark), [
            "deletable id=\(zombieID.uuidString) gap=\(gap)d partner=\(siblingID.uuidString)",
            "done report-only candidates=1 deletable=1 kept=0",
        ], "the run is a report, and it names the partner that is the evidence")

        // Nothing COMMITTED either — the row is still in the slot file, so no
        // hard DELETE was ever staged for the next diffSync.
        let third = makeZombieSweepStore(suiteName, location)
        XCTAssertNotNil(third.findCalendarEvent(id: zombieID), "still on disk")
        XCTAssertEqual(third.rawCalendarEvents.count, 3)
    }

    /// Idempotence used to mean "the second launch finds nothing left to do".
    /// A report-only sweep changes nothing, so it means the stronger thing: the
    /// SAME report, launch after launch, over an unchanged store.
    ///
    /// The signature is still what carries it, and there is still no ran-once
    /// flag — which is why a zombie a cloud restore delivers next year is
    /// reported the launch after it lands, instead of being waved through by a
    /// flag set the launch before it existed.
    @MainActor
    func testSweepReportRepeatsIdenticallyAcrossLaunchesAndChangesNothing() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.idempotent"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "52000000-0000-0000-0000-000000000001")!
        let siblingID = UUID(uuidString: "52000000-0000-0000-0000-000000000002")!

        let seeded = makeZombieSweepStore(suiteName, location)
        let zombie = makeZombieSeries(id: zombieID, start: start)
        seeded.addCalendarEvent(zombie)
        seeded.addCalendarEvent(makeMintPartner(id: siblingID, of: zombie, start: start))
        let expected = seeded.rawCalendarEvents.map(\.id)

        let firstMark = zombieSweepTrailMark()
        let first = makeZombieSweepStore(suiteName, location)
        let firstReport = zombieSweepReport(since: firstMark)
        let secondMark = zombieSweepTrailMark()
        let steady = makeZombieSweepStore(suiteName, location)
        let secondReport = zombieSweepReport(since: secondMark)

        XCTAssertEqual(first.rawCalendarEvents.map(\.id), expected, "launch one mutates nothing")
        XCTAssertEqual(steady.rawCalendarEvents.map(\.id), expected, "and neither does launch two")
        XCTAssertEqual(firstReport, secondReport,
                       "the same store reports the same thing every launch: \(firstReport) vs \(secondReport)")
        XCTAssertEqual(secondReport.last, "done report-only candidates=1 deletable=1 kept=0")

        // A cloud restore / device backup delivers a SECOND zombie, long after
        // any "ran once" flag would have been set. Its own title, so the two
        // pairs cannot vouch for each other.
        let restoredID = UUID(uuidString: "52000000-0000-0000-0000-000000000003")!
        let restoredSiblingID = UUID(uuidString: "52000000-0000-0000-0000-000000000004")!
        let restored = makeZombieSeries(id: restoredID, title: "Restored", start: start)
        steady.addCalendarEvent(restored)
        steady.addCalendarEvent(makeMintPartner(id: restoredSiblingID, of: restored, start: start))

        let thirdMark = zombieSweepTrailMark()
        let afterRestore = makeZombieSweepStore(suiteName, location)
        let thirdReport = zombieSweepReport(since: thirdMark)
        XCTAssertEqual(afterRestore.rawCalendarEvents.count, 4, "still nothing is removed")
        XCTAssertNotNil(afterRestore.findCalendarEvent(id: restoredID))
        XCTAssertEqual(thirdReport.last, "done report-only candidates=2 deletable=2 kept=0",
                       "a zombie that arrives later is reported too — no flag stands in the way")
        XCTAssertTrue(
            thirdReport.contains("deletable id=\(restoredID.uuidString) gap=\(Event.zombieRecurrenceSignatureDayGap(restored) ?? -1)d partner=\(restoredSiblingID.uuidString)"),
            "and it is classified on its own evidence: \(thirdReport)"
        )
    }

    /// The issue's "verify per series, not assume". A log record still anchored
    /// to the zombie is logged history; deleting the series would prune it for
    /// good, so the row stays dormant instead.
    @MainActor
    func testSweepKeepsZombieOwningLogRecords() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.logs"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "53000000-0000-0000-0000-000000000001")!

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(makeZombieSeries(id: zombieID, start: start))
        seeded.upsertLogRecord(for: zombieSweepOccurrence(zombieID, on: start)) { $0.note = "did it anyway" }
        XCTAssertEqual(seeded.calendarEventLogRecords.count, 1)
        XCTAssertEqual(seeded.calendarEventLogRecords.first?.baseSeriesEventID, zombieID)

        let relaunched = makeZombieSweepStore(suiteName, location)
        let kept = relaunched.findCalendarEvent(id: zombieID)
        XCTAssertNotNil(kept, "a zombie that owns logged history is kept, not deleted")
        XCTAssertEqual(relaunched.calendarEventLogRecords.count, 1, "and its history is kept with it")
        XCTAssertEqual(kept.flatMap { relaunched.zombieSweepBlocker(for: $0) }, "owns log record(s)")
    }

    @MainActor
    func testSweepKeepsZombieOwningFeedbackRecord() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.feedback"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "54000000-0000-0000-0000-000000000001")!

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(makeZombieSeries(id: zombieID, start: start))
        seeded.upsertFeedbackRecord(for: zombieSweepOccurrence(zombieID, on: start)) { $0.selfNote = "felt fine" }
        XCTAssertEqual(seeded.calendarEventFeedbackRecords.count, 1)

        let relaunched = makeZombieSweepStore(suiteName, location)
        XCTAssertNotNil(relaunched.findCalendarEvent(id: zombieID))
        XCTAssertEqual(relaunched.calendarEventFeedbackRecords.count, 1)
    }

    /// A `.single` edit the user made before the split left a materialized
    /// exception parented to the zombie — a row they typed into, and one the
    /// `.all` delete would take with the series.
    @MainActor
    func testSweepKeepsZombieOwningExceptionInstance() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.exception"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let cal = zombieSweepCalendar
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "55000000-0000-0000-0000-000000000001")!
        let instanceID = UUID(uuidString: "55000000-0000-0000-0000-000000000002")!

        let seeded = makeZombieSweepStore(suiteName, location)
        let zombie = makeZombieSeries(id: zombieID, start: start)
        seeded.addCalendarEvent(zombie)
        var instance = zombie
        instance.id = instanceID
        instance.title = "The day I moved"
        instance.repeatUnit = .none
        instance.repeatEndType = .none
        instance.repeatEndDate = nil
        instance.recurrenceParentId = zombieID
        instance.recurrenceInstanceDate = cal.startOfDay(for: start)
        instance.recurrenceInstanceDayKey = Event.recurrenceDayKey(for: cal.startOfDay(for: start), calendar: cal)
        seeded.addCalendarEvent(instance)

        let relaunched = makeZombieSweepStore(suiteName, location)
        XCTAssertNotNil(relaunched.findCalendarEvent(id: zombieID), "the parent of a real row is kept")
        XCTAssertNotNil(relaunched.findCalendarEvent(id: instanceID), "and the row itself survives")
    }

    /// The one loss with no cloud and no legacy fallback. A photo only the
    /// zombie references makes the row `kept`; a photo the split-off sibling
    /// inherited BY VALUE does not, because `orphanedImageRefs` ref-counts it
    /// and stages nothing.
    @MainActor
    func testSweepKeepsZombieWithUniqueIntakeAsset() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.uniqueAsset"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "56000000-0000-0000-0000-000000000001")!
        let siblingID = UUID(uuidString: "56000000-0000-0000-0000-000000000002")!
        let ref = AgenticIntakeImageRef(
            relativePath: "\(zombieID.uuidString)/photo.jpg", pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1
        )

        let seeded = makeZombieSweepStore(suiteName, location)
        var zombie = makeZombieSeries(id: zombieID, start: start)
        zombie.agenticIntake = AgenticIntakeRecord(rawText: "", images: [ref], source: .classicFallback)
        seeded.addCalendarEvent(zombie)
        // A real partner, so the photo is the ONLY thing standing in the way.
        seeded.addCalendarEvent(makeMintPartner(id: siblingID, of: zombie, start: start))

        let relaunched = makeZombieSweepStore(suiteName, location)
        let kept = relaunched.findCalendarEvent(id: zombieID)
        XCTAssertNotNil(kept, "a photo no survivor references is not ours to destroy")
        XCTAssertEqual(kept.flatMap { relaunched.zombieSweepBlocker(for: $0) },
                       "owns intake image file(s) no survivor references")
    }

    /// The other side of that arm: a photo the split-off sibling inherited BY
    /// VALUE is not a blocker, because `orphanedImageRefs` ref-counts it and
    /// stages nothing. So the row classifies `deletable` — and, the delete arm
    /// being parked, keeps its photo and its place.
    @MainActor
    func testSweepReportsZombieWhoseAssetsTheSiblingSharesAsDeletable() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.sharedAsset"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "57000000-0000-0000-0000-000000000001")!
        let siblingID = UUID(uuidString: "57000000-0000-0000-0000-000000000002")!
        // Inherited BY VALUE at the split: the same `<zombie-id>/…` path on both rows.
        let ref = AgenticIntakeImageRef(
            relativePath: "\(zombieID.uuidString)/photo.jpg", pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1
        )

        let seeded = makeZombieSweepStore(suiteName, location)
        var zombie = makeZombieSeries(id: zombieID, start: start)
        zombie.agenticIntake = AgenticIntakeRecord(rawText: "", images: [ref], source: .classicFallback)
        seeded.addCalendarEvent(zombie)
        var sibling = makeMintPartner(id: siblingID, of: zombie, start: start)
        sibling.agenticIntake = AgenticIntakeRecord(rawText: "", images: [ref], source: .classicFallback)
        seeded.addCalendarEvent(sibling)
        XCTAssertTrue(
            EventStore.orphanedImageRefs(deleting: [zombieID], from: seeded.rawCalendarEvents).isEmpty,
            "the probe must be a genuinely shared ref — nothing is stageable"
        )

        let gap = Event.zombieRecurrenceSignatureDayGap(zombie) ?? -1
        let mark = zombieSweepTrailMark()
        let relaunched = makeZombieSweepStore(suiteName, location)
        let reported = relaunched.findCalendarEvent(id: zombieID)
        XCTAssertNotNil(reported, "report-only: the row stays whatever the classification says")
        XCTAssertNil(reported.flatMap { relaunched.zombieSweepBlocker(for: $0) },
                     "a shared ref is not a blocker")
        XCTAssertEqual(zombieSweepReport(since: mark), [
            "deletable id=\(zombieID.uuidString) gap=\(gap)d partner=\(siblingID.uuidString)",
            "done report-only candidates=1 deletable=1 kept=0",
        ])
        XCTAssertNotNil(relaunched.findCalendarEvent(id: zombieID)?.agenticIntake?.images.first,
                        "and both rows keep the photo they share")
        XCTAssertNotNil(relaunched.findCalendarEvent(id: siblingID)?.agenticIntake?.images.first)
    }

    /// A user-authored end date beyond the mint's own reach: the pair would
    /// have to sit inside `zombieMintShapeSeparation` (24 h…51 h) to be
    /// mint-shaped at all, and this one is ten days apart. Reported, kept.
    /// Stated in HOURS, never in days — a 50 h separation is a 3-calendar-day
    /// gap in plenty of reading zones, which is why the ceiling stopped being
    /// a day count in `2fe145e`.
    @MainActor
    func testSweepKeepsUserAuthoredEndBeforeStartBeyondMintShape() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.beyondMint"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let authoredID = UUID(uuidString: "58000000-0000-0000-0000-000000000001")!

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(makeZombieSeries(id: authoredID, title: "Typo, not a zombie", start: start, gapDays: 10))
        XCTAssertEqual(
            Event.zombieRecurrenceSignatureDayGap(seeded.findCalendarEvent(id: authoredID)!, calendar: zombieSweepCalendar),
            10, "it does match the signature — it just is not mint-shaped"
        )

        let relaunched = makeZombieSweepStore(suiteName, location)
        let kept = relaunched.findCalendarEvent(id: authoredID)
        XCTAssertNotNil(kept, "beyond the mint shape the sweep reports and keeps")
        let blocker = relaunched.zombieSweepBlocker(for: kept!) ?? ""
        XCTAssertTrue(blocker.contains("beyond the mint shape"), "blocker was: \(blocker)")
        // Stated as a raw separation, not as a day gap: ~249h for a 10-day gap
        // at a 09:00 seed, and that number is the same in every reading zone.
        XCTAssertTrue(blocker.contains("h before the seed"), "blocker was: \(blocker)")
        XCTAssertEqual(blocker, Event.zombieMintShapeRefusal(kept!, calendar: zombieSweepCalendar),
                       "the store's blocker and the pure predicate are one predicate")
    }

    /// THE DEFECT (gh#150 panel, blocking): a lone end-before-start row INSIDE
    /// the separation window, produced the way a user reaches it — an `.all`
    /// edit that drags a legitimate "ends on its own start day" series one day
    /// later. Shape says deletable; nothing stands beside it; the sweep must
    /// classify it `kept` and say why. Before the twin requirement this row was removed from
    /// memory AND from the committed slot, and the removal rode the next
    /// diff-push out as a hard DELETE.
    @MainActor
    func testSweepKeepsLoneEndBeforeStartRowInsideTheMintWindow() throws {
        let suiteName = "CalendarDragLogicTests.zombieSweep.noPartner"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let cal = zombieSweepCalendar
        let seed = recurrenceDate(2026, 3, 10)
        let rowID = UUID(uuidString: "5F000000-0000-0000-0000-000000000001")!

        var series = makeHealthySeries(id: rowID, title: "Gym", start: seed)
        series.repeatEndType = .onDate
        series.repeatEndDate = cal.startOfDay(for: seed)
        let movedStart = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: seed))
        let moved = try XCTUnwrap(Event.applyEdit(
            series: series, occurrenceDate: seed, scope: .all,
            edit: { $0.timeRanges = [Event.TimeRange(start: movedStart, end: movedStart.addingTimeInterval(3600))] },
            calendar: cal
        ).updatedSeries)
        XCTAssertNil(Event.zombieMintShapeRefusal(moved, calendar: cal),
                     "the fixture must be mint-SHAPED or this test proves nothing")

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(moved)

        let mark = zombieSweepTrailMark()
        let relaunched = makeZombieSweepStore(suiteName, location)
        let kept = try XCTUnwrap(relaunched.findCalendarEvent(id: rowID),
                                 "a row the user's own edit produced must not be auto-deleted")
        XCTAssertEqual(kept.repeatEndDate, moved.repeatEndDate, "and it is kept unmodified")
        let blocker = try XCTUnwrap(relaunched.zombieSweepBlocker(for: kept))
        XCTAssertTrue(blocker.contains("no partner series"), "blocker was: \(blocker)")
        let gap = Event.zombieRecurrenceSignatureDayGap(moved) ?? -1
        XCTAssertEqual(zombieSweepReport(since: mark), [
            "kept id=\(rowID.uuidString) gap=\(gap)d: \(blocker)",
            "done report-only candidates=1 deletable=0 kept=1",
        ], "the trail reports it and names the reason")

        let third = makeZombieSweepStore(suiteName, location)
        XCTAssertNotNil(third.findCalendarEvent(id: rowID),
                        "still on disk — nothing reached the committed slot either")
    }

    /// THE ROUND-2 DEFECT (gh#150 review, blocking): the same user-dragged row,
    /// this time with an unrelated lookalike standing next to it. At `3d1aff0`
    /// the lookalike vouched — {title, unit, interval} was the whole match — and
    /// the row was removed from memory AND from the committed slot, and the
    /// removal rode the next diff-push out as a hard DELETE. It must survive
    /// both launches with the notes it carries.
    @MainActor
    func testSweepKeepsRowAnUnrelatedLookalikeWouldHaveVouchedFor() throws {
        let suiteName = "CalendarDragLogicTests.zombieSweep.lookalike"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let rowID = UUID(uuidString: "5A000000-0000-0000-0000-000000000001")!
        let lookalikeID = UUID(uuidString: "5A000000-0000-0000-0000-000000000002")!

        var dragged = try makeDraggedPastItsOwnEndRow(id: rowID, title: "Gym")
        dragged.note = "the notes that would have gone with it"
        XCTAssertNil(Event.zombieMintShapeRefusal(dragged, calendar: zombieSweepCalendar),
                     "the fixture must be mint-SHAPED or this test proves nothing")
        let draggedSeed = try XCTUnwrap(dragged.primaryTimeRange?.start)

        // "It disappeared, let me make it again": a second daily "Gym", created
        // by hand on the same morning, with the user's own type and length.
        var lookalike = makeHealthySeries(id: lookalikeID, title: "Gym", start: draggedSeed)
        lookalike.type = "Life"
        lookalike.timeRanges = [Event.TimeRange(start: draggedSeed, end: draggedSeed.addingTimeInterval(4 * 3600))]

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(dragged)
        seeded.addCalendarEvent(lookalike)

        let relaunched = makeZombieSweepStore(suiteName, location)
        let kept = try XCTUnwrap(relaunched.findCalendarEvent(id: rowID),
                                 "an unrelated lookalike is not evidence of a split")
        XCTAssertEqual(kept.note, dragged.note, "and the row is kept whole")
        XCTAssertNotNil(relaunched.findCalendarEvent(id: lookalikeID), "the lookalike is untouched too")
        let blocker = try XCTUnwrap(relaunched.zombieSweepBlocker(for: kept))
        XCTAssertTrue(blocker.contains("no partner series"), "blocker was: \(blocker)")

        let third = makeZombieSweepStore(suiteName, location)
        XCTAssertNotNil(third.findCalendarEvent(id: rowID),
                        "still on disk — no hard DELETE was ever staged for the wire")
        XCTAssertEqual(third.rawCalendarEvents.count, 2)
    }

    /// The other direction, from the REAL mint site rather than a fixture: run
    /// the pre-c19aa55 first-occurrence `.following` split, put both of its rows
    /// in the store, and the capped half — and only it — is reported deletable
    /// next launch. Both halves survive, which is the point: this pair and a
    /// hand-made duplicate are the same bytes, and only one of the two is
    /// debris.
    @MainActor
    func testSweepReportsTheRealMintPairsCappedHalfAsDeletableAndKeepsBoth() throws {
        let suiteName = "CalendarDragLogicTests.zombieSweep.realPair"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let cal = zombieSweepCalendar
        let start = recurrenceDate(2026, 3, 10)
        let seriesID = UUID(uuidString: "5F000000-0000-0000-0000-000000000002")!

        let result = Event.applyEdit(
            series: makeHealthySeries(id: seriesID, title: "Gym", start: start),
            occurrenceDate: start, scope: .following, edit: { _ in }, calendar: cal
        )
        let capped = try XCTUnwrap(result.updatedSeries)
        let replacement = try XCTUnwrap(result.newSeries)

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(capped)
        seeded.addCalendarEvent(replacement)

        let gap = Event.zombieRecurrenceSignatureDayGap(capped) ?? -1
        let mark = zombieSweepTrailMark()
        let relaunched = makeZombieSweepStore(suiteName, location)
        let reported = try XCTUnwrap(relaunched.findCalendarEvent(id: seriesID),
                                     "the capped half is the zombie — and it is still here")
        XCTAssertNotNil(relaunched.findCalendarEvent(id: replacement.id), "so is the half that renders")
        XCTAssertNil(relaunched.zombieSweepBlocker(for: reported),
                     "nothing blocks the capped half; it is the class the delete arm existed for")

        // Only the capped half is a candidate at all — the replacement never
        // reaches the classifier, so it can never be named by one of its lines
        // except as the partner.
        XCTAssertNil(Event.zombieRecurrenceSignatureDayGap(replacement))
        XCTAssertEqual(zombieSweepReport(since: mark), [
            "deletable id=\(seriesID.uuidString) gap=\(gap)d partner=\(replacement.id.uuidString)",
            "done report-only candidates=1 deletable=1 kept=0",
        ], "the report names the row that would have been its evidence")

        let third = makeZombieSweepStore(suiteName, location)
        XCTAssertEqual(third.rawCalendarEvents.count, 2, "both halves are still in the committed slot file")
    }

    /// The witness arm, end to end through the store: a legitimate
    /// ends-on-start-day series authored on the longest day in the tz database
    /// clears the separation floor, so on this device nothing but
    /// `zombieEndsOnStartDayWitness` keeps it. Mutate that arm to `return nil`
    /// and this row is reported `deletable` — the verdict the parked delete arm
    /// would have destroyed it on.
    @MainActor
    func testSweepKeepsLegitEndsOnStartDaySeriesWhoseOnlyDefenceIsTheWitness() throws {
        let suiteName = "CalendarDragLogicTests.zombieSweep.witness"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let longest = try XCTUnwrap(longestTimeZoneDatabaseDay())
        XCTAssertGreaterThanOrEqual(longest.length, 25 * 3600,
                                    "no >25h day left in the tz database — re-derive this fixture")
        var authoring = Calendar(identifier: .gregorian)
        authoring.timeZone = longest.zone
        let legitID = UUID(uuidString: "5F000000-0000-0000-0000-000000000003")!

        let seed = longest.dayStart.addingTimeInterval(longest.length - 3600)
        var legit = makeHealthySeries(id: legitID, title: "One day only", start: seed)
        legit.repeatEndType = .onDate
        legit.repeatEndDate = authoring.startOfDay(for: seed)

        // Non-vacuous here, on this device: it IS a candidate, and the
        // separation window does NOT exclude it.
        XCTAssertNotNil(Event.zombieRecurrenceSignatureDayGap(legit, calendar: zombieSweepCalendar),
                        "the fixture must be a candidate in the test's own zone or nothing is being tested")
        let separation = try XCTUnwrap(Event.zombieRecurrenceEndToSeedSeparation(legit))
        XCTAssertTrue(Event.zombieMintShapeSeparation.contains(separation),
                      "the separation arm must be powerless here (\(separation / 3600)h)")

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(legit)

        let relaunched = makeZombieSweepStore(suiteName, location)
        let kept = try XCTUnwrap(relaunched.findCalendarEvent(id: legitID),
                                 "a legitimate ends-on-start-day series is never swept, from any zone")
        let blocker = try XCTUnwrap(relaunched.zombieSweepBlocker(for: kept))
        XCTAssertTrue(blocker.contains("reads the end as the start of the seed's own day"),
                      "and the WITNESS is what kept it, not a later arm: \(blocker)")

        let third = makeZombieSweepStore(suiteName, location)
        XCTAssertNotNil(third.findCalendarEvent(id: legitID), "still in the committed slot file")
    }

    /// Interrupt children and absorbed todos are NOT blockers: the sanctioned
    /// `.all` delete the parked arm would have called hands both back
    /// non-destructively, so neither of them can make a row `kept`. What the
    /// report-only sweep must NOT do is hand them back anyway — a satellite
    /// that gets orphaned or released without its parent going anywhere is a
    /// mutation with nothing to show for it.
    @MainActor
    func testSweepReportsZombieWithNonDestructiveSatellitesWithoutDetachingThem() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.satellites"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "59000000-0000-0000-0000-000000000001")!
        let childID = UUID(uuidString: "59000000-0000-0000-0000-000000000002")!
        let todoID = UUID(uuidString: "59000000-0000-0000-0000-000000000003")!
        let partnerID = UUID(uuidString: "59000000-0000-0000-0000-000000000004")!

        let seeded = makeZombieSweepStore(suiteName, location)
        let zombie = makeZombieSeries(id: zombieID, start: start)
        seeded.addCalendarEvent(zombie)
        seeded.addCalendarEvent(makeMintPartner(id: partnerID, of: zombie, start: start))
        var child = Event(
            id: childID,
            title: "Interrupt",
            timeRanges: [Event.TimeRange(start: start.addingTimeInterval(900), end: start.addingTimeInterval(1800))],
            type: "Study"
        )
        child.displayKind = .interrupt
        child.interruptRelation = EventInterruptRelation(
            parentEventID: zombieID,
            baseSeriesEventID: zombieID,
            occurrenceDate: zombieSweepCalendar.startOfDay(for: start)
        )
        seeded.addCalendarEvent(child)
        var todo = Event(
            id: todoID,
            title: "Absorbed",
            timeRanges: [Event.TimeRange(start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000))],
            type: "Study"
        )
        todo.kind = .todo
        todo.absorbedIntoEventID = zombieID
        seeded.addCalendarEvent(todo)
        // The child's state BEFORE any sweep has run. `resolveInterruptRelationState`
        // already orphans it at load, because the zombie renders no occurrence
        // for the parent range to be found in — so `.orphaned` here is the
        // relation resolver's ordinary work, and reading it now is what stops
        // the assertion below from crediting it to the sweep.
        let seededChildState = seeded.findCalendarEvent(id: childID)?.interruptRelation?.state

        let gap = Event.zombieRecurrenceSignatureDayGap(zombie) ?? -1
        let mark = zombieSweepTrailMark()
        let relaunched = makeZombieSweepStore(suiteName, location)
        let reported = relaunched.findCalendarEvent(id: zombieID)
        XCTAssertNotNil(reported, "the row stays")
        XCTAssertNil(reported.flatMap { relaunched.zombieSweepBlocker(for: $0) },
                     "neither satellite is a blocker")
        XCTAssertEqual(zombieSweepReport(since: mark), [
            "deletable id=\(zombieID.uuidString) gap=\(gap)d partner=\(partnerID.uuidString)",
            "done report-only candidates=1 deletable=1 kept=0",
        ])
        // These two pin the relation's SHAPE, not the parking: an `.all` delete
        // writes back the same `.orphaned` the load-time resolver already wrote
        // and keeps parentEventID, so neither line moves if the delete arm comes
        // back (measured). They would catch a sweep that re-embedded or cleared
        // the relation. The absorbed todo below is the satellite that actually
        // distinguishes parked from unparked — releasing it is delete-only.
        XCTAssertEqual(relaunched.findCalendarEvent(id: childID)?.interruptRelation?.parentEventID, zombieID,
                       "the interrupt child still points at the parent that never left")
        XCTAssertEqual(relaunched.findCalendarEvent(id: childID)?.interruptRelation?.state, seededChildState,
                       "and its state is exactly what the relation resolver had already made it")
        XCTAssertEqual(relaunched.findCalendarEvent(id: todoID)?.absorbedIntoEventID, zombieID,
                       "the absorbed todo is still absorbed — the delete's release never ran")
        XCTAssertEqual(relaunched.rawCalendarEvents.count, 4)
    }

    // MARK: gh#150 — refusals

    /// A restore marker still standing after `replayPendingRestoreIfNeeded`
    /// means five slots are about to be rewritten. Judging "satellite-free" on
    /// rows that are not the final ones is exactly how a sweep destroys
    /// history, so it refuses.
    @MainActor
    func testZombieSweepRefusalWhenRestorePending() throws {
        let suiteName = "CalendarDragLogicTests.zombieSweep.restorePending"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "5A000000-0000-0000-0000-000000000001")!

        let store = makeZombieSweepStore(suiteName, location)
        store.addCalendarEvent(makeZombieSeries(id: zombieID, start: start))
        XCTAssertNil(store.zombieSweepRefusal, "a healthy store refuses nothing")

        _ = try store.storage.recordPendingWork(kind: "restore", payload: Data("{}".utf8))

        let refusal = try XCTUnwrap(store.zombieSweepRefusal)
        XCTAssertTrue(refusal.contains("restore marker"), "got: \(refusal)")
    }

    /// The behavioural half of the refusal, end to end: a slot that could not
    /// be read this launch freezes, the calendar slot loads the zombie
    /// perfectly well — and the sweep still declines to CLASSIFY, because the
    /// rows that would have made the zombie `kept` may be the ones that are
    /// missing. A `deletable` line derived from half a store is a misleading
    /// line in a file the user exports and hands to someone, so the refusal
    /// short-circuits ahead of the classifier and emits `skipped` alone.
    @MainActor
    func testSweepRefusesToClassifyAtAllWhileAnotherSlotIsFrozen() throws {
        let suiteName = "CalendarDragLogicTests.zombieSweep.frozenSlot"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let zombieID = UUID(uuidString: "5B000000-0000-0000-0000-000000000001")!
        let anchorID = UUID(uuidString: "5B000000-0000-0000-0000-000000000002")!
        let partnerID = UUID(uuidString: "5B000000-0000-0000-0000-000000000003")!

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(Event(
            id: anchorID,
            title: "Anchor",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(1800))],
            type: "Study"
        ))
        seeded.upsertLogRecord(for: zombieSweepOccurrence(anchorID, on: start)) { $0.note = "unrelated" }
        let zombie = makeZombieSeries(id: zombieID, start: start)
        seeded.addCalendarEvent(zombie)
        seeded.addCalendarEvent(makeMintPartner(id: partnerID, of: zombie, start: start))

        // Shred a NON-calendar slot: the zombie still loads perfectly, and the
        // store is still incomplete.
        let directory = try location.directoryURL()
        let logPrimary = directory.appendingPathComponent(StorageSlot.calendarEventLogRecords.filename)
        let goodBytes = try Data(contentsOf: logPrimary)
        try Data("shredded".utf8).write(to: logPrimary)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(StorageSlot.calendarEventLogRecords.backupFilename))

        let gap = Event.zombieRecurrenceSignatureDayGap(zombie) ?? -1
        let degradedMark = zombieSweepTrailMark()
        let degraded = makeZombieSweepStore(suiteName, location)
        XCTAssertTrue(degraded.isSlotFrozen(.calendarEventLogRecords), "the probe must actually freeze a slot")
        XCTAssertNotNil(degraded.zombieSweepRefusal)
        XCTAssertNotNil(degraded.findCalendarEvent(id: zombieID),
                        "a launch that cannot see every satellite touches nothing")
        let degradedReport = zombieSweepReport(since: degradedMark)
        XCTAssertEqual(degradedReport.count, 1, "one line only: \(degradedReport)")
        XCTAssertTrue(degradedReport.first?.hasPrefix("skipped 1 candidate(s): ") == true,
                      "and it is the refusal: \(degradedReport)")
        XCTAssertFalse(degradedReport.contains { $0.hasPrefix("deletable") || $0.hasPrefix("kept") },
                       "no row is classified from half a store: \(degradedReport)")
        XCTAssertFalse(degradedReport.contains { $0.hasPrefix("done") },
                       "and the run does not claim to have finished one: \(degradedReport)")

        // The fault was transient — and the sweep is not a one-shot, so the
        // next healthy launch does the classifying no flag would have let it
        // redo. It still removes nothing.
        try goodBytes.write(to: logPrimary)
        let healthyMark = zombieSweepTrailMark()
        let healthy = makeZombieSweepStore(suiteName, location)
        XCTAssertFalse(healthy.isSlotFrozen(.calendarEventLogRecords))
        XCTAssertNil(healthy.zombieSweepRefusal)
        XCTAssertNotNil(healthy.findCalendarEvent(id: zombieID), "report-only, on this launch too")
        XCTAssertEqual(zombieSweepReport(since: healthyMark), [
            "deletable id=\(zombieID.uuidString) gap=\(gap)d partner=\(partnerID.uuidString)",
            "done report-only candidates=1 deletable=1 kept=0",
        ], "the classification the frozen launch withheld")
        XCTAssertEqual(healthy.calendarEventLogRecords.count, 1,
                       "the unrelated record came back with its slot")
    }

    /// The ordinary launch, which is every launch for almost every user: no
    /// candidate, no write, and not one line in the trail.
    @MainActor
    func testSweepQuietAndHarmlessOnCleanStore() {
        let suiteName = "CalendarDragLogicTests.zombieSweep.clean"
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let start = recurrenceDate(2026, 3, 10)
        let cal = zombieSweepCalendar
        let dailyID = UUID(uuidString: "5C000000-0000-0000-0000-000000000001")!
        let oneDayID = UUID(uuidString: "5C000000-0000-0000-0000-000000000002")!
        let boundedID = UUID(uuidString: "5C000000-0000-0000-0000-000000000003")!

        let seeded = makeZombieSweepStore(suiteName, location)
        seeded.addCalendarEvent(makeHealthySeries(id: dailyID, title: "Daily", start: start))
        // The legitimate single-occurrence rule: ends on the day it starts.
        var oneDay = makeHealthySeries(id: oneDayID, title: "Just today", start: start)
        oneDay.repeatEndType = .onDate
        oneDay.repeatEndDate = cal.startOfDay(for: start)
        seeded.addCalendarEvent(oneDay)
        var bounded = makeHealthySeries(id: boundedID, title: "Two weeks", start: start)
        bounded.repeatEndType = .onDate
        bounded.repeatEndDate = cal.date(byAdding: .day, value: 14, to: start)!
        seeded.addCalendarEvent(bounded)
        let expected = seeded.rawCalendarEvents.map(\.id)

        let mark = zombieSweepTrailMark()
        let relaunched = makeZombieSweepStore(suiteName, location)

        XCTAssertEqual(relaunched.rawCalendarEvents.map(\.id), expected, "no row is touched")
        XCTAssertEqual(zombieSweepReport(since: mark), [],
                       "a scan with no candidates writes nothing at all — not even a done line")
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
