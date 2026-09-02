//
//  ResidentObservationCenter.swift
//  Done
//
//  FIX WATCH — the impure shell around `ResidentTierOneCore`: clocks,
//  coordinator registration, per-instance store seams, lifecycle-edge
//  flushes, and the Tier-2 window's frame probe. Every rule lives in
//  ResidentObservationModel.swift; this file is wiring.
//
//  Cost contract, in order of the paths that pay it:
//    * Per signal (production body passes, 120Hz gesture closures): one
//      Date read, one Double compare (the cached day-end bound — R-F10:
//      no UserDefaults, no Calendar math, no allocation on this path),
//      and the core's O(1) fixed-key bump / bounded ring append.
//    * Window OPEN (a completed tap's `.commitEnd`): in-memory struct +
//      CADisplayLink attach. NO `SpikeRunContext.stamp()`, NO write-ahead
//      `beginRun`, NO disk I/O (R-F5 — arming used to execute inside the
//      measured touch path; now everything heavy happens at close). A
//      crash mid-window loses that one window, which is exactly why
//      launch reconciliation never needs to know windows exist.
//    * Window CLOSE / daily flush: stamp + one JSONL append (+ the
//      stat-gated compaction). Flushes fire on the three lifecycle edges
//      EventStore's own flushes use, on deck-open, and on day rollover —
//      and rollover NEVER flushes synchronously from a signal (R-F3): the
//      signal path only schedules a main-queue hop.
//
//  NOT an ObservableObject, deliberately: signals arrive inside SwiftUI
//  body evaluation (`.bodyPass`) and inside the Me reductions' witness
//  emits, and a publish from there is an
//  undefined-behavior-during-view-update hazard (adversary F10). The
//  deck reads state by asking for a flush and loading the files.
//
//  Not wired under XCTest (R-F10): `DoneApp` creates this only when
//  `EventStorageLocation.isRunningUnderXCTest` is false. DoneTests is a
//  host-app bundle — a resident registered at app launch would run
//  counter work and real CADisplayLink windows during timing-sensitive
//  tests. Tests construct their own centers over scratch stores.
//

import Combine
import Foundation
import QuartzCore
import UIKit

@MainActor
final class ResidentObservationCenter {
    static let residentID = "fix-watch-resident"

    /// Weak access for the deck (FixWatchView). Weak so a test's center
    /// dies with the test; assigned in `activate()`. NOT a second
    /// seam-writer — the coordinator remains the only writer of the
    /// physical seams.
    private(set) static weak var shared: ResidentObservationCenter?

    private let coordinator: SpikeSessionCoordinator
    private weak var store: EventStore?
    private let location: SpikeRunStorageLocation
    private let calendar: Calendar
    private let now: () -> Date
    private let mediaNow: () -> Double
    private let makeFrameProbe: @MainActor () -> SpikeFrameProbe

    private(set) var core: ResidentTierOneCore
    private var dayBounds: ResidentDayBounds
    /// The signal path's rollover check is one compare against this
    /// cached Double; it is recomputed only at init and flush edges.
    private var dayEndSinceReference: Double
    /// R-F2: the day's run id is ADOPTED from today's on-disk record at
    /// init (all counters seeded with it), so a same-day relaunch
    /// re-appends the same id with true merged totals and
    /// latest-record-wins collapse keeps the day whole.
    private var dailyRunID: UUID
    private var dailyRunStartedAt: Date
    private var rolloverFlushScheduled = false

    private(set) var window: ResidentWindowModel?
    private var frameProbe: SpikeFrameProbe?
    private var windowCloseWorkItem: DispatchWorkItem?

    private var lifecycleObservers: [NSObjectProtocol] = []
    private var manualRunWatch: AnyCancellable?

    init(
        coordinator: SpikeSessionCoordinator,
        store: EventStore?,
        location: SpikeRunStorageLocation = .production,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        mediaNow: @escaping () -> Double = CACurrentMediaTime,
        makeFrameProbe: @escaping @MainActor () -> SpikeFrameProbe = { SpikeFrameProbe() }
    ) {
        self.coordinator = coordinator
        self.store = store
        self.location = location
        self.calendar = calendar
        self.now = now
        self.mediaNow = mediaNow
        self.makeFrameProbe = makeFrameProbe

        let today = now()
        let bounds = ResidentDayBounds.compute(for: today, calendar: calendar)
        dayBounds = bounds
        dayEndSinceReference = bounds.dayEnd.timeIntervalSinceReferenceDate

        // R-F2: ONE launch-time read seeds ALL counters — not just the
        // window budget. Anything not seeded here would be erased by the
        // evening flush (latest-record-wins), including a morning
        // tripwire violation whose alarm would silently un-fire.
        var seededCore = ResidentTierOneCore()
        if let todays = Self.latestDailyRecord(location: location, within: bounds) {
            seededCore.counters = ResidentCounterSet(metrics: todays.metrics)
            dailyRunID = todays.id
            dailyRunStartedAt = todays.startedAt
        } else {
            dailyRunID = UUID()
            dailyRunStartedAt = today
        }
        core = seededCore
    }

