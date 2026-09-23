//
//  SpikeSessionCoordinator.swift
//  Done
//
//  gh#197 SPIKE v2 — app-level ownership of armed spike runs.
//
//  v1 shipped with `SpikeDetailView` owning its runner via `@StateObject`.
//  The settings root is sheet-presented, so dismissing the sheet destroyed
//  the view and deallocated the runner mid-run: `SpikeProbe.onSignal` kept
//  a `[weak self]` closure whose self was gone (every typed character
//  silently dropped, the run never closed until next-launch
//  reconciliation), and the CADisplayLink kept its dead runner's probe
//  alive ticking forever, growing its sample array until the process died.
//  This coordinator exists so an armed run's lifetime is tied to the
//  PROCESS, not to any presented screen: it is created once at the app
//  root (`DoneApp`), injected via `.environmentObject` exactly like
//  `EventStore`, and the spike views are remote controls that read it from
//  the environment.
//
//  It is also the single writer of the two physical instrumentation seams:
//
//    * `SpikeProbe.onSignal` — set to exactly one closure that fans out to
//      every currently registered listener, and set back to `nil` the
//      moment the last listener unregisters. `emit` staying a single
//      optional-closure nil-check while nothing is armed is a contract,
//      not an implementation detail.
//    * `EventStore.onSlotCommitted` — same fan-out, managed per store
//      instance. In v1 each runner assigned these seams directly, so a
//      second armed runner would silently clobber the first one's
//      listener; with assignment concentrated here and runners reduced to
//      register/unregister, that clobbering is impossible by construction.
//
//  A second coordinator instance would contend for the same static seam,
//  so exactly one exists, created at the app root and nowhere else.
//
//  FIX WATCH adds a second listener kind: RESIDENT listeners
//  (`registerResident`), permanently-attached observability consumers
//  with no run, no record, and no place in `armedRunIDs` — they are never
//  co-active-stamped, never block orphan reconciliation, and never expire.
//  The seams install while EITHER kind is attached and return to `nil`
//  only when BOTH are empty; fan-out order is armed runs first, then
//  residents. The inverted-clobber hazard this creates (a finishing
//  manual run must not nil a seam a resident still listens on) is fixed
//  in `unregister` and pinned by `ResidentObservationTests`.
//
//  Lifetime policy (invariant): armed runs survive backgrounding. The
//  probes are asynchronous instruments over a wall-clock measurement
//  window, and a `.userAction` scenario sends the user into production
//  UI where app-switching is normal — suspending the app must not end
//  the run. The only orphan source is process death; next-launch
//  reconciliation closes those, excluding whatever the live coordinator
//  has armed.
//

import Combine
import Foundation

@MainActor
final class SpikeSessionCoordinator: ObservableObject {

    // MARK: Registration record

    /// What the management UI needs to show for one armed run.
    struct ActiveRun: Identifiable, Equatable {
        /// The run's own id — stable across the run's whole lifetime.
        let id: UUID
        let spikeID: String
        let scenarioID: String
        let startedAt: Date
    }

    /// Everything one armed run registers. `stop` is the coordinator's
    /// handle for tearing the run down from the outside (the management
    /// UI's per-run Stop button and its Stop All). Stop contract: the
    /// handler must finish the run AND leave no live probe behind —
    /// invalidating any CADisplayLink it started is part of stopping,
    /// because a display link retains its target and an orphaned probe
    /// outlives every owner. `Spike195Runner.cancel` is the reference
    /// implementation. The handler need not unregister — the coordinator
    /// enforces removal itself after invoking it.
    private struct Registration {
        let spikeID: String
        let scenarioID: String
        let startedAt: Date
        let onSignal: (SpikeSignal) -> Void
        let onSlotCommitted: ((StorageSlot) -> Void)?
        weak var store: EventStore?
        let stop: () -> Void
    }

    // MARK: Owned runners

    /// The #195 runner lives here for the whole process lifetime so an
    /// armed run survives sheet dismissal and any navigation. Views never
    /// own a runner — they read this one through the environment.
    let runner195: Spike195Runner
    /// gh#201's runner, owned for the same reason #195's is: its scenario
    /// sends the user out of settings and into the event detail page to
    /// tap, so the run must outlive this sheet.
    let runner201: Spike201Runner

    // MARK: Published state

    /// Armed runs across all spikes, in arm order (oldest first) — the
    /// data source for `SpikeListView`'s Active Runs card.
    @Published private(set) var activeRuns: [ActiveRun] = []

    // MARK: Private state

    private var registrations: [UUID: Registration] = [:]
    /// Arm order, oldest first. Fan-out and the management UI both follow
    /// this instead of dictionary order so behavior is deterministic.
    private var order: [UUID] = []
    private var runnerChangeForwarders: [AnyCancellable] = []

