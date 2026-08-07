//
//  AgentConversationRepository.swift
//  Done
//
//  The durable, process-wide owner of the agent chat history.
//
//  WHY THIS EXISTS
//  ---------------
//  `AgentService.saveConversations()` JSON-encoded the whole array and handed
//  it to `UserDefaults`. `defaults.set` returning means the bytes reached
//  cfprefsd, not the disk — the flush is that daemon's own batched business —
//  so the reported sequence "finish a round with the agent, swipe the app
//  away, reopen" could legitimately come back without the round. On the
//  dogfood device that blob is 351 KB across 9 conversations of real
//  back-and-forth: not reconstructible, not derived, not re-fetchable.
//
//  The encode failure was swallowed outright ("// silently fail"), so a save
//  that never happened looked exactly like one that did.
//
//  WHY A SINGLETON, AND WHY THE CONSUMERS TALK TO IT
//  -------------------------------------------------
//  Three consumers bypassed `AgentService` entirely and read the raw blob:
//  the sync row builder, the local DR snapshot, and the restore writer. That
//  worked only because `UserDefaults` is one shared mutable dictionary. A file
//  has no such property — N readers over one path agree until one of them
//  writes — so exactly one object owns the file and the consumers ask IT.
//
//  THE SIGNAL, WHICH IS THE EASY HALF TO FORGET
//  --------------------------------------------
//  Cloud sync woke on `UserDefaults.didChangeNotification`: any write to any
//  key, 5 s debounce, then `syncAgentConversations()`. A file-backed store
//  posts no such notification, so moving the bytes without moving the signal
//  leaves local persistence correct and cloud backup silently frozen at
//  whatever it last saw. `didChangeNotification` here is the explicit
//  replacement, posted on real commits only — which is also strictly better
//  than what it replaces, because the old trigger fired on every unrelated
//  preference write and left `syncAgentConversations` to hash its way back to
//  "nothing changed".
//
//  WHERE THE FILE LIVES
//  --------------------
//  `Application Support/AgentChat/`, deliberately NOT under `EventStore/`:
//  `DurableEventStorage.sweepUnknownEntries()` deletes anything off its
//  whitelist in that directory, so a `conversations.json` next to the slots
//  would be swept on the next launch.
//
//  AND THE USER HAS TO BE TOLD
//  ---------------------------
//  A freeze protects the cloud copy and the file on disk; it does nothing for
//  the person typing. While it stands the chat list renders EMPTY, a new round
//  is accepted by the UI, refused by `replaceAll`, and gone on the next launch
//  — indefinitely, because only a user-initiated restore clears the fault and
//  nothing else would prompt one. That is the swallowed `catch` again, moved
//  from an empty error handler to a flag nobody reads. So `isDegraded` is
//  `@Published` and the persistence-degraded banner watches it, exactly as it
//  watches `EventStore.persistenceDegraded` and
//  `EventTypeTemplateStore.isCatalogDegraded`.
//

import Combine
import Foundation
import os

private let conversationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

@MainActor
final class AgentConversationRepository: ObservableObject {
    static let productionDirectoryName = "AgentChat"
    static let testHostDirectoryName = "AgentChat-TestHost"
    static let conversationsFilename = "conversations.json"

    /// The pre-conversations encoding: a flat `[ChatMessage]` transcript.
    /// Still a migration source, and — unlike before — no longer deleted when
    /// it is consumed. See `legacyValue`.
    static let legacyMessagesKey = "agentChatMessages"

    /// Posted after a commit that actually changed the file (or after one that
    /// failed, where memory has moved and the cloud is the copy worth having).
    ///
    /// This is the load-bearing replacement for `UserDefaults.didChangeNotification`
    /// in `SupabaseSyncService.attach`. Without it the conversations would
    /// persist locally and stop being backed up, which is the failure mode that
    /// looks fine right up until the device is gone.
    static let didChangeNotification = Notification.Name("agentConversationsRepositoryDidChange")

    /// The real repository. Cut off from legacy migration under XCTest for the
    /// same reason `EventStorageLocation.production` is redirected: `DoneTests`
    /// is a host-app bundle, so an un-redirected path would have every test
    /// read and write the dogfood user's own chat history.
    static let shared = AgentConversationRepository(
        directory: productionDirectory(),
        legacyDefaults: EventStorageLocation.isRunningUnderXCTest ? nil : .standard
    )

    /// Last known good. While `isFrozen` this is deliberately NOT the array the
    /// UI is showing — see `replaceAll`.
    private(set) var conversations: [AgentConversation] = []

    /// Exposed because a caller reasoning about this store (diagnostics, and
    /// the tests that stage a damaged file) should not have to re-derive it
    /// from the app-support path rules.
    let directory: URL

    private let file: AtomicValueFile<[AgentConversation]>
    private let legacyDefaults: UserDefaults?
    private var writeFailed = false

