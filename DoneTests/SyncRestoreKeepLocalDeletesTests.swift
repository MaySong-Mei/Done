//
//  SyncRestoreKeepLocalDeletesTests.swift
//  DoneTests
//
//  "Restore from Cloud" → Merge over rows this device deleted whose delete
//  had not reached the cloud (fix/restore-keep-local-deletes). The user's
//  rule: in a merge, such a row stays deleted and its delete still goes up;
//  "cloud overwrites local" is unchanged — the cloud's copy wins there.
//
//  A pending delete is an id the baseline holds and the local table does
//  not. Here it is made the way the app makes one: the row is deleted and
//  the debounce that would send its tombstone has not fired (the manual
//  scheduler is not advanced), the master switch is off, or the undo
//  prompt holds the tombstone back.
//
//  Every test drives the restore through `RestoreCoordinator`, the path the
//  app takes. Only API that predates the fix is used here, so the file runs
//  unchanged on the commit before it — where the revival tests fail and the
//  overwrite test passes. The preview and the trail line are in
//  SyncRestoreKeepLocalDeletesPreviewTests.
//

import XCTest
@testable import Done

@MainActor
class SyncRestoreKeepLocalDeletesTestCase: SyncRestoreAndSwitchTestCase {

    /// One row of an id table as the sync engine names it: the baseline
    /// table, the server table and the id spelled as the baseline keys it.
    struct WireRow {
        let table: String
        let server: String
        let id: String
        let isLocal: @MainActor () -> Bool
    }

    /// One row in every id table the merge touches, on the server and on
    /// the device, plus a row of each kind that stays (a calendar event that
    /// owns the log and the feedback, and an event type). `deleted` is the
    /// rows the tests delete on the device.
    struct EveryTable {
        let owner: Event
        let keptType: EventTypeTemplate
        let deleted: [WireRow]
    }

