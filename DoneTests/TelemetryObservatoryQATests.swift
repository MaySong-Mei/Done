//
//  TelemetryObservatoryQATests.swift
//  DoneTests
//
//  gh#273 §16, independent QA on the observatory slice (1fec7b0). Each test
//  here kills a mutant that the slice's own suite let through: the
//  production TestFlight detector, a batch that runs before StoreKit
//  answers, `activate()` as the default's real entry, a lower cloud revision
//  over a fresher local copy, the device count, and the switch's one write
//  path (the toggle binding, never an observer of the stored value). Every
//  absence is paired with a positive control.
//

import StoreKit
import XCTest
@testable import Done

/// A scratch pool, a scratch defaults suite, account A's fake server and a
/// clock — the same rig shape as TelemetryObservatoryTests', kept separate
/// so neither file depends on the other's private helpers.
@MainActor
private final class ObservatoryQARig {
    let uid = TelemetryFixtures.uid
    let location = SpikeRunStorageLocation.ephemeral(id: UUID())
    let suiteName = "TelemetryObservatoryQATests-\(UUID().uuidString)"
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

    func uploader(isTestFlight: Bool) -> TelemetryUploader {
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.now = { [unowned self] in self.clock }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.distribution = { [unowned self] in
            self.detectorCalls += 1
            return isTestFlight ? .testFlight : .appStore
        }
        let uploader = TelemetryUploader(dependencies: deps)
        uploader.attach(TelemetryUploader.Attachment(
            gateway: server, isBlockedByBuild: { false },
            currentUserID: { [uid] in uid }, isSignedIn: { true }
        ))
        return uploader
    }

    var switchOn: Bool { defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled) }

    /// A record as the cloud hands it back: wire row → JSON → `run(fromRow:)`,
    /// the path the deck's cloud records take.
    func viaCloud(_ run: SpikeRun) throws -> SpikeRun {
        let row = TelemetryWire.row(for: run, userID: uid, installID: run.installID ?? UUID(), now: clock) { _ in
            ("2026-09-21", 0)
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: row)) as? [String: Any])
        return try XCTUnwrap(TelemetryWire.run(fromRow: json))
    }
}

/// The first day of the deck's window for these fixtures (r2, review P1-3):
/// every fixture day — 2026-09-21 and the day before — is inside it.
private let qaWindowStart = "2026-07-23"

/// The segment `TelemetryFixtures.run` stamps (model and OS), read as this
/// phone's: the deck's timing verdicts are judged on it.
private let qaSegment = FixWatchSegment(deviceModel: "iPhone17,2", osVersion: "26.0")

/// A daily whose Me-tab liveness counter reads `visible` — the number the
/// deck shows as "visible computes (liveness)", so which copy of a record
/// the deck evaluated is visible in its output.
private func daily(id: UUID = UUID(), visible: Int, revision: Int, install: UUID?,
                   configuration: String = "release", startedAt: Date = TelemetryFixtures.t0) -> SpikeRun {
    var metrics = ResidentCounterSet().metrics
    metrics["meComputedVisible"] = .number(Double(visible))
    var run = TelemetryFixtures.run(id: id, startedAt: startedAt, buildConfiguration: configuration,
                                    metrics: metrics, revision: revision)
    run.installID = install
    return run
}

private func meTabVisible(_ verdicts: [FixVerdict]) -> String? {
    verdicts.first { $0.entryID == FixObservationRegistry.meTabGateFixID }?
        .readouts.first { $0.id == "visible computes (liveness)" }?.measured
}

// MARK: - TestFlight: the production answer and the real entry

