//
//  SyncApplierTests.swift
//  DoneTests
//
//  `EventStore.applyRemote` (design §6 / §6.1 / §6.2 / §6.4) driven with
//  hand-built pages over a fresh store. Every hash these tests compare
//  against is taken through the pusher's own projection
//  (`service.eventToRow` / `logToRow` / …), never through anything the
//  applier computed, so a projection drift between the two sides fails here.
//

import XCTest
@testable import Done

@MainActor
final class SyncApplierTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var store: EventStore!
    private var service: SupabaseSyncService!
    private var shelfDirectory: URL!
    private var shelf: ConflictShelf!
    private let uid = "44444444-4444-4444-4444-444444444444"
    private static let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() {
        super.setUp()
        suite = "SyncApplierTests-\(UUID().uuidString)"
        location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        service = SupabaseSyncService(gateway: SyncFakeServer(userId: uid), userId: uid, defaults: defaults)
        shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncApplierTests-\(UUID().uuidString)", isDirectory: true)
        shelf = ConflictShelf(directory: shelfDirectory)
    }

    override func tearDown() {
        store = nil
        service = nil
        try? FileManager.default.removeItem(at: shelfDirectory)
        TestStorage.tearDown(suite)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeEvent(_ title: String, note: String = "", hour: Double = 0, id: UUID = UUID()) -> Event {
        let start = Self.t0.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title, note: note,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
                     createdAt: Self.t0)
    }

    private func edited(_ event: Event, note: String) -> Event {
        var copy = event
        copy.note = note
        return copy
    }

    private func context(pullIssue: Int = 1, token: Int? = nil) -> SyncApplyContext {
        SyncApplyContext(engine: service, shelf: shelf,
                         eraseToken: token ?? LocalDataEraseEpoch.capture(), pullIssue: pullIssue)
    }

    @discardableResult
    private func apply(_ rows: [SyncFeedRow], _ ctx: SyncApplyContext? = nil) -> SyncApplyOutcome {
        store.applyRemote(RemotePage(rows: rows), context: ctx ?? context())
    }

    private func serverShape(_ row: [String: Any], seq: Int64, deleted: Bool) -> [String: Any] {
        var data = row
        if let id = data["id"] as? String, UUID(uuidString: id) != nil { data["id"] = id.lowercased() }
        data["seq"] = NSNumber(value: seq)
        data["deleted_at"] = deleted ? "2026-10-19T00:00:00.000Z" : NSNull()
        return data
    }

    private func eventRow(_ event: Event, kind: String = "calendar", seq: Int64, deleted: Bool = false) -> SyncFeedRow {
        SyncFeedRow(table: "events", seq: seq,
                    data: serverShape(service.eventToRow(event, kind: kind), seq: seq, deleted: deleted))
    }

    private func logRow(_ record: CalendarEventLogRecord, seq: Int64, deleted: Bool = false) -> SyncFeedRow {
        SyncFeedRow(table: "event_logs", seq: seq, data: serverShape(service.logToRow(record), seq: seq, deleted: deleted))
    }

    private func feedbackRow(_ record: CalendarEventFeedbackRecord, seq: Int64, deleted: Bool = false) -> SyncFeedRow {
        SyncFeedRow(table: "event_feedback", seq: seq,
                    data: serverShape(service.feedbackToRow(record), seq: seq, deleted: deleted))
    }

    private func hash(_ event: Event, kind: String = "calendar") -> String {
        SupabaseSyncService.rowHash(service.eventToRow(event, kind: kind))
    }

    private func logHash(_ record: CalendarEventLogRecord) -> String {
        SupabaseSyncService.rowHash(service.logToRow(record))
    }

    private func feedbackHash(_ record: CalendarEventFeedbackRecord) -> String {
        SupabaseSyncService.rowHash(service.feedbackToRow(record))
    }

    private func calKey(_ event: Event) -> SyncBaselineKey {
        SyncBaselineKey(table: "calendar_events", id: event.id.uuidString)
    }

    private func entry(_ event: Event, table: String = "calendar_events") -> SyncBaselineEntry? {
        service.baseline.entry(table: table, id: event.id.uuidString)
    }

    private func setBase(_ event: Event, hash: String, seq: Int64?, table: String = "calendar_events") {
        service.baseline.setEntry(SyncBaselineEntry(hash: hash, seq: seq), table: table, id: event.id.uuidString)
    }

    private func localCalendar(_ event: Event) -> Event? {
        store.rawCalendarEvents.first { $0.id == event.id }
    }

    private func singleKey(_ event: Event) -> CalendarOccurrenceKey {
        CalendarOccurrenceKey(eventID: event.id, baseSeriesEventID: nil, occurrenceDate: Self.t0,
                              kind: .singleEvent, dayKey: 20260528)
    }

    private func seriesKey(_ series: Event, dayKey: Int) -> CalendarOccurrenceKey {
        CalendarOccurrenceKey(eventID: series.id, baseSeriesEventID: series.id, occurrenceDate: Self.t0,
                              kind: .seriesOccurrence, dayKey: dayKey)
    }

    private func makeLog(_ key: CalendarOccurrenceKey, note: String) -> CalendarEventLogRecord {
        CalendarEventLogRecord(id: key, eventID: key.eventID, baseSeriesEventID: key.baseSeriesEventID,
                               occurrenceDate: Self.t0, note: note, createdAt: Self.t0, updatedAt: Self.t0)
    }

    private func makeFeedback(_ key: CalendarOccurrenceKey, note: String) -> CalendarEventFeedbackRecord {
        CalendarEventFeedbackRecord(id: key, eventID: key.eventID, baseSeriesEventID: key.baseSeriesEventID,
                                    occurrenceDate: Self.t0, selfNote: note, createdAt: Self.t0, updatedAt: Self.t0)
    }

    private func wire(_ key: CalendarOccurrenceKey) -> String { service.encodeOccurrenceKey(key) }

    private func shelfLines() -> [ConflictShelfEntry] { shelf.entries() }

    private func trailLines(containing needle: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init).filter { $0.contains(needle) }
    }

    /// A calendar event committed to the store with a CLEAN baseline at `seq`.
    @discardableResult
    private func seedClean(_ event: Event, seq: Int64) -> Event {
        store.addCalendarEvent(event)
        let local = localCalendar(event)!
        setBase(local, hash: hash(local), seq: seq)
        return local
    }

    // MARK: - Projection control

    /// The applier's h_in for a row the pusher built from `e` must equal the
    /// pusher's hash of `e`, or every row reads dirty. Positive control for
    /// every "same" / "echo" assertion below.
    func testIncomingRowHashesExactlyAsThePusherHashesTheLocalRow() {
        let e = makeEvent("round trip", note: "n")
        let decoded = SupabaseSyncService.rowToEvent(eventRow(e, seq: 1).data)!
        XCTAssertEqual(hash(decoded), hash(e))
        let log = makeLog(singleKey(e), note: "l")
        XCTAssertEqual(logHash(SupabaseSyncService.rowToLog(logRow(log, seq: 1).data)!), logHash(log))
        let fb = makeFeedback(singleKey(e), note: "f")
        XCTAssertEqual(feedbackHash(SupabaseSyncService.rowToFeedback(feedbackRow(fb, seq: 1).data)!), feedbackHash(fb))
    }

    // MARK: - The rule table, one row each

    func testRow1SkipsAVersionAtOrBelowTheBaselineSeq() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 10)
        let before = entry(local)
        for seq: Int64 in [10, 9] {
            let outcome = apply([eventRow(edited(local, note: "stale \(seq)"), seq: seq)])
            XCTAssertEqual(outcome.status, .applied)
            XCTAssertEqual(outcome.decisions[calKey(local)], .skip)
            XCTAssertEqual(localCalendar(local)?.note, "c0")
            XCTAssertEqual(entry(local), before)
        }
        XCTAssertTrue(shelfLines().isEmpty)
    }

    func testRow2CleanTombstoneRemovesTheRowAndTheBaselineAndShelvesNothing() {
        let local = seedClean(makeEvent("x"), seq: 5)
        let outcome = apply([eventRow(local, seq: 6, deleted: true)])
        XCTAssertEqual(outcome.decisions[calKey(local)], .tombstone)
        XCTAssertNil(localCalendar(local))
        XCTAssertNil(entry(local))
        XCTAssertTrue(shelfLines().isEmpty)
    }

    func testRow2DirtyTombstoneShelvesTheLocalVersionAtTheTombstoneSeq() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        store.updateCalendarEvent(edited(local, note: "c1 offline"))
        apply([eventRow(local, seq: 6, deleted: true)])
        XCTAssertNil(localCalendar(local))
        XCTAssertNil(entry(local))
        let lines = shelfLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.reason, ConflictShelfReason.tombstoneDirtyLocal.rawValue)
        XCTAssertEqual(lines.first?.seq, 6, "the tombstone's seq, not base.seq")
        XCTAssertEqual(lines.first?.row["note"] as? String, "c1 offline")
    }

    func testRow2TombstoneForAnAbsentRowRemovesTheBaselineEntry() {
        let gone = makeEvent("gone")
        setBase(gone, hash: hash(gone), seq: 5)
        let outcome = apply([eventRow(gone, seq: 7, deleted: true)])
        XCTAssertEqual(outcome.decisions[calKey(gone)], .tombstone)
        XCTAssertNil(entry(gone))
        XCTAssertTrue(shelfLines().isEmpty)
    }

    func testRow3EchoKeepsTheNewerLocalEditAndOnlyMovesTheSeq() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        let c1 = edited(local, note: "c1")
        setBase(local, hash: hash(c1), seq: 5)       // c1 went out
        store.updateCalendarEvent(edited(local, note: "c2"))
        let outcome = apply([eventRow(c1, seq: 6)])
        XCTAssertEqual(outcome.decisions[calKey(local)], .echo)
        XCTAssertEqual(localCalendar(local)?.note, "c2")
        XCTAssertEqual(entry(local), SyncBaselineEntry(hash: hash(c1), seq: 6))
        XCTAssertTrue(shelfLines().isEmpty)
    }

    func testRow4SameContentWritesTheBaseline() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        store.updateCalendarEvent(edited(local, note: "c1"))
        let outcome = apply([eventRow(edited(local, note: "c1"), seq: 6)])
        XCTAssertEqual(outcome.decisions[calKey(local)], .same)
        XCTAssertEqual(entry(local), SyncBaselineEntry(hash: hash(edited(local, note: "c1")), seq: 6))
        XCTAssertTrue(shelfLines().isEmpty)
    }

    func testInFlightEchoIsNeverAConflict() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        let c1 = edited(local, note: "c1")
        service.baseline.setEntry(.unknown(seq: 5), table: "calendar_events", id: local.id.uuidString)
        store.updateCalendarEvent(edited(local, note: "c2"))
        var ctx = context()
        ctx.inFlight = { [hash = hash(c1), id = local.id.uuidString] key in
            key == SyncBaselineKey(table: "calendar_events", id: id) ? .rowHash(hash) : nil
        }
        let outcome = apply([eventRow(c1, seq: 6)], ctx)
        XCTAssertEqual(outcome.decisions[calKey(local)], .echo)
        XCTAssertEqual(localCalendar(local)?.note, "c2")
        XCTAssertEqual(entry(local), SyncBaselineEntry(hash: hash(c1), seq: 6))
        XCTAssertTrue(shelfLines().isEmpty)
    }

    /// Control for the test above: without the in-flight entry the same page
    /// IS a conflict, so the echo row is what kept it off the shelf.
    func testWithoutTheInFlightEntryTheSamePageIsAConflict() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        let c1 = edited(local, note: "c1")
        service.baseline.setEntry(.unknown(seq: 5), table: "calendar_events", id: local.id.uuidString)
        store.updateCalendarEvent(edited(local, note: "c2"))
        let outcome = apply([eventRow(c1, seq: 6)])
        XCTAssertEqual(outcome.decisions[calKey(local)], .conflict)
        XCTAssertEqual(shelfLines().count, 1)
    }

    func testRow5PendingLocalDeleteMeetsAPeerEditStaysAbsentAndShelvesTheIncomingRow() {
        let gone = makeEvent("x", note: "c0")
        setBase(gone, hash: hash(gone), seq: 5)
        let peer = edited(gone, note: "c2 peer")
        let outcome = apply([eventRow(peer, seq: 6)])
        XCTAssertEqual(outcome.decisions[calKey(gone)], .conflict)
        XCTAssertNil(localCalendar(gone), "the pending delete stays; its tombstone still goes out")
        XCTAssertEqual(entry(gone), SyncBaselineEntry(hash: hash(peer), seq: 6))
        XCTAssertEqual(shelfLines().map(\.reason), [ConflictShelfReason.pendingDelete.rawValue])
        XCTAssertEqual(shelfLines().first?.row["note"] as? String, "c2 peer")
    }

    func testRow6CleanRowAdoptsTheIncomingVersion() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        let peer = edited(local, note: "c2 peer")
        let outcome = apply([eventRow(peer, seq: 6)])
        XCTAssertEqual(outcome.decisions[calKey(local)], .adopt)
        XCTAssertEqual(localCalendar(local)?.note, "c2 peer")
        XCTAssertEqual(entry(local), SyncBaselineEntry(hash: hash(peer), seq: 6))
        XCTAssertEqual(hash(localCalendar(local)!), hash(peer), "local now reads clean")
    }

    func testRow6NewRowIsInserted() {
        let peer = makeEvent("new on B", note: "n")
        apply([eventRow(peer, seq: 3)])
        XCTAssertEqual(localCalendar(peer).map { hash($0) }, hash(peer))
        XCTAssertEqual(entry(peer), SyncBaselineEntry(hash: hash(peer), seq: 3))
    }

    func testRow7DirtyRowKeepsLocalShelvesIncomingAndBaselineNamesTheServer() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        store.updateCalendarEvent(edited(local, note: "c1 mine"))
        let peer = edited(local, note: "c2 peer")
        let outcome = apply([eventRow(peer, seq: 6)])
        XCTAssertEqual(outcome.decisions[calKey(local)], .conflict)
        XCTAssertEqual(localCalendar(local)?.note, "c1 mine")
        XCTAssertEqual(entry(local), SyncBaselineEntry(hash: hash(peer), seq: 6),
                       "(h_in, seq): dirty ⟺ local ≠ server")
        XCTAssertEqual(shelfLines().map(\.reason), [ConflictShelfReason.conflict.rawValue])
        XCTAssertEqual(shelfLines().first?.seq, 6)
        XCTAssertEqual(trailLines(containing: "sync.conflict table=calendar_events id=\(local.id.uuidString) seq=6").count, 1)
    }

    func testTodoRowsLiveInTheTodoArrayUnderTheirOwnBaselineTable() {
        let todo = makeEvent("todo")
        apply([eventRow(todo, kind: "todo", seq: 4)])
        XCTAssertEqual(store.events.map(\.id), [todo.id])
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
        XCTAssertEqual(entry(todo, table: "events"), SyncBaselineEntry(hash: hash(todo, kind: "todo"), seq: 4))
        XCTAssertNil(entry(todo))
    }

    func testUndecodableRowWritesNothingButTheCursorStillPasses() {
        let bad = SyncFeedRow(table: "events", seq: 8,
                              data: ["id": "not-a-uuid", "kind": "calendar", "seq": NSNumber(value: 8), "deleted_at": NSNull()])
        let outcome = apply([bad])
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(outcome.undecodable.count, 1)
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
        XCTAssertEqual(service.cursor.value, 8)
    }

    // MARK: - Side-effect bypasses

    func testRemoteRowsNeverFireTheRecordCompletedHooks() {
        var completed = 0
        store.onCalendarEventRecordCompleted = { _ in completed += 1 }
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        completed = 0
        apply([eventRow(edited(local, note: "c2"), seq: 6), eventRow(makeEvent("new"), seq: 7)])
        XCTAssertEqual(store.rawCalendarEvents.count, 2, "fixture guard: both rows landed")
        XCTAssertEqual(completed, 0)
    }

    func testTodoTombstoneDoesNotStopTheLinkedTimer() {
        var cal = makeEvent("running")
        cal.timerStartedAt = Self.t0
        store.addCalendarEvent(cal)
        var todo = makeEvent("todo")
        todo.linkedCalendarEventId = cal.id
        store.add(todo)
        setBase(todo, hash: hash(todo, kind: "todo"), seq: 2, table: "events")
        var completed = 0
        store.onCalendarEventRecordCompleted = { _ in completed += 1 }
        apply([eventRow(todo, kind: "todo", seq: 3, deleted: true)])
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.rawCalendarEvents.first?.timerStartedAt, Self.t0)
        XCTAssertEqual(completed, 0)
    }

    func testRemoteTombstoneNeverUnlinksImageFilesWhileTheUserDeleteDoes() {
        var removed: [[AgenticIntakeImageRef]] = []
        store.removeAssetFiles = { removed.append($0) }
        func withImage(_ title: String) -> Event {
            var e = makeEvent(title)
            e.agenticIntake = AgenticIntakeRecord(
                rawText: "", images: [AgenticIntakeImageRef(relativePath: "\(e.id.uuidString)/a.jpg",
                                                            pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1)],
                source: .quickAdd)
            return e
        }
        let user = withImage("user")
        store.addCalendarEvent(user)
        store.deleteCalendarEvent(user)
        XCTAssertEqual(removed.count, 1, "control: the user delete unlinks")

        let remote = seedClean(withImage("remote"), seq: 5)
        apply([eventRow(remote, seq: 6, deleted: true)])
        XCTAssertNil(localCalendar(remote))
        XCTAssertEqual(removed.count, 1, "a remote tombstone unlinks nothing")

        let flagged = withImage("flagged")
        store.addCalendarEvent(flagged)
        store.deleteCalendarEvent(flagged, unlinkAssets: false)
        XCTAssertEqual(removed.count, 1)
    }

    // MARK: - Cascades (fresh-eyes B2)

    func testTombstoneCascadePrunesRecordsAndShelvesOnlyTheDirtyOrUnbaselinedOnes() {
        let x = seedClean(makeEvent("x"), seq: 5)
        let cleanLog = makeLog(singleKey(x), note: "clean")
        let dirtyFeedback = makeFeedback(singleKey(x), note: "offline note")
        store.calendarEventLogRecords = [cleanLog]
        store.calendarEventFeedbackRecords = [dirtyFeedback]
        XCTAssertTrue(store.commitLogRecordsNow())
        XCTAssertTrue(store.saveCalendarEventFeedbackRecords())
        service.baseline.setEntry(SyncBaselineEntry(hash: logHash(cleanLog), seq: 3), table: "event_logs", id: wire(cleanLog.id))
        service.baseline.setEntry(SyncBaselineEntry(hash: "older", seq: 3), table: "event_feedback", id: wire(dirtyFeedback.id))

        let outcome = apply([eventRow(x, seq: 9, deleted: true)])
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertNil(localCalendar(x))
        XCTAssertTrue(store.calendarEventLogRecords.isEmpty)
        XCTAssertTrue(store.calendarEventFeedbackRecords.isEmpty)
        let lines = shelfLines()
        XCTAssertEqual(lines.map(\.table), ["event_feedback"])
        XCTAssertEqual(lines.first?.reason, ConflictShelfReason.cascade.rawValue)
        XCTAssertEqual(lines.first?.seq, 9, "the parent tombstone's seq")
        XCTAssertEqual(lines.first?.row["self_note"] as? String, "offline note")
        // The children keep their baselines: the collection diff tombstones them.
        XCTAssertNotNil(service.baseline.entry(table: "event_logs", id: wire(cleanLog.id)))
        XCTAssertNotNil(service.baseline.entry(table: "event_feedback", id: wire(dirtyFeedback.id)))
    }

    func testCascadeShelvesARecordWithNoBaselineAndOneMarkedUnknown() {
        let x = seedClean(makeEvent("x"), seq: 5)
        let neverUploaded = makeLog(singleKey(x), note: "written offline")
        let sending = makeFeedback(singleKey(x), note: "in flight")
        store.calendarEventLogRecords = [neverUploaded]
        store.calendarEventFeedbackRecords = [sending]
        service.baseline.setEntry(.unknown(seq: 3), table: "event_feedback", id: wire(sending.id))
        apply([eventRow(x, seq: 9, deleted: true)])
        XCTAssertEqual(Set(shelfLines().map(\.table)), ["event_logs", "event_feedback"])
        XCTAssertTrue(shelfLines().allSatisfy { $0.seq == 9 && $0.reason == ConflictShelfReason.cascade.rawValue })
    }

    func testARecordWhoseOwnTombstoneIsInThePageIsLeftToItsOwnRow() {
        let x = seedClean(makeEvent("x"), seq: 5)
        let log = makeLog(singleKey(x), note: "dirty")
        store.calendarEventLogRecords = [log]
        service.baseline.setEntry(SyncBaselineEntry(hash: "older", seq: 3), table: "event_logs", id: wire(log.id))
        apply([eventRow(x, seq: 9, deleted: true), logRow(log, seq: 10, deleted: true)])
        let lines = shelfLines()
        XCTAssertEqual(lines.count, 1, "one line, not a cascade line plus its own")
        XCTAssertEqual(lines.first?.reason, ConflictShelfReason.tombstoneDirtyLocal.rawValue)
        XCTAssertEqual(lines.first?.seq, 10, "its own tombstone's seq")
    }

    func testSeriesTombstoneCascadesInstancesAndSeriesRecords() {
        var series = makeEvent("daily")
        series.repeatUnit = .day
        series = seedClean(series, seq: 5)
        var instance = makeEvent("moved", hour: 30)
        instance.recurrenceParentId = series.id
        instance.recurrenceInstanceDate = Self.t0.addingTimeInterval(86_400)
        store.addCalendarEvent(instance)        // never uploaded: no baseline
        let seriesLog = makeLog(seriesKey(series, dayKey: 20260529), note: "day two")
        store.calendarEventLogRecords = [seriesLog]
        XCTAssertTrue(series.isRecurringSeries && instance.isExceptionInstance, "fixture guard")

        apply([eventRow(series, seq: 12, deleted: true)])
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
        XCTAssertTrue(store.calendarEventLogRecords.isEmpty)
        let shelved = Set(shelfLines().map { "\($0.table)|\($0.reason)|\($0.seq)" })
        XCTAssertEqual(shelved, ["calendar_events|cascade|12", "event_logs|cascade|12"])
    }

    func testCascadeReleasesAbsorbedTodosAndLeavesThemDirty() {
        let parent = seedClean(makeEvent("parent"), seq: 5)
        var absorbed = makeEvent("absorbed todo", hour: 1)
        absorbed.absorbedIntoEventID = parent.id
        absorbed = seedClean(absorbed, seq: 4)
        let absorbedBase = entry(absorbed)
        apply([eventRow(parent, seq: 6, deleted: true)])
        let released = localCalendar(absorbed)
        XCTAssertNil(released?.absorbedIntoEventID)
        XCTAssertEqual(entry(absorbed), absorbedBase, "no incoming version: not replayed (I2)")
        XCTAssertNotEqual(released.map { hash($0) }, absorbedBase?.hash, "so it reads dirty and uploads")
    }

    func testLogForAnEventNotYetLocalIsStillInserted() {
        let missing = makeEvent("arrives later")
        let log = makeLog(singleKey(missing), note: "early")
        apply([logRow(log, seq: 2)])
        XCTAssertEqual(store.calendarEventLogRecords.map(\.note), ["early"])
        XCTAssertEqual(service.baseline.entry(table: "event_logs", id: wire(log.id)),
                       SyncBaselineEntry(hash: logHash(log), seq: 2))
    }

    // MARK: - Refusal (§6.1)

    private func freezeCalendar() throws {
        let other = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        other.addCalendarEvent(makeEvent("on disk"))
        let dir = try location.directoryURL()
        try Data("shredded".utf8).write(to: dir.appendingPathComponent(StorageSlot.calendarEvents.filename))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(StorageSlot.calendarEvents.backupFilename))
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    func testAFrozenSlotRefusesTheWholePageWithNothingMutated() throws {
        let list = TodoList(title: "lists still fine", colorName: "red")
        try freezeCalendar()
        XCTAssertTrue(store.isSlotFrozen(.calendarEvents), "fixture guard")
        let refusedBefore = trailLines(containing: "sync.apply.refused slot=calendarEvents seq=3").count
        let listRow = SyncFeedRow(table: "todo_lists", seq: 3,
                                  data: serverShape(service.todoListToRow(list), seq: 3, deleted: false))
        let outcome = apply([listRow, eventRow(makeEvent("peer"), seq: 4)])
        XCTAssertEqual(outcome.status, .refused(.frozen(slot: "calendarEvents")))
        XCTAssertFalse(outcome.countsAsApplied)
        XCTAssertFalse(service.inboundAtHead, "a refused page takes the session off head (I1)")
        XCTAssertTrue(store.todoLists.isEmpty, "the healthy slot's row was not applied either")
        XCTAssertTrue(service.baseline.entries(table: "todo_lists").isEmpty)
        XCTAssertNil(service.cursor.value)
        XCTAssertTrue(outcome.persistedSlots.isEmpty)
        XCTAssertEqual(trailLines(containing: "sync.apply.refused slot=calendarEvents seq=3").count, refusedBefore + 1)
    }

    func testALogPageIsRefusedWhenTheCalendarIsFrozenOnlyIfItCascades() throws {
        try freezeCalendar()
        let log = makeLog(singleKey(makeEvent("e")), note: "n")
        XCTAssertEqual(apply([logRow(log, seq: 2)]).status, .applied, "a log row does not read the calendar")
    }

    func testAShelfFailureRefusesThePageWithNothingMutated() {
        let clean = seedClean(makeEvent("clean", note: "c0"), seq: 5)
        let dirty = seedClean(makeEvent("dirty", note: "c0", hour: 2), seq: 5)
        store.updateCalendarEvent(edited(dirty, note: "mine"))
        shelf = ConflictShelf(directory: URL(fileURLWithPath: "/dev/null/Sync-NoSuchDir"))
        let baseBefore = service.baseline.entries(table: "calendar_events")
        let refusedBefore = trailLines(containing: "sync.apply.refused slot=shelf seq=6").count
        let arrayBefore = store.rawCalendarEvents.map { hash($0) }
        let outcome = apply([eventRow(edited(clean, note: "peer A"), seq: 6),
                             eventRow(edited(dirty, note: "peer B"), seq: 7)])
        XCTAssertEqual(outcome.status, .refused(.shelf))
        XCTAssertEqual(store.rawCalendarEvents.map { hash($0) }, arrayBefore, "the clean row was not adopted")
        XCTAssertEqual(service.baseline.entries(table: "calendar_events"), baseBefore)
        XCTAssertNil(service.cursor.value)
        XCTAssertTrue(outcome.persistedSlots.isEmpty)
        XCTAssertEqual(trailLines(containing: "sync.apply.refused slot=shelf seq=6").count, refusedBefore + 1)
    }

    /// A commit that returns false (here: the slot directory and its delta
    /// log made read-only) stops the page at that slot: no baseline for it,
    /// no cursor, and — #145 — the cascade's records are NOT pruned while
    /// the event they hang off is still durable.
    func testACalendarCommitFailureKeepsTheRecordsWritesNoBaselineAndNoCursor() throws {
        let x = seedClean(makeEvent("x"), seq: 5)
        let log = makeLog(singleKey(x), note: "kept")
        store.calendarEventLogRecords = [log]
        XCTAssertTrue(store.commitLogRecordsNow())
        let peerNew = makeEvent("new", hour: 1)
        let dir = try location.directoryURL()
        let deltaLog = dir.appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
        if FileManager.default.fileExists(atPath: deltaLog.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: deltaLog.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: deltaLog.path)
        }
        let outcome = apply([eventRow(x, seq: 6, deleted: true), eventRow(peerNew, seq: 7)])
        XCTAssertTrue(store.writeFailedSlots.contains(.calendarEvents),
                      "positive control: the calendar commit really was refused")
        XCTAssertEqual(outcome.status, .commitFailed(slot: "calendarEvents"))
        XCTAssertEqual(outcome.persistedSlots, ["calendarEvents"], "nothing after the failed slot")
        XCTAssertEqual(store.calendarEventLogRecords.map(\.note), ["kept"], "#145: no prune before a durable delete")
        XCTAssertEqual(entry(x)?.seq, 5, "no baseline for a slot whose commit failed")
        XCTAssertNil(entry(peerNew))
        XCTAssertNil(service.cursor.value)
        XCTAssertFalse(service.inboundAtHead)
    }

    // MARK: - Erase epoch (§6.4)

    func testAnEraseBeforePassTwoAbortsWithNothingMutated() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
            var ctx = context()
            ctx.trace = { step in if step == "pass2" { LocalDataEraseEpoch.bump() } }
            let outcome = apply([eventRow(edited(local, note: "peer"), seq: 6)], ctx)
            XCTAssertEqual(outcome.status, .staleErase)
            XCTAssertEqual(localCalendar(local)?.note, "c0")
            XCTAssertEqual(entry(local)?.seq, 5)
            XCTAssertNil(service.cursor.value)
        }
    }

    func testAnEraseBetweenSlotsStopsBeforeTheNextWrite() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let cal = makeEvent("cal")
            let todo = makeEvent("todo", hour: 1)
            var steps: [String] = []
            var ctx = context()
            ctx.trace = { step in
                steps.append(step)
                if step == "persist events" { LocalDataEraseEpoch.bump() }
            }
            let outcome = apply([eventRow(cal, seq: 2), eventRow(todo, kind: "todo", seq: 3)], ctx)
            XCTAssertEqual(outcome.status, .staleErase)
            XCTAssertEqual(outcome.persistedSlots, ["calendarEvents"], "the todo slot was never written")
            XCTAssertNotNil(entry(cal), "the calendar slot landed with its baseline")
            XCTAssertNil(entry(todo, table: "events"))
            XCTAssertNil(service.cursor.value)
            XCTAssertFalse(steps.contains("cursor"))
        }
    }

    func testAnEraseDuringPassOneRefusesTheShelfAppend() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
            store.updateCalendarEvent(edited(local, note: "mine"))
            let token = LocalDataEraseEpoch.capture()
            LocalDataEraseEpoch.bump()
            let outcome = apply([eventRow(edited(local, note: "peer"), seq: 6)], context(token: token))
            XCTAssertEqual(outcome.status, .staleErase)
            XCTAssertTrue(shelfLines().isEmpty)
            XCTAssertEqual(entry(local)?.seq, 5)
        }
    }

    // MARK: - Persist order and count (I3, §6.1)

    func testEachTouchedSlotIsPersistedOnceInOrderWithItsBaselineRightAfter() {
        let a = seedClean(makeEvent("a"), seq: 1)
        let b = seedClean(makeEvent("b", hour: 1), seq: 1)
        let c = seedClean(makeEvent("c", hour: 2), seq: 1)
        store.calendarEventLogRecords = [makeLog(singleKey(b), note: "b log"), makeLog(singleKey(c), note: "c log")]
        XCTAssertTrue(store.commitLogRecordsNow())
        var commits: [StorageSlot: Int] = [:]
        store.onSlotCommitted = { slot, _ in commits[slot, default: 0] += 1 }
        var steps: [String] = []
        var ctx = context()
        ctx.trace = { steps.append($0) }
        let outcome = apply([
            eventRow(edited(a, note: "peer"), seq: 2),
            eventRow(b, seq: 3, deleted: true),
            eventRow(c, seq: 4, deleted: true),
            eventRow(makeEvent("new", hour: 3), seq: 5),
            eventRow(makeEvent("todo", hour: 4), kind: "todo", seq: 6),
        ], ctx)
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(outcome.persistedSlots,
                       ["calendarEvents", "events", "calendarEventLogRecords", "calendarEventFeedbackRecords"])
        XCTAssertEqual(commits[.calendarEvents], 1, "two tombstones and two adopts, one calendar commit")
        XCTAssertEqual(commits[.calendarEventLogRecords], 1, "two cascades' prunes, one log commit")
        XCTAssertEqual(commits[.events], 1)
        XCTAssertTrue(store.calendarEventLogRecords.isEmpty)
        let order = ["persist calendarEvents", "baseline calendarEvents", "persist events", "baseline events",
                     "persist calendarEventLogRecords", "baseline calendarEventLogRecords", "cursor"]
        let positions = order.map { steps.firstIndex(of: $0) ?? -1 }
        XCTAssertFalse(positions.contains(-1), "\(steps)")
        XCTAssertEqual(positions, positions.sorted(), "slot → its baseline → … → cursor")
        XCTAssertEqual(service.cursor.value, 6)
    }

    func testTheCursorExpectsANewGenerationForEveryTableThatAppearedEvenWhenSkipped() {
        let local = seedClean(makeEvent("x"), seq: 10)
        apply([eventRow(local, seq: 10)])     // skip
        XCTAssertEqual(service.cursor.value, 10)
        XCTAssertEqual(service.cursor.expectedGenerations["calendar_events"], 1)
        XCTAssertEqual(service.baseline.generation(of: "calendar_events"), 1)
    }

    func testAnAppliedPageLeavesTheHeadFlagAlone() {
        XCTAssertTrue(service.inboundAtHead, "fixture guard")
        XCTAssertEqual(apply([eventRow(makeEvent("x"), seq: 1)]).status, .applied)
        XCTAssertTrue(service.inboundAtHead)
    }

    func testAnEmptyPageWritesNothing() {
        let outcome = apply([])
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertNil(outcome.cursor)
        XCTAssertNil(service.cursor.value)
    }

    // MARK: - Idempotence

    func testReapplyingTheSamePageChangesNothing() {
        let a = seedClean(makeEvent("a", note: "c0"), seq: 1)
        let d = seedClean(makeEvent("d", note: "c0", hour: 1), seq: 1)
        store.updateCalendarEvent(edited(d, note: "mine"))
        let gone = seedClean(makeEvent("gone", hour: 2), seq: 1)
        store.calendarEventLogRecords = [makeLog(singleKey(gone), note: "never uploaded")]
        let page = [eventRow(edited(a, note: "peer"), seq: 2),
                    eventRow(edited(d, note: "peer d"), seq: 3),
                    eventRow(gone, seq: 4, deleted: true),
                    eventRow(makeEvent("new", hour: 3), seq: 5)]
        apply(page)
        let arrays = store.rawCalendarEvents.map { hash($0) }
        let logs = store.calendarEventLogRecords.count
        let base = service.baseline.entries(table: "calendar_events")
        let lines = shelfLines().count
        XCTAssertEqual(lines, 2, "fixture guard: one conflict, one cascade")

        let again = apply(page)
        XCTAssertEqual(again.status, .applied)
        XCTAssertEqual(store.rawCalendarEvents.map { hash($0) }, arrays)
        XCTAssertEqual(store.calendarEventLogRecords.count, logs)
        XCTAssertEqual(service.baseline.entries(table: "calendar_events"), base)
        XCTAssertEqual(shelfLines().count, lines, "shelf dedupe keeps the re-pull idempotent")
        XCTAssertEqual(service.cursor.value, 5)
    }

    // MARK: - Pending verify

    func testAnEligiblePullThatDeliversTheRowClearsItsPendingVerifyElement() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        let key = calKey(local)
        service.notePendingVerify(key, sentSeq: 5, payload: .rowHash("sent"), pullIssue: 3)
        let early = apply([eventRow(edited(local, note: "peer"), seq: 6)], context(pullIssue: 3))
        XCTAssertTrue(early.clearedPendingVerify.isEmpty, "a pull issued before the [] may not clear it")
        XCTAssertTrue(service.pendingVerify.contains(key))
        let late = apply([eventRow(edited(local, note: "peer 2"), seq: 7)], context(pullIssue: 4))
        XCTAssertEqual(late.clearedPendingVerify, [key])
        XCTAssertFalse(service.pendingVerify.contains(key))
    }

    // MARK: - Zone first (§6.2)

    private func settingsRow(_ blob: [String: Any], seq: Int64, deleted: Bool = false) -> SyncFeedRow {
        SyncFeedRow(table: "user_settings", seq: seq,
                    data: ["user_id": uid, "settings": blob, "seq": NSNumber(value: seq),
                           "deleted_at": deleted ? "2026-10-19T00:00:00.000Z" : NSNull()])
    }

    private var zoneKey: String { CalendarOccurrenceKey.referenceTimeZoneDefaultsKey }

    func testTheZoneIsDecidedBeforeAnyOccurrenceRowOfThePageIsDecoded() {
        let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
        let remoteZone = zones.establishedIdentifier == "Pacific/Apia" ? "Asia/Tokyo" : "Pacific/Apia"
        var series = makeEvent("s")
        series.repeatUnit = .day
        let log = makeLog(seriesKey(series, dayKey: 20260601), note: "n")
        var steps: [String] = []
        var ctx = context()
        ctx.trace = { steps.append($0) }
        // The log row comes FIRST in seq order.
        apply([logRow(log, seq: 5), settingsRow([zoneKey: remoteZone], seq: 6)], ctx)
        XCTAssertEqual(zones.establishedIdentifier, remoteZone)
        let zoneAt = steps.firstIndex(of: "zone adopt")
        let decodeAt = steps.firstIndex { $0.hasPrefix("decode event_logs") }
        XCTAssertNotNil(zoneAt)
        XCTAssertNotNil(decodeAt)
        XCTAssertLessThan(zoneAt ?? .max, decodeAt ?? .min)
        XCTAssertEqual(store.calendarEventLogRecords.count, 1)
    }

    func testAZoneIsNotAdoptedOverRecordsAnchoredInTheLocalZoneAndIsLoggedOncePerSession() {
        let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
        _ = zones.referenceTimeZone              // freeze the device zone
        let localZone = zones.establishedIdentifier!
        let remoteZone = localZone == "Pacific/Apia" ? "Asia/Tokyo" : "Pacific/Apia"
        var series = makeEvent("s")
        series.repeatUnit = .day
        store.calendarEventLogRecords = [makeLog(seriesKey(series, dayKey: 20260601), note: "anchored")]
        let needle = "sync.conflict key=zone local=\(localZone) remote=\(remoteZone)"
        let before = trailLines(containing: needle).count
        apply([settingsRow([zoneKey: remoteZone], seq: 6)])
        apply([settingsRow([zoneKey: remoteZone, "x": 1], seq: 7)])
        XCTAssertEqual(zones.establishedIdentifier, localZone)
        XCTAssertEqual(trailLines(containing: needle).count, before + 1)
    }

    // MARK: - user_settings (per key)

    /// A blob as it comes off the wire: through `JSONSerialization`, so its
    /// scalars are the same `NSNumber`s a `UserDefaults` read returns.
    private func wire(_ blob: [String: Any]) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: blob)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testSettingsMergePerKeyUnionsTheAnalyzedIdsSortedAndShelvesALocalWin() {
        let showBanner = AppSettingsKeys.showTimerBanner
        let period = AppSettingsKeys.analysisDefaultPeriod
        // The base: what both sides last agreed on, as the pusher hashes it.
        defaults.set(true, forKey: showBanner)
        defaults.set("day", forKey: period)
        defaults.set(["a"], forKey: "skillAnalyzedEventIds")
        let base = SupabaseSyncService.settingsKeyHashes(SyncedSettings.currentSnapshot(defaults))
        service.baseline.setSettings(.versioned(seq: 4, keys: base, zone: nil))
        // Local changed `period` (day → week) and added an analyzed id.
        defaults.set("week", forKey: period)
        defaults.set(["b", "a"], forKey: "skillAnalyzedEventIds")
        // Remote changed `showBanner`, changed `period` differently, and
        // added another analyzed id.
        let remote = wire([showBanner: false, period: "month", "skillAnalyzedEventIds": ["c", "a"]])
        let outcome = apply([settingsRow(remote, seq: 5)])
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(defaults.object(forKey: showBanner) as? Bool, false, "remote-only change adopted")
        XCTAssertEqual(defaults.string(forKey: period), "week", "both changed: local wins")
        XCTAssertEqual(defaults.array(forKey: "skillAnalyzedEventIds") as? [String], ["a", "b", "c"])
        XCTAssertEqual(service.baseline.settings,
                       .versioned(seq: 5, keys: SupabaseSyncService.settingsKeyHashes(remote), zone: nil))
        let line = shelfLines().first
        XCTAssertEqual(line?.reason, ConflictShelfReason.settingsKeys.rawValue)
        let keys = (line?.row["keys"] as? [[String: Any]])?.compactMap { $0["key"] as? String }
        XCTAssertEqual(keys, [period])
    }

    /// The per-key in-flight echo: a remote value equal to what our
    /// outstanding write sent for that key is not a conflict.
    func testSettingsKeyEqualToTheInFlightSentValueIsAnEchoNotAConflict() {
        let period = AppSettingsKeys.analysisDefaultPeriod
        defaults.set("day", forKey: period)
        let base = SupabaseSyncService.settingsKeyHashes(SyncedSettings.currentSnapshot(defaults))
        service.baseline.setSettings(.versioned(seq: 4, keys: base.mapValues { _ in SyncBaselineEntry.unknownHash }, zone: nil))
        defaults.set("year", forKey: period)                  // typed again after sending "week"
        let sent = SupabaseSyncService.settingsKeyHashes(wire([period: "week"]))
        var ctx = context()
        ctx.inFlight = { [uid] key in
            key == SyncBaselineKey(table: "user_settings", id: uid) ? .settingsKeys(sent) : nil
        }
        let echo = apply([settingsRow(wire([period: "week"]), seq: 5)], ctx)
        XCTAssertEqual(echo.decisions[SyncBaselineKey(table: "user_settings", id: uid)], .adopt)
        XCTAssertTrue(shelfLines().isEmpty)
        XCTAssertEqual(defaults.string(forKey: period), "year")
        // Control: the same page without the in-flight entry shelves the key.
        service.baseline.setSettings(.versioned(seq: 4, keys: base.mapValues { _ in SyncBaselineEntry.unknownHash }, zone: nil))
        apply([settingsRow(wire([period: "week"]), seq: 5)])
        XCTAssertEqual(shelfLines().count, 1)
    }

    func testSettingsTombstoneNeverTouchesLocalAndBaselinesTheLocalKeys() {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        service.baseline.setSettings(.versioned(seq: 4, keys: [:], zone: "Asia/Tokyo"))
        let needle = "sync.apply.tombstoned_singleton table=user_settings seq=9"
        let before = trailLines(containing: needle).count
        apply([settingsRow([:], seq: 9, deleted: true)])
        XCTAssertEqual(defaults.object(forKey: AppSettingsKeys.showTimerBanner) as? Bool, true)
        let local = SyncedSettings.currentSnapshot(defaults)
        let expected = SupabaseSyncService.settingsKeyHashes(
            SupabaseSyncService.settingsBlobForUpload(local: local, serverZone: nil))
        XCTAssertEqual(service.baseline.settings, .versioned(seq: 9, keys: expected, zone: nil))
        XCTAssertTrue(shelfLines().isEmpty)
        XCTAssertEqual(trailLines(containing: needle).count, before + 1)
    }

    // MARK: - event_types

    private func typeRow(_ template: EventTypeTemplate, seq: Int64, deleted: Bool = false) -> SyncFeedRow {
        SyncFeedRow(table: "event_types", seq: seq,
                    data: serverShape(service.eventTypeToRow(template), seq: seq, deleted: deleted))
    }

    private func makeTypeStore(_ templates: [EventTypeTemplate]) -> EventTypeTemplateStore {
        let types = EventTypeTemplateStore(defaults: defaults)
        XCTAssertTrue(types.catalog.setTemplates(templates))
        return types
    }

    func testEventTypeNamesakesKeepTheSmallestLiveUuidAndTheLoserNeverEntersTheBaseline() {
        let small = EventTypeTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Study", colorHex: "#111111")
        let large = EventTypeTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, title: "study", colorHex: "#777777")
        let types = makeTypeStore([large])
        service.baseline.setEntry(SyncBaselineEntry(hash: "uploaded", seq: 1), table: "event_types", id: large.id.uuidString)
        var ctx = context()
        ctx.eventTypeStore = types
        let outcome = apply([typeRow(small, seq: 4)], ctx)
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(types.templates.map(\.id), [small.id], "the local loser was swapped for the winner")
        XCTAssertNotNil(service.baseline.entry(table: "event_types", id: large.id.uuidString),
                        "the local loser's entry stays, so the diff tombstones it")

        // Now the large one arrives: it loses, is not inserted, and is
        // tombstoned by the engine directly.
        let again = apply([typeRow(large, seq: 5)], ctx)
        XCTAssertEqual(again.directTombstones, [large.id.uuidString])
        XCTAssertEqual(types.templates.map(\.id), [small.id])
    }

    /// Lean `naive_dead_namesake_erases_live_type_witness`: this device holds
    /// 3 (it won earlier); the page tombstones 3 and brings 7. If the dead 3
    /// still took part, 7 would lose and be tombstoned — the type would
    /// vanish from both devices without a shelf line.
    func testADeadNamesakeTakesNoPartInChoosingTheWinner() {
        let small = EventTypeTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Study", colorHex: "#111111")
        let large = EventTypeTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, title: "Study", colorHex: "#777777")
        let types = makeTypeStore([small])
        var ctx = context()
        ctx.eventTypeStore = types
        let outcome = apply([typeRow(small, seq: 4, deleted: true), typeRow(large, seq: 5)], ctx)
        XCTAssertTrue(outcome.directTombstones.isEmpty)
        XCTAssertEqual(types.templates.map(\.id), [large.id])
        XCTAssertEqual(service.baseline.entry(table: "event_types", id: large.id.uuidString)?.seq, 5)
    }

    func testAPageWithEventTypesAndNoTypeStoreIsRefused() {
        let t = EventTypeTemplate(title: "Study", colorHex: "#111111")
        XCTAssertEqual(apply([typeRow(t, seq: 1)]).status, .refused(.missingStore(table: "event_types")))
    }

    // MARK: - todo_lists / skill_insights

    func testTodoListsAndSkillInsightsAdoptAndTombstone() {
        let list = TodoList(title: "Groceries", colorName: "green")
        let skills = SkillInsightStore(defaults: defaults)
        let insight = SkillInsight(skillName: "focus", points: 2, date: Self.t0, eventTitle: "e", reasoning: "r")
        var ctx = context()
        ctx.skillStore = skills
        apply([SyncFeedRow(table: "todo_lists", seq: 1, data: serverShape(service.todoListToRow(list), seq: 1, deleted: false)),
               SyncFeedRow(table: "skill_insights", seq: 2, data: serverShape(service.skillToRow(insight), seq: 2, deleted: false))], ctx)
        XCTAssertEqual(store.todoLists.map(\.id), [list.id])
        XCTAssertEqual(skills.insights.map(\.id), [insight.id])
        XCTAssertEqual(service.baseline.entry(table: "skill_insights", id: insight.id.uuidString)?.seq, 2)

        apply([SyncFeedRow(table: "todo_lists", seq: 3, data: serverShape(service.todoListToRow(list), seq: 3, deleted: true))], ctx)
        XCTAssertTrue(store.todoLists.isEmpty)
        XCTAssertNil(service.baseline.entry(table: "todo_lists", id: list.id.uuidString))
    }

    // MARK: - Singleton tables

    private final class FakeSingleton: SyncSingletonAdapter {
        var value: String
        var frozen = false
        var adopts = 0
        init(_ value: String) { self.value = value }
        var isFrozen: Bool { frozen }
        func localRow() -> [String: Any] { ["v": value] }
        func projected(_ incoming: [String: Any]) -> [String: Any]? {
            (incoming["v"] as? String).map { ["v": $0] }
        }
        func adopt(_ incoming: [String: Any]) -> Bool {
            adopts += 1
            value = incoming["v"] as? String ?? value
            return true
        }
    }

    private func singletonRow(_ value: String, seq: Int64, deleted: Bool = false) -> SyncFeedRow {
        SyncFeedRow(table: "agent_preferences", seq: seq,
                    data: ["user_id": uid, "v": value, "seq": NSNumber(value: seq),
                           "deleted_at": deleted ? "2026-10-19T00:00:00.000Z" : NSNull()])
    }

    func testSingletonRowsAdoptConflictAndTombstoneThroughTheTable() {
        let fake = FakeSingleton("c0")
        let h0 = SupabaseSyncService.rowHash(["v": "c0"])
        service.baseline.setEntry(SyncBaselineEntry(hash: h0, seq: 1), table: "agent_preferences", id: uid)
        var ctx = context()
        ctx.singletons = ["agent_preferences": fake]

        apply([singletonRow("c1", seq: 2)], ctx)
        XCTAssertEqual(fake.value, "c1", "clean → adopt")

        fake.value = "mine"
        let outcome = apply([singletonRow("theirs", seq: 3)], ctx)
        XCTAssertEqual(outcome.decisions[SyncBaselineKey(table: "agent_preferences", id: uid)], .conflict)
        XCTAssertEqual(fake.value, "mine")
        XCTAssertEqual(shelfLines().last?.table, "agent_preferences")

        apply([singletonRow("dead", seq: 4, deleted: true)], ctx)
        XCTAssertEqual(fake.value, "mine", "a tombstone never resets the local row")
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid),
                       SyncBaselineEntry(hash: SupabaseSyncService.rowHash(["v": "mine"]), seq: 4))
    }

    func testAFrozenSingletonStoreRefusesThePage() {
        let fake = FakeSingleton("c0")
        fake.frozen = true
        var ctx = context()
        ctx.singletons = ["agent_preferences": fake]
        XCTAssertEqual(apply([singletonRow("c1", seq: 2)], ctx).status, .refused(.frozen(slot: "agent_preferences")))
        XCTAssertEqual(fake.adopts, 0)
    }
}