    func makeTodo(_ title: String) -> Event {
        Event(title: title, timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(1800))],
              createdAt: Self.t0, kind: .todo)
    }

    func makeLog(for event: Event) -> CalendarEventLogRecord {
        let day = Calendar.current.startOfDay(for: event.timeRanges[0].start)
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: day)
        return CalendarEventLogRecord(id: key, eventID: event.id, baseSeriesEventID: nil,
                                      occurrenceDate: day, createdAt: Self.t0, updatedAt: Self.t0)
    }

    func makeFeedback(for event: Event) -> CalendarEventFeedbackRecord {
        let day = Calendar.current.startOfDay(for: event.timeRanges[0].start)
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: day)
        return CalendarEventFeedbackRecord(id: key, eventID: event.id, baseSeriesEventID: nil,
                                           occurrenceDate: day, createdAt: Self.t0, updatedAt: Self.t0)
    }

    func local(_ id: UUID) -> Event? {
        store.rawCalendarEvents.first { $0.id == id }
    }

    func baselineEntry(_ row: WireRow) -> SyncBaselineEntry? {
        service.baseline.entry(table: row.table, id: row.id)
    }

    func writesNaming(_ row: WireRow, after index: Int) -> [SyncFakeServer.Request] {
        // A log and a feedback record of one occurrence share their id, so a
        // write is matched on its table as well as its key.
        writes(after: index).filter { $0.table == row.server && $0.keys.contains { $0.lowercased() == row.id.lowercased() } }
    }

    func trailLines(_ needle: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init).filter { $0.contains(needle) }
    }

    func coordinator() -> RestoreCoordinator {
        let c = RestoreCoordinator(waitForLoadingFrame: {})
        c.configure(syncService: service, eventStore: store, eventTypeStore: device.types,
                    skillStore: device.skills, preferenceStore: device.prefs)
        return c
    }

    /// Seeds one row per id table on the server and pulls them, so each is
    /// on the device with a baseline entry at its server seq.
    func seedEveryTable() async throws -> EveryTable {
        let owner = makeEvent("owns the log and the feedback, stays")
        let cal = makeEvent("calendar event deleted here")
        let todo = makeTodo("todo deleted here")
        let log = makeLog(for: owner)
        let feedback = makeFeedback(for: owner)
        let list = TodoList(title: "list deleted here", colorName: "green", createdAt: Self.t0)
        let keptType = EventTypeTemplate(title: "Kept type", colorHex: "#112233")
        let type = EventTypeTemplate(title: "Type deleted here", colorHex: "#445566")
        let skill = makeSkill("skill deleted here")
        server.seed(table: "events", rows: [row(owner), row(cal), service.eventToRow(todo, kind: "todo")])
        server.seed(table: "event_logs", rows: [service.logToRow(log)])
        server.seed(table: "event_feedback", rows: [service.feedbackToRow(feedback)])
        server.seed(table: "todo_lists", rows: [service.todoListToRow(list)])
        server.seed(table: "event_types", rows: [service.eventTypeToRow(keptType), service.eventTypeToRow(type)])
        server.seed(table: "skill_insights", rows: [service.skillToRow(skill)])
        await puller.pullToHead()

        let store = self.store, types = device.types, skills = device.skills
        let logId = service.encodeOccurrenceKey(log.id), feedbackId = service.encodeOccurrenceKey(feedback.id)
        let deleted = [
            WireRow(table: "calendar_events", server: "events", id: cal.id.uuidString,
                    isLocal: { store.rawCalendarEvents.contains { $0.id == cal.id } }),
            WireRow(table: "events", server: "events", id: todo.id.uuidString,
                    isLocal: { store.events.contains { $0.id == todo.id } }),
            WireRow(table: "event_logs", server: "event_logs", id: logId,
                    isLocal: { store.calendarEventLogRecords.contains { $0.id == log.id } }),
            WireRow(table: "event_feedback", server: "event_feedback", id: feedbackId,
                    isLocal: { store.calendarEventFeedbackRecords.contains { $0.id == feedback.id } }),
            WireRow(table: "todo_lists", server: "todo_lists", id: list.id.uuidString,
                    isLocal: { store.todoLists.contains { $0.id == list.id } }),
            WireRow(table: "event_types", server: "event_types", id: type.id.uuidString,
                    isLocal: { types.templates.contains { $0.id == type.id } }),
            WireRow(table: "skill_insights", server: "skill_insights", id: skill.id.uuidString,
                    isLocal: { skills.insights.contains { $0.id == skill.id } }),
        ]
        for row in deleted {
            XCTAssertTrue(row.isLocal(), "fixture: \(row.table) was pulled")
            XCTAssertEqual(baselineEntry(row)?.seq, server.seq(table: row.server, key: row.id),
                           "fixture: \(row.table) is recorded at its server seq")
        }
        XCTAssertNotNil(local(owner.id), "fixture: the owner was pulled")
        XCTAssertTrue(types.templates.contains { $0.id == keptType.id }, "fixture: the kept type was pulled")
        return EveryTable(owner: owner, keptType: keptType, deleted: deleted)
    }

    /// Deletes every row of `rows` on the device, the way the app removes
    /// each kind. Nothing is sent: the debounce is not advanced.
    func deleteOnDevice(_ fixture: EveryTable) {
        for row in fixture.deleted {
            switch row.table {
            case "calendar_events":
                if let event = store.rawCalendarEvents.first(where: { $0.id.uuidString == row.id }) {
                    store.deleteCalendarEvent(event, unlinkAssets: false)
                }
            case "events":
                if let todo = store.events.first(where: { $0.id.uuidString == row.id }) { store.delete(todo) }
            case "event_logs":
                store.calendarEventLogRecords.removeAll { service.encodeOccurrenceKey($0.id) == row.id }
                store.saveCalendarEventLogRecords()
            case "event_feedback":
                store.calendarEventFeedbackRecords.removeAll { service.encodeOccurrenceKey($0.id) == row.id }
                store.saveCalendarEventFeedbackRecords()
            case "todo_lists":
                if let list = store.todoLists.first(where: { $0.id.uuidString == row.id }) { store.deleteList(list) }
            case "event_types":
                if let type = device.types.templates.first(where: { $0.id.uuidString == row.id }) {
                    device.types.remove(title: type.title)
                }
            case "skill_insights":
                // The skills store has no single-row delete; the array losing
                // the row is what the flush reads as a delete.
                device.skills.replaceInsightsFromSync(device.skills.insights.filter { $0.id.uuidString != row.id })
            default:
                XCTFail("no delete for \(row.table)")
            }
        }
        for row in fixture.deleted {
            XCTAssertFalse(row.isLocal(), "fixture: \(row.table) was deleted on the device")
            XCTAssertNotNil(baselineEntry(row), "fixture: \(row.table)'s delete is pending (the baseline still holds it)")
        }
    }
}

