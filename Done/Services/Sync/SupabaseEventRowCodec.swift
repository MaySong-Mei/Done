//
//  SupabaseEventRowCodec.swift
//  Done
//
//  Platform-neutral event row codec (gh#219 DoneMac plan, B-6). The
//  encode side (`hashableFields` / `eventToRow`) and the decode side
//  (`rowToEvent` / `rowToEventType` + the row-reading helpers) moved here
//  verbatim from SupabaseSyncService.swift / +Restore.swift so both app
//  targets share ONE codec — row hashes and decode behavior must stay
//  bit-identical across platforms (pinned by
//  DoneTests/SupabaseEventRowRoundTripTests.swift).
//
//  `SupabaseSyncService` keeps thin wrappers with the original method
//  names/signatures; the iOS-only restore orchestration stays in
//  SupabaseSyncService+Restore.swift and calls in here.
//

import Foundation

enum SupabaseEventRowCodec {

    // MARK: - Row reading helpers

    /// Typed accessors over the loose `[String: Any]` produced by `JSONSerialization`.
    /// Treats `NSNull` the same as a missing key.
    struct RowReader {
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
    enum SupabaseDateParser {
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
    static func decodeEmbeddedJSON<T: Decodable>(_ value: Any?, as type: T.Type) -> T? {
        guard let value, !(value is NSNull) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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

    // MARK: - Decode: Events

    static func rowToEvent(_ row: [String: Any]) -> Event? {
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

    // MARK: - Decode: Types

    static func rowToEventType(_ row: [String: Any]) -> EventTypeTemplate? {
        let r = RowReader(row: row)
        guard let id = r.uuid("id"), let title = r.string("title") else { return nil }
        return EventTypeTemplate(
            id: id,
            title: title,
            colorHex: r.string("color_hex") ?? "#8E8E93"
        )
    }

    // MARK: - Decode: Occurrence key

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
    static func decodeOccurrenceKey(
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

    // MARK: - Encode: Events

    /// The hashed portion of an event row — every field except the two
    /// always-now timestamps. Single source of truth shared by `eventToRow`
    /// (upload) and the hashing-only path (`eventToRowForHashing` on the
    /// service) so their hashes can never drift apart.
    static func hashableFields(
        _ e: Event,
        kind: String,
        userId: String,
        iso: ISO8601DateFormatter
    ) -> [String: Any] {
        // ALL keys must always be present (use NSNull for nil).
        // PostgREST requires uniform keys across batch rows.
        let ranges: [[String: String]] = e.timeRanges.map { r in
            ["start": iso.string(from: r.start), "end": iso.string(from: r.end)]
        }
        // The day-key identity ships BESIDE its legacy mirror dates
        // (`recurrence_exception_day_keys` / `recurrence_instance_day_key`,
        // migration 014): keys that exist must never be re-derived from the
        // lossy mirror on pull — re-derivation on every restore is what let
        // a tz change move a detached day permanently (gh#127 review
        // finding 3). The dates stay on the wire untouched as the rollback
        // net for pre-migration readers.
        let exDates: [String] = e.recurrenceExceptionDates.map { iso.string(from: $0) }

        var ir: Any = NSNull()
        if let rel = e.interruptRelation {
            ir = [
                "parentEventID": rel.parentEventID.uuidString,
                "baseSeriesEventID": rel.baseSeriesEventID?.uuidString as Any,
                "state": rel.state.rawValue,
                "occurrenceDate": iso.string(from: rel.occurrenceDate),
                "createdAt": iso.string(from: rel.createdAt),
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
            "deadline": e.deadline.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "complete_at": e.completeAt.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "repeat_unit": e.repeatUnit.rawValue,
            "repeat_interval": e.repeatInterval,
            "repeat_end_type": e.repeatEndType.rawValue,
            "repeat_end_date": e.repeatEndDate.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "repeat_end_count": e.repeatEndCount as Any? ?? NSNull(),
            "recurrence_parent_id": e.recurrenceParentId?.uuidString as Any? ?? NSNull(),
            "recurrence_instance_date": e.recurrenceInstanceDate.map { iso.string(from: $0) } as Any? ?? NSNull(),
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
            "timer_started_at": e.timerStartedAt.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "interrupt_relation": ir,
            "wanna_notes": wannaNotesPayload,
            "agentic_intake": agenticIntakePayload,
            "suggested_log_template_id": e.suggestedLogTemplateID as Any? ?? NSNull(),
            "suggested_log_template_confidence": e.suggestedLogTemplateConfidence as Any? ?? NSNull(),
            "suggested_log_template_updated_at": e.suggestedLogTemplateUpdatedAt.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "suggested_log_template_source": e.suggestedLogTemplateSource?.rawValue as Any? ?? NSNull(),
            "created_at": iso.string(from: e.createdAt),
        ]
    }

    /// Full upload payload for an event row, including the `updated_at` /
    /// `synced_at` timestamps the server persists — stamped from `now`
    /// (callers pass `Date()` to preserve the pre-extraction behavior).
    static func eventToRow(
        _ e: Event,
        kind: String,
        userId: String,
        now: Date,
        iso: ISO8601DateFormatter
    ) -> [String: Any] {
        var row = hashableFields(e, kind: kind, userId: userId, iso: iso)
        row["updated_at"] = iso.string(from: now)
        row["synced_at"] = iso.string(from: now)
        return row
    }

    /// Round-trip an Encodable through JSON so PostgREST sees an Array/Object
    /// instead of an opaque Encodable wrapper. Returns `NSNull()` for nil/empty
    /// so the surrounding row schema stays uniform across batches.
    /// (Internal, not private: `SupabaseSyncService`'s non-event row builders
    /// — agent_preferences — delegate here too.)
    static func encodeJSONOrNull<T: Encodable>(_ value: T?) -> Any {
        guard let value else { return NSNull() }
        if let arr = value as? [Any], arr.isEmpty { return NSNull() }
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return NSNull() }
        if let arr = decoded as? [Any], arr.isEmpty { return NSNull() }
        return decoded
    }
}
