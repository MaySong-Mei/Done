//
//  SyncSeamlessSwitchTests.swift
//  DoneTests
//
//  gh#257, decided 2026-10-21: data belongs to its account, and changing
//  account should feel like nothing happened. Account B signs in on a phone
//  that holds account A's data. When everything of A's is in the cloud the
//  sign-in switches on its own (the erase keeping B's session, then B
//  syncs); only changes of A's that the cloud does not have make the card
//  ask. Two accounts, two fake servers, one phone whose gateway follows the
//  signed-in account.
//

import XCTest
@testable import Done

/// The phone's one gateway, pointed at whichever account is signed in: each
/// fake server is one account's cloud.
final class SyncAccountRouter: SyncGateway {
    var current: SyncFakeServer
    var writeEpoch: String?

    init(_ server: SyncFakeServer) { current = server }

    private var server: SyncFakeServer {
        current.writeEpoch = writeEpoch
        return current
    }

    func pullChanges(sinceSeq: Int64, pageLimit: Int) async throws -> [SyncFeedRow] {
        try await server.pullChanges(sinceSeq: sinceSeq, pageLimit: pageLimit)
    }
    func fetchSyncEpoch() async throws -> SyncEpochRow { try await server.fetchSyncEpoch() }
    func isAncestor(table: String, id: String, a: String, b: String) async throws -> Bool? {
        try await server.isAncestor(table: table, id: id, a: a, b: b)
    }
    func patchConditional(table: String, keyColumn: String, key: String, baseSeq: Int64, body: [String: Any]) async throws -> [[String: Any]] {
        try await server.patchConditional(table: table, keyColumn: keyColumn, key: key, baseSeq: baseSeq, body: body)
    }
    func insertIgnoringDuplicates(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
        try await server.insertIgnoringDuplicates(table: table, rows: rows)
    }
    func tombstone(table: String, keyColumn: String, keys: [String], deletedAt: Date) async throws -> [[String: Any]] {
        try await server.tombstone(table: table, keyColumn: keyColumn, keys: keys, deletedAt: deletedAt)
    }
    func upsertMerging(table: String, keyColumn: String, rows: [[String: Any]]) async throws {
        try await server.upsertMerging(table: table, keyColumn: keyColumn, rows: rows)
    }
    func deletePhysically(table: String, keyColumn: String, keys: [String]) async throws {
        try await server.deletePhysically(table: table, keyColumn: keyColumn, keys: keys)
    }
    func fetchAll(table: String, userId: String) async throws -> [[String: Any]] {
        try await server.fetchAll(table: table, userId: userId)
    }
}

