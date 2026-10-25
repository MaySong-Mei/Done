import XCTest
@testable import Done

/// Independent QA for gh#274 (watch phase 1). The tests that were red in the
/// first round (named `testDEFECT_…` then) now pin the contracts adopted in
/// the fix round; the coordinator flipped them, the QA author wrote them.
@MainActor
final class WristAdversarialQATests: XCTestCase {
    private let suiteName = "WristAdversarialQATests"
    private var defaults: UserDefaults!
    private var store: EventStore!
    /// 2026-03-10 10:05:00 UTC — snaps to 10:00 on the quarter-hour grid.
    private let now = Date(timeIntervalSince1970: 1_773_137_100)
    private let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    override func setUp() {
        super.setUp()
        let location = TestStorage.reset(suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    override func tearDown() {
        store = nil
        defaults = nil
        TestStorage.tearDown(suiteName)
        super.tearDown()
    }

    // MARK: Helpers

    private func m(_ minutes: Double, from base: Date? = nil) -> Date { (base ?? now).addingTimeInterval(minutes * 60) }

    private func cmd(_ kind: WristCommand.Kind, id: UUID = UUID()) -> WristCommand {
        WristCommand(id: id, issuedAt: now, kind: kind)
    }

    private func bridge() -> WristBridge {
        let b = WristBridge(ledger: WristAppliedLedger(defaults: defaults))
        b.attach(store: store, templates: EventTypeTemplateStore(defaults: defaults))
        return b
    }

    private func occ(_ title: String, eventID: UUID = UUID(), start: Date, end: Date,
                     interrupt: Bool = false) -> WristOccurrence {
        WristOccurrence(id: "\(title)-\(eventID)-\(start.timeIntervalSince1970)", eventID: eventID, title: title,
                        type: title, colorHex: "#000000", start: start, end: end,
                        isInterrupt: interrupt, quickActionsEnabled: true)
    }

    private func snap(_ occurrences: [WristOccurrence], types: [WristType] = [], receipts: [WristReceipt] = []) -> WristSnapshot {
        WristSnapshot(generatedAt: now, types: types, occurrences: occurrences, receipts: receipts)
    }

    private func isOnGrid(_ d: Date) -> Bool {
        d.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 900) == 0
    }

    // MARK: P1 — redelivery never applies twice (all three kinds)

    func testP1_redeliveryOfEveryKindIsIdempotent() {
        let b = bridge()
        let eventID = UUID()
        let start = cmd(.start(eventID: eventID, typeTitle: "Research", start: now, end: m(30)))
        let extend = cmd(.extend(eventID: eventID, rangeStart: nil, by: 15 * 60))
        var outcomes: [WristReceipt.Outcome] = []
        for _ in 0..<3 { outcomes.append(b.handle(start)!.outcome) }
        for _ in 0..<3 { outcomes.append(b.handle(extend)!.outcome) }
        XCTAssertEqual(outcomes, [.applied, .duplicate, .duplicate, .applied, .duplicate, .duplicate])
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
        // 10:35 + 15 = 10:50 → snaps to 10:45; applied ONCE.
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end, m(40))
    }

    // MARK: P2 — fresh command id, existing eventID

    func testP2_freshCommandIDOnExistingEventIDChangesNothing() {
        let b = bridge()
        let eventID = UUID()
        XCTAssertEqual(b.handle(cmd(.start(eventID: eventID, typeTitle: "Research", start: now, end: m(30))))?.outcome, .applied)
        let before = store.findCalendarEvent(id: eventID)
        let receipt = b.handle(cmd(.start(eventID: eventID, typeTitle: "Gym", start: m(-60), end: m(120))))
        XCTAssertEqual(receipt?.outcome, .duplicate)
        XCTAssertEqual(store.findCalendarEvent(id: eventID), before)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
    }

    // MARK: P3 — clamp and grid

    func testP3_finishInsideFirstQuarterStoresExactlyStartPlus15() {
        let start = WristTiming.startInstant(m(2.5)) // 10:07, off-grid like every wrist start
        var violations = 0
        for halfMinutes in 0..<30 {
            let end = WristCommandApplier.adjustedEnd(start: start, requested: start.addingTimeInterval(Double(halfMinutes) * 30))
            if end != start.addingTimeInterval(900) { violations += 1 }
        }
        XCTAssertEqual(violations, 0)
    }

