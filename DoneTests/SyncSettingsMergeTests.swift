//
//  SyncSettingsMergeTests.swift
//  DoneTests
//
//  The user_settings per-key three-way merge (design §6 user_settings 段).
//  Test names carry the Lean theorem they mirror where one exists
//  (verification/CivilCalendar/SyncMerge.lean, namespace `Settings`).
//

import XCTest
@testable import Done

@MainActor
final class SyncSettingsMergeTests: XCTestCase {

    /// A transparent per-key hash for rule tests: values are compared by
    /// their description, so a test reads as the values it holds.
    private let h: SyncSettingsMerge.KeyHash = { _, value in "#\(value)" }
    private let ids = "skillAnalyzedEventIds"
    private let zone = SyncSettingsMerge.zoneKey

    private func base(_ keys: [String: Any], seq: Int64? = 5) -> SyncSettingsBaseline {
        .versioned(seq: seq, keys: keys.mapValues { "#\($0)" }, zone: nil)
    }

    private func merge(local: [String: Any], remote: [String: Any], base: SyncSettingsBaseline?,
                       seq: Int64 = 6) -> SyncSettingsMerge.Outcome {
        SyncSettingsMerge.merge(local: local, remote: remote, remoteSeq: seq, baseline: base, keyHash: h)
    }

    private func isDirty(_ outcome: SyncSettingsMerge.Outcome, _ key: String) -> Bool {
        outcome.merged[key].map { h(key, $0) } != outcome.baseline?.keys[key]
    }

    // MARK: - mergeKey

    func testOneSideTakesThatSide() {
        // Remote moved, local did not.
        let r = merge(local: ["a": 1], remote: ["a": 2], base: base(["a": 1]))
        XCTAssertEqual(r.merged["a"] as? Int, 2)
        XCTAssertTrue(r.shelved.isEmpty)
        // Local moved, remote did not.
        let l = merge(local: ["a": 3], remote: ["a": 1], base: base(["a": 1]))
        XCTAssertEqual(l.merged["a"] as? Int, 3)
        XCTAssertTrue(l.shelved.isEmpty)
        XCTAssertTrue(isDirty(l, "a"), "the local change stays dirty and uploads")
    }

    func testMergeKeysSameBytesClean() {
        let r = merge(local: ["a": 7], remote: ["a": 7], base: base(["a": 1]))
        XCTAssertEqual(r.merged["a"] as? Int, 7)
        XCTAssertTrue(r.shelved.isEmpty, "both changed to the same bytes is no conflict")
        XCTAssertFalse(isDirty(r, "a"))
    }

    func testBothChangedLocalWinsRemoteShelved() throws {
        let r = merge(local: ["a": 3], remote: ["a": 2], base: base(["a": 1]))
        XCTAssertEqual(r.merged["a"] as? Int, 3)
        XCTAssertEqual(r.shelved.count, 1)
        let shelved = try XCTUnwrap(r.shelved.first)
        XCTAssertEqual(shelved.key, "a")
        XCTAssertEqual(shelved.side, .remote)
        XCTAssertEqual(shelved.value as? Int, 2)
    }

    func testRemoteDeletionOverriddenIsShelved() throws {
        let r = merge(local: ["a": 3], remote: [:], base: base(["a": 1]))
        XCTAssertEqual(r.merged["a"] as? Int, 3)
        let shelved = try XCTUnwrap(r.shelved.first)
        XCTAssertEqual(shelved.side, .remote)
        XCTAssertNil(shelved.value, "{key, remote: absent}")
        let object = shelved.shelfObject
        XCTAssertEqual(object["absent"] as? Bool, true)
        XCTAssertNil(object["value"])
    }

