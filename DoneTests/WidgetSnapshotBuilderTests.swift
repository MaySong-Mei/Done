import XCTest
@testable import Done

/// Coverage for the widget's App Group payload — the projection that used to
/// live inline in `EventStore.syncWidgetSnapshots` with zero tests (gh#142).
///
/// The window is pinned to a fixed UTC calendar and a fixed "now" so nothing
/// here depends on the machine's time zone or on when the suite runs.
final class WidgetSnapshotBuilderTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// 2026-03-10 00:00 UTC — a plain mid-month Tuesday, no DST edge.
    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
    }

    private func day(_ offset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let start = calendar.date(byAdding: .day, value: offset, to: today)!
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start)!
    }

    private func build(_ events: [Event]) -> [SharedEventSnapshot] {
        let window = WidgetSnapshotBuilder.window(now: today, calendar: calendar)
        return WidgetSnapshotBuilder.snapshots(
            events: events,
            windowStart: window.start,
            windowEnd: window.end,
            calendar: calendar,
            colorHex: { _ in "#0A84FF" }
        )
    }

    // MARK: - Absorbed todos (the canvasRenderable audit's missed consumer)

    func testAbsorbedTodoIsExcludedFromSnapshots() {
        let parent = Event(
            title: "Deep Work",
            timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 11))],
            type: "Work"
        )
        var absorbed = Event(
            title: "Write the memo",
            timeRanges: [.init(start: day(0, hour: 9, minute: 30), end: day(0, hour: 10))],
            kind: .todo
        )
        absorbed.absorbedIntoEventID = parent.id

        let titles = build([parent, absorbed]).map(\.title)
        XCTAssertEqual(titles, ["Deep Work"],
                       "An absorbed todo is hidden on the canvas, so it must be hidden on the widget")
    }

    func testReleasedTodoReappearsInSnapshots() {
        // Guards against a filter that drops todos wholesale rather than
        // dropping *absorbed* ones — the test above would pass either way.
        var todo = Event(
            title: "Write the memo",
            timeRanges: [.init(start: day(0, hour: 9, minute: 30), end: day(0, hour: 10))],
            kind: .todo
        )
        todo.absorbedIntoEventID = nil

        XCTAssertEqual(build([todo]).map(\.title), ["Write the memo"])
    }

    // MARK: - Per-occurrence identity

    func testRecurringOccurrencesGetDistinctIDsAndShareEventID() {
        let series = Event(
            title: "Standup",
            timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 9, minute: 15))],
            repeatUnit: .day,
            type: "Work"
        )

        let snapshots = build([series])

        // Window is [today-1, today+7): the series starts today, so today…+6.
        XCTAssertEqual(snapshots.count, 7)
        XCTAssertEqual(Set(snapshots.map(\.id)).count, snapshots.count,
                       "Every occurrence needs its own id — sharing event.id collides any id-keyed ForEach")
        XCTAssertEqual(Set(snapshots.map(\.resolvedEventID)), [series.id],
                       "…while still resolving back to the series event")
    }

    func testOccurrenceIDsAreDeterministicAcrossRebuilds() {
        let series = Event(
            title: "Standup",
            timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 9, minute: 15))],
            repeatUnit: .day
        )
        XCTAssertEqual(build([series]).map(\.id), build([series]).map(\.id),
                       "Re-deriving the payload must not churn identities (widget rows would tear down)")
    }

    func testTwoRangesSharingAStartGetDistinctIDs() {
        // The end date is deliberately not part of the id, which leaves
        // `(event, start)` non-unique for one shape: two ranges of the SAME
        // event starting at the same instant. Without a tiebreaker both mint
        // the identical UUID — the duplicate-id `ForEach` key gh#142 is about,
        // reintroduced by the very fix that removed it.
        let event = Event(
            title: "Night Shift",
            timeRanges: [
                .init(start: day(0, hour: 22), end: day(1)),
                .init(start: day(0, hour: 22), end: day(1, hour: 4))
            ],
            type: "Work"
        )

        let snapshots = build([event])
        XCTAssertEqual(snapshots.count, 2, "Both blocks are on the canvas, so both are on the widget")
        XCTAssertEqual(Set(snapshots.map(\.id)).count, 2, "Same start must not collapse two occurrences into one id")
        XCTAssertEqual(Set(snapshots.map(\.endDate)), [day(1), day(1, hour: 4)])
        XCTAssertEqual(build([event]).map(\.id), snapshots.map(\.id),
                       "…and the tiebreaker is deterministic, not insertion-order luck")
    }

    func testSameStartIsReachableByDroppingOneSegmentOntoTheOther() {
        // Not a hypothetical shape. `calendarUpdatedRangesAfterDrop` is the
        // live canvas-drag commit (`CalendarPageView` calls it on every event
        // drop, then writes the result straight into `rawCalendarEvents`), and
        // it replaces the dragged range in place without ever checking whether
        // the new start already belongs to a sibling range. Drag the
        // after-midnight half of a cross-midnight event back onto its own
        // evening half and the event holds two ranges with one start.
        let evening = Event.TimeRange(start: day(0, hour: 22), end: day(1))
        let morning = Event.TimeRange(start: day(1), end: day(1, hour: 6))
        let ranges = calendarUpdatedRangesAfterDrop(
            existingRanges: [evening, morning],
            draggedRange: morning,
            droppedRange: Event.TimeRange(start: day(0, hour: 22), end: day(1, hour: 4)),
            occurrenceID: nil
        )
        XCTAssertEqual(ranges.map(\.start), [day(0, hour: 22), day(0, hour: 22)],
                       "Precondition: the drag really does produce two ranges with one start")

        let snapshots = build([Event(title: "Night Shift", timeRanges: ranges)])
        XCTAssertEqual(Set(snapshots.map(\.id)).count, snapshots.count,
                       "unique == occurrences is the invariant the on-device log asserts")
    }

    func testEveryPayloadKeepsUniqueIDsAcrossMixedShapes() {
        // The invariant `syncWidgetSnapshots` logs as `unique == occurrences`,
        // over one payload holding all the shapes at once.
        let series = Event(
            title: "Standup",
            timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 9, minute: 15))],
            repeatUnit: .day
        )
        let crossMidnight = Event(
            title: "Night Shift",
            timeRanges: [
                .init(start: day(0, hour: 22), end: day(1)),
                .init(start: day(1), end: day(1, hour: 6))
            ]
        )
        let sameStartTwice = Event(
            title: "Merged",
            timeRanges: [
                .init(start: day(2, hour: 14), end: day(2, hour: 15)),
                .init(start: day(2, hour: 14), end: day(2, hour: 16))
            ]
        )
        let allDay = Event(title: "Holiday", timeRanges: [.init(start: day(3), end: day(4))], isAllDay: true)

        let snapshots = build([series, crossMidnight, sameStartTwice, allDay])
        XCTAssertEqual(Set(snapshots.map(\.id)).count, snapshots.count)
    }

    func testOccurrenceIDIsRecomputableFromTheSnapshot() {
        let series = Event(
            title: "Standup",
            timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 9, minute: 15))],
            repeatUnit: .day
        )
        for snapshot in build([series]) {
            XCTAssertEqual(
                snapshot.id,
                SharedEventSnapshot.occurrenceID(
                    eventID: snapshot.resolvedEventID,
                    occurrenceStart: snapshot.startDate
                ),
                "The id is a composite key, not an opaque random — it must be reproducible"
            )
        }
    }

    func testOrdinalZeroIsByteIdenticalToThePlainCompositeKey() {
        // The ordinal must be a pure extension: every id already written into a
        // live App Group blob was minted without one, so ordinal 0 has to
        // reproduce the old value exactly or the first post-upgrade rewrite
        // re-keys every row and the widget tears its whole list down.
        let eventID = UUID()
        let start = day(0, hour: 9)
        XCTAssertEqual(
            SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: start, ordinal: 0),
            SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: start)
        )
        XCTAssertNotEqual(
            SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: start, ordinal: 1),
            SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: start)
        )
    }

    func testOccurrenceIDSurvivesNonFiniteAndAbsurdStarts() {
        // The clamp exists for corrupt/hand-edited blobs, not for
        // `.distantFuture` (~6.4e13 ms, five orders of magnitude short of
        // Int64.max). Reaching `Int64(_:)` with a NaN or an infinity traps, so
        // these must return rather than crash.
        let eventID = UUID()
        for interval in [Double.nan, .infinity, -.infinity, 1.0e30, -1.0e30] {
            _ = SharedEventSnapshot.occurrenceID(
                eventID: eventID,
                occurrenceStart: Date(timeIntervalSince1970: interval)
            )
        }
        XCTAssertNotEqual(
            SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: .distantFuture),
            SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: .distantPast),
            "…and dates that are merely extreme, not invalid, still separate normally"
        )
    }

    func testOccurrenceIDDiffersForAdjacentDaysAndMatchesForSameStart() {
        let eventID = UUID()
        let a = SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: day(0, hour: 9))
        let b = SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: day(1, hour: 9))
        let aAgain = SharedEventSnapshot.occurrenceID(eventID: eventID, occurrenceStart: day(0, hour: 9))
        let other = SharedEventSnapshot.occurrenceID(eventID: UUID(), occurrenceStart: day(0, hour: 9))

        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, aAgain)
        XCTAssertNotEqual(a, other, "Different events at the same instant must not collide")
        XCTAssertNotEqual(a, eventID, "…and an occurrence id must not shadow the raw event id")
    }

    func testMultiRangeEventGetsOneDistinctIDPerRange() {
        // The cross-midnight shape: one event, two ranges, both visible in the
        // widget's "today" filter — the pre-fix duplicate-id case most likely
        // to be hit in practice.
        let event = Event(
            title: "Night Shift",
            timeRanges: [
                .init(start: day(0, hour: 22), end: day(1)),
                .init(start: day(1), end: day(1, hour: 6))
            ],
            type: "Work"
        )

        let snapshots = build([event])
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertNotEqual(snapshots[0].id, snapshots[1].id)
        XCTAssertEqual(Set(snapshots.map(\.resolvedEventID)), [event.id])
    }

    // MARK: - Per-occurrence done state

    func testSingleOccurrenceDoneAppliesToThatDayOnly() throws {
        let series = Event(
            title: "Standup",
            timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 9, minute: 15))],
            repeatUnit: .day,
            type: "Work"
        )
        // Marking one occurrence done is modelled as a single-scope edit: the
        // series gains an exception date and a materialized instance carries the
        // done flag. The widget must reflect that split, not the series flag.
        let result = Event.applyEdit(
            series: series,
            occurrenceDate: day(2),
            scope: .single,
            edit: { instance in
                instance.isDone = true
                instance.status = .completed
            },
            calendar: calendar
        )
        let updatedSeries = try XCTUnwrap(result.updatedSeries)
        let instance = try XCTUnwrap(result.exceptionInstance)

        let snapshots = build([updatedSeries, instance])

        XCTAssertEqual(snapshots.count, 7, "The done day is served by the instance, not duplicated")
        let doneDays = snapshots.filter(\.isDone).map(\.startDate)
        XCTAssertEqual(doneDays, [day(2, hour: 9)],
                       "Exactly the edited occurrence is done")
        XCTAssertEqual(Set(snapshots.map(\.startDate)).count, 7,
                       "…and no day is missing or doubled")
    }

    func testSeriesLevelDoneStillPropagatesToUnmaterializedOccurrences() {
        // Parity lock with the canvas: `EventBlock` renders an un-exceptioned
        // occurrence from the series' own `isDone`. If that ever becomes a
        // per-occurrence resolution on the canvas, this test should flip too.
        let series = Event(
            title: "Vitamins",
            timeRanges: [.init(start: day(0, hour: 8), end: day(0, hour: 8, minute: 5))],
            repeatUnit: .day,
            isDone: true,
            kind: .todo
        )
        XCTAssertTrue(build([series]).allSatisfy(\.isDone))
    }

    // MARK: - Window boundaries

    func testWindowIsYesterdayThroughSevenDaysAhead() {
        let window = WidgetSnapshotBuilder.window(now: day(0, hour: 13, minute: 37), calendar: calendar)
        XCTAssertEqual(window.start, day(-1))
        XCTAssertEqual(window.end, day(7))
    }

    func testEventEndingExactlyAtWindowStartIsExcluded() {
        let event = Event(
            title: "Two days ago",
            timeRanges: [.init(start: day(-2, hour: 22), end: day(-1))]
        )
        XCTAssertTrue(build([event]).isEmpty,
                      "Half-open window: an occurrence that ends at the boundary has no overlap")
    }

    func testEventStraddlingWindowStartIsIncluded() {
        let event = Event(
            title: "Straddler",
            timeRanges: [.init(start: day(-2, hour: 23), end: day(-1, hour: 1))]
        )
        XCTAssertEqual(build([event]).map(\.title), ["Straddler"])
    }

    func testEventStartingExactlyAtWindowEndIsExcluded() {
        let event = Event(
            title: "Day seven",
            timeRanges: [.init(start: day(7), end: day(7, hour: 1))]
        )
        XCTAssertTrue(build([event]).isEmpty)
    }

    func testEventInsideTheLastWindowDayIsIncluded() {
        let event = Event(
            title: "Day six",
            timeRanges: [.init(start: day(6, hour: 23), end: day(6, hour: 23, minute: 59))]
        )
        XCTAssertEqual(build([event]).map(\.title), ["Day six"])
    }

    func testRecurringSeriesStopsAtTheWindowEdges() {
        // Series started long ago and ends inside the window: expansion must be
        // clipped on both sides, not run to `repeatEndDate`.
        let series = Event(
            title: "Old habit",
            timeRanges: [.init(start: day(-30, hour: 7), end: day(-30, hour: 8))],
            repeatUnit: .day,
            repeatEndType: .onDate,
            repeatEndDate: day(3)
        )
        let starts = build([series]).map(\.startDate)
        XCTAssertEqual(starts, [
            day(-1, hour: 7), day(0, hour: 7), day(1, hour: 7), day(2, hour: 7), day(3, hour: 7)
        ])
    }

    // MARK: - Payload ordering & shape

    func testSnapshotsAreOrderedByStartRegardlessOfInputOrder() {
        let late = Event(title: "Late", timeRanges: [.init(start: day(0, hour: 18), end: day(0, hour: 19))])
        let early = Event(title: "Early", timeRanges: [.init(start: day(0, hour: 8), end: day(0, hour: 9))])
        XCTAssertEqual(build([late, early]).map(\.title), ["Early", "Late"])
        XCTAssertEqual(build([early, late]).map(\.title), ["Early", "Late"])
    }

    func testInterruptRelationIsCarriedForParentLookup() throws {
        let parent = Event(title: "Deep Work", timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 11))])
        var child = Event(title: "Phone call", timeRanges: [.init(start: day(0, hour: 10), end: day(0, hour: 10, minute: 15))])
        child.displayKind = .interrupt
        child.interruptRelation = EventInterruptRelation(parentEventID: parent.id, occurrenceDate: day(0))

        let snapshots = build([parent, child])
        let childSnapshot = try XCTUnwrap(snapshots.first { $0.title == "Phone call" })
        XCTAssertEqual(childSnapshot.isInterrupt, true)
        // The widget resolves the parent through `resolvedEventID`, so the
        // relation's `parentEventID` must keep pointing at the EVENT id.
        XCTAssertEqual(childSnapshot.parentEventID, parent.id)
        XCTAssertNotNil(snapshots.first { $0.resolvedEventID == childSnapshot.parentEventID })
    }

    func testStackTodoWithNoTimeRangesProducesNothing() {
        let stackTodo = Event(title: "Someday", kind: .todo)
        XCTAssertTrue(build([stackTodo]).isEmpty)
    }

    // MARK: - App Group blob compatibility

    func testLegacyBlobWithoutEventIDStillResolvesAnEventID() throws {
        // A widget built after this change can be asked to read a payload the
        // PREVIOUS app version wrote (the App Group blob survives the upgrade
        // until the app runs once). That blob has no `eventID` key.
        let legacyID = UUID()
        let json = """
        [{"id":"\(legacyID.uuidString)","title":"Legacy","type":"Work",
          "startDate":760000000,"endDate":760003600,"isAllDay":false,"isDone":false}]
        """
        let decoded = try JSONDecoder().decode([SharedEventSnapshot].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].eventID)
        XCTAssertEqual(decoded[0].resolvedEventID, legacyID,
                       "resolvedEventID falls back to the legacy id-is-the-event-id convention")
    }

    func testHostAppIsActuallyEntitledToTheAppGroup() {
        // The gh#142 the user could SEE. Commit 3fe4e3a emptied the
        // `com.apple.security.application-groups` array in Done/Done.entitlements
        // while DoneWidget kept the group, so every snapshot the app wrote
        // landed in the app's own Library/Preferences and the widget — reading
        // the real shared container — showed "No more events" forever.
        //
        // This runs in the Done.app test host, so it reads the shipping app's
        // entitlements: empty the array again and this goes red. Assert both the
        // probe and the suite, because only the probe can tell them apart —
        // `UserDefaults(suiteName:)` happily returns a working (private) suite
        // for a group this process has no claim to.
        XCTAssertTrue(SharedWidgetData.isMemberOfAppGroup,
                      "Done/Done.entitlements must list \(SharedWidgetData.appGroupID)")
        XCTAssertNotNil(SharedWidgetData.sharedDefaults)
        XCTAssertNotNil(
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedWidgetData.appGroupID
            ),
            "…and the container the widget reads must be reachable from the app"
        )
    }

    func testWidgetGroupIDMatchesTheWidgetsOwnEntitlement() {
        // Two entitlement files, one string: a typo in either is invisible at
        // runtime (both sides just get their own private suite).
        XCTAssertEqual(SharedWidgetData.appGroupID, "group.wordless.shiqiliuyifanmei.app")
    }

    // MARK: - Canvas-renderable predicate is one rule, not two

    @MainActor
    func testBuilderAndCanvasFilterAgreeOnMembership() {
        // gh#142's head bug was a consumer that missed the canvas filter. Both
        // halves now read `Event.isCanvasRenderable`, and this is the test that
        // notices if one of them stops: give the STORE the raw array and compare
        // what each side keeps.
        let suiteName = "WidgetSnapshotBuilderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)

        let parent = Event(title: "Deep Work", timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 11))])
        var absorbed = Event(
            title: "Write the memo",
            timeRanges: [.init(start: day(0, hour: 9, minute: 30), end: day(0, hour: 10))],
            kind: .todo
        )
        absorbed.absorbedIntoEventID = parent.id
        store.rawCalendarEvents = [parent, absorbed]

        let canvasIDs = Set(store.canvasRenderableCalendarEvents.map(\.id))
        // Deliberately the RAW array: the builder's own guard is the belt to the
        // call site's braces, and it must implement the same rule.
        let widgetIDs = Set(build(store.rawCalendarEvents).map(\.resolvedEventID))

        XCTAssertEqual(canvasIDs, [parent.id])
        XCTAssertEqual(widgetIDs, canvasIDs,
                       "The widget mirrors the canvas — one predicate, not two copies that can drift")
    }

    func testSnapshotSurvivesARoundTripThroughJSON() throws {
        let event = Event(title: "Round trip", timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 10))])
        let snapshots = build([event])
        let data = try JSONEncoder().encode(snapshots)
        let decoded = try JSONDecoder().decode([SharedEventSnapshot].self, from: data)
        XCTAssertEqual(decoded, snapshots)
        XCTAssertEqual(decoded.first?.eventID, event.id)
    }
}