    /// Fix Watch resident listeners, keyed by their stable id.
    private struct ResidentRegistration {
        let onSignal: (SpikeSignal) -> Void
        let onSlotCommitted: ((StorageSlot) -> Void)?
        weak var store: EventStore?
    }
    private var residents: [String: ResidentRegistration] = [:]
    /// Registration order, for deterministic fan-out.
    private var residentOrder: [String] = []

    /// Fix Watch R-F10: a manual armed run left running (a curious user
    /// taps Start and never Stop) holds a CADisplayLink for every
    /// foreground session indefinitely. The coordinator now enforces an
    /// auto-expiry: each registration schedules a one-shot timer that
    /// routes through the run's own stop handler. Timers pause while the
    /// app is suspended and fire on resume, which is exactly the coverage
    /// needed — a suspended app runs no display link. Residents are not
    /// registrations and never expire.
    let manualRunExpiry: TimeInterval
    static let defaultManualRunExpiry: TimeInterval = 30 * 60
    private var expiryTimers: [UUID: Timer] = [:]

    init(manualRunExpiry: TimeInterval = SpikeSessionCoordinator.defaultManualRunExpiry) {
        self.manualRunExpiry = manualRunExpiry
        // Every stored property first — `self` is not usable for the
        // wiring below until all of them are initialized.
        runner195 = Spike195Runner()
        runner201 = Spike201Runner()

        runner195.coordinator = self
        runner201.coordinator = self
        // The coordinator republishes runner state changes so a view that
        // observes only the coordinator (the one object views hold) also
        // refreshes when a runner arms or finishes.
        for runner in [runner195.objectWillChange.eraseToAnyPublisher(),
                       runner201.objectWillChange.eraseToAnyPublisher()] {
            runner
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &runnerChangeForwarders)
        }
    }

    // MARK: Registration

    /// Run ids armed by THIS process right now. Callers of
    /// `SpikeRunStore.reconcileInterruptedRuns` pass these as exclusions:
    /// an open record on disk is an orphan only when no live runner in
    /// this process owns it.
    var armedRunIDs: Set<UUID> { Set(order) }

    /// Registers an armed run's listeners and returns the run stamped
    /// with its co-active context (`coActiveSpikeIDs` — the OTHER spikes
    /// armed at this moment, never the run's own arming; see the field's
    /// doc comment for the invariants). The caller persists the STAMPED
    /// run, not the one it passed in, so the write-ahead open record on
    /// disk already carries the stamp.
    func register(
        run: SpikeRun,
        store: EventStore?,
        onSignal: @escaping (SpikeSignal) -> Void,
        onSlotCommitted: ((StorageSlot) -> Void)?,
        stop: @escaping () -> Void
    ) -> SpikeRun {
        var stamped = run
        stamped.coActiveSpikeIDs = coActiveSpikeIDsSnapshot()

        registrations[stamped.id] = Registration(
            spikeID: stamped.spikeID,
            scenarioID: stamped.scenarioID,
            startedAt: stamped.startedAt,
            onSignal: onSignal,
            onSlotCommitted: onSlotCommitted,
            store: store,
            stop: stop
        )
        order.append(stamped.id)

        installSignalSeam()
        if let store {
            installSlotSeam(on: store)
        }
        scheduleExpiry(for: stamped.id)
        refreshActiveRuns()
        return stamped
    }

    /// Removes a run's listeners. Called by the runner itself whenever a
    /// run finishes, for any reason. Removing the last listener on a seam
    /// returns that seam to `nil` — the disarmed, zero-cost state.
    func unregister(runID: UUID) {
        guard let removed = registrations.removeValue(forKey: runID) else { return }
        order.removeAll { $0 == runID }
        expiryTimers.removeValue(forKey: runID)?.invalidate()

        // Fix Watch R-F6.1: BOTH listener kinds keep a seam alive. The
        // pre-fix check walked `order` only, so the last manual run's
        // finish silently killed a resident's slot-write counters — the
        // v1→v2 clobber lesson, one seam over.
        if let store = removed.store, !isStoreListenedTo(store) {
            store.onSlotCommitted = nil
        }
        if order.isEmpty && residents.isEmpty {
            SpikeProbe.onSignal = nil
        }
        refreshActiveRuns()
    }

    // MARK: Resident listeners (Fix Watch)

    /// Attaches a permanent observability listener. Idempotent per id —
    /// re-registering replaces the closures. Residents receive every
    /// signal AFTER the armed runs of the same dispatch, and slot commits
    /// for the store they registered with.
    func registerResident(
        id: String,
        store: EventStore?,
        onSignal: @escaping (SpikeSignal) -> Void,
        onSlotCommitted: ((StorageSlot) -> Void)? = nil
    ) {
        if residents[id] == nil {
            residentOrder.append(id)
        }
        residents[id] = ResidentRegistration(
            onSignal: onSignal,
            onSlotCommitted: onSlotCommitted,
            store: store
        )
        installSignalSeam()
        if let store {
            installSlotSeam(on: store)
        }
    }

    func unregisterResident(id: String) {
        guard let removed = residents.removeValue(forKey: id) else { return }
        residentOrder.removeAll { $0 == id }
        if let store = removed.store, !isStoreListenedTo(store) {
            store.onSlotCommitted = nil
        }
        if order.isEmpty && residents.isEmpty {
            SpikeProbe.onSignal = nil
        }
    }

    private func isStoreListenedTo(_ store: EventStore) -> Bool {
        order.contains { registrations[$0]?.store === store }
            || residentOrder.contains { residents[$0]?.store === store }
    }

    // MARK: Manual-run auto-expiry (Fix Watch R-F10)

    private func scheduleExpiry(for runID: UUID) {
        guard manualRunExpiry > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: manualRunExpiry, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.expireOverdueManualRuns()
            }
        }
        expiryTimers[runID] = timer
    }

    /// Stops every armed run older than `manualRunExpiry`. Public and
    /// clock-injected so the rule is assertion-testable without waiting
    /// on a real timer; the scheduled timers just call it.
    func expireOverdueManualRuns(now: Date = Date()) {
        guard manualRunExpiry > 0 else { return }
        let overdue = order.filter { runID in
            guard let registration = registrations[runID] else { return false }
            return now.timeIntervalSince(registration.startedAt) >= manualRunExpiry
        }
        for runID in overdue {
            stop(runID: runID)
        }
    }

    // MARK: External teardown (management UI)

    /// Tears down one armed run from the outside. Delegates to the
    /// registration's stop handler (see `Registration.stop` for the
    /// contract — finishing the run and invalidating its probe are the
    /// handler's job), then unregisters the entry itself, so "the entry
    /// is gone by the time this returns" holds by construction — a no-op
    /// when the handler's finish path already unregistered, enforcement
    /// when it did not.
    func stop(runID: UUID) {
        guard let registration = registrations[runID] else { return }
        registration.stop()
        unregister(runID: runID)
    }

    /// Tears down every armed run (the management UI's Stop All).
    /// Iterates a snapshot because each stop removes its own entry while
    /// the loop runs.
    func stopAll() {
        for runID in order {
            stop(runID: runID)
        }
    }

    // MARK: Seam management (the ONLY writers of the physical seams)

    /// Distinct spike ids currently armed, in arm order. Computed BEFORE
    /// the arming run is inserted, so the arming run can never see itself
    /// — that, not a filter on its own spike id, is what implements
    /// exclude-self: a sibling run of the SAME spike armed earlier is
    /// genuine co-activity and does appear.
    private func coActiveSpikeIDsSnapshot() -> [String] {
        var seen = Set<String>()
        var coActive: [String] = []
        for runID in order {
            guard let spikeID = registrations[runID]?.spikeID, !seen.contains(spikeID) else { continue }
            seen.insert(spikeID)
            coActive.append(spikeID)
        }
        return coActive
    }

    private func installSignalSeam() {
        SpikeProbe.onSignal = { [weak self] signal in
            self?.dispatch(signal)
        }
    }

    private func installSlotSeam(on store: EventStore) {
        store.onSlotCommitted = { [weak self, weak store] slot in
            guard let self, let store else { return }
            self.dispatchSlot(slot, from: store)
        }
    }

    private func dispatch(_ signal: SpikeSignal) {
        for runID in order {
            registrations[runID]?.onSignal(signal)
        }
        for id in residentOrder {
            residents[id]?.onSignal(signal)
        }
    }

    private func dispatchSlot(_ slot: StorageSlot, from store: EventStore) {
        for runID in order {
            guard let registration = registrations[runID],
                  registration.store === store,
                  let handler = registration.onSlotCommitted else { continue }
            handler(slot)
        }
        for id in residentOrder {
            guard let resident = residents[id],
                  resident.store === store,
                  let handler = resident.onSlotCommitted else { continue }
            handler(slot)
        }
    }

    private func refreshActiveRuns() {
        activeRuns = order.compactMap { runID in
            guard let registration = registrations[runID] else { return nil }
            return ActiveRun(
                id: runID,
                spikeID: registration.spikeID,
                scenarioID: registration.scenarioID,
                startedAt: registration.startedAt
            )
        }
    }
}
