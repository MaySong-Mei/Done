//
//  Spike201EffortTap.swift
//  Done
//
//  gh#201 SPIKE — "effort tap-to-feedback still feels delayed after #162".
//
//  #162 fixed the DRAG hot path and proved it on device. This runner
//  times a direct TAP's three candidate gaps separately — see
//  `SpikeGesturePhase` for what each gap means and which hypothesis it
//  belongs to.
//
//  FIX WATCH MIGRATION NOTE: on the spike branch this file also carried
//  `Spike201EffortTap` — the round-2 experiment machinery (armed variant
//  snapshot + the production gate in `EventStore.upsertLogRecord` that
//  removed one publish per non-stock variant). That machinery answered
//  its attribution question and was NOT migrated: post-#201 king ships
//  the coalesced colour-depth mirror with no spike gate, and this runner
//  is measurement-only. With no run armed, every emit is a single
//  optional-closure nil-check.
//
//  Runner shape (register with the coordinator, never touch the seams
//  directly; write-ahead open record; probe invalidated on every finish
//  path) is `Spike195Runner`'s, ported rather than reinvented.
//

import Combine
import Foundation
import QuartzCore

@MainActor
final class Spike201Runner: ObservableObject {
    static let spikeID = Spike201SignalID.spikeID
    static let scenarioID = Spike201SignalID.scenarioID

    enum State: Equatable {
        case idle
        case armed(SpikeRun)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCompletedRun: SpikeRun?

    weak var coordinator: SpikeSessionCoordinator?

    private var frameProbe: SpikeFrameProbe?
    private var log = Spike201GestureLog()
    /// Delivery-lag epoch conversion + implausible-reading quarantine.
    /// Lives on the runner, not in the emitter: the production emitter
    /// carries the raw `Date` so it never has to import QuartzCore just to
    /// report a touch, and `CACurrentMediaTime()` is already read here.
    private var lagTracker = Spike201DeliveryLagTracker()
    /// All three clocks, read once at arm (gh#201 round 3 / R10).
    private var epochStamp: Spike201EpochStamp?

    /// Where this runner's records are written. `.production` in the app;
    /// the harness tests point it at an ephemeral directory so
    /// instantiating a runner cannot leave a line in the real run log.
    var storageLocation: SpikeRunStorageLocation = .production

    var isArmed: Bool {
        if case .armed = state { return true }
        return false
    }

    /// Gestures recorded so far — the detail page shows this live so the
    /// user can see the rig is actually seeing their taps instead of
    /// tapping twenty times into a run that was never wired.
    var recordedGestureCount: Int { log.records.count }
    /// Run-level signal totals, shown live beside the gesture count so
    /// "the wire is dead" and "the work is genuinely not happening" are
    /// distinguishable at a glance instead of hours later in the file.
    var recordedCalendarPageBodyTotal: Int { log.runCalendarPageBodyTotal }
    var recordedCalendarDayLayerTotal: Int { log.runCalendarDayLayerTotal }
    var recordedCalendarDayLayerAppliedTotal: Int { log.runCalendarDayLayerAppliedTotal }

    func start(store: EventStore) {
        guard case .idle = state else { return }
        guard let coordinator else { return }
        log = Spike201GestureLog()
        lagTracker = Spike201DeliveryLagTracker()
        epochStamp = Spike201EpochStamp(
            mediaTime: CACurrentMediaTime(),
            systemUptime: ProcessInfo.processInfo.systemUptime,
            dateSinceReferenceDate: Date().timeIntervalSinceReferenceDate
        )

        let context = SpikeRunContext.stamp()
        let openRun = SpikeRun(
            id: UUID(),
            spikeID: Self.spikeID,
            scenarioID: Self.scenarioID,
            // No variants on this branch — the experiment machinery
            // stayed on the spike branch (see the header note).
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
            onSlotCommitted: { [weak self] slot in
                self?.log.noteSlotWrite(slot: slot)
            },
            stop: { [weak self] in
                self?.cancel()
            }
        )
        SpikeRunStore.beginRun(stamped, location: storageLocation)

        let probe = SpikeFrameProbe()
        // Set BEFORE start: a tick that arrives between start() and the
        // assignment would be a silently lost frame boundary.
        probe.onTick = { [weak self] timestamp in
            self?.log.noteFrame(at: timestamp)
        }
        probe.start()
        frameProbe = probe

        state = .armed(stamped)
    }