    /// The file could not be READ. Every export path must consult this: an
    /// unreadable file presents as an empty array, and `agent_conversations`
    /// is a single row upserted whole, so uploading that emptiness overwrites
    /// the last surviving copy of a 351 KB transcript with `[]`.
    var isFrozen: Bool { file.fault != nil }

    /// Frozen, or a write did not land. Either way this store is not a
    /// faithful copy of what the user sees, and the user is the one who needs
    /// to know: see the header. THE consumer is `StorageFaultBanner`.
    ///
    /// Stored and published rather than computed, because `AtomicValueFile.fault`
    /// and `writeFailed` are plain properties — a SwiftUI view observing this
    /// object would never be told that a mid-session write started failing.
    /// Refreshed at every point that can move either input.
    @Published private(set) var isDegraded = false

    init(directory: URL, legacyDefaults: UserDefaults?) {
        self.directory = directory
        self.file = AtomicValueFile(directory: directory, filename: Self.conversationsFilename)
        self.legacyDefaults = legacyDefaults
        load()
    }

    private func refreshDegraded() {
        let degraded = isFrozen || writeFailed
        if isDegraded != degraded { isDegraded = degraded }
    }

    // MARK: - Load

    private func load() {
        switch file.read(legacy: { [legacyDefaults] in Self.legacyValue(legacyDefaults) }) {
        case .loaded(let rows, let provenance):
            conversations = Self.withoutLoadingMessages(rows)
            trail("agentchat: loaded \(conversations.count) conversation(s) from \(provenance.rawValue)")
        case .fresh:
            conversations = []
        case .unreadable(let fault):
            // `[]` in memory, but `isFrozen` is now true and every export path
            // checks it. The distinction is the whole point: "the user has no
            // chat history" and "we could not read the user's chat history"
            // are the same array and opposite instructions.
            conversations = []
            trailError("agentchat: conversations UNREADABLE (\(fault)); uploads and snapshots suppressed until a restore")
        }
        refreshDegraded()
    }

    /// The `UserDefaults` funnel, in the precedence `AgentService.loadConversations`
    /// used: the conversations key wins outright if it is there at all, and the
    /// flat transcript is consulted only when it is absent.
    ///
    /// That precedence is not cosmetic. Reaching the older key whenever the
    /// newer one merely decodes EMPTY would make an undecodable `agentChatMessages`
    /// — dead data for years, never cleaned up because the old migration only
    /// deleted it on success — freeze a user whose real state is "no
    /// conversations".
    ///
    /// Undecodable bytes under the key that IS in force are a different matter
    /// and return `.damaged`: today that blob maps to `[]` in
    /// `agentConversationsToRow()` and is uploaded over the cloud's copy. That
    /// is the loss amplifier, and `.damaged` is what closes it.
    private static func legacyValue(
        _ defaults: UserDefaults?
    ) -> AtomicValueFile<[AgentConversation]>.LegacyValue {
        guard let defaults else { return .absent }

        if let data = defaults.data(forKey: AgentConversationsStorageKey) {
            guard let decoded = try? JSONDecoder().decode([AgentConversation].self, from: data) else {
                return .damaged(detail: "agentConversations: not [AgentConversation]", raw: data)
            }
            let cleaned = withoutLoadingMessages(decoded)
            // Empty is not content. Returning `.absent` lets the store stay
            // `.fresh` — nothing is written, the legacy key is untouched, and
            // the first real chat commits the file.
            return cleaned.isEmpty ? .absent : .present(cleaned)
        }

        if let data = defaults.data(forKey: legacyMessagesKey) {
            guard let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
                return .damaged(detail: "agentChatMessages: not [ChatMessage]", raw: data)
            }
            let messages = decoded.filter { !$0.isLoading }
            return messages.isEmpty ? .absent : .present([AgentConversation(messages: messages)])
        }

