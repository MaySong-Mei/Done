import XCTest
@testable import Done

/// The watch's pure state: snapshot + in-flight commands + wrist-finished
/// sessions → one of three screens. Fixed instants throughout.
@MainActor
final class WristStateReducerTests: XCTestCase {
    /// 2026-03-10 10:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_773_136_800)
    private let research = WristType(id: UUID(), title: "Research", colorHex: "#0A84FF")
    private let meeting = WristType(id: UUID(), title: "Meeting", colorHex: "#FF9F0A")

    private func minutes(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }

    private func occurrence(
        _ title: String, eventID: UUID = UUID(), start: Date, end: Date,
        isInterrupt: Bool = false, quickActions: Bool = true
    ) -> WristOccurrence {
        WristOccurrence(
            id: "\(title)-\(start.timeIntervalSince1970)", eventID: eventID, title: title, type: title,
            colorHex: "#0A84FF", start: start, end: end, isInterrupt: isInterrupt, quickActionsEnabled: quickActions
        )
    }

    private func snapshot(_ occurrences: [WristOccurrence], receipts: [WristReceipt] = []) -> WristSnapshot {
        WristSnapshot(generatedAt: now, types: [research, meeting], occurrences: occurrences, receipts: receipts)
    }

    private func display(
        _ snapshot: WristSnapshot?, pending: [WristPendingCommand] = [], dismissed: [WristDismissal] = [], at: Date? = nil
    ) -> WristDisplayState {
        WristStateReducer.display(snapshot: snapshot, pending: pending, dismissed: dismissed, now: at ?? now)
    }

    private func dismissal(_ occurrence: WristOccurrence, at tappedAt: Date) -> WristDismissal {
        WristDismissal(eventID: occurrence.eventID, rangeStart: occurrence.start, tappedAt: tappedAt)
    }

    // MARK: Screens

    func testNoSnapshotShowsNoPhoneData() {
        XCTAssertEqual(display(nil), .noPhoneData)
    }

    func testNothingRunningShowsGridWithTypes() {
        let state = display(snapshot([occurrence("Done earlier", start: minutes(-120), end: minutes(-60))]))
        guard case .idle(let types, let since) = state else { return XCTFail("expected idle, got \(state)") }
        XCTAssertEqual(types, [research, meeting])
        XCTAssertEqual(since, 60 * 60)
    }

    func testNoRecordsEverGivesNilSinceLastRecord() {
        let state = display(snapshot([occurrence("Later", start: minutes(30), end: minutes(60))]))
        guard case .idle(_, let since) = state else { return XCTFail("expected idle, got \(state)") }
        XCTAssertNil(since)
    }

    func testOccurrenceCoveringNowIsActive() {
        let running = occurrence("Paper", start: minutes(-10), end: minutes(20))
        XCTAssertEqual(display(snapshot([running])), .active(running, pending: false))
    }

    func testEventEndingExactlyNowIsOver() {
        let state = display(snapshot([occurrence("Paper", start: minutes(-30), end: now)]))
        guard case .idle(_, let since) = state else { return XCTFail("expected idle, got \(state)") }
        XCTAssertEqual(since, 0)
    }

    func testEmbeddedInterruptWinsOverParent() {
        let parent = occurrence("Deep work", start: minutes(-60), end: minutes(60))
        let interrupt = occurrence("Phone rang", start: minutes(-5), end: minutes(10), isInterrupt: true)
        XCTAssertEqual(display(snapshot([parent, interrupt])), .active(interrupt, pending: false))
    }

    func testTimelineAdvancesWithoutANewSnapshot() {
        let later = occurrence("Standup", start: minutes(30), end: minutes(45))
        let snap = snapshot([later])
        guard case .idle = display(snap) else { return XCTFail("not started yet") }
        XCTAssertEqual(display(snap, at: minutes(31)), .active(later, pending: false))
        guard case .idle(_, let since) = display(snap, at: minutes(50)) else { return XCTFail("should be over") }
        XCTAssertEqual(since, 5 * 60)
    }

    // MARK: Optimistic overlay

    private func pendingStart(_ type: WristType, eventID: UUID = UUID(), issuedAt: Date? = nil) -> WristPendingCommand {
        let start = WristTiming.startInstant(issuedAt ?? now)
        return WristPendingCommand(
            command: WristCommand(
                id: UUID(), issuedAt: issuedAt ?? now,
                kind: .start(eventID: eventID, typeTitle: type.title, start: start,
                             end: WristTiming.defaultEnd(start: start))
            )
        )
    }

