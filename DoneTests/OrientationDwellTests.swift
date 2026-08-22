//
//  OrientationDwellTests.swift
//  DoneTests
//
//  **The dwell this file is named for is gone.** gh#172 shipped a 0.25 s
//  hysteresis filter in `OrientationManager` — an orientation had to hold
//  before it was published — and then removed it, because the premise it was
//  bought on was measured on an iPhone 15 Pro Max and is false. The file keeps
//  its name as a pointer to that history; `OrientationManager` carries the
//  reasoning in full.
//
//  What is left here is the pipeline that *does* filter, which turned out to
//  be the part nobody was calling a filter:
//
//    - `orientationLandscapeSample` mapping `.faceUp`/`.faceDown`/`.unknown`
//      to `nil`, and the `compactMap` in `init` dropping them;
//    - the `candidate != isLandscape` guard in `observe`, which makes a
//      repeated sample inert.
//
//  Between them they account for every sub-250 ms event the hardware probe
//  recorded. `testHardwareProbeShowsNoLandscapeSampleShorterThanTheRemovedDwell`
//  carries that probe as a fixture — the measurement lives here, in code the
//  suite re-derives, rather than in a comment a later round would read as a
//  decision input.
//
//  Note what the removal costs elsewhere: the dwell was the only upstream
//  mitigation this repo ever claimed for **gh#171**'s symptom 2, and
//  `testSpuriousLandscapeDuringExitFlightIsNotBelieved` was its guard. Both are
//  gone, and the probe is why — see "Consequences of the removal" on
//  `OrientationManager` for the argument, which is that the tilt phase
//  falsifies the mechanism symptom 2 rests on rather than merely descoping it.
//
//  **Three populations of test live here, and the difference matters.**
//
//  **Four build no `OrientationManager` at all.** Three are fixtures — the
//  probe, its sub-dwell churn, and the rotation-flash counter-argument — which
//  assert arithmetic over captured data and call no production code but
//  `orientationLandscapeSample`. The fourth covers that function directly.
//
//  **Three build `OrientationManager(observeNotifications: false)`** and drive
//  `observe(_:)` by hand: they exercise the publishing rule and nothing else.
//  Until round 3 that was ALL of them, so the generation call and the Combine
//  subscription had no unit coverage — losing either would have left this file
//  entirely green while the feature was dead on device.
//
//  **Four build the DEFAULT init**, under "MARK: - The live subscriptions",
//  and cover exactly that gap.
//
//  Those live tests have a hazard the `false` seam exists for: with the real
//  stream connected, a stray device notification can move `isLandscape`
//  underneath an assertion. Each live test therefore pumps the run loop
//  synchronously rather than `await`ing, so the test method never suspends and
//  the only work that can interleave is what the run loop itself drains.
//
//  Each was checked by breaking the thing it claims to cover and confirming it
//  goes red — deleting the generation call, pointing the subscription at a
//  different notification, swapping the `compactMap` for a portrait-coercing
//  `map`, and caching the `deviceOrientation` read at construction instead of
//  calling it per notification. Every mutation was caught by the test that
//  names it, which is the gap restated as a measurement.
//
//  It is not one-red-per-mutation, and the exception is worth recording rather
//  than rounding off: pointing the subscription at a different notification
//  reddens **two** — the routing test and the per-notification-read test, the
//  latter because it needs delivery to happen before it can tell a per-call
//  read from a cached one. That is more sensitive, not less specific.
//
//  gh#172.
//

import XCTest
import UIKit
import Combine
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

/// A counter the `objectWillChange` sink can bump. Same reason as above: a
/// captured `var` mutated from an escaping closure is a Swift 6 error.
@MainActor private final class InvalidationCounter {
    var count = 0
}

/// One line of the hardware orientation probe: the raw `UIDeviceOrientation`
/// the sensor reported and the `CACurrentMediaTime()` it arrived at.
///
/// Deliberately raw. The fixture stores what the notification carried, and the
/// test derives the landscape bit through `orientationLandscapeSample` — the
/// production function — so the counts below are assertions about the shipping
/// filter and not a second transcription of it.
private struct RawOrientationSample {
    let seq: Int
    let t: CFTimeInterval
    let raw: UIDeviceOrientation
}

