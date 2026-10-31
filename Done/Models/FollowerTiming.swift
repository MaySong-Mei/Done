//
//  FollowerTiming.swift
//  Done
//
//  perf batch 2a — the follower timing probe (FIX WATCH, report-only).
//
//  A FOLLOWER is main-actor work that runs because a store changed: the sync
//  flush, the calendar's occurrence cache rebuild, the backup snapshot, the
//  deferred colorDepth mirror, the widget and watch projections, the image
//  scan. After a tap commits, these run in the frames that follow it, and the
//  window probe sees those frames as slow without knowing whose work they
//  carried. This file attributes main-thread time to each follower:
//
//    * `FollowerTiming.measure(.id) { … }` wraps the synchronous part of a
//      follower. Only what runs inside the closure is timed, so a network
//      await can never be counted — a closure cannot await.
//    * `FollowerTimingRecorder` accumulates per follower: count, total and
//      longest single run. Two tables: the DAY (foreground only, rides the
//      resident's daily record) and the open auto-WINDOW (rides the window
//      record), plus, for the window, how much of each follower's time fell
//      inside the window's largest frame.
//
//  Cost contract (the hot path is `measure` with a recorder installed): two
//  clock reads, a fixed-depth stack push and pop, and in-place stores into
//  arrays the recorder allocated once at init. No dictionary, no string, no
//  allocation per call. With no recorder installed — under XCTest, on the Mac,
//  before the resident activates — `measure` is one nil check around the
//  body.
//
//  Nesting is EXCLUSIVE: a follower measured inside another is charged to
//  itself, and the outer one is charged only the time outside it, so the
//  followers' times in a window never sum to more than the main thread ran.
//
//  Everything here is report-only. No verdict reads these numbers, and the
//  window probe's own metrics (`ResidentWindowAggregates`) are untouched: the
//  follower keys are added beside them under their own prefixes.
//
//  Shared with DoneMac (EventStore, the sync engine and the backup snapshot
//  carry the measure calls). The Mac never installs a recorder.
//

import Foundation

// MARK: - Vocabulary

/// Every follower the probe knows. A CLOSED set: a new follower is a new case
/// (and new registry keys), never a free-form string, so nothing a caller
/// passes can grow the record or put text on the wire.
enum FollowerID: Int, CaseIterable {
    // The sync flush, per table group and phase. `build` turns the store's
    // array into rows; `hash` hashes every row; `baseline` is the diff against
    // the baseline, the sent-markers and the baseline writes, before and after
    // the network. The network awaits sit between the measured spans.
    case syncCalendarBuild
    case syncCalendarHash
    case syncCalendarBaseline
    case syncLogsBuild
    case syncLogsHash
    case syncLogsBaseline
    case syncFeedbackBuild
    case syncFeedbackHash
    case syncFeedbackBaseline
    /// Todos, todo lists, event types and skill insights.
    case syncOtherBuild
    case syncOtherHash
    case syncOtherBaseline
    /// The settings row: snapshot, canonical blob and per-key hashes.
    case syncSettings
    /// `CalendarPageView.rebuildOccurrencesCache`: the synchronous window
    /// around the selected day, then each progressive batch.
    case occurrenceSync
    case occurrenceBatch
    /// The backup snapshot's dirty check (encode + digest, and the first
    /// launch's comparison with the file), then the write when it is dirty.
    case snapshotDigest
    case snapshotWrite
    /// The deferred effort → colorDepth mirror, including its commit.
    case colorDepthMirror
    case widgetSnapshot
    case wristSnapshot
    /// The image backup's candidate walk over every event and log.
    case imageScan

