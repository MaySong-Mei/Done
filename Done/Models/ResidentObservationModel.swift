//
//  ResidentObservationModel.swift
//  Done
//
//  FIX WATCH — pure data + pure logic for the temporarily-resident
//  observability tier. No file I/O (ResidentObservationCenter.swift), no
//  CADisplayLink/UIKit, no SwiftUI (FixWatchView.swift), and — enforced by
//  a source-scan test — no UserDefaults and no `Calendar.current`: the
//  resident's signal path runs inside production body passes and gesture
//  closures, so everything here must be arithmetic over values the caller
//  already holds. The one function that needs calendar math
//  (`ResidentDayBounds.compute`) takes the Calendar as a parameter and is
//  called only from the center's init/flush edges, never per signal.
//
//  Two-tier shape (Fix Watch blueprint as amended):
//    * Tier 1 — `ResidentTierOneCore`: O(1) counter bumps per signal into
//      a FIXED-KEY value type, plus a bounded rolling gesture log (last
//      32 gestures). Gesture forensics come from THIS log, never from
//      windows (R-F1).
//    * Tier 2 — `ResidentWindowModel`: a window exists ONLY to attach the
//      frame probe for the post-commit settle storm. It opens on a
//      completed TAP's `.commitEnd` (drags never open windows: R-F8),
//      arming is near-free (in-memory struct; stamp and record write
//      happen at close: R-F5), one window at a time globally, extension
//      cap 2, 12 windows per day with budget state that survives
//      relaunch (R-F2 via the daily record).
//
//  The fixed-key counter set is the LOAD-BEARING privacy guard: the
//  `.counter`/`.invariant` signal cases accept arbitrary strings, and the
//  only reason no free-form string can ever reach a JSONL line is that
//  unknown ids bump nothing and unknown metric keys are dropped on seed.
//

import Foundation

// MARK: - Signal vocabulary

/// Signal ids shared between the Me-tab witness emitters
/// (AnalysisView.swift) and the resident listener. Centralized for the
/// same anti-typo reason as `Spike195SignalID`: a mismatch reads exactly
/// like a clean result.
enum FixWatchSignalID {
    /// TRIPWIRE (gh#214): a store-wide Me reduction ran while the Me
    /// surface was not visible. Expected 0; any positive is a 回归警报.
    ///
    /// HONESTY NOTE (R-F7): the `visible:` answer every reduction is
    /// forced to supply is the SAME predicate the gate reads
    /// (`RootTabVisibility.isVisible` via `ProfileHubActivation` /
    /// `\.rootTabIsVisible`). This tripwire therefore detects CALL-SITE
    /// BYPASSES — a future caller that skips the gate or hardcodes
    /// `visible: true` against a hidden surface reached through a fresh
    /// wrong predicate — and is BLIND to rot inside
    /// `RootTabVisibility.isVisible` itself: if that predicate breaks,
    /// the gate and the tripwire go blind together. No independent
    /// ground truth is built in this slice, deliberately.
    static let meComputedHidden = "me.aggregates.computedHidden"
    /// Liveness pair for the tripwire: the same sites count their
    /// legitimate (visible) executions, so `0 violations / 0 legitimate`
    /// reads INSUFFICIENT (dead wire or tab unvisited — indistinguishable
    /// and said so) while `0 / N` reads HOLDING.
    static let meComputedVisible = "me.aggregates.computedVisible"
}

// MARK: - Delivery-lag histogram (pure)

/// Fixed 8-bucket histogram for touch delivery lag, bumped ONCE PER
/// COMPLETED GESTURE from the rolling log's classified record (R-F4.3) —
/// never per raw `.changed` sample, which would let one slow drag
/// contribute 100+ small-lag samples and drown the regression this
/// histogram exists to catch (a restored `delaysContentTouches` hold
/// produces ONE large-lag sample per gesture).
///
/// Bucket edges are chosen so both criteria are exact bucket arithmetic:
/// p50 ≤ 40ms and p95 ≤ 120ms land on bucket boundaries — a daily
/// histogram cannot honestly state a 1ms-precision percentile, so the
/// criteria are stated as cumulative-share clauses instead.
struct ResidentLagHistogram: Equatable {
    /// Upper bounds of the measured buckets, inclusive. Two more buckets
    /// follow: over-the-last-bound, and missing (the gesture carried no
    /// admissible lag — no event time, or implausible).
    static let bucketUpperBoundsMs: [Double] = [10, 20, 40, 80, 120, 320]
    static let bucketCount = bucketUpperBoundsMs.count + 2
    private static let overflowIndex = bucketUpperBoundsMs.count
    private static let missingIndex = bucketUpperBoundsMs.count + 1