// MARK: - gh#219: the widget's display schedule (pure, shared)

/// Behavioural coverage for `WidgetTimelineSchedule` — the entry list the
/// widget renders a whole day from without spending refresh budget. Same
/// fixed-UTC-calendar discipline as the builder tests above.
final class WidgetTimelineScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// 2026-03-10 00:00 UTC — a plain mid-month Tuesday, no DST edge.
    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
    }

    private func day(_ offset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let start = calendar.date(byAdding: .day, value: offset, to: today)!
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start)!
    }

    private func snap(start: Date, end: Date, allDay: Bool = false, title: String = "t") -> SharedEventSnapshot {
        SharedEventSnapshot(
            id: UUID(), eventID: UUID(), title: title, type: "Work", colorHex: nil,
            startDate: start, endDate: end, isAllDay: allDay, isDone: false
        )
    }

    private func assertStrictlyAscending(_ dates: [Date], file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(dates, dates.dropFirst()) {
            XCTAssertLessThan(a, b, "entry dates must be strictly ascending", file: file, line: line)
        }
    }

    func testEntryDatesCoverEventBoundariesAndEndAtTheDayRollover() {
        let now = day(0, hour: 9)
        let events = [
            snap(start: day(0, hour: 10), end: day(0, hour: 11)),
            snap(start: day(0, hour: 14), end: day(0, hour: 15, minute: 30)),
        ]
        let dates = WidgetTimelineSchedule.entryDates(events: events, now: now, calendar: calendar)

        // The moments `currentEvent`/`nextUpEvent` flip are all entries.
        for boundary in [day(0, hour: 10), day(0, hour: 11), day(0, hour: 14), day(0, hour: 15, minute: 30)] {
            XCTAssertTrue(dates.contains(boundary), "missing display boundary \(boundary)")
        }
        XCTAssertEqual(dates.first, now, "the timeline must start rendering immediately")
        XCTAssertEqual(dates.last, day(1), "the final entry is the day rollover — with .atEnd that is ~one requested refresh per day")
        XCTAssertTrue(dates.allSatisfy { $0 >= now && $0 <= day(1) })
        assertStrictlyAscending(dates)
        XCTAssertLessThanOrEqual(dates.count, WidgetTimelineSchedule.maxEntryCount)
    }

    func testBoundariesOutsideTheCurrentDayWindowAreExcluded() {
        let now = day(0, hour: 9)
        let events = [
            snap(start: day(-1, hour: 23), end: day(-1, hour: 23, minute: 30)),  // fully past
            snap(start: day(0, hour: 8), end: day(0, hour: 9, minute: 30)),      // running now
            snap(start: day(1, hour: 10), end: day(1, hour: 11)),                // tomorrow
        ]
        let dates = WidgetTimelineSchedule.entryDates(events: events, now: now, calendar: calendar)

        XCTAssertTrue(dates.contains(day(0, hour: 9, minute: 30)),
                      "the running event's END is a future display boundary")
        for excluded in [day(-1, hour: 23), day(-1, hour: 23, minute: 30), day(0, hour: 8),
                         day(1, hour: 10), day(1, hour: 11)] {
            XCTAssertFalse(dates.contains(excluded),
                           "\(excluded) is outside (now, rollover) and must not be an entry")
        }
    }

    func testTicksKeepEveryGapWithinTheTickInterval() {
        // 09:07 — deliberately unaligned, so the fill must snap to the grid.
        let now = day(0, hour: 9, minute: 7)
        let dates = WidgetTimelineSchedule.entryDates(events: [], now: now, calendar: calendar)

        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates[1], day(0, hour: 9, minute: 15), "ticks align to the interval grid, not to `now`")
        XCTAssertEqual(dates.last, day(1))
        assertStrictlyAscending(dates)
        for (a, b) in zip(dates, dates.dropFirst()) {
            XCTAssertLessThanOrEqual(b.timeIntervalSince(a), WidgetTimelineSchedule.tickInterval + 0.001,
                                     "time-anchored chrome (now line, remaining label) may never freeze for longer than one tick")
        }
    }

    func testCapIsEnforcedKeepingNowAndTheRollover() {
        // 200 events -> 400 in-window boundaries, far past the cap.
        let now = day(0, hour: 9)
        let events = (0..<200).map { i -> SharedEventSnapshot in
            let start = calendar.date(byAdding: .second, value: i * 60, to: day(0, hour: 10))!
            return snap(start: start, end: start.addingTimeInterval(30))
        }
        let dates = WidgetTimelineSchedule.entryDates(events: events, now: now, calendar: calendar)

        XCTAssertEqual(dates.count, WidgetTimelineSchedule.maxEntryCount,
                       "the schedule enforces its own cap rather than letting WidgetKit truncate blind")
        XCTAssertEqual(dates.first, now, "the cap must never drop the immediate entry")
        XCTAssertEqual(dates.last, day(1), "the cap must never drop the rollover entry")
        assertStrictlyAscending(dates)
    }

    func testRolloverEntryShowsTheNextDaysEvents() {
        let todayEvent = snap(start: day(0, hour: 9), end: day(0, hour: 10), title: "today")
        let tomorrowEvent = snap(start: day(1, hour: 10), end: day(1, hour: 11), title: "tomorrow")
        let tomorrowAllDay = snap(start: day(1), end: day(2), allDay: true, title: "all day")
        let all = [todayEvent, tomorrowEvent, tomorrowAllDay]

        let atNoon = WidgetTimelineSchedule.events(visibleOn: day(0, hour: 12), from: all, calendar: calendar)
        XCTAssertEqual(atNoon.map(\.id), [todayEvent.id])

        let atRollover = WidgetTimelineSchedule.events(visibleOn: day(1), from: all, calendar: calendar)
        XCTAssertEqual(atRollover.map(\.id), [tomorrowEvent.id],
                       "the midnight entry carries the NEXT day's timed list — all-day rows stay excluded, as in the old todayEvents()")
    }
}

