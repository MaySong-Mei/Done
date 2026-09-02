//
//  SpikeModel.swift
//  Done
//
//  gh#197 SPIKE — in-app Spike Harness, first slice.
//
//  Pure data + pure logic only. No file I/O (that's SpikeRunStore.swift),
//  no CADisplayLink/UIKit (that's Spike195DetailPerf.swift), no SwiftUI
//  (that's SpikeSettingsView.swift). Kept pure so the registry lookup,
//  run-log algebra, and percentile math can be pinned by hand-reasoned
//  fixtures rather than trusted by inspection.
//
//  `SpikeProbe` at the bottom is the one exception to "pure": together
//  with the `SpikeFeatureFlag` key strings (`spike.<id>.enabled` /
//  `spike.<id>.variant` — no production gate site reads them on this
//  branch, the harness UI's arming toggle does), it
//  is the entire surface production views are allowed to know about the
//  harness. A production call site says `SpikeProbe.emit(.bodyPass("..."))`
//  or holds a flag key, and nothing else — no reference to SpikeRunStore,
//  SpikeRegistry, or any Spike UI type. With no listener attached, `emit` is a single
//  optional-closure nil-check: the zero-cost disabled path.
//

import Foundation

// MARK: - Definition / Scenario / Registry

enum SpikeLifecycle: String, Codable, Equatable {
    case active
    case concluded
    case removed
}

/// Which of the issue's three scenario classes a scenario belongs to —
/// drives which affordance the detail page shows (`[Run]` vs `[Start]` vs
/// an A/B comparison), not measurement mechanics.
enum SpikeScenarioKind: String, Codable, Equatable {
    /// Class 1: harness executes it standalone, no user action needed.
    case automated
    /// Class 2: harness owns the measurement window; the user performs a
    /// real gesture/keyboard/IME interaction inside production UI while
    /// it is armed.
    case userAction
    /// Class 3: subjective A/B/variant comparison, optionally alongside
    /// objective frame metrics.
    case subjective
}

struct SpikeScenario: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: SpikeScenarioKind
    /// Shown to the user before/while armed. For `.userAction` scenarios
    /// this is the entire "what do I do" instruction — there is no
    /// scripted UI automation driving the gesture for them (out of scope
    /// per the issue's own first-slice non-goals).
    let instructions: String
}

/// What a registry entry IS — a measurement probe or a candidate feature.
/// Orthogonal to `SpikeScenarioKind`, which classifies how a MEASUREMENT
/// scenario runs; a feature spike typically has no scenarios at all.
enum SpikeKind: String, Codable, Equatable {
    /// gh#197's original shape: instrumentation armed per scenario, runs
    /// recorded to SpikeRunStore.
    ///
    /// `enabled` allows arming. On this (Fix Watch) branch every
    /// registered measurement spike is measurement-ONLY: the gh#201
    /// round-2 experiment variants that removed production publishes
    /// stayed on the spike branch and were not migrated, so arming a run
    /// here changes no production behaviour.
    case measurement
    /// A candidate feature managed by the harness: `enabled` IS the
    /// feature flag — production gate sites read it and flip behavior.
    ///
    /// Off must be king's shape — that is a REQUIREMENT (gh#165's
    /// ungated round-2 mirror is the incident behind it, on the spike
    /// branch that owns that history).
    ///
    /// No entry on this branch uses this case: the #165/#192/#198
    /// feature spikes stayed on the spike branch. The case (and
    /// `SpikeVariant`/`SpikeFeatureFlag`) is the kill-switch machinery
    /// the harness UI still renders, kept so a parked feature branch can
    /// merge without re-deriving it.
    case featureToggle
}

/// One selectable variant of a feature spike. The selection persists
/// as a plain string under
/// `SpikeFeatureFlag.variantKey(spikeID)`; gate sites that care about the
/// variant read that key the same way they read the enabled key.
struct SpikeVariant: Identifiable, Equatable {
    let id: String
    let title: String
}

struct SpikeDefinition: Identifiable, Equatable {
    let id: String
    let issueNumber: Int?
    let title: String
    let purpose: String
    let scenarios: [SpikeScenario]
    let lifecycle: SpikeLifecycle
    /// Defaults keep every pre-existing (measurement) registration
    /// byte-identical at its call site.
    var kind: SpikeKind = .measurement
    /// Only meaningful for `.featureToggle`. Empty = plain on/off feature;
    /// non-empty = the detail page renders a variant picker and the
    /// feature's gate sites read `SpikeFeatureFlag.variantKey(id)`.
    var variants: [SpikeVariant] = []
}

/// The persisted-key vocabulary shared by the harness UI and production
/// gate sites. `spike.<id>.enabled` predates this helper (SpikeDetailView's
/// toggle idiom); the variant key extends the same shape.
enum SpikeFeatureFlag {
    static func enabledKey(_ spikeID: String) -> String {
        "spike.\(spikeID).enabled"
    }

    static func variantKey(_ spikeID: String) -> String {
        "spike.\(spikeID).variant"
    }
}

/// Compile-time registry: a static array literal, not a runtime
/// registration mechanism and not generated. Adding a spike means adding
/// an entry here and (if it has a `.userAction`/`.automated` scenario
/// meant to actually run) wiring a runner for it — see
/// `Spike195Runner` for the one scenario wired in this slice.
enum SpikeRegistry {
    static let all: [SpikeDefinition] = [
        SpikeDefinition(
            id: Spike195SignalID.spikeID,
            issueNumber: 195,
            title: "High-Frequency Detail Interactions",
            purpose: "Size the cost of the event detail view's per-keystroke persistence path (parent/leaf body passes, store writes, frame timing) before any fix is designed.",
            scenarios: [
                SpikeScenario(
                    id: "reflection-note-40-char",
                    title: "Reflection Note: type 40 characters",
                    kind: .userAction,
                    instructions: "Tap Start below, then open any event's detail view, swipe to the Reflection page, and type at least 40 characters into the Note field. The run ends automatically once 40 characters have been typed, or tap Stop here to end it early."
                ),
            ],
            lifecycle: .active
        ),
        SpikeDefinition(
            id: Spike201SignalID.spikeID,
            issueNumber: 201,
            title: "Effort Tap Latency",
            purpose: "Measure where a DIRECT TAP on the effort scrubber spends its time, now that gh#162 made dragging smooth. Records, per gesture: how long our code saw the finger down, the touch event's delivery lag, the synchronous commit duration, the first display frame after each, and the body/store amplification. Drags recorded in the same run are the rig's positive control.",
            scenarios: [
                SpikeScenario(
                    id: Spike201SignalID.scenarioID,
                    title: "Effort scrubber: 20 taps, then 5 slow drags",
                    kind: .userAction,
                    instructions: "Tap Start, then SCROLL THE CALENDAR once — that alone proves the day-layer probes are alive. Open any event's detail view and swipe to the Reflection page. TAP directly on effort levels 20 times — a normal tap, no sliding, a DIFFERENT level each time, and pause a FULL THREE SECONDS between taps: the phenomenon being measured runs about a second, so a one-second pause is the same length as the thing itself and one tap's settle lands inside the next. THEN do 5 slow drags across the scrubber. Come back here and tap Stop. The drags are not optional: they are the control that proves the instrument can tell a held touch from a live one. Tapping the level that is already selected is not a measurement: the commit short-circuits and the tap writes nothing — it is still recorded and marked noOp, and kept out of the commit aggregates."
                ),
            ],
            lifecycle: .active
            // Fix Watch migration: the round-2 experiment variants
            // (production-publish-removing arms) stayed on the spike
            // branch — their question is answered and post-#201 king
            // ships the coalesced mirror with no gate. This entry is
            // plain `.measurement` with no variants.
        ),
    ]

    static func definition(for id: String) -> SpikeDefinition? {
        all.first { $0.id == id }
    }
}

// MARK: - Run

enum SpikeRunOutcome: String, Codable, Equatable {
    case completed
    case aborted
    case interrupted
}

/// A structured metric value that round-trips through JSON as a bare
/// scalar (`18.4`, not `{"number":18.4}`) so a JSONL line stays readable
/// by a human or an agent grepping the file directly — the issue's own
/// worked example (`p99FrameMs = 18.4`) is what this is trying to look
/// like on disk.
///
/// One numeric case, not separate `.integer`/`.number` cases: Foundation's
/// `JSONEncoder` prints a whole-number `Double` without a decimal point
/// (`16.0` encodes as `16`), which is indistinguishable on decode from a
/// genuine `Int` — a probe confirmed this before the split was removed.
/// Splitting the type by Swift type rather than by JSON shape would have
/// made the tag silently flip on any metric that happens to land on a
/// whole number (an entirely plausible frame-time percentile). Counts and
/// measurements are both just "a number" for this harness's purposes.
enum SpikeMetricValue: Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
}

