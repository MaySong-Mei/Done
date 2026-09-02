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