// MARK: - QA round 1: gaps the first suite left open
extension SyncApplierTests {

    private func qaFrozenCatalog(history: Bool) throws -> EventTypeCatalog {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("QAProbeCatalog-\(UUID().uuidString)", isDirectory: true)
        let seeded = EventTypeCatalog(directory: dir, legacyDefaults: nil)
        XCTAssertTrue(seeded.setTemplates([EventTypeTemplate(title: "Reading", colorHex: "#112233")]))
        if history {
            XCTAssertTrue(seeded.setColorHistory(["Gone": "#ABCDEF"]))
            try Data("shredded".utf8).write(to: dir.appendingPathComponent(EventTypeCatalog.colorHistoryFilename))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("colorHistory.bak"))
        } else {
            try Data("shredded".utf8).write(to: dir.appendingPathComponent(EventTypeCatalog.templatesFilename))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("templates.bak"))
        }
        return EventTypeCatalog(directory: dir, legacyDefaults: nil)
    }

    // a settings row at or below the settings baseline seq never moves the zone.
    func testQA_P1_StaleSettingsRowNeverAdoptsItsZone() {
        let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
        _ = zones.referenceTimeZone
        let localZone = zones.establishedIdentifier!
        let remoteZone = localZone == "Pacific/Apia" ? "Asia/Tokyo" : "Pacific/Apia"
        service.baseline.setSettings(.versioned(seq: 10, keys: [:], zone: nil))
        apply([settingsRow([zoneKey: remoteZone], seq: 8)])
        XCTAssertEqual(zones.establishedIdentifier, localZone)
    }

    // a calendar tombstone reads the record slots; a frozen one refuses the page.
    func testQA_P2_FrozenFeedbackSlotRefusesACascadingTombstone() throws {
        let x = seedClean(makeEvent("x"), seq: 5)
        store.calendarEventFeedbackRecords = [makeFeedback(singleKey(x), note: "f")]
        XCTAssertTrue(store.saveCalendarEventFeedbackRecords())
        let dir = try location.directoryURL()
        try Data("shredded".utf8).write(to: dir.appendingPathComponent(StorageSlot.calendarEventFeedbackRecords.filename))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(StorageSlot.calendarEventFeedbackRecords.backupFilename))
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        XCTAssertTrue(store.isSlotFrozen(.calendarEventFeedbackRecords), "fixture guard")
        let outcome = apply([eventRow(x, seq: 6, deleted: true)])
        XCTAssertEqual(outcome.status, .refused(.frozen(slot: "calendarEventFeedbackRecords")))
        XCTAssertNotNil(localCalendar(x))
    }

    // the zone rule reads calendar/log/feedback; a frozen calendar refuses a settings page.
    func testQA_P3_FrozenCalendarRefusesASettingsPage() throws {
        try freezeCalendar()
        XCTAssertTrue(store.isSlotFrozen(.calendarEvents), "fixture guard")
        let outcome = apply([settingsRow(["x": 1], seq: 5)])
        XCTAssertEqual(outcome.status, .refused(.frozen(slot: "calendarEvents")))
    }

    // frozen event types refuse the page.
    func testQA_P4_FrozenEventTypesRefuseThePage() throws {
        let types = EventTypeTemplateStore(catalog: try qaFrozenCatalog(history: false))
        XCTAssertTrue(types.areTemplatesFrozen, "fixture guard")
        var ctx = context()
        ctx.eventTypeStore = types
        let t = EventTypeTemplate(title: "Study", colorHex: "#111111")
        XCTAssertEqual(apply([typeRow(t, seq: 1)], ctx).status, .refused(.frozen(slot: "event_types")))
    }

    // an unreadable bridged settings owner refuses a settings page.
    func testQA_P5_UnreadableBridgedOwnerRefusesASettingsPage() throws {
        let catalog = try qaFrozenCatalog(history: true)
        XCTAssertTrue(catalog.isColorHistoryFrozen, "fixture guard")
        EventTypeCatalog.register(catalog, for: defaults)
        XCTAssertTrue(SyncedSettings.hasUnreadableBridgedOwner(defaults), "fixture guard")
        let outcome = apply([settingsRow(["x": 1], seq: 5)])
        XCTAssertEqual(outcome.status, .refused(.frozen(slot: "user_settings")))
    }

    // a remote SERIES tombstone unlinks no image files and commits the calendar once.
    func testQA_P6_RemoteSeriesTombstoneUnlinksNothingAndCommitsOnce() {
        var removed: [[AgenticIntakeImageRef]] = []
        store.removeAssetFiles = { removed.append($0) }
        var series = makeEvent("daily")
        series.repeatUnit = .day
        series.agenticIntake = AgenticIntakeRecord(
            rawText: "", images: [AgenticIntakeImageRef(relativePath: "\(series.id.uuidString)/a.jpg",
                                                        pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1)],
            source: .quickAdd)
        series = seedClean(series, seq: 5)
        var commits = 0
        store.onSlotCommitted = { slot, _ in if slot == .calendarEvents { commits += 1 } }
        apply([eventRow(series, seq: 6, deleted: true)])
        XCTAssertTrue(store.rawCalendarEvents.isEmpty, "fixture guard")
        XCTAssertTrue(removed.isEmpty, "a remote series tombstone unlinks nothing")
        XCTAssertEqual(commits, 1)
    }

    // the erase check sits before every baseline write.
    func testQA_P7_AnEraseRightBeforeABaselineWriteStopsIt() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
            var ctx = context()
            ctx.trace = { if $0 == "baseline calendarEvents" { LocalDataEraseEpoch.bump() } }
            let outcome = apply([eventRow(edited(local, note: "peer"), seq: 6)], ctx)
            XCTAssertEqual(outcome.status, .staleErase)
            XCTAssertEqual(entry(local)?.seq, 5)
        }
    }

    // the erase check sits before the cursor write.
    func testQA_P8_AnEraseRightBeforeTheCursorStopsIt() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            var ctx = context()
            ctx.trace = { if $0 == "cursor" { LocalDataEraseEpoch.bump() } }
            let outcome = apply([eventRow(makeEvent("x"), seq: 6)], ctx)
            XCTAssertEqual(outcome.status, .staleErase)
            XCTAssertNil(service.cursor.value)
        }
    }

    // the erase check sits before the zone adoption.
    func testQA_P9_AnEraseRightBeforeTheZoneAdoptionStopsIt() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
            let before = zones.establishedIdentifier
            let remoteZone = before == "Pacific/Apia" ? "Asia/Tokyo" : "Pacific/Apia"
            var ctx = context()
            ctx.trace = { if $0 == "zone adopt" { LocalDataEraseEpoch.bump() } }
            let outcome = apply([settingsRow([zoneKey: remoteZone], seq: 6)], ctx)
            XCTAssertEqual(outcome.status, .staleErase)
            XCTAssertNotEqual(zones.establishedIdentifier, remoteZone)
        }
    }

    // a series FEEDBACK record anchors the zone too.
    func testQA_P11_ASeriesFeedbackRecordAlsoKeepsTheLocalZone() {
        let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
        _ = zones.referenceTimeZone
        let localZone = zones.establishedIdentifier!
        let remoteZone = localZone == "Pacific/Apia" ? "Asia/Tokyo" : "Pacific/Apia"
        var series = makeEvent("s")
        series.repeatUnit = .day
        store.calendarEventFeedbackRecords = [makeFeedback(seriesKey(series, dayKey: 20260601), note: "anchored")]
        apply([settingsRow([zoneKey: remoteZone], seq: 6)])
        XCTAssertEqual(zones.establishedIdentifier, localZone)
    }

    // the merged analyzed-id union survives the skill store's next whole-set write.
    func testQA_P12_MergedAnalyzedIdsSurviveTheNextMarkAnalyzed() {
        defaults.set(["a"], forKey: "skillAnalyzedEventIds")
        let skills = SkillInsightStore(defaults: defaults)
        let base = SupabaseSyncService.settingsKeyHashes(SyncedSettings.currentSnapshot(defaults))
        service.baseline.setSettings(.versioned(seq: 4, keys: base, zone: nil))
        var ctx = context()
        ctx.skillStore = skills
        let c = UUID().uuidString
        apply([settingsRow(wire(["skillAnalyzedEventIds": ["a", c]]), seq: 5)], ctx)
        XCTAssertEqual(Set(defaults.array(forKey: "skillAnalyzedEventIds") as? [String] ?? []), ["a", c], "fixture guard")
        skills.markAnalyzed(UUID())
        XCTAssertTrue((defaults.array(forKey: "skillAnalyzedEventIds") as? [String] ?? []).contains(c))
    }

    // two live namesakes arriving in one page — only the smallest UUID enters.
    func testQA_P13_TwoLiveNamesakesInOnePageKeepOnlyTheSmallest() {
        let small = EventTypeTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Study", colorHex: "#111111")
        let large = EventTypeTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, title: "Study", colorHex: "#777777")
        let types = makeTypeStore([])
        var ctx = context()
        ctx.eventTypeStore = types
        let outcome = apply([typeRow(large, seq: 4), typeRow(small, seq: 5)], ctx)
        XCTAssertEqual(types.templates.filter { $0.title == "Study" }.map(\.id), [small.id])
        XCTAssertEqual(outcome.directTombstones, [large.id.uuidString])
    }

    // a SEEN pending-verify row keeps the three-way result; no sentHash overwrite.
    func testQA_P14_ASeenPendingVerifyRowKeepsItsThreeWayBaseline() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        service.notePendingVerify(calKey(local), sentSeq: 5, payload: .rowHash("sent"), pullIssue: 3)
        let peer = edited(local, note: "peer")
        apply([eventRow(peer, seq: 7)], context(pullIssue: 4))
        XCTAssertEqual(entry(local), SyncBaselineEntry(hash: hash(peer), seq: 7))
    }

    // a refused page clears no pending-verify element.
    func testQA_P15_ARefusedPageClearsNoPendingVerify() throws {
        try freezeCalendar()
        let e = makeEvent("x")
        let key = calKey(e)
        service.notePendingVerify(key, sentSeq: 5, payload: .rowHash("sent"), pullIssue: 3)
        let outcome = apply([eventRow(e, seq: 7)], context(pullIssue: 4))
        XCTAssertEqual(outcome.status, .refused(.frozen(slot: "calendarEvents")), "fixture guard")
        XCTAssertTrue(service.pendingVerify.contains(key))
    }

    // a singleton row is hashed in the pusher's projection, so our own echo is an echo.
    func testQA_P16_SingletonEchoIsNotAConflict() {
        let fake = FakeSingleton("c0")
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(["v": "c0"]), seq: 1),
                                  table: "agent_preferences", id: uid)
        fake.value = "mine"
        var ctx = context()
        ctx.singletons = ["agent_preferences": fake]
        let outcome = apply([singletonRow("c0", seq: 2)], ctx)
        XCTAssertEqual(outcome.decisions[SyncBaselineKey(table: "agent_preferences", id: uid)], .echo)
        XCTAssertTrue(shelfLines().isEmpty)
    }

    // a series tombstone does not shelve an exception instance that is clean.
    func testQA_P17_ACleanExceptionInstanceIsNotShelved() {
        var series = makeEvent("daily")
        series.repeatUnit = .day
        series = seedClean(series, seq: 5)
        var instance = makeEvent("moved", hour: 30)
        instance.recurrenceParentId = series.id
        instance.recurrenceInstanceDate = Self.t0.addingTimeInterval(86_400)
        instance = seedClean(instance, seq: 5)
        apply([eventRow(series, seq: 12, deleted: true)])
        XCTAssertTrue(store.rawCalendarEvents.isEmpty, "fixture guard")
        XCTAssertTrue(shelfLines().isEmpty)
    }

    // Design §6 event_logs: identity = the decoded CalendarOccurrenceKey, so a
    // pre-#26 id is not a second record.
    func testQA_D1_ALegacyFormatLogRowDoesNotDuplicateALocalRecord() {
        let x = makeEvent("x")
        let key = singleKey(x)
        let mine = makeLog(key, note: "mine, newer")
        store.calendarEventLogRecords = [mine]
        XCTAssertTrue(store.commitLogRecordsNow())
        service.baseline.setEntry(SyncBaselineEntry(hash: logHash(mine), seq: 3), table: "event_logs", id: wire(key))
        var legacy = serverShape(service.logToRow(makeLog(key, note: "old, pre-#26")), seq: 9, deleted: false)
        legacy["id"] = "single|\(x.id.uuidString)|none|2026-05-28T00:00:00.000Z"
        apply([SyncFeedRow(table: "event_logs", seq: 9, data: legacy)])
        XCTAssertEqual(store.calendarEventLogRecords.filter { $0.id == key }.count, 1,
                       "one record per CalendarOccurrenceKey")
        var pushed: [String: [String: Any]] = [:]
        for row in store.calendarEventLogRecords.map(service.logToRow) { pushed[row["id"] as! String] = row }
        XCTAssertEqual(pushed[wire(key)]?["note"] as? String, "mine, newer",
                       "the row the pusher would PATCH under the current id")
    }

    // a tombstone on a refused page leaves the event in memory (pass 1 is read only).
    func testQA_P18_ATombstoneOnAShelfRefusedPageLeavesTheEventInMemory() {
        let gone = seedClean(makeEvent("gone"), seq: 5)
        let dirty = seedClean(makeEvent("dirty", note: "c0", hour: 2), seq: 5)
        store.updateCalendarEvent(edited(dirty, note: "mine"))
        shelf = ConflictShelf(directory: URL(fileURLWithPath: "/dev/null/Sync-NoSuchDir"))
        let outcome = apply([eventRow(gone, seq: 6, deleted: true),
                             eventRow(edited(dirty, note: "peer"), seq: 7)])
        XCTAssertEqual(outcome.status, .refused(.shelf), "fixture guard")
        XCTAssertNotNil(localCalendar(gone))
    }

    // a series tombstone shelves exactly what the series cascade prunes.
    func testQA_P19_ASeriesTombstoneShelvesOnlyWhatTheSeriesCascadePrunes() {
        var series = makeEvent("daily")
        series.repeatUnit = .day
        series = seedClean(series, seq: 5)
        let survivor = makeLog(singleKey(series), note: "single-kind key, survives the series prune")
        store.calendarEventLogRecords = [survivor]
        XCTAssertNil(EventStore.recordsSurviving([survivor], afterDeletingSeries: series, occurrenceDate: Self.t0, scope: .all),
                     "fixture guard: the series cascade keeps it")
        apply([eventRow(series, seq: 6, deleted: true)])
        XCTAssertEqual(store.calendarEventLogRecords.count, 1, "fixture guard: not pruned")
        XCTAssertTrue(shelfLines().isEmpty)
    }

    // each slot is persisted once per page (the singleton adopt is the observable write).
    func testQA_P20_ASingletonIsAdoptedOncePerPage() {
        let fake = FakeSingleton("c0")
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(["v": "c0"]), seq: 1),
                                  table: "agent_preferences", id: uid)
        var ctx = context()
        ctx.singletons = ["agent_preferences": fake]
        apply([singletonRow("c1", seq: 2)], ctx)
        XCTAssertEqual(fake.adopts, 1)
    }
}