extension SpikeMetricValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// One run of one scenario. `endedAt == nil` means the run is still open
/// — either genuinely in progress in this process, or (found in a file
/// written by a past process) interrupted and awaiting reconciliation.
/// See `SpikeRunLog` for how two on-disk records (open, then close) for
/// the same `id` collapse into one current `SpikeRun`.
struct SpikeRun: Codable, Identifiable, Equatable {
    let id: UUID
    let spikeID: String
    let scenarioID: String
    var variantID: String?
    let startedAt: Date
    var endedAt: Date?
    let appVersion: String
    let appBuild: String
    /// Best-effort; nil until a build phase stamps a commit SHA into
    /// Info.plist (not implemented in this slice — see the harness
    /// report's decision points).
    let appCommit: String?
    let deviceModel: String
    let osVersion: String
    /// Hard-won constraint (gh#197 comment #1): host time zone has
    /// silently invalidated a measurement before. Recorded so a later
    /// reader can tell whether a tz-sensitive scenario ran under the
    /// device's ambient zone or something unexpected.
    let timeZoneIdentifier: String
    let localeIdentifier: String
    /// Fix Watch R-F4: "debug" / "release" via `#if DEBUG`, stamped by
    /// `SpikeRunContext`. OPTIONAL for append-only JSONL compatibility —
    /// same reasoning as `coActiveSpikeIDs` below: lines written before
    /// the field existed must keep decoding. The verdict evaluator
    /// applies criteria to `"release"` records ONLY; debug (and
    /// unattributed nil) records display separately and never feed a
    /// verdict — Debug commits run ~2× Release, and a mixed population
    /// can produce a false FAILING that reopens an issue for a fix that
    /// holds.
    var buildConfiguration: String? = nil
    /// Spike ids of the OTHER spikes armed at the moment this run armed,
    /// stamped by `SpikeSessionCoordinator.register`. Invariants: the
    /// run's own arming never appears in its own stamp (exclude-self —
    /// the stamp answers "what else was measuring while I measured", and
    /// a run trivially co-exists with itself); an empty array means the
    /// run armed alone; `nil` means the record predates this field. The
    /// run log is append-only and old lines are never migrated, so this
    /// MUST stay optional — `SpikeRunStore.loadRuns` decodes line-by-line
    /// with `try?`, and a required field would silently drop every line
    /// written before the field existed.
    var coActiveSpikeIDs: [String]? = nil
    var metrics: [String: SpikeMetricValue]
    var note: String?
    var outcome: SpikeRunOutcome?
    var abortReason: String?

    var isOpen: Bool { endedAt == nil }
}

// MARK: - Run log algebra (pure)

/// Pure operations over an ordered list of appended `SpikeRun` records
/// (oldest first, exactly the order `SpikeRunStore` reads them off disk
/// in). Kept separate from any file I/O so every rule here is testable
/// against a plain array fixture.
enum SpikeRunLog {
    /// A run may appear as two on-disk records (write-ahead open, then a
    /// closing record) or be re-appended later (a note added after
    /// close). The LATEST record for a given id, in append order, is that
    /// run's current truth; first-seen order is preserved for the id
    /// itself so results stay stable regardless of how many times a run
    /// was re-appended.
    static func collapse(_ records: [SpikeRun]) -> [SpikeRun] {
        var latest: [UUID: SpikeRun] = [:]
        var order: [UUID] = []
        for record in records {
            if latest[record.id] == nil {
                order.append(record.id)
            }
            latest[record.id] = record
        }
        return order.compactMap { latest[$0] }
    }

    /// Runs whose latest known record was never closed. An open record
    /// means one of two things this function cannot tell apart: a run a
    /// PAST process left behind by dying (crash, force-quit, the OS
    /// reclaiming the app while backgrounded — backgrounding alone
    /// orphans nothing, armed runs survive it) — an orphan to close as
    /// interrupted — or a run
    /// the CURRENT process has armed right now, which must be left alone.
    /// Under parallel arming any number of runs may be legitimately open
    /// at once, so callers reconciling to disk own the distinction:
    /// `SpikeRunStore.reconcileInterruptedRuns` takes the currently armed
    /// run ids as exclusions for exactly this reason.
    static func openRuns(in collapsed: [SpikeRun]) -> [SpikeRun] {
        collapsed.filter(\.isOpen)
    }

    /// Rewrites open runs as closed-by-interruption. Pure — returns the
    /// closing records for the caller to append; never mutates its input
    /// and never touches disk.
    static func closeAsInterrupted(_ openRuns: [SpikeRun], closedAt: Date) -> [SpikeRun] {
        openRuns.map { run in
            var closed = run
            closed.endedAt = closedAt
            closed.outcome = .interrupted
            closed.abortReason = "process ended before the scenario finished"
            return closed
        }
    }

    /// Oldest-`startedAt`-dropped retention over already-collapsed runs.
    /// A negative cap is treated as "keep everything" (a misconfiguration
    /// should not silently wipe a spike's history); `cap == 0` keeps
    /// nothing.
    static func applyRetention(_ collapsed: [SpikeRun], cap: Int) -> [SpikeRun] {
        guard cap >= 0 else { return collapsed }
        guard collapsed.count > cap else { return collapsed }
        return Array(collapsed.sorted { $0.startedAt > $1.startedAt }.prefix(cap))
    }
}

// MARK: - Frame statistics (pure)

struct SpikeFrameStats: Codable, Equatable {
    let count: Int
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double
    /// Frames longer than `overThresholdMs`, which is derived from THIS
    /// run's own observed cadence — not from a literal, and not from the
    /// display's advertised maximum.
    ///
    /// Round 1 shipped a hardcoded `> 16.0` and 427 of 447 samples
    /// "exceeded" it. Round 2 replaced the literal with the display's
    /// `maximumFramesPerSecond`, and on the only device it has ever run
    /// on that was strictly worse: the panel advertises 120Hz (threshold
    /// 12.5ms) while the link actually ran at 60Hz (p50 16.67ms), so
    /// 367 of 367 samples counted as late. A threshold that fires on
    /// every sample measures nothing, in either direction. Round 3
    /// derives it from the run's own median frame, which is by
    /// construction the cadence the link achieved.
    let overThresholdCount: Int
    /// The threshold `overThresholdCount` was actually counted against,
    /// carried alongside it so a reader never has to guess.
    let overThresholdMs: Double
    /// 1000 / p50 — the cadence the link ACHIEVED, as opposed to the one
    /// the panel advertises (`displayMaxFPS`). Reported next to it so a
    /// saturated threshold is visible on the JSONL line itself instead of
    /// only in an analysis nobody ran.
    let achievedFramesPerSecond: Double
}

// MARK: - Refresh-rate-derived frame threshold (pure)

/// Turns a run's OWN observed frame cadence into the "this frame was
/// late" threshold, and keeps the display's advertised rate as recorded
/// context beside it. Pure so the arithmetic is pinned by fixture; the one
/// impure part (asking UIKit what the display is) lives in
/// `SpikeFrameProbe`, and it no longer feeds any count.
enum SpikeFrameThreshold {
    /// A frame is counted late once it exceeds this multiple of the run's
    /// own median frame.
    ///
    /// 1.5× is a CHOICE, not a derivation. At a measured 60Hz cadence it
    /// puts the line at 25ms: above the 16.7ms a healthy frame takes, and
    /// below the 33.3ms a genuinely dropped one does. Smaller multiples
    /// (1.1×, 1.2×) also clear a nominal frame — an earlier revision of
    /// this comment claimed 1.5× was "the smallest multiple that cannot
    /// fire", which is simply false. It was picked for the margin it
    /// leaves on BOTH sides. The count that depends on no multiple at all
    /// is `SpikeFrameOvershootTally`.
    static let lateFrameMultiplier: Double = 1.5
    /// Used when the display refuses to name a refresh rate (a
    /// non-positive `maximumFramesPerSecond`). Only ever reported as
    /// context now — round 3 derives no count from the display.
    static let fallbackFramesPerSecond = 60

