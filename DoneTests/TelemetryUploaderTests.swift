//
//  TelemetryUploaderTests.swift
//  DoneTests
//
//  gh#273 — the uploader against two instruments:
//    * a `URLProtocol` stub registered on the shared session, so "zero
//      requests" is judged at the HTTP layer and a second request path
//      cannot hide behind the gateway seam (B·F34);
//    * `SyncFakeServer.upsertRows`, for the composite-key and revision
//      semantics (B·F13/F35) and for injected failures (B·F36).
//  Plus the center-side claim-key tests (design §11 test 9) and the
//  erase witness (test 7). Every absence is paired with a positive control.
//

import Combine
import QuartzCore
import UIKit
import XCTest
@testable import Done

// MARK: - URLProtocol stub

/// Intercepts EVERY http(s) request on the shared session while registered
/// and answers it; records the request and its body bytes.
final class TelemetryHTTPStub: URLProtocol {
    struct Captured {
        let request: URLRequest
        let body: Data
    }

    nonisolated(unsafe) static var captured: [Captured] = []
    nonisolated(unsafe) static var status = 201
    private static let lock = NSLock()

    static func reset(status: Int = 201) {
        lock.lock(); defer { lock.unlock() }
        captured = []
        Self.status = status
    }

    static var all: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static func install() {
        URLProtocol.registerClass(TelemetryHTTPStub.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(TelemetryHTTPStub.self)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        Self.lock.lock()
        Self.captured.append(Captured(request: request, body: body))
        let status = Self.status
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `httpBody` is nil inside a URLProtocol for URLSession-dispatched
    /// requests; the bytes arrive as a stream.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Rig

@MainActor
final class TelemetryUploaderTests: XCTestCase {
    private let uid = TelemetryFixtures.uid
    private var location: SpikeRunStorageLocation!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var clock: Date = TelemetryFixtures.t0
    /// The attachment captures the session and the engine WEAKLY (as the
    /// app's does); the test keeps them alive for its duration.
    private var retained: [AnyObject] = []

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        suiteName = "TelemetryUploaderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        server = SyncFakeServer(userId: uid)
        clock = TelemetryFixtures.t0
    }

    override func tearDown() {
        TelemetryHTTPStub.uninstall()
        SpikeRunStore.ownerProvider = nil
        try? FileManager.default.removeItem(at: location.directory)
        defaults.removePersistentDomain(forName: suiteName)
        SpikeProbe.onSignal = nil
        retained = []
        super.tearDown()
    }

    private func makeUploader(bootstrapOwner: String? = nil) -> TelemetryUploader {
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.now = { [unowned self] in self.clock }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { bootstrapOwner }
        return TelemetryUploader(dependencies: deps)
    }

    private func attachFakeServer(_ uploader: TelemetryUploader, blocked: Bool = false, userID: String? = nil) {
        let user = userID ?? uid
        uploader.attach(TelemetryUploader.Attachment(
            gateway: server,
            isBlockedByBuild: { blocked },
            currentUserID: { user },
            isSignedIn: { true }
        ))
    }

    /// A real `SupabaseREST` over a stub host with an injected, unrefreshable
    /// session — the request leaves through `send` exactly as in the app and
    /// the URLProtocol stub answers it.
    private func attachRealGateway(_ uploader: TelemetryUploader, blocked: Bool = false) -> AuthService {
        let json = #"{"access_token":"at-1","refresh_token":"","user_id":"\#(uid)","email":"rig@example.com"}"#
        let auth = AuthService(
            url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
            sessionStore: InMemorySessionStore(),
            transport: { request in
                XCTFail("no auth request may go out; got \(request.url?.absoluteString ?? "?")")
                throw URLError(.notConnectedToInternet)
            },
            launchEnvironment: ["SYNC_DEBUG_SESSION": json], syncEnvironment: .local
        )
        XCTAssertTrue(auth.isSignedIn, "rig: the injected session must be live")
        retained.append(auth)
        let rest = SupabaseREST(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", authService: auth)
        uploader.attach(TelemetryUploader.Attachment(
            gateway: rest,
            isBlockedByBuild: { blocked },
            currentUserID: { [weak auth] in auth?.userId },
            isSignedIn: { [weak auth] in auth?.isSignedIn ?? false }
        ))
        return auth
    }

    private func turnOn(consentAt: Date? = nil) {
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: consentAt ?? clock.addingTimeInterval(-3600))
    }

    @discardableResult
    private func seed(
        kind: TelemetryRecordKind = .dailyRollup,
        startedAt: Date? = nil,
        owner: String? = TelemetryFixtures.uid,
        note: String? = nil,
        abortReason: SpikeAbortReason? = nil,
        metrics: [String: SpikeMetricValue] = ["tapCount": .number(1)],
        id: UUID = UUID()
    ) -> SpikeRun {
        let spikeID: String
        let scenarioID: String
        switch kind {
        case .dailyRollup:
            spikeID = FixObservationRegistry.residentDailySpikeID
            scenarioID = FixObservationRegistry.residentDailyScenarioID
        case .window:
            spikeID = FixObservationRegistry.effortPathFixID
            scenarioID = FixObservationRegistry.windowScenarioID
        default:
            spikeID = Spike201SignalID.spikeID
            scenarioID = "default"
        }
        let run = TelemetryFixtures.run(
            id: id, spikeID: spikeID, scenarioID: scenarioID,
            startedAt: startedAt ?? clock, endedAt: (startedAt ?? clock).addingTimeInterval(1),
            metrics: metrics, note: note, abortReason: abortReason, ownerUID: owner, kind: kind, revision: nil
        )
        XCTAssertTrue(SpikeRunStore.finishRun(run, location: location), "seed must land")
        return run
    }

    private func telemetryRequests() -> [SyncFakeServer.Request] {
        server.requests(.telemetryUpsert)
    }

    /// The run ids in every body the URLProtocol stub captured — the
    /// HTTP-layer twin of `telemetryRequests().keys`, for the tests whose
    /// claim is "nothing on the wire" (B·F34: judged below the gateway seam).
    private func httpSentRunIDs() -> [String] {
        TelemetryHTTPStub.all.flatMap { captured -> [String] in
            let rows = (try? JSONSerialization.jsonObject(with: captured.body)) as? [[String: Any]] ?? []
            return rows.compactMap { $0["run_id"] as? String }
        }
    }

    // MARK: 1 — switch off = zero requests, at the HTTP layer

    /// Design §11 test 1 (B·F34). Three triggers with the switch OFF put
    /// nothing on the wire — judged by a URLProtocol stub on the shared
    /// session, not by the gateway seam. Positive control: ON with a
    /// pending record → exactly one POST, with the composite `on_conflict`
    /// and the merge-duplicates Prefer the wire contract names, and no
    /// `X-Sync-Epoch`.
    func testSwitchOffPutsNothingOnTheWireAndOnSendsExactlyOneUpsert() async throws {
        TelemetryHTTPStub.install()
        TelemetryHTTPStub.reset()
        let uploader = makeUploader()
        _ = attachRealGateway(uploader)
        seed()
        // consent exists but the switch is OFF: the switch alone must stop it.
        TelemetryConsentStore.recordGrant(defaults, at: clock.addingTimeInterval(-3600))
        defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled)

        for trigger in [TelemetryTrigger.launch, .deckOpen, .backgroundEdge] {
            let outcome = await uploader.uploadNow(trigger: trigger)
            XCTAssertEqual(outcome, .switchOff, "\(trigger)")
        }
        XCTAssertEqual(TelemetryHTTPStub.all.count, 0, "switch OFF: zero HTTP requests, whatever the trigger")

        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .uploaded(rows: 1))
        XCTAssertEqual(TelemetryHTTPStub.all.count, 1, "positive control: ON → exactly one request")
        let request = try XCTUnwrap(TelemetryHTTPStub.all.first?.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://stub.invalid/rest/v1/spike_runs?on_conflict=user_id,run_id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=minimal")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-publishable-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Sync-Epoch"), "outside the 015 gate (B·F14)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(TelemetryHTTPStub.all.first).body) as? [[String: Any]])
        guard body.count == 1 else { return XCTFail("expected one row in the body, got \(body.count)") }
        XCTAssertEqual(body[0]["user_id"] as? String, uid)
        XCTAssertEqual(body[0]["kind"] as? String, "daily_rollup")

        // Nothing new → nothing sent, still through the HTTP layer.
        let again = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(again, .nothingPending)
        XCTAssertEqual(TelemetryHTTPStub.all.count, 1)
    }

    // MARK: 2 — idempotence and ordering on the fake server

    /// Design §11 test 2 against the in-memory server, which runs
    /// `TelemetryServerModel.apply` as its BEFORE UPDATE guard: the same
    /// revision twice is one row; 7 then 5 keeps 7; 8 overwrites 7. Also
    /// through the uploader: a re-append (new revision) is a second upsert
    /// that the server accepts, and a stale resend afterwards changes nothing.
    func testSameRevisionTwiceIsOneRowAndALowerRevisionNeverOverwritesAHigherOne() async throws {
        let uploader = makeUploader()
        attachFakeServer(uploader)
        turnOn()
        let run = seed()

        let outcome1 = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome1, .uploaded(rows: 1))
        let first = try XCTUnwrap(server.telemetryRow(runID: run.id))
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(server.telemetryRowCount(), 1)

        // Same revision again, straight at the server: still one row, two writes.
        try await server.upsertRows(table: TelemetryWire.table, rows: [first.data], onConflict: TelemetryWire.onConflict)
        XCTAssertEqual(server.telemetryRowCount(), 1)
        XCTAssertEqual(server.telemetryRow(runID: run.id)?.writes, 2)

        // 7 then 5 → 7; then 8 → 8.
        var seven = first.data; seven["revision"] = 7; seven["metrics"] = ["tapCount": 7]
        var five = first.data; five["revision"] = 5; five["metrics"] = ["tapCount": 5]
        var eight = first.data; eight["revision"] = 8; eight["metrics"] = ["tapCount": 8]
        try await server.upsertRows(table: TelemetryWire.table, rows: [seven], onConflict: TelemetryWire.onConflict)
        try await server.upsertRows(table: TelemetryWire.table, rows: [five], onConflict: TelemetryWire.onConflict)
        XCTAssertEqual(server.telemetryRow(runID: run.id)?.revision, 7, "a lower revision arriving later is skipped")
        XCTAssertEqual((server.telemetryRow(runID: run.id)?.data["metrics"] as? [String: Any])?["tapCount"] as? Int, 7)
        try await server.upsertRows(table: TelemetryWire.table, rows: [eight], onConflict: TelemetryWire.onConflict)
        XCTAssertEqual(server.telemetryRow(runID: run.id)?.revision, 8)
        XCTAssertEqual(server.telemetryRowCount(), 1, "one key, one row, throughout")

        // Through the uploader: a note edit re-appends the id (revision 2)
        // and goes out as a second request for the same row.
        XCTAssertTrue(SpikeRunStore.setNote("edited", forRunID: run.id, spikeID: run.spikeID, location: location))
        // Reset the server row to what the uploader last sent so the
        // revision guard is judged against the client's own sequence.
        try await server.upsertRows(table: TelemetryWire.table, rows: [first.data], onConflict: TelemetryWire.onConflict)
        let outcome2 = await uploader.uploadNow(trigger: .deckOpen)
        XCTAssertEqual(outcome2, .uploaded(rows: 1),
                       "a skipped update is still a 2xx to the client")
        XCTAssertEqual(server.telemetryRow(runID: run.id)?.writes, 7, "the uploader's second request reached the row")
        XCTAssertEqual(server.telemetryRow(runID: run.id)?.revision, 8, "8 > 2: the server keeps the higher revision")
    }

