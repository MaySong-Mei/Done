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
    /// Across the day's width and in stacking order, as the phone's day
    /// timeline places it (`WristOverlapLayout`). An interrupt embedded in
    /// a parent on the page takes the parent's slot, one level up, and is
    /// drawn inset on it (`parentID`).
    var slot: WristOverlapSlot
    var parentID: String?
    var isCurrent: Bool
    /// The block's identity from one snapshot to the next: the event and
    /// which of its blocks on the page this is. An occurrence id changes
    /// with the range (and a block created here changes it once more when
    /// the phone's copy replaces the watch's own), so motion follows this.
    var motionKey: String
}

/// One day's blocks, and where the draft being drawn sits among them.
nonisolated struct WristDayPage: Equatable, Sendable {
    var blocks: [WristDayBlock]
    var draftSlot: WristOverlapSlot?
}

nonisolated enum WristDayLayout {
    static let draftID = "wrist.draft"

    static func blocks(
        _ occurrences: [WristOccurrence], dismissed: [WristDismissal],
        dayStart: Date, dayEnd: Date, now: Date, currentID: String?
    ) -> [WristDayBlock] {
        page(occurrences, dismissed: dismissed, dayStart: dayStart, dayEnd: dayEnd,
             now: now, currentID: currentID).blocks
    }

    /// The day as the phone's day timeline would draw it. With a `draft`,
    /// the draft takes a column of its own and everything equal-splits
    /// around it — the phone's drag to create — so no block becomes a
    /// stack-peek host mid-draw.
    static func page(
        _ occurrences: [WristOccurrence], dismissed: [WristDismissal],
        dayStart: Date, dayEnd: Date, now: Date, currentID: String?,
        draft: WristTimeSpan? = nil
    ) -> WristDayPage {
        var placed: [WristDayBlock] = []
        var storeOrder: [String: Int] = [:]
        for (index, occurrence) in occurrences.enumerated() {
            storeOrder[occurrence.id] = storeOrder[occurrence.id] ?? index
            var end = occurrence.isOpenEnded ? min(now, dayEnd) : occurrence.end
            if let dismissal = dismissed.first(where: { $0.applies(to: occurrence) }) {
                end = min(end, max(dismissal.tappedAt, occurrence.start))
            }
            let start = max(occurrence.start, dayStart)
            end = min(end, dayEnd)
            guard end > start else { continue }
            placed.append(WristDayBlock(
                id: occurrence.id, occurrence: occurrence, start: start, end: end,
                slot: .full, parentID: nil, isCurrent: occurrence.id == currentID, motionKey: ""
            ))
        }
        // A fixed order, so the same day in any order lays out the same.
        placed.sort { ($0.start, $1.end, $0.id) < ($1.start, $0.end, $1.id) }

        // Motion keys: the event, then its blocks in order down the page.
        var seen: [UUID: Int] = [:]
        for i in placed.indices {
            let eventID = placed[i].occurrence.eventID
            let ordinal = seen[eventID, default: 0]
            seen[eventID] = ordinal + 1
            placed[i].motionKey = "\(eventID.uuidString)#\(ordinal)"
        }

        // The phone's interrupt context: an embedded interrupt whose parent
        // is on the page and overlaps it is drawn on that parent. Of two
        // blocks of one series, the one later in the phone's store order
        // (the input's) is the parent, as on the phone.
        var parents: [UUID: Int] = [:]
        let inStoreOrder = placed.indices.sorted {
            (storeOrder[placed[$0].id] ?? 0, $0) < (storeOrder[placed[$1].id] ?? 0, $1)
        }
        for i in inStoreOrder where !placed[i].occurrence.isInterrupt {
            parents[placed[i].occurrence.anchorID] = i
        }
        var embeddedIn: [Int: Int] = [:]
        for i in placed.indices {
            let occurrence = placed[i].occurrence
            guard occurrence.isInterrupt, let parentID = occurrence.interruptParentID,
                  let p = parents[parentID],
                  placed[i].end > placed[p].start && placed[i].start < placed[p].end else { continue }
            embeddedIn[i] = p
        }

        var items = placed.indices.filter { embeddedIn[$0] == nil }.map { i -> WristOverlapItem in
            let occurrence = placed[i].occurrence
            return WristOverlapItem(
                id: placed[i].id, start: placed[i].start, end: placed[i].end,
                createdAt: occurrence.createdAt, anchorID: occurrence.anchorID,
                embeddedParentID: occurrence.interruptParentID, isInterrupt: occurrence.isInterrupt
            )
        }
        if let draft {
            items.append(WristOverlapItem(
                id: draftID, start: draft.start, end: draft.end, createdAt: .distantFuture, anchorID: UUID()
            ))
        }
        let slots = WristOverlapLayout.slots(
            for: items, visibleStart: dayStart, visibleEnd: dayEnd, mode: draft == nil ? .auto : .equalSplit
        )
        for i in placed.indices where embeddedIn[i] == nil {
            placed[i].slot = slots[placed[i].id] ?? .full
        }
        for (child, parent) in embeddedIn {
            var slot = placed[parent].slot
            slot.zIndex += 1
            slot.coverRanges = []
            placed[child].slot = slot
            placed[child].parentID = placed[parent].id
        }
        // Drawn bottom to top: stacking order, then down the page.
        let drawn = placed.enumerated().sorted { a, b in
            a.element.slot.zIndex != b.element.slot.zIndex
                ? a.element.slot.zIndex < b.element.slot.zIndex
                : a.offset < b.offset
        }.map(\.element)
        return WristDayPage(blocks: drawn, draftSlot: draft == nil ? nil : slots[draftID])
    }

    /// The hour rows of the day starting at `dayStart`: each row's start and
    /// its clock hour. On a DST day there are 23 or 25 of them, and the
    /// clock hours skip or repeat — labels follow the clock, positions the
    /// elapsed time.
    static func hourRows(dayStart: Date, dayEnd: Date, calendar: Calendar) -> [(start: Date, hour: Int)] {
        var rows: [(Date, Int)] = []
        var t = dayStart
        while t < dayEnd {
            rows.append((t, calendar.component(.hour, from: t)))
            t = t.addingTimeInterval(3600)
        }
        return rows
    }

    /// Where `date` falls in the day, 0…1.
    static func fraction(_ date: Date, dayStart: Date, dayEnd: Date) -> Double {
        let span = dayEnd.timeIntervalSince(dayStart)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(dayStart) / span))
    }
}

