//
//  ResidentObservationTests.swift
//  DoneTests
//
//  FIX WATCH — tests for the resident observability tier and for the two
//  repairs the adversary report demanded land BEFORE it:
//
//    * R-F3  — SpikeRunStore compaction: the byte-size stat gates the read
//              (no full-file decode per finishRun), and a compaction lands
//              at HALF the threshold so steady state cannot sit at the
//              threshold and rewrite on every close.
//    * R-F6.1 — SpikeSessionCoordinator seam teardown: a finishing manual
//              run must not nil a seam a RESIDENT still listens on (the
//              v1→v2 clobber lesson, one seam over).
//    * R-F10 — manual armed runs auto-expire; a leaked Start can no longer
//              run a display link forever.
//
//  Every expectation is hand-computed against the stated rule, not derived
//  by reading the implementation under test. Disk tests run against
//  isolated `.ephemeral` directories.
//

import Combine
import QuartzCore
import XCTest
import UIKit
@testable import Done

// MARK: - R-F6.1 — resident listeners and the slot-seam inverted clobber

@MainActor
final class ResidentSeamTests: XCTestCase {
    private var coordinator: SpikeSessionCoordinator!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storageLocation: EventStorageLocation!

    override func setUp() {
        super.setUp()
        coordinator = SpikeSessionCoordinator()
        suiteName = "ResidentSeamTests-\(UUID().uuidString)"
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

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: storageLocation, seedsSampleDataIfEmpty: false)
    }

    /// THE R-F6.1 pin: the last manual run's finish must leave BOTH seams
    /// installed for the resident. Pre-fix, `unregister` computed
    /// `storeStillListenedTo` over armed runs only and nil'ed
    /// `store.onSlotCommitted` — the resident's slot counters flatlined
    /// after any manual spike session and its liveness pairs drifted to
    /// 0/0, an INSUFFICIENT masquerade.
    func testManualRunFinishingLeavesTheResidentAttachedToBothSeams() {
        let store = makeStore()
        var residentSignals = 0
        var residentSlots: [StorageSlot] = []
        coordinator.registerResident(
            id: "fix-watch",
            store: store,
            onSignal: { _ in residentSignals += 1 },
            onSlotCommitted: { residentSlots.append($0) }
        )
        let manual = coordinator.register(
            run: makeRun(spikeID: "spike-a"), store: store,
            onSignal: { _ in }, onSlotCommitted: { _ in }, stop: {}
        )

        coordinator.unregister(runID: manual.id)

        XCTAssertNotNil(SpikeProbe.onSignal,
                        "the signal seam must survive the last manual unregister while a resident is attached")
        XCTAssertNotNil(store.onSlotCommitted,
                        "the slot seam must survive it too — this is the inverted clobber")

        SpikeProbe.emit(.bodyPass("x"))
        store.onSlotCommitted?(.calendarEvents)
        XCTAssertEqual(residentSignals, 1)
        XCTAssertEqual(residentSlots, [.calendarEvents])
    }

    /// The other direction still holds: with the resident ALSO gone, both
    /// seams return to nil — the zero-cost disabled path is reachable again.
    func testUnregisteringTheResidentLastRestoresTheDisabledPath() {
        let store = makeStore()
        coordinator.registerResident(id: "fix-watch", store: store, onSignal: { _ in }, onSlotCommitted: { _ in })
        let manual = coordinator.register(
            run: makeRun(spikeID: "spike-a"), store: store,
            onSignal: { _ in }, onSlotCommitted: { _ in }, stop: {}
        )

        coordinator.unregister(runID: manual.id)
        coordinator.unregisterResident(id: "fix-watch")

        XCTAssertNil(SpikeProbe.onSignal)
        XCTAssertNil(store.onSlotCommitted)
    }

    /// Fan-out order is armed runs first, then residents — deterministic,
    /// and the resident can never starve a measurement of its signal.
    func testDispatchReachesArmedRunsBeforeResidents() {
        var orderSeen: [String] = []
        _ = coordinator.register(
            run: makeRun(spikeID: "spike-a"), store: nil,
            onSignal: { _ in orderSeen.append("armed") }, onSlotCommitted: nil, stop: {}
        )
        coordinator.registerResident(id: "fix-watch", store: nil, onSignal: { _ in orderSeen.append("resident") })

        SpikeProbe.emit(.bodyPass("x"))

        XCTAssertEqual(orderSeen, ["armed", "resident"])
    }

    /// Residents are observers, not runs: they never appear in
    /// `armedRunIDs` (launch reconciliation must not exclude anything for
    /// them), never in `activeRuns`, and are never co-active-stamped onto
    /// a manual run.
    func testResidentsAreInvisibleToRunBookkeeping() {
        coordinator.registerResident(id: "fix-watch", store: nil, onSignal: { _ in })
        XCTAssertTrue(coordinator.armedRunIDs.isEmpty)
        XCTAssertTrue(coordinator.activeRuns.isEmpty)

        let stamped = coordinator.register(
            run: makeRun(spikeID: "spike-a"), store: nil,
            onSignal: { _ in }, onSlotCommitted: nil, stop: {}
        )
        XCTAssertEqual(stamped.coActiveSpikeIDs, [],
                       "a resident is not co-activity — the stamp answers what else was MEASURING")
    }
}

// MARK: - R-F10 — manual-run auto-expiry

@MainActor
final class ManualRunExpiryTests: XCTestCase {
    override func tearDown() {
        SpikeProbe.onSignal = nil
        super.tearDown()
    }

    private func makeRun(spikeID: String, startedAt: Date) -> SpikeRun {
        SpikeRun(
            id: UUID(), spikeID: spikeID, scenarioID: "sc", variantID: nil,
            startedAt: startedAt, endedAt: nil,
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone99,1", osVersion: "99.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            metrics: [:], note: nil, outcome: nil, abortReason: nil
        )
    }

    func testAnOverdueRunIsStoppedThroughItsOwnStopHandlerAndAFreshOneIsNot() {
        let coordinator = SpikeSessionCoordinator(manualRunExpiry: 30 * 60)
        var oldStopped = false
        var freshStopped = false
        let now = Date()
        _ = coordinator.register(
            run: makeRun(spikeID: "old", startedAt: now.addingTimeInterval(-31 * 60)),
            store: nil, onSignal: { _ in }, onSlotCommitted: nil,
            stop: { oldStopped = true }
        )
        let fresh = coordinator.register(
            run: makeRun(spikeID: "fresh", startedAt: now.addingTimeInterval(-60)),
            store: nil, onSignal: { _ in }, onSlotCommitted: nil,
            stop: { freshStopped = true }
        )

        coordinator.expireOverdueManualRuns(now: now)

        XCTAssertTrue(oldStopped, "31 minutes armed is past the 30-minute expiry")
        XCTAssertFalse(freshStopped, "one minute armed is not")
        XCTAssertEqual(coordinator.activeRuns.map(\.id), [fresh.id])
        coordinator.stopAll()
    }