    private(set) var counts: [Int]

    init() {
        counts = Array(repeating: 0, count: Self.bucketCount)
    }

    init?(counts: [Int]) {
        guard counts.count == Self.bucketCount else { return nil }
        self.counts = counts
    }

    static func bucketIndex(forLagMs lagMs: Double?) -> Int {
        guard let lagMs else { return missingIndex }
        for (index, bound) in bucketUpperBoundsMs.enumerated() where lagMs <= bound {
            return index
        }
        return overflowIndex
    }

    mutating func admit(lagMs: Double?) {
        counts[Self.bucketIndex(forLagMs: lagMs)] += 1
    }

    /// Gestures that carried a measurable lag — the criteria's sample
    /// floor. The missing bucket is recorded (a zero must be
    /// distinguishable from a dead wire) but never feeds a share.
    var measuredCount: Int {
        counts[..<Self.missingIndex].reduce(0, +)
    }

    /// Measured samples at or under `ms`, which must be one of the bucket
    /// bounds — asking for any other cut is a caller bug, answered with
    /// nil rather than a silently wrong rounding.
    func measuredCountAtOrUnder(ms: Double) -> Int? {
        guard let boundIndex = Self.bucketUpperBoundsMs.firstIndex(of: ms) else { return nil }
        return counts[...boundIndex].reduce(0, +)
    }

    /// Space-separated bucket counts for the daily JSONL line.
    var serialized: String {
        counts.map(String.init).joined(separator: " ")
    }

    static func deserialize(_ raw: String) -> ResidentLagHistogram? {
        let parsed = raw.split(separator: " ").compactMap { Int($0) }
        return ResidentLagHistogram(counts: parsed)
    }

    /// Bucket-wise sum, for pooling several days into one criterion read.
    static func sum(_ histograms: [ResidentLagHistogram]) -> ResidentLagHistogram {
        var total = ResidentLagHistogram()
        for histogram in histograms {
            for index in 0..<Self.bucketCount {
                total.counts[index] += histogram.counts[index]
            }
        }
        return total
    }
}

// MARK: - Fixed-key counter set (pure)

/// Every Tier-1 counter the resident maintains. A STRUCT with named
/// fields, not a dictionary: the key set is closed at compile time, so no
/// signal — however its string id is spelled — can grow the state or
/// smuggle free-form content into the daily line. Seeding from a loaded
/// record drops unknown keys for the same reason.
struct ResidentCounterSet: Equatable {
    /// Entry 1 daily counters, fed by the per-instance store seams
    /// (`onDetailBodyPass` / `onPrefilledDraftComputed`) — NOT by a new
    /// global emit in CalendarEventDetailView (R-F11; king's seams
    /// document exactly why they are per-instance).
    var detailBodyPasses = 0
    var draftComputes = 0
    /// Entry 2 tripwire + liveness pair.
    var meComputedHidden = 0
    var meComputedVisible = 0
    /// Completed-gesture counts from the rolling log.
    var tapCount = 0
    var dragCount = 0
    /// Mirror of the lag tracker's quarantine count — the epoch-conversion
    /// self-announcement, on the daily line.
    var implausibleLagCount = 0
    /// All-day slot-commit context.
    var slotWritesLogRecords = 0
    var slotWritesCalendarEvents = 0
    var slotWritesOther = 0
    /// Window budget state. `windowsOpened` seeds the budget across
    /// relaunch by riding the daily record (R-F2).
    var windowsOpened = 0
    var windowsRefusedBudget = 0
    var windowsExtended = 0
    /// Entry 3's histograms: tap arm carries the criteria, drag arm is
    /// recorded context (the positive control).
    var tapLagHistogram = ResidentLagHistogram()
    var dragLagHistogram = ResidentLagHistogram()

    init() {}

