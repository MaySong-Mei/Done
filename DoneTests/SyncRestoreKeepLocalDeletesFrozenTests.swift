//
//  SyncRestoreKeepLocalDeletesFrozenTests.swift
//  DoneTests
//
//  What a merge restore must NOT keep deleted (fix/restore-keep-local-deletes,
//  from its code review). A pending delete is an id the baseline holds and
//  the local table does not, but other things look the same:
//
//  - a frozen table: its file could not be read, so it is empty in memory
//    while the baseline still names every row. Kept deleted, the restore
//    would unfreeze it as empty and the next flush would tombstone the
//    whole table on the server and on every peer. The merge restores it,
//    as it always did.
//  - a row the merge itself replaced (an event type whose cloud namesake
//    won keep-cloud): not a delete of the user's, so its entry is not kept
//    and nothing deletes it on the server.
//  - a delete the server refused: never re-sent, so keeping it would leave
//    the row stuck; the merge brings it back, which is how it heals.
//
//  Each test carries a real pending delete beside the case, kept and sent,
//  so the flush is seen to run and "nothing was deleted" is not vacuous.
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreKeepLocalDeletesFrozenTests: SyncRestoreKeepLocalDeletesTestCase {

    /// The phone relaunched over the fixture device's files and baseline,
    /// switched on and pulled to head. The fixture device stops pulling
    /// first; nothing advances its scheduler, so it sends nothing.
    private func relaunch(catalog: EventTypeCatalog? = nil) async -> SyncSwitchTestDevice {
        puller.endSession()
        let phone = SyncSwitchTestDevice(server: server, uid: uid, start: Self.t0, switchOnAtAttach: false,
                                         relaunching: device, catalog: catalog)
        phone.defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        phone.puller.beginSession(autoPull: false)
        await phone.puller.pullToHead()
        XCTAssertTrue(phone.service.inboundAtHead, "fixture: the relaunched phone reached head")
        return phone
    }

    private func coordinator(on phone: SyncSwitchTestDevice) -> RestoreCoordinator {
        let c = RestoreCoordinator(waitForLoadingFrame: {})
        c.configure(syncService: phone.service, eventStore: phone.store, eventTypeStore: phone.types,
                    skillStore: phone.skills, preferenceStore: phone.prefs)
        return c
    }

    private func reviewedMerge(on phone: SyncSwitchTestDevice) async throws -> (RestoreCoordinator, MergePreview) {
        let c = coordinator(on: phone)
        await c.startFetch()
        guard case .ready = c.phase else { throw FixtureFailure(description: "the fetch did not finish: \(c.phase)") }
        await c.prepareMerge()
        guard case .mergeReview(_, let preview) = c.phase else {
            throw FixtureFailure(description: "the merge was not reviewed: \(c.phase)")
        }
        return (c, preview)
    }

    /// A list deleted on the device whose tombstone has not gone up: the
    /// real pending delete each test carries beside its case.
    private func seedAndDeleteAList() async throws -> TodoList {
        let list = TodoList(title: "list deleted here", colorName: "green", createdAt: Self.t0)
        server.seed(table: "todo_lists", rows: [service.todoListToRow(list)])
        await puller.pullToHead()
        store.deleteList(try XCTUnwrap(store.todoLists.first { $0.id == list.id }, "fixture: the list was pulled"))
        return list
    }

    private func names(_ request: SyncFakeServer.Request, _ id: UUID, on table: String) -> Bool {
        request.table == table && names(request, id)
    }

    // MARK: - A frozen calendar slot

    /// The calendar file is unreadable at launch, so the calendar slot is
    /// frozen and empty while the baseline names both rows. A merge restores
    /// both rows and the flush that follows deletes neither; the list
    /// deleted here is still kept deleted and sent.
    func testAMergeOverAnUnreadableCalendarRestoresItAndDeletesNothing() async throws {
        let x1 = makeEvent("X1"), x2 = makeEvent("X2")
        server.seed(table: "events", rows: [row(x1), row(x2)])
        let list = try await seedAndDeleteAList()
        XCTAssertNotNil(local(x1.id), "fixture: the calendar was pulled")
        let dir = try EventStorageLocation.isolated(name: device.suite).directoryURL()
        try Data("shredded".utf8).write(to: dir.appendingPathComponent(StorageSlot.calendarEvents.filename))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(StorageSlot.calendarEvents.backupFilename))

        let phone = await relaunch()
        defer { phone.tearDown() }
        XCTAssertTrue(phone.store.isSlotFrozen(.calendarEvents), "fixture: the calendar slot is frozen")
        XCTAssertTrue(phone.store.rawCalendarEvents.isEmpty, "fixture: the frozen slot is empty in memory")
        XCTAssertNotNil(phone.service.baseline.entry(table: "calendar_events", id: x1.id.uuidString),
                        "fixture: the baseline still names the calendar")
        XCTAssertNotNil(phone.service.baseline.entry(table: "todo_lists", id: list.id.uuidString),
                        "fixture: the list's delete is pending")

        let (c, preview) = try await reviewedMerge(on: phone)
        XCTAssertEqual(preview.addsFromCloud.calendarEvents, 2, "the unreadable calendar is not offered back")
        XCTAssertEqual(preview.keptDeleted.calendarEvents, 0, "the unreadable calendar was counted as deleted here")
        XCTAssertEqual(preview.keptDeleted.todoLists, 1, "positive control: the list deleted here is kept deleted")
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }

        XCTAssertEqual(Set(phone.store.rawCalendarEvents.map(\.id)), [x1.id, x2.id], "the merge did not restore the calendar")
        XCTAssertFalse(phone.store.isSlotFrozen(.calendarEvents), "fixture: the restore unfroze the slot")
        XCTAssertFalse(phone.store.todoLists.contains { $0.id == list.id })
        let before = server.requests.count

        phone.scheduler.advance(by: debounce)
        try await syncEventually("positive control: the flush sent the list's delete") {
            self.server.isTombstoned(table: "todo_lists", key: list.id.uuidString)
        }
        try await settle()
        for x in [x1, x2] {
            XCTAssertFalse(server.isTombstoned(table: "events", key: x.id.uuidString), "\(x.title) was deleted on the server")
            XCTAssertEqual(writes(after: before).filter { names($0, x.id, on: "events") }.map(\.verb), [],
                           "\(x.title) was sent although the cloud holds it as it is")
        }
    }

    // MARK: - A frozen event-type catalog

    /// The same with the event-type catalog unreadable: frozen, presenting
    /// none of the user's types, while the baseline names both. The merge
    /// restores them; nothing deletes them.
    func testAMergeOverAnUnreadableEventTypeCatalogRestoresItAndDeletesNothing() async throws {
        let a = EventTypeTemplate(title: "Type A", colorHex: "#112233")
        let b = EventTypeTemplate(title: "Type B", colorHex: "#445566")
        server.seed(table: "event_types", rows: [service.eventTypeToRow(a), service.eventTypeToRow(b)])
        let list = try await seedAndDeleteAList()
        XCTAssertTrue(device.types.templates.contains { $0.id == a.id }, "fixture: the types were pulled")

        let catalogDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SyncRestoreKeepLocalDeletesFrozenTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: catalogDir) }
        XCTAssertTrue(EventTypeCatalog(directory: catalogDir, legacyDefaults: nil).setTemplates([a, b]))
        try Data("shredded".utf8).write(to: catalogDir.appendingPathComponent(EventTypeCatalog.templatesFilename))
        try? FileManager.default.removeItem(at: catalogDir.appendingPathComponent("templates.bak"))
        let frozen = EventTypeCatalog(directory: catalogDir, legacyDefaults: nil)

        let phone = await relaunch(catalog: frozen)
        defer { phone.tearDown() }
        XCTAssertTrue(phone.types.areTemplatesFrozen, "fixture: the catalog is frozen")
        XCTAssertFalse(phone.types.templates.contains { $0.id == a.id || $0.id == b.id },
                       "fixture: the frozen catalog presents none of the user's types")
        XCTAssertNotNil(phone.service.baseline.entry(table: "event_types", id: a.id.uuidString),
                        "fixture: the baseline still names the types")

        let (c, preview) = try await reviewedMerge(on: phone)
        XCTAssertEqual(preview.addsFromCloud.eventTypes, 2, "the unreadable catalog is not offered back")
        XCTAssertEqual(preview.keptDeleted.eventTypes, 0, "the unreadable catalog was counted as deleted here")
        XCTAssertEqual(preview.keptDeleted.todoLists, 1, "positive control: the list deleted here is kept deleted")
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }

        XCTAssertTrue(Set(phone.types.templates.map(\.id)).isSuperset(of: [a.id, b.id]), "the merge did not restore the types")
        XCTAssertFalse(phone.types.areTemplatesFrozen, "fixture: the restore unfroze the catalog")
        let before = server.requests.count

        phone.scheduler.advance(by: debounce)
        try await syncEventually("positive control: the flush sent the list's delete") {
            self.server.isTombstoned(table: "todo_lists", key: list.id.uuidString)
        }
        try await settle()
        for t in [a, b] {
            XCTAssertFalse(server.isTombstoned(table: "event_types", key: t.id.uuidString), "\(t.title) was deleted on the server")
            XCTAssertEqual(writes(after: before).filter { names($0, t.id, on: "event_types") }.map(\.verb), [],
                           "\(t.title) was sent although the cloud holds it as it is")
        }
    }

    // MARK: - A row the merge replaced is not a delete

    /// Local type A and the cloud's namesake C (another device's "Reading",
    /// read first by the fetch): keep cloud puts C in A's place. A was not
    /// deleted by the user, so its entry is not kept and nothing tombstones
    /// it; K, deleted here, is.
    func testKeepCloudReplacingALocalTypeWithItsCloudNamesakeDoesNotDeleteTheReplacedType() async throws {
        let a = EventTypeTemplate(title: "Reading", colorHex: "#111111")
        let k = EventTypeTemplate(title: "Deleted here", colorHex: "#999999")
        server.seed(table: "event_types", rows: [service.eventTypeToRow(a), service.eventTypeToRow(k)])
        await puller.pullToHead()
        XCTAssertTrue(device.types.templates.contains { $0.id == a.id }, "fixture: A was pulled")
        device.types.remove(title: k.title)
        let c = EventTypeTemplate(title: "Reading", colorHex: "#222222")
        server.seed(table: "event_types", rows: [service.eventTypeToRow(c)])
        // A's seq now above C's, so the fetch (in seq order) reads C first
        // and the title dedupe keeps C.
        server.writeDirectly(table: "event_types", key: a.id.uuidString, data: ["color_hex": "#333333"])

        let flow = coordinator()
        await flow.startFetch()
        await flow.prepareMerge()
        guard case .mergeReview = flow.phase else { return XCTFail("fixture: Reading conflicts, got \(flow.phase)") }
        await flow.applyMerge(resolution: .keepCloud)
        guard case .finished = flow.phase else { return XCTFail("the restore did not finish: \(flow.phase)") }
        XCTAssertEqual(device.types.templates.filter { $0.title == "Reading" }.map(\.id), [c.id],
                       "fixture: keep cloud put the cloud's namesake in A's place")
        XCTAssertNil(service.baseline.entry(table: "event_types", id: a.id.uuidString),
                     "the replay kept the entry of a type the merge replaced")
        let before = server.requests.count

        scheduler.advance(by: debounce)
        try await syncEventually("positive control: the flush sent K's delete") {
            self.server.isTombstoned(table: "event_types", key: k.id.uuidString)
        }
        try await settle()
        XCTAssertFalse(server.isTombstoned(table: "event_types", key: a.id.uuidString), "A was deleted on the server")
        XCTAssertEqual(writes(after: before).filter { names($0, a.id, on: "event_types") }.map(\.verb), [])
    }

    // MARK: - A refused delete heals

    /// X's tombstone was refused by the server, so the flush never sends it
    /// again; kept deleted, X would be gone here and live everywhere else
    /// for good. The merge brings X back, clean at the cloud's version, and
    /// nothing is sent for it. Y, deleted here afterwards, is kept deleted
    /// and sent.
    func testAMergeBringsBackARowWhoseDeleteTheServerRefused() async throws {
        let x = makeEvent("X, its delete refused"), y = makeEvent("Y, deleted here")
        server.seed(table: "events", rows: [row(x), row(y)])
        await puller.pullToHead()
        server.reject(table: "events", key: x.id.uuidString, code: "23514")
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        scheduler.advance(by: debounce)
        try await syncEventually("fixture: the server refused X's tombstone") {
            self.service.rejected.refuses(SyncBaselineKey(table: "calendar_events", id: x.id.uuidString),
                                          hash: SyncRejectedSet.deletedHash)
        }
        try await settle()
        XCTAssertFalse(server.isTombstoned(table: "events", key: x.id.uuidString))
        XCTAssertNotNil(entry(x), "fixture: X's delete is still owed")
        server.clearRejection(table: "events", key: x.id.uuidString)
        store.deleteCalendarEvent(try XCTUnwrap(local(y.id)), unlinkAssets: false)

        try await restore(.merge)
        XCTAssertNotNil(local(x.id), "the merge left deleted a row whose delete the server refused")
        XCTAssertEqual(entry(x)?.seq, server.seq(table: "events", key: x.id.uuidString), "X does not read clean at the cloud's version")
        XCTAssertNil(local(y.id), "positive control: Y is kept deleted")
        let before = server.requests.count

        scheduler.advance(by: debounce)
        try await syncEventually("positive control: the flush sent Y's delete") {
            self.server.isTombstoned(table: "events", key: y.id.uuidString)
        }
        try await settle()
        XCTAssertFalse(server.isTombstoned(table: "events", key: x.id.uuidString))
        XCTAssertEqual(writes(after: before).filter { names($0, x.id) }.map(\.verb), [], "X was sent after it came back")
        XCTAssertNotNil(local(x.id))
    }
}
