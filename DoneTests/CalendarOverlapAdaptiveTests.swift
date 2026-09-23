import XCTest
@testable import Done

/// Tests for `CalendarLayout.overlapLayout`. The algorithm picks per-cluster:
///   - if column heights (total event-time per column) are even, equal-split
///     greedy column packing with rightward expansion;
///   - if uneven, stack-peek — longest group is the host (full width with
///     `coverRanges`), and the remainder recurses in a 50%-wide right strip.
/// This eliminates the "blank below shorter event" gap that equal-split leaves
/// when one column has less total event-time than another.
final class CalendarOverlapLayoutTests: XCTestCase {

    private var visibleStart: Date { Self.date("2026-05-05T00:00:00Z") }
    private var visibleEnd: Date { Self.date("2026-05-06T00:00:00Z") }
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    // MARK: - Helpers

    private static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    private func occ(_ id: String, _ start: String, _ end: String) -> CalendarLayout.EventOccurrence {
        CalendarLayout.EventOccurrence(
            id: id,
            event: Event(title: id),
            range: Event.TimeRange(start: Self.date(start), end: Self.date(end))
        )
    }

    private func layout(_ occs: [CalendarLayout.EventOccurrence]) -> [String: CalendarLayout.EventOverlapSlot] {
        CalendarLayout.overlapLayout(
            for: occs,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar
        )
    }

    // MARK: - The user's original pain case: stack-peek with 50% strip

    /// 2-hour a + 1-hour B at same start. Columns: a=2h, B=1h → uneven →
    /// stack-peek. a takes full width as the host (depth 0, coverRanges
    /// covers B's time range); B sits at the right 50% strip (depth 1).
    /// a's title can fit in the uncovered left 50% during 7-8, no
    /// title-push-down required, and there's no blank in 8-9 because a
    /// extends through that whole region.
    func testStackPeekOnUnevenColumns() {
        let a = occ("a", "2026-05-05T07:00:00Z", "2026-05-05T09:00:00Z")
        let b = occ("B", "2026-05-05T07:00:00Z", "2026-05-05T08:00:00Z")
        let slots = layout([a, b])

        XCTAssertEqual(slots["a"]!.depth, 0)
        XCTAssertEqual(slots["a"]!.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(slots["a"]!.xOffsetFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(slots["a"]!.coverRanges.count, 1)
        XCTAssertEqual(slots["a"]!.coverRanges.first?.start, b.range.start)
        XCTAssertEqual(slots["a"]!.coverRanges.first?.end, b.range.end)

        XCTAssertEqual(slots["B"]!.depth, 1)
        XCTAssertEqual(slots["B"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.xOffsetFraction, 0.5, accuracy: 0.001)
        XCTAssertTrue(slots["B"]!.coverRanges.isEmpty)
    }

    // MARK: - Peer clusters (column heights even) — equal-split

    /// Two truly identical events split fifty-fifty at depth 0 with no peek.
    func testIdenticalEventsSplitFiftyFifty() {
        let a = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b])

        XCTAssertEqual(slots["A"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["A"]!.depth, 0)
        XCTAssertEqual(slots["B"]!.depth, 0)
        XCTAssertTrue(slots["A"]!.coverRanges.isEmpty)
        XCTAssertTrue(slots["B"]!.coverRanges.isEmpty)
    }

    /// Three identical events split into thirds.
    func testThreeIdenticalEventsThirdsSplit() {
        let a = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let c = occ("C", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b, c])

        for id in ["A", "B", "C"] {
            XCTAssertEqual(slots[id]!.widthFraction, 1.0 / 3.0, accuracy: 0.001)
            XCTAssertEqual(slots[id]!.depth, 0)
        }
    }

    /// 4-event chain A-B-C-D each overlap their neighbor; A & D never share
    /// screen time. Greedy column-packing fits them in 2 columns with even
    /// heights (col 0 = A+C = 2h, col 1 = B+D = 2h). Equal-split applies —
    /// 50% width each, K=2 not K=4.
    func testChainPatternEvenColumnsEqualSplits() {
        let a = occ("A", "2026-05-05T09:00:00Z", "2026-05-05T10:00:00Z")
        let b = occ("B", "2026-05-05T09:30:00Z", "2026-05-05T10:30:00Z")
        let c = occ("C", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let d = occ("D", "2026-05-05T10:30:00Z", "2026-05-05T11:30:00Z")
        let slots = layout([a, b, c, d])

        for id in ["A", "B", "C", "D"] {
            XCTAssertEqual(slots[id]!.widthFraction, 0.5, accuracy: 0.001)
            XCTAssertEqual(slots[id]!.depth, 0)
        }
        XCTAssertEqual(slots["A"]!.xOffsetFraction, slots["C"]!.xOffsetFraction, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.xOffsetFraction, slots["D"]!.xOffsetFraction, accuracy: 0.001)
        XCTAssertNotEqual(slots["A"]!.xOffsetFraction, slots["B"]!.xOffsetFraction)
    }

    /// Back-to-back events (A ends exactly when B starts) form SEPARATE
    /// clusters under strict overlap. Each gets its own full-width slot.
    func testBackToBackEventsDoNotCluster() {
        let a = occ("A", "2026-05-05T09:00:00Z", "2026-05-05T10:00:00Z")
        let b = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b])

        XCTAssertEqual(slots["A"]!.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.widthFraction, 1.0, accuracy: 0.001)
    }

    /// A single-event cluster returns `.default`.
    func testSingletonClusterReturnsDefault() {
        let a = occ("A", "2026-05-05T09:00:00Z", "2026-05-05T10:00:00Z")
        let slots = layout([a])

        XCTAssertEqual(slots["A"]!.xOffsetFraction, 0)
        XCTAssertEqual(slots["A"]!.widthFraction, 1)
        XCTAssertTrue(slots["A"]!.coverRanges.isEmpty)
    }