/// One rig's reading of the rotation flash that the removed dwell suppressed —
/// the standing counter-argument to removing it, carried as data.
///
/// Named by **round and build** rather than "QA", because the whole weight of
/// the rebuttal is on which rig produced it: every one of these is a
/// **simulator** driving a **commanded** transient. See "What the dwell did fix"
/// on `OrientationManager`.
private struct RotationFlashReading {
    /// The gh#172 round whose QA ran it.
    let round: Int
    /// The build measured. `nil` frame counts are rigs that reported only a
    /// duration.
    let build: String
    let frames: Int?
    let seconds: CFTimeInterval
}

@MainActor
final class OrientationDwellTests: XCTestCase {

    /// The dwell that gh#172 shipped and then removed. Kept as a number only
    /// so the probe fixture can state what it is measured against.
    private let removedDwell: CFTimeInterval = 0.25

    // MARK: - The hardware measurement

    /// The raw probe, verbatim: 36 notifications over 313.2 s.
    ///
    /// iPhone 15 Pro Max, iOS 26.6. An `os_log`+file probe at the raw
    /// notification inside the `compactMap` in `OrientationManager.init` — the
    /// probe point that file's own falsifier specified. Protocol: (a)
    /// deliberate portrait↔landscape rotations with 3 s holds, (b) ~9 s of
    /// sub-threshold tilting at 20–30° never letting it flip, (c) walking while
    /// rotating.
    ///
    /// Timestamps are `CACurrentMediaTime()`, i.e. seconds since boot; only
    /// their differences mean anything.
    private let probe: [RawOrientationSample] = [
        .init(seq:  1, t: 218238.4884, raw: .faceUp),
        .init(seq:  2, t: 218302.0568, raw: .landscapeLeft),
        .init(seq:  3, t: 218304.6147, raw: .faceUp),
        .init(seq:  4, t: 218309.8536, raw: .portrait),
        .init(seq:  5, t: 218312.5552, raw: .faceUp),
        .init(seq:  6, t: 218329.2469, raw: .landscapeLeft),
        .init(seq:  7, t: 218331.8315, raw: .portrait),
        .init(seq:  8, t: 218332.9895, raw: .faceUp),
        .init(seq:  9, t: 218340.1594, raw: .landscapeLeft),
        .init(seq: 10, t: 218352.1172, raw: .portrait),
        .init(seq: 11, t: 218354.7543, raw: .landscapeLeft),
        .init(seq: 12, t: 218358.5790, raw: .portrait),
        .init(seq: 13, t: 218362.5253, raw: .landscapeLeft),
        .init(seq: 14, t: 218364.8691, raw: .portrait),
        .init(seq: 15, t: 218367.3513, raw: .landscapeLeft),
        .init(seq: 16, t: 218370.5745, raw: .faceUp),
        .init(seq: 17, t: 218371.3755, raw: .portrait),
        .init(seq: 18, t: 218372.8042, raw: .faceUp),
        // --- the sub-threshold tilt phase begins ---
        .init(seq: 19, t: 218521.9249, raw: .portrait),
        .init(seq: 20, t: 218524.5954, raw: .faceUp),
        .init(seq: 21, t: 218525.1910, raw: .portrait),
        .init(seq: 22, t: 218529.1779, raw: .faceUp),
        .init(seq: 23, t: 218529.3751, raw: .portrait),
        .init(seq: 24, t: 218529.5352, raw: .faceUp),
        .init(seq: 25, t: 218530.9301, raw: .portrait),
        // --- and ends, without ever producing a landscape value ---
        .init(seq: 26, t: 218536.5514, raw: .landscapeLeft),
        .init(seq: 27, t: 218537.3623, raw: .portrait),
        .init(seq: 28, t: 218539.7685, raw: .landscapeLeft),
        .init(seq: 29, t: 218541.5563, raw: .portrait),
        .init(seq: 30, t: 218542.3258, raw: .landscapeLeft),
        .init(seq: 31, t: 218545.2769, raw: .portrait),
        .init(seq: 32, t: 218545.9935, raw: .landscapeRight),
        .init(seq: 33, t: 218546.7816, raw: .portrait),
        .init(seq: 34, t: 218547.0692, raw: .faceUp),
        .init(seq: 35, t: 218549.1704, raw: .portrait),
        .init(seq: 36, t: 218551.7320, raw: .faceUp),
    ]

