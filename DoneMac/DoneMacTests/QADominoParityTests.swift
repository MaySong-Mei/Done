//
//  QADominoParityTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA — domino parity oracle (attack surface 1).
//
//  The iOS logic (Done/Models/EventStore.swift, dominoPushTodosPastHorizon,
//  lines 488-563 @ c07231d) cannot be linked into this macOS test bundle
//  (EventStore is an iOS ObservableObject), so the iOS algorithm is
//  TRANSCRIBED below as a pure reference function, line for line:
//    - nil stamp: seed only, no movement          (iOS 489-493)
//    - delta <= 0: return, stamp NOT advanced     (iOS 494-495)
//    - delta < 60: return, stamp NOT advanced     (iOS 512-515)
//    - horizonAtLast = horizonDate(from: CURRENT horizonDays, now: LAST)
//                                                 (iOS 530)
//    - filter: .todo, not absorbed, not series, firstStart >= horizonAtLast
//                                                 (iOS 541-545)
//    - shift ALL ranges by delta uniformly        (iOS 546-551)
//    - stamp advances only on a real (>= 60s) push (iOS 554)
//  Any divergence between MacEventStore and this transcription is a parity
//  break. The transcription is the oracle; if the transcription itself is
//  wrong, the cited lines are the arbiter.
//

import XCTest
@testable import Done

