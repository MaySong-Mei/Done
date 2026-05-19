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
///   observes `EventStore.$events` / `$calendarEvents` and uploads anything
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

    private let assetStore = AgenticIntakeAssetStore()
    private weak var eventStore: EventStore?
    private weak var authService: AuthService?
    private var storageService: SupabaseImageStorageService?
    private var attemptedImageIDs: Set<UUID> = []
    private var cancellables = Set<AnyCancellable>()

    init() {}

    /// Wire up. Idempotent — repeated calls clear prior subscriptions to
    /// avoid duplicate uploads on view-graph rebuilds.
    func attach(eventStore: EventStore, authService: AuthService) {
        cancellables.removeAll()
        self.eventStore = eventStore
        self.authService = authService
        self.storageService = SupabaseImageStorageService(authService: authService)

        // Initial scan + change-driven scans. Merge both event lists into
        // a unit-publisher so we don't run two parallel scans.
        Publishers
            .Merge(
                eventStore.$events.map { _ in () },
                eventStore.$calendarEvents.map { _ in () }
            )
            .debounce(for: .seconds(Self.scanDebounce), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.scanAndUpload(reason: "storeChange") }
            }
            .store(in: &cancellables)

        // Also run once on attach so we pick up images attached before
        // first observation fires (e.g. saved during prior launch).
        Task { await scanAndUpload(reason: "attach") }
    }

    func scanAndUpload(reason: String) async {
        guard let eventStore,
              let storageService,
              let userID = authService?.session?.user.id
        else { return }

        var newlyUploaded = 0
        var failed = 0

        // 1. Agentic-intake images on the event itself.
        let allEvents = eventStore.events + eventStore.calendarEvents
        for event in allEvents {
            guard let intake = event.agenticIntake else { continue }
            for ref in intake.images {
                await uploadIfNeeded(
                    ref: ref,
                    eventID: event.id,
                    userID: userID,
                    storageService: storageService,
                    newlyUploaded: &newlyUploaded,
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
                        failed: &failed
                    )
                }
            }
        }

        if newlyUploaded > 0 || failed > 0 {
            logger.info("Scan (\(reason, privacy: .public)): uploaded \(newlyUploaded, privacy: .public), failed \(failed, privacy: .public)")
        }
    }

    private func uploadIfNeeded(
        ref: AgenticIntakeImageRef,
        eventID: UUID,
        userID: String,
        storageService: SupabaseImageStorageService,
        newlyUploaded: inout Int,
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
            try await storageService.upload(path: path, data: data)
            newlyUploaded += 1
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
    }
}
