//
//  MacEventStoreTests.swift
//  DoneMacTests
//
//  Commit/delta/observation semantics of the Mac truth store: every
//  mutation is exactly one generation bump and one delta; recipients are
//  filtered by interest; the sidecar tracks per-record revisions.
//

import XCTest
@testable import Done

@MainActor
final class MacEventStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    private func makeStore() async throws -> MacEventStore {
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
        await store.load()
        return store
    }

    private func event(id: UUID = UUID(), title: String = "E", start: Date, hours: Double = 1) -> Event {
        Event(id: id, title: title,
              timeRanges: [.init(start: start, end: start.addingTimeInterval(hours * 3600))],
              kind: .event)
    }

    // MARK: - Generations and deltas

    func testAddBumpsGenerationAndEmitsExactDelta() async throws {
        let store = try await makeStore()
        var received: [CommitDelta] = []
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { received.append($0) }

        let id = UUID()
        store.addCalendarEvent(event(id: id, start: t0), now: t0)

        XCTAssertEqual(store.revision[.calendarEvents], 1)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.changedIDs, [id])
        XCTAssertEqual(received.first?.generation, 1)
        XCTAssertEqual(received.first?.affectedDayKeys, DayKey.keys(spanning: .init(start: t0, end: t0.addingTimeInterval(3600)), calendar: calendar))
    }

    func testReplaceEmitsUnionOfOldAndNewDayKeys() async throws {
        let store = try await makeStore()
        let id = UUID()
        store.addCalendarEvent(event(id: id, start: t0), now: t0)

        var received: [CommitDelta] = []
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { received.append($0) }

        let movedStart = t0.addingTimeInterval(10 * 86_400)
        store.replaceCalendarEvent(event(id: id, start: movedStart), now: t0)

        XCTAssertEqual(store.revision[.calendarEvents], 2)
        let expected = DayKey.keys(spanning: .init(start: t0, end: t0.addingTimeInterval(3600)), calendar: calendar)!
            .union(DayKey.keys(spanning: .init(start: movedStart, end: movedStart.addingTimeInterval(3600)), calendar: calendar)!)
        XCTAssertEqual(received.first?.affectedDayKeys, expected,
                       "a move must invalidate BOTH the source and target days")
    }

    func testIdenticalReplaceIsANoOp() async throws {
        let store = try await makeStore()
        let id = UUID()
        let row = event(id: id, start: t0)
        store.addCalendarEvent(row, now: t0)
        var received = 0
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { _ in received += 1 }

        store.replaceCalendarEvent(row, now: t0.addingTimeInterval(60))

        XCTAssertEqual(store.revision[.calendarEvents], 1, "identical replace must not bump the generation")
        XCTAssertEqual(received, 0, "identical replace must not emit a delta")
    }

    func testRemoveEmitsOldDayKeysAndDropsSidecarEntry() async throws {
        let store = try await makeStore()
        let id = UUID()
        store.addCalendarEvent(event(id: id, start: t0), now: t0)
        XCTAssertNotNil(store.sidecar.records[id])

        store.removeCalendarEvent(id: id, now: t0)

        XCTAssertEqual(store.calendarEvents.count, 0)
        XCTAssertEqual(store.revision[.calendarEvents], 2)
        XCTAssertNil(store.sidecar.records[id], "a removed record's sidecar entry must go with it")
    }

    // Literal fixture (review finding 15): the range→DayKey mapping pinned
    // by hand-written civil values, not by the function under test.
    func testDayKeyLiteralTwoDayFixture() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 2026-03-10 23:30 UTC + 2h ends 2026-03-11 01:30 UTC.
        let start = Date(timeIntervalSince1970: 1_773_185_400)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(7200))
        XCTAssertEqual(
            DayKey.keys(spanning: range, calendar: cal),
            [DayKey(year: 2026, month: 3, day: 10), DayKey(year: 2026, month: 3, day: 11)]
        )
    }

    // MARK: - Interest filtering (concept 1: recipients)

    func testDayKeyInterestFiltersDeltas() async throws {
        let store = try await makeStore()
        let todayKey = DayKey(date: t0, calendar: calendar)
        let farKey = DayKey(date: t0.addingTimeInterval(20 * 86_400), calendar: calendar)

        var todayHits = 0
        var farHits = 0
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents], dayKeys: [todayKey])) { _ in todayHits += 1 }
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents], dayKeys: [farKey])) { _ in farHits += 1 }

        store.addCalendarEvent(event(start: t0), now: t0)

        XCTAssertEqual(todayHits, 1)
        XCTAssertEqual(farHits, 0, "an uninterested day observer heard a delta — recipients leak")
    }

    func testWrongSlotObserverHearsNothing() async throws {
        let store = try await makeStore()
        var hits = 0
        store.addObserver(interest: StoreInterest(slots: [.todoLists])) { _ in hits += 1 }
        store.addCalendarEvent(event(start: t0), now: t0)
        XCTAssertEqual(hits, 0)
    }

    func testRemovedObserverStopsReceiving() async throws {
        let store = try await makeStore()
        var hits = 0
        let token = store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { _ in hits += 1 }
        store.addCalendarEvent(event(start: t0), now: t0)
        store.removeObserver(token)
        store.addCalendarEvent(event(start: t0), now: t0)
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(store.observerCount, 0)
    }

    // MARK: - Sidecar revisions (concept 3, per-record half)

    func testSidecarBumpsOnlyChangedRecords() async throws {
        let store = try await makeStore()
        let a = UUID(), b = UUID()
        store.addCalendarEvent(event(id: a, start: t0), now: t0)
        store.addCalendarEvent(event(id: b, start: t0), now: t0)
        XCTAssertEqual(store.sidecar.records[a]?.revision, 1)
        XCTAssertEqual(store.sidecar.records[b]?.revision, 1)

        store.replaceCalendarEvent(event(id: a, title: "changed", start: t0), now: t0.addingTimeInterval(60))

        XCTAssertEqual(store.sidecar.records[a]?.revision, 2)
        XCTAssertEqual(store.sidecar.records[b]?.revision, 1,
                       "an untouched record's revision moved — per-record identity broken")
        XCTAssertEqual(store.sidecar.records[a]?.updatedAt, t0.addingTimeInterval(60))
    }

    // MARK: - Persistence round trip through the store

    func testCommittedStateSurvivesReload() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let id = UUID()
        do {
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            store.addCalendarEvent(event(id: id, title: "Durable", start: t0), now: t0)
            await store.flush()
        }
        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
        await store.load()
        XCTAssertEqual(store.calendarEvents.count, 1)
        XCTAssertEqual(store.calendarEvents.first?.id, id)
        XCTAssertEqual(store.sidecar.records[id]?.revision, 1,
                       "sidecar must survive the reload alongside the rows")
    }

    func testDominoStampSurvivesReloadViaEnvelope() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let id = UUID()
        let farStart = t0.addingTimeInterval(30 * 86_400)
        do {
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            store.dominoPush(now: t0, horizonDays: 7)
            store.addCalendarEvent(Event(
                id: id, title: "Far",
                timeRanges: [.init(start: farStart, end: farStart.addingTimeInterval(3600))],
                kind: .todo), now: t0)
            store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 7)
            await store.flush()
        }
        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
        await store.load()
        XCTAssertEqual(store.dominoLastPushEffective, t0.addingTimeInterval(3600),
                       "the stamp rides with the rows; losing it re-applies the whole delta")
        // And the catch-up after reload continues from the stamp, not from zero.
        store.dominoPush(now: t0.addingTimeInterval(7200), horizonDays: 7)
        XCTAssertEqual(store.calendarEvents.first?.timeRanges.first?.start,
                       farStart.addingTimeInterval(7200))
    }

    // MARK: - Sidecar orphan tripwire (plan risk #4)

    func testSidecarOrphanTripwireCountsOnLoad() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        do {
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            let id = UUID()
            store.addCalendarEvent(event(id: id, start: t0), now: t0)
            await store.flush()
            // Sabotage: rewrite rows without the record, keeping the sidecar.
            await persistence.submitCalendarEvents([], generation: 99, dominoStamp: nil)
            await persistence.flush()
        }
        let persistence = try MacPersistence(location: location)
        let bill = MacWorkBill()
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        XCTAssertEqual(bill.count(.sidecarOrphansSeen), 1,
                       "an orphaned sidecar entry must trip the counter on load")
    }
}
