//
//  SpikeEraseWritebackTests.swift
//  DoneTests
//
//  A manual spike run armed from the Developer page, then "erase all local
//  data", then the run completes. The closing record used to land after the
//  erase: the pre-erase id and gestures, revision 1, stamped with whoever was
//  signed in by then, and the uploader sent it. The erase here is the real
//  `LocalDataEraser`; every erase test has a twin without the erase that
//  writes and uploads exactly as before.
//

import XCTest
@testable import Done

// MARK: - Through the real eraser

@MainActor
final class SpikeEraseWritebackTests: XCTestCase {

    private let uid = TelemetryFixtures.uid
    private let bundleID = Bundle.main.bundleIdentifier ?? "wordless.shiqiliuyifanmei.app"

    private var savedStandard: [String: Any]?
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: EventStore!
    private var coordinator: SpikeSessionCoordinator!
    private var uploader: TelemetryUploader!
    private var server: SyncFakeServer!
    private var eraser: LocalDataEraser!
    private var scratch: [URL] = []

    /// Where the runners write in the app, and what the erase wipes. Under
    /// XCTest it is the test host's own `spike-runs-test-host`.
    private let pool = SpikeRunStorageLocation.production

    override func setUp() async throws {
        try await super.setUp()
        savedStandard = UserDefaults.standard.persistentDomain(forName: bundleID)
        SpikeRunStore.wipe(location: pool)
        suite = "SpikeEraseWritebackTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)

        // The account signed in before the erase and after it (the account
        // switch keeps it; a later sign-in is the same for the store).
        SpikeRunStore.ownerProvider = { [uid] in uid }

        // The uploader reads the same pool. Its switch and consent live in
        // the test's own suite, which the erase does not sweep: that is the
        // user turning statistics back on afterwards.
        server = SyncFakeServer(userId: uid)
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = pool
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        uploader = TelemetryUploader(dependencies: deps)
        uploader.attach(TelemetryUploader.Attachment(
            gateway: server, isBlockedByBuild: { false },
            currentUserID: { [uid] in uid }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: Date().addingTimeInterval(-3_600))

        eraser = makeEraser()
        eraser.telemetryUploader = uploader
        coordinator = SpikeSessionCoordinator()
    }

    override func tearDown() async throws {
        coordinator?.stopAll()
        SpikeProbe.onSignal = nil
        SpikeRunStore.ownerProvider = nil
        SpikeRunStore.wipe(location: pool)
        UserDefaults.standard.setPersistentDomain(savedStandard ?? [:], forName: bundleID)
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        TestStorage.tearDown(suite)
        coordinator = nil
        uploader = nil
        eraser = nil
        try await super.tearDown()
    }

    /// The same construction as the real-eraser sync QA: the eraser writes
    /// the master switch and its sweep into `UserDefaults.standard` (saved
    /// and put back around each test), and its backup snapshot is pointed at
    /// a temporary file so the host app's own is never touched.
    private func makeEraser() -> LocalDataEraser {
        let types = EventTypeTemplateStore(defaults: defaults)
        let skills = SkillInsightStore(defaults: defaults)
        let prefsDirectory = temporaryDirectory("prefs")
        let prefs = AgentPreferenceStore(directoryURL: prefsDirectory)
        let service = SupabaseSyncService(gateway: SyncFakeServer(userId: uid).connection(), userId: uid,
                                          defaults: .standard, scheduler: SyncManualScheduler(start: Date()),
                                          environment: .local)
        let expiresAt = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let session = #"{"access_token":"at-1","refresh_token":"r-1","user_id":"\#(uid)","email":"erase@example.com","expires_at":\#(expiresAt)}"#
        let auth = AuthService(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
                               sessionStore: InMemorySessionStore(),
                               transport: { request in
                                   XCTFail("no auth request may go out; got \(request.url?.absoluteString ?? "?")")
                                   throw URLError(.notConnectedToInternet)
                               },
                               launchEnvironment: ["SYNC_DEBUG_SESSION": session], syncEnvironment: .local)
        let snapshotDirectory = temporaryDirectory("snapshot")
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let snapshots = BackupSnapshotService()
        snapshots.snapshotFileURLOverride = snapshotDirectory.appendingPathComponent("backup-snapshot.json")
        return LocalDataEraser(store: store, skillStore: skills,
                               agentRuntime: AgentRuntime(eventTypeTemplateStore: types, preferenceStore: prefs),
                               authService: auth, calendarState: CalendarViewState(defaults: defaults),
                               syncService: service, imageBackupCoordinator: ImageBackupCoordinator(defaults: defaults),
                               backupSnapshotService: snapshots)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpikeEraseWritebackTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        scratch.append(url)
        return url
    }

    // MARK: Driving the runs

    private func armedRunID(_ spikeID: String, file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        try XCTUnwrap(coordinator.activeRuns.first { $0.spikeID == spikeID }?.id,
                      "rig: a \(spikeID) run is armed", file: file, line: line)
    }

    /// One tap is one gesture record: it stays open until its commit ends.
    private func tapEffort(_ times: Int) {
        for index in 0..<times {
            let x = Double(40 + index)
            for phase in [SpikeGesturePhase.changed, .ended, .commitStart, .commitEnd] {
                SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, phase, eventTime: nil, locationX: x))
            }
        }
    }

    private func typeNote(_ length: Int) {
        SpikeProbe.emit(.bodyPass(Spike195SignalID.parentBody))
        SpikeProbe.emit(.bodyPass(Spike195SignalID.reflectionNoteLeaf))
        SpikeProbe.emit(.textLength(Spike195SignalID.reflectionNoteLength, length))
    }

    // MARK: Reading the pool

    /// Every file in the pool's directory, dotfiles included (the upload
    /// cursor, the install id, the request sample), as text.
    private func poolFiles() -> [(name: String, text: String)] {
        let directory = pool.directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().map { name in
            let data = (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data()
            return (name, String(decoding: data, as: UTF8.self))
        }
    }

    private func records(of spikeID: String) -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: spikeID, location: pool)
    }

    private func sentRunIDs() -> [String] {
        server.requests(.telemetryUpsert)
            .flatMap { ($0.body as? [[String: Any]]) ?? [] }
            .compactMap { ($0["run_id"] as? String)?.lowercased() }
    }

    /// The bytes, not a decode: a line that no longer parses still carries
    /// the id, and so does a cursor entry or a request sample.
    private func assertNothingOnDisk(from runID: UUID, file: StaticString = #filePath, line: UInt = #line) {
        let needle = runID.uuidString.lowercased()
        for (name, text) in poolFiles() {
            XCTAssertFalse(text.lowercased().contains(needle),
                           "\(name) holds the pre-erase run after the erase", file: file, line: line)
        }
    }

    private func assertNothingUploaded(from runID: UUID, file: StaticString = #filePath, line: UInt = #line) async {
        _ = await uploader.uploadNow(trigger: .launch)
        XCTAssertFalse(sentRunIDs().contains(runID.uuidString.lowercased()),
                       "the pre-erase run went to the server", file: file, line: line)
        XCTAssertNil(server.telemetryRow(runID: runID), file: file, line: line)
    }

    /// After the erase the pool and the uploader still work: a run armed
    /// now is written, closed and sent. Without this, "nothing came back"
    /// could be a dead pipe.
    private func assertAPostEraseRunIsWrittenAndSent(file: StaticString = #filePath, line: UInt = #line) async throws {
        let runner = coordinator.runner201
        runner.start(store: store)
        let fresh = try armedRunID(Spike201Runner.spikeID, file: file, line: line)
        tapEffort(2)
        runner.cancel()
        let written = try XCTUnwrap(records(of: Spike201Runner.spikeID).first { $0.id == fresh },
                                    "liveness: a run armed after the erase is written", file: file, line: line)
        XCTAssertEqual(written.outcome, .completed, file: file, line: line)
        XCTAssertEqual(written.ownerUID, uid, file: file, line: line)
        _ = await uploader.uploadNow(trigger: .launch)
        XCTAssertNotNil(server.telemetryRow(runID: fresh), "liveness: and uploaded", file: file, line: line)
    }

    // MARK: gh#201

    /// The reviewer's scenario on the account switch: arm #201, erase, keep
    /// tapping, Stop. Right after the erase the run is gone from the
    /// Developer page; the taps after it reach nothing; the Stop writes
    /// nothing; the uploader has nothing of it to send.
    func testA201RunArmedBeforeTheEraseLeavesNothingOnDiskOrOnTheWire() async throws {
        let runner = coordinator.runner201
        runner.start(store: store)
        let pre = try armedRunID(Spike201Runner.spikeID)
        tapEffort(3)
        XCTAssertTrue(poolFiles().contains { $0.text.lowercased().contains(pre.uuidString.lowercased()) },
                      "rig: the open record is on disk before the erase")

        eraser.resetAllLocalData(keepingSession: true)

        XCTAssertFalse(runner.isArmed, "the erase ended the run")
        XCTAssertTrue(coordinator.activeRuns.isEmpty, "the Developer page's Active Runs card is empty")
        XCTAssertNil(SpikeProbe.onSignal, "no listener is left on the probe seam")

        tapEffort(4)
        runner.cancel()

        XCTAssertNil(runner.lastCompletedRun, "no pre-erase run is shown as the last completed one")
        assertNothingOnDisk(from: pre)
        await assertNothingUploaded(from: pre)
        try await assertAPostEraseRunIsWrittenAndSent()
    }

    /// Control: the same steps without the erase write the open and the
    /// closing record, and the closing one is uploaded.
    func testControlWithoutTheEraseA201RunIsWrittenAndUploaded() async throws {
        let runner = coordinator.runner201
        runner.start(store: store)
        let id = try armedRunID(Spike201Runner.spikeID)
        tapEffort(3)
        tapEffort(4)
        runner.cancel()

        let closed = try XCTUnwrap(records(of: Spike201Runner.spikeID).first { $0.id == id })
        XCTAssertEqual(closed.outcome, .completed)
        XCTAssertEqual(closed.revision, 2, "the open record, then the closing one")
        XCTAssertEqual(closed.ownerUID, uid)
        guard case .string(let csv)? = closed.metrics["gestures"] else { return XCTFail("the gestures are on the line") }
        XCTAssertEqual(csv.split(separator: "\n").count - 1, 7, "all seven taps")
        XCTAssertEqual(runner.lastCompletedRun?.id, id)
        _ = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(server.telemetryRow(runID: id)?.data["user_id"] as? String, uid)
    }

    // MARK: gh#195

    /// From Data & Privacy (signed out), with the note reaching its forty
    /// characters after the erase — the run's own completion.
    func testA195RunArmedBeforeTheEraseLeavesNothingOnDiskOrOnTheWire() async throws {
        let runner = coordinator.runner195
        runner.start(store: store)
        let pre = try armedRunID(Spike195Runner.spikeID)
        typeNote(12)
        XCTAssertTrue(poolFiles().contains { $0.text.lowercased().contains(pre.uuidString.lowercased()) },
                      "rig: the open record is on disk before the erase")

        eraser.resetAllLocalData(keepingSession: false)

        XCTAssertFalse(runner.isArmed, "the erase ended the run")
        XCTAssertTrue(coordinator.activeRuns.isEmpty)
        XCTAssertNil(SpikeProbe.onSignal)

        typeNote(40)
        runner.cancel()

        XCTAssertNil(runner.lastCompletedRun)
        assertNothingOnDisk(from: pre)
        await assertNothingUploaded(from: pre)
        try await assertAPostEraseRunIsWrittenAndSent()
    }

    func testControlWithoutTheEraseA195RunIsWrittenAndUploaded() async throws {
        let runner = coordinator.runner195
        runner.start(store: store)
        let id = try armedRunID(Spike195Runner.spikeID)
        typeNote(12)
        typeNote(40)

        XCTAssertFalse(runner.isArmed, "forty characters complete the run")
        let closed = try XCTUnwrap(records(of: Spike195Runner.spikeID).first { $0.id == id })
        XCTAssertEqual(closed.outcome, .completed)
        XCTAssertEqual(closed.revision, 2)
        XCTAssertEqual(closed.metrics["bodyPassesParent"], .number(2))
        XCTAssertEqual(runner.lastCompletedRun?.id, id)
        _ = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(server.telemetryRow(runID: id)?.data["user_id"] as? String, uid)
    }

    /// A run completed BEFORE the erase is gone with the files; the runner's
    /// copy of it, which the Developer page reads, goes too.
    func testTheLastCompletedRunFromBeforeTheEraseIsForgotten() throws {
        let runner = coordinator.runner201
        runner.start(store: store)
        tapEffort(1)
        runner.cancel()
        XCTAssertNotNil(runner.lastCompletedRun, "rig")

        eraser.resetAllLocalData(keepingSession: false)

        XCTAssertNil(runner.lastCompletedRun)
        XCTAssertTrue(poolFiles().filter { !$0.name.hasPrefix(".") }.isEmpty, "the wipe took the records")
    }
}