    /// The daily line's metric vocabulary. One writer (the center's
    /// flush), read back by `init(metrics:)` at relaunch and by the
    /// verdict evaluator — a key spelled differently in any of the three
    /// places fails the round-trip test.
    var metrics: [String: SpikeMetricValue] {
        [
            "detailBodyPasses": .number(Double(detailBodyPasses)),
            "draftComputes": .number(Double(draftComputes)),
            "meComputedHidden": .number(Double(meComputedHidden)),
            "meComputedVisible": .number(Double(meComputedVisible)),
            "tapCount": .number(Double(tapCount)),
            "dragCount": .number(Double(dragCount)),
            "implausibleLagCount": .number(Double(implausibleLagCount)),
            "slotWritesLogRecords": .number(Double(slotWritesLogRecords)),
            "slotWritesCalendarEvents": .number(Double(slotWritesCalendarEvents)),
            "slotWritesOther": .number(Double(slotWritesOther)),
            "windowsOpened": .number(Double(windowsOpened)),
            "windowsRefusedBudget": .number(Double(windowsRefusedBudget)),
            "windowsExtended": .number(Double(windowsExtended)),
            "tapLagBuckets": .string(tapLagHistogram.serialized),
            "dragLagBuckets": .string(dragLagHistogram.serialized),
        ]
    }

    /// Relaunch seed (R-F2): ALL counters come back, not just budget —
    /// latest-record-wins collapse means the next same-day flush REPLACES
    /// the day's record, so anything not seeded here is silently erased
    /// by the evening flush (the adversary's exact scenario: a morning
    /// tripwire violation un-firing over lunch).
    init(metrics: [String: SpikeMetricValue]) {
        func number(_ key: String) -> Int {
            if case .number(let value)? = metrics[key] { return Int(value) }
            return 0
        }
        detailBodyPasses = number("detailBodyPasses")
        draftComputes = number("draftComputes")
        meComputedHidden = number("meComputedHidden")
        meComputedVisible = number("meComputedVisible")
        tapCount = number("tapCount")
        dragCount = number("dragCount")
        implausibleLagCount = number("implausibleLagCount")
        slotWritesLogRecords = number("slotWritesLogRecords")
        slotWritesCalendarEvents = number("slotWritesCalendarEvents")
        slotWritesOther = number("slotWritesOther")
        windowsOpened = number("windowsOpened")
        windowsRefusedBudget = number("windowsRefusedBudget")
        windowsExtended = number("windowsExtended")
        if case .string(let raw)? = metrics["tapLagBuckets"],
           let histogram = ResidentLagHistogram.deserialize(raw) {
            tapLagHistogram = histogram
        }
        if case .string(let raw)? = metrics["dragLagBuckets"],
           let histogram = ResidentLagHistogram.deserialize(raw) {
            dragLagHistogram = histogram
        }
    }
}

// MARK: - Civil-day bounds (pure given a calendar)

/// The rollover check on the signal path is ONE Double compare against
/// `dayEnd` (R-F10); this type owns the arithmetic that produces the
/// cached bound, and the Calendar it needs is a PARAMETER — the model
/// file's no-`Calendar.current` scan keeps calendar math off the hot
/// path structurally.
struct ResidentDayBounds: Equatable {
    let dayStart: Date
    let dayEnd: Date

    static func compute(for date: Date, calendar: Calendar) -> ResidentDayBounds {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return ResidentDayBounds(dayStart: start, dayEnd: end)
    }

    func contains(_ date: Date) -> Bool {
        date >= dayStart && date < dayEnd
    }
}

// MARK: - Tier-1 core (pure)

/// Everything the resident does with a signal, minus clocks and I/O. The
/// impure center reads the clocks, calls `ingest`, and acts on the
/// returned completion — so the classification rules, the ring bound,
/// and the fixed-key discipline are all pinned by fixtures.
struct ResidentTierOneCore: Equatable {
    /// Rolling-log bound (R-F1): big enough that a window's whole span
    /// (≤ 3 taps plus settle) plus generous context is always present,
    /// small enough that `noteFrame`'s O(records) walk during a window is
    /// a fixed handful of comparisons.
    static let gestureRingCapacity = 32

    var counters = ResidentCounterSet()
    private(set) var gestureLog = Spike201GestureLog()
    private(set) var lagTracker = Spike201DeliveryLagTracker()

    enum GestureCompletion: Equatable {
        case none
        /// A gesture just saw its `.commitEnd`. Classification is
        /// available HERE — at gesture end, from the completed record —
        /// which is what lets windows open only on taps (R-F8) and the
        /// histogram bump once per gesture (R-F4.3).
        case completed(isTap: Bool, commitEndedAtMedia: Double)
    }