    /// The key stem on the wire (`fl.<stem>.n`, `wfl.<stem>.ms`, …).
    var stem: String {
        switch self {
        case .syncCalendarBuild: return "syncCal.build"
        case .syncCalendarHash: return "syncCal.hash"
        case .syncCalendarBaseline: return "syncCal.baseline"
        case .syncLogsBuild: return "syncLog.build"
        case .syncLogsHash: return "syncLog.hash"
        case .syncLogsBaseline: return "syncLog.baseline"
        case .syncFeedbackBuild: return "syncFb.build"
        case .syncFeedbackHash: return "syncFb.hash"
        case .syncFeedbackBaseline: return "syncFb.baseline"
        case .syncOtherBuild: return "syncOther.build"
        case .syncOtherHash: return "syncOther.hash"
        case .syncOtherBaseline: return "syncOther.baseline"
        case .syncSettings: return "syncSettings"
        case .occurrenceSync: return "occ.sync"
        case .occurrenceBatch: return "occ.batch"
        case .snapshotDigest: return "snap.digest"
        case .snapshotWrite: return "snap.write"
        case .colorDepthMirror: return "mirror"
        case .widgetSnapshot: return "widget"
        case .wristSnapshot: return "wrist"
        case .imageScan: return "imgScan"
        }
    }

    var group: FollowerGroup {
        switch self {
        case .syncCalendarBuild, .syncCalendarHash, .syncCalendarBaseline,
             .syncLogsBuild, .syncLogsHash, .syncLogsBaseline,
             .syncFeedbackBuild, .syncFeedbackHash, .syncFeedbackBaseline,
             .syncOtherBuild, .syncOtherHash, .syncOtherBaseline,
             .syncSettings:
            return .sync
        case .occurrenceSync, .occurrenceBatch: return .occurrences
        case .snapshotDigest, .snapshotWrite: return .snapshot
        case .colorDepthMirror: return .mirror
        case .widgetSnapshot: return .widget
        case .wristSnapshot: return .wrist
        case .imageScan: return .imageScan
        }
    }
}

/// The trail line's coarse columns.
enum FollowerGroup: Int, CaseIterable {
    case sync, occurrences, snapshot, mirror, widget, wrist, imageScan

    var label: String {
        switch self {
        case .sync: return "sync"
        case .occurrences: return "occ"
        case .snapshot: return "snap"
        case .mirror: return "mirror"
        case .widget: return "widget"
        case .wrist: return "wrist"
        case .imageScan: return "img"
        }
    }
}

/// The sync engine's per-row tables, folded into the four groups the probe
/// keeps apart. Keyed by the BASELINE table name `pushTable` is handed.
enum FollowerSyncTable: Equatable {
    case calendar, logs, feedback, other

    init(baselineTable: String) {
        switch baselineTable {
        case "calendar_events": self = .calendar
        case "event_logs": self = .logs
        case "event_feedback": self = .feedback
        default: self = .other
        }
    }

    var build: FollowerID {
        switch self {
        case .calendar: return .syncCalendarBuild
        case .logs: return .syncLogsBuild
        case .feedback: return .syncFeedbackBuild
        case .other: return .syncOtherBuild
        }
    }

    var hash: FollowerID {
        switch self {
        case .calendar: return .syncCalendarHash
        case .logs: return .syncLogsHash
        case .feedback: return .syncFeedbackHash
        case .other: return .syncOtherHash
        }
    }

    var baseline: FollowerID {
        switch self {
        case .calendar: return .syncCalendarBaseline
        case .logs: return .syncLogsBaseline
        case .feedback: return .syncFeedbackBaseline
        case .other: return .syncOtherBaseline
        }
    }
}

// MARK: - Clock

/// One monotonic clock for the spans AND the frame ticks. `CLOCK_UPTIME_RAW`
/// is `mach_absolute_time` in nanoseconds, the same timebase
/// `CACurrentMediaTime` and `CADisplayLink.timestamp` report in seconds, so a
/// frame boundary and a follower span can be compared directly.
enum FollowerClock {
    nonisolated static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// A media-time timestamp (seconds) on the same clock, in nanoseconds.
    nonisolated static func nanoseconds(fromMediaSeconds seconds: Double) -> UInt64 {
        seconds > 0 ? UInt64((seconds * 1e9).rounded()) : 0
    }
}

// MARK: - Accumulation (pure)