    /// The boundary is inclusive: exactly `manualRunExpiry` old expires.
    func testExpiryBoundaryIsInclusive() {
        let coordinator = SpikeSessionCoordinator(manualRunExpiry: 100)
        var stopped = false
        let now = Date()
        _ = coordinator.register(
            run: makeRun(spikeID: "edge", startedAt: now.addingTimeInterval(-100)),
            store: nil, onSignal: { _ in }, onSlotCommitted: nil,
            stop: { stopped = true }
        )
        coordinator.expireOverdueManualRuns(now: now)
        XCTAssertTrue(stopped)
    }

    /// Residents never expire — they are not registrations at all, so the
    /// sweep cannot reach them by construction; this pins the observable
    /// half: the resident still hears signals after a sweep that stopped
    /// every overdue manual run.
    func testResidentsSurviveAnExpirySweep() {
        let coordinator = SpikeSessionCoordinator(manualRunExpiry: 100)
        var residentSignals = 0
        coordinator.registerResident(id: "fix-watch", store: nil, onSignal: { _ in residentSignals += 1 })
        _ = coordinator.register(
            run: makeRun(spikeID: "old", startedAt: Date().addingTimeInterval(-200)),
            store: nil, onSignal: { _ in }, onSlotCommitted: nil, stop: {}
        )

        coordinator.expireOverdueManualRuns(now: Date())
        SpikeProbe.emit(.bodyPass("x"))

        XCTAssertTrue(coordinator.activeRuns.isEmpty)
        XCTAssertEqual(residentSignals, 1)
    }
}

// MARK: - R-F3 — compaction: stat-gated, byte-bounded

final class SpikeRunStoreCompactionTests: XCTestCase {
    private var location: SpikeRunStorageLocation!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    private func fileURL(spikeID: String) -> URL {
        location.directory.appendingPathComponent("\(spikeID).jsonl")
    }

    private func fileSize(spikeID: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL(spikeID: spikeID).path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// The file's identity (inode) survives an append but not a rewrite —
    /// `rewrite` replaces the file atomically. That distinction is what
    /// lets a test observe "no compaction happened" from outside.
    private func fileID(spikeID: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL(spikeID: spikeID).path))?[.systemFileNumber] as? NSNumber)?.intValue ?? -1
    }

    private func makeClosedRun(spikeID: String, startedAt: Date, note: String? = nil) -> SpikeRun {
        SpikeRun(
            id: UUID(), spikeID: spikeID, scenarioID: "sc", variantID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1),
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone99,1", osVersion: "99.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            metrics: [:], note: note, outcome: .completed, abortReason: nil
        )
    }

    /// Under the byte threshold, `finishRun` must append and nothing more
    /// — no rewrite, even when the DISTINCT-RUN count is over the cap.
    /// This pins the R-F3 semantics change deliberately: the count cap no
    /// longer triggers a rewrite on its own (readers still see at most
    /// the cap via `loadRuns` retention); only the byte threshold pays
    /// for a compaction, and the stat that checks it is the only I/O a
    /// small file's finishRun performs beyond its own append.
    func testUnderThresholdFinishRunAppendsWithoutRewritingEvenOverTheCountCap() {
        let spikeID = "compaction-count"
        let base = Date(timeIntervalSince1970: 1_000_000)
        // 210 tiny runs: over the 200 count cap, far under 256KB.
        for index in 0..<210 {
            SpikeRunStore.finishRun(
                makeClosedRun(spikeID: spikeID, startedAt: base.addingTimeInterval(Double(index))),
                location: location
            )
        }
        XCTAssertLessThan(fileSize(spikeID: spikeID), SpikeRunStore.compactAtBytes)
        let idBefore = fileID(spikeID: spikeID)

        SpikeRunStore.finishRun(
            makeClosedRun(spikeID: spikeID, startedAt: base.addingTimeInterval(500)),
            location: location
        )

        XCTAssertEqual(fileID(spikeID: spikeID), idBefore,
                       "an under-threshold finishRun must append in place, never rewrite")
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: spikeID, location: location).count,
                       SpikeRunStore.maxRunsPerSpike,
                       "readers still see at most the cap — retention applies at read")
    }

    /// Driving the file past `compactAtBytes` must compact it down to at
    /// most `compactTargetBytes` (half the threshold), so steady state has
    /// 128KB of append headroom before the next rewrite — the pre-fix
    /// steady state rewrote the whole file on EVERY close.
    ///
    /// Deterministic by construction, because "keep appending until the
    /// file is over the threshold" CANNOT terminate — the very finishRun
    /// that crosses compacts back below it on its way out (this test's
    /// first draft looped forever on exactly that). So the record size is
    /// measured first, the file is filled to JUST under the threshold
    /// (provably no compaction can have run), and then ONE more append
    /// forces the single observable crossing.
    func testCompactionPastTheThresholdLandsAtOrUnderHalfOfIt() throws {
        let spikeID = "compaction-bytes"
        let base = Date(timeIntervalSince1970: 1_000_000)
        let padding = String(repeating: "x", count: 2_000)

        // Encoded line length is constant across these records: same keys,
        // fixed-width ISO-8601 dates and UUIDs, same note length.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let probeRecord = makeClosedRun(spikeID: spikeID, startedAt: base, note: padding)
        let lineBytes = try encoder.encode(probeRecord).count + 1

        let fillCount = (SpikeRunStore.compactAtBytes - 1) / lineBytes
        for index in 0..<fillCount {
            SpikeRunStore.finishRun(
                makeClosedRun(spikeID: spikeID, startedAt: base.addingTimeInterval(Double(index)), note: padding),
                location: location
            )
        }
        let filled = fileSize(spikeID: spikeID)
        XCTAssertEqual(filled, fillCount * lineBytes, "the size model must hold or the crossing below is not proven")
        XCTAssertLessThan(filled, SpikeRunStore.compactAtBytes, "still under threshold — no compaction has run yet")

        // The single crossing: this append reaches the threshold and the
        // same finishRun compacts on its way out.
        let lastStart = base.addingTimeInterval(Double(fillCount))
        SpikeRunStore.finishRun(
            makeClosedRun(spikeID: spikeID, startedAt: lastStart, note: padding),
            location: location
        )

        let size = fileSize(spikeID: spikeID)
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThanOrEqual(size, SpikeRunStore.compactTargetBytes,
                                 "a compaction must land with headroom, not at the threshold")

        // And the survivors are the NEWEST runs.
        let survivors = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        XCTAssertEqual(survivors.map(\.startedAt).max(), lastStart,
                       "byte retention drops the OLDEST runs")
        XCTAssertEqual(survivors.map(\.startedAt).min(),
                       lastStart.addingTimeInterval(Double(-(survivors.count - 1))),
                       "and keeps a contiguous newest block")
    }

    /// A single run bigger than the whole budget is kept anyway — the
    /// newest measurement must survive its own compaction.
    func testAnOversizedNewestRunSurvivesCompaction() {
        let spikeID = "compaction-oversized"
        let base = Date(timeIntervalSince1970: 1_000_000)
        let huge = String(repeating: "y", count: SpikeRunStore.compactAtBytes)
        SpikeRunStore.finishRun(
            makeClosedRun(spikeID: spikeID, startedAt: base, note: "small-old"),
            location: location
        )
        SpikeRunStore.finishRun(
            makeClosedRun(spikeID: spikeID, startedAt: base.addingTimeInterval(10), note: huge),
            location: location
        )

        let survivors = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(survivors.first?.note, huge)
    }

    /// R-F3 structural pin, in the `Spike201EmitSiteInventoryTests` idiom
    /// (a source scan is a weaker instrument than a behavioural test and
    /// is declared as such): inside `compactIfNeeded`, the size stat and
    /// its guard must both appear BEFORE the `loadRuns` call, so the
    /// full-file read cannot run on the under-threshold path.
    func testCompactIfNeededStatsAndGuardsBeforeItReads() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Done/Services/SpikeRunStore.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(
            src.range(of: "private static func compactIfNeeded").map { String(src[$0.lowerBound...]) }
        )
        let stat = try XCTUnwrap(body.range(of: "attributesOfItem"))
        let guardLine = try XCTUnwrap(body.range(of: "guard size >= compactAtBytes else { return }"))
        let read = try XCTUnwrap(body.range(of: "loadRuns("))
        XCTAssertLessThan(stat.lowerBound, guardLine.lowerBound)
        XCTAssertLessThan(guardLine.lowerBound, read.lowerBound,
                          "the guard must gate the read — stat first, read only when over threshold")
    }
}

