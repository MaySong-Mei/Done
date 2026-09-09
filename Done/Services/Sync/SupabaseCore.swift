//
//  SupabaseCore.swift
//  Done
//
//  Platform-neutral Supabase seam (gh#219 DoneMac plan, B-6). Holds the
//  pieces both app targets need; SupabaseREST and the row codec join it
//  when the Mac sync phase lands. The key literal lives ONLY here so the
//  Stage-3 rotation (#28) is a one-file fix.
//

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Sync"
)

// MARK: - Configuration

enum SupabaseSyncConfig {
    nonisolated static let url = "https://uqnvtzblppjblwgbpqhf.supabase.co"
    /// Project key for the `apikey` HTTP header. As of Stage 2 of #28
    /// this is ONLY used to identify the Supabase project — the
    /// `Authorization` header now carries the per-user JWT, so RLS
    /// enforces row access.
    ///
    /// **TODO(Stage 3 of #28): rotation hazard.** This constant is
    /// misnamed: decoding the JWT shows `role: service_role`, valid
    /// until 2036. Stage 3 must:
    ///   1. Generate the project's actual `anon` key in the Supabase
    ///      dashboard.
    ///   2. Replace this string with that anon key + push a new app
    ///      build.
    ///   3. Wait until that build has propagated to ~all active
    ///      installs (TestFlight + AppStore release cohort).
    ///   4. ONLY THEN rotate the service_role key in the dashboard.
    ///      Rotating earlier leaves every pre-Stage-3 binary
    ///      permanently 401'd because the bundled key it sends in
    ///      `apikey` is rejected.
    ///   5. Coordinate same-time env-var rollover in `done-mcp`
    ///      backend (whose service_role key is from the same project).
    nonisolated static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVxbnZ0emJscHBqYmx3Z2JwcWhmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NjE2MzA5MiwiZXhwIjoyMDkxNzM5MDkyfQ.LUwM3Kq6UbPiPeucHfn5iKaNh1RhEY5X1dU61BRS4Ng"
    nonisolated static let debounceSeconds: TimeInterval = 2.0
}

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
final class SupabaseREST {
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

    // MARK: - PostgREST verbs

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

    /// Fetch all rows for a given user_id. Pages through PostgREST 1k-row windows.
    /// PostgREST caps a single response, so we walk Range headers until a short page arrives.
    ///
    /// Note: with RLS now enforcing `auth.uid() = user_id`, the
    /// `?user_id=eq.X` query parameter is technically redundant — the
    /// server would filter to the JWT's user_id anyway. Kept it as belt-
    /// and-suspenders / explicit-intent + back-compat with any caller
    /// that passed a different ID expecting service_role bypass.
    func fetchAll(table: String, userId: String) async throws -> [[String: Any]] {
        guard !userId.isEmpty else { return [] }
        guard let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SyncError.fetchFailed(table: table, status: -1)
        }
        let pageSize = 1000
        let safetyCap = 100_000
        var offset = 0
        var allRows: [[String: Any]] = []

        while true {
            let urlStr = "\(baseURL)/rest/v1/\(table)?user_id=eq.\(encodedUserId)"
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
            case .notSignedIn: return "Cannot reach Supabase: not signed in."
            case .tokenExpired: return "Session expired — please sign in again."
            }
        }
    }
}
