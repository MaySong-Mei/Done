//
//  SyncRestoreKeepLocalDeletesFrozenQATests.swift
//  DoneTests
//
//  Independent QA for fix/restore-keep-local-deletes @ 1703a124: a merge
//  restore over an unreadable (frozen) slot must restore that table and
//  delete nothing in it. The implementer's SyncRestoreKeepLocalDeletesFrozenTests
//  cover the calendar slot and the event-type catalog; these cover the
//  other synced slots — todos, activity logs, feedback records and todo
//  lists. A frozen slot is empty in memory while the baseline names its
//  rows, so the pending-delete rule (in the baseline, not local) would read
//  it as "everything deleted here": the merge would restore nothing, the
//  restore would unfreeze the slot as empty, and the next flush would
//  tombstone the whole table on the server.
//
//  Each test carries a real pending delete in a readable table beside the
//  frozen one — a calendar event deleted here, whose tombstone has not gone
//  up — kept deleted and sent, so "nothing was deleted" is not vacuous.
//
//  On e4cbac6d (with this branch's test fixture) every test fails: the
//  frozen table is counted as kept deleted and tombstoned on the server.
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreKeepLocalDeletesFrozenQATests: SyncRestoreKeepLocalDeletesTestCase {

    /// One synced slot made unreadable.
    struct FrozenCase {
        let slot: StorageSlot
        /// The baseline / server table and the two wire ids of its rows.
        let table: String
        let server: String
        let ids: [String]
        /// How many rows of the table the device holds in memory.
        let localCount: (SyncSwitchTestDevice) -> Int
        /// The review's adds and kept-deleted counts for the table.
        let adds: (MergePreview) -> Int
        let kept: (MergePreview) -> Int
    }

    /// The phone relaunched over the fixture device's files and baseline,
    /// switched on and pulled to head (the fixture device stops first).
    private func relaunch() async -> SyncSwitchTestDevice {
        puller.endSession()
        let phone = SyncSwitchTestDevice(server: server, uid: uid, start: Self.t0, switchOnAtAttach: false, relaunching: device)
        phone.defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        phone.puller.beginSession(autoPull: false)
        await phone.puller.pullToHead()
        XCTAssertTrue(phone.service.inboundAtHead, "fixture: the relaunched phone reached head")
        return phone
    }

    private func shred(_ slot: StorageSlot) throws {
        let dir = try EventStorageLocation.isolated(name: device.suite).directoryURL()
        try Data("shredded".utf8).write(to: dir.appendingPathComponent(slot.filename))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(slot.backupFilename))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(slot.deltaFilename))
    }

    /// Seeds the frozen table's two rows and the control calendar event Z,
    /// pulls them, deletes Z here (pending), shreds the slot, relaunches,
    /// merges keep-local, and checks the review, the device and the server.
    private func assertAMergeOverAFrozenSlotRestoresItAndDeletesNothing(
        _ seed: () async throws -> FrozenCase, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let frozen = try await seed()
        let z = makeEvent("Z, deleted here")
        server.seed(table: "events", rows: [row(z)])
        await puller.pullToHead()
        XCTAssertEqual(frozen.localCount(device), frozen.ids.count, "fixture: the table was pulled", file: file, line: line)
        store.deleteCalendarEvent(try XCTUnwrap(local(z.id)), unlinkAssets: false)
        try shred(frozen.slot)

        let phone = await relaunch()
        defer { phone.tearDown() }
        XCTAssertTrue(phone.store.isSlotFrozen(frozen.slot), "fixture: \(frozen.slot) is frozen", file: file, line: line)
        XCTAssertEqual(frozen.localCount(phone), 0, "fixture: the frozen slot is empty in memory", file: file, line: line)
        for id in frozen.ids {
            XCTAssertNotNil(phone.service.baseline.entry(table: frozen.table, id: id),
                            "fixture: the baseline still names \(frozen.table) \(id)", file: file, line: line)
        }
        XCTAssertNotNil(phone.service.baseline.entry(table: "calendar_events", id: z.id.uuidString),
                        "fixture: Z's delete is pending", file: file, line: line)
        XCTAssertNil(phone.store.rawCalendarEvents.first { $0.id == z.id }, "fixture: Z is deleted here", file: file, line: line)

        let c = RestoreCoordinator(waitForLoadingFrame: {})
        c.configure(syncService: phone.service, eventStore: phone.store, eventTypeStore: phone.types,
                    skillStore: phone.skills, preferenceStore: phone.prefs)
        await c.startFetch()
        guard case .ready = c.phase else { return XCTFail("the fetch did not finish: \(c.phase)", file: file, line: line) }
        await c.prepareMerge()
        guard case .mergeReview(_, let preview) = c.phase else {
            return XCTFail("the merge was not reviewed: \(c.phase)", file: file, line: line)
        }
        XCTAssertEqual(frozen.adds(preview), frozen.ids.count, "the unreadable \(frozen.table) is not offered back", file: file, line: line)
        XCTAssertEqual(frozen.kept(preview), 0, "the unreadable \(frozen.table) was counted as deleted here", file: file, line: line)
        XCTAssertEqual(preview.keptDeleted.calendarEvents, 1, "positive control: Z is kept deleted", file: file, line: line)
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)", file: file, line: line) }

        XCTAssertEqual(frozen.localCount(phone), frozen.ids.count, "the merge did not restore \(frozen.table)", file: file, line: line)
        XCTAssertFalse(phone.store.isSlotFrozen(frozen.slot), "fixture: the restore unfroze the slot", file: file, line: line)
        XCTAssertNil(phone.store.rawCalendarEvents.first { $0.id == z.id }, "positive control: Z stays deleted", file: file, line: line)
        let before = server.requests.count

        phone.scheduler.advance(by: debounce)
        try await syncEventually("positive control: the flush sent Z's delete") {
            self.server.isTombstoned(table: "events", key: z.id.uuidString)
        }
        try await settle()
        try await settle()
        for id in frozen.ids {
            XCTAssertFalse(server.isTombstoned(table: frozen.server, key: id),
                           "\(frozen.table) \(id) was deleted on the server", file: file, line: line)
            XCTAssertEqual(writes(after: before).filter { $0.table == frozen.server && $0.keys.contains { $0.lowercased() == id.lowercased() } }.map(\.verb),
                           [], "\(frozen.table) \(id) was sent although the cloud holds it as it is", file: file, line: line)
        }
    }

    // MARK: - The four slots

    func testAMergeOverUnreadableTodosRestoresThemAndDeletesNothing() async throws {
        try await assertAMergeOverAFrozenSlotRestoresItAndDeletesNothing {
            let t1 = self.makeTodo("todo 1"), t2 = self.makeTodo("todo 2")
            self.server.seed(table: "events", rows: [self.service.eventToRow(t1, kind: "todo"), self.service.eventToRow(t2, kind: "todo")])
            let ids = [t1.id, t2.id]
            return FrozenCase(slot: .events, table: "events", server: "events", ids: ids.map(\.uuidString),
                              localCount: { d in d.store.events.filter { ids.contains($0.id) }.count },
                              adds: { $0.addsFromCloud.todoEvents }, kept: { $0.keptDeleted.todoEvents })
        }
    }

    func testAMergeOverUnreadableActivityLogsRestoresThemAndDeletesNothing() async throws {
        try await assertAMergeOverAFrozenSlotRestoresItAndDeletesNothing {
            let o1 = self.makeEvent("owner 1"), o2 = self.makeEvent("owner 2")
            let l1 = self.makeLog(for: o1), l2 = self.makeLog(for: o2)
            self.server.seed(table: "events", rows: [self.row(o1), self.row(o2)])
            self.server.seed(table: "event_logs", rows: [self.service.logToRow(l1), self.service.logToRow(l2)])
            let keys = [l1.id, l2.id]
            return FrozenCase(slot: .calendarEventLogRecords, table: "event_logs", server: "event_logs",
                              ids: keys.map { self.service.encodeOccurrenceKey($0) },
                              localCount: { d in d.store.calendarEventLogRecords.filter { keys.contains($0.id) }.count },
                              adds: { $0.addsFromCloud.logs }, kept: { $0.keptDeleted.logs })
        }
    }

    func testAMergeOverUnreadableFeedbackRestoresItAndDeletesNothing() async throws {
        try await assertAMergeOverAFrozenSlotRestoresItAndDeletesNothing {
            let o1 = self.makeEvent("owner 1"), o2 = self.makeEvent("owner 2")
            let f1 = self.makeFeedback(for: o1), f2 = self.makeFeedback(for: o2)
            self.server.seed(table: "events", rows: [self.row(o1), self.row(o2)])
            self.server.seed(table: "event_feedback", rows: [self.service.feedbackToRow(f1), self.service.feedbackToRow(f2)])
            let keys = [f1.id, f2.id]
            return FrozenCase(slot: .calendarEventFeedbackRecords, table: "event_feedback", server: "event_feedback",
                              ids: keys.map { self.service.encodeOccurrenceKey($0) },
                              localCount: { d in d.store.calendarEventFeedbackRecords.filter { keys.contains($0.id) }.count },
                              adds: { $0.addsFromCloud.feedback }, kept: { $0.keptDeleted.feedback })
        }
    }

    func testAMergeOverUnreadableTodoListsRestoresThemAndDeletesNothing() async throws {
        try await assertAMergeOverAFrozenSlotRestoresItAndDeletesNothing {
            let a = TodoList(title: "list A", colorName: "green", createdAt: Self.t0)
            let b = TodoList(title: "list B", colorName: "blue", createdAt: Self.t0)
            self.server.seed(table: "todo_lists", rows: [self.service.todoListToRow(a), self.service.todoListToRow(b)])
            let ids = [a.id, b.id]
            return FrozenCase(slot: .todoLists, table: "todo_lists", server: "todo_lists", ids: ids.map(\.uuidString),
                              localCount: { d in d.store.todoLists.filter { ids.contains($0.id) }.count },
                              adds: { $0.addsFromCloud.todoLists }, kept: { $0.keptDeleted.todoLists })
        }
    }
}
