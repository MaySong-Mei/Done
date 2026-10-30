//
//  SyncRestoreKeepLocalDeletesQATests.swift
//  DoneTests
//
//  Independent QA for fix/restore-keep-local-deletes (the user's rule: in a
//  "Restore from Cloud" merge, a row deleted on this device whose delete has
//  not reached the cloud stays deleted and its delete still goes up; "cloud
//  overwrites local" is unchanged).
//
//  These tests use only API that predates the fix, so the file also runs on
//  king 9121ba12, where the tests that pin the rule fail (the positive
//  control) and the ones marked "same on both" pass.
//
//  The deletes here are made the ways the app makes them: the store's own
//  delete calls, the todo merge / smart split with the undo hold that
//  EventGridView puts on them, and the Undo buttons' own actions
//  (`undoHold.release` + `undoMerge` / `undoSmartSplit`).
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreKeepLocalDeletesQATests: SyncRestoreAndSwitchTestCase {

    // MARK: Helpers

    func local(_ id: UUID) -> Event? {
        store.rawCalendarEvents.first { $0.id == id }
    }

    func todos(_ id: UUID) -> [Event] {
        store.events.filter { $0.id == id }
    }

    func makeTodo(_ title: String, note: String = "") -> Event {
        Event(title: title, note: note, timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(1800))],
              createdAt: Self.t0, kind: .todo)
    }

    func todoEntry(_ id: UUID) -> SyncBaselineEntry? {
        service.baseline.entry(table: "events", id: id.uuidString)
    }

    func coordinator(waitForLoadingFrame: @escaping @MainActor () async -> Void = {}) -> RestoreCoordinator {
        let c = RestoreCoordinator(waitForLoadingFrame: waitForLoadingFrame)
        c.configure(syncService: service, eventStore: store, eventTypeStore: device.types,
                    skillStore: device.skills, preferenceStore: device.prefs)
        return c
    }

    /// Seeds calendar rows on the server and pulls them.
    @discardableResult
    func seedAndPull(_ events: [Event]) async throws -> [Event] {
        server.seed(table: "events", rows: events.map(row))
        await puller.pullToHead()
        for e in events { XCTAssertNotNil(local(e.id), "fixture: \(e.title) was pulled") }
        return events
    }

    func seedTodosAndPull(_ todos: [Event]) async {
        server.seed(table: "events", rows: todos.map { service.eventToRow($0, kind: "todo") })
        await puller.pullToHead()
        for t in todos { XCTAssertEqual(self.todos(t.id).count, 1, "fixture: \(t.title) was pulled") }
    }

    /// Fetch, prepare, and (when reviewed) apply with `resolution`.
    func merge(_ c: RestoreCoordinator, _ resolution: ConflictResolution = .keepLocal,
               file: StaticString = #filePath, line: UInt = #line) async {
        await c.startFetch()
        guard case .ready = c.phase else { return XCTFail("the fetch did not finish: \(c.phase)", file: file, line: line) }
        await c.prepareMerge()
        if case .mergeReview = c.phase { await c.applyMerge(resolution: resolution) }
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)", file: file, line: line) }
    }

    // MARK: - Undo after the restore (the Undo buttons' real actions)

    /// Todos S merged into T (EventGridView.performMerge: `mergeEvents` + the
    /// undo hold), a keep-cloud merge restore inside the window, then Undo:
    /// S is back exactly once, clean against the entry it had, and nothing
    /// naming S goes out — not when the debounce fires, not when the window
    /// would have ended.
    func testUndoMergeTappedAfterTheRestore_SComesBackOnceCleanAndNothingIsSent() async throws {
        let t = makeTodo("T", note: "t"), s = makeTodo("S, merged into T", note: "s")
        await seedTodosAndPull([t, s])
        let entryOfS = try XCTUnwrap(todoEntry(s.id))
        let info = store.mergeEvents(source: try XCTUnwrap(todos(s.id).first), into: try XCTUnwrap(todos(t.id).first))
        service.undoHold.hold([info.sourceEvent.id], for: EventGridView.mergeUndoWindow)
        XCTAssertTrue(todos(s.id).isEmpty, "fixture: the merge deleted S")

        await merge(coordinator(), .keepCloud)
        XCTAssertTrue(todos(s.id).isEmpty, "the merge restore brought back S, which the undo prompt is holding")
        XCTAssertTrue(service.undoHold.isHeld(s.id.uuidString), "fixture: the window is still open")
        let before = server.requests.count

        // The Undo button (EventGridView).
        service.undoHold.release([info.sourceEvent.id])
        store.undoMerge(info)
        XCTAssertEqual(todos(s.id).count, 1, "Undo did not put S back exactly once")
        XCTAssertEqual(todoEntry(s.id), entryOfS, "S's entry is not the one it had")
        XCTAssertEqual(SupabaseSyncService.rowHash(service.eventToRow(todos(s.id)[0], kind: "todo")), entryOfS.hash,
                       "S came back dirty, so it would be re-sent")

        scheduler.advance(by: debounce)
        try await settle()
        scheduler.advance(by: EventGridView.mergeUndoWindow)
        try await settle()
        try await settle()
        XCTAssertEqual(writes(after: before).filter { names($0, s.id) }.map(\.verb), [], "the undone delete sent something")
        XCTAssertFalse(server.isTombstoned(table: "events", key: s.id.uuidString))
        XCTAssertEqual(todos(s.id).count, 1)
    }

    /// Smart split of O (EventGridView.performSmartSplit: `smartSplitEvent` +
    /// the 6 s hold), a merge restore inside the window, then Undo: O back
    /// once and clean, the children gone, nothing naming O sent.
    func testUndoSplitTappedAfterTheRestore_OComesBackOnceCleanAndNothingIsSent() async throws {
        let o = makeTodo("O, split", note: "o")
        await seedTodosAndPull([o])
        let entryOfO = try XCTUnwrap(todoEntry(o.id))
        let info = try XCTUnwrap(store.smartSplitEvent(try XCTUnwrap(todos(o.id).first),
                                                       subtasks: [(title: "O-1", portion: 0.5), (title: "O-2", portion: 0.5)]))
        service.undoHold.hold([info.originalEvent.id], for: EventGridView.splitUndoWindow)

        await merge(coordinator())
        XCTAssertTrue(todos(o.id).isEmpty, "the merge restore brought back O, which the undo prompt is holding")
        let before = server.requests.count

        service.undoHold.release([info.originalEvent.id])
        store.undoSmartSplit(info)
        XCTAssertEqual(todos(o.id).count, 1, "Undo did not put O back exactly once")
        XCTAssertEqual(todoEntry(o.id), entryOfO)
        XCTAssertTrue(store.events.filter { info.newEventIDs.contains($0.id) }.isEmpty, "fixture: the children are gone")

        scheduler.advance(by: EventGridView.splitUndoWindow)
        try await settle()
        try await settle()
        XCTAssertEqual(writes(after: before).filter { names($0, o.id) }.map(\.verb), [], "the undone split sent something for O")
        XCTAssertFalse(server.isTombstoned(table: "events", key: o.id.uuidString))
    }

    /// The same split, no Undo: the restore keeps O deleted and the window's
    /// end sends its tombstone, once.
    func testSplitWindowEndingAfterTheRestore_OsTombstoneGoesUpOnce() async throws {
        let o = makeTodo("O, split")
        await seedTodosAndPull([o])
        let info = try XCTUnwrap(store.smartSplitEvent(try XCTUnwrap(todos(o.id).first),
                                                       subtasks: [(title: "O-1", portion: 0.5), (title: "O-2", portion: 0.5)]))
        service.undoHold.hold([info.originalEvent.id], for: EventGridView.splitUndoWindow)
        await merge(coordinator(), .keepCloud)
        XCTAssertTrue(todos(o.id).isEmpty, "the merge restore brought back O")
        let before = server.requests.count

        scheduler.advance(by: EventGridView.splitUndoWindow)
        try await syncEventually("O's tombstone went up when the window ended") {
            self.server.isTombstoned(table: "events", key: o.id.uuidString)
        }
        try await settle()
        XCTAssertEqual(writes(after: before).filter { names($0, o.id) }.map(\.verb), [.tombstone])
        XCTAssertTrue(todos(o.id).isEmpty)
    }

    // MARK: - When the delete happens relative to the review

    /// X deleted while the review is up (after `prepareMerge` counted
    /// nothing): the apply reads the device as it is then, so X stays
    /// deleted and its tombstone goes up once.
    func testADeleteMadeDuringTheReviewStaysDeletedAndIsSent() async throws {
        let x = makeEvent("X", note: "v1")
        try await seedAndPull([x])
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])   // makes the merge worth reviewing
        let c = coordinator()
        await c.startFetch()
        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: the merge is reviewed, got \(c.phase)") }
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertNil(local(x.id), "the merge brought back a row deleted during the review")
        XCTAssertNotNil(local(y.id), "positive control: the cloud-only row was added")
        let before = server.requests.count
        scheduler.advance(by: debounce)
        try await syncEventually("X's tombstone went up") { self.server.isTombstoned(table: "events", key: x.id.uuidString) }
        try await settle()
        XCTAssertEqual(writes(after: before).filter { names($0, x.id) }.map(\.verb), [.tombstone])
    }

    /// A delete that lands while the apply's spinner is coming up (the
    /// coordinator's loading-frame wait — e.g. from the watch): the pending
    /// set is read after the wait, so X stays deleted.
    func testADeleteLandingDuringTheLoadingFrameStaysDeleted() async throws {
        let x = makeEvent("X", note: "v1")
        try await seedAndPull([x])
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])
        let store = self.store
        let c = coordinator(waitForLoadingFrame: {
            if let e = store.rawCalendarEvents.first(where: { $0.id == x.id }) { store.deleteCalendarEvent(e, unlinkAssets: false) }
        })
        await merge(c)
        XCTAssertNil(local(x.id), "the merge brought back a row deleted while its spinner came up")
        scheduler.advance(by: debounce)
        try await syncEventually("X's tombstone went up") { self.server.isTombstoned(table: "events", key: x.id.uuidString) }
    }

    /// Same on both: the tombstone is answered while the review is up, so at
    /// the apply X is no longer a pending delete and the stale snapshot puts
    /// it back; the next pull delivers the tombstone and X is gone again,
    /// with nothing more sent for it.
    func testATombstoneAnsweredDuringTheReview_XIsGoneAgainAfterTheNextPull() async throws {
        let x = makeEvent("X", note: "v1")
        try await seedAndPull([x])
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])
        let c = coordinator()
        await c.startFetch()
        await c.prepareMerge()
        guard case .mergeReview = c.phase else { return XCTFail("fixture: the merge is reviewed, got \(c.phase)") }
        scheduler.advance(by: debounce)
        try await syncEventually("the tombstone was answered during the review") {
            self.server.isTombstoned(table: "events", key: x.id.uuidString) && self.entry(x) == nil
        }
        let before = server.requests.count
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        await puller.pullToHead()
        try await settle()
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertNil(local(x.id), "X is back after the pull that carries its tombstone")
        XCTAssertEqual(writes(after: before).filter { names($0, x.id) }.map(\.verb), [], "X was sent again")
        XCTAssertTrue(server.isTombstoned(table: "events", key: x.id.uuidString))
    }

    // MARK: - The cascade

    /// Deleting a calendar event prunes its log and feedback records
    /// (`deleteCalendarEvent`). A keep-cloud merge keeps all three deleted
    /// and the flush tombstones each once.
    func testACalendarEventsCascadedLogAndFeedbackStayDeletedAndAreSent() async throws {
        let e = makeEvent("E, with a log and feedback")
        let day = Calendar.current.startOfDay(for: e.timeRanges[0].start)
        let key = CalendarOccurrenceKey.make(for: e, occurrenceDate: day)
        let log = CalendarEventLogRecord(id: key, eventID: e.id, baseSeriesEventID: nil, occurrenceDate: day,
                                         createdAt: Self.t0, updatedAt: Self.t0)
        let fb = CalendarEventFeedbackRecord(id: key, eventID: e.id, baseSeriesEventID: nil, occurrenceDate: day,
                                             createdAt: Self.t0, updatedAt: Self.t0)
        server.seed(table: "events", rows: [row(e)])
        server.seed(table: "event_logs", rows: [service.logToRow(log)])
        server.seed(table: "event_feedback", rows: [service.feedbackToRow(fb)])
        await puller.pullToHead()
        let wire = service.encodeOccurrenceKey(key)
        XCTAssertEqual(store.calendarEventLogRecords.filter { $0.id == key }.count, 1, "fixture: the log was pulled")
        XCTAssertEqual(store.calendarEventFeedbackRecords.filter { $0.id == key }.count, 1, "fixture: the feedback was pulled")

        store.deleteCalendarEvent(try XCTUnwrap(local(e.id)), unlinkAssets: false)
        XCTAssertTrue(store.calendarEventLogRecords.filter { $0.id == key }.isEmpty, "fixture: the delete pruned the log")
        XCTAssertTrue(store.calendarEventFeedbackRecords.filter { $0.id == key }.isEmpty, "fixture: the delete pruned the feedback")

        await merge(coordinator(), .keepCloud)
        XCTAssertNil(local(e.id), "the merge brought back the deleted event")
        XCTAssertTrue(store.calendarEventLogRecords.filter { $0.id == key }.isEmpty, "the merge brought back its log")
        XCTAssertTrue(store.calendarEventFeedbackRecords.filter { $0.id == key }.isEmpty, "the merge brought back its feedback")
        let before = server.requests.count

        scheduler.advance(by: debounce)
        try await syncEventually("all three tombstones went up") {
            self.server.isTombstoned(table: "events", key: e.id.uuidString)
                && self.server.isTombstoned(table: "event_logs", key: wire)
                && self.server.isTombstoned(table: "event_feedback", key: wire)
        }
        try await settle()
        let w = writes(after: before)
        XCTAssertEqual(w.filter { $0.table == "events" && names($0, e.id) }.map(\.verb), [.tombstone])
        XCTAssertEqual(w.filter { $0.table == "event_logs" && $0.keys.contains(wire) }.map(\.verb), [.tombstone])
        XCTAssertEqual(w.filter { $0.table == "event_feedback" && $0.keys.contains(wire) }.map(\.verb), [.tombstone])
    }

    // MARK: - A pending delete the cloud already deleted

    /// Same on both: a peer tombstoned X before the fetch, so the snapshot
    /// does not carry it. Nothing comes back; the device's tombstone goes up
    /// once, is answered with no row, and settles: no refusal, no resend.
    func testAPendingDeleteThePeerAlreadyTombstonedSettlesQuietly() async throws {
        let x = makeEvent("X")
        try await seedAndPull([x])
        _ = server.tombstoneDirectly(table: "events", key: x.id.uuidString)
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])
        await merge(coordinator())
        XCTAssertNil(local(x.id))
        let before = server.requests.count
        scheduler.advance(by: debounce)
        try await syncEventually("the entry settled") { self.entry(x) == nil }
        try await settle()
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertLessThanOrEqual(writes(after: before).filter { names($0, x.id) }.count, 1, "X's tombstone was resent")
        XCTAssertTrue(DiagnosticTrail.combinedText().components(separatedBy: "sync.push.rejected table=calendar_events id=\(x.id.uuidString)").count == 1,
                      "the tombstone of a row the peer deleted was refused")
    }

    // MARK: - A refused tombstone (characterization)

    /// The server refuses X's tombstone (a 4xx; the engine does not resend a
    /// refused tombstone while the row is still absent). On king a merge
    /// restore brought X back, which also cleared the refusal, so device and
    /// cloud agreed again. With the fix the merge keeps X deleted: the device
    /// shows no X, the cloud keeps it live, and nothing is sent — the review
    /// line's "the deletion still syncs to the cloud" does not hold for this
    /// row. Pinned so a change to it is seen.
    func testCharacterization_aRefusedTombstoneStaysDeletedHereAndIsNotResent() async throws {
        let x = makeEvent("X")
        try await seedAndPull([x])
        server.reject(table: "events", key: x.id.uuidString, status: 400, code: "23514")
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        scheduler.advance(by: debounce)
        try await syncEventually("the tombstone was refused") {
            DiagnosticTrail.combinedText().contains("sync.push.rejected table=calendar_events id=\(x.id.uuidString)")
        }
        try await settle()
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])
        await merge(coordinator())
        XCTAssertNil(local(x.id), "the merge brought back X (king's behaviour)")
        let before = server.requests.count
        scheduler.advance(by: debounce)
        try await settle()
        await puller.pullToHead()
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertEqual(writes(after: before).filter { names($0, x.id) }.count, 0, "a refused tombstone was resent")
        XCTAssertFalse(server.isTombstoned(table: "events", key: x.id.uuidString), "fixture: the cloud keeps X")
        XCTAssertNil(local(x.id), "device and cloud now disagree about X")
    }

    // MARK: - Event types

    /// "Reading" (a) deleted here while the switch is off, and a peer's own
    /// "Reading" (a') made after this device last pulled. The merge sets
    /// the deleted type aside BEFORE the title dedupe, so the peer's type —
    /// a row this device never had — is added; a stays deleted and its
    /// tombstone goes up when the switch comes on.
    func testADeletedTypeBesideAPeersLiveNamesake_thePeersTypeIsAddedAndTheDeletedOneStaysDeleted() async throws {
        let kept = EventTypeTemplate(title: "Kept type", colorHex: "#112233")
        let a = EventTypeTemplate(title: "Reading", colorHex: "#445566")
        server.seed(table: "event_types", rows: [service.eventTypeToRow(kept), service.eventTypeToRow(a)])
        await puller.pullToHead()
        let types = device.types
        XCTAssertTrue(types.templates.contains { $0.id == a.id }, "fixture: a was pulled")
        switchOff()
        let peers = EventTypeTemplate(title: "Reading", colorHex: "#998877")
        server.seed(table: "event_types", rows: [service.eventTypeToRow(peers)])
        types.remove(title: "Reading")
        XCTAssertFalse(types.templates.contains { $0.title == "Reading" }, "fixture: the type is deleted here")

        await merge(coordinator(), .keepCloud)
        XCTAssertEqual(types.templates.filter { $0.title == "Reading" }.map(\.id), [peers.id],
                       "the deleted type came back, or the peer's namesake was dropped with it")
        XCTAssertNotNil(service.baseline.entry(table: "event_types", id: a.id.uuidString), "the deleted type's entry was dropped")

        switchOn()
        try await syncEventually("the deleted type's tombstone went up") {
            self.server.isTombstoned(table: "event_types", key: a.id.uuidString)
        }
        try await settle()
        XCTAssertFalse(server.isTombstoned(table: "event_types", key: peers.id.uuidString), "the peer's type was deleted")
    }

    /// Overwrite is unchanged: the deleted type's cloud copy replaces the
    /// catalog, the namesake made here (never uploaded) is gone, and no
    /// tombstone goes up for the type the cloud still holds.
    func testOverwrite_theDeletedTypeComesBackAndItsNamesakeMadeHereIsDropped() async throws {
        let a = EventTypeTemplate(title: "Reading", colorHex: "#445566")
        server.seed(table: "event_types", rows: [service.eventTypeToRow(a)])
        await puller.pullToHead()
        let types = device.types
        switchOff()
        types.remove(title: "Reading")
        types.add("Reading", colorHex: "#00AA00")
        let namesake = try XCTUnwrap(types.templates.first { $0.title == "Reading" })
        XCTAssertNotEqual(namesake.id, a.id)

        try await restore(.cloudOverwritesLocal)
        XCTAssertEqual(types.templates.filter { $0.title == "Reading" }.map(\.id), [a.id], "the overwrite did not take the cloud's type")
        let before = server.requests.count
        switchOn()
        try await settle()
        scheduler.advance(by: debounce)
        try await settle()
        try await settle()
        XCTAssertFalse(server.isTombstoned(table: "event_types", key: a.id.uuidString), "the overwrite's type was deleted")
        XCTAssertEqual(writes(after: before).filter { $0.table == "event_types" && names($0, namesake.id) }.count, 0,
                       "the dropped namesake was sent")
    }
}