    /// RLS at the fake: a row claiming another user is refused with 403 /
    /// 42501, which the client classifies as a rejection of the row. ("Two
    /// users, same run id → two rows" is NOT asserted here: two independent
    /// fake servers each hold their own table, so it would hold by
    /// construction — the real evidence is SQL check T5.)
    func testARowClaimingAnotherUserIsRefusedAsARejection() async throws {
        let run = TelemetryFixtures.run(revision: 1)
        let theirs = TelemetryWire.row(for: run, userID: TelemetryFixtures.otherUID, installID: UUID(), now: clock) { _ in ("2026-01-01", 0) }
        do {
            try await server.upsertRows(table: TelemetryWire.table, rows: [theirs], onConflict: TelemetryWire.onConflict)
            XCTFail("a row for another user must be refused")
        } catch SupabaseREST.SyncError.requestFailed(_, _, let status, let code) {
            XCTAssertEqual(status, 403, "PostgREST answers an RLS refusal to an authenticated client with 403, never 401")
            XCTAssertEqual(code, "42501")
            XCTAssertEqual(SyncWriteFailure.classify(SupabaseREST.SyncError.requestFailed(table: "t", method: "POST", status: status, code: code)).kind,
                           .rejected, "and the client classifies it as a rejection of the row")
        }
    }

    // MARK: P1-2 — a refused row is quarantined, not a permanent blocker

    /// Review P1-2. A record whose `buildConfiguration` is prose becomes
    /// `"unknown"` after redaction (the NOT NULL placeholder), which the
    /// server's check refuses; the bulk insert fails as a whole, every row is
    /// resent on its own, the good rows land and are acknowledged, the bad
    /// one is parked at its revision, and the next trigger sends nothing.
    /// Positive control first: a clean batch is exactly one request — the
    /// per-row path is never walked when nothing is refused.
    func testARefusedRowIsQuarantinedWhileTheGoodRowsLandAndTheCursorMovesForThem() async throws {
        let uploader = makeUploader()
        attachFakeServer(uploader)
        turnOn()

        // Positive control: clean batch, one request.
        let clean1 = seed(kind: .window, startedAt: clock)
        let clean2 = seed(kind: .window, startedAt: clock.addingTimeInterval(1))
        let control = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(control, .uploaded(rows: 2))
        XCTAssertEqual(telemetryRequests().count, 1, "no refusal → no per-row walk")
        XCTAssertEqual(server.telemetryRowCount(), 2)

        // One bad row among good ones.
        let good = seed(kind: .window, startedAt: clock.addingTimeInterval(2))
        let bad = TelemetryFixtures.run(spikeID: FixObservationRegistry.effortPathFixID, scenarioID: FixObservationRegistry.windowScenarioID,
                                        startedAt: clock.addingTimeInterval(3), buildConfiguration: "staging",
                                        metrics: ["tapCount": .number(1)], kind: .window, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(bad, location: location))

        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .partial(uploaded: 1, quarantined: 1))
        XCTAssertEqual(telemetryRequests().count, 4, "1 control + 1 refused batch + 2 single rows")
        XCTAssertEqual(server.telemetryRowCount(), 3, "the good row landed")
        XCTAssertNotNil(server.telemetryRow(runID: good.id))
        XCTAssertNil(server.telemetryRow(runID: bad.id))
        let cursor = SpikeRunStore.loadUploadCursor(location: location)
        XCTAssertEqual(cursor.uploaded[good.id], 1, "the cursor moved for the good row")
        XCTAssertEqual(cursor.uploaded[clean1.id], 1)
        XCTAssertEqual(cursor.uploaded[clean2.id], 1)
        XCTAssertNil(cursor.uploaded[bad.id])
        XCTAssertEqual(cursor.quarantined[bad.id], 1, "the bad row is parked at its revision")
        XCTAssertEqual(uploader.quarantinedCount, 1)
        XCTAssertEqual(uploader.lastBatchCount, 1)

