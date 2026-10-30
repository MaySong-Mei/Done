import XCTest
@testable import Done

/// The crown on the watch's event page, as data (`WristEndCrown`): which
/// events it moves, the stops it moves the end through — every one an end
/// the phone keeps as it is — the limits, what it sends, and how it rides
/// out the day changing under a turn. Ported from the lifted block's
/// tests (`watch/hold-plus-namelater`), which pinned bugs already found.
final class WristEndCrownTests: XCTestCase {
    /// 2026-03-10 00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    private func at(_ hours: Double) -> Date { dayStart.addingTimeInterval(hours * 3600) }
    private func at(_ hour: Int, _ minute: Int) -> Date { dayStart.addingTimeInterval(Double(hour * 3600 + minute * 60)) }

    private func crown(
        _ start: Date, _ end: Date, current: Bool = false, openEnded: Bool = false, quick: Bool = true,
        takesEdits: Bool = true, now: Date? = nil, edges: [Date] = []
    ) -> WristEndCrown.Availability {
        WristEndCrown.availability(
            start: start, end: end, isOpenEnded: openEnded, quickActionsEnabled: quick, isRunning: current,
            takesRangeEdits: takesEdits, dayStart: dayStart, dayEnd: dayEnd, now: now ?? at(6), edges: edges
        )
    }

    private func endCrown(
        _ start: Date, _ end: Date, current: Bool = false, takesEdits: Bool = true, now: Date? = nil,
        edges: [Date] = [], file: StaticString = #filePath, line: UInt = #line
    ) -> WristEndCrown {
        guard case .moves(let config) = crown(start, end, current: current, takesEdits: takesEdits, now: now, edges: edges) else {
            XCTFail("the crown should move this block", file: file, line: line)
            return WristEndCrown(.init(start: start, end: end, floor: end, ceiling: end, edges: []))
        }
        return WristEndCrown(config)
    }

    /// Turns `detents` (signed) and returns the targets after each.
    private func turn(_ lift: inout WristEndCrown, _ detents: Int) -> [Date] {
        (0..<abs(detents)).map { _ in
            _ = lift.turn(detents > 0 ? 1 : -1)
            return lift.target
        }
    }

    // MARK: Which blocks

    func testTheCrownMovesAnEditableEventsEndAndRefusesTheRest() {
        XCTAssertEqual(crown(at(10), at(11), quick: false), .refused(.notEditable), "repeating")
        XCTAssertEqual(crown(at(10), at(11), current: true, openEnded: true, quick: false), .refused(.notEditable), "phone timer")
        XCTAssertEqual(crown(at(10), at(11), openEnded: true), .refused(.notEditable), "open-ended, however marked")
        XCTAssertEqual(crown(at(10), at(11), takesEdits: false), .refused(.phoneTooOld))
        XCTAssertEqual(crown(at(23), at(25)), .refused(.endsAnotherDay), "its end is tomorrow's")
        guard case .moves = crown(at(10), at(11)) else { return XCTFail() }
        // The running session on a phone from before range edits: no crown
        // editing either (the page keeps +15 and Finish).
        XCTAssertEqual(crown(at(10), at(11), current: true, takesEdits: false), .refused(.phoneTooOld))
    }

    // MARK: Stops

    func testAnOnGridEndMovesAQuarterHourADetentBothWays() {
        var l = endCrown(at(10), at(11))
        XCTAssertEqual(l.target, at(11))
        XCTAssertEqual(turn(&l, 3), [at(11.25), at(11.5), at(11.75)])
        XCTAssertEqual(turn(&l, -5), [at(11.5), at(11.25), at(11), at(10.75), at(10.5)])
    }

    /// From 10:07 the first detent goes to the grid mark that way, then a
    /// quarter hour a detent, as the phone's grid has them.
    func testAnOffGridEndGoesToTheNextGridMarkInTheDirectionTurned() {
        var later = endCrown(at(9), at(10, 7))
        XCTAssertEqual(turn(&later, 2), [at(10, 15), at(10, 30)])
        XCTAssertEqual(turn(&later, -2), [at(10, 15), at(10, 7)], "the end it had is a stop on the way back")
        var earlier = endCrown(at(9), at(10, 7))
        XCTAssertEqual(turn(&earlier, -2), [at(10, 0), at(9, 45)])
    }

    func testANeighboursEdgeIsAStop() {
        var l = endCrown(at(10), at(11), edges: [at(11, 10), at(12, 0), at(9, 0)])
        XCTAssertEqual(turn(&l, 3), [at(11, 10), at(11, 15), at(11, 30)])
    }

