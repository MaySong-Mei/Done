//
//  DominoAnchorSyncTests.swift
//  DoneTests
//
//  Design §10.5 (i), per-row domino anchoring: a parked todo moves by
//  `now − its own anchor` and the anchor travels with the row, so two
//  devices each pushing once move it by the elapsed time, not twice that.
//  Two stores stand in for two devices; the row crosses between them
//  through the real projections (`eventToRow` → `rowToEvent`), which is the
//  path a pull takes once the applier has decided to adopt.
//

import XCTest
@testable import Done

@MainActor
final class DominoAnchorSyncTests: XCTestCase {
    private var suiteA: String!
    private var suiteB: String!
    private var suiteS: String!
    private var defaultsA: UserDefaults!
    private var defaultsB: UserDefaults!
    private var defaultsS: UserDefaults!
    private var service: SupabaseSyncService!
    private let uid = "55555555-5555-5555-5555-555555555555"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    override func setUp() {
        super.setUp()
        suiteA = "DominoAnchorSyncTests-A-\(UUID().uuidString)"
        suiteB = "DominoAnchorSyncTests-B-\(UUID().uuidString)"
        suiteS = "DominoAnchorSyncTests-S-\(UUID().uuidString)"
        defaultsA = UserDefaults(suiteName: suiteA)
        defaultsB = UserDefaults(suiteName: suiteB)
        defaultsS = UserDefaults(suiteName: suiteS)!
        TestStorage.reset(suiteA)
        TestStorage.reset(suiteB)
        service = SupabaseSyncService(gateway: SyncFakeServer(userId: uid), userId: uid, defaults: defaultsS)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteA)
        TestStorage.tearDown(suiteB)
        defaultsS.removePersistentDomain(forName: suiteS)
        service = nil
        super.tearDown()
    }

    private func store(_ suite: String, _ defaults: UserDefaults) -> EventStore {
        EventStore(defaults: defaults, storage: .isolated(name: suite), seedsSampleDataIfEmpty: false)
    }

    /// A far-future todo: 30 days out with a 7-day horizon, so the domino owns it.
    private func parkedTodo(id: UUID = UUID()) -> Event {
        let start = t0.addingTimeInterval(30 * 86_400)
        return Event(id: id, title: "Parked",
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(hour))],
                     kind: .todo)
    }

    private func row(_ store: EventStore, _ id: UUID) -> Event? {
        store.rawCalendarEvents.first { $0.id == id }
    }

    /// The row as the other device receives it: through the upload
    /// projection and back through the download projection.
    private func crossed(_ event: Event) throws -> Event {
        try XCTUnwrap(SupabaseSyncService.rowToEvent(service.eventToRow(event, kind: "calendar")))
    }

    // MARK: Two devices, each pushing once

    func testTwoDevicesEachPushingOnceMoveAParkedTodoByTheElapsedTimeOnly_killsNoAnchorWritten_killsAnchorNotProjected() throws {
        let a = store(suiteA, defaultsA)
        let b = store(suiteB, defaultsB)
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        b.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        let id = UUID()
        a.addCalendarEvent(parkedTodo(id: id))
        let parkedStart = try XCTUnwrap(row(a, id)?.timeRanges.first?.start)

        // A ticks an hour later: one hour, anchor written.
        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(hour), horizonDays: 7)
        let afterA = try XCTUnwrap(row(a, id))
        XCTAssertEqual(afterA.timeRanges[0].start.timeIntervalSince(parkedStart), hour, accuracy: 0.001)
        XCTAssertEqual(afterA.dominoAnchor, t0.addingTimeInterval(hour), "the push stamps the row with its own instant")

        // B adopts A's row (its anchor rides along) and ticks an hour after A did.
        let arrivedAtB = try crossed(afterA)
        XCTAssertEqual(arrivedAtB.dominoAnchor?.timeIntervalSince1970 ?? 0,
                       t0.addingTimeInterval(hour).timeIntervalSince1970, accuracy: 0.001,
                       "the anchor is in the projection, or B cannot know A pushed")
        b.applyRemoteCalendarRows(adopts: [arrivedAtB], deletions: [])
        b.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(2 * hour), horizonDays: 7)
        let afterB = try XCTUnwrap(row(b, id))
        XCTAssertEqual(afterB.timeRanges[0].start.timeIntervalSince(parkedStart), 2 * hour, accuracy: 0.001,
                       "B moves the row only by what is left since A's push — the whole-store delta (B's heartbeat at t0) would make this three hours")
        XCTAssertEqual(afterB.dominoAnchor, t0.addingTimeInterval(2 * hour))

        // A adopts B's row and ticks an hour after B: again only the remainder.
        a.applyRemoteCalendarRows(adopts: [try crossed(afterB)], deletions: [])
        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3 * hour), horizonDays: 7)
        let finalA = try XCTUnwrap(row(a, id))
        XCTAssertEqual(finalA.timeRanges[0].start.timeIntervalSince(parkedStart), 3 * hour, accuracy: 0.001,
                       "total drift equals wall-clock time across both devices")
    }

    func testAdoptingARowAnotherDevicePushedAndTickingAtTheSameInstantMovesNothing() throws {
        let a = store(suiteA, defaultsA)
        let b = store(suiteB, defaultsB)
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        b.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        let id = UUID()
        a.addCalendarEvent(parkedTodo(id: id))
        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(hour), horizonDays: 7)
        let pushedByA = try XCTUnwrap(row(a, id))

        b.applyRemoteCalendarRows(adopts: [try crossed(pushedByA)], deletions: [])
        b.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(hour), horizonDays: 7)

        let atB = try XCTUnwrap(row(b, id))
        XCTAssertEqual(atB.timeRanges[0].start, pushedByA.timeRanges[0].start,
                       "nothing is left to push: the row's anchor is this very instant")
        XCTAssertEqual(atB.dominoAnchor?.timeIntervalSince1970 ?? 0,
                       t0.addingTimeInterval(hour).timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: A row without an anchor

    func testARowWithoutAnAnchorStartsFromThisDevicesHeartbeatOnceAndThenHasItsOwn() throws {
        let a = store(suiteA, defaultsA)
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        let id = UUID()
        a.addCalendarEvent(parkedTodo(id: id))
        XCTAssertNil(row(a, id)?.dominoAnchor, "fixture: a new todo carries no anchor")
        let parkedStart = try XCTUnwrap(row(a, id)?.timeRanges.first?.start)

        // First push: the whole-store rule — since the heartbeat at t0.
        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(2 * hour), horizonDays: 7)
        let first = try XCTUnwrap(row(a, id))
        XCTAssertEqual(first.timeRanges[0].start.timeIntervalSince(parkedStart), 2 * hour, accuracy: 0.001)
        XCTAssertEqual(first.dominoAnchor, t0.addingTimeInterval(2 * hour))

        // Second push: since its own anchor.
        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3 * hour), horizonDays: 7)
        let second = try XCTUnwrap(row(a, id))
        XCTAssertEqual(second.timeRanges[0].start.timeIntervalSince(parkedStart), 3 * hour, accuracy: 0.001)
        XCTAssertEqual(second.dominoAnchor, t0.addingTimeInterval(3 * hour))
    }

    func testANearFutureTodoIsNeverAnchored() throws {
        let a = store(suiteA, defaultsA)
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        let id = UUID()
        let start = t0.addingTimeInterval(2 * 86_400)
        a.addCalendarEvent(Event(id: id, title: "Soon",
                                 timeRanges: [.init(start: start, end: start.addingTimeInterval(hour))],
                                 kind: .todo))

        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(hour), horizonDays: 7)

        let soon = try XCTUnwrap(row(a, id))
        XCTAssertEqual(soon.timeRanges[0].start, start, "before the horizon: the user's date")
        XCTAssertNil(soon.dominoAnchor, "only a pushed row is stamped")
    }

    // MARK: The anchor on the wire and on disk

    func testTheAnchorIsInTheRowHashAndSurvivesTheProjectionRoundTrip_killsAnchorNotProjected() throws {
        var plain = parkedTodo()
        plain.dominoAnchor = nil
        var stamped = plain
        stamped.dominoAnchor = t0.addingTimeInterval(hour)

        XCTAssertNotEqual(SupabaseSyncService.rowHash(service.eventToRow(plain, kind: "calendar")),
                          SupabaseSyncService.rowHash(service.eventToRow(stamped, kind: "calendar")),
                          "a push changes the hash, so it is an upload (§6 domino 段)")
        let back = try crossed(stamped)
        XCTAssertEqual(back.dominoAnchor?.timeIntervalSince1970 ?? 0,
                       t0.addingTimeInterval(hour).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(try crossed(plain).dominoAnchor, "no anchor stays no anchor: a null column decodes to nil")
    }

    func testTheAnchorIsPersistedWithTheRowItDescribes() throws {
        let id = UUID()
        do {
            let a = store(suiteA, defaultsA)
            a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
            a.addCalendarEvent(parkedTodo(id: id))
            a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(hour), horizonDays: 7)
        }
        let relaunched = store(suiteA, defaultsA)
        XCTAssertEqual(row(relaunched, id)?.dominoAnchor, t0.addingTimeInterval(hour),
                       "the local Codable path carries the anchor; without it a relaunch re-applies the whole delta")

        let encoded = try JSONEncoder().encode(try XCTUnwrap(row(relaunched, id)))
        XCTAssertEqual(try JSONDecoder().decode(Event.self, from: encoded).dominoAnchor, t0.addingTimeInterval(hour))
    }

    /// QA QM1: the horizon filter is taken AS OF the row's anchor, not now.
    /// A todo parked 8 days out with a 7-day horizon, anchored at t0, sits
    /// BEFORE the horizon of a tick 3 days later (t0 + 10 d); filtering by
    /// the current horizon would silently abandon it, filtering by the
    /// anchor's horizon (t0 + 7 d) catches it and moves it the 3 days.
    func testTheHorizonFilterIsTakenAtTheRowsAnchorNotNow_killsHorizonNotByAnchor() throws {
        let day: TimeInterval = 86_400
        let a = store(suiteA, defaultsA)
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        let parkedID = UUID(), soonID = UUID()
        var parked = parkedTodo(id: parkedID)
        parked.timeRanges = [.init(start: t0.addingTimeInterval(8 * day), end: t0.addingTimeInterval(8 * day + hour))]
        parked.dominoAnchor = t0
        var soon = parkedTodo(id: soonID)
        soon.timeRanges = [.init(start: t0.addingTimeInterval(2 * day), end: t0.addingTimeInterval(2 * day + hour))]
        soon.dominoAnchor = t0
        a.applyRemoteCalendarRows(adopts: [parked, soon], deletions: [])

        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3 * day), horizonDays: 7)

        let pushed = try XCTUnwrap(row(a, parkedID))
        XCTAssertEqual(pushed.timeRanges[0].start.timeIntervalSince(t0), 11 * day, accuracy: 0.001,
                       "past the horizon as of its anchor: moved by the 3 days since — the mutant filtering by today's horizon leaves it at 8 days")
        XCTAssertEqual(pushed.dominoAnchor, t0.addingTimeInterval(3 * day))
        let control = try XCTUnwrap(row(a, soonID))
        XCTAssertEqual(control.timeRanges[0].start.timeIntervalSince(t0), 2 * day, accuracy: 0.001,
                       "positive control: before the horizon as of its anchor, never moved")
        XCTAssertEqual(control.dominoAnchor, t0, "…and not re-stamped")
    }

    func testAnAnchorAheadOfThisClockIsLeftAloneUntilTheClockPassesIt() throws {
        let a = store(suiteA, defaultsA)
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        let id = UUID()
        var fromAFastClock = parkedTodo(id: id)
        fromAFastClock.dominoAnchor = t0.addingTimeInterval(2 * hour)
        a.applyRemoteCalendarRows(adopts: [fromAFastClock], deletions: [])
        let start = try XCTUnwrap(row(a, id)?.timeRanges.first?.start)

        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(hour), horizonDays: 7)
        XCTAssertEqual(row(a, id)?.timeRanges.first?.start, start, "never moved backwards, never moved at all")
        XCTAssertEqual(row(a, id)?.dominoAnchor, t0.addingTimeInterval(2 * hour), "the foreign anchor stands")

        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3 * hour), horizonDays: 7)
        XCTAssertEqual(row(a, id)?.timeRanges.first?.start.timeIntervalSince(start) ?? 0, hour, accuracy: 0.001,
                       "once past it: only the remainder")
    }
}