/// Long-press-and-drag on the today page, as data — the phone's drag to
/// create on a day column. Positions are points down from the top of the
/// day; both ends land on the 15-minute grid, or on the edge of a block on
/// the page when the finger comes within `snapPoints` of it (tested against
/// the unrounded time, as the phone does, so a grid round cannot push an end
/// out of reach of the magnet).
nonisolated struct WristDraftMapping: Equatable, Sendable {
    var dayStart: Date
    var dayEnd: Date
    /// Points the whole day spans.
    var height: Double
    /// Start and end of every block on the page.
    var edges: [Date]
    var snapPoints: Double = 8

    /// One end of the draft: where it lands, and the block edge it is held
    /// on, if any.
    struct Point: Equatable, Sendable {
        var time: Date
        var edge: Date?
    }

    /// The draft's range, start before end whichever way the finger went,
    /// never under the minimum and never outside the day. `moving` is the
    /// finger's end — each change of it is one tick.
    struct Range: Equatable, Sendable {
        var start: Date
        var end: Date
        var moving: Point
    }

    private var span: TimeInterval { dayEnd.timeIntervalSince(dayStart) }

    /// The instant under `y`, unrounded, held to the day.
    func rawTime(atY y: Double) -> Date {
        guard height > 0, span > 0 else { return dayStart }
        return dayStart.addingTimeInterval(span * min(height, max(0, y)) / height)
    }

    func point(atY y: Double) -> Point {
        let raw = rawTime(atY: y)
        let grid = min(max(WristTiming.snappedToGrid(raw), dayStart), dayEnd)
        guard height > 0, snapPoints > 0 else { return Point(time: grid, edge: nil) }
        var best: Date?
        var bestDistance = snapPoints / height * span
        for edge in edges where edge >= dayStart && edge <= dayEnd {
            let distance = abs(edge.timeIntervalSince(raw))
            if distance <= bestDistance {
                bestDistance = distance
                best = edge
            }
        }
        return best.map { Point(time: $0, edge: $0) } ?? Point(time: grid, edge: nil)
    }

    /// The draft between the press at `anchorY` and the finger at
    /// `currentY`. Too short, it grows away from the press, in the
    /// direction the finger went (down when it has not moved).
    func range(anchorY: Double, currentY: Double) -> Range {
        let anchor = point(atY: anchorY).time
        let moving = point(atY: currentY)
        let minimum = WristTiming.minimumDuration
        let upward = moving.time < anchor || (moving.time == anchor && currentY < anchorY)
        var start = min(anchor, moving.time)
        var end = max(anchor, moving.time)
        if end.timeIntervalSince(start) < minimum {
            if upward {
                start = end.addingTimeInterval(-minimum)
            } else {
                end = start.addingTimeInterval(minimum)
            }
        }
        if start < dayStart {
            start = dayStart
            end = max(end, start.addingTimeInterval(minimum))
        }
        if end > dayEnd {
            end = dayEnd
            start = min(start, end.addingTimeInterval(-minimum))
        }
        return Range(start: start, end: end, moving: moving)
    }

    /// A press can start a draft only on empty time: not inside a block.
    func isEmpty(atY y: Double, blocks: [WristDayBlock]) -> Bool {
        let time = rawTime(atY: y)
        return !blocks.contains { $0.start <= time && time < $0.end }
    }
}