    /// Never shorter than the shortest event: a block off the grid stops at
    /// exactly that length.
    func testTheFloorIsTheShortestLengthAndPastItIsALimit() {
        var l = endCrown(at(10), at(10.5))
        XCTAssertEqual(l.turn(-1), .moved)
        XCTAssertEqual(l.target, at(10.25))
        XCTAssertEqual(l.turn(-1), .limit)
        XCTAssertEqual(l.target, at(10.25))
        // Back out at once: pushing past the limit leaves nothing to undo.
        XCTAssertEqual(l.turn(1), .moved)
        XCTAssertEqual(l.target, at(10.5))

        var offGrid = endCrown(at(10, 7), at(11))
        XCTAssertEqual(turn(&offGrid, -4), [at(10, 45), at(10, 30), at(10, 22), at(10, 22)])
        XCTAssertEqual(offGrid.target.timeIntervalSince(at(10, 7)), WristTiming.minimumDuration)
    }

    /// A block already under the shortest length (the phone allows one)
    /// only grows.
    func testABlockShorterThanTheMinimumOnlyGrows() {
        var l = endCrown(at(10), at(10, 5))
        XCTAssertEqual(l.turn(-1), .limit)
        XCTAssertEqual(turn(&l, 2), [at(10, 15), at(10, 30)])
    }

    func testTheEndNeverPassesMidnight() {
        var l = endCrown(at(23), at(23.5))
        XCTAssertEqual(turn(&l, 2), [at(23.75), dayEnd])
        XCTAssertEqual(l.turn(1), .limit)
        XCTAssertEqual(l.target, dayEnd)
    }

    /// In from yesterday: the end moves, and a quarter hour stays on the
    /// page.
    func testABlockFromYesterdayKeepsAQuarterHourOnThePage() {
        var l = endCrown(at(-1), at(0.5))
        XCTAssertEqual(turn(&l, -3), [at(0.25), at(0.25), at(0.25)])
    }

    /// The running session is not ended by the crown — Finish does that.
    /// The page's `now` lags the real time by up to a minute, so the end
    /// stays on a mark at least a quarter hour after it.
    func testARunningSessionsEndStaysAQuarterHourAhead() {
        var l = endCrown(at(10), at(10.5), current: true, now: at(10, 16))
        XCTAssertEqual(l.turn(-1), .limit, "10:45 is the first mark a quarter hour after 10:16")
        var early = endCrown(at(10), at(10.75), current: true, now: at(10, 14))
        XCTAssertEqual(turn(&early, -2), [at(10.5), at(10.5)])
        var onMark = endCrown(at(10), at(10.75), current: true, now: at(10, 15))
        XCTAssertEqual(turn(&onMark, -2), [at(10.5), at(10.5)])
        XCTAssertEqual(WristEndCrown.runningFloor(at(10, 15)), at(10, 30))
        XCTAssertEqual(WristEndCrown.runningFloor(at(10, 14)), at(10, 30))
        XCTAssertEqual(WristEndCrown.runningFloor(at(10, 16)), at(10, 45))
    }

    /// The page's minute is 10:14 but the real time is 10:14:50 and the
    /// send goes much later: what is sent still ends ahead of the real time.
    func testARunningSessionsSendIsCheckedAgainstTheRealTime() {
        var l = endCrown(at(10), at(11), current: true, now: at(10, 14))
        _ = turn(&l, -2)
        XCTAssertEqual(l.target, at(10.5))
        XCTAssertEqual(l.takeUnsent(now: at(10, 14).addingTimeInterval(50)), WristTimeSpan(start: at(10), end: at(10.5)),
                       "fifteen minutes ahead: sent as turned")
        var late = endCrown(at(10), at(11), current: true, now: at(10, 14))
        _ = turn(&late, -2)
        // The page stayed up, the crown rested only at 10:29:30.
        XCTAssertEqual(late.takeUnsent(now: at(10, 29).addingTimeInterval(30)), WristTimeSpan(start: at(10), end: at(10.75)),
                       "no longer ahead: the first stop a quarter hour after the real time")
        var notRunning = endCrown(at(10), at(11))
        _ = turn(&notRunning, -2)
        XCTAssertEqual(notRunning.takeUnsent(now: at(12)), WristTimeSpan(start: at(10), end: at(10.5)), "only a running session")
    }

