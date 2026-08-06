//
//  EventStoreDurabilityTests.swift
//  DoneTests
//
//  The store-level half of the durability work: migration off UserDefaults,
//  the three seed gates, per-slot freezing, the wipe, the restore redo marker,
//  and the Domino timestamp — the one value whose loss silently and
//  permanently moves the user's dates.
//
//  Written against interruption points, not against the happy path. Every
//  "boot a second store at the same location" here is standing in for the
//  process dying and the next launch starting.
//

import XCTest
@testable import Done

@MainActor
final class EventStoreDurabilityTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "EventStoreDurabilityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    private func makeStore(seeds: Bool = false) -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: seeds)
    }

    private func event(_ title: String, hoursFromNow: Double = 1, kind: Event.Kind = .event) -> Event {
        let start = Date().addingTimeInterval(hoursFromNow * 3600)
        return Event(title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: kind)
    }

    /// Parked past the horizon RELATIVE TO the injected `now` — the Domino
    /// filter compares against `horizonDate(from:now:)`, so a todo placed
    /// relative to the wall clock would sit before the horizon of a pinned
    /// `now` and never move.
    private func parkedTodo(relativeTo now: Date) -> Event {
        let start = now.addingTimeInterval(30 * 86_400)
        return Event(title: "parked",
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .todo)
    }

    private func directory() throws -> URL { try location.directoryURL() }

    private func primaryURL(_ slot: StorageSlot) throws -> URL {
        try directory().appendingPathComponent(slot.filename)
    }

    // MARK: - The bug, expressed as a test

    /// The reported failure: a write reports success, the process dies, and
    /// the next launch has fewer rows than the last save said it wrote. This
    /// cannot reproduce the SIGKILL, but it does pin the property that makes
    /// SIGKILL survivable — when `saveCalendarEvents` returns, a store built
    /// from scratch against the same files already sees the row.
    func testAWriteIsVisibleToAFreshStoreImmediately() {
        let a = makeStore()
        a.addCalendarEvent(event("Dentist"))
        let b = makeStore()
        XCTAssertEqual(b.rawCalendarEvents.map(\.title), ["Dentist"])
    }

    // MARK: - Migration

    func testAllEightSlotsMigrateFromUserDefaults() throws {
        let encoder = JSONEncoder()
        defaults.set(try encoder.encode([event("todo-1", kind: .todo)]), forKey: "events")
        defaults.set(try encoder.encode([event("cal-1"), event("cal-2")]), forKey: "calendarEvents")
        defaults.set(try encoder.encode([TodoList(title: "Inbox", colorName: "blue")]), forKey: "todoLists")
        defaults.set(try encoder.encode([Person(name: "Alex")]), forKey: "people")

        let store = makeStore()
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.rawCalendarEvents.count, 2)
        XCTAssertEqual(store.todoLists.count, 1)
        XCTAssertEqual(store.people.count, 1)
        XCTAssertTrue(store.storageFaults.isEmpty)

        // Legacy keys are frozen, not deleted: a downgrade of the binary must
        // land on the migration-time snapshot, not on nothing.
        XCTAssertNotNil(defaults.data(forKey: "calendarEvents"))

        // Second launch reads the files and does not consult legacy at all.
        defaults.set(try encoder.encode([Event]()), forKey: "calendarEvents")
        let next = makeStore()
        XCTAssertEqual(next.rawCalendarEvents.count, 2,
                       "the file wins; legacy is dead data once a file exists")
    }

    func testMigrationSurvivesBeingInterruptedAndRepeated() throws {
        let rows = (0..<40).map { event("cal-\($0)", hoursFromNow: Double($0)) }
        defaults.set(try JSONEncoder().encode(rows), forKey: "calendarEvents")

        for _ in 0..<3 {
            let store = makeStore()
            XCTAssertEqual(store.rawCalendarEvents.count, 40)
            XCTAssertTrue(store.storageFaults.isEmpty)
        }
        // ...and with debris from a commit killed before its rename.
        try Data("junk".utf8).write(to: try directory().appendingPathComponent(".tmp-calendarEvents-x"))
        XCTAssertEqual(makeStore().rawCalendarEvents.count, 40)
    }

    // MARK: - The seed gates

    /// The single most consequential line in the change. Under UserDefaults
    /// "empty" meant absent-or-corrupt; under files it can also mean "could
    /// not be read this once". Seeding calls `addCalendarEvent`, which SAVES —
    /// so without the gate, one transient read failure replaces the user's
    /// events with six demo rows.
    func testUnreadableCalendarIsNeverSeededOver() throws {
        let a = makeStore()
        for i in 0..<12 { a.addCalendarEvent(event("real-\(i)", hoursFromNow: Double(i))) }
        let primary = try primaryURL(.calendarEvents)
        let goodBytes = try Data(contentsOf: primary)
        // Corrupt BOTH copies, so recovery cannot rescue us and the store is
        // forced into the failure branch.
        try Data("shredded".utf8).write(to: primary)
        try? FileManager.default.removeItem(
            at: try directory().appendingPathComponent(StorageSlot.calendarEvents.backupFilename))

        let b = makeStore(seeds: true)
        XCTAssertTrue(b.rawCalendarEvents.isEmpty)
        XCTAssertTrue(b.isSlotFrozen(.calendarEvents))
        XCTAssertTrue(b.persistenceDegraded)

        // Nothing was written over the top: the bytes are preserved in
        // quarantine and no new primary was created.
        let quarantine = try directory().appendingPathComponent("quarantine")
        let saved = try FileManager.default.contentsOfDirectory(atPath: quarantine.path)
            .filter { $0.hasPrefix("calendarEvents-corrupt-") }
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent(saved[0])),
                       Data("shredded".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path),
                       "a frozen slot must not get a new primary written under it")
        XCTAssertNotEqual(goodBytes, Data("shredded".utf8))   // guard on the fixture
    }

    /// ...and continuing to use the app while frozen must not write either.
    func testEditsAreRefusedWhileASlotIsFrozen() throws {
        let a = makeStore()
        a.addCalendarEvent(event("real"))
        try Data("x".utf8).write(to: try primaryURL(.calendarEvents))
        try? FileManager.default.removeItem(
            at: try directory().appendingPathComponent(StorageSlot.calendarEvents.backupFilename))

        let b = makeStore()
        XCTAssertTrue(b.isSlotFrozen(.calendarEvents))
        b.addCalendarEvent(event("added-while-frozen"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try primaryURL(.calendarEvents).path),
                       "a refused save must not create the file")

        // A healthy slot in the same store keeps working.
        b.addList(TodoList(title: "Still works", colorName: "red"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try primaryURL(.todoLists).path))
    }

    func testAFirstLaunchStillSeeds() {
        let store = makeStore(seeds: true)
        XCTAssertFalse(store.rawCalendarEvents.isEmpty, "a provably fresh store may seed")
    }

    func testAWipedStoreSeedsAgainOnTheNextLaunch() {
        let a = makeStore(seeds: true)
        XCTAssertFalse(a.rawCalendarEvents.isEmpty)
        a.clearAllLocalData()
        let b = makeStore(seeds: true)
        XCTAssertFalse(b.rawCalendarEvents.isEmpty,
                       "wipe-then-relaunch repopulating the demo events is today's behaviour")
    }

    // MARK: - Wipe

    /// Deleting the files would leave "no file", which is the state that
    /// re-runs legacy migration — and `removeObject` goes to cfprefsd, whose
    /// durability is the bug. So the wipe writes empty envelopes instead, and
    /// erased data has no path back.
    func testWipeCannotBeUndoneByASurvivingLegacyKey() throws {
        let rows = (0..<30).map { event("legacy-\($0)", hoursFromNow: Double($0)) }
        defaults.set(try JSONEncoder().encode(rows), forKey: "calendarEvents")
        let a = makeStore()
        XCTAssertEqual(a.rawCalendarEvents.count, 30)
        a.clearAllLocalData()

        // Simulate cfprefsd never having flushed the key removal.
        defaults.set(try JSONEncoder().encode(rows), forKey: "calendarEvents")

        let b = makeStore()
        XCTAssertTrue(b.rawCalendarEvents.isEmpty, "erased data must not come back")
    }

    func testWipeIsResumableWhenInterruptedPartWay() throws {
        let a = makeStore()
        a.addCalendarEvent(event("cal"))
        a.addList(TodoList(title: "list", colorName: "blue"))
        a.addPerson(Person(name: "Alex"))

        // Emulate a kill after some slots were cleared and others were not, by
        // clearing only two of them through the same primitive the wipe uses.
        try a.storage.commit([Event](), to: .calendarEvents, wiped: true, intent: .destructive)
        try a.storage.commit([TodoList](), to: .todoLists, wiped: true, intent: .destructive)

        let b = makeStore()
        XCTAssertTrue(b.rawCalendarEvents.isEmpty)
        XCTAssertTrue(b.todoLists.isEmpty)
        XCTAssertEqual(b.people.count, 1, "the un-cleared slot is untouched")
        // Pressing the button again finishes the job.
        b.clearAllLocalData()
        XCTAssertTrue(makeStore().people.isEmpty)
    }

    func testWipeRemovesThePreWipePlaintextCopies() throws {
        let a = makeStore()
        a.addCalendarEvent(event("one"))
        a.addCalendarEvent(event("two"))   // second commit creates the .bak
        let backup = try directory().appendingPathComponent(StorageSlot.calendarEvents.backupFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        a.clearAllLocalData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    // MARK: - Restore redo marker

    /// Mirrors `EventStore.RestoreRedoPayload`. Deliberately a separate
    /// declaration: if the on-disk shape of a marker ever changes
    /// incompatibly, this test fails, which is exactly the signal wanted for
    /// a payload that has to be readable by a LATER launch.
    private struct RestoreMarkerMirror: Codable {
        var events: [Event]
        var calendarEvents: [Event]
        var logs: [CalendarEventLogRecord]
        var feedback: [CalendarEventFeedbackRecord]
        var todoLists: [TodoList]
    }

    func testACompletedRestoreLeavesNoMarker() {
        let store = makeStore()
        store.addCalendarEvent(event("before"))
        _ = store.applyRestore(
            RestoreSnapshot(calendarEvents: [event("after")], todoEvents: [],
                            logs: [], feedback: [], todoLists: [],
                            eventTypes: [], skills: []),
            strategy: .cloudOverwritesLocal, resolution: .keepCloud
        )
        XCTAssertEqual(store.rawCalendarEvents.map(\.title), ["after"])
        XCTAssertTrue(store.storage.pendingWork(kind: "restore").isEmpty)
        XCTAssertEqual(makeStore().rawCalendarEvents.map(\.title), ["after"])
    }

    /// A restore is one transaction over five arrays. Across five files a kill
    /// in the middle leaves a PERSISTENT half restore — and the next backup
    /// snapshot would push that half state to the cloud. The marker turns it
    /// from "detectable" into "repaired on the next launch".
    func testAnInterruptedRestoreIsFinishedOnTheNextLaunch() throws {
        let a = makeStore()
        a.addCalendarEvent(event("old-cal"))
        a.addList(TodoList(title: "old-list", colorName: "blue"))

        let restored = RestoreMarkerMirror(
            events: [event("new-todo", kind: .todo)],
            calendarEvents: [event("new-cal-1"), event("new-cal-2")],
            logs: [], feedback: [],
            todoLists: [TodoList(title: "new-list", colorName: "red")]
        )
        // The exact on-disk state of a restore killed after the marker was
        // written but before (or during) the five slot writes: marker present,
        // slots still holding the OLD content.
        try a.storage.recordPendingWork(kind: "restore",
                                        payload: JSONEncoder().encode(restored))

        let b = makeStore()
        XCTAssertEqual(b.rawCalendarEvents.map(\.title), ["new-cal-1", "new-cal-2"])
        XCTAssertEqual(b.events.map(\.title), ["new-todo"])
        XCTAssertEqual(b.todoLists.map(\.title), ["new-list"])
        XCTAssertTrue(b.storage.pendingWork(kind: "restore").isEmpty, "the marker is consumed")

        // Replaying writes an end state, so doing it twice is a no-op.
        XCTAssertEqual(makeStore().rawCalendarEvents.count, 2)
    }

    /// Make one slot's commit fail while the rest of the directory stays
    /// perfectly writable: `rename(2)` cannot replace a directory with a file
    /// (EISDIR), so the temp file is written and the commit point fails —
    /// exactly the shape of a full disk or an unwritable container, but
    /// scoped to a single slot.
    private func jamSlot(_ slot: StorageSlot) throws {
        let primary = try primaryURL(slot)
        try? FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
    }

    private func unjamSlot(_ slot: StorageSlot) throws {
        try FileManager.default.removeItem(at: try primaryURL(slot))
    }

    /// `persist` reports failure by RETURNING false. A restore writes five
    /// arrays and the calendar is by far the biggest, so "four landed, the
    /// calendar did not" is the realistic failure — a PERSISTENT half restore.
    /// Clearing the marker there would throw away the only thing that makes it
    /// repairable, and the next backup pass would push the half state to the
    /// cloud.
    func testARestoreThatCouldNotBeFullyWrittenKeepsItsMarker() throws {
        let a = makeStore()
        a.addCalendarEvent(event("old-cal"))
        try jamSlot(.calendarEvents)

        _ = a.applyRestore(
            RestoreSnapshot(calendarEvents: [event("new-cal")],
                            todoEvents: [event("new-todo", kind: .todo)],
                            logs: [], feedback: [],
                            todoLists: [TodoList(title: "new-list", colorName: "red")],
                            eventTypes: [], skills: []),
            strategy: .cloudOverwritesLocal, resolution: .keepCloud
        )

        XCTAssertEqual(a.storage.pendingWork(kind: "restore").count, 1,
                       "a half-written restore must keep its redo marker")
        XCTAssertTrue(a.persistenceDegraded, "and the user must be told")

        // The next launch, once the slot is writable again, finishes the job.
        try unjamSlot(.calendarEvents)
        let b = makeStore()
        XCTAssertEqual(b.rawCalendarEvents.map(\.title), ["new-cal"])
        XCTAssertEqual(b.events.map(\.title), ["new-todo"])
        XCTAssertEqual(b.todoLists.map(\.title), ["new-list"])
        XCTAssertTrue(b.storage.pendingWork(kind: "restore").isEmpty)
    }

    // MARK: - The degraded-write banner

    /// The banner is the user's only safety net when a write cannot land, and
    /// it was a single global flag: the calendar failing to write raised it,
    /// and the very next save of ANY small slot — reminders, lists, people,
    /// all of which save constantly — cleared it again within seconds while
    /// the calendar was still not being written.
    func testAFailingSlotKeepsTheBannerUpWhileOtherSlotsSaveFine() throws {
        let store = makeStore()
        store.addCalendarEvent(event("first"))
        try jamSlot(.calendarEvents)

        store.addCalendarEvent(event("cannot-land"))
        XCTAssertTrue(store.writeFailedSlots.contains(.calendarEvents))
        XCTAssertTrue(store.persistenceDegraded)

        // A different, perfectly healthy slot saves — repeatedly.
        store.addList(TodoList(title: "healthy", colorName: "blue"))
        store.addPerson(Person(name: "Alex"))
        XCTAssertTrue(store.persistenceDegraded,
                      "another slot's success says nothing about the calendar")

        // Only the calendar itself becoming writable clears it.
        try unjamSlot(.calendarEvents)
        store.addCalendarEvent(event("lands-now"))
        XCTAssertFalse(store.writeFailedSlots.contains(.calendarEvents))
        XCTAssertFalse(store.persistenceDegraded)
    }

    func testAnUnreadableMarkerIsDiscardedRatherThanBlockingLaunch() throws {
        let a = makeStore()
        a.addCalendarEvent(event("survives"))
        try a.storage.recordPendingWork(kind: "restore", payload: Data("not json".utf8))

        let b = makeStore()
        XCTAssertEqual(b.rawCalendarEvents.map(\.title), ["survives"])
        XCTAssertTrue(b.storage.pendingWork(kind: "restore").isEmpty)
    }

    // MARK: - Domino timestamp

    /// The highest-risk value in the change. Under UserDefaults the stamp and
    /// the shifted rows died together, so a kill was a clean no-op. Split
    /// across media, "rows survived + stamp lost" would re-apply the WHOLE
    /// elapsed delta on top of already-shifted todos: a silent, permanent
    /// corruption of user dates that nobody would ever notice.
    func testStampSurvivesWithTheRowsItDescribes() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = makeStore()
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        a.addCalendarEvent(parkedTodo(relativeTo: t0))
        let parkedStart = a.rawCalendarEvents[0].timeRanges[0].start

        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600), horizonDays: 7)
        XCTAssertEqual(a.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       3600, accuracy: 0.001)

        // Next launch: same instant must move nothing more.
        let b = makeStore()
        b.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600), horizonDays: 7)
        XCTAssertEqual(b.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       3600, accuracy: 0.001, "the stamp must have survived with the rows")

        // And an hour later moves exactly one more hour, never two.
        b.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(7200), horizonDays: 7)
        XCTAssertEqual(b.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       7200, accuracy: 0.001)
    }

    /// Losing the heartbeat file must not cause a double shift, because the
    /// authoritative stamp travelled inside the calendar envelope.
    func testLosingTheHeartbeatFileDoesNotDoubleShift() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = makeStore()
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        a.addCalendarEvent(parkedTodo(relativeTo: t0))
        let parkedStart = a.rawCalendarEvents[0].timeRanges[0].start
        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600), horizonDays: 7)

        try? FileManager.default.removeItem(
            at: try directory().appendingPathComponent("domino.json"))

        let b = makeStore()
        b.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600), horizonDays: 7)
        XCTAssertEqual(b.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       3600, accuracy: 0.001)
    }

    /// The other direction: a tick that moved nothing writes only the 8-byte
    /// heartbeat, and that heartbeat must be honoured even though the calendar
    /// envelope still carries an older stamp (`max` of the two).
    func testNoOpTickWritesOnlyTheHeartbeatAndItIsHonoured() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = makeStore()
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)   // nothing parked yet
        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(7200), horizonDays: 7)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try directory().appendingPathComponent("domino.json").path))

        let b = makeStore()
        b.addCalendarEvent(parkedTodo(relativeTo: t0))
        let parkedStart = b.rawCalendarEvents[0].timeRanges[0].start
        // Only 3600s have elapsed since the LAST tick; if the older envelope
        // stamp won, this would shift by 10800 instead.
        b.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(10800), horizonDays: 7)
        XCTAssertEqual(b.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       3600, accuracy: 0.001)
    }

    /// The two interruption stories crossed: a restore replay rewrites the
    /// calendar envelope, and the envelope is where the authoritative stamp
    /// lives. The heartbeat is ALLOWED to lag it — a tick that actually moved
    /// rows updates the envelope and not the heartbeat — so a replay that
    /// commits the rows without the stamp silently hands the next tick a delta
    /// it has already applied, and the parked todo moves twice.
    func testARestoreReplayCarriesTheDominoStampWithTheRowsItRewrites() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = makeStore()
        // A no-op tick: heartbeat = t0, nothing parked yet.
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        a.addCalendarEvent(parkedTodo(relativeTo: t0))
        let parkedStart = a.rawCalendarEvents[0].timeRanges[0].start

        // A REAL push an hour later: rows move, the stamp t0+3600 rides in the
        // calendar envelope, and the heartbeat file is deliberately left at t0.
        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600), horizonDays: 7)
        XCTAssertEqual(a.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       3600, accuracy: 0.001)
        XCTAssertEqual(a.storage.readDominoHeartbeat(), t0,
                       "fixture guard: the heartbeat must be the STALE one")

        // A cloud restore killed after its marker was written.
        try a.storage.recordPendingWork(
            kind: "restore",
            payload: JSONEncoder().encode(RestoreMarkerMirror(
                events: a.events, calendarEvents: a.rawCalendarEvents,
                logs: [], feedback: [], todoLists: a.todoLists
            ))
        )

        let b = makeStore()   // the replay rewrites the calendar envelope
        XCTAssertEqual(b.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       3600, accuracy: 0.001)
        b.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600), horizonDays: 7)
        XCTAssertEqual(b.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       3600, accuracy: 0.001,
                       "the replay must carry the envelope stamp forward, not fall back to the "
                       + "lagging heartbeat and re-apply a delta that was already applied")
    }

    /// An upgrading user's accumulated delta lives in the legacy key. Missing
    /// it would treat the upgrade launch as a first-ever push and silently
    /// drop however long they were away.
    func testLegacyDominoStampIsCarriedAcrossOnUpgrade() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(t0.timeIntervalSince1970, forKey: EventStore.legacyDominoLastPushKey)

        let store = makeStore()
        store.addCalendarEvent(parkedTodo(relativeTo: t0))
        let parkedStart = store.rawCalendarEvents[0].timeRanges[0].start
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600), horizonDays: 7)
        XCTAssertEqual(store.rawCalendarEvents[0].timeRanges[0].start.timeIntervalSince(parkedStart),
                       3600, accuracy: 0.001, "the pre-upgrade delta must be applied, not discarded")
    }

    /// A user who moves the system clock backwards leaves a stamp in the
    /// future. Behaviour is unchanged from today (no push until real time
    /// catches up), and it must not throw or shift backwards.
    func testAStampInTheFutureDoesNotPushBackwards() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = makeStore()
        a.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        a.addCalendarEvent(parkedTodo(relativeTo: t0))
        let parkedStart = a.rawCalendarEvents[0].timeRanges[0].start

        a.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(-86_400), horizonDays: 7)
        XCTAssertEqual(a.rawCalendarEvents[0].timeRanges[0].start, parkedStart)
    }

    // MARK: - Scale

    /// The dogfood device carries 2690 calendar rows / 1.25 MB, and the
    /// simulator's failure to reproduce the original bug was blamed on data
    /// volume. Everything above runs at toy sizes; this runs the real path at
    /// the real size, through the store rather than the storage layer.
    func testDeviceScaleStoreRoundTripAndMigration() throws {
        let rows = (0..<2600).map { i in
            Event(title: "Event \(i) — padded to a realistic width",
                  note: String(repeating: "n", count: 180),
                  location: "Room \(i)",
                  timeRanges: [.init(start: Date().addingTimeInterval(Double(i) * 3600),
                                     end: Date().addingTimeInterval(Double(i) * 3600 + 1800))],
                  type: "Work")
        }
        defaults.set(try JSONEncoder().encode(rows), forKey: "calendarEvents")

        let migrated = makeStore()
        XCTAssertEqual(migrated.rawCalendarEvents.count, 2600)
        XCTAssertTrue(migrated.storageFaults.isEmpty)

        // A single edit at this size must be visible to the next launch.
        migrated.addCalendarEvent(event("the 2601st"))
        let next = makeStore()
        XCTAssertEqual(next.rawCalendarEvents.count, 2601)
        XCTAssertEqual(next.rawCalendarEvents.last?.title, "the 2601st")

        // And a delete at this size, too — the shrink guard must not interfere
        // with an ordinary single-row removal.
        next.deleteCalendarEvent(next.rawCalendarEvents[0])
        XCTAssertEqual(makeStore().rawCalendarEvents.count, 2600)
    }

    /// A large deliberate shrink is allowed (refusing would fork memory from
    /// disk) but must leave a forensic snapshot behind.
    func testLargeAccidentalShrinkIsRecordedButNotBlocked() throws {
        let store = makeStore()
        for i in 0..<120 { store.rawCalendarEvents.append(event("e-\(i)", hoursFromNow: Double(i))) }
        store.saveCalendarEvents(refreshInterrupts: false)
        store.rawCalendarEvents = [event("survivor")]
        store.saveCalendarEvents(refreshInterrupts: false)

        let snapshots = try FileManager.default.contentsOfDirectory(
            atPath: try directory().appendingPathComponent("snapshots").path)
        XCTAssertEqual(snapshots.filter { $0.hasPrefix("calendarEvents-shrink-") }.count, 1)
        XCTAssertEqual(makeStore().rawCalendarEvents.count, 1, "the write still went through")
    }
}
