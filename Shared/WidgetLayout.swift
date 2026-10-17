import Foundation
import CoreGraphics

/// Pure layout arithmetic for the home-screen widgets (gh#239).
///
/// Lives here, beside `WidgetTimelineSchedule`, for the same reason that one
/// does: the widget target has no test bundle, so anything whose *correctness*
/// is arithmetic rather than appearance has to live in a file BOTH targets
/// compile, and gets its behavioural tests from `DoneTests`.  The views in
/// `DoneWidget.swift` keep only the drawing.
///
/// Everything here is expressed in fractions of the available box or in points
/// the caller measured, never in a hardcoded widget size — the same widget is
/// handed 148, 158 and 170 point squares depending on the device, and gh#239
/// F2/F4 were both "a constant that only fit the 158 case".
enum WidgetLayout {

    // MARK: - Mini timeline: horizontal placement

    /// Where one occurrence sits across the mini timeline's event lane.
    ///
    /// `x` and `width` are fractions of the lane, so the view multiplies by
    /// whatever width it actually got.  `isOverlay` marks an interrupt drawn
    /// *inside* its parent's slot (the canvas' leading-inset convention)
    /// rather than as a lane citizen of its own.
    struct Slot: Equatable {
        var x: Double
        var width: Double
        var isOverlay: Bool

        static let full = Slot(x: 0, width: 1, isOverlay: false)
    }