@MainActor
final class SyncSeamlessSwitchTests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let uidA = "a1a1a1a1-0000-0000-0000-00000000000a"
    private let uidB = "b2b2b2b2-0000-0000-0000-00000000000b"

    private var cloudA: SyncFakeServer!
    private var cloudB: SyncFakeServer!
    private var router: SyncAccountRouter!
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: EventStore!
    private var service: SupabaseSyncService!
    private var puller: SyncPuller!
    private var shelf: ConflictShelf!
    private var shelfDirectory: URL!
    /// B's own other phone, which put B's row in B's cloud.
    private var bPhone: (suite: String, puller: SyncPuller)?
    private var erases = 0

    override func setUp() {
        super.setUp()
        cloudA = SyncFakeServer(userId: uidA)
        cloudB = SyncFakeServer(userId: uidB)
        router = SyncAccountRouter(cloudA)
        suite = "SyncSeamlessSwitchTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        service = SupabaseSyncService(gateway: router, userId: uidA, defaults: defaults, scheduler: SyncManualScheduler())
        service.attachStores(eventStore: store, eventTypeStore: nil, skillStore: nil, preferenceStore: nil)
        shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncSeamlessSwitchTests-\(UUID().uuidString)", isDirectory: true)
        shelf = ConflictShelf(directory: shelfDirectory)
        puller = service.installInbound(shelf: shelf)
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()
        puller.beginSession(autoPull: false)
        erases = 0
        // What the app hands in (`LocalDataEraser.resetAllLocalData(keepingSession: true)`),
        // as far as the engine can see it: the stores, the `syncHashes.`
        // prefix (the owner with it), the shelf, and the master switch off.
        service.ownerSwitchEraser = { [unowned self] in
            erases += 1
            store.clearAllLocalData()
            SupabaseSyncService.wipeAllPersistedHashes(defaults)
            shelf.wipe()
            defaults.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        }
    }

    override func tearDown() {
        puller.endSession()
        bPhone?.puller.endSession()
        if let bPhone { TestStorage.tearDown(bPhone.suite) }
        try? FileManager.default.removeItem(at: shelfDirectory)
        TestStorage.tearDown(suite)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeEvent(_ title: String, note: String) -> Event {
        Event(title: title, note: note,
              timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(1800))],
              createdAt: Self.t0)
    }

    private func local(_ event: Event) -> Event? {
        store.rawCalendarEvents.first { $0.id == event.id }
    }

    private func note(_ cloud: SyncFakeServer, _ event: Event) -> String? {
        cloud.row(table: "events", key: event.id.uuidString)?.data["note"] as? String
    }

    private func writes(_ cloud: SyncFakeServer) -> Int {
        cloud.requests.filter { [.patch, .insert, .tombstone, .upsert, .delete].contains($0.verb) }.count
    }

    /// Everything account A's session flushes, then its chain to head.
    private func syncEverythingAsA() async {
        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        await service.syncEvents(store.events, kind: "todo")
        await service.syncSettings()
        await service.syncAgentConversations()
        await puller.pullToHead()
    }

    /// A's phone with two calendar rows and a todo, all in A's cloud.
    private func aHasSyncedEverything() async -> [Event] {
        let rows = [makeEvent("A1", note: "a1"), makeEvent("A2", note: "a2")]
        rows.forEach { store.addCalendarEvent($0) }
        store.add(makeEvent("A todo", note: "t"))
        await syncEverythingAsA()
        XCTAssertEqual(rows.map { note(cloudA, $0) }, ["a1", "a2"], "fixture: A's rows are in A's cloud")
        XCTAssertEqual(service.unsyncedChanges(owner: uidA), 0, "fixture: nothing of A's is owed")
        return rows.map { local($0)! }
    }

    /// B's row, in B's cloud, put there by B's other phone.
    private func bHasARowInTheCloud() async -> Event {
        let suiteName = "SyncSeamlessSwitchTests-B-\(UUID().uuidString)"
        let location = TestStorage.reset(suiteName)
        let bDefaults = UserDefaults(suiteName: suiteName)!
        let bStore = EventStore(defaults: bDefaults, storage: location, seedsSampleDataIfEmpty: false)
        let bService = SupabaseSyncService(gateway: cloudB.connection(), userId: uidB, defaults: bDefaults, scheduler: SyncManualScheduler())
        bService.attachStores(eventStore: bStore, eventTypeStore: nil, skillStore: nil, preferenceStore: nil)
        let bShelf = FileManager.default.temporaryDirectory.appendingPathComponent("SyncSeamlessSwitchTests-B-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: bShelf) }
        let bPuller = bService.installInbound(shelf: ConflictShelf(directory: bShelf))
        bPuller.observesForeground = false
        bPuller.headFlag = SyncHeadFlag()
        bPuller.beginSession(autoPull: false)
        bPhone = (suiteName, bPuller)
        let theirs = makeEvent("B's", note: "nb")
        bStore.addCalendarEvent(theirs)
        await bPuller.pullToHead()
        await bService.syncEvents(bStore.rawCalendarEvents, kind: "calendar")
        XCTAssertEqual(note(cloudB, theirs), "nb", "fixture: B's row is in B's cloud")
        return theirs
    }

    /// A signs out; B signs in on this phone: what the session sink runs
    /// (`beginSession`, then the automatic switch). Returns whether it switched.
    @discardableResult
    private func signInAsB() -> Bool {
        puller.endSession()
        service.endSession()
        router.current = cloudB
        service.beginSession(userId: uidB)
        XCTAssertEqual(service.ownerState, .blocked(owner: uidA, session: uidB), "fixture: A's data blocks B")
        return service.switchAutomaticallyIfOwnerSynced()
    }

    /// The newest `sync.owner.` line, from its event name on.
    private func lastOwnerLine() -> String? {
        DiagnosticTrail.combinedText().components(separatedBy: "\n").last { $0.contains(" sync.owner.") }
            .flatMap { line in line.range(of: "sync.owner.").map { String(line[$0.lowerBound...]) } }
    }

    // MARK: - Everything in the cloud: switch, no prompt

    func testEverythingSynced_signingInAsBSwitchesWithoutAskingAndLoadsB_killsAutoSwitchWithoutErase_killsAutoSwitchLeavesMasterOff() async {
        let theirs = await bHasARowInTheCloud()
        let ours = await aHasSyncedEverything()
        let aWritesBefore = writes(cloudA)
        let aRowsBefore = ours.map { cloudA.seq(table: "events", key: $0.id.uuidString) }

        let switched = signInAsB()

        XCTAssertTrue(switched, "the sign-in switched on its own")
        XCTAssertNil(service.ownerUnsyncedChanges, "no prompt")
        XCTAssertEqual(erases, 1, "the erase ran once")
        XCTAssertEqual(service.ownerState, .active(uid: uidB))
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uidB, "B owns the phone now")
        XCTAssertTrue(defaults.bool(forKey: AppSettingsKeys.syncUploadsEnabled), "D9: the master switch is on")
        XCTAssertTrue(puller.active, "B's sync runs")
        let line = lastOwnerLine() ?? ""
        XCTAssertTrue(line.hasPrefix("sync.owner.switched reason=clean previous=\(uidA) session=\(uidB) erased=3"), line)

        await puller.pullToHead()
        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        await service.syncEvents(store.events, kind: "todo")

        XCTAssertEqual(store.rawCalendarEvents.map(\.id), [theirs.id], "the phone holds B's cloud")
        XCTAssertEqual(local(theirs)?.note, "nb")
        XCTAssertTrue(store.events.isEmpty, "A's todo left the phone")
        XCTAssertEqual(writes(cloudA), aWritesBefore, "nothing written to A's cloud")
        XCTAssertEqual(ours.map { cloudA.seq(table: "events", key: $0.id.uuidString) }, aRowsBefore)
        XCTAssertEqual(ours.map { note(cloudA, $0) }, ["a1", "a2"], "A's cloud is unchanged")
        XCTAssertTrue(ours.allSatisfy { cloudB.row(table: "events", key: $0.id.uuidString) == nil },
                      "nothing of A's went into B")
    }

    /// Before migration 015 (king's whole-table diff): the baseline holds
    /// the hash of each row as sent without the 015 columns. That is still
    /// "uploaded", so the switch runs on its own.
    func testEverythingSyncedBefore015_stillSwitchesOnItsOwn_killsFallbackHashNotRecognised() async {
        cloudA.pre015 = true
        _ = await aHasSyncedEverything()
        XCTAssertTrue(puller.feedUnavailable, "fixture: A's server has no feed")

        XCTAssertTrue(signInAsB(), "A's rows went up the king way; nothing is lost")
        XCTAssertEqual(service.ownerState, .active(uid: uidB))
    }

    // MARK: - Something not in the cloud: ask

    /// Positive control: an offline edit (the flush never ran) is owed.
    /// The card asks; "discard and switch" then runs today's switch: A's
    /// cloud keeps the old value, and the phone holds B's.
    func testAnOfflineEditIsOwed_theSignInAsksAndDiscardThenSwitches_killsDirtyRowsIgnored() async {
        let theirs = await bHasARowInTheCloud()
        let ours = await aHasSyncedEverything()
        var edited = ours[0]
        edited.note = "offline"
        store.updateCalendarEvent(edited)
        let aWritesBefore = writes(cloudA)

        XCTAssertFalse(signInAsB(), "not switched")

        XCTAssertEqual(service.ownerUnsyncedChanges, 1, "the card asks about one change")
        XCTAssertEqual(erases, 0, "nothing erased")
        XCTAssertEqual(service.ownerState, .blocked(owner: uidA, session: uidB))
        XCTAssertEqual(local(edited)?.note, "offline", "the edit is still on the phone")
        XCTAssertEqual(lastOwnerLine(), "sync.owner.switch_held reason=unsynced owner=\(uidA) session=\(uidB) n=1")

        // 放弃这些修改并切换: the card's switch.
        service.switchToCurrentAccount(erasingLocalData: service.ownerSwitchEraser!)
        await puller.pullToHead()

        XCTAssertEqual(service.ownerState, .active(uid: uidB))
        XCTAssertNil(service.ownerUnsyncedChanges, "the card is gone")
        XCTAssertEqual(store.rawCalendarEvents.map(\.id), [theirs.id], "the phone holds B's cloud")
        XCTAssertEqual(note(cloudA, ours[0]), "a1", "A's cloud keeps the value it had")
        XCTAssertEqual(writes(cloudA), aWritesBefore, "nothing written to A's cloud")
        XCTAssertTrue(lastOwnerLine()?.hasPrefix("sync.owner.switched reason=user") == true, lastOwnerLine() ?? "")
    }

    /// A delete made offline: the id is still in A's baseline, its
    /// tombstone never went out.
    func testAnOfflineDeleteIsOwed_killsUnsentDeletesIgnored() async {
        let ours = await aHasSyncedEverything()
        store.deleteCalendarEvent(ours[1])
        XCTAssertNil(local(ours[1]), "fixture: deleted on the phone")

        XCTAssertFalse(signInAsB())
        XCTAssertEqual(service.ownerUnsyncedChanges, 1)
        XCTAssertEqual(note(cloudA, ours[1]), "a2", "fixture: still live in A's cloud")
    }

    /// A flush that failed and was not sent again: the `?` its send left
    /// in A's baseline is what is read.
    func testAFailedFlushIsOwed() async {
        let ours = await aHasSyncedEverything()
        var edited = ours[0]
        edited.note = "failed"
        store.updateCalendarEvent(edited)
        cloudA.failWhen = { verb, _ in verb == .patch ? SyncFakeServer.Injected(note: "offline") : nil }
        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        XCTAssertEqual(note(cloudA, ours[0]), "a1", "fixture: the edit did not land")

        XCTAssertFalse(signInAsB())
        XCTAssertEqual(service.ownerUnsyncedChanges, 1)
    }

    /// An undecided recovery offer of A's on the shelf: a switch would
    /// throw it away, so the card asks.
    func testAnUndecidedOfferOfAsIsOwed_killsUndecidedOffersIgnored() async {
        let ours = await aHasSyncedEverything()
        XCTAssertTrue(shelf.append(ConflictShelfEntry(uid: uidA, table: "calendar_events", id: ours[0].id.uuidString, seq: 1,
                                                      reason: .catchup, row: ["title": "A1"], localClean: false,
                                                      catchup: true, offered: true)))

        XCTAssertFalse(signInAsB())
        XCTAssertEqual(service.ownerUnsyncedChanges, 1)
        XCTAssertEqual(erases, 0)
    }

    /// A's account was erased on another device (design §10.7): the
    /// three-way choice stays, nothing switches on its own.
    func testTheTerminalStateKeepsItsChoice_killsAutoSwitchInTerminalState() async {
        _ = await aHasSyncedEverything()
        defaults.set("calendar_events", forKey: SupabaseSyncService.accountGoneTableKey)

        XCTAssertFalse(signInAsB())
        XCTAssertTrue(service.canAdoptLocalData, "fixture: the terminal state")
        XCTAssertEqual(erases, 0, "nothing erased")
        XCTAssertNil(service.ownerUnsyncedChanges)
        XCTAssertEqual(service.ownerState, .blocked(owner: uidA, session: uidB))
    }

    // MARK: - Wiring and copy

    /// The session sink switches right after `beginSession`, and stops
    /// there: the switch already started B's sync.
    func testTheSessionSinkSwitchesRightAfterBeginSession_killsSinkNeverSwitches() throws {
        let body = try EraseWiringScan.functionBody(of: "func attach(", inFileAt: "Done/Services/SupabaseSyncService.swift")
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(collapsed.contains("self.beginSession(userId: session.user.id) if self.switchAutomaticallyIfOwnerSynced() { return } if !self.canUpload {"),
                      collapsed)
    }

    /// The app hands the engine the real erase, keeping the session, before
    /// `attach` (whose session sink may switch at once).
    func testTheAppWiresTheRealEraseBeforeAttach_killsEraserNotWired() throws {
        let source = try String(contentsOf: EraseWiringScan.repoRoot.appendingPathComponent("Done/ContentView.swift"), encoding: .utf8)
        let collapsed = EraseWiringScan.strippingComments(source).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let wired = try XCTUnwrap(collapsed.range(of: "syncService.ownerSwitchEraser = { ownerSwitchEraser.resetAllLocalData(keepingSession: true) }"))
        let attach = try XCTUnwrap(collapsed.range(of: "syncService.attach("))
        XCTAssertLessThan(wired.lowerBound, attach.lowerBound)
        XCTAssertTrue(collapsed.contains("let ownerSwitchEraser = LocalDataEraser(store: store, skillStore: skillInsightStore,"))
    }

    func testThePromptCopyInBothLanguages() {
        let en = LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, 3, language: .english)
        XCTAssertTrue(en.contains("3 changes on this phone that haven't synced to the cloud"), en)
        XCTAssertTrue(en.contains("Switching now would lose them"), en)
        let zh = LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, 3, language: .chinese)
        XCTAssertEqual(zh, "之前登录的账号还有 3 条修改没同步到云端，现在切换会丢掉它们。")
        XCTAssertEqual(LKey.ownerUnsyncedSignInOwner.text(for: .chinese), "用原账号登录并同步")
        XCTAssertEqual(LKey.ownerUnsyncedDiscardAndSwitch.text(for: .chinese), "放弃这些修改并切换")
        XCTAssertEqual(LKey.ownerUnsyncedDiscardAndSwitch.text(for: .english), "Discard these changes and switch")
    }
}