// MARK: - Tier-1 core (pure)

final class ResidentTierOneCoreTests: XCTestCase {

    private func feedGesture(
        _ core: inout ResidentTierOneCore,
        startAt t: Double,
        travel: Double,
        changedSamples: Int = 1
    ) -> ResidentTierOneCore.GestureCompletion {
        var last: ResidentTierOneCore.GestureCompletion = .none
        for step in 0..<changedSamples {
            let x = 100 + travel * Double(step) / Double(max(1, changedSamples - 1))
            last = core.ingest(
                signal: .gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: changedSamples == 1 ? 100 : x),
                mediaNow: t + Double(step) * 0.02
            )
        }
        _ = core.ingest(signal: .gesture(Spike201SignalID.effortScrubber, .ended, eventTime: nil, locationX: 100 + travel), mediaNow: t + 0.09)
        _ = core.ingest(signal: .gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0), mediaNow: t + 0.10)
        last = core.ingest(signal: .gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0), mediaNow: t + 0.13)
        return last
    }

    /// R-F8's foundation: classification happens at gesture END, from the
    /// completed record — a stationary tap completes as `isTap: true`, a
    /// 200pt scrub as `isTap: false`. Windows key off exactly this.
    func testACompletedTapAndACompletedDragClassifyDifferently() {
        var core = ResidentTierOneCore()
        let tap = feedGesture(&core, startAt: 10, travel: 0)
        XCTAssertEqual(tap, .completed(isTap: true, commitEndedAtMedia: 10.13))
        let drag = feedGesture(&core, startAt: 20, travel: 200, changedSamples: 10)
        XCTAssertEqual(drag, .completed(isTap: false, commitEndedAtMedia: 20.13))
        XCTAssertEqual(core.counters.tapCount, 1)
        XCTAssertEqual(core.counters.dragCount, 1)
    }

    /// R-F4.3: the histogram bumps ONCE per completed gesture — a drag
    /// with 100 movement samples contributes exactly one drag-arm entry,
    /// not 100 small-lag samples that would drown a held-touch regression.
    func testHistogramBumpsOncePerCompletedGestureNotPerSample() {
        var core = ResidentTierOneCore()
        _ = feedGesture(&core, startAt: 10, travel: 200, changedSamples: 100)
        XCTAssertEqual(core.counters.dragLagHistogram.counts.reduce(0, +), 1)
        XCTAssertEqual(core.counters.tapLagHistogram.counts.reduce(0, +), 0)
    }

    /// A commit with no gesture open (the scenePhase backgrounding flush)
    /// completes nothing and counts nothing.
    func testACommitOutsideAnyGestureCompletesNothing() {
        var core = ResidentTierOneCore()
        _ = core.ingest(signal: .gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0), mediaNow: 5)
        let completion = core.ingest(signal: .gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0), mediaNow: 5.01)
        XCTAssertEqual(completion, .none)
        XCTAssertEqual(core.counters.tapCount, 0)
        XCTAssertEqual(core.counters.dragCount, 0)
    }

    /// R-F1's bound: the rolling log never grows past its ring capacity,
    /// and it is the NEWEST records that survive.
    func testTheRollingLogStaysBoundedAndKeepsTheNewest() {
        var core = ResidentTierOneCore()
        for index in 0..<40 {
            _ = feedGesture(&core, startAt: Double(index * 10), travel: 0)
        }
        XCTAssertEqual(core.gestureLog.records.count, ResidentTierOneCore.gestureRingCapacity)
        XCTAssertEqual(core.gestureLog.records.last?.firstChangedAt, 390.0)
        XCTAssertEqual(core.counters.tapCount, 40, "counters keep the full day even as the ring drops records")
    }

    /// The fixed-key privacy guard, positive and negative: known ids bump
    /// their counter, arbitrary strings bump NOTHING and can never reach
    /// a JSONL line.
    func testUnknownCounterAndInvariantIDsBumpNothing() {
        var core = ResidentTierOneCore()
        _ = core.ingest(signal: .counter(FixWatchSignalID.meComputedVisible), mediaNow: 1)
        _ = core.ingest(signal: .invariant(FixWatchSignalID.meComputedHidden), mediaNow: 1)
        _ = core.ingest(signal: .counter("some.free.form@string with spaces"), mediaNow: 1)
        _ = core.ingest(signal: .invariant("another/unknown"), mediaNow: 1)
        let before = core
        _ = core.ingest(signal: .counter("x"), mediaNow: 2)
        XCTAssertEqual(core, before, "an unknown id changes no state at all")
        XCTAssertEqual(core.counters.meComputedVisible, 1)
        XCTAssertEqual(core.counters.meComputedHidden, 1)
        XCTAssertFalse(core.counters.metrics.values.contains(.string("some.free.form@string with spaces")))
    }

    /// R-F11: the resident deliberately ignores the global bodyPass
    /// stream — entry 1's daily counters come from the per-instance store
    /// seams, fed through `noteDetailBodyPass`/`noteDraftComputed`.
    func testBodyPassSignalsAreIgnoredAndSeamNotesCount() {
        var core = ResidentTierOneCore()
        _ = core.ingest(signal: .bodyPass(Spike195SignalID.parentBody), mediaNow: 1)
        _ = core.ingest(signal: .bodyPass(Spike201SignalID.calendarPageBody), mediaNow: 1)
        XCTAssertEqual(core.counters.detailBodyPasses, 0)
        core.noteDetailBodyPass()
        core.noteDraftComputed()
        XCTAssertEqual(core.counters.detailBodyPasses, 1)
        XCTAssertEqual(core.counters.draftComputes, 1)
    }

    func testSlotNotesSplitBySlotAndReachTheRollingRecord() {
        var core = ResidentTierOneCore()
        _ = core.ingest(signal: .gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: 100), mediaNow: 1)
        core.noteSlot(.calendarEventLogRecords)
        core.noteSlot(.calendarEvents)
        core.noteSlot(.people)
        XCTAssertEqual(core.counters.slotWritesLogRecords, 1)
        XCTAssertEqual(core.counters.slotWritesCalendarEvents, 1)
        XCTAssertEqual(core.counters.slotWritesOther, 1)
        XCTAssertEqual(core.gestureLog.records.last?.slotWrites, 3)
    }
}

