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
//  only, the winner is the smallest lowercase UUID string — computed here,
//  never `dedupedByTitle`'s "first one seen". A tombstone removes only its
//  own UUID and takes no part in choosing a winner (Lean
//  `naive_dead_namesake_erases_live_type_witness`).
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

    /// A type row, by id and title.
    struct Namesake: Equatable {
        let id: String
        let title: String
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

    /// The winner order: the smallest lowercase UUID string.
    static func isWinner(_ a: String, over b: String) -> Bool {
        a.lowercased() < b.lowercased()
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
            return Resolution(winnerId: smallest(remaining.map(\.id)),
                              removeLocally: [], tombstoneDirectly: [],
                              incomingEntersTable: true)
        }

        let others = namesakes.filter { !sameId($0.id, incoming.id) }
        let winner = smallest(others.map(\.id) + [incoming.id]) ?? incoming.id
        let incomingWins = sameId(winner, incoming.id)
        return Resolution(
            winnerId: winner,
            removeLocally: namesakes.map(\.id).filter { !sameId($0, winner) },
            tombstoneDirectly: incomingWins ? [] : [incoming.id],
            incomingEntersTable: incomingWins
        )
    }

    private static func smallest(_ ids: [String]) -> String? {
        ids.min { isWinner($0, over: $1) }
    }
}
