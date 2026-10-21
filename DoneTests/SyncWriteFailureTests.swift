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
        XCTAssertEqual(entry(bad), .unknown(seq: nil), "only the send's `?`: the row is still dirty")
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
        XCTAssertEqual(entry(e), .unknown(seq: before.seq), "the send's `?` at the same seq, nothing more")
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

        // The row comes back locally: its refused tombstone describes nothing
        // now. The tombstone's `?` makes the restored row dirty, so it is
        // re-verified on its old seq (S4 case 3).
        server.clearRejection(table: "events", key: b.id.uuidString)
        let patchesBefore = server.requests(.patch).count
        await service.syncEvents([b, keep], kind: "calendar")
        XCTAssertNil(service.rejected[key(b)])
        XCTAssertEqual(server.requests(.patch).count, patchesBefore + 1)
    }

    // MARK: The user_id foreign key (design §6.4, S12's detection half)

    /// PostgREST's error body for a 23503, as Postgres words it for an
    /// inline `references auth.users(id)` (named `<table>_user_id_fkey`).
    private func foreignKeyBody(table: String, constraint: String) -> Data {
        let object: [String: Any] = [
            "code": "23503",
            "details": "Key (user_id)=(\(uid)) is not present in table \"users\".",
            "hint": NSNull(),
            "message": "insert or update on table \"\(table)\" violates foreign key constraint \"\(constraint)\"",
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// What `SupabaseREST.send` throws for that body.
    private func accountGone(_ table: String) -> Error {
        SupabaseREST.requestError(table: table, method: "POST", status: 409,
                                  body: foreignKeyBody(table: table, constraint: "\(table)_user_id_fkey"))
    }

    private func accountLines() -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init).filter { $0.contains("sync.account.") }
    }

    func testUserIdForeignKeyIsReadFromTheConstraintNameAndIsNeverARefusal() {
        let error = SupabaseREST.requestError(table: "events", method: "POST", status: 409,
                                              body: foreignKeyBody(table: "events", constraint: "events_user_id_fkey"))
        guard case SupabaseREST.SyncError.accountMissing(_, _, let constraint) = error else {
            return XCTFail("a user_id foreign-key 23503 must be accountMissing, got \(error)")
        }
        XCTAssertEqual(constraint, "events_user_id_fkey")
        XCTAssertEqual(SyncWriteFailure.classify(error).kind, .accountMissing)
        XCTAssertEqual(SyncWriteFailure.classify(error).code, "23503")
        XCTAssertEqual(SyncWriteFailure.classify(accountGone("user_settings")).kind, .accountMissing)

        // Positive control: another foreign key is an ordinary refusal.
        let other = SupabaseREST.requestError(table: "event_logs", method: "POST", status: 409,
                                              body: foreignKeyBody(table: "event_logs", constraint: "event_logs_event_id_fkey"))
        guard case SupabaseREST.SyncError.requestFailed(_, _, 409, .some("23503")) = other else {
            return XCTFail("a non-user_id foreign key keeps its code, got \(other)")
        }
        XCTAssertEqual(SyncWriteFailure.classify(other).kind, .rejected)
        let check = SupabaseREST.requestError(table: "events", method: "POST", status: 400,
                                              body: Data(#"{"code":"23514","message":"new row violates check constraint \"events_user_id_fkey\""}"#.utf8))
        XCTAssertEqual(SyncWriteFailure.classify(check).kind, .rejected, "the constraint name counts only on a 23503")
        XCTAssertNil(SupabaseREST.userIdForeignKeyConstraint(message: nil))
    }

    func testUserIdForeignKeyStopsTheTableForcesARefreshAndRetriesNextFlush_killsAccountMissingRejected() async throws {
        DiagnosticTrail.clear()
        var refreshes = 0
        service.tokenRefresher = { refreshes += 1; return .kept }
        let events = (0..<(SyncGatewayLimits.insertChunkSize + 1)).map { makeEvent("e\($0)") }
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }

        await service.syncEvents(events, kind: "calendar")

        XCTAssertTrue(service.rejected.isEmpty, "never a refusal")
        XCTAssertTrue(rejectedLines(events[0].id.uuidString).isEmpty)
        XCTAssertEqual(server.requests(.insert).map(\.keys.count), [SyncGatewayLimits.insertChunkSize],
                       "the table stops: no per-row resend, no second chunk")
        XCTAssertEqual(refreshes, 1, "one forced refresh")
        XCTAssertEqual(service.accountCheck, .suspected(table: "calendar_events"))
        for e in events { XCTAssertEqual(entry(e), .unknown(seq: nil), "rows stay dirty with the send's `?`") }
        XCTAssertTrue(accountLines().contains { $0.contains("sync.account.fk_missing table=calendar_events") })
        XCTAssertTrue(accountLines().contains { $0.contains("sync.account.refresh outcome=kept") })

        server.failWhen = nil
        await service.syncEvents(events, kind: "calendar")

        for e in events { XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString), "retried on the next flush") }
        XCTAssertEqual(service.accountCheck, .none, "an insert landed in the table: the account is there")
        XCTAssertTrue(service.rejected.isEmpty)
    }

    /// Sim QA round 2: Sync Status read "POST events failed: the account
    /// may no longer exist (events_user_id_fkey)". It says it in words now.
    /// The "raw error shown" mutant puts the constraint name back.
    func testSyncStatusSaysTheAccountMayBeGoneInWords_killsRawErrorShown() async throws {
        let reporter = SyncStatusReporter()
        service.statusReporter = reporter
        service.tokenRefresher = { .kept }
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }

        await service.syncEvents([makeEvent("x")], kind: "calendar")

        let shown = try XCTUnwrap(reporter.structured.lastError)
        XCTAssertTrue(shown.contains(L(.syncErrorAccountMayBeGone)), shown)
        XCTAssertFalse(shown.contains("fkey"), shown)
        XCTAssertFalse(shown.contains("POST"), shown)
        XCTAssertEqual(LKey.syncErrorAccountMayBeGone.text(for: .chinese), "账号可能已不存在。")
    }

    func testAfterARefreshShowedTheAccountExistsTheSameViolationIsARefusal() async throws {
        var refreshes = 0
        service.tokenRefresher = { refreshes += 1; return .refreshed }
        let e = makeEvent("fk")
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }

        await service.syncEvents([e], kind: "calendar")
        XCTAssertEqual(service.accountCheck, .accountExists(table: "calendar_events"))
        XCTAssertTrue(service.rejected.isEmpty, "the first meeting is retried, not refused")

        await service.syncEvents([e], kind: "calendar")

        XCTAssertEqual(server.requests(.insert).count, 2, "retried once on the next flush")
        XCTAssertEqual(service.rejected[key(e)], SyncRejectedSet.Element(hash: hash(e), code: "23503"),
                       "the account exists, so the violation has another cause: a refusal (design §6.4)")
        XCTAssertEqual(refreshes, 1, "no second refresh")
        let requests = server.requests.count
        await service.syncEvents([e], kind: "calendar")
        XCTAssertEqual(server.requests.count, requests, "a refusal is not resent unchanged")
    }

    /// The refresh's "the account exists" answers the violation it was
    /// raised for, once. Kept for the rest of the session, it would read an
    /// erasure that happens later as one more refusal and never check again.
    func testTheRefusalSpendsTheRefreshsAnswer_aLaterViolationIsCheckedAfresh_killsStickyAccountExists() async throws {
        var refreshes = 0
        service.tokenRefresher = { refreshes += 1; return .refreshed }
        let e = makeEvent("fk")
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }
        await service.syncEvents([e], kind: "calendar")
        await service.syncEvents([e], kind: "calendar")
        XCTAssertNotNil(service.rejected[key(e)], "rig: the recurrence was refused on the refresh's answer")
        XCTAssertEqual(service.accountCheck, .none, "the refusal spent it")

        let later = makeEvent("later")
        await service.syncEvents([e, later], kind: "calendar")

        XCTAssertNil(service.rejected[key(later)], "a later violation is an account check, not a refusal")
        XCTAssertEqual(refreshes, 2, "a fresh forced refresh")
        XCTAssertEqual(service.accountCheck, .accountExists(table: "calendar_events"))
        XCTAssertEqual(entry(later), .unknown(seq: nil), "left dirty for the next flush")
    }

    /// The single-row path spends it too: the settings POST refused on the
    /// refresh's answer leaves no answer behind, so a later violation in
    /// the row is checked afresh rather than read as one more refusal.
    func testTheSettingsRefusalSpendsTheRefreshsAnswerToo_aLaterViolationIsCheckedAfresh_killsSingletonSpendDropped() async throws {
        var refreshes = 0
        service.tokenRefresher = { refreshes += 1; return .refreshed }
        let banner = AppSettingsKeys.showTimerBanner
        let settingsKey = SyncBaselineKey(table: "user_settings", id: uid)
        defaults.set(true, forKey: banner)
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }
        await service.syncSettings()
        XCTAssertEqual(service.accountCheck, .accountExists(table: "user_settings"))
        XCTAssertTrue(service.rejected.isEmpty, "the first meeting is retried, not refused")

        await service.syncSettings()
        XCTAssertEqual(server.requests(.insert, table: "user_settings").count, 2, "rig: the recurrence went out")
        XCTAssertNotNil(service.rejected[settingsKey], "rig: the recurrence was refused on the refresh's answer")
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(service.accountCheck, .none, "the refusal spent it")

        defaults.set(false, forKey: banner)
        await service.syncSettings()

        XCTAssertEqual(server.requests(.insert, table: "user_settings").count, 3, "a changed row loses its refusal and goes out")
        XCTAssertNil(service.rejected[settingsKey], "a later violation is an account check, not a refusal")
        XCTAssertEqual(refreshes, 2, "a fresh forced refresh")
        XCTAssertEqual(service.accountCheck, .accountExists(table: "user_settings"))
    }

    /// The answer is about the table it was raised for: a violation in
    /// another table is checked, not refused on it.
    func testARefreshsAnswerForOneTableDoesNotRefuseAViolationInAnother_killsAccountExistsAnyTable() async throws {
        var refreshes = 0
        service.tokenRefresher = { refreshes += 1; return .refreshed }
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }
        await service.syncEvents([makeEvent("fk")], kind: "calendar")
        XCTAssertEqual(service.accountCheck, .accountExists(table: "calendar_events"))

        let todo = makeEvent("todo")
        await service.syncEvents([todo], kind: "todo")

        let todoTable = SupabaseSyncService.eventsBaselineTable(kind: "todo")
        XCTAssertNotEqual(todoTable, "calendar_events")
        XCTAssertNil(service.rejected[SyncBaselineKey(table: todoTable, id: todo.id.uuidString)])
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(service.accountCheck, .accountExists(table: todoTable))
    }

    /// A refresh that comes back after the session changed answers for the
    /// account that left: nothing is recorded for the one now signed in.
    func testARefreshAnsweredAfterTheSessionChangedRecordsNothing_killsRefreshedUidGuardDropped() async throws {
        let other = "66666666-6666-6666-6666-666666666666"
        service.tokenRefresher = { [unowned self] in
            self.service.beginSession(userId: other)
            return .refreshed
        }
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }

        await service.syncEvents([makeEvent("fk")], kind: "calendar")

        XCTAssertEqual(service.userId, other, "rig: the session changed while the refresh was out")
        XCTAssertEqual(service.accountCheck, .none)
    }

    func testSettingsPostMeetingTheForeignKeyIsAnAccountCheckToo() async throws {
        service.tokenRefresher = { .kept }
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }

        await service.syncSettings()

        XCTAssertEqual(service.accountCheck, .suspected(table: "user_settings"))
        XCTAssertTrue(service.rejected.isEmpty)
    }

    /// The terminal half runs through the REAL `AuthService` (gh#234): its
    /// refresh is refused with the terminal code, it clears the session and
    /// sets the re-authentication flag, and the sync service reports why.
    func testTerminalRefreshGoesDownTheGh234PathAndThePublishedCheckSaysWhy() async throws {
        let auth = makeAuth(refreshAnswer: (400, #"{"code":400,"error_code":"refresh_token_already_used","msg":"Invalid Refresh Token: Already Used"}"#))
        XCTAssertTrue(auth.isSignedIn)
        service.tokenRefresher = { await SupabaseSyncService.forceRefresh(auth) }
        let e = makeEvent("fk")
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }

        await service.syncEvents([e], kind: "calendar")

        XCTAssertNil(auth.session, "the terminal refresh cleared the session")
        XCTAssertTrue(auth.needsReauthentication, "gh#234's explanation for the sign-in page")
        XCTAssertEqual(service.accountCheck, .signedOut(table: "calendar_events"))
        XCTAssertTrue(service.rejected.isEmpty)
        XCTAssertEqual(entry(e), .unknown(seq: nil), "local data and its marker untouched (§10.7 decides)")

        // What the `$session` sink does once the terminal refresh cleared it.
        service.endSession()
        XCTAssertEqual(service.accountCheck, .signedOut(table: "calendar_events"), "the reason outlives the session it ended, for the account card")

        service.beginSession(userId: "66666666-6666-6666-6666-666666666666")
        XCTAssertEqual(service.accountCheck, .none, "a new sign-in starts a fresh check")
    }

    func testForceRefreshReadsTheSessionAuthServiceLeaves() async throws {
        let refreshed = makeAuth(refreshAnswer: (200, #"{"access_token":"AT-new","refresh_token":"R2","expires_in":3600,"user":{"id":"\#(uid)","email":null}}"#))
        let outcomeRefreshed = await SupabaseSyncService.forceRefresh(refreshed)
        XCTAssertEqual(outcomeRefreshed, .refreshed)
        let kept = makeAuth(refreshAnswer: (500, #"{"code":500,"msg":"boom"}"#))
        let outcomeKept = await SupabaseSyncService.forceRefresh(kept)
        XCTAssertEqual(outcomeKept, .kept)
        XCTAssertTrue(kept.isSignedIn)
    }

    /// A signed-in `AuthService` whose every refresh grant gets `answer`.
    private func makeAuth(refreshAnswer answer: (status: Int, body: String)) -> AuthService {
        let session = AuthSession(
            accessToken: "AT-old", refreshToken: "R1",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            user: AuthUser(id: uid, email: nil, createdAt: nil)
        )
        let authSuite = "\(suiteName).auth.\(UUID().uuidString)"
        let authDefaults = UserDefaults(suiteName: authSuite)!
        addTeardownBlock { authDefaults.removePersistentDomain(forName: authSuite) }
        return AuthService(
            url: "https://stub.invalid",
            projectAPIKey: "test-publishable-key",
            defaults: authDefaults,
            sessionStore: InMemorySessionStore(stored: try! JSONEncoder().encode(session)),
            transport: { request in
                let http = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/2", headerFields: [:])!
                return (Data(answer.body.utf8), http)
            }
        )
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
        XCTAssertEqual(entry(e), .unknown(seq: nil), "a 401 writes nothing more than the send's `?`")
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