// MARK: - Lag histogram (pure)

final class ResidentLagHistogramTests: XCTestCase {
    func testBucketIndexEdgesAreInclusiveOnTheUpperBound() {
        XCTAssertEqual(ResidentLagHistogram.bucketIndex(forLagMs: 10), 0)
        XCTAssertEqual(ResidentLagHistogram.bucketIndex(forLagMs: 10.1), 1)
        XCTAssertEqual(ResidentLagHistogram.bucketIndex(forLagMs: 40), 2)
        XCTAssertEqual(ResidentLagHistogram.bucketIndex(forLagMs: 120), 4)
        XCTAssertEqual(ResidentLagHistogram.bucketIndex(forLagMs: 320), 5)
        XCTAssertEqual(ResidentLagHistogram.bucketIndex(forLagMs: 321), 6)
        XCTAssertEqual(ResidentLagHistogram.bucketIndex(forLagMs: nil), 7)
    }

    /// The criteria are bucket arithmetic ON PURPOSE (a daily histogram
    /// cannot honestly state a 1ms-precision median) — both bounds must
    /// therefore BE bucket edges, or the share question is unanswerable.
    func testTheCriteriaBoundsAreBucketEdgesAndOthersAreRefused() {
        var histogram = ResidentLagHistogram()
        histogram.admit(lagMs: 8)     // ≤10
        histogram.admit(lagMs: 35)    // ≤40
        histogram.admit(lagMs: 100)   // ≤120
        histogram.admit(lagMs: 500)   // overflow
        histogram.admit(lagMs: nil)   // missing
        XCTAssertEqual(histogram.measuredCount, 4, "the missing bucket never feeds a share")
        XCTAssertEqual(histogram.measuredCountAtOrUnder(ms: 40), 2)
        XCTAssertEqual(histogram.measuredCountAtOrUnder(ms: 120), 3)
        XCTAssertNil(histogram.measuredCountAtOrUnder(ms: 100), "a non-edge cut is a caller bug, answered with nil")
    }

    func testSerializationRoundTripsAndSumPools() {
        var a = ResidentLagHistogram()
        a.admit(lagMs: 15)
        a.admit(lagMs: nil)
        var b = ResidentLagHistogram()
        b.admit(lagMs: 15)
        b.admit(lagMs: 999)
        let restored = ResidentLagHistogram.deserialize(a.serialized)
        XCTAssertEqual(restored, a)
        XCTAssertNil(ResidentLagHistogram.deserialize("1 2 3"), "a wrong-arity line is refused, not padded")
        let pooled = ResidentLagHistogram.sum([a, b])
        XCTAssertEqual(pooled.counts[1], 2)
        XCTAssertEqual(pooled.measuredCount, 3)
    }
}

// MARK: - Counter set (pure)

final class ResidentCounterSetTests: XCTestCase {
    /// The R-F2 relaunch merge rests on this round trip: every field out,
    /// every field back.
    func testMetricsRoundTripRestoresEveryField() {
        var counters = ResidentCounterSet()
        counters.detailBodyPasses = 1
        counters.draftComputes = 2
        counters.meComputedHidden = 3
        counters.meComputedVisible = 4
        counters.tapCount = 5
        counters.dragCount = 6
        counters.implausibleLagCount = 7
        counters.slotWritesLogRecords = 8
        counters.slotWritesCalendarEvents = 9
        counters.slotWritesOther = 10
        counters.windowsOpened = 11
        counters.windowsRefusedBudget = 12
        counters.windowsExtended = 13
        counters.tapLagHistogram.admit(lagMs: 33)
        counters.dragLagHistogram.admit(lagMs: 200)

        let restored = ResidentCounterSet(metrics: counters.metrics)
        XCTAssertEqual(restored, counters)
    }

    /// Unknown keys are DROPPED on seed — the closed key set is the
    /// privacy guard, and a foreign line cannot smuggle state in.
    func testUnknownMetricKeysAreDroppedOnSeed() {
        var metrics = ResidentCounterSet().metrics
        metrics["someForeignKey"] = .number(99)
        metrics["note"] = .string("free-form text")
        let seeded = ResidentCounterSet(metrics: metrics)
        XCTAssertEqual(seeded, ResidentCounterSet())
    }
}

// MARK: - Window model + aggregates (pure)

final class ResidentWindowModelTests: XCTestCase {
    private func makeWindow(openedAtMedia: Double = 100) -> ResidentWindowModel {
        ResidentWindowModel(
            openedAtMedia: openedAtMedia,
            openedAt: Date(timeIntervalSince1970: 1_000_000),
            triggerCommitEndMedia: openedAtMedia - 0.01
        )
    }

    /// R-F9/R-F8: a qualifying tap extends by one duration, at most
    /// twice; the third is counted, never extending — so a window is
    /// bounded at 3 × duration and there is only ever one deadline.
    func testExtensionCapsAtTwoAndFurtherTapsAreCoalesced() {
        var window = makeWindow()
        XCTAssertEqual(window.deadlineMedia, 106, "6s base duration")
        XCTAssertTrue(window.noteQualifyingTap())
        XCTAssertEqual(window.deadlineMedia, 112)
        XCTAssertTrue(window.noteQualifyingTap())
        XCTAssertEqual(window.deadlineMedia, 118)
        XCTAssertFalse(window.noteQualifyingTap())
        XCTAssertEqual(window.deadlineMedia, 118, "past the cap the deadline never moves")
        XCTAssertEqual(window.extensions, 2)
        XCTAssertEqual(window.coalescedBeyondCap, 1)
    }

    func testBudgetRefusesAtTwelve() {
        XCTAssertTrue(ResidentWindowBudget.canOpen(openedToday: 11))
        XCTAssertFalse(ResidentWindowBudget.canOpen(openedToday: 12))
    }

