//
//  AllDayDSTCoverageTests.swift
//  DoneTests
//
//  gh#188 — adjacent gaps around all-day projection and DST:
//    * the all-day branch of `Event.renderTimeRanges(calendar:)` — the only
//      shape-changing branch (snaps a traveled instance to the reading
//      frame's own midnight, keeping only the covered days) — had no test;
//      since gh#152 its output is what the edit sheet seeds and re-commits
//      to storage.
//    * the spring-forward composite: projection seed
//      (`EditCalendarEventView.occurrenceSeedRange`) → the form's all-day
//      storage snap (`CalendarEventFormData.allDayStorage*`). On a 23-hour
//      reading day, `+86_399` arithmetic straddles the civil day.
//    * `Event.dateByCombining` handed a time-of-day inside the DST gap:
//      Foundation returns an adjusted instant, not nil — pinned here as the
//      observed contract.
//    * round 2 (QA): the fall-back (25-hour) day's snap end, a mint-frame
//      spring-forward hour hiding inside a multi-day stored duration (the
//      `.rounded()` vs flooring divergence), and the degenerate short-range
//      clamp.
//
//  Every expected instant is a hand-computed epoch literal (time-zone math
//  done outside this codebase); no expectation is derived through
//  `renderTimeRanges`, `occurrenceSeedRange`, or the storage-snap functions
//  under test.
//

import XCTest
@testable import Done

@MainActor
final class AllDayDSTCoverageTests: XCTestCase {