    /// O(1) per signal: fixed-key bumps, a bounded ring append, no
    /// dictionary growth, no allocation beyond the ring's amortized
    /// storage. Unknown `.counter`/`.invariant` ids bump NOTHING — that
    /// is the privacy guard, not an oversight.
    mutating func ingest(signal: SpikeSignal, mediaNow: Double) -> GestureCompletion {
        switch signal {
        case .counter(let id):
            if id == FixWatchSignalID.meComputedVisible {
                counters.meComputedVisible += 1
            }
            return .none
        case .invariant(let id):
            if id == FixWatchSignalID.meComputedHidden {
                counters.meComputedHidden += 1
            }
            return .none
        case .bodyPass, .textLength:
            // Entry 1's daily body-pass/draft counters come from the
            // per-instance store seams (R-F11), and windows collect no
            // signal counts (R-F1: windows are frame-probe-only). The
            // resident deliberately ignores the global bodyPass stream.
            return .none
        case .gesture(let id, let phase, let eventTime, let locationX):
            guard id == Spike201SignalID.effortScrubber else { return .none }
            let wasTimingOpen = gestureLog.records.last?.isTimingOpen ?? false
            let rawLagMs = eventTime.map {
                Spike201DeliveryLagTracker.lagMs(eventTime: $0, mediaTimeNow: mediaNow)
            }
            let lagMs = lagTracker.admit(eventTime: eventTime, mediaTimeNow: mediaNow)
            gestureLog.ingest(
                phase: phase,
                at: mediaNow,
                locationX: locationX,
                deliveryLagMs: lagMs,
                rawDeliveryLagMs: rawLagMs
            )
            counters.implausibleLagCount = lagTracker.implausibleCount
            if phase == .commitEnd, wasTimingOpen,
               let last = gestureLog.records.last, !last.isTimingOpen {
                let isTap = Spike201Metrics.isTap(last)
                if isTap {
                    counters.tapCount += 1
                    counters.tapLagHistogram.admit(lagMs: last.firstDeliveryLagMs)
                } else {
                    counters.dragCount += 1
                    counters.dragLagHistogram.admit(lagMs: last.firstDeliveryLagMs)
                }
                gestureLog.trimRecords(toLast: Self.gestureRingCapacity)
                return .completed(isTap: isTap, commitEndedAtMedia: mediaNow)
            }
            return .none
        }
    }

    mutating func noteSlot(_ slot: StorageSlot) {
        switch slot {
        case .calendarEventLogRecords:
            counters.slotWritesLogRecords += 1
        case .calendarEvents:
            counters.slotWritesCalendarEvents += 1
        default:
            counters.slotWritesOther += 1
        }
        gestureLog.noteSlotWrite(slot: slot)
    }

    mutating func noteFrame(at time: Double) {
        gestureLog.noteFrame(at: time)
    }

    mutating func noteDetailBodyPass() {
        counters.detailBodyPasses += 1
    }

    mutating func noteDraftComputed() {
        counters.draftComputes += 1
    }

    /// Day rollover re-base: yesterday's counters have been flushed under
    /// yesterday's run id; everything in memory starts over.
    mutating func resetForNewDay() {
        counters = ResidentCounterSet()
        gestureLog = Spike201GestureLog()
        lagTracker = Spike201DeliveryLagTracker()
    }
}

// MARK: - Tier-2 window (pure)

/// One auto-capture window. Exists ONLY to attach the frame probe for the
/// post-commit settle storm — gesture forensics live in the rolling log.
/// Opening is an in-memory struct (R-F5: no stamp, no write-ahead, no
/// disk); everything heavy happens at close. A crash mid-window loses one
/// window, which is why launch reconciliation never needs to know windows
/// exist.
struct ResidentWindowModel: Equatable {
    static let durationSeconds: Double = 6
    /// A qualifying tap while open extends the deadline by one duration,
    /// at most this many times (R-F9: one probe, one window — extension
    /// instead of overlap keeps per-window frame stats honest).
    static let maxExtensions = 2
    static let dailyBudget = 12

    let openedAtMedia: Double
    let openedAt: Date
    /// The trigger tap's `.commitEnd` in media time — the lower bound of
    /// "gestures this window covers" when aggregating from the rolling
    /// log at close.
    let triggerCommitEndMedia: Double
    private(set) var deadlineMedia: Double
    private(set) var extensions = 0
    /// Qualifying taps past the extension cap — counted, never extending.
    private(set) var coalescedBeyondCap = 0
    private(set) var slotLogRecords = 0
    private(set) var slotCalendarEvents = 0
    private(set) var slotOther = 0

    init(openedAtMedia: Double, openedAt: Date, triggerCommitEndMedia: Double) {
        self.openedAtMedia = openedAtMedia
        self.openedAt = openedAt
        self.triggerCommitEndMedia = triggerCommitEndMedia
        deadlineMedia = openedAtMedia + Self.durationSeconds
    }

