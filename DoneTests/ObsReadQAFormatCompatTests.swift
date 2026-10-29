//
//  ObsReadQAFormatCompatTests.swift
//  DoneTests
//
//  Independent QA for perf/obs-read step 4 (the healing newline): files the
//  new append can leave behind — a torn line closed by a newline of its own,
//  and blank lines — read by EVERY reader of the spike-run files, against
//  the same file never torn. Every reader goes through `loadRuns`: the
//  collapse, the uploader's pool read, compaction, the launch reconcile,
//  `setNote`, `latestRuns`.
//
//  Written against API that exists at 3111ef1 too (what users have
//  installed), so this file runs unchanged on both commits — the installed
//  build must read what this build writes. Nothing here uses a symbol the
//  branch added.
//

import XCTest
@testable import Done

@MainActor
final class ObsReadQAFormatCompatTests: XCTestCase {
    private var dirty: SpikeRunStorageLocation!
    private var clean: SpikeRunStorageLocation!
    private var suites: [String] = []
    private let install = UUID()
    private let t0 = TelemetryFixtures.t0

    override func setUp() {
        super.setUp()
        dirty = .ephemeral(id: UUID())
        clean = .ephemeral(id: UUID())
        for location in [dirty!, clean!] {
            try? FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
            try? Data(install.uuidString.utf8).write(to: SpikeRunStore.installIDURL(location: location))
        }
    }

    override func tearDown() {
        for location in [dirty!, clean!] { try? FileManager.default.removeItem(at: location.directory) }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        SpikeRunStore.ownerProvider = nil
        dirty = nil
        clean = nil
        super.tearDown()
    }

    private let manualSpike = Spike201SignalID.spikeID

