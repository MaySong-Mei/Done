//
//  SyncFlushLiveArrayTests.swift
//  DoneTests
//
//  The per-table debounce sinks in `SupabaseSyncService.attach` deliver the
//  array the store published when the debounce armed, and queue the flush
//  as a main-actor task. A pull page that lands on the main actor before
//  that task starts writes the store AND the baseline. A flush that pushes
//  the delivered array then reads every row the page created as "left the
//  local array" and tombstones it, and every row the page edited as a
//  local change and PATCHes the old value back at the new seq: another
//  device's new row deleted everywhere, its edit overwritten.
//
//  Each test drives the interleaving through `attach`'s real sinks: a local
//  change arms the debounce, another device writes the server, the manual
//  clock fires the debounce (the flush task is queued, not run), the page
//  is applied with the applier the puller calls, and only then does the
//  test yield to the flush. The test holds the main actor across the two
//  middle steps, which is the order a pull continuation queued ahead of the
//  flush task runs in.
//

import XCTest
@testable import Done

@MainActor
final class SyncFlushLiveArrayTests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let uid = "11111111-2222-4333-8444-555555555555"

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
        suite = "SyncFlushLiveArrayTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        server = SyncFakeServer(userId: uid)
        scheduler = SyncManualScheduler(start: Self.t0)
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        prefsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFlushLiveArrayTests-prefs-\(UUID().uuidString)", isDirectory: true)
        shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFlushLiveArrayTests-shelf-\(UUID().uuidString)", isDirectory: true)
        prefs = AgentPreferenceStore(directoryURL: prefsDirectory)

        service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: defaults,
                                      scheduler: scheduler, environment: .local)
        service.attachStores(eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)
        puller = service.installInbound(shelf: ConflictShelf(directory: shelfDirectory))
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()

        // The session is there before `attach`, as at launch. With the
        // master switch off the session sink marks the launch sync done and
        // starts neither the puller nor a full sync, so nothing runs that
        // the test did not start; the sinks read the switch on every
        // delivery, so turning it on afterwards is all they need.
        let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
        let session = #"{"access_token":"at-1","refresh_token":"r-1","user_id":"\#(uid)","email":"rig@example.com","expires_at":\#(expiresAt)}"#
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

        // A session at head: the state every flush below runs in.
        puller.beginSession(autoPull: false)
        await puller.pullToHead()
        XCTAssertTrue(service.inboundAtHead, "fixture: the session reached head")
    }

    override func tearDown() async throws {
        puller?.endSession()
        try? FileManager.default.removeItem(at: shelfDirectory)
        try? FileManager.default.removeItem(at: prefsDirectory)
        TestStorage.tearDown(suite)
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

    private func occurrenceKey(_ event: Event) -> CalendarOccurrenceKey {
        CalendarOccurrenceKey(eventID: event.id, baseSeriesEventID: nil, occurrenceDate: Self.t0,
                              kind: .singleEvent, dayKey: 20260528)
    }

    private func makeLog(_ event: Event, note: String) -> CalendarEventLogRecord {
        let key = occurrenceKey(event)
        return CalendarEventLogRecord(id: key, eventID: key.eventID, baseSeriesEventID: nil,
                                      occurrenceDate: Self.t0, note: note, createdAt: Self.t0, updatedAt: Self.t0)
    }

    private func makeFeedback(_ event: Event, note: String) -> CalendarEventFeedbackRecord {
        let key = occurrenceKey(event)
        return CalendarEventFeedbackRecord(id: key, eventID: key.eventID, baseSeriesEventID: nil,
                                           occurrenceDate: Self.t0, selfNote: note, createdAt: Self.t0, updatedAt: Self.t0)
    }

    private func writeCount() -> Int {
        server.requests.filter { [.patch, .insert, .tombstone, .upsert, .delete].contains($0.verb) }.count
    }

    private func tombstonedKeys(_ serverTable: String) -> Set<String> {
        Set(server.requests(.tombstone, table: serverTable).flatMap(\.keys).map { $0.lowercased() })
    }

    private func patchedKeys(_ serverTable: String) -> Set<String> {
        Set(server.requests(.patch, table: serverTable).flatMap(\.keys).map { $0.lowercased() })
    }

    private func liveLines(_ table: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init)
            .filter { $0.contains("sync.flush.live table=\(table) ") }
    }

    private func seq(_ table: String, _ id: String) -> Int64? {
        service.baseline.entry(table: table, id: id)?.seq
    }

    /// A row the sinks pushed is in the baseline with the seq its response
    /// carried; inserts go out after the deletes and the PATCHes, so this
    /// also says the flush's earlier requests were answered.
    private func waitUntilPushed(_ table: String, _ id: String, _ what: String) async throws {
        try await syncEventually("\(what) pushed through the sink") { self.seq(table, id) != nil }
    }

    /// One debounce period on the manual clock, then the flushes it queued.
    private func flushThroughTheSinks(settledBy table: String, _ id: String, _ what: String) async throws {
        scheduler.advance(by: SupabaseSyncConfig.debounceSeconds)
        try await waitUntilPushed(table, id, what)
    }

    /// The interleaving. `localChange` arms the debounce; `otherDevice`
    /// writes the server; the page that carries it is fetched first (the
    /// RPC is the async part of a pull). Then, without yielding: the
    /// debounce fires, so the sink delivers its array and queues the flush
    /// task; the page is applied as the puller applies it. The flush task
    /// runs once the test waits for it.
    private func remoteWriteLandsInTheGap(
        localChange: () -> Void,
        otherDevice: () -> Void,
        applies remote: (table: String, id: String),
        settledBy table: String, _ localId: @autoclosure () -> String
    ) async throws {
        localChange()
        otherDevice()
        let page = try await server.pullChanges(sinceSeq: service.cursor.value ?? 0, pageLimit: puller.pageLimit)
        XCTAssertFalse(page.isEmpty, "fixture: the other device's write is in the feed")

        let writesBefore = writeCount()
        scheduler.advance(by: SupabaseSyncConfig.debounceSeconds)
        var context = SyncApplyContext(engine: service, shelf: puller.shelf,
                                       eraseToken: LocalDataEraseEpoch.capture(), pullIssue: puller.pullIssue)
        context.eventTypeStore = types
        context.skillStore = skills
        let outcome = store.applyRemote(RemotePage(rows: page), context: context)
        XCTAssertTrue(outcome.countsAsApplied, "fixture: the page applied")
        XCTAssertEqual(writeCount(), writesBefore, "fixture: the flush task had not run when the page landed")
        XCTAssertNotNil(service.baseline.entry(table: remote.table, id: remote.id)?.seq,
                        "fixture: the pull wrote the remote row's baseline")

        try await waitUntilPushed(table, localId(), "the local change")
    }

    /// The other device's new row arrived, and this device's flush in the
    /// gap left it alone: never tombstoned, still on the server, still here.
    private func assertTheRemoteRowSurvived(serverTable: String, baselineTable: String, id: String,
                                            isLocal: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(service.baseline.entry(table: baselineTable, id: id),
                        "the remote row lost the baseline the pull gave it", file: file, line: line)
        XCTAssertFalse(tombstonedKeys(serverTable).contains(id.lowercased()),
                       "the flush tombstoned the other device's new row", file: file, line: line)
        XCTAssertFalse(server.isTombstoned(table: serverTable, key: id),
                       "the other device's new row is dead on the server", file: file, line: line)
        XCTAssertTrue(isLocal, "the other device's new row is still on this device", file: file, line: line)
    }

    // MARK: - A remote create in the gap, table by table

    func testACalendarRowCreatedRemotelyInTheGapIsNotTombstoned_killsCalendarSinkPushesItsCapture_killsNoTrailLine() async throws {
        let mine = makeEvent("mine"), theirs = makeEvent("theirs")
        let linesBefore = liveLines("calendar_events").count
        try await remoteWriteLandsInTheGap(
            localChange: { store.addCalendarEvent(mine) },
            otherDevice: { server.writeDirectly(table: "events", key: theirs.id.uuidString,
                                                data: service.eventToRow(theirs, kind: "calendar")) },
            applies: ("calendar_events", theirs.id.uuidString),
            settledBy: "calendar_events", mine.id.uuidString)
        assertTheRemoteRowSurvived(serverTable: "events", baselineTable: "calendar_events", id: theirs.id.uuidString,
                                   isLocal: store.rawCalendarEvents.contains { $0.id == theirs.id })
        // The device-side witness: the flush found the store ahead of what
        // the debounce delivered, and says so once.
        XCTAssertEqual(liveLines("calendar_events").count, linesBefore + 1)
        XCTAssertTrue(liveLines("calendar_events").last?.hasSuffix("delivered=1 live=2") == true,
                      liveLines("calendar_events").last ?? "no line")
    }

    func testATodoCreatedRemotelyInTheGapIsNotTombstoned_killsTodoSinkPushesItsCapture() async throws {
        let mine = makeTodo("mine"), theirs = makeTodo("theirs")
        try await remoteWriteLandsInTheGap(
            localChange: { store.add(mine) },
            otherDevice: { server.writeDirectly(table: "events", key: theirs.id.uuidString,
                                                data: service.eventToRow(theirs, kind: "todo")) },
            applies: ("events", theirs.id.uuidString),
            settledBy: "events", mine.id.uuidString)
        assertTheRemoteRowSurvived(serverTable: "events", baselineTable: "events", id: theirs.id.uuidString,
                                   isLocal: store.events.contains { $0.id == theirs.id })
    }

    func testALogCreatedRemotelyInTheGapIsNotTombstoned_killsLogSinkPushesItsCapture() async throws {
        let mine = makeLog(makeEvent("mine"), note: "mine"), theirs = makeLog(makeEvent("theirs"), note: "theirs")
        let theirsId = service.encodeOccurrenceKey(theirs.id)
        try await remoteWriteLandsInTheGap(
            localChange: { store.calendarEventLogRecords.append(mine) },
            otherDevice: { server.writeDirectly(table: "event_logs", key: theirsId, data: service.logToRow(theirs)) },
            applies: ("event_logs", theirsId),
            settledBy: "event_logs", service.encodeOccurrenceKey(mine.id))
        assertTheRemoteRowSurvived(serverTable: "event_logs", baselineTable: "event_logs", id: theirsId,
                                   isLocal: store.calendarEventLogRecords.contains { $0.id == theirs.id })
    }

    func testFeedbackCreatedRemotelyInTheGapIsNotTombstoned_killsFeedbackSinkPushesItsCapture() async throws {
        let mine = makeFeedback(makeEvent("mine"), note: "mine"), theirs = makeFeedback(makeEvent("theirs"), note: "theirs")
        let theirsId = service.encodeOccurrenceKey(theirs.id)
        try await remoteWriteLandsInTheGap(
            localChange: { store.calendarEventFeedbackRecords.append(mine) },
            otherDevice: { server.writeDirectly(table: "event_feedback", key: theirsId, data: service.feedbackToRow(theirs)) },
            applies: ("event_feedback", theirsId),
            settledBy: "event_feedback", service.encodeOccurrenceKey(mine.id))
        assertTheRemoteRowSurvived(serverTable: "event_feedback", baselineTable: "event_feedback", id: theirsId,
                                   isLocal: store.calendarEventFeedbackRecords.contains { $0.id == theirs.id })
    }

    func testATodoListCreatedRemotelyInTheGapIsNotTombstoned_killsTodoListSinkPushesItsCapture() async throws {
        let mine = TodoList(title: "mine", colorName: "green", createdAt: Self.t0)
        let theirs = TodoList(title: "theirs", colorName: "red", createdAt: Self.t0)
        try await remoteWriteLandsInTheGap(
            localChange: { store.addList(mine) },
            otherDevice: { server.writeDirectly(table: "todo_lists", key: theirs.id.uuidString, data: service.todoListToRow(theirs)) },
            applies: ("todo_lists", theirs.id.uuidString),
            settledBy: "todo_lists", mine.id.uuidString)
        assertTheRemoteRowSurvived(serverTable: "todo_lists", baselineTable: "todo_lists", id: theirs.id.uuidString,
                                   isLocal: store.todoLists.contains { $0.id == theirs.id })
    }

    func testAnEventTypeCreatedRemotelyInTheGapIsNotTombstoned_killsEventTypeSinkPushesItsCapture() async throws {
        let theirs = EventTypeTemplate(title: "Theirs", colorHex: "#123456")
        try await remoteWriteLandsInTheGap(
            localChange: { types.add("Mine", colorHex: "#654321") },
            otherDevice: { server.writeDirectly(table: "event_types", key: theirs.id.uuidString, data: service.eventTypeToRow(theirs)) },
            applies: ("event_types", theirs.id.uuidString),
            settledBy: "event_types", types.templates.first { $0.title == "Mine" }?.id.uuidString ?? "no local type")
        assertTheRemoteRowSurvived(serverTable: "event_types", baselineTable: "event_types", id: theirs.id.uuidString,
                                   isLocal: types.templates.contains { $0.id == theirs.id })
    }

    func testASkillInsightCreatedRemotelyInTheGapIsNotTombstoned_killsSkillSinkPushesItsCapture() async throws {
        let mine = SkillInsight(skillName: "focus", points: 1, date: Self.t0, eventTitle: "mine", reasoning: "r")
        let theirs = SkillInsight(skillName: "focus", points: 2, date: Self.t0, eventTitle: "theirs", reasoning: "r")
        try await remoteWriteLandsInTheGap(
            localChange: { skills.add(mine) },
            otherDevice: { server.writeDirectly(table: "skill_insights", key: theirs.id.uuidString, data: service.skillToRow(theirs)) },
            applies: ("skill_insights", theirs.id.uuidString),
            settledBy: "skill_insights", mine.id.uuidString)
        assertTheRemoteRowSurvived(serverTable: "skill_insights", baselineTable: "skill_insights", id: theirs.id.uuidString,
                                   isLocal: skills.insights.contains { $0.id == theirs.id })
    }

    // MARK: - A remote edit in the gap

    func testARemoteEditAppliedInTheGapIsNotOverwrittenWithTheOldValue_killsCalendarSinkPushesItsCapture() async throws {
        let shared = makeEvent("shared", note: "before")
        store.addCalendarEvent(shared)
        try await flushThroughTheSinks(settledBy: "calendar_events", shared.id.uuidString, "the shared row")
        let patchesBefore = patchedKeys("events")

        let mine = makeEvent("mine")
        try await remoteWriteLandsInTheGap(
            localChange: { store.addCalendarEvent(mine) },
            otherDevice: { server.writeDirectly(table: "events", key: shared.id.uuidString, data: ["note": "theirs"]) },
            applies: ("calendar_events", shared.id.uuidString),
            settledBy: "calendar_events", mine.id.uuidString)

        XCTAssertEqual(store.rawCalendarEvents.first { $0.id == shared.id }?.note, "theirs", "fixture: the pull adopted the edit")
        XCTAssertEqual(patchedKeys("events").subtracting(patchesBefore), [],
                       "the flush PATCHed the row the pull had just changed")
        XCTAssertEqual(server.row(table: "events", key: shared.id.uuidString)?.data["note"] as? String, "theirs",
                       "the other device's edit was overwritten with the old value")
    }

    // MARK: - Local deletes still go out

    func testALocalDeleteInTheSameFlushIsStillTombstoned_killsLiveReadSkipsDeletes() async throws {
        let doomed = makeEvent("doomed")
        store.addCalendarEvent(doomed)
        try await flushThroughTheSinks(settledBy: "calendar_events", doomed.id.uuidString, "the doomed row")

        let mine = makeEvent("mine"), theirs = makeEvent("theirs")
        try await remoteWriteLandsInTheGap(
            localChange: {
                store.deleteCalendarEvent(doomed)
                store.addCalendarEvent(mine)
            },
            otherDevice: { server.writeDirectly(table: "events", key: theirs.id.uuidString,
                                                data: service.eventToRow(theirs, kind: "calendar")) },
            applies: ("calendar_events", theirs.id.uuidString),
            settledBy: "calendar_events", mine.id.uuidString)

        XCTAssertEqual(tombstonedKeys("events"), [doomed.id.uuidString.lowercased()],
                       "exactly the row deleted here is tombstoned")
        XCTAssertTrue(server.isTombstoned(table: "events", key: doomed.id.uuidString))
        XCTAssertNil(service.baseline.entry(table: "calendar_events", id: doomed.id.uuidString),
                     "a 2xx tombstone takes the id out of the baseline")
        XCTAssertFalse(server.isTombstoned(table: "events", key: theirs.id.uuidString))
    }

    func testAPlainLocalTodoDeleteIsTombstonedThroughTheSink_killsLiveReadSkipsDeletes_killsTrailOnEveryFlush() async throws {
        let doomed = makeTodo("doomed"), kept = makeTodo("kept")
        let linesBefore = liveLines("events").count
        store.add(doomed)
        store.add(kept)
        try await flushThroughTheSinks(settledBy: "events", doomed.id.uuidString, "the doomed todo")

        store.delete(doomed)
        scheduler.advance(by: SupabaseSyncConfig.debounceSeconds)
        try await syncEventually("the delete pushed through the sink") {
            self.service.baseline.entry(table: "events", id: doomed.id.uuidString) == nil
        }
        XCTAssertEqual(tombstonedKeys("events"), [doomed.id.uuidString.lowercased()])
        XCTAssertTrue(server.isTombstoned(table: "events", key: doomed.id.uuidString))
        XCTAssertFalse(server.isTombstoned(table: "events", key: kept.id.uuidString))
        XCTAssertEqual(liveLines("events").count, linesBefore, "a flush with nothing in the gap writes no trail line")
    }
}
