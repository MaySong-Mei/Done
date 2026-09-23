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

    /// Touching at an instant is not overlapping: 09:00-10:00 and 10:00-11:00
    /// are consecutive, and splitting the lane for them would waste half of it.
    func testBackToBackEventsShareOneColumn() {
        let events = [snap("first", t(9), t(10)), snap("second", t(10), t(11))]
        for slot in WidgetLayout.miniTimelineSlots(for: events) {
            XCTAssertEqual(slot.width, 1, accuracy: 1e-9)
        }
    }

    /// A block expands rightward through columns holding nothing concurrent,
    /// so a cluster never leaves a permanently empty strip.
    func testBlockExpandsIntoAnEmptyNeighbouringColumn() {
        // A and B are concurrent (2 columns). C sits after both, alone in time,
        // so it may claim the whole lane rather than half of it.
        let events = [
            snap("A", t(13), t(14)),
            snap("B", t(13, 30), t(14, 30)),
            snap("C", t(15), t(16)),
        ]
        assertNoCollision(events, "expansion")
        let slots = WidgetLayout.miniTimelineSlots(for: events)
        XCTAssertEqual(slots[2].width, 1, accuracy: 1e-9, "C has no concurrent neighbour and should span the lane")
    }

    /// Randomised days: the invariant must hold for shapes nobody thought of.
    func testRandomDaysNeverCollide() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<300 {
            let count = Int.random(in: 2...9, using: &rng)
            var events: [SharedEventSnapshot] = []
            for i in 0..<count {
                let startMinutes = Int.random(in: 0..<(23 * 60), using: &rng)
                let duration = Int.random(in: 5...240, using: &rng)
                events.append(snap(
                    "e\(i)",
                    calendar.date(byAdding: .minute, value: startMinutes, to: day)!,
                    calendar.date(byAdding: .minute, value: startMinutes + duration, to: day)!
                ))
            }
            events.sort { $0.startDate < $1.startDate }
            assertNoCollision(events, "random trial \(trial)")
        }
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

    func testHourLabelSuppressionIsSymmetric() {
        XCTAssertEqual(
            WidgetLayout.hourLabelFits(markerY: 50, nowY: 56),
            WidgetLayout.hourLabelFits(markerY: 62, nowY: 56)
        )
    }

    // MARK: - Row capacity (F2)

    /// The capacity must be exactly the number of rows whose stack still fits
    /// the box — one more must not.
    func testListRowCapacityFillsTheBoxWithoutOverflowing() {
        let header: CGFloat = 15, row: CGFloat = 28, spacing: CGFloat = 4
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
            WidgetLayout.listRowCapacity(contentHeight: 4000, headerHeight: 15, rowHeight: 28, spacing: 4),
            4, "the cap bounds a tall family"
        )
        XCTAssertEqual(
            WidgetLayout.listRowCapacity(contentHeight: 0, headerHeight: 0, rowHeight: 0, spacing: 0),
            1, "degenerate metrics must not divide by zero"
        )
    }

    /// The three content boxes WidgetKit actually hands the medium family,
    /// pinned so a future metric change has to face them.
    func testMediumCapacityOnEveryShippingWidgetHeight() {
        for height in [CGFloat(116), 126, 138] {
            XCTAssertEqual(
                WidgetLayout.listRowCapacity(contentHeight: height, headerHeight: 15, rowHeight: 28, spacing: 4),
                3, "content height \(height)"
            )
        }
    }

    // MARK: - Ring diameter (F4)

    func testRingFitsEveryShippingSmallWidgetBox() {
        let top: CGFloat = 14, bottom: CGFloat = 15, spacing: CGFloat = 8
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

    // MARK: - Palette (F9)

    /// `String.hashValue` is seeded per process: the same type drew one colour
    /// in the app and another in the widget, and a third after a relaunch.
    func testPaletteIndexIsStableInRangeAndTotal() {
        let types = ["Deep Work", "Meeting", "", "深度工作", "🙂", String(repeating: "x", count: 4096)]
        for type in types {
            let index = WidgetLayout.paletteIndex(for: type, count: 10)
            XCTAssertEqual(index, WidgetLayout.paletteIndex(for: type, count: 10), "not deterministic: \(type)")
            XCTAssertTrue((0..<10).contains(index), "out of range for \(type)")
        }
        XCTAssertEqual(WidgetLayout.paletteIndex(for: "Meeting", count: 0), 0, "an empty palette must not divide by zero")
    }

    func testPaletteIndexDistinguishesCommonTypes() {
        let indices = Set(["Deep Work", "Meeting", "Health", "Admin"].map {
            WidgetLayout.paletteIndex(for: $0, count: 10)
        })
        XCTAssertGreaterThan(indices.count, 1, "a constant is not a palette")
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

    /// The widget extension's own `standard` domain never carries
    /// `appLanguage`, so before the fix every `L(...)` in `DoneWidget.swift`
    /// resolved to English while the same widget's date header — read from the
    /// App Group — came out in Chinese.
    func testLanguageFallsBackToTheAppGroupWhenTheLocalDomainIsSilent() throws {
        try setLanguage(standard: nil, group: "zh")
        XCTAssertEqual(AppLanguage.current, .chinese)
        XCTAssertEqual(L(.now), "进行中")
        XCTAssertEqual(AppLanguage.current.locale.identifier, "zh_CN",
                       "dates and chrome must resolve from the same value")
    }

    /// Inside the app its own domain is the source of truth and must win, so a
    /// language change is live on the run that writes it.
    func testLocalDomainWinsOverTheAppGroupMirror() throws {
        try setLanguage(standard: "en", group: "zh")
        XCTAssertEqual(AppLanguage.current, .english)
        try setLanguage(standard: "zh", group: "en")
        XCTAssertEqual(AppLanguage.current, .chinese)
    }

    func testUnknownOrAbsentValuesDegradeToEnglish() throws {
        try setLanguage(standard: nil, group: nil)
        XCTAssertEqual(AppLanguage.current, .english)
        try setLanguage(standard: "kl", group: "xx")
        XCTAssertEqual(AppLanguage.current, .english, "an unparseable raw value must not crash or stick")
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

    /// The medium header hardcoded English and said "1 events".
    func testEventCountIsLocalisedAndPluralised() throws {
        try setLanguage(standard: "en", group: "en")
        XCTAssertEqual(LFormat.eventCount(0), "0 events")
        XCTAssertEqual(LFormat.eventCount(1), "1 event")
        XCTAssertEqual(LFormat.eventCount(4), "4 events")

        try setLanguage(standard: "zh", group: "zh")
        XCTAssertEqual(LFormat.eventCount(1), "1 个事件")
        XCTAssertEqual(LFormat.eventCount(4), "4 个事件")
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
