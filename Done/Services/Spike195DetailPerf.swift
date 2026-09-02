//
//  Spike195DetailPerf.swift
//  Done
//
//  gh#197 SPIKE — the one real spike wired end-to-end in this slice: #195
//  "Reflection Note: type 40 characters".
//
//  Everything here is the RUNNER side: it registers its listeners with
//  `SpikeSessionCoordinator` — the single writer of the zero-cost
//  `SpikeProbe` seam and of `EventStore.onSlotCommitted` — runs a
//  CADisplayLink frame probe for the duration, and writes the resulting
//  SpikeRun through SpikeRunStore. The runner never assigns either seam
//  itself. Production views know nothing about this file.
//
//  CADisplayLink usage mirrors BoundaryExtensionScrollAnimator's idiom
//  (NSObject target + `@objc` tick selector added to `.main`/`.common`) —
//  ported, not reinvented, per gh#197 comment #1's instrumentation
//  inventory.
//

import Combine
import Foundation
import QuartzCore
import UIKit

/// Collects frame-to-frame deltas for as long as it is running.
///
/// gh#201 round 3: everything this does WITH a tick moved into
/// `SpikeFrameTickIngestor`, which owns the lifecycle fact rather than
/// being handed it. What is left here is the tick SOURCE (a CADisplayLink
/// and two `UIApplication` notifications) and the display query — the
/// parts that genuinely depend on the run loop. `ingestTick` is internal
/// so a test can drive the same path the `@objc` callback drives, with
/// hand-written timestamps.
///
/// The display link retains this object (CADisplayLink retains its
/// target), so a probe can outlive whatever logically owned it. Two
/// defenses: sample retention is hard-capped by `SpikeFrameSampleBuffer`
/// so even an orphaned probe's memory stays bounded, and the only path
/// that discards a probe — a runner's finish, reachable from the
/// coordinator's stop — calls `stopAndSummarize()`, whose `invalidate()`
/// is what actually releases the link's grip.
@MainActor
final class SpikeFrameProbe: NSObject {
    /// Upper bound on retained frame samples. Sized to cover several
    /// minutes of continuous sampling at the fastest refresh rate
    /// shipping hardware produces — far longer than any attended
    /// scenario — while keeping the worst-case buffer a small, fixed
    /// memory cost.
    static let maxSamples = 36_000
    /// Single-delta bound above which a delta is a candidate for gap
    /// classification (see `SpikeFrameSampleBuffer`).
    ///
    /// gh#201 round 3 moved this from 1000ms to 250ms. Round 2's comment
    /// claimed 1000ms was "well past any frame time the distribution is
    /// designed to characterize" — the very device run it was written for
    /// then produced stalls of 768, 768, 779, 805, 1081 and 1160ms, i.e.
    /// the bound sat INSIDE the phenomenon and the same physical event
    /// landed on either side of it at a 4% margin. Suspension is decided
    /// by the lifecycle fact now, not by duration, so the bound only has
    /// to sit clear of any real frame: 250ms is 15× a 60Hz frame and 30×
    /// a 120Hz one, and comfortably below the smallest stall observed.
    /// Independently, `SpikeFrameSampleBuffer.largestDeltasMs` retains the
    /// top deltas UNCONDITIONALLY, so no placement of this bound can make
    /// a large delta invisible.
    static let gapCandidateFrameDeltaMs: Double = 250

    /// Optional per-tick callback, carrying the link's own timestamp
    /// (`CACurrentMediaTime` timebase). Added for gh#201, whose question
    /// is "when did the next frame boundary happen relative to this
    /// touch", which a delta distribution alone cannot answer. `nil` for
    /// gh#195, which keeps exactly its previous behavior.
    var onTick: ((CFTimeInterval) -> Void)?

    private var displayLink: CADisplayLink?
    /// The display's nominal refresh rate, captured when the probe starts
    /// and reported as CONTEXT. Round 1 counted "over 16ms" against a
    /// literal; round 2 counted against this and saturated at 367/367
    /// because the panel advertises 120Hz while the link ran at 60. No
    /// count is derived from it any more — see `SpikeFrameThreshold`.
    private(set) var maximumFramesPerSecond = SpikeFrameThreshold.fallbackFramesPerSecond
    /// Internal, not private, so `SpikeFrameProbeTests` can read the
    /// lifecycle fact the notification observers set and the counts the
    /// ticks produce. Nothing outside this class writes it.
    private(set) var tickIngestor = SpikeFrameTickIngestor(
        capacity: SpikeFrameProbe.maxSamples,
        gapCandidateMs: SpikeFrameProbe.gapCandidateFrameDeltaMs
    )

