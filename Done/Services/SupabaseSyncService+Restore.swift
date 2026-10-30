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
    /// The row's token columns are not read
    /// (`SupabaseSyncService.agentPreferencesTokenColumns`).
    var agentDecisionHistory: [AgentDecisionRecord]?
    /// Raw JSON for the `conversations` jsonb column — we don't decode the
    /// typed `AgentConversation` array here because the sync layer doesn't
    /// depend on it directly; the AgentService consumer round-trips this
    /// blob back into UserDefaults under `agentConversations`.
    var agentConversationsBlob: Any?
    /// The server's `seq` for every row the cloud carried, keyed by the
    /// baseline table label and the device's spelling of the id; the
    /// single-row tables key on the table with an empty id. What
    /// `markRestoreCompleted` writes as the baseline seq of a row the cloud
    /// knows (survey S6).
    var cloudSeqs: [SyncBaselineKey: Int64] = [:]
    /// Where this device's pull stood when the fetch began, and what that
    /// position belongs to. Set by `fetchRestoreSnapshot`; nil for a
    /// snapshot built any other way, which the apply neither checks nor
    /// rewinds the cursor for.
    var fetchMark: RestoreFetchMark?

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
        agentConversationsBlob: nil as Any?
    )
}

/// The pull cursor as it stood before a restore fetch read its first row,
/// together with what makes that number a position in THIS device's feed:
/// the account, the server epoch the cursor key records, and the count of
/// local-data erases.
///
/// Why the apply needs it (Lean, formal/restore-replay: the restore step
/// with the rewind, `reachInv_restore` and `baseCovers_restore`, resting on
/// `restore_fresh_of_read_above_cursor`): the fetch reads every row after
/// `cursor` was taken, so any version of a snapshot row newer than the one
/// the snapshot carries was written above `cursor`. The apply replays the snapshot's
/// (hash, seq) into the baseline — possibly older versions than the device
/// pulled during the user's review — and then moves the cursor back to
/// `cursor`, so the next pull re-delivers every such version and the
/// three-way compare settles each row against it. Without the move the
/// cursor stays past them and no pull ever brings them back.
///
/// When any part of that identity has changed by the time of the apply,
/// the position names nothing in the device's current feed, and the apply
/// is refused (`SupabaseSyncService.restoreApplyRefusal`).
struct RestoreFetchMark: Equatable {
    let userId: String
    let epoch: String?
    let eraseToken: Int
    /// Nil when the device had no cursor: a rewind then means a pull from
    /// the start of the feed.
    let cursor: Int64?
}

/// Why an apply was refused: the part of `RestoreFetchMark` that no longer
/// matches the device.
enum RestoreApplyRefusal: String {
    /// Another account (or none) is signed in.
    case account
    /// The cursor key records another server epoch than at the fetch: the
    /// server's history was reset under the device (design §6.6), the
    /// record is gone, or the fetch saw none and one has been recorded
    /// since (`restoreApplyRefusal`).
    case epoch
    /// Local data was erased.
    case erase
}

// MARK: - Row reading helpers

/// Typed accessors over the loose `[String: Any]` produced by `JSONSerialization`.
/// Treats `NSNull` the same as a missing key.
private struct RowReader {
    let row: [String: Any]

    func string(_ key: String) -> String? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        return v as? String
    }

    func uuid(_ key: String) -> UUID? {
        guard let s = string(key) else { return nil }
        return UUID(uuidString: s)
    }

    func date(_ key: String) -> Date? {
        guard let s = string(key) else { return nil }
        return SupabaseDateParser.parse(s)
    }

    func int(_ key: String) -> Int? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        return v as? Bool
    }

    func double(_ key: String) -> Double? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    func stringArray(_ key: String) -> [String]? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        return v as? [String]
    }

    /// All-or-nothing: a row whose array contains any non-integer element
    /// reads as absent, never as a silently truncated identity.
    func intArray(_ key: String) -> [Int]? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        if let ints = v as? [Int] { return ints }
        return (v as? [NSNumber])?.map { $0.intValue }
    }

    func object(_ key: String) -> [String: Any]? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        return v as? [String: Any]
    }

    func array(_ key: String) -> [Any]? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        return v as? [Any]
    }
}

/// PostgREST date strings can come back with or without fractional seconds depending
/// on the value the column was written with. Postgres `timestamptz` may also serialize
/// up to 6 fractional digits (microseconds), which `ISO8601DateFormatter` rejects —
/// without normalization that would silently drop rows on restore.
private enum SupabaseDateParser {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let microsecondRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\.(\d{3})\d+"#)

