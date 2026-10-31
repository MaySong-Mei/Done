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
//  is unknown" (survey S4): the flush writes it when it builds the request,
//  before the request leaves. It equals no row hash, so the row stays dirty
//  until a response, the echo or the pending-verify pull settles it — each
//  of those writing only while the entry is still the `?` that send wrote.
//
//  Generations (survey S11): each table's value also carries the generation
//  it was last written in, and the cursor records the generation it expects
//  of every table. See `SyncCursorStore` for why; generation 0 is written as
//  the pre-generation shape, so nothing changes on disk until a cursor
//  commit first advances one.
//
//  Mutations are in memory; `persist()` writes the tables touched since the
//  last persist. The outbound flush persists each table it sends from once
//  with the `?` markers, before any request leaves, and once with the
//  outcomes; the applier persists right after each slot commit (I3). A
//  crash in between only costs a re-sent row, which the server's no-op
//  short circuit absorbs.
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
    /// The server's `version_id` of the version this entry names (design
    /// §6.6 版本谱系, v1.6). Nil for an entry written before the server
    /// handed out version ids, or from a response that carried none.
    var vid: String?
    /// The catch-up marker (design §6.6 设备追平, the `~` prefix): the
    /// server went backwards and this entry has not been reconciled with
    /// the new timeline. While set, the §6.6 pre-rules decide the row and
    /// the §6 skip row never fires on it.
    var stale: Bool

    /// The hash of a row whose last write was sent and whose result is
    /// unknown (survey S4). Not hex, so no row hash ever equals it.
    nonisolated static let unknownHash = "?"

    init(hash: String, seq: Int64?, vid: String? = nil, stale: Bool = false) {
        self.hash = hash
        self.seq = seq
        self.vid = vid
        self.stale = stale
    }

    /// Equality is the three values the §6 rules read: hash, seq and the
    /// catch-up marker. The version id rides along but does not compare,
    /// so a baseline assertion written against `(hash, seq)` holds whether
    /// or not the server reported a version id. Tests that pin a version id
    /// read `vid` directly.
    static func == (lhs: SyncBaselineEntry, rhs: SyncBaselineEntry) -> Bool {
        lhs.hash == rhs.hash && lhs.seq == rhs.seq && lhs.stale == rhs.stale
    }

    /// The marker entry: the row is owed a re-verification, its seq is
    /// whatever was known before the write.
    static func unknown(seq: Int64?) -> SyncBaselineEntry {
        SyncBaselineEntry(hash: unknownHash, seq: seq)
    }

    var isUnknown: Bool { hash == Self.unknownHash }

    /// `"<hash>"` (legacy, seq unknown), `"<hash>@<seq>"`, and from v1.6
    /// `"<hash>@<seq>#<vid>"` with a leading `~` for a stale entry. A hash
    /// never contains `@`, `#` or `~` (hex, or `?`); a version id is a uuid
    /// and never all digits, so the generation suffix the scalar values
    /// carry (`#<digits>`, stripped before this runs) cannot be mistaken
    /// for one.
    init?(encoded: String) {
        guard !encoded.isEmpty else { return nil }
        var text = Substring(encoded)
        var stale = false
        if text.hasPrefix("~") {
            stale = true
            text = text.dropFirst()
            guard !text.isEmpty else { return nil }
        }
        var vid: String?
        if let hashMark = text.lastIndex(of: "#") {
            let candidate = text[text.index(after: hashMark)...]
            if !candidate.isEmpty, Int64(candidate) == nil {
                vid = String(candidate)
                text = text[..<hashMark]
            }
        }
        guard let at = text.lastIndex(of: "@") else {
            self.init(hash: String(text), seq: nil, vid: vid, stale: stale)
            return
        }
        let hash = String(text[..<at])
        let seqText = text[text.index(after: at)...]
        guard !hash.isEmpty, let seq = Int64(seqText) else {
            // Malformed suffix: keep the hash, forget the seq. Re-POSTing is
            // the safe direction (ignore-duplicates cannot overwrite).
            self.init(hash: hash.isEmpty ? String(text) : hash, seq: nil, vid: vid, stale: stale)
            return
        }
        self.init(hash: hash, seq: seq, vid: vid, stale: stale)
    }

    var encoded: String {
        var out = stale ? "~" : ""
        out += hash
        if let seq { out += "@\(seq)" }
        if let vid, !vid.isEmpty { out += "#\(vid)" }
        return out
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
    /// The server epoch each table's value was last written under (design
    /// §6.6 游标键带 epoch 与 kmin): a table whose epoch disagrees with the
    /// cursor's lost a reset write and is re-marked stale at load.
    private var epochs: [String: String] = [:]
    /// Per row, the version id the current local edit chain started from
    /// (design §6.6 来源快进, `origin`): written by the flush the first time
    /// a dirty row goes out, kept across conflicts and epoch changes, dropped
    /// when the row reads clean again. Scalar tables key it by the uid.
    private var origins: [String: [String: String]] = [:]
    /// The settings row's catch-up marker; the settings baseline is per key
    /// and has no entry to carry one.
    private(set) var settingsStale = false
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
        settingsStale = false
        dirtyTables.insert(Self.settingsTable)
    }

    func setSettingsStale(_ stale: Bool) {
        settingsStale = stale
        dirtyTables.insert(Self.settingsTable)
    }

    // MARK: Catch-up state (design §6.6)

    /// The version id the row's current edit chain started from, if the
    /// flush recorded one. Scalar tables ignore `id`.
    func origin(table: String, id: String) -> String? {
        if Self.scalarTables.contains(table) { return origins[table]?[userId] }
        return origins[table]?[id]
    }

    func setOrigin(_ vid: String, table: String, id: String) {
        let rowId = Self.scalarTables.contains(table) ? userId : id
        origins[table, default: [:]][rowId] = vid
        dirtyTables.insert(table)
    }

    func removeOrigin(table: String, id: String) {
        let rowId = Self.scalarTables.contains(table) ? userId : id
        guard origins[table]?[rowId] != nil else { return }
        origins[table]?[rowId] = nil
        dirtyTables.insert(table)
    }

    /// The epoch `table`'s value was last written under; nil before the
    /// device ever recorded one.
    func epoch(of table: String) -> String? {
        epochs[table]
    }

    func setEpoch(_ epoch: String, tables: some Sequence<String>) {
        for table in tables {
            epochs[table] = epoch
            dirtyTables.insert(table)
        }
    }

    /// The reset (design §6.6 设备追平): every entry of every table keeps
    /// its hash, seq and version id and gains the stale marker.
    func markAllStale() {
        for table in Self.perRowTables { markStale(table: table) }
        for table in Self.scalarTables { markStale(table: table) }
        markStale(table: Self.settingsTable)
    }

    func markStale(table: String) {
        if table == Self.settingsTable {
            if settings != nil { settingsStale = true }
        } else if Self.scalarTables.contains(table) {
            scalars[table]?.stale = true
        } else {
            rows[table] = (rows[table] ?? [:]).mapValues { entry in
                var copy = entry
                copy.stale = true
                return copy
            }
        }
        dirtyTables.insert(table)
    }

    /// The entries of `table` still carrying the stale marker — after a
    /// chain reached head, the rows the server no longer holds.
    func staleEntries(table: String) -> [String: SyncBaselineEntry] {
        entries(table: table).filter { $0.value.stale }
    }

    /// Whether any entry anywhere is still stale (a catch-up is in progress
    /// or was abandoned): the next reset takes `min` with the old kmin.
    var hasStaleEntries: Bool {
        if settingsStale { return true }
        if scalars.values.contains(where: \.stale) { return true }
        return rows.values.contains { $0.values.contains(where: \.stale) }
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
        /// v1.6: the per-row origin table and the table's epoch. Absent in
        /// values written before them; absent on disk while empty / nil.
        var origin: [String: String]?
        var epoch: String?
    }

    /// The scalar / settings value when it carries v1.6 state the `#<gen>`
    /// suffix cannot: `{"$v": <encoded>, "gen": n, "epoch": e, "origin": vid,
    /// "stale": bool}`. A value without any of that is written in the
    /// pre-v1.6 shape, so nothing on disk changes until a reset or an
    /// origin is recorded.
    private struct WrappedScalar: Codable {
        var v: String
        var gen: Int64
        var epoch: String?
        var origin: String?
        var stale: Bool?

        enum CodingKeys: String, CodingKey {
            case v = "$v", gen, epoch, origin, stale
        }
    }

    /// Written with sorted keys, so the wrapper always starts with `{"$v"`
    /// — which no settings JSON does (its keys sort `keys`, `seq`, `zone`).
    nonisolated private static func encodeWrapped(_ wrapped: WrappedScalar) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(wrapped) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func decodeWrapped(_ text: String) -> WrappedScalar? {
        guard text.hasPrefix("{\"$v\"") else { return nil }
        return try? JSONDecoder().decode(WrappedScalar.self, from: Data(text.utf8))
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
                if wrapped.gen != 0 { generations[table] = wrapped.gen }
                if let origin = wrapped.origin, !origin.isEmpty { origins[table] = origin }
                if let epoch = wrapped.epoch { epochs[table] = epoch }
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
                let (encoded, gen) = unwrapScalar(stored, table: table)
                scalars[table] = SyncBaselineEntry(encoded: encoded)
                if gen != 0 { generations[table] = gen }
            }
        }
        if let stored = defaults.string(forKey: Self.key(userId: userId, table: Self.settingsTable)) {
            let (encoded, gen) = unwrapScalar(stored, table: Self.settingsTable)
            settings = SyncSettingsBaseline(encoded: encoded)
            if gen != 0 { generations[Self.settingsTable] = gen }
        }
        dirtyTables = []
    }

    /// The encoded value and generation of a scalar / settings key, reading
    /// both the `#<gen>` suffix shape and the v1.6 wrapper, and taking the
    /// wrapper's epoch / origin / stale into the store.
    private func unwrapScalar(_ stored: String, table: String) -> (value: String, gen: Int64) {
        if let wrapped = Self.decodeWrapped(stored) {
            if let epoch = wrapped.epoch { epochs[table] = epoch }
            if let origin = wrapped.origin { origins[table] = [userId: origin] }
            if table == Self.settingsTable, wrapped.stale == true { settingsStale = true }
            return (wrapped.v, wrapped.gen)
        }
        return Self.splitGeneration(stored)
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
        let epoch = epochs[table]
        if table == Self.settingsTable || Self.scalarTables.contains(table) {
            let encoded = table == Self.settingsTable ? settings?.encoded : scalars[table]?.encoded
            let origin = Self.scalarTables.contains(table) ? origins[table]?[userId] : nil
            let stale = table == Self.settingsTable && settingsStale
            if epoch != nil || origin != nil || stale {
                let wrapped = WrappedScalar(v: encoded ?? "", gen: gen, epoch: epoch, origin: origin, stale: stale ? true : nil)
                if let text = Self.encodeWrapped(wrapped) {
                    defaults.set(text, forKey: key)
                }
                return
            }
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
            let origin = origins[table]?.isEmpty == false ? origins[table] : nil
            let data: Data?
            if gen == 0, origin == nil, epoch == nil {
                data = try? JSONEncoder().encode(map)
            } else {
                data = try? JSONEncoder().encode(GenerationalRows(gen: gen, rows: map, origin: origin, epoch: epoch))
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

    /// `{cursor, gen, epoch, kmin}` (design §6.3 游标 row, v1.6). `cursor`
    /// is nil after a reset: the epoch and kmin survive the dropped cursor
    /// in the same key, which is what lets the next page's epoch check
    /// compare against the epoch the reset recorded.
    private struct Stored: Codable {
        var cursor: Int64?
        var gen: [String: Int64]
        var epoch: String?
        var kmin: Int64?
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

    /// The cursor. Setting it moves only the seq and keeps the generations,
    /// epoch and kmin the stored value already carries; the puller's path
    /// is `commit`.
    var value: Int64? {
        get { stored?.cursor }
        set {
            var next = stored ?? Stored(cursor: nil, gen: [:])
            next.cursor = newValue
            if newValue == nil, next.epoch == nil, next.kmin == nil {
                write(nil)
            } else {
                write(next)
            }
        }
    }

    /// The generation the stored cursor expects of each table (absent = 0).
    var expectedGenerations: [String: Int64] { stored?.gen ?? [:] }

    /// The server epoch this device last reconciled with; nil before the
    /// first `sync_epoch` read (an upgrade's first pull records it and
    /// resets nothing, design §6.6).
    var epoch: String? { stored?.epoch }

    /// The restore ledger's minimum kept_max since the device's old epoch
    /// (design §6.6 恢复帐本); nil is ∞ — no restore recorded.
    var kmin: Int64? { stored?.kmin }

    /// First sighting of an epoch (an upgrade's first pull): recorded on
    /// the cursor key and on every table, nothing marked stale. From here
    /// on a table without the cursor's epoch is a table whose reset write
    /// was lost (`validate`).
    func recordEpoch(_ epoch: String, baseline: SyncBaselineStore) {
        guard !userId.isEmpty else { return }
        baseline.setEpoch(epoch, tables: SyncBaselineStore.allTables)
        baseline.persist()
        var next = stored ?? Stored(cursor: nil, gen: [:])
        next.epoch = epoch
        write(next)
    }

    /// One applied batch: the touched tables' baselines move to a new
    /// generation and are persisted FIRST, then the cursor is written with
    /// `max(old, seq)` (I9) and every table's generation as its
    /// expectation. Same main-actor tick, no suspension in between.
    func commit(seq: Int64, baseline: SyncBaselineStore, touched: Set<String>) {
        guard !userId.isEmpty else { return }
        baseline.advanceGeneration(tables: touched)
        baseline.persist()
        let current = stored
        let next = max(current?.cursor ?? seq, seq)
        write(Stored(cursor: next, gen: baseline.generationMap, epoch: current?.epoch, kmin: current?.kmin))
    }

    /// A cloud restore replayed into the baseline a snapshot read at or
    /// above `seq` (`RestoreFetchMark`): the cursor moves back to `seq` when
    /// it is past it, and never forward. Nil on either side means no cursor
    /// — the next pull starts from the beginning of the feed. Ordered like
    /// `commit`: every table moves to a new generation and the baseline is
    /// persisted FIRST, then the cursor is written expecting those
    /// generations, so losing either write to a crash drops the cursor at
    /// the next load (`validate`) instead of leaving a cursor past versions
    /// newer than the replayed baseline. The epoch and kmin stay.
    func rewind(to seq: Int64?, baseline: SyncBaselineStore) {
        guard !userId.isEmpty else { return }
        baseline.advanceGeneration(tables: SyncBaselineStore.allTables)
        baseline.persist()
        let current = stored
        let next: Int64? = {
            guard let seq, let old = current?.cursor else { return nil }
            return min(old, seq)
        }()
        write(Stored(cursor: next, gen: baseline.generationMap, epoch: current?.epoch, kmin: current?.kmin))
    }

    /// The reset at a chain boundary (design §6.6 设备追平): the cursor is
    /// dropped, every table moves to a new generation under the new epoch,
    /// every entry gains the stale marker, and the cursor key records the
    /// new epoch and kmin. The cursor key is written first, then the nine
    /// tables: any subset landing is recoverable (§6.6 游标键带 epoch 与
    /// kmin) — a lost cursor key re-resets on the next page (the marker is
    /// idempotent), a lost table disagrees with the cursor's epoch at load
    /// and is re-marked (`validate`).
    func reset(newEpoch: String, kmin: Int64?, baseline: SyncBaselineStore) {
        guard !userId.isEmpty else { return }
        baseline.advanceGeneration(tables: SyncBaselineStore.allTables)
        baseline.setEpoch(newEpoch, tables: SyncBaselineStore.allTables)
        baseline.markAllStale()
        write(Stored(cursor: nil, gen: baseline.generationMap, epoch: newEpoch, kmin: kmin))
        baseline.persist()
    }

    /// The tables whose baseline generation is not the one the cursor
    /// expects. Empty when there is no cursor.
    func mismatchedTables(_ baseline: SyncBaselineStore) -> [String] {
        guard let stored else { return [] }
        return SyncBaselineStore.allTables.filter { baseline.generation(of: $0) != (stored.gen[$0] ?? 0) }
    }

    /// The tables whose recorded epoch is not the cursor's (none counts):
    /// a reset's write of that table did not land, or landed while the
    /// cursor key's did not. Empty while the cursor has no epoch yet.
    func epochMismatchedTables(_ baseline: SyncBaselineStore) -> [String] {
        guard let epoch = stored?.epoch else { return [] }
        return SyncBaselineStore.allTables.filter { baseline.epoch(of: $0) != epoch }
    }

    /// Load-time check: drop the cursor when any generation disagrees; a
    /// table whose epoch disagrees is re-marked stale under the cursor's
    /// epoch before anything is applied (design §6.6), and the cursor is
    /// dropped too. Returns the tables that disagreed (empty = cursor kept).
    @discardableResult
    func validate(against baseline: SyncBaselineStore) -> [String] {
        var mismatched = mismatchedTables(baseline)
        let staleTables = epochMismatchedTables(baseline)
        if !staleTables.isEmpty, let epoch = stored?.epoch {
            for table in staleTables {
                baseline.markStale(table: table)
                baseline.setEpoch(epoch, tables: [table])
                if !mismatched.contains(table) { mismatched.append(table) }
            }
            baseline.persist()
        }
        if !mismatched.isEmpty { clear() }
        return mismatched
    }

    /// Drops the cursor seq; the epoch and kmin stay (they are what the
    /// next chain compares against).
    func clear() { value = nil }
}
