//
//  WristDay.swift
//  Shared (Done + DoneWatch)
//
//  The watch's "today" page as data: which blocks the day timeline draws,
//  where, and in which column. Pure and platform-free so DoneTests can pin
//  it; the watch view only turns fractions of the day into points.
//

import Foundation

nonisolated struct WristDayBlock: Equatable, Identifiable, Sendable {
    var id: String
    var occurrence: WristOccurrence
    /// Clipped to the day. `end` is the instant the block is drawn to: the
    /// occurrence's end, or now for an open-ended (running timer) one, or
    /// the tap for a session finished on this watch.
    var start: Date
    var end: Date
    /// Column within its cluster of overlapping blocks, and the cluster's
    /// column count. Interrupts sit on top of whatever they interrupt and
    /// always take the full width (lane 0 of 1).
    var lane: Int
    var lanes: Int
    var isCurrent: Bool
}

nonisolated enum WristDayLayout {
    static func blocks(
        _ occurrences: [WristOccurrence], dismissed: [WristDismissal],
        dayStart: Date, dayEnd: Date, now: Date, currentID: String?
    ) -> [WristDayBlock] {
        var placed: [WristDayBlock] = []
        for occurrence in occurrences {
            var end = occurrence.isOpenEnded ? min(now, dayEnd) : occurrence.end
            if let dismissal = dismissed.first(where: { $0.applies(to: occurrence) }) {
                end = min(end, max(dismissal.tappedAt, occurrence.start))
            }
            let start = max(occurrence.start, dayStart)
            end = min(end, dayEnd)
            guard end > start else { continue }
            placed.append(WristDayBlock(
                id: occurrence.id, occurrence: occurrence, start: start, end: end,
                lane: 0, lanes: 1, isCurrent: occurrence.id == currentID
            ))
        }
        placed.sort { ($0.start, $1.end) < ($1.start, $0.end) }

        // Greedy columns per cluster of overlapping (non-interrupt) blocks.
        var clusterIndices: [Int] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func closeCluster() {
            for i in clusterIndices { placed[i].lanes = max(1, laneEnds.count) }
            clusterIndices = []
            laneEnds = []
        }
        for i in placed.indices where !placed[i].occurrence.isInterrupt {
            if placed[i].start >= clusterEnd { closeCluster() }
            if let free = laneEnds.firstIndex(where: { $0 <= placed[i].start }) {
                placed[i].lane = free
                laneEnds[free] = placed[i].end
            } else {
                placed[i].lane = laneEnds.count
                laneEnds.append(placed[i].end)
            }
            clusterIndices.append(i)
            clusterEnd = max(clusterEnd, placed[i].end)
        }
        closeCluster()
        // Interrupts last, so they draw on top.
        return placed.filter { !$0.occurrence.isInterrupt } + placed.filter { $0.occurrence.isInterrupt }
    }

    /// Where `date` falls in the day, 0…1.
    static func fraction(_ date: Date, dayStart: Date, dayEnd: Date) -> Double {
        let span = dayEnd.timeIntervalSince(dayStart)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(dayStart) / span))
    }
}
