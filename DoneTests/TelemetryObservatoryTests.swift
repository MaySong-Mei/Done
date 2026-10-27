//
//  TelemetryObservatoryTests.swift
//  DoneTests
//
//  gh#273 §16 — "the observatory IS data collection": the TestFlight
//  default (on, distant-past watermark, never against the user's own
//  "off"), the backfill loop (batches until drained), and the observatory's
//  read of this account's cloud rows (stable paging, merge, fallback).
//  Every absence is paired with a positive control.
//

import XCTest
@testable import Done

/// A JSONL line as a build before the chassis wrote it — no `revision`,
/// `kind`, `ownerUID` or `installID` — written past the store, which would
/// stamp all four.
private func writeLegacyLine(_ run: SpikeRun, location: SpikeRunStorageLocation) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(run)
    let text = String(decoding: data, as: UTF8.self)
    data.append(0x0A)
    try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
    let url = location.directory.appendingPathComponent("\(run.spikeID).jsonl")
    if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } else {
        try data.write(to: url)
    }
    return text
}

/// A small rig every class here shares: a scratch pool, a scratch defaults
/// suite, account A's fake server, and a clock.
@MainActor
private final class ObservatoryRig {
    let uid = TelemetryFixtures.uid
    let location = SpikeRunStorageLocation.ephemeral(id: UUID())
    let suiteName = "TelemetryObservatoryTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let server: SyncFakeServer
    var clock = TelemetryFixtures.t0
    var detectorCalls = 0

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        server = SyncFakeServer(userId: TelemetryFixtures.uid)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        defaults.removePersistentDomain(forName: suiteName)
        SpikeRunStore.ownerProvider = nil
    }

    func uploader(isTestFlight: Bool = false, cloudReader: TelemetryCloudReading? = nil,
                  signedIn: Bool = true, attached: Bool = true) -> TelemetryUploader {
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.now = { [unowned self] in self.clock }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.isTestFlight = { [unowned self] in
            self.detectorCalls += 1
            return isTestFlight
        }
        let uploader = TelemetryUploader(dependencies: deps)
        if attached {
            uploader.attach(TelemetryUploader.Attachment(
                gateway: server, isBlockedByBuild: { false },
                currentUserID: { [uid] in signedIn ? uid : nil }, isSignedIn: { signedIn },
                cloudReader: cloudReader
            ))
        }
        return uploader
    }

    var switchOn: Bool { defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled) }
    var upserts: [SyncFakeServer.Request] { server.requests(.telemetryUpsert) }

    @discardableResult
    func seed(_ count: Int, kind: TelemetryRecordKind, ageMinutes: Double = 0) -> [SpikeRun] {
        (0..<count).map { index in
            let started = clock.addingTimeInterval(-(ageMinutes + Double(index)) * 60)
            let isDaily = kind == .dailyRollup
            let run = TelemetryFixtures.run(
                spikeID: isDaily ? FixObservationRegistry.residentDailySpikeID : FixObservationRegistry.effortPathFixID,
                scenarioID: isDaily ? FixObservationRegistry.residentDailyScenarioID : FixObservationRegistry.windowScenarioID,
                startedAt: started, endedAt: started.addingTimeInterval(30), kind: kind, revision: nil
            )
            XCTAssertTrue(SpikeRunStore.finishRun(run, location: location), "seed must land")
            return run
        }
    }
}

// MARK: - TestFlight default (§16 rule 2)

