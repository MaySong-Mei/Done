import XCTest
@testable import Done

/// Overlap-sharing in `AnalysisViewModel`'s hour aggregation: a window
/// covered by n occurrences credits each 1/n, so daily totals equal union
/// coverage (a fully-logged day sums to 24h) instead of over-counting —
/// which used to inflate the week-max and squash every other day's
/// heatmap bar.
final class AnalysisOverlapSharingTests: XCTestCase {
    private let calendar = Calendar.current

    private func hour(_ h: Int, _ mi: Int = 0) -> Date {
        calendar.startOfDay(for: Date()).addingTimeInterval(TimeInterval(h * 3600 + mi * 60))
    }

    private func event(
        type: String,
        start: Date,
        end: Date,
        interruptRelation: EventInterruptRelation? = nil
    ) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: type,
            interruptRelation: interruptRelation
        )
    }

    @MainActor
    private func makeStore(_ events: [Event]) -> EventStore {
        // Throwaway per call; `.ephemeral` keeps the directory in the temp
        // dir so nothing outlives the run even if the test aborts.
        let suiteName = "AnalysisOverlapSharingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = EventStore(defaults: defaults,
                               storage: .ephemeral(id: UUID()),
                               seedsSampleDataIfEmpty: false)
        store.rawCalendarEvents = events
        return store
    }

    /// Day-period view model with "now" pinned to the end of today, so the
    /// elapsed-clamp (#121) never truncates these fixtures — the tests here
    /// exercise overlap-sharing, not partial-day accounting.
    private func makeDayViewModel() -> AnalysisViewModel {
        let viewModel = AnalysisViewModel(initialPeriod: .day)
        let endOfToday = hour(24)
        viewModel.now = { endOfToday }
        return viewModel
    }

    @MainActor
    func testFullyOverlappingEventsShareTimeEvenly() {
        // Two 2h events on the same window: each counts half, day total = 2h.
        let store = makeStore([
            event(type: "work", start: hour(8), end: hour(10)),
            event(type: "study", start: hour(8), end: hour(10)),
        ])
        let daily = makeDayViewModel().dailyHoursData(store: store)

        XCTAssertEqual(daily.first { $0.type == "work" }?.hours ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(daily.first { $0.type == "study" }?.hours ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.hours }, 2.0, accuracy: 0.0001)
    }

    @MainActor
    func testPartialOverlapSplitsOnlyTheSharedWindow() {
        // A 8–10, B 9–11: 8–9 A alone, 9–10 half each, 10–11 B alone.
        let store = makeStore([
            event(type: "a", start: hour(8), end: hour(10)),
            event(type: "b", start: hour(9), end: hour(11)),
        ])
        let daily = makeDayViewModel().dailyHoursData(store: store)

        XCTAssertEqual(daily.first { $0.type == "a" }?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(daily.first { $0.type == "b" }?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.hours }, 3.0, accuracy: 0.0001)
    }

    @MainActor
    func testEmbeddedInterruptChildStaysNetNotOverlapShared() {
        // The parent excludes its embedded child's window (NET) before the
        // overlap pass, so the pair never reads as an overlap: parent 1.5h,
        // child 0.5h, total conserved at 2h.
        let parent = event(type: "work", start: hour(8), end: hour(10))
        let child = event(
            type: "break",
            start: hour(9), end: hour(9, 30),
            interruptRelation: EventInterruptRelation(
                parentEventID: parent.id,
                occurrenceDate: hour(9)
            )
        )
        let store = makeStore([parent, child])
        let daily = makeDayViewModel().dailyHoursData(store: store)

        XCTAssertEqual(daily.first { $0.type == "work" }?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(daily.first { $0.type == "break" }?.hours ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.hours }, 2.0, accuracy: 0.0001)
    }

    @MainActor
    func testFullyLoggedDayWithOverlapTotalsTwentyFourHours() {
        // Full-day coverage with an overlapping second event still sums to
        // 24h, so the heatmap bar reads as full instead of raising the
        // week-max above 24.
        let store = makeStore([
            event(type: "work", start: hour(0), end: hour(24)),
            event(type: "study", start: hour(6), end: hour(18)),
        ])
        let viewModel = makeDayViewModel()

        XCTAssertEqual(viewModel.totalScheduledHours(store: store), 24.0, accuracy: 0.0001)
        XCTAssertEqual(
            viewModel.dailyHoursData(store: store).reduce(0) { $0 + $1.hours },
            24.0,
            accuracy: 0.0001
        )
    }
}