// MARK: - Legacy record ids and the production preferences adapter

extension SyncApplierTests {

    private func legacySingleId(_ event: Event) -> String {
        "single|\(event.id.uuidString)|none|2026-05-28T00:00:00.000Z"
    }

    private func legacySeriesId(_ series: Event) -> String {
        "seriesOccurrence|\(series.id.uuidString)|\(series.id.uuidString)|2026-06-01T00:00:00.000Z"
    }

    func testTheLegacyIdDetectorKnowsBothLayouts() {
        let x = makeEvent("x")
        var series = makeEvent("s")
        series.repeatUnit = .day
        XCTAssertTrue(SupabaseSyncService.isLegacyOccurrenceKeyId(legacySingleId(x)))
        XCTAssertTrue(SupabaseSyncService.isLegacyOccurrenceKeyId(legacySeriesId(series)))
        XCTAssertFalse(SupabaseSyncService.isLegacyOccurrenceKeyId(wire(singleKey(x))))
        XCTAssertFalse(SupabaseSyncService.isLegacyOccurrenceKeyId(wire(seriesKey(series, dayKey: 20260601))))
        XCTAssertFalse(SupabaseSyncService.isLegacyOccurrenceKeyId("not|an-id"))
    }

    /// The legacy row's tombstone is the re-key cleanup of an old id, not a
    /// deletion of the record: the current record and its baseline stay.
    func testALegacyIdTombstoneLeavesTheCurrentRecordAndItsBaseline() {
        let x = makeEvent("x")
        var series = makeEvent("s")
        series.repeatUnit = .day
        let single = makeLog(singleKey(x), note: "single")
        let occurrence = makeFeedback(seriesKey(series, dayKey: 20260601), note: "series")
        store.calendarEventLogRecords = [single]
        store.calendarEventFeedbackRecords = [occurrence]
        XCTAssertTrue(store.commitLogRecordsNow())
        XCTAssertTrue(store.saveCalendarEventFeedbackRecords())
        let logBase = SyncBaselineEntry(hash: logHash(single), seq: 3)
        let feedbackBase = SyncBaselineEntry(hash: feedbackHash(occurrence), seq: 3)
        service.baseline.setEntry(logBase, table: "event_logs", id: wire(single.id))
        service.baseline.setEntry(feedbackBase, table: "event_feedback", id: wire(occurrence.id))

        var deadLog = serverShape(service.logToRow(single), seq: 9, deleted: true)
        deadLog["id"] = legacySingleId(x)
        var deadFeedback = serverShape(service.feedbackToRow(occurrence), seq: 10, deleted: true)
        deadFeedback["id"] = legacySeriesId(series)
        let outcome = apply([SyncFeedRow(table: "event_logs", seq: 9, data: deadLog),
                             SyncFeedRow(table: "event_feedback", seq: 10, data: deadFeedback)])

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(store.calendarEventLogRecords.map(\.note), ["single"])
        XCTAssertEqual(store.calendarEventFeedbackRecords.map(\.selfNote), ["series"])
        XCTAssertEqual(service.baseline.entry(table: "event_logs", id: wire(single.id)), logBase)
        XCTAssertEqual(service.baseline.entry(table: "event_feedback", id: wire(occurrence.id)), feedbackBase)
        XCTAssertEqual(Set(outcome.legacyIds.map(\.id)), [legacySingleId(x), legacySeriesId(series)])
        XCTAssertTrue(shelfLines().isEmpty)
    }

