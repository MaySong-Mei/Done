//
//  QA5SyncCodecRoundTripTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA round 5 — Mac-side codec round-trip fidelity (attack
//  surface 1). The iOS SupabaseEventRowRoundTripTests could not move to
//  this target (they construct SupabaseSyncService), so the Mac sync path
//  gets its own: full-field event -> eventToRow -> ACTUAL JSON wire trip
//  (JSONSerialization data -> parse, the same shape PostgREST hands back)
//  -> rowToEvent -> field-by-field compare. Any field lost here is a
//  cross-device data-loss channel, because MacSyncEngine pushes through
//  exactly this encoder and adopts through exactly this decoder.
//
//  Also pins the gh#127 day-key wire rule: keys that ride the wire ARE the
//  identity and must never be re-derived from their mirror dates on decode
//  — proven with fixtures whose keys deliberately DISAGREE with the mirror
//  dates, plus positive controls showing the fixtures discriminate.
//
//  Tests named QA5Finding_* PIN current behavior the QA report discusses;
//  they are green on purpose so the suite stays adjudicable.
//

import XCTest
@testable import Done

@MainActor
final class QA5SyncCodecRoundTripTests: XCTestCase {
    /// 2026-03-10 00:00:00 UTC — whole seconds, so ISO-with-fractional
    /// round trips are exact by construction (precision is not under test).
    private let t0 = Date(timeIntervalSince1970: 1_773_100_800)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The honest wire: serialize the row to JSON bytes and parse it back,
    /// exactly what happens between our upsert body and a later fetch's
    /// JSONSerialization.jsonObject. This catches NSNumber/Bool/Double
    /// bridging losses an in-memory dictionary pass would hide.
    private func wireTrip(_ row: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: row)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    private func uuid(_ tail: Int) -> UUID {
        UUID(uuidString: String(format: "AAAAAAAA-0000-0000-0000-%012d", tail))!
    }

    // MARK: - Fixtures

    /// Every wire field populated at once: multi-range, deadline, full
    /// recurrence family with explicit exception day keys, links, list,
    /// people, wanna notes, agentic intake, suggested-log family, tags,
    /// weights, colorDepth, todo behavior kind.
    private func fullFieldSeriesEvent() -> Event {
        let start1 = t0.addingTimeInterval(9 * 3600)
        let start2 = t0.addingTimeInterval(14 * 3600)
        let intake = AgenticIntakeRecord(
            rawText: "raw capture text",
            images: [AgenticIntakeImageRef(
                id: uuid(21), relativePath: "img/1.jpg", pixelWidth: 100,
                pixelHeight: 200, fileSizeBytes: 12_345, createdAt: t0
            )],
            source: .quickAdd,
            providerMetadata: AgenticProviderMetadata(
                provider: "anthropic", model: "m-1", usedVision: true, createdAt: t0
            ),
            warnings: ["w1"],
            createdAt: t0,
            processingPhase: .completed,
            processingUpdatedAt: t0.addingTimeInterval(60),
            failureMessage: nil
        )
        return Event(
            id: uuid(1),
            title: "Full field series",
            note: "note body",
            location: "Irvine",
            timeRanges: [
                .init(start: start1, end: start1.addingTimeInterval(1800)),
                .init(start: start2, end: start2.addingTimeInterval(3600)),
            ],
            deadline: t0.addingTimeInterval(7 * 86_400),
            repeatUnit: .week,
            isAllDay: false,
            isDone: true,
            repeatInterval: 2,
            // afterCount=5 / interval=2 are fixed points of
            // normalizedRecurrenceRule, so decode-side repair is identity.
            repeatEndType: .afterCount,
            repeatEndDate: nil,
            repeatEndCount: 5,
            priority: 3,
            status: .completed,
            createdAt: t0.addingTimeInterval(-86_400),
            completeAt: t0.addingTimeInterval(3600),
            tags: ["deep", "work"],
            type: "Deep Work",
            kind: .todo,
            additionalTypes: ["Gym"],
            typeWeights: ["Deep Work": 0.75, "Gym": 0.25],
            colorDepth: 0.62,
            recurrenceParentId: nil,
            recurrenceInstanceDate: nil,
            recurrenceInstanceDayKey: nil,
            recurrenceExceptionDates: [
                t0.addingTimeInterval(7 * 86_400),
                t0.addingTimeInterval(14 * 86_400),
            ],
            recurrenceExceptionDayKeys: [20_260_317, 20_260_324],
            timerStartedAt: t0.addingTimeInterval(120),
            linkedCalendarEventId: uuid(2),
            linkedTodoEventId: uuid(3),
            listID: uuid(4),
            agenticIntake: intake,
            suggestedLogTemplateID: "template-7",
            suggestedLogTemplateConfidence: 0.9,
            suggestedLogTemplateUpdatedAt: t0.addingTimeInterval(300),
            suggestedLogTemplateSource: .agent,
            displayKind: .regular,
            interruptRelation: nil,
            absorbedIntoEventID: uuid(5),
            wannaNotes: [Event.WannaNote(id: uuid(6), text: "wanna", createdAt: t0)],
            peopleIDs: [uuid(7), uuid(8)]
        )
    }

