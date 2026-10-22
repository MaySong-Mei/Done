//
//  SyncFakeServerHookTests.swift
//  DoneTests
//
//  A positive control for every `SyncFakeServer` fault hook (survey M6(1)):
//  each test runs the same request with the hook off and on and shows the
//  outcome differs, so a test that later leans on a hook is leaning on
//  something that bites. Plus the page-cap rule (survey M1(b)).
//

import XCTest
@testable import Done

@MainActor
final class SyncFakeServerHookTests: XCTestCase {

    private let uid = "44444444-4444-4444-4444-444444444444"
    private var server: SyncFakeServer!

    override func setUp() {
        super.setUp()
        server = SyncFakeServer(userId: uid)
    }

    private func listRow(_ id: String = UUID().uuidString, title: String = "t") -> [String: Any] {
        ["id": id, "user_id": uid, "title": title, "color_name": "blue"]
    }

    @discardableResult
    private func seedLists(_ count: Int) -> [String] {
        let rows = (0..<count).map { listRow(title: "l\($0)") }
        server.seed(table: "todo_lists", rows: rows)
        return rows.compactMap { $0["id"] as? String }
    }

    private func patch(_ key: String, baseSeq: Int64, title: String) async throws -> [[String: Any]] {
        try await server.patchConditional(table: "todo_lists", keyColumn: "id", key: key,
                                          baseSeq: baseSeq, body: listRow(key, title: title))
    }

    // MARK: holdResponseWhen — request-time snapshot, late delivery

