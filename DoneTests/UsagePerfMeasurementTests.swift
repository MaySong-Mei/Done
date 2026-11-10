//
//  UsagePerfMeasurementTests.swift
//  DoneTests
//
//  gh#273 §6.3 / §10 — a measurement harness, not a gate: skipped unless the
//  runner is started with TEST_RUNNER_USAGE_PERF=1, and meant to be built
//  with optimization on (SWIFT_OPTIMIZATION_LEVEL=-O). It times, on the main
//  thread, the usage-daily paths that touch the disk:
//    * the whole-file read + decode of a usage file just under its 256 KB cap
//      (`SpikeRunStore.loadRuns`), and the longest main-thread stall of a real
//      upload batch over that file, which now decodes off the main thread;
//    * the launch seed's tail read of that file (32 KB, at most 8 decodes);
//    * the rollover a return from background after midnight runs inside the
//      foreground notification (its appends, below the cap);
//    * the compaction an append that crosses the cap runs — the worst case
//      for any flush, the rollover's included, is the two added.
//  The file is written through the real store with lines shaped like the
//  center's (one id per day, re-appended at each dirty flush). Results are
//  printed as one `USAGE_PERF` line per path: median and max over the trials.
//

import XCTest
import UIKit
@testable import Done

@MainActor
final class UsagePerfMeasurementTests: XCTestCase {
    private var scratch: [SpikeRunStorageLocation] = []

    override func tearDown() {
        for location in scratch { try? FileManager.default.removeItem(at: location.directory) }
        scratch = []
        super.tearDown()
    }

