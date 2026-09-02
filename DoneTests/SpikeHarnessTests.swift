//
//  SpikeHarnessTests.swift
//  DoneTests
//
//  gh#197 SPIKE — tests for SpikeModel.swift's pure logic (registry lookup,
//  metric codable shape, run-log algebra, frame-percentile math, frame
//  sample buffer), for SpikeSessionCoordinator's registration algebra
//  (seam fan-out, co-active stamping, external stop routing), and for
//  SpikeRunStore's disk behavior (round trip, interrupted-run reconcile
//  with armed-run exclusion, v1-line compatibility, note edits,
//  retention/compaction) against isolated `.ephemeral` directories so
//  nothing here touches the real app container.
//
//  Every expectation below is hand-computed against the stated business
//  rule, not derived by reading the implementation under test.
//
//  gh#201 round 3 shrank the untestable set. Independent mutation QA
//  landed 8 mutants and 6 survived, every one of them on an impure
//  WIRING point next to a thoroughly pinned pure rule — so the wiring
//  stopped being declared untestable and got tests:
//    * `SpikeFrameProbe` — its lifecycle-notification observers and its
//      tick path are covered (`SpikeFrameProbeTests`), by posting the
//      real `UIApplication` notifications and driving `ingestTick` with
//      hand-written timestamps. What remains genuinely untestable is the
//      CADisplayLink's own CADENCE and whether `invalidate()` releases
//      the link.
//    * `Spike201Runner` — covered (`Spike201RunnerTests`), which is where
//      the clock the touch stamp is read in is pinned. Round 2 had zero
//      references to this class from any test.
//    * The production gate in `EventStore.upsertLogRecord` — NOT on this
//      branch: the experiment machinery stayed on the spike branch
//      (Fix Watch migration; post-#201 king has no spike gate there).
//    * Production EMIT SITES — covered only by source inspection
//      (`Spike201EmitSiteInventoryTests`), and declared as the weaker
//      instrument it is: a SwiftUI `body` and a `UIViewRepresentable`'s
//      `updateUIView` cannot be evaluated here, so those tests prove the
//      call exists and is spelled right, never that it is reached.
//  Still untestable here: SwiftUI view wiring — `SpikeListView`'s Active
//  Runs card, `SpikeDetailView`'s remote control of the coordinator-owned
//  runner (including the armed-run control lock), and `DoneApp`'s
//  `.environmentObject(SpikeSessionCoordinator)` injection.
//

import Combine
import QuartzCore
import XCTest
import UIKit
@testable import Done

// MARK: - Registry

final class SpikeRegistryTests: XCTestCase {
    func testLookupByIDFindsTheRegisteredDefinition() throws {
        let found = try XCTUnwrap(SpikeRegistry.definition(for: "detail-perf-195"))
        XCTAssertEqual(found.issueNumber, 195)
        XCTAssertEqual(found.lifecycle, .active)
    }

    func testLookupByUnknownIDReturnsNil() {
        XCTAssertNil(SpikeRegistry.definition(for: "not-a-real-spike"))
    }

    /// Pins the #195 slice's exact scope: exactly one scenario, the
    /// user-action reflection-note case, wired to `Spike195Runner`'s own
    /// constants (a mismatch here would silently desync the registry's
    /// listing from what the runner actually listens for).
    func testDetailPerf195HasExactlyTheOneWiredScenario() throws {
        let definition = try XCTUnwrap(SpikeRegistry.definition(for: Spike195Runner.spikeID))
        XCTAssertEqual(definition.scenarios.count, 1)
        let scenario = try XCTUnwrap(definition.scenarios.first)
        XCTAssertEqual(scenario.id, Spike195Runner.scenarioID)
        XCTAssertEqual(scenario.kind, .userAction)
    }

    /// The combo spike's feature-toggle surface must leave the measurement
    /// spike untouched: #195 stays `.measurement` with no variants, so its
    /// detail page renders exactly as before.
    func testDetailPerf195RemainsMeasurementKindWithNoVariants() throws {
        let definition = try XCTUnwrap(SpikeRegistry.definition(for: Spike195Runner.spikeID))
        XCTAssertEqual(definition.kind, .measurement)
        XCTAssertTrue(definition.variants.isEmpty)
    }

    /// Fix Watch migration boundary, pinned as a positive AND a negative:
    /// exactly the two measurement spikes migrated; the three feature
    /// spikes (#165/#192/#198) and every `.featureToggle` entry stayed on
    /// the spike branch.
    func testTheRegistryCarriesExactlyTheTwoMigratedMeasurementSpikes() {
        XCTAssertEqual(SpikeRegistry.all.map(\.id), ["detail-perf-195", "effort-tap-201"])
        XCTAssertTrue(SpikeRegistry.all.allSatisfy { $0.kind == .measurement })
        XCTAssertTrue(SpikeRegistry.all.allSatisfy { $0.variants.isEmpty },
                      "the #201 experiment variants were deliberately not migrated")
    }

    /// The key contract between the harness detail page and the arming
    /// toggle: the literal spelling is pinned (not derived on both sides
    /// from the same helper) so a helper change cannot silently move
    /// every flag.
    func testFeatureFlagKeyIdiomIsPinnedLiterally() {
        XCTAssertEqual(SpikeFeatureFlag.enabledKey("effort-tap-201"), "spike.effort-tap-201.enabled")
        XCTAssertEqual(SpikeFeatureFlag.variantKey("effort-tap-201"), "spike.effort-tap-201.variant")
    }
}

// MARK: - SpikeMetricValue Codable shape