@MainActor
final class TelemetryTestFlightQATests: XCTestCase {
    private var rig: ObservatoryQARig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryQARig()
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    /// Every TestFlight test in the slice injects the answer, so the one
    /// function that decides "App Store install → default OFF" ran in no
    /// test. This host is a simulator test run — never a TestFlight
    /// install — so the production detector, and the production dependency
    /// that wraps it, must say false. StoreKit's own answer is read first
    /// and printed, so the precondition is checked, not assumed. (Mutants:
    /// detector constant `.testFlight`; `Dependencies().distribution` =
    /// `{ .testFlight }`.)
    func testOnThisSimulatorTheProductionDetectorAndTheLiveDependencySayNotTestFlight() async {
        var storeKit = "error"
        do {
            switch try await AppTransaction.shared {
            case .verified(let transaction): storeKit = "verified:\(transaction.environment.rawValue)"
            case .unverified(let transaction, _): storeKit = "unverified:\(transaction.environment.rawValue)"
            }
        } catch {
            storeKit = "error"
        }
        XCTAssertNotEqual(storeKit, "verified:\(AppStore.Environment.sandbox.rawValue)",
                          "rig: this host must not be a TestFlight install")
        let detector = await TelemetryDistributionDetector.live()
        XCTAssertNotEqual(detector, .testFlight, "StoreKit said \(storeKit); the detector must not read that as TestFlight")
        let live = await TelemetryUploader.Dependencies().distribution()
        XCTAssertNotEqual(live, .testFlight, "the production dependency asks the detector (StoreKit said \(storeKit))")
    }

    /// The slice's tests call `applyTestFlightDefaultIfNeeded()` directly
    /// ("what activate() runs"); nothing pinned that `activate()` — the
    /// app's real entry — runs it. On a TestFlight install, activating
    /// switches statistics on, marked as the default's, with the consent at
    /// the real moment (review P1-1: the backfill is the watermark rule's,
    /// never a stored distant past); on an App Store install the detector is
    /// asked and nothing changes (the pair is the control: the wait below is
    /// not what turned it on).
    func testActivateIsWhatAppliesTheTestFlightDefault() async {
        let other = rig.uploader(isTestFlight: false)
        other.activate()
        for _ in 0..<300 where rig.detectorCalls == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(rig.detectorCalls, 1, "liveness: activate() asked the detector")
        XCTAssertFalse(rig.switchOn, "not TestFlight: activate() leaves the switch off")
        XCTAssertNil(TelemetryConsentStore.consentAt(rig.defaults))
        await other.drain()

        let testFlight = rig.uploader(isTestFlight: true)
        testFlight.activate()
        for _ in 0..<300 where !rig.switchOn {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(rig.switchOn, "TestFlight: activate() itself applies the default")
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), rig.clock,
                       "the default's consent is the real moment, not 0001-01-01")
        XCTAssertTrue(TelemetryConsentStore.isEnabledByDefault(rig.defaults), "and marked as the default's")
        XCTAssertFalse(TelemetryConsentStore.userHasDecided(rig.defaults), "and records no decision")
        await testFlight.drain()
    }

    /// `isTestFlightInstall` is nil until StoreKit answers; a batch that
    /// runs first (the launch batch can beat the detector) must filter by
    /// the stored consent — the App Store rule — and leave older history
    /// pending, not send it on a guess. Positive control: once the answer
    /// is TestFlight, the next trigger sends that history ("late, never
    /// lost"). (Mutant: nil read as TestFlight.)
    func testABatchBeforeStoreKitAnswersUsesTheConsentMomentAndTheLateAnswerBackfills() async {
        let day: TimeInterval = 86_400
        let before = TelemetryFixtures.run(startedAt: rig.clock - 10 * day, endedAt: rig.clock - 10 * day + 60, revision: nil)
        let chosen = rig.clock.addingTimeInterval(0.5)
        let after = TelemetryFixtures.run(startedAt: chosen.addingTimeInterval(60), endedAt: chosen.addingTimeInterval(90), revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(before, location: rig.location))
        XCTAssertTrue(SpikeRunStore.finishRun(after, location: rig.location))
        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetrySwitchEdge.apply(from: false, to: true, defaults: rig.defaults, now: chosen, uploader: nil)

        let uploader = rig.uploader(isTestFlight: true)
        XCTAssertNil(uploader.isTestFlightInstall, "rig: StoreKit has not answered yet")
        let first = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(first, .uploaded(rows: 1))
        XCTAssertNotNil(rig.server.telemetryRow(runID: after.id), "positive control: what came after the ON went up")
        XCTAssertNil(rig.server.telemetryRow(runID: before.id),
                     "before StoreKit answers, the stored consent is the watermark — even on what will turn out to be TestFlight")
        XCTAssertEqual(rig.detectorCalls, 0, "the batch did not ask StoreKit on its own")

        _ = await uploader.applyTestFlightDefaultIfNeeded()
        await uploader.drain()
        XCTAssertEqual(uploader.isTestFlightInstall, true)
        XCTAssertNotNil(rig.server.telemetryRow(runID: before.id), "the late TestFlight answer backfills it on the next batch")
        XCTAssertEqual(rig.server.telemetryRowCount(), 2)
    }
}

