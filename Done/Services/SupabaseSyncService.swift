import Foundation
import Combine
import CryptoKit

// MARK: - Configuration

enum SupabaseSyncConfig {
    static let url = "https://uqnvtzblppjblwgbpqhf.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVxbnZ0emJscHBqYmx3Z2JwcWhmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NjE2MzA5MiwiZXhwIjoyMDkxNzM5MDkyfQ.LUwM3Kq6UbPiPeucHfn5iKaNh1RhEY5X1dU61BRS4Ng"
    // TODO: Replace with real auth — for now we use a fixed test user
    static let userId = "9c415221-a561-46eb-b562-f81f62e2af51"
    static let debounceSeconds: TimeInterval = 2.0
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
            print("[Sync] Upsert \(table) HTTP \(code): \(body.prefix(200))")
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

    enum SyncError: Error, LocalizedError {
        case upsertFailed(table: String, status: Int)
        case deleteFailed(table: String, status: Int)

        var errorDescription: String? {
            switch self {
            case .upsertFailed(let t, let s): return "Upsert to \(t) failed (HTTP \(s))"
            case .deleteFailed(let t, let s): return "Delete from \(t) failed (HTTP \(s))"
            }
        }
    }
}

// MARK: - Row Hashing (for diff-based sync)

/// Compute a stable hash for a row dictionary so we can detect changes.
private func rowHash(_ row: [String: Any]) -> String {
    // Sort keys for deterministic output
    let sorted = row.keys.sorted()
    var parts: [String] = []
    for key in sorted {
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
    private let userId: String
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

    private var isFullSyncDone = false

    init(
        url: String = SupabaseSyncConfig.url,
        apiKey: String = SupabaseSyncConfig.anonKey,
        userId: String = SupabaseSyncConfig.userId
    ) {
        self.rest = SupabaseREST(url: url, apiKey: apiKey)
        self.userId = userId
    }

    /// Start observing stores. Call once after stores are initialized.
    func attach(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) {
        let debounce = SupabaseSyncConfig.debounceSeconds

        // ── Todo events ──
        eventStore.$events
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] events in
                guard let self, self.isFullSyncDone else { return }
                Task { await self.syncEvents(events, kind: "todo") }
            }
            .store(in: &cancellables)

        // ── Calendar events ──
        eventStore.$calendarEvents
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] events in
                guard let self, self.isFullSyncDone else { return }
                Task { await self.syncEvents(events, kind: "calendar") }
            }
            .store(in: &cancellables)

        // ── Event logs ──
        eventStore.$calendarEventLogRecords
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] logs in
                guard let self, self.isFullSyncDone else { return }
                Task { await self.syncLogs(logs) }
            }
            .store(in: &cancellables)

        // ── Event feedback ──
        eventStore.$calendarEventFeedbackRecords
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] records in
                guard let self, self.isFullSyncDone else { return }
                Task { await self.syncFeedback(records) }
            }
            .store(in: &cancellables)

        // ── Todo lists ──
        eventStore.$todoLists
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] lists in
                guard let self, self.isFullSyncDone else { return }
                Task { await self.syncTodoLists(lists) }
            }
            .store(in: &cancellables)

        // ── Event types ──
        eventTypeStore.$templates
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] templates in
                guard let self, self.isFullSyncDone else { return }
                Task { await self.syncEventTypes(templates) }
            }
            .store(in: &cancellables)

        // ── Skill insights ──
        skillStore.$insights
            .dropFirst()
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] insights in
                guard let self, self.isFullSyncDone else { return }
                Task { await self.syncSkills(insights) }
            }
            .store(in: &cancellables)

        // Do a full sync on attach
        Task {
            await fullSync(
                eventStore: eventStore,
                eventTypeStore: eventTypeStore,
                skillStore: skillStore
            )
            isFullSyncDone = true
        }
    }

    // MARK: - Full sync (on launch)

    private func fullSync(
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore
    ) async {
        print("[Sync] Full sync starting…")
        await syncEvents(eventStore.events, kind: "todo")
        await syncEvents(eventStore.calendarEvents, kind: "calendar")
        await syncLogs(eventStore.calendarEventLogRecords)
        await syncFeedback(eventStore.calendarEventFeedbackRecords)
        await syncTodoLists(eventStore.todoLists)
        await syncEventTypes(eventTypeStore.templates)
        await syncSkills(skillStore.insights)
        print("[Sync] Full sync complete")
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
                print("[Sync] Deleted \(deletedIds.count) from \(table)")
            } catch {
                print("[Sync] Delete \(table) failed: \(error)")
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
                print("[Sync] \(table): \(succeeded) changed (of \(rows.count) total)")
            } else {
                print("[Sync] \(table): \(succeeded) synced, \(failed) failed (of \(rows.count) total)")
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
            "created_at": iso(e.createdAt),
            "updated_at": iso(Date()),
            "synced_at": iso(Date()),
        ]
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
            "template_answers": [:] as [String: Any],
            "timeline_items": [] as [Any],
            "created_at": iso(log.createdAt),
            "updated_at": iso(log.updatedAt),
            "synced_at": iso(Date()),
        ]
    }

    // MARK: - Sync: Feedback

    private func syncFeedback(_ records: [CalendarEventFeedbackRecord]) async {
        let rows = records.map { r -> [String: Any] in
            [
                "id": encodeOccurrenceKey(r.id),
                "user_id": userId,
                "event_id": r.eventID.uuidString,
                "base_series_event_id": r.baseSeriesEventID?.uuidString as Any? ?? NSNull(),
                "occurrence_date": iso(r.occurrenceDate),
                "effort": r.effort as Any? ?? NSNull(),
                "emotions": r.emotions,
                "behaviors": r.behaviors,
                "self_note": r.selfNote,
                "logs": [] as [Any],
                "created_at": iso(r.createdAt),
                "updated_at": iso(r.updatedAt),
                "synced_at": iso(Date()),
            ]
        }
        lastFeedbackHashes = await diffSync(
            table: "event_feedback",
            rows: rows,
            previousHashes: lastFeedbackHashes
        )
    }

    // MARK: - Sync: Todo Lists

    private func syncTodoLists(_ lists: [TodoList]) async {
        let rows = lists.map { l -> [String: Any] in
            [
                "id": l.id.uuidString,
                "user_id": userId,
                "title": l.title,
                "color_name": l.colorName,
                "created_at": iso(l.createdAt),
                "synced_at": iso(Date()),
            ]
        }
        lastTodoListHashes = await diffSync(
            table: "todo_lists",
            rows: rows,
            previousHashes: lastTodoListHashes
        )
    }

    // MARK: - Sync: Event Types

    private func syncEventTypes(_ templates: [EventTypeTemplate]) async {
        let rows = templates.map { t -> [String: Any] in
            [
                "id": t.id.uuidString,
                "user_id": userId,
                "title": t.title,
                "color_hex": t.colorHex,
                "updated_at": iso(Date()),
                "synced_at": iso(Date()),
            ]
        }
        lastEventTypeHashes = await diffSync(
            table: "event_types",
            rows: rows,
            previousHashes: lastEventTypeHashes
        )
    }

    // MARK: - Sync: Skills

    private func syncSkills(_ insights: [SkillInsight]) async {
        let rows = insights.map { s -> [String: Any] in
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
        lastSkillHashes = await diffSync(
            table: "skill_insights",
            rows: rows,
            previousHashes: lastSkillHashes
        )
    }

    // MARK: - Helpers

    /// Encode CalendarOccurrenceKey to a stable string ID for Supabase.
    private func encodeOccurrenceKey(_ key: CalendarOccurrenceKey) -> String {
        let dateStr = iso(key.occurrenceDate)
        let base = key.baseSeriesEventID?.uuidString ?? "none"
        return "\(key.kind.rawValue)|\(key.eventID.uuidString)|\(base)|\(dateStr)"
    }
}