// MARK: - The merge keeps the device's pending deletes

@MainActor
final class SyncRestoreKeepLocalDeletesTests: SyncRestoreKeepLocalDeletesTestCase {

    enum Resolve {
        case keepLocal, keepCloud, perRowKeepCloud
    }

    /// Every id table: a row deleted here, its tombstone not yet sent (the
    /// debounce has not fired), is in the snapshot the merge applies. After
    /// the merge it is still deleted and its baseline entry is the one it
    /// had; the next flush tombstones it, and only that. `k` is a calendar
    /// row edited here and different on the cloud — a conflict — so the
    /// resolution is seen to apply while the deletes stay.
    private func assertEveryTableKeepsItsDelete(_ resolve: Resolve,
                                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try await seedEveryTable()
        let k = makeEvent("K, edited here", note: "v1")
        server.seed(table: "events", rows: [row(k)])
        await puller.pullToHead()
        var mine = try XCTUnwrap(local(k.id), "fixture: K was pulled")
        mine.note = "mine"
        store.updateCalendarEvent(mine)
        let entriesBefore = fixture.deleted.map(baselineEntry)
        deleteOnDevice(fixture)
        XCTAssertTrue(writes().isEmpty, "fixture: nothing has been sent", file: file, line: line)

        let c = coordinator()
        await c.startFetch()
        guard case .ready(let snapshot) = c.phase else { return XCTFail("the fetch did not finish: \(c.phase)", file: file, line: line) }
        for row in fixture.deleted {
            XCTAssertNotNil(snapshot.cloudSeqs[SyncBaselineKey(table: row.table, id: row.id)],
                            "fixture: the snapshot carries \(row.table)'s row", file: file, line: line)
        }
        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: K conflicts, got \(c.phase)", file: file, line: line) }
        switch resolve {
        case .keepLocal:
            await c.applyMerge(resolution: .keepLocal)
        case .keepCloud:
            await c.applyMerge(resolution: .keepCloud)
        case .perRowKeepCloud:
            c.enterPerRowReview()
            c.perRowDecisions.calendarEvents[k.id] = .keepCloud
            await c.applyPerRow()
        }
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)", file: file, line: line) }

        XCTAssertEqual(local(k.id)?.note, resolve == .keepLocal ? "mine" : "v1",
                       "positive control: the merge resolved K as asked", file: file, line: line)
        XCTAssertNotNil(local(fixture.owner.id), file: file, line: line)
        for (row, before) in zip(fixture.deleted, entriesBefore) {
            XCTAssertFalse(row.isLocal(), "\(row.table): the merge brought back a row deleted here", file: file, line: line)
            XCTAssertEqual(baselineEntry(row), before, "\(row.table): the restore changed the pending delete's entry", file: file, line: line)
        }
        let before = server.requests.count

