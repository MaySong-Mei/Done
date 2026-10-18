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
//  `sync_changes` is ordered by seq and clamped at the page limit. A uuid
//  id matches whatever its case (Postgres compares the value) and comes
//  back LOWERCASE in every response body (PostgREST renders the column),
//  which is not how the device spells it — see
//  SyncOutboundTests.testInsertResponseIdsComeBackLowercaseAndStillSetTheBaselineSeq.
//
//  Two hooks for interleavings: `failWhen` throws before a verb runs, and
//  `holdWhen` parks a verb until the test releases it — the server state the
//  verb sees is the state at RELEASE time, which is what a request built
//  before another device's write and evaluated after it looks like.
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

    private var held: [CheckedContinuation<Void, Error>] = []
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

    private func gate(_ verb: Verb, _ table: String) async throws {
        if let error = failWhen?(verb, table) { throw error }
        guard holdWhen?(verb, table) == true else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            held.append(continuation)
        }
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
        row.seq = seqCounter
        tables[table]![key] = row
        return seqCounter
    }

    // MARK: SyncGateway

    func pullChanges(sinceSeq: Int64, pageLimit: Int) async throws -> [SyncFeedRow] {
        enter(); defer { leave() }
        requests.append(Request(verb: .pull, table: "sync_changes", keys: [], baseSeq: sinceSeq, body: pageLimit))
        try await gate(.pull, "sync_changes")
        let limit = max(1, min(pageLimit, SyncGatewayLimits.maxPageLimit))
        var rows: [SyncFeedRow] = []
        for (table, byKey) in tables {
            for row in byKey.values where row.userId == userId && row.seq > sinceSeq {
                rows.append(SyncFeedRow(table: table, seq: row.seq, data: represent(row)))
            }
        }
        rows.sort { $0.seq < $1.seq }
        return Array(rows.prefix(limit))
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
        let key = Self.k(key)
        guard var row = tables[table]?[key], row.seq == baseSeq else { return [] }
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
            return []  // content-identical: no seq, no row (015 §2 `return null`)
        }
        seqCounter += 1
        row.data = merged
        row.seq = seqCounter
        tables[table]![key] = row
        return [represent(row)]
    }

    func insertIgnoringDuplicates(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
        enter(); defer { leave() }
        let keyColumn = Self.keyColumn(for: table)
        requests.append(Request(
            verb: .insert, table: table,
            keys: rows.compactMap { $0[keyColumn] as? String }, baseSeq: nil, body: rows
        ))
        try await gate(.insert, table)
        var inserted: [[String: Any]] = []
        for row in rows {
            guard let key = (row[keyColumn] as? String).map(Self.k) else { continue }
            if tables[table]?[key] != nil { continue }
            seqCounter += 1
            let stored = Row(data: row, seq: seqCounter, deletedAt: nil, userId: userId)
            tables[table, default: [:]][key] = stored
            inserted.append(represent(stored))
        }
        return inserted
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
        var stamped: [[String: Any]] = []
        let stamp = Self.iso.string(from: deletedAt)
        for key in keys.map(Self.k) {
            guard var row = tables[table]?[key], row.deletedAt == nil else { continue }
            seqCounter += 1
            row.deletedAt = stamp
            row.seq = seqCounter
            tables[table]![key] = row
            stamped.append(represent(row))
        }
        return stamped
    }

    func fetchAll(table: String, userId: String) async throws -> [[String: Any]] {
        enter(); defer { leave() }
        requests.append(Request(verb: .fetchAll, table: table, keys: [], baseSeq: nil, body: nil))
        try await gate(.fetchAll, table)
        return (tables[table] ?? [:]).values
            .filter { $0.userId == userId && $0.deletedAt == nil }
            .sorted { $0.seq < $1.seq }
            .map(represent)
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