    /// A turn down on a running session, waiting for the crown to rest,
    /// when the minute ticks and the floor passes it: no stop is left below
    /// the end, so the turn goes back to the end — never up to an extension.
    func testAKeptShorteningNeverBecomesAnExtension() {
        var l = endCrown(at(10), at(11), current: true, now: at(10, 30))
        XCTAssertEqual(l.config.floor, at(10, 45))
        XCTAssertEqual(turn(&l, -1), [at(10, 45)])
        guard case .moves(let ticked) = crown(at(10), at(11), current: true, now: at(10, 31)) else { return XCTFail() }
        XCTAssertEqual(ticked.floor, at(11))
        l.update(ticked)
        XCTAssertEqual(l.target, at(11), "back to the end")
        XCTAssertFalse(l.hasUnsent)
        XCTAssertNil(l.takeUnsent(now: at(10, 31)), "nothing sent")
    }

    /// A turn later onto a neighbour's edge, the neighbour moves and leaves
    /// no stop above the end: back to the end — never down to a shortening.
    func testAKeptExtensionNeverBecomesAShortening() {
        var l = endCrown(at(23), at(23.75), edges: [at(23, 50)])
        XCTAssertEqual(turn(&l, 1), [at(23, 50)])
        // The block's end moves to midnight on the phone, a neighbour's edge
        // goes: nothing is left above it.
        guard case .moves(let moved) = crown(at(23), at(24), edges: []) else { return XCTFail() }
        l.update(moved)
        XCTAssertEqual(l.target, at(24))
        XCTAssertNil(l.takeUnsent())
        // With stops still above, the nearest of those.
        var up = endCrown(at(10), at(11), edges: [at(11, 10)])
        XCTAssertEqual(turn(&up, 1), [at(11, 10)])
        guard case .moves(let gone) = crown(at(10), at(11), edges: []) else { return XCTFail() }
        up.update(gone)
        XCTAssertEqual(up.target, at(11, 15))
        var down = endCrown(at(10), at(11), edges: [at(10, 50)])
        XCTAssertEqual(turn(&down, -1), [at(10, 50)])
        guard case .moves(let gone2) = crown(at(10), at(11), edges: []) else { return XCTFail() }
        down.update(gone2)
        XCTAssertEqual(down.target, at(10, 45), "the nearest below, not 11:00's other side")
        // The way the turn went is kept against the NEW end: shortened from
        // 11:00 to 10:15, then the phone makes the block 10:10–10:17 — every
        // end the phone keeps for it is later than 10:17, so the turn is
        // dropped rather than sent as a lengthening.
        var shortened = endCrown(at(10), at(11))
        _ = turn(&shortened, -3)
        XCTAssertEqual(shortened.anchor, at(11))
        guard case .moves(let squeezed) = crown(at(10, 10), at(10, 17)) else { return XCTFail() }
        shortened.update(squeezed)
        XCTAssertEqual(shortened.target, at(10, 17))
        XCTAssertFalse(shortened.hasUnsent)
    }

    /// A later turn not sent, and the phone moves the end to it or past it:
    /// the turn is done (or overtaken) — dropped, never sent as a shortening.
    /// The same for an earlier turn the phone undercuts. A move that leaves
    /// the turn ahead of the new end keeps it.
    func testAKeptTurnStaysOnItsSideOfTheNewEnd() {
        var later = endCrown(at(10), at(11))
        _ = turn(&later, 1)
        guard case .moves(let past) = crown(at(10), at(11.5)) else { return XCTFail() }
        later.update(past)
        XCTAssertEqual(later.target, at(11.5))
        XCTAssertNil(later.takeUnsent())

        var reached = endCrown(at(10), at(11))
        _ = turn(&reached, 1)
        guard case .moves(let onIt) = crown(at(10), at(11.25)) else { return XCTFail() }
        reached.update(onIt)
        XCTAssertNil(reached.takeUnsent())

        var earlier = endCrown(at(10), at(12))
        _ = turn(&earlier, -1)
        guard case .moves(let under) = crown(at(10), at(11)) else { return XCTFail() }
        earlier.update(under)
        XCTAssertEqual(earlier.target, at(11))
        XCTAssertNil(earlier.takeUnsent())

        var ahead = endCrown(at(10), at(11))
        _ = turn(&ahead, 3)
        guard case .moves(let short) = crown(at(10), at(11.25)) else { return XCTFail() }
        ahead.update(short)
        XCTAssertEqual(ahead.takeUnsent(), WristTimeSpan(start: at(10), end: at(11.75)))
    }

