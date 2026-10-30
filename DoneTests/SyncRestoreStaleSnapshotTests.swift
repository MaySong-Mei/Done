//
//  SyncRestoreStaleSnapshotTests.swift
//  DoneTests
//
//  "Restore from Cloud" applied over a snapshot older than what the device
//  pulled while the user reviewed it (fix/restore-stale-snapshot; QA's pins
//  are SyncRestoreStaleSnapshotQATests). The fix, tested here:
//
//  - the fetch records the cursor and what it is a position in (account,
//    the cursor key's epoch, the erase count) before its first read
//    (`RestoreFetchMark`);
//  - the apply refuses, mutating nothing, when any of that changed;
//  - otherwise `markRestoreCompleted` takes the cursor back to the recorded
//    position, never forward, ordered so a lost write drops the cursor
//    (`SyncCursorStore.rewind`), and asks for a pull at once;
//  - a chain that began before the rewind gives up instead of committing
//    past it;
//  - the rows the rewind re-delivers that the device already holds change
//    nothing.
//
//  The coordinator runs with no frame wait: what is under test happens
//  after it.
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreStaleSnapshotTests: SyncRestoreAndSwitchTestCase {

    private func coordinator() -> RestoreCoordinator {
        let c = RestoreCoordinator(waitForLoadingFrame: {})
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

    private func local(_ id: UUID) -> Event? {
        store.rawCalendarEvents.first { $0.id == id }
    }

    private func trailLines(_ needle: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init).filter { $0.contains(needle) }
    }

    /// X on the server and on the device; returns its seq, which is then
    /// also the device's cursor.
    private func seedAndPull(_ x: Event) async throws -> Int64 {
        let s0 = try XCTUnwrap(server.seed(table: "events", rows: [row(x)])[x.id.uuidString])
        await puller.pullToHead()
        XCTAssertEqual(entry(x)?.seq, s0, "fixture: the device holds X at its seq")
        XCTAssertEqual(service.cursor.value, s0, "fixture: the cursor is at X")
        return s0
    }

    /// A peer's edit of X that the device pulls; returns its seq.
    private func peerEditPulled(_ x: Event, note: String) async throws -> Int64 {
        let seq = server.writeDirectly(table: "events", key: x.id.uuidString, data: ["note": note])
        await puller.pullToHead()
        XCTAssertEqual(local(x.id)?.note, note, "fixture: the device pulled the peer's edit")
        XCTAssertEqual(service.cursor.value, seq, "fixture: the cursor is past the peer's edit")
        return seq
    }

    // MARK: - The mark

    /// The fetch's first read is parked while the device pulls a peer's
    /// edit: the mark still names the cursor from before the read, not the
    /// one the read ran under. Taken after the first read, it would name a
    /// position past a version the snapshot may not carry.
    func testTheMarkIsTheCursorBeforeTheFetchsFirstRead() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let c = coordinator()
        server.holdWhen = { verb, table in verb == .fetchAll && table == "events" }
        let fetching = Task { await c.startFetch() }
        try await syncEventually("the fetch is parked on its first read") { self.server.heldCount == 1 }
        let peerSeq = try await peerEditPulled(x, note: "peer")
        server.holdWhen = nil
        server.releaseAll()
        await fetching.value

        guard case .ready(let snapshot) = c.phase else { return XCTFail("the fetch did not finish: \(c.phase)") }
        let mark = try XCTUnwrap(snapshot.fetchMark, "a fetched snapshot carries its mark")
        XCTAssertEqual(mark.cursor, s0, "the mark is the cursor before the first read, not \(peerSeq)")
        XCTAssertEqual(mark.userId, uid)
        XCTAssertNotNil(mark.epoch, "fixture: the session's first pull recorded the epoch")
        XCTAssertEqual(mark.epoch, service.cursor.epoch)
        XCTAssertEqual(snapshot.calendarEvents.first { $0.id == x.id }?.note, "peer",
                       "fixture: the read itself ran after the peer's edit")
    }

    // MARK: - The rewind and the pull it asks for

    /// Keep cloud after the device pulled a peer's newer X: the apply takes
    /// the cursor back to the fetch's position and asks for a pull, which —
    /// with no pull asked for by the test, no poll and no doorbell — brings
    /// the peer's version back.
    func testKeepCloud_theCursorGoesBackToTheFetchAndTheRestoresOwnPullBringsThePeersVersion() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let c = coordinator()
        try await fetch(c)
        let peerSeq = try await peerEditPulled(x, note: "peer")
        DiagnosticTrail.clear()

        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: X conflicts, got \(c.phase)") }
        await c.applyMerge(resolution: .keepCloud)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertEqual(trailLines("sync.cursor.restore_rewind from=\(peerSeq) to=\(s0)").count, 1,
                       "the apply moves the cursor from the peer's edit back to the fetch's position")

        try await syncEventually("the restore's own pull brought back the peer's version") {
            self.local(x.id)?.note == "peer"
        }
        try await syncEventually("that pull ran to head") { self.service.cursor.value == peerSeq }
        XCTAssertEqual(entry(x), SyncBaselineEntry(hash: hash(try XCTUnwrap(local(x.id))), seq: peerSeq),
                       "X reads clean at the server's version")
        XCTAssertEqual(trailLines("sync.pull reason=restore").count, 1, "one pull, asked for by the restore")
        XCTAssertTrue(shelved(x.id).isEmpty, "keep cloud left nothing local to shelve")
    }

    /// Nothing pulled between the fetch and the apply: the cursor is where
    /// the fetch began, the rewind leaves it there, and the restore asks for
    /// no pull — the snapshot replaced no version the device had pulled.
    /// The pull a moved cursor asks for: `testKeepCloud_…`.
    func testACursorThatDidNotMoveAsksForNoPull() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let c = coordinator()
        try await fetch(c)
        let pullsBefore = server.requests(.pull).count
        DiagnosticTrail.clear()

        await c.applyOverwrite()
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        try await settle()

        XCTAssertEqual(trailLines("sync.cursor.restore_rewind from=\(s0) to=\(s0)").count, 1,
                       "positive control: the rewind ran and left the cursor")
        XCTAssertEqual(server.requests(.pull).count, pullsBefore, "the restore asked for a pull it owed nothing to")
        XCTAssertEqual(service.cursor.value, s0)
    }

    /// A chain that asked for a page from its own (later) cursor before the
    /// rewind, and gets the answer after it: the page is not applied, the
    /// chain ends `rewound`, and the rerun pulls from the rewound cursor.
    /// Applied, its commit (`max(old, seq)`) would have put the cursor past
    /// the peer's edit of X again, and nothing would ever re-deliver it.
    func testAChainThatBeganBeforeTheRewindDoesNotCommitPastIt() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let c = coordinator()
        try await fetch(c)
        let peerSeq = try await peerEditPulled(x, note: "peer")
        let y = makeEvent("Y, a peer's row after that")
        let ySeq = try XCTUnwrap(server.seed(table: "events", rows: [row(y)])[y.id.uuidString])
        XCTAssertGreaterThan(ySeq, peerSeq)
        DiagnosticTrail.clear()

        var holdPulls = true
        server.holdWhen = { verb, _ in verb == .pull && holdPulls }
        puller.requestPull(reason: "doorbell")
        try await syncEventually("the chain asked for its page from its own cursor") { self.server.heldCount == 1 }
        XCTAssertEqual(server.requests(.pull).last?.baseSeq, peerSeq, "fixture: the parked page was asked for past the peer's edit")

        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: X conflicts, got \(c.phase)") }
        await c.applyMerge(resolution: .keepCloud)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertEqual(local(x.id)?.note, "v1", "fixture: keep cloud took the snapshot's X")
        XCTAssertEqual(service.cursor.value, s0, "fixture: the parked chain has not run; the cursor is the fetch's")

        holdPulls = false
        server.releaseAll()
        try await syncEventually("the rerun brought back the peer's version of X") { self.local(x.id)?.note == "peer" }
        try await syncEventually("and reached head past Y") { self.service.cursor.value == ySeq }

        XCTAssertEqual(trailLines("sync.pull reason=doorbell pages=0 rows=0 status=rewound").count, 1,
                       "the parked chain applied nothing and gave up")
        XCTAssertTrue(server.requests(.pull).contains { $0.baseSeq == s0 }, "the rerun pulled from the rewound cursor")
        XCTAssertNotNil(local(y.id))
        XCTAssertEqual(entry(x)?.seq, peerSeq)
    }

    // MARK: - Re-delivery of what the device already holds

    /// The rewind re-delivers every row written above the fetch's position.
    /// Here those are rows the device already holds at the very version the
    /// re-delivery carries: Z, written after the mark was taken but before
    /// the fetch read it (the snapshot carries Z at its seq), and W, made
    /// during the review and kept by the merge as local-only. Both come
    /// back through the feed (the pull line counts them) and change
    /// nothing: no local row, no baseline entry, no shelf line, no write.
    func testReDeliveringRowsTheDeviceAlreadyHoldsChangesNothing() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let c = coordinator()
        server.holdWhen = { verb, table in verb == .fetchAll && table == "events" }
        let fetching = Task { await c.startFetch() }
        try await syncEventually("the fetch is parked on its first read") { self.server.heldCount == 1 }
        let z = makeEvent("Z, before the read")
        let zSeq = try XCTUnwrap(server.seed(table: "events", rows: [row(z)])[z.id.uuidString])
        await puller.pullToHead()
        XCTAssertNotNil(local(z.id), "fixture: the device pulled Z")
        server.holdWhen = nil
        server.releaseAll()
        await fetching.value
        guard case .ready(let snapshot) = c.phase else { return XCTFail("the fetch did not finish: \(c.phase)") }
        XCTAssertEqual(snapshot.fetchMark?.cursor, s0)
        XCTAssertEqual(snapshot.cloudSeqs[SyncBaselineKey(table: "calendar_events", id: z.id.uuidString)], zSeq,
                       "fixture: the snapshot carries Z at a seq above the mark")

        let w = makeEvent("W, during the review")
        let wSeq = try XCTUnwrap(server.seed(table: "events", rows: [row(w)])[w.id.uuidString])
        await puller.pullToHead()
        XCTAssertNotNil(local(w.id), "fixture: the device pulled W")

        let rowsBefore = [x, z, w].map { local($0.id) }
        let entriesBefore = [x, z, w].map { entry($0) }
        XCTAssertFalse(entriesBefore.contains(nil), "fixture: every row has a baseline entry")
        let writesBefore = writes().count
        DiagnosticTrail.clear()

        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: W is local-only, so the merge is reviewed; got \(c.phase)") }
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertEqual(trailLines("sync.cursor.restore_rewind from=\(wSeq) to=\(s0)").count, 1)
        try await syncEventually("the restore's pull reached head") { self.service.cursor.value == wSeq }
        scheduler.advance(by: debounce)
        try await settle()

        XCTAssertEqual(trailLines("sync.pull reason=restore pages=1 rows=2 status=head").count, 1,
                       "positive control: Z and W really were re-delivered")
        XCTAssertEqual([x, z, w].map { local($0.id) }, rowsBefore, "a re-delivered row changed a local row")
        XCTAssertEqual([x, z, w].map { entry($0) }, entriesBefore, "a re-delivered row changed a baseline entry")
        XCTAssertTrue(([x, z, w].flatMap { shelved($0.id) }).isEmpty, "a re-delivered row was shelved")
        XCTAssertEqual(writes(after: writesBefore).map { "\($0.verb) \($0.table)" }, [],
                       "the restore and its re-delivery sent a write")
    }

    // MARK: - Refusals

    /// The device after an overwrite would differ from now in both
    /// directions: X back to the snapshot's v1, and L — a row the snapshot
    /// does not carry — gone. A refused apply leaves both.
    private func overwriteFixture() async throws -> (x: Event, l: Event, c: RestoreCoordinator, peerSeq: Int64) {
        let x = makeEvent("X", note: "v1")
        _ = try await seedAndPull(x)
        let c = coordinator()
        try await fetch(c)
        let peerSeq = try await peerEditPulled(x, note: "peer")
        let l = makeEvent("L, local only")
        store.addCalendarEvent(l)
        return (x, l, c, peerSeq)
    }

    private func assertRefused(_ c: RestoreCoordinator, reason: String, x: Event, l: Event,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.phase, .failed(L(.restoreSnapshotOutdated)), "the apply was not refused", file: file, line: line)
        XCTAssertEqual(local(x.id)?.note, "peer", "the refused overwrite replaced X", file: file, line: line)
        XCTAssertNotNil(local(l.id), "the refused overwrite dropped the local-only row", file: file, line: line)
        XCTAssertEqual(trailLines("restore REFUSED reason=\(reason)").count, 1, file: file, line: line)
        XCTAssertEqual(trailLines("restore APPLY").count, 0, "the restore ran", file: file, line: line)
        XCTAssertEqual(trailLines("sync.cursor.restore_rewind").count, 0, "the cursor moved", file: file, line: line)
    }

    func testAnApplyAfterTheAccountSignedOutIsRefusedAndChangesNothing() async throws {
        let (x, l, c, peerSeq) = try await overwriteFixture()
        device.auth.signOut()
        try await syncEventually("the engine ended the session") { self.service.userId.isEmpty }
        DiagnosticTrail.clear()

        await c.applyOverwrite()

        assertRefused(c, reason: "account", x: x, l: l)
        XCTAssertEqual(SyncCursorStore(defaults: defaults, userId: uid).value, peerSeq,
                       "the account's stored cursor moved")
    }

    func testAnApplyAfterTheServerEpochWasResetIsRefusedAndChangesNothing() async throws {
        let (x, l, c, _) = try await overwriteFixture()
        let fetchedEpoch = service.cursor.epoch
        server.reenable()
        server.unpause()
        await puller.pullToHead()
        XCTAssertNotNil(fetchedEpoch)
        XCTAssertNotEqual(service.cursor.epoch, fetchedEpoch, "fixture: the device took the server's new epoch")
        XCTAssertEqual(local(x.id)?.note, "peer", "fixture: the catch-up kept X")
        let cursorBefore = service.cursor.value
        DiagnosticTrail.clear()

        await c.applyOverwrite()

        assertRefused(c, reason: "epoch", x: x, l: l)
        XCTAssertEqual(service.cursor.value, cursorBefore)
    }

    func testAnApplyAfterAnEraseIsRefusedAndChangesNothing() async throws {
        try await LocalDataEraseEpoch.withIsolatedEpoch {
            let (x, l, c, peerSeq) = try await overwriteFixture()
            LocalDataEraseEpoch.bump()
            DiagnosticTrail.clear()

            await c.applyOverwrite()

            assertRefused(c, reason: "erase", x: x, l: l)
            XCTAssertEqual(service.cursor.value, peerSeq)
        }
    }

    /// The positive control for the three refusals: the same fixture with
    /// nothing changed applies, and the overwrite does what it says.
    func testControl_theSameOverwriteWithNothingChangedApplies() async throws {
        let (x, l, c, _) = try await overwriteFixture()
        DiagnosticTrail.clear()

        await c.applyOverwrite()

        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertNil(local(l.id), "the overwrite dropped the local-only row")
        XCTAssertEqual(trailLines("restore REFUSED").count, 0)
        XCTAssertEqual(trailLines("restore APPLY").count, 1)
        // The overwrite took X back to v1; the restore's pull brings the
        // peer's version back.
        try await syncEventually("the restore's pull brought back the peer's X") { self.local(x.id)?.note == "peer" }
    }

    /// `markRestoreCompleted` reached without the coordinator's check (its
    /// other callers): a mark that no longer matches replays nothing into
    /// the baseline, in memory or on disk, and moves no cursor. X's entry
    /// names the peer's version the device pulled; a replay would have put
    /// the snapshot's older version there.
    func testMarkRestoreCompletedWithAMarkThatNoLongerMatchesTouchesNeitherBaselineNorCursor() async throws {
        let x = makeEvent("X", note: "v1")
        let s0 = try await seedAndPull(x)
        let snapshot = try await service.fetchRestoreSnapshot()
        XCTAssertEqual(snapshot.cloudSeqs[SyncBaselineKey(table: "calendar_events", id: x.id.uuidString)], s0,
                       "fixture: the snapshot carries X at its first version")
        let peerSeq = try await peerEditPulled(x, note: "peer")
        let entriesBefore = service.baseline.entries(table: "calendar_events")
        XCTAssertEqual(entriesBefore[x.id.uuidString]?.seq, peerSeq, "fixture: X's entry names the peer's version")
        try LocalDataEraseEpoch.withIsolatedEpoch {
            LocalDataEraseEpoch.bump()
            DiagnosticTrail.clear()
            service.markRestoreCompleted(eventStore: store, eventTypeStore: device.types, skillStore: device.skills,
                                         snapshot: snapshot, strategy: .merge)
            XCTAssertEqual(trailLines("restore.replay_skipped reason=erase").count, 1)
            XCTAssertEqual(service.baseline.entries(table: "calendar_events"), entriesBefore,
                           "the snapshot from before the erase was replayed into the baseline")
            XCTAssertEqual(SyncBaselineStore(defaults: defaults, userId: uid).entries(table: "calendar_events"), entriesBefore,
                           "the snapshot from before the erase was persisted as the baseline")
            XCTAssertEqual(service.cursor.value, peerSeq, "the cursor moved under a mark from before an erase")
        }
    }

    // MARK: - A fetch that saw no epoch

    /// A device whose first pull has not read the server's epoch yet: the
    /// launch chain is parked on that read.
    private func deviceBeforeItsFirstEpochRead() async throws -> SyncSwitchTestDevice {
        let phone = SyncSwitchTestDevice(server: server, uid: uid, start: Self.t0, switchOnAtAttach: false)
        phone.defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        server.holdWhen = { verb, _ in verb == .epoch }
        phone.puller.beginSession(autoPull: false)
        phone.puller.requestPull(reason: "launch")
        try await syncEventually("the first pull waits on its epoch read") { self.server.heldCount == 1 }
        XCTAssertNil(phone.service.cursor.epoch, "fixture: no epoch recorded yet")
        return phone
    }

    private func fetchedWithNoEpoch(on phone: SyncSwitchTestDevice) async throws -> RestoreCoordinator {
        let c = RestoreCoordinator(waitForLoadingFrame: {})
        c.configure(syncService: phone.service, eventStore: phone.store, eventTypeStore: phone.types,
                    skillStore: phone.skills, preferenceStore: phone.prefs)
        await c.startFetch()
        guard case .ready(let snapshot) = c.phase else {
            throw FixtureFailure(description: "the restore fetch did not finish: \(c.phase)")
        }
        XCTAssertNotNil(snapshot.fetchMark, "fixture: a fetched snapshot carries its mark")
        XCTAssertNil(snapshot.fetchMark?.epoch, "fixture: the fetch saw no epoch")
        return c
    }

    /// The fetch ran before the first pull read the server's epoch; during
    /// the review that pull recorded it, and then the server's history was
    /// reset and the device took the reset (every entry stale, the cursor
    /// dropped, a catch-up). The snapshot may be from the old history, and
    /// replaying it would put old-history entries over the reset's stale
    /// markers. The apply is refused and changes nothing. The device cannot
    /// tell this from a first sighting alone, so any epoch recorded since a
    /// fetch that saw none refuses (`restoreApplyRefusal`).
    func testAFetchThatSawNoEpoch_thenTheFirstEpochAndAReset_isRefused() async throws {
        let x = makeEvent("X, before the reset", note: "v1")
        server.seed(table: "events", rows: [row(x)])
        let phone = try await deviceBeforeItsFirstEpochRead()
        defer { phone.tearDown() }
        let c = try await fetchedWithNoEpoch(on: phone)

        server.holdWhen = nil
        server.releaseAll()
        await phone.puller.pullToHead()
        let first = try XCTUnwrap(phone.service.cursor.epoch, "fixture: the first pull recorded the epoch")
        server.reenable()
        server.unpause()
        await phone.puller.pullToHead()
        XCTAssertNotEqual(phone.service.cursor.epoch, first, "fixture: the device took the reset")
        let rowsBefore = phone.store.rawCalendarEvents
        let entriesBefore = phone.service.baseline.entries(table: "calendar_events")
        let cursorBefore = phone.service.cursor.value
        DiagnosticTrail.clear()

        await c.applyOverwrite()

        XCTAssertEqual(c.phase, .failed(L(.restoreSnapshotOutdated)), "the apply was not refused")
        XCTAssertEqual(trailLines("restore REFUSED reason=epoch").count, 1)
        XCTAssertEqual(trailLines("restore APPLY").count, 0, "the restore ran")
        XCTAssertEqual(phone.store.rawCalendarEvents, rowsBefore, "the refused apply changed the store")
        XCTAssertEqual(phone.service.baseline.entries(table: "calendar_events"), entriesBefore,
                       "the refused apply changed the baseline")
        XCTAssertEqual(phone.service.cursor.value, cursorBefore, "the refused apply moved the cursor")
    }

    /// The positive control: the same fetch with no epoch, applied while
    /// the device still has none recorded (the first epoch read is still
    /// parked). Nothing it identifies has changed, and the overwrite runs.
    func testControl_aFetchThatSawNoEpoch_appliedWithNoneRecordedSince_applies() async throws {
        let x = makeEvent("X", note: "v1")
        server.seed(table: "events", rows: [row(x)])
        let phone = try await deviceBeforeItsFirstEpochRead()
        defer { phone.tearDown() }
        let c = try await fetchedWithNoEpoch(on: phone)
        XCTAssertFalse(phone.store.rawCalendarEvents.contains { $0.id == x.id }, "fixture: X is not on the device yet")
        DiagnosticTrail.clear()

        await c.applyOverwrite()

        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertNil(phone.service.cursor.epoch, "fixture: still no epoch recorded")
        XCTAssertEqual(trailLines("restore REFUSED").count, 0)
        XCTAssertTrue(phone.store.rawCalendarEvents.contains { $0.id == x.id }, "the overwrite landed the cloud's X")
    }
}

