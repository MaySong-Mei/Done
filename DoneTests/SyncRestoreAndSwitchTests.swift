//
//  SyncRestoreAndSwitchTests.swift
//  DoneTests
//
//  Two pre-existing sync bugs (fix/sync-restore-and-toggle):
//
//  1. A merge restore wrote every local row into the baseline as clean —
//     rows the cloud never had, and (before 015) rows whose merged content
//     differs from the cloud's — so no flush ever sent them.
//  2. The master switch turned off and on while a full sync ran: the puller
//     stayed stopped; a delivery during the pass to a table it had passed
//     was dropped; an edit made while the switch was off to a table it had
//     passed was not sent when the switch came back on.
//
//  The restores run through `RestoreCoordinator`, the path the app takes.
//

import XCTest
@testable import Done

/// One device on a fake server: the engine, its stores, its puller, and an
/// `AuthService` holding an injected session whose refresh the transport
/// answers with a new token (a refresh re-runs the session sink).
@MainActor
final class SyncSwitchTestDevice {
    let defaults: UserDefaults
    let scheduler: SyncManualScheduler
    let store: EventStore
    let types: EventTypeTemplateStore
    let skills: SkillInsightStore
    let prefs: AgentPreferenceStore
    let service: SupabaseSyncService
    let puller: SyncPuller
    let auth: AuthService
    private let suite: String
    private let prefsDirectory: URL
    private let shelfDirectory: URL

    init(server: SyncFakeServer, uid: String, start: Date, switchOnAtAttach: Bool) {
        suite = "SyncRestoreAndSwitchTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        scheduler = SyncManualScheduler(start: start)
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        let scratch = FileManager.default.temporaryDirectory
        prefsDirectory = scratch.appendingPathComponent("SyncRestoreAndSwitchTests-prefs-\(UUID().uuidString)", isDirectory: true)
        shelfDirectory = scratch.appendingPathComponent("SyncRestoreAndSwitchTests-shelf-\(UUID().uuidString)", isDirectory: true)
        prefs = AgentPreferenceStore(directoryURL: prefsDirectory)
        service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: defaults,
                                      scheduler: scheduler, environment: .local)
        service.attachStores(eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)
        puller = service.installInbound(shelf: ConflictShelf(directory: shelfDirectory))
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()

        let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
        let session = #"{"access_token":"at-1","refresh_token":"r-1","user_id":"\#(uid)","email":"switch@example.com","expires_at":\#(expiresAt)}"#
        auth = AuthService(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
                           sessionStore: InMemorySessionStore(),
                           transport: { request in
                               guard request.url?.absoluteString.contains("grant_type=refresh_token") == true else {
                                   XCTFail("only a token refresh may go out; got \(request.url?.absoluteString ?? "?")")
                                   throw URLError(.notConnectedToInternet)
                               }
                               let body = #"{"access_token":"at-\#(UUID().uuidString)","refresh_token":"r-\#(UUID().uuidString)","expires_in":3600,"user":{"id":"\#(uid)","email":null}}"#
                               let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!
                               return (Data(body.utf8), http)
                           },
                           launchEnvironment: ["SYNC_DEBUG_SESSION": session], syncEnvironment: .local)
        defaults.set(switchOnAtAttach, forKey: AppSettingsKeys.syncUploadsEnabled)
        service.attach(authService: auth, eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)
    }

    func tearDown() {
        puller.endSession()
        try? FileManager.default.removeItem(at: shelfDirectory)
        try? FileManager.default.removeItem(at: prefsDirectory)
        TestStorage.tearDown(suite)
    }
}

/// The shared fixture: attached with the switch off (so no full sync ran at
/// attach), then the switch on and the puller at head.
@MainActor
class SyncRestoreAndSwitchTestCase: XCTestCase {
    static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    static let writeVerbs: Set<SyncFakeServer.Verb> = [.patch, .insert, .tombstone, .upsert, .delete]
    let uid = "44444444-5555-4666-8777-888888888888"

