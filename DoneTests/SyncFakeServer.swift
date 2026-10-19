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
//

import Foundation
import XCTest
@testable import Done

@MainActor
final class SyncFakeServer: SyncGateway {
    enum Verb: String, CaseIterable {
        case pull, patch, insert, tombstone, fetchAll
    }

    struct Request {
        let verb: Verb
        let table: String
        let keys: [String]
        let baseSeq: Int64?
        let body: Any?
    }

    struct Row {
        var data: [String: Any]
        var seq: Int64
        var deletedAt: String?
        let userId: String
    }

    struct Injected: Error, Equatable {
        let note: String
    }

    struct Rejection {
        let status: Int
        let code: String
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

    /// The restore identity (survey M2's `sync_epoch`): a new epoch and a
    /// floor at each `rewind`. The gateway does not serve it yet.
    private(set) var epoch = UUID()
    private(set) var floor: Int64 = 0

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
            tables[table, default: [:]][Self.k(key)] = Row(data: row, seq: seqCounter, deletedAt: nil, userId: userId)
            out[key] = seqCounter
        }
        return out
    }

    /// Another device's edit: merge and take a new seq (no filter).
    @discardableResult
    func writeDirectly(table: String, key: String, data: [String: Any]) -> Int64 {
        let key = Self.k(key)
        var row = tables[table]?[key] ?? Row(data: [:], seq: 0, deletedAt: nil, userId: userId)
        for (k, v) in data where k != "seq" { row.data[k] = v }
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
    /// stood at `seq` come after the dump and are undone too.
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

    // MARK: SyncGateway

    func pullChanges(sinceSeq: Int64, pageLimit: Int) async throws -> [SyncFeedRow] {
        enter(); defer { leave() }
        requests.append(Request(verb: .pull, table: "sync_changes", keys: [], baseSeq: sinceSeq, body: pageLimit))
        try await gate(.pull, "sync_changes")
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

    func patchConditional(
        table: String,
        keyColumn: String,
        key: String,
        baseSeq: Int64,
        body: [String: Any]
    ) async throws -> [[String: Any]] {
        enter(); defer { leave() }
        requests.append(Request(verb: .patch, table: table, keys: [key], baseSeq: baseSeq, body: body))
        try await gate(.patch, table)
        XCTAssertEqual(keyColumn, Self.keyColumn(for: table), "wrong key column for \(table)")
        try checkRejected(.patch, table: table, keys: [key])
        let key = Self.k(key)
        guard var row = tables[table]?[key], row.seq == baseSeq else { return try await respond(.patch, table, []) }
        var merged = row.data
        for (k, v) in body where k != "seq" {
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
        tables[table]![key] = row
        return try await respond(.patch, table, [represent(row)])
    }

    func insertIgnoringDuplicates(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
        enter(); defer { leave() }
        let keyColumn = Self.keyColumn(for: table)
        requests.append(Request(
            verb: .insert, table: table,
            keys: rows.compactMap { $0[keyColumn] as? String }, baseSeq: nil, body: rows
        ))
        try await gate(.insert, table)
        try checkRejected(.insert, table: table, keys: rows.compactMap { $0[keyColumn] as? String })
        var inserted: [[String: Any]] = []
        for row in rows {
            guard let key = (row[keyColumn] as? String).map(Self.k) else { continue }
            if tables[table]?[key] != nil { continue }
            seqCounter += 1
            record(table: table, key: key, seq: seqCounter)
            let stored = Row(data: row, seq: seqCounter, deletedAt: nil, userId: userId)
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
        requests.append(Request(verb: .tombstone, table: table, keys: keys, baseSeq: nil, body: deletedAt))
        try await gate(.tombstone, table)
        XCTAssertEqual(keyColumn, Self.keyColumn(for: table), "wrong key column for \(table)")
        try checkRejected(.tombstone, table: table, keys: keys)
        var stamped: [[String: Any]] = []
        let stamp = Self.iso.string(from: deletedAt)
        for key in keys.map(Self.k) {
            guard var row = tables[table]?[key], row.deletedAt == nil else { continue }
            seqCounter += 1
            record(table: table, key: key, seq: seqCounter)
            row.deletedAt = stamp
            row.seq = seqCounter
            tables[table]![key] = row
            stamped.append(represent(row))
        }
        return try await respond(.tombstone, table, stamped)
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
        requests.append(Request(verb: .fetchAll, table: table, keys: [], baseSeq: afterSeq, body: nil))
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

    /// The row as PostgREST would return it: content plus `seq` and
    /// `deleted_at` (null when live), a uuid `id` rendered lowercase
    /// whatever case the client sent (measured on the local stack with an
    /// `UUID.uuidString` id; the bench scripts mint lowercase ids and never
    /// saw the difference).
    func represent(_ row: Row) -> [String: Any] {
        var out = row.data
        out["seq"] = NSNumber(value: row.seq)
        out["deleted_at"] = row.deletedAt.map { $0 as Any } ?? NSNull()
        out["user_id"] = row.userId
        if let id = out["id"] as? String, UUID(uuidString: id) != nil {
            out["id"] = id.lowercased()
        }
        return out
    }

    private static func canonical(_ data: [String: Any]) -> String {
        let content = data.filter { !metaKeys.contains($0.key) && $0.key != "deleted_at" }
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