    private static func latestDailyRecord(
        location: SpikeRunStorageLocation,
        within bounds: ResidentDayBounds
    ) -> SpikeRun? {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
            .filter { bounds.contains($0.startedAt) }
            .max { $0.startedAt < $1.startedAt }
    }

    // MARK: Activation

    /// Registers the resident listener with the coordinator, occupies the
    /// production store's per-instance seams (R-F11 — entry 1's daily
    /// counters come from `onDetailBodyPass`/`onPrefilledDraftComputed`,
    /// not from a new global emit), and subscribes the three lifecycle
    /// edges EventStore's own flushes already use.
    func activate() {
        Self.shared = self
        coordinator.registerResident(
            id: Self.residentID,
            store: store,
            onSignal: { [weak self] signal in
                self?.handleSignal(signal)
            },
            onSlotCommitted: { [weak self] slot in
                self?.handleSlot(slot)
            }
        )
        store?.onDetailBodyPass = { [weak self] _ in
            self?.core.noteDetailBodyPass()
        }
        store?.onPrefilledDraftComputed = { [weak self] _ in
            self?.core.noteDraftComputed()
        }

        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleLifecycleEdge()
                }
            })
        }

        // A manual #201 run arming mid-window takes the measurement over:
        // the auto-window aborts so the forensic run's probe is the only
        // one alive. `activeRuns` changes on register/unregister (UI
        // actions), never inside a body pass.
        manualRunWatch = coordinator.$activeRuns.sink { [weak self] runs in
            guard runs.contains(where: { $0.spikeID == Spike201SignalID.spikeID }) else { return }
            self?.closeWindow(outcome: .aborted, reason: "manual #201 run took over")
        }
    }

    func deactivate() {
        closeWindow(outcome: .aborted, reason: "resident deactivated")
        coordinator.unregisterResident(id: Self.residentID)
        store?.onDetailBodyPass = nil
        store?.onPrefilledDraftComputed = nil
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers = []
        manualRunWatch = nil
        if Self.shared === self {
            Self.shared = nil
        }
    }

    // MARK: Signal hot path

    private func handleSignal(_ signal: SpikeSignal) {
        // Rollover: ONE Double compare on the hot path. Crossing it only
        // SCHEDULES a main-queue hop (R-F3: a `.bodyPass` arriving just
        // after midnight must not run file I/O inside a SwiftUI body
        // evaluation). Signals between midnight and the hop land in the
        // old day's counters — a few-signal imprecision at 00:00,
        // documented and accepted.
        if now().timeIntervalSinceReferenceDate >= dayEndSinceReference {
            scheduleRolloverFlush()
        }
        let completion = core.ingest(signal: signal, mediaNow: mediaNow())
        if case .completed(let isTap, let commitEnd) = completion, isTap {
            handleQualifyingTap(commitEndMedia: commitEnd)
        }
    }

    private func handleSlot(_ slot: StorageSlot) {
        core.noteSlot(slot)
        window?.noteSlot(slot)
    }

    // MARK: Tier-2 windows

    private func handleQualifyingTap(commitEndMedia: Double) {
        // While a manual #201 run is armed, auto-windows are suppressed
        // entirely: the forensic run keeps a clean field and there is
        // never a second display link.
        guard !coordinator.activeRuns.contains(where: { $0.spikeID == Spike201SignalID.spikeID }) else { return }

        if window != nil {
            if window!.noteQualifyingTap() {
                core.counters.windowsExtended += 1
                scheduleWindowClose()
            }
            return
        }
        guard ResidentWindowBudget.canOpen(openedToday: core.counters.windowsOpened) else {
            core.counters.windowsRefusedBudget += 1
            return
        }
        core.counters.windowsOpened += 1
        window = ResidentWindowModel(
            openedAtMedia: mediaNow(),
            openedAt: now(),
            triggerCommitEndMedia: commitEndMedia
        )
        let probe = makeFrameProbe()
        probe.onTick = { [weak self] timestamp in
            // The probe fills the ROLLING LOG's frame columns — including
            // the trigger tap's `firstFrameAfterCommitMs`, which is in
            // the log because Tier 1 recorded it before the window
            // existed (R-F1: windows never need to see their trigger).
            self?.core.noteFrame(at: timestamp)
        }
        probe.start()
        frameProbe = probe
        scheduleWindowClose()
    }

    private func scheduleWindowClose() {
        windowCloseWorkItem?.cancel()
        guard let window else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.closeWindow(outcome: .completed)
        }
        windowCloseWorkItem = item
        let delay = max(0, window.deadlineMedia - mediaNow())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Everything heavy happens HERE (R-F5): probe teardown, context
    /// stamp, aggregate build, one JSONL append.
    func closeWindow(outcome: SpikeRunOutcome = .completed, reason: String? = nil, closedByResign: Bool = false) {
        guard let closing = window else { return }
        window = nil
        windowCloseWorkItem?.cancel()
        windowCloseWorkItem = nil
        let probeResult = frameProbe?.stopAndSummarize()
        frameProbe = nil

        let closedAtMedia = mediaNow()
        let context = SpikeRunContext.stamp()
        let run = SpikeRun(
            id: UUID(),
            spikeID: FixObservationRegistry.effortPathFixID,
            scenarioID: FixObservationRegistry.windowScenarioID,
            variantID: nil,
            startedAt: closing.openedAt,
            endedAt: now(),
            appVersion: context.appVersion,
            appBuild: context.appBuild,
            appCommit: context.appCommit,
            deviceModel: context.deviceModel,
            osVersion: context.osVersion,
            timeZoneIdentifier: context.timeZoneIdentifier,
            localeIdentifier: context.localeIdentifier,
            buildConfiguration: context.buildConfiguration,
            metrics: ResidentWindowAggregates.metrics(
                window: closing,
                records: core.gestureLog.records,
                closedAtMedia: closedAtMedia,
                probe: probeResult,
                closedByResign: closedByResign
            ),
            note: nil,
            outcome: outcome,
            abortReason: reason
        )
        SpikeRunStore.finishRun(run, location: location)
    }

    // MARK: Flushes

    private func handleLifecycleEdge() {
        closeWindow(outcome: .completed, closedByResign: true)
        flushDaily()
    }

    /// Also the deck's read barrier: FixWatchView calls this on appear so
    /// the evaluator always reads a line that includes today so far.
    func flushDaily() {
        performRolloverFlushIfDue()
        writeDailyRecord()
    }

    private func scheduleRolloverFlush() {
        guard !rolloverFlushScheduled else { return }
        rolloverFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.performRolloverFlushIfDue()
        }
    }

    /// Internal (not private) so tests can drive the deferred hop
    /// deterministically with an injected clock.
    func performRolloverFlushIfDue() {
        rolloverFlushScheduled = false
        let currentNow = now()
        guard currentNow.timeIntervalSinceReferenceDate >= dayEndSinceReference else { return }
        // Close any window across midnight first — its record belongs to
        // the day that opened it.
        closeWindow(outcome: .completed)
        // Yesterday's line closes AT its own day end, so the record's
        // civil day stays unambiguous.
        writeDailyRecord(endedAt: dayBounds.dayEnd)
        // Re-base for the new day: fresh counters, fresh id, fresh cached
        // bound (the ONLY places calendar math runs are init and here —
        // flush edges, never the signal path).
        core.resetForNewDay()
        let bounds = ResidentDayBounds.compute(for: currentNow, calendar: calendar)
        dayBounds = bounds
        dayEndSinceReference = bounds.dayEnd.timeIntervalSinceReferenceDate
        dailyRunID = UUID()
        dailyRunStartedAt = currentNow
    }

    private func writeDailyRecord(endedAt: Date? = nil) {
        let context = SpikeRunContext.stamp()
        let run = SpikeRun(
            id: dailyRunID,
            spikeID: FixObservationRegistry.residentDailySpikeID,
            scenarioID: FixObservationRegistry.residentDailyScenarioID,
            variantID: nil,
            startedAt: dailyRunStartedAt,
            endedAt: endedAt ?? now(),
            appVersion: context.appVersion,
            appBuild: context.appBuild,
            appCommit: context.appCommit,
            deviceModel: context.deviceModel,
            osVersion: context.osVersion,
            timeZoneIdentifier: context.timeZoneIdentifier,
            localeIdentifier: context.localeIdentifier,
            buildConfiguration: context.buildConfiguration,
            metrics: core.counters.metrics,
            note: nil,
            outcome: .completed,
            abortReason: nil
        )
        SpikeRunStore.finishRun(run, location: location)
    }
}
