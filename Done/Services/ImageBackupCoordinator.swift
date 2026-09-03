import Foundation
import Combine
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "ImageBackup"
)

/// Observes the event stores and pushes any locally-attached image binaries
/// to Supabase Storage. Per the L2 architecture in #21, this is the
/// cross-platform / cross-Apple-ID image-backup path.
///
/// Design choices:
///
/// - **Pull-based, not push-based.** Rather than hooking every call site of
///   `AgenticIntakeAssetStore.saveImages(...)` (5+ places), this coordinator
///   observes `EventStore.$events` / `$rawCalendarEvents` and uploads anything
///   that hasn't been uploaded yet this session. Eventual consistency:
///   crash / app-quit between save and upload is recovered on next launch.
///
/// - **Two-tier dedup** (gh#219). Tier 1, durable: image IDs whose presence
///   in cloud Storage was CONFIRMED by a remote outcome (2xx, 409, or a
///   successful restore download) persist per user in `defaults`, so a cold
///   launch no longer re-reads and re-POSTs every backed-up image for a
///   guaranteed 409. Tier 2, in-memory: `attemptedImageIDs` suppresses
///   repeat work within one session for everything weaker than confirmation
///   (in-flight attempts, disabled-gate no-ops, missing/corrupt local
///   files); on failure the ID is removed so the next store-change scan
///   retries, and process exit resets the tier entirely — the deliberate
///   retry channel for anything unconfirmed.
///
/// - **No cloud-side deletion in v1.** When the user deletes an event, the
///   local image files are removed (`AgenticIntakeAssetStore.removeAssets`)
///   but the corresponding Supabase Storage objects remain orphaned. A
///   periodic garbage-collect follow-up will clean these up later — they
///   don't affect correctness and the user is paying for their own egress
///   anyway. Tracked separately.
///
/// - **DEBUG safety** is delegated to `SupabaseImageStorageService.upload`,
///   which throws `.uploadsDisabled` in DEBUG and we silently swallow.
@MainActor
final class ImageBackupCoordinator: ObservableObject {
    /// Live progress for the in-flight restore image fetch. Nil when no
    /// restore download is happening. `RestoreSheet` observes this so the
    /// "Applying restore…" view can surface a "Downloading N/M images"
    /// line instead of a blind spinner during long downloads.
    struct DownloadProgress: Equatable {
        var current: Int
        var total: Int
    }
    @Published private(set) var restoreDownloadProgress: DownloadProgress?

    /// Long enough to coalesce a burst of edits, short enough that a freshly
    /// attached photo lands in the cloud within seconds.
    private static let scanDebounce: TimeInterval = 5

    // Injection seam (gh#219). Defaults preserve production wiring: the
    // coordinator reads/writes the standard defaults and the real on-disk
    // asset store, and `attach()` builds a real `SupabaseImageStorageService`
    // over the `AuthService` it is handed. Tests inject an isolated suite,
    // an isolated asset directory, and a scripted storage mock — and then
    // drive the coordinator through `attach()`, the production entry point.
    private let defaults: UserDefaults
    private let assetStore: AgenticIntakeAssetStore
    private let storageServiceFactory: (@MainActor (AuthService) -> any ImageStorageServicing)?
    private weak var eventStore: EventStore?
    private weak var authService: AuthService?
    weak var statusReporter: SyncStatusReporter?
    private var storageService: (any ImageStorageServicing)?
    private var attemptedImageIDs: Set<UUID> = []

    // MARK: Durable upload markers (gh#219)

