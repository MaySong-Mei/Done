//
//  SyncBaseline.swift
//  Done
//
//  The (hash, seq) baseline and the pull cursor — design §6.3 of
//  Docs/sync/00-realtime-sync-design.md. Both live in UserDefaults under the
//  existing `syncHashes.<uid>.<table>` prefix, so the erase's prefix sweep
//  (`SupabaseSyncService.wipeAllPersistedHashes`) covers them for free and a
//  pre-Phase-1 build's `<hash>` values keep decoding.
//
//  Value shapes:
//    per-row tables      `[rowId: "<hash>" | "<hash>@<seq>"]` as JSON Data
//    agent_preferences / agent_conversations
//                        `"<hash>" | "<hash>@<seq>"` as a String
//    user_settings       `"<hash>"` (legacy) or JSON
//                        `{"seq": n, "keys": {key: hash}, "zone": "<id>"}`
//    cursor              an integer under `syncHashes.<uid>.cursor`
//
//  `hash` is always the hash of the row AS THIS DEVICE SENT IT (or holds it);
//  `seq` is always the server's number from a response body or the feed. A
//  missing seq means "server version unknown": the row goes out as an
//  ignore-duplicates POST and gets its seq from the response or the echo.
//
//  Mutations are in memory; `persist()` writes the tables touched since the
//  last persist. The outbound flush persists once per table, the applier
//  persists right after each slot commit (I3). A crash in between only
//  costs a re-sent row, which the server's no-op short circuit absorbs.
//

import Foundation

/// `(table, id)` — the identity the baseline, the pending-verify set and
/// the echo bookkeeping all key on. `table` is the BASELINE table label:
/// the server table for every table but calendar-kind events, which keep
/// their own label (`calendar_events`) because todo and calendar rows share
/// the `events` server table yet diff and delete as two separate sets.
struct SyncBaselineKey: Hashable {
    let table: String
    let id: String

    /// The form under which a row id compares equal to the server's
    /// rendering of it. PostgREST renders uuid columns lowercase while the
    /// device keys rows by `UUID.uuidString` (uppercase); the filters
    /// `id=eq.` / `id=in.()` match either case, but a response body has to
    /// be matched back to the row that was sent. Non-uuid ids (occurrence
    /// keys, log ids) are returned as sent. See
    /// SyncOutboundTests.testInsertResponseIdsComeBackLowercaseAndStillSetTheBaselineSeq.
    static func matchKey(_ id: String) -> String {
        UUID(uuidString: id) != nil ? id.lowercased() : id
    }

    /// The device-side spelling of an id the server rendered: uuids back
    /// to `UUID.uuidString`, everything else unchanged. The applier keys
    /// the baseline by this.
    static func localId(_ serverId: String) -> String {
        UUID(uuidString: serverId)?.uuidString ?? serverId
    }
}

struct SyncBaselineEntry: Equatable {
    var hash: String
    var seq: Int64?

    init(hash: String, seq: Int64?) {
        self.hash = hash
        self.seq = seq
    }

    /// `"<hash>"` (legacy, seq unknown) or `"<hash>@<seq>"`. A hash never
    /// contains `@` (hex), so the last `@` is the separator.
    init?(encoded: String) {
        guard !encoded.isEmpty else { return nil }
        guard let at = encoded.lastIndex(of: "@") else {
            self.init(hash: encoded, seq: nil)
            return
        }
        let hash = String(encoded[..<at])
        let seqText = encoded[encoded.index(after: at)...]
        guard !hash.isEmpty, let seq = Int64(seqText) else {
            // Malformed suffix: keep the hash, forget the seq. Re-POSTing is
            // the safe direction (ignore-duplicates cannot overwrite).
            self.init(hash: hash.isEmpty ? encoded : hash, seq: nil)
            return
        }
        self.init(hash: hash, seq: seq)
    }

    var encoded: String {
        guard let seq else { return hash }
        return "\(hash)@\(seq)"
    }
}