final class SpikeMetricValueCodableTests: XCTestCase {
    private func jsonString(_ value: SpikeMetricValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testNumberEncodesAsABareScalarNotATaggedObject() throws {
        XCTAssertEqual(try jsonString(.number(18.4)), "18.4")
    }

    func testBoolEncodesAsABareScalar() throws {
        XCTAssertEqual(try jsonString(.bool(true)), "true")
    }

    func testStringEncodesAsAQuotedScalar() throws {
        XCTAssertEqual(try jsonString(.string("floaty")), "\"floaty\"")
    }

    func testEachCaseRoundTripsThroughDecodeUnchanged() throws {
        let decoder = JSONDecoder()
        for original: SpikeMetricValue in [.number(18.4), .bool(true), .string("floaty")] {
            let data = try JSONEncoder().encode(original)
            let decoded = try decoder.decode(SpikeMetricValue.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    /// The reason `.integer` isn't a separate case: `JSONEncoder` prints a
    /// whole-number `Double` without a decimal point (`16.0` -> `"16"`),
    /// so a `.number` landing on a whole value must still decode back as
    /// `.number`, not silently become something else. This pins the exact
    /// shape that made a would-be `.integer`/`.number` split ambiguous.
    func testAWholeNumberDoubleEncodesWithoutADecimalPointAndStillDecodesAsNumber() throws {
        XCTAssertEqual(try jsonString(.number(16.0)), "16")
        let data = try JSONEncoder().encode(SpikeMetricValue.number(16.0))
        let decoded = try JSONDecoder().decode(SpikeMetricValue.self, from: data)
        XCTAssertEqual(decoded, .number(16.0))
    }
}

// MARK: - Frame statistics (pure percentile math)

final class SpikeFrameStatisticsTests: XCTestCase {
    /// [10,20,30,40,50], deliberately given out of order to also pin that
    /// `summarize` sorts before computing.
    ///
    /// By hand: n=5, rank(p) = (p/100)*(n-1) = (p/100)*4.
    /// p50: rank=2.0 -> exact index 2 -> 30
    /// p95: rank=3.8 -> between index 3 (40) and 4 (50), weight .8 -> 48.0
    /// p99: rank=3.96 -> between 40 and 50, weight .96 -> 49.6
    /// max = 50.
    /// Late threshold = 1.5 x p50 = 1.5 x 30 = 45; values > 45 -> {50} = 1.
    /// Achieved cadence = 1000/30 = 33.333 fps.
    func testFiveValueDistributionMatchesHandComputedPercentiles() throws {
        let stats = try XCTUnwrap(SpikeFrameStatistics.summarize(durationsMs: [40, 10, 50, 20, 30]))
        XCTAssertEqual(stats.count, 5)
        XCTAssertEqual(stats.p50Ms, 30.0, accuracy: 0.0001)
        XCTAssertEqual(stats.p95Ms, 48.0, accuracy: 0.0001)
        XCTAssertEqual(stats.p99Ms, 49.6, accuracy: 0.0001)
        XCTAssertEqual(stats.maxMs, 50.0, accuracy: 0.0001)
        XCTAssertEqual(stats.overThresholdMs, 45.0, accuracy: 0.0001)
        XCTAssertEqual(stats.overThresholdCount, 1)
        XCTAssertEqual(stats.achievedFramesPerSecond, 33.3333, accuracy: 0.0001)
    }

    func testSingleValueDistributionReportsThatValueForEveryPercentile() throws {
        let stats = try XCTUnwrap(SpikeFrameStatistics.summarize(durationsMs: [42.0]))
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.p50Ms, 42.0)
        XCTAssertEqual(stats.p95Ms, 42.0)
        XCTAssertEqual(stats.p99Ms, 42.0)
        XCTAssertEqual(stats.maxMs, 42.0)
        // 1.5 x 42 = 63, and 42 is not > 63: a distribution of one frame
        // cannot contain a late frame, which is the honest answer.
        XCTAssertEqual(stats.overThresholdMs, 63.0, accuracy: 0.0001)
        XCTAssertEqual(stats.overThresholdCount, 0)
    }

    func testEmptyDistributionSummarizesToNilRatherThanACrash() {
        XCTAssertNil(SpikeFrameStatistics.summarize(durationsMs: []))
    }

    /// gh#201 ROUND-3 FIX (R1), and the test that kills MUT-D.
    ///
    /// Round 1 counted "over 16.0ms" against a literal and called 427 of
    /// 447 device samples late, because a healthy 60Hz frame is 16.67ms.
    /// Round 2 counted against the DISPLAY's advertised maximum and did
    /// worse: the device panel advertises 120Hz (threshold 12.5ms) while
    /// the link ran at 60Hz, so 367 of 367 samples were late.
    ///
    /// The property that survives both: the SAME cadence must produce zero
    /// late frames whatever the panel claims, and the threshold must MOVE
    /// with the observed cadence. No constant — 16.0, 12.5, 25.0 — can
    /// satisfy both halves at once.
    func testTheLateThresholdIsDerivedFromTheRunsOwnCadenceNotFromAnyConstant() throws {
        // A run that achieved 60Hz. 367 of these were called late in round 2.
        let at60 = try XCTUnwrap(SpikeFrameStatistics.summarize(
            durationsMs: [16.67, 16.67, 16.66, 16.68, 16.67]
        ))
        XCTAssertEqual(at60.overThresholdCount, 0, "a run's own median frame is never a late frame")
        XCTAssertEqual(at60.overThresholdMs, 25.005, accuracy: 0.001)
        XCTAssertEqual(at60.achievedFramesPerSecond, 59.988, accuracy: 0.01)

        // A run that achieved 120Hz, sampled from the same instrument.
        let at120 = try XCTUnwrap(SpikeFrameStatistics.summarize(
            durationsMs: [8.33, 8.33, 8.34, 8.33, 8.33]
        ))
        XCTAssertEqual(at120.overThresholdCount, 0, "a healthy 120Hz frame is not late either")
        XCTAssertEqual(at120.overThresholdMs, 12.495, accuracy: 0.001)
        XCTAssertEqual(at120.achievedFramesPerSecond, 120.048, accuracy: 0.01)

        // The two thresholds MUST differ: that is what no literal can do.
        XCTAssertNotEqual(at60.overThresholdMs, at120.overThresholdMs)
        // And 16.0 specifically — round 1's literal — is not either of them.
        XCTAssertNotEqual(at60.overThresholdMs, 16.0, accuracy: 0.001)
        XCTAssertNotEqual(at120.overThresholdMs, 16.0, accuracy: 0.001)
    }

    /// The device shape, replayed: a 60Hz run with a handful of long
    /// stalls. The late count must name the stalls and nothing else.
    func testTheDeviceShapedRunCountsItsStallsAndNotItsHealthyFrames() throws {
        var deltas = Array(repeating: 16.67, count: 20)
        deltas.append(contentsOf: [768.0, 805.0, 1159.8])
        let stats = try XCTUnwrap(SpikeFrameStatistics.summarize(durationsMs: deltas))
        XCTAssertEqual(stats.overThresholdCount, 3, "exactly the three stalls, not 23 of 23")
        XCTAssertEqual(stats.p50Ms, 16.67, accuracy: 0.001)
    }
}

// MARK: - SpikeFrameThreshold (observed-cadence late-frame bound)

final class SpikeFrameThresholdTests: XCTestCase {
    /// By hand: 1.5 x 16.6667 = 25.0.
    func testTheObservedThresholdIsOneAndAHalfTimesTheMedianFrame() {
        XCTAssertEqual(
            SpikeFrameThreshold.observedLateThresholdMs(medianFrameMs: 16.6667),
            25.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SpikeFrameThreshold.observedLateThresholdMs(medianFrameMs: 8.3333),
            12.5,
            accuracy: 0.0001
        )
    }

    /// By hand: 1000/16.6667 = 60.0; 1000/8.3333 = 120.0.
    func testTheAchievedCadenceIsTheReciprocalOfTheMedianFrame() {
        XCTAssertEqual(
            SpikeFrameThreshold.achievedFramesPerSecond(medianFrameMs: 16.6667),
            60.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SpikeFrameThreshold.achievedFramesPerSecond(medianFrameMs: 8.3333),
            120.0,
            accuracy: 0.001
        )
    }

    /// A degenerate median must not produce an infinite cadence.
    func testANonPositiveMedianReportsNoCadenceRatherThanInfinity() {
        XCTAssertEqual(SpikeFrameThreshold.achievedFramesPerSecond(medianFrameMs: 0), 0)
        XCTAssertEqual(SpikeFrameThreshold.achievedFramesPerSecond(medianFrameMs: -5), 0)
    }

    /// The display rate is CONTEXT now. It still has to answer sanely for
    /// a display that names no rate, because it is reported on the line.
    func testTheDisplayNominalIntervalIsStillReportedAndStillFallsBackToSixtyHertz() {
        XCTAssertEqual(SpikeFrameThreshold.nominalIntervalMs(maximumFramesPerSecond: 60), 16.6667, accuracy: 0.0001)
        XCTAssertEqual(SpikeFrameThreshold.nominalIntervalMs(maximumFramesPerSecond: 120), 8.3333, accuracy: 0.0001)
        XCTAssertEqual(
            SpikeFrameThreshold.nominalIntervalMs(maximumFramesPerSecond: 0),
            SpikeFrameThreshold.nominalIntervalMs(maximumFramesPerSecond: 60),
            accuracy: 0.0001
        )
        XCTAssertEqual(SpikeFrameThreshold.nominalIntervalMs(maximumFramesPerSecond: -1), 16.6667, accuracy: 0.0001)
    }

    /// The multiplier claim, stated honestly: 1.5x clears a nominal frame
    /// and lands under a dropped one. NOT "the smallest multiple that
    /// cannot fire" — 1.1x also clears a nominal frame, and this pins that
    /// the doc no longer claims otherwise.
    func testTheMultiplierClearsANominalFrameAndLandsUnderADroppedOne() {
        let p50 = 1_000.0 / 60.0
        let threshold = SpikeFrameThreshold.observedLateThresholdMs(medianFrameMs: p50)
        XCTAssertGreaterThan(threshold, p50)
        XCTAssertLessThan(threshold, 2 * p50, "a doubled frame must still count as late")
        // The disproof of the retired claim, kept as arithmetic:
        XCTAssertGreaterThan(1.1 * p50, p50)
    }
}

// MARK: - SpikeFrameOvershootTally (the system's own definition of late)

final class SpikeFrameOvershootTallyTests: XCTestCase {
    /// A link that lands on its own target is never late, whatever rate
    /// the OS chose — which is the whole reason this replaced
    /// `over33msCount`. 33ms deltas that arrive exactly on target produce
    /// zero here.
    func testOnTargetTicksAreNeverLateEvenWhenTheDeltaIsLarge() {
        var tally = SpikeFrameOvershootTally()
        for _ in 0..<10 { tally.admit(0.0) }
        XCTAssertEqual(tally.sampleCount, 10)
        XCTAssertEqual(tally.lateCount, 0)
        XCTAssertEqual(tally.maxMs, 0)
    }

    /// The tolerance is inclusive-safe on the low side: exactly 1.0ms of
    /// overshoot is jitter, 1.1ms is late.
    func testToleranceIsExclusiveAtItsOwnEdge() {
        var tally = SpikeFrameOvershootTally()
        tally.admit(1.0)
        XCTAssertEqual(tally.lateCount, 0)
        tally.admit(1.1)
        XCTAssertEqual(tally.lateCount, 1)
        XCTAssertEqual(tally.sampleCount, 2)
        XCTAssertEqual(tally.maxMs, 1.1, accuracy: 0.0001)
    }

    /// Bounded by construction: ten thousand samples, three stored numbers.
    func testTheTallyKeepsNoArrayAndSoCannotGrow() {
        var tally = SpikeFrameOvershootTally()
        for i in 0..<10_000 { tally.admit(Double(i % 7)) }
        XCTAssertEqual(tally.sampleCount, 10_000)
        XCTAssertEqual(tally.maxMs, 6)
        XCTAssertEqual(MemoryLayout<SpikeFrameOvershootTally>.size, MemoryLayout<Int>.size * 2 + MemoryLayout<Double>.size)
    }
}

// MARK: - Spike201DeliveryLagTracker (touch-delivery lag epoch)

final class Spike201DeliveryLagTrackerTests: XCTestCase {
    /// gh#201 ROUND-2 FIX 1, and the fixture that fails if the wall clock
    /// comes back. `DragGesture.Value.time` measured on device as
    /// `Date(timeIntervalSinceReferenceDate: systemUptime)`, so the number
    /// inside it is SECONDS SINCE BOOT wearing a `Date`'s clothes. Read in
    /// the media timebase it belongs to, a touch stamped at uptime 1000.000
    /// and handled at media time 1000.080 is an 80ms lag.
    func testLagIsReadInTheMediaTimebaseTheTouchStampIsActuallyOn() {
        let touch = Date(timeIntervalSinceReferenceDate: 1_000.0)
        XCTAssertEqual(
            Spike201DeliveryLagTracker.lagMs(eventTime: touch, mediaTimeNow: 1_000.08),
            80.0,
            accuracy: 0.0001
        )
    }

    /// The positive control for the fixture above: differencing the SAME
    /// stamp against a wall clock -- round 1's formula -- produces the
    /// absurdity round 1 actually recorded (~8.097e11 ms, about 25.7
    /// years). Asserted here so the defect stays legible rather than
    /// remembered.
    func testTheRoundOneWallClockFormulaProducesAnAbsurdityOnTheSameStamp() {
        let touch = Date(timeIntervalSinceReferenceDate: 1_000.0)
        let roundOneLagMs = Date(timeIntervalSinceReferenceDate: 800_000_000)
            .timeIntervalSince(touch) * 1_000
        XCTAssertGreaterThan(roundOneLagMs, 1e11)
        XCTAssertFalse(
            Spike201DeliveryLagTracker.isPlausible(roundOneLagMs),
            "round 1's number must be rejected by the plausibility rule, not averaged into a median"
        )
    }

    func testAPlausibleReadingIsAdmittedUnchangedAndCountsNothing() {
        var tracker = Spike201DeliveryLagTracker()
        let admitted = tracker.admit(
            eventTime: Date(timeIntervalSinceReferenceDate: 500.0),
            mediaTimeNow: 500.012
        )
        XCTAssertEqual(try XCTUnwrap(admitted), 12.0, accuracy: 0.0001)
        XCTAssertEqual(tracker.implausibleCount, 0)
        XCTAssertNil(tracker.firstImplausibleMs)
    }

    /// The absurd number must stay VISIBLE. Not clamped to the window edge
    /// -- a clamped -50 is indistinguishable from a real -50 -- and not
    /// admitted, where it would swallow the median whole.
    func testAnImplausibleReadingIsQuarantinedVerbatimNeverClamped() {
        var tracker = Spike201DeliveryLagTracker()
        let touch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expected = Spike201DeliveryLagTracker.lagMs(eventTime: touch, mediaTimeNow: 1_000)

        XCTAssertNil(tracker.admit(eventTime: touch, mediaTimeNow: 1_000))
        XCTAssertEqual(tracker.implausibleCount, 1)
        XCTAssertEqual(try XCTUnwrap(tracker.firstImplausibleMs), expected, accuracy: 1)
        XCTAssertLessThan(
            try XCTUnwrap(tracker.firstImplausibleMs),
            Spike201DeliveryLagTracker.minPlausibleMs,
            "the quarantined value is the raw reading, not the window edge"
        )
    }

    /// Both edges are INCLUSIVE, and one millisecond outside either is
    /// not. Pinned so a `<` / `<=` slip changes a test, not just a metric.
    func testThePlausibleWindowIsInclusiveAtBothEdges() {
        XCTAssertTrue(Spike201DeliveryLagTracker.isPlausible(-50))
        XCTAssertTrue(Spike201DeliveryLagTracker.isPlausible(5_000))
        XCTAssertFalse(Spike201DeliveryLagTracker.isPlausible(-51))
        XCTAssertFalse(Spike201DeliveryLagTracker.isPlausible(5_001))
    }

    func testFirstImplausibleKeepsTheFirstReadingNotTheLatest() {
        var tracker = Spike201DeliveryLagTracker()
        _ = tracker.admit(eventTime: Date(timeIntervalSinceReferenceDate: 0), mediaTimeNow: 100)
        _ = tracker.admit(eventTime: Date(timeIntervalSinceReferenceDate: 0), mediaTimeNow: 900)
        XCTAssertEqual(tracker.implausibleCount, 2)
        XCTAssertEqual(try XCTUnwrap(tracker.firstImplausibleMs), 100_000, accuracy: 0.0001)
    }

    /// A phase with no touch behind it (the commit brackets) records
    /// nothing at all -- neither a lag nor an implausibility.
    func testAMissingEventTimeIsNotAnImplausibleReading() {
        var tracker = Spike201DeliveryLagTracker()
        XCTAssertNil(tracker.admit(eventTime: nil, mediaTimeNow: 1_000))
        XCTAssertEqual(tracker.implausibleCount, 0)
    }
}

// MARK: - SpikeRunLog (pure run-log algebra)

final class SpikeRunLogTests: XCTestCase {
    private func makeRun(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        outcome: SpikeRunOutcome? = nil
    ) -> SpikeRun {
        SpikeRun(
            id: id, spikeID: "s", scenarioID: "sc", variantID: nil,
            startedAt: startedAt, endedAt: endedAt,
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone99,1", osVersion: "99.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            metrics: [:], note: nil, outcome: outcome, abortReason: nil
        )
    }

    func testCollapseKeepsTheLatestRecordPerIDInFirstSeenOrder() {
        let idA = UUID()
        let idB = UUID()
        let t0 = Date(timeIntervalSince1970: 0)
        let openA = makeRun(id: idA, startedAt: t0)
        let openB = makeRun(id: idB, startedAt: t0.addingTimeInterval(1))
        let closedA = makeRun(id: idA, startedAt: t0, endedAt: t0.addingTimeInterval(10), outcome: .completed)

        let collapsed = SpikeRunLog.collapse([openA, openB, closedA])

        XCTAssertEqual(collapsed.map(\.id), [idA, idB], "first-seen order must be preserved")
        XCTAssertEqual(collapsed[0].outcome, .completed, "the LATER record for idA must win")
        XCTAssertTrue(collapsed[1].isOpen, "idB's only record is still open")
    }

    func testOpenRunsFiltersToRecordsWithNoEndedAt() {
        let closed = makeRun(startedAt: .distantPast, endedAt: .distantPast, outcome: .completed)
        let open = makeRun(startedAt: .distantPast)
        XCTAssertEqual(SpikeRunLog.openRuns(in: [closed, open]).map(\.id), [open.id])
    }

    func testCloseAsInterruptedSetsEndedAtOutcomeAndAReason() {
        let open = makeRun(startedAt: .distantPast)
        let closedAt = Date(timeIntervalSince1970: 12345)

        let closed = SpikeRunLog.closeAsInterrupted([open], closedAt: closedAt)

        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].endedAt, closedAt)
        XCTAssertEqual(closed[0].outcome, .interrupted)
        XCTAssertNotNil(closed[0].abortReason)
        XCTAssertFalse(closed[0].isOpen)
    }

    func testCloseAsInterruptedNeverMutatesItsInput() {
        let open = makeRun(startedAt: .distantPast)
        _ = SpikeRunLog.closeAsInterrupted([open], closedAt: Date())
        XCTAssertTrue(open.isOpen, "the original value must be untouched -- this is a pure function")
    }

    func testRetentionKeepsTheNewestRunsByStartedAtWhenOverCap() {
        let t0 = Date(timeIntervalSince1970: 0)
        let older = makeRun(startedAt: t0)
        let middle = makeRun(startedAt: t0.addingTimeInterval(1))
        let newest = makeRun(startedAt: t0.addingTimeInterval(2))

        let kept = SpikeRunLog.applyRetention([older, middle, newest], cap: 2)

        XCTAssertEqual(Set(kept.map(\.id)), Set([middle.id, newest.id]))
        XCTAssertFalse(kept.map(\.id).contains(older.id), "the oldest run must be the one dropped")
    }

    func testRetentionWithCapZeroKeepsNothing() {
        let run = makeRun(startedAt: .distantPast)
        XCTAssertTrue(SpikeRunLog.applyRetention([run], cap: 0).isEmpty)
    }

    func testRetentionWithANegativeCapIsTreatedAsUnbounded() {
        let run = makeRun(startedAt: .distantPast)
        XCTAssertEqual(SpikeRunLog.applyRetention([run], cap: -1).map(\.id), [run.id])
    }

    func testRetentionUnderCapReturnsTheOriginalArrayUnsorted() {
        // When nothing needs dropping, the input's own order is preserved
        // rather than being re-sorted -- callers must not assume
        // `applyRetention` implies "now sorted by recency".
        let t0 = Date(timeIntervalSince1970: 0)
        let newer = makeRun(startedAt: t0.addingTimeInterval(1))
        let older = makeRun(startedAt: t0)
        let result = SpikeRunLog.applyRetention([newer, older], cap: 5)
        XCTAssertEqual(result.map(\.id), [newer.id, older.id])
    }
}

// MARK: - SpikeProbe (production seam)

final class SpikeProbeTests: XCTestCase {
    override func tearDown() {
        SpikeProbe.onSignal = nil
        super.tearDown()
    }

    func testEmitWithNoListenerAttachedDoesNotCrashOrThrow() {
        SpikeProbe.onSignal = nil
        SpikeProbe.emit(.bodyPass("anything"))
        SpikeProbe.emit(.textLength("anything", 3))
        // Reaching this line is the assertion: the disabled path is inert.
    }

    func testEmitForwardsExactlyOnceToAnAttachedListener() {
        var received: [SpikeSignal] = []
        SpikeProbe.onSignal = { received.append($0) }
        SpikeProbe.emit(.bodyPass("x"))
        XCTAssertEqual(received, [.bodyPass("x")])
    }
}

// MARK: - SpikeFrameSampleBuffer (pure retention bound)

final class SpikeFrameSampleBufferTests: XCTestCase {
    func testAppendsUnderCapacityAreAllKeptAndNotMarkedTruncated() {
        var buffer = SpikeFrameSampleBuffer(capacity: 3, gapCandidateMs: 1_000)
        buffer.append(1.5)
        buffer.append(2.5)
        XCTAssertEqual(buffer.samples, [1.5, 2.5])
        XCTAssertFalse(buffer.isTruncated)
        XCTAssertEqual(buffer.suspensionGapCount, 0)
        XCTAssertTrue(buffer.activeStallsMs.isEmpty)
    }

    func testAppendsPastCapacityAreDroppedAndMarkedTruncated() {
        var buffer = SpikeFrameSampleBuffer(capacity: 3, gapCandidateMs: 1_000)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0] {
            buffer.append(value)
        }
        XCTAssertEqual(buffer.samples, [1.0, 2.0, 3.0], "the EARLIEST samples are kept; appends past the cap are dropped, not rotated")
        XCTAssertTrue(buffer.isTruncated)
    }

    /// The suspension belt, now conditioned on the LIFECYCLE FACT. By
    /// hand, with bound 100 and the app having resigned active: 250 and
    /// exactly-100 are gaps (at-or-above), 10 and 20 are frames. Capacity
    /// 2 is chosen so the test also pins that gaps consume NO capacity —
    /// if the first gap ate a slot, 20 would have been truncated out.
    func testOverBoundDeltasAfterAResignAreSuspensionGapsAndConsumeNoCapacity() {
        var buffer = SpikeFrameSampleBuffer(capacity: 2, gapCandidateMs: 100)
        buffer.append(250.0, resignedActiveSinceLastSample: true)
        buffer.append(10.0)
        buffer.append(100.0, resignedActiveSinceLastSample: true)
        buffer.append(20.0)
        XCTAssertEqual(buffer.samples, [10.0, 20.0])
        XCTAssertEqual(buffer.suspensionGapCount, 2)
        XCTAssertEqual(buffer.suspensionGapsMs, [250.0, 100.0], "durations, not just a count")
        XCTAssertTrue(buffer.activeStallsMs.isEmpty)
        XCTAssertFalse(buffer.isTruncated, "a dropped gap is not truncation — the two markers answer different questions")
    }

    /// gh#201 ROUND-2 FIX 3, and the fixture that fails if duration goes
    /// back to being treated as evidence of suspension. Round 1 dropped
    /// three deltas of ≥1s on a run whose entire finding is ~1s
    /// main-thread stalls. With the app AWAKE, an over-bound delta is the
    /// longest frame that actually happened: it must reach the
    /// distribution (so it reaches max/p99) and be listed as a stall.
    func testAnOverBoundDeltaWithNoResignIsARealStallAdmittedToTheDistribution() throws {
        var buffer = SpikeFrameSampleBuffer(capacity: 10, gapCandidateMs: 1_000)
        buffer.append(16.7)
        buffer.append(1_261.0)
        buffer.append(16.7)

        XCTAssertEqual(buffer.samples, [16.7, 1_261.0, 16.7], "the stall is a sample; round 1 threw it away")
        XCTAssertEqual(buffer.activeStallsMs, [1_261.0])
        XCTAssertEqual(buffer.suspensionGapCount, 0, "nothing resigned active, so nothing was a suspension")
        XCTAssertTrue(buffer.suspensionGapsMs.isEmpty)

        let stats = try XCTUnwrap(SpikeFrameStatistics.summarize(durationsMs: buffer.samples))
        XCTAssertEqual(stats.maxMs, 1_261.0, accuracy: 0.0001, "a stall the rig admits is a stall the max can see")
    }

    /// The discriminator, stated as one fixture: the SAME duration is
    /// classified two different ways, and only the lifecycle fact decides.
    func testTheIdenticalDurationIsASuspensionOrAStallDependingOnlyOnTheLifecycleFact() {
        var suspended = SpikeFrameSampleBuffer(capacity: 10, gapCandidateMs: 1_000)
        suspended.append(4_000.0, resignedActiveSinceLastSample: true)

        var awake = SpikeFrameSampleBuffer(capacity: 10, gapCandidateMs: 1_000)
        awake.append(4_000.0, resignedActiveSinceLastSample: false)

        XCTAssertTrue(suspended.samples.isEmpty)
        XCTAssertEqual(suspended.suspensionGapsMs, [4_000.0])
        XCTAssertEqual(awake.samples, [4_000.0])
        XCTAssertEqual(awake.activeStallsMs, [4_000.0])
    }