        // Nothing pending: the parked row does not come back.
        let again = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(again, .nothingPending)
        XCTAssertEqual(telemetryRequests().count, 4, "zero requests on the next trigger")

        // A re-append (new revision) is tried again on its own merits — and
        // parked again at the new revision when still refused.
        XCTAssertTrue(SpikeRunStore.setNote("retry", forRunID: bad.id, spikeID: bad.spikeID, location: location))
        let retry = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(retry, .partial(uploaded: 0, quarantined: 1))
        XCTAssertEqual(telemetryRequests().count, 6, "the batch of one, then the one row")
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: location).quarantined[bad.id], 2)
        XCTAssertEqual(server.telemetryRowCount(), 3)
    }

    /// The isolation path is for ROW faults only: a 500 or a transport
    /// error on the batch is not walked per row (that would turn one outage
    /// into N requests), and a transport error met mid-walk stops it.
    func testOnlyRowFaultsAreIsolatedPerRow() async throws {
        XCTAssertTrue(TelemetryUploader.isolatesRows(.rejected))
        XCTAssertTrue(TelemetryUploader.isolatesRows(.schemaCache))
        XCTAssertTrue(TelemetryUploader.isolatesRows(.tooLarge))
        for kind in [SyncWriteFailureKind.retryable, .unauthorized, .accountMissing, .epochStale, .paused] {
            XCTAssertFalse(TelemetryUploader.isolatesRows(kind), "\(kind)")
        }
        let uploader = makeUploader()
        attachFakeServer(uploader)
        turnOn()
        seed(kind: .window, startedAt: clock)
        seed(kind: .window, startedAt: clock.addingTimeInterval(1))
        server.failWhen = { verb, table in
            verb == .telemetryUpsert ? SupabaseREST.SyncError.requestFailed(table: table, method: "POST", status: 500, code: nil) : nil
        }
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .failed(kind: .retryable, code: "http500"))
        XCTAssertEqual(telemetryRequests().count, 1, "a 500 is one failed request, not three")
    }

    // MARK: 3 — cursor only after 2xx

    /// Design §11 test 3 (B·F36): a 500 and a transport error leave the
    /// cursor untouched; a 2xx advances it; a NEW uploader over the same
    /// files has nothing to send. The failures are classified and logged,
    /// never retried inside the batch.
    func testTheCursorAdvancesOnlyAfterA2xxAndARelaunchSendsNothing() async throws {
        let uploader = makeUploader()
        attachFakeServer(uploader)
        turnOn()
        let run = seed()
        let cursorURL = SpikeRunStore.uploadCursorURL(location: location)

        server.failWhen = { verb, table in
            verb == .telemetryUpsert ? SupabaseREST.SyncError.requestFailed(table: table, method: "POST", status: 500, code: nil) : nil
        }
        let outcome3 = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome3, .failed(kind: .retryable, code: "http500"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursorURL.path), "500 → no cursor written")
        XCTAssertEqual(telemetryRequests().count, 1, "one attempt, no retry storm")

        server.failWhen = { verb, _ in verb == .telemetryUpsert ? URLError(.networkConnectionLost) : nil }
        let outcome4 = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome4, .failed(kind: .retryable, code: "url-1005"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursorURL.path), "URLError → no cursor written")
        XCTAssertEqual(telemetryRequests().count, 2)

        server.failWhen = nil
        let outcome5 = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome5, .uploaded(rows: 1))
        let cursor = SpikeRunStore.loadUploadCursor(location: location)
        XCTAssertEqual(cursor.uploaded[run.id], 1, "2xx → the cursor records the sent revision")
        XCTAssertEqual(uploader.totalAcknowledged, 1)
        XCTAssertEqual(uploader.lastBatchCount, 1)
        XCTAssertEqual(uploader.lastUploadAt, clock)

        // "Relaunch": a fresh uploader over the same directory and defaults.
        let relaunched = makeUploader()
        attachFakeServer(relaunched)
        let outcome6 = await relaunched.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome6, .nothingPending)
        XCTAssertEqual(telemetryRequests().count, 3, "no fourth request: the persisted cursor is the truth")
        XCTAssertEqual(relaunched.totalAcknowledged, 1, "the cumulative count is read back from the cursor")
    }

    /// Design §7.5: a 2xx that arrives after an erase began must not write
    /// a cursor describing records that no longer exist.
    func testA2xxAfterAnEraseBeganDoesNotWriteTheCursor() async throws {
        let uploader = makeUploader()
        attachFakeServer(uploader)
        turnOn()
        seed()
        server.holdWhen = { verb, _ in verb == .telemetryUpsert }

        let outcome = await LocalDataEraseEpoch.withIsolatedEpoch { () async -> TelemetryUploadOutcome in
            uploader.schedule(.launch)
            // Let the batch reach the held verb, then "erase".
            let deadline = Date().addingTimeInterval(2)
            while server.heldCount == 0 && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(server.heldCount, 1, "rig: the request is parked at the server")
            LocalDataEraseEpoch.bump()
            server.releaseAll()
            await uploader.drain()
            return uploader.lastOutcome ?? .nothingPending
        }
        XCTAssertEqual(outcome, .staleAfterErase)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpikeRunStore.uploadCursorURL(location: location).path))
        XCTAssertEqual(server.telemetryRowCount(), 1, "the rows did land; only the cursor is withheld")
    }

    /// Single writer: a trigger arriving while a batch is held is merged
    /// into ONE follow-up, run after — never two batches in flight.
    func testSchedulesDuringAnInFlightBatchMergeIntoOneFollowUp() async throws {
        let uploader = makeUploader()
        attachFakeServer(uploader)
        turnOn()
        seed()
        server.holdWhen = { verb, _ in verb == .telemetryUpsert }
        uploader.schedule(.launch)
        let deadline = Date().addingTimeInterval(2)
        while server.heldCount == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.heldCount, 1)
        uploader.schedule(.backgroundEdge)
        uploader.schedule(.deckOpen)
        uploader.schedule(.backgroundEdge)
        XCTAssertEqual(server.maxInFlight, 1)
        server.holdWhen = nil
        server.releaseAll()
        await uploader.drain()
        XCTAssertEqual(server.maxInFlight, 1, "never two batches in flight")
        XCTAssertEqual(telemetryRequests().count, 1, "the merged follow-up found nothing pending and sent nothing")
        XCTAssertEqual(uploader.lastOutcome, .nothingPending)
    }

    /// Review P2-1: edge work never runs bare. A background edge scheduled
    /// while a launch batch is in flight begins the keep-alive at once and
    /// holds it until that batch AND the merged follow-up are done; a batch
    /// started while the app is not active is wrapped too; a foreground
    /// deck-open is not. Begin/end pair exactly once per episode.
    func testEdgeWorkIsAlwaysUnderOneKeepAliveFromScheduleToDrain() async throws {
        final class Counting: TelemetryKeepAlive {
            let log: Box<[String]>
            init(_ log: Box<[String]>) { self.log = log; log.value.append("begin") }
            func end() { log.value.append("end") }
        }
        let log = Box<[String]>([])
        let active = Box(true)
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.now = { [unowned self] in self.clock }
        deps.launchDelay = 0
        deps.makeKeepAlive = { Counting(log) }
        deps.isApplicationActive = { active.value }
        let uploader = TelemetryUploader(dependencies: deps)
        attachFakeServer(uploader)
        turnOn()
        seed()

        // Foreground launch batch: no keep-alive on its own.
        server.holdWhen = { verb, _ in verb == .telemetryUpsert }
        uploader.schedule(.launch)
        let deadline = Date().addingTimeInterval(2)
        while server.heldCount == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.heldCount, 1)
        XCTAssertEqual(log.value, [], "a foreground launch batch runs without a keep-alive")

        // The edge arrives mid-flight: begun NOW, merged behind the batch.
        uploader.schedule(.backgroundEdge)
        XCTAssertEqual(log.value, ["begin"], "the edge's keep-alive begins at schedule time, not when its batch starts")
        uploader.schedule(.backgroundEdge)
        XCTAssertEqual(log.value, ["begin"], "a second edge joins the same keep-alive")

        server.holdWhen = nil
        server.releaseAll()
        await uploader.drain()
        XCTAssertEqual(log.value, ["begin", "end"], "ended once, after the in-flight batch and the follow-up both finished")
        XCTAssertEqual(uploader.lastOutcome, .nothingPending)

        // Not active: even a non-edge batch is wrapped.
        active.value = false
        seed(kind: .window, startedAt: clock.addingTimeInterval(1))
        _ = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(log.value, ["begin", "end", "begin", "end"])

        // Active deck-open: bare.
        active.value = true
        seed(kind: .window, startedAt: clock.addingTimeInterval(2))
        _ = await uploader.uploadNow(trigger: .deckOpen)
        XCTAssertEqual(log.value, ["begin", "end", "begin", "end"], "a foreground deck-open adds no keep-alive")
    }

    // MARK: 4 — the Debug → production gate

    /// Design §11 test 4 (B·F38): the uploader asks the ONE gate the sync
    /// engine asks; when it says blocked nothing goes out even with the
    /// switch on, consent given and a record pending. Positive control: the
    /// same rig with the gate open sends. (The source scans that forbid a
    /// second `#if DEBUG` are in TelemetrySourceScanTests.)
    func testABlockedBuildSendsNothingAndAnOpenOneSends() async throws {
        TelemetryHTTPStub.install()
        TelemetryHTTPStub.reset()
        let blocked = makeUploader()
        _ = attachRealGateway(blocked, blocked: true)
        turnOn()
        seed()
        let outcome7 = await blocked.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome7, .blockedByBuild)
        XCTAssertEqual(TelemetryHTTPStub.all.count, 0)

        let open = makeUploader()
        _ = attachRealGateway(open, blocked: false)
        let outcome8 = await open.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome8, .uploaded(rows: 1))
        XCTAssertEqual(TelemetryHTTPStub.all.count, 1, "positive control")
    }

    /// The production attachment reads `uploadsBlockedByBuild` off the live
    /// engine: a DEBUG process pointed at production is blocked, at the
    /// local stack it is not — the engine's own matrix, seen by the uploader.
    func testTheLiveAttachmentReadsTheEnginesGate() async throws {
        let engineOnProduction = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults, environment: .production)
        let engineOnLocal = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults, environment: .local)
        XCTAssertTrue(engineOnProduction.uploadsBlockedByBuild, "precondition: this is a DEBUG test process")
        XCTAssertFalse(engineOnLocal.uploadsBlockedByBuild)
        let json = #"{"access_token":"at-1","refresh_token":"","user_id":"\#(uid)"}"#
        let auth = AuthService(url: "https://stub.invalid", projectAPIKey: "k", defaults: defaults,
                               sessionStore: InMemorySessionStore(),
                               transport: { _ in throw URLError(.notConnectedToInternet) },
                               launchEnvironment: ["SYNC_DEBUG_SESSION": json], syncEnvironment: .local)
        turnOn()
        seed()
        retained.append(auth)
        retained.append(engineOnProduction)
        retained.append(engineOnLocal)
        let uploader = makeUploader()
        uploader.attach(authService: auth, syncService: engineOnProduction)
        let outcome9 = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome9, .blockedByBuild)
        XCTAssertEqual(uploader.ownerUID, uid, "the attached session is the owner")
    }

    // MARK: 5 — free text never leaves

    /// Design §11 test 5 (B·F37): sentinels in `note`, in a legacy abort
    /// text and in an unregistered `.string` metric; opt-out → the request
    /// BYTES contain none; opt-in → only the note's.
    func testSentinelsInNoteAbortReasonAndStringMetricNeverLeaveExceptTheNoteWhenOptedIn() async throws {
        TelemetryHTTPStub.install()
        TelemetryHTTPStub.reset()
        let uploader = makeUploader()
        _ = attachRealGateway(uploader)
        turnOn()
        let noteSentinel = "NOTE-\(UUID().uuidString)"
        let abortSentinel = "ABORT-\(UUID().uuidString)"
        let metricSentinel = "METRIC-\(UUID().uuidString)"
        let run = seed(kind: .manualRun, note: noteSentinel, abortReason: .legacyUnknown(abortSentinel),
                       metrics: ["freeText": .string(metricSentinel), "tapCount": .number(2)])
        // Liveness: the sentinels really are on disk.
        let onDisk = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: run.spikeID, location: location).first)
        XCTAssertEqual(onDisk.note, noteSentinel)
        XCTAssertEqual(onDisk.abortReason, .legacyUnknown(abortSentinel))
        XCTAssertEqual(onDisk.metrics["freeText"], .string(metricSentinel))

        let outcome10 = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome10, .uploaded(rows: 1))
        let optOutBytes = String(decoding: try XCTUnwrap(TelemetryHTTPStub.all.last?.body), as: UTF8.self)
        XCTAssertFalse(optOutBytes.isEmpty, "liveness: a body was captured")
        XCTAssertFalse(optOutBytes.contains(noteSentinel))
        XCTAssertFalse(optOutBytes.contains(abortSentinel))
        XCTAssertFalse(optOutBytes.contains(metricSentinel))
        XCTAssertTrue(optOutBytes.contains("\"tapCount\""), "positive control: the numeric metric did go out")

        // Opt in, re-append (new revision), send again: only the note appears.
        defaults.set(true, forKey: AppSettingsKeys.telemetryNoteUploadsEnabled)
        XCTAssertTrue(SpikeRunStore.setNote(noteSentinel, forRunID: run.id, spikeID: run.spikeID, location: location))
        let outcome11 = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome11, .uploaded(rows: 1))
        let optInBytes = String(decoding: try XCTUnwrap(TelemetryHTTPStub.all.last?.body), as: UTF8.self)
        XCTAssertTrue(optInBytes.contains(noteSentinel), "positive control: the note switch lets the note out")
        XCTAssertFalse(optInBytes.contains(abortSentinel), "the abort text has no switch — ever")
        XCTAssertFalse(optInBytes.contains(metricSentinel), "nor does an unregistered string metric")
        XCTAssertEqual(uploader.lastRequestBodyPreview?.contains(noteSentinel), true, "the sample sheet shows what was sent")
    }

    // MARK: 6 — consent watermark

    /// Design §11 test 6. Three real lifecycle cycles through a wired center
    /// with the switch OFF → zero requests (the center flushes, the uploader
    /// is triggered, nothing leaves). Then consent at `t`: the first batch
    /// has no record started before `t`, and none owned by another account.
    ///
    /// Mutant: delete `$0.startedAt >= consentAt` in `TelemetryConsent.filter`
    /// → `early` is in the batch and the "no record before t" assertion
    /// fails. Mutant: delete `$0.ownerUID == currentOwner` → `foreign` is sent.
    func testSwitchOffThroughThreeLifecycleCyclesSendsNothingAndConsentGatesByStartAndOwner() async throws {
        // "Zero requests" is judged at the HTTP layer (the stub on the shared
        // session), not at the gateway seam — the same instrument as test 1.
        TelemetryHTTPStub.install()
        TelemetryHTTPStub.reset()
        let uploader = makeUploader()
        _ = attachRealGateway(uploader)
        defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: clock.addingTimeInterval(-3600))

        let coordinator = SpikeSessionCoordinator()
        let center = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { [unowned self] in self.clock }, mediaNow: { CACurrentMediaTime() },
            ownerUID: { [uid] in uid }
        )
        center.onUploadTrigger = { [weak uploader] trigger in uploader?.schedule(trigger) }
        center.activate()
        defer { center.deactivate() }

        for cycle in 0..<3 {
            SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            await uploader.drain()
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            XCTAssertEqual(TelemetryHTTPStub.all.count, 0, "cycle \(cycle): switch OFF → zero HTTP requests")
            XCTAssertEqual(uploader.lastOutcome, .switchOff, "cycle \(cycle): the trigger did reach the uploader")
        }
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location).count, 1,
                       "liveness: the center did flush a daily each cycle (same id, collapsed)")

        // Consent at t, later than the three cycles: only records minted
        // at/after t, only this account's.
        clock = clock.addingTimeInterval(300)
        let t = clock
        let early = seed(kind: .window, startedAt: t.addingTimeInterval(-60))
        let onTime = seed(kind: .window, startedAt: t)
        let later = seed(kind: .window, startedAt: t.addingTimeInterval(60))
        let foreign = seed(kind: .window, startedAt: t.addingTimeInterval(120), owner: TelemetryFixtures.otherUID)
        let signedOut = seed(kind: .window, startedAt: t.addingTimeInterval(180), owner: nil)
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: t)
        clock = t.addingTimeInterval(600)

        let outcome = await uploader.uploadNow(trigger: .launch)
        // The center's daily was minted BEFORE t (startedAt = the first
        // flush's clock) — the watermark excludes it too.
        XCTAssertEqual(outcome, .uploaded(rows: 2))
        XCTAssertEqual(TelemetryHTTPStub.all.count, 1, "positive control: one HTTP request carried the batch")
        let sentIDs = Set(httpSentRunIDs())
        XCTAssertEqual(sentIDs, [onTime.id.uuidString.lowercased(), later.id.uuidString.lowercased()])
        XCTAssertFalse(sentIDs.contains(early.id.uuidString.lowercased()), "no record started before t")
        XCTAssertFalse(sentIDs.contains(foreign.id.uuidString.lowercased()), "another account's record is never sent")
        XCTAssertFalse(sentIDs.contains(signedOut.id.uuidString.lowercased()), "a signed-out record is never sent")
    }

    /// Review P1-1: a signed-out stretch (owner nil) closed out by the
    /// center when account B signs in must STAY nil even though the store's
    /// provider now answers "B" — and therefore never reach the server.
    /// B's own fresh daily does. Positive control: with the provider
    /// installed, a manual run (no explicit owner) does get B.
    func testASignedOutDailyClosedAfterSignInStaysOwnerlessAndIsNotUploaded() async throws {
        // Account B is a real uid: the Redactor whitelists `user_id` as a
        // UUID, and the fake server's RLS is B's — the rig's default server
        // is account A's and would (rightly) refuse B's rows.
        let b = TelemetryFixtures.otherUID
        let owner = Box<String?>(nil)
        SpikeRunStore.ownerProvider = { owner.value }
        server = SyncFakeServer(userId: b)
        let uploader = makeUploader()
        attachFakeServer(uploader, userID: b)
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: clock.addingTimeInterval(-3600))

        let coordinator = SpikeSessionCoordinator()
        let center = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { [unowned self] in self.clock }, mediaNow: { CACurrentMediaTime() },
            ownerUID: { owner.value }
        )
        center.onUploadTrigger = { [weak uploader] trigger in uploader?.schedule(trigger) }
        center.activate()
        defer { center.deactivate() }

        // Signed out: counts accrue under a nil owner; the deck flush
        // triggers an upload that finds nothing it may send.
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()
        await uploader.drain()
        XCTAssertEqual(uploader.lastOutcome, .nothingPending, "an owner-less record is never pending for B")
        let signedOut = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location).first)
        XCTAssertNil(signedOut.ownerUID, "liveness: the signed-out daily is owner-less on disk")

        // B signs in; the next flush closes the nil-owner id and mints B's.
        owner.value = b
        clock = clock.addingTimeInterval(60)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()        // closes the signed-out record (2 counts), mints B's id
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()        // B's first line
        await uploader.drain()
        // (`lastOutcome` is the merged follow-up's `.nothingPending`; the
        // request count and the server row are the positive control.)
        XCTAssertEqual(telemetryRequests().count, 1, "positive control: exactly one upsert went out, for B")

        let dailies = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
        XCTAssertEqual(dailies.count, 2)
        let closed = try XCTUnwrap(dailies.first { $0.id == signedOut.id })
        XCTAssertNil(closed.ownerUID, "the close-out keeps nil: the provider's B must not be stamped over it")
        XCTAssertEqual(closed.metrics["meComputedVisible"], .number(2))
        let bDaily = try XCTUnwrap(dailies.first { $0.id != signedOut.id })
        XCTAssertEqual(bDaily.ownerUID, b)

        XCTAssertNotNil(server.telemetryRow(runID: bDaily.id), "B's daily went out")
        XCTAssertNil(server.telemetryRow(runID: signedOut.id), "the signed-out counts never leave the device")

        // Positive control: a writer that does NOT decide gets the provider's B.
        var manual = TelemetryFixtures.run(spikeID: Spike201SignalID.spikeID, scenarioID: "default",
                                           startedAt: clock, ownerUID: nil, kind: nil, revision: nil)
        manual.outcome = .completed
        XCTAssertTrue(SpikeRunStore.finishRun(manual, location: location))
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: manual.spikeID, location: location).first?.ownerUID, b)
    }

    /// The switch's OFF → ON edge: the view records consent NOW (the one
    /// write, review P2-4), then the uploader tries once; ON → OFF drops a
    /// queued follow-up. The watermark moves forward on each OFF → ON, so
    /// the gap between stays local.
    func testTheSwitchEdgeTriesOnceAgainstTheConsentTheViewJustWrote() async throws {
        TelemetryHTTPStub.install()
        TelemetryHTTPStub.reset()
        let uploader = makeUploader()
        _ = attachRealGateway(uploader)
        defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        let before = seed(kind: .window, startedAt: clock.addingTimeInterval(-10))
        clock = clock.addingTimeInterval(100)

        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        // What `DataPrivacySettingsView.onChange` does before telling the uploader.
        TelemetryConsentStore.recordGrant(defaults, at: clock)
        uploader.switchDidChange(from: false, to: true)
        XCTAssertEqual(TelemetryConsentStore.consentAt(defaults), clock, "consent is NOW, not when the record was minted")
        await uploader.drain()
        XCTAssertEqual(uploader.lastOutcome, .nothingPending, "tried once; `before` predates consent")
        XCTAssertEqual(TelemetryHTTPStub.all.count, 0, "zero HTTP requests: nothing eligible")
        _ = before

        let after = seed(kind: .window, startedAt: clock.addingTimeInterval(1))
        let outcome12 = await uploader.uploadNow(trigger: .deckOpen)
        XCTAssertEqual(outcome12, .uploaded(rows: 1))
        XCTAssertEqual(TelemetryHTTPStub.all.count, 1, "positive control: one HTTP request")
        XCTAssertEqual(httpSentRunIDs(), [after.id.uuidString.lowercased()])
    }

    /// Review P2-3: the day's record was minted at launch (T0), consent
    /// comes at T1 > T0. Without a re-mint every count of the day would sit
    /// behind a pre-consent `startedAt` and never upload ("first-day
    /// silence"). On OFF → ON the center closes the T0 id (local only) and
    /// mints a new id at T1; the next flush writes it and it goes out.
    func testConsentRemintsTheDailySoTheDaysCountsUploadFromTheConsentMomentOn() async throws {
        let uploader = makeUploader()
        attachFakeServer(uploader)
        defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled)

        let coordinator = SpikeSessionCoordinator()
        let center = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { [unowned self] in self.clock }, mediaNow: { CACurrentMediaTime() },
            ownerUID: { [uid] in uid }
        )
        center.onUploadTrigger = { [weak uploader] trigger in uploader?.schedule(trigger) }
        uploader.onConsentGranted = { [weak center] in center?.remintDailyForConsent() }
        center.activate()
        defer { center.deactivate() }

        // T0: launch-time daily, counts accrue, a flush writes it.
        let t0 = clock
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()
        await uploader.drain()
        let preConsent = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location).first)
        XCTAssertEqual(preConsent.startedAt, t0)

        // T1: the user turns the switch on — the view writes consent, then
        // tells the uploader, which re-mints through the center.
        clock = t0.addingTimeInterval(600)
        let t1 = clock
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: t1)
        uploader.switchDidChange(from: false, to: true)
        await uploader.drain()
        XCTAssertEqual(server.telemetryRowCount(), 0, "nothing minted at or after consent exists yet")

        // Counts after consent land on the new id; a flush writes and sends it.
        clock = t1.addingTimeInterval(30)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()
        await uploader.drain()

        let dailies = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
        XCTAssertEqual(dailies.count, 2, "the T0 id was closed, a new id minted")
        let fresh = try XCTUnwrap(dailies.first { $0.id != preConsent.id })
        XCTAssertGreaterThanOrEqual(fresh.startedAt, t1, "the new id starts at or after consent")
        XCTAssertEqual(fresh.metrics["meComputedVisible"], .number(2), "post-consent counts only")
        XCTAssertNotNil(server.telemetryRow(runID: fresh.id), "and it uploads")
        XCTAssertNil(server.telemetryRow(runID: preConsent.id), "the pre-consent record never leaves")
        XCTAssertEqual(server.telemetryRowCount(), 1)
    }

    // MARK: 7 — erase

    /// Design §11 test 7 (B·F39). The cursor, the install id and the sample
    /// live inside `spike-runs/`, so the erase's own `SpikeRunStore.wipe()`
    /// (pinned by name in EraseWiringQATests) takes them; afterwards the
    /// first request body carries a NEW `install_id`.
    ///
    /// Run against the PRODUCTION location — redirected to
    /// `spike-runs-test-host` under XCTest — because `wipe()` with no
    /// argument is the exact call `LocalDataEraser.resetAllLocalData` makes.
    /// The eraser itself is not driven here: constructing it needs the live
    /// `AgentRuntime` and `ImageBackupCoordinator`, and it writes
    /// `UserDefaults.standard` and signs the host's `AuthService` out, which
    /// the rest of this process's suite would then see.
    func testWipeTakesCursorAndInstallIDAndTheNextUploadCarriesANewInstallID() async throws {
        let production = SpikeRunStorageLocation.production
        XCTAssertTrue(EventStorageLocation.isRunningUnderXCTest, "rig: the production location must be the test-host redirect")
        XCTAssertTrue(production.directory.lastPathComponent == "spike-runs-test-host")
        SpikeRunStore.wipe()
        defer { SpikeRunStore.wipe() }

        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = production
        deps.now = { [unowned self] in self.clock }
        deps.makeKeepAlive = { nil }
        let uploader = TelemetryUploader(dependencies: deps)
        attachFakeServer(uploader)
        turnOn()
        let run = TelemetryFixtures.run(startedAt: clock, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(run, location: production))
        let outcome13 = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome13, .uploaded(rows: 1))
        let installBefore = try XCTUnwrap(server.telemetryRow(runID: run.id)?.data["install_id"] as? String)

        // Structural fact the erase relies on: all three side files are
        // under the directory `wipe()` removes.
        for url in [SpikeRunStore.installIDURL(location: production), SpikeRunStore.uploadCursorURL(location: production),
                    SpikeRunStore.lastUploadSampleURL(location: production)] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "liveness: \(url.lastPathComponent) exists after an upload")
            XCTAssertEqual(url.deletingLastPathComponent(), production.directory)
        }

        SpikeRunStore.wipe()   // the erase's call, verbatim

        XCTAssertFalse(FileManager.default.fileExists(atPath: SpikeRunStore.uploadCursorURL(location: production).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpikeRunStore.installIDURL(location: production).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpikeRunStore.lastUploadSampleURL(location: production).path))

        // The next install: a new record, a new uploader, a new install id on the wire.
        let fresh = TelemetryUploader(dependencies: deps)
        attachFakeServer(fresh)
        let afterRun = TelemetryFixtures.run(startedAt: clock.addingTimeInterval(1), revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(afterRun, location: production))
        let outcome14 = await fresh.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome14, .uploaded(rows: 1))
        let installAfter = try XCTUnwrap(server.telemetryRow(runID: afterRun.id)?.data["install_id"] as? String)
        XCTAssertNotEqual(installAfter, installBefore, "an erased phone is a new install to the server")
        XCTAssertEqual(fresh.totalAcknowledged, 1, "and the cursor started empty")
    }

    /// Review P2-6: an entry for a record the pool no longer holds is
    /// dropped after the next successful batch; the cumulative count is its
    /// own monotonic number, not the cursor's size, so pruning does not
    /// shrink "累计". Positive control: the live record's entry survives.
    func testASuccessfulBatchPrunesOrphanCursorEntriesWithoutShrinkingTheCumulativeCount() async throws {
        let orphan = UUID()
        let seeded = UploadCursor(uploaded: [orphan: 3], quarantined: [orphan: 4], totalAcknowledged: 7)
        XCTAssertTrue(SpikeRunStore.saveUploadCursor(seeded, location: location))
        let uploader = makeUploader()
        attachFakeServer(uploader)
        turnOn()
        XCTAssertEqual(uploader.totalAcknowledged, 7, "read back from the cursor at init")
        let live = seed()
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .uploaded(rows: 1))
        let cursor = SpikeRunStore.loadUploadCursor(location: location)
        XCTAssertNil(cursor.uploaded[orphan], "the orphan is gone")
        XCTAssertNil(cursor.quarantined[orphan])
        XCTAssertEqual(cursor.uploaded[live.id], 1, "positive control: the live record's entry is kept")
        XCTAssertEqual(cursor.totalAcknowledged, 8, "7 before + 1 row now; pruning took nothing away")
        XCTAssertEqual(uploader.totalAcknowledged, 8)
    }

    // MARK: Store stamping

    /// Round-2 ruling 1: a manual spike run — written by `beginRun` /
    /// `finishRun` with no owner, by a runner that knows nothing about
    /// sessions — gets the signed-in account stamped by the store's owner
    /// provider, and with consent on it is uploaded. Positive control: with
    /// no provider the same record stays owner-less and is NOT uploaded.
    func testAManualRunGetsTheOwnerStampedByTheStoreAndIsUploaded() async throws {
        let uploader = makeUploader()
        attachFakeServer(uploader)
        turnOn()

        // No provider (the XCTest default): owner-less, filtered out.
        var unowned = TelemetryFixtures.run(spikeID: Spike201SignalID.spikeID, scenarioID: "default",
                                            startedAt: clock, endedAt: nil, ownerUID: nil, kind: nil, revision: nil)
        unowned.outcome = nil
        XCTAssertTrue(SpikeRunStore.beginRun(unowned, location: location))
        unowned.endedAt = clock.addingTimeInterval(5)
        unowned.outcome = .completed
        XCTAssertTrue(SpikeRunStore.finishRun(unowned, location: location))
        XCTAssertNil(SpikeRunStore.loadRuns(spikeID: unowned.spikeID, location: location).first?.ownerUID)
        let before = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(before, .nothingPending, "positive control: an owner-less manual run never leaves")

        // The provider the uploader installs in the app (`activate()`).
        SpikeRunStore.ownerProvider = { [uid] in uid }
        var manual = TelemetryFixtures.run(spikeID: Spike201SignalID.spikeID, scenarioID: "default",
                                           startedAt: clock.addingTimeInterval(10), endedAt: nil,
                                           ownerUID: nil, kind: nil, revision: nil)
        manual.outcome = nil
        XCTAssertTrue(SpikeRunStore.beginRun(manual, location: location))
        manual.endedAt = clock.addingTimeInterval(15)
        manual.outcome = .completed
        XCTAssertTrue(SpikeRunStore.finishRun(manual, location: location))
        let stored = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: manual.spikeID, location: location).first { $0.id == manual.id })
        XCTAssertEqual(stored.ownerUID, uid, "the store stamped the owner the runner never knew")
        XCTAssertEqual(stored.revision, 2, "open + closed = two appends")
        XCTAssertNil(stored.kind, "the runner stamps no kind; the wire infers manual_run")

        let after = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(after, .uploaded(rows: 1))
        let row = try XCTUnwrap(server.telemetryRow(runID: manual.id))
        XCTAssertEqual(row.data["kind"] as? String, "manual_run")
        XCTAssertEqual(row.data["user_id"] as? String, uid)
        XCTAssertNil(server.telemetryRow(runID: unowned.id), "the owner-less one still did not go")

        // A writer's own non-nil owner is kept (the center's close-out of a
        // previous owner's record relies on this).
        SpikeRunStore.ownerProvider = { "someone-else" }
        let claimed = TelemetryFixtures.run(ownerUID: "qa-a", revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(claimed, location: location))
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: claimed.spikeID, location: location).first { $0.id == claimed.id }?.ownerUID, "qa-a")
    }

    func testTheStoreStampsAMonotonicRevisionAndTheInstallIDAcrossAppendsAndRelaunch() throws {
        let id = UUID()
        let run = TelemetryFixtures.run(id: id, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(run, location: location))
        XCTAssertTrue(SpikeRunStore.setNote("one", forRunID: id, spikeID: run.spikeID, location: location))
        XCTAssertTrue(SpikeRunStore.setNote("two", forRunID: id, spikeID: run.spikeID, location: location))
        let latest = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: run.spikeID, location: location).first { $0.id == id })
        XCTAssertEqual(latest.revision, 3)
        XCTAssertEqual(latest.installID, SpikeRunStore.installID(location: location))

        // A record the caller stamped with its own revision is overwritten.
        var forged = run
        forged.revision = 99
        XCTAssertTrue(SpikeRunStore.finishRun(forged, location: location))
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: run.spikeID, location: location).first { $0.id == id }?.revision, 4)

        // Raw lines, in order, carry 1, 2, 3, 4.
        let url = location.directory.appendingPathComponent("\(run.spikeID).jsonl")
        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(lines.compactMap { try? decoder.decode(SpikeRun.self, from: Data($0.utf8)).revision }, [1, 2, 3, 4])
        XCTAssertEqual(SpikeRunStore.spikeIDsOnDisk(location: location), [run.spikeID], "dotfiles are not record files")
    }
}

