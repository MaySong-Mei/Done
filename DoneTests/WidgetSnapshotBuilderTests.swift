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
        // Every boundary sits OFF the 15-minute tick grid on purpose (gh#219
        // QA F3): with on-grid fixtures (10:00, 11:00, …) the tick fill
        // reproduced every boundary by itself, so a schedule that dropped
        // boundary collection entirely still passed this test. Off-grid
        // times pin the boundary property in its own right.
        let events = [
            snap(start: day(0, hour: 10, minute: 7), end: day(0, hour: 11, minute: 2)),
            snap(start: day(0, hour: 13, minute: 43), end: day(0, hour: 15, minute: 26)),
        ]
        let dates = WidgetTimelineSchedule.entryDates(events: events, now: now, calendar: calendar)

        // The moments `currentEvent`/`nextUpEvent` flip are all entries.
        for boundary in [day(0, hour: 10, minute: 7), day(0, hour: 11, minute: 2),
                         day(0, hour: 13, minute: 43), day(0, hour: 15, minute: 26)] {
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
            snap(start: day(0, hour: 8), end: day(0, hour: 9, minute: 31)),      // running now
            snap(start: day(1, hour: 10), end: day(1, hour: 11)),                // tomorrow
        ]
        let dates = WidgetTimelineSchedule.entryDates(events: events, now: now, calendar: calendar)

        // 09:31, not 09:30: off the tick grid so a tick cannot stand in for
        // the boundary this asserts (the QA F3 hole, same as the test above).
        XCTAssertTrue(dates.contains(day(0, hour: 9, minute: 31)),
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
        let timeZone: String?
    }

    private func captureGroupState(_ d: UserDefaults) -> GroupState {
        GroupState(
            snapshot: d.data(forKey: SharedWidgetData.snapshotKey),
            updated: d.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date,
            timeFormat: d.string(forKey: SharedWidgetData.timeFormatKey),
            language: d.string(forKey: SharedWidgetData.languageKey),
            timeZone: d.string(forKey: SharedWidgetData.timeZoneKey)
        )
    }

    private func restoreGroupState(_ s: GroupState, in d: UserDefaults) {
        let pairs: [(String, Any?)] = [
            (SharedWidgetData.snapshotKey, s.snapshot),
            (SharedWidgetData.lastUpdatedKey, s.updated),
            (SharedWidgetData.timeFormatKey, s.timeFormat),
            (SharedWidgetData.languageKey, s.language),
            (SharedWidgetData.timeZoneKey, s.timeZone),
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

        // A group that has never been written: no payload, no settings keys,
        // no time-zone stamp.
        for key in [SharedWidgetData.snapshotKey, SharedWidgetData.lastUpdatedKey,
                    SharedWidgetData.timeFormatKey, SharedWidgetData.languageKey,
                    SharedWidgetData.timeZoneKey] {
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

    /// gh#219 QA F1 (ruled): a time-zone change while the app is DEAD was
    /// the one case the removed 5-minute pull used to catch — and the
    /// payload hash omitted the zone, so even opening the app only healed
    /// the widget if the snapshot bytes happened to differ. With the zone in
    /// the hash and stamped into the App Group, app-open is a guaranteed
    /// heal. The dead-app window itself (widget on old-zone times until the
    /// old zone's midnight rollover entry, <= 24h) is the accepted residue —
    /// documented at `widgetPayloadHash`.
    @MainActor
    func testTimeZoneChangeWhileAppWasDeadPunchesThroughTheWriteGuardOnOpen() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        let suiteName = "WidgetRefreshBudget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        // Session one stamps the group with the zone the payload was
        // computed in.
        let first = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        first.addCalendarEvent(todayEvent(title: "TZ probe", startHour: 9))
        first.flushWidgetSnapshotSync()
        XCTAssertEqual(group.string(forKey: SharedWidgetData.timeZoneKey), TimeZone.current.identifier,
                       "the write stamps the payload's zone")

        // The app dies; the device moves zones. From the relaunching store's
        // side that is exactly "the group holds a payload stamped with a
        // DIFFERENT zone", which needs no TimeZone.current mocking.
        let staleZone = TimeZone.current.identifier == "Pacific/Chatham"
            ? "America/New_York" : "Pacific/Chatham"
        group.set(staleZone, forKey: SharedWidgetData.timeZoneKey)

        // Cold relaunch: the seed hashes the STORED (stale) zone, the sync
        // hashes the current one — so the first flush must write and reload
        // even though the event content, and therefore the snapshot bytes,
        // did not change at all. This is the assertion that dies if the zone
        // is dropped from the hash on either side.
        let second = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var reloads = 0
        second.reloadWidgetTimelines = { reloads += 1 }
        second.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 1,
                       "a zone change ALONE must punch through the write guard — app-open is the guaranteed heal (gh#219 QA F1)")
        XCTAssertEqual(group.string(forKey: SharedWidgetData.timeZoneKey), TimeZone.current.identifier,
                       "the heal re-stamps the group with the current zone")

        // And with the zone healed the guard closes again.
        second.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 1, "no further change, no further spend")
    }

    /// Upgrade path for the stamp itself: a blob written by THIS branch
    /// before QA F1 has payload + settings keys but no zone stamp. The seed
    /// must treat it like any other incomplete read-back — skip, and let the
    /// first sync rewrite (one reload, once, per upgrade: the self-healing
    /// direction, never the stale one).
    @MainActor
    func testPreZoneStampBlobIsNotSeededAndGetsOneHealingWrite() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        let suiteName = "WidgetRefreshBudget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        // Write a normal payload, then strip only the zone stamp — the exact
        // shape a pre-F1 build leaves behind.
        let first = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        first.addCalendarEvent(todayEvent(title: "Pre-stamp content", startHour: 9))
        first.flushWidgetSnapshotSync()
        group.removeObject(forKey: SharedWidgetData.timeZoneKey)

        let second = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var reloads = 0
        second.reloadWidgetTimelines = { reloads += 1 }
        second.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 1,
                       "a stamp-less blob must not be seeded around — one healing write backfills it")
        XCTAssertEqual(group.string(forKey: SharedWidgetData.timeZoneKey), TimeZone.current.identifier,
                       "the healing write adds the zone stamp")

        second.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 1, "healed — the guard closes")
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
        // The ARGUMENT is pinned, not just the call (gh#219 QA B2): a
        // provider that maps every entry to `events(visibleOn: now, …)`
        // still contains "events(visibleOn:" — and hands the midnight entry
        // YESTERDAY'S list, undoing the rollover guarantee the schedule
        // tests prove. Each entry's list must be derived for that entry's
        // own date.
        XCTAssertTrue(src.contains("WidgetTimelineSchedule.events(visibleOn: date"),
                      "…and derive each entry's list from the same shared day rule, FOR THE ENTRY'S OWN DATE")
    }

    /// gh#219 QA B1: the production default of the `reloadWidgetTimelines`
    /// seam is observed by NOTHING behavioural — every seed/guard test
    /// replaces the closure with a counter before flushing, so gutting the
    /// default to `{}` survived all 44 widget tests. In production that
    /// mutant silently kills every data-change push: the widget keeps
    /// rendering its delivered day and goes stale for up to 24h with zero
    /// signal — the exact disease this branch treats. The seam's default is
    /// therefore source-pinned, the branch's declared idiom for the layer a
    /// test bundle cannot reach (`WidgetCenter` is real IPC; counting it
    /// behaviourally from DoneTests would need the mock this seam IS).
    func testReloadSeamDefaultIsTheRealWidgetCenterReload() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Done/Models/EventStore.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            src.contains("var reloadWidgetTimelines: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }"),
            "the seam's default closure must BE the real WidgetCenter reload — an empty or renamed default ships an app whose widget never hears about data changes"
        )
        // Grep-earned across the repo at pin time: EventStore.swift is the
        // ONLY file with a WidgetCenter call, and the seam default is its
        // only occurrence. Exactly one spend site means every reload request
        // routes through the seam the tests count.
        XCTAssertEqual(
            src.components(separatedBy: "WidgetCenter.shared.reloadAllTimelines()").count - 1, 1,
            "exactly one reload spend site — a second direct call would bypass the countable seam"
        )
    }
}

