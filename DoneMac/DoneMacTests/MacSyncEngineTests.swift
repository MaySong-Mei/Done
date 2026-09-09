//
//  MacSyncEngineTests.swift
//  DoneMacTests
//
//  Phase-1 sync contracts through a fake gateway: server truth adopted,
//  local dirty preserved and pushed via the SHARED codec, the stale-write
//  guardrail dropping a lost race to iOS, and one-commit bulk merges.
//

import XCTest
@testable import Done

@MainActor
final class MacSyncEngineTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let t0 = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC

    @MainActor
    final class FakeGateway: RemoteEventsGateway {
        var rowsToServe: [[String: Any]] = []
        var upserted: [[[String: Any]]] = []
        var fetchError: Error?

        func fetchEventRows(userId: String) async throws -> [[String: Any]] {
            if let fetchError { throw fetchError }
            return rowsToServe
        }

        func upsertEventRows(_ rows: [[String: Any]]) async throws {
            upserted.append(rows)
        }
    }

    private struct Rig {
        let store: MacEventStore
        let engine: MacSyncEngine
        let gateway: FakeGateway
        let bill: MacWorkBill
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func makeRig(localEvents: [Event] = [], signedIn: Bool = true) async throws -> Rig {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        for event in localEvents { store.addCalendarEvent(event, now: t0) }
        let gateway = FakeGateway()
        let engine = MacSyncEngine(
            store: store, gateway: gateway, calendar: calendar,
            identity: { signedIn ? "user-1" : nil }
        )
        return Rig(store: store, engine: engine, gateway: gateway, bill: bill)
    }

    private func event(id: UUID = UUID(), title: String, hour: Double) -> Event {
        let start = t0.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    /// A server row IS a codec row — the wire format is the shared one.
    private func serverRow(_ event: Event, updatedAt: String) -> [String: Any] {
        var row = SupabaseEventRowCodec.eventToRow(
            event, kind: "calendar", userId: "user-1", now: t0, iso: Self.iso
        )
        row["updated_at"] = updatedAt
        return row
    }

    // MARK: - Pull

    func testPullAdoptsServerTruthAndRemovesCleanAbsentRows() async throws {
        let keepID = UUID()
        let goneID = UUID()
        let rig = try await makeRig(localEvents: [
            event(id: keepID, title: "Old title", hour: 9),
            event(id: goneID, title: "Deleted elsewhere", hour: 11),
        ])
        // Local rows are dirty (created locally, never pushed) — first sync
        // pushes them. To model CLEAN local rows, mark them pushed.
        rig.store.markPushed([keepID, goneID])

        let serverKeep = event(id: keepID, title: "Server title", hour: 10)
        let newID = UUID()
        let serverNew = event(id: newID, title: "Born on iPhone", hour: 14)
        rig.gateway.rowsToServe = [
            serverRow(serverKeep, updatedAt: "s1"),
            serverRow(serverNew, updatedAt: "s1"),
        ]

        await rig.engine.syncNow(now: t0)

        XCTAssertEqual(rig.engine.phase, .idle)
        let titles = Set(rig.store.calendarEvents.map(\.title))
        XCTAssertEqual(titles, ["Server title", "Born on iPhone"],
                       "server truth adopted; the clean absent row removed")
        XCTAssertTrue(rig.gateway.upserted.isEmpty, "nothing dirty, nothing pushed")
    }

    func testPullKeepsDirtyLocalEditAndPushesIt() async throws {
        let id = UUID()
        let rig = try await makeRig(localEvents: [event(id: id, title: "Mac edit", hour: 9)])
        // Dirty by construction (never pushed).
        rig.gateway.rowsToServe = [
            serverRow(event(id: id, title: "Server version", hour: 8), updatedAt: "s1")
        ]

        await rig.engine.syncNow(now: t0)

        XCTAssertEqual(rig.store.calendarEvents.first?.title, "Mac edit",
                       "a dirty local row survives the pull")
        XCTAssertEqual(rig.gateway.upserted.count, 1)
        XCTAssertEqual(rig.gateway.upserted[0].count, 1)
        XCTAssertEqual(rig.gateway.upserted[0][0]["title"] as? String, "Mac edit")
        XCTAssertEqual(rig.gateway.upserted[0][0]["kind"] as? String, "calendar")
        XCTAssertTrue(rig.store.dirtyEventIDs().isEmpty,
                      "a successful push marks the revision as the server's")
    }

    /// The stale-write guardrail: our edit raced an iPhone write and lost.
    func testServerStampChangeDropsLocalEditIOSWins() async throws {
        let id = UUID()
        let rig = try await makeRig(localEvents: [event(id: id, title: "Baseline", hour: 9)])
        rig.store.markPushed([id])
        rig.gateway.rowsToServe = [
            serverRow(event(id: id, title: "Baseline", hour: 9), updatedAt: "s1")
        ]
        await rig.engine.syncNow(now: t0)  // baseline pull records stamp s1

        // Mac edits locally; meanwhile the iPhone writes the same row (s2).
        guard let row = rig.store.calendarEvents.first(where: { $0.id == id }) else { return XCTFail() }
        var edited = row
        edited.title = "Mac raced"
        rig.store.replaceCalendarEvent(edited, now: t0.addingTimeInterval(60))
        rig.gateway.rowsToServe = [
            serverRow(event(id: id, title: "iPhone won", hour: 9), updatedAt: "s2")
        ]

        await rig.engine.syncNow(now: t0.addingTimeInterval(120))

        XCTAssertEqual(rig.store.calendarEvents.first?.title, "iPhone won",
                       "a moved server stamp means iOS wins — the local edit is dropped")
        XCTAssertTrue(rig.gateway.upserted.isEmpty,
                      "the losing edit must NOT be pushed over the iPhone's write")
        XCTAssertTrue(rig.engine.lastSummary.contains("updated on iPhone"),
                      "the override is surfaced, never silent")
    }

    func testUnchangedStampKeepsAndPushesTheLocalEdit() async throws {
        let id = UUID()
        let rig = try await makeRig(localEvents: [event(id: id, title: "Baseline", hour: 9)])
        rig.store.markPushed([id])
        rig.gateway.rowsToServe = [
            serverRow(event(id: id, title: "Baseline", hour: 9), updatedAt: "s1")
        ]
        await rig.engine.syncNow(now: t0)

        guard let row = rig.store.calendarEvents.first(where: { $0.id == id }) else { return XCTFail() }
        var edited = row
        edited.title = "Mac uncontended"
        rig.store.replaceCalendarEvent(edited, now: t0.addingTimeInterval(60))
        // Server unchanged: same stamp on the second pull.

        await rig.engine.syncNow(now: t0.addingTimeInterval(120))

        XCTAssertEqual(rig.store.calendarEvents.first?.title, "Mac uncontended")
        XCTAssertEqual(rig.gateway.upserted.count, 1, "the uncontended edit pushes")
    }

    func testPullIgnoresTodoKindRowsThisPhase() async throws {
        let rig = try await makeRig()
        var row = serverRow(event(title: "Wanna row", hour: 9), updatedAt: "s1")
        row["kind"] = "todo"
        rig.gateway.rowsToServe = [row]

        await rig.engine.syncNow(now: t0)

        XCTAssertTrue(rig.store.calendarEvents.isEmpty,
                      "phase 1 owns the calendar slot only")
    }

    func testSignedOutIsANoOp() async throws {
        let rig = try await makeRig(localEvents: [event(title: "Local", hour: 9)], signedIn: false)
        rig.gateway.rowsToServe = [serverRow(event(title: "Server", hour: 10), updatedAt: "s1")]
        await rig.engine.syncNow(now: t0)
        XCTAssertEqual(rig.engine.phase, .signedOut)
        XCTAssertEqual(rig.store.calendarEvents.first?.title, "Local")
    }

    func testFetchFailureSurfacesAndChangesNothing() async throws {
        struct Boom: Error {}
        let rig = try await makeRig(localEvents: [event(title: "Local", hour: 9)])
        rig.gateway.fetchError = Boom()
        await rig.engine.syncNow(now: t0)
        if case .failed = rig.engine.phase {} else {
            XCTFail("a failed pull must surface, not idle quietly")
        }
        XCTAssertEqual(rig.store.calendarEvents.first?.title, "Local")
    }

    /// The merge is ONE bulk commit — sync cannot storm the canvas.
    func testPullMergeIsOneCommit() async throws {
        let rig = try await makeRig()
        rig.gateway.rowsToServe = (0..<50).map {
            serverRow(event(title: "R\($0)", hour: Double($0 % 12)), updatedAt: "s1")
        }
        let commits = rig.bill.count(.storeCommits)
        await rig.engine.syncNow(now: t0)
        XCTAssertEqual(rig.store.calendarEvents.count, 50)
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1,
                       "fifty adopted rows are one commit, one delta")
    }

    /// Round-trip: what the Mac pushes, the codec reads back identically —
    /// the shape-safety claim behind "iOS restore stays safe".
    func testPushedRowRoundTripsThroughTheSharedCodec() async throws {
        let id = UUID()
        let rig = try await makeRig(localEvents: [event(id: id, title: "Round trip", hour: 9)])
        await rig.engine.syncNow(now: t0)
        guard let pushed = rig.gateway.upserted.first?.first else {
            return XCTFail("nothing pushed")
        }
        let decoded = SupabaseEventRowCodec.rowToEvent(pushed)
        XCTAssertEqual(decoded?.id, id)
        XCTAssertEqual(decoded?.title, "Round trip")
        XCTAssertEqual(decoded?.timeRanges,
                       rig.store.calendarEvents.first?.timeRanges)
    }
}