@MainActor
final class TelemetryTestFlightDefaultTests: XCTestCase {
    private var rig: ObservatoryRig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryRig()
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    /// A TestFlight install the user has not ruled on switches on, with the
    /// watermark in the distant past: account-stamped history from long
    /// before any consent goes up ("补传"). What §16 does NOT adopt stays
    /// home — a line older than the chassis (no revision, no owner) and a
    /// signed-out record (owner nil). The owned record is the positive
    /// control that the backfill really ran.
    func testATestFlightInstallSwitchesOnAndBackfillsOwnedHistoryButNotLegacyOrSignedOutRecords() async throws {
        let day: TimeInterval = 86_400
        let owned = TelemetryFixtures.run(startedAt: rig.clock - 30 * day, endedAt: rig.clock - 30 * day + 60, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(owned, location: rig.location))
        let signedOut = TelemetryFixtures.run(startedAt: rig.clock - 20 * day, endedAt: rig.clock - 20 * day + 60,
                                              ownerUID: nil, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(signedOut, owner: .explicit(nil), location: rig.location))
        let legacy = TelemetryFixtures.run(startedAt: rig.clock - 40 * day, endedAt: rig.clock - 40 * day + 60,
                                           ownerUID: nil, kind: nil, revision: nil, dayKey: nil, dayTZOffsetMin: nil)
        let legacyLine = try writeLegacyLine(legacy, location: rig.location)
        XCTAssertFalse(legacyLine.contains("\"revision\""), "rig: the legacy line carries no revision")
        XCTAssertFalse(legacyLine.contains("\"ownerUID\""), "rig: nor an owner")
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: owned.spikeID, location: rig.location).count, 3, "liveness: all three on disk")

        let uploader = rig.uploader(isTestFlight: true)
        let switchedOn = await uploader.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(switchedOn)
        XCTAssertTrue(rig.switchOn)
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), .distantPast, "TestFlight backfills: the watermark is the distant past")
        XCTAssertFalse(rig.defaults.bool(forKey: AppSettingsKeys.telemetryNoteUploadsEnabled), "the note never comes on by default")
        XCTAssertFalse(TelemetryConsentStore.userHasDecided(rig.defaults), "the default is not the user's decision")

        await uploader.drain()
        XCTAssertEqual(uploader.lastOutcome, .uploaded(rows: 1))
        XCTAssertNotNil(rig.server.telemetryRow(runID: owned.id), "positive control: 30-day-old owned history went up")
        XCTAssertNil(rig.server.telemetryRow(runID: legacy.id), "a line older than the chassis is never adopted")
        XCTAssertNil(rig.server.telemetryRow(runID: signedOut.id), "a signed-out record never leaves the device")
        XCTAssertEqual(rig.server.telemetryRowCount(), 1)
    }

    /// Not TestFlight (the App Store, Xcode, or StoreKit could not answer):
    /// nothing changes and nothing is sent.
    func testAnInstallThatIsNotTestFlightStaysOff() async {
        rig.seed(3, kind: .window)
        let uploader = rig.uploader(isTestFlight: false)
        let switchedOn = await uploader.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(switchedOn)
        XCTAssertEqual(rig.detectorCalls, 1, "liveness: the detector was asked")
        XCTAssertFalse(rig.switchOn)
        XCTAssertNil(TelemetryConsentStore.consentAt(rig.defaults))
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .switchOff)
        XCTAssertTrue(rig.upserts.isEmpty)
    }

    /// The user turned it off on Fix Watch; a later version on TestFlight
    /// never turns it back on — the detector is not even asked. Positive
    /// control first: untouched defaults DO get the default.
    func testAUserWhoTurnedItOffIsNeverTurnedBackOnByTheDefault() async {
        let first = rig.uploader(isTestFlight: true)
        let defaulted = await first.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(defaulted, "positive control: an untouched TestFlight install gets the default")

        // The toggle binding writes the value, then runs the edge.
        rig.defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetrySwitchEdge.apply(from: true, to: false, defaults: rig.defaults, now: rig.clock, uploader: first)
        XCTAssertTrue(TelemetryConsentStore.userHasDecided(rig.defaults))

        let callsBefore = rig.detectorCalls
        let upgraded = rig.uploader(isTestFlight: true)
        let again = await upgraded.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(again)
        XCTAssertEqual(rig.detectorCalls, callsBefore, "a decided user is not even a question for StoreKit")
        XCTAssertFalse(rig.switchOn)
        let outcome = await upgraded.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .switchOff)
    }

    /// A user who turned it ON themselves on this version has ruled too: the
    /// default never rewrites their watermark to the distant past (that
    /// would upload history from before the moment they chose). This is the
    /// case only the decided bit can tell — a stored `true` alone looks like
    /// build 17's undecided ON below. Positive control: the switch edge
    /// recorded the decision.
    func testAUserWhoTurnedItOnThemselvesKeepsTheirOwnWatermark() async {
        let uploader = rig.uploader(isTestFlight: true)
        let chosen = rig.clock.addingTimeInterval(0.5)
        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetrySwitchEdge.apply(from: false, to: true, defaults: rig.defaults, now: chosen, uploader: nil)
        XCTAssertTrue(TelemetryConsentStore.userHasDecided(rig.defaults), "positive control: the flip is a decision")

        let defaulted = await uploader.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(defaulted)
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), chosen, "the user's own moment stands")
        XCTAssertEqual(rig.detectorCalls, 0, "a decided user is not a question for StoreKit")
    }

    /// Phones that already ran build 17: a switch left stored OFF is the
    /// user's own "off" (the key is unregistered — only the user writes
    /// `false`), so the default leaves it alone. A switch the user turned ON
    /// there gets the backfill watermark — that user asked for it.
    func testBuild17StateIsReadAsTheUsersOwnAnswer() async {
        rig.defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        let leftOff = rig.uploader(isTestFlight: true)
        let defaultedOff = await leftOff.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(defaultedOff, "a stored OFF from build 17 is a decision")
        XCTAssertFalse(rig.switchOn)

        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(rig.defaults, at: rig.clock.addingTimeInterval(-600))
        let turnedOn = rig.uploader(isTestFlight: true)
        let defaultedOn = await turnedOn.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(defaultedOn, "build 17's manual ON carried no decided bit")
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), .distantPast, "and now backfills")
    }

    /// The decided bit is the previous owner's: swept by the erase, never a
    /// registered default (a registered value would survive the sweep).
    func testTheDecidedBitIsSweptByTheEraseAndNeverRegistered() {
        XCTAssertTrue(AppSettingsKeys.resettableUserDefaultsKeys.contains(AppSettingsKeys.telemetryUserDecided))
        XCTAssertNil(AppSettingsKeys.launchRegisteredDefaults[AppSettingsKeys.telemetryUserDecided])
        TelemetryConsentStore.recordDecision(rig.defaults)
        XCTAssertTrue(TelemetryConsentStore.userHasDecided(rig.defaults), "liveness")
        AppSettingsKeys.removeResettableKeys(from: rig.defaults)
        XCTAssertNil(rig.defaults.object(forKey: AppSettingsKeys.telemetryUserDecided))
        XCTAssertFalse(TelemetryConsentStore.userHasDecided(rig.defaults), "an erased phone is undecided again")
    }
}

