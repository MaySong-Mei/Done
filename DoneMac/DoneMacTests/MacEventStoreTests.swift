//
//  MacEventStoreTests.swift
//  DoneMacTests
//
//  Delta/observation semantics of the Mac adapter over the shared
//  EventStore: every change to the calendar rows — a Mac edit or a write
//  the shared store makes on its own (sync apply, restore) — is exactly one
//  generation bump and one delta; recipients are filtered by interest.
//

import XCTest
@testable import Done

@MainActor
final class MacEventStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    private func makeStore() async throws -> MacEventStore {
        let store = MacTestStore.make(bill: MacWorkBill(), calendar: calendar)
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

    func testRemoveEmitsOldDayKeys() async throws {
        let store = try await makeStore()
        let id = UUID()
        store.addCalendarEvent(event(id: id, start: t0), now: t0)
        var received: [CommitDelta] = []
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { received.append($0) }

        store.removeCalendarEvent(id: id, now: t0)

        XCTAssertEqual(store.calendarEvents.count, 0)
        XCTAssertEqual(store.revision[.calendarEvents], 2)
        XCTAssertEqual(received.first?.changedIDs, [id])
        XCTAssertEqual(received.first?.affectedDayKeys,
                       DayKey.keys(spanning: .init(start: t0, end: t0.addingTimeInterval(3600)), calendar: calendar),
                       "a removed row must invalidate the days it used to occupy")
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

    // MARK: - Writes the Mac did not make (the adapter's reason to exist)

    /// The sync engine applies other devices' rows straight into the shared
    /// store. The canvas only hears CommitDelta, so such a write must produce
    /// one — or a row edited on the iPhone never appears on the Mac.
    func testAWriteMadeDirectlyOnTheSharedStoreEmitsADelta() async throws {
        let store = try await makeStore()
        var received: [CommitDelta] = []
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { received.append($0) }

        let id = UUID()
        store.shared.rawCalendarEvents.append(event(id: id, start: t0))
        store.flushPendingDeltas()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.changedIDs, [id])
        XCTAssertEqual(store.calendarEvents.map(\.id), [id],
                       "the adapter's rows must already be the new ones when observers run")
    }

    /// Handlers run while the shared store's @Published is still in willSet;
    /// a handler that reads the ADAPTER must see the new rows.
    func testObserversReadTheNewRowsDuringTheirCallback() async throws {
        let store = try await makeStore()
        var seenCount: Int?
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { _ in
            seenCount = store.calendarEvents.count
        }
        store.addCalendarEvent(event(start: t0), now: t0)
        XCTAssertEqual(seenCount, 1)
    }

    func testReorderingWithoutChangeEmitsNoDelta() async throws {
        let a = event(start: t0), b = event(start: t0.addingTimeInterval(7200))
        let store = MacTestStore.make(seed: [a, b], calendar: calendar)
        var hits = 0
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { _ in hits += 1 }

        store.shared.rawCalendarEvents = [b, a]
        store.flushPendingDeltas()

        XCTAssertEqual(hits, 0, "same rows, new order: nothing to invalidate")
        XCTAssertEqual(store.calendarEvents.map(\.id), [b.id, a.id])
        XCTAssertEqual(store.revision[.calendarEvents], 0)
    }

    func testAChangeAboveTheBulkThresholdClaimsEveryDay() async throws {
        let store = try await makeStore()
        var received: [CommitDelta] = []
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { received.append($0) }

        let rows = (0...MacEventStore.bulkThreshold).map { event(start: t0.addingTimeInterval(Double($0) * 3600)) }
        store.shared.rawCalendarEvents = rows
        store.flushPendingDeltas()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.changedIDs.count, MacEventStore.bulkThreshold + 1)
        XCTAssertNil(received.first?.affectedDayKeys, "a bulk change must claim every day, never a guess")
    }

    /// The sync applier writes the array once per tombstone. Those writes
    /// must cost ONE diff for the turn, not one per write (review #3).
    func testOutsideWritesInOneTurnCoalesceIntoOneDelta() async throws {
        let rows = (0..<5).map { event(start: t0.addingTimeInterval(Double($0) * 3600)) }
        let store = MacTestStore.make(seed: rows, calendar: calendar)
        var received: [CommitDelta] = []
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { received.append($0) }

        for row in rows.prefix(3) {
            store.shared.rawCalendarEvents.removeAll { $0.id == row.id }
        }
        XCTAssertTrue(received.isEmpty, "outside writes must not diff inside the writer's call")
        store.flushPendingDeltas()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.changedIDs, Set(rows.prefix(3).map(\.id)))
        XCTAssertEqual(store.calendarEvents.count, 2)
    }

    /// Nothing calls the flush in production: the main-queue turn does.
    func testAnOutsideWriteIsDescribedOnTheNextTurnWithoutAFlush() async throws {
        let store = try await makeStore()
        var received: [CommitDelta] = []
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { received.append($0) }

        store.shared.rawCalendarEvents.append(event(start: t0))
        XCTAssertTrue(received.isEmpty)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(received.count, 1, "the scheduled flush never landed")
    }

    /// A handler that mutates the store must neither re-enter `emit` nor lose
    /// its write: its delta follows on the next turn.
    func testAMutationFromInsideAHandlerIsDeliveredAfterwards() async throws {
        let store = try await makeStore()
        var received: [CommitDelta] = []
        let follower = UUID()
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { delta in
            received.append(delta)
            if received.count == 1 {
                store.addCalendarEvent(self.event(id: follower, start: self.t0), now: self.t0)
            }
        }

        store.addCalendarEvent(event(start: t0), now: t0)
        XCTAssertEqual(received.count, 1, "the nested write must not re-enter emit")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last?.changedIDs, [follower])
        XCTAssertTrue(store.calendarEvents.contains { $0.id == follower })
    }

    // MARK: - Persistence goes through the shared store

    func testAMacEditReachesTheSharedStoresDisk() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        defer { EventStorageLocation.destroy(location) }
        let defaults = UserDefaults(suiteName: "DoneMacTests-\(UUID().uuidString)")!
        let id = UUID()
        do {
            let shared = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
            let store = MacEventStore(shared: shared, bill: MacWorkBill(), calendar: calendar)
            store.addCalendarEvent(event(id: id, title: "Durable", start: t0), now: t0)
        }
        let reopened = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        XCTAssertEqual(reopened.rawCalendarEvents.map(\.id), [id])
        XCTAssertEqual(reopened.rawCalendarEvents.first?.title, "Durable")
    }
}
