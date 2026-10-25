//
//  TelemetryUploader.swift
//  Done
//
//  gh#273 — the telemetry chassis's single writer (design §7; wire contract
//  §1, §5). Reads the spike-run pool, keeps the per-record `revision`
//  cursor, and sends ≤32-row bulk upserts through the sync gateway.
//
//  Shape: a `@MainActor final class` driving ONE serial `Task`, not an
//  `actor`. Reasons, in order of weight:
//    1. Every neighbour it touches is MainActor already — the store the
//       center writes (`SpikeRunStore`, MainActor by the module's default
//       isolation), `AuthService` (the session), `UserDefaults` reads of the
//       switches, and `UIApplication.beginBackgroundTask`. An actor would
//       hop to main for each of those and gain nothing between hops.
//    2. SwiftUI's status row ("上次上传 · 条数 · 累计 · 构建", the sample
//       sheet) needs an `ObservableObject`; an actor cannot publish.
//    3. "Single writer" is a one-line invariant here: `inFlight` is the
//       only Task; a `schedule` while it runs merges into `queued` and runs
//       AFTER it, so a launch catch-up and a background edge can never
//       interleave their cursor writes (B·F22).
//  The one thing an actor would have bought — the pool read off the main
//  thread — is deferred instead: the launch batch runs 2 s after
//  `didBecomeActive` at `.utility` priority (B·F11: zero work before the
//  first frame), and the other three triggers fire from flush edges the
//  center already pays for on main.
//
//  Gates, every batch, in this order (design §7.4 / §8.2): the telemetry
//  switch; `SupabaseSyncService.uploadsBlockedByBuild` — the SAME property
//  the sync engine asks, through a closure, never a second `#if DEBUG`
//  (B·F38; a source-scan test keeps this file free of one); the consent
//  watermark; a signed-in account with a token. Then the pool → collapse →
//  consent filter → cursor → trigger's selection → serialize → Redactor →
//  one request. The cursor moves only on 2xx, and only when no erase began
//  while the request was in flight (`LocalDataEraseEpoch`, design §7.5).
//

import Combine
import Foundation
import SwiftUI
import UIKit

// MARK: - Consent record

/// The two `UserDefaults` facts about consent, read and written through one
/// place so the settings view, the uploader and the tests agree on the key
/// and the type (a `Date`, so "≥ consent" is a date compare, not a string).
enum TelemetryConsentStore {
    static func consentAt(_ defaults: UserDefaults) -> Date? {
        defaults.object(forKey: AppSettingsKeys.telemetryConsentAt) as? Date
    }

    /// OFF → ON writes NOW: records minted before this moment stay local.
    /// ON → OFF leaves the value alone (design §8.2: the switch stops
    /// uploads at once and the cursor is kept; a later ON moves the
    /// watermark forward again).
    static func recordGrant(_ defaults: UserDefaults, at date: Date) {
        defaults.set(date, forKey: AppSettingsKeys.telemetryConsentAt)
    }
}

// MARK: - Background assertion

/// What the uploader holds while edge-triggered work is in flight: begun
/// once, ended once when the queue drains. The production conformance is
/// `UIApplication.beginBackgroundTask`; tests inject a counting double.
@MainActor
protocol TelemetryKeepAlive: AnyObject {
    func end()
}

/// Keeps the process alive through a background-edge upload (≈30 s window,
/// design §7.1 edge 4). Same shape as the widget stats build's assertion in
/// EventStore.swift — the app's one other `beginBackgroundTask`: it extends
/// a running process and relaunches nothing (it is not a background mode).
@MainActor
final class TelemetryBackgroundAssertion: TelemetryKeepAlive {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Telemetry upload") { [weak self] in
            self?.end()
        }
    }

    /// Idempotent: the expiration handler and the batch's completion both
    /// call it, whichever comes first ends the assertion.
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// MARK: - Outcome