    /// Retained DURATIONS are bounded (an orphaned probe must not grow
    /// them without limit) while the suspension COUNT is not — so a
    /// reader can always tell how many there were even once the list
    /// stopped growing.
    func testRetainedGapDurationsAreBoundedWhileTheCountIsNot() {
        var buffer = SpikeFrameSampleBuffer(capacity: 5_000, gapCandidateMs: 100)
        let overflow = SpikeFrameSampleBuffer.maxRetainedGaps + 7
        for _ in 0..<overflow {
            buffer.append(500.0, resignedActiveSinceLastSample: true)
            buffer.append(500.0, resignedActiveSinceLastSample: false)
        }
        XCTAssertEqual(buffer.suspensionGapCount, overflow)
        XCTAssertEqual(buffer.suspensionGapsMs.count, SpikeFrameSampleBuffer.maxRetainedGaps)
        XCTAssertEqual(buffer.activeStallsMs.count, SpikeFrameSampleBuffer.maxRetainedGaps)
    }

    func testANonPositiveGapCandidateBoundIsTreatedAsUnbounded() {
        var buffer = SpikeFrameSampleBuffer(capacity: 3, gapCandidateMs: 0)
        buffer.append(10_000, resignedActiveSinceLastSample: true)
        XCTAssertEqual(buffer.samples, [10_000], "a misconfigured bound must not silently discard every sample")
        XCTAssertEqual(buffer.suspensionGapCount, 0)
        XCTAssertTrue(buffer.activeStallsMs.isEmpty)
    }

    /// The invariant behind "a second stopAndSummarize returns nothing":
    /// draining hands everything over exactly once and resets ALL state —
    /// including both new gap lists — so the probe cannot re-report a
    /// stale distribution.
    func testDrainReturnsEverythingOnceAndResetsTheBuffer() {
        var buffer = SpikeFrameSampleBuffer(capacity: 2, gapCandidateMs: 100)
        buffer.append(10.0)
        buffer.append(20.0)
        buffer.append(30.0)
        buffer.append(500.0, resignedActiveSinceLastSample: true)
        buffer.append(700.0)

        let first = buffer.drain()
        XCTAssertEqual(first.samples, [10.0, 20.0])
        XCTAssertTrue(first.isTruncated)
        XCTAssertEqual(first.suspensionGapCount, 1)
        XCTAssertEqual(first.suspensionGapsMs, [500.0])
        XCTAssertEqual(first.activeStallsMs, [700.0])

        let second = buffer.drain()
        XCTAssertTrue(second.samples.isEmpty)
        XCTAssertFalse(second.isTruncated)
        XCTAssertEqual(second.suspensionGapCount, 0)
        XCTAssertTrue(second.suspensionGapsMs.isEmpty)
        XCTAssertTrue(second.activeStallsMs.isEmpty)
        XCTAssertTrue(second.largestDeltasMs.isEmpty)
        XCTAssertNil(
            SpikeFrameStatistics.summarize(durationsMs: second.samples),
            "an empty drain summarizes to nil — the second stop reports no distribution"
        )
    }

    /// gh#201 round 3 / R12. Round 2's credibility bound was 1000ms while
    /// the stalls it measured came in at 768–1160ms, so the same physical
    /// event landed on either side of it at a 4% margin. The top-N list is
    /// recorded BEFORE any classification, so whichever side of the bound
    /// a delta falls on, its duration is still on the line.
    func testTheLargestDeltasAreRetainedWhicheverSideOfTheBoundTheyFallOn() {
        // Bound at 900: 768 is "just a frame", 1160 is a stall, and one
        // suspension is dropped from the distribution entirely.
        var buffer = SpikeFrameSampleBuffer(capacity: 100, gapCandidateMs: 900)
        buffer.append(16.7)
        buffer.append(768.0)
        buffer.append(1_159.8)
        buffer.append(2_000.0, resignedActiveSinceLastSample: true)

        XCTAssertEqual(buffer.samples, [16.7, 768.0, 1_159.8], "the suspension is not a frame")
        XCTAssertEqual(buffer.activeStallsMs, [1_159.8], "only 1159.8 crossed the bound while awake")
        XCTAssertEqual(buffer.suspensionGapsMs, [2_000.0])
        // Every one of them, including the 768 the bound called ordinary
        // and the 2000 it dropped:
        XCTAssertEqual(buffer.largestDeltasMs, [2_000.0, 1_159.8, 768.0, 16.7])
    }

    /// Descending, capped, and never grown by an orphaned probe.
    func testTheLargestDeltaListIsSortedDescendingAndBounded() {
        var buffer = SpikeFrameSampleBuffer(capacity: 10_000, gapCandidateMs: 250)
        for i in 1...1_000 { buffer.append(Double(i)) }
        XCTAssertEqual(buffer.largestDeltasMs.count, SpikeFrameSampleBuffer.maxRetainedLargestDeltas)
        XCTAssertEqual(buffer.largestDeltasMs.first, 1_000.0)
        XCTAssertEqual(buffer.largestDeltasMs, buffer.largestDeltasMs.sorted(by: >))
    }
}

// MARK: - SpikeFrameTickIngestor (the lifecycle fact, owned rather than passed)

/// The tests that kill MUT-I. That mutation passed a literal `false` where
/// the probe passed its lifecycle fact — reclassifying every background
/// gap as a real main-thread stall, i.e. fabricating this spike's headline
/// number — and it survived 32 tests because the fact was read and passed
/// inside an `@objc` display-link callback nothing could reach.
final class SpikeFrameTickIngestorTests: XCTestCase {
    private func ingestor() -> SpikeFrameTickIngestor {
        SpikeFrameTickIngestor(capacity: 100, gapCandidateMs: 250)
    }

    /// The tick-to-delta wiring, by hand: seconds in, milliseconds out,
    /// and the FIRST tick produces no delta because it has nothing to
    /// measure from.
    func testTicksBecomeMillisecondDeltasAndTheFirstTickProducesNone() {
        var ing = ingestor()
        ing.ingest(timestamp: 100.0, targetTimestamp: 100.0167)
        XCTAssertTrue(ing.buffer.samples.isEmpty)
        ing.ingest(timestamp: 100.0167, targetTimestamp: 100.0334)
        ing.ingest(timestamp: 100.0334, targetTimestamp: 100.0501)
        XCTAssertEqual(ing.buffer.samples.count, 2)
        XCTAssertEqual(ing.buffer.samples[0], 16.7, accuracy: 0.01)
    }

    /// MUT-I, stated as a fixture. A one-second gap that spans a resign is
    /// a suspension; the identical gap with no resign is a stall. If the
    /// lifecycle fact is replaced by a constant `false`, the first
    /// assertion below fails — the suspension is reported as a stall and
    /// admitted to the distribution.
    func testAGapAcrossAResignIsASuspensionAndTheSameGapWhileAwakeIsAStall() {
        var suspended = ingestor()
        suspended.ingest(timestamp: 10.0, targetTimestamp: 10.0167)
        suspended.noteWillResignActive()
        // Re-baselined at the resign, so two ticks are needed before a
        // delta spanning the gap exists.
        suspended.ingest(timestamp: 11.0, targetTimestamp: 11.0167)
        suspended.ingest(timestamp: 12.0, targetTimestamp: 12.0167)
        XCTAssertEqual(suspended.buffer.suspensionGapCount, 1)
        XCTAssertEqual(suspended.buffer.suspensionGapsMs, [1_000.0])
        XCTAssertTrue(suspended.buffer.samples.isEmpty, "a suspension gap is not a frame time")
        XCTAssertTrue(suspended.buffer.activeStallsMs.isEmpty, "and it is not a main-thread stall either")

        var awake = ingestor()
        awake.ingest(timestamp: 11.0, targetTimestamp: 11.0167)
        awake.ingest(timestamp: 12.0, targetTimestamp: 12.0167)
        XCTAssertEqual(awake.buffer.activeStallsMs, [1_000.0])
        XCTAssertEqual(awake.buffer.samples, [1_000.0])
        XCTAssertEqual(awake.buffer.suspensionGapCount, 0)
    }

    /// The dangerous ordering the flag exists for: a tick that lands after
    /// the process resumes but BEFORE `didBecomeActive` arrives. Only a
    /// flag still set at that moment classifies its enormous delta right.
    func testATickThatBeatsTheDidBecomeActiveNotificationIsStillASuspension() {
        var ing = ingestor()
        ing.ingest(timestamp: 10.0, targetTimestamp: 10.0167)
        ing.noteWillResignActive()
        ing.ingest(timestamp: 40.0, targetTimestamp: 40.0167)
        ing.ingest(timestamp: 70.0, targetTimestamp: 70.0167)   // arrives before the notification
        ing.noteDidBecomeActive()
        ing.ingest(timestamp: 70.02, targetTimestamp: 70.0367)
        ing.ingest(timestamp: 70.04, targetTimestamp: 70.0567)
        XCTAssertEqual(ing.buffer.suspensionGapCount, 1)
        XCTAssertEqual(ing.buffer.suspensionGapsMs, [30_000.0])
        XCTAssertEqual(ing.buffer.samples.count, 1, "only the post-resume 20ms frame is a frame")
        XCTAssertEqual(ing.buffer.samples[0], 20.0, accuracy: 0.01)
    }

    /// gh#201 round 3 / R13: the edges are counted unconditionally, so
    /// "the app never backgrounded" stops being a prose assertion.
    func testLifecycleEdgesAreCountedIncludingWhenThereAreNone() {
        var quiet = ingestor()
        quiet.ingest(timestamp: 1.0, targetTimestamp: 1.0167)
        let quietDrain = quiet.drain()
        XCTAssertEqual(quietDrain.resignActiveCount, 0)
        XCTAssertEqual(quietDrain.didBecomeActiveCount, 0)

        var switched = ingestor()
        switched.noteWillResignActive()
        switched.noteDidBecomeActive()
        switched.noteWillResignActive()
        let switchedDrain = switched.drain()
        XCTAssertEqual(switchedDrain.resignActiveCount, 2)
        XCTAssertEqual(switchedDrain.didBecomeActiveCount, 1)
    }

    /// The overshoot series, by hand. Each tick's timestamp is compared
    /// against the PREVIOUS tick's targetTimestamp — the OS's own
    /// statement of what it expected.
    func testOvershootIsMeasuredAgainstThePreviousTicksTarget() {
        var ing = ingestor()
        ing.ingest(timestamp: 0.0, targetTimestamp: 0.0167)
        ing.ingest(timestamp: 0.0167, targetTimestamp: 0.0334)   // exactly on target: 0ms
        ing.ingest(timestamp: 0.0434, targetTimestamp: 0.0601)   // 10ms past target
        XCTAssertEqual(ing.overshoot.sampleCount, 2)
        XCTAssertEqual(ing.overshoot.lateCount, 1)
        XCTAssertEqual(ing.overshoot.maxMs, 10.0, accuracy: 0.01)
    }

    /// A 33ms delta that the OS itself expected is NOT late — the exact
    /// case `over33msCount` could not distinguish. This is the fixture
    /// that justifies retiring it.
    func testAThirtyThreeMillisecondDeltaTheSystemAskedForIsNotLate() {
        var ing = ingestor()
        // The OS has throttled to 30fps: it schedules the next frame 33ms
        // out, and the link lands on it.
        ing.ingest(timestamp: 0.0, targetTimestamp: 0.0333)
        ing.ingest(timestamp: 0.0333, targetTimestamp: 0.0666)
        ing.ingest(timestamp: 0.0666, targetTimestamp: 0.0999)
        XCTAssertEqual(ing.overshoot.lateCount, 0, "idle throttling is not a dropped frame")
        XCTAssertEqual(ing.buffer.samples.count, 2)
        XCTAssertEqual(ing.buffer.samples[0], 33.3, accuracy: 0.05, "the deltas ARE 33ms — and mean nothing")
    }

    /// A lifecycle edge must not leave a fake overshoot behind: the gap
    /// spanning a suspension is neither a frame nor a missed deadline.
    func testALifecycleEdgeDropsTheOvershootThatSpansItToo() {
        var ing = ingestor()
        ing.ingest(timestamp: 10.0, targetTimestamp: 10.0167)
        ing.noteWillResignActive()
        ing.ingest(timestamp: 40.0, targetTimestamp: 40.0167)
        XCTAssertEqual(ing.overshoot.sampleCount, 0, "no target survives the edge, so no overshoot is computed")
    }

    func testDrainHandsEverythingOverOnceAndResetsTheEdgeCounts() {
        var ing = ingestor()
        ing.noteWillResignActive()
        ing.noteDidBecomeActive()
        ing.ingest(timestamp: 1.0, targetTimestamp: 1.0167)
        ing.ingest(timestamp: 1.02, targetTimestamp: 1.0367)
        let first = ing.drain()
        XCTAssertEqual(first.samples.count, 1)
        XCTAssertEqual(first.resignActiveCount, 1)
        XCTAssertEqual(first.overshoot.sampleCount, 1)

        let second = ing.drain()
        XCTAssertTrue(second.samples.isEmpty)
        XCTAssertEqual(second.resignActiveCount, 0)
        XCTAssertEqual(second.didBecomeActiveCount, 0)
        XCTAssertEqual(second.overshoot.sampleCount, 0)
    }
}

// MARK: - SpikeSessionCoordinator (registration algebra + seam ownership)