    /// The contrast is the point: `holdWhen` evaluates at release and sees
    /// the tombstone; `holdResponseWhen` evaluated at request time and
    /// delivers the row alive, after the tombstone, many steps later.
    func testHeldResponseCarriesTheStateAtRequestTimeWhileHeldRequestSeesTheStateAtRelease() async throws {
        let id = seedLists(1)[0]

        server.holdWhen = { verb, _ in verb == .pull }
        let requestHeld = Task { try await self.server.pullChanges(sinceSeq: 0, pageLimit: 500) }
        try await syncEventually("request parked") { self.server.heldCount == 1 }
        server.tombstoneDirectly(table: "todo_lists", key: id)
        server.holdWhen = nil
        server.release()
        let atRelease = try await requestHeld.value
        XCTAssertFalse(atRelease.first?.data["deleted_at"] is NSNull, "holdWhen: the verb ran after the tombstone")

        server = SyncFakeServer(userId: uid)
        let id2 = seedLists(1)[0]
        server.holdResponseWhen = { verb, _ in verb == .pull }
        let responseHeld = Task { try await self.server.pullChanges(sinceSeq: 0, pageLimit: 500) }
        try await syncEventually("response parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        // Further steps while it is parked: a tombstone, and a pull that sees it.
        server.tombstoneDirectly(table: "todo_lists", key: id2)
        let fresh = try await server.pullChanges(sinceSeq: 0, pageLimit: 500)
        XCTAssertFalse(fresh.first?.data["deleted_at"] is NSNull)
        XCTAssertEqual(server.heldResponseCount, 1, "the parked response outlives the later steps")
        server.releaseAllResponses()
        let stale = try await responseHeld.value
        XCTAssertEqual(stale.count, 1)
        XCTAssertTrue(stale.first?.data["deleted_at"] is NSNull, "holdResponseWhen: the page was cut before the tombstone")
    }

    func testHeldResponseOfAWriteHasAlreadyChangedTheServer() async throws {
        let id = seedLists(1)[0]
        let s0 = try XCTUnwrap(server.seq(table: "todo_lists", key: id))
        server.holdResponseWhen = { verb, _ in verb == .patch }

        let call = Task { try await self.patch(id, baseSeq: s0, title: "late") }
        try await syncEventually("response parked") { self.server.heldResponseCount == 1 }
        XCTAssertEqual(server.row(table: "todo_lists", key: id)?.data["title"] as? String, "late")
        XCTAssertGreaterThan(try XCTUnwrap(server.seq(table: "todo_lists", key: id)), s0)

        server.releaseResponse(failing: SyncFakeServer.Injected(note: "connection reset"))
        do {
            _ = try await call.value
            XCTFail("a parked response released as a failure must throw")
        } catch {
            XCTAssertEqual(error as? SyncFakeServer.Injected, SyncFakeServer.Injected(note: "connection reset"))
        }
    }

    // MARK: dropResponseWhen — executed, answer lost (PATCH / POST / tombstone PATCH)

    func testDroppedPatchResponseThrowsButTheWriteLanded() async throws {
        let id = seedLists(1)[0]
        let s0 = try XCTUnwrap(server.seq(table: "todo_lists", key: id))
        let lost = SyncFakeServer.Injected(note: "lost")

        server.failWhen = { verb, _ in verb == .patch ? lost : nil }
        do { _ = try await patch(id, baseSeq: s0, title: "a"); XCTFail("must throw") } catch {}
        XCTAssertEqual(server.seq(table: "todo_lists", key: id), s0, "failWhen: nothing ran")

        server.failWhen = nil
        server.dropResponseWhen = { verb, _ in verb == .patch ? lost : nil }
        do { _ = try await patch(id, baseSeq: s0, title: "a"); XCTFail("must throw") } catch {
            XCTAssertEqual(error as? SyncFakeServer.Injected, lost)
        }
        XCTAssertEqual(server.row(table: "todo_lists", key: id)?.data["title"] as? String, "a")
        XCTAssertGreaterThan(try XCTUnwrap(server.seq(table: "todo_lists", key: id)), s0, "dropResponseWhen: the write took a seq")
    }

    func testDroppedInsertResponseThrowsButTheRowsExist() async throws {
        let row = listRow(title: "posted")
        let id = try XCTUnwrap(row["id"] as? String)
        server.dropResponseWhen = { verb, _ in verb == .insert ? SyncFakeServer.Injected(note: "lost") : nil }

        do { _ = try await server.insertIgnoringDuplicates(table: "todo_lists", rows: [row]); XCTFail("must throw") } catch {}

        XCTAssertNotNil(server.seq(table: "todo_lists", key: id))
        server.dropResponseWhen = nil
        let again = try await server.insertIgnoringDuplicates(table: "todo_lists", rows: [row])
        XCTAssertTrue(again.isEmpty, "the resend finds it already there — the shape awaitingEcho exists for")
    }

    func testDroppedTombstoneResponseThrowsButTheRowIsDead() async throws {
        let id = seedLists(1)[0]
        server.dropResponseWhen = { verb, _ in verb == .tombstone ? SyncFakeServer.Injected(note: "lost") : nil }

        do {
            _ = try await server.tombstone(table: "todo_lists", keyColumn: "id", keys: [id], deletedAt: Date())
            XCTFail("must throw")
        } catch {}

        XCTAssertTrue(server.isTombstoned(table: "todo_lists", key: id))
        server.dropResponseWhen = nil
        let resend = try await server.tombstone(table: "todo_lists", keyColumn: "id", keys: [id], deletedAt: Date())
        XCTAssertTrue(resend.isEmpty, "the resend stamps nothing: the row is already dead")
    }

    /// Through the engine: a lost PATCH answer leaves the baseline on the old
    /// seq, so the resend is stale and lands in pending-verify — where a
    /// pre-execution failure (`failWhen`) resends and lands the write.
    func testEngineSeesALostPatchAnswerAsAStaleResendWhereAFailedRequestResendsCleanly() async throws {
        let suite = "SyncFakeServerHookTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let e = Event(title: "drop", note: "v1", timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
        await service.syncEvents([e], kind: "calendar")
        var e2 = e
        e2.note = "v2"

        server.dropResponseWhen = { verb, _ in verb == .patch ? SyncFakeServer.Injected(note: "lost") : nil }
        await service.syncEvents([e2], kind: "calendar")
        server.dropResponseWhen = nil
        XCTAssertEqual(server.row(table: "events", key: e.id.uuidString)?.data["note"] as? String, "v2")
        XCTAssertTrue(service.pendingVerify.isEmpty)

        await service.syncEvents([e2], kind: "calendar")

        XCTAssertEqual(service.pendingVerify.count, 1, "the resend on the old seq came back []")
    }

    // MARK: maxRows — PostgREST db-max-rows

    func testMaxRowsTruncatesThePullPageAndTheRestoreWalk() async throws {
        seedLists(1500)

        let full = try await server.pullChanges(sinceSeq: 0, pageLimit: SyncGatewayLimits.maxPageLimit)
        XCTAssertEqual(full.count, SyncGatewayLimits.maxPageLimit)
        XCTAssertFalse(SyncGatewayLimits.isHead(rowCount: full.count, requestedLimit: SyncGatewayLimits.maxPageLimit))
        let restored = try await server.fetchAll(table: "todo_lists", userId: uid)
        XCTAssertEqual(restored.count, 1500)

        let lowered = SyncGatewayLimits.maxPageLimit / 2 - 100
        server.maxRows = lowered
        let truncated = try await server.pullChanges(sinceSeq: 0, pageLimit: SyncGatewayLimits.maxPageLimit)
        XCTAssertEqual(truncated.count, lowered)
        XCTAssertTrue(SyncGatewayLimits.isHead(rowCount: truncated.count, requestedLimit: SyncGatewayLimits.maxPageLimit),
                      "a max_rows below the page limit makes a full page read as head (survey G3)")
        let shortRestore = try await server.fetchAll(table: "todo_lists", userId: uid)
        XCTAssertEqual(shortRestore.count, lowered, "the restore walk stops at the first truncated window")
    }

    // MARK: A row that does not exist

    func testWritesToARowThatDoesNotExistAnswerEmptyAndDoNotThrow() async throws {
        let ghost = UUID().uuidString
        let live = seedLists(1)[0]
        let liveSeq = try XCTUnwrap(server.seq(table: "todo_lists", key: live))

        let control = try await patch(live, baseSeq: liveSeq, title: "edited")
        XCTAssertEqual(control.count, 1, "the same PATCH shape on an existing row returns it")

        let patched = try await patch(ghost, baseSeq: liveSeq, title: "edited")
        XCTAssertTrue(patched.isEmpty)
        let stamped = try await server.tombstone(table: "todo_lists", keyColumn: "id", keys: [ghost], deletedAt: Date())
        XCTAssertTrue(stamped.isEmpty)
        XCTAssertNil(server.row(table: "todo_lists", key: ghost), "neither write created it")
    }

    // MARK: physicallyDelete — TRUNCATE / hard-delete shape

    func testPhysicallyDeletedRowAnswersEmptyToTheSeqThatMatchedAndLeavesTheFeed() async throws {
        let ids = seedLists(2)
        let s0 = try XCTUnwrap(server.seq(table: "todo_lists", key: ids[0]))
        let counter = server.seqCounter

        XCTAssertTrue(server.physicallyDelete(table: "todo_lists", key: ids[0]))

        XCTAssertEqual(server.seqCounter, counter, "no seq: nothing in the feed says it went")
        XCTAssertNil(server.row(table: "todo_lists", key: ids[0]))
        let patched = try await patch(ids[0], baseSeq: s0, title: "after")
        XCTAssertTrue(patched.isEmpty, "the seq that matched before now answers [] — survey G2's false 'identical'")
        let feed = try await server.pullChanges(sinceSeq: 0, pageLimit: 500)
        XCTAssertEqual(feed.compactMap { $0.data["id"] as? String }, [ids[1].lowercased()])
    }

    // MARK: rewind(toSeq:) — restore from a dump

    func testRewindRestoresTheRowsAndTheCounterAndHandsOutTheSameSeqsAgain() async throws {
        let id = seedLists(1)[0]
        let dumpSeq = server.seqCounter
        let epoch0 = server.epoch
        let afterDump = try await patch(id, baseSeq: dumpSeq, title: "after dump")
        let s1 = try XCTUnwrap(afterDump.first?["seq"] as? NSNumber).int64Value
        let later = seedLists(1)[0]
        XCTAssertTrue(server.physicallyDelete(table: "todo_lists", key: id))

        server.rewind(toSeq: dumpSeq)

        XCTAssertEqual(server.seqCounter, dumpSeq)
        XCTAssertEqual(server.floor, dumpSeq)
        XCTAssertNotEqual(server.epoch, epoch0)
        XCTAssertEqual(server.row(table: "todo_lists", key: id)?.data["title"] as? String, "l0", "the row as the dump had it")
        XCTAssertEqual(server.seq(table: "todo_lists", key: id), dumpSeq)
        XCTAssertNil(server.row(table: "todo_lists", key: later), "written after the dump: gone")

        let different = try await patch(id, baseSeq: dumpSeq, title: "different")
        let reused = try XCTUnwrap(different.first?["seq"] as? NSNumber).int64Value
        XCTAssertEqual(reused, s1, "the restored counter hands out a seq a client already saw, for other content (survey G1)")
    }

    func testRewindIsANoOpForTheRowsAtTheCurrentSeq() {
        let ids = seedLists(2)
        server.rewind(toSeq: server.seqCounter)
        XCTAssertEqual(ids.compactMap { server.row(table: "todo_lists", key: $0) }.count, 2)
        XCTAssertEqual(server.floor, server.seqCounter)
    }

    // MARK: reject — permanent 4xx with a PostgREST code

    func testRejectedRowAnswersTheCodedFailureAndChangesNothing() async throws {
        let row = listRow(title: "bad")
        let id = try XCTUnwrap(row["id"] as? String)
        let other = listRow(title: "good")
        server.reject(table: "todo_lists", key: id, status: 400, code: "23514")

        do {
            _ = try await server.insertIgnoringDuplicates(table: "todo_lists", rows: [other, row])
            XCTFail("must throw")
        } catch SupabaseREST.SyncError.requestFailed(let table, let method, let status, let code) {
            XCTAssertEqual(table, "todo_lists")
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code, "23514")
        }
        XCTAssertNil(server.row(table: "todo_lists", key: other["id"] as! String), "one statement: the chunk fails whole")

        server.clearRejection(table: "todo_lists", key: id)
        let inserted = try await server.insertIgnoringDuplicates(table: "todo_lists", rows: [other, row])
        XCTAssertEqual(inserted.count, 2, "the same request with the hook off succeeds")

        server.reject(table: "todo_lists", key: id, status: 400, code: "PGRST204")
        let seq = try XCTUnwrap(server.seq(table: "todo_lists", key: id))
        do { _ = try await patch(id, baseSeq: seq, title: "x"); XCTFail("must throw") } catch SupabaseREST.SyncError.requestFailed(_, let method, _, let code) {
            XCTAssertEqual(method, "PATCH")
            XCTAssertEqual(code, "PGRST204")
        }
        XCTAssertEqual(server.seq(table: "todo_lists", key: id), seq)
    }

