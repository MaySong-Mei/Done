//
//  SyncEventTypeWinners.swift
//  Done
//
//  The event_types namesake rule — design §6 event_types 段 of
//  Docs/sync/00-realtime-sync-design.md; formal statement `EventTypes.resolve`
//  in verification/CivilCalendar/SyncMerge.lean.
//
//  Locally types merge by title, on the wire by UUID. Two devices that each
//  create the same title mint two UUIDs. Per `normalizedTitle`
//  (`EventTypeTemplateStore.normalizedTitle`), among the LIVE namesakes
//  only, the winner is the row with the latest `updated_at`; equal
//  timestamps fall back to the smallest lowercase UUID string — computed
//  here, never `dedupedByTitle`'s "first one seen". A tombstone removes
//  only its own UUID and takes no part in choosing a winner (Lean
//  `naive_dead_namesake_erases_live_type_witness`).
//
//  Why the newest (gh#257, production): an account carried the app's
//  default rows twice (uploaded 2026-05-18) next to the user's later
//  customised rows of the same titles; smallest-UUID-only picked the stale
//  defaults for two titles and tombstoned the user's colours.
//
//  Only page rows carry an `updated_at`: the local catalog keeps no
//  timestamp, so a local row this page does not carry is undated. If ANY
//  live candidate of the title is undated, the whole title falls back to
//  the smallest UUID. Undated-counts-as-oldest (or as "now") would break
//  the two-holder case: A holds its own a and pulls b, B holds its own b
//  and pulls a — each would see its own row undated and the other's dated,
//  pick opposite winners, and the type would die on both. With the
//  fallback both pick the smaller UUID (Lean `holders_views_agree`). The
//  date rule therefore decides when every live namesake is in the page —
//  a first pull from an empty baseline, which is where duplicates
//  accumulated by older builds get resolved.
//
//  Losers never enter the baseline. A local loser is swapped for the
//  winner's row and leaves the array; when it is in the baseline the
//  collection diff sends its tombstone. An incoming loser is not inserted
//  and the applier tombstones it itself — `PATCH event_types?id=in.(…)&
//  deleted_at=is.null` — because a UUID that never entered the baseline is
//  invisible to the diff. Both holders do this, idempotently.
//
//  Pure: this decides; the applier runs the incoming row through the §6
//  table (`SyncDecision`) only when `incomingEntersTable` says so.
//

import Foundation

enum SyncEventTypeWinners {

    /// A type row, by id, title and — for a row the page carries — its
    /// server `updated_at` (nil for a local row the page does not carry).
    struct Namesake: Equatable {
        let id: String
        let title: String
        var updatedAt: Date? = nil
    }

    struct Resolution: Equatable {
        /// The id this device holds for the title afterwards; nil when none.
        let winnerId: String?
        /// Local live namesakes that lost: replaced by the winner's row and
        /// removed from the array. Not written to the baseline.
        let removeLocally: [String]
        /// Incoming losers to tombstone directly
        /// (`PATCH event_types?id=in.(…)&deleted_at=is.null`). Never written
        /// to the baseline.
        let tombstoneDirectly: [String]
        /// Whether the incoming row goes through the §6 table at all. False
        /// for an incoming loser: it is not inserted and gets no baseline
        /// entry.
        let incomingEntersTable: Bool
    }

    /// The tie-break order: the smallest lowercase UUID string.
    static func isWinner(_ a: String, over b: String) -> Bool {
        a.lowercased() < b.lowercased()
    }

    /// The winner among live namesakes (one title): the latest
    /// `updated_at`, ties to the smallest lowercase UUID — when every
    /// candidate is dated; otherwise the smallest lowercase UUID alone.
    static func winner(_ candidates: [Namesake]) -> Namesake? {
        let dated = candidates.allSatisfy { $0.updatedAt != nil }
        return candidates.min { a, b in
            if dated, let ta = a.updatedAt, let tb = b.updatedAt, ta != tb { return ta > tb }
            return isWinner(a.id, over: b.id)
        }
    }

    static func sameId(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    static func normalizedTitle(_ title: String) -> String {
        EventTypeTemplateStore.normalizedTitle(title)
    }

    /// - Parameters:
    ///   - localLive: the LIVE local types (dead rows are not in the array).
    ///   - incoming: the incoming row's id and title.
    ///   - incomingIsLive: false for a tombstone.
    static func resolve(localLive: [Namesake], incoming: Namesake, incomingIsLive: Bool) -> Resolution {
        let title = normalizedTitle(incoming.title)
        let namesakes = localLive.filter { normalizedTitle($0.title) == title }

        guard incomingIsLive else {
            // A tombstone removes only its own UUID (through the table); the
            // live namesakes keep whichever of them already won.
            let remaining = namesakes.filter { !sameId($0.id, incoming.id) }
            return Resolution(winnerId: winner(remaining)?.id,
                              removeLocally: [], tombstoneDirectly: [],
                              incomingEntersTable: true)
        }

        let others = namesakes.filter { !sameId($0.id, incoming.id) }
        let winnerId = winner(others + [incoming])?.id ?? incoming.id
        let incomingWins = sameId(winnerId, incoming.id)
        return Resolution(
            winnerId: winnerId,
            removeLocally: namesakes.map(\.id).filter { !sameId($0, winnerId) },
            tombstoneDirectly: incomingWins ? [] : [incoming.id],
            incomingEntersTable: incomingWins
        )
    }
}
