//
//  QA5MergePrimitiveEdgeTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA round 5 — MacEventStore merge-primitive edges (attack
//  surface 2): duplicate remote ids, overridden-dirty rows absent from the
//  remote snapshot, dirty local-only survival, adoption-counter honesty,
//  no-op detection, and the refusal gates (pre-load / frozen slot) that
//  applyRemoteEvents shares with every other mutation.
//
//  Convention: tests named QA5Finding_* PIN current behavior the report
//  flags (green on purpose, severity lives in the report). A test with a
//  plain contract name that is RED pins a real bug the report numbers.
//

import XCTest
@testable import Done

@MainActor
final class QA5MergePrimitiveEdgeTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let t0 = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC

    private func event(id: UUID = UUID(), title: String, hour: Double = 9) -> Event {
        let start = t0.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    private func makeStore() async throws -> (store: MacEventStore, bill: MacWorkBill) {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        return (store, bill)
    }

    // MARK: - Duplicate remote ids (REAL BUG when red — see QA5 report)

    /// The remote loop appends once per ROW, not once per id, so a snapshot
    /// carrying the same id twice puts TWO rows with one UUID into the
    /// truth store. Arithmetic: remote = [X, X'] , dirtyIDs = {} ->
    /// iteration 1 appends X (adopted=1), iteration 2 appends X'
    /// (adopted=2), merged.count = 2, unique ids = 1. Duplicates are
    /// reachable in production: SupabaseREST.fetchAll pages 1k-row Range
    /// windows WITHOUT an `order` clause, and PostgREST gives no stable
    /// order across unordered paged requests — a row can repeat (or drop)
    /// across page boundaries once a user exceeds 1000 event rows. Two
    /// rows sharing a UUID break every firstIndex-based mutation and
    /// double-render the event.
    func testDuplicateRemoteIDsMustNotDuplicateStoreRows() async throws {
        let (store, _) = try await makeStore()
        let id = UUID()
        let first = event(id: id, title: "Page-boundary copy A")
        let second = event(id: id, title: "Page-boundary copy B", hour: 10)

        store.applyRemoteEvents([first, second], overridingDirty: [], now: t0)

        let ids = store.calendarEvents.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "one server id must never become two truth rows")
        XCTAssertEqual(store.calendarEvents.count, 1)
    }

    /// The dirty flavor of the same hole: a DIRTY local row whose id appears
    /// twice in remote is kept twice — keptDirty double-counts and the
    /// LOCAL row is duplicated.
    func testDuplicateRemoteIDsMustNotDuplicateADirtyLocalRow() async throws {
        let (store, _) = try await makeStore()
        let id = UUID()
        store.addCalendarEvent(event(id: id, title: "Dirty local"), now: t0)  // dirty by construction

        let server = event(id: id, title: "Server copy")
        let adoption = store.applyRemoteEvents([server, server], overridingDirty: [], now: t0)

        XCTAssertEqual(store.calendarEvents.count, 1,
                       "a dirty row must survive as ONE row, however many times the snapshot repeats it")
        XCTAssertEqual(adoption.keptDirty, 1,
                       "keptDirty must count records, not remote occurrences")
    }

    // MARK: - overridingDirty absent from remote (pinned contract)

    /// QA5Finding: naming a dirty id in `overridingDirty` while the remote
    /// snapshot does NOT carry that id makes the record VANISH — it is
    /// removed as "deleted elsewhere" (dropped local edit + no server row).
    /// Today the engine cannot construct this call: `conflicted` requires a
    /// stamp from THIS pull, so conflicted ⊆ remote ids. Pinned green as
    /// the primitive's contract so any future caller inherits the warning;
    /// the report carries it as a latent footgun.
    func testQA5Finding_OverriddenDirtyAbsentFromRemoteVanishesEntirely() async throws {
        let (store, _) = try await makeStore()
        let id = UUID()
        store.addCalendarEvent(event(id: id, title: "Doomed local edit"), now: t0)

        let adoption = store.applyRemoteEvents([], overridingDirty: [id], now: t0)

        XCTAssertTrue(store.calendarEvents.isEmpty,
                      "pinned: override + absent-from-remote = record gone")
        XCTAssertEqual(adoption.removed, 1)
        XCTAssertEqual(adoption.overriddenDirty, 1,
                       "round-6: the override IS counted — iOS deleting a row we hold dirty surfaces in the summary")
        XCTAssertTrue(store.dirtyEventIDs().isEmpty)
    }

    // MARK: - Dirty local-only survival (positive control)

    func testDirtyLocalOnlyRowSurvivesThePull() async throws {
        let (store, _) = try await makeStore()
        let localID = UUID()
        store.addCalendarEvent(event(id: localID, title: "Born on Mac"), now: t0)

        let serverOnly = event(title: "Born on iPhone", hour: 11)
        let adoption = store.applyRemoteEvents([serverOnly], overridingDirty: [], now: t0)

        XCTAssertEqual(Set(store.calendarEvents.map(\.title)),
                       ["Born on Mac", "Born on iPhone"])
        XCTAssertEqual(adoption.keptDirty, 1)
        XCTAssertEqual(adoption.adopted, 1)
        XCTAssertEqual(store.dirtyEventIDs(), [localID],
                       "the kept row stays dirty and will push")
    }

    // MARK: - Adoption counter honesty, all four classes at once

    /// A=clean+present (adopt), B=dirty+present (keep), C=dirty+present+
    /// overridden (adopt, iOS wins), D=clean+absent (remove), E=dirty+
    /// absent (keep). Expected: adopted 2 (A,C), keptDirty 2 (B,E),
    /// removed 1 (D), overriddenDirty 1 (C).
    func testAdoptionCountersExactAcrossAllFiveClasses() async throws {
        let (store, _) = try await makeStore()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

        // Seed A, C, D as CLEAN via adoption (no markPushed dependency).
        store.applyRemoteEvents([
            event(id: a, title: "A0"), event(id: c, title: "C0"), event(id: d, title: "D0"),
        ], overridingDirty: [], now: t0)
        XCTAssertTrue(store.dirtyEventIDs().isEmpty, "adopted rows must arrive clean")

        // B, E dirty by local creation; C dirty by local edit.
        store.addCalendarEvent(event(id: b, title: "B-local"), now: t0)
        store.addCalendarEvent(event(id: e, title: "E-local"), now: t0)
        store.replaceCalendarEvent(event(id: c, title: "C-local-edit"), now: t0.addingTimeInterval(60))
        XCTAssertEqual(store.dirtyEventIDs(), [b, c, e])

        let adoption = store.applyRemoteEvents([
            event(id: a, title: "A1"), event(id: b, title: "B1"), event(id: c, title: "C1"),
        ], overridingDirty: [c], now: t0.addingTimeInterval(120))

        XCTAssertEqual(adoption, MacEventStore.RemoteAdoption(
            adopted: 2, keptDirty: 2, removed: 1, overriddenDirty: 1
        ))
        XCTAssertEqual(Set(store.calendarEvents.map(\.title)),
                       ["A1", "B-local", "C1", "E-local"],
                       "kept: dirty B + dirty-absent E; adopted: A1 + overridden C1; removed: D")
        XCTAssertEqual(store.dirtyEventIDs(), [b, e],
                       "the overridden row's local history is gone — iOS won")
    }

    // MARK: - No-op detection

    func testIdenticalSnapshotIsANoOpZeroCommits() async throws {
        let (store, bill) = try await makeStore()
        let row = event(title: "Stable")
        store.applyRemoteEvents([row], overridingDirty: [], now: t0)
        let commitsBefore = bill.count(.storeCommits)

        let adoption = store.applyRemoteEvents([row], overridingDirty: [], now: t0.addingTimeInterval(60))

        XCTAssertEqual(bill.count(.storeCommits), commitsBefore,
                       "an identical snapshot must not mint a commit or a delta")
        XCTAssertEqual(adoption.adopted, 0)
        XCTAssertEqual(adoption.removed, 0)
    }

    // MARK: - Refusal gates

    func testApplyRemoteBeforeLoadIsRefusedAndCounted() async throws {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        // No load().

        let adoption = store.applyRemoteEvents([event(title: "Too early")], overridingDirty: [], now: t0)

        XCTAssertEqual(adoption, MacEventStore.RemoteAdoption())
        XCTAssertTrue(store.calendarEvents.isEmpty)
        XCTAssertEqual(bill.count(.preLoadMutationRefused), 1,
                       "the refusal must be counted, not silent")
    }

    func testApplyRemoteOnFrozenSlotIsRefused() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        do {
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            store.addCalendarEvent(event(title: "Original"), now: t0)
            await store.flush()
        }
        // Corrupt the slot; single prior commit leaves no backup to heal from.
        let primary = try location.directoryURL().appendingPathComponent("calendarEvents.json")
        try Data("QA5 corruption".utf8).write(to: primary)

        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        XCTAssertTrue(store.frozenSlots.contains(.calendarEvents), "precondition: slot frozen")

        let adoption = store.applyRemoteEvents([event(title: "Server row")], overridingDirty: [], now: t0)

        XCTAssertEqual(adoption, MacEventStore.RemoteAdoption(),
                       "a frozen slot must refuse the merge wholesale")
        XCTAssertTrue(store.calendarEvents.isEmpty)
        XCTAssertEqual(store.revision[.calendarEvents], 0,
                       "no generation bump on a refused merge")
    }
}