// MARK: - 9 — claim key at the center

/// A mutable cell the test can flip while a closure the center or store
/// holds reads it (owner, build, zone).
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
final class TelemetryClaimKeyCenterTests: XCTestCase {

    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var centers: [ResidentObservationCenter] = []

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
    }

    override func tearDown() {
        for center in centers { center.deactivate() }
        centers = []
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    /// The flush-time stamp, with the process zone as a knob: in the app
    /// `SpikeRunContext.stamp()` reads `TimeZone.current` at each flush,
    /// which is exactly the source B·F17 says the day key must NOT come from.
    private func stamp(build: String = "10", os: String = "26.0", zone: String = "America/Los_Angeles") -> SpikeRunContext.Stamp {
        SpikeRunContext.Stamp(appVersion: "0.5.0", appBuild: build, appCommit: nil, deviceModel: "iPhone17,2",
                              osVersion: os, timeZoneIdentifier: zone,
                              localeIdentifier: "en_US", buildConfiguration: SpikeRunContext.buildConfiguration)
    }

    private func makeCenter(
        clock: Box<Date>, owner: Box<String?>, build: Box<String>,
        zone: Box<String> = Box("America/Los_Angeles"), calendar: Calendar = .current
    ) -> ResidentObservationCenter {
        let center = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: calendar,
            now: { clock.value }, mediaNow: { CACurrentMediaTime() },
            ownerUID: { owner.value }, stamp: { [unowned self] in self.stamp(build: build.value, zone: zone.value) }
        )
        centers.append(center)
        center.activate()
        return center
    }

    private func dailies() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    /// Design §11 test 9: build 10 in the morning, TestFlight updates to 11
    /// at noon → two same-day dailies, each under its own build (B·F15).
    /// Positive control: the same build relaunched adopts the one id.
    func testASameDayBuildChangeMintsASecondDailyWhereTheSameBuildAdopts() throws {
        let clock = Box(Date())
        let owner = Box<String?>("a")
        let build = Box("10")
        let morning = makeCenter(clock: clock, owner: owner, build: build)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        morning.flushDaily()
        morning.deactivate()

        let sameBuild = makeCenter(clock: clock, owner: owner, build: build)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        sameBuild.flushDaily()
        sameBuild.deactivate()
        XCTAssertEqual(dailies().count, 1, "positive control: same claim → the one id is adopted")
        XCTAssertEqual(dailies().first?.metrics["meComputedVisible"], .number(2))

        build.value = "11"
        let afternoon = makeCenter(clock: clock, owner: owner, build: build)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        afternoon.flushDaily()
        afternoon.deactivate()

        let records = dailies().sorted { ($0.appBuild, $0.startedAt) < ($1.appBuild, $1.startedAt) }
        // A guard, not an assert-then-subscript: a wrong count must fail
        // this test, not trap the runner and hide every verdict after it.
        guard records.count == 2 else { return XCTFail("a build change mints a new same-day id; got \(records.count) dailies") }
        XCTAssertEqual(records[0].appBuild, "10")
        XCTAssertEqual(records[0].metrics["meComputedVisible"], .number(2), "the morning's counts stay under build 10")
        XCTAssertEqual(records[1].appBuild, "11")
        XCTAssertEqual(records[1].metrics["meComputedVisible"], .number(1))
        XCTAssertNotEqual(records[0].id, records[1].id)
        XCTAssertEqual(records.map(\.kind), [.dailyRollup, .dailyRollup])
    }

    /// Same day, account a → account b (qa-a → qa-b on the staging rig):
    /// two dailies, owners differ (B·F16). Also the in-process switch: the
    /// flush that first sees the new owner closes a's id and mints b's.
    func testASameDayOwnerChangeMintsASecondDailyWithItsOwnOwner() throws {
        let clock = Box(Date())
        let owner = Box<String?>("qa-a")
        let build = Box("10")
        let first = makeCenter(clock: clock, owner: owner, build: build)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        first.flushDaily()
        first.deactivate()

        owner.value = "qa-b"
        let second = makeCenter(clock: clock, owner: owner, build: build)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        second.flushDaily()

        var records = dailies()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap(\.ownerUID)), ["qa-a", "qa-b"])
        XCTAssertEqual(records.first { $0.ownerUID == "qa-a" }?.metrics["meComputedVisible"], .number(1))
        XCTAssertEqual(records.first { $0.ownerUID == "qa-b" }?.metrics["meComputedVisible"], .number(2))

        // In-process switch: b signs out, c signs in, no relaunch.
        owner.value = "qa-c"
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        second.flushDaily()   // closes b (3 counts), mints c with nothing to write yet
        records = dailies()
        XCTAssertEqual(records.count, 2, "c has counted nothing yet — no empty record")
        XCTAssertEqual(records.first { $0.ownerUID == "qa-b" }?.metrics["meComputedVisible"], .number(3),
                       "the signals before the flush land on the owner who was signed in")
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        second.flushDaily()
        records = dailies()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.first { $0.ownerUID == "qa-c" }?.metrics["meComputedVisible"], .number(1))
        second.deactivate()
    }

    /// LA → Tokyo mid-day (B·F17): the record's `dayKey` comes from the
    /// center's boundary calendar, minted once; the flush-time zone (what
    /// the stamp records as `timeZoneIdentifier`) changes and nothing else.
    /// The counterfactual is spelled out: 09:00 LA on the 21st IS the 22nd
    /// in Tokyo, so a key derived from the flush zone would have moved.
    func testFlippingTheProcessZoneLeavesTheMintedDayKeyAlone() throws {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let clock = Box(try XCTUnwrap(la.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9))))
        let owner = Box<String?>("a")
        let build = Box("10")
        let zone = Box("America/Los_Angeles")
        let center = makeCenter(clock: clock, owner: owner, build: build, zone: zone, calendar: la)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()
        let before = try XCTUnwrap(dailies().first)
        XCTAssertEqual(before.dayKey, "2026-09-21")
        XCTAssertEqual(before.dayTZOffsetMin, -420)
        XCTAssertEqual(before.timeZoneIdentifier, "America/Los_Angeles")

        // The plane lands: the flush-time zone is now Tokyo.
        zone.value = "Asia/Tokyo"
        clock.value = clock.value.addingTimeInterval(60)
        XCTAssertEqual(TelemetryClaimKey.dayKey(forDayStart: tokyo.startOfDay(for: clock.value), calendar: tokyo).dayKey,
                       "2026-09-22", "counterfactual: a key re-derived in the flush zone would say the 22nd")
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()
        let after = try XCTUnwrap(dailies().first)
        XCTAssertEqual(dailies().count, 1, "same id — the zone change is not a claim change")
        XCTAssertEqual(after.dayKey, "2026-09-21", "minted from the boundary calendar, not re-derived")
        XCTAssertEqual(after.dayTZOffsetMin, -420)
        XCTAssertEqual(after.timeZoneIdentifier, "Asia/Tokyo", "liveness: the flush really saw the new zone")
    }

    /// B·F6: a flush with nothing new appends nothing; a rollover always
    /// closes the day's line at its day end even with nothing new.
    func testAnUnchangedFlushAppendsNoLineWhileRolloverAlwaysCloses() throws {
        let calendar = Calendar.current
        let elevenPM = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date()))
        let clock = Box(elevenPM)
        let center = makeCenter(clock: clock, owner: Box<String?>("a"), build: Box("10"))
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()
        center.flushDaily()
        center.flushDaily()
        XCTAssertEqual(rawLineCount(), 1, "three flushes, one change → one line")
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        center.flushDaily()
        XCTAssertEqual(rawLineCount(), 2, "positive control: a change appends")

        clock.value = elevenPM.addingTimeInterval(2 * 3600)
        center.performRolloverFlushIfDue()
        XCTAssertEqual(rawLineCount(), 3, "the rollover closes the line at day end even with nothing new")
        XCTAssertEqual(dailies().first?.endedAt, calendar.startOfDay(for: clock.value))
    }

    private func rawLineCount() -> Int {
        let url = location.directory.appendingPathComponent("\(FixObservationRegistry.residentDailySpikeID).jsonl")
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).count
    }
}
