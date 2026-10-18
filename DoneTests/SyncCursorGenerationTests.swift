//
//  SyncCursorGenerationTests.swift
//  DoneTests
//
//  Survey S11 / gap G22: the cursor records the generation it expects of
//  every baseline table, each table's value carries its own, and a load
//  that finds them disagreeing drops the cursor. The rollbacks below write
//  a key back to its earlier value while another keeps its later one —
//  the per-key reordering a power loss can leave behind.
//

import XCTest
@testable import Done

@MainActor
final class SyncCursorGenerationTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private let uid = "99999999-9999-9999-9999-999999999999"

    override func setUp() {
        super.setUp()
        suiteName = "SyncCursorGenerationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func key(_ table: String) -> String { "syncHashes.\(uid).\(table)" }

    /// A page applied to `calendar_events` at `seq`: the baseline write, then
    /// the cursor commit, as the applier does it.
    private func applyPage(_ baseline: SyncBaselineStore, _ cursor: SyncCursorStore, id: String, seq: Int64) {
        baseline.setEntry(SyncBaselineEntry(hash: "h\(seq)", seq: seq), table: "calendar_events", id: id)
        cursor.commit(seq: seq, baseline: baseline, touched: ["calendar_events"])
    }

    private func relaunch() -> SupabaseSyncService {
        SupabaseSyncService(gateway: SyncFakeServer(userId: uid), userId: uid, defaults: defaults)
    }

    func testCommitAdvancesTheTouchedTablesAndTheCursorExpectsThem_andAConsistentStateKeepsTheCursor() {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        applyPage(baseline, cursor, id: "A", seq: 5)
        applyPage(baseline, cursor, id: "B", seq: 9)

        XCTAssertEqual(baseline.generation(of: "calendar_events"), 2)
        XCTAssertEqual(baseline.generation(of: "events"), 0, "untouched")
        XCTAssertEqual(cursor.expectedGenerations, ["calendar_events": 2])
        XCTAssertEqual(cursor.value, 9)

        let service = relaunch()
        XCTAssertEqual(service.cursor.value, 9, "positive control: nothing rolled back, nothing dropped")
        XCTAssertEqual(service.baseline.generation(of: "calendar_events"), 2)
        XCTAssertEqual(service.baseline.entry(table: "calendar_events", id: "B"), SyncBaselineEntry(hash: "h9", seq: 9))
    }

    func testNewCursorWithAnOlderBaselineDropsTheCursor_killsNoGenerationCheck() {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        applyPage(baseline, cursor, id: "A", seq: 5)
        let olderBaseline = defaults.object(forKey: key("calendar_events"))
        applyPage(baseline, cursor, id: "A", seq: 9)

        // The baseline key went back; the cursor key kept its later value.
        defaults.set(olderBaseline, forKey: key("calendar_events"))
        let service = relaunch()

        XCTAssertNil(service.cursor.value, "the mutant keeps cursor 9 over a baseline that never saw seq 9")
        XCTAssertNil(defaults.object(forKey: key("cursor")), "dropped on disk too: the next pull starts from zero")
        XCTAssertTrue(DiagnosticTrail.combinedText().contains("sync.cursor.dropped reason=generation tables=calendar_events"))
    }

    func testBaselineKeyLostEntirelyDropsTheCursor() {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        applyPage(baseline, cursor, id: "A", seq: 5)

        defaults.removeObject(forKey: key("calendar_events"))

        XCTAssertNil(relaunch().cursor.value)
    }

    func testOlderCursorWithANewerBaselineDropsTheCursorToo() {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        applyPage(baseline, cursor, id: "A", seq: 5)
        let olderCursor = defaults.object(forKey: key("cursor"))
        applyPage(baseline, cursor, id: "A", seq: 9)

        defaults.set(olderCursor, forKey: key("cursor"))

        XCTAssertNil(relaunch().cursor.value, "any disagreement is a full pull; the three-way compare makes it safe")
    }

    func testABareIntegerCursorFromBeforeGenerationsStillLoadsOverGenerationlessBaselines() throws {
        defaults.set(try JSONEncoder().encode(["A": "hA@3"]), forKey: key("calendar_events"))
        defaults.set(NSNumber(value: 3), forKey: key("cursor"))

        let service = relaunch()

        XCTAssertEqual(service.cursor.value, 3)
        XCTAssertEqual(service.baseline.entry(table: "calendar_events", id: "A"), SyncBaselineEntry(hash: "hA", seq: 3))
    }

    func testGenerationZeroWritesThePreGenerationShapeAndAHigherOneIsCarriedInsideEachValue() throws {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        baseline.setEntry(SyncBaselineEntry(hash: "h", seq: 1), table: "event_logs", id: "L")
        baseline.setEntry(SyncBaselineEntry(hash: "p", seq: 2), table: "agent_preferences", id: uid)
        baseline.setSettings(.versioned(seq: 3, keys: ["k": "hk"], zone: nil))
        baseline.persist()
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(defaults.data(forKey: key("event_logs")))), ["L": "h@1"])
        XCTAssertEqual(defaults.string(forKey: key("agent_preferences")), "p@2")

        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        cursor.commit(seq: 7, baseline: baseline, touched: ["event_logs", "agent_preferences", "user_settings", "agent_conversations"])

        XCTAssertEqual(defaults.string(forKey: key("agent_preferences")), "p@2#1")
        XCTAssertEqual(defaults.string(forKey: key("agent_conversations")), "#1", "an empty value still carries its generation")
        XCTAssertTrue(try XCTUnwrap(defaults.string(forKey: key("user_settings"))).hasSuffix("}#1"))
        let reloaded = SyncBaselineStore(defaults: defaults, userId: uid)
        XCTAssertEqual(reloaded.entry(table: "event_logs", id: "L"), SyncBaselineEntry(hash: "h", seq: 1))
        XCTAssertEqual(reloaded.entry(table: "agent_preferences", id: uid), SyncBaselineEntry(hash: "p", seq: 2))
        XCTAssertNil(reloaded.entry(table: "agent_conversations", id: uid))
        XCTAssertEqual(reloaded.settings, .versioned(seq: 3, keys: ["k": "hk"], zone: nil))
        for table in ["event_logs", "agent_preferences", "user_settings", "agent_conversations"] {
            XCTAssertEqual(reloaded.generation(of: table), 1, table)
        }
        XCTAssertTrue(SyncCursorStore(defaults: defaults, userId: uid).mismatchedTables(reloaded).isEmpty)
    }

    func testTheUnknownMarkerSurvivesAGenerationSuffix() {
        XCTAssertEqual(SyncBaselineStore.splitGeneration("?@5#3").value, "?@5")
        XCTAssertEqual(SyncBaselineStore.splitGeneration("?@5#3").gen, 3)
        XCTAssertEqual(SyncBaselineStore.splitGeneration("?").gen, 0)
        XCTAssertEqual(SyncBaselineStore.splitGeneration("{\"keys\":{\"a#b\":\"h\"}}").gen, 0, "a `#` inside the JSON is not a suffix")
        XCTAssertEqual(SyncBaselineEntry(encoded: SyncBaselineStore.splitGeneration("?@5#3").value), .unknown(seq: 5))
    }

    func testCommitNeverMovesTheCursorBackwards() {
        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        cursor.commit(seq: 9, baseline: baseline, touched: ["events"])
        cursor.commit(seq: 4, baseline: baseline, touched: ["events"])
        XCTAssertEqual(cursor.value, 9)
        XCTAssertEqual(cursor.expectedGenerations["events"], 2)
    }
}
