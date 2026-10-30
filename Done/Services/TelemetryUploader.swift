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
//  switch — and, for a switch the TestFlight default turned on, this
//  launch's "TestFlight" answer (review P1-1); `SupabaseSyncService.uploadsBlockedByBuild` — the SAME property
//  the sync engine asks, through a closure, never a second `#if DEBUG`
//  (B·F38; a source-scan test keeps this file free of one); the consent
//  watermark; a signed-in account with a token. Then the pool → collapse →
//  consent filter → cursor → trigger's selection → serialize → Redactor →
//  one request. The cursor moves only on 2xx, and only when no erase began
//  while the request was in flight (`LocalDataEraseEpoch`, design §7.5).
//

import Combine
import Foundation
import StoreKit
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

    /// §16: the user has ruled on the switch. True once they flipped it
    /// (`telemetryUserDecided`), and also for any stored switch the default
    /// did not write — build 17's ON as much as its OFF (review P1-1): the
    /// key is not registered and the erase removes it, so a stored value
    /// without the by-default bit can only be the user's.
    static func userHasDecided(_ defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: AppSettingsKeys.telemetryUserDecided) { return true }
        return defaults.object(forKey: AppSettingsKeys.telemetryUploadsEnabled) != nil && !isEnabledByDefault(defaults)
    }

    /// The user's own flip: from now on nothing but the user moves the
    /// switch, and it is no longer the default's.
    static func recordDecision(_ defaults: UserDefaults) {
        defaults.set(true, forKey: AppSettingsKeys.telemetryUserDecided)
        defaults.removeObject(forKey: AppSettingsKeys.telemetryEnabledByDefault)
    }

    static func isEnabledByDefault(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: AppSettingsKeys.telemetryEnabledByDefault)
    }

    /// A definite App Store answer on a switch the default turned on: back to
    /// "never ruled" — the switch and the bit REMOVED, not written false (a
    /// stored false would read as the user's own OFF) — and the note
    /// sub-consent withdrawn with it (Q5). The consent moment is kept, as on
    /// any ON → OFF.
    static func withdrawDefault(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: AppSettingsKeys.telemetryUploadsEnabled)
        defaults.removeObject(forKey: AppSettingsKeys.telemetryEnabledByDefault)
        defaults.set(false, forKey: AppSettingsKeys.telemetryNoteUploadsEnabled)
    }
}

// MARK: - The settings switch's edge

/// What the statistics switch does when the USER flips it (Fix Watch's
/// toggle binding, §16 rule 1) — one function, so the integration test
/// drives the REAL sequence rather than a hand-copied one (device bug,
/// build 17: every earlier end-to-end run pre-wrote consent into the plist
/// and never exercised this path). Records that the user has ruled (§16:
/// no default turns it on again), then OFF → ON writes consent at `now`
/// (the one write point, review P2-4) and only then tells the uploader,
/// which re-mints the day's record; ON → OFF withdraws the note
/// sub-consent with it (Q5). A programmatic write of the switch (the
/// TestFlight default) does not come through here — that is why the view
/// binds the toggle to this instead of observing the stored value.
@MainActor
enum TelemetrySwitchEdge {
    static func apply(from wasOn: Bool, to isOn: Bool, defaults: UserDefaults, now: Date, uploader: TelemetryUploader?) {
        TelemetryConsentStore.recordDecision(defaults)
        if !wasOn, isOn {
            TelemetryConsentStore.recordGrant(defaults, at: now)
        } else if wasOn, !isOn {
            defaults.set(false, forKey: AppSettingsKeys.telemetryNoteUploadsEnabled)
        }
        uploader?.switchDidChange(from: wasOn, to: isOn)
    }
}

// MARK: - Distribution (design §16 rule 2, review P1-2)