    /// Returns true when the tap extended the window.
    mutating func noteQualifyingTap() -> Bool {
        guard extensions < Self.maxExtensions else {
            coalescedBeyondCap += 1
            return false
        }
        extensions += 1
        deadlineMedia += Self.durationSeconds
        return true
    }

    mutating func noteSlot(_ slot: StorageSlot) {
        switch slot {
        case .calendarEventLogRecords: slotLogRecords += 1
        case .calendarEvents: slotCalendarEvents += 1
        default: slotOther += 1
        }
    }
}

enum ResidentWindowBudget {
    static func canOpen(openedToday: Int, budget: Int = ResidentWindowModel.dailyBudget) -> Bool {
        openedToday < budget
    }
}

// MARK: - Window close aggregation (pure)

enum ResidentWindowAggregates {
    /// R-F4.2: an auto-window has no lab protocol, so organic activity
    /// can interleave — an edit to the reflection note, a sync-driven
    /// commit, a scenePhase flush. Slot commits beyond the expected set
    /// (at most one log-record write and one mirrored calendar-event
    /// write per writing gesture, nothing in any other slot) mark the
    /// record contaminated; the verdict's clean-window floor counts only
    /// uncontaminated windows.
    static func isContaminated(window: ResidentWindowModel, writingGesturesInWindow: Int) -> Bool {
        window.slotOther > 0
            || window.slotLogRecords > writingGesturesInWindow
            || window.slotCalendarEvents > writingGesturesInWindow
    }

    /// The records this window covers: completed at or after the trigger
    /// tap's commit, at or before close. Media time is monotonic, so the
    /// bounds are exact.
    static func recordsInWindow(
        _ records: [Spike201GestureRecord],
        window: ResidentWindowModel,
        closedAtMedia: Double
    ) -> [Spike201GestureRecord] {
        records.filter { record in
            guard let commitEnd = record.commitEndedAt else { return false }
            return commitEnd >= window.triggerCommitEndMedia && commitEnd <= closedAtMedia
        }
    }

    /// Aggregates ONLY — no per-gesture CSV on auto-windows (R-F3: the
    /// record must stay small; manual runs keep their CSV). The list
    /// metrics carry at most 1 + maxExtensions values each.
    static func metrics(
        window: ResidentWindowModel,
        records: [Spike201GestureRecord],
        closedAtMedia: Double,
        probe: SpikeFrameProbeResult?,
        closedByResign: Bool
    ) -> [String: SpikeMetricValue] {
        let covered = recordsInWindow(records, window: window, closedAtMedia: closedAtMedia)
        let taps = covered.filter { Spike201Metrics.isTap($0) }
        let writingGestures = covered.filter { !Spike201Metrics.isNoOp($0) }
        let writingTaps = taps.filter { !Spike201Metrics.isNoOp($0) }
        // A gesture that began inside the window and never saw its commit
        // by close — visible, never silently completed (R-F8's truncation
        // honesty at the window level).
        let truncatedGesture = records.contains {
            $0.isTimingOpen && $0.firstChangedAt >= window.openedAtMedia
        }

        var metrics: [String: SpikeMetricValue] = [
            "wGestures": .number(Double(covered.count)),
            "wTaps": .number(Double(taps.count)),
            "wWritingTaps": .number(Double(writingTaps.count)),
            "wSlotLogRecords": .number(Double(window.slotLogRecords)),
            "wSlotCalendarEvents": .number(Double(window.slotCalendarEvents)),
            "wSlotOther": .number(Double(window.slotOther)),
            "wContaminated": .bool(isContaminated(window: window, writingGesturesInWindow: writingGestures.count)),
            "wExtensions": .number(Double(window.extensions)),
            "wCoalescedBeyondCap": .number(Double(window.coalescedBeyondCap)),
            "wTruncatedGesture": .bool(truncatedGesture),
            "wClosedByResign": .bool(closedByResign),
        ]

        func putList(_ key: String, _ values: [Double]) {
            guard !values.isEmpty else { return }
            metrics[key] = .string(values.map { String(format: "%.1f", $0) }.joined(separator: " "))
        }
        putList("wCommitMs", writingTaps.compactMap(\.commitMs))
        putList("wFrameAfterCommitMs", taps.compactMap(\.firstFrameAfterCommitMs))
        putList("wLagMs", taps.compactMap(\.firstDeliveryLagMs))

        if let probe {
            if let stats = probe.stats {
                metrics["wFrameDeltaCount"] = .number(Double(stats.count))
                metrics["wP50FrameDeltaMs"] = .number(stats.p50Ms)
                metrics["wP95FrameDeltaMs"] = .number(stats.p95Ms)
                metrics["wMaxFrameDeltaMs"] = .number(stats.maxMs)
            }
            metrics["wFrameActiveStallCount"] = .number(Double(probe.drain.activeStallsMs.count))
            metrics["wFrameSuspensionGapCount"] = .number(Double(probe.drain.suspensionGapCount))
            metrics["wFrameResignActiveCount"] = .number(Double(probe.drain.resignActiveCount))
            putList("wFrameLargestDeltasMs", Array(probe.drain.largestDeltasMs.prefix(8)))
        }
        return metrics
    }
}

