import CryptoKit
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

    /// Where the snapshot lands. `nil` — always, in the app — means
    /// `Self.snapshotURL()` (Documents). A test points this at a scratch file
    /// so exercising the writer neither clobbers the host app's real snapshot
    /// nor reads leftover state a previous run left there.
    var snapshotFileURLOverride: URL?

    /// How many snapshot files THIS instance has actually written. Purely a
    /// test observable: file bytes cannot distinguish "skipped" from "rewrote
    /// equal content in the same millisecond", but this counter can.
    private(set) var snapshotWritesPerformed = 0

    /// Content digest (`componentsDigest`) of the payload most recently KNOWN
    /// to be on disk — set after a successful write, or after the launch-seed
    /// comparison proves the disk file already carries current content. `nil`
    /// until the first evaluation each launch: the marker is deliberately
    /// in-memory only, re-derived from the snapshot file itself, so it cannot
    /// desync from the file the way a persisted marker could (the gh#142 rule).
    private var lastWrittenComponentsDigest: Data?

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
    /// which is more noise than signal. The backgrounding write is still
    /// reported. ("manual" sat here for a while, but no caller ever sent it.)
    private static let reasonsSurfacedInUI: Set<String> = [
        "didEnterBackground",
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
        var reportedStart = false
        do {
            // ── Dirty check ──
            // The document is rebuilt from scratch on every trigger, so "did
            // anything change" is answered by hashing what the rebuild would
            // say — before the two JSONSerialization passes and the I/O,
            // which are what the guard exists to skip. `createdAt` is the one
            // field the digest must ignore (same trap, same answer as
            // `rowHashIgnoredKeys`): it is stamped fresh at write time, so
            // hashing it would leave a guard that never fires yet looks alive.
            let components = try encodeSnapshotComponents(
                eventStore: eventStore,
                eventTypeStore: eventTypeStore,
                skillStore: skillStore,
                preferenceStore: preferenceStore
            )
            let digest = Self.componentsDigest(components)

            if digest == lastWrittenComponentsDigest {
                logger.info("Snapshot skipped — content unchanged (reason: \(reason, privacy: .public))")
                return
            }

            // First evaluation this launch: the in-memory digest knows
            // nothing yet, but the disk file does. Seed by comparing against
            // the snapshot itself — parsed, `createdAt` stripped, canonically
            // re-serialized — so a relaunch over an unchanged store writes
            // nothing. Costlier than the steady-state check above (it pays
            // the jsonObject passes once), but it runs at most once per
            // launch, and never on the launch path itself: the earliest
            // trigger is a backgrounding or a 30s-quiet edit.
            var assembled: [String: Any]?
            if lastWrittenComponentsDigest == nil {
                let payload = try assemblePayload(from: components)
                assembled = payload
                if let onDisk = canonicalDigestOfDiskSnapshot(),
                   onDisk == Self.canonicalDigest(ofPayload: payload) {
                    lastWrittenComponentsDigest = digest
                    logger.info("Snapshot skipped — disk already current (reason: \(reason, privacy: .public))")
                    return
                }
            }

            if surfaceInUI {
                statusReporter?.snapshotDidStart()
                reportedStart = true
            }
            var dict: [String: Any]
            if let assembled {
                dict = assembled
            } else {
                dict = try assemblePayload(from: components)
            }
            dict["createdAt"] = ISO8601DateFormatter.iso8601WithFraction.string(from: Date())
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
            try writeAtomically(data)
            // Only after the write LANDS: a failed write must leave the
            // digest stale so the next trigger retries instead of skipping.
            lastWrittenComponentsDigest = digest
            logger.info("Snapshot written (\(data.count, privacy: .public) bytes, reason: \(reason, privacy: .public))")
            if surfaceInUI { statusReporter?.snapshotDidSucceed(byteCount: data.count) }
        } catch {
            logger.error("Snapshot write failed (reason: \(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            // Always surface errors, even on the debounced path — a silent
            // failing snapshot is worse than a noisy row.
            if !reportedStart { statusReporter?.snapshotDidStart() }
            statusReporter?.snapshotDidFail(error.localizedDescription)
        }
    }

    /// Stage 1 of the build: every component of the document in its cheapest
    /// stable byte form — per-collection `JSONEncoder` output, the settings
    /// blob canonically serialized, the conversation repository's own sync
    /// bytes, the raw avatar. This is what the dirty check hashes, computed
    /// BEFORE the `JSONSerialization` round-trips: a clean skip pays the
    /// encode pass only. (The encode is the unavoidable bulk — it is how we
    /// learn what the stores would say — but the jsonObject parse, the
    /// pretty re-serialize, and the disk write are all skipped.)
    ///
    /// **Coverage**: this is the local-DR side of the audit table. As the
    /// cloud-side picks up new buckets (avatar binary, agent preferences,
    /// agent conversations — see `SupabaseSyncService.restoreTables`), the
    /// snapshot mirrors them or the local-only path falls strictly behind.
    /// A new bucket must land in BOTH `collections`/fields here AND
    /// `assemblePayload` — the digest walks this struct, so a bucket that
    /// skips it would never dirty the snapshot.
    private struct SnapshotComponents {
        /// `(payload key, encoder bytes)` in a FIXED order — the digest walks
        /// this order, so the order is part of the digest's meaning.
        var collections: [(key: String, data: Data)]
        var settings: [String: Any]
        var settingsCanonical: Data
        var conversationsRaw: Data
        var avatarData: Data?
    }

    private func encodeSnapshotComponents(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore,
        preferenceStore: AgentPreferenceStore?
    ) throws -> SnapshotComponents {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys for the same reason `AtomicValueFile`'s and the
        // conversation repository's sync encoders use them: JSONEncoder
        // randomizes keyed-container order per encode, so without this two
        // encodes of one unchanged store differ byte-wise and the digest
        // below dirties on every call — a guard that never fires.
        encoder.outputFormatting = [.sortedKeys]

        var collections: [(key: String, data: Data)] = [
            ("events", try encoder.encode(eventStore.events)),
            ("calendarEvents", try encoder.encode(eventStore.rawCalendarEvents)),
            ("logs", try encoder.encode(eventStore.calendarEventLogRecords)),
            ("feedback", try encoder.encode(eventStore.calendarEventFeedbackRecords)),
            ("todoLists", try encoder.encode(eventStore.todoLists)),
            ("eventTypes", try encoder.encode(eventTypeStore.templates)),
            ("skills", try encoder.encode(skillStore.insights)),
        ]
        if let preferenceStore {
            collections.append(("agentRules", try encoder.encode(preferenceStore.rules)))
            collections.append(("agentDecisionHistory", try encoder.encode(preferenceStore.decisionHistory)))
        }

        let settings = SyncedSettings.currentSnapshot(settingsDefaults)
        let settingsCanonical = try JSONSerialization.data(
            withJSONObject: settings, options: [.sortedKeys])

        // Agent conversations: canonical sorted-key bytes from the durable
        // repository. An unreadable file is caught by the frozen gate in
        // `writeSnapshotSync` before this is called at all.
        let conversationsRaw = AgentConversationRepository.shared.encodedJSONForSync() ?? Data()

        return SnapshotComponents(
            collections: collections,
            settings: settings,
            settingsCanonical: settingsCanonical,
            conversationsRaw: conversationsRaw,
            avatarData: MeAvatarStore.loadData()
        )
    }

    /// The steady-state dirty check: SHA256 over every component's bytes,
    /// label-and-length framed so no concatenation of two components can
    /// imitate another. `createdAt` is deliberately absent — it is not a
    /// component, it is a stamp added at write time, and hashing it would
    /// mean no two builds ever compare equal (the `rowHashIgnoredKeys`
    /// lesson).
    private static func componentsDigest(_ c: SnapshotComponents) -> Data {
        var hasher = SHA256()
        func absorb(_ label: String, _ data: Data) {
            hasher.update(data: Data(label.utf8))
            withUnsafeBytes(of: UInt64(data.count).littleEndian) {
                hasher.update(bufferPointer: $0)
            }
            hasher.update(data: data)
        }
        absorb("version", Data("\(snapshotVersion)".utf8))
        for (key, data) in c.collections { absorb(key, data) }
        absorb("settings", c.settingsCanonical)
        absorb("agentConversations", c.conversationsRaw)
        if let avatar = c.avatarData { absorb("avatarJPEGBase64", avatar) }
        return Data(hasher.finalize())
    }

    /// Stage 2: the JSON-native document, WITHOUT `createdAt` — the caller
    /// stamps that at write time, after the dirty check has already decided.
    /// Built from the stage-1 bytes so nothing is encoded twice. The dict is
    /// both human-readable and tolerant of the heterogeneous data we carry
    /// (typed models + an untyped settings blob).
    private func assemblePayload(from c: SnapshotComponents) throws -> [String: Any] {
        var dict: [String: Any] = [
            "version": Self.snapshotVersion,
            "settings": c.settings,
        ]
        for (key, data) in c.collections {
            dict[key] = (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
        }
        // Decoded back to JSON-native so the dict round-trips through
        // JSONSerialization cleanly. The `[]` fallback is for an encode
        // failure only — an unreadable file is caught by the frozen gate.
        dict["agentConversations"] = c.conversationsRaw.isEmpty
            ? [Any]()
            : ((try? JSONSerialization.jsonObject(with: c.conversationsRaw)) ?? [Any]())
        // Avatar bytes: base64 so the snapshot stays a single JSON file.
        // ~100 KB compressed JPEG → ~133 KB base64 — tolerable for a JSON
        // payload; the alternative (sibling file) would complicate the
        // "one file = one restore" property the snapshot has today.
        if let avatar = c.avatarData {
            dict["avatarJPEGBase64"] = avatar.base64EncodedString()
        }
        return dict
    }

    /// The launch-seed digest space: an assembled payload minus `createdAt`,
    /// serialized with sorted keys. Both sides of the seed comparison — the
    /// freshly assembled dict and the parsed disk file — pass through this
    /// same function, so formatting quirks of either producer cancel out.
    private static func canonicalDigest(ofPayload payload: [String: Any]) -> Data? {
        var stripped = payload
        stripped.removeValue(forKey: "createdAt")
        guard let data = try? JSONSerialization.data(
            withJSONObject: stripped, options: [.sortedKeys]) else { return nil }
        return Data(SHA256.hash(data: data))
    }

    /// `nil` on any trouble — missing file, unparseable JSON — which the
    /// caller treats as "disk holds nothing current": the write proceeds and
    /// heals the file. Re-deriving from the snapshot itself instead of
    /// persisting a marker means there is nothing to desync (the gh#142 rule).
    private func canonicalDigestOfDiskSnapshot() -> Data? {
        guard let url = try? resolvedSnapshotURL(),
              let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return Self.canonicalDigest(ofPayload: dict)
    }

    /// `Data.write(options: .atomic)` is implemented by Foundation as
    /// write-to-temp-then-rename, so readers never see a partial file —
    /// important if a future foreground reader is added.
    private func writeAtomically(_ data: Data) throws {
        let url = try resolvedSnapshotURL()
        try data.write(to: url, options: [.atomic])
        snapshotWritesPerformed += 1
    }

    private func resolvedSnapshotURL() throws -> URL {
        if let snapshotFileURLOverride { return snapshotFileURLOverride }
        return try Self.snapshotURL()
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