    /// **The measurement that removed the dwell.** Not one landscape sample in
    /// 313.2 s of deliberate abuse lived less than 0.25 s, so the filter was
    /// spending a quarter second on every rotation to reject a class of sample
    /// that never arrived.
    ///
    /// The lifetimes are computed the way the pipeline would see them: raw
    /// samples through `orientationLandscapeSample`, flat ones dropped as the
    /// `compactMap` drops them, and a landscape sample's life ending at the
    /// next sample that *contradicts* it rather than the next notification of
    /// any kind.
    ///
    /// This test is also the falsifier's other half. If a future capture ever
    /// shows two filter-reaching samples contradicting each other inside
    /// ~250 ms, the trade `OrientationManager` describes reopens — and this
    /// fixture is what a new capture gets compared against.
    func testHardwareProbeShowsNoLandscapeSampleShorterThanTheRemovedDwell() {
        XCTAssertEqual(probe.count, 36)
        XCTAssertEqual(probe.last!.t - probe.first!.t, 313.2436, accuracy: 1e-4,
                       "313.2 s of capture")

        // What the production mapping does to the raw stream.
        let mapped = probe.map { orientationLandscapeSample($0.raw) }
        XCTAssertEqual(mapped.filter { $0 == nil }.count, 11,
                       "flat samples the compactMap drops before observe() is ever called")
        XCTAssertEqual(mapped.filter { $0 != nil }.count, 25, "samples that reach the filter")
        XCTAssertEqual(mapped.filter { $0 == true }.count, 10, "landscape samples")
        XCTAssertEqual(mapped.filter { $0 == false }.count, 15, "portrait samples")

        // Each landscape sample's life, ending at the first contradicting
        // portrait — i.e. what a dwell would have had to outlast.
        let reaching = probe.filter { orientationLandscapeSample($0.raw) != nil }
        var lifetimes: [CFTimeInterval] = []
        for (i, sample) in reaching.enumerated() where orientationLandscapeSample(sample.raw) == true {
            if let contradiction = reaching[(i + 1)...].first(
                where: { orientationLandscapeSample($0.raw) == false }
            ) {
                lifetimes.append(contradiction.t - sample.t)
            }
        }
        XCTAssertEqual(lifetimes.count, 10, "every landscape sample was eventually contradicted")

        let expected: [CFTimeInterval] = [
            7.797, 2.585, 11.958, 3.825, 2.344, 4.024, 0.811, 1.788, 2.951, 0.788,
        ]
        for (measured, recorded) in zip(lifetimes, expected) {
            XCTAssertEqual(measured, recorded, accuracy: 1e-3)
        }

        let shortest = lifetimes.min()!
        XCTAssertEqual(shortest, 0.788, accuracy: 1e-3)
        XCTAssertGreaterThan(
            shortest, removedDwell,
            "the shortest landscape sample is 3.15x the dwell that was removed"
        )
        XCTAssertEqual(
            lifetimes.filter { $0 < removedDwell }.count, 0,
            "THE PREMISE: the 0.25 s dwell would have suppressed no landscape sample at all"
        )
        // The falsification is clean in BOTH directions — nothing had claimed
        // this, and it is free. The same walk mirrored: each portrait sample's
        // life, ending at the first contradicting landscape.
        var portraitLifetimes: [CFTimeInterval] = []
        for (i, sample) in reaching.enumerated()
        where orientationLandscapeSample(sample.raw) == false {
            if let contradiction = reaching[(i + 1)...].first(
                where: { orientationLandscapeSample($0.raw) == true }
            ) {
                portraitLifetimes.append(contradiction.t - sample.t)
            }
        }
        XCTAssertEqual(portraitLifetimes.min()!, 0.7166, accuracy: 1e-3,
                       "shortest portrait->landscape gap, the mirror of the 0.788")
        XCTAssertEqual(
            portraitLifetimes.filter { $0 < removedDwell }.count, 0,
            "neither direction produced a sample a 0.25 s dwell could suppress"
        )

        // The counter-argument's own numbers, and this sample's margin over
        // them, live in the rotation-flash fixture below.
    }