    /// Nothing is written for a legacy row, but its table still appeared, so
    /// the cursor moves with it.
    func testALegacyIdRowWritesNothingAndStillMovesTheCursor() {
        let x = makeEvent("x")
        var legacy = serverShape(service.logToRow(makeLog(singleKey(x), note: "old")), seq: 9, deleted: false)
        legacy["id"] = legacySingleId(x)
        let outcome = apply([SyncFeedRow(table: "event_logs", seq: 9, data: legacy)])
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertTrue(store.calendarEventLogRecords.isEmpty)
        XCTAssertNil(service.baseline.entry(table: "event_logs", id: legacySingleId(x)))
        XCTAssertNil(service.baseline.entry(table: "event_logs", id: wire(singleKey(x))))
        XCTAssertEqual(outcome.cursor, 9)
    }

    private func preferencesAdapter() -> AgentPreferencesSyncAdapter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncApplierPrefs-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AgentPreferencesSyncAdapter(engine: service, store: AgentPreferenceStore(directoryURL: dir))
    }

    private func preferencesRow(_ columns: [String: Any], seq: Int64) -> SyncFeedRow {
        var data = columns
        data["user_id"] = uid
        data["seq"] = NSNumber(value: seq)
        data["deleted_at"] = NSNull()
        return SyncFeedRow(table: "agent_preferences", seq: seq, data: data)
    }

    /// A slice this build cannot decode makes the row undecodable; it is
    /// never adopted as empty arrays. Missing or null columns are empty.
    func testThePreferencesAdapterNeverReadsAnUndecodableSliceAsEmpty() {
        let adapter = preferencesAdapter()
        XCTAssertNotNil(adapter.projected(["rules": [Any](), "decision_history": [Any](),
                                           "token_dynamic_hypotheses": NSNull()]), "control")
        for column in ["rules", "decision_history", "token_dynamic_hypotheses",
                       "token_meta_hypotheses", "token_projections"] {
            XCTAssertNil(adapter.projected([column: [["from_a_newer_build": true]]]), column)
            XCTAssertFalse(adapter.adopt([column: [["from_a_newer_build": true]]]), column)
        }
        var ctx = context()
        ctx.singletons = ["agent_preferences": adapter]
        let outcome = apply([preferencesRow(["rules": [["from_a_newer_build": true]]], seq: 2)], ctx)
        let key = SyncBaselineKey(table: "agent_preferences", id: uid)
        XCTAssertEqual(outcome.undecodable, [key])
        XCTAssertNil(outcome.decisions[key])
        XCTAssertNil(service.baseline.entry(table: "agent_preferences", id: uid))
    }
}