    static func nominalIntervalMs(maximumFramesPerSecond: Int) -> Double {
        let fps = maximumFramesPerSecond > 0 ? maximumFramesPerSecond : fallbackFramesPerSecond
        return 1_000 / Double(fps)
    }

    /// The late-frame line for a run whose median frame was `medianFrameMs`.
    static func observedLateThresholdMs(medianFrameMs: Double) -> Double {
        medianFrameMs * lateFrameMultiplier
    }

    /// The cadence a run actually achieved, from its own median frame. A
    /// non-positive median means "no usable cadence" rather than an
    /// infinite one.
    static func achievedFramesPerSecond(medianFrameMs: Double) -> Double {
        guard medianFrameMs > 0 else { return 0 }
        return 1_000 / medianFrameMs
    }
}

// MARK: - Touch delivery lag (pure)

/// Converts a `DragGesture.Value.time` into a delivery lag, and keeps the
/// absurd readings visible instead of letting them into the median.
///
/// gh#201 round 1 computed `Date().timeIntervalSince(drag.time)` and got
/// ~8.097e11 ms — about 25.7 years — on every single sample. Measured
/// cause: SwiftUI stamps that `Date` from the event's MACH uptime, i.e.
/// it behaves as `Date(timeIntervalSinceReferenceDate: systemUptime)`,
/// not as a wall clock. Differencing it against `Date()` therefore
/// subtracts two different epochs.
///
/// The conversion here reads the same number in the timebase it is
/// actually in: `CACurrentMediaTime()` (seconds since boot, the same
/// timebase `systemUptime` is on) minus
/// `time.timeIntervalSinceReferenceDate`. The production emitter keeps
/// carrying the raw `Date` so it never has to import QuartzCore just to
/// report a touch.
struct Spike201DeliveryLagTracker: Equatable {
    /// A touch delivered slightly "in the future" is a clock-resolution
    /// artefact, not a finding; a touch older than five seconds is not a
    /// touch this rig can reason about. Outside this window the number is
    /// recorded as implausible rather than admitted — and never clamped,
    /// because a clamped 25-year lag looks exactly like a 5-second one.
    static let minPlausibleMs: Double = -50
    static let maxPlausibleMs: Double = 5_000

    /// How many readings fell outside the plausible window.
    private(set) var implausibleCount = 0
    /// The FIRST implausible reading, kept verbatim. This is the field
    /// that makes a broken epoch self-announcing: 8.097e11 in the run's
    /// metrics is unmistakable, where a count alone would only say
    /// "something was wrong".
    private(set) var firstImplausibleMs: Double?

    static func lagMs(eventTime: Date, mediaTimeNow: Double) -> Double {
        (mediaTimeNow - eventTime.timeIntervalSinceReferenceDate) * 1_000
    }

    static func isPlausible(_ lagMs: Double) -> Bool {
        lagMs >= minPlausibleMs && lagMs <= maxPlausibleMs
    }

    /// Returns the lag to record in the distribution, or `nil` when there
    /// is nothing to record — either no event time was supplied (the
    /// commit brackets have no touch at all) or the reading was
    /// implausible, in which case it is counted here instead.
    mutating func admit(eventTime: Date?, mediaTimeNow: Double) -> Double? {
        guard let eventTime else { return nil }
        let lag = Self.lagMs(eventTime: eventTime, mediaTimeNow: mediaTimeNow)
        guard Self.isPlausible(lag) else {
            implausibleCount += 1
            if firstImplausibleMs == nil { firstImplausibleMs = lag }
            return nil
        }
        return lag
    }
}

/// Frame-time distribution math, ported from the gh#162 device-measurement
/// pattern (CADisplayLink probe alive during the interaction, distribution
/// computed once at END) rather than reinvented. Pure so the
/// interpolation rule is pinned by hand-computed fixtures.
enum SpikeFrameStatistics {
    /// `durationsMs` are frame-to-frame deltas in milliseconds, any order.
    ///
    /// The late-frame threshold is derived HERE, from the same sorted
    /// array the percentiles come from, so there is no wiring left
    /// between "which display is this" and "what counts as late" for a
    /// caller to get wrong — round 2's threshold reached this function
    /// through a parameter, and hardcoding that parameter back to a
    /// literal was a mutation nothing caught.
    static func summarize(durationsMs: [Double]) -> SpikeFrameStats? {
        guard !durationsMs.isEmpty else { return nil }
        let sorted = durationsMs.sorted()
        let p50 = percentile(50, of: sorted)
        let threshold = SpikeFrameThreshold.observedLateThresholdMs(medianFrameMs: p50)
        return SpikeFrameStats(
            count: sorted.count,
            p50Ms: p50,
            p95Ms: percentile(95, of: sorted),
            p99Ms: percentile(99, of: sorted),
            maxMs: sorted[sorted.count - 1],
            overThresholdCount: sorted.filter { $0 > threshold }.count,
            overThresholdMs: threshold,
            achievedFramesPerSecond: SpikeFrameThreshold.achievedFramesPerSecond(medianFrameMs: p50)
        )
    }

    /// `sorted` must already be ascending. Linear interpolation between
    /// the two nearest ranks (the "linear" rule NumPy/Excel default to),
    /// so an even-length array's p50 averages the two middle values
    /// instead of arbitrarily picking one.
    private static func percentile(_ p: Double, of sorted: [Double]) -> Double {
        if sorted.count == 1 { return sorted[0] }
        let rank = (p / 100) * Double(sorted.count - 1)
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))
        if lowerIndex == upperIndex { return sorted[lowerIndex] }
        let weight = rank - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * weight
    }
}

// MARK: - Frame overshoot against the system's own expectation (pure)

/// gh#201 round 3's replacement for `over33msCount`.
///
/// `over33msCount` counted deltas above a literal 33ms — "missed a frame
/// even at 30fps". On a variable-refresh display that literal names
/// nothing the app did: the system is entitled to slow the link down when
/// there is nothing to draw, so a 33ms delta can be the OS's own idle
/// throttling rather than a frame the app failed to produce. Round 2 kept
/// the count for continuity and the device run promptly produced 29 of
/// them on a run whose median frame was 16.7ms, with no way to tell the
/// two causes apart. It is retired rather than reinterpreted.
///
/// The only definition of "late" that survives adaptive refresh is the
/// system's own. `CADisplayLink.targetTimestamp` is when the OS expects
/// the frame being prepared to be displayed; if the NEXT tick's
/// `timestamp` is past that, the deadline the OS itself set was missed —
/// whatever rate it had set it at, and whether or not it changed the rate
/// in between.
///
/// Bounded by construction (count / late-count / max only, no array), so
/// an orphaned probe cannot grow it.
struct SpikeFrameOvershootTally: Equatable {
    /// Overshoot above this counts as late. A healthy link lands within
    /// scheduling jitter of its own target; 1ms is far above that jitter
    /// and far below the shortest nominal interval any shipping display
    /// uses (120Hz = 8.33ms), so it cannot fire on a frame that merely
    /// landed a hair after the target it was given.
    static let toleranceMs: Double = 1.0

    private(set) var sampleCount = 0
    private(set) var lateCount = 0
    private(set) var maxMs: Double = 0

    mutating func admit(_ overshootMs: Double) {
        sampleCount += 1
        if overshootMs > Self.toleranceMs { lateCount += 1 }
        if overshootMs > maxMs { maxMs = overshootMs }
    }
}

// MARK: - Frame sample buffer (pure)

