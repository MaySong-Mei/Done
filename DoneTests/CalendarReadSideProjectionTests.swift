//
//  CalendarReadSideProjectionTests.swift
//  DoneTests
//
//  gh#187 — read-side projection: display code must show a traveled detached
//  recurrence-exception instance at the same instant the canvas draws it
//  (`renderTimeRanges`/`renderPrimaryTimeRange`), never at its raw stored
//  instant, which sits a whole frame away after a time-zone change.
//
//  Mutation coverage (revert the named production site to a raw
//  `timeRanges`/`primaryTimeRange` read and the paired test goes red):
//    * CalendarListEventRow.displayedTimeRange
//        → testListRowTimeLabelUsesRenderFrameForTraveledInstance
//    * CalendarListView.detailRouteOccurrenceDate
//        → testListRouteOccurrenceDateReachesDetailDisplayRange
//    * CalendarSearchView result-builder selectionDate/displayDate fallbacks
//      and CalendarSearchResult.defaultSelectionDate / defaultContext fallback
//        → testSearchResultSeedsRenderFrameSelectionAndDisplayDates,
//          testSearchFallbacksUseRenderFrameForTraveledMovedInstance
//    * CalendarSearchOccurrenceMatch.context(for:) fallback
//        → testSearchOccurrenceMatchContextFallbackMintsRenderFrameRange
//    * ReportStatsBuilder.expandOccurrences non-recurring loop
//        → ReportStatsBuilderTests.testTraveledDetachedInstanceBucketsIntoRenderFrameDay
//    * CalendarPageView.todoStackDropAbsorbParent (containment + sort key)
//        → testTodoStackDropAbsorbsIntoTraveledParentDrawnSlot
//    * CalendarPageView.absorbedParentJumpDay
//        → testJumpToCalendarResolvesTraveledParentDrawnDay
//
//  NOT pinned by any test (reversion invisible; declared per gh#187 rules —
//  all are view-body-embedded reads with no extractable seam worth the churn):
//    * CalendarEventDetailView.todoAbsorptionSection parent time label
//    * CalendarEventDetailView.absorbIntoEventPicker sort key + row label
//    * CalendarEventDetailView.addAbsorptionPicker sort key + row label
//    * CalendarEventDetailView.resolvedParallelTimelineItems candidate range
//    * CalendarSearchView.eventCardRange fallback (private view method)
//

import XCTest
@testable import Done

@MainActor
final class CalendarReadSideProjectionTests: XCTestCase {

    // Mint frame: Pacific/Apia (UTC+13, no DST). Read frame: New York
    // (EDT in August, UTC−4) — 17 hours apart, so an Apia-morning instant
    // re-buckets to the PREVIOUS New York day while the nominal day key
    // pins the drawn block to the day the user detached.
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

    private func apiaDate(_ day: Int, _ hour: Int) -> Date {
        apia.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
    }

