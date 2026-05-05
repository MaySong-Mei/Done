import XCTest
@testable import Done

/// Tests for the stack-with-peek overlap layout in `CalendarLayout.overlapLayout`.
/// All cases use a 1-hour-per-pt-equivalent visible window so durations map
/// cleanly. `peekFraction = 0.02` (the layer offset), `canvas = 1.0` (fractional).
final class CalendarOverlapStackPeekTests: XCTestCase {

    private var visibleStart: Date { Self.date("2026-05-05T00:00:00Z") }
    private var visibleEnd: Date { Self.date("2026-05-06T00:00:00Z") }
    private let peek: CGFloat = 0.02
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

    private func occurrence(id: String, _ startISO: String, _ endISO: String) -> CalendarLayout.EventOccurrence {
        let event = Event(title: id)
        return CalendarLayout.EventOccurrence(
            id: id,
            event: event,
            range: Event.TimeRange(start: Self.date(startISO), end: Self.date(endISO))
        )
    }

    private func layout(
        _ occs: [CalendarLayout.EventOccurrence],
        peerTolerance: TimeInterval = 0
    ) -> [String: CalendarLayout.EventOverlapSlot] {
        CalendarLayout.overlapLayout(
            for: occs,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            peekFraction: peek,
            peerTolerance: peerTolerance
        )
    }

    // MARK: - Topologies