    func testDeletionPropagates() {
        let r = merge(local: ["a": 1], remote: [:], base: base(["a": 1]))
        XCTAssertNil(r.merged["a"], "remote deleted, local untouched → deleted")
        XCTAssertTrue(r.shelved.isEmpty)
        let l = merge(local: [:], remote: ["a": 1], base: base(["a": 1]))
        XCTAssertNil(l.merged["a"], "local deleted, remote untouched → stays deleted")
        XCTAssertTrue(isDirty(l, "a"), "the local deletion uploads")
    }

    func testLocalDeletionWinsRemoteShelved() throws {
        let r = merge(local: [:], remote: ["a": 2], base: base(["a": 1]))
        XCTAssertNil(r.merged["a"])
        let shelved = try XCTUnwrap(r.shelved.first)
        XCTAssertEqual(shelved.side, .remote)
        XCTAssertEqual(shelved.value as? Int, 2)
    }

    /// An absent key is a value: absent on both sides and in the base is
    /// nothing; with no baseline at all, a key present on one side only is
    /// that side's change.
    func testAbsentKeyIsAValue() {
        let both = merge(local: [:], remote: [:], base: base([:]))
        XCTAssertTrue(both.merged.isEmpty)
        let noBase = merge(local: ["l": 1], remote: ["r": 2], base: nil)
        XCTAssertEqual(noBase.merged["l"] as? Int, 1)
        XCTAssertEqual(noBase.merged["r"] as? Int, 2)
        XCTAssertTrue(noBase.shelved.isEmpty)
    }

    // MARK: - The post-merge baseline

    func testMergeKeysBaseTracksRemote() {
        let r = merge(local: ["a": 3, "b": 1, "c": 9], remote: ["a": 2, "b": 4], base: base(["a": 1, "b": 1, "c": 9]),
                      seq: 11)
        XCTAssertEqual(r.baseline, .versioned(seq: 11, keys: ["a": "#2", "b": "#4"], zone: nil),
                       "every key := the remote hash (conflict key a included), absent remote key absent")
    }

    func testMergeKeysLocalChangeStaysDirtyAndRemoteChangeClean() {
        let r = merge(local: ["a": 3, "b": 1], remote: ["a": 1, "b": 4], base: base(["a": 1, "b": 1]))
        XCTAssertTrue(isDirty(r, "a"), "local change uploads")
        XCTAssertFalse(isDirty(r, "b"), "remote change reads clean")
    }

    /// Round nine: after a conflict, setting the key back to the old base
    /// value still reads dirty — the baseline names the server's value.
    func testSettingsConflictKeyRevertWitness() {
        let r = merge(local: ["a": 3], remote: ["a": 2], base: base(["a": 1]))
        let reverted = SyncSettingsMerge.Outcome(skipped: false, merged: ["a": 1], baseline: r.baseline,
                                             shelved: [], needsZoneRule: nil)
        XCTAssertTrue(isDirty(reverted, "a"), "c0 against the server's c2 is a change")
    }

    // MARK: - The row skip

    func testMergeRowReapplySkip() {
        let first = merge(local: ["a": 3], remote: ["a": 2], base: base(["a": 1]), seq: 6)
        XCTAssertEqual(first.shelved.count, 1)
        let again = merge(local: first.merged, remote: ["a": 2], base: first.baseline, seq: 6)
        XCTAssertTrue(again.skipped)
        XCTAssertTrue(again.shelved.isEmpty, "nothing shelved twice")
        XCTAssertEqual(again.baseline, first.baseline)
        XCTAssertEqual(again.merged["a"] as? Int, 3)

        let older = merge(local: ["a": 3], remote: ["a": 0], base: base(["a": 1], seq: 9), seq: 8)
        XCTAssertTrue(older.skipped, "a stale page's older row skips")
    }

    func testUnknownSeqNeverSkips() {
        let r = merge(local: ["a": 1], remote: ["a": 2], base: base(["a": 1], seq: nil), seq: 0)
        XCTAssertFalse(r.skipped)
        XCTAssertEqual(r.merged["a"] as? Int, 2)
    }

    // MARK: - skillAnalyzedEventIds