// MARK: - The store's own guard

/// The structural half on its own: no runner, no eraser — a record built
/// before the epoch moved, handed straight to the store.
@MainActor
final class SpikeRunStoreEraseEpochTests: XCTestCase {
    private var location: SpikeRunStorageLocation!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        SpikeRunStore.ownerProvider = nil
        super.tearDown()
    }

    private func openRun() -> SpikeRun {
        var run = TelemetryFixtures.run(spikeID: Spike201SignalID.spikeID, scenarioID: Spike201SignalID.scenarioID,
                                        startedAt: Date(), endedAt: nil, ownerUID: nil, kind: nil, revision: nil)
        run.outcome = nil
        return run
    }

    private func closed(_ run: SpikeRun) -> SpikeRun {
        var copy = run
        copy.endedAt = run.startedAt.addingTimeInterval(5)
        copy.outcome = .completed
        copy.metrics = ["gestures": .string("tap")]
        return copy
    }

    /// Born before the bump, appended after it: refused on both paths, and
    /// a copy carries the epoch it was copied from. Nothing reaches the
    /// disk, not even the directory or the install id the first append would
    /// mint. Positive control: a record built after the bump is written.
    func testARecordBornBeforeAnEraseIsRefusedAndOneBornAfterIsWritten() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            let before = openRun()
            LocalDataEraseEpoch.bump()

            XCTAssertFalse(SpikeRunStore.beginRun(before, location: location))
            XCTAssertFalse(SpikeRunStore.finishRun(closed(before), location: location))
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path),
                           "a refused record leaves no file, no directory and no install id")

            let after = openRun()
            XCTAssertTrue(SpikeRunStore.beginRun(after, location: location))
            XCTAssertTrue(SpikeRunStore.finishRun(closed(after), location: location))
            let runs = SpikeRunStore.loadRuns(spikeID: after.spikeID, location: location)
            XCTAssertEqual(runs.map(\.id), [after.id])
            XCTAssertEqual(try XCTUnwrap(runs.first).revision, 2)
        }
    }

    /// A record READ before the erase is as stale as one built before it,
    /// and a refused append moves no revision: the id's next accepted line
    /// is the one after its last line on disk.
    func testARecordReadBeforeAnEraseIsRefusedAndMovesNoRevision() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            let run = openRun()
            XCTAssertTrue(SpikeRunStore.beginRun(run, location: location))
            let read = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: run.spikeID, location: location).first)
            LocalDataEraseEpoch.bump()

            XCTAssertFalse(SpikeRunStore.finishRun(closed(read), location: location))
            XCTAssertFalse(SpikeRunStore.finishRun(closed(read), location: location))
            XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: run.spikeID, location: location).first?.revision, 1,
                           "nothing was appended")

            // Read again now: a fresh value, accepted, and numbered from the
            // file — the two refusals counted nothing.
            XCTAssertTrue(SpikeRunStore.setNote("after", forRunID: run.id, spikeID: run.spikeID, location: location))
            XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: run.spikeID, location: location).first?.revision, 2)
        }
    }

    /// Control, green before and after the change by design: the line on
    /// disk names exactly the fields it named before, so a build without the
    /// epoch reads it unchanged; and a value that was encoded and decoded
    /// compares equal to the original.
    func testTheLineOnDiskNamesTheSameFieldsAsBefore() throws {
        var run = TelemetryFixtures.run(spikeID: Spike201SignalID.spikeID, scenarioID: Spike201SignalID.scenarioID,
                                        note: "n", abortReason: .stoppedBeforeTarget, ownerUID: "owner",
                                        kind: .manualRun, revision: 3, coActiveSpikeIDs: ["x"], variantID: "v")
        run.installID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(run)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "id", "spikeID", "scenarioID", "variantID", "startedAt", "endedAt", "appVersion", "appBuild",
            "deviceModel", "osVersion", "timeZoneIdentifier", "localeIdentifier", "buildConfiguration",
            "coActiveSpikeIDs", "metrics", "note", "outcome", "abortReason", "installID", "ownerUID", "dayKey",
            "dayTZOffsetMin", "revision", "kind",
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(SpikeRun.self, from: data), run)
    }
}

