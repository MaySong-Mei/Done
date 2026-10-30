//
//  SyncRestoreStaleSnapshotQATests.swift
//  DoneTests
//
//  Independent QA for the restore premise the Lean model calls `hfresh`
//  (formal/restore-replay c4a56b85, `restore_stale_snapshot_witness`):
//  "Restore from Cloud" fetches its snapshot when the sheet opens and
//  applies it only after the user's review, while the puller keeps
//  running; the restore moves no cursor. When the device pulls a newer
//  version of a snapshot row in between, the replay writes the older
//  `(hash, seq)` back under a cursor already past the newer one.
//
//  Each pin runs the window through `RestoreCoordinator` (the app's path)
//  and asserts the CORRECT outcome inside `XCTExpectFailure`: the suite is
//  green on king 7a2e382e, and a test fails ("expected failure not
//  recorded") the moment a fix makes its outcome right, so the wrapper
//  must then be removed. The fixture steps before the wrapper are plain
//  assertions — the device really pulled the peer's write before the
//  apply — so a pin cannot pass vacuously. The control at the end runs the
//  same writes with the peer's edit landing BEFORE the fetch (`hfresh`
//  holds) and asserts the same outcome unwrapped: the assertions are
//  satisfiable, and only the timing differs.
//
//  The same four outcomes were reproduced on the real app against the
//  local stack (QA e2e, not committed).
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreStaleSnapshotQATests: SyncRestoreAndSwitchTestCase {

    private func coordinator() -> RestoreCoordinator {
        let c = RestoreCoordinator()
        c.configure(syncService: service, eventStore: store, eventTypeStore: device.types,
                    skillStore: device.skills, preferenceStore: device.prefs)
        return c
    }

    private func fetch(_ c: RestoreCoordinator) async throws {
        await c.startFetch()
        guard case .ready = c.phase else {
            throw FixtureFailure(description: "the restore fetch did not finish: \(c.phase)")
        }
    }

    private func apply(_ c: RestoreCoordinator, _ strategy: RestoreStrategy,
                       resolution: ConflictResolution = .keepLocal) async throws {
        switch strategy {
        case .cloudOverwritesLocal:
            await c.applyOverwrite()
        case .merge:
            await c.prepareMerge()
            if case .mergeReview = c.phase { await c.applyMerge(resolution: resolution) }
        }
        guard case .finished = c.phase else {
            throw FixtureFailure(description: "the restore did not finish: \(c.phase)")
        }
    }

    private func local(_ id: UUID) -> Event? {
        store.rawCalendarEvents.first { $0.id == id }
    }

    /// One flush of whatever the restore or an edit left dirty, then the
    /// eligible pull its `[]` asks for (the verify pass).
    private func flushAndVerify() async throws {
        scheduler.advance(by: debounce)
        try await settle()
        await puller.pullToHead(reason: "verify")
        try await settle()
    }

    /// The fixture every pin shares: X on the server and on the device at
    /// s0; the restore fetch reads it; a peer then writes X and the device
    /// pulls that write before the user applies. Returns (coordinator, s0,
    /// the peer's seq).
    private func fetchThenPullPeerEdit(_ x: Event) async throws -> (RestoreCoordinator, Int64, Int64) {
        let s0 = try XCTUnwrap(server.seed(table: "events", rows: [row(x)])[x.id.uuidString])
        await puller.pullToHead()
        XCTAssertEqual(entry(x)?.seq, s0, "fixture: the device holds X at s0")

        let c = coordinator()
        try await fetch(c)
        let peerSeq = server.writeDirectly(table: "events", key: x.id.uuidString, data: ["note": "peer"])
        await puller.pullToHead()
        XCTAssertEqual(local(x.id)?.note, "peer", "fixture: the device pulled the peer's edit during the review")
        XCTAssertEqual(entry(x)?.seq, peerSeq, "fixture: the device's baseline names the peer's version")
        XCTAssertGreaterThan(peerSeq, s0)
        return (c, s0, peerSeq)
    }

    // MARK: - Claim 1: keep local, then an edit

    /// Merge keeping local after the device pulled the peer's newer X: the
    /// replay writes X back at the snapshot's s0. The restore's own flush
    /// PATCHes `seq=eq.s0`, gets `[]`, and the verify pass (whose pull no
    /// longer shows X — the cursor is past it) confirms it at s0. The
    /// user's next edit goes the same way: never on the server, clean on
    /// the device, and the peer's next write replaces it with nothing
    /// shelved.
    func testKeepLocalAfterPullingANewerVersion_theNextEditReachesTheServerOrTheShelf() async throws {
        let x = makeEvent("X", note: "v1")
        let (c, s0, peerSeq) = try await fetchThenPullPeerEdit(x)
        try await apply(c, .merge, resolution: .keepLocal)
        // The mechanism, as a plain observation: the entry went back to s0.
        let restoredSeq = entry(x)?.seq
        try await flushAndVerify()

        var mine = try XCTUnwrap(local(x.id))
        mine.note = "mine"
        let patchesBefore = server.requests(.patch).count
        store.updateCalendarEvent(mine)
        try await flushAndVerify()
        XCTAssertGreaterThan(server.requests(.patch).count, patchesBefore, "fixture: the edit's flush sent a PATCH")
        // Read before the peer's next write, which may rightly replace a
        // landed edit.
        let editedClean = entry(x)?.hash == hash(mine)
        let serverAfterEdit = onServer(x)?["note"] as? String

        let laterSeq = server.writeDirectly(table: "events", key: x.id.uuidString, data: ["note": "peer again"])
        await puller.pullToHead()
        XCTAssertEqual(server.seq(table: "events", key: x.id.uuidString), laterSeq)
        let mineShelved = shelved(x.id).contains { $0.row["note"] as? String == "mine" }
        // Recorded, not asserted: a fix may keep the snapshot's seq in the
        // baseline (e.g. by rewinding the cursor instead).
        XCTContext.runActivity(named: "entry after the restore: \(restoredSeq.map(String.init) ?? "nil"); s0=\(s0) peer=\(peerSeq)") { _ in }

        XCTExpectFailure("BUG (hfresh): the replay regresses X's entry to the snapshot's seq under a cursor past the version the device pulled; the edit is confirmed clean at that seq and never sent") {
            XCTAssertFalse(editedClean && serverAfterEdit != "mine",
                           "the edit reads clean while the server holds the peer's version")
            XCTAssertTrue(serverAfterEdit == "mine" || mineShelved || local(x.id)?.note == "mine",
                          "the edit never reached the server, and after the peer's next write it is on no device or shelf")
        }
    }

    // MARK: - Claim 2: keep cloud, or overwrite

    /// Keep cloud after the device pulled the peer's newer X: the device
    /// goes back to the snapshot's older X, reads clean, and no pull from
    /// its cursor brings the newer one back.
    func testKeepCloudAfterPullingANewerVersion_theDeviceConvergesToTheServer() async throws {
        let x = makeEvent("X", note: "v1")
        let (c, _, _) = try await fetchThenPullPeerEdit(x)
        try await apply(c, .merge, resolution: .keepCloud)
        XCTAssertEqual(local(x.id)?.note, "v1", "fixture: keep cloud took the snapshot's copy")
        try await flushAndVerify()
        // Another row moves the feed, so the puller runs past X again.
        let y = makeEvent("Y")
        server.seed(table: "events", rows: [row(y)])
        await puller.pullToHead()
        XCTAssertNotNil(local(y.id), "fixture: the puller still runs")

        XCTExpectFailure("BUG (hfresh): keep cloud leaves the device on the snapshot's older version, clean, while the server holds the newer one") {
            XCTAssertEqual(local(x.id)?.note, onServer(x)?["note"] as? String, "device and server disagree on X for good")
        }
    }

    /// Overwrite after the device pulled a row a peer CREATED during the
    /// review: the snapshot does not carry it, the overwrite drops it and
    /// its entry, and the cursor is already past it. Not an `hfresh` case —
    /// `hfresh` quantifies over the snapshot's rows only — but the same
    /// cause, and the same remedy.
    func testOverwriteAfterPullingARowCreatedDuringTheReview_theRowStaysOnTheDevice() async throws {
        let x = makeEvent("X", note: "v1")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        let c = coordinator()
        try await fetch(c)
        let z = makeEvent("Z, made by a peer during the review")
        server.seed(table: "events", rows: [row(z)])
        await puller.pullToHead()
        XCTAssertNotNil(local(z.id), "fixture: the device pulled the peer's new row during the review")

        try await apply(c, .cloudOverwritesLocal)
        try await flushAndVerify()
        let y = makeEvent("Y")
        server.seed(table: "events", rows: [row(y)])
        await puller.pullToHead()
        XCTAssertNotNil(local(y.id), "fixture: the puller still runs")
        XCTAssertNotNil(onServer(z), "fixture: the server still holds Z")

        XCTExpectFailure("BUG (same cause, outside hfresh): the overwrite drops a row created after the fetch that the device had already pulled; no pull brings it back") {
            XCTAssertNotNil(local(z.id), "a live server row is missing on the device for good")
        }
    }

    // MARK: - Claim 3: a delete during the review

    /// Merge after the device pulled a peer's delete of X: to `mergeByID`
    /// X is a row only the cloud has, so it comes back, clean at the
    /// snapshot's seq, under a cursor past the tombstone.
    func testMergeAfterPullingAPeerDeleteDuringTheReview_theRowStaysDeleted() async throws {
        let x = makeEvent("X", note: "v1")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        let c = coordinator()
        try await fetch(c)
        XCTAssertNotNil(server.tombstoneDirectly(table: "events", key: x.id.uuidString))
        await puller.pullToHead()
        XCTAssertNil(local(x.id), "fixture: the device pulled the peer's delete during the review")

        try await apply(c, .merge, resolution: .keepLocal)
        try await flushAndVerify()
        let y = makeEvent("Y")
        server.seed(table: "events", rows: [row(y)])
        await puller.pullToHead()
        XCTAssertNotNil(local(y.id), "fixture: the puller still runs")
        XCTAssertNotNil(server.row(table: "events", key: x.id.uuidString)?.deletedAt, "fixture: the server holds X deleted")

        XCTExpectFailure("BUG (hfresh): the merge brings back a row whose delete the device had already pulled; it reads clean and stays") {
            XCTAssertNil(local(x.id), "a row deleted on the server is live on the device for good")
        }
    }

    // MARK: - Control: the same writes, the peer's edit before the fetch

    /// `hfresh` holds: the peer's edit lands and is pulled BEFORE the
    /// fetch, so the snapshot carries it. The same keep-local merge, the
    /// same edit, the same later peer write; the unwrapped assertions the
    /// first pin wraps all hold.
    func testControl_thePeerEditBeforeTheFetch_theEditLands() async throws {
        let x = makeEvent("X", note: "v1")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        let peerSeq = server.writeDirectly(table: "events", key: x.id.uuidString, data: ["note": "peer"])
        await puller.pullToHead()
        XCTAssertEqual(local(x.id)?.note, "peer")

        let c = coordinator()
        try await fetch(c)
        try await apply(c, .merge, resolution: .keepLocal)
        let restoredSeq = entry(x)?.seq
        try await flushAndVerify()

        var mine = try XCTUnwrap(local(x.id))
        mine.note = "mine"
        store.updateCalendarEvent(mine)
        try await flushAndVerify()
        let editedClean = entry(x)?.hash == hash(mine)
        let serverAfterEdit = onServer(x)?["note"] as? String

        XCTAssertGreaterThanOrEqual(restoredSeq ?? 0, peerSeq)
        XCTAssertFalse(editedClean && serverAfterEdit != "mine")
        XCTAssertEqual(serverAfterEdit, "mine", "the edit reached the server")
    }
}
