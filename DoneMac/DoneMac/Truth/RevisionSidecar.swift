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

struct SidecarFile: Codable, Equatable, Sendable {
    var records: [UUID: RecordMeta] = [:]

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
    /// exists. Expected 0 after every load (plan risk #4).
    func orphans(against liveIDs: Set<UUID>) -> Set<UUID> {
        Set(records.keys).subtracting(liveIDs)
    }
}