    var server: SyncFakeServer!
    var device: SyncSwitchTestDevice!

    var service: SupabaseSyncService { device.service }
    var store: EventStore { device.store }
    var puller: SyncPuller { device.puller }
    var defaults: UserDefaults { device.defaults }
    var scheduler: SyncManualScheduler { device.scheduler }
    var debounce: TimeInterval { SupabaseSyncConfig.debounceSeconds }

    struct FixtureFailure: Error, CustomStringConvertible {
        let description: String
    }

    override func setUp() async throws {
        try await super.setUp()
        server = SyncFakeServer(userId: uid)
        device = SyncSwitchTestDevice(server: server, uid: uid, start: Self.t0, switchOnAtAttach: false)
        XCTAssertTrue(device.auth.isSignedIn, "fixture: the injected session signed in")
        defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        puller.beginSession(autoPull: false)
        await puller.pullToHead()
        XCTAssertTrue(service.inboundAtHead, "fixture: the session reached head")
    }

    override func tearDown() async throws {
        server?.holdWhen = nil
        server?.releaseAll()
        device?.tearDown()
        try await super.tearDown()
    }

    func makeEvent(_ title: String, note: String = "") -> Event {
        Event(title: title, note: note,
              timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(1800))],
              createdAt: Self.t0)
    }

    func makeSkill(_ name: String) -> SkillInsight {
        SkillInsight(skillName: name, points: 1, date: Self.t0, eventTitle: name, reasoning: "r")
    }

    func row(_ event: Event) -> [String: Any] {
        service.eventToRow(event, kind: "calendar")
    }

    func hash(_ event: Event) -> String {
        SupabaseSyncService.rowHash(row(event))
    }

    func entry(_ event: Event) -> SyncBaselineEntry? {
        service.baseline.entry(table: "calendar_events", id: event.id.uuidString)
    }

    func onServer(_ event: Event) -> [String: Any]? {
        server.row(table: "events", key: event.id.uuidString)?.data
    }

    /// What the settings UI does (`AgentSettingsView.onChange`).
    func switchOff() {
        defaults.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        service.userDidDisableUploads()
    }

    func switchOn() {
        defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        service.userDidEnableUploads()
    }

    func writes(after index: Int = 0) -> [SyncFakeServer.Request] {
        server.requests.dropFirst(index).filter { Self.writeVerbs.contains($0.verb) }
    }

    func names(_ request: SyncFakeServer.Request, _ id: UUID) -> Bool {
        request.keys.contains { $0.lowercased() == id.uuidString.lowercased() }
    }

    func shelved(_ id: UUID) -> [ConflictShelfEntry] {
        puller.shelf.entries().filter { $0.id.lowercased() == id.uuidString.lowercased() }
    }

    static func without015(_ row: [String: Any]) -> [String: Any] {
        row.filter { !SyncFakeServer.only015Columns.contains($0.key) }
    }

    /// Lets in-process flush tasks run to their end; every gateway call on
    /// the fake server is a main-actor call. Used only after a positive
    /// witness said the work started.
    func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
    }

    /// "Restore from cloud" as the app runs it: fetch, then overwrite, or
    /// merge with `resolution` for the collisions.
    @discardableResult
    func restore(_ strategy: RestoreStrategy, resolution: ConflictResolution = .keepLocal) async throws -> RestoreSnapshot {
        let coordinator = RestoreCoordinator()
        coordinator.configure(syncService: service, eventStore: store, eventTypeStore: device.types,
                              skillStore: device.skills, preferenceStore: device.prefs)
        await coordinator.startFetch()
        guard case .ready(let snapshot) = coordinator.phase else {
            throw FixtureFailure(description: "the restore fetch did not finish: \(coordinator.phase)")
        }
        switch strategy {
        case .cloudOverwritesLocal:
            await coordinator.applyOverwrite()
        case .merge:
            await coordinator.prepareMerge()
            if case .mergeReview = coordinator.phase {
                await coordinator.applyMerge(resolution: resolution)
            }
        }
        guard case .finished = coordinator.phase else {
            throw FixtureFailure(description: "the restore did not finish: \(coordinator.phase)")
        }
        return snapshot
    }
}

