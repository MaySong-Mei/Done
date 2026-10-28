import XCTest
@testable import Done

/// Parallel events on the watch's today page, case by case: where each
/// block goes, which one the running bar shows and what its buttons
/// change, drawing next to and across them at every zoom, the stats under
/// each overlap rule, and which motions a change plays. Every expected
/// number is worked out by hand from the clock times in the comment above
/// it. Fixed UTC day, 2026-03-10.
@MainActor
final class WristParallelEventsTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute))!
    }

    private var dayStart: Date { at(0) }
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    /// `created` orders events that start together: seconds after a fixed
    /// instant a week back.
    private func ev(
        _ title: String, _ start: Date, _ end: Date, created: Double = 0,
        interruptOn parent: Event? = nil, parentID: UUID? = nil
    ) -> Event {
        let parentEventID = parentID ?? parent?.id
        return Event(
            title: title, timeRanges: [.init(start: start, end: end)],
            createdAt: dayStart.addingTimeInterval(-7 * 86_400 + created), type: title,
            displayKind: parentEventID == nil ? .regular : .interrupt,
            interruptRelation: parentEventID.map { EventInterruptRelation(parentEventID: $0, occurrenceDate: dayStart) }
        )
    }

    private func occurrences(_ events: [Event], now: Date) -> [WristOccurrence] {
        WristSnapshotBuilder.occurrences(events: events, now: now, calendar: calendar, colorHex: { _ in "#0A84FF" })
    }

    private func page(_ events: [Event], now: Date? = nil, draft: (Date, Date)? = nil) -> WristDayPage {
        WristDayLayout.page(
            occurrences(events, now: now ?? at(15)), dismissed: [], dayStart: dayStart, dayEnd: dayEnd,
            now: now ?? at(15), currentID: nil, draft: draft.map { WristTimeSpan(start: $0.0, end: $0.1) }
        )
    }

    private func slot(_ page: WristDayPage, _ title: String, file: StaticString = #filePath, line: UInt = #line) -> WristOverlapSlot {
        guard let block = page.blocks.first(where: { $0.occurrence.title == title }) else {
            XCTFail("no block \(title)", file: file, line: line)
            return .full
        }
        return block.slot
    }

    private func assertSlot(
        _ page: WristDayPage, _ title: String, x: Double, width: Double, depth: Int = 0,
        covers: [(Date, Date)] = [], file: StaticString = #filePath, line: UInt = #line
    ) {
        let s = slot(page, title, file: file, line: line)
        XCTAssertEqual(s.x, x, accuracy: 1e-9, "\(title) x", file: file, line: line)
        XCTAssertEqual(s.width, width, accuracy: 1e-9, "\(title) width", file: file, line: line)
        XCTAssertEqual(s.depth, depth, "\(title) depth", file: file, line: line)
        XCTAssertEqual(s.coverRanges.map { [$0.start, $0.end] }, covers.map { [$0.0, $0.1] }, "\(title) covers", file: file, line: line)
    }

    // MARK: - Layout

    /// A 9–10, B 9:30–10:30: an hour each, neither dominant — two halves.
    func testTwoOverlappingSplitInHalves() {
        let p = page([ev("A", at(9), at(10)), ev("B", at(9, 30), at(10, 30))])
        assertSlot(p, "A", x: 0, width: 0.5)
        assertSlot(p, "B", x: 0.5, width: 0.5)
    }

    /// A 9–11 (2h), B 9:30–10:30 and C 10–11 (1h each). A is 2× the longest
    /// other (≥ 1.5×), both overlap it, and B's column covers only 1h of
    /// A's 2h — so A is the host at full width, hidden 9:30–11 (B and C
    /// merged), and B and C share the right half: a quarter each, one
    /// level up.
    func testThreeWithADominantBlockStackPeek() {
        let p = page([ev("A", at(9), at(11)), ev("B", at(9, 30), at(10, 30)), ev("C", at(10), at(11))])
        assertSlot(p, "A", x: 0, width: 1, covers: [(at(9, 30), at(11))])
        assertSlot(p, "B", x: 0.5, width: 0.25, depth: 1)
        assertSlot(p, "C", x: 0.75, width: 0.25, depth: 1)
        XCTAssertEqual(p.blocks.map(\.occurrence.title), ["A", "B", "C"], "the host is drawn first, under the strip")
    }

    /// Three identical 9–10 blocks: thirds, left to right in the order they
    /// were created (C, then A, then B), not by name or id.
    func testThreeIdenticalRangesSplitInThirdsByCreationOrder() {
        let p = page([ev("A", at(9), at(10), created: 20), ev("B", at(9), at(10), created: 30), ev("C", at(9), at(10), created: 10)])
        assertSlot(p, "C", x: 0, width: 1.0 / 3)
        assertSlot(p, "A", x: 1.0 / 3, width: 1.0 / 3)
        assertSlot(p, "B", x: 2.0 / 3, width: 1.0 / 3)
    }

    /// A 9–10, B 9:30–10:30, C 10–11: A meets B and B meets C, A only
    /// touches C. One cluster of two columns; C reuses A's.
    func testChainedOverlapsShareTwoColumns() {
        let p = page([ev("A", at(9), at(10)), ev("B", at(9, 30), at(10, 30)), ev("C", at(10), at(11))])
        assertSlot(p, "A", x: 0, width: 0.5)
        assertSlot(p, "B", x: 0.5, width: 0.5)
        assertSlot(p, "C", x: 0, width: 0.5)
    }

    /// Two identical 9–10 blocks: the earlier-created on the left, whichever
    /// way round they were made.
    func testIdenticalPairOrdersByCreation() {
        let first = page([ev("A", at(9), at(10), created: 1), ev("B", at(9), at(10), created: 2)])
        assertSlot(first, "A", x: 0, width: 0.5)
        assertSlot(first, "B", x: 0.5, width: 0.5)
        let swapped = page([ev("A", at(9), at(10), created: 2), ev("B", at(9), at(10), created: 1)])
        assertSlot(swapped, "B", x: 0, width: 0.5)
        assertSlot(swapped, "A", x: 0.5, width: 0.5)
    }

    /// Work 9–11 with an interrupt Call 9:30–9:45 embedded in it, and Q
    /// 10–10:30 beside it. The Call takes no column: it sits on Work's slot
    /// one level up. Work (2h) against Q (30m) is a stack-peek host hidden
    /// 10–10:30; Q in the right half. An interrupt whose parent is not on
    /// the day (Ring 13–13:30) is an ordinary block.
    func testInterruptInsideItsParent() {
        let work = ev("Work", at(9), at(11))
        let p = page([work, ev("Call", at(9, 30), at(9, 45), interruptOn: work), ev("Q", at(10), at(10, 30)),
                      ev("Ring", at(13), at(13, 30), parentID: UUID())])
        assertSlot(p, "Work", x: 0, width: 1, covers: [(at(10), at(10, 30))])
        assertSlot(p, "Q", x: 0.5, width: 0.5, depth: 1)
        let call = p.blocks.first { $0.occurrence.title == "Call" }
        XCTAssertEqual(call?.parentID, p.blocks.first { $0.occurrence.title == "Work" }?.id)
        XCTAssertEqual(call?.slot.x, 0)
        XCTAssertEqual(call?.slot.width, 1)
        XCTAssertEqual(call?.slot.zIndex, 2, "over its parent")
        XCTAssertEqual(call?.slot.coverRanges, [], "its title is never pushed aside")
        XCTAssertEqual(p.blocks.last?.occurrence.title, "Call", "drawn on top")
        assertSlot(p, "Ring", x: 0, width: 1)
        XCTAssertNil(p.blocks.first { $0.occurrence.title == "Ring" }?.parentID)
    }

    /// Long 9–12 with a 15-minute Short 10–10:15 inside: 12× longer, so
    /// Long keeps the full width, hidden 10–10:15, and Short sits in the
    /// right half over it.
    func testQuarterHourInsideALongBlock() {
        let p = page([ev("Long", at(9), at(12)), ev("Short", at(10), at(10, 15))])
        assertSlot(p, "Long", x: 0, width: 1, covers: [(at(10), at(10, 15))])
        assertSlot(p, "Short", x: 0.5, width: 0.5, depth: 1)
    }

    /// X 22:00 yesterday – 01:00, Y 00:30–02:00. On today's page X is
    /// 0:00–1:00 (1h) and Y 1.5h: exactly 1.5×, so Y hosts at full width,
    /// hidden where X is drawn (0:00–1:00), and X takes the right half.
    func testCrossMidnight() {
        let x = ev("X", at(0).addingTimeInterval(-2 * 3600), at(1))
        let p = page([x, ev("Y", at(0, 30), at(2))])
        assertSlot(p, "Y", x: 0, width: 1, covers: [(at(0), at(1))])
        assertSlot(p, "X", x: 0.5, width: 0.5, depth: 1)
        XCTAssertEqual(p.blocks.first { $0.occurrence.title == "X" }?.start, dayStart, "clipped at midnight")
    }

    // MARK: - Two running at once

    /// A 9–11 is older in the store than B 9:30–10:30; at 10:00 both run.
    /// Focus mode takes the first in its store: B is listed first here, so
    /// B — not A, the earlier start the watch used to pick. Finish and +15
    /// name B's range and leave A alone. An interrupt covering now (I
    /// 9:50–10:10 on A) beats both, on the phone and here.
    func testTwoRunningAtOnceFollowFocusMode() {
        let a = ev("A", at(9), at(11))
        let b = ev("B", at(9, 30), at(10, 30))
        let store = [b, a]
        let now = at(10)
        let timeline = occurrences(store, now: now)
        let phone = focusCurrentOccurrence(
            in: CalendarLayout.occurrencesForDate(store, date: now, calendar: calendar, now: now), now: now, overrunGrace: 0
        )
        let current = WristStateReducer.current(in: timeline, now: now)
        XCTAssertEqual(phone?.event.id, b.id)
        XCTAssertEqual(current?.eventID, b.id)

        let snapshot = WristSnapshot(generatedAt: now, types: [], occurrences: timeline, receipts: [])
        guard case .active(let shown, _) = WristStateReducer.display(snapshot: snapshot, pending: [], dismissed: [], now: now) else {
            return XCTFail("expected a running session")
        }
        XCTAssertEqual(shown.eventID, b.id)
        // Finish at 10:05 → B ends on the grid at 10:00 (its 15-minute
        // minimum ends 9:45); +15 → B ends 10:45. A keeps 11:00 both times.
        let finish = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: at(10, 5), kind: .finish(eventID: shown.eventID, rangeStart: shown.start, at: at(10, 5))
        ))
        let finished = WristStateReducer.overlaid(snapshot, pending: [finish], now: at(10, 5)).occurrences
        XCTAssertEqual(finished.first { $0.eventID == b.id }?.end, at(10))
        XCTAssertEqual(finished.first { $0.eventID == a.id }?.end, at(11))
        let extend = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: now, kind: .extend(eventID: shown.eventID, rangeStart: shown.start, by: WristTiming.extendStep)
        ))
        let extended = WristStateReducer.overlaid(snapshot, pending: [extend], now: now).occurrences
        XCTAssertEqual(extended.first { $0.eventID == b.id }?.end, at(10, 45))
        XCTAssertEqual(extended.first { $0.eventID == a.id }?.end, at(11))

        let i = ev("I", at(9, 50), at(10, 10), interruptOn: a)
        let withInterrupt = store + [i]
        XCTAssertEqual(WristStateReducer.current(in: occurrences(withInterrupt, now: now), now: now)?.eventID, i.id)
        XCTAssertEqual(focusCurrentOccurrence(
            in: CalendarLayout.occurrencesForDate(withInterrupt, date: now, calendar: calendar, now: now), now: now, overrunGrace: 0
        )?.event.id, i.id)
        // Store order the other way round: A.
        XCTAssertEqual(WristStateReducer.current(in: occurrences([a, b], now: now), now: now)?.eventID, a.id)
    }

    /// A block started on the watch is not in the phone's store yet: it is
    /// last, behind everything the phone ranks.
    func testABlockStartedHereComesAfterThePhonesEvents() {
        let a = ev("A", at(9, 30), at(10, 30))
        var snapshot = WristSnapshot(generatedAt: at(10), types: [], occurrences: occurrences([a], now: at(10)), receipts: [])
        snapshot.types = [WristType(id: UUID(), title: "R", colorHex: "#FFFFFF")]
        let start = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: at(9, 55), kind: .start(eventID: UUID(), typeTitle: "R", start: at(9), end: at(11))
        ))
        let timeline = WristStateReducer.overlaid(snapshot, pending: [start], now: at(10)).occurrences
        XCTAssertEqual(WristStateReducer.current(in: timeline, now: at(10))?.eventID, a.id)
    }

    // MARK: - Drawing next to and across parallel blocks, every zoom

    /// A 9:00–10:10 and B 9:30–10:10 end together, off the grid. A press at
    /// 10:17 is on empty time. Its start lands on their shared edge when
    /// 7 minutes is within the 8pt magnet — 10.9 min at 44pt/h, 7.5 at 64 —
    /// and on the 10:15 grid mark at 88pt/h, where 8pt is 5.45 min.
    func testDraftNextToOverlappedBlocksAtEachZoom() {
        let events = [ev("A", at(9), at(10, 10)), ev("B", at(9, 30), at(10, 10))]
        let blocks = page(events).blocks
        let expected: [WristLocalSettings.Zoom: Date] = [.small: at(10, 10), .medium: at(10, 10), .large: at(10, 15)]
        for zoom in WristLocalSettings.Zoom.allCases {
            let height = 24 * zoom.hourHeight
            let mapping = WristDraftMapping(
                dayStart: dayStart, dayEnd: dayEnd, height: height, edges: blocks.flatMap { [$0.start, $0.end] }
            )
            func y(_ date: Date) -> Double { date.timeIntervalSince(dayStart) / 86_400 * height }
            XCTAssertTrue(mapping.isEmpty(atY: y(at(10, 17)), blocks: blocks), "\(zoom)")
            XCTAssertFalse(mapping.isEmpty(atY: y(at(10, 5)), blocks: blocks), "\(zoom): inside A and B")
            let range = mapping.range(anchorY: y(at(10, 17)), currentY: y(at(11)))
            XCTAssertEqual(range.start, expected[zoom], "\(zoom)")
            XCTAssertEqual(range.end, at(11), "\(zoom)")
        }
    }

    /// While drawing, the page equal-splits like the phone's under a
    /// finger. Without a draft A (70 min) hosts B (40 min): 1.75 ≥ 1.5.
    /// A draft 10:10–11:00 only touches them: full width by itself, and A
    /// and B drop to halves (no host while drawing). A draft 8:30–9:45
    /// reaches into both: draft, A, B in thirds by start.
    func testDraftReflowsParallelBlocks() {
        let events = [ev("A", at(9), at(10, 10)), ev("B", at(9, 30), at(10, 10))]
        let resting = page(events)
        assertSlot(resting, "A", x: 0, width: 1, covers: [(at(9, 30), at(10, 10))])
        assertSlot(resting, "B", x: 0.5, width: 0.5, depth: 1)

        let touching = page(events, draft: (at(10, 10), at(11)))
        XCTAssertEqual(touching.draftSlot, .full)
        assertSlot(touching, "A", x: 0, width: 0.5)
        assertSlot(touching, "B", x: 0.5, width: 0.5)

        let across = page(events, draft: (at(8, 30), at(9, 45)))
        XCTAssertEqual(across.draftSlot?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(across.draftSlot?.width ?? -1, 1.0 / 3, accuracy: 1e-9)
        assertSlot(across, "A", x: 1.0 / 3, width: 1.0 / 3)
        assertSlot(across, "B", x: 2.0 / 3, width: 1.0 / 3)
    }

    // MARK: - Stats under each overlap rule (now = 12:00, 12h elapsed)

    private func figures(_ events: [Event], _ rule: WristOverlapRule) -> WristStatsFigures {
        let payload = CategoryStatsBuilder.payload(events: events, now: at(12), calendar: calendar, colorHex: { "#\($0)" })
        return WristStatsFigures.of(payload, period: .today, asOf: at(12), overlap: rule)
    }

    private func hours(_ events: [Event], _ rule: WristOverlapRule) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: figures(events, rule).categories.map { ($0.name, $0.hours) })
            .filter { $0.value > 0 }
    }

    /// Chained A 9–10, B 9:30–10:30, C 10–11. 9–9:30 A; 9:30–10 A+B;
    /// 10–10:30 B+C; 10:30–11 C. Logged 2h.
    /// split:  A .5+.25, B .25+.25, C .25+.5
    /// full:   1 each, 3 in all
    /// latest: B takes 9:30–10, C takes 10–10:30 → A .5, B .5, C 1
    func testStatsChained() {
        let e = [ev("A", at(9), at(10)), ev("B", at(9, 30), at(10, 30)), ev("C", at(10), at(11))]
        XCTAssertEqual(hours(e, .split), ["A": 0.75, "B": 0.5, "C": 0.75])
        XCTAssertEqual(hours(e, .full), ["A": 1, "B": 1, "C": 1])
        XCTAssertEqual(hours(e, .latestStart), ["A": 0.5, "B": 0.5, "C": 1])
        for rule in WristOverlapRule.allCases {
            XCTAssertEqual(figures(e, rule).loggedHours, 2, "\(rule)")
            XCTAssertEqual(figures(e, rule).unloggedHours, 10, "\(rule)")
        }
    }

    /// Identical A and B 9–10. split .5 each; full 1 each; latest: same
    /// start, same length — the tie goes by name, to A.
    func testStatsIdentical() {
        let e = [ev("A", at(9), at(10)), ev("B", at(9), at(10))]
        XCTAssertEqual(hours(e, .split), ["A": 0.5, "B": 0.5])
        XCTAssertEqual(hours(e, .full), ["A": 1, "B": 1])
        XCTAssertEqual(hours(e, .latestStart), ["A": 1])
        XCTAssertEqual(figures(e, .full).loggedHours, 1)
    }

    /// Work 9–11 with the Call interrupt 9:30–9:45 in it: the Call is cut
    /// out of Work, so nothing overlaps — Work 1.75, Call .25 by every rule.
    func testStatsInterruptInsideParent() {
        let work = ev("Work", at(9), at(11))
        let e = [work, ev("Call", at(9, 30), at(9, 45), interruptOn: work)]
        for rule in WristOverlapRule.allCases {
            XCTAssertEqual(hours(e, rule), ["Work": 1.75, "Call": 0.25], "\(rule)")
            XCTAssertEqual(figures(e, rule).loggedHours, 2, "\(rule)")
        }
    }

    /// Long 9–12, Short 10–10:15. split: Long 2.75 + .125, Short .125;
    /// full: Long 3, Short .25; latest: Short takes its quarter → Long 2.75.
    func testStatsQuarterHourInsideLong() {
        let e = [ev("Long", at(9), at(12)), ev("Short", at(10), at(10, 15))]
        XCTAssertEqual(hours(e, .split), ["Long": 2.875, "Short": 0.125])
        XCTAssertEqual(hours(e, .full), ["Long": 3, "Short": 0.25])
        XCTAssertEqual(hours(e, .latestStart), ["Long": 2.75, "Short": 0.25])
    }

    /// X 22:00 yesterday – 1:00, Y 0:30–2:00; today only: 0–0:30 X,
    /// 0:30–1 X+Y, 1–2 Y. split X .75, Y 1.25; full X 1, Y 1.5; latest: Y
    /// started later → X .5, Y 1.5. Logged 2h.
    func testStatsCrossMidnight() {
        let e = [ev("X", at(0).addingTimeInterval(-2 * 3600), at(1)), ev("Y", at(0, 30), at(2))]
        XCTAssertEqual(hours(e, .split), ["X": 0.75, "Y": 1.25])
        XCTAssertEqual(hours(e, .full), ["X": 1, "Y": 1.5])
        XCTAssertEqual(hours(e, .latestStart), ["X": 0.5, "Y": 1.5])
        XCTAssertEqual(figures(e, .split).loggedHours, 2)
    }

    /// The two that ran at once, A 9–11 and B 9:30–10:30, read at noon:
    /// split A .5 + .5 + .5 = 1.5, B .5; full A 2, B 1; latest: B takes its
    /// hour → A 1, B 1.
    func testStatsTwoRunningAtOnce() {
        let e = [ev("B", at(9, 30), at(10, 30)), ev("A", at(9), at(11))]
        XCTAssertEqual(hours(e, .split), ["A": 1.5, "B": 0.5])
        XCTAssertEqual(hours(e, .full), ["A": 2, "B": 1])
        XCTAssertEqual(hours(e, .latestStart), ["A": 1, "B": 1])
    }

    // MARK: - Motions

    private let on = WristMotionSettings(create: .assemble, delete: .dissolve, resize: .standard)

    private func wrist(_ title: String, eventID: UUID = UUID(), _ start: Date, _ end: Date, series: UUID? = nil, id: String? = nil) -> WristOccurrence {
        WristOccurrence(
            id: id ?? "\(eventID.uuidString)-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)",
            eventID: eventID, title: title, type: title, colorHex: "#0A84FF", start: start, end: end,
            isInterrupt: false, quickActionsEnabled: true, seriesID: series
        )
    }

    private func blocks(_ o: [WristOccurrence]) -> [WristDayBlock] {
        WristDayLayout.blocks(o, dismissed: [], dayStart: dayStart, dayEnd: dayEnd, now: at(15), currentID: nil)
    }

    private func plan(
        _ old: [WristOccurrence], _ new: [WristOccurrence], local: Set<UUID> = [], settings: WristMotionSettings? = nil,
        sameDay: Bool = true, drawing: Bool = false, reduceMotion: Bool = false
    ) -> WristMotionPlan {
        WristMotionPlan.make(
            old: blocks(old), new: blocks(new), oldAll: old, newAll: new, localCreates: local,
            settings: settings ?? on, sameDay: sameDay, drawing: drawing, reduceMotion: reduceMotion
        )
    }

    private func key(_ o: WristOccurrence) -> String { "\(o.eventID.uuidString)#0" }

    /// Drawn here: the pending block plays from the draft; when the phone's
    /// copy replaces it (new id, same event), nothing plays again.
    func testABlockDrawnHereComesFromTheDraftOnce() {
        let a = wrist("A", at(9), at(10))
        let id = UUID()
        let pending = wrist("New", eventID: id, at(9, 30), at(10, 30), id: "pending-\(id.uuidString)")
        let real = wrist("New", eventID: id, at(9, 30), at(10, 30))
        XCTAssertEqual(plan([a], [a, pending], local: [id]).arrivals, [key(pending): .fromDraft])
        let swap = plan([a, pending], [a, real], local: [])
        XCTAssertTrue(swap.isEmpty, "the phone's copy takes the watch's place quietly")
    }

    /// From the phone: up to eight new events play, the first three in the
    /// phone's style and the rest as a fade; nine at once is an import and
    /// none play. An exception instance an edit minted never plays.
    func testArrivalsFromThePhone() {
        let base = wrist("Base", at(1), at(2))
        let two = (0..<2).map { wrist("N\($0)", at(9 + $0), at(10 + $0)) }
        XCTAssertEqual(Set(plan([base], [base] + two).arrivals.values), [.style(.assemble)])
        let five = (0..<5).map { wrist("N\($0)", at(9 + $0), at(10 + $0)) }
        let arrivals = plan([base], [base] + five).arrivals
        XCTAssertEqual(arrivals.values.filter { $0 == .style(.assemble) }.count, 3)
        XCTAssertEqual(arrivals.values.filter { $0 == .fade }.count, 2)
        let nine = (0..<9).map { wrist("N\($0)", at(9 + $0), at(10 + $0)) }
        XCTAssertTrue(plan([base], [base] + nine).arrivals.isEmpty)
        let exception = wrist("Edited", at(9), at(10), series: UUID())
        XCTAssertTrue(plan([base], [base, exception]).arrivals.isEmpty)
        XCTAssertTrue(plan([base], [base] + two, reduceMotion: true).arrivals.values.allSatisfy { $0 == .fade })
    }

    /// Deleted: gone from the snapshot with nothing in its event's place.
    /// Moved to tomorrow, or edited (its id changes with the range), it is
    /// not a deletion.
    func testDepartures() {
        let a = wrist("A", at(9), at(10)), b = wrist("B", at(9, 30), at(10, 30))
        let deleted = plan([a, b], [a])
        XCTAssertEqual(deleted.departures.map(\.block.id), [b.id])
        XCTAssertEqual(deleted.departures.map(\.motion), [.style(.dissolve)])

        let tomorrow = wrist("B", eventID: b.eventID, at(9, 30).addingTimeInterval(86_400), at(10, 30).addingTimeInterval(86_400))
        XCTAssertTrue(plan([a, b], [a, tomorrow]).departures.isEmpty, "moved off the page")
        var moved = b
        moved.start = at(11)
        XCTAssertTrue(plan([a, b], [a, moved]).departures.isEmpty, "same occurrence elsewhere in the window")
        let edited = wrist("B", eventID: b.eventID, at(9, 30), at(11))
        XCTAssertTrue(plan([a, b], [a, edited]).departures.isEmpty, "an edit is not a deletion")

        let series = UUID()
        let one = wrist("S", eventID: series, at(14), at(15), id: "\(series.uuidString)-recur-1")
        let other = wrist("S", eventID: series, at(14).addingTimeInterval(86_400), at(15).addingTimeInterval(86_400), id: "\(series.uuidString)-recur-2")
        XCTAssertEqual(plan([a, one, other], [a, other]).departures.map(\.block.id), [one.id], "one occurrence of a series")
        let exception = wrist("S", eventID: UUID(), at(14), at(16), series: series)
        XCTAssertTrue(plan([a, one, other], [a, other, exception]).departures.isEmpty, "replaced by its exception")
    }

    /// A length change of a minute or more tweens the page; a move that
    /// keeps the length does not, nor anything while drawing.
    func testLengthChangesTween() {
        let a = wrist("A", at(9), at(10)), b = wrist("B", at(9, 30), at(10, 30))
        let longer = wrist("B", eventID: b.eventID, at(9, 30), at(11))
        XCTAssertEqual(plan([a, b], [a, longer]).tween, .standard)
        let shifted = wrist("B", eventID: b.eventID, at(10), at(11))
        XCTAssertNil(plan([a, b], [a, shifted]).tween)
        XCTAssertNil(plan([a, b], [a, longer], drawing: true).tween)
        XCTAssertNil(plan([a, b], [a, longer], reduceMotion: true).tween)
        let slightly = wrist("B", eventID: b.eventID, at(9, 30), at(10, 30).addingTimeInterval(30))
        XCTAssertNil(plan([a, b], [a, slightly]).tween)
    }

    /// The phone's switches: off plays nothing; a new day plays nothing.
    func testSwitchesAndDayChange() {
        let a = wrist("A", at(9), at(10)), b = wrist("B", at(9, 30), at(10, 30))
        XCTAssertTrue(plan([a], [a, b], settings: .off).isEmpty)
        XCTAssertTrue(plan([a, b], [a], settings: .off).isEmpty)
        XCTAssertTrue(plan([a], [b], sameDay: false).isEmpty)
        let resizeOnly = WristMotionSettings(resize: .brisk)
        XCTAssertTrue(plan([a], [a, b], settings: resizeOnly).arrivals.isEmpty)
        XCTAssertEqual(plan([a], [wrist("A", eventID: a.eventID, at(9), at(11))], settings: resizeOnly).tween, .brisk)
    }

    /// The switches cross as the phone's own style names, and every style
    /// the phone has, the watch has.
    func testTheSwitchesCrossTheWire() throws {
        XCTAssertEqual(EventCreationMotionVariant.allCases.map(\.rawValue), WristCreateStyle.allCases.map(\.rawValue))
        XCTAssertEqual(EventDeletionMotionVariant.allCases.map(\.rawValue), WristDeleteStyle.allCases.map(\.rawValue))
        XCTAssertEqual(EventResizeTweenVariant.allCases.map(\.rawValue), WristResizePace.allCases.map(\.rawValue))
        for (watch, phone) in zip(WristResizePace.allCases, EventResizeTweenVariant.allCases) {
            XCTAssertEqual(watch.duration, phone.editDuration, accuracy: 1e-9)
        }
        XCTAssertEqual(WristSnapshotBuilder.motions(create: .pinDrop, delete: .pop, resize: nil),
                       WristMotionSettings(create: .pinDrop, delete: .pop))

        let snapshot = WristSnapshot(generatedAt: at(9), types: [], occurrences: [], receipts: [], motions: on)
        let decoded = try WristWire.decode(WristSnapshot.self, from: WristWire.encode(snapshot))
        XCTAssertEqual(decoded.motions, on)
        let off = WristSnapshot(generatedAt: at(9), types: [], occurrences: [], receipts: [])
        let text = String(decoding: try WristWire.encode(off), as: UTF8.self)
        XCTAssertFalse(text.contains("motions"), "off sends nothing, as a phone without the field")
        XCTAssertEqual(try WristWire.decode(WristSnapshot.self, from: WristWire.encode(off)).motions, .off)
        let unknown = Data(#"{"create":"sparkle","delete":"pop"}"#.utf8)
        XCTAssertEqual(try WristWire.decode(WristMotionSettings.self, from: unknown), WristMotionSettings(delete: .pop))
    }

    /// The layout fields cross the wire and default when missing.
    func testOccurrenceLayoutFieldsCrossTheWire() throws {
        let parent = UUID(), series = UUID()
        let o = WristOccurrence(
            id: "x", eventID: UUID(), title: "t", type: "t", colorHex: "#000000", start: at(9), end: at(10),
            isInterrupt: true, quickActionsEnabled: true, createdAt: at(1), seriesID: series,
            interruptParentID: parent
        )
        let back = try WristWire.decode(WristOccurrence.self, from: WristWire.encode(o))
        XCTAssertEqual(back, o)
        XCTAssertEqual(back.anchorID, series)
        var bare = o
        bare.createdAt = nil
        bare.seriesID = nil
        bare.interruptParentID = nil
        let text = String(decoding: try WristWire.encode(bare), as: UTF8.self)
        XCTAssertFalse(text.contains("interruptParentID") || text.contains("seriesID") || text.contains("createdAt"))
        XCTAssertEqual(try WristWire.decode(WristOccurrence.self, from: WristWire.encode(bare)), bare)
    }
}