/// Where this install came from, decided by the first of these that
/// speaks, and said on the trail (`environment.source=`):
/// 1. `embedded.mobileprovision` — Xcode, devicectl, ad hoc — is
///    `.development` (a development install talks to the sandbox too).
/// 2. The simulator is `.development`. Measured: its receipt is named
///    `receipt`, so without this rule a simulator run would read as the
///    App Store.
/// 3. The App Store receipt's NAME, read synchronously: `sandboxReceipt` is
///    TestFlight, `receipt` the App Store. Build 20 on a real TestFlight
///    install: `AppTransaction.shared` threw (StoreKitError), the install
///    read as unknown, and the backfill never ran. App Review runs a
///    submitted build in the sandbox too, so its machine reads as
///    TestFlight here — the known risk recorded in design §14.
/// 4. Only then StoreKit 2's VERIFIED app transaction: `.sandbox`
///    TestFlight, `.production` App Store, `.xcode` development; an
///    unverified one or an error is `.unknown` — with StoreKit's own reason
///    — which never turns the default on.
/// Cached for the process once asked.
@MainActor
enum TelemetryDistributionDetector {
    /// StoreKit's answer, reduced to what the rule reads (a test cannot
    /// build a `VerificationResult<AppTransaction>`).
    enum StoreKitAnswer: Equatable {
        case verified(environment: String)
        case unverified
        case failed(reason: String)
    }

    /// Which evidence decided.
    enum Source: String {
        case provisioning, simulator, receipt, storekit
    }

    struct Answer: Equatable {
        let distribution: TelemetryDistribution
        let source: Source
    }

    private static var cached: TelemetryDistribution?

    static func live() async -> TelemetryDistribution {
        if let cached { return cached }
        let answer = await resolve(
            hasProvisioningProfile: Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil,
            isSimulator: isSimulator,
            receiptName: receiptName(),
            storeKit: { await storeKitAnswer() }
        )
        cached = answer
        return answer
    }

    /// `classify`, then one `Telemetry environment.source=` line on the trail
    /// — once per launch, since `live()` caches — so a device shows which
    /// evidence decided.
    static func resolve(hasProvisioningProfile: Bool, isSimulator: Bool, receiptName: String?,
                        storeKit: @MainActor () async -> StoreKitAnswer) async -> TelemetryDistribution {
        let answer = await classify(hasProvisioningProfile: hasProvisioningProfile, isSimulator: isSimulator,
                                    receiptName: receiptName, storeKit: storeKit)
        DiagnosticTrail.record("Telemetry", "environment.source=\(answer.source.rawValue)")
        return answer.distribution
    }

