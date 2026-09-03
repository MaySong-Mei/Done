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
/// - **In-memory attempt tracking** to avoid spamming the API. A `Set<UUID>`
///   of image IDs we've already tried this session prevents repeat work for
///   images we know are uploaded (or that just failed and we shouldn't
///   hammer). On failure we remove from the set so the next store-change
///   scan retries.
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

        // Reset the per-session suppression cache when the signed-in user
        // changes. Without this, a sign-out → sign-in-as-different-user on
        // the same device would carry the old user's "already attempted"
        // image IDs into the new session — UUID collisions are
        // astronomically unlikely (128 bits), but the conceptual leak is
        // real and a one-line fix.
        authService.$session
            .map { $0?.user.id }
            .removeDuplicates()
            .sink { [weak self] _ in self?.attemptedImageIDs.removeAll() }
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
            attemptedImageIDs: attemptedImageIDs
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

    /// Counts unattempted image refs in both surfaces. Mirrors the iteration
    /// in `scanAndUpload` but only reads `attemptedImageIDs` — no I/O.
    private static func countUploadCandidates(
        eventStore: EventStore,
        attemptedImageIDs: Set<UUID>
    ) -> Int {
        var n = 0
        for event in eventStore.events + eventStore.rawCalendarEvents {
            guard let intake = event.agenticIntake else { continue }
            for ref in intake.images where !attemptedImageIDs.contains(ref.id) { n += 1 }
        }
        for log in eventStore.calendarEventLogRecords {
            for item in log.timelineItems {
                guard let note = item.noteValue else { continue }
                for ref in note.images where !attemptedImageIDs.contains(ref.id) { n += 1 }
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
        guard !attemptedImageIDs.contains(ref.id) else { return }
        attemptedImageIDs.insert(ref.id)

        let localURL = assetStore.absoluteURL(for: ref)
        guard let data = try? Data(contentsOf: localURL) else {
            // Local file missing — nothing to upload. Could be a
            // restore-imminent state. Skip without erroring; will
            // try again if local file ever materializes.
            return
        }
        let path = storageService.storagePath(
            userID: userID,
            eventID: eventID,
            imageID: ref.id
        )
        do {
            let didWriteNewBytes = try await storageService.upload(path: path, data: data)
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
                // Mark as "attempted" so the upload scan doesn't try to
                // re-upload the same bytes we just pulled down.
                attemptedImageIDs.insert(p.ref.id)
                ok += 1
            } catch {
                fail += 1
                logger.error("Image \(p.ref.id, privacy: .private) download failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.info("Restore: image download complete (\(ok, privacy: .public)/\(pending.count, privacy: .public) ok, \(fail, privacy: .public) failed)")
        if fail == 0 {
            statusReporter?.imagesDidSucceed(detail: "\(ok) downloaded")
        } else {
            statusReporter?.imagesDidFail("restore: \(fail) of \(pending.count) failed")
        }
    }
}