    /// At send time the real time has passed the turned end of a running
    /// session: the first stop the real time allows is above the end, which
    /// would lengthen what was shortened — nothing is sent.
    func testTheSendRecheckNeverTurnsAShorteningIntoAnExtension() {
        var l = endCrown(at(10), at(11), current: true, now: at(10, 30))
        XCTAssertEqual(turn(&l, -1), [at(10, 45)])
        XCTAssertNil(l.takeUnsent(now: at(10, 44).addingTimeInterval(30)))
        XCTAssertEqual(l.target, at(11))
        XCTAssertFalse(l.hasUnsent)
        // Still room below the end at the real time: the first stop that is.
        var room = endCrown(at(10), at(12), current: true, now: at(10, 0))
        XCTAssertEqual(turn(&room, -6), [at(11.75), at(11.5), at(11.25), at(11), at(10.75), at(10.5)])
        XCTAssertEqual(room.takeUnsent(now: at(10, 29).addingTimeInterval(30)), WristTimeSpan(start: at(10), end: at(10.75)))
    }

    /// The phone answered a send the day never showed (the overlay could
    /// not apply it, then the phone refused it): released, the preview goes
    /// back to the block's end, and nothing is resent.
    func testReleaseLetsGoOfASendTheDayNeverShowed() {
        var l = endCrown(at(10), at(11))
        _ = turn(&l, 2)
        _ = l.takeUnsent()
        XCTAssertTrue(l.inFlight)
        l.release()
        XCTAssertEqual(l.target, at(11))
        XCTAssertNil(l.sent)
        XCTAssertNil(l.takeUnsent())
        // A newer turn waiting to go is not dropped by a release.
        var newer = endCrown(at(10), at(11))
        _ = turn(&newer, 1)
        _ = newer.takeUnsent()
        _ = turn(&newer, 1)
        newer.release()
        XCTAssertEqual(newer.target, at(11.5))
        XCTAssertTrue(newer.hasUnsent)
    }

    /// Off-grid starts whose shortest end the phone would round: the
    /// shortest stop is the first grid mark past it instead.
    func testAShortestEndThePhoneWouldRoundIsNoStop() {
        var l = endCrown(at(10, 8), at(12))
        while l.turn(-1) == .moved {}
        XCTAssertEqual(l.target, at(10, 30))
        var kept = endCrown(at(10, 8), at(10, 53))
        while kept.turn(-1) == .moved {}
        XCTAssertEqual(kept.target, at(10, 23), "a whole number of quarter hours from the end: kept")
    }

    /// Every stop is an end the phone keeps as it is, so the preview is
    /// what the phone will store (`WristRangeEdit`, the rule both share).
    func testEveryStopIsAnEndThePhoneKeeps() {
        let blocks: [(Date, Date, [Date])] = [
            (at(10), at(11), []),
            (at(10, 7), at(11, 0), []),
            (at(10, 0), at(10, 52), []),
            (at(10, 7), at(10, 52), [at(12, 4), at(9, 58)]),
            (at(-1), at(0, 40), [at(1, 3)]),
            (at(22, 50), at(23, 20), []),
        ]
        for (start, end, edges) in blocks {
            let l = endCrown(start, end, edges: edges)
            for stop in l.stops {
                let settled = WristRangeEdit.settled(
                    original: WristTimeSpan(start: start, end: end),
                    requested: WristTimeSpan(start: start, end: stop), edges: edges
                )
                XCTAssertEqual(settled, WristTimeSpan(start: start, end: stop), "\(start)…\(end) → \(stop)")
            }
        }
    }

    // MARK: Sending

    func testTheChangeIsSentOnceAndNotWhenTurnedBack() {
        var l = endCrown(at(10), at(11))
        XCTAssertNil(l.takeUnsent(), "nothing turned")
        _ = turn(&l, 2)
        XCTAssertTrue(l.hasUnsent)
        XCTAssertEqual(l.takeUnsent(), WristTimeSpan(start: at(10), end: at(11.5)))
        XCTAssertFalse(l.hasUnsent)
        XCTAssertNil(l.takeUnsent())
        _ = turn(&l, -2)
        XCTAssertFalse(l.hasUnsent, "back on the block's end: nothing to send")
    }

    // MARK: The day changing under a turn

    /// The send lands: the turn goes on from the block's new end.
    func testALandedSendBecomesTheNewEnd() {
        var l = endCrown(at(10), at(11))
        _ = turn(&l, 2)
        _ = l.takeUnsent()
        var landed = l.config
        landed.end = at(11.5)
        l.update(landed)
        XCTAssertEqual(l.target, at(11.5))
        XCTAssertNil(l.sent)
        XCTAssertFalse(l.hasUnsent)
        XCTAssertEqual(turn(&l, 1), [at(11.75)])
    }