    static func classify(hasProvisioningProfile: Bool, isSimulator: Bool, receiptName: String?,
                         storeKit: @MainActor () async -> StoreKitAnswer) async -> Answer {
        if hasProvisioningProfile { return Answer(distribution: .development, source: .provisioning) }
        if isSimulator { return Answer(distribution: .development, source: .simulator) }
        switch receiptName {
        case "sandboxReceipt": return Answer(distribution: .testFlight, source: .receipt)
        case "receipt": return Answer(distribution: .appStore, source: .receipt)
        default: break
        }
        let distribution: TelemetryDistribution
        switch await storeKit() {
        case .verified(let environment):
            switch environment {
            case AppStore.Environment.sandbox.rawValue: distribution = .testFlight
            case AppStore.Environment.production.rawValue: distribution = .appStore
            case AppStore.Environment.xcode.rawValue: distribution = .development
            default: distribution = .unknown(reason: "environment_\(environment)")
            }
        case .unverified:
            distribution = .unknown(reason: "unverified")
        case .failed(let reason):
            distribution = .unknown(reason: reason)
        }
        return Answer(distribution: distribution, source: .storekit)
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The receipt file's name — `Bundle.appStoreReceiptURL`, deprecated
    /// (iOS 18) but still answering, read through a local protocol so this
    /// one call site does not warn.
    static func receiptName(_ bundle: any AppStoreReceiptLocating = Bundle.main) -> String? {
        bundle.appStoreReceiptURL?.lastPathComponent
    }

    /// `appTransaction` is StoreKit's call; a test hands in a throwing one.
    static func storeKitAnswer(
        _ appTransaction: @MainActor () async throws -> VerificationResult<AppTransaction> = { try await AppTransaction.shared }
    ) async -> StoreKitAnswer {
        do {
            switch try await appTransaction() {
            case .verified(let transaction): return .verified(environment: transaction.environment.rawValue)
            case .unverified: return .unverified
            }
        } catch {
            return .failed(reason: failureReason(error))
        }
    }

    /// StoreKit's own case — and, for the two that wrap another error, that
    /// error's `domain#code` — for `environment=unknown(<this>)`. Build 20's
    /// trail said only "StoreKit.StoreKitError#1".
    nonisolated static func failureReason(_ error: any Error) -> String {
        guard let storeKit = error as? StoreKitError else { return domainAndCode(error) }
        switch storeKit {
        case .networkError(let underlying): return "StoreKitError.networkError:\(domainAndCode(underlying))"
        case .systemError(let underlying): return "StoreKitError.systemError:\(domainAndCode(underlying))"
        case .unknown: return "StoreKitError.unknown"
        case .userCancelled: return "StoreKitError.userCancelled"
        case .notAvailableInStorefront: return "StoreKitError.notAvailableInStorefront"
        case .notEntitled: return "StoreKitError.notEntitled"
        case .unsupported: return "StoreKitError.unsupported"
        @unknown default: return "StoreKitError.\(domainAndCode(storeKit))"
        }
    }

    nonisolated private static func domainAndCode(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}

/// Where `Bundle.appStoreReceiptURL` is read from: `Bundle` in the app,
/// a stub in a test. The requirement itself is not deprecated, so the one
/// read of the deprecated property does not warn.
protocol AppStoreReceiptLocating {
    var appStoreReceiptURL: URL? { get }
}

extension Bundle: AppStoreReceiptLocating {}

// MARK: - Observatory cloud read (design §16 rule 3)

/// One page of this account's observatory rows (server view
/// `v_my_spike_runs`, RLS: own rows only, release rows only), on or after
/// `sinceDayKey` (review P1-3: the deck's window, not the account's
/// lifetime). `SupabaseREST` is the production conformance.
@MainActor
protocol TelemetryCloudReading: AnyObject {
    func fetchMySpikeRunsPage(spikeIDs: [String], sinceDayKey: String, limit: Int, offset: Int) async throws -> [[String: Any]]
}

extension SupabaseREST: TelemetryCloudReading {}

enum TelemetryCloudPager {
    /// Below any plausible PostgREST `max_rows` (1000 locally and by
    /// default), so a page that comes back short really is the last one —
    /// never a server cap read as the end.
    static let pageSize = 500
    static let maxPages = 40

    /// Every row, walked with `limit`/`offset` over the view's STABLE order
    /// (`day_key.desc, run_id.asc` — total, `run_id` being unique per user).
    /// Rows are only ever inserted or updated in place (no client delete),
    /// so a row added mid-walk can only push later rows DOWN: the next page
    /// repeats one, it never skips one. Repeats collapse by run id, keeping
    /// the higher `revision`.
    static func fetchAll(from source: TelemetryCloudReading, spikeIDs: [String], sinceDayKey: String,
                         pageSize: Int = pageSize) async throws -> [[String: Any]] {
        var byID: [String: [String: Any]] = [:]
        var order: [String] = []
        for page in 0..<maxPages {
            let rows = try await source.fetchMySpikeRunsPage(spikeIDs: spikeIDs, sinceDayKey: sinceDayKey,
                                                             limit: pageSize, offset: page * pageSize)
            for row in rows {
                guard let id = (row["run_id"] as? String)?.lowercased() else { continue }
                if let held = byID[id] {
                    let heldRevision = (held["revision"] as? NSNumber)?.intValue ?? 0
                    let incoming = (row["revision"] as? NSNumber)?.intValue ?? 0
                    if incoming > heldRevision { byID[id] = row }
                } else {
                    byID[id] = row
                    order.append(id)
                }
            }
            if rows.count < pageSize { break }
        }
        return order.compactMap { byID[$0] }
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
    /// The switch is ON by the TestFlight default and this launch has not
    /// heard "TestFlight" (yet, or at all): nothing is sent (review P1-1).
    case defaultNotConfirmed
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
        case .defaultNotConfirmed: return "default_not_confirmed"
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
        /// The observatory's read of this account's cloud rows (§16 rule 3);
        /// nil where there is none (tests that only upload).
        var cloudReader: TelemetryCloudReading? = nil
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
        /// §16 rule 2: where this install came from (review P1-2). The
        /// provisioning check and StoreKit in the app; tests hand in an answer.
        var distribution: @MainActor () async -> TelemetryDistribution = { await TelemetryDistributionDetector.live() }
    }

    let dependencies: Dependencies
    private(set) var attachment: Attachment?
    /// Told on the switch's OFF → ON edge, after consent is recorded (review
    /// P2-3): the app wires it to `ResidentObservationCenter.
    /// remintDailyForConsent()`, so the day's counts from this moment on
    /// get a record whose `startedAt` is at or after the watermark instead
    /// of staying behind the pre-consent id for the rest of the day.
    var onConsentGranted: (() -> Void)?
    /// Called by `uploadNow` before it schedules (device fix, build 17): the
    /// app wires it to `ResidentObservationCenter.flushForManualUpload()`, so
    /// counts made since the last flush edge are on disk when the manual
    /// batch reads it. nil (no resident, most tests) reads what is on disk.
    var flushBeforeManualUpload: (@MainActor () -> Void)?
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
    /// Rows the running trigger has landed so far — what the status row
    /// counts ("the trigger, not its last batch").
    private var landedThisTrigger = 0
    /// Where this install came from (§16), learned once at activation
    /// (`refreshDistribution`). nil until then: a batch that runs first
    /// filters by the stored consent (the App Store rule) — and sends
    /// nothing at all if the switch is the default's — and what it leaves
    /// stays pending for the next batch: late, never lost.
    private(set) var distribution: TelemetryDistribution?
    var isTestFlightInstall: Bool? { distribution.map { $0 == .testFlight } }
    private var lifecycleObserver: NSObjectProtocol?
    private var launchBatchArmed = false
    private var bootstrapOwnerCache: String??

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        let cursor = SpikeRunStore.loadUploadCursor(location: dependencies.location)
        totalAcknowledged = cursor.totalAcknowledged
        quarantinedCount = cursor.quarantined.count
        if let status = SpikeRunStore.loadLastUploadStatus(location: dependencies.location) {
            lastUploadAt = status.at
            lastBatchCount = status.rows
        }
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
    /// persisted session as the pre-attach owner. `isTestFlight`, when
    /// given, replaces the distribution answer (`true` TestFlight, `false`
    /// App Store) and says so on the trail; DoneApp passes the DEBUG-only
    /// `TELEMETRY_FAKE_TESTFLIGHT` launch variable, and no other build has
    /// anything to pass (QA, §16).
    static func live(isTestFlight: Bool? = nil) -> TelemetryUploader {
        var deps = Dependencies()
        deps.bootstrapOwner = { Self.persistedSessionOwner() }
        if let isTestFlight {
            let faked: TelemetryDistribution = isTestFlight ? .testFlight : .appStore
            deps.distribution = {
                DiagnosticTrail.record("Telemetry", "environment.faked_by_launch_variable value=\(isTestFlight ? 1 : 0)")
                return faked
            }
        }
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
        let rest = SupabaseREST(url: SupabaseSyncConfig.url, projectAPIKey: SupabaseSyncConfig.publishableKey,
                                authService: authService)
        attach(Attachment(
            gateway: rest,
            isBlockedByBuild: { [weak syncService] in syncService?.uploadsBlockedByBuild ?? true },
            currentUserID: { [weak authService] in authService?.userId },
            isSignedIn: { [weak authService] in authService?.isSignedIn ?? false },
            cloudReader: rest
        ))
    }

    /// The app's wiring of the resident to this uploader, in ONE place so the
    /// tests run exactly what DoneApp runs (review P2-2 — a hand-copied
    /// wiring let the "Upload now" flush go unwired with every test green):
    /// the center's flush edges schedule batches, the consent edge re-mints
    /// the day's record, and "Upload now" writes the counts so far first.
    func connect(center: ResidentObservationCenter) {
        center.onUploadTrigger = { [weak self] trigger in self?.schedule(trigger) }
        onConsentGranted = { [weak center] in center?.remintDailyForConsent() }
        flushBeforeManualUpload = { [weak center] in center?.flushForManualUpload() }
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
        Task { [weak self] in await self?.applyTestFlightDefaultIfNeeded() }
    }

    /// Asks the detector once per uploader, remembers the answer — for
    /// every install, decided or not: in TestFlight the answer sets the
    /// watermark of ANY consent (decision 2026-10-27 ①) — and writes it to
    /// the trail, one `Telemetry environment=` line per launch (review P1-2:
    /// the answer must be visible on a device, whatever it is).
    @discardableResult
    func refreshDistribution() async -> TelemetryDistribution {
        if let known = distribution { return known }
        let answer = await dependencies.distribution()
        distribution = answer
        DiagnosticTrail.record("Telemetry", "environment=\(answer.traceLabel)")
        return answer
    }

    /// §16 rule 2, once StoreKit has answered:
    /// - App Store, switch ON by the default (a TestFlight install updated
    ///   to, or restored onto, the App Store build): withdrawn — switch and
    ///   bit removed, nothing sent (review P1-1).
    /// - TestFlight, user has not ruled: ON, with the by-default bit. The
    ///   consent moment written is NOW, and one already stored is kept; the
    ///   backfill comes from the watermark rule alone, never from the stored
    ///   value. Never touches the note sub-switch, never sets "decided", so
    ///   it re-asserts itself — idempotently — each launch until the user
    ///   flips the switch either way.
    /// - TestFlight with the switch ON, the default's or the user's own: a
    ///   batch is scheduled now, so history a batch before the answer left
    ///   behind goes up without waiting for another trigger (①).
    /// Returns whether it is on by default after the call.
    @discardableResult
    func applyTestFlightDefaultIfNeeded() async -> Bool {
        let defaults = dependencies.defaults
        let distribution = await refreshDistribution()
        // Read after the await: the user may have flipped the switch while
        // StoreKit answered.
        let wasOn = defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled)
        if TelemetryDefaultPolicy.withdrawsDefault(distribution: distribution,
                                                   enabledByDefault: TelemetryConsentStore.isEnabledByDefault(defaults)) {
            TelemetryConsentStore.withdrawDefault(defaults)
            queued = nil
            DiagnosticTrail.record("Telemetry", "default.withdrawn environment=\(distribution.traceLabel) was_on=\(wasOn)")
            return false
        }
        var onByDefault = false
        if TelemetryDefaultPolicy.autoEnables(distribution: distribution,
                                              userHasDecided: TelemetryConsentStore.userHasDecided(defaults)) {
            let keptConsent = TelemetryConsentStore.consentAt(defaults) != nil
            if !keptConsent {
                TelemetryConsentStore.recordGrant(defaults, at: dependencies.now())
            }
            defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
            defaults.set(true, forKey: AppSettingsKeys.telemetryEnabledByDefault)
            if !wasOn {
                DiagnosticTrail.record("Telemetry", "default.testflight_on consent=\(keptConsent ? "kept" : "now")")
            }
            onByDefault = true
        }
        if distribution == .testFlight, defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled) {
            schedule(.launch)
        }
        return onByDefault
    }