    /// R-F4.2: any commit in a slot outside the expected set — or more
    /// log/mirror commits than writing gestures — contaminates the window.
    func testContaminationRules() {
        var clean = makeWindow()
        clean.noteSlot(.calendarEventLogRecords)
        clean.noteSlot(.calendarEvents)
        XCTAssertFalse(ResidentWindowAggregates.isContaminated(window: clean, writingGesturesInWindow: 1))

        var foreign = makeWindow()
        foreign.noteSlot(.people)
        XCTAssertTrue(ResidentWindowAggregates.isContaminated(window: foreign, writingGesturesInWindow: 1))

        var doubled = makeWindow()
        doubled.noteSlot(.calendarEventLogRecords)
        doubled.noteSlot(.calendarEventLogRecords)
        XCTAssertTrue(ResidentWindowAggregates.isContaminated(window: doubled, writingGesturesInWindow: 1),
                      "an organic log write during the window inflates past the writing-gesture count")
    }

    /// The window covers exactly the gestures whose commit landed between
    /// its trigger and its close — media time is monotonic, so the bounds
    /// are exact, and the TRIGGER tap itself is inside (R-F1: the window
    /// never had to see it live; the rolling log carried it).
    func testRecordsInWindowSpanTriggerThroughClose() throws {
        var log = Spike201GestureLog()
        func tap(at t: Double) {
            log.ingest(phase: .changed, at: t, locationX: 100, deliveryLagMs: nil)
            log.ingest(phase: .ended, at: t + 0.05, locationX: 100, deliveryLagMs: nil)
            log.ingest(phase: .commitStart, at: t + 0.06, locationX: 0, deliveryLagMs: nil)
            log.ingest(phase: .commitEnd, at: t + 0.10, locationX: 0, deliveryLagMs: nil)
        }
        tap(at: 90)   // before the window — excluded
        tap(at: 99.8) // the trigger (commit at 99.9)
        tap(at: 102)  // inside
        tap(at: 130)  // after close — excluded

        // The trigger bound is the SAME Double production passes: the
        // ingested commitEnd itself (`GestureCompletion.completed` hands
        // it over verbatim). Rebuilding 99.8 + 0.10 from arithmetic here
        // produced a value one ULP off the literal and silently excluded
        // the trigger tap — the exact bug this bound's design avoids.
        let triggerCommitEnd = try XCTUnwrap(log.records[1].commitEndedAt)
        let window = ResidentWindowModel(
            openedAtMedia: triggerCommitEnd + 0.01,
            openedAt: Date(),
            triggerCommitEndMedia: triggerCommitEnd
        )
        let covered = ResidentWindowAggregates.recordsInWindow(log.records, window: window, closedAtMedia: 106)
        XCTAssertEqual(covered.map(\.firstChangedAt), [99.8, 102])
    }

    /// Auto-window records carry AGGREGATES ONLY — no per-gesture CSV
    /// (R-F3) — and a realistic record stays small. The ruling's target
    /// is ≤ 600 bytes; the honest envelope (device/os/tz/locale stamp
    /// that every SpikeRun carries) plus the frame subset lands slightly
    /// above it, pinned here at ≤ 900 so growth is caught.
    func testAWindowRecordCarriesNoCSVAndStaysUnderTheSizePin() throws {
        var log = Spike201GestureLog()
        log.ingest(phase: .changed, at: 100, locationX: 100, deliveryLagMs: 21.4)
        log.ingest(phase: .ended, at: 100.08, locationX: 100, deliveryLagMs: nil)
        log.ingest(phase: .commitStart, at: 100.09, locationX: 0, deliveryLagMs: nil)
        log.ingest(phase: .commitEnd, at: 100.135, locationX: 0, deliveryLagMs: nil)
        log.noteSlotWrite(slot: .calendarEventLogRecords)
        log.noteFrame(at: 100.95)

        var window = ResidentWindowModel(openedAtMedia: 100.14, openedAt: Date(), triggerCommitEndMedia: 100.135)
        window.noteSlot(.calendarEventLogRecords)

        var overshoot = SpikeFrameOvershootTally()
        overshoot.admit(0.4)
        let drain = SpikeFrameTickDrain(
            samples: [16.7, 16.6, 812.4, 16.8],
            isTruncated: false,
            suspensionGapCount: 0,
            suspensionGapsMs: [],
            activeStallsMs: [812.4],
            largestDeltasMs: [812.4, 16.8, 16.7],
            overshoot: overshoot,
            resignActiveCount: 0,
            didBecomeActiveCount: 0
        )
        let probe = SpikeFrameProbeResult(
            stats: SpikeFrameStatistics.summarize(durationsMs: drain.samples),
            truncated: false,
            maximumFramesPerSecond: 120,
            drain: drain
        )
        let metrics = ResidentWindowAggregates.metrics(
            window: window,
            records: log.records,
            closedAtMedia: 106.14,
            probe: probe,
            closedByResign: false
        )
        XCTAssertNil(metrics["gestures"], "no CSV on auto-windows")
        XCTAssertEqual(metrics["wWritingTaps"], .number(1))
        XCTAssertEqual(metrics["wContaminated"], .bool(false))
        XCTAssertEqual(metrics["wCommitMs"], .string("45.0"))
        XCTAssertEqual(metrics["wFrameAfterCommitMs"], .string("815.0"))

        let run = SpikeRun(
            id: UUID(), spikeID: FixObservationRegistry.effortPathFixID,
            scenarioID: FixObservationRegistry.windowScenarioID, variantID: nil,
            startedAt: Date(), endedAt: Date().addingTimeInterval(6),
            appVersion: "1.4.2", appBuild: "142", appCommit: nil,
            deviceModel: "iPhone17,1", osVersion: "26.0",
            timeZoneIdentifier: "America/Los_Angeles", localeIdentifier: "en_US",
            buildConfiguration: "release",
            metrics: metrics, note: nil, outcome: .completed, abortReason: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(run).count
        XCTAssertLessThanOrEqual(bytes, 900, "window record grew past its size pin (target 600B, envelope-honest pin 900B)")
    }

    /// A gesture that began inside the window and never committed by
    /// close is marked, never silently completed.
    func testAnUncommittedGestureAtCloseIsMarkedTruncated() {
        var log = Spike201GestureLog()
        log.ingest(phase: .changed, at: 103, locationX: 100, deliveryLagMs: nil)
        let window = ResidentWindowModel(openedAtMedia: 100, openedAt: Date(), triggerCommitEndMedia: 99.9)
        let metrics = ResidentWindowAggregates.metrics(
            window: window, records: log.records, closedAtMedia: 106, probe: nil, closedByResign: false
        )
        XCTAssertEqual(metrics["wTruncatedGesture"], .bool(true))
    }
}

// MARK: - Resident center (wiring: relaunch merge, flushes, windows)

@MainActor
final class ResidentObservationCenterTests: XCTestCase {
    private final class ClockBox {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var center: ResidentObservationCenter?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        coordinator = nil
        location = nil
        super.tearDown()
    }

    private func makeCenter(clock: ClockBox) -> ResidentObservationCenter {
        let made = ResidentObservationCenter(
            coordinator: coordinator,
            store: nil,
            location: location,
            calendar: .current,
            now: { clock.now }
        )
        center = made
        return made
    }