// MARK: - Fix-observation registry

enum FixObservationLifecycle: String, Equatable {
    case active
    /// R-F11: retirement flips this flag and NOTHING else — the entry
    /// stays in the registry (greyed on the deck) and its emit sites are
    /// NEVER deleted by retirement. Retiring is a code change (a commit
    /// that edits this literal), not a runtime button: a registry that is
    /// a compile-time array cannot be mutated from the deck, and a button
    /// that pretended to would lie.
    case retired
}

struct FixObservationEntry: Identifiable, Equatable {
    /// Also the JSONL spikeID for the entry's auto-windows.
    let id: String
    let issueNumbers: [Int]
    /// King merge SHAs of the fixes under observation.
    let mergedSHAs: [String]
    let title: String
    let summary: String
    let hasWindows: Bool
    let lifecycle: FixObservationLifecycle
    let addedOn: String
    /// Past this civil date the deck shows OVERDUE — a banner,
    /// deliberately never a failing test (no time-bomb reds).
    let reviewBy: String
}

enum FixObservationRegistry {
    static let residentDailySpikeID = "resident-daily"
    static let residentDailyScenarioID = "daily-rollup"
    static let windowScenarioID = "auto-window"
    static let effortPathFixID = "fix-effort-path"
    static let meTabGateFixID = "fix-me-tab-gate"
    static let touchDeliveryFixID = "fix-touch-delivery"

    static let all: [FixObservationEntry] = [
        FixObservationEntry(
            id: effortPathFixID,
            issueNumbers: [201, 213],
            mergedSHAs: ["f645913", "c181611"],
            title: "Effort tap path",
            summary: "Tap → durable commit stays fast after the #201/#213 fixes: commit p50 ≤ 55ms from clean auto-windows; the 664–1009ms post-commit settle storm is NOT claimed fixed — its metrics display but never fail the verdict.",
            hasWindows: true,
            lifecycle: .active,
            addedOn: "2026-09-02",
            reviewBy: "2026-10-17"
        ),
        FixObservationEntry(
            id: meTabGateFixID,
            issueNumbers: [214],
            mergedSHAs: ["3362e4f", "3f1398e"],
            title: "Me-tab aggregate gate",
            summary: "Store-wide Me reductions never run off screen. Tripwire: any hidden compute is a 回归警报. Detects call-site bypasses; blind to rot inside RootTabVisibility.isVisible itself.",
            hasWindows: false,
            lifecycle: .active,
            addedOn: "2026-09-02",
            reviewBy: "2026-10-17"
        ),
        FixObservationEntry(
            id: touchDeliveryFixID,
            issueNumbers: [201],
            mergedSHAs: ["f645913"],
            title: "Touch delivery",
            summary: "Scrubber touches arrive live (pre-fix: 72–208ms medians under the delaysContentTouches hold). Tap-arm histogram: p50 ≤ 40ms and p95 ≤ 120ms.",
            hasWindows: false,
            lifecycle: .active,
            addedOn: "2026-09-02",
            reviewBy: "2026-10-17"
        ),
    ]

    static func entry(for id: String) -> FixObservationEntry? {
        all.first { $0.id == id }
    }
}

// MARK: - Verdict evaluation (pure)

enum FixVerdictState: String, Equatable {
    /// 观察中 — the entry is live but no Release data exists yet.
    case observing
    /// 数据不足 — some Release data, below the sample floors.
    case insufficient
    /// 达标 — every criterion holds on Release data.
    case holding
    /// 未达标 — at least one criterion fails on Release data.
    case failing
}

struct FixMetricReadout: Equatable, Identifiable {
    let id: String
    let measured: String
    let threshold: String
    /// nil = report-only: displayed, zero verdict weight.
    let passing: Bool?
}

struct FixVerdict: Equatable {
    let entryID: String
    let state: FixVerdictState
    /// Entry 2's 回归警报 — any positive tripwire count in retained
    /// Release dailies.
    let alarm: Bool
    let readouts: [FixMetricReadout]
    let releaseDayCount: Int
    /// Debug (or unattributed) records — displayed separately, NEVER
    /// feeding a verdict (R-F4.1).
    let nonReleaseCount: Int
    let notes: [String]
}