    private func ms(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    private func report(_ name: String, _ samples: [Double], extra: String = "") {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "USAGE_PERF %@ n=%d median=%.2fms max=%.2fms %@", name, sorted.count, median, sorted.last ?? 0, extra))
    }

    /// A usage line as the center writes it on a busy day: every visit key
    /// of the features used, a few dozen keys.
    private func dayMetrics(_ scale: Int) -> [String: SpikeMetricValue] {
        var metrics: [String: SpikeMetricValue] = ["sessions": .number(Double(10 + scale))]
        for key in UsageKey.all.prefix(40) where key.kind == .counter {
            metrics[key.name] = .number(Double(scale % 17 + 1))
        }
        for key in UsageKey.all where key.kind == .histogram {
            metrics[key.name] = .string("\(scale) \(scale * 2) \(scale % 5) 1")
        }
        return metrics
    }

    /// Fills `location`'s usage file with day records re-appended per flush
    /// until it is just under `targetBytes`; returns the last day's start.
    @discardableResult
    private func fill(_ location: SpikeRunStorageLocation, toBytes targetBytes: Int, start: Date) -> Date {
        let url = SpikeRunStore.fileURL(spikeID: UsageRecordIDs.spikeID, location: location)
        var day = 0
        var dayStart = start
        while true {
            dayStart = start.addingTimeInterval(Double(day) * 86_400)
            let id = UUID()
            for flush in 0..<40 {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if size >= targetBytes { return dayStart }
                var run = TelemetryFixtures.run(id: id, spikeID: UsageRecordIDs.spikeID, scenarioID: UsageRecordIDs.scenarioID,
                                                startedAt: dayStart, endedAt: dayStart.addingTimeInterval(Double(flush) * 600),
                                                appBuild: "31", metrics: dayMetrics(flush))
                run.dayKey = nil
                SpikeRunStore.finishRun(run, owner: .explicit(TelemetryFixtures.uid), location: location)
            }
            day += 1
        }
    }

    private func fileBytes(_ location: SpikeRunStorageLocation) -> Int {
        let url = SpikeRunStore.fileURL(spikeID: UsageRecordIDs.spikeID, location: location)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    func testMeasureTheUsageFilePaths() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["USAGE_PERF"] == "1", "measurement harness: run with TEST_RUNNER_USAGE_PERF=1")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let cap = SpikeRunStore.compactAtBytes

        // 1. The uploader's per-file read + decode, on a file just under the cap.
        let full = SpikeRunStorageLocation.ephemeral(id: UUID())
        scratch.append(full)
        fill(full, toBytes: cap - 4_096, start: start)
        let fullBytes = fileBytes(full)
        _ = SpikeRunStore.loadRuns(spikeID: UsageRecordIDs.spikeID, location: full)
        report("loadRuns(usage-daily)", (0..<25).map { _ in ms { _ = SpikeRunStore.loadRuns(spikeID: UsageRecordIDs.spikeID, location: full) } },
               extra: "bytes=\(fullBytes)")

        // 2. The launch seed's tail read: a hit on the last line, and a miss
        //    that spends its whole decode budget.
        let url = SpikeRunStore.fileURL(spikeID: UsageRecordIDs.spikeID, location: full)
        report("seedTail(hit)", (0..<25).map { _ in ms {
            _ = SpikeRunFileScan.newestMatch(in: url, maxBytes: ResidentObservationCenter.seedTailBytes,
                                             maxDecodes: ResidentObservationCenter.seedMaxDecodes) { _ in true }
        } })
        report("seedTail(miss, resident budget)", (0..<25).map { _ in ms {
            _ = SpikeRunFileScan.newestMatch(in: url, maxBytes: ResidentObservationCenter.seedTailBytes,
                                             maxDecodes: ResidentObservationCenter.seedMaxDecodes) { _ in false }
        } })
        report("seedTail(miss, usage budget)", (0..<25).map { _ in ms {
            _ = SpikeRunFileScan.newestMatch(in: url, maxBytes: ResidentObservationCenter.seedTailBytes,
                                             maxDecodes: ResidentObservationCenter.usageSeedMaxDecodes) { _ in false }
        } })

        // 3. The return after midnight: the foreground notification itself,
        //    and the rollover hop that runs after it.
        func rolloverTrial(fileBytes target: Int) -> (notification: Double, hop: Double) {
            let location = SpikeRunStorageLocation.ephemeral(id: UUID())
            scratch.append(location)
            fill(location, toBytes: target, start: start.addingTimeInterval(-40 * 86_400))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            var clock = calendar.date(bySettingHour: 23, minute: 50, second: 0, of: start)!
            let center = ResidentObservationCenter(
                coordinator: SpikeSessionCoordinator(), store: nil, location: location, calendar: calendar,
                now: { clock }, mediaNow: { 0 }, ownerUID: { TelemetryFixtures.uid },
                installsFollowerProbe: false, verifiesSeed: false, seedTrail: { _ in },
                countsLaunchSession: true, isAppForeground: { true }, availableGates: { [.focus] })
            center.activate()
            defer { center.deactivate() }
            UsageProbe.enter(.eventDetailCanvas)
            UsageProbe.use(.eventDetailPlan)
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            UsageProbe.use(.allDayToggle)       // counted but not yet written: the rollover writes it
            clock = clock.addingTimeInterval(20 * 60)
            let notification = ms { NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil) }
            let hop = ms { center.performRolloverFlushIfDue() }
            return (notification, hop)
        }
        let trials = (0..<15).map { _ in rolloverTrial(fileBytes: cap / 2) }
        report("foregroundNotification(after midnight)", trials.map(\.notification))
        report("rolloverHop", trials.map(\.hop))

        // 4. The compaction alone: one append that crosses the cap. The line
        //    carries every key, longer than the room left under the cap.
        var everyKey: [String: SpikeMetricValue] = [:]
        for key in UsageKey.all { everyKey[key.name] = key.kind == .histogram ? .string("1 2 3 4") : .number(7) }
        report("compaction(usage file at the cap)", (0..<8).map { _ in
            let location = SpikeRunStorageLocation.ephemeral(id: UUID())
            scratch.append(location)
            fill(location, toBytes: cap - 2_048, start: start)
            var run = TelemetryFixtures.run(spikeID: UsageRecordIDs.spikeID, scenarioID: UsageRecordIDs.scenarioID,
                                            startedAt: start.addingTimeInterval(400 * 86_400), endedAt: start.addingTimeInterval(400 * 86_400 + 60),
                                            appBuild: "31", metrics: everyKey)
            run.dayKey = nil
            let before = fileBytes(location)
            let elapsed = ms { SpikeRunStore.finishRun(run, owner: .explicit(TelemetryFixtures.uid), location: location) }
            XCTAssertLessThan(fileBytes(location), before, "the append did compact")
            return elapsed
        })

        // 5. A real upload batch over the full file: the longest gap between
        //    beats of a 1 ms main-queue heartbeat is the longest main-thread
        //    stall the batch caused. Two controls bracket it: the heartbeat
        //    with nothing running (its own noise), and the heartbeat around
        //    the on-main whole-file decode the batch used to run (a stall the
        //    instrument must see).
        func heartbeat(_ work: (@escaping () -> Void) -> Void) -> Double {
            var last = DispatchTime.now().uptimeNanoseconds
            var longest: UInt64 = 0
            let beat = Timer(timeInterval: 0.001, repeats: true) { _ in
                let t = DispatchTime.now().uptimeNanoseconds
                longest = max(longest, t - last)
                last = t
            }
            RunLoop.main.add(beat, forMode: .common)
            let done = expectation(description: "work")
            work { done.fulfill() }
            wait(for: [done], timeout: 30)
            beat.invalidate()
            return Double(longest) / 1e6
        }
        let idle = (0..<8).map { _ in heartbeat { finish in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
        } }
        report("heartbeat(idle control)", idle, extra: "all=\(idle.map { String(format: "%.1f", $0) })")
        let onMain = (0..<8).map { _ in heartbeat { finish in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                _ = SpikeRunStore.loadRuns(spikeID: UsageRecordIDs.spikeID, location: full)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { finish() }
            }
        } }
        report("heartbeat(on-main decode control)", onMain, extra: "all=\(onMain.map { String(format: "%.1f", $0) })")
        let suite = "UsagePerfMeasurementTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stalls: [Double] = []
        for _ in 0..<8 {
            let pool = SpikeRunStorageLocation.ephemeral(id: UUID())
            scratch.append(pool)
            fill(pool, toBytes: cap - 4_096, start: start)
            var deps = TelemetryUploader.Dependencies()
            deps.defaults = defaults
            deps.location = pool
            deps.now = { start.addingTimeInterval(500 * 86_400) }
            deps.launchDelay = 0
            deps.makeKeepAlive = { nil }
            deps.bootstrapOwner = { nil }
            let uploader = TelemetryUploader(dependencies: deps)
            uploader.attach(TelemetryUploader.Attachment(gateway: SyncFakeServer(userId: TelemetryFixtures.uid),
                                                         isBlockedByBuild: { false },
                                                         currentUserID: { TelemetryFixtures.uid }, isSignedIn: { true }))
            defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
            TelemetryConsentStore.recordGrant(defaults, at: start.addingTimeInterval(-86_400))
            stalls.append(heartbeat { finish in
                Task { @MainActor in
                    _ = await uploader.uploadNow(trigger: .launch)
                    finish()
                }
            })
        }
        report("uploadBatch(longest main-thread stall)", stalls,
               extra: "file=\(fullBytes)B all=\(stalls.map { String(format: "%.1f", $0) })")
    }
}
