//
//  SpikeEraseWritebackQATests.swift
//  DoneTests
//
//  Independent QA of the spike-run erase write-back fix. Not the
//  implementer's file: these drive the same real types from angles the
//  implementer's tests do not — both runners armed at once across an account
//  switch to a different owner, a coordinator the eraser cannot reach, the
//  note and reconcile writers, an older build's view of the line, and the
//  off-main decoders.
//

import QuartzCore
import XCTest
@testable import Done

// MARK: - Account switch, both runners armed, the real eraser

@MainActor
final class SpikeEraseQAAccountSwitchTests: XCTestCase {

    private let accountA = TelemetryFixtures.otherUID
    private let accountB = TelemetryFixtures.uid
    private let bundleID = Bundle.main.bundleIdentifier ?? "wordless.shiqiliuyifanmei.app"

    private var savedStandard: [String: Any]?
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: EventStore!
    private var coordinator: SpikeSessionCoordinator!
    private var extraCoordinators: [SpikeSessionCoordinator] = []
    private var uploader: TelemetryUploader!
    private var server: SyncFakeServer!
    private var eraser: LocalDataEraser!
    private var scratch: [URL] = []
    /// Who is signed in: A before the switch, B from the moment the switch
    /// signs B in (before the erase that keeps B's session).
    private var signedIn: String?

    private let pool = SpikeRunStorageLocation.production

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertEqual(pool.directory.lastPathComponent, "spike-runs-test-host",
                       "rig: the pool must be the test host's, never the device's")
        savedStandard = UserDefaults.standard.persistentDomain(forName: bundleID)
        SpikeRunStore.wipe(location: pool)
        suite = "SpikeEraseQAAccountSwitchTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)

        signedIn = accountA
        SpikeRunStore.ownerProvider = { [weak self] in self?.signedIn }

        // The server is B's: a row stamped A would be refused there, but it
        // would still have gone over the wire — the requests are what is read.
        server = SyncFakeServer(userId: accountB)
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = pool
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        uploader = TelemetryUploader(dependencies: deps)
        uploader.attach(TelemetryUploader.Attachment(
            gateway: server, isBlockedByBuild: { false },
            currentUserID: { [weak self] in self?.signedIn }, isSignedIn: { [weak self] in self?.signedIn != nil }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: Date().addingTimeInterval(-3_600))

        eraser = makeEraser()
        eraser.telemetryUploader = uploader
        coordinator = SpikeSessionCoordinator()
    }