/// Criteria applied to Release records only; Debug and unattributed
/// records are counted for display and excluded from every criterion
/// (R-F4.1 — a mixed-config population can produce a false FAILING and
/// reopen an issue for a fix that holds).
enum FixWatchVerdictEvaluator {
    static let commitP50ThresholdMs: Double = 55
    static let commitMinSamples = 20
    static let lagMinSamples = 10

    static func isRelease(_ run: SpikeRun) -> Bool {
        run.buildConfiguration == "release"
    }

    static func partition(_ runs: [SpikeRun]) -> (release: [SpikeRun], nonReleaseCount: Int) {
        let release = runs.filter(isRelease)
        return (release, runs.count - release.count)
    }

    private static func pooledTapHistogram(_ releaseDailies: [SpikeRun]) -> ResidentLagHistogram {
        ResidentLagHistogram.sum(releaseDailies.compactMap { run in
            if case .string(let raw)? = run.metrics["tapLagBuckets"] {
                return ResidentLagHistogram.deserialize(raw)
            }
            return nil
        })
    }

    private static func parseList(_ value: SpikeMetricValue?) -> [Double] {
        guard case .string(let raw)? = value else { return [] }
        return raw.split(separator: " ").compactMap { Double($0) }
    }

    private static func shareReadout(
        id: String,
        histogram: ResidentLagHistogram,
        percentile: Int,
        boundMs: Double
    ) -> FixMetricReadout {
        let measured = histogram.measuredCount
        let atOrUnder = histogram.measuredCountAtOrUnder(ms: boundMs) ?? 0
        guard measured >= lagMinSamples else {
            return FixMetricReadout(
                id: id,
                measured: "\(measured) samples",
                threshold: "≥ \(lagMinSamples) samples",
                passing: nil
            )
        }
        let passing = atOrUnder * 100 >= measured * percentile
        return FixMetricReadout(
            id: id,
            measured: "\(atOrUnder)/\(measured) ≤ \(Int(boundMs))ms",
            threshold: "≥ \(percentile)%",
            passing: passing
        )
    }

    private static func state(for criteria: [FixMetricReadout], hasAnyReleaseData: Bool) -> FixVerdictState {
        guard hasAnyReleaseData else { return .observing }
        let decided = criteria.compactMap(\.passing)
        guard decided.count == criteria.count, !criteria.isEmpty else { return .insufficient }
        return decided.allSatisfy { $0 } ? .holding : .failing
    }

    // MARK: Entry 1 — fix-effort-path