/// Bounded buffer for frame-delta samples. Two independent bounds, both
/// pure (no clock, no display link) so their rules are pinned by fixture
/// tests while the wall-clock probe around them stays untestable-but-thin:
///
///   * CAPACITY — appends past capacity are dropped and remembered as
///     truncation instead of growing the array. A CADisplayLink retains
///     its target, so a probe whose logical owner has died keeps ticking,
///     and before this bound an orphaned probe grew its sample array
///     until the process died.
///   * GAP CANDIDACY — a single delta at or above `gapCandidateMs` is
///     large enough to be a suspension rather than a frame. CADisplayLink
///     pauses while the app is suspended but its timestamp keeps
///     advancing, so the first tick after a resume can record the entire
///     background gap as one "frame" — and armed runs deliberately
///     survive backgrounding, with the user sent into production UI where
///     app-switching is normal.
///
/// Round 2 made DURATION stop deciding suspension on its own: the caller
/// (`SpikeFrameProbe`, via `SpikeFrameTickIngestor`) observes
/// `willResignActive` / `didBecomeActive` and passes that FACT in.
///
///   * over-candidate AND the app had resigned active → a suspension gap.
///     Dropped from the distribution, its DURATION retained in
///     `suspensionGapsMs` (bounded by `maxRetainedGaps`) and counted in
///     `suspensionGapCount`. Consumes no capacity.
///   * over-candidate AND the app stayed active → a REAL STALL. Admitted
///     to the distribution — it is the longest frame that actually
///     happened — and its duration ALSO retained in `activeStallsMs`.
///
/// gh#201 ROUND 3 removes the last way the bound could hide a number.
/// Round 2's bound was 1000ms while the stalls it was measuring came in
/// at 768–1160ms, so the same physical event landed in different buckets
/// on a 4% margin. `largestDeltasMs` now retains the top
/// `maxRetainedLargestDeltas` deltas UNCONDITIONALLY, before any
/// classification, so no placement of the bound can make a large delta
/// invisible; the bound itself moved down, clear of the phenomenon
/// instead of through it (see `SpikeFrameProbe.gapCandidateFrameDeltaMs`).
struct SpikeFrameSampleBuffer: Equatable {
    /// Upper bound on retained GAP durations (each list separately).
    /// Small: these are exceptional events, and an orphaned probe must
    /// not be able to grow them without limit.
    static let maxRetainedGaps = 64
    /// Upper bound on the unconditional top-N delta list.
    static let maxRetainedLargestDeltas = 16

    let capacity: Int
    /// Deltas at or above this are candidates for gap classification, not
    /// automatically recorded as frames. A non-positive bound is treated
    /// as unbounded — a misconfiguration must not silently discard every
    /// sample (the same reasoning as retention's negative-cap rule).
    let gapCandidateMs: Double
    private(set) var samples: [Double] = []
    /// True once at least one append was dropped by the CAPACITY bound.
    /// Surfaced into the run's metrics as `frameSamplesTruncated` so a
    /// truncated distribution can never masquerade as a complete one.
    private(set) var isTruncated = false
    /// How many over-bound deltas were classified as SUSPENSION gaps and
    /// dropped. Not the same quantity round 1's `droppedGapCount` was —
    /// that one also swallowed the active-thread stalls below — which is
    /// why the metric key changed with it.
    private(set) var suspensionGapCount = 0
    /// Durations of those suspension gaps, oldest first, capped at
    /// `maxRetainedGaps`.
    private(set) var suspensionGapsMs: [Double] = []
    /// Durations of over-candidate deltas that happened while the app was
    /// ACTIVE, i.e. real main-thread stalls. These are also present in
    /// `samples`; the separate list exists so a reader does not have to
    /// re-derive which of the samples crossed the bound.
    private(set) var activeStallsMs: [Double] = []
    /// The largest deltas seen, descending, capped at
    /// `maxRetainedLargestDeltas` — recorded BEFORE any bound or
    /// lifecycle classification, so this list cannot be changed by where
    /// the gap-candidate bound sits. Suspensions appear here too; that is
    /// the point (`frameSuspensionGapCount` says how many there were).
    private(set) var largestDeltasMs: [Double] = []

    init(capacity: Int, gapCandidateMs: Double) {
        self.capacity = max(0, capacity)
        self.gapCandidateMs = gapCandidateMs > 0 ? gapCandidateMs : .infinity
    }

    /// `resignedActiveSinceLastSample` is the caller's LIFECYCLE FACT, not
    /// a guess: true only when `UIApplication.willResignActiveNotification`
    /// has fired and no `didBecomeActive` has followed it. Defaults to
    /// `false` — "the app stayed active" — which is the honest reading for
    /// any caller that does not observe lifecycle at all.
    mutating func append(_ value: Double, resignedActiveSinceLastSample: Bool = false) {
        noteLargestDelta(value)
        if value >= gapCandidateMs {
            if resignedActiveSinceLastSample {
                suspensionGapCount += 1
                if suspensionGapsMs.count < Self.maxRetainedGaps {
                    suspensionGapsMs.append(value)
                }
                return
            }
            if activeStallsMs.count < Self.maxRetainedGaps {
                activeStallsMs.append(value)
            }
            // Falls through: a stall the app was awake for IS a frame time.
        }
        guard samples.count < capacity else {
            isTruncated = true
            return
        }
        samples.append(value)
    }

    /// Insertion into a descending top-N list. Unconditional: every delta
    /// is offered, including the ones classified away as suspensions.
    private mutating func noteLargestDelta(_ value: Double) {
        guard let insertAt = largestDeltasMs.firstIndex(where: { value > $0 }) else {
            if largestDeltasMs.count < Self.maxRetainedLargestDeltas {
                largestDeltasMs.append(value)
            }
            return
        }
        largestDeltasMs.insert(value, at: insertAt)
        if largestDeltasMs.count > Self.maxRetainedLargestDeltas {
            largestDeltasMs.removeLast()
        }
    }

    /// Returns everything collected and resets the buffer to its empty
    /// state. This is what makes "a second stop returns nothing" true by
    /// construction in `SpikeFrameProbe.stopAndSummarize` rather than
    /// true by comment.
    mutating func drain() -> (
        samples: [Double],
        isTruncated: Bool,
        suspensionGapCount: Int,
        suspensionGapsMs: [Double],
        activeStallsMs: [Double],
        largestDeltasMs: [Double]
    ) {
        defer {
            samples = []
            isTruncated = false
            suspensionGapCount = 0
            suspensionGapsMs = []
            activeStallsMs = []
            largestDeltasMs = []
        }
        return (samples, isTruncated, suspensionGapCount, suspensionGapsMs, activeStallsMs, largestDeltasMs)
    }
}

// MARK: - Frame tick bookkeeping (pure)

/// Everything `SpikeFrameProbe` does with a tick, minus the tick source.
/// Every timestamp is passed in and there is no clock inside, so the parts
/// that decide what a delta MEANS are pinned by fixture.
///
/// This type exists because of a mutation that survived 32 tests: passing
/// a literal `false` where the probe passed its lifecycle fact. That
/// mutation reclassifies every background gap as a real main-thread stall
/// — it fabricates this spike's headline number — and it survived because
/// the fact was read and passed inside an `@objc` display-link callback
/// that no test could reach. With the fact OWNED here, there is nothing
/// left to pass: the probe hands over two timestamps and two lifecycle
/// edges, and every rule that consumes them is testable.
struct SpikeFrameTickIngestor: Equatable {
    private(set) var buffer: SpikeFrameSampleBuffer
    private(set) var overshoot = SpikeFrameOvershootTally()
    /// True from `willResignActive` until the matching `didBecomeActive`.
    /// Cleared at resume rather than on the next tick on purpose — the
    /// dangerous ordering is a tick that lands after the process resumes
    /// but before the notification, and only a flag that is still set at
    /// that moment classifies its enormous delta correctly.
    private(set) var hasResignedActive = false
    /// gh#201 round 3: counted UNCONDITIONALLY, including zero. Round 1
    /// had to assert "the app never backgrounded" in prose; a run that
    /// backgrounded and one that did not are otherwise indistinguishable,
    /// because the normal outcome of a real backgrounding — a re-baselined
    /// timebase and no computed delta at all — leaves no marker behind.
    private(set) var resignActiveCount = 0
    private(set) var didBecomeActiveCount = 0

    private var lastTimestamp: Double?
    private var lastTargetTimestamp: Double?

    init(capacity: Int, gapCandidateMs: Double) {
        buffer = SpikeFrameSampleBuffer(capacity: capacity, gapCandidateMs: gapCandidateMs)
    }

    mutating func noteWillResignActive() {
        resignActiveCount += 1
        hasResignedActive = true
        rebaseline()
    }

    mutating func noteDidBecomeActive() {
        didBecomeActiveCount += 1
        hasResignedActive = false
        rebaseline()
    }

    /// One display-link tick. `targetTimestamp` is the OS's own statement
    /// of when it expects the frame being prepared to be shown; the next
    /// tick's `timestamp` measured against it is the overshoot.
    mutating func ingest(timestamp: Double, targetTimestamp: Double) {
        if let last = lastTimestamp {
            buffer.append(
                (timestamp - last) * 1_000,
                resignedActiveSinceLastSample: hasResignedActive
            )
        }
        if let lastTarget = lastTargetTimestamp {
            overshoot.admit((timestamp - lastTarget) * 1_000)
        }
        lastTimestamp = timestamp
        lastTargetTimestamp = targetTimestamp
    }

