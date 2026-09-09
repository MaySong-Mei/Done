//
//  MacDominoBedrockTests.swift
//  DoneMacTests
//
//  The Lean domino bedrock (gh#220 slice 3), re-pointed at MacEventStore:
//  same theorems, same fixtures, Mac commit path. If these diverge from
//  DoneTests/LeanDominoBedrockTests the thin store has drifted from the
//  iOS semantics — the plan's risk #3 tripwire.
//

import XCTest
@testable import Done

@MainActor
final class MacDominoBedrockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> MacEventStore {
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        return MacEventStore(
            persistence: persistence,
            bill: MacWorkBill(),
            calendar: Calendar(identifier: .gregorian)
        )
    }

    /// Stamp the first push, add the rows, push one hour later.
    private func pushed(_ events: [Event]) throws -> MacEventStore {
        let store = try makeStore()
        store.dominoPush(now: t0, horizonDays: 7)
        for e in events { store.addCalendarEvent(e, now: t0) }
        store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 7)
        return store
    }

    private func start(_ store: MacEventStore, _ id: UUID) -> Date? {
        store.calendarEvents.first { $0.id == id }?.timeRanges.first?.start
    }

    // THEOREM 24, clause "kind == .todo"
    func testEventKindIsNeverMoved() throws {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let store = try pushed([Event(
            id: id, title: "Commitment",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .event
        )])
        XCTAssertEqual(start(store, id), s, "an .event moved — bedrock violated")
    }

    // THEOREM 24, clause "start < horizon"
    func testNearFutureTodoIsNeverMoved() throws {
        let id = UUID()
        let s = t0.addingTimeInterval(2 * 86_400)
        let store = try pushed([Event(
            id: id, title: "NearFuture",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .todo
        )])
        XCTAssertEqual(start(store, id), s, "a .nearFuture todo moved — bedrock violated")
    }

    // THEOREM 24, clause "absorbed"
    func testAbsorbedTodoIsNeverMoved() throws {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let store = try pushed([Event(
            id: id, title: "Absorbed",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .todo,
            absorbedIntoEventID: UUID()
        )])
        XCTAssertEqual(start(store, id), s, "an absorbed todo moved")
    }

    // Mac filter parity: a recurring series template never moves.
    func testRecurringSeriesIsNeverMoved() throws {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        var series = Event(
            id: id, title: "Series",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .todo
        )
        series.repeatUnit = .day
        let store = try pushed([series])
        XCTAssertEqual(start(store, id), s, "a recurring series template moved")
    }

    // THEOREM 29 (frame condition): only timeRanges slide.
    func testDeadlineSurvivesThePush() throws {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let deadline = t0.addingTimeInterval(60 * 86_400)
        let store = try pushed([Event(
            id: id, title: "WithDeadline",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            deadline: deadline,
            kind: .todo
        )])
        let row = store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(row?.timeRanges.first?.start, s.addingTimeInterval(3600),
                       "the eligible todo should have moved by the elapsed hour")
        XCTAssertEqual(row?.deadline, deadline,
                       "the deadline moved — auto-defer touched the commitment")
    }

    // THEOREM 28 + 27: both endpoints slide together; horizon distance exact.
    func testDurationAndHorizonDistancePreserved() throws {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let store = try pushed([Event(
            id: id, title: "Slides",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(5400))],
            kind: .todo
        )])
        let range = store.calendarEvents.first { $0.id == id }?.timeRanges.first
        XCTAssertEqual(range.map { $0.end.timeIntervalSince($0.start) }, 5400)
        XCTAssertEqual(range?.start, s.addingTimeInterval(3600))
    }

    // THEOREM 26 (additivity): two pushes equal one whole-span push.
    func testTwoPushesEqualOneWholeSpanPush() throws {
        let idA = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        func makeRow() -> Event {
            Event(id: idA, title: "Additive",
                  timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
                  kind: .todo)
        }
        let twoStep = try makeStore()
        twoStep.dominoPush(now: t0, horizonDays: 7)
        twoStep.addCalendarEvent(makeRow(), now: t0)
        twoStep.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 7)
        twoStep.dominoPush(now: t0.addingTimeInterval(9600), horizonDays: 7)

        let oneStep = try makeStore()
        oneStep.dominoPush(now: t0, horizonDays: 7)
        oneStep.addCalendarEvent(makeRow(), now: t0)
        oneStep.dominoPush(now: t0.addingTimeInterval(9600), horizonDays: 7)

        XCTAssertEqual(start(twoStep, idA), start(oneStep, idA))
        XCTAssertEqual(start(twoStep, idA), s.addingTimeInterval(9600))
    }

    // Boundary convention: a todo exactly AT the horizon-as-of-last-push moves.
    func testTodoExactlyAtHorizonBoundaryMoves() throws {
        let id = UUID()
        let s = EventZone.horizonDate(from: 7, now: t0)
        let store = try pushed([Event(
            id: id, title: "AtBoundary",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .todo
        )])
        XCTAssertEqual(start(store, id), s.addingTimeInterval(3600),
                       "a todo at the exact horizon boundary belongs to the future group")
    }

    // Sub-threshold delta: nothing moves AND the stamp does not advance,
    // so the deferred drift lands intact on the next real push.
    func testSubThresholdPushIsLosslesslyDeferred() throws {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let store = try makeStore()
        store.dominoPush(now: t0, horizonDays: 7)
        store.addCalendarEvent(Event(
            id: id, title: "Deferred",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .todo
        ), now: t0)
        store.dominoPush(now: t0.addingTimeInterval(30), horizonDays: 7)
        XCTAssertEqual(start(store, id), s, "sub-threshold push must not move rows")
        XCTAssertEqual(store.dominoLastPushEffective, t0, "sub-threshold push must not advance the stamp")
        store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 7)
        XCTAssertEqual(start(store, id), s.addingTimeInterval(3600),
                       "the full elapsed hour lands on the next real push")
    }

    // First-ever push only seeds the stamp; rows never move on it.
    func testFirstPushSeedsStampWithoutMoving() throws {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let store = try makeStore()
        store.addCalendarEvent(Event(
            id: id, title: "Seed",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .todo
        ), now: t0)
        store.dominoPush(now: t0, horizonDays: 7)
        XCTAssertEqual(start(store, id), s)
        XCTAssertEqual(store.dominoLastPushEffective, t0)
    }
}