    static func evaluateEffortPath(dailies: [SpikeRun], windows: [SpikeRun]) -> FixVerdict {
        let (releaseDailies, nonReleaseDailies) = partition(dailies)
        let (releaseWindows, nonReleaseWindows) = partition(windows)
        // Clean-window floor (R-F4.2): contaminated windows are excluded
        // from every pooled number.
        let cleanWindows = releaseWindows.filter { run in
            if case .bool(true)? = run.metrics["wContaminated"] { return false }
            return true
        }

        var criteria: [FixMetricReadout] = []
        var reportOnly: [FixMetricReadout] = []
        var notes: [String] = []

        // Criterion: pooled writing-tap commit p50 ≤ 55ms.
        let commitSamples = cleanWindows.flatMap { parseList($0.metrics["wCommitMs"]) }
        if commitSamples.count >= commitMinSamples, let p50 = Spike201Metrics.median(commitSamples) {
            criteria.append(FixMetricReadout(
                id: "commit p50",
                measured: String(format: "%.1fms (n=%d)", p50, commitSamples.count),
                threshold: "≤ \(Int(commitP50ThresholdMs))ms",
                passing: p50 <= commitP50ThresholdMs
            ))
        } else {
            criteria.append(FixMetricReadout(
                id: "commit p50",
                measured: "\(commitSamples.count) writing taps",
                threshold: "≥ \(commitMinSamples) samples",
                passing: nil
            ))
        }

        // Criterion: tap-arm delivery lag p50 ≤ 40ms (daily histogram).
        criteria.append(shareReadout(
            id: "delivery lag p50",
            histogram: pooledTapHistogram(releaseDailies),
            percentile: 50,
            boundMs: 40
        ))

        // Report-only: the settle storm (unclaimed 664–1009ms residual).
        let settleSamples = cleanWindows.flatMap { parseList($0.metrics["wFrameAfterCommitMs"]) }
        if let p50 = Spike201Metrics.median(settleSamples), let maxValue = settleSamples.max() {
            reportOnly.append(FixMetricReadout(
                id: "settle: first frame after commit",
                measured: String(format: "p50 %.0fms · max %.0fms (n=%d)", p50, maxValue, settleSamples.count),
                threshold: "report-only",
                passing: nil
            ))
        }
        // Report-only: daily draft-compute amplification via the seams.
        let passes = releaseDailies.reduce(0) { total, run -> Int in
            if case .number(let value)? = run.metrics["detailBodyPasses"] { return total + Int(value) }
            return total
        }
        let drafts = releaseDailies.reduce(0) { total, run -> Int in
            if case .number(let value)? = run.metrics["draftComputes"] { return total + Int(value) }
            return total
        }
        if passes > 0 {
            reportOnly.append(FixMetricReadout(
                id: "drafts / body passes",
                measured: String(format: "%.2f (%d/%d)", Double(drafts) / Double(passes), drafts, passes),
                threshold: "report-only",
                passing: nil
            ))
        }
        notes.append("残余 settle storm(664–1009ms)未宣称修复,仅展示,不参与判定")

        let hasData = !releaseDailies.isEmpty || !releaseWindows.isEmpty
        return FixVerdict(
            entryID: FixObservationRegistry.effortPathFixID,
            state: state(for: criteria, hasAnyReleaseData: hasData),
            alarm: false,
            readouts: criteria + reportOnly,
            releaseDayCount: releaseDailies.count,
            nonReleaseCount: nonReleaseDailies + nonReleaseWindows,
            notes: notes + (cleanWindows.count < releaseWindows.count
                ? ["\(releaseWindows.count - cleanWindows.count) 个窗口因外部写入污染被排除"]
                : [])
        )
    }

    // MARK: Entry 2 — fix-me-tab-gate (tripwire)

    static func evaluateMeTabGate(dailies: [SpikeRun]) -> FixVerdict {
        let (releaseDailies, nonReleaseCount) = partition(dailies)
        var hidden = 0
        var visible = 0
        for run in releaseDailies {
            if case .number(let value)? = run.metrics["meComputedHidden"] { hidden += Int(value) }
            if case .number(let value)? = run.metrics["meComputedVisible"] { visible += Int(value) }
        }

        let state: FixVerdictState
        let alarm = hidden > 0
        if releaseDailies.isEmpty {
            state = .observing
        } else if alarm {
            // Alarm-on-any: no threshold, no statistics, overrides
            // everything else.
            state = .failing
        } else if visible == 0 {
            // 0/0: dead wire or tab unvisited — indistinguishable, and
            // said so rather than read as HOLDING.
            state = .insufficient
        } else {
            state = .holding
        }
        return FixVerdict(
            entryID: FixObservationRegistry.meTabGateFixID,
            state: state,
            alarm: alarm,
            readouts: [
                FixMetricReadout(
                    id: "hidden computes",
                    measured: "\(hidden)",
                    threshold: "== 0",
                    passing: releaseDailies.isEmpty ? nil : !alarm
                ),
                FixMetricReadout(
                    id: "visible computes (liveness)",
                    measured: "\(visible)",
                    threshold: "> 0",
                    passing: nil
                ),
            ],
            releaseDayCount: releaseDailies.count,
            nonReleaseCount: nonReleaseCount,
            notes: ["仅检测调用点绕过;对 RootTabVisibility.isVisible 本身的腐坏不可见(R-F7)"]
        )
    }

    // MARK: Entry 3 — fix-touch-delivery

    static func evaluateTouchDelivery(dailies: [SpikeRun]) -> FixVerdict {
        let (releaseDailies, nonReleaseCount) = partition(dailies)
        let histogram = pooledTapHistogram(releaseDailies)
        let criteria = [
            shareReadout(id: "tap lag p50", histogram: histogram, percentile: 50, boundMs: 40),
            shareReadout(id: "tap lag p95", histogram: histogram, percentile: 95, boundMs: 120),
        ]
        return FixVerdict(
            entryID: FixObservationRegistry.touchDeliveryFixID,
            state: state(for: criteria, hasAnyReleaseData: !releaseDailies.isEmpty),
            alarm: false,
            readouts: criteria,
            releaseDayCount: releaseDailies.count,
            nonReleaseCount: nonReleaseCount,
            notes: ["逐手势计数(tap 臂),drag 不参与判定;修复前中位 72–208ms"]
        )
    }
}