// MARK: - The deck's merge and source line

@MainActor
final class TelemetryObservatoryMergeQATests: XCTestCase {
    private var rig: ObservatoryQARig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryQARig()
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    /// Today's daily keeps counting on this phone after an upload, so the
    /// cloud copy of it can be OLDER than the local one. The slice's merge
    /// tests only ever had the cloud newer or tied; a merge that let any
    /// non-tied cloud copy win passed them all. The deck must show the
    /// fresher local count, and — positive control — a newer cloud copy
    /// does replace it.
    func testALowerCloudRevisionNeverReplacesTheFresherLocalCopy() throws {
        let id = UUID(), install = UUID()
        let local = daily(id: id, visible: 9, revision: 3, install: install)
        let staleCloud = try rig.viaCloud(daily(id: id, visible: 1, revision: 2, install: install))

        let merged = TelemetryObservatoryMerge.merge(local: [local], cloud: [staleCloud])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.revision, 3, "the local copy is newer")
        XCTAssertEqual(merged.first?.metrics["meComputedVisible"], .number(9))
        let deck = FixWatchAttention.observatory(localDailies: [local], localWindows: [], cloud: [staleCloud], localInstall: install, sinceDayKey: qaWindowStart, currentSegment: qaSegment)
        XCTAssertEqual(meTabVisible(deck.verdicts), "9", "the deck reads the fresher local count")

        let newerCloud = try rig.viaCloud(daily(id: id, visible: 5, revision: 4, install: install))
        let replaced = FixWatchAttention.observatory(localDailies: [local], localWindows: [], cloud: [newerCloud], localInstall: install, sinceDayKey: qaWindowStart, currentSegment: qaSegment)
        XCTAssertEqual(meTabVisible(replaced.verdicts), "5", "positive control: a newer cloud copy does win")
    }

    /// The source line counts the installs behind the RELEASE records the
    /// verdicts read. A Debug build's own records feed no verdict, so they
    /// are not a device here: this phone's debug daily plus another phone's
    /// release rows is one device; the same phone with a release daily is
    /// two (positive control). Pins the implementation's stated rule
    /// (`FixWatchAttention.observatory` doc comment), not a spec sentence.
    func testTheDeviceCountNamesOnlyTheInstallsBehindReleaseRecords() throws {
        let here = UUID(), otherPhone = UUID()
        let theirs = try rig.viaCloud(daily(visible: 2, revision: 1, install: otherPhone,
                                            startedAt: rig.clock.addingTimeInterval(-86_400)))
        let debugHere = daily(visible: 4, revision: 1, install: here, configuration: "debug")
        let debugOnly = FixWatchAttention.observatory(localDailies: [debugHere], localWindows: [], cloud: [theirs], localInstall: here, sinceDayKey: qaWindowStart, currentSegment: qaSegment)
        XCTAssertEqual(debugOnly.source, .cloud(devices: 1), "a Debug build's own records are not a device the verdicts came from")

        let releaseHere = daily(visible: 4, revision: 1, install: here)
        let both = FixWatchAttention.observatory(localDailies: [releaseHere], localWindows: [], cloud: [theirs], localInstall: here, sinceDayKey: qaWindowStart, currentSegment: qaSegment)
        XCTAssertEqual(both.source, .cloud(devices: 2), "positive control: a release record here is a second device")
    }
}

// MARK: - The switch has one write path

final class TelemetrySwitchWritePathScanTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// §16 rule 2 and the Fix Watch toggle's own comment: the TestFlight
    /// default WRITES the stored switch, so any view that observes the
    /// stored value and runs the edge would record the default as the
    /// user's decision and overwrite the consent moment with "now". The
    /// edge must run from exactly one place — the toggle's binding setter —
    /// and nothing in the app may observe the stored switch. Read as code
    /// with comments stripped (a comment naming the call cannot stand in for
    /// it), across every Swift file under Done/. Liveness: the same scan
    /// does find the app's other `.onChange(of:` sites.
    func testTheEdgeRunsOnlyFromTheToggleBindingAndNothingObservesTheStoredSwitch() throws {
        let done = repoRoot.appendingPathComponent("Done")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: done, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "liveness: the scan reads the app's sources")

        let observer = try NSRegularExpression(
            pattern: #"\.(onChange\(of:|onReceive\()\s*(self\.)?_?\$?telemetryUploadsEnabled"#)
        let anyOnChange = try NSRegularExpression(pattern: #"\.onChange\(of:"#)
        var edgeSites: [String: Int] = [:]
        var observers: [String] = []
        var onChangeSites = 0
        for url in files {
            let code = EraseWiringScan.strippingComments(try String(contentsOf: url, encoding: .utf8))
            let name = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            let edges = code.components(separatedBy: "TelemetrySwitchEdge.apply(").count - 1
            if edges > 0 { edgeSites[name] = edges }
            let range = NSRange(code.startIndex..., in: code)
            if observer.firstMatch(in: code, range: range) != nil { observers.append(name) }
            onChangeSites += anyOnChange.numberOfMatches(in: code, range: range)
        }
        XCTAssertGreaterThan(onChangeSites, 10, "liveness: the scan does see the app's onChange sites")
        XCTAssertEqual(observers, [], "nothing may observe the stored statistics switch")
        XCTAssertEqual(edgeSites, ["Done/Views/Agent/FixWatchView.swift": 1], "the edge has exactly one call site")

        let fixWatch = EraseWiringScan.strippingComments(
            try String(contentsOf: done.appendingPathComponent("Views/Agent/FixWatchView.swift"), encoding: .utf8))
        let binding = try XCTUnwrap(fixWatch.range(of: "Toggle(isOn: Binding("), "the switch is bound, not observed")
        let setter = try XCTUnwrap(fixWatch.range(of: "set: {", range: binding.upperBound..<fixWatch.endIndex))
        let edge = try XCTUnwrap(fixWatch.range(of: "TelemetrySwitchEdge.apply(", range: setter.upperBound..<fixWatch.endIndex))
        let label = try XCTUnwrap(fixWatch.range(of: "L(.telemetryShareToggle)", range: binding.upperBound..<fixWatch.endIndex))
        XCTAssertLessThan(edge.lowerBound, label.lowerBound, "the edge sits in the statistics toggle's own setter")
    }
}

// MARK: - Independent QA: segments on the cloud path (feat/fixwatch-segment)

/// The deck's segments, read off rows that came back over the wire. The
/// shapes the slice's own cloud test does not build: this phone's segment
/// present ONLY in the cloud (a reinstall — another install id, the same
/// model and OS major, a different point release), and a Me-tab hidden
/// compute only in a cloud-only, non-current segment.
@MainActor
final class FixWatchSegmentCloudQATests: XCTestCase {
    private var rig: ObservatoryQARig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryQARig()
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    private func segmentDaily(model: String, os: String, install: UUID, dayKey: String, startedAt: Date,
                              taps: String, hidden: Int = 0, visible: Int = 0) -> SpikeRun {
        var metrics = ResidentCounterSet().metrics
        metrics[ResidentCounterSet.tapLagBucketsKey] = .string(taps)
        metrics["meComputedHidden"] = .number(Double(hidden))
        metrics["meComputedVisible"] = .number(Double(visible))
        var run = SpikeRun(
            id: UUID(), spikeID: FixObservationRegistry.residentDailySpikeID,
            scenarioID: FixObservationRegistry.residentDailyScenarioID, variantID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            appVersion: "0.5.0", appBuild: "24", appCommit: nil,
            deviceModel: model, osVersion: os,
            timeZoneIdentifier: "America/Los_Angeles", localeIdentifier: "zh_CN",
            buildConfiguration: "release", metrics: metrics, note: nil, outcome: .completed, abortReason: nil
        )
        run.installID = install
        run.ownerUID = rig.uid
        run.dayKey = dayKey
        run.dayTZOffsetMin = -420
        run.revision = 1
        run.kind = .dailyRollup
        return run
    }

