//
//  SyncOwnerGuardTests.swift
//  DoneTests
//
//  Survey S5 / gap G11: the device's local data belongs to an account
//  (`syncHashes.ownerUid`). A session for another uid, while that owner
//  still has synced state here, stops the engine — no pull, no push — and
//  publishes a state the account card can show.
//

import XCTest
@testable import Done

@MainActor
final class SyncOwnerGuardTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private let owner = "66666666-6666-6666-6666-666666666666"
    private let other = "77777777-7777-7777-7777-777777777777"

    override func setUp() {
        super.setUp()
        suiteName = "SyncOwnerGuardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeEvent(_ title: String) -> Event {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Event(title: title, timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
    }

    private func ownerLines(_ session: String) -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n").map(String.init)
            .filter { $0.contains("sync.blocked.owner_mismatch") && $0.contains("session=\(session)") }
    }

    /// The owner signs in, pushes a row (leaving synced state), signs out.
    private func ownerHasSynced() async {
        let server = SyncFakeServer(userId: owner)
        let service = SupabaseSyncService(gateway: server, userId: owner, defaults: defaults)
        await service.syncEvents([makeEvent("owner's")], kind: "calendar")
        XCTAssertNotNil(defaults.data(forKey: "syncHashes.\(owner).calendar_events"), "precondition: synced state exists")
    }

    func testFirstSignInWithNoOwnerRecordsTheSessionAsOwnerAndSyncs() async {
        XCTAssertNil(defaults.string(forKey: "syncHashes.ownerUid"))
        let server = SyncFakeServer(userId: owner)

        let service = SupabaseSyncService(gateway: server, userId: owner, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), owner)
        XCTAssertEqual(SyncOwnerGuard.ownerKey, "syncHashes.ownerUid", "inside the prefix the erase sweeps")
        XCTAssertEqual(service.ownerState, .active(uid: owner))
        await service.syncEvents([makeEvent("first")], kind: "calendar")
        XCTAssertEqual(server.requests(.insert).count, 1)
    }

    func testSameUidAgainSyncsNormally() async {
        await ownerHasSynced()
        let server = SyncFakeServer(userId: owner)

        let service = SupabaseSyncService(gateway: server, userId: owner, defaults: defaults)

        XCTAssertEqual(service.ownerState, .active(uid: owner))
        await service.syncEvents([makeEvent("again")], kind: "calendar")
        XCTAssertEqual(server.requests(.insert).count, 1)
    }

    func testDifferentUidWhileTheOwnerHasSyncedStateStopsEveryPushAndPublishesTheState_killsNoOwnerGuard() async {
        await ownerHasSynced()
        let server = SyncFakeServer(userId: other)
        // The trail outlives a test run; only a line this sign-in wrote counts.
        let linesBefore = ownerLines(other).count

        let service = SupabaseSyncService(gateway: server, userId: other, defaults: defaults)

        XCTAssertEqual(service.ownerState, .blocked(owner: owner, session: other))
        XCTAssertFalse(service.ownerState.allowsSync, "the puller reads the same flag: no pull either")
        XCTAssertEqual(ownerLines(other).count, linesBefore + 1)
        XCTAssertTrue(ownerLines(other).last?.contains("owner=\(owner) session=\(other)") == true)
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await service.syncEvents([makeEvent("A's row")], kind: "calendar")
        await service.syncEvents([makeEvent("A's todo")], kind: "todo")
        await service.syncSettings()
        await service.syncAgentConversations()
        XCTAssertTrue(server.requests.isEmpty, "the mutant without the guard POSTs account A's rows into B")
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), owner, "the owner is not taken over")
    }

    func testAdoptingTheLocalDataForTheNewAccountLiftsTheBlock() async {
        await ownerHasSynced()
        let server = SyncFakeServer(userId: other)
        let service = SupabaseSyncService(gateway: server, userId: other, defaults: defaults)
        XCTAssertFalse(service.ownerState.allowsSync)

        service.adoptLocalDataForCurrentAccount()

        XCTAssertEqual(service.ownerState, .active(uid: other))
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), other)
        await service.syncEvents([makeEvent("now B's")], kind: "calendar")
        XCTAssertEqual(server.requests(.insert).count, 1)
    }

    func testDifferentUidWhenTheOwnerNeverSyncedAnythingHereTakesOwnership() {
        SyncOwnerGuard.setOwner(owner, defaults)

        let service = SupabaseSyncService(gateway: SyncFakeServer(userId: other), userId: other, defaults: defaults)

        XCTAssertEqual(service.ownerState, .active(uid: other))
        XCTAssertEqual(defaults.string(forKey: SyncOwnerGuard.ownerKey), other)
    }

    func testTheEraseClearsTheOwnerSoAnotherAccountMaySyncAfterIt() async {
        await ownerHasSynced()

        SupabaseSyncService.wipeAllPersistedHashes(defaults)

        XCTAssertNil(defaults.string(forKey: SyncOwnerGuard.ownerKey))
        let service = SupabaseSyncService(gateway: SyncFakeServer(userId: other), userId: other, defaults: defaults)
        XCTAssertEqual(service.ownerState, .active(uid: other))
    }

    /// Positive control for the evidence: the owner's own state, not
    /// anyone's, is what blocks.
    func testAnotherUsersLeftoverStateDoesNotBlockTheOwner() {
        defaults.set(Data("{}".utf8), forKey: "syncHashes.\(other).events")
        SyncOwnerGuard.setOwner(owner, defaults)
        XCTAssertEqual(SyncOwnerGuard.evaluate(sessionUid: owner, defaults), .active(uid: owner))
        XCTAssertTrue(SyncOwnerGuard.hasSyncedState(owner: other, defaults))
        XCTAssertFalse(SyncOwnerGuard.hasSyncedState(owner: owner, defaults))
    }
}