    func start() {
        tickIngestor = SpikeFrameTickIngestor(
            capacity: Self.maxSamples,
            gapCandidateMs: Self.gapCandidateFrameDeltaMs
        )
        maximumFramesPerSecond = Self.currentMaximumFramesPerSecond()
        let link = CADisplayLink(target: self, selector: #selector(handleTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // First belt against suspension gaps: re-baseline the tick
        // timebase on lifecycle edges so the first tick after a resume
        // measures from resume, not from before the suspension. The
        // buffer's credibility bound is the second belt — notification
        // delivery order versus the first resumed tick is not guaranteed,
        // so neither belt is trusted alone.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleWillResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Best-effort read of the display the app is actually on, via the
    /// connected window scene (`UIScreen.main` is deprecated and, on a
    /// multi-display device, would answer about the wrong screen). No
    /// scene, or a screen that names no rate, falls back to 60Hz — the
    /// same conservative choice `SpikeFrameThreshold` documents.
    private static func currentMaximumFramesPerSecond() -> Int {
        let sceneScreen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen
        let fps = sceneScreen?.maximumFramesPerSecond ?? 0
        return fps > 0 ? fps : SpikeFrameThreshold.fallbackFramesPerSecond
    }

    @objc private func handleWillResignActive() {
        tickIngestor.noteWillResignActive()
    }

    @objc private func handleDidBecomeActive() {
        tickIngestor.noteDidBecomeActive()
    }

    /// The whole body of the display-link callback, reachable without a
    /// display link. `targetTimestamp` is the OS's own statement of when
    /// it expects the frame being prepared to be shown; measuring the NEXT
    /// tick's `timestamp` against it is the only definition of "late" that
    /// survives adaptive refresh.
    func ingestTick(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        tickIngestor.ingest(timestamp: timestamp, targetTimestamp: targetTimestamp)
        onTick?(timestamp)
    }

    @objc private func handleTick(_ link: CADisplayLink) {
        ingestTick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
    }

    /// Invalidates the link, detaches the lifecycle observers, and
    /// returns the distribution plus both integrity markers: whether the
    /// sample cap was hit, and how many suspension-gap deltas were
    /// dropped (neither a truncated nor a gap-riddled distribution may
    /// masquerade as clean — the caller records both as metrics). The
    /// buffer drains on the way out, so a second call returns an empty
    /// result by construction, not by convention.
    func stopAndSummarize() -> SpikeFrameProbeResult {
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
        onTick = nil
        let drained = tickIngestor.drain()
        return SpikeFrameProbeResult(
            // No threshold argument: the late-frame line is derived inside
            // `summarize` from the run's own median, so there is no
            // display-to-threshold wiring here left to get wrong.
            stats: SpikeFrameStatistics.summarize(durationsMs: drained.samples),
            truncated: drained.isTruncated,
            maximumFramesPerSecond: maximumFramesPerSecond,
            drain: drained
        )
    }
}

/// What one frame probe run produced: the distribution, the display it was
/// taken on, and everything `SpikeFrameTickIngestor` collected alongside.
struct SpikeFrameProbeResult: Equatable {
    let stats: SpikeFrameStats?
    let truncated: Bool
    let maximumFramesPerSecond: Int
    let drain: SpikeFrameTickDrain

    /// The frame metrics every runner writes, so the two runners cannot
    /// drift into naming the same quantity differently.
    ///
    /// gh#201 ROUND 3 RENAMED THE DISTRIBUTION KEYS. Round 2 changed what
    /// they measure — it began ADMITTING active stalls that round 1
    /// discarded, so round 1's max of 941.1 and round 2's of 1159.8 are
    /// partly a reclassification, not a regression — while keeping the
    /// keys `frameSampleCount` / `p50FrameMs` / `p95FrameMs` /
    /// `p99FrameMs` / `maxFrameMs`. Round 2 applied its own
    /// "meaning changed ⇒ key changed" rule to two keys and not to these
    /// five. They are `...FrameDelta...` now, and the old spellings are
    /// asserted never to reappear, so no round-1 line can be read against
    /// a round-3 line by key.
    var metrics: [String: SpikeMetricValue] {
        var metrics: [String: SpikeMetricValue] = [
            // Context only. The panel's advertised maximum; the cadence
            // the link ACHIEVED is `frameAchievedFPS` below, and on the
            // one device this has run on they differ by 2×.
            "displayMaxFPS": .number(Double(maximumFramesPerSecond)),
            "displayNominalFrameMs": .number(
                SpikeFrameThreshold.nominalIntervalMs(maximumFramesPerSecond: maximumFramesPerSecond)
            ),
            // Recorded unconditionally, zero included. "Absence of markers
            // means the distribution is complete" was false: absence is
            // also the normal outcome of a real backgrounding, which
            // re-baselines the timebase and therefore computes no delta at
            // all. Round 1 could only assert "the app never backgrounded"
            // in prose; these two are that assertion as a number.
            "frameResignActiveCount": .number(Double(drain.resignActiveCount)),
            "frameDidBecomeActiveCount": .number(Double(drain.didBecomeActiveCount)),
            "frameSuspensionGapCount": .number(Double(drain.suspensionGapCount)),
            "frameActiveStallCount": .number(Double(drain.activeStallsMs.count)),
            "frameSamplesTruncated": .bool(truncated),
            // The system's own definition of late: this tick's timestamp
            // against the previous tick's targetTimestamp. Independent of
            // any multiple, and the only one that survives the OS changing
            // the refresh rate mid-run.
            "frameOvershootSampleCount": .number(Double(drain.overshoot.sampleCount)),
            "frameOvershootLateCount": .number(Double(drain.overshoot.lateCount)),
            "frameOvershootMaxMs": .number(drain.overshoot.maxMs),
            "frameOvershootToleranceMs": .number(SpikeFrameOvershootTally.toleranceMs),
        ]
        if let stats {
            metrics["frameDeltaCount"] = .number(Double(stats.count))
            metrics["p50FrameDeltaMs"] = .number(stats.p50Ms)
            metrics["p95FrameDeltaMs"] = .number(stats.p95Ms)
            metrics["p99FrameDeltaMs"] = .number(stats.p99Ms)
            metrics["maxFrameDeltaMs"] = .number(stats.maxMs)
            metrics["frameAchievedFPS"] = .number(stats.achievedFramesPerSecond)
            metrics["frameLateThresholdObservedMs"] = .number(stats.overThresholdMs)
            metrics["overObservedCadenceCount"] = .number(Double(stats.overThresholdCount))
        }
        // Durations, listed only when there is something to list — the
        // counts above already distinguish "none happened" from "the rig
        // never looked".
        if !drain.largestDeltasMs.isEmpty {
            metrics["frameLargestDeltasMs"] = .string(Self.list(drain.largestDeltasMs))
        }
        if !drain.suspensionGapsMs.isEmpty {
            metrics["frameSuspensionGapsMs"] = .string(Self.list(drain.suspensionGapsMs))
        }
        if !drain.activeStallsMs.isEmpty {
            metrics["frameActiveStallsMs"] = .string(Self.list(drain.activeStallsMs))
        }
        return metrics
    }

    private static func list(_ values: [Double]) -> String {
        values.map { String(format: "%.1f", $0) }.joined(separator: " ")
    }
}

/// Arms/disarms the #195 "Reflection Note: type 40 characters" scenario.
/// One instance is owned by `SpikeSessionCoordinator` for the lifetime of
/// the PROCESS — an armed run survives the settings sheet's dismissal and
/// any navigation, which is the whole point of a `.userAction` scenario
/// (the user must leave settings and go type in production UI).
/// `SpikeDetailView` is only a remote control for this instance. Every
/// finish path unregisters from the coordinator (detaching both seams)
/// and invalidates the frame probe, so no run can end with production
/// instrumentation still attached.
@MainActor
final class Spike195Runner: ObservableObject {
    static let spikeID = Spike195SignalID.spikeID
    static let scenarioID = "reflection-note-40-char"
    private static let targetCharacterCount = 40

    enum State: Equatable {
        case idle
        case armed(SpikeRun)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCompletedRun: SpikeRun?

    /// Set by `SpikeSessionCoordinator` when it creates this runner. Weak
    /// because the coordinator owns the runner, not the other way around.
    weak var coordinator: SpikeSessionCoordinator?

    private var frameProbe: SpikeFrameProbe?
    private var bodyPassesParent = 0
    private var bodyPassesLeaf = 0
    private var storeWrites = 0

    var isArmed: Bool {
        if case .armed = state { return true }
        return false
    }

    /// Begins the measurement window: registers with the coordinator
    /// (which stamps `coActiveSpikeIDs` and attaches this runner's
    /// listeners to the seams it owns), writes the STAMPED open
    /// (write-ahead) record immediately so a crash before `finish()`
    /// still leaves a trace `reconcileInterruptedRuns` can close on next
    /// launch, then starts the frame probe.
    func start(store: EventStore) {
        guard case .idle = state else { return }
        // The coordinator creates this runner and points it back at
        // itself; nil means the runner was constructed outside the app's
        // session wiring, and arming without seam ownership would
        // silently measure nothing — refuse instead.
        guard let coordinator else { return }
        bodyPassesParent = 0
        bodyPassesLeaf = 0
        storeWrites = 0

        let context = SpikeRunContext.stamp()
        let openRun = SpikeRun(
            id: UUID(),
            spikeID: Self.spikeID,
            scenarioID: Self.scenarioID,
            variantID: nil,
            startedAt: Date(),
            endedAt: nil,
            appVersion: context.appVersion,
            appBuild: context.appBuild,
            appCommit: context.appCommit,
            deviceModel: context.deviceModel,
            osVersion: context.osVersion,
            timeZoneIdentifier: context.timeZoneIdentifier,
            localeIdentifier: context.localeIdentifier,
            buildConfiguration: context.buildConfiguration,
            metrics: [:],
            note: nil,
            outcome: nil,
            abortReason: nil
        )
        let stamped = coordinator.register(
            run: openRun,
            store: store,
            onSignal: { [weak self] signal in
                self?.handle(signal)
            },
            onSlotCommitted: { [weak self] _ in
                self?.storeWrites += 1
            },
            stop: { [weak self] in
                self?.cancel()
            }
        )
        SpikeRunStore.beginRun(stamped)

        let probe = SpikeFrameProbe()
        probe.start()
        frameProbe = probe

        state = .armed(stamped)
    }

    /// Manual early stop (the detail page's Stop button, or the Active
    /// Runs card's — the coordinator's per-run stop routes here too),
    /// distinct from the automatic 40-character completion.
    func cancel() {
        finish(outcome: .aborted, abortReason: "stopped manually before 40 characters")
    }

    private func handle(_ signal: SpikeSignal) {
        switch signal {
        case .bodyPass(let id):
            if id == Spike195SignalID.parentBody {
                bodyPassesParent += 1
            } else if id == Spike195SignalID.reflectionNoteLeaf {
                bodyPassesLeaf += 1
            }
        case .textLength(let id, let length):
            if id == Spike195SignalID.reflectionNoteLength, length >= Self.targetCharacterCount {
                finish(outcome: .completed, abortReason: nil)
            }
        case .gesture, .counter, .invariant:
            // Other spikes' / the resident's streams. Ignored here on
            // purpose: the coordinator fans every signal out to every
            // armed listener, so a #195 run co-armed with anything else
            // sees it all.
            break
        }
    }

    private func finish(outcome: SpikeRunOutcome, abortReason: String?) {
        guard case .armed(let openRun) = state else { return }

        // Order matters: invalidate the probe FIRST (stopAndSummarize is
        // where the CADisplayLink lets go of its target), then detach the
        // seams by unregistering — the coordinator, not this runner, is
        // the only writer of the physical seams.
        let frameResult = frameProbe?.stopAndSummarize()
        frameProbe = nil
        coordinator?.unregister(runID: openRun.id)

        var metrics: [String: SpikeMetricValue] = [
            "bodyPassesParent": .number(Double(bodyPassesParent)),
            "bodyPassesLeaf": .number(Double(bodyPassesLeaf)),
            "storeWrites": .number(Double(storeWrites)),
        ]
        // Frame metrics come from ONE author (`SpikeFrameProbeResult`), so
        // #195 and #201 can never name the same quantity differently. Its
        // doc lists every key retired so far and why; the assertion that
        // none of them reappears is
        // `SpikeFrameProbeResultMetricsTests.testTheRetiredKeysAreNeverEmittedAgain`,
        // not this comment.
        for (key, value) in frameResult?.metrics ?? [:] {
            metrics[key] = value
        }

        var closedRun = openRun
        closedRun.endedAt = Date()
        closedRun.outcome = outcome
        closedRun.abortReason = abortReason
        closedRun.metrics = metrics
        SpikeRunStore.finishRun(closedRun)

        lastCompletedRun = closedRun
        state = .idle
    }
}
