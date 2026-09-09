//
//  RevisionSidecar.swift
//  DoneMac
//
//  Per-record revisions live in a sidecar file, NOT in `Event`: the shared
//  Event Codable bytes are consumed by three iOS paths (durable storage,
//  backup snapshot, widget snapshot) and must stay byte-identical until
//  phase-2 sync lifts `revision` server-side.
//

import Foundation

struct RecordMeta: Codable, Equatable, Sendable {
    var revision: Int64
    var updatedAt: Date
    /// Highest revision the sync layer has successfully pushed. nil = never
    /// pushed. `revision > lastPushedRevision` is the dirty predicate.
    var lastPushedRevision: Int64?
}

struct SidecarFile: Equatable, Sendable {
    var records: [UUID: RecordMeta] = [:]
    /// Server `updated_at` per row as of OUR last pull — the stale-write
    /// guardrail's PERSISTED baseline (round-5 review #6/QA F2: an
    /// in-memory map died with the session while dirtiness survived, so a
    /// relaunch let a stale Mac edit clobber a newer iPhone write).
    var serverStamps: [UUID: String] = [:]
    /// Rows deleted locally AFTER they were synced. Blocks re-adoption on
    /// pull and drives the delete push; cleared when the server confirms —
    /// or when the server stamp moves (iOS re-edited after our delete:
    /// iOS wins, the row comes back). Round-5 review #7 / QA F5.
    var tombstones: Set<UUID> = []
    /// Ids we pushed since the last pull. Their next-seen server stamp is
    /// OUR OWN write echoed back in the server's formatting — adopt it as
    /// the new baseline without a conflict. Comparing our formatted guess
    /// against the echo is format-fragile (round-6: QA's own-push test
    /// proved the string-equality approach misfires).
    var pushedAwaitingRebaseline: Set<UUID> = []

    mutating func bump(_ ids: Set<UUID>, at now: Date) {
        for id in ids {
            var meta = records[id] ?? RecordMeta(revision: 0, updatedAt: now, lastPushedRevision: nil)
            meta.revision &+= 1
            meta.updatedAt = now
            records[id] = meta
        }
    }

    mutating func remove(_ ids: Set<UUID>) {
        for id in ids { records.removeValue(forKey: id) }
    }

    mutating func setMeta(_ meta: RecordMeta, for id: UUID) {
        records[id] = meta
    }

    /// Coherence tripwire input: sidecar entries whose record no longer
    /// exists. Expected 0 after every load (plan risk #4). Tombstoned ids
    /// are deliberately recordless — they don't count.
    func orphans(against liveIDs: Set<UUID>) -> Set<UUID> {
        Set(records.keys).subtracting(liveIDs).subtracting(tombstones)
    }
}

// Decode-tolerant by hand: sidecar files written before serverStamps/
// tombstones existed must load, not freeze (missing keys on a synthesized
// non-optional Dictionary decode would throw).
extension SidecarFile: Codable {
    private enum CodingKeys: String, CodingKey {
        case records, serverStamps, tombstones, pushedAwaitingRebaseline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decodeIfPresent([UUID: RecordMeta].self, forKey: .records) ?? [:]
        serverStamps = try container.decodeIfPresent([UUID: String].self, forKey: .serverStamps) ?? [:]
        tombstones = try container.decodeIfPresent(Set<UUID>.self, forKey: .tombstones) ?? []
        pushedAwaitingRebaseline = try container.decodeIfPresent(Set<UUID>.self, forKey: .pushedAwaitingRebaseline) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(records, forKey: .records)
        try container.encode(serverStamps, forKey: .serverStamps)
        try container.encode(tombstones, forKey: .tombstones)
        try container.encode(pushedAwaitingRebaseline, forKey: .pushedAwaitingRebaseline)
    }
}
