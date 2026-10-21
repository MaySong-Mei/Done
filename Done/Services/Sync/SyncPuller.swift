//
//  SyncPuller.swift
//  Done
//
//  The pull chain — design §4 (SyncPuller), I1 / I9, §6.6 (the per-page
//  epoch check, the reset at the chain boundary, the catch-up) and §7 (8)
//  of Docs/sync/00-realtime-sync-design.md.
//
//  One chain at a time (I9): a trigger while a chain runs only sets
//  `rerun`, and the next chain starts when this one ends. Every page:
//
//    1. `LocalDataEraseEpoch.capture()`, then `sync_changes` from the cursor;
//    2. GET `sync_epoch` — after the RPC answered, so a page from the new
//       timeline is never applied under the old epoch. An empty page is
//       followed by the same GET (the first page after a restore is usually
//       empty). A different epoch: `sync.epoch.changed`, the chain is
//       abandoned (nothing written) and the executor resets at the chain
//       boundary. `paused`: the chain is abandoned without a reset.
//    3. the §6.6 pre-questions (`is_ancestor` for stale rows the page
//       carries), then the applier; a refused page ends the chain off head;
//    4. at head: I1 opens, pending-verify resolves, orphans log, a catch-up
//       finalizes (re-uploads, dead-row inserts) and computes the one
//       prompt, and the tables that owe a flush get one.
//
//  Feed unavailable (§7 (7), the seat belt): a 404 / `PGRST2xx` from the
//  feed RPC or the epoch GET means migration 015 is not applied. The engine
//  marks `feedUnavailable`, logs `sync.feed.unavailable`, and opens I1 so
//  today's whole-table uploads continue; the next session probes again.
//
//  Triggers: launch (session begin), foreground, the doorbell's `.joined`
//  and its frames (coalesced 300 ms), a 60 s poll while active. The session
//  sink in `SupabaseSyncService.attach` feeds `sessionDidChange`.
//

import Foundation
import UIKit

@MainActor
final class SyncPuller {
    private unowned let engine: SupabaseSyncService
    private let gateway: SyncGateway
    let shelf: ConflictShelf
    private let scheduler: SyncScheduler
    private let doorbell: SupabaseRealtimeDoorbell?
    let recovery: SyncRecovery

    /// The stores the applier writes. `configure` sets them; a session
    /// without them pulls nothing.
    private weak var eventStore: EventStore?
    private weak var eventTypeStore: EventTypeTemplateStore?
    private weak var skillStore: SkillInsightStore?
    private var singletons: [String: SyncSingletonAdapter] = [:]

    nonisolated static let pollInterval: TimeInterval = 60
    nonisolated static let doorbellCoalesce: TimeInterval = 0.3
    var pageLimit = SyncGatewayLimits.defaultPageLimit
    /// Whether the session subscribes to `willEnterForegroundNotification`.
    /// The app always does; a test harness opts out so a notification the
    /// test host receives mid-run cannot start a chain the test did not ask
    /// for (`foregroundDidReturn()` is called directly instead).
    var observesForeground = true

    private(set) var pullIssue = 0
    private var chain: Task<Void, Never>?
    private var rerun = false
    private var rerunReason = "rerun"
    private var sessionGeneration = 0
    private(set) var active = false
    private(set) var feedUnavailable = false
    /// The domino head gate (design §6 domino 段, §10.5; contract in
    /// `SyncHeadGate.swift`): this engine is its single writer — running
    /// while a session pulls, every chain reported at start and at end with
    /// I1's verdict, off when the feed is missing or the session ends.
    /// `installInbound` hands in the app's shared flag; a test hands in its
    /// own.
    var headFlag: SyncHeadFlag?
    private(set) var pausedLogged = false
    /// The epoch of the reset whose catch-up is in progress; nil otherwise.
    private(set) var catchUpEpoch: String?
    private var pendingReset: SyncEpochRow?
    private var pollWork: SyncScheduledWork?
    private var frameDebouncer: SyncDebouncer<Void>?
    private var foregroundObserver: NSObjectProtocol?
    private var doorbellFrameAt: ContinuousClock.Instant?

    /// Test seam: every chain's reason and status, in order.
    var trace: ((String) -> Void)?

    init(engine: SupabaseSyncService, gateway: SyncGateway, shelf: ConflictShelf,
         scheduler: SyncScheduler, doorbell: SupabaseRealtimeDoorbell? = nil) {
        self.engine = engine
        self.gateway = gateway
        self.shelf = shelf
        self.scheduler = scheduler
        self.doorbell = doorbell
        self.recovery = SyncRecovery(engine: engine, gateway: gateway, shelf: shelf)
        self.recovery.applyLocally = { [weak self] rows in self?.applyWithoutCursor(rows) }
        engine.onNeedsPull = { [weak self] in self?.requestPull(reason: "verify") }
        engine.onEpochStale = { [weak self] in self?.requestPull(reason: "gate") }
        engine.pullIssueCounter = { [weak self] in self?.pullIssue ?? 0 }
        wireDoorbell()
    }

