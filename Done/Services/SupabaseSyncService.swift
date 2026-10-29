import Foundation
import Combine
import CryptoKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Sync"
)

// MARK: - Configuration

enum SupabaseSyncConfig {
    /// The project this process talks to, decided once per process by
    /// `SupabaseEnvironment.current` (design D8): production unless the
    /// build is Staging or a DEBUG launch asked for another project. The
    /// names stay so the four clients that read them need not change.
    nonisolated static var url: String { SupabaseEnvironment.current.url }
    /// Project key for the `apikey` HTTP header. ONLY identifies the
    /// Supabase project — the `Authorization` header carries the
    /// per-user JWT, so RLS enforces row access.
    ///
    /// Modern publishable key (`sb_publishable_…`): public by design,
    /// safe to commit and ship. It replaced the hardcoded service_role
    /// JWT that leaked through this public repo — incident record and
    /// rotation checklist in gh#232.
    nonisolated static var publishableKey: String { SupabaseEnvironment.current.publishableKey }
    nonisolated static let debounceSeconds: TimeInterval = 2.0
    /// The settings sink's longer quiet period: `didChangeNotification`
    /// fires on every `UserDefaults` write in the app, synced key or not.
    nonisolated static let settingsDebounceSeconds: TimeInterval = 5.0
    /// How long a row may keep meeting PostgREST's schema-cache errors
    /// (`PGRST2xx`) before they are taken as a refusal (survey S1): the
    /// attempts bound AND the time bound must each be passed — enough
    /// flushes, and enough time for a `NOTIFY pgrst, 'reload schema'` to
    /// have happened.
    nonisolated static let schemaCacheRetryAttempts = 3
    nonisolated static let schemaCacheRetryWindowSeconds: TimeInterval = 600
}

/// The `UserDefaults` key the JSON-encoded `[AgentConversation]` blob USED to
/// live under. It is a migration source now, read once by
/// `AgentConversationRepository` and thereafter dead data — never updated,
/// never deleted, because the untouched blob is what a downgraded binary lands
/// on. The single exception is "reset all local data", where leaving it would
/// resurrect the very conversations the user asked to erase.
let AgentConversationsStorageKey = "agentConversations"

// MARK: - Supabase REST Client (minimal, no SDK dependency)

/// Thin REST client for Supabase PostgREST. No external dependencies.
///
/// **Auth**: every request goes out with two headers:
///   - `apikey: <projectAPIKey>` — identifies the Supabase project
///   - `Authorization: Bearer <user_jwt>` — identifies the signed-in user
///
/// This is the user-JWT auth pattern that mirrors `SupabaseImageStorageService`.
/// Server-side RLS policies (`auth.uid() = user_id`) enforce that the request
/// can only touch rows belonging to the signed-in user. Earlier versions
/// sent `service_role` JWT in both headers, which bypassed RLS entirely
/// — see issue #28 for the migration audit.
///
/// Token refresh: every request first calls `authService.refreshTokenIfNeeded()`
/// so a session that's <5 min from expiry rotates before we hit the wire.
/// A 401 then triggers one retry after `refreshTokenIfNeeded()` runs again,
/// for the rare race where the token expired between our pre-emptive check
/// and the actual request.
///
/// The `SyncGateway` conformance is the production face of the sync engine
/// (design §6 上传形状). The pre-D6 `upsert` (`merge-duplicates`) and
/// physical `delete` verbs are gone: no caller, and no `X-Sync-Epoch`
/// (`SyncError.upsertFailed` / `deleteFailed` stay for the classifier).
final class SupabaseREST: SyncGateway {
    private let baseURL: String
    /// Project anon/service-role key — only used for the `apikey` HTTP
    /// header (routing / project identity). Authorization always uses the
    /// per-user JWT from `authService`.
    private let projectAPIKey: String
    private weak var authService: AuthService?

    /// The gate's two messages (migration 015 `trg_<t>_sync_gate`, design
    /// §6.6 服务端写闸), matched in the 400 body's `message`.
    nonisolated static let gateStaleMessage = "sync_epoch_stale"
    nonisolated static let gatePausedMessage = "sync_paused"
    /// The header every table write carries (design §6.6); not sent while
    /// nil, and never on the RPC / GET reads.
    nonisolated static let epochHeaderField = "X-Sync-Epoch"

    /// Set by the engine (`SyncPuller`) when it records or changes the
    /// device's epoch. Read on the main actor by every write.
    var writeEpoch: String?

    init(url: String, projectAPIKey: String, authService: AuthService?) {
        self.baseURL = url
        self.projectAPIKey = projectAPIKey
        self.authService = authService
    }

    // MARK: - Auth helpers

    /// Pre-emptive refresh + read of the current user JWT. Throws when no
    /// session is established (the caller is responsible for blocking the
    /// upload pipeline until sign-in completes).
    private func userToken() async throws -> String {
        await authService?.refreshTokenIfNeeded()
        guard let token = authService?.accessToken, !token.isEmpty else {
            throw SyncError.notSignedIn
        }
        return token
    }

    /// Pass-once dispatcher: run `body` with a fresh user token; on 401
    /// the inner closure can throw a marker that triggers a single
    /// refresh-and-retry. Subsequent failures bubble up as `httpFailure`.
    private func withTokenRetry<T>(
        _ body: (_ token: String) async throws -> T
    ) async throws -> T {
        let token = try await userToken()
        do {
            return try await body(token)
        } catch SyncError.tokenExpired {
            // Force a refresh — `refreshTokenIfNeeded` is pre-emptive and
            // may have just returned without doing anything (the cached
            // session still looked fine to it). A real 401 means the
            // server disagreed, so force-rotate.
            await authService?.forceRefreshToken()
            let retried = try await userToken()
            return try await body(retried)
        }
    }

    private func authorizationHeader(_ token: String) -> String { "Bearer \(token)" }

    // MARK: - SyncGateway (design §6 上传形状)

    /// RFC 3986 unreserved characters only; everything else is percent-
    /// encoded. Occurrence-key ids carry `|`, which PostgREST accepts raw or
    /// encoded (bench S9) — encoding keeps `URL(string:)` honest.
    nonisolated private static let filterValueAllowed: CharacterSet =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    nonisolated static func encodeFilterValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: filterValueAllowed) ?? value
    }

    /// The restore-path query: the user's rows, LIVE rows only, in seq
    /// order, after `afterSeq` (the last seq the previous page held). Pure so
    /// the filter is pinned by a test without a network.
    ///
    /// Why a keyset walk and not `Range` windows: without an ORDER BY,
    /// Postgres owes no stable order from one window's query to the next
    /// (a synchronized scan may start mid-table), so a restore wider than one
    /// window could skip or repeat rows. Ordering by `seq` and continuing
    /// after the last seq read also holds while another device writes during
    /// the walk: a row rewritten mid-walk takes a higher seq and is read
    /// again further on (`dedupeFetchedRows` keeps that later copy), and no
    /// row is skipped because nothing shifts under an offset.
    nonisolated static func fetchAllQuery(table: String, userId: String, afterSeq: Int64? = nil) -> String {
        var query = "\(table)?user_id=eq.\(encodeFilterValue(userId))&deleted_at=is.null&order=seq.asc"
        if let afterSeq { query += "&seq=gt.\(afterSeq)" }
        return query
    }

    /// The highest `seq` on a page, as PostgREST renders it (a JSON number).
    nonisolated static func lastSeq(of page: [[String: Any]]) -> Int64? {
        page.compactMap { ($0["seq"] as? NSNumber)?.int64Value }.max()
    }

    /// One row per key across a keyset walk, the copy read LAST winning (it
    /// carries the higher seq), in the order the walk first met each key.
    /// The key is `id`, or `user_id` for the single-row tables.
    nonisolated static func dedupeFetchedRows(_ rows: [[String: Any]]) -> [[String: Any]] {
        var order: [String] = []
        var latest: [String: [String: Any]] = [:]
        var keyless: [[String: Any]] = []
        for row in rows {
            guard let key = (row["id"] as? String) ?? (row["user_id"] as? String) else {
                keyless.append(row)
                continue
            }
            let match = SyncBaselineKey.matchKey(key)
            if latest[match] == nil { order.append(match) }
            latest[match] = row
        }
        return order.compactMap { latest[$0] } + keyless
    }

    nonisolated static func conditionalPatchQuery(table: String, keyColumn: String, key: String, baseSeq: Int64) -> String {
        "\(table)?\(keyColumn)=eq.\(encodeFilterValue(key))&seq=eq.\(baseSeq)"
    }

    nonisolated static func tombstoneQuery(table: String, keyColumn: String, keys: [String]) -> String {
        let joined = keys.map(encodeFilterValue).joined(separator: ",")
        return "\(table)?\(keyColumn)=in.(\(joined))&deleted_at=is.null"
    }

    func pullChanges(sinceSeq: Int64, pageLimit: Int) async throws -> [SyncFeedRow] {
        let limit = SyncGatewayLimits.clampedPageLimit(pageLimit)
        let body: [String: Any] = ["since_seq": NSNumber(value: sinceSeq), "page_limit": limit]
        let data = try await send(
            method: "POST", path: "rpc/sync_changes", body: body,
            headers: ["Content-Type": "application/json"], table: "sync_changes", isWrite: false
        )
        let rows = try Self.decodeRows(data, table: "sync_changes")
        return rows.compactMap { row in
            guard let table = row["tbl"] as? String,
                  let seq = (row["seq"] as? NSNumber)?.int64Value,
                  let payload = row["data"] as? [String: Any]
            else { return nil }
            return SyncFeedRow(table: table, seq: seq, data: payload)
        }
    }

    nonisolated static let syncEpochQuery = "sync_epoch?select=epoch,paused,restores"

    func fetchSyncEpoch() async throws -> SyncEpochRow {
        let data = try await send(method: "GET", path: Self.syncEpochQuery, body: nil, headers: [:],
                                  table: "sync_epoch", isWrite: false)
        let rows = try Self.decodeRows(data, table: "sync_epoch")
        guard let row = Self.decodeEpochRow(rows) else { throw SyncError.malformedResponse(table: "sync_epoch") }
        return row
    }

    /// Exactly one row with an `epoch`; the ledger's unreadable records are
    /// dropped (a record without `kept_max` cannot bound anything).
    nonisolated static func decodeEpochRow(_ rows: [[String: Any]]) -> SyncEpochRow? {
        guard rows.count == 1, let row = rows.first, let epoch = row["epoch"] as? String else { return nil }
        let paused = (row["paused"] as? Bool) ?? ((row["paused"] as? NSNumber)?.boolValue ?? false)
        let restores = (row["restores"] as? [[String: Any]] ?? []).compactMap(SyncRestoreRecord.init(json:))
        return SyncEpochRow(epoch: epoch, paused: paused, restores: restores)
    }

    func isAncestor(table: String, id: String, a: String, b: String) async throws -> Bool? {
        let body: [String: Any] = ["p_tbl": table, "p_id": id, "a": a, "b": b]
        let data = try await send(method: "POST", path: "rpc/is_ancestor", body: body,
                                  headers: ["Content-Type": "application/json"], table: "is_ancestor", isWrite: false)
        return try Self.decodeAncestry(data)
    }

    /// The RPC answers a bare JSON scalar: `true`, `false` or `null`.
    nonisolated static func decodeAncestry(_ data: Data) throws -> Bool? {
        guard !data.isEmpty else { return nil }
        let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if parsed is NSNull { return nil }
        if let number = parsed as? NSNumber { return number.boolValue }
        if let text = parsed as? String {
            if text == "true" { return true }
            if text == "false" { return false }
            return nil
        }
        throw SyncError.malformedResponse(table: "is_ancestor")
    }

    func patchConditional(
        table: String,
        keyColumn: String,
        key: String,
        baseSeq: Int64,
        body: [String: Any]
    ) async throws -> [[String: Any]] {
        let data = try await send(
            method: "PATCH",
            path: Self.conditionalPatchQuery(table: table, keyColumn: keyColumn, key: key, baseSeq: baseSeq),
            body: body,
            headers: ["Content-Type": "application/json", "Prefer": "return=representation"],
            table: table, isWrite: true
        )
        return try Self.decodeRows(data, table: table)
    }

    func insertIgnoringDuplicates(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
        guard !rows.isEmpty else { return [] }
        let data = try await send(
            method: "POST",
            path: table,
            body: rows,
            headers: [
                "Content-Type": "application/json",
                "Prefer": "resolution=ignore-duplicates, return=representation",
            ],
            table: table, isWrite: true
        )
        return try Self.decodeRows(data, table: table)
    }

    func tombstone(
        table: String,
        keyColumn: String,
        keys: [String],
        deletedAt: Date
    ) async throws -> [[String: Any]] {
        guard !keys.isEmpty else { return [] }
        let data = try await send(
            method: "PATCH",
            path: Self.tombstoneQuery(table: table, keyColumn: keyColumn, keys: keys),
            body: ["deleted_at": Self.iso.string(from: deletedAt)],
            headers: ["Content-Type": "application/json", "Prefer": "return=representation"],
            table: table, isWrite: true
        )
        return try Self.decodeRows(data, table: table)
    }

    func upsertMerging(table: String, keyColumn: String, rows: [[String: Any]]) async throws {
        guard !rows.isEmpty else { return }
        _ = try await send(
            method: "POST",
            path: "\(table)?on_conflict=\(keyColumn)",
            body: rows,
            headers: ["Content-Type": "application/json", "Prefer": "resolution=merge-duplicates, return=minimal"],
            table: table, isWrite: true
        )
    }

    func upsertRows(table: String, rows: [[String: Any]], onConflict: [String]) async throws {
        guard !rows.isEmpty else { return }
        _ = try await send(
            method: "POST",
            path: "\(table)?on_conflict=\(onConflict.joined(separator: ","))",
            body: rows,
            headers: ["Content-Type": "application/json", "Prefer": "resolution=merge-duplicates,return=minimal"],
            table: table,
            // `isWrite: false` here means "no `X-Sync-Epoch`", not "a read":
            // the telemetry table is outside the 015 gate (wire contract §1).
            isWrite: false,
            // A refused telemetry row's PostgREST `details` is "Failing row
            // contains (…)" — the row itself, `note` included. Log the
            // status and `code` only (review P2-12).
            logsResponseBody: false
        )
    }

    /// gh#273 §16 rule 3: one page of this account's observatory rows from
    /// `v_my_spike_runs` (RLS: own rows only), release only, on or after
    /// `sinceDayKey` (review P1-3), in the view's stable order, paged by
    /// `TelemetryCloudPager`. A read: no epoch header, and a refusal logs
    /// status and code only (the rows are the user's).
    func fetchMySpikeRunsPage(spikeIDs: [String], sinceDayKey: String, limit: Int, offset: Int) async throws -> [[String: Any]] {
        let table = "v_my_spike_runs"
        let path = "\(table)?select=*&build_configuration=eq.release&spike_id=in.(\(spikeIDs.joined(separator: ",")))"
            + "&day_key=gte.\(sinceDayKey)&order=day_key.desc,run_id.asc&limit=\(limit)&offset=\(offset)"
        let data = try await send(method: "GET", path: path, body: nil, headers: [:], table: table,
                                  isWrite: false, logsResponseBody: false)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SyncError.malformedResponse(table: table)
        }
        return rows
    }

    func deletePhysically(table: String, keyColumn: String, keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        _ = try await send(
            method: "DELETE",
            path: Self.deleteQuery(table: table, keyColumn: keyColumn, keys: keys),
            body: nil,
            headers: ["Prefer": "return=minimal"],
            table: table, isWrite: true
        )
    }

    nonisolated static func deleteQuery(table: String, keyColumn: String, keys: [String]) -> String {
        "\(table)?\(keyColumn)=in.(\(keys.map(encodeFilterValue).joined(separator: ",")))"
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One authenticated request. 401 takes the refresh-and-retry hop; any
    /// other non-2xx becomes `requestFailed` carrying PostgREST's `code`
    /// (the `40P01` deadlock victim is retried once by the caller, §9.17).
    private func send(
        method: String,
        path: String,
        body: Any?,
        headers: [String: String],
        table: String,
        isWrite: Bool,
        logsResponseBody: Bool = true
    ) async throws -> Data {
        let epochHeader = isWrite ? writeEpoch : nil
        #if DEBUG
        // The harness's offline switch (design §8.4): checked before the
        // token step so that nothing — not even a refresh — goes out.
        try SyncOfflineSwitch.checkOnline()
        #endif
        return try await withTokenRetry { token in
            guard let url = URL(string: "\(self.baseURL)/rest/v1/\(path)") else {
                throw SyncError.requestFailed(table: table, method: method, status: -1, code: nil)
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(self.projectAPIKey, forHTTPHeaderField: "apikey")
            request.setValue(self.authorizationHeader(token), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let epochHeader {
                request.setValue(epochHeader, forHTTPHeaderField: Self.epochHeaderField)
            }
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.requestFailed(table: table, method: method, status: -1, code: nil)
            }
            if http.statusCode == 401 { throw SyncError.tokenExpired }
            guard (200..<300).contains(http.statusCode) else {
                if logsResponseBody {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    logger.error("\(method, privacy: .public) \(table, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(text.prefix(200), privacy: .public)")
                } else {
                    let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["code"] as? String ?? "-"
                    logger.error("\(method, privacy: .public) \(table, privacy: .public) HTTP \(http.statusCode, privacy: .public) code=\(code, privacy: .public)")
                }
                throw Self.requestError(table: table, method: method, status: http.statusCode, body: data)
            }
            return data
        }
    }

    /// The error a non-2xx answer becomes: `requestFailed` with PostgREST's
    /// `code`, except a `23503` whose constraint is a `user_id` foreign key
    /// (design §6.4, judged by the constraint name), which is
    /// `accountMissing`. Pure, so a test feeds it PostgREST's error body.
    nonisolated static func requestError(table: String, method: String, status: Int, body: Data) -> SyncError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = object?["code"] as? String
        let message = object?["message"] as? String
        if code == "23503", let constraint = userIdForeignKeyConstraint(message: message) {
            return .accountMissing(table: table, method: method, constraint: constraint)
        }
        if let reason = gateRejection(status: status, message: message) {
            return .gateRejected(table: table, method: method, reason: reason)
        }
        if code == "PGRST204", let column = missingColumn(message: message) {
            return .missingColumn(table: table, method: method, column: column)
        }
        return .requestFailed(table: table, method: method, status: status, code: code)
    }

    /// The column a `PGRST204` names: PostgREST's schema cache has no such
    /// column on the table ("Could not find the 'domino_anchor' column of
    /// 'events' in the schema cache") — a server without migration 015.
    nonisolated static func missingColumn(message: String?) -> String? {
        guard let message,
              let marker = message.range(of: "find the '"),
              let close = message[marker.upperBound...].firstIndex(of: "'")
        else { return nil }
        let name = String(message[marker.upperBound..<close])
        return name.isEmpty ? nil : name
    }

    /// The write gate's refusal, judged by the message (design §6.6: the
    /// errcode is the generic `P0001`): the stale message wins when both
    /// appear, as the gate checks the epoch first.
    nonisolated static func gateRejection(status: Int, message: String?) -> String? {
        guard status == 400, let message else { return nil }
        if message.contains(gateStaleMessage) { return gateStaleMessage }
        if message.contains(gatePausedMessage) { return gatePausedMessage }
        return nil
    }

    /// The constraint a foreign-key violation's message names, when it is a
    /// table's `user_id` reference to `auth.users`: every synced table
    /// declares it inline, so Postgres names it `<table>_user_id_fkey`.
    /// Any other foreign key is an ordinary refusal.
    nonisolated static func userIdForeignKeyConstraint(message: String?) -> String? {
        guard let message,
              let marker = message.range(of: "foreign key constraint \""),
              let close = message[marker.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let name = String(message[marker.upperBound..<close])
        return name.hasSuffix("_user_id_fkey") ? name : nil
    }

    /// `return=representation` bodies are JSON arrays; an empty body (a
    /// 204 from a verb that happened not to return) reads as no rows.
    nonisolated private static func decodeRows(_ data: Data, table: String) throws -> [[String: Any]] {
        if data.isEmpty { return [] }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let rows = parsed as? [[String: Any]] else {
            throw SyncError.malformedResponse(table: table)
        }
        return rows
    }

    /// Fetch all LIVE rows for a given user_id. PostgREST caps a single
    /// response, so the walk asks for one window at a time in seq order,
    /// each continuing after the last seq the previous one held, until a
    /// short page arrives (see `fetchAllQuery` for why it is keyset).
    ///
    /// Note: with RLS now enforcing `auth.uid() = user_id`, the
    /// `?user_id=eq.X` query parameter is technically redundant — the
    /// server would filter to the JWT's user_id anyway. Kept it as belt-
    /// and-suspenders / explicit-intent + back-compat with any caller
    /// that passed a different ID expecting service_role bypass.
    /// `deleted_at=is.null` is not redundant: without it a restore after
    /// migration 015 brings tombstoned rows back as live ones (bench S11).
    func fetchAll(table: String, userId: String) async throws -> [[String: Any]] {
        guard !userId.isEmpty else { return [] }
        let pageSize = SyncGatewayLimits.fetchAllPageSize
        return try await Self.keysetWalk(table: table, pageSize: pageSize) { afterSeq in
            #if DEBUG
            try SyncOfflineSwitch.checkOnline()
            #endif
            let urlStr = "\(self.baseURL)/rest/v1/\(Self.fetchAllQuery(table: table, userId: userId, afterSeq: afterSeq))"
            guard let url = URL(string: urlStr) else {
                throw SyncError.fetchFailed(table: table, status: -1)
            }
            return try await self.withTokenRetry { token in
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(self.projectAPIKey, forHTTPHeaderField: "apikey")
                request.setValue(self.authorizationHeader(token), forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("0-\(pageSize - 1)", forHTTPHeaderField: "Range")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SyncError.fetchFailed(table: table, status: -1)
                }
                // PostgREST answers 416 for a Range past the end of the result
                // set; every window here starts at 0, so it can only mean an
                // empty remainder.
                if http.statusCode == 416 { return [] }
                if http.statusCode == 401 { throw SyncError.tokenExpired }
                guard (200..<300).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    logger.error("Fetch \(table, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(body.prefix(200), privacy: .public)")
                    throw SyncError.fetchFailed(table: table, status: http.statusCode)
                }
                let parsed = try JSONSerialization.jsonObject(with: data)
                return (parsed as? [[String: Any]]) ?? []
            }
        }
    }

    /// Rows a restore walk reads before it stops asking, for a server that
    /// keeps answering full windows.
    nonisolated static let keysetWalkSafetyCap = 100_000

    /// The restore walk itself, apart from how one window is fetched, so the
    /// loop that runs against PostgREST is the loop the fake server runs in
    /// tests: ask `window` for the rows after `afterSeq` (nil: from the
    /// start), stop at the first window that reads as the last
    /// (`SyncGatewayLimits.isHead`), otherwise continue after the highest
    /// seq that window held. A full window with no readable seq cannot be
    /// continued from and throws, rather than hand the restore a silently
    /// partial set. Rows read twice (rewritten during the walk) come back
    /// once, the later copy winning (`dedupeFetchedRows`).
    static func keysetWalk(
        table: String,
        pageSize: Int,
        safetyCap: Int = keysetWalkSafetyCap,
        window: (_ afterSeq: Int64?) async throws -> [[String: Any]]
    ) async throws -> [[String: Any]] {
        var afterSeq: Int64?
        var allRows: [[String: Any]] = []
        while true {
            let pageRows = try await window(afterSeq)
            allRows.append(contentsOf: pageRows)
            if SyncGatewayLimits.isHead(rowCount: pageRows.count, requestedLimit: pageSize) { break }
            guard let next = lastSeq(of: pageRows) else {
                logger.error("fetchAll \(table, privacy: .public): full page without seq; cannot continue the walk")
                throw SyncError.malformedResponse(table: table)
            }
            afterSeq = next
            if allRows.count >= safetyCap {
                logger.notice("fetchAll \(table, privacy: .public) safety cap hit at \(allRows.count, privacy: .public)")
                break
            }
        }
        return dedupeFetchedRows(allRows)
    }

    enum SyncError: Error, LocalizedError {
        case upsertFailed(table: String, status: Int)
        case deleteFailed(table: String, status: Int)
        case fetchFailed(table: String, status: Int)
        /// Any `SyncGateway` verb that came back non-2xx. `code` is
        /// PostgREST's error code from the body when it carried one.
        case requestFailed(table: String, method: String, status: Int, code: String?)
        /// A 2xx whose body was not the JSON array `return=representation`
        /// promises. Treated like a failure: nothing is written to the baseline.
        case malformedResponse(table: String)
        /// A `23503` on the `user_id` foreign key: the account may no longer
        /// exist (design §6.4). `constraint` is the name the body carried.
        case accountMissing(table: String, method: String, constraint: String)
        /// The server's write gate refused the request (design §6.6):
        /// `reason` is `sync_epoch_stale` or `sync_paused`, from the body's
        /// message. The write did not run.
        case gateRejected(table: String, method: String, reason: String)
        /// A `PGRST204`: the body named a column the server's schema does
        /// not have (`column`, read from the message). A server without
        /// migration 015 answers this for every 015 column a write carries.
        case missingColumn(table: String, method: String, column: String)
        case notSignedIn
        /// 401 marker used by `withTokenRetry` for the in-band refresh-and-
        /// retry hop. Almost always handled there; bubbles to the caller
        /// only when a SECOND 401 hits after a force-refresh succeeded
        /// (account deleted mid-session, key rotated server-side, or RLS
        /// rejected the new token). User-visible at that point — the
        /// description below is what they'll see.
        case tokenExpired

        var errorDescription: String? {
            switch self {
            case .upsertFailed(let t, let s): return "Upsert to \(t) failed (HTTP \(s))"
            case .deleteFailed(let t, let s): return "Delete from \(t) failed (HTTP \(s))"
            case .fetchFailed(let t, let s): return "Fetch from \(t) failed (HTTP \(s))"
            case .requestFailed(let t, let m, let s, let c):
                return "\(m) \(t) failed (HTTP \(s)\(c.map { ", \($0)" } ?? ""))"
            case .malformedResponse(let t): return "\(t): unexpected response body"
            case .accountMissing(let t, let m, let c): return "\(m) \(t) failed: the account may no longer exist (\(c))"
            case .gateRejected(let t, let m, let r): return "\(m) \(t) refused by the sync gate (\(r))"
            case .missingColumn(let t, let m, let c): return "\(m) \(t) failed: the server has no column \(c) (PGRST204)"
            case .notSignedIn: return "Cannot reach Supabase: not signed in."
            case .tokenExpired: return "Session expired — please sign in again."
            }
        }
    }
}