    /// The phone refused it: the block's end goes back, and the preview
    /// with it.
    func testARefusedSendPutsThePreviewBack() {
        var l = endCrown(at(10), at(11))
        _ = turn(&l, 2)
        _ = l.takeUnsent()
        var landed = l.config
        landed.end = at(11.5)
        l.update(landed)
        var refused = landed
        refused.end = at(11)
        l.update(refused)
        XCTAssertEqual(l.target, at(11))
        XCTAssertFalse(l.hasUnsent)
    }

    /// The block's end changes mid-turn (the phone moved it, or an earlier
    /// send landed): the time being turned to is kept, and sent.
    func testAnUnsentChangeKeepsItsTimeWhenTheEndMovesUnderIt() {
        var l = endCrown(at(10), at(11))
        _ = turn(&l, 3)
        var moved = l.config
        moved.end = at(11.5)
        l.update(moved)
        XCTAssertEqual(l.target, at(11.75))
        XCTAssertTrue(l.hasUnsent)
        XCTAssertEqual(l.takeUnsent(), WristTimeSpan(start: at(10), end: at(11.75)))
        // Turning on counts from the kept time.
        XCTAssertEqual(turn(&l, 1), [at(12)])
    }

    /// Sent, but the day has not caught up yet when something else changes
    /// (a minute passed): the preview stays on what was sent.
    func testASentChangeWaitsForTheDay() {
        var l = endCrown(at(10), at(10.5), current: true, now: at(10, 2))
        _ = turn(&l, 2)
        _ = l.takeUnsent()
        guard case .moves(let ticked) = crown(at(10), at(10.5), current: true, now: at(10, 16)) else { return XCTFail() }
        XCTAssertNotEqual(ticked, l.config, "the floor moved on")
        l.update(ticked)
        XCTAssertEqual(l.target, at(11))
    }

    /// A minute passing does not reset a turn of the running session.
    func testAMinutePassingKeepsATurn() {
        var l = endCrown(at(10), at(10.5), current: true, now: at(10, 2))
        _ = turn(&l, 1)
        guard case .moves(let ticked) = crown(at(10), at(10.5), current: true, now: at(10, 16)) else { return XCTFail() }
        XCTAssertNotEqual(ticked, l.config, "the floor moved on")
        l.update(ticked)
        XCTAssertEqual(l.target, at(10.75))
        XCTAssertTrue(l.hasUnsent)
        // Still nothing past the floor once now passes a mark.
        guard case .moves(let later) = crown(at(10), at(10.5), current: true, now: at(10, 20)) else { return XCTFail() }
        var idle = endCrown(at(10), at(10.5), current: true, now: at(10, 2))
        idle.update(later)
        XCTAssertEqual(idle.turn(-1), .limit)
    }

    /// A kept time the new limits rule out goes to the nearest stop within
    /// them.
    func testAKeptTimeOutsideTheNewLimitsComesInside() {
        var l = endCrown(at(10), at(11))
        _ = turn(&l, -2)
        XCTAssertEqual(l.target, at(10.5))
        var later = l.config
        // The phone moved the block's start: 10:30 is now under the minimum.
        later.start = at(10, 30)
        later.floor = at(10, 45)
        l.update(later)
        XCTAssertGreaterThanOrEqual(l.target, at(10, 45))
        XCTAssertTrue(l.stops.allSatisfy { $0 >= at(10, 45) || $0 == later.end })
    }


    // MARK: The crown's sign

    /// The sign lives in one constant: a delta in the crown's "later" sign
    /// makes the end later, whatever the constant is.
    func testTheCrownsLaterSignMakesTheEndLater() {
        XCTAssertEqual(abs(WristEndCrown.crownLater), 1)
        XCTAssertEqual(WristEndCrown.direction(ofCrownDelta: 3 * WristEndCrown.crownLater), 1)
        XCTAssertEqual(WristEndCrown.direction(ofCrownDelta: -WristEndCrown.crownLater), -1)
        XCTAssertEqual(WristEndCrown.direction(ofCrownDelta: 0), 0)
    }
}

/// The event page's subject (`WristEventSubject`) and its crown across
/// subjects (`WristEndCrownSession`): selected, else running, else none; a
/// turn belongs to the subject it was made on.
final class WristEndCrownSessionTests: XCTestCase {
    /// 2026-03-10 00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }
    private func at(_ hours: Double) -> Date { dayStart.addingTimeInterval(hours * 3600) }