@MainActor
final class SpikeSessionCoordinatorTests: XCTestCase {
    private var coordinator: SpikeSessionCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = SpikeSessionCoordinator()
    }

    override func tearDown() {
        // Some tests deliberately end with listeners still registered
        // (fan-out and stamping tests never stop their runs), so clear
        // the static seam rather than leaking a listener into the next
        // test.
        SpikeProbe.onSignal = nil
        coordinator = nil
        super.tearDown()
    }

    private func makeRun(spikeID: String, scenarioID: String = "sc", startedAt: Date = Date()) -> SpikeRun {
        SpikeRun(
            id: UUID(), spikeID: spikeID, scenarioID: scenarioID, variantID: nil,
            startedAt: startedAt, endedAt: nil,
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone99,1", osVersion: "99.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            metrics: [:], note: nil, outcome: nil, abortReason: nil
        )
    }

    @discardableResult
    private func registerListener(
        _ run: SpikeRun,
        store: EventStore? = nil,
        onSignal: @escaping (SpikeSignal) -> Void = { _ in },
        onSlotCommitted: ((StorageSlot) -> Void)? = nil,
        stop: @escaping () -> Void = {}
    ) -> SpikeRun {
        coordinator.register(run: run, store: store, onSignal: onSignal, onSlotCommitted: onSlotCommitted, stop: stop)
    }

    func testSignalFanOutReachesEveryRegisteredListener() {
        var aReceived: [SpikeSignal] = []
        var bReceived: [SpikeSignal] = []
        registerListener(makeRun(spikeID: "spike-a"), onSignal: { aReceived.append($0) })
        registerListener(makeRun(spikeID: "spike-b"), onSignal: { bReceived.append($0) })

        SpikeProbe.emit(.bodyPass("x"))

        XCTAssertEqual(aReceived, [.bodyPass("x")])
        XCTAssertEqual(bReceived, [.bodyPass("x")], "the second listener must NOT have clobbered the first -- both hear every signal")
    }

    func testUnregisteringOneListenerStopsOnlyThatOneAndTheLastRestoresTheDisabledPath() {
        var aReceived: [SpikeSignal] = []
        var bReceived: [SpikeSignal] = []
        let runA = registerListener(makeRun(spikeID: "spike-a"), onSignal: { aReceived.append($0) })
        let runB = registerListener(makeRun(spikeID: "spike-b"), onSignal: { bReceived.append($0) })

        coordinator.unregister(runID: runA.id)
        SpikeProbe.emit(.textLength("field", 7))

        XCTAssertTrue(aReceived.isEmpty, "an unregistered listener must hear nothing")
        XCTAssertEqual(bReceived, [.textLength("field", 7)], "the surviving listener must be unaffected")

        coordinator.unregister(runID: runB.id)
        XCTAssertNil(SpikeProbe.onSignal, "with nothing armed, emit must be back to a single optional-closure nil-check -- the zero-cost contract")
    }

    /// Arm order drives the stamp: A arms alone (stamp is EMPTY, not nil
    /// -- nil is reserved for records that predate the field), then B arms
    /// while A is live (stamp names A). A's own stamp can never mention B,
    /// because B did not exist when A armed and stamps are immutable
    /// arm-time facts.
    func testCoActiveStampNamesSpikesArmedEarlierAndNeverSelf() throws {
        let stampedA = registerListener(makeRun(spikeID: "spike-a"))
        let stampedB = registerListener(makeRun(spikeID: "spike-b"))

        XCTAssertEqual(stampedA.coActiveSpikeIDs, [], "armed alone means empty, not nil")
        XCTAssertEqual(stampedB.coActiveSpikeIDs, ["spike-a"])
        XCTAssertFalse(try XCTUnwrap(stampedB.coActiveSpikeIDs).contains("spike-b"), "a run never appears in its own stamp")
    }

    func testActiveRunsListsRegistrationsInArmOrderAndDropsTheUnregistered() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let runA = registerListener(makeRun(spikeID: "spike-a", scenarioID: "sc-a", startedAt: t0))
        let runB = registerListener(makeRun(spikeID: "spike-b", scenarioID: "sc-b", startedAt: t0.addingTimeInterval(1)))

        XCTAssertEqual(coordinator.activeRuns.map(\.id), [runA.id, runB.id])
        XCTAssertEqual(coordinator.activeRuns.map(\.spikeID), ["spike-a", "spike-b"])
        XCTAssertEqual(coordinator.activeRuns.first?.startedAt, t0)

        coordinator.unregister(runID: runA.id)
        XCTAssertEqual(coordinator.activeRuns.map(\.id), [runB.id])
        XCTAssertEqual(coordinator.armedRunIDs, [runB.id])
    }

    func testStopRoutesToExactlyTheTargetedRunsStopHandler() {
        var aStopped = false
        var bStopped = false
        let runA = registerListener(makeRun(spikeID: "spike-a"), stop: { aStopped = true })
        registerListener(makeRun(spikeID: "spike-b"), stop: { bStopped = true })

        coordinator.stop(runID: runA.id)

        XCTAssertTrue(aStopped)
        XCTAssertFalse(bStopped, "stopping one run must not touch another")
    }

    func testStopAllReachesEveryRegisteredStopHandler() {
        var stopped: Set<String> = []
        registerListener(makeRun(spikeID: "spike-a"), stop: { stopped.insert("a") })
        registerListener(makeRun(spikeID: "spike-b"), stop: { stopped.insert("b") })

        coordinator.stopAll()

        XCTAssertEqual(stopped, ["a", "b"])
    }

    /// "The entry is gone by the time stop returns" is enforced by the
    /// coordinator, not delegated to the handler: these handlers do NOT
    /// unregister (a broken or partial runner), and removal must happen
    /// anyway -- including the last-listener seam teardown.
    func testStopRemovesTheEntryEvenWhenItsHandlerDoesNotUnregister() {
        let runA = registerListener(makeRun(spikeID: "spike-a"), stop: {})
        let runB = registerListener(makeRun(spikeID: "spike-b"), stop: {})

        coordinator.stop(runID: runA.id)
        XCTAssertEqual(coordinator.activeRuns.map(\.id), [runB.id], "only the stopped run's entry is removed")

        coordinator.stopAll()
        XCTAssertTrue(coordinator.activeRuns.isEmpty)
        XCTAssertTrue(coordinator.armedRunIDs.isEmpty)
        XCTAssertNil(SpikeProbe.onSignal, "removing the last entry must restore the disarmed seam even on the enforcement path")
    }
}

/// The `EventStore.onSlotCommitted` half of seam ownership, against a real
/// (isolated) store. The commit itself is simulated by invoking the seam
/// closure directly -- what fires it on a genuine disk commit is pinned by
/// the persistence suites, not re-proven here.
@MainActor
final class SpikeSessionCoordinatorSlotSeamTests: XCTestCase {
    private var coordinator: SpikeSessionCoordinator!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storageLocation: EventStorageLocation!

    override func setUp() {
        super.setUp()
        coordinator = SpikeSessionCoordinator()
        suiteName = "SpikeSessionCoordinatorSlotSeamTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storageLocation = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        SpikeProbe.onSignal = nil
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        storageLocation = nil
        coordinator = nil
        super.tearDown()
    }

    private func makeRun(spikeID: String) -> SpikeRun {
        SpikeRun(
            id: UUID(), spikeID: spikeID, scenarioID: "sc", variantID: nil,
            startedAt: Date(), endedAt: nil,
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone99,1", osVersion: "99.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            metrics: [:], note: nil, outcome: nil, abortReason: nil
        )
    }

    func testSlotCommitFanOutReachesEveryListenerAndTheLastUnregisterDetachesTheSeam() {
        let store = EventStore(defaults: defaults, storage: storageLocation, seedsSampleDataIfEmpty: false)
        var aSlots: [StorageSlot] = []
        var bSlots: [StorageSlot] = []
        let runA = coordinator.register(
            run: makeRun(spikeID: "spike-a"), store: store,
            onSignal: { _ in }, onSlotCommitted: { aSlots.append($0) }, stop: {}
        )
        let runB = coordinator.register(
            run: makeRun(spikeID: "spike-b"), store: store,
            onSignal: { _ in }, onSlotCommitted: { bSlots.append($0) }, stop: {}
        )

        store.onSlotCommitted?(.calendarEvents)
        XCTAssertEqual(aSlots, [.calendarEvents])
        XCTAssertEqual(bSlots, [.calendarEvents], "registering B must not clobber A's listener -- v1's exact failure mode")

        coordinator.unregister(runID: runA.id)
        store.onSlotCommitted?(.calendarEvents)
        XCTAssertEqual(aSlots, [.calendarEvents], "unregistered A hears nothing further")
        XCTAssertEqual(bSlots, [.calendarEvents, .calendarEvents])

        coordinator.unregister(runID: runB.id)
        XCTAssertNil(store.onSlotCommitted, "the last unregister must return the store's seam to its disarmed state")
    }
}

// MARK: - SpikeRunStore (disk behavior, isolated location)

final class SpikeRunStoreTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private let spikeID = "store-test-spike"

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    private func makeOpenRun(id: UUID = UUID(), startedAt: Date = Date(), note: String? = nil) -> SpikeRun {
        SpikeRun(
            id: id, spikeID: spikeID, scenarioID: "sc", variantID: nil,
            startedAt: startedAt, endedAt: nil,
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone99,1", osVersion: "99.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            metrics: [:], note: note, outcome: nil, abortReason: nil
        )
    }

    func testBeginThenFinishRoundTripsAsOneClosedRun() throws {
        let open = makeOpenRun()
        SpikeRunStore.beginRun(open, location: location)

        var closed = open
        closed.endedAt = open.startedAt.addingTimeInterval(5)
        closed.outcome = .completed
        closed.metrics = ["storeWrites": .number(3)]
        SpikeRunStore.finishRun(closed, location: location)

        let loaded = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        XCTAssertEqual(loaded.count, 1, "open+close for the same id must collapse to one run")
        let run = try XCTUnwrap(loaded.first)
        XCTAssertFalse(run.isOpen)
        XCTAssertEqual(run.outcome, .completed)
        XCTAssertEqual(run.metrics["storeWrites"], .number(3))
    }

    func testAnOpenRunWithNoClosingRecordIsReconciledAsInterrupted() throws {
        let open = makeOpenRun()
        SpikeRunStore.beginRun(open, location: location)

        SpikeRunStore.reconcileInterruptedRuns(spikeIDs: [spikeID], closedAt: Date(), location: location)

        let loaded = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        let run = try XCTUnwrap(loaded.first(where: { $0.id == open.id }))
        XCTAssertEqual(run.outcome, .interrupted)
        XCTAssertFalse(run.isOpen)
    }

    func testReconcileIsIdempotentAndDoesNotReopenAnAlreadyClosedRun() throws {
        let open = makeOpenRun()
        SpikeRunStore.beginRun(open, location: location)
        SpikeRunStore.reconcileInterruptedRuns(spikeIDs: [spikeID], closedAt: Date(), location: location)
        SpikeRunStore.reconcileInterruptedRuns(spikeIDs: [spikeID], closedAt: Date(), location: location)

        let loaded = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        XCTAssertEqual(loaded.count, 1, "a second reconcile pass must not append yet another closing record")
        XCTAssertEqual(loaded.first?.outcome, .interrupted)
    }

    func testReconcileLeavesACompletedRunAlone() throws {
        let open = makeOpenRun()
        SpikeRunStore.beginRun(open, location: location)
        var closed = open
        closed.endedAt = Date()
        closed.outcome = .completed
        SpikeRunStore.finishRun(closed, location: location)

        SpikeRunStore.reconcileInterruptedRuns(spikeIDs: [spikeID], closedAt: Date(), location: location)

        let run = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: spikeID, location: location).first)
        XCTAssertEqual(run.outcome, .completed, "reconcile must not overwrite a run that finished normally")
    }

    func testSetNoteUpdatesTheReadBackNoteWithoutTouchingOtherFields() throws {
        let open = makeOpenRun()
        SpikeRunStore.beginRun(open, location: location)
        var closed = open
        closed.endedAt = Date()
        closed.outcome = .completed
        SpikeRunStore.finishRun(closed, location: location)

        let wrote = SpikeRunStore.setNote("this feels floaty", forRunID: open.id, spikeID: spikeID, location: location)
        XCTAssertTrue(wrote)

        let run = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: spikeID, location: location).first)
        XCTAssertEqual(run.note, "this feels floaty")
        XCTAssertEqual(run.outcome, .completed, "setNote must not disturb outcome/metrics")
    }

    /// A line exactly as v1 wrote it: no `coActiveSpikeIDs` key at all.
    /// `loadRuns` decodes line-by-line with `try?`, so if the new field
    /// were required this line would not fail loudly -- it would be
    /// SILENTLY DROPPED, erasing every run recorded before v2. The field
    /// staying optional is what this pins.
    func testAV1ShapedLineWithoutCoActiveSpikeIDsStillDecodesFromDisk() throws {
        let v1Line = """
        {"id":"7E9C1A2B-0000-4000-8000-000000000001","spikeID":"\(spikeID)","scenarioID":"sc","startedAt":"2026-08-01T12:00:00Z","endedAt":"2026-08-01T12:00:05Z","appVersion":"1.0","appBuild":"1","deviceModel":"iPhone99,1","osVersion":"99.0","timeZoneIdentifier":"UTC","localeIdentifier":"en_US","metrics":{"storeWrites":3},"outcome":"completed"}
        """
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try Data((v1Line + "\n").utf8).write(to: location.directory.appendingPathComponent("\(spikeID).jsonl"))

        let loaded = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        XCTAssertEqual(loaded.count, 1, "a v1 line must decode, not be silently skipped")
        let run = try XCTUnwrap(loaded.first)
        XCTAssertNil(run.coActiveSpikeIDs, "an absent field decodes as nil (pre-v2 record), never a decode failure")
        XCTAssertEqual(run.outcome, .completed)
        XCTAssertEqual(run.metrics["storeWrites"], .number(3))
    }

    func testCoActiveSpikeIDsRoundTripsThroughBeginAndLoad() throws {
        var open = makeOpenRun()
        open.coActiveSpikeIDs = ["other-spike"]
        SpikeRunStore.beginRun(open, location: location)

        let run = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: spikeID, location: location).first)
        XCTAssertEqual(run.coActiveSpikeIDs, ["other-spike"])
    }

    /// Under parallel arming, an open record can belong to a run the
    /// CURRENT process has live right now -- reconciling it away would
    /// close a run mid-measurement. The exclusion set (in production, the
    /// coordinator's armed ids) is what separates armed from orphaned.
    func testReconcileLeavesAnExcludedArmedRunOpenWhileClosingTrueOrphans() throws {
        let armed = makeOpenRun()
        let orphan = makeOpenRun()
        SpikeRunStore.beginRun(armed, location: location)
        SpikeRunStore.beginRun(orphan, location: location)

        SpikeRunStore.reconcileInterruptedRuns(
            spikeIDs: [spikeID], closedAt: Date(),
            excludingRunIDs: [armed.id], location: location
        )

        let loaded = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        let armedBack = try XCTUnwrap(loaded.first { $0.id == armed.id })
        let orphanBack = try XCTUnwrap(loaded.first { $0.id == orphan.id })
        XCTAssertTrue(armedBack.isOpen, "a run the current process armed must never be reconciled away")
        XCTAssertNil(armedBack.outcome)
        XCTAssertEqual(orphanBack.outcome, .interrupted, "the unexcluded orphan must still be closed")
    }

    func testSetNoteOnAnUnknownRunIDFailsWithoutWritingAnything() {
        let wrote = SpikeRunStore.setNote("x", forRunID: UUID(), spikeID: spikeID, location: location)
        XCTAssertFalse(wrote)
        XCTAssertTrue(SpikeRunStore.loadRuns(spikeID: spikeID, location: location).isEmpty)
    }

    /// Count-based retention: enough DISTINCT runs to cross
    /// `maxRunsPerSpike` (200) by a small margin, written oldest-first so
    /// the dropped set is unambiguous. Exercises the real cap constant
    /// end-to-end (not a mocked-down cap) via real file writes, the same
    /// "write real volume, then assert" style `DiagnosticTrailTests` uses
    /// for its own byte-rotation threshold.
    func testRetentionDropsTheOldestRunsOnceDistinctCountExceedsTheCap() throws {
        let overflow = 3
        let total = SpikeRunStore.maxRunsPerSpike + overflow
        var ids: [UUID] = []
        for i in 0..<total {
            let id = UUID()
            ids.append(id)
            let startedAt = Date(timeIntervalSince1970: TimeInterval(i))
            let open = makeOpenRun(id: id, startedAt: startedAt)
            SpikeRunStore.beginRun(open, location: location)
            var closed = open
            closed.endedAt = startedAt.addingTimeInterval(1)
            closed.outcome = .completed
            SpikeRunStore.finishRun(closed, location: location)
        }

        let loaded = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        XCTAssertEqual(loaded.count, SpikeRunStore.maxRunsPerSpike)

        let loadedIDs = Set(loaded.map(\.id))
        for droppedIndex in 0..<overflow {
            XCTAssertFalse(loadedIDs.contains(ids[droppedIndex]), "run #\(droppedIndex) was the oldest and must have been dropped")
        }
        XCTAssertTrue(loadedIDs.contains(ids[total - 1]), "the newest run must survive retention")
    }

    /// Byte-size backstop: many edits to the SAME run id, which the
    /// count-based cap does not see (distinct-run count stays at 1). Each
    /// edit re-appends a full record, so without compaction the file would
    /// grow without bound purely from note churn on one run.
    func testRepeatedNoteEditsOnOneRunAreCompactedRatherThanGrowingUnbounded() throws {
        let open = makeOpenRun()
        SpikeRunStore.beginRun(open, location: location)
        var closed = open
        closed.endedAt = Date()
        closed.outcome = .completed
        SpikeRunStore.finishRun(closed, location: location)

        let padding = String(repeating: "n", count: 3000)
        let editCount = 90 // 90 * ~3KB well exceeds compactAtBytes (256KB)
        for i in 0..<editCount {
            SpikeRunStore.setNote("\(i)-\(padding)", forRunID: open.id, spikeID: spikeID, location: location)
        }

        let loaded = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        XCTAssertEqual(loaded.count, 1, "still exactly one distinct run")
        XCTAssertEqual(loaded.first?.note, "\(editCount - 1)-\(padding)", "the LAST edit must be what survives")

        let fileSize = ((try? FileManager.default.attributesOfItem(
            atPath: location.directory.appendingPathComponent("\(spikeID).jsonl").path
        ))?[.size] as? NSNumber)?.intValue ?? Int.max
        XCTAssertLessThan(
            fileSize, SpikeRunStore.compactAtBytes,
            "compaction must have collapsed the duplicate lines -- \(editCount) uncompacted edits would be roughly \(editCount * padding.count) bytes"
        )
    }
}