// MARK: - Backfill loop (§16 rule 2)

@MainActor
final class TelemetryBackfillLoopTests: XCTestCase {
    private var rig: ObservatoryRig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryRig()
        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(rig.defaults, at: .distantPast)
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    private func bodySizes() -> [Int] {
        rig.upserts.map { ($0.body as? [[String: Any]])?.count ?? -1 }
    }

    /// 120 records of history, ONE trigger: 4 requests (32+32+32+24), the
    /// cursor covers all of them, and the next trigger sends nothing.
    func testOneTriggerSendsBatchesUntilNothingIsPending() async {
        rig.seed(120, kind: .window)
        let uploader = rig.uploader()
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .uploaded(rows: 120), "the trigger reports everything it moved")
        XCTAssertEqual(bodySizes(), [32, 32, 32, 24])
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: rig.location).uploaded.count, 120)
        XCTAssertEqual(rig.server.telemetryRowCount(), 120)
        XCTAssertEqual(uploader.lastBatchCount, 120, "the status line counts the trigger, not its last batch")

        let again = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(again, .nothingPending)
        XCTAssertEqual(rig.upserts.count, 4, "zero requests on the next trigger")
    }

    /// Any failure stops the loop; the next trigger picks up where it left.
    func testALoopStopsAtTheFirstFailureAndTheNextTriggerResumes() async {
        rig.seed(120, kind: .window)
        let uploader = rig.uploader()
        let server = rig.server
        server.failWhen = { verb, table in
            guard verb == .telemetryUpsert, server.requests(.telemetryUpsert).count == 2 else { return nil }
            return SupabaseREST.SyncError.requestFailed(table: table, method: "POST", status: 500, code: nil)
        }
        let stopped = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(stopped, .failed(kind: .retryable, code: "http500"), "the failure is the news")
        XCTAssertEqual(rig.upserts.count, 2, "one batch landed, the second failed, no third was tried")
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: rig.location).uploaded.count, 32)
        XCTAssertEqual(uploader.lastBatchCount, 32)

        server.failWhen = nil
        let resumed = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(resumed, .uploaded(rows: 88))
        XCTAssertEqual(rig.upserts.count, 5)
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: rig.location).uploaded.count, 120)
    }

    /// The daily throttle is judged once, at the trigger: an edge allowed to
    /// send dailies sends all 40, not only the first batch's 32. (Judged per
    /// batch, the first batch's daily would shut the gate on the rest.)
    func testAnEdgeAllowedDailiesSendsAllOfThemAcrossBatches() async {
        rig.seed(40, kind: .dailyRollup)
        let uploader = rig.uploader()
        let outcome = await uploader.uploadNow(trigger: .backgroundEdge)
        XCTAssertEqual(outcome, .uploaded(rows: 40))
        XCTAssertEqual(bodySizes(), [32, 8])
    }
}