// MARK: - QA (independent adversarial loop, gh#219 refresh-budget fix)

/// Independent QA probes for the gh#219 branch. Same capture/restore
/// discipline as `WidgetRefreshBudgetSeedTests` for anything that touches the
/// REAL App Group or the host app's standard defaults.
final class WidgetRefreshBudgetQATests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
    }

    private func day(_ offset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let start = calendar.date(byAdding: .day, value: offset, to: today)!
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start)!
    }

    private func snap(start: Date, end: Date, title: String = "t") -> SharedEventSnapshot {
        SharedEventSnapshot(
            id: UUID(), eventID: UUID(), title: title, type: "Work", colorHex: nil,
            startDate: start, endDate: end, isAllDay: false, isDone: false
        )
    }

    // MARK: group/standard-defaults capture

    private struct GroupState {
        let snapshot: Data?
        let updated: Date?
        let timeFormat: String?
        let language: String?
        let timeZone: String?
    }

    private func captureGroupState(_ d: UserDefaults) -> GroupState {
        GroupState(
            snapshot: d.data(forKey: SharedWidgetData.snapshotKey),
            updated: d.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date,
            timeFormat: d.string(forKey: SharedWidgetData.timeFormatKey),
            language: d.string(forKey: SharedWidgetData.languageKey),
            timeZone: d.string(forKey: SharedWidgetData.timeZoneKey)
        )
    }

    private func restoreGroupState(_ s: GroupState, in d: UserDefaults) {
        let pairs: [(String, Any?)] = [
            (SharedWidgetData.snapshotKey, s.snapshot),
            (SharedWidgetData.lastUpdatedKey, s.updated),
            (SharedWidgetData.timeFormatKey, s.timeFormat),
            (SharedWidgetData.languageKey, s.language),
            (SharedWidgetData.timeZoneKey, s.timeZone),
        ]
        for (key, value) in pairs {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }

    private func todayEvent(title: String, startHour: Int) -> Event {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .minute, value: startHour * 60, to: dayStart)!
        let end = cal.date(byAdding: .minute, value: startHour * 60 + 60, to: dayStart)!
        return Event(title: title, timeRanges: [.init(start: start, end: end)])
    }

    // MARK: - Attack 2: launch seed vs older-app-version blobs

    /// The FIRST shipped widget version (9f83f3e) wrote exactly these seven
    /// fields and no settings keys. A user upgrading straight from that build
    /// hands the seed this exact shape.
    private struct EraOneSnapshot: Codable {
        var id: UUID
        var title: String
        var type: String
        var startDate: Date
        var endDate: Date
        var isAllDay: Bool
        var isDone: Bool
    }

    @MainActor
    func testQA_EraOneLegacyBlobDoesNotCrashTheSeedAndStillGetsHealed() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        // Era-1 payload: decodes under the CURRENT struct (missing fields are
        // optional), but the settings keys the seed guard requires are absent.
        let legacy = [EraOneSnapshot(
            id: UUID(), title: "Era one leftover", type: "Work",
            startDate: Date(), endDate: Date().addingTimeInterval(3600),
            isAllDay: false, isDone: false
        )]
        group.set(try JSONEncoder().encode(legacy), forKey: SharedWidgetData.snapshotKey)
        group.removeObject(forKey: SharedWidgetData.timeFormatKey)
        group.removeObject(forKey: SharedWidgetData.languageKey)
        group.removeObject(forKey: SharedWidgetData.timeZoneKey)

        let suiteName = "WidgetQA-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        // Init runs the seed against the legacy blob: must not crash, and must
        // NOT seed (settings keys are missing), so the first sync heals.
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var reloads = 0
        store.reloadWidgetTimelines = { reloads += 1 }
        store.addCalendarEvent(todayEvent(title: "Post-upgrade content", startHour: 9))
        store.flushWidgetSnapshotSync()

        XCTAssertEqual(reloads, 1, "a pre-settings-era blob must not be seeded around — one healing write")
        let blob = try XCTUnwrap(group.data(forKey: SharedWidgetData.snapshotKey))
        let decoded = try JSONDecoder().decode([SharedEventSnapshot].self, from: blob)
        XCTAssertTrue(decoded.contains { $0.title == "Post-upgrade content" },
                      "the healing write replaced the legacy blob with current content")
        XCTAssertNotNil(group.string(forKey: SharedWidgetData.timeFormatKey),
                        "the healing write also backfills the settings keys")
        XCTAssertNotNil(group.string(forKey: SharedWidgetData.timeZoneKey),
                        "…and the zone stamp (gh#219 QA F1)")
    }

    @MainActor
    func testQA_ForeignValidBlobSeedsThenMismatchesHarmlessly() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        // A fully valid, current-format blob from some other data set, WITH
        // settings keys: the seed takes it, and the first sync must detect the
        // mismatch (different content) and write — the harmless direction.
        let foreign = [snap(start: day(0, hour: 9), end: day(0, hour: 10), title: "Foreign occupant")]
        XCTAssertTrue(SharedWidgetData.write(events: foreign, timeFormat: "24h", language: "en",
                                             timeZone: TimeZone.current.identifier))

        let suiteName = "WidgetQA-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var reloads = 0
        store.reloadWidgetTimelines = { reloads += 1 }
        store.addCalendarEvent(todayEvent(title: "Local truth", startHour: 9))
        store.flushWidgetSnapshotSync()

        XCTAssertEqual(reloads, 1, "a seeded-but-stale hash must not suppress the correcting write")
        let blob = try XCTUnwrap(group.data(forKey: SharedWidgetData.snapshotKey))
        let decoded = try JSONDecoder().decode([SharedEventSnapshot].self, from: blob)
        XCTAssertTrue(decoded.contains { $0.title == "Local truth" })
        XCTAssertFalse(decoded.contains { $0.title == "Foreign occupant" })
    }

    // MARK: - Attack 1: settings changes must punch through the write guard

    /// The payload hash includes timeFormat and language, so flipping either
    /// setting alone (no event change) must produce a write + reload at the
    /// next flush — that flush is the willResignActive edge in production,
    /// which always precedes the user seeing the widget. A hash that silently
    /// drops either component would freeze the widget's clock format or
    /// language forever; no test in the branch pinned this.
    @MainActor
    func testQA_TimeFormatOrLanguageChangeAlonePunchesThroughTheWriteGuard() throws {
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        let saved = captureGroupState(group)
        defer { restoreGroupState(saved, in: group) }

        let std = UserDefaults.standard
        let savedTimeFormat = std.string(forKey: AppSettingsLocale.timeFormatKey)
        let savedLanguage = std.string(forKey: AppSettingsLocale.languageKey)
        defer {
            if let savedTimeFormat { std.set(savedTimeFormat, forKey: AppSettingsLocale.timeFormatKey) }
            else { std.removeObject(forKey: AppSettingsLocale.timeFormatKey) }
            if let savedLanguage { std.set(savedLanguage, forKey: AppSettingsLocale.languageKey) }
            else { std.removeObject(forKey: AppSettingsLocale.languageKey) }
        }

        let suiteName = "WidgetQA-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let location = TestStorage.reset(suiteName)
        defer { TestStorage.tearDown(suiteName) }

        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        var reloads = 0
        store.reloadWidgetTimelines = { reloads += 1 }
        store.addCalendarEvent(todayEvent(title: "Settings probe", startHour: 9))
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 1, "positive control")

        // Flip ONLY the time format.
        let flippedFormat = AppTimeFormat.current == .twentyFour ? "12h" : "24h"
        std.set(flippedFormat, forKey: AppSettingsLocale.timeFormatKey)
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 2,
                       "a time-format change with unchanged events must write + reload (hash includes timeFormat)")
        XCTAssertEqual(group.string(forKey: SharedWidgetData.timeFormatKey), flippedFormat)

        // Flip ONLY the language.
        let flippedLanguage = AppLanguage.current == .english ? "zh" : "en"
        std.set(flippedLanguage, forKey: AppSettingsLocale.languageKey)
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 3,
                       "a language change with unchanged events must write + reload (hash includes language)")
        XCTAssertEqual(group.string(forKey: SharedWidgetData.languageKey), flippedLanguage)

        // And the guard still holds afterwards: nothing changed, no spend.
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads, 3, "no further change, no further spend")
    }

    // MARK: - Attack 3: the cap on a 60-event day, quantified

    func testQA_SixtyEventDayCapKeepsEndpointsDropsExactlyTwoBoundariesAndAddsNoTicks() {
        // 60 events, starts every 9 min from 09:00, each 8 min long: 120
        // distinct boundaries strictly inside (08:00, 24:00). With now and the
        // rollover that is 122 candidates against a cap of 120.
        let now = day(0, hour: 8)
        let events = (0..<60).map { i -> SharedEventSnapshot in
            let start = day(0, hour: 9, minute: i * 9)
            return snap(start: start, end: start.addingTimeInterval(8 * 60))
        }
        var boundaries = Set<Date>()
        for e in events { boundaries.insert(e.startDate); boundaries.insert(e.endDate) }
        XCTAssertEqual(boundaries.count, 120, "fixture sanity: 120 distinct boundaries")

        let dates = WidgetTimelineSchedule.entryDates(events: events, now: now, calendar: calendar)

        XCTAssertEqual(dates.count, WidgetTimelineSchedule.maxEntryCount)
        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates.last, day(1))
        let missing = boundaries.subtracting(dates)
        XCTAssertEqual(missing.count, 2,
                       "the stride sample drops exactly the overflow — two interior flip boundaries")
        for interior in dates.dropFirst().dropLast() {
            XCTAssertTrue(boundaries.contains(interior),
                          "cap-bitten day contains NO ticks — every interior entry is an event boundary")
        }
        // QA measurement, pinned as the ACCEPTED cap tradeoff: after the
        // last event boundary (17:59) the next entry is the rollover — the
        // widget's clock chrome (TimelineBar time, ring remaining-label, now
        // line) freezes for the whole gap. The F2 stride fill cannot help
        // here: the 120 boundaries alone overflow the ~118 slots that exist
        // beside now + rollover, so the tick budget is zero and there is
        // nothing to stride. The cap itself is the tradeoff, documented at
        // `maxEntryCount`.
        let lastBoundary = dates.dropLast().last!
        let freeze = dates.last!.timeIntervalSince(lastBoundary)
        XCTAssertEqual(freeze, 6 * 3600 + 60, accuracy: 1,
                       "measured chrome freeze on a 60-event day: 6h01m (17:59 -> 24:00)")
    }

    /// The comment's own arithmetic: 96 ticks + 2 endpoints leaves 22 boundary
    /// slots = 11 events. At the .atEnd regeneration moment (midnight, the
    /// STANDARD generation time for an untouched device) an 11-event day still
    /// gets full-day tick coverage...
    func testQA_ElevenEventDayFromMidnightKeepsFullDayTickCoverage() {
        let now = day(0, hour: 0, minute: 1)
        let events = (0..<11).map { i -> SharedEventSnapshot in
            let start = day(0, hour: 9, minute: i * 13 + 1) // off the 15-min grid
            return snap(start: start, end: start.addingTimeInterval(7 * 60))
        }
        let dates = WidgetTimelineSchedule.entryDates(events: events, now: now, calendar: calendar)
        XCTAssertLessThanOrEqual(dates.count, WidgetTimelineSchedule.maxEntryCount)
        for (a, b) in zip(dates, dates.dropFirst()) {
            XCTAssertLessThanOrEqual(b.timeIntervalSince(a), WidgetTimelineSchedule.tickInterval + 0.001,
                                     "an 11-event day keeps the documented <=15min chrome granularity all day")
        }
    }

    /// ...and a 20-event day regenerated at midnight — where QA originally
    /// measured the F2 finding: the chronological fill spent every tick slot
    /// on the morning and afternoon and left the evening chrome frozen for
    /// >1h stretches (while the widget renders each entry's wall-clock
    /// time). Under the ruled stride policy the leftover tick budget is
    /// spread evenly across (now, rollover), so the whole day stays covered;
    /// this test is that measurement turned into the pin.
    func testQA_TwentyEventDayFromMidnightKeepsTheEveningCoveredByStridedTicks() {
        let now = day(0, hour: 0, minute: 5)
        let events = (0..<20).map { i -> SharedEventSnapshot in
            let start = day(0, hour: 10, minute: i * 13 + 2) // off the 15-min grid
            return snap(start: start, end: start.addingTimeInterval(11 * 60))
        }
        let dates = WidgetTimelineSchedule.entryDates(events: events, now: now, calendar: calendar)
        XCTAssertEqual(dates.count, WidgetTimelineSchedule.maxEntryCount, "cap is filled")
        let maxGap = zip(dates, dates.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .max() ?? .infinity
        // Hand-computed bound, deliberately NOT the implementation's formula
        // re-run: 40 event boundaries + now + rollover leave 78 tick slots
        // for the 23h55m span; 86100s / 79 ≈ 1090s ≈ 18m10s between ticks,
        // and boundaries only ever shrink a gap. 19 minutes is that number
        // with margin — and less than a third of the >1h freeze this fixture
        // produced under the chronological fill.
        XCTAssertLessThanOrEqual(maxGap, 19 * 60,
                                 "strided ticks keep the WHOLE day's chrome moving — this exact fixture froze >1h under chronological fill (gh#219 QA F2)")
        XCTAssertEqual(dates.last, day(1), "the rollover entry itself always survives")
    }
}
