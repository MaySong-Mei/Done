import XCTest
import UIKit
import CoreText
import SwiftUI
@testable import Done

/// Coverage for the widget's layout arithmetic (gh#239).
///
/// `DoneWidget` has no test bundle, so everything whose correctness is
/// arithmetic rather than appearance was moved into `Shared/WidgetLayout.swift`
/// — a file both targets compile — precisely so it could be asserted here.
/// The views keep only the drawing.
final class WidgetLayoutTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// 2026-03-10 00:00 UTC — a plain mid-month Tuesday, no DST edge.
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))! }

    private func t(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
    }

    private func snap(
        _ title: String, _ start: Date, _ end: Date,
        id: UUID = UUID(), eventID: UUID? = nil,
        interrupt: Bool = false, parent: UUID? = nil
    ) -> SharedEventSnapshot {
        SharedEventSnapshot(
            id: id, eventID: eventID ?? id, title: title, type: "Deep Work", colorHex: "4A90D9",
            startDate: start, endDate: end, isAllDay: false, isDone: false,
            isInterrupt: interrupt ? true : nil, parentEventID: parent
        )
    }

    // MARK: - The invariant the whole packer exists for (F1)

    /// Two occurrences that share any instant must not share any horizontal
    /// space. Asserted as a property over the slots rather than against
    /// hand-computed fractions, so it keeps its teeth if the packing strategy
    /// is ever retuned.
    private func assertNoCollision(
        _ events: [SharedEventSnapshot], _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertEqual(slots.count, events.count, "\(label): one slot per occurrence", file: file, line: line)
        for i in events.indices {
            XCTAssertGreaterThan(slots[i].width, 0, "\(label): \(events[i].title) has no width", file: file, line: line)
            XCTAssertGreaterThanOrEqual(slots[i].x, 0, "\(label): \(events[i].title) starts left of the lane", file: file, line: line)
            XCTAssertLessThanOrEqual(slots[i].x + slots[i].width, 1.0 + 1e-9,
                                     "\(label): \(events[i].title) runs past the lane", file: file, line: line)
            guard i + 1 < events.count else { continue }
            for j in (i + 1)..<events.count {
                // Overlays deliberately sit inside their parent's slot; the
                // invariant is about lane citizens.
                if slots[i].isOverlay || slots[j].isOverlay { continue }
                let concurrent = events[i].startDate < events[j].endDate
                    && events[j].startDate < events[i].endDate
                guard concurrent else { continue }
                let intersect = min(slots[i].x + slots[i].width, slots[j].x + slots[j].width)
                    - max(slots[i].x, slots[j].x)
                XCTAssertLessThanOrEqual(
                    intersect, 1e-9,
                    "\(label): \(events[i].title) and \(events[j].title) are concurrent but overlap horizontally by \(intersect)",
                    file: file, line: line
                )
            }
        }
    }

    /// The exact shape that shipped broken: each event computed its own column
    /// COUNT, so the three disagreed about the denominator and two pairs
    /// overlapped by 14% of the lane.
    func testStaircaseOverlapDoesNotCollide() {
        assertNoCollision([
            snap("Alpha", t(13, 30), t(15, 0)),
            snap("Bravo", t(14, 0), t(15, 30)),
            snap("Charlie", t(15, 15), t(16, 15)),
        ], "3-way staircase")
    }

    func testFourWayStaircaseDoesNotCollide() {
        assertNoCollision([
            snap("A", t(13, 0), t(14, 30)),
            snap("B", t(13, 30), t(15, 0)),
            snap("C", t(14, 0), t(15, 30)),
            snap("D", t(14, 30), t(16, 0)),
        ], "4-way staircase")
    }

    /// The two shapes that happened to work before — they must keep working.
    func testPairwiseAndFullyConcurrentStillSplitEvenly() {
        let pair = [snap("A", t(13, 30), t(15, 0)), snap("B", t(14, 0), t(15, 30))]
        assertNoCollision(pair, "pair")
        let pairSlots = WidgetLayout.miniTimelineSlots(for: pair)
        XCTAssertEqual(pairSlots[0].x, 0, accuracy: 1e-9)
        XCTAssertEqual(pairSlots[0].width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pairSlots[1].x, 0.5, accuracy: 1e-9)

        let trio = [snap("A", t(14), t(15)), snap("B", t(14), t(15)), snap("C", t(14), t(15))]
        assertNoCollision(trio, "3 fully concurrent")
        for (i, slot) in WidgetLayout.miniTimelineSlots(for: trio).enumerated() {
            XCTAssertEqual(slot.width, 1.0 / 3, accuracy: 1e-9)
            XCTAssertEqual(slot.x, Double(i) / 3, accuracy: 1e-9)
        }
    }

    /// A lone occurrence, and occurrences in separate clusters, each own the
    /// whole lane — a cluster's denominator must not leak into its neighbours.
    func testDisjointEventsEachKeepTheFullLane() {
        let events = [
            snap("morning", t(9), t(10)),
            snap("noon", t(12), t(13)),
            snap("evening", t(19), t(20)),
        ]
        for slot in WidgetLayout.miniTimelineSlots(for: events) {
            XCTAssertEqual(slot.x, 0, accuracy: 1e-9)
            XCTAssertEqual(slot.width, 1, accuracy: 1e-9)
        }
    }

    /// Touching at an instant is not overlapping, and two consecutive events
    /// must REUSE one column rather than each taking their own.
    ///
    /// The first spelling used only the two consecutive events, which are two
    /// singleton clusters — they returned `.full` without the packer ever
    /// running, so the assertion held for any column rule at all (gh#239 QA).
    /// The `host` here forces all three into one cluster, so the widths are
    /// genuinely the packer's answer: `first` and `second` share column 1
    /// because `columnEnd[1] <= second.start`.
    func testBackToBackEventsShareOneColumn() {
        let events = [
            snap("host", t(9), t(11)),        // overlaps both, forces one cluster
            snap("first", t(9), t(10)),
            snap("second", t(10), t(11)),
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[0].x, 0, accuracy: 1e-9)
        XCTAssertEqual(slots[0].width, 0.5, accuracy: 1e-9, "host owns column 0 of a two-column cluster")
        XCTAssertEqual(slots[1].x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(slots[2].x, 0.5, accuracy: 1e-9, "the consecutive pair must reuse ONE column, not open a third")
        XCTAssertEqual(slots[1].width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(slots[2].width, 0.5, accuracy: 1e-9)
        assertNoCollision(events, "back to back inside a cluster")
    }

    /// A block expands rightward through columns holding nothing concurrent,
    /// so a cluster never leaves a permanently empty strip.
    ///
    /// The first fixture put its third event in its OWN cluster, so the width
    /// it asserted came from the singleton shortcut and the expansion loop ran
    /// zero times across the whole suite — deleting the loop outright kept
    /// every test green (gh#239 QA). Here all four are one cluster (`host`
    /// spans them all), the cluster needs three columns, and `late` is
    /// concurrent with nothing in columns 2 or 3, so it must widen to 2/3 of
    /// the lane instead of sitting in a third of it.
    func testBlockExpandsIntoAnEmptyNeighbouringColumn() {
        let events = [
            snap("host", t(13), t(16)),          // column 0 all afternoon
            snap("early", t(13, 10), t(13, 20)), // column 1
            snap("earlyPeer", t(13, 15), t(13, 25)), // forces column 2
            snap("late", t(13, 30), t(13, 40)),  // reuses column 1, nothing in 2 is concurrent
        ]
        assertNoCollision(events, "expansion")
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertEqual(slots[0].width, 1.0 / 3, accuracy: 1e-9, "host is boxed in by both peers")
        XCTAssertEqual(slots[1].width, 1.0 / 3, accuracy: 1e-9, "early is boxed in by earlyPeer")
        XCTAssertEqual(slots[3].x, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(slots[3].width, 2.0 / 3, accuracy: 1e-9,
                       "late must expand through the free column instead of leaving a third of the lane empty")
    }

    /// splitmix64 — a SEEDED generator, so a red run is reproducible.
    ///
    /// `SystemRandomNumberGenerator` was the first spelling and is the wrong
    /// one for a suite that must not flake: a failure reported synthetic titles
    /// and no seed, so nobody could turn the red into a fixture (gh#239 QA).
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Randomised days: the invariant must hold for shapes nobody thought of.
    ///
    /// The generator is biased toward the shape that broke the predecessor —
    /// staircases of partially-overlapping events — because uniformly random
    /// day-long intervals mostly produce disjoint or fully-nested pairs, which
    /// the OLD code also got right.
    func testRandomDaysNeverCollide() {
        for seed in UInt64(1)...40 {
            var rng = Seeded(state: seed)
            for trial in 0..<200 {
                let count = Int.random(in: 2...9, using: &rng)
                var events: [SharedEventSnapshot] = []
                var cursor = Int.random(in: 0..<600, using: &rng)
                for i in 0..<count {
                    // Step forward by less than the previous duration most of
                    // the time, so consecutive events overlap partially.
                    let duration = Int.random(in: 10...180, using: &rng)
                    events.append(snap(
                        "e\(i)@\(cursor)+\(duration)",
                        calendar.date(byAdding: .minute, value: cursor, to: day)!,
                        calendar.date(byAdding: .minute, value: cursor + duration, to: day)!
                    ))
                    cursor += Int.random(in: 0...(duration + 30), using: &rng)
                }
                events.sort { $0.startDate < $1.startDate }
                assertNoCollision(events, "seed \(seed) trial \(trial)")
            }
        }
    }

    /// The generator above must actually produce the shape the packer exists
    /// for. Without this, a generator that only ever emitted disjoint events
    /// would report 8000 green trials and mean nothing.
    func testRandomGeneratorActuallyProducesMultiColumnClusters() {
        var multiColumn = 0
        for seed in UInt64(1)...40 {
            var rng = Seeded(state: seed)
            for _ in 0..<200 {
                let count = Int.random(in: 2...9, using: &rng)
                var events: [SharedEventSnapshot] = []
                var cursor = Int.random(in: 0..<600, using: &rng)
                for i in 0..<count {
                    let duration = Int.random(in: 10...180, using: &rng)
                    events.append(snap(
                        "e\(i)",
                        calendar.date(byAdding: .minute, value: cursor, to: day)!,
                        calendar.date(byAdding: .minute, value: cursor + duration, to: day)!
                    ))
                    cursor += Int.random(in: 0...(duration + 30), using: &rng)
                }
                events.sort { $0.startDate < $1.startDate }
                if WidgetLayout.miniTimelineSlots(for: events).contains(where: { $0.width < 0.999 }) {
                    multiColumn += 1
                }
            }
        }
        XCTAssertGreaterThan(multiColumn, 4000,
                             "the random corpus must be mostly multi-column days — \(multiColumn)/8000 were")
    }

    // MARK: - Interrupts (F8)

    func testInterruptInheritsItsParentSlotAndIsMarkedOverlay() {
        let parentID = UUID()
        let events = [
            snap("host", t(13), t(15), id: parentID, eventID: parentID),
            snap("peer", t(13, 30), t(15, 30)),
            snap("call", t(14), t(14, 20), interrupt: true, parent: parentID),
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertTrue(slots[2].isOverlay)
        XCTAssertEqual(slots[2].x, slots[0].x, accuracy: 1e-9)
        XCTAssertEqual(slots[2].width, slots[0].width, accuracy: 1e-9)
        assertNoCollision(events, "interrupt with parent")
    }

    /// An interrupt whose parent is not in this list — an all-day parent
    /// (filtered out by `WidgetTimelineSchedule.events`), or a parent
    /// occurrence on another day. It used to keep the untouched full-width
    /// default and paint over everything.
    func testOrphanInterruptIsPackedInsteadOfClaimingTheWholeLane() {
        let events = [
            snap("focus", t(14), t(16)),
            snap("call", t(14, 45), t(15, 5), interrupt: true, parent: UUID()),
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertFalse(slots[1].isOverlay, "an orphan interrupt has no parent slot to sit inside")
        XCTAssertLessThan(slots[1].width, 1, "it must not claim the whole lane")
        assertNoCollision(events, "orphan interrupt")
    }

    /// An interrupt with no `parentEventID` at all is the same case.
    func testParentlessInterruptIsPacked() {
        let events = [
            snap("focus", t(14), t(16)),
            snap("call", t(14, 45), t(15, 5), interrupt: true, parent: nil),
        ]
        assertNoCollision(events, "parentless interrupt")
        XCTAssertFalse(WidgetLayout.miniTimelineSlots(for: events)[1].isOverlay)
    }

    /// A recurring parent shows up twice in one window; the interrupt must
    /// follow the occurrence it actually sits inside, not the first match.
    func testInterruptPrefersTheParentOccurrenceItSitsInside() {
        let parentID = UUID()
        let first = SharedEventSnapshot.occurrenceID(eventID: parentID, occurrenceStart: t(9))
        let second = SharedEventSnapshot.occurrenceID(eventID: parentID, occurrenceStart: t(14))
        let events = [
            snap("host am", t(9), t(10), id: first, eventID: parentID),
            snap("peer", t(9, 30), t(10, 30)),                     // forces the am cluster to 2 columns
            snap("host pm", t(14), t(16), id: second, eventID: parentID),
            snap("call", t(14, 30), t(15), interrupt: true, parent: parentID),
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertTrue(slots[3].isOverlay)
        XCTAssertEqual(slots[3].x, slots[2].x, accuracy: 1e-9, "should follow the pm occurrence")
        XCTAssertEqual(slots[3].width, slots[2].width, accuracy: 1e-9)
        XCTAssertNotEqual(slots[2].width, slots[0].width, "fixture is only meaningful if the two occurrences differ")
    }

    func testEmptyInputProducesNoSlots() {
        XCTAssertTrue(WidgetLayout.miniTimelineSlots(for: []).isEmpty)
    }

    // MARK: - Axis label suppression (F7)

    /// Measured ink of one axis label: `ascender - descender` for
    /// `.systemFont(ofSize: 7, weight: .semibold)`. Copied into the fixture
    /// rather than left in a comment, so the rule is checked against a number
    /// the suite owns.
    private let axisLabelInk: CGFloat = 8.25

    /// The property that matters: whatever the rule decides to draw must not
    /// land inside the now-label's ink, at any of the three widget heights.
    func testEveryDrawnHourLabelClearsTheNowLabel() {
        for height in [CGFloat(116), 126, 138] {
            let pps = height / (6 * 3600)
            let nowY = height * 0.4
            for minutes in 1...180 {
                for direction in [-1.0, 1.0] {
                    let y = nowY + CGFloat(direction) * CGFloat(minutes * 60) * pps
                    guard WidgetLayout.hourLabelFits(markerY: y, nowY: nowY) else { continue }
                    XCTAssertGreaterThanOrEqual(
                        abs(y - nowY), axisLabelInk,
                        "h=\(height): a label \(minutes) min away is drawn \(abs(y - nowY))pt from the now-label and overlaps it"
                    )
                }
            }
            let farY = nowY + CGFloat(3600) * pps
            XCTAssertTrue(WidgetLayout.hourLabelFits(markerY: farY, nowY: nowY),
                          "h=\(height): an hour away is always far enough to draw")
        }
    }

    /// Witness for the rule that was retired: 21 minutes cleared the old
    /// `> 20 minutes` guard at every widget height, and 21 minutes is inside a
    /// label's ink at every widget height. Without this the fix reads as a
    /// refactor.
    func testTheRetiredMinuteGuardAdmittedACollisionAtEveryHeight() {
        for height in [CGFloat(116), 126, 138] {
            let pps = height / (6 * 3600)
            let nowY = height * 0.4
            let y = nowY + CGFloat(21 * 60) * pps
            XCTAssertLessThan(abs(y - nowY), axisLabelInk,
                              "h=\(height): fixture is stale — 21 min no longer collides")
            XCTAssertFalse(WidgetLayout.hourLabelFits(markerY: y, nowY: nowY),
                           "h=\(height): the point rule must reject what the minute rule admitted")
        }
    }

    /// Above and below the now-line must behave identically — and the fixture
    /// has to straddle the threshold to say anything.
    ///
    /// The first spelling compared markerY 50 and 62 against nowY 56: both 6pt
    /// away, both suppressed, so it asserted `false == false` and held for any
    /// monotone rule. Dropping the `abs()` — which erases every hour label
    /// ABOVE the now-line, two of the six the mini timeline draws — kept the
    /// whole suite green (gh#239 QA).
    func testHourLabelSuppressionIsSymmetric() {
        let nowY: CGFloat = 56
        for distance in stride(from: CGFloat(1), through: 40, by: 0.5) {
            let above = WidgetLayout.hourLabelFits(markerY: nowY - distance, nowY: nowY)
            let below = WidgetLayout.hourLabelFits(markerY: nowY + distance, nowY: nowY)
            XCTAssertEqual(above, below, "asymmetric at distance \(distance)")
        }
        // …and the sweep must actually cross the threshold, in both directions.
        XCTAssertTrue(WidgetLayout.hourLabelFits(markerY: nowY - 40, nowY: nowY),
                      "a far marker ABOVE the now-line must be drawn")
        XCTAssertTrue(WidgetLayout.hourLabelFits(markerY: nowY + 40, nowY: nowY),
                      "a far marker BELOW the now-line must be drawn")
        XCTAssertFalse(WidgetLayout.hourLabelFits(markerY: nowY - 1, nowY: nowY))
        XCTAssertFalse(WidgetLayout.hourLabelFits(markerY: nowY + 1, nowY: nowY))
    }

    /// The clearance constant needs an UPPER bound too. The drawn-label sweep
    /// only constrains what the rule draws, so a wildly generous clearance —
    /// 19pt, which eats two of the six hour labels on a 116pt box — satisfied
    /// every other assertion (gh#239 QA).
    func testAxisLabelClearanceIsBoundedOnBothSides() {
        XCTAssertGreaterThanOrEqual(
            WidgetLayout.axisLabelLineHeight, axisLabelInk,
            "clearance below the label's own ink lets two labels overlap"
        )
        XCTAssertLessThan(
            WidgetLayout.axisLabelLineHeight, axisLabelInk * 1.5,
            "clearance far above the label's ink suppresses hour labels that would have been perfectly readable"
        )
        // Stated as a consequence: on the smallest box, at most one hour marker
        // either side of the now-line may be suppressed.
        let height: CGFloat = 116
        let pps = height / (6 * 3600)
        let suppressed = (1...6).filter { !WidgetLayout.hourLabelFits(markerY: height * 0.4 + CGFloat($0 * 3600) * pps, nowY: height * 0.4) }
        XCTAssertTrue(suppressed.isEmpty, "no whole-hour marker may be suppressed — only sub-hour proximity to now")
    }

    // MARK: - Row capacity (F2)

    /// The capacity must be exactly the number of rows whose stack still fits
    /// the box — one more must not.
    func testListRowCapacityFillsTheBoxWithoutOverflowing() {
        let header = WidgetLayout.Metrics.listHeaderHeight
        let row = WidgetLayout.Metrics.listRowHeight
        let spacing = WidgetLayout.Metrics.listRowSpacing
        for height in [CGFloat(116), 126, 138, 200, 400] {
            let n = WidgetLayout.listRowCapacity(
                contentHeight: height, headerHeight: header, rowHeight: row, spacing: spacing, cap: 12
            )
            let used = header + CGFloat(n) * (row + spacing)
            XCTAssertLessThanOrEqual(used, height, "h=\(height): \(n) rows do not fit")
            let oneMore = header + CGFloat(n + 1) * (row + spacing)
            XCTAssertGreaterThan(oneMore, height, "h=\(height): \(n + 1) rows would have fitted too")
        }
    }

    func testListRowCapacityAlwaysYieldsAtLeastOneRowAndHonoursTheCap() {
        XCTAssertEqual(
            WidgetLayout.listRowCapacity(contentHeight: 10, headerHeight: 15, rowHeight: 28, spacing: 4),
            1, "a box too small for any row still shows one rather than nothing"
        )
        XCTAssertEqual(
            WidgetLayout.listRowCapacity(contentHeight: 4000, headerHeight: 15, rowHeight: 28, spacing: 4, cap: 4),
            4, "the cap bounds a tall family"
        )
        // The cap must be tested where it BINDS, not where it coincides with
        // the geometric answer (gh#239 QA: at h=400/cap=12 the two agreed, so
        // the clamp was never exercised).
        XCTAssertEqual(
            WidgetLayout.listRowCapacity(contentHeight: 4000, headerHeight: 15, rowHeight: 28, spacing: 4, cap: 3),
            3, "the cap must win over a geometry that would allow far more"
        )
        XCTAssertEqual(
            WidgetLayout.listRowCapacity(contentHeight: 0, headerHeight: 0, rowHeight: 0, spacing: 0),
            1, "degenerate metrics must not divide by zero"
        )
    }

    /// The lists follow the reader's text size up to xxLarge. At that cap
    /// the medium list still shows a header and two rows on every box, and
    /// what it shows fits (gh#248). The factor is UIKit's own for body text.
    func testTheMediumListAtTheTextSizeCapStillFits() {
        let trait = UITraitCollection(preferredContentSizeCategory: .extraExtraLarge)
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: trait)
        XCTAssertGreaterThan(scale, 1.15, "precondition: xxLarge is larger than the default")
        let (header, row) = WidgetLayout.listHeights(scale: scale)
        XCTAssertEqual(row, (WidgetLayout.Metrics.listRowHeight * scale).rounded(.up), "scaled rows are whole points")
        for widget in [CGFloat(146), 162, 164.3, 172.7] {
            let height = widget - 2 * WidgetLayout.Metrics.listVerticalMargin
            let n = WidgetLayout.listRowCapacity(contentHeight: height, headerHeight: header, rowHeight: row,
                                                 spacing: WidgetLayout.Metrics.listRowSpacing, cap: WidgetLayout.Metrics.listRowCap)
            XCTAssertGreaterThanOrEqual(n, 2, "widget \(widget): at the cap it shows \(n) rows")
        }
    }

    /// Under its card the small list shows the events after it: not ended,
    /// not done, not the card's own, in start order (gh#248).
    func testTheSmallListFollowsItsCardWithWhatComesNext() {
        let now = t(14)
        let cardEvent = UUID()
        let card = snap("card", t(13, 30), t(14, 30), eventID: cardEvent)
        let events = [
            snap("ended", t(12), t(13)), snap("ends now", t(13), t(14)), card, snap("later", t(16), t(17)),
            SharedEventSnapshot(id: UUID(), eventID: UUID(), title: "done", type: "Deep Work", colorHex: nil,
                                startDate: t(15), endDate: t(15, 30), isAllDay: false, isDone: true),
            snap("concurrent", t(13, 45), t(15)), snap("soon, longer", t(14, 15), t(14, 50)),
            snap("soon", t(14, 15), t(14, 45)),
            snap("card again", t(18), t(18, 30), eventID: cardEvent),
        ]
        XCTAssertEqual(WidgetLayout.smallListFollowing(events, card: card, now: now).map(\.title),
                       ["concurrent", "soon", "soon, longer", "later", "card again"],
                       "an event ending now is over; the card's event later in the day is another occurrence")
    }

    /// The medium widget's height on the four simulators the sim QA measured
    /// (SE 146, 17e 162, 17 164.3, Air 172.7pt), less the list's own top and
    /// bottom margin, asserted against the SHIPPING metrics — so changing a
    /// metric in the view (which `DoneTests` cannot compile) has to face this
    /// test. Inside the system's 16-19pt margins the 17 and 17e came out at
    /// three rows with room on the widget for a fourth, and the Air at three
    /// because the header was budgeted 0.67pt taller than it draws.
    func testMediumCapacityOnEveryShippingWidgetHeight() {
        let expected: [(CGFloat, Int)] = [(146, 3), (162, 4), (164.3, 4), (172.7, 4)]
        let heights = WidgetLayout.listHeights(scale: 1)
        XCTAssertEqual(heights.header, WidgetLayout.Metrics.listHeaderHeight, "the default size draws the metrics as they are")
        XCTAssertEqual(heights.row, WidgetLayout.Metrics.listRowHeight)
        for (widget, rows) in expected {
            let height = widget - 2 * WidgetLayout.Metrics.listVerticalMargin
            let n = WidgetLayout.listRowCapacity(
                contentHeight: height,
                headerHeight: heights.header,
                rowHeight: heights.row,
                spacing: WidgetLayout.Metrics.listRowSpacing,
                cap: WidgetLayout.Metrics.listRowCap
            )
            XCTAssertEqual(n, rows, "content height \(height)")
            let used = heights.header
                + CGFloat(n) * (heights.row + WidgetLayout.Metrics.listRowSpacing)
            XCTAssertLessThanOrEqual(used, height, "the shipping metrics must actually fit \(height)pt")
        }
    }

    // MARK: - Ring diameter (F4)

    func testRingFitsEveryShippingSmallWidgetBox() {
        let top = WidgetLayout.Metrics.ringTopLabelHeight
        let bottom = WidgetLayout.Metrics.ringBottomLabelHeight
        let spacing = WidgetLayout.Metrics.ringSpacing
        for side in [CGFloat(116), 126, 138] {
            let box = CGSize(width: side, height: side)
            let d = WidgetLayout.ringDiameter(
                content: box, topLabelHeight: top, bottomLabelHeight: bottom, spacing: spacing
            )
            XCTAssertLessThanOrEqual(d + top + bottom + spacing * 2, side, "side=\(side): the stack overflows")
            XCTAssertLessThanOrEqual(d, side)
            XCTAssertGreaterThan(d, 0)
        }
    }

    func testRingNeverExceedsItsMaximumOrCollapsesToNothing() {
        XCTAssertEqual(
            WidgetLayout.ringDiameter(content: CGSize(width: 400, height: 400),
                                      topLabelHeight: 14, bottomLabelHeight: 15, spacing: 8),
            80, "a large box does not inflate the ring past its design size"
        )
        XCTAssertGreaterThanOrEqual(
            WidgetLayout.ringDiameter(content: CGSize(width: 10, height: 10),
                                      topLabelHeight: 14, bottomLabelHeight: 15, spacing: 8),
            24, "a degenerate box still leaves a drawable ring"
        )
    }

    // MARK: - Interrupts that no longer nest in their parent (F8 residual)

    /// An interrupt the app calls `.detached` — dragged out of its parent, the
    /// parent still on the day. The first fix only handled the ORPHAN case (no
    /// parent in the list); with the parent present but disjoint, the untimed
    /// `firstIndex` fallback still handed the interrupt the parent's slot and
    /// the view drew it at its own y, on top of whatever was actually running
    /// there (gh#239 QA).
    func testDetachedInterruptIsPackedNotOverlaid() {
        let parentID = UUID()
        let events = [
            snap("host", t(9), t(10), id: parentID, eventID: parentID),
            snap("peer", t(14), t(15)),
            snap("call", t(14, 10), t(14, 40), interrupt: true, parent: parentID),
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertFalse(slots[2].isOverlay,
                       "an interrupt that no longer touches its parent has no parent slot to sit inside")
        XCTAssertLessThan(slots[2].width, 1, "it must take a column instead of the whole lane")
        assertNoCollision(events, "detached interrupt")
    }

    /// Merely OVERLAPPING the parent is enough to stay an overlay — that is the
    /// app's own `.embedded` predicate, and tightening this to full containment
    /// would silently drop the overlay treatment for an interrupt that ran past
    /// its parent's end.
    func testInterruptOverlappingItsParentStaysAnOverlay() {
        let parentID = UUID()
        let events = [
            snap("host", t(14), t(15), id: parentID, eventID: parentID),
            snap("peer", t(14), t(14, 30)),
            snap("call", t(14, 45), t(15, 30), interrupt: true, parent: parentID),
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertTrue(slots[2].isOverlay, "still overlapping the parent — the app calls this embedded")
        XCTAssertEqual(slots[2].x, slots[0].x, accuracy: 1e-9)
    }

    // MARK: - The medium list's window (F2 follow-on)

    /// `prefix(capacity)` alone took the day's FIRST rows, so at 18:30 a
    /// five-event day showed three finished morning rows and dropped the one
    /// that was running (gh#239 QA).
    func testListWindowKeepsTheRunningEventOnScreen() {
        let events = [
            snap("standup", t(9), t(9, 30)),
            snap("triage", t(10), t(11)),
            snap("lunch", t(12), t(13)),
            snap("review", t(18), t(19, 30)),
            snap("gym", t(20), t(21)),
        ]
        let now = t(18, 30)
        for capacity in 1...4 {
            let rows = WidgetLayout.listWindow(events, now: now, capacity: capacity)
            XCTAssertEqual(rows.count, capacity, "capacity \(capacity)")
            XCTAssertTrue(rows.contains { $0.title == "review" },
                          "capacity \(capacity): the running event must never be the row that falls off")
        }
    }

    /// Late in the day the remaining events no longer fill the box, so the
    /// window backs up rather than leaving it half empty.
    func testListWindowBackfillsWhenTheDayIsNearlyOver() {
        let events = (0..<5).map { snap("e\($0)", t(9 + $0), t(9 + $0, 30)) }
        let rows = WidgetLayout.listWindow(events, now: t(23), capacity: 3)
        XCTAssertEqual(rows.map(\.title), ["e2", "e3", "e4"], "a finished day shows the last rows, not one row")
    }

    func testListWindowDegeneratesSafely() {
        let events = [snap("a", t(9), t(10)), snap("b", t(11), t(12))]
        XCTAssertTrue(WidgetLayout.listWindow([], now: t(12), capacity: 3).isEmpty)
        XCTAssertTrue(WidgetLayout.listWindow(events, now: t(12), capacity: 0).isEmpty)
        XCTAssertEqual(WidgetLayout.listWindow(events, now: t(9), capacity: 9).count, 2,
                       "a capacity larger than the day returns the day")
        XCTAssertEqual(WidgetLayout.listWindow(events, now: t(8), capacity: 1).first?.title, "a",
                       "before the day starts, start at the top")
    }

    /// The window preserves chronological order — a list that reordered rows
    /// to fit would be worse than one that trimmed them.
    func testListWindowPreservesOrder() {
        let events = (0..<6).map { snap("e\($0)", t(9 + $0), t(9 + $0, 45)) }
        for now in [t(9), t(11), t(14), t(23)] {
            let rows = WidgetLayout.listWindow(events, now: now, capacity: 3)
            XCTAssertEqual(rows, rows.sorted { $0.startDate < $1.startDate }, "now=\(now)")
        }
    }

    // MARK: - The timeline bar's stack (F4 residual)

    /// The bar was the one small view F4 left out: a fixed stack that cleared
    /// the 116pt box by under a point, and did not clear it at all with the 12h
    /// clock (gh#239 QA). Its clock line is solved from the box now.
    func testBarStackFitsEveryShippingSmallWidgetBox() {
        for side in measuredMiniHeights {
            let clock = WidgetLayout.barClockHeight(contentHeight: side)
            let stack = WidgetLayout.barStackHeight(clockHeight: clock)
            XCTAssertLessThanOrEqual(stack, side, "side=\(side): stack \(stack) overflows")
            XCTAssertGreaterThanOrEqual(clock, 16, "side=\(side): the clock must stay readable")
            XCTAssertLessThanOrEqual(clock, WidgetLayout.Metrics.barClockHeight,
                                     "side=\(side): a large box must not inflate the clock past its design size")
        }
    }

    /// The solve must actually ENGAGE on the box that needed it, and stay out
    /// of the way on the boxes that did not — otherwise a function that always
    /// returned the design height would pass the fit test above.
    func testBarClockShrinksOnlyOnTheBoxThatCannotHoldIt() {
        let design = WidgetLayout.Metrics.barClockHeight
        let se = measuredMiniHeights[0]
        XCTAssertLessThan(
            WidgetLayout.barClockHeight(contentHeight: se), design,
            "the SE's box is short of the design stack — this is the box where the bar clipped"
        )
        for side in measuredMiniHeights.dropFirst() {
            XCTAssertEqual(WidgetLayout.barClockHeight(contentHeight: side), design, "side=\(side) holds the design stack")
        }
        // And the shrink is exactly the shortfall, not an arbitrary step.
        let shortfall = WidgetLayout.barStackHeight(clockHeight: design) - se
        XCTAssertEqual(WidgetLayout.barClockHeight(contentHeight: se), design - shortfall, accuracy: 1e-9)
    }

    /// The bar's event title takes a second line where the box holds it with
    /// the clock line no shorter than `barClockHeightTwoLines` — the 160-class
    /// boxes — and one line on the SE, whose box the one-line stack already
    /// fills. Whichever, the stack fits (gh#248).
    func testTheBarTitleTakesTwoLinesWhereTheBoxHoldsIt() {
        let m = WidgetLayout.Metrics.self
        XCTAssertEqual(measuredMiniHeights.map { WidgetLayout.barTitleLines(contentHeight: $0) }, [1, 2, 2, 2])
        for side in measuredMiniHeights {
            let lines = WidgetLayout.barTitleLines(contentHeight: side)
            let clock = WidgetLayout.barClockHeight(contentHeight: side, titleLines: lines)
            XCTAssertLessThanOrEqual(WidgetLayout.barStackHeight(clockHeight: clock, titleLines: lines), side + 1e-9,
                                     "side=\(side), \(lines) lines: the stack overflows")
            if lines == 2 {
                XCTAssertGreaterThanOrEqual(clock, m.barClockHeightTwoLines - 1e-9, "side=\(side): the clock gave too much")
            }
        }
        let se = measuredMiniHeights[0]
        XCTAssertGreaterThan(WidgetLayout.barStackHeight(clockHeight: m.barClockHeightTwoLines, titleLines: 2), se,
                             "positive control: the SE has no room for a second line")
    }

    func testBarClockNeverGrowsAndNeverVanishes() {
        XCTAssertEqual(WidgetLayout.barClockHeight(contentHeight: 400),
                       WidgetLayout.Metrics.barClockHeight)
        XCTAssertGreaterThanOrEqual(WidgetLayout.barClockHeight(contentHeight: 10), 16)
    }

    // MARK: - Mini timeline edges (gh#239 sim QA)

    /// The heights the sim QA measured the small content box at: SE, 17e, 17, Air.
    private let measuredMiniHeights: [CGFloat] = [114, 126.6, 128.3, 134.7]

    private func ink(_ title: WidgetLayout.MiniTitle) -> ClosedRange<CGFloat> {
        let m = WidgetLayout.Metrics.self
        return (title.lineTop + m.miniTitleInkTop * title.size)...(title.lineTop + m.miniTitleInkBottom * title.size)
    }

    /// Wherever a block sits — off the top, across the now line, cut by the
    /// bottom edge, two points tall or two hundred — its title's ink is inside
    /// the visible part of its rectangle, or there is no title. It is clear of
    /// the now line unless neither side of the line holds the smallest title,
    /// and then it says so, for the view to cut the line behind it. Asserted
    /// over the whole space, not at picked points.
    func testBlockTitleInkStaysInsideTheVisibleRectangleAndOffTheNowLine() {
        let m = WidgetLayout.Metrics.self
        let inkPerPoint = m.miniTitleInkBottom - m.miniTitleInkTop
        var clear = 0, knockedOut = 0
        for h in measuredMiniHeights {
            let nowY = h * CGFloat(m.miniNowFraction)
            let lineTop = nowY - 0.5 - m.miniTitleClearance
            let lineBottom = nowY + 0.5 + m.miniTitleClearance
            for topStep in stride(from: CGFloat(-60), through: h + 10, by: 0.5) {
                for height in stride(from: CGFloat(1), through: 80, by: 0.5) {
                    guard let title = WidgetLayout.miniTitlePlacement(
                        rectTop: topStep, rectBottom: topStep + height, contentHeight: h,
                        nowY: nowY, topPad: 3
                    ) else { continue }
                    let band = ink(title)
                    let visibleTop = max(topStep, 0) + m.miniTitleInset
                    let visibleBottom = min(topStep + height, h) - m.miniTitleInset
                    let label = "h=\(h) top=\(topStep) height=\(height)"
                    XCTAssertGreaterThanOrEqual(band.lowerBound, visibleTop - 1e-9, label)
                    XCTAssertLessThanOrEqual(band.upperBound, visibleBottom + 1e-9, label)
                    XCTAssertGreaterThanOrEqual(title.size, m.miniTitleMinSize, label)
                    XCTAssertLessThanOrEqual(title.size, m.miniTitleSize, label)
                    if title.knocksOutNowLine {
                        knockedOut += 1
                        let smallest = inkPerPoint * m.miniTitleMinSize
                        XCTAssertLessThan(lineTop - visibleTop, smallest, "\(label): the title fits above the line")
                        XCTAssertLessThan(visibleBottom - lineBottom, smallest, "\(label): the title fits below the line")
                    } else {
                        clear += 1
                        XCTAssertTrue(band.upperBound <= lineTop + 1e-9 || band.lowerBound >= lineBottom - 1e-9,
                                      "\(label): the title's ink crosses the now line")
                    }
                }
            }
        }
        XCTAssertGreaterThan(clear, 10_000, "positive control: most of the space gets a title clear of the line")
        XCTAssertGreaterThan(knockedOut, 100, "positive control: the short running block gets one too")
    }

    /// Whatever interrupts are drawn over a block, its title's ink keeps
    /// `miniTitleClearance` off every one of them (gh#239 sim QA X5: the
    /// interrupt's own title was drawn on top of its parent's).
    func testATitleKeepsOutFromUnderTheInterruptsDrawnOverIt() {
        let m = WidgetLayout.Metrics.self
        var rng = SystemRandomNumberGenerator()
        var placed = 0
        for h in measuredMiniHeights {
            for _ in 0..<4000 {
                let top = CGFloat.random(in: -20...(h - 5), using: &rng)
                let bottom = top + CGFloat.random(in: 4...90, using: &rng)
                let covers = (0..<Int.random(in: 1...3, using: &rng)).map { _ -> WidgetLayout.MiniBand in
                    let coverTop = CGFloat.random(in: (top - 5)...(bottom + 5), using: &rng)
                    return WidgetLayout.MiniBand(top: coverTop, bottom: coverTop + CGFloat.random(in: 1...30, using: &rng))
                }
                guard let title = WidgetLayout.miniTitlePlacement(
                    rectTop: top, rectBottom: bottom, contentHeight: h, nowY: h * 0.4, topPad: 3, covers: covers
                ) else { continue }
                placed += 1
                let band = ink(title)
                for cover in covers {
                    XCTAssertTrue(band.upperBound <= cover.top - m.miniTitleClearance + 1e-9
                                    || band.lowerBound >= cover.bottom + m.miniTitleClearance - 1e-9,
                                  "h=\(h) rect \(top)...\(bottom): ink \(band) under \(cover)")
                }
            }
        }
        XCTAssertGreaterThan(placed, 2000, "positive control: covered blocks still get titles")
    }

    /// The X5 shape: an interrupt drawn 7pt under its parent's top. With
    /// nothing over it the parent keeps the usual look; with the interrupt
    /// there, its title goes under it.
    func testAParentsTitleGoesUnderAnInterruptThatCoversTheUsualPlace() {
        let h: CGFloat = 134.7
        let free = WidgetLayout.miniTitlePlacement(
            rectTop: 40, rectBottom: 100, contentHeight: h, nowY: 120, topPad: 3
        )
        XCTAssertEqual(free, WidgetLayout.MiniTitle(lineTop: 43, size: WidgetLayout.Metrics.miniTitleSize),
                       "positive control: uncovered, the usual look")
        let cover = WidgetLayout.MiniBand(top: 47.4, bottom: 60.6)
        let covered = WidgetLayout.miniTitlePlacement(
            rectTop: 40, rectBottom: 100, contentHeight: h, nowY: 120, topPad: 3, covers: [cover]
        )
        XCTAssertNotNil(covered)
        let gap = ink(covered!).lowerBound - cover.bottom
        XCTAssertGreaterThanOrEqual(gap, WidgetLayout.Metrics.miniTitleClearance - 1e-9)
        XCTAssertLessThan(gap, WidgetLayout.Metrics.miniTitleClearance + 3,
                          "under an interrupt the title sits right below it, without the top pad")
    }

    /// A tall block clear of the edges and the now line keeps the look it has
    /// always had: full size, `topPad` under its top.
    func testATallBlockKeepsTheUsualTitle() {
        let title = WidgetLayout.miniTitlePlacement(
            rectTop: 70, rectBottom: 110, contentHeight: 128.3, nowY: 128.3 * 0.4, topPad: 3
        )
        XCTAssertEqual(title, WidgetLayout.MiniTitle(lineTop: 73, size: WidgetLayout.Metrics.miniTitleSize))
    }

    /// The B5 shape on the Air: the line ~10pt under a running block's top
    /// leaves the sliver above it room only for a centred title pressed to the
    /// top stroke, and the usual look free below it. A tie on size goes to the
    /// less squeezed look; with the usual look free on both sides, to the upper.
    func testATieOnSizeGoesToTheUsualLookThenToTheUpperRegion() {
        let h: CGFloat = 134.7, nowY = h * 0.4
        let squeezed = WidgetLayout.miniTitlePlacement(
            rectTop: nowY - 10.2, rectBottom: nowY + 21.4, contentHeight: h, nowY: nowY, topPad: 3
        )
        XCTAssertEqual(squeezed?.size, WidgetLayout.Metrics.miniTitleSize)
        XCTAssertGreaterThan(squeezed!.lineTop, nowY, "the title must take the usual look below the line")
        XCTAssertEqual(squeezed?.knocksOutNowLine, false)
        let gap = ink(squeezed!).lowerBound - (nowY + 0.5)
        XCTAssertGreaterThanOrEqual(gap, WidgetLayout.Metrics.miniTitleClearance - 1e-9)
        XCTAssertLessThan(gap, WidgetLayout.Metrics.miniTitleClearance + 3,
                          "under the line the title sits right below it, without the top pad")

        let roomy = WidgetLayout.miniTitlePlacement(
            rectTop: nowY - 20, rectBottom: nowY + 21.4, contentHeight: h, nowY: nowY, topPad: 3
        )
        XCTAssertEqual(roomy, WidgetLayout.MiniTitle(lineTop: nowY - 20 + 3, size: WidgetLayout.Metrics.miniTitleSize),
                       "with room above, the title keeps its place at the top")
    }

    /// A block that has scrolled off the top took its title with it to the
    /// next block down (gh#239 sim QA B3/B4/X2): with nothing of it on screen
    /// there is nowhere for the title to be.
    func testABlockOffTheTopHasNoTitle() {
        for bottom in [CGFloat(-20), -1, 0, 3] {
            XCTAssertNil(WidgetLayout.miniTitlePlacement(
                rectTop: bottom - 40, rectBottom: bottom, contentHeight: 128.3, nowY: 51.3, topPad: 3
            ), "rect bottom \(bottom)")
        }
    }

    /// The lane's own arithmetic, as the view does it: `rectTop` for a block
    /// starting `minutesFromNow` away, at the box height `h`.
    private func laneRect(h: CGFloat, minutesFromNow: Double, minutes: Double) -> (top: CGFloat, bottom: CGFloat) {
        let pps = h / CGFloat(WidgetLayout.Metrics.miniVisibleHours * 3600)
        let blockTop = h * CGFloat(WidgetLayout.Metrics.miniNowFraction) + CGFloat(minutesFromNow * 60) * pps
        let span = CGFloat(minutes * 60) * pps
        let height = WidgetLayout.miniDrawnHeight(span: span, roomBelow: nil)
        return (blockTop + 1, blockTop + 1 + height)
    }

    /// A half-hour event is the common short block. It hung its title past its
    /// border on the 17-class boxes, and on the SE — whose room for it is a
    /// hair either side of 6.5pt — lost it to rounding at most positions
    /// (gh#239 sim QA B3/B4/B10). Wherever it sits whole in the lane, at every
    /// measured box and a hair under each, it gets a title.
    func testAHalfHourBlockGetsATitleWhereverItSits() {
        for measured in measuredMiniHeights {
            for h in [measured, measured - 1e-9, measured - 0.5] {
                for minutes in stride(from: -120.0, through: 200, by: 1) {
                    let rect = laneRect(h: h, minutesFromNow: minutes, minutes: 30)
                    guard rect.top >= 0, rect.bottom <= h else { continue }
                    XCTAssertNotNil(WidgetLayout.miniTitlePlacement(
                        rectTop: rect.top, rectBottom: rect.bottom, contentHeight: h, nowY: h * 0.4, topPad: 3
                    ), "h=\(h), \(minutes) min from now: a 30-minute block lost its title")
                }
            }
        }
    }

    /// The running block is the one a glance is for. Its title used to sit
    /// under the now line, drawn over it in the same colour; moved clear of
    /// the line, a half-hour block lost it for most of its run, because
    /// neither side of the line holds one (gh#239 static review). Every
    /// minute of a run, at every measured box, it has a title; from an hour
    /// up, always clear of the line.
    func testTheRunningBlockAlwaysHasATitle() {
        var knockedOut = 0
        for h in measuredMiniHeights {
            let nowY = h * 0.4
            for minutes in [30.0, 45, 60, 90] {
                for minutesIn in stride(from: 1.0, to: minutes, by: 1) {
                    let rect = laneRect(h: h, minutesFromNow: -minutesIn, minutes: minutes)
                    let title = WidgetLayout.miniTitlePlacement(
                        rectTop: rect.top, rectBottom: rect.bottom, contentHeight: h, nowY: nowY, topPad: 3
                    )
                    let label = "h=\(h), \(minutes)-min block \(minutesIn) min in"
                    XCTAssertNotNil(title, "\(label): no title")
                    if title?.knocksOutNowLine == true {
                        knockedOut += 1
                        XCTAssertLessThan(minutes, 60, "\(label): an hour has room clear of the line")
                    }
                }
            }
        }
        XCTAssertGreaterThan(knockedOut, 0, "positive control: the half-hour block does need the knockout")
    }

    /// A busy hour's ~27pt column gets the narrow padding; a title beside the
    /// now dot is pushed clear of its circle, by its full width when the ink
    /// spans the dot's centre row.
    func testTitlePads() {
        let m = WidgetLayout.Metrics.self
        let laneLeft: CGFloat = 36, nowY: CGFloat = 20
        let far = WidgetLayout.MiniTitle(lineTop: 100, size: m.miniTitleSize)
        let atLine = WidgetLayout.MiniTitle(lineTop: nowY - 4, size: m.miniTitleSize)
        func pads(_ width: CGFloat, x: CGFloat = 80, title: WidgetLayout.MiniTitle? = nil) -> WidgetLayout.MiniTitlePads {
            WidgetLayout.miniTitlePads(blockX: x, blockWidth: width, standard: 4, title: title ?? far,
                                       laneLeft: laneLeft, nowY: nowY)
        }
        let narrow = m.miniNarrowSidePad
        XCTAssertEqual(pads(80), .init(leading: 4, trailing: 4))
        XCTAssertEqual(pads(m.miniNarrowBlockWidth), .init(leading: 4, trailing: 4))
        XCTAssertEqual(pads(27), .init(leading: narrow, trailing: narrow))
        let offDot = m.miniNowDotRadius + m.miniTitleClearance
        XCTAssertEqual(pads(27, x: laneLeft, title: atLine), .init(leading: offDot, trailing: narrow),
                       "ink across the dot's centre row: clear of its full width")
        XCTAssertEqual(pads(27, x: laneLeft), .init(leading: narrow, trailing: narrow), "away from the dot, no push")
    }

    /// A title's text keeps `miniTitleClearance` off the now dot's circle,
    /// drawn over the blocks on the lane's left edge, wherever the title sits
    /// near it — and is pushed no further than that: a push as wide as the dot
    /// at every height dropped titles the circle leaves room for. Away from
    /// it the pads are even. Distances are taken point by point down the text
    /// box's leading edge, not with the function's own formula.
    func testATitleKeepsClearOfTheNowDotAndNoFurther() {
        let m = WidgetLayout.Metrics.self
        let laneLeft: CGFloat = 36, nowY: CGFloat = 51.32
        let r = m.miniNowDotRadius, clearance = m.miniTitleClearance
        func nearest(edgeX: CGFloat, ink: ClosedRange<CGFloat>) -> CGFloat {
            var ys = Array(stride(from: ink.lowerBound, through: ink.upperBound, by: 0.05)) + [ink.upperBound]
            if ink.contains(nowY) { ys.append(nowY) }
            return ys.map { y in ((edgeX - laneLeft) * (edgeX - laneLeft) + (y - nowY) * (y - nowY)).squareRoot() }.min()!
        }
        var pushed = 0, even = 0
        for size in [m.miniTitleMinSize, 7, m.miniTitleSize] {
            for lineTop in stride(from: nowY - 20, through: nowY + 10, by: 0.25) {
                let title = WidgetLayout.MiniTitle(lineTop: lineTop, size: size, knocksOutNowLine: true)
                let band = ink(title)
                for x in [laneLeft, laneLeft + 1, laneLeft + 2.5, laneLeft + 4, laneLeft + 30] {
                    for width in [CGFloat(20), 22.67, 29.5, 45, 90] {
                        for standard in [CGFloat(3), 4] {
                            let pads = WidgetLayout.miniTitlePads(
                                blockX: x, blockWidth: width, standard: standard, title: title,
                                laneLeft: laneLeft, nowY: nowY
                            )
                            let label = "size=\(size) lineTop=\(lineTop) x=\(x) width=\(width)"
                            let edge = x + pads.leading
                            XCTAssertGreaterThanOrEqual(nearest(edgeX: edge, ink: band), r + clearance - 1e-6,
                                                        "\(label): the text is within \(clearance)pt of the dot")
                            if pads.leading > pads.trailing {
                                pushed += 1
                                XCTAssertLessThan(nearest(edgeX: edge - 0.05, ink: band), r + clearance,
                                                  "\(label): pushed further than the dot needs")
                            } else {
                                XCTAssertEqual(pads.leading, pads.trailing, label)
                                even += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(pushed, 100, "positive control: titles beside the dot were pushed off it")
        XCTAssertGreaterThan(even, 1000, "positive control: titles away from it were not")
    }

    private func titleFont(_ size: CGFloat, bold: Bool = false) -> UIFont {
        .systemFont(ofSize: size, weight: bold ? .heavy : .semibold)
    }

    private func width(_ text: String, _ size: CGFloat, bold: Bool = false, kerning: CGFloat = 0) -> CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [.font: titleFont(size, bold: bold)]
        if kerning != 0 { attributes[.kern] = kerning }
        return (text as NSString).size(withAttributes: attributes).width
    }

    /// Titles in the scripts and shapes the widget sees: CJK, kana, Hangul,
    /// Latin, Cyrillic, Greek, Thai (with marks), Arabic, digits, symbols,
    /// emoji (ZWJ, flag, keycap), accented capitals, characters that kern
    /// against the "…", CJK into Latin and Latin into CJK, titles SwiftUI
    /// fitted whole only by tightening, titles led by spaces, an invisible
    /// direction mark, a BOM, a zero-width space or a lone combining mark, and
    /// titles holding line breaks or control characters.
    private let titleSamples = [
        "会议同步", "设计评审", "写周报", "ミーティング", "회의", "Weekly sync", "Write", "WWWW", "\"Quote\"",
        "Meeting", "Ж встреча", "Ω test", "ประชุม", "ที่ทำงาน", "กินข้าว", "اجتماع", "8am run", "1:1", "@home",
        "★ Star", "🏃 Run", "😀 Party", "👨‍👩‍👧 Family", "🇨🇳 China", "1️⃣ First", "Ångström", "7 min", "Y axis",
        "会议Q3", "评审PR", "跑步5km", "Q3规划", "1对1", "7号", "Dentist", "Commute", "Breakfast", "  缩进",
        "\u{200E}Weekly sync", "\u{FEFF}会议", "\u{200B}Write", "\u{0301}Write", "Meeting\nnotes", "会议\n3楼",
        "\nMeeting", "Gym\u{2028}A", "a\u{0}b", "Gym \u{200E}Arena", "Team \u{200F}اجتماع", "i", "会",
        "Quarterly planning review",
    ]

    /// A title is drawn on one line: its line breaks become spaces, and
    /// control characters are dropped. Measured with a break in it, a title
    /// was measured at its widest line and drawn as its first plus a "…".
    func testATitleIsDrawnAsOneLine() {
        for (title, line) in [("Meeting\nnotes", "Meeting notes"), ("\nMeeting", "Meeting"), ("会议\r\n3楼", "会议 3楼"),
                              ("Gym\u{2028}A", "Gym A"), ("a\u{0}b", "ab"), ("Lunch\tSam", "Lunch Sam"), ("  缩进", "  缩进"),
                              ("Weekly sync", "Weekly sync")] {
            XCTAssertEqual(WidgetLayout.miniTitleLine(title), line, title.debugDescription)
        }
    }

    /// What `miniTitleRun` gives is the most of the title that fits, on one
    /// line: the whole title at the placed size; or shrunk no further than it
    /// must and no further than the floor; or at the floor, tightened by the
    /// one step; or at the floor the longest run of its first characters with
    /// a "…", tightened only if it must — and it fits. It is never a bare "…":
    /// a cut holds a visible character and no space before its "…", or there
    /// is no title. Swept over widths, sizes and both weights.
    func testATitleRunIsTheMostOfTheTitleThatFits() {
        let blank: Set<Unicode.GeneralCategory> = [.spaceSeparator, .control, .format, .nonspacingMark, .enclosingMark]
        func visible(_ text: String) -> Bool { text.unicodeScalars.contains { !blank.contains($0.properties.generalCategory) } }
        var whole = 0, shrunk = 0, tightened = 0, cut = 0, none = 0
        for bold in [false, true] {
            for size in [WidgetLayout.Metrics.miniTitleSize, 7, 6.8, WidgetLayout.Metrics.miniTitleMinSize] {
                let floor = size * WidgetLayout.miniTitleMinimumScale(size: size)
                let tight = WidgetLayout.Metrics.miniTitleTightening * floor
                for title in titleSamples {
                    let line = WidgetLayout.miniTitleLine(title)
                    for box in stride(from: CGFloat(3), through: 70, by: 0.75) {
                        let label = "\(title.debugDescription) size=\(size) box=\(box) bold=\(bold)"
                        guard let run = WidgetLayout.miniTitleRun(title, width: box, size: size, bold: bold) else {
                            none += 1
                            let first = line.firstIndex { visible(String($0)) }.map { String(line[...$0]) } ?? line
                            XCTAssertGreaterThan(width(first + "…", floor, bold: bold, kerning: tight), box - 1e-9,
                                                 "\(label): nil, but a cut fits")
                            continue
                        }
                        XCTAssertLessThanOrEqual(width(run.text, run.size, bold: bold, kerning: run.kerning), box + 1e-9,
                                                 "\(label): \(run) does not fit")
                        XCTAssertTrue(run.kerning == 0 || abs(run.kerning - tight) < 1e-9, "\(label): kerning \(run.kerning)")
                        XCTAssertFalse(run.text.contains { $0.isNewline }, label)
                        XCTAssertGreaterThanOrEqual(run.size, floor - 1e-9, label)
                        XCTAssertLessThanOrEqual(run.size, size + 1e-9, label)
                        XCTAssertNotEqual(run.text.trimmingCharacters(in: .whitespaces), "…", "\(label): a bare …")
                        if run.kerning != 0 {
                            XCTAssertEqual(run.size, floor, accuracy: 1e-9, "\(label): tightened before shrinking to the floor")
                            XCTAssertGreaterThan(width(run.text, floor, bold: bold), box, "\(label): tightened though it fits as it is")
                        }
                        if run.text == line {
                            if run.kerning != 0 { tightened += 1 }
                            else if run.size < size {
                                shrunk += 1
                                XCTAssertGreaterThan(width(line, run.size + 0.02, bold: bold), box, "\(label): shrunk more than it must")
                            } else { whole += 1 }
                        } else {
                            cut += 1
                            XCTAssertEqual(run.size, floor, accuracy: 1e-9, "\(label): cut before shrinking to the floor")
                            XCTAssertGreaterThan(width(line, floor, bold: bold, kerning: tight), box,
                                                 "\(label): cut though it fits whole, tightened")
                            XCTAssertTrue(run.text.hasSuffix("…"), label)
                            let head = String(run.text.dropLast())
                            let last = head.last.map { $0.isWhitespace || !visible(String($0)) } ?? true
                            XCTAssertFalse(last, "\(label): a space or nothing visible before the …")
                            XCTAssertTrue(line.hasPrefix(head), "\(label): \(run.text) is not the title's start")
                            XCTAssertTrue(visible(head), "\(label): \(run.text) shows nothing but …")
                            let rest = line.dropFirst(head.count).drop { $0.isWhitespace || !visible(String($0)) }
                            if !rest.isEmpty {
                                let longer = String(line.prefix(line.count - rest.count + 1))
                                XCTAssertGreaterThan(width(longer + "…", floor, bold: bold, kerning: tight), box,
                                                     "\(label): \(longer)… fits too, past \(run.text)")
                            }
                        }
                    }
                }
            }
        }
        for (count, name) in [(whole, "whole"), (shrunk, "shrunk"), (cut, "cut"), (none, "none")] {
            XCTAssertGreaterThan(count, 50, "positive control: the sweep reaches the \(name) case")
        }
        XCTAssertGreaterThan(tightened, 20, "positive control: the sweep reaches the tightened case")
        let control = WidgetLayout.miniTitleRun("设计评审", width: 27, size: WidgetLayout.Metrics.miniTitleSize)
        XCTAssertEqual(control?.text, "设计评审", "the SE two-column box SwiftUI fitted whole by tightening (sim QA Y3)")
    }

    /// SwiftUI draws a tightened run at the width it was measured at — to a
    /// twentieth of a point, rendered at 20x — so the tightening it was
    /// measured with is the tightening drawn. At 2x or 3x a pixel is wider
    /// than a short title's whole tightening, and could not show it.
    @MainActor
    func testSwiftUIDrawsATightenedRunAtItsMeasuredWidth() throws {
        let m = WidgetLayout.Metrics.self
        var checked = 0
        for bold in [false, true] {
            for title in titleSamples {
                for box in stride(from: CGFloat(8), through: 60, by: 1.5) {
                    guard let run = WidgetLayout.miniTitleRun(title, width: box, size: m.miniTitleSize, bold: bold),
                          run.kerning != 0 else { continue }
                    let drawn = try XCTUnwrap(render(run.text, size: run.size, scale: 20, bold: bold, kerning: run.kerning))
                    let measured = width(run.text, run.size, bold: bold, kerning: run.kerning)
                    XCTAssertEqual(drawn.width, measured, accuracy: 0.1, "\(run.text.debugDescription) bold \(bold)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 20, "positive control: tightened runs were drawn")
        let loose = try XCTUnwrap(render("设计评审", size: 6.8, scale: 20))
        let tight = try XCTUnwrap(render("设计评审", size: 6.8, scale: 20, kerning: m.miniTitleTightening * 6.8))
        XCTAssertGreaterThan(loose.width - tight.width, 0.4, "positive control: the tightening is drawn")
    }

    /// A title placed at one size and drawn smaller starts its ink where the
    /// placement's does, and so stays inside the placed ink band.
    func testATitleDrawnSmallerKeepsInsideItsPlacedInk() {
        let m = WidgetLayout.Metrics.self
        let title = WidgetLayout.MiniTitle(lineTop: 40, size: 8)
        for drawn in stride(from: 6.8, through: 8, by: 0.05) {
            let top = WidgetLayout.miniTitleRunTop(title, run: .init(text: "x", size: drawn))
            XCTAssertEqual(top + m.miniTitleInkTop * drawn, ink(title).lowerBound, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(top + m.miniTitleInkBottom * drawn, ink(title).upperBound + 1e-9)
        }
    }

    /// How SwiftUI draws `text` the way the widget draws a title run (pinned
    /// to the view by `WidgetViewSourcePinTests`), with Bold Text on or off:
    /// its laid-out width, and whether it is a bare "…" — three dots and
    /// nothing else. `fitting` instead draws it the old way, left to
    /// SwiftUI's own fitting in a box that wide.
    @MainActor
    private func render(
        _ text: String, size: CGFloat, scale: CGFloat, bold: Bool = false, kerning: CGFloat = 0, fitting: CGFloat? = nil
    ) -> (width: CGFloat, bare: Bool)? {
        let plain = Text(text).font(.system(size: size, weight: .semibold))
        let title = (kerning == 0 ? plain : plain.kerning(kerning)).lineLimit(1)
        let view: AnyView = fitting.map { box in
            AnyView(title.minimumScaleFactor(WidgetLayout.miniTitleMinimumScale(size: size)).allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true).frame(width: box, alignment: .leading))
        } ?? AnyView(title.fixedSize())
        let renderer = ImageRenderer(content: view.environment(\.legibilityWeight, bold ? .bold : .regular))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let inked = (0..<w).map { x in (0..<h).contains { y in pixels[(y * w + x) * 4 + 3] > 64 } }
        var runs = 0
        for x in 0..<w where inked[x] && (x == 0 || !inked[x - 1]) { runs += 1 }
        guard let first = inked.firstIndex(of: true), let last = inked.lastIndex(of: true) else {
            return (CGFloat(w) / scale, false)
        }
        return (CGFloat(w) / scale, runs == 3 && CGFloat(last - first + 1) / scale < 6)
    }

    /// SwiftUI draws a title run whole, at the width it was measured to fit —
    /// within a pixel — at 2x and 3x, with Bold Text on and off; so a run is
    /// never re-cut into a bare "…". Left to SwiftUI's own fitting, the same
    /// box drew a bare "…" for a CJK title running into Latin (the control).
    @MainActor
    func testSwiftUIDrawsATitleRunWholeInItsBox() throws {
        let m = WidgetLayout.Metrics.self
        for scale in [CGFloat(2), 3] {
            for bold in [false, true] {
                for size in [m.miniTitleSize, 7, m.miniTitleMinSize] {
                    for title in titleSamples {
                        for box in [CGFloat(8), 10.5, 12, 13.5, 15, 16.5, 18, 21, 26, 40] {
                            guard let run = WidgetLayout.miniTitleRun(title, width: box, size: size, bold: bold) else { continue }
                            let drawn = try XCTUnwrap(render(run.text, size: run.size, scale: scale, bold: bold,
                                                             kerning: run.kerning))
                            let label = "\(run.text.debugDescription) at \(run.size)pt, \(scale)x, bold \(bold), box \(box)"
                            XCTAssertLessThanOrEqual(drawn.width, box + 1 / scale + 1e-9, "\(label): wider than its box")
                            XCTAssertFalse(drawn.bare, "\(label): a bare …")
                        }
                    }
                }
            }
        }
        let regular = try XCTUnwrap(render("Meeting", size: m.miniTitleSize, scale: 3))
        let heavier = try XCTUnwrap(render("Meeting", size: m.miniTitleSize, scale: 3, bold: true))
        XCTAssertGreaterThan(heavier.width, regular.width + 1, "positive control: the renders do apply Bold Text")
        let tight = m.miniTitleTightening * 6.8
        let regularTight = try XCTUnwrap(render("Meeting", size: 6.8, scale: 3, kerning: tight))
        let heavierTight = try XCTUnwrap(render("Meeting", size: 6.8, scale: 3, bold: true, kerning: tight))
        XCTAssertGreaterThan(heavierTight.width, regularTight.width + 1, "a tightened title keeps Bold Text")
        let control = try XCTUnwrap(render("会议Q3", size: m.miniTitleSize, scale: 3, fitting: 16))
        XCTAssertTrue(control.bare, "positive control: SwiftUI's own fitting drew 会议Q3 as a bare … in 16pt")
        let run = try XCTUnwrap(WidgetLayout.miniTitleRun("会议Q3", width: 16, size: m.miniTitleSize))
        XCTAssertFalse(try XCTUnwrap(render(run.text, size: run.size, scale: 3)).bare, "the run draws 会…")
    }

    /// The ink band covers the measured ink of the titles the widget draws:
    /// CJK tops, Latin descenders, the two mixed. Accented capitals and emoji
    /// reach past it, and are accepted: covering them costs ~1.5pt of every
    /// block's room. The line box is the font's, with the CJK fallback.
    func testTheInkBandBoundsTheMeasuredGlyphs() {
        let m = WidgetLayout.Metrics.self
        let size = m.miniTitleSize
        let font = titleFont(size)
        var deepest: CGFloat = 0, highest: CGFloat = .infinity
        for sample in ["规划", "设计评审", "yoga 瑜伽", "Hxg", "Design 1:1", "Quarterly planning", "gjpqy"] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [.font: font]))
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let inkTop = (font.ascender - glyphs.maxY) / size
            let inkBottom = (font.ascender - glyphs.minY) / size
            highest = min(highest, inkTop)
            deepest = max(deepest, inkBottom)
            XCTAssertGreaterThanOrEqual(inkTop, m.miniTitleInkTop, "\(sample): ink top at \(inkTop)")
            XCTAssertLessThanOrEqual(inkBottom, m.miniTitleInkBottom, "\(sample): ink bottom at \(inkBottom)")
        }
        XCTAssertLessThan(m.miniTitleInkTop, highest + 0.05, "the band's top hugs the highest ink (\(highest))")
        XCTAssertGreaterThan(m.miniTitleInkBottom, deepest - 0.05, "the band's bottom hugs the deepest (\(deepest))")
        XCTAssertLessThanOrEqual(m.miniTitleInkBottom, font.lineHeight / size + 1e-9, "the band sits in the line box")
    }

    /// The horizontal floor never takes a title under the smallest size the
    /// block's height allows, and an 8pt title keeps its 0.85.
    func testATitleShrinksForWidthNoFurtherThanTheFloor() {
        let m = WidgetLayout.Metrics.self
        XCTAssertEqual(WidgetLayout.miniTitleMinimumScale(size: m.miniTitleSize), m.miniTitleMinScale, accuracy: 1e-12)
        for size in stride(from: m.miniTitleMinSize, through: m.miniTitleSize, by: 0.05) {
            let scale = WidgetLayout.miniTitleMinimumScale(size: size)
            XCTAssertLessThanOrEqual(scale, 1)
            XCTAssertGreaterThanOrEqual(size * scale, min(size, m.miniTitleSize * m.miniTitleMinScale) - 1e-9, "size=\(size)")
            XCTAssertGreaterThanOrEqual(size * scale, m.miniTitleMinSize - 1e-9, "size=\(size)")
        }
    }

    /// Hour labels are drawn whole or not at all: a marker near either edge
    /// drew a label the view's clip cut through the digits.
    func testHourLabelsAreWholeInsideTheBox() {
        let rise = WidgetLayout.axisLabelRise
        let line = WidgetLayout.axisLabelLineHeight
        for h in measuredMiniHeights {
            for y in stride(from: CGFloat(-10), through: h + 10, by: 0.25) {
                guard WidgetLayout.hourLabelInsideBox(markerY: y, contentHeight: h) else { continue }
                XCTAssertGreaterThanOrEqual(y - rise, 0, "h=\(h) y=\(y)")
                XCTAssertLessThanOrEqual(y - rise + line, h, "h=\(h) y=\(y)")
            }
            XCTAssertTrue(WidgetLayout.hourLabelInsideBox(markerY: rise, contentHeight: h), "top edge, exactly")
            XCTAssertFalse(WidgetLayout.hourLabelInsideBox(markerY: rise - 0.25, contentHeight: h))
            XCTAssertTrue(WidgetLayout.hourLabelInsideBox(markerY: h - line + rise, contentHeight: h), "bottom edge")
            XCTAssertFalse(WidgetLayout.hourLabelInsideBox(markerY: h - line + rise + 0.25, contentHeight: h))
        }
    }

    /// The window is six hours with now at 40%, and an occurrence shows in it
    /// when it overlaps it, half-open at both ends.
    func testMiniWindow() {
        let window = WidgetLayout.miniWindow(now: t(15))
        XCTAssertEqual(window.start, t(12, 36))
        XCTAssertEqual(window.end, t(18, 36))
        XCTAssertFalse(WidgetLayout.miniWindowShows(snap("a", t(11), t(12, 36)), in: window))
        XCTAssertTrue(WidgetLayout.miniWindowShows(snap("b", t(11), t(12, 37)), in: window))
        XCTAssertFalse(WidgetLayout.miniWindowShows(snap("c", t(18, 36), t(19)), in: window))
    }

    /// An event that ended above the window claimed a column and squeezed the
    /// visible one into half the lane (gh#245 1).
    func testAnEventOutsideTheWindowDoesNotSqueezeTheVisibleOne() {
        let window = WidgetLayout.miniWindow(now: t(15))     // 12:36–18:36
        let gone = snap("gone", t(10), t(12))
        let visible = snap("visible", t(11, 30), t(14))
        XCTAssertLessThan(WidgetLayout.miniTimelineSlots(for: [gone, visible])[1].width, 1,
                          "positive control: packed whole, the two share the lane")
        XCTAssertEqual(WidgetLayout.miniTimelineSlots(for: [gone, visible], window: window)[1].width, 1)
        // Two visible blocks that overlap still share it.
        let other = snap("other", t(13), t(14, 30))
        let both = WidgetLayout.miniTimelineSlots(for: [gone, visible, other], window: window)
        XCTAssertEqual(both[1].width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(both[2].width, 0.5, accuracy: 1e-9)
    }

    /// An interrupt that runs past its parent's end is drawn at its own time
    /// in its parent's column, so the block after the parent must not get that
    /// column (gh#239 sim QA X5).
    func testAnInterruptOverrunningItsParentKeepsTheNextBlockOutOfItsColumn() {
        let parentID = UUID()
        let parent = snap("parent", t(10), t(11), id: parentID)
        let interrupt = snap("interrupt", t(10, 30), t(11, 30), interrupt: true, parent: parentID)
        let next = snap("next", t(11), t(12))
        let slots = WidgetLayout.miniTimelineSlots(for: [parent, interrupt, next])
        XCTAssertTrue(slots[1].isOverlay)
        let i = slots[1], n = slots[2]
        XCTAssertFalse(i.x < n.x + n.width && n.x < i.x + i.width,
                       "the overrunning interrupt and the block after its parent share lane width")
    }

    /// A short block's floor height stops short of the block after it in its
    /// column (gh#245 2), and a lone short block keeps the floor.
    func testAShortBlocksFloorStopsShortOfTheNextBlock() {
        let events = [snap("a", t(14), t(14, 5)), snap("b", t(14, 5), t(14, 10)), snap("c", t(14, 10), t(15))]
        let window = WidgetLayout.miniWindow(now: t(14))
        let slots = WidgetLayout.miniTimelineSlots(for: events, window: window)
        let next = WidgetLayout.miniNextStarts(for: events, slots: slots, window: window)
        XCTAssertEqual(next, [t(14, 5), t(14, 10), nil])
        for h in measuredMiniHeights {
            let pps = h / CGFloat(window.duration)
            let y = { (d: Date) in CGFloat(d.timeIntervalSince(window.start)) * pps }
            for i in 0..<2 {
                let span = CGFloat(events[i].endDate.timeIntervalSince(events[i].startDate)) * pps
                let drawn = WidgetLayout.miniDrawnHeight(span: span, roomBelow: y(next[i]!) - y(events[i].startDate))
                XCTAssertLessThan(y(events[i].startDate) + 1 + drawn, y(events[i + 1].startDate) + 1,
                                  "h=\(h): block \(i) is drawn into the next")
            }
            let lone = WidgetLayout.miniDrawnHeight(span: 5 * 60 * pps, roomBelow: nil)
            XCTAssertEqual(lone, WidgetLayout.Metrics.miniMinBlockHeight, "positive control: the floor still holds")
        }
    }

    /// The next block is the earliest one starting after a block's end that
    /// shares any of its width: a block in the other column does not count,
    /// a later full-width one does, and so does one that expanded into it.
    func testTheNextStartIsTheEarliestOneInTheBlocksOwnWidth() {
        let window = WidgetLayout.miniWindow(now: t(14))
        let events = [
            snap("long", t(14), t(14, 30)),        // column 0
            snap("short", t(14), t(14, 5)),        // column 1
            snap("after", t(15), t(15, 30)),       // full width, its own cluster
            snap("right", t(14, 40), t(15)),       // column 1
            snap("left", t(14, 30), t(15)),        // column 0
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events, window: window)
        XCTAssertEqual(slots.map(\.x), [0, 0.5, 0, 0.5, 0], "precondition: the columns")
        XCTAssertEqual(slots.map(\.width), [0.5, 0.5, 1, 0.5, 0.5], "precondition: the widths")
        XCTAssertEqual(WidgetLayout.miniNextStarts(for: events, slots: slots, window: window),
                       [t(14, 30), t(14, 40), nil, t(15), t(15)])

        let expanded = [
            snap("a", t(14), t(15)), snap("b", t(14), t(14, 30)), snap("c", t(14), t(14, 10)),
            snap("d", t(14, 10), t(14, 20)), snap("e", t(14, 30), t(14, 50)),
        ]
        let expandedSlots = WidgetLayout.miniTimelineSlots(for: expanded, window: window)
        XCTAssertEqual(expandedSlots[4].width, 2.0 / 3, accuracy: 1e-9, "precondition: e expands over d's column")
        XCTAssertEqual(WidgetLayout.miniNextStarts(for: expanded, slots: expandedSlots, window: window)[3], t(14, 30))
    }

    /// A drawn block never reaches past the next block's top, however short
    /// it is, and keeps a point clear of it when it has one to spare. With
    /// room to spare it is drawn 2pt short of its span: the gap between
    /// back-to-back blocks.
    func testADrawnBlockNeverReachesTheNextOne() {
        XCTAssertEqual(WidgetLayout.miniDrawnHeight(span: 20, roomBelow: nil), 18)
        XCTAssertEqual(WidgetLayout.miniDrawnHeight(span: 20, roomBelow: 20), 18, "back to back: a 2pt gap")
        for span in stride(from: CGFloat(0), through: 30, by: 0.1) {
            for room in stride(from: CGFloat(0), through: 30, by: 0.1) where room >= span {
                let drawn = WidgetLayout.miniDrawnHeight(span: span, roomBelow: room)
                XCTAssertLessThanOrEqual(drawn, room + 1e-9, "span=\(span) room=\(room)")
                if room >= 2 { XCTAssertLessThanOrEqual(drawn, room - 1 + 1e-9, "span=\(span) room=\(room)") }
                XCTAssertGreaterThanOrEqual(drawn, min(1, room) - 1e-9, "span=\(span) room=\(room): vanished")
            }
        }
    }

    /// A zero-length event inside the window is drawn, so it is packed beside
    /// what it sits in, windowed or not (gh#239 static review).
    func testAZeroLengthEventIsPackedInsideTheWindow() {
        let window = WidgetLayout.miniWindow(now: t(15))
        let events = [snap("a", t(14), t(15)), snap("z", t(14, 30), t(14, 30))]
        let whole = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertEqual(whole[0].width, 0.5, accuracy: 1e-9, "positive control: packed whole, the two split")
        XCTAssertEqual(WidgetLayout.miniTimelineSlots(for: events, window: window), whole)
        let outside = [snap("a", t(14), t(15)), snap("z", t(12), t(12))]
        XCTAssertEqual(WidgetLayout.miniTimelineSlots(for: outside, window: window)[0], .full,
                       "one before the window is not packed")
    }

    /// A zero-length event takes up its instant: at the moment another block
    /// starts it is packed beside it, and drawn at the floor height. Packed as
    /// nothing, the block starting with it expanded over its column and it
    /// was drawn 0pt tall underneath (gh#239 static review).
    func testAZeroLengthEventAtAnotherBlocksStartKeepsItsOwnColumn() {
        let window = WidgetLayout.miniWindow(now: t(15))
        let days: [[SharedEventSnapshot]] = [
            [snap("b", t(14, 30), t(15)), snap("z", t(14, 30), t(14, 30))],
            [snap("z1", t(14, 30), t(14, 30)), snap("z2", t(14, 30), t(14, 30))],
            [snap("a", t(14), t(15)), snap("c", t(14, 30), t(14, 45)), snap("z", t(14, 30), t(14, 30))],
        ]
        for events in days {
            let slots = WidgetLayout.miniTimelineSlots(for: events, window: window)
            let next = WidgetLayout.miniNextStarts(for: events, slots: slots, window: window)
            let label = events.map(\.title).joined(separator: "+")
            for z in events.indices where events[z].endDate == events[z].startDate {
                for other in events.indices where other != z
                    && events[other].startDate <= events[z].startDate && events[z].startDate < max(events[other].endDate, events[other].startDate + 1) {
                    let a = slots[z], b = slots[other]
                    XCTAssertFalse(a.x < b.x + b.width - 1e-9 && b.x < a.x + a.width - 1e-9,
                                   "\(label): \(events[z].title) shares lane width with \(events[other].title)")
                }
                for h in measuredMiniHeights {
                    let pps = h / CGFloat(window.duration)
                    let room = next[z].map { CGFloat($0.timeIntervalSince(events[z].startDate)) * pps }
                    XCTAssertEqual(WidgetLayout.miniDrawnHeight(span: 0, roomBelow: room), WidgetLayout.Metrics.miniMinBlockHeight,
                                   "\(label) h=\(h): \(events[z].title) is not drawn at the floor")
                }
            }
        }
    }

    /// The same for a zero-length interrupt, which is not packed but drawn in
    /// its parent's slot: its parent starting at its instant is not the next
    /// block under it. And in a cluster of five columns, where slot fractions
    /// do not add up exactly (gh#239 static review).
    func testAZeroLengthOverlayOrFifthColumnBlockIsDrawnAtTheFloor() {
        let window = WidgetLayout.miniWindow(now: t(15))
        let parentID = UUID()
        let days: [[SharedEventSnapshot]] = [
            [snap("P", t(14, 30), t(15, 30), id: parentID), snap("Iz", t(14, 30), t(14, 30), interrupt: true, parent: parentID)],
            [snap("P", t(14, 30), t(15, 30), id: parentID), snap("S", t(14, 30), t(15), interrupt: true, parent: parentID),
             snap("Iz", t(14, 30), t(14, 30), interrupt: true, parent: parentID)],
            [snap("A", t(14), t(15)), snap("B", t(14, 10), t(15)), snap("b", t(14, 30), t(15)),
             snap("z", t(14, 30), t(14, 30)), snap("F", t(14, 30), t(14, 30))],
        ]
        for events in days {
            let slots = WidgetLayout.miniTimelineSlots(for: events, window: window)
            let next = WidgetLayout.miniNextStarts(for: events, slots: slots, window: window)
            for z in events.indices where events[z].endDate == events[z].startDate {
                XCTAssertNil(next[z], "\(events.map(\.title)): \(events[z].title) has a block under it at its own instant")
                XCTAssertEqual(WidgetLayout.miniDrawnHeight(span: 0, roomBelow: nil), WidgetLayout.Metrics.miniMinBlockHeight)
            }
        }
    }

    /// A zero-length interrupt floored over a sibling with time that reaches
    /// into it and shows no more than `miniVisibleSliver` past it hid that
    /// sibling (gh#239 sim QA Y6), so it is left out, whichever is drawn
    /// first — the sibling as tall as it, a fraction taller, starting seconds
    /// before it, or cut short inside it. Over a sibling that shows past it,
    /// or one that ends where it starts (a short call, then a note logged as
    /// it ends), it is a chip and stays; nothing else is left out.
    func testAZeroLengthInterruptOverItsSiblingIsLeftOut() {
        let sliver = WidgetLayout.Metrics.miniVisibleSliver
        let parentID = UUID(), otherID = UUID()
        let p = snap("P", t(14), t(15, 30), id: parentID)
        func interrupt(_ title: String, _ start: Date, _ end: Date, parent: UUID? = nil) -> SharedEventSnapshot {
            snap(title, start, end, interrupt: true, parent: parent ?? parentID)
        }
        func band(_ top: CGFloat, _ height: CGFloat) -> WidgetLayout.MiniBand { .init(top: top, bottom: top + height) }
        let s = interrupt("S", t(14, 30), t(14, 45)), z = interrupt("Z", t(14, 30), t(14, 30))
        for events in [[p, s, z], [p, z, s]] {
            let parents = WidgetLayout.miniOverlayParents(for: events)
            let zi = events.firstIndex { $0.title == "Z" }!, si = events.firstIndex { $0.title == "S" }!
            func leftOut(s sRect: WidgetLayout.MiniBand?) -> [Int] {
                var rects: [WidgetLayout.MiniBand?] = [band(10, 30), nil, nil]
                rects[si] = sRect
                rects[zi] = band(20, 4)
                return WidgetLayout.miniCoincidingOverlays(for: events, parents: parents, rects: rects)
            }
            let order = events.map(\.title)
            XCTAssertEqual(leftOut(s: band(20, 4)), [zi], "\(order): as tall")
            XCTAssertEqual(leftOut(s: band(20, 4 + sliver)), [zi], "\(order): a sliver taller")
            XCTAssertEqual(leftOut(s: band(20 - sliver, 4 + sliver)), [zi], "\(order): starting a sliver before")
            XCTAssertEqual(leftOut(s: band(20, 4 + sliver + 0.25)), [], "\(order): showing past it, a chip")
            XCTAssertEqual(leftOut(s: band(20 - sliver - 0.25, 4)), [], "\(order): starting well before, a chip")
            XCTAssertEqual(leftOut(s: band(20 - 0.95, 5.6)), [zi], "\(order): a sliver before and a sliver past")
            XCTAssertEqual(leftOut(s: band(20, 2.5)), [zi], "\(order): cut short inside it")
            XCTAssertEqual(leftOut(s: band(20 - 0.633, 0.633)), [], "\(order): ending where it starts, a chip")
            XCTAssertEqual(leftOut(s: nil), [], "\(order): S not shown")
        }
        let q = snap("Q", t(14), t(15, 30), id: otherID)
        let others: [([SharedEventSnapshot], [WidgetLayout.MiniBand?], String)] = [
            ([p, s, interrupt("S2", t(14, 30), t(15))], [band(10, 30), band(20, 4), band(20, 4)], "two timed siblings"),
            ([p, z, interrupt("Z2", t(14, 30), t(14, 30))], [band(10, 30), band(20, 4), band(20, 4)], "two zero-length siblings"),
            ([p, q, z, interrupt("S'", t(14, 30), t(14, 45), parent: otherID)],
             [band(10, 30), band(10, 30), band(20, 4), band(20, 4)], "a timed interrupt of another parent"),
            ([snap("P", t(14, 30), t(14, 45), id: parentID), z], [band(20, 4), band(20, 4)], "its own short parent"),
        ]
        for (events, rects, label) in others {
            let parents = WidgetLayout.miniOverlayParents(for: events)
            XCTAssertEqual(WidgetLayout.miniCoincidingOverlays(for: events, parents: parents, rects: rects), [], label)
        }
    }

    /// Two columns side by side do not share width because their slot
    /// fractions add up a hair over: 0.4 + 0.2 > 0.6 made a fifth-column
    /// block's neighbour its next block (gh#239 static review).
    func testAdjacentColumnsDoNotShareWidthByRounding() {
        let window = WidgetLayout.miniWindow(now: t(15))
        let events = [
            snap("A", t(14), t(15)), snap("B", t(14), t(15)), snap("C", t(14), t(14, 5)), snap("D", t(14), t(14, 4)),
            snap("E", t(14), t(14, 3)), snap("G", t(14, 5), t(14, 50)), snap("D2", t(14, 10), t(14, 50)),
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events, window: window)
        XCTAssertEqual(slots[3].x, 0.6, accuracy: 1e-12, "precondition: D in the fourth column")
        XCTAssertEqual(slots[5].x + slots[5].width, 0.6, accuracy: 1e-12, "precondition: G ends where D begins")
        XCTAssertGreaterThan(slots[5].x + slots[5].width, slots[3].x, "precondition: by a hair")
        XCTAssertEqual(WidgetLayout.miniNextStarts(for: events, slots: slots, window: window)[3], t(14, 10))
    }

    /// The same from the other side: an interrupt whose column ends a hair
    /// past the next column's start is not cut by that column's block.
    func testAColumnEndingAHairPastTheNextDoesNotShareItsWidth() {
        let window = WidgetLayout.miniWindow(now: t(15))
        let gID = UUID()
        let events = [
            snap("A", t(14), t(15)), snap("B", t(14), t(15)), snap("C", t(14), t(14, 5)), snap("D", t(14), t(14, 4)),
            snap("E", t(14), t(14, 3)), snap("G", t(14, 5), t(14, 50), id: gID), snap("D2", t(14, 10), t(14, 20)),
            snap("M", t(14, 20), t(14, 30)), snap("I", t(14, 10), t(14, 15), interrupt: true, parent: gID),
        ]
        let slots = WidgetLayout.miniTimelineSlots(for: events, window: window)
        XCTAssertTrue(slots[8].isOverlay, "precondition: I is drawn in G's column")
        XCTAssertGreaterThan(slots[8].x + slots[8].width, slots[7].x, "precondition: I's column ends a hair past M's start")
        XCTAssertEqual(slots[8].x + slots[8].width, slots[7].x, accuracy: 1e-12, "precondition: by a hair")
        XCTAssertNil(WidgetLayout.miniNextStarts(for: events, slots: slots, window: window)[8])
    }

    /// The view draws a title only where its text fits, and the now dot
    /// narrows the text beside it, so the best place can be one it cannot
    /// draw. Then the next place in the same order is used, a place clear of
    /// the now line before any knockout, and every place tried keeps the ink
    /// rules (gh#239 static review).
    func testATitleGoesToTheBestPlaceItCanBeDrawnAt() {
        let m = WidgetLayout.Metrics.self
        let h: CGFloat = 134.7, nowY = h * 0.4
        let top = nowY - 10.2, bottom = nowY + 21.4
        let best = WidgetLayout.miniTitlePlacement(rectTop: top, rectBottom: bottom, contentHeight: h, nowY: nowY, topPad: 3)
        var tried: [WidgetLayout.MiniTitle] = []
        let next = WidgetLayout.miniTitlePlacement(
            rectTop: top, rectBottom: bottom, contentHeight: h, nowY: nowY, topPad: 3
        ) { title -> Bool? in
            tried.append(title)
            return title == best ? nil : true
        }
        XCTAssertEqual(tried.first, best, "the best place is tried first")
        XCTAssertNotNil(next)
        XCTAssertNotEqual(next?.title, best)
        XCTAssertEqual(next?.title.knocksOutNowLine, false, "a place clear of the line comes before a knockout")
        let knocked = WidgetLayout.miniTitlePlacement(
            rectTop: top, rectBottom: bottom, contentHeight: h, nowY: nowY, topPad: 3
        ) { title -> Bool? in
            tried.append(title)
            return title.knocksOutNowLine ? true : nil
        }
        XCTAssertEqual(knocked?.title.knocksOutNowLine, true, "the knockout once no clear place can be drawn")
        XCTAssertNil(WidgetLayout.miniTitlePlacement(
            rectTop: top, rectBottom: bottom, contentHeight: h, nowY: nowY, topPad: 3
        ) { _ -> Bool? in nil })
        for title in tried {
            let band = ink(title)
            XCTAssertGreaterThanOrEqual(band.lowerBound, top + m.miniTitleInset - 1e-9, "\(title)")
            XCTAssertLessThanOrEqual(band.upperBound, bottom - m.miniTitleInset + 1e-9, "\(title)")
            if !title.knocksOutNowLine {
                XCTAssertTrue(band.upperBound <= nowY - 0.5 - m.miniTitleClearance + 1e-9
                                || band.lowerBound >= nowY + 0.5 + m.miniTitleClearance - 1e-9, "\(title) crosses the line")
            }
        }
    }

    /// A running title in a narrow first column, pushed off the now dot in
    /// the usual and the centred look, is drawn at the far end of its region
    /// where the dot leaves its text room (gh#239 static review: the Air's
    /// 4-column "🏃 Run", the SE's 4-column "Meeting", the Air's 5-column
    /// "会议同步"). Composed as the view composes it, over every quarter
    /// minute of the run: where a title is drawn, it fits; and it is drawn at
    /// every minute some place in the block can draw it.
    func testARunningFirstColumnTitleTakesThePlaceItFits() {
        let cases: [(h: CGFloat, columns: CGFloat, title: String)] = [
            (134.7, 4, "🏃 Run"), (114, 4, "Meeting"), (134.7, 5, "会议同步"),
        ]
        for c in cases {
            let laneLeft: CGFloat = 36, laneWidth = c.h - 40, nowY = c.h * 0.4
            let pps = c.h / CGFloat(WidgetLayout.Metrics.miniVisibleHours * 3600)
            let width = laneWidth / c.columns - 2
            for minutesIn in stride(from: 0.25, to: 45, by: 0.25) {
                let rectTop = nowY - CGFloat(minutesIn * 60) * pps + 1
                let height = WidgetLayout.miniDrawnHeight(span: 45 * 60 * pps, roomBelow: nil)
                func run(_ title: WidgetLayout.MiniTitle) -> WidgetLayout.MiniTitleRun? {
                    let pads = WidgetLayout.miniTitlePads(blockX: laneLeft, blockWidth: width, standard: 4, title: title,
                                                          laneLeft: laneLeft, nowY: nowY)
                    return WidgetLayout.miniTitleRun(c.title, width: width - pads.leading - pads.trailing, size: title.size)
                }
                let placed = WidgetLayout.miniTitlePlacement(
                    rectTop: rectTop, rectBottom: rectTop + height, contentHeight: c.h, nowY: nowY, topPad: 3, drawing: run
                )
                // Some place in the block that draws it: any full-size line box
                // whose ink is inside the rectangle and clear of the line, or
                // across it as a knockout, tried a quarter point apart.
                let m = WidgetLayout.Metrics.self
                let inkHeight = (m.miniTitleInkBottom - m.miniTitleInkTop) * m.miniTitleSize
                var drawable = false
                for inkTop in stride(from: rectTop + m.miniTitleInset, through: rectTop + height - m.miniTitleInset - inkHeight, by: 0.25) {
                    let title = WidgetLayout.MiniTitle(lineTop: inkTop - m.miniTitleInkTop * m.miniTitleSize, size: m.miniTitleSize)
                    if run(title) != nil { drawable = true; break }
                }
                let label = "\(c.title) h=\(c.h) \(c.columns) columns, \(minutesIn) min in"
                if drawable { XCTAssertNotNil(placed, "\(label): no title, though a place in the block draws it") }
            }
        }
    }

    /// An inverted snapshot (end before start) takes up its start instant, as
    /// in the packing: a block lying between its end and its start is not the
    /// next one under it.
    func testAnInvertedBlocksNextBlockIsBelowItsStart() {
        let window = WidgetLayout.miniWindow(now: t(15))
        let events = [snap("X", t(15), t(14)), snap("Y", t(14, 10), t(14, 50))]
        let slots = WidgetLayout.miniTimelineSlots(for: events, window: window)
        XCTAssertNil(WidgetLayout.miniNextStarts(for: events, slots: slots, window: window)[0])
    }

    /// An inverted snapshot (end before start) can have the next block start
    /// above its top; its drawn height is then 0, not negative.
    func testADrawnHeightIsNeverNegative() {
        for room in stride(from: CGFloat(-30), through: 0, by: 0.5) {
            XCTAssertGreaterThanOrEqual(WidgetLayout.miniDrawnHeight(span: 4, roomBelow: room), 0, "room=\(room)")
        }
        XCTAssertEqual(WidgetLayout.miniDrawnHeight(span: 4, roomBelow: -6.33), 0)
    }

    /// What is drawn over a block: the interrupts overlaid on it and, over an
    /// interrupt, its siblings drawn after it. Not an interrupt on another
    /// block, not one drawn under it, not one that is not shown.
    func testTheCoversOfABlockAreWhatIsDrawnOverIt() {
        let band = { (top: CGFloat) in WidgetLayout.MiniBand(top: top, bottom: top + 5) }
        // 0 lane P · 1 interrupt A on P · 2 lane Q · 3 interrupt B on P · 4 interrupt C on Q · 5 interrupt D on P, hidden
        let parents: [Int?] = [nil, 0, nil, 0, 2, 0]
        let extents: [WidgetLayout.MiniBand?] = [band(0), band(10), band(20), band(30), band(40), nil]
        let covers = { (idx: Int) in WidgetLayout.miniCovers(of: idx, parents: parents, extents: extents) }
        XCTAssertEqual(covers(0), [band(10), band(30)], "P: its two shown interrupts")
        XCTAssertEqual(covers(1), [band(30)], "A: its sibling B, drawn after it")
        XCTAssertEqual(covers(3), [], "B: A is drawn under it")
        XCTAssertEqual(covers(2), [band(40)], "Q: only its own interrupt")
        XCTAssertEqual(covers(4), [], "C: no sibling")
    }

    /// A drawn extent is the rectangle and half the stroke either side.
    func testADrawnExtentIncludesHalfTheStrokeEachSide() {
        let extent = WidgetLayout.miniDrawnExtent(top: 40, height: 10, strokeWidth: 1.2)
        XCTAssertEqual(extent.top, 39.4, accuracy: 1e-9)
        XCTAssertEqual(extent.bottom, 50.6, accuracy: 1e-9)
    }

    /// The occurrences a window shows, across midnight both ways — the civil
    /// day dropped them (gh#239 sim QA C1/C5).
    func testTheWindowsOccurrencesCrossMidnight() {
        let tomorrowEarly = snap("tomorrow", t(24 + 1), t(24 + 2))
        let yesterdayLate = snap("yesterday", t(-2), t(0, -30))
        var allDay = snap("allDay", t(0), t(24))
        allDay.isAllDay = true
        let all = [tomorrowEarly, yesterdayLate, allDay]

        let lateEvening = WidgetTimelineSchedule.events(overlapping: WidgetLayout.miniWindow(now: t(23, 20)), from: all)
        XCTAssertEqual(lateEvening.map(\.title), ["tomorrow"])
        XCTAssertTrue(WidgetTimelineSchedule.events(visibleOn: t(23, 20), from: all, calendar: calendar).isEmpty,
                      "positive control: the civil day drops it")

        let pastMidnight = WidgetTimelineSchedule.events(overlapping: WidgetLayout.miniWindow(now: t(0, 30)), from: all)
        XCTAssertEqual(pastMidnight.map(\.title), ["yesterday"])
        XCTAssertTrue(WidgetTimelineSchedule.events(visibleOn: t(0, 30), from: all, calendar: calendar)
            .allSatisfy { $0.title != "yesterday" }, "positive control: the civil day drops it")
    }

    /// A long block that began in the morning dragged the list back over the
    /// finished rows and dropped the running standup (gh#239 sim QA X3).
    func testListWindowKeepsTheRunningEventWhenALongBlockStartedEarly() {
        let events = [
            snap("long", t(9), t(16)),
            snap("inbox", t(9, 30), t(10)),
            snap("planning", t(10, 30), t(11)),
            snap("lunch", t(11, 30), t(12)),
            snap("standup", t(13, 50), t(14, 20)),
            snap("oneOnOne", t(14, 45), t(15, 15)),
        ]
        let rows = WidgetLayout.listWindow(events, now: t(14), capacity: 3)
        XCTAssertEqual(rows.map(\.title), ["long", "standup", "oneOnOne"])
    }

    // MARK: - Palette (F9)

    /// GOLDEN digests — the only form of this assertion that means anything.
    ///
    /// "Call it twice and compare" is satisfied by `String.hashValue` too: it is
    /// stable WITHIN a process and reseeded between them, which is exactly the
    /// defect (the widget disagreed with the app, and with its own previous
    /// launch). Reinstating `abs(type.hashValue) % count` kept the whole suite
    /// green (gh#239 QA). Pinning the values makes "agrees across processes and
    /// builds" checkable, because a per-process seed cannot reproduce them.
    ///
    /// Note `"Meeting"` and `"Admin"` both land on 8: this is a hash, and
    /// asserting pairwise distinctness would pin an accident.
    func testPaletteIndexMatchesItsGoldenDigests() {
        let golden: [(String, Int)] = [
            ("Deep Work", 4), ("Meeting", 8), ("Health", 5), ("Admin", 8),
            ("Break", 0), ("Focus", 3), ("深度工作", 6), ("", 7), ("🙂", 7),
        ]
        for (type, expected) in golden {
            XCTAssertEqual(
                WidgetLayout.paletteIndex(for: type, count: 10), expected,
                "\(type.isEmpty ? "(empty)" : type) — a changed digest means the widget and the app now disagree about colour"
            )
        }
    }

    func testPaletteIndexStaysInRangeForAnyInputAndPaletteSize() {
        let types = ["Deep Work", "", "深度工作", "🙂", String(repeating: "x", count: 4096), "\u{0}"]
        for type in types {
            for count in [1, 2, 7, 10, 64] {
                let index = WidgetLayout.paletteIndex(for: type, count: count)
                XCTAssertTrue((0..<count).contains(index), "out of range: \(type) / \(count)")
            }
        }
        XCTAssertEqual(WidgetLayout.paletteIndex(for: "Meeting", count: 0), 0, "an empty palette must not divide by zero")
        XCTAssertEqual(WidgetLayout.paletteIndex(for: "Meeting", count: -3), 0, "a negative palette must not trap")
    }

    func testPaletteIndexSpreadsTheCommonTypes() {
        let indices = Set(["Deep Work", "Meeting", "Health", "Break", "Focus", "深度工作"].map {
            WidgetLayout.paletteIndex(for: $0, count: 10)
        })
        XCTAssertGreaterThanOrEqual(indices.count, 5, "a palette that collapses six common types is not usable")
    }
}

/// The widget's strings (gh#239 F5/F6/F10).
///
/// Mutates the two preference domains `AppLanguage.current` consults, and puts
/// both back in `tearDown` — there is no other way to pin "which domain does
/// the resolver read, in which order", and that ordering is the entire bug.
final class WidgetLocalizationTests: XCTestCase {

    private var savedStandard: String??
    private var savedGroup: String??

    override func setUp() {
        super.setUp()
        savedStandard = .some(UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey))
        savedGroup = .some(SharedWidgetData.sharedDefaults?.string(forKey: SharedWidgetData.languageKey))
    }

    override func tearDown() {
        if case .some(let value) = savedStandard {
            if let value { UserDefaults.standard.set(value, forKey: AppSettingsLocale.languageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppSettingsLocale.languageKey) }
        }
        if case .some(let value) = savedGroup, let group = SharedWidgetData.sharedDefaults {
            if let value { group.set(value, forKey: SharedWidgetData.languageKey) }
            else { group.removeObject(forKey: SharedWidgetData.languageKey) }
        }
        savedStandard = nil
        savedGroup = nil
        super.tearDown()
    }

    private func setLanguage(standard: String?, group: String?) throws {
        let shared = try XCTUnwrap(
            SharedWidgetData.sharedDefaults,
            "this test host must be entitled to the App Group; without it the fallback under test is unreachable"
        )
        if let standard { UserDefaults.standard.set(standard, forKey: AppSettingsLocale.languageKey) }
        else { UserDefaults.standard.removeObject(forKey: AppSettingsLocale.languageKey) }
        if let group { shared.set(group, forKey: SharedWidgetData.languageKey) }
        else { shared.removeObject(forKey: SharedWidgetData.languageKey) }
    }

    /// Domain separation, asserted on the PURE resolver.
    ///
    /// The first spelling drove this through `UserDefaults`, writing the
    /// "group" value *through the accessor under test* and probing the two
    /// domains with DIFFERENT keys (`appLanguage` vs `widgetLanguage`) — so
    /// substituting `sharedDefaults = UserDefaults.standard` kept all seven
    /// green. It pinned key precedence, not domain separation, and domain
    /// separation is the whole of F5 (gh#239 QA). The resolver is pure now, so
    /// this table says exactly which domain wins, in which process.
    func testResolverPrecedenceTable() {
        let cases: [(local: String?, group: String?, ext: Bool, expect: AppLanguage, why: String)] = [
            // The widget: its own domain never carries the key, so the mirror decides.
            (nil, "zh", true, .chinese, "extension with a silent local domain reads the App Group — this IS gh#239 F5"),
            (nil, "en", true, .english, "…and honours an English mirror just as well"),
            (nil, nil, true, .english, "extension with nothing anywhere degrades to English"),
            ("en", "zh", true, .english, "a local value still wins inside an extension"),
            // The app: the mirror must NOT be consulted.
            (nil, "zh", false, .english, "the APP must ignore the mirror — a restore that clears appLanguage would otherwise latch the app to a stale language while its own picker reads the cleared domain"),
            ("zh", "en", false, .chinese, "the app reads its own domain"),
            ("zh", nil, false, .chinese, "…with or without a mirror"),
            (nil, nil, false, .english, "app with nothing set degrades to English"),
            // Garbage in either domain must not stick or crash.
            ("kl", "zh", true, .chinese, "an unparseable local value falls through to the group in an extension"),
            ("kl", "zh", false, .english, "…and to English in the app, never to the mirror"),
            ("zh", "xx", true, .chinese, "an unparseable mirror is ignored when the local value is good"),
            (nil, "xx", true, .english, "an unparseable mirror degrades to English"),
            ("", "zh", true, .chinese, "an empty local value is not a language"),
        ]
        for c in cases {
            XCTAssertEqual(
                AppLanguage.resolve(local: c.local, group: c.group, isAppExtension: c.ext),
                c.expect,
                "local=\(c.local ?? "nil") group=\(c.group ?? "nil") ext=\(c.ext): \(c.why)"
            )
        }
    }

    /// The gate itself: with the group fallthrough scoped to extensions, the
    /// app's answer must not depend on the mirror AT ALL.
    func testAppAnswerIsIndependentOfTheAppGroupMirror() {
        for local in [nil, "en", "zh", "kl"] as [String?] {
            var answers = Set<AppLanguage>()
            for group in [nil, "zh", "en", "xx"] as [String?] {
                answers.insert(AppLanguage.resolve(local: local, group: group, isAppExtension: false))
            }
            XCTAssertEqual(answers.count, 1,
                           "local=\(local ?? "nil"): the app changed its answer when only the mirror changed")
        }
    }

    /// End to end through the real domains, for the app process this suite runs
    /// in — the pure table cannot catch a wrong key or a missing App Group
    /// entitlement, and the `XCTUnwrap` in `setLanguage` does.
    func testLiveResolverReadsTheAppsOwnDomain() throws {
        XCTAssertFalse(AppLanguage.isAppExtension, "the test host is the app, not an extension")
        try setLanguage(standard: "zh", group: "en")
        XCTAssertEqual(AppLanguage.current, .chinese)
        XCTAssertEqual(L(.now), "进行中")
        XCTAssertEqual(AppLanguage.current.locale.identifier, "zh_CN",
                       "dates and chrome must resolve from the same value")
        try setLanguage(standard: "en", group: "zh")
        XCTAssertEqual(AppLanguage.current, .english)
        XCTAssertEqual(L(.now), "Now")
        try setLanguage(standard: nil, group: "zh")
        XCTAssertEqual(AppLanguage.current, .english,
                       "the app must not pick the mirror up when its own domain goes silent")
    }

    /// The ring hardcoded "2h 15m left" in English regardless of language, and
    /// the three keys meant for it had been declared and never looked up.
    func testRemainingTextIsLocalisedInBothLanguages() throws {
        try setLanguage(standard: "en", group: "en")
        XCTAssertEqual(LFormat.remaining(seconds: 83 * 60), "1h 23m left")
        XCTAssertEqual(LFormat.remaining(seconds: 120 * 60), "2h left")
        XCTAssertEqual(LFormat.remaining(seconds: 45 * 60), "45m left")

        try setLanguage(standard: "zh", group: "zh")
        XCTAssertEqual(LFormat.remaining(seconds: 83 * 60), "还剩1时23分")
        XCTAssertEqual(LFormat.remaining(seconds: 120 * 60), "还剩2时")
        XCTAssertEqual(LFormat.remaining(seconds: 45 * 60), "还剩45分")
    }

    /// A still-running event must never read as finished.
    func testRemainingTextRoundsTheLastMinuteUpAndClampsAtZero() throws {
        try setLanguage(standard: "en", group: "en")
        XCTAssertEqual(LFormat.remaining(seconds: 20), "1m left")
        XCTAssertEqual(LFormat.remaining(seconds: 0), "1m left")
        XCTAssertEqual(LFormat.remaining(seconds: -500), "1m left")
    }

    /// The hour boundary in both languages — exactly where the template
    /// changes, and the one value the first suite skipped.
    func testRemainingTextAtTheHourBoundary() throws {
        try setLanguage(standard: "en", group: "en")
        XCTAssertEqual(LFormat.remaining(seconds: 59 * 60), "59m left")
        XCTAssertEqual(LFormat.remaining(seconds: 60 * 60), "1h left")
        XCTAssertEqual(LFormat.remaining(seconds: 61 * 60), "1h 1m left")
        try setLanguage(standard: "zh", group: "zh")
        XCTAssertEqual(LFormat.remaining(seconds: 59 * 60), "还剩59分")
        XCTAssertEqual(LFormat.remaining(seconds: 60 * 60), "还剩1时")
        XCTAssertEqual(LFormat.remaining(seconds: 61 * 60), "还剩1时1分")
    }

    /// The payload is plain JSON and a `Date` decodes straight off a `Double`,
    /// so a corrupt blob can hand this anything. It must neither trap nor print
    /// a negative hour count — `String(format:)` reads `%d` as 32 bits, so the
    /// templates use `%ld` and the interval is clamped before conversion
    /// (gh#239 QA).
    func testRemainingTextSurvivesAbsurdIntervals() throws {
        try setLanguage(standard: "en", group: "en")
        let absurd: [TimeInterval] = [1e12, 1e15, 1e19, .greatestFiniteMagnitude,
                                      -1e19, .infinity, -.infinity, .nan]
        for seconds in absurd {
            let text = LFormat.remaining(seconds: seconds)
            XCTAssertFalse(text.contains("-"), "negative component for \(seconds): \(text)")
            XCTAssertFalse(text.isEmpty)
        }
        // Past the clamp everything reads as the ceiling, not as a wrapped or
        // truncated number.
        XCTAssertEqual(LFormat.remaining(seconds: 100 * 24 * 3600), "2400h left")
        XCTAssertEqual(LFormat.remaining(seconds: 1e19), "2400h left")
        XCTAssertEqual(LFormat.remaining(seconds: 1e12), "2400h left")

        // The Chinese templates take the same absurd values — nothing else in
        // the suite drives them past a normal event length.
        try setLanguage(standard: "zh", group: "zh")
        for seconds in absurd {
            let text = LFormat.remaining(seconds: seconds)
            XCTAssertFalse(text.contains("-"), "negative component for \(seconds): \(text)")
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertEqual(LFormat.remaining(seconds: 1e19), "还剩2400时")
    }

    /// The medium header hardcoded English and said "1 events".
    func testEventCountIsLocalisedAndPluralised() throws {
        try setLanguage(standard: "en", group: "en")
        XCTAssertEqual(LFormat.eventCount(0), "0 events")
        XCTAssertEqual(LFormat.eventCount(1), "1 event")
        XCTAssertEqual(LFormat.eventCount(4), "4 events")

        // No space in Chinese: a numeral is not separated from its measure
        // word, and the sibling composer already gets this right.
        try setLanguage(standard: "zh", group: "zh")
        XCTAssertEqual(LFormat.eventCount(0), "0个事件")
        XCTAssertEqual(LFormat.eventCount(1), "1个事件")
        XCTAssertEqual(LFormat.eventCount(4), "4个事件")
        XCTAssertFalse(LFormat.remaining(seconds: 83 * 60).contains(" "),
                       "the two composers must agree about Chinese numeral spacing")
    }

    /// The ring's two-line remaining label breaks where the language does —
    /// after "还剩", before "left" — and is otherwise the one-line string
    /// (gh#239 sim QA: "还剩2" / "时59分").
    func testTwoLineRemainingBreaksAtTheLanguagesSeam() throws {
        for (language, joiner) in [("en", " "), ("zh", "")] {
            try setLanguage(standard: language, group: language)
            let samples: [TimeInterval] = [30, 300, 3600, 7200, 4980, 38700]
            for seconds in samples {
                let two = LFormat.remaining(seconds: seconds, twoLines: true)
                let lines = two.components(separatedBy: "\n")
                XCTAssertEqual(lines.count, 2, "\(language) \(seconds): \(two)")
                XCTAssertEqual(lines.joined(separator: joiner), LFormat.remaining(seconds: seconds),
                               "\(language) \(seconds)")
                if language == "zh" { XCTAssertEqual(lines[0], "还剩") } else { XCTAssertEqual(lines[1], "left") }
            }
        }
    }

    /// Which empty state a face shows depends on whether the day had events.
    func testIdleStatusDependsOnWhetherTheDayHadEvents() throws {
        for language in ["en", "zh"] {
            try setLanguage(standard: language, group: language)
            XCTAssertEqual(LFormat.idleStatus(dayHasEvents: false), L(.noEventsToday))
            XCTAssertEqual(LFormat.idleStatus(dayHasEvents: true), L(.noMoreEvents))
            XCTAssertNotEqual(L(.noEventsToday), L(.noMoreEvents), language)
        }
    }

    /// The bar widget labelled a running event with the widget's own NAME.
    /// These are the two statuses it and the list widget must agree on.
    func testRunningAndUpcomingStatusesAreDistinctFromTheWidgetName() throws {
        for language in ["en", "zh"] {
            try setLanguage(standard: language, group: language)
            XCTAssertNotEqual(L(.now), L(.timeline), "\(language): a status must not be the widget's name")
            XCTAssertNotEqual(L(.now), L(.upNext), "\(language)")
            XCTAssertFalse(L(.now).isEmpty)
            XCTAssertFalse(L(.upNext).isEmpty)
        }
    }
}

// MARK: - gh#239: the widget's own call sites, source-pinned

/// `DoneWidget.swift` is compiled by exactly one target, and that target has no
/// test bundle — so F3 (text compaction), F6 (the localized composers) and F10
/// (the running-event status) live entirely where `DoneTests` cannot execute
/// them. gh#239 QA proved the cost of pretending otherwise: reverting all three
/// call sites and recompiling the widget left the suite at 29/29 green, and the
/// test *named* for F10 asserted only that three entries of the string table
/// differ from one another — which was already true before the fix.
///
/// A source scan is the honest reachable layer, weaker than a behavioural test
/// and declared as such — the `WidgetTimelinePolicySourcePinTests` idiom this
/// repo already uses for the same target.
final class WidgetViewSourcePinTests: XCTestCase {

    private func widgetSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DoneWidget/DoneWidget.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The widget's code without its comment lines, whitespace collapsed to
    /// one space: a pin is met by code, not by a comment that quotes it.
    private func widgetCode() throws -> String {
        try widgetSource().split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// F10: a running event is labelled with a STATUS, not with the widget's
    /// own name.
    func testBarLabelsARunningEventAsNowNotAsTheWidgetName() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains("Text(isCurrent ? L(.now) : L(.upNext))"),
                      "the bar's header must read Now / Up Next")
        XCTAssertFalse(src.contains("isCurrent ? L(.timeline)"),
                       "`L(.timeline)` is the widget's NAME — it must not stand in for a status again")
    }

    /// F6: the three composed strings go through `LFormat`, and no English
    /// literal survives beside them.
    func testComposedStringsGoThroughLFormat() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains("LFormat.remaining(seconds:"),
                      "the ring's remaining label must be composed, not interpolated in English")
        XCTAssertTrue(src.contains("LFormat.eventCount("),
                      "the medium header's count must be composed")
        XCTAssertTrue(src.contains("return L(.allDay)"),
                      "the all-day label must be looked up")
        for literal in ["\"m left\"", "\"h left\"", "m left\\\"", "events\")", "\"All day\""] {
            XCTAssertFalse(src.contains(literal),
                           "hardcoded English survives in the widget: \(literal)")
        }
    }

    /// F3: text compaction is applied, and is applied widely — a single
    /// surviving `widgetFit()` would satisfy a mere `contains` check.
    func testTextCompactionIsAppliedAcrossTheWidget() throws {
        let src = try widgetSource()
        let applications = src.components(separatedBy: ".widgetFit(").count - 1
        XCTAssertGreaterThanOrEqual(applications, 20,
                                    "only \(applications) compaction sites — F3 was a sweep, not a spot fix")
        XCTAssertTrue(src.contains("func widgetFit("), "the modifier itself must exist")
        XCTAssertTrue(src.contains("minimumScaleFactor(minimumScale)"),
                      "widgetFit must actually scale, not just clamp lines")
    }

    /// The sub-10pt faces must NOT take the 0.7 default: at 8pt it draws 5.6pt
    /// type that still truncates in a two-column lane (gh#239 QA G2).
    func testTinyFacesUseAHigherCompactionFloor() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains(".widgetFit(0.85)"),
                      "the 8pt block title and the 9pt badge need a higher floor than the 10-13pt default")
        XCTAssertTrue(src.contains(".widgetFit(1)"),
                      "the 7pt axis labels must not scale at all")
    }

    /// The mini timeline draws the window's occurrences, which the provider
    /// builds with the shared window — not the civil day's list (gh#239 sim QA).
    func testMiniTimelineDrawsTheWindowNotTheCivilDay() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains("let events = entry.windowEvents"),
                      "the mini timeline must draw the window's occurrences")
        XCTAssertTrue(src.contains("overlapping: WidgetLayout.miniWindow(now: date), from: all"),
                      "the provider must build them from the same window the view draws")
    }

    /// The bar's stack has exactly the four gaps `barStackHeight` sums: two in
    /// the top group, the spacer, one in the bottom group. The single stack it
    /// replaced had five, and overflowed the SE's box by ~6pt (gh#239 sim QA).
    func testTheBarStackIsTheTwoGroupsTheArithmeticSums() throws {
        let src = try widgetSource()
        let start = try XCTUnwrap(src.range(of: "struct TimelineBarWidgetView"))
        let rest = src[start.upperBound...]
        let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
        let code = rest[..<end].split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("""
            VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: spacing) {
            """), "the outer stack has no spacing of its own; the top group does")
        XCTAssertEqual(code.components(separatedBy: "Spacer(minLength: spacing)").count - 1, 1,
                       "one spacer, at least a gap tall, between the groups")
        XCTAssertEqual(code.components(separatedBy: "VStack(alignment: .leading, spacing: spacing)").count - 1, 2,
                       "both groups take the spacing the arithmetic sums")
        XCTAssertTrue(code.contains("let spacing = WidgetLayout.barSpacing(titleLines: titleLines)"))
        XCTAssertTrue(code.contains("let lines = WidgetLayout.barTitleLines(contentHeight: geo.size.height)"))
        XCTAssertTrue(code.contains("WidgetLayout.barClockHeight(contentHeight: geo.size.height, titleLines: lines)"))
        XCTAssertTrue(code.contains(".lineLimit(titleLines)"), "the title takes the lines the arithmetic gave it")
    }

    /// Up next, the bar's hero is the event's start, not the clock; and no
    /// branch of it uses the widget's name as a status (gh#239 sim QA).
    func testBarHeroIsTheStartWhileUpNextAndNoBranchUsesTheName() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains("Text(formatTime(isCurrent ? entry.date : event.startDate))"))
        XCTAssertFalse(src.contains("Text(L(.timeline))"),
                       "the empty branch must say a status, not the widget's name")
    }

    /// `WidgetLayoutTests` renders title runs the way the view draws them.
    func testTheTitleIsFittedAsTheseTestsRenderIt() throws {
        let code = try widgetCode()
        XCTAssertTrue(code.contains("let text = Text(run.text).font(.system(size: run.size, weight: .semibold)) return (run.kerning == 0 ? text : text.kerning(run.kerning)) .lineLimit(1) .fixedSize() }"),
                      "a title run is drawn as it is, at its own size")
        XCTAssertEqual(code.components(separatedBy: "titleText(title.run)").count - 1, 2, "by the block and by the knockout")
    }

    /// The now line's knockout cuts the line and nothing else: the line opens
    /// its own layer, the cut is inside it after the line, and the layer is
    /// composited on its own, with the dot outside it. Without the group the
    /// cut cleared the block and the title under it; with the line after the
    /// cut it cleared nothing (gh#239 static review, rendered both ways).
    func testTheKnockoutIsConfinedToTheNowLinesOwnLayer() throws {
        let code = try widgetCode()
        let view = try XCTUnwrap(code.range(of: "struct MiniTimelineWidgetView"))
        let layerHead = "ZStack(alignment: .topLeading) { Rectangle() .fill(Color.primary) .frame(width: lane.width + 4, height: 1)"
        let layer = try XCTUnwrap(code.range(of: layerHead, range: view.upperBound..<code.endIndex),
                                  "the line opens its own layer")
        var depth = 0
        var close: String.Index?
        var i = try XCTUnwrap(code.range(of: "{", range: layer.lowerBound..<code.endIndex)).lowerBound
        while i < code.endIndex {
            if code[i] == "{" { depth += 1 }
            if code[i] == "}" {
                depth -= 1
                if depth == 0 { close = i; break }
            }
            i = code.index(after: i)
        }
        let end = try XCTUnwrap(close, "the layer closes")
        let inside = code[layer.upperBound..<end]
        XCTAssertTrue(inside.contains("title.knocksOutNowLine"), "the knocked-out titles are inside the layer")
        XCTAssertTrue(inside.contains(".blendMode(.destinationOut)"), "the cut is inside the layer, after the line")
        XCTAssertEqual(code.components(separatedBy: ".blendMode(.destinationOut)").count - 1, 1, "and nowhere else")
        XCTAssertTrue(code[code.index(after: end)...].hasPrefix(
            " .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading) .compositingGroup()"
        ), "the layer is composited on its own")
        let dot = try XCTUnwrap(code.range(of: "Circle()", range: view.upperBound..<code.endIndex))
        XCTAssertLessThan(dot.lowerBound, layer.lowerBound, "the dot is drawn before the layer, so the cut leaves it whole")
    }

    /// The two views whose fit is solved from the box must actually consume the
    /// shared arithmetic, and the metrics must not be re-typed here.
    func testViewsConsumeTheSharedLayoutArithmetic() throws {
        let src = try widgetCode()
        for call in ["WidgetLayout.miniTimelineSlots(for: events, window: window)",
                     "WidgetLayout.miniNextStarts(for: events, slots: slots, window: window)",
                     "WidgetLayout.miniDrawnHeight(", "WidgetLayout.miniTitlePlacement(",
                     "WidgetLayout.miniTitlePads(", "WidgetLayout.miniWindowShows(",
                     "WidgetLayout.hourLabelInsideBox(", "WidgetLayout.listRowCapacity(",
                     "WidgetLayout.listWindow(", "WidgetLayout.ringDiameter(",
                     "WidgetLayout.barClockHeight(", "WidgetLayout.hourLabelFits(",
                     "WidgetLayout.paletteIndex(", "LFormat.idleStatus(",
                     "LFormat.remaining(seconds: remaining, twoLines: true)",
                     "WidgetLayout.miniOverlayParents(for: events)",
                     "WidgetLayout.miniDrawnExtent(top: $0.top, height: $0.height, strokeWidth: $0.style.strokeWidth)",
                     "covers: WidgetLayout.miniCovers(of: idx, parents: parents, extents: extents)",
                     "WidgetLayout.miniTitleRun( events[idx].title, width: width - pads.leading - pads.trailing, size: title.size, bold: legibilityWeight == .bold )",
                     "top: WidgetLayout.miniTitleRunTop(title, run: run)",
                     "WidgetLayout.MiniBand(top: $0.top, bottom: $0.top + $0.height)",
                     "for idx in WidgetLayout.miniCoincidingOverlays(for: events, parents: parents, rects: drawn) { rects[idx] = nil } let extents = rects.map { rect in",
                     "span: span, roomBelow: nextStarts[idx].map { lane.y($0) - blockTop }",
                     "BlockStyle.interrupt : BlockStyle.lane, blockTop + 1, height)",
                     "covers: WidgetLayout.miniCovers(of: idx, parents: parents, extents: extents) ) { title -> PlacedTitle? in",
                     "title: placed?.drawn",
                     ".padding(.leading, title.pads.leading) .offset(y: title.top - place.rectTop)",
                     ".offset(x: place.x, y: title.top)",
                     "@Environment(\\.legibilityWeight) private var legibilityWeight",
                     "laneLeft: lane.left, nowY: lane.nowY",
                     ".background(Rectangle().fill(Color.white).padding(-1))",
                     "let dot = WidgetLayout.Metrics.miniNowDotRadius",
                     ".frame(width: 2 * dot, height: 2 * dot) .offset(x: lane.left - dot, y: lane.nowY - dot)",
                     "laneLeft: lane.left, nowY: lane.nowY )",
                     ".configurationDisplayName(L(.todaysEvents))",
                     "let following = WidgetLayout.smallListFollowing(entry.events, card: event, now: entry.date) ViewThatFits(in: .vertical) { cardAndRows(event, following, rows: 3) cardAndRows(event, following, rows: 2) cardAndRows(event, following, rows: 1) cardAndRows(event, following, rows: 0) cardAndRows(event, following, rows: 0, titleLines: 1) } } else {",
                     "let shown = Array(following.prefix(min(rows, WidgetLayout.Metrics.smallListRowCap)))",
                     "private var headerHeight: CGFloat { WidgetLayout.listHeights(scale: scale).header }",
                     "private var rowHeight: CGFloat { WidgetLayout.listHeights(scale: scale).row }"] {
            XCTAssertTrue(src.contains(call), "the view must consume \(call)")
        }
        XCTAssertEqual(src.components(separatedBy: "@ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1").count - 1, 2,
                       "both lists follow the reader's text size")
        XCTAssertEqual(src.components(separatedBy: ".dynamicTypeSize(...DynamicTypeSize.xxLarge)").count - 1, 2,
                       "both lists are capped where the tests check them")
        XCTAssertTrue(src.contains("DoneWidgetSmallView(entry: entry) .dynamicTypeSize(...DynamicTypeSize.xxLarge)"))
        XCTAssertTrue(src.contains("DoneWidgetMediumView(entry: entry) .dynamicTypeSize(...DynamicTypeSize.xxLarge)"))
        for metric in ["WidgetLayout.listHeights(scale: scale)",
                       "WidgetLayout.Metrics.listVerticalMargin", "WidgetLayout.Metrics.miniNowFraction",
                       "WidgetLayout.Metrics.listRowSpacing", "WidgetLayout.Metrics.ringTopLabelHeight",
                       "WidgetLayout.Metrics.ringSpacing", "WidgetLayout.Metrics.barSpacing"] {
            XCTAssertTrue(src.contains(metric),
                          "\(metric) must come from the shared declaration the tests assert against — a literal here is invisible to every test")
        }
    }
}