/// What a hold on a block grabs: the whole block, or one of its edges.
nonisolated enum WristEditMode: Equatable, Sendable {
    case move, resizeTop, resizeBottom
}

/// Long-press-and-drag on a block of the today page, as data — the phone's
/// move and edge resize on its day timeline. A press near the top or bottom
/// edge resizes that edge, anywhere else moves the block. Like the phone's
/// drag, the finger's travel moves an edge in whole quarter hours (a block
/// off the grid keeps its minutes), and an edge that comes within
/// `snapPoints` of another block's edge lands on it. The block never gets
/// shorter than the minimum, an edge is never dragged out of the day, and a
/// move never takes the block further out of the day than it already was.
nonisolated struct WristBlockEdit: Equatable, Sendable {
    /// The day's geometry; `edges` are every other block's edges.
    var mapping: WristDraftMapping
    /// The range being edited, unclipped.
    var original: WristTimeSpan
    var mode: WristEditMode
    /// Where the press was, in the day's points.
    var anchorY: Double

    /// The points at a block's top and bottom that grab its edge: a quarter
    /// of the block, but never less than a fingertip can aim at and never so
    /// much that a tall block is hard to move. A block without room for a
    /// fingertip at both edges and one in the middle only moves.
    static let minimumEdgeZone: Double = 12
    static let maximumEdgeZone: Double = 18
    static let edgeZoneShare: Double = 0.25

    static func edgeZone(blockHeight: Double) -> Double {
        guard blockHeight >= 3 * minimumEdgeZone else { return 0 }
        return min(maximumEdgeZone, max(minimumEdgeZone, blockHeight * edgeZoneShare))
    }

    /// The grab for a press `pressY` points below the block's top. An edge
    /// the day clips (the block runs in from yesterday or on into tomorrow)
    /// cannot be grabbed: a press there moves the block.
    static func mode(
        pressY: Double, blockHeight: Double, canResizeTop: Bool, canResizeBottom: Bool
    ) -> WristEditMode {
        let zone = edgeZone(blockHeight: blockHeight)
        guard zone > 0 else { return .move }
        if canResizeTop, pressY < zone { return .resizeTop }
        if canResizeBottom, pressY > blockHeight - zone { return .resizeBottom }
        return .move
    }

    /// The edited range with the finger at `currentY`. `moving` is the edge
    /// that follows the finger (a move's start, unless its end is the one on
    /// a magnet) — each change of it is one tick.
    func range(currentY: Double) -> WristDraftMapping.Range {
        let span = mapping.dayEnd.timeIntervalSince(mapping.dayStart)
        guard mapping.height > 0, span > 0 else {
            return .init(start: original.start, end: original.end, moving: .init(time: original.start, edge: nil))
        }
        let perPoint = span / mapping.height
        let travel = (currentY - anchorY) * perPoint
        let quarter = TimeInterval(WristTiming.gridMinutes * 60)
        let steps = (travel / quarter).rounded() * quarter
        let reach = mapping.snapPoints * perPoint
        let minimum = WristTiming.minimumDuration
        let lower = min(original.start, mapping.dayStart)
        let upper = max(original.end, mapping.dayEnd)

        func magnet(_ raw: Date) -> (edge: Date, distance: TimeInterval)? {
            var best: (Date, TimeInterval)?
            for edge in mapping.edges {
                let distance = abs(edge.timeIntervalSince(raw))
                if distance <= reach, distance <= (best?.1 ?? .infinity) { best = (edge, distance) }
            }
            return best
        }

        switch mode {
        case .move:
            let length = original.end.timeIntervalSince(original.start)
            var start = original.start.addingTimeInterval(steps)
            var held: Date?
            let byStart = magnet(original.start.addingTimeInterval(travel))
            let byEnd = magnet(original.end.addingTimeInterval(travel))
            if let byStart, byStart.distance <= (byEnd?.distance ?? .infinity) {
                start = byStart.edge
                held = byStart.edge
            } else if let byEnd {
                start = byEnd.edge.addingTimeInterval(-length)
                held = byEnd.edge
            }
            start = max(start, lower)
            start = min(start, upper.addingTimeInterval(-length))
            let end = start.addingTimeInterval(length)
            if let edge = held, edge != start, edge != end { held = nil }
            let movingTime = held.map { $0 == end ? end : start } ?? start
            return .init(start: start, end: end, moving: .init(time: movingTime, edge: held))

        case .resizeBottom:
            var end = original.end.addingTimeInterval(steps)
            var held: Date?
            if let hit = magnet(original.end.addingTimeInterval(travel)) {
                end = hit.edge
                held = hit.edge
            }
            end = min(max(end, original.start.addingTimeInterval(minimum)), upper)
            if held != end { held = nil }
            return .init(start: original.start, end: end, moving: .init(time: end, edge: held))

        case .resizeTop:
            var start = original.start.addingTimeInterval(steps)
            var held: Date?
            if let hit = magnet(original.start.addingTimeInterval(travel)) {
                start = hit.edge
                held = hit.edge
            }
            start = max(min(start, original.end.addingTimeInterval(-minimum)), lower)
            if held != start { held = nil }
            return .init(start: start, end: original.end, moving: .init(time: start, edge: held))
        }
    }
}