    /// A lifecycle edge invalidates the timebase: the delta spanning it is
    /// not a frame, and the overshoot spanning it is not a missed
    /// deadline. Dropping BOTH is what stops a suspension from being
    /// counted twice — once as a stall, once as a late frame.
    private mutating func rebaseline() {
        lastTimestamp = nil
        lastTargetTimestamp = nil
    }

    mutating func drain() -> SpikeFrameTickDrain {
        let drained = buffer.drain()
        let result = SpikeFrameTickDrain(
            samples: drained.samples,
            isTruncated: drained.isTruncated,
            suspensionGapCount: drained.suspensionGapCount,
            suspensionGapsMs: drained.suspensionGapsMs,
            activeStallsMs: drained.activeStallsMs,
            largestDeltasMs: drained.largestDeltasMs,
            overshoot: overshoot,
            resignActiveCount: resignActiveCount,
            didBecomeActiveCount: didBecomeActiveCount
        )
        overshoot = SpikeFrameOvershootTally()
        resignActiveCount = 0
        didBecomeActiveCount = 0
        hasResignedActive = false
        rebaseline()
        return result
    }
}

/// Everything one ingestor collected, handed over in a single value so a
/// caller cannot pick up half of it.
struct SpikeFrameTickDrain: Equatable {
    let samples: [Double]
    let isTruncated: Bool
    let suspensionGapCount: Int
    let suspensionGapsMs: [Double]
    let activeStallsMs: [Double]
    let largestDeltasMs: [Double]
    let overshoot: SpikeFrameOvershootTally
    let resignActiveCount: Int
    let didBecomeActiveCount: Int
}

// MARK: - Production instrumentation seam

/// Everything a production call site can report through `SpikeProbe`.
/// Deliberately a small set of GENERIC cases rather than one case per
/// measurement — adding a signal kind does not mean touching every
/// existing call site's type. (It started at two; gh#201 added
/// `.gesture`, which is what that design was for.)
enum SpikeSignal: Equatable {
    /// One body/render pass of a named view, for counting re-renders.
    case bodyPass(String)
    /// A named text field's current length, for scenarios that end at a
    /// character-count threshold instead of a fixed duration.
    case textLength(String, Int)
    /// One phase sample of a tracked gesture (gh#201). `eventTime` is the
    /// touch event's OWN wall-clock timestamp as SwiftUI reports it, kept
    /// separate from the moment a listener runs so the two can be
    /// subtracted into a delivery lag; `nil` on the phases that are not a
    /// touch at all (the commit brackets).
    case gesture(String, SpikeGesturePhase, eventTime: Date?, locationX: Double)
    /// Fix Watch Tier-1: an anonymous O(1) event for a resident counter.
    /// The string accepts anything; the resident's FIXED-KEY counter set
    /// (`ResidentCounterSet`) bumps nothing for an unknown id — that
    /// closed key set is the load-bearing privacy guard, so no free-form
    /// string can ever reach a JSONL line through this case.
    case counter(String)
    /// Fix Watch Tier-1: a TRIPWIRE observation — the violation half of a
    /// violation/liveness pair guarding an invariant a fix established.
    /// Same zero-cost nil-check as every other case when nothing is
    /// registered; same fixed-key guard as `.counter`.
    case invariant(String)
}

/// Zero-cost unless a spike scenario has attached a listener: `emit` is
/// one optional-closure check. Lives in Models (not Services/Spike or
/// Views) specifically so production feature files can reference it
/// without importing anything that looks like "the spike subsystem" —
/// see gh#197 architecture question 2.
///
/// `onSignal` is assigned by `SpikeSessionCoordinator` and by nothing
/// else. Runners never touch this seam — they register with the
/// coordinator, whose single fan-out closure delivers to every armed
/// listener. That single-writer rule is what makes it impossible for two
/// concurrently armed runs to clobber each other's listener, and the
/// coordinator restores `nil` the moment the last listener unregisters,
/// so the disabled path stays exactly one optional-closure nil-check.
enum SpikeProbe {
    static var onSignal: ((SpikeSignal) -> Void)?

    @inline(__always)
    static func emit(_ signal: SpikeSignal) {
        onSignal?(signal)
    }

    // gh#201 round 3 REMOVED `isArmed`. It answered "is ANY spike armed",
    // and the one production gate that used it (the effort-commit
    // experiment) therefore changed behaviour whenever an unrelated
    // spike armed: leaving #201 enabled with a variant picked and then
    // starting a #195 run silently removed a publish from production
    // while #195's record said nothing about it. The gate now reads
    // `Spike201EffortTap.armedExperiment`, which is non-nil only while
    // the #201 runner itself holds a run — see that property's doc.
}

/// Signal ids the #195 integration shares between `CalendarEventDetailView`
/// (the emitter) and `Spike195Runner` (the one listener). Centralized so a
/// typo in either place can't silently desync them into "armed but nothing
/// is ever counted."
enum Spike195SignalID {
    static let spikeID = "detail-perf-195"
    static let parentBody = "calendarEventDetail.body"
    static let reflectionNoteLeaf = "calendarEventDetail.reflectionNote.leaf"
    static let reflectionNoteLength = "calendarEventDetail.reflectionNote"
}

/// Signal ids the gh#201 integration shares between the effort scrubber
/// (`CalendarEffortScrubber`'s gesture closures + `CalendarEffortQuickControl`'s
/// commit bracket, the emitters) and `Spike201Runner` (the one listener).
/// Same anti-typo reason as `Spike195SignalID`: a mismatch here is "armed
/// but nothing is ever counted", which reads exactly like a clean result.
enum Spike201SignalID {
    static let spikeID = "effort-tap-201"
    static let scenarioID = "effort-tap-20x"
    /// The one gesture stream this spike tracks.
    static let effortScrubber = "calendarEffortScrubber"
    /// Round 2. Round 1 could only INFER that the ~960ms of held main
    /// thread after `commitEnd` was the calendar page re-rendering
    /// underneath the pushed detail page; nothing observed it. These two
    /// ids make it observable, and they are counted SEPARATELY from
    /// `Spike195SignalID.parentBody` (the detail page's own body), whose
    /// meaning is unchanged.
    ///
    /// `calendarPageBody` fires once per `CalendarPageView.body`
    /// evaluation — the whole calendar surface, one emit per render.
    static let calendarPageBody = "calendarPage.body"
    /// `calendarDayLayerUpdate` fires once per `CalendarDayLayerView`
    /// SwiftUI→UIKit bridge update — i.e. once per mounted DAY COLUMN
    /// that SwiftUI ASKED to re-apply.
    ///
    /// The mounted column count is `2 * calendarRenderBuffer(daysCount:)
    /// + 1`, and `calendarRenderBuffer` floors at 7, so it is 15 in day
    /// mode AND 15 in week mode. (An earlier revision of this comment
    /// said "1 in day mode, up to 7 in week mode". The round-2 device run
    /// settled it: `dayLayer / pageBody` was exactly 15 on every one of
    /// the 8 gestures.)
    ///
    /// This emit sits BEFORE `DayLayerHostView.apply`, which early-returns
    /// at `guard currentModel != model`. So it counts requests, not work:
    /// 15 counted passes are consistent with zero rendering. The emit that
    /// counts work is `calendarDayLayerApplied`, and it is the PAIR that
    /// answers round 3's question — neither number means anything alone.
    static let calendarDayLayerUpdate = "calendarPage.dayLayer.update"
    /// Round 3. Fires only AFTER `DayLayerHostView.apply`'s
    /// `guard currentModel != model` early return, i.e. once per day
    /// column whose model actually CHANGED and which therefore did layout
    /// and paint work. Deliberately NOT inside the per-occurrence layer
    /// loop: an emit that fires two hundred times per render would measure
    /// the instrument, not the app.
    static let calendarDayLayerApplied = "calendarPage.dayLayer.applied"
}

// MARK: - gh#201 effort-tap latency (pure)

/// Which point of a tracked gesture a `SpikeSignal.gesture` sample marks.
///
/// The four phases exist because gh#201's whole question is WHERE the
/// time goes on a tap, and the three candidate answers live in three
/// different gaps:
///
///   * `changed` → `ended`: how long our code saw the finger down. A real
///     human tap is 60–120ms. If this collapses to ~0 the touch was held
///     by an enclosing scroll view and delivered in one batch at lift —
///     dead time BEFORE any of our code runs, which no commit-path
///     optimization can reach.
///   * `ended` → `commitStart`: SwiftUI's own dispatch of the
///     `@GestureState` reset that triggers the commit.
///   * `commitStart` → `commitEnd`: the synchronous durable write
///     (store mutation + two full saves + publish), i.e. gh#201's own
///     stated hypothesis.
enum SpikeGesturePhase: String, Codable, Equatable {
    case changed
    case ended
    case commitStart
    case commitEnd
}

