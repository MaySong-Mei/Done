//
//  SyncBaselineTests.swift
//  DoneTests
//
//  The (hash, seq) baseline, the settings JSON shape and the cursor
//  (design §6.3): legacy `<hash>` values keep decoding, `<hash>@<seq>`
//  carries the seq, `user_settings` moves from a scalar to
//  `{seq, keys, zone}`, and all of it lives under the one `syncHashes.`
//  prefix the erase sweeps.
//

import XCTest
@testable import Done

@MainActor
final class SyncBaselineTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private let uid = "22222222-2222-2222-2222-222222222222"

    override func setUp() {
        super.setUp()
        suiteName = "SyncBaselineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func key(_ table: String) -> String { "syncHashes.\(uid).\(table)" }

    // MARK: Entry encoding

    func testLegacyHashDecodesWithUnknownSeq() {
        let entry = SyncBaselineEntry(encoded: "0123456789abcdef")
        XCTAssertEqual(entry, SyncBaselineEntry(hash: "0123456789abcdef", seq: nil))
        XCTAssertEqual(entry?.encoded, "0123456789abcdef")
    }

    func testVersionedHashRoundTripsSeq() {
        let entry = SyncBaselineEntry(hash: "abcd", seq: 4711)
        XCTAssertEqual(entry.encoded, "abcd@4711")
        XCTAssertEqual(SyncBaselineEntry(encoded: "abcd@4711"), entry)
    }

    func testMalformedSeqSuffixKeepsTheHashAndForgetsTheSeq() {
        XCTAssertEqual(SyncBaselineEntry(encoded: "abcd@x"), SyncBaselineEntry(hash: "abcd", seq: nil))
        XCTAssertNil(SyncBaselineEntry(encoded: ""))
    }

    // MARK: Settings baseline shape

    func testSettingsLegacyScalarDecodesAsLegacy() {
        XCTAssertEqual(SyncSettingsBaseline(encoded: "deadbeef"), .legacy(rowHash: "deadbeef"))
        XCTAssertEqual(SyncSettingsBaseline.legacy(rowHash: "deadbeef").encoded, "deadbeef")
    }

    func testSettingsVersionedRoundTripsAsSortedJSON() throws {
        let versioned = SyncSettingsBaseline.versioned(seq: 12, keys: ["b": "hb", "a": "ha"], zone: "Asia/Tokyo")
        let encoded = versioned.encoded
        XCTAssertTrue(encoded.hasPrefix("{"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(object["seq"] as? Int, 12)
        XCTAssertEqual(object["keys"] as? [String: String], ["a": "ha", "b": "hb"])
        XCTAssertEqual(object["zone"] as? String, "Asia/Tokyo")
        XCTAssertEqual(SyncSettingsBaseline(encoded: encoded), versioned)
    }

    func testSettingsVersionedWithoutSeqOrZoneOmitsThem() throws {
        let versioned = SyncSettingsBaseline.versioned(seq: nil, keys: ["a": "ha"], zone: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(versioned.encoded.utf8)) as? [String: Any])
        XCTAssertNil(object["seq"])
        XCTAssertNil(object["zone"])
        XCTAssertEqual(SyncSettingsBaseline(encoded: versioned.encoded), versioned)
    }

    // MARK: Store load / persist

    func testStoreLoadsLegacyAndVersionedRowsFromThePreExistingKeyShape() throws {
        // What a pre-Phase-1 build left behind (JSON `[id: hash]` Data) plus
        // one row already carrying a seq.
        let map = ["A": "hA", "B": "hB@9"]
        defaults.set(try JSONEncoder().encode(map), forKey: key("calendar_events"))
        defaults.set("hP@3", forKey: key("agent_preferences"))
        defaults.set("legacyS", forKey: key("user_settings"))

        let store = SyncBaselineStore(defaults: defaults, userId: uid)

        XCTAssertEqual(store.entry(table: "calendar_events", id: "A"), SyncBaselineEntry(hash: "hA", seq: nil))
        XCTAssertEqual(store.entry(table: "calendar_events", id: "B"), SyncBaselineEntry(hash: "hB", seq: 9))
        XCTAssertEqual(store.entry(table: "agent_preferences", id: uid), SyncBaselineEntry(hash: "hP", seq: 3))
        XCTAssertEqual(store.entry(table: "agent_preferences", id: "any-id-is-ignored"), SyncBaselineEntry(hash: "hP", seq: 3))
        XCTAssertEqual(store.settings, .legacy(rowHash: "legacyS"))
    }

    func testPersistWritesOnlyTouchedTablesAndReloadsIdentically() throws {
        let store = SyncBaselineStore(defaults: defaults, userId: uid)
        store.setEntry(SyncBaselineEntry(hash: "h1", seq: 5), table: "event_logs", id: "single|L")
        store.setEntry(SyncBaselineEntry(hash: "h2", seq: nil), table: "event_logs", id: "M")
        store.setEntry(SyncBaselineEntry(hash: "hc", seq: 8), table: "agent_conversations", id: uid)
        store.setSettings(.versioned(seq: 2, keys: ["k": "hk"], zone: nil))
        XCTAssertNil(defaults.data(forKey: key("event_logs")), "nothing on disk before persist")

        store.persist()

        XCTAssertNotNil(defaults.data(forKey: key("event_logs")))
        XCTAssertNil(defaults.data(forKey: key("todo_lists")), "untouched tables are not written")
        let map = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(defaults.data(forKey: key("event_logs"))))
        XCTAssertEqual(map, ["single|L": "h1@5", "M": "h2"])
        XCTAssertEqual(defaults.string(forKey: key("agent_conversations")), "hc@8")

        let reloaded = SyncBaselineStore(defaults: defaults, userId: uid)
        XCTAssertEqual(reloaded.entries(table: "event_logs"), store.entries(table: "event_logs"))
        XCTAssertEqual(reloaded.entry(table: "agent_conversations", id: uid), SyncBaselineEntry(hash: "hc", seq: 8))
        XCTAssertEqual(reloaded.settings, .versioned(seq: 2, keys: ["k": "hk"], zone: nil))
    }

    func testRemoveAndReplace() {
        let store = SyncBaselineStore(defaults: defaults, userId: uid)
        store.setEntry(SyncBaselineEntry(hash: "a", seq: 1), table: "todo_lists", id: "A")
        store.setEntry(SyncBaselineEntry(hash: "b", seq: 2), table: "todo_lists", id: "B")
        store.setEntry(SyncBaselineEntry(hash: "c", seq: 3), table: "todo_lists", id: "C")
        store.removeEntries(table: "todo_lists", ids: ["A", "C"])
        XCTAssertEqual(store.entries(table: "todo_lists").keys.sorted(), ["B"])

        store.replaceEntries(table: "todo_lists", with: ["Z": SyncBaselineEntry(hash: "z", seq: nil)])
        store.persist()
        XCTAssertEqual(SyncBaselineStore(defaults: defaults, userId: uid).entries(table: "todo_lists").keys.sorted(), ["Z"])
    }

    func testSignedOutStorePersistsNothing() {
        let store = SyncBaselineStore(defaults: defaults, userId: "")
        store.setEntry(SyncBaselineEntry(hash: "a", seq: 1), table: "events", id: "A")
        store.setSettings(.versioned(seq: 1, keys: [:], zone: nil))
        store.persist()
        store.persistAll()
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("syncHashes.") }.isEmpty)
    }

    func testWipeAllCoversEveryUserAndTheCursor() {
        let store = SyncBaselineStore(defaults: defaults, userId: uid)
        store.setEntry(SyncBaselineEntry(hash: "a", seq: 1), table: "events", id: "A")
        store.persist()
        SyncCursorStore(defaults: defaults, userId: uid).value = 99
        SyncCursorStore(defaults: defaults, userId: "other-user").value = 5
        defaults.set("unrelated", forKey: "someOtherKey")

        SyncBaselineStore.wipeAll(defaults)

        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("syncHashes.") }.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "someOtherKey"), "unrelated")
        XCTAssertNil(SyncCursorStore(defaults: defaults, userId: uid).value)
    }

    // MARK: Cursor

    func testCursorRoundTripsAndClears() {
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        XCTAssertNil(cursor.value, "a missing cursor means pull everything (I1)")
        cursor.value = 1 << 40
        XCTAssertEqual(cursor.value, 1 << 40)
        XCTAssertEqual((defaults.object(forKey: key("cursor")) as? NSNumber)?.int64Value, 1 << 40,
                       "lives under the same prefix as the hashes")
        XCTAssertEqual(SyncCursorStore(defaults: defaults, userId: uid).value, 1 << 40)
        cursor.clear()
        XCTAssertNil(cursor.value)
        XCTAssertNil(defaults.object(forKey: key("cursor")))
    }

    func testCursorIsScopedPerUserAndSignedOutIsNil() {
        SyncCursorStore(defaults: defaults, userId: uid).value = 7
        XCTAssertNil(SyncCursorStore(defaults: defaults, userId: "someone-else").value)
        let signedOut = SyncCursorStore(defaults: defaults, userId: "")
        signedOut.value = 3
        XCTAssertNil(signedOut.value)
        XCTAssertNil(defaults.object(forKey: "syncHashes..cursor"))
    }

    // MARK: Table labels

    func testUuidIdsFoldToTheServerSpellingAndBackNonUuidIdsPassThrough() {
        let local = "D94F6056-7B3B-4AFA-B4E9-C135CA5712CB"
        let server = "d94f6056-7b3b-4afa-b4e9-c135ca5712cb"
        XCTAssertEqual(SyncBaselineKey.matchKey(local), SyncBaselineKey.matchKey(server))
        XCTAssertEqual(SyncBaselineKey.matchKey(local), server)
        XCTAssertEqual(SyncBaselineKey.localId(server), local)
        XCTAssertEqual(SyncBaselineKey.localId(local), local)
        let occurrenceKey = "D94F6056-7B3B-4AFA-B4E9-C135CA5712CB|2026-01-02"
        XCTAssertEqual(SyncBaselineKey.matchKey(occurrenceKey), occurrenceKey, "not a uuid: sent and matched raw")
        XCTAssertEqual(SyncBaselineKey.localId(occurrenceKey), occurrenceKey)
    }

    func testCalendarKindEventsKeepTheirOwnBaselineLabel() {
        XCTAssertEqual(SyncBaselineStore.table(forFeedTable: "events", kind: "calendar"), "calendar_events")
        XCTAssertEqual(SyncBaselineStore.table(forFeedTable: "events", kind: "todo"), "events")
        XCTAssertEqual(SyncBaselineStore.table(forFeedTable: "event_logs", kind: nil), "event_logs")
        XCTAssertEqual(SupabaseSyncService.eventsBaselineTable(kind: "calendar"), "calendar_events")
    }
}