    /// Horizontal slots for one entry's occurrences, in the order given.
    ///
    /// Mirrors the canvas (`CalendarLayout.overlapLayout` in `.equalSplit`
    /// spirit): union-find the time-overlap clusters, greedy-pack each cluster
    /// into columns, then let every block expand rightward through columns that
    /// hold nothing concurrent with it.
    ///
    /// The predecessor computed a column index and a column *count* per event
    /// from that event's own overlap set (gh#239 F1).  Neighbours in one
    /// cluster therefore disagreed about how many columns the cluster had, so
    /// their fractions were taken against different denominators and their
    /// x-ranges intersected — a 13:30-15:00 / 14:00-15:30 / 15:15-16:15
    /// staircase put two concurrent blocks on top of each other by 14% of the
    /// lane.  A cluster-wide denominator is what makes that impossible, and
    /// `WidgetLayoutTests` asserts the impossibility directly: no two
    /// time-overlapping lane citizens may have intersecting x-ranges.
    ///
    /// An interrupt is an overlay only when its parent is itself a lane citizen
    /// in THIS list.  When the parent is missing — it is an all-day event
    /// (`WidgetTimelineSchedule.events` filters those out), or its occurrence
    /// falls on another day — the interrupt is packed like any other block.
    /// The predecessor fell back to the interrupt's own untouched default slot,
    /// which was full width, so an orphan interrupt painted over the whole lane
    /// (gh#239 F8).
    ///
    /// `window` is the span the view draws (`miniWindow(now:)`). Only what
    /// shows in it is packed, clamped to it: an event that ended an hour above
    /// the top edge used to claim a column and squeeze the block that WAS
    /// visible into half the lane (gh#245 1). `nil` packs every occurrence
    /// whole.
    ///
    /// A lane citizen is packed over its FAMILY's span — itself plus every
    /// interrupt overlaid on it — because the overlay is drawn at its own time
    /// in the parent's column: an interrupt running past its parent's end was
    /// painted over whatever lane block sat in that column next (gh#239 sim QA).
    static func miniTimelineSlots(
        for events: [SharedEventSnapshot], window: DateInterval? = nil
    ) -> [Slot] {
        guard !events.isEmpty else { return [] }

        // 1. Resolve each interrupt to the lane citizen it overlays, if any.
        var overlays = [Int?](repeating: nil, count: events.count)
        for (i, event) in events.enumerated() where event.isInterrupt == true {
            guard let parentID = event.parentEventID else { continue }
            // Prefer the parent occurrence this interrupt actually sits inside:
            // a recurring parent can appear more than once in one window.
            let inside = events.firstIndex {
                $0.isInterrupt != true
                    && $0.resolvedEventID == parentID
                    && $0.startDate <= event.startDate
                    && $0.endDate > event.startDate
            }
            // The fallback needs a time test too. With none, an interrupt the
            // app calls `.detached` — dragged out of its parent, parent still
            // on the day — inherited the parent's slot and was drawn at its
            // own y, on top of whatever lane citizen owns that time. That is
            // the same symptom F8 named for the orphan case, on the subset
            // where the parent IS present (gh#239 QA). Overlapping at all is
            // enough to keep the overlay (the app's own `.embedded` predicate
            // in `EventStore.resolveInterruptRelationState` requires no more);
            // disjoint falls through to packing.
            overlays[i] = inside ?? events.firstIndex {
                $0.isInterrupt != true
                    && $0.resolvedEventID == parentID
                    && $0.startDate < event.endDate
                    && $0.endDate > event.startDate
            }
        }

        // The span each lane citizen is packed over: its family's, clamped to
        // the window. A family with nothing in the window is not packed.
        var spans: [Int: (start: Date, end: Date)] = [:]
        for i in events.indices where overlays[i] == nil {
            spans[i] = (events[i].startDate, events[i].endDate)
        }
        for (i, parentIdx) in overlays.enumerated() {
            guard let parentIdx, let span = spans[parentIdx] else { continue }
            spans[parentIdx] = (min(span.start, events[i].startDate), max(span.end, events[i].endDate))
        }
        if let window {
            for (i, span) in spans {
                let start = max(span.start, window.start), end = min(span.end, window.end)
                spans[i] = end > start ? (start, end) : nil
            }
        }

        let citizens = events.indices.filter { overlays[$0] == nil && spans[$0] != nil }
        var slots = [Slot](repeating: .full, count: events.count)
        guard !citizens.isEmpty else { return slots }
        func span(_ member: Int) -> (start: Date, end: Date) { spans[citizens[member]]! }

        // 2. Union-find the time-overlap clusters among lane citizens.
        var parent = Array(0..<citizens.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for a in citizens.indices {
            for b in (a + 1)..<citizens.count {
                let ea = span(a), eb = span(b)
                if ea.start < eb.end && eb.start < ea.end {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[ra] = rb }
                }
            }
        }
        var clusters: [Int: [Int]] = [:]
        for a in citizens.indices { clusters[find(a), default: []].append(a) }

        // 3. Greedy column packing + rightward expansion, per cluster.
        for cluster in clusters.values {
            guard cluster.count > 1 else { continue }  // singleton keeps .full
            // Chronological, longest-first on a tie, so the packing is stable
            // and independent of the caller's array order beyond that.
            let ordered = cluster.sorted { l, r in
                let el = span(l), er = span(r)
                if el.start != er.start { return el.start < er.start }
                if el.end != er.end { return el.end > er.end }
                return l < r
            }
            var columns: [[Int]] = []          // column -> member cluster-indices
            var columnEnd: [Date] = []         // column -> last assigned end
            var columnOf = [Int: Int]()        // cluster-index -> column
            for member in ordered {
                let event = span(member)
                var placed = false
                for c in columns.indices where columnEnd[c] <= event.start {
                    columns[c].append(member)
                    columnEnd[c] = event.end
                    columnOf[member] = c
                    placed = true
                    break
                }
                if !placed {
                    columns.append([member])
                    columnEnd.append(event.end)
                    columnOf[member] = columns.count - 1
                }
            }
            let total = Double(columns.count)
            for member in ordered {
                guard let c = columnOf[member] else { continue }
                let event = span(member)
                var last = c
                while last + 1 < columns.count {
                    let blocked = columns[last + 1].contains { other in
                        let o = span(other)
                        return event.start < o.end && o.start < event.end
                    }
                    if blocked { break }
                    last += 1
                }
                slots[citizens[member]] = Slot(
                    x: Double(c) / total,
                    width: Double(last - c + 1) / total,
                    isOverlay: false
                )
            }
        }

        // 4. Interrupts inherit their parent's slot.
        for (i, parentIdx) in overlays.enumerated() {
            guard let parentIdx else { continue }
            var slot = slots[parentIdx]
            slot.isOverlay = true
            slots[i] = slot
        }
        return slots
    }

    // MARK: - Mini timeline: the window

    /// The span the mini timeline draws around `now`: six hours, with now 40%
    /// of the way down. One definition for the view (which turns it into
    /// points), for the packing above, and for the provider, which hands the
    /// view every occurrence overlapping it. The civil-day list the view used
    /// to draw from dropped tomorrow's early events off a late-evening window
    /// and yesterday's late ones off a just-after-midnight one (gh#239 sim QA).
    static func miniWindow(now: Date) -> DateInterval {
        let span = Metrics.miniVisibleHours * 3600
        return DateInterval(start: now.addingTimeInterval(-span * Metrics.miniNowFraction), duration: span)
    }

