//
//  SyncSingletonTombstone.swift
//  Done
//
//  The tombstone rule for the three one-row-per-user tables — design §6
//  单行表的 tombstone of Docs/sync/00-realtime-sync-design.md.
//
//  user_settings, agent_preferences and agent_conversations have no
//  "absent" state on the device and no delete cascade, so an incoming
//  tombstone for one of them (a dashboard DELETE of the row) NEVER resets
//  the local value and NEVER shelves it: the local value is the only copy
//  and it stays. The baseline becomes `(hash(local), seq)` — for settings,
//  `keys :=` the local per-key hashes — and one trail line is written.
//
//  Writing hash(local) rather than h_in is arithmetic (Lean
//  `naive_half_round`): h_in would read dirty on every device, each would
//  write its local value into the dead row and pull the others' — a
//  ping-pong through the dead row. hash(local) reads clean, uploads
//  nothing, and only a later local edit writes the dead row once.
//
//  The row-level skip (`in_seq ≤ base.seq`, a known seq only) precedes the
//  tombstone check, as in the id-table rule.
//

import Foundation

enum SyncSingletonTombstone {

    /// The whole-row singleton tables.
    static let rowTables: Set<String> = SyncBaselineStore.scalarTables

    struct Outcome<Baseline: Equatable>: Equatable {
        /// The row-level skip fired: nothing to write, no trail line.
        let skipped: Bool
        /// The baseline to store (the input on a skip).
        let baseline: Baseline?
        /// The trail line to record (`DiagnosticTrail.record("Sync", …)`);
        /// nil on a skip.
        let trailLine: String?
    }

    static func trailLine(table: String, seq: Int64) -> String {
        "sync.apply.tombstoned_singleton table=\(table) seq=\(seq)"
    }

    /// agent_preferences / agent_conversations: baseline := (hash(local), seq).
    static func applyRow(
        table: String,
        localHash: String,
        base: SyncBaselineEntry?,
        incomingSeq: Int64
    ) -> Outcome<SyncBaselineEntry> {
        if let baseSeq = base?.seq, incomingSeq <= baseSeq {
            return Outcome(skipped: true, baseline: base, trailLine: nil)
        }
        return Outcome(skipped: false,
                       baseline: SyncBaselineEntry(hash: localHash, seq: incomingSeq),
                       trailLine: trailLine(table: table, seq: incomingSeq))
    }

    /// user_settings: keys := the local per-key hashes, as the pusher hashes
    /// them. The zone is cleared: a dead row is not "the server has a
    /// value" (§6.2), so the pusher sends the local zone and the row reads
    /// clean against these keys.
    static func applySettings(
        localKeys: [String: String],
        base: SyncSettingsBaseline?,
        incomingSeq: Int64
    ) -> Outcome<SyncSettingsBaseline> {
        if let baseSeq = base?.seq, incomingSeq <= baseSeq {
            return Outcome(skipped: true, baseline: base, trailLine: nil)
        }
        return Outcome(skipped: false,
                       baseline: .versioned(seq: incomingSeq, keys: localKeys, zone: nil),
                       trailLine: trailLine(table: SyncBaselineStore.settingsTable, seq: incomingSeq))
    }
}