    private func emitDrag() {
        for x in stride(from: 40.0, through: 240.0, by: 40.0) {
            SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: x))
        }
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .ended, eventTime: nil, locationX: 240))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0))
    }

    private func emitTap() {
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .ended, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0))
    }

    private func loadDailies() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    /// THE R-F2 pin, exactly as the adversary demanded: seed counters →
    /// flush → simulate relaunch (new center over the same store dir) →
    /// bump → flush → the day's single record carries morning+evening
    /// sums, including a nonzero tripwire count surviving the relaunch.
    func testRelaunchMergesTheDaysCountersIncludingTheTripwire() throws {
        let clock = ClockBox(Date())
        let morning = makeCenter(clock: clock)
        morning.activate()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        emitDrag()
        morning.flushDaily()
        morning.deactivate()

        let evening = makeCenter(clock: clock)
        evening.activate()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        emitDrag()
        evening.flushDaily()
        evening.deactivate()

        let dailies = loadDailies()
        XCTAssertEqual(dailies.count, 1, "same day, same run id — collapse keeps ONE record")
        let record = try XCTUnwrap(dailies.first)
        XCTAssertEqual(record.metrics["meComputedHidden"], .number(4),
                       "the morning's 3 violations survive the relaunch — the alarm cannot un-fire over lunch")
        XCTAssertEqual(record.metrics["meComputedVisible"], .number(2))
        XCTAssertEqual(record.metrics["dragCount"], .number(2))
    }

    /// T2: signals write ZERO bytes; the first flush edge writes the line.
    func testSignalsAloneWriteNothingUntilAFlushEdge() {
        let clock = ClockBox(Date())
        let made = makeCenter(clock: clock)
        made.activate()
        emitDrag()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        XCTAssertTrue(loadDailies().isEmpty, "no lifecycle edge yet — nothing on disk")
        made.flushDaily()
        XCTAssertEqual(loadDailies().count, 1)
    }

    /// T3: two same-day flushes collapse to one run; a clock past
    /// midnight mints a new id, and yesterday's line closes at its own
    /// day end.
    func testSameDayReflushCollapsesAndRolloverMintsANewID() throws {
        let calendar = Calendar.current
        let elevenPM = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        let clock = ClockBox(elevenPM)
        let made = makeCenter(clock: clock)
        made.activate()
        emitDrag()
        made.flushDaily()
        made.flushDaily()
        XCTAssertEqual(loadDailies().count, 1)
        let yesterdayID = loadDailies()[0].id

        clock.now = elevenPM.addingTimeInterval(2 * 3600) // 01:00 next day
        made.performRolloverFlushIfDue()
        emitDrag()
        made.flushDaily()

        let dailies = loadDailies().sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(dailies.count, 2)
        XCTAssertEqual(dailies[0].id, yesterdayID)
        XCTAssertNotEqual(dailies[1].id, yesterdayID)
        XCTAssertEqual(dailies[0].endedAt, calendar.startOfDay(for: clock.now),
                       "yesterday's line closes AT its own day end")
        XCTAssertEqual(dailies[1].metrics["dragCount"], .number(1), "the new day starts from zero")
    }

    /// R-F3: the rollover flush NEVER runs synchronously from a signal —
    /// the signal only schedules a main-queue hop.
    func testRolloverFromASignalIsDeferredOffTheSignalPath() {
        let calendar = Calendar.current
        let elevenPM = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        let clock = ClockBox(elevenPM)
        let made = makeCenter(clock: clock)
        made.activate()
        emitDrag()

        clock.now = elevenPM.addingTimeInterval(2 * 3600)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        XCTAssertTrue(loadDailies().isEmpty,
                      "the signal that crossed midnight must not write synchronously")

        let deadline = Date().addingTimeInterval(2)
        while loadDailies().isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(loadDailies().count, 1, "the deferred hop flushed yesterday's line")
    }

    /// R-F8 + R-F5: a completed TAP opens a window; a drag never does.
    func testAWindowOpensOnACompletedTapAndNeverOnADrag() {
        let clock = ClockBox(Date())
        let made = makeCenter(clock: clock)
        made.activate()
        emitDrag()
        XCTAssertNil(made.window, "drags never open windows")
        XCTAssertEqual(made.core.counters.windowsOpened, 0)

        emitTap()
        XCTAssertNotNil(made.window)
        XCTAssertEqual(made.core.counters.windowsOpened, 1)
        XCTAssertTrue(loadDailies().isEmpty, "window open writes NOTHING (R-F5)")
        XCTAssertTrue(
            SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location).isEmpty,
            "no write-ahead record either — a crashed window loses itself, launch reconciliation never sees it"
        )
        made.closeWindow(outcome: .completed)
        let windows = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location)
        XCTAssertEqual(windows.count, 1, "everything (stamp, record) happens at close")
        XCTAssertNil(made.window)
    }

    /// One window globally; qualifying taps extend to the cap and the
    /// record says so.
    func testTapsWhileOpenExtendToTheCapAndTheRecordCarriesIt() throws {
        let clock = ClockBox(Date())
        let made = makeCenter(clock: clock)
        made.activate()
        emitTap()
        emitTap()
        emitTap()
        emitTap() // 3 taps while open: 2 extensions + 1 coalesced
        XCTAssertEqual(made.core.counters.windowsOpened, 1, "one window at a time — never a second probe")
        XCTAssertEqual(made.core.counters.windowsExtended, 2)
        made.closeWindow(outcome: .completed)

        let record = try XCTUnwrap(
            SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location).first
        )
        XCTAssertEqual(record.metrics["wExtensions"], .number(2))
        XCTAssertEqual(record.metrics["wCoalescedBeyondCap"], .number(1))
        XCTAssertEqual(record.metrics["wTaps"], .number(4), "all four taps' forensics came from the rolling log")
    }

    /// R-F2's budget half, exactly as demanded: a daily record showing 12
    /// opened windows refuses the first post-relaunch trigger.
    func testWindowBudgetSurvivesRelaunchViaTheDailyRecord() {
        let clock = ClockBox(Date())
        var spent = ResidentCounterSet()
        spent.windowsOpened = 12
        let context = SpikeRunContext.stamp()
        SpikeRunStore.finishRun(SpikeRun(
            id: UUID(), spikeID: FixObservationRegistry.residentDailySpikeID,
            scenarioID: FixObservationRegistry.residentDailyScenarioID, variantID: nil,
            startedAt: clock.now, endedAt: clock.now,
            appVersion: context.appVersion, appBuild: context.appBuild, appCommit: nil,
            deviceModel: context.deviceModel, osVersion: context.osVersion,
            timeZoneIdentifier: context.timeZoneIdentifier, localeIdentifier: context.localeIdentifier,
            metrics: spent.metrics, note: nil, outcome: .completed, abortReason: nil
        ), location: location)

        let made = makeCenter(clock: clock)
        made.activate()
        emitTap()
        XCTAssertNil(made.window, "the 13th window of the day is refused, across a relaunch")
        XCTAssertEqual(made.core.counters.windowsRefusedBudget, 1, "and the refusal is itself a counter")
    }

    /// A manual #201 run suppresses auto-windows entirely: forensic
    /// manual runs keep a clean field and there is never a second
    /// display link.
    func testAManualEffortRunSuppressesAutoWindows() {
        let clock = ClockBox(Date())
        let made = makeCenter(clock: clock)
        made.activate()
        let manual = coordinator.register(
            run: SpikeRun(
                id: UUID(), spikeID: Spike201SignalID.spikeID, scenarioID: "sc", variantID: nil,
                startedAt: Date(), endedAt: nil,
                appVersion: "1", appBuild: "1", appCommit: nil,
                deviceModel: "d", osVersion: "1",
                timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
                metrics: [:], note: nil, outcome: nil, abortReason: nil
            ),
            store: nil, onSignal: { _ in }, onSlotCommitted: nil, stop: {}
        )
        emitTap()
        XCTAssertNil(made.window)
        XCTAssertEqual(made.core.counters.windowsOpened, 0)
        coordinator.unregister(runID: manual.id)
    }
}

