//
//  OrientationDwellTests.swift
//  DoneTests
//
//  `UIDevice.orientationDidChangeNotification` is a gravity reading: it
//  fires on small tilts and on the settling wobble at the end of a
//  deliberate rotation. `OrientationManager` used to turn every one of
//  those into an app-wide state flip, so a transient the user never
//  intended reached `DoneApp`, `ContentView`, `CalendarPageView` and
//  `TodoStackDrawer` — and, per gh#171, could revoke a focus dismissal
//  that was already in flight.
//
//  The fix is hysteresis: an orientation must HOLD for
//  `orientationDwellSeconds` before it is published. These tests pin the
//  pure decision function (`orientationDwellDecision`) and the thin shell
//  around it. Time is injected as `CFTimeInterval` — the production code
//  reads `CACurrentMediaTime()`, which is monotonic, so nothing here
//  depends on the wall clock or on real elapsed time.
//
//  gh#172.
//

import XCTest
import UIKit
import QuartzCore
@testable import Done

@MainActor
final class OrientationDwellTests: XCTestCase {

    private let dwell: CFTimeInterval = 0.25

    // MARK: - Duplicate suppression (K2)

    /// The observation agrees with what subscribers already see, so nothing
    /// is published. Before this guard, `update()` assigned `isLandscape`
    /// unconditionally and every redundant notification fired
    /// `objectWillChange` inside a 0.4 s animation transaction.
    func testAgreeingObservationPublishesNothing() {
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: nil,
                                     candidate: false, now: 10, dwell: dwell),
            .idle
        )
        XCTAssertEqual(
            orientationDwellDecision(published: true, pending: nil,
                                     candidate: true, now: 10, dwell: dwell),
            .idle
        )
    }

    /// A landscapeLeft -> landscapeRight notification resolves to the same
    /// bit, so it is a duplicate too. The manager publishes one bit, not a
    /// four-way orientation.
    func testSameBitFromADifferentDeviceOrientationIsStillADuplicate() {
        // Both `.landscapeLeft` and `.landscapeRight` map to `true`.
        XCTAssertTrue(UIDeviceOrientation.landscapeLeft.isLandscape)
        XCTAssertTrue(UIDeviceOrientation.landscapeRight.isLandscape)
        XCTAssertFalse(UIDeviceOrientation.portrait.isLandscape)
        XCTAssertEqual(
            orientationDwellDecision(published: true, pending: nil,
                                     candidate: true, now: 10, dwell: dwell),
            .idle
        )
    }

    // MARK: - Dwell (K1)

    /// A disagreeing candidate does not publish on arrival; it starts a
    /// window and asks to be re-examined when the window closes.
    func testDisagreeingObservationStartsTheWindowRatherThanPublishing() {
        let decision = orientationDwellDecision(
            published: false, pending: nil, candidate: true, now: 100, dwell: dwell
        )
        XCTAssertEqual(
            decision,
            .hold(OrientationDwellCandidate(landscape: true, since: 100), after: 0.25)
        )
    }

    /// Held past the window: publish.
    func testCandidateThatHoldsPastTheWindowPublishes() {
        let pending = OrientationDwellCandidate(landscape: true, since: 100)
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: pending,
                                     candidate: true, now: 100.3, dwell: dwell),
            .publish(true)
        )
    }

    /// The boundary is inclusive: at exactly `dwell` the candidate has held
    /// long enough. Pinned so a later `>` / `>=` edit is a test failure and
    /// not a silent extra frame of latency.
    func testWindowBoundaryIsInclusive() {
        let pending = OrientationDwellCandidate(landscape: true, since: 100)
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: pending,
                                     candidate: true, now: 100 + dwell, dwell: dwell),
            .publish(true)
        )
        // One tick short still holds.
        guard case .hold = orientationDwellDecision(
            published: false, pending: pending,
            candidate: true, now: 100 + dwell - 0.001, dwell: dwell
        ) else {
            return XCTFail("just inside the window must still hold")
        }
    }

    /// THE POINT OF THE SLICE: a tilt that reverts inside the window is
    /// dropped, and the revert also clears the pending candidate so no
    /// wake-up can resurrect it.
    func testTransientThatRevertsInsideTheWindowNeverPublishes() {
        // t=100.00 device tips into landscape.
        let first = orientationDwellDecision(
            published: false, pending: nil, candidate: true, now: 100, dwell: dwell
        )
        guard case let .hold(pending, _) = first else {
            return XCTFail("expected the tilt to be held, got \(first)")
        }
        // t=100.08 it falls back to portrait, well inside the window.
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: pending,
                                     candidate: false, now: 100.08, dwell: dwell),
            .idle
        )
    }

    /// The window is measured from when the candidate was FIRST seen, not
    /// from the most recent notification. A stream of notifications during
    /// one continuous rotation must not push the deadline forward — the
    /// re-arming wall-clock window is the failure mode this pins against.
    func testRepeatedObservationsDoNotRestartTheWindow() {
        var pending = OrientationDwellCandidate(landscape: true, since: 100)
        // Three more landscape samples while the device is being turned.
        for now in [100.05, 100.10, 100.20] as [CFTimeInterval] {
            let decision = orientationDwellDecision(
                published: false, pending: pending, candidate: true, now: now, dwell: dwell
            )
            guard case let .hold(next, after) = decision else {
                return XCTFail("expected hold at \(now), got \(decision)")
            }
            XCTAssertEqual(next.since, 100, "the window must keep its original stamp")
            XCTAssertEqual(after, 100 + dwell - now, accuracy: 1e-9,
                           "the remaining wait must shrink, not reset")
            pending = next
        }
        // And it still lands on schedule rather than 0.25 s after the last
        // sample (which would be 100.45).
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: pending,
                                     candidate: true, now: 100.25, dwell: dwell),
            .publish(true)
        )
    }

    /// `CACurrentMediaTime()` is monotonic, but the arithmetic should not
    /// depend on that: a backwards `now` must not produce a wait longer
    /// than the dwell (or a negative one).
    func testBackwardsClockIsClampedToTheFullWindow() {
        let pending = OrientationDwellCandidate(landscape: true, since: 100)
        let decision = orientationDwellDecision(
            published: false, pending: pending, candidate: true, now: 99.5, dwell: dwell
        )
        guard case let .hold(_, after) = decision else {
            return XCTFail("expected hold, got \(decision)")
        }
        XCTAssertEqual(after, dwell, accuracy: 1e-9)
    }

    /// A zero (or negative) dwell degrades to publish-on-arrival, i.e. the
    /// pre-gh#172 behaviour. Keeps the function total.
    func testZeroDwellPublishesImmediately() {
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: nil,
                                     candidate: true, now: 100, dwell: 0),
            .publish(true)
        )
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: nil,
                                     candidate: true, now: 100, dwell: -1),
            .publish(true)
        )
    }

    /// The exit direction is symmetric — leaving landscape dwells exactly
    /// as entering it does. Landscape focus exit therefore cannot be
    /// triggered by a single portrait sample.
    func testExitDirectionDwellsToo() {
        let first = orientationDwellDecision(
            published: true, pending: nil, candidate: false, now: 200, dwell: dwell
        )
        XCTAssertEqual(
            first,
            .hold(OrientationDwellCandidate(landscape: false, since: 200), after: dwell)
        )
        guard case let .hold(pending, _) = first else { return }
        XCTAssertEqual(
            orientationDwellDecision(published: true, pending: pending,
                                     candidate: false, now: 200 + dwell, dwell: dwell),
            .publish(false)
        )
    }

    // MARK: - gh#171 shape

    /// gh#171's revocation: a spurious `.landscapeLeft` arrives while the
    /// focus exit animation is in flight, after the user has already
    /// rotated back to portrait. With the dwell, that sample has to hold
    /// for 0.25 s to be believed; because the device is physically
    /// portrait, the next sample contradicts it and nothing is published.
    ///
    /// Note the scope of what this proves: it proves the filter drops a
    /// sample that reverts inside 0.25 s. Whether the real spurious sample
    /// reverts that fast is a device-timing question this test cannot
    /// answer.
    func testSpuriousLandscapeDuringExitFlightIsNotBelieved() {
        // Published state has just flipped to portrait; exit is animating.
        let published = false
        let spurious = orientationDwellDecision(
            published: published, pending: nil, candidate: true, now: 300, dwell: dwell
        )
        guard case let .hold(pending, _) = spurious else {
            return XCTFail("the spurious sample must not publish on arrival")
        }
        // The device is actually portrait, so the next reading contradicts.
        XCTAssertEqual(
            orientationDwellDecision(published: published, pending: pending,
                                     candidate: false, now: 300.12, dwell: dwell),
            .idle
        )
    }

    // MARK: - The constant

    /// The dwell must stay under the transition it gates (this manager's own
    /// 0.4 s enter animation) and under `ContentView`'s 0.6 s day-offset
    /// unfreeze, or it would start reordering things downstream.
    func testDwellConstantStaysUnderTheTransitionsItGates() {
        XCTAssertEqual(orientationDwellSeconds, 0.25, accuracy: 1e-9)
        XCTAssertLessThan(orientationDwellSeconds, 0.4, "the 0.4 s enter animation")
        XCTAssertLessThan(orientationDwellSeconds, 0.6, "ContentView's unfreeze delay")
        XCTAssertGreaterThan(orientationDwellSeconds, 0)
    }

    // MARK: - Shell wiring

    /// The manager itself, driven with an injected clock: a tilt that
    /// reverts inside the window never reaches `isLandscape`, so no
    /// subscriber is ever invalidated by it.
    func testManagerDoesNotPublishATransientTilt() {
        let manager = OrientationManager()
        XCTAssertFalse(manager.isLandscape)

        manager.observe(true, at: 1_000)
        XCTAssertFalse(manager.isLandscape, "arrival alone must not publish")

        manager.observe(false, at: 1_000.1)
        XCTAssertFalse(manager.isLandscape, "the revert must leave the published bit alone")

        // And the revert must have dropped the candidate, so a later
        // landscape sample starts a fresh window rather than inheriting the
        // old one and publishing at once.
        manager.observe(true, at: 1_000.2)
        XCTAssertFalse(manager.isLandscape)
    }

    /// A held rotation does publish, in both directions.
    func testManagerPublishesAHeldRotation() {
        let manager = OrientationManager()

        manager.observe(true, at: 2_000)
        XCTAssertFalse(manager.isLandscape)
        manager.observe(true, at: 2_000 + orientationDwellSeconds)
        XCTAssertTrue(manager.isLandscape)

        manager.observe(false, at: 2_001)
        XCTAssertTrue(manager.isLandscape, "the exit dwells as well")
        manager.observe(false, at: 2_001 + orientationDwellSeconds)
        XCTAssertFalse(manager.isLandscape)
    }

    /// The first reading is not exempt from the dwell — a launch that is
    /// already rotated still waits it out. Documented as deliberate in
    /// `OrientationManager`: the seed `false` agrees with what the portrait
    /// lock is already rendering, so nothing is shown wrongly in between.
    func testLaunchAlreadyRotatedIsNotExemptFromTheDwell() {
        let manager = OrientationManager()
        manager.observe(true, at: 0)
        XCTAssertFalse(manager.isLandscape)
        manager.observe(true, at: orientationDwellSeconds)
        XCTAssertTrue(manager.isLandscape)
    }

    /// Rotation must not disturb manual focus — the pre-existing decision
    /// this slice deliberately did not change.
    func testPublishingAnOrientationDoesNotClearManualFocus() {
        let manager = OrientationManager()
        manager.manualFocusActive = true
        manager.observe(true, at: 3_000)
        manager.observe(true, at: 3_000 + orientationDwellSeconds)
        XCTAssertTrue(manager.isLandscape)
        XCTAssertTrue(manager.manualFocusActive)

        manager.observe(false, at: 3_001)
        manager.observe(false, at: 3_001 + orientationDwellSeconds)
        XCTAssertFalse(manager.isLandscape)
        XCTAssertTrue(manager.manualFocusActive)
    }
}