    /// Image IDs whose presence in cloud Storage was CONFIRMED by a remote
    /// outcome — a 2xx upload, a 409 "object already exists", or a
    /// successful restore download of the same object. Persisted per user
    /// id (one defaults key per user) so cold launches stop re-reading and
    /// re-POSTing every already-backed-up image.
    ///
    /// The gh#142 rule — a wrongly-persisted "already done" marker is
    /// permanent, so persist only where a wrong skip SELF-HEALS — shapes
    /// the lifecycle: skipping the re-POST of a truly-uploaded image is
    /// harmless (the server has the bytes), while a persisted marker for a
    /// failed upload would mean "never backed up, forever". So an ID enters
    /// this set ONLY after a confirmed remote outcome: never on attempt,
    /// never before the local file read, never on any thrown error.
    ///
    /// Size: one UUID per lifetime-confirmed image, stored as a 36-char
    /// string — ~36 KB per 1,000 photos in a single key, written once per
    /// scan (coalesced), not once per image. No pruning: a marker whose
    /// image was deleted is never consulted again (its ref left every
    /// scanned surface), and pruning against a possibly partially-loaded
    /// store at launch could drop live markers — recreating the re-POST
    /// storm this set exists to prevent.
    private var confirmedUploadedImageIDs: Set<UUID> = []
    /// The user id `confirmedUploadedImageIDs` was loaded for (nil = signed
    /// out). Also the key under which a dirty set flushes.
    private var confirmedUploadsUserID: String?
    private var confirmedUploadsLoaded = false
    private var confirmedUploadsDirty = false

    private static func confirmedUploadsKey(_ userID: String) -> String {
        "imageBackup.confirmedUploadedImageIDs.\(userID)"
    }

    /// Reacts to a session emission. `authService.$session` re-emits on
    /// EVERY `attach()` — each attach re-subscribes, and a fresh
    /// subscription replays the current value — so this must dedupe on the
    /// user id it already holds. Clearing or blindly reloading per emission
    /// would wipe the persisted markers every launch and silently turn the
    /// durable dedup into a no-op.
    private func handleSessionUser(_ userID: String?) {
        if confirmedUploadsLoaded && confirmedUploadsUserID == userID { return }
        // Genuine identity change (or first load). Drop the old user's
        // per-session suppression so the new user's images get evaluated,
        // flush any of the old user's unsaved confirmations under THEIR
        // key, then swap in the new user's persisted set. Keys are per
        // user, so a switch neither reads nor destroys anyone else's
        // markers.
        attemptedImageIDs.removeAll()
        flushConfirmedUploadsIfDirty()
        if let userID {
            confirmedUploadedImageIDs = Set(
                (defaults.stringArray(forKey: Self.confirmedUploadsKey(userID)) ?? [])
                    .compactMap(UUID.init)
            )
        } else {
            confirmedUploadedImageIDs = []
        }
        confirmedUploadsUserID = userID
        confirmedUploadsLoaded = true
        confirmedUploadsDirty = false
    }

    /// Files a confirmed outcome into the durable set — IF the set still
    /// belongs to the user the outcome happened for. A scan captures its
    /// user id at entry; if the session switches while an upload is in
    /// flight, the sink swaps the loaded set to the NEW user's, and filing
    /// the stale outcome there would persist a wrong-skip under the wrong
    /// user (their cloud never gets the image — not self-healing, gh#142).
    /// Dropping the stale mark IS self-healing: the original user's next
    /// scan re-confirms it via a cheap 409.
    private func markConfirmedUploaded(_ id: UUID, for userID: String) {
        guard userID == confirmedUploadsUserID else { return }
        confirmedUploadedImageIDs.insert(id)
        confirmedUploadsDirty = true
    }

    /// One coalesced defaults write per scan/restore completion — never one
    /// per image. Sorted for a deterministic on-disk value.
    private func flushConfirmedUploadsIfDirty() {
        guard confirmedUploadsDirty, let userID = confirmedUploadsUserID else { return }
        defaults.set(
            confirmedUploadedImageIDs.map(\.uuidString).sorted(),
            forKey: Self.confirmedUploadsKey(userID)
        )
        confirmedUploadsDirty = false
    }