/// One tracked gesture's forensic record. Every time here is
/// `CACurrentMediaTime()` SECONDS (seconds since boot, monotonic), never
/// `Date` — mixing the two is the classic way a latency rig produces
/// precise, reproducible, meaningless numbers, and round 1 did exactly
/// that.
///
/// The delivery-lag fields are the one place a touch's own stamp enters.
/// SwiftUI's `DragGesture.Value.time` is NOT on the wall-clock epoch: it
/// behaves as `Date(timeIntervalSinceReferenceDate: systemUptime)`.
/// Round 1 differenced it against `Date()` and got ~8.097e11 ms (about
/// 25.7 years) on every sample. The caller reads it in the media timebase
/// it is actually on before it ever reaches this type — see
/// `Spike201DeliveryLagTracker`.
struct Spike201GestureRecord: Equatable {
    let index: Int
    let firstChangedAt: Double
    let firstLocationX: Double
    /// How many `.onChanged` callbacks this gesture produced.
    ///
    /// NOT a tap witness, despite round 1's fixture reading as if it were.
    /// On device a STATIONARY finger produces exactly one `.onChanged`
    /// whether SwiftUI delivered it live or replayed it in a batch at
    /// lift — there is no second sample to produce, because nothing
    /// moved. It still discriminates DRAGS (a live-delivered scrub emits
    /// one per movement sample; a batched one would not), which is why it
    /// is kept.
    ///
    /// The tap witnesses are `changedToEndedMs` and `firstDeliveryLagMs`.
    var changedCount: Int = 1
    var lastChangedAt: Double
    var maxLocationDelta: Double = 0
    var endedAt: Double?
    var commitStartedAt: Double?
    var commitEndedAt: Double?
    /// Wall-clock gap between the touch event's own timestamp and the
    /// instant our handler ran, for the FIRST `.changed` of the gesture.
    /// `nil` when SwiftUI supplied no event time. This is the direct
    /// instrument for held-touch delivery; `changedToEndedMs` is the
    /// independent one. They are recorded separately on purpose — if
    /// SwiftUI turns out to stamp `DragGesture.Value.time` at DELIVERY
    /// rather than at the original touch, this number degenerates to ~0
    /// and says nothing, while the other still decides.
    var firstDeliveryLagMs: Double?
    /// The SAME first-`.changed` reading, but BEFORE the plausibility
    /// filter — recorded unconditionally, including when it is absurd.
    ///
    /// gh#201 round 3: the filter exists so one bad reading cannot move a
    /// median, but a filtered-away number is a number the file no longer
    /// contains, and round 1's verdict on H1 came from the MIN-NORMALISED
    /// relative lag, which is immune to any constant epoch offset. Keeping
    /// the raw column makes round 3 a strict superset of round 1 under
    /// every epoch hypothesis, including ones nobody has thought of yet.
    var firstRawDeliveryLagMs: Double?
    /// Largest ADMITTED delivery lag across the gesture's `.changed`
    /// samples. Round 2 computed and stored this and then reported it
    /// nowhere — it reached neither `summarize` nor `csv`.
    var maxDeliveryLagMs: Double?
    /// First display-link tick strictly after `firstChangedAt` — the
    /// earliest opportunity the preview had to reach the screen.
    var firstFrameAfterFirstChangedMs: Double?
    /// First display-link tick strictly after `commitEndedAt`.
    var firstFrameAfterCommitMs: Double?
    /// Signals attributed to this gesture: from its first `.changed`
    /// until the NEXT gesture starts (or the run ends), so a gesture's
    /// post-commit settle counts toward it. That attribution window is
    /// only meaningful if the user pauses between gestures, which is what
    /// the scenario instructions ask for.
    var bodyPasses: Int = 0
    /// gh#201 round 2: body passes of the CALENDAR PAGE, which stays
    /// mounted under the pushed detail page. Counted separately from
    /// `bodyPasses` (the detail page's own) — conflating them would
    /// destroy the only question round 2 exists to answer.
    var calendarPageBodyPasses: Int = 0
    /// gh#201 round 2: `CalendarDayLayerView` bridge updates SwiftUI
    /// ASKED for, i.e. day columns offered a new model. Counts requests,
    /// not work — see `Spike201SignalID.calendarDayLayerUpdate`.
    var calendarDayLayerPasses: Int = 0
    /// gh#201 round 3: day columns that got PAST `apply`'s
    /// `guard currentModel != model` and actually re-laid-out. The pair
    /// (`calendarDayLayerPasses`, this) is the answer round 3 exists for;
    /// round 2 could only report the first half and 195 of them were
    /// consistent with zero rendering work.
    var calendarDayLayerAppliedPasses: Int = 0
    /// Durable commits attributed to this gesture, ALL slots. Round 2
    /// counted only this, and the `no-colordepth-mirror` variant's whole
    /// built-in cross-check was "it drops 2 → 1" — which one unrelated
    /// background commit in any of the other seven slots inflates back to
    /// 2, making a working variant read as inert.
    var slotWrites: Int = 0
    /// The `.calendarEvents` commits specifically — the slot the
    /// colorDepth/density mirror owns. This is the variant cross-check
    /// that cannot be spoofed by an unrelated slot.
    var calendarEventSlotWrites: Int = 0
    /// The `.calendarEventLogRecords` commits specifically — the
    /// unconditional `saveCalendarEventLogRecords()` every
    /// `upsertLogRecord` performs. Exactly 1 per writing tap, in every
    /// variant; anything else means the attribution window is wrong.
    var logRecordSlotWrites: Int = 0

    var isTimingOpen: Bool { commitEndedAt == nil }

    var changedToEndedMs: Double? {
        endedAt.map { ($0 - firstChangedAt) * 1000 }
    }

    var endedToCommitMs: Double? {
        guard let endedAt, let commitStartedAt else { return nil }
        return (commitStartedAt - endedAt) * 1000
    }

    var commitMs: Double? {
        guard let commitStartedAt, let commitEndedAt else { return nil }
        return (commitEndedAt - commitStartedAt) * 1000
    }
}

/// Segments a stream of gesture phase signals into per-gesture records.
/// Pure and clock-free (every timestamp is passed in), so the segmentation
/// rules are pinned by fixtures rather than trusted — including the two
/// fixtures that matter most: a HELD-delivery tap (Δ≈0 between its first
/// `.changed` and its `.ended`) and a LIVE-delivery tap (Δ≈80ms) must come
/// out distinguishable, or the rig cannot answer the question it was built
/// for.
///
/// gh#201 round 2 corrects what round 2's predecessor implied here: the
/// discriminator is that Δ (`changedToEndedMs`), together with the
/// delivery lag. It is NOT `changedCount` — a stationary finger emits
/// exactly one `.onChanged` in either world (see that field's own doc).
struct Spike201GestureLog: Equatable {
    /// Points of finger travel at or below which a gesture is classified a
    /// tap. Well above touch jitter on a stationary finger, well below any
    /// deliberate scrub across a full-width track.
    static let tapDisplacementThreshold: Double = 12

    private(set) var records: [Spike201GestureRecord] = []

    /// Run-level totals, counted from ARM rather than attributed to any
    /// gesture (gh#201 round 3).
    ///
    /// A per-gesture zero and a dead wire look identical on the line, and
    /// two of the three signals round 2 added are emitted from surfaces
    /// that fire whether or not a gesture is in flight. These counters
    /// make the difference readable: `runCalendarPageBodyTotal == 0` means
    /// the instrument never fired at all (navigating into the detail page
    /// alone makes it non-zero — `.navigationDestination(item:)` hangs off
    /// `CalendarPageView.body`), while `> 0` with all-zero per-gesture
    /// counts is a real finding about where the work is NOT.
    private(set) var runDetailBodyTotal = 0
    private(set) var runCalendarPageBodyTotal = 0
    private(set) var runCalendarDayLayerTotal = 0
    private(set) var runCalendarDayLayerAppliedTotal = 0
    private(set) var runSlotWriteTotal = 0