    /// The churn the premise predicted is real — and lands entirely on the
    /// channel that cannot reach the filter.
    ///
    /// This is what stops a later reader concluding the premise was simply
    /// wrong and deleting `orientationLandscapeSample`'s `nil` cases as dead
    /// caution. They are not: they are the only reason the two sub-250 ms
    /// events in the capture are harmless.
    ///
    /// **`rapid` pairs RAW adjacency, and on a new capture that is not the
    /// question.** The loop below asserts that a sub-250 ms *adjacent* pair
    /// involves a flat sample. On this frozen fixture that is exactly
    /// equivalent to the real condition and the assertion is sound. It is not
    /// equivalent in general: two filter-reaching samples could contradict each
    /// other *across* an interposed flat sample inside 250 ms, and every
    /// adjacent pair would still satisfy `previous == nil || next == nil` while
    /// the trade reopened. Since this file advertises itself as the comparison
    /// point for a new capture, note that the reopening condition is the one
    /// `OrientationManager` states — contradiction between *filter-reaching*
    /// samples — which is what the lifetime walk in the test above computes,
    /// and not this adjacency check.
    func testTheOnlySubDwellChurnIsOnTheFlatChannelWhichNeverReachesTheFilter() {
        let rapid = zip(probe, probe.dropFirst())
            .filter { $0.1.t - $0.0.t < removedDwell }
        XCTAssertEqual(rapid.count, 2, "exactly two sub-250 ms gaps in 313.2 s")

        // 0.197 s faceUp -> portrait (seq 22->23), 0.160 s portrait -> faceUp
        // (seq 23->24). Both far inside the removed window.
        XCTAssertEqual(rapid.map { $0.0.seq }, [22, 23])
        XCTAssertEqual(rapid[0].1.t - rapid[0].0.t, 0.197, accuracy: 1e-3)
        XCTAssertEqual(rapid[1].1.t - rapid[1].0.t, 0.160, accuracy: 1e-3)

        for (previous, next) in rapid {
            XCTAssertTrue(
                orientationLandscapeSample(previous.raw) == nil
                    || orientationLandscapeSample(next.raw) == nil,
                "a sub-dwell pair must involve a flat sample the compactMap drops (seq \(previous.seq))"
            )
        }

        // The tilt phase: ~9 s of deliberate 20-30 degree tilting produced
        // seven samples, six alternations, and no landscape value whatsoever.
        let tilt = probe.filter { (19...25).contains($0.seq) }
        XCTAssertEqual(tilt.count, 7)
        XCTAssertEqual(tilt.last!.t - tilt.first!.t, 9.0052, accuracy: 1e-3)
        XCTAssertEqual(
            zip(tilt, tilt.dropFirst()).filter { $0.0.raw != $0.1.raw }.count, 6,
            "six alternations — re-derived here, not just asserted in the comment"
        )
        XCTAssertTrue(
            tilt.allSatisfy { orientationLandscapeSample($0.raw) != true },
            "sub-threshold tilting never produced a landscape sample to filter"
        )
    }

    // MARK: - The counter-argument

    /// The transient the counter-argument is built on, as **commanded** by the
    /// rig. Not a sensor reading — that distinction is the rebuttal.
    private let commandedTransient: CFTimeInterval = 0.150

    /// **The rotation flash the dwell suppressed**, with its rig on the label.
    ///
    /// gh#172 **round 3**'s independent QA, on a **simulator**, commanding a
    /// 150 ms transient from `Device > Orientation`: **0 motion frames** on both
    /// dwell builds, against king `7b70001` at **44 frames / 710 ms** of
    /// full-screen flash. Round **2**'s QA measured the same thing at **675 ms**
    /// on its own rig and did not report a frame count.
    private let rotationFlash: [RotationFlashReading] = [
        .init(round: 3, build: "c02fee9", frames: 0, seconds: 0),
        .init(round: 3, build: "ea3f605", frames: 0, seconds: 0),
        .init(round: 3, build: "7b70001", frames: 44, seconds: 0.710),
        .init(round: 2, build: "7b70001", frames: nil, seconds: 0.675),
    ]