// MARK: - gh#201 effort-tap latency rig

/// The gh#201 rig's own tests. What is being pinned here is not "the code
/// runs" but the one property the whole measurement depends on: a tap
/// whose touches were HELD by an enclosing scroll view and delivered in
/// one batch at lift must come out of this log measurably different from
/// a tap whose touches were delivered live. If those two collapse to the
/// same numbers, the rig cannot answer gh#201's question and any number
/// it prints is precise, reproducible, and meaningless.
///
/// Every timestamp below is a hand-written monotonic-seconds fixture, so
/// the expected millisecond values are arithmetic, not observations.
final class Spike201EffortTapTests: XCTestCase {

    /// Delivered-at-lift fixture: ONE `.changed` and the `.ended`
    /// essentially together (UIKit sends touchesBegan and touchesEnded
    /// back to back once the delay expires against an already-lifted
    /// finger), even though the finger was really down for ~90ms.
    private func heldDeliveryTap(startingAt t: Double) -> [(SpikeGesturePhase, Double, Double)] {
        [
            (.changed, t, 100),
            (.ended, t + 0.002, 100),
            (.commitStart, t + 0.004, 0),
            (.commitEnd, t + 0.030, 0),
        ]
    }

    /// Live-delivery fixture: the same human tap, but the touches arrive
    /// as they happen — several `.changed` samples spread across the time
    /// the finger was actually down, with sub-threshold jitter.
    private func liveDeliveryTap(startingAt t: Double) -> [(SpikeGesturePhase, Double, Double)] {
        [
            (.changed, t, 100),
            (.changed, t + 0.020, 102),
            (.changed, t + 0.040, 101),
            (.changed, t + 0.060, 103),
            (.ended, t + 0.088, 103),
            (.commitStart, t + 0.090, 0),
            (.commitEnd, t + 0.116, 0),
        ]
    }

    private func slowDrag(startingAt t: Double) -> [(SpikeGesturePhase, Double, Double)] {
        var events: [(SpikeGesturePhase, Double, Double)] = []
        for step in 0..<10 {
            events.append((.changed, t + Double(step) * 0.03, 40 + Double(step) * 20))
        }
        events.append((.ended, t + 0.31, 240))
        events.append((.commitStart, t + 0.312, 0))
        events.append((.commitEnd, t + 0.340, 0))
        return events
    }

    private func feed(_ events: [(SpikeGesturePhase, Double, Double)], into log: inout Spike201GestureLog) {
        for (phase, time, x) in events {
            log.ingest(phase: phase, at: time, locationX: x, deliveryLagMs: nil)
        }
    }

    /// THE test this rig exists for.
    func testHeldDeliveryTapIsDistinguishableFromLiveDeliveryTap() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        feed(liveDeliveryTap(startingAt: 20), into: &log)

        XCTAssertEqual(log.records.count, 2, "two gestures, segmented by their commit brackets")

        let held = log.records[0]
        let live = log.records[1]

        // Both are taps: neither travelled far enough to be a drag.
        XCTAssertTrue(Spike201Metrics.isTap(held))
        XCTAssertTrue(Spike201Metrics.isTap(live))

        // THE discriminator. gh#201 round 2 corrects what round 1's
        // comment claimed here ("both instruments"): the tap witnesses are
        // this duration and the delivery lag. `changedCount` below is
        // recorded, and this synthetic fixture happens to vary it, but it
        // is NOT a witness for taps -- see
        // `testChangedCountIsNotATapWitnessOnDeviceShapedFixtures`, where a
        // live-delivered STATIONARY finger produces exactly one `.changed`
        // just like a held one.
        XCTAssertEqual(held.changedToEndedMs!, 2, accuracy: 0.001)
        XCTAssertEqual(live.changedToEndedMs!, 88, accuracy: 0.001)
        XCTAssertEqual(held.changedCount, 1)
        XCTAssertEqual(live.changedCount, 4)