    private func occurrence(
        _ n: Int, _ start: Double, _ end: Double, quick: Bool = true, openEnded: Bool = false
    ) -> WristOccurrence {
        WristOccurrence(
            id: "o\(n)-\(start)-\(end)", eventID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            title: "E\(n)", type: "T", colorHex: "#0A84FF", start: at(start), end: at(end),
            isInterrupt: false, quickActionsEnabled: quick, isOpenEnded: openEnded
        )
    }

    private func blocks(_ occurrences: [WristOccurrence], now: Double = 10.5, currentID: String? = nil) -> [WristDayBlock] {
        WristDayLayout.blocks(occurrences, dismissed: [], dayStart: dayStart, dayEnd: dayEnd, now: at(now), currentID: currentID)
    }

    private func availability(_ subject: WristEventSubject?, _ blocks: [WristDayBlock], now: Double = 10.5, takesEdits: Bool = true) -> WristEndCrown.Availability? {
        subject.map {
            WristEndCrown.availability(for: $0, blocks: blocks, takesRangeEdits: takesEdits, dayStart: dayStart, dayEnd: dayEnd, now: at(now))
        }
    }

    // MARK: Subject

    func testTheSelectedBlockIsTheSubjectElseTheRunningSessionElseNone() {
        let work = occurrence(1, 9, 11), gym = occurrence(2, 12, 13)
        let day = blocks([work, gym], currentID: work.id)
        let gymKey = day.first { $0.occurrence.id == gym.id }!.motionKey
        let selected = WristEventSubject.resolve(selectedKey: gymKey, blocks: day, running: work)
        XCTAssertEqual(selected?.source, .selected)
        XCTAssertEqual(selected?.occurrence, gym)
        XCTAssertEqual(selected?.isRunning, false)

        let running = WristEventSubject.resolve(selectedKey: nil, blocks: day, running: work)
        XCTAssertEqual(running?.source, .running)
        XCTAssertEqual(running?.occurrence, work)
        XCTAssertEqual(running?.isRunning, true)
        XCTAssertEqual(running?.key, day.first { $0.occurrence.id == work.id }!.motionKey, "the running block's own key")

        XCTAssertNil(WristEventSubject.resolve(selectedKey: nil, blocks: day, running: nil))
    }

    func testSelectingTheRunningBlockIsTheRunningSubject() {
        let work = occurrence(1, 9, 11)
        let day = blocks([work], currentID: work.id)
        let subject = WristEventSubject.resolve(selectedKey: day[0].motionKey, blocks: day, running: work)
        XCTAssertEqual(subject?.source, .selected)
        XCTAssertEqual(subject?.isRunning, true)
        XCTAssertEqual(subject?.key, WristEventSubject.resolve(selectedKey: nil, blocks: day, running: work)?.key,
                       "the same subject whichever way it was reached")
    }

    /// A selection gone from the day falls back to the running session, or
    /// to none.
    func testASelectionGoneFromTheDayFallsBack() {
        let work = occurrence(1, 9, 11)
        let day = blocks([work])
        XCTAssertNil(WristEventSubject.resolve(selectedKey: "gone#0", blocks: day, running: nil))
        XCTAssertEqual(WristEventSubject.resolve(selectedKey: "gone#0", blocks: day, running: work)?.source, .running)
    }

    func testNeighbourEdgesAreTheOtherBlocksOwnRangesAndATimersStartOnly() {
        let me = occurrence(1, 9, 11), other = occurrence(2, 10.5, 12), timer = occurrence(3, 8, 30, openEnded: true)
        let day = blocks([me, other, timer], now: 10.5)
        let key = day.first { $0.occurrence.id == me.id }!.motionKey
        XCTAssertEqual(Set(WristEventSubject.neighbourEdges(of: key, in: day)), [at(10.5), at(12), at(8)])
    }

    func testTheRunningSubjectsEndHasAFloorAheadOfNow() {
        let work = occurrence(1, 9, 11)
        let day = blocks([work], currentID: work.id)
        let subject = WristEventSubject.resolve(selectedKey: nil, blocks: day, running: work)
        guard case .moves(let config)? = availability(subject, day, now: 10.5) else { return XCTFail() }
        XCTAssertTrue(config.running)
        XCTAssertEqual(config.floor, at(10.75))
        XCTAssertEqual(availability(subject, day, takesEdits: false), .refused(.phoneTooOld))
        let repeating = occurrence(4, 13, 14, quick: false)
        let day2 = blocks([repeating])
        XCTAssertEqual(availability(WristEventSubject.resolve(selectedKey: day2[0].motionKey, blocks: day2, running: nil), day2),
                       .refused(.notEditable))
    }

    // MARK: Session

