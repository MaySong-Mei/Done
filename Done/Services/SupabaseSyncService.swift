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
    nonisolated static let url = "https://uqnvtzblppjblwgbpqhf.supabase.co"
    /// Project key for the `apikey` HTTP header. ONLY identifies the
    /// Supabase project — the `Authorization` header carries the
    /// per-user JWT, so RLS enforces row access.
    ///
    /// Modern publishable key (`sb_publishable_…`): public by design,
    /// safe to commit and ship. It replaced the hardcoded service_role
    /// JWT that leaked through this public repo — incident record and
    /// rotation checklist in gh#232.
    nonisolated static let publishableKey = "sb_publishable_1Cd8-AKwVRLBI3RAmFziNg_guyoO3Cz"
    nonisolated static let debounceSeconds: TimeInterval = 2.0
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
/// (design §6 上传形状). `upsert` / `delete` below are NOT part of it: the
/// outbound path no longer sends `merge-duplicates` or a physical DELETE
/// (design D6); they stay for the legacy paths only.
final class SupabaseREST: SyncGateway {
    private let baseURL: String
    /// Project anon/service-role key — only used for the `apikey` HTTP
    /// header (routing / project identity). Authorization always uses the
    /// per-user JWT from `authService`.
    private let projectAPIKey: String
    private weak var authService: AuthService?

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

    // MARK: - PostgREST verbs (legacy paths)