// MARK: - gh#219: launch seed + reload seam (the app side)

/// The app-side half of the refresh-budget fix: `lastWrittenSnapshotHash` is
/// seeded at launch from the App Group payload itself, so a cold relaunch
/// with unchanged data neither rewrites the blob nor spends a
/// `reloadAllTimelines` on it. Runs against the REAL App Group suite (the
/// host app is entitled to it), so every test captures and restores the
/// group's widget keys around itself.
final class WidgetRefreshBudgetSeedTests: XCTestCase {
    private struct GroupState {
        let snapshot: Data?
        let updated: Date?
        let timeFormat: String?
        let language: String?
    }

    private func captureGroupState(_ d: UserDefaults) -> GroupState {
        GroupState(
            snapshot: d.data(forKey: SharedWidgetData.snapshotKey),
            updated: d.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date,
            timeFormat: d.string(forKey: SharedWidgetData.timeFormatKey),
            language: d.string(forKey: SharedWidgetData.languageKey)
        )
    }

    private func restoreGroupState(_ s: GroupState, in d: UserDefaults) {
        let pairs: [(String, Any?)] = [
            (SharedWidgetData.snapshotKey, s.snapshot),
            (SharedWidgetData.lastUpdatedKey, s.updated),
            (SharedWidgetData.timeFormatKey, s.timeFormat),
            (SharedWidgetData.languageKey, s.language),
        ]
        for (key, value) in pairs {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }

    /// A timed event on today's canvas, so it lands inside the snapshot window.
    private func todayEvent(title: String, startHour: Int) -> Event {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .minute, value: startHour * 60, to: dayStart)!
        let end = cal.date(byAdding: .minute, value: startHour * 60 + 60, to: dayStart)!
        return Event(title: title, timeRanges: [.init(start: start, end: end)])
    }