    /// Whether an occurrence is drawn in `window` at all. Half-open, like every
    /// other overlap test on this payload. The view used to admit anything
    /// within 10pt of either edge, so a block that had already scrolled off
    /// the top was still drawn — and pinned its title onto the next one.
    static func miniWindowShows(_ event: SharedEventSnapshot, in window: DateInterval) -> Bool {
        event.endDate > window.start && event.startDate < window.end
    }

    // MARK: - Mini timeline: block height

    /// For each occurrence, the start of the nearest block that begins at or
    /// after its end and shares any of its lane width: the point its floored
    /// height must not reach past. `nil` when nothing follows it.
    ///
    /// A five-minute event is under 2pt tall at this scale, and the view floors
    /// a block at `Metrics.miniMinBlockHeight` so it stays visible — which drew
    /// it into whatever started right after it (gh#245 2).
    static func miniNextStarts(
        for events: [SharedEventSnapshot], slots: [Slot], window: DateInterval? = nil
    ) -> [Date?] {
        precondition(events.count == slots.count, "one slot per occurrence")
        let shown = events.map { event in window.map { miniWindowShows(event, in: $0) } ?? true }
        return events.indices.map { i in
            guard shown[i] else { return nil }
            let a = slots[i]
            return events.indices.filter { j in
                j != i && shown[j]
                    && events[j].startDate >= events[i].endDate
                    && a.x < slots[j].x + slots[j].width && slots[j].x < a.x + a.width
            }
            .map { events[$0].startDate }
            .min()
        }
    }

    /// Height a block is drawn at: 2pt shorter than its span (the gap between
    /// back-to-back blocks), floored so a short event stays visible, but never
    /// past `roomBelow` — the distance from its top to the next block's top
    /// in its column — less a 1pt gap.
    static func miniDrawnHeight(span: CGFloat, roomBelow: CGFloat?) -> CGFloat {
        let floored = max(Metrics.miniMinBlockHeight, span - 2)
        guard let roomBelow else { return floored }
        return min(floored, max(1, roomBelow - 1))
    }

    // MARK: - Mini timeline: block titles

    /// Where a block's title is drawn: the top of its line box, in the lane's
    /// coordinates, and the point size.
    struct MiniTitle: Equatable {
        var lineTop: CGFloat
        var size: CGFloat
    }

    /// Where a block's title may go, or `nil` when it cannot go anywhere whole.
    ///
    /// The title's INK must lie inside the part of the drawn rectangle that is
    /// on screen, and clear of the now line. The gate this replaced read only
    /// the block's time span (`> 10pt`) and pinned the title to the top of the
    /// box whatever was left of the block, so (gh#239 sim QA, every lane):
    /// - a block that had scrolled off the top left its title behind on the
    ///   next block;
    /// - a half-hour block, drawn ~9pt tall, hung a 12pt title past its border;
    /// - the running block's title sat under the now line, which is drawn over
    ///   the blocks (the app's z-order) in the same colour, so it read as
    ///   struck through.
    ///
    /// Tried in order, per region (the visible rectangle, or the parts above
    /// and below the now line when the line crosses it): the usual look, `topPad`
    /// under the region's top; centred at full size; centred and shrunk to the
    /// region, down to `miniTitleMinSize`. Of the two regions the larger size
    /// wins, the upper one on a tie.
    static func miniTitlePlacement(
        rectTop: CGFloat, rectBottom: CGFloat, contentHeight: CGFloat,
        nowY: CGFloat, topPad: CGFloat
    ) -> MiniTitle? {
        let m = Metrics.self
        let top = max(rectTop, 0) + m.miniTitleInset
        let bottom = min(rectBottom, contentHeight) - m.miniTitleInset
        guard bottom > top else { return nil }
        let bandTop = nowY - 0.5 - m.miniNowLineClearance
        let bandBottom = nowY + 0.5 + m.miniNowLineClearance
        let regions: [(top: CGFloat, bottom: CGFloat, pad: CGFloat)]
        if bandBottom <= top || bandTop >= bottom {
            regions = [(top, bottom, topPad)]
        } else {
            // Below the line the title sits right under it: the pad is the
            // look of a block's top edge, and the line is not one.
            regions = [(top, bandTop, topPad), (bandBottom, bottom, 0)]
        }
        var best: MiniTitle?
        for region in regions {
            guard let fit = miniTitleFit(top: region.top, bottom: region.bottom, pad: region.pad) else { continue }
            if best.map({ fit.size > $0.size }) ?? true { best = fit }
        }
        return best
    }

