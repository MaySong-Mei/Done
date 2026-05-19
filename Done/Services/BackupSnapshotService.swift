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

    private var cancellables = Set<AnyCancellable>()

    init() {}

    /// Wire up subscribers. Idempotent; safe to call once after stores exist.
    func attach(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) {
        self.eventStore = eventStore
        self.eventTypeStore = eventTypeStore
        self.skillStore = skillStore

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
        let storeChanges = Publishers
            .Merge5(
                eventStore.$events.map { _ in () },
                eventStore.$calendarEvents.map { _ in () },
                eventStore.$calendarEventLogRecords.map { _ in () },
                eventStore.$calendarEventFeedbackRecords.map { _ in () },
                eventStore.$todoLists.map { _ in () }
            )
            .dropFirst()
            .debounce(for: .seconds(Self.storeChangeDebounce), scheduler: RunLoop.main)

        storeChanges
            .sink { [weak self] _ in
                self?.writeSnapshotSync(reason: "storeChange")
            }
            .store(in: &cancellables)
    }

    /// On-demand write (e.g. from a "Snapshot now" UI button, if we add one).
    /// Public so the restore UI can offer manual triggers if needed.
    func writeSnapshotNow(reason: String = "manual") {
        writeSnapshotSync(reason: reason)
    }

    // MARK: - Implementation

    private func writeSnapshotSync(reason: String) {
        guard let eventStore, let eventTypeStore, let skillStore else { return }

        do {
            let data = try buildSnapshotData(
                eventStore: eventStore,
                eventTypeStore: eventTypeStore,
                skillStore: skillStore
            )
            try writeAtomically(data)
            logger.info("Snapshot written (\(data.count, privacy: .public) bytes, reason: \(reason, privacy: .public))")
        } catch {
            logger.error("Snapshot write failed (reason: \(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Build the snapshot payload as a single JSON-serializable dictionary so
    /// it's both human-readable and tolerant of the heterogeneous data we
    /// carry (typed models + an untyped settings blob).
    private func buildSnapshotData(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        func jsonArray<T: Encodable>(_ items: [T]) throws -> [Any] {
            let data = try encoder.encode(items)
            return (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
        }

        let dict: [String: Any] = [
            "version": Self.snapshotVersion,
            "createdAt": ISO8601DateFormatter.iso8601WithFraction.string(from: Date()),
            "events": try jsonArray(eventStore.events),
            "calendarEvents": try jsonArray(eventStore.calendarEvents),
            "logs": try jsonArray(eventStore.calendarEventLogRecords),
            "feedback": try jsonArray(eventStore.calendarEventFeedbackRecords),
            "todoLists": try jsonArray(eventStore.todoLists),
            "eventTypes": try jsonArray(eventTypeStore.templates),
            "skills": try jsonArray(skillStore.insights),
            "settings": SyncedSettings.currentSnapshot(),
        ]

        return try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Write to a temp file then `replaceItem` so readers never see a partial
    /// file (especially important if a future foreground reader is added).
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