    // MARK: 401 on the k-th request

    func testUnauthorizedOrdinalFailsExactlyThatRequestBeforeItRuns() async throws {
        let ids = seedLists(1)
        let s0 = try XCTUnwrap(server.seq(table: "todo_lists", key: ids[0]))
        server.unauthorizedRequests = [2]

        _ = try await server.pullChanges(sinceSeq: 0, pageLimit: 500)
        do {
            _ = try await patch(ids[0], baseSeq: s0, title: "401")
            XCTFail("the second request must be refused")
        } catch SupabaseREST.SyncError.tokenExpired {}
        XCTAssertEqual(server.seq(table: "todo_lists", key: ids[0]), s0, "a 401 runs nothing")

        let third = try await patch(ids[0], baseSeq: s0, title: "ok")
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(server.requests.count, 3)
    }
}

/// Survey M1(b): the client cap is the server's clamp, and "this page is the
/// head" is one comparison.
@MainActor
final class SyncPageHeadTests: XCTestCase {

    func testIsHeadComparesAgainstTheClampedLimit() {
        let cap = SyncGatewayLimits.maxPageLimit
        XCTAssertTrue(SyncGatewayLimits.isHead(rowCount: cap - 1, requestedLimit: cap))
        XCTAssertFalse(SyncGatewayLimits.isHead(rowCount: cap, requestedLimit: cap))
        XCTAssertFalse(SyncGatewayLimits.isHead(rowCount: cap, requestedLimit: cap + 1),
                       "a request above the cap gets a capped page; full at the cap is not head")
        let small = SyncGatewayLimits.defaultPageLimit
        XCTAssertTrue(SyncGatewayLimits.isHead(rowCount: small - 1, requestedLimit: small))
        XCTAssertFalse(SyncGatewayLimits.isHead(rowCount: small, requestedLimit: small))
        XCTAssertTrue(SyncGatewayLimits.isHead(rowCount: 0, requestedLimit: 0), "a non-positive limit is one row")
    }