    func testPendingStartShowsActiveAtOnceWithTypeColor() {
        let eventID = UUID()
        let state = display(snapshot([]), pending: [pendingStart(meeting, eventID: eventID)])
        guard case .active(let occ, let pending) = state else { return XCTFail("expected active, got \(state)") }
        XCTAssertTrue(pending)
        XCTAssertEqual(occ.eventID, eventID)
        XCTAssertEqual(occ.type, "Meeting")
        XCTAssertEqual(occ.colorHex, meeting.colorHex)
        XCTAssertEqual(occ.start, now)
        XCTAssertEqual(occ.end, now.addingTimeInterval(30 * 60))
    }

    func testPendingStartAlreadyInSnapshotIsNotDuplicated() {
        let eventID = UUID()
        let echoed = occurrence("Meeting", eventID: eventID, start: now, end: minutes(30))
        let timeline = WristStateReducer.overlaid(snapshot([echoed]), pending: [pendingStart(meeting, eventID: eventID)], now: now)
        XCTAssertEqual(timeline.occurrences.count, 1)
        XCTAssertEqual(timeline.pendingEventIDs, [eventID])
    }

    func testReceiptSettlesPendingAndTimeoutDropsIt() {
        let fresh = pendingStart(research)
        let stale = pendingStart(research, issuedAt: now.addingTimeInterval(-WristStateReducer.pendingTimeout))
        let receipted = pendingStart(meeting)
        let snap = snapshot([], receipts: [WristReceipt(id: receipted.command.id, outcome: .applied, reason: nil)])
        XCTAssertEqual(WristStateReducer.settle([fresh, stale, receipted], snapshot: snap, now: now), [fresh])
        // One second under the timeout still counts.
        let almost = pendingStart(research, issuedAt: now.addingTimeInterval(-WristStateReducer.pendingTimeout + 1))
        XCTAssertEqual(WristStateReducer.settle([almost], snapshot: nil, now: now), [almost])
    }