/// A finger on the today page from touch-down to lift, as data. The hold is
/// timed here rather than by a long-press gesture: a long press followed by
/// a drag learns where the finger went down only from the drag's first
/// sample, and a finger held still on the glass sends none — so a still
/// hold drew nothing and played nothing. Kept within `slop` of where it
/// went down for `duration`, with the day not scrolling under it, the touch
/// arms and reads what it is on at once (`read`); moved further first, or
/// scrolled, it is no hold and the scroll view keeps it.
nonisolated struct WristHold: Equatable, Sendable {
    /// The phone's event hold is a little shorter and its create hold a
    /// little longer; this sits between them.
    static let duration: TimeInterval = 0.4
    /// How far a still finger may wander. Under a quarter hour at the
    /// smallest zoom, so a drag of one grid step is never taken for
    /// stillness, and as much as UIKit's own long press allows.
    static let slop: Double = 10
    /// How far the day may move under a pending hold before it counts as
    /// scrolled: settling by a fraction of a point is not a scroll.
    static let scrollTolerance: Double = 1
    /// The hold timer and the wall clock round differently: a fire this
    /// close to `duration` counts as on time.
    static let timerLeeway: TimeInterval = 0.01

    enum Phase: Equatable, Sendable {
        case pending, armed, cancelled(Cancel)

        /// For the gesture trail.
        var name: String {
            switch self {
            case .pending: return "pending"
            case .armed: return "armed"
            case .cancelled(let reason): return "cancelled-\(reason.rawValue)"
            }
        }
    }

    enum Cancel: String, Equatable, Sendable {
        case moved, scrolled
    }

    /// When and where (in the scroll view's points) the finger went down,
    /// and how far the day was scrolled then.
    let downAt: Date
    let downX: Double
    let downY: Double
    let downScroll: Double
    private(set) var phase: Phase = .pending

    init(downAt: Date, x: Double, y: Double, scroll: Double) {
        self.downAt = downAt
        downX = x
        downY = y
        downScroll = scroll
    }

    var isPending: Bool { phase == .pending }
    var isArmed: Bool { phase == .armed }

    /// A later sample of the same touch. The phase only changes while the
    /// hold is pending: once armed, the finger is drawing.
    mutating func track(x: Double, y: Double) {
        guard isPending, hypot(x - downX, y - downY) > Self.slop else { return }
        phase = .cancelled(.moved)
    }

    /// The day is now scrolled to `offset`, or the scroll view began a pan.
    mutating func scrolled(to offset: Double) {
        guard isPending, abs(offset - downScroll) > Self.scrollTolerance else { return }
        phase = .cancelled(.scrolled)
    }

    mutating func scrollBegan() {
        guard isPending else { return }
        phase = .cancelled(.scrolled)
    }

    /// The hold timer fired at `now`: a touch still pending arms once
    /// `duration` has passed since it went down. True when it armed.
    mutating func arm(at now: Date) -> Bool {
        guard isPending, now.timeIntervalSince(downAt) >= Self.duration - Self.timerLeeway else { return false }
        phase = .armed
        return true
    }

    /// The block under the press, as the hold needs it: its top and height
    /// in the day's points, and what the phone lets the watch do with it.
    struct Target: Equatable, Sendable {
        var minY: Double
        var height: Double
        var editable: Bool
        var canResizeTop: Bool
        var canResizeBottom: Bool
    }

    /// What an armed hold does with the finger still where it went down:
    /// on empty time, a draft of the shortest length from the grid mark
    /// nearest the press (the draw's own range with the finger not yet
    /// moved, so the first drag step grows it from there); on a block the
    /// watch may edit, a grab of its edge or the whole of it; on any other
    /// block, a refusal.
    enum Reading: Equatable, Sendable {
        case draft(WristDraftMapping.Range)
        case grab(WristEditMode)
        case refused
        case nothing
    }

    static func read(pressY: Double, target: Target?, emptyAtPress: Bool, mapping: WristDraftMapping) -> Reading {
        if let target {
            guard target.editable else { return .refused }
            return .grab(WristBlockEdit.mode(
                pressY: pressY - target.minY, blockHeight: target.height,
                canResizeTop: target.canResizeTop, canResizeBottom: target.canResizeBottom
            ))
        }
        guard emptyAtPress else { return .nothing }
        return .draft(mapping.range(anchorY: pressY, currentY: pressY))
    }

    /// What lifting the finger does: a draft goes to the type picker —
    /// moved or not — and an edit that changed the range is sent.
    enum Release: Equatable, Sendable {
        case pick, sendEdit, none
    }

    static func release(hasDraft: Bool, editChanged: Bool) -> Release {
        if hasDraft { return .pick }
        if editChanged { return .sendEdit }
        return .none
    }
}

