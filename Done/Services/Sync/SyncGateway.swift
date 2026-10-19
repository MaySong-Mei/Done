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
/// server's clamp on `page_limit` in migration 015 (survey M1(b)), held at
/// PostgREST's default `max_rows`: a client value above whichever cap the
/// server applies would read a full page as a short one and declare head
/// early (I1, survey G3). `isHead` is the one place that judgement is made.
enum SyncGatewayLimits {
    nonisolated static let defaultPageLimit = 500
    nonisolated static let maxPageLimit = 1000
    /// The `Range` window of the restore-path GET walk (`fetchAll`), held to
    /// the same cap for the same reason.
    nonisolated static let fetchAllPageSize = 1000
    /// Conditional PATCHes in flight at once during one table's flush.
    nonisolated static let maxConcurrentPatches = 8
    /// Rows per `insertIgnoringDuplicates` request.
    nonisolated static let insertChunkSize = 20

    /// Whether a page of `rowCount` rows, asked for with `requestedLimit`,
    /// is the last one: it came back shorter than the most the server would
    /// have sent. Every "this page is the head" decision goes through here,
    /// so the client cap and the comparison cannot drift apart.
    nonisolated static func isHead(rowCount: Int, requestedLimit: Int) -> Bool {
        rowCount < clampedPageLimit(requestedLimit)
    }

    /// The limit the server actually applies to a requested one.
    nonisolated static func clampedPageLimit(_ requestedLimit: Int) -> Int {
        min(max(1, requestedLimit), maxPageLimit)
    }
}

protocol SyncGateway: AnyObject {
    /// `POST /rest/v1/rpc/sync_changes {"since_seq", "page_limit"}`. Rows
    /// come back ordered by `seq`; a page shorter than the (clamped) limit
    /// means the caller is at head — judged by `SyncGatewayLimits.isHead`.
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
    /// design §6 Restore 路径): a keyset walk by `seq`, one `Range` window at
    /// a time, run by `SupabaseREST.keysetWalk` in every conformance.
    func fetchAll(table: String, userId: String) async throws -> [[String: Any]]
}