enum TelemetryUploadOutcome: Equatable {
    case switchOff
    case notAttached
    case blockedByBuild
    case noConsent
    case signedOut
    case nothingPending
    case uploaded(rows: Int)
    /// A 2xx came back after an erase began: the rows landed, the cursor is
    /// deliberately NOT written — the pool it describes is gone.
    case staleAfterErase
    case failed(kind: SyncWriteFailureKind, code: String)
    /// The batch was refused as a whole, so every row was resent on its
    /// own: `uploaded` landed and were acknowledged, `quarantined` were
    /// refused again and are parked at their revision (review P1-2).
    case partial(uploaded: Int, quarantined: Int)

    /// The trail token for a batch that stopped at a gate (review P0-1: a
    /// silent "nothing sent" has no symptom; the trail line is the symptom).
    /// nil for the outcomes that already write their own line.
    var gateLabel: String? {
        switch self {
        case .switchOff: return "switch_off"
        case .notAttached: return "not_attached"
        case .blockedByBuild: return "blocked_by_build"
        case .noConsent: return "no_consent"
        case .signedOut: return "signed_out"
        case .nothingPending: return "nothing_pending"
        case .uploaded, .staleAfterErase, .failed, .partial: return nil
        }
    }
}

// MARK: - Uploader

@MainActor
final class TelemetryUploader: ObservableObject {
    /// What the uploader needs from the signed-in world, attached once the
    /// app has an `AuthService` and a `SupabaseSyncService`
    /// (`ContentView.onAppear`); tests hand in a fake gateway and closures.
    struct Attachment {
        let gateway: SyncGateway
        /// `SupabaseSyncService.uploadsBlockedByBuild` — the one Debug →
        /// production gate (design §7.4).
        let isBlockedByBuild: () -> Bool
        let currentUserID: () -> String?
        let isSignedIn: () -> Bool
    }

    struct Dependencies {
        var defaults: UserDefaults = .standard
        var location: SpikeRunStorageLocation = .production
        var now: () -> Date = Date.init
        /// `didBecomeActive` → launch batch (design §7.1 edge 1).
        var launchDelay: TimeInterval = 2
        /// Begins the keep-alive edge work runs under (review P2-1); nil
        /// means "none available" and the work runs bare.
        var makeKeepAlive: @MainActor () -> (any TelemetryKeepAlive)? = { TelemetryBackgroundAssertion() }
        /// Whether the app is in the foreground: a batch started while it is
        /// not (a queued launch batch drained after the edge) is wrapped too.
        var isApplicationActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
        /// The owner before `attach` has happened: the persisted session's
        /// user, so the center can mint today's record under the right claim
        /// at launch even though `AuthService` lives further down the view
        /// tree (nil under test and when nothing is persisted).
        var bootstrapOwner: () -> String? = { nil }
    }

    let dependencies: Dependencies
    private(set) var attachment: Attachment?
    /// Told on the switch's OFF → ON edge, after consent is recorded (review
    /// P2-3): the app wires it to `ResidentObservationCenter.
    /// remintDailyForConsent()`, so the day's counts from this moment on
    /// get a record whose `startedAt` is at or after the watermark instead
    /// of staying behind the pre-consent id for the rest of the day.
    var onConsentGranted: (() -> Void)?
    private weak var authService: AuthService?
    private weak var syncService: SupabaseSyncService?

    // Status for the settings card (design §8.3 可见反馈).
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastBatchCount = 0
    /// Rows acknowledged over this install's lifetime (`UploadCursor.
    /// totalAcknowledged`): persisted, monotonic, reads as "累计".
    @Published private(set) var totalAcknowledged = 0
    /// A pretty-printed copy of the rows the most recent ATTEMPT sent — the
    /// same redacted content, not the wire bytes (those are compact and
    /// unordered; review P2-5). Set before the request, so a failed attempt
    /// is shown too; the on-disk sample is written only after a 2xx. The
    /// one honest answer to "are you uploading my events".
    @Published private(set) var lastRequestBodyPreview: String?
    @Published private(set) var lastOutcome: TelemetryUploadOutcome?
    /// Rows the server refused and the cursor parked (`UploadCursor.quarantined`).
    @Published private(set) var quarantinedCount = 0

