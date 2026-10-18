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
//    cursor              `{"cursor": n, "gen": {table: g}}` under
//                        `syncHashes.<uid>.cursor` (a bare integer from
//                        before the generation check still reads)
//
//  `hash` is always the hash of the row AS THIS DEVICE SENT IT (or holds it);
//  `seq` is always the server's number from a response body or the feed. A
//  missing seq means "server version unknown": the row goes out as an
//  ignore-duplicates POST and gets its seq from the response or the echo.
//  The literal hash `?` means "a write of this row was sent and its result
//  is unknown" (survey S4): it equals no row hash, so the row stays dirty
//  until a response, the echo or the pending-verify pull settles it.
//
//  Generations (survey S11): each table's value also carries the generation
//  it was last written in, and the cursor records the generation it expects
//  of every table. See `SyncCursorStore` for why; generation 0 is written as
//  the pre-generation shape, so nothing changes on disk until a cursor
//  commit first advances one.
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
    nonisolated static func matchKey(_ id: String) -> String {
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

    /// The hash of a row whose last write was sent and whose result is
    /// unknown (survey S4). Not hex, so no row hash ever equals it.
    nonisolated static let unknownHash = "?"

    init(hash: String, seq: Int64?) {
        self.hash = hash
        self.seq = seq
    }

    /// The marker entry: the row is owed a re-verification, its seq is
    /// whatever was known before the write.
    static func unknown(seq: Int64?) -> SyncBaselineEntry {
        SyncBaselineEntry(hash: unknownHash, seq: seq)
    }

    var isUnknown: Bool { hash == Self.unknownHash }

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

    /// Every table label that has a baseline value, in one list: the
    /// generation check walks all of them.
    nonisolated static var allTables: [String] {
        perRowTables + scalarTables.sorted() + [settingsTable]
    }

    let defaults: UserDefaults
    let userId: String

    private var rows: [String: [String: SyncBaselineEntry]] = [:]
    private var scalars: [String: SyncBaselineEntry] = [:]
    private(set) var settings: SyncSettingsBaseline?
    private var generations: [String: Int64] = [:]
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

    // MARK: Generations (survey S11)

    /// The generation `table`'s value was last written in; 0 when it never
    /// carried one.
    func generation(of table: String) -> Int64 {
        generations[table] ?? 0
    }

    /// Every table's generation, zeros omitted — what a cursor commit
    /// records as its expectation.
    var generationMap: [String: Int64] {
        generations.filter { $0.value != 0 }
    }

    /// The first step of a cursor commit: each table the committed batch
    /// touched moves to a new generation and is marked for the next
    /// `persist()`, so its value is rewritten carrying it.
    func advanceGeneration(tables: some Sequence<String>) {
        for table in tables {
            generations[table] = generation(of: table) + 1
            dirtyTables.insert(table)
        }
    }

    // MARK: Persistence

    /// The per-row value once a generation is on it: the rows map wrapped
    /// with the generation. Generation 0 keeps the bare map, which is what
    /// every build before the generation check wrote and reads.
    private struct GenerationalRows: Codable {
        let gen: Int64
        let rows: [String: String]
    }

    /// The scalar / settings value's generation rides as a `#<gen>` suffix.
    /// A hash is hex or `?`, a seq is digits, the settings JSON ends in `}`,
    /// so a trailing `#` followed only by digits is never part of the value.
    nonisolated static func splitGeneration(_ text: String) -> (value: String, gen: Int64) {
        guard let hash = text.lastIndex(of: "#"),
              let gen = Int64(text[text.index(after: hash)...]), gen >= 0
        else { return (text, 0) }
        return (String(text[..<hash]), gen)
    }

    nonisolated static func appendingGeneration(_ value: String, _ gen: Int64) -> String {
        gen == 0 ? value : "\(value)#\(gen)"
    }

    private func load() {
        guard !userId.isEmpty else { return }
        for table in Self.perRowTables {
            guard let data = defaults.data(forKey: Self.key(userId: userId, table: table)) else { continue }
            let map: [String: String]
            if let bare = try? JSONDecoder().decode([String: String].self, from: data) {
                map = bare
            } else if let wrapped = try? JSONDecoder().decode(GenerationalRows.self, from: data) {
                map = wrapped.rows
                generations[table] = wrapped.gen
            } else {
                continue
            }
            var decoded: [String: SyncBaselineEntry] = [:]
            for (id, encoded) in map {
                if let entry = SyncBaselineEntry(encoded: encoded) { decoded[id] = entry }
            }
            rows[table] = decoded
        }
        for table in Self.scalarTables {
            if let stored = defaults.string(forKey: Self.key(userId: userId, table: table)) {
                let (encoded, gen) = Self.splitGeneration(stored)
                scalars[table] = SyncBaselineEntry(encoded: encoded)
                if gen != 0 { generations[table] = gen }
            }
        }
        if let stored = defaults.string(forKey: Self.key(userId: userId, table: Self.settingsTable)) {
            let (encoded, gen) = Self.splitGeneration(stored)
            settings = SyncSettingsBaseline(encoded: encoded)
            if gen != 0 { generations[Self.settingsTable] = gen }
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
        let gen = generation(of: table)
        if table == Self.settingsTable || Self.scalarTables.contains(table) {
            let encoded = table == Self.settingsTable ? settings?.encoded : scalars[table]?.encoded
            if let encoded {
                defaults.set(Self.appendingGeneration(encoded, gen), forKey: key)
            } else if gen != 0 {
                // An empty value still carries its generation, or the check
                // would read a cleared table as a lost write.
                defaults.set(Self.appendingGeneration("", gen), forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        } else {
            let map = (rows[table] ?? [:]).mapValues { $0.encoded }
            let data: Data?
            if gen == 0 {
                data = try? JSONEncoder().encode(map)
            } else {
                data = try? JSONEncoder().encode(GenerationalRows(gen: gen, rows: map))
            }
            guard let data else { return }
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
///
/// **Why the cursor carries generations (survey S11, gap G22).** The cursor
/// and the baseline tables are separate `UserDefaults` keys. A single key's
/// value is written whole, but nothing orders the writes of DIFFERENT keys
/// against each other once they leave the process: a power loss, a kernel
/// panic or a `cfprefsd` crash can keep a later key and lose an earlier one.
/// "New cursor, old baseline" is the state that loses data — the applier
/// took c2@s1 into the slot, its baseline (h2, s1) is gone but the cursor
/// past s1 survived, so the next local edit goes out on the old seq, comes
/// back `[]`, is never seen by a pull, and reads as identical: it never
/// uploads. That ordering cannot be measured from inside the app (`kill -9`
/// leaves `cfprefsd` holding every write already handed to it), so it is
/// ruled out by construction instead: `commit` first moves every table the
/// batch touched to a new generation and persists it, then writes the
/// cursor together with the generation it expects of every table, in the
/// cursor's own value. `validate` runs at load; any table whose generation
/// is not the one the cursor expects means some write did not land, and the
/// cursor is dropped — a full pull, which the three-way compare makes safe.
/// No assumption about the order keys reach disk is needed.
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

    private struct Stored: Codable {
        let cursor: Int64
        let gen: [String: Int64]
    }

    /// The stored value: the S11 JSON shape, or the bare integer an earlier
    /// build wrote (no generation expected of any table).
    private var stored: Stored? {
        guard !userId.isEmpty, let raw = defaults.object(forKey: key) else { return nil }
        if let number = raw as? NSNumber { return Stored(cursor: number.int64Value, gen: [:]) }
        guard let text = raw as? String,
              let decoded = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8))
        else { return nil }
        return decoded
    }

    private func write(_ value: Stored?) {
        guard !userId.isEmpty else { return }
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(text, forKey: key)
    }

    /// The cursor. Setting it moves only the seq and keeps the generations
    /// the stored value already expects; the puller's path is `commit`.
    var value: Int64? {
        get { stored?.cursor }
        set {
            guard let newValue else { write(nil); return }
            write(Stored(cursor: newValue, gen: stored?.gen ?? [:]))
        }
    }

    /// The generation the stored cursor expects of each table (absent = 0).
    var expectedGenerations: [String: Int64] { stored?.gen ?? [:] }

    /// One applied batch: the touched tables' baselines move to a new
    /// generation and are persisted FIRST, then the cursor is written with
    /// `max(old, seq)` (I9) and every table's generation as its
    /// expectation. Same main-actor tick, no suspension in between.
    func commit(seq: Int64, baseline: SyncBaselineStore, touched: Set<String>) {
        guard !userId.isEmpty else { return }
        baseline.advanceGeneration(tables: touched)
        baseline.persist()
        let next = max(stored?.cursor ?? seq, seq)
        write(Stored(cursor: next, gen: baseline.generationMap))
    }

    /// The tables whose baseline generation is not the one the cursor
    /// expects. Empty when there is no cursor.
    func mismatchedTables(_ baseline: SyncBaselineStore) -> [String] {
        guard let stored else { return [] }
        return SyncBaselineStore.allTables.filter { baseline.generation(of: $0) != (stored.gen[$0] ?? 0) }
    }

    /// Load-time check: drop the cursor when any generation disagrees.
    /// Returns the tables that disagreed (empty = cursor kept).
    @discardableResult
    func validate(against baseline: SyncBaselineStore) -> [String] {
        let mismatched = mismatchedTables(baseline)
        if !mismatched.isEmpty { clear() }
        return mismatched
    }

    func clear() { value = nil }
}
