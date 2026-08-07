import Foundation
import Combine
import SwiftUI
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "BackupSnapshot"
)

/// Writes a comprehensive JSON snapshot of all user-specific data to
/// `Documents/backup-snapshot.json`. This file is automatically included in
/// iOS Device Backup (and thus iCloud Backup if the user has it on), giving
/// us a recovery layer independent of Supabase.
///
/// Two triggers keep the snapshot fresh:
///   1. `UIApplication.didEnterBackgroundNotification` — most important; iOS
///      Backup typically runs at night when the app is backgrounded.
///   2. EventStore / EventTypeTemplateStore / SkillInsightStore changes with
///      a 30s debounce — captures in-foreground edits in case the user uses
///      the app continuously without backgrounding before a corruption event.
///
/// The file is intentionally redundant with Supabase. When Supabase is the
/// preferred recovery source, this file is just belt-and-suspenders. When
/// Supabase is unreachable or the user wants offline recovery, this is the
/// fallback.
@MainActor
final class BackupSnapshotService: ObservableObject {
    /// Bump when the on-disk shape changes in an incompatible way.
    private static let snapshotVersion = 1

    /// One file, always at the same path. Rolled atomically on every write so
    /// readers never see a half-written file.
    private static let snapshotFilename = "backup-snapshot.json"

    /// 30s debounce on store changes — much longer than the Supabase sync
    /// debounce (2s) since this writes to disk locally and there's no
    /// network cost. Enough to coalesce a burst of edits.
    private static let storeChangeDebounce: TimeInterval = 30

    private weak var eventStore: EventStore?
    private weak var eventTypeStore: EventTypeTemplateStore?
    private weak var skillStore: SkillInsightStore?
    private weak var preferenceStore: AgentPreferenceStore?
    weak var statusReporter: SyncStatusReporter?

    /// Which `UserDefaults` the `settings` blob — and therefore its BRIDGED
    /// keys, whose truth lives in files rather than in preferences — is read
    /// through. Always `.standard` in the app; the seam exists so a test can
    /// stage a bridged owner in a specific state (see
    /// `OccurrenceKeyMetadataStore.register(_:for:)`), which is otherwise
    /// impossible for a process-wide singleton.
    var settingsDefaults: UserDefaults = .standard

    private var cancellables = Set<AnyCancellable>()

    init() {}

    /// Wire up subscribers. Idempotent — calling it more than once (e.g. if
    /// `onAppear` re-fires due to SwiftUI view-graph rebuilds) clears the
    /// previous subscriptions before installing fresh ones, so we never end
    /// up with duplicate snapshot writers racing each other.
    func attach(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore,
        preferenceStore: AgentPreferenceStore
    ) {
        cancellables.removeAll()
        self.eventStore = eventStore
        self.eventTypeStore = eventTypeStore
        self.skillStore = skillStore
        self.preferenceStore = preferenceStore

        // ── App backgrounding ──
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.writeSnapshotSync(reason: "didEnterBackground")
            }
            .store(in: &cancellables)

        // ── Store-change debounce (30s) ──
        // We piggyback on EventStore's @Published arrays; any change in the
        // five core lists triggers a (debounced) snapshot. Event-types and
        // skills are quieter so we skip per-store debounces for them — the
        // background trigger covers infrequent edits.
        // Each of the five `@Published` arrays emits its current value the
        // moment we subscribe, so the merged stream produces five initial
        // emissions. Drop all five so we don't write a spurious snapshot
        // ~30s after every launch with no real user activity. Genuine edits
        // afterwards still flow through the debounce.
        let storeChanges = Publishers
            .Merge5(
                eventStore.$events.map { _ in () },
                eventStore.$rawCalendarEvents.map { _ in () },
                eventStore.$calendarEventLogRecords.map { _ in () },
                eventStore.$calendarEventFeedbackRecords.map { _ in () },
                eventStore.$todoLists.map { _ in () }
            )
            .dropFirst(5)
            .debounce(for: .seconds(Self.storeChangeDebounce), scheduler: RunLoop.main)

