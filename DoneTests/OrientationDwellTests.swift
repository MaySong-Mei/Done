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
//  dwell" on `OrientationManager` for what would settle it, and that file's
//  header for the rig behind every measurement quoted here — all of it
//  simulator-derived, no hardware anywhere in this loop.
//
//  Time is injected as `CFTimeInterval` — production reads
//  `CACurrentMediaTime()`, which is monotonic — so nothing here depends on
//  the wall clock.
//
//  **Two populations of test live here, and the difference matters.** Most
//  build `OrientationManager(observeNotifications: false)` and drive
//  `observe(_:at:)` by hand: they exercise the filter and nothing else. Until
//  round 3 that was ALL of them, so the generation call and both Combine
//  subscriptions had no unit coverage — losing either would have left this
//  file entirely green while the feature was dead on device. "MARK: - The
//  live subscriptions" builds the real init and covers them.
//
//  Those live tests have a hazard the `false` seam exists for: with the real
//  stream connected, a device notification landing mid-test calls `observe`
//  with the real `CACurrentMediaTime()`, which on this host reads a few
//  hundred seconds since boot — so an injected `at: 1_000` is hundreds of
//  seconds, thousands of dwell windows, away from it, and any interleaving is
//  nonsense rather than merely noisy. Each live test therefore (a) bases every
//  injected timestamp on a real `CACurrentMediaTime()` reading, so a stray
//  sample is coherent with the arithmetic instead, (b) pumps the run loop
//  synchronously rather than `await`ing, so the test method never suspends,
//  and (c) keeps every pump well below the 0.25 s wake-up task, so that task
//  cannot fire inside one.
//
//  Each was checked by breaking the thing it claims to cover and confirming
//  it goes red — deleting the generation call, pointing either subscription at
//  a different notification, swapping the `compactMap` for a portrait-coercing
//  `map`, and caching the `deviceOrientation` read at construction instead of
//  calling it per notification. Every mutation left the other tests green,
//  which is the gap restated as a measurement.
//
//  gh#172.
//

import XCTest
import UIKit
import QuartzCore
@testable import Done