    func testUnionKeepsBothSorted() {
        let r = merge(local: [ids: ["c", "a"]], remote: [ids: ["b", "a"]], base: base([ids: ["a"]]))
        XCTAssertEqual(r.merged[ids] as? [String], ["a", "b", "c"])
        XCTAssertTrue(r.shelved.isEmpty, "the union never shelves")

        // Enough ids that a hash-ordered Set cannot come out sorted by luck.
        let many = (0..<40).map { String(format: "id-%02d", $0) }
        let big = merge(local: [ids: Array(many.prefix(25).reversed())], remote: [ids: Array(many.suffix(25))],
                        base: nil)
        XCTAssertEqual(big.merged[ids] as? [String], many, "written back in canonical (sorted) order")
    }

    func testAnalyzedUnionOrderFree() {
        let one = merge(local: [ids: ["c", "a"]], remote: [ids: ["b"]], base: nil)
        let two = merge(local: [ids: ["b", "a"]], remote: [ids: ["c", "a"]], base: base([ids: ["z"]]))
        XCTAssertEqual(one.merged[ids] as? [String], two.merged[ids] as? [String])
    }

    func testUnionUndoesShrinkWitness() {
        let r = merge(local: [ids: ["2"]], remote: [ids: ["1", "2"]], base: base([ids: ["2"]]))
        XCTAssertEqual(r.merged[ids] as? [String], ["1", "2"], "a shrink is unioned back; only a deletion shrinks")
    }

    func testNilVsNonNilBaseDeletes() {
        let remoteCleared = merge(local: [ids: ["a"]], remote: [:], base: base([ids: ["a"]]))
        XCTAssertNil(remoteCleared.merged[ids])
        XCTAssertTrue(remoteCleared.shelved.isEmpty, "local had not moved: nothing to shelve")
        let localCleared = merge(local: [:], remote: [ids: ["a"]], base: base([ids: ["a"]]))
        XCTAssertNil(localCleared.merged[ids])
    }

    func testDeletionShelvesMovedSide() throws {
        let r = merge(local: [ids: ["a", "b"]], remote: [:], base: base([ids: ["a"]]))
        XCTAssertNil(r.merged[ids], "the deletion propagates over a local addition")
        let shelved = try XCTUnwrap(r.shelved.first)
        XCTAssertEqual(shelved.side, .local)
        XCTAssertEqual(shelved.value as? [String], ["a", "b"])

        let remoteMoved = merge(local: [:], remote: [ids: ["a", "c"]], base: base([ids: ["a"]]))
        XCTAssertNil(remoteMoved.merged[ids])
        XCTAssertEqual(remoteMoved.shelved.first?.side, .remote)
    }

    func testDoubleDeleteShelvesNothing() {
        let r = merge(local: [:], remote: [:], base: base([ids: ["a"]]))
        XCTAssertNil(r.merged[ids])
        XCTAssertTrue(r.shelved.isEmpty)
    }

    /// With no baseline for the key, nil vs a list is the general rule:
    /// the list is kept.
    func testNilWithoutBaseKeepsTheList() {
        let r = merge(local: [:], remote: [ids: ["a"]], base: base([:]))
        XCTAssertEqual(r.merged[ids] as? [String], ["a"])
    }

    /// The pair settles under the REAL outbound hash: after B pushes the
    /// sorted union, A merging it with a subset reads clean.
    func testUnionCanonicalSettlesWitnessUnderTheOutboundHash() {
        let b = SyncSettingsMerge.merge(local: [ids: ["3", "1"]], remote: [ids: ["2", "1"]],
                                        remoteSeq: 6, baseline: nil)
        let pushed = b.merged
        let a = SyncSettingsMerge.merge(local: [ids: ["2", "1"]], remote: pushed, remoteSeq: 7,
                                        baseline: .versioned(seq: 6, keys: [:], zone: nil))
        let sentKeys = SupabaseSyncService.settingsKeyHashes(
            SupabaseSyncService.settingsBlobForUpload(local: a.merged, serverZone: a.baseline?.zone))
        XCTAssertEqual(sentKeys, a.baseline?.keys, "A reads clean and sends nothing")
    }