struct FollowerStat: Equatable {
    var count = 0
    var totalNs: UInt64 = 0
    var maxNs: UInt64 = 0

    /// Saturating, so a total can pin at its ceiling but never wrap to a
    /// small number that would read as healthy.
    mutating func add(_ ns: UInt64) {
        count &+= 1
        let (sum, overflow) = totalNs.addingReportingOverflow(ns)
        totalNs = overflow ? .max : sum
        if ns > maxNs { maxNs = ns }
    }
}

/// Milliseconds as the records carry them: hundredths of a millisecond.
enum FollowerMillis {
    static func value(_ ns: UInt64) -> Double {
        (Double(ns) / 1e4).rounded() / 100
    }

    static func nanoseconds(_ ms: Double) -> UInt64 {
        guard ms.isFinite, ms > 0 else { return 0 }
        return UInt64((ms * 1e6).rounded())
    }
}

/// One stat per follower, indexed by `FollowerID.rawValue`. A value type for
/// snapshots, seeds and fixtures; the recorder keeps its own live copies and
/// hands these out only as fresh copies, never as a shared buffer it will
/// mutate again.
struct FollowerStatTable: Equatable {
    private(set) var stats: [FollowerStat]

    init() {
        stats = Array(repeating: FollowerStat(), count: FollowerID.allCases.count)
    }

    subscript(id: FollowerID) -> FollowerStat {
        stats[id.rawValue]
    }

    mutating func add(_ id: FollowerID, ns: UInt64) {
        stats[id.rawValue].add(ns)
    }

    /// A copy that owns its own storage.
    func detached() -> FollowerStatTable {
        var copy = FollowerStatTable()
        for index in stats.indices { copy.stats[index] = stats[index] }
        return copy
    }

    var totalRuns: Int { stats.reduce(0) { $0 + $1.count } }
    var isEmpty: Bool { totalRuns == 0 }

    func totalNs(of group: FollowerGroup) -> UInt64 {
        FollowerID.allCases.filter { $0.group == group }.reduce(0) { $0 &+ self[$1].totalNs }
    }

    func count(of group: FollowerGroup) -> Int {
        FollowerID.allCases.filter { $0.group == group }.reduce(0) { $0 + self[$1].count }
    }

    // MARK: Daily record keys

    /// Daily keys: `fl.<stem>.n` / `.ms` / `.maxMs`, every follower, zero
    /// included — the daily line's key set is fixed (the wire conformance
    /// test compares it with the registry in both directions).
    static func dailyCountKey(_ id: FollowerID) -> String { "fl.\(id.stem).n" }
    static func dailyTotalKey(_ id: FollowerID) -> String { "fl.\(id.stem).ms" }
    static func dailyMaxKey(_ id: FollowerID) -> String { "fl.\(id.stem).maxMs" }
    /// Runs whose nesting went past the recorder's fixed stack; those were
    /// charged inclusive time. Expected 0.
    static let dailyOverflowKey = "fl.overflow"

    static var dailyKeys: [String] {
        FollowerID.allCases.flatMap { [dailyCountKey($0), dailyTotalKey($0), dailyMaxKey($0)] } + [dailyOverflowKey]
    }

    func dailyMetrics(overflow: Int) -> [String: SpikeMetricValue] {
        var metrics: [String: SpikeMetricValue] = [Self.dailyOverflowKey: .number(Double(overflow))]
        for id in FollowerID.allCases {
            let stat = self[id]
            metrics[Self.dailyCountKey(id)] = .number(Double(stat.count))
            metrics[Self.dailyTotalKey(id)] = .number(FollowerMillis.value(stat.totalNs))
            metrics[Self.dailyMaxKey(id)] = .number(FollowerMillis.value(stat.maxNs))
        }
        return metrics
    }

