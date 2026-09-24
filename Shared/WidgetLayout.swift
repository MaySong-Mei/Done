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
    static func miniTimelineSlots(for events: [SharedEventSnapshot]) -> [Slot] {
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

        let citizens = events.indices.filter { overlays[$0] == nil }
        var slots = [Slot](repeating: .full, count: events.count)
        guard !citizens.isEmpty else { return slots }

        // 2. Union-find the time-overlap clusters among lane citizens.
        var parent = Array(0..<citizens.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for a in citizens.indices {
            for b in (a + 1)..<citizens.count {
                let ea = events[citizens[a]], eb = events[citizens[b]]
                if ea.startDate < eb.endDate && eb.startDate < ea.endDate {
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
                let el = events[citizens[l]], er = events[citizens[r]]
                if el.startDate != er.startDate { return el.startDate < er.startDate }
                if el.endDate != er.endDate { return el.endDate > er.endDate }
                return l < r
            }
            var columns: [[Int]] = []          // column -> member cluster-indices
            var columnEnd: [Date] = []         // column -> last assigned end
            var columnOf = [Int: Int]()        // cluster-index -> column
            for member in ordered {
                let event = events[citizens[member]]
                var placed = false
                for c in columns.indices where columnEnd[c] <= event.startDate {
                    columns[c].append(member)
                    columnEnd[c] = event.endDate
                    columnOf[member] = c
                    placed = true
                    break
                }
                if !placed {
                    columns.append([member])
                    columnEnd.append(event.endDate)
                    columnOf[member] = columns.count - 1
                }
            }
            let total = Double(columns.count)
            for member in ordered {
                guard let c = columnOf[member] else { continue }
                let event = events[citizens[member]]
                var last = c
                while last + 1 < columns.count {
                    let blocked = columns[last + 1].contains { other in
                        let o = events[citizens[other]]
                        return event.startDate < o.endDate && o.startDate < event.endDate
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
        /// Medium list. Header is the 12pt rounded face's line box; a row is
        /// the colour bar, whose height its 13pt title and 10pt time line are
        /// laid out to match.
        ///
        /// `rowSpacing` is 2, not the 4 it shipped at and not the 6 it started
        /// at: at 4 the stack needs 15 + 4x32 = 143pt against the 170-class
        /// content box of 138, so the fourth row — which on that device is
        /// where the running event of a busy evening lands — was dropped. At 2
        /// it needs 135 and fits. The row itself has no slack to give: its
        /// inner stack measures 28.00pt against a 28pt frame.
        static let listHeaderHeight: CGFloat = 15
        static let listRowHeight: CGFloat = 28
        static let listRowSpacing: CGFloat = 2
        static let listRowCap = 4

        /// Focus ring: the line boxes of the labels above and below it, and
        /// the stack spacing between all three.
        static let ringTopLabelHeight: CGFloat = 14
        static let ringBottomLabelHeight: CGFloat = 15
        static let ringSpacing: CGFloat = 8
        static let ringStrokeWidth: CGFloat = 6
        static let ringMaxDiameter: CGFloat = 80

        /// Timeline bar: the five line boxes of its stack, and the spacing
        /// between them. Summed by `barStackHeight`.
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
    /// The stack it models is `header + n*(row + spacing)` — spacing after
    /// every row including the last, which is what the `VStack` plus its
    /// trailing `Spacer(minLength: 0)` actually produces.
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

    /// The slice of a day's occurrences the medium list should draw.
    ///
    /// Anchored on `now`, not on the start of the day. `prefix(capacity)` alone
    /// takes the day's FIRST rows, so at 18:30 a five-event day showed the
    /// 09:00/10:00/12:00 rows and dropped the 18:00 one that was actually
    /// running — the single row a glance is for (gh#239 QA). Backfilled from
    /// behind when the remaining events no longer fill the box, so a late
    /// evening shows a full list of what just happened rather than one lonely
    /// row.
    ///
    /// `events` is expected in the ascending order `WidgetTimelineSchedule.events`
    /// returns; the slice preserves it.
    static func listWindow(
        _ events: [SharedEventSnapshot], now: Date, capacity: Int
    ) -> [SharedEventSnapshot] {
        guard capacity > 0 else { return [] }
        guard events.count > capacity else { return events }
        let firstLive = events.firstIndex { $0.endDate > now } ?? events.count
        let start = min(firstLive, events.count - capacity)
        return Array(events[start..<(start + capacity)])
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