// MARK: - QA round 2: probes the second suite was missing
extension SyncApplierTests {

    private func qa2NoShelf() {
        shelf = ConflictShelf(directory: URL(fileURLWithPath: "/dev/null/Sync-NoSuchDir"))
    }

    /// A dirty calendar row whose conflict needs a shelf append; with the
    /// shelf unwritable it refuses the page.
    private func qa2RefusingRow() -> SyncFeedRow {
        let dirty = seedClean(makeEvent("dirty", note: "c0", hour: 9), seq: 5)
        store.updateCalendarEvent(edited(dirty, note: "mine"))
        return eventRow(edited(dirty, note: "peer"), seq: 99)
    }

    private func qa2MakeCalendarCommitFail() throws -> () -> Void {
        let dir = try location.directoryURL()
        let deltaLog = dir.appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
        if FileManager.default.fileExists(atPath: deltaLog.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: deltaLog.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        return {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: deltaLog.path)
        }
    }

    private func qa2Catalog() -> (EventTypeCatalog, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("QA2Catalog-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return (EventTypeCatalog(directory: dir, legacyDefaults: nil), dir)
    }

    // pass 1 is read only: a log row on a refused page is not inserted.
    func testQA2_A_ALogRowOnARefusedPageIsNotInserted() {
        let refusing = qa2RefusingRow()
        qa2NoShelf()
        let x = makeEvent("x", hour: 3)
        let outcome = apply([logRow(makeLog(singleKey(x), note: "peer"), seq: 6), refusing])
        XCTAssertEqual(outcome.status, .refused(.shelf), "fixture guard")
        XCTAssertTrue(store.calendarEventLogRecords.isEmpty)
    }

    // pass 1 is read only: a todo tombstone on a refused page leaves the todo.
    func testQA2_B_ATodoTombstoneOnARefusedPageLeavesTheTodo() {
        store.events = [makeEvent("todo", hour: 1)]
        XCTAssertTrue(store.save())
        let todo = store.events[0]
        service.baseline.setEntry(SyncBaselineEntry(hash: hash(todo, kind: "todo"), seq: 5), table: "events", id: todo.id.uuidString)
        let refusing = qa2RefusingRow()
        qa2NoShelf()
        let outcome = apply([eventRow(todo, kind: "todo", seq: 6, deleted: true), refusing])
        XCTAssertEqual(outcome.status, .refused(.shelf), "fixture guard")
        XCTAssertEqual(store.events.map(\.id), [todo.id])
    }

    // pass 1 is read only: a settings row on a refused page writes no key.
    func testQA2_C_ASettingsRowOnARefusedPageWritesNoKey() {
        let period = AppSettingsKeys.analysisDefaultPeriod
        defaults.set("day", forKey: period)
        let base = SupabaseSyncService.settingsKeyHashes(SyncedSettings.currentSnapshot(defaults))
        service.baseline.setSettings(.versioned(seq: 4, keys: base, zone: nil))
        let refusing = qa2RefusingRow()
        qa2NoShelf()
        let outcome = apply([settingsRow(wire([period: "month"]), seq: 5), refusing])
        XCTAssertEqual(outcome.status, .refused(.shelf), "fixture guard")
        XCTAssertEqual(defaults.string(forKey: period), "day")
    }

    // the zone is never adopted on a page the precheck refuses.
    func testQA2_D_AFrozenPageNeverAdoptsTheZone() throws {
        try freezeCalendar()
        let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
        let remoteZone = zones.establishedIdentifier == "Pacific/Apia" ? "Asia/Tokyo" : "Pacific/Apia"
        let outcome = apply([settingsRow([zoneKey: remoteZone], seq: 5)])
        XCTAssertEqual(outcome.status, .refused(.frozen(slot: "calendarEvents")), "fixture guard")
        XCTAssertNotEqual(zones.establishedIdentifier, remoteZone)
    }

    // pass 1 is read only: a local event-type loser stays on a refused page.
    func testQA2_E_ALocalTypeLoserStaysOnARefusedPage() {
        let small = EventTypeTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Study", colorHex: "#111111")
        let large = EventTypeTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, title: "Study", colorHex: "#777777")
        let types = makeTypeStore([large])
        let refusing = qa2RefusingRow()
        qa2NoShelf()
        var ctx = context()
        ctx.eventTypeStore = types
        let outcome = apply([typeRow(small, seq: 4), refusing], ctx)
        XCTAssertEqual(outcome.status, .refused(.shelf), "fixture guard")
        XCTAssertEqual(types.templates.map(\.id), [large.id])
    }