    @MainActor
    func testColdRelaunchWithUnchangedPayloadWritesNothingAndFiresNoReload() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        let suiteName = "WidgetRefreshBudget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        // Session one: real content -> one write, one reload request.
        let first = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var firstReloads = 0
        first.reloadWidgetTimelines = { firstReloads += 1 }
        first.addCalendarEvent(todayEvent(title: "Seeded content", startHour: 9))
        first.flushWidgetSnapshotSync()
        XCTAssertEqual(firstReloads, 1, "positive control: a real change writes and requests a reload")
        let updatedAfterFirst = group.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date

        // Cold relaunch: a NEW store over the same durable state. The
        // process-local hash is gone; before the launch seed this rewrote a
        // byte-identical payload and spent one reload of refresh budget.
        let second = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var secondReloads = 0
        second.reloadWidgetTimelines = { secondReloads += 1 }
        second.flushWidgetSnapshotSync()
        XCTAssertEqual(secondReloads, 0,
                       "an unchanged payload after relaunch must spend no refresh budget (gh#219)")
        XCTAssertEqual(group.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date, updatedAfterFirst,
                       "and no write either — lastUpdated untouched")
    }

    @MainActor
    func testRealChangeAfterColdRelaunchStillWritesAndReloads() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        let suiteName = "WidgetRefreshBudget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        let first = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        first.addCalendarEvent(todayEvent(title: "Baseline", startHour: 9))
        first.flushWidgetSnapshotSync()

        let second = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var reloads = 0
        second.reloadWidgetTimelines = { reloads += 1 }
        second.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 0, "seed holds while nothing changed")

        second.addCalendarEvent(todayEvent(title: "New plan", startHour: 14))
        second.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 1,
                       "the seed guards only the unchanged case — a real payload change must still write and reload")
        let blob = try XCTUnwrap(group.data(forKey: SharedWidgetData.snapshotKey))
        let decoded = try JSONDecoder().decode([SharedEventSnapshot].self, from: blob)
        XCTAssertTrue(decoded.contains { $0.title == "New plan" }, "the new content actually reached the App Group")
    }

    @MainActor
    func testFreshAppGroupStillGetsItsFirstWrite() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        // A group that has never been written: no payload, no settings keys.
        for key in [SharedWidgetData.snapshotKey, SharedWidgetData.lastUpdatedKey,
                    SharedWidgetData.timeFormatKey, SharedWidgetData.languageKey] {
            group.removeObject(forKey: key)
        }

        let suiteName = "WidgetRefreshBudget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var reloads = 0
        store.reloadWidgetTimelines = { reloads += 1 }
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 1,
                       "an ABSENT payload must never be seeded around — even an empty store's first sync writes")
        XCTAssertNotNil(group.object(forKey: SharedWidgetData.lastUpdatedKey))
    }

    @MainActor
    func testCorruptPayloadIsNotSeededAndGetsRewritten() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        group.set(Data("definitely not JSON".utf8), forKey: SharedWidgetData.snapshotKey)
        group.set("24h", forKey: SharedWidgetData.timeFormatKey)
        group.set("en", forKey: SharedWidgetData.languageKey)

        let suiteName = "WidgetRefreshBudget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var reloads = 0
        store.reloadWidgetTimelines = { reloads += 1 }
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 1, "a blob that fails to decode must not seed — the next sync heals it")
        let blob = try XCTUnwrap(group.data(forKey: SharedWidgetData.snapshotKey))
        XCTAssertNoThrow(try JSONDecoder().decode([SharedEventSnapshot].self, from: blob),
                         "the corrupt blob was replaced by one the widget can read")
    }
}