// MARK: - The uploader's row-by-row walk

/// A refused batch is resent one row per request, each after an await. An
/// erase that lands between two of them leaves the rest of the batch as the
/// erased owner's records: none of them may go after it.
@MainActor
final class TelemetryRowWalkEraseTests: XCTestCase {
    private let uid = TelemetryFixtures.uid
    private var location: SpikeRunStorageLocation!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var uploader: TelemetryUploader!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        suiteName = "TelemetryRowWalkEraseTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        server = SyncFakeServer(userId: uid)
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        uploader = TelemetryUploader(dependencies: deps)
        uploader.attach(TelemetryUploader.Attachment(
            gateway: server, isBlockedByBuild: { false },
            currentUserID: { [uid] in uid }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: TelemetryFixtures.t0.addingTimeInterval(-3_600))
    }

    override func tearDown() {
        server?.holdWhen = nil
        try? FileManager.default.removeItem(at: location.directory)
        defaults.removePersistentDomain(forName: suiteName)
        uploader = nil
        server = nil
        super.tearDown()
    }

    /// Two good window records and one the server refuses (a prose build
    /// configuration redacts to the NOT NULL placeholder, which its check
    /// rejects): the batch fails as a whole and is walked row by row.
    private func seedARefusedBatch() {
        for offset in 0..<3 {
            let run = TelemetryFixtures.run(spikeID: FixObservationRegistry.effortPathFixID,
                                            scenarioID: FixObservationRegistry.windowScenarioID,
                                            startedAt: TelemetryFixtures.t0.addingTimeInterval(Double(offset)),
                                            buildConfiguration: offset == 1 ? "staging" : "release",
                                            metrics: ["tapCount": .number(1)], kind: .window, revision: nil)
            XCTAssertTrue(SpikeRunStore.finishRun(run, location: location), "rig: seed lands")
        }
    }