    private func nyDate(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        ny.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    /// Detach the Aug 10 occurrence of an Apia-frame daily series through the
    /// production seam (`Event.applyEdit`), then read it under New York.
    /// Asserts the non-degeneracy precondition — projected != raw — so every
    /// downstream assertion is guaranteed to discriminate the two frames.
    private func makeTraveledInstance() throws -> (instance: Event, raw: Event.TimeRange, projected: Event.TimeRange) {
        let series = Event(
            id: UUID(uuidString: "18718700-0000-0000-0000-000000000001")!,
            title: "Daily",
            timeRanges: [Event.TimeRange(start: apiaDate(3, 9), end: apiaDate(3, 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: apiaDate(10, 9),
            scope: .single,
            edit: { $0.title = "TraveledDetachedProbe" },
            calendar: apia
        )
        let instance = try XCTUnwrap(result.exceptionInstance)
        let raw = try XCTUnwrap(instance.primaryTimeRange)
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertEqual(raw.start, nyDate(9, 16), "stored instant re-buckets to NY Aug 9")
        XCTAssertEqual(projected.start, nyDate(10, 16), "canvas draws the nominal day, NY Aug 10")
        XCTAssertEqual(projected.end, nyDate(10, 17))
        XCTAssertNotEqual(projected, raw,
                          "fixture must actually travel — identical frames make every assertion vacuous")
        return (instance, raw, projected)
    }

    /// The moved-AND-traveled variant: the replacement's stored range was
    /// deliberately moved one day past its nominal day, so the occurrence-day
    /// lookup (`recurrenceInstanceMatches`) misses and the raw-read fallbacks
    /// under test are the ONLY path that fires.
    private func makeTraveledMovedInstance() throws -> (instance: Event, raw: Event.TimeRange, projected: Event.TimeRange) {
        let instance = Event(
            id: UUID(uuidString: "18718700-0000-0000-0000-000000000002")!,
            title: "TraveledMovedProbe",
            timeRanges: [Event.TimeRange(start: apiaDate(11, 9), end: apiaDate(11, 10))],
            type: "Study",
            recurrenceParentId: UUID(uuidString: "18718700-0000-0000-0000-000000000003")!,
            recurrenceInstanceDate: apia.startOfDay(for: apiaDate(10, 9)),
            recurrenceInstanceDayKey: 20_260_810
        )
        let raw = try XCTUnwrap(instance.primaryTimeRange)
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertEqual(raw.start, nyDate(10, 16))
        XCTAssertEqual(projected.start, nyDate(11, 16),
                       "the deliberate one-day move survives projection (day shift preserved)")
        XCTAssertNotEqual(projected, raw,
                          "fixture must actually travel — identical frames make every assertion vacuous")
        XCTAssertNil(
            calendarOccurrenceDisplayRange(event: instance, occurrenceDate: projected.start, calendar: ny),
            "moved instance misses the nominal-day lookup, so the fallback under test is the live path"
        )
        return (instance, raw, projected)
    }

    private func withDefaultTimeZonePinnedToNewYork(_ body: () throws -> Void) rethrows {
        let prior = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = prior }
        try body()
    }

    // MARK: - List (CalendarListView)

    /// The agenda row's time label must be the projected range — the same
    /// frame `eventsForDate` buckets and sorts by — not the raw stored one.
    func testListRowTimeLabelUsesRenderFrameForTraveledInstance() throws {
        let fixture = try makeTraveledInstance()
        try withDefaultTimeZonePinnedToNewYork {
            let row = CalendarListEventRow(event: fixture.instance)
            XCTAssertEqual(row.displayedTimeRange(), fixture.projected)
            XCTAssertNotEqual(row.displayedTimeRange(), fixture.raw,
                              "raw label would name an instant on the day BEFORE the row's own section header")
            _ = try XCTUnwrap(row.displayedTimeRange())
        }
    }

    /// The pushed route's occurrenceDate must land on the nominal day so the
    /// detail's display-range lookup resolves — seeding it from the raw start
    /// is exactly the blank-detail-header repro.
    func testListRouteOccurrenceDateReachesDetailDisplayRange() throws {
        let fixture = try makeTraveledInstance()
        let listedDay = ny.startOfDay(for: fixture.projected.start)

        let occurrenceDate = CalendarListView.detailRouteOccurrenceDate(
            for: fixture.instance,
            listedDate: listedDay,
            calendar: ny
        )
        XCTAssertEqual(occurrenceDate, fixture.projected.start)

        let headerRange = calendarOccurrenceDisplayRange(
            event: fixture.instance,
            occurrenceDate: occurrenceDate,
            calendar: ny
        )
        XCTAssertEqual(headerRange, fixture.projected, "detail header resolves to the drawn slot")

        XCTAssertNil(
            calendarOccurrenceDisplayRange(
                event: fixture.instance,
                occurrenceDate: fixture.raw.start,
                calendar: ny
            ),
            "a raw-seeded route misses the nominal-day key — the blank header this fix removes"
        )
    }

    // MARK: - Search (CalendarSearchView)

    /// A title-matched traveled instance (no occurrence matches) must seed its
    /// card display date, default selection, and pushed context from the
    /// projected range.
    func testSearchResultSeedsRenderFrameSelectionAndDisplayDates() throws {
        let fixture = try makeTraveledInstance()
        try withDefaultTimeZonePinnedToNewYork {
            let results = calendarSearchResults(
                query: "TraveledDetachedProbe",
                events: [fixture.instance],
                logRecords: [],
                calendar: ny
            )
            let result = try XCTUnwrap(results.first)
            XCTAssertEqual(results.count, 1)
            XCTAssertTrue(result.occurrenceMatches.isEmpty,
                          "title-only match — the event-range fallbacks under test are the live path")

            XCTAssertEqual(result.displayDate, fixture.projected.start)
            XCTAssertEqual(result.defaultSelectionDate(calendar: ny), fixture.projected.start)

            let context = result.defaultContext(calendar: ny)
            XCTAssertEqual(context.occurrenceDate, fixture.projected.start)
            let occurrenceID = try XCTUnwrap(context.occurrenceID)
            XCTAssertTrue(occurrenceID.contains("\(fixture.projected.start.timeIntervalSince1970)"),
                          "occurrenceID is minted from the projected range the canvas block carries")
            XCTAssertFalse(occurrenceID.contains("\(fixture.raw.start.timeIntervalSince1970)"),
                           "a raw-minted occurrenceID matches no drawn block")
        }
    }

    /// With the occurrence-day lookup missing (moved + traveled), the
    /// `?? render…` fallbacks themselves are exercised end to end.
    func testSearchFallbacksUseRenderFrameForTraveledMovedInstance() throws {
        let fixture = try makeTraveledMovedInstance()
        try withDefaultTimeZonePinnedToNewYork {
            let results = calendarSearchResults(
                query: "TraveledMovedProbe",
                events: [fixture.instance],
                logRecords: [],
                calendar: ny
            )
            let result = try XCTUnwrap(results.first)
            XCTAssertEqual(result.displayDate, fixture.projected.start)
            XCTAssertEqual(result.defaultSelectionDate(calendar: ny), fixture.projected.start)

            let context = result.defaultContext(calendar: ny)
            XCTAssertEqual(context.occurrenceDate, fixture.projected.start)
            let occurrenceID = try XCTUnwrap(context.occurrenceID)
            XCTAssertTrue(occurrenceID.contains("\(fixture.projected.start.timeIntervalSince1970)"))
            XCTAssertFalse(occurrenceID.contains("\(fixture.raw.start.timeIntervalSince1970)"))
        }
    }

    /// An occurrence match whose stored date names the mint-frame day (the
    /// shape a pre-travel log record carries) falls through the day lookup;
    /// the fallback must still mint the context from the projected range.
    func testSearchOccurrenceMatchContextFallbackMintsRenderFrameRange() throws {
        let fixture = try makeTraveledInstance()
        let match = CalendarSearchOccurrenceMatch(
            eventID: fixture.instance.id,
            occurrenceDate: nyDate(9),
            isAllDay: false,
            snippets: []
        )
        XCTAssertNil(
            calendarOccurrenceDisplayRange(event: fixture.instance, occurrenceDate: nyDate(9), calendar: ny),
            "mint-frame day misses the nominal-day lookup — the fallback under test is the live path"
        )

        let context = match.context(for: fixture.instance, calendar: ny)
        let occurrenceID = try XCTUnwrap(context.occurrenceID)
        XCTAssertTrue(occurrenceID.contains("\(fixture.projected.start.timeIntervalSince1970)"),
                      "fallback context is minted from the projected range")
        XCTAssertFalse(occurrenceID.contains("\(fixture.raw.start.timeIntervalSince1970)"))
    }

    // MARK: - Canvas drop + search jump (CalendarPageView)

    /// A stack-card drop instant comes from canvas Y geometry, so hit-testing
    /// must run against the traveled parent's DRAWN slot. The second,
    /// never-traveled candidate makes the latest-start tie-break
    /// discriminating too: projected sort picks the traveled parent, raw sort
    /// would pick the other.
    func testTodoStackDropAbsorbsIntoTraveledParentDrawnSlot() throws {
        let fixture = try makeTraveledInstance()
        let plain = Event(
            id: UUID(uuidString: "18718700-0000-0000-0000-000000000004")!,
            title: "Underneath",
            timeRanges: [Event.TimeRange(start: nyDate(10, 15, 30), end: nyDate(10, 17, 30))],
            type: "Study"
        )
        let todoID = UUID(uuidString: "18718700-0000-0000-0000-000000000005")!
        let dropInstant = nyDate(10, 16, 30)

        let parent = CalendarPageView.todoStackDropAbsorbParent(
            candidates: [plain, fixture.instance],
            dropInstant: dropInstant,
            excluding: todoID,
            calendar: ny
        )
        XCTAssertEqual(parent?.id, fixture.instance.id,
                       "drop inside the drawn slot absorbs into the traveled parent (latest projected start)")

        XCTAssertNil(
            CalendarPageView.todoStackDropAbsorbParent(
                candidates: [fixture.instance],
                dropInstant: fixture.raw.start.addingTimeInterval(30 * 60),
                excluding: todoID,
                calendar: ny
            ),
            "the mint-frame slot draws nothing — no false absorb there"
        )
    }

    /// The receiving end of the search route: jumping to an absorbed todo
    /// scrolls to the day its (traveled) parent is drawn on, not to the day
    /// the raw stored start names.
    func testJumpToCalendarResolvesTraveledParentDrawnDay() throws {
        let fixture = try makeTraveledInstance()
        let day = CalendarPageView.absorbedParentJumpDay(parent: fixture.instance, calendar: ny)
        XCTAssertEqual(day, ny.startOfDay(for: fixture.projected.start))
        XCTAssertNotEqual(day, ny.startOfDay(for: fixture.raw.start),
                          "raw day would scroll the canvas to a day that draws nothing")
    }
}
