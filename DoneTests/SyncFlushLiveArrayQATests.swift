//
//  SyncFlushLiveArrayQATests.swift
//  DoneTests
//
//  Independent QA for the flush-reads-the-live-array fix (1200b7e). The
//  implementer's SyncFlushLiveArrayTests apply the gap page BEFORE the
//  flush task starts. These tests attack what that harness cannot see:
//
//  - a page queued on the main actor BEHIND the flush task: it may only
//    land after the flush's diff, never between the live read and the diff
//    (an await injected anywhere on that path lets it in);
//  - the pre-015 fallback (`pushTableFallback`, physical DELETE / merge
//    upsert), with a pull page and with a restore as the gap writer;
//  - a restore landing in the gap on a 015 server;
//  - the undo prompt: Undo tapped in the gap, and a held delete flushed
//    through the sinks (015 and fallback);
//  - the two paths that already read live (`undoHold.onExpire`,
//    `flushPendingTables`): the second table is read after the first
//    table's network await, not before it;
//  - the trail line under typing: one line per flush whose store moved in
//    the gap, never one per keystroke;
//  - the cost of `live != delivered`.
//

import XCTest
@testable import Done

@MainActor
final class SyncFlushLiveArrayQATests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let uid = "22222222-3333-4444-8555-666666666666"

    private var suite = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var scheduler: SyncManualScheduler!
    private var store: EventStore!
    private var types: EventTypeTemplateStore!
    private var skills: SkillInsightStore!
    private var prefs: AgentPreferenceStore!
    private var auth: AuthService!
    private var service: SupabaseSyncService!
    private var puller: SyncPuller!
    private var shelfDirectory: URL!
    private var prefsDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        // The trail is process-wide and rotates at 192 KiB, dropping the
        // older file: the line counts below start from an empty trail.
        DiagnosticTrail.clear()
        suite = "SyncFlushLiveArrayQATests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        server = SyncFakeServer(userId: uid)
        scheduler = SyncManualScheduler(start: Self.t0)
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        prefsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFlushLiveArrayQATests-prefs-\(UUID().uuidString)", isDirectory: true)
        shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFlushLiveArrayQATests-shelf-\(UUID().uuidString)", isDirectory: true)
        prefs = AgentPreferenceStore(directoryURL: prefsDirectory)

        service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: defaults,
                                      scheduler: scheduler, environment: .local)
        service.attachStores(eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)
        puller = service.installInbound(shelf: ConflictShelf(directory: shelfDirectory))
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()

        let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
        let session = #"{"access_token":"at-1","refresh_token":"r-1","user_id":"\#(uid)","email":"qa@example.com","expires_at":\#(expiresAt)}"#
        auth = AuthService(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
                           sessionStore: InMemorySessionStore(),
                           transport: { request in
                               XCTFail("no auth request may go out; got \(request.url?.absoluteString ?? "?")")
                               throw URLError(.notConnectedToInternet)
                           },
                           launchEnvironment: ["SYNC_DEBUG_SESSION": session], syncEnvironment: .local)
        XCTAssertTrue(auth.isSignedIn, "fixture: the injected session signed in")
        defaults.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        service.attach(authService: auth, eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)
        defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        XCTAssertTrue(service.canUpload, "fixture: the sinks may flush")

        puller.beginSession(autoPull: false)
        await puller.pullToHead()
        XCTAssertTrue(service.inboundAtHead, "fixture: the session reached head")
    }

    override func tearDown() async throws {
        server?.holdWhen = nil
        server?.releaseAll()
        puller?.endSession()
        try? FileManager.default.removeItem(at: shelfDirectory)
        try? FileManager.default.removeItem(at: prefsDirectory)
        TestStorage.tearDown(suite)
        DiagnosticTrail.clear()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeEvent(_ title: String, note: String = "") -> Event {
        Event(title: title, note: note,
              timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(1800))],
              createdAt: Self.t0)
    }

    private func makeTodo(_ title: String) -> Event {
        Event(title: title, timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(3600))],
              createdAt: Self.t0, kind: .todo)
    }

    private func makeLog(_ event: Event, note: String) -> CalendarEventLogRecord {
        let key = CalendarOccurrenceKey(eventID: event.id, baseSeriesEventID: nil, occurrenceDate: Self.t0,
                                        kind: .singleEvent, dayKey: 20260528)
        return CalendarEventLogRecord(id: key, eventID: key.eventID, baseSeriesEventID: nil,
                                      occurrenceDate: Self.t0, note: note, createdAt: Self.t0, updatedAt: Self.t0)
    }

    private var debounce: TimeInterval { SupabaseSyncConfig.debounceSeconds }

    private func ids(_ verb: SyncFakeServer.Verb, _ table: String) -> Set<String> {
        Set(server.requests(verb, table: table).flatMap(\.keys).map { $0.lowercased() })
    }

    private func upsertedIds(_ table: String) -> Set<String> {
        let bodies = server.requests(.upsert, table: table).compactMap { $0.body as? [[String: Any]] }
        return Set(bodies.flatMap { $0 }.compactMap { ($0["id"] as? String)?.lowercased() })
    }

    private func liveLines(_ table: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init)
            .filter { $0.contains("sync.flush.live table=\(table) ") }
    }

    private func seq(_ table: String, _ id: String) -> Int64? {
        service.baseline.entry(table: table, id: id)?.seq
    }

    private func applyContext() -> SyncApplyContext {
        var context = SyncApplyContext(engine: service, shelf: puller.shelf,
                                       eraseToken: LocalDataEraseEpoch.capture(), pullIssue: puller.pullIssue)
        context.eventTypeStore = types
        context.skillStore = skills
        return context
    }

    /// The other device's write, fetched the way the puller fetches it.
    private func fetchPage() async throws -> [SyncFeedRow] {
        let page = try await server.pullChanges(sinceSeq: service.cursor.value ?? 0, pageLimit: puller.pageLimit)
        XCTAssertFalse(page.isEmpty, "fixture: the other device's write is in the feed")
        return page
    }

    private func apply(_ page: [SyncFeedRow]) {
        let outcome = store.applyRemote(RemotePage(rows: page), context: applyContext())
        XCTAssertTrue(outcome.countsAsApplied, "fixture: the page applied")
    }

    /// Pushes `rows` through the real sinks and waits for each id's seq.
    private func flushCalendar(_ events: [Event]) async throws {
        for e in events { store.addCalendarEvent(e) }
        scheduler.advance(by: debounce)
        try await syncEventually("calendar rows pushed") {
            events.allSatisfy { self.service.baseline.entry(table: "calendar_events", id: $0.id.uuidString) != nil }
        }
    }

    private func flushTodos(_ events: [Event]) async throws {
        for e in events { store.add(e) }
        scheduler.advance(by: debounce)
        try await syncEventually("todos pushed") {
            events.allSatisfy { self.seq("events", $0.id.uuidString) != nil }
        }
    }

    /// Lets the in-process flush tasks run to their end: every gateway call
    /// on the fake server is a main-actor call, so a handful of turns is the
    /// whole flush. Used only AFTER a positive witness said the flush ran.
    private func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - 1. Same turn: a page queued behind the flush task lands after the diff

    /// The fix holds only if nothing suspends between `liveForFlush`'s read
    /// and `pushTable`'s `previous`/`current`/`deletedIds`. Here the flush
    /// task is queued first and the page's main-actor job right behind it,
    /// which is the order a doorbell-driven pull continuation can take. With
    /// no suspension the flush diffs before the page exists: the remote row
    /// is neither tombstoned nor read as moved (no trail line). An `await`
    /// anywhere on that path lets the page in between the read and the diff,
    /// and the delivered-free live array then tombstones the page's row.
    func testQA1_APageQueuedBehindTheFlushTaskLandsAfterItsDiffNeverBetweenReadAndDiff() async throws {
        let mine = makeEvent("mine"), theirs = makeEvent("theirs")
        store.addCalendarEvent(mine)
        server.writeDirectly(table: "events", key: theirs.id.uuidString,
                             data: service.eventToRow(theirs, kind: "calendar"))
        let page = try await fetchPage()
        let linesBefore = liveLines("calendar_events").count

        scheduler.advance(by: debounce)          // the sink delivers; the flush task is queued
        var appliedAfterFlushStarted = false
        let pageJob = Task { @MainActor in       // queued behind the flush task
            appliedAfterFlushStarted = self.ids(.insert, "events").contains(mine.id.uuidString.lowercased())
                || self.service.baseline.entry(table: "calendar_events", id: mine.id.uuidString) != nil
            self.apply(page)
        }
        await pageJob.value
        try await syncEventually("mine pushed") { self.seq("calendar_events", mine.id.uuidString) != nil }
        try await settle()

        XCTAssertTrue(appliedAfterFlushStarted,
                      "fixture: the page job ran after the flush had built its request (FIFO on the main actor)")
        XCTAssertFalse(ids(.tombstone, "events").contains(theirs.id.uuidString.lowercased()),
                       "a page that landed between the flush's live read and its diff was tombstoned")
        XCTAssertFalse(server.isTombstoned(table: "events", key: theirs.id.uuidString))
        XCTAssertNotNil(service.baseline.entry(table: "calendar_events", id: theirs.id.uuidString))
        XCTAssertEqual(liveLines("calendar_events").count, linesBefore,
                       "the flush read the store before the page landed, so live == delivered")

        // The page published the store, which armed the debounce again: that
        // flush reads the page's row as clean and sends nothing for it.
        let writesForTheirs = { [self] in
            [SyncFakeServer.Verb.tombstone, .patch, .insert].reduce(0) {
                $0 + server.requests($1, table: "events").filter { $0.keys.map { $0.lowercased() }.contains(theirs.id.uuidString.lowercased()) }.count
            }
        }
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertEqual(writesForTheirs(), 0, "the follow-up flush wrote the remote row back")
        XCTAssertFalse(server.isTombstoned(table: "events", key: theirs.id.uuidString))
    }

    // MARK: - 2. The pre-015 fallback: physical DELETE and merge upsert

    func testQA2_FallbackPushDoesNotPhysicallyDeleteARowAPageLandedInTheGap() async throws {
        service.outboundFallback = true
        let mine = makeEvent("mine"), theirs = makeEvent("theirs")
        store.addCalendarEvent(mine)
        server.writeDirectly(table: "events", key: theirs.id.uuidString,
                             data: service.eventToRow(theirs, kind: "calendar"))
        let page = try await fetchPage()
        let linesBefore = liveLines("calendar_events").count

        scheduler.advance(by: debounce)
        apply(page)
        XCTAssertTrue(server.requests(.upsert).isEmpty && server.requests(.delete).isEmpty,
                      "fixture: the flush task had not run when the page landed")
        try await syncEventually("mine upserted through the fallback") {
            self.upsertedIds("events").contains(mine.id.uuidString.lowercased())
        }
        try await settle()

        XCTAssertFalse(ids(.delete, "events").contains(theirs.id.uuidString.lowercased()),
                       "the fallback flush physically DELETEd the other device's new row")
        XCTAssertNotNil(server.row(table: "events", key: theirs.id.uuidString),
                        "the other device's row is gone from the server")
        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == theirs.id })
        XCTAssertEqual(liveLines("calendar_events").count, linesBefore + 1)
    }

    func testQA2b_FallbackPushDoesNotUpsertTheOldValueOverARemoteEditInTheGap() async throws {
        service.outboundFallback = true
        let shared = makeEvent("shared", note: "before")
        store.addCalendarEvent(shared)
        scheduler.advance(by: debounce)
        try await syncEventually("shared upserted") { self.upsertedIds("events").contains(shared.id.uuidString.lowercased()) }
        try await settle()
        let upsertsBefore = server.requests(.upsert, table: "events").count

        let mine = makeEvent("mine")
        store.addCalendarEvent(mine)
        server.writeDirectly(table: "events", key: shared.id.uuidString, data: ["note": "theirs"])
        let page = try await fetchPage()
        scheduler.advance(by: debounce)
        apply(page)
        XCTAssertEqual(store.rawCalendarEvents.first { $0.id == shared.id }?.note, "theirs", "fixture: the pull adopted the edit")
        try await syncEventually("mine upserted") { self.upsertedIds("events").contains(mine.id.uuidString.lowercased()) }
        try await settle()

        let laterBodies = server.requests(.upsert, table: "events").dropFirst(upsertsBefore)
            .compactMap { $0.body as? [[String: Any]] }.flatMap { $0 }
        XCTAssertFalse(laterBodies.contains { ($0["id"] as? String)?.lowercased() == shared.id.uuidString.lowercased() },
                       "the fallback flush upserted the row the pull had just changed")
        XCTAssertEqual(server.row(table: "events", key: shared.id.uuidString)?.data["note"] as? String, "theirs",
                       "the other device's edit was overwritten with the old value")
    }

    /// The realistic pre-015 gap writer: no feed, so no pull — but "restore
    /// from cloud" writes the store and the baseline in one main-actor tick
    /// (`RestoreCoordinator.applyInternal`), with a debounce still pending.
    func testQA2c_PreMigrationServerARestoreInTheGapIsNotPhysicallyDeleted() async throws {
        server.pre015 = true
        await puller.pullToHead()
        XCTAssertTrue(service.outboundFallback, "fixture: the feed is gone, the engine took the fallback")
        XCTAssertTrue(service.inboundAtHead, "fixture: the fallback opens the flush gate")

        let theirs = makeEvent("theirs")
        server.writeDirectly(table: "events", key: theirs.id.uuidString,
                             data: Self.without015(service.eventToRow(theirs, kind: "calendar")))
        let mine = makeEvent("mine")
        store.addCalendarEvent(mine)
        let snapshot = try await service.fetchRestoreSnapshot()
        XCTAssertTrue(snapshot.calendarEvents.contains { $0.id == theirs.id }, "fixture: the cloud carries their row")
        let linesBefore = liveLines("calendar_events").count

        scheduler.advance(by: debounce)
        _ = store.applyRestore(snapshot, strategy: .merge, resolution: .keepLocal)
        service.markRestoreCompleted(eventStore: store, eventTypeStore: types, skillStore: skills, snapshot: snapshot)
        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == theirs.id }, "fixture: the restore added their row")
        XCTAssertNotNil(service.baseline.entry(table: "calendar_events", id: theirs.id.uuidString),
                        "fixture: the restore wrote their row's baseline")

        try await syncEventually("the flush ran") {
            self.liveLines("calendar_events").count > linesBefore || !self.server.requests(.delete).isEmpty
        }
        try await settle()
        XCTAssertFalse(ids(.delete, "events").contains(theirs.id.uuidString.lowercased()),
                       "the flush physically DELETEd the row the restore just brought back")
        XCTAssertNotNil(server.row(table: "events", key: theirs.id.uuidString))
    }

    private static func without015(_ row: [String: Any]) -> [String: Any] {
        row.filter { !SyncFakeServer.only015Columns.contains($0.key) }
    }

    // MARK: - 3. A restore in the gap on a 015 server

    func testQA3_ARestoreInTheGapIsNotTombstoned() async throws {
        let theirs = makeEvent("theirs")
        server.writeDirectly(table: "events", key: theirs.id.uuidString,
                             data: service.eventToRow(theirs, kind: "calendar"))
        let mine = makeEvent("mine")
        store.addCalendarEvent(mine)
        let snapshot = try await service.fetchRestoreSnapshot()
        let linesBefore = liveLines("calendar_events").count

        scheduler.advance(by: debounce)
        _ = store.applyRestore(snapshot, strategy: .merge, resolution: .keepLocal)
        service.markRestoreCompleted(eventStore: store, eventTypeStore: types, skillStore: skills, snapshot: snapshot)
        XCTAssertNotNil(seq("calendar_events", theirs.id.uuidString), "fixture: the restore wrote their row at its cloud seq")

        try await syncEventually("the flush ran") {
            self.liveLines("calendar_events").count > linesBefore || !self.server.requests(.tombstone).isEmpty
        }
        try await settle()
        XCTAssertFalse(ids(.tombstone, "events").contains(theirs.id.uuidString.lowercased()),
                       "the flush tombstoned the row the restore just brought back")
        XCTAssertFalse(server.isTombstoned(table: "events", key: theirs.id.uuidString))
    }

    // MARK: - 4. Undo

    /// Undo tapped between the debounce delivering and the flush task: the
    /// hold is released and the row is back in the store before the flush
    /// reads it. The delivered array (from before the Undo) lacks the row
    /// and the hold no longer protects it.
    func testQA4_UndoTappedInTheGapLeavesTheRowAliveOnTheServer() async throws {
        let target = makeTodo("target"), source = makeTodo("source")
        try await flushTodos([target, source])
        let linesBefore = liveLines("events").count

        let info = store.mergeEvents(source: source, into: target)
        service.undoHold.hold([source.id], for: EventGridView.mergeUndoWindow)
        scheduler.advance(by: debounce)          // flush task queued with the merged array
        service.undoHold.release([source.id])    // the Undo button, in its order
        store.undoMerge(info)

        try await syncEventually("the flush ran") {
            self.liveLines("events").count > linesBefore || !self.server.requests(.tombstone).isEmpty
        }
        try await settle()
        XCTAssertFalse(ids(.tombstone, "events").contains(source.id.uuidString.lowercased()),
                       "the flush tombstoned the row the user had just brought back with Undo")
        XCTAssertFalse(server.isTombstoned(table: "events", key: source.id.uuidString))
        XCTAssertNotNil(service.baseline.entry(table: "events", id: source.id.uuidString))
    }

    /// The hold still does its job when the flush reads live: the merged-away
    /// row is not tombstoned while the prompt is up, and is once it expires.
    func testQA5_AHeldDeleteThroughTheSinksIsSentOnlyWhenTheWindowEnds() async throws {
        let target = makeTodo("target"), source = makeTodo("source")
        try await flushTodos([target, source])
        let patchesBefore = server.requests(.patch, table: "events").count

        _ = store.mergeEvents(source: source, into: target)
        service.undoHold.hold([source.id], for: EventGridView.mergeUndoWindow)
        scheduler.advance(by: debounce)
        try await syncEventually("the merged target PATCHed") {
            self.server.requests(.patch, table: "events").count > patchesBefore
        }
        try await settle()
        XCTAssertFalse(ids(.tombstone, "events").contains(source.id.uuidString.lowercased()),
                       "a held delete was tombstoned inside its undo window")
        XCTAssertNotNil(service.baseline.entry(table: "events", id: source.id.uuidString), "the held row keeps its baseline")

        scheduler.advance(by: EventGridView.mergeUndoWindow - debounce)   // the window ends
        try await syncEventually("the tombstone sent on expiry") {
            self.server.isTombstoned(table: "events", key: source.id.uuidString)
        }
    }

    func testQA5b_FallbackAHeldDeleteIsNotPhysicallyDeletedInsideTheWindow() async throws {
        service.outboundFallback = true
        let target = makeTodo("target"), source = makeTodo("source")
        for e in [target, source] { store.add(e) }
        scheduler.advance(by: debounce)
        try await syncEventually("todos upserted") {
            [target, source].allSatisfy { self.upsertedIds("events").contains($0.id.uuidString.lowercased()) }
        }
        try await settle()
        let upsertsBefore = server.requests(.upsert, table: "events").count

        _ = store.mergeEvents(source: source, into: target)
        service.undoHold.hold([source.id], for: EventGridView.mergeUndoWindow)
        scheduler.advance(by: debounce)
        try await syncEventually("the merged target upserted") {
            self.server.requests(.upsert, table: "events").count > upsertsBefore
        }
        try await settle()
        XCTAssertFalse(ids(.delete, "events").contains(source.id.uuidString.lowercased()),
                       "a held delete was physically DELETEd inside its undo window")
        XCTAssertNotNil(server.row(table: "events", key: source.id.uuidString))

        scheduler.advance(by: EventGridView.mergeUndoWindow - debounce)
        try await syncEventually("the DELETE sent on expiry") {
            self.ids(.delete, "events").contains(source.id.uuidString.lowercased())
        }
    }

    // MARK: - 5. The paths that already read live, across their own awaits

    /// `undoHold.onExpire` flushes the todos, awaits the network, then
    /// flushes the calendar. The calendar array must be read after that
    /// await: a page and a local edit that land while the todo tombstone is
    /// in flight are in it.
    func testQA6_OnExpireReadsTheCalendarArrayAfterTheTodoFlushesNetworkAwait() async throws {
        let target = makeTodo("target"), source = makeTodo("source")
        try await flushTodos([target, source])
        _ = store.mergeEvents(source: source, into: target)
        service.undoHold.hold([source.id], for: EventGridView.mergeUndoWindow)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertFalse(server.isTombstoned(table: "events", key: source.id.uuidString), "fixture: still held")

        server.holdWhen = { verb, table in verb == .tombstone && table == "events" }
        scheduler.advance(by: EventGridView.mergeUndoWindow - debounce)     // onExpire: todo flush parks
        try await syncEventually("the todo tombstone is in flight") { self.server.heldCount == 1 }

        let theirs = makeEvent("theirs"), mine = makeEvent("mine")
        server.writeDirectly(table: "events", key: theirs.id.uuidString,
                             data: service.eventToRow(theirs, kind: "calendar"))
        apply(try await fetchPage())
        store.addCalendarEvent(mine)              // the debounce this arms is never advanced
        server.holdWhen = nil
        server.releaseAll()

        try await syncEventually("onExpire's calendar flush pushed the row added during the todo await") {
            self.seq("calendar_events", mine.id.uuidString) != nil
        }
        try await settle()
        XCTAssertTrue(server.isTombstoned(table: "events", key: source.id.uuidString))
        XCTAssertFalse(server.isTombstoned(table: "events", key: theirs.id.uuidString),
                       "onExpire's calendar flush pushed an array read before the todo flush's await")
    }

    /// `flushPendingTables` walks the flagged tables in order; each table's
    /// array is read when its turn comes, after the previous table's sends.
    func testQA7_FlushPendingTablesReadsEachTableWhenItsTurnComes() async throws {
        let cal = makeEvent("calendar-local")
        store.addCalendarEvent(cal)               // the debounce this arms is never advanced
        var parked = 0
        server.holdWhen = { verb, table in
            guard verb == .insert, table == "events", parked == 0 else { return false }
            parked += 1
            return true
        }
        service.markNeedsFlush("calendar_events")
        service.markNeedsFlush("events")
        let flush = Task { await self.service.flushPendingTables() }
        try await syncEventually("the calendar insert is in flight") { self.server.heldCount == 1 }

        let theirs = makeTodo("theirs"), mine = makeTodo("mine-local")
        server.writeDirectly(table: "events", key: theirs.id.uuidString,
                             data: service.eventToRow(theirs, kind: "todo"))
        apply(try await fetchPage())
        store.add(mine)
        server.releaseAll()
        await flush.value

        XCTAssertNotNil(seq("calendar_events", cal.id.uuidString))
        XCTAssertNotNil(seq("events", mine.id.uuidString),
                        "the todo flush pushed an array read before the calendar flush's await")
        XCTAssertFalse(server.isTombstoned(table: "events", key: theirs.id.uuidString),
                       "the todo flush tombstoned a row a page delivered during the calendar flush's await")
    }

    // MARK: - 6. The trail line under typing

    /// Typing a note (`upsertSeededLogRecord` writes the in-memory record on
    /// every keystroke; only the disk write is coalesced) re-arms the 2 s
    /// debounce on every key. Normal typing — bursts and pauses — never has a
    /// keystroke in the gap and writes no line. The worst case, a keystroke
    /// in every gap, writes one line per flush, never one per keystroke.
    func testQA8_TheTrailLineIsOnePerMovedFlushNeverOnePerKeystroke() async throws {
        let event = makeEvent("journal")
        store.addCalendarEvent(event)
        store.calendarEventLogRecords.append(makeLog(event, note: ""))
        let logId = service.encodeOccurrenceKey(store.calendarEventLogRecords[0].id)
        scheduler.advance(by: debounce)
        try await syncEventually("the log pushed") { self.seq("event_logs", logId) != nil }
        try await settle()

        var keystrokes = 0
        func type(_ n: Int, gap: TimeInterval = 0.15) {
            for _ in 0..<n {
                keystrokes += 1
                store.calendarEventLogRecords[0].note += "x"
                scheduler.advance(by: gap)
            }
        }
        func patches() -> Int { server.requests(.patch, table: "event_logs").count }
        let linesAtStart = liveLines("event_logs").count

        // Realistic: three bursts of 20 keys at ~7 keys/s, a 3 s pause after each.
        for burst in 1...3 {
            let before = patches()
            type(20)
            XCTAssertEqual(patches(), before, "no flush while the keys keep coming")
            scheduler.advance(by: 3)
            try await syncEventually("burst \(burst) flushed") { patches() == before + 1 }
            try await settle()
        }
        XCTAssertEqual(liveLines("event_logs").count, linesAtStart,
                       "\(keystrokes) keystrokes with nothing in the gap wrote a trail line")

        // Adversarial: a keystroke lands in each of five gaps.
        let gapFlushes = 5
        for round in 1...gapFlushes {
            let before = patches()
            type(10)
            scheduler.advance(by: debounce)          // the sink delivers; the flush task is queued
            keystrokes += 1
            store.calendarEventLogRecords[0].note += "y"   // in the gap
            try await syncEventually("gap round \(round) flushed") { patches() == before + 1 }
            try await settle()
        }
        scheduler.advance(by: debounce)              // the last gap keystroke's own flush
        try await settle()
        XCTAssertEqual(liveLines("event_logs").count, linesAtStart + gapFlushes,
                       "one line per flush whose store moved in the gap (\(keystrokes) keystrokes typed)")
        XCTAssertEqual(server.row(table: "event_logs", key: logId)?.data["note"] as? String,
                       store.calendarEventLogRecords[0].note, "the server holds every keystroke")
    }

    // MARK: - 7. What `live != delivered` costs

    nonisolated private struct Counted: Equatable {
        nonisolated(unsafe) static var comparisons = 0
        let value: Int
        static func == (lhs: Counted, rhs: Counted) -> Bool {
            comparisons += 1
            return lhs.value == rhs.value
        }
    }

    /// The fast path the fix leans on, counted rather than timed: an array
    /// compared with a copy that shares its buffer compares no elements; an
    /// equal array in another buffer compares every one.
    func testQA9_ArrayEqualityTakesTheBufferIdentityFastPath() {
        let delivered = (0..<5_200).map(Counted.init(value:))
        let live = delivered                                  // what the store still holds
        Counted.comparisons = 0
        XCTAssertFalse(live != delivered)
        XCTAssertEqual(Counted.comparisons, 0, "a shared buffer must not be compared element by element")

        let rebuilt = delivered.map { $0 }                    // equal content, another buffer
        Counted.comparisons = 0
        XCTAssertFalse(rebuilt != delivered)
        XCTAssertEqual(Counted.comparisons, 5_200)

        var appended = delivered
        appended.append(Counted(value: -1))                   // a page's new row: counts differ
        Counted.comparisons = 0
        XCTAssertTrue(appended != delivered)
        XCTAssertEqual(Counted.comparisons, 0, "a count difference must short-circuit")
    }

    /// Timings for a realistic calendar: 5,200 events with notes, tags and a
    /// range. Printed, not asserted (CPU load moves them); the report quotes
    /// them.
    func testQA10_LiveComparisonCostOnA5200EventCalendar() {
        var events: [Event] = []
        events.reserveCapacity(5_200)
        for i in 0..<5_200 {
            let start = Self.t0.addingTimeInterval(Double(i) * 3600)
            var e = Event(title: "Event \(i) — 写代码 review", note: String(repeating: "note \(i) ", count: 8),
                          timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))], createdAt: start)
            e.tags = ["work", "focus-\(i % 7)"]
            e.type = i % 3 == 0 ? "Work" : "Study"
            events.append(e)
        }
        let delivered = events
        let sameBuffer = delivered
        let otherBuffer = delivered.map { $0 }
        var differAtEnd = delivered.map { $0 }
        differAtEnd[differAtEnd.count - 1].note += "!"

        func ms(_ iterations: Int, _ body: () -> Bool) -> (Double, Bool) {
            var last = false
            let clock = ContinuousClock()
            let elapsed = clock.measure { for _ in 0..<iterations { last = body() } }
            let total = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            return (total / Double(iterations), last)
        }
        let identity = ms(1_000) { sameBuffer != delivered }
        let equalCopy = ms(20) { otherBuffer != delivered }
        let endDiff = ms(20) { differAtEnd != delivered }
        // For scale: what every calendar flush already does on the main
        // actor with the same array — build each row and hash it.
        let buildAndHash = ms(3) {
            delivered.map { SupabaseSyncService.rowHash(self.service.eventToRow($0, kind: "calendar")) }.count == 5_200
        }
        XCTAssertFalse(identity.1)
        XCTAssertFalse(equalCopy.1)
        XCTAssertTrue(endDiff.1)
        XCTAssertTrue(buildAndHash.1)
        let line = String(format: "QA-BENCH live!=delivered n=5200 identity=%.6fms equal_other_buffer=%.3fms differ_at_end=%.3fms flush_build_and_hash=%.3fms",
                          identity.0, equalCopy.0, endDiff.0, buildAndHash.0)
        print(line)
        XCTContext.runActivity(named: line) { _ in }
    }

    // MARK: - 8. A remote delete in the gap

    /// The other device deletes a row this device holds; the pull applies
    /// the tombstone (store and baseline) between the debounce delivering
    /// and the flush task. The delivered array still carries the row, the
    /// live one does not. Nothing may be written for it: a flush that
    /// pushed it again would POST a row the cloud has just buried.
    func testQA13_ARemoteDeleteAppliedInTheGapIsNotWrittenBack() async throws {
        let doomed = makeEvent("doomed-elsewhere")
        try await flushCalendar([doomed])
        server.tombstoneDirectly(table: "events", key: doomed.id.uuidString)
        let page = try await fetchPage()
        let mine = makeEvent("mine")
        store.addCalendarEvent(mine)
        let requestsBefore = server.requests.count

        scheduler.advance(by: debounce)          // flush task queued with [doomed, mine]
        apply(page)
        XCTAssertFalse(store.rawCalendarEvents.contains { $0.id == doomed.id }, "fixture: the pull removed the row")
        XCTAssertEqual(server.requests.count, requestsBefore, "fixture: the flush task had not run when the page landed")
        try await syncEventually("mine pushed") { self.seq("calendar_events", mine.id.uuidString) != nil }
        try await settle()

        let laterWrites = server.requests.dropFirst(requestsBefore)
            .filter { [.patch, .insert, .tombstone, .upsert, .delete].contains($0.verb) }
        XCTAssertFalse(laterWrites.contains { $0.keys.map { $0.lowercased() }.contains(doomed.id.uuidString.lowercased()) },
                       "the flush wrote the remotely deleted row back: \(laterWrites.map { "\($0.verb) \($0.keys)" })")
        XCTAssertTrue(server.isTombstoned(table: "events", key: doomed.id.uuidString))
        XCTAssertFalse(store.rawCalendarEvents.contains { $0.id == doomed.id })
        XCTAssertEqual(liveLines("calendar_events"), liveLines("calendar_events").filter { $0.hasSuffix("delivered=2 live=1") })
        XCTAssertEqual(liveLines("calendar_events").count, 1, "the flush found the row gone from the store")
    }

    /// The pre-015 shape of the same thing, and where re-sending is worst:
    /// another device physically deleted a row, the user chose "cloud
    /// overwrites local", and the restore dropped it (and the pending local
    /// row) in the gap. The fallback's merge upsert of a row the baseline
    /// no longer holds re-creates it in the cloud.
    func testQA14_PreMigrationAnOverwriteRestoreInTheGapDoesNotResurrectWhatItDropped() async throws {
        server.pre015 = true
        await puller.pullToHead()
        XCTAssertTrue(service.outboundFallback, "fixture: the engine took the fallback")
        let kept = makeEvent("kept"), gone = makeEvent("deleted-elsewhere")
        store.addCalendarEvent(kept)
        store.addCalendarEvent(gone)
        scheduler.advance(by: debounce)
        try await syncEventually("both upserted") {
            [kept, gone].allSatisfy { self.server.row(table: "events", key: $0.id.uuidString) != nil }
        }
        try await settle()
        XCTAssertTrue(server.physicallyDelete(table: "events", key: gone.id.uuidString), "fixture: the other device's delete")

        let mine = makeEvent("mine-pending")
        store.addCalendarEvent(mine)
        let snapshot = try await service.fetchRestoreSnapshot()
        XCTAssertFalse(snapshot.calendarEvents.contains { $0.id == gone.id }, "fixture: the cloud no longer has it")
        let requestsBefore = server.requests.count

        scheduler.advance(by: debounce)          // flush task queued with [kept, gone, mine]
        _ = store.applyRestore(snapshot, strategy: .cloudOverwritesLocal, resolution: .keepLocal)
        service.markRestoreCompleted(eventStore: store, eventTypeStore: types, skillStore: skills, snapshot: snapshot)
        XCTAssertEqual(store.rawCalendarEvents.map(\.id), [kept.id], "fixture: the overwrite left only the cloud's row")

        try await syncEventually("the flush ran") {
            !self.liveLines("calendar_events").isEmpty || self.server.requests.count > requestsBefore
        }
        try await settle()
        let laterWrites = server.requests.dropFirst(requestsBefore)
            .filter { [.patch, .insert, .tombstone, .upsert, .delete].contains($0.verb) }
        XCTAssertNil(server.row(table: "events", key: gone.id.uuidString),
                     "the flush re-created in the cloud a row another device deleted and the restore dropped")
        XCTAssertNil(server.row(table: "events", key: mine.id.uuidString),
                     "the flush uploaded a row the user chose to overwrite")
        // `kept` may go out once more with the same content: on a pre-015
        // server the fallback hashes the row with the 015 columns withheld,
        // and the restore's baseline replay hashes the full row (pre-existing,
        // harmless). Nothing may name the two rows the restore dropped.
        let dropped = Set([gone.id, mine.id].map { $0.uuidString.lowercased() })
        XCTAssertFalse(laterWrites.contains { !dropped.isDisjoint(with: $0.keys.map { $0.lowercased() }) },
                       "\(laterWrites.map { "\($0.verb) \($0.keys)" })")
        XCTAssertEqual(liveLines("calendar_events").last.map { $0.hasSuffix("delivered=3 live=1") }, true,
                       liveLines("calendar_events").last ?? "no line")
    }

    // MARK: - 9. Observed while building QA2c/QA3 (pre-existing, not this fix)

    /// A merge restore writes every LOCAL row into the baseline: a row the
    /// cloud did not carry gets the hash of the local row (`replayBaseline`,
    /// "keeps the legacy shape"). A row that never reached the cloud — made
    /// while the master switch was off, or still in its debounce — then
    /// reads clean, and no later flush sends it until it is edited.
    func testQA12_PreExisting_ALocalOnlyRowAtAMergeRestoreStillReachesTheCloud() async throws {
        // Strict: this test turns red the day the restore stops marking
        // never-uploaded rows clean — then delete this line. Without it the
        // last assertion fails (on 3111ef1 and on the fix alike).
        XCTExpectFailure("pre-existing (restore baseline replay), not the live-array fix", strict: true)
        defaults.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)   // made while uploads were off
        let offline = makeEvent("made-offline")
        store.addCalendarEvent(offline)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertNil(server.row(table: "events", key: offline.id.uuidString), "fixture: never uploaded")

        let snapshot = try await service.fetchRestoreSnapshot()
        _ = store.applyRestore(snapshot, strategy: .merge, resolution: .keepLocal)
        service.markRestoreCompleted(eventStore: store, eventTypeStore: types, skillStore: skills, snapshot: snapshot)
        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == offline.id }, "fixture: the merge kept the local row")

        defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        service.markNeedsFlush("calendar_events")                         // the flush a chain at head owes
        await service.flushPendingTables()
        try await settle()
        XCTAssertNotNil(server.row(table: "events", key: offline.id.uuidString),
                        "a row that was only ever local reads clean after a merge restore and is never uploaded")
    }
}