    private func shown(_ occurrences: [WristOccurrence], select n: Int?, running: WristOccurrence? = nil, session: inout WristEndCrownSession) -> (WristEventSubject?, Bool) {
        let day = blocks(occurrences, currentID: running?.id)
        let key = n.flatMap { n in day.first { $0.occurrence.title == "E\(n)" }?.motionKey }
        let subject = WristEventSubject.resolve(selectedKey: key, blocks: day, running: running)
        let dropped = session.show(subject, availability: availability(subject, day))
        return (subject, dropped)
    }

    func testDetentsMoveTheEndAndOneSendGoesAtRest() {
        var session = WristEndCrownSession()
        let e1 = occurrence(1, 9, 11)
        _ = shown([e1], select: 1, session: &session)
        XCTAssertEqual(session.shownEnd, at(11))
        XCTAssertEqual(session.turn(crownDelta: WristEndCrown.crownLater)?.moved, true)
        XCTAssertEqual(session.turn(crownDelta: 2 * WristEndCrown.crownLater)?.moved, true, "a delta of two is two stops")
        XCTAssertEqual(session.shownEnd, at(11.75))
        XCTAssertEqual(session.takeUnsent(now: at(10)), .init(occurrence: e1, start: at(9), end: at(11.75)))
        XCTAssertNil(session.takeUnsent(now: at(10)), "once")
    }

    func testNothingToMoveWithNoSubjectOrAnUneditableOne() {
        var session = WristEndCrownSession()
        XCTAssertNil(session.turn(crownDelta: 1))
        _ = shown([occurrence(1, 9, 11, quick: false)], select: 1, session: &session)
        XCTAssertNil(session.crown)
        XCTAssertNil(session.turn(crownDelta: 1))
        XCTAssertEqual(session.shownEnd, at(11))
    }

    /// The subject becomes another event mid-turn: the unsent turn is
    /// dropped, never sent for the new subject, and the new one starts
    /// from its own end.
    func testASubjectChangeMidTurnDropsTheTurn() {
        var session = WristEndCrownSession()
        let e1 = occurrence(1, 9, 11), e2 = occurrence(2, 12, 13)
        _ = shown([e1, e2], select: 1, session: &session)
        _ = session.turn(crownDelta: 2)
        let (_, dropped) = shown([e1, e2], select: 2, session: &session)
        XCTAssertTrue(dropped)
        XCTAssertEqual(session.occurrence, e2)
        XCTAssertEqual(session.shownEnd, at(13))
        XCTAssertNil(session.takeUnsent(now: at(10)))
    }

    /// The selected event leaves the day mid-turn, with a session running:
    /// the page falls back to it, and the turn is not applied to it.
    func testTheEventVanishingMidTurnFallsBackWithoutTheTurn() {
        var session = WristEndCrownSession()
        let e1 = occurrence(1, 12, 13), running = occurrence(2, 10, 11)
        _ = shown([e1, running], select: 1, running: running, session: &session)
        _ = session.turn(crownDelta: -1)
        let (subject, dropped) = shown([running], select: 1, running: running, session: &session)
        XCTAssertEqual(subject?.source, .running)
        XCTAssertTrue(dropped)
        XCTAssertNil(session.takeUnsent(now: at(10.5)))
        XCTAssertEqual(session.shownEnd, at(11))
    }

    /// The phone moves the subject's end mid-turn: same subject, the turn
    /// keeps its time and its direction.
    func testThePhoneMovingTheSubjectKeepsTheTurn() {
        var session = WristEndCrownSession()
        _ = shown([occurrence(1, 9, 11)], select: 1, session: &session)
        _ = session.turn(crownDelta: 3)
        let moved = occurrence(1, 9, 11.5)
        let (_, dropped) = shown([moved], select: 1, session: &session)
        XCTAssertFalse(dropped)
        XCTAssertEqual(session.shownEnd, at(11.75))
        XCTAssertEqual(session.takeUnsent(now: at(10))?.end, at(11.75))
        XCTAssertEqual(session.takeUnsent(now: at(10)), nil)
    }

    /// The same event stops being one the crown moves (now repeating): the
    /// phone would refuse the turn, so it is dropped.
    func testASubjectBecomingUneditableDropsTheTurn() {
        var session = WristEndCrownSession()
        _ = shown([occurrence(1, 9, 11)], select: 1, session: &session)
        _ = session.turn(crownDelta: 1)
        let (_, dropped) = shown([occurrence(1, 9, 11, quick: false)], select: 1, session: &session)
        XCTAssertTrue(dropped)
        XCTAssertNil(session.crown)
        XCTAssertNil(session.takeUnsent(now: at(10)))
    }

