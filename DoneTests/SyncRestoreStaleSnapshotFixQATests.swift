//
//  SyncRestoreStaleSnapshotFixQATests.swift
//  DoneTests
//
//  Independent QA for fix/restore-stale-snapshot (b73289ba): the fetch's
//  cursor mark, the refusal at the apply, the rewind, and the puller
//  abandoning a chain that began before the rewind. Each test here kills a
//  QA mutant the implementer's suite let through (round-2 report):
//
//  - a chain parked at its EPOCH read, not its page read, when the rewind
//    lands (the implementer's chain test parks the page read only);
//  - another account that knows the same server epoch (the implementer's
//    account test signs out, which the epoch check would also refuse);
//  - a sign-out while the loading frame is awaited (the check must run
//    after the wait);
//  - a fetch taken before the device first saw the server's epoch (nil →
//    set is a first sighting and must apply);
//  - the replayed baseline is on disk, with the generations the rewound
//    cursor expects, when the apply returns;
//  - a fetch with no cursor: the rewind goes to the start of the feed and
//    the restore's own pull runs at once.
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreStaleSnapshotFixQATests: SyncRestoreAndSwitchTestCase {

    private func coordinator(wait: @escaping @MainActor () async -> Void = {}) -> RestoreCoordinator {
        let c = RestoreCoordinator(waitForLoadingFrame: wait)
        c.configure(syncService: service, eventStore: store, eventTypeStore: device.types,
                    skillStore: device.skills, preferenceStore: device.prefs)
        return c
    }

    @discardableResult
    private func fetch(_ c: RestoreCoordinator) async throws -> RestoreSnapshot {
        await c.startFetch()
        guard case .ready(let snapshot) = c.phase else {
            throw FixtureFailure(description: "the restore fetch did not finish: \(c.phase)")
        }
        return snapshot
    }

    private func keepCloud(_ c: RestoreCoordinator) async throws {
        await c.prepareMerge()
        guard case .mergeReview = c.phase else {
            throw FixtureFailure(description: "fixture: X conflicts, got \(c.phase)")
        }
        await c.applyMerge(resolution: .keepCloud)
    }

    private func local(_ id: UUID) -> Event? {
        store.rawCalendarEvents.first { $0.id == id }
    }

    private func trailLines(_ needle: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init).filter { $0.contains(needle) }
    }

    private func seedAndPull(_ x: Event) async throws -> Int64 {
        let s0 = try XCTUnwrap(server.seed(table: "events", rows: [row(x)])[x.id.uuidString])
        await puller.pullToHead()
        XCTAssertEqual(entry(x)?.seq, s0, "fixture: the device holds X at its seq")
        return s0
    }

    private func peerEditPulled(_ x: Event, note: String) async throws -> Int64 {
        let seq = server.writeDirectly(table: "events", key: x.id.uuidString, data: ["note": note])
        await puller.pullToHead()
        XCTAssertEqual(local(x.id)?.note, note, "fixture: the device pulled the peer's edit")
        XCTAssertEqual(service.cursor.value, seq, "fixture: the cursor is past the peer's edit")
        return seq
    }

    // MARK: - The chain

    /// The chain asked for its page before the rewind and got it; the
    /// rewind lands while it awaits the epoch read. The page must not be
    /// applied: its commit (`max(old, seq)`) would carry the cursor past the
    /// peer's edit again. Kills QA mutant "no guard after the epoch read".
    func testAChainParkedAtItsEpochReadWhenTheRewindLands_appliesNothingAndTheRerunPullsFromTheRewoundCursor() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let c = coordinator()
        try await fetch(c)
        let peerSeq = try await peerEditPulled(x, note: "peer")
        let y = makeEvent("Y, a peer's row after that")
        let ySeq = try XCTUnwrap(server.seed(table: "events", rows: [row(y)])[y.id.uuidString])
        DiagnosticTrail.clear()

        var hold = true
        server.holdWhen = { verb, _ in verb == .epoch && hold }
        puller.requestPull(reason: "doorbell")
        try await syncEventually("the chain read its page and parked at the epoch read") { self.server.heldCount == 1 }
        XCTAssertEqual(server.requests(.pull).last?.baseSeq, peerSeq, "fixture: the page was asked for past the peer's edit")
        XCTAssertNil(local(y.id), "fixture: the parked chain has applied nothing yet")

        try await keepCloud(c)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertEqual(local(x.id)?.note, "v1", "fixture: keep cloud took the snapshot's X")
        XCTAssertEqual(service.cursor.value, s0, "fixture: the rewind ran")

        hold = false
        server.releaseAll()
        try await syncEventually("the rerun brought the peer's X back") { self.local(x.id)?.note == "peer" }
        try await syncEventually("and reached head past Y") { self.service.cursor.value == ySeq }
        XCTAssertEqual(trailLines("status=rewound").count, 1, "the parked chain did not give up")
        XCTAssertNotNil(local(y.id))
        XCTAssertEqual(entry(x)?.seq, peerSeq)
    }

    /// The same with an EMPTY page (the device was at head when the chain
    /// asked): no page guard comes after the epoch read, so only the guard
    /// there keeps the chain from ending `head` and running its head work
    /// (pending-verify, the flush, I1) on a pull that never covered the
    /// rewound range. With a non-empty page the guard after the ancestry
    /// read shadows it (QA mutant survived the test above).
    func testAChainParkedAtItsEpochReadWithAnEmptyPage_givesUpWithoutHeadWork() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let c = coordinator()
        try await fetch(c)
        let peerSeq = try await peerEditPulled(x, note: "peer")
        final class Lines { var all: [String] = [] }
        let traced = Lines()
        puller.trace = { traced.all.append($0) }
        DiagnosticTrail.clear()

        var hold = true
        server.holdWhen = { verb, _ in verb == .epoch && hold }
        puller.requestPull(reason: "doorbell")
        try await syncEventually("the chain read an empty page and parked at the epoch read") { self.server.heldCount == 1 }
        XCTAssertEqual(server.requests(.pull).last?.baseSeq, peerSeq, "fixture: the page was asked for from the head")

        try await keepCloud(c)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertEqual(service.cursor.value, s0, "fixture: the rewind ran")

        hold = false
        server.releaseAll()
        try await syncEventually("the rerun brought the peer's X back") { self.local(x.id)?.note == "peer" }
        XCTAssertEqual(trailLines("sync.pull reason=doorbell pages=0 rows=0 status=rewound").count, 1,
                       "the parked chain ended as if at head: \(traced.all)")
        XCTAssertEqual(traced.all.first, "chain doorbell rewound", "the parked chain's first trace: \(traced.all)")
    }

    // MARK: - Refusals the implementer's tests reach only through another check

    /// Another account whose cursor key records the same server epoch (it
    /// synced on this device before): only the account check refuses. Kills
    /// QA mutant "refuse only when signed out", which the implementer's
    /// sign-out test cannot tell from the real check.
    func testAnApplyAfterSwitchingToAnAccountThatKnowsTheSameEpochIsRefusedAndChangesNothing() async throws {
        let x = makeEvent("X", note: "v1")
        _ = try await seedAndPull(x)
        let c = coordinator()
        try await fetch(c)
        let peerSeq = try await peerEditPulled(x, note: "peer")
        let l = makeEvent("L, local only")
        store.addCalendarEvent(l)
        let epoch = try XCTUnwrap(service.cursor.epoch)
        let uidB = "99999999-aaaa-4bbb-8ccc-dddddddddddd"
        SyncCursorStore(defaults: defaults, userId: uidB)
            .recordEpoch(epoch, baseline: SyncBaselineStore(defaults: defaults, userId: uidB))

        device.auth.signOut()
        try await syncEventually("signed out") { self.service.userId.isEmpty }
        XCTAssertTrue(device.signIn(uidB), "fixture: B signed in")
        try await syncEventually("B's session began") { self.service.userId == uidB }
        XCTAssertEqual(service.cursor.epoch, epoch, "fixture: B's cursor key records the epoch the fetch saw")
        DiagnosticTrail.clear()

        await c.applyOverwrite()

        XCTAssertEqual(c.phase, .failed(L(.restoreSnapshotOutdated)), "A's snapshot was applied under B")
        XCTAssertEqual(local(x.id)?.note, "peer", "the refused overwrite replaced X")
        XCTAssertNotNil(local(l.id), "the refused overwrite dropped the local-only row")
        XCTAssertEqual(trailLines("restore REFUSED reason=account").count, 1)
        XCTAssertEqual(trailLines("restore APPLY").count, 0)
        XCTAssertEqual(SyncCursorStore(defaults: defaults, userId: uid).value, peerSeq, "A's stored cursor moved")
        XCTAssertNil(SyncCursorStore(defaults: defaults, userId: uidB).value, "B's cursor was written")
    }

    /// The sign-out lands while the loading frame is awaited. The check
    /// must come after the wait: before it, the apply would run on a
    /// signed-out engine. Kills QA mutant "check before the wait".
    func testASignOutWhileTheLoadingFrameIsAwaitedIsRefusedAndChangesNothing() async throws {
        let x = makeEvent("X", note: "v1")
        _ = try await seedAndPull(x)
        final class Flag { var on = false }
        let waited = Flag()
        let c = coordinator(wait: { [unowned self] in
            waited.on = true
            self.device.auth.signOut()
            try? await syncEventually("signed out during the wait") { self.service.userId.isEmpty }
        })
        try await fetch(c)
        _ = try await peerEditPulled(x, note: "peer")
        let l = makeEvent("L, local only")
        store.addCalendarEvent(l)
        XCTAssertFalse(service.userId.isEmpty, "fixture: signed in when the apply starts")
        DiagnosticTrail.clear()

        await c.applyOverwrite()

        XCTAssertTrue(waited.on, "fixture: the apply awaited the loading frame")
        XCTAssertEqual(c.phase, .failed(L(.restoreSnapshotOutdated)), "the apply was not refused")
        XCTAssertEqual(local(x.id)?.note, "peer", "the refused overwrite replaced X")
        XCTAssertNotNil(local(l.id), "the refused overwrite dropped the local-only row")
        XCTAssertEqual(trailLines("restore APPLY").count, 0, "the restore ran")
    }

    /// The fetch ran before this device had ever recorded the server's
    /// epoch (a cursor key from before epochs); the pull during the review
    /// records it. That is a first sighting, which resets nothing: the
    /// apply goes ahead. Kills QA mutant "a nil epoch at the fetch refuses".
    func testAFetchTakenBeforeTheFirstEpochSightingStillApplies() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        defaults.set(NSNumber(value: s0), forKey: SyncBaselineStore.key(userId: uid, table: SyncCursorStore.tableLabel))
        XCTAssertNil(service.cursor.epoch, "fixture: no epoch recorded")
        XCTAssertEqual(service.cursor.value, s0, "fixture: the cursor itself is kept")
        let c = coordinator()
        let snapshot = try await fetch(c)
        XCTAssertNotNil(snapshot.fetchMark, "fixture: the fetch took its mark")
        XCTAssertNil(snapshot.fetchMark?.epoch, "fixture: the mark carries no epoch")
        let peerSeq = try await peerEditPulled(x, note: "peer")
        XCTAssertNotNil(service.cursor.epoch, "fixture: the review's pull recorded the server's epoch")
        DiagnosticTrail.clear()

        try await keepCloud(c)

        guard case .finished = c.phase else { return XCTFail("a first epoch sighting refused the restore: \(c.phase)") }
        XCTAssertEqual(trailLines("restore REFUSED").count, 0)
        try await syncEventually("the restore's pull brought the peer's X back") { self.local(x.id)?.note == "peer" }
        XCTAssertEqual(entry(x)?.seq, peerSeq)
    }

    // MARK: - What a relaunch right after the apply would load

    /// The baseline the replay wrote, and the generations the rewound
    /// cursor expects of it, are on disk when the apply returns: a relaunch
    /// right then keeps the cursor and the restored entries. Kills QA mutant
    /// "the rewind does not persist the baseline" (the cursor would be
    /// dropped and the restored entries lost — after a large restore, every
    /// row the restore added would read as never sent).
    func testTheReplayedBaselineAndItsGenerationsAreOnDiskWhenTheApplyReturns() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let c = coordinator()
        try await fetch(c)
        _ = try await peerEditPulled(x, note: "peer")

        try await keepCloud(c)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        let inMemory = try XCTUnwrap(entry(x))
        XCTAssertEqual(inMemory.seq, s0, "fixture: the replay wrote the snapshot's version")

        let onDisk = SyncBaselineStore(defaults: defaults, userId: uid)
        let loaded = onDisk.entry(table: "calendar_events", id: x.id.uuidString)
        XCTAssertEqual(loaded?.hash, inMemory.hash, "the replayed baseline is not on disk")
        XCTAssertEqual(loaded?.seq, inMemory.seq, "the replayed baseline is not on disk")
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        cursor.validate(against: onDisk)
        XCTAssertEqual(cursor.value, s0, "a relaunch now would drop the rewound cursor")
    }

    // MARK: - No cursor at the fetch

    /// The fetch began with no cursor (dropped at this launch, or never
    /// set): the rewind goes to the start of the feed, and the restore's
    /// own pull runs at once. Kills QA mutant "pull only when both cursors
    /// are numbers and the new one is lower".
    func testAFetchWithNoCursorRewindsToTheStartAndPullsAtOnce() async throws {
        let x = makeEvent("X", note: "v1")
        _ = try await seedAndPull(x)
        service.cursor.value = nil
        let c = coordinator()
        let snapshot = try await fetch(c)
        XCTAssertNotNil(snapshot.fetchMark, "fixture: the fetch took its mark")
        XCTAssertNil(snapshot.fetchMark?.cursor, "fixture: with no cursor")
        let peerSeq = try await peerEditPulled(x, note: "peer")
        DiagnosticTrail.clear()

        try await keepCloud(c)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertEqual(local(x.id)?.note, "v1", "fixture: keep cloud took the snapshot's X")
        XCTAssertNil(service.cursor.value, "the rewind did not go to the start of the feed")

        try await syncEventually("the restore's own pull brought the peer's X back") { self.local(x.id)?.note == "peer" }
        try await syncEventually("and reached head") { self.service.cursor.value == peerSeq }
    }
}
