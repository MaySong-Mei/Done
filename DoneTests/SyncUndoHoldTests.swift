//
//  SyncUndoHoldTests.swift
//  DoneTests
//
//  Design §10.6 (A) / §8.2 S2: merge, flush, undo at the third second — the
//  deleted row is alive on the server and in the feed the other device
//  pulls, with no orphan; let the prompt expire instead and the tombstone
//  goes out. Everything runs on the manual scheduler, so "the third second"
//  is a number the test chooses, not a sleep.
//

import XCTest
@testable import Done

@MainActor
final class SyncUndoHoldTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var scheduler: SyncManualScheduler!
    private var service: SupabaseSyncService!
    private let uid = "88888888-8888-8888-8888-888888888888"
    /// The baseline table for `kind: "todo"` rows (the feed table itself;
    /// only calendar rows get their own label).
    private var table: String { SupabaseSyncService.eventsBaselineTable(kind: "todo") }

    override func setUp() {
        super.setUp()
        suiteName = "SyncUndoHoldTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        scheduler = SyncManualScheduler()
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults, scheduler: scheduler)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeTodo(_ title: String) -> Event {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Event(title: title, timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], kind: .todo)
    }

    private func entry(_ event: Event) -> SyncBaselineEntry? {
        service.baseline.entry(table: table, id: event.id.uuidString)
    }

    private func hash(_ event: Event) -> String {
        SupabaseSyncService.rowHash(service.eventToRow(event, kind: "todo"))
    }

    /// What `EventStore.mergeEvents` leaves in the array: the target with
    /// the source folded in, the source gone.
    private func merged(_ target: Event, _ source: Event) -> Event {
        var out = target
        out.title = "\(target.title) / \(source.title)"
        return out
    }

    /// The other device's view: the feed rows it pulls from head.
    private func feedRowForS(_ s: Event) async throws -> [String: Any]? {
        let rows = try await server.pullChanges(sinceSeq: 0, pageLimit: 100)
        return rows.last { ($0.data["id"] as? String)?.lowercased() == s.id.uuidString.lowercased() }?.data
    }

    /// Two synced todos, then the merge of S into T with S's tombstone held.
    private func mergedWithHold(window: TimeInterval = EventGridView.mergeUndoWindow) async throws -> (t: Event, s: Event, merged: Event) {
        let t = makeTodo("T"), s = makeTodo("S")
        await service.syncEvents([t, s], kind: "todo")
        XCTAssertNotNil(entry(s)?.seq, "fixture: S has a baseline with a seq")
        service.undoHold.hold([s.id], for: window)
        return (t, s, merged(t, s))
    }

    // MARK: Undo inside the window (§8.2 S2)

    func testMergeFlushAndUndoAtTheThirdSecondLeavesTheRowAliveEverywhereWithNoOrphan_killsNoDelay() async throws {
        let (t, s, m) = try await mergedWithHold()
        let baselineOfS = try XCTUnwrap(entry(s))

        // The 2 s debounce fires: the merged target goes up, S does not go down.
        scheduler.advance(by: 2)
        await service.syncEvents([m], kind: "todo")
        XCTAssertEqual(server.requests(.tombstone).count, 0, "the mutant without the hold tombstones S here")
        XCTAssertFalse(server.isTombstoned(table: "events", key: s.id.uuidString))
        XCTAssertEqual(entry(s), baselineOfS, "S keeps its baseline while the prompt is up")
        XCTAssertEqual(server.requests(.patch).count, 1, "the merged target itself is uploaded as usual")

        // Third second: Undo. The rows come back exactly as they were.
        scheduler.advance(by: 1)
        service.undoHold.release([s.id])
        await service.syncEvents([t, s], kind: "todo")

        XCTAssertEqual(server.requests(.tombstone).count, 0)
        XCTAssertEqual(server.requests(.insert).count, 1, "S is clean against its old baseline: no POST, so no `[]`, so no orphan")
        XCTAssertTrue(service.awaitingEcho.isEmpty)
        XCTAssertEqual(service.orphansAfterHeadPull(), [])
        XCTAssertFalse(server.isTombstoned(table: "events", key: s.id.uuidString))
        let seen = try await feedRowForS(s)
        XCTAssertNotNil(seen, "the other device pulls S")
        XCTAssertTrue(seen?["deleted_at"] is NSNull, "…alive")
        XCTAssertEqual(server.row(table: "events", key: t.id.uuidString)?.data["title"] as? String, "T", "the target is back too")

        // The window ending later changes nothing: the hold was released.
        scheduler.advance(by: 10)
        let requests = server.requests.count
        await service.syncEvents([t, s], kind: "todo")
        XCTAssertEqual(server.requests.count, requests)
        XCTAssertTrue(service.undoHold.heldIds.isEmpty)
    }

    // MARK: No undo: the window ends

    func testLettingThePromptExpireSendsTheTombstoneOnTheNextFlush_killsNeverExpires() async throws {
        let (_, s, m) = try await mergedWithHold()
        scheduler.advance(by: 2)
        await service.syncEvents([m], kind: "todo")
        XCTAssertEqual(server.requests(.tombstone).count, 0)
        var expired: Set<String> = []
        service.undoHold.onExpire = { expired = $0 }

        // Seventh second: the prompt is long gone.
        scheduler.advance(by: 5)

        XCTAssertEqual(expired, [s.id.uuidString], "the engine is told so it can flush now")
        XCTAssertTrue(service.undoHold.heldIds.isEmpty)
        await service.syncEvents([m], kind: "todo")
        XCTAssertEqual(server.requests(.tombstone).count, 1)
        XCTAssertTrue(server.isTombstoned(table: "events", key: s.id.uuidString))
        XCTAssertNil(entry(s), "a 2xx tombstone takes the id out of the baseline")
    }

    func testTheWindowIsExactlyThePromptsLifetime() async throws {
        let (_, s, m) = try await mergedWithHold()
        scheduler.advance(by: EventGridView.mergeUndoWindow - 0.001)
        await service.syncEvents([m], kind: "todo")
        XCTAssertEqual(server.requests(.tombstone).count, 0, "still inside the prompt")

        scheduler.advance(by: 0.001)
        await service.syncEvents([m], kind: "todo")
        XCTAssertEqual(server.requests(.tombstone).count, 1)
        XCTAssertTrue(server.isTombstoned(table: "events", key: s.id.uuidString))
    }

    func testSmartSplitUsesTheLongerWindow() async throws {
        XCTAssertGreaterThan(EventGridView.splitUndoWindow, EventGridView.mergeUndoWindow, "fixture: 6 s vs 4 s")
        let s = makeTodo("S")
        await service.syncEvents([s], kind: "todo")
        XCTAssertNotNil(entry(s)?.seq, "fixture: S has a baseline with a seq")
        // The split: S is gone, two children take its place.
        service.undoHold.hold([s.id], for: EventGridView.splitUndoWindow)
        let children = [makeTodo("S1"), makeTodo("S2")]

        scheduler.advance(by: EventGridView.mergeUndoWindow + 1)
        await service.syncEvents(children, kind: "todo")
        XCTAssertEqual(server.requests(.tombstone).count, 0, "the merge window has passed; the split window has not")
        XCTAssertNotNil(entry(s))
        XCTAssertEqual(server.requests(.insert).count, 2, "the children go up as usual")

        scheduler.advance(by: 2)
        await service.syncEvents(children, kind: "todo")
        XCTAssertEqual(server.requests(.tombstone).count, 1)
        XCTAssertTrue(server.isTombstoned(table: "events", key: s.id.uuidString))
    }

    // MARK: The hold is in memory

    func testAProcessThatDiesInsideTheWindowSendsTheTombstoneAfterRelaunch() async throws {
        let (_, s, m) = try await mergedWithHold()
        scheduler.advance(by: 2)
        await service.syncEvents([m], kind: "todo")
        XCTAssertEqual(server.requests(.tombstone).count, 0)

        // Relaunch: same defaults (the baseline persisted), a new engine, no hold.
        let relaunched = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults, scheduler: SyncManualScheduler())
        XCTAssertTrue(relaunched.undoHold.heldIds.isEmpty)
        XCTAssertNotNil(relaunched.baseline.entry(table: table, id: s.id.uuidString), "the baseline still owes the delete")

        await relaunched.syncEvents([m], kind: "todo")

        XCTAssertEqual(server.requests(.tombstone).count, 1)
        XCTAssertTrue(server.isTombstoned(table: "events", key: s.id.uuidString))
    }

    func testHoldingAgainRestartsTheWindowAndReleasingCancelsIt() async throws {
        let s = makeTodo("S")
        var fired: [Set<String>] = []
        service.undoHold.onExpire = { fired.append($0) }

        service.undoHold.hold([s.id], for: 4)
        scheduler.advance(by: 3)
        service.undoHold.hold([s.id], for: 4)
        scheduler.advance(by: 3)
        XCTAssertTrue(service.undoHold.isHeld(s.id.uuidString), "the second hold restarted the window")
        XCTAssertEqual(fired, [])

        service.undoHold.release([s.id])
        scheduler.advance(by: 10)
        XCTAssertEqual(fired, [], "a released hold never fires")
        XCTAssertFalse(service.undoHold.isHeld(s.id.uuidString))
    }
}
