import XCTest
@testable import Done

/// Independent QA for gh#213 — the loop-invariant hoist of
/// `store.canvasRenderableCalendarEvents` out of the three Analysis day loops
/// (`totalScheduledHours` / `typeAllocations` / `dailyHoursData`).
///
/// This suite is written by an independent QA that did NOT write the fix. It
/// answers three questions with tests, not prose:
///
///  1. EQUIVALENCE — the three aggregations return the same values after the
///     hoist as before (pure loop-invariant code motion). Locked here by an
///     independently hand-computed representative fixture (large history N,
///     month period, canvas-renderable + non-renderable mix, cross-midnight
///     fan-out, a recurring daily series). The out-of-band king baseline
///     byte-for-byte 对拍 is recorded in the QA report; this file is the
///     self-contained permanent lock (the task's "自己独立算期望" arm).
///
///  2. FILTER-COUNT — a single aggregate build evaluates the O(N) filter a
///     small CONSTANT number of times, not once per day (3×D pre-hoist). Pinned
///     with the `onCanvasRenderableComputed` observability hook the fix added.
///
///  3. NOT-FROZEN — the hoist is a per-build method-local, so the aggregate
///     still tracks store data across builds (guardrail #3: no stale capture
///     that outlives an @Published change).
///
/// Plus a boundary lock (guardrail #2): the deliberately-raw methods
/// (`recordStreak`) were NOT swept onto the filter by accident.
final class AnalysisRenderableHoistQATests: XCTestCase {
    private let calendar = Calendar.current

    // MARK: - Fixture builders (independent of the fix's own test helpers)