    /// Re-entry guard for `scanAndUpload`. `storeChange` debounce +
    /// `userDidEnableUploads` + `attach`-time scan can otherwise overlap.
    /// The work is per-image idempotent at the Storage layer, but overlap
    /// would emit double `imagesDidStart` and clutter the status timeline.
    private var scanInFlight = false
    private var cancellables = Set<AnyCancellable>()
    /// Number of `scanAndUpload` passes that ran to completion (the
    /// disabled-gate no-op path counts; a scan dropped by the re-entry
    /// guard or the not-attached/not-signed-in guards does not). `attach()`
    /// kicks off its initial scan fire-and-forget; tests await that scan by
    /// polling this. Production ignores it.
    private(set) var completedScanCount = 0

    init(
        defaults: UserDefaults = .standard,
        assetStore: AgenticIntakeAssetStore = AgenticIntakeAssetStore(),
        storageServiceFactory: (@MainActor (AuthService) -> any ImageStorageServicing)? = nil
    ) {
        self.defaults = defaults
        self.assetStore = assetStore
        self.storageServiceFactory = storageServiceFactory
    }

    /// Wire up. Idempotent — repeated calls clear prior subscriptions to
    /// avoid duplicate uploads on view-graph rebuilds.
    func attach(eventStore: EventStore, authService: AuthService) {
        cancellables.removeAll()
        self.eventStore = eventStore
        self.authService = authService
        self.storageService = storageServiceFactory?(authService)
            ?? SupabaseImageStorageService(authService: authService)

        // Initial scan + change-driven scans. Merge both event lists into
        // a unit-publisher so we don't run two parallel scans.
        Publishers
            .Merge(
                eventStore.$events.map { _ in () },
                eventStore.$rawCalendarEvents.map { _ in () }
            )
            .debounce(for: .seconds(Self.scanDebounce), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.scanAndUpload(reason: "storeChange") }
            }
            .store(in: &cancellables)

        // Also run once on attach so we pick up images attached before
        // first observation fires (e.g. saved during prior launch).
        Task { await scanAndUpload(reason: "attach") }

        // Load the signed-in user's durable markers and reset the
        // per-session suppression cache — but only on a GENUINE identity
        // change: `handleSessionUser` dedupes on user id because this sink
        // fires on every attach (fresh subscriptions replay the current
        // value; `removeDuplicates` only dedupes within one subscription's
        // stream). Per-user keys also keep one user's markers out of
        // another user's session — the old in-memory-only version of that
        // leak was UUID-collision-improbable but conceptually real.
        authService.$session
            .map { $0?.user.id }
            .removeDuplicates()
            .sink { [weak self] userID in self?.handleSessionUser(userID) }
            .store(in: &cancellables)

