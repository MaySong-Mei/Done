//
//  SyncFakeServer.swift
//  DoneTests
//
//  An in-memory `SyncGateway` that behaves like migration 015 behind
//  PostgREST, as the local bench measured it (done-mcp/supabase/tests,
//  S7–S10): one global seq counter; a conditional PATCH honours `seq=eq`
//  (`[]` when the base does not match, `[]` again when the content is
//  identical, `[row]` with the new seq otherwise — and a tombstoned row
//  whose seq DOES match is accepted and returned with `deleted_at` set);
//  ignore-duplicates POST returns only the rows it inserted; a tombstone
//  PATCH stamps only live rows and stores the client's timestamp verbatim;
//  `sync_changes` is ordered by seq and clamped at the page limit (the
//  client's own clamp, `SyncGatewayLimits.clampedPageLimit`). A uuid
//  id matches whatever its case (Postgres compares the value) and comes
//  back LOWERCASE in every response body (PostgREST renders the column),
//  which is not how the device spells it — see
//  SyncOutboundTests.testInsertResponseIdsComeBackLowercaseAndStillSetTheBaselineSeq.
//
//  v1.6 (design §6.6): the `sync_epoch` row (`epoch`, `paused`, `rollback`,
//  the restore ledger `restores`), the write gate (a write carrying an
//  `X-Sync-Epoch` that is not the current epoch is refused with
//  `sync_epoch_stale`; while paused, every headed write and every
//  header-less write outside a rollback is refused with `sync_paused`),
//  version ids (`version_id` / `parent_version_id` on every row, a version
//  log that survives restores, `restored_from_version_id` read off a
//  write-back body and logged, never stored on the row), `is_ancestor` with
//  its three answers, and the ops steps: `dump()` + `restoreFromDump` (the
//  scripted restore: rows back to the dump, the counter never lowered, a
//  ledger record, a new epoch, paused), `bypassRestore` (a hand restore:
//  the counter and the epoch row come back from the dump too, no ledger
//  record), `restoreWithEpochStep` (the R3 catch-up step), `rollback` /
//  `reenable` / `unpause`, and `agentWrite` (a header-less write that takes
//  a new seq; during a rollback it keeps its version id, as the
//  stamp-only trigger does).
//
//  Hooks for interleavings and faults (survey M6(1)), each pinned by a
//  positive control in SyncFakeServerHookTests:
//  - `failWhen` throws before a verb runs.
//  - `holdWhen` parks a verb before it runs — the server state the verb
//    sees is the state at RELEASE time, which is what a request built
//    before another device's write and evaluated after it looks like.
//  - `holdResponseWhen` runs the verb at REQUEST time and parks only the
//    response — a stale page delivered late, after any number of steps.
//  - `dropResponseWhen` runs the verb (the server state changes) and then
//    throws — the write landed, the answer was lost.
//  - `maxRows` is PostgREST's `db-max-rows`: no single response, RPC page or
//    GET window, carries more rows than it.
//  - `reject(table:key:status:code:)` answers every write touching that row
//    with the non-2xx `SupabaseREST.send` throws, carrying the code.
//  - `unauthorizedRequests` answers the request with that 1-based ordinal
//    with the 401 `SupabaseREST` surfaces once its own refresh-and-retry
//    has also been refused.
//  - `physicallyDelete` removes a row with no tombstone and no seq (a
//    TRUNCATE or a hard delete); a later PATCH of it answers `[]`.
//  - `fetchAllWindowTransform` reshapes each restore window before it is
//    answered (a column dropped, a row rewritten mid-walk). The walk over
//    the windows is the production one, `SupabaseREST.keysetWalk`.
//  - `rewind(toSeq:)` puts every row and the counter back to the moment
//    that seq was taken and records a new epoch with that seq as floor — a
//    restore from a dump (survey M2), which hands out the same seqs again.
//  - `ancestryUnknownWhen` makes `is_ancestor` answer null for a pair (the
//    90-day cleanup, or a log that did not travel with a dump).
//  - `feedUnavailable` answers the feed RPC and the epoch GET with the 404
//    a server without migration 015 gives (PostgREST `PGRST202`).
//  - `lacksColumns` makes every write whose body names one of them fail the
//    way PostgREST does when its schema has no such column: 400 `PGRST204`,
//    "Could not find the '<column>' column of '<table>' in the schema
//    cache", through `SupabaseREST.requestError`. `pre015` is the whole
//    server before migration 015 (QA S7): the feed missing, every 015
//    column missing, no `seq=eq.` filter to PATCH on, and responses that
//    carry no `seq`, `deleted_at` or version columns.
//

import Foundation
import XCTest
@testable import Done

@MainActor
final class SyncFakeServer: SyncGateway {
    enum Verb: String, CaseIterable {
        case pull, patch, insert, tombstone, fetchAll, epoch, ancestry
        /// King's verbs, the feed-unavailable fallback's shapes.
        case upsert, delete
        /// Telemetry's composite-key bulk upsert (gh#273).
        case telemetryUpsert
    }

    /// One row of a telemetry table (`spike_runs`): keyed by the
    /// composite conflict target, guarded by `revision` exactly as the
    /// server's BEFORE UPDATE trigger is (`TelemetryServerModel.apply`).
    struct TelemetryRow {
        var data: [String: Any]
        var revision: Int
        /// How many upserts touched this key, applied or skipped — so a test
        /// can tell "one row" apart from "one request".
        var writes: Int
    }