/// The range the phone stores when the watch asks for `requested` in place
/// of `original` — the same on both sides, so the watch shows at once what
/// the phone will keep. An edge left where it was stays; one that moved is
/// kept when it is on the 15-minute grid, a whole number of quarter hours
/// from where it was (the phone's drag keeps an off-grid block's minutes),
/// or on another block's edge (the magnet); anything else goes to the
/// nearest grid mark. A move keeps the length whichever edge holds it.
/// Then the minimum length, grown from the edge that did not move. Nil for
/// an empty or inverted request.
nonisolated enum WristRangeEdit {
    static func settled(original: WristTimeSpan, requested: WristTimeSpan, edges: [Date]) -> WristTimeSpan? {
        guard requested.end > requested.start else { return nil }
        let quarter = TimeInterval(WristTiming.gridMinutes * 60)
        /// The edge as kept, or nil when it has to go to the grid.
        func kept(_ new: Date, from old: Date) -> Date? {
            if WristTiming.sameInstant(new, old) { return old }
            if let edge = edges.first(where: { WristTiming.sameInstant($0, new) }) { return edge }
            let grid = WristTiming.snappedToGrid(new)
            if WristTiming.sameInstant(grid, new) { return grid }
            let steps = (new.timeIntervalSince(old) / quarter).rounded()
            let stepped = old.addingTimeInterval(steps * quarter)
            if WristTiming.sameInstant(stepped, new) { return stepped }
            return nil
        }
        var start: Date
        var end: Date
        let length = original.end.timeIntervalSince(original.start)
        let moved = !WristTiming.sameInstant(requested.start, original.start)
            && abs(requested.end.timeIntervalSince(requested.start) - length) < WristTiming.instantTolerance
        if moved {
            // A move keeps the length: one edge held is enough (a block
            // moved onto a neighbour's edge by its end keeps its start's
            // minutes), else its start goes to the grid.
            if let held = kept(requested.start, from: original.start) {
                start = held
            } else if let held = kept(requested.end, from: original.end) {
                start = held.addingTimeInterval(-length)
            } else {
                start = WristTiming.snappedToGrid(requested.start)
            }
            end = start.addingTimeInterval(length)
        } else {
            start = kept(requested.start, from: original.start) ?? WristTiming.snappedToGrid(requested.start)
            end = kept(requested.end, from: original.end) ?? WristTiming.snappedToGrid(requested.end)
        }
        let minimum = WristTiming.minimumDuration
        if end.timeIntervalSince(start) < minimum {
            if start != original.start && end == original.end {
                start = end.addingTimeInterval(-minimum)
            } else {
                end = start.addingTimeInterval(minimum)
            }
        }
        return WristTimeSpan(start: start, end: end)
    }
}