    override func tearDown() async throws {
        coordinator?.stopAll()
        for extra in extraCoordinators { extra.stopAll() }
        extraCoordinators = []
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

    /// The real eraser with every side effect pointed away from the host
    /// app: the backup snapshot at a temporary file, the session in memory,
    /// the sync engine on a fake server.
    private func makeEraser() -> LocalDataEraser {
        let types = EventTypeTemplateStore(defaults: defaults)
        let skills = SkillInsightStore(defaults: defaults)
        let prefs = AgentPreferenceStore(directoryURL: temporaryDirectory("prefs"))
        let service = SupabaseSyncService(gateway: SyncFakeServer(userId: accountB).connection(), userId: accountB,
                                          defaults: .standard, scheduler: SyncManualScheduler(start: Date()),
                                          environment: .local)
        let expiresAt = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let session = #"{"access_token":"at-1","refresh_token":"r-1","user_id":"\#(accountB)","email":"qa@example.com","expires_at":\#(expiresAt)}"#
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
            .appendingPathComponent("SpikeEraseQA-\(name)-\(UUID().uuidString)", isDirectory: true)
        scratch.append(url)
        return url
    }

    // MARK: Driving

    private func armedID(_ spikeID: String, on coordinator: SpikeSessionCoordinator,
                         file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        try XCTUnwrap(coordinator.activeRuns.first { $0.spikeID == spikeID }?.id,
                      "rig: a \(spikeID) run is armed", file: file, line: line)
    }

    private func tapEffort(_ times: Int) {
        for index in 0..<times {
            for phase in [SpikeGesturePhase.changed, .ended, .commitStart, .commitEnd] {
                SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, phase, eventTime: nil, locationX: Double(60 + index)))
            }
        }
    }

    private func typeNote(_ length: Int) {
        SpikeProbe.emit(.bodyPass(Spike195SignalID.parentBody))
        SpikeProbe.emit(.bodyPass(Spike195SignalID.reflectionNoteLeaf))
        SpikeProbe.emit(.textLength(Spike195SignalID.reflectionNoteLength, length))
    }

    // MARK: Reading

    /// Every regular file under the pool, at any depth, dotfiles included.
    private func poolBytes() -> [(path: String, text: String)] {
        let root = pool.directory
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let data = (try? Data(contentsOf: url)) ?? Data()
            out.append((url.path.replacingOccurrences(of: root.path, with: ""), String(decoding: data, as: UTF8.self).lowercased()))
        }
        return out
    }

    private func assertPoolHolds(none needles: [String], _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        for (path, text) in poolBytes() {
            for needle in needles {
                XCTAssertFalse(text.contains(needle.lowercased()), "\(path) holds \(needle): \(why)", file: file, line: line)
            }
        }
    }

    /// Every telemetry request body the uploader put on the wire, as text.
    private func wireText() -> String {
        server.requests(.telemetryUpsert).map { request -> String in
            guard let body = request.body,
                  let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self).lowercased()
        }.joined(separator: "\n")
    }

    private func wireRowKeys() -> Set<String> {
        Set(server.requests(.telemetryUpsert)
            .flatMap { ($0.body as? [[String: Any]]) ?? [] }
            .flatMap(\.keys))
    }

    // MARK: Tests

    /// The account card's switch with BOTH manual runs armed: A signed in, two
    /// open records on disk under A; B signs in and the erase keeps B's
    /// session; the user keeps tapping and typing, then stops both. Nothing
    /// of either pre-erase run — its id, or A's uid — reaches B's pool or the
    /// wire. Then both runners, armed again under B, write and upload as B.
    func testBothRunsArmedAcrossAnAccountSwitchLeaveNothingOfAOnDiskOrOnTheWire() async throws {
        coordinator.runner201.start(store: store)
        coordinator.runner195.start(store: store)
        let pre201 = try armedID(Spike201Runner.spikeID, on: coordinator)
        let pre195 = try armedID(Spike195Runner.spikeID, on: coordinator)
        tapEffort(3)
        typeNote(12)
        let preRecords = SpikeRunStore.loadRuns(spikeID: Spike201Runner.spikeID, location: pool)
            + SpikeRunStore.loadRuns(spikeID: Spike195Runner.spikeID, location: pool)
        XCTAssertEqual(Set(preRecords.map(\.id)), [pre201, pre195], "rig: both open records are on disk")
        XCTAssertEqual(Set(preRecords.compactMap(\.ownerUID)), [accountA], "rig: stamped with A")

        signedIn = accountB
        eraser.resetAllLocalData(keepingSession: true)

        XCTAssertFalse(coordinator.runner201.isArmed)
        XCTAssertFalse(coordinator.runner195.isArmed)
        XCTAssertTrue(coordinator.activeRuns.isEmpty)
        XCTAssertTrue(coordinator.armedRunIDs.isEmpty, "nothing left for a reconcile to exclude")

        // Keep using the app: taps, the note's fortieth character, both Stop
        // buttons, Stop All, a note typed into a stale Latest Runs row, and
        // the settings page's reconcile with nothing excluded.
        tapEffort(4)
        typeNote(40)
        coordinator.runner201.cancel()
        coordinator.runner195.cancel()
        coordinator.stopAll()
        XCTAssertFalse(SpikeRunStore.setNote("typed after the switch", forRunID: pre201, spikeID: Spike201Runner.spikeID, location: pool))
        XCTAssertFalse(SpikeRunStore.setNote("typed after the switch", forRunID: pre195, spikeID: Spike195Runner.spikeID, location: pool))
        SpikeRunStore.reconcileInterruptedRuns(spikeIDs: SpikeRegistry.all.map(\.id), location: pool)

        XCTAssertNil(coordinator.runner201.lastCompletedRun)
        XCTAssertNil(coordinator.runner195.lastCompletedRun)
        let after = [pre201.uuidString, pre195.uuidString, accountA]
        assertPoolHolds(none: after, "the pre-erase run or account came back after the switch")

        _ = await uploader.uploadNow(trigger: .launch)
        let wire = wireText()
        for needle in after {
            XCTAssertFalse(wire.contains(needle.lowercased()), "\(needle) went over the wire after the switch")
        }

        // Positive control: the same two runners, armed under B.
        coordinator.runner201.start(store: store)
        coordinator.runner195.start(store: store)
        let post201 = try armedID(Spike201Runner.spikeID, on: coordinator)
        let post195 = try armedID(Spike195Runner.spikeID, on: coordinator)
        tapEffort(2)
        typeNote(40)
        coordinator.runner201.cancel()
        XCTAssertEqual(coordinator.runner201.lastCompletedRun?.id, post201)
        XCTAssertEqual(coordinator.runner195.lastCompletedRun?.id, post195)
        let written = SpikeRunStore.loadRuns(spikeID: Spike201Runner.spikeID, location: pool)
            + SpikeRunStore.loadRuns(spikeID: Spike195Runner.spikeID, location: pool)
        XCTAssertEqual(Set(written.map(\.id)), [post201, post195], "liveness: both post-switch runs are written")
        XCTAssertEqual(Set(written.compactMap(\.ownerUID)), [accountB])
        XCTAssertEqual(Set(written.compactMap(\.revision)), [2], "open then closed, nothing refused counted")
        XCTAssertEqual(written.first { $0.id == post195 }?.outcome, .completed)

        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .uploaded(rows: 2))
        XCTAssertEqual(server.telemetryRow(runID: post201)?.data["user_id"] as? String, accountB)
        XCTAssertEqual(server.telemetryRow(runID: post195)?.data["user_id"] as? String, accountB)
        XCTAssertFalse(wireRowKeys().isEmpty, "rig: rows went out")
        XCTAssertTrue(wireRowKeys().allSatisfy { !$0.lowercased().contains("epoch") },
                      "no epoch field on the wire: \(wireRowKeys().sorted())")
    }

    /// The eraser reaches the coordinator through a weak static set by every
    /// init. If it points at a different instance than the one holding the
    /// armed run, nothing tears that run down — and the store alone must
    /// still refuse its closing record.
    func testWhenTheEraseTellsAnotherCoordinatorTheStoreStillRefusesTheClosingRecord() async throws {
        coordinator.runner201.start(store: store)
        coordinator.runner195.start(store: store)
        let pre201 = try armedID(Spike201Runner.spikeID, on: coordinator)
        let pre195 = try armedID(Spike195Runner.spikeID, on: coordinator)
        tapEffort(2)

        let other = SpikeSessionCoordinator()
        extraCoordinators.append(other)
        XCTAssertTrue(SpikeSessionCoordinator.shared === other, "rig: the last init wins the static")

        signedIn = accountB
        eraser.resetAllLocalData(keepingSession: true)
        XCTAssertTrue(coordinator.runner201.isArmed, "rig: the untold coordinator's run is still armed")

        tapEffort(3)
        typeNote(40)
        coordinator.runner201.cancel()
        coordinator.runner195.cancel()

        // What the Developer page would show is not this test's question;
        // the store's refusal is.
        print("QA-OBSERVE untold coordinator: runner201.lastCompletedRun=\(coordinator.runner201.lastCompletedRun?.id.uuidString ?? "nil") "
              + "runner195.lastCompletedRun=\(coordinator.runner195.lastCompletedRun?.id.uuidString ?? "nil")")
        assertPoolHolds(none: [pre201.uuidString, pre195.uuidString, accountA],
                        "the store wrote a closing record born before the erase")
        _ = await uploader.uploadNow(trigger: .launch)
        XCTAssertFalse(wireText().contains(pre201.uuidString.lowercased()))
        XCTAssertFalse(wireText().contains(pre195.uuidString.lowercased()))

        // Liveness on the same untold coordinator: a run armed now writes.
        coordinator.runner201.start(store: store)
        let post = try armedID(Spike201Runner.spikeID, on: coordinator)
        tapEffort(1)
        coordinator.runner201.cancel()
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: Spike201Runner.spikeID, location: pool).map(\.id), [post])
    }

    /// "Probe stopped" is half of the runners' erase teardown, and the Stop
    /// contract's own words: a display link retains its target, so a probe
    /// left running outlives every owner and ticks until the process dies.
    /// Read through reflection because the probe and its link are private.
    func testTheEraseStopsBothRunnersFrameProbes() throws {
        coordinator.runner201.start(store: store)
        coordinator.runner195.start(store: store)
        func probe(_ runner: Any) -> SpikeFrameProbe? {
            Mirror(reflecting: runner).descendant("frameProbe") as? SpikeFrameProbe
        }
        func link(_ probe: SpikeFrameProbe) -> CADisplayLink? {
            Mirror(reflecting: probe).descendant("displayLink") as? CADisplayLink
        }
        let probe201 = try XCTUnwrap(probe(coordinator.runner201), "rig: #201 armed with a probe")
        let probe195 = try XCTUnwrap(probe(coordinator.runner195), "rig: #195 armed with a probe")
        XCTAssertNotNil(link(probe201), "rig: the link is read through reflection")
        XCTAssertNotNil(link(probe195))

        eraser.resetAllLocalData(keepingSession: false)

        XCTAssertNil(link(probe201), "#201's display link still runs after the erase")
        XCTAssertNil(link(probe195), "#195's display link still runs after the erase")
        XCTAssertNil(probe(coordinator.runner201))
        XCTAssertNil(probe(coordinator.runner195))
    }

    /// A run completed before the erase, and an orphaned open record a past
    /// process left: the note writer and the launch reconcile re-read the
    /// disk, so after the erase they have nothing to write. Positive control:
    /// both writers still work on a post-erase run.
    func testTheNoteWriterAndTheReconcileCannotReviveAPreEraseRun() throws {
        coordinator.runner201.start(store: store)
        tapEffort(1)
        coordinator.runner201.cancel()
        let completed = try XCTUnwrap(coordinator.runner201.lastCompletedRun?.id)
        var orphan = TelemetryFixtures.run(spikeID: Spike195Runner.spikeID, scenarioID: Spike195Runner.scenarioID,
                                           startedAt: Date(), endedAt: nil, ownerUID: accountA, kind: nil, revision: nil)
        orphan.outcome = nil
        XCTAssertTrue(SpikeRunStore.beginRun(orphan, owner: .explicit(accountA), location: pool), "rig: an orphan on disk")
        let staleRows = SpikeRunStore.latestRuns(spikeID: Spike201Runner.spikeID, limit: 20, location: pool)
        XCTAssertEqual(staleRows.map(\.id), [completed], "rig: the Latest Runs list as the page holds it")

        signedIn = accountB
        eraser.resetAllLocalData(keepingSession: true)

        XCTAssertFalse(SpikeRunStore.setNote("late", forRunID: completed, spikeID: Spike201Runner.spikeID, location: pool))
        SpikeRunStore.reconcileInterruptedRuns(spikeIDs: [Spike195Runner.spikeID, Spike201Runner.spikeID], location: pool)
        assertPoolHolds(none: [completed.uuidString, orphan.id.uuidString, accountA], "a pre-erase run was revived")

        // Positive control.
        coordinator.runner195.start(store: store)
        let post = try armedID(Spike195Runner.spikeID, on: coordinator)
        XCTAssertTrue(SpikeRunStore.setNote("after", forRunID: post, spikeID: Spike195Runner.spikeID, location: pool))
        coordinator.stopAll()
        let lines = SpikeRunStore.loadRuns(spikeID: Spike195Runner.spikeID, location: pool)
        XCTAssertEqual(lines.map(\.id), [post])
        XCTAssertEqual(lines.first?.revision, 3, "open, note, closed")
    }
}