        // And the commit duration is the SAME in both fixtures (26ms vs
        // 26ms), which is the point: the commit cost cannot explain the
        // difference between these two worlds, so a rig that only
        // measured the commit would call them identical.
        XCTAssertEqual(held.commitMs!, 26, accuracy: 0.001)
        XCTAssertEqual(live.commitMs!, 26, accuracy: 0.001)
    }

    func testGestureKindComesFromDisplacementNotDuration() {
        var log = Spike201GestureLog()
        // A long, stationary press: 300ms, no travel. Classified a tap —
        // duration is deliberately NOT part of the rule, because the thing
        // being measured IS duration and classifying by it would make the
        // result circular.
        log.ingest(phase: .changed, at: 0, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .changed, at: 0.3, locationX: 104, deliveryLagMs: nil)
        log.ingest(phase: .ended, at: 0.31, locationX: 104, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 0.312, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 0.33, locationX: 0, deliveryLagMs: nil)
        XCTAssertTrue(Spike201Metrics.isTap(log.records[0]))

        // A fast flick: 40ms, 120pt of travel. A drag.
        var flick = Spike201GestureLog()
        flick.ingest(phase: .changed, at: 0, locationX: 40, deliveryLagMs: nil)
        flick.ingest(phase: .changed, at: 0.02, locationX: 160, deliveryLagMs: nil)
        flick.ingest(phase: .ended, at: 0.04, locationX: 160, deliveryLagMs: nil)
        XCTAssertFalse(Spike201Metrics.isTap(flick.records[0]))
        XCTAssertEqual(flick.records[0].maxLocationDelta, 120, accuracy: 0.001)
    }

    /// The scrubber also commits from `CalendarEffortQuickControl`'s
    /// scenePhase backgrounding flush, where there is no gesture at all.
    /// That commit must not be attached to the previous gesture, whose
    /// numbers are already final.
    func testCommitOutsideAnyGestureIsIgnored() {
        var log = Spike201GestureLog()
        log.ingest(phase: .commitStart, at: 1, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 1.5, locationX: 0, deliveryLagMs: nil)
        XCTAssertTrue(log.records.isEmpty, "a commit with no gesture open creates nothing")

        feed(heldDeliveryTap(startingAt: 10), into: &log)
        let commitBefore = log.records[0].commitMs
        log.ingest(phase: .commitStart, at: 11, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 11.9, locationX: 0, deliveryLagMs: nil)
        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.records[0].commitMs!, commitBefore!, accuracy: 0.001,
                       "a background flush must not rewrite a finished gesture's commit time")
    }

    func testEndedBeforeAnyChangedIsIgnored() {
        var log = Spike201GestureLog()
        log.ingest(phase: .ended, at: 1, locationX: 100, deliveryLagMs: nil)
        XCTAssertTrue(log.records.isEmpty)
    }

    func testFrameFieldsFillOnceAndOnlyFromLaterTicks() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)   // changed@10, commitEnd@10.030

        log.noteFrame(at: 9.99)   // earlier than the gesture: ignored
        XCTAssertNil(log.records[0].firstFrameAfterFirstChangedMs)

        log.noteFrame(at: 10.008)
        log.noteFrame(at: 10.024)
        XCTAssertEqual(log.records[0].firstFrameAfterFirstChangedMs!, 8, accuracy: 0.001,
                       "only the FIRST later tick counts")
        XCTAssertNil(log.records[0].firstFrameAfterCommitMs, "no tick after commitEnd yet")

        log.noteFrame(at: 10.041)
        log.noteFrame(at: 10.058)
        XCTAssertEqual(log.records[0].firstFrameAfterCommitMs!, 11, accuracy: 0.001)
    }

    func testSignalsAttributeToTheMostRecentGestureIncludingItsSettle() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        log.noteBodyPass()
        log.noteSlotWrite(slot: .calendarEventLogRecords)
        log.noteBodyPass()   // after commitEnd — the settle still belongs to this tap
        feed(heldDeliveryTap(startingAt: 20), into: &log)
        log.noteBodyPass()

        XCTAssertEqual(log.records[0].bodyPasses, 2, "two body passes were fed to this gesture, one of them after its commit")
        XCTAssertEqual(log.records[0].slotWrites, 1)
        XCTAssertEqual(log.records[1].bodyPasses, 1)
        XCTAssertEqual(log.records[1].slotWrites, 0)
    }

    /// Metric values that came out of a subtraction are compared with an
    /// accuracy, never for exact equality: the fixtures' millisecond
    /// values are exact in decimal but not in binary floating point
    /// (45.00000000000082 for a hand-computed 45).
    private func number(_ value: SpikeMetricValue?) -> Double? {
        guard case .number(let raw)? = value else { return nil }
        return raw
    }

    func testSummarySeparatesTapsFromTheirDragControl() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        feed(liveDeliveryTap(startingAt: 20), into: &log)
        feed(slowDrag(startingAt: 30), into: &log)

        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["gestureCount"], .number(3))
        XCTAssertEqual(metrics["tapCount"], .number(2))
        XCTAssertEqual(metrics["dragCount"], .number(1))
        // 2ms and 88ms -> median 45, min 2, max 88.
        XCTAssertEqual(number(metrics["tapChangedToEndedMsMedian"])!, 45, accuracy: 0.001)
        XCTAssertEqual(number(metrics["tapChangedToEndedMsMin"])!, 2, accuracy: 0.001)
        XCTAssertEqual(number(metrics["tapChangedToEndedMsMax"])!, 88, accuracy: 0.001)
        // The control arm is present and separately reported: 310ms.
        XCTAssertEqual(number(metrics["dragChangedToEndedMsMedian"])!, 310, accuracy: 0.001)
        // Sample counts, the second independent witness.
        XCTAssertEqual(metrics["tapChangedSamplesMin"], .number(1))
        XCTAssertEqual(metrics["dragChangedSamplesMedian"], .number(10))
    }

    func testSummaryOmitsMetricsItHasNoSamplesFor() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["dragCount"], .number(0))
        XCTAssertNil(metrics["dragChangedToEndedMsMedian"],
                     "a run with no control drags must not print a control number")
        XCTAssertNil(metrics["tapDeliveryLagMsMedian"],
                     "these fixtures carry no event time, so no lag may be reported")
    }

    func testDeliveryLagRecordsFirstAndMax() {
        var log = Spike201GestureLog()
        log.ingest(phase: .changed, at: 0, locationX: 100, deliveryLagMs: 148)
        log.ingest(phase: .changed, at: 0.01, locationX: 101, deliveryLagMs: 3)
        log.ingest(phase: .changed, at: 0.02, locationX: 101, deliveryLagMs: 210)
        XCTAssertEqual(log.records[0].firstDeliveryLagMs!, 148, accuracy: 0.001)
        XCTAssertEqual(log.records[0].maxDeliveryLagMs!, 210, accuracy: 0.001)
    }

    func testCsvCarriesOneRowPerGestureWithItsKind() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        feed(slowDrag(startingAt: 30), into: &log)

        let lines = Spike201Metrics.csv(log.records).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, "header + one row per gesture")
        XCTAssertEqual(lines[0], Spike201Metrics.csvHeader)
        // index, kind, noOp, changedCount — neither gesture wrote a slot,
        // so both are no-ops in this pure fixture.
        XCTAssertTrue(lines[1].hasPrefix("0,tap,1,1,"), "got: \(lines[1])")
        XCTAssertTrue(lines[2].hasPrefix("1,drag,1,10,"), "got: \(lines[2])")
    }

    func testRegistryCarriesTheScenarioTheRunnerAnswersTo() {
        // A registry id that disagrees with the runner's is "armed but the
        // Start button belongs to nothing" — silent, and it looks exactly
        // like a clean run.
        let definition = SpikeRegistry.definition(for: Spike201SignalID.spikeID)
        XCTAssertNotNil(definition)
        XCTAssertEqual(definition?.kind, .measurement)
        XCTAssertEqual(definition?.issueNumber, 201)
        XCTAssertEqual(definition?.scenarios.map(\.id), [Spike201SignalID.scenarioID])
        XCTAssertEqual(definition?.scenarios.first?.kind, .userAction)
    }

    // MARK: gh#201 round 2 — changedCount is not the tap witness

    /// gh#201 ROUND-2 FIX 4. The device data settles it: a STATIONARY
    /// finger produces exactly ONE `.onChanged` whether SwiftUI delivered
    /// it live or replayed it in a batch at lift, because there is no
    /// second movement sample to deliver. This fixture is device-shaped
    /// (both taps stationary, one `.changed` each) and it FAILS if anyone
    /// re-asserts `changedCount` as a tap discriminator: the two counts
    /// are equal, while the duration and the delivery lag still separate
    /// the two worlds cleanly.
    func testChangedCountIsNotATapWitnessOnDeviceShapedFixtures() {
        var log = Spike201GestureLog()
        // Held: one batched `.changed`, `.ended` ~1ms later, lag ~150ms.
        log.ingest(phase: .changed, at: 10.000, locationX: 100, deliveryLagMs: 150)
        log.ingest(phase: .ended, at: 10.001, locationX: 100, deliveryLagMs: 150)
        log.ingest(phase: .commitStart, at: 10.003, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 10.030, locationX: 0, deliveryLagMs: nil)
        // Live: also one `.changed` (nothing moved), `.ended` 84ms later,
        // lag ~2ms.
        log.ingest(phase: .changed, at: 20.000, locationX: 100, deliveryLagMs: 2)
        log.ingest(phase: .ended, at: 20.084, locationX: 100, deliveryLagMs: 2)
        log.ingest(phase: .commitStart, at: 20.086, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 20.113, locationX: 0, deliveryLagMs: nil)

        let held = log.records[0]
        let live = log.records[1]
        XCTAssertTrue(Spike201Metrics.isTap(held))
        XCTAssertTrue(Spike201Metrics.isTap(live))

        XCTAssertEqual(held.changedCount, live.changedCount, "a stationary finger emits one .onChanged in EITHER world — this cannot discriminate a tap")

        // The two witnesses that do decide.
        XCTAssertEqual(held.changedToEndedMs!, 1, accuracy: 0.001)
        XCTAssertEqual(live.changedToEndedMs!, 84, accuracy: 0.001)
        XCTAssertEqual(held.firstDeliveryLagMs!, 150, accuracy: 0.001)
        XCTAssertEqual(live.firstDeliveryLagMs!, 2, accuracy: 0.001)
    }

    /// `changedCount` is kept because it still discriminates DRAGS: a
    /// live-delivered scrub emits one `.changed` per movement sample, so a
    /// drag that arrived as a single batch would stand out.
    func testChangedCountStillDiscriminatesDrags() {
        var log = Spike201GestureLog()
        feed(slowDrag(startingAt: 5), into: &log)
        XCTAssertEqual(log.records[0].changedCount, 10)
        XCTAssertFalse(Spike201Metrics.isTap(log.records[0]))
    }

    // MARK: gh#201 round 2 — where the storm lands

    /// The direct evidence round 1 could not produce. Three counters,
    /// three ids, no merging: the detail page's own body, the calendar
    /// page's body, and the calendar day-layer bridge updates. Merging any
    /// two would destroy the only question round 2 exists to answer.
    func testCalendarBodyPassesAreCountedSeparatelyFromTheDetailPage() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)

        log.noteBodyPass(signalID: Spike195SignalID.parentBody)
        log.noteBodyPass(signalID: Spike201SignalID.calendarPageBody)
        log.noteBodyPass(signalID: Spike201SignalID.calendarPageBody)
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerUpdate)
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerUpdate)
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerUpdate)

        let record = log.records[0]
        XCTAssertEqual(record.bodyPasses, 1)
        XCTAssertEqual(record.calendarPageBodyPasses, 2)
        XCTAssertEqual(record.calendarDayLayerPasses, 3)
    }

    /// The three ids must be distinct strings, or the routing above
    /// collapses silently into one counter and every number still looks
    /// plausible.
    func testTheThreeBodyPassIDsAreDistinct() {
        let ids = [
            Spike195SignalID.parentBody,
            Spike201SignalID.calendarPageBody,
            Spike201SignalID.calendarDayLayerUpdate,
        ]
        XCTAssertEqual(Set(ids).count, 3)
    }

    /// An id nobody claims is ignored, not attributed to the nearest
    /// counter: the coordinator fans EVERY armed run's signals to EVERY
    /// listener, so a co-armed #195 run's leaf id legitimately arrives
    /// here.
    func testAnUnclaimedBodyPassIDIncrementsNothing() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        log.noteBodyPass(signalID: Spike195SignalID.reflectionNoteLeaf)
        log.noteBodyPass(signalID: "not-a-signal")

        let record = log.records[0]
        XCTAssertEqual(record.bodyPasses, 0)
        XCTAssertEqual(record.calendarPageBodyPasses, 0)
        XCTAssertEqual(record.calendarDayLayerPasses, 0)
    }

    /// MUT-A. Round 2's fixture used counts of 1, 2, 1, 2 — a collision
    /// that let TWO independent column transpositions hide at once, and a
    /// rotation of three CSV columns duly survived. Every count here is
    /// distinct, so any permutation of the columns moves at least one
    /// assertion. Every column in the header is pinned, not a subset.
    func testCsvCarriesEveryCounterColumnInItsHeaderPosition() throws {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        log.noteBodyPass(signalID: Spike195SignalID.parentBody)                              // 1
        for _ in 0..<2 { log.noteBodyPass(signalID: Spike201SignalID.calendarPageBody) }      // 2
        for _ in 0..<3 { log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerUpdate) }  // 3
        for _ in 0..<4 { log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerApplied) } // 4
        for _ in 0..<5 { log.noteSlotWrite(slot: .calendarEventLogRecords) }                  // 5
        for _ in 0..<6 { log.noteSlotWrite(slot: .calendarEvents) }                           // 6, total 11

        let lines = Spike201Metrics.csv(log.records).components(separatedBy: "\n")
        let header = lines[0].components(separatedBy: ",")
        let row = lines[1].components(separatedBy: ",")
        XCTAssertEqual(header.count, row.count, "every header column has exactly one value")

        func value(_ column: String) throws -> String {
            row[try XCTUnwrap(header.firstIndex(of: column))]
        }
        XCTAssertEqual(try value("bodyPasses"), "1")
        XCTAssertEqual(try value("pageBody"), "2")
        XCTAssertEqual(try value("dayLayer"), "3")
        XCTAssertEqual(try value("dayLayerApplied"), "4")
        XCTAssertEqual(try value("slotLogs"), "5")
        XCTAssertEqual(try value("slotEvents"), "6")
        XCTAssertEqual(try value("slotWrites"), "11")
        XCTAssertEqual(try value("i"), "0")
        XCTAssertEqual(try value("kind"), "tap")
        XCTAssertEqual(try value("noOp"), "0", "eleven slot writes is not a no-op tap")
    }

    /// The numeric columns, given six DISTINCT hand-computed values so no
    /// transposition among them can be invisible either.
    func testCsvCarriesEveryTimingColumnInItsHeaderPosition() throws {
        var log = Spike201GestureLog()
        // changed@10 (lag 7.5 admitted, raw 7.5), changed@10.05 (lag 9.5),
        // ended@10.09, commitStart@10.13, commitEnd@10.21.
        log.ingest(phase: .changed, at: 10.0, locationX: 100, deliveryLagMs: 7.5, rawDeliveryLagMs: 7.5)
        log.ingest(phase: .changed, at: 10.05, locationX: 103, deliveryLagMs: 9.5, rawDeliveryLagMs: 9.5)
        log.ingest(phase: .ended, at: 10.09, locationX: 103, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 10.13, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 10.21, locationX: 0, deliveryLagMs: nil)
        log.noteFrame(at: 10.02)   // 20ms after first changed
        log.noteFrame(at: 10.25)   // 40ms after commit end

        let lines = Spike201Metrics.csv(log.records).components(separatedBy: "\n")
        let header = lines[0].components(separatedBy: ",")
        let row = lines[1].components(separatedBy: ",")
        func value(_ column: String) throws -> String {
            row[try XCTUnwrap(header.firstIndex(of: column))]
        }
        XCTAssertEqual(try value("changed"), "2")
        XCTAssertEqual(try value("dxMax"), "3.0")
        XCTAssertEqual(try value("lagMs"), "7.5")
        XCTAssertEqual(try value("lagMaxMs"), "9.5")
        XCTAssertEqual(try value("chToEndMs"), "90.0")
        XCTAssertEqual(try value("endToCommitMs"), "40.0")
        XCTAssertEqual(try value("commitMs"), "80.0")
        XCTAssertEqual(try value("frameAfterChangedMs"), "20.0")
        XCTAssertEqual(try value("frameAfterCommitMs"), "40.0")
    }

    /// gh#201 round 3 / R10: the RAW reading is always written, including
    /// when the plausibility filter refused to admit it — round 1's
    /// verdict came from the min-normalised relative lag, which is immune
    /// to any constant epoch offset.
    func testTheRawDeliveryLagIsWrittenEvenWhenTheFilterRejectedIt() throws {
        var log = Spike201GestureLog()
        // What the runner does with an absurd reading: `admit` returns nil,
        // the raw number is carried through anyway.
        log.ingest(phase: .changed, at: 10.0, locationX: 100, deliveryLagMs: nil, rawDeliveryLagMs: 8.097e11)
        log.ingest(phase: .ended, at: 10.09, locationX: 100, deliveryLagMs: nil)

        let lines = Spike201Metrics.csv(log.records).components(separatedBy: "\n")
        let header = lines[0].components(separatedBy: ",")
        let row = lines[1].components(separatedBy: ",")
        let lagIndex = try XCTUnwrap(header.firstIndex(of: "lagMs"))
        let rawIndex = try XCTUnwrap(header.firstIndex(of: "rawLagMs"))
        XCTAssertEqual(row[lagIndex], "", "the filter refused it")
        XCTAssertEqual(row[rawIndex], "809700000000.0", "and the file kept it anyway")
    }

    func testSummaryReportsTheCalendarPassesSeparatelyFromTheDetailOnes() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        log.noteBodyPass(signalID: Spike195SignalID.parentBody)
        log.noteBodyPass(signalID: Spike201SignalID.calendarPageBody)
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerUpdate)
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerUpdate)
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerApplied)

        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["tapBodyPassesMedian"], .number(1))
        XCTAssertEqual(metrics["tapCalendarPageBodyPassesMedian"], .number(1))
        XCTAssertEqual(metrics["tapCalendarDayLayerPassesMedian"], .number(2))
        XCTAssertEqual(metrics["tapCalendarDayLayerAppliedPassesMedian"], .number(1))
    }

    /// gh#201 round 3 / R3. The two day-layer ids must land in DIFFERENT
    /// counters: the whole question is whether the columns SwiftUI asked
    /// to re-apply actually did any work, and one counter cannot answer
    /// it. Swapping them at the router makes both assertions fail.
    func testTheAskedAndAppliedDayLayerIDsAreCountedSeparately() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        for _ in 0..<15 { log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerUpdate) }
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerApplied)

        XCTAssertNotEqual(Spike201SignalID.calendarDayLayerUpdate, Spike201SignalID.calendarDayLayerApplied)
        XCTAssertEqual(log.records[0].calendarDayLayerPasses, 15, "fifteen columns were offered a model")
        XCTAssertEqual(log.records[0].calendarDayLayerAppliedPasses, 1, "one of them actually re-laid-out")
    }

    /// gh#201 round 3 / R7. `slotWrites` alone was the variant's whole
    /// cross-check ("it drops 2 → 1"), and one unrelated background commit
    /// inflates it back to 2 — a working variant reads as inert. The
    /// per-slot counts cannot be spoofed that way.
    func testAnUnrelatedSlotCommitCannotSpoofTheVariantCrossCheck() {
        var log = Spike201GestureLog()
        // The `no-colordepth-mirror` world: the log record is saved, the
        // calendar-events mirror is not — but a background reminders
        // commit lands inside the same attribution window.
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        log.noteSlotWrite(slot: .calendarEventLogRecords)
        log.noteSlotWrite(slot: .reminders)

        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["tapSlotWritesMax"], .number(2), "the old cross-check now reads like stock")
        XCTAssertEqual(metrics["tapCalendarEventSlotWritesMax"], .number(0), "and the real one still reads the variant")
        XCTAssertEqual(metrics["tapLogRecordSlotWritesMin"], .number(1))
    }

    /// The variant's built-in cross-check: `slotWrites` per tap must drop
    /// 2 → 1 when the colorDepth/density mirror is skipped, and the MIN is
    /// reported so a single tap that still wrote twice cannot hide behind
    /// a median.
    func testTapSlotWritesReportsItsMinimumSoAPartialVariantCannotHide() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        log.noteSlotWrite(slot: .calendarEventLogRecords)
        feed(heldDeliveryTap(startingAt: 20), into: &log)
        log.noteSlotWrite(slot: .calendarEventLogRecords)
        log.noteSlotWrite(slot: .calendarEvents)

        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["tapSlotWritesMin"], .number(1))
        XCTAssertEqual(metrics["tapSlotWritesMax"], .number(2))
        XCTAssertEqual(metrics["tapCalendarEventSlotWritesMin"], .number(0))
        XCTAssertEqual(metrics["tapCalendarEventSlotWritesMax"], .number(1))
    }

    /// gh#201 round 3 / R2, and the exact device loss it repairs. Round 2
    /// filled only `records.indices.last`, so tap 1's frame columns were
    /// frozen at nil the instant tap 2 began. The loss is biased toward
    /// the LONGEST stalls, so a candidate that shortened the storm could
    /// have read as a regression.
    func testAFrameTickBackfillsAnEarlierGesturesFrameColumns() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)   // commitEnd @ 10.030
        // The next gesture starts BEFORE any tick lands after tap 0's
        // commit — the device shape when the storm outlasts the pause.
        feed(heldDeliveryTap(startingAt: 10.05), into: &log)
        XCTAssertNil(log.records[0].firstFrameAfterCommitMs)

        log.noteFrame(at: 10.1)

        XCTAssertEqual(log.records[0].firstFrameAfterCommitMs!, 70, accuracy: 0.001,
                       "the earlier record is still fillable; round 2 dropped it forever")
        XCTAssertEqual(log.records[0].firstFrameAfterFirstChangedMs!, 100, accuracy: 0.001)
        XCTAssertEqual(log.records[1].firstFrameAfterCommitMs!, 20, accuracy: 0.001)
    }

    /// And what stays lost is COUNTED, so the loss can never be invisible.
    func testTapsWhoseFrameColumnsStayedNilAreCounted() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        feed(heldDeliveryTap(startingAt: 20), into: &log)
        log.noteFrame(at: 20.5)   // fills both records' fields
        feed(heldDeliveryTap(startingAt: 30), into: &log)   // never sees a tick

        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["tapsMissingFrameAfterChangedCount"], .number(1))
        XCTAssertEqual(metrics["tapsMissingFrameAfterCommitCount"], .number(1))
    }

    /// gh#201 round 3 / R9. Taps 0 and 2 of the device run wrote nothing
    /// (`slotWrites = 0`) and their 16.4ms / 4.5ms commits sat inside a
    /// reported median of 78.7ms. The commit aggregates now have two arms,
    /// and the no-op count is on the line whether or not it is zero.
    func testNoOpTapsAreCountedAndKeptOutOfTheWritingCommitAggregate() {
        var log = Spike201GestureLog()
        // Two real writing taps at 80ms, one no-op at 4ms.
        log.ingest(phase: .changed, at: 10.0, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .ended, at: 10.09, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 10.10, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 10.18, locationX: 0, deliveryLagMs: nil)
        log.noteSlotWrite(slot: .calendarEventLogRecords)

        log.ingest(phase: .changed, at: 20.0, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .ended, at: 20.09, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 20.10, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 20.18, locationX: 0, deliveryLagMs: nil)
        log.noteSlotWrite(slot: .calendarEventLogRecords)

        log.ingest(phase: .changed, at: 30.0, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .ended, at: 30.09, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 30.10, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 30.104, locationX: 0, deliveryLagMs: nil)

        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["tapsWithZeroSlotWritesCount"], .number(1))
        guard case .number(let writing)? = metrics["tapWritingCommitMsMedian"],
              case .number(let noOp)? = metrics["tapNoOpCommitMsMedian"] else {
            return XCTFail("both commit arms must be reported")
        }
        XCTAssertEqual(writing, 80.0, accuracy: 0.001)
        XCTAssertEqual(noOp, 4.0, accuracy: 0.001)
        XCTAssertNil(metrics["tapCommitMsMedian"], "the mixed-population key is retired, not reinterpreted")

        // And the no-op tap is STILL in the CSV: the round-2 run's tap 0
        // (no write, no storm) is its best internal control.
        let rows = Spike201Metrics.csv(log.records).components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 4, "header + three gestures, no-op included")
        XCTAssertTrue(rows[3].contains(",tap,1,"), "row 2 is a tap, marked noOp")
    }

    /// A CANCELLED tap has no `.onEnded` at all — the scrubber commits
    /// from the `@GestureState` reset, and cancellation is routine inside
    /// the reflection `ScrollView`. Such a tap vanishes from
    /// `tapChangedToEndedMs*`, so its absence has to be a number.
    func testTapsThatNeverEndedAreCounted() {
        var log = Spike201GestureLog()
        feed(heldDeliveryTap(startingAt: 10), into: &log)
        log.ingest(phase: .changed, at: 20.0, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 20.10, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 20.18, locationX: 0, deliveryLagMs: nil)

        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["tapCount"], .number(2))
        XCTAssertEqual(metrics["tapsWithoutEndedCount"], .number(1))
    }

    /// gh#201 round 3 / R8. Run totals are counted from ARM, so a signal
    /// that fired while no gesture was open still proves the wire is live.
    func testRunTotalsCountSignalsThatNoGestureClaimed() {
        var log = Spike201GestureLog()
        // Before any gesture: navigating into the detail page alone drives
        // the calendar page body, and the scenario's calendar scroll drives
        // the day layer.
        log.noteBodyPass(signalID: Spike201SignalID.calendarPageBody)
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerUpdate)
        log.noteBodyPass(signalID: Spike201SignalID.calendarDayLayerApplied)
        XCTAssertTrue(log.records.isEmpty, "no gesture claimed any of them")

        feed(heldDeliveryTap(startingAt: 10), into: &log)
        log.noteBodyPass(signalID: Spike201SignalID.calendarPageBody)
        log.noteSlotWrite(slot: .calendarEvents)

        let totals = Spike201Metrics.runTotals(log)
        XCTAssertEqual(totals["runCalendarPageBodyTotal"], .number(2))
        XCTAssertEqual(totals["runCalendarDayLayerTotal"], .number(1))
        XCTAssertEqual(totals["runCalendarDayLayerAppliedTotal"], .number(1))
        XCTAssertEqual(totals["runSlotWriteTotal"], .number(1))
        // The per-gesture number is 1, the run number is 2: a zero in the
        // first with a non-zero in the second is a finding, not a dead wire.
        XCTAssertEqual(log.records[0].calendarPageBodyPasses, 1)
    }

    /// Every run total is emitted, ZERO included — a missing key and a
    /// dead instrument would otherwise read the same.
    func testRunTotalsAreEmittedEvenWhenNothingEverFired() {
        let totals = Spike201Metrics.runTotals(Spike201GestureLog())
        XCTAssertEqual(totals["runCalendarPageBodyTotal"], .number(0))
        XCTAssertEqual(totals["runCalendarDayLayerTotal"], .number(0))
        XCTAssertEqual(totals["runCalendarDayLayerAppliedTotal"], .number(0))
        XCTAssertEqual(totals["runDetailBodyTotal"], .number(0))
        XCTAssertEqual(totals["runSlotWriteTotal"], .number(0))
    }

    /// R10/R11: the minimum of BOTH delivery-lag arms, and the max-lag
    /// column round 2 computed and reported nowhere.
    func testDeliveryLagAggregatesReportTheirMinimumAndTheirPerGestureMax() {
        var log = Spike201GestureLog()
        // A gesture stays TIMING-OPEN until its `commitEnd`, so each of
        // these needs its own commit bracket or the second one merges into
        // the first.
        log.ingest(phase: .changed, at: 10.0, locationX: 100, deliveryLagMs: 33.7, rawDeliveryLagMs: 33.7)
        log.ingest(phase: .changed, at: 10.02, locationX: 101, deliveryLagMs: 41.0, rawDeliveryLagMs: 41.0)
        log.ingest(phase: .ended, at: 10.09, locationX: 101, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 10.10, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 10.18, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .changed, at: 20.0, locationX: 100, deliveryLagMs: 16.7, rawDeliveryLagMs: 16.7)
        log.ingest(phase: .ended, at: 20.09, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 20.10, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 20.18, locationX: 0, deliveryLagMs: nil)

        let metrics = Spike201Metrics.summarize(log.records)
        XCTAssertEqual(metrics["tapCount"], .number(2))
        XCTAssertEqual(metrics["tapDeliveryLagMsMin"], .number(16.7))
        XCTAssertEqual(metrics["tapDeliveryLagMsMax"], .number(33.7))
        XCTAssertEqual(metrics["tapMaxDeliveryLagMsMax"], .number(41.0), "round 2 stored this and printed it nowhere")
        XCTAssertEqual(metrics["tapRawDeliveryLagMsMin"], .number(16.7))
    }

    /// R10: the epoch triple, so the question "which clock is
    /// DragGesture.Value.time on" is settled by measurement rather than by
    /// the reasoning in a comment.
    func testTheEpochStampCarriesAllThreeClocks() {
        let stamp = Spike201EpochStamp(
            mediaTime: 51_234.5,
            systemUptime: 51_234.5,
            dateSinceReferenceDate: 809_712_345.0
        )
        XCTAssertEqual(stamp.metrics["epochMediaTime"], .number(51_234.5))
        XCTAssertEqual(stamp.metrics["epochSystemUptime"], .number(51_234.5))
        XCTAssertEqual(stamp.metrics["epochDateSinceReferenceDate"], .number(809_712_345.0))
    }
}

