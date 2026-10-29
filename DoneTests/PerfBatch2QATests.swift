//
//  PerfBatch2QATests.swift
//  DoneTests
//
//  Independent QA for perf batch 2a: the follower timing probe and gh#282
//  (token inference off). Tests only; no production file is touched.
//
//  What these pin that the batch's own suites leave open:
//    * the measure hot path allocates nothing on the main thread, counted
//      through libmalloc's `malloc_logger`, with positive controls that
//      allocate once per call;
//    * no frame probe (no display link) runs while no window is open, and
//      the one a window starts stops ticking at the close;
//    * with a REAL display link, a blocking run inside a window is charged
//      to exactly its follower and placed in the window's largest frame;
//    * a same-day owner change starts the day's followers over (the third
//      reset site; midnight and the consent re-mint are pinned upstream);
//    * the observatory's verdicts read the same with and without follower
//      keys on the records, however large their values;
//    * gh#282: foreground / active edges create no coordinator, and no app
//      source constructs one.
//

import Darwin
import QuartzCore
import UIKit
import XCTest
@testable import Done

// MARK: - A main-thread allocation counter

/// Counts allocations made on the MAIN thread while `count` runs its body,
/// through libmalloc's `malloc_logger` hook. The hook runs for every
/// malloc-family call on every thread, so it must not allocate itself: it
/// reads the thread and bumps one pre-allocated integer.
enum QAMainThreadMallocCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` in <malloc/malloc.h>'s logger contract.
    static let allocateFlag: UInt32 = 2

    static let counter: UnsafeMutablePointer<Int> = {
        let pointer = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return pointer
    }()

    static let hook: Logger = { type, _, _, _, _, _ in
        if type & QAMainThreadMallocCounter.allocateFlag != 0, pthread_main_np() != 0 {
            QAMainThreadMallocCounter.counter.pointee &+= 1
        }
    }

    /// nil when the hook cannot be found (the count would be meaningless).
    static func count(_ body: () -> Void) -> Int? {
        // RTLD_DEFAULT: search every loaded image.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Optional<Logger>.self)
        _ = counter.pointee        // initialise the lazy globals before arming
        let hook = Self.hook
        let previous = slot.pointee
        counter.pointee = 0
        slot.pointee = hook
        body()
        slot.pointee = previous
        return counter.pointee
    }
}

private final class QABox {
    let value: Int
    init(_ value: Int) { self.value = value }
}

@MainActor
final class PerfBatch2QAAllocationTests: XCTestCase {
    private var displaced: FollowerTimingRecorder?
    private let iterations = 20_000
    private var sink = 0

    override func setUp() {
        super.setUp()
        displaced = FollowerTiming.recorder
    }

    override func tearDown() {
        FollowerTiming.recorder = displaced
        super.tearDown()
    }

    /// Main-thread allocations the body made beyond the same loop with no
    /// call under test. Every body keeps its counters in locals declared
    /// inside it: a Debug test loop pays an allocation per iteration of its
    /// own, and more per captured variable it touches.
    private func counted(_ label: String, _ body: () -> Int) throws -> Int {
        let n = iterations
        var total = 0
        let baseline = try XCTUnwrap(QAMainThreadMallocCounter.count {
            var local = 0
            for _ in 0..<n { local &+= 1 }
            total &+= local
        }, "malloc_logger is not reachable")
        let count = try XCTUnwrap(QAMainThreadMallocCounter.count { total &+= body() })
        sink &+= total
        let line = "PerfBatch2QA alloc \(label): \(count - baseline) beyond the bare loop's \(baseline), over \(n) iterations"
        print(line)
        DiagnosticTrail.record("PerfBatch2QA", line)
        return count - baseline
    }

    /// Positive controls: the counter sees one allocation per iteration from
    /// a raw malloc, a Swift object, and a dictionary keyed by a built
    /// string (the per-call shape the probe's cost contract rules out).
    func testPositiveControlTheCounterSeesPerCallAllocations() throws {
        let n = iterations
        let raw = try counted("control raw malloc") {
            var local = 0
            for _ in 0..<n {
                let pointer = malloc(32)
                local &+= pointer == nil ? 0 : 1
                free(pointer)
            }
            return local
        }
        let object = try counted("control Swift object") {
            var local = 0
            for index in 0..<n { local &+= QABox(index).value & 1 }
            return local
        }
        let keyed = try counted("control keyed dictionary") {
            var local = 0
            for index in 0..<n {
                var metrics: [String: Double] = [:]
                metrics[FollowerWindowResult.windowTotalKey(.widgetSnapshot) + "\(index)"] = 1
                local &+= metrics.count
            }
            return local
        }
        XCTAssertGreaterThan(sink, 0)
        XCTAssertGreaterThanOrEqual(raw, n, "the hook sees raw malloc")
        XCTAssertGreaterThanOrEqual(object, n, "the hook sees Swift object allocation")
        XCTAssertGreaterThanOrEqual(keyed, n, "the hook sees a per-call dictionary")
    }

    func testMeasureAndTheFrameTickAllocateNothingPerCall() throws {
        let n = iterations
        let recorder = FollowerTimingRecorder(isForeground: true)
        FollowerTiming.recorder = recorder
        // Warm every path once, outside the count.
        recorder.armWindow()
        FollowerTiming.measure(.widgetSnapshot) {}
        let warmSpan = FollowerTiming.begin()
        FollowerTiming.end(.syncSettings, warmSpan)
        recorder.noteFrameTick(atNs: FollowerClock.now())
        recorder.noteFrameTick(atNs: FollowerClock.now() &+ 1)
        _ = recorder.disarmWindow()

        let day = try counted("measure, day only") {
            var local = 0
            for _ in 0..<n { FollowerTiming.measure(.widgetSnapshot) { local &+= 1 } }
            return local
        }
        recorder.armWindow()
        let window = try counted("measure, window armed") {
            var local = 0
            for _ in 0..<n { FollowerTiming.measure(.occurrenceBatch) { local &+= 1 } }
            return local
        }
        let nested = try counted("measure, nested two deep") {
            var local = 0
            for _ in 0..<n {
                FollowerTiming.measure(.colorDepthMirror) {
                    FollowerTiming.measure(.occurrenceSync) { local &+= 1 }
                }
            }
            return local
        }
        let beginEnd = try counted("begin/end span") {
            var local = 0
            for _ in 0..<n {
                let span = FollowerTiming.begin()
                local &+= 1
                FollowerTiming.end(.syncCalendarBaseline, span)
            }
            return local
        }
        let withTicks = try counted("measure + frame tick, one run per frame") {
            var local = 0
            var tick = FollowerClock.now()
            for _ in 0..<n {
                FollowerTiming.measure(.syncCalendarHash) { local &+= 1 }
                tick &+= 8_333_333
                recorder.noteFrameTick(atNs: tick)
            }
            return local
        }
        _ = recorder.disarmWindow()
        FollowerTiming.recorder = nil
        let off = try counted("measure, no recorder") {
            var local = 0
            for _ in 0..<n { FollowerTiming.measure(.imageScan) { local &+= 1 } }
            return local
        }
        XCTAssertGreaterThan(sink, 0)
        // A per-call allocation would read as at least `n` (see the positive
        // control). The measure paths are expected at zero. The tick walks
        // its pending runs with a for-in over a range, which in an
        // unoptimized build costs an allocation per iteration exactly like
        // the bare loop above (an optimized build of the same file counts
        // zero); so here the tick is bounded by one per placed run plus the
        // one-off table resets, which still catches anything built per tick.
        for (label, count) in [("day", day), ("window", window), ("nested", nested),
                               ("begin/end", beginEnd), ("off", off)] {
            XCTAssertLessThanOrEqual(count, 2, "\(label): \(count) allocations beyond the loop over \(n) calls")
        }
        XCTAssertLessThanOrEqual(withTicks, n + n / 50, "ticks: \(withTicks) allocations beyond the loop over \(n) ticks")
    }
}

// MARK: - Resident center: idle cost, a real display link, the owner reset

@MainActor
final class PerfBatch2QACenterTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var centers: [ResidentObservationCenter] = []
    private var displaced: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        for center in centers { center.deactivate() }
        centers = []
        FollowerTiming.recorder = displaced
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        coordinator = nil
        location = nil
        super.tearDown()
    }

    private func makeCenter(
        ownerUID: @escaping () -> String? = { nil },
        followerClock: @escaping () -> UInt64 = FollowerClock.now,
        makeFrameProbe: @escaping @MainActor () -> SpikeFrameProbe = { SpikeFrameProbe() }
    ) -> ResidentObservationCenter {
        let center = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            makeFrameProbe: makeFrameProbe, ownerUID: ownerUID,
            followerClock: followerClock, installsFollowerProbe: true, isAppActive: { true }
        )
        centers.append(center)
        return center
    }

    private func emitTap() {
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .ended, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0))
    }

    /// Runs the main run loop (display link callbacks included).
    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func busyWait(ms: Double) {
        let end = FollowerClock.now() + UInt64(ms * 1e6)
        while FollowerClock.now() < end {}
    }

    private func windows() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location)
    }

    private func dailies() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    private func number(_ run: SpikeRun, _ key: String) -> Double? {
        if case .number(let value)? = run.metrics[key] { return value }
        return nil
    }

    // MARK: Idle cost

    /// With the probe installed and no window open, nothing ticks: no frame
    /// probe is made, the recorder is not armed. A window makes exactly one
    /// probe, which ticks while open (positive control) and stops at close.
    func testNoFrameProbeTicksWhileNoWindowIsOpen() throws {
        var made: [SpikeFrameProbe] = []
        let center = makeCenter(makeFrameProbe: {
            let probe = SpikeFrameProbe()
            made.append(probe)
            return probe
        })
        center.activate()
        XCTAssertTrue(FollowerTiming.recorder === center.followers, "fixture: the probe is installed")

        spin(1.5)
        // The host app's own followers share the recorder; count only ours.
        let before = center.followers.dailySnapshot()[.wristSnapshot].count
        FollowerTiming.measure(.wristSnapshot) {}
        XCTAssertTrue(made.isEmpty, "an idle resident made \(made.count) frame probe(s)")
        XCTAssertFalse(center.followers.isWindowArmed, "an idle resident armed the follower window")
        XCTAssertEqual(center.followers.dailySnapshot()[.wristSnapshot].count, before + 1, "fixture: the day still counts the run")

        emitTap()
        XCTAssertEqual(made.count, 1, "a window makes one frame probe")
        let probe = try XCTUnwrap(made.first)
        var ticks = 0
        let centersTick = probe.onTick
        probe.onTick = { timestamp in
            ticks += 1
            centersTick?(timestamp)
        }
        spin(0.5)
        XCTAssertGreaterThan(ticks, 5, "positive control: the open window's probe ticks")
        center.closeWindow()
        // Re-attach a counter after the close: a link still alive would
        // reach it.
        let atClose = ticks
        probe.onTick = { _ in ticks += 1 }
        spin(1.0)
        XCTAssertEqual(ticks, atClose, "the probe ticked \(ticks - atClose) time(s) after the window closed")
        XCTAssertEqual(made.count, 1)
        XCTAssertFalse(center.followers.isWindowArmed)
    }

    // MARK: A real display link

    /// A real 60 ms block inside one follower, inside an open window, with
    /// the real clock and the real display link: the window charges it to
    /// exactly that follower, at least 60 ms, and places it in the largest
    /// frame. The frame bounds are the link's vsync timestamps, so the part
    /// inside the largest frame may fall short of the run by up to one
    /// refresh interval; the exact numbers are printed for the report.
    func testARealDisplayLinkChargesABlockingRunToItsFollowerAndTheLargestFrame() throws {
        let blockMs = 60.0
        // A display link's first timestamp is the last vsync the main run
        // loop saw, which a busy main thread (an earlier test) can leave
        // seconds old; a throwaway link first keeps it a frame old.
        let warm = SpikeFrameProbe()
        warm.start()
        spin(0.3)
        _ = warm.stopAndSummarize()
        let center = makeCenter()
        center.activate()
        emitTap()
        spin(0.3)
        FollowerTiming.measure(.syncCalendarHash) { busyWait(ms: blockMs) }
        spin(0.3)
        center.closeWindow()

        let window = try XCTUnwrap(windows().first)
        let total = try XCTUnwrap(number(window, "wfl.syncCal.hash.ms"))
        let runs = try XCTUnwrap(number(window, "wfl.syncCal.hash.n"))
        let maxFrame = try XCTUnwrap(number(window, "wfl.maxFrameMs"), "a window with ticks has a largest frame")
        let inMax = try XCTUnwrap(number(window, "wfl.syncCal.hash.inMaxFrameMs"))
        let inMaxAll = try XCTUnwrap(number(window, "wfl.inMaxFrameMs"))
        let fps = Double(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.maximumFramesPerSecond ?? 60)
        let refreshMs = 1000 / max(fps, 1)
        let probeMax = number(window, "wMaxFrameDeltaMs") ?? -1
        let line = String(format: "PerfBatch2QA real link: block=%.0fms charged=%.2fms n=%.0f maxFrame=%.2fms (window probe wMaxFrameDeltaMs=%.2fms) inMax(follower)=%.2fms inMax(all)=%.2fms refresh=%.2fms",
                          blockMs, total, runs, maxFrame, probeMax, inMax, inMaxAll, refreshMs)
        print(line)
        DiagnosticTrail.record("PerfBatch2QA", line)

        XCTAssertEqual(runs, 1, line)
        XCTAssertGreaterThanOrEqual(total, blockMs, line)
        XCTAssertLessThan(total, blockMs + 20, "nothing but the block is charged to it: \(line)")
        XCTAssertGreaterThanOrEqual(maxFrame, blockMs - refreshMs, "the block is the window's largest frame: \(line)")
        XCTAssertGreaterThanOrEqual(inMax, blockMs - refreshMs - 1, "the block sits in the largest frame: \(line)")
        XCTAssertLessThanOrEqual(inMax, total + 0.01, line)
        XCTAssertLessThanOrEqual(inMax, maxFrame + 0.01, line)
        // No other follower outranks it inside that frame.
        for id in FollowerID.allCases where id != .syncCalendarHash {
            let other = number(window, FollowerWindowResult.windowInMaxFrameKey(id)) ?? 0
            XCTAssertLessThan(other, inMax, "\(id.stem) outranks the block in the largest frame: \(line)")
        }
        let tag = "followers: window=\(window.id.uuidString.prefix(8).lowercased())"
        let trail = DiagnosticTrail.combinedText().split(separator: "\n").filter { $0.contains(tag) }
        XCTAssertEqual(trail.count, 1, "one trail line for the window")
        XCTAssertTrue(trail.first?.contains("(syncCal.hash) dropped=0") == true,
                      "the trail line names the block's follower as the largest frame's top: \(trail.first ?? "")")
    }

    // MARK: Owner change

    /// A sign-in / sign-out / account switch mid-day closes the old owner's
    /// id and starts the followers over for the new one, like the counters.
    func testASameDayOwnerChangeStartsTheFollowersOver() throws {
        var owner: String? = TelemetryFixtures.uid
        let clock = FollowerManualClock()
        let center = makeCenter(ownerUID: { owner }, followerClock: { clock.ns })
        center.activate()
        FollowerTiming.measure(.imageScan) { clock.advance(ms: 5) }
        center.flushDaily()

        owner = TelemetryFixtures.otherUID
        center.flushDaily()                       // the claim change: closes A, mints B
        FollowerTiming.measure(.imageScan) { clock.advance(ms: 3) }
        center.flushDaily()

        func latest(_ uid: String) -> SpikeRun? {
            dailies().filter { $0.ownerUID == uid }.max { ($0.revision ?? 0) < ($1.revision ?? 0) }
        }
        let first = try XCTUnwrap(latest(TelemetryFixtures.uid), "the first owner's line")
        let second = try XCTUnwrap(latest(TelemetryFixtures.otherUID), "the second owner's line")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.metrics["fl.imgScan.n"], .number(1))
        XCTAssertEqual(first.metrics["fl.imgScan.ms"], .number(5))
        XCTAssertEqual(second.metrics["fl.imgScan.n"], .number(1), "the new owner starts from zero")
        XCTAssertEqual(second.metrics["fl.imgScan.ms"], .number(3))
        XCTAssertEqual(second.metrics["fl.imgScan.maxMs"], .number(3))
    }
}

// MARK: - The observatory's verdicts ignore the follower keys

final class PerfBatch2QAVerdictTests: XCTestCase {
    private let segment = FixWatchSegment(deviceModel: "iPhone17,1", osVersion: "26.0")

    private func makeRun(spikeID: String, scenarioID: String, metrics: [String: SpikeMetricValue],
                         startedAt: Date) -> SpikeRun {
        SpikeRun(
            id: UUID(), spikeID: spikeID, scenarioID: scenarioID, variantID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone17,1", osVersion: "26.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            buildConfiguration: "release",
            metrics: metrics, note: nil, outcome: .completed, abortReason: nil
        )
    }

    /// Every follower key either record kind can carry, at an absurd value.
    private func followerKeys(window: Bool, value: Double) -> [String: SpikeMetricValue] {
        let keys = window ? FollowerWindowResult.allKeys : FollowerStatTable.dailyKeys
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, SpikeMetricValue.number(value)) })
    }

    private func population(lagOver320: Int, commitMs: Double, settleMs: Double, hidden: Int, days: Int) -> (dailies: [SpikeRun], windows: [SpikeRun]) {
        var dailies: [SpikeRun] = []
        var windows: [SpikeRun] = []
        for day in 0..<days {
            let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
            var counters = ResidentCounterSet()
            for _ in 0..<20 { counters.tapLagHistogram.admit(lagMs: 30) }
            for _ in 0..<lagOver320 { counters.tapLagHistogram.admit(lagMs: 500) }
            counters.meComputedHidden = hidden
            counters.meComputedVisible = 3
            dailies.append(makeRun(spikeID: FixObservationRegistry.residentDailySpikeID,
                                   scenarioID: FixObservationRegistry.residentDailyScenarioID,
                                   metrics: counters.metrics, startedAt: start))
            for _ in 0..<4 {
                windows.append(makeRun(spikeID: FixObservationRegistry.effortPathFixID,
                                       scenarioID: FixObservationRegistry.windowScenarioID,
                                       metrics: ["wContaminated": .bool(false),
                                                 "wCommitMs": .string(String(format: "%.1f %.1f", commitMs, commitMs)),
                                                 "wFrameAfterCommitMs": .string(String(format: "%.1f", settleMs))],
                                       startedAt: start))
            }
        }
        return (dailies, windows)
    }

    private func withFollowers(_ runs: [SpikeRun], window: Bool, value: Double) -> [SpikeRun] {
        runs.map { run in
            var copy = run
            copy.metrics.merge(followerKeys(window: window, value: value)) { existing, _ in existing }
            return copy
        }
    }

    func testTheVerdictsReadTheSameWithAndWithoutFollowerKeys() {
        let scenarios = [
            population(lagOver320: 0, commitMs: 8, settleMs: 12, hidden: 0, days: 8),
            population(lagOver320: 30, commitMs: 400, settleMs: 900, hidden: 5, days: 8),
            population(lagOver320: 2, commitMs: 30, settleMs: 40, hidden: 0, days: 2),
        ]
        var distinctStates = Set<String>()
        for (index, scenario) in scenarios.enumerated() {
            let baseEffort = FixWatchVerdictEvaluator.evaluateEffortPath(dailies: scenario.dailies, windows: scenario.windows, currentSegment: segment)
            let baseGate = FixWatchVerdictEvaluator.evaluateMeTabGate(dailies: scenario.dailies)
            let baseTouch = FixWatchVerdictEvaluator.evaluateTouchDelivery(dailies: scenario.dailies, currentSegment: segment)
            distinctStates.insert("\(baseEffort.state)")
            for value in [0.0, 1e6, -1] {
                let dailies = withFollowers(scenario.dailies, window: false, value: value)
                let windows = withFollowers(scenario.windows, window: true, value: value)
                XCTAssertEqual(FixWatchVerdictEvaluator.evaluateEffortPath(dailies: dailies, windows: windows, currentSegment: segment),
                               baseEffort, "scenario \(index), follower value \(value): effort path")
                XCTAssertEqual(FixWatchVerdictEvaluator.evaluateMeTabGate(dailies: dailies), baseGate,
                               "scenario \(index), follower value \(value): Me tab gate")
                XCTAssertEqual(FixWatchVerdictEvaluator.evaluateTouchDelivery(dailies: dailies, currentSegment: segment), baseTouch,
                               "scenario \(index), follower value \(value): touch delivery")
            }
        }
        XCTAssertGreaterThan(distinctStates.count, 1, "fixture: the scenarios reach more than one verdict state (\(distinctStates))")
    }
}

// MARK: - gh#282: no coordinator, by any path

@MainActor
final class PerfBatch2QATokenOffTests: XCTestCase {
    /// The app's foreground and active edges, as the system posts them,
    /// create no coordinator (the host test only sees the launch path).
    func testForegroundAndActiveEdgesCreateNoCoordinator() async throws {
        XCTAssertEqual(TokenInferenceCoordinator.liveCount, 0, "fixture: none before")
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.post(name: name, object: UIApplication.shared)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(TokenInferenceCoordinator.liveCount, 0, "after \(name.rawValue)")
        }
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Code lines (comments stripped) that construct a coordinator, per file.
    private func constructions(under directory: String) throws -> [String] {
        let base = Self.repoRoot.appendingPathComponent(directory)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        var hits: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = raw.components(separatedBy: "//").first ?? ""
                if code.contains("TokenInferenceCoordinator(") {
                    hits.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "fixture: \(directory) was read")
        return hits
    }

    func testNoAppSourceConstructsACoordinator() throws {
        XCTAssertEqual(try constructions(under: "Done"), [], "the iOS app constructs a token inference coordinator")
        XCTAssertEqual(try constructions(under: "DoneMac"), [], "the Mac app constructs a token inference coordinator")
        // Positive control: the same scan finds the hand-built coordinator
        // in the batch's own positive-control test.
        XCTAssertTrue(try constructions(under: "DoneTests").contains { $0.hasPrefix("TokenInferenceOffTests.swift:") },
                      "the scan finds a construction where one exists")
    }
}




// MARK: - The sync flush: every network await stays outside the baseline spans

/// The batch's own flush test holds the INSERT; these hold the tombstone and
/// the conditional patch, the two awaits that sit right after the first
/// baseline span ends. A span whose end slid past either await would charge
/// the network's time (and any main-actor work interleaved during it).
@MainActor
final class PerfBatch2QASyncSpanTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!
    private var recorder: FollowerTimingRecorder!
    private var displaced: FollowerTimingRecorder?
    private let uid = "55555555-4444-4444-8444-444444444444"

    override func setUp() {
        super.setUp()
        suiteName = "PerfBatch2QASyncSpanTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
        recorder = FollowerTimingRecorder(isForeground: true)
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = recorder
    }

    override func tearDown() {
        FollowerTiming.recorder = displaced
        server.releaseAll()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func events(_ count: Int) -> [Event] {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return (0..<count).map {
            Event(title: "e\($0)", timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
        }
    }

    /// Runs `second` as a flush with `verb` held for `holdMs` on the far
    /// side; returns (wall ms of that flush, baseline runs it added, baseline
    /// ms it added).
    private func heldFlush(_ verb: SyncFakeServer.Verb, holdMs: Int, _ second: [Event]) async throws -> (Double, Int, Double) {
        let before = recorder.dailySnapshot()[.syncCalendarBaseline]
        server.holdWhen = { held, _ in held == verb }
        let started = FollowerClock.now()
        let flush = Task { await service.syncEvents(second, kind: "calendar") }
        let deadline = Date().addingTimeInterval(5)
        while server.heldCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(server.heldCount, 0, "fixture: the flush reached the network with a \(verb)")
        try await Task.sleep(for: .milliseconds(holdMs))
        server.holdWhen = nil
        server.releaseAll()
        await flush.value
        let wallMs = Double(FollowerClock.now() - started) / 1e6
        let after = recorder.dailySnapshot()[.syncCalendarBaseline]
        return (wallMs, after.count - before.count, Double(after.totalNs - before.totalNs) / 1e6)
    }

    func testATombstoneAwaitIsOutsideTheBaselineSpans() async throws {
        let all = events(3)
        await service.syncEvents(all, kind: "calendar")
        let (wall, runs, spanMs) = try await heldFlush(.tombstone, holdMs: 400, Array(all.dropFirst()))
        XCTAssertGreaterThanOrEqual(wall, 400, "positive control: the tombstone really took the held time")
        XCTAssertEqual(runs, 2, "before the sends and after them")
        XCTAssertLessThan(spanMs, 100, "the baseline spans are main-thread work only (wall \(wall)ms)")
    }

    func testAConditionalPatchAwaitIsOutsideTheBaselineSpans() async throws {
        var all = events(3)
        await service.syncEvents(all, kind: "calendar")
        all[1].title = "changed"
        let (wall, runs, spanMs) = try await heldFlush(.patch, holdMs: 400, all)
        XCTAssertGreaterThanOrEqual(wall, 400, "positive control: the patch really took the held time")
        XCTAssertEqual(runs, 2, "before the sends and after them")
        XCTAssertLessThan(spanMs, 100, "the baseline spans are main-thread work only (wall \(wall)ms)")
    }
}