    /// The first single-row request is held at the server; the erase begins;
    /// the request is let go. Nothing is sent after it.
    func testAnEraseDuringTheRowByRowWalkStopsTheWalk() async {
        seedARefusedBatch()
        let server = self.server!
        server.holdWhen = { verb, _ in verb == .telemetryUpsert && server.requests(.telemetryUpsert).count == 2 }

        let sentAtTheErase = await LocalDataEraseEpoch.withIsolatedEpoch { () async -> Int in
            uploader.schedule(.launch)
            let deadline = Date().addingTimeInterval(5)
            while server.heldCount == 0 && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(server.heldCount, 1, "rig: the first single row is parked at the server")
            let sent = server.requests(.telemetryUpsert).count
            LocalDataEraseEpoch.bump()
            server.releaseAll()
            await uploader.drain()
            return sent
        }
        XCTAssertEqual(sentAtTheErase, 2, "rig: the refused batch, then the first row on its own")
        XCTAssertEqual(server.requests(.telemetryUpsert).count, sentAtTheErase, "no row went after the erase")
        XCTAssertEqual(uploader.lastOutcome, .staleAfterErase)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpikeRunStore.uploadCursorURL(location: location).path))
    }

    /// Control: the same walk with no erase sends every row on its own.
    func testControlWithoutAnEraseTheWalkSendsEveryRow() async {
        seedARefusedBatch()
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .partial(uploaded: 2, quarantined: 1))
        XCTAssertEqual(server.requests(.telemetryUpsert).count, 4, "the refused batch, then three single rows")
    }
}