    // MARK: - The zone key

    func testZoneKeyIsLeftForTheZoneRule() throws {
        let r = merge(local: [zone: "Europe/Paris", "a": 1], remote: [zone: "Asia/Tokyo", "a": 1],
                      base: base([zone: "Europe/Paris", "a": 1]))
        XCTAssertEqual(r.merged[zone] as? String, "Europe/Paris", "never adopted by the general rule")
        XCTAssertTrue(r.shelved.isEmpty, "a zone never goes to the shelf")
        let pending = try XCTUnwrap(r.needsZoneRule)
        XCTAssertEqual(pending.local as? String, "Europe/Paris")
        XCTAssertEqual(pending.remote as? String, "Asia/Tokyo")
        XCTAssertEqual(r.baseline?.zone, "Asia/Tokyo")
        XCTAssertEqual(r.baseline?.keys[zone], "#Asia/Tokyo", "the zone key's baseline is the remote hash too")

        let agree = merge(local: [zone: "Asia/Tokyo"], remote: [zone: "Asia/Tokyo"], base: nil)
        XCTAssertNil(agree.needsZoneRule, "equal values need no rule")
    }

    /// The pusher substitutes the server zone, so a device whose own zone
    /// differs still reads clean after the merge.
    func testZoneDifferenceDoesNotLeaveTheRowDirtyForThePusher() {
        let r = SyncSettingsMerge.merge(local: [zone: "Europe/Paris", "a": 1],
                                        remote: [zone: "Asia/Tokyo", "a": 1],
                                        remoteSeq: 6, baseline: nil)
        let sentKeys = SupabaseSyncService.settingsKeyHashes(
            SupabaseSyncService.settingsBlobForUpload(local: r.merged, serverZone: r.baseline?.zone))
        XCTAssertEqual(sentKeys, r.baseline?.keys)
    }

    // MARK: - The shelf row

    func testAllShelvedKeysShareOneShelfRow() throws {
        let r = merge(local: ["a": 3, "b": 5], remote: ["a": 2], base: base(["a": 1, "b": 1]))
        XCTAssertEqual(r.shelved.map(\.key).sorted(), ["a", "b"])
        let row = try XCTUnwrap(r.shelfRow)
        let keys = try XCTUnwrap(row["keys"] as? [[String: Any]])
        XCTAssertEqual(keys.map { $0["key"] as? String }, ["a", "b"])
        XCTAssertEqual(keys[1]["absent"] as? Bool, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(row))
        XCTAssertNil(merge(local: ["a": 1], remote: ["a": 1], base: nil).shelfRow)
    }

    // MARK: - The legacy upgrade

    func testUpgradedKeysThreeBranches() {
        let hashes = SyncSettingsMerge.LegacyRowHashes(local: "L", remote: "R")
        XCTAssertEqual(SyncSettingsMerge.upgradedKeys(legacyHash: "L", rowHashes: hashes,
                                                      localKeys: ["k": "l"], remoteKeys: ["k": "r"]), ["k": "l"])
        XCTAssertEqual(SyncSettingsMerge.upgradedKeys(legacyHash: "R", rowHashes: hashes,
                                                      localKeys: ["k": "l"], remoteKeys: ["k": "r"]), ["k": "r"])
        XCTAssertEqual(SyncSettingsMerge.upgradedKeys(legacyHash: "X", rowHashes: hashes,
                                                      localKeys: ["k": "l"], remoteKeys: ["k": "r"]), [:])
    }

