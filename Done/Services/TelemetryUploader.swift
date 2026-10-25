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

/// Keeps the process alive through a background-edge upload (≈30 s window,
/// design §7.1 edge 4). Same shape as the widget stats build's assertion in
/// EventStore.swift — the app's one other `beginBackgroundTask`: it extends
/// a running process and relaunches nothing (it is not a background mode).
@MainActor
final class TelemetryBackgroundAssertion {
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
        var makeBackgroundAssertion: @MainActor () -> TelemetryBackgroundAssertion? = { TelemetryBackgroundAssertion() }
        /// The owner before `attach` has happened: the persisted session's
        /// user, so the center can mint today's record under the right claim
        /// at launch even though `AuthService` lives further down the view
        /// tree (nil under test and when nothing is persisted).
        var bootstrapOwner: () -> String? = { nil }
    }

    let dependencies: Dependencies
    private(set) var attachment: Attachment?
    private weak var authService: AuthService?

    // Status for the settings card (design §8.3 可见反馈).
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastBatchCount = 0
    /// Distinct records the server has acknowledged — the cursor's size, so
    /// it survives relaunch and reads as "累计".
    @Published private(set) var totalUploaded = 0
    /// Pretty JSON of the most recent request body, exactly as sent (after
    /// redaction) — the one honest answer to "are you uploading my events".
    @Published private(set) var lastRequestBodyPreview: String?
    @Published private(set) var lastOutcome: TelemetryUploadOutcome?

    private var inFlight: Task<Void, Never>?
    private var queued: TelemetryTrigger?
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
        totalUploaded = cursor.uploaded.count
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

    func attach(authService: AuthService, syncService: SupabaseSyncService) {
        self.authService = authService
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
    /// frame (design §7.1 edge 1, B·F11).
    func activate() {
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

    /// The settings toggle's edges. OFF → ON records consent and tries once
    /// at once (B·F29); ON → OFF drops anything queued — an in-flight
    /// request finishes (its rows were consented), nothing follows it.
    func switchDidChange(from wasOn: Bool, to isOn: Bool) {
        if !wasOn, isOn {
            TelemetryConsentStore.recordGrant(dependencies.defaults, at: dependencies.now())
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
        guard inFlight == nil else {
            queued = Self.merge(queued, trigger)
            return
        }
        start(trigger)
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
        let assertion = trigger == .backgroundEdge ? dependencies.makeBackgroundAssertion() : nil
        inFlight = Task(priority: .utility) { [weak self] in
            guard let self else {
                assertion?.end()
                return
            }
            let outcome = await self.runBatch(trigger: trigger)
            self.lastOutcome = outcome
            assertion?.end()
            self.inFlight = nil
            if let next = self.queued {
                self.queued = nil
                self.start(next)
            }
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
            return .failed(kind: failure.kind, code: failure.code)
        }

        guard !LocalDataEraseEpoch.isStale(eraseToken) else {
            DiagnosticTrail.record("Telemetry", "upload.stale_after_erase rows=\(rows.count)")
            return .staleAfterErase
        }
        cursor.acknowledge(ids: batch.map { ($0.id, $0.revision ?? 0) })
        SpikeRunStore.saveUploadCursor(cursor, location: location)
        SpikeRunStore.saveLastUploadSample(previewData, location: location)
        if batch.contains(where: { !$0.resolvedKind.isEventRecord }) {
            lastDailyUploadAt = now
        }
        lastUploadAt = now
        lastBatchCount = rows.count
        totalUploaded = cursor.uploaded.count
        DiagnosticTrail.record("Telemetry", "upload.ok trigger=\(trigger) rows=\(rows.count) total=\(cursor.uploaded.count)")
        return .uploaded(rows: rows.count)
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