// MARK: - Cloud paging (§16 rule 3)

/// Serves `rows` in the view's order (`day_key` desc, `run_id` asc), one
/// `limit`/`offset` page at a time; `beforePage` lets a test change the
/// table between pages, the way another device's upload would.
@MainActor
private final class FakeCloudReader: TelemetryCloudReading {
    var rows: [[String: Any]] = []
    var calls: [(limit: Int, offset: Int)] = []
    var beforePage: ((Int) -> Void)?
    var error: Error?

    static func row(day: String, id: Int, revision: Int = 1) -> [String: Any] {
        ["run_id": String(format: "00000000-0000-4000-8000-%012d", id), "day_key": day, "revision": revision]
    }

    func fetchMySpikeRunsPage(spikeIDs: [String], limit: Int, offset: Int) async throws -> [[String: Any]] {
        beforePage?(calls.count)
        calls.append((limit, offset))
        if let error { throw error }
        let ordered = rows.sorted { a, b in
            let (dayA, dayB) = (a["day_key"] as! String, b["day_key"] as! String)
            if dayA != dayB { return dayA > dayB }
            return (a["run_id"] as! String) < (b["run_id"] as! String)
        }
        return Array(ordered.dropFirst(offset).prefix(limit))
    }
}

@MainActor
final class TelemetryCloudPagerTests: XCTestCase {

    private func ids(_ rows: [[String: Any]]) -> [String] { rows.compactMap { $0["run_id"] as? String } }

    /// Two pages of three, and between them another device uploads a row
    /// for an OLDER day than page one ended on: every row after it shifts
    /// down, so page two starts with page one's last row. Nothing that
    /// existed when the walk began is lost, and nothing comes back twice.
    func testTwoPagesWithARowPushedAcrossTheBoundaryLoseNothingAndRepeatNothing() async throws {
        let reader = FakeCloudReader()
        let originals = (1...5).map { FakeCloudReader.row(day: "2026-10-0\($0)", id: $0) }
        reader.rows = originals
        reader.beforePage = { [unowned reader] page in
            if page == 1 { reader.rows.append(FakeCloudReader.row(day: "2026-10-04", id: 9)) }
        }
        let fetched = try await TelemetryCloudPager.fetchAll(from: reader, spikeIDs: ["resident-daily"], pageSize: 3)
        let got = ids(fetched)
        for id in ids(originals) {
            XCTAssertEqual(got.filter { $0 == id }.count, 1, "\(id) exactly once")
        }
        XCTAssertEqual(got.count, Set(got).count, "no repeats in the result")
        XCTAssertEqual(reader.calls.map(\.offset), [0, 3, 6], "a full page asks for the next; the empty one ends it")
        XCTAssertEqual(reader.calls.map(\.limit), [3, 3, 3])
    }