    /// The record a new phase signal belongs to for TIMING — the last one
    /// that has not yet seen its `commitEnd`.
    private var timingOpenIndex: Int? {
        guard let last = records.indices.last, records[last].isTimingOpen else { return nil }
        return last
    }

    mutating func ingest(
        phase: SpikeGesturePhase,
        at time: Double,
        locationX: Double,
        deliveryLagMs: Double?,
        rawDeliveryLagMs: Double? = nil
    ) {
        switch phase {
        case .changed:
            if let index = timingOpenIndex {
                records[index].changedCount += 1
                records[index].lastChangedAt = time
                records[index].maxLocationDelta = max(
                    records[index].maxLocationDelta,
                    abs(locationX - records[index].firstLocationX)
                )
                if let lag = deliveryLagMs {
                    records[index].maxDeliveryLagMs = max(records[index].maxDeliveryLagMs ?? lag, lag)
                }
            } else {
                var record = Spike201GestureRecord(
                    index: records.count,
                    firstChangedAt: time,
                    firstLocationX: locationX,
                    lastChangedAt: time
                )
                record.firstDeliveryLagMs = deliveryLagMs
                record.firstRawDeliveryLagMs = rawDeliveryLagMs
                record.maxDeliveryLagMs = deliveryLagMs
                records.append(record)
            }
        case .ended:
            guard let index = timingOpenIndex else { return }
            records[index].endedAt = time
        case .commitStart:
            // A commit with no gesture open is real and must be ignored,
            // not attached to the previous gesture: the scrubber also
            // commits from `CalendarEffortQuickControl`'s scenePhase
            // backgrounding flush, which has no gesture at all.
            guard let index = timingOpenIndex else { return }
            records[index].commitStartedAt = time
        case .commitEnd:
            guard let index = timingOpenIndex, records[index].commitStartedAt != nil else { return }
            records[index].commitEndedAt = time
        }
    }

    /// A display-link tick. Fills the two "first frame after X" fields of
    /// EVERY record still missing one, each exactly once.
    ///
    /// gh#201 round 3. Round 2 filled `records.indices.last` only, so the
    /// instant the next gesture started, the previous record's
    /// `firstFrameAfterCommitMs` was frozen at nil forever and
    /// `compactMap` removed it from the aggregates. On device that lost
    /// BOTH frame columns of tap 1 outright. The loss is biased toward the
    /// longest stalls — the longer the storm runs, the likelier the user
    /// has already begun the next tap — so a fix candidate that SHORTENED
    /// the storm could have read as a regression. `Spike201Metrics` also
    /// emits a count of the taps whose fields stayed nil, so the remaining
    /// loss can never be invisible.
    ///
    /// O(records) per tick, on a log whose records are one per human
    /// gesture: a 20-tap run is 20 comparisons per frame boundary, and
    /// the loop is only reached while a run is armed.
    mutating func noteFrame(at time: Double) {
        for index in records.indices {
            if records[index].firstFrameAfterFirstChangedMs == nil,
               time > records[index].firstChangedAt {
                records[index].firstFrameAfterFirstChangedMs = (time - records[index].firstChangedAt) * 1000
            }
            if let commitEndedAt = records[index].commitEndedAt,
               records[index].firstFrameAfterCommitMs == nil,
               time > commitEndedAt {
                records[index].firstFrameAfterCommitMs = (time - commitEndedAt) * 1000
            }
        }
    }

    /// SINGLE SOURCE for the `.bodyPass` signal-id → counter mapping.
    /// The runner calls this rather than switching on the id itself, so
    /// there is exactly one place where "which view does this id belong
    /// to" is decided — and that place is pure, so the mapping is pinned
    /// by fixture instead of trusted. An unknown id is ignored: the
    /// coordinator fans every armed run's signals to every listener, so a
    /// co-armed #195 run's leaf id legitimately arrives here.
    mutating func noteBodyPass(signalID: String) {
        switch signalID {
        case Spike195SignalID.parentBody:
            runDetailBodyTotal += 1
            noteBodyPass()
        case Spike201SignalID.calendarPageBody:
            runCalendarPageBodyTotal += 1
            noteCalendarPageBodyPass()
        case Spike201SignalID.calendarDayLayerUpdate:
            runCalendarDayLayerTotal += 1
            noteCalendarDayLayerPass()
        case Spike201SignalID.calendarDayLayerApplied:
            runCalendarDayLayerAppliedTotal += 1
            noteCalendarDayLayerAppliedPass()
        default:
            break
        }
    }

    mutating func noteBodyPass() {
        guard let index = records.indices.last else { return }
        records[index].bodyPasses += 1
    }

    mutating func noteCalendarPageBodyPass() {
        guard let index = records.indices.last else { return }
        records[index].calendarPageBodyPasses += 1
    }

    mutating func noteCalendarDayLayerPass() {
        guard let index = records.indices.last else { return }
        records[index].calendarDayLayerPasses += 1
    }

    mutating func noteCalendarDayLayerAppliedPass() {
        guard let index = records.indices.last else { return }
        records[index].calendarDayLayerAppliedPasses += 1
    }

    /// Fix Watch R-F1: the resident keeps this log as a bounded ROLLING
    /// ring — the oldest records drop once a completed gesture pushes the
    /// count past the cap. Called only between gestures (at `.commitEnd`
    /// completion), never mid-gesture, so `timingOpenIndex`'s
    /// last-record contract is preserved. `records[i].index` keeps its
    /// original mint (indices are labels, not positions); manual runs
    /// never call this and keep every record.
    mutating func trimRecords(toLast cap: Int) {
        guard cap >= 0, records.count > cap else { return }
        records.removeFirst(records.count - cap)
    }

    /// One durable commit. The SLOT is the point (gh#201 round 3): the
    /// coordinator already hands it to the closure and round 2 discarded
    /// it, leaving the variant cross-check open to inflation by any of the
    /// other seven slots committing for an unrelated reason.
    mutating func noteSlotWrite(slot: StorageSlot) {
        runSlotWriteTotal += 1
        guard let index = records.indices.last else { return }
        records[index].slotWrites += 1
        switch slot {
        case .calendarEvents:
            records[index].calendarEventSlotWrites += 1
        case .calendarEventLogRecords:
            records[index].logRecordSlotWrites += 1
        default:
            break
        }
    }
}

/// Aggregation + on-disk forensics for a gh#201 run. Taps and drags are
/// summarized SEPARATELY and both are reported: the drags are the rig's
/// positive control. A run where taps and drags produce the same
/// `changedToEnded` distribution is a broken instrument, not a finding —
/// and that is only visible if both are in the file.
enum Spike201Metrics {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func isTap(_ record: Spike201GestureRecord) -> Bool {
        record.maxLocationDelta <= Spike201GestureLog.tapDisplacementThreshold
    }

    /// A tap that committed nothing durable. Tapping the level that is
    /// already selected short-circuits the commit, so the gesture is real
    /// but the phenomenon under measurement never happened.
    ///
    /// The round-2 device run had two of these among eight (taps 0 and 2),
    /// and their 16.4ms / 4.5ms commits sat inside a reported
    /// `tapCommitMsMedian` of 78.7ms. They are excluded from the commit
    /// aggregates and reported as their own arm — but they stay in the
    /// CSV, because tap 0 (no write, no storm, 33.7ms lag, 0 body passes)
    /// is the best internal control the run produced.
    static func isNoOp(_ record: Spike201GestureRecord) -> Bool {
        record.slotWrites == 0
    }

    /// Totals counted from ARM, not attributed to any gesture — the answer
    /// to "is this zero a finding or a dead wire?" (gh#201 round 3).
    static func runTotals(_ log: Spike201GestureLog) -> [String: SpikeMetricValue] {
        [
            "runDetailBodyTotal": .number(Double(log.runDetailBodyTotal)),
            "runCalendarPageBodyTotal": .number(Double(log.runCalendarPageBodyTotal)),
            "runCalendarDayLayerTotal": .number(Double(log.runCalendarDayLayerTotal)),
            "runCalendarDayLayerAppliedTotal": .number(Double(log.runCalendarDayLayerAppliedTotal)),
            "runSlotWriteTotal": .number(Double(log.runSlotWriteTotal)),
        ]
    }

