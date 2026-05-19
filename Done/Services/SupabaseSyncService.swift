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
    nonisolated static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVxbnZ0emJscHBqYmx3Z2JwcWhmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NjE2MzA5MiwiZXhwIjoyMDkxNzM5MDkyfQ.LUwM3Kq6UbPiPeucHfn5iKaNh1RhEY5X1dU61BRS4Ng"
    nonisolated static let debounceSeconds: TimeInterval = 2.0
}

// MARK: - Supabase REST Client (minimal, no SDK dependency)

/// Thin REST client for Supabase PostgREST. No external dependencies.
final class SupabaseREST: Sendable {
    private let baseURL: String
    private let apiKey: String

    init(url: String, apiKey: String) {
        self.baseURL = url
        self.apiKey = apiKey
    }

    /// Upsert rows into a table. All rows MUST have identical keys.
    func upsert(table: String, rows: [[String: Any]]) async throws {
        guard !rows.isEmpty else { return }
        let url = URL(string: "\(baseURL)/rest/v1/\(table)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: rows)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            logger.error("Upsert \(table, privacy: .public) HTTP \(code, privacy: .public): \(body.prefix(200), privacy: .public)")
            throw SyncError.upsertFailed(table: table, status: code)
        }
    }

    /// Delete rows by IDs.
    func delete(table: String, ids: [String], idColumn: String = "id") async throws {
        guard !ids.isEmpty else { return }
        let joined = ids.joined(separator: ",")
        let urlStr = "\(baseURL)/rest/v1/\(table)?\(idColumn)=in.(\(joined))"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SyncError.deleteFailed(table: table, status: code)
        }
    }

    /// Fetch all rows for a given user_id. Pages through PostgREST 1k-row windows.
    /// PostgREST caps a single response, so we walk Range headers until a short page arrives.
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
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("\(offset)-\(offset + pageSize - 1)", forHTTPHeaderField: "Range")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.fetchFailed(table: table, status: -1)
            }
            // PostgREST returns 416 when the requested offset is past the end of
            // the result set — e.g. when the total row count is an exact multiple
            // of pageSize and our trailing request lands one page too far.
            if http.statusCode == 416 {
                break
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                logger.error("Fetch \(table, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(body.prefix(200), privacy: .public)")
                throw SyncError.fetchFailed(table: table, status: http.statusCode)
            }

            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let rows = parsed as? [[String: Any]] else {
                throw SyncError.fetchFailed(table: table, status: http.statusCode)
            }
            allRows.append(contentsOf: rows)

            if rows.count < pageSize { break }
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

        var errorDescription: String? {
            switch self {
            case .upsertFailed(let t, let s): return "Upsert to \(t) failed (HTTP \(s))"
            case .deleteFailed(let t, let s): return "Delete from \(t) failed (HTTP \(s))"
            case .fetchFailed(let t, let s): return "Fetch from \(t) failed (HTTP \(s))"
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
private func rowHash(_ row: [String: Any]) -> String {
    // Sort keys for deterministic output
    let sorted = row.keys.sorted()
    var parts: [String] = []
    for key in sorted where !rowHashIgnoredKeys.contains(key) {
        let val = row[key]
        if val is NSNull {
            parts.append("\(key):null")
        } else {
            parts.append("\(key):\(String(describing: val!))")
        }
    }
    let joined = parts.joined(separator: "|")
    let digest = SHA256.hash(data: Data(joined.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Sync Service

/// Observes EventStore + related stores via Combine and syncs changes to Supabase.
/// iOS is the single source of truth; the server is a read-only mirror (+ AI tables).
/// Uses content hashing to only sync rows that actually changed.
@MainActor
final class SupabaseSyncService: ObservableObject {
    private let rest: SupabaseREST
    private var userId: String = ""
    private weak var authService: AuthService?
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

    private var isFullSyncDone = false

    init(
        url: String = SupabaseSyncConfig.url,
        apiKey: String = SupabaseSyncConfig.anonKey
    ) {
        self.rest = SupabaseREST(url: url, apiKey: apiKey)
    }

    /// In DEBUG builds we disable all upload paths (fullSync + the per-store
    /// Combine sinks) so simulator/dev runs can sign in with a real account
    /// without polluting the production Supabase tables. Read paths
    /// (`fetchAllRawRows`) stay live so dry-run preview and restore still work.
    /// Release builds always sync normally.
    #if DEBUG
    private static let uploadsDisabled = true
    #else
    private static let uploadsDisabled = false
    #endif

    /// Start observing stores. Call once after stores are initialized.
    func attach(
        authService: AuthService,
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) {
        self.authService = authService
        let debounce = SupabaseSyncConfig.debounceSeconds

        if Self.uploadsDisabled {
            logger.notice("⚠️ DEBUG build — uploads disabled. Auth + read-only sync only. Restore (GET) still works.")
        }

        // ── Watch auth state: keep userId in lockstep with session in all
        //    builds (fetchAllRawRows needs it). Skip the upload-side fullSync
        //    when uploads are disabled.
        authService.$session
            .sink { [weak self, weak eventStore, weak eventTypeStore, weak skillStore] session in
                guard let self else { return }
                if let session {
                    self.userId = session.user.id
                    if Self.uploadsDisabled {
                        // Mark "ready" so any code gated on isFullSyncDone still
                        // works as expected (no harm — there are no sinks to gate).
                        self.isFullSyncDone = true
                        return
                    }
                    if let es = eventStore, let ets = eventTypeStore, let ss = skillStore {
                        Task {
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
        // but nothing on the device will ever be pushed to Supabase.
        if Self.uploadsDisabled { return }

        // ── Todo events ──
        eventStore.$events
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] events in
                guard let self, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncEvents(events, kind: "todo") }
            }
            .store(in: &cancellables)

        // ── Calendar events ──
        eventStore.$calendarEvents
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] events in
                guard let self, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncEvents(events, kind: "calendar") }
            }
            .store(in: &cancellables)

        // ── Event logs ──
        eventStore.$calendarEventLogRecords
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] logs in
                guard let self, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncLogs(logs) }
            }
            .store(in: &cancellables)

        // ── Event feedback ──
        eventStore.$calendarEventFeedbackRecords
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] records in
                guard let self, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncFeedback(records) }
            }
            .store(in: &cancellables)

        // ── Todo lists ──
        eventStore.$todoLists
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] lists in
                guard let self, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncTodoLists(lists) }
            }
            .store(in: &cancellables)

        // ── Event types ──
        eventTypeStore.$templates
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] templates in
                guard let self, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncEventTypes(templates) }
            }
            .store(in: &cancellables)

        // ── Skill insights ──
        skillStore.$insights
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] insights in
                guard let self, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncSkills(insights) }
            }
            .store(in: &cancellables)

        // ── User settings ──
        // UserDefaults.didChangeNotification fires on any write, not just our
        // synced keys, so debounce aggressively (5s) and let the row-hash check
        // inside `syncSettings()` collapse no-op uploads to nothing.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isFullSyncDone, !self.userId.isEmpty else { return }
                Task { await self.syncSettings() }
            }
            .store(in: &cancellables)
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
    }

    // MARK: - Full sync (on launch)

    private func fullSync(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) async {
        logger.info("Full sync starting…")
        await syncEvents(eventStore.events, kind: "todo")
        await syncEvents(eventStore.calendarEvents, kind: "calendar")
        await syncLogs(eventStore.calendarEventLogRecords)
        await syncFeedback(eventStore.calendarEventFeedbackRecords)
        await syncTodoLists(eventStore.todoLists)
        await syncEventTypes(eventTypeStore.templates)
        await syncSkills(skillStore.insights)
        await syncSettings()
        logger.info("Full sync complete")
    }

    // MARK: - Sync: User Settings

    /// One row per user; only upserts when the content hash actually differs.
    /// Always upserts a complete settings blob — no per-key diff. The row's
    /// `synced_at`/`updated_at` are excluded from the hash (see `rowHashIgnoredKeys`).
    private func syncSettings() async {
        guard !userId.isEmpty else { return }
        let row = settingsToRow()
        let hash = rowHash(row)
        guard hash != lastSettingsHash else { return }
        do {
            try await rest.upsert(table: "user_settings", rows: [row])
            lastSettingsHash = hash
            logger.info("user_settings: uploaded (\(row.count, privacy: .public) keys)")
        } catch {
            logger.error("user_settings upload failed: \(error.localizedDescription, privacy: .public)")
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

        // Detect deletions
        let deletedIds = Set(previousHashes.keys).subtracting(currentHashes.keys)
        if !deletedIds.isEmpty {
            do {
                try await rest.delete(table: table, ids: Array(deletedIds), idColumn: idKey)
                logger.info("Deleted \(deletedIds.count, privacy: .public) from \(table, privacy: .public)")
            } catch {
                logger.error("Delete \(table, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Upsert changed rows in chunks. Each chunk failure is isolated.
        if !changedRows.isEmpty {
            let chunkSize = 20
            var succeeded = 0
            var failed = 0

            for i in stride(from: 0, to: changedRows.count, by: chunkSize) {
                let chunk = Array(changedRows[i..<min(i + chunkSize, changedRows.count)])
                do {
                    try await rest.upsert(table: table, rows: chunk)
                    succeeded += chunk.count
                } catch {
                    failed += chunk.count
                    // Don't update hashes for failed rows so they retry next time
                    for row in chunk {
                        if let rowId = row[idKey] as? String {
                            currentHashes[rowId] = previousHashes[rowId] ?? ""
                        }
                    }
                }
            }

            let total = succeeded + failed
            if failed == 0 {
                logger.info("\(table, privacy: .public): \(succeeded, privacy: .public) changed (of \(rows.count, privacy: .public) total)")
            } else {
                logger.error("\(table, privacy: .public): \(succeeded, privacy: .public) synced, \(failed, privacy: .public) failed (of \(rows.count, privacy: .public) total)")
            }
        } else if deletedIds.isEmpty {
            // Nothing changed
        }

        return currentHashes
    }

    // MARK: - Sync: Events

    private func syncEvents(_ events: [Event], kind: String) async {
        let rows = events.map { e in eventToRow(e, kind: kind) }

        let previousHashes = kind == "todo" ? lastEventHashes : lastCalendarEventHashes
        let newHashes = await diffSync(
            table: "events",
            rows: rows,
            previousHashes: previousHashes
        )

        if kind == "todo" { lastEventHashes = newHashes }
        else { lastCalendarEventHashes = newHashes }
    }

    private func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private func eventToRow(_ e: Event, kind: String) -> [String: Any] {
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
            "interrupt_relation": ir,
            "wanna_notes": wannaNotesPayload,
            "agentic_intake": agenticIntakePayload,
            "suggested_log_template_id": e.suggestedLogTemplateID as Any? ?? NSNull(),
            "suggested_log_template_confidence": e.suggestedLogTemplateConfidence as Any? ?? NSNull(),
            "suggested_log_template_updated_at": e.suggestedLogTemplateUpdatedAt.map { iso($0) } as Any? ?? NSNull(),
            "suggested_log_template_source": e.suggestedLogTemplateSource?.rawValue as Any? ?? NSNull(),
            "created_at": iso(e.createdAt),
            "updated_at": iso(Date()),
            "synced_at": iso(Date()),
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
        let rows = logs.map { logToRow($0) }
        lastLogHashes = await diffSync(
            table: "event_logs",
            rows: rows,
            previousHashes: lastLogHashes
        )
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
        let rows = records.map(feedbackToRow)
        lastFeedbackHashes = await diffSync(
            table: "event_feedback",
            rows: rows,
            previousHashes: lastFeedbackHashes
        )
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
        let rows = lists.map(todoListToRow)
        lastTodoListHashes = await diffSync(
            table: "todo_lists",
            rows: rows,
            previousHashes: lastTodoListHashes
        )
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
        let rows = templates.map(eventTypeToRow)
        lastEventTypeHashes = await diffSync(
            table: "event_types",
            rows: rows,
            previousHashes: lastEventTypeHashes
        )
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

    /// Encode CalendarOccurrenceKey to a stable string ID for Supabase.
    private func encodeOccurrenceKey(_ key: CalendarOccurrenceKey) -> String {
        let dateStr = iso(key.occurrenceDate)
        let base = key.baseSeriesEventID?.uuidString ?? "none"
        return "\(key.kind.rawValue)|\(key.eventID.uuidString)|\(base)|\(dateStr)"
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
            rows: eventStore.calendarEvents.map { eventToRow($0, kind: "calendar") }
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