    // a page with skill rows and no skill store is refused before anything is written.
    func testQA2_F_ASkillPageWithoutAStoreIsRefusedWholly() {
        let e = makeEvent("x")
        let insight = SkillInsight(skillName: "focus", points: 2, date: Self.t0, eventTitle: "e", reasoning: "r")
        let outcome = apply([eventRow(e, seq: 1),
                             SyncFeedRow(table: "skill_insights", seq: 2,
                                         data: serverShape(service.skillToRow(insight), seq: 2, deleted: false))])
        XCTAssertEqual(outcome.status, .refused(.missingStore(table: "skill_insights")))
        XCTAssertNil(localCalendar(e))
    }

    // a page with a singleton row and no adapter is refused; the cursor does not pass it.
    func testQA2_G_ASingletonPageWithoutAnAdapterIsRefused() {
        let outcome = apply([eventRow(makeEvent("x"), seq: 1), singletonRow("c1", seq: 2)])
        XCTAssertEqual(outcome.status, .refused(.missingStore(table: "agent_preferences")))
        XCTAssertNil(service.cursor.value)
    }

    // a frozen todo slot refuses the page.
    func testQA2_H_AFrozenTodoSlotRefusesThePage() throws {
        let other = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        other.events = [makeEvent("on disk")]
        XCTAssertTrue(other.save())
        let dir = try location.directoryURL()
        try Data("shredded".utf8).write(to: dir.appendingPathComponent(StorageSlot.events.filename))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(StorageSlot.events.backupFilename))
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        XCTAssertTrue(store.isSlotFrozen(.events), "fixture guard")
        let outcome = apply([eventRow(makeEvent("todo"), kind: "todo", seq: 3)])
        XCTAssertEqual(outcome.status, .refused(.frozen(slot: "events")))
    }

    // the cascade shelf line carries the local record's content.
    func testQA2_I_ACascadeShelfLineCarriesTheRecord() {
        let x = seedClean(makeEvent("x"), seq: 5)
        store.calendarEventLogRecords = [makeLog(singleKey(x), note: "never uploaded")]
        XCTAssertTrue(store.commitLogRecordsNow())
        apply([eventRow(x, seq: 6, deleted: true)])
        let line = shelfLines().first { $0.reason == ConflictShelfReason.cascade.rawValue }
        XCTAssertEqual(line?.row["note"] as? String, "never uploaded")
    }

    // the log slot is committed once per page, even with log rows and a cascade.
    func testQA2_J_LogRowsAndACascadeCommitTheLogSlotOnce() {
        let gone = seedClean(makeEvent("gone"), seq: 1)
        store.calendarEventLogRecords = [makeLog(singleKey(gone), note: "gone log")]
        XCTAssertTrue(store.commitLogRecordsNow())
        var commits = 0
        store.onSlotCommitted = { slot, _ in if slot == .calendarEventLogRecords { commits += 1 } }
        let other = makeEvent("other", hour: 3)
        apply([logRow(makeLog(singleKey(other), note: "peer log"), seq: 2), eventRow(gone, seq: 3, deleted: true)])
        XCTAssertEqual(store.calendarEventLogRecords.map(\.note), ["peer log"], "fixture guard")
        XCTAssertEqual(commits, 1)
    }

    // a dead settings row is not "the server has a zone" (§6.2).
    func testQA2_K_ATombstonedSettingsRowNeverMovesTheZone() {
        let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
        let remoteZone = zones.establishedIdentifier == "Pacific/Apia" ? "Asia/Tokyo" : "Pacific/Apia"
        apply([settingsRow([zoneKey: remoteZone], seq: 5, deleted: true)])
        XCTAssertNotEqual(zones.establishedIdentifier, remoteZone)
    }

    // a bridged key the merge adopts reaches its durable owner.
    func testQA2_L_ARemoteColorHistoryReachesItsOwner() {
        let (catalog, _) = qa2Catalog()
        XCTAssertTrue(catalog.setColorHistory(["Old": "#000000"]))
        EventTypeCatalog.register(catalog, for: defaults)
        let key = EventTypeTemplateStore.colorHistoryKey
        let base = SupabaseSyncService.settingsKeyHashes(SyncedSettings.currentSnapshot(defaults))
        service.baseline.setSettings(.versioned(seq: 4, keys: base, zone: nil))
        apply([settingsRow(wire([key: ["Peer": "#FFFFFF"]]), seq: 5)])
        XCTAssertEqual(EventTypeCatalog.forDefaults(defaults).colorHistory, ["Peer": "#FFFFFF"])
    }

    // a key the remote deleted (local untouched) is removed locally.
    func testQA2_M_ARemoteKeyDeletionPropagates() {
        let period = AppSettingsKeys.analysisDefaultPeriod
        defaults.set("day", forKey: period)
        let base = SupabaseSyncService.settingsKeyHashes(SyncedSettings.currentSnapshot(defaults))
        service.baseline.setSettings(.versioned(seq: 4, keys: base, zone: nil))
        apply([settingsRow([:], seq: 5)])
        XCTAssertNil(defaults.object(forKey: period))
    }

    // a page whose commit fails clears no pending-verify element.
    func testQA2_N_ACommitFailureClearsNoPendingVerify() throws {
        _ = seedClean(makeEvent("seed"), seq: 1)
        let e = makeEvent("x", hour: 2)
        let key = calKey(e)
        service.notePendingVerify(key, sentSeq: 5, payload: .rowHash("sent"), pullIssue: 3)
        let restore = try qa2MakeCalendarCommitFail()
        defer { restore() }
        let outcome = apply([eventRow(e, seq: 7)], context(pullIssue: 4))
        XCTAssertEqual(outcome.status, .commitFailed(slot: "calendarEvents"), "fixture guard")
        XCTAssertTrue(service.pendingVerify.contains(key))
    }

    // a page stopped by an erase clears no pending-verify element.
    func testQA2_O_AnErasedPageClearsNoPendingVerify() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let e = makeEvent("x")
            let key = calKey(e)
            service.notePendingVerify(key, sentSeq: 5, payload: .rowHash("sent"), pullIssue: 3)
            var ctx = context(pullIssue: 4)
            ctx.trace = { if $0 == "persist calendarEvents" { LocalDataEraseEpoch.bump() } }
            let outcome = apply([eventRow(e, seq: 7)], ctx)
            XCTAssertEqual(outcome.status, .staleErase, "fixture guard")
            XCTAssertTrue(service.pendingVerify.contains(key))
        }
    }

    // a delivered tombstone is "seen": its pending-verify element leaves the set.
    func testQA2_P_ADeliveredTombstoneClearsItsPendingVerifyElement() {
        let local = seedClean(makeEvent("x"), seq: 5)
        let key = calKey(local)
        service.notePendingVerify(key, sentSeq: 5, payload: .rowHash("sent"), pullIssue: 3)
        let outcome = apply([eventRow(local, seq: 7, deleted: true)], context(pullIssue: 4))
        XCTAssertEqual(outcome.status, .applied, "fixture guard")
        XCTAssertFalse(service.pendingVerify.contains(key))
    }

    // re-pulling a page whose commit failed adds no second shelf line.
    func testQA2_Q_ARepullAfterACommitFailureAddsNoSecondShelfLine() throws {
        let d = seedClean(makeEvent("d", note: "c0"), seq: 5)
        store.updateCalendarEvent(edited(d, note: "mine"))
        let page = [eventRow(edited(d, note: "peer"), seq: 6), eventRow(makeEvent("new", hour: 4), seq: 7)]
        let restore = try qa2MakeCalendarCommitFail()
        let first = apply(page)
        restore()
        XCTAssertEqual(first.status, .commitFailed(slot: "calendarEvents"), "fixture guard")
        XCTAssertEqual(shelfLines().count, 1, "fixture guard")
        let second = apply(page)
        XCTAssertEqual(second.status, .applied, "fixture guard")
        XCTAssertEqual(shelfLines().count, 1)
    }

    // a legacy-id row's table still gets the new generation (S11 / B1).
    func testQA2_R_ALegacyIdRowsTableGetsTheNewGeneration() {
        let x = makeEvent("x")
        var legacy = serverShape(service.logToRow(makeLog(singleKey(x), note: "old")), seq: 9, deleted: false)
        legacy["id"] = "single|\(x.id.uuidString)|none|2026-05-28T00:00:00.000Z"
        apply([SyncFeedRow(table: "event_logs", seq: 9, data: legacy)])
        XCTAssertEqual(service.cursor.expectedGenerations["event_logs"], 1)
        XCTAssertEqual(service.baseline.generation(of: "event_logs"), 1)
    }

    // a settings row AT the baseline seq is skipped, zone included.
    func testQA2_S_ASettingsRowAtTheBaselineSeqNeverMovesTheZone() {
        let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
        let remoteZone = zones.establishedIdentifier == "Pacific/Apia" ? "Asia/Tokyo" : "Pacific/Apia"
        service.baseline.setSettings(.versioned(seq: 6, keys: [:], zone: nil))
        apply([settingsRow([zoneKey: remoteZone], seq: 6)])
        XCTAssertNotEqual(zones.establishedIdentifier, remoteZone)
    }

    // after a clean adopt each row reads clean to the pusher (same projection).
    func testQA2_U1_AnAdoptedListReadsClean() {
        let list = TodoList(title: "Groceries", colorName: "green")
        apply([SyncFeedRow(table: "todo_lists", seq: 1, data: serverShape(service.todoListToRow(list), seq: 1, deleted: false))])
        let local = store.todoLists.first { $0.id == list.id }
        XCTAssertNotNil(local, "fixture guard")
        XCTAssertEqual(service.baseline.entry(table: "todo_lists", id: list.id.uuidString)?.hash,
                       local.map { SupabaseSyncService.rowHash(service.todoListToRow($0)) })
    }

    func testQA2_U2_AnAdoptedSkillReadsClean() {
        let skills = SkillInsightStore(defaults: defaults)
        let insight = SkillInsight(skillName: "focus", points: 2, date: Self.t0, eventTitle: "e", reasoning: "r")
        var ctx = context()
        ctx.skillStore = skills
        apply([SyncFeedRow(table: "skill_insights", seq: 2, data: serverShape(service.skillToRow(insight), seq: 2, deleted: false))], ctx)
        let local = skills.insights.first { $0.id == insight.id }
        XCTAssertNotNil(local, "fixture guard")
        XCTAssertEqual(service.baseline.entry(table: "skill_insights", id: insight.id.uuidString)?.hash,
                       local.map { SupabaseSyncService.rowHash(service.skillToRow($0)) })
    }

    func testQA2_U3_AnAdoptedTypeReadsClean() {
        let types = makeTypeStore([])
        let t = EventTypeTemplate(title: "Study", colorHex: "#111111")
        var ctx = context()
        ctx.eventTypeStore = types
        apply([typeRow(t, seq: 3)], ctx)
        let local = types.templates.first { $0.id == t.id }
        XCTAssertNotNil(local, "fixture guard")
        XCTAssertEqual(service.baseline.entry(table: "event_types", id: t.id.uuidString)?.hash,
                       local.map { SupabaseSyncService.rowHash(service.eventTypeToRow($0)) })
    }

    func testQA2_U5_AnAdoptedFeedbackReadsClean() {
        let x = makeEvent("x")
        apply([feedbackRow(makeFeedback(singleKey(x), note: "f"), seq: 5)])
        let local = store.calendarEventFeedbackRecords.first
        XCTAssertNotNil(local, "fixture guard")
        XCTAssertEqual(service.baseline.entry(table: "event_feedback", id: wire(singleKey(x)))?.hash, local.map(feedbackHash))
    }

    // the conflict shelf line carries the INCOMING row (the losing version).
    func testQA2_W_AConflictShelfLineCarriesTheIncomingRow() {
        let local = seedClean(makeEvent("x", note: "c0"), seq: 5)
        store.updateCalendarEvent(edited(local, note: "mine"))
        apply([eventRow(edited(local, note: "peer"), seq: 6)])
        let line = shelfLines().first { $0.reason == ConflictShelfReason.conflict.rawValue }
        XCTAssertEqual(line?.row["note"] as? String, "peer")
    }

    // a stale settings tombstone (seq below the baseline) changes nothing.
    func testQA2_T_AStaleSettingsTombstoneIsSkipped() {
        let before = SyncSettingsBaseline.versioned(seq: 10, keys: ["k": "h"], zone: "Asia/Tokyo")
        service.baseline.setSettings(before)
        let outcome = apply([settingsRow([:], seq: 8, deleted: true)])
        XCTAssertEqual(outcome.decisions[SyncBaselineKey(table: "user_settings", id: uid)], .skip)
        XCTAssertEqual(service.baseline.settings, before)
    }

    // a live singleton row writes (h_in, seq): adopt and conflict alike.
    func testQA2_Y_ALiveSingletonRowWritesTheIncomingBaseline() {
        let fake = FakeSingleton("c0")
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(["v": "c0"]), seq: 1),
                                  table: "agent_preferences", id: uid)
        var ctx = context()
        ctx.singletons = ["agent_preferences": fake]
        apply([singletonRow("c1", seq: 2)], ctx)
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid),
                       SyncBaselineEntry(hash: SupabaseSyncService.rowHash(["v": "c1"]), seq: 2))
        fake.value = "mine"
        apply([singletonRow("theirs", seq: 3)], ctx)
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid),
                       SyncBaselineEntry(hash: SupabaseSyncService.rowHash(["v": "theirs"]), seq: 3))
    }
}