// MARK: - Row Hashing (for diff-based sync)

/// Keys whose values are side-channel timestamps, not content. Excluding them
/// from `rowHash` makes the hash actually reflect the row's data, so the
/// diff-sync can detect "nothing changed" instead of treating every emission
/// as a change (every row builder stamps `synced_at` from the scheduler clock, and
/// for events / event_types also for `updated_at`).
private let rowHashIgnoredKeys: Set<String> = ["synced_at", "updated_at"]

/// Compute a stable hash for a row dictionary so we can detect changes.
///
/// **Cross-process determinism is load-bearing now that hashes are persisted
/// (#30).** Swift's `String(describing:)` on a `Dictionary` walks its
/// underlying hash table in random order — fine within one process, but two
/// runs of the same row will produce two different strings (and therefore
/// two different hashes), causing every relaunch to treat every nested-dict
/// row as "changed". Pre-#30 this was a non-issue because every relaunch
/// started with empty hash maps anyway; post-#30 it caused `user_settings`
/// to enter an infinite re-upload loop (settings has a deep nested dict;
/// upload writes UserDefaults; didChangeNotification fires; debounce arms;
/// 5s later the same data hashes to a *different* value; upload again …).
///
/// Fix: serialize nested arrays/dicts via `JSONSerialization` with
/// `.sortedKeys`, which produces canonical ordering. Scalars
/// (`String`/`Bool`/`Int`/`NSNumber`) keep `String(describing:)` — their
/// representation is already deterministic.
///
/// Reachable as `SupabaseSyncService.rowHash` so the seed fingerprint and
/// the tests hash through the one function the flush hashes through.
private func syncRowHash(_ row: [String: Any]) -> String {
    // Sort keys for deterministic output
    let sorted = row.keys.sorted()
    var parts: [String] = []
    for key in sorted where !rowHashIgnoredKeys.contains(key) {
        let val = row[key]
        if val is NSNull {
            parts.append("\(key):null")
        } else {
            parts.append("\(key):\(canonicalDescription(val!))")
        }
    }
    return sha256Prefix(parts.joined(separator: "|"))
}

/// One settings key's hash — the same canonical form as a row cell, so the
/// per-key baseline of `user_settings` (design §6.3) cannot drift from the
/// row hash it replaced.
private func syncValueHash(_ value: Any) -> String {
    if value is NSNull { return sha256Prefix("null") }
    return sha256Prefix(canonicalDescription(value))
}

private func sha256Prefix(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// Deterministic string form for a single row-cell value. Falls back to
/// `String(describing:)` for primitives (already deterministic) and uses
/// sorted-key JSON for nested dicts/arrays. See the long comment on
/// `rowHash` for why this matters.
private func canonicalDescription(_ value: Any) -> String {
    // Nested JSON-shaped values must serialize with deterministic key order.
    if value is [String: Any] || value is [Any] {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.sortedKeys]
           ),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
    }
    return String(describing: value)
}

// MARK: - Sync Service

/// What this session's pulls showed about migration 015 (the change feed).
nonisolated enum SyncFeedAvailability: Equatable, Sendable {
    case unknown
    case available
    case unavailable
}

/// The legacy "Restore from Cloud" offer after a sign-in (design §7 Phase 1).
nonisolated enum AutoRestoreOfferDecision: Equatable, Sendable {
    /// Today's behaviour: offer it if the device looks empty.
    case offer
    /// Not yet known whether the feed exists; decide when the pull answers.
    case wait
    /// The feed exists: the pull loads the account, no sheet.
    case retired
}

/// Observes EventStore + related stores via Combine and publishes local
/// changes to Supabase as the change log of this account (design D6 / §6
/// 上传形状): a dirty row whose server version is known goes out as a
/// conditional PATCH, a row without one as an ignore-duplicates POST, a
/// locally removed row as a tombstone PATCH. The (hash, seq) baseline
/// (`SyncBaselineStore`) is what "dirty" and "known version" mean; it is
/// shared with the inbound applier, which replays it after every apply.
@MainActor
final class SupabaseSyncService: ObservableObject {
    /// The HTTP seam. Constructed as a placeholder (no `AuthService`), then
    /// replaced in `attach()` with the real client; an injected gateway
    /// (tests) is kept across `attach`.
    private var gateway: SyncGateway
    private let gatewayIsInjected: Bool
    /// Where the baseline, the cursor and the settings snapshot live.
    /// `.standard` in the app; a suite in tests.
    let defaults: UserDefaults
    /// The clock the outbound debounce runs on (survey M6(4)): the main run
    /// loop in the app, a manual clock in tests.
    let scheduler: SyncScheduler
    /// Rows whose tombstone waits out an undo prompt (design §10.6 (A)).
    let undoHold: SyncUndoHold
    private(set) var userId: String = ""
    private weak var authService: AuthService?
    /// Optional callback for UI sync-status reporting. Wired from
    /// `ContentView` at attach time; nil-tolerant so the service still works
    /// in tests / standalone contexts without reporter plumbing.
    weak var statusReporter: SyncStatusReporter?

    /// Cached store references so `userDidEnableUploads()` can run a fresh
    /// `fullSync` without re-attaching the Combine pipeline. Set in `attach`,
    /// nilled implicitly by weak semantics if the stores go away.
    private weak var attachedEventStore: EventStore?
    private weak var attachedEventTypeStore: EventTypeTemplateStore?
    private weak var attachedSkillStore: SkillInsightStore?
    private weak var attachedPreferenceStore: AgentPreferenceStore?

    private var cancellables = Set<AnyCancellable>()

    // MARK: Engine state shared with the puller / applier

    /// The (hash, seq) baseline for the signed-in user (design §6.3). The
    /// applier writes it after each slot commit; this service reads it at
    /// flush time and writes it after each response.
    private(set) var baseline: SyncBaselineStore
    /// The pull cursor for the signed-in user. Owned by the puller; held
    /// here because it shares the user scope and the sign-out reset.
    private(set) var cursor: SyncCursorStore
    /// Rows whose conditional PATCH came back `[]` and await an eligible
    /// head pull (design §6 上传形状 "`[]` 的收口"). In memory only.
    private(set) var pendingVerify = PendingVerifySet()
    /// Rows POSTed with ignore-duplicates that the response did not return:
    /// the server already had them, and their seq arrives with the echo.
    /// Still here after a head pull → `sync.push.orphan` (a UUID collision
    /// under another account), see `orphansAfterHeadPull()`.
    private(set) var awaitingEcho: Set<SyncBaselineKey> = []
    /// Remote reference zones this session already logged a
    /// `sync.conflict key=zone` for (design §6.2: once per session per
    /// remote value). Owned by the applier; dropped with the session.
    var zoneConflictsLogged: Set<String> = []
    /// Rows the server refused, by the version it refused (survey S1).
    /// Persisted per user; not resent while the local hash is unchanged.
    private(set) var rejected: SyncRejectedSet
    /// First sighting and count of schema-cache failures per row, for the
    /// bounded retry window. In memory: a relaunch restarts the window.
    private var schemaCacheFailures: [SyncBaselineKey: (first: Date, attempts: Int)] = [:]
    /// S12's detection half (design §6.4): set when a write meets the
    /// `user_id` foreign key and by the forced refresh that follows. The
    /// account card can read it; nothing here acts on local data.
    @Published private(set) var accountCheck: SyncAccountCheck = .none
    /// What the user chose once `accountCheck` was terminal (design §10.7).
    /// Written only by `chooseAfterAccountGone`.
    @Published var accountGoneChoice: SyncAccountGoneChoice?
    /// Where the terminal state and the choice outlive the process (QA S6:
    /// after a relaunch the account card fell back to the generic "signed
    /// out" one and lost "upload it to the next account"). Account state,
    /// not baseline: outside the `syncHashes.` prefix, swept by the erase by
    /// name (`AppSettingsKeys.resettableUserDefaultsKeys`), and removed by
    /// the next sign-in (`beginSession`).
    nonisolated static let accountGoneTableKey = "syncAccountGone.table"
    nonisolated static let accountGoneChoiceKey = "syncAccountGone.choice"
    /// The forced token refresh that detection asks for. Nil in the app:
    /// the attached `AuthService` is asked (`forceRefresh(_:)`). A test
    /// hands in its own.
    var tokenRefresher: (() async -> SyncTokenRefreshOutcome)?
    private var accountRefreshInFlight = false
    /// Whose data this device holds (survey S5). `.blocked` stops every
    /// pull and push; the account card reads it.
    @Published private(set) var ownerState: SyncOwnerState = .signedOut
    /// The blocked sign-in did not switch on its own because the owner's
    /// data on this device still owes the cloud this many changes
    /// (`unsyncedChanges(owner:)`); the account card asks. Nil otherwise.
    @Published private(set) var ownerUnsyncedChanges: Int?
    /// The erase "switch to this account" runs when the owner's data is all
    /// in the cloud (`switchAutomaticallyIfOwnerSynced`): the app hands in
    /// `LocalDataEraser.resetAllLocalData(keepingSession: true)` before it
    /// attaches. Nil — no automatic switch; the card asks as before.
    var ownerSwitchEraser: (@MainActor () -> Void)?
    /// The owner guard's record beside the data (`SyncOwnerRecord`): the
    /// app hands in `.production`. Nil — the defaults key only.
    let ownerRecord: SyncOwnerRecord?
    /// The held switch's alert over the main screen (staging QA round 7,
    /// observation 1: the card alone sat under Me → gear → Account and the
    /// app opened with no signal). N while it should show; the root view
    /// presents it and clears it. At most once per launch: the session sink
    /// runs again on every token refresh and return to the foreground, and
    /// the card keeps asking after the alert is gone.
    @Published var heldSwitchAlert: Int?
    /// How many times this launch presented it (`presentHeldSwitchAlert`).
    private(set) var heldSwitchAlertsPresented = 0
    /// What this session's pulls showed about migration 015 (the feed):
    /// set by the puller, back to `.unknown` with every new session. The
    /// legacy restore offer reads it (`autoRestoreOfferDecision`).
    @Published private(set) var feedAvailability: SyncFeedAvailability = .unknown
    /// The last snapshot `fetchRestoreSnapshot` returned, for
    /// `markRestoreCompleted` (survey S6). Cleared once it is replayed.
    var lastRestoreSnapshot: RestoreSnapshot?

    /// I1, read at flush time: whether this session has pulled to head
    /// (last page shorter than `page_limit`, no refused page since). While
    /// false, every flush returns without sending — a row whose baseline
    /// the applier has not written yet must not be pushed as dirty. The
    /// puller flips it: false when its session begins, true at head, and
    /// true again when the feed is unavailable (design §7 (7), the seat
    /// belt). True until a puller begins a session, so the outbound path
    /// works standalone (every outbound test, and a build with no puller).
    var inboundAtHead: Bool = true

    /// Asked for after a flush that received `[]` (pending-verify) or hit a
    /// dead row — the engine's pull is what clears both.
    var onNeedsPull: (() -> Void)?
    /// The write gate answered `sync_epoch_stale` (design §6.6): the puller
    /// abandons its chain and resets at the boundary.
    var onEpochStale: (() -> Void)?
    /// The engine's pull issue counter (incremented before every
    /// `sync_changes` RPC); captured into each pending-verify element so
    /// only a pull issued after the `[]` may clear it.
    var pullIssueCounter: () -> Int = { 0 }

    /// The inbound engine (design §4 SyncPuller), created by `attach`;
    /// nil in a test that drives the outbound path alone.
    private(set) var inbound: SyncPuller?
    /// Tables that owe a flush (design §6 每表单飞 flush (3)): held by I1
    /// before head, stopped by the gate (`sync_paused`, `sync_epoch_stale`)
    /// or by the server's paused bit. Each chain that reaches head flushes
    /// them once.
    private(set) var needsFlush: Set<String> = []
    /// The last `sync_epoch` read said `paused`: writes are held until a
    /// chain reads it false (the client-side courtesy gate; the server's
    /// write gate is what bears the load, design §6.6).
    var serverPaused = false
    /// Rule-4 re-uploads (design §6.6 设备追平): the parent version id a
    /// stale, seq-less row sends with its POST.
    var reuploadParents: [SyncBaselineKey: String] = [:]
    /// The columns a client write can carry that only exist once migration
    /// 015 is applied (`events.domino_anchor`, §5.8; the version columns,
    /// §5.9). A server without 015 refuses a body naming any of them with
    /// 400 `PGRST204`, so they are withheld while the feed is unavailable
    /// (the seat belt, design §6.6 设备何时查 epoch) and once the server
    /// has named one.
    nonisolated static let only015Columns: Set<String> = ["domino_anchor", "parent_version_id", "restored_from_version_id"]
    /// The outbound shape while the server has no migration 015 (design
    /// §6.6, the seat belt: "king 的整表差分上传照旧"): set by the puller when
    /// it finds the feed missing, cleared when a chain reaches head with
    /// the feed (the re-probe) and at every session start. While set, a
    /// changed row goes out as a merge-duplicates upsert and a removed one
    /// as a physical DELETE, and the baseline keeps hashes only (king's
    /// rule) — a conditional PATCH needs a `seq` and a tombstone needs
    /// `deleted_at`, neither of which exists before 015 (QA probe: edits
    /// and deletes never reached such a server).
    var outboundFallback = false
    /// The 015 columns a `PGRST204` showed this server does not have; for
    /// the rest of the session they are withheld from every write.
    private(set) var serverMissingColumns: Set<String> = []
    /// The token state the agent_preferences upgrade transition hashes
    /// with (`preferencesBaseInTokenFreeProjection`); a test hands in its own.
    var legacyTokenState: @MainActor () -> TokenInferenceRepository.Snapshot = { TokenInferenceRepository.shared.snapshot() }
    /// The baseline entries that transition could not explain this session.
    private var unexplainedPreferencesBases: Set<String> = []
    /// What each row awaiting its echo was sent as (`payloadDigest`): a
    /// single-row table does not send the same payload again before the
    /// echo, which is what kept user_settings re-POSTing on a server
    /// without the feed.
    private var awaitingEchoDigests: [SyncBaselineKey: String] = [:]
    /// L10 tripwire (design §9.36): the highest seq this device has seen,
    /// from committed pages and write responses. A write response whose
    /// seq is at or below the value captured when the request was built
    /// means the server handed out a number it had already handed out —
    /// logged and counted, never acted on (§6.6 不做的 (1)).
    private(set) var observedMaxSeq: Int64 = 0
    /// The highest seq this device's own write responses carried this
    /// session: rows at or below it may still have their doorbell frame on
    /// the way, so a poll that applies them is no missed ring (§6.5 M5).
    private(set) var ownWriteMaxSeq: Int64 = 0
    @Published private(set) var rewindAlerts = 0
    /// The one recovery prompt (design §6.6 一次恢复提示) while it is up,
    /// and the badge count of offers not yet decided.
    @Published private(set) var recoveryPrompt: SyncRecoveryPrompt?
    @Published private(set) var pendingPromptCount = 0

    private var isFullSyncDone = false

    /// Re-entry guard for `fullSync`. The sign-in path and
    /// `userDidEnableUploads` can both kick off a fullSync; rapid toggle
    /// flipping could otherwise spawn N parallel passes that idempotent-upsert
    /// the same rows and stretch the `isFullSyncDone == false` window that
    /// blocks debounced sinks. Set inside the Task, cleared in defer.
    private var fullSyncInFlight = false

    init(
        url: String = SupabaseSyncConfig.url,
        apiKey: String = SupabaseSyncConfig.publishableKey,
        defaults: UserDefaults = .standard,
        scheduler: SyncScheduler = RunLoopSyncScheduler(),
        environment: SupabaseEnvironment = .current,
        ownerRecord: SyncOwnerRecord? = nil
    ) {
        // Placeholder client; `attach()` reconstructs with the real
        // `AuthService` reference for user-JWT auth.
        self.gateway = SupabaseREST(url: url, projectAPIKey: apiKey, authService: nil as AuthService?)
        self.gatewayIsInjected = false
        self.defaults = defaults
        self.ownerRecord = ownerRecord
        self.environment = environment
        self.scheduler = scheduler
        self.undoHold = SyncUndoHold(scheduler: scheduler)
        self.baseline = SyncBaselineStore(defaults: defaults, userId: "")
        self.cursor = SyncCursorStore(defaults: defaults, userId: "")
        self.rejected = SyncRejectedSet(defaults: defaults, userId: "")
        restoreAccountGone()
    }

    /// Engine construction without an `AuthService`: a gateway (the fake
    /// server in tests), the user it speaks as, and the defaults it keeps
    /// its baseline in. Runs the same sign-in bookkeeping the session sink
    /// runs, including the legacy settings-baseline upgrade.
    init(
        gateway: SyncGateway,
        userId: String,
        defaults: UserDefaults,
        scheduler: SyncScheduler = RunLoopSyncScheduler(),
        environment: SupabaseEnvironment = .current,
        ownerRecord: SyncOwnerRecord? = nil
    ) {
        self.gateway = gateway
        self.gatewayIsInjected = true
        self.defaults = defaults
        self.ownerRecord = ownerRecord
        self.environment = environment
        self.scheduler = scheduler
        self.undoHold = SyncUndoHold(scheduler: scheduler)
        self.baseline = SyncBaselineStore(defaults: defaults, userId: "")
        self.cursor = SyncCursorStore(defaults: defaults, userId: "")
        self.rejected = SyncRejectedSet(defaults: defaults, userId: "")
        restoreAccountGone()
        beginSession(userId: userId)
    }

    /// DEBUG safety net: compile-time block that prevents any simulator or
    /// dev-built binary from writing to the production Supabase project.
    /// Independent of the user-controlled `syncUploadsEnabled` toggle — DEBUG
    /// blocks regardless of what the user picked, so accidental builds can
    /// never pollute prod. Read paths (`fetchAllRawRows`) stay live in both
    /// modes so dry-run preview and restore still work.
    #if DEBUG
    static let debugBlocksUploads = true
    #else
    static let debugBlocksUploads = false
    #endif

    /// The project this engine was built against. Production code hands in
    /// `SupabaseEnvironment.current`; the gate matrix test hands in each.
    let environment: SupabaseEnvironment

    /// Whether the build itself refuses to upload. The DEBUG block protects
    /// PRODUCTION (design D8): a DEBUG build pointed at the local stack or
    /// staging uploads under the master switch like any other build, or
    /// the simulator rig can never exercise the outbound path. Release and
    /// Staging builds never block here.
    nonisolated var uploadsBlockedByBuild: Bool {
        Self.debugBlocksUploads && environment == .production
    }

    /// Runtime gate: does this device sync? `uploadsBlockedByBuild`
    /// (compile-time block, production only) AND `syncUploadsEnabled` (the
    /// master switch, D9: registered ON at launch, gates the pull as well).
    /// Read on every sync entry point so flipping the toggle takes effect
    /// on the very next debounce without needing to re-attach the Combine
    /// pipeline.
    nonisolated var canUpload: Bool {
        if uploadsBlockedByBuild { return false }
        return defaults.bool(forKey: AppSettingsKeys.syncUploadsEnabled)
    }