    // Mint frame: Pacific/Apia (UTC+13, no DST). Read frames: New York
    // (EDT in August — a normal 24-hour day) and Los Angeles, whose
    // 2026-03-08 is the spring-forward day (02:00→03:00 skipped, 23 civil
    // hours).
    private var apia: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Pacific/Apia")!
        return cal
    }

    private var ny: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private var la: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return cal
    }

    // MARK: - Hand-computed instants

    /// Apia 2026-08-10 00:00:00 (+13) == New York 2026-08-09 07:00:00 (EDT)
    private let apiaAug10Midnight = Date(timeIntervalSince1970: 1_786_273_200)
    /// New York 2026-08-10 00:00:00 (EDT)
    private let nyAug10Midnight = Date(timeIntervalSince1970: 1_786_334_400)
    /// New York 2026-08-10 23:59:59 (EDT)
    private let nyAug10EndOfDay = Date(timeIntervalSince1970: 1_786_420_799)
    /// Apia 2026-03-08 00:00:00 (+13) == Los Angeles 2026-03-07 03:00:00 (PST)
    private let apiaMar8Midnight = Date(timeIntervalSince1970: 1_772_881_200)
    /// Los Angeles 2026-03-08 00:00:00 (PST) — midnight of the spring-forward day
    private let laMar8Midnight = Date(timeIntervalSince1970: 1_772_956_800)
    /// Los Angeles 2026-03-08 23:59:59 (PDT) — calendar end of the 23-hour day;
    /// `laMar8Midnight + 86_399` is NOT this instant (it is Mar 9, 00:59:59 PDT)
    private let laMar8EndOfDay = Date(timeIntervalSince1970: 1_773_039_599)
    /// Los Angeles 2026-03-08 12:00:00 (PDT)
    private let laMar8Noon = Date(timeIntervalSince1970: 1_772_996_400)
    /// Los Angeles 2026-03-07 00:00:00 (PST)
    private let laMar7Midnight = Date(timeIntervalSince1970: 1_772_870_400)
    /// Los Angeles 2026-03-07 02:30:00 (PST) — a normal-day 02:30 wall clock
    private let laMar7At0230 = Date(timeIntervalSince1970: 1_772_879_400)
    /// Los Angeles 2026-03-08 03:00:00 (PDT) — the first valid instant after
    /// the spring-forward gap
    private let laMar8At0300 = Date(timeIntervalSince1970: 1_772_964_000)
    /// New York 2026-03-07 00:00:00 (EST)
    private let nyMar7Midnight = Date(timeIntervalSince1970: 1_772_859_600)
    /// New York 2026-03-08 23:59:59 (EDT) — calendar end of NY's own 23-hour
    /// spring-forward day
    private let nyMar8EndOfDay = Date(timeIntervalSince1970: 1_773_028_799)
    /// Los Angeles 2026-11-01 00:00:00 (PDT) — midnight of the fall-back day
    /// (25 civil hours: 01:00–02:00 repeats, PDT then PST)
    private let laNov1Midnight = Date(timeIntervalSince1970: 1_793_516_400)
    /// Los Angeles 2026-11-01 23:59:59 (PST) — calendar end of the 25-hour
    /// day; `laNov1Midnight + 86_399` is Nov 1 22:59:59 PST, one hour SHORT
    private let laNov1EndOfDay = Date(timeIntervalSince1970: 1_793_606_399)
    /// Los Angeles 2026-11-01 12:00:00 (PST — noon falls after the fall-back)
    private let laNov1Noon = Date(timeIntervalSince1970: 1_793_563_200)

    // MARK: - Fixture

    /// A traveled ALL-DAY detached exception instance carrying the composer's
    /// stored shape `[mint midnight, mint midnight + storedDuration]` (the
    /// single-day default 86_399 IS the mint frame's calendar end on the
    /// non-DST Apia fixtures; multi-day callers pass their mint pair's own
    /// span), nominal day pinned by its day key. Read under a different
    /// frame, the mirror differs from the reading frame's midnight, so the
    /// projection actually fires (asserted per-test as the non-degeneracy
    /// precondition).
    private func traveledAllDayInstance(nominalDayKey: Int, mintMidnight: Date,
                                        storedDuration: TimeInterval = 86_399) -> Event {
        Event(
            id: UUID(uuidString: "18800000-0000-0000-0000-000000000001")!,
            title: "TraveledAllDayProbe",
            timeRanges: [Event.TimeRange(
                start: mintMidnight,
                end: mintMidnight.addingTimeInterval(storedDuration)
            )],
            isAllDay: true,
            type: "Study",
            recurrenceParentId: UUID(uuidString: "18800000-0000-0000-0000-000000000002")!,
            recurrenceInstanceDate: mintMidnight,
            recurrenceInstanceDayKey: nominalDayKey
        )
    }

    // MARK: - P1: the all-day projection branch (normal read day)

    /// The all-day branch snaps the projection to the READING frame's own
    /// midnight of the nominal day and preserves the original duration —
    /// never the mint frame's residue time-of-day (which would be 07:00 in
    /// New York for an Apia midnight).
    func testTraveledAllDayInstanceProjectsToReadingFrameMidnightPreservingDuration() throws {
        XCTAssertNotEqual(apia.timeZone, ny.timeZone,
                          "fixture precondition: mint and read frames must differ")
        let instance = traveledAllDayInstance(nominalDayKey: 20_260_810,
                                              mintMidnight: apiaAug10Midnight)
        let raw = try XCTUnwrap(instance.primaryTimeRange)
        XCTAssertEqual(raw.start, apiaAug10Midnight,
                       "raw stored instant is NY Aug 9 07:00 — off the nominal day")
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertNotEqual(projected, raw,
                          "fixture must actually travel — identical frames make every assertion vacuous")
        XCTAssertEqual(projected.start, nyAug10Midnight,
                       "all-day projection lands on the reading frame's own midnight of the nominal day, not at the mint frame's residue time-of-day (NY Aug 10 07:00)")
        XCTAssertEqual(projected.start, ny.startOfDay(for: projected.start),
                       "projected start must be a New York midnight")
        XCTAssertEqual(projected.end.timeIntervalSince(projected.start), 86_399,
                       "original all-day duration preserved on a normal 24-hour read day")
        XCTAssertEqual(projected.end, nyAug10EndOfDay)
    }

    /// Single-day stays single-day on a normal read day — asserted both on
    /// the projected range and through the all-day strip's real overlap
    /// consumer: exactly the nominal day renders the block.
    func testTraveledAllDayInstanceStaysSingleDayOnNormalReadDay() throws {
        let instance = traveledAllDayInstance(nominalDayKey: 20_260_810,
                                              mintMidnight: apiaAug10Midnight)
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertNotEqual(projected, instance.primaryTimeRange,
                          "fixture must actually travel — identical frames make every assertion vacuous")
        XCTAssertTrue(ny.isDate(projected.start, inSameDayAs: projected.end),
                      "a single-day all-day instance must project inside one civil day")

        let aug9 = ny.date(from: DateComponents(year: 2026, month: 8, day: 9))!
        let aug10 = ny.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let aug11 = ny.date(from: DateComponents(year: 2026, month: 8, day: 11))!
        XCTAssertTrue(CalendarLayout.allDayOccurrencesForDate([instance], date: aug9, calendar: ny).isEmpty,
                      "the raw mint-frame instant would leak the block onto NY Aug 9")
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate([instance], date: aug10, calendar: ny).count, 1,
                       "the block belongs on its nominal day")
        XCTAssertTrue(CalendarLayout.allDayOccurrencesForDate([instance], date: aug11, calendar: ny).isEmpty,
                      "an end straddling midnight would leak the block onto NY Aug 11")
    }

    // MARK: - P1b: multi-day all-day across a mint-frame DST hour

    /// A TWO-day traveled all-day instance whose stored duration hides a
    /// mint-frame spring-forward hour: minted in Los Angeles across
    /// Mar 7–8 2026 (24h + 23h civil days), the healthy stored shape is
    /// [Mar 7 00:00 PST, Mar 8 23:59:59 PDT] — duration 169_199s, and
    /// (169_199 + 1) / 86_400 = 1.958…, so `.rounded()` keeps 2 covered
    /// days while flooring would collapse the instance to one. Read in New
    /// York (whose Mar 7–8 pair is also 47h), the projection must cover
    /// exactly NY Mar 7 and Mar 8.
    func testTraveledTwoDayAllDayInstanceKeepsBothDaysAcrossMintFrameDSTHour() throws {
        let instance = traveledAllDayInstance(nominalDayKey: 20_260_307,
                                              mintMidnight: laMar7Midnight,
                                              storedDuration: 169_199)
        let raw = try XCTUnwrap(instance.primaryTimeRange)
        XCTAssertEqual(raw.end, laMar8EndOfDay,
                       "fixture precondition: the LA-minted 2-day shape ends Mar 8 23:59:59 PDT")
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertNotEqual(projected, raw,
                          "fixture must actually travel — identical frames make every assertion vacuous")
        XCTAssertEqual(projected.start, nyMar7Midnight)
        XCTAssertEqual(projected.end, nyMar8EndOfDay,
                       "both covered days survive the projection — a floored day count would end at NY Mar 7 23:59:59 (1_772_945_999)")

        let mar6 = ny.date(from: DateComponents(year: 2026, month: 3, day: 6))!
        let mar7 = ny.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let mar8 = ny.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let mar9 = ny.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        XCTAssertTrue(CalendarLayout.allDayOccurrencesForDate([instance], date: mar6, calendar: ny).isEmpty)
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate([instance], date: mar7, calendar: ny).count, 1)
        XCTAssertEqual(CalendarLayout.allDayOccurrencesForDate([instance], date: mar8, calendar: ny).count, 1,
                       "the second covered day must render — a floored day count drops it from the strip")
        XCTAssertTrue(CalendarLayout.allDayOccurrencesForDate([instance], date: mar9, calendar: ny).isEmpty)
    }

    /// Degenerate-input clamp: a corrupt all-day range shorter than half a
    /// day (here 3_599s) must still project as ONE full civil day — without
    /// the `max(1, …)` clamp the rounded day count is 0 and the projected
    /// end lands on the PREVIOUS civil day, before the projected start.
    func testDegenerateShortAllDayRangeStillProjectsOneFullCivilDay() throws {
        let instance = traveledAllDayInstance(nominalDayKey: 20_260_810,
                                              mintMidnight: apiaAug10Midnight,
                                              storedDuration: 3_599)
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertEqual(projected.start, nyAug10Midnight)
        XCTAssertEqual(projected.end, nyAug10EndOfDay,
                       "a sub-day stored duration clamps to one full civil day — a zero day count would invert the range")
        XCTAssertTrue(projected.start < projected.end)
    }

    // MARK: - P2: spring-forward — projection layer

    /// On a 23-hour spring-forward reading day the projected all-day range
    /// must still end inside its own civil day: raw `start + 86_399`
    /// arithmetic lands at Mar 9 00:59:59 PDT, one civil day over.
    func testAllDayProjectionOnSpringForwardReadDayEndsInsideItsCivilDay() throws {
        let instance = traveledAllDayInstance(nominalDayKey: 20_260_308,
                                              mintMidnight: apiaMar8Midnight)
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: la))
        XCTAssertNotEqual(projected, instance.primaryTimeRange,
                          "fixture must actually travel — identical frames make every assertion vacuous")
        XCTAssertEqual(projected.start, laMar8Midnight,
                       "reading frame's midnight of the nominal day (LA Mar 8 00:00 PST)")
        XCTAssertEqual(projected.end, laMar8EndOfDay,
                       "calendar end of the 23-hour day (Mar 8 23:59:59 PDT) — +86_399 arithmetic would land at Mar 9 00:59:59 PDT")
        XCTAssertTrue(la.isDate(projected.start, inSameDayAs: projected.end),
                      "the projection must not straddle the all-day strip's overlap test into Mar 9")
    }

    // MARK: - P2: spring-forward — the real composite (seed → snap)

    /// The gh#152 write path end-to-end: the edit sheet seeds from the
    /// projection (`occurrenceSeedRange`), an untouched all-day edit rides
    /// that seed into the form's storage snap, and what comes out is what
    /// gets stored. On the spring-forward day the composite must still
    /// commit ONE civil day — not stretch a single-day instance to two.
    func testUntouchedAllDayEditOnSpringForwardReadDayCommitsSingleDayStorage() throws {
        let instance = traveledAllDayInstance(nominalDayKey: 20_260_308,
                                              mintMidnight: apiaMar8Midnight)
        let seed = EditCalendarEventView.occurrenceSeedRange(
            event: instance,
            occurrenceDate: nil,
            recurrenceScope: nil,
            calendar: la
        )
        XCTAssertEqual(seed.start, laMar8Midnight,
                       "the sheet seeds the drawn day's own midnight — precondition for the snap below")

        let storedStart = CalendarEventFormData.allDayStorageStart(for: seed.start, calendar: la)
        let storedEnd = CalendarEventFormData.allDayStorageEnd(for: seed.end, calendar: la)
        XCTAssertEqual(storedStart, laMar8Midnight)
        XCTAssertEqual(storedEnd, laMar8EndOfDay,
                       "an untouched all-day edit must re-commit the SAME civil day, ending Mar 8 23:59:59 PDT — not anchor on a straddled seed end and stretch storage into Mar 9")
        XCTAssertTrue(la.isDate(storedStart, inSameDayAs: storedEnd),
                      "the composite must not store a single-day all-day instance as two days")
    }

    /// The snap owns the same 23-hour-day wrongness independent of any
    /// travel or projection: a plain CREATE of an all-day event on the
    /// spring-forward day must store one civil day.
    func testAllDaySaveSnapOnSpringForwardDayStaysSingleDayWithoutTravel() {
        let storedStart = CalendarEventFormData.allDayStorageStart(for: laMar8Noon, calendar: la)
        let storedEnd = CalendarEventFormData.allDayStorageEnd(for: laMar8Noon, calendar: la)
        XCTAssertEqual(storedStart, laMar8Midnight)
        XCTAssertEqual(storedEnd, laMar8EndOfDay,
                       "create-path snap: `startOfDay + 86_399` would store an end at Mar 9 00:59:59 PDT")
        XCTAssertTrue(la.isDate(storedStart, inSameDayAs: storedEnd))
    }

    // MARK: - P2b: fall-back — the 25-hour day

    /// Fall-back mirror of the create-path pin: on LA's 25-hour 2026-11-01
    /// the snap must end at the day's own calendar end, Nov 1 23:59:59 PST.
    /// The old `startOfDay + 86_399` shape stopped one hour SHORT of it
    /// (Nov 1 22:59:59 PST, epoch 1_793_602_799 = end − 3_600).
    func testAllDaySaveSnapOnFallBackDayCoversFull25HourDay() {
        let storedStart = CalendarEventFormData.allDayStorageStart(for: laNov1Noon, calendar: la)
        let storedEnd = CalendarEventFormData.allDayStorageEnd(for: laNov1Noon, calendar: la)
        XCTAssertEqual(storedStart, laNov1Midnight)
        XCTAssertEqual(storedEnd, laNov1EndOfDay,
                       "calendar end of the 25-hour day — `startOfDay + 86_399` stops at Nov 1 22:59:59 PST, an hour early")
        XCTAssertEqual(storedEnd.timeIntervalSince(storedStart), 89_999,
                       "the fall-back civil day spans 25 hours (90_000s); the end sits at its last second")
        XCTAssertTrue(la.isDate(storedStart, inSameDayAs: storedEnd))
    }

    // MARK: - P3: dateByCombining inside the spring-forward gap

    /// Observed Foundation contract, pinned: `calendar.date(bySettingHour:)`
    /// handed a wall-clock inside the 02:00→03:00 gap returns the FIRST
    /// valid post-gap instant (03:00:00 PDT) — an adjusted instant, never
    /// nil, and the minutes are collapsed, not carried across the gap.
    func testDateByCombiningInSpringForwardGapSnapsToFirstPostGapInstant() {
        let control = Event.dateByCombining(day: laMar7Midnight, timeFrom: laMar7At0230, calendar: la)
        XCTAssertEqual(control, laMar7At0230,
                       "positive control: outside the gap the reduction is wall-clock identity (02:30 lands at 02:30 of the target day)")

        let combined = Event.dateByCombining(day: laMar8Midnight, timeFrom: laMar7At0230, calendar: la)
        XCTAssertNotEqual(combined, laMar8Midnight,
                          "Foundation does not hit the `?? day` nil-fallback in the gap")
        XCTAssertEqual(combined, laMar8At0300,
                       "a 02:30 time-of-day inside the gap resolves to 03:00:00 PDT — the first post-gap instant, not 03:30 (minute carry) and not a phantom 02:30")
    }
}