    struct Request {
        let verb: Verb
        let table: String
        let keys: [String]
        let baseSeq: Int64?
        let body: Any?
        /// The `X-Sync-Epoch` the request carried (writes only).
        let epochHeader: String?
    }

    struct Row {
        var data: [String: Any]
        var seq: Int64
        var deletedAt: String?
        let userId: String
        var versionId: String
        var parentVersionId: String?
    }

    struct Injected: Error, Equatable {
        let note: String
    }

    struct Rejection {
        let status: Int
        let code: String
    }

    /// One line of `sync_versions`: survives every restore (the dump's
    /// COPY block is stripped, design §6.6 版本谱系 premise 1).
    struct VersionRecord: Equatable {
        let table: String
        let key: String
        let versionId: String
        let parentVersionId: String?
        let restoredFromVersionId: String?
        let seq: Int64
    }

    /// Everything a `supabase db dump` carries: the rows, the counter, and
    /// the `sync_epoch` row as it was — NOT the version log.
    struct Dump {
        let tables: [String: [String: Row]]
        let seqCounter: Int64
        let epoch: UUID
        let paused: Bool
        let restores: [SyncRestoreRecord]
    }

    /// One change to one row, kept so `rewind(toSeq:)` can undo it. `seq` is
    /// the seq the change took, or for a physical delete the counter at the
    /// time (it takes none).
    private struct JournalEntry {
        let seq: Int64
        let physical: Bool
        let table: String
        let key: String
        let before: Row?
    }

    static let singletonTables: Set<String> = ["user_settings", "agent_preferences", "agent_conversations"]
    static let metaKeys: Set<String> = ["seq", "updated_at", "synced_at"]
    /// Columns the gate / meta triggers own: never merged into a row's
    /// content by a client write.
    static let serverColumns: Set<String> = ["version_id", "parent_version_id", "restored_from_version_id"]

    static func keyColumn(for table: String) -> String {
        singletonTables.contains(table) ? "user_id" : "id"
    }

    /// Storage key: the value Postgres compares, so `D94F…` and `d94f…`
    /// are one row.
    private static func k(_ key: String) -> String {
        SyncBaselineKey.matchKey(key)
    }

    let userId: String
    private(set) var seqCounter: Int64 = 0
    private(set) var tables: [String: [String: Row]] = [:]
    private(set) var requests: [Request] = []
    /// Telemetry tables, keyed `table → composite key → row`. Separate from
    /// `tables` because these rows have no seq, no version and no gate.
    private(set) var telemetryTables: [String: [String: TelemetryRow]] = [:]

    /// Evaluated at the start of every verb; a non-nil error is thrown
    /// before any state changes.
    var failWhen: ((Verb, String) -> Error?)?
    /// Evaluated after `failWhen`; `true` parks the verb until `release`.
    var holdWhen: ((Verb, String) -> Bool)?
    /// Evaluated after the verb ran; `true` parks its RESULT (computed from
    /// the state at request time) until `releaseResponse`.
    var holdResponseWhen: ((Verb, String) -> Bool)?
    /// Evaluated after the verb ran; a non-nil error is thrown in place of
    /// the result, the state change stays.
    var dropResponseWhen: ((Verb, String) -> Error?)?
    /// PostgREST `db-max-rows`; nil is no cap beyond the page limit.
    var maxRows: Int?
    /// 1-based ordinals (over `requests`) answered with a 401.
    var unauthorizedRequests: Set<Int> = []
    private(set) var rejections: [String: [String: Rejection]] = [:]
    /// `is_ancestor` answers null for pairs this returns true for.
    var ancestryUnknownWhen: ((_ table: String, _ key: String, _ a: String, _ b: String) -> Bool)?
    /// A server where migration 015 is not applied: the feed RPC and the
    /// epoch GET answer 404 `PGRST202` (function / relation not in the
    /// schema cache). Writes still work the pre-015 way.
    var feedUnavailable = false
    /// Columns this server's schema does not have (see the header).
    var lacksColumns: Set<String> = []
    /// Every column migration 015 adds that a client body can name.
    static let only015Columns: Set<String> = ["seq", "deleted_at", "version_id", "parent_version_id",
                                               "restored_from_version_id", "domino_anchor"]
    /// The server before migration 015 (see the header).
    var pre015 = false {
        didSet { lacksColumns = pre015 ? Self.only015Columns : [] }
    }

    // MARK: sync_epoch

    /// The restore identity (design §6.6 纪元行与暂停位). `epoch` changes
    /// at every epoch step and at `rewind`; `floor` is `rewind`'s legacy
    /// record (survey M2) and plays no part in v1.6.
    private(set) var epoch = UUID()
    private(set) var floor: Int64 = 0
    var epochString: String { epoch.uuidString }
    private(set) var paused = false
    private(set) var rollback = false
    private(set) var restores: [SyncRestoreRecord] = []

    /// The header the client's writes carry (`SyncGateway.writeEpoch`).
    var writeEpoch: String?

    private(set) var versionLog: [VersionRecord] = []

    private var held: [CheckedContinuation<Void, Error>] = []
    private var heldResponses: [CheckedContinuation<Void, Error>] = []
    private var journal: [JournalEntry] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0

    init(userId: String) {
        self.userId = userId
    }

    // MARK: Hold-back

    var heldCount: Int { held.count }

