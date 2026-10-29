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
//  Follower timing (perf batch 2a, report-only): the center owns the
//  `FollowerTimingRecorder` and installs it as `FollowerTiming.recorder`
//  while active. The day's follower stats ride the daily record (foreground
//  only), an auto-window's ride its window record, and each window close
//  writes one `followers:` trail line. Under XCTest the recorder is NOT
//  installed unless a test asks (`installsFollowerProbe`): the host app's own
//  followers run on the same main thread and would leak into a test's
//  records. Uninstalled, the daily line still carries the follower keys, all
//  zero.
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
    /// The account signed in right now (gh#273 §4.2 / B·F16): part of the
    /// claim key, stamped on every record this center writes. Injected so
    /// tests can switch accounts and the app can hand in the live session.
    private let ownerUID: () -> String?
    /// Device/build stamp seam (gh#273 test 9: a same-day build change
    /// must mint a new id). Production hands in `SpikeRunContext.stamp`.
    private let stamp: () -> SpikeRunContext.Stamp

    /// gh#273 §7.1: told after each flush edge so the telemetry uploader
    /// can schedule a batch. Optional and set by the app — the center
    /// never knows what an uploader is, and under XCTest it stays nil.
    var onUploadTrigger: ((TelemetryTrigger) -> Void)?

    private(set) var core: ResidentTierOneCore
    /// perf batch 2a: the follower probe's accumulator. Always present (the
    /// daily line carries its keys); installed process-wide only when
    /// `installsFollowerProbe`.
    let followers: FollowerTimingRecorder
    private let installsFollowerProbe: Bool
    private let isAppActive: @MainActor () -> Bool
    /// What the last successful daily append carried for the followers — the
    /// follower half of the dirty check (B·F6).
    private var lastWrittenFollowers: FollowerStatTable?
    private var lastWrittenFollowerOverflow = 0
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
    /// The claim the current daily id was minted or adopted under (gh#273
    /// §4.2). Build, OS and configuration cannot change inside a process;
    /// the owner can (sign-in, account switch), and a flush that finds a
    /// different owner closes this id and mints a new one.
    private var dailyClaim: TelemetryClaimKey
    /// Civil day of the current daily id in the boundary's own zone,
    /// formatted once at mint (B·F17 — never from `TimeZone.current`).
    private var dailyDay: (dayKey: String, tzOffsetMin: Int)
    /// Dirty check (B·F6): what the last successful daily append carried.
    /// A flush whose counters and start are unchanged writes nothing —
    /// every duplicate line was pure compaction pressure, and now also a
    /// pointless revision bump the uploader would resend.
    private var lastWrittenCounters: ResidentCounterSet?
    private var lastWrittenStartedAt: Date?
    private var rolloverFlushScheduled = false

    private(set) var window: ResidentWindowModel?
    private var frameProbe: SpikeFrameProbe?
    private var windowCloseWorkItem: DispatchWorkItem?

    private var lifecycleObservers: [NSObjectProtocol] = []
    private var manualRunWatch: AnyCancellable?
    /// S8: one backgrounding cycle flushes ONCE. `willResignActive` and
    /// `didEnterBackground` both fire on a normal backgrounding; without
    /// this token each cycle appended the same-id daily record twice
    /// (collapse hid it from readers, but every duplicate line is pure
    /// compaction pressure). Set on the first edge of a cycle, cleared on
    /// `didBecomeActive`. `willTerminate` without a preceding resign (rare,
    /// foreground kill) still flushes: the token is only set by an edge.
    private var lifecycleEdgeFlushed = false

    init(
        coordinator: SpikeSessionCoordinator,
        store: EventStore?,
        location: SpikeRunStorageLocation = .production,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        mediaNow: @escaping () -> Double = CACurrentMediaTime,
        makeFrameProbe: @escaping @MainActor () -> SpikeFrameProbe = { SpikeFrameProbe() },
        ownerUID: @escaping () -> String? = { nil },
        stamp: @escaping () -> SpikeRunContext.Stamp = SpikeRunContext.stamp,
        followerClock: @escaping () -> UInt64 = FollowerClock.now,
        installsFollowerProbe: Bool = !EventStorageLocation.isRunningUnderXCTest,
        isAppActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.coordinator = coordinator
        self.store = store
        self.location = location
        self.calendar = calendar
        self.now = now
        self.mediaNow = mediaNow
        self.makeFrameProbe = makeFrameProbe
        self.ownerUID = ownerUID
        self.stamp = stamp
        self.installsFollowerProbe = installsFollowerProbe
        self.isAppActive = isAppActive
        let followers = FollowerTimingRecorder(now: followerClock, isForeground: false)
        self.followers = followers

        let today = now()
        let bounds = ResidentDayBounds.compute(for: today, calendar: calendar)
        dayBounds = bounds
        dayEndSinceReference = bounds.dayEnd.timeIntervalSinceReferenceDate
        dailyDay = TelemetryClaimKey.dayKey(forDayStart: bounds.dayStart, calendar: calendar)

        // R-F2: ONE launch-time read seeds ALL counters — not just the
        // window budget. Anything not seeded here would be erased by the
        // evening flush (latest-record-wins), including a morning
        // tripwire violation whose alarm would silently un-fire.
        //
        // B1, widened by gh#273 §4.2 (B·F15/F16): adoption is CLAIM-AWARE —
        // only a record stamped by the same (configuration, build, OS,
        // owner) is adopted. `writeDailyRecord` stamps the CURRENT
        // process's values, so adopting across any of them let an evening
        // flush re-append a morning run id under a different label:
        // latest-wins collapse then relabeled the whole day (a Release
        // morning became "debug" and its tripwire alarm un-fired; a build-10
        // morning became build 11 on TestFlight's update day; one account's
        // counts landed on the next account's row). A mismatch instead
        // mints a NEW same-day run id; both records survive collapse
        // (distinct ids) and every daily-fed criterion SUMS across
        // same-day records of its partition.
        let claim = Self.currentClaim(stamp: stamp(), ownerUID: ownerUID())
        var seededCore = ResidentTierOneCore()
        if let todays = Self.latestDailyRecord(location: location, within: bounds, claim: claim) {
            seededCore.counters = ResidentCounterSet(metrics: todays.metrics)
            // The follower stats come back with the counters, for the same
            // reason (latest-record-wins would erase the morning's).
            let seededFollowers = FollowerStatTable(dailyMetrics: todays.metrics)
            let seededOverflow = FollowerStatTable.dailyOverflow(in: todays.metrics)
            followers.resetDaily(seed: seededFollowers, overflow: seededOverflow)
            lastWrittenFollowers = seededFollowers
            lastWrittenFollowerOverflow = seededOverflow
            dailyRunID = todays.id
            dailyRunStartedAt = todays.startedAt
            // The adopted line IS the last written state: a flush with no
            // new signals has nothing to add to it.
            lastWrittenCounters = seededCore.counters
            lastWrittenStartedAt = todays.startedAt
            if let dayKey = todays.dayKey, let offset = todays.dayTZOffsetMin {
                dailyDay = (dayKey, offset)
            }
        } else {
            dailyRunID = UUID()
            dailyRunStartedAt = today
        }
        dailyClaim = claim
        core = seededCore
    }

    private static func currentClaim(stamp: SpikeRunContext.Stamp, ownerUID: String?) -> TelemetryClaimKey {
        TelemetryClaimKey(
            buildConfiguration: stamp.buildConfiguration,
            appBuild: stamp.appBuild,
            osVersion: stamp.osVersion,
            ownerUID: ownerUID
        )
    }

    /// Latest of today's records written under exactly THIS claim (B1 /
    /// gh#273 §4.2) — a record written by another configuration, build, OS
    /// or account (or by a pre-stamp build, whose `buildConfiguration` is
    /// nil) is never adopted, because re-appending its id would relabel it
    /// with this process's stamp.
    private static func latestDailyRecord(
        location: SpikeRunStorageLocation,
        within bounds: ResidentDayBounds,
        claim: TelemetryClaimKey
    ) -> SpikeRun? {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
            .filter { bounds.contains($0.startedAt) && TelemetryClaimKey(run: $0) == claim }
            .max { $0.startedAt < $1.startedAt }
    }

    /// A fresh same-day (or new-day) id under the current claim, with the
    /// civil day minted from the boundary's own zone (B·F17).
    private func mintDailyRun(at date: Date, bounds: ResidentDayBounds) {
        dailyRunID = UUID()
        dailyRunStartedAt = date
        dailyClaim = Self.currentClaim(stamp: stamp(), ownerUID: ownerUID())
        dailyDay = TelemetryClaimKey.dayKey(forDayStart: bounds.dayStart, calendar: calendar)
        lastWrittenCounters = nil
        lastWrittenStartedAt = nil
        lastWrittenFollowers = nil
        lastWrittenFollowerOverflow = 0
    }

    /// A new day, a new owner or a consent re-mint: every count starts over,
    /// the followers' with the counters'.
    private func resetCountsForNewDaily() {
        core.resetForNewDay()
        followers.resetDaily()
    }

    // MARK: Activation

    /// Registers the resident listener with the coordinator, occupies the
    /// production store's per-instance seams (R-F11 — entry 1's daily
    /// counters come from `onDetailBodyPass`/`onPrefilledDraftComputed`,
    /// not from a new global emit), and subscribes the three lifecycle
    /// edges EventStore's own flushes already use.
    func activate() {
        Self.shared = self
        followers.isForeground = isAppActive()
        if installsFollowerProbe {
            FollowerTiming.recorder = followers
        }
        coordinator.registerResident(
            id: Self.residentID,
            store: store,
            onSignal: { [weak self] signal in
                self?.handleSignal(signal)
            },
            onSlotCommitted: { [weak self] slot, mode in
                self?.handleSlot(slot, mode: mode)
            }
        )
        // SINGLE WRITER (S5): in the app process this center is the ONE
        // writer of these two per-instance seams, and it assigns them
        // unconditionally — any closure a previous owner left there is
        // overwritten, not composed with. That is safe only because the
        // render test (the seams' other consumer) runs under XCTest, where
        // no app resident is ever created and tests hold their own store
        // instances; a second in-app writer would silently disconnect
        // these counters and must not be added.
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
                    // Foreground-only daily follower stats: what runs from
                    // here until `didBecomeActive` is background work.
                    self?.followers.isForeground = false
                    self?.handleLifecycleEdge()
                }
            })
        }
        // The S8 token's clearing edge: back to foreground re-arms the
        // one-flush-per-backgrounding-cycle guard.
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lifecycleEdgeFlushed = false
                self?.followers.isForeground = true
            }
        })

        // A manual #201 run arming mid-window takes the measurement over:
        // the auto-window aborts so the forensic run's probe is the only
        // one alive. `activeRuns` changes on register/unregister (UI
        // actions), never inside a body pass.
        manualRunWatch = coordinator.$activeRuns.sink { [weak self] runs in
            guard runs.contains(where: { $0.spikeID == Spike201SignalID.spikeID }) else { return }
            self?.closeWindow(outcome: .aborted, reason: .manualRunTookOver)
        }
    }

    func deactivate() {
        closeWindow(outcome: .aborted, reason: .residentDeactivated)
        coordinator.unregisterResident(id: Self.residentID)
        store?.onDetailBodyPass = nil
        store?.onPrefilledDraftComputed = nil
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers = []
        manualRunWatch = nil
        if FollowerTiming.recorder === followers {
            FollowerTiming.recorder = nil
        }
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

    private func handleSlot(_ slot: StorageSlot, mode: CommitMode) {
        core.noteSlot(slot, mode: mode)
        // The window's counters stay mode-BLIND on purpose: they exist to
        // detect contamination (an unexpected extra commit inside an auto
        // window), and a commit contaminates a window whichever shape it
        // reached the disk in.
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
        // perf batch 2a: the followers' window span is the auto-window's
        // own, open to close (extensions included). Armed only when the
        // probe is installed — an uninstalled recorder measures nothing, and
        // a window must not claim a follower probe that never ran.
        if installsFollowerProbe {
            followers.armWindow()
        }
        let probe = makeFrameProbe()
        probe.onTick = { [weak self] timestamp in
            // The probe fills the ROLLING LOG's frame columns — including
            // the trigger tap's `firstFrameAfterCommitMs`, which is in
            // the log because Tier 1 recorded it before the window
            // existed (R-F1: windows never need to see their trigger).
            self?.core.noteFrame(at: timestamp)
            // The same tick is the followers' frame boundary.
            self?.followers.noteFrameTick(atNs: FollowerClock.nanoseconds(fromMediaSeconds: timestamp))
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
    func closeWindow(outcome: SpikeRunOutcome = .completed, reason: SpikeAbortReason? = nil, closedByResign: Bool = false) {
        guard let closing = window else { return }
        window = nil
        windowCloseWorkItem?.cancel()
        windowCloseWorkItem = nil
        let probeResult = frameProbe?.stopAndSummarize()
        frameProbe = nil
        let followerResult = followers.disarmWindow()

        let closedAtMedia = mediaNow()
        let context = stamp()
        var windowMetrics = ResidentWindowAggregates.metrics(
            window: closing,
            records: core.gestureLog.records,
            closedAtMedia: closedAtMedia,
            probe: probeResult,
            closedByResign: closedByResign
        )
        // The follower keys sit BESIDE the window probe's, under their own
        // prefix; none of the probe's keys changes.
        if let followerResult {
            windowMetrics.merge(followerResult.metrics()) { probeValue, _ in probeValue }
        }
        var run = SpikeRun(
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
            metrics: windowMetrics,
            note: nil,
            outcome: outcome,
            abortReason: reason
        )
        // Telemetry envelope (gh#273 §4.1): the window belongs to the day
        // and the account the day's record is CLAIMED under — the same
        // owner the daily carries, never the live session (final review
        // P2-2: a window closed between an account switch and the flush
        // that notices it would otherwise go to the new account while the
        // counts it sat in went to the old). Explicit, nil included.
        run.dayKey = dailyDay.dayKey
        run.dayTZOffsetMin = dailyDay.tzOffsetMin
        run.kind = .window
        SpikeRunStore.finishRun(run, owner: .explicit(dailyClaim.ownerUID), location: location)
        if let followerResult {
            DiagnosticTrail.record("FixWatch", followerResult.trailLine(windowID: run.id))
        }
    }

    // MARK: Flushes

    private func handleLifecycleEdge() {
        // S8: `willResignActive` and `didEnterBackground` both land here on
        // one backgrounding; the token makes the cycle flush once.
        guard !lifecycleEdgeFlushed else { return }
        lifecycleEdgeFlushed = true
        closeWindow(outcome: .completed, closedByResign: true)
        flushDailyRecord()
        // gh#273 §7.1 edge 4: the records are on disk; the uploader wraps
        // what follows in a background task and sends event records plus
        // (throttled) today's daily.
        onUploadTrigger?(.backgroundEdge)
    }

    /// Also the deck's read barrier: FixWatchView calls this on appear so
    /// the evaluator always reads a line that includes today so far.
    func flushDaily() {
        flushDailyRecord()
        // gh#273 §7.1 edge 3: opening the deck is an upload point.
        onUploadTrigger?(.deckOpen)
    }

    private func flushDailyRecord() {
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
        // bound.
        resetCountsForNewDaily()
        mintDailyRun(at: currentNow, bounds: rebaseDay(at: currentNow))
        // gh#273 §7.1 edge 2: yesterday's line is final; send it.
        onUploadTrigger?(.dayRollover)
    }

    /// Recomputes the cached day bound for the day holding `date`. The ONLY
    /// places calendar math runs are init and here — reached from the
    /// rollover and the erase, never from the signal path.
    private func rebaseDay(at date: Date) -> ResidentDayBounds {
        let bounds = ResidentDayBounds.compute(for: date, calendar: calendar)
        dayBounds = bounds
        dayEndSinceReference = bounds.dayEnd.timeIntervalSinceReferenceDate
        return bounds
    }

    /// gh#273 review P2-3 — consent is a claim change in time. The day's
    /// record was minted at launch, BEFORE the user turned the switch on,
    /// so its `startedAt` is below the watermark and nothing counted today
    /// would ever upload. Close that id under its own claim (it stays
    /// local), reset the counters, mint a fresh same-day id at `now` —
    /// at or after the consent the view just recorded — and WRITE it at
    /// once (device bug, build 17: an id that lived only in memory left the
    /// OFF → ON batch reading a disk of pre-consent records, so switching on
    /// and tapping "Upload now" sent nothing). The zero-count line is itself
    /// the "this install is active today" mark. Like the
    /// owner-switch re-mint, this resets `windowsOpened` with the counters,
    /// so the day may admit up to one more round of 12 auto-windows —
    /// accepted (same shape as a same-day account switch).
    func remintDailyForConsent() {
        // First the day: a process that crossed midnight with no signal still
        // holds yesterday's `dayBounds` (23:50 to background, 00:10 back,
        // straight to the switch). Minting against them would give the new
        // id today's `startedAt` under yesterday's `dayKey`, and the next
        // rollover would close it at yesterday's day end — `ended_at <
        // started_at` on the wire (final review P1-1).
        performRolloverFlushIfDue()
        if dailyHasUnwrittenCounts {
            appendDailyRecord(endedAt: now(), claim: dailyClaim)
        }
        resetCountsForNewDaily()
        mintDailyRun(at: now(), bounds: dayBounds)
        writeDailyRecord()
    }

    // MARK: Erase

    /// "Erase all local data": everything this center holds in memory is the
    /// erased owner's day — the counters, the followers, the gesture log, the
    /// daily id and the claim it was minted under, and an auto-window that may
    /// be open right now. `SpikeRunStore.wipe()` took the files; without this
    /// the next flush wrote the whole pre-erase day back under the old owner
    /// (a claim change closes the old id under its OWN claim), and the open
    /// window's close wrote the pre-erase gestures. Told, not reached around,
    /// like `TelemetryUploader.forgetAfterErase`.
    ///
    /// Writes NOTHING: the window is torn down without a record, and the day
    /// starts over under a fresh id minted for the claim that holds now — so
    /// the eraser calls this after signing out and after the wipe. The day
    /// bound is recomputed here rather than by the rollover path, which would
    /// first close the old id with a write.
    func forgetAfterErase() {
        windowCloseWorkItem?.cancel()
        windowCloseWorkItem = nil
        window = nil
        _ = frameProbe?.stopAndSummarize()
        frameProbe = nil
        _ = followers.disarmWindow()

        resetCountsForNewDaily()
        let currentNow = now()
        mintDailyRun(at: currentNow, bounds: rebaseDay(at: currentNow))
    }

    /// "Upload now"'s read barrier (device fix, build 17): writes today's
    /// counts so far — rolling the day over first if midnight passed with no
    /// signal — WITHOUT telling the uploader. Its caller
    /// (`TelemetryUploader.uploadNow`) schedules the batch itself;
    /// `flushDaily()` would schedule a second `.deckOpen`. A rollover found
    /// here still fires its own `.dayRollover`, which the uploader merges.
    func flushForManualUpload() {
        flushDailyRecord()
    }

    /// Whether closing the current daily id would write anything new. A
    /// never-written id (fresh mint) counts as dirty only if something was
    /// counted since — closing a pristine id as an empty record (as the
    /// first re-mint after a rollover would have) is a line with no
    /// information and a revision the uploader would send.
    private var dailyHasUnwrittenCounts: Bool {
        if let lastWrittenCounters {
            return lastWrittenCounters != core.counters || lastWrittenStartedAt != dailyRunStartedAt
                || !followersMatchLastWrite
        }
        return core.counters != ResidentCounterSet() || !followers.dailyIsEmpty
    }

    private var followersMatchLastWrite: Bool {
        followers.dailyEquals(lastWrittenFollowers) && followers.dailyOverflow == lastWrittenFollowerOverflow
    }

    private func writeDailyRecord(endedAt: Date? = nil) {
        let context = stamp()
        let claim = Self.currentClaim(stamp: context, ownerUID: ownerUID())
        if claim != dailyClaim {
            // The owner changed since this id was minted (sign-in, sign-out,
            // account switch — the other three parts cannot change in a
            // live process). The counts so far belong to the owner who was
            // signed in while they accrued: close THIS id under its own
            // claim, then start a fresh same-day id for the new owner. The
            // few signals between the switch and this flush land on the old
            // owner — the same class of imprecision as the midnight hop.
            if dailyHasUnwrittenCounts {
                appendDailyRecord(endedAt: endedAt ?? now(), claim: dailyClaim)
            }
            resetCountsForNewDaily()
            mintDailyRun(at: now(), bounds: dayBounds)
            return
        }
        // Dirty check (B·F6). A rollover close always writes: its `endedAt`
        // is the day end, which marks the line as complete (F20) even when
        // nothing was counted since the last flush.
        if endedAt == nil,
           lastWrittenCounters == core.counters,
           lastWrittenStartedAt == dailyRunStartedAt,
           followersMatchLastWrite {
            return
        }
        appendDailyRecord(endedAt: endedAt ?? now(), claim: claim)
    }

    private func appendDailyRecord(endedAt: Date, claim: TelemetryClaimKey) {
        let context = stamp()
        let followerDay = followers.dailySnapshot()
        let followerOverflow = followers.dailyOverflow
        // The follower keys sit beside the counters under their own prefix.
        let metrics = core.counters.metrics.merging(followerDay.dailyMetrics(overflow: followerOverflow)) { counter, _ in counter }
        var run = SpikeRun(
            id: dailyRunID,
            spikeID: FixObservationRegistry.residentDailySpikeID,
            scenarioID: FixObservationRegistry.residentDailyScenarioID,
            variantID: nil,
            startedAt: dailyRunStartedAt,
            endedAt: endedAt,
            appVersion: context.appVersion,
            appBuild: claim.appBuild,
            appCommit: context.appCommit,
            deviceModel: context.deviceModel,
            osVersion: claim.osVersion,
            timeZoneIdentifier: context.timeZoneIdentifier,
            localeIdentifier: context.localeIdentifier,
            buildConfiguration: claim.buildConfiguration,
            metrics: metrics,
            note: nil,
            outcome: .completed,
            abortReason: nil
        )
        run.dayKey = dailyDay.dayKey
        run.dayTZOffsetMin = dailyDay.tzOffsetMin
        run.kind = .dailyRollup
        // The claim's owner, explicitly — a nil (signed-out) claim closes
        // out as nil even while the provider knows the next account (P1-1).
        if SpikeRunStore.finishRun(run, owner: .explicit(claim.ownerUID), location: location) {
            lastWrittenCounters = core.counters
            lastWrittenStartedAt = dailyRunStartedAt
            lastWrittenFollowers = followerDay
            lastWrittenFollowerOverflow = followerOverflow
        }
    }
}