        storeChanges
            .sink { [weak self] _ in
                self?.writeSnapshotSync(reason: "storeChange")
            }
            .store(in: &cancellables)
    }

    // MARK: - Implementation

    /// Reasons whose write should be surfaced in the Sync Status UI. The 30s
    /// debounced `storeChange` path is deliberately excluded — it would
    /// re-tick the "Local snapshot" row every half-minute during active use,
    /// which is more noise than signal. Background/foreground/manual writes
    /// are still reported.
    private static let reasonsSurfacedInUI: Set<String> = [
        "didEnterBackground",
        "manual",
    ]

    /// Internal rather than private so a test can exercise the frozen-slot
    /// suppression below without posting a process-wide
    /// `didEnterBackgroundNotification` — which, in a host-app test bundle,
    /// would also drive the RUNNING app's own snapshot writer.
    func writeSnapshotSync(reason: String) {
        guard let eventStore, let eventTypeStore, let skillStore else { return }

        // A frozen slot reads as an EMPTY array in memory (see
        // `EventStore.isSlotFrozen`) — and a slot freezes precisely because
        // its file could not be read, which is the one moment this snapshot
        // and the cloud are the only surviving copies. Overwriting the
        // snapshot with that emptiness would destroy the local half of the
        // recovery on the next backgrounding, seconds after the fault.
        //
        // All-or-nothing on purpose: this is ONE document spanning five
        // slots, so a single frozen slot poisons it, and a stale-but-complete
        // snapshot beats a fresh one with a hole in it.
        // The event-type catalog is the sixth thing this document spans, and
        // it freezes for exactly the same reason a slot does. All-or-nothing
        // includes it: a snapshot whose `eventTypes` array came back empty
        // would strip the color off every event in the other five on restore.
        //
        // EITHER of the catalog's two files, deliberately — unlike the sync
        // paths, which are scoped to the one they mirror. This document
        // carries the templates array AND, inside `settings`, the bridged
        // color history, so an unreadable history file punches a hole in it
        // just as an unreadable templates file does.
        //
        // The chat history is the seventh, and it is the largest single thing
        // this document carries. Same rule, same reason: an unreadable
        // conversation file reads as `[]`, and rewriting the snapshot from that
        // would destroy the local half of the recovery seconds after the fault.
        //
        // And the `settings` blob is the eighth, which is where the ASYMMETRY
        // this gate used to have lived. `SyncedSettings.currentSnapshot()` reads
        // its bridged keys from their durable owners, and an owner that cannot
        // answer makes the key ABSENT rather than wrong — a hole, silently, in
        // a document that then replaces the one that had it. The upload path
        // already refuses to send that blob (`settingsExportSuppressed`), and
        // the local half must reach the same conclusion from the same
        // predicate, or "stale beats holed" holds for the cloud copy and not
        // for the local one.
        //
        // The frozen reference time zone is the case that forced this: its
        // owner is unusable both when the file is unreadable AND when the file
        // holds an identifier this OS does not know, and `hasUnreadableBridgedOwner`
        // is the only predicate that covers the second.
        let conversations = AgentConversationRepository.shared
        let settingsBlobHoled = SyncedSettings.hasUnreadableBridgedOwner(settingsDefaults)
        if eventStore.hasFrozenSlot
            || eventTypeStore.isCatalogFrozen
            || conversations.isFrozen
            || settingsBlobHoled {
            let slots = [
                eventStore.frozenSlotNames,
                eventTypeStore.isCatalogFrozen ? "eventTypes" : "",
                conversations.isFrozen ? "agentConversations" : "",
                settingsBlobHoled ? "settings" : "",
            ]
                .filter { !$0.isEmpty }
                .joined(separator: ",")
            logger.error("Snapshot SKIPPED (reason: \(reason, privacy: .public)) — frozen slots: \(slots, privacy: .public); keeping the previous snapshot")
            statusReporter?.snapshotDidStart()
            statusReporter?.snapshotDidFail("Local store degraded (\(slots)) — kept the previous snapshot")
            return
        }

        let surfaceInUI = Self.reasonsSurfacedInUI.contains(reason)
        if surfaceInUI { statusReporter?.snapshotDidStart() }
        do {
            let data = try buildSnapshotData(
                eventStore: eventStore,
                eventTypeStore: eventTypeStore,
                skillStore: skillStore,
                preferenceStore: preferenceStore
            )
            try writeAtomically(data)
            logger.info("Snapshot written (\(data.count, privacy: .public) bytes, reason: \(reason, privacy: .public))")
            if surfaceInUI { statusReporter?.snapshotDidSucceed(byteCount: data.count) }
        } catch {
            logger.error("Snapshot write failed (reason: \(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            // Always surface errors, even on the debounced path — a silent
            // failing snapshot is worse than a noisy row.
            if surfaceInUI {
                statusReporter?.snapshotDidFail(error.localizedDescription)
            } else {
                statusReporter?.snapshotDidStart()
                statusReporter?.snapshotDidFail(error.localizedDescription)
            }
        }
    }

    /// Build the snapshot payload as a single JSON-serializable dictionary so
    /// it's both human-readable and tolerant of the heterogeneous data we
    /// carry (typed models + an untyped settings blob).
    ///
    /// **Coverage**: this is the local-DR side of the audit table. As the
    /// cloud-side picks up new buckets (avatar binary, agent preferences,
    /// agent conversations — see `SupabaseSyncService.restoreTables`), the
    /// snapshot mirrors them or the local-only path falls strictly behind.
    private func buildSnapshotData(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore,
        preferenceStore: AgentPreferenceStore?
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        func jsonArray<T: Encodable>(_ items: [T]) throws -> [Any] {
            let data = try encoder.encode(items)
            return (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
        }

        // Avatar bytes: base64 so the snapshot stays a single JSON file.
        // ~100 KB compressed JPEG → ~133 KB base64 — tolerable for a JSON
        // payload; the alternative (sibling file) would complicate the
        // "one file = one restore" property the snapshot has today.
        let avatarBase64: String? = MeAvatarStore.loadData()?.base64EncodedString()

        // Agent conversations: canonical bytes from the durable repository,
        // decoded back to JSON-native so the dict round-trips through
        // JSONSerialization cleanly. The `[]` fallbacks are for an encode
        // failure only — an unreadable file is caught by the frozen gate in
        // `writeSnapshotSync`, before this document is built at all.
        let conversationsBlob: Any = {
            let raw = AgentConversationRepository.shared.encodedJSONForSync() ?? Data()
            if raw.isEmpty { return [] }
            return (try? JSONSerialization.jsonObject(with: raw)) ?? []
        }()

        var dict: [String: Any] = [
            "version": Self.snapshotVersion,
            "createdAt": ISO8601DateFormatter.iso8601WithFraction.string(from: Date()),
            "events": try jsonArray(eventStore.events),
            "calendarEvents": try jsonArray(eventStore.rawCalendarEvents),
            "logs": try jsonArray(eventStore.calendarEventLogRecords),
            "feedback": try jsonArray(eventStore.calendarEventFeedbackRecords),
            "todoLists": try jsonArray(eventStore.todoLists),
            "eventTypes": try jsonArray(eventTypeStore.templates),
            "skills": try jsonArray(skillStore.insights),
            "settings": SyncedSettings.currentSnapshot(settingsDefaults),
            "agentConversations": conversationsBlob,
        ]
        if let preferenceStore {
            dict["agentRules"] = try jsonArray(preferenceStore.rules)
            dict["agentDecisionHistory"] = try jsonArray(preferenceStore.decisionHistory)
        }
        if let avatarBase64 {
            dict["avatarJPEGBase64"] = avatarBase64
        }

        return try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// `Data.write(options: .atomic)` is implemented by Foundation as
    /// write-to-temp-then-rename, so readers never see a partial file —
    /// important if a future foreground reader is added.
    private func writeAtomically(_ data: Data) throws {
        let url = try Self.snapshotURL()
        try data.write(to: url, options: [.atomic])
    }

    /// Public so a future "Restore from local snapshot" UI can read it.
    static func snapshotURL() throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "BackupSnapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Documents directory unavailable",
            ])
        }
        return docs.appendingPathComponent(snapshotFilename)
    }
}

private extension ISO8601DateFormatter {
    static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