    /// Stopping IS this scenario's normal completion — there is no
    /// character-count threshold to cross, the user decides when they have
    /// tapped enough. Named `cancel` because that is the coordinator's
    /// stop-handler contract (`Registration.stop`), which the Active Runs
    /// card and Stop All both route through.
    func cancel() {
        finish()
    }

    private func handle(_ signal: SpikeSignal) {
        switch signal {
        case .bodyPass(let id):
            // Three DISTINCT counters, never merged. `parentBody` keeps
            // exactly the meaning it has had since #195 — the detail
            // page's own body. The two calendar ids are round 2's direct
            // evidence for where the post-commit storm lands, which round
            // 1 could only infer.
            log.noteBodyPass(signalID: id)
        case .textLength, .counter, .invariant:
            break
        case .gesture(let id, let phase, let eventTime, let locationX):
            guard id == Spike201SignalID.effortScrubber else { return }
            // ONE clock. gh#201 round 1 read two (`CACurrentMediaTime()`
            // for intervals, `Date()` to difference against the touch's own
            // stamp) and the delivery lag came back as ~8.097e11 ms —
            // about 25.7 years — on every sample, because SwiftUI's
            // `DragGesture.Value.time` is not on the wall-clock epoch: it
            // behaves as `Date(timeIntervalSinceReferenceDate:
            // systemUptime)`. Read in the media timebase it is actually
            // on, it is a lag. See `Spike201DeliveryLagTracker`.
            let now = CACurrentMediaTime()
            // The RAW reading is recorded unconditionally, including when
            // it is absurd; the tracker's plausibility filter governs the
            // aggregates only (gh#201 round 3 / R10).
            let rawLagMs = eventTime.map {
                Spike201DeliveryLagTracker.lagMs(eventTime: $0, mediaTimeNow: now)
            }
            let lagMs = lagTracker.admit(eventTime: eventTime, mediaTimeNow: now)
            log.ingest(
                phase: phase,
                at: now,
                locationX: locationX,
                deliveryLagMs: lagMs,
                rawDeliveryLagMs: rawLagMs
            )
        }
    }

    private func finish() {
        guard case .armed(let openRun) = state else { return }

        let frameResult = frameProbe?.stopAndSummarize()
        frameProbe = nil
        coordinator?.unregister(runID: openRun.id)

        let records = log.records
        var metrics = Spike201Metrics.summarize(records)
        metrics["gestures"] = .string(Spike201Metrics.csv(records))
        for (key, value) in Spike201Metrics.runTotals(log) {
            metrics[key] = value
        }
        for (key, value) in epochStamp?.metrics ?? [:] {
            metrics[key] = value
        }
        for (key, value) in frameResult?.metrics ?? [:] {
            metrics[key] = value
        }
        // Recorded unconditionally, including the zero: "the epoch
        // conversion produced nothing absurd" is a result worth being able
        // to read off the line, and an absent key would be
        // indistinguishable from a rig that forgot to look.
        metrics["implausibleLagCount"] = .number(Double(lagTracker.implausibleCount))
        if let firstImplausible = lagTracker.firstImplausibleMs {
            metrics["implausibleLagFirstMs"] = .number(firstImplausible)
        }

        var closedRun = openRun
        closedRun.endedAt = Date()
        // A run with no gesture at all is not a completed measurement: the
        // user armed it and nothing reached the instrument. Recorded as
        // aborted with the reason, so an empty file line can never be read
        // later as "we measured, and there was nothing there".
        if records.isEmpty {
            closedRun.outcome = .aborted
            closedRun.abortReason = "stopped with no effort-scrubber gesture recorded"
        } else {
            closedRun.outcome = .completed
        }
        closedRun.metrics = metrics
        SpikeRunStore.finishRun(closedRun, location: storageLocation)

        lastCompletedRun = closedRun
        log = Spike201GestureLog()
        lagTracker = Spike201DeliveryLagTracker()
        epochStamp = nil
        state = .idle
    }
}
