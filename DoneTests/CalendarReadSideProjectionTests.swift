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
//  gh#204 (cosmetic/gamification aggregation + remaining route seeds):
//    * calendarProjectedTypeHours (knownTypeNames/topDescriptors + the
//      personality summary's hour buckets)
//        → testTypeHourWindowCountsTraveledInstanceInProjectedWindow,
//          testTypeHourWindowClipsStraddlingAndDropsOutsideRanges
//    * PersonalityTagsService.typeDistribution (hours + range count)
//        → testPersonalitySummaryTypeDistributionUsesRenderFrame
//    * CalendarPageView.canvasDropAbsorbParent (drag-drop absorb fallback)
//        → testCanvasDropFallbackAbsorbsIntoTraveledParentDrawnSlot
//    * AchievementCatalog.makeFunnyHiddenAchievements shared range pool
//        → testHiddenAchievementRangePoolUsesRenderFrame
//    * AchievementCatalog sleep/exercise streak day-sets
//        → testHabitStreakDaySetsBucketTraveledInstanceOnProjectedDay
//    * AchievementCatalog slam-dunk / well-rested unlock dates
//        → testHabitRewardUnlockDatesUseRenderFrame
//    * AchievementCatalog.makeFestive special-day loop
//        → testFestiveSpecialDayUsesRenderFrameDay
//    * EditCalendarEventView.fallbackDeleteOccurrenceDate
//        → testDeleteFallbackOccurrenceSeedUsesRenderFrame
//    * CalendarRecurringSeriesListView.editorSeedOccurrenceDate
//        → testRecurringSeriesListSeedsRenderFrameOccurrenceDate
//
//  NOT pinned by any test (reversion invisible; declared per gh#187 rules —
//  all are view-body-embedded reads with no extractable seam worth the churn):
//    * CalendarEventDetailView.todoAbsorptionSection parent time label
//    * CalendarEventDetailView.absorbIntoEventPicker sort key + row label
//    * CalendarEventDetailView.addAbsorptionPicker sort key + row label
//    * CalendarEventDetailView.resolvedParallelTimelineItems candidate range
//    * CalendarSearchView.eventCardRange fallback (private view method)
//  gh#204 additions to that list:
//    * ProfileHubView.knownTypeNames/topDescriptors wrappers around the seam
//      (view-locked plumbing; the seam itself is pinned)
//    * PersonalityTagsService.buildUserSummary plumbing into typeDistribution
//      (provider-locked; the reduction itself is pinned)
//    * CalendarPageView.handleEventDrag call site of canvasDropAbsorbParent
//      (view-locked plumbing)
//    * AchievementCatalog.compute's argument plumbing into the two builders
//    * EditCalendarEventView.deleteEvent / series-list sheet call sites of the
//      pinned seeds (view-locked plumbing)
//    * CalendarRecurringSeriesListView.sortedSeriesList SORT KEY — no test can
//      see a reversion: the isRecurringSeries filter admits only templates,
//      where the raw and projected frames coincide by construction
//
//  gh#208 (the finale — wanna completion, agent-facing readers, skill
//  analysis):
//    * EventStore.currentlyActiveCalendarEvent containment
//        → testCurrentlyActiveCalendarEventSelectsTraveledInstanceByDrawnSlot
//    * EventStore.completeWanna stamped occurrenceDate (and, transitively,
//      the active-event selection it rides on)
//        → testCompleteWannaStampsProjectedOccurrenceKeyForTraveledActiveEvent
//    * EventStore.completeWanna stamp anchors on the projected START's day
//      (cross-midnight discrimination the same-day fixture cannot make)
//        → testCompleteWannaCrossMidnightStampsDrawnStartDay
//    * EventStore.currentlyActiveCalendarEvent boundary contract (closed
//      intervals + array-order tie-break, pinned as an invariant)
//        → testCurrentlyActiveCalendarEventBoundaryIsClosedAndArrayOrdered
//    * EventStore.absorbTodoIntoEvent auto-complete gate
//        → testAbsorbAutoCompleteGateReadsTraveledParentDrawnEnd
//    * AgentTools listCalendarEvents filter + display strings
//        → testAgentListCalendarEventsReturnsProjectedTimesForTraveledInstance
//    * AgentTools getScheduleForDate day bucket + display strings
//        → testAgentScheduleForDateBucketsTraveledInstanceOnDrawnDay
//    * AgentTools getUserData display strings
//        → testAgentUserDataExportPrintsProjectedTimes
//    * SkillAnalysisService end gate (skillAnalysisEventHasEnded)
//        → testSkillAnalysisEndGateReadsDrawnSlot
//    * SkillAnalysisService.parseAndStore insight date bucket
//        → testSkillInsightDateBucketsTraveledInstanceOnDrawnDay
//  gh#208 additions to the NOT-pinned list:
//    * AgentTools.executeGetUserData cutoff FILTER frame — the cutoff
//      anchors to a bare Date() inside the executor, so no deterministic
//      fixture can place it between the raw and projected starts; the
//      display strings beside it are pinned, the window frame is not
//    * SkillAnalysisService.analyzeEvent's call into
//      skillAnalysisEventHasEnded — the predicate itself is pinned, but the
//      call site sits behind the async LLM-provider seam and its outcome
//      (return-before-markAnalyzed) is indistinguishable from the
//      missing-API-key return without a provider fake
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

    // MARK: - gh#204 fixtures

    /// Direct-construction traveled instance (mirror minted in Apia, read in
    /// NY) with caller-chosen type/day/shape — the aggregation tests need
    /// typed populations the `applyEdit` fixture can't mint. Same
    /// non-degeneracy preconditions as the fixtures above, plus the drawn
    /// DAY differing, which the day-set assertions depend on.
    private func makeTraveledTypedInstance(
        type: String,
        month: Int,
        day: Int,
        startHour: Int = 9,
        durationHours: Double = 1
    ) throws -> (instance: Event, raw: Event.TimeRange, projected: Event.TimeRange) {
        let start = apia.date(from: DateComponents(year: 2026, month: month, day: day, hour: startHour))!
        let instance = Event(
            id: UUID(),
            title: "Traveled \(type)",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(durationHours * 3600))],
            type: type,
            recurrenceParentId: UUID(),
            recurrenceInstanceDate: apia.startOfDay(for: start),
            recurrenceInstanceDayKey: 20_260_000 + month * 100 + day
        )
        let raw = try XCTUnwrap(instance.primaryTimeRange)
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertNotEqual(projected, raw,
                          "fixture must actually travel — identical frames make every assertion vacuous")
        XCTAssertNotEqual(ny.startOfDay(for: projected.start), ny.startOfDay(for: raw.start),
                          "the drawn DAY must differ from the stored day")
        return (instance, raw, projected)
    }

    private func plainEvent(
        type: String,
        month: Int,
        day: Int,
        startHour: Int = 16,
        durationHours: Double = 1
    ) -> Event {
        let start = ny.date(from: DateComponents(year: 2026, month: month, day: day, hour: startHour))!
        return Event(
            id: UUID(),
            title: "Plain \(type)",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(durationHours * 3600))],
            type: type
        )
    }

    private func makeSeriesTemplate(startDay: Int) -> Event {
        Event(
            id: UUID(),
            title: "Series \(startDay)",
            timeRanges: [Event.TimeRange(start: nyDate(startDay, 9), end: nyDate(startDay, 10))],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Study"
        )
    }

    // MARK: - gh#204 — Me-page type hours (ProfileHubView)

    /// The type-hour reduction behind `knownTypeNames`/`topDescriptors` must
    /// clip against projected instants: a 30-day-style window opening on the
    /// drawn day contains the traveled hour, while the stored instant sits
    /// wholly before it and would contribute nothing.
    func testTypeHourWindowCountsTraveledInstanceInProjectedWindow() throws {
        let fixture = try makeTraveledInstance()
        let window = ny.startOfDay(for: fixture.projected.start)...nyDate(30)
        let hours = calendarProjectedTypeHours(
            events: [fixture.instance],
            window: window,
            calendar: ny
        )
        XCTAssertEqual(hours["Study"] ?? 0, 1.0, accuracy: 0.0001,
                       "the traveled hour lands inside the window that opens on its drawn day")
        // Unwindowed shape (knownTypeNames): the same single projected hour.
        let all = calendarProjectedTypeHours(events: [fixture.instance], calendar: ny)
        XCTAssertEqual(all["Study"] ?? 0, 1.0, accuracy: 0.0001)
    }

    /// The window intersection itself (skip + clamp): a range straddling the
    /// window's lower bound contributes only its clipped tail, and a range
    /// wholly outside contributes nothing — dropping the clip would count
    /// three raw hours here instead of one.
    func testTypeHourWindowClipsStraddlingAndDropsOutsideRanges() {
        let straddler = plainEvent(type: "Study", month: 8, day: 10, startHour: 15, durationHours: 2)
        let outside = plainEvent(type: "Study", month: 8, day: 9, startHour: 10)
        let window = nyDate(10, 16)...nyDate(30)
        let hours = calendarProjectedTypeHours(events: [straddler, outside], window: window, calendar: ny)
        XCTAssertEqual(hours["Study"] ?? 0, 1.0, accuracy: 0.0001,
                       "15:00-17:00 clipped at the 16:00 bound leaves 1h; the day-9 range adds nothing")
    }

    /// The personality summary's 90-day type distribution: the traveled
    /// instance's hours and its "tracked activities" count are both decided
    /// by the drawn instant. The window opens between the raw and projected
    /// instants, so a raw read finds nothing at all.
    func testPersonalitySummaryTypeDistributionUsesRenderFrame() throws {
        let fixture = try makeTraveledInstance()
        // Window opens mid-way through the projected hour: raw (Aug 9 16:00)
        // is wholly before it, projected (Aug 10 16:00-17:00) clips to 30min.
        let window = nyDate(10, 16, 30)...nyDate(30)
        let distribution = PersonalityTagsService.typeDistribution(
            events: [fixture.instance],
            window: window,
            calendar: ny
        )
        XCTAssertEqual(distribution.hoursByType["Study"] ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(distribution.rangeCount, 1)
    }

    /// The on-canvas drag-drop absorb FALLBACK (no spatial drop target
    /// recorded) overlap-tests the todo's dropped range against the DRAWN
    /// slot: a drop inside the traveled parent's projected slot absorbs, and
    /// the mint-frame slot — where the canvas draws nothing — absorbs
    /// nothing.
    func testCanvasDropFallbackAbsorbsIntoTraveledParentDrawnSlot() throws {
        let fixture = try makeTraveledInstance()
        let todoID = UUID(uuidString: "18718700-0000-0000-0000-000000000006")!

        let droppedRange = Event.TimeRange(start: nyDate(10, 16, 15), end: nyDate(10, 16, 45))
        let parent = CalendarPageView.canvasDropAbsorbParent(
            candidates: [fixture.instance],
            droppedRange: droppedRange,
            excluding: todoID,
            calendar: ny
        )
        XCTAssertEqual(parent?.id, fixture.instance.id,
                       "a drop overlapping the drawn slot resolves the traveled parent")

        let rawSlotRange = Event.TimeRange(
            start: fixture.raw.start.addingTimeInterval(15 * 60),
            end: fixture.raw.start.addingTimeInterval(45 * 60)
        )
        XCTAssertNil(
            CalendarPageView.canvasDropAbsorbParent(
                candidates: [fixture.instance],
                droppedRange: rawSlotRange,
                excluding: todoID,
                calendar: ny
            ),
            "the mint-frame slot draws nothing — no false absorb there"
        )
    }

    // MARK: - gh#204 — hidden achievements (AchievementCatalog)

    /// Habit-streak day sets must bucket a traveled instance on its drawn
    /// (nominal) day: projected days {10,11,12} form the 3-day runs below,
    /// raw days {9,11,12} do not.
    func testHabitStreakDaySetsBucketTraveledInstanceOnProjectedDay() throws {
        let sleep = try makeTraveledTypedInstance(type: "Sleep", month: 8, day: 10)
        let gym = try makeTraveledTypedInstance(type: "Gym", month: 8, day: 10)
        let events = [
            sleep.instance,
            plainEvent(type: "Sleep", month: 8, day: 11),
            plainEvent(type: "Sleep", month: 8, day: 12),
            gym.instance,
            plainEvent(type: "Gym", month: 8, day: 11),
            plainEvent(type: "Gym", month: 8, day: 12)
        ]
        let ids = Set(AchievementCatalog.makeFunnyHiddenAchievements(
            events: events, logs: [], calendar: ny, now: nyDate(20)
        ).map(\.id))
        XCTAssertTrue(ids.contains("hidden_steady_sleep"))
        XCTAssertTrue(ids.contains("hidden_workout_streak"))
    }

    /// The shared range pool feeding the weekday/instant patterns must be
    /// render-frame: the traveled instance's stored start sits on a Sunday
    /// (NY Aug 9) while the canvas draws it on Monday Aug 10 — a raw pool
    /// would award Weekend Warrior for a weekend the user never saw booked.
    func testHiddenAchievementRangePoolUsesRenderFrame() throws {
        let traveled = try makeTraveledTypedInstance(type: "Study", month: 8, day: 10)
        XCTAssertEqual(ny.component(.weekday, from: traveled.raw.start), 1, "stored start is a Sunday")
        XCTAssertEqual(ny.component(.weekday, from: traveled.projected.start), 2, "drawn start is a Monday")
        let saturday = plainEvent(type: "Study", month: 8, day: 8, startHour: 10)

        let ids = Set(AchievementCatalog.makeFunnyHiddenAchievements(
            events: [traveled.instance, saturday], logs: [], calendar: ny, now: nyDate(20)
        ).map(\.id))
        XCTAssertFalse(ids.contains("hidden_weekend"),
                       "projected weekdays are {Mon, Sat} — only the raw frame contains a Sunday")

        // Positive control: an actual Sunday event earns the badge, so the
        // absence above is the projection's doing, not unreachability.
        let sunday = plainEvent(type: "Study", month: 8, day: 16, startHour: 10)
        let withSunday = Set(AchievementCatalog.makeFunnyHiddenAchievements(
            events: [traveled.instance, saturday, sunday], logs: [], calendar: ny, now: nyDate(20)
        ).map(\.id))
        XCTAssertTrue(withSunday.contains("hidden_weekend"))
    }

    /// Slam-dunk / well-rested unlock dates are display dates and must be the
    /// projected instants. (The raw well-rested range still qualifies on
    /// duration — only the DATE discriminates the frames there.)
    func testHabitRewardUnlockDatesUseRenderFrame() throws {
        let exercise = try makeTraveledTypedInstance(type: "Exercise", month: 8, day: 10)
        let sleep = try makeTraveledTypedInstance(type: "Sleep", month: 8, day: 10, startHour: 0, durationHours: 8)
        let byID = Dictionary(uniqueKeysWithValues: AchievementCatalog.makeFunnyHiddenAchievements(
            events: [exercise.instance, sleep.instance], logs: [], calendar: ny, now: nyDate(20)
        ).map { ($0.id, $0) })
        XCTAssertEqual(byID["hidden_slamdunk"]?.unlockedAt, exercise.projected.start)
        XCTAssertEqual(byID["hidden_well_rested"]?.unlockedAt, sleep.projected.start)
    }

    /// The festive badge's special-day membership must test the drawn day:
    /// this instance is drawn on Valentine's Day (NY Feb 14, a holiday in
    /// both language tables) while its stored instant sits on plain Feb 13.
    func testFestiveSpecialDayUsesRenderFrameDay() throws {
        let traveled = try makeTraveledTypedInstance(type: "Study", month: 2, day: 14)
        // Self-validating preconditions — the annotation table is consumed
        // data, not something this test controls.
        XCTAssertTrue(CalendarAnnotations.hasAnyAnnotation(on: traveled.projected.start, calendar: ny))
        XCTAssertFalse(CalendarAnnotations.hasAnyAnnotation(on: traveled.raw.start, calendar: ny))

        let festive = AchievementCatalog.makeFestive(
            events: [traveled.instance], logs: [], calendar: ny, now: nyDate(20)
        )
        XCTAssertEqual(festive?.unlockedAt, traveled.projected.start,
                       "earned via the drawn special day — a raw read lands on plain Feb 13 and earns nothing")
    }

    // MARK: - gh#204 — remaining route seeds

    /// The delete confirmation's whole-series fallback seed must resolve a
    /// display range (a raw instant misses the nominal-day key — the blank
    /// shape gh#187 removed elsewhere). Production reaches this seed only
    /// with series templates, where projection is identity; the traveled
    /// input pins the seed's frame contract itself.
    func testDeleteFallbackOccurrenceSeedUsesRenderFrame() throws {
        let fixture = try makeTraveledInstance()
        let seed = EditCalendarEventView.fallbackDeleteOccurrenceDate(for: fixture.instance, calendar: ny)
        XCTAssertEqual(seed, fixture.projected.start)
        XCTAssertEqual(
            calendarOccurrenceDisplayRange(event: fixture.instance, occurrenceDate: seed, calendar: ny),
            fixture.projected
        )
        XCTAssertNil(
            calendarOccurrenceDisplayRange(event: fixture.instance, occurrenceDate: fixture.raw.start, calendar: ny),
            "a raw-seeded anchor misses the nominal-day key"
        )

        let series = makeSeriesTemplate(startDay: 3)
        let templateSeed = EditCalendarEventView.fallbackDeleteOccurrenceDate(for: series, calendar: ny)
        XCTAssertEqual(templateSeed, series.primaryTimeRange?.start,
                       "identity for the templates that actually reach this branch")
        XCTAssertNotNil(calendarOccurrenceDisplayRange(event: series, occurrenceDate: templateSeed, calendar: ny),
                        "the seed resolves the series' own occurrence")
    }

    /// The recurring-series settings list: editor seed and ordering are
    /// render-frame. The traveled input pins the seed's frame contract; the
    /// template pair pins identity + resolvability for the population the
    /// list actually holds.
    func testRecurringSeriesListSeedsRenderFrameOccurrenceDate() throws {
        let fixture = try makeTraveledInstance()
        XCTAssertEqual(
            CalendarRecurringSeriesListView.editorSeedOccurrenceDate(for: fixture.instance, calendar: ny),
            fixture.projected.start
        )

        let early = makeSeriesTemplate(startDay: 3)
        let late = makeSeriesTemplate(startDay: 5)
        let seed = CalendarRecurringSeriesListView.editorSeedOccurrenceDate(for: early, calendar: ny)
        XCTAssertEqual(seed, early.primaryTimeRange?.start)
        XCTAssertNotNil(calendarOccurrenceDisplayRange(event: early, occurrenceDate: seed, calendar: ny))

        let sorted = CalendarRecurringSeriesListView.sortedSeriesList(
            [late, fixture.instance, early], calendar: ny
        )
        XCTAssertEqual(sorted.map(\.id), [early.id, late.id],
                       "detached instances are filtered out; templates order by start")
    }

    // MARK: - gh#208 helpers

    /// Store-backed fixture for the EventStore / agent-tool sites: fresh
    /// suite + storage per call, torn down before returning.
    private func withStore(_ body: (EventStore) throws -> Void) throws {
        let suiteName = "CalendarReadSideProjectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        try body(store)
    }

    private func decodeJSONObject(
        _ raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(raw.data(using: .utf8), "result not UTF-8: \(raw)", file: file, line: line)
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            "result not a JSON object: \(raw)", file: file, line: line
        )
    }

    /// Formatter shaped like AgentToolRunner's display formatter (medium
    /// date / short time, ambient locale + time zone) so the JSON string
    /// assertions compare rendered instants, not formatter trivia.
    private var agentDisplayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    // MARK: - gh#208 — wanna completion (EventStore)

    /// The "what's happening right now" selector must run over the DRAWN
    /// slots: an instant inside the projected range selects the traveled
    /// instance, an instant inside only the mint-frame slot selects nothing
    /// (no block is drawn there).
    func testCurrentlyActiveCalendarEventSelectsTraveledInstanceByDrawnSlot() throws {
        let fixture = try makeTraveledInstance()
        try withDefaultTimeZonePinnedToNewYork {
            try withStore { store in
                store.addCalendarEvent(fixture.instance)

                let duringDrawnSlot = fixture.projected.start.addingTimeInterval(1800)
                XCTAssertEqual(
                    store.currentlyActiveCalendarEvent(at: duringDrawnSlot)?.id,
                    fixture.instance.id,
                    "now inside the PROJECTED slot selects the drawn block"
                )

                let duringRawSlotOnly = fixture.raw.start.addingTimeInterval(1800)
                XCTAssertNil(
                    store.currentlyActiveCalendarEvent(at: duringRawSlotOnly),
                    "now inside only the mint-frame slot must select nothing — the canvas draws no block there"
                )

                // Identity control: a never-traveled event is still found
                // inside its own slot.
                let plain = plainEvent(type: "Study", month: 8, day: 20)
                store.addCalendarEvent(plain)
                XCTAssertEqual(
                    store.currentlyActiveCalendarEvent(at: nyDate(20, 16, 30))?.id,
                    plain.id
                )
            }
        }
    }

    /// Cross-midnight traveled variant: the drawn slot straddles the NY
    /// midnight, so the projected START day and END day reduce to DIFFERENT
    /// occurrence dayKeys — the discrimination the same-day fixture cannot
    /// make.
    private func makeTraveledCrossMidnightInstance() throws -> (instance: Event, raw: Event.TimeRange, projected: Event.TimeRange) {
        let start = apiaDate(10, 16)
        let end = apia.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 17, minute: 30))!
        let instance = Event(
            id: UUID(uuidString: "18718700-0000-0000-0000-000000000006")!,
            title: "TraveledCrossMidnightProbe",
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: "Study",
            recurrenceParentId: UUID(uuidString: "18718700-0000-0000-0000-000000000007")!,
            recurrenceInstanceDate: apia.startOfDay(for: start),
            recurrenceInstanceDayKey: 20_260_810
        )
        let raw = try XCTUnwrap(instance.primaryTimeRange)
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertEqual(projected.start, nyDate(10, 23), "drawn slot opens late on the nominal day")
        XCTAssertEqual(projected.end, nyDate(11, 0, 30), "and closes past the NY midnight")
        XCTAssertNotEqual(ny.startOfDay(for: projected.start), ny.startOfDay(for: projected.end),
                          "start-day and end-day must differ or a START/END stamp slip is invisible")
        XCTAssertNotEqual(projected, raw,
                          "fixture must actually travel — identical frames make every assertion vacuous")
        return (instance, raw, projected)
    }

    /// The stamp anchors on the projected START's day specifically: with a
    /// drawn slot straddling midnight, an END-derived stamp would key the
    /// NEXT day — a completion no lookup for this occurrence resolves.
    func testCompleteWannaCrossMidnightStampsDrawnStartDay() throws {
        let fixture = try makeTraveledCrossMidnightInstance()
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "America/New_York")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }
        try withDefaultTimeZonePinnedToNewYork {
            try withStore { store in
                store.addCalendarEvent(fixture.instance)
                let wanna = Event(title: "cross-midnight wanna probe")
                store.addWithAutoPlacement(wanna)

                store.completeWanna(wanna, now: fixture.projected.start.addingTimeInterval(1800))

                let startContext = CalendarEventOccurrenceContext(
                    eventID: fixture.instance.id,
                    occurrenceDate: fixture.projected.start,
                    occurrenceID: nil,
                    isAllDay: false,
                    source: .timelineTap
                )
                let record = try XCTUnwrap(store.logRecord(for: startContext),
                                           "the completion keys on the drawn START day")
                XCTAssertEqual(record.id.dayKey, 20_260_810)
                XCTAssertEqual(
                    record.timelineItems.compactMap { $0.wannaCompletionValue?.wannaEventID },
                    [wanna.id]
                )

                let endContext = CalendarEventOccurrenceContext(
                    eventID: fixture.instance.id,
                    occurrenceDate: fixture.projected.end,
                    occurrenceID: nil,
                    isAllDay: false,
                    source: .timelineTap
                )
                XCTAssertNil(store.logRecord(for: endContext),
                             "an END-derived stamp would key the next day — a record no reader resolves")
            }
        }
    }

    /// Boundary contract pin (deliberate, not an endorsement): containment
    /// is CLOSED at both ends, so at the exact instant one block ends and
    /// the next begins BOTH contain `now`, and selection falls to
    /// rawCalendarEvents array order — the earlier-INSERTED block wins the
    /// shared instant (here: the just-ended one). These comparators predate
    /// gh#208; this test freezes the current contract so any future change
    /// to the comparison or the ordering is a conscious decision with a red
    /// test, not a drive-by.
    func testCurrentlyActiveCalendarEventBoundaryIsClosedAndArrayOrdered() throws {
        try withDefaultTimeZonePinnedToNewYork {
            try withStore { store in
                let first = plainEvent(type: "Study", month: 8, day: 20, startHour: 10)
                let second = plainEvent(type: "Study", month: 8, day: 20, startHour: 11)
                store.addCalendarEvent(first)
                store.addCalendarEvent(second)

                XCTAssertEqual(first.primaryTimeRange?.end, second.primaryTimeRange?.start,
                               "back-to-back by construction — the shared instant exists")
                XCTAssertEqual(
                    store.currentlyActiveCalendarEvent(at: nyDate(20, 11))?.id,
                    first.id,
                    "closed intervals + array order: the earlier-inserted, just-ended block wins the shared instant"
                )
                XCTAssertEqual(store.currentlyActiveCalendarEvent(at: nyDate(20, 10, 59))?.id, first.id)
                XCTAssertEqual(store.currentlyActiveCalendarEvent(at: nyDate(20, 11, 1))?.id, second.id)
            }
        }
    }

    /// completeWanna's stamped occurrenceDate must reduce to the SAME
    /// occurrence key every reader mints from the projected start (gh#187
    /// route seeds): the written log record is found at the drawn day and
    /// absent at the mint-frame day.
    func testCompleteWannaStampsProjectedOccurrenceKeyForTraveledActiveEvent() throws {
        let fixture = try makeTraveledInstance()
        let priorOverride = CalendarOccurrenceKey.referenceTimeZoneOverride
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "America/New_York")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = priorOverride }
        try withDefaultTimeZonePinnedToNewYork {
            try withStore { store in
                store.addCalendarEvent(fixture.instance)
                let wanna = Event(title: "traveled wanna probe")
                store.addWithAutoPlacement(wanna)

                store.completeWanna(wanna, now: fixture.projected.start.addingTimeInterval(1800))

                let projectedContext = CalendarEventOccurrenceContext(
                    eventID: fixture.instance.id,
                    occurrenceDate: fixture.projected.start,
                    occurrenceID: nil,
                    isAllDay: false,
                    source: .timelineTap
                )
                let record = try XCTUnwrap(
                    store.logRecord(for: projectedContext),
                    "the completion must be keyed where every reader looks: the projected day"
                )
                XCTAssertEqual(
                    record.timelineItems.compactMap { $0.wannaCompletionValue?.wannaEventID },
                    [wanna.id]
                )
                XCTAssertEqual(record.id.dayKey, 20_260_810,
                               "occurrence dayKey is the drawn nominal day")

                let rawContext = CalendarEventOccurrenceContext(
                    eventID: fixture.instance.id,
                    occurrenceDate: fixture.raw.start,
                    occurrenceID: nil,
                    isAllDay: false,
                    source: .timelineTap
                )
                XCTAssertNil(
                    store.logRecord(for: rawContext),
                    "a raw-stamped write would land here — a day no reader ever looks up"
                )

                XCTAssertTrue(
                    store.events.first { $0.id == wanna.id }?.isDone ?? false,
                    "the wanna itself still completes"
                )
            }
        }
    }

    /// The absorb auto-complete cascade fires on the parent's DRAWN end:
    /// dropping a todo onto a traveled parent whose drawn block is still
    /// upcoming must not mark the todo done, even though the mint-frame end
    /// already passed.
    func testAbsorbAutoCompleteGateReadsTraveledParentDrawnEnd() throws {
        let fixture = try makeTraveledInstance()
        try withDefaultTimeZonePinnedToNewYork {
            try withStore { store in
                store.addCalendarEvent(fixture.instance)
                var todo = Event(
                    title: "absorb probe",
                    timeRanges: [Event.TimeRange(start: nyDate(10, 11), end: nyDate(10, 12))]
                )
                todo.kind = .todo
                store.addCalendarEvent(todo)

                // Between the mint-frame end and the drawn end: the user
                // sees the parent as not-yet-finished.
                store.absorbTodoIntoEvent(
                    todoID: todo.id, parentEventID: fixture.instance.id, now: nyDate(10, 12)
                )
                let absorbed = try XCTUnwrap(store.rawCalendarEvents.first { $0.id == todo.id })
                XCTAssertEqual(absorbed.absorbedIntoEventID, fixture.instance.id)
                XCTAssertFalse(absorbed.isDone,
                               "drawn slot has not ended — raw end passing must not auto-complete")

                // Positive control: past the drawn end the cascade fires.
                var lateTodo = Event(
                    title: "absorb probe late",
                    timeRanges: [Event.TimeRange(start: nyDate(10, 11), end: nyDate(10, 12))]
                )
                lateTodo.kind = .todo
                store.addCalendarEvent(lateTodo)
                store.absorbTodoIntoEvent(
                    todoID: lateTodo.id, parentEventID: fixture.instance.id, now: nyDate(11, 12)
                )
                let absorbedLate = try XCTUnwrap(store.rawCalendarEvents.first { $0.id == lateTodo.id })
                XCTAssertTrue(absorbedLate.isDone, "drawn end passed — the cascade still works")
            }
        }
    }

    // MARK: - gh#208 — agent-facing readers (AgentTools)

    /// The agent is a reader too: listCalendarEvents must window AND print
    /// the traveled instance at its projected slot — the times the canvas
    /// draws are the times the model is told.
    func testAgentListCalendarEventsReturnsProjectedTimesForTraveledInstance() throws {
        let fixture = try makeTraveledInstance()
        try withDefaultTimeZonePinnedToNewYork {
            try withStore { store in
                store.addCalendarEvent(fixture.instance)

                let raw = AgentToolRunner.execute(
                    toolName: "listCalendarEvents",
                    arguments: "{\"startDate\": \"2026-08-10\"}",
                    store: store
                )
                let object = try decodeJSONObject(raw)
                let events = try XCTUnwrap(object["events"] as? [[String: Any]])
                XCTAssertEqual(events.count, 1,
                               "a window opening on the drawn day admits the traveled instance; the raw frame would drop it")
                let item = try XCTUnwrap(events.first)

                let display = agentDisplayFormatter
                XCTAssertEqual(item["startTime"] as? String,
                               display.string(from: fixture.projected.start),
                               "the model is told the time the canvas draws")
                XCTAssertEqual(item["endTime"] as? String,
                               display.string(from: fixture.projected.end))
                XCTAssertNotEqual(item["startTime"] as? String,
                                  display.string(from: fixture.raw.start),
                                  "the raw string names an instant on a day the canvas draws nothing")
            }
        }
    }

    /// getScheduleForDate: the drawn day answers with the instance at its
    /// projected times; the mint-frame day answers empty.
    func testAgentScheduleForDateBucketsTraveledInstanceOnDrawnDay() throws {
        let fixture = try makeTraveledInstance()
        try withDefaultTimeZonePinnedToNewYork {
            try withStore { store in
                store.addCalendarEvent(fixture.instance)

                let drawnDay = try decodeJSONObject(AgentToolRunner.execute(
                    toolName: "getScheduleForDate",
                    arguments: "{\"date\": \"2026-08-10\"}",
                    store: store
                ))
                let drawnEvents = try XCTUnwrap(drawnDay["calendarEvents"] as? [[String: Any]])
                XCTAssertEqual(drawnEvents.count, 1, "the drawn day holds the block")
                let display = agentDisplayFormatter
                XCTAssertEqual(drawnEvents.first?["startTime"] as? String,
                               display.string(from: fixture.projected.start))
                XCTAssertEqual(drawnEvents.first?["endTime"] as? String,
                               display.string(from: fixture.projected.end))

                let mintDay = try decodeJSONObject(AgentToolRunner.execute(
                    toolName: "getScheduleForDate",
                    arguments: "{\"date\": \"2026-08-09\"}",
                    store: store
                ))
                let mintEvents = try XCTUnwrap(mintDay["calendarEvents"] as? [[String: Any]])
                XCTAssertTrue(mintEvents.isEmpty,
                              "the mint-frame day draws nothing, so the schedule reports nothing")
            }
        }
    }

    /// getUserData export prints the projected times. (Its cutoff FILTER
    /// frame is declared unpinnable in the header — the cutoff anchors to a
    /// bare Date() no fixture can bracket deterministically.)
    func testAgentUserDataExportPrintsProjectedTimes() throws {
        let fixture = try makeTraveledInstance()
        try withDefaultTimeZonePinnedToNewYork {
            try withStore { store in
                store.addCalendarEvent(fixture.instance)

                let object = try decodeJSONObject(AgentToolRunner.execute(
                    toolName: "getUserData",
                    arguments: "{\"days\": 36500}",
                    store: store
                ))
                let events = try XCTUnwrap(object["calendarEvents"] as? [[String: Any]])
                XCTAssertEqual(events.count, 1)
                let item = try XCTUnwrap(events.first)
                let display = agentDisplayFormatter
                XCTAssertEqual(item["startTime"] as? String,
                               display.string(from: fixture.projected.start))
                XCTAssertEqual(item["endTime"] as? String,
                               display.string(from: fixture.projected.end))
                XCTAssertEqual(item["durationMinutes"] as? Int, 60)
                XCTAssertNotEqual(item["startTime"] as? String,
                                  display.string(from: fixture.raw.start))
            }
        }
    }

    // MARK: - gh#208 — skill analysis (SkillAnalysisService)

    /// The "activity already happened" gate reads the drawn slot: between
    /// the mint-frame end and the drawn end the block is still on the user's
    /// canvas as unfinished, so analysis must wait.
    func testSkillAnalysisEndGateReadsDrawnSlot() throws {
        let fixture = try makeTraveledInstance()
        XCTAssertFalse(
            skillAnalysisEventHasEnded(fixture.instance, now: nyDate(10, 12), calendar: ny),
            "raw end has passed but the drawn block has not ended"
        )
        XCTAssertTrue(
            skillAnalysisEventHasEnded(
                fixture.instance,
                now: fixture.projected.end.addingTimeInterval(1),
                calendar: ny
            ),
            "past the drawn end the gate opens"
        )
        // Identity + rangeless controls.
        let plain = plainEvent(type: "Study", month: 8, day: 12)
        XCTAssertFalse(skillAnalysisEventHasEnded(plain, now: nyDate(12, 16, 30), calendar: ny))
        XCTAssertTrue(skillAnalysisEventHasEnded(plain, now: nyDate(12, 18), calendar: ny))
        XCTAssertFalse(skillAnalysisEventHasEnded(Event(title: "rangeless"), now: nyDate(12, 18), calendar: ny),
                       "no range still means never analyze")
    }

    /// SkillInsight.date buckets on the drawn start — bound to the real
    /// insight-minting path (`parseAndStore`), not a copy of its reduction.
    func testSkillInsightDateBucketsTraveledInstanceOnDrawnDay() throws {
        let fixture = try makeTraveledInstance()
        let suiteName = "CalendarReadSideProjectionTests-Skill-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let insightStore = SkillInsightStore(defaults: defaults)
        let service = SkillAnalysisService(insightStore: insightStore)

        try withDefaultTimeZonePinnedToNewYork {
            try service.parseAndStore(
                "[{\"skill\": \"Focus\", \"points\": 1.0, \"reasoning\": \"probe\"}]",
                event: fixture.instance
            )
            let insight = try XCTUnwrap(insightStore.insights.first)
            XCTAssertEqual(insight.date, fixture.projected.start,
                           "the insight lands on the day the canvas drew the activity")
            XCTAssertNotEqual(insight.date, fixture.raw.start)
        }
    }
}
