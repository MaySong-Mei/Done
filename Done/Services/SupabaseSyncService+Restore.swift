import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Sync"
)

// MARK: - Snapshot

/// All data fetched from Supabase during a restore, ready to merge into local stores.
struct RestoreSnapshot {
    var calendarEvents: [Event]
    var todoEvents: [Event]
    var logs: [CalendarEventLogRecord]
    var feedback: [CalendarEventFeedbackRecord]
    var todoLists: [TodoList]
    var eventTypes: [EventTypeTemplate]
    var skills: [SkillInsight]
    /// User preferences (`UserDefaults` snapshot) — nil when the user has no
    /// cloud-side settings row yet (fresh account).
    var settings: [String: Any]?
    /// Decoded `AgentPreferenceStore.rules` from the `agent_preferences` row.
    /// Nil when the user has no cloud-side row yet.
    var agentRules: [AgentPreferenceRule]?
    /// Decoded `AgentPreferenceStore.decisionHistory` from the same row.
    var agentDecisionHistory: [AgentDecisionRecord]?
    /// `TokenInferenceRepository`'s learned state (migration 011). All three
    /// slices live on the same `agent_preferences` row.
    var tokenDynamicHypotheses: [TokenDynamicHypothesisRecord]?
    var tokenMetaHypotheses: [TokenMetaHypothesisRecord]?
    var tokenProjections: [TokenOccurrenceProjectionRecord]?
    /// Raw JSON for the `conversations` jsonb column — we don't decode the
    /// typed `AgentConversation` array here because the sync layer doesn't
    /// depend on it directly; the AgentService consumer round-trips this
    /// blob back into UserDefaults under `agentConversations`.
    var agentConversationsBlob: Any?

    var totalCount: Int {
        calendarEvents.count + todoEvents.count + logs.count + feedback.count
            + todoLists.count + eventTypes.count + skills.count
            + (settings?.isEmpty == false ? 1 : 0)
            + ((agentRules?.isEmpty == false) || (agentDecisionHistory?.isEmpty == false) ? 1 : 0)
            + (agentConversationsBlob != nil ? 1 : 0)
    }

    var isEmpty: Bool { totalCount == 0 }

    static let empty = RestoreSnapshot(
        calendarEvents: [], todoEvents: [], logs: [], feedback: [],
        todoLists: [], eventTypes: [], skills: [],
        settings: nil as [String: Any]?,
        agentRules: nil as [AgentPreferenceRule]?,
        agentDecisionHistory: nil as [AgentDecisionRecord]?,
        tokenDynamicHypotheses: nil as [TokenDynamicHypothesisRecord]?,
        tokenMetaHypotheses: nil as [TokenMetaHypothesisRecord]?,
        tokenProjections: nil as [TokenOccurrenceProjectionRecord]?,
        agentConversationsBlob: nil as Any?
    )
}

// MARK: - Row reading helpers

// `RowReader`, `SupabaseDateParser`, and `decodeEmbeddedJSON` live in
// Sync/SupabaseEventRowCodec.swift (shared, UIKit-free) since the B-6
// extraction. The alias + shim keep the iOS-only decoders below verbatim.
private typealias RowReader = SupabaseEventRowCodec.RowReader

/// Decode an embedded JSON-object/array value back into a typed `Decodable`.
/// Used for `timeline_items` and `template_answers`, which the forward mapper
/// round-trips through `JSONEncoder` → `JSONSerialization.jsonObject`.
private func decodeEmbeddedJSON<T: Decodable>(_ value: Any?, as type: T.Type) -> T? {
    SupabaseEventRowCodec.decodeEmbeddedJSON(value, as: type)
}

// MARK: - Decoders