    /// A page shorter than the limit is the last; a row seen twice keeps
    /// its higher revision. Page one is full (three rows), so page two is
    /// asked for; between them the page's last row is updated (revision 2)
    /// and a new head row pushes it onto page two, which comes back with
    /// just that one row — short, so the walk ends there.
    func testAShortPageEndsTheWalkAndARepeatKeepsTheHigherRevision() async throws {
        let reader = FakeCloudReader()
        reader.rows = [FakeCloudReader.row(day: "2026-10-05", id: 1), FakeCloudReader.row(day: "2026-10-04", id: 2),
                       FakeCloudReader.row(day: "2026-10-03", id: 3)]
        reader.beforePage = { [unowned reader] page in
            if page == 1 {
                reader.rows[2]["revision"] = 2
                reader.rows.append(FakeCloudReader.row(day: "2026-10-06", id: 4))
            }
        }
        let fetched = try await TelemetryCloudPager.fetchAll(from: reader, spikeIDs: ["resident-daily"], pageSize: 3)
        XCTAssertEqual(reader.calls.map(\.offset), [0, 3], "page two came back short (1 < 3) and ended the walk")
        let row3 = try XCTUnwrap(fetched.first { ($0["run_id"] as? String)?.hasSuffix("000000000003") == true })
        XCTAssertEqual((row3["revision"] as? NSNumber)?.intValue, 2, "the repeat with the higher revision wins")
        XCTAssertEqual(ids(fetched).count, Set(ids(fetched)).count)
    }

    /// The production request: the view, release rows, the two observatory
    /// spikes, the stable order, limit/offset — a read with no epoch header.
    func testTheRESTReadAsksForReleaseRowsInTheStableOrderWithNoEpoch() async throws {
        let suite = "TelemetryCloudPagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let json = #"{"access_token":"at-1","refresh_token":"","user_id":"\#(TelemetryFixtures.uid)"}"#
        let auth = AuthService(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
                               sessionStore: InMemorySessionStore(),
                               transport: { _ in throw URLError(.notConnectedToInternet) },
                               launchEnvironment: ["SYNC_DEBUG_SESSION": json], syncEnvironment: .local)
        XCTAssertTrue(auth.isSignedIn, "rig: injected session")
        TelemetryHTTPStub.install()
        TelemetryHTTPStub.reset(status: 200)
        defer { TelemetryHTTPStub.uninstall() }
        let rest = SupabaseREST(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", authService: auth)
        rest.writeEpoch = "epoch-must-not-be-sent"

        let rows = try await rest.fetchMySpikeRunsPage(spikeIDs: [FixObservationRegistry.residentDailySpikeID,
                                                                   FixObservationRegistry.effortPathFixID],
                                                        limit: 500, offset: 1000)
        XCTAssertTrue(rows.isEmpty)
        let request = try XCTUnwrap(TelemetryHTTPStub.all.first?.request)
        XCTAssertEqual(TelemetryHTTPStub.all.count, 1)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://stub.invalid/rest/v1/v_my_spike_runs?select=*&build_configuration=eq.release"
                       + "&spike_id=in.(resident-daily,fix-effort-path)&order=day_key.desc,run_id.asc&limit=500&offset=1000")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Sync-Epoch"), "a read carries no epoch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
    }
}

// MARK: - Merge and fallback (§16 rule 3)

