//
//  SyncWriteFailureTests.swift
//  DoneTests
//
//  Survey S1 / gap G7: every outbound failure is classified; a refused row
//  is resent on its own once, then remembered by the version that was
//  refused and not sent again until it changes, while the rest of its
//  request proceeds. Too-large requests are split; schema-cache errors get
//  a bounded window; retryable failures and 401s record nothing.
//

import XCTest
@testable import Done

@MainActor
final class SyncWriteFailureTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var clock: SyncManualScheduler!
    private var service: SupabaseSyncService!
    private let uid = "55555555-5555-5555-5555-555555555555"

    override func setUp() {
        super.setUp()
        suiteName = "SyncWriteFailureTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        clock = SyncManualScheduler()
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults, scheduler: clock)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeEvent(_ title: String, note: String = "") -> Event {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Event(title: title, note: note,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
    }

    private func key(_ event: Event) -> SyncBaselineKey {
        SyncBaselineKey(table: "calendar_events", id: event.id.uuidString)
    }

    private func hash(_ event: Event) -> String {
        SupabaseSyncService.rowHash(service.eventToRow(event, kind: "calendar"))
    }

    private func entry(_ event: Event) -> SyncBaselineEntry? {
        service.baseline.entry(table: "calendar_events", id: event.id.uuidString)
    }

    private func rejectedLines(_ id: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init)
            .filter { $0.contains("sync.push.rejected") && $0.contains("id=\(id)") }
    }

    private func status(_ status: Int, _ code: String? = nil) -> Error {
        SupabaseREST.SyncError.requestFailed(table: "events", method: "PATCH", status: status, code: code)
    }

    // MARK: Classification

    func testClassificationTable() {
        typealias F = SyncWriteFailure
        func kind(_ error: Error) -> SyncWriteFailureKind { F.classify(error).kind }
        func landed(_ error: Error) -> Bool { F.classify(error).mayHaveLanded }

        XCTAssertEqual(kind(SupabaseREST.SyncError.tokenExpired), .unauthorized)
        XCTAssertFalse(landed(SupabaseREST.SyncError.tokenExpired))
        for code in ["40P01", "57014", "55P03"] {
            XCTAssertEqual(kind(status(500, code)), .retryable, code)
        }
        for code in [500, 502, 503, 504, 408, 429] {
            XCTAssertEqual(kind(status(code)), .retryable, "\(code)")
            XCTAssertFalse(landed(status(code)), "an HTTP status is an answer")
        }
        for code in ["PGRST204", "PGRST202", "PGRST205"] {
            XCTAssertEqual(kind(status(400, code)), .schemaCache, code)
        }
        XCTAssertEqual(kind(status(413)), .tooLarge)
        XCTAssertEqual(kind(status(414)), .tooLarge)
        for code in ["23514", "23502", "23505", "22P02", "22001", "42501"] {
            XCTAssertEqual(kind(status(400, code)), .rejected, code)
            XCTAssertEqual(F.classify(status(400, code)).code, code)
        }
        XCTAssertEqual(kind(status(400, "42703")), .retryable, "an unlisted code is not taken as permanent")
        XCTAssertEqual(kind(status(400)), .retryable)

        XCTAssertEqual(kind(URLError(.timedOut)), .retryable)
        XCTAssertTrue(landed(URLError(.timedOut)), "the request may have reached the server")
        XCTAssertTrue(landed(URLError(.networkConnectionLost)))
        XCTAssertFalse(landed(URLError(.notConnectedToInternet)), "never left the device")
        XCTAssertFalse(landed(URLError(.cannotConnectToHost)))
        XCTAssertTrue(landed(SupabaseREST.SyncError.malformedResponse(table: "events")), "a 2xx came back")
        XCTAssertFalse(landed(SupabaseREST.SyncError.notSignedIn))
    }

    // MARK: A refused row in a POST chunk

    func testOneRefusedRowInAChunkOfTwenty_nineteenLandOneStaysDirtyOneTrailLineThenZeroResends_killsNoRejectedSet() async throws {
        let events = (0..<SyncGatewayLimits.insertChunkSize).map { makeEvent("e\($0)") }
        let bad = events[events.count / 2]
        server.reject(table: "events", key: bad.id.uuidString, code: "23514")

        await service.syncEvents(events, kind: "calendar")

        for e in events where e.id != bad.id {
            XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString), "the rest of the chunk proceeds")
            XCTAssertNotNil(entry(e)?.seq)
        }
        XCTAssertNil(server.row(table: "events", key: bad.id.uuidString))
        XCTAssertNil(entry(bad), "baseline untouched: the row is still dirty")
        XCTAssertEqual(service.rejected[key(bad)], SyncRejectedSet.Element(hash: hash(bad), code: "23514"))
        XCTAssertEqual(rejectedLines(bad.id.uuidString).count, 1)
        XCTAssertTrue(rejectedLines(bad.id.uuidString).first?.contains("table=calendar_events id=\(bad.id.uuidString) code=23514") == true)
        // The chunk, then each of its rows on its own.
        XCTAssertEqual(server.requests(.insert).map(\.keys.count), [events.count] + Array(repeating: 1, count: events.count))

        let before = server.requests.count
        await service.syncEvents(events, kind: "calendar")
        await service.syncEvents(events, kind: "calendar")
        XCTAssertEqual(server.requests.count, before, "the mutant without a rejected set sends the refused row on every flush")
        XCTAssertEqual(rejectedLines(bad.id.uuidString).count, 1, "one line per refused version")

        // Persisted: a relaunch does not resend it either.
        let relaunched = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults, scheduler: clock)
        await relaunched.syncEvents(events, kind: "calendar")
        XCTAssertEqual(server.requests.count, before)
    }

    func testRefusedRowIsSentAgainAsSoonAsItChanges() async throws {
        let bad = makeEvent("bad")
        server.reject(table: "events", key: bad.id.uuidString, code: "23514")
        await service.syncEvents([bad], kind: "calendar")
        XCTAssertNotNil(service.rejected[key(bad)])
        XCTAssertEqual(server.requests(.insert).count, 1, "a chunk of one is its own individual resend")

        server.clearRejection(table: "events", key: bad.id.uuidString)
        var fixed = bad
        fixed.note = "fixed"
        await service.syncEvents([fixed], kind: "calendar")

        XCTAssertEqual(server.requests(.insert).count, 2)
        XCTAssertNotNil(server.row(table: "events", key: bad.id.uuidString))
        XCTAssertNil(service.rejected[key(bad)])
        XCTAssertEqual(entry(fixed)?.hash, hash(fixed))
    }

    func testRefusedPatchLeavesBaselineAndLocalAloneAndIsNotResentUntilChanged() async throws {
        let e = makeEvent("v1")
        await service.syncEvents([e], kind: "calendar")
        let before = try XCTUnwrap(entry(e))
        server.reject(table: "events", key: e.id.uuidString, code: "23502")
        var v2 = e
        v2.note = "v2"

        await service.syncEvents([v2], kind: "calendar")
        XCTAssertEqual(entry(e), before)
        XCTAssertEqual(service.rejected[key(e)]?.code, "23502")
        let requests = server.requests.count

        await service.syncEvents([v2], kind: "calendar")
        XCTAssertEqual(server.requests.count, requests)

        server.clearRejection(table: "events", key: e.id.uuidString)
        var v3 = v2
        v3.note = "v3"
        await service.syncEvents([v3], kind: "calendar")
        XCTAssertEqual(server.row(table: "events", key: e.id.uuidString)?.data["note"] as? String, "v3")
        XCTAssertNil(service.rejected[key(e)])
    }

    func testRefusedTombstoneAmongSeveralIsResentAloneOthersLandAndItIsNotResentWhileAbsent() async throws {
        let a = makeEvent("a"), b = makeEvent("b"), c = makeEvent("c"), keep = makeEvent("keep")
        await service.syncEvents([a, b, c, keep], kind: "calendar")
        server.reject(table: "events", key: b.id.uuidString, code: "42501")

        await service.syncEvents([keep], kind: "calendar")

        XCTAssertTrue(server.isTombstoned(table: "events", key: a.id.uuidString))
        XCTAssertTrue(server.isTombstoned(table: "events", key: c.id.uuidString))
        XCTAssertFalse(server.isTombstoned(table: "events", key: b.id.uuidString))
        XCTAssertNotNil(entry(b), "kept: the delete is still owed")
        XCTAssertEqual(service.rejected[key(b)], SyncRejectedSet.Element(hash: SyncRejectedSet.deletedHash, code: "42501"))
        XCTAssertEqual(server.requests(.tombstone).map(\.keys.count), [3, 1, 1, 1])

        let requests = server.requests.count
        await service.syncEvents([keep], kind: "calendar")
        XCTAssertEqual(server.requests.count, requests)

        // The row comes back locally: its refused tombstone describes nothing now.
        await service.syncEvents([b, keep], kind: "calendar")
        XCTAssertNil(service.rejected[key(b)])
    }

    // MARK: Too large → split

    func testTooLargeTombstoneIsSplitInHalvesAndAllLand() async throws {
        let gone = (0..<6).map { makeEvent("g\($0)") }
        let keep = makeEvent("keep")
        await service.syncEvents(gone + [keep], kind: "calendar")
        var first = true
        server.failWhen = { verb, _ in
            guard verb == .tombstone, first else { return nil }
            first = false
            return SupabaseREST.SyncError.requestFailed(table: "events", method: "PATCH", status: 414, code: nil)
        }

        await service.syncEvents([keep], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).map(\.keys.count), [6, 3, 3])
        for e in gone {
            XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString))
            XCTAssertNil(entry(e))
        }
        XCTAssertTrue(service.rejected.isEmpty, "a request that can still be split is never a refusal")
    }

    func testTooLargePostChunkIsSplitAndALoneTooLargeRowIsRefused() async throws {
        let events = (0..<4).map { makeEvent("p\($0)") }
        let huge = events[0]
        server.failWhen = { verb, _ in
            guard verb == .insert else { return nil }
            // The whole chunk and every request still carrying `huge` are too large.
            let last = self.server.requests(.insert).last?.keys ?? []
            return last.contains(huge.id.uuidString)
                ? SupabaseREST.SyncError.requestFailed(table: "events", method: "POST", status: 413, code: nil) : nil
        }

        await service.syncEvents(events, kind: "calendar")

        // The chunk, its halves, then the half that held the huge row
        // split again: whichever half it sorted into.
        XCTAssertEqual(server.requests(.insert).map(\.keys.count).sorted(), [1, 1, 2, 2, 4])
        XCTAssertEqual(server.requests(.insert).first?.keys.count, 4)
        for e in events.dropFirst() { XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString)) }
        XCTAssertEqual(service.rejected[key(huge)]?.code, "http413")
    }

    // MARK: Schema cache

    func testSchemaCacheErrorsThatClearAreNeverARefusal() async throws {
        let e = makeEvent("migrating")
        var remaining = 2
        server.failWhen = { verb, _ in
            guard verb == .insert, remaining > 0 else { return nil }
            remaining -= 1
            return SupabaseREST.SyncError.requestFailed(table: "events", method: "POST", status: 400, code: "PGRST204")
        }

        await service.syncEvents([e], kind: "calendar")
        clock.advance(by: SupabaseSyncConfig.schemaCacheRetryWindowSeconds)
        await service.syncEvents([e], kind: "calendar")
        XCTAssertNil(service.rejected[key(e)])
        await service.syncEvents([e], kind: "calendar")

        XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString))
        XCTAssertNil(service.rejected[key(e)])
        XCTAssertNotNil(entry(e)?.seq)
    }

    func testSchemaCacheErrorsBecomeARefusalOnlyPastBothTheAttemptsAndTheWindow() async throws {
        let e = makeEvent("dropped column")
        server.reject(table: "events", key: e.id.uuidString, code: "PGRST204")
        let attempts = SupabaseSyncConfig.schemaCacheRetryAttempts
        let window = SupabaseSyncConfig.schemaCacheRetryWindowSeconds

        // Many quick flushes: attempts pass, the window does not.
        for _ in 0..<(attempts * 2) {
            await service.syncEvents([e], kind: "calendar")
        }
        XCTAssertNil(service.rejected[key(e)], "a schema reload may still be on its way")

        clock.advance(by: window)
        await service.syncEvents([e], kind: "calendar")
        XCTAssertEqual(service.rejected[key(e)]?.code, "PGRST204")

        let requests = server.requests.count
        await service.syncEvents([e], kind: "calendar")
        XCTAssertEqual(server.requests.count, requests)
    }

    func testSchemaCacheWindowAloneIsNotEnoughWithoutTheAttempts() async throws {
        let e = makeEvent("slow flushes")
        server.reject(table: "events", key: e.id.uuidString, code: "PGRST204")
        let window = SupabaseSyncConfig.schemaCacheRetryWindowSeconds
        for _ in 0..<(SupabaseSyncConfig.schemaCacheRetryAttempts - 1) {
            await service.syncEvents([e], kind: "calendar")
            clock.advance(by: window)
        }
        XCTAssertNil(service.rejected[key(e)])
        await service.syncEvents([e], kind: "calendar")
        XCTAssertNotNil(service.rejected[key(e)])
    }

    // MARK: Retryable and 401 record nothing

    func testRetryableFailuresRecordNothingAndResendNextFlush() async throws {
        for (index, error) in [status(503), status(429), status(500, "57014"), status(500, "55P03"), URLError(.notConnectedToInternet) as Error].enumerated() {
            let e = makeEvent("r\(index)")
            server.failWhen = { verb, _ in verb == .insert ? error : nil }
            await service.syncEvents([e], kind: "calendar")
            XCTAssertNil(service.rejected[key(e)], "\(error)")
            server.failWhen = nil
            await service.syncEvents([e], kind: "calendar")
            XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString), "\(error)")
        }
        XCTAssertTrue(service.rejected.isEmpty)
    }

    /// A deadlock victim that loses again on the PATCH's own single re-send
    /// is still a retryable failure: the server wrote nothing either time.
    func testDeadlockVictimTwiceInOneFlushIsRetriedNextFlushNeverRefused_killsDeadlockClassifiedRejected() async throws {
        let e = makeEvent("v1", note: "v1")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        var v2 = e
        v2.note = "v2"
        server.failWhen = { verb, _ in verb == .patch ? self.status(500, "40P01") : nil }

        await service.syncEvents([v2], kind: "calendar")
        server.failWhen = nil

        XCTAssertEqual(server.requests(.patch).map(\.baseSeq), [s0, s0], "the PATCH and its one deadlock re-send")
        XCTAssertNil(service.rejected[key(e)], "a deadlock is not a refusal")
        XCTAssertTrue(rejectedLines(e.id.uuidString).isEmpty)
        XCTAssertEqual(entry(e)?.seq, s0)

        await service.syncEvents([v2], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s0, "resent on the next flush on the same seq")
        XCTAssertEqual(server.row(table: "events", key: e.id.uuidString)?.data["note"] as? String, "v2")
    }

    func testDeadlockOnAnInsertIsRetryable_killsDeadlockClassifiedRejected() async throws {
        let e = makeEvent("insert deadlock")
        server.failWhen = { verb, _ in verb == .insert ? self.status(500, "40P01") : nil }
        await service.syncEvents([e], kind: "calendar")
        server.failWhen = nil
        XCTAssertNil(service.rejected[key(e)])

        await service.syncEvents([e], kind: "calendar")

        XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString))
    }

    func testUnauthorizedAfterTheGatewaysOwnRetryRecordsNothingAndTheNextFlushLands() async throws {
        let e = makeEvent("401")
        server.unauthorizedRequests = [server.requests.count + 1]

        await service.syncEvents([e], kind: "calendar")

        XCTAssertNil(server.row(table: "events", key: e.id.uuidString))
        XCTAssertNil(entry(e), "a 401 is an answer: no marker")
        XCTAssertTrue(service.rejected.isEmpty)
        await service.syncEvents([e], kind: "calendar")
        XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString))
    }

    // MARK: Session scope

    /// `$session` re-delivers the same uid on every token refresh (design
    /// §6.4). That is not a new session: the echo wait, pending-verify and
    /// the schema-cache window all carry over.
    func testTokenRefreshForTheSameUidKeepsTheInMemorySyncState_killsSameUidSessionReset() async throws {
        let echo = makeEvent("echo")
        server.seed(table: "events", rows: [service.eventToRow(echo, kind: "calendar")])
        let stale = makeEvent("stale", note: "v1")
        let schema = makeEvent("schema")
        await service.syncEvents([echo, stale], kind: "calendar")
        XCTAssertEqual(service.awaitingEcho, [key(echo)])
        server.writeDirectly(table: "events", key: stale.id.uuidString, data: ["note": "elsewhere"])
        var staleEdit = stale
        staleEdit.note = "v2"
        server.reject(table: "events", key: schema.id.uuidString, code: "PGRST204")
        let attempts = SupabaseSyncConfig.schemaCacheRetryAttempts
        for _ in 0..<(attempts - 1) {
            await service.syncEvents([echo, staleEdit, schema], kind: "calendar")
        }
        XCTAssertTrue(service.pendingVerify.contains(key(stale)), "seq moved under the PATCH: []")
        XCTAssertNil(service.rejected[key(schema)])
        clock.advance(by: SupabaseSyncConfig.schemaCacheRetryWindowSeconds)

        service.beginSession(userId: uid)

        XCTAssertEqual(service.awaitingEcho, [key(echo)])
        XCTAssertTrue(service.pendingVerify.contains(key(stale)))
        await service.syncEvents([echo, staleEdit, schema], kind: "calendar")
        XCTAssertEqual(service.rejected[key(schema)]?.code, "PGRST204",
                       "the attempts before the refresh still count; the mutant restarts the window and holds back")
    }

    /// Positive control: a real change of account does drop that state.
    func testANewSessionDropsTheInMemorySyncState() async throws {
        let echo = makeEvent("echo")
        server.seed(table: "events", rows: [service.eventToRow(echo, kind: "calendar")])
        await service.syncEvents([echo], kind: "calendar")
        XCTAssertEqual(service.awaitingEcho, [key(echo)])

        service.beginSession(userId: "99999999-9999-9999-9999-999999999999")
        service.beginSession(userId: uid)

        XCTAssertTrue(service.awaitingEcho.isEmpty)
    }

    // MARK: Single-row tables

    func testRefusedSettingsRowIsNotResentUntilASettingChanges() async throws {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        server.reject(table: "user_settings", key: uid, code: "22P02")

        await service.syncSettings()
        let refusal = try XCTUnwrap(service.rejected[SyncBaselineKey(table: "user_settings", id: uid)])
        XCTAssertEqual(refusal.code, "22P02")
        let requests = server.requests.count
        await service.syncSettings()
        XCTAssertEqual(server.requests.count, requests)

        server.clearRejection(table: "user_settings", key: uid)
        defaults.set(false, forKey: AppSettingsKeys.showTimerBanner)
        await service.syncSettings()
        XCTAssertNotNil(server.row(table: "user_settings", key: uid))
        XCTAssertNil(service.rejected[SyncBaselineKey(table: "user_settings", id: uid)])
    }

    // MARK: Scope

    func testRejectedSetLivesUnderTheUsersSyncHashesPrefixAndTheEraseRemovesIt() async throws {
        let bad = makeEvent("bad")
        server.reject(table: "events", key: bad.id.uuidString, code: "23514")
        await service.syncEvents([bad], kind: "calendar")
        XCTAssertNotNil(defaults.data(forKey: "syncHashes.\(uid).rejected"))

        SupabaseSyncService.wipeAllPersistedHashes(defaults)

        XCTAssertNil(defaults.data(forKey: "syncHashes.\(uid).rejected"))
        XCTAssertTrue(SyncRejectedSet(defaults: defaults, userId: uid).isEmpty)
    }
}
