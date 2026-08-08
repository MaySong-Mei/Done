import XCTest
@testable import Done

/// Round-trip tests for the four `Event` fields that drift through Supabase
/// sync today (issues #38 + #45): `kind`, `absorbedIntoEventID`, `peopleIDs`,
/// `timerStartedAt`. Each test pushes an Event through `eventToRow`,
/// coerces the dict the way PostgREST would (via `JSONSerialization`), then
/// decodes back through `rowToEvent` and asserts equality.
@MainActor
final class SupabaseEventRowRoundTripTests: XCTestCase {

    // MARK: - Helpers

    /// Round-trip a row dict through JSONSerialization the same way PostgREST
    /// would on the wire: dict → JSON bytes → JSON object. Coerces native Swift
    /// types into their JSON-bridged equivalents so the reader sees the same
    /// shapes a real server response would deliver.
    private func coerceThroughJSON(_ row: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: row, options: [])
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    /// One round-trip: Event → row → JSON-coerced row → Event.
    /// Caller asserts on the restored Event.
    private func roundTrip(_ event: Event, kind: String = "calendar") throws -> Event {
        let service = SupabaseSyncService()
        let row = service.eventToRow(event, kind: kind)
        let coerced = try coerceThroughJSON(row)
        return try XCTUnwrap(SupabaseSyncService.rowToEvent(coerced))
    }

    /// Drop sub-second precision so ISO-string round-trip comparisons hold
    /// even when the formatter writes microseconds and the parser reads back
    /// at second granularity.
    private func truncatedToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    // MARK: - a) Fully-populated round-trip

    func testFullyPopulatedEventRoundTrip() throws {
        let parentID = UUID()
        let person1 = UUID()
        let person2 = UUID()
        let listID = UUID()
        let recurrenceParentID = UUID()
        let linkedCalID = UUID()
        let linkedTodoID = UUID()
        let baseSeriesID = UUID()

        // Truncate dates to the second to keep round-trip comparisons clean.
        // Sub-second precision is preserved by the writer's fractional ISO
        // format but the parser strips it; comparing at second resolution is
        // the documented behavior, not a regression.
        let start = truncatedToSecond(Date())
        let end = truncatedToSecond(Date(timeIntervalSinceNow: 3600))
        let deadline = truncatedToSecond(Date(timeIntervalSinceNow: 7200))
        let createdAt = truncatedToSecond(Date(timeIntervalSinceNow: -86400))
        let completeAt = truncatedToSecond(Date(timeIntervalSinceNow: -3600))
        let recurrenceInstanceDate = truncatedToSecond(Date(timeIntervalSinceNow: -7200))
        let recurrenceEndDate = truncatedToSecond(Date(timeIntervalSinceNow: 31_536_000))
        let exceptionDate = truncatedToSecond(Date(timeIntervalSinceNow: 86_400))
        let timerStart = truncatedToSecond(Date(timeIntervalSinceNow: -120))
        let interruptOccurrence = truncatedToSecond(Date(timeIntervalSinceNow: 1800))
        let interruptCreated = truncatedToSecond(Date(timeIntervalSinceNow: -60))

        let original = Event(
            title: "Full event \(UUID().uuidString)",
            note: "note body \(UUID().uuidString)",
            location: "loc \(UUID().uuidString)",
            timeRanges: [.init(start: start, end: end)],
            deadline: deadline,
            repeatUnit: .week,
            isAllDay: true,
            isDone: true,
            repeatInterval: 2,
            repeatEndType: .onDate,
            repeatEndDate: recurrenceEndDate,
            repeatEndCount: 5,
            priority: 7,
            status: .completed,
            createdAt: createdAt,
            completeAt: completeAt,
            tags: ["tag-a", "tag-b"],
            type: "work",
            kind: .todo,
            additionalTypes: ["focus", "review"],
            typeWeights: ["work": 0.6, "focus": 0.4],
            colorDepth: 0.75,
            recurrenceParentId: recurrenceParentID,
            recurrenceInstanceDate: recurrenceInstanceDate,
            recurrenceExceptionDates: [exceptionDate],
            timerStartedAt: timerStart,
            linkedCalendarEventId: linkedCalID,
            linkedTodoEventId: linkedTodoID,
            listID: listID,
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: parentID,
                baseSeriesEventID: baseSeriesID,
                occurrenceDate: interruptOccurrence,
                state: .embedded,
                createdAt: interruptCreated
            ),
            absorbedIntoEventID: parentID,
            wannaNotes: [.init(text: "wn", createdAt: truncatedToSecond(Date()))],
            peopleIDs: [person1, person2]
        )