    static func summarize(_ records: [Spike201GestureRecord]) -> [String: SpikeMetricValue] {
        let taps = records.filter(isTap)
        let drags = records.filter { !isTap($0) }
        let writingTaps = taps.filter { !isNoOp($0) }
        let noOpTaps = taps.filter(isNoOp)
        var metrics: [String: SpikeMetricValue] = [
            "gestureCount": .number(Double(records.count)),
            "tapCount": .number(Double(taps.count)),
            "dragCount": .number(Double(drags.count)),
            // gh#201 round 3 — the four ways a tap silently leaves an
            // aggregate. All emitted unconditionally, zero included: an
            // absent key is indistinguishable from a rig that never
            // looked.
            "tapsWithZeroSlotWritesCount": .number(Double(noOpTaps.count)),
            // A CANCELLED tap has no `.onEnded` at all — the scrubber's
            // commit fires from the `@GestureState` reset, and
            // cancellation is routine inside the reflection `ScrollView`.
            // Such a tap vanishes from `tapChangedToEndedMs*` with nothing
            // to mark its absence unless this is on the line.
            "tapsWithoutEndedCount": .number(Double(taps.filter { $0.endedAt == nil }.count)),
            "tapsMissingFrameAfterChangedCount": .number(
                Double(taps.filter { $0.firstFrameAfterFirstChangedMs == nil }.count)
            ),
            "tapsMissingFrameAfterCommitCount": .number(
                Double(taps.filter { $0.firstFrameAfterCommitMs == nil }.count)
            ),
        ]

        func put(_ key: String, _ values: [Double], includeMin: Bool = false) {
            guard let med = median(values), let maxValue = values.max(), let minValue = values.min() else { return }
            metrics["\(key)Median"] = .number(med)
            metrics["\(key)Max"] = .number(maxValue)
            if includeMin {
                metrics["\(key)Min"] = .number(minValue)
            }
        }

        // THE gh#201 discriminator, and its positive control right next to
        // it. Min is included for taps because a single ~0 sample among 20
        // is already proof that at least one touch was held: no human tap
        // lasts zero milliseconds.
        put("tapChangedToEndedMs", taps.compactMap(\.changedToEndedMs), includeMin: true)
        put("dragChangedToEndedMs", drags.compactMap(\.changedToEndedMs))
        // Recorded, but NOT a tap witness — see
        // `Spike201GestureRecord.changedCount`. Kept because it still
        // discriminates the DRAG control right below it.
        put("tapChangedSamples", taps.map { Double($0.changedCount) }, includeMin: true)
        put("dragChangedSamples", drags.map { Double($0.changedCount) })
        // Min on BOTH delivery-lag arms: round 1's verdict came from the
        // MIN-normalised relative lag, so the minimum is the load-bearing
        // sample, and round 2 emitted it for neither.
        put("tapDeliveryLagMs", taps.compactMap(\.firstDeliveryLagMs), includeMin: true)
        put("dragDeliveryLagMs", drags.compactMap(\.firstDeliveryLagMs), includeMin: true)
        // The unfiltered readings, so the file stays a superset of round 1
        // under every epoch hypothesis.
        put("tapRawDeliveryLagMs", taps.compactMap(\.firstRawDeliveryLagMs), includeMin: true)
        put("dragRawDeliveryLagMs", drags.compactMap(\.firstRawDeliveryLagMs), includeMin: true)
        // Round 2 computed and stored `maxDeliveryLagMs` and reported it
        // nowhere.
        put("tapMaxDeliveryLagMs", taps.compactMap(\.maxDeliveryLagMs), includeMin: true)
        put("dragMaxDeliveryLagMs", drags.compactMap(\.maxDeliveryLagMs))
        put("tapEndedToCommitMs", taps.compactMap(\.endedToCommitMs))
        // Two arms, never one population: a no-op tap's commit measures the
        // short-circuit, not the durable write.
        put("tapWritingCommitMs", writingTaps.compactMap(\.commitMs), includeMin: true)
        put("tapNoOpCommitMs", noOpTaps.compactMap(\.commitMs), includeMin: true)
        put("dragCommitMs", drags.compactMap(\.commitMs))
        put("tapFirstFrameAfterChangedMs", taps.compactMap(\.firstFrameAfterFirstChangedMs))
        put("tapFirstFrameAfterCommitMs", taps.compactMap(\.firstFrameAfterCommitMs))
        put("tapBodyPasses", taps.map { Double($0.bodyPasses) })
        // Round 2's direct evidence: where the post-commit storm actually
        // lands. `tapBodyPasses` above is still and only the DETAIL page.
        put("tapCalendarPageBodyPasses", taps.map { Double($0.calendarPageBodyPasses) })
        put("tapCalendarDayLayerPasses", taps.map { Double($0.calendarDayLayerPasses) })
        // Round 3's half of the day-layer pair: asked-for vs actually
        // applied. Min included — one applied column among twenty taps is
        // already a different finding from none.
        put("tapCalendarDayLayerAppliedPasses", taps.map { Double($0.calendarDayLayerAppliedPasses) }, includeMin: true)
        put("dragCalendarPageBodyPasses", drags.map { Double($0.calendarPageBodyPasses) })
        put("dragCalendarDayLayerPasses", drags.map { Double($0.calendarDayLayerPasses) })
        put("dragCalendarDayLayerAppliedPasses", drags.map { Double($0.calendarDayLayerAppliedPasses) })
        put("tapSlotWrites", taps.map { Double($0.slotWrites) }, includeMin: true)
        // The variant cross-check, per slot. `no-colordepth-mirror` must
        // drive `tapCalendarEventSlotWritesMax` to 0 while
        // `tapLogRecordSlotWrites*` stays at 1 — a statement no unrelated
        // background commit can spoof.
        put("tapCalendarEventSlotWrites", taps.map { Double($0.calendarEventSlotWrites) }, includeMin: true)
        put("tapLogRecordSlotWrites", taps.map { Double($0.logRecordSlotWrites) }, includeMin: true)
        return metrics
    }

    static let csvHeader = "i,kind,noOp,changed,dxMax,lagMs,rawLagMs,lagMaxMs,chToEndMs,endToCommitMs,commitMs,frameAfterChangedMs,frameAfterCommitMs,bodyPasses,pageBody,dayLayer,dayLayerApplied,slotWrites,slotEvents,slotLogs"

    /// Every gesture, one row, in the run's own JSONL line — aggregates
    /// can hide a bimodal distribution (say, 15 held taps and 5 live ones)
    /// that per-gesture rows make obvious.
    static func csv(_ records: [Spike201GestureRecord]) -> String {
        func num(_ value: Double?) -> String {
            guard let value else { return "" }
            return String(format: "%.1f", value)
        }
        let rows = records.map { record in
            [
                String(record.index),
                isTap(record) ? "tap" : "drag",
                isNoOp(record) ? "1" : "0",
                String(record.changedCount),
                num(record.maxLocationDelta),
                num(record.firstDeliveryLagMs),
                num(record.firstRawDeliveryLagMs),
                num(record.maxDeliveryLagMs),
                num(record.changedToEndedMs),
                num(record.endedToCommitMs),
                num(record.commitMs),
                num(record.firstFrameAfterFirstChangedMs),
                num(record.firstFrameAfterCommitMs),
                String(record.bodyPasses),
                String(record.calendarPageBodyPasses),
                String(record.calendarDayLayerPasses),
                String(record.calendarDayLayerAppliedPasses),
                String(record.slotWrites),
                String(record.calendarEventSlotWrites),
                String(record.logRecordSlotWrites),
            ].joined(separator: ",")
        }
        return ([csvHeader] + rows).joined(separator: "\n")
    }
}

// MARK: - Epoch stamp (pure)

/// One reading of all three clocks this rig touches, taken once per run.
///
/// gh#201 round 1 lost its delivery-lag column to an epoch mismatch and
/// round 2 recovered it by REASONING about which timebase SwiftUI stamps
/// `DragGesture.Value.time` in. Reasoning is not a measurement. Three
/// readings taken back to back settle it permanently and for whatever the
/// next OS release does: `mediaTime` and `systemUptime` agree to within
/// the cost of two function calls if they share a timebase, and
/// `dateSinceReferenceDate - mediaTime` IS the constant offset any epoch
/// hypothesis has to explain.
struct Spike201EpochStamp: Equatable {
    let mediaTime: Double
    let systemUptime: Double
    let dateSinceReferenceDate: Double

    var metrics: [String: SpikeMetricValue] {
        [
            "epochMediaTime": .number(mediaTime),
            "epochSystemUptime": .number(systemUptime),
            "epochDateSinceReferenceDate": .number(dateSinceReferenceDate),
        ]
    }
}