// MARK: - SpikeFrameProbeResult (the frame metric keys both runners emit)

final class SpikeFrameProbeResultMetricsTests: XCTestCase {
    private func drain(
        truncated: Bool = false,
        suspensions: [Double] = [],
        stalls: [Double] = [],
        largest: [Double] = [],
        overshoot: SpikeFrameOvershootTally = SpikeFrameOvershootTally(),
        resigns: Int = 0,
        becameActive: Int = 0
    ) -> SpikeFrameTickDrain {
        SpikeFrameTickDrain(
            samples: [],
            isTruncated: truncated,
            suspensionGapCount: suspensions.count,
            suspensionGapsMs: suspensions,
            activeStallsMs: stalls,
            largestDeltasMs: largest,
            overshoot: overshoot,
            resignActiveCount: resigns,
            didBecomeActiveCount: becameActive
        )
    }

    private func result(
        stats: SpikeFrameStats?,
        truncated: Bool = false,
        fps: Int = 60,
        suspensions: [Double] = [],
        stalls: [Double] = [],
        largest: [Double] = [],
        overshoot: SpikeFrameOvershootTally = SpikeFrameOvershootTally(),
        resigns: Int = 0,
        becameActive: Int = 0
    ) -> SpikeFrameProbeResult {
        SpikeFrameProbeResult(
            stats: stats,
            truncated: truncated,
            maximumFramesPerSecond: fps,
            drain: drain(
                truncated: truncated,
                suspensions: suspensions,
                stalls: stalls,
                largest: largest,
                overshoot: overshoot,
                resigns: resigns,
                becameActive: becameActive
            )
        )
    }

    /// The rename rule, as an assertion rather than a promise: every key
    /// whose MEANING has changed across rounds must be gone, or a line
    /// from one round can be read against a line from another as if the
    /// two held the same quantity.
    ///
    /// * `over16msCount` (round 1) counted healthy 60Hz frames.
    /// * `frameGapsDropped` (round 1) conflated suspensions with stalls.
    /// * `over33msCount` (rounds 1–2) counted a literal that names nothing
    ///   on a variable-refresh display.
    /// * `frameLateThresholdMs` / `overRefreshThresholdCount` (round 2)
    ///   counted against the DISPLAY's advertised maximum and saturated.
    /// * `frameSampleCount` / `p50FrameMs` / `p95FrameMs` / `p99FrameMs` /
    ///   `maxFrameMs` changed POPULATION in round 2, which began admitting
    ///   the active stalls round 1 discarded — round 1's max of 941.1 and
    ///   round 2's of 1159.8 are partly that reclassification. Round 2
    ///   applied its own rename rule to two keys and not to these five.
    func testTheRetiredKeysAreNeverEmittedAgain() throws {
        let stats = try XCTUnwrap(SpikeFrameStatistics.summarize(durationsMs: [16.7, 40.0, 1_200.0]))
        let metrics = result(
            stats: stats,
            truncated: true,
            suspensions: [3_000, 4_000],
            stalls: [1_200],
            largest: [1_200, 40.0, 16.7],
            resigns: 1,
            becameActive: 1
        ).metrics

        for retired in [
            "over16msCount", "frameGapsDropped", "over33msCount",
            "frameLateThresholdMs", "overRefreshThresholdCount",
            "frameSampleCount", "p50FrameMs", "p95FrameMs", "p99FrameMs", "maxFrameMs",
        ] {
            XCTAssertNil(metrics[retired], "\(retired) changed meaning and must never be emitted again")
        }
    }

    /// The distribution keys, their observed-cadence threshold, and the
    /// display context all travel together. A late count without the
    /// threshold it counted against is unreadable, and a threshold without
    /// the achieved cadence hides a saturated metric.
    func testTheReplacementKeysCarryTheObservedThresholdAndTheDisplayContext() throws {
        // p50 of [16.7, 40, 1200] is 40 -> threshold 60 -> only 1200 is late.
        let stats = try XCTUnwrap(SpikeFrameStatistics.summarize(durationsMs: [16.7, 40.0, 1_200.0]))
        let metrics = result(stats: stats, fps: 120, stalls: [1_200]).metrics

        XCTAssertEqual(metrics["displayMaxFPS"], .number(120))
        XCTAssertEqual(metrics["displayNominalFrameMs"], .number(1_000.0 / 120.0))
        XCTAssertEqual(metrics["frameDeltaCount"], .number(3))
        XCTAssertEqual(metrics["p50FrameDeltaMs"], .number(40))
        XCTAssertEqual(metrics["maxFrameDeltaMs"], .number(1_200))
        XCTAssertEqual(metrics["frameLateThresholdObservedMs"], .number(60))
        XCTAssertEqual(metrics["overObservedCadenceCount"], .number(1), "only 1200 exceeds 1.5 x 40")
        XCTAssertEqual(metrics["frameAchievedFPS"], .number(25), "1000/40 — not the 120 the panel advertises")
    }

    /// gh#201 round 3 / R13. "Absence of markers means the distribution is
    /// complete" was false — absence is also the normal outcome of a real
    /// backgrounding, which re-baselines the timebase and computes no
    /// delta at all. Every integrity COUNT is now present on a clean run,
    /// carrying a zero.
    func testEveryIntegrityCountIsPresentOnACleanRunCarryingAZero() throws {
        let stats = try XCTUnwrap(SpikeFrameStatistics.summarize(durationsMs: [16.7, 16.7]))
        let metrics = result(stats: stats).metrics

        XCTAssertEqual(metrics["frameSamplesTruncated"], .bool(false))
        XCTAssertEqual(metrics["frameSuspensionGapCount"], .number(0))
        XCTAssertEqual(metrics["frameActiveStallCount"], .number(0))
        XCTAssertEqual(metrics["frameResignActiveCount"], .number(0))
        XCTAssertEqual(metrics["frameDidBecomeActiveCount"], .number(0))
        XCTAssertEqual(metrics["frameOvershootSampleCount"], .number(0))
        XCTAssertEqual(metrics["frameOvershootLateCount"], .number(0))
        // The LISTS stay conditional: the counts above already separate
        // "none happened" from "nobody looked".
        XCTAssertNil(metrics["frameSuspensionGapsMs"])
        XCTAssertNil(metrics["frameActiveStallsMs"])
        XCTAssertEqual(metrics["displayMaxFPS"], .number(60))
    }

    func testTheLifecycleEdgeCountsReachTheMetrics() {
        let metrics = result(stats: nil, resigns: 3, becameActive: 2).metrics
        XCTAssertEqual(metrics["frameResignActiveCount"], .number(3))
        XCTAssertEqual(metrics["frameDidBecomeActiveCount"], .number(2))
    }

    /// The DURATIONS, not just the counts. A count alone cannot tell a
    /// 1.2s main-thread stall from a 40s app-switch.
    func testGapDurationsReachTheMetricsAsDurations() {
        let metrics = result(
            stats: nil,
            suspensions: [3_000, 40_000],
            stalls: [1_261.4, 1_004.0],
            largest: [40_000, 3_000, 1_261.4]
        ).metrics

        XCTAssertEqual(metrics["frameSuspensionGapCount"], .number(2))
        XCTAssertEqual(metrics["frameSuspensionGapsMs"], .string("3000.0 40000.0"))
        XCTAssertEqual(metrics["frameActiveStallCount"], .number(2))
        XCTAssertEqual(metrics["frameActiveStallsMs"], .string("1261.4 1004.0"))
        XCTAssertEqual(metrics["frameLargestDeltasMs"], .string("40000.0 3000.0 1261.4"))
    }

    /// The overshoot arm, including its own tolerance, so a later reader
    /// never has to guess what "late" meant on this line.
    func testTheOvershootArmCarriesItsToleranceWithIt() {
        var tally = SpikeFrameOvershootTally()
        tally.admit(0.2)
        tally.admit(9.5)
        let metrics = result(stats: nil, overshoot: tally).metrics
        XCTAssertEqual(metrics["frameOvershootSampleCount"], .number(2))
        XCTAssertEqual(metrics["frameOvershootLateCount"], .number(1))
        XCTAssertEqual(metrics["frameOvershootMaxMs"], .number(9.5))
        XCTAssertEqual(metrics["frameOvershootToleranceMs"], .number(SpikeFrameOvershootTally.toleranceMs))
    }

    /// A run whose probe collected nothing still reports the display and
    /// every integrity count, and invents no distribution.
    func testAnEmptyDistributionStillNamesTheDisplayAndInventsNoNumbers() {
        let metrics = result(stats: nil).metrics
        XCTAssertNil(metrics["frameDeltaCount"])
        XCTAssertNil(metrics["p50FrameDeltaMs"])
        XCTAssertNil(metrics["frameLateThresholdObservedMs"])
        XCTAssertEqual(metrics["displayMaxFPS"], .number(60))
        XCTAssertEqual(metrics["frameSuspensionGapCount"], .number(0))
    }
}

// MARK: - SpikeFrameProbe (the physical tick source)

/// gh#201 round 3. The probe's own wiring — the two notification
/// observers, and the path from a tick to the ingestor — was previously
/// declared untestable and left uncovered; MUT-I lived in exactly that
/// gap. The CADisplayLink's CADENCE still is untestable, but everything
/// the probe does with a tick is not.
@MainActor
final class SpikeFrameProbeTests: XCTestCase {
    func testTheResignNotificationReachesTheIngestorsLifecycleFact() {
        let probe = SpikeFrameProbe()
        probe.start()
        defer { _ = probe.stopAndSummarize() }

        XCTAssertFalse(probe.tickIngestor.hasResignedActive)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(probe.tickIngestor.hasResignedActive, "the observer must be wired to noteWillResignActive")
        XCTAssertEqual(probe.tickIngestor.resignActiveCount, 1)

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(probe.tickIngestor.hasResignedActive)
        XCTAssertEqual(probe.tickIngestor.didBecomeActiveCount, 1)
    }

    /// The end-to-end classification through the REAL probe: a gap across
    /// a real notification is a suspension, and the identical gap without
    /// one is a stall that reaches the distribution.
    func testAGapAcrossARealNotificationIsClassifiedAsASuspensionByTheProbe() {
        let suspended = SpikeFrameProbe()
        suspended.start()
        suspended.ingestTick(timestamp: 10.0, targetTimestamp: 10.0167)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        suspended.ingestTick(timestamp: 20.0, targetTimestamp: 20.0167)
        suspended.ingestTick(timestamp: 30.0, targetTimestamp: 30.0167)
        let suspendedResult = suspended.stopAndSummarize()
        XCTAssertEqual(suspendedResult.drain.suspensionGapCount, 1)
        XCTAssertTrue(suspendedResult.drain.activeStallsMs.isEmpty)
        XCTAssertEqual(suspendedResult.drain.resignActiveCount, 1)

        let awake = SpikeFrameProbe()
        awake.start()
        awake.ingestTick(timestamp: 20.0, targetTimestamp: 20.0167)
        awake.ingestTick(timestamp: 30.0, targetTimestamp: 30.0167)
        let awakeResult = awake.stopAndSummarize()
        XCTAssertEqual(awakeResult.drain.suspensionGapCount, 0)
        XCTAssertEqual(awakeResult.drain.activeStallsMs, [10_000.0])
        XCTAssertEqual(awakeResult.drain.resignActiveCount, 0)
    }

    /// `onTick` still carries the link's own timestamp — the gh#201
    /// gesture log's only frame-boundary source.
    func testOnTickForwardsTheTickTimestamp() {
        let probe = SpikeFrameProbe()
        var seen: [CFTimeInterval] = []
        probe.onTick = { seen.append($0) }
        probe.start()
        probe.ingestTick(timestamp: 5.0, targetTimestamp: 5.0167)
        probe.ingestTick(timestamp: 5.0167, targetTimestamp: 5.0334)
        _ = probe.stopAndSummarize()
        XCTAssertEqual(seen, [5.0, 5.0167])
    }

    /// A second stop returns nothing, by construction rather than by
    /// convention — the drain reset lives in the ingestor now.
    func testASecondStopReportsNothing() {
        let probe = SpikeFrameProbe()
        probe.start()
        probe.ingestTick(timestamp: 1.0, targetTimestamp: 1.0167)
        probe.ingestTick(timestamp: 1.02, targetTimestamp: 1.0367)
        XCTAssertNotNil(probe.stopAndSummarize().stats)
        XCTAssertNil(probe.stopAndSummarize().stats)
    }

    /// The gap-candidate bound moved clear of the phenomenon (R12): the
    /// smallest stall the device produced was 768ms and the bound was
    /// 1000ms, so it sat inside the distribution it was classifying.
    func testTheGapCandidateBoundSitsBelowEveryStallTheDeviceProduced() {
        XCTAssertLessThan(
            SpikeFrameProbe.gapCandidateFrameDeltaMs, 768.0,
            "the round-2 device run's SHORTEST stall; a bound above it re-buckets the phenomenon"
        )
        XCTAssertGreaterThan(
            SpikeFrameProbe.gapCandidateFrameDeltaMs, 1_000.0 / 30.0,
            "and it must stay well above any frame time, at any refresh rate"
        )
    }
}

// MARK: - Spike201Runner (the runner itself, which no test had ever built)