    /// A detached exception instance whose wire day key DELIBERATELY
    /// disagrees with what its mirror date derives to (20991231 vs a
    /// March-2026 key): if any decode path re-derives, equality breaks.
    private func detachedInstanceEvent() -> Event {
        let start = t0.addingTimeInterval(10 * 3600)
        return Event(
            id: uuid(11),
            title: "Detached exception instance",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
            isAllDay: true,
            createdAt: t0,
            type: "Series",
            kind: .event,
            recurrenceParentId: uuid(12),
            recurrenceInstanceDate: t0,
            recurrenceInstanceDayKey: 20_991_231,
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: uuid(12),
                baseSeriesEventID: uuid(13),
                occurrenceDate: t0,
                state: .detached,
                createdAt: t0
            )
        )
    }

    private func encodedRow(_ e: Event) -> [String: Any] {
        SupabaseEventRowCodec.eventToRow(
            e, kind: "calendar", userId: "user-1", now: t0, iso: Self.iso
        )
    }

    // MARK: - Full-field round trip

    func testFullFieldSeriesEventRoundTripsThroughTheWire() throws {
        let original = fullFieldSeriesEvent()
        let row = encodedRow(original)

        // Encode-side wire honesty for the gh#127 columns: both the key
        // identity AND its legacy mirror ship, in step.
        XCTAssertEqual(row["recurrence_exception_day_keys"] as? [Int],
                       [20_260_317, 20_260_324])
        XCTAssertEqual((row["recurrence_exception_dates"] as? [String])?.count, 2)

        let wired = try wireTrip(row)
        let decoded = try XCTUnwrap(SupabaseEventRowCodec.rowToEvent(wired),
                                    "a row we minted must decode")

        // Field-by-field first, so a failure names the lost channel.
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.note, original.note)
        XCTAssertEqual(decoded.location, original.location)
        XCTAssertEqual(decoded.timeRanges, original.timeRanges, "multi-range")
        XCTAssertEqual(decoded.deadline, original.deadline)
        XCTAssertEqual(decoded.repeatUnit, original.repeatUnit)
        XCTAssertEqual(decoded.isAllDay, original.isAllDay)
        XCTAssertEqual(decoded.isDone, original.isDone)
        XCTAssertEqual(decoded.repeatInterval, original.repeatInterval)
        XCTAssertEqual(decoded.repeatEndType, original.repeatEndType)
        XCTAssertEqual(decoded.repeatEndDate, original.repeatEndDate)
        XCTAssertEqual(decoded.repeatEndCount, original.repeatEndCount)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.completeAt, original.completeAt)
        XCTAssertEqual(decoded.tags, original.tags)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.kind, original.kind, "behavior_kind (todo)")
        XCTAssertEqual(decoded.additionalTypes, original.additionalTypes)
        XCTAssertEqual(decoded.typeWeights, original.typeWeights)
        XCTAssertEqual(decoded.colorDepth, original.colorDepth)
        XCTAssertEqual(decoded.recurrenceExceptionDates, original.recurrenceExceptionDates)
        XCTAssertEqual(decoded.recurrenceExceptionDayKeys, original.recurrenceExceptionDayKeys,
                       "exception day keys must ride the wire, not re-derive")
        XCTAssertEqual(decoded.timerStartedAt, original.timerStartedAt)
        XCTAssertEqual(decoded.linkedCalendarEventId, original.linkedCalendarEventId)
        XCTAssertEqual(decoded.linkedTodoEventId, original.linkedTodoEventId)
        XCTAssertEqual(decoded.listID, original.listID)
        XCTAssertEqual(decoded.agenticIntake, original.agenticIntake)
        XCTAssertEqual(decoded.suggestedLogTemplateID, original.suggestedLogTemplateID)
        XCTAssertEqual(decoded.suggestedLogTemplateConfidence, original.suggestedLogTemplateConfidence)
        XCTAssertEqual(decoded.suggestedLogTemplateUpdatedAt, original.suggestedLogTemplateUpdatedAt)
        XCTAssertEqual(decoded.suggestedLogTemplateSource, original.suggestedLogTemplateSource)
        XCTAssertEqual(decoded.displayKind, original.displayKind)
        XCTAssertEqual(decoded.absorbedIntoEventID, original.absorbedIntoEventID)
        XCTAssertEqual(decoded.wannaNotes, original.wannaNotes)
        XCTAssertEqual(decoded.peopleIDs, original.peopleIDs)

        // The whole value, so a NEW field added to Event without wire
        // support turns this test red the day it lands.
        XCTAssertEqual(decoded, original, "full-field Mac wire round trip must be lossless")
    }

    // MARK: - Detached instance + interrupt relation

    func testDetachedInstanceRoundTripsAndKeepsWireDayKey() throws {
        let original = detachedInstanceEvent()
        let row = encodedRow(original)
        XCTAssertEqual(row["recurrence_instance_day_key"] as? Int, 20_991_231)

        let decoded = try XCTUnwrap(SupabaseEventRowCodec.rowToEvent(try wireTrip(row)))
        XCTAssertEqual(decoded.recurrenceInstanceDayKey, 20_991_231,
                       "the wire key IS the identity even when the mirror date disagrees")
        XCTAssertEqual(decoded.recurrenceParentId, original.recurrenceParentId)
        XCTAssertEqual(decoded.recurrenceInstanceDate, original.recurrenceInstanceDate)
        XCTAssertEqual(decoded.interruptRelation, original.interruptRelation)
        XCTAssertEqual(decoded.displayKind, .interrupt)
        XCTAssertEqual(decoded, original)
    }

    /// POSITIVE CONTROL for the test above: strip the day-key column and
    /// the decoded key must move to the mirror-derived backfill — proof the
    /// disagreeing fixture actually discriminates re-derivation.
    func testControl_InstanceDayKeyColumnAbsenceFallsBackToMirror() throws {
        var wired = try wireTrip(encodedRow(detachedInstanceEvent()))
        wired["recurrence_instance_day_key"] = NSNull()
        let decoded = try XCTUnwrap(SupabaseEventRowCodec.rowToEvent(wired))
        XCTAssertNotEqual(decoded.recurrenceInstanceDayKey, 20_991_231,
                          "without the column the key must be backfilled, not remembered")
        XCTAssertNotNil(decoded.recurrenceInstanceDayKey,
                        "a mirror date must backfill a key")
    }

    // MARK: - Exception day keys: wire identity + wholesale degrade

    /// gh#127 shape, sharpest form: even NONSENSE keys that disagree with
    /// every mirror date must survive decode untouched, because minted keys
    /// are identity and re-derivation is exactly the bug that moved a
    /// detached day permanently after a tz change.
    func testExceptionDayKeysAreAuthoritativeEvenWhenDisagreeingWithMirrors() throws {
        var wired = try wireTrip(encodedRow(fullFieldSeriesEvent()))
        wired["recurrence_exception_day_keys"] = [20_990_101, 20_990_102]
        let decoded = try XCTUnwrap(SupabaseEventRowCodec.rowToEvent(wired))
        XCTAssertEqual(decoded.recurrenceExceptionDayKeys, [20_990_101, 20_990_102],
                       "keys on the wire are identity; mirror dates must not overrule them")
    }

    /// COUNT MISMATCH (the stale-server-column detection): keys out of step
    /// with the dates degrade WHOLESALE to the backfill — never a mixed
    /// per-element state, and never a silently truncated identity.
    func testExceptionDayKeyCountMismatchDegradesWholesaleToBackfill() throws {
        var wired = try wireTrip(encodedRow(fullFieldSeriesEvent()))
        wired["recurrence_exception_day_keys"] = [20_990_101]  // 1 key, 2 dates
        let decoded = try XCTUnwrap(SupabaseEventRowCodec.rowToEvent(wired))
        XCTAssertEqual(decoded.recurrenceExceptionDayKeys.count, 2,
                       "backfill must cover every exception date")
        XCTAssertFalse(decoded.recurrenceExceptionDayKeys.contains(20_990_101),
                       "a mismatched key column must be ignored wholesale, not merged")
    }

    // MARK: - Pinned canonicalization (report note, not a bug)

    /// QA5Finding: an EMPTY wannaNotes array canonicalizes to NSNull on the
    /// wire and decodes as nil — `[]` and `nil` collapse to one state after
    /// a sync round trip. Both platforms share this codec, so the collapse
    /// is at least consistent across devices; pinned here so a future
    /// consumer that distinguishes [] from nil finds this test first.
    func testQA5Finding_EmptyWannaNotesCanonicalizeToNilOnTheWire() throws {
        var e = fullFieldSeriesEvent()
        e.wannaNotes = []
        let row = encodedRow(e)
        XCTAssertTrue(row["wanna_notes"] is NSNull)
        let decoded = try XCTUnwrap(SupabaseEventRowCodec.rowToEvent(try wireTrip(row)))
        XCTAssertNil(decoded.wannaNotes)
    }
}
