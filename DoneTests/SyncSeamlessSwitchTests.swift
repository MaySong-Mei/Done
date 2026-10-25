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
    func upsertRows(table: String, rows: [[String: Any]], onConflict: [String]) async throws {
        try await server.upsertRows(table: table, rows: rows, onConflict: onConflict)
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
    private var prefsDirectory: URL!
    private var prefs: AgentPreferenceStore!
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
        shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncSeamlessSwitchTests-\(UUID().uuidString)", isDirectory: true)
        // The owner record beside the shelf, as in the app (`.production`
        // is `ConflictShelf.productionDirectory`); the shelf's wipe removes it.
        service = SupabaseSyncService(gateway: router, userId: uidA, defaults: defaults, scheduler: SyncManualScheduler(),
                                      ownerRecord: SyncOwnerRecord(directory: shelfDirectory))
        prefsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncSeamlessSwitchTests-prefs-\(UUID().uuidString)", isDirectory: true)
        prefs = AgentPreferenceStore(directoryURL: prefsDirectory)
        service.attachStores(eventStore: store, eventTypeStore: nil, skillStore: nil, preferenceStore: prefs)
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
        try? FileManager.default.removeItem(at: prefsDirectory)
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
        await service.syncAgentPreferences(prefs)
        await service.syncAgentConversations()
        await puller.pullToHead()
    }

    /// What the app does to the preferences row on its own (staging QA
    /// round 7: the token projections carry event titles, so every event
    /// edit rewrites it): the row differs from what A uploaded.
    private func thePreferencesRowChangesOnItsOwn() {
        let rule = AgentPreferenceRule(scope: .eventTypeMapping,
                                       triggerPattern: .init(kind: .exactEventTypeTitle, value: "gym"),
                                       preferredAction: .init(kind: .keepTypeOnly, value: nil),
                                       source: .explicitSelection, lastUsedAt: Self.t0)
        _ = prefs.applyRestore(rules: [rule], decisionHistory: [], strategy: .cloudOverwritesLocal, resolution: .keepCloud)
        XCTAssertNotEqual(SupabaseSyncService.rowHash(service.agentPreferencesToRow(prefs)),
                          service.baseline.entry(table: "agent_preferences", id: uidA)?.hash,
                          "fixture: the preferences row is not the one A uploaded")
        XCTAssertNotNil(service.baseline.entry(table: "agent_preferences", id: uidA), "fixture: A did upload one")
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
        XCTAssertEqual(service.heldSwitchAlertsPresented, 0, "no alert")
        XCTAssertNil(service.heldSwitchAlert)
        XCTAssertEqual(erases, 1, "the erase ran once")
        XCTAssertEqual(service.ownerState, .active(uid: uidB))
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uidB, "B owns the phone now")
        XCTAssertEqual(SyncOwnerRecord(directory: shelfDirectory).read(), uidB, "…on file too")
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

    /// Staging QA round 7, finding 1: three offline event changes and the
    /// preferences row the app rewrote alongside them. The card says 3 — the
    /// changes the user made — not 4.
    func testThreeOfflineChangesAreThree_thePreferencesRowIsNotCounted_killsSingletonsCounted() async {
        let ours = await aHasSyncedEverything()
        for (index, row) in ours.enumerated() {
            var edited = row
            edited.note = "offline \(index)"
            store.updateCalendarEvent(edited)
        }
        store.addCalendarEvent(makeEvent("A3", note: "a3"))
        thePreferencesRowChangesOnItsOwn()

        XCTAssertFalse(signInAsB(), "not switched")

        XCTAssertEqual(service.ownerUnsyncedChanges, 3, "three changes, not four")
        XCTAssertEqual(lastOwnerLine(), "sync.owner.switch_held reason=unsynced owner=\(uidA) session=\(uidB) n=3")
        XCTAssertEqual(erases, 0)
    }

    /// The preferences row alone does not hold the switch: nothing the user
    /// would recognise is lost, so the sign-in switches on its own.
    func testOnlyThePreferencesRowIsUnsynced_theSignInSwitchesOnItsOwn_killsSingletonsCounted() async {
        _ = await aHasSyncedEverything()
        thePreferencesRowChangesOnItsOwn()

        XCTAssertTrue(signInAsB(), "switched on its own")
        XCTAssertNil(service.ownerUnsyncedChanges)
        XCTAssertEqual(erases, 1)
        XCTAssertEqual(service.ownerState, .active(uid: uidB))
    }

    /// A settings key A changed and never sent is the user's own change:
    /// one change, and the card asks.
    func testOnlyASettingsKeyIsUnsynced_theCardAsksAboutOne_killsSettingsNotCounted() async {
        _ = await aHasSyncedEverything()
        let was = defaults.object(forKey: AppSettingsKeys.showTimerBanner) as? Bool ?? false
        defaults.set(!was, forKey: AppSettingsKeys.showTimerBanner)

        XCTAssertFalse(signInAsB(), "not switched")
        XCTAssertEqual(service.ownerUnsyncedChanges, 1)
        XCTAssertEqual(erases, 0)
    }

    /// Staging QA round 7, observation 1: a held sign-in says so over the
    /// main screen — once. The session sink runs again on every token
    /// refresh and return to the foreground; the alert does not come back,
    /// and the card keeps asking.
    func testAHeldSignInPutsTheAlertUpOnceAndNotAgainOnForeground_killsNoAlert_killsAlertEveryTime() async {
        let ours = await aHasSyncedEverything()
        var edited = ours[0]
        edited.note = "offline"
        store.updateCalendarEvent(edited)

        XCTAssertFalse(signInAsB())
        XCTAssertEqual(service.heldSwitchAlertsPresented, 1, "the alert went up")
        XCTAssertEqual(service.heldSwitchAlert, 1, "…saying one change")

        service.heldSwitchAlert = nil  // the user dismissed it
        // Foreground / token refresh: what the session sink runs again.
        service.beginSession(userId: uidB)
        XCTAssertFalse(service.switchAutomaticallyIfOwnerSynced())

        XCTAssertEqual(service.heldSwitchAlertsPresented, 1, "not again this launch")
        XCTAssertNil(service.heldSwitchAlert)
        XCTAssertEqual(service.ownerUnsyncedChanges, 1, "the card still asks")
    }

    /// The alert's answers are the card's: "switch anyway" straight to the
    /// switch, "cancel" keeps the changes and signs out.
    func testTheAlertOffersSwitchAnywayAndCancelThatSignsOut_killsAlertCancelKeepsSession() throws {
        let source = try String(contentsOf: EraseWiringScan.repoRoot.appendingPathComponent("Done/ContentView.swift"), encoding: .utf8)
        let collapsed = EraseWiringScan.strippingComments(source).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(collapsed.contains("presenting: syncService.heldSwitchAlert) { _ in Button(L(.ownerUnsyncedSwitchAnyway), role: .destructive) { syncService.switchAnyway() } Button(L(.cancel), role: .cancel) { syncService.deferSwitchUntilOwnerSyncs() authService.signOut() } } message: { unsynced in Text(LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, unsynced)) }"),
                      "the launch alert's two answers")
    }

    /// "Switch anyway" (card or alert) switches at once, as the user's
    /// choice; A's cloud keeps what it had.
    func testSwitchAnywaySwitchesAtOnce() async {
        let theirs = await bHasARowInTheCloud()
        let ours = await aHasSyncedEverything()
        var edited = ours[0]
        edited.note = "offline"
        store.updateCalendarEvent(edited)
        XCTAssertFalse(signInAsB())
        let aWritesBefore = writes(cloudA)

        service.switchAnyway()
        await puller.pullToHead()

        XCTAssertEqual(erases, 1)
        XCTAssertEqual(service.ownerState, .active(uid: uidB))
        XCTAssertNil(service.heldSwitchAlert, "the alert is gone")
        XCTAssertEqual(store.rawCalendarEvents.map(\.id), [theirs.id])
        XCTAssertEqual(writes(cloudA), aWritesBefore)
        XCTAssertTrue(lastOwnerLine()?.hasPrefix("sync.owner.switched reason=user previous=\(uidA) session=\(uidB)") == true,
                      lastOwnerLine() ?? "")
    }

    /// Not held (a fully synced owner, or nobody blocked): nothing to answer.
    func testSwitchAnywayWithNothingHeldDoesNothing() async {
        _ = await aHasSyncedEverything()
        service.switchAnyway()
        XCTAssertEqual(erases, 0)
        XCTAssertEqual(lastOwnerLine(), "sync.owner.switch_refused reason=not_held")
    }

    // MARK: - The owner record beside the data (staging QA round 7, finding 2)

    /// The device's preferences were lost while its data files stayed (QA:
    /// cfprefsd refusing writes; the next sign-in uploaded the old account's
    /// rows into the new one). A relaunch signed in as B is still blocked:
    /// the record beside the data names A. With A's baseline gone too,
    /// every row of A's counts as unsynced, so the card asks.
    func testTheDefaultsAreLostWhileTheDataStays_aRelaunchAsBIsStillBlocked_killsDefaultsOnly() async {
        _ = await aHasSyncedEverything()
        XCTAssertEqual(SyncOwnerRecord(directory: shelfDirectory).read(), uidA, "fixture: A is on file")
        let rowsOnThePhone = store.rawCalendarEvents.count + store.events.count
        puller.endSession()
        service.endSession()
        defaults.removePersistentDomain(forName: suite)
        XCTAssertNil(defaults.string(forKey: SyncOwnerGuard.ownerKey), "fixture: the defaults are gone")
        XCTAssertFalse(SyncOwnerGuard.hasSyncedState(owner: uidA, defaults), "fixture: A's baseline went with them")

        router.current = cloudB
        let relaunched = SupabaseSyncService(gateway: router, userId: uidB, defaults: defaults, scheduler: SyncManualScheduler(),
                                             ownerRecord: SyncOwnerRecord(directory: shelfDirectory))
        relaunched.attachStores(eventStore: store, eventTypeStore: nil, skillStore: nil, preferenceStore: prefs)
        relaunched.ownerSwitchEraser = service.ownerSwitchEraser

        XCTAssertEqual(relaunched.ownerState, .blocked(owner: uidA, session: uidB), "still blocked")
        XCTAssertFalse(relaunched.switchAutomaticallyIfOwnerSynced(), "nothing of A's can be shown to be in the cloud")
        XCTAssertGreaterThanOrEqual(relaunched.ownerUnsyncedChanges ?? 0, rowsOnThePhone)
        XCTAssertEqual(erases, 0)
        XCTAssertTrue(DiagnosticTrail.combinedText().contains("sync.owner.record_mismatch file=\(uidA) defaults=none session=\(uidB)"))
        await relaunched.syncEvents(store.rawCalendarEvents, kind: "calendar")
        XCTAssertEqual(writes(cloudB), 0, "nothing of A's went into B")
    }

    /// Either record names the owner. A device from before the file: the
    /// key decides, and the owner's next sign-in writes the file.
    func testEitherRecordNamesTheOwner_aDeviceFromBeforeTheFileGetsOneAtItsOwnersSignIn_killsStoredOwnerDefaultsOnly() {
        let record = SyncOwnerRecord(directory: shelfDirectory)
        record.remove()
        XCTAssertNil(record.read(), "fixture: no file")
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uidA)
        XCTAssertEqual(SyncOwnerGuard.storedOwner(defaults, record: record), uidA, "the key alone names the owner")

        XCTAssertEqual(SyncOwnerGuard.evaluate(sessionUid: uidA, defaults, record: record), .active(uid: uidA))
        XCTAssertEqual(record.read(), uidA, "the file is written")

        defaults.removeObject(forKey: SyncOwnerGuard.ownerKey)
        XCTAssertEqual(SyncOwnerGuard.storedOwner(defaults, record: record), uidA, "the file alone names the owner")
    }

    /// The app hands its engine the record beside the data, and the erase
    /// removes it by name.
    func testTheAppKeepsTheOwnerRecordBesideTheData_killsRecordNotWired() throws {
        let source = try String(contentsOf: EraseWiringScan.repoRoot.appendingPathComponent("Done/ContentView.swift"), encoding: .utf8)
        let collapsed = EraseWiringScan.strippingComments(source).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(collapsed.contains("@StateObject private var syncService = SupabaseSyncService(ownerRecord: .production)"))
        XCTAssertEqual(SyncOwnerRecord.production.directory, ConflictShelf.productionDirectory, "beside the shelf")
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

    /// The held card has exactly two answers: "switch anyway" (the
    /// destructive switch, at once: no second confirmation, staging QA
    /// round 7 observation 3) and "cancel", which ends this session so the
    /// owner can sign in and sync. No third button. The plain mismatch
    /// card's "switch to this account" keeps its confirmation.
    func testTheHeldCardOffersSwitchAnywayAndCancelOnly_killsCancelKeepsSession_killsSecondConfirmation() throws {
        let body = try EraseWiringScan.functionBody(of: "private var ownerMismatchCard: some View {",
                                                    inFileAt: "Done/Views/Agent/AccountView.swift")
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(collapsed.contains("if unsyncedChangesHeld { Button(L(.ownerUnsyncedSwitchAnyway), role: .destructive) { syncService.switchAnyway() } .font(.subheadline) Button(L(.cancel)) { syncService.deferSwitchUntilOwnerSyncs() authService.signOut() } .font(.subheadline) } else {"),
                      collapsed)
        XCTAssertTrue(collapsed.contains("} else { Button(L(.ownerMismatchSwitch)) { switchConfirmationCount = syncService.localIdRowCount }"),
                      "the plain card still confirms")
        XCTAssertEqual(collapsed.components(separatedBy: "switchConfirmationCount = syncService.localIdRowCount").count - 1, 1,
                       "one way into the switch confirmation: the plain card's")
    }

    func testThePromptCopyInBothLanguages() {
        XCTAssertEqual(LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, 3, language: .english),
                       "This phone still has 3 changes that haven't synced to the cloud. Switching now will lose them.")
        XCTAssertEqual(LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, 1, language: .english),
                       "This phone still has 1 change that hasn't synced to the cloud. Switching now will lose it.")
        XCTAssertEqual(LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, 3, language: .chinese),
                       "本机还有 3 条修改没有同步到云端，现在切换会丢失它们。")
        XCTAssertEqual(LKey.ownerUnsyncedSwitchAnyway.text(for: .chinese), "仍要切换")
        XCTAssertEqual(LKey.ownerUnsyncedSwitchAnyway.text(for: .english), "Switch Anyway")
        XCTAssertEqual(LKey.cancel.text(for: .chinese), "取消")
    }

    /// Staging QA round 7: in Chinese the account card's "Account", "Email",
    /// "Sync" headings and its footer were still English.
    func testTheAccountCardHeadingsAreLocalised_killsHardCodedHeading() throws {
        XCTAssertEqual(LKey.accountTitle.text(for: .chinese), "账户")
        XCTAssertEqual(LKey.accountEmail.text(for: .chinese), "邮箱")
        XCTAssertEqual(LKey.accountSyncSection.text(for: .chinese), "同步")
        XCTAssertEqual(LKey.accountSyncHint.text(for: .chinese), "你的事件、日志和技能会自动同步到云端。AI 助手可以通过 MCP 查询这些数据。")
        XCTAssertEqual(LKey.accountSyncSection.text(for: .english), "Sync")
        let body = try EraseWiringScan.functionBody(of: "private var signedInSection: some View {",
                                                    inFileAt: "Done/Views/Agent/AccountView.swift")
        for literal in ["settingsCard(\"", "settingsLabeledRow(\"", "settingsHintCard(\""] {
            XCTAssertFalse(body.contains(literal), "an English literal heading in the account card: \(literal)")
        }
        XCTAssertTrue(body.contains("settingsCard(L(.accountSyncSection))"), "liveness: the scan reads the card")
    }
}