    // MARK: Observatory

    /// This account's observatory rows from the cloud (§16 rule 3),
    /// decoded; nil when there is no cloud to ask — not attached, signed
    /// out, no reader, or the read failed — so the deck falls back to this
    /// device and says so. Reading one's own rows needs no consent switch.
    func fetchObservatoryCloudRuns(sinceDayKey: String) async -> [SpikeRun]? {
        guard let attachment, let reader = attachment.cloudReader, attachment.isSignedIn() else { return nil }
        do {
            let rows = try await TelemetryCloudPager.fetchAll(
                from: reader,
                spikeIDs: [FixObservationRegistry.residentDailySpikeID, FixObservationRegistry.effortPathFixID],
                sinceDayKey: sinceDayKey
            )
            return rows.compactMap(TelemetryWire.run(fromRow:))
        } catch {
            let failure = SyncWriteFailure.classify(error)
            DiagnosticTrail.record("Telemetry", "observatory.cloud_unavailable kind=\(failure.kind) code=\(failure.code)")
            return nil
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

    // MARK: Erase

    /// "Erase all local data" (final review P1-2): the files went with
    /// `SpikeRunStore.wipe()`; this drops every in-memory trace of the
    /// previous owner's uploads — the status row, the sample, the last
    /// outcome, the daily throttle clock, a queued follow-up, and the
    /// pre-attach owner cache. The attachment stays: the session object is
    /// the same one, now signed out.
    func forgetAfterErase() {
        lastUploadAt = nil
        lastBatchCount = 0
        landedThisTrigger = 0
        totalAcknowledged = 0
        quarantinedCount = 0
        lastRequestBodyPreview = nil
        lastOutcome = nil
        lastDailyUploadAt = nil
        queued = nil
        bootstrapOwnerCache = nil
    }

    // MARK: Switch edges

    /// The settings toggle's edges. Consent itself is written by
    /// `TelemetrySwitchEdge.apply` (the ONE place — review P2-4) before
    /// this is called. OFF → ON then re-mints the day's record
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
        // The button is the device checklist's probe: what it sends must
        // include what was counted a moment ago, not only what the last
        // background edge happened to write.
        flushBeforeManualUpload?()
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
            let outcome = await self.runUntilDrained(trigger: trigger)
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

    // MARK: One trigger: batches until drained (design §16 rule 2)

    /// A ceiling on one trigger's batches (2048 rows): a backfill larger
    /// than that finishes on the next trigger.
    static let maxBatchesPerTrigger = 64

    /// One trigger sends batches until nothing is pending — a TestFlight
    /// device's backfill is hundreds of rows, a batch is ≤32. It stops at
    /// the first batch that moves nothing: a gate, an empty selection, a
    /// failure, an erase — so a failure waits for the next trigger like any
    /// other. The daily throttle is judged ONCE, at the trigger: an edge
    /// that may send dailies sends all of them, not only the first batch's.
    /// The loop runs inside the single in-flight task, so the keep-alive
    /// covers all of it.
    private func runUntilDrained(trigger: TelemetryTrigger) async -> TelemetryUploadOutcome {
        let dailyClockAtTrigger = lastDailyUploadAt
        landedThisTrigger = 0
        var sent = 0
        var parked = 0
        var last: TelemetryUploadOutcome = .nothingPending
        batches: for _ in 0..<Self.maxBatchesPerTrigger {
            last = await runBatch(trigger: trigger, lastDailyUploadAt: dailyClockAtTrigger)
            switch last {
            case .uploaded(let rows):
                sent += rows
            case .partial(let uploaded, let quarantined) where uploaded + quarantined > 0:
                sent += uploaded
                parked += quarantined
            default:
                break batches
            }
        }
        switch last {
        case .uploaded, .partial, .nothingPending:
            // Drained (or at the ceiling): report what the trigger moved.
            if parked > 0 { return .partial(uploaded: sent, quarantined: parked) }
            if sent > 0 { return .uploaded(rows: sent) }
            return last
        default:
            // Stopped by a failure, a gate or an erase: that is the news;
            // the status line already shows the rows that did land.
            return last
        }
    }

    // MARK: One batch

    private func runBatch(trigger: TelemetryTrigger, lastDailyUploadAt: Date?) async -> TelemetryUploadOutcome {
        let defaults = dependencies.defaults
        guard defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled) else { return .switchOff }
        guard TelemetryDefaultPolicy.mayUpload(enabledByDefault: TelemetryConsentStore.isEnabledByDefault(defaults),
                                               distribution: distribution) else { return .defaultNotConfirmed }
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
        // In TestFlight every consent backfills (①): the stored moment is the
        // App Store's watermark only.
        let watermark = TelemetryDefaultPolicy.watermark(consentAt: consentAt, isTestFlight: isTestFlightInstall == true)
        let consented = TelemetryConsent.filter(records, consentAt: watermark, currentOwner: userID)
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

        // A 2xx is the whole success signal: the contract is
        // `return=minimal`, so "2xx but 0 rows" (B·F36) is not observable
        // here by design — a row the server skipped is the revision guard's
        // doing, and the cursor advancing past it is correct (design §7.2).
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
    /// down": the server refused the body (23xxx / 42501) or the body is too
    /// big. Each row is then sent on its own, once (review P1-2). Everything
    /// else stays a whole-batch failure the next trigger retries unchanged —
    /// including `schemaCache` (PGRST204): it is the transient between a
    /// migration and PostgREST's `NOTIFY pgrst` reload, so parking rows at
    /// their revision for it would quarantine every window record written
    /// while the server was behind, and windows are never re-appended.
    static func isolatesRows(_ kind: SyncWriteFailureKind) -> Bool {
        switch kind {
        case .rejected, .tooLarge: return true
        case .schemaCache, .unauthorized, .retryable, .accountMissing, .epochStale, .paused: return false
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
            // Each row is its own request, after an await: an erase since the
            // batch was read leaves the rows not yet sent as the erased
            // owner's records, from files that are gone. None of them goes.
            if LocalDataEraseEpoch.isStale(eraseToken) { break }
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
            landedThisTrigger += landed.count
            lastUploadAt = now
            lastBatchCount = landedThisTrigger
            // Beside the cursor, under the same erase check: a relaunch shows
            // the last upload instead of "never" (QA).
            SpikeRunStore.saveLastUploadStatus(TelemetryUploadStatus(at: now, rows: landedThisTrigger), location: location)
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