    /// The counter-argument is a fixture for the same reason the probe is.
    ///
    /// The standing rule in this file is that a number a future round will act
    /// on gets re-derived by the suite instead of restated in a comment. That
    /// rule was applied to the probe — the number nobody contests — and not to
    /// this one, which is the number a reader reaches for when they see a
    /// rotation flash and wonder whether removing the dwell was a mistake. This
    /// closes that gap.
    ///
    /// What it can and cannot establish: the capture is not re-runnable from
    /// here, so the readings are data. What is re-derived is their relationship
    /// to the probe — the margin, and the fact that the transient sits *below*
    /// the removed dwell, which is why the dwell caught it at all.
    func testTheRotationFlashCounterArgumentIsRecordedWithItsRig() {
        let round3 = rotationFlash.filter { $0.round == 3 }
        XCTAssertEqual(round3.count, 3)

        let withDwell = round3.filter { $0.build != "7b70001" }
        XCTAssertEqual(withDwell.map(\.build), ["c02fee9", "ea3f605"])
        XCTAssertTrue(
            withDwell.allSatisfy { $0.frames == 0 && $0.seconds == 0 },
            "the dwell suppressed the transient completely on both builds"
        )

        let king = round3.first { $0.build == "7b70001" }!
        XCTAssertEqual(king.frames, 44)
        XCTAssertEqual(king.seconds, 0.710, accuracy: 1e-9)

        // Two rigs, two readings, both kept. The spread is the uncertainty on
        // the figure and averaging them would hide it.
        let round2 = rotationFlash.first { $0.round == 2 }!
        XCTAssertEqual(round2.seconds, 0.675, accuracy: 1e-9)
        XCTAssertNil(round2.frames)
        XCTAssertEqual(king.seconds - round2.seconds, 0.035, accuracy: 1e-9,
                       "35 ms between the two rigs measuring the same thing")

        // Why the dwell caught it: the transient is shorter than the window.
        XCTAssertLessThan(commandedTransient, removedDwell)

        // And why that stopped mattering. Recomputed from the probe rather
        // than restated: the shortest thing gravity produced clears the
        // commanded transient by 5.25x.
        let reaching = probe.filter { orientationLandscapeSample($0.raw) != nil }
        var lifetimes: [CFTimeInterval] = []
        for (i, sample) in reaching.enumerated()
        where orientationLandscapeSample(sample.raw) == true {
            if let contradiction = reaching[(i + 1)...].first(
                where: { orientationLandscapeSample($0.raw) == false }
            ) {
                lifetimes.append(contradiction.t - sample.t)
            }
        }
        XCTAssertEqual(lifetimes.min()! / commandedTransient, 5.25, accuracy: 5e-3)
    }

