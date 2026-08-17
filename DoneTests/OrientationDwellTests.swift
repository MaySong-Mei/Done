//
//  OrientationDwellTests.swift
//  DoneTests
//
//  `OrientationManager` used to turn every
//  `UIDevice.orientationDidChangeNotification` into an app-wide state flip,
//  so any sample the user never intended reached `DoneApp`, `ContentView`,
//  `CalendarPageView` and `TodoStackDrawer` — and, per gh#171, could revoke
//  a focus dismissal that was already in flight.
//
//  The fix is hysteresis: an orientation must HOLD before it is published.
//  Note the scope of what these tests can establish. They pin the *rule* —
//  that a sample which reverts inside the window is dropped, that the window
//  does not re-arm, that the two directions dwell differently. They do NOT
//  establish that gravity emits such samples unprompted; that premise is
//  unverified and a simulator cannot test it even in principle (no
//  accelerometer, orientation is a discrete menu-set value). See "Why a
//  dwell" on `OrientationManager` for what would settle it.
//
//  Time is injected as `CFTimeInterval` — production reads
//  `CACurrentMediaTime()`, which is monotonic — so nothing here depends on
//  the wall clock. The one exception is
//  `testWakeUpTaskPublishesWithoutASecondObservation`, which must let the
//  real wake-up task fire; it constructs its manager with
//  `observeNotifications: false` so the live stream cannot land inside its
//  await.
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
    /// A symmetric policy, for the tests that are about the rule rather than
    /// about the asymmetry.
    private let symmetric = OrientationDwellPolicy(enter: 0.25, exit: 0.25)

    // MARK: - Duplicate suppression (K2)

    /// The observation agrees with what subscribers already see, so nothing
    /// is published. Before this guard, `update()` assigned `isLandscape`
    /// unconditionally and every redundant notification fired
    /// `objectWillChange` inside a 0.4 s animation transaction.
    func testAgreeingObservationPublishesNothing() {
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: nil,
                                     candidate: false, now: 10, policy: symmetric),
            .idle
        )
        XCTAssertEqual(
            orientationDwellDecision(published: true, pending: nil,
                                     candidate: true, now: 10, policy: symmetric),
            .idle
        )
    }

    /// The device-orientation mapping the subscription actually uses, over
    /// all seven cases. `.landscapeLeft` and `.landscapeRight` collapse to
    /// the same bit, so a left→right notification is a duplicate: the manager
    /// publishes one bit, not a four-way orientation.
    ///
    /// This reaches `orientationLandscapeSample`, which the production
    /// subscription in `OrientationManager.init` calls at its single call
    /// site. It does not — and cannot, on a simulator — prove the
    /// notification is delivered: `UIDevice.current.orientation` is not
    /// settable and there is no accelerometer to drive it.
    func testDeviceOrientationMapsToOneBitAndDropsTheFlatSamples() {
        XCTAssertEqual(orientationLandscapeSample(.landscapeLeft), true)
        XCTAssertEqual(orientationLandscapeSample(.landscapeRight), true)
        XCTAssertEqual(orientationLandscapeSample(.portrait), false)
        XCTAssertEqual(orientationLandscapeSample(.portraitUpsideDown), false)
        // Flat and unknown carry no landscape/portrait meaning. Apple's
        // `isLandscape` reports `false` for all three, which would read as a
        // portrait sample; dropping them is the point of the `Bool?`.
        XCTAssertNil(orientationLandscapeSample(.faceUp))
        XCTAssertNil(orientationLandscapeSample(.faceDown))
        XCTAssertNil(orientationLandscapeSample(.unknown))

        // And having collapsed to one bit, the second landscape sample is a
        // duplicate.
        XCTAssertEqual(
            orientationDwellDecision(published: true, pending: nil,
                                     candidate: true, now: 10, policy: symmetric),
            .idle
        )
    }

    // MARK: - Dwell (K1)

    /// A disagreeing candidate does not publish on arrival; it starts a
    /// window and asks to be re-examined when the window closes.
    func testDisagreeingObservationStartsTheWindowRatherThanPublishing() {
        let decision = orientationDwellDecision(
            published: false, pending: nil, candidate: true, now: 100, policy: symmetric
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
                                     candidate: true, now: 100.3, policy: symmetric),
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
                                     candidate: true, now: 100 + dwell, policy: symmetric),
            .publish(true)
        )
        // One tick short still holds.
        guard case .hold = orientationDwellDecision(
            published: false, pending: pending,
            candidate: true, now: 100 + dwell - 0.001, policy: symmetric
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
            published: false, pending: nil, candidate: true, now: 100, policy: symmetric
        )
        guard case let .hold(pending, _) = first else {
            return XCTFail("expected the tilt to be held, got \(first)")
        }
        // t=100.08 it falls back to portrait, well inside the window.
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: pending,
                                     candidate: false, now: 100.08, policy: symmetric),
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
                published: false, pending: pending, candidate: true, now: now, policy: symmetric
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
                                     candidate: true, now: 100.25, policy: symmetric),
            .publish(true)
        )
    }

    /// `CACurrentMediaTime()` is monotonic, but the arithmetic should not
    /// depend on that: a backwards `now` must not produce a wait longer
    /// than the dwell (or a negative one).
    func testBackwardsClockIsClampedToTheFullWindow() {
        let pending = OrientationDwellCandidate(landscape: true, since: 100)
        let decision = orientationDwellDecision(
            published: false, pending: pending, candidate: true, now: 99.5, policy: symmetric
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
            orientationDwellDecision(published: false, pending: nil, candidate: true,
                                     now: 100, policy: .init(enter: 0, exit: 0)),
            .publish(true)
        )
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: nil, candidate: true,
                                     now: 100, policy: .init(enter: -1, exit: -1)),
            .publish(true)
        )
    }

    // MARK: - The asymmetry (gh#172 round 2)

    /// Round 1 dwelled both directions and device QA measured the exit path
    /// at +390–400 ms against king, because the dwell runs concurrently with
    /// the ~300 ms system rotation and pushes the 0.4 s overlay fade behind
    /// it. Under the shipped policy the *entering* direction still waits and
    /// the *leaving* direction publishes on arrival.
    ///
    /// The direction is chosen from the candidate inside the pure layer, not
    /// branched on by the shell, and it is policy rather than a hard-coded
    /// branch — a policy with a non-zero `exit` dwells on exit too.
    func testTheDwellIsAsymmetricEnteringWaitsLeavingDoesNot() {
        XCTAssertEqual(
            orientationDwellDecision(published: true, pending: nil, candidate: false,
                                     now: 200, policy: orientationDwellPolicy),
            .publish(false),
            "leaving landscape must not wait — this is the +390 ms QA measured"
        )
        XCTAssertEqual(
            orientationDwellDecision(published: false, pending: nil, candidate: true,
                                     now: 200, policy: orientationDwellPolicy),
            .hold(OrientationDwellCandidate(landscape: true, since: 200), after: 0.25),
            "entering landscape keeps the full window"
        )
        // Not a hard-coded branch: the exit dwell is whatever the policy says.
        XCTAssertEqual(
            orientationDwellDecision(published: true, pending: nil, candidate: false,
                                     now: 200, policy: .init(enter: 0.25, exit: 0.1)),
            .hold(OrientationDwellCandidate(landscape: false, since: 200), after: 0.1)
        )
    }

    // MARK: - gh#171 shape

    /// gh#171's revocation: a spurious `.landscapeLeft` arrives while the
    /// focus exit animation is in flight, after the user has already
    /// rotated back to portrait. That sample is an *entering* candidate, so
    /// it keeps the full 0.25 s window even under the asymmetric policy;
    /// because the device is physically portrait, the next sample
    /// contradicts it and nothing is published.
    ///
    /// Note the scope of what this proves: it proves the filter drops a
    /// sample that reverts inside 0.25 s. Whether the real spurious sample
    /// reverts that fast — indeed whether it occurs at all — is a device
    /// question this test cannot answer.
    func testSpuriousLandscapeDuringExitFlightIsNotBelieved() {
        // Published state has just flipped to portrait; exit is animating.
        let published = false
        let spurious = orientationDwellDecision(
            published: published, pending: nil, candidate: true,
            now: 300, policy: orientationDwellPolicy
        )
        guard case let .hold(pending, _) = spurious else {
            return XCTFail("the spurious sample must not publish on arrival")
        }
        // The device is actually portrait, so the next reading contradicts.
        XCTAssertEqual(
            orientationDwellDecision(published: published, pending: pending,
                                     candidate: false, now: 300.12, policy: orientationDwellPolicy),
            .idle
        )
    }

    // MARK: - Alternation

    /// An alternating stream starves the publish for as long as it lasts —
    /// there is deliberately no ceiling. The defence is that the
    /// notification is edge-triggered: when the user stops rotating the
    /// stream stops, and the last candidate then runs its window out and
    /// publishes exactly once. QA's synthesised L/P/L/P/L burst over 480 ms
    /// showed exactly this shape (zero visible change, then one clean entry);
    /// king showed three transitions with visible flicker.
    func testAlternatingStreamStarvesThePublishUntilTheStreamStops() {
        let manager = OrientationManager(observeNotifications: false)
        var t: CFTimeInterval = 4_000
        for candidate in [true, false, true, false, true] {
            manager.observe(candidate, at: t)
            XCTAssertFalse(manager.isLandscape,
                           "nothing may publish mid-burst (t=\(t), candidate=\(candidate))")
            t += 0.08
        }
        // 480 ms of alternation and still nothing published: each contrary
        // sample reset the candidate. The last landscape sample was at
        // 4_000.32; once the stream stops, its window closes on schedule.
        manager.observe(true, at: 4_000.32 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape, "one clean entry once the motion stops")
    }

    /// The swallowing is asymmetric like everything else here, and that is
    /// the honest cost of `exit: 0`: a burst that begins while the device is
    /// already published-landscape emits ONE immediate exit before the rest
    /// is swallowed. This is king's behaviour on that direction, not a
    /// regression, but it is not filtered either.
    func testAlternationStartingFromLandscapeExitsOnceThenIsSwallowed() {
        let manager = OrientationManager(observeNotifications: false)
        manager.observe(true, at: 5_000)
        manager.observe(true, at: 5_000 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)

        // First contrary sample of the burst: published at once.
        manager.observe(false, at: 5_001)
        XCTAssertFalse(manager.isLandscape, "exit: 0 means the first portrait sample wins")

        // The remainder of the burst is swallowed, because every landscape
        // sample is now an entering candidate and each is contradicted
        // inside its window.
        manager.observe(true, at: 5_001.08)
        manager.observe(false, at: 5_001.16)
        manager.observe(true, at: 5_001.24)
        XCTAssertFalse(manager.isLandscape, "no further flip during the burst")
    }

    // MARK: - Shell wiring

    /// The manager itself, driven with an injected clock: a tilt that
    /// reverts inside the window never reaches `isLandscape`, so no
    /// subscriber is ever invalidated by it.
    func testManagerDoesNotPublishATransientTilt() {
        let manager = OrientationManager(observeNotifications: false)
        XCTAssertFalse(manager.isLandscape)

        manager.observe(true, at: 1_000)
        XCTAssertFalse(manager.isLandscape, "arrival alone must not publish")

        manager.observe(false, at: 1_000.1)
        XCTAssertFalse(manager.isLandscape, "the revert must leave the published bit alone")

        // And the revert must have DROPPED the candidate. The third
        // observation alone does not show that — nothing publishes under
        // either hypothesis at t=1_000.2. The fourth does: it is 0.2 s after
        // the third sample but 0.4 s after the first, so if the revert had
        // kept the original stamp the window would be over and this would
        // publish.
        manager.observe(true, at: 1_000.2)
        XCTAssertFalse(manager.isLandscape)
        manager.observe(true, at: 1_000.4)
        XCTAssertFalse(manager.isLandscape,
                       "the fresh window runs from 1_000.2, so 1_000.4 is still inside it")
        // ...and the fresh window does close, at 1_000.45.
        manager.observe(true, at: 1_000.2 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)
    }

    /// A held rotation publishes on entry; the exit does not wait.
    func testManagerPublishesAHeldRotationAndLeavesAtOnce() {
        let manager = OrientationManager(observeNotifications: false)

        manager.observe(true, at: 2_000)
        XCTAssertFalse(manager.isLandscape)
        manager.observe(true, at: 2_000 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)

        manager.observe(false, at: 2_001)
        XCTAssertFalse(manager.isLandscape, "the exit publishes on arrival")
    }

    /// The first reading is not exempt from the dwell — a launch that is
    /// already rotated still waits it out. Documented as deliberate in
    /// `OrientationManager`: at launch the seed `false` agrees with what the
    /// portrait lock is already rendering and the gate has never opened, so
    /// nothing is shown wrongly in between.
    func testLaunchAlreadyRotatedIsNotExemptFromTheDwell() {
        let manager = OrientationManager(observeNotifications: false)
        manager.observe(true, at: 0)
        XCTAssertFalse(manager.isLandscape)
        manager.observe(true, at: orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)
    }

    /// Rotation must not disturb manual focus — the pre-existing decision
    /// this slice deliberately did not change.
    func testPublishingAnOrientationDoesNotClearManualFocus() {
        let manager = OrientationManager(observeNotifications: false)
        manager.manualFocusActive = true
        manager.observe(true, at: 3_000)
        manager.observe(true, at: 3_000 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)
        XCTAssertTrue(manager.manualFocusActive)

        manager.observe(false, at: 3_001)
        XCTAssertFalse(manager.isLandscape)
        XCTAssertTrue(manager.manualFocusActive)
    }

    // MARK: - The wake-up task

    /// The wake-up task is the SOLE hold→publish trigger in the steady
    /// state: `UIDevice.orientationDidChangeNotification` is edge-triggered,
    /// so an ordinary rotation is one notification → `.hold` → nothing → the
    /// task → `.publish`. Every other shell test here injects `at:` and
    /// drives the second observation by hand, so none of them exercise it.
    ///
    /// This one calls `observe` exactly once, against the real clock, and
    /// waits. If re-arming were ever made conditional, this is the test that
    /// would fail rather than the feature silently dying on device.
    ///
    /// `observeNotifications: false` matters here specifically: this is the
    /// only test that suspends, so it is the only one where a real device
    /// notification could land mid-test.
    func testWakeUpTaskPublishesWithoutASecondObservation() async {
        let manager = OrientationManager(observeNotifications: false)

        manager.observe(true)
        XCTAssertFalse(manager.isLandscape, "arrival alone must not publish")

        let deadline = Date().addingTimeInterval(2)
        while !manager.isLandscape && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            manager.isLandscape,
            "nothing but the wake-up task can move this bit — no second observation was made"
        )
    }

    // MARK: - Sleep / resume

    /// On `willEnterForeground` the pending candidate is re-stamped rather
    /// than published, cleared, or re-sampled from the device.
    ///
    /// The stamps come from `CACurrentMediaTime()`, which stops while the
    /// device sleeps, whereas `Task.sleep` runs on the continuous clock,
    /// which does not — so across a sleep the app can resume with a
    /// long-standing candidate whose device state is stale. Re-stamping
    /// gives the correcting notification a fresh full window and takes no
    /// device sample.
    func testForegroundRestampGivesThePendingCandidateAFreshWindow() {
        let manager = OrientationManager(observeNotifications: false)
        manager.observe(true, at: 5_000)
        XCTAssertFalse(manager.isLandscape)

        // Backgrounded; resumed 30 s of media time later.
        manager.restampPendingForResume(at: 5_030)

        // The original deadline (5_000.25) is long past. If the stamp had
        // survived, this sample would publish immediately — the stale
        // publish the re-stamp exists to remove.
        manager.observe(true, at: 5_030.1)
        XCTAssertFalse(manager.isLandscape, "the resumed window must be a full fresh one")

        // But the candidate was NOT cleared: it still publishes once the
        // fresh window closes. Clearing would lose a genuine rotation for
        // good, because UIKit posts nothing on resume when the device is
        // still in the pending orientation.
        manager.observe(true, at: 5_030 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)
    }

    /// With nothing pending, a resume is a no-op — it must not invent a
    /// candidate or disturb the published bit.
    func testForegroundRestampWithNothingPendingIsANoOp() {
        let manager = OrientationManager(observeNotifications: false)
        manager.restampPendingForResume(at: 6_000)
        XCTAssertFalse(manager.isLandscape)
        // And a later sample still starts its window from scratch.
        manager.observe(true, at: 6_001)
        XCTAssertFalse(manager.isLandscape)
        manager.observe(true, at: 6_001 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)
    }
}
