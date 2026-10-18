//
//  SyncSettingsCanonicalTests.swift
//  DoneTests
//
//  The union key's canonical form (design §6 user_settings 段, round nine):
//  `skillAnalyzedEventIds` is sorted before it is hashed and before it is
//  sent, so the same set in another order is not a change.
//

import XCTest
@testable import Done

@MainActor
final class SyncSettingsCanonicalTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!
    private let uid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let unionKey = "skillAnalyzedEventIds"

    override func setUp() {
        super.setUp()
        suiteName = "SyncSettingsCanonicalTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheUnionKeyIsInTheSyncedSetAndNamedAsAUnion() {
        XCTAssertTrue(SyncedSettings.allKeys.contains(unionKey))
        XCTAssertTrue(SyncedSettings.unionKeys.contains(unionKey))
    }

    func testSameSetInAnotherOrderHashesTheSame() {
        let a = SupabaseSyncService.settingsKeyHashes([unionKey: ["c", "a", "b"]])
        let b = SupabaseSyncService.settingsKeyHashes([unionKey: ["b", "c", "a"]])
        XCTAssertEqual(a, b)
        // Positive control: the hash does see the array's content.
        XCTAssertNotEqual(a, SupabaseSyncService.settingsKeyHashes([unionKey: ["a", "b"]]))
        // Only the union key is canonicalised; another array keeps its order.
        XCTAssertNotEqual(SupabaseSyncService.settingsKeyHashes(["other": ["b", "a"]]),
                          SupabaseSyncService.settingsKeyHashes(["other": ["a", "b"]]))
    }

    func testTheBlobGoesOutSorted() async throws {
        defaults.set(["c", "a", "b"], forKey: unionKey)

        await service.syncSettings()

        let insert = try XCTUnwrap(server.requests(.insert, table: "user_settings").first)
        let sent = try XCTUnwrap((insert.body as? [[String: Any]])?.first?["settings"] as? [String: Any])
        XCTAssertEqual(sent[unionKey] as? [String], ["a", "b", "c"])
        XCTAssertEqual(defaults.stringArray(forKey: unionKey), ["c", "a", "b"], "the local value is not rewritten")
    }

    func testTheSameSetReorderedLocallyIsNotAChange_killsUnsortedUnionKey() async throws {
        defaults.set(["c", "a", "b"], forKey: unionKey)
        await service.syncSettings()
        let before = server.requests.count

        // `Array(Set)` hands back another order in another process.
        defaults.set(["b", "c", "a"], forKey: unionKey)
        await service.syncSettings()

        XCTAssertEqual(server.requests.count, before, "the mutant hashes the array as stored and PATCHes every reorder")

        // Positive control: a real change still goes out.
        defaults.set(["b", "c", "a", "d"], forKey: unionKey)
        await service.syncSettings()
        XCTAssertEqual(server.requests.count, before + 1)
    }

    /// The restore replay hashes the CLOUD blob (survey S6). A blob an
    /// earlier build wrote holds the set in whatever order it was stored;
    /// the same set held locally is not a change.
    func testRestoreOfACloudBlobHoldingTheSetUnsortedReadsClean_killsUnsortedReplayHash() async throws {
        defaults.set(["c", "a", "b"], forKey: unionKey)
        let cloudBlob = SyncedSettings.currentSnapshot(defaults)
        XCTAssertEqual(cloudBlob[unionKey] as? [String], ["c", "a", "b"], "the fixture's cloud blob is unsorted")
        server.seed(table: "user_settings", rows: [["user_id": uid, "settings": cloudBlob]])
        let snapshot = try await service.fetchRestoreSnapshot()
        service.markRestoreCompleted(todoEvents: [], calendarEvents: [], logs: [], feedback: [],
                                     todoLists: [], eventTypes: [], skills: [], snapshot: snapshot)
        let before = server.requests.count

        await service.syncSettings()

        XCTAssertEqual(server.requests.count, before, "the mutant hashes the cloud array as stored and PATCHes a set nobody changed")

        // Positive control: a set that really differs from the cloud's is sent.
        defaults.set(["c", "a"], forKey: unionKey)
        await service.syncSettings()
        XCTAssertEqual(server.requests(.patch, table: "user_settings").count, 1)
    }

    func testCanonicalFormLeavesAValueThatIsNotAStringArrayAlone() {
        let blob: [String: Any] = [unionKey: 7, "x": "y"]
        let canonical = SyncedSettings.canonicalForm(blob)
        XCTAssertEqual(canonical[unionKey] as? Int, 7)
        XCTAssertEqual(canonical["x"] as? String, "y")
    }

    /// The legacy scalar was hashed by an earlier build over the array as
    /// stored; the upgrade compares in that form, not the canonical one.
    func testLegacyUpgradeComparesTheStoredOrder() throws {
        defaults.set(["c", "a", "b"], forKey: unionKey)
        let local = SyncedSettings.currentSnapshot(defaults)
        defaults.set(SupabaseSyncService.rowHash(["user_id": uid, "settings": local]), forKey: "syncHashes.\(uid).user_settings")

        let fresh = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)

        XCTAssertEqual(fresh.baseline.settings, .versioned(seq: nil, keys: SupabaseSyncService.settingsKeyHashes(local), zone: nil),
                       "still recognised as clean")
    }
}