    private static func miniTitleFit(top: CGFloat, bottom: CGFloat, pad: CGFloat) -> MiniTitle? {
        let m = Metrics.self
        let room = bottom - top
        let inkPerPoint = m.miniTitleInkBottom - m.miniTitleInkTop
        let full = m.miniTitleSize
        // The usual look, measured from the rectangle's edge, not from the
        // inset `top`: pad + the line box's own space above the ink.
        let padToInk = max(0, pad + m.miniTitleInkTop * full - m.miniTitleInset)
        let size: CGFloat
        let inkTop: CGFloat
        if room >= padToInk + inkPerPoint * full {
            size = full
            inkTop = top + padToInk
        } else if room >= inkPerPoint * full {
            size = full
            inkTop = top + (room - inkPerPoint * full) / 2
        } else if room >= inkPerPoint * m.miniTitleMinSize {
            size = room / inkPerPoint
            inkTop = top
        } else {
            return nil
        }
        return MiniTitle(lineTop: inkTop - m.miniTitleInkTop * size, size: size)
    }

    /// Side padding for a block's title, or `nil` when the block is too narrow
    /// for any of it: a column of a busy hour is ~27pt, and at the usual 4pt a
    /// side its two-character titles became a bare "…" (gh#239 sim QA).
    static func miniTitleSidePad(blockWidth: CGFloat, standard: CGFloat) -> CGFloat? {
        let m = Metrics.self
        let pad = blockWidth < m.miniNarrowBlockWidth ? min(standard, m.miniNarrowSidePad) : standard
        return blockWidth - 2 * pad >= m.miniTitleMinTextWidth ? pad : nil
    }

    // MARK: - Mini timeline: hour-label suppression

    /// Height of one mini-timeline axis label's line box, at the 7pt semibold
    /// the view draws it in.  Measured once rather than guessed: `ascender -
    /// descender` for `.systemFont(ofSize: 7, weight: .semibold)` is 8.24pt on
    /// iOS 26, and the suppression rule below is only sound if this is an upper
    /// bound on the ink two stacked labels occupy.
    static let axisLabelLineHeight: CGFloat = 9

    /// Whether an hour marker's label may be drawn alongside the now-label.
    ///
    /// The predecessor asked `abs(hourMinutes - nowMinutes) > 20` — a *time*
    /// threshold standing in for a *pixel* problem (gh#239 F7).  Across the
    /// three widget heights, 20 minutes of the 6-hour window is 6.4pt (148),
    /// 7.0pt (158) and 7.7pt (170), all of them under the 8.24pt a label
    /// actually occupies, so a marker 21-25 minutes from now always passed the
    /// guard and always collided.  Comparing the points the labels are drawn at
    /// is the only form of this question that cannot go stale when the window,
    /// the widget height or the font changes.
    static func hourLabelFits(
        markerY: CGFloat, nowY: CGFloat, lineHeight: CGFloat = axisLabelLineHeight
    ) -> Bool {
        abs(markerY - nowY) >= lineHeight
    }

    /// How far above its marker an axis label's line box starts. The label is
    /// drawn with its box `axisLabelRise` above the grid line it names.
    static let axisLabelRise: CGFloat = 5

    /// Whether an hour label's whole line box lies inside the lane. The grid
    /// line keeps its 10pt slack; the label had the same one, so a marker near
    /// either edge drew a label the view's clip then cut through the digits
    /// (gh#239 sim QA: a sliver of "12:00" for about a quarter of every hour).
    static func hourLabelInsideBox(
        markerY: CGFloat, contentHeight: CGFloat, lineHeight: CGFloat = axisLabelLineHeight
    ) -> Bool {
        markerY - axisLabelRise >= 0 && markerY - axisLabelRise + lineHeight <= contentHeight
    }

    // MARK: - View metrics

