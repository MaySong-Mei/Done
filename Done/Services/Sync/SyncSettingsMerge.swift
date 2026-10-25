//
//  SyncSettingsMerge.swift
//  Done
//
//  The user_settings per-key three-way merge — design §6 user_settings 段 of
//  Docs/sync/00-realtime-sync-design.md; formal statement `Settings.mergeKey`,
//  `mergeAnalyzedIds` and `mergeRow` in verification/CivilCalendar/SyncMerge.lean.
//  Pure: the applier hands it the local blob, the incoming blob and the
//  baseline, and writes back what it returns.
//
//  Per key (`in`, `loc`, `base`), an absent key being a value (nil):
//  - one side changed from the base → that side (a deletion propagates);
//  - both changed to the same bytes → no conflict;
//  - both changed differently → local wins, the remote value goes to the
//    shelf — `{key, remote: absent}` when the remote side was a deletion.
//  `skillAnalyzedEventIds` (every `SyncedSettings.unionKeys` key): both
//  non-nil → the union, sorted; one side nil against a non-nil base → the
//  deletion propagates and a side that had moved from the base is shelved.
//  The reference-zone key is not merged here: §6.2 decides it, and the
//  outcome only says when that rule is needed.
//
//  The row-level skip (`in_seq ≤ base.seq`) runs first. After a merge the
//  baseline is the REMOTE row on every key — conflict keys included — at
//  the incoming seq, so a key is dirty exactly when its local value differs
//  from the server's.
//

import Foundation

enum SyncSettingsMerge {
    static let zoneKey = CalendarOccurrenceKey.referenceTimeZoneDefaultsKey

    /// One key's hash. Defaults to the outbound per-key hash
    /// (`SupabaseSyncService.settingsKeyHashes`, canonical form included),
    /// so the merge and the pusher can never disagree on "changed".
    typealias KeyHash = (_ key: String, _ value: Any) -> String

    static let outboundKeyHash: KeyHash = { key, value in
        SupabaseSyncService.settingsKeyHashes([key: value])[key] ?? ""
    }

    /// The legacy row hashes the upgrade rule compares the old scalar
    /// against, taken in the form the legacy hash was taken in
    /// (`SupabaseSyncService.rowHash(settingsRow(blob))`).
    struct LegacyRowHashes: Equatable {
        let local: String
        let remote: String
    }

    enum Side: String, Equatable {
        case remote
        case local
    }

    /// One shelved key. `value == nil` is the absent key: the side that
    /// lost was a deletion.
    struct ShelvedKey {
        let key: String
        let side: Side
        let value: Any?

        var shelfObject: [String: Any] {
            var object: [String: Any] = ["key": key, "side": side.rawValue]
            if let value { object["value"] = value } else { object["absent"] = true }
            return object
        }
    }

    /// What §6.2 must decide: the zone key's two values when they differ.
    /// The merge leaves the local value in place and the baseline names the
    /// remote one, as for every other key.
    struct ZonePending {
        let local: Any?
        let remote: Any?
    }

    struct Outcome {
        /// The row-level skip fired: nothing merged, nothing to write.
        let skipped: Bool
        /// The local blob after the merge.
        let merged: [String: Any]
        /// The baseline to store: `.versioned(seq: in_seq, keys: remote
        /// per-key hashes, zone: remote zone)`, or the input on a skip.
        let baseline: SyncSettingsBaseline?
        let shelved: [ShelvedKey]
        let needsZoneRule: ZonePending?

        /// The shelf line's row: every shelved key of this merge in one
        /// object, so the shelf's `(uid, table, id, seq)` dedupe keeps a
        /// re-pulled row idempotent. nil when nothing was shelved.
        var shelfRow: [String: Any]? {
            guard !shelved.isEmpty else { return nil }
            return ["keys": shelved.sorted { $0.key < $1.key }.map(\.shelfObject)]
        }
    }

    // MARK: - The legacy upgrade

    /// The three-branch rule for a pre-Phase-1 scalar baseline (design §6
    /// settings 段): legacy == hash(local row) → local per-key hashes;
    /// legacy == hash(remote row) → remote per-key hashes; neither → empty.
    /// `SupabaseSyncService.upgradeLegacySettingsBaseline` takes its keys
    /// from here.
    static func upgradedKeys(
        legacyHash: String,
        rowHashes: LegacyRowHashes,
        localKeys: @autoclosure () -> [String: String],
        remoteKeys: @autoclosure () -> [String: String]
    ) -> [String: String] {
        if let keys = upgradedKeysIfLocalClean(legacyHash: legacyHash, localRowHash: rowHashes.local,
                                               localKeys: localKeys()) {
            return keys
        }
        if legacyHash == rowHashes.remote { return remoteKeys() }
        return [:]
    }

    /// The first branch alone — the one that needs no remote row, so the
    /// pusher can take it before any pull. nil when the local row no longer
    /// hashes to the legacy value. `upgradedKeys` and
    /// `SupabaseSyncService.upgradeLegacySettingsBaselineIfLocalClean` both
    /// go through here.
    static func upgradedKeysIfLocalClean(
        legacyHash: String,
        localRowHash: String,
        localKeys: @autoclosure () -> [String: String]
    ) -> [String: String]? {
        legacyHash == localRowHash ? localKeys() : nil
    }