    static func parse(_ s: String) -> Date? {
        if let d = withFraction.date(from: s) { return d }
        if let d = withoutFraction.date(from: s) { return d }
        // Fallback for PostgREST's microsecond timestamps (e.g. ".123456+00").
        let normalized = truncateFractional(s)
        if normalized != s, let d = withFraction.date(from: normalized) { return d }
        return nil
    }

    /// Truncate any `.FFFFFF` sequence to `.FFF` so `ISO8601DateFormatter` can parse it.
    private static func truncateFractional(_ s: String) -> String {
        guard let regex = microsecondRegex else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: ".$1")
    }
}

/// Decode an embedded JSON-object/array value back into a typed `Decodable`.
/// Used for `timeline_items` and `template_answers`, which the forward mapper
/// round-trips through `JSONEncoder` → `JSONSerialization.jsonObject`.
private func decodeEmbeddedJSON<T: Decodable>(_ value: Any?, as type: T.Type) -> T? {
    guard let value, !(value is NSNull) else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: []) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
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

        // agent_preferences: one row, rules + decision_history as jsonb arrays.
        // Its token columns (migration 011) are left on the server.
        let prefsRow = (raw["agent_preferences"] ?? []).first
        let agentRules: [AgentPreferenceRule]? = decodeJSONArray(prefsRow?["rules"])
        let agentDecisions: [AgentDecisionRecord]? = decodeJSONArray(prefsRow?["decision_history"])
        if let prefsRow {
            let ignored = agentPreferencesTokenColumnsPresent(prefsRow)
            if !ignored.isEmpty {
                DiagnosticTrail.record("Sync", "restore.ignored_columns table=agent_preferences columns=\(ignored.joined(separator: ","))")
            }
        }

        // agent_conversations: one row, conversations jsonb passed through raw
        // for the consumer (AgentService) to re-encode into its UserDefaults key.
        let conversationsRaw: Any? = (raw["agent_conversations"] ?? []).first?["conversations"]
        let conversationsBlob: Any?
        if let conversationsRaw, !(conversationsRaw is NSNull) {
            conversationsBlob = conversationsRaw
        } else {
            conversationsBlob = nil
        }

        var snapshot = RestoreSnapshot(
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
            agentConversationsBlob: conversationsBlob
        )
        snapshot.cloudSeqs = cloudSeqs(raw)
        return snapshot
    }

    /// Key for a single-row table's entry in `RestoreSnapshot.cloudSeqs`.
    static func restoreSingletonKey(_ table: String) -> SyncBaselineKey {
        SyncBaselineKey(table: table, id: "")
    }

    /// Every carried row's seq. A row without a readable `seq` or `id` is
    /// left out, and so falls back to the legacy baseline shape.
    private static func cloudSeqs(_ raw: [String: [[String: Any]]]) -> [SyncBaselineKey: Int64] {
        var out: [SyncBaselineKey: Int64] = [:]
        for (table, rows) in raw {
            let singleton = isSingletonTable(table)
            for row in rows {
                guard let seq = (row["seq"] as? NSNumber)?.int64Value else { continue }
                if singleton {
                    out[restoreSingletonKey(table)] = seq
                    continue
                }
                guard let id = row["id"] as? String else { continue }
                let label = SyncBaselineStore.table(forFeedTable: table, kind: row["kind"] as? String)
                out[SyncBaselineKey(table: label, id: SyncBaselineKey.localId(id))] = seq
            }
        }
        return out
    }

    /// Decode a jsonb array column back into a typed Codable Swift array.
    /// Returns nil when the column is missing or malformed (caller treats as
    /// "no cloud value yet" rather than crashing on a partially-rolled-out
    /// schema).
    static func decodeJSONArray<T: Decodable>(_ value: Any?) -> [T]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let decoded = try? JSONDecoder().decode([T].self, from: data)
        else { return nil }
        return decoded
    }

    /// Convenience: fetch + decode in one call. Throws `RestoreError.notSignedIn`
    /// when there's no authenticated user.
    func fetchRestoreSnapshot() async throws -> RestoreSnapshot {
        // Taken before the first table is read, with no suspension between:
        // every row the fetch reads then comes from a server state at or
        // above this cursor.
        let mark = restoreFetchMark()
        let raw = try await fetchAllRawRows()
        var snapshot = Self.decodeRestoreSnapshot(raw)
        snapshot.fetchMark = mark
        // Kept for `markRestoreCompleted`, whose caller does not hand the
        // snapshot back.
        lastRestoreSnapshot = snapshot
        return snapshot
    }

    /// The device's pull position now, with its identity.
    func restoreFetchMark() -> RestoreFetchMark {
        RestoreFetchMark(userId: userId, epoch: cursor.epoch,
                         eraseToken: LocalDataEraseEpoch.capture(), cursor: cursor.value)
    }

    /// Nil when `mark` still names a position in this device's feed: the
    /// same account, no erase since, and exactly the epoch the cursor key
    /// recorded then — none if it had none. A fetch that saw no epoch is
    /// refused once any has been recorded: the first sighting
    /// (`SyncCursorStore.recordEpoch`) resets nothing, but a reset can
    /// follow it within the same review, and once that reset's catch-up has
    /// finished nothing on the device tells the two apart. Refusing both
    /// costs a second fetch only when the review straddled the session's
    /// first epoch read.
    func restoreApplyRefusal(_ mark: RestoreFetchMark) -> RestoreApplyRefusal? {
        if mark.userId != userId { return .account }
        if LocalDataEraseEpoch.isStale(mark.eraseToken) { return .erase }
        if mark.epoch != cursor.epoch { return .epoch }
        return nil
    }

    /// The restore's half of the cursor (see `RestoreFetchMark`): called by
    /// `markRestoreCompleted` once the baseline holds the replayed snapshot,
    /// in the same main-actor turn, and persists that baseline. Moves the
    /// cursor back to the fetch's starting position, never forward; when it
    /// did move, has the puller abandon any chain that began before the move
    /// and pull again at once. Only for a mark `restoreApplyRefusal` passes:
    /// `markRestoreCompleted` checks before it replays anything.
    func rewindCursorAfterRestore(to mark: RestoreFetchMark) {
        let from = cursor.value
        cursor.rewind(to: mark.cursor, baseline: baseline)
        let to = cursor.value
        DiagnosticTrail.record("Sync", "sync.cursor.restore_rewind from=\(from.map(String.init) ?? "none") to=\(to.map(String.init) ?? "none")")
        // Only a cursor that moved back owes a re-delivery. One that did not
        // move means nothing was pulled since the fetch began: the snapshot
        // replaced no version the device had pulled, and a chain in flight
        // asked for its pages from this same position.
        if to != from { inbound?.cursorWasRewound(reason: "restore") }
    }

    // MARK: Pending local deletes

    /// The rows of `snapshot` whose id this device deleted without the
    /// delete reaching the cloud. Such a delete is an id the baseline holds
    /// that the local table no longer does — whatever kept it from going up
    /// (uploads off, signed out, the undo window, a debounce not yet fired,
    /// a tombstone whose answer never came) — and it is exactly what the
    /// next flush tombstones (`pushTable`'s `deletedIds`) and what
    /// `unsyncedChanges` counts. A merge restore leaves these rows out
    /// (`EventStore.applyRestore`, `EventTypeTemplateStore.applyRestore`,
    /// `SkillInsightStore.applyRestore`), and the replay keeps their
    /// entries (`replayBaseline`), so the delete stays and is still sent.
    ///
    /// Reads the baseline and the stores as they are now. The apply reads
    /// it in the main-actor turn that runs the merge and the replay, so the
    /// three see one state.
    func pendingDeletes(in snapshot: RestoreSnapshot, eventStore: EventStore,
                        eventTypeStore: EventTypeTemplateStore, skillStore: SkillInsightStore) -> RestorePendingDeletes {
        var out = RestorePendingDeletes()
        out.todoEvents = pendingDeleteIds(table: "events", local: eventStore.events,
                                          cloud: snapshot.todoEvents, wireId: { $0.id.uuidString }, id: \.id)
        out.calendarEvents = pendingDeleteIds(table: "calendar_events", local: eventStore.rawCalendarEvents,
                                              cloud: snapshot.calendarEvents, wireId: { $0.id.uuidString }, id: \.id)
        out.logs = pendingDeleteIds(table: "event_logs", local: eventStore.calendarEventLogRecords,
                                    cloud: snapshot.logs, wireId: { self.encodeOccurrenceKey($0.id) }, id: \.id)
        out.feedback = pendingDeleteIds(table: "event_feedback", local: eventStore.calendarEventFeedbackRecords,
                                        cloud: snapshot.feedback, wireId: { self.encodeOccurrenceKey($0.id) }, id: \.id)
        out.todoLists = pendingDeleteIds(table: "todo_lists", local: eventStore.todoLists,
                                         cloud: snapshot.todoLists, wireId: { $0.id.uuidString }, id: \.id)
        out.eventTypes = pendingDeleteIds(table: "event_types", local: eventTypeStore.templates,
                                          cloud: snapshot.eventTypes, wireId: { $0.id.uuidString }, id: \.id)
        out.skills = pendingDeleteIds(table: "skill_insights", local: skillStore.insights,
                                      cloud: snapshot.skills, wireId: { $0.id.uuidString }, id: \.id)
        return out
    }

    /// One table of `pendingDeletes`: the cloud rows whose id, spelled as
    /// the row projection spells it (`wireId`, the baseline's key), is in
    /// the baseline and not among the local rows.
    private func pendingDeleteIds<Row, ID: Hashable>(table: String, local: [Row], cloud: [Row],
                                                     wireId: (Row) -> String, id: KeyPath<Row, ID>) -> Set<ID> {
        let entries = baseline.entries(table: table)
        guard !entries.isEmpty, !cloud.isEmpty else { return [] }
        var deleted = Set(entries.keys)
        for row in local { deleted.remove(wireId(row)) }
        guard !deleted.isEmpty else { return [] }
        var out = Set<ID>()
        for row in cloud where deleted.contains(wireId(row)) { out.insert(row[keyPath: id]) }
        return out
    }

    // MARK: Events

    internal static func rowToEvent(_ row: [String: Any]) -> Event? {
        let r = RowReader(row: row)
        guard let id = r.uuid("id") else { return nil }

        let timeRanges: [Event.TimeRange] = (r.array("time_ranges") as? [[String: Any]] ?? []).compactMap { sub in
            let sr = RowReader(row: sub)
            guard let start = sr.date("start"), let end = sr.date("end") else { return nil }
            return Event.TimeRange(start: start, end: end)
        }

        // Day keys ride the wire (`recurrence_exception_day_keys` /
        // `recurrence_instance_day_key`, migration 014): when present and in
        // step with the mirror dates they ARE the identity — no re-derivation
        // on pull, so a device's minted keys survive any number of restores
        // in any time zone (gh#127 review finding 3: per-pull backfill made
        // one tz change move a detached day permanently). A row without them
        // — a pre-migration snapshot, or an old build's upsert that rewrote
        // the dates while the keys column kept its stale server-side value
        // (detected by the COUNT mismatch below; PostgREST leaves absent
        // columns untouched on conflict-update) — degrades wholesale to the
        // ONE precedence rule inside the memberwise `Event` init
        // (`Event.resolvedRecurrenceExceptionDayKeys`): a deterministic
        // frozen-reference-calendar backfill, same honest limitation as local
        // legacy decode.
        let exDates: [Date] = (r.stringArray("recurrence_exception_dates") ?? [])
            .compactMap(SupabaseDateParser.parse)
        let exDayKeys: [Int]? = r.intArray("recurrence_exception_day_keys")
            .flatMap { $0.count == exDates.count ? $0 : nil }

        let interruptRelation: EventInterruptRelation? = {
            guard let irRow = r.object("interrupt_relation") else { return nil }
            let ir = RowReader(row: irRow)
            guard let parentID = ir.uuid("parentEventID"),
                  let occDate = ir.date("occurrenceDate"),
                  let stateRaw = ir.string("state"),
                  let state = EventInterruptRelationState(rawValue: stateRaw)
            else { return nil }
            return EventInterruptRelation(
                parentEventID: parentID,
                baseSeriesEventID: ir.uuid("baseSeriesEventID"),
                occurrenceDate: occDate,
                state: state,
                createdAt: ir.date("createdAt") ?? Date()
            )
        }()

        let typeWeights: [String: Double]? = {
            guard let obj = r.object("type_weights") else { return nil }
            var out: [String: Double] = [:]
            for (k, v) in obj {
                if let d = v as? Double { out[k] = d }
                else if let i = v as? Int { out[k] = Double(i) }
            }
            return out.isEmpty ? nil : out
        }()

        let wannaNotes: [Event.WannaNote]? = decodeEmbeddedJSON(
            r.array("wanna_notes"),
            as: [Event.WannaNote].self
        )
        let agenticIntake: AgenticIntakeRecord? = decodeEmbeddedJSON(
            r.object("agentic_intake"),
            as: AgenticIntakeRecord.self
        )
        let suggestedLogTemplateSource: SuggestedLogTemplateSource? = r.string("suggested_log_template_source")
            .flatMap(SuggestedLogTemplateSource.init(rawValue:))

        let kind: Event.Kind = r.string("behavior_kind").flatMap(Event.Kind.init(rawValue:)) ?? .event
        let peopleIDs: [UUID]? = r.stringArray("people_ids").map { $0.compactMap(UUID.init(uuidString:)) }

        var event = Event(
            id: id,
            title: r.string("title") ?? "",
            note: r.string("note") ?? "",
            location: r.string("location") ?? "",
            timeRanges: timeRanges,
            deadline: r.date("deadline"),
            repeatUnit: r.string("repeat_unit").flatMap(Event.RepeatUnit.init(rawValue:)) ?? .none,
            isAllDay: r.bool("is_all_day") ?? false,
            isDone: r.bool("is_done") ?? false,
            repeatInterval: r.int("repeat_interval") ?? 1,
            repeatEndType: r.string("repeat_end_type").flatMap(Event.RepeatEndType.init(rawValue:)) ?? .none,
            repeatEndDate: r.date("repeat_end_date"),
            repeatEndCount: r.int("repeat_end_count"),
            priority: r.int("priority") ?? 0,
            status: r.string("status").flatMap(Event.Status.init(rawValue:)) ?? .active,
            createdAt: r.date("created_at") ?? Date(),
            completeAt: r.date("complete_at"),
            tags: r.stringArray("tags") ?? [],
            type: r.string("type") ?? "",
            kind: kind,
            additionalTypes: r.stringArray("additional_types"),
            typeWeights: typeWeights,
            colorDepth: r.double("color_depth") ?? 0,
            recurrenceParentId: r.uuid("recurrence_parent_id"),
            recurrenceInstanceDate: r.date("recurrence_instance_date"),
            recurrenceInstanceDayKey: r.int("recurrence_instance_day_key"),
            recurrenceExceptionDates: exDates,
            recurrenceExceptionDayKeys: exDayKeys,
            timerStartedAt: r.date("timer_started_at"),
            linkedCalendarEventId: r.uuid("linked_calendar_event_id"),
            linkedTodoEventId: r.uuid("linked_todo_event_id"),
            listID: r.uuid("list_id"),
            displayKind: r.string("display_kind").flatMap(EventDisplayKind.init(rawValue:)) ?? .regular,
            interruptRelation: interruptRelation,
            absorbedIntoEventID: r.uuid("absorbed_into_event_id"),
            wannaNotes: wannaNotes,
            peopleIDs: peopleIDs
        )
        // `Event.init` doesn't expose every stored field as a parameter
        // (agentic intake + suggested log template are populated by other
        // call sites post-construction). Mirror that by mutating after.
        event.agenticIntake = agenticIntake
        event.suggestedLogTemplateID = r.string("suggested_log_template_id")
        event.suggestedLogTemplateConfidence = r.double("suggested_log_template_confidence")
        event.suggestedLogTemplateUpdatedAt = r.date("suggested_log_template_updated_at")
        event.suggestedLogTemplateSource = suggestedLogTemplateSource
        // Design §10.5 (i): the domino anchor another device wrote comes
        // in with the row; the next push here moves it only by what is left.
        event.dominoAnchor = r.date("domino_anchor")
        // The memberwise `Event(...)` above bypasses `Event.init(from:)`, so
        // repair a value-less / degenerate recurrence rule here too — a null
        // `repeat_end_count` column with `.afterCount` would otherwise render
        // forever. Fails closed to the seed — see `normalizedRecurrenceRule`.
        let normalizedRule = Event.normalizedRecurrenceRule(
            interval: event.repeatInterval,
            endType: event.repeatEndType,
            endDate: event.repeatEndDate,
            endCount: event.repeatEndCount,
            seriesStart: event.timeRanges.first?.start
        )
        event.repeatInterval = normalizedRule.interval
        event.repeatEndType = normalizedRule.endType
        event.repeatEndDate = normalizedRule.endDate
        event.repeatEndCount = normalizedRule.endCount
        return event
    }

    // MARK: Logs

    static func rowToLog(_ row: [String: Any]) -> CalendarEventLogRecord? {
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

    static func rowToFeedback(_ row: [String: Any]) -> CalendarEventFeedbackRecord? {
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

    static func rowToTodoList(_ row: [String: Any]) -> TodoList? {
        let r = RowReader(row: row)
        guard let id = r.uuid("id"), let title = r.string("title") else { return nil }
        return TodoList(
            id: id,
            title: title,
            colorName: r.string("color_name") ?? "blue",
            createdAt: r.date("created_at") ?? Date()
        )
    }

    static func rowToEventType(_ row: [String: Any]) -> EventTypeTemplate? {
        let r = RowReader(row: row)
        guard let id = r.uuid("id"), let title = r.string("title") else { return nil }
        return EventTypeTemplate(
            id: id,
            title: title,
            colorHex: r.string("color_hex") ?? "#8E8E93"
        )
    }

    /// A row's `updated_at`, for the event_types namesake rule
    /// (`SyncEventTypeWinners`, gh#257). Nil when absent or unparseable.
    static func rowUpdatedAt(_ row: [String: Any]) -> Date? {
        RowReader(row: row).date("updated_at")
    }

    static func rowToSkill(_ row: [String: Any]) -> SkillInsight? {
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

    /// True for an id in the date-bearing layout `encodeOccurrenceKey` wrote
    /// before issue #26 (`<kind>|<eventID>|<base|"none">|<isoDate>`), i.e.
    /// an id `decodeOccurrenceKey` accepts but `encodeOccurrenceKey` never
    /// produces today. Such a row and the current-format row of the same key
    /// are two server rows for one record.
    static func isLegacyOccurrenceKeyId(_ encoded: String) -> Bool {
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let kind = CalendarOccurrenceKey.Kind(rawValue: String(parts[0])),
              UUID(uuidString: String(parts[1])) != nil
        else { return false }
        switch kind {
        case .singleEvent:
            return parts.count > 2
        case .seriesOccurrence:
            return parts.count == 4 && Int(parts[3]) == nil
                && SupabaseDateParser.parse(String(parts[3])) != nil
        }
    }

    /// Inverse of `encodeOccurrenceKey` in SupabaseSyncService.swift. Handles
    /// both the current identity-only format and the legacy date-bearing one,
    /// so older cloud rows still round-trip until a normal sync re-keys them
    /// (issue #26):
    ///   - single (new):    `single|<eventID>`
    ///   - series (new):    `seriesOccurrence|<eventID>|<base|"none">|<dayKey:Int>`
    ///   - legacy (either): `<kind>|<eventID>|<base|"none">|<isoDate>`
    ///
    /// `occurrenceDate` is the authoritative `occurrence_date` column value. It
    /// fills the key's non-identity date field so the record reads back
    /// correctly regardless of what (if anything) the ID itself encodes.
    fileprivate static func decodeOccurrenceKey(
        _ encoded: String,
        occurrenceDate: Date
    ) -> CalendarOccurrenceKey? {
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let kind = CalendarOccurrenceKey.Kind(rawValue: String(parts[0])),
              let eventID = UUID(uuidString: String(parts[1]))
        else { return nil }

        func base(at index: Int) -> UUID? {
            guard parts.count > index else { return nil }
            let s = String(parts[index])
            return s == "none" ? nil : UUID(uuidString: s)
        }

        switch kind {
        case .singleEvent:
            // Identity is eventID only; dayKey/occurrenceDate are non-identity.
            // Derive dayKey from the authoritative column date. (Legacy 4-part
            // single rows land here too — their date part is simply ignored.)
            return CalendarOccurrenceKey(
                eventID: eventID,
                baseSeriesEventID: base(at: 2),
                occurrenceDate: occurrenceDate,
                kind: .singleEvent,
                dayKey: CalendarOccurrenceKey.dayKey(from: occurrenceDate)
            )
        case .seriesOccurrence:
            guard parts.count == 4 else { return nil }
            // The 4th field disambiguates the format: an integer is the new
            // tz-stable dayKey; an ISO date is a legacy row, so derive dayKey
            // from it to match the identity the original write produced.
            let dayKey: Int
            if let intDay = Int(parts[3]) {
                dayKey = intDay
            } else if let legacyDate = SupabaseDateParser.parse(String(parts[3])) {
                dayKey = CalendarOccurrenceKey.dayKey(from: legacyDate)
            } else {
                return nil
            }
            return CalendarOccurrenceKey(
                eventID: eventID,
                baseSeriesEventID: base(at: 2),
                occurrenceDate: occurrenceDate,
                kind: .seriesOccurrence,
                dayKey: dayKey
            )
        }
    }
}