    func testPendingExtendMovesTheEndOnTheGrid() {
        // `now` is 10:00 UTC, so 10:30 sits on the quarter-hour grid and the
        // extension lands on 10:45 exactly; an off-grid end gets snapped the
        // way the phone snaps it.
        let running = occurrence("Paper", start: minutes(-10), end: minutes(30))
        let extend = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: now, kind: .extend(eventID: running.eventID, rangeStart: nil, by: 15 * 60)))
        guard case .active(let occ, let pending) = display(snapshot([running]), pending: [extend]) else {
            return XCTFail("expected active")
        }
        XCTAssertTrue(pending)
        XCTAssertEqual(occ.end, minutes(45))

        let offGrid = occurrence("Paper", start: minutes(-10), end: minutes(20))
        let timeline = WristStateReducer.overlaid(snapshot([offGrid]), pending: [
            WristPendingCommand(command: WristCommand(
                id: UUID(), issuedAt: now, kind: .extend(eventID: offGrid.eventID, rangeStart: nil, by: 15 * 60))),
        ], now: now)
        XCTAssertEqual(timeline.occurrences.first?.end, minutes(30), "10:35 snaps to 10:30, as the phone would store it")
    }

    func testPendingFinishClampsToMinimumDuration() {
        // Started 5 minutes ago; the phone will store start + 15.
        let running = occurrence("Paper", start: minutes(-5), end: minutes(25))
        let finish = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: now, kind: .finish(eventID: running.eventID, rangeStart: nil, at: now)))
        let timeline = WristStateReducer.overlaid(snapshot([running]), pending: [finish], now: now)
        XCTAssertEqual(timeline.occurrences.first?.end, minutes(10))
    }

    func testFinishOverlayTargetsTheOccurrenceCoveringNow() {
        let eventID = UUID()
        let earlier = occurrence("Night shift", eventID: eventID, start: minutes(-600), end: minutes(-540))
        let running = occurrence("Night shift", eventID: eventID, start: minutes(-20), end: minutes(40))
        let finish = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, rangeStart: nil, at: now)))
        let timeline = WristStateReducer.overlaid(snapshot([earlier, running]), pending: [finish], now: now)
        XCTAssertEqual(timeline.occurrences.map(\.end), [earlier.end, now])

        // Naming a range wins over "the one covering now", even when it is
        // not the last one.
        let named = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: now, kind: .extend(eventID: eventID, rangeStart: earlier.start, by: 15 * 60)))
        let namedTimeline = WristStateReducer.overlaid(snapshot([earlier, running]), pending: [named], now: now)
        XCTAssertEqual(namedTimeline.occurrences.map(\.end), [earlier.end.addingTimeInterval(15 * 60), running.end])
    }

    func testAcknowledgedPendingStaysInTheOverlayWithoutTheSendingHint() {
        var entry = pendingStart(meeting)
        guard case .active(_, let pendingBefore) = display(snapshot([]), pending: [entry]) else { return XCTFail("expected active") }
        XCTAssertTrue(pendingBefore)
        entry.acknowledgedAt = now
        guard case .active(let occ, let pendingAfter) = display(snapshot([]), pending: [entry]) else { return XCTFail("expected active") }
        XCTAssertFalse(pendingAfter)
        XCTAssertEqual(occ.eventID, entry.command.eventID, "still shown: only a receipted snapshot removes it")
        XCTAssertEqual(WristStateReducer.settle([entry], snapshot: snapshot([]), now: now), [entry])
    }

    func testPendingEntryDecodesWithoutTheNewerFields() throws {
        let entry = pendingStart(research)
        var object = try JSONSerialization.jsonObject(with: try WristWire.encode(entry)) as! [String: Any]
        for key in ["sentAt", "sentAsTransfer", "acknowledgedAt", "settleAfter"] {
            object.removeValue(forKey: key)
        }
        let decoded = try WristWire.decode(WristPendingCommand.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, entry)
        XCTAssertFalse(decoded.sentAsTransfer)
        XCTAssertNil(decoded.acknowledgedAt)
        XCTAssertNil(decoded.sentAt)
        XCTAssertNil(decoded.settleAfter)
    }

    // MARK: Sending rules

    private func entry(_ command: WristCommand, sentAt: Date? = nil, transfer: Bool = false, acked: Bool = false) -> WristPendingCommand {
        WristPendingCommand(command: command, sentAt: sentAt, sentAsTransfer: transfer, acknowledgedAt: acked ? now : nil)
    }

    func testChannelRuleKeepsOneEventsCommandsInOrder() {
        let eventID = UUID()
        let start = WristCommand(id: UUID(), issuedAt: minutes(-2), kind: .start(eventID: eventID, typeTitle: "R", start: minutes(-2), end: minutes(28)))
        let finish = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, rangeStart: minutes(-2), at: now))
        let other = WristCommand(id: UUID(), issuedAt: minutes(-1), kind: .start(eventID: UUID(), typeTitle: "G", start: minutes(-1), end: minutes(29)))

        // Nothing earlier: whichever channel is available.
        XCTAssertEqual(WristStateReducer.channel(for: entry(start), among: [entry(start)], reachable: true), .message)
        XCTAssertEqual(WristStateReducer.channel(for: entry(start), among: [entry(start)], reachable: false), .transfer)
        // The start is out as a message and unanswered: the finish waits.
        XCTAssertNil(WristStateReducer.channel(for: entry(finish), among: [entry(start, sentAt: now), entry(finish)], reachable: true))
        // The start is not even sent yet: the finish waits.
        XCTAssertNil(WristStateReducer.channel(for: entry(finish), among: [entry(start), entry(finish)], reachable: true))
        // The start went as a transfer: the finish follows on the same FIFO channel, reachable or not.
        XCTAssertEqual(WristStateReducer.channel(for: entry(finish), among: [entry(start, sentAt: now, transfer: true), entry(finish)], reachable: true), .transfer)
        XCTAssertEqual(WristStateReducer.channel(for: entry(finish), among: [entry(start, sentAt: now, transfer: true), entry(finish)], reachable: false), .transfer)
        // The start was answered: the finish is free.
        XCTAssertEqual(WristStateReducer.channel(for: entry(finish), among: [entry(start, sentAt: now, acked: true), entry(finish)], reachable: true), .message)
        // Another event's unanswered command does not gate it.
        XCTAssertEqual(WristStateReducer.channel(for: entry(finish), among: [entry(other, sentAt: now), entry(start, sentAt: now, acked: true), entry(finish)], reachable: true), .message)
    }

    func testAcknowledgeKeepsAppliedUntilASnapshotReflectsItAndDropsTheRest() {
        let applied = pendingStart(research)
        let rejected = pendingStart(meeting)
        let phoneClock = now.addingTimeInterval(1)
        var pending = [applied, rejected]
        pending = WristStateReducer.acknowledge(pending, receipt: WristReceipt(id: applied.command.id, outcome: .applied, reason: nil), repliedAt: phoneClock, now: now)
        pending = WristStateReducer.acknowledge(pending, receipt: WristReceipt(id: rejected.command.id, outcome: .rejected, reason: "recurring"), repliedAt: phoneClock, now: now)
        XCTAssertEqual(pending.map(\.command.id), [applied.command.id], "the rejected one changed nothing and is gone")
        XCTAssertEqual(pending[0].acknowledgedAt, now)
        XCTAssertEqual(pending[0].settleAfter, phoneClock)

        // An older snapshot (generated before the reply) keeps the overlay;
        // one generated at or after the reply settles it even without the receipt.
        var older = snapshot([]); older.generatedAt = now
        XCTAssertEqual(WristStateReducer.settle(pending, snapshot: older, now: now).count, 1)
        var newer = snapshot([]); newer.generatedAt = phoneClock
        XCTAssertTrue(WristStateReducer.settle(pending, snapshot: newer, now: now).isEmpty)
        // A duplicate answer means "applied earlier": kept like an applied one; an unknown id is ignored.
        let dup = WristStateReducer.acknowledge([applied], receipt: WristReceipt(id: applied.command.id, outcome: .duplicate, reason: nil), repliedAt: phoneClock, now: now)
        XCTAssertEqual(dup.count, 1)
        XCTAssertEqual(dup[0].settleAfter, phoneClock)
        // A second reply (a re-send answered duplicate, later clock) keeps the first clock.
        let again = WristStateReducer.acknowledge(pending, receipt: WristReceipt(id: applied.command.id, outcome: .duplicate, reason: nil), repliedAt: phoneClock.addingTimeInterval(600), now: now.addingTimeInterval(600))
        XCTAssertEqual(again[0].settleAfter, phoneClock)
        XCTAssertEqual(again[0].acknowledgedAt, now)
        XCTAssertEqual(WristStateReducer.acknowledge(pending, receipt: WristReceipt(id: UUID(), outcome: .applied, reason: nil), repliedAt: nil, now: now), pending)
    }

    func testANewProcessResendsMessagesItCannotGetRepliesFor() {
        let sentMessage = WristPendingCommand(command: pendingStart(research).command, sentAt: now)
        let sentTransfer = WristPendingCommand(command: pendingStart(meeting).command, sentAt: now, sentAsTransfer: true)
        let answered = WristPendingCommand(command: pendingStart(research).command, sentAt: now, acknowledgedAt: now)
        let reset = WristStateReducer.resetMessagesFromAnEarlierProcess([sentMessage, sentTransfer, answered])
        XCTAssertNil(reset[0].sentAt, "the reply handler died with the old process: due again")
        XCTAssertEqual(reset[1], sentTransfer, "a transfer is queued by the system and still in flight")
        XCTAssertEqual(reset[2], answered)
    }

    func testNamedRangeMatchesWithinTheWireTolerance() {
        // Two ranges of one event; the command names the EARLIER one, whose
        // start came back through the wire 0.4 s off. Without the tolerance
        // the "covering now" fallback would edit the running range instead.
        let eventID = UUID()
        let earlier = occurrence("Paper", eventID: eventID, start: minutes(-120).addingTimeInterval(0.4), end: minutes(-60))
        let running = occurrence("Paper", eventID: eventID, start: minutes(-10), end: minutes(20))
        let extend = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: now, kind: .extend(eventID: eventID, rangeStart: minutes(-120), by: 15 * 60)))
        let timeline = WristStateReducer.overlaid(snapshot([earlier, running]), pending: [extend], now: now).occurrences
        XCTAssertEqual(timeline.map(\.end), [earlier.end.addingTimeInterval(15 * 60), running.end])
        XCTAssertTrue(WristTiming.sameInstant(now, now.addingTimeInterval(0.49)))
        XCTAssertFalse(WristTiming.sameInstant(now, now.addingTimeInterval(0.5)))
    }

    // MARK: Dismissal (finished from the wrist)

    func testDismissedSessionHidesEvenWhileClampedEndIsAhead() {
        let running = occurrence("Paper", start: minutes(-5), end: minutes(10))
        let state = display(snapshot([running]), dismissed: [dismissal(running, at: now)])
        guard case .idle(_, let since) = state else { return XCTFail("expected idle, got \(state)") }
        XCTAssertEqual(since, 0, "the record ended at the tap, not at the clamped end")
        // Five minutes on, the clamped end (minutes(10)) is still ahead and the
        // record still ended at the tap.
        guard case .idle(_, let later) = display(snapshot([running]), dismissed: [dismissal(running, at: now)], at: minutes(5)) else {
            return XCTFail("expected idle")
        }
        XCTAssertEqual(later, 5 * 60)
        // Twenty minutes on — past the clamped end — the counter still runs
        // from the tap: no jump to "ten minutes since the clamped end".
        guard case .idle(_, let past) = display(snapshot([running]), dismissed: [dismissal(running, at: now)], at: minutes(20)) else {
            return XCTFail("expected idle")
        }
        XCTAssertEqual(past, 20 * 60)
    }

    func testDismissalIsPrunedOnceTheEventLeavesTheTimeline() {
        // The occurrences are the overlaid timeline: an occurrence finished
        // from the wrist already carries the clamped end the finish asked for.
        let over = occurrence("Paper", start: minutes(-60), end: minutes(-45))
        let live = occurrence("Gym", start: minutes(-5), end: minutes(10))
        let gone = occurrence("Walk", start: minutes(-120), end: minutes(-105))
        let kept = WristStateReducer.pruneDismissed(
            [dismissal(over, at: minutes(-50)), dismissal(live, at: minutes(-1)), dismissal(gone, at: minutes(-110))],
            occurrences: [over, live], now: now)
        XCTAssertEqual(kept, [dismissal(over, at: minutes(-50)), dismissal(live, at: minutes(-1))],
                       "kept while the occurrence is on the timeline, dropped once it is not")
    }

    /// Finish range 1 on the watch; the phone later adds range 2 (or the
    /// user resumes it there): range 2 shows. And an end the phone moved
    /// past what the finish asked for reveals the occurrence again.
    func testDismissalCoversOneRangeAndYieldsToAPhoneSideChange() {
        let eventID = UUID()
        let morning = occurrence("Paper", eventID: eventID, start: minutes(-120), end: minutes(-105))
        let afternoon = occurrence("Paper", eventID: eventID, start: minutes(-5), end: minutes(25))
        let tapped = dismissal(morning, at: minutes(-118))
        XCTAssertEqual(display(snapshot([morning, afternoon]), dismissed: [tapped]), .active(afternoon, pending: false),
                       "a later range of the same event is not hidden")

        let running = occurrence("Paper", start: minutes(-5), end: minutes(10))
        let finished = dismissal(running, at: now)
        guard case .idle = display(snapshot([running]), dismissed: [finished]) else { return XCTFail("hidden at the clamped end") }
        var extended = running
        extended.end = minutes(40)
        XCTAssertEqual(display(snapshot([extended]), dismissed: [finished]), .active(extended, pending: false),
                       "the phone moved the end past start+15: the finish is moot")
        XCTAssertEqual(WristStateReducer.pruneDismissed([finished], occurrences: [extended], now: now), [])
    }

    func testDismissingOneSessionRevealsAnotherRunningOne() {
        let parent = occurrence("Deep work", start: minutes(-60), end: minutes(60))
        let interrupt = occurrence("Phone rang", start: minutes(-5), end: minutes(10), isInterrupt: true)
        XCTAssertEqual(display(snapshot([parent, interrupt]), dismissed: [dismissal(interrupt, at: now)]), .active(parent, pending: false))
    }

    // MARK: Timing rules

    func testDefaultEndIsOnTheGridAndNeverUnderTheMinimum() {
        for minute in 0..<60 {
            let start = minutes(Double(minute))
            let end = WristTiming.defaultEnd(start: start)
            XCTAssertEqual(end.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 900), 0, "minute \(minute)")
            XCTAssertGreaterThanOrEqual(end.timeIntervalSince(start), WristTiming.minimumDuration)
            XCTAssertLessThanOrEqual(abs(end.timeIntervalSince(start) - WristTiming.defaultDuration), 7.5 * 60)
            // And +15 from there lands exactly +15.
            XCTAssertEqual(WristTiming.clampedEnd(start: start, requested: end.addingTimeInterval(15 * 60)), end.addingTimeInterval(15 * 60))
        }
    }

    func testStartInstantFloorsToTheMinuteAndNeverRunsAhead() {
        let tapped = now.addingTimeInterval(7 * 60 + 59)
        XCTAssertEqual(WristTiming.startInstant(tapped), minutes(7))
        XCTAssertLessThanOrEqual(WristTiming.startInstant(tapped), tapped)
    }

    func testClampedEndMatchesThePhoneRule() {
        let start = minutes(-5)
        // Finish 5 minutes in: snapped to the grid would be `now`, clamp wins.
        XCTAssertEqual(WristTiming.clampedEnd(start: start, requested: now), start.addingTimeInterval(15 * 60))
        // Finish 52 minutes in: grid-snapped to the nearest quarter hour.
        let late = start.addingTimeInterval(52 * 60)
        XCTAssertEqual(WristTiming.clampedEnd(start: start, requested: late), calendarSnapDateToMinuteGrid(late))
        XCTAssertEqual(WristTiming.snappedToGrid(late), calendarSnapDateToMinuteGrid(late))
    }
}