    func configure(eventStore: EventStore, eventTypeStore: EventTypeTemplateStore?,
                   skillStore: SkillInsightStore?, singletons: [String: SyncSingletonAdapter] = [:]) {
        self.eventStore = eventStore
        self.eventTypeStore = eventTypeStore
        self.skillStore = skillStore
        self.singletons = singletons
    }

    // MARK: Session

    /// The session sink: a session begins pulling, nil ends it. A repeat
    /// of the same uid (a token refresh) only re-hands the doorbell its
    /// credentials.
    func sessionDidChange(signedIn: Bool) {
        if signedIn {
            if active {
                doorbell?.credentialsDidChange()
            } else {
                beginSession()
            }
        } else {
            endSession()
        }
    }

    /// `autoPull: false` is the test seam: the session begins without the
    /// launch chain, which the test then drives with `pullToHead`.
    func beginSession(autoPull: Bool = true) {
        guard !engine.userId.isEmpty, engine.ownerState.allowsSync else { return }
        active = true
        sessionGeneration += 1
        feedUnavailable = false
        headFlag?.engineRunning = true
        headFlag?.pullNow = { [weak self] in
            Task { @MainActor in self?.requestPull(reason: "domino") }
        }
        pausedLogged = false
        catchUpEpoch = engine.baseline.hasStaleEntries ? engine.cursor.epoch : nil
        engine.inboundAtHead = false
        adoptEpochHeader(engine.cursor.epoch)
        recovery.refreshBadge()
        doorbell?.credentialsDidChange()
        doorbell?.start()
        startPolling()
        observeForeground()
        if autoPull { requestPull(reason: "launch") }
    }

    /// `$session → nil` (design §6.4): stop, drop every in-memory table,
    /// persist nothing.
    func endSession() {
        active = false
        headFlag?.engineRunning = false
        headFlag?.pullNow = nil
        sessionGeneration += 1
        chain = nil
        rerun = false
        pendingReset = nil
        catchUpEpoch = nil
        adoptEpochHeader(nil)
        doorbell?.stop()
        stopPolling()
        frameDebouncer?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
    }

    // MARK: Triggers

    private func wireDoorbell() {
        guard let doorbell else { return }
        doorbell.onStateChange = { [weak self] state in
            guard let self, state == .joined else { return }
            self.requestPull(reason: "joined")
        }
        doorbell.onChange = { [weak self] _ in
            guard let self else { return }
            if self.doorbellFrameAt == nil { self.doorbellFrameAt = ContinuousClock.now }
            if self.frameDebouncer == nil {
                self.frameDebouncer = SyncDebouncer(delay: Self.doorbellCoalesce, scheduler: self.scheduler) { [weak self] in
                    self?.requestPull(reason: "doorbell")
                }
            }
            self.frameDebouncer?.submit(())
        }
    }

    private func startPolling() {
        stopPolling()
        pollWork = scheduler.schedule(after: Self.pollInterval) { [weak self] in
            guard let self, self.active else { return }
            self.requestPull(reason: "poll")
            self.startPolling()
        }
    }

    private func stopPolling() {
        pollWork?.cancel()
        pollWork = nil
    }