// MARK: - The line an older build reads, and the line it wrote

/// `SpikeRun` exactly as it stood at ad877111, before the epoch field —
/// what an installed older build encodes and decodes.
private struct LegacySpikeRun: Codable, Equatable {
    let id: UUID
    let spikeID: String
    let scenarioID: String
    var variantID: String?
    let startedAt: Date
    var endedAt: Date?
    let appVersion: String
    let appBuild: String
    let appCommit: String?
    let deviceModel: String
    let osVersion: String
    let timeZoneIdentifier: String
    let localeIdentifier: String
    var buildConfiguration: String? = nil
    var coActiveSpikeIDs: [String]? = nil
    var metrics: [String: SpikeMetricValue]
    var note: String?
    var outcome: SpikeRunOutcome?
    var abortReason: SpikeAbortReason?
    var installID: UUID? = nil
    var ownerUID: String? = nil
    var dayKey: String? = nil
    var dayTZOffsetMin: Int? = nil
    var revision: Int? = nil
    var kind: TelemetryRecordKind? = nil
}

@MainActor
final class SpikeRunLineCompatQATests: XCTestCase {
    private var location: SpikeRunStorageLocation!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    private func encoder(sorted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if sorted { encoder.outputFormatting = [.sortedKeys] }
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Every field set, so a dropped or added key changes the bytes.
    private func fullRun() -> SpikeRun {
        var run = TelemetryFixtures.run(spikeID: Spike201SignalID.spikeID, scenarioID: Spike201SignalID.scenarioID,
                                        metrics: ["gestures": .string("a"), "n": .number(3), "b": .bool(true)],
                                        note: "n", abortReason: .stoppedBeforeTarget, ownerUID: "owner",
                                        kind: .manualRun, revision: 3, coActiveSpikeIDs: ["x"], variantID: "v")
        run.installID = UUID()
        return run
    }

    private func legacy(_ run: SpikeRun) -> LegacySpikeRun {
        LegacySpikeRun(id: run.id, spikeID: run.spikeID, scenarioID: run.scenarioID, variantID: run.variantID,
                       startedAt: run.startedAt, endedAt: run.endedAt, appVersion: run.appVersion, appBuild: run.appBuild,
                       appCommit: "abc123", deviceModel: run.deviceModel, osVersion: run.osVersion,
                       timeZoneIdentifier: run.timeZoneIdentifier, localeIdentifier: run.localeIdentifier,
                       buildConfiguration: run.buildConfiguration, coActiveSpikeIDs: run.coActiveSpikeIDs,
                       metrics: run.metrics, note: run.note, outcome: run.outcome, abortReason: run.abortReason,
                       installID: run.installID, ownerUID: run.ownerUID, dayKey: run.dayKey,
                       dayTZOffsetMin: run.dayTZOffsetMin, revision: run.revision, kind: run.kind)
    }

    /// New build writes, old build reads: byte for byte the line the old
    /// struct writes for the same values, and the old struct decodes it.
    func testTheNewLineIsByteForByteTheOldLine() throws {
        let legacyValue = legacy(fullRun())
        let current = try decoder.decode(SpikeRun.self, from: try encoder(sorted: true).encode(legacyValue))
        let newBytes = try encoder(sorted: true).encode(current)
        let oldBytes = try encoder(sorted: true).encode(legacyValue)
        XCTAssertEqual(String(decoding: newBytes, as: UTF8.self), String(decoding: oldBytes, as: UTF8.self))
        XCTAssertEqual(try decoder.decode(LegacySpikeRun.self, from: newBytes), legacyValue,
                       "an older build reads the new line unchanged")
    }

    /// What the store itself appends is what an older build can read: the
    /// file's line decodes as the old struct with every field the new value had.
    func testAStoreAppendedLineDecodesAsTheOldStruct() throws {
        var run = fullRun()
        run.endedAt = run.startedAt.addingTimeInterval(5)
        XCTAssertTrue(SpikeRunStore.finishRun(run, owner: .explicit("owner"), location: location))
        let data = try Data(contentsOf: SpikeRunStore.fileURL(spikeID: run.spikeID, location: location))
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        XCTAssertFalse(object.keys.contains { $0.lowercased().contains("epoch") }, "\(object.keys.sorted())")
        let old = try decoder.decode(LegacySpikeRun.self, from: Data(lines[0]))
        XCTAssertEqual(old.id, run.id)
        XCTAssertEqual(old.revision, 1)
        XCTAssertEqual(old.metrics, run.metrics)
        XCTAssertEqual(old.note, "n")
    }

    /// An old build's line decodes on the new build, and a line that names an
    /// epoch of its own cannot pick it: the decode stamps the epoch current
    /// at the read, so the store accepts it.
    func testAnOldLineDecodesAndAnEpochOnTheLineIsIgnored() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            LocalDataEraseEpoch.bump()
            LocalDataEraseEpoch.bump()
            let oldBytes = try encoder(sorted: false).encode(legacy(fullRun()))
            let decoded = try decoder.decode(SpikeRun.self, from: oldBytes)
            XCTAssertEqual(decoded.eraseEpoch, LocalDataEraseEpoch.capture())

            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
            object["eraseEpoch"] = -7
            let planted = try decoder.decode(SpikeRun.self, from: try JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(planted.eraseEpoch, LocalDataEraseEpoch.capture(), "the line's own value is not read")
            var closed = planted
            closed.endedAt = closed.startedAt.addingTimeInterval(1)
            XCTAssertTrue(SpikeRunStore.finishRun(closed, owner: .explicit("owner"), location: location))
        }
    }