    private var inFlight: Task<Void, Never>?
    private var queued: TelemetryTrigger?
    /// Held from the first edge-flavoured schedule until BOTH the in-flight
    /// batch and whatever was queued behind it have finished (review P2-1):
    /// edge work never runs bare, whichever trigger's batch it rides in.
    private var keepAlive: (any TelemetryKeepAlive)?
    /// When a daily rollup last went out, for the background edge's
    /// 15-minute throttle. In memory only: a relaunch's own launch batch
    /// sends the daily anyway.
    private var lastDailyUploadAt: Date?
    private var lifecycleObserver: NSObjectProtocol?
    private var launchBatchArmed = false
    private var bootstrapOwnerCache: String??

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        let cursor = SpikeRunStore.loadUploadCursor(location: dependencies.location)
        totalAcknowledged = cursor.totalAcknowledged
        quarantinedCount = cursor.quarantined.count
        if let sample = SpikeRunStore.loadLastUploadSample(location: dependencies.location) {
            lastRequestBodyPreview = String(data: sample, encoding: .utf8)
        }
    }

    deinit {
        if let lifecycleObserver {
            NotificationCenter.default.removeObserver(lifecycleObserver)
        }
    }

    // MARK: Live wiring

    /// The app's uploader: standard defaults, the production pool, the
    /// persisted session as the pre-attach owner.
    static func live() -> TelemetryUploader {
        var deps = Dependencies()
        deps.bootstrapOwner = { Self.persistedSessionOwner() }
        return TelemetryUploader(dependencies: deps)
    }

    /// The user of the session `AuthService` persisted (gh#249: the
    /// Keychain). Read-only; `AuthService` remains the single write point.
    static func persistedSessionOwner() -> String? {
        guard let data = try? KeychainSessionStore().load(),
              let session = try? JSONDecoder().decode(AuthSession.self, from: data) else { return nil }
        return session.user.id
    }

    /// The account records are minted under (`SpikeRun.ownerUID`): the live
    /// session once attached, the persisted one before.
    var ownerUID: String? {
        if let attachment { return attachment.currentUserID() }
        if let cached = bootstrapOwnerCache { return cached }
        let owner = dependencies.bootstrapOwner()
        bootstrapOwnerCache = .some(owner)
        return owner
    }

    /// Idempotent: attaching the same session and engine again is a no-op
    /// (both `ContentView.onAppear` and its `onChange` fallback call this).
    func attach(authService: AuthService, syncService: SupabaseSyncService) {
        if attachment != nil, self.authService === authService, self.syncService === syncService { return }
        self.authService = authService
        self.syncService = syncService
        attach(Attachment(
            gateway: SupabaseREST(url: SupabaseSyncConfig.url, projectAPIKey: SupabaseSyncConfig.publishableKey,
                                  authService: authService),
            isBlockedByBuild: { [weak syncService] in syncService?.uploadsBlockedByBuild ?? true },
            currentUserID: { [weak authService] in authService?.userId },
            isSignedIn: { [weak authService] in authService?.isSignedIn ?? false }
        ))
    }

    func attach(_ attachment: Attachment) {
        self.attachment = attachment
    }

    /// Subscribes the launch edge: the first `didBecomeActive` (or right
    /// away if the app is already active) schedules the catch-up batch
    /// `launchDelay` later at `.utility` priority — never before the first
    /// frame (design §7.1 edge 1, B·F11). Also installs this uploader as
    /// the store's owner provider, so EVERY record appended from here on —
    /// manual runs included, which no center stamps — carries the account
    /// that was signed in when it was written (gh#273 round-2 ruling 1).
    func activate() {
        SpikeRunStore.ownerProvider = { [weak self] in self?.ownerUID }
        guard lifecycleObserver == nil else { return }
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.armLaunchBatch() }
        }
        if UIApplication.shared.applicationState == .active {
            armLaunchBatch()
        }
    }

    private func armLaunchBatch() {
        guard !launchBatchArmed else { return }
        launchBatchArmed = true
        let delay = dependencies.launchDelay
        Task(priority: .utility) { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            self?.schedule(.launch)
        }
    }

    // MARK: Switch edges

    /// The settings toggle's edges. Consent itself is written by the view
    /// (`DataPrivacySettingsView`'s `onChange`, the ONE place — review
    /// P2-4) before this is called. OFF → ON then re-mints the day's record
    /// (`onConsentGranted`) and tries once at once (B·F29); ON → OFF drops
    /// anything queued — an in-flight request finishes (its rows were
    /// consented), nothing follows it.
    func switchDidChange(from wasOn: Bool, to isOn: Bool) {
        if !wasOn, isOn {
            onConsentGranted?()
            schedule(.deckOpen)
        } else if wasOn, !isOn {
            queued = nil
        }
    }

    // MARK: Scheduling (single writer)

    /// Fire-and-forget. One batch at a time; a trigger arriving while one
    /// is in flight is merged into a single follow-up (the fuller trigger
    /// wins, so a background edge cannot downgrade a queued launch batch).
    func schedule(_ trigger: TelemetryTrigger) {
        // The edge begins its keep-alive at once — merged into a running
        // launch batch or not, the process must survive until that batch
        // and the follow-up finish.
        if trigger == .backgroundEdge {
            ensureKeepAlive()
        }
        guard inFlight == nil else {
            queued = Self.merge(queued, trigger)
            return
        }
        start(trigger)
    }

    private func ensureKeepAlive() {
        guard keepAlive == nil else { return }
        keepAlive = dependencies.makeKeepAlive()
    }

    private func endKeepAliveIfDrained() {
        guard inFlight == nil, queued == nil else { return }
        keepAlive?.end()
        keepAlive = nil
    }

    /// For the "立即上传" button and the tests: schedules, waits for the
    /// queue to drain, and reports the LAST batch's outcome.
    @discardableResult
    func uploadNow(trigger: TelemetryTrigger = .deckOpen) async -> TelemetryUploadOutcome {
        schedule(trigger)
        await drain()
        return lastOutcome ?? .nothingPending
    }

    /// Waits until no batch is in flight or queued.
    func drain() async {
        while let task = inFlight {
            await task.value
        }
    }

    private static func merge(_ queued: TelemetryTrigger?, _ incoming: TelemetryTrigger) -> TelemetryTrigger {
        guard let queued else { return incoming }
        // Only the background edge is a SUBSET of the others.
        if queued == .backgroundEdge { return incoming }
        return queued
    }

    private func start(_ trigger: TelemetryTrigger) {
        // An edge batch, or any batch started while the app is not in the
        // foreground (a queued launch batch drained after the edge), runs
        // under the keep-alive.
        if trigger == .backgroundEdge || !dependencies.isApplicationActive() {
            ensureKeepAlive()
        }
        inFlight = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let outcome = await self.runBatch(trigger: trigger)
            // One line per CHANGE of gate outcome, not per batch: a device
            // stuck at a gate shows the gate once, not a line per edge.
            if let gate = outcome.gateLabel, outcome != self.lastOutcome {
                DiagnosticTrail.record("Telemetry", "gate.\(gate) trigger=\(trigger)")
            }
            self.lastOutcome = outcome
            self.inFlight = nil
            if let next = self.queued {
                self.queued = nil
                self.start(next)
            }
            self.endKeepAliveIfDrained()
        }
    }

    // MARK: One batch

    private func runBatch(trigger: TelemetryTrigger) async -> TelemetryUploadOutcome {
        let defaults = dependencies.defaults
        guard defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled) else { return .switchOff }
        guard let attachment else { return .notAttached }
        guard !attachment.isBlockedByBuild() else { return .blockedByBuild }
        guard let consentAt = TelemetryConsentStore.consentAt(defaults) else { return .noConsent }
        guard attachment.isSignedIn(), let userID = attachment.currentUserID() else { return .signedOut }

        // Before the FIRST await (design §7.5): a cursor written after an
        // erase would describe records that no longer exist.
        let eraseToken = LocalDataEraseEpoch.capture()
        let now = dependencies.now()
        let location = dependencies.location
        let installID = SpikeRunStore.installID(location: location)
        var cursor = SpikeRunStore.loadUploadCursor(location: location)

        var records: [SpikeRun] = []
        for spikeID in SpikeRunStore.spikeIDsOnDisk(location: location) {
            records.append(contentsOf: SpikeRunStore.loadRuns(spikeID: spikeID, location: location))
        }
        let consented = TelemetryConsent.filter(records, consentAt: consentAt, currentOwner: userID)
        let pending = cursor.pending(consented, id: \.id, revision: \.revision)
        let batch = TelemetryTrigger.selectBatch(pending, trigger: trigger, lastDailyUploadAt: lastDailyUploadAt, now: now)
        guard !batch.isEmpty else { return .nothingPending }

        let noteOptIn = defaults.bool(forKey: AppSettingsKeys.telemetryNoteUploadsEnabled)
        // A record minted before `dayKey` existed is dated in the process's
        // own calendar at upload time — the best available answer, and the
        // only place outside the center that does calendar math.
        let calendar = Calendar.current
        let rows = batch.map { run in
            TelemetryRedactor.redact(
                row: TelemetryWire.row(for: run, userID: userID, installID: installID, now: now) { startedAt in
                    TelemetryClaimKey.dayKey(forDayStart: calendar.startOfDay(for: startedAt), calendar: calendar)
                },
                noteOptIn: noteOptIn,
                allowedStringKeys: TelemetryRedactor.observatoryFixedFormatStringKeys
            )
        }
        let previewData = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        lastRequestBodyPreview = String(data: previewData, encoding: .utf8)

        do {
            try await attachment.gateway.upsertRows(table: TelemetryWire.table, rows: rows, onConflict: TelemetryWire.onConflict)
        } catch {
            let failure = SyncWriteFailure.classify(error)
            DiagnosticTrail.record("Telemetry",
                                   "upload.failed trigger=\(trigger) rows=\(rows.count) kind=\(failure.kind) code=\(failure.code) mayHaveLanded=\(failure.mayHaveLanded)")
            guard Self.isolatesRows(failure.kind) else { return .failed(kind: failure.kind, code: failure.code) }
            return await isolateRows(batch: batch, rows: rows, gateway: attachment.gateway, cursor: cursor,
                                     knownIDs: Set(records.map(\.id)), eraseToken: eraseToken, now: now,
                                     location: location, previewData: previewData)
        }

        guard !LocalDataEraseEpoch.isStale(eraseToken) else {
            DiagnosticTrail.record("Telemetry", "upload.stale_after_erase rows=\(rows.count)")
            return .staleAfterErase
        }
        commit(landed: batch.map { ($0.id, $0.revision ?? 0) }, landedRuns: batch, quarantined: [], cursor: cursor,
               knownIDs: Set(records.map(\.id)), now: now, location: location, previewData: previewData)
        DiagnosticTrail.record("Telemetry", "upload.ok trigger=\(trigger) rows=\(rows.count) total=\(totalAcknowledged)")
        return .uploaded(rows: rows.count)
    }

    /// The failure classes that mean "a ROW is wrong", not "the wire is
    /// down": the server refused the body (23xxx / 42501), its schema has no
    /// column the body names, or the body is too big. Each row is then sent
    /// on its own, once (review P1-2). Transport, 5xx and 401 stay whole-batch
    /// failures: the next trigger retries them unchanged.
    static func isolatesRows(_ kind: SyncWriteFailureKind) -> Bool {
        switch kind {
        case .rejected, .schemaCache, .tooLarge: return true
        case .unauthorized, .retryable, .accountMissing, .epochStale, .paused: return false
        }
    }

    /// One request per row of a refused batch: rows that land are
    /// acknowledged, rows refused AGAIN are quarantined at their revision
    /// (`UploadCursor.quarantined`) with a trail line naming the run, and a
    /// transport-class failure stops the walk — the rest wait for the next
    /// trigger like any retryable batch.
    private func isolateRows(
        batch: [SpikeRun], rows: [[String: Any]], gateway: SyncGateway, cursor: UploadCursor, knownIDs: Set<UUID>,
        eraseToken: Int, now: Date, location: SpikeRunStorageLocation, previewData: Data
    ) async -> TelemetryUploadOutcome {
        var landed: [(UUID, Int)] = []
        var landedRuns: [SpikeRun] = []
        var quarantined: [(UUID, Int)] = []
        var stoppedBy: SyncWriteFailure?
        for (run, row) in zip(batch, rows) {
            let revision = run.revision ?? 0
            do {
                try await gateway.upsertRows(table: TelemetryWire.table, rows: [row], onConflict: TelemetryWire.onConflict)
                landed.append((run.id, revision))
                landedRuns.append(run)
            } catch {
                let failure = SyncWriteFailure.classify(error)
                guard Self.isolatesRows(failure.kind) else {
                    stoppedBy = failure
                    break
                }
                quarantined.append((run.id, revision))
                DiagnosticTrail.record("Telemetry",
                                       "upload.quarantined run=\(run.id.uuidString.lowercased()) revision=\(revision) kind=\(failure.kind) code=\(failure.code)")
            }
        }
        guard !LocalDataEraseEpoch.isStale(eraseToken) else {
            DiagnosticTrail.record("Telemetry", "upload.stale_after_erase rows=\(rows.count)")
            return .staleAfterErase
        }
        if landed.isEmpty, quarantined.isEmpty, let stoppedBy {
            return .failed(kind: stoppedBy.kind, code: stoppedBy.code)
        }
        commit(landed: landed, landedRuns: landedRuns, quarantined: quarantined, cursor: cursor,
               knownIDs: knownIDs, now: now, location: location, previewData: previewData)
        DiagnosticTrail.record("Telemetry", "upload.partial landed=\(landed.count) quarantined=\(quarantined.count) total=\(totalAcknowledged)")
        return .partial(uploaded: landed.count, quarantined: quarantined.count)
    }

    /// The one place the cursor file and the status fields move: after a
    /// 2xx (whole batch or per row) and only when no erase began meanwhile
    /// (callers check `LocalDataEraseEpoch` first).
    private func commit(
        landed: [(UUID, Int)], landedRuns: [SpikeRun], quarantined: [(UUID, Int)], cursor: UploadCursor, knownIDs: Set<UUID>,
        now: Date, location: SpikeRunStorageLocation, previewData: Data
    ) {
        var cursor = cursor
        cursor.acknowledge(ids: landed)
        for (id, revision) in quarantined {
            cursor.quarantine(id: id, revision: revision)
        }
        // Entries for records compaction has evicted since are dead weight
        // (review P2-6); the id set is the one THIS batch's read saw.
        cursor.prune(keeping: knownIDs)
        SpikeRunStore.saveUploadCursor(cursor, location: location)
        SpikeRunStore.saveLastUploadSample(previewData, location: location)
        // The gate's subject is the daily ROLLUP (`dailyGateOpen`); a
        // MetricKit daily going out does not reset its clock.
        if landedRuns.contains(where: { $0.resolvedKind == .dailyRollup }) {
            lastDailyUploadAt = now
        }
        if !landed.isEmpty {
            lastUploadAt = now
            lastBatchCount = landed.count
        }
        totalAcknowledged = cursor.totalAcknowledged
        quarantinedCount = cursor.quarantined.count
    }
}

// MARK: - SwiftUI environment

/// The uploader for the settings card; nil under XCTest and before the app
/// has created one, in which case the card shows the switches only.
private struct TelemetryUploaderKey: EnvironmentKey {
    static let defaultValue: TelemetryUploader? = nil
}

extension EnvironmentValues {
    var telemetryUploader: TelemetryUploader? {
        get { self[TelemetryUploaderKey.self] }
        set { self[TelemetryUploaderKey.self] = newValue }
    }
}