@MainActor
final class TelemetryObservatoryMergeTests: XCTestCase {
    private var rig: ObservatoryRig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryRig()
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    /// A row as the server stores it (the wire row, through JSON, with
    /// PostgREST's `+00:00` / microsecond timestamps) reads back as the
    /// record it came from — every field the evaluator or the merge uses.
    func testAViewRowReadsBackAsTheRecordItCameFrom() throws {
        let install = UUID()
        var run = TelemetryFixtures.run(
            metrics: ["tapCount": .number(4), "tapLagBuckets": .string("0 1 2 3 4 5 6 7"), "wContaminated": .bool(true)],
            abortReason: .manualRunTookOver, revision: 7, coActiveSpikeIDs: ["spike-195-detail-perf"], variantID: "B"
        )
        run.installID = install
        var row = TelemetryWire.row(for: run, userID: rig.uid, installID: install, now: rig.clock) { _ in ("2000-01-01", 0) }
        row = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: row)) as? [String: Any])
        row["started_at"] = "2026-09-21T14:13:20+00:00"
        row["ended_at"] = "2026-09-21T14:14:20.000000+00:00"

        let back = try XCTUnwrap(TelemetryWire.run(fromRow: row))
        XCTAssertEqual(back.id, run.id)
        XCTAssertEqual(back.spikeID, run.spikeID)
        XCTAssertEqual(back.scenarioID, run.scenarioID)
        XCTAssertEqual(back.startedAt, run.startedAt)
        XCTAssertEqual(back.endedAt, run.endedAt)
        XCTAssertEqual(back.appBuild, "12")
        XCTAssertEqual(back.buildConfiguration, "release")
        XCTAssertEqual(back.metrics, run.metrics, "number, fixed-format string and bool all survive")
        XCTAssertEqual(back.kind, .dailyRollup)
        XCTAssertEqual(back.revision, 7)
        XCTAssertEqual(back.dayKey, "2026-09-21")
        XCTAssertEqual(back.dayTZOffsetMin, -420)
        XCTAssertEqual(back.ownerUID, rig.uid, "the owner is the row's user")
        XCTAssertEqual(back.installID, install)
        XCTAssertEqual(back.abortReason, .manualRunTookOver)
        XCTAssertEqual(back.variantID, "B")
        XCTAssertEqual(back.coActiveSpikeIDs, ["spike-195-detail-perf"])

        row["started_at"] = nil
        XCTAssertNil(TelemetryWire.run(fromRow: row), "an unreadable row is left out, not guessed at")
    }

    /// A record as the cloud hands it back: through the wire row, JSON and
    /// `run(fromRow:)` — the same path the deck's records take (so it has no
    /// zone or locale, which the wire does not carry).
    private func viaCloud(_ run: SpikeRun, revision: Int) throws -> SpikeRun {
        var copy = run
        copy.revision = revision
        let row = TelemetryWire.row(for: copy, userID: rig.uid, installID: copy.installID ?? UUID(), now: rig.clock) { _ in
            ("2026-09-21", 0)
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: row)) as? [String: Any])
        return try XCTUnwrap(TelemetryWire.run(fromRow: json))
    }

    /// One record per run id: the higher revision wins; a tie goes to the
    /// local copy (it carries zone and locale the wire does not); records
    /// only one side has are all kept.
    func testTheMergeKeepsOneRecordPerRunIDAndTheHigherRevision() throws {
        let shared = UUID(), tied = UUID()
        let localOld = TelemetryFixtures.run(id: shared, revision: 3)
        let cloudNew = try viaCloud(localOld, revision: 5)
        let localTie = TelemetryFixtures.run(id: tied, revision: 2)
        let cloudTie = try viaCloud(localTie, revision: 2)
        XCTAssertEqual(cloudTie.timeZoneIdentifier, "", "rig: the cloud copy has no zone")
        let localOnly = TelemetryFixtures.run(startedAt: rig.clock.addingTimeInterval(10), revision: 1)
        let cloudOnly = try viaCloud(TelemetryFixtures.run(startedAt: rig.clock.addingTimeInterval(20)), revision: 1)

        let merged = TelemetryObservatoryMerge.merge(local: [localOld, localTie, localOnly], cloud: [cloudNew, cloudTie, cloudOnly])
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.first { $0.id == shared }?.revision, 5, "the cloud's newer revision wins")
        XCTAssertEqual(merged.first { $0.id == tied }?.timeZoneIdentifier, "America/Los_Angeles", "a tie keeps the local copy")
        XCTAssertNotNil(merged.first { $0.id == localOnly.id })
        XCTAssertNotNil(merged.first { $0.id == cloudOnly.id })
    }

    private func releaseDaily(install: UUID?, revision: Int = 1, startedAt: Date) -> SpikeRun {
        var run = TelemetryFixtures.run(startedAt: startedAt, metrics: ResidentCounterSet().metrics, revision: revision)
        run.installID = install
        return run
    }

    private func meTabDays(_ verdicts: [FixVerdict]) -> Int? {
        verdicts.first { $0.entryID == FixObservationRegistry.meTabGateFixID }?.releaseDayCount
    }

    /// No cloud (offline / signed out / failed) or an empty one: the deck is
    /// this device's and says "this device only". With cloud rows: merged,
    /// the release days are the account's total, and the source names the
    /// installs — the local one plus another phone's.
    func testTheDeckFallsBackToThisDeviceWithoutACloudAndCountsTheAccountsDevicesWithOne() throws {
        let local = UUID(), otherPhone = UUID()
        let mine = releaseDaily(install: local, revision: 3, startedAt: rig.clock)
        let staleCopy = try viaCloud(mine, revision: 2)          // this phone's day, an older upload of it
        let theirs = try viaCloud(releaseDaily(install: otherPhone, startedAt: rig.clock.addingTimeInterval(-86_400)), revision: 1)

        let offline = FixWatchAttention.observatory(localDailies: [mine], localWindows: [], cloud: nil, localInstall: local)
        XCTAssertEqual(offline.source, .localOnly)
        XCTAssertEqual(meTabDays(offline.verdicts), 1)
        XCTAssertEqual(offline.verdicts, FixWatchAttention.evaluate(dailies: [mine], windows: []),
                       "the fallback is exactly this device's evaluation")

        let empty = FixWatchAttention.observatory(localDailies: [mine], localWindows: [], cloud: [], localInstall: local)
        XCTAssertEqual(empty.source, .localOnly, "an empty cloud is not a source")

        let cloud = FixWatchAttention.observatory(localDailies: [mine], localWindows: [], cloud: [staleCopy, theirs],
                                                  localInstall: local)
        XCTAssertEqual(cloud.source, .cloud(devices: 2))
        XCTAssertEqual(meTabDays(cloud.verdicts), 2, "this phone's day once (not twice) plus the other phone's")
        XCTAssertEqual(FixWatchSource.localOnly.label, L(.fixWatchSourceLocal))
        XCTAssertTrue(FixWatchSource.cloud(devices: 2).label.contains("2"))
    }

    /// The uploader asks the cloud only when it can, and every "cannot" is
    /// nil — the deck's fallback signal: not attached, no reader, signed
    /// out, or a failed read. Positive control: a readable cloud decodes.
    func testTheCloudReadIsNilWheneverThereIsNoCloudToAsk() async {
        let unattached = rig.uploader(attached: false)
        let notAttached = await unattached.fetchObservatoryCloudRuns()
        XCTAssertNil(notAttached)

        let noReader = await rig.uploader(cloudReader: nil).fetchObservatoryCloudRuns()
        XCTAssertNil(noReader)

        let reader = FakeCloudReader()
        let run = TelemetryFixtures.run(revision: 1)
        reader.rows = [TelemetryWire.row(for: run, userID: rig.uid, installID: UUID(), now: rig.clock) { _ in ("2026-09-21", 0) }]
        let signedOut = await rig.uploader(cloudReader: reader, signedIn: false).fetchObservatoryCloudRuns()
        XCTAssertNil(signedOut)
        XCTAssertTrue(reader.calls.isEmpty, "signed out: the cloud is not even asked")

        reader.error = URLError(.notConnectedToInternet)
        let offline = await rig.uploader(cloudReader: reader).fetchObservatoryCloudRuns()
        XCTAssertNil(offline, "a failed read falls back")

        reader.error = nil
        let readable = await rig.uploader(cloudReader: reader).fetchObservatoryCloudRuns()
        XCTAssertEqual(readable?.map(\.id), [run.id], "positive control: the row decodes")
    }
}
