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
}