// MARK: - Graduation guards (structural)

final class ResidentGraduationGuardTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// R-F10: the resident is wired ONLY outside XCTest. Source-scan (the
    /// declared-weaker instrument, same as the emit-site inventory) plus
    /// the runtime half below.
    func testDoneAppGuardsResidentCreationOnXCTest() throws {
        let src = try source("Done/DoneApp.swift")
        let creation = try XCTUnwrap(src.range(of: "ResidentObservationCenter(coordinator:"))
        let guardRange = try XCTUnwrap(src.range(of: "!EventStorageLocation.isRunningUnderXCTest"))
        XCTAssertLessThan(guardRange.lowerBound, creation.lowerBound,
                          "the XCTest guard must gate the center's creation")
    }

    /// The runtime half: in THIS process (the hosted test run), the app
    /// never built a resident — no shared center exists unless a test
    /// made one, and tests tear theirs down.
    @MainActor
    func testNoAppResidentExistsInTheTestHost() {
        XCTAssertNil(ResidentObservationCenter.shared)
    }

    /// R-F10: the signal hot path structurally cannot read defaults or do
    /// ambient calendar math — the pure model file bans both outright;
    /// the center bans UserDefaults and confines calendar math to the
    /// two flush-edge sites that recompute the cached day bound. CODE
    /// lines only: both files' doc comments name the banned tokens on
    /// purpose (that is the contract being documented), so a raw
    /// `contains` would fail on its own documentation.
    func testTheHotPathFilesContainNoDefaultsAndNoAmbientCalendar() throws {
        func codeLines(_ source: String) -> [String] {
            source.components(separatedBy: "\n").filter { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
        }
        let model = codeLines(try source("Done/Models/ResidentObservationModel.swift"))
        XCTAssertFalse(model.contains { $0.contains("UserDefaults") })
        XCTAssertFalse(model.contains { $0.contains("Calendar.current") })

        let center = codeLines(try source("Done/Services/ResidentObservationCenter.swift"))
        XCTAssertFalse(center.contains { $0.contains("UserDefaults") })
        XCTAssertEqual(
            center.filter { $0.contains("ResidentDayBounds.compute") }.count, 2,
            "day-bound calendar math runs at exactly two flush-edge sites (init + rollover), never per signal"
        )
    }

    /// R-F11: retirement keeps registry entries AND emit sites. The
    /// registry has no removal path (a compile-time literal), retired
    /// entries stay listed, and the Me-tab witness sites belong to the
    /// emit-site inventory, which fails on any deletion.
    func testRetirementKeepsEntriesListedAndTheirSignalIDsWired() {
        for entry in FixObservationRegistry.all {
            XCTAssertNotNil(FixObservationRegistry.entry(for: entry.id),
                            "every entry stays reachable regardless of lifecycle")
        }
        // The tripwire's signal ids must stay spelled into the witness
        // emitters (inventory rows pin the sites themselves; this pins
        // the id linkage so a retired entry cannot orphan its wire).
        XCTAssertEqual(FixWatchSignalID.meComputedHidden, "me.aggregates.computedHidden")
        XCTAssertEqual(FixWatchSignalID.meComputedVisible, "me.aggregates.computedVisible")
    }
}

// MARK: - Verdict evaluator (pure, fixture matrix)

final class FixWatchVerdictEvaluatorTests: XCTestCase {