    /// The point sizes the widget views lay out against.
    ///
    /// These live here, not as literals in `DoneWidget.swift`, because the
    /// functions below only answer correctly for the metrics they are handed:
    /// gh#239 QA showed the view and `WidgetLayoutTests` each re-typing the
    /// same three triples, so raising the view's row height to 30 reintroduced
    /// the F2 clipping with the whole suite green. One declaration, read by
    /// the view and asserted by the tests, is what closes that.
    enum Metrics {
        /// Mini timeline: the window (see `miniWindow(now:)`).
        static let miniVisibleHours: Double = 6
        static let miniNowFraction: Double = 0.4
        /// The shortest a block is drawn, so a five-minute event stays visible.
        static let miniMinBlockHeight: CGFloat = 4

        /// Mini timeline block titles (see `miniTitlePlacement`). Ink is
        /// modelled as a band of the line box, in multiples of the point size:
        /// from 0.15 (above a CJK glyph's top, measured at 0.17) to 1.15 (a
        /// Latin descender). The line box itself is ~1.18x.
        static let miniTitleSize: CGFloat = 8
        static let miniTitleMinSize: CGFloat = 6.5
        static let miniTitleInkTop: CGFloat = 0.15
        static let miniTitleInkBottom: CGFloat = 1.15
        /// Ink to the drawn rectangle's edge: half the 1pt stroke.
        static let miniTitleInset: CGFloat = 0.5
        /// Ink to the 1pt now line's edge.
        static let miniNowLineClearance: CGFloat = 1
        static let miniNarrowBlockWidth: CGFloat = 30
        static let miniNarrowSidePad: CGFloat = 2
        static let miniTitleMinTextWidth: CGFloat = 8

        /// Medium list. The header is pinned to `listHeaderHeight` (its 12pt
        /// rounded line box measures 14.33pt) so the arithmetic below is the
        /// drawn height, not a guess at it: at the 15 it used to assume, the
        /// iPhone Air's 134.67pt box came out 0.33pt short of a fourth row it
        /// had room for (gh#239 sim QA). A row is the colour bar, whose height
        /// its 13pt title and 10pt time line are laid out to match; its inner
        /// stack measures 28.00pt, so the row has no slack to give.
        static let listHeaderHeight: CGFloat = 14.5
        static let listRowHeight: CGFloat = 28
        static let listRowSpacing: CGFloat = 2
        static let listRowCap = 4
        /// Top and bottom margin of the medium list, which draws inside its own
        /// margins rather than the system's. The system's 16-19pt left the
        /// iPhone 17 and 17e 6-8pt short of a fourth row the widget had room
        /// for; at 12 every 160-class device shows four and the SE still three.
        /// Sides keep the system margin.
        static let listVerticalMargin: CGFloat = 12

        /// Focus ring: the line boxes of the labels above and below it, and
        /// the stack spacing between all three.
        static let ringTopLabelHeight: CGFloat = 14
        static let ringBottomLabelHeight: CGFloat = 15
        static let ringSpacing: CGFloat = 8
        static let ringStrokeWidth: CGFloat = 6
        static let ringMaxDiameter: CGFloat = 80

        /// Timeline bar: the five line boxes of its stack, and the spacing
        /// between them. Summed by `barStackHeight`; the view's stack is built
        /// so that it has exactly the four gaps summed there.
        static let barTitleHeight: CGFloat = 18      // 15pt semibold status
        static let barSubtitleHeight: CGFloat = 16   // 13pt medium event title
        static let barClockHeight: CGFloat = 26      // 22pt semibold clock
        static let barTrackHeight: CGFloat = 14      // the progress track
        static let barFooterHeight: CGFloat = 13     // 10pt start/end row
        static let barSpacing: CGFloat = 8
    }

    /// Height the timeline bar's stack needs, given the clock line it is
    /// allowed to draw.
    ///
    /// The bar was the one small view left out of gh#239 F4 — the ring got a
    /// box-solved diameter and the bar kept a fixed stack that cleared the
    /// 116pt content box by under a point, and clipped it outright with the
    /// 12h clock (the descender of "pm" landing 1.0pt past the edge). Solving
    /// the clock line from the box the way the ring solves its diameter gives
    /// the same guarantee, and gives the tests something to pin.
    static func barStackHeight(clockHeight: CGFloat) -> CGFloat {
        let m = Metrics.self
        return m.barTitleHeight + m.barSubtitleHeight + clockHeight
            + m.barTrackHeight + m.barFooterHeight + m.barSpacing * 4
    }