        scheduler.advance(by: debounce)
        for row in fixture.deleted {
            try await syncEventually("\(row.table): the delete reached the cloud") {
                self.server.isTombstoned(table: row.server, key: row.id)
            }
        }
        try await settle()
        for row in fixture.deleted {
            XCTAssertEqual(writesNaming(row, after: before).map(\.verb), [.tombstone],
                           "\(row.table): the delete was not sent exactly once, as a tombstone", file: file, line: line)
            XCTAssertNil(baselineEntry(row), "\(row.table): the answered tombstone left its entry", file: file, line: line)
            XCTAssertFalse(row.isLocal(), file: file, line: line)
        }
        XCTAssertFalse(server.isTombstoned(table: "events", key: fixture.owner.id.uuidString), file: file, line: line)
        XCTAssertFalse(server.isTombstoned(table: "event_types", key: fixture.keptType.id.uuidString), file: file, line: line)
    }

    func testKeepLocal_everyTablesPendingDeleteStaysDeletedAndIsSent() async throws {
        try await assertEveryTableKeepsItsDelete(.keepLocal)
    }

    func testKeepCloud_everyTablesPendingDeleteStaysDeletedAndIsSent() async throws {
        try await assertEveryTableKeepsItsDelete(.keepCloud)
    }

    func testPerRow_everyTablesPendingDeleteStaysDeletedAndIsSent() async throws {
        try await assertEveryTableKeepsItsDelete(.perRowKeepCloud)
    }

    /// The delete made while uploads were off: the merge keeps it, and the
    /// switch coming back on sends it.
    func testADeleteMadeWhileUploadsWereOffStaysDeletedAndGoesUpWhenTheSwitchComesBackOn() async throws {
        let x = makeEvent("X, deleted while uploads were off")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        let entryBefore = try XCTUnwrap(entry(x))
        switchOff()
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(writes().isEmpty, "positive control: the switch kept the delete on the phone")
        XCTAssertEqual(entry(x), entryBefore, "fixture: the delete is pending")

        try await restore(.merge)
        XCTAssertNil(local(x.id), "the merge brought back a row deleted while uploads were off")
        XCTAssertEqual(entry(x), entryBefore, "the restore changed the pending delete's entry")
        let before = server.requests.count

        switchOn()
        try await syncEventually("the delete reached the cloud") { self.server.isTombstoned(table: "events", key: x.id.uuidString) }
        try await settle()
        XCTAssertEqual(writes(after: before).filter { names($0, x.id) }.map(\.verb), [.tombstone])
        XCTAssertNil(local(x.id))
    }

    /// A pending delete the snapshot does not carry: Y was made here, its
    /// POST landed after the restore fetch read the events table, and then
    /// Y was deleted here. The merge has nothing to leave out, but the
    /// replay keeps Y's entry, so the tombstone goes up. Dropped, nothing
    /// would delete Y on the server, and the next pull would bring it back.
    func testAPendingDeleteTheSnapshotDoesNotCarryStillGoesUp() async throws {
        server.holdWhen = { verb, table in verb == .insert && table == "events" }
        let y = makeEvent("Y, made here")
        store.addCalendarEvent(y)
        scheduler.advance(by: debounce)
        try await syncEventually("Y's POST is on its way") { self.server.heldCount == 1 }
        let c = coordinator()
        await c.startFetch()
        guard case .ready(let snapshot) = c.phase else { return XCTFail("the fetch did not finish: \(c.phase)") }
        XCTAssertFalse(snapshot.calendarEvents.contains { $0.id == y.id }, "fixture: the fetch read the table before Y landed")
        server.holdWhen = nil
        server.releaseAll()
        try await syncEventually("Y landed") { self.onServer(y) != nil }
        try await syncEventually("Y's answer was recorded") { self.entry(y)?.seq != nil }
        let entryOfY = try XCTUnwrap(entry(y))
        store.deleteCalendarEvent(try XCTUnwrap(local(y.id)), unlinkAssets: false)

        await c.prepareMerge()
        if case .mergeReview = c.phase { await c.applyMerge(resolution: .keepLocal) }
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertNil(local(y.id))
        XCTAssertEqual(entry(y), entryOfY, "the restore dropped the entry of a delete the snapshot did not carry")

        scheduler.advance(by: debounce)
        try await syncEventually("the delete reached the cloud") { self.server.isTombstoned(table: "events", key: y.id.uuidString) }
        await puller.pullToHead()
        try await settle()
        XCTAssertNil(local(y.id), "the pull brought back a row deleted here")
    }

    // MARK: - Overwrite is unchanged

    /// "Cloud overwrites local": the cloud's copy of every row deleted here
    /// comes back, reads clean at its cloud seq, and no tombstone goes up.
    func testOverwrite_theCloudsCopyOfEveryPendingDeleteComesBackAndNoTombstoneIsSent() async throws {
        let fixture = try await seedEveryTable()
        deleteOnDevice(fixture)
        try await restore(.cloudOverwritesLocal)

        for row in fixture.deleted {
            XCTAssertTrue(row.isLocal(), "\(row.table): the overwrite did not take the cloud's copy")
            XCTAssertEqual(baselineEntry(row)?.seq, server.seq(table: row.server, key: row.id),
                           "\(row.table): the overwrite's row is not recorded at its cloud seq")
        }
        let before = server.requests.count
        scheduler.advance(by: debounce)
        try await settle()
        try await settle()
        for row in fixture.deleted {
            XCTAssertFalse(server.isTombstoned(table: row.server, key: row.id), "\(row.table): the overwrite's row was deleted")
            XCTAssertEqual(writesNaming(row, after: before).map(\.verb), [], "\(row.table): a row the cloud holds as it is was sent")
        }
    }

    // MARK: - The undo window

    /// A merge of todos S into T: S is deleted, its tombstone held while the
    /// undo prompt is up (`EventGridView.mergeUndoWindow`). A restore merged
    /// inside the window keeps S deleted; the tombstone goes up when the
    /// window ends, not before.
    private func todoMergedInsideItsUndoWindow() async throws -> (t: Event, s: Event, entry: SyncBaselineEntry) {
        let t = makeTodo("T"), s = makeTodo("S, merged into T")
        server.seed(table: "events", rows: [service.eventToRow(t, kind: "todo"), service.eventToRow(s, kind: "todo")])
        await puller.pullToHead()
        let localS = try XCTUnwrap(store.events.first { $0.id == s.id }, "fixture: S was pulled")
        let entryOfS = try XCTUnwrap(service.baseline.entry(table: "events", id: s.id.uuidString))
        store.delete(localS)
        service.undoHold.hold([s.id], for: EventGridView.mergeUndoWindow)
        return (t, localS, entryOfS)
    }

    func testUndoWindow_aRestoreInsideItKeepsTheRowDeletedAndTheTombstoneGoesUpWhenItEnds() async throws {
        let (_, s, entryOfS) = try await todoMergedInsideItsUndoWindow()
        try await restore(.merge)
        XCTAssertFalse(store.events.contains { $0.id == s.id }, "the merge brought back the row the undo prompt is holding")
        XCTAssertEqual(service.baseline.entry(table: "events", id: s.id.uuidString), entryOfS)

        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertFalse(server.isTombstoned(table: "events", key: s.id.uuidString), "the tombstone went up inside the undo window")
        XCTAssertTrue(service.undoHold.isHeld(s.id.uuidString), "fixture: the window has not ended")

        scheduler.advance(by: EventGridView.mergeUndoWindow)
        try await syncEventually("the tombstone went up when the window ended") {
            self.server.isTombstoned(table: "events", key: s.id.uuidString)
        }
        XCTAssertFalse(store.events.contains { $0.id == s.id })
    }

    /// The same, and the user taps Undo after the restore: S (as the device
    /// held it) comes back clean against the entry the restore kept, and
    /// nothing is sent for it.
    func testUndoWindow_undoAfterTheRestoreBringsTheRowBackWithNothingSent() async throws {
        let (_, s, entryOfS) = try await todoMergedInsideItsUndoWindow()
        try await restore(.merge)
        XCTAssertFalse(store.events.contains { $0.id == s.id }, "the merge brought back the row the undo prompt is holding")
        let before = server.requests.count

        service.undoHold.release([s.id])
        store.add(s)
        scheduler.advance(by: debounce)
        try await settle()
        try await settle()
        XCTAssertTrue(store.events.contains { $0.id == s.id }, "fixture: the undo put S back")
        XCTAssertEqual(service.baseline.entry(table: "events", id: s.id.uuidString), entryOfS)
        XCTAssertEqual(writes(after: before).filter { names($0, s.id) }.map(\.verb), [], "the undone delete sent something")
        XCTAssertFalse(server.isTombstoned(table: "events", key: s.id.uuidString))
    }

    // MARK: - The restore's re-pull

    /// The fetch, then a pull during the review (so the apply rewinds the
    /// cursor and pulls again), and a peer's edit of X — deleted here — that
    /// the device has not pulled. The restore's own pull delivers X's live
    /// copy: the §6 table's pending-delete row (local absent, entry present)
    /// shelves it and leaves X deleted; the tombstone still goes up.
    func testTheRestoresOwnPullMeetingALiveCopyOfAPendingDeleteLeavesItDeleted() async throws {
        let x = makeEvent("X, deleted here", note: "v1")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        let c = coordinator()
        await c.startFetch()
        guard case .ready(let snapshot) = c.phase else { return XCTFail("the fetch did not finish: \(c.phase)") }
        XCTAssertEqual(snapshot.calendarEvents.first { $0.id == x.id }?.note, "v1", "fixture: the snapshot carries X")

        let y = makeEvent("Y, a peer's row pulled during the review")
        let ySeq = try XCTUnwrap(server.seed(table: "events", rows: [row(y)])[y.id.uuidString])
        await puller.pullToHead()
        XCTAssertNotNil(local(y.id), "fixture: the device pulled during the review")
        XCTAssertNil(local(x.id), "fixture: X is still deleted")
        let peerSeq = server.writeDirectly(table: "events", key: x.id.uuidString, data: ["note": "peer, not pulled"])
        XCTAssertGreaterThan(peerSeq, ySeq)
        DiagnosticTrail.clear()

        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: the merge is reviewed, got \(c.phase)") }
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        try await syncEventually("the restore's pull reached head") { self.service.cursor.value == peerSeq }
        try await settle()

        XCTAssertEqual(trailLines("sync.pull reason=restore").count, 1, "positive control: the restore pulled again")
        XCTAssertEqual(trailLines("sync.conflict table=calendar_events id=\(x.id.uuidString)").count, 1,
                       "positive control: the pull delivered X's live copy")
        XCTAssertNil(local(x.id), "the re-pulled live copy brought back a row deleted here")
        XCTAssertTrue(shelved(x.id).contains {
            $0.reason == ConflictShelfReason.pendingDelete.rawValue && $0.row["note"] as? String == "peer, not pulled"
        }, "the peer's edit is not on the shelf")
        XCTAssertEqual(entry(x)?.seq, peerSeq, "the pending delete's entry names the version the pull met")
        let before = server.requests.count

        scheduler.advance(by: debounce)
        try await syncEventually("the delete reached the cloud") { self.server.isTombstoned(table: "events", key: x.id.uuidString) }
        try await settle()
        XCTAssertEqual(writes(after: before).filter { names($0, x.id) }.map(\.verb), [.tombstone])
        XCTAssertNil(local(x.id))
    }

    /// The peer's edit of X pulled during the review instead (the §6 table
    /// shelved it then): the restore's pull re-delivers that very version,
    /// which is skipped, and X stays deleted.
    func testTheRestoresOwnPullReDeliveringAVersionTheDeviceAlreadyMetLeavesItDeleted() async throws {
        let x = makeEvent("X, deleted here", note: "v1")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        let c = coordinator()
        await c.startFetch()
        guard case .ready = c.phase else { return XCTFail("the fetch did not finish: \(c.phase)") }

        let peerSeq = server.writeDirectly(table: "events", key: x.id.uuidString, data: ["note": "peer, pulled"])
        await puller.pullToHead()
        XCTAssertNil(local(x.id), "fixture: the pull during the review left X deleted")
        let entryAfterThePull = try XCTUnwrap(entry(x))
        XCTAssertEqual(entryAfterThePull.seq, peerSeq, "fixture: the pull met X's peer edit")
        let shelfBefore = shelved(x.id).count
        DiagnosticTrail.clear()

        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: the merge is reviewed, got \(c.phase)") }
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        try await syncEventually("the restore's pull reached head") { self.service.cursor.value == peerSeq }
        try await settle()

        XCTAssertEqual(trailLines("sync.pull reason=restore").count, 1, "positive control: the restore pulled again")
        XCTAssertNil(local(x.id), "the re-delivered version brought back a row deleted here")
        XCTAssertEqual(entry(x), entryAfterThePull)
        XCTAssertEqual(shelved(x.id).count, shelfBefore, "the re-delivered version was shelved a second time")

        scheduler.advance(by: debounce)
        try await syncEventually("the delete reached the cloud") { self.server.isTombstoned(table: "events", key: x.id.uuidString) }
    }

    // MARK: - Event types: matched by title, kept deleted by id

    /// The type deleted here, then a new type of the same title made here.
    /// The merge matches types by title, so on the deleted type's cloud row
    /// keep-cloud would put the deleted UUID back in place of the new one,
    /// and keep-local would leave it out but drop its entry, so its delete
    /// never went up. Either way now: the new type stays, the deleted one
    /// stays deleted, and its tombstone goes up.
    private func assertADeletedTypeStaysDeletedBesideANewNamesake(_ resolution: ConflictResolution,
                                                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let kept = EventTypeTemplate(title: "Kept type", colorHex: "#112233")
        let reading = EventTypeTemplate(title: "Reading", colorHex: "#445566")
        server.seed(table: "event_types", rows: [service.eventTypeToRow(kept), service.eventTypeToRow(reading)])
        await puller.pullToHead()
        let types = device.types
        XCTAssertTrue(types.templates.contains { $0.id == reading.id }, "fixture: the type was pulled", file: file, line: line)
        let entryBefore = try XCTUnwrap(service.baseline.entry(table: "event_types", id: reading.id.uuidString))
        types.remove(title: "Reading")
        types.add("Reading", colorHex: "#00AA00")
        let namesake = try XCTUnwrap(types.templates.first { $0.title == "Reading" }, "fixture: the new type was made", file: file, line: line)
        XCTAssertNotEqual(namesake.id, reading.id, "fixture: the new type has its own UUID", file: file, line: line)

        let c = coordinator()
        await c.startFetch()
        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: the merge is reviewed, got \(c.phase)", file: file, line: line) }
        await c.applyMerge(resolution: resolution)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)", file: file, line: line) }

        XCTAssertEqual(types.templates.filter { $0.title == "Reading" }.map(\.id), [namesake.id],
                       "the deleted type came back, or replaced the new one", file: file, line: line)
        XCTAssertEqual(service.baseline.entry(table: "event_types", id: reading.id.uuidString), entryBefore,
                       "the restore changed the deleted type's entry", file: file, line: line)
        let before = server.requests.count
        scheduler.advance(by: debounce)
        try await syncEventually("the deleted type's tombstone went up") {
            self.server.isTombstoned(table: "event_types", key: reading.id.uuidString)
        }
        try await syncEventually("the new type went up") { self.server.row(table: "event_types", key: namesake.id.uuidString) != nil }
        try await settle()
        XCTAssertEqual(writes(after: before).filter { $0.table == "event_types" && names($0, reading.id) }.map(\.verb), [.tombstone],
                       file: file, line: line)
        XCTAssertEqual(types.templates.filter { $0.title == "Reading" }.map(\.id), [namesake.id], file: file, line: line)
    }

    func testEventTypes_keepCloud_aDeletedTypeStaysDeletedBesideANewNamesake() async throws {
        try await assertADeletedTypeStaysDeletedBesideANewNamesake(.keepCloud)
    }

    func testEventTypes_keepLocal_aDeletedTypeStaysDeletedBesideANewNamesake() async throws {
        try await assertADeletedTypeStaysDeletedBesideANewNamesake(.keepLocal)
    }
}