    /// The relaunch seed: a day's record read back. Unknown keys are ignored
    /// and a missing key is zero, like `ResidentCounterSet(metrics:)`.
    init(dailyMetrics metrics: [String: SpikeMetricValue]) {
        self.init()
        func number(_ key: String) -> Double {
            if case .number(let value)? = metrics[key], value.isFinite, value > 0 { return value }
            return 0
        }
        for id in FollowerID.allCases {
            stats[id.rawValue] = FollowerStat(
                count: Int(number(Self.dailyCountKey(id))),
                totalNs: FollowerMillis.nanoseconds(number(Self.dailyTotalKey(id))),
                maxNs: FollowerMillis.nanoseconds(number(Self.dailyMaxKey(id)))
            )
        }
    }

    static func dailyOverflow(in metrics: [String: SpikeMetricValue]) -> Int {
        if case .number(let value)? = metrics[dailyOverflowKey], value.isFinite, value > 0 { return Int(value) }
        return 0
    }
}

// MARK: - A closed window (pure)

/// What one auto-window's followers did, from arm to close.
struct FollowerWindowResult: Equatable {
    var table: FollowerStatTable
    /// Per follower, the part of its time inside the window's largest frame.
    var inMaxFrameNs: [UInt64]
    /// The largest tick-to-tick interval the window saw; nil with fewer than
    /// two ticks (no probe, or a window closed before its second frame).
    var maxFrameNs: UInt64?
    /// Runs the frame attribution could not place (its fixed buffer was full)
    /// or whose nesting went past the fixed stack. Expected 0.
    var dropped: Int

    static func windowCountKey(_ id: FollowerID) -> String { "wfl.\(id.stem).n" }
    static func windowTotalKey(_ id: FollowerID) -> String { "wfl.\(id.stem).ms" }
    static func windowMaxKey(_ id: FollowerID) -> String { "wfl.\(id.stem).maxMs" }
    static func windowInMaxFrameKey(_ id: FollowerID) -> String { "wfl.\(id.stem).inMaxFrameMs" }
    /// Every follower run the window saw, zero included: the marker that the
    /// probe was armed (an older build's window carries no `wfl.` key at all).
    static let runsKey = "wfl.runs"
    static let maxFrameKey = "wfl.maxFrameMs"
    static let inMaxFrameKey = "wfl.inMaxFrameMs"
    static let droppedKey = "wfl.dropped"

    /// Every key a window can carry, for the registry and its tests.
    static var allKeys: [String] {
        FollowerID.allCases.flatMap {
            [windowCountKey($0), windowTotalKey($0), windowMaxKey($0), windowInMaxFrameKey($0)]
        } + [runsKey, maxFrameKey, inMaxFrameKey, droppedKey]
    }

    var inMaxFrameTotalNs: UInt64 { inMaxFrameNs.reduce(0, &+) }

    /// The follower with the most time inside the largest frame, if any.
    var topInMaxFrame: FollowerID? {
        guard let index = inMaxFrameNs.indices.max(by: { inMaxFrameNs[$0] < inMaxFrameNs[$1] }),
              inMaxFrameNs[index] > 0 else { return nil }
        return FollowerID(rawValue: index)
    }

    /// The window record's follower keys. A follower that did not run in the
    /// window has no keys (absent, not zero — like the window's other lists);
    /// `wfl.runs` is always there. The frame keys need a measured frame.
    func metrics() -> [String: SpikeMetricValue] {
        var metrics: [String: SpikeMetricValue] = [Self.runsKey: .number(Double(table.totalRuns))]
        for id in FollowerID.allCases where table[id].count > 0 {
            let stat = table[id]
            metrics[Self.windowCountKey(id)] = .number(Double(stat.count))
            metrics[Self.windowTotalKey(id)] = .number(FollowerMillis.value(stat.totalNs))
            metrics[Self.windowMaxKey(id)] = .number(FollowerMillis.value(stat.maxNs))
            if maxFrameNs != nil {
                metrics[Self.windowInMaxFrameKey(id)] = .number(FollowerMillis.value(inMaxFrameNs[id.rawValue]))
            }
        }
        if let maxFrameNs {
            metrics[Self.maxFrameKey] = .number(FollowerMillis.value(maxFrameNs))
            metrics[Self.inMaxFrameKey] = .number(FollowerMillis.value(inMaxFrameTotalNs))
        }
        if dropped > 0 {
            metrics[Self.droppedKey] = .number(Double(dropped))
        }
        return metrics
    }

