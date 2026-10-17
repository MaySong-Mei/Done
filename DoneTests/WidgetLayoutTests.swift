import XCTest
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

    /// The three content boxes WidgetKit actually hands the medium family,
    /// asserted against the SHIPPING metrics — so changing a metric in the view
    /// (which `DoneTests` cannot compile) has to face this test.
    ///
    /// Row spacing of 4 put this at 3/3/3; at 2 the 170-class box fits a fourth
    /// row, which is where the running event of a busy evening lands.
    func testMediumCapacityOnEveryShippingWidgetHeight() {
        let expected: [(CGFloat, Int)] = [(116, 3), (126, 3), (138, 4)]
        for (height, rows) in expected {
            let n = WidgetLayout.listRowCapacity(
                contentHeight: height,
                headerHeight: WidgetLayout.Metrics.listHeaderHeight,
                rowHeight: WidgetLayout.Metrics.listRowHeight,
                spacing: WidgetLayout.Metrics.listRowSpacing,
                cap: WidgetLayout.Metrics.listRowCap
            )
            XCTAssertEqual(n, rows, "content height \(height)")
            let used = WidgetLayout.Metrics.listHeaderHeight
                + CGFloat(n) * (WidgetLayout.Metrics.listRowHeight + WidgetLayout.Metrics.listRowSpacing)
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
        for side in [CGFloat(116), 126, 138] {
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
        XCTAssertLessThan(
            WidgetLayout.barClockHeight(contentHeight: 116), design,
            "the 148-class box is 3pt short of the design stack — this is the box where the bar clipped"
        )
        XCTAssertEqual(WidgetLayout.barClockHeight(contentHeight: 126), design,
                       "the 158-class box holds the design stack")
        XCTAssertEqual(WidgetLayout.barClockHeight(contentHeight: 138), design,
                       "so does the 170-class box")
        // And the shrink is exactly the shortfall, not an arbitrary step.
        let shortfall = WidgetLayout.barStackHeight(clockHeight: design) - 116
        XCTAssertEqual(WidgetLayout.barClockHeight(contentHeight: 116), design - shortfall, accuracy: 1e-9)
    }

    func testBarClockNeverGrowsAndNeverVanishes() {
        XCTAssertEqual(WidgetLayout.barClockHeight(contentHeight: 400),
                       WidgetLayout.Metrics.barClockHeight)
        XCTAssertGreaterThanOrEqual(WidgetLayout.barClockHeight(contentHeight: 10), 16)
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

    /// The title gate reads the block's TIME EXTENT, not the (floored, 2pt
    /// shorter) height it is drawn at — the extraction of `block()` moved that
    /// threshold from 10pt to an effective 12pt and took the title off every
    /// half-hour event (gh#239 QA).
    func testMiniTimelineTitleGateReadsTheSpanNotTheDrawnHeight() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains("if spanHeight > 10"),
                      "the gate must read the untrimmed span")
        XCTAssertFalse(src.contains("if height > 10"),
                       "gating on the drawn height silently raises the threshold by 2pt")
        XCTAssertTrue(src.contains("spanHeight: blockH"),
                      "both draw passes must pass the raw block height")
    }

    /// The two views whose fit is solved from the box must actually consume the
    /// shared arithmetic, and the metrics must not be re-typed here.
    func testViewsConsumeTheSharedLayoutArithmetic() throws {
        let src = try widgetSource()
        for call in ["WidgetLayout.miniTimelineSlots(", "WidgetLayout.listRowCapacity(",
                     "WidgetLayout.listWindow(", "WidgetLayout.ringDiameter(",
                     "WidgetLayout.barClockHeight(", "WidgetLayout.hourLabelFits(",
                     "WidgetLayout.paletteIndex("] {
            XCTAssertTrue(src.contains(call), "the view must consume \(call)")
        }
        for metric in ["WidgetLayout.Metrics.listHeaderHeight", "WidgetLayout.Metrics.listRowHeight",
                       "WidgetLayout.Metrics.listRowSpacing", "WidgetLayout.Metrics.ringTopLabelHeight",
                       "WidgetLayout.Metrics.ringSpacing", "WidgetLayout.Metrics.barSpacing"] {
            XCTAssertTrue(src.contains(metric),
                          "\(metric) must come from the shared declaration the tests assert against — a literal here is invisible to every test")
        }
    }
}