// MARK: - 1. The merge restore's baseline

@MainActor
final class SyncMergeRestoreUploadTests: SyncRestoreAndSwitchTestCase {

    /// QA12's scenario through the app's restore: a row made while uploads
    /// were off is still unsent after a merge and goes up when the switch
    /// comes back on. The cloud's rows the device holds as they are send
    /// nothing; the kept-local collision goes out on the cloud's version.
    func testAMergeRestoreLeavesARowTheCloudNeverHadToBeSentWhenTheSwitchComesBackOn() async throws {
        let same = makeEvent("same on both"), kept = makeEvent("kept", note: "v1")
        let seeded = server.seed(table: "events", rows: [row(same), row(kept)])
        await puller.pullToHead()
        XCTAssertNotNil(entry(same)?.seq, "fixture: the device holds the cloud's rows")

        switchOff()
        let offline = makeEvent("made while uploads were off")
        store.addCalendarEvent(offline)
        var mine = kept
        mine.note = "mine"
        store.updateCalendarEvent(mine)
        let cloudSeq = server.writeDirectly(table: "events", key: kept.id.uuidString, data: ["note": "theirs"])
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(writes().isEmpty, "positive control: the switch kept every change on the phone")
        XCTAssertNil(entry(offline), "positive control: the row was never sent")

        let snapshot = try await restore(.merge)
        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == offline.id }, "fixture: the merge kept the local row")
        XCTAssertEqual(snapshot.cloudSeqs[SyncBaselineKey(table: "calendar_events", id: kept.id.uuidString)], cloudSeq)
        XCTAssertNil(entry(offline), "the restore marked a row the cloud never had as uploaded")
        XCTAssertEqual(entry(same), SyncBaselineEntry(hash: hash(same), seq: seeded[same.id.uuidString]),
                       "a row the cloud holds as it is reads clean")
        let before = server.requests.count

        switchOn()
        try await syncEventually("the row made offline reached the cloud") { self.onServer(offline) != nil }
        try await syncEventually("the kept-local row reached the cloud") { self.onServer(kept)?["note"] as? String == "mine" }
        try await settle()

        let later = writes(after: before)
        XCTAssertFalse(later.contains { names($0, same.id) }, "a row the cloud holds as it is was sent again")
        let keptWrites = later.filter { names($0, kept.id) }
        XCTAssertEqual(keptWrites.map(\.verb), [.patch])
        XCTAssertEqual(keptWrites.first?.baseSeq, cloudSeq, "the kept-local row is sent on the cloud's version")
    }

    /// The switch on throughout: a row still in its debounce when the merge
    /// runs is sent by that debounce. The kept-local collision is sent only
    /// on the version the snapshot held, so a cloud edit made after the
    /// snapshot is never overwritten unseen: the PATCH answers `[]`, and
    /// the pull puts the later edit on this device's shelf. Every version
    /// written after it descends from it.
    func testARowInItsDebounceAtAMergeIsSent_andTheKeptLocalRowCannotOverwriteALaterCloudEditUnseen() async throws {
        let kept = makeEvent("kept", note: "v1")
        server.seed(table: "events", rows: [row(kept)])
        await puller.pullToHead()
        let pending = makeEvent("still in its debounce")
        store.addCalendarEvent(pending)
        var mine = kept
        mine.note = "mine"
        store.updateCalendarEvent(mine)
        let snapshotSeq = server.writeDirectly(table: "events", key: kept.id.uuidString, data: ["note": "theirs"])
        XCTAssertTrue(writes().isEmpty, "fixture: the debounce has not delivered")

        try await restore(.merge)
        XCTAssertNil(entry(pending), "the restore marked a row still in its debounce as uploaded")
        let laterSeq = server.writeDirectly(table: "events", key: kept.id.uuidString, data: ["note": "after the snapshot"])
        let laterVersion = try XCTUnwrap(server.versionId(table: "events", key: kept.id.uuidString))
        let before = server.requests.count

        scheduler.advance(by: debounce)
        try await syncEventually("the pending row reached the cloud") { self.onServer(pending) != nil }
        try await syncEventually("the later cloud edit reached the shelf") {
            self.shelved(kept.id).contains { $0.row["note"] as? String == "after the snapshot" }
        }
        try await settle()

        let keptPatches = writes(after: before).filter { $0.verb == .patch && names($0, kept.id) }
        XCTAssertEqual(keptPatches.first?.baseSeq, snapshotSeq, "the first send is conditional on the snapshot's version")
        let overwrites = server.versions(table: "events", key: kept.id.uuidString).filter { $0.seq > laterSeq }
        XCTAssertTrue(overwrites.allSatisfy { $0.parentVersionId == laterVersion },
                      "a version was written over the later cloud edit without it as parent")
    }

    /// A row this device uploaded, edited while uploads were off, that
    /// another device deleted meanwhile. The snapshot does not carry it, the
    /// merge keeps the local copy, and the restore must leave its entry as
    /// the version this device last sent: the pull then meets a dirty row,
    /// shelves the edit and removes the row. Marked clean, the edit was
    /// removed with no trace. Nothing writes the deleted row back.
    func testAnOfflineEditToARowAnotherDeviceDeletedIsShelvedAfterAMerge_neitherDroppedNorResurrected() async throws {
        let gone = makeEvent("deleted elsewhere", note: "v1")
        server.seed(table: "events", rows: [row(gone)])
        await puller.pullToHead()
        let uploaded = try XCTUnwrap(entry(gone))

        switchOff()
        var edited = gone
        edited.note = "edited offline"
        store.updateCalendarEvent(edited)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(writes().isEmpty, "positive control: the edit stayed on the phone")
        server.tombstoneDirectly(table: "events", key: gone.id.uuidString)

        let snapshot = try await restore(.merge)
        XCTAssertFalse(snapshot.calendarEvents.contains { $0.id == gone.id }, "fixture: the cloud no longer carries it")
        XCTAssertEqual(store.rawCalendarEvents.first { $0.id == gone.id }?.note, "edited offline", "fixture: the merge kept it")
        XCTAssertEqual(entry(gone), uploaded, "the restore recorded the offline edit as uploaded")
        let before = server.requests.count

        switchOn()
        try await syncEventually("the pull applied the delete") { !self.store.rawCalendarEvents.contains { $0.id == gone.id } }
        try await settle()

        XCTAssertEqual(shelved(gone.id).compactMap { $0.row["note"] as? String }, ["edited offline"],
                       "the offline edit was removed without a shelf line")
        XCTAssertTrue(server.isTombstoned(table: "events", key: gone.id.uuidString))
        XCTAssertFalse(writes(after: before).contains { names($0, gone.id) }, "the deleted row was written again")
    }

    /// "Cloud overwrites local" keeps its replay: every local row reads
    /// clean. Over a cloud holding one event and no types, settings,
    /// preferences or conversations, the device keeps the cloud's event,
    /// falls back to the built-in types and keeps its own settings, and the
    /// switch coming back on sends nothing. (Green before the fix as well:
    /// this pins that the overwrite is unchanged. A merge — or an overwrite
    /// whose strategy does not reach the replay — sends the types, settings,
    /// preferences and conversations the cloud never had.)
    func testAnOverwriteRestoreStillSendsNothingTheCloudDidNotHave() async throws {
        let cloudRow = makeEvent("the cloud's")
        server.seed(table: "events", rows: [row(cloudRow)])
        switchOff()
        let offline = makeEvent("made while uploads were off")
        store.addCalendarEvent(offline)
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        scheduler.advance(by: SupabaseSyncConfig.settingsDebounceSeconds)
        try await settle()
        XCTAssertTrue(writes().isEmpty, "positive control: nothing left the phone")

        try await restore(.cloudOverwritesLocal)
        XCTAssertEqual(store.rawCalendarEvents.map(\.id), [cloudRow.id], "fixture: the cloud's rows replaced the local ones")
        XCTAssertFalse(device.types.templates.isEmpty, "fixture: a cloud without types leaves the built-in ones")
        let before = server.requests.count

        switchOn()
        try await syncEventually("the puller reached head") { self.puller.active && self.service.inboundAtHead }
        try await settle()
        try await settle()
        XCTAssertEqual(writes(after: before).map { "\($0.verb) \($0.table)" }, [], "an overwrite sent what the cloud did not have")

        // Positive control: the engine is live — an edit goes out.
        var edited = cloudRow
        edited.note = "edited after the restore"
        store.updateCalendarEvent(edited)
        scheduler.advance(by: debounce)
        try await syncEventually("the edit reached the cloud") { self.onServer(cloudRow)?["note"] as? String == "edited after the restore" }
        XCTAssertEqual(writes(after: before).map { "\($0.verb) \($0.table)" }, ["patch events"])
    }

    /// Before migration 015 (the fallback: merge upserts, no seqs). After a
    /// merge, a skill and an event made while uploads were off go up, the
    /// kept-local collision goes up with the local content, and the row the
    /// restore brought from the cloud is not sent back: it is compared as
    /// the fallback sends it, without the 015 columns.
    func testBefore015AMergeRestoreUpsertsWhatTheCloudLacksAndNothingItHolds() async throws {
        server.pre015 = true
        await puller.pullToHead()
        XCTAssertTrue(service.outboundFallback, "fixture: the engine took the fallback")
        let kept = makeEvent("kept", note: "v1")
        store.addCalendarEvent(kept)
        scheduler.advance(by: debounce)
        try await syncEventually("kept upserted") { self.onServer(kept) != nil }
        try await settle()
        server.writeDirectly(table: "events", key: kept.id.uuidString, data: ["note": "cloud"])
        let theirs = makeEvent("theirs")
        server.writeDirectly(table: "events", key: theirs.id.uuidString, data: Self.without015(row(theirs)))

        switchOff()
        var local = kept
        local.note = "local"
        store.updateCalendarEvent(local)
        let offline = makeEvent("made while uploads were off")
        store.addCalendarEvent(offline)
        let skill = makeSkill("made while uploads were off")
        device.skills.add(skill)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertNil(server.row(table: "skill_insights", key: skill.id.uuidString), "positive control: the skill stayed on the phone")
        XCTAssertNil(onServer(offline))

        let snapshot = try await restore(.merge)
        XCTAssertTrue(snapshot.cloudSeqs.isEmpty, "fixture: a server before 015 hands out no seq")
        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == theirs.id }, "fixture: the merge brought their row")
        let before = server.requests.count

        switchOn()
        try await syncEventually("the offline skill reached the cloud") {
            self.server.row(table: "skill_insights", key: skill.id.uuidString) != nil
        }
        try await syncEventually("the offline event reached the cloud") { self.onServer(offline) != nil }
        try await syncEventually("the kept-local content reached the cloud") { self.onServer(kept)?["note"] as? String == "local" }
        try await settle()
        XCTAssertFalse(writes(after: before).contains { names($0, theirs.id) }, "the row the restore brought from the cloud was sent back")
    }

    /// The one-row tables follow the rule: over a cloud with no settings,
    /// preferences or conversations row, a merge leaves this device's rows
    /// as they were — never sent — and the switch coming back on sends them.
    /// Marked clean, the settings stayed on the phone until they changed.
    func testAMergeOverACloudWithoutTheOneRowTablesLeavesThemToBeSent() async throws {
        switchOff()
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        scheduler.advance(by: SupabaseSyncConfig.settingsDebounceSeconds)
        try await settle()
        XCTAssertNil(service.baseline.settings, "positive control: the settings were never sent")
        server.seed(table: "events", rows: [row(makeEvent("the cloud's"))])

        try await restore(.merge)
        XCTAssertNil(service.baseline.settings, "the restore recorded settings the cloud never had as uploaded")
        XCTAssertNil(service.baseline.entry(table: "agent_preferences", id: uid))
        XCTAssertNil(service.baseline.entry(table: "agent_conversations", id: uid))

        switchOn()
        try await syncEventually("the settings reached the cloud") { self.server.row(table: "user_settings", key: self.uid) != nil }
        let sent = server.row(table: "user_settings", key: uid)?.data["settings"] as? [String: Any]
        XCTAssertEqual(sent?[AppSettingsKeys.showTimerBanner] as? Bool, true)
        try await syncEventually("the preferences reached the cloud") { self.server.row(table: "agent_preferences", key: self.uid) != nil }
        try await syncEventually("the conversations reached the cloud") { self.server.row(table: "agent_conversations", key: self.uid) != nil }
    }

    /// Before 015 the settings row has no seq: after a merge its baseline is
    /// the cloud blob's keys, so the key the merge kept local reads dirty
    /// and the fallback sends it.
    func testBefore015AMergeTakesTheCloudsSettingsBlobAsTheBaseline() async throws {
        server.pre015 = true
        await puller.pullToHead()
        XCTAssertTrue(service.outboundFallback, "fixture: the engine took the fallback")
        server.seed(table: "user_settings", rows: [["user_id": uid, "settings": [AppSettingsKeys.showTimerBanner: false]]])
        let snapshot = try await service.fetchRestoreSnapshot()
        XCTAssertNil(snapshot.cloudSeqs[SupabaseSyncService.restoreSingletonKey("user_settings")], "fixture: no seq before 015")
        XCTAssertEqual(snapshot.settings?[AppSettingsKeys.showTimerBanner] as? Bool, false)
        // The merge kept the local value of the colliding key.
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)

        service.markRestoreCompleted(eventStore: store, eventTypeStore: device.types, skillStore: device.skills,
                                     snapshot: snapshot)
        await service.syncSettings()

        let upsert = try XCTUnwrap(server.requests(.upsert, table: "user_settings").first, "the kept-local key was recorded as uploaded")
        let body = try XCTUnwrap((upsert.body as? [[String: Any]])?.first?["settings"] as? [String: Any])
        XCTAssertEqual(body[AppSettingsKeys.showTimerBanner] as? Bool, true)
    }
}

