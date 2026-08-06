//
//  DominoPushIntervalTests.swift
//  DoneTests
//
//  The Domino push rewrites the ENTIRE calendar blob every time it moves
//  anything. On the launch path it used to run twice — `.onAppear` and the
//  launch `.onChange(of: scenePhase)` both call `handleDominoScenePhase(.active)`
//  a few hundred ms apart — so a cold start cost two full-blob writes for a
//  second push whose delta was under a second (≈0.02pt of movement).
//
//  The fix is a minimum-interval guard that returns WITHOUT stamping the
//  last-push timestamp. These tests pin the two properties that make that safe:
//  the sub-threshold call moves nothing, and the skipped interval is not lost —
//  the next above-threshold call applies the FULL accumulated delta.
//

import XCTest
@testable import Done

@MainActor
final class DominoPushIntervalTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DominoPushIntervalTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A far-future todo: past the horizon, so Domino owns it.
    private func makeParkedTodo(start: Date) -> Event {
        Event(
            title: "Parked",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
            kind: .todo
        )
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults,
                   storage: .isolated(name: suiteName),
                   seedsSampleDataIfEmpty: false)
    }

    private func firstStart(_ store: EventStore) -> Date {
        store.rawCalendarEvents[0].timeRanges[0].start
    }

    func testSubThresholdDeltaMovesNothing() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // First call only stamps — there is no last-push to diff against.
        store.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)

        store.addCalendarEvent(makeParkedTodo(start: t0.addingTimeInterval(30 * 86_400)))
        let before = firstStart(store)

        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(0.5), horizonDays: 7)
        XCTAssertEqual(firstStart(store), before,
                       "a half-second delta must not shift anything")

        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(59), horizonDays: 7)
        XCTAssertEqual(firstStart(store), before,
                       "still below the 60s threshold")
    }

    /// The load-bearing safety property: skipping must not stamp, so the
    /// skipped interval is applied in full later. If the guard stamped, the
    /// todo would land at t0+120 minus the two skipped hops.
    func testSkippedIntervalIsAppliedInFullByTheNextPush() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        store.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)

        store.addCalendarEvent(makeParkedTodo(start: t0.addingTimeInterval(30 * 86_400)))
        let before = firstStart(store)

        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(0.5), horizonDays: 7)
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(59), horizonDays: 7)
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(120), horizonDays: 7)

        XCTAssertEqual(firstStart(store).timeIntervalSince(before), 120, accuracy: 0.001,
                       "the full 120s must be applied, not 120 - 59")
    }

    /// Many sub-threshold ticks followed by one real one must equal a single
    /// push over the whole span — the guard trades write frequency, never data.
    func testManySkipsEqualOneWholeSpanPush() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let parkedStart = t0.addingTimeInterval(30 * 86_400)

        let chopped = makeStore()
        chopped.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        chopped.addCalendarEvent(makeParkedTodo(start: parkedStart))
        for i in 1...20 {
            chopped.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(Double(i) * 2), horizonDays: 7)
        }
        chopped.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(300), horizonDays: 7)

        XCTAssertEqual(firstStart(chopped).timeIntervalSince(parkedStart), 300, accuracy: 0.001)
    }

    /// The horizon line and partial-day tint redraw off `dominoTickNonce`;
    /// skipping the push must not skip the redraw.
    func testNonceStillBumpsOnASkippedTick() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        store.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        let before = store.dominoTickNonce
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(0.4), horizonDays: 7)
        XCTAssertEqual(store.dominoTickNonce, before &+ 1)
    }

    /// The duplicate launch-time save, expressed as the property that matters:
    /// two `.active` entries a fraction of a second apart produce exactly one
    /// push, not two.
    func testTwoLaunchTimeActiveEntriesProduceOnePush() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // Previous session left a stamp ~21s ago (measured shape on device).
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(-21), horizonDays: 7)
        store.addCalendarEvent(makeParkedTodo(start: t0.addingTimeInterval(30 * 86_400)))
        let before = firstStart(store)

        // .onAppear
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(60), horizonDays: 7)
        let afterFirst = firstStart(store)
        XCTAssertEqual(afterFirst.timeIntervalSince(before), 81, accuracy: 0.001)

        // .onChange(of: scenePhase), 0.45s later — the redundant one.
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(60.45), horizonDays: 7)
        XCTAssertEqual(firstStart(store), afterFirst,
                       "the second launch-time entry must be a no-op")
    }
}