        // Observe avatar version bumps so an updated avatar uploads on
        // its own schedule (separate from the event-image scan because
        // its lifecycle — save/delete via the Me-page picker — is
        // disjoint from event mutations).
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(Self.scanDebounce), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.syncAvatarIfNeeded(reason: "userDefaultsChange") }
            }
            .store(in: &cancellables)
        Task { await syncAvatarIfNeeded(reason: "attach") }
    }

    /// Called by the settings UI when the user flips the upload toggle from
    /// OFF → ON. Clears the in-session suppression cache so images we tagged
    /// as "attempted" during the disabled period get re-evaluated and pushed
    /// to the cloud on this fresh scan.
    func userDidEnableUploads() {
        attemptedImageIDs.removeAll()
        Task {
            await scanAndUpload(reason: "userEnabledUploads")
            await syncAvatarIfNeeded(reason: "userEnabledUploads")
        }
    }

    // MARK: - Avatar sync (closing the #1 gap toward full backup)

    /// UserDefaults key for the last avatar version we successfully synced
    /// to the cloud, scoped per user. `meAvatarVersion` itself is in
    /// `SyncedSettings.allKeys` and therefore syncs cross-device; this
    /// key is the **local-only** record of "the version this device has
    /// already pushed".
    private static func lastSyncedAvatarVersionKey(_ userID: String) -> String {
        "lastSyncedAvatarVersion.\(userID)"
    }

    /// Reconcile this device's avatar with the cloud. Three cases:
    ///   - Local has avatar AND version differs from last-synced  → upload
    ///   - Local has NO avatar AND version differs                → delete
    ///   - Versions match                                          → no-op
    ///
    /// The DEBUG safety net + user upload toggle both gate this through
    /// the underlying `SupabaseImageStorageService.upload` (which throws
    /// `.uploadsDisabled` in DEBUG) and the `canUpload` check below.
    func syncAvatarIfNeeded(reason: String) async {
        guard let storageService,
              let userID = authService?.session?.user.id
        else { return }
        // Gate on the same predicate event-image upload uses so the
        // avatar respects the user's per-device upload toggle. Skip
        // silently — the per-image scan already surfaces "disabled"
        // to the status reporter for whichever gate is active, and
        // duplicating it here would emit two channel pings per scan
        // for the same reason.
        let userToggle = defaults.bool(forKey: AppSettingsKeys.syncUploadsEnabled)
        guard !storageService.uploadsDisabled, userToggle else { return }

        let currentVersion = defaults.integer(forKey: AppSettingsKeys.meAvatarVersion)
        let lastSynced = defaults.integer(forKey: Self.lastSyncedAvatarVersionKey(userID))
        guard currentVersion != lastSynced else { return }

        if MeAvatarStore.hasImage {
            guard let data = MeAvatarStore.loadData(), !data.isEmpty else { return }
            do {
                try await storageService.uploadAvatar(userID: userID, data: data)
                defaults.set(currentVersion, forKey: Self.lastSyncedAvatarVersionKey(userID))
                logger.info("Avatar uploaded (\(reason, privacy: .public), \(data.count, privacy: .public) bytes)")
            } catch SupabaseImageStorageService.Error.uploadsDisabled {
                // DEBUG path. Expected. No retry.
            } catch {
                logger.error("Avatar upload failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            // Local was deleted (version bumped + no file on disk).
            await storageService.deleteAvatar(userID: userID)
            defaults.set(currentVersion, forKey: Self.lastSyncedAvatarVersionKey(userID))
            logger.info("Avatar deleted (\(reason, privacy: .public))")
        }
    }

    /// Pull the avatar from cloud if local doesn't have it. Called by
    /// `RestoreCoordinator` after structured restore lands — `MeAvatarStore`
    /// is a file in `Documents/`, not a synced UserDefaults blob, so the
    /// PostgREST restore alone can't bring it back.
    func downloadAvatarIfMissing() async {
        guard let storageService,
              let userID = authService?.session?.user.id
        else { return }
        // Only fetch when local has nothing. If local already exists,
        // assume it's the right one (the user is the one who picked it).
        guard !MeAvatarStore.hasImage else { return }
        do {
            guard let data = try await storageService.downloadAvatar(userID: userID), !data.isEmpty else {
                return  // 404 — no avatar in cloud for this user
            }
            try MeAvatarStore.writeRaw(data)
            // Mark this device as "synced to the version we just downloaded"
            // so the next upload-side scan doesn't try to immediately re-up
            // the freshly-restored bytes.
            let restoredVersion = defaults.integer(forKey: AppSettingsKeys.meAvatarVersion)
            defaults.set(restoredVersion, forKey: Self.lastSyncedAvatarVersionKey(userID))
            logger.info("Avatar restored (\(data.count, privacy: .public) bytes)")
        } catch {
            logger.error("Avatar restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func scanAndUpload(reason: String) async {
        guard let eventStore,
              let storageService,
              let userID = authService?.session?.user.id
        else { return }
        // Re-entry guard. The in-flight scan will already pick up any new
        // candidates that landed since it started, so dropping the duplicate
        // is correct, not just an optimization.
        if scanInFlight { return }
        // Defensive: the session sink normally loaded the durable markers
        // during attach(); this no-ops when they're already loaded for
        // `userID` and repairs the ordering if a future refactor breaks it.
        handleSessionUser(userID)
        scanInFlight = true
        defer {
            scanInFlight = false
            completedScanCount += 1
        }

        // Pre-scan: count work so we can decide whether to surface activity.
        // Cheap relative to the actual upload; avoids spinner flicker on
        // scans that find nothing to do.
        let candidateCount = Self.countUploadCandidates(
            eventStore: eventStore,
            suppressedImageIDs: attemptedImageIDs.union(confirmedUploadedImageIDs)
        )
        // Two independent gates can disable uploads:
        //  1. DEBUG safety net (compile-time) — simulator/dev builds never write
        //  2. User toggle (`syncUploadsEnabled`) — Release users opt-in per device
        // Either gate active → surface a one-shot "disabled" note + suppress
        // future re-pings (mark all current candidates as attempted), and
        // bail before any I/O. The reason label distinguishes the two so a
        // confused user can tell whether it's a dev build or their toggle.
        let userToggle = defaults.bool(forKey: AppSettingsKeys.syncUploadsEnabled)
        if candidateCount > 0,
           storageService.uploadsDisabled || !userToggle {
            Self.collectCandidateIDs(eventStore: eventStore, into: &attemptedImageIDs)
            let reason = storageService.uploadsDisabled
                ? "disabled (DEBUG)"
                : "uploads off (Settings)"
            statusReporter?.imagesDidNoOp(detail: reason)
            return
        }
        let trackInUI = candidateCount > 0
        if trackInUI { statusReporter?.imagesDidStart() }

        var newlyUploaded = 0
        var alreadyInCloud = 0
        var failed = 0

        // 1. Agentic-intake images on the event itself.
        let allEvents = eventStore.events + eventStore.rawCalendarEvents
        for event in allEvents {
            guard let intake = event.agenticIntake else { continue }
            for ref in intake.images {
                await uploadIfNeeded(
                    ref: ref,
                    eventID: event.id,
                    userID: userID,
                    storageService: storageService,
                    newlyUploaded: &newlyUploaded,
                    alreadyInCloud: &alreadyInCloud,
                    failed: &failed
                )
            }
        }

        // 2. Timeline-note images attached during logging. These live on
        //    `CalendarEventLogRecord.timelineItems[*].note(EventLogTimelineNote).images`
        //    and use the same on-disk layout (`AgenticIntakeAssets/{eventID}/{imageID}.jpg`,
        //    keyed by the parent event's ID — see saveImages call sites in
        //    `CalendarEventLogSheet` and `CalendarEventDetailView`). Without
        //    this loop they sync as refs across devices but the binaries
        //    stay orphaned on the originating device.
        for log in eventStore.calendarEventLogRecords {
            for item in log.timelineItems {
                guard let note = item.noteValue else { continue }
                for ref in note.images {
                    await uploadIfNeeded(
                        ref: ref,
                        eventID: log.eventID,
                        userID: userID,
                        storageService: storageService,
                        newlyUploaded: &newlyUploaded,
                        alreadyInCloud: &alreadyInCloud,
                        failed: &failed
                    )
                }
            }
        }

        // Coalesced durable-marker write: everything this scan confirmed
        // (2xx and 409 alike) lands in one defaults write.
        flushConfirmedUploadsIfDirty()

        if newlyUploaded > 0 || alreadyInCloud > 0 || failed > 0 {
            logger.info("Scan (\(reason, privacy: .public)): \(newlyUploaded, privacy: .public) new, \(alreadyInCloud, privacy: .public) already in cloud, \(failed, privacy: .public) failed")
        }
        if trackInUI {
            if failed == 0 {
                // Compose a useful detail string that doesn't lie. "0 new"
                // when everything was already in cloud is honest; "N uploaded"
                // when it was really a no-op dedup pass would be misleading.
                let detail: String
                switch (newlyUploaded, alreadyInCloud) {
                case (0, 0):                 detail = "no changes"
                case (0, let dedup):         detail = "\(dedup) already in cloud"
                case (let n, 0):             detail = "\(n) uploaded"
                case (let n, let dedup):     detail = "\(n) new, \(dedup) already in cloud"
                }
                statusReporter?.imagesDidSucceed(detail: detail)
            } else {
                statusReporter?.imagesDidFail("\(failed) of \(newlyUploaded + alreadyInCloud + failed) failed")
            }
        }
    }

    /// Counts unsuppressed image refs in both surfaces. Mirrors the
    /// iteration in `scanAndUpload` but does no I/O. `suppressedImageIDs`
    /// is the union of both dedup tiers: per-session attempts + durable
    /// confirmed uploads.
    private static func countUploadCandidates(
        eventStore: EventStore,
        suppressedImageIDs: Set<UUID>
    ) -> Int {
        var n = 0
        for event in eventStore.events + eventStore.rawCalendarEvents {
            guard let intake = event.agenticIntake else { continue }
            for ref in intake.images where !suppressedImageIDs.contains(ref.id) { n += 1 }
        }
        for log in eventStore.calendarEventLogRecords {
            for item in log.timelineItems {
                guard let note = item.noteValue else { continue }
                for ref in note.images where !suppressedImageIDs.contains(ref.id) { n += 1 }
            }
        }
        return n
    }

    /// Walk the same two surfaces and insert every image ID into the
    /// suppression set. Used by the DEBUG no-op path so we don't re-ping the
    /// status UI on every subsequent store edit.
    private static func collectCandidateIDs(
        eventStore: EventStore,
        into set: inout Set<UUID>
    ) {
        for event in eventStore.events + eventStore.rawCalendarEvents {
            guard let intake = event.agenticIntake else { continue }
            for ref in intake.images { set.insert(ref.id) }
        }
        for log in eventStore.calendarEventLogRecords {
            for item in log.timelineItems {
                guard let note = item.noteValue else { continue }
                for ref in note.images { set.insert(ref.id) }
            }
        }
    }

    private func uploadIfNeeded(
        ref: AgenticIntakeImageRef,
        eventID: UUID,
        userID: String,
        storageService: any ImageStorageServicing,
        newlyUploaded: inout Int,
        alreadyInCloud: inout Int,
        failed: inout Int
    ) async {
        guard !confirmedUploadedImageIDs.contains(ref.id),
              !attemptedImageIDs.contains(ref.id) else { return }
        attemptedImageIDs.insert(ref.id)

        let localURL = assetStore.absoluteURL(for: ref)
        guard let data = try? Data(contentsOf: localURL) else {
            // Local file missing — nothing to upload. Could be a
            // restore-imminent state. Suppressed for THIS session (the ID
            // stays in `attemptedImageIDs`: no per-scan disk probes or
            // status pings), but deliberately NOT marked confirmed — no
            // remote outcome happened (gh#142) — so the next launch
            // retries. The old in-memory-only set provided that retry by
            // accident of its process reset; the durable tier preserves it
            // by design.
            return
        }
        let path = storageService.storagePath(
            userID: userID,
            eventID: eventID,
            imageID: ref.id
        )
        do {
            let didWriteNewBytes = try await storageService.upload(path: path, data: data)
            // Confirmed remote outcome — 2xx (bytes written this call) or
            // 409 (object already at this path). The ONLY line that feeds
            // the durable tier from the upload side; every thrown error
            // skips it, so failures stay retryable forever.
            markConfirmedUploaded(ref.id, for: userID)
            if didWriteNewBytes {
                newlyUploaded += 1
            } else {
                alreadyInCloud += 1
            }
        } catch SupabaseImageStorageService.Error.uploadsDisabled {
            // DEBUG path. Expected. No retry.
        } catch SupabaseImageStorageService.Error.notSignedIn {
            attemptedImageIDs.remove(ref.id)
        } catch SupabaseImageStorageService.Error.emptyData {
            // Permanent: local file is corrupt (0 bytes). Keep in
            // attemptedImageIDs to suppress retry; user would need to
            // re-attach the image to recover.
            logger.error("Image \(ref.id, privacy: .private) local file is empty/corrupt — skipping permanently this session")
        } catch {
            attemptedImageIDs.remove(ref.id)
            failed += 1
            logger.error("Image \(ref.id, privacy: .private) upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called by `RestoreCoordinator` after `applyRestore` mutates events.
    /// Walks both surfaces that carry image refs in the restored state —
    /// `event.agenticIntake.images` AND `log.timelineItems.note(...).images`
    /// — and downloads any whose local file is missing. Sequential; we
    /// want to be a polite cloud citizen and a typical restore won't have
    /// thousands of images.
    func downloadMissing(forEvents events: [Event]) async {
        guard let eventStore,
              let storageService,
              let userID = authService?.session?.user.id
        else { return }
        // Defensive, same as `scanAndUpload`: make sure the durable-marker
        // set belongs to `userID` before we file confirmations into it.
        handleSessionUser(userID)

        // Tuple carries the `eventID` to use for the cloud path. For
        // agentic-intake images that's the event's own id; for timeline-note
        // images it's the parent log's `eventID` (same on-disk path scheme).
        struct Pending {
            let eventID: UUID
            let ref: AgenticIntakeImageRef
            let localURL: URL
        }
        var pending: [Pending] = []

        // 1. Agentic-intake images on events
        for event in events {
            guard let intake = event.agenticIntake else { continue }
            for ref in intake.images {
                let localURL = assetStore.absoluteURL(for: ref)
                if !FileManager.default.fileExists(atPath: localURL.path) {
                    pending.append(Pending(eventID: event.id, ref: ref, localURL: localURL))
                }
            }
        }
        // 2. Timeline-note images on log records (read live from store so
        //    we cover all restored logs, not just those for the events we
        //    were handed). Without this, log photos wouldn't survive
        //    cross-device restore.
        for log in eventStore.calendarEventLogRecords {
            for item in log.timelineItems {
                guard let note = item.noteValue else { continue }
                for ref in note.images {
                    let localURL = assetStore.absoluteURL(for: ref)
                    if !FileManager.default.fileExists(atPath: localURL.path) {
                        pending.append(Pending(eventID: log.eventID, ref: ref, localURL: localURL))
                    }
                }
            }
        }
        guard !pending.isEmpty else { return }
        logger.info("Restore: downloading \(pending.count, privacy: .public) missing image(s)")
        statusReporter?.imagesDidStart()
        defer { restoreDownloadProgress = nil }

        var ok = 0
        var fail = 0
        for (index, p) in pending.enumerated() {
            // 1-indexed for display: "Downloading images: 1 / N" while the
            // first image is in flight (not "0 / N", which is confusing).
            // The redundant final "(N, N)" assignment was dropped — `defer`
            // nils the value immediately after method return so a frame at
            // 100% is never actually visible to the user.
            restoreDownloadProgress = DownloadProgress(
                current: index + 1,
                total: pending.count
            )
            let path = storageService.storagePath(
                userID: userID,
                eventID: p.eventID,
                imageID: p.ref.id
            )
            do {
                guard let data = try await storageService.download(path: path) else {
                    // 404 → not in cloud either. Image is lost; nothing to do.
                    continue
                }
                try FileManager.default.createDirectory(
                    at: p.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: p.localURL, options: .atomic)
                // The object verifiably exists in cloud Storage — we just
                // downloaded it. Same confirmation strength as a 409, so
                // it feeds the durable tier and the upload scan skips it
                // on every future launch, not just this session.
                markConfirmedUploaded(p.ref.id, for: userID)
                ok += 1
            } catch {
                fail += 1
                logger.error("Image \(p.ref.id, privacy: .private) download failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        flushConfirmedUploadsIfDirty()
        logger.info("Restore: image download complete (\(ok, privacy: .public)/\(pending.count, privacy: .public) ok, \(fail, privacy: .public) failed)")
        if fail == 0 {
            statusReporter?.imagesDidSucceed(detail: "\(ok) downloaded")
        } else {
            statusReporter?.imagesDidFail("restore: \(fail) of \(pending.count) failed")
        }
    }
}