    /// Upsert rows into a table. All rows MUST have identical keys.
    func upsert(table: String, rows: [[String: Any]]) async throws {
        guard !rows.isEmpty else { return }
        try await withTokenRetry { token in
            guard let url = URL(string: "\(self.baseURL)/rest/v1/\(table)") else {
                throw SyncError.upsertFailed(table: table, status: -1)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(self.projectAPIKey, forHTTPHeaderField: "apikey")
            request.setValue(self.authorizationHeader(token), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: rows)

            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.upsertFailed(table: table, status: -1)
            }
            if http.statusCode == 401 { throw SyncError.tokenExpired }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: responseData, encoding: .utf8) ?? ""
                logger.error("Upsert \(table, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(body.prefix(200), privacy: .public)")
                throw SyncError.upsertFailed(table: table, status: http.statusCode)
            }
        }
    }

    /// Delete rows by IDs.
    func delete(table: String, ids: [String], idColumn: String = "id") async throws {
        guard !ids.isEmpty else { return }
        try await withTokenRetry { token in
            let joined = ids.joined(separator: ",")
            let urlStr = "\(self.baseURL)/rest/v1/\(table)?\(idColumn)=in.(\(joined))"
            guard let url = URL(string: urlStr) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(self.projectAPIKey, forHTTPHeaderField: "apikey")
            request.setValue(self.authorizationHeader(token), forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.deleteFailed(table: table, status: -1)
            }
            if http.statusCode == 401 { throw SyncError.tokenExpired }
            guard (200..<300).contains(http.statusCode) else {
                throw SyncError.deleteFailed(table: table, status: http.statusCode)
            }
        }
    }

    // MARK: - SyncGateway (design §6 上传形状)

    /// RFC 3986 unreserved characters only; everything else is percent-
    /// encoded. Occurrence-key ids carry `|`, which PostgREST accepts raw or
    /// encoded (bench S9) — encoding keeps `URL(string:)` honest.
    nonisolated private static let filterValueAllowed: CharacterSet =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    nonisolated static func encodeFilterValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: filterValueAllowed) ?? value
    }

    /// The restore-path query: the user's rows, LIVE rows only. Pure so the
    /// filter is pinned by a test without a network.
    nonisolated static func fetchAllQuery(table: String, userId: String) -> String {
        "\(table)?user_id=eq.\(encodeFilterValue(userId))&deleted_at=is.null"
    }

    nonisolated static func conditionalPatchQuery(table: String, keyColumn: String, key: String, baseSeq: Int64) -> String {
        "\(table)?\(keyColumn)=eq.\(encodeFilterValue(key))&seq=eq.\(baseSeq)"
    }

    nonisolated static func tombstoneQuery(table: String, keyColumn: String, keys: [String]) -> String {
        let joined = keys.map(encodeFilterValue).joined(separator: ",")
        return "\(table)?\(keyColumn)=in.(\(joined))&deleted_at=is.null"
    }

    func pullChanges(sinceSeq: Int64, pageLimit: Int) async throws -> [SyncFeedRow] {
        let limit = min(max(1, pageLimit), SyncGatewayLimits.maxPageLimit)
        let body: [String: Any] = ["since_seq": NSNumber(value: sinceSeq), "page_limit": limit]
        let data = try await send(
            method: "POST", path: "rpc/sync_changes", body: body,
            headers: ["Content-Type": "application/json"], table: "sync_changes"
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
            table: table
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
            table: table
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
            table: table
        )
        return try Self.decodeRows(data, table: table)
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
        table: String
    ) async throws -> Data {
        try await withTokenRetry { token in
            guard let url = URL(string: "\(self.baseURL)/rest/v1/\(path)") else {
                throw SyncError.requestFailed(table: table, method: method, status: -1, code: nil)
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(self.projectAPIKey, forHTTPHeaderField: "apikey")
            request.setValue(self.authorizationHeader(token), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
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
                let text = String(data: data, encoding: .utf8) ?? ""
                let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
                logger.error("\(method, privacy: .public) \(table, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(text.prefix(200), privacy: .public)")
                throw SyncError.requestFailed(table: table, method: method, status: http.statusCode, code: code)
            }
            return data
        }
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

    /// Fetch all LIVE rows for a given user_id. Pages through PostgREST 1k-row windows.
    /// PostgREST caps a single response, so we walk Range headers until a short page arrives.
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
        let pageSize = 1000
        let safetyCap = 100_000
        var offset = 0
        var allRows: [[String: Any]] = []

        while true {
            let urlStr = "\(baseURL)/rest/v1/\(Self.fetchAllQuery(table: table, userId: userId))"
            guard let url = URL(string: urlStr) else {
                throw SyncError.fetchFailed(table: table, status: -1)
            }
            let pageRows: [[String: Any]] = try await withTokenRetry { token in
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(self.projectAPIKey, forHTTPHeaderField: "apikey")
                request.setValue(self.authorizationHeader(token), forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("\(offset)-\(offset + pageSize - 1)", forHTTPHeaderField: "Range")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SyncError.fetchFailed(table: table, status: -1)
                }
                // PostgREST returns 416 when the requested offset is past the end of
                // the result set — e.g. when the total row count is an exact multiple
                // of pageSize and our trailing request lands one page too far.
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
            allRows.append(contentsOf: pageRows)
            if pageRows.count < pageSize { break }
            offset += pageSize
            if offset >= safetyCap {
                logger.notice("fetchAll \(table, privacy: .public) safety cap hit at \(offset, privacy: .public)")
                break
            }
        }

        return allRows
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
/// as a change (every row builder calls `iso(Date())` for `synced_at`, and
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

    /// I1, read at flush time: whether this session has pulled to head
    /// (last page shorter than `page_limit`, no refused page since). While
    /// false, every flush returns without sending — a row whose baseline
    /// the applier has not written yet must not be pushed as dirty. The
    /// puller flips it; it is true until a puller exists so the outbound
    /// path works standalone, which is the state this slice ships in.
    var inboundAtHead: Bool = true

    /// Asked for after a flush that received `[]` (pending-verify) or hit a
    /// dead row — the engine's pull is what clears both.
    var onNeedsPull: (() -> Void)?
    /// The engine's pull issue counter (incremented before every
    /// `sync_changes` RPC); captured into each pending-verify element so
    /// only a pull issued after the `[]` may clear it.
    var pullIssueCounter: () -> Int = { 0 }

    private var isFullSyncDone = false

    /// Re-entry guard for `fullSync`. The sign-in path and
    /// `userDidEnableUploads` can both kick off a fullSync; rapid toggle
    /// flipping could otherwise spawn N parallel passes that idempotent-upsert
    /// the same rows and stretch the `isFullSyncDone == false` window that
    /// blocks debounced sinks. Set inside the Task, cleared in defer.
    private var fullSyncInFlight = false

    init(
        url: String = SupabaseSyncConfig.url,
        apiKey: String = SupabaseSyncConfig.publishableKey
    ) {
        // Placeholder client; `attach()` reconstructs with the real
        // `AuthService` reference for user-JWT auth.
        self.gateway = SupabaseREST(url: url, projectAPIKey: apiKey, authService: nil as AuthService?)
        self.gatewayIsInjected = false
        self.defaults = .standard
        self.baseline = SyncBaselineStore(defaults: .standard, userId: "")
        self.cursor = SyncCursorStore(defaults: .standard, userId: "")
    }

    /// Engine construction without an `AuthService`: a gateway (the fake
    /// server in tests), the user it speaks as, and the defaults it keeps
    /// its baseline in. Runs the same sign-in bookkeeping the session sink
    /// runs, including the legacy settings-baseline upgrade.
    init(gateway: SyncGateway, userId: String, defaults: UserDefaults) {
        self.gateway = gateway
        self.gatewayIsInjected = true
        self.defaults = defaults
        self.baseline = SyncBaselineStore(defaults: defaults, userId: "")
        self.cursor = SyncCursorStore(defaults: defaults, userId: "")
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

    /// Runtime gate: are uploads currently allowed for this device?
    /// `debugBlocksUploads` (compile-time) AND `syncUploadsEnabled` (user
    /// toggle, defaults OFF on a fresh install). Read on every sync entry
    /// point so flipping the toggle takes effect on the very next debounce
    /// without needing to re-attach the Combine pipeline.
    nonisolated var canUpload: Bool {
        if Self.debugBlocksUploads { return false }
        return UserDefaults.standard.bool(forKey: AppSettingsKeys.syncUploadsEnabled)
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
        Task {
            self.fullSyncInFlight = true
            defer { self.fullSyncInFlight = false }
            self.isFullSyncDone = false
            await self.fullSync(eventStore: es, eventTypeStore: ets, skillStore: ss)
            self.isFullSyncDone = true
        }
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
        self.attachedEventStore = eventStore
        self.attachedEventTypeStore = eventTypeStore
        self.attachedSkillStore = skillStore
        self.attachedPreferenceStore = preferenceStore
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
        let debounce = SupabaseSyncConfig.debounceSeconds

        if Self.debugBlocksUploads {
            logger.notice("⚠️ DEBUG build — uploads disabled. Auth + read-only sync only. Restore (GET) still works.")
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
                    if !self.canUpload {
                        // Mark "ready" so any code gated on isFullSyncDone still
                        // works as expected. No fullSync — that runs when the
                        // toggle flips on (see `userDidEnableUploads`) or when
                        // the next debounced sink fires with the toggle on.
                        self.isFullSyncDone = true
                        return
                    }
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
                    self.endSession()
                }
            }
            .store(in: &cancellables)

        // In DEBUG, skip wiring up any of the upload-side Combine sinks below.
        // The signed-in userId is still set above so `fetchAllRawRows()` works,
        // but nothing on the device will ever be pushed to Supabase. In Release
        // we wire the sinks unconditionally — each sink body checks `canUpload`
        // so the user toggle takes effect dynamically.
        if Self.debugBlocksUploads { return }

        // ── Todo events ──
        eventStore.$events
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] events in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncEvents(events, kind: "todo") }
            }
            .store(in: &cancellables)

        // ── Calendar events ──
        eventStore.$rawCalendarEvents
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] events in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncEvents(events, kind: "calendar") }
            }
            .store(in: &cancellables)

        // ── Event logs ──
        eventStore.$calendarEventLogRecords
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] logs in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncLogs(logs) }
            }
            .store(in: &cancellables)

        // ── Event feedback ──
        eventStore.$calendarEventFeedbackRecords
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] records in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncFeedback(records) }
            }
            .store(in: &cancellables)

        // ── Todo lists ──
        eventStore.$todoLists
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] lists in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncTodoLists(lists) }
            }
            .store(in: &cancellables)

        // ── Event types ──
        eventTypeStore.$templates
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self, weak eventTypeStore] templates in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                // Checked at the sink as well as inside `syncEventTypes`,
                // because a frozen catalog still PUBLISHES (a refused write
                // mirrors the catalog's array back, which is a change) and
                // the cheapest place to stop a mirror is before it starts.
                guard !Self.eventTypeExportSuppressed(of: eventTypeStore) else { return }
                Task {
                    await self.syncEventTypes(templates)
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
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] insights in
                guard let self, self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncSkills(insights) }
            }
            .store(in: &cancellables)

        // ── User settings ──
        // UserDefaults.didChangeNotification fires on any write, not just our
        // synced keys, so debounce aggressively (5s) and let the row-hash check
        // inside the sync funcs collapse no-op uploads to nothing.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
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
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] _ in
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
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self, weak preferenceStore] _ in
                guard let self, let preferenceStore,
                      self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncAgentPreferences(preferenceStore) }
            }
            .store(in: &cancellables)

        // ── Token inference state (lives on the same agent_preferences
        // row, but `TokenInferenceRepository` doesn't expose @Published
        // arrays — it posts `.tokenInferenceStateDidChange` from its save
        // methods instead).
        NotificationCenter.default
            .publisher(for: .tokenInferenceStateDidChange)
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self, weak preferenceStore] _ in
                guard let self, let preferenceStore,
                      self.canUpload, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncAgentPreferences(preferenceStore) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Session scope

    /// Sign-in: load this user's baseline and cursor from disk and drop
    /// anything the previous user left in memory.
    private func beginSession(userId: String) {
        self.userId = userId
        baseline = SyncBaselineStore(defaults: defaults, userId: userId)
        cursor = SyncCursorStore(defaults: defaults, userId: userId)
        pendingVerify.reset()
        awaitingEcho = []
        upgradeLegacySettingsBaselineIfLocalClean()
    }

    /// `$session → nil` (design §6.4): forget the in-memory baseline, cursor,
    /// pending-verify set and echo bookkeeping, and persist NOTHING — the
    /// erase signs out before it wipes the hashes, and a write here would
    /// land in that window.
    private func endSession() {
        userId = ""
        isFullSyncDone = false
        baseline = SyncBaselineStore(defaults: defaults, userId: "")
        cursor = SyncCursorStore(defaults: defaults, userId: "")
        pendingVerify.reset()
        awaitingEcho = []
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
    static func settingsKeyHashes(_ blob: [String: Any]) -> [String: String] {
        blob.mapValues { syncValueHash($0) }
    }

    /// The settings blob as it goes out: the local snapshot, except the
    /// reference-zone key is the SERVER's value when the baseline holds one
    /// (design §6.2 pusher rule — a device never pushes another zone over an
    /// established account zone; it sends its own only while the server
    /// has none).
    static func settingsBlobForUpload(local: [String: Any], serverZone: String?) -> [String: Any] {
        var blob = local
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
        guard rowHash == Self.rowHash(settingsRow(local)) else { return }
        baseline.setSettings(.versioned(seq: nil, keys: Self.settingsKeyHashes(local), zone: nil))
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
        let keys: [String: String]
        if legacyHash == Self.rowHash(settingsRow(local)) {
            keys = Self.settingsKeyHashes(local)
        } else if legacyHash == Self.rowHash(settingsRow(remoteSettings)) {
            keys = Self.settingsKeyHashes(remoteSettings)
        } else {
            keys = [:]
        }
        let zone = remoteSettings[CalendarOccurrenceKey.referenceTimeZoneDefaultsKey] as? String
        baseline.setSettings(.versioned(seq: remoteSeq, keys: keys, zone: zone))
        baseline.persist()
        return true
    }

    /// Wipe persisted hashes for every user this device has ever signed in
    /// as. Used by "Reset all local data" in settings. Scans UserDefaults
    /// for keys with the `syncHashes.` prefix (since `userId` itself may
    /// not be currently known if the reset runs while signed out). The
    /// cursor shares the prefix and goes with them.
    static func wipeAllPersistedHashes() {
        SyncBaselineStore.wipeAll(UserDefaults.standard)
    }

    // MARK: - Pending verify / echo bookkeeping for the engine

    /// The engine calls this once per pull that reached head (design §6
    /// 上传形状): `seen` is every (table, id) that pull delivered,
    /// `pullIssue` the issue number of the RPC that returned the short page.
    /// Confirmed elements write the SENT hash / keys into the baseline; the
    /// seq is left alone (it equals the sent one by construction).
    @discardableResult
    func resolvePendingVerifyAtHead(seen: Set<SyncBaselineKey>, pullIssue: Int) -> [SyncBaselineKey] {
        var set = pendingVerify
        let cleared = set.resolveAtHead(
            seen: seen,
            pullIssue: pullIssue,
            baselineSeq: { self.baselineSeq($0) },
            confirm: { key, payload in self.writeBaseline(key, payload: payload, seq: nil) }
        )
        pendingVerify = set
        baseline.persist()
        return cleared
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

    /// The one place a successful push (or a confirmed pending element)
    /// writes the baseline. `seq == nil` keeps the seq already there.
    private func writeBaseline(_ key: SyncBaselineKey, payload: PendingVerifyPayload, seq: Int64?) {
        switch payload {
        case .rowHash(let hash):
            let existing = baseline.entry(table: key.table, id: key.id)?.seq
            baseline.setEntry(SyncBaselineEntry(hash: hash, seq: seq ?? existing), table: key.table, id: key.id)
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

    private struct PushRow {
        let key: SyncBaselineKey
        let row: [String: Any]
        /// What the baseline will hold if this row lands: the hash of the
        /// row AS SENT (settings: its per-key hashes). Computed before the
        /// request; never from a response body and never from the row the
        /// device holds later.
        let payload: PendingVerifyPayload
    }

    /// Serial bookkeeping for one flush; the network waits overlap, the
    /// accounting does not (every completion hops to the main actor).
    private final class FlushTally {
        var succeeded = 0
        var stale = 0
        var deadRowHits = 0
        var tombstonedSingletons = 0
        var failed = 0
        var awaitingEcho = 0
        var lastError: String?
        var needsPull = false
    }

    /// Whether a flush may send at all: I1 read here, after the debounce
    /// fired, not when it was scheduled.
    private func flushGate(_ table: String) -> Bool {
        guard !userId.isEmpty else { return false }
        guard inboundAtHead else {
            logger.notice("\(table, privacy: .public): flush held — inbound not at head (I1)")
            return false
        }
        return true
    }

    /// One per-row table: tombstone what left the local array, conditional
    /// PATCH what changed with a known seq, ignore-duplicates POST the rest.
    private func pushTable(serverTable: String, table: String, rows: [[String: Any]]) async {
        guard flushGate(table) else { return }
        let previous = baseline.entries(table: table)

        var current: [String: PushRow] = [:]
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            current[id] = PushRow(
                key: SyncBaselineKey(table: table, id: id),
                row: row,
                payload: .rowHash(Self.rowHash(row))
            )
        }

        // A row that left the local array while awaiting its echo has no
        // baseline entry to tombstone from and nothing left to echo into.
        for key in awaitingEcho where key.table == table && current[key.id] == nil {
            awaitingEcho.remove(key)
        }

        let tally = FlushTally()
        var deletes = 0
        var deleteFailure: String?

        // Deletes first, as one request per table. The baseline follows the
        // request OUTCOME, never the body (design §6 删除段): a throw keeps
        // every requested id for the next flush; any 2xx removes them all —
        // an id absent from the response was tombstoned by another device
        // or never existed, and neither needs anything more from here.
        let deletedIds = Set(previous.keys).subtracting(current.keys)
        if !deletedIds.isEmpty {
            do {
                let stamped = try await gateway.tombstone(
                    table: serverTable, keyColumn: "id", keys: deletedIds.sorted(), deletedAt: Date()
                )
                baseline.removeEntries(table: table, ids: deletedIds)
                deletes = deletedIds.count
                logger.info("\(table, privacy: .public): tombstoned \(deletedIds.count, privacy: .public) (\(stamped.count, privacy: .public) stamped now)")
            } catch {
                deleteFailure = error.localizedDescription
                logger.error("\(table, privacy: .public): tombstone PATCH failed, ids kept for the next flush: \(error.localizedDescription, privacy: .public)")
            }
        }

        var patches: [(PushRow, Int64)] = []
        var posts: [PushRow] = []
        for id in current.keys.sorted() {
            let item = current[id]!
            guard let base = previous[id] else { posts.append(item); continue }
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
                patches.append((item, seq))
            } else {
                posts.append(item)
            }
        }

        await sendConditionalPatches(serverTable: serverTable, keyColumn: "id", items: patches, tally: tally)
        await sendInserts(serverTable: serverTable, keyColumn: "id", items: posts, tally: tally)
        baseline.persist()

        if tally.failed == 0, deleteFailure == nil {
            logger.info("\(table, privacy: .public): \(tally.succeeded, privacy: .public) pushed, \(tally.stale, privacy: .public) pending verify, \(tally.awaitingEcho, privacy: .public) awaiting echo (of \(rows.count, privacy: .public) total)")
            statusReporter?.structuredRecord(table: table, upserts: tally.succeeded, deletes: deletes)
        } else {
            logger.error("\(table, privacy: .public): \(tally.succeeded, privacy: .public) pushed, \(tally.failed, privacy: .public) failed (of \(rows.count, privacy: .public) total)")
            statusReporter?.structuredRecordFailure(table: table, error: tally.lastError ?? deleteFailure ?? "unknown error")
        }
        if tally.needsPull { onNeedsPull?() }
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
        let item = PushRow(key: key, row: row, payload: payload)
        let tally = FlushTally()
        statusReporter?.structuredBeginBurst()
        defer { statusReporter?.structuredEndBurst() }
        if let baseSeq {
            await sendConditionalPatches(serverTable: table, keyColumn: "user_id", items: [(item, baseSeq)], tally: tally)
        } else {
            await sendInserts(serverTable: table, keyColumn: "user_id", items: [item], tally: tally)
        }
        baseline.persist()
        if tally.failed == 0 {
            logger.info("\(table, privacy: .public): pushed=\(tally.succeeded, privacy: .public) pending=\(tally.stale, privacy: .public) echo=\(tally.awaitingEcho, privacy: .public)")
            statusReporter?.structuredRecord(table: table, upserts: tally.succeeded, deletes: 0)
        } else {
            logger.error("\(table, privacy: .public) upload failed: \(tally.lastError ?? "unknown error", privacy: .public)")
            statusReporter?.structuredRecordFailure(table: table, error: tally.lastError ?? "unknown error")
        }
        if tally.needsPull { onNeedsPull?() }
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
                group.addTask { @MainActor in
                    let result = await self.performConditionalPatch(
                        serverTable: serverTable, keyColumn: keyColumn, item: item, baseSeq: baseSeq
                    )
                    self.record(result, for: item, baseSeq: baseSeq, serverTable: serverTable, tally: tally)
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

    /// The three response shapes (design §6 上传形状), judged by the body.
    private func record(
        _ result: Result<[[String: Any]], Error>,
        for item: PushRow,
        baseSeq: Int64,
        serverTable: String,
        tally: FlushTally
    ) {
        switch result {
        case .failure(let error):
            tally.failed += 1
            tally.lastError = error.localizedDescription
            logger.error("\(serverTable, privacy: .public) PATCH \(item.key.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        case .success(let rows):
            guard let row = rows.first else {
                // Stale or content-identical; the eligible pull decides.
                pendingVerify.insert(item.key, sentSeq: baseSeq, payload: item.payload, pullIssue: pullIssueCounter())
                tally.stale += 1
                tally.needsPull = true
                return
            }
            guard let seq = (row["seq"] as? NSNumber)?.int64Value else {
                tally.failed += 1
                tally.lastError = "\(serverTable): response row without seq"
                return
            }
            let dead = Self.isTombstoned(row)
            let singleton = Self.isSingletonTable(item.key.table)
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
            writeBaseline(item.key, payload: item.payload, seq: seq)
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
    /// already existed server-side and waits for its echo.
    private func sendInserts(
        serverTable: String,
        keyColumn: String,
        items: [PushRow],
        tally: FlushTally
    ) async {
        guard !items.isEmpty else { return }
        let chunkSize = SyncGatewayLimits.insertChunkSize
        for start in stride(from: 0, to: items.count, by: chunkSize) {
            let chunk = Array(items[start..<min(start + chunkSize, items.count)])
            do {
                let returned = try await gateway.insertIgnoringDuplicates(table: serverTable, rows: chunk.map(\.row))
                // The server renders uuid ids lowercase; the rows were sent
                // with `UUID.uuidString`. Match on the folded form.
                var seqs: [String: Int64] = [:]
                for row in returned {
                    if let id = row[keyColumn] as? String, let seq = (row["seq"] as? NSNumber)?.int64Value {
                        seqs[SyncBaselineKey.matchKey(id)] = seq
                    }
                }
                for item in chunk {
                    if let seq = seqs[SyncBaselineKey.matchKey(item.key.id)] {
                        writeBaseline(item.key, payload: item.payload, seq: seq)
                        awaitingEcho.remove(item.key)
                        tally.succeeded += 1
                    } else {
                        awaitingEcho.insert(item.key)
                        tally.awaitingEcho += 1
                    }
                }
            } catch {
                tally.failed += chunk.count
                tally.lastError = error.localizedDescription
                logger.error("\(serverTable, privacy: .public) POST failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func isSingletonTable(_ table: String) -> Bool {
        table == SyncBaselineStore.settingsTable || SyncBaselineStore.scalarTables.contains(table)
    }

    // MARK: - Sync: User Settings

    /// One row per user, merged per key (design §6 user_settings 段): the
    /// whole blob goes out conditional on the baseline seq, and "changed"
    /// means the per-key hashes of the blob as sent differ from the baseline.
    func syncSettings() async {
        guard flushGate("user_settings") else { return }
        guard !Self.settingsExportSuppressed(defaults) else { return }
        let local = SyncedSettings.currentSnapshot(defaults)
        let base = baseline.settings
        let blob = Self.settingsBlobForUpload(local: local, serverZone: base?.zone)
        let sentKeys = Self.settingsKeyHashes(blob)
        let row = settingsRow(blob)

        switch base {
        case .versioned(let seq, let keys, _):
            guard keys != sentKeys else { return }
            await pushSingleton(table: "user_settings", row: row, payload: .settingsKeys(sentKeys), baseSeq: seq)
        case .legacy(let legacyHash):
            // Still legacy means the local row had changed since the last
            // upload when this user signed in — unless it changed back.
            if legacyHash == Self.rowHash(row) {
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
        let local = SyncedSettings.currentSnapshot(defaults)
        switch baseline.settings {
        case .versioned(_, let keys, let zone):
            return keys == Self.settingsKeyHashes(Self.settingsBlobForUpload(local: local, serverZone: zone))
        case .legacy(let hash):
            return hash == Self.rowHash(settingsRow(local))
        case nil:
            return false
        }
    }

    private func settingsRow(_ blob: [String: Any]) -> [String: Any] {
        [
            "user_id": userId,
            "settings": blob,
            "updated_at": iso(Date()),
            "synced_at": iso(Date()),
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
        let base = baseline.entry(table: "agent_preferences", id: userId)
        guard base?.hash != hash else { return }
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
        guard base?.hash != hash else { return }
        await pushSingleton(table: "agent_conversations", row: row, payload: .rowHash(hash), baseSeq: base?.seq)
    }

    // MARK: - Row builders for the two single-row blob tables

    /// Same shape `syncAgentPreferences` uploads; extracted so
    /// `markRestoreCompleted` can reseed the diff baseline without
    /// re-uploading the bytes that just landed via restore.
    ///
    /// Includes `TokenInferenceRepository`'s 3 learned-state arrays
    /// (migration 011) in the same row — see migration comment for
    /// the "agent's learned model lives together" rationale.
    ///
    /// `rules` / `decision_history` are `jsonb not null` (migration 009),
    /// so an empty array goes out as `[]`, never as null (bench S13: null
    /// was a 400 on every upload for a zero-rule user). The three token
    /// columns are nullable and keep the null-for-empty encoding.
    func agentPreferencesToRow(_ store: AgentPreferenceStore) -> [String: Any] {
        let tokenState = TokenInferenceRepository.shared.snapshot()
        return [
            "user_id": userId,
            "rules": Self.encodeJSONArray(store.rules),
            "decision_history": Self.encodeJSONArray(store.decisionHistory),
            "token_dynamic_hypotheses": Self.encodeJSONOrNull(tokenState.dynamic),
            "token_meta_hypotheses": Self.encodeJSONOrNull(tokenState.meta),
            "token_projections": Self.encodeJSONOrNull(tokenState.projections),
            "updated_at": iso(Date()),
            "synced_at": iso(Date()),
        ]
    }

    /// Same shape `syncAgentConversations` uploads.
    ///
    /// The `[]` fallbacks below are now unreachable for the case that mattered.
    /// This used to read the raw `UserDefaults` blob, and an UNDECODABLE blob
    /// landed here as `[]` and was uploaded — overwriting the cloud's copy of a
    /// transcript at precisely the moment the local one had just been proven
    /// unreadable. That state is a freeze in the repository now, and
    /// `agentConversationsExportSuppressed` stops the upload before it starts.
    private func agentConversationsToRow() -> [String: Any] {
        let raw = AgentConversationRepository.shared.encodedJSONForSync() ?? Data()
        let decoded: Any
        if raw.isEmpty {
            decoded = []
        } else if let any = try? JSONSerialization.jsonObject(with: raw) {
            decoded = any
        } else {
            decoded = []
        }
        return [
            "user_id": userId,
            "conversations": decoded,
            "updated_at": iso(Date()),
            "synced_at": iso(Date()),
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
        let rows = events.map { e in eventToRow(e, kind: kind) }
        await pushTable(serverTable: "events", table: Self.eventsBaselineTable(kind: kind), rows: rows)
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
        row["updated_at"] = iso(Date())
        row["synced_at"] = iso(Date())
        return row
    }

    /// Same row minus `updated_at` / `synced_at`, which `rowHash` discards
    /// anyway (see `rowHashIgnoredKeys`) — so the hash is identical to
    /// `eventToRow`'s. Use on the hashing-only path (`syncStateForEvent`, the
    /// inspect UI's per-event hot loop) to skip two throwaway `iso(Date())`
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
        let rows = logs.map { logToRow($0) }
        await pushTable(serverTable: "event_logs", table: "event_logs", rows: rows)
    }

    private func logToRow(_ log: CalendarEventLogRecord) -> [String: Any] {
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
            "synced_at": iso(Date()),
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
        let rows = records.map(feedbackToRow)
        await pushTable(serverTable: "event_feedback", table: "event_feedback", rows: rows)
    }

    private func feedbackToRow(_ r: CalendarEventFeedbackRecord) -> [String: Any] {
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
            "synced_at": iso(Date()),
        ]
    }

    // MARK: - Sync: Todo Lists

    func syncTodoLists(_ lists: [TodoList]) async {
        guard !exportSuppressed(.todoLists, table: "todo_lists") else { return }
        let rows = lists.map(todoListToRow)
        await pushTable(serverTable: "todo_lists", table: "todo_lists", rows: rows)
    }

    private func todoListToRow(_ l: TodoList) -> [String: Any] {
        [
            "id": l.id.uuidString,
            "user_id": userId,
            "title": l.title,
            "color_name": l.colorName,
            "created_at": iso(l.createdAt),
            "synced_at": iso(Date()),
        ]
    }

    // MARK: - Sync: Event Types

    func syncEventTypes(_ templates: [EventTypeTemplate]) async {
        guard !Self.eventTypeExportSuppressed(of: attachedEventTypeStore) else { return }
        let rows = templates.map(eventTypeToRow)
        await pushTable(serverTable: "event_types", table: "event_types", rows: rows)
    }

    private func eventTypeToRow(_ t: EventTypeTemplate) -> [String: Any] {
        [
            "id": t.id.uuidString,
            "user_id": userId,
            "title": t.title,
            "color_hex": t.colorHex,
            "updated_at": iso(Date()),
            "synced_at": iso(Date()),
        ]
    }

    // MARK: - Sync: Skills

    func syncSkills(_ insights: [SkillInsight]) async {
        let rows = insights.map(skillToRow)
        await pushTable(serverTable: "skill_insights", table: "skill_insights", rows: rows)
    }

    private func skillToRow(_ s: SkillInsight) -> [String: Any] {
        [
            "id": s.id.uuidString,
            "user_id": userId,
            "skill_name": s.skillName,
            "points": s.points,
            "date": iso(s.date),
            "event_title": s.eventTitle,
            "reasoning": s.reasoning,
            "synced_at": iso(Date()),
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
    private func encodeOccurrenceKey(_ key: CalendarOccurrenceKey) -> String {
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
    /// the local stores. Recomputes the diff-sync baseline hashes from the
    /// freshly-restored local state so the debounced upload sinks see no diff
    /// — otherwise every restored row would be re-uploaded, bumping every
    /// `updated_at`/`synced_at` on the server for no good reason and risking
    /// spurious tombstones if local previously held rows the cloud snapshot
    /// didn't include. A seq already known for an id is kept; an unknown one
    /// stays unknown (legacy shape) and the ignore-duplicates POST or the
    /// echo recovers it (design §6.3).
    func markRestoreCompleted(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) {
        replayBaseline(table: "events", rows: eventStore.events.map { eventToRow($0, kind: "todo") })
        replayBaseline(table: "calendar_events", rows: eventStore.rawCalendarEvents.map { eventToRow($0, kind: "calendar") })
        replayBaseline(table: "event_logs", rows: eventStore.calendarEventLogRecords.map(logToRow))
        replayBaseline(table: "event_feedback", rows: eventStore.calendarEventFeedbackRecords.map(feedbackToRow))
        replayBaseline(table: "todo_lists", rows: eventStore.todoLists.map(todoListToRow))
        replayBaseline(table: "event_types", rows: eventTypeStore.templates.map(eventTypeToRow))
        replayBaseline(table: "skill_insights", rows: skillStore.insights.map(skillToRow))
        // Restore writes back to UserDefaults, which fires didChangeNotification
        // and would otherwise trigger an immediate re-upload of the freshly
        // restored settings. Seed the per-key baseline with the current state
        // so the next debounced settings sink sees zero diff.
        let settings = baseline.settings
        let blob = Self.settingsBlobForUpload(local: SyncedSettings.currentSnapshot(defaults), serverZone: settings?.zone)
        baseline.setSettings(.versioned(seq: settings?.seq, keys: Self.settingsKeyHashes(blob), zone: settings?.zone))
        // Same reasoning for the two blob tables (#2 + #3 from the
        // full-backup audit). Without these reseeds, applying a restore
        // would observe the just-written `preferenceStore` arrays + the
        // re-encoded conversations, compare to empty hashes, see "different",
        // and re-upload the restored bytes — bumping cloud
        // `updated_at`/`synced_at` for no real change.
        if let preferenceStore = attachedPreferenceStore {
            replaySingleton(table: "agent_preferences", hash: Self.rowHash(agentPreferencesToRow(preferenceStore)))
        }
        replaySingleton(table: "agent_conversations", hash: Self.rowHash(agentConversationsToRow()))
        // Persist the just-restored baseline so the next launch starts from
        // here, not from an empty map that would re-upload everything.
        baseline.persistAll()
    }

    private func replayBaseline(table: String, rows: [[String: Any]]) {
        let previous = baseline.entries(table: table)
        var next: [String: SyncBaselineEntry] = [:]
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            next[id] = SyncBaselineEntry(hash: Self.rowHash(row), seq: previous[id]?.seq)
        }
        baseline.replaceEntries(table: table, with: next)
    }

    private func replaySingleton(table: String, hash: String) {
        let seq = baseline.entry(table: table, id: userId)?.seq
        baseline.setEntry(SyncBaselineEntry(hash: hash, seq: seq), table: table, id: userId)
    }
}