    /// Called by the settings UI when the user flips the upload toggle from
    /// OFF → ON. Triggers a fresh fullSync to catch up the cloud with all
    /// the local changes that accumulated while uploads were paused. If a
    /// fullSync is already in flight (e.g. rapid OFF→ON→OFF→ON), this is a
    /// no-op — the in-flight pass already covers the catch-up work.
    func userDidEnableUploads() {
        guard canUpload, !userId.isEmpty, !fullSyncInFlight else { return }
        guard let es = attachedEventStore,
              let ets = attachedEventTypeStore,
              let ss = attachedSkillStore else { return }
        inbound?.sessionDidChange(signedIn: true)
        Task {
            self.fullSyncInFlight = true
            defer { self.fullSyncInFlight = false }
            self.isFullSyncDone = false
            await self.fullSync(eventStore: es, eventTypeStore: ets, skillStore: ss)
            self.isFullSyncDone = true
        }
    }

    /// Called by the settings UI when the master switch goes ON → OFF.
    /// D9: the switch gates both directions, so the puller stops too — no
    /// pull, no doorbell, no poll — until the switch is on again
    /// (`userDidEnableUploads` starts it).
    func userDidDisableUploads() {
        guard !canUpload else { return }
        inbound?.sessionDidChange(signedIn: false)
    }

    /// The stores the outbound path reads and the catch-up / recovery
    /// project rows from. `attach` calls it; a test that drives the engine
    /// without an `AuthService` calls it directly.
    func attachStores(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore?,
        skillStore: SkillInsightStore?,
        preferenceStore: AgentPreferenceStore?
    ) {
        self.attachedEventStore = eventStore
        self.attachedEventTypeStore = eventTypeStore
        self.attachedSkillStore = skillStore
        self.attachedPreferenceStore = preferenceStore
    }

    /// The inbound engine over the current gateway (design §4): the puller,
    /// its shelf, and — when an `AuthService` is attached — the realtime
    /// doorbell. Idempotent; a test hands in its own shelf directory.
    @discardableResult
    func installInbound(shelf: ConflictShelf, doorbell: SupabaseRealtimeDoorbell? = nil) -> SyncPuller {
        if let inbound { return inbound }
        let puller = SyncPuller(engine: self, gateway: gateway, shelf: shelf, scheduler: scheduler, doorbell: doorbell)
        puller.headFlag = SyncHeadFlag.shared
        if let eventStore = attachedEventStore {
            var singletons: [String: SyncSingletonAdapter] = [:]
            if let preferenceStore = attachedPreferenceStore {
                singletons["agent_preferences"] = AgentPreferencesSyncAdapter(engine: self, store: preferenceStore)
            }
            singletons["agent_conversations"] = AgentConversationsSyncAdapter(engine: self)
            puller.configure(eventStore: eventStore, eventTypeStore: attachedEventTypeStore,
                             skillStore: attachedSkillStore, singletons: singletons)
        }
        inbound = puller
        return puller
    }