extension SupabaseSyncService {
    /// Decode a `fetchAllRawRows()` payload into typed model collections.
    /// Rows that fail to decode are skipped (logged at info level), so a partially
    /// corrupt server-side row never blocks the rest of the restore.
    static func decodeRestoreSnapshot(_ raw: [String: [[String: Any]]]) -> RestoreSnapshot {
        let allEvents = raw["events"] ?? []
        var calendar: [Event] = []
        var todo: [Event] = []
        var skippedEvents = 0
        for row in allEvents {
            let kind = row["kind"] as? String ?? ""
            guard let event = rowToEvent(row) else { skippedEvents += 1; continue }
            if kind == "calendar" {
                calendar.append(event)
            } else if kind == "todo" {
                todo.append(event)
            } else {
                skippedEvents += 1
            }
        }
        if skippedEvents > 0 {
            logger.warning("Skipped \(skippedEvents, privacy: .public) malformed event rows during restore")
        }

        // user_settings has at most one row per user.
        let settingsBlob: [String: Any]? = (raw["user_settings"] ?? [])
            .first
            .flatMap { $0["settings"] as? [String: Any] }

        // agent_preferences: one row, rules + decision_history as jsonb arrays
        // + (migration 011) the three TokenInferenceRepository slices.
        let prefsRow = (raw["agent_preferences"] ?? []).first
        let agentRules: [AgentPreferenceRule]? = decodeJSONArray(prefsRow?["rules"])
        let agentDecisions: [AgentDecisionRecord]? = decodeJSONArray(prefsRow?["decision_history"])
        let tokenDynamic: [TokenDynamicHypothesisRecord]? = decodeJSONArray(prefsRow?["token_dynamic_hypotheses"])
        let tokenMeta: [TokenMetaHypothesisRecord]? = decodeJSONArray(prefsRow?["token_meta_hypotheses"])
        let tokenProj: [TokenOccurrenceProjectionRecord]? = decodeJSONArray(prefsRow?["token_projections"])

        // agent_conversations: one row, conversations jsonb passed through raw
        // for the consumer (AgentService) to re-encode into its UserDefaults key.
        let conversationsRaw: Any? = (raw["agent_conversations"] ?? []).first?["conversations"]
        let conversationsBlob: Any?
        if let conversationsRaw, !(conversationsRaw is NSNull) {
            conversationsBlob = conversationsRaw
        } else {
            conversationsBlob = nil
        }

        return RestoreSnapshot(
            calendarEvents: calendar,
            todoEvents: todo,
            logs: (raw["event_logs"] ?? []).compactMap(rowToLog),
            feedback: (raw["event_feedback"] ?? []).compactMap(rowToFeedback),
            todoLists: (raw["todo_lists"] ?? []).compactMap(rowToTodoList),
            eventTypes: (raw["event_types"] ?? []).compactMap(rowToEventType),
            skills: (raw["skill_insights"] ?? []).compactMap(rowToSkill),
            settings: settingsBlob,
            agentRules: agentRules,
            agentDecisionHistory: agentDecisions,
            tokenDynamicHypotheses: tokenDynamic,
            tokenMetaHypotheses: tokenMeta,
            tokenProjections: tokenProj,
            agentConversationsBlob: conversationsBlob
        )
    }

    /// Decode a jsonb array column back into a typed Codable Swift array.
    /// Returns nil when the column is missing or malformed (caller treats as
    /// "no cloud value yet" rather than crashing on a partially-rolled-out
    /// schema).
    private static func decodeJSONArray<T: Decodable>(_ value: Any?) -> [T]? {
        SupabaseEventRowCodec.decodeJSONArray(value)
    }

    /// Convenience: fetch + decode in one call. Throws `RestoreError.notSignedIn`
    /// when there's no authenticated user.
    func fetchRestoreSnapshot() async throws -> RestoreSnapshot {
        let raw = try await fetchAllRawRows()
        return Self.decodeRestoreSnapshot(raw)
    }

    // MARK: Events

    /// Delegates to the shared codec (B-6 extraction); this wrapper keeps
    /// the historical `SupabaseSyncService.rowToEvent` call sites compiling.
    internal static func rowToEvent(_ row: [String: Any]) -> Event? {
        SupabaseEventRowCodec.rowToEvent(row)
    }

    // MARK: Logs