// MARK: - gh#219: the provider's policy, source-pinned

/// `DoneWidget` has no test bundle, so the provider's timeline POLICY cannot
/// be asserted behaviourally from here; a source scan is the honest reachable
/// layer (weaker than a behavioural test, and declared as such — the
/// `Spike201EmitSiteInventoryTests` idiom). The schedule the provider maps
/// over IS behaviourally tested above; this pin holds the two remaining
/// strands: the provider consumes that schedule, and the policy is `.atEnd`,
/// not a periodic pull.
final class WidgetTimelinePolicySourcePinTests: XCTestCase {
    func testGetTimelineIsScheduleDrivenAtEndNotAPeriodicPull() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DoneWidget/DoneWidget.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(src.contains("policy: .atEnd"),
                      "the timeline refreshes once its day of entries runs out — ~1 requested refresh/day")
        XCTAssertFalse(src.contains("policy: .after"),
                       "no periodic pull policy — .after(now + 5 min) was gh#219's 288 requested refreshes/day")
        XCTAssertFalse(src.contains("byAdding: .minute, value: 5"),
                       "the 5-minute pull interval must not come back in any spelling")
        XCTAssertTrue(src.contains("WidgetTimelineSchedule.entryDates("),
                      "the provider must consume the shared schedule the behavioural tests cover")
        XCTAssertTrue(src.contains("WidgetTimelineSchedule.events(visibleOn:"),
                      "…and derive each entry's list from the same shared day rule")
    }
}
