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
private func rowHash(_ row: [String: Any]) -> String {
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
    let joined = parts.joined(separator: "|")
    let digest = SHA256.hash(data: Data(joined.utf8))
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

/// Observes EventStore + related stores via Combine and syncs changes to Supabase.
/// iOS is the single source of truth; the server is a read-only mirror (+ AI tables).
/// Uses content hashing to only sync rows that actually changed.
@MainActor
final class SupabaseSyncService: ObservableObject {
    /// Constructed twice: once at init with `authService == nil` (so the
    /// type can be non-optional throughout), then replaced in `attach()`
    /// with the real `AuthService` reference. No PostgREST call happens
    /// before `attach`, so the placeholder client is never exercised —
    /// requests against it would throw `.notSignedIn`, which is the
    /// correct semantic for the pre-attach state.
    private var rest: SupabaseREST
    private var userId: String = ""
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
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Track previous state: ID → content hash
    private var lastEventHashes: [String: String] = [:]      // uuid → hash
    private var lastCalendarEventHashes: [String: String] = [:]
    private var lastLogHashes: [String: String] = [:]         // occurrenceKey → hash
    private var lastFeedbackHashes: [String: String] = [:]
    private var lastTodoListHashes: [String: String] = [:]
    private var lastSkillHashes: [String: String] = [:]
    private var lastEventTypeHashes: [String: String] = [:]
    /// user_settings is a single-row-per-user table — track its hash as a
    /// scalar rather than a per-id map.
    private var lastSettingsHash: String = ""
    /// agent_preferences is also one row per user. Same scalar pattern.
    private var lastAgentPrefsHash: String = ""
    /// agent_conversations: same.
    private var lastAgentConversationsHash: String = ""

    private var isFullSyncDone = false

    /// Re-entry guard for `fullSync`. The sign-in path and
    /// `userDidEnableUploads` can both kick off a fullSync; rapid toggle
    /// flipping could otherwise spawn N parallel passes that idempotent-upsert
    /// the same rows and stretch the `isFullSyncDone == false` window that
    /// blocks debounced sinks. Set inside the Task, cleared in defer.
    private var fullSyncInFlight = false

    init(
        url: String = SupabaseSyncConfig.url,
        apiKey: String = SupabaseSyncConfig.anonKey
    ) {
        // Placeholder client; `attach()` reconstructs with the real
        // `AuthService` reference for user-JWT auth.
        self.rest = SupabaseREST(url: url, projectAPIKey: apiKey, authService: nil as AuthService?)
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
        self.rest = SupabaseREST(
            url: SupabaseSyncConfig.url,
            projectAPIKey: SupabaseSyncConfig.anonKey,
            authService: authService
        )
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
                    self.userId = session.user.id
                    // Rehydrate diff-sync baseline from disk before any sync
                    // runs. Without this every cold start treats all rows as
                    // changed (issue #30 was the tracking ticket for the bug
                    // this addresses).
                    self.loadHashes(forUserId: self.userId)
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
                    self.userId = ""
                    self.isFullSyncDone = false
                    self.clearHashes()
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

    // MARK: - Per-row sync-state query (inspect UI)

    /// Sync-state observable by the inspect UI. Computed on demand from the
    /// existing in-memory hash maps; no new storage. After #30, those maps
    /// are persisted, so this returns meaningful state from the first frame
    /// of an inspect view (rather than "everything pending" until the first
    /// fullSync completes after launch).
    enum RowSyncState: Equatable {
        case synced            // local hash matches last-persisted upload hash
        case pending           // hash differs (or row not yet seen by sync)
        case offline           // sync hasn't run yet this session, can't tell
    }

    /// Per-event lookup. `kind` is "todo" or "calendar" to disambiguate which
    /// hash map to consult. Returns `.offline` when no userId is set so the
    /// UI can show a neutral state instead of falsely claiming "pending".
    func syncStateForEvent(_ event: Event, kind: String) -> RowSyncState {
        guard !userId.isEmpty else { return .offline }
        let map = kind == "todo" ? lastEventHashes : lastCalendarEventHashes
        let currentHash = rowHash(eventToRowForHashing(event, kind: kind))
        return map[event.id.uuidString] == currentHash ? .synced : .pending
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
        summarize(rows: lists.map(todoListToRow), map: lastTodoListHashes)
    }
    func syncSummaryForEventTypes(_ types: [EventTypeTemplate]) -> TableSyncSummary {
        summarize(rows: types.map(eventTypeToRow), map: lastEventTypeHashes)
    }
    func syncSummaryForSkills(_ insights: [SkillInsight]) -> TableSyncSummary {
        summarize(rows: insights.map(skillToRow), map: lastSkillHashes)
    }
    func syncSummaryForLogs(_ logs: [CalendarEventLogRecord]) -> TableSyncSummary {
        summarize(rows: logs.map(logToRow), map: lastLogHashes)
    }
    func syncSummaryForFeedback(_ records: [CalendarEventFeedbackRecord]) -> TableSyncSummary {
        summarize(rows: records.map(feedbackToRow), map: lastFeedbackHashes)
    }
    func syncSummaryForSettings() -> TableSyncSummary {
        guard !userId.isEmpty else { return .offline }
        let current = rowHash(settingsToRow())
        return current == lastSettingsHash ? .synced(count: 1) : .pending(synced: 0, pending: 1)
    }

    func syncSummaryForAgentPreferences(_ store: AgentPreferenceStore) -> TableSyncSummary {
        guard !userId.isEmpty else { return .offline }
        let current = rowHash(agentPreferencesToRow(store))
        return current == lastAgentPrefsHash ? .synced(count: 1) : .pending(synced: 0, pending: 1)
    }

    func syncSummaryForAgentConversations() -> TableSyncSummary {
        guard !userId.isEmpty else { return .offline }
        let current = rowHash(agentConversationsToRow())
        return current == lastAgentConversationsHash ? .synced(count: 1) : .pending(synced: 0, pending: 1)
    }

    private func summarize(rows: [[String: Any]], map: [String: String]) -> TableSyncSummary {
        guard !userId.isEmpty else { return .offline }
        guard !rows.isEmpty else { return .empty }
        var synced = 0
        var pending = 0
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            if map[id] == rowHash(row) {
                synced += 1
            } else {
                pending += 1
            }
        }
        return pending == 0 ? .synced(count: synced) : .pending(synced: synced, pending: pending)
    }

    private func clearHashes() {
        lastEventHashes = [:]
        lastCalendarEventHashes = [:]
        lastLogHashes = [:]
        lastFeedbackHashes = [:]
        lastTodoListHashes = [:]
        lastSkillHashes = [:]
        lastEventTypeHashes = [:]
        lastSettingsHash = ""
        lastAgentPrefsHash = ""
        lastAgentConversationsHash = ""
    }

    // MARK: - Hash persistence (#30)
    //
    // Diff-sync hash maps are persisted to UserDefaults so a relaunch with no
    // edits doesn't fall back to the empty-map-against-current-rows case,
    // which would treat every row as "changed" and burn bandwidth uploading
    // ~1,800 idempotent rows on every cold start.
    //
    // Storage shape: `syncHashes.<userId>.<tableLabel>` — JSON-encoded
    // `[rowId: hash]` for per-row maps, plain `String` for user_settings'
    // scalar hash. user_id scoping lets one device juggle multiple accounts
    // without cross-contaminating baselines; `clearHashes()` only wipes the
    // in-memory copy so the next sign-in (same account) re-uses persisted
    // state.

    /// Storage key suffix for `user_settings`' scalar hash. The 7 per-row
    /// table keys are inline at their respective syncX callsites — they
    /// can't be DRY'd into a list because each wrapper also reads/writes
    /// a distinct stored property, and Swift can't dispatch a property
    /// reference from a string. If a new table is added, mirror the
    /// inline-string pattern at the new syncX wrapper.
    private static let persistedSettingsTableKey = "user_settings"
    private static let persistedAgentPrefsTableKey = "agent_preferences"
    private static let persistedAgentConversationsTableKey = "agent_conversations"

    private func hashKey(table: String, userId: String) -> String {
        "syncHashes.\(userId).\(table)"
    }

    private func loadHashes(forUserId userId: String) {
        guard !userId.isEmpty else { return }
        lastEventHashes = readHashMap(table: "events", userId: userId)
        lastCalendarEventHashes = readHashMap(table: "calendar_events", userId: userId)
        lastLogHashes = readHashMap(table: "event_logs", userId: userId)
        lastFeedbackHashes = readHashMap(table: "event_feedback", userId: userId)
        lastTodoListHashes = readHashMap(table: "todo_lists", userId: userId)
        lastSkillHashes = readHashMap(table: "skill_insights", userId: userId)
        lastEventTypeHashes = readHashMap(table: "event_types", userId: userId)
        lastSettingsHash = UserDefaults.standard.string(
            forKey: hashKey(table: Self.persistedSettingsTableKey, userId: userId)
        ) ?? ""
        lastAgentPrefsHash = UserDefaults.standard.string(
            forKey: hashKey(table: Self.persistedAgentPrefsTableKey, userId: userId)
        ) ?? ""
        lastAgentConversationsHash = UserDefaults.standard.string(
            forKey: hashKey(table: Self.persistedAgentConversationsTableKey, userId: userId)
        ) ?? ""
    }

    private func readHashMap(table: String, userId: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: hashKey(table: table, userId: userId)),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    /// Persist a per-row hash map. Called by each per-table sync after the
    /// in-memory map is updated. No-op when `userId` isn't set (e.g. signed-out
    /// state) — we never persist hashes that can't be scoped to a user.
    private func persistHashes(table: String, hashes: [String: String]) {
        guard !userId.isEmpty,
              let data = try? JSONEncoder().encode(hashes)
        else { return }
        UserDefaults.standard.set(data, forKey: hashKey(table: table, userId: userId))
    }

    private func persistSettingsHash(_ hash: String) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.set(
            hash,
            forKey: hashKey(table: Self.persistedSettingsTableKey, userId: userId)
        )
    }

    private func persistAgentPrefsHash(_ hash: String) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.set(
            hash,
            forKey: hashKey(table: Self.persistedAgentPrefsTableKey, userId: userId)
        )
    }

    private func persistAgentConversationsHash(_ hash: String) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.set(
            hash,
            forKey: hashKey(table: Self.persistedAgentConversationsTableKey, userId: userId)
        )
    }

    /// Persist the full snapshot at once. Used by `markRestoreCompleted`
    /// (after a restore overwrites the in-memory state, we want the next
    /// launch to start from there, not from scratch).
    private func persistAllHashes() {
        persistHashes(table: "events", hashes: lastEventHashes)
        persistHashes(table: "calendar_events", hashes: lastCalendarEventHashes)
        persistHashes(table: "event_logs", hashes: lastLogHashes)
        persistHashes(table: "event_feedback", hashes: lastFeedbackHashes)
        persistHashes(table: "todo_lists", hashes: lastTodoListHashes)
        persistHashes(table: "skill_insights", hashes: lastSkillHashes)
        persistHashes(table: "event_types", hashes: lastEventTypeHashes)
        persistSettingsHash(lastSettingsHash)
        persistAgentPrefsHash(lastAgentPrefsHash)
        persistAgentConversationsHash(lastAgentConversationsHash)
    }

    /// Wipe persisted hashes for every user this device has ever signed in
    /// as. Used by "Reset all local data" in settings. Scans UserDefaults
    /// for keys with the `syncHashes.` prefix (since `userId` itself may
    /// not be currently known if the reset runs while signed out).
    static func wipeAllPersistedHashes() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("syncHashes.") {
            defaults.removeObject(forKey: key)
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

    // MARK: - Sync: User Settings

    /// One row per user; only upserts when the content hash actually differs.
    /// Always upserts a complete settings blob — no per-key diff. The row's
    /// `synced_at`/`updated_at` are excluded from the hash (see `rowHashIgnoredKeys`).
    private func syncSettings() async {
        guard !userId.isEmpty else { return }
        guard !Self.settingsExportSuppressed() else { return }
        let row = settingsToRow()
        let hash = rowHash(row)
        guard hash != lastSettingsHash else { return }
        // Wrap in a burst so a standalone settings sync (debounce-triggered,
        // outside fullSync) still emits a single aggregate; inside fullSync
        // nested begin/end is fine — the outer burst absorbs the inner one.
        statusReporter?.structuredBeginBurst()
        defer { statusReporter?.structuredEndBurst() }
        do {
            try await rest.upsert(table: "user_settings", rows: [row])
            lastSettingsHash = hash
            persistSettingsHash(hash)
            logger.info("user_settings: uploaded (\(row.count, privacy: .public) keys)")
            statusReporter?.structuredRecord(table: "user_settings", upserts: 1, deletes: 0)
        } catch {
            logger.error("user_settings upload failed: \(error.localizedDescription, privacy: .public)")
            statusReporter?.structuredRecordFailure(table: "user_settings", error: error.localizedDescription)
        }
    }

    private func settingsToRow() -> [String: Any] {
        return [
            "user_id": userId,
            "settings": SyncedSettings.currentSnapshot(),
            "updated_at": iso(Date()),
            "synced_at": iso(Date()),
        ]
    }

    // MARK: - Sync: Agent Preferences (rules + decision history)

    /// Single-row-per-user, same pattern as `user_settings`. Rules and history
    /// are encoded as JSON arrays directly into the row payload so jsonb
    /// storage preserves the typed Swift model shape without a relational
    /// schema for every nested enum / associated value.
    private func syncAgentPreferences(_ store: AgentPreferenceStore) async {
        guard !userId.isEmpty else { return }
        let row = agentPreferencesToRow(store)
        let hash = rowHash(row)
        guard hash != lastAgentPrefsHash else { return }
        statusReporter?.structuredBeginBurst()
        defer { statusReporter?.structuredEndBurst() }
        do {
            try await rest.upsert(table: "agent_preferences", rows: [row])
            lastAgentPrefsHash = hash
            persistAgentPrefsHash(hash)
            logger.info("agent_preferences: uploaded (\(store.rules.count, privacy: .public) rules, \(store.decisionHistory.count, privacy: .public) decisions)")
            statusReporter?.structuredRecord(table: "agent_preferences", upserts: 1, deletes: 0)
        } catch {
            logger.error("agent_preferences upload failed: \(error.localizedDescription, privacy: .public)")
            statusReporter?.structuredRecordFailure(table: "agent_preferences", error: error.localizedDescription)
        }
    }

    // MARK: - Sync: Agent Conversations (chat history)

    /// One-row-per-user blob of the chat history. Read from
    /// `AgentConversationRepository`, which is the canonical singleton this
    /// used to say did not exist: the several `@StateObject AgentService()`
    /// instances shared their state through `UserDefaults`, and when those
    /// bytes moved to a file they needed one owner rather than N caches.
    private func syncAgentConversations() async {
        guard !userId.isEmpty else { return }
        guard !Self.agentConversationsExportSuppressed() else { return }
        let row = agentConversationsToRow()
        let hash = rowHash(row)
        guard hash != lastAgentConversationsHash else { return }
        statusReporter?.structuredBeginBurst()
        defer { statusReporter?.structuredEndBurst() }
        do {
            try await rest.upsert(table: "agent_conversations", rows: [row])
            lastAgentConversationsHash = hash
            persistAgentConversationsHash(hash)
            let count = (row["conversations"] as? [Any])?.count ?? 0
            logger.info("agent_conversations: uploaded (\(count, privacy: .public) conversations)")
            statusReporter?.structuredRecord(table: "agent_conversations", upserts: 1, deletes: 0)
        } catch {
            logger.error("agent_conversations upload failed: \(error.localizedDescription, privacy: .public)")
            statusReporter?.structuredRecordFailure(table: "agent_conversations", error: error.localizedDescription)
        }
    }

    // MARK: - Row builders for the two new single-row blob tables

    /// Same shape `syncAgentPreferences` uploads; extracted so
    /// `markRestoreCompleted` can reseed the diff baseline without
    /// re-uploading the bytes that just landed via restore.
    ///
    /// Includes `TokenInferenceRepository`'s 3 learned-state arrays
    /// (migration 011) in the same row — see migration comment for
    /// the "agent's learned model lives together" rationale.
    private func agentPreferencesToRow(_ store: AgentPreferenceStore) -> [String: Any] {
        let tokenState = TokenInferenceRepository.shared.snapshot()
        return [
            "user_id": userId,
            "rules": encodeJSONOrNull(store.rules),
            "decision_history": encodeJSONOrNull(store.decisionHistory),
            "token_dynamic_hypotheses": encodeJSONOrNull(tokenState.dynamic),
            "token_meta_hypotheses": encodeJSONOrNull(tokenState.meta),
            "token_projections": encodeJSONOrNull(tokenState.projections),
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
    /// `diffSync` is a MIRROR: ids that are in the previous hash map and not
    /// in the rows handed to it are DELETEd from the cloud. That is correct
    /// when the local array is the user's data and wrong when it merely looks
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
    /// because `diffSync` is a mirror: four fallback rows uploaded would
    /// DELETE every real type the user has in the cloud, and every event
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
    /// `agent_conversations` is one row per user upserted WHOLE, so this is the
    /// bluntest instrument of the three: an unreadable file reads as `[]`, and
    /// `[]` upserted is not a stale row or a missing key — it is the user's
    /// entire transcript replaced with nothing, in the one moment the cloud was
    /// the last copy standing. Suppress until a restore says otherwise.
    static func agentConversationsExportSuppressed(
        _ repository: AgentConversationRepository = .shared
    ) -> Bool {
        guard repository.isFrozen else { return false }
        logger.error("agent_conversations: upload SUPPRESSED — the local conversation file is unreadable; not mirroring an empty history over the cloud's copy")
        return true
    }

    /// The settings blob's equivalent, and it exists for a sharper reason than
    /// symmetry: `user_settings` is a single row upserted WHOLE, so a key the
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

    // MARK: - Generic diff + batch upsert

    /// Diff rows against previous hashes, upsert only changed rows, delete removed rows.
    /// Returns updated hash map.
    @discardableResult
    private func diffSync(
        table: String,
        rows: [[String: Any]],
        idKey: String = "id",
        previousHashes: [String: String]
    ) async -> [String: String] {
        // Build current hashes
        var currentHashes: [String: String] = [:]
        var changedRows: [[String: Any]] = []

        for row in rows {
            guard let rowId = row[idKey] as? String else { continue }
            let hash = rowHash(row)
            currentHashes[rowId] = hash

            if previousHashes[rowId] != hash {
                changedRows.append(row)
            }
        }

        let deletedIds = Set(previousHashes.keys).subtracting(currentHashes.keys)

        var deleteFailureMessage: String?
        var actualDeletes = 0
        if !deletedIds.isEmpty {
            do {
                try await rest.delete(table: table, ids: Array(deletedIds), idColumn: idKey)
                actualDeletes = deletedIds.count
                logger.info("Deleted \(deletedIds.count, privacy: .public) from \(table, privacy: .public)")
            } catch {
                deleteFailureMessage = error.localizedDescription
                logger.error("Delete \(table, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Upsert changed rows in chunks. Each chunk failure is isolated.
        var succeeded = 0
        var failed = 0
        var lastUpsertError: String?
        if !changedRows.isEmpty {
            let chunkSize = 20

            for i in stride(from: 0, to: changedRows.count, by: chunkSize) {
                let chunk = Array(changedRows[i..<min(i + chunkSize, changedRows.count)])
                do {
                    try await rest.upsert(table: table, rows: chunk)
                    succeeded += chunk.count
                } catch {
                    failed += chunk.count
                    lastUpsertError = error.localizedDescription
                    // Don't update hashes for failed rows so they retry next time
                    for row in chunk {
                        if let rowId = row[idKey] as? String {
                            currentHashes[rowId] = previousHashes[rowId] ?? ""
                        }
                    }
                }
            }

            if failed == 0 {
                logger.info("\(table, privacy: .public): \(succeeded, privacy: .public) changed (of \(rows.count, privacy: .public) total)")
            } else {
                logger.error("\(table, privacy: .public): \(succeeded, privacy: .public) synced, \(failed, privacy: .public) failed (of \(rows.count, privacy: .public) total)")
            }
        }

        if failed > 0 || deleteFailureMessage != nil {
            let msg = lastUpsertError ?? deleteFailureMessage ?? "unknown error"
            statusReporter?.structuredRecordFailure(table: table, error: msg)
        } else {
            statusReporter?.structuredRecord(table: table, upserts: succeeded, deletes: actualDeletes)
        }

        return currentHashes
    }

    // MARK: - Sync: Events

    private func syncEvents(_ events: [Event], kind: String) async {
        guard !exportSuppressed(kind == "todo" ? .events : .calendarEvents,
                                table: "events(\(kind))") else { return }
        let rows = events.map { e in eventToRow(e, kind: kind) }

        let previousHashes = kind == "todo" ? lastEventHashes : lastCalendarEventHashes
        let newHashes = await diffSync(
            table: "events",
            rows: rows,
            previousHashes: previousHashes
        )

        if kind == "todo" {
            lastEventHashes = newHashes
            persistHashes(table: "events", hashes: newHashes)
        } else {
            lastCalendarEventHashes = newHashes
            persistHashes(table: "calendar_events", hashes: newHashes)
        }
    }

    private func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Full upload payload for an event row, including the always-now
    /// `updated_at` / `synced_at` timestamps the server persists.
    internal func eventToRow(_ e: Event, kind: String) -> [String: Any] {
        var row = eventRowHashableFields(e, kind: kind)
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
        eventRowHashableFields(e, kind: kind)
    }

    /// The hashed portion of an event row — every field except the two
    /// always-now timestamps. Single source of truth shared by `eventToRow`
    /// (upload) and `eventToRowForHashing` (state check) so their hashes can
    /// never drift apart.
    private func eventRowHashableFields(_ e: Event, kind: String) -> [String: Any] {
        // ALL keys must always be present (use NSNull for nil).
        // PostgREST requires uniform keys across batch rows.
        let ranges: [[String: String]] = e.timeRanges.map { r in
            ["start": iso(r.start), "end": iso(r.end)]
        }
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
            "recurrence_exception_dates": exDates,
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
    private func encodeJSONOrNull<T: Encodable>(_ value: T?) -> Any {
        guard let value else { return NSNull() }
        if let arr = value as? [Any], arr.isEmpty { return NSNull() }
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return NSNull() }
        if let arr = decoded as? [Any], arr.isEmpty { return NSNull() }
        return decoded
    }

    // MARK: - Sync: Logs

    private func syncLogs(_ logs: [CalendarEventLogRecord]) async {
        guard !exportSuppressed(.calendarEventLogRecords, table: "event_logs") else { return }
        let rows = logs.map { logToRow($0) }
        lastLogHashes = await diffSync(
            table: "event_logs",
            rows: rows,
            previousHashes: lastLogHashes
        )
        persistHashes(table: "event_logs", hashes: lastLogHashes)
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

    private func syncFeedback(_ records: [CalendarEventFeedbackRecord]) async {
        guard !exportSuppressed(.calendarEventFeedbackRecords, table: "event_feedback") else { return }
        let rows = records.map(feedbackToRow)
        lastFeedbackHashes = await diffSync(
            table: "event_feedback",
            rows: rows,
            previousHashes: lastFeedbackHashes
        )
        persistHashes(table: "event_feedback", hashes: lastFeedbackHashes)
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

    private func syncTodoLists(_ lists: [TodoList]) async {
        guard !exportSuppressed(.todoLists, table: "todo_lists") else { return }
        let rows = lists.map(todoListToRow)
        lastTodoListHashes = await diffSync(
            table: "todo_lists",
            rows: rows,
            previousHashes: lastTodoListHashes
        )
        persistHashes(table: "todo_lists", hashes: lastTodoListHashes)
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

    private func syncEventTypes(_ templates: [EventTypeTemplate]) async {
        guard !Self.eventTypeExportSuppressed(of: attachedEventTypeStore) else { return }
        let rows = templates.map(eventTypeToRow)
        lastEventTypeHashes = await diffSync(
            table: "event_types",
            rows: rows,
            previousHashes: lastEventTypeHashes
        )
        persistHashes(table: "event_types", hashes: lastEventTypeHashes)
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

    private func syncSkills(_ insights: [SkillInsight]) async {
        let rows = insights.map(skillToRow)
        lastSkillHashes = await diffSync(
            table: "skill_insights",
            rows: rows,
            previousHashes: lastSkillHashes
        )
        persistHashes(table: "skill_insights", hashes: lastSkillHashes)
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

    /// Pull all rows for the current signed-in user. Returns raw row dictionaries
    /// keyed by table name; deserialization to typed models is the caller's job.
    /// Throws `RestoreError.notSignedIn` if the user is not authenticated.
    func fetchAllRawRows() async throws -> [String: [[String: Any]]] {
        guard !userId.isEmpty else { throw RestoreError.notSignedIn }
        let capturedUserId = userId
        var result: [String: [[String: Any]]] = [:]
        for table in Self.restoreTables {
            do {
                let rows = try await rest.fetchAll(table: table, userId: capturedUserId)
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
    /// spurious deletions if local previously held rows the cloud snapshot
    /// didn't include.
    func markRestoreCompleted(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) {
        lastEventHashes = hashMap(
            rows: eventStore.events.map { eventToRow($0, kind: "todo") }
        )
        lastCalendarEventHashes = hashMap(
            rows: eventStore.rawCalendarEvents.map { eventToRow($0, kind: "calendar") }
        )
        lastLogHashes = hashMap(rows: eventStore.calendarEventLogRecords.map(logToRow))
        lastFeedbackHashes = hashMap(rows: eventStore.calendarEventFeedbackRecords.map(feedbackToRow))
        lastTodoListHashes = hashMap(rows: eventStore.todoLists.map(todoListToRow))
        lastEventTypeHashes = hashMap(rows: eventTypeStore.templates.map(eventTypeToRow))
        lastSkillHashes = hashMap(rows: skillStore.insights.map(skillToRow))
        // Restore writes back to UserDefaults, which fires didChangeNotification
        // and would otherwise trigger an immediate re-upload of the freshly
        // restored settings. Seed the scalar hash with the current state so
        // the next debounced settings sink sees zero diff.
        lastSettingsHash = rowHash(settingsToRow())
        // Same reasoning for the two new blob tables (#2 + #3 from the
        // full-backup audit). Without these reseeds, applying a restore
        // would observe the just-written `preferenceStore` arrays + the
        // re-encoded `agentConversations` UserDefaults blob, compare to
        // empty hashes, see "different", and re-upload the restored bytes
        // — bumping cloud `updated_at`/`synced_at` for no real change.
        if let preferenceStore = attachedPreferenceStore {
            lastAgentPrefsHash = rowHash(agentPreferencesToRow(preferenceStore))
        }
        lastAgentConversationsHash = rowHash(agentConversationsToRow())
        // Persist the just-restored baseline so the next launch starts from
        // here, not from an empty map that would re-upload everything.
        persistAllHashes()
    }

    private func hashMap(rows: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            out[id] = rowHash(row)
        }
        return out
    }
}
