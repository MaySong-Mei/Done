//
//  SyncGateway.swift
//  Done
//
//  The HTTP face of the sync engine, as a protocol: every verb the outbound
//  flush, the puller and the applier send, judged by the response BODY and
//  never by the status code (Docs/sync/00-realtime-sync-design.md §6
//  上传形状; bench S7 — the three conditional-PATCH outcomes are all 200).
//  `SupabaseREST` is the production conformance; tests hand in an in-memory
//  server (`SyncFakeServer`) that implements migration 015's semantics, the
//  same seam shape as `RealtimeSocket` and `AuthTransport`.
//
//  What is deliberately NOT here: `merge-duplicates` upserts and physical
//  DELETE. The new outbound path never sends either (design D6 / §6 删除段);
//  they remain on `SupabaseREST` for the legacy paths only.
//

import Foundation

/// One row of the `sync_changes` feed: which table it came from, the change
/// number that ordered it, and the full row as the server holds it (including
/// `seq` and `deleted_at`). Decoding `data` into a model is the applier's job.
struct SyncFeedRow {
    let table: String
    let seq: Int64
    let data: [String: Any]
}

/// Request-shape constants the design fixes. The page limit cap mirrors the
/// server's clamp (`least(page_limit, 2000)`): a larger client value would
/// read a full 2000-row page as a short one and declare head early (I1).
enum SyncGatewayLimits {
    nonisolated static let defaultPageLimit = 500
    nonisolated static let maxPageLimit = 2000
    /// Conditional PATCHes in flight at once during one table's flush.
    nonisolated static let maxConcurrentPatches = 8
    /// Rows per `insertIgnoringDuplicates` request.
    nonisolated static let insertChunkSize = 20
}

protocol SyncGateway: AnyObject {
    /// `POST /rest/v1/rpc/sync_changes {"since_seq", "page_limit"}`. Rows
    /// come back ordered by `seq`; a page shorter than the (clamped) limit
    /// means the caller is at head.
    func pullChanges(sinceSeq: Int64, pageLimit: Int) async throws -> [SyncFeedRow]

    /// `PATCH /rest/v1/<table>?<keyColumn>=eq.<key>&seq=eq.<baseSeq>` with
    /// `Prefer: return=representation`. `[]` means stale OR content-identical
    /// (the server's no-op short circuit returns no row either); `[row]` is
    /// the row after the write, whose `deleted_at` the caller must inspect.
    /// Never the single-object `Accept` — zero rows would become a 406.
    func patchConditional(
        table: String,
        keyColumn: String,
        key: String,
        baseSeq: Int64,
        body: [String: Any]
    ) async throws -> [[String: Any]]

    /// `POST /rest/v1/<table>` with `Prefer: resolution=ignore-duplicates,
    /// return=representation`. Returns exactly the rows that were inserted
    /// (bench S8); a row whose key already existed is absent from the result
    /// and untouched on the server.
    func insertIgnoringDuplicates(table: String, rows: [[String: Any]]) async throws -> [[String: Any]]

    /// `PATCH /rest/v1/<table>?<keyColumn>=in.(…)&deleted_at=is.null` with
    /// body `{"deleted_at": <iso>}`. Returns the rows it stamped; a row that
    /// was already tombstoned is filtered out by the request and absent from
    /// the result (bench S9). Callers judge the baseline by whether this
    /// THREW, never by the body (design §6 删除段).
    func tombstone(
        table: String,
        keyColumn: String,
        keys: [String],
        deletedAt: Date
    ) async throws -> [[String: Any]]

    /// Restore-path GET of every LIVE row the user owns (`deleted_at=is.null`,
    /// design §6 Restore 路径). Paged through PostgREST `Range` windows.
    func fetchAll(table: String, userId: String) async throws -> [[String: Any]]
}