// MARK: - 2. The master switch during a full sync

@MainActor
final class SyncSwitchDuringFullSyncTests: SyncRestoreAndSwitchTestCase {

    /// A full sync parked on its skill_insights POST. `sentByThePass` was
    /// added before it started and not delivered (the scheduler did not
    /// move), so the pass itself sent it: the calendar table is behind it.
    func parkAPass(startedBy start: () async -> Void) async throws {
        let sentByThePass = makeEvent("sent by the pass")
        store.addCalendarEvent(sentByThePass)
        device.skills.add(makeSkill("parks the pass"))
        server.holdWhen = { verb, table in verb == .insert && table == "skill_insights" }
        await start()
        try await syncEventually("the pass is parked on skills") { self.server.heldCount == 1 }
        XCTAssertNotNil(onServer(sentByThePass), "positive control: the pass sent the calendar table before it parked")
    }

    /// The parked POST answered; the pass runs on to its end.
    func releaseThePass() async throws {
        server.holdWhen = nil
        server.releaseAll()
        try await syncEventually("the parked skill row landed") {
            self.server.heldCount == 0
                && self.service.baseline.entries(table: "skill_insights").values.allSatisfy { $0.seq != nil }
        }
        try await settle()
        try await settle()
    }

    /// (a) Off then on while a pass runs: the puller runs again, and another
    /// device's edit reaches this phone.
    func testThePullerRunsAgainWhenTheSwitchComesBackOnDuringAFullSync() async throws {
        try await parkAPass { self.service.userDidEnableUploads() }
        XCTAssertTrue(puller.active, "fixture: the puller runs")
        switchOff()
        XCTAssertFalse(puller.active, "positive control: the switch stopped the puller")
        switchOn()
        XCTAssertTrue(puller.active, "the switch is on and nothing pulls")
        try await releaseThePass()

        let theirs = makeEvent("another device's")
        server.writeDirectly(table: "events", key: theirs.id.uuidString, data: row(theirs))
        await puller.pullToHead()
        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == theirs.id }, "another device's change never reached this phone")
    }

    /// (b) A delivery while the pass runs, to a table it has passed: owed,
    /// and sent once when the pass ends. A chain reaching head meanwhile
    /// leaves the owed tables to the pass: the skills table it has in
    /// flight is owed too (its delivery came in the same turn), and is not
    /// sent a second time beside it.
    func testAnEditToATableTheFullSyncHasPassedIsSentWhenItEnds() async throws {
        try await parkAPass { self.service.userDidEnableUploads() }
        let edit = makeEvent("edited during the pass")
        store.addCalendarEvent(edit)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertNil(onServer(edit), "positive control: the delivery came while the pass was parked")
        let pulls = server.requests(.pull).count
        puller.requestPull(reason: "doorbell")
        try await syncEventually("a chain ran") { self.server.requests(.pull).count > pulls }
        try await settle()
        XCTAssertEqual(server.heldCount, 1, "a chain at head sent the table the pass has in flight")

        try await releaseThePass()
        try await syncEventually("the edit reached the cloud") { self.onServer(edit) != nil }
        try await settle()
        XCTAssertEqual(server.requests(.insert, table: "events").filter { names($0, edit.id) }.count, 1, "sent more than once")
        XCTAssertEqual(server.requests(.insert, table: "skill_insights").count, 1, "the parked table was sent twice")
    }

    /// (b) without any toggling: the session sink runs a full sync on every
    /// `$session` emission — a token refresh, the return to the foreground —
    /// and with the puller at head that pass really sends. An edit delivered
    /// while it runs, to a table it has passed, is sent when it ends.
    func testAnEditDuringTheFullSyncATokenRefreshStartsIsSentWhenItEnds() async throws {
        let tokenBefore = device.auth.accessToken
        try await parkAPass { await self.device.auth.forceRefreshToken() }
        XCTAssertNotEqual(device.auth.accessToken, tokenBefore, "positive control: the refresh installed a new session")
        let edit = makeEvent("edited during the refresh's pass")
        store.addCalendarEvent(edit)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertNil(onServer(edit), "positive control: the delivery came while the pass was parked")

        try await releaseThePass()
        try await syncEventually("the edit reached the cloud") { self.onServer(edit) != nil }
    }

    /// (c) The switch off while a pass runs, an edit to a table it has
    /// passed (refused by the switch, unflagged by design), the switch on
    /// again before the pass ends: the pass runs once more and sends it.
    func testAnEditMadeWhileTheSwitchWasOffIsSentWhenItComesBackOnDuringAFullSync() async throws {
        try await parkAPass { self.service.userDidEnableUploads() }
        switchOff()
        let offline = makeEvent("edited while the switch was off")
        store.addCalendarEvent(offline)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertNil(entry(offline), "positive control: the switch refused it")
        XCTAssertFalse(service.needsFlush.contains("calendar_events"), "positive control: a refusal by the switch is not flagged")

        switchOn()
        try await releaseThePass()
        try await syncEventually("the edit made while the switch was off reached the cloud") { self.onServer(offline) != nil }
    }

    /// From off: on, off, on within one turn — before the pass's task has
    /// run — runs one pass at a time, not two side by side.
    func testTogglingTheSwitchWithinOneTurnRunsOnePassAtATime() async throws {
        switchOff()
        let offline = makeEvent("made while uploads were off")
        store.addCalendarEvent(offline)
        let skill = makeSkill("made while uploads were off")
        device.skills.add(skill)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(writes().isEmpty, "positive control: nothing left the phone")
        server.holdWhen = { verb, table in verb == .insert && table == "skill_insights" }

        switchOn()
        switchOff()
        switchOn()
        try await syncEventually("a skills POST is parked") { self.server.heldCount >= 1 }
        try await settle()
        XCTAssertEqual(server.heldCount, 1, "two passes sent the same table side by side")
        XCTAssertTrue(puller.active)

        try await releaseThePass()
        try await syncEventually("the offline row reached the cloud") { self.onServer(offline) != nil }
        XCTAssertEqual(server.requests(.insert, table: "skill_insights").count, 1, "the skill row was sent twice")
    }

    /// Flipped repeatedly while a pass is parked: the puller follows the
    /// switch's last position, no second pass starts beside the parked one,
    /// and once the switch ends off the pass sends nothing more and stops.
    /// On again, a fresh pass sends what the stopped one never reached.
    func testTheSwitchFlippedRepeatedlyDuringAFullSync_thePullerAndThePassFollowItsLastPosition() async throws {
        try await parkAPass { self.service.userDidEnableUploads() }
        switchOff()
        switchOn()
        switchOff()
        switchOn()
        XCTAssertTrue(puller.active, "the switch ended on and nothing pulls")
        try await settle()
        XCTAssertEqual(server.heldCount, 1, "a second pass started beside the parked one")

        switchOff()
        XCTAssertFalse(puller.active, "the switch ended off and the puller runs")
        let writesBefore = writes().count
        try await releaseThePass()
        XCTAssertEqual(writes().count, writesBefore, "the pass went on writing with the switch off")
        XCTAssertNil(server.row(table: "user_settings", key: uid), "positive control: the pass had not reached the settings")

        switchOn()
        XCTAssertTrue(puller.active)
        try await syncEventually("the settings the stopped pass never reached went up") {
            self.server.row(table: "user_settings", key: self.uid) != nil
        }
        XCTAssertEqual(server.requests(.insert, table: "skill_insights").count, 1, "the skill row was sent twice")
    }

    /// Evidence, not a regression test (green before the fix as well): the
    /// cold-launch full sync cannot drop a delivery. The session sink starts
    /// the puller before the pass, so I1 holds every table — each is flagged
    /// and the pass ends in the turn it starts — and the chain's flush at
    /// head reads the live arrays. Here the launch pull is parked, as a slow
    /// network leaves it, and an edit delivered meanwhile is sent at head.
    func testAColdLaunchFullSyncHoldsEveryTableForTheChainAndAnEditMeanwhileIsSentAtHead() async throws {
        let launchServer = SyncFakeServer(userId: uid)
        launchServer.holdWhen = { verb, _ in verb == .pull }
        let launch = SyncSwitchTestDevice(server: launchServer, uid: uid, start: Self.t0, switchOnAtAttach: true)
        defer {
            launchServer.holdWhen = nil
            launchServer.releaseAll()
            launch.tearDown()
        }
        XCTAssertTrue(launch.puller.active, "fixture: the session sink started the puller")
        try await syncEventually("the launch pull is parked") { launchServer.heldCount == 1 }
        try await settle()
        XCTAssertFalse(launch.service.inboundAtHead, "positive control: I1 is closed while the pull is out")
        XCTAssertEqual(Set(launch.service.needsFlush), Set(SupabaseSyncService.flushTables),
                       "the launch pass flagged every table for the chain")

        let edit = makeEvent("edited right after launch")
        launch.store.addCalendarEvent(edit)
        launch.scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(launchServer.requests.filter { Self.writeVerbs.contains($0.verb) }.isEmpty, "nothing is written before head")

        launchServer.holdWhen = nil
        launchServer.releaseAll()
        try await syncEventually("the edit reached the cloud at head") {
            launchServer.row(table: "events", key: edit.id.uuidString) != nil
        }
    }
}
