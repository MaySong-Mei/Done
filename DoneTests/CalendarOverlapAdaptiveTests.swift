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
}