    /// The pusher's pre-pull upgrade takes branch 1 only: keys when the
    /// local row still hashes to the legacy value, nil otherwise — never the
    /// remote branch, which needs a pulled row.
    func testUpgradedKeysIfLocalCleanIsBranchOneAlone() {
        XCTAssertEqual(SyncSettingsMerge.upgradedKeysIfLocalClean(legacyHash: "L", localRowHash: "L",
                                                                  localKeys: ["k": "l"]), ["k": "l"])
        XCTAssertNil(SyncSettingsMerge.upgradedKeysIfLocalClean(legacyHash: "R", localRowHash: "L",
                                                                localKeys: ["k": "l"]))
    }

    /// Branch 2: the remote IS this device's last upload, so every
    /// difference is local — taken, nothing shelved.
    func testLegacyBaselineRemoteBranchKeepsLocalChanges() {
        let r = SyncSettingsMerge.merge(local: ["a": 3], remote: ["a": 1], remoteSeq: 6,
                                        baseline: .legacy(rowHash: "R"),
                                        legacyRowHashes: .init(local: "L", remote: "R"), keyHash: h)
        XCTAssertFalse(r.skipped, "a legacy baseline has no seq")
        XCTAssertEqual(r.merged["a"] as? Int, 3)
        XCTAssertTrue(r.shelved.isEmpty)
        XCTAssertTrue(isDirty(r, "a"))
    }

    /// Branch 3: neither — every differing key is a conflict, local wins,
    /// remote shelved; equal keys are not conflicts.
    func testLegacyBaselineNeitherBranchShelvesEveryDifferingKey() {
        for hashes in [SyncSettingsMerge.LegacyRowHashes(local: "L", remote: "R"), nil] {
            let r = SyncSettingsMerge.merge(local: ["a": 3, "same": 1], remote: ["a": 2, "same": 1],
                                            remoteSeq: 6, baseline: .legacy(rowHash: "X"),
                                            legacyRowHashes: hashes, keyHash: h)
            XCTAssertEqual(r.merged["a"] as? Int, 3)
            XCTAssertEqual(r.shelved.map(\.key), ["a"])
            XCTAssertEqual(r.baseline, .versioned(seq: 6, keys: ["a": "#2", "same": "#1"], zone: nil))
        }
    }

    /// The service's slice-1 entry point and the merge take their keys from
    /// the same rule, fed the same row hashes.
    func testServiceEntryPointAndMergeAgreeOnTheUpgrade() {
        let suite = "SyncSettingsMergeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let uid = "88888888-8888-8888-8888-888888888888"
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        let remote: [String: Any] = ["a": 1]
        defaults.set(SupabaseSyncService.rowHash(["user_id": uid, "settings": remote]),
                     forKey: "syncHashes.\(uid).user_settings")
        let service = SupabaseSyncService(gateway: SyncFakeServer(userId: uid), userId: uid, defaults: defaults)
        guard case .legacy(let legacyHash) = service.baseline.settings else {
            return XCTFail("fixture liveness: the baseline must still be legacy")
        }
        let local = SyncedSettings.currentSnapshot(defaults)
        let hashes = service.legacySettingsRowHashes(local: local, remote: remote)

        let merged = SyncSettingsMerge.merge(local: local, remote: remote, remoteSeq: 9,
                                             baseline: .legacy(rowHash: legacyHash), legacyRowHashes: hashes)
        XCTAssertTrue(merged.shelved.isEmpty, "branch 2: the remote is the last upload")
        // Only branch 2 tells "a" apart: with the remote row as base, the
        // local snapshot's missing "a" is a local deletion and stays; with
        // empty base keys (branch 3) the remote "a" would be adopted.
        XCTAssertNil(merged.merged["a"], "branch 2: the local deletion of a remote-only key stands")
        XCTAssertEqual(merged.merged[AppSettingsKeys.showTimerBanner] as? Bool, true)

        XCTAssertTrue(service.upgradeLegacySettingsBaseline(remoteSettings: remote, remoteSeq: 9))
        XCTAssertEqual(service.baseline.settings?.keys, SupabaseSyncService.settingsKeyHashes(remote))
    }
}