    /// Two events with truly identical start AND end should fall back to
    /// equal split at the same depth — not stacked with peek.
    func testIdenticalEventsEqualSplitAtSameDepth() {
        let a = occurrence(id: "A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b])
        let sa = slots["A"]!
        let sb = slots["B"]!

        XCTAssertEqual(sa.depth, 0)
        XCTAssertEqual(sb.depth, 0)
        // Equal width = 0.5 each. Sum = 1.0 (full canvas), no peek.
        XCTAssertEqual(sa.widthFraction + sb.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(sa.widthFraction, sb.widthFraction, accuracy: 0.001)
        XCTAssertTrue(sa.coverRanges.isEmpty, "Peers don't cover each other")
        XCTAssertTrue(sb.coverRanges.isEmpty)
    }

    /// Same start, A longer. A is depth 0 (longest); B is depth 1.
    /// A is covered during B's range (the aligned-start band).
    func testAlignedStartLongerGoesToDepthZero() {
        let a = occurrence(id: "A", "2026-05-05T10:00:00Z", "2026-05-05T12:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b])
        let sa = slots["A"]!
        let sb = slots["B"]!

        XCTAssertEqual(sa.depth, 0)
        XCTAssertEqual(sb.depth, 1)
        XCTAssertEqual(sa.xOffsetFraction, 0, accuracy: 0.001)
        XCTAssertEqual(sb.xOffsetFraction, peek, accuracy: 0.001)
        XCTAssertEqual(sa.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(sb.widthFraction, 1.0 - peek, accuracy: 0.001)

        // A is covered exactly during B's range
        XCTAssertEqual(sa.coverRanges.count, 1)
        XCTAssertEqual(sa.coverRanges.first?.start, b.range.start)
        XCTAssertEqual(sa.coverRanges.first?.end, b.range.end)
        XCTAssertTrue(sb.coverRanges.isEmpty)
    }

    /// Same end, A starts earlier. A wins depth 0 (longer).
    func testAlignedEndLongerGoesToDepthZero() {
        let a = occurrence(id: "A", "2026-05-05T09:00:00Z", "2026-05-05T11:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b])

        XCTAssertEqual(slots["A"]?.depth, 0)
        XCTAssertEqual(slots["B"]?.depth, 1)
        XCTAssertEqual(slots["A"]?.coverRanges.count, 1)
        XCTAssertEqual(slots["A"]?.coverRanges.first?.start, b.range.start)
        XCTAssertEqual(slots["A"]?.coverRanges.first?.end, b.range.end)
    }

    /// Strict containment: A 9-12, B 10-11 fully inside A.
    /// A is depth 0; B is depth 1 with no covers; A has one cover band.
    func testContainmentNonInterrupt() {
        let a = occurrence(id: "A", "2026-05-05T09:00:00Z", "2026-05-05T12:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b])
        let sa = slots["A"]!
        let sb = slots["B"]!

        XCTAssertEqual(sa.depth, 0)
        XCTAssertEqual(sb.depth, 1)
        XCTAssertEqual(sa.coverRanges.count, 1)
        XCTAssertTrue(sb.coverRanges.isEmpty)
    }

    /// Staircase: A 9-11, B 10-12 (same duration, partial overlap).
    /// Tie on duration → start-asc → A first → A depth 0, B depth 1.
    func testStaircaseEqualDuration() {
        let a = occurrence(id: "A", "2026-05-05T09:00:00Z", "2026-05-05T11:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:00Z", "2026-05-05T12:00:00Z")
        let slots = layout([a, b])

        XCTAssertEqual(slots["A"]?.depth, 0)
        XCTAssertEqual(slots["B"]?.depth, 1)
        // A's cover is the overlap band [10:00, 11:00]
        let cover = slots["A"]?.coverRanges.first
        XCTAssertEqual(cover?.start, Self.date("2026-05-05T10:00:00Z"))
        XCTAssertEqual(cover?.end, Self.date("2026-05-05T11:00:00Z"))
    }

    /// 3-event cascade: A 9-13 (longest), B 10-12, C 10:30-11:30.
    /// All three mutually overlap → depths 0, 1, 2.
    /// A covered by union of B and C → merged to [10:00, 12:00].
    func testThreeEventCascade() {
        let a = occurrence(id: "A", "2026-05-05T09:00:00Z", "2026-05-05T13:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:00Z", "2026-05-05T12:00:00Z")
        let c = occurrence(id: "C", "2026-05-05T10:30:00Z", "2026-05-05T11:30:00Z")
        let slots = layout([a, b, c])

        XCTAssertEqual(slots["A"]?.depth, 0)
        XCTAssertEqual(slots["B"]?.depth, 1)
        XCTAssertEqual(slots["C"]?.depth, 2)

        XCTAssertEqual(slots["A"]!.xOffsetFraction, 0, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.xOffsetFraction, peek, accuracy: 0.001)
        XCTAssertEqual(slots["C"]!.xOffsetFraction, 2 * peek, accuracy: 0.001)

        // A's covers: [10:00, 12:00] (B union C; merged since they overlap)
        XCTAssertEqual(slots["A"]?.coverRanges.count, 1)
        XCTAssertEqual(slots["A"]?.coverRanges.first?.start, Self.date("2026-05-05T10:00:00Z"))
        XCTAssertEqual(slots["A"]?.coverRanges.first?.end, Self.date("2026-05-05T12:00:00Z"))

        // B's covers: [10:30, 11:30] (only C)
        XCTAssertEqual(slots["B"]?.coverRanges.count, 1)
        XCTAssertEqual(slots["B"]?.coverRanges.first?.start, Self.date("2026-05-05T10:30:00Z"))
        XCTAssertEqual(slots["B"]?.coverRanges.first?.end, Self.date("2026-05-05T11:30:00Z"))

        // C: no covers (highest depth)
        XCTAssertTrue(slots["C"]?.coverRanges.isEmpty ?? false)
    }

    /// Back-to-back events (no time overlap) should both be depth 0.
    func testBackToBackNotOverlapping() {
        let a = occurrence(id: "A", "2026-05-05T09:00:00Z", "2026-05-05T10:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b])

        // No overlap → not in same cluster → both default
        XCTAssertEqual(slots["A"]?.depth, 0)
        XCTAssertEqual(slots["B"]?.depth, 0)
        XCTAssertEqual(slots["A"]!.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.widthFraction, 1.0, accuracy: 0.001)
    }

    /// Single event with no neighbors should be the default slot (full width).
    func testSingleEventGetsDefaultSlot() {
        let a = occurrence(id: "A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a])
        XCTAssertEqual(slots["A"]!.widthFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(slots["A"]!.xOffsetFraction, 0, accuracy: 0.001)
        XCTAssertTrue(slots["A"]?.coverRanges.isEmpty ?? false)
    }

    /// Three identical-time events should all be depth 0, equal-split into thirds.
    func testThreeIdenticalEventsThirdsSplit() {
        let a = occurrence(id: "A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let c = occurrence(id: "C", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b, c])

        XCTAssertEqual(slots["A"]?.depth, 0)
        XCTAssertEqual(slots["B"]?.depth, 0)
        XCTAssertEqual(slots["C"]?.depth, 0)

        let widths = [slots["A"]!, slots["B"]!, slots["C"]!].map { $0.widthFraction }
        XCTAssertEqual(widths.reduce(0, +), 1.0, accuracy: 0.001)
        for w in widths {
            XCTAssertEqual(w, 1.0 / 3.0, accuracy: 0.001)
        }
        // Peers don't cover each other
        XCTAssertTrue(slots["A"]!.coverRanges.isEmpty)
        XCTAssertTrue(slots["B"]!.coverRanges.isEmpty)
        XCTAssertTrue(slots["C"]!.coverRanges.isEmpty)
    }

    /// Mixed: two identical peers + a longer wrapping event.
    /// The wrapping event is depth 0 alone; the two peers share depth 1
    /// and split that depth's reduced width.
    func testMixedIdenticalPeersInsideLongerWrapper() {
        let big = occurrence(id: "BIG", "2026-05-05T09:00:00Z", "2026-05-05T13:00:00Z")
        let p1 = occurrence(id: "P1", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let p2 = occurrence(id: "P2", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([big, p1, p2])

        XCTAssertEqual(slots["BIG"]?.depth, 0)
        XCTAssertEqual(slots["P1"]?.depth, 1)
        XCTAssertEqual(slots["P2"]?.depth, 1)

        // Depth 1 width = 1 - peek; peers split equally
        let depth1Width = 1.0 - peek
        XCTAssertEqual(slots["P1"]!.widthFraction, depth1Width / 2.0, accuracy: 0.001)
        XCTAssertEqual(slots["P2"]!.widthFraction, depth1Width / 2.0, accuracy: 0.001)
        // Sum of peer xOffset positions stays inside [peek, 1.0]
        let p1End = (slots["P1"]!.xOffsetFraction) + (slots["P1"]!.widthFraction)
        let p2End = (slots["P2"]!.xOffsetFraction) + (slots["P2"]!.widthFraction)
        XCTAssertLessThanOrEqual(p1End, 1.0 + 0.001)
        XCTAssertLessThanOrEqual(p2End, 1.0 + 0.001)

        // BIG is covered during the peer band [10:00, 11:00]
        XCTAssertEqual(slots["BIG"]?.coverRanges.count, 1)
        XCTAssertEqual(slots["BIG"]?.coverRanges.first?.start, Self.date("2026-05-05T10:00:00Z"))
        XCTAssertEqual(slots["BIG"]?.coverRanges.first?.end, Self.date("2026-05-05T11:00:00Z"))
    }

    // MARK: - peerTolerance behavior

    /// Two events differing by less than the peer-tolerance on both ends
    /// should be treated as peers (equal-split, depth 0, no covers).
    func testPeerToleranceMakesAlmostIdenticalEventsPeers() {
        // 3-min start drift, 2-min end drift; tolerance 5 min absorbs both.
        let a = occurrence(id: "A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:03:00Z", "2026-05-05T11:02:00Z")
        let slots = layout([a, b], peerTolerance: 5 * 60)

        XCTAssertEqual(slots["A"]?.depth, 0)
        XCTAssertEqual(slots["B"]?.depth, 0)
        XCTAssertEqual(slots["A"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertTrue(slots["A"]!.coverRanges.isEmpty)
        XCTAssertTrue(slots["B"]!.coverRanges.isEmpty)
    }

    /// Two events drifted beyond the tolerance should NOT be peers —
    /// they fall back to stack-peek with the longer at depth 0.
    func testPeerToleranceRespectsBoundary() {
        // 10-min start drift exceeds 5-min tolerance.
        let a = occurrence(id: "A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:10:00Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b], peerTolerance: 5 * 60)

        // A and B differ on start by 10 min; B is shorter; A → depth 0.
        XCTAssertNotEqual(slots["A"]?.depth, slots["B"]?.depth)
    }

    /// With tolerance = 0, near-identical events stack (matches strict mode).
    func testPeerToleranceZeroIsStrict() {
        let a = occurrence(id: "A", "2026-05-05T10:00:00Z", "2026-05-05T11:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T10:00:30Z", "2026-05-05T11:00:00Z")
        let slots = layout([a, b], peerTolerance: 0)

        // Even a 30s drift puts them at different depths under strict mode.
        XCTAssertNotEqual(slots["A"]?.depth, slots["B"]?.depth)
    }

    // MARK: - z-order semantics: later on top

    /// Short event starts earlier; a longer event starts later and overlaps
    /// the tail of the short one. The later event must sit at higher depth
    /// (= on top during overlap), even though it's the longer one. Earlier
    /// event lands at depth 0; later event lands at depth 1.
    func testLaterStartGoesOnTopEvenWhenLonger() {
        let a = occurrence(id: "A", "2026-05-05T09:00:00Z", "2026-05-05T09:30:00Z")
        let b = occurrence(id: "B", "2026-05-05T09:15:00Z", "2026-05-05T13:00:00Z")
        let slots = layout([a, b])

        XCTAssertEqual(slots["A"]?.depth, 0, "Earlier event sits at the back")
        XCTAssertEqual(slots["B"]?.depth, 1, "Later event renders on top")
        // A's cover band is the overlap window [9:15, 9:30]
        XCTAssertEqual(slots["A"]?.coverRanges.count, 1)
        XCTAssertEqual(slots["A"]?.coverRanges.first?.start, Self.date("2026-05-05T09:15:00Z"))
        XCTAssertEqual(slots["A"]?.coverRanges.first?.end, Self.date("2026-05-05T09:30:00Z"))
    }

    /// Legacy equal-split mode (peekFraction = 0) preserves the old
    /// column behavior — depth stays 0 because that field is unused
    /// in legacy mode (the slot constructor leaves the default).
    func testLegacyEqualSplitPathUnchanged() {
        let a = occurrence(id: "A", "2026-05-05T10:00:00Z", "2026-05-05T12:00:00Z")
        let b = occurrence(id: "B", "2026-05-05T11:00:00Z", "2026-05-05T13:00:00Z")
        let slots = CalendarLayout.overlapLayout(
            for: [a, b],
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            calendar: calendar,
            peekFraction: 0
        )
        // Both should occupy half the canvas (legacy column packing).
        XCTAssertEqual(slots["A"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(slots["B"]!.widthFraction, 0.5, accuracy: 0.001)
        XCTAssertTrue(slots["A"]?.coverRanges.isEmpty ?? false)
        XCTAssertTrue(slots["B"]?.coverRanges.isEmpty ?? false)
    }
}