// MARK: - Persist truth: a write that did not land is a failed commit
extension SyncApplierTests {

    private func tempDirectory(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func makeReadOnly(_ dir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    }

    /// §6.2: a zone write that did not reach the file stops the page like a
    /// failed commit of user_settings — no zone_adopted line, no settings
    /// baseline past the row, nothing after it applied, no cursor, and the
    /// pending-verify set untouched.
    func testAZoneWriteThatDidNotLandStopsThePage() throws {
        let dir = try tempDirectory("SyncApplierZone")
        let zones = OccurrenceKeyMetadataStore(directory: dir, legacyDefaults: nil,
                                               currentTimeZone: { TimeZone(identifier: "Asia/Tokyo")! })
        XCTAssertEqual(zones.referenceTimeZone.identifier, "Asia/Tokyo", "fixture guard: frozen on disk")
        OccurrenceKeyMetadataStore.register(zones, for: defaults)
        try makeReadOnly(dir)
        let before = SyncSettingsBaseline.versioned(seq: 4, keys: [:], zone: nil)
        service.baseline.setSettings(before)
        let peer = makeEvent("peer")
        service.notePendingVerify(calKey(peer), sentSeq: 2, payload: .rowHash("sent"), pullIssue: 3)
        let adopted = "sync.apply.zone_adopted zone=Atlantic/Azores"
        let adoptedBefore = trailLines(containing: adopted).count
        let refused = "sync.apply.refused slot=user_settings seq=5 reason=commit"
        let refusedBefore = trailLines(containing: refused).count

        let outcome = apply([eventRow(peer, seq: 5), settingsRow([zoneKey: "Atlantic/Azores"], seq: 6)],
                            context(pullIssue: 4))

        XCTAssertEqual(OccurrenceKeyMetadataStore(directory: dir, legacyDefaults: nil).establishedIdentifier,
                       "Asia/Tokyo", "positive control: nothing reached disk")
        XCTAssertEqual(outcome.status, .commitFailed(slot: "user_settings"))
        XCTAssertEqual(trailLines(containing: adopted).count, adoptedBefore)
        XCTAssertEqual(trailLines(containing: refused).count, refusedBefore + 1)
        XCTAssertEqual(service.baseline.settings, before)
        XCTAssertNil(localCalendar(peer))
        XCTAssertNil(entry(peer))
        XCTAssertNil(service.cursor.value)
        XCTAssertTrue(service.pendingVerify.contains(calKey(peer)))
    }

    /// A zone this system does not know is never written by the store, so
    /// the page is not stopped for it and nothing claims it was adopted.
    func testAnUnknownRemoteZoneIsNeitherAdoptedNorAFailedWrite() {
        let zones = OccurrenceKeyMetadataStore.forDefaults(defaults)
        _ = zones.referenceTimeZone
        let local = zones.establishedIdentifier
        let adopted = "sync.apply.zone_adopted zone=Not/AZone"
        let unknown = "sync.apply.zone_unknown zone=Not/AZone"
        let adoptedBefore = trailLines(containing: adopted).count
        let unknownBefore = trailLines(containing: unknown).count
        let outcome = apply([settingsRow([zoneKey: "Not/AZone"], seq: 5)])
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(zones.establishedIdentifier, local)
        XCTAssertEqual(trailLines(containing: adopted).count, adoptedBefore)
        XCTAssertEqual(trailLines(containing: unknown).count, unknownBefore + 1)
    }

    /// The conversations restore keeps a failed file write in memory and
    /// reports it; the adapter passes that on.
    func testAConversationsWriteThatDidNotLandWritesNoBaseline() throws {
        let dir = try tempDirectory("SyncApplierConversations")
        let repository = AgentConversationRepository(directory: dir, legacyDefaults: nil)
        let adapter = AgentConversationsSyncAdapter(engine: service, repository: repository)
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(adapter.localRow()), seq: 1),
                                  table: "agent_conversations", id: uid)
        try makeReadOnly(dir)
        let conversation = AgentConversation(title: "from the peer", createdAt: Self.t0, updatedAt: Self.t0)
        let blob = try JSONSerialization.jsonObject(with: JSONEncoder().encode([conversation]))
        let row = SyncFeedRow(table: "agent_conversations", seq: 2,
                              data: ["user_id": uid, "conversations": blob,
                                     "seq": NSNumber(value: 2), "deleted_at": NSNull()])
        var ctx = context()
        ctx.singletons = ["agent_conversations": adapter]
        let outcome = apply([row], ctx)
        XCTAssertEqual(repository.conversations.map(\.title), ["from the peer"], "fixture guard: adopted in memory")
        let reread = AgentConversationRepository(directory: dir, legacyDefaults: nil)
        reread.ensureLoaded()
        XCTAssertFalse(reread.conversations.contains { $0.id == conversation.id }, "positive control: nothing reached disk")
        XCTAssertEqual(outcome.status, .commitFailed(slot: "agent_conversations"))
        XCTAssertEqual(service.baseline.entry(table: "agent_conversations", id: uid)?.seq, 1)
        XCTAssertNil(service.cursor.value)
    }

    /// The skills slot saves through `UserDefaults`, which cannot fail; the
    /// encode before it can (the JSON encoder refuses a non-finite number),
    /// and then nothing is saved.
    func testASkillsWriteThatDidNotLandWritesNoBaseline() {
        let skills = SkillInsightStore(defaults: defaults)
        skills.add(SkillInsight(skillName: "unsaved", points: .nan, date: Self.t0, eventTitle: "e", reasoning: "r"))
        XCTAssertTrue(SkillInsightStore(defaults: defaults).insights.isEmpty, "fixture guard: the save writes nothing")
        let peer = SkillInsight(skillName: "focus", points: 2, date: Self.t0, eventTitle: "e", reasoning: "r")
        var ctx = context()
        ctx.skillStore = skills
        let outcome = apply([SyncFeedRow(table: "skill_insights", seq: 2,
                                         data: serverShape(service.skillToRow(peer), seq: 2, deleted: false))], ctx)
        XCTAssertTrue(skills.insights.contains { $0.id == peer.id }, "fixture guard: adopted in memory")
        XCTAssertFalse(SkillInsightStore(defaults: defaults).insights.contains { $0.id == peer.id },
                       "positive control: nothing reached disk")
        XCTAssertEqual(outcome.status, .commitFailed(slot: "skill_insights"))
        XCTAssertNil(service.baseline.entry(table: "skill_insights", id: peer.id.uuidString))
        XCTAssertNil(service.cursor.value)
    }

    /// The token half of the preferences adopt: a slice that does not
    /// encode is not reported as saved.
    func testATokenSliceThatDoesNotEncodeIsNotReportedAsSaved() {
        let suite = "SyncApplierTokens-\(UUID().uuidString)"
        let tokenDefaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let repository = TokenInferenceRepository(defaults: tokenDefaults)
        XCTAssertTrue(repository.applyRestore(dynamicHypotheses: [], metaHypotheses: nil, projections: nil,
                                              strategy: .cloudOverwritesLocal, resolution: .keepCloud), "control")
        let unencodable = TokenDynamicHypothesisRecord(
            id: "h", category: .state, statement: "s", confidence: .nan, weight: 1,
            windowStart: Self.t0, windowEnd: Self.t0, relatedOccurrenceKeys: [], rationale: "r",
            derivedFromIDs: [], status: .active, updatedAt: Self.t0)
        XCTAssertFalse(repository.applyRestore(dynamicHypotheses: [unencodable], metaHypotheses: nil, projections: nil,
                                               strategy: .cloudOverwritesLocal, resolution: .keepCloud))
        XCTAssertTrue(TokenInferenceRepository(defaults: tokenDefaults).snapshot().dynamic.isEmpty,
                      "positive control: nothing reached the defaults")
    }

    /// An undecodable row was never compared and moved no baseline, so its
    /// pending-verify element stays; its table still moves the cursor.
    func testAnUndecodableRowLeavesItsPendingVerifyElement() {
        let skills = SkillInsightStore(defaults: defaults)
        var ctx = context(pullIssue: 4)
        ctx.skillStore = skills
        let readable = SkillInsight(skillName: "focus", points: 2, date: Self.t0, eventTitle: "e", reasoning: "r")
        let unreadable = SkillInsight(skillName: "newer", points: 1, date: Self.t0, eventTitle: "e", reasoning: "r")
        var data = serverShape(service.skillToRow(unreadable), seq: 6, deleted: false)
        data.removeValue(forKey: "date")
        let readableKey = SyncBaselineKey(table: "skill_insights", id: readable.id.uuidString)
        let unreadableKey = SyncBaselineKey(table: "skill_insights", id: unreadable.id.uuidString)
        service.notePendingVerify(readableKey, sentSeq: 1, payload: .rowHash("sent"), pullIssue: 3)
        service.notePendingVerify(unreadableKey, sentSeq: 1, payload: .rowHash("sent"), pullIssue: 3)
        let outcome = apply([SyncFeedRow(table: "skill_insights", seq: 5,
                                         data: serverShape(service.skillToRow(readable), seq: 5, deleted: false)),
                             SyncFeedRow(table: "skill_insights", seq: 6, data: data)], ctx)
        XCTAssertEqual(outcome.status, .applied, "fixture guard")
        XCTAssertEqual(outcome.undecodable, [unreadableKey], "fixture guard")
        XCTAssertEqual(outcome.cursor, 6)
        XCTAssertEqual(outcome.clearedPendingVerify, [readableKey], "positive control: the decoded row's element is cleared")
        XCTAssertTrue(service.pendingVerify.contains(unreadableKey))
    }

    // §6 "返回 true 后…写该 slot 的基线": a preferences write that did not
    // reach disk leaves no (h_in, seq) baseline.
    func testQA2_X1_APreferencesWriteThatDidNotLandWritesNoBaseline() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QA2Prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefs = AgentPreferenceStore(directoryURL: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let adapter = AgentPreferencesSyncAdapter(engine: service, store: prefs)
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(adapter.localRow()), seq: 1),
                                  table: "agent_preferences", id: uid)
        let rule = AgentPreferenceRule(scope: .eventTypeMapping,
                                       triggerPattern: .init(kind: .exactEventTypeTitle, value: "gym"),
                                       preferredAction: .init(kind: .keepTypeOnly, value: nil),
                                       source: .explicitSelection, lastUsedAt: Self.t0)
        let snap = TokenInferenceRepository.shared.snapshot()
        var data = service.agentPreferencesRow(rules: [rule], decisionHistory: [], dynamic: snap.dynamic,
                                               meta: snap.meta, projections: snap.projections)
        data["seq"] = NSNumber(value: 2)
        data["deleted_at"] = NSNull()
        var ctx = context()
        ctx.singletons = ["agent_preferences": adapter]
        let outcome = apply([SyncFeedRow(table: "agent_preferences", seq: 2, data: data)], ctx)
        XCTAssertEqual(prefs.rules.count, 1, "fixture guard: adopted in memory")
        XCTAssertTrue(AgentPreferenceStore(directoryURL: dir).rules.isEmpty, "positive control: nothing reached disk")
        XCTAssertNotEqual(outcome.status, .applied, "a write that did not land is a failed commit")
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid)?.seq, 1,
                       "no baseline naming the peer's row over a disk that still holds the old one")
    }

    // the same for the bridged color-history key.
    func testQA2_X2_AColorHistoryWriteThatDidNotLandWritesNoBaseline() throws {
        let (catalog, dir) = qa2Catalog()
        XCTAssertTrue(catalog.setColorHistory(["Old": "#000000"]))
        EventTypeCatalog.register(catalog, for: defaults)
        let key = EventTypeTemplateStore.colorHistoryKey
        let base = SupabaseSyncService.settingsKeyHashes(SyncedSettings.currentSnapshot(defaults))
        service.baseline.setSettings(.versioned(seq: 4, keys: base, zone: nil))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let outcome = apply([settingsRow(wire([key: ["Peer": "#FFFFFF"]]), seq: 5)])
        XCTAssertEqual(EventTypeCatalog(directory: dir, legacyDefaults: nil).colorHistory, ["Old": "#000000"],
                       "positive control: nothing reached disk")
        XCTAssertNotEqual(outcome.status, .applied, "a write that did not land is a failed commit")
        if case .versioned(let seq, _, _)? = service.baseline.settings {
            XCTAssertEqual(seq, 4, "no baseline naming the peer's value over a disk that still holds the old one")
        }
    }
}