    // MARK: - The merge

    /// - Parameters:
    ///   - legacyRowHashes: required to upgrade a `.legacy` baseline; without
    ///     them the upgrade takes its third branch (empty keys), which loses
    ///     nothing — every differing key is shelved.
    static func merge(
        local: [String: Any],
        remote: [String: Any],
        remoteSeq: Int64,
        baseline: SyncSettingsBaseline?,
        legacyRowHashes: LegacyRowHashes? = nil,
        keyHash: KeyHash = outboundKeyHash
    ) -> Outcome {
        let baseKeys: [String: String]
        switch baseline {
        case .versioned(let seq, let keys, _):
            if let seq, remoteSeq <= seq {
                return Outcome(skipped: true, merged: local, baseline: baseline, shelved: [], needsZoneRule: nil)
            }
            baseKeys = keys
        case .legacy(let legacyHash):
            baseKeys = legacyRowHashes.map {
                upgradedKeys(legacyHash: legacyHash, rowHashes: $0,
                             localKeys: hashes(local, keyHash), remoteKeys: hashes(remote, keyHash))
            } ?? [:]
        case nil:
            baseKeys = [:]
        }

        var merged: [String: Any] = [:]
        var shelved: [ShelvedKey] = []
        let allKeys = Set(local.keys).union(remote.keys).union(baseKeys.keys)

        for key in allKeys.sorted() {
            let inV = remote[key]
            let locV = local[key]
            let baseV = baseKeys[key]

            if key == zoneKey {
                if let locV { merged[key] = locV }
                continue
            }

            let result: KeyResult
            if SyncedSettings.unionKeys.contains(key) {
                result = mergeUnion(key: key, inV: inV, locV: locV, baseV: baseV, keyHash: keyHash)
            } else {
                result = mergeKey(key: key, inV: inV, locV: locV, baseV: baseV, keyHash: keyHash)
            }
            if let value = result.value { merged[key] = value }
            if result.shelfRemote { shelved.append(ShelvedKey(key: key, side: .remote, value: inV)) }
            if result.shelfLocal { shelved.append(ShelvedKey(key: key, side: .local, value: locV)) }
        }

        let localZone = local[zoneKey]
        let remoteZone = remote[zoneKey]
        let zonePending: ZonePending? =
            localZone.map { keyHash(zoneKey, $0) } == remoteZone.map { keyHash(zoneKey, $0) }
            ? nil : ZonePending(local: localZone, remote: remoteZone)

        let newBaseline = SyncSettingsBaseline.versioned(
            seq: remoteSeq,
            keys: hashes(remote, keyHash),
            zone: remoteZone as? String
        )
        return Outcome(skipped: false, merged: merged, baseline: newBaseline,
                       shelved: shelved, needsZoneRule: zonePending)
    }

    // MARK: - Per key

    struct KeyResult {
        let value: Any?
        let shelfRemote: Bool
        let shelfLocal: Bool
    }

    /// A side changed iff its value's hash differs from the per-key base
    /// hash; an absent key is a value on both sides.
    static func changed(key: String, _ value: Any?, base: String?, keyHash: KeyHash) -> Bool {
        value.map { keyHash(key, $0) } != base
    }

    /// Lean `Settings.mergeKey`.
    static func mergeKey(key: String, inV: Any?, locV: Any?, baseV: String?, keyHash: KeyHash) -> KeyResult {
        if !changed(key: key, inV, base: baseV, keyHash: keyHash) {
            return KeyResult(value: locV, shelfRemote: false, shelfLocal: false)
        }
        if !changed(key: key, locV, base: baseV, keyHash: keyHash) {
            return KeyResult(value: inV, shelfRemote: false, shelfLocal: false)
        }
        if inV.map({ keyHash(key, $0) }) == locV.map({ keyHash(key, $0) }) {
            return KeyResult(value: locV, shelfRemote: false, shelfLocal: false)
        }
        return KeyResult(value: locV, shelfRemote: true, shelfLocal: false)
    }

    /// Lean `Settings.mergeAnalyzedIds`: the union, written back sorted
    /// (the order is what lets two devices that merged the same set write
    /// the same bytes); nil against a non-nil base is a deletion. A value
    /// that is not a list of strings takes the general rule.
    static func mergeUnion(key: String, inV: Any?, locV: Any?, baseV: String?, keyHash: KeyHash) -> KeyResult {
        if let a = inV as? [String], let b = locV as? [String] {
            return KeyResult(value: Array(Set(a).union(b)).sorted(), shelfRemote: false, shelfLocal: false)
        }
        let inIsList = inV == nil || inV is [String]
        let locIsList = locV == nil || locV is [String]
        if baseV != nil, inIsList, locIsList, inV == nil || locV == nil {
            return KeyResult(
                value: nil,
                shelfRemote: inV != nil && changed(key: key, inV, base: baseV, keyHash: keyHash),
                shelfLocal: locV != nil && changed(key: key, locV, base: baseV, keyHash: keyHash)
            )
        }
        return mergeKey(key: key, inV: inV, locV: locV, baseV: baseV, keyHash: keyHash)
    }

    private static func hashes(_ blob: [String: Any], _ keyHash: KeyHash) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in blob { out[key] = keyHash(key, value) }
        return out
    }
}