    private func encode(_ run: SpikeRun) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try! encoder.encode(run)
        data.append(0x0A)
        return data
    }

    private func url(_ spikeID: String, _ location: SpikeRunStorageLocation) -> URL {
        location.directory.appendingPathComponent("\(spikeID).jsonl")
    }

    /// The same records twice: once as clean JSONL, once as a file a healed
    /// append leaves — a torn line closed by its own newline (cut inside a
    /// multi-byte note, inside the id, at the closing brace), a blank line,
    /// a run of blank lines, a blank first line and a blank last line.
    private struct Pair {
        var dirtyBytes = Data()
        var cleanBytes = Data()
        mutating func keep(_ line: Data) { dirtyBytes += line; cleanBytes += line }
        mutating func torn(_ line: Data, at cut: Int) { dirtyBytes += line.prefix(cut) + Data([0x0A]) }
        mutating func blank(_ count: Int = 1) { dirtyBytes += Data(repeating: 0x0A, count: count) }
    }

    private func dailies(owner: String? = TelemetryFixtures.uid) -> (Pair, [SpikeRun]) {
        var pair = Pair()
        var runs: [SpikeRun] = []
        pair.blank()
        for index in 0..<6 {
            var metrics: [String: SpikeMetricValue] = ["tapCount": .number(Double(index)), "meComputedVisible": .number(1)]
            metrics["note.mb"] = .string("观察站 🙂 e\u{301}")
            let run = TelemetryFixtures.run(id: UUID(), startedAt: t0.addingTimeInterval(Double(index) * 600),
                                            metrics: metrics, ownerUID: owner, revision: index + 1)
            runs.append(run)
            let line = encode(run)
            switch index {
            case 1:
                let other = encode(TelemetryFixtures.run(id: UUID(), startedAt: t0, note: "日本語のメモ", ownerUID: owner))
                pair.torn(other, at: other.count / 2)            // inside the note or the id
                pair.keep(line)
            case 2:
                pair.blank(3)
                pair.keep(line)
            case 3:
                // Torn only of its own `\n`: the heal makes it whole again, so
                // the never-torn twin holds the same record.
                let otherRun = TelemetryFixtures.run(id: UUID(), startedAt: t0, ownerUID: owner)
                let other = encode(otherRun)
                pair.dirtyBytes += other.prefix(other.count - 1) + Data([0x0A])
                pair.cleanBytes += other
                runs.insert(otherRun, at: runs.count - 1)
                pair.keep(line)
            case 4:
                let other = encode(TelemetryFixtures.run(id: UUID(), startedAt: t0, note: "🙂🙂🙂🙂", ownerUID: owner))
                let emoji = other.range(of: Data("🙂".utf8))!.lowerBound + 2
                pair.torn(other, at: emoji)                      // inside a 4-byte character
                pair.keep(line)
            default:
                pair.keep(line)
            }
        }
        pair.blank()
        return (pair, runs)
    }

    private func write(_ pair: Pair, spikeID: String) throws {
        try pair.dirtyBytes.write(to: url(spikeID, dirty))
        try pair.cleanBytes.write(to: url(spikeID, clean))
    }

    // MARK: The collapse and the list

    func testTheCollapseAndTheListReadTheHealedFileAsTheCleanOne() throws {
        let (pair, runs) = dailies()
        try write(pair, spikeID: FixObservationRegistry.residentDailySpikeID)
        let spike = FixObservationRegistry.residentDailySpikeID
        let fromDirty = SpikeRunStore.loadRuns(spikeID: spike, location: dirty)
        XCTAssertEqual(fromDirty, SpikeRunStore.loadRuns(spikeID: spike, location: clean))
        XCTAssertEqual(fromDirty.map(\.id), runs.map(\.id), "liveness: every whole record, nothing from a torn line")
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: spike, location: dirty, applyRetention: false),
                       SpikeRunStore.loadRuns(spikeID: spike, location: clean, applyRetention: false))
        XCTAssertEqual(SpikeRunStore.latestRuns(spikeID: spike, limit: 4, location: dirty),
                       SpikeRunStore.latestRuns(spikeID: spike, limit: 4, location: clean))
    }

    // MARK: The launch reconcile and setNote

    func testTheReconcileAndSetNoteReadTheHealedFileAsTheCleanOne() throws {
        var pair = Pair()
        pair.blank()
        let open = { () -> SpikeRun in
            var run = TelemetryFixtures.run(id: UUID(), spikeID: self.manualSpike, scenarioID: "default",
                                            startedAt: self.t0, endedAt: nil, note: "first note", kind: .manualRun, revision: 1)
            run.endedAt = nil
            return run
        }()
        let closed = TelemetryFixtures.run(id: UUID(), spikeID: manualSpike, scenarioID: "default",
                                           startedAt: t0.addingTimeInterval(60), kind: .manualRun, revision: 1)
        let torn = encode(TelemetryFixtures.run(id: UUID(), spikeID: manualSpike, scenarioID: "default", note: "残り", kind: .manualRun))
        pair.keep(encode(open))
        pair.torn(torn, at: torn.count / 3)
        pair.blank(2)
        pair.keep(encode(closed))
        pair.blank()
        try write(pair, spikeID: manualSpike)

        for location in [dirty!, clean!] {
            SpikeRunStore.reconcileInterruptedRuns(spikeIDs: [manualSpike], closedAt: t0.addingTimeInterval(3_600),
                                                   excludingRunIDs: [], location: location)
            XCTAssertTrue(SpikeRunStore.setNote("edited", forRunID: closed.id, spikeID: manualSpike, location: location))
        }
        let fromDirty = SpikeRunStore.loadRuns(spikeID: manualSpike, location: dirty)
        XCTAssertEqual(fromDirty, SpikeRunStore.loadRuns(spikeID: manualSpike, location: clean))
        XCTAssertEqual(fromDirty.first { $0.id == open.id }?.outcome, .interrupted, "liveness: the orphan was closed")
        XCTAssertEqual(fromDirty.first { $0.id == open.id }?.revision, 2)
        XCTAssertEqual(fromDirty.first { $0.id == closed.id }?.note, "edited")
        XCTAssertEqual(fromDirty.first { $0.id == closed.id }?.revision, 2)
    }

    // MARK: Compaction

    func testCompactionReadsTheHealedFileAsTheCleanOneAndWritesItClean() throws {
        let (pair, _) = dailies()
        let spike = FixObservationRegistry.residentDailySpikeID
        // The same old padding before both, to cross the compaction cap.
        var padding = Data()
        var index = 0
        while padding.count < SpikeRunStore.compactAtBytes {
            padding += encode(TelemetryFixtures.run(id: UUID(), startedAt: t0.addingTimeInterval(-86_400 - Double(index)),
                                                    metrics: ["pad": .string(String(repeating: "p", count: 2_000))]))
            index += 1
        }
        try (padding + pair.dirtyBytes).write(to: url(spike, dirty))
        try (padding + pair.cleanBytes).write(to: url(spike, clean))

        let crossing = TelemetryFixtures.run(id: UUID(), startedAt: t0.addingTimeInterval(7_200), revision: nil)
        for location in [dirty!, clean!] {
            XCTAssertTrue(SpikeRunStore.finishRun(crossing, owner: .explicit(TelemetryFixtures.uid), location: location))
            let size = (try FileManager.default.attributesOfItem(atPath: url(spike, location).path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertLessThan(size, SpikeRunStore.compactAtBytes, "liveness: the append compacted the file")
        }
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: spike, location: dirty, applyRetention: false),
                       SpikeRunStore.loadRuns(spikeID: spike, location: clean, applyRetention: false))
        let compacted = try Data(contentsOf: url(spike, dirty))
        XCTAssertFalse(compacted.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast().contains { $0.isEmpty },
                       "the rewrite carries no blank line")
    }

    // MARK: The uploader's pool read — what reaches the server

    private func sentRows(_ location: SpikeRunStorageLocation) async throws -> [String] {
        let suite = "ObsReadQAFormatCompatTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        let now = t0.addingTimeInterval(86_400)
        deps.now = { now }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        let uploader = TelemetryUploader(dependencies: deps)
        let server = SyncFakeServer(userId: TelemetryFixtures.uid)
        uploader.attach(TelemetryUploader.Attachment(gateway: server, isBlockedByBuild: { false },
                                                     currentUserID: { TelemetryFixtures.uid }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: t0.addingTimeInterval(-3_600))
        _ = await uploader.uploadNow(trigger: .launch)
        return server.requests(.telemetryUpsert).flatMap { ($0.body as? [[String: Any]]) ?? [] }.map { row in
            String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
        }.sorted()
    }

    /// The uploader matters most: the rows sent from the healed files are
    /// byte-for-byte the rows sent from the clean ones — dailies, windows and
    /// a manual run, every file the pool walks.
    func testTheUploaderSendsTheSameRowsFromTheHealedFiles() async throws {
        let (dailyPair, runs) = dailies()
        try write(dailyPair, spikeID: FixObservationRegistry.residentDailySpikeID)
        var windowPair = Pair()
        for index in 0..<3 {
            let window = encode(TelemetryFixtures.run(
                id: UUID(), spikeID: FixObservationRegistry.effortPathFixID, scenarioID: FixObservationRegistry.windowScenarioID,
                startedAt: t0.addingTimeInterval(Double(index) * 60), metrics: ["wTaps": .number(1)], kind: .window))
            if index == 1 {
                windowPair.torn(window, at: 17)
                windowPair.blank()
            }
            windowPair.keep(window)
        }
        try write(windowPair, spikeID: FixObservationRegistry.effortPathFixID)
        var manualPair = Pair()
        let manual = encode(TelemetryFixtures.run(id: UUID(), spikeID: manualSpike, scenarioID: "default",
                                                  note: "备注", kind: .manualRun))
        manualPair.blank(2)
        manualPair.keep(manual)
        manualPair.torn(manual, at: manual.count - 3)
        try write(manualPair, spikeID: manualSpike)

        let fromDirty = try await sentRows(dirty)
        let fromClean = try await sentRows(clean)
        XCTAssertEqual(fromDirty.count, runs.count + 3 + 1, "liveness: every record went out")
        XCTAssertEqual(fromDirty, fromClean, "the server sees the same rows")
    }
}