    func release(count: Int = 1) {
        for _ in 0..<count {
            guard !held.isEmpty else { return }
            held.removeFirst().resume()
        }
    }

    func releaseAll() {
        release(count: held.count)
    }

    var heldResponseCount: Int { heldResponses.count }

    /// Deliver the oldest parked responses, or fail them with `error` (the
    /// connection died after the server answered).
    func releaseResponse(count: Int = 1, failing error: Error? = nil) {
        for _ in 0..<count {
            guard !heldResponses.isEmpty else { return }
            let continuation = heldResponses.removeFirst()
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    func releaseAllResponses() {
        releaseResponse(count: heldResponses.count)
    }

    private func gate(_ verb: Verb, _ table: String) async throws {
        if unauthorizedRequests.contains(requests.count) {
            throw SupabaseREST.SyncError.tokenExpired
        }
        if let error = failWhen?(verb, table) { throw error }
        guard holdWhen?(verb, table) == true else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            held.append(continuation)
        }
    }

    /// The far side of a verb that ran: drop or park its answer.
    private func respond<T>(_ verb: Verb, _ table: String, _ result: T) async throws -> T {
        if let error = dropResponseWhen?(verb, table) { throw error }
        if holdResponseWhen?(verb, table) == true {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                heldResponses.append(continuation)
            }
        }
        return result
    }

    private func checkRejected(_ verb: Verb, table: String, keys: [String]) throws {
        guard let byKey = rejections[table] else { return }
        for key in keys {
            if let rejection = byKey[Self.k(key)] {
                throw SupabaseREST.SyncError.requestFailed(
                    table: table, method: verb == .insert ? "POST" : "PATCH",
                    status: rejection.status, code: rejection.code
                )
            }
        }
    }

    /// `trg_<t>_sync_gate` (design §6.6 服务端写闸), run before the write
    /// as one statement: nothing lands when it raises.
    private func writeGate(_ verb: Verb, table: String, header: String?) throws {
        let method = verb == .insert ? "POST" : "PATCH"
        if let header, header != epochString {
            throw SupabaseREST.SyncError.gateRejected(table: table, method: method, reason: SupabaseREST.gateStaleMessage)
        }
        if paused, header != nil || !rollback {
            throw SupabaseREST.SyncError.gateRejected(table: table, method: method, reason: SupabaseREST.gatePausedMessage)
        }
    }

    /// PostgREST's answer to a body naming a column the schema lacks.
    private func checkColumns(_ verb: Verb, table: String, bodies: [[String: Any]]) throws {
        guard !lacksColumns.isEmpty else { return }
        let named = Set(bodies.flatMap(\.keys)).intersection(lacksColumns)
        guard let column = named.sorted().first else { return }
        let body: [String: Any] = [
            "code": "PGRST204", "details": NSNull(), "hint": NSNull(),
            "message": "Could not find the '\(column)' column of '\(table)' in the schema cache",
        ]
        throw SupabaseREST.requestError(table: table, method: verb == .insert ? "POST" : "PATCH", status: 400,
                                        body: try JSONSerialization.data(withJSONObject: body))
    }

    private func unavailable(_ path: String) -> Error {
        SupabaseREST.SyncError.requestFailed(table: path, method: "POST", status: 404, code: "PGRST202")
    }

    private func capped(_ count: Int) -> Int {
        maxRows.map { min(count, $0) } ?? count
    }

    private func record(table: String, key: String, seq: Int64, physical: Bool = false) {
        journal.append(JournalEntry(seq: seq, physical: physical, table: table, key: key, before: tables[table]?[key]))
    }

