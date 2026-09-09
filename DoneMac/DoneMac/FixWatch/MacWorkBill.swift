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
