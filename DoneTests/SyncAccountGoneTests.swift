//
//  SyncAccountGoneTests.swift
//  DoneTests
//
//  Design §10.7 / §6.4 终态之后 / §8.2 §10.7 tests: after the account was
//  erased on another device (a `user_id` 23503 and a terminal refresh), the
//  engine stops and deletes nothing until the user chooses; (a) keeps the
//  owner guard standing against a new uid, (c) lifts it so the next sign-in
//  uploads, (b) is the existing erase.
//

import XCTest
@testable import Done

@MainActor
final class SyncAccountGoneTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var store: EventStore!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!
    private let uid = "99999999-9999-9999-9999-999999999999"
    private let other = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    override func setUp() {
        super.setUp()
        suiteName = "SyncAccountGoneTests-\(UUID().uuidString)"
        location = TestStorage.reset(suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
    }

    override func tearDown() {
        store = nil
        service = nil
        TestStorage.tearDown(suiteName)
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeEvent(_ title: String) -> Event {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Event(title: title, timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
    }

    /// What `SupabaseREST.send` throws for the 23503 on `<table>_user_id_fkey`.
    private func accountGone(_ table: String) -> Error {
        let body: [String: Any] = [
            "code": "23503",
            "details": "Key (user_id)=(\(uid)) is not present in table \"users\".",
            "hint": NSNull(),
            "message": "insert or update on table \"\(table)\" violates foreign key constraint \"\(table)_user_id_fkey\"",
        ]
        return SupabaseREST.requestError(table: table, method: "POST", status: 409,
                                         body: try! JSONSerialization.data(withJSONObject: body))
    }

    private var baselineKey: String { "syncHashes.\(uid).calendar_events" }

    /// The device has synced rows, then meets the terminal state: a write
    /// hits the foreign key and the forced refresh ends the session.
    /// Returns the rows the device holds.
    private func reachTerminalState() async -> [Event] {
        let synced = [makeEvent("one"), makeEvent("two")]
        for e in synced { store.addCalendarEvent(e) }
        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        XCTAssertEqual(server.requests(.insert).count, 1, "fixture: synced")
        XCTAssertNotNil(defaults.data(forKey: baselineKey), "fixture: a baseline exists")
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uid, "fixture: the owner is on record")

        service.tokenRefresher = { .signedOut }
        server.failWhen = { verb, table in verb == .insert ? self.accountGone(table) : nil }
        store.addCalendarEvent(makeEvent("after the erase"))
        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        XCTAssertEqual(service.accountCheck, .signedOut(table: "calendar_events"), "fixture: terminal")
        server.failWhen = nil
        // What the `$session` sink delivers once AuthService cleared the session.
        service.endSession()
        return store.rawCalendarEvents
    }

    private func trailLines(containing needle: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init).filter { $0.contains(needle) }
    }

    // MARK: Before the choice

    func testTheTerminalStateStopsSyncAndDeletesNothingUntilTheUserChooses_killsEraseOnTerminal() async {
        let held = await reachTerminalState()
        let requests = server.requests.count

        XCTAssertTrue(service.awaitsAccountGoneChoice, "the prompt is owed")
        XCTAssertEqual(store.rawCalendarEvents.map(\.title), held.map(\.title), "local rows untouched")
        XCTAssertEqual(store.rawCalendarEvents.count, 3)
        XCTAssertNotNil(defaults.data(forKey: baselineKey), "the baseline is not wiped — the mutant that erases on the terminal state removes it")
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uid, "the owner guard keeps standing")
        XCTAssertNil(service.accountGoneChoice)

        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        await service.syncSettings()
        XCTAssertEqual(server.requests.count, requests, "no session: nothing is sent")

        // The store on disk is intact too: a relaunch reads the same rows.
        let relaunched = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        XCTAssertEqual(relaunched.rawCalendarEvents.count, 3)
    }

    func testAChoiceOutsideTheTerminalStateIsIgnored() {
        XCTAssertEqual(service.accountCheck, .none)

        service.chooseAfterAccountGone(.uploadIntoNextAccount)

        XCTAssertNil(service.accountGoneChoice)
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uid, "a stale prompt cannot lift the guard")
    }

    // MARK: (a) Keep the data on this device, no sync

    func testKeepLocalDataLeavesTheGuardStandingSoANewAccountIsBlocked_killsEraseOnTerminal() async {
        let held = await reachTerminalState()

        service.chooseAfterAccountGone(.keepLocalData)

        XCTAssertEqual(service.accountGoneChoice, .keepLocalData)
        XCTAssertFalse(service.awaitsAccountGoneChoice)
        XCTAssertEqual(store.rawCalendarEvents.map(\.title), held.map(\.title))
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uid)
        XCTAssertTrue(trailLines(containing: "sync.account.gone choice=keepLocalData").count >= 1)

        // A new account signs in: blocked (G11 场景二), nothing uploaded.
        let before = server.requests.count
        service.beginSession(userId: other)
        XCTAssertEqual(service.ownerState, .blocked(owner: uid, session: other))
        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        XCTAssertEqual(server.requests.count, before, "the erased account's data is not pushed into the new one")
        XCTAssertEqual(service.accountCheck, .none, "the new sign-in starts a fresh check")
        XCTAssertNil(service.accountGoneChoice, "…and forgets the old choice")
    }

    // MARK: (c) Upload into the next account

    func testUploadIntoNextAccountLiftsTheGuardSoTheNextSignInUploads() async {
        let held = await reachTerminalState()

        service.chooseAfterAccountGone(.uploadIntoNextAccount)

        XCTAssertEqual(service.accountGoneChoice, .uploadIntoNextAccount)
        XCTAssertNil(defaults.string(forKey: SyncOwnerGuard.ownerKey), "only this choice clears the owner (§10.7)")
        XCTAssertEqual(store.rawCalendarEvents.map(\.title), held.map(\.title), "the choice itself moves nothing")
        XCTAssertNotNil(defaults.data(forKey: baselineKey), "the old account's baseline is left for the erase; it is not the new account's")

        // The new account signs in: it takes ownership and the rows go up.
        service.beginSession(userId: other)
        XCTAssertEqual(service.ownerState, .active(uid: other))
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), other)
        let inserts = server.requests(.insert).count
        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        XCTAssertEqual(server.requests(.insert).count, inserts + 1)
        XCTAssertEqual(server.requests(.insert).last?.keys.count, 3, "every local row, as the new account's")
    }

    // MARK: (b) Erase this device

    func testEraseThisDeviceRecordsTheChoiceAndLeavesTheErasingToTheExistingPath() async {
        let held = await reachTerminalState()

        service.chooseAfterAccountGone(.eraseThisDevice)

        XCTAssertEqual(service.accountGoneChoice, .eraseThisDevice)
        XCTAssertEqual(store.rawCalendarEvents.map(\.title), held.map(\.title), "the choice deletes nothing; the erase does")
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uid)

        // The existing erase (`resetAllLocalData`): the store is cleared and the
        // `syncHashes.` prefix — owner key included — is swept.
        store.clearAllLocalData()
        SupabaseSyncService.wipeAllPersistedHashes(defaults)
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
        XCTAssertNil(defaults.string(forKey: SyncOwnerGuard.ownerKey))
        XCTAssertNil(defaults.data(forKey: baselineKey))

        service.beginSession(userId: other)
        XCTAssertEqual(service.ownerState, .active(uid: other), "a clean device for the next account")
    }

    // MARK: The guard's lift is only the choice

    func testClearOwnerRemovesOnlyTheOwnerKey() {
        defaults.set("x", forKey: "syncHashes.\(uid).todos")
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), uid)

        SyncOwnerGuard.clearOwner(defaults)

        XCTAssertNil(SyncOwnerGuard.storedOwner(defaults))
        XCTAssertEqual(defaults.string(forKey: "syncHashes.\(uid).todos"), "x")
    }
}