    /// Start observing stores. Call once after stores are initialized.
    func attach(
        authService: AuthService,
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore,
        preferenceStore: AgentPreferenceStore
    ) {
        self.authService = authService
        attachStores(eventStore: eventStore, eventTypeStore: eventTypeStore,
                     skillStore: skillStore, preferenceStore: preferenceStore)
        // Rebuild the REST client now that we have the real AuthService.
        // Every PostgREST request from here on uses user-JWT auth (#28);
        // RLS on each table enforces `auth.uid() = user_id`.
        if !gatewayIsInjected {
            self.gateway = SupabaseREST(
                url: SupabaseSyncConfig.url,
                projectAPIKey: SupabaseSyncConfig.publishableKey,
                authService: authService
            )
        }
        // The inbound engine (design §4, §7 Phase 1): the puller over the
        // same gateway, the production shelf, and the doorbell. It runs
        // only while the master switch is on (`canUpload`, D9): with it off
        // this device neither pulls nor pushes, and a DEBUG build pointed at
        // production never pulls it.
        if inbound == nil {
            let doorbell = gatewayIsInjected ? nil : SupabaseRealtimeDoorbell(authService: authService)
            installInbound(shelf: ConflictShelf(directory: ConflictShelf.productionDirectory), doorbell: doorbell)
        }
        let debounce = SupabaseSyncConfig.debounceSeconds

        if uploadsBlockedByBuild {
            logger.notice("⚠️ DEBUG build on production — uploads disabled. Auth + read-only sync only. Restore (GET) still works.")
        } else if Self.debugBlocksUploads {
            logger.notice("DEBUG build on \(self.environment.displayName, privacy: .public) — uploads follow the master switch.")
        }

        // ── Watch auth state: keep userId in lockstep with session in all
        //    builds (fetchAllRawRows needs it). Skip the upload-side fullSync
        //    when uploads are disabled by either gate (DEBUG or user toggle).
        authService.$session
            .sink { [weak self, weak eventStore, weak eventTypeStore, weak skillStore] session in
                guard let self else { return }
                if let session {
                    // Rehydrate diff-sync baseline from disk before any sync
                    // runs. Without this every cold start treats all rows as
                    // changed (issue #30 was the tracking ticket for the bug
                    // this addresses).
                    self.beginSession(userId: session.user.id)
                    // gh#257: another account's data, all in the cloud —
                    // the switch ran and started this account's sync.
                    if self.switchAutomaticallyIfOwnerSynced() { return }
                    if !self.canUpload {
                        // Mark "ready" so any code gated on isFullSyncDone still
                        // works as expected. No fullSync — that runs when the
                        // toggle flips on (see `userDidEnableUploads`) or when
                        // the next debounced sink fires with the toggle on.
                        self.isFullSyncDone = true
                        return
                    }
                    // Every emission, a token refresh included (design §6.4):
                    // the puller re-hands the doorbell its credentials and
                    // otherwise begins its session.
                    self.inbound?.sessionDidChange(signedIn: true)
                    if let es = eventStore, let ets = eventTypeStore, let ss = skillStore,
                       !self.fullSyncInFlight {
                        Task {
                            self.fullSyncInFlight = true
                            defer { self.fullSyncInFlight = false }
                            self.isFullSyncDone = false
                            await self.fullSync(eventStore: es, eventTypeStore: ets, skillStore: ss)
                            self.isFullSyncDone = true
                        }
                    }
                } else {
                    // `$session → nil`: the puller stops first (its chain
                    // persists nothing after this), then the engine forgets.
                    self.inbound?.sessionDidChange(signedIn: false)
                    self.endSession()
                }
            }
            .store(in: &cancellables)

        // In DEBUG, skip wiring up any of the upload-side Combine sinks below.
        // The signed-in userId is still set above so `fetchAllRawRows()` works,
        // but nothing on the device will ever be pushed to Supabase. In Release
        // we wire the sinks unconditionally — each sink body checks `canUpload`
        // so the user toggle takes effect dynamically.
        if uploadsBlockedByBuild { return }

        // An undo window ended (design §10.6 (A)): the tombstone it held
        // goes out now, not with the next edit.
        undoHold.onExpire = { [weak self, weak eventStore] _ in
            guard let self, let eventStore, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
            Task {
                await self.syncEvents(eventStore.events, kind: "todo")
                await self.syncEvents(eventStore.rawCalendarEvents, kind: "calendar")
            }
        }

        // The per-table sinks below push the store's array as it is when
        // the flush task runs, not the value the debounce delivered: a pull
        // page applied on the main actor between the delivery and the task
        // has already written the store and the baseline, and the delivered
        // array, from before the page, would send every row the page created
        // as a tombstone and every row it edited back at the old value.
        // `undoHold.onExpire` and `flushPendingTables` read the stores the
        // same way. See SyncFlushLiveArrayTests.

        // ── Todo events ──
        eventStore.$events
            .dropFirst()
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self, weak eventStore] events in
                guard let self, let eventStore, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncEvents(self.liveForFlush(eventStore.events, delivered: events, table: "events"), kind: "todo") }
            }
            .store(in: &cancellables)

        // ── Calendar events ──
        eventStore.$rawCalendarEvents
            .dropFirst()
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self, weak eventStore] events in
                guard let self, let eventStore, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncEvents(self.liveForFlush(eventStore.rawCalendarEvents, delivered: events, table: "calendar_events"), kind: "calendar") }
            }
            .store(in: &cancellables)

        // ── Event logs ──
        eventStore.$calendarEventLogRecords
            .dropFirst()
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self, weak eventStore] logs in
                guard let self, let eventStore, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncLogs(self.liveForFlush(eventStore.calendarEventLogRecords, delivered: logs, table: "event_logs")) }
            }
            .store(in: &cancellables)

        // ── Event feedback ──
        eventStore.$calendarEventFeedbackRecords
            .dropFirst()
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self, weak eventStore] records in
                guard let self, let eventStore, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncFeedback(self.liveForFlush(eventStore.calendarEventFeedbackRecords, delivered: records, table: "event_feedback")) }
            }
            .store(in: &cancellables)

        // ── Todo lists ──
        eventStore.$todoLists
            .dropFirst()
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self, weak eventStore] lists in
                guard let self, let eventStore, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncTodoLists(self.liveForFlush(eventStore.todoLists, delivered: lists, table: "todo_lists")) }
            }
            .store(in: &cancellables)

        // ── Event types ──
        eventTypeStore.$templates
            .dropFirst()
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self, weak eventTypeStore] templates in
                guard let self, let eventTypeStore, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                // Checked at the sink as well as inside `syncEventTypes`,
                // because a frozen catalog still PUBLISHES (a refused write
                // mirrors the catalog's array back, which is a change) and
                // the cheapest place to stop a mirror is before it starts.
                guard !Self.eventTypeExportSuppressed(of: eventTypeStore) else { return }
                Task {
                    await self.syncEventTypes(self.liveForFlush(eventTypeStore.templates, delivered: templates, table: "event_types"))
                    // The deleted-type color history rides in the settings
                    // blob, and it left `UserDefaults` when the catalog took
                    // it over — so `didChangeNotification`, which used to be
                    // what pushed it, no longer fires for it. The only thing
                    // that writes it (`remove(title:)`) always moves
                    // `templates` too, so this is the honest replacement
                    // trigger. `syncSettings` hash-guards itself, so when the
                    // history did not change this costs one hash.
                    await self.syncSettings()
                }
            }
            .store(in: &cancellables)

        // ── Skill insights ──
        skillStore.$insights
            .dropFirst()
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self, weak skillStore] insights in
                guard let self, let skillStore, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncSkills(self.liveForFlush(skillStore.insights, delivered: insights, table: "skill_insights")) }
            }
            .store(in: &cancellables)

        // ── User settings ──
        // UserDefaults.didChangeNotification fires on any write, not just our
        // synced keys, so debounce aggressively (5s) and let the row-hash check
        // inside the sync funcs collapse no-op uploads to nothing.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .syncDebounceSink(for: SupabaseSyncConfig.settingsDebounceSeconds, on: scheduler) { [weak self] _ in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncSettings() }
            }
            .store(in: &cancellables)

        // ── Agent conversations ──
        // These used to ride the `didChangeNotification` sink above, for the
        // accidental reason that they were a `UserDefaults` blob. They are a
        // file now, and a file posts nothing — so without this subscription the
        // chat history would persist locally and quietly stop being backed up,
        // a failure that is invisible until the device is.
        //
        // The standard 2 s debounce rather than the settings sink's defensive
        // 5 s: this fires only on a real conversation commit, not on every
        // unrelated preference write in the app.
        NotificationCenter.default
            .publisher(for: AgentConversationRepository.didChangeNotification)
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self] _ in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncAgentConversations() }
            }
            .store(in: &cancellables)

        // ── Agent preferences (rules + decision history) ──
        // PreferenceStore persists to ApplicationSupport JSON files, not
        // UserDefaults, so it doesn't hit the didChange path above. Subscribe
        // to its @Published arrays via combineLatest — that primitive emits
        // ONE initial combined value, so `dropFirst()` (singular) is a
        // contract guarantee. The earlier `Publishers.Merge` + `dropFirst(2)`
        // shape relied on a count that drifts if a sibling adds
        // `.removeDuplicates()` upstream or if init order changes.
        preferenceStore.$rules
            .combineLatest(preferenceStore.$decisionHistory)
            .dropFirst()
            .map { _ in () }
            .syncDebounceSink(for: debounce, on: scheduler) { [weak self, weak preferenceStore] _ in
                guard let self, let preferenceStore,
                      self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncAgentPreferences(preferenceStore) }
            }
            .store(in: &cancellables)
        // The token-inference state is not synced (`agentPreferencesTokenColumns`),
        // so its saves trigger nothing here.
    }

    /// What a debounced per-table flush pushes: `live`, the store's array
    /// read in the flush task's own turn, the same turn its diff runs in.
    /// `delivered` is only compared, so the trail shows when the store moved
    /// between the debounce delivering and the flush starting — a pull page
    /// in that gap is what a flush of `delivered` would have undone.
    /// Unchanged arrays share storage, so the usual comparison is one check.
    private func liveForFlush<Element: Equatable>(_ live: [Element], delivered: [Element], table: String) -> [Element] {
        if live != delivered {
            DiagnosticTrail.record("Sync", "sync.flush.live table=\(table) delivered=\(delivered.count) live=\(live.count)")
        }
        return live
    }

    // MARK: - Session scope

    /// Sign-in: load this user's baseline and cursor from disk and drop
    /// anything the previous user left in memory. Internal so a test can
    /// replay what the `$session` sink delivers on a token refresh.
    func beginSession(userId: String) {
        // The same uid again is a token refresh, not a new session (design
        // §6.4): nothing is dropped, nothing is re-read.
        if userId == self.userId, !userId.isEmpty { return }
        self.userId = userId
        feedAvailability = .unknown
        baseline = SyncBaselineStore(defaults: defaults, userId: userId)
        cursor = SyncCursorStore(defaults: defaults, userId: userId)
        rejected = SyncRejectedSet(defaults: defaults, userId: userId)
        pendingVerify.reset()
        awaitingEcho = []
        awaitingEchoDigests = [:]
        zoneConflictsLogged = []
        schemaCacheFailures = [:]
        serverMissingColumns = []
        unexplainedPreferencesBases = []
        let dropped = cursor.validate(against: baseline)
        if !dropped.isEmpty {
            DiagnosticTrail.record("Sync", "sync.cursor.dropped reason=generation tables=\(dropped.joined(separator: ","))")
            logger.notice("cursor dropped: baseline generation mismatch in \(dropped.joined(separator: ","), privacy: .public); next pull starts from zero")
        }
        ownerState = SyncOwnerGuard.evaluate(sessionUid: userId, defaults, record: ownerRecord)
        ownerUnsyncedChanges = nil
        if case .blocked(let owner, let session) = ownerState {
            DiagnosticTrail.record("Sync", "sync.blocked.owner_mismatch owner=\(owner) session=\(session)")
            logger.error("sync stopped: local data belongs to another account")
        }
        // The "erased elsewhere" state ends with a sign-in — except one the
        // owner guard blocks (design §10.7 (a), then a new account): the
        // owner it blocks on is the account that was erased (only an active
        // session, whose uid is the owner, can reach the terminal state), and
        // the state is what keeps "use this phone's data for this account"
        // on the card (§10.7 (c) "仍可从账户卡片走到"; gh#257 staging QA
        // round 4: adopting is only for that state).
        if case .blocked = ownerState, defaults.string(forKey: Self.accountGoneTableKey) != nil {
            restoreAccountGone()
        } else {
            forgetAccountGone()
        }
        upgradeLegacySettingsBaselineIfLocalClean()
    }

    /// The terminal state as the last process left it (design §10.7): the
    /// card and the three-way prompt come back after a relaunch.
    private func restoreAccountGone() {
        guard let table = defaults.string(forKey: Self.accountGoneTableKey) else { return }
        accountCheck = .signedOut(table: table)
        accountGoneChoice = defaults.string(forKey: Self.accountGoneChoiceKey).flatMap(SyncAccountGoneChoice.init(rawValue:))
    }

    /// A new sign-in, or the erase: the "erased elsewhere" state is over,
    /// in memory and on disk.
    func forgetAccountGone() {
        accountCheck = .none
        accountGoneChoice = nil
        defaults.removeObject(forKey: Self.accountGoneTableKey)
        defaults.removeObject(forKey: Self.accountGoneChoiceKey)
    }

    /// 仍要退出并丢弃 (design §6.6 登出 / 擦除前的警告): the warning says the
    /// undecided offers are lost, so they are — discarded (only the offered
    /// lines, `SyncRecovery.discard`) before the sign-out or the erase runs.
    /// QA S5: they stayed undecided and came back as the badge when the same
    /// account signed in again.
    func discardUndecidedOffersBeforeLeaving() {
        guard let recovery = inbound?.recovery, recovery.hasUndecidedOffers else { return }
        recovery.discard()
    }

    /// Whether "use this phone's data for this account" may run: the data
    /// is blocked by its owner AND that owner was erased on another device
    /// (design §10.7 (c)). Data belongs to its account (gh#257 staging QA
    /// round 4, decided 2026-10-21): while the old account still exists its
    /// rows' ids are taken under it, the global primary key swallows every
    /// POST of them into this one (`sync.push.orphan`), and the upload the
    /// confirmation promised never happens. The card and the action read
    /// this one predicate.
    var canAdoptLocalData: Bool {
        guard !userId.isEmpty, case .blocked = ownerState, case .signedOut = accountCheck else { return false }
        return true
    }

    /// The explicit "use this device's data for the signed-in account"
    /// action (survey S5), only after the owner was erased elsewhere
    /// (`canAdoptLocalData`): the session's uid becomes the owner and the
    /// engine runs again. While the old account exists, the ways out of
    /// `.blocked` are "switch to this account" (`switchToCurrentAccount`,
    /// the erase then a fresh sync) and signing out.
    func adoptLocalDataForCurrentAccount() {
        guard !userId.isEmpty, case .blocked(let owner, _) = ownerState else { return }
        guard canAdoptLocalData else {
            DiagnosticTrail.record("Sync", "sync.owner.adopt_refused reason=owner_exists owner=\(owner) session=\(userId)")
            logger.error("adopt refused: the owner of this device's data still exists")
            return
        }
        SyncOwnerGuard.setOwner(userId, defaults, record: ownerRecord)
        ownerState = .active(uid: userId)
        // The erased account's state is answered: this account owns the data now.
        forgetAccountGone()
        DiagnosticTrail.record("Sync", "sync.owner.adopted previous=\(owner) session=\(userId)")
        // QA S6: nothing synced after this until a relaunch. The puller's
        // session was refused at sign-in (the guard stood), and the blocked
        // flushes returned before flagging anything. Every table owes a
        // flush, and the puller starts now; its first chain to reach head
        // sends them.
        needsFlush.formUnion(Self.flushTables)
        if gatewayIsInjected || canUpload {
            inbound?.sessionDidChange(signedIn: true)
        }
    }

    /// "Switch to this account" (gh#257 staging QA round 4; decided
    /// 2026-10-21: data belongs to its account). The local data is another
    /// account's, that account still exists, and the user wants the
    /// signed-in one here: `erase` is the existing erase run keeping the
    /// session (`LocalDataEraser.resetAllLocalData(keepingSession: true)`:
    /// stores, shelf, baselines, cursor and `ownerUid` go), then this
    /// session starts afresh — it takes ownership, the master switch goes on
    /// (D9), and the puller's first chain loads this account's rows. The
    /// other account's cloud data is not touched.
    func switchToCurrentAccount(reason: OwnerSwitchReason = .user, erasingLocalData erase: () -> Void) {
        guard !userId.isEmpty, case .blocked(let owner, let session) = ownerState else {
            DiagnosticTrail.record("Sync", "sync.owner.switch_refused reason=not_blocked")
            return
        }
        let erasedRows = localIdRowCount
        // Nothing may pull or write into the stores while they are erased.
        inbound?.sessionDidChange(signedIn: false)
        erase()
        // The erase sweeps the `syncHashes.` prefix; an owner still on record
        // means it did not run, and starting would leave the block standing
        // over data nobody chose to keep or lose.
        if let survivor = SyncOwnerGuard.storedOwner(defaults, record: ownerRecord) {
            DiagnosticTrail.record("Sync", "sync.owner.switch_refused reason=owner_survived_erase owner=\(survivor)")
            logger.error("switch refused: the erase left the owner on record")
            return
        }
        defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        endSession()
        beginSession(userId: session)
        DiagnosticTrail.record("Sync", "sync.owner.switched reason=\(reason.rawValue) previous=\(owner) session=\(session) erased=\(erasedRows)")
        guard ownerState.allowsSync else { return }
        if gatewayIsInjected || canUpload {
            inbound?.sessionDidChange(signedIn: true)
        }
        if canUpload {
            userDidEnableUploads()
        } else {
            isFullSyncDone = true
        }
    }

    /// The rows of the id tables this device holds — what the adopt
    /// confirmation tells the user will go into the signed-in account
    /// (sim QA round 2: adopting had no confirmation step). The one-row
    /// tables (settings, agent preferences, conversations) are not counted.
    var localIdRowCount: Int {
        var count = 0
        if let store = attachedEventStore {
            count += store.events.count + store.rawCalendarEvents.count
            count += store.calendarEventLogRecords.count + store.calendarEventFeedbackRecords.count
            count += store.todoLists.count
        }
        count += attachedEventTypeStore?.templates.count ?? 0
        count += attachedSkillStore?.insights.count ?? 0
        return count
    }

    /// Why the switch ran: the user chose it on the card, or the owner's
    /// data was all in the cloud and the sign-in switched on its own.
    enum OwnerSwitchReason: String {
        case user
        case clean
    }

    /// The seamless switch (gh#257, decided 2026-10-21: data belongs to its
    /// account, and changing account should feel like nothing happened).
    /// Called right after a sign-in the owner guard blocked. When the
    /// owner's data on this device is all in the cloud
    /// (`unsyncedChanges(owner:) == 0`), nothing can be lost by removing it,
    /// so the switch runs without asking: the erase keeping this session,
    /// then this account syncs (`switchToCurrentAccount`). Otherwise the
    /// count is published and the account card asks. Not in the state where
    /// the owner was erased elsewhere (design §10.7): there the three-way
    /// choice stands, since "use this phone's data" is still an answer.
    /// Returns whether it switched.
    @discardableResult
    func switchAutomaticallyIfOwnerSynced() -> Bool {
        guard !userId.isEmpty, case .blocked(let owner, _) = ownerState, !canAdoptLocalData,
              let erase = ownerSwitchEraser else { return false }
        let unsynced = unsyncedChanges(owner: owner)
        guard unsynced == 0 else {
            ownerUnsyncedChanges = unsynced
            DiagnosticTrail.record("Sync", "sync.owner.switch_held reason=unsynced owner=\(owner) session=\(userId) n=\(unsynced)")
            if heldSwitchAlertsPresented == 0 {
                presentHeldSwitchAlert(unsynced)
            }
            return false
        }
        switchToCurrentAccount(reason: .clean, erasingLocalData: erase)
        return ownerState.allowsSync
    }

    /// Puts the held switch's alert up over the main screen.
    func presentHeldSwitchAlert(_ unsynced: Int) {
        heldSwitchAlertsPresented += 1
        heldSwitchAlert = unsynced
        DiagnosticTrail.record("Sync", "sync.switch_alert.presented n=\(unsynced)")
    }

    /// "Switch Anyway", on the held card or the launch alert. The user has
    /// just read what will be lost, so the switch runs now (`reason=user`)
    /// with no second confirmation (staging QA round 7, observation 3: the
    /// "12 items will be removed" step after "4 changes will be lost" read
    /// as two numbers for one thing). The plain mismatch card's "Switch to
    /// this account" keeps its confirmation.
    func switchAnyway() {
        heldSwitchAlert = nil
        guard ownerUnsyncedChanges != nil, let erase = ownerSwitchEraser else {
            DiagnosticTrail.record("Sync", "sync.owner.switch_refused reason=not_held")
            return
        }
        switchToCurrentAccount(reason: .user, erasingLocalData: erase)
    }

    /// "Sign in with that account to sync": the card's way to keep the
    /// owner's unsynced changes. This session ends (the caller signs out);
    /// the owner signs in again and its next flush sends them.
    func deferSwitchUntilOwnerSyncs() {
        guard case .blocked(let owner, let session) = ownerState else { return }
        DiagnosticTrail.record("Sync", "sync.owner.switch_deferred owner=\(owner) session=\(session) n=\(ownerUnsyncedChanges ?? 0)")
    }

    /// What `owner`'s data on this device still owes the cloud, read from
    /// what lasts: its own baseline on disk and the shelf. A row counts when
    /// its local hash is not the one last uploaded or pulled — that covers
    /// an edit made offline, a send whose answer never came (`?`, the mark
    /// pending-verify, awaiting-echo and a failed flush all leave), a
    /// rule-4 re-upload not yet sent, and a delete whose tombstone has not
    /// gone out (the baseline still holds the id). The in-memory sets
    /// (`needsFlush`, pending-verify, awaiting-echo) are another session's
    /// and were dropped when it ended; the marks they left are what is read.
    /// Before 015 (king's whole-table diff) the baseline holds the hash of
    /// the row as sent without the 015 columns, which also counts as
    /// uploaded. Plus the shelf's undecided offers under `owner`. Counted:
    /// the id tables and the settings row — what the user changed and would
    /// recognise in "N changes"; not the two derived one-row tables.
    func unsyncedChanges(owner: String) -> Int {
        guard !owner.isEmpty else { return 0 }
        let base = SyncBaselineStore(defaults: defaults, userId: owner)
        var count = 0
        let previousUid = userId
        // The row projections carry `user_id`, and the owner's baseline was
        // hashed with the owner's.
        userId = owner
        defer { userId = previousUid }
        if let store = attachedEventStore {
            count += Self.unsyncedRows(store.events.map { eventToRow($0, kind: "todo") }, table: "events", base)
            count += Self.unsyncedRows(store.rawCalendarEvents.map { eventToRow($0, kind: "calendar") },
                                       table: "calendar_events", base)
            count += Self.unsyncedRows(store.calendarEventLogRecords.map { logToRow($0) }, table: "event_logs", base)
            count += Self.unsyncedRows(store.calendarEventFeedbackRecords.map { feedbackToRow($0) }, table: "event_feedback", base)
            count += Self.unsyncedRows(store.todoLists.map(todoListToRow), table: "todo_lists", base)
        }
        if let types = attachedEventTypeStore {
            count += Self.unsyncedRows(types.templates.map(eventTypeToRow), table: "event_types", base)
        }
        if let skills = attachedSkillStore {
            count += Self.unsyncedRows(skills.insights.map(skillToRow), table: "skill_insights", base)
        }
        // The user's own settings are one change the user made and can name.
        if !settingsIsClean(against: base.settings) || base.settingsStale { count += 1 }
        // `agent_preferences` and `agent_conversations` are not counted and
        // do not hold the switch on their own (staging QA round 7, finding 1:
        // three offline event edits read "4 changes", back when the
        // preferences row carried the token projections and every edit
        // rewrote it). They are state the app derives
        // or keeps for the assistant, not changes the user could recognise;
        // when something else is owed the switch is held and they stay on
        // the phone with it.
        count += inbound?.recovery.undecidedOffers(uid: owner).count ?? 0
        return count
    }

    /// The hashes a row may have been uploaded under: as it is, and as the
    /// pre-015 fallback sends it (without the 015 columns, all or one).
    static func uploadedHashes(of row: [String: Any]) -> Set<String> {
        var hashes: Set<String> = [rowHash(row), rowHash(withholding(only015Columns, from: row))]
        for column in only015Columns { hashes.insert(rowHash(withholding([column], from: row))) }
        return hashes
    }

    private static func isUploaded(_ row: [String: Any], _ entry: SyncBaselineEntry?) -> Bool {
        guard let entry, !entry.isUnknown, !isStaleReupload(entry) else { return false }
        return uploadedHashes(of: row).contains(entry.hash)
    }

    /// Local rows not uploaded as they are, plus ids the baseline holds that
    /// left the local array (a delete not yet sent).
    private static func unsyncedRows(_ rows: [[String: Any]], table: String, _ base: SyncBaselineStore) -> Int {
        let entries = base.entries(table: table)
        var live: Set<String> = []
        var count = 0
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            live.insert(id)
            if !isUploaded(row, entries[id]) { count += 1 }
        }
        count += Set(entries.keys).subtracting(live).count
        return count
    }

    /// Every table `flushPendingTables` knows how to flush.
    nonisolated static let flushTables: [String] = [
        "events", "calendar_events", "event_logs", "event_feedback", "todo_lists", "event_types",
        "skill_insights", SyncBaselineStore.settingsTable, "agent_preferences", "agent_conversations",
    ]

    /// `$session → nil` (design §6.4): forget the in-memory baseline, cursor,
    /// pending-verify set and echo bookkeeping, and persist NOTHING — the
    /// erase signs out before it wipes the hashes, and a write here would
    /// land in that window. `accountCheck` stays: a terminal refresh ends
    /// the session, and the reason is what the account card shows next.
    /// Internal so a test can replay what the `$session` sink delivers.
    func endSession() {
        userId = ""
        isFullSyncDone = false
        baseline = SyncBaselineStore(defaults: defaults, userId: "")
        cursor = SyncCursorStore(defaults: defaults, userId: "")
        rejected = SyncRejectedSet(defaults: defaults, userId: "")
        pendingVerify.reset()
        awaitingEcho = []
        awaitingEchoDigests = [:]
        zoneConflictsLogged = []
        schemaCacheFailures = [:]
        serverMissingColumns = []
        unexplainedPreferencesBases = []
        outboundFallback = false
        needsFlush = []
        reuploadParents = [:]
        serverPaused = false
        observedMaxSeq = 0
        ownWriteMaxSeq = 0
        recoveryPrompt = nil
        pendingPromptCount = 0
        ownerState = .signedOut
        ownerUnsyncedChanges = nil
        heldSwitchAlert = nil
        feedAvailability = .unknown
    }

    func noteFeedAvailability(_ availability: SyncFeedAvailability) {
        guard feedAvailability != availability else { return }
        feedAvailability = availability
    }

    /// Design §7 Phase 1: `offerAutoRestoreIfNeeded` retires (gh#257 staging
    /// QA round 4 bug 2: the "Restore from Cloud" sheet, with "cloud
    /// overwrites local", came up on a re-sign-in over synced events). Where
    /// the feed answers, the first pull to head does what the sheet did, so
    /// there is no sheet. Where it does not (a server before 015), or sync is
    /// off on this device so nothing will pull, today's offer stands. Until
    /// this session's first pull has answered, the offer waits.
    nonisolated static func autoRestoreOfferDecision(syncRuns: Bool, feed: SyncFeedAvailability) -> AutoRestoreOfferDecision {
        guard syncRuns else { return .offer }
        switch feed {
        case .available: return .retired
        case .unavailable: return .offer
        case .unknown: return .wait
        }
    }

    /// The reset's half of the in-memory tables (design §6.6 设备追平, §6.4
    /// list): the pending-verify set, the echo bookkeeping, the schema-cache
    /// windows, the flush flags and the re-upload parents. The `rejected`
    /// set is on disk per user and stays.
    func clearInMemoryForReset() {
        pendingVerify.reset()
        awaitingEcho = []
        awaitingEchoDigests = [:]
        schemaCacheFailures = [:]
        needsFlush = []
        reuploadParents = [:]
        serverPaused = false
    }

    func markNeedsFlush(_ table: String) {
        needsFlush.insert(table)
    }

    /// The flush each chain that reaches head owes the flagged tables
    /// (design §6 每表单飞 flush (3)): the per-table sync over the attached
    /// stores' live arrays. Nothing is sent while the master switch is off.
    func flushPendingTables() async {
        guard gatewayIsInjected || canUpload else { return }
        let tables = needsFlush
        needsFlush = []
        guard !tables.isEmpty else { return }
        for table in tables.sorted() {
            switch table {
            case "events":
                if let store = attachedEventStore { await syncEvents(store.events, kind: "todo") }
            case "calendar_events":
                if let store = attachedEventStore { await syncEvents(store.rawCalendarEvents, kind: "calendar") }
            case "event_logs":
                if let store = attachedEventStore { await syncLogs(store.calendarEventLogRecords) }
            case "event_feedback":
                if let store = attachedEventStore { await syncFeedback(store.calendarEventFeedbackRecords) }
            case "todo_lists":
                if let store = attachedEventStore { await syncTodoLists(store.todoLists) }
            case "event_types":
                if let store = attachedEventTypeStore { await syncEventTypes(store.templates) }
            case "skill_insights":
                if let store = attachedSkillStore { await syncSkills(store.insights) }
            case SyncBaselineStore.settingsTable:
                await syncSettings()
            case "agent_preferences":
                if let store = attachedPreferenceStore { await syncAgentPreferences(store) }
            case "agent_conversations":
                await syncAgentConversations()
            default:
                break
            }
        }
    }

    /// The local row of `(table, id)` in the outbound projection, from the
    /// attached stores; nil when the device does not hold it. What the
    /// catch-up (rule 3 vs 4) and the recovery (keep both) read.
    func localRow(table: String, id: String) -> [String: Any]? {
        switch table {
        case "calendar_events":
            return attachedEventStore?.rawCalendarEvents.first { $0.id.uuidString == id }.map { eventToRow($0, kind: "calendar") }
        case "events":
            return attachedEventStore?.events.first { $0.id.uuidString == id }.map { eventToRow($0, kind: "todo") }
        case "event_logs":
            return attachedEventStore?.calendarEventLogRecords.first { encodeOccurrenceKey($0.id) == id }.map(logToRow)
        case "event_feedback":
            return attachedEventStore?.calendarEventFeedbackRecords.first { encodeOccurrenceKey($0.id) == id }.map(feedbackToRow)
        case "todo_lists":
            return attachedEventStore?.todoLists.first { $0.id.uuidString == id }.map(todoListToRow)
        case "event_types":
            return attachedEventTypeStore?.templates.first { $0.id.uuidString == id }.map(eventTypeToRow)
        case "skill_insights":
            return attachedSkillStore?.insights.first { $0.id.uuidString == id }.map(skillToRow)
        case "agent_preferences":
            return attachedPreferenceStore.map(agentPreferencesToRow)
        case "agent_conversations":
            return agentConversationsToRow()
        case SyncBaselineStore.settingsTable:
            return settingsToRow()
        default:
            return nil
        }
    }

    /// The server table a baseline label maps to (`calendar_events` and
    /// `events` share `events`).
    nonisolated static func serverTable(forBaselineTable table: String) -> String {
        table == "calendar_events" ? "events" : table
    }

    /// The baseline key a feed row is applied under, as the applier keys
    /// it (an `events` row without `kind` is unknown here and skipped).
    nonisolated static func baselineKey(forFeedRow row: SyncFeedRow, userId: String) -> SyncBaselineKey? {
        switch row.table {
        case "events":
            guard let raw = row.data["id"] as? String, let kind = row.data["kind"] as? String else { return nil }
            return SyncBaselineKey(table: SyncBaselineStore.table(forFeedTable: "events", kind: kind), id: SyncBaselineKey.localId(raw))
        case "event_logs", "event_feedback":
            guard let raw = row.data["id"] as? String else { return nil }
            return SyncBaselineKey(table: row.table, id: raw)
        case "todo_lists", "event_types", "skill_insights":
            guard let raw = row.data["id"] as? String else { return nil }
            return SyncBaselineKey(table: row.table, id: SyncBaselineKey.localId(raw))
        case SyncBaselineStore.settingsTable, "agent_preferences", "agent_conversations":
            return SyncBaselineKey(table: row.table, id: userId)
        default:
            return nil
        }
    }

    static func isoString(_ date: Date) -> String { iso(date) }

    // MARK: - L10 tripwire and the recovery prompt's published state

    func noteObservedSeq(_ seq: Int64) {
        observedMaxSeq = max(observedMaxSeq, seq)
    }

    /// A write response carrying a seq at or below the watermark captured
    /// when the request was built: the server handed out a number this
    /// device had already seen. Logged and counted only.
    private func noteWriteSeq(_ seq: Int64, watermark: Int64, table: String) {
        if watermark > 0, seq <= watermark {
            rewindAlerts += 1
            DiagnosticTrail.record("Sync", "sync.cursor.rewind table=\(table) seq=\(seq) watermark=\(watermark)")
        }
        ownWriteMaxSeq = max(ownWriteMaxSeq, seq)
        noteObservedSeq(seq)
    }

    func presentRecoveryPrompt(_ prompt: SyncRecoveryPrompt?) {
        recoveryPrompt = prompt
    }

    func setPendingPromptCount(_ count: Int) {
        pendingPromptCount = count
    }

    /// Offers the prompt named that the user has not decided (design §6.6
    /// 登出 / 擦除前的警告): the sign-out and erase guards read it.
    var hasUndecidedOffers: Bool {
        inbound?.recovery.hasUndecidedOffers ?? false
    }

    // MARK: - Per-row sync-state query (inspect UI)

    /// Sync-state observable by the inspect UI. Computed on demand from the
    /// baseline; no new storage. After #30, the baseline is persisted, so
    /// this returns meaningful state from the first frame of an inspect view
    /// (rather than "everything pending" until the first fullSync completes
    /// after launch).
    enum RowSyncState: Equatable {
        case synced            // local hash matches last-persisted upload hash
        case pending           // hash differs (or row not yet seen by sync)
        case offline           // sync hasn't run yet this session, can't tell
    }

    /// Per-event lookup. `kind` is "todo" or "calendar" to disambiguate which
    /// baseline table to consult. Returns `.offline` when no userId is set so
    /// the UI can show a neutral state instead of falsely claiming "pending".
    func syncStateForEvent(_ event: Event, kind: String) -> RowSyncState {
        guard !userId.isEmpty else { return .offline }
        let table = Self.eventsBaselineTable(kind: kind)
        let currentHash = Self.rowHash(eventToRowForHashing(event, kind: kind))
        return baseline.entry(table: table, id: event.id.uuidString)?.hash == currentHash ? .synced : .pending
    }

    /// Generic per-table aggregate: "are all rows in this table currently
    /// synced?" Used by the inspect UI to render a one-line summary for
    /// non-event tables (event_types / todo_lists / skill_insights /
    /// user_settings) that don't live on the calendar.
    enum TableSyncSummary: Equatable {
        case empty                   // table is empty locally — nothing to sync
        case synced(count: Int)
        case pending(synced: Int, pending: Int)
        case offline
    }

    func syncSummaryForTodoLists(_ lists: [TodoList]) -> TableSyncSummary {
        summarize(rows: lists.map(todoListToRow), table: "todo_lists")
    }
    func syncSummaryForEventTypes(_ types: [EventTypeTemplate]) -> TableSyncSummary {
        summarize(rows: types.map(eventTypeToRow), table: "event_types")
    }
    func syncSummaryForSkills(_ insights: [SkillInsight]) -> TableSyncSummary {
        summarize(rows: insights.map(skillToRow), table: "skill_insights")
    }
    func syncSummaryForLogs(_ logs: [CalendarEventLogRecord]) -> TableSyncSummary {
        summarize(rows: logs.map(logToRow), table: "event_logs")
    }
    func syncSummaryForFeedback(_ records: [CalendarEventFeedbackRecord]) -> TableSyncSummary {
        summarize(rows: records.map(feedbackToRow), table: "event_feedback")
    }
    func syncSummaryForSettings() -> TableSyncSummary {
        guard !userId.isEmpty else { return .offline }
        return settingsIsClean() ? .synced(count: 1) : .pending(synced: 0, pending: 1)
    }

    func syncSummaryForAgentPreferences(_ store: AgentPreferenceStore) -> TableSyncSummary {
        guard !userId.isEmpty else { return .offline }
        let current = Self.rowHash(agentPreferencesToRow(store))
        return baseline.entry(table: "agent_preferences", id: userId)?.hash == current
            ? .synced(count: 1) : .pending(synced: 0, pending: 1)
    }

    func syncSummaryForAgentConversations() -> TableSyncSummary {
        guard !userId.isEmpty else { return .offline }
        let current = Self.rowHash(agentConversationsToRow())
        return baseline.entry(table: "agent_conversations", id: userId)?.hash == current
            ? .synced(count: 1) : .pending(synced: 0, pending: 1)
    }

    private func summarize(rows: [[String: Any]], table: String) -> TableSyncSummary {
        guard !userId.isEmpty else { return .offline }
        guard !rows.isEmpty else { return .empty }
        let entries = baseline.entries(table: table)
        var synced = 0
        var pending = 0
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            if entries[id]?.hash == Self.rowHash(row) {
                synced += 1
            } else {
                pending += 1
            }
        }
        return pending == 0 ? .synced(count: synced) : .pending(synced: synced, pending: pending)
    }

    // MARK: - Hashing seams

    /// The one row hash (see `syncRowHash`).
    static func rowHash(_ row: [String: Any]) -> String { syncRowHash(row) }

    /// Per-key hashes of a settings blob: the `user_settings` baseline shape.
    /// Hashed in canonical form (`SyncedSettings.canonicalForm`), so
    /// devices holding the same union set in different orders agree.
    static func settingsKeyHashes(_ blob: [String: Any]) -> [String: String] {
        SyncedSettings.canonicalForm(blob).mapValues { syncValueHash($0) }
    }

    /// The settings blob as it goes out: the local snapshot, except the
    /// reference-zone key is the SERVER's value when the baseline holds one
    /// (design §6.2 pusher rule — a device never pushes another zone over an
    /// established account zone; it sends its own only while the server
    /// has none).
    static func settingsBlobForUpload(local: [String: Any], serverZone: String?) -> [String: Any] {
        var blob = SyncedSettings.canonicalForm(local)
        if let serverZone {
            blob[CalendarOccurrenceKey.referenceTimeZoneDefaultsKey] = serverZone
        }
        return blob
    }

    /// The fingerprint the sample-data seeder records (design §6 示例数据):
    /// the calendar projection of the row WITHOUT `user_id`, so the value at
    /// seed time (no session) equals the value at check time (signed in).
    static func seedFingerprint(_ event: Event) -> String {
        var row = eventRowHashableFields(event, kind: "calendar", userId: "")
        row["user_id"] = nil
        return rowHash(row)
    }

    nonisolated static func eventsBaselineTable(kind: String) -> String {
        SyncBaselineStore.table(forFeedTable: "events", kind: kind)
    }

    static func isTombstoned(_ row: [String: Any]) -> Bool {
        guard let value = row["deleted_at"] else { return false }
        return !(value is NSNull)
    }

    // MARK: - Baseline (#30, now (hash, seq) — design §6.3)
    //
    // The baseline is persisted so a relaunch with no edits doesn't fall back
    // to the empty-map-against-current-rows case, which would treat every row
    // as "changed" and burn bandwidth uploading every row on every cold start.
    // Shapes and keys: see `SyncBaseline.swift`.

    /// The legacy scalar settings hash upgrades to per-key hashes without a
    /// server round trip in exactly one case: the local row still hashes to
    /// it (nothing changed locally since the last upload), so the local
    /// per-key hashes ARE the baseline and only the seq is unknown. The
    /// other two branches need the remote row: `upgradeLegacySettingsBaseline`.
    private func upgradeLegacySettingsBaselineIfLocalClean() {
        guard !userId.isEmpty, case .legacy(let rowHash) = baseline.settings else { return }
        let local = SyncedSettings.currentSnapshot(defaults)
        guard let keys = SyncSettingsMerge.upgradedKeysIfLocalClean(
            legacyHash: rowHash,
            localRowHash: Self.rowHash(settingsRow(local)),
            localKeys: Self.settingsKeyHashes(local)
        ) else { return }
        baseline.setSettings(.versioned(seq: nil, keys: keys, zone: nil))
        baseline.persist()
    }

    /// The applier's entry point for the legacy settings baseline (design
    /// §6 user_settings 段), called with the remote row once it is in hand.
    /// Local row still hashes to the legacy value → local per-key hashes;
    /// remote row hashes to it (the remote IS this device's last upload, so
    /// every difference is local) → remote per-key hashes; neither → empty
    /// keys, every differing key is a conflict for the merge to resolve.
    /// Returns false when there was no legacy baseline to upgrade.
    @discardableResult
    func upgradeLegacySettingsBaseline(remoteSettings: [String: Any], remoteSeq: Int64) -> Bool {
        guard !userId.isEmpty, case .legacy(let legacyHash) = baseline.settings else { return false }
        let local = SyncedSettings.currentSnapshot(defaults)
        let keys = SyncSettingsMerge.upgradedKeys(
            legacyHash: legacyHash,
            rowHashes: legacySettingsRowHashes(local: local, remote: remoteSettings),
            localKeys: Self.settingsKeyHashes(local),
            remoteKeys: Self.settingsKeyHashes(remoteSettings)
        )
        let zone = remoteSettings[CalendarOccurrenceKey.referenceTimeZoneDefaultsKey] as? String
        baseline.setSettings(.versioned(seq: remoteSeq, keys: keys, zone: zone))
        baseline.persist()
        return true
    }

    /// The two row hashes the legacy upgrade compares the old scalar
    /// against, in the form it was taken in. The applier hands these to
    /// `SyncSettingsMerge.merge` with a `.legacy` baseline.
    func legacySettingsRowHashes(local: [String: Any], remote: [String: Any]) -> SyncSettingsMerge.LegacyRowHashes {
        SyncSettingsMerge.LegacyRowHashes(
            local: Self.rowHash(settingsRow(local)),
            remote: Self.rowHash(settingsRow(remote))
        )
    }

    /// Wipe persisted hashes for every user this device has ever signed in
    /// as. Used by "Reset all local data" in settings. Scans UserDefaults
    /// for keys with the `syncHashes.` prefix (since `userId` itself may
    /// not be currently known if the reset runs while signed out). The
    /// cursor shares the prefix and goes with them.
    static func wipeAllPersistedHashes(_ defaults: UserDefaults = .standard) {
        SyncBaselineStore.wipeAll(defaults)
    }

    // MARK: - Pending verify / echo bookkeeping for the engine

    /// The engine calls this once per pull that reached head (design §6
    /// 上传形状): `seen` is every (table, id) that pull delivered,
    /// `pullIssue` the issue number of the RPC that returned the short page.
    /// Confirmed elements write the SENT hash / keys into the baseline; the
    /// seq is left alone (it equals the sent one by construction).
    ///
    /// The confirmation is a compare-and-set against the `?@sentSeq` the
    /// send wrote (survey S4): the seq the set compares with `sentSeq` is
    /// read only from an entry that is still that marker, so an entry a
    /// pull rewrote — even at the same seq — is never overwritten.
    @discardableResult
    func resolvePendingVerifyAtHead(seen: Set<SyncBaselineKey>, pullIssue: Int) -> [SyncBaselineKey] {
        var set = pendingVerify
        let cleared = set.resolveAtHead(
            seen: seen,
            pullIssue: pullIssue,
            baselineSeq: { self.markedSeq($0) },
            confirm: { key, payload in self.writeBaseline(key, payload: payload, seq: nil) }
        )
        pendingVerify = set
        baseline.persist()
        return cleared
    }

    /// The applier's half of the pending-verify rule (design §6 上传形状,
    /// "`[]` 的收口"): a row an ELIGIBLE pull delivered went through the
    /// normal three-way compare, so its element leaves the set — the same
    /// "seen → dropped" branch `resolvePendingVerifyAtHead` takes, taken as
    /// each applied page lands. Elements recorded at or after `pullIssue`
    /// stay: that pull may predate the write that made the PATCH stale.
    /// Returns the keys dropped.
    @discardableResult
    func dropSeenPendingVerify(_ seen: Set<SyncBaselineKey>, pullIssue: Int) -> Set<SyncBaselineKey> {
        var dropped: Set<SyncBaselineKey> = []
        for key in seen {
            guard let element = pendingVerify[key], pullIssue > element.pullIssue else { continue }
            pendingVerify.remove(key)
            dropped.insert(key)
        }
        return dropped
    }

    /// Test and engine seam: records a `[]` outcome exactly as the flush does.
    func notePendingVerify(_ key: SyncBaselineKey, sentSeq: Int64, payload: PendingVerifyPayload, pullIssue: Int) {
        pendingVerify.insert(key, sentSeq: sentSeq, payload: payload, pullIssue: pullIssue)
    }

    /// After a head pull: drop every awaiting-echo key whose baseline now
    /// carries a seq (the echo arrived) and return the rest — rows the
    /// server neither inserted nor echoed, i.e. `sync.push.orphan`.
    func orphansAfterHeadPull() -> [SyncBaselineKey] {
        var orphans: [SyncBaselineKey] = []
        for key in awaitingEcho {
            if baselineSeq(key) != nil {
                awaitingEcho.remove(key)
            } else {
                orphans.append(key)
            }
        }
        return orphans
    }

    private func baselineSeq(_ key: SyncBaselineKey) -> Int64? {
        if key.table == SyncBaselineStore.settingsTable { return baseline.settings?.seq }
        return baseline.entry(table: key.table, id: key.id)?.seq
    }

    /// The seq of an entry that still holds a send's `?` marker, nil for
    /// any other entry. The settings row marks per key and moves its seq
    /// only by a pull or a response, so its seq is the comparison.
    private func markedSeq(_ key: SyncBaselineKey) -> Int64? {
        if key.table == SyncBaselineStore.settingsTable { return baseline.settings?.seq }
        guard let entry = baseline.entry(table: key.table, id: key.id), entry.isUnknown else { return nil }
        return entry.seq
    }

    /// The one place a successful push (or a confirmed pending element)
    /// writes the baseline. `seq == nil` keeps the seq already there;
    /// `vid == nil` keeps the version id. The row reads clean afterwards,
    /// so its origin and any re-upload parent are dropped.
    private func writeBaseline(_ key: SyncBaselineKey, payload: PendingVerifyPayload, seq: Int64?, vid: String? = nil) {
        switch payload {
        case .rowHash(let hash):
            let existing = baseline.entry(table: key.table, id: key.id)
            baseline.setEntry(SyncBaselineEntry(hash: hash, seq: seq ?? existing?.seq, vid: vid ?? existing?.vid, stale: false),
                              table: key.table, id: key.id)
            baseline.removeOrigin(table: key.table, id: key.id)
            reuploadParents[key] = nil
        case .settingsKeys(let keys):
            let current = baseline.settings
            baseline.setSettings(.versioned(seq: seq ?? current?.seq, keys: keys, zone: current?.zone))
        }
    }

    // MARK: - Full sync (on launch)

    private func fullSync(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) async {
        logger.info("Full sync starting…")
        statusReporter?.structuredBeginBurst()
        defer { statusReporter?.structuredEndBurst() }
        await syncEvents(eventStore.events, kind: "todo")
        await syncEvents(eventStore.rawCalendarEvents, kind: "calendar")
        await syncLogs(eventStore.calendarEventLogRecords)
        await syncFeedback(eventStore.calendarEventFeedbackRecords)
        await syncTodoLists(eventStore.todoLists)
        await syncEventTypes(eventTypeStore.templates)
        await syncSkills(skillStore.insights)
        await syncSettings()
        if let preferenceStore = attachedPreferenceStore {
            await syncAgentPreferences(preferenceStore)
        }
        await syncAgentConversations()
        logger.info("Full sync complete")
    }

    // MARK: - Outbound shapes (design §6 上传形状)

    /// The baseline value one send wrote for its row (survey S4, design §6
    /// 结果未知的写): `?@sentSeq` for a per-row or scalar entry (`?` alone
    /// when the row has no seq), or the whole settings baseline after the
    /// keys the write changes were set to `?`. Every outcome that writes
    /// `(hash, seq)` compares the entry against it first.
    private enum SentMark: Equatable {
        case entry(SyncBaselineEntry)
        case settings(SyncSettingsBaseline?)
    }

    private struct PushRow {
        let key: SyncBaselineKey
        /// The body as sent; a rule-4 re-upload adds `parent_version_id`,
        /// which is not part of the hash (the server owns the column).
        var row: [String: Any]
        /// What the baseline will hold if this row lands: the hash of the
        /// row AS SENT (settings: its per-key hashes). Computed before the
        /// request; never from a response body and never from the row the
        /// device holds later. Recomputed only when a 015 column is
        /// withheld from a row already built (`withholding(_:from:)`).
        var payload: PendingVerifyPayload
        /// What this flush wrote into the baseline before sending the row.
        /// Nil only before `markSent`; an unmarked row's outcome writes nothing.
        var mark: SentMark? = nil
        /// L10: the highest seq observed when the request was built.
        var watermark: Int64 = 0
    }

    /// Serial bookkeeping for one flush; the network waits overlap, the
    /// accounting does not (every completion hops to the main actor).
    private final class FlushTally {
        var succeeded = 0
        var stale = 0
        var deadRowHits = 0
        var tombstonedSingletons = 0
        var failed = 0
        var rejected = 0
        var deletes = 0
        var awaitingEcho = 0
        /// Outcomes that found their row's entry moved by a pull while the
        /// request was out, and so wrote nothing.
        var superseded = 0
        /// A write met the `user_id` foreign key: the rest of the table's
        /// flush is not sent and the account is checked (design §6.4).
        var accountMissing = false
        /// A violation was refused because a refresh had shown the account
        /// exists; that answer is spent once the flush ends.
        var accountExistsSpent = false
        var lastError: String?
        /// The class code of the last failure counted in `failed`, for the
        /// one `sync.push.failed` line a flush writes per table.
        var lastCode: String?
        var needsPull = false
        /// The write gate refused (design §6.6, the sixth class): nothing
        /// more is sent in this flush; which message decides what follows.
        var gateStopped = false
        var epochStale = false
        var paused = false
    }

    /// Whether a flush may send at all: the master switch and I1 read here,
    /// after the debounce fired, not when it was scheduled. A held table
    /// owes a flush to the next chain that reaches head; one held by the
    /// switch does not, because turning it on runs a full sync of every
    /// table (`userDidEnableUploads`).
    private func flushGate(_ table: String) -> Bool {
        guard !userId.isEmpty else { return false }
        // An injected gateway is a fake server, never production: the build
        // block does not apply to it, the switch does.
        let uploadsOn = gatewayIsInjected ? defaults.bool(forKey: AppSettingsKeys.syncUploadsEnabled) : canUpload
        guard uploadsOn else {
            logger.notice("\(table, privacy: .public): flush held — uploads off (D9)")
            return false
        }
        guard ownerState.allowsSync else {
            logger.notice("\(table, privacy: .public): flush held — local data belongs to another account (S5)")
            return false
        }
        guard inboundAtHead else {
            logger.notice("\(table, privacy: .public): flush held — inbound not at head (I1)")
            needsFlush.insert(table)
            return false
        }
        guard !serverPaused else {
            logger.notice("\(table, privacy: .public): flush held — server paused")
            needsFlush.insert(table)
            return false
        }
        return true
    }

    /// Rows that failed (not refused) are owed to the next chain that
    /// reaches head, not only to the next local edit. QA S7: rows that
    /// failed while the feed was unavailable went out only with the next
    /// edit, though the re-probe had reached head long before. A failure
    /// on the `user_id` foreign key is the account check's to settle.
    private func oweFlushAfterFailure(_ tally: FlushTally, table: String) {
        if tally.failed > 0 {
            // QA S7 (#9): failed writes reached only the unified log. One
            // line per table per flush, not per row.
            DiagnosticTrail.record("Sync", "sync.push.failed table=\(table) code=\(tally.lastCode ?? "unknown") n=\(tally.failed)")
        }
        guard tally.failed > 0, !tally.accountMissing else { return }
        needsFlush.insert(table)
    }

    /// The tail every table flush shares once the gate has spoken.
    private func settleGate(_ tally: FlushTally, table: String) {
        guard tally.gateStopped else { return }
        needsFlush.insert(table)
        if tally.epochStale { onEpochStale?() }
    }

    /// One per-row table: tombstone what left the local array, conditional
    /// PATCH what changed with a known seq, ignore-duplicates POST the rest.
    /// A row the server refused is skipped while it is still the version
    /// that was refused (survey S1).
    private func pushTable(serverTable: String, table: String, rows: [[String: Any]]) async {
        guard flushGate(table) else { return }
        let previous = baseline.entries(table: table)
        // A server without 015 refuses the whole request over one column
        // (QA S7: every events POST 400 `PGRST204` on `domino_anchor`). The
        // hash is of the row as sent, so the baseline says what the server
        // holds; once the column is sent again the row reads dirty and
        // goes out with it.
        let withheld = columnsWithheld
        if outboundFallback {
            await pushTableFallback(serverTable: serverTable, table: table, rows: rows, withheld: withheld)
            return
        }

        // Follower probe (perf batch 2a): three main-thread spans per flush —
        // the hashing, the baseline work before the sends, the baseline work
        // after them. The awaits in between are never inside a span.
        let follower = FollowerSyncTable(baselineTable: table)
        var current: [String: PushRow] = [:]
        FollowerTiming.measure(follower.hash) {
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                let sent = Self.withholding(withheld, from: row)
                current[id] = PushRow(
                    key: SyncBaselineKey(table: table, id: id),
                    row: sent,
                    payload: .rowHash(Self.rowHash(sent))
                )
            }
        }

        let baselineSpan = FollowerTiming.begin()
        // A row that left the local array while awaiting its echo still has
        // its `?` baseline entry (survey S4, gap G23), so the delete below
        // reaches it; only the echo bookkeeping lets go of it here.
        for key in awaitingEcho where key.table == table && current[key.id] == nil {
            awaitingEcho.remove(key)
        }

        let tally = FlushTally()

        // Deletes go first. The baseline follows the request OUTCOME, never
        // the body (design §6 删除段): a 2xx removes every requested id — an
        // id absent from the response was tombstoned by another device or
        // never existed, and neither needs anything more from here; a
        // failure keeps them, as the `?` written below, for the next flush.
        // A refused tombstone is not resent while the row is still absent.
        // A row inside its undo window is not a delete yet (design §10.6
        // (A)): it keeps its baseline and is skipped here until the
        // prompt is gone.
        let deletedIds = Set(previous.keys).subtracting(current.keys).filter { !undoHold.isHeld($0) }
        pruneRejected(table: table, live: Set(current.keys), deleted: deletedIds)
        let toTombstone = deletedIds.filter {
            !rejected.refuses(SyncBaselineKey(table: table, id: $0), hash: SyncRejectedSet.deletedHash)
        }.sorted()

        var patches: [(PushRow, Int64)] = []
        var posts: [PushRow] = []
        for id in current.keys.sorted() {
            let item = current[id]!
            if isRefusedUnchanged(item) { continue }
            guard let base = previous[id] else { posts.append(item); continue }
            if base.stale, base.seq == nil {
                // Rule 4 (design §6.6): a row the restored server no longer
                // holds goes back as a POST naming the version it had.
                posts.append(item)
                continue
            }
            if case .rowHash(let hash) = item.payload, base.hash == hash { continue }
            // Awaiting the pull that tells `[]` apart. A stale `[]` would
            // only repeat; an identical-content `[]` left the server seq
            // where it was, so a NEW edit re-sent at the same seq would
            // land — it still waits, because the element's sent hash is
            // what the pull confirms, and a second in-flight payload would
            // make that confirmation ambiguous. The design accepts the
            // delay (§6 上传形状: the later edit uploads after the window).
            if pendingVerify.contains(item.key) { continue }
            if let seq = base.seq {
                // The origin of this edit chain (design §6.6 来源快进): the
                // version it started from, recorded once and kept until the
                // row reads clean again.
                if let vid = base.vid, baseline.origin(table: table, id: id) == nil {
                    baseline.setOrigin(vid, table: table, id: id)
                }
                patches.append((item, seq))
            } else {
                posts.append(item)
            }
        }

        // Survey S4: every row this flush sends is marked `?` now, in the
        // tick its request is built, and the table is written once before
        // any request leaves. Nothing after this point writes a marker.
        for id in toTombstone {
            _ = markSent(SyncBaselineKey(table: table, id: id), payload: nil, seq: previous[id]?.seq)
        }
        patches = patches.map { item, seq in
            var marked = item
            marked.mark = markSent(item.key, payload: item.payload, seq: seq)
            marked.watermark = observedMaxSeq
            return (marked, seq)
        }
        posts = posts.map { item in
            var marked = item
            if !withheld.contains("parent_version_id"), let parent = reuploadParents[item.key] {
                marked.row["parent_version_id"] = parent
            }
            marked.mark = markSent(item.key, payload: item.payload, seq: nil)
            marked.watermark = observedMaxSeq
            return marked
        }
        baseline.persist()
        FollowerTiming.end(follower.baseline, baselineSpan)

        await sendTombstones(serverTable: serverTable, table: table, ids: toTombstone, individually: false, tally: tally)
        if !tally.accountMissing, !tally.gateStopped {
            await sendConditionalPatches(serverTable: serverTable, keyColumn: "id", items: patches, tally: tally)
        }
        if !tally.accountMissing, !tally.gateStopped {
            await sendInserts(serverTable: serverTable, keyColumn: "id", items: posts, tally: tally)
        }
        FollowerTiming.measure(follower.baseline) {
            baseline.persist()
            settleGate(tally, table: table)
            oweFlushAfterFailure(tally, table: table)
        }

        if tally.failed == 0, tally.rejected == 0 {
            logger.info("\(table, privacy: .public): \(tally.succeeded, privacy: .public) pushed, \(tally.deletes, privacy: .public) tombstoned, \(tally.stale, privacy: .public) pending verify, \(tally.awaitingEcho, privacy: .public) awaiting echo, \(tally.superseded, privacy: .public) settled by a pull (of \(rows.count, privacy: .public) total)")
            statusReporter?.structuredRecord(table: table, upserts: tally.succeeded, deletes: tally.deletes)
        } else {
            logger.error("\(table, privacy: .public): \(tally.succeeded, privacy: .public) pushed, \(tally.failed, privacy: .public) failed, \(tally.rejected, privacy: .public) refused (of \(rows.count, privacy: .public) total)")
            statusReporter?.structuredRecordFailure(table: table, error: tally.lastError ?? "unknown error")
        }
        spendAccountExists(in: table, tally: tally)
        if tally.accountMissing { await checkAccount(afterForeignKeyViolationIn: table) }
        if tally.needsPull { onNeedsPull?() }
    }

    /// King's shape for a server without 015 (`outboundFallback`): every row
    /// whose hash differs from the baseline goes out in a merge-duplicates
    /// upsert, every row that left the local array in a physical DELETE.
    /// The baseline follows king's rule — the hash as sent, no seq — and the
    /// `?` written before the send keeps a failed row dirty.
    private func pushTableFallback(serverTable: String, table: String, rows: [[String: Any]], withheld: Set<String>) async {
        let follower = FollowerSyncTable(baselineTable: table)
        let previous = baseline.entries(table: table)
        var current: [String: PushRow] = [:]
        FollowerTiming.measure(follower.hash) {
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                let sent = Self.withholding(withheld, from: row)
                current[id] = PushRow(key: SyncBaselineKey(table: table, id: id), row: sent, payload: .rowHash(Self.rowHash(sent)))
            }
        }
        let baselineSpan = FollowerTiming.begin()
        let tally = FlushTally()
        let deletedIds = Set(previous.keys).subtracting(current.keys).filter { !undoHold.isHeld($0) }
        pruneRejected(table: table, live: Set(current.keys), deleted: deletedIds)
        let toDelete = deletedIds.filter {
            !rejected.refuses(SyncBaselineKey(table: table, id: $0), hash: SyncRejectedSet.deletedHash)
        }.sorted()
        var upserts: [PushRow] = []
        for id in current.keys.sorted() {
            let item = current[id]!
            if isRefusedUnchanged(item) { continue }
            if let base = previous[id], case .rowHash(let hash) = item.payload, base.hash == hash { continue }
            var marked = item
            marked.mark = markSent(item.key, payload: item.payload, seq: previous[id]?.seq)
            upserts.append(marked)
        }
        baseline.persist()
        FollowerTiming.end(follower.baseline, baselineSpan)

        await sendPhysicalDeletes(serverTable: serverTable, table: table, ids: toDelete, individually: false, tally: tally)
        if !tally.accountMissing {
            await sendUpserts(serverTable: serverTable, keyColumn: "id", items: upserts, individually: false, tally: tally)
        }
        FollowerTiming.measure(follower.baseline) {
            baseline.persist()
            oweFlushAfterFailure(tally, table: table)
        }
        if tally.failed == 0, tally.rejected == 0 {
            logger.info("\(table, privacy: .public): fallback \(tally.succeeded, privacy: .public) upserted, \(tally.deletes, privacy: .public) deleted (of \(rows.count, privacy: .public) total)")
            statusReporter?.structuredRecord(table: table, upserts: tally.succeeded, deletes: tally.deletes)
        } else {
            logger.error("\(table, privacy: .public): fallback \(tally.succeeded, privacy: .public) upserted, \(tally.failed, privacy: .public) failed, \(tally.rejected, privacy: .public) refused (of \(rows.count, privacy: .public) total)")
            statusReporter?.structuredRecordFailure(table: table, error: tally.lastError ?? "unknown error")
        }
        spendAccountExists(in: table, tally: tally)
        if tally.accountMissing { await checkAccount(afterForeignKeyViolationIn: table) }
    }

    /// Merge-duplicates upserts in chunks, with the insert path's split and
    /// resend rules. A 2xx means every row in the chunk is on the server as
    /// sent: the baseline takes its hash (the seq stays whatever it was).
    private func sendUpserts(serverTable: String, keyColumn: String, items: [PushRow], individually: Bool, tally: FlushTally) async {
        guard !items.isEmpty else { return }
        let chunkSize = SyncGatewayLimits.insertChunkSize
        for start in stride(from: 0, to: items.count, by: chunkSize) {
            if tally.accountMissing { break }
            let chunk = Array(items[start..<min(start + chunkSize, items.count)])
            do {
                try await gateway.upsertMerging(table: serverTable, keyColumn: keyColumn, rows: chunk.map(\.row))
                for item in chunk {
                    schemaCacheFailures[item.key] = nil
                    guard stillMarked(item) else { tally.superseded += 1; continue }
                    writeBaseline(item.key, payload: item.payload, seq: nil)
                    awaitingEcho.remove(item.key)
                    awaitingEchoDigests[item.key] = nil
                    tally.succeeded += 1
                    clearAccountCheck(afterInsertIn: item.key.table)
                }
            } catch {
                if let column = missing015Column(in: error, rows: chunk.map(\.row), serverTable: serverTable) {
                    let stripped = chunk.map { withholding(column, from: $0) }
                    await sendUpserts(serverTable: serverTable, keyColumn: keyColumn, items: stripped, individually: individually, tally: tally)
                    continue
                }
                let failure = noteFailure(error, count: chunk.count, verb: "upsert", serverTable: serverTable)
                switch failure.kind {
                case .tooLarge where chunk.count > 1, .rejected where chunk.count > 1 && !individually:
                    for item in chunk {
                        await sendUpserts(serverTable: serverTable, keyColumn: keyColumn, items: [item], individually: true, tally: tally)
                    }
                default:
                    for item in chunk {
                        settleFailure(failure, key: item.key, refusedHash: Self.payloadDigest(item.payload), error: error, tally: tally)
                    }
                }
            }
        }
    }

    /// King's physical DELETE. A 2xx removes every requested id from the
    /// baseline; a failure keeps them for the next flush.
    private func sendPhysicalDeletes(serverTable: String, table: String, ids: [String], individually: Bool, tally: FlushTally) async {
        guard !ids.isEmpty else { return }
        do {
            try await gateway.deletePhysically(table: serverTable, keyColumn: "id", keys: ids)
            baseline.removeEntries(table: table, ids: ids)
            for id in ids {
                let key = SyncBaselineKey(table: table, id: id)
                rejected.remove(key)
                schemaCacheFailures[key] = nil
                baseline.removeOrigin(table: table, id: id)
                reuploadParents[key] = nil
            }
            tally.deletes += ids.count
        } catch {
            let failure = noteFailure(error, count: ids.count, verb: "DELETE", serverTable: serverTable)
            switch failure.kind {
            case .tooLarge where ids.count > 1, .rejected where ids.count > 1 && !individually:
                for id in ids {
                    await sendPhysicalDeletes(serverTable: serverTable, table: table, ids: [id], individually: true, tally: tally)
                }
            default:
                for id in ids {
                    settleFailure(failure, key: SyncBaselineKey(table: table, id: id), refusedHash: SyncRejectedSet.deletedHash,
                                  error: error, tally: tally)
                }
            }
        }
    }

    /// One single-row-per-user table (`user_settings`, `agent_preferences`,
    /// `agent_conversations`): the filter is `user_id=eq.<uid>` and the
    /// baseline is one entry. Same three outcomes as a per-row PATCH, except
    /// that `[row]` with `deleted_at` set IS the regular path here (design
    /// §6 单行表的 tombstone): the baseline follows the dead row's seq and
    /// the local value is never touched.
    private func pushSingleton(table: String, row: [String: Any], payload: PendingVerifyPayload, baseSeq: Int64?) async {
        let key = SyncBaselineKey(table: table, id: userId)
        guard !pendingVerify.contains(key) else { return }
        // The same payload is already on the server and its echo decides
        // (QA S7: without this, user_settings re-POSTed every 5 s on a
        // server without the feed — each send's baseline write posts
        // `didChangeNotification`, whose sink sent it again).
        if awaitingEcho.contains(key), awaitingEchoDigests[key] == Self.payloadDigest(payload) { return }
        let withheld = columnsWithheld
        var item = PushRow(key: key, row: Self.withholding(withheld, from: row), payload: payload)
        if isRefusedUnchanged(item) { return }
        if let baseSeq, let vid = baseline.entry(table: table, id: userId)?.vid,
           baseline.origin(table: table, id: userId) == nil, baseSeq == baseline.entry(table: table, id: userId)?.seq {
            baseline.setOrigin(vid, table: table, id: userId)
        }
        if baseSeq == nil, !withheld.contains("parent_version_id"), let parent = reuploadParents[key] {
            item.row["parent_version_id"] = parent
        }
        if table == "agent_preferences" {
            // What a push of this row costs now that the token columns stay
            // home (`agentPreferencesTokenColumns`).
            let bytes = (try? JSONSerialization.data(withJSONObject: item.row))?.count ?? -1
            DiagnosticTrail.record("Sync", "sync.push.agent_preferences bytes=\(bytes) columns=\(item.row.keys.sorted().joined(separator: ","))")
        }
        // Survey S4: marked, and written, before the request leaves.
        item.mark = markSent(key, payload: payload, seq: baseSeq)
        item.watermark = observedMaxSeq
        baseline.persist()
        let tally = FlushTally()
        statusReporter?.structuredBeginBurst()
        defer { statusReporter?.structuredEndBurst() }
        if outboundFallback {
            await sendUpserts(serverTable: table, keyColumn: "user_id", items: [item], individually: false, tally: tally)
        } else if let baseSeq {
            await sendConditionalPatches(serverTable: table, keyColumn: "user_id", items: [(item, baseSeq)], tally: tally)
        } else {
            await sendInserts(serverTable: table, keyColumn: "user_id", items: [item], tally: tally)
        }
        baseline.persist()
        settleGate(tally, table: table)
        oweFlushAfterFailure(tally, table: table)
        if tally.failed == 0, tally.rejected == 0 {
            logger.info("\(table, privacy: .public): pushed=\(tally.succeeded, privacy: .public) pending=\(tally.stale, privacy: .public) echo=\(tally.awaitingEcho, privacy: .public) settled-by-pull=\(tally.superseded, privacy: .public)")
            statusReporter?.structuredRecord(table: table, upserts: tally.succeeded, deletes: 0)
        } else {
            logger.error("\(table, privacy: .public) upload failed: \(tally.lastError ?? "unknown error", privacy: .public)")
            statusReporter?.structuredRecordFailure(table: table, error: tally.lastError ?? "unknown error")
        }
        spendAccountExists(in: table, tally: tally)
        if tally.accountMissing { await checkAccount(afterForeignKeyViolationIn: table) }
        if tally.needsPull { onNeedsPull?() }
    }

    // MARK: - Refused rows and unknown results (survey S1 / S4)

    /// What a refused version is remembered by: the row hash, or for the
    /// settings row a digest of its per-key hashes.
    static func payloadDigest(_ payload: PendingVerifyPayload) -> String {
        switch payload {
        case .rowHash(let hash):
            return hash
        case .settingsKeys(let keys):
            return syncRowHash(keys.mapValues { $0 as Any })
        }
    }

    /// True while the row is the version the server refused: it is not sent.
    /// A row that changed since loses its refusal here and goes out.
    private func isRefusedUnchanged(_ item: PushRow) -> Bool {
        guard let refused = rejected[item.key] else { return false }
        if refused.hash == Self.payloadDigest(item.payload) { return true }
        rejected.remove(item.key)
        return false
    }

    /// The 015 columns withheld from this flush's writes: all of them while
    /// the feed is unavailable, and any a `PGRST204` named this session.
    var columnsWithheld: Set<String> {
        (inbound?.feedUnavailable == true ? Self.only015Columns : []).union(serverMissingColumns)
    }

    static func withholding(_ columns: Set<String>, from row: [String: Any]) -> [String: Any] {
        guard !columns.isEmpty else { return row }
        return row.filter { !columns.contains($0.key) }
    }

    /// The row without `column`, its payload rehashed over what is sent
    /// (the version columns are the server's and never part of the hash).
    private func withholding(_ column: String, from item: PushRow) -> PushRow {
        var next = item
        next.row[column] = nil
        if case .rowHash = item.payload {
            let hashed = next.row.filter { $0.key != "parent_version_id" && $0.key != "restored_from_version_id" }
            next.payload = .rowHash(Self.rowHash(hashed))
        }
        return next
    }

    /// A `PGRST204` naming a 015 column one of `rows` carries: the server
    /// has no 015 (or not this column of it). Remembered for the session,
    /// logged once, and the column is returned so the caller resends the
    /// request once without it. Any other error, or a column the rows do
    /// not carry, returns nil and fails the usual way.
    private func missing015Column(in error: Error, rows: [[String: Any]], serverTable: String) -> String? {
        guard case SupabaseREST.SyncError.missingColumn(_, _, let column) = error,
              Self.only015Columns.contains(column),
              rows.contains(where: { $0[column] != nil })
        else { return nil }
        if serverMissingColumns.insert(column).inserted {
            DiagnosticTrail.record("Sync", "sync.push.column_withheld table=\(serverTable) column=\(column)")
            logger.error("\(serverTable, privacy: .public): the server has no column \(column, privacy: .public) (no migration 015); withheld from writes this session")
        }
        return column
    }

    /// Refusals of rows that no longer exist locally (or, for a refused
    /// tombstone, rows that came back) are dropped; they describe nothing.
    private func pruneRejected(table: String, live: Set<String>, deleted: Set<String>) {
        for id in rejected.ids(table: table) {
            let key = SyncBaselineKey(table: table, id: id)
            guard let element = rejected[key] else { continue }
            let stillMeaningful = element.hash == SyncRejectedSet.deletedHash ? deleted.contains(id) : live.contains(id)
            if !stillMeaningful { rejected.remove(key) }
        }
    }

    /// A refusal: remembered with the refused version, a trail line for
    /// each new `(table, id, hash)`, local value untouched and the baseline
    /// left at the `?` the send wrote.
    private func reject(_ key: SyncBaselineKey, hash: String, failure: SyncWriteFailure, tally: FlushTally) {
        schemaCacheFailures[key] = nil
        if rejected.insert(key, hash: hash, code: failure.code) {
            DiagnosticTrail.record("Sync", "sync.push.rejected table=\(key.table) id=\(key.id) code=\(failure.code)")
        }
        tally.rejected += 1
        tally.lastError = "\(key.table) \(key.id) refused by the server (\(failure.code))"
        logger.error("\(key.table, privacy: .public) \(key.id, privacy: .public) refused (\(failure.code, privacy: .public)); not resent until it changes")
    }

    /// Schema-cache errors are retried until the row has met them on
    /// enough flushes AND for long enough that a schema reload would have
    /// happened; past those, they count as a refusal.
    private func schemaCacheWindowExpired(_ key: SyncBaselineKey) -> Bool {
        let now = scheduler.now()
        var record = schemaCacheFailures[key] ?? (first: now, attempts: 0)
        record.attempts += 1
        schemaCacheFailures[key] = record
        return record.attempts >= SupabaseSyncConfig.schemaCacheRetryAttempts
            && now.timeIntervalSince(record.first) >= SupabaseSyncConfig.schemaCacheRetryWindowSeconds
    }

    /// Survey S4 (design §6 结果未知的写): the row is about to be sent, so
    /// its baseline entry becomes `?` — hash unknown, seq kept — which no
    /// local hash equals: until an outcome settles it, the row is dirty
    /// whatever the user puts in it, including the old value. The settings
    /// row marks each key the write would change; a legacy settings value
    /// is left as it is (the applier's upgrade needs it, and its POST always
    /// meets the row that exists). Returns what was written, for the
    /// outcome's compare-and-set.
    private func markSent(_ key: SyncBaselineKey, payload: PendingVerifyPayload?, seq: Int64?) -> SentMark {
        if key.table == SyncBaselineStore.settingsTable {
            guard case .settingsKeys(let sentKeys)? = payload else { return .settings(baseline.settings) }
            switch baseline.settings {
            case .versioned(let baseSeq, let keys, let zone):
                var marked = keys
                for name in Set(keys.keys).union(sentKeys.keys) where keys[name] != sentKeys[name] {
                    marked[name] = SyncBaselineEntry.unknownHash
                }
                baseline.setSettings(.versioned(seq: baseSeq, keys: marked, zone: zone))
            case nil:
                baseline.setSettings(.versioned(seq: nil, keys: sentKeys.mapValues { _ in SyncBaselineEntry.unknownHash }, zone: nil))
            case .legacy:
                break
            }
            return .settings(baseline.settings)
        }
        // The marker keeps the entry's version id and its catch-up marker:
        // a stale entry marked `?` is still stale (the §6.6 pre-rules keep
        // deciding it), and a reset that marks an in-flight `?` stale makes
        // it unequal to the marker the send wrote, so a response from the
        // old timeline writes nothing (the ABA case of §6 结果未知的写).
        let existing = baseline.entry(table: key.table, id: key.id)
        let marker = SyncBaselineEntry(hash: SyncBaselineEntry.unknownHash, seq: seq,
                                       vid: existing?.vid, stale: existing?.stale ?? false)
        baseline.setEntry(marker, table: key.table, id: key.id)
        return .entry(marker)
    }

    /// The compare half of every outcome's compare-and-set: the row's entry
    /// is still what its send wrote. False once a pull moved it (the
    /// three-way compare wrote `(h_in, seq)`, or the tombstone branch
    /// removed it): the result is already known and nothing is written.
    private func stillMarked(_ item: PushRow) -> Bool {
        switch item.mark {
        case .entry(let marker)?:
            return baseline.entry(table: item.key.table, id: item.key.id) == marker
        case .settings(let value)?:
            return baseline.settings == value
        case nil:
            return false
        }
    }

    /// The log line every failed write shares. Writes nothing to the
    /// baseline: the `?` the send wrote stays, and the row goes out again
    /// on the next flush. Returns the failure so the caller can split or
    /// resend a multi-row request.
    private func noteFailure(_ error: Error, count: Int, verb: String, serverTable: String) -> SyncWriteFailure {
        let failure = SyncWriteFailure.classify(error)
        logger.error("\(serverTable, privacy: .public) \(verb, privacy: .public) of \(count, privacy: .public) failed (\(failure.code, privacy: .public)\(failure.mayHaveLanded ? ", result unknown" : "", privacy: .public)): \(error.localizedDescription, privacy: .public)")
        return failure
    }

    /// The single-row tail of every failure: refuse, wait out the schema
    /// cache, stop the table for an account check, or leave the row for
    /// the next flush.
    private func settleFailure(_ failure: SyncWriteFailure, key: SyncBaselineKey, refusedHash: String, error: Error, tally: FlushTally) {
        if failure.kind != .rejected, failure.kind != .tooLarge { tally.lastCode = failure.code }
        switch failure.kind {
        case .rejected, .tooLarge:
            reject(key, hash: refusedHash, failure: failure, tally: tally)
        case .schemaCache:
            if schemaCacheWindowExpired(key) {
                reject(key, hash: refusedHash, failure: failure, tally: tally)
            } else {
                tally.failed += 1
                tally.lastError = error.localizedDescription
            }
        case .accountMissing:
            if case .accountExists(let checked) = accountCheck, checked == key.table {
                // A refresh already showed the account exists: another cause.
                reject(key, hash: refusedHash, failure: failure, tally: tally)
                tally.accountExistsSpent = true
            } else {
                schemaCacheFailures[key] = nil
                tally.failed += 1
                tally.accountMissing = true
                // Sync Status shows this to the user: words, not the
                // constraint name (sim QA round 2). The trail keeps the code.
                tally.lastError = L(.syncErrorAccountMayBeGone)
            }
        case .retryable, .unauthorized:
            schemaCacheFailures[key] = nil
            tally.failed += 1
            tally.lastError = error.localizedDescription
        case .epochStale, .paused:
            // The sixth class (design §6.6): not a rejection, no backoff.
            // The `?` the send wrote stays; the flush stops here.
            schemaCacheFailures[key] = nil
            tally.failed += 1
            tally.lastError = error.localizedDescription
            if !tally.gateStopped {
                let reason = failure.kind == .epochStale ? "stale" : "paused"
                DiagnosticTrail.record("Sync", "sync.push.gate_rejected reason=\(reason) table=\(key.table)")
            }
            tally.gateStopped = true
            if failure.kind == .epochStale { tally.epochStale = true } else { tally.paused = true }
        }
    }

    /// Design §6.4, S12's detection half: a write met the `user_id` foreign
    /// key, so the account may have been erased on another device. Force a
    /// token refresh and record what it showed. A terminal refresh is
    /// `AuthService`'s own path (gh#234: the session is cleared, the
    /// re-authentication banner set, and `$session → nil` ends this
    /// session); any other outcome leaves the rows dirty for the next flush.
    /// One check at a time; a flush meeting the violation meanwhile waits
    /// for the next.
    private func checkAccount(afterForeignKeyViolationIn table: String) async {
        guard !accountRefreshInFlight else { return }
        accountRefreshInFlight = true
        defer { accountRefreshInFlight = false }
        let uid = userId
        accountCheck = .suspected(table: table)
        DiagnosticTrail.record("Sync", "sync.account.fk_missing table=\(table)")
        logger.error("\(table, privacy: .public): user_id foreign key violated; the account may no longer exist — forcing a token refresh")
        let outcome = await forceTokenRefresh()
        switch outcome {
        case .signedOut:
            accountCheck = .signedOut(table: table)
            defaults.set(table, forKey: Self.accountGoneTableKey)
            DiagnosticTrail.record("Sync", "sync.account.refresh outcome=signed_out table=\(table)")
        case .refreshed:
            guard userId == uid else { return }
            accountCheck = .accountExists(table: table)
            DiagnosticTrail.record("Sync", "sync.account.refresh outcome=refreshed table=\(table)")
        case .kept:
            DiagnosticTrail.record("Sync", "sync.account.refresh outcome=kept table=\(table)")
        }
    }

    /// A refresh's "the account exists" answers the violation it was raised
    /// for, once: after the flush that refused on it, the next violation in
    /// the table is checked afresh, so an erasure later in the session is
    /// still detected rather than read as another refusal.
    private func spendAccountExists(in table: String, tally: FlushTally) {
        guard tally.accountExistsSpent, case .accountExists(table) = accountCheck else { return }
        accountCheck = .none
    }

    /// An insert landed in the table the check was raised for: the account
    /// is there, and the next violation starts a fresh check.
    private func clearAccountCheck(afterInsertIn table: String) {
        switch accountCheck {
        case .suspected(table), .accountExists(table):
            accountCheck = .none
        default:
            break
        }
    }

    private func forceTokenRefresh() async -> SyncTokenRefreshOutcome {
        if let tokenRefresher { return await tokenRefresher() }
        guard let authService else { return .kept }
        return await Self.forceRefresh(authService)
    }

    /// `AuthService`'s forced refresh, read back from the session it left:
    /// none (its terminal path cleared it), a new access token, or the same.
    static func forceRefresh(_ auth: AuthService) async -> SyncTokenRefreshOutcome {
        let before = auth.accessToken
        await auth.forceRefreshToken()
        guard let after = auth.accessToken else { return .signedOut }
        return after == before ? .kept : .refreshed
    }

    /// The tombstone PATCH for `ids`, with the S1 split and resend rules:
    /// too large → halves; refused with several ids → each id resent on its
    /// own, so a refused id does not hold the others back. A 2xx removes
    /// the entries whatever a pull did meanwhile: the request stamped every
    /// live row it named, so the server row is dead either way.
    private func sendTombstones(serverTable: String, table: String, ids: [String], individually: Bool, tally: FlushTally) async {
        guard !ids.isEmpty, !tally.gateStopped else { return }
        do {
            let watermark = observedMaxSeq
            let stamped = try await gateway.tombstone(
                table: serverTable, keyColumn: "id", keys: ids, deletedAt: scheduler.now()
            )
            baseline.removeEntries(table: table, ids: ids)
            for id in ids {
                let key = SyncBaselineKey(table: table, id: id)
                rejected.remove(key)
                schemaCacheFailures[key] = nil
                baseline.removeOrigin(table: table, id: id)
                reuploadParents[key] = nil
            }
            for row in stamped {
                if let seq = (row["seq"] as? NSNumber)?.int64Value { noteWriteSeq(seq, watermark: watermark, table: table) }
            }
            tally.deletes += ids.count
            logger.info("\(table, privacy: .public): tombstoned \(ids.count, privacy: .public) (\(stamped.count, privacy: .public) stamped now)")
        } catch {
            let keys = ids.map { SyncBaselineKey(table: table, id: $0) }
            let failure = noteFailure(error, count: ids.count, verb: "tombstone", serverTable: serverTable)
            switch failure.kind {
            case .tooLarge where ids.count > 1:
                let middle = ids.count / 2
                await sendTombstones(serverTable: serverTable, table: table, ids: Array(ids[..<middle]), individually: individually, tally: tally)
                await sendTombstones(serverTable: serverTable, table: table, ids: Array(ids[middle...]), individually: individually, tally: tally)
            case .rejected where ids.count > 1 && !individually:
                for id in ids {
                    await sendTombstones(serverTable: serverTable, table: table, ids: [id], individually: true, tally: tally)
                }
            default:
                for key in keys {
                    settleFailure(failure, key: key, refusedHash: SyncRejectedSet.deletedHash, error: error, tally: tally)
                }
            }
        }
    }

    /// Conditional PATCHes, at most `maxConcurrentPatches` in flight. The
    /// children are main-actor closures: the `await` on the gateway lets
    /// the next one start, every completion's bookkeeping runs serially.
    private func sendConditionalPatches(
        serverTable: String,
        keyColumn: String,
        items: [(PushRow, Int64)],
        tally: FlushTally
    ) async {
        guard !items.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for (index, (item, baseSeq)) in items.enumerated() {
                if index >= SyncGatewayLimits.maxConcurrentPatches {
                    await group.next()
                }
                // The gate spoke on an earlier row: the rest of this flush
                // is not sent (the `?` they carry keeps them dirty).
                if tally.gateStopped { break }
                group.addTask { @MainActor in
                    var sent = item
                    var result = await self.performConditionalPatch(
                        serverTable: serverTable, keyColumn: keyColumn, item: sent, baseSeq: baseSeq
                    )
                    if case .failure(let error) = result,
                       let column = self.missing015Column(in: error, rows: [sent.row], serverTable: serverTable) {
                        sent = self.withholding(column, from: sent)
                        result = await self.performConditionalPatch(
                            serverTable: serverTable, keyColumn: keyColumn, item: sent, baseSeq: baseSeq
                        )
                    }
                    self.record(result, for: sent, baseSeq: baseSeq, serverTable: serverTable, tally: tally)
                }
            }
            await group.waitForAll()
        }
    }

    /// One PATCH; a `40P01` deadlock victim is re-sent once with the same
    /// seq (the server wrote nothing, §9.17). Whatever the re-send returns
    /// is final — a `[]` goes to pending-verify like any other.
    private func performConditionalPatch(
        serverTable: String,
        keyColumn: String,
        item: PushRow,
        baseSeq: Int64
    ) async -> Result<[[String: Any]], Error> {
        do {
            return .success(try await gateway.patchConditional(
                table: serverTable, keyColumn: keyColumn, key: item.key.id, baseSeq: baseSeq, body: item.row
            ))
        } catch SupabaseREST.SyncError.requestFailed(_, _, _, let code) where code == "40P01" {
            do {
                return .success(try await gateway.patchConditional(
                    table: serverTable, keyColumn: keyColumn, key: item.key.id, baseSeq: baseSeq, body: item.row
                ))
            } catch {
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    /// The three response shapes (design §6 上传形状), judged by the body
    /// and written only while the entry is still the `?@sentSeq` this send
    /// wrote (survey S4); a failure by its class (survey S1), writing
    /// nothing to the baseline.
    private func record(
        _ result: Result<[[String: Any]], Error>,
        for item: PushRow,
        baseSeq: Int64,
        serverTable: String,
        tally: FlushTally
    ) {
        switch result {
        case .failure(let error):
            // A single row: there is nothing to split, so a 413 / 414 is the
            // row's own size and is refused like any rejection.
            let failure = noteFailure(error, count: 1, verb: "PATCH", serverTable: serverTable)
            settleFailure(failure, key: item.key, refusedHash: Self.payloadDigest(item.payload), error: error, tally: tally)
        case .success(let rows):
            schemaCacheFailures[item.key] = nil
            guard stillMarked(item) else {
                // A pull settled the row while the request was out: its
                // `(hash, seq)` is newer than anything this answer carries,
                // and a `[]` here is explained by the seq it moved.
                tally.superseded += 1
                return
            }
            guard let row = rows.first else {
                // Stale or content-identical; the eligible pull decides.
                pendingVerify.insert(item.key, sentSeq: baseSeq, payload: item.payload, pullIssue: pullIssueCounter())
                tally.stale += 1
                tally.needsPull = true
                return
            }
            guard let seq = (row["seq"] as? NSNumber)?.int64Value else {
                // A 2xx the write ran under, with a body that cannot say
                // which seq it took: the `?` stays, result unknown.
                tally.failed += 1
                tally.lastCode = "no_seq"
                tally.lastError = "\(serverTable): response row without seq"
                return
            }
            let dead = Self.isTombstoned(row)
            let singleton = Self.isSingletonTable(item.key.table)
            noteWriteSeq(seq, watermark: item.watermark, table: serverTable)
            if dead && !singleton {
                // Reachable only if the baseline holds a dead row's seq —
                // a bug by the design's own rules, so the baseline is not
                // advanced; the pull brings the tombstone and the applier
                // handles it as one (shelf, cascade, baseline removal).
                tally.deadRowHits += 1
                tally.needsPull = true
                DiagnosticTrail.record("Sync", "sync.push.dead_row_hit table=\(serverTable) id=\(item.key.id) seq=\(seq)")
                logger.error("\(serverTable, privacy: .public): PATCH hit a dead row \(item.key.id, privacy: .public); baseline untouched, pull requested")
                return
            }
            writeBaseline(item.key, payload: item.payload, seq: seq, vid: row["version_id"] as? String)
            tally.succeeded += 1
            if dead {
                if tally.tombstonedSingletons == 0 {
                    DiagnosticTrail.record("Sync", "sync.push.tombstoned_singleton table=\(serverTable) seq=\(seq)")
                }
                tally.tombstonedSingletons += 1
            }
        }
    }

    /// Ignore-duplicates POSTs in chunks. Returned rows set the baseline to
    /// (hash of the local row, response seq); a row the response omits
    /// already existed server-side and waits for its echo. A chunk that met
    /// the `user_id` foreign key stops the rest: they would meet it too.
    private func sendInserts(
        serverTable: String,
        keyColumn: String,
        items: [PushRow],
        tally: FlushTally
    ) async {
        guard !items.isEmpty else { return }
        let chunkSize = SyncGatewayLimits.insertChunkSize
        for start in stride(from: 0, to: items.count, by: chunkSize) {
            if tally.accountMissing || tally.gateStopped { break }
            let chunk = Array(items[start..<min(start + chunkSize, items.count)])
            await sendInsertChunk(serverTable: serverTable, keyColumn: keyColumn, chunk: chunk, individually: false, tally: tally)
        }
    }

    /// One POST, with the S1 split and resend rules: too large → halves;
    /// refused with several rows → each row resent on its own, so only the
    /// row that is actually refused stays behind and the rest proceed.
    private func sendInsertChunk(
        serverTable: String,
        keyColumn: String,
        chunk: [PushRow],
        individually: Bool,
        tally: FlushTally
    ) async {
        guard !chunk.isEmpty else { return }
        do {
            let returned = try await gateway.insertIgnoringDuplicates(table: serverTable, rows: chunk.map(\.row))
            // The server renders uuid ids lowercase; the rows were sent
            // with `UUID.uuidString`. Match on the folded form.
            var seqs: [String: Int64] = [:]
            var vids: [String: String] = [:]
            // Rows the server inserted. Without migration 015 a row has no
            // `seq`: it landed all the same, as sent, and the baseline
            // takes its hash with no seq (the seat belt's whole-table diff
            // upload); the pull after 015 settles the seq.
            var landed: Set<String> = []
            for row in returned {
                guard let id = row[keyColumn] as? String else { continue }
                landed.insert(SyncBaselineKey.matchKey(id))
                if let seq = (row["seq"] as? NSNumber)?.int64Value {
                    seqs[SyncBaselineKey.matchKey(id)] = seq
                    vids[SyncBaselineKey.matchKey(id)] = row["version_id"] as? String
                }
            }
            for item in chunk {
                schemaCacheFailures[item.key] = nil
                if let seq = seqs[SyncBaselineKey.matchKey(item.key.id)] {
                    noteWriteSeq(seq, watermark: item.watermark, table: serverTable)
                }
                guard stillMarked(item) else {
                    // The echo came first and the three-way compare wrote
                    // the row's `(hash, seq)`; this answer is older news.
                    tally.superseded += 1
                    continue
                }
                if landed.contains(SyncBaselineKey.matchKey(item.key.id)) {
                    let seq = seqs[SyncBaselineKey.matchKey(item.key.id)]
                    writeBaseline(item.key, payload: item.payload, seq: seq, vid: vids[SyncBaselineKey.matchKey(item.key.id)])
                    awaitingEcho.remove(item.key)
                    awaitingEchoDigests[item.key] = nil
                    tally.succeeded += 1
                    clearAccountCheck(afterInsertIn: item.key.table)
                } else {
                    // The server already had this key. Its seq comes with
                    // the echo; until then the `?` the send wrote stays,
                    // and it is what lets a local delete in the meantime
                    // still send the tombstone (G23).
                    awaitingEcho.insert(item.key)
                    awaitingEchoDigests[item.key] = Self.payloadDigest(item.payload)
                    tally.awaitingEcho += 1
                }
            }
        } catch {
            if let column = missing015Column(in: error, rows: chunk.map(\.row), serverTable: serverTable) {
                // Once, without the column: the stripped rows cannot name it again.
                let stripped = chunk.map { withholding(column, from: $0) }
                await sendInsertChunk(serverTable: serverTable, keyColumn: keyColumn, chunk: stripped, individually: individually, tally: tally)
                return
            }
            let failure = noteFailure(error, count: chunk.count, verb: "POST", serverTable: serverTable)
            switch failure.kind {
            case .tooLarge where chunk.count > 1:
                let middle = chunk.count / 2
                await sendInsertChunk(serverTable: serverTable, keyColumn: keyColumn, chunk: Array(chunk[..<middle]), individually: individually, tally: tally)
                await sendInsertChunk(serverTable: serverTable, keyColumn: keyColumn, chunk: Array(chunk[middle...]), individually: individually, tally: tally)
            case .rejected where chunk.count > 1 && !individually:
                for item in chunk {
                    await sendInsertChunk(serverTable: serverTable, keyColumn: keyColumn, chunk: [item], individually: true, tally: tally)
                }
            default:
                for item in chunk {
                    settleFailure(failure, key: item.key, refusedHash: Self.payloadDigest(item.payload), error: error, tally: tally)
                }
            }
        }
    }

    nonisolated static func isSingletonTable(_ table: String) -> Bool {
        singletonTables.contains(table)
    }

    /// user_settings, agent_preferences, agent_conversations.
    nonisolated static let singletonTables: Set<String> = SyncBaselineStore.scalarTables.union([SyncBaselineStore.settingsTable])

    // MARK: - Sync: User Settings

    /// One row per user, merged per key (design §6 user_settings 段): the
    /// whole blob goes out conditional on the baseline seq, and "changed"
    /// means the per-key hashes of the blob as sent differ from the baseline.
    func syncSettings() async {
        guard flushGate("user_settings") else { return }
        guard !Self.settingsExportSuppressed(defaults) else { return }
        // Follower probe (perf batch 2a): the settings row and its per-key
        // hashes, which every UserDefaults write re-arms (5 s debounce).
        let span = FollowerTiming.begin()
        let local = SyncedSettings.currentSnapshot(defaults)
        let base = baseline.settings
        let blob = Self.settingsBlobForUpload(local: local, serverZone: base?.zone)
        let sentKeys = Self.settingsKeyHashes(blob)
        let row = settingsRow(blob)
        FollowerTiming.end(.syncSettings, span)

        switch base {
        case .versioned(let seq, let keys, _):
            guard keys != sentKeys else { return }
            await pushSingleton(table: "user_settings", row: row, payload: .settingsKeys(sentKeys), baseSeq: seq)
        case .legacy(let legacyHash):
            // Still legacy means the local row had changed since the last
            // upload when this user signed in — unless it changed back.
            // Compared in the form the legacy hash was taken in: the local
            // snapshot as stored, before the canonical form.
            if legacyHash == Self.rowHash(settingsRow(local)) {
                baseline.setSettings(.versioned(seq: nil, keys: sentKeys, zone: nil))
                baseline.persist()
                return
            }
            // Server version unknown: POST. The row exists, so the response
            // is `[]` and the applier's upgrade (with the remote row) is what
            // moves this baseline forward.
            await pushSingleton(table: "user_settings", row: row, payload: .settingsKeys(sentKeys), baseSeq: nil)
        case nil:
            await pushSingleton(table: "user_settings", row: row, payload: .settingsKeys(sentKeys), baseSeq: nil)
        }
    }

    private func settingsIsClean() -> Bool {
        settingsIsClean(against: baseline.settings)
    }

    private func settingsIsClean(against settings: SyncSettingsBaseline?) -> Bool {
        let local = SyncedSettings.currentSnapshot(defaults)
        switch settings {
        case .versioned(_, let keys, let zone):
            return keys == Self.settingsKeyHashes(Self.settingsBlobForUpload(local: local, serverZone: zone))
        case .legacy(let hash):
            return hash == Self.rowHash(settingsRow(local))
        case nil:
            return false
        }
    }

    func settingsRow(_ blob: [String: Any]) -> [String: Any] {
        [
            "user_id": userId,
            "settings": blob,
            "updated_at": iso(scheduler.now()),
            "synced_at": iso(scheduler.now()),
        ]
    }

    /// The row as the legacy scalar hash saw it (no zone override), for the
    /// inspect UI and `markRestoreCompleted`.
    private func settingsToRow() -> [String: Any] {
        settingsRow(SyncedSettings.currentSnapshot(defaults))
    }

    // MARK: - Sync: Agent Preferences (rules + decision history)

    /// Single-row-per-user, whole-row hash. Rules and history are encoded as
    /// JSON arrays directly into the row payload so jsonb storage preserves
    /// the typed Swift model shape without a relational schema for every
    /// nested enum / associated value.
    func syncAgentPreferences(_ store: AgentPreferenceStore) async {
        guard flushGate("agent_preferences") else { return }
        let row = agentPreferencesToRow(store)
        let hash = Self.rowHash(row)
        let stored = baseline.entry(table: "agent_preferences", id: userId)
        let base = preferencesBaseInTokenFreeProjection(stored, rules: store.rules, decisionHistory: store.decisionHistory)
        if let base, base.hash != stored?.hash {
            // The same server version, re-hashed: kept so the next flush
            // reads it without hashing the token state again.
            baseline.setEntry(base, table: "agent_preferences", id: userId)
            baseline.persist()
        }
        guard base?.hash != hash || Self.isStaleReupload(base) else { return }
        await pushSingleton(table: "agent_preferences", row: row, payload: .rowHash(hash), baseSeq: base?.seq)
    }

    // MARK: - Sync: Agent Conversations (chat history)

    /// One-row-per-user blob of the chat history. Read from
    /// `AgentConversationRepository`, which is the canonical singleton this
    /// used to say did not exist: the several `@StateObject AgentService()`
    /// instances shared their state through `UserDefaults`, and when those
    /// bytes moved to a file they needed one owner rather than N caches.
    func syncAgentConversations() async {
        guard flushGate("agent_conversations") else { return }
        guard !Self.agentConversationsExportSuppressed() else { return }
        let row = agentConversationsToRow()
        let hash = Self.rowHash(row)
        let base = baseline.entry(table: "agent_conversations", id: userId)
        guard base?.hash != hash || Self.isStaleReupload(base) else { return }
        await pushSingleton(table: "agent_conversations", row: row, payload: .rowHash(hash), baseSeq: base?.seq)
    }

    /// Rule 4 (design §6.6): an entry the catch-up left stale and seq-less
    /// goes out even though its hash still equals the local row.
    nonisolated static func isStaleReupload(_ base: SyncBaselineEntry?) -> Bool {
        guard let base else { return false }
        return base.stale && base.seq == nil
    }

    // MARK: - Row builders for the two single-row blob tables

    /// The token-inference columns of `agent_preferences` (migration 011).
    /// This build neither sends nor reads them: the state has no UI, and at
    /// megabytes per row it was most of every push of the row and most of
    /// its server timeouts. The row leaves them OUT, never sends them as
    /// null — a build from before this one decodes null as an empty slice,
    /// overwrites its own state with it, rebuilds it and pushes it whole
    /// again. A column a write does not carry stays as it is on the server,
    /// so older builds still sync theirs among themselves. Inbound they are
    /// ignored: not applied, and not part of the hash, so a change to them
    /// alone is no change. See AgentPreferencesTokenFreeSyncTests.
    nonisolated static let agentPreferencesTokenColumns = ["token_dynamic_hypotheses", "token_meta_hypotheses", "token_projections"]

    /// Same shape `syncAgentPreferences` uploads; extracted so
    /// `markRestoreCompleted` can reseed the diff baseline without
    /// re-uploading the bytes that just landed via restore.
    ///
    /// `rules` / `decision_history` are `jsonb not null` (migration 009),
    /// so an empty array goes out as `[]`, never as null (bench S13: null
    /// was a 400 on every upload for a zero-rule user).
    func agentPreferencesToRow(_ store: AgentPreferenceStore) -> [String: Any] {
        agentPreferencesRow(rules: store.rules, decisionHistory: store.decisionHistory)
    }

    /// The one projection of the agent_preferences row, from the values it
    /// carries: the local store's for the upload and the local hash, an
    /// incoming row's decoded values for the applier, a restore snapshot's
    /// for the restore baseline (S6), nothing for the empty row (gh#257).
    /// It has no token column (`agentPreferencesTokenColumns`).
    func agentPreferencesRow(rules: [AgentPreferenceRule], decisionHistory: [AgentDecisionRecord]) -> [String: Any] {
        [
            "user_id": userId,
            "rules": Self.encodeJSONArray(rules),
            "decision_history": Self.encodeJSONArray(decisionHistory),
            "updated_at": iso(scheduler.now()),
            "synced_at": iso(scheduler.now()),
        ]
    }

    /// The rules and history an incoming agent_preferences row (a feed row,
    /// a restore row) carries. A column that is missing or null is empty; a
    /// column that is present but does not decode (a newer build's field)
    /// makes the row unreadable — nil — so it is never adopted as empty
    /// arrays over the local ones. The token columns are not decoded.
    static func agentPreferencesSlices(_ row: [String: Any]) -> (rules: [AgentPreferenceRule], decisionHistory: [AgentDecisionRecord])? {
        guard let rules: [AgentPreferenceRule] = decodedSlice(row["rules"]),
              let decisions: [AgentDecisionRecord] = decodedSlice(row["decision_history"])
        else { return nil }
        return (rules, decisions)
    }

    /// The token columns `row` carries with a value, for the trail line
    /// that says they were ignored.
    nonisolated static func agentPreferencesTokenColumnsPresent(_ row: [String: Any]) -> [String] {
        agentPreferencesTokenColumns.filter { column in
            guard let value = row[column] else { return false }
            return !(value is NSNull)
        }
    }

    private static func decodedSlice<T: Decodable>(_ value: Any?) -> [T]? {
        guard let value, !(value is NSNull) else { return [] }
        return decodeJSONArray(value)
    }

    // MARK: agent_preferences: the upgrade from the token-bearing row

    /// The three token columns as builds that still synced the token state
    /// sent them (null when empty). Today's row plus these is the row those
    /// builds hashed; read only by `preferencesBaseInTokenFreeProjection`.
    private static func legacyTokenColumns(_ tokens: TokenInferenceRepository.Snapshot) -> [String: Any] {
        [
            "token_dynamic_hypotheses": encodeJSONOrNull(tokens.dynamic),
            "token_meta_hypotheses": encodeJSONOrNull(tokens.meta),
            "token_projections": encodeJSONOrNull(tokens.projections),
        ]
    }

    /// The token slices of an incoming row the way those builds decoded
    /// them; nil when one does not decode (they could not have hashed it).
    private static func legacyTokenSlices(_ row: [String: Any]) -> TokenInferenceRepository.Snapshot? {
        guard let dynamic: [TokenDynamicHypothesisRecord] = decodedSlice(row["token_dynamic_hypotheses"]),
              let meta: [TokenMetaHypothesisRecord] = decodedSlice(row["token_meta_hypotheses"]),
              let projections: [TokenOccurrenceProjectionRecord] = decodedSlice(row["token_projections"])
        else { return nil }
        return (dynamic, meta, projections)
    }

    /// The agent_preferences baseline entry as the token-free projection
    /// reads it.
    ///
    /// An entry written before the token columns left the row holds the
    /// hash of the row WITH them, which no token-free hash equals. Read as
    /// it is, the local row looks edited, and a peer's rules change meets
    /// it as a conflict: a shelf line, and the peer's rules kept off this
    /// device. So an entry that is the legacy hash of a row this device can
    /// name — its own rules and history, or the incoming row's, under
    /// either side's token state — is rewritten as that row's token-free
    /// hash. Seq, version id and the catch-up marker stay: the server
    /// version the entry names is the same one.
    ///
    /// An entry already token-free, the `?` marker, or one nothing here
    /// explains comes back unchanged, and the §6 table reads it as before.
    /// That last case is a device whose token state moved after its last
    /// baseline write; it can still conflict, but only when the rules or
    /// history differ, and it stays local-kept, peer-shelved. A miss is
    /// remembered for the session, so a device that cannot be explained
    /// does not re-hash the token state on every flush.
    func preferencesBaseInTokenFreeProjection(_ entry: SyncBaselineEntry?, rules: [AgentPreferenceRule],
                                              decisionHistory: [AgentDecisionRecord],
                                              incoming: [String: Any]? = nil) -> SyncBaselineEntry? {
        guard var entry, !entry.isUnknown else { return entry }
        let localHash = Self.rowHash(agentPreferencesRow(rules: rules, decisionHistory: decisionHistory))
        if entry.hash == localHash { return entry }
        var sides = [(rules: rules, decisionHistory: decisionHistory, hash: localHash, name: "local")]
        if let incoming, let slices = Self.agentPreferencesSlices(incoming) {
            let incomingHash = Self.rowHash(agentPreferencesRow(rules: slices.rules, decisionHistory: slices.decisionHistory))
            if entry.hash == incomingHash { return entry }
            sides.append((slices.rules, slices.decisionHistory, incomingHash, "incoming"))
        }
        // Keyed without the local hash: a later local edit makes the entry
        // no easier to explain, and the token state is what is missing.
        let attempt = entry.hash + "|" + (sides.count > 1 ? sides[1].hash : "")
        guard !unexplainedPreferencesBases.contains(attempt) else { return entry }
        var tokenStates = [legacyTokenState()]
        if sides.count > 1, let incoming, let tokens = Self.legacyTokenSlices(incoming) { tokenStates.append(tokens) }
        let tokenColumns = tokenStates.map(Self.legacyTokenColumns)
        for side in sides {
            let row = agentPreferencesRow(rules: side.rules, decisionHistory: side.decisionHistory)
            for columns in tokenColumns
            where Self.rowHash(row.merging(columns) { _, legacy in legacy }) == entry.hash {
                entry.hash = side.hash
                DiagnosticTrail.record("Sync", "sync.baseline.token_free table=agent_preferences matched=\(side.name) seq=\(entry.seq.map(String.init) ?? "nil")")
                return entry
            }
        }
        unexplainedPreferencesBases.insert(attempt)
        DiagnosticTrail.record("Sync", "sync.baseline.token_free table=agent_preferences matched=none seq=\(entry.seq.map(String.init) ?? "nil")")
        return entry
    }

    /// Same shape `syncAgentConversations` uploads.
    ///
    /// The `[]` fallbacks below are now unreachable for the case that mattered.
    /// This used to read the raw `UserDefaults` blob, and an UNDECODABLE blob
    /// landed here as `[]` and was uploaded — overwriting the cloud's copy of a
    /// transcript at precisely the moment the local one had just been proven
    /// unreadable. That state is a freeze in the repository now, and
    /// `agentConversationsExportSuppressed` stops the upload before it starts.
    /// `repository` nil is the shared one.
    func agentConversationsToRow(from repository: AgentConversationRepository? = nil) -> [String: Any] {
        let raw = (repository ?? .shared).encodedJSONForSync() ?? Data()
        let decoded: Any
        if raw.isEmpty {
            decoded = []
        } else if let any = try? JSONSerialization.jsonObject(with: raw) {
            decoded = any
        } else {
            decoded = []
        }
        return agentConversationsRow(conversations: decoded)
    }

    /// The one projection of the agent_conversations row from its blob.
    func agentConversationsRow(conversations: Any) -> [String: Any] {
        [
            "user_id": userId,
            "conversations": conversations,
            "updated_at": iso(scheduler.now()),
            "synced_at": iso(scheduler.now()),
        ]
    }

    // MARK: - Frozen-slot suppression

    /// Whether the array backing `slot` may be uploaded at all.
    ///
    /// The flush is a MIRROR: ids that are in the baseline and not in the
    /// rows handed to it are tombstoned on the server. That is correct when
    /// the local array is the user's data and wrong when it merely looks
    /// like it — and a frozen slot is exactly the second case. It reads as an
    /// empty array because its file could not be read, so the first fullSync
    /// after the fault (sign-in, or the uploads toggle going on) would delete
    /// every row of the last surviving copy.
    ///
    /// The judgement itself lives in `EventStore.isSlotFrozen`; this only
    /// routes to it. Suppress the whole table rather than just the delete
    /// branch: the upserts would still rewrite the persisted hash baseline
    /// from a state we know is not the user's.
    private func exportSuppressed(_ slot: StorageSlot, table: String) -> Bool {
        Self.exportSuppressed(slot, of: attachedEventStore, table: table)
    }

    /// Written as a function of (slot, store) so it can be exercised without
    /// `attach`, which needs an `AuthService` and three sibling stores that
    /// have nothing to do with this decision.
    static func exportSuppressed(_ slot: StorageSlot, of store: EventStore?, table: String) -> Bool {
        guard store?.isSlotFrozen(slot) == true else { return false }
        logger.error("\(table, privacy: .public): upload SUPPRESSED — local slot \(slot.rawValue, privacy: .public) is frozen; not mirroring an unreadable slot to the cloud")
        return true
    }

    /// Same judgement, different owner: the event types live in
    /// `EventTypeCatalog`, not in a `StorageSlot`.
    ///
    /// This one matters more than its size suggests. A frozen catalog serves
    /// LAST-KNOWN-GOOD or nothing — never the built-in four — precisely
    /// because the flush is a mirror: four fallback rows uploaded would
    /// tombstone every real type the user has in the cloud, and every event
    /// referencing one would lose its color on the next restore.
    /// Scoped to the TEMPLATES file, not to the catalog as a whole: a
    /// shredded color-history file is a lost nicety, and letting it stop the
    /// templates mirror would be the same over-broad blast radius the other
    /// way round.
    static func eventTypeExportSuppressed(of store: EventTypeTemplateStore?) -> Bool {
        guard store?.areTemplatesFrozen == true else { return false }
        logger.error("event_types: upload SUPPRESSED — the local event-type catalog is frozen; not mirroring an unreadable store to the cloud")
        return true
    }

    /// Same judgement again, for the chat history.
    ///
    /// `agent_conversations` is one row per user pushed WHOLE, so this is the
    /// bluntest instrument of the three: an unreadable file reads as `[]`, and
    /// `[]` pushed is not a stale row or a missing key — it is the user's
    /// entire transcript replaced with nothing, in the one moment the cloud was
    /// the last copy standing. Suppress until a restore says otherwise.
    static func agentConversationsExportSuppressed(
        _ repository: AgentConversationRepository = .shared
    ) -> Bool {
        // Fold before judging (gh#148). This gate exists to stop an EMPTY
        // history reaching the whole-row upsert; a not-yet-folded store reads
        // as exactly that empty, yet carries no fault, so consulting
        // `isFrozen` on an un-folded store would wave the `[]` through. Folding
        // first turns the read into the real history, after which `isFrozen`
        // is again the only question. A no-op once the launch task has folded.
        repository.ensureLoaded()
        guard repository.isFrozen else { return false }
        logger.error("agent_conversations: upload SUPPRESSED — the local conversation file is unreadable; not mirroring an empty history over the cloud's copy")
        return true
    }

    /// The settings blob's equivalent, and it exists for a sharper reason than
    /// symmetry: `user_settings` is a single row pushed WHOLE, so a key the
    /// blob does not carry is a key the cloud loses. The bridged
    /// `eventTypeColorHistory` reads as absent while its file is unreadable,
    /// which would turn "we cannot read the local copy" into "delete the
    /// remote one" — the local half is already gone, so that is the last copy.
    /// A stale cloud blob is strictly better than a truncated one.
    static func settingsExportSuppressed(_ defaults: UserDefaults = .standard) -> Bool {
        guard SyncedSettings.hasUnreadableBridgedOwner(defaults) else { return false }
        logger.error("user_settings: upload SUPPRESSED — a bridged key's durable owner is unreadable; the whole-blob upsert would delete the cloud's copy of it")
        return true
    }

    // MARK: - Sync: Events

    func syncEvents(_ events: [Event], kind: String) async {
        guard !exportSuppressed(kind == "todo" ? .events : .calendarEvents,
                                table: "events(\(kind))") else { return }
        let table = Self.eventsBaselineTable(kind: kind)
        // Follower probe (perf batch 2a): building the rows is its own span;
        // `pushTable` times the hashing and the baseline work around the
        // network awaits.
        let rows = FollowerTiming.measure(FollowerSyncTable(baselineTable: table).build) {
            events.map { e in eventToRow(e, kind: kind) }
        }
        await pushTable(serverTable: "events", table: table, rows: rows)
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private func iso(_ date: Date) -> String {
        Self.iso(date)
    }

    /// Full upload payload for an event row, including the always-now
    /// `updated_at` / `synced_at` timestamps the server persists.
    internal func eventToRow(_ e: Event, kind: String) -> [String: Any] {
        var row = Self.eventRowHashableFields(e, kind: kind, userId: userId)
        row["updated_at"] = iso(scheduler.now())
        row["synced_at"] = iso(scheduler.now())
        return row
    }

    /// Same row minus `updated_at` / `synced_at`, which `rowHash` discards
    /// anyway (see `rowHashIgnoredKeys`) — so the hash is identical to
    /// `eventToRow`'s. Use on the hashing-only path (`syncStateForEvent`, the
    /// inspect UI's per-event hot loop) to skip two throwaway timestamp
    /// formatter calls per event.
    private func eventToRowForHashing(_ e: Event, kind: String) -> [String: Any] {
        Self.eventRowHashableFields(e, kind: kind, userId: userId)
    }

    /// The hashed portion of an event row — every field except the two
    /// always-now timestamps. Single source of truth shared by `eventToRow`
    /// (upload), `eventToRowForHashing` (state check) and `seedFingerprint`
    /// (the seeder, which has no session: `userId` is a parameter so all
    /// three project through one function).
    static func eventRowHashableFields(_ e: Event, kind: String, userId: String) -> [String: Any] {
        // ALL keys must always be present (use NSNull for nil).
        // PostgREST requires uniform keys across batch rows.
        let ranges: [[String: String]] = e.timeRanges.map { r in
            ["start": iso(r.start), "end": iso(r.end)]
        }
        // The day-key identity ships BESIDE its legacy mirror dates
        // (`recurrence_exception_day_keys` / `recurrence_instance_day_key`,
        // migration 014): keys that exist must never be re-derived from the
        // lossy mirror on pull — re-derivation on every restore is what let
        // a tz change move a detached day permanently (gh#127 review
        // finding 3). The dates stay on the wire untouched as the rollback
        // net for pre-migration readers.
        let exDates: [String] = e.recurrenceExceptionDates.map { iso($0) }

        var ir: Any = NSNull()
        if let rel = e.interruptRelation {
            ir = [
                "parentEventID": rel.parentEventID.uuidString,
                "baseSeriesEventID": rel.baseSeriesEventID?.uuidString as Any,
                "state": rel.state.rawValue,
                "occurrenceDate": iso(rel.occurrenceDate),
                "createdAt": iso(rel.createdAt),
            ] as [String: Any]
        }

        let wannaNotesPayload: Any = encodeJSONOrNull(e.wannaNotes)
        let agenticIntakePayload: Any = encodeJSONOrNull(e.agenticIntake)

        return [
            "id": e.id.uuidString,
            "user_id": userId,
            "kind": kind,
            "title": e.title,
            "note": e.note,
            "location": e.location,
            "type": e.type,
            "additional_types": e.additionalTypes as Any? ?? NSNull(),
            "type_weights": e.typeWeights as Any? ?? NSNull(),
            "tags": e.tags,
            "priority": e.priority,
            "status": e.status.rawValue,
            "is_all_day": e.isAllDay,
            "is_done": e.isDone,
            "color_depth": e.colorDepth,
            "time_ranges": ranges,
            "deadline": e.deadline.map { iso($0) } as Any? ?? NSNull(),
            "complete_at": e.completeAt.map { iso($0) } as Any? ?? NSNull(),
            "repeat_unit": e.repeatUnit.rawValue,
            "repeat_interval": e.repeatInterval,
            "repeat_end_type": e.repeatEndType.rawValue,
            "repeat_end_date": e.repeatEndDate.map { iso($0) } as Any? ?? NSNull(),
            "repeat_end_count": e.repeatEndCount as Any? ?? NSNull(),
            "recurrence_parent_id": e.recurrenceParentId?.uuidString as Any? ?? NSNull(),
            "recurrence_instance_date": e.recurrenceInstanceDate.map { iso($0) } as Any? ?? NSNull(),
            "recurrence_instance_day_key": e.recurrenceInstanceDayKey as Any? ?? NSNull(),
            "recurrence_exception_dates": exDates,
            "recurrence_exception_day_keys": e.recurrenceExceptionDayKeys,
            "linked_calendar_event_id": e.linkedCalendarEventId?.uuidString as Any? ?? NSNull(),
            "linked_todo_event_id": e.linkedTodoEventId?.uuidString as Any? ?? NSNull(),
            "list_id": e.listID?.uuidString as Any? ?? NSNull(),
            "display_kind": e.displayKind.rawValue,
            "behavior_kind": e.kind.rawValue,
            "absorbed_into_event_id": e.absorbedIntoEventID?.uuidString as Any? ?? NSNull(),
            "people_ids": e.peopleIDs.map { $0.map { $0.uuidString } } as Any? ?? NSNull(),
            "timer_started_at": e.timerStartedAt.map { iso($0) } as Any? ?? NSNull(),
            "interrupt_relation": ir,
            "wanna_notes": wannaNotesPayload,
            "agentic_intake": agenticIntakePayload,
            "suggested_log_template_id": e.suggestedLogTemplateID as Any? ?? NSNull(),
            "suggested_log_template_confidence": e.suggestedLogTemplateConfidence as Any? ?? NSNull(),
            "suggested_log_template_updated_at": e.suggestedLogTemplateUpdatedAt.map { iso($0) } as Any? ?? NSNull(),
            "suggested_log_template_source": e.suggestedLogTemplateSource?.rawValue as Any? ?? NSNull(),
            "created_at": iso(e.createdAt),
            // Design §5.8 / §10.5 (i): the domino's per-row anchor rides
            // with the row, inside the hash — a push is an upload.
            "domino_anchor": e.dominoAnchor.map { iso($0) } as Any? ?? NSNull(),
        ]
    }

    /// Round-trip an Encodable through JSON so PostgREST sees an Array/Object
    /// instead of an opaque Encodable wrapper. Returns `NSNull()` for nil/empty
    /// so the surrounding row schema stays uniform across batches.
    private static func encodeJSONOrNull<T: Encodable>(_ value: T?) -> Any {
        guard let value else { return NSNull() }
        if let arr = value as? [Any], arr.isEmpty { return NSNull() }
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return NSNull() }
        if let arr = decoded as? [Any], arr.isEmpty { return NSNull() }
        return decoded
    }

    /// The `jsonb not null` twin: nil, empty and unencodable all go out as
    /// `[]`, which the server column accepts and the restore decoder reads
    /// back as an empty array.
    static func encodeJSONArray<T: Encodable>(_ value: [T]?) -> [Any] {
        guard let value, !value.isEmpty,
              let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return decoded
    }

    // MARK: - Sync: Logs

    func syncLogs(_ logs: [CalendarEventLogRecord]) async {
        guard !exportSuppressed(.calendarEventLogRecords, table: "event_logs") else { return }
        let rows = FollowerTiming.measure(.syncLogsBuild) { logs.map { logToRow($0) } }
        await pushTable(serverTable: "event_logs", table: "event_logs", rows: rows)
    }

    func logToRow(_ log: CalendarEventLogRecord) -> [String: Any] {
        return [
            "id": encodeOccurrenceKey(log.id),
            "user_id": userId,
            "event_id": log.eventID.uuidString,
            "base_series_event_id": log.baseSeriesEventID?.uuidString as Any? ?? NSNull(),
            "occurrence_date": iso(log.occurrenceDate),
            "completion_status": log.completionStatus?.rawValue as Any? ?? NSNull(),
            "actual_duration_minutes": log.actualDurationMinutes as Any? ?? NSNull(),
            "summary": log.summary,
            "note": log.note,
            "effort": log.effort as Any? ?? NSNull(),
            "emotions": log.emotions,
            "behaviors": log.behaviors,
            "suggested_template_id": log.suggestedTemplateID as Any? ?? NSNull(),
            "selected_template_id": log.selectedTemplateID as Any? ?? NSNull(),
            "template_answers": encodeTemplateAnswers(log.templateAnswers),
            "timeline_items": encodeTimelineItems(log.timelineItems),
            "created_at": iso(log.createdAt),
            "updated_at": iso(log.updatedAt),
            "synced_at": iso(scheduler.now()),
        ]
    }

    private func encodeTimelineItems(_ items: [EventLogTimelineItem]) -> [Any] {
        guard !items.isEmpty,
              let data = try? JSONEncoder().encode(items),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return decoded
    }

    private func encodeTemplateAnswers(_ answers: [String: EventLogAnswerValue]) -> [String: Any] {
        guard !answers.isEmpty,
              let data = try? JSONEncoder().encode(answers),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return decoded
    }

    // MARK: - Sync: Feedback

    func syncFeedback(_ records: [CalendarEventFeedbackRecord]) async {
        guard !exportSuppressed(.calendarEventFeedbackRecords, table: "event_feedback") else { return }
        let rows = FollowerTiming.measure(.syncFeedbackBuild) { records.map(feedbackToRow) }
        await pushTable(serverTable: "event_feedback", table: "event_feedback", rows: rows)
    }

    func feedbackToRow(_ r: CalendarEventFeedbackRecord) -> [String: Any] {
        let logsPayload: [Any] = {
            guard !r.logs.isEmpty,
                  let data = try? JSONEncoder().encode(r.logs),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any]
            else { return [] }
            return decoded
        }()
        return [
            "id": encodeOccurrenceKey(r.id),
            "user_id": userId,
            "event_id": r.eventID.uuidString,
            "base_series_event_id": r.baseSeriesEventID?.uuidString as Any? ?? NSNull(),
            "occurrence_date": iso(r.occurrenceDate),
            "effort": r.effort as Any? ?? NSNull(),
            "emotions": r.emotions,
            "behaviors": r.behaviors,
            "self_note": r.selfNote,
            "logs": logsPayload,
            "chat_conversation_id": r.chatConversationID?.uuidString as Any? ?? NSNull(),
            "created_at": iso(r.createdAt),
            "updated_at": iso(r.updatedAt),
            "synced_at": iso(scheduler.now()),
        ]
    }

    // MARK: - Sync: Todo Lists

    func syncTodoLists(_ lists: [TodoList]) async {
        guard !exportSuppressed(.todoLists, table: "todo_lists") else { return }
        let rows = FollowerTiming.measure(.syncOtherBuild) { lists.map(todoListToRow) }
        await pushTable(serverTable: "todo_lists", table: "todo_lists", rows: rows)
    }

    func todoListToRow(_ l: TodoList) -> [String: Any] {
        [
            "id": l.id.uuidString,
            "user_id": userId,
            "title": l.title,
            "color_name": l.colorName,
            "created_at": iso(l.createdAt),
            "synced_at": iso(scheduler.now()),
        ]
    }

    // MARK: - Sync: Event Types

    func syncEventTypes(_ templates: [EventTypeTemplate]) async {
        guard !Self.eventTypeExportSuppressed(of: attachedEventTypeStore) else { return }
        guard flushGate("event_types") else { return }
        // Seeds that go to the cloud are written down first, so the next
        // launch serves them under the ids the cloud holds.
        attachedEventTypeStore?.catalog.commitServedFallback()
        let rows = FollowerTiming.measure(.syncOtherBuild) { templates.map(eventTypeToRow) }
        await pushTable(serverTable: "event_types", table: "event_types", rows: rows)
    }

    func eventTypeToRow(_ t: EventTypeTemplate) -> [String: Any] {
        [
            "id": t.id.uuidString,
            "user_id": userId,
            "title": t.title,
            "color_hex": t.colorHex,
            "updated_at": iso(scheduler.now()),
            "synced_at": iso(scheduler.now()),
        ]
    }

    // MARK: - Sync: Skills

    func syncSkills(_ insights: [SkillInsight]) async {
        let rows = FollowerTiming.measure(.syncOtherBuild) { insights.map(skillToRow) }
        await pushTable(serverTable: "skill_insights", table: "skill_insights", rows: rows)
    }

    func skillToRow(_ s: SkillInsight) -> [String: Any] {
        [
            "id": s.id.uuidString,
            "user_id": userId,
            "skill_name": s.skillName,
            "points": s.points,
            "date": iso(s.date),
            "event_title": s.eventTitle,
            "reasoning": s.reasoning,
            "synced_at": iso(scheduler.now()),
        ]
    }

    // MARK: - Helpers

    /// Encode CalendarOccurrenceKey to a stable Supabase row ID.
    ///
    /// The ID is a function of *identity only* (issue #26). The previous
    /// format embedded `occurrenceDate`, which is NOT part of the key's
    /// identity (`CalendarOccurrenceKey.==` ignores it for single events and
    /// uses `dayKey` for series). So any drift in the stored date — cross-tz
    /// writes, legacy paths, `make()` refactors — produced a *new* row ID and
    /// the next sync inserted a duplicate instead of upserting in place,
    /// leaking duplicate cloud rows per logical record.
    func encodeOccurrenceKey(_ key: CalendarOccurrenceKey) -> String {
        switch key.kind {
        case .singleEvent:
            // Single-event identity is the eventID alone.
            return "\(key.kind.rawValue)|\(key.eventID.uuidString)"
        case .seriesOccurrence:
            // Series identity adds baseSeriesEventID + the tz-stable dayKey
            // (an integer, never the raw date, so it can't drift across tz).
            let base = key.baseSeriesEventID?.uuidString ?? "none"
            return "\(key.kind.rawValue)|\(key.eventID.uuidString)|\(base)|\(key.dayKey)"
        }
    }

    // MARK: - Restore (read from server)

    enum RestoreError: Error, LocalizedError {
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in before restoring from the cloud."
            }
        }
    }

    /// Tables fetched during a restore. Order is meaningful for UI progress reporting.
    static let restoreTables: [String] = [
        "events",
        "event_logs",
        "event_feedback",
        "todo_lists",
        "event_types",
        "skill_insights",
        "user_settings",
        "agent_preferences",
        "agent_conversations",
    ]

    /// Pull all live rows for the current signed-in user. Returns raw row
    /// dictionaries keyed by table name; deserialization to typed models is
    /// the caller's job. Throws `RestoreError.notSignedIn` if the user is not
    /// authenticated.
    func fetchAllRawRows() async throws -> [String: [[String: Any]]] {
        guard !userId.isEmpty else { throw RestoreError.notSignedIn }
        let capturedUserId = userId
        var result: [String: [[String: Any]]] = [:]
        for table in Self.restoreTables {
            do {
                let rows = try await gateway.fetchAll(table: table, userId: capturedUserId)
                result[table] = rows
                logger.info("Fetched \(rows.count, privacy: .public) rows from \(table, privacy: .public)")
            } catch SupabaseREST.SyncError.fetchFailed(_, let status)
                    where Self.tablesTolerantOfMissingSchema.contains(table) && status == 404 {
                // Migration 006 introduced `user_settings`. If the app is
                // talking to a Supabase project that hasn't applied that
                // migration yet, treat the missing table as "no cloud data
                // for this table" rather than failing the whole restore so
                // dry-run + restore keep working for pre-existing tables.
                logger.notice("\(table, privacy: .public) not yet provisioned (404), skipping")
            }
        }
        return result
    }

    /// Tables that may legitimately be missing on the server (e.g. a Supabase
    /// project that hasn't applied the latest migration yet). For these we
    /// tolerate a 404 during fetch instead of blowing up the whole restore.
    private static let tablesTolerantOfMissingSchema: Set<String> = ["user_settings"]

    /// Called by `RestoreCoordinator` immediately after `applyRestore` mutates
    /// the local stores. Rebuilds the diff-sync baseline so that it names
    /// the SERVER (survey S6, design §6 Restore 路径 — the same principle as
    /// the conflict row's baseline): a row the cloud snapshot carried gets
    /// `hash(cloud row)@cloud seq`, the cloud row projected exactly as this
    /// device would send it. A row restored from the cloud therefore reads
    /// clean, and a keepLocal collision row — local content, cloud version —
    /// reads dirty and goes out as a conditional PATCH on the cloud seq. A
    /// row the cloud did not carry keeps the legacy shape: the hash of the
    /// local row with whatever seq was already known for it.
    ///
    /// `snapshot` defaults to the one `fetchRestoreSnapshot` last returned.
    func markRestoreCompleted(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore,
        snapshot: RestoreSnapshot? = nil
    ) {
        markRestoreCompleted(
            todoEvents: eventStore.events,
            calendarEvents: eventStore.rawCalendarEvents,
            logs: eventStore.calendarEventLogRecords,
            feedback: eventStore.calendarEventFeedbackRecords,
            todoLists: eventStore.todoLists,
            eventTypes: eventTypeStore.templates,
            skills: skillStore.insights,
            snapshot: snapshot
        )
    }

    /// The store-free core of `markRestoreCompleted`: the local rows after
    /// the restore, and the cloud snapshot it applied.
    func markRestoreCompleted(
        todoEvents: [Event],
        calendarEvents: [Event],
        logs: [CalendarEventLogRecord],
        feedback: [CalendarEventFeedbackRecord],
        todoLists: [TodoList],
        eventTypes: [EventTypeTemplate],
        skills: [SkillInsight],
        snapshot: RestoreSnapshot? = nil
    ) {
        let cloud = snapshot ?? lastRestoreSnapshot ?? .empty
        lastRestoreSnapshot = nil
        let seqs = cloud.cloudSeqs

        replayBaseline(table: "events", local: todoEvents.map { eventToRow($0, kind: "todo") },
                       cloud: cloud.todoEvents.map { eventToRow($0, kind: "todo") }, seqs: seqs)
        replayBaseline(table: "calendar_events", local: calendarEvents.map { eventToRow($0, kind: "calendar") },
                       cloud: cloud.calendarEvents.map { eventToRow($0, kind: "calendar") }, seqs: seqs)
        replayBaseline(table: "event_logs", local: logs.map(logToRow), cloud: cloud.logs.map(logToRow), seqs: seqs)
        replayBaseline(table: "event_feedback", local: feedback.map(feedbackToRow), cloud: cloud.feedback.map(feedbackToRow), seqs: seqs)
        replayBaseline(table: "todo_lists", local: todoLists.map(todoListToRow), cloud: cloud.todoLists.map(todoListToRow), seqs: seqs)
        replayBaseline(table: "event_types", local: eventTypes.map(eventTypeToRow), cloud: cloud.eventTypes.map(eventTypeToRow), seqs: seqs)
        replayBaseline(table: "skill_insights", local: skills.map(skillToRow), cloud: cloud.skills.map(skillToRow), seqs: seqs)

        // Settings: the cloud blob's per-key hashes at the cloud seq, so a
        // key the merge kept local reads dirty and every other key clean.
        // Without a cloud row: the current local state, as before — restore
        // writes back to UserDefaults, which fires didChangeNotification,
        // and the next debounced settings sink must see zero diff.
        let settingsKey = Self.restoreSingletonKey(SyncBaselineStore.settingsTable)
        if let blob = cloud.settings, let seq = seqs[settingsKey] {
            let known = blob.filter { SyncedSettings.allKeys.contains($0.key) && !($0.value is NSNull) }
            let zone = known[CalendarOccurrenceKey.referenceTimeZoneDefaultsKey] as? String
            baseline.setSettings(.versioned(seq: seq, keys: Self.settingsKeyHashes(known), zone: zone))
        } else {
            let settings = baseline.settings
            let blob = Self.settingsBlobForUpload(local: SyncedSettings.currentSnapshot(defaults), serverZone: settings?.zone)
            baseline.setSettings(.versioned(seq: settings?.seq, keys: Self.settingsKeyHashes(blob), zone: settings?.zone))
        }

        // The two blob tables (#2 + #3 from the full-backup audit): same
        // rule — the cloud row's hash at its seq when the cloud carried one,
        // the local row's hash otherwise, so restored bytes are not
        // re-uploaded for no change.
        let preferencesKey = Self.restoreSingletonKey("agent_preferences")
        if let seq = seqs[preferencesKey] {
            let row = agentPreferencesRow(rules: cloud.agentRules ?? [], decisionHistory: cloud.agentDecisionHistory ?? [])
            baseline.setEntry(SyncBaselineEntry(hash: Self.rowHash(row), seq: seq), table: "agent_preferences", id: userId)
        } else if let preferenceStore = attachedPreferenceStore {
            replaySingleton(table: "agent_preferences", hash: Self.rowHash(agentPreferencesToRow(preferenceStore)))
        }
        let conversationsKey = Self.restoreSingletonKey("agent_conversations")
        if let seq = seqs[conversationsKey] {
            let row = agentConversationsRow(conversations: cloud.agentConversationsBlob ?? [Any]())
            baseline.setEntry(SyncBaselineEntry(hash: Self.rowHash(row), seq: seq), table: "agent_conversations", id: userId)
        } else {
            replaySingleton(table: "agent_conversations", hash: Self.rowHash(agentConversationsToRow()))
        }
        // Persist the just-restored baseline so the next launch starts from
        // here, not from an empty map that would re-upload everything.
        baseline.persistAll()
    }

    /// One table's replay. Only rows the device holds after the restore
    /// enter the baseline (a row in the baseline and not local would be
    /// tombstoned). Each takes the cloud row's hash and seq when the
    /// snapshot carried that id with a seq; otherwise the local hash and the
    /// seq already known.
    private func replayBaseline(table: String, local: [[String: Any]], cloud: [[String: Any]], seqs: [SyncBaselineKey: Int64]) {
        let previous = baseline.entries(table: table)
        var cloudHashes: [String: String] = [:]
        for row in cloud {
            guard let id = row["id"] as? String else { continue }
            cloudHashes[id] = Self.rowHash(row)
        }
        var next: [String: SyncBaselineEntry] = [:]
        for row in local {
            guard let id = row["id"] as? String else { continue }
            if let cloudHash = cloudHashes[id], let seq = seqs[SyncBaselineKey(table: table, id: id)] {
                next[id] = SyncBaselineEntry(hash: cloudHash, seq: seq)
            } else {
                next[id] = SyncBaselineEntry(hash: Self.rowHash(row), seq: previous[id]?.seq)
            }
        }
        baseline.replaceEntries(table: table, with: next)
    }

    private func replaySingleton(table: String, hash: String) {
        let seq = baseline.entry(table: table, id: userId)?.seq
        baseline.setEntry(SyncBaselineEntry(hash: hash, seq: seq), table: table, id: userId)
    }
}