    /// Two copies of one run, read on either side of an erase, are equal —
    /// the implementer's stated contract, pinned.
    func testCopiesReadOnEitherSideOfAnEraseCompareEqual() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            let bytes = try encoder(sorted: false).encode(legacy(fullRun()))
            let before = try decoder.decode(SpikeRun.self, from: bytes)
            LocalDataEraseEpoch.bump()
            let after = try decoder.decode(SpikeRun.self, from: bytes)
            XCTAssertNotEqual(before.eraseEpoch, after.eraseEpoch, "rig: the two copies carry different epochs")
            XCTAssertEqual(before, after)
            XCTAssertEqual(Spike201Runner.State.armed(before), Spike201Runner.State.armed(after))
        }
    }
}

// MARK: - Off the main thread

/// The resident's launch-seed verification decodes the daily file on a
/// utility queue; the decode now takes the epoch lock once per line. Decoding
/// there while an erase bumps the epoch must lose no line and stamp only
/// epochs that existed during the read.
final class SpikeRunOffMainDecodeQATests: XCTestCase {

    func testOffMainDecodesDuringBumpsLoseNoLineAndStampOnlyLiveEpochs() throws {
        let location = SpikeRunStorageLocation.ephemeral(id: UUID())
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = Data()
        let lineCount = 300
        for index in 0..<lineCount {
            let run = TelemetryFixtures.run(startedAt: TelemetryFixtures.t0.addingTimeInterval(Double(index)),
                                            metrics: ["i": .number(Double(index))], revision: 1)
            payload.append(try encoder.encode(run))
            payload.append(0x0A)
        }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let url = SpikeRunStore.fileURL(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
        try payload.write(to: url)
        let bounds = ResidentDayBounds.compute(for: TelemetryFixtures.t0, calendar: Calendar(identifier: .gregorian))
        let claim = TelemetryClaimKey(buildConfiguration: "release", appBuild: "12", osVersion: "26.0", ownerUID: TelemetryFixtures.uid)

        let bumps = 200
        LocalDataEraseEpoch.withIsolatedEpoch {
            let first = LocalDataEraseEpoch.capture()
            let lock = NSLock()
            var counts: [Int] = []
            var epochs: [Int] = []
            var reports = 0
            let group = DispatchGroup()
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for _ in 0..<bumps { LocalDataEraseEpoch.bump() }
            }
            DispatchQueue.global(qos: .utility).async(group: group) {
                DispatchQueue.concurrentPerform(iterations: 16) { index in
                    if index % 4 == 0 {
                        _ = ResidentObservationCenter.compareSeed(.miss(.noFile, decodedLines: 0), seedMs: 0, url: url,
                                                                  bounds: bounds, claim: claim, retention: 200)
                        lock.lock(); reports += 1; lock.unlock()
                    }
                    let runs = SpikeRunFileScan.records(in: payload)
                    lock.lock()
                    counts.append(runs.count)
                    epochs.append(contentsOf: runs.map(\.eraseEpoch))
                    lock.unlock()
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
            XCTAssertEqual(counts.count, 16)
            XCTAssertEqual(Set(counts), [lineCount], "no line lost to a decode on any thread")
            XCTAssertEqual(reports, 4)
            XCTAssertTrue(epochs.allSatisfy { (first...(first + bumps)).contains($0) },
                          "an epoch outside the read: \(epochs.filter { !(first...(first + bumps)).contains($0) }.prefix(3))")
            XCTAssertEqual(LocalDataEraseEpoch.capture(), first + bumps, "no bump lost")
        }
    }
}
