import XCTest
@testable import Done

/// Randomized property coverage for the `eventToRow` <-> `rowToEvent` sync
/// seam (gh#227 slice 2). The original season survey judged this seam
/// "better as property tests than theorems" — honored here as such (the
/// Lean project stays untouched). The existing `SupabaseEventRowRoundTripTests`
/// is entirely example-based; this is the first randomized coverage.
///
/// Oracle: `Event`'s auto-synthesized `Equatable` (all 43 stored properties,
/// including the recurrence-key family). The generator builds ALREADY-
/// NORMALIZED Events and uses the CONSTRUCTED Event as the expectation, so
/// the round trip's own decode-side normalization (`normalizedRecurrenceRule`,
/// day-key resolution) is a no-op on a clean input and equality is a valid
/// whole-object check. The known-lossy shapes (empty `wannaNotes`/`typeWeights`
/// collapsing to nil, sub-second date precision) are deliberately kept out of
/// the generator and pinned SEPARATELY as documented divergences below.
@MainActor
final class SupabaseRoundTripPropertyTests: XCTestCase {

    // Deterministic LCG — no wall clock, no system RNG.
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 17
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
        mutating func bool() -> Bool { next() & 1 == 0 }
        mutating func prob(_ p: Int) -> Bool { int(100) < p }
        /// A whole-second date within ~±2 years of a fixed epoch — second
        /// granularity dodges the seam's millisecond-write / second-read
        /// precision loss (pinned separately).
        mutating func date() -> Date {
            let base = 1_780_000_000
            return Date(timeIntervalSince1970: TimeInterval(base + int(126_144_000) - 63_072_000))
        }
        mutating func uuid() -> UUID { UUID() }
        mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
        mutating func word() -> String { pick(["Study", "Work", "Gym", "Read", "Rest", ""]) }
    }

    private func coerceThroughJSON(_ row: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: row, options: [])
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    private func roundTrip(_ event: Event, kind: String) throws -> Event {
        let service = SupabaseSyncService()
        let row = service.eventToRow(event, kind: kind)
        let coerced = try coerceThroughJSON(row)
        return try XCTUnwrap(SupabaseSyncService.rowToEvent(coerced))
    }

    /// Build a NORMALIZED random Event honoring the seam's invariants
    /// (§5 of the exploration): recurrence rule already valid, empty
    /// collections kept out of the collapse-prone fields, whole-second
    /// dates, day-key family left to the init to resolve.
    private func makeEvent(_ r: inout RNG) -> (event: Event, kind: String) {
        let isTodo = r.bool()
        let kind: Event.Kind = isTodo ? .todo : .event

        // timeRanges: a .todo may be dateless; a .event carries >= 1 range.
        var ranges: [Event.TimeRange] = []
        let rangeCount = isTodo ? (r.prob(40) ? 0 : 1 + r.int(2)) : 1 + r.int(3)
        for _ in 0..<rangeCount {
            let start = r.date()
            ranges.append(Event.TimeRange(
                start: start, end: start.addingTimeInterval(TimeInterval(900 * (1 + r.int(32))))))
        }

        // Recurrence: mostly none; when present, already normalized.
        var repeatUnit: Event.RepeatUnit = .none
        var repeatEndType: Event.RepeatEndType = .none
        var repeatEndDate: Date? = nil
        var repeatEndCount: Int? = nil
        var interval = 1
        if !ranges.isEmpty && r.prob(45) {
            repeatUnit = r.pick([.day, .week, .month, .year])
            interval = 1 + r.int(4)                       // >= 1
            switch r.int(3) {
            case 0: repeatEndType = .none
            case 1:
                repeatEndType = .afterCount
                repeatEndCount = 1 + r.int(10)            // >= 1
            default:
                repeatEndType = .onDate
                // end date at or after series start (avoid the zombie shape)
                repeatEndDate = ranges[0].start.addingTimeInterval(TimeInterval(86_400 * (1 + r.int(60))))
            }
        }

        // Optional scalar/reference fields.
        let deadline: Date? = r.prob(40) ? r.date() : nil
        let completeAt: Date? = r.prob(30) ? r.date() : nil
        let timerStartedAt: Date? = (!isTodo && r.prob(15)) ? r.date() : nil
        let status: Event.Status = r.pick([.active, .completed, .archived])
        let displayKind: EventDisplayKind = r.pick([.regular, .interrupt])
        let absorbed: UUID? = (isTodo && r.prob(20)) ? r.uuid() : nil

        // Arrays that PRESERVE nil-vs-empty (safe to generate any shape).
        let tags: [String] = r.prob(30) ? [] : (0..<r.int(3)).map { _ in var rr = r; return rr.word() }
        let additional: [String]? = r.prob(50) ? nil : (r.prob(30) ? [] : [r.word()])
        let peopleIDs: [UUID]? = {
            switch r.int(4) { case 0: return nil; case 1: return []; default: return (0..<r.int(3)).map { _ in UUID() } }
        }()

        // typeWeights: NON-empty when present (empty collapses to nil — pinned separately).
        var typeWeights: [String: Double]? = nil
        if r.prob(30) {
            typeWeights = ["Study": Double(r.int(10)) / 2.0, "Work": Double(r.int(10)) / 2.0]
        }
        // wannaNotes: NON-empty when present (empty collapses to nil).
        var wannaNotes: [Event.WannaNote]? = nil
        if r.prob(20) {
            wannaNotes = [Event.WannaNote(text: r.word().isEmpty ? "n" : r.word())]
        }

        var interruptRelation: EventInterruptRelation? = nil
        if displayKind == .interrupt {
            interruptRelation = EventInterruptRelation(
                parentEventID: UUID(),
                baseSeriesEventID: r.prob(50) ? UUID() : nil,
                occurrenceDate: r.date(),
                state: r.pick([.detached, .embedded, .orphaned]),
                createdAt: r.date()
            )
        }

        // gh#227 QA gap-close: the five fields the first generator left
        // nil-only had NO round-trip coverage anywhere (a dropped mapping
        // was invisible). Exercise them, plus the recurrenceInstance pair
        // the example sibling covered only at fixed values. Whole-second
        // dates throughout to stay off the ms-precision path.
        var agenticIntake: AgenticIntakeRecord? = nil
        if r.prob(25) {
            agenticIntake = AgenticIntakeRecord(
                rawText: r.word().isEmpty ? "raw" : r.word(),
                images: [],
                source: r.pick([.quickAdd, .dragCreate, .classicFallback]),
                providerMetadata: nil,
                warnings: r.prob(50) ? [] : ["w"],
                createdAt: r.date(),
                processingPhase: r.pick([.queued, .analyzing, .completed, .failed]),
                processingUpdatedAt: r.date(),
                failureMessage: r.prob(50) ? nil : "fail"
            )
        }
        let hasTemplate = r.prob(30)
        let sugID: String? = hasTemplate ? "tmpl-\(r.int(1000))" : nil
        let sugConf: Double? = hasTemplate ? Double(r.int(11)) / 10.0 : nil
        let sugUpdated: Date? = hasTemplate ? r.date() : nil
        let sugSource: SuggestedLogTemplateSource? = hasTemplate
            ? r.pick([.agent, .heuristic, .manualFallback]) : nil
        let hasInstance = r.prob(15)
        let instanceDate: Date? = hasInstance ? r.date() : nil
        let instanceDayKey: Int? = hasInstance
            ? (20260000 + 100 * (1 + r.int(12)) + 1 + r.int(28)) : nil

        let event = Event(
            id: UUID(),
            title: r.word().isEmpty ? "untitled" : r.word(),
            note: r.prob(40) ? "note" : "",
            location: r.prob(20) ? "loc" : "",
            timeRanges: ranges,
            deadline: deadline,
            repeatUnit: repeatUnit,
            isAllDay: r.prob(20),
            isDone: r.bool(),
            repeatInterval: interval,
            repeatEndType: repeatEndType,
            repeatEndDate: repeatEndDate,
            repeatEndCount: repeatEndCount,
            priority: r.int(3),
            status: status,
            createdAt: r.date(),
            completeAt: completeAt,
            tags: tags,
            type: r.word().isEmpty ? "General" : r.word(),
            kind: kind,
            additionalTypes: additional,
            typeWeights: typeWeights,
            colorDepth: Double(r.int(11)) / 10.0,
            recurrenceParentId: r.prob(15) ? UUID() : nil,
            recurrenceInstanceDate: instanceDate,
            recurrenceInstanceDayKey: instanceDayKey,
            recurrenceExceptionDates: [],
            recurrenceExceptionDayKeys: [],
            timerStartedAt: timerStartedAt,
            linkedCalendarEventId: r.prob(15) ? UUID() : nil,
            linkedTodoEventId: r.prob(15) ? UUID() : nil,
            listID: r.prob(20) ? UUID() : nil,
            agenticIntake: agenticIntake,
            suggestedLogTemplateID: sugID,
            suggestedLogTemplateConfidence: sugConf,
            suggestedLogTemplateUpdatedAt: sugUpdated,
            suggestedLogTemplateSource: sugSource,
            displayKind: displayKind,
            interruptRelation: interruptRelation,
            absorbedIntoEventID: absorbed,
            wannaNotes: wannaNotes,
            peopleIDs: peopleIDs
        )
        return (event, isTodo ? "todo" : "calendar")
    }

    /// The headline property: a clean, normalized Event survives the sync
    /// round trip byte-for-byte. 500 seeded trials.
    func testCleanEventRoundTripsToItself() throws {
        var r = RNG(state: 0x5117_0001)
        for trial in 0..<500 {
            let (event, kind) = makeEvent(&r)
            let restored = try roundTrip(event, kind: kind)
            XCTAssertEqual(restored, event, "trial \(trial): round trip diverged")
        }
    }

    /// A recurring series with resolved exception day-keys survives — the
    /// gh#127 family the projection seasons fought over. Exceptions are added
    /// through the production seam so keys and mirror dates stay parallel.
    func testRecurringSeriesWithExceptionsRoundTrips() throws {
        var r = RNG(state: 0x5117_0002)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for trial in 0..<200 {
            let start = r.date()
            var event = Event(
                id: UUID(),
                title: "Series",
                timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(3600))],
                repeatUnit: r.pick([.day, .week]),
                repeatInterval: 1 + r.int(3),
                createdAt: start,   // whole-second oracle
                type: "Study"
            )
            // Add 0-3 exceptions through the production mutator (keeps the
            // day-key and mirror-date arrays index-parallel and count-matched).
            for _ in 0..<r.int(4) {
                let day = start.addingTimeInterval(TimeInterval(86_400 * (1 + r.int(30))))
                event.appendRecurrenceException(onDay: day, calendar: cal)
            }
            let restored = try roundTrip(event, kind: "calendar")
            XCTAssertEqual(restored, event, "trial \(trial): recurring series with exceptions diverged")
            XCTAssertEqual(restored.recurrenceExceptionDayKeys, event.recurrenceExceptionDayKeys)
            XCTAssertEqual(restored.recurrenceExceptionDates, event.recurrenceExceptionDates)
        }
    }

    /// The documented lossy divergences, pinned as expectations rather than
    /// smoothed over: empty `wannaNotes` and empty `typeWeights` collapse to
    /// nil on round trip (via `encodeJSONOrNull` / the empty-dict decode
    /// guard). If either ever stops collapsing, this fails and the generator's
    /// avoidance can be relaxed.
    func testEmptyCollectionsCollapseToNil() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let event = Event(
            id: UUID(), title: "E",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(3600))],
            createdAt: start,   // whole-second: dodge the ms-precision divergence
            type: "Study",
            typeWeights: [:],
            wannaNotes: []
        )
        let restored = try roundTrip(event, kind: "calendar")
        XCTAssertNil(restored.typeWeights, "empty typeWeights should collapse to nil (documented)")
        XCTAssertNil(restored.wannaNotes, "empty wannaNotes should collapse to nil (documented)")
        // And the collapse is the ONLY difference — everything else survives.
        var expected = event
        expected.typeWeights = nil
        expected.wannaNotes = nil
        XCTAssertEqual(restored, expected)
    }
}
