import XCTest
@testable import Done

/// Me-page weekly stats fixes:
///
/// - #121 elapsed-clamp: the hour aggregations ("active" total, per-day
///   heatmap, type split) measure *spent* time, so an occurrence contributes
///   `min(end, now) − start` once it has started and nothing while it is
///   still in the future.  The cut rule is `Event.elapsedWindowCut`, shared
///   with the report clue battery.
/// - #120 done count: `tasksCompletedCount` spans both task domains — the
///   legacy Wanna list AND calendar todos (`kind == .todo && isDone` with
///   `completeAt` in range) — without double-counting a wanna linked to its
///   calendar twin.
final class AnalysisWeekStatsTests: XCTestCase {
    private let calendar = Calendar.current

    private func hour(_ h: Int, _ mi: Int = 0) -> Date {
        calendar.startOfDay(for: Date()).addingTimeInterval(TimeInterval(h * 3600 + mi * 60))
    }

    private func calendarEvent(
        type: String = "work",
        start: Date,
        end: Date
    ) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: type
        )
    }

    @MainActor
    private func makeStore(
        calendarEvents: [Event] = [],
        legacyEvents: [Event] = []
    ) -> EventStore {
        let suiteName = "AnalysisWeekStatsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = EventStore(defaults: defaults,
                               storage: .ephemeral(id: UUID()),
                               seedsSampleDataIfEmpty: false)
        store.rawCalendarEvents = calendarEvents
        store.events = legacyEvents
        return store
    }

    private func makeDayViewModel(now: Date) -> AnalysisViewModel {
        let viewModel = AnalysisViewModel(initialPeriod: .day)
        viewModel.now = { now }
        return viewModel
    }

    // MARK: - #121 elapsed-clamp

    @MainActor
    func testFullyFutureOccurrenceContributesZeroHours() {
        // Observed at 06:00, an 08:00–10:00 event is still a plan: no bar,
        // no type split, no "active" total.
        let store = makeStore(calendarEvents: [
            calendarEvent(start: hour(8), end: hour(10))
        ])
        let viewModel = makeDayViewModel(now: hour(6))

        XCTAssertEqual(viewModel.totalScheduledHours(store: store), 0, accuracy: 0.0001)
        XCTAssertTrue(viewModel.typeAllocations(store: store).isEmpty)
        XCTAssertTrue(viewModel.dailyHoursData(store: store).isEmpty)
    }

    @MainActor
    func testOccurrenceStraddlingNowCountsOnlyElapsedPart() {
        // Observed at 09:00, an 08:00–10:00 event has spent exactly 1h.
        let store = makeStore(calendarEvents: [
            calendarEvent(start: hour(8), end: hour(10))
        ])
        let viewModel = makeDayViewModel(now: hour(9))

        XCTAssertEqual(viewModel.totalScheduledHours(store: store), 1.0, accuracy: 0.0001)
        XCTAssertEqual(
            viewModel.dailyHoursData(store: store).reduce(0) { $0 + $1.hours },
            1.0,
            accuracy: 0.0001
        )
    }

    @MainActor
    func testFinishedOccurrenceStillCountsInFull() {
        // Observed at 12:00, the same event counts its full 2h — the clamp
        // only ever removes not-yet-elapsed time.
        let store = makeStore(calendarEvents: [
            calendarEvent(start: hour(8), end: hour(10))
        ])
        let viewModel = makeDayViewModel(now: hour(12))

        XCTAssertEqual(viewModel.totalScheduledHours(store: store), 2.0, accuracy: 0.0001)
    }

    func testElapsedWindowCutBounds() {
        // The shared cut rule itself: before the window → start (nothing
        // elapsed); inside → asOf; after → end (fully counted).
        let start = hour(8), end = hour(10)
        XCTAssertEqual(Event.elapsedWindowCut(windowStart: start, windowEnd: end, asOf: hour(6)), start)
        XCTAssertEqual(Event.elapsedWindowCut(windowStart: start, windowEnd: end, asOf: hour(9)), hour(9))
        XCTAssertEqual(Event.elapsedWindowCut(windowStart: start, windowEnd: end, asOf: hour(12)), end)
    }

    // MARK: - #120 done count

    @MainActor
    func testCompletedCalendarTodoCountsOnce() {
        // A calendar todo marked done via the detail page (isDone/status/
        // completeAt trio) enters the week's done count; an open todo and a
        // completed plain `.event` do not.
        let doneTodo = Event(
            title: "done todo",
            timeRanges: [Event.TimeRange(start: hour(9), end: hour(10))],
            isDone: true,
            status: .completed,
            completeAt: hour(10),
            kind: .todo
        )
        let openTodo = Event(
            title: "open todo",
            timeRanges: [Event.TimeRange(start: hour(11), end: hour(12))],
            kind: .todo
        )
        let plainEvent = Event(
            title: "plain event",
            timeRanges: [Event.TimeRange(start: hour(13), end: hour(14))],
            isDone: true,
            status: .completed,
            completeAt: hour(14)
        )
        let store = makeStore(calendarEvents: [doneTodo, openTodo, plainEvent])
        let viewModel = makeDayViewModel(now: hour(23))

        XCTAssertEqual(viewModel.tasksCompletedCount(store: store), 1)
    }

    @MainActor
    func testCompletionOutsideRangeNotCounted() {
        // completeAt eight days back falls outside the current week window.
        let oldComplete = calendar.date(byAdding: .day, value: -8, to: hour(10))!
        let staleTodo = Event(
            title: "stale todo",
            timeRanges: [Event.TimeRange(start: oldComplete, end: oldComplete.addingTimeInterval(3600))],
            isDone: true,
            status: .completed,
            completeAt: oldComplete,
            kind: .todo
        )
        let store = makeStore(calendarEvents: [staleTodo])
        let viewModel = AnalysisViewModel(initialPeriod: .week)
        viewModel.now = { self.hour(23) }

        XCTAssertEqual(viewModel.tasksCompletedCount(store: store), 0)
    }

    @MainActor
    func testLinkedWannaAndCalendarTwinCountOnce() {
        // A legacy wanna linked to a calendar twin: when both carry a
        // completion in the window, the pair is one intent → one count.
        // The unlinked legacy wanna keeps the original counting path.
        let twinID = UUID()
        let calendarTwin = Event(
            id: twinID,
            title: "twin on calendar",
            timeRanges: [Event.TimeRange(start: hour(9), end: hour(10))],
            isDone: true,
            status: .completed,
            completeAt: hour(10),
            kind: .todo
        )
        let linkedWanna = Event(
            title: "linked wanna",
            isDone: true,
            status: .completed,
            completeAt: hour(10),
            linkedCalendarEventId: twinID
        )
        let plainWanna = Event(
            title: "plain wanna",
            isDone: true,
            status: .completed,
            completeAt: hour(11)
        )
        let store = makeStore(
            calendarEvents: [calendarTwin],
            legacyEvents: [linkedWanna, plainWanna]
        )
        let viewModel = makeDayViewModel(now: hour(23))

        XCTAssertEqual(viewModel.tasksCompletedCount(store: store), 2)
    }
}