        let restored = try roundTrip(original)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.note, original.note)
        XCTAssertEqual(restored.location, original.location)
        XCTAssertEqual(restored.timeRanges.count, 1)
        XCTAssertEqual(restored.timeRanges.first?.start, start)
        XCTAssertEqual(restored.timeRanges.first?.end, end)
        XCTAssertEqual(restored.deadline, deadline)
        XCTAssertEqual(restored.repeatUnit, .week)
        XCTAssertEqual(restored.isAllDay, true)
        XCTAssertEqual(restored.isDone, true)
        XCTAssertEqual(restored.repeatInterval, 2)
        XCTAssertEqual(restored.repeatEndType, .onDate)
        XCTAssertEqual(restored.repeatEndDate, recurrenceEndDate)
        XCTAssertEqual(restored.repeatEndCount, 5)
        XCTAssertEqual(restored.priority, 7)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.createdAt, createdAt)
        XCTAssertEqual(restored.completeAt, completeAt)
        XCTAssertEqual(restored.tags, ["tag-a", "tag-b"])
        XCTAssertEqual(restored.type, "work")
        // The four newly-synced fields.
        XCTAssertEqual(restored.kind, .todo)
        XCTAssertEqual(restored.timerStartedAt, timerStart)
        XCTAssertEqual(restored.absorbedIntoEventID, parentID)
        XCTAssertEqual(restored.peopleIDs, [person1, person2])
        XCTAssertEqual(restored.additionalTypes, ["focus", "review"])
        XCTAssertEqual(restored.typeWeights?["work"], 0.6)
        XCTAssertEqual(restored.typeWeights?["focus"], 0.4)
        XCTAssertEqual(restored.colorDepth, 0.75)
        XCTAssertEqual(restored.recurrenceParentId, recurrenceParentID)
        XCTAssertEqual(restored.recurrenceInstanceDate, recurrenceInstanceDate)
        XCTAssertEqual(restored.recurrenceExceptionDates, [exceptionDate])
        XCTAssertEqual(restored.linkedCalendarEventId, linkedCalID)
        XCTAssertEqual(restored.linkedTodoEventId, linkedTodoID)
        XCTAssertEqual(restored.listID, listID)
        XCTAssertEqual(restored.displayKind, .interrupt)
        XCTAssertEqual(restored.interruptRelation?.parentEventID, parentID)
        XCTAssertEqual(restored.interruptRelation?.baseSeriesEventID, baseSeriesID)
        XCTAssertEqual(restored.interruptRelation?.occurrenceDate, interruptOccurrence)
        XCTAssertEqual(restored.interruptRelation?.state, .embedded)
        XCTAssertEqual(restored.interruptRelation?.createdAt, interruptCreated)
        XCTAssertEqual(restored.wannaNotes?.count, 1)
        XCTAssertEqual(restored.wannaNotes?.first?.text, "wn")
    }

    // MARK: - a2) recurrence day-key identity across the wire (gh#127 review, findings 3 + PROBE Q8)

    /// Day keys ride the wire (`recurrence_exception_day_keys` /
    /// `recurrence_instance_day_key`, migration 014) and restore treats them
    /// as the identity — it must NEVER re-derive them from the lossy mirror
    /// dates when they exist. Both the frozen reference zone AND the device
    /// zone are pinned away from the mint zone here to prove neither is
    /// consulted: minted keys survive a cloud round trip bit-for-bit, in any
    /// zone, on every pull.
    func testRecurrenceDayKeysSurviveRestoreEastOfFrozenReferenceZone() throws {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "America/New_York")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }
        let priorDefaultTZ = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
        defer { NSTimeZone.default = priorDefaultTZ }

        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func cnDay(_ d: Int, hour: Int = 0) -> Date {
            shanghai.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))!
        }

        var series = Event(
            title: "Daily",
            timeRanges: [.init(start: cnDay(3, hour: 9), end: cnDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.appendRecurrenceException(onDay: cnDay(10), calendar: shanghai)
        XCTAssertEqual(series.recurrenceExceptionDayKeys, [20_260_810])

        // The row ships identity + mirror side by side.
        let row = SupabaseSyncService().eventToRow(series, kind: "calendar")
        XCTAssertEqual(row["recurrence_exception_day_keys"] as? [Int], [20_260_810],
                       "the minted key is ON the wire — restore has no reason to re-derive it")
        XCTAssertEqual((row["recurrence_exception_dates"] as? [String])?.count, 1,
                       "the legacy mirror dates still ride along as the rollback net")

        let restored = try roundTrip(series)
        XCTAssertEqual(restored.recurrenceExceptionDayKeys, [20_260_810],
                       "the wire key IS the restored identity — neither the frozen New York reference"
                       + " zone nor the Shanghai device zone may re-bucket it to 20260809")
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: restored, on: cnDay(10), calendar: shanghai),
                     "the suppression survives the cloud round trip")
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: restored, on: cnDay(11), calendar: shanghai))

        // The detached instance's day pointer takes the same trip on its own
        // column.
        let instance = Event(
            title: "Moved",
            timeRanges: [.init(start: cnDay(10, hour: 9), end: cnDay(10, hour: 10))],
            type: "Study",
            recurrenceParentId: series.id,
            recurrenceInstanceDate: shanghai.startOfDay(for: cnDay(10)),
            recurrenceInstanceDayKey: 20_260_810
        )
        let instanceRow = SupabaseSyncService().eventToRow(instance, kind: "calendar")
        XCTAssertEqual(instanceRow["recurrence_instance_day_key"] as? Int, 20_260_810)
        let restoredInstance = try roundTrip(instance)
        XCTAssertEqual(restoredInstance.recurrenceInstanceDayKey, 20_260_810,
                       "the instance day key survives the wire untouched")
        XCTAssertTrue(restoredInstance.recurrenceInstanceMatches(day: cnDay(10), calendar: shanghai))
    }

    /// PROBE Q8's amplifier, closed: the SAME restore repeated in a
    /// DIFFERENT time zone yields the same identity, because the key is
    /// read from the wire, not re-derived per pull. Before the columns, each
    /// pull re-reduced the mirror in whatever frame the device sat in — one
    /// travel-restore moved the detached day and the next save encoded the
    /// moved key as truth.
    func testRestoreIsIdempotentAcrossDeviceTimeZones() throws {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "America/New_York")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }
        let priorDefaultTZ = NSTimeZone.default
        defer { NSTimeZone.default = priorDefaultTZ }

        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        func apiaDay(_ d: Int, hour: Int = 0) -> Date {
            apia.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))!
        }

        var series = Event(
            title: "Daily",
            timeRanges: [.init(start: apiaDay(3, hour: 9), end: apiaDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.appendRecurrenceException(onDay: apiaDay(10), calendar: apia)

        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let restoredTraveling = try roundTrip(series)
        NSTimeZone.default = TimeZone(identifier: "Pacific/Apia")!
        let restoredHome = try roundTrip(series)

        XCTAssertEqual(restoredTraveling.recurrenceExceptionDayKeys, [20_260_810],
                       "a restore performed mid-trip must not move the detached day")
        XCTAssertEqual(restoredHome.recurrenceExceptionDayKeys,
                       restoredTraveling.recurrenceExceptionDayKeys,
                       "one wire row, one identity, in every zone")
    }

    /// Mixed-provenance guard: an old build's upsert rewrites
    /// `recurrence_exception_dates` while the day-keys column keeps its
    /// stale server-side value (PostgREST leaves absent columns untouched on
    /// conflict-update). A count mismatch marks the row and it degrades
    /// WHOLESALE to the deterministic legacy backfill — never a half-stale
    /// identity.
    func testStaleWireDayKeysDegradeWholesaleToLegacyBackfill() throws {
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "Pacific/Apia")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }

        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        func apiaDay(_ d: Int, hour: Int = 0) -> Date {
            apia.date(from: DateComponents(year: 2026, month: 8, day: d, hour: hour))!
        }

        var series = Event(
            title: "Daily",
            timeRanges: [.init(start: apiaDay(3, hour: 9), end: apiaDay(3, hour: 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        series.appendRecurrenceException(onDay: apiaDay(9), calendar: apia)
        series.appendRecurrenceException(onDay: apiaDay(10), calendar: apia)

        var row = SupabaseSyncService().eventToRow(series, kind: "calendar")
        // The old build rewrote the dates; the keys column kept one stale row.
        row["recurrence_exception_day_keys"] = [20_260_809]
        let coerced = try coerceThroughJSON(row)
        let restored = try XCTUnwrap(SupabaseSyncService.rowToEvent(coerced))

        XCTAssertEqual(restored.recurrenceExceptionDayKeys, [20_260_809, 20_260_810],
                       "count mismatch → the stale keys are discarded and BOTH days backfill from"
                       + " the mirror via the frozen reference calendar")
    }

    // MARK: - b) peopleIDs edge cases

    func testPeopleIDsArrayEdgeCases() throws {
        let base = Event(title: "people-edge")

        // nil case
        var nilEvent = base
        nilEvent.peopleIDs = nil
        let nilRestored = try roundTrip(nilEvent)
        XCTAssertNil(nilRestored.peopleIDs, "nil peopleIDs should stay nil")

        // empty case
        var emptyEvent = base
        emptyEvent.peopleIDs = []
        let emptyRestored = try roundTrip(emptyEvent)
        // Empty array round-trips as empty array (writer emits `[]`, reader
        // sees a non-NSNull array and decodes it to `[]`). The nil-vs-empty
        // distinction is preserved.
        XCTAssertEqual(emptyRestored.peopleIDs, [])

        // single
        let one = UUID()
        var singleEvent = base
        singleEvent.peopleIDs = [one]
        let singleRestored = try roundTrip(singleEvent)
        XCTAssertEqual(singleRestored.peopleIDs, [one])

        // multi
        let many = [UUID(), UUID(), UUID()]
        var manyEvent = base
        manyEvent.peopleIDs = many
        let manyRestored = try roundTrip(manyEvent)
        XCTAssertEqual(manyRestored.peopleIDs, many)
    }

    // MARK: - c) Kind round-trip

    func testKindRoundTrip() throws {
        // explicit .event
        var asEvent = Event(title: "an event")
        asEvent.kind = .event
        let restoredEvent = try roundTrip(asEvent)
        XCTAssertEqual(restoredEvent.kind, .event)

        // explicit .todo
        var asTodo = Event(title: "a todo")
        asTodo.kind = .todo
        let restoredTodo = try roundTrip(asTodo)
        XCTAssertEqual(restoredTodo.kind, .todo)

        // Legacy row (behavior_kind absent) defaults to .event.
        let baseEvent = Event(title: "legacy")
        let row = SupabaseSyncService().eventToRow(baseEvent, kind: "calendar")
        var legacyRow = try coerceThroughJSON(row)
        legacyRow.removeValue(forKey: "behavior_kind")
        let restoredLegacy = try XCTUnwrap(SupabaseSyncService.rowToEvent(legacyRow))
        XCTAssertEqual(restoredLegacy.kind, .event, "missing behavior_kind decodes as .event")
    }

    // MARK: - d) Absorbed parent/child round-trip

    func testAbsorbedIntoEventIDRoundTrip() throws {
        let parent = Event(title: "parent event")
        var child = Event(title: "absorbed todo")
        child.kind = .todo
        child.absorbedIntoEventID = parent.id

        let restoredParent = try roundTrip(parent)
        let restoredChild = try roundTrip(child)

        XCTAssertNil(restoredParent.absorbedIntoEventID, "parent has no absorption link")
        XCTAssertEqual(restoredChild.absorbedIntoEventID, parent.id)
        XCTAssertEqual(restoredChild.absorbedIntoEventID, restoredParent.id,
                       "child still points at the round-tripped parent")
        XCTAssertEqual(restoredChild.kind, .todo)
    }

    // MARK: - e) Legacy row missing all four new columns

    func testLegacyRowMissingNewColumns() throws {
        let base = Event(title: "legacy row")
        let fresh = SupabaseSyncService().eventToRow(base, kind: "calendar")
        var legacy = try coerceThroughJSON(fresh)
        legacy.removeValue(forKey: "behavior_kind")
        legacy.removeValue(forKey: "absorbed_into_event_id")
        legacy.removeValue(forKey: "people_ids")
        legacy.removeValue(forKey: "timer_started_at")

        let restored = try XCTUnwrap(SupabaseSyncService.rowToEvent(legacy))
        XCTAssertEqual(restored.kind, .event)
        XCTAssertNil(restored.absorbedIntoEventID)
        XCTAssertNil(restored.peopleIDs)
        XCTAssertNil(restored.timerStartedAt)
    }

    // MARK: - f) Dateless todo (empty timeRanges) round-trip — Todo stack

    /// A stack todo is `kind == .todo` with no time ranges at all. The row
    /// must carry `time_ranges` as an empty array (PostgREST requires
    /// uniform keys across batch rows), and restore must bring it back as
    /// an empty array — not nil, and not a fabricated range.
    func testDatelessTodoRoundTrip() throws {
        let deadline = truncatedToSecond(Date(timeIntervalSinceNow: 86_400))
        var todo = Event(title: "dateless stack todo")
        todo.kind = .todo
        todo.timeRanges = []
        todo.deadline = deadline

        let row = SupabaseSyncService().eventToRow(todo, kind: "calendar")
        let ranges = try XCTUnwrap(row["time_ranges"] as? [[String: String]],
                                   "time_ranges key must be present even when empty")
        XCTAssertTrue(ranges.isEmpty, "dateless todo serializes time_ranges as []")

        let restored = try roundTrip(todo)
        XCTAssertEqual(restored.timeRanges, [], "empty timeRanges survives the round-trip")
        XCTAssertEqual(restored.kind, .todo)
        XCTAssertEqual(restored.deadline, deadline)
        XCTAssertNil(restored.absorbedIntoEventID)
        XCTAssertFalse(restored.isDone)
    }

    /// A row missing the `time_ranges` key entirely (pre-schema or
    /// hand-edited rows) restores as an empty array rather than dropping
    /// the event.
    func testMissingTimeRangesKeyRestoresEmpty() throws {
        var todo = Event(title: "no ranges key")
        todo.kind = .todo
        let row = SupabaseSyncService().eventToRow(todo, kind: "calendar")
        var stripped = try coerceThroughJSON(row)
        stripped.removeValue(forKey: "time_ranges")

        let restored = try XCTUnwrap(SupabaseSyncService.rowToEvent(stripped))
        XCTAssertEqual(restored.timeRanges, [])
        XCTAssertEqual(restored.kind, .todo)
    }
}
