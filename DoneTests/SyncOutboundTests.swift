//
//  SyncOutboundTests.swift
//  DoneTests
//
//  The outbound half of the sync engine against `SyncFakeServer` (design
//  §6 上传形状 / 删除段 / 单行表的 tombstone / §6.2 pusher rule / §6 示例数据).
//  Every baseline assertion is against the hash of the row AS SENT
//  (`SupabaseSyncService.rowHash(service.eventToRow(...))`), never against
//  anything the fake returned.
//

import XCTest
@testable import Done

@MainActor
final class SyncOutboundTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!
    private var pullRequests = 0
    private let uid = "33333333-3333-3333-3333-333333333333"

    override func setUp() {
        super.setUp()
        suiteName = "SyncOutboundTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
        pullRequests = 0
        service.onNeedsPull = { [weak self] in self?.pullRequests += 1 }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeEvent(_ title: String, note: String = "") -> Event {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Event(title: title, note: note,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
    }

    private func hash(_ event: Event, kind: String = "calendar") -> String {
        SupabaseSyncService.rowHash(service.eventToRow(event, kind: kind))
    }

    private func key(_ event: Event, kind: String = "calendar") -> SyncBaselineKey {
        SyncBaselineKey(table: SupabaseSyncService.eventsBaselineTable(kind: kind), id: event.id.uuidString)
    }

    private func entry(_ event: Event, kind: String = "calendar") -> SyncBaselineEntry? {
        service.baseline.entry(table: SupabaseSyncService.eventsBaselineTable(kind: kind), id: event.id.uuidString)
    }

    private func serverNote(_ event: Event) -> String? {
        server.row(table: "events", key: event.id.uuidString)?.data["note"] as? String
    }

    private func edited(_ event: Event, note: String) -> Event {
        var copy = event
        copy.note = note
        return copy
    }

    private func trailLines(containing needle: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init).filter { $0.contains(needle) }
    }

    // MARK: New rows → ignore-duplicates POST

    func testNewRowGoesOutAsIgnoreDuplicatesPostAndBaselineTakesSeqFromTheResponse() async throws {
        let e = makeEvent("new")

        await service.syncEvents([e], kind: "calendar")

        XCTAssertEqual(server.requests(.insert).count, 1)
        XCTAssertEqual(server.requests(.patch).count, 0)
        XCTAssertEqual(server.requests(.tombstone).count, 0)
        let seq = try XCTUnwrap(server.seq(table: "events", key: e.id.uuidString))
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: hash(e), seq: seq))
        // Persisted, not just in memory.
        let reloaded = SyncBaselineStore(defaults: defaults, userId: uid)
        XCTAssertEqual(reloaded.entry(table: "calendar_events", id: e.id.uuidString), SyncBaselineEntry(hash: hash(e), seq: seq))
    }

    func testCleanRowSendsNothing() async {
        let e = makeEvent("quiet")
        await service.syncEvents([e], kind: "calendar")
        let before = server.requests.count

        await service.syncEvents([e], kind: "calendar")

        XCTAssertEqual(server.requests.count, before)
    }

    func testInsertsGoOutInChunksOfTwenty() async {
        let events = (0..<45).map { makeEvent("e\($0)") }
        await service.syncEvents(events, kind: "calendar")
        let inserts = server.requests(.insert)
        XCTAssertEqual(inserts.map(\.keys.count), [20, 20, 5])
        XCTAssertEqual(events.compactMap { entry($0)?.seq }.count, 45)
    }

    func testRowAlreadyOnTheServerIsOmittedFromTheInsertResponseAndWaitsForItsEcho() async throws {
        let e = makeEvent("already there")
        let seeded = server.seed(table: "events", rows: [service.eventToRow(e, kind: "calendar")])
        let seq = try XCTUnwrap(seeded[e.id.uuidString])

        await service.syncEvents([e], kind: "calendar")

        XCTAssertEqual(server.requests(.insert).count, 1)
        XCTAssertEqual(entry(e), .unknown(seq: nil), "no seq came back, so the baseline cannot claim one; the `?` marks the row as owed a verification (S4)")
        XCTAssertEqual(service.awaitingEcho, [key(e)])
        XCTAssertEqual(service.orphansAfterHeadPull(), [key(e)], "still no seq after a head pull: an orphan to log")

        // The echo arrives (the applier writes base := (h_in, seq)).
        service.baseline.setEntry(SyncBaselineEntry(hash: hash(e), seq: seq), table: "calendar_events", id: e.id.uuidString)
        XCTAssertEqual(service.orphansAfterHeadPull(), [])
        XCTAssertTrue(service.awaitingEcho.isEmpty)
    }

    /// PostgREST renders a uuid column lowercase; the device sent
    /// `UUID.uuidString`. The response row must still find its item, or
    /// every insert lands in awaitingEcho and is re-POSTed each flush.
    func testInsertResponseIdsComeBackLowercaseAndStillSetTheBaselineSeq() async throws {
        let e = makeEvent("case")
        XCTAssertNotEqual(e.id.uuidString, e.id.uuidString.lowercased(), "uuidString is uppercase; the probe sent exactly this")

        await service.syncEvents([e], kind: "calendar")

        let stored = try XCTUnwrap(server.row(table: "events", key: e.id.uuidString))
        let rendered = try XCTUnwrap(server.represent(stored)["id"] as? String)
        XCTAssertEqual(rendered, e.id.uuidString.lowercased())
        XCTAssertNotEqual(rendered, e.id.uuidString, "the fake must disagree with the device on case, like the server does")
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: hash(e), seq: stored.seq))
        XCTAssertTrue(service.awaitingEcho.isEmpty)

        // And the next flush is quiet — no re-POST of a row the server has.
        let before = server.requests.count
        await service.syncEvents([e], kind: "calendar")
        XCTAssertEqual(server.requests.count, before)
    }

    /// Survey S4 / G23: slice 1 dropped the key here ("no baseline entry to
    /// tombstone from") and the delete never reached the server.
    func testRowRemovedLocallyWhileAwaitingItsEchoIsTombstonedAndIsNeverAnOrphan_killsAwaitingEchoDeleteDropped() async throws {
        let e = makeEvent("gone before its echo")
        server.seed(table: "events", rows: [service.eventToRow(e, kind: "calendar")])
        await service.syncEvents([e], kind: "calendar")
        XCTAssertEqual(service.awaitingEcho, [key(e)])

        await service.syncEvents([], kind: "calendar")

        XCTAssertTrue(service.awaitingEcho.isEmpty)
        XCTAssertEqual(service.orphansAfterHeadPull(), [])
        XCTAssertEqual(server.requests(.tombstone).map(\.keys), [[e.id.uuidString]], "the `?` entry is what the delete is sent from")
        XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString))
        XCTAssertNil(entry(e))
    }

    // MARK: Dirty rows with a known seq → conditional PATCH

    func testDirtyRowWithKnownSeqGoesOutAsConditionalPatchOnThatSeq() async throws {
        let e = makeEvent("v1")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        let e2 = edited(e, note: "v2")

        await service.syncEvents([e2], kind: "calendar")

        let patches = server.requests(.patch)
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.baseSeq, s0)
        XCTAssertEqual(patches.first?.keys, [e.id.uuidString])
        XCTAssertEqual((patches.first?.body as? [String: Any])?["user_id"] as? String, uid, "the whole row goes out")
        XCTAssertEqual(serverNote(e), "v2")
        let s1 = try XCTUnwrap(server.seq(table: "events", key: e.id.uuidString))
        XCTAssertGreaterThan(s1, s0)
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: hash(e2), seq: s1))
        XCTAssertTrue(service.pendingVerify.isEmpty)
        XCTAssertEqual(pullRequests, 0)
    }

    func testBaselineHashIsTheHashOfTheRowAsSentNeverOfTheResponseBody() async throws {
        let e = makeEvent("sent")
        await service.syncEvents([e], kind: "calendar")
        let e2 = edited(e, note: "sent v2")
        await service.syncEvents([e2], kind: "calendar")

        let responseRow = try XCTUnwrap(server.row(table: "events", key: e.id.uuidString))
        let responseHash = SupabaseSyncService.rowHash(server.represent(responseRow))
        XCTAssertEqual(entry(e)?.hash, hash(e2))
        XCTAssertNotEqual(entry(e)?.hash, responseHash, "a response carries seq / deleted_at; hashing it would make every row permanently dirty")
    }

    func testEmptyResponseCreatesPendingVerifyElementWithSentSeqSentHashAndPullIssue() async throws {
        let e = makeEvent("v1")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        // Another device wrote X@s1.
        server.writeDirectly(table: "events", key: e.id.uuidString, data: ["note": "c2"])
        service.pullIssueCounter = { 42 }
        let e2 = edited(e, note: "c1")

        await service.syncEvents([e2], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).count, 1)
        XCTAssertEqual(service.pendingVerify[key(e)],
                       PendingVerifyElement(sentSeq: s0, payload: .rowHash(hash(e2)), pullIssue: 42))
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: hash(e), seq: s0), "baseline untouched on []")
        XCTAssertEqual(pullRequests, 1)
        XCTAssertEqual(serverNote(e), "c2", "the stale PATCH wrote nothing")
    }

    func testPendingRowIsNotResentUntilAnEligiblePullResolvesIt() async throws {
        let e = makeEvent("v1")
        await service.syncEvents([e], kind: "calendar")
        server.writeDirectly(table: "events", key: e.id.uuidString, data: ["note": "c2"])
        let e2 = edited(e, note: "c1")
        await service.syncEvents([e2], kind: "calendar")
        let patchesAfterFirst = server.requests(.patch).count

        await service.syncEvents([e2], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).count, patchesAfterFirst, "re-sending the same seq would only be another []")
    }

    // MARK: The third response shape: [row] with deleted_at set

    func testDeadRowHitOnAnIdTableLeavesTheBaselineAloneAndRequestsAPull() async throws {
        let e = makeEvent("v1")
        await service.syncEvents([e], kind: "calendar")
        let sDead = try XCTUnwrap(server.tombstoneDirectly(table: "events", key: e.id.uuidString))
        // The bug condition the guard exists for: a baseline holding a dead
        // row's seq (the applier's tombstone branch would have removed it).
        service.baseline.setEntry(SyncBaselineEntry(hash: hash(e), seq: sDead), table: "calendar_events", id: e.id.uuidString)
        let e2 = edited(e, note: "edit on a dead row")

        await service.syncEvents([e2], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).count, 1)
        XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString), "the fake accepted the write and kept deleted_at (S7)")
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: hash(e), seq: sDead), "not advanced: the pull brings the tombstone")
        XCTAssertTrue(service.pendingVerify.isEmpty)
        XCTAssertEqual(pullRequests, 1)
        XCTAssertTrue(DiagnosticTrail.combinedText().contains("sync.push.dead_row_hit table=events id=\(e.id.uuidString)"))
    }

    func testDeadSingletonRowAdvancesTheBaselineToTheDeadRowSeqAndLeavesLocalAlone() async throws {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await service.syncSettings()
        XCTAssertEqual(server.requests(.insert, table: "user_settings").count, 1)
        let sDead = try XCTUnwrap(server.tombstoneDirectly(table: "user_settings", key: uid))
        // What the applier's singleton tombstone branch writes: (local keys, s_dead).
        guard case .versioned(_, let keys, _) = try XCTUnwrap(service.baseline.settings) else { return XCTFail("versioned expected") }
        service.baseline.setSettings(.versioned(seq: sDead, keys: keys, zone: nil))
        defaults.set(false, forKey: AppSettingsKeys.showTimerBanner)
        // The trail persists across runs; only a line this flush wrote counts.
        let trailLinesBefore = trailLines(containing: "sync.push.tombstoned_singleton table=user_settings")

        await service.syncSettings()

        let patch = try XCTUnwrap(server.requests(.patch, table: "user_settings").first)
        XCTAssertEqual(patch.baseSeq, sDead)
        XCTAssertTrue(server.isTombstoned(table: "user_settings", key: uid))
        let sNew = try XCTUnwrap(server.seq(table: "user_settings", key: uid))
        XCTAssertGreaterThan(sNew, sDead)
        let sentBlob = try XCTUnwrap((patch.body as? [String: Any])?["settings"] as? [String: Any])
        XCTAssertEqual(service.baseline.settings, .versioned(seq: sNew, keys: SupabaseSyncService.settingsKeyHashes(sentBlob), zone: nil))
        XCTAssertEqual(defaults.bool(forKey: AppSettingsKeys.showTimerBanner), false, "local never reset")
        XCTAssertTrue(service.pendingVerify.isEmpty)
        let trailLinesAfter = trailLines(containing: "sync.push.tombstoned_singleton table=user_settings")
        XCTAssertEqual(trailLinesAfter.count, trailLinesBefore.count + 1, "exactly one line from this flush")
        XCTAssertTrue(trailLinesAfter.last?.hasSuffix("table=user_settings seq=\(sNew)") == true, "\(trailLinesAfter.last ?? "no line")")

        // Clean now: no further request until the next local change.
        let before = server.requests.count
        await service.syncSettings()
        XCTAssertEqual(server.requests.count, before)
    }

    // MARK: Pending-verify interleavings (i), (ii), (iii) end to end

    func testInterleavingI_pullIssuedBeforeTheEmptyResponseDoesNotClear_c1ReachesTheServer_killsClearOnAnyPull() async throws {
        let e = makeEvent("X")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        let h0 = hash(e)
        // P1 (issue 5) is in flight when B commits c2@s1.
        service.pullIssueCounter = { 5 }
        let s1 = server.writeDirectly(table: "events", key: e.id.uuidString, data: ["note": "c2"])
        let c1 = edited(e, note: "c1")
        await service.syncEvents([c1], kind: "calendar")
        XCTAssertEqual(service.pendingVerify[key(e)]?.sentSeq, s0)

        // P1 reaches head without seeing X (its snapshot predates s1).
        service.resolvePendingVerifyAtHead(seen: [], pullIssue: 5)
        XCTAssertTrue(service.pendingVerify.contains(key(e)), "P1 was issued before the []; it may not clear")
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: h0, seq: s0), "the mutant would have written h1 here and the next pull would adopt c2 over c1")

        // P2 (issue 6) sees X@s1: the applier's dirty branch shelves c2 and
        // moves base.seq to s1 (hash untouched, keeps c1 dirty).
        service.baseline.setEntry(SyncBaselineEntry(hash: h0, seq: s1), table: "calendar_events", id: e.id.uuidString)
        service.resolvePendingVerifyAtHead(seen: [key(e)], pullIssue: 6)
        XCTAssertFalse(service.pendingVerify.contains(key(e)))

        await service.syncEvents([c1], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s1)
        XCTAssertEqual(serverNote(e), "c1", "c1 wins on the server; c2 lives in A's shelf")
        XCTAssertEqual(entry(e)?.hash, hash(c1))
    }

    func testInterleavingII_pullMovesBaselineWhilePatchIsInFlight_staleNotIdentical_c1StillUploads() async throws {
        let e = makeEvent("X")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        let h0 = hash(e)
        let c1 = edited(e, note: "c1")
        server.holdWhen = { verb, _ in verb == .patch }
        let flush = Task { await self.service.syncEvents([c1], kind: "calendar") }
        try await syncEventually("PATCH built with s0 and parked") { self.server.heldCount == 1 }
        XCTAssertEqual(server.requests(.patch).first?.baseSeq, s0)

        // Before the request reaches the server, a pull applies X@s1
        // (another device's c2): dirty branch, base := (h0, s1).
        let s1 = server.writeDirectly(table: "events", key: e.id.uuidString, data: ["note": "c2"])
        service.baseline.setEntry(SyncBaselineEntry(hash: h0, seq: s1), table: "calendar_events", id: e.id.uuidString)
        server.holdWhen = nil
        server.releaseAll()
        await flush.value

        XCTAssertEqual(service.pendingVerify[key(e)]?.sentSeq, s0, "seq=eq.s0 against s1 → []")
        // The next pull sees nothing (s1 ≤ cursor). Unseen, base.seq (s1) ≠ sentSeq (s0): stale.
        service.resolvePendingVerifyAtHead(seen: [], pullIssue: 1)
        XCTAssertFalse(service.pendingVerify.contains(key(e)))
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: h0, seq: s1), "hash untouched — the old rule would have marked c1 clean forever")

        await service.syncEvents([c1], kind: "calendar")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s1)
        XCTAssertEqual(serverNote(e), "c1")
    }

    func testInterleavingIII_identicalWriteConfirmsTheSentHash_laterEditStillUploads_killsRecomputeFromLiveRow() async throws {
        // The server already holds c1 at s0; the baseline hash is from an
        // older hash encoding, so c1 looks dirty locally.
        let c1 = makeEvent("X", note: "c1")
        let seeded = server.seed(table: "events", rows: [service.eventToRow(c1, kind: "calendar")])
        let s0 = try XCTUnwrap(seeded[c1.id.uuidString])
        service.baseline.setEntry(SyncBaselineEntry(hash: "0ld3nc0d1ng00000", seq: s0), table: "calendar_events", id: c1.id.uuidString)
        service.pullIssueCounter = { 7 }

        await service.syncEvents([c1], kind: "calendar")
        XCTAssertEqual(service.pendingVerify[key(c1)], PendingVerifyElement(sentSeq: s0, payload: .rowHash(hash(c1)), pullIssue: 7))
        XCTAssertEqual(server.seq(table: "events", key: c1.id.uuidString), s0, "identical content: no new seq (015 short circuit)")

        // In the window before the eligible pull reaches head, the user edits
        // X to c3 and the debounced flush fires: the service now holds c3 as
        // the row's live value but sends nothing (pending). A confirm that
        // recomputed the hash from the live row would see c3 here.
        let c3 = edited(c1, note: "c3")
        let requestsBeforeWindowFlush = server.requests.count
        await service.syncEvents([c3], kind: "calendar")
        XCTAssertEqual(server.requests.count, requestsBeforeWindowFlush, "pending: not re-sent in the window")

        service.resolvePendingVerifyAtHead(seen: [], pullIssue: 8)
        XCTAssertEqual(entry(c1), SyncBaselineEntry(hash: hash(c1), seq: s0), "confirmed with the SENT hash")
        XCTAssertNotEqual(entry(c1)?.hash, hash(c3), "the mutant writes hash(c3) and c3 never uploads")

        await service.syncEvents([c3], kind: "calendar")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s0)
        XCTAssertEqual(serverNote(c1), "c3")
        XCTAssertEqual(entry(c1)?.hash, hash(c3))
    }

    // MARK: Deletes → tombstone PATCH, baseline by outcome

    func testLocallyRemovedRowsGoOutAsOneTombstonePatchPerTable() async throws {
        let a = makeEvent("a"), b = makeEvent("b"), c = makeEvent("c"), keep = makeEvent("keep")
        await service.syncEvents([a, b, c, keep], kind: "calendar")

        await service.syncEvents([keep], kind: "calendar")

        let tombstones = server.requests(.tombstone)
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertEqual(Set(tombstones.first?.keys ?? []), Set([a, b, c].map { $0.id.uuidString }))
        for e in [a, b, c] {
            XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString))
            XCTAssertNil(entry(e))
        }
        XCTAssertNotNil(entry(keep))
        XCTAssertFalse(server.isTombstoned(table: "events", key: keep.id.uuidString))
    }

    func testTombstonePatchThatThrowsKeepsTheIdsInTheBaselineAndResendsNextFlush_killsInheritedDiffSync() async throws {
        let gone = makeEvent("gone"), keep = makeEvent("keep")
        await service.syncEvents([gone, keep], kind: "calendar")
        server.failWhen = { verb, _ in verb == .tombstone ? SyncFakeServer.Injected(note: "network") : nil }

        await service.syncEvents([keep], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).count, 1)
        XCTAssertNotNil(entry(gone), "the inherited diffSync returned a map without this id here — and the server never learned of the delete")
        XCTAssertFalse(server.isTombstoned(table: "events", key: gone.id.uuidString))
        // Persisted that way too: a relaunch must still owe the tombstone.
        XCTAssertNotNil(SyncBaselineStore(defaults: defaults, userId: uid).entry(table: "calendar_events", id: gone.id.uuidString))

        server.failWhen = nil
        await service.syncEvents([keep], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).count, 2)
        XCTAssertEqual(server.requests(.tombstone).last?.keys, [gone.id.uuidString])
        XCTAssertNil(entry(gone))
        XCTAssertTrue(server.isTombstoned(table: "events", key: gone.id.uuidString))
    }

    func testTombstonePatchReturningEmptyBodyStillClearsTheBaseline() async throws {
        let gone = makeEvent("gone"), keep = makeEvent("keep")
        await service.syncEvents([gone, keep], kind: "calendar")
        // Another device tombstoned it first: the filter excludes it, the body is [].
        server.tombstoneDirectly(table: "events", key: gone.id.uuidString)

        await service.syncEvents([keep], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).count, 1)
        XCTAssertNil(entry(gone), "2xx removes every requested id, whatever the body said")
        let before = server.requests.count
        await service.syncEvents([keep], kind: "calendar")
        XCTAssertEqual(server.requests.count, before, "no re-PATCH every flush")
    }

    func testTombstoneWithShortBodyClearsAllRequestedIds() async throws {
        let a = makeEvent("a"), b = makeEvent("b"), keep = makeEvent("keep")
        await service.syncEvents([a, b, keep], kind: "calendar")
        server.tombstoneDirectly(table: "events", key: a.id.uuidString)   // only b will be in the response

        await service.syncEvents([keep], kind: "calendar")

        XCTAssertNil(entry(a))
        XCTAssertNil(entry(b))
        XCTAssertTrue(server.isTombstoned(table: "events", key: b.id.uuidString))
    }

    func testTodoAndCalendarKindsAreSeparateBaselinesOverOneServerTable() async {
        let todo = makeEvent("todo"), cal = makeEvent("cal")
        await service.syncEvents([todo], kind: "todo")
        await service.syncEvents([cal], kind: "calendar")
        await service.syncEvents([todo], kind: "todo")
        await service.syncEvents([cal], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).count, 0, "one kind's flush must not read the other kind's rows as deleted")
        XCTAssertNotNil(entry(todo, kind: "todo"))
        XCTAssertNotNil(entry(cal, kind: "calendar"))
        XCTAssertNil(entry(todo, kind: "calendar"))
    }

    // MARK: Concurrency cap

    func testConditionalPatchesNeverExceedEightInFlight() async throws {
        let events = (0..<20).map { makeEvent("e\($0)") }
        await service.syncEvents(events, kind: "calendar")
        let edits = events.map { edited($0, note: "edited") }
        server.holdWhen = { verb, _ in verb == .patch }
        let flush = Task { await self.service.syncEvents(edits, kind: "calendar") }

        try await syncEventually("eight PATCHes parked") { self.server.heldCount == 8 }
        for _ in 0..<25 { await Task.yield() }
        XCTAssertEqual(server.heldCount, 8, "the ninth must wait for a completion")
        XCTAssertEqual(server.requests(.patch).count, 8)
        XCTAssertEqual(server.inFlight, 8)

        server.release(count: 1)
        try await syncEventually("the ninth starts after one completes") { self.server.requests(.patch).count == 9 }
        XCTAssertLessThanOrEqual(server.inFlight, 8)

        server.holdWhen = nil
        server.releaseAll()
        await flush.value

        XCTAssertEqual(server.requests(.patch).count, 20)
        XCTAssertEqual(server.maxInFlight, SyncGatewayLimits.maxConcurrentPatches)
        XCTAssertEqual(server.inFlight, 0)
        for (e, edit) in zip(events, edits) {
            XCTAssertEqual(entry(e)?.hash, hash(edit))
            XCTAssertEqual(serverNote(e), "edited")
        }
    }

    func testPatchFailureKeepsTheRowDirtyForTheNextFlush() async throws {
        let e = makeEvent("v1")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        let e2 = edited(e, note: "v2")
        server.failWhen = { verb, _ in
            verb == .patch ? SupabaseREST.SyncError.requestFailed(table: "events", method: "PATCH", status: 503, code: nil) : nil
        }

        await service.syncEvents([e2], kind: "calendar")
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: hash(e), seq: s0))
        XCTAssertTrue(service.pendingVerify.isEmpty)

        server.failWhen = nil
        await service.syncEvents([e2], kind: "calendar")
        XCTAssertEqual(serverNote(e), "v2")
    }

    func testDeadlockVictimIsResentOnceWithTheSameSeq() async throws {
        let e = makeEvent("v1")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        var remaining = 1
        server.failWhen = { verb, _ in
            guard verb == .patch, remaining > 0 else { return nil }
            remaining -= 1
            return SupabaseREST.SyncError.requestFailed(table: "events", method: "PATCH", status: 500, code: "40P01")
        }

        await service.syncEvents([edited(e, note: "v2")], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).map(\.baseSeq), [s0, s0])
        XCTAssertEqual(serverNote(e), "v2")
    }

    // MARK: I1 gate

    func testFlushIsHeldWhileInboundIsNotAtHead() async {
        service.inboundAtHead = false
        await service.syncEvents([makeEvent("held")], kind: "calendar")
        XCTAssertTrue(server.requests.isEmpty)

        service.inboundAtHead = true
        await service.syncEvents([makeEvent("held")], kind: "calendar")
        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: user_settings

    func testNewSettingsRowIsPostedAndBaselineIsPerKeyHashesWithSeq() async throws {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)

        await service.syncSettings()

        let insert = try XCTUnwrap(server.requests(.insert, table: "user_settings").first)
        XCTAssertEqual(insert.keys, [uid])
        let seq = try XCTUnwrap(server.seq(table: "user_settings", key: uid))
        let sent = try XCTUnwrap((insert.body as? [[String: Any]])?.first?["settings"] as? [String: Any])
        XCTAssertEqual(sent[AppSettingsKeys.showTimerBanner] as? Bool, true)
        XCTAssertEqual(service.baseline.settings, .versioned(seq: seq, keys: SupabaseSyncService.settingsKeyHashes(sent), zone: nil))

        let before = server.requests.count
        await service.syncSettings()
        XCTAssertEqual(server.requests.count, before, "clean")
    }

    func testSettingsPatchSendsTheServerZoneInsteadOfTheLocalOne() async throws {
        let seeded = server.seed(table: "user_settings", rows: [["user_id": uid, "settings": [String: Any]()]])
        let s0 = try XCTUnwrap(seeded[uid])
        service.baseline.setSettings(.versioned(seq: s0, keys: [:], zone: "Asia/Tokyo"))
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)

        await service.syncSettings()

        let patch = try XCTUnwrap(server.requests(.patch, table: "user_settings").first)
        XCTAssertEqual(patch.baseSeq, s0)
        let sent = try XCTUnwrap((patch.body as? [String: Any])?["settings"] as? [String: Any])
        XCTAssertEqual(sent[CalendarOccurrenceKey.referenceTimeZoneDefaultsKey] as? String, "Asia/Tokyo")
        XCTAssertEqual(sent[AppSettingsKeys.showTimerBanner] as? Bool, true)
        let s1 = try XCTUnwrap(server.seq(table: "user_settings", key: uid))
        XCTAssertEqual(service.baseline.settings, .versioned(seq: s1, keys: SupabaseSyncService.settingsKeyHashes(sent), zone: "Asia/Tokyo"))
        XCTAssertTrue(service.pendingVerify.isEmpty)
    }

    func testSettingsBlobForUploadZoneRule() {
        let zoneKey = CalendarOccurrenceKey.referenceTimeZoneDefaultsKey
        let local: [String: Any] = [zoneKey: "America/Los_Angeles", "a": 1]
        XCTAssertEqual(SupabaseSyncService.settingsBlobForUpload(local: local, serverZone: nil)[zoneKey] as? String, "America/Los_Angeles")
        XCTAssertEqual(SupabaseSyncService.settingsBlobForUpload(local: local, serverZone: "Asia/Tokyo")[zoneKey] as? String, "Asia/Tokyo")
        XCTAssertEqual(SupabaseSyncService.settingsBlobForUpload(local: ["a": 1], serverZone: "Asia/Tokyo")[zoneKey] as? String, "Asia/Tokyo",
                       "a device with no zone of its own still carries the account's")
        XCTAssertNil(SupabaseSyncService.settingsBlobForUpload(local: ["a": 1], serverZone: nil)[zoneKey])
    }

    func testSettingsStaleResponseCreatesPendingElementWithSentKeys() async throws {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await service.syncSettings()
        let s0 = try XCTUnwrap(service.baseline.settings?.seq)
        server.writeDirectly(table: "user_settings", key: uid, data: ["settings": ["other": 1]])
        service.pullIssueCounter = { 3 }
        defaults.set(false, forKey: AppSettingsKeys.showTimerBanner)

        await service.syncSettings()

        let patch = try XCTUnwrap(server.requests(.patch, table: "user_settings").first)
        let sent = try XCTUnwrap((patch.body as? [String: Any])?["settings"] as? [String: Any])
        XCTAssertEqual(service.pendingVerify[SyncBaselineKey(table: "user_settings", id: uid)],
                       PendingVerifyElement(sentSeq: s0, payload: .settingsKeys(SupabaseSyncService.settingsKeyHashes(sent)), pullIssue: 3))
        XCTAssertEqual(service.baseline.settings?.seq, s0)
        XCTAssertEqual(pullRequests, 1)
    }

    func testLegacySettingsBaselineUpgradesAtLoadWhenTheLocalRowIsClean() throws {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        let local = SyncedSettings.currentSnapshot(defaults)
        let legacyHash = SupabaseSyncService.rowHash(["user_id": uid, "settings": local])
        defaults.set(legacyHash, forKey: "syncHashes.\(uid).user_settings")

        let fresh = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)

        XCTAssertEqual(fresh.baseline.settings, .versioned(seq: nil, keys: SupabaseSyncService.settingsKeyHashes(local), zone: nil))
        XCTAssertTrue(try XCTUnwrap(defaults.string(forKey: "syncHashes.\(uid).user_settings")).hasPrefix("{"), "persisted in the new shape")
    }

    func testLegacySettingsBaselineStaysLegacyWhenLocalIsDirtyAndUpgradesFromTheRemoteRow() {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        defaults.set("not the local hash", forKey: "syncHashes.\(uid).user_settings")
        let fresh = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
        XCTAssertEqual(fresh.baseline.settings, .legacy(rowHash: "not the local hash"))

        // Branch 2: the remote row is this device's last upload.
        let remote: [String: Any] = ["a": 1, CalendarOccurrenceKey.referenceTimeZoneDefaultsKey: "Asia/Tokyo"]
        defaults.set(SupabaseSyncService.rowHash(["user_id": uid, "settings": remote]), forKey: "syncHashes.\(uid).user_settings")
        let second = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
        XCTAssertTrue(second.upgradeLegacySettingsBaseline(remoteSettings: remote, remoteSeq: 9))
        XCTAssertEqual(second.baseline.settings, .versioned(seq: 9, keys: SupabaseSyncService.settingsKeyHashes(remote), zone: "Asia/Tokyo"))

        // Branch 3: neither — empty keys, every differing key is a conflict for the merge.
        defaults.set("neither", forKey: "syncHashes.\(uid).user_settings")
        let third = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
        XCTAssertTrue(third.upgradeLegacySettingsBaseline(remoteSettings: remote, remoteSeq: 10))
        XCTAssertEqual(third.baseline.settings, .versioned(seq: 10, keys: [:], zone: "Asia/Tokyo"))
        XCTAssertFalse(third.upgradeLegacySettingsBaseline(remoteSettings: remote, remoteSeq: 11), "nothing legacy left")
    }

    // MARK: agent_preferences

    func testAgentPreferencesEmptyRulesAndHistoryEncodeAsEmptyArraysNotNull() async throws {
        let prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SyncOutboundTests-prefs-\(UUID().uuidString)", isDirectory: true))
        let row = service.agentPreferencesToRow(prefs)

        XCTAssertNotNil(row["rules"] as? [Any])
        XCTAssertEqual((row["rules"] as? [Any])?.isEmpty, true)
        XCTAssertNotNil(row["decision_history"] as? [Any])
        XCTAssertEqual((row["decision_history"] as? [Any])?.isEmpty, true)
        XCTAssertFalse(row["rules"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(row))

        await service.syncAgentPreferences(prefs)
        let insert = try XCTUnwrap(server.requests(.insert, table: "agent_preferences").first)
        XCTAssertEqual((insert.body as? [[String: Any]])?.first?["rules"] as? [String], [])
        let seq = try XCTUnwrap(server.seq(table: "agent_preferences", key: uid))
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid), SyncBaselineEntry(hash: SupabaseSyncService.rowHash(row), seq: seq))
    }

    func testRestoreDecoderReadsEmptyArraysAsEmptyAndNullAsAbsent() {
        let empty = SupabaseSyncService.decodeRestoreSnapshot(["agent_preferences": [["rules": [Any](), "decision_history": [Any]()]]])
        XCTAssertEqual(empty.agentRules?.isEmpty, true)
        XCTAssertEqual(empty.agentDecisionHistory?.isEmpty, true)
        let absent = SupabaseSyncService.decodeRestoreSnapshot(["agent_preferences": [["rules": NSNull(), "decision_history": NSNull()]]])
        XCTAssertNil(absent.agentRules)
        XCTAssertNil(absent.agentDecisionHistory)
    }

    // MARK: Request shapes (pure)

    func testFetchAllQueryFiltersTombstonesAndWalksInSeqOrder_killsUnorderedRestoreWindows() {
        XCTAssertEqual(SupabaseREST.fetchAllQuery(table: "events", userId: uid),
                       "events?user_id=eq.\(uid)&deleted_at=is.null&order=seq.asc")
        XCTAssertEqual(SupabaseREST.fetchAllQuery(table: "events", userId: uid, afterSeq: 41),
                       "events?user_id=eq.\(uid)&deleted_at=is.null&order=seq.asc&seq=gt.41")
    }

    func testFetchAllContinuesAfterThePagesHighestSeq() {
        let page: [[String: Any]] = [["id": "a", "seq": NSNumber(value: 3)], ["id": "b", "seq": NSNumber(value: 9)], ["id": "c", "seq": NSNumber(value: 5)]]
        XCTAssertEqual(SupabaseREST.lastSeq(of: page), 9)
        XCTAssertNil(SupabaseREST.lastSeq(of: [["id": "a"]]), "no seq: the walk cannot continue and says so")
    }

    /// A row rewritten by another device during the walk is read twice, the
    /// second time with its higher seq; the restore keeps that one, once.
    func testFetchAllKeepsTheLaterCopyOfARowReadTwice_killsDuplicateRowsFromAWalk() {
        let upper = "D94F0000-0000-4000-8000-000000000001"
        let rows: [[String: Any]] = [
            ["id": upper, "note": "old", "seq": NSNumber(value: 4)],
            ["id": "b", "note": "b", "seq": NSNumber(value: 6)],
            ["id": upper.lowercased(), "note": "new", "seq": NSNumber(value: 11)],
            ["user_id": uid, "settings": [String: Any](), "seq": NSNumber(value: 12)],
        ]
        let deduped = SupabaseREST.dedupeFetchedRows(rows)
        XCTAssertEqual(deduped.count, 3)
        XCTAssertEqual(deduped.first?["note"] as? String, "new", "the later copy, in the place the walk first met the key")
        XCTAssertEqual(deduped[1]["id"] as? String, "b")
        XCTAssertEqual(deduped[2]["user_id"] as? String, uid, "a single-row table is keyed by user_id")
    }

    func testConditionalPatchAndTombstoneQueriesEncodeKeys() {
        XCTAssertEqual(SupabaseREST.conditionalPatchQuery(table: "user_settings", keyColumn: "user_id", key: uid, baseSeq: 7),
                       "user_settings?user_id=eq.\(uid)&seq=eq.7")
        XCTAssertEqual(SupabaseREST.tombstoneQuery(table: "event_logs", keyColumn: "id", keys: ["single|A", "seriesOccurrence|B|none|20260101"]),
                       "event_logs?id=in.(single%7CA,seriesOccurrence%7CB%7Cnone%7C20260101)&deleted_at=is.null")
        XCTAssertEqual(SupabaseREST.encodeFilterValue("0123-abcd_ef.~"), "0123-abcd_ef.~")
    }

    // MARK: seedFingerprint

    func testSeedFingerprintIsIndependentOfUserId() {
        let e = makeEvent("seed", note: "demo")
        var noUser = SupabaseSyncService.eventRowHashableFields(e, kind: "calendar", userId: "")
        var realUser = SupabaseSyncService.eventRowHashableFields(e, kind: "calendar", userId: uid)
        // Positive control: the projection itself does depend on the user.
        XCTAssertNotEqual(SupabaseSyncService.rowHash(noUser), SupabaseSyncService.rowHash(realUser))
        noUser["user_id"] = nil
        realUser["user_id"] = nil
        XCTAssertEqual(SupabaseSyncService.seedFingerprint(e), SupabaseSyncService.rowHash(noUser))
        XCTAssertEqual(SupabaseSyncService.seedFingerprint(e), SupabaseSyncService.rowHash(realUser))
        XCTAssertNotEqual(SupabaseSyncService.seedFingerprint(e), SupabaseSyncService.seedFingerprint(edited(e, note: "touched")))
        // Same projection the upload uses: the service's row is the static one plus the two stamps.
        let uploaded = service.eventToRow(e, kind: "calendar")
        XCTAssertEqual(SupabaseSyncService.rowHash(uploaded), SupabaseSyncService.rowHash(SupabaseSyncService.eventRowHashableFields(e, kind: "calendar", userId: uid)))
    }
}