    private func makeRun(
        spikeID: String,
        scenarioID: String,
        metrics: [String: SpikeMetricValue],
        buildConfiguration: String?,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SpikeRun {
        SpikeRun(
            id: UUID(), spikeID: spikeID, scenarioID: scenarioID, variantID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone17,1", osVersion: "26.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            buildConfiguration: buildConfiguration,
            metrics: metrics, note: nil, outcome: .completed, abortReason: nil
        )
    }

    private func daily(_ counters: ResidentCounterSet, build: String? = "release", startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SpikeRun {
        makeRun(
            spikeID: FixObservationRegistry.residentDailySpikeID,
            scenarioID: FixObservationRegistry.residentDailyScenarioID,
            metrics: counters.metrics,
            buildConfiguration: build,
            startedAt: startedAt
        )
    }

    private func window(commitMs: [Double], frameAfterCommitMs: [Double] = [], contaminated: Bool = false, build: String? = "release") -> SpikeRun {
        var metrics: [String: SpikeMetricValue] = [
            "wContaminated": .bool(contaminated),
        ]
        if !commitMs.isEmpty {
            metrics["wCommitMs"] = .string(commitMs.map { String(format: "%.1f", $0) }.joined(separator: " "))
        }
        if !frameAfterCommitMs.isEmpty {
            metrics["wFrameAfterCommitMs"] = .string(frameAfterCommitMs.map { String(format: "%.1f", $0) }.joined(separator: " "))
        }
        return makeRun(
            spikeID: FixObservationRegistry.effortPathFixID,
            scenarioID: FixObservationRegistry.windowScenarioID,
            metrics: metrics,
            buildConfiguration: build
        )
    }

    /// A tap-lag counter set with `count` samples all in the ≤40ms bucket
    /// unless placed elsewhere.
    private func lagCounters(under40: Int, over320: Int = 0, hidden: Int = 0, visible: Int = 0) -> ResidentCounterSet {
        var counters = ResidentCounterSet()
        for _ in 0..<under40 { counters.tapLagHistogram.admit(lagMs: 30) }
        for _ in 0..<over320 { counters.tapLagHistogram.admit(lagMs: 500) }
        counters.meComputedHidden = hidden
        counters.meComputedVisible = visible
        return counters
    }

    // MARK: R-F4.1 — Release-only criteria

    /// Debug records — however damning their numbers — never feed a
    /// verdict. With ONLY debug data the state is 观察中 (observing), not
    /// failing, and the debug population is counted for display.
    func testDebugRecordsNeverFeedAVerdict() {
        var awful = lagCounters(under40: 0, over320: 50)
        awful.meComputedHidden = 7
        let dailies = [daily(awful, build: "debug"), daily(awful, build: nil)]
        let windows = [window(commitMs: Array(repeating: 500, count: 30), build: "debug")]

        let effort = FixWatchVerdictEvaluator.evaluateEffortPath(dailies: dailies, windows: windows)
        XCTAssertEqual(effort.state, .observing)
        XCTAssertEqual(effort.nonReleaseCount, 3)

        let gate = FixWatchVerdictEvaluator.evaluateMeTabGate(dailies: dailies)
        XCTAssertEqual(gate.state, .observing)
        XCTAssertFalse(gate.alarm, "a debug-build violation is display, not alarm — the criteria population is Release only")

        let touch = FixWatchVerdictEvaluator.evaluateTouchDelivery(dailies: dailies)
        XCTAssertEqual(touch.state, .observing)
    }

    // MARK: Entry 2 — tripwire epistemics

    func testAnyPositiveTripwireIsFailingWithAlarmRegardlessOfLiveness() {
        let verdict = FixWatchVerdictEvaluator.evaluateMeTabGate(
            dailies: [daily(lagCounters(under40: 0, hidden: 1, visible: 500))]
        )
        XCTAssertEqual(verdict.state, .failing)
        XCTAssertTrue(verdict.alarm)
    }

    func testTripwireZeroWithZeroLivenessIsInsufficientNotHolding() {
        let verdict = FixWatchVerdictEvaluator.evaluateMeTabGate(
            dailies: [daily(lagCounters(under40: 0, hidden: 0, visible: 0))]
        )
        XCTAssertEqual(verdict.state, .insufficient, "dead wire and unvisited tab are indistinguishable — say so")
    }

    func testTripwireZeroWithLivenessIsHolding() {
        let verdict = FixWatchVerdictEvaluator.evaluateMeTabGate(
            dailies: [daily(lagCounters(under40: 0, hidden: 0, visible: 37))]
        )
        XCTAssertEqual(verdict.state, .holding)
        XCTAssertFalse(verdict.alarm)
    }

    /// The R-F7 honesty note is part of the surface, not a comment.
    func testTheTripwireVerdictCarriesTheHonestyNote() {
        let verdict = FixWatchVerdictEvaluator.evaluateMeTabGate(dailies: [])
        XCTAssertTrue(verdict.notes.contains { $0.contains("RootTabVisibility.isVisible") },
                      "the card must state the blind spot: call-site bypasses only")
    }

    // MARK: Entry 1 — commit criterion, floors, contamination, report-only

    func testEffortPathHoldsAtTheThresholdAndFailsPastIt() {
        let healthyLag = [daily(lagCounters(under40: 12))]
        let holding = FixWatchVerdictEvaluator.evaluateEffortPath(
            dailies: healthyLag,
            windows: [window(commitMs: Array(repeating: 54.9, count: 20))]
        )
        XCTAssertEqual(holding.state, .holding)

        let failing = FixWatchVerdictEvaluator.evaluateEffortPath(
            dailies: healthyLag,
            windows: [window(commitMs: Array(repeating: 55.1, count: 20))]
        )
        XCTAssertEqual(failing.state, .failing)
    }

    func testEffortPathBelowTheSampleFloorIsInsufficient() {
        let verdict = FixWatchVerdictEvaluator.evaluateEffortPath(
            dailies: [daily(lagCounters(under40: 12))],
            windows: [window(commitMs: Array(repeating: 40, count: 19))]
        )
        XCTAssertEqual(verdict.state, .insufficient, "19 writing taps is under the 20-sample floor")
    }

    /// R-F4.2: contaminated windows feed NOTHING — their fast commits
    /// cannot rescue the floor.
    func testContaminatedWindowsAreExcludedFromThePool() {
        let verdict = FixWatchVerdictEvaluator.evaluateEffortPath(
            dailies: [daily(lagCounters(under40: 12))],
            windows: [
                window(commitMs: Array(repeating: 40, count: 15)),
                window(commitMs: Array(repeating: 40, count: 15), contaminated: true),
            ]
        )
        XCTAssertEqual(verdict.state, .insufficient,
                       "15 clean samples — the contaminated window's 15 must not fill the floor")
        XCTAssertTrue(verdict.notes.contains { $0.contains("污染") })
    }

    /// The settle storm is REPORT-ONLY: second-long first-frames after
    /// commit change nothing about a holding verdict — the fix never
    /// claimed that residual, and the verdict must not punish or absolve
    /// it.
    func testTheSettleStormIsDisplayedButNeverFailsTheVerdict() {
        let verdict = FixWatchVerdictEvaluator.evaluateEffortPath(
            dailies: [daily(lagCounters(under40: 12))],
            windows: [window(
                commitMs: Array(repeating: 40, count: 20),
                frameAfterCommitMs: Array(repeating: 1_009, count: 20)
            )]
        )
        XCTAssertEqual(verdict.state, .holding)
        XCTAssertTrue(verdict.readouts.contains { $0.id.contains("settle") && $0.passing == nil })
    }

    // MARK: Entry 3 — bucket-arithmetic criteria

    func testTouchDeliveryPassesWhenAllSamplesAreFast() {
        let verdict = FixWatchVerdictEvaluator.evaluateTouchDelivery(
            dailies: [daily(lagCounters(under40: 10))]
        )
        XCTAssertEqual(verdict.state, .holding)
    }

    /// Hand-computed boundary: 10 samples, 9 at ≤40ms and 1 past 320ms.
    /// p50 clause: 9/10 ≥ 50% → passes. p95 clause: 9/10 < 95% → fails.
    func testTouchDeliveryP95CatchesASlowTail() {
        let verdict = FixWatchVerdictEvaluator.evaluateTouchDelivery(
            dailies: [daily(lagCounters(under40: 9, over320: 1))]
        )
        XCTAssertEqual(verdict.state, .failing)
        let p50 = verdict.readouts.first { $0.id.contains("p50") }
        let p95 = verdict.readouts.first { $0.id.contains("p95") }
        XCTAssertEqual(p50?.passing, true)
        XCTAssertEqual(p95?.passing, false)
    }

    func testTouchDeliveryBelowTenSamplesIsInsufficient() {
        let verdict = FixWatchVerdictEvaluator.evaluateTouchDelivery(
            dailies: [daily(lagCounters(under40: 9))]
        )
        XCTAssertEqual(verdict.state, .insufficient)
    }

    /// Pooling is bucket-wise across days: two days of 6 samples each
    /// clear the 10-sample floor together.
    func testHistogramsPoolAcrossDailyRecords() {
        let day1 = daily(lagCounters(under40: 6), startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let day2 = daily(lagCounters(under40: 6), startedAt: Date(timeIntervalSince1970: 1_700_100_000))
        let verdict = FixWatchVerdictEvaluator.evaluateTouchDelivery(dailies: [day1, day2])
        XCTAssertEqual(verdict.state, .holding)
        XCTAssertEqual(verdict.releaseDayCount, 2)
    }
}