    private func card(_ id: String, _ verdicts: [FixVerdict]) throws -> FixVerdict {
        try XCTUnwrap(verdicts.first { $0.entryID == id })
    }

    /// No local records at all (a fresh install). The cloud holds this
    /// phone's model and OS major from the previous install — 12 taps in
    /// 40–80 → 0/12 → 未达标 — and the old phone's 12 fast taps plus one
    /// hidden compute. Judged on the cloud's copy of this phone's segment;
    /// the old phone shows report-only; the hidden compute alarms.
    /// Positive control: offline, the same deck is 观察中 with no rows
    /// beyond its own and no alarm.
    func testThisPhonesSegmentOnlyInTheCloudIsJudgedAndAnotherCloudOnlySegmentIsNot() throws {
        let here = UUID(), previousInstall = UUID(), oldPhone = UUID()
        let current = FixWatchSegment(deviceModel: "iPhone19,2", osVersion: "27.0")
        let mineBefore = try rig.viaCloud(segmentDaily(
            model: "iPhone19,2", os: "27.0.1", install: previousInstall, dayKey: "2026-09-21",
            startedAt: rig.clock, taps: "0 0 0 12 0 0 0 0", visible: 1))
        let theirs = try rig.viaCloud(segmentDaily(
            model: "iPhone16,2", os: "26.6", install: oldPhone, dayKey: "2026-09-20",
            startedAt: rig.clock - 86_400, taps: "12 0 0 0 0 0 0 0", hidden: 1))
        XCTAssertEqual(mineBefore.osVersion, "27.0.1", "rig: the wire keeps the point release")

        let online = FixWatchAttention.observatory(localDailies: [], localWindows: [], cloud: [mineBefore, theirs],
                                                   localInstall: here, sinceDayKey: qaWindowStart, currentSegment: current)
        XCTAssertEqual(online.source, .cloud(devices: 2))
        let touch = try card(FixObservationRegistry.touchDeliveryFixID, online.verdicts)
        XCTAssertEqual(touch.state, .failing)
        XCTAssertEqual(touch.readouts.map(\.measured), ["0/12 ≤ 40ms", "12/12 ≤ 120ms", "12/12 ≤ 40ms", "12/12 ≤ 120ms"])
        XCTAssertEqual(touch.readouts.map(\.passing), [false, true, nil, nil])
        XCTAssertEqual(touch.readouts[2].id, "iPhone16,2 · iOS 26 · tap lag p50")
        XCTAssertEqual(touch.releaseDayCount, 1)
        XCTAssertTrue(touch.notes.contains { $0.contains("合计 2 天") }, "\(touch.notes)")
        let gate = try card(FixObservationRegistry.meTabGateFixID, online.verdicts)
        XCTAssertTrue(gate.alarm, "a hidden compute on any phone is a regression")
        XCTAssertEqual(try card(FixObservationRegistry.effortPathFixID, online.verdicts).state, .failing,
                       "Entry 1 on the cloud's copy of this phone: lag 0/12 decided-failing dominates the empty commit")

        let offline = FixWatchAttention.observatory(localDailies: [], localWindows: [], cloud: nil,
                                                    localInstall: here, sinceDayKey: qaWindowStart, currentSegment: current)
        XCTAssertEqual(offline.source, .localOnly)
        let offTouch = try card(FixObservationRegistry.touchDeliveryFixID, offline.verdicts)
        XCTAssertEqual(offTouch.state, .observing)
        XCTAssertEqual(offTouch.readouts.count, 2)
        XCTAssertFalse(offTouch.notes.contains { $0.contains("还没有 Release 数据") })
        XCTAssertFalse(try card(FixObservationRegistry.meTabGateFixID, offline.verdicts).alarm)
    }
}