    /// The constant against PostgREST's default `db-max-rows`, which is the
    /// bound survey G3 measured: a cap above it reads a full page as head.
    func testCapDoesNotExceedPostgRESTDefaultMaxRowsAndRestoreWindowMatches() {
        let postgrestDefaultMaxRows = 1000
        XCTAssertLessThanOrEqual(SyncGatewayLimits.maxPageLimit, postgrestDefaultMaxRows)
        XCTAssertLessThanOrEqual(SyncGatewayLimits.fetchAllPageSize, postgrestDefaultMaxRows)
        XCTAssertLessThanOrEqual(SyncGatewayLimits.defaultPageLimit, SyncGatewayLimits.maxPageLimit)
    }

    func testFakeServerClampsAtTheCapAndTheFollowingPageIsHead() async throws {
        let uid = "55555555-5555-5555-5555-555555555555"
        let server = SyncFakeServer(userId: uid)
        let total = SyncGatewayLimits.maxPageLimit + 200
        server.seed(table: "todo_lists", rows: (0..<total).map { ["id": UUID().uuidString, "user_id": uid, "title": "\($0)"] })
        let asked = SyncGatewayLimits.maxPageLimit + 500

        let first = try await server.pullChanges(sinceSeq: 0, pageLimit: asked)
        XCTAssertEqual(first.count, SyncGatewayLimits.maxPageLimit)
        XCTAssertFalse(SyncGatewayLimits.isHead(rowCount: first.count, requestedLimit: asked))
        let second = try await server.pullChanges(sinceSeq: try XCTUnwrap(first.last?.seq), pageLimit: asked)
        XCTAssertEqual(first.count + second.count, total)
        XCTAssertTrue(SyncGatewayLimits.isHead(rowCount: second.count, requestedLimit: asked))
    }

    /// Wiring: no sync source compares a page's row count to a limit by hand.
    func testNoSyncSourceJudgesHeadOutsideIsHead() throws {
        let files = try SyncSourceScan.syncPathFiles()
        let pattern = try NSRegularExpression(pattern: #"\.count\s*<\s*[A-Za-z_.]*([Ll]imit|[Ss]ize)\b"#)
        // Positive control: the hand comparison this replaced is caught.
        let replaced = "            if pageRows.count < pageSize { break }"
        XCTAssertEqual(pattern.numberOfMatches(in: replaced, range: NSRange(replaced.startIndex..., in: replaced)), 1)
        for file in files {
            let code = try SyncSourceScan.code(of: file)
            let hits = pattern.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
            XCTAssertEqual(hits, 0, "\(file) compares a row count to a page limit by hand — use SyncGatewayLimits.isHead")
        }
    }
}