    @MainActor
    private func makeStore(_ events: [Event]) -> EventStore {
        let suiteName = "AnalysisRenderableHoistQATests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = EventStore(defaults: defaults,
                               storage: .ephemeral(id: UUID()),
                               seedsSampleDataIfEmpty: false)
        store.rawCalendarEvents = events
        return store
    }

    private func plainEvent(type: String, start: Date, end: Date) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: type
        )
    }

    /// A `.todo` absorbed into a parent — carries its own time range, so if the
    /// canvas-render filter were dropped it would re-emit as a phantom
    /// occurrence and inflate the hour/type sums. Must never surface.
    private func absorbedTodo(type: String, start: Date, end: Date, parent: UUID) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: type,
            kind: .todo,
            absorbedIntoEventID: parent
        )
    }

    /// A dateless stack todo — canvas-renderable (not absorbed) but yields zero
    /// occurrences (no time range). Confirms a renderable-but-timeless event
    /// adds nothing to the hour sums.
    private func stackTodo(type: String) -> Event {
        Event(title: type, timeRanges: [], type: type, kind: .todo)
    }

    /// A recurring DAILY series anchored at `start`..`end` (no end condition):
    /// one occurrence on every day of any range at or after the anchor day.
    private func recurringDaily(type: String, start: Date, end: Date) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: type
        )
    }

    // MARK: - 1. Equivalence: hand-computed representative fixture

    /// Independently-computed expected outputs for a representative month
    /// fixture. If the hoist changed ANY of the three aggregations — dropped
    /// the filter, froze the loop, mis-ordered accumulation — one of these
    /// exact assertions breaks. Everything is asserted relative to
    /// `D = daysInRange().count` and to event DURATIONS (never wall-clock
    /// placement), so the fixture is robust across run-date and DST months.
    ///
    /// Composition (all times civil, non-overlapping within any single day so
    /// overlap-sharing credits each occurrence its full duration):
    ///   - "work": 5 plain 1h events on 5 distinct days           → 5h
    ///   - "sleep": 1 cross-midnight 4h event (22:00→02:00)       → 4h, split
    ///              across two civil days by the gh#225 fan-out
    ///   - "gym": 1 daily recurring 1h series over the whole month → D h
    ///   - "study": 50 ABSORBED todos (1h each)                    → 0h (filtered)
    ///   - "errand": 1 dateless stack todo                         → 0h (no range)
    /// Expected total = D + 9.
    @MainActor
    func testRepresentativeMonthFixtureAggregates_handComputed() {
        let viewModel = AnalysisViewModel(initialPeriod: .month)
        // Pin now well past month end so the elapsed-clamp never truncates a day
        // — every occurrence counts its full duration.
        let range = viewModel.dateRange
        viewModel.now = { range.end.addingTimeInterval(3600) }

        let days = viewModel.daysInRange()
        let D = days.count
        XCTAssertGreaterThanOrEqual(D, 28, "month must span many days")

        // Civil hour on a given day index, built via calendar components so the
        // placement stays at the intended civil hour across DST days.
        func at(dayIndex: Int, hour: Int, minute: Int = 0) -> Date {
            let dayStart = days[dayIndex]
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart)!
        }

        let dummyParent = UUID()
        var events: [Event] = []

        // 5 "work" events, each on a distinct day, 09:00–10:00.
        for i in 0..<5 {
            events.append(plainEvent(type: "work", start: at(dayIndex: i, hour: 9), end: at(dayIndex: i, hour: 10)))
        }

        // 1 cross-midnight "sleep": day5 22:00 → day6 02:00 (4h).
        events.append(plainEvent(
            type: "sleep",
            start: at(dayIndex: 5, hour: 22),
            end: calendar.date(bySettingHour: 2, minute: 0, second: 0, of: days[6])!
        ))

        // 1 recurring daily "gym" 06:00–07:00 anchored on day0 → every day.
        events.append(recurringDaily(type: "gym", start: at(dayIndex: 0, hour: 6), end: at(dayIndex: 0, hour: 7)))

        // 50 absorbed "study" todos at 12:00–13:00 across days — all filtered out.
        for i in 0..<50 {
            let d = i % D
            events.append(absorbedTodo(type: "study", start: at(dayIndex: d, hour: 12), end: at(dayIndex: d, hour: 13), parent: dummyParent))
        }

        // 1 dateless stack todo — renderable, no time range.
        events.append(stackTodo(type: "errand"))

        let store = makeStore(events)

        // --- totalScheduledHours ---
        let total = viewModel.totalScheduledHours(store: store)
        XCTAssertEqual(total, Double(D) + 9.0, accuracy: 0.0001,
                       "total = work(5) + sleep(4) + gym(D=\(D)); absorbed 'study' and stack 'errand' contribute nothing")

        // --- typeAllocations ---
        let allocations = viewModel.typeAllocations(store: store)
        let byType = Dictionary(uniqueKeysWithValues: allocations.map { ($0.type, $0.hours) })
        XCTAssertEqual(byType["work"] ?? -1, 5.0, accuracy: 0.0001)
        XCTAssertEqual(byType["sleep"] ?? -1, 4.0, accuracy: 0.0001)
        XCTAssertEqual(byType["gym"] ?? -1, Double(D), accuracy: 0.0001)
        XCTAssertNil(byType["study"], "absorbed todos must not form a type bucket")
        XCTAssertNil(byType["errand"], "dateless stack todo must not form a type bucket")
        XCTAssertEqual(allocations.count, 3, "exactly work/sleep/gym survive")

        // --- dailyHoursData ---
        let daily = viewModel.dailyHoursData(store: store)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.hours }, Double(D) + 9.0, accuracy: 0.0001,
                       "daily rows must sum to the same total")
        let gymRows = daily.filter { $0.type == "gym" }
        XCTAssertEqual(gymRows.count, D, "gym recurs on every one of the \(D) days")
        for row in gymRows {
            XCTAssertEqual(row.hours, 1.0, accuracy: 0.0001, "each gym day is 1h")
        }
        XCTAssertEqual(daily.filter { $0.type == "work" }.reduce(0) { $0 + $1.hours }, 5.0, accuracy: 0.0001)
        XCTAssertEqual(daily.filter { $0.type == "sleep" }.reduce(0) { $0 + $1.hours }, 4.0, accuracy: 0.0001,
                       "cross-midnight sleep totals 4h across its civil days")
        XCTAssertTrue(daily.allSatisfy { $0.type != "study" && $0.type != "errand" },
                      "no phantom daily bar from absorbed or dateless todos")
    }

    // MARK: - 2. Filter-count proof (constant, independent of D)

    /// A full `AnalysisAggregates.full` build evaluates
    /// `canvasRenderableCalendarEvents` a small CONSTANT number of times,
    /// independent of the range length. Pre-hoist the chart pass alone read it
    /// 2×D times (typeAllocations + dailyHoursData, once per day). The proof
    /// that the count no longer scales with D: run the SAME store through a
    /// day build (D=1) and a month build (D≈30) and assert the read count is
    /// identical — and equal to the constant 2.
    @MainActor
    func testFullBuildFilterReadsConstantIndependentOfRangeLength() {
        let store = makeStore([
            plainEvent(type: "work", start: dayHour(8), end: dayHour(10)),
            plainEvent(type: "study", start: dayHour(11), end: dayHour(12)),
        ])
        var reads = 0
        store.onCanvasRenderableComputed = { reads += 1 }
        let skillStore = SkillInsightStore(defaults: UserDefaults(suiteName: "hoistQA-skill-\(UUID())")!)

        let dayVM = AnalysisViewModel(initialPeriod: .day)
        dayVM.now = { dayVM.dateRange.end.addingTimeInterval(3600) }
        reads = 0
        _ = AnalysisAggregates.full(store: store, skillStore: skillStore, viewModel: dayVM, visible: true)
        let dayReads = reads

        let monthVM = AnalysisViewModel(initialPeriod: .month)
        monthVM.now = { monthVM.dateRange.end.addingTimeInterval(3600) }
        XCTAssertGreaterThanOrEqual(monthVM.daysInRange().count, 28)
        reads = 0
        _ = AnalysisAggregates.full(store: store, skillStore: skillStore, viewModel: monthVM, visible: true)
        let monthReads = reads

        XCTAssertEqual(dayReads, monthReads,
                       "filter reads scaled with range length: day=\(dayReads) month=\(monthReads) — hoist failed")
        XCTAssertEqual(monthReads, 2,
                       "a full build reads the filter exactly twice (typeAllocations + dailyHoursData); got \(monthReads)")
    }

    /// Independent (non-shared) restatement of the per-method invariant: over a
    /// month each of the three aggregations reads the filter exactly once.
    @MainActor
    func testEachMethodReadsFilterExactlyOnceOverMonth() {
        let store = makeStore([plainEvent(type: "work", start: dayHour(8), end: dayHour(10))])
        var reads = 0
        store.onCanvasRenderableComputed = { reads += 1 }

        let vm = AnalysisViewModel(initialPeriod: .month)
        vm.now = { vm.dateRange.end.addingTimeInterval(3600) }
        let D = vm.daysInRange().count
        XCTAssertGreaterThanOrEqual(D, 28)

        reads = 0; _ = vm.totalScheduledHours(store: store)
        XCTAssertEqual(reads, 1, "totalScheduledHours over \(D) days")
        reads = 0; _ = vm.typeAllocations(store: store)
        XCTAssertEqual(reads, 1, "typeAllocations over \(D) days")
        reads = 0; _ = vm.dailyHoursData(store: store)
        XCTAssertEqual(reads, 1, "dailyHoursData over \(D) days")
    }

    // MARK: - 3. Not-frozen positive control

    /// The hoisted local lives inside a single synchronous build, never as a
    /// cached property that outlives an @Published change. So two builds that
    /// straddle a store mutation must see DIFFERENT outputs. If the aggregate
    /// were frozen (renderable captured once and reused across builds) the
    /// second build would ignore the new event and this fails.
    @MainActor
    func testAggregatesReflectStoreMutation_notFrozenAcrossBuilds() {
        let vm = AnalysisViewModel(initialPeriod: .day)
        vm.now = { vm.dateRange.end.addingTimeInterval(3600) }

        let store = makeStore([plainEvent(type: "work", start: dayHour(8), end: dayHour(10))])
        let before = vm.totalScheduledHours(store: store)
        XCTAssertEqual(before, 2.0, accuracy: 0.0001)

        // Mutate the store between builds (a new, non-overlapping event).
        store.rawCalendarEvents.append(plainEvent(type: "work", start: dayHour(13), end: dayHour(16)))
        let after = vm.totalScheduledHours(store: store)
        XCTAssertEqual(after, 5.0, accuracy: 0.0001,
                       "second build must see the +3h event; a frozen/stale capture would still read 2h")
        XCTAssertNotEqual(before, after, accuracy: 0.0001)
    }

    // MARK: - 4. Boundary lock: raw-reading methods untouched (guardrail #2)

    /// `recordStreak` deliberately reads `rawCalendarEvents`, NOT the filter:
    /// a day whose only event is an absorbed todo still counts toward the
    /// streak. If the hoist had also swept the raw-reading methods onto the
    /// canvas filter, that day would vanish and the streak would drop. Anchors
    /// the streak on a day-period range ending on the absorbed-only day.
    @MainActor
    func testRecordStreakStillCountsAbsorbedOnlyDay_rawSourceUntouched() {
        // Day period, offset 0 → range ends today. Put an absorbed-only todo on
        // today; recordStreak walks back from today and must count it.
        let vm = AnalysisViewModel(initialPeriod: .day)
        let todayStart = calendar.startOfDay(for: Date())
        let absorbed = absorbedTodo(
            type: "study",
            start: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: todayStart)!,
            end: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: todayStart)!,
            parent: UUID()
        )
        let store = makeStore([absorbed])

        // The absorbed todo is filtered OUT of the hour metrics …
        vm.now = { vm.dateRange.end.addingTimeInterval(3600) }
        XCTAssertEqual(vm.totalScheduledHours(store: store), 0.0, accuracy: 0.0001,
                       "absorbed todo contributes no hours (filtered)")
        // … but STILL counts as 'logged something today' for the streak (raw).
        XCTAssertGreaterThanOrEqual(vm.recordStreak(store: store), 1,
                                    "recordStreak reads rawCalendarEvents; the absorbed-only day must still count")
    }

    // MARK: - Helpers

    /// Civil hour on today (day-period fixtures).
    private func dayHour(_ h: Int) -> Date {
        calendar.startOfDay(for: Date()).addingTimeInterval(TimeInterval(h * 3600))
    }
}