    /// One line per window for the diagnostic trail, e.g.
    /// `followers: window=1a2b3c4d sync=12.30ms/4 occ=… snapW=0 maxFrame=… inMax=…(top) dropped=0`.
    func trailLine(windowID: UUID) -> String {
        func ms(_ ns: UInt64) -> String { String(format: "%.2fms", FollowerMillis.value(ns)) }
        var parts = ["followers: window=\(windowID.uuidString.prefix(8).lowercased())"]
        for group in FollowerGroup.allCases {
            parts.append("\(group.label)=\(ms(table.totalNs(of: group)))/\(table.count(of: group))")
        }
        parts.append("snapW=\(table[.snapshotWrite].count)")
        if let maxFrameNs {
            let top = topInMaxFrame.map { "(\($0.stem))" } ?? ""
            parts.append("maxFrame=\(ms(maxFrameNs)) inMax=\(ms(inMaxFrameTotalNs))\(top)")
        } else {
            parts.append("maxFrame=- inMax=-")
        }
        parts.append("dropped=\(dropped)")
        return parts.joined(separator: " ")
    }
}

// MARK: - Recorder (main actor)

/// The live accumulator. One per resident; installed as
/// `FollowerTiming.recorder` while the resident is active.
@MainActor
final class FollowerTimingRecorder {
    /// Deepest nesting with exact exclusive accounting; deeper runs are
    /// charged inclusive time and counted as overflow.
    static let maxDepth = 8
    /// Follower runs one frame can hold for the largest-frame attribution;
    /// past it a run is counted in `dropped` instead of placed.
    static let frameRunCapacity = 64

    private let now: () -> UInt64

    /// Daily accumulation runs only while this is true (the resident follows
    /// the app's active state). A window is open only while the app is
    /// active, so it does not consult this.
    var isForeground: Bool

    private var daily = FollowerStatTable()
    private(set) var dailyOverflow = 0

    private var depth = 0
    private var childNs: [UInt64]

    private(set) var isWindowArmed = false
    private var window = FollowerStatTable()
    private var windowInMaxFrame: [UInt64]
    private var windowDropped = 0
    private var lastTickNs: UInt64?
    private var maxFrameNs: UInt64?
    private var pendingStart: [UInt64]
    private var pendingEnd: [UInt64]
    private var pendingID: [Int]
    private var pendingCount = 0

    init(now: @escaping () -> UInt64 = FollowerClock.now, isForeground: Bool = true) {
        self.now = now
        self.isForeground = isForeground
        childNs = Array(repeating: 0, count: Self.maxDepth)
        windowInMaxFrame = Array(repeating: 0, count: FollowerID.allCases.count)
        pendingStart = Array(repeating: 0, count: Self.frameRunCapacity)
        pendingEnd = Array(repeating: 0, count: Self.frameRunCapacity)
        pendingID = Array(repeating: 0, count: Self.frameRunCapacity)
    }

    // MARK: Spans

    /// Opens a span; returns its start. Pair with exactly one `end`.
    func begin() -> UInt64 {
        if depth < Self.maxDepth { childNs[depth] = 0 }
        depth &+= 1
        return now()
    }

    func end(_ id: FollowerID, start: UInt64) {
        let end = now()
        guard depth > 0 else { return }
        depth &-= 1
        let elapsed = end >= start ? end &- start : 0
        var exclusive = elapsed
        var overflowed = false
        if depth < Self.maxDepth {
            exclusive = elapsed &- min(childNs[depth], elapsed)
        } else {
            overflowed = true
        }
        if depth > 0, depth &- 1 < Self.maxDepth {
            childNs[depth &- 1] &+= elapsed
        }
        record(id, exclusiveNs: exclusive, endNs: end, overflowed: overflowed)
    }