        return .absent
    }

    /// A loading placeholder is a UI state mid-request, not content;
    /// `syncMessagesToConversation` filters it out before saving, so one on
    /// disk means the process died with a request in flight. Stripped in
    /// memory only — a launch is not a reason to write.
    private static func withoutLoadingMessages(_ rows: [AgentConversation]) -> [AgentConversation] {
        rows.map { conversation in
            guard conversation.messages.contains(where: { $0.isLoading }) else { return conversation }
            var copy = conversation
            copy.messages.removeAll { $0.isLoading }
            return copy
        }
    }

    // MARK: - Mutation

    /// The one write path. Refuses while frozen, so a caller can tell the
    /// difference between "saved" and "looked like it saved" — which is the
    /// difference the swallowed `catch` used to erase.
    ///
    /// A refusal deliberately leaves `conversations` at last-known-good rather
    /// than accepting the caller's array: while the file is unreadable this
    /// object is the thing the exporters read, and letting it hold an array we
    /// never managed to persist is how the emptiness gets mirrored.
    @discardableResult
    func replaceAll(_ rows: [AgentConversation]) -> Bool {
        guard !isFrozen else {
            trailError("agentchat: conversation write REFUSED (file frozen: \(String(describing: file.fault)))")
            return false
        }

        conversations = rows
        var landed = true
        // A skipped commit means the bytes on disk already say this. Nothing
        // changed, so nothing needs uploading — and posting anyway would put
        // back exactly the wake-on-every-write noise this replaced.
        var changed = false
        do {
            changed = try file.commit(rows) > 0
            writeFailed = false
        } catch {
            landed = false
            writeFailed = true
            // NOT swallowed. The old `catch {}` meant a full disk, an
            // unwritable container or an encoder failure all presented to the
            // user as a successful save.
            trailError("agentchat: conversation write FAILED, previous file intact: \(String(describing: error))")
            // Memory has moved and the disk has not, so the cloud is now the
            // copy worth having. Wake the sink.
            changed = true
        }
        refreshDegraded()
        if changed { postDidChange() }
        return landed
    }

    /// Canonical bytes for the row/snapshot builders.
    ///
    /// Sorted keys for the same reason `AtomicValueFile`'s encoder uses them:
    /// two encodes of one value must not differ byte-wise, or every hash built
    /// on top of this churns. Returns nil only if the array cannot be encoded
    /// at all — which callers must treat as "do not upload", never as `[]`.
    func encodedJSONForSync() -> Data? {
        do {
            return try Self.syncEncoder.encode(conversations)
        } catch {
            trailError("agentchat: conversations could not be encoded for sync: \(String(describing: error))")
            return nil
        }
    }

    /// Apply a restored blob. USER-CONFIRMED PATH ONLY.
    ///
    /// Clearing the fault is the point: a restore is the one moment someone has
    /// looked at the cloud copy and said "use that", which is the only evidence
    /// that can outrank an unreadable local file. Nothing automatic may do
    /// this — a frozen store reads as `[]`, and an automatic unfreeze would let
    /// the next ordinary save write that emptiness down.
    ///
    /// Throws rather than absorbing a bad blob: decoding here is what stops a
    /// shape the cloud should not have sent from landing as the local truth.
    func applyRestore(blobData: Data) throws {
        let rows = Self.withoutLoadingMessages(
            try JSONDecoder().decode([AgentConversation].self, from: blobData)
        )
        clearFault()
        conversations = rows
        do {
            try file.commit(rows, intent: .destructive)
            writeFailed = false
            trail("agentchat: RESTORED \(rows.count) conversation(s)")
        } catch {
            // In memory the restore has landed and the user can see it; on disk
            // it has not. Same posture as `replaceAll`: say so, keep the value.
            writeFailed = true
            trailError("agentchat: restored conversations could not be written: \(String(describing: error))")
        }
        refreshDegraded()
        postDidChange()
    }

    /// "Reset all local data".
    ///
    /// The empty array is COMMITTED, not merely served. `wipe()` leaves a
    /// witness behind (deliberately — it is what stops the next launch reading
    /// an emptied directory as a first run and re-migrating the legacy blob),
    /// and a witness with no file is `.lostAfterCommit` — a freeze. Writing the
    /// `[]` the user asked for is what makes the post-reset state a state
    /// rather than a fault.
    func wipe() {
        file.wipe()
        writeFailed = false
        conversations = []
        do {
            try file.commit([], intent: .destructive)
        } catch {
            writeFailed = true
            trailError("agentchat: wipe could not commit the empty state: \(String(describing: error))")
        }
        refreshDegraded()
        postDidChange()
    }

    /// Unfreeze. Only from a user-confirmed restore or a wipe — see
    /// `applyRestore`.
    func clearFault() {
        file.clearFault()
        writeFailed = false
        refreshDegraded()
    }

    // MARK: - Plumbing

    private func postDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func trail(_ message: String) {
        conversationLogger.log("\(message, privacy: .public)")
        DiagnosticTrail.record("Persistence", message)
    }

    private func trailError(_ message: String) {
        conversationLogger.error("\(message, privacy: .public)")
        DiagnosticTrail.record("Persistence", "ERROR " + message)
    }

    private static let syncEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func productionDirectory() -> URL {
        let name = EventStorageLocation.isRunningUnderXCTest
            ? testHostDirectoryName
            : productionDirectoryName
        guard let base = try? EventStorageLocation.applicationSupport() else {
            // Unresolvable base: hand the file a path that cannot be created so
            // it raises `directoryUnavailable` and freezes, rather than quietly
            // writing somewhere purgeable.
            return URL(fileURLWithPath: "/dev/null").appendingPathComponent(name, isDirectory: true)
        }
        return base.appendingPathComponent(name, isDirectory: true)
    }
}
