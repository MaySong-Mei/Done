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

    func testSnapshotSurvivesARoundTripThroughJSON() throws {
        let event = Event(title: "Round trip", timeRanges: [.init(start: day(0, hour: 9), end: day(0, hour: 10))])
        let snapshots = build([event])
        let data = try JSONEncoder().encode(snapshots)
        let decoded = try JSONDecoder().decode([SharedEventSnapshot].self, from: data)
        XCTAssertEqual(decoded, snapshots)
        XCTAssertEqual(decoded.first?.eventID, event.id)
    }
}