    private func observeForeground() {
        guard observesForeground, foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.foregroundDidReturn() }
        }
    }

    /// Foreground: a pull — and, on a server the feed was found missing
    /// on, one fresh probe (migration 015 may have been applied since;
    /// design §7 (7) "下次启动再探" extended to the foreground).
    func foregroundDidReturn() {
        guard active else { return }
        if feedUnavailable {
            feedUnavailable = false
            DiagnosticTrail.record("Sync", "sync.feed.reprobe reason=foreground")
        }
        requestPull(reason: "foreground")
    }

    /// Single flight (I9): a running chain absorbs the trigger as a rerun.
    func requestPull(reason: String) {
        guard active else { return }
        if chain != nil {
            rerun = true
            rerunReason = reason
            return
        }
        let generation = sessionGeneration
        chain = Task { [weak self] in
            await self?.runChains(reason: reason, generation: generation)
        }
    }

    /// Test convenience: trigger and wait for every chain the trigger (and
    /// its reruns / resets) leads to.
    func pullToHead(reason: String = "test") async {
        requestPull(reason: reason)
        // `runChains` clears `chain` when it ends; a trigger that arrived
        // meanwhile started another, which the next turn of the loop awaits.
        while let running = chain {
            await running.value
        }
    }

    private func runChains(reason: String, generation: Int) async {
        var next: String? = reason
        while let current = next, generation == sessionGeneration {
            rerun = false
            // A probe after the feed was found missing runs the engine again;
            // `handlePullError` turns it off if the feed is still missing.
            if !feedUnavailable { headFlag?.engineRunning = true }
            headFlag?.chainStarted()
            await runChain(reason: current, generation: generation)
            guard generation == sessionGeneration else { break }
            if let reset = pendingReset {
                pendingReset = nil
                performReset(reset)
                rerun = true
                rerunReason = "reset"
            }
            next = rerun ? rerunReason : nil
            // I1's verdict for this chain; a rerun keeps the session off head
            // until the chain it starts ends.
            headFlag?.chainEnded(atHead: engine.inboundAtHead && next == nil)
        }
        // A session that ended meanwhile already dropped this chain, and
        // may have started another: only the chain's own session clears it.
        if generation == sessionGeneration { chain = nil }
    }

    // MARK: One chain

    private func runChain(reason: String, generation: Int) async {
        guard let store = eventStore, !engine.userId.isEmpty, engine.ownerState.allowsSync, !feedUnavailable else {
            trace?("chain \(reason) skipped")
            return
        }
        var since = engine.cursor.value ?? 0
        var seen: Set<SyncBaselineKey> = []
        var lastIssue = pullIssue
        var pages = 0
        var rows = 0
        let frameAt = reason == "doorbell" ? doorbellFrameAt : nil
        if reason == "doorbell" { doorbellFrameAt = nil }
        var status = "head"

        pageLoop: while true {
            let token = LocalDataEraseEpoch.capture()
            pullIssue += 1
            let issue = pullIssue
            lastIssue = issue

            let page: [SyncFeedRow]
            do {
                page = try await gateway.pullChanges(sinceSeq: since, pageLimit: pageLimit)
            } catch {
                status = handlePullError(error, what: "sync_changes")
                break pageLoop
            }
            guard generation == sessionGeneration else { return }

            let epochRow: SyncEpochRow
            do {
                epochRow = try await gateway.fetchSyncEpoch()
            } catch {
                status = handlePullError(error, what: "sync_epoch")
                break pageLoop
            }
            guard generation == sessionGeneration else { return }

            if let known = engine.cursor.epoch {
                if known != epochRow.epoch {
                    DiagnosticTrail.record("Sync", "sync.epoch.changed old=\(known) new=\(epochRow.epoch)")
                    pendingReset = epochRow
                    status = "epoch_changed"
                    break pageLoop
                }
            } else {
                engine.cursor.recordEpoch(epochRow.epoch, baseline: engine.baseline)
                adoptEpochHeader(epochRow.epoch)
            }
            if epochRow.paused {
                if !pausedLogged {
                    pausedLogged = true
                    DiagnosticTrail.record("Sync", "sync.paused")
                }
                engine.serverPaused = true
                status = "paused"
                break pageLoop
            }
            engine.serverPaused = false

            let head = SyncGatewayLimits.isHead(rowCount: page.count, requestedLimit: pageLimit)
            if !page.isEmpty {
                let ancestry = await preQueryAncestry(page)
                guard generation == sessionGeneration else { return }
                var context = SyncApplyContext(engine: engine, shelf: shelf, eraseToken: token, pullIssue: issue)
                context.eventTypeStore = eventTypeStore
                context.skillStore = skillStore
                context.singletons = singletons
                if let catchUpEpoch {
                    context.catchUp = SyncCatchUpContext(epoch: catchUpEpoch, ancestry: ancestry)
                }
                let remote = RemotePage(rows: page)
                let outcome = store.applyRemote(remote, context: context)
                pages += 1
                rows += page.count
                seen.formUnion(outcome.seen)
                guard outcome.countsAsApplied else {
                    status = "refused"
                    break pageLoop
                }
                if let committed = outcome.cursor { since = committed } else if let last = remote.lastSeq { since = last }
                engine.noteObservedSeq(since)
                if !outcome.directTombstones.isEmpty {
                    await tombstoneEventTypeLosers(outcome.directTombstones)
                    guard generation == sessionGeneration else { return }
                }
            }
            if head { break pageLoop }
        }

        var line = "sync.pull reason=\(reason) pages=\(pages) rows=\(rows) status=\(status)"
        if let frameAt {
            let elapsed = ContinuousClock.now - frameAt
            line += " latency_ms=\(Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15))"
        }
        DiagnosticTrail.record("Sync", line)
        trace?("chain \(reason) \(status)")
        guard generation == sessionGeneration else { return }
        if status == "feed_unavailable" {
            // The seat belt (design §7 (7)): I1 is open, and the tables the
            // session start held — the launch upload of offline edits —
            // go out now, as today's build sends them.
            await engine.flushPendingTables()
            return
        }
        guard status == "head" else { return }

        // At head.
        let cleared = engine.resolvePendingVerifyAtHead(seen: seen, pullIssue: lastIssue)
        if !cleared.isEmpty { trace?("pending-verify cleared \(cleared.count)") }
        for orphan in engine.orphansAfterHeadPull() {
            DiagnosticTrail.record("Sync", "sync.push.orphan table=\(orphan.table) id=\(orphan.id)")
        }
        if catchUpEpoch != nil {
            let finalized = await SyncCatchUp.finalize(engine: engine, gateway: gateway)
            guard generation == sessionGeneration else { return }
            trace?("catchup finalized reupload=\(finalized.reuploaded.count) dead=\(finalized.deadInserted.count)")
            catchUpEpoch = nil
            await recovery.computeOffers()
            guard generation == sessionGeneration else { return }
        }
        // I1 opens only now: after the catch-up's own writes and the
        // prompt's questions, so no debounced flush can interleave with them.
        engine.inboundAtHead = true
        await engine.flushPendingTables()
    }

    private func handlePullError(_ error: Error, what: String) -> String {
        if Self.isFeedUnavailable(error) {
            feedUnavailable = true
            engine.inboundAtHead = true
            headFlag?.engineRunning = false
            DiagnosticTrail.record("Sync", "sync.feed.unavailable what=\(what) code=\(SyncWriteFailure.classify(error).code)")
            return "feed_unavailable"
        }
        DiagnosticTrail.record("Sync", "sync.pull.failed what=\(what) code=\(SyncWriteFailure.classify(error).code)")
        return "failed"
    }

    /// A server without migration 015: the RPC / relation is not in
    /// PostgREST's schema cache (404, `PGRST2xx`).
    nonisolated static func isFeedUnavailable(_ error: Error) -> Bool {
        guard let syncError = error as? SupabaseREST.SyncError else { return false }
        switch syncError {
        case .requestFailed(_, _, let status, let code):
            return status == 404 || (code?.hasPrefix("PGRST2") ?? false)
        case .fetchFailed(_, let status):
            return status == 404
        default:
            return false
        }
    }

    /// The §6.6 questions a page raises on its stale rows, asked before
    /// the page is applied (the applier is synchronous).
    private func preQueryAncestry(_ page: [SyncFeedRow]) async -> [SyncBaselineKey: Bool?] {
        guard catchUpEpoch != nil else { return [:] }
        var answers: [SyncBaselineKey: Bool?] = [:]
        var unknown = 0
        for row in page where !SupabaseSyncService.isTombstoned(row.data) {
            guard let key = SupabaseSyncService.baselineKey(forFeedRow: row, userId: engine.userId) else { continue }
            let base = engine.baseline.entry(table: key.table, id: key.id)
            let origin = engine.baseline.origin(table: key.table, id: key.id)
            guard let question = SyncCatchUp.ancestryQuestion(base: base, origin: origin, incomingVid: row.data["version_id"] as? String) else { continue }
            do {
                let answer = try await gateway.isAncestor(table: row.table, id: key.id, a: question.a, b: question.b)
                answers[key] = answer
                if answer == nil { unknown += 1 }
            } catch {
                answers[key] = .some(nil)
                unknown += 1
            }
        }
        if unknown > 0 { DiagnosticTrail.record("Sync", "sync.ancestry unknown=\(unknown)") }
        return answers
    }

    private func tombstoneEventTypeLosers(_ ids: [String]) async {
        do {
            _ = try await gateway.tombstone(table: "event_types", keyColumn: "id", keys: ids, deletedAt: scheduler.now())
        } catch {
            DiagnosticTrail.record("Sync", "sync.apply.loser_tombstone_failed table=event_types code=\(SyncWriteFailure.classify(error).code)")
        }
    }

    // MARK: Reset

    private func performReset(_ row: SyncEpochRow) {
        SyncCatchUp.reset(engine: engine, newEpoch: row.epoch, ledger: row.restores)
        adoptEpochHeader(row.epoch)
        catchUpEpoch = row.epoch
        engine.inboundAtHead = false
    }

    /// The one place the device's epoch reaches the wire (design §6.6
    /// 服务端写闸): every write from here on carries it as `X-Sync-Epoch`.
    private func adoptEpochHeader(_ epoch: String?) {
        gateway.writeEpoch = epoch
    }

    /// A write-back landed: its rows are applied like a page, the cursor
    /// untouched (the write's seq is not a feed position).
    private func applyWithoutCursor(_ rows: [SyncFeedRow]) {
        guard let store = eventStore, !rows.isEmpty else { return }
        pullIssue += 1
        var context = SyncApplyContext(engine: engine, shelf: shelf, eraseToken: LocalDataEraseEpoch.capture(), pullIssue: pullIssue)
        context.eventTypeStore = eventTypeStore
        context.skillStore = skillStore
        context.singletons = singletons
        context.commitsCursor = false
        _ = store.applyRemote(RemotePage(rows: rows), context: context)
    }
}