    private func record(_ id: FollowerID, exclusiveNs: UInt64, endNs: UInt64, overflowed: Bool) {
        if isForeground {
            daily.add(id, ns: exclusiveNs)
            if overflowed { dailyOverflow &+= 1 }
        }
        guard isWindowArmed else { return }
        window.add(id, ns: exclusiveNs)
        if overflowed { windowDropped &+= 1 }
        // Frame placement treats the exclusive time as one block ending where
        // the run ended (for an unnested run, that is exactly the run).
        guard pendingCount < Self.frameRunCapacity else {
            windowDropped &+= 1
            return
        }
        pendingStart[pendingCount] = endNs &- min(exclusiveNs, endNs)
        pendingEnd[pendingCount] = endNs
        pendingID[pendingCount] = id.rawValue
        pendingCount &+= 1
    }

    // MARK: Day

    /// A copy of the day so far.
    func dailySnapshot() -> FollowerStatTable {
        daily.detached()
    }

    func dailyEquals(_ table: FollowerStatTable?) -> Bool {
        guard let table else { return false }
        return daily == table
    }

    var dailyIsEmpty: Bool { daily.isEmpty && dailyOverflow == 0 }

    func resetDaily() {
        resetDaily(seed: FollowerStatTable(), overflow: 0)
    }

    func resetDaily(seed: FollowerStatTable, overflow: Int) {
        daily = seed.detached()
        dailyOverflow = overflow
    }

    // MARK: Window

    /// Starts a window's attribution (the resident's auto-window opened).
    func armWindow() {
        isWindowArmed = true
        window = FollowerStatTable()
        for index in windowInMaxFrame.indices { windowInMaxFrame[index] = 0 }
        windowDropped = 0
        lastTickNs = nil
        maxFrameNs = nil
        pendingCount = 0
    }

    /// Ends it and hands back what it saw; nil when no window was armed.
    func disarmWindow() -> FollowerWindowResult? {
        guard isWindowArmed else { return nil }
        isWindowArmed = false
        let result = FollowerWindowResult(
            table: window.detached(),
            inMaxFrameNs: windowInMaxFrame.map { $0 },
            maxFrameNs: maxFrameNs,
            dropped: windowDropped
        )
        pendingCount = 0
        lastTickNs = nil
        return result
    }

    /// A frame boundary (the window probe's display-link tick), on the span
    /// clock. Runs since the previous tick are placed in the frame that just
    /// ended, clipped to it; a run that reaches past the tick carries its
    /// remainder into the next frame. When this frame is the window's
    /// largest so far, its placement replaces the previous largest's.
    func noteFrameTick(atNs tick: UInt64) {
        guard isWindowArmed else { return }
        guard let last = lastTickNs else {
            // The first tick has no frame before it to measure: drop what
            // came before it, keep what reaches past it.
            carryRemainders(past: tick, from: 0, attributeFrom: nil)
            lastTickNs = tick
            return
        }
        guard tick > last else { return }
        let delta = tick &- last
        let isLargest = maxFrameNs.map { delta > $0 } ?? true
        if isLargest {
            maxFrameNs = delta
            for index in windowInMaxFrame.indices { windowInMaxFrame[index] = 0 }
        }
        carryRemainders(past: tick, from: last, attributeFrom: isLargest ? last : nil)
        lastTickNs = tick
    }

    private func carryRemainders(past tick: UInt64, from frameStart: UInt64, attributeFrom: UInt64?) {
        var kept = 0
        for index in 0..<pendingCount {
            let start = max(pendingStart[index], frameStart)
            let end = pendingEnd[index]
            if attributeFrom != nil {
                let overlapEnd = min(end, tick)
                if overlapEnd > start {
                    windowInMaxFrame[pendingID[index]] &+= overlapEnd &- start
                }
            }
            if end > tick {
                pendingStart[kept] = max(pendingStart[index], tick)
                pendingEnd[kept] = end
                pendingID[kept] = pendingID[index]
                kept &+= 1
            }
        }
        pendingCount = kept
    }
}

// MARK: - Entry point