    /// Clock-line height that lets the bar's stack fit `contentHeight`.
    /// Never grows past its design size, never shrinks below legibility.
    static func barClockHeight(contentHeight: CGFloat) -> CGFloat {
        let slack = contentHeight - barStackHeight(clockHeight: Metrics.barClockHeight)
        return max(16, min(Metrics.barClockHeight, Metrics.barClockHeight + slack))
    }

    // MARK: - Medium list: how many rows actually fit

    /// Rows the medium widget may draw without clipping.
    ///
    /// The list used a hardcoded `prefix(4)` whose stack needs ~157pt against
    /// content boxes of 116-138pt, so on EVERY device size a 4-event day lost
    /// both the date header (off the top) and the last row (off the bottom) —
    /// measured at 7.5/9.5pt on the 170 class, 13.5/15.5 on 158 and 18.5/20.5
    /// on 148 (gh#239 F2).  Deriving the count from the height the view was
    /// actually handed is what keeps that from coming back on the next device
    /// size.
    ///
    /// `cap` bounds it from above so a tall future family cannot turn the
    /// glanceable list into a wall of text.
    ///
    /// The stack it models is `header + n*(row + spacing)` — spacing before
    /// every row, none after the last, which is how the view builds it.
    static func listRowCapacity(
        contentHeight: CGFloat,
        headerHeight: CGFloat,
        rowHeight: CGFloat,
        spacing: CGFloat,
        cap: Int = 4
    ) -> Int {
        guard rowHeight + spacing > 0, cap > 0 else { return 1 }
        let available = contentHeight - headerHeight
        let fits = Int(floor(available / (rowHeight + spacing)))
        return max(1, min(cap, fits))
    }

    /// The occurrences the medium list should draw, in the order given.
    ///
    /// The ones that have not ended come first — running before upcoming, which
    /// the start order already gives — and finished ones fill what is left,
    /// most recently ended first, so a late evening shows a full list of what
    /// just happened rather than one lonely row.
    ///
    /// `prefix(capacity)` took the day's FIRST rows, so at 18:30 a five-event
    /// day dropped the 18:00 one that was running (gh#239 QA). The contiguous
    /// slice that replaced it started at the first event not yet ended, so a
    /// long block that began in the morning dragged the slice back over
    /// finished rows and dropped the running standup instead (gh#239 sim QA).
    ///
    /// `events` is expected in the ascending order `WidgetTimelineSchedule.events`
    /// returns.
    static func listWindow(
        _ events: [SharedEventSnapshot], now: Date, capacity: Int
    ) -> [SharedEventSnapshot] {
        guard capacity > 0 else { return [] }
        guard events.count > capacity else { return events }
        var chosen = Array(events.indices.filter { events[$0].endDate > now }.prefix(capacity))
        if chosen.count < capacity {
            let finished = events.indices
                .filter { events[$0].endDate <= now }
                .sorted { events[$0].endDate != events[$1].endDate
                    ? events[$0].endDate > events[$1].endDate : $0 > $1 }
            chosen += finished.prefix(capacity - chosen.count)
        }
        return chosen.sorted().map { events[$0] }
    }

    // MARK: - Progress ring: diameter that fits its box

    /// Diameter for the focus ring given the box the view was handed.
    ///
    /// The ring was a hardcoded 80pt inside a `VStack(spacing: 8)` with an 11pt
    /// label above and a 12pt label below — about 123pt of stack against a
    /// 116pt content box on 148-class devices, which clipped 1.5pt off the top
    /// and 4.0pt off the bottom (gh#239 F4).
    static func ringDiameter(
        content: CGSize,
        topLabelHeight: CGFloat,
        bottomLabelHeight: CGFloat,
        spacing: CGFloat,
        maximum: CGFloat = 80
    ) -> CGFloat {
        let vertical = content.height - topLabelHeight - bottomLabelHeight - spacing * 2
        return max(24, min(maximum, min(content.width, vertical)))
    }

    // MARK: - Stable type colour

    /// Deterministic palette index for an event type with no stored colour.
    ///
    /// `String.hashValue` — what this replaced — is seeded per process, so the
    /// same type drew a different colour in the widget than in the app and a
    /// different one again after every widget relaunch; `abs()` on the `Int.min`
    /// it may return also traps (gh#239 F9).  Only reachable for a blob written
    /// before `colorHex` existed (the field is optional for backwards decode),
    /// which is exactly the case that must not crash.  FNV-1a over UTF-8.
    static func paletteIndex(for type: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in type.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(count))
    }
}
