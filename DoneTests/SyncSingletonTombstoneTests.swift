//
//  SyncSingletonTombstoneTests.swift
//  DoneTests
//
//  The singleton-table tombstone rule (design §6 单行表的 tombstone): local
//  never reset, never shelved; baseline := (hash(local), seq); one trail
//  line.
//

import XCTest
@testable import Done

@MainActor
final class SyncSingletonTombstoneTests: XCTestCase {

    func testRowTableBaselineIsTheLocalHashAtTheTombstoneSeq() {
        for table in SyncSingletonTombstone.rowTables.sorted() {
            let r = SyncSingletonTombstone.applyRow(table: table, localHash: "hLocal",
                                                    base: SyncBaselineEntry(hash: "h0", seq: 5), incomingSeq: 8)
            XCTAssertFalse(r.skipped)
            XCTAssertEqual(r.baseline, SyncBaselineEntry(hash: "hLocal", seq: 8),
                           "\(table): hash(local), never h_in, never removed")
            XCTAssertEqual(r.trailLine, "sync.apply.tombstoned_singleton table=\(table) seq=8")
        }
    }

    /// Writing hash(local) makes the row read clean: nothing goes out until
    /// a later local edit. Control: the id-table rule on the same inputs
    /// removes the baseline (the local row would be cascaded away).
    func testTheRowReadsCleanAfterwards() {
        let r = SyncSingletonTombstone.applyRow(table: "agent_preferences", localHash: "hLocal",
                                                base: nil, incomingSeq: 3)
        XCTAssertEqual(r.baseline?.hash, "hLocal", "local hash == baseline hash: clean, no upload")
        let idTable = SyncDecision.decide(tombstone: true, incomingHash: "hDead", localHash: "hLocal",
                                          base: nil, incomingSeq: 3)
        XCTAssertEqual(idTable.baseline, .remove, "control: the id-table tombstone row differs")
    }

    func testSkipRowPrecedesTheTombstone() {
        let base = SyncBaselineEntry(hash: "h0", seq: 9)
        for seq: Int64 in [8, 9] {
            let r = SyncSingletonTombstone.applyRow(table: "agent_conversations", localHash: "hLocal",
                                                    base: base, incomingSeq: seq)
            XCTAssertTrue(r.skipped)
            XCTAssertEqual(r.baseline, base)
            XCTAssertNil(r.trailLine)
        }
        // A seq-less entry never skips.
        let legacy = SyncSingletonTombstone.applyRow(table: "agent_conversations", localHash: "hLocal",
                                                     base: SyncBaselineEntry(hash: "h0", seq: nil), incomingSeq: 1)
        XCTAssertFalse(legacy.skipped)
        // The `?` marker is replaced: the result is now known (the row is dead).
        let marker = SyncSingletonTombstone.applyRow(table: "agent_conversations", localHash: "hLocal",
                                                     base: .unknown(seq: 4), incomingSeq: 6)
        XCTAssertEqual(marker.baseline, SyncBaselineEntry(hash: "hLocal", seq: 6))
    }

    /// user_settings: keys := the local per-key hashes, zone cleared — and
    /// under the pusher's own projection that reads clean, even when the
    /// previous baseline carried a server zone.
    func testSettingsKeysAreTheLocalPerKeyHashesAndReadClean() {
        let local: [String: Any] = ["a": 1, SyncSettingsMerge.zoneKey: "Europe/Paris",
                                    "skillAnalyzedEventIds": ["b", "a"]]
        let localKeys = SupabaseSyncService.settingsKeyHashes(local)
        let before = SyncSettingsBaseline.versioned(seq: 5, keys: ["a": "old"], zone: "Asia/Tokyo")
        let r = SyncSingletonTombstone.applySettings(localKeys: localKeys, base: before, incomingSeq: 7)
        XCTAssertEqual(r.baseline, .versioned(seq: 7, keys: localKeys, zone: nil))
        XCTAssertEqual(r.trailLine, "sync.apply.tombstoned_singleton table=user_settings seq=7")

        let sent = SupabaseSyncService.settingsKeyHashes(
            SupabaseSyncService.settingsBlobForUpload(local: local, serverZone: r.baseline?.zone))
        XCTAssertEqual(sent, r.baseline?.keys, "clean: the dead row is not written to")

        // Control: keeping the old server zone would leave the row dirty.
        let keptZone = SupabaseSyncService.settingsKeyHashes(
            SupabaseSyncService.settingsBlobForUpload(local: local, serverZone: "Asia/Tokyo"))
        XCTAssertNotEqual(keptZone, r.baseline?.keys)
    }

    func testSettingsSkipAndLegacy() {
        let skipped = SyncSingletonTombstone.applySettings(localKeys: ["a": "x"],
                                                           base: .versioned(seq: 7, keys: [:], zone: nil),
                                                           incomingSeq: 7)
        XCTAssertTrue(skipped.skipped)
        XCTAssertNil(skipped.trailLine)
        let legacy = SyncSingletonTombstone.applySettings(localKeys: ["a": "x"], base: .legacy(rowHash: "h"),
                                                          incomingSeq: 1)
        XCTAssertEqual(legacy.baseline, .versioned(seq: 1, keys: ["a": "x"], zone: nil),
                       "a legacy scalar has no seq: never skips, upgraded to the local keys")
    }
}