    /// The phone adds a range of the same event before the selected one:
    /// the motion keys shift, the range does not — the turn stays on the
    /// range it was made on, and the selection follows the range.
    func testAnotherRangeOfTheEventArrivingKeepsTheTurnOnItsRange() {
        let morning = occurrence(1, 10, 11), afternoon = occurrence(1, 14, 15)
        var session = WristEndCrownSession()
        let day = blocks([morning, afternoon])
        let selection = WristEventSubject.Selection(afternoon)
        var subject = WristEventSubject.resolve(selection: selection, blocks: day, running: nil)
        session.show(subject, availability: availability(subject, day))
        _ = session.turn(crownDelta: 1)
        let early = occurrence(1, 8, 9)
        let day2 = blocks([early, morning, afternoon])
        XCTAssertNotEqual(day2.first { $0.occurrence.id == afternoon.id }?.motionKey, subject?.key, "the motion key moved")
        subject = WristEventSubject.resolve(selection: selection, blocks: day2, running: nil)
        XCTAssertEqual(subject?.occurrence, afternoon)
        XCTAssertFalse(session.show(subject, availability: availability(subject, day2)))
        XCTAssertEqual(session.takeUnsent(now: at(10)), .init(occurrence: afternoon, start: at(14), end: at(15.25)))
    }

    /// Named by its old motion key, the subject is now another range: the
    /// turn is dropped, not sent for that range.
    func testATurnIsNeverSentForAnotherRangeOfTheEvent() {
        let morning = occurrence(1, 10, 11), afternoon = occurrence(1, 14, 15)
        var session = WristEndCrownSession()
        let day = blocks([morning, afternoon])
        let key = day.first { $0.occurrence.id == afternoon.id }!.motionKey
        var subject = WristEventSubject.resolve(selectedKey: key, blocks: day, running: nil)
        session.show(subject, availability: availability(subject, day))
        _ = session.turn(crownDelta: 1)
        let day2 = blocks([occurrence(1, 8, 9), morning, afternoon])
        subject = WristEventSubject.resolve(selectedKey: key, blocks: day2, running: nil)
        XCTAssertEqual(subject?.occurrence, morning, "the old key names another range now")
        XCTAssertTrue(session.show(subject, availability: availability(subject, day2)))
        XCTAssertNil(session.takeUnsent(now: at(10)))
    }

    /// A block this watch created that the phone has not reflected yet is
    /// no magnet: the phone does not know its edges.
    func testLocalCreatesLendNoEdges() {
        let me = occurrence(1, 9, 11), mine = occurrence(2, 11.1, 12)
        let day = blocks([me, mine])
        let key = day.first { $0.occurrence.id == me.id }!.motionKey
        XCTAssertTrue(WristEventSubject.neighbourEdges(of: key, in: day).contains(at(11.1)))
        XCTAssertEqual(WristEventSubject.neighbourEdges(of: key, in: day, localCreates: [mine.eventID]), [])
        let subject = WristEventSubject.resolve(selectedKey: key, blocks: day, running: nil)!
        guard case .moves(let config) = WristEndCrown.availability(
            for: subject, blocks: day, takesRangeEdits: true, dayStart: dayStart, dayEnd: dayEnd, now: at(8),
            localCreates: [mine.eventID]
        ) else { return XCTFail() }
        XCTAssertFalse(WristEndCrown(config).stops.contains(at(11.1)))
    }

    func testFinishLetsGoOfAnUnsentTurn() {
        var session = WristEndCrownSession()
        let running = occurrence(1, 9, 11)
        _ = shown([running], select: nil, running: running, session: &session)
        _ = session.turn(crownDelta: 2)
        session.discardUnsent()
        XCTAssertEqual(session.shownEnd, at(11))
        XCTAssertNil(session.takeUnsent(now: at(10)))
    }

    /// The phone answered (the event is no longer pending) a send the day
    /// never showed: the page goes back to the event's end.
    func testSettleReleasesASendTheDayNeverShowed() {
        var session = WristEndCrownSession()
        let e1 = occurrence(1, 9, 11)
        _ = shown([e1], select: 1, session: &session)
        _ = session.turn(crownDelta: 1)
        _ = session.takeUnsent(now: at(10))
        session.settle(pendingEventIDs: [e1.eventID])
        XCTAssertEqual(session.shownEnd, at(11.25), "still waiting")
        session.settle(pendingEventIDs: [])
        XCTAssertEqual(session.shownEnd, at(11))
    }
}