@MainActor
enum FollowerTiming {
    /// The installed recorder; nil means the probe is off and `measure` only
    /// runs its body.
    static var recorder: FollowerTimingRecorder?

    @inline(__always)
    static func measure<T>(_ id: FollowerID, _ body: () throws -> T) rethrows -> T {
        guard let recorder else { return try body() }
        let start = recorder.begin()
        defer { recorder.end(id, start: start) }
        return try body()
    }

    /// For a straight-line span that a closure cannot wrap (its `let`s are
    /// read after it). Every `begin` must reach its `end`: no return or throw
    /// in between.
    @inline(__always)
    static func begin() -> (recorder: FollowerTimingRecorder, start: UInt64)? {
        guard let recorder else { return nil }
        return (recorder, recorder.begin())
    }

    @inline(__always)
    static func end(_ id: FollowerID, _ span: (recorder: FollowerTimingRecorder, start: UInt64)?) {
        guard let span else { return }
        span.recorder.end(id, start: span.start)
    }
}

// MARK: - Observatory readout (pure, report-only)

/// What 观察站 shows about the followers: report-only rows, never a verdict.
enum FollowerReport {
    struct Row: Equatable, Identifiable {
        let id: String
        let runs: Int
        let totalMs: Double
        let maxMs: Double
        /// Summed over windows; nil for the day (no frames there).
        let inMaxFrameMs: Double?
    }

    struct Summary: Equatable {
        /// Windows that carried follower keys.
        let windowCount: Int
        let windowRows: [Row]
        let largestFrameMs: Double?
        let inLargestFramesMs: Double?
        let todayRows: [Row]
    }

    private static func number(_ run: SpikeRun, _ key: String) -> Double? {
        if case .number(let value)? = run.metrics[key], value.isFinite { return value }
        return nil
    }

    /// Windows (any configuration — report-only) and the day's latest daily
    /// record, as rows sorted by total time, largest first.
    static func summarize(windows: [SpikeRun], today: SpikeRun?) -> Summary {
        let armed = windows.filter { number($0, FollowerWindowResult.runsKey) != nil }
        var windowRows: [Row] = []
        for id in FollowerID.allCases {
            var runs = 0
            var total = 0.0
            var longest = 0.0
            var inMax = 0.0
            for window in armed {
                runs += Int(number(window, FollowerWindowResult.windowCountKey(id)) ?? 0)
                total += number(window, FollowerWindowResult.windowTotalKey(id)) ?? 0
                longest = max(longest, number(window, FollowerWindowResult.windowMaxKey(id)) ?? 0)
                inMax += number(window, FollowerWindowResult.windowInMaxFrameKey(id)) ?? 0
            }
            if runs > 0 {
                windowRows.append(Row(id: id.stem, runs: runs, totalMs: total, maxMs: longest, inMaxFrameMs: inMax))
            }
        }
        var todayRows: [Row] = []
        if let today {
            for id in FollowerID.allCases {
                let runs = Int(number(today, FollowerStatTable.dailyCountKey(id)) ?? 0)
                guard runs > 0 else { continue }
                todayRows.append(Row(id: id.stem, runs: runs,
                                     totalMs: number(today, FollowerStatTable.dailyTotalKey(id)) ?? 0,
                                     maxMs: number(today, FollowerStatTable.dailyMaxKey(id)) ?? 0,
                                     inMaxFrameMs: nil))
            }
        }
        let frames = armed.compactMap { number($0, FollowerWindowResult.maxFrameKey) }
        let inFrames = armed.compactMap { number($0, FollowerWindowResult.inMaxFrameKey) }
        let byTotal: (Row, Row) -> Bool = { $0.totalMs != $1.totalMs ? $0.totalMs > $1.totalMs : $0.id < $1.id }
        return Summary(
            windowCount: armed.count,
            windowRows: windowRows.sorted(by: byTotal),
            largestFrameMs: frames.max(),
            inLargestFramesMs: inFrames.isEmpty ? nil : inFrames.reduce(0, +),
            todayRows: todayRows.sorted(by: byTotal)
        )
    }
}