/// `user_settings` is merged per key (design §6 user_settings 段), so its
/// baseline is per-key hashes plus one row seq, not a row hash. `legacy` is
/// the pre-Phase-1 scalar; the upgrade rule needs the local row (and, for
/// two of its three branches, the remote row) and lives on the service.
enum SyncSettingsBaseline: Equatable {
    case legacy(rowHash: String)
    /// `zone` is the server's `occurrenceKeyReferenceTimeZoneIdentifier`
    /// when the applier has seen one; the pusher sends it instead of the
    /// local value (design §6.2 pusher rule).
    case versioned(seq: Int64?, keys: [String: String], zone: String?)

    init?(encoded: String) {
        guard !encoded.isEmpty else { return nil }
        guard encoded.hasPrefix("{") else {
            self = .legacy(rowHash: encoded)
            return
        }
        guard let data = encoded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let seq = (object["seq"] as? NSNumber)?.int64Value
        let keys = object["keys"] as? [String: String] ?? [:]
        let zone = object["zone"] as? String
        self = .versioned(seq: seq, keys: keys, zone: zone)
    }

    var encoded: String {
        switch self {
        case .legacy(let rowHash):
            return rowHash
        case .versioned(let seq, let keys, let zone):
            var object: [String: Any] = ["keys": keys]
            if let seq { object["seq"] = NSNumber(value: seq) }
            if let zone { object["zone"] = zone }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return "{}" }
            return text
        }
    }

    var seq: Int64? {
        if case .versioned(let seq, _, _) = self { return seq }
        return nil
    }

    var keys: [String: String] {
        if case .versioned(_, let keys, _) = self { return keys }
        return [:]
    }

    var zone: String? {
        if case .versioned(_, _, let zone) = self { return zone }
        return nil
    }
}

@MainActor
final class SyncBaselineStore {
    nonisolated static let keyPrefix = "syncHashes."
    nonisolated static let settingsTable = "user_settings"
    nonisolated static let scalarTables: Set<String> = ["agent_preferences", "agent_conversations"]
    nonisolated static let perRowTables: [String] = [
        "events", "calendar_events", "event_logs", "event_feedback",
        "todo_lists", "skill_insights", "event_types",
    ]

    nonisolated static func key(userId: String, table: String) -> String {
        "\(keyPrefix)\(userId).\(table)"
    }

    /// The baseline label for a feed row: `events` with `kind == "calendar"`
    /// is `calendar_events`; everything else is the server table.
    nonisolated static func table(forFeedTable table: String, kind: String?) -> String {
        if table == "events", kind == "calendar" { return "calendar_events" }
        return table
    }

    let defaults: UserDefaults
    let userId: String

    private var rows: [String: [String: SyncBaselineEntry]] = [:]
    private var scalars: [String: SyncBaselineEntry] = [:]
    private(set) var settings: SyncSettingsBaseline?
    private var dirtyTables: Set<String> = []

    /// Loads from `defaults` at once. An empty `userId` is a signed-out store:
    /// it holds nothing and persists nothing.
    init(defaults: UserDefaults, userId: String) {
        self.defaults = defaults
        self.userId = userId
        load()
    }

    // MARK: Per-row and scalar tables (one API; scalar tables ignore `id`)

    func entry(table: String, id: String) -> SyncBaselineEntry? {
        if Self.scalarTables.contains(table) { return scalars[table] }
        return rows[table]?[id]
    }

    func setEntry(_ entry: SyncBaselineEntry, table: String, id: String) {
        if Self.scalarTables.contains(table) {
            scalars[table] = entry
        } else {
            rows[table, default: [:]][id] = entry
        }
        dirtyTables.insert(table)
    }

    func removeEntry(table: String, id: String) {
        if Self.scalarTables.contains(table) {
            scalars[table] = nil
        } else {
            rows[table]?[id] = nil
        }
        dirtyTables.insert(table)
    }