/// A one-field box, so the sensor stub can CHANGE between two notifications.
///
/// A plain captured `var` reads better and compiles today, but it warns
/// ("reference to captured var in concurrently-executing code") and is an
/// error in the Swift 6 language mode — the test it serves has to outlive
/// that. Isolated rather than `@unchecked`: `@MainActor` makes this implicitly
/// `Sendable`, which is what lets it cross into the `@Sendable` closure, and
/// the read there goes through `MainActor.assumeIsolated`, so an off-main post
/// traps instead of racing. `@unchecked` asserted the same thing and disabled
/// the check that would catch it.
@MainActor private final class MutableOrientationStub {
    var value: UIDeviceOrientation
    init(_ value: UIDeviceOrientation) { self.value = value }
}

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
    /// site. It covers the mapping only; delivery *through* the subscription
    /// is covered separately, under "The live subscriptions", by posting the
    /// notification with the sensor read stubbed — the one thing a simulator
    /// cannot supply, since `UIDevice.current.orientation` is not settable and
    /// there is no accelerometer to drive it.
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

    /// Round 1 dwelled both directions and QA measured the exit path at
    /// +390–400 ms against king, because the dwell runs concurrently with
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
    /// publishes exactly once.
    ///
    /// This pins that shape as a property of the filter. It is **not**
    /// evidence that the filter helps in the field. An earlier version of
    /// this comment cited a synthesised L/P/L/P/L burst producing one clean
    /// entry here against three flickering transitions on king; that evidence
    /// has been withdrawn (the delivery path that produced it no longer
    /// functions, and QA could not re-deliver sub-dwell alternation at all).
    /// See "The alternation benefit is unverified" on `OrientationManager`.
    func testAlternatingStreamStarvesThePublishUntilTheStreamStops() {
        let manager = OrientationManager(observeNotifications: false)
        var t: CFTimeInterval = 4_000
        for candidate in [true, false, true, false, true] {
            manager.observe(candidate, at: t)
            XCTAssertFalse(manager.isLandscape,
                           "nothing may publish mid-burst (t=\(t), candidate=\(candidate))")
            t += 0.08
        }
        // 320 ms of alternation and still nothing published: each contrary
        // sample reset the candidate. The last landscape sample was at
        // 4_000.32; once the stream stops, its window closes on schedule.
        manager.observe(true, at: 4_000.32 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape, "one clean entry once the motion stops")
    }

    /// The swallowing is asymmetric like everything else here, and that is
    /// the honest cost of `exit: 0`: a burst that begins while the device is
    /// already published-landscape emits ONE immediate exit before the rest
    /// is swallowed.
    ///
    /// An earlier version of this comment called that "king's behaviour on
    /// that direction, not a regression". **The exit is king's behaviour; the
    /// interval that follows it is not.** The immediate exit is followed by
    /// the full `enter` window before focus returns, so the app sits in the
    /// wrong state for that whole span — a sample gap plus a flat 250 ms at
    /// the minimum. `OrientationManager.orientationDwellPolicy` carries the
    /// measurements and the gh#178 consequence.
    func testAlternationStartingFromLandscapeExitsOnceThenIsSwallowed() {
        let manager = OrientationManager(observeNotifications: false)
        manager.observe(true, at: 5_000)
        manager.observe(true, at: 5_000 + orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)

        // First contrary sample of the burst: published at once.
        manager.observe(false, at: 5_001)
        XCTAssertFalse(manager.isLandscape, "exit: 0 means the first portrait sample wins")

        // The remainder of the burst is swallowed, because every landscape
        // sample is now an *entering* candidate. Two different reasons, and
        // the distinction matters: the 5_001.08 sample is contradicted at
        // 5_001.16, inside its window; the 5_001.24 sample is never
        // contradicted at all — the burst simply ends — and is still unheard
        // only because it has not yet served the 0.25 s it owes. Stop the
        // stream and it publishes, which is the previous test.
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
    /// task → `.publish`. Every other shell test injects `at:` and drives the
    /// second observation by hand, so none of them exercise it. This one calls
    /// `observe` exactly once, against the real clock, and waits — if re-arming
    /// were ever made conditional, this fails rather than the feature silently
    /// dying on device.
    ///
    /// `observeNotifications: false` matters here specifically: this is the
    /// only test that suspends, so it is the only one where a stray
    /// orientation notification could land inside an `await`. The live tests
    /// below take the opposite trade deliberately and pay for it by never
    /// suspending — see the file header.
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

    // MARK: - The live subscriptions

    // Everything above builds `OrientationManager(observeNotifications:
    // false)`, which returns from `init` before a single line of wiring runs.
    // The tests here build the DEFAULT init — the one that ships. See the file
    // header for the flake hazard that creates: no injected timestamp is ever
    // far from the real clock, and no test here suspends.

    /// Pump the main run loop, synchronously.
    ///
    /// Both subscriptions `.receive(on: RunLoop.main)`, so a posted
    /// notification is delivered a run-loop turn later and a test that
    /// asserts immediately sees nothing. This is deliberately not `await`:
    /// the test method never suspends, so the only work that can interleave
    /// is what the run loop itself drains. That does include `@MainActor`
    /// continuations, which is why the pump is kept well below
    /// `orientationDwellPolicy.enter` — 0.06 s against 0.25 s, a factor of
    /// 4.2 rather than the order of magnitude an earlier comment claimed. The
    /// margin is measured, not inferred: QA timed all five pump calls (four
    /// tests, one pumping twice) at 0.061–0.064 s each, none overrunning, with
    /// the wake-up task firing at least 0.19 s after the pump it follows ended.
    private func pumpRunLoop(_ seconds: TimeInterval = 0.06) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// The default init turns device-orientation generation ON, and the
    /// `false` seam does not.
    ///
    /// `UIDevice.orientationDidChangeNotification` is not posted at all
    /// unless someone has called
    /// `beginGeneratingDeviceOrientationNotifications()`, so dropping that
    /// one line kills the feature outright while leaving every filter test in
    /// this file green. Nothing covered it before this test.
    ///
    /// The flag is reference-counted and the test host's own app has already
    /// begun generating, so it reads `true` before we do anything. Drain it
    /// to zero first, or the assertion passes for the host's reason instead
    /// of ours — and put the count back, since it is process-global state
    /// shared with every other test.
    func testDefaultInitBeginsGeneratingDeviceOrientationNotifications() {
        let device = UIDevice.current
        var drained = 0
        while device.isGeneratingDeviceOrientationNotifications && drained < 64 {
            device.endGeneratingDeviceOrientationNotifications()
            drained += 1
        }
        XCTAssertFalse(device.isGeneratingDeviceOrientationNotifications,
                       "the count must reach zero or the rest of this test proves nothing")

        // The seam the other tests use must not turn it back on: it is
        // supposed to skip the wiring entirely, not just skip the sink.
        _ = OrientationManager(observeNotifications: false)
        XCTAssertFalse(device.isGeneratingDeviceOrientationNotifications,
                       "observeNotifications: false must not touch the device at all")

        let manager = OrientationManager()
        XCTAssertTrue(device.isGeneratingDeviceOrientationNotifications,
                      "the shipped init must ask UIKit to post orientation notifications")
        withExtendedLifetime(manager) {}

        // Restore the host's reference count, exactly. `manager` contributed
        // one begin and `OrientationManager` has no `deinit`, so that begin
        // would outlive this test: balance it, then put back the `drained`
        // begins we took.
        //
        // It has to be an `end` plus `drained` begins, not `drained - 1`
        // begins. The two agree for every `drained >= 1`, which is why the
        // arithmetic form looked right — but at `drained == 0` (host not
        // generating) every arithmetic form leaves the count at 1 and only an
        // explicit `end` returns it to 0.
        device.endGeneratingDeviceOrientationNotifications()
        for _ in 0..<drained {
            device.beginGeneratingDeviceOrientationNotifications()
        }
    }

    /// The default init subscribes to `UIDevice.orientationDidChangeNotification`
    /// and routes the device's sample into `observe`.
    ///
    /// This is the notification-name check and the sink-target check:
    /// subscribe to the wrong name, or forget to call `observe`, and nothing
    /// below moves. Only the sensor read is stubbed, and only because it is
    /// unreadable here — `UIDevice.current.orientation` measures `.unknown`
    /// on this host at every point in the test, before and after generation is
    /// on, and assigning it by KVC leaves it there. Everything between the
    /// notification and `isLandscape` is production code. The stub is a
    /// constant, which is why it takes a further test to pin that the read
    /// happens per notification at all.
    func testDefaultInitRoutesOrientationNotificationsIntoTheFilter() {
        let manager = OrientationManager(deviceOrientation: { .landscapeLeft })

        NotificationCenter.default.post(
            name: UIDevice.orientationDidChangeNotification, object: UIDevice.current
        )
        pumpRunLoop()

        // Delivery must have CREATED a candidate, stamped at delivery time.
        // Nothing else in this test can create one, so if the subscription is
        // missing or listening to the wrong name, the observation below is the
        // first sample the manager has ever seen and merely opens its own
        // window. Stamps are real-clock so a stray device notification lands
        // in the same arithmetic.
        manager.observe(true, at: CACurrentMediaTime() + orientationDwellPolicy.enter)
        XCTAssertTrue(
            manager.isLandscape,
            "the notification must have started the window; unsubscribed, this sample is the first one and still holds"
        )
    }

    /// And the flat samples are dropped by the live pipeline, not merely by
    /// the mapping function.
    ///
    /// `orientationLandscapeSample` returning `nil` is only useful if the
    /// subscription actually `compactMap`s it away. Swap that `compactMap`
    /// for a `map` with a `?? false` and `.faceUp` — a phone lying on a table
    /// — starts arriving as a portrait sample.
    func testDefaultInitDropsFlatSamplesRatherThanReadingThemAsPortrait() {
        let manager = OrientationManager(deviceOrientation: { .faceUp })
        let t0 = CACurrentMediaTime()

        // A landscape candidate is standing. A `false` reaching `observe`
        // would agree with the published bit, return `.idle`, and drop it.
        manager.observe(true, at: t0)
        NotificationCenter.default.post(
            name: UIDevice.orientationDidChangeNotification, object: UIDevice.current
        )
        pumpRunLoop()

        manager.observe(true, at: t0 + orientationDwellPolicy.enter)
        XCTAssertTrue(
            manager.isLandscape,
            "a flat sample must not reach the filter at all; coerced to portrait it would have killed this candidate"
        )
    }

    /// **The sensor is read once per notification, not once at construction.**
    ///
    /// This is the only test that can tell those two apart, and it guards a
    /// rewrite that is attractive precisely because it matches the house shape
    /// — `deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation`,
    /// a value like every neighbouring seam. It kills landscape focus outright;
    /// the `deviceOrientation` parameter on `OrientationManager.init` carries
    /// the mechanism.
    ///
    /// The two live tests above stub a **constant** orientation, and a
    /// constant answers identically read every time or read once and cached —
    /// so that rewrite leaves them, and every other test here, green. This
    /// stub *changes between the two posts*, a shape a value parameter cannot
    /// express: the rewrite cannot be applied here mechanically, and applied
    /// anyway this test goes red.
    func testTheSensorIsReadOnEveryNotificationNotOnceAtConstruction() {
        let stub = MutableOrientationStub(.portrait)
        let manager = OrientationManager(
            deviceOrientation: { MainActor.assumeIsolated { stub.value } }
        )

        // Post #1 reads portrait, which agrees with the published bit, so it
        // must leave nothing standing under either hypothesis.
        NotificationCenter.default.post(
            name: UIDevice.orientationDidChangeNotification, object: UIDevice.current
        )
        pumpRunLoop()

        // Post #2 reads landscape. Only a per-call read can see this.
        stub.value = .landscapeLeft
        NotificationCenter.default.post(
            name: UIDevice.orientationDidChangeNotification, object: UIDevice.current
        )
        pumpRunLoop()

        // Read per call: post #2 delivered `true` and opened a window at
        // delivery time, which precedes the clock reading below, so this
        // sample closes it. Read once and cached: every notification is still
        // portrait, each resolves to `.idle`, and this is then the manager's
        // first landscape sample — it opens its own window and publishes
        // nothing.
        manager.observe(true, at: CACurrentMediaTime() + orientationDwellPolicy.enter)
        XCTAssertTrue(
            manager.isLandscape,
            "the sensor must be read per notification; cached at construction, the second post is still portrait and no window is open"
        )
    }

    /// The default init subscribes to
    /// `UIApplication.willEnterForegroundNotification` and routes it into
    /// `restampPendingForResume`.
    ///
    /// `testForegroundRestampGivesThePendingCandidateAFreshWindow` pins what
    /// the re-stamp does; nothing pinned that anything calls it. Both stamps
    /// here are real-clock readings, so the assertion is exact arithmetic
    /// rather than a race: under the re-stamp the candidate's window starts
    /// at `t1 > t0` and the original deadline `t0 + enter` is still inside
    /// it, while without the re-stamp that same instant is the deadline
    /// exactly and publishes.
    ///
    /// The orientation read is stubbed **landscape** to keep the first
    /// assertion single-cause. It is not what this test covers; it is the one
    /// other way `isLandscape` could stay `false` here. A stray portrait
    /// sample reaching `observe` would return `.idle` and clear the candidate,
    /// and then the assertion would pass with the foreground subscription
    /// entirely broken. Stubbed landscape, a stray sample *agrees* with the
    /// standing candidate, carries its stamp through unchanged, and cannot
    /// clear it — so the only thing that can move the window is the re-stamp.
    /// (Unreachable on this host today, where the real read is `.unknown` and
    /// the `compactMap` drops it, but the test should not depend on that.)
    func testDefaultInitRestampsThePendingCandidateOnForeground() {
        let manager = OrientationManager(deviceOrientation: { .landscapeLeft })

        let t0 = CACurrentMediaTime()
        manager.observe(true, at: t0)
        XCTAssertFalse(manager.isLandscape)

        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        pumpRunLoop()

        manager.observe(true, at: t0 + orientationDwellPolicy.enter)
        XCTAssertFalse(
            manager.isLandscape,
            "the resume must have refreshed the window; unsubscribed, the original stamp survives and this publishes"
        )

        // And nothing is wedged: the refreshed window does close. Written at
        // 2× the dwell so it clears the re-stamped deadline (t1 + enter, with
        // t1 one pump past t0) with room to spare.
        manager.observe(true, at: t0 + 2 * orientationDwellPolicy.enter)
        XCTAssertTrue(manager.isLandscape)
    }
}
