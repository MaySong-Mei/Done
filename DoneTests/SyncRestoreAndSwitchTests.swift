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
//     passed was not sent when the switch came back on. The same through
//     the session: an edit made while signed out during a pass was not sent
//     after the sign-in.
//
//  The restores run through `RestoreCoordinator`, the path the app takes,
//  except the pre-015 settings test, which calls `markRestoreCompleted`
//  directly (the coordinator writes a restored settings blob into
//  `UserDefaults.standard`, not the engine's suite). The pre-015 tests use
//  the fake server's pre-015 mode, which answers the restore fetch; a real
//  server before 015 refuses it (`fetchAllQuery` filters on `deleted_at`
//  and orders by `seq`), so they pin the replay's guard, not a live path.
//

import XCTest
import Combine
import QuartzCore
@testable import Done

/// One device on a fake server: the engine, its stores, its puller, and an
/// `AuthService` holding an injected session whose refresh the transport
/// answers with a new token (a refresh re-runs the session sink). `gateway`
/// replaces the server's own connection (a router between two accounts).
/// `relaunching` opens the suite and storage of an earlier device instead
/// of fresh ones — the same phone after a relaunch, its files and baseline
/// as that device left them; `catalog` is the event-type catalog the new
/// type store reads (one staged unreadable, say).
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
    let suite: String
    private let prefsDirectory: URL
    private let shelfDirectory: URL

    init(server: SyncFakeServer, gateway: SyncGateway? = nil, uid: String, start: Date, switchOnAtAttach: Bool,
         relaunching earlier: SyncSwitchTestDevice? = nil, catalog: EventTypeCatalog? = nil) {
        suite = earlier?.suite ?? "SyncRestoreAndSwitchTests-\(UUID().uuidString)"
        let location = earlier == nil ? TestStorage.reset(suite) : EventStorageLocation.isolated(name: suite)
        defaults = UserDefaults(suiteName: suite)!
        scheduler = SyncManualScheduler(start: start)
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        if let catalog { EventTypeCatalog.register(catalog, for: defaults) }
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        let scratch = FileManager.default.temporaryDirectory
        prefsDirectory = scratch.appendingPathComponent("SyncRestoreAndSwitchTests-prefs-\(UUID().uuidString)", isDirectory: true)
        shelfDirectory = scratch.appendingPathComponent("SyncRestoreAndSwitchTests-shelf-\(UUID().uuidString)", isDirectory: true)
        prefs = AgentPreferenceStore(directoryURL: prefsDirectory)
        service = SupabaseSyncService(gateway: gateway ?? server.connection(), userId: uid, defaults: defaults,
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

    /// An interactive sign-in as `uid` (the injected-session path).
    @discardableResult
    func signIn(_ uid: String) -> Bool {
        let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
        let session = #"{"access_token":"at-\#(UUID().uuidString)","refresh_token":"r-\#(UUID().uuidString)","user_id":"\#(uid)","email":"switch@example.com","expires_at":\#(expiresAt)}"#
        return auth.adoptInjectedSessionIfPresent(launchEnvironment: ["SYNC_DEBUG_SESSION": session], syncEnvironment: .local)
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

    /// The session instead of the switch: signed out and back in to the same
    /// account while a pass is parked. An edit made while signed out is
    /// flagged by nothing (there is no session to owe it to) and the pass
    /// had already read its table, so the new session owes a rerun.
    func testAnEditMadeWhileSignedOutDuringAFullSyncIsSentAfterTheSameAccountSignsBackIn() async throws {
        try await parkAPass { self.service.userDidEnableUploads() }
        device.auth.signOut()
        XCTAssertEqual(service.userId, "", "fixture: the session ended")
        let signedOut = makeEvent("made while signed out")
        store.addCalendarEvent(signedOut)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(service.needsFlush.isEmpty, "positive control: nothing flagged the edit")

        XCTAssertTrue(device.signIn(uid), "fixture: signed in again")
        XCTAssertEqual(server.heldCount, 1, "fixture: the pass is still parked")
        try await releaseThePass()
        try await syncEventually("the edit made while signed out reached the cloud") { self.onServer(signedOut) != nil }
    }

    /// A switch to another account while a pass of the first is parked
    /// (the account card's "Switch Anyway": the erase, then the new
    /// session). The pass stops at its next table instead of reading on for
    /// the new account, the new account gets a pass of its own, and nothing
    /// of the first account reaches the second's cloud.
    func testASwitchToAnotherAccountDuringAFullSyncStopsThePass_andTheNewAccountGetsAPassOfItsOwn() async throws {
        let uidB = "55555555-6666-4777-8888-999999999999"
        let cloudA = SyncFakeServer(userId: uid), cloudB = SyncFakeServer(userId: uidB)
        let router = SyncAccountRouter(cloudA)
        let phone = SyncSwitchTestDevice(server: cloudA, gateway: router, uid: uid, start: Self.t0, switchOnAtAttach: false)
        defer {
            cloudA.holdWhen = nil
            cloudA.releaseAll()
            phone.tearDown()
        }
        phone.defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        phone.puller.beginSession(autoPull: false)
        await phone.puller.pullToHead()
        // What the app's eraser does, as far as the engine can see it.
        phone.service.ownerSwitchEraser = { [unowned phone] in
            phone.store.clearAllLocalData()
            phone.skills.clearAll()
            SupabaseSyncService.wipeAllPersistedHashes(phone.defaults)
            phone.puller.shelf.wipe()
            phone.defaults.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        }
        let rowA = makeEvent("account A's"), skillA = makeSkill("account A's")
        phone.store.addCalendarEvent(rowA)
        phone.skills.add(skillA)
        cloudA.holdWhen = { verb, table in verb == .insert && table == "skill_insights" }
        phone.service.userDidEnableUploads()
        try await syncEventually("A's pass is parked on skills") { cloudA.heldCount == 1 }
        XCTAssertNotNil(cloudA.row(table: "events", key: rowA.id.uuidString), "positive control: A's pass read the calendar for A")
        // The trail is process-wide, lives across runs and rotates, dropping
        // its older file: the count below starts from an empty trail.
        DiagnosticTrail.clear()
        let requestsToABefore = cloudA.requests.count

        phone.auth.signOut()
        router.current = cloudB
        XCTAssertTrue(phone.signIn(uidB), "fixture: B signed in")
        if case .blocked = phone.service.ownerState { phone.service.switchAnyway() }
        XCTAssertEqual(phone.service.ownerState, .active(uid: uidB), "fixture: the device switched to B")
        let rowB = makeEvent("account B's")
        phone.store.addCalendarEvent(rowB)
        cloudA.holdWhen = nil
        cloudA.releaseAll()

        try await syncEventually("B's own pass sent B's row") { cloudB.row(table: "events", key: rowB.id.uuidString) != nil }
        try await settle()
        XCTAssertEqual(Self.trailLines("sync.fullsync.stopped reason=account_changed"), 1,
                       "A's pass read on into its next table for B")
        XCTAssertEqual(cloudA.requests.count, requestsToABefore, "A's cloud was written after the switch")
        let sentToB = cloudB.requests.filter { Self.writeVerbs.contains($0.verb) }
        let bodiesToB = sentToB.compactMap { $0.body as? [[String: Any]] }.flatMap { $0 }
            + sentToB.compactMap { $0.body as? [String: Any] }
        XCTAssertFalse(bodiesToB.isEmpty, "positive control: B's cloud was written")
        XCTAssertEqual(Set(bodiesToB.compactMap { $0["user_id"] as? String }), [uidB], "a row went to B's cloud under another account")
        let idsA = Set([rowA.id.uuidString, skillA.id.uuidString].map { $0.lowercased() })
        XCTAssertFalse(sentToB.contains { !idsA.isDisjoint(with: $0.keys.map { $0.lowercased() }) }, "A's rows reached B's cloud")
    }

    /// With the switch off, a token refresh during a pass took the session
    /// sink's switch-off branch, which marked the full sync done while the
    /// pass still ran. Back on, a delivery to the row the pass has in
    /// flight went to its own flush beside the pass and sent that row a
    /// second time. It stays owed to the pass until the pass ends.
    func testWithTheSwitchOffATokenRefreshDuringAFullSyncLeavesTheNextDeliveryOwedToThePass() async throws {
        let inFlight = makeEvent("in flight", note: "v1")
        store.addCalendarEvent(inFlight)
        server.holdWhen = { verb, table in verb == .insert && table == "events" }
        service.userDidEnableUploads()
        try await syncEventually("the pass is parked on its calendar POST") { self.server.heldCount == 1 }
        switchOff()
        let tokenBefore = device.auth.accessToken
        await device.auth.forceRefreshToken()
        XCTAssertNotEqual(device.auth.accessToken, tokenBefore, "positive control: the refresh re-published the session")
        switchOn()

        var edited = inFlight
        edited.note = "v2"
        store.updateCalendarEvent(edited)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(service.needsFlush.contains("calendar_events"), "the delivery was not owed to the running pass")
        XCTAssertEqual(server.heldCount, 1, "the delivery sent the row beside the pass")

        server.holdWhen = nil
        server.releaseAll()
        try await syncEventually("the edit reached the cloud") { self.onServer(inFlight)?["note"] as? String == "v2" }
        try await settle()
        XCTAssertEqual(server.requests(.insert, table: "events").filter { names($0, inFlight.id) }.count, 1,
                       "the row was POSTed twice")
    }

    /// A token refresh is not a new session: during a pass it owes no second
    /// pass, which would hash every table again on the main thread. (Green
    /// before this change too: it pins the choice.)
    func testATokenRefreshDuringAFullSyncOwesNoSecondPass() async throws {
        let displaced = FollowerTiming.recorder
        let recorder = FollowerTimingRecorder()
        FollowerTiming.recorder = recorder
        defer { FollowerTiming.recorder = displaced }
        try await parkAPass { self.service.userDidEnableUploads() }
        XCTAssertEqual(recorder.dailySnapshot()[.syncCalendarBuild].count, 1, "fixture: the pass read the calendar once")
        let tokenBefore = device.auth.accessToken
        await device.auth.forceRefreshToken()
        XCTAssertNotEqual(device.auth.accessToken, tokenBefore, "positive control: the refresh re-published the session")

        try await releaseThePass()
        try await settle()
        XCTAssertEqual(recorder.dailySnapshot()[.syncCalendarBuild].count, 1, "a token refresh ran a second pass")
    }

    static func trailLines(_ text: String) -> Int {
        DiagnosticTrail.combinedText().split(separator: "\n").filter { $0.contains(text) }.count
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

// MARK: - 3. The restore's loading view goes up before the work

/// The coordinator's frame wait, held by the test: it logs and counts its
/// entries and parks the FIRST restore there until released. A later
/// entry — a second apply — passes straight through, so it shows up in
/// what the test reads instead of hanging the run.
@MainActor
final class HeldLoadingFrame {
    private(set) var entries = 0
    var onEnter: () -> Void = {}
    let entered: XCTestExpectation
    private var parked: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        entries += 1
        onEnter()
        guard entries == 1 else { return }
        await withCheckedContinuation { continuation in
            parked = continuation
            entered.fulfill()
        }
    }

    func release() {
        parked?.resume()
        parked = nil
    }
}

/// Counts display refreshes while it runs.
@MainActor
final class DisplayRefreshCounter: NSObject {
    private(set) var count = 0
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        count += 1
    }
}

/// "正在恢复…" has to be on the screen before the restore's synchronous work
/// holds the main thread. The coordinator publishes `.applying`, then waits
/// for a frame, then mutates the stores — on each of the four ways into an
/// apply. These tests hold that wait and look at what has happened by then;
/// the last one runs the app's own wait and counts the display refreshes
/// that pass before the first store change.
@MainActor
final class RestoreLoadingFrameTests: SyncRestoreAndSwitchTestCase {
    private var log: [String] = []
    private var bag: Set<AnyCancellable> = []

    override func tearDown() async throws {
        bag.removeAll()
        try await super.tearDown()
    }

    private static func name(_ phase: RestoreCoordinator.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .fetching: return "fetching"
        case .ready: return "ready"
        case .mergeReview: return "mergeReview"
        case .perRowReview: return "perRowReview"
        case .applying: return "applying"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }

    private func makeCoordinator(waitForLoadingFrame: @escaping @MainActor () async -> Void) -> RestoreCoordinator {
        let coordinator = RestoreCoordinator(waitForLoadingFrame: waitForLoadingFrame)
        coordinator.configure(syncService: service, eventStore: store, eventTypeStore: device.types,
                              skillStore: device.skills, preferenceStore: device.prefs)
        return coordinator
    }

    private func fetched(_ coordinator: RestoreCoordinator) async throws {
        await coordinator.startFetch()
        guard case .ready = coordinator.phase else {
            throw FixtureFailure(description: "the restore fetch did not finish: \(coordinator.phase)")
        }
    }

    private func holds(_ event: Event) -> Bool {
        store.rawCalendarEvents.contains { $0.id == event.id }
    }

    /// One way into an apply, from the phase `reach` leaves it in, held at
    /// the frame wait. While held: the loading phase is published, nothing
    /// in the store has changed, and every entry point — a second tap on any
    /// button — starts nothing. Released: the store changes, then the
    /// restore finishes.
    private func assertTheLoadingFrameComesFirst(
        _ path: String,
        strategy: RestoreStrategy,
        incoming: Event?,
        reach: (RestoreCoordinator) async throws -> Void,
        apply: @escaping (RestoreCoordinator) async -> Void
    ) async throws {
        let frame = HeldLoadingFrame(entered: expectation(description: "\(path): the frame wait was entered"))
        let coordinator = makeCoordinator { await frame.wait() }
        try await fetched(coordinator)
        try await reach(coordinator)
        if let incoming { XCTAssertFalse(holds(incoming), "fixture: the cloud's row is not on this device yet") }

        coordinator.$phase.dropFirst().sink { [unowned self] in self.log.append("phase " + Self.name($0)) }.store(in: &bag)
        store.objectWillChange.sink { [unowned self] in self.log.append("store") }.store(in: &bag)
        frame.onEnter = { [unowned self] in self.log.append("frame") }

        let run = Task { await apply(coordinator) }
        await fulfillment(of: [frame.entered], timeout: 5)
        guard frame.entries == 1 else {
            return XCTFail("\(path): the apply never reached the frame wait: \(coordinator.phase), \(log)")
        }

        XCTAssertEqual(coordinator.phase, .applying(strategy), "\(path): the loading phase is published before the wait")
        XCTAssertEqual(log, ["phase applying", "frame"], "\(path): by the wait, the loading phase and nothing else")
        if let incoming { XCTAssertFalse(holds(incoming), "\(path): the store changed before the loading frame") }

        await coordinator.applyOverwrite()
        await coordinator.prepareMerge()
        await coordinator.applyMerge(resolution: .keepCloud)
        coordinator.enterPerRowReview()
        await coordinator.applyPerRow()
        XCTAssertEqual(frame.entries, 1, "\(path): a second tap during the wait started a second apply")
        XCTAssertEqual(coordinator.phase, .applying(strategy), "\(path): a second tap moved the phase")
        XCTAssertEqual(log, ["phase applying", "frame"], "\(path): a second tap changed something")

        frame.release()
        await run.value
        guard case .finished(_, strategy, _) = coordinator.phase else {
            return XCTFail("\(path): the restore did not finish: \(coordinator.phase)")
        }
        XCTAssertEqual(Array(log.prefix(3)), ["phase applying", "frame", "store"],
                       "\(path): the store changes after the wait, first thing")
        XCTAssertEqual(log.filter { $0.hasPrefix("phase") }, ["phase applying", "phase finished"], "\(path)")
        XCTAssertEqual(log.last, "phase finished", "\(path)")
        if let incoming { XCTAssertTrue(holds(incoming), "\(path): the restore landed the cloud's row") }
    }

    private func seedIncoming() -> Event {
        let incoming = makeEvent("only in the cloud")
        server.seed(table: "events", rows: [row(incoming)])
        return incoming
    }

    func testOverwrite_theLoadingFrameComesBeforeTheStoreChanges() async throws {
        try await assertTheLoadingFrameComesFirst(
            "overwrite", strategy: .cloudOverwritesLocal, incoming: seedIncoming(),
            reach: { _ in },
            apply: { await $0.applyOverwrite() })
    }

    func testMergeFromTheReview_theLoadingFrameComesBeforeTheStoreChanges() async throws {
        try await assertTheLoadingFrameComesFirst(
            "merge", strategy: .merge, incoming: seedIncoming(),
            reach: { coordinator in
                await coordinator.prepareMerge()
                guard case .mergeReview = coordinator.phase else {
                    throw FixtureFailure(description: "a cloud-only row leaves something to review: \(coordinator.phase)")
                }
            },
            apply: { await $0.applyMerge(resolution: .keepLocal) })
    }

    func testPerRow_theLoadingFrameComesBeforeTheStoreChanges() async throws {
        try await assertTheLoadingFrameComesFirst(
            "per-row", strategy: .merge, incoming: seedIncoming(),
            reach: { coordinator in
                await coordinator.prepareMerge()
                coordinator.enterPerRowReview()
                guard case .perRowReview = coordinator.phase else {
                    throw FixtureFailure(description: "the per-row review did not open: \(coordinator.phase)")
                }
            },
            apply: { await $0.applyPerRow() })
    }

    /// `prepareMerge` with nothing to review applies directly: the cloud
    /// holds exactly what this device holds, its event types included.
    func testMergeWithNothingToReview_theLoadingFrameComesBeforeTheStoreChanges() async throws {
        let same = makeEvent("on both, the same")
        server.seed(table: "events", rows: [row(same)])
        server.seed(table: "event_types", rows: device.types.templates.map(service.eventTypeToRow))
        await puller.pullToHead()
        XCTAssertTrue(holds(same), "fixture: the device holds the cloud's row")
        try await assertTheLoadingFrameComesFirst(
            "merge, nothing to review", strategy: .merge, incoming: nil,
            reach: { _ in },
            apply: { await $0.prepareMerge() })
    }

    /// The app's own wait, not a held one: at least one display refresh
    /// passes between publishing `.applying` and the first store change —
    /// the window in which the loading view is committed to the screen.
    /// Before the wait existed the two happened in one main-actor turn, with
    /// no refresh between them.
    func testTheAppsWaitLetsADisplayRefreshPassBeforeTheFirstStoreChange() async throws {
        let incoming = seedIncoming()
        let coordinator = RestoreCoordinator()
        coordinator.configure(syncService: service, eventStore: store, eventTypeStore: device.types,
                              skillStore: device.skills, preferenceStore: device.prefs)
        try await fetched(coordinator)

        let refreshes = DisplayRefreshCounter()
        defer { refreshes.stop() }
        var applyingPublished = false
        var refreshesAtFirstStoreChange: Int?
        coordinator.$phase.sink { phase in
            guard case .applying = phase else { return }
            applyingPublished = true
            refreshes.start()
        }.store(in: &bag)
        store.objectWillChange.sink {
            if applyingPublished, refreshesAtFirstStoreChange == nil {
                refreshesAtFirstStoreChange = refreshes.count
            }
        }.store(in: &bag)

        await coordinator.applyOverwrite()
        guard case .finished = coordinator.phase else { return XCTFail("the restore finished: \(coordinator.phase)") }
        XCTAssertTrue(holds(incoming), "the restore landed")
        XCTAssertTrue(applyingPublished, "the loading phase was published")
        let atStoreChange = try XCTUnwrap(refreshesAtFirstStoreChange, "the store changed after the loading phase")
        // Liveness: the counter does count, so a zero above is a finding.
        let after = refreshes.count
        try await syncEventually("the refresh counter ticks") { refreshes.count > after }
        XCTAssertGreaterThanOrEqual(atStoreChange, 1,
                                    "no display refresh passed between the loading phase and the store change")
    }

    /// When no refresh comes in time, the wait gives up at its ceiling and
    /// the restore goes ahead — it is never parked on the display.
    func testTheFrameWaitGivesUpAtItsCeiling() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await DisplayedFrameWait.wait(frames: 1_000_000, ceiling: .milliseconds(100))
        let waited = clock.now - start
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(100), "the wait ran to its ceiling")
        XCTAssertLessThan(waited, .seconds(5), "the wait returned at its ceiling")
    }
}