/// The tests that kill MUT-C.
///
/// Replacing `CACurrentMediaTime()` with `Date().timeIntervalSinceReferenceDate`
/// in `Spike201Runner.handle` — round 1's exact bug, the one that reported
/// every touch as ~25.7 years old — survived 40 tests, because
/// `grep -rn "Spike201Runner" DoneTests/` returned nothing: the runner was
/// never instantiated by any test at all.
@MainActor
final class Spike201RunnerTests: XCTestCase {
    private var storageLocation: SpikeRunStorageLocation!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var eventLocation: EventStorageLocation!
    /// RETAINED for the test's whole lifetime. The coordinator OWNS the
    /// runner and the runner holds it weakly, so dropping it here would
    /// leave `SpikeProbe.onSignal` attached to a dead coordinator — which
    /// is exactly the gh#197 v1 blocker this whole ownership model exists
    /// to prevent, and it would silently poison every later test.
    private var coordinator: SpikeSessionCoordinator!
    private var store: EventStore!

    override func setUp() {
        super.setUp()
        storageLocation = .ephemeral(id: UUID())
        suiteName = "Spike201RunnerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        eventLocation = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            coordinator?.stopAll()
            SpikeProbe.onSignal = nil
        }
        try? FileManager.default.removeItem(at: storageLocation.directory)
        TestStorage.tearDown(suiteName)
        coordinator = nil
        store = nil
        storageLocation = nil
        defaults = nil
        suiteName = nil
        eventLocation = nil
        super.tearDown()
    }

    @discardableResult
    private func armedRunner() -> Spike201Runner {
        coordinator = SpikeSessionCoordinator()
        store = EventStore(defaults: defaults, storage: eventLocation, seedsSampleDataIfEmpty: false)
        let runner = coordinator.runner201
        runner.storageLocation = storageLocation
        runner.start(store: store)
        return runner
    }

    /// A touch stamped the way SwiftUI actually stamps `DragGesture.Value.time`:
    /// `Date(timeIntervalSinceReferenceDate: <uptime>)`. Read in the media
    /// timebase this is a lag of a few milliseconds; differenced against a
    /// wall clock it is about 25.7 years.
    private func swiftUIShapedTouchTime(offsetSeconds: Double = 0) -> Date {
        Date(timeIntervalSinceReferenceDate: CACurrentMediaTime() - offsetSeconds)
    }

    /// MUT-C. The runner must read the touch stamp in the MEDIA timebase.
    /// With `Date()` substituted the lag comes out ~8.1e11 ms, the tracker
    /// quarantines it, and all three assertions below fail at once.
    func testTheRunnerReadsTheTouchStampInTheMediaTimebase() throws {
        let runner = armedRunner()
        SpikeProbe.emit(.gesture(
            Spike201SignalID.effortScrubber, .changed,
            eventTime: swiftUIShapedTouchTime(offsetSeconds: 0.030),
            locationX: 100
        ))
        SpikeProbe.emit(.gesture(
            Spike201SignalID.effortScrubber, .ended,
            eventTime: swiftUIShapedTouchTime(), locationX: 100
        ))
        runner.cancel()

        let metrics = try XCTUnwrap(runner.lastCompletedRun?.metrics)
        XCTAssertEqual(metrics["implausibleLagCount"], .number(0),
                       "a media-timebase read of a media-timebase stamp is plausible")
        XCTAssertNil(metrics["implausibleLagFirstMs"])
        guard case .number(let lagMax)? = metrics["tapDeliveryLagMsMax"] else {
            return XCTFail("the delivery lag must reach the aggregates at all")
        }
        // 30ms of simulated hold, plus whatever the two calls cost.
        XCTAssertGreaterThan(lagMax, 25.0)
        XCTAssertLessThan(lagMax, 500.0, "and nowhere near the 8.097e11 round 1 reported")
    }

    /// The same run, from the other side: the RAW column carries the
    /// uncorrected number, so a future epoch change is diagnosable from
    /// the file rather than from a rebuild (R10).
    func testTheRunnerAlsoWritesTheRawUncorrectedLag() throws {
        let runner = armedRunner()
        SpikeProbe.emit(.gesture(
            Spike201SignalID.effortScrubber, .changed,
            eventTime: swiftUIShapedTouchTime(offsetSeconds: 0.010), locationX: 100
        ))
        runner.cancel()

        let metrics = try XCTUnwrap(runner.lastCompletedRun?.metrics)
        guard case .string(let csv)? = metrics["gestures"] else { return XCTFail("no CSV") }
        let header = csv.components(separatedBy: "\n")[0].components(separatedBy: ",")
        let row = csv.components(separatedBy: "\n")[1].components(separatedBy: ",")
        let rawIndex = try XCTUnwrap(header.firstIndex(of: "rawLagMs"))
        XCTAssertFalse(row[rawIndex].isEmpty, "the raw column is written on every gesture")
        XCTAssertNotNil(metrics["tapRawDeliveryLagMsMin"])
    }

    /// R10: the epoch triple, stamped once per run, on the line.
    func testTheRunStampsAllThreeClocksOnce() throws {
        let runner = armedRunner()
        SpikeProbe.emit(.gesture(
            Spike201SignalID.effortScrubber, .changed,
            eventTime: swiftUIShapedTouchTime(), locationX: 100
        ))
        runner.cancel()

        let metrics = try XCTUnwrap(runner.lastCompletedRun?.metrics)
        guard case .number(let media)? = metrics["epochMediaTime"],
              case .number(let uptime)? = metrics["epochSystemUptime"],
              case .number(let wall)? = metrics["epochDateSinceReferenceDate"] else {
            return XCTFail("all three clocks must be recorded")
        }
        XCTAssertEqual(media, uptime, accuracy: 1.0, "media time and system uptime share a timebase")
        XCTAssertGreaterThan(wall - media, 1_000_000, "and the wall clock does not")
    }

    /// R8: the run totals reach the record, and the live counters the
    /// detail page polls track them.
    func testRunTotalsReachTheRecordAndTheLiveCounters() throws {
        let runner = armedRunner()
        SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarPageBody))
        SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarPageBody))
        SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarDayLayerUpdate))
        SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarDayLayerApplied))
        XCTAssertEqual(runner.recordedCalendarPageBodyTotal, 2)
        XCTAssertEqual(runner.recordedCalendarDayLayerTotal, 1)
        XCTAssertEqual(runner.recordedCalendarDayLayerAppliedTotal, 1)
        XCTAssertEqual(runner.recordedGestureCount, 0, "no gesture claimed any of them")

        SpikeProbe.emit(.gesture(
            Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: 100
        ))
        runner.cancel()

        let metrics = try XCTUnwrap(runner.lastCompletedRun?.metrics)
        XCTAssertEqual(metrics["runCalendarPageBodyTotal"], .number(2))
        XCTAssertEqual(metrics["runCalendarDayLayerTotal"], .number(1))
        XCTAssertEqual(metrics["runCalendarDayLayerAppliedTotal"], .number(1))
    }

    /// The runner detaches every seam it attached: after a finish, the
    /// disabled path is one nil-check again. (On the spike branch this
    /// also asserted the experiment gate released; the gate machinery was
    /// not migrated — measurement-only runner here.)
    func testFinishingDetachesTheSignalSeam() {
        let runner = armedRunner()
        XCTAssertNotNil(SpikeProbe.onSignal)
        runner.cancel()
        XCTAssertNil(SpikeProbe.onSignal)
    }
}

// MARK: - Emit-site inventory (the seams no unit test can reach)

/// The tests that kill MUT-N and MUT-B.
///
/// Deleting the `CalendarPageView.body` emit outright survived 69 tests;
/// swapping the two signal ids at the emit sites survived 34. The pure
/// id→counter router IS pinned (that was the mutation QA's control, and it
/// died correctly), but the router can only be reached by an id that a
/// production view actually emits, and neither the SwiftUI `body` of a
/// 4000-line calendar page nor a `UIViewRepresentable`'s `updateUIView`
/// can be evaluated in a unit test.
///
/// So this pins the SOURCE. It is a weaker instrument than a behavioural
/// test and it is declared as such: it proves the call exists, spelled
/// with the right id, in the right file, and that no emit site has been
/// added without being declared here. It cannot prove the call is reached
/// at runtime — only a device run can, which is what `runCalendarPageBodyTotal`
/// and `runCalendarDayLayerAppliedTotal` are for.
final class Spike201EmitSiteInventoryTests: XCTestCase {

    /// `#filePath` is this file's location at COMPILE time, which is the
    /// checkout the test binary was built from. Two directories up is the
    /// repo root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines that actually CALL emit — a doc comment mentioning
    /// `SpikeProbe.emit` is documentation, not a site.
    private func emitCallLines(in source: String) -> [String] {
        source.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return false }
            return trimmed.contains("SpikeProbe.emit(")
        }
    }

    /// THE inventory. Every production emit site, by file and by the
    /// literal expression that must appear there. Adding a site without
    /// adding a row here fails `testTheInventoryIsComplete` below.
    private let inventory: [(path: String, expression: String)] = [
        ("Done/Views/Calendar/CalendarEventDetailView.swift",
         "SpikeProbe.emit(.bodyPass(Spike195SignalID.parentBody))"),
        ("Done/Views/Calendar/CalendarEventDetailView.swift",
         "SpikeProbe.emit(.bodyPass(Spike195SignalID.reflectionNoteLeaf))"),
        ("Done/Views/Calendar/CalendarEventDetailView.swift",
         "SpikeProbe.emit(.textLength(Spike195SignalID.reflectionNoteLength,"),
        ("Done/Views/Calendar/CalendarPageView.swift",
         "SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarPageBody))"),
        ("Done/Views/Calendar/Components/Timeline/CalendarDayLayerView.swift",
         "SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarDayLayerUpdate))"),
        ("Done/Views/Calendar/Components/Timeline/CalendarDayLayerView.swift",
         "SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarDayLayerApplied))"),
        ("Done/Views/Calendar/Components/CalendarEffortQuickControl.swift",
         "SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart,"),
        ("Done/Views/Calendar/Components/CalendarEffortQuickControl.swift",
         "SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd,"),
    ]

    /// MUT-N (deletion) and MUT-B (id swap) both land here: an emit that
    /// was deleted is absent, and an emit whose id was swapped with its
    /// twin's is absent from the file it belongs to.
    func testEveryDeclaredEmitSiteExistsExactlyOnceInItsOwnFile() throws {
        for entry in inventory {
            let src = try source(entry.path)
            let occurrences = src.components(separatedBy: entry.expression).count - 1
            XCTAssertEqual(
                occurrences, 1,
                "\(entry.path) must contain exactly one `\(entry.expression)` — found \(occurrences)"
            )
        }
    }

    /// The gesture emits in `GlassCardView` span several lines (they carry
    /// `drag.time`, which is the whole reason they live in the gesture
    /// closure), so they are pinned by phase + id proximity rather than by
    /// a single literal.
    func testTheScrubberGestureEmitsCarryTheirOwnPhasesAndTheTouchStamp() throws {
        let src = try source("Done/Views/Calendar/Components/GlassCardView.swift")
        XCTAssertEqual(emitCallLines(in: src).count, 2, "one `.changed` emit and one `.ended` emit, no more")

        // The argument list of each emit, taken as the text between the
        // call and its closing `))`. Indentation-independent.
        let bodies = src.components(separatedBy: "SpikeProbe.emit(.gesture(").dropFirst().map {
            String($0.prefix(while: { $0 != ")" }))
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("Spike201SignalID.effortScrubber"))
        XCTAssertTrue(bodies[0].contains(".changed"), "the first emit is the FINGER-DOWN sample")
        XCTAssertTrue(bodies[1].contains("Spike201SignalID.effortScrubber"))
        XCTAssertTrue(bodies[1].contains(".ended"), "the second is the LIFT")
        XCTAssertFalse(bodies[0].contains(".ended"))
        XCTAssertFalse(bodies[1].contains(".changed"))
        for body in bodies {
            XCTAssertTrue(
                body.contains("eventTime: drag.time"),
                "both emits must carry the touch's OWN stamp — that IS the delivery-lag measurement"
            )
        }
    }

    /// The two commit-bracket emits must BRACKET the call, in order. Their
    /// ordering around `onCommit` IS the commit-duration measurement.
    func testTheCommitBracketEmitsSurroundTheCommitInOrder() throws {
        let src = try source("Done/Views/Calendar/Components/CalendarEffortQuickControl.swift")
        let start = try XCTUnwrap(src.range(of: ".commitStart,"))
        let call = try XCTUnwrap(src.range(of: "onCommit(finalValue)"))
        let end = try XCTUnwrap(src.range(of: ".commitEnd,"))
        XCTAssertLessThan(start.lowerBound, call.lowerBound)
        XCTAssertLessThan(call.lowerBound, end.lowerBound)
    }

    /// The day-layer PAIR, in the two places that make them mean different
    /// things on post-#201 king: `update` before the representable hands
    /// the ApplyKey over, `applied` past BOTH admission tests — the keyed
    /// entry's `guard currentApplyKey != key` (gh#201 fix 2) AND
    /// `applyResolved`'s `guard currentModel != model`. Swapping the two
    /// ids inverts round 3's entire answer; an `applied` emit that
    /// drifted above either guard would count requests as work.
    func testTheDayLayerPairSitsOnOppositeSidesOfTheEarlyReturns() throws {
        let src = try source("Done/Views/Calendar/Components/Timeline/CalendarDayLayerView.swift")
        let updateEmit = try XCTUnwrap(src.range(of: "SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarDayLayerUpdate))"))
        // `updateUIView`'s call specifically — `makeUIView` uses
        // `view.apply(...)`, so this literal occurs exactly once.
        let applyCall = try XCTUnwrap(src.range(of: "uiView.apply(key: makeApplyKey(), callbacks: makeCallbacks(), makeOccurrences: occurrenceSource.build)"))
        let keyGuardLine = try XCTUnwrap(src.range(of: "guard currentApplyKey != key else { return }"))
        let modelGuardLine = try XCTUnwrap(src.range(of: "guard currentModel != model else { return }"))
        let appliedEmit = try XCTUnwrap(src.range(of: "SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarDayLayerApplied))"))

        XCTAssertLessThan(updateEmit.lowerBound, applyCall.lowerBound,
                          "`update` counts the REQUEST, so it precedes the apply call")
        XCTAssertLessThan(keyGuardLine.lowerBound, appliedEmit.lowerBound,
                          "`applied` counts the WORK, so it follows the ApplyKey filter")
        XCTAssertLessThan(modelGuardLine.lowerBound, appliedEmit.lowerBound,
                          "and the model guard too")
    }

    /// The `CalendarPageView` emit must be the first statement of `body`
    /// itself. An emit that drifted into a helper would count something
    /// else entirely, and one placed after `pageBodyContent` would not be
    /// evaluated on every body pass.
    func testTheCalendarPageEmitIsTheFirstStatementOfBody() throws {
        let src = try source("Done/Views/Calendar/CalendarPageView.swift")
        XCTAssertTrue(
            src.contains("SpikeProbe.emit(.bodyPass(Spike201SignalID.calendarPageBody))\n        pageBodyContent"),
            "the emit must sit immediately before `pageBodyContent`, inside `var body`"
        )
    }

    /// The count itself. `Spike201EffortTap.swift`'s header used to claim
    /// "the two emitters"; the number is eight and this is where it is
    /// established, by walking the tree rather than by asserting a
    /// sentence.
    func testTheInventoryIsCompleteAndNoUndeclaredEmitSiteExists() throws {
        let doneRoot = repoRoot.appendingPathComponent("Done")
        var found: [String: Int] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: doneRoot, includingPropertiesForKeys: nil
        ))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            let count = emitCallLines(in: src).count
            if count > 0 {
                found[url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")] = count
            }
        }

        var declared: [String: Int] = [:]
        for entry in inventory {
            declared[entry.path, default: 0] += 1
        }
        // The two multi-line gesture emits in GlassCardView are pinned by
        // their own test above, not by a single-line literal.
        declared["Done/Views/Calendar/Components/GlassCardView.swift"] = 2

        XCTAssertEqual(found, declared, "every emit site must be declared in `inventory`, and no others may exist")
        XCTAssertEqual(found.values.reduce(0, +), 10, "ten emit calls across five production files")
    }
}
