//
//  MacLoadBenchmarkTests.swift
//  DoneMacTests
//
//  Phase-2 gate: the 10k-event load baseline. Exactly one snapshot read,
//  and cold load stays interactive-fast. The soft wall-clock bound is
//  deliberately generous (CI noise); the structural assertions are the
//  real gate.
//

import XCTest
@testable import Done

@MainActor
final class MacLoadBenchmarkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(count: Int) -> [Event] {
        (0..<count).map { i in
            let start = t0.addingTimeInterval(Double(i % 365) * 86_400 + Double(i % 12) * 3600)
            return Event(
                id: UUID(),
                title: "Fixture \(i)",
                timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
                kind: i % 4 == 0 ? .todo : .event
            )
        }
    }

    func testTenThousandEventLoadBaseline() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let rows = fixture(count: 10_000)
        do {
            let persistence = try MacPersistence(location: location)
            await persistence.submitCalendarEvents(rows, generation: 1, dominoStamp: nil)
            await persistence.flush()
        }

        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(
            persistence: persistence,
            bill: MacWorkBill(),
            calendar: Calendar(identifier: .gregorian)
        )
        let began = Date()
        await store.load()
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertEqual(store.calendarEvents.count, 10_000)
        XCTAssertLessThan(elapsed, 5.0, "10k cold load left the interactive class entirely")
        let stats = await persistence.stats
        XCTAssertEqual(stats.slotWrites, 0, "a LOAD wrote something")
    }
}
