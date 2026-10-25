//
//  SyncDecision.swift
//  Done
//
//  The id-table decision core — design §6 apply table of
//  Docs/sync/00-realtime-sync-design.md, and nothing else. A pure function
//  of the hashes and seqs one incoming row brings; the applier owns the
//  arrays, the cascades, the shelf file and the persist order.
//
//  The formal statement is `decideRow` in
//  verification/CivilCalendar/SyncMerge.lean, and
//  verification/sync-fixtures.json is the replay contract this function is
//  held to (`SyncDecisionReplayTests`). The table, in its stated order:
//
//    1. in_seq ≤ base.seq          → skip (never fires when the seq is unknown)
//    2. tombstone                  → local removed, a dirty local version shelved
//                                    first, baseline entry removed
//    3. h_in == base.hash          → echo, baseline (h_in, in_seq)
//    4. h_in == h_loc              → same, baseline (h_in, in_seq)
//    5. local absent, base present → conflict: a pending local delete meets a
//                                    peer edit; local stays absent, incoming
//                                    shelved, baseline (h_in, in_seq)
//    6. !dirty or local absent     → adopt, baseline (h_in, in_seq)
//    7. otherwise (dirty)          → conflict, local kept, incoming shelved,
//                                    baseline (h_in, in_seq)
//
//  `dirty` is `h_loc ≠ base.hash`, an absent side counting as a value.
//
//  Two baseline shapes that the fixtures do not carry (design §6.3, S4):
//  - a legacy `<hash>` entry has no seq, and an unknown seq never makes
//    row 1 fire;
//  - the `?` marker (a write sent, its result unknown) equals no hash: row
//    3 never fires on it, the row always reads dirty, and only `h_in == h_loc`
//    settles it without a shelf line.
//
//  The in-flight echo (Lean `decideRowInflight`): when a PATCH of ours for
//  this id is still outstanding and the incoming LIVE row carries exactly
//  the bytes it sent, the row is our own write coming back — an echo,
//  never a conflict, whatever the local row became meanwhile. It is
//  consulted after rows 1 and 2 and writes the same baseline the table
//  would (`decideRowInflight_base`).
//

import Foundation

enum SyncDecisionAction: String, Equatable {
    case skip
    case tombstone
    case echo
    case same
    case adopt
    case conflict
}

/// What becomes of the id's baseline entry. The table has three writings:
/// skip keeps it, tombstone removes it, every other row writes
/// `(h_in, in_seq)` — the version the server held at that seq.
enum SyncBaselineWrite: Equatable {
    case keep
    case remove
    case write(SyncBaselineEntry)
}

/// What becomes of the local row; a function of the action alone.
enum SyncLocalEffect: Equatable {
    /// skip, echo, same, conflict. A conflict with no local row keeps the
    /// local side ABSENT: the pending delete stays and its tombstone PATCH
    /// still goes out.
    case keep
    /// adopt: the incoming row replaces (or inserts) the local one.
    case replaceWithIncoming
    /// tombstone: the existing delete cascade runs (a no-op when absent).
    case remove
}

struct SyncDecision: Equatable {
    let action: SyncDecisionAction
    let baseline: SyncBaselineWrite
    /// The incoming row goes to the shelf (both conflict rows).
    let shelfRemote: Bool
    /// The local row goes to the shelf, before anything else is touched
    /// (tombstone meeting a dirty local row). The shelf line's seq is the
    /// tombstone's seq, never the baseline's.
    let shelfLocal: Bool

    var localEffect: SyncLocalEffect {
        switch action {
        case .tombstone: return .remove
        case .adopt: return .replaceWithIncoming
        case .skip, .echo, .same, .conflict: return .keep
        }
    }

    /// The whole baseline entry after the row, given the one before it.
    func baseAfter(_ before: SyncBaselineEntry?) -> SyncBaselineEntry? {
        switch baseline {
        case .keep: return before
        case .remove: return nil
        case .write(let entry): return entry
        }
    }

    /// - Parameters:
    ///   - tombstone: the incoming row has `deleted_at` set.
    ///   - incomingHash: `rowHash` of the incoming row, in the outbound
    ///     projection.
    ///   - localHash: `rowHash` of the local row; nil when there is none.
    ///   - base: the baseline entry for the id; nil when there is none.
    ///   - incomingSeq: the incoming row's seq.
    ///   - inFlightSentHash: the sent hash of a PATCH of ours for this id
    ///     whose response has not been applied yet; nil when none is
    ///     outstanding.
    static func decide(
        tombstone: Bool,
        incomingHash: String,
        localHash: String?,
        base: SyncBaselineEntry?,
        incomingSeq: Int64,
        inFlightSentHash: String? = nil
    ) -> SyncDecision {
        // Row 1. Only a known seq can make a row stale or seen.
        if let base, let baseSeq = base.seq, incomingSeq <= baseSeq {
            return SyncDecision(action: .skip, baseline: .keep, shelfRemote: false, shelfLocal: false)
        }

        let written = SyncBaselineWrite.write(SyncBaselineEntry(hash: incomingHash, seq: incomingSeq))
        let baseHash = comparableHash(base)
        let dirty = localHash != baseHash

        // Row 2.
        if tombstone {
            return SyncDecision(action: .tombstone, baseline: .remove, shelfRemote: false,
                                shelfLocal: localHash != nil && dirty)
        }

        // The in-flight echo: after the skip and tombstone rows, before the rest.
        if let inFlightSentHash, inFlightSentHash == incomingHash {
            return SyncDecision(action: .echo, baseline: written, shelfRemote: false, shelfLocal: false)
        }

        // Row 3.
        if let baseHash, baseHash == incomingHash {
            return SyncDecision(action: .echo, baseline: written, shelfRemote: false, shelfLocal: false)
        }
        // Row 4.
        if localHash == incomingHash {
            return SyncDecision(action: .same, baseline: written, shelfRemote: false, shelfLocal: false)
        }
        // Row 5.
        if localHash == nil, base != nil {
            return SyncDecision(action: .conflict, baseline: written, shelfRemote: true, shelfLocal: false)
        }
        // Row 6.
        if !dirty || localHash == nil {
            return SyncDecision(action: .adopt, baseline: written, shelfRemote: false, shelfLocal: false)
        }
        // Row 7.
        return SyncDecision(action: .conflict, baseline: written, shelfRemote: true, shelfLocal: false)
    }

    /// The baseline hash as a comparable value: nil when there is no entry
    /// AND when the entry is the `?` marker, which equals no hash. A local
    /// row is therefore always dirty against `?`; an absent local row with
    /// a `?` entry is still "an entry" for row 5, which precedes the only
    /// other row that reads `dirty` with no local row.
    private static func comparableHash(_ base: SyncBaselineEntry?) -> String? {
        guard let base, !base.isUnknown else { return nil }
        return base.hash
    }
}