    func removeEntries(table: String, ids: some Sequence<String>) {
        for id in ids { removeEntry(table: table, id: id) }
    }

    func entries(table: String) -> [String: SyncBaselineEntry] {
        if Self.scalarTables.contains(table) {
            guard let scalar = scalars[table] else { return [:] }
            return [userId: scalar]
        }
        return rows[table] ?? [:]
    }

    /// Whole-table replacement (`markRestoreCompleted`).
    func replaceEntries(table: String, with entries: [String: SyncBaselineEntry]) {
        if Self.scalarTables.contains(table) {
            scalars[table] = entries.values.first
        } else {
            rows[table] = entries
        }
        dirtyTables.insert(table)
    }

    // MARK: user_settings

    func setSettings(_ value: SyncSettingsBaseline?) {
        settings = value
        dirtyTables.insert(Self.settingsTable)
    }

    // MARK: Persistence

    private func load() {
        guard !userId.isEmpty else { return }
        for table in Self.perRowTables {
            guard let data = defaults.data(forKey: Self.key(userId: userId, table: table)),
                  let map = try? JSONDecoder().decode([String: String].self, from: data)
            else { continue }
            var decoded: [String: SyncBaselineEntry] = [:]
            for (id, encoded) in map {
                if let entry = SyncBaselineEntry(encoded: encoded) { decoded[id] = entry }
            }
            rows[table] = decoded
        }
        for table in Self.scalarTables {
            if let encoded = defaults.string(forKey: Self.key(userId: userId, table: table)) {
                scalars[table] = SyncBaselineEntry(encoded: encoded)
            }
        }
        if let encoded = defaults.string(forKey: Self.key(userId: userId, table: Self.settingsTable)) {
            settings = SyncSettingsBaseline(encoded: encoded)
        }
        dirtyTables = []
    }

    /// Write every table mutated since the last persist. No-op when signed
    /// out: a baseline that cannot be scoped to a user is never written.
    func persist() {
        guard !userId.isEmpty else { dirtyTables = []; return }
        for table in dirtyTables { write(table: table) }
        dirtyTables = []
    }

    func persistAll() {
        guard !userId.isEmpty else { dirtyTables = []; return }
        for table in Self.perRowTables { write(table: table) }
        for table in Self.scalarTables { write(table: table) }
        write(table: Self.settingsTable)
        dirtyTables = []
    }

    private func write(table: String) {
        let key = Self.key(userId: userId, table: table)
        if table == Self.settingsTable {
            if let settings {
                defaults.set(settings.encoded, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        } else if Self.scalarTables.contains(table) {
            if let scalar = scalars[table] {
                defaults.set(scalar.encoded, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        } else {
            let map = (rows[table] ?? [:]).mapValues { $0.encoded }
            guard let data = try? JSONEncoder().encode(map) else { return }
            defaults.set(data, forKey: key)
        }
    }

    /// Prefix sweep over every user this device ever signed in as (the
    /// erase). Covers the cursor too, which shares the prefix.
    nonisolated static func wipeAll(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The one pull cursor per user: the highest `seq` of the last page that was
/// fully applied. Missing means "pull everything first" (I1). Written
/// immediately — a cursor is the last step of a committed page and must not
/// outlive the process unwritten (I3).
@MainActor
final class SyncCursorStore {
    nonisolated static let tableLabel = "cursor"

    let defaults: UserDefaults
    let userId: String

    init(defaults: UserDefaults, userId: String) {
        self.defaults = defaults
        self.userId = userId
    }

    private var key: String { SyncBaselineStore.key(userId: userId, table: Self.tableLabel) }

    var value: Int64? {
        get {
            guard !userId.isEmpty else { return nil }
            return (defaults.object(forKey: key) as? NSNumber)?.int64Value
        }
        set {
            guard !userId.isEmpty else { return }
            if let newValue {
                defaults.set(NSNumber(value: newValue), forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    func clear() { value = nil }
}