    fileprivate static func rowToLog(_ row: [String: Any]) -> CalendarEventLogRecord? {
        let r = RowReader(row: row)
        guard let idStr = r.string("id"),
              let eventID = r.uuid("event_id"),
              let occurrenceDate = r.date("occurrence_date"),
              let key = decodeOccurrenceKey(idStr, occurrenceDate: occurrenceDate)
        else { return nil }

        let completionStatus = r.string("completion_status").flatMap(EventLogCompletionStatus.init(rawValue:))

        let templateAnswers: [String: EventLogAnswerValue] = decodeEmbeddedJSON(
            r.object("template_answers"),
            as: [String: EventLogAnswerValue].self
        ) ?? [:]

        let timelineItems: [EventLogTimelineItem] = decodeEmbeddedJSON(
            r.array("timeline_items"),
            as: [EventLogTimelineItem].self
        ) ?? []

        return CalendarEventLogRecord(
            id: key,
            eventID: eventID,
            baseSeriesEventID: r.uuid("base_series_event_id"),
            occurrenceDate: occurrenceDate,
            suggestedTemplateID: r.string("suggested_template_id"),
            selectedTemplateID: r.string("selected_template_id"),
            completionStatus: completionStatus,
            actualDurationMinutes: r.int("actual_duration_minutes"),
            summary: r.string("summary") ?? "",
            note: r.string("note") ?? "",
            effort: r.int("effort"),
            emotions: r.stringArray("emotions") ?? [],
            behaviors: r.stringArray("behaviors") ?? [],
            templateAnswers: templateAnswers,
            timelineItems: timelineItems,
            createdAt: r.date("created_at") ?? Date(),
            updatedAt: r.date("updated_at") ?? Date()
        )
    }

    // MARK: Feedback

    fileprivate static func rowToFeedback(_ row: [String: Any]) -> CalendarEventFeedbackRecord? {
        let r = RowReader(row: row)
        guard let idStr = r.string("id"),
              let eventID = r.uuid("event_id"),
              let occurrenceDate = r.date("occurrence_date"),
              let key = decodeOccurrenceKey(idStr, occurrenceDate: occurrenceDate)
        else { return nil }

        let logs: [CalendarEventLogEntry] = decodeEmbeddedJSON(
            r.array("logs"),
            as: [CalendarEventLogEntry].self
        ) ?? []

        return CalendarEventFeedbackRecord(
            id: key,
            eventID: eventID,
            baseSeriesEventID: r.uuid("base_series_event_id"),
            occurrenceDate: occurrenceDate,
            effort: r.int("effort"),
            emotions: r.stringArray("emotions") ?? [],
            behaviors: r.stringArray("behaviors") ?? [],
            selfNote: r.string("self_note") ?? "",
            logs: logs,
            chatConversationID: r.uuid("chat_conversation_id"),
            createdAt: r.date("created_at") ?? Date(),
            updatedAt: r.date("updated_at") ?? Date()
        )
    }

    // MARK: Lists / Types / Skills

    fileprivate static func rowToTodoList(_ row: [String: Any]) -> TodoList? {
        let r = RowReader(row: row)
        guard let id = r.uuid("id"), let title = r.string("title") else { return nil }
        return TodoList(
            id: id,
            title: title,
            colorName: r.string("color_name") ?? "blue",
            createdAt: r.date("created_at") ?? Date()
        )
    }

    fileprivate static func rowToEventType(_ row: [String: Any]) -> EventTypeTemplate? {
        SupabaseEventRowCodec.rowToEventType(row)
    }

    fileprivate static func rowToSkill(_ row: [String: Any]) -> SkillInsight? {
        let r = RowReader(row: row)
        guard let id = r.uuid("id"), let date = r.date("date") else { return nil }
        return SkillInsight(
            id: id,
            skillName: r.string("skill_name") ?? "",
            points: r.double("points") ?? 0,
            date: date,
            eventTitle: r.string("event_title") ?? "",
            reasoning: r.string("reasoning") ?? ""
        )
    }

    // MARK: Occurrence key

    /// Inverse of `encodeOccurrenceKey` in SupabaseSyncService.swift.
    /// Body lives in `SupabaseEventRowCodec.decodeOccurrenceKey` (B-6
    /// extraction) — see the format documentation there.
    fileprivate static func decodeOccurrenceKey(
        _ encoded: String,
        occurrenceDate: Date
    ) -> CalendarOccurrenceKey? {
        SupabaseEventRowCodec.decodeOccurrenceKey(encoded, occurrenceDate: occurrenceDate)
    }
}