    func testP3_endIsNeverBeforeStartPlus15() {
        var violations = 0
        for startMinute in 0..<60 {
            let start = m(Double(startMinute))
            for offset in stride(from: -120.0, through: 240.0, by: 0.5) {
                let end = WristCommandApplier.adjustedEnd(start: start, requested: start.addingTimeInterval(offset * 60))
                if end < start.addingTimeInterval(900) { violations += 1 }
            }
        }
        XCTAssertEqual(violations, 0)
    }

    /// Wrist starts are floored to the minute (off-grid), so for a start at
    /// hh:mm with mm mod 15 in 1…7 a finish between start+15 and the next
    /// grid mark snaps BACK below start+15 and the floor wins: the stored end
    /// is then start+15 exactly, otherwise it is on the grid.
    func testP3_storedEndIsOnGridUnlessTheFloorWins() {
        var violations = 0, floorWins = 0, total = 0
        let hour = utc.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 10))!
        for startMinute in 0..<60 {
            let start = m(Double(startMinute), from: hour)
            for finishOffset in 15...60 {
                total += 1
                let end = WristCommandApplier.adjustedEnd(start: start, requested: start.addingTimeInterval(Double(finishOffset) * 60))
                if isOnGrid(end) { continue }
                if end == start.addingTimeInterval(900) { floorWins += 1 } else { violations += 1 }
            }
        }
        XCTAssertEqual(violations, 0, "ends neither on grid nor at start+15: \(violations)/\(total)")
        XCTAssertEqual(floorWins, 112, "the floor wins for 7 start minutes × 16 finish offsets")
    }

    func testP3_extendFromOnGridEndLandsExactlyPlus15() {
        let eventID = UUID()
        WristCommandApplier.apply(cmd(.start(eventID: eventID, typeTitle: "R", start: m(-5), end: m(25))), to: store) // ends 10:30
        WristCommandApplier.apply(cmd(.extend(eventID: eventID, rangeStart: nil, by: 900)), to: store)
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges[0].end, m(40))
    }

    /// The wrist mints start = tap minute and end = the grid mark nearest
    /// start + 30, so "+15" adds exactly fifteen minutes for every start minute.
    func testPlus15OnAWristStartedEventAddsExactlyFifteenMinutes() {
        let hour = utc.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 10))!
        var exact = 0
        var deltas: [Int: Int] = [:]
        for startMinute in 0..<60 {
            let start = WristTiming.startInstant(m(Double(startMinute) + 0.5, from: hour))
            let end = WristTiming.defaultEnd(start: start)
            let extended = WristCommandApplier.adjustedEnd(start: start, requested: end.addingTimeInterval(WristTiming.extendStep))
            let delta = Int(extended.timeIntervalSince(end) / 60)
            deltas[delta, default: 0] += 1
            if delta == 15 { exact += 1 }
        }
        XCTAssertEqual(exact, 60, "+15 added exactly 15 min for \(exact)/60 start minutes; delta histogram (min: count) \(deltas.sorted { $0.key < $1.key })")
    }

    // MARK: P4 — hasSameContent

    func testP4_hasSameContentIgnoresOnlyGeneratedAt() {
        let base = WristSnapshot(generatedAt: now, language: "en",
                                 types: [WristType(id: UUID(), title: "A", colorHex: "#1")],
                                 occurrences: [occ("x", start: now, end: m(30))],
                                 receipts: [WristReceipt(id: UUID(), outcome: .applied, reason: nil)])
        var g = base; g.generatedAt = m(999)
        XCTAssertTrue(base.hasSameContent(as: g))
        var v = base; v.version = 2
        var l = base; l.language = "zh"
        var t = base; t.types[0].colorHex = "#2"
        var o = base; o.occurrences[0].quickActionsEnabled = false
        var r = base; r.receipts[0].reason = "x"
        for (name, variant) in [("version", v), ("language", l), ("types", t), ("occurrences", o), ("receipts", r)] {
            XCTAssertFalse(base.hasSameContent(as: variant), name)
        }
    }

    // MARK: P5 — the clock alone drives start and end

    func testP5_futureOccurrenceActivatesAtStartAndEndsAtEndExactly() {
        let later = occ("Standup", start: m(30), end: m(45))
        let s = snap([later])
        XCTAssertNotEqual(WristStateReducer.display(snapshot: s, pending: [], dismissed: [:], now: m(30).addingTimeInterval(-0.001)),
                          .active(later, pending: false))
        XCTAssertEqual(WristStateReducer.display(snapshot: s, pending: [], dismissed: [:], now: m(30)), .active(later, pending: false))
        XCTAssertEqual(WristStateReducer.display(snapshot: s, pending: [], dismissed: [:], now: m(45).addingTimeInterval(-0.001)),
                       .active(later, pending: false))
        guard case .idle(_, let since) = WristStateReducer.display(snapshot: s, pending: [], dismissed: [:], now: m(45)) else {
            return XCTFail("not idle at end")
        }
        XCTAssertEqual(since, 0)
    }

    // MARK: P6 — wrist finish inside the first quarter hour

    func testP6_wristFinishHidesAtOnceAndPrunesAtClampedEnd() {
        let running = occ("Paper", start: m(-3), end: m(27))
        let finish = WristPendingCommand(command: cmd(.finish(eventID: running.eventID, rangeStart: running.start, at: now)))
        let s = snap([running])
        guard case .idle(_, let since) = WristStateReducer.display(snapshot: s, pending: [finish], dismissed: [running.eventID: now], now: now) else {
            return XCTFail("expected idle")
        }
        XCTAssertEqual(since, 0)
        let clampedEnd = m(12)
        let tl1 = WristStateReducer.overlaid(s, pending: [finish], now: m(11.99)).occurrences
        XCTAssertEqual(tl1.first?.end, clampedEnd)
        XCTAssertEqual(WristStateReducer.pruneDismissed([running.eventID: now], occurrences: tl1, now: m(11.99)), [running.eventID: now])
        // Past the clamped end the event is over on both sides; the dismissal
        // stays while the event is on the timeline so "since" keeps counting
        // from the tap, and goes once the window has dropped the event.
        let tl2 = WristStateReducer.overlaid(s, pending: [finish], now: clampedEnd).occurrences
        XCTAssertEqual(WristStateReducer.pruneDismissed([running.eventID: now], occurrences: tl2, now: clampedEnd), [running.eventID: now])
        guard case .idle(_, let since2) = WristStateReducer.display(snapshot: s, pending: [finish], dismissed: [running.eventID: now], now: m(30)) else {
            return XCTFail("expected idle")
        }
        XCTAssertEqual(since2, 30 * 60)
        XCTAssertEqual(WristStateReducer.pruneDismissed([running.eventID: now], occurrences: [], now: m(30)), [:])
    }

    // MARK: P7 — builder window

    func testP7_allDayNeverAndRecurringNeverQuickActions() {
        let t = utc.startOfDay(for: now)
        var series = Event(title: "S", timeRanges: [.init(start: t.addingTimeInterval(-86400 * 9 + 3600), end: t.addingTimeInterval(-86400 * 9 + 7200))], type: "S")
        series.repeatUnit = .day
        var child = Event(title: "C", timeRanges: [.init(start: m(-10), end: m(20))], type: "S")
        child.recurrenceParentId = series.id
        let allDay = Event(title: "Off", timeRanges: [.init(start: t, end: t.addingTimeInterval(86400))], isAllDay: true, type: "Off")
        let result = WristSnapshotBuilder.occurrences(events: [series, child, allDay], now: now, calendar: utc, colorHex: { _ in "" })
        XCTAssertFalse(result.contains { $0.eventID == allDay.id })
        XCTAssertTrue(result.filter { $0.eventID == series.id || $0.eventID == child.id }.allSatisfy { !$0.quickActionsEnabled })
        XCTAssertEqual(result.filter { $0.eventID == series.id }.count, 4)
    }

    /// A plain event crossing midnight is ONE unclipped occurrence with its
    /// true start (`occurrencesForDate` does not clip plain events and the
    /// builder dedupes by id), not one per day.
    func testP7_crossMidnightPlainEventIsOneUnclippedOccurrence() {
        let t = utc.startOfDay(for: now)
        let a = Event(title: "Night", timeRanges: [.init(start: t.addingTimeInterval(-3600), end: t.addingTimeInterval(3600))], type: "N")
        let b = Event(title: "Late", timeRanges: [.init(start: t.addingTimeInterval(86400 - 3600), end: t.addingTimeInterval(86400 + 3600))], type: "N")
        let result = WristSnapshotBuilder.occurrences(events: [a, b], now: now, calendar: utc, colorHex: { _ in "" })
        XCTAssertEqual(result.filter { $0.eventID == a.id }.count, 1)
        XCTAssertEqual(result.filter { $0.eventID == b.id }.count, 1)
        XCTAssertEqual(result.first { $0.eventID == a.id }?.start, a.timeRanges[0].start, "unclipped start")
        XCTAssertEqual(result.first { $0.eventID == a.id }?.end, a.timeRanges[0].end, "unclipped end")
    }

    func testP7_windowInLosAngelesOnSpringForwardDay() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func at(_ d: Int, _ h: Int, _ mi: Int = 0) -> Date { la.date(from: DateComponents(year: 2026, month: 3, day: d, hour: h, minute: mi))! }
        let probes: [(String, Date)] = [
            ("6th 23:30", at(6, 23, 30)), ("7th 00:30", at(7, 0, 30)), ("8th 01:30", at(8, 1, 30)),
            ("8th 03:30", at(8, 3, 30)), ("9th 23:30", at(9, 23, 30)), ("10th 00:30", at(10, 0, 30)),
        ]
        let events = probes.map { Event(title: $0.0, timeRanges: [.init(start: $0.1, end: $0.1.addingTimeInterval(1800))], type: "T") }
        for (nowLabel, nowDate) in [("8th 12:00", at(8, 12)), ("8th 00:30", at(8, 0, 30)), ("8th 23:45", at(8, 23, 45))] {
            let titles = WristSnapshotBuilder.occurrences(events: events, now: nowDate, calendar: la, colorHex: { _ in "" }).map(\.title)
            XCTAssertEqual(titles, ["7th 00:30", "8th 01:30", "8th 03:30", "9th 23:30", "10th 00:30"], "now = \(nowLabel)")
        }
        // now on the 9th at 00:30 PDT: yesterday is the 23-hour 8th.
        let titles = WristSnapshotBuilder.occurrences(events: events, now: at(9, 0, 30), calendar: la, colorHex: { _ in "" }).map(\.title)
        XCTAssertEqual(titles, ["8th 01:30", "8th 03:30", "9th 23:30", "10th 00:30"])
    }

    // MARK: P8 — pending timeout

    func testP8_pendingKeptJustUnderTheTimeoutAndDroppedAtIt() {
        let p = WristPendingCommand(command: WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: UUID(), rangeStart: nil, at: now)))
        let t = WristStateReducer.pendingTimeout
        XCTAssertEqual(t, 24 * 3600, "a transfer may wait for hours while the phone is away")
        XCTAssertEqual(WristStateReducer.settle([p], snapshot: nil, now: now.addingTimeInterval(t - 1)), [p])
        XCTAssertEqual(WristStateReducer.settle([p], snapshot: nil, now: now.addingTimeInterval(t - 0.001)), [p])
        XCTAssertEqual(WristStateReducer.settle([p], snapshot: nil, now: now.addingTimeInterval(t)), [])
    }

    // MARK: P9 — ledger

    func testP9_ledgerCapacityEvictionOrderAndPersistence() {
        var ledger = WristAppliedLedger(defaults: defaults)
        let ids = (0..<300).map { _ in UUID() }
        for id in ids { ledger.record(WristReceipt(id: id, outcome: .applied, reason: nil)) }
        ledger.record(WristReceipt(id: ids[299], outcome: .applied, reason: nil)) // re-insert is a no-op
        XCTAssertEqual(ledger.count, 256)
        let reread = WristAppliedLedger(defaults: defaults)
        XCTAssertEqual(reread.count, 256)
        XCTAssertEqual(ids.prefix(44).filter { ledger.contains($0) || reread.contains($0) }.count, 0)
        XCTAssertEqual(ids.suffix(256).filter { ledger.contains($0) && reread.contains($0) }.count, 256)
    }

    // MARK: P10 — recurring can never be modified

    func testP10_noWristCommandModifiesASeriesOrItsMaterializedChild() {
        let b = bridge()
        var series = Event(title: "Standup", timeRanges: [.init(start: m(-86400 * 3 / 60), end: m(-86400 * 3 / 60 + 15))], type: "Meeting")
        series.repeatUnit = .day
        var child = Event(title: "Standup", timeRanges: [.init(start: m(-5), end: m(10))], type: "Meeting")
        child.recurrenceParentId = series.id
        store.addCalendarEvent(series)
        store.addCalendarEvent(child)
        for target in [series, child] {
            let r1 = b.handle(cmd(.finish(eventID: target.id, rangeStart: nil, at: now)))
            let r2 = b.handle(cmd(.extend(eventID: target.id, rangeStart: nil, by: 900)))
            let r3 = b.handle(cmd(.extend(eventID: target.id, rangeStart: nil, by: -3600)))
            let r4 = b.handle(cmd(.start(eventID: target.id, typeTitle: "Hack", start: now, end: m(30))))
            XCTAssertEqual([r1, r2, r3].map { $0?.reason }, ["recurring", "recurring", "recurring"])
            XCTAssertEqual(r4?.outcome, .duplicate)
            XCTAssertEqual(store.findCalendarEvent(id: target.id)?.timeRanges, target.timeRanges)
        }
        XCTAssertEqual(store.rawCalendarEvents.count, 2)
    }

    // MARK: Adversarial

    /// A two-range event whose SECOND range is running. The watch predicts the
    /// covering range's end; the phone rewrites range 0 instead.
    func testMultiRangeFinishEditsTheRangeTheWatchNamed() {
        let eventID = UUID()
        let r0 = Event.TimeRange(start: m(-365), end: m(-305))  // 04:00–05:00
        let r1 = Event.TimeRange(start: m(-20), end: m(40))     // 09:45–10:45 (running)
        store.addCalendarEvent(Event(id: eventID, title: "Split", timeRanges: [r0, r1], type: "Work"))

        let built = WristSnapshotBuilder.occurrences(events: store.canvasRenderableCalendarEvents, now: now, calendar: utc, colorHex: { _ in "" })
        XCTAssertEqual(built.filter { $0.eventID == eventID }.count, 2)
        let running = built.first { $0.eventID == eventID && $0.start == r1.start }!
        let finish = cmd(.finish(eventID: eventID, rangeStart: running.start, at: now))
        let predicted = WristStateReducer.overlaid(snap(built), pending: [WristPendingCommand(command: finish)], now: now).occurrences
        XCTAssertEqual(predicted.map(\.end), [r0.end, m(-5)], "watch predicts the running range ends at 10:00")

        XCTAssertEqual(WristCommandApplier.apply(finish, to: store).outcome, .applied)
        let stored = store.findCalendarEvent(id: eventID)!.timeRanges
        XCTAssertEqual(stored.map(\.end), [r0.end, m(-5)], "phone stored \(stored.map { "\($0.start)–\($0.end)" })")
    }

    /// Start lost its fast path (sendMessage error → transfer) while the
    /// finish went out as a message: the finish reaches the phone first. It
    /// is refused but not remembered, so its transfer copy applies later.
    func testFinishArrivingBeforeItsStartAppliesOnRedelivery() {
        let b = bridge()
        let eventID = UUID()
        let start = cmd(.start(eventID: eventID, typeTitle: "Research", start: now, end: m(30)))
        let finish = cmd(.finish(eventID: eventID, rangeStart: now, at: m(3)))
        let r1 = b.handle(finish)
        let r2 = b.handle(start)
        let r3 = b.handle(finish) // the transfer copy of the finish also arrives
        XCTAssertEqual([r1?.outcome, r2?.outcome, r3?.outcome], [.rejected, .applied, .applied])
        XCTAssertEqual(r1?.reason, "not found")
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end, m(15),
                       "user finished at +3 min: stored end is start+15")
    }

    func testFinishOnAnEventDeletedOnThePhoneIsRejectedAndCreatesNothing() {
        let b = bridge()
        let eventID = UUID()
        b.handle(cmd(.start(eventID: eventID, typeTitle: "R", start: now, end: m(30))))
        store.deleteCalendarEvent(store.findCalendarEvent(id: eventID)!)
        XCTAssertNil(store.findCalendarEvent(id: eventID))
        let r = b.handle(cmd(.finish(eventID: eventID, rangeStart: nil, at: m(5))))
        let e = b.handle(cmd(.extend(eventID: eventID, rangeStart: nil, by: 900)))
        XCTAssertEqual([r?.reason, e?.reason], ["not found", "not found"])
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
    }

    func testStartWithEndBeforeOrEqualStartIsRejected() {
        for end in [now, m(-1), m(-600)] {
            XCTAssertEqual(WristCommandApplier.apply(cmd(.start(eventID: UUID(), typeTitle: "R", start: now, end: end)), to: store).reason, "invalid range")
        }
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
    }

    /// A todo timer started from the Event Grid (`EventStore.startTimer`)
    /// projects open-ended: active on the wrist for as long as it runs, with
    /// the quick actions off (it is stopped on the phone).
    func testRunningTimerEventIsActiveOnTheWristOpenEnded() {
        let ts = m(-10)
        let timer = Event(title: "Reading", timeRanges: [.init(start: ts, end: ts)], type: "Read", timerStartedAt: ts)
        let built = WristSnapshotBuilder.occurrences(events: [timer], now: now, calendar: utc, colorHex: { _ in "" })
        XCTAssertEqual(built.count, 1)
        XCTAssertTrue(built[0].isOpenEnded)
        XCTAssertFalse(built[0].quickActionsEnabled)
        let atBuild = WristStateReducer.display(snapshot: snap(built), pending: [], dismissed: [:], now: now)
        let hoursLater = WristStateReducer.display(snapshot: snap(built), pending: [], dismissed: [:], now: m(180))
        XCTAssertEqual(atBuild, .active(built[0], pending: false))
        XCTAssertEqual(hoursLater, .active(built[0], pending: false))
    }

    func testIdenticalTypeTitlesAndUnicodeTitles() {
        let gymA = EventTypeTemplate(title: "Gym", colorHex: "#AA0000")
        let gymB = EventTypeTemplate(title: "Gym", colorHex: "#00BB00")
        let ranked = WristSnapshotBuilder.rankedTypes(events: [], templates: [gymA, gymB], now: now, calendar: utc)
        XCTAssertEqual(ranked.map(\.colorHex), ["#AA0000", "#00BB00"])
        XCTAssertEqual(Set(ranked.map(\.id)).count, 2)
        let pending = WristPendingCommand(command: cmd(.start(eventID: UUID(), typeTitle: "Gym", start: now, end: m(30))))
        let s = WristSnapshot(generatedAt: now, types: [ranked[1], ranked[0]], occurrences: [], receipts: [])
        XCTAssertEqual(WristStateReducer.overlaid(s, pending: [pending], now: now).occurrences.first?.colorHex, "#00BB00",
                       "first matching title wins (tapped type's color is not carried)")

        let cjk = UUID(), zw = UUID(), emoji = UUID()
        XCTAssertEqual(WristCommandApplier.apply(cmd(.start(eventID: cjk, typeTitle: "\u{3000}研究 \n", start: now, end: m(30))), to: store).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: cjk)?.type, "研究")
        XCTAssertEqual(WristCommandApplier.apply(cmd(.start(eventID: emoji, typeTitle: "🏋️‍♀️", start: now, end: m(30))), to: store).outcome, .applied)
        // A zero-width space trims to empty (Foundation counts U+200B as whitespace here).
        let zwOutcome = WristCommandApplier.apply(cmd(.start(eventID: zw, typeTitle: "\u{200B}", start: now, end: m(30))), to: store).outcome
        XCTAssertEqual(zwOutcome, .rejected)
    }

    func testFiveHundredOccurrencesOverlayStaysCheap() {
        var occurrences: [WristOccurrence] = []
        for i in 0..<500 { occurrences.append(occ("o\(i)", start: m(Double(i) - 400), end: m(Double(i) - 395))) }
        let running = occurrences[400]
        let pending = (0..<10).map { i in
            WristPendingCommand(command: cmd(i.isMultiple(of: 2) ? .extend(eventID: running.eventID, rangeStart: nil, by: 900)
                                             : .start(eventID: UUID(), typeTitle: "X", start: now, end: m(30))))
        }
        let s = snap(occurrences)
        let clock = Date()
        var last: WristDisplayState = .noPhoneData
        for _ in 0..<200 { last = WristStateReducer.display(snapshot: s, pending: pending, dismissed: [:], now: now) }
        let perCall = Date().timeIntervalSince(clock) / 200
        print("QA-PERF display() 500 occ + 10 pending: \(String(format: "%.3f", perCall * 1000)) ms/call")
        guard case .active = last else { return XCTFail("expected active") }
        XCTAssertLessThan(perCall, 0.005)
    }
}