    // MARK: - The mapping

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
    }

    // MARK: - The publishing rule

    /// A sample that agrees with the published bit invalidates nobody.
    ///
    /// This is the second half of what makes the measured churn harmless, and
    /// it is the one place the **publishing rule** differs from
    /// `king-of-rubbish-bin`, which assigns unconditionally and fires
    /// `objectWillChange` inside a 0.4 s animation transaction on every
    /// redundant notification. Only the rule: the same commit also drops king's
    /// `@Published var rotation`, narrows `isLandscape` to `private(set)`, and
    /// changes what a future `UIDeviceOrientation` case publishes. Publish
    /// *timing* is king's exactly, in both directions.
    ///
    /// Counted rather than inferred: "published nothing" has exactly one
    /// observable consequence, and this is it.
    func testAnAgreeingSampleDoesNotInvalidateSubscribers() {
        let manager = OrientationManager(observeNotifications: false)
        let counter = InvalidationCounter()
        let subscription = manager.objectWillChange.sink { _ in counter.count += 1 }
        defer { subscription.cancel() }

        manager.observe(false)
        XCTAssertEqual(counter.count, 0, "the seed is already portrait; this says nothing new")

        manager.observe(true)
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(manager.isLandscape)

        // The repeated sample the probe measured either side of a flat one.
        manager.observe(true)
        manager.observe(true)
        XCTAssertEqual(counter.count, 1, "a repeated sample must stay inert")

        manager.observe(false)
        XCTAssertEqual(counter.count, 2)
        XCTAssertFalse(manager.isLandscape)
    }

    /// A mapped sample publishes on arrival, in both directions — the whole
    /// rule, and `king-of-rubbish-bin`'s behaviour exactly.
    ///
    /// The dwell that used to sit between the sample and the assignment cost
    /// the entering direction ~250 ms on every rotation. This test is what
    /// would go red if it, or anything else deferring the publish, came back
    /// without the measurement on `OrientationManager` being overturned first.
    func testAMappedSamplePublishesOnArrivalInBothDirections() {
        let manager = OrientationManager(observeNotifications: false)
        XCTAssertFalse(manager.isLandscape)

        manager.observe(true)
        XCTAssertTrue(manager.isLandscape, "entering landscape must not wait")

        manager.observe(false)
        XCTAssertFalse(manager.isLandscape, "and neither must leaving it")
    }

    /// Rotation must not disturb manual focus — the pre-existing decision
    /// neither gh#172 round changed.
    func testPublishingAnOrientationDoesNotClearManualFocus() {
        let manager = OrientationManager(observeNotifications: false)
        manager.manualFocusActive = true

        manager.observe(true)
        XCTAssertTrue(manager.isLandscape)
        XCTAssertTrue(manager.manualFocusActive)

        manager.observe(false)
        XCTAssertFalse(manager.isLandscape)
        XCTAssertTrue(manager.manualFocusActive)
    }

    // MARK: - The live subscriptions

    // Everything above builds `OrientationManager(observeNotifications:
    // false)`, which returns from `init` before a single line of wiring runs.
    // The tests here build the DEFAULT init — the one that ships.

    /// Pump the main run loop, synchronously.
    ///
    /// The subscription `.receive(on: RunLoop.main)`, so a posted notification
    /// is delivered a run-loop turn later and a test that asserts immediately
    /// sees nothing. This is deliberately not `await`: the test method never
    /// suspends, so the only work that can interleave is what the run loop
    /// itself drains.
    private func pumpRunLoop(_ seconds: TimeInterval = 0.06) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// The default init turns device-orientation generation ON, and the
    /// `false` seam does not.
    ///
    /// `UIDevice.orientationDidChangeNotification` is not posted at all
    /// unless someone has called
    /// `beginGeneratingDeviceOrientationNotifications()`, so dropping that
    /// one line kills the feature outright while leaving every other test in
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
    /// and routes the device's sample all the way into `isLandscape`.
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
        XCTAssertFalse(manager.isLandscape)

        NotificationCenter.default.post(
            name: UIDevice.orientationDidChangeNotification, object: UIDevice.current
        )
        pumpRunLoop()

        XCTAssertTrue(
            manager.isLandscape,
            "the notification must reach observe(); unsubscribed, nothing moves this bit"
        )
    }

    /// And the flat samples are dropped by the live pipeline, not merely by
    /// the mapping function.
    ///
    /// `orientationLandscapeSample` returning `nil` is only useful if the
    /// subscription actually `compactMap`s it away. Swap that `compactMap`
    /// for a `map` with a `?? false` and `.faceUp` — a phone lying on a table
    /// — starts arriving as a portrait sample, which is precisely the churn
    /// the hardware probe caught twice inside 200 ms.
    func testDefaultInitDropsFlatSamplesRatherThanReadingThemAsPortrait() {
        let manager = OrientationManager(deviceOrientation: { .faceUp })

        // Establish landscape, so a coerced `false` would have somewhere to go:
        // it would disagree with the published bit and publish at once.
        manager.observe(true)
        XCTAssertTrue(manager.isLandscape)

        NotificationCenter.default.post(
            name: UIDevice.orientationDidChangeNotification, object: UIDevice.current
        )
        pumpRunLoop()

        XCTAssertTrue(
            manager.isLandscape,
            "a flat sample must not reach the filter at all; coerced to portrait it would have published"
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

        // Post #1 reads portrait, which agrees with the seed, so it publishes
        // nothing under either hypothesis. A checkpoint, not the assertion.
        NotificationCenter.default.post(
            name: UIDevice.orientationDidChangeNotification, object: UIDevice.current
        )
        pumpRunLoop()
        XCTAssertFalse(manager.isLandscape)

        // Post #2 reads landscape. Only a per-call read can see this: cached
        // at construction, every notification is still portrait, agrees with
        // the published bit, and the guard returns.
        stub.value = .landscapeLeft
        NotificationCenter.default.post(
            name: UIDevice.orientationDidChangeNotification, object: UIDevice.current
        )
        pumpRunLoop()

        XCTAssertTrue(
            manager.isLandscape,
            "the sensor must be read per notification; cached at construction the second post is still portrait"
        )
    }
}