/// The stats page's periods: the last N days, today included. Rolling, so
/// none of them collapses into today at the start of a week or a month.
nonisolated enum WristStatsPeriod: String, CaseIterable, Sendable {
    case today, threeDays, sevenDays, thirtyDays

    var days: Int {
        switch self {
        case .today: return 1
        case .threeDays: return 3
        case .sevenDays: return 7
        case .thirtyDays: return 30
        }
    }

    /// `[start, end)` around `asOf`, whole days of `calendar`.
    func span(asOf: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let today = CategoryStats.range(of: .today, containing: asOf, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: 1 - days, to: today.start) ?? today.start
        return (start, today.end)
    }
}

/// One period's figures on the elapsed basis: the categories' hours and
/// the elapsed hours nothing was logged in.
nonisolated struct WristStatsFigures: Equatable {
    var status: CategoryStatsStatus
    var categories: [CategoryHours]
    /// The rows together. Under `WristOverlapRule.full` this can be more
    /// than `loggedHours`.
    var totalHours: Double
    /// The period's elapsed hours, less the time only left-out types
    /// cover (`WristStatsTally.leftOutHours`).
    var elapsedHours: Double
    /// Stale only because the days the period needs are not on the watch —
    /// left out to fit the transfer, or never written by an older phone —
    /// while the stats themselves are current.
    var leftOutToFit = false
    /// Wall-clock hours something counted covers: what the clock row's
    /// share is of, whichever overlap rule the rows use.
    var loggedHours: Double = 0

    var unloggedHours: Double { max(0, elapsedHours - loggedHours) }

    /// Read in the payload's own calendar, like the widget, so the days line
    /// up with the slices whatever zone the watch is in. Categories the
    /// payload marks left out (`CategoryStatsPayload.markingLeftOut`) count
    /// nowhere.
    static func of(
        _ payload: CategoryStatsPayload?, period: WristStatsPeriod, asOf: Date, overlap: WristOverlapRule = .split
    ) -> WristStatsFigures {
        guard let payload else { return WristStatsFigures(status: .noData, categories: [], totalHours: 0, elapsedHours: 0) }
        let span = period.span(asOf: asOf, calendar: payload.resolvedCalendar())
        let status = CategoryStats.status(of: payload, span: span, asOf: asOf, basis: .elapsed)
        guard status == .ok else {
            let current = status == .stale && (payload.coverageEnd ?? .distantPast) > asOf
            return WristStatsFigures(status: status, categories: [], totalHours: 0, elapsedHours: 0, leftOutToFit: current)
        }
        let tally = WristStatsTally.of(payload, span: span, asOf: asOf, overlap: overlap)
        let ranked = CategoryStats.ranked(tally.hours, colors: CategoryStats.colors(in: payload))
        return WristStatsFigures(
            status: status, categories: ranked,
            totalHours: ranked.reduce(0) { $0 + $1.hours },
            elapsedHours: max(0, CategoryStats.elapsedHours(in: span, asOf: asOf) - tally.leftOutHours),
            loggedHours: tally.loggedHours
        )
    }
}
