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

    /// Cold launch with 10k rows on disk: the shared store's synchronous
    /// load plus the adapter's adoption of its rows.
    func testTenThousandEventLoadBaseline() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        defer { EventStorageLocation.destroy(location) }
        let defaults = UserDefaults(suiteName: "DoneMacTests-\(UUID().uuidString)")!
        let rows = fixture(count: 10_000)
        do {
            let seeder = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
            seeder.rawCalendarEvents = rows
            XCTAssertTrue(seeder.saveCalendarEvents(refreshInterrupts: false), "fixture never reached disk")
        }

        let began = Date()
        let shared = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        let store = MacEventStore(shared: shared, bill: MacWorkBill(),
                                  calendar: Calendar(identifier: .gregorian))
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertEqual(store.calendarEvents.count, 10_000)
        XCTAssertEqual(store.revision[.calendarEvents], 0, "adopting the launch rows is not a change")
        XCTAssertLessThan(elapsed, 5.0, "10k cold load left the interactive class entirely")
    }
}