@MainActor
final class QADominoParityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func makeStore() async throws -> MacEventStore {
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: MacWorkBill(),
                                  calendar: Self.utcCalendar())
        await store.load()
        return store
    }

    // MARK: - iOS reference transcription (the oracle)

    private struct RefState {
        var events: [Event]
        var last: Date?
    }

    /// Transcription of EventStore.dominoPushTodosPastHorizon (iOS), minus
    /// persistence/nonce side effects (which have no Mac data equivalent).
    private func refPush(_ state: inout RefState, now: Date, horizonDays: Int) {
        guard let last = state.last else {
            state.last = now
            return
        }
        let delta = now.timeIntervalSince(last)
        guard delta > 0 else { return }
        guard delta >= 60 else { return }                      // dominoMinimumPushInterval
        let horizonAtLast = EventZone.horizonDate(from: horizonDays, now: last)
        for i in state.events.indices {
            let event = state.events[i]
            guard event.kind == .todo,
                  event.absorbedIntoEventID == nil,
                  !event.isRecurringSeries,
                  let firstStart = event.timeRanges.first?.start,
                  firstStart >= horizonAtLast else { continue }
            state.events[i].timeRanges = event.timeRanges.map { range in
                Event.TimeRange(
                    start: range.start.addingTimeInterval(delta),
                    end: range.end.addingTimeInterval(delta)
                )
            }
        }
        state.last = now
    }

    /// Drive the Mac store and the reference through an identical schedule
    /// and demand byte-equal rows plus stamp agreement at every step.
    private func assertParity(
        events: [Event],
        schedule: [(now: Date, horizonDays: Int)],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let store = try await makeStore()
        var ref = RefState(events: events, last: nil)

        // Seed both stamps at t0 before rows exist (matches bedrock tests).
        store.dominoPush(now: t0, horizonDays: 7)
        refPush(&ref, now: t0, horizonDays: 7)
        for e in events { store.addCalendarEvent(e, now: t0) }

        for (index, step) in schedule.enumerated() {
            store.dominoPush(now: step.now, horizonDays: step.horizonDays)
            refPush(&ref, now: step.now, horizonDays: step.horizonDays)
            XCTAssertEqual(store.calendarEvents, ref.events,
                           "parity break at step \(index) (now offset \(step.now.timeIntervalSince(t0))s, horizonDays \(step.horizonDays))",
                           file: file, line: line)
            XCTAssertEqual(store.dominoLastPushEffective, ref.last,
                           "stamp divergence at step \(index)",
                           file: file, line: line)
        }
    }

    // MARK: - Fixture builders

    private func todo(id: UUID = UUID(), title: String = "T",
                      startOffset: TimeInterval, durations: [TimeInterval] = [3600],
                      gap: TimeInterval = 7200,
                      absorbed: Bool = false, series: Bool = false) -> Event {
        var ranges: [Event.TimeRange] = []
        var cursor = t0.addingTimeInterval(startOffset)
        for d in durations {
            ranges.append(.init(start: cursor, end: cursor.addingTimeInterval(d)))
            cursor = cursor.addingTimeInterval(d + gap)
        }
        var e = Event(id: id, title: title, timeRanges: ranges, kind: .todo,
                      absorbedIntoEventID: absorbed ? UUID() : nil)
        if series { e.repeatUnit = .day }
        return e
    }

    // MARK: - Matrix parity

    func testParityAcrossMixedScheduleAndFilterClasses() async throws {
        let events: [Event] = [
            todo(title: "far", startOffset: 30 * 86_400),
            todo(title: "near", startOffset: 2 * 86_400),
            todo(title: "past", startOffset: -3 * 86_400),
            todo(title: "absorbed-far", startOffset: 30 * 86_400, absorbed: true),
            todo(title: "series-far", startOffset: 30 * 86_400, series: true),
            todo(title: "empty-ranges", startOffset: 0, durations: []),
            todo(title: "multi-far", startOffset: 20 * 86_400, durations: [1800, 3600, 900]),
            Event(id: UUID(), title: "commitment",
                  timeRanges: [.init(start: t0.addingTimeInterval(30 * 86_400),
                                     end: t0.addingTimeInterval(30 * 86_400 + 3600))],
                  kind: .event),
            todo(title: "at-boundary", startOffset: 7 * 86_400),
        ]
        // Backwards clock, zero delta, sub-threshold, real pushes, a long
        // gap, and horizonDays changing BETWEEN pushes in both directions.
        let schedule: [(now: Date, horizonDays: Int)] = [
            (t0.addingTimeInterval(-300), 7),        // backwards
            (t0, 7),                                 // zero delta
            (t0.addingTimeInterval(30), 7),          // sub-threshold
            (t0.addingTimeInterval(3600), 7),        // real push
            (t0.addingTimeInterval(3600), 7),        // zero delta after push
            (t0.addingTimeInterval(3660), 1),        // horizon SHRANK between pushes
            (t0.addingTimeInterval(4 * 86_400), 30), // horizon GREW + multi-day gap
            (t0.addingTimeInterval(4 * 86_400 + 45), 30), // sub-threshold again
            (t0.addingTimeInterval(9 * 86_400), 7),  // back to default
        ]
        try await assertParity(events: events, schedule: schedule)
    }

    func testParityRandomizedSweepSeeded() async throws {
        // Deterministic LCG so a failure is reproducible from the seed.
        var state: UInt64 = 0x5EED_5EED_5EED_5EED
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }

        var events: [Event] = []
        for i in 0..<40 {
            let offset = Double(Int(next() % 45) - 5) * 86_400 + Double(next() % 24) * 3600
            let durations: [TimeInterval] = pick([[3600], [1800, 5400], []])
            events.append(todo(title: "R\(i)", startOffset: offset,
                               durations: durations,
                               absorbed: next() % 5 == 0,
                               series: next() % 7 == 0))
        }
        var offset: TimeInterval = 0
        var schedule: [(now: Date, horizonDays: Int)] = []
        for _ in 0..<12 {
            offset += pick([-300, 0, 30, 90, 3600, 3 * 86_400, 45, 7200])
            schedule.append((t0.addingTimeInterval(offset), pick([1, 7, 30])))
        }
        try await assertParity(events: events, schedule: schedule)
    }

    // MARK: - Named edges (each one line of the oracle, isolated)

    func testBackwardsClockMovesNothingAndKeepsStamp() async throws {
        let id = UUID()
        let store = try await makeStore()
        store.dominoPush(now: t0, horizonDays: 7)
        store.addCalendarEvent(todo(id: id, startOffset: 30 * 86_400), now: t0)
        store.dominoPush(now: t0.addingTimeInterval(-7200), horizonDays: 7)
        XCTAssertEqual(store.calendarEvents.first?.timeRanges.first?.start,
                       t0.addingTimeInterval(30 * 86_400),
                       "a backwards clock must not move rows")
        XCTAssertEqual(store.dominoLastPushEffective, t0,
                       "a backwards clock must not regress the stamp — a regressed stamp re-applies the gap on the next push")
        // And the forward push afterwards applies exactly now-last, not
        // now-(backwards moment).
        store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 7)
        XCTAssertEqual(store.calendarEvents.first?.timeRanges.first?.start,
                       t0.addingTimeInterval(30 * 86_400 + 3600))
    }

    func testEmptyTimeRangesTodoIsUntouched() async throws {
        let id = UUID()
        let store = try await makeStore()
        store.dominoPush(now: t0, horizonDays: 7)
        store.addCalendarEvent(todo(id: id, startOffset: 0, durations: []), now: t0)
        store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 7)
        let row = store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(row?.timeRanges.count, 0, "an empty-range todo must survive a push untouched")
    }

    func testMultiRangeTodoShiftsAllRangesUniformly() async throws {
        let id = UUID()
        let store = try await makeStore()
        store.dominoPush(now: t0, horizonDays: 7)
        let row = todo(id: id, startOffset: 20 * 86_400, durations: [1800, 3600, 900])
        let before = row.timeRanges
        store.addCalendarEvent(row, now: t0)
        store.dominoPush(now: t0.addingTimeInterval(7200), horizonDays: 7)
        let after = store.calendarEvents.first { $0.id == id }?.timeRanges ?? []
        XCTAssertEqual(after.count, 3)
        for (b, a) in zip(before, after) {
            XCTAssertEqual(a.start, b.start.addingTimeInterval(7200),
                           "every range must shift by the same delta (iOS 539: 'mutates ALL ranges uniformly')")
            XCTAssertEqual(a.end, b.end.addingTimeInterval(7200))
        }
    }

    /// iOS filters on `timeRanges.first?.start` ONLY (line 544). A todo whose
    /// FIRST range is inside the horizon does not move even if a later range
    /// is past it. The Mac port must not "improve" this into an any-range rule.
    func testFirstRangeInsideHorizonBlocksTheWholeTodo() async throws {
        let id = UUID()
        let store = try await makeStore()
        store.dominoPush(now: t0, horizonDays: 7)
        var e = Event(id: id, title: "straddler", timeRanges: [
            .init(start: t0.addingTimeInterval(2 * 86_400),
                  end: t0.addingTimeInterval(2 * 86_400 + 3600)),
            .init(start: t0.addingTimeInterval(20 * 86_400),
                  end: t0.addingTimeInterval(20 * 86_400 + 3600)),
        ], kind: .todo)
        e.repeatUnit = .none
        store.addCalendarEvent(e, now: t0)
        store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 7)
        let after = store.calendarEvents.first { $0.id == id }?.timeRanges
        XCTAssertEqual(after?.first?.start, t0.addingTimeInterval(2 * 86_400),
                       "firstStart rules the filter — parity with iOS line 544")
        XCTAssertEqual(after?.last?.start, t0.addingTimeInterval(20 * 86_400),
                       "no partial shift of later ranges")
    }

    /// The real candidate divergence named in the plan: horizonDays changes
    /// BETWEEN pushes. Both sides compute horizonAtLast from the NEW
    /// horizonDays over the OLD stamp — arithmetic check with exact numbers.
    func testHorizonDaysShrinkBetweenPushesUsesNewDaysOverOldStamp() async throws {
        let id = UUID()
        let store = try await makeStore()
        store.dominoPush(now: t0, horizonDays: 7)                 // stamp = t0
        // Todo parked 2 days out: inside a 7-day horizon, past a 1-day one.
        store.addCalendarEvent(todo(id: id, startOffset: 2 * 86_400), now: t0)
        store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 1)
        // horizonAtLast = t0 + 1*86400. firstStart = t0 + 2*86400 >= that → moves.
        XCTAssertEqual(store.calendarEvents.first?.timeRanges.first?.start,
                       t0.addingTimeInterval(2 * 86_400 + 3600),
                       "with the NEW horizonDays (1) over the OLD stamp, the 2-day todo is past horizon and must move — iOS line 530 does exactly this")
    }

    func testHorizonDaysGrowBetweenPushesAbandonsSwallowedTodoOnBothPlatforms() async throws {
        let id = UUID()
        let store = try await makeStore()
        store.dominoPush(now: t0, horizonDays: 7)                 // stamp = t0
        // Parked 10 days out under a 7-day horizon (was "future").
        store.addCalendarEvent(todo(id: id, startOffset: 10 * 86_400), now: t0)
        store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 30)
        // horizonAtLast = t0 + 30d; firstStart = t0 + 10d < that → skipped.
        XCTAssertEqual(store.calendarEvents.first?.timeRanges.first?.start,
                       t0.addingTimeInterval(10 * 86_400),
                       "a horizon grown past a parked todo swallows it into near-future on BOTH platforms (same formula); this is parity, recorded deliberately")
    }
}