    // MARK: - Background pattern (Work + disjoint shorts) — recursive peek

    /// Long Work event + three short events that overlap Work but not each
    /// other. Column heights: Work=9h, shorts=3h → uneven → peek. Work
    /// becomes the depth-0 host (full width). The remaining shorts re-cluster
    /// into three singleton sub-clusters; each fills the 50% right strip in
    /// its own time region (depth 1). No blank because Work fills the gaps.
    func testBackgroundPatternRecursesIntoSingletons() {
        let work = occ("Work", "2026-05-05T09:00:00Z", "2026-05-05T18:00:00Z")
        let a = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occ("B", "2026-05-05T13:00:00Z", "2026-05-05T14:00:00Z")
        let c = occ("C", "2026-05-05T15:00:00Z", "2026-05-05T16:00:00Z")
        let slots = layout([work, a, b, c])

        XCTAssertEqual(slots["Work"]!.depth, 0)
        XCTAssertEqual(slots["Work"]!.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(slots["Work"]!.coverRanges.count, 3)

        for id in ["A", "B", "C"] {
            XCTAssertEqual(slots[id]!.depth, 1)
            XCTAssertEqual(slots[id]!.xOffsetFraction, 0.5, accuracy: 0.001)
            XCTAssertEqual(slots[id]!.widthFraction, 0.5, accuracy: 0.001)
        }
    }

    /// Long Work event + two short meetings that overlap each other under
    /// Work. After Work hosts, the rest {M1, M2} is one connected sub-cluster
    /// with even column heights → recursive equal-split inside the 50% strip.
    /// Each meeting takes 25% of canvas at depth 1.
    func testBackgroundPlusOverlappingPairEqualSplitsInsideStrip() {
        let work = occ("Work", "2026-05-05T09:00:00Z", "2026-05-05T18:00:00Z")
        let m1 = occ("M1", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let m2 = occ("M2", "2026-05-05T10:30:00Z", "2026-05-05T11:30:00Z")
        let slots = layout([work, m1, m2])

        XCTAssertEqual(slots["Work"]!.depth, 0)
        XCTAssertEqual(slots["Work"]!.widthFraction, 1.0, accuracy: 0.001)

        XCTAssertEqual(slots["M1"]!.depth, 1)
        XCTAssertEqual(slots["M2"]!.depth, 1)
        XCTAssertEqual(slots["M1"]!.widthFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(slots["M2"]!.widthFraction, 0.25, accuracy: 0.001)
        XCTAssertNotEqual(slots["M1"]!.xOffsetFraction, slots["M2"]!.xOffsetFraction)
    }

    /// Three-level nesting: each level's column heights end up uneven,
    /// triggering peek again. Big > Medium > Small.
    func testThreeLevelNestingProducesDepthTwo() {
        let big = occ("Big", "2026-05-05T09:00:00Z", "2026-05-05T18:00:00Z")
        let med = occ("Med", "2026-05-05T10:00:00Z", "2026-05-05T14:00:00Z")
        let sm = occ("Sm", "2026-05-05T11:00:00Z", "2026-05-05T12:00:00Z")
        let slots = layout([big, med, sm])

        XCTAssertEqual(slots["Big"]!.depth, 0)
        XCTAssertEqual(slots["Med"]!.depth, 1)
        XCTAssertEqual(slots["Sm"]!.depth, 2)
        // x accumulates: depth 1 at 0.5, depth 2 at 0.5 + 0.5*0.5 = 0.75
        XCTAssertEqual(slots["Med"]!.xOffsetFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["Sm"]!.xOffsetFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(slots["Big"]!.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(slots["Med"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["Sm"]!.widthFraction, 0.25, accuracy: 0.001)
    }

    // MARK: - Interrupt-family folding

    /// Parent + embedded child fold into one packing group. With a non-family
    /// sibling that has a shorter duration, columns become uneven (family
    /// span = 9h vs sibling = 1h) → peek. Parent+child host at full width,
    /// sibling at right 50% strip.
    func testInterruptFamilyFoldsIntoSingleHostGroup() {
        let parentID = UUID()
        let childID = UUID()
        let siblingID = UUID()
        let occurrenceDate = Self.date("2026-05-05T00:00:00Z")

        let parent = CalendarLayout.EventOccurrence(
            id: "parent",
            event: Event(id: parentID, title: "Parent"),
            range: Event.TimeRange(
                start: Self.date("2026-05-05T09:00:00Z"),
                end: Self.date("2026-05-05T18:00:00Z")
            )
        )

        let childEvent = Event(
            id: childID,
            title: "InterruptChild",
            interruptRelation: EventInterruptRelation(
                parentEventID: parentID,
                occurrenceDate: occurrenceDate,
                state: .embedded
            )
        )
        let child = CalendarLayout.EventOccurrence(
            id: "child",
            event: childEvent,
            range: Event.TimeRange(
                start: Self.date("2026-05-05T10:00:00Z"),
                end: Self.date("2026-05-05T10:05:00Z")
            )
        )

        let sibling = CalendarLayout.EventOccurrence(
            id: "sibling",
            event: Event(id: siblingID, title: "Sibling"),
            range: Event.TimeRange(
                start: Self.date("2026-05-05T12:00:00Z"),
                end: Self.date("2026-05-05T13:00:00Z")
            )
        )

        let slots = layout([parent, child, sibling])

        // Parent and child share the same slot (folded into the host group).
        XCTAssertEqual(slots["parent"]!.xOffsetFraction, slots["child"]!.xOffsetFraction, accuracy: 0.001)
        XCTAssertEqual(slots["parent"]!.widthFraction, slots["child"]!.widthFraction, accuracy: 0.001)
        XCTAssertEqual(slots["parent"]!.depth, 0)
        // Sibling is the non-host, takes the right 50% strip at depth 1.
        XCTAssertEqual(slots["sibling"]!.depth, 1)
        XCTAssertEqual(slots["sibling"]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    // MARK: - Peer tolerance — similar-duration events stay equal-split

    /// Two events with similar but not identical durations (60min + 50min,
    /// ratio 1.2) — within the peer tolerance (1.5). Equal-split applies
    /// even though columns aren't exactly equal in height.
    func testSimilarDurationsStayPeerInsideTolerance() {
        let a = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T10:50:00Z")
        let slots = layout([a, b])

        XCTAssertEqual(slots["A"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["A"]!.depth, 0)
        XCTAssertEqual(slots["B"]!.depth, 0)
    }

    /// Two events at ratio 1.6 — just past the peer tolerance. Falls
    /// through to stack-peek so the shorter event's column doesn't leave
    /// a 38%-deep tail-blank.
    func testRatioJustAbovePeerToleranceTriggersPeek() {
        let a = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:36:00Z")  // 96min
        let b = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")  // 60min
        let slots = layout([a, b])

        XCTAssertEqual(slots["A"]!.depth, 0)
        XCTAssertEqual(slots["A"]!.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.depth, 1)
        XCTAssertEqual(slots["B"]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    // MARK: - Sanity

    /// Zero-duration / point-in-time events don't crash the algorithm.
    func testZeroDurationEventDoesNotCrash() {
        let a = occ("A", "2026-05-05T09:00:00Z", "2026-05-05T11:00:00Z")
        let zero = occ("Z", "2026-05-05T10:00:00Z", "2026-05-05T10:00:00Z")
        let slots = layout([a, zero])
        XCTAssertNotNil(slots["A"])
        _ = slots["Z"]
    }

    // MARK: - OverlapMode.equalSplit drag freeze (PR #59)
    //
    // The CALayer timeline passes `mode: .equalSplit` to `overlapLayout` while
    // a drag is active so neither the per-frame mode flip (#1) nor the
    // host-identity flip on resize (#2) can fire. These tests pin the
    // contract: any cluster that would otherwise trigger stack-peek must
    // instead resolve to equal-split column packing, and the recursive peek
    // branch (host + 50% strip) must not run.

    /// 2h+1h at same start would normally trip the ratio>=1.5 gate and fall
    /// into stack-peek (the existing `testStackPeekOnUnevenColumns` case).
    /// With `mode: .equalSplit` both events must sit at 50% width with empty
    /// `coverRanges` — the peek decision is suppressed.
    func testEqualSplitModeForcesPeerEvenOnExtremeRatio() {
        let a = occ("a", "2026-05-05T07:00:00Z", "2026-05-05T09:00:00Z")
        let b = occ("B", "2026-05-05T07:00:00Z", "2026-05-05T08:00:00Z")
        let slots = CalendarLayout.overlapLayout(
            for: [a, b],
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .equalSplit
        )

        // Both at 50% width, depth 0, no host / no peek.
        XCTAssertEqual(slots["a"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["a"]!.depth, 0)
        XCTAssertEqual(slots["B"]!.depth, 0)
        XCTAssertTrue(slots["a"]!.coverRanges.isEmpty,
                      "equalSplit must suppress coverRanges (no host)")
        XCTAssertTrue(slots["B"]!.coverRanges.isEmpty)
        // One occupies left, the other right — never the same column.
        XCTAssertNotEqual(slots["a"]!.xOffsetFraction, slots["B"]!.xOffsetFraction)
    }

    /// Work + 3 disjoint shorts is the classic peek-then-recurse case
    /// (`testBackgroundPatternRecursesIntoSingletons`). With `.equalSplit`
    /// the whole cluster collapses to greedy column packing — Work in col 0,
    /// shorts in col 1 (they don't overlap each other so they share col 1),
    /// every member at depth 0 with empty `coverRanges`.
    func testEqualSplitModeRecursesEqualSplit() {
        let work = occ("Work", "2026-05-05T09:00:00Z", "2026-05-05T18:00:00Z")
        let a = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occ("B", "2026-05-05T13:00:00Z", "2026-05-05T14:00:00Z")
        let c = occ("C", "2026-05-05T15:00:00Z", "2026-05-05T16:00:00Z")
        let slots = CalendarLayout.overlapLayout(
            for: [work, a, b, c],
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .equalSplit
        )

        // 2 columns total (Work in col 0, A/B/C share col 1) at 50% each.
        for id in ["Work", "A", "B", "C"] {
            XCTAssertEqual(slots[id]!.depth, 0,
                           "\(id) must stay at depth 0 — no recursion in equalSplit")
            XCTAssertEqual(slots[id]!.widthFraction, 0.5, accuracy: 0.001,
                           "\(id) must be 50%-wide equal-split, not host or peek strip")
            XCTAssertTrue(slots[id]!.coverRanges.isEmpty,
                          "\(id) must have empty coverRanges (no host in equalSplit)")
        }
        // Work owns col 0; A/B/C share col 1 (they're disjoint).
        XCTAssertEqual(slots["Work"]!.xOffsetFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(slots["A"]!.xOffsetFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.xOffsetFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["C"]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    /// Bug-#1 regression shape: during a drag the live `overlapSlots` (built
    /// from drag-adjusted ranges) and `stableOverlapSlots` (built from the
    /// un-adjusted source ranges) must agree on the dragged occurrence's slot
    /// geometry. With `.auto`, a tiny resize that shifts the column ratio
    /// past 1.5 would flip one pass into stack-peek (dragged becomes full-
    /// width host, widthFraction == 1.0) while the other stays equal-split
    /// (peer, widthFraction == 0.5) — the 50% canvas snap. With
    /// `.equalSplit` both passes must produce peer-shaped slots: depth 0,
    /// empty `coverRanges`, widthFraction <= 0.5, so no mismatch is possible.
    func testDualPassWithEqualSplitModeAgreesOnDraggedSlotGeometry() {
        // Source occurrences — 2h "drag" + 1h "peer", overlapping at the same
        // start. Under `.auto` this is the classic stack-peek case (host +
        // 50% strip), exactly the shape the bug needs to fire.
        let dragOcc = occ("drag", "2026-05-05T07:00:00Z", "2026-05-05T09:00:00Z")
        let peerOcc = occ("peer", "2026-05-05T07:00:00Z", "2026-05-05T08:00:00Z")
        let unadjusted = [dragOcc, peerOcc]

        // Live-adjusted: simulate a resize that shortens "drag" to 30min so
        // the column-height ratio flips. Under `.auto` the host identity
        // would now move to "peer" — the per-frame host-flip bug. Under
        // `.equalSplit` neither pass picks a host.
        let dragLive = occ("drag", "2026-05-05T07:00:00Z", "2026-05-05T07:30:00Z")
        let adjusted = [dragLive, peerOcc]

        let stableSlots = CalendarLayout.overlapLayout(
            for: unadjusted,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .equalSplit
        )
        let liveSlots = CalendarLayout.overlapLayout(
            for: adjusted,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .equalSplit
        )

        // Sanity: under .auto these inputs would diverge. Confirm at least
        // the stable pass picks "drag" as host (depth 0, width 1.0,
        // coverRanges non-empty) — proves the cluster shape can fire the
        // bug. If this invariant ever shifts upstream the test will go
        // stale loudly, instead of silently passing on a degenerate input.
        let autoStable = CalendarLayout.overlapLayout(
            for: unadjusted,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .auto
        )
        XCTAssertEqual(autoStable["drag"]!.widthFraction, 1.0, accuracy: 0.001,
                       "input cluster must reproduce the stack-peek shape under .auto, " +
                       "else the .equalSplit guarantee being tested is meaningless")

        // The actual contract: both passes under `.equalSplit` must report
        // the dragged slot at depth 0, empty `coverRanges`, and a width
        // that's a peer slice (<= 0.5) — never the host's full canvas. If
        // these agree, the dual-pass disagreement bug can't fire.
        for (label, slots) in [("stable", stableSlots), ("live", liveSlots)] {
            let dragSlot = slots["drag"]!
            XCTAssertEqual(dragSlot.depth, 0,
                           "[\(label)] dragged slot must be depth 0 under .equalSplit")
            XCTAssertTrue(dragSlot.coverRanges.isEmpty,
                          "[\(label)] dragged slot must have empty coverRanges (no host)")
            XCTAssertLessThanOrEqual(dragSlot.widthFraction, 0.5 + 0.001,
                                     "[\(label)] dragged slot must be a peer column " +
                                     "(<= 0.5), not the host's full canvas (1.0)")
            XCTAssertNotEqual(dragSlot.widthFraction, 1.0, accuracy: 0.001,
                              "[\(label)] dragged slot must not be host-width")
        }

        // And finally — the bug shape itself: the two passes must agree
        // close enough that the dragged block can't read host geometry
        // from one and peer geometry from the other.
        XCTAssertEqual(stableSlots["drag"]!.widthFraction,
                       liveSlots["drag"]!.widthFraction,
                       accuracy: 0.001,
                       "stable and live passes must report the same dragged width " +
                       "under .equalSplit (else the 50% canvas snap bug #1 fires)")
    }

    /// User-reported mini-day repro (PR #67 follow-up): focused 8h45m event
    /// + parallel 8h30m event + parallel 5h30m todo. Column-height ratio
    /// (8h45m : 5h30m ≈ 1.59) would trip the stack-peek gate under `.auto`,
    /// returning a host slot with `widthFraction = 1.0` and the siblings
    /// encoded in `coverRanges`. Preview-style renderers (mini-day, share
    /// card, focus event flow) only read `widthFraction`/`xOffsetFraction`
    /// so the siblings would render fully covered by the host. With
    /// `.equalSplit` every occurrence must receive a peer slot.
    func testMiniDayLikeUnevenClusterEqualSplits() {
        let focused = occ("focused", "2026-05-05T08:00:00Z", "2026-05-05T16:45:00Z") // 8h45m
        let parallel = occ("parallel", "2026-05-05T08:30:00Z", "2026-05-05T17:00:00Z") // 8h30m
        let todo = occ("todo", "2026-05-05T09:00:00Z", "2026-05-05T14:30:00Z") // 5h30m

        let slots = CalendarLayout.overlapLayout(
            for: [focused, parallel, todo],
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .equalSplit
        )

        // 1. All 3 occurrences receive a slot.
        for id in ["focused", "parallel", "todo"] {
            XCTAssertNotNil(slots[id], "\(id) must receive a slot under .equalSplit")
        }

        // 2. widthFraction sums to <= 1.0 — every block fits in the canvas.
        let widthSum = ["focused", "parallel", "todo"]
            .map { slots[$0]!.widthFraction }
            .reduce(0, +)
        XCTAssertLessThanOrEqual(widthSum, 1.0 + 0.001,
                                 "widthFractions must sum to <= 1.0 (each ~1/3), got \(widthSum)")

        // 3. xOffsetFraction values are non-overlapping (no two slots share x range).
        let ordered = ["focused", "parallel", "todo"]
            .map { (id: $0, slot: slots[$0]!) }
            .sorted { $0.slot.xOffsetFraction < $1.slot.xOffsetFraction }
        for i in 0..<(ordered.count - 1) {
            let lhs = ordered[i].slot
            let rhs = ordered[i + 1].slot
            XCTAssertLessThanOrEqual(lhs.xOffsetFraction + lhs.widthFraction,
                                     rhs.xOffsetFraction + 0.001,
                                     "\(ordered[i].id) [\(lhs.xOffsetFraction), " +
                                     "\(lhs.xOffsetFraction + lhs.widthFraction)] overlaps " +
                                     "\(ordered[i + 1].id) at \(rhs.xOffsetFraction)")
        }

        // 4. All slots have empty coverRanges — stack-peek bypassed.
        for id in ["focused", "parallel", "todo"] {
            XCTAssertTrue(slots[id]!.coverRanges.isEmpty,
                          "\(id) must have empty coverRanges under .equalSplit")
        }
    }

    /// `mode: .auto` is the documented default and must produce identical
    /// output to a call that omits the parameter — protects callers that
    /// haven't been updated yet from a silent behavior shift.
    func testAutoModeMatchesDefault() {
        let work = occ("Work", "2026-05-05T09:00:00Z", "2026-05-05T18:00:00Z")
        let a = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occ("B", "2026-05-05T13:00:00Z", "2026-05-05T14:00:00Z")
        let inputs = [work, a, b]

        let auto = CalendarLayout.overlapLayout(
            for: inputs,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .auto
        )
        let defaulted = CalendarLayout.overlapLayout(
            for: inputs,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar
        )

        XCTAssertEqual(auto, defaulted,
                       ".auto must be a no-op replacement for the default-param call")
    }

    // MARK: - True-peer lane ordering (gh#173) — earlier createdAt sits left
    //
    // For occurrences with identical start AND end, left/right is decided by
    // `event.createdAt` ascending (millisecond granularity), with id order
    // only as the final deterministic fallback. Fixtures below deliberately
    // pick ids whose lexicographic order CONTRADICTS creation order, so a
    // regression back to id-based lanes fails loudly.

    private func occ(
        _ id: String,
        _ start: String,
        _ end: String,
        createdAt: Date,
        eventID: UUID = UUID()
    ) -> CalendarLayout.EventOccurrence {
        CalendarLayout.EventOccurrence(
            id: id,
            event: Event(id: eventID, title: id, createdAt: createdAt),
            range: Event.TimeRange(start: Self.date(start), end: Self.date(end))
        )
    }

    private func occ(
        _ id: String,
        _ start: String,
        _ end: String,
        event: Event
    ) -> CalendarLayout.EventOccurrence {
        CalendarLayout.EventOccurrence(
            id: id,
            event: event,
            range: Event.TimeRange(start: Self.date(start), end: Self.date(end))
        )
    }

    private var peerCreationBase: Date { Self.date("2026-05-01T08:00:00Z") }

    /// 2-way identical-time peers: the earlier-created event takes the left
    /// column even though its occurrence id sorts AFTER the other's — and the
    /// result is identical when the input array order is reversed.
    func testEqualTimePeersOrderByCreatedAtAscending() {
        let earlier = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                          createdAt: peerCreationBase)
        let later = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                        createdAt: peerCreationBase.addingTimeInterval(60))

        let slots = layout([earlier, later])
        XCTAssertEqual(slots["B"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                       "earlier-created peer must take the left column")
        XCTAssertEqual(slots["A"]!.xOffsetFraction, 0.5, accuracy: 0.001,
                       "later-created peer must take the right column")

        let reversed = layout([later, earlier])
        XCTAssertEqual(reversed["B"]!.xOffsetFraction, slots["B"]!.xOffsetFraction,
                       accuracy: 0.001,
                       "input array order must not change lane assignment")
        XCTAssertEqual(reversed["A"]!.xOffsetFraction, slots["A"]!.xOffsetFraction,
                       accuracy: 0.001)
    }

    /// 3-way identical-time peers: createdAt ascending reads left → right.
    func testThreeWayEqualTimePeersOrderByCreationAscending() {
        let first = occ("C", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                        createdAt: peerCreationBase)
        let second = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                         createdAt: peerCreationBase.addingTimeInterval(60))
        let third = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                        createdAt: peerCreationBase.addingTimeInterval(120))

        let slots = layout([third, first, second])
        XCTAssertEqual(slots["C"]!.xOffsetFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.xOffsetFraction, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(slots["A"]!.xOffsetFraction, 2.0 / 3.0, accuracy: 0.001)
    }

    /// Exactly equal createdAt falls back to id order, deterministically in
    /// both input orders.
    func testEqualCreatedAtFallsBackToIDAscending() {
        let a = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                    createdAt: peerCreationBase)
        let b = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                    createdAt: peerCreationBase)

        let slots = layout([b, a])
        XCTAssertEqual(slots["A"]!.xOffsetFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.xOffsetFraction, 0.5, accuracy: 0.001)

        let reversed = layout([a, b])
        XCTAssertEqual(reversed["A"]!.xOffsetFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(reversed["B"]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    /// createdAt comparison is millisecond-granular: a 0.4ms gap that rounds
    /// to the same millisecond compares equal (id decides), a 2ms gap is a
    /// real createdAt ordering.
    func testCreatedAtComparisonIsMillisecondGranular() {
        let subMillisecondLater = occ(
            "A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
            createdAt: peerCreationBase.addingTimeInterval(0.0004)
        )
        let subMillisecondEarlier = occ(
            "B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
            createdAt: peerCreationBase
        )
        let subMs = layout([subMillisecondLater, subMillisecondEarlier])
        XCTAssertEqual(subMs["A"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                       "0.4ms apart rounds to the same millisecond — id must decide")
        XCTAssertEqual(subMs["B"]!.xOffsetFraction, 0.5, accuracy: 0.001)

        let twoMsLater = occ(
            "C", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
            createdAt: peerCreationBase.addingTimeInterval(0.002)
        )
        let twoMsEarlier = occ(
            "D", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
            createdAt: peerCreationBase
        )
        let twoMs = layout([twoMsLater, twoMsEarlier])
        XCTAssertEqual(twoMs["D"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                       "2ms apart is a real createdAt difference — creation order must decide")
        XCTAssertEqual(twoMs["C"]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    /// Editing non-temporal presentation fields between two layout passes
    /// must not swap peer lanes.
    func testNonTemporalEditsKeepPeerLanes() {
        let leftID = UUID()
        let rightID = UUID()
        var leftEvent = Event(id: leftID, title: "One", createdAt: peerCreationBase)
        var rightEvent = Event(id: rightID, title: "Two",
                               createdAt: peerCreationBase.addingTimeInterval(60))

        let before = layout([
            occ("left", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z", event: leftEvent),
            occ("right", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z", event: rightEvent)
        ])

        leftEvent.title = "One (renamed)"
        leftEvent.colorDepth = 0.9
        leftEvent.type = "Work"
        rightEvent.title = "Two (renamed)"
        rightEvent.note = "edited"

        let after = layout([
            occ("left", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z", event: leftEvent),
            occ("right", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z", event: rightEvent)
        ])

        XCTAssertEqual(before["left"]!.xOffsetFraction, after["left"]!.xOffsetFraction,
                       accuracy: 0.001,
                       "title/effort/type edits must not move a peer's lane")
        XCTAssertEqual(before["right"]!.xOffsetFraction, after["right"]!.xOffsetFraction,
                       accuracy: 0.001)
        XCTAssertEqual(before["left"]!.xOffsetFraction, 0.0, accuracy: 0.001)
    }

    /// The interaction-time `.equalSplit` mode must agree with static `.auto`
    /// on true-peer left/right identity.
    func testEqualSplitModeAgreesWithAutoOnTruePeerLanes() {
        let earlier = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                          createdAt: peerCreationBase)
        let later = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                        createdAt: peerCreationBase.addingTimeInterval(60))

        let auto = CalendarLayout.overlapLayout(
            for: [earlier, later],
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .auto
        )
        let equalSplit = CalendarLayout.overlapLayout(
            for: [earlier, later],
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            mode: .equalSplit
        )

        XCTAssertEqual(auto["B"]!.xOffsetFraction, equalSplit["B"]!.xOffsetFraction,
                       accuracy: 0.001,
                       ".auto and .equalSplit must agree on true-peer lanes")
        XCTAssertEqual(auto["A"]!.xOffsetFraction, equalSplit["A"]!.xOffsetFraction,
                       accuracy: 0.001)
        XCTAssertEqual(equalSplit["B"]!.xOffsetFraction, 0.0, accuracy: 0.001)
    }

    /// Two recurring series projected onto the same day/time order by the
    /// SERIES' createdAt — the synthesized "<uuid>-recur-<ts>" occurrence ids
    /// are chosen here so id order contradicts creation order.
    func testRecurringSeriesPeersOrderBySeriesCreatedAt() {
        let earlierSeries = Event(
            id: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")!,
            title: "EarlierSeries",
            timeRanges: [Event.TimeRange(
                start: Self.date("2026-05-01T10:00:00Z"),
                end: Self.date("2026-05-01T11:00:00Z")
            )],
            repeatUnit: .day,
            createdAt: peerCreationBase
        )
        let laterSeries = Event(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!,
            title: "LaterSeries",
            timeRanges: [Event.TimeRange(
                start: Self.date("2026-05-01T10:00:00Z"),
                end: Self.date("2026-05-01T11:00:00Z")
            )],
            repeatUnit: .day,
            createdAt: peerCreationBase.addingTimeInterval(60)
        )

        let occurrences = CalendarLayout.occurrencesForDate(
            [laterSeries, earlierSeries],
            date: visibleStart,
            calendar: calendar
        )
        XCTAssertEqual(occurrences.count, 2)
        let slots = layout(occurrences)

        let earlierOcc = occurrences.first { $0.event.id == earlierSeries.id }!
        let laterOcc = occurrences.first { $0.event.id == laterSeries.id }!
        XCTAssertGreaterThan(earlierOcc.id, laterOcc.id,
                             "fixture must keep occurrence-id order opposed to creation order")
        XCTAssertEqual(slots[earlierOcc.id]!.xOffsetFraction, 0.0, accuracy: 0.001,
                       "earlier-created series must sit left regardless of occurrence id")
        XCTAssertEqual(slots[laterOcc.id]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    /// A detached single-instance edit keeps the lane the series projection
    /// would get against the same peer. The instance is minted through the
    /// production `Event.applyEdit(scope: .single)` path — not a hand copy —
    /// so this test reddens if that branch ever starts stamping a fresh
    /// createdAt.
    func testDetachedInstanceInheritsSeriesLane() {
        let series = Event(
            id: UUID(),
            title: "Series",
            timeRanges: [Event.TimeRange(
                start: Self.date("2026-05-01T10:00:00Z"),
                end: Self.date("2026-05-01T11:00:00Z")
            )],
            repeatUnit: .day,
            createdAt: peerCreationBase
        )
        let peerEvent = Event(
            id: UUID(),
            title: "Peer",
            createdAt: peerCreationBase.addingTimeInterval(60)
        )

        let baseline = layout([
            occ("z-series", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z", event: series),
            occ("a-peer", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z", event: peerEvent)
        ])
        XCTAssertEqual(baseline["z-series"]!.xOffsetFraction, 0.0, accuracy: 0.001)

        let result = Event.applyEdit(
            series: series,
            occurrenceDate: Self.date("2026-05-05T00:00:00Z"),
            scope: .single,
            edit: { $0.title = "Series (edited)" },
            calendar: calendar
        )
        guard let instance = result.exceptionInstance else {
            XCTFail(".single edit on a recurring series must mint a detached instance")
            return
        }
        XCTAssertNotEqual(instance.id, series.id)

        let detached = layout([
            occ("z-detached", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z", event: instance),
            occ("a-peer", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z", event: peerEvent)
        ])
        XCTAssertEqual(detached["z-detached"]!.xOffsetFraction,
                       baseline["z-series"]!.xOffsetFraction,
                       accuracy: 0.001,
                       "detached instance must keep the series' lane against the same peer")
        XCTAssertEqual(detached["a-peer"]!.xOffsetFraction,
                       baseline["a-peer"]!.xOffsetFraction,
                       accuracy: 0.001)
    }

    /// The live move-drag preview occurrence reuses the REAL event under a
    /// "<occurrence-id>#preview" id, so its lane against an equal-time peer
    /// must equal the source occurrence's lane.
    func testMovePreviewKeepsSourceLaneAgainstPeer() {
        let sourceEvent = Event(id: UUID(), title: "Source", createdAt: peerCreationBase)
        let peerEvent = Event(id: UUID(), title: "Peer",
                              createdAt: peerCreationBase.addingTimeInterval(60))

        let source = occ("event-b", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                         event: sourceEvent)
        let peer = occ("event-a", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                       event: peerEvent)
        let preview = occ("event-b#preview", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                          event: sourceEvent)

        let baseline = layout([source, peer])
        let live = layout([preview, peer])

        XCTAssertEqual(baseline["event-b"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                       "earlier-created source must sit left despite larger occurrence id")
        XCTAssertEqual(live["event-b#preview"]!.xOffsetFraction,
                       baseline["event-b"]!.xOffsetFraction,
                       accuracy: 0.001,
                       "preview occurrence must keep the source event's lane")
        XCTAssertEqual(live["event-a"]!.xOffsetFraction,
                       baseline["event-a"]!.xOffsetFraction,
                       accuracy: 0.001)
    }

    /// The drag-create draft is minted fresh each render (createdAt = now),
    /// so against any equal-time existing peer it deterministically lands on
    /// the RIGHT.
    func testFreshCreationDraftLandsRightOfExistingPeer() {
        let existing = occ("existing", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                           createdAt: peerCreationBase)
        let draft = occ("__creation_draft__",
                        "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                        event: Event(title: ""))

        let slots = layout([draft, existing])
        XCTAssertEqual(slots["existing"]!.xOffsetFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(slots["__creation_draft__"]!.xOffsetFraction, 0.5, accuracy: 0.001,
                       "just-minted draft must land right of any older equal-time peer")
    }

    /// Same start, different durations inside the peer tolerance: the longer
    /// event keeps the left column even when it was created later — createdAt
    /// must not preempt temporal priority.
    func testLongerPeerKeepsLeftColumnRegardlessOfCreation() {
        let longerButNewer = occ("A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                                 createdAt: peerCreationBase.addingTimeInterval(60))
        let shorterButOlder = occ("B", "2026-05-05T10:00:00Z", "2026-05-05T10:50:00Z",
                                  createdAt: peerCreationBase)

        let slots = layout([shorterButOlder, longerButNewer])
        XCTAssertEqual(slots["A"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                       "longer event keeps the left column — end-desc still preempts createdAt")
        XCTAssertEqual(slots["B"]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    /// Interrupt family vs an equal-time ordinary peer: the family stays
    /// folded into one slot, and its lane is decided by the PARENT's
    /// createdAt — an extreme child stamp must not leak into the lane.
    func testInterruptFamilyLaneFollowsParentCreation() {
        let parentID = UUID()
        let childEvent = Event(
            id: UUID(),
            title: "Child",
            createdAt: peerCreationBase.addingTimeInterval(-3600),
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: parentID,
                occurrenceDate: Self.date("2026-05-05T00:00:00Z"),
                state: .embedded
            )
        )
        let child = occ("child", "2026-05-05T10:00:00Z", "2026-05-05T10:15:00Z",
                        event: childEvent)
        let peer = occ("peer", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                       createdAt: peerCreationBase)

        // Parent created AFTER the peer → family right, even though the
        // child was created long before the peer.
        let laterParent = occ("parent", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                              createdAt: peerCreationBase.addingTimeInterval(60),
                              eventID: parentID)
        let familyRight = layout([laterParent, child, peer])
        XCTAssertEqual(familyRight["peer"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                       "family lane must follow the parent's createdAt, not the child's")
        XCTAssertEqual(familyRight["parent"]!.xOffsetFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(familyRight["parent"]!.xOffsetFraction,
                       familyRight["child"]!.xOffsetFraction, accuracy: 0.001,
                       "parent and embedded child must share one slot")
        XCTAssertEqual(familyRight["parent"]!.widthFraction,
                       familyRight["child"]!.widthFraction, accuracy: 0.001)

        // Parent created BEFORE the peer → family left.
        let earlierParent = occ("parent", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                                createdAt: peerCreationBase.addingTimeInterval(-60),
                                eventID: parentID)
        let familyLeft = layout([peer, child, earlierParent])
        XCTAssertEqual(familyLeft["parent"]!.xOffsetFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(familyLeft["child"]!.xOffsetFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(familyLeft["peer"]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    /// One anchor can carry TWO non-embedded family events with different
    /// stamps — a `.following` split mints a fresh createdAt for the new
    /// series (Event.swift `.following` branch) while the store re-parents
    /// old detached instances to it with their original stamp intact
    /// (EventStore.swift `.following` sweep) — so the family representative
    /// must be the EARLIEST parent stamp, independent of input order. Block
    /// one's competitor sits BETWEEN the two parent stamps: last-parent-
    /// wins would flip the family across it depending on member order.
    /// Block two arms the other failure mode: an ancient child stamp fed
    /// first, with the competitor below both parents — a representative
    /// that lets an early child pollute the parent min drags the family
    /// left of the competitor in the child-first order only.
    func testSplitParentsUnderOneAnchorKeepOrderFreeFamilyLane() {
        let anchorID = UUID()
        var detachedEvent = Event(id: UUID(), title: "Detached",
                                  createdAt: peerCreationBase)
        detachedEvent.recurrenceParentId = anchorID
        detachedEvent.recurrenceInstanceDate = Self.date("2026-05-05T00:00:00Z")
        let splitEvent = Event(id: anchorID, title: "Split",
                               createdAt: peerCreationBase.addingTimeInterval(120))
        let childEvent = Event(
            id: UUID(),
            title: "Child",
            createdAt: peerCreationBase.addingTimeInterval(180),
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: anchorID,
                occurrenceDate: Self.date("2026-05-05T00:00:00Z"),
                state: .embedded
            )
        )
        let competitorEvent = Event(id: UUID(), title: "Competitor",
                                    createdAt: peerCreationBase.addingTimeInterval(60))

        let detached = occ("o1", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                           event: detachedEvent)
        let split = occ("p", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                        event: splitEvent)
        let competitor = occ("x", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                             event: competitorEvent)
        let child = occ("c1", "2026-05-05T10:00:00Z", "2026-05-05T10:15:00Z",
                        event: childEvent)

        let orderA = layout([detached, split, competitor, child])
        let orderB = layout([split, competitor, child, detached])

        for (label, slots) in [("A", orderA), ("B", orderB)] {
            XCTAssertEqual(slots["p"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                           "[\(label)] earliest parent stamp is the family identity — " +
                           "family sits left of the between-stamped competitor")
            XCTAssertEqual(slots["o1"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                           "[\(label)] detached instance folds into the family slot")
            XCTAssertEqual(slots["c1"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                           "[\(label)] embedded child folds into the family slot")
            XCTAssertEqual(slots["x"]!.xOffsetFraction, 0.5, accuracy: 0.001)
        }

        // Block two: ancient child stamp, competitor below both parents,
        // one order feeding the child before any parent has been seen.
        let anchor2 = UUID()
        var detached2Event = Event(id: UUID(), title: "Detached2",
                                   createdAt: peerCreationBase)
        detached2Event.recurrenceParentId = anchor2
        detached2Event.recurrenceInstanceDate = Self.date("2026-05-05T00:00:00Z")
        let split2Event = Event(id: anchor2, title: "Split2",
                                createdAt: peerCreationBase.addingTimeInterval(120))
        let child2Event = Event(
            id: UUID(),
            title: "Child2",
            createdAt: peerCreationBase.addingTimeInterval(-3600),
            displayKind: .interrupt,
            interruptRelation: EventInterruptRelation(
                parentEventID: anchor2,
                occurrenceDate: Self.date("2026-05-05T00:00:00Z"),
                state: .embedded
            )
        )
        let competitor2Event = Event(id: UUID(), title: "Competitor2",
                                     createdAt: peerCreationBase.addingTimeInterval(-60))

        let detached2 = occ("o2", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                            event: detached2Event)
        let split2 = occ("p2", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                         event: split2Event)
        let competitor2 = occ("x2", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                              event: competitor2Event)
        let child2 = occ("c2", "2026-05-05T10:00:00Z", "2026-05-05T10:15:00Z",
                         event: child2Event)

        let orderC = layout([child2, detached2, split2, competitor2])
        let orderD = layout([split2, competitor2, child2, detached2])

        for (label, slots) in [("C", orderC), ("D", orderD)] {
            XCTAssertEqual(slots["x2"]!.xOffsetFraction, 0.0, accuracy: 0.001,
                           "[\(label)] the competitor predates both parents — it stays left")
            XCTAssertEqual(slots["p2"]!.xOffsetFraction, 0.5, accuracy: 0.001,
                           "[\(label)] the child's ancient stamp must not drag the " +
                           "family left of the competitor, even when the child is fed first")
            XCTAssertEqual(slots["o2"]!.xOffsetFraction, 0.5, accuracy: 0.001,
                           "[\(label)] detached instance folds into the family slot")
            XCTAssertEqual(slots["c2"]!.xOffsetFraction, 0.5, accuracy: 0.001,
                           "[\(label)] embedded child folds into the family slot")
        }
    }

    /// Stack-peek host selection: duration and start still dominate; on a
    /// full tie the earlier-created group hosts, replacing the old id key.
    func testHostPickPrefersEarlierCreatedOnDurationTie() {
        let laterTwin = occ("a", "2026-05-05T10:00:00Z", "2026-05-05T12:00:00Z",
                            createdAt: peerCreationBase.addingTimeInterval(60))
        let earlierTwin = occ("b", "2026-05-05T10:00:00Z", "2026-05-05T12:00:00Z",
                              createdAt: peerCreationBase)
        let short = occ("c", "2026-05-05T10:00:00Z", "2026-05-05T10:30:00Z",
                        createdAt: peerCreationBase.addingTimeInterval(120))

        let slots = layout([laterTwin, earlierTwin, short])
        XCTAssertEqual(slots["b"]!.depth, 0,
                       "earlier-created twin must win the host tie, not the smaller id")
        XCTAssertEqual(slots["b"]!.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertFalse(slots["b"]!.coverRanges.isEmpty)
        XCTAssertEqual(slots["a"]!.depth, 1)
        XCTAssertEqual(slots["a"]!.xOffsetFraction, 0.5, accuracy: 0.001)
    }

    /// `timelineVisibleOccurrences` shares the contract: equal start/end
    /// orders by createdAt before the id fallback.
    func testTimelineVisibleOccurrencesTieBreakUsesCreatedAt() {
        let earlier = occ("b", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                          createdAt: peerCreationBase)
        let later = occ("a", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z",
                        createdAt: peerCreationBase.addingTimeInterval(60))

        let visible = CalendarLayout.timelineVisibleOccurrences(
            forDayOffset: 0,
            reference: Self.date("2026-05-05T12:00:00Z"),
            calendar: calendar
        ) { _ in [later, earlier] }

        XCTAssertEqual(visible.map(\.id), ["b", "a"],
                       "equal-range occurrences must order by createdAt before id")
    }
}
