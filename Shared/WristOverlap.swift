//
//  WristOverlap.swift
//  Shared (Done + DoneWatch)
//
//  The phone day timeline's placement of overlapping blocks
//  (`CalendarLayout.overlapLayout`), ported line for line onto plain values
//  so the watch can run it without the phone's `Event`. Same clusters, same
//  greedy columns with rightward expansion, same stack-peek host for a
//  dominant block, same interrupt families packed into one column, same
//  creation-time order for blocks that start together.
//
//  The phone keeps its own copy; `WristOverlapParityTests` runs both on the
//  same days and requires every slot to agree. A change to one is a change
//  to both.
//

import Foundation

nonisolated struct WristOverlapItem: Equatable, Sendable {
    var id: String
    var start: Date
    var end: Date
    /// The event's creation time in whole milliseconds, the phone's
    /// ordering key for blocks that start together.
    var createdAtMillis: Int64
    /// `recurrenceParentId ?? id`: the event an interrupt names as parent.
    var anchorID: UUID
    /// The parent of an interrupt relation in the embedded state.
    var embeddedParentID: UUID?
    var isInterrupt: Bool

    init(
        id: String, start: Date, end: Date, createdAt: Date?, anchorID: UUID,
        embeddedParentID: UUID? = nil, isInterrupt: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.createdAtMillis = createdAt.map(Self.millis) ?? 0
        self.anchorID = anchorID
        self.embeddedParentID = embeddedParentID
        self.isInterrupt = isInterrupt
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// Where one block sits across the day's width, as fractions of it, and
/// how it stacks. `coverRanges` are the stretches of a stack-peek host the
/// blocks over it hide, so its title can stay clear of them.
nonisolated struct WristOverlapSlot: Equatable, Sendable {
    var x: Double
    var width: Double
    var zIndex: Double
    var depth: Int
    var coverRanges: [WristTimeSpan]

    init(x: Double, width: Double, zIndex: Double, depth: Int = 0, coverRanges: [WristTimeSpan] = []) {
        self.x = x
        self.width = width
        self.zIndex = zIndex
        self.depth = depth
        self.coverRanges = coverRanges
    }

    static let full = WristOverlapSlot(x: 0, width: 1, zIndex: 1)
}

nonisolated struct WristTimeSpan: Equatable, Sendable {
    var start: Date
    var end: Date
}

nonisolated enum WristOverlapLayout {
    /// `CalendarLayout.OverlapMode` without the held slot, which only a
    /// finger dragging an existing block needs.
    enum Mode: Equatable, Sendable {
        /// The resting day: a dominant block may become a stack-peek host.
        case auto
        /// While a draft is drawn: equal columns only, so nothing flips
        /// from frame to frame.
        case equalSplit
    }

    static let peekRatioThreshold = 1.5
    static let stripFraction = 0.5

    static func slots(
        for items: [WristOverlapItem], visibleStart: Date, visibleEnd: Date, mode: Mode = .auto
    ) -> [String: WristOverlapSlot] {
        guard items.count > 1 else {
            return Dictionary(items.map { ($0.id, .full) }, uniquingKeysWith: { a, _ in a })
        }
        var result: [String: WristOverlapSlot] = [:]
        for cluster in clusters(items, visibleStart: visibleStart, visibleEnd: visibleEnd) {
            if cluster.count == 1 {
                result[cluster[0].id] = .full
                continue
            }
            for (id, slot) in layoutCluster(
                cluster, visibleStart: visibleStart, visibleEnd: visibleEnd,
                xStart: 0, width: 1, baseZ: 1, depth: 0, mode: mode
            ) {
                result[id] = slot
            }
        }
        for item in items where result[item.id] == nil {
            result[item.id] = .full
        }
        return result
    }

    /// Connected components of strict overlap within the visible window;
    /// blocks that only touch stay apart.
    static func clusters(
        _ items: [WristOverlapItem], visibleStart: Date, visibleEnd: Date
    ) -> [[WristOverlapItem]] {
        let n = items.count
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for i in 0..<n {
            let si = max(items[i].start, visibleStart)
            let ei = min(items[i].end, visibleEnd)
            for j in (i + 1)..<n {
                let sj = max(items[j].start, visibleStart)
                let ej = min(items[j].end, visibleEnd)
                if si < ej && sj < ei {
                    let ra = find(i), rb = find(j)
                    if ra != rb { parent[ra] = rb }
                }
            }
        }
        var groups: [Int: [WristOverlapItem]] = [:]
        var order: [Int] = []
        for i in 0..<n {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(items[i])
        }
        return order.map { groups[$0]! }
    }

    private struct Group {
        let id: String
        let members: [WristOverlapItem]
        let start: Date
        let end: Date
        let firstSeenIndex: Int
    }

    private static func layoutCluster(
        _ cluster: [WristOverlapItem], visibleStart: Date, visibleEnd: Date,
        xStart: Double, width: Double, baseZ: Double, depth: Int, mode: Mode
    ) -> [(String, WristOverlapSlot)] {
        guard !cluster.isEmpty else { return [] }
        if cluster.count == 1 {
            return [(cluster[0].id, WristOverlapSlot(x: xStart, width: width, zIndex: baseZ, depth: depth))]
        }

        let embeddedParentIDs = Set(cluster.compactMap(\.embeddedParentID))
        func groupKey(_ item: WristOverlapItem) -> String {
            if let parent = item.embeddedParentID {
                return "interrupt-family:\(parent.uuidString)"
            }
            if embeddedParentIDs.contains(item.anchorID) {
                return "interrupt-family:\(item.anchorID.uuidString)"
            }
            return "occurrence:\(item.id)"
        }

        // One creation stamp per group: the earliest family parent's when
        // the family has one here, else the earliest member's.
        var groupCreated: [String: Int64] = [:]
        var groupHasParent: Set<String> = []
        for item in cluster {
            let key = groupKey(item)
            let created = item.createdAtMillis
            let isFamilyParent = item.embeddedParentID == nil && embeddedParentIDs.contains(item.anchorID)
            if isFamilyParent {
                if groupHasParent.contains(key) {
                    groupCreated[key] = min(groupCreated[key] ?? created, created)
                } else {
                    groupCreated[key] = created
                    groupHasParent.insert(key)
                }
            } else if !groupHasParent.contains(key) {
                groupCreated[key] = min(groupCreated[key] ?? created, created)
            }
        }

        let sorted = cluster.sorted { a, b in
            let sa = max(a.start, visibleStart)
            let sb = max(b.start, visibleStart)
            if sa != sb { return sa < sb }
            let groupA = groupKey(a), groupB = groupKey(b)
            if groupA != groupB {
                let createdA = groupCreated[groupA] ?? .max
                let createdB = groupCreated[groupB] ?? .max
                if createdA != createdB { return createdA < createdB }
                return groupA < groupB
            }
            let rankA = a.isInterrupt ? 1 : 0, rankB = b.isInterrupt ? 1 : 0
            if rankA != rankB { return rankA < rankB }
            let da = min(a.end, visibleEnd).timeIntervalSince(sa)
            let db = min(b.end, visibleEnd).timeIntervalSince(sb)
            if da != db { return da > db }
            if a.createdAtMillis != b.createdAtMillis { return a.createdAtMillis < b.createdAtMillis }
            return a.id < b.id
        }

        var groupedMembers: [String: [WristOverlapItem]] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, item) in sorted.enumerated() {
            let key = groupKey(item)
            groupedMembers[key, default: []].append(item)
            firstSeen[key] = min(firstSeen[key] ?? index, index)
        }
        let groups = groupedMembers.compactMap { key, members -> Group? in
            guard let first = members.first else { return nil }
            let start = members.reduce(max(first.start, visibleStart)) { min($0, max($1.start, visibleStart)) }
            let end = members.reduce(min(first.end, visibleEnd)) { max($0, min($1.end, visibleEnd)) }
            return Group(id: key, members: members, start: start, end: end, firstSeenIndex: firstSeen[key] ?? 0)
        }.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.firstSeenIndex < b.firstSeenIndex
        }

        if groups.count == 1 {
            return groups[0].members.map {
                ($0.id, WristOverlapSlot(x: xStart, width: width, zIndex: baseZ, depth: depth))
            }
        }

        // Greedy columns, start ascending, the longer first on a tie.
        var column: [String: Int] = [:]
        var columns: [[Group]] = []
        for group in groups {
            if let free = columns.firstIndex(where: { col in
                !col.contains { group.start < $0.end && $0.start < group.end }
            }) {
                column[group.id] = free
                columns[free].append(group)
            } else {
                column[group.id] = columns.count
                columns.append([group])
            }
        }
        let totalCols = columns.count

        // Rightward expansion into free neighbouring columns.
        var spanEnd: [String: Int] = [:]
        for group in groups {
            let col = column[group.id] ?? 0
            var expandTo = col
            for next in (col + 1)..<totalCols {
                if columns[next].contains(where: { group.start < $0.end && $0.start < group.end }) { break }
                expandTo = next
            }
            spanEnd[group.id] = expandTo
        }

        // Stack-peek only for a dominant host every other block overlaps and
        // that equal columns would leave partly blank.
        var peek: (host: Group, rest: [Group])?
        if mode == .auto {
            let host = groups.max { lhs, rhs in
                let l = lhs.end.timeIntervalSince(lhs.start), r = rhs.end.timeIntervalSince(rhs.start)
                if l != r { return l < r }
                return lhs.id > rhs.id
            }!
            let rest = groups.filter { $0.id != host.id }
            let hostSeconds = host.end.timeIntervalSince(host.start)
            let longestRest = rest.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
            let dominant = hostSeconds >= peekRatioThreshold * longestRest
            let reach = rest.allSatisfy { $0.start < host.end && host.start < $0.end }
            let hostCol = column[host.id] ?? 0
            let blank = (0..<totalCols).contains { col in
                guard col != hostCol else { return false }
                let painted = rest.filter { group in
                    let from = column[group.id] ?? 0
                    return from <= col && col <= (spanEnd[group.id] ?? from)
                }
                let covered = merged(painted.compactMap { group -> WristTimeSpan? in
                    let start = max(group.start, host.start), end = min(group.end, host.end)
                    return end > start ? WristTimeSpan(start: start, end: end) : nil
                }).reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
                return covered > 1.0 ? hostSeconds / covered >= peekRatioThreshold : true
            }
            if dominant && reach && blank { peek = (host, rest) }
        }

        guard let plan = peek else {
            let colWidth = totalCols > 0 ? width / Double(totalCols) : width
            var result: [(String, WristOverlapSlot)] = []
            for group in groups {
                let col = column[group.id] ?? 0
                let span = Double((spanEnd[group.id] ?? col) - col + 1)
                let slot = WristOverlapSlot(
                    x: xStart + colWidth * Double(col), width: colWidth * span, zIndex: baseZ, depth: depth
                )
                for member in group.members { result.append((member.id, slot)) }
            }
            return result
        }

        let covers = merged(plan.rest.compactMap { other -> WristTimeSpan? in
            let start = max(other.start, visibleStart), end = min(other.end, visibleEnd)
            return end > start ? WristTimeSpan(start: start, end: end) : nil
        })
        var result: [(String, WristOverlapSlot)] = []
        let hostSlot = WristOverlapSlot(x: xStart, width: width, zIndex: baseZ, depth: depth, coverRanges: covers)
        for member in plan.host.members { result.append((member.id, hostSlot)) }
        let subX = xStart + width * stripFraction
        let subWidth = width * stripFraction
        for sub in clusters(plan.rest.flatMap(\.members), visibleStart: visibleStart, visibleEnd: visibleEnd) {
            result.append(contentsOf: layoutCluster(
                sub, visibleStart: visibleStart, visibleEnd: visibleEnd,
                xStart: subX, width: subWidth, baseZ: baseZ + 0.01, depth: depth + 1, mode: mode
            ))
        }
        return result
    }

    private static func merged(_ spans: [WristTimeSpan]) -> [WristTimeSpan] {
        guard !spans.isEmpty else { return [] }
        let sorted = spans.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var out = [sorted[0]]
        for span in sorted.dropFirst() {
            if span.start <= out[out.count - 1].end {
                out[out.count - 1].end = max(out[out.count - 1].end, span.end)
            } else {
                out.append(span)
            }
        }
        return out
    }
}