// MARK: - QA round 3: the success side of persist truth, and the per-file conjunction
extension SyncApplierTests {

    private func qa3PreferencesRow(_ adapter: AgentPreferencesSyncAdapter, seq: Int64) -> SyncFeedRow {
        let rule = AgentPreferenceRule(scope: .eventTypeMapping,
                                       triggerPattern: .init(kind: .exactEventTypeTitle, value: "gym"),
                                       preferredAction: .init(kind: .keepTypeOnly, value: nil),
                                       source: .explicitSelection, lastUsedAt: Self.t0)
        let snap = TokenInferenceRepository.shared.snapshot()
        var data = service.agentPreferencesRow(rules: [rule], decisionHistory: [], dynamic: snap.dynamic,
                                               meta: snap.meta, projections: snap.projections)
        data["seq"] = NSNumber(value: seq)
        data["deleted_at"] = NSNull()
        return SyncFeedRow(table: "agent_preferences", seq: seq, data: data)
    }

    private func qa3IsDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // the success path of the real preferences adapter: it lands, so the page applies.
    func testQA3_P1_APreferencesAdoptThatLandsWritesTheBaseline() throws {
        let dir = try tempDirectory("QA3Prefs")
        let prefs = AgentPreferenceStore(directoryURL: dir)
        let adapter = AgentPreferencesSyncAdapter(engine: service, store: prefs)
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(adapter.localRow()), seq: 1),
                                  table: "agent_preferences", id: uid)
        var ctx = context()
        ctx.singletons = ["agent_preferences": adapter]
        let outcome = apply([qa3PreferencesRow(adapter, seq: 2)], ctx)
        XCTAssertEqual(AgentPreferenceStore(directoryURL: dir).rules.count, 1, "fixture guard: reached disk")
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid)?.seq, 2)
    }

    // the success path of the real conversations adapter.
    func testQA3_P2_AConversationsAdoptThatLandsWritesTheBaseline() throws {
        let dir = try tempDirectory("QA3Conversations")
        let repository = AgentConversationRepository(directory: dir, legacyDefaults: nil)
        let adapter = AgentConversationsSyncAdapter(engine: service, repository: repository)
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(adapter.localRow()), seq: 1),
                                  table: "agent_conversations", id: uid)
        let conversation = AgentConversation(title: "from the peer", createdAt: Self.t0, updatedAt: Self.t0)
        let blob = try JSONSerialization.jsonObject(with: JSONEncoder().encode([conversation]))
        let row = SyncFeedRow(table: "agent_conversations", seq: 2,
                              data: ["user_id": uid, "conversations": blob,
                                     "seq": NSNumber(value: 2), "deleted_at": NSNull()])
        var ctx = context()
        ctx.singletons = ["agent_conversations": adapter]
        let outcome = apply([row], ctx)
        let reread = AgentConversationRepository(directory: dir, legacyDefaults: nil)
        reread.ensureLoaded()
        XCTAssertTrue(reread.conversations.contains { $0.id == conversation.id }, "fixture guard: reached disk")
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(service.baseline.entry(table: "agent_conversations", id: uid)?.seq, 2)
    }

    // only the decisions file fails: the adopt did not land.
    func testQA3_P3_APreferencesAdoptWhoseDecisionsFileFailsWritesNoBaseline() throws {
        let dir = try tempDirectory("QA3PrefsDecisions")
        let prefs = AgentPreferenceStore(directoryURL: dir)
        let blocker = dir.appendingPathComponent("decision_records.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let adapter = AgentPreferencesSyncAdapter(engine: service, store: prefs)
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(adapter.localRow()), seq: 1),
                                  table: "agent_preferences", id: uid)
        var ctx = context()
        ctx.singletons = ["agent_preferences": adapter]
        let outcome = apply([qa3PreferencesRow(adapter, seq: 2)], ctx)
        XCTAssertTrue(qa3IsDirectory(blocker), "fixture guard: the decisions path still cannot hold a file")
        XCTAssertEqual(AgentPreferenceStore(directoryURL: dir).rules.count, 1, "fixture guard: the rules file landed")
        XCTAssertNotEqual(outcome.status, .applied)
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid)?.seq, 1)
    }

    // only the rules file fails: the adopt did not land, and the decisions file is still written.
    func testQA3_P4_APreferencesAdoptWhoseRulesFileFailsWritesNoBaseline() throws {
        let dir = try tempDirectory("QA3PrefsRules")
        let prefs = AgentPreferenceStore(directoryURL: dir)
        let blocker = dir.appendingPathComponent("preference_rules.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let decisions = dir.appendingPathComponent("decision_records.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: decisions.path), "fixture guard: no decisions file yet")
        let adapter = AgentPreferencesSyncAdapter(engine: service, store: prefs)
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(adapter.localRow()), seq: 1),
                                  table: "agent_preferences", id: uid)
        var ctx = context()
        ctx.singletons = ["agent_preferences": adapter]
        let outcome = apply([qa3PreferencesRow(adapter, seq: 2)], ctx)
        XCTAssertTrue(qa3IsDirectory(blocker), "fixture guard: the rules path still cannot hold a file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: decisions.path), "the second file is written after the first fails")
        XCTAssertNotEqual(outcome.status, .applied)
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid)?.seq, 1)
    }

    // a skill page that leaves the array as it was still applies.
    func testQA3_P5_ASkillPageThatChangesNothingStillApplies() {
        let skills = SkillInsightStore(defaults: defaults)
        skills.add(SkillInsight(skillName: "focus", points: 2, date: Self.t0, eventTitle: "e", reasoning: "r"))
        let local = skills.insights[0]
        let key = SyncBaselineKey(table: "skill_insights", id: local.id.uuidString)
        service.baseline.setEntry(SyncBaselineEntry(hash: SupabaseSyncService.rowHash(service.skillToRow(local)), seq: 1),
                                  table: "skill_insights", id: local.id.uuidString)
        var ctx = context()
        ctx.skillStore = skills
        let outcome = apply([SyncFeedRow(table: "skill_insights", seq: 2,
                                         data: serverShape(service.skillToRow(local), seq: 2, deleted: false))], ctx)
        XCTAssertNotNil(outcome.decisions[key], "fixture guard")
        XCTAssertNotEqual(outcome.decisions[key], .adopt, "fixture guard: nothing to change")
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(service.baseline.entry(table: "skill_insights", id: local.id.uuidString)?.seq, 2)
    }
}

// MARK: - One-row tables with no baseline (gh#257 staging QA round 5, bug 1)
extension SyncApplierTests {

    private func noBaseRule(_ value: String) -> AgentPreferenceRule {
        AgentPreferenceRule(scope: .eventTypeMapping,
                            triggerPattern: .init(kind: .exactEventTypeTitle, value: value),
                            preferredAction: .init(kind: .keepTypeOnly, value: nil),
                            source: .explicitSelection, lastUsedAt: Self.t0)
    }

    private func noBasePreferencesRow(_ rules: [AgentPreferenceRule], seq: Int64) -> SyncFeedRow {
        var data = service.agentPreferencesRow(rules: rules, decisionHistory: [], dynamic: [], meta: [], projections: [])
        data["seq"] = NSNumber(value: seq)
        data["deleted_at"] = NSNull()
        return SyncFeedRow(table: "agent_preferences", seq: seq, data: data)
    }

    private func emptyTokenStateGuard() {
        let snap = TokenInferenceRepository.shared.snapshot()
        XCTAssertTrue(snap.dynamic.isEmpty && snap.meta.isEmpty && snap.projections.isEmpty,
                      "fixture guard: the shared token state is empty")
    }

    /// A fresh install or an erased phone: empty preferences, no baseline.
    /// The account's row is adopted, not shelved and pushed over.
    func testNoBaseline_anEmptyPreferencesStoreAdoptsTheAccountsRow_killsEmptyReadAsAnEdit() throws {
        emptyTokenStateGuard()
        let prefs = AgentPreferenceStore(directoryURL: try tempDirectory("NoBasePrefs"))
        let adapter = AgentPreferencesSyncAdapter(engine: service, store: prefs)
        XCTAssertNil(service.baseline.entry(table: "agent_preferences", id: uid), "fixture: no baseline")
        let rule = noBaseRule("gym")
        var ctx = context()
        ctx.singletons = ["agent_preferences": adapter]

        let outcome = apply([noBasePreferencesRow([rule], seq: 7)], ctx)

        XCTAssertEqual(outcome.decisions[SyncBaselineKey(table: "agent_preferences", id: uid)], .adopt)
        XCTAssertEqual(prefs.rules.map(\.id), [rule.id])
        XCTAssertTrue(shelfLines().isEmpty)
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid)?.seq, 7)
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid)?.hash,
                       SupabaseSyncService.rowHash(adapter.localRow()), "clean: the flush sends nothing")
    }

    /// Positive control for the rule's edge: preferences with content and
    /// no baseline are a real conflict — local kept, the account's row on
    /// the shelf (design §6 row 7).
    func testNoBaseline_aPreferencesStoreWithContentIsStillAConflict_killsEveryUnbaselinedRowClean() throws {
        emptyTokenStateGuard()
        let prefs = AgentPreferenceStore(directoryURL: try tempDirectory("NoBasePrefsContent"))
        let mine = noBaseRule("mine")
        XCTAssertTrue(prefs.applyRestore(rules: [mine], decisionHistory: [], strategy: .cloudOverwritesLocal,
                                         resolution: .keepCloud), "fixture")
        let adapter = AgentPreferencesSyncAdapter(engine: service, store: prefs)
        var ctx = context()
        ctx.singletons = ["agent_preferences": adapter]

        let outcome = apply([noBasePreferencesRow([noBaseRule("theirs")], seq: 7)], ctx)

        XCTAssertEqual(outcome.decisions[SyncBaselineKey(table: "agent_preferences", id: uid)], .conflict)
        XCTAssertEqual(prefs.rules.map(\.id), [mine.id])
        XCTAssertEqual(shelfLines().map(\.table), ["agent_preferences"])
    }

    /// The chat history, the same way.
    func testNoBaseline_anEmptyConversationsStoreAdoptsTheAccountsRow() throws {
        let repository = AgentConversationRepository(directory: try tempDirectory("NoBaseConversations"), legacyDefaults: nil)
        let adapter = AgentConversationsSyncAdapter(engine: service, repository: repository)
        let conversation = AgentConversation(title: "from the account", createdAt: Self.t0, updatedAt: Self.t0)
        let blob = try JSONSerialization.jsonObject(with: JSONEncoder().encode([conversation]))
        let row = SyncFeedRow(table: "agent_conversations", seq: 3,
                              data: ["user_id": uid, "conversations": blob, "seq": NSNumber(value: 3), "deleted_at": NSNull()])
        var ctx = context()
        ctx.singletons = ["agent_conversations": adapter]

        let outcome = apply([row], ctx)

        XCTAssertEqual(outcome.decisions[SyncBaselineKey(table: "agent_conversations", id: uid)], .adopt)
        XCTAssertTrue(shelfLines().isEmpty)
        repository.ensureLoaded()
        XCTAssertTrue(repository.conversations.contains { $0.id == conversation.id })
    }
}