// MARK: - SyncCursorStore.rewind

@MainActor
final class SyncCursorRewindTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private let uid = "77777777-7777-4777-8777-777777777777"

    override func setUp() {
        super.setUp()
        suiteName = "SyncCursorRewindTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func applyPage(_ baseline: SyncBaselineStore, _ cursor: SyncCursorStore, seq: Int64) {
        baseline.setEntry(SyncBaselineEntry(hash: "h\(seq)", seq: seq), table: "calendar_events", id: "A")
        cursor.commit(seq: seq, baseline: baseline, touched: ["calendar_events"])
    }

    private func relaunchCursor() -> Int64? {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        cursor.validate(against: baseline)
        return cursor.value
    }

    func testRewindTakesTheLowerCursorAndNeverMovesItForward() {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        cursor.recordEpoch("E", baseline: baseline)
        applyPage(baseline, cursor, seq: 10)

        cursor.rewind(to: 5, baseline: baseline)
        XCTAssertEqual(cursor.value, 5)
        cursor.rewind(to: 8, baseline: baseline)
        XCTAssertEqual(cursor.value, 5, "a rewind moved the cursor forward")
        XCTAssertEqual(cursor.epoch, "E", "the epoch survives")
        XCTAssertEqual(relaunchCursor(), 5, "positive control: both writes landed, the cursor is kept")

        cursor.rewind(to: nil, baseline: baseline)
        XCTAssertNil(cursor.value, "a fetch with no cursor rewinds to the start of the feed")
        cursor.rewind(to: 3, baseline: baseline)
        XCTAssertNil(cursor.value, "no cursor stays no cursor")
        XCTAssertEqual(cursor.epoch, "E")
    }

    /// The rewind's cursor write is lost while the baseline's landed (the
    /// per-key reordering survey S11 rules out by construction): the old
    /// cursor, past versions newer than the replayed baseline, must not
    /// survive the next load.
    func testALostRewindWriteDropsTheCursorAtTheNextLoad() {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        applyPage(baseline, cursor, seq: 10)
        let cursorKey = SyncBaselineStore.key(userId: uid, table: SyncCursorStore.tableLabel)
        let before = defaults.object(forKey: cursorKey)

        baseline.setEntry(SyncBaselineEntry(hash: "h-restored", seq: 4), table: "calendar_events", id: "A")
        cursor.rewind(to: 5, baseline: baseline)
        defaults.set(before, forKey: cursorKey)

        XCTAssertNil(relaunchCursor(), "the cursor from before the rewind survived over the replayed baseline")
    }
}
