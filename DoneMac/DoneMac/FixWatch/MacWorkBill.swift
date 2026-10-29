//
//  MacWorkBill.swift
//  DoneMac
//
//  The work-bill: what one user action costs, as live counters (#219 —
//  "the bill is pinned as assertions and tripwires"). Pure counters, O(1)
//  bumps, no I/O; mirrors the iOS ResidentObservationModel split where the
//  model counts and someone else persists.
//

import Foundation

@MainActor
final class MacWorkBill {
    enum Counter: String, CaseIterable, Sendable {
        case storeCommits
        case recordsRewritten
        case deltasEmitted
        case observerNotifications
        case dominoPushes
        case dominoHeartbeats
        case clockTicksThirtySeconds
        case clockTicksMinute
        case clockTicksDay
        /// Tripwire — expected 0: the hub must be suspended while occluded.
        case clockTicksWhileOccluded
        /// Tripwire — expected 0 after load (plan risk #4).
        case sidecarOrphansSeen
        /// Tripwire — expected 0: the sidecar file was unreadable at load;
        /// per-record revision history is frozen for this run (QA finding 2).
        case sidecarUnreadableSeen
        /// Tripwire — expected 0: a durable write failed and its snapshot is
        /// being held for retry (review finding 5 — failures must surface).
        case persistWriteFailuresSeen
        /// Tripwire — expected 0: a mutation arrived before load() finished
        /// and was refused (review finding 2 / QA finding 3).
        case preLoadMutationRefused
        case dayModelBuilds
        case dayModelHits
        case overlayBuilds
        case surfaceRebuilds
        /// The todo drawer's own rebuild counter — separate from the
        /// calendar surface so recipient-scoping is attributable
        /// (review round-3 F8: a shared counter made the drawer's gate a
        /// guaranteed mutation survivor).
        case todoSurfaceRebuilds
        /// Tripwire — expected 0: the incremental OccurrenceIndex or a
        /// still-cached DayModel diverged from a fresh build (plan risk #6
        /// shadow-compare). DEBUG-only in both detection and healing — a
        /// release build neither counts nor repairs; the test gate is the
        /// release defense.
        case indexShadowMismatches
    }

    private(set) var counts: [Counter: Int] = [:]

    func bump(_ counter: Counter, by amount: Int = 1) {
        counts[counter, default: 0] += amount
    }

    func count(_ counter: Counter) -> Int {
        counts[counter] ?? 0
    }

    func reset() {
        counts = [:]
    }

    func snapshot() -> [String: Int] {
        counts.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
    }
}