// MARK: - The real eraser in the gap

/// `LocalDataEraser.resetAllLocalData`, the real one, landing between the
/// debounce delivering and the flush task. The eraser writes the master
/// switch and its sweep into `UserDefaults.standard`, and in the app the
/// engine reads the same object, so here the engine is built on `.standard`
/// too (the stores keep their own suite). The app domain is saved before
/// each test and put back after it.
///
/// The live read is what makes this matter: a flush task queued before the
/// erase and run after it reads EMPTY stores, where the delivered array
/// carried every row. Two things refuse it: the switch the eraser turns off
/// first, read by `flushGate` at flush time (09d9fa4), and — for
/// `keepingSession: false` only — the sign-out that ends the session in
/// the same turn. `keepingSession: true` (the body `switchToCurrentAccount`
/// runs) has no sign-out, so there the switch is all that holds.
@MainActor
final class SyncFlushRealEraserQATests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let uid = "33333333-4444-4555-8666-777777777777"
    private let bundleID = Bundle.main.bundleIdentifier ?? "wordless.shiqiliuyifanmei.app"

    private var savedStandard: [String: Any]?
    private var suite = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var scheduler: SyncManualScheduler!
    private var store: EventStore!
    private var types: EventTypeTemplateStore!
    private var skills: SkillInsightStore!
    private var prefs: AgentPreferenceStore!
    private var auth: AuthService!
    private var service: SupabaseSyncService!
    private var puller: SyncPuller!
    private var eraser: LocalDataEraser!
    private var shelfDirectory: URL!
    private var prefsDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        DiagnosticTrail.clear()
        savedStandard = UserDefaults.standard.persistentDomain(forName: bundleID)
        // Another owner's sync keys in the app domain would block this uid.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(SyncBaselineStore.keyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        suite = "SyncFlushRealEraserQATests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        server = SyncFakeServer(userId: uid)
        scheduler = SyncManualScheduler(start: Self.t0)
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        prefsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFlushRealEraserQATests-prefs-\(UUID().uuidString)", isDirectory: true)
        shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFlushRealEraserQATests-shelf-\(UUID().uuidString)", isDirectory: true)
        prefs = AgentPreferenceStore(directoryURL: prefsDirectory)

        service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: .standard,
                                      scheduler: scheduler, environment: .local)
        service.attachStores(eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)
        puller = service.installInbound(shelf: ConflictShelf(directory: shelfDirectory))
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()

        let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
        let session = #"{"access_token":"at-1","refresh_token":"r-1","user_id":"\#(uid)","email":"erase@example.com","expires_at":\#(expiresAt)}"#
        auth = AuthService(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
                           sessionStore: InMemorySessionStore(),
                           transport: { request in
                               XCTFail("no auth request may go out; got \(request.url?.absoluteString ?? "?")")
                               throw URLError(.notConnectedToInternet)
                           },
                           launchEnvironment: ["SYNC_DEBUG_SESSION": session], syncEnvironment: .local)
        XCTAssertTrue(auth.isSignedIn, "fixture: the injected session signed in")
        UserDefaults.standard.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        service.attach(authService: auth, eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)
        UserDefaults.standard.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        XCTAssertTrue(service.canUpload, "fixture: the sinks may flush")
        XCTAssertTrue(service.ownerState.allowsSync, "fixture: this uid owns the data")

        eraser = LocalDataEraser(store: store, skillStore: skills,
                                 agentRuntime: AgentRuntime(eventTypeTemplateStore: types, preferenceStore: prefs),
                                 authService: auth, calendarState: CalendarViewState(defaults: defaults),
                                 syncService: service, imageBackupCoordinator: ImageBackupCoordinator(defaults: defaults),
                                 backupSnapshotService: BackupSnapshotService())

        puller.beginSession(autoPull: false)
        await puller.pullToHead()
        XCTAssertTrue(service.inboundAtHead, "fixture: the session reached head")
    }

    override func tearDown() async throws {
        puller?.endSession()
        UserDefaults.standard.setPersistentDomain(savedStandard ?? [:], forName: bundleID)
        try? FileManager.default.removeItem(at: shelfDirectory)
        try? FileManager.default.removeItem(at: prefsDirectory)
        TestStorage.tearDown(suite)
        DiagnosticTrail.clear()
        try await super.tearDown()
    }

    private func makeEvent(_ title: String) -> Event {
        Event(title: title, timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(1800))], createdAt: Self.t0)
    }

    private func makeTodo(_ title: String) -> Event {
        Event(title: title, timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(3600))],
              createdAt: Self.t0, kind: .todo)
    }

    private func writes() -> [SyncFakeServer.Request] {
        server.requests.filter { [.patch, .insert, .tombstone, .upsert, .delete].contains($0.verb) }
    }

    private func liveLines(_ table: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init)
            .filter { $0.contains("sync.flush.live table=\(table) ") }
    }

    private func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
    }

    private struct Erased {
        let onServer: [Event]
        let writesBefore: Int
        let calendarBaselineBefore: [String: SyncBaselineEntry]
    }

    /// Two calendar rows and a todo in the cloud and the baseline; one more
    /// calendar row pending in the debounce; the debounce fires (the flush
    /// task is queued with three rows) and the real erase runs in the same
    /// turn. Returns once the queued flush has read the emptied store — its
    /// `delivered=3 live=0` line is the witness that it ran.
    private func eraseLandsInTheGap(keepingSession: Bool) async throws -> Erased {
        let a = makeEvent("a"), b = makeEvent("b"), t = makeTodo("t")
        store.addCalendarEvent(a)
        store.addCalendarEvent(b)
        store.add(t)
        scheduler.advance(by: SupabaseSyncConfig.debounceSeconds)
        try await syncEventually("a, b and t pushed") {
            [a, b, t].allSatisfy { self.server.row(table: "events", key: $0.id.uuidString) != nil }
                && self.service.baseline.entry(table: "calendar_events", id: a.id.uuidString)?.seq != nil
                && self.service.baseline.entry(table: "calendar_events", id: b.id.uuidString)?.seq != nil
                && self.service.baseline.entry(table: "events", id: t.id.uuidString)?.seq != nil
        }
        try await settle()
        let erased = Erased(onServer: [a, b, t], writesBefore: writes().count,
                            calendarBaselineBefore: service.baseline.entries(table: "calendar_events"))

        store.addCalendarEvent(makeEvent("mine"))
        scheduler.advance(by: SupabaseSyncConfig.debounceSeconds)     // the flush task is queued
        eraser.resetAllLocalData(keepingSession: keepingSession)      // the real erase, same turn
        XCTAssertTrue(store.rawCalendarEvents.isEmpty && store.events.isEmpty, "fixture: the erase emptied the stores")
        XCTAssertEqual(writes().count, erased.writesBefore, "fixture: the flush task had not run when the erase did")

        try await syncEventually("the queued flush read the emptied store") { !self.liveLines("calendar_events").isEmpty }
        try await settle()
        XCTAssertEqual(liveLines("calendar_events"), liveLines("calendar_events").filter { $0.hasSuffix("delivered=3 live=0") },
                       "the queued flush ran once, on the emptied store")
        XCTAssertEqual(liveLines("calendar_events").count, 1)
        // The erase's own publications: their deliveries meet the switch off.
        scheduler.advance(by: SupabaseSyncConfig.settingsDebounceSeconds)
        try await settle()
        return erased
    }

    private func assertNothingLeftTheDevice(_ erased: Erased, file: StaticString = #filePath, line: UInt = #line) {
        let after = writes().dropFirst(erased.writesBefore)
        XCTAssertTrue(after.isEmpty, "a flush after the erase wrote: \(after.map { "\($0.verb) \($0.keys)" })",
                      file: file, line: line)
        for e in erased.onServer {
            XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString), "\(e.title) left the cloud", file: file, line: line)
            XCTAssertFalse(server.isTombstoned(table: "events", key: e.id.uuidString), "\(e.title) tombstoned by the erase",
                           file: file, line: line)
        }
    }

    func testQA11a_TheRealResetAllInTheGapLeavesTheCloudAlone() async throws {
        let erased = try await eraseLandsInTheGap(keepingSession: false)
        assertNothingLeftTheDevice(erased)
    }

    /// No sign-out here: the session, the owner and I1 all still let the
    /// queued flush through, so the switch the eraser turned off is the only
    /// thing between the emptied stores and a tombstone for every row.
    func testQA11b_TheRealEraseKeepingTheSessionInTheGapLeavesTheCloudAlone() async throws {
        let erased = try await eraseLandsInTheGap(keepingSession: true)
        XCTAssertEqual(service.userId, uid, "fixture: the session was kept")
        XCTAssertTrue(service.ownerState.allowsSync && service.inboundAtHead, "fixture: only the switch can refuse")
        assertNothingLeftTheDevice(erased)
        XCTAssertEqual(service.baseline.entries(table: "calendar_events"), erased.calendarBaselineBefore,
                       "the refused flush marked rows as sent")
        XCTAssertFalse(service.needsFlush.contains("calendar_events"),
                       "a flush the switch holds owes nothing: turning it on runs a full sync")
    }
}
