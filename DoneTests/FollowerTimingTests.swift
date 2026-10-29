//
//  FollowerTimingTests.swift
//  DoneTests
//
//  perf batch 2a — the follower timing probe's pure half and its recorder,
//  on a manual clock: accumulation, exclusive nesting and its overflow, the
//  frame attribution, the gating, the record keys against the registry, the
//  trail line, and the per-call overhead.
//
//  Every recorder test is synchronous on purpose. The recorder is installed
//  process-wide (`FollowerTiming.recorder`) and DoneTests runs inside the
//  host app, whose own followers run on the same main thread; a test that
//  never yields leaves them no turn to run in.
//

import QuartzCore
import XCTest
@testable import Done

/// A clock the test moves by hand, in nanoseconds.
final class FollowerManualClock {
    var ns: UInt64

    init(ns: UInt64 = 1_000_000_000) {
        self.ns = ns
    }

    func advance(ms: Double) {
        ns += UInt64((ms * 1e6).rounded())
    }

    func set(ms: Double) {
        ns = UInt64((ms * 1e6).rounded())
    }
}

@MainActor
final class FollowerTimingRecorderTests: XCTestCase {
    private var clock: FollowerManualClock!
    private var recorder: FollowerTimingRecorder!
    private var displaced: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        clock = FollowerManualClock()
        let clock = clock!
        recorder = FollowerTimingRecorder(now: { clock.ns }, isForeground: true)
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = recorder
    }

    override func tearDown() {
        FollowerTiming.recorder = displaced
        recorder = nil
        clock = nil
        super.tearDown()
    }

    private func ns(_ ms: Double) -> UInt64 { UInt64((ms * 1e6).rounded()) }

    private func run(_ id: FollowerID, ms: Double) {
        FollowerTiming.measure(id) { clock.advance(ms: ms) }
    }

    // MARK: Accumulation

    func testARunIsChargedToTheDayAndToTheOpenWindowWithItsDuration() throws {
        recorder.armWindow()
        run(.syncCalendarHash, ms: 5)
        let day = recorder.dailySnapshot()
        XCTAssertEqual(day[.syncCalendarHash], FollowerStat(count: 1, totalNs: ns(5), maxNs: ns(5)))
        let window = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertEqual(window.table[.syncCalendarHash], FollowerStat(count: 1, totalNs: ns(5), maxNs: ns(5)))
        XCTAssertEqual(day.totalRuns, 1, "nothing else was charged")
    }

    func testTotalsSumTheRunsAndMaxIsTheLongestSingleRun() {
        for ms in [3.0, 7.0, 2.0] { run(.occurrenceBatch, ms: ms) }
        XCTAssertEqual(recorder.dailySnapshot()[.occurrenceBatch], FollowerStat(count: 3, totalNs: ns(12), maxNs: ns(7)))
    }

    func testMeasureReturnsTheBodysValue() {
        let value = FollowerTiming.measure(.widgetSnapshot) { () -> Int in
            clock.advance(ms: 1)
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    // MARK: Nesting

    /// Exclusive accounting: each run is charged only its own time, so the
    /// followers never sum to more than the wall time they covered.
    func testNestedRunsAreChargedExclusivelyAndSumToTheWallTime() {
        let start = clock.ns
        FollowerTiming.measure(.syncCalendarBuild) {
            clock.advance(ms: 2)
            FollowerTiming.measure(.occurrenceSync) {
                clock.advance(ms: 4)
                FollowerTiming.measure(.widgetSnapshot) { clock.advance(ms: 1) }
                clock.advance(ms: 0.5)
            }
            clock.advance(ms: 3)
        }
        let wall = clock.ns - start
        let day = recorder.dailySnapshot()
        XCTAssertEqual(day[.syncCalendarBuild].totalNs, ns(5), "2 + 3, the inner 5.5 excluded")
        XCTAssertEqual(day[.occurrenceSync].totalNs, ns(4.5), "4 + 0.5, the inner 1 excluded")
        XCTAssertEqual(day[.widgetSnapshot].totalNs, ns(1))
        XCTAssertEqual(day.stats.reduce(0) { $0 + $1.totalNs }, wall, "exclusive times sum to the wall time")
        XCTAssertEqual(recorder.dailyOverflow, 0)
    }

    /// Past the fixed stack a run is charged inclusive time and counted, and
    /// the stack is whole again afterwards.
    func testNestingPastTheStackIsCountedAsOverflowAndTheStackRecovers() throws {
        let levels = FollowerTimingRecorder.maxDepth + 2
        recorder.armWindow()
        func nest(_ remaining: Int) {
            guard remaining > 0 else { return }
            FollowerTiming.measure(.imageScan) {
                clock.advance(ms: 1)
                nest(remaining - 1)
            }
        }
        nest(levels)
        XCTAssertEqual(recorder.dailyOverflow, 2, "the two levels past the stack")
        let window = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertEqual(window.dropped, 2)
        XCTAssertEqual(window.table[.imageScan].count, levels, "every level is still a run")

        // The stack recovered: a plain nested pair is exact again.
        FollowerTiming.measure(.colorDepthMirror) {
            clock.advance(ms: 2)
            FollowerTiming.measure(.wristSnapshot) { clock.advance(ms: 3) }
        }
        let day = recorder.dailySnapshot()
        XCTAssertEqual(day[.colorDepthMirror].totalNs, ns(2))
        XCTAssertEqual(day[.wristSnapshot].totalNs, ns(3))
        XCTAssertEqual(recorder.dailyOverflow, 2, "no new overflow")
    }

    private struct Boom: Error {}

    func testAThrowingBodyStillClosesItsSpan() {
        XCTAssertThrowsError(try FollowerTiming.measure(.snapshotWrite) { () throws -> Void in
            clock.advance(ms: 4)
            throw Boom()
        })
        XCTAssertEqual(recorder.dailySnapshot()[.snapshotWrite], FollowerStat(count: 1, totalNs: ns(4), maxNs: ns(4)))
        // Depth back at zero: an outer run after it is not charged as a child.
        FollowerTiming.measure(.snapshotDigest) { clock.advance(ms: 6) }
        XCTAssertEqual(recorder.dailySnapshot()[.snapshotDigest].totalNs, ns(6))
    }

    func testABeginEndSpanIsARunLikeMeasure() {
        let span = FollowerTiming.begin()
        clock.advance(ms: 9)
        FollowerTiming.end(.syncSettings, span)
        XCTAssertEqual(recorder.dailySnapshot()[.syncSettings], FollowerStat(count: 1, totalNs: ns(9), maxNs: ns(9)))
    }

    // MARK: Overflow of the numbers themselves

    func testATotalSaturatesInsteadOfWrapping() {
        var stat = FollowerStat()
        stat.add(UInt64.max - 5)
        stat.add(10)
        XCTAssertEqual(stat.totalNs, .max)
        XCTAssertEqual(stat.count, 2)
        XCTAssertEqual(stat.maxNs, UInt64.max - 5)
    }

    func testAClockThatStepsBackwardsChargesZeroNotAWrap() {
        FollowerTiming.measure(.widgetSnapshot) { clock.ns -= 1_000 }
        XCTAssertEqual(recorder.dailySnapshot()[.widgetSnapshot], FollowerStat(count: 1, totalNs: 0, maxNs: 0))
    }

    // MARK: Gating

    /// Probe off: `measure` runs the body and touches no recorder — not even
    /// one that is armed and in the foreground.
    func testWithNoRecorderInstalledNothingIsRecorded() {
        FollowerTiming.recorder = nil
        recorder.armWindow()
        let value = FollowerTiming.measure(.syncLogsHash) { () -> String in
            clock.advance(ms: 5)
            return "ran"
        }
        XCTAssertEqual(value, "ran", "the body still runs")
        XCTAssertTrue(recorder.dailySnapshot().isEmpty)
        XCTAssertEqual(recorder.disarmWindow()?.table.isEmpty, true)
        // Positive control: installed again, the same call records.
        FollowerTiming.recorder = recorder
        run(.syncLogsHash, ms: 5)
        XCTAssertEqual(recorder.dailySnapshot()[.syncLogsHash].count, 1)
    }

    func testOutOfTheForegroundTheDayIsNotChargedAndWithoutAWindowNothingIs() {
        recorder.isForeground = false
        run(.snapshotWrite, ms: 30)
        XCTAssertTrue(recorder.dailySnapshot().isEmpty, "background work is not the foreground day's")
        XCTAssertNil(recorder.disarmWindow(), "no window was armed")

        recorder.armWindow()
        run(.snapshotWrite, ms: 30)
        XCTAssertTrue(recorder.dailySnapshot().isEmpty)
        XCTAssertEqual(recorder.disarmWindow()?.table[.snapshotWrite].count, 1, "an armed window still sees it")

        recorder.isForeground = true
        run(.snapshotWrite, ms: 30)
        XCTAssertEqual(recorder.dailySnapshot()[.snapshotWrite].count, 1, "positive control: the foreground day does")
    }

    func testAWindowCollectsOnlyBetweenArmAndDisarm() throws {
        run(.colorDepthMirror, ms: 1)
        recorder.armWindow()
        run(.colorDepthMirror, ms: 2)
        let window = try XCTUnwrap(recorder.disarmWindow())
        run(.colorDepthMirror, ms: 4)
        XCTAssertEqual(window.table[.colorDepthMirror], FollowerStat(count: 1, totalNs: ns(2), maxNs: ns(2)))
        XCTAssertEqual(recorder.dailySnapshot()[.colorDepthMirror].count, 3, "the day saw all three")
        XCTAssertNil(recorder.disarmWindow(), "disarmed once")

        recorder.armWindow()
        XCTAssertEqual(recorder.disarmWindow()?.table.isEmpty, true, "a re-armed window starts empty")
    }

    // MARK: Largest-frame attribution

    func testARunInsideTheLargestFrameIsChargedToIt() throws {
        recorder.armWindow()
        recorder.noteFrameTick(atNs: ns(100))
        clock.set(ms: 105)
        run(.syncCalendarHash, ms: 30)          // 105…135
        recorder.noteFrameTick(atNs: ns(140))   // frame 100…140
        recorder.noteFrameTick(atNs: ns(148))   // a short frame
        let window = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertEqual(window.maxFrameNs, ns(40))
        XCTAssertEqual(window.inMaxFrameNs[FollowerID.syncCalendarHash.rawValue], ns(30))
        XCTAssertEqual(window.topInMaxFrame, .syncCalendarHash)
    }

    /// A run that ends after the frame's vsync timestamp (the callback could
    /// not run until it finished) is clipped to the frame; its remainder is
    /// carried into the next frame.
    func testARunPastTheTickIsClippedAndItsRemainderCarried() throws {
        recorder.armWindow()
        recorder.noteFrameTick(atNs: ns(100))
        clock.set(ms: 110)
        run(.occurrenceSync, ms: 40)            // 110…150
        recorder.noteFrameTick(atNs: ns(140))   // frame 100…140 holds 30 of it
        let clipped = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertEqual(clipped.maxFrameNs, ns(40))
        XCTAssertEqual(clipped.inMaxFrameNs[FollowerID.occurrenceSync.rawValue], ns(30), "clipped at the tick")

        recorder.armWindow()
        recorder.noteFrameTick(atNs: ns(100))
        clock.set(ms: 110)
        run(.occurrenceSync, ms: 40)
        recorder.noteFrameTick(atNs: ns(140))
        recorder.noteFrameTick(atNs: ns(200))   // frame 140…200 is larger and holds the carried 10
        let carried = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertEqual(carried.maxFrameNs, ns(60))
        XCTAssertEqual(carried.inMaxFrameNs[FollowerID.occurrenceSync.rawValue], ns(10), "the remainder past the tick")
    }

    func testASmallerLaterFrameDoesNotReplaceTheLargest() throws {
        recorder.armWindow()
        recorder.noteFrameTick(atNs: ns(0) + 1)
        clock.set(ms: 10)
        run(.snapshotDigest, ms: 50)            // 10…60
        recorder.noteFrameTick(atNs: ns(80))    // largest: 80
        clock.set(ms: 85)
        run(.widgetSnapshot, ms: 5)             // 85…90
        recorder.noteFrameTick(atNs: ns(100))   // 20, smaller
        let window = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertEqual(window.maxFrameNs, ns(80) - 1)
        XCTAssertEqual(window.inMaxFrameNs[FollowerID.snapshotDigest.rawValue], ns(50))
        XCTAssertEqual(window.inMaxFrameNs[FollowerID.widgetSnapshot.rawValue], 0, "its frame was not the largest")
        XCTAssertEqual(window.table[.widgetSnapshot].count, 1, "it still counts as a window run")
    }

    func testWithFewerThanTwoTicksThereIsNoLargestFrame() throws {
        recorder.armWindow()
        run(.wristSnapshot, ms: 3)
        recorder.noteFrameTick(atNs: clock.ns + 1)
        let window = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertNil(window.maxFrameNs)
        let metrics = window.metrics()
        XCTAssertNil(metrics[FollowerWindowResult.maxFrameKey])
        XCTAssertNil(metrics[FollowerWindowResult.windowInMaxFrameKey(.wristSnapshot)])
        XCTAssertEqual(metrics[FollowerWindowResult.windowCountKey(.wristSnapshot)], .number(1))
    }

    func testATickThatDoesNotMoveForwardIsIgnored() throws {
        recorder.armWindow()
        recorder.noteFrameTick(atNs: ns(100))
        recorder.noteFrameTick(atNs: ns(100))
        recorder.noteFrameTick(atNs: ns(90))
        let window = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertNil(window.maxFrameNs, "no forward step, no frame")
    }

    /// More runs in one frame than the fixed buffer holds: the excess is
    /// counted, never silently attributed, and every run still counts.
    func testRunsPastTheFrameBufferAreCountedAsDropped() throws {
        let runs = FollowerTimingRecorder.frameRunCapacity + 3
        recorder.armWindow()
        recorder.noteFrameTick(atNs: clock.ns)
        for _ in 0..<runs { run(.occurrenceBatch, ms: 1) }
        recorder.noteFrameTick(atNs: clock.ns + 1)
        let window = try XCTUnwrap(recorder.disarmWindow())
        XCTAssertEqual(window.dropped, 3)
        XCTAssertEqual(window.table[.occurrenceBatch].count, runs)
        XCTAssertEqual(window.inMaxFrameNs[FollowerID.occurrenceBatch.rawValue],
                       ns(Double(FollowerTimingRecorder.frameRunCapacity)), "only the placed runs")
        XCTAssertEqual(window.metrics()[FollowerWindowResult.droppedKey], .number(3))
    }

    /// The two clocks the attribution compares really are one timebase.
    func testTheSpanClockAndTheMediaClockAgree() {
        let media = FollowerClock.nanoseconds(fromMediaSeconds: CACurrentMediaTime())
        let span = FollowerClock.now()
        let gap = media > span ? media - span : span - media
        XCTAssertLessThan(gap, 1_000_000, "CACurrentMediaTime and CLOCK_UPTIME_RAW within a millisecond")
    }
}

// MARK: - Records, registry and trail (pure)

@MainActor
final class FollowerTimingRecordTests: XCTestCase {
    private func ns(_ ms: Double) -> UInt64 { UInt64((ms * 1e6).rounded()) }

    private func table(_ entries: [(FollowerID, [Double])]) -> FollowerStatTable {
        var table = FollowerStatTable()
        for (id, runs) in entries {
            for ms in runs { table.add(id, ns: ns(ms)) }
        }
        return table
    }

    func testTheDailyMetricsCarryEveryFollowerZeroIncludedAndRoundTrip() {
        let day = table([(.syncCalendarHash, [12.34, 0.01]), (.snapshotWrite, [230.5])])
        let metrics = day.dailyMetrics(overflow: 2)
        XCTAssertEqual(Set(metrics.keys), Set(FollowerStatTable.dailyKeys))
        XCTAssertEqual(metrics.count, FollowerID.allCases.count * 3 + 1)
        XCTAssertEqual(metrics["fl.syncCal.hash.n"], .number(2))
        XCTAssertEqual(metrics["fl.syncCal.hash.ms"], .number(12.35))
        XCTAssertEqual(metrics["fl.syncCal.hash.maxMs"], .number(12.34))
        XCTAssertEqual(metrics["fl.snap.write.ms"], .number(230.5))
        XCTAssertEqual(metrics["fl.mirror.n"], .number(0), "zero is written, not left out")
        XCTAssertEqual(metrics[FollowerStatTable.dailyOverflowKey], .number(2))

        XCTAssertEqual(FollowerStatTable(dailyMetrics: metrics), day, "the relaunch seed reads back what was written")
        XCTAssertEqual(FollowerStatTable.dailyOverflow(in: metrics), 2)
    }

    func testTheSeedIgnoresUnknownKeysAndReadsMissingOnesAsZero() {
        let seeded = FollowerStatTable(dailyMetrics: [
            "fl.mirror.n": .number(3), "fl.mirror.ms": .number(1.5), "fl.mirror.maxMs": .number(0.75),
            "fl.bogus.n": .number(99), "fl.widget.n": .string("7"), "tapCount": .number(5),
        ])
        XCTAssertEqual(seeded[.colorDepthMirror], FollowerStat(count: 3, totalNs: ns(1.5), maxNs: ns(0.75)))
        XCTAssertEqual(seeded.totalRuns, 3, "nothing else came in")
    }

    func testTheWindowMetricsCarryOnlyFollowersThatRanAndTheFrameKeysOnlyWithAFrame() {
        var inMax = Array(repeating: UInt64(0), count: FollowerID.allCases.count)
        inMax[FollowerID.syncLogsHash.rawValue] = ns(20)
        let framed = FollowerWindowResult(table: table([(.syncLogsHash, [25, 5])]), inMaxFrameNs: inMax,
                                          maxFrameNs: ns(132), dropped: 0)
        XCTAssertEqual(framed.metrics(), [
            "wfl.runs": .number(2),
            "wfl.syncLog.hash.n": .number(2),
            "wfl.syncLog.hash.ms": .number(30),
            "wfl.syncLog.hash.maxMs": .number(25),
            "wfl.syncLog.hash.inMaxFrameMs": .number(20),
            "wfl.maxFrameMs": .number(132),
            "wfl.inMaxFrameMs": .number(20),
        ])
        let empty = FollowerWindowResult(table: FollowerStatTable(), inMaxFrameNs: inMax.map { _ in 0 },
                                         maxFrameNs: nil, dropped: 0)
        XCTAssertEqual(empty.metrics(), ["wfl.runs": .number(0)], "an armed window with no follower says so")
    }

    func testEveryKeyAWindowCanCarryIsInTheVocabulary() {
        let inMax = Array(repeating: UInt64(1), count: FollowerID.allCases.count)
        let everything = FollowerWindowResult(
            table: table(FollowerID.allCases.map { ($0, [1]) }), inMaxFrameNs: inMax, maxFrameNs: ns(50), dropped: 1)
        let keys = Set(everything.metrics().keys)
        XCTAssertEqual(keys, Set(FollowerWindowResult.allKeys), "all of them, and nothing outside them")
    }

    // MARK: Registry (wire contract §4)

    private struct RegistryEntry: Decodable {
        let key: String
        let kind: String
        let family: String
        let value_schema: String
        let spike_id: String
    }

    private func registry() throws -> [String: RegistryEntry] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("done-mcp/supabase/telemetry/key_registry.json")
        let entries = try JSONDecoder().decode([RegistryEntry].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
    }

    /// Every follower key is registered under the spike whose record carries
    /// it, as a numeric gauge (report-only: kept out of `counter_long`), and
    /// the registry holds no follower key the client cannot write.
    func testEveryFollowerKeyIsRegisteredAsANumericGaugeOfItsRecordsSpike() throws {
        let registry = try registry()
        var violations: [String] = []
        let expected = FollowerStatTable.dailyKeys.map { ($0, FixObservationRegistry.residentDailySpikeID) }
            + FollowerWindowResult.allKeys.map { ($0, FixObservationRegistry.effortPathFixID) }
        for (key, spike) in expected {
            guard let entry = registry[key] else { violations.append("\(key) unregistered"); continue }
            if entry.spike_id != spike { violations.append("\(key) spike \(entry.spike_id)") }
            if entry.kind != "gauge" || entry.value_schema != "number" { violations.append("\(key) \(entry.kind)/\(entry.value_schema)") }
            if entry.family != "fixwatch" { violations.append("\(key) family \(entry.family)") }
        }
        let registeredFollowerKeys = Set(registry.keys.filter { $0.hasPrefix("fl.") || $0.hasPrefix("wfl.") })
        let writable = Set(expected.map(\.0))
        for stray in registeredFollowerKeys.subtracting(writable) { violations.append("\(stray) registered but never written") }
        XCTAssertEqual(violations.sorted(), [])
        XCTAssertEqual(registeredFollowerKeys.count, writable.count)
    }

    // MARK: Trail line

    func testTheTrailLineNamesTheWindowAndEveryGroup() throws {
        var inMax = Array(repeating: UInt64(0), count: FollowerID.allCases.count)
        inMax[FollowerID.syncCalendarHash.rawValue] = ns(80)
        inMax[FollowerID.occurrenceSync.rawValue] = ns(18.5)
        let result = FollowerWindowResult(
            table: table([(.syncCalendarBuild, [20]), (.syncCalendarHash, [100]), (.syncLogsBaseline, [2.5, 2.5]),
                          (.occurrenceSync, [22]), (.occurrenceBatch, [3, 3, 3]), (.snapshotDigest, [99]),
                          (.colorDepthMirror, [4])]),
            inMaxFrameNs: inMax, maxFrameNs: ns(132), dropped: 0)
        let id = try XCTUnwrap(UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000000"))
        XCTAssertEqual(result.trailLine(windowID: id),
                       "followers: window=1a2b3c4d sync=125.00ms/4 occ=31.00ms/4 snap=99.00ms/1 mirror=4.00ms/1 "
                       + "widget=0.00ms/0 wrist=0.00ms/0 img=0.00ms/0 snapW=0 maxFrame=132.00ms inMax=98.50ms(syncCal.hash) dropped=0")
        let unframed = FollowerWindowResult(table: FollowerStatTable(), inMaxFrameNs: inMax.map { _ in 0 },
                                            maxFrameNs: nil, dropped: 2)
        XCTAssertTrue(unframed.trailLine(windowID: id).hasSuffix("snapW=0 maxFrame=- inMax=- dropped=2"))
    }

    // MARK: Observatory readout

    func testTheReportSumsArmedWindowsAndReadsTodaysDailyLargestFirst() {
        func window(_ metrics: [String: SpikeMetricValue]) -> SpikeRun {
            TelemetryFixtures.run(spikeID: FixObservationRegistry.effortPathFixID,
                                  scenarioID: FixObservationRegistry.windowScenarioID, metrics: metrics, kind: .window)
        }
        let a = window(["wfl.runs": .number(3), "wfl.syncCal.hash.n": .number(1), "wfl.syncCal.hash.ms": .number(100),
                        "wfl.syncCal.hash.maxMs": .number(100), "wfl.syncCal.hash.inMaxFrameMs": .number(80),
                        "wfl.occ.sync.n": .number(2), "wfl.occ.sync.ms": .number(40), "wfl.occ.sync.maxMs": .number(30),
                        "wfl.maxFrameMs": .number(132), "wfl.inMaxFrameMs": .number(80)])
        let b = window(["wfl.runs": .number(1), "wfl.syncCal.hash.n": .number(1), "wfl.syncCal.hash.ms": .number(90),
                        "wfl.syncCal.hash.maxMs": .number(90), "wfl.maxFrameMs": .number(60), "wfl.inMaxFrameMs": .number(0)])
        let olderBuild = window(["wTaps": .number(1)])
        let today = TelemetryFixtures.run(metrics: FollowerStatTable().dailyMetrics(overflow: 0).merging(
            ["fl.snap.digest.n": .number(4), "fl.snap.digest.ms": .number(400), "fl.snap.digest.maxMs": .number(110),
             "fl.mirror.n": .number(2), "fl.mirror.ms": .number(6), "fl.mirror.maxMs": .number(4)]) { _, new in new })
        let summary = FollowerReport.summarize(windows: [a, b, olderBuild], today: today)
        XCTAssertEqual(summary.windowCount, 2, "a window from a build without the probe is not counted")
        XCTAssertEqual(summary.windowRows, [
            FollowerReport.Row(id: "syncCal.hash", runs: 2, totalMs: 190, maxMs: 100, inMaxFrameMs: 80),
            FollowerReport.Row(id: "occ.sync", runs: 2, totalMs: 40, maxMs: 30, inMaxFrameMs: 0),
        ])
        XCTAssertEqual(summary.largestFrameMs, 132)
        XCTAssertEqual(summary.inLargestFramesMs, 80)
        XCTAssertEqual(summary.todayRows, [
            FollowerReport.Row(id: "snap.digest", runs: 4, totalMs: 400, maxMs: 110, inMaxFrameMs: nil),
            FollowerReport.Row(id: "mirror", runs: 2, totalMs: 6, maxMs: 4, inMaxFrameMs: nil),
        ])
        XCTAssertEqual(FollowerReport.summarize(windows: [], today: nil),
                       FollowerReport.Summary(windowCount: 0, windowRows: [], largestFrameMs: nil,
                                              inLargestFramesMs: nil, todayRows: []))
    }
}

// MARK: - Overhead

/// The cost of one `measure` call, against the bare body. Reported as a
/// number in the log line and bounded loosely: the claim is "microseconds,
/// nothing allocated per call", and an allocation or a lock would show up
/// as a multiple of this bound.
@MainActor
final class FollowerTimingOverheadTests: XCTestCase {
    private var displaced: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        displaced = FollowerTiming.recorder
    }

    override func tearDown() {
        FollowerTiming.recorder = displaced
        super.tearDown()
    }

    private func nsPerCall(_ iterations: Int, _ body: () -> Void) -> Double {
        let start = FollowerClock.now()
        body()
        return Double(FollowerClock.now() - start) / Double(iterations)
    }

    func testOneMeasureCallCostsWellUnderAMicrosecond() {
        let iterations = 200_000
        var sink = 0
        // Warm up both paths.
        let recorder = FollowerTimingRecorder(isForeground: true)
        recorder.armWindow()
        FollowerTiming.recorder = recorder
        for _ in 0..<1_000 { FollowerTiming.measure(.widgetSnapshot) { sink &+= 1 } }

        FollowerTiming.recorder = nil
        let body: () -> Void = { sink &+= 1 }
        let bare = nsPerCall(iterations) {
            for _ in 0..<iterations { body() }
        }
        let off = nsPerCall(iterations) {
            for _ in 0..<iterations { FollowerTiming.measure(.widgetSnapshot) { sink &+= 1 } }
        }
        FollowerTiming.recorder = recorder
        let onWindow = nsPerCall(iterations) {
            for _ in 0..<iterations { FollowerTiming.measure(.widgetSnapshot) { sink &+= 1 } }
        }
        _ = recorder.disarmWindow()
        let onDay = nsPerCall(iterations) {
            for _ in 0..<iterations { FollowerTiming.measure(.widgetSnapshot) { sink &+= 1 } }
        }
        // Ticks while armed, with a full frame buffer to place each time.
        recorder.armWindow()
        var tick = FollowerClock.now()
        let tickCost = nsPerCall(iterations / 10) {
            for _ in 0..<(iterations / 10) {
                FollowerTiming.measure(.widgetSnapshot) { sink &+= 1 }
                tick &+= 8_333_333
                recorder.noteFrameTick(atNs: tick)
            }
        }
        _ = recorder.disarmWindow()
        FollowerTiming.recorder = nil

        let line = String(format: "follower overhead: bare=%.1fns off=%.1fns day=%.1fns window=%.1fns measure+tick=%.1fns per call",
                          bare, off, onDay, onWindow, tickCost)
        print(line)
        DiagnosticTrail.record("PerfBatch2", line)
        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(onWindow, 1_000, line)
        XCTAssertLessThan(onDay, 1_000, line)
        XCTAssertLessThan(tickCost, 2_000, line)
        XCTAssertLessThan(off, 200, line)
    }
}
