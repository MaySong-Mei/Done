//
//  ObsReadQAMainThreadCostTests.swift
//  DoneTests
//
//  Independent QA for perf/obs-read: what the main thread pays, before and
//  after, on a spike-run pool shaped like the 18 Pro's (10-28 listing):
//  resident-daily 242,805 B in 223 lines over 63 ids, lines up to about
//  3.2 KB; windows 35,283 B; effort-tap-201 41,912 B; detail-perf-195
//  1,014 B. "Before" runs the 3111ef1 code paths (the oracle's verbatim
//  copy, or the store calls that did not change); "after" runs this branch's.
//
//  Timings are printed, not asserted (wall clock is shared with other
//  agents' builds and suites). What is asserted is deterministic: the new
//  seed and lookup, through the center's launch and the store's append, read
//  no whole file and decode a bounded number of lines; the 3111ef1 reads are
//  whole-file reads the counter sees (the positive control).
//

import XCTest
@testable import Done

@MainActor
final class ObsReadQAMainThreadCostTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private let noon = Date(timeIntervalSinceReferenceDate: Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: Date())!.timeIntervalSinceReferenceDate.rounded(.down))
    private let claimBuild = "10"

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        try? FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    private func url(_ spikeID: String) -> URL { location.directory.appendingPathComponent("\(spikeID).jsonl") }

    private func stamp(build: String) -> SpikeRunContext.Stamp {
        SpikeRunContext.Stamp(appVersion: "0.5.0", appBuild: build, appCommit: nil, deviceModel: "iPhone17,2",
                              osVersion: "26.0", timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
                              buildConfiguration: "release")
    }

    /// A line of `size` bytes (newline included) shaped like a daily: the
    /// counter keys, follower-like keys, string histograms.
    private func sizedLine(_ base: SpikeRun, size: Int) -> Data {
        var run = base
        func encoded() -> Data { ObsReadQABytes.line(run) }
        run.metrics["pad"] = .string("")
        let length = encoded().count
        run.metrics["pad"] = .string(String(repeating: "7", count: max(0, size - length)))
        return encoded()
    }

    private func dailyBase(_ id: UUID, startedAt: Date, build: String, followers: Bool, rng: inout ObsReadQARandom) -> SpikeRun {
        var counters = ResidentCounterSet()
        counters.tapCount = Int.random(in: 0...900, using: &rng)
        counters.meComputedVisible = Int.random(in: 0...300, using: &rng)
        counters.detailBodyPasses = Int.random(in: 0...3_000, using: &rng)
        var metrics = counters.metrics
        if followers {
            // Today's lines carry the batch-2a follower keys: the widest lines.
            for index in 0..<36 { metrics["follower.f\(index).ms"] = .number(Double(Int.random(in: 0...90_000, using: &rng)) / 7) }
        }
        var run = ObsReadQABytes.run(id: id, spikeID: FixObservationRegistry.residentDailySpikeID, startedAt: startedAt,
                                     revision: 1, build: build, metrics: metrics)
        run.kind = .dailyRollup
        return run
    }

    /// The pool, shaped like the device's. Returns today's id (the last
    /// lines of the daily file, under build `claimBuild`).
    private func writeDevicePool() throws -> (today: UUID, dailyLines: Int, dailyIDs: Int) {
        var rng = ObsReadQARandom(seed: 0x18_0F_2026)
        // resident-daily: 63 ids, 223 lines, one id with 40 lines, today's last.
        var counts = Array(repeating: 1, count: 63)
        counts[10] = 40
        counts[62] = 5
        var remaining = 223 - counts.reduce(0, +)
        while remaining > 0 { counts[Int.random(in: 0..<62, using: &rng)] += 1; remaining -= 1 }
        var lines: [Data] = []
        var today = UUID()
        for (index, count) in counts.enumerated() {
            let id = UUID()
            let isToday = index == counts.count - 1
            if isToday { today = id }
            let start = isToday ? noon.addingTimeInterval(-7_200) : noon.addingTimeInterval(-86_400 * Double(63 - index) / 2)
            let base = dailyBase(id, startedAt: start, build: isToday ? claimBuild : "9", followers: isToday, rng: &rng)
            for revision in 1...count {
                var run = base
                run.revision = revision
                let plain = ObsReadQABytes.line(run).count
                lines.append(sizedLine(run, size: isToday ? Int.random(in: 2_600...3_177, using: &rng)
                                                          : plain + 8 + Int.random(in: 0...160, using: &rng)))
            }
        }
        // The device's size exactly: drop the oldest lines while over, then
        // pad the first line kept.
        let target = 242_805
        while lines.reduce(0, { $0 + $1.count }) > target - 2_000 { lines.removeFirst() }
        let rest = lines.dropFirst().reduce(0) { $0 + $1.count }
        let firstRun = try ObsReadQAOracle.decoder().decode(SpikeRun.self, from: lines[0].dropLast())
        lines[0] = sizedLine(firstRun, size: target - rest)
        let daily = lines.reduce(Data(), +)
        XCTAssertEqual(daily.count, target, "rig: the daily file is the device's size")
        try daily.write(to: url(FixObservationRegistry.residentDailySpikeID))
        let ids = Set(ObsReadQAOracle.records(daily).map(\.id)).count

        func fill(_ spikeID: String, scenario: String, kind: TelemetryRecordKind, bytes: Int, sizes: ClosedRange<Int>) throws {
            var data = Data()
            var index = 0
            while data.count < bytes {
                var run = ObsReadQABytes.run(id: UUID(), spikeID: spikeID, startedAt: noon.addingTimeInterval(-Double(index) * 3_000),
                                             revision: 1, metrics: ["wTaps": .number(2), "wGestures": .number(3)])
                run.kind = kind
                _ = scenario
                data += sizedLine(run, size: Int.random(in: sizes, using: &rng))
                index += 1
            }
            try data.write(to: url(spikeID))
        }
        try fill(FixObservationRegistry.effortPathFixID, scenario: "auto-window", kind: .window, bytes: 35_283, sizes: 600...1_500)
        try fill(Spike201SignalID.spikeID, scenario: "default", kind: .manualRun, bytes: 41_912, sizes: 800...2_400)
        try fill("detail-perf-195", scenario: "default", kind: .manualRun, bytes: 1_014, sizes: 900...1_000)
        return (today, lines.count, ids)
    }

    private func median(_ runs: Int = 9, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        body()   // warm
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        return samples.sorted()[samples.count / 2]
    }

    func testMeasureTheMainThreadReadsOnADeviceSizedPool() throws {
        let (today, dailyLineCount, dailyIDCount) = try writeDevicePool()
        let dailyURL = url(FixObservationRegistry.residentDailySpikeID)
        let dailyBytes = try Data(contentsOf: dailyURL)
        let bounds = ResidentDayBounds.compute(for: noon, calendar: .current)
        let claim = TelemetryClaimKey(buildConfiguration: "release", appBuild: claimBuild, osVersion: "26.0", ownerUID: "owner-a")
        let newBuild = TelemetryClaimKey(buildConfiguration: "release", appBuild: "11", osVersion: "26.0", ownerUID: "owner-a")
        let matches: (SpikeRun) -> Bool = { bounds.contains($0.startedAt) && TelemetryClaimKey(run: $0) == claim }
        let matchesNew: (SpikeRun) -> Bool = { bounds.contains($0.startedAt) && TelemetryClaimKey(run: $0) == newBuild }
        XCTAssertEqual(ObsReadQAOracle.seed(dailyBytes, matches: matches)?.id, today, "rig: today's record is the last id")
        var lines: [String] = []
        func report(_ label: String, _ ms: Double) {
            lines.append(label.padding(toLength: 66, withPad: " ", startingAt: 0) + String(format: "%8.2f ms", ms))
        }
        lines.append("pool: resident-daily \(dailyBytes.count) B, \(dailyLineCount) lines, \(dailyIDCount) ids")

        // Positive control for the counts asserted below: the reads the 3111ef1
        // seed and lookup made are whole-file reads, and the counter sees each.
        var reads = SpikeRunStore.wholeFileReads
        _ = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
        XCTAssertEqual(SpikeRunStore.wholeFileReads - reads, 1, "control: the 3111ef1 seed's read is one whole-file read")
        reads = SpikeRunStore.wholeFileReads
        _ = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location,
                                   applyRetention: false).first { $0.id == today }
        XCTAssertEqual(SpikeRunStore.wholeFileReads - reads, 1, "control: the 3111ef1 lookup's read is one whole-file read")

        // Launch seed.
        let seedOld = median { _ = ObsReadQAOracle.seed((try? Data(contentsOf: dailyURL)) ?? Data(), matches: matches) }
        let seedHit = median {
            _ = SpikeRunFileScan.newestMatch(in: dailyURL, maxBytes: ResidentObservationCenter.seedTailBytes,
                                             maxDecodes: ResidentObservationCenter.seedMaxDecodes, where: matches)
        }
        let seedMiss = median {
            _ = SpikeRunFileScan.newestMatch(in: dailyURL, maxBytes: ResidentObservationCenter.seedTailBytes,
                                             maxDecodes: ResidentObservationCenter.seedMaxDecodes, where: matchesNew)
        }
        report("launch seed, 3111ef1 (whole file)", seedOld)
        report("launch seed, branch (tail, today's line last: 1 decode)", seedHit)
        report("launch seed, branch (tail, new build: 8 decodes)", seedMiss)

        // Revision lookup: the first daily flush of a process, every window close.
        let revisionOld = median {
            _ = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location,
                                       applyRetention: false).first { $0.id == today }
        }
        var decodes = 0
        let revisionPresent = median { _ = SpikeRunFileScan.latestLine(of: today, in: dailyURL, decodedLines: &decodes) }
        let fresh = UUID()
        let revisionFresh = median { _ = SpikeRunFileScan.latestLine(of: fresh, in: dailyURL, decodedLines: &decodes) }
        let windowsURL = url(FixObservationRegistry.effortPathFixID)
        let windowOld = median {
            _ = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location,
                                       applyRetention: false).first { $0.id == fresh }
        }
        let windowNew = median { _ = SpikeRunFileScan.latestLine(of: fresh, in: windowsURL, decodedLines: &decodes) }
        report("revision lookup, daily, 3111ef1 (whole file)", revisionOld)
        report("revision lookup, daily, branch (today's id)", revisionPresent)
        report("revision lookup, daily, branch (fresh id)", revisionFresh)
        report("revision lookup, window close, 3111ef1", windowOld)
        report("revision lookup, window close, branch", windowNew)

        // The search itself: today's id costs the one line it is on, a fresh id none.
        var searchDecodes = 0
        if case .found(let run) = SpikeRunFileScan.latestLine(of: today, in: dailyURL, decodedLines: &searchDecodes) {
            XCTAssertEqual(run.revision, 5)
        } else {
            XCTFail("rig: today's id is on disk")
        }
        XCTAssertEqual(searchDecodes, 1, "today's id: one decode")
        searchDecodes = 0
        XCTAssertEqual(SpikeRunFileScan.latestLine(of: UUID(), in: dailyURL, decodedLines: &searchDecodes), .absent)
        XCTAssertEqual(searchDecodes, 0, "a fresh id: no decode")

        // A new build's first launch: the tail misses within its decode budget,
        // and reads no whole file.
        reads = SpikeRunStore.wholeFileReads
        let newBuildLaunch = ResidentObservationCenter(
            coordinator: SpikeSessionCoordinator(), store: nil, location: location, calendar: .current,
            now: { [noon] in noon }, mediaNow: { 500 }, makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { "owner-a" }, stamp: { [unowned self] in self.stamp(build: "11") },
            installsFollowerProbe: false, isAppActive: { true }, verifiesSeed: false)
        XCTAssertEqual(SpikeRunStore.wholeFileReads, reads, "a new build's launch seed reads no whole file")
        if case .miss(_, let decodes) = newBuildLaunch.launchSeed {
            XCTAssertLessThanOrEqual(decodes, ResidentObservationCenter.seedMaxDecodes, "within the decode budget")
        } else {
            XCTFail("rig: a new build adopts nothing")
        }

        // The Settings row, with a live center holding an unwritten day. Its
        // launch is the seed under test: no whole-file read, one decode.
        reads = SpikeRunStore.wholeFileReads
        let made = ResidentObservationCenter(
            coordinator: SpikeSessionCoordinator(), store: nil, location: location, calendar: .current,
            now: { [noon] in noon }, mediaNow: { 500 }, makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { "owner-a" }, stamp: { [claimBuild, unowned self] in self.stamp(build: claimBuild) },
            installsFollowerProbe: false, isAppActive: { true }, verifiesSeed: false)
        made.activate()
        center = made
        XCTAssertEqual(SpikeRunStore.wholeFileReads, reads, "the launch seed reads no whole file")
        if case .found(let adopted, let decodes) = made.launchSeed {
            XCTAssertEqual(adopted.id, today, "rig: the center adopted today's line")
            XCTAssertEqual(decodes, 1, "today's line is the last: one decode")
        } else {
            XCTFail("rig: the center adopted today's line")
        }
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))

        let poolRead = {
            for spikeID in SpikeRunStore.spikeIDsOnDisk(location: self.location) {
                _ = SpikeRunStore.loadRuns(spikeID: spikeID, location: self.location)
            }
        }
        let rowRead = median {
            _ = FixWatchAttention.evaluate(
                dailies: SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: self.location),
                windows: SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: self.location),
                currentSegment: .thisDevice())
        }
        var flushSamples: [Double] = []
        for index in 0..<9 {
            SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
            reads = SpikeRunStore.wholeFileReads
            let start = DispatchTime.now().uptimeNanoseconds
            made.flushForManualUpload()
            flushSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            if index == 0 {
                // The first append of today's id here: the revision lookup runs.
                XCTAssertEqual(SpikeRunStore.wholeFileReads, reads, "the first flush's revision lookup reads no whole file")
                let appended = try ObsReadQAOracle.decoder().decode(
                    SpikeRun.self, from: Data(try XCTUnwrap(try Data(contentsOf: dailyURL).split(separator: 0x0A).last)))
                XCTAssertEqual(appended.id, today)
                XCTAssertEqual(appended.revision, 6, "liveness: the lookup ran and found revision 5")
            }
            try dailyBytes.write(to: dailyURL)       // back to the device's size, untimed
        }
        // A window close: always a fresh id, so always a lookup.
        reads = SpikeRunStore.wholeFileReads
        var window = ObsReadQABytes.run(id: UUID(), spikeID: FixObservationRegistry.effortPathFixID, startedAt: noon,
                                        revision: nil, metrics: ["wTaps": .number(1)])
        window.kind = .window
        XCTAssertTrue(SpikeRunStore.finishRun(window, owner: .explicit("owner-a"), location: location))
        XCTAssertEqual(SpikeRunStore.wholeFileReads, reads, "a window close's revision lookup reads no whole file")
        let flush = flushSamples.sorted()[4]
        let pool = median(9, poolRead)
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        XCTAssertNotNil(made.unwrittenDailyRecord(), "rig: the row has an unwritten day to fold")
        let statisticsOff = StatisticsOffDefaults.make()
        let rowNew = median { _ = FixWatchAttention.needsAttention(location: self.location, defaults: statisticsOff) }
        report("Settings appear, 3111ef1: flush (append)", flush)
        report("Settings appear, 3111ef1: + its first flush's revision lookup", revisionOld)
        report("Settings appear, 3111ef1: row read (daily + windows, evaluate)", rowRead)
        report("Settings appear, 3111ef1: .deckOpen upload's pool read (all files)", pool)
        report("Settings appear, 3111ef1 total (flush + row + pool)", flush + rowRead + pool)
        report("Settings appear, branch (needsAttention: row read + fold)", rowNew)

        // What still reads whole files on the main thread.
        let reconcile = median {
            SpikeRunStore.reconcileInterruptedRuns(spikeIDs: [Spike201SignalID.spikeID, "detail-perf-195"], location: self.location)
        }
        report("still: launch reconcile (manual files, every root appear)", reconcile)
        report("still: uploader pool read (launch +2 s, edges, deck, rollover)", pool)
        report("still: deck open (flush + row read + pool)", flush + rowRead + pool)

        // A compaction crossing: the append that takes the daily file over the cap.
        let crossingURL = dailyURL
        let dailySplit = dailyBytes.split(separator: 0x0A)
        var crossingSamples: [Double] = []
        for index in 0..<5 {
            var padded = dailyBytes
            while padded.count < SpikeRunStore.compactAtBytes - 1_200 {
                padded += dailySplit[(index + padded.count) % 50] + Data([0x0A])
            }
            try padded.write(to: crossingURL)
            var run = ObsReadQABytes.run(id: today, spikeID: FixObservationRegistry.residentDailySpikeID,
                                         startedAt: noon.addingTimeInterval(-7_200), revision: nil, build: claimBuild,
                                         metrics: ["pad": .string(String(repeating: "9", count: 2_500))])
            run.kind = .dailyRollup
            let start = DispatchTime.now().uptimeNanoseconds
            SpikeRunStore.finishRun(run, owner: .explicit("owner-a"), location: location)
            crossingSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            let size = (try FileManager.default.attributesOfItem(atPath: crossingURL.path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertLessThan(size, SpikeRunStore.compactAtBytes, "rig: the append compacted")
        }
        report("still: compaction crossing (finishRun over 256 KiB)", crossingSamples.sorted()[2])
        try dailyBytes.write(to: dailyURL)

        // Timings are printed, never asserted: a wall-clock ratio goes red under
        // CPU contention (several agents and suites share this machine). The
        // claims are held by the counts above.
        print("QA main-thread cost (Debug, simulator), median of 9:\n" + lines.joined(separator: "\n"))
    }
}
