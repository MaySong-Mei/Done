//
//  QA5DeleteResurrectionTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA round 5 — local delete vs the phase-1 pull (attack
//  surface 4). Phase 1 documents "no tombstones", but the CONSEQUENCE is
//  never stated anywhere: deleting a synced event on the Mac drops its
//  sidecar entry, which makes the row CLEAN, which makes the next pull
//  adopt the server copy right back. The user's delete silently un-does
//  itself. Pinned green (documented-gap adjudication belongs to the
//  report); the control shows local-only rows do stay deleted.
//

import XCTest
@testable import Done

@MainActor
final class QA5DeleteResurrectionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let t0 = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @MainActor
    final class QA5Gateway: RemoteEventsGateway {
        var rowsToServe: [[String: Any]] = []
        var upserted: [[[String: Any]]] = []
        func fetchEventRows(userId: String) async throws -> [[String: Any]] { rowsToServe }
        func upsertEventRows(_ rows: [[String: Any]]) async throws { upserted.append(rows) }

        var deletedIDs: [[String]] = []
        func deleteEventRows(ids: [String]) async throws {
            deletedIDs.append(ids)
        }
    }

    private func event(id: UUID = UUID(), title: String, hour: Double = 9) -> Event {
        let start = t0.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    private func serverRow(_ event: Event, updatedAt: String) -> [String: Any] {
        var row = SupabaseEventRowCodec.eventToRow(
            event, kind: "calendar", userId: "user-1", now: t0, iso: Self.iso
        )
        row["updated_at"] = updatedAt
        return row
    }

    /// Was the resurrection pin (round-6 fix: a synced row's local delete
    /// now mints a TOMBSTONE — the pull skips re-adoption, the push
    /// propagates the delete over the wire, and the summary names it).
    func testLocalDeleteOfSyncedRowTombstonesAndPropagates() async throws {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        let gateway = QA5Gateway()
        let engine = MacSyncEngine(
            store: store, gateway: gateway, identity: { "user-1" }
        )

        let id = UUID()
        gateway.rowsToServe = [serverRow(event(id: id, title: "Synced event"), updatedAt: "s1")]
        await engine.syncNow(now: t0)
        XCTAssertEqual(store.calendarEvents.first?.id, id, "precondition: adopted")

        store.removeCalendarEvent(id: id, now: t0.addingTimeInterval(60))
        XCTAssertTrue(store.calendarEvents.isEmpty, "locally deleted")
        XCTAssertTrue(store.dirtyEventIDs().isEmpty,
                      "a delete is not row-dirtiness — its trace is the tombstone below")

        XCTAssertEqual(store.tombstonedIDs, [id],
                       "a synced row's delete leaves a tombstone, not silence")

        // Server state unchanged; user syncs again.
        await engine.syncNow(now: t0.addingTimeInterval(600))

        XCTAssertTrue(store.calendarEvents.isEmpty,
                      "the deleted event must NOT come back on the next pull")
        XCTAssertEqual(gateway.deletedIDs.first, [id.uuidString],
                      "the delete propagates over the wire")
        XCTAssertTrue(store.tombstonedIDs.isEmpty,
                      "a confirmed delete clears its tombstone")
        XCTAssertTrue(engine.lastSummary.contains("deletes propagated"),
                      "the delete is named in the summary")
    }

    /// Control: a never-synced local row deleted before any push stays
    /// deleted — resurrection is specific to rows the server already holds.
    func testLocalOnlyRowDeletedBeforePushStaysDeleted() async throws {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        let gateway = QA5Gateway()
        let engine = MacSyncEngine(
            store: store, gateway: gateway, identity: { "user-1" }
        )

        let id = UUID()
        store.addCalendarEvent(event(id: id, title: "Never synced"), now: t0)
        store.removeCalendarEvent(id: id, now: t0.addingTimeInterval(30))
        XCTAssertTrue(store.calendarEvents.isEmpty)

        await engine.syncNow(now: t0.addingTimeInterval(60))

        XCTAssertTrue(store.calendarEvents.isEmpty, "nothing to resurrect from")
        XCTAssertTrue(gateway.upserted.isEmpty,
                      "the deleted never-pushed row must not ship postmortem")
    }
}