    private func enter() {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    private func leave() {
        inFlight -= 1
    }

    // MARK: Versions

    private func mintVersion(table: String, key: String, parent: String?, restoredFrom: String?, seq: Int64) -> String {
        let vid = UUID().uuidString.lowercased()
        versionLog.append(VersionRecord(table: table, key: key, versionId: vid, parentVersionId: parent,
                                        restoredFromVersionId: restoredFrom, seq: seq))
        return vid
    }

    /// The log's records for one row, newest last.
    func versions(table: String, key: String) -> [VersionRecord] {
        versionLog.filter { $0.table == table && $0.key == Self.k(key) }
    }

    func versionId(table: String, key: String) -> String? {
        tables[table]?[Self.k(key)]?.versionId
    }

    /// `is_ancestor` as the RPC computes it (design §5.9): from `b`, up the
    /// parent and restored-from edges, at most 1000 steps; true on reaching
    /// `a`; null when either id is not in the log for this row.
    func ancestry(table: String, key: String, a: String, b: String) -> Bool? {
        let key = Self.k(key)
        if ancestryUnknownWhen?(table, key, a, b) == true { return nil }
        let records = versions(table: table, key: key)
        guard records.contains(where: { $0.versionId == a }), records.contains(where: { $0.versionId == b }) else { return nil }
        var frontier = [b]
        var seen: Set<String> = []
        var steps = 0
        while let current = frontier.popLast(), steps < 1000 {
            steps += 1
            if current == a { return true }
            guard seen.insert(current).inserted else { continue }
            for record in records where record.versionId == current {
                if let parent = record.parentVersionId { frontier.append(parent) }
                if let restored = record.restoredFromVersionId { frontier.append(restored) }
            }
        }
        return false
    }

    // MARK: Direct state (what another device, or the dashboard, did)

    func row(table: String, key: String) -> Row? {
        tables[table]?[Self.k(key)]
    }

    func seq(table: String, key: String) -> Int64? {
        tables[table]?[Self.k(key)]?.seq
    }

    func isTombstoned(table: String, key: String) -> Bool {
        tables[table]?[Self.k(key)]?.deletedAt != nil
    }

    /// Insert rows as if they already existed on the server. Returns each
    /// key's seq.
    @discardableResult
    func seed(table: String, rows: [[String: Any]]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        let keyColumn = Self.keyColumn(for: table)
        for row in rows {
            guard let key = row[keyColumn] as? String else { continue }
            seqCounter += 1
            record(table: table, key: Self.k(key), seq: seqCounter)
            let vid = mintVersion(table: table, key: Self.k(key), parent: nil, restoredFrom: nil, seq: seqCounter)
            tables[table, default: [:]][Self.k(key)] = Row(data: Self.content(row), seq: seqCounter, deletedAt: nil,
                                                          userId: userId, versionId: vid, parentVersionId: nil)
            out[key] = seqCounter
        }
        return out
    }

    /// Another device's edit: merge and take a new seq (no filter, no
    /// gate). A new version with the old one as parent.
    @discardableResult
    func writeDirectly(table: String, key: String, data: [String: Any]) -> Int64 {
        let key = Self.k(key)
        var row = tables[table]?[key] ?? Row(data: [:], seq: 0, deletedAt: nil, userId: userId, versionId: "", parentVersionId: nil)
        let existed = tables[table]?[key] != nil
        for (k, v) in data where k != "seq" && !Self.serverColumns.contains(k) { row.data[k] = v }
        seqCounter += 1
        record(table: table, key: key, seq: seqCounter)
        row.seq = seqCounter
        let parent = existed ? row.versionId : nil
        row.parentVersionId = parent
        row.versionId = mintVersion(table: table, key: key, parent: parent, restoredFrom: nil, seq: seqCounter)
        tables[table, default: [:]][key] = row
        return seqCounter
    }

    /// An agent / MCP / dashboard write: header-less, through the gate
    /// (refused while paused outside a rollback), a new seq; during a
    /// rollback the version id stays (only the stamp trigger runs, design
    /// §6.6 回滚期间盖号).
    @discardableResult
    func agentWrite(table: String, key: String, data: [String: Any]) throws -> Int64 {
        try writeGate(.patch, table: table, header: nil)
        guard rollback else { return writeDirectly(table: table, key: key, data: data) }
        let key = Self.k(key)
        var row = tables[table]?[key] ?? Row(data: [:], seq: 0, deletedAt: nil, userId: userId,
                                             versionId: UUID().uuidString.lowercased(), parentVersionId: nil)
        for (k, v) in data where k != "seq" && !Self.serverColumns.contains(k) { row.data[k] = v }
        seqCounter += 1
        record(table: table, key: key, seq: seqCounter)
        row.seq = seqCounter
        tables[table, default: [:]][key] = row
        return seqCounter
    }

    /// Another device's delete, rewritten server-side into a tombstone
    /// UPDATE that takes a new seq (015 §4 + §2). On a row already dead
    /// the rewrite keeps `deleted_at` and changes nothing, so no seq moves.
    @discardableResult
    func tombstoneDirectly(table: String, key: String, at date: Date = Date()) -> Int64? {
        let key = Self.k(key)
        guard var row = tables[table]?[key] else { return nil }
        guard row.deletedAt == nil else { return row.seq }
        row.deletedAt = Self.iso.string(from: date)
        seqCounter += 1
        record(table: table, key: key, seq: seqCounter)
        row.seq = seqCounter
        row.parentVersionId = row.versionId
        row.versionId = mintVersion(table: table, key: key, parent: row.parentVersionId, restoredFrom: nil, seq: seqCounter)
        tables[table]![key] = row
        return seqCounter
    }

    /// A row gone with no tombstone and no seq: what a TRUNCATE or a hard
    /// delete leaves behind (survey G2). Returns whether a row was there.
    @discardableResult
    func physicallyDelete(table: String, key: String) -> Bool {
        let key = Self.k(key)
        guard tables[table]?[key] != nil else { return false }
        record(table: table, key: key, seq: seqCounter, physical: true)
        tables[table]![key] = nil
        return true
    }

    /// Every write that touches this row answers `status` with PostgREST's
    /// `code` in the body (a CHECK, a NOT NULL, a dropped column — survey
    /// G7), and changes nothing.
    func reject(table: String, key: String, status: Int = 400, code: String) {
        rejections[table, default: [:]][Self.k(key)] = Rejection(status: status, code: code)
    }

    func clearRejection(table: String, key: String) {
        rejections[table]?[Self.k(key)] = nil
    }

    /// A restore from a dump taken right after `seq` was handed out: every
    /// row as it was then, the counter back at `seq` (the dump's `setval`),
    /// so the next write takes `seq + 1` again, and a new epoch with `seq`
    /// as its floor (survey M2). Physical deletes made while the counter
    /// stood at `seq` come after the dump and are undone too. No ledger
    /// record: this is the hand restore of v1.5.
    func rewind(toSeq seq: Int64) {
        precondition(seq >= 0 && seq <= seqCounter, "rewind target outside the seqs handed out")
        while let last = journal.last, last.seq > seq || (last.physical && last.seq == seq) {
            journal.removeLast()
            tables[last.table, default: [:]][last.key] = last.before
        }
        seqCounter = seq
        floor = seq
        epoch = UUID()
    }

    // MARK: The ops steps (design §6.6)

    /// `supabase db dump` now: rows, counter and the `sync_epoch` row.
    func dump() -> Dump {
        Dump(tables: tables, seqCounter: seqCounter, epoch: epoch, paused: paused, restores: restores)
    }

    /// The highest seq among the rows now held, tombstones included — a
    /// ledger record's `kept_max`.
    private var keptMax: Int64 {
        tables.values.flatMap { $0.values.map(\.seq) }.max() ?? 0
    }

    /// One epoch step's common tail: a new epoch, a ledger record, the
    /// counter only raised, paused.
    private func epochStep(dumpEpoch: String?) {
        epoch = UUID()
        let kept = keptMax
        seqCounter = max(seqCounter, kept)
        restores.append(SyncRestoreRecord(epoch: epochString, keptMax: kept, dumpEpoch: dumpEpoch))
        paused = true
        journal = []
    }

    /// `ops/restore.sh`: the rows come back as the dump held them (their
    /// seqs and version ids too), the counter is never lowered, the live
    /// ledger is kept and gains a record, a new epoch, `paused`. The version
    /// log is not touched (its COPY block is stripped from the dump).
    func restoreFromDump(_ dump: Dump) {
        tables = dump.tables
        epochStep(dumpEpoch: dump.epoch.uuidString)
        rollback = false
    }

    /// A restore that bypassed the script: `--replace` brings back the
    /// rows, the counter (`setval`) AND the dump's own `sync_epoch` row,
    /// ledger included; the window is open until `restoreWithEpochStep`.
    func bypassRestore(_ dump: Dump) {
        tables = dump.tables
        seqCounter = dump.seqCounter
        epoch = dump.epoch
        paused = dump.paused
        restores = dump.restores
        journal = []
    }

    /// `ops/restore_with_epoch.sql` (the R3 step after a bypass): kept_max
    /// from the rows now held, the counter only raised, a record with no
    /// dump epoch, a new epoch, `paused`, `rollback := false`.
    func restoreWithEpochStep() {
        epochStep(dumpEpoch: nil)
        rollback = false
    }

    /// `ops/rollback.sql`: paused and rollback set; from here agent writes
    /// land with a new seq and the same version id.
    func rollbackTriggers() {
        paused = true
        rollback = true
    }

    /// `ops/reenable.sql`: the triggers back, then the epoch step.
    func reenable() {
        epochStep(dumpEpoch: nil)
        rollback = false
    }

    /// The ops' last step after the post-apply checks.
    func unpause() {
        paused = false
    }

    /// `update sync_epoch set paused = true` on its own (the first step of
    /// a rollback, or an operator holding writes).
    func pause() {
        paused = true
    }

    // MARK: Per-device connections

    /// One device's view of the shared server: its own `X-Sync-Epoch`
    /// (`SyncGateway.writeEpoch`), handed to the server right before each
    /// verb runs. Two devices in one test each get one; the server's own
    /// `writeEpoch` is then "the header of the request being served".
    final class Connection: SyncGateway {
        let server: SyncFakeServer
        var writeEpoch: String?

        init(server: SyncFakeServer) {
            self.server = server
        }

        func pullChanges(sinceSeq: Int64, pageLimit: Int) async throws -> [SyncFeedRow] {
            server.writeEpoch = writeEpoch
            return try await server.pullChanges(sinceSeq: sinceSeq, pageLimit: pageLimit)
        }

        func fetchSyncEpoch() async throws -> SyncEpochRow {
            server.writeEpoch = writeEpoch
            return try await server.fetchSyncEpoch()
        }

        func isAncestor(table: String, id: String, a: String, b: String) async throws -> Bool? {
            server.writeEpoch = writeEpoch
            return try await server.isAncestor(table: table, id: id, a: a, b: b)
        }

        func patchConditional(table: String, keyColumn: String, key: String, baseSeq: Int64, body: [String: Any]) async throws -> [[String: Any]] {
            server.writeEpoch = writeEpoch
            return try await server.patchConditional(table: table, keyColumn: keyColumn, key: key, baseSeq: baseSeq, body: body)
        }

        func insertIgnoringDuplicates(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
            server.writeEpoch = writeEpoch
            return try await server.insertIgnoringDuplicates(table: table, rows: rows)
        }

        func tombstone(table: String, keyColumn: String, keys: [String], deletedAt: Date) async throws -> [[String: Any]] {
            server.writeEpoch = writeEpoch
            return try await server.tombstone(table: table, keyColumn: keyColumn, keys: keys, deletedAt: deletedAt)
        }

        func upsertMerging(table: String, keyColumn: String, rows: [[String: Any]]) async throws {
            server.writeEpoch = writeEpoch
            try await server.upsertMerging(table: table, keyColumn: keyColumn, rows: rows)
        }

        func deletePhysically(table: String, keyColumn: String, keys: [String]) async throws {
            server.writeEpoch = writeEpoch
            try await server.deletePhysically(table: table, keyColumn: keyColumn, keys: keys)
        }

        func upsertRows(table: String, rows: [[String: Any]], onConflict: [String]) async throws {
            try await server.upsertRows(table: table, rows: rows, onConflict: onConflict)
        }

        func fetchAll(table: String, userId: String) async throws -> [[String: Any]] {
            server.writeEpoch = writeEpoch
            return try await server.fetchAll(table: table, userId: userId)
        }
    }

    func connection() -> Connection {
        Connection(server: self)
    }

    // MARK: SyncGateway

    func pullChanges(sinceSeq: Int64, pageLimit: Int) async throws -> [SyncFeedRow] {
        enter(); defer { leave() }
        requests.append(Request(verb: .pull, table: "sync_changes", keys: [], baseSeq: sinceSeq, body: pageLimit, epochHeader: nil))
        try await gate(.pull, "sync_changes")
        if feedUnavailable || pre015 { throw unavailable("sync_changes") }
        let limit = capped(SyncGatewayLimits.clampedPageLimit(pageLimit))
        var rows: [SyncFeedRow] = []
        for (table, byKey) in tables {
            for row in byKey.values where row.userId == userId && row.seq > sinceSeq {
                rows.append(SyncFeedRow(table: table, seq: row.seq, data: represent(row)))
            }
        }
        rows.sort { $0.seq < $1.seq }
        return try await respond(.pull, "sync_changes", Array(rows.prefix(limit)))
    }

    func fetchSyncEpoch() async throws -> SyncEpochRow {
        enter(); defer { leave() }
        requests.append(Request(verb: .epoch, table: "sync_epoch", keys: [], baseSeq: nil, body: nil, epochHeader: nil))
        try await gate(.epoch, "sync_epoch")
        if feedUnavailable || pre015 { throw unavailable("sync_epoch") }
        return try await respond(.epoch, "sync_epoch", SyncEpochRow(epoch: epochString, paused: paused, restores: restores))
    }

    func isAncestor(table: String, id: String, a: String, b: String) async throws -> Bool? {
        enter(); defer { leave() }
        requests.append(Request(verb: .ancestry, table: table, keys: [id], baseSeq: nil, body: [a, b], epochHeader: nil))
        try await gate(.ancestry, table)
        if pre015 { throw unavailable("is_ancestor") }
        return try await respond(.ancestry, table, ancestry(table: table, key: id, a: a, b: b))
    }

    func patchConditional(
        table: String,
        keyColumn: String,
        key: String,
        baseSeq: Int64,
        body: [String: Any]
    ) async throws -> [[String: Any]] {
        enter(); defer { leave() }
        let header = writeEpoch
        requests.append(Request(verb: .patch, table: table, keys: [key], baseSeq: baseSeq, body: body, epochHeader: header))
        try await gate(.patch, table)
        XCTAssertEqual(keyColumn, Self.keyColumn(for: table), "wrong key column for \(table)")
        if pre015 {
            // `seq=eq.<n>` names a column the table does not have.
            let body: [String: Any] = ["code": "42703", "message": "column \(table).seq does not exist"]
            throw SupabaseREST.requestError(table: table, method: "PATCH", status: 400,
                                            body: try JSONSerialization.data(withJSONObject: body))
        }
        try checkColumns(.patch, table: table, bodies: [body])
        try checkRejected(.patch, table: table, keys: [key])
        let key = Self.k(key)
        guard var row = tables[table]?[key], row.seq == baseSeq else { return try await respond(.patch, table, []) }
        // The gate runs per row the statement touches: a filter that
        // matches nothing raises nothing.
        try writeGate(.patch, table: table, header: header)
        var merged = row.data
        for (k, v) in body where k != "seq" && !Self.serverColumns.contains(k) {
            if k == "deleted_at" {
                // I6: a tombstone survives an ordinary write.
                if row.deletedAt != nil { continue }
                if v is NSNull { continue }
                row.deletedAt = v as? String
                continue
            }
            merged[k] = v
        }
        if Self.canonical(merged) == Self.canonical(row.data), row.deletedAt == tables[table]?[key]?.deletedAt {
            // content-identical: no seq, no row (015 §2 `return null`)
            return try await respond(.patch, table, [])
        }
        seqCounter += 1
        record(table: table, key: key, seq: seqCounter)
        row.data = merged
        row.seq = seqCounter
        let restoredFrom = body["restored_from_version_id"] as? String
        row.parentVersionId = row.versionId
        row.versionId = mintVersion(table: table, key: key, parent: row.parentVersionId, restoredFrom: restoredFrom, seq: seqCounter)
        tables[table]![key] = row
        return try await respond(.patch, table, [represent(row)])
    }

    func insertIgnoringDuplicates(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
        enter(); defer { leave() }
        let keyColumn = Self.keyColumn(for: table)
        let header = writeEpoch
        requests.append(Request(
            verb: .insert, table: table,
            keys: rows.compactMap { $0[keyColumn] as? String }, baseSeq: nil, body: rows, epochHeader: header
        ))
        try await gate(.insert, table)
        try checkColumns(.insert, table: table, bodies: rows)
        try checkRejected(.insert, table: table, keys: rows.compactMap { $0[keyColumn] as? String })
        var inserted: [[String: Any]] = []
        for row in rows {
            guard let key = (row[keyColumn] as? String).map(Self.k) else { continue }
            if tables[table]?[key] != nil { continue }
            try writeGate(.insert, table: table, header: header)
            seqCounter += 1
            record(table: table, key: key, seq: seqCounter)
            // INSERT keeps the client's parent (a re-upload names the
            // version its baseline held, design §5.9); a dead-row insert
            // carries `deleted_at`.
            let parent = row["parent_version_id"] as? String
            let restoredFrom = row["restored_from_version_id"] as? String
            let deletedAt = row["deleted_at"] as? String
            let vid = mintVersion(table: table, key: key, parent: parent, restoredFrom: restoredFrom, seq: seqCounter)
            let stored = Row(data: Self.content(row), seq: seqCounter, deletedAt: deletedAt, userId: userId,
                             versionId: vid, parentVersionId: parent)
            tables[table, default: [:]][key] = stored
            inserted.append(represent(stored))
        }
        return try await respond(.insert, table, inserted)
    }

    func tombstone(
        table: String,
        keyColumn: String,
        keys: [String],
        deletedAt: Date
    ) async throws -> [[String: Any]] {
        enter(); defer { leave() }
        let header = writeEpoch
        requests.append(Request(verb: .tombstone, table: table, keys: keys, baseSeq: nil, body: deletedAt, epochHeader: header))
        try await gate(.tombstone, table)
        XCTAssertEqual(keyColumn, Self.keyColumn(for: table), "wrong key column for \(table)")
        try checkColumns(.tombstone, table: table, bodies: [["deleted_at": deletedAt]])
        try checkRejected(.tombstone, table: table, keys: keys)
        var stamped: [[String: Any]] = []
        let stamp = Self.iso.string(from: deletedAt)
        for key in keys.map(Self.k) {
            guard var row = tables[table]?[key], row.deletedAt == nil else { continue }
            try writeGate(.tombstone, table: table, header: header)
            seqCounter += 1
            record(table: table, key: key, seq: seqCounter)
            row.deletedAt = stamp
            row.seq = seqCounter
            row.parentVersionId = row.versionId
            row.versionId = mintVersion(table: table, key: key, parent: row.parentVersionId, restoredFrom: nil, seq: seqCounter)
            tables[table]![key] = row
            stamped.append(represent(row))
        }
        return try await respond(.tombstone, table, stamped)
    }

    /// King's merge-duplicates upsert: an existing row takes the body's
    /// columns (a new seq, as the meta trigger would give it on a 015
    /// server), a missing one is inserted. Returns nothing (`return=minimal`).
    func upsertMerging(table: String, keyColumn: String, rows: [[String: Any]]) async throws {
        enter(); defer { leave() }
        let header = writeEpoch
        requests.append(Request(verb: .upsert, table: table, keys: rows.compactMap { $0[keyColumn] as? String },
                                baseSeq: nil, body: rows, epochHeader: header))
        try await gate(.upsert, table)
        XCTAssertEqual(keyColumn, Self.keyColumn(for: table), "wrong key column for \(table)")
        try checkColumns(.upsert, table: table, bodies: rows)
        try checkRejected(.upsert, table: table, keys: rows.compactMap { $0[keyColumn] as? String })
        for body in rows {
            guard let key = (body[keyColumn] as? String).map(Self.k) else { continue }
            try writeGate(.upsert, table: table, header: header)
            seqCounter += 1
            record(table: table, key: key, seq: seqCounter)
            if var row = tables[table]?[key] {
                var merged = row.data
                for (k, v) in Self.content(body) { merged[k] = v }
                row.data = merged
                row.seq = seqCounter
                row.parentVersionId = row.versionId
                row.versionId = mintVersion(table: table, key: key, parent: row.parentVersionId, restoredFrom: nil, seq: seqCounter)
                tables[table]![key] = row
            } else {
                let vid = mintVersion(table: table, key: key, parent: nil, restoredFrom: nil, seq: seqCounter)
                tables[table, default: [:]][key] = Row(data: Self.content(body), seq: seqCounter, deletedAt: nil, userId: userId,
                                                       versionId: vid, parentVersionId: nil)
            }
        }
        _ = try await respond(.upsert, table, [[String: Any]]())
    }

    /// King's physical DELETE: the rows are gone, no tombstone, no seq.
    func deletePhysically(table: String, keyColumn: String, keys: [String]) async throws {
        enter(); defer { leave() }
        requests.append(Request(verb: .delete, table: table, keys: keys, baseSeq: nil, body: nil, epochHeader: writeEpoch))
        try await gate(.delete, table)
        XCTAssertEqual(keyColumn, Self.keyColumn(for: table), "wrong key column for \(table)")
        try checkRejected(.delete, table: table, keys: keys)
        for key in keys { _ = physicallyDelete(table: table, key: key) }
        _ = try await respond(.delete, table, [[String: Any]]())
    }

    /// Telemetry's composite-key upsert as the server runs it (gh#273 wire
    /// contract §3): a row is one `(user_id, run_id)` — a single-column
    /// `on_conflict` is a test failure, because production would then take
    /// two rows where this took one (B·F13/F35); an existing row is replaced
    /// only when the incoming `revision` is higher
    /// (`TelemetryServerModel.apply`, the BEFORE UPDATE guard), and a
    /// skipped row is still a 2xx. The row's `user_id` must be this server's
    /// user, as RLS `with check` would demand. No seq, no version, no
    /// `X-Sync-Epoch` gate — the table is outside 015.
    func upsertRows(table: String, rows: [[String: Any]], onConflict: [String]) async throws {
        enter(); defer { leave() }
        requests.append(Request(verb: .telemetryUpsert, table: table,
                                keys: rows.compactMap { $0["run_id"] as? String },
                                baseSeq: nil, body: rows, epochHeader: nil))
        try await gate(.telemetryUpsert, table)
        XCTAssertEqual(onConflict, ["user_id", "run_id"],
                       "telemetry upserts must name the composite primary key (wire contract §3)")
        for row in rows {
            let keyParts = onConflict.map { column -> String in
                if let text = row[column] as? String { return text.lowercased() }
                if let number = row[column] as? NSNumber { return number.stringValue }
                return ""
            }
            guard !keyParts.contains("") else {
                throw SupabaseREST.SyncError.requestFailed(table: table, method: "POST", status: 400, code: "23502")
            }
            guard let rowUser = row["user_id"] as? String, rowUser.lowercased() == userId.lowercased() else {
                // RLS `with check (user_id = auth.uid())` refuses the row.
                throw SupabaseREST.SyncError.requestFailed(table: table, method: "POST", status: 401, code: "42501")
            }
            let key = keyParts.joined(separator: "|")
            let incoming = (row["revision"] as? NSNumber)?.intValue ?? 0
            if var existing = telemetryTables[table]?[key] {
                existing.writes += 1
                if TelemetryServerModel.apply(existing: existing.revision, incoming: incoming) {
                    existing.data = row
                    existing.revision = incoming
                }
                telemetryTables[table]![key] = existing
            } else {
                telemetryTables[table, default: [:]][key] = TelemetryRow(data: row, revision: incoming, writes: 1)
            }
        }
        _ = try await respond(.telemetryUpsert, table, [[String: Any]]())
    }

    /// The telemetry row for a run id as the server holds it.
    func telemetryRow(table: String = TelemetryWire.table, runID: UUID) -> TelemetryRow? {
        telemetryTables[table]?["\(userId.lowercased())|\(runID.uuidString.lowercased())"]
    }

    func telemetryRowCount(table: String = TelemetryWire.table) -> Int {
        telemetryTables[table]?.count ?? 0
    }

    /// The restore path runs the PRODUCTION keyset walk
    /// (`SupabaseREST.keysetWalk`); only the window GET is faked here, one
    /// recorded `.fetchAll` request per window, its `baseSeq` the `seq=gt.`
    /// the window was asked after. `fetchAllWindowTransform` lets a test
    /// reshape a window as the wire would carry it.
    func fetchAll(table: String, userId: String) async throws -> [[String: Any]] {
        try await SupabaseREST.keysetWalk(table: table, pageSize: SyncGatewayLimits.fetchAllPageSize) { afterSeq in
            try await self.fetchAllWindow(table: table, userId: userId, afterSeq: afterSeq)
        }
    }

    /// Applied to each restore window after it is computed, before it is
    /// answered: a test's way to drop a column or rewrite a row mid-walk.
    var fetchAllWindowTransform: ((_ afterSeq: Int64?, _ window: [[String: Any]]) -> [[String: Any]])?

    /// One `GET <table>?…&order=seq.asc&seq=gt.<afterSeq>` with
    /// `Range: 0-<pageSize-1>`: live rows only, in seq order, at most
    /// `maxRows` of them.
    private func fetchAllWindow(table: String, userId: String, afterSeq: Int64?) async throws -> [[String: Any]] {
        enter(); defer { leave() }
        requests.append(Request(verb: .fetchAll, table: table, keys: [], baseSeq: afterSeq, body: nil, epochHeader: nil))
        try await gate(.fetchAll, table)
        let live = (tables[table] ?? [:]).values
            .filter { $0.userId == userId && $0.deletedAt == nil && (afterSeq == nil || $0.seq > afterSeq!) }
            .sorted { $0.seq < $1.seq }
        var window = Array(live.prefix(capped(SyncGatewayLimits.fetchAllPageSize))).map(represent)
        if let transform = fetchAllWindowTransform { window = transform(afterSeq, window) }
        return try await respond(.fetchAll, table, window)
    }

    // MARK: Helpers

    func requests(_ verb: Verb, table: String? = nil) -> [Request] {
        requests.filter { $0.verb == verb && (table == nil || $0.table == table) }
    }

    /// The row's content columns: what the client sent minus the columns
    /// the server owns.
    private static func content(_ row: [String: Any]) -> [String: Any] {
        row.filter { !serverColumns.contains($0.key) && $0.key != "deleted_at" }
    }

    /// The row as PostgREST would return it: content plus `seq`,
    /// `deleted_at` (null when live), the version columns, a uuid `id`
    /// rendered lowercase whatever case the client sent (measured on the
    /// local stack with an `UUID.uuidString` id; the bench scripts mint
    /// lowercase ids and never saw the difference).
    func represent(_ row: Row) -> [String: Any] {
        var out = row.data
        out["user_id"] = row.userId
        if !pre015 {
            out["seq"] = NSNumber(value: row.seq)
            out["deleted_at"] = row.deletedAt.map { $0 as Any } ?? NSNull()
            out["version_id"] = row.versionId
            out["parent_version_id"] = row.parentVersionId.map { $0 as Any } ?? NSNull()
        }
        if let id = out["id"] as? String, UUID(uuidString: id) != nil {
            out["id"] = id.lowercased()
        }
        return out
    }

    private static func canonical(_ data: [String: Any]) -> String {
        let content = data.filter { !metaKeys.contains($0.key) && $0.key != "deleted_at" && !serverColumns.contains($0.key) }
        guard JSONSerialization.isValidJSONObject(content),
              let bytes = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8)
        else { return String(describing: content) }
        return text
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct SyncEventuallyTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for: \(what)" }
}

/// Poll a main-actor condition without sleeping the test thread.
@MainActor
func syncEventually(_ what: String, timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw SyncEventuallyTimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(5))
    }
}
