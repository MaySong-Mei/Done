import XCTest
@testable import Done

/// Independent QA of the watch's event page (`WristEventSubject`,
/// `WristEndCrown`, `WristEndCrownSession`), written from the spec and the
/// phone's own rule rather than the implementation. Expected ends come from
/// `phoneStores` below — the phone's end-only edit restated from
/// `WristCommandApplier.setRange` + `WristRangeEdit.settled` — checked
/// against the shared rule (positive control) and, end to end, against the
/// phone's real applier on a real store.
@MainActor
final class WristEventPageQATests: XCTestCase {
    private static let q: TimeInterval = 15 * 60
    private let suiteName = "WristEventPageQATests"

    // MARK: Oracle

    /// The end the phone stores when asked for `requested` in place of
    /// `oldEnd`, start unchanged: kept if unchanged, on a neighbour edge, on
    /// the 15-minute grid, or whole quarter hours from the old end; else the
    /// nearest grid mark; then at least 15 minutes long.
    static func phoneStores(start: Date, oldEnd: Date, requested: Date, edges: [Date]) -> Date {
        func same(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.5 }
        let t = requested.timeIntervalSinceReferenceDate
        let grid = Date(timeIntervalSinceReferenceDate: (t / q).rounded() * q)
        var end: Date
        if same(requested, oldEnd) {
            end = oldEnd
        } else if let edge = edges.first(where: { same($0, requested) }) {
            end = edge
        } else if same(grid, requested) {
            end = grid
        } else {
            let stepped = oldEnd.addingTimeInterval((requested.timeIntervalSince(oldEnd) / q).rounded() * q)
            end = same(stepped, requested) ? stepped : grid
        }
        if end.timeIntervalSince(start) < 15 * 60 { end = start.addingTimeInterval(15 * 60) }
        return end
    }

    private static func keeps(start: Date, end: Date, stop: Date, edges: [Date]) -> Bool {
        abs(phoneStores(start: start, oldEnd: end, requested: stop, edges: edges).timeIntervalSince(stop)) < 0.5
    }

    private static func isGrid(_ d: Date) -> Bool {
        let r = d.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: q)
        return abs(r) < 0.001 || abs(r - q) < 0.001
    }

    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }

    // MARK: Fixtures

    /// 2026-03-10 00:00 UTC.
    nonisolated private static let utcStart = Date(timeIntervalSince1970: 1_773_100_800)
    nonisolated private static let utcEnd = utcStart.addingTimeInterval(86_400)
    nonisolated private static func at(_ h: Int, _ m: Int, _ day: Date = utcStart) -> Date {
        day.addingTimeInterval(Double(h * 3600 + m * 60))
    }

    private static func occ(_ start: Date, _ end: Date) -> WristOccurrence {
        occ(UUID(), id: nil, start, end)
    }

    private static func occ(
        _ eventID: UUID, id: String?, _ start: Date, _ end: Date,
        editable: Bool = true, openEnded: Bool = false
    ) -> WristOccurrence {
        WristOccurrence(
            id: id ?? "\(eventID.uuidString)@\(start.timeIntervalSince1970)", eventID: eventID, title: "e", type: "t",
            colorHex: "#000000", start: start, end: end, isInterrupt: false,
            quickActionsEnabled: editable, isOpenEnded: openEnded
        )
    }

    private func config(
        _ start: Date, _ end: Date, edges: [Date] = [], running: Bool = false, now: Date? = nil,
        dayStart: Date = utcStart, dayEnd: Date = utcEnd,
        file: StaticString = #filePath, line: UInt = #line
    ) -> WristEndCrown.Config? {
        let a = WristEndCrown.availability(
            start: start, end: end, isOpenEnded: false, quickActionsEnabled: true, isRunning: running,
            takesRangeEdits: true, dayStart: dayStart, dayEnd: dayEnd,
            now: now ?? dayStart.addingTimeInterval(-3 * 86_400), edges: edges
        )
        guard case .moves(let c) = a else {
            XCTFail("crown should move \(start)…\(end): \(a)", file: file, line: line)
            return nil
        }
        return c
    }

    // MARK: 0. Positive control — the oracle is the shared rule

    func testOracleAgreesWithTheSharedPhoneRule() {
        var rng = LCG(state: 11)
        var checked = 0
        for _ in 0..<4000 {
            let s = Self.at(0, Int(rng.next() % (22 * 60)))
            let e = s.addingTimeInterval(Double(1 + rng.next() % 240) * 60)
            let req = s.addingTimeInterval(Double(1 + rng.next() % 300) * 60)
            let edges = (0..<3).map { _ in Self.at(0, Int(rng.next() % (24 * 60))) }
            let shared = WristRangeEdit.settled(
                original: WristTimeSpan(start: s, end: e), requested: WristTimeSpan(start: s, end: req), edges: edges
            )
            XCTAssertEqual(shared?.start, s)
            XCTAssertEqual(shared?.end, Self.phoneStores(start: s, oldEnd: e, requested: req, edges: edges),
                           "oracle disagrees: \(s)…\(e) → \(req)")
            checked += 1
        }
        XCTAssertEqual(checked, 4000)
        // Known values: off-grid start 10:13, end 11:00 → 10:28 is stored 10:30.
        XCTAssertEqual(Self.phoneStores(start: Self.at(10, 13), oldEnd: Self.at(11, 0), requested: Self.at(10, 28), edges: []), Self.at(10, 30))
        // 10:07 → 10:22 is a whole quarter from the old end: kept.
        XCTAssertEqual(Self.phoneStores(start: Self.at(9, 0), oldEnd: Self.at(10, 7), requested: Self.at(10, 22), edges: []), Self.at(10, 22))
    }

    // MARK: 1. Stops

    /// Every start minute × lengths × off-grid neighbour edges: every stop is
    /// an end the phone keeps; never under the minimum (bar the event's own
    /// end); never past midnight; strictly increasing; no grid mark or
    /// in-limit neighbour edge the phone keeps is skipped.
    func testSweepEveryStopIsKeptAndNothingIsSkipped() {
        var rng = LCG(state: 3)
        var total = 0
        for startMinute in stride(from: 0, to: 23 * 60 + 50, by: 7) {
            for length in [1, 9, 15, 16, 29, 45, 61, 133] {
                let s = Self.at(0, startMinute), e = s.addingTimeInterval(Double(length) * 60)
                guard e <= Self.utcEnd else { continue }
                let edges = (0..<4).map { _ in s.addingTimeInterval(Double(Int(rng.next() % 300) - 60) * 60 + Double(rng.next() % 2) * 20) }
                guard let c = config(s, e, edges: edges) else { return }
                let stops = WristEndCrown.stops(for: c, keeping: nil)
                XCTAssertTrue(stops.contains(e), "own end is a stop")
                for (i, stop) in stops.enumerated() {
                    if i > 0 { XCTAssertGreaterThan(stop, stops[i - 1]) }
                    XCTAssertLessThanOrEqual(stop, Self.utcEnd)
                    guard stop != e else { continue }
                    XCTAssertGreaterThanOrEqual(stop.timeIntervalSince(s), 15 * 60 - 0.001, "under the minimum: \(s)…\(e) → \(stop)")
                    XCTAssertTrue(Self.keeps(start: s, end: e, stop: stop, edges: c.edges),
                                  "\(s)…\(e) → \(stop): phone stores \(Self.phoneStores(start: s, oldEnd: e, requested: stop, edges: c.edges))")
                    XCTAssertTrue(Self.isGrid(stop) || c.edges.contains(stop) || stop == c.floor,
                                  "a stop must be a grid mark, a neighbour edge or the floor: \(stop)")
                    total += 1
                }
                // Nothing skipped: every kept grid mark / in-day edge at or
                // above the minimum and at or below midnight is a stop.
                let lowest = s.addingTimeInterval(15 * 60)
                var expected: [Date] = c.edges.filter { $0 >= lowest && $0 <= Self.utcEnd && $0 > Self.utcStart }
                var mark = WristEndCrown.markAtOrAfter(lowest)
                while mark <= Self.utcEnd { expected.append(mark); mark = mark.addingTimeInterval(Self.q) }
                for want in expected where Self.keeps(start: s, end: e, stop: want, edges: c.edges) {
                    XCTAssertTrue(stops.contains { abs($0.timeIntervalSince(want)) < 0.5 }, "\(s)…\(e): skipped \(want)")
                }
            }
        }
        XCTAssertGreaterThan(total, 10_000)
    }

    /// Off the grid, the first detent goes to the next grid mark that way —
    /// or a neighbour edge in between.
    func testOffGridEndFirstDetentGoesToTheNextMarkEachWay() {
        for r in 1..<15 {
            let s = Self.at(9, 0), e = Self.at(11, r)
            guard let c = config(s, e) else { return }
            var up = WristEndCrown(c); XCTAssertEqual(up.turn(1), .moved); XCTAssertEqual(up.target, Self.at(11, 15))
            var down = WristEndCrown(c); XCTAssertEqual(down.turn(-1), .moved); XCTAssertEqual(down.target, Self.at(11, 0))
        }
        guard let c = config(Self.at(9, 0), Self.at(11, 7), edges: [Self.at(11, 10), Self.at(10, 52)]) else { return }
        var up = WristEndCrown(c); _ = up.turn(1); XCTAssertEqual(up.target, Self.at(11, 10))
        var down = WristEndCrown(c); _ = down.turn(-1); XCTAssertEqual(down.target, Self.at(11, 0))
        _ = down.turn(-1); XCTAssertEqual(down.target, Self.at(10, 52))
    }

    /// The predecessor's bug: start 10:13, end 11:00 — the lowest stop must
    /// be one the phone keeps (10:30), never 10:28 (stored as 10:30).
    func testOffGridStartLowestStopIsKeptForEveryMinuteOffset() {
        for r in 0..<15 {
            let s = Self.at(10, r), e = Self.at(12, 0)
            guard let c = config(s, e) else { return }
            var crown = WristEndCrown(c)
            while crown.turn(-1) == .moved {}
            XCTAssertTrue(Self.keeps(start: s, end: e, stop: crown.target, edges: []),
                          "start 10:\(r): lowest stop \(crown.target) is stored as \(Self.phoneStores(start: s, oldEnd: e, requested: crown.target, edges: []))")
            XCTAssertGreaterThanOrEqual(crown.target.timeIntervalSince(s), 15 * 60)
            XCTAssertLessThan(crown.target.timeIntervalSince(s), 30 * 60, "the shortest reachable end is within a quarter of the minimum")
        }
        guard let c = config(Self.at(10, 13), Self.at(11, 0)) else { return }
        var crown = WristEndCrown(c)
        while crown.turn(-1) == .moved {}
        XCTAssertEqual(crown.target, Self.at(10, 30))
    }

    /// Minimum: 10:00–11:00 goes down to 10:15 and no further; back moves at once.
    func testMinimumDurationLimit() {
        guard let c = config(Self.at(10, 0), Self.at(11, 0)) else { return }
        var crown = WristEndCrown(c)
        for want in [Self.at(10, 45), Self.at(10, 30), Self.at(10, 15)] {
            XCTAssertEqual(crown.turn(-1), .moved); XCTAssertEqual(crown.target, want)
        }
        XCTAssertEqual(crown.turn(-1), .limit)
        XCTAssertEqual(crown.target, Self.at(10, 15))
        XCTAssertEqual(crown.turn(1), .moved)
        XCTAssertEqual(crown.target, Self.at(10, 30))
        // Already shorter than the minimum: it cannot go shorter.
        guard let short = config(Self.at(10, 0), Self.at(10, 5)) else { return }
        var s = WristEndCrown(short)
        XCTAssertEqual(s.turn(-1), .limit)
        XCTAssertEqual(s.turn(1), .moved); XCTAssertEqual(s.target, Self.at(10, 15))
    }

    /// Midnight: the last stop is midnight, then a limit; an event ending at
    /// midnight only moves earlier; one ending tomorrow is not crown-edited.
    func testMidnightLimit() {
        for endMinute in stride(from: 22 * 60, through: 24 * 60, by: 1) {
            guard let c = config(Self.at(21, 0), Self.at(0, endMinute)) else { return }
            var crown = WristEndCrown(c)
            while crown.turn(1) == .moved {}
            XCTAssertEqual(crown.target, Self.utcEnd, "end \(endMinute)")
            XCTAssertEqual(crown.turn(1), .limit)
        }
        let tomorrow = WristEndCrown.availability(
            start: Self.at(23, 0), end: Self.at(24, 30), isOpenEnded: false, quickActionsEnabled: true, isRunning: false,
            takesRangeEdits: true, dayStart: Self.utcStart, dayEnd: Self.utcEnd, now: Self.utcStart, edges: []
        )
        XCTAssertEqual(tomorrow, .refused(.endsAnotherDay))
    }

    /// DST days (America/New_York 2026-03-08, 23 h; 2026-11-01, 25 h): every
    /// real quarter hour is a stop, none doubled or skipped across the jump,
    /// and the last is local midnight; the phone keeps each.
    func testDSTDaysWalkEveryRealQuarterHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        for (d, hours) in [((2026, 3, 8), 23.0), ((2026, 11, 1), 25.0)] {
            let dayStart = cal.date(from: DateComponents(year: d.0, month: d.1, day: d.2))!
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
            XCTAssertEqual(dayEnd.timeIntervalSince(dayStart), hours * 3600)
            guard let c = config(dayStart, dayStart.addingTimeInterval(3600), dayStart: dayStart, dayEnd: dayEnd) else { return }
            var crown = WristEndCrown(c)
            while crown.turn(-1) == .moved {}
            var walked = [crown.target]
            while crown.turn(1) == .moved { walked.append(crown.target) }
            XCTAssertEqual(walked.first, dayStart.addingTimeInterval(Self.q))
            XCTAssertEqual(walked.last, dayEnd)
            XCTAssertEqual(walked.count, Int(hours * 4), "\(d)")
            for (a, b) in zip(walked, walked.dropFirst()) { XCTAssertEqual(b.timeIntervalSince(a), Self.q) }
            XCTAssertTrue(walked.allSatisfy { Self.keeps(start: dayStart, end: c.end, stop: $0, edges: []) })
        }
    }

    /// In from yesterday: the send keeps yesterday's start, and no stop puts
    /// the end before a quarter hour into today.
    func testEventInFromYesterday() {
        let s = Self.utcStart.addingTimeInterval(-3600), e = Self.at(1, 0)
        guard let c = config(s, e) else { return }
        var crown = WristEndCrown(c)
        while crown.turn(-1) == .moved {}
        XCTAssertGreaterThanOrEqual(crown.target, Self.at(0, 15))
        _ = crown.turn(1)
        XCTAssertEqual(crown.takeUnsent()?.start, s)
    }

    /// Not editable: repeating, a phone timer, a phone without range edits.
    func testRefusals() {
        func a(editable: Bool = true, open: Bool = false, takes: Bool = true, running: Bool = false) -> WristEndCrown.Availability {
            WristEndCrown.availability(
                start: Self.at(10, 0), end: Self.at(11, 0), isOpenEnded: open, quickActionsEnabled: editable, isRunning: running,
                takesRangeEdits: takes, dayStart: Self.utcStart, dayEnd: Self.utcEnd, now: Self.at(10, 30), edges: []
            )
        }
        XCTAssertEqual(a(editable: false), .refused(.notEditable))
        XCTAssertEqual(a(open: true), .refused(.notEditable))
        XCTAssertEqual(a(takes: false), .refused(.phoneTooOld))
        XCTAssertEqual(a(takes: false, running: true), .refused(.phoneTooOld))
        if case .refused = a() { XCTFail("positive control: an ordinary event moves") }
    }

    // MARK: 2. End to end through the phone's real applier

    func testEveryStopIsStoredUnchangedByThePhonesApplier() {
        let location = TestStorage.reset(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        defer { TestStorage.tearDown(suiteName) }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_773_144_000))
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        func at(_ h: Int, _ m: Int) -> Date { dayStart.addingTimeInterval(Double(h * 3600 + m * 60)) }
        let neighbours: [Event] = [
            Event(id: UUID(), title: "A", timeRanges: [.init(start: at(8, 0), end: at(9, 7))], type: "A"),
            Event(id: UUID(), title: "B", timeRanges: [.init(start: at(11, 10), end: at(11, 52))], type: "B"),
            Event(id: UUID(), title: "C", timeRanges: [.init(start: at(13, 3), end: at(14, 0))], type: "C"),
            Event(id: UUID(), title: "Y", timeRanges: [.init(start: at(-1, 0), end: at(0, 40))], type: "Y"),
            Event(id: UUID(), title: "L", timeRanges: [.init(start: at(22, 26), end: at(23, 11))], type: "L"),
        ]
        var timer = Event(id: UUID(), title: "T", timeRanges: [.init(start: at(18, 2), end: at(18, 47))], type: "T")
        timer.timerStartedAt = at(18, 2)
        for e in neighbours + [timer] { store.addCalendarEvent(e) }
        let targets: [[Event.TimeRange]] = [
            [.init(start: at(10, 0), end: at(10, 50))],
            [.init(start: at(9, 7), end: at(10, 0))],
            [.init(start: at(10, 7), end: at(10, 22))],
            [.init(start: at(12, 0), end: at(12, 5))],
            [.init(start: at(-1, 30), end: at(0, 20))],
            [.init(start: at(23, 0), end: at(24, 0))],
            [.init(start: at(16, 13), end: at(17, 41))],
            [.init(start: at(14, 20), end: at(14, 33)), .init(start: at(15, 20), end: at(15, 40))],
        ]
        let now = at(6, 0)
        var applied = 0
        for ranges in targets {
            let event = Event(id: UUID(), title: "X", timeRanges: ranges, type: "X")
            store.addCalendarEvent(event)
            let snapshot = WristSnapshotBuilder.snapshot(
                events: store.canvasRenderableCalendarEvents, templates: [], now: now,
                calendar: calendar, language: nil, receipts: [], colorHex: { _ in "#000000" }
            )
            let blocks = WristDayLayout.blocks(snapshot.occurrences, dismissed: [], dayStart: dayStart, dayEnd: dayEnd, now: now, currentID: nil)
            for range in ranges {
                guard let block = blocks.first(where: { $0.occurrence.eventID == event.id && WristTiming.sameInstant($0.occurrence.start, range.start) }) else {
                    XCTFail("block for \(range)"); continue
                }
                guard let subject = WristEventSubject.resolve(selectedKey: block.motionKey, blocks: blocks, running: nil) else {
                    XCTFail("selected block is the subject"); continue
                }
                XCTAssertEqual(subject.source, .selected)
                guard case .moves(let c) = WristEndCrown.availability(
                    for: subject, blocks: blocks, takesRangeEdits: true, dayStart: dayStart, dayEnd: dayEnd, now: now
                ) else { XCTFail("moves"); continue }
                var crown = WristEndCrown(c)
                while crown.turn(-1) == .moved {}
                repeat {
                    var probe = crown
                    guard let span = probe.takeUnsent(now: now) else { continue }
                    let receipt = WristCommandApplier.apply(
                        WristCommand(id: UUID(), issuedAt: now, kind: .setRange(eventID: event.id, rangeStart: block.occurrence.start, start: span.start, end: span.end)),
                        to: store
                    )
                    XCTAssertEqual(receipt.outcome, .applied)
                    let stored = store.findCalendarEvent(id: event.id)?.timeRanges.first { WristTiming.sameInstant($0.start, range.start) }
                    XCTAssertEqual(stored?.end, span.end, "phone stored another end for \(range.start)…\(range.end) → \(span.end)")
                    applied += 1
                    var back = store.findCalendarEvent(id: event.id)!
                    back.timeRanges = ranges
                    store.updateCalendarEvent(back)
                } while crown.turn(1) == .moved
            }
            store.deleteCalendarEvent(store.findCalendarEvent(id: event.id)!)
        }
        XCTAssertGreaterThan(applied, 300)
    }

    // MARK: 3. Running session — moved like any other event (spec change 10-30)

    private func lowest(_ c: WristEndCrown.Config) -> Date {
        var crown = WristEndCrown(c)
        while crown.turn(-1) == .moved {}
        return crown.target
    }

    /// Whatever now is, a running session's stops are exactly those of the
    /// same range not running: down to start + 15 min, now never consulted.
    func testRunningSessionStopsAreThoseOfAnyEvent() {
        let s = Self.at(20, 0), e = Self.at(23, 0)
        guard let plain = config(s, e) else { return }
        let plainStops = WristEndCrown.stops(for: plain, keeping: nil)
        for tick in 0..<(4 * 360) {
            let now = s.addingTimeInterval(Double(tick) * 10)
            guard let c = config(s, e, running: true, now: now) else { return }
            XCTAssertEqual(WristEndCrown.stops(for: c, keeping: nil), plainStops, "now \(now)")
        }
        // Independent values: the spec's old examples no longer hold.
        for now in [Self.at(21, 26), Self.at(21, 28), Self.at(21, 29), Self.at(22, 50)] {
            guard let c = config(s, e, running: true, now: now) else { return }
            XCTAssertEqual(lowest(c), Self.at(20, 15), "now \(now): down to start + 15 min")
        }
        // Just started at 21:20 (now 21:21): start + 15 = 21:35, which the phone keeps.
        guard let fresh = config(Self.at(21, 20), e, running: true, now: Self.at(21, 21)) else { return }
        XCTAssertEqual(lowest(fresh), Self.at(21, 35))
        XCTAssertEqual(Self.phoneStores(start: Self.at(21, 20), oldEnd: e, requested: Self.at(21, 35), edges: []), Self.at(21, 35))
        // Off-grid start 21:13: start + 15 (21:28) is stored as 21:30, so 21:30.
        guard let off = config(Self.at(21, 13), e, running: true, now: Self.at(21, 14)) else { return }
        XCTAssertEqual(lowest(off), Self.at(21, 30))
    }

    /// The send is the end chosen, whenever it goes: no lift against the
    /// real clock, even when the end is already past.
    func testRunningSessionSendIsNotLiftedByTheClock() {
        let s = Self.at(20, 0), e = Self.at(23, 0)
        guard let c = config(s, e, running: true, now: Self.at(21, 26)) else { return }
        var crown = WristEndCrown(c)
        while crown.target > Self.at(21, 30) { XCTAssertEqual(crown.turn(-1), .moved) }
        XCTAssertEqual(crown.target, Self.at(21, 30))
        for real in [Self.at(21, 26), Self.at(21, 29), Self.at(21, 44), Self.at(22, 30)] {
            var probe = crown
            XCTAssertEqual(probe.takeUnsent(now: real)?.end, Self.at(21, 30), "sent at \(real)")
        }
        // Through the session too (its send takes the real time).
        let r = Self.occ(s, e)
        let day = Day(occurrences: [r], now: Self.at(21, 26), running: r)
        var session = WristEndCrownSession()
        _ = day.show(&session, selected: nil)
        for _ in 0..<20 { _ = session.turn(crownDelta: -WristEndCrown.crownLater) }
        XCTAssertEqual(session.shownEnd, Self.at(20, 15))
        XCTAssertEqual(session.takeUnsent(now: Self.at(22, 0))?.end, Self.at(20, 15), "a running session may be shortened into the past")
    }

    // MARK: 3b. − / + taps

    /// Several taps accumulate into one send at rest: + + + − is two stops
    /// later, sent once; nothing goes before the rest.
    func testTapsAccumulateIntoOneSend() {
        let a = Self.occ(Self.at(10, 0), Self.at(11, 7))
        let day = Day(occurrences: [a])
        var session = WristEndCrownSession()
        _ = day.show(&session, selected: day.key(of: a.id))
        let plus = WristEndCrown.crownLater, minus = -WristEndCrown.crownLater
        for d in [plus, plus, plus, minus] { XCTAssertEqual(session.turn(crownDelta: d)?.moved, true) }
        // From an off-grid 11:07: 11:15, 11:30, 11:45, back to 11:30.
        XCTAssertEqual(session.shownEnd, Self.at(11, 30))
        let sends = [session.takeUnsent(now: day.now), session.takeUnsent(now: day.now)].compactMap { $0 }
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.start, Self.at(10, 0))
        XCTAssertEqual(sends.first?.end, Self.at(11, 30))
        // − − back past the end and + + back to it: nothing to send.
        var back = WristEndCrownSession()
        _ = day.show(&back, selected: day.key(of: a.id))
        for d in [minus, minus, plus, plus] { _ = back.turn(crownDelta: d) }
        XCTAssertEqual(back.shownEnd, Self.at(11, 7))
        XCTAssertNil(back.takeUnsent(now: day.now))
    }

    /// A tap at a limit does nothing: + at midnight, − at the minimum; the
    /// button reads disabled (`canStep`) and nothing is sent.
    func testTapAtALimitDoesNothing() {
        let late = Self.occ(Self.at(23, 0), Self.at(23, 45))
        let day = Day(occurrences: [late])
        var session = WristEndCrownSession()
        _ = day.show(&session, selected: day.key(of: late.id))
        XCTAssertTrue(session.canStep(1))
        XCTAssertEqual(session.turn(crownDelta: WristEndCrown.crownLater)?.moved, true)
        XCTAssertEqual(session.shownEnd, Self.utcEnd)
        XCTAssertFalse(session.canStep(1))
        XCTAssertTrue(session.canStep(-1))
        XCTAssertEqual(session.turn(crownDelta: WristEndCrown.crownLater)?.moved, false)
        XCTAssertEqual(session.shownEnd, Self.utcEnd)
        XCTAssertEqual(session.takeUnsent(now: day.now)?.end, Self.utcEnd, "the one move before the limit is sent")

        let short = Self.occ(Self.at(10, 0), Self.at(10, 15))
        let d2 = Day(occurrences: [short])
        var min = WristEndCrownSession()
        _ = d2.show(&min, selected: d2.key(of: short.id))
        XCTAssertFalse(min.canStep(-1))
        XCTAssertEqual(min.turn(crownDelta: -WristEndCrown.crownLater)?.moved, false)
        XCTAssertEqual(min.shownEnd, Self.at(10, 15))
        XCTAssertNil(min.takeUnsent(now: d2.now), "a tap at the limit sends nothing")
        // Not editable (repeating): neither button moves anything.
        let rep = Self.occ(UUID(), id: "rep", Self.at(12, 0), Self.at(13, 0), editable: false)
        let d3 = Day(occurrences: [rep])
        var none = WristEndCrownSession()
        _ = d3.show(&none, selected: d3.key(of: "rep"))
        XCTAssertFalse(none.canStep(1)); XCTAssertFalse(none.canStep(-1))
        XCTAssertNil(none.turn(crownDelta: 1))
        XCTAssertNil(none.takeUnsent(now: d3.now))
    }

    // MARK: 4. Subject

    func testSubjectIsSelectedThenRunningThenNone() {
        let a = Self.occ(Self.at(9, 0), Self.at(10, 0))
        let r = Self.occ(Self.at(10, 0), Self.at(11, 0))
        let blocks = WristDayLayout.blocks([a, r], dismissed: [], dayStart: Self.utcStart, dayEnd: Self.utcEnd, now: Self.at(10, 30), currentID: r.id)
        let keyA = blocks.first { $0.occurrence.id == a.id }!.motionKey
        let keyR = blocks.first { $0.occurrence.id == r.id }!.motionKey

        let selected = WristEventSubject.resolve(selectedKey: keyA, blocks: blocks, running: r)
        XCTAssertEqual(selected?.occurrence.id, a.id); XCTAssertEqual(selected?.source, .selected)
        XCTAssertEqual(selected?.isRunning, false)

        let fallback = WristEventSubject.resolve(selectedKey: nil, blocks: blocks, running: r)
        XCTAssertEqual(fallback?.occurrence.id, r.id); XCTAssertEqual(fallback?.source, .running)
        XCTAssertEqual(fallback?.isRunning, true)
        XCTAssertEqual(fallback?.key, keyR, "running block's key is its block's, so selecting it keeps a turn")

        let runningSelected = WristEventSubject.resolve(selectedKey: keyR, blocks: blocks, running: r)
        XCTAssertEqual(runningSelected?.isRunning, true, "a selected running block keeps the running floor")

        XCTAssertNil(WristEventSubject.resolve(selectedKey: nil, blocks: blocks, running: nil))
        // A selection no longer on the page counts as none.
        let gone = WristEventSubject.resolve(selectedKey: "\(UUID().uuidString)#0", blocks: blocks, running: r)
        XCTAssertEqual(gone?.occurrence.id, r.id)
        XCTAssertNil(WristEventSubject.resolve(selectedKey: "\(UUID().uuidString)#0", blocks: blocks, running: nil))
    }

    // MARK: 5. Session: sending at rest, refusals, mid-turn subject changes

    private struct Day {
        var occurrences: [WristOccurrence]
        var now = WristEventPageQATests.at(6, 0)
        var running: WristOccurrence? = nil
        var blocks: [WristDayBlock] {
            WristDayLayout.blocks(occurrences, dismissed: [], dayStart: WristEventPageQATests.utcStart, dayEnd: WristEventPageQATests.utcEnd, now: now, currentID: running?.id)
        }
        func key(of id: String) -> String? { blocks.first { $0.occurrence.id == id }?.motionKey }
        func show(_ session: inout WristEndCrownSession, selected: String?) -> Bool {
            show(&session, subject: WristEventSubject.resolve(selectedKey: selected, blocks: blocks, running: running))
        }
        /// The view's path: the selection is held as (event, range start).
        func show(_ session: inout WristEndCrownSession, selection: WristEventSubject.Selection?) -> Bool {
            show(&session, subject: WristEventSubject.resolve(selection: selection, blocks: blocks, running: running))
        }
        func show(_ session: inout WristEndCrownSession, subject: WristEventSubject?) -> Bool {
            let b = blocks
            let availability = subject.map {
                WristEndCrown.availability(for: $0, blocks: b, takesRangeEdits: true,
                                           dayStart: WristEventPageQATests.utcStart, dayEnd: WristEventPageQATests.utcEnd, now: now)
            }
            return session.show(subject, availability: availability)
        }
    }

    /// Turning sends nothing; the rest sends once, the last target, with the
    /// event's own start; turning back to the end sends nothing.
    func testSendsOnlyOnceAtRest() {
        let a = Self.occ(Self.at(10, 0), Self.at(11, 0))
        let day = Day(occurrences: [a])
        var session = WristEndCrownSession()
        _ = day.show(&session, selected: day.key(of: a.id))
        XCTAssertEqual(session.shownEnd, Self.at(11, 0))
        for _ in 0..<3 { _ = session.turn(crownDelta: WristEndCrown.crownLater) }
        XCTAssertEqual(session.shownEnd, Self.at(11, 45))
        _ = session.turn(crownDelta: -WristEndCrown.crownLater)
        let send = session.takeUnsent(now: day.now)
        XCTAssertEqual(send?.start, Self.at(10, 0)); XCTAssertEqual(send?.end, Self.at(11, 30))
        XCTAssertEqual(send?.occurrence.eventID, a.eventID)
        XCTAssertNil(session.takeUnsent(now: day.now), "sent once")

        var back = WristEndCrownSession()
        _ = day.show(&back, selected: day.key(of: a.id))
        _ = back.turn(crownDelta: 2); _ = back.turn(crownDelta: -2)
        XCTAssertNil(back.takeUnsent(now: day.now), "back at its end: nothing to send")
    }

    /// The crown's sign: the turn that scrolls Today later (`crownLater`)
    /// makes the end later, the other earlier — in one constant.
    func testDirectionFollowsTheNamedConstant() {
        XCTAssertEqual(abs(WristEndCrown.crownLater), 1)
        XCTAssertEqual(WristEndCrown.direction(ofCrownDelta: WristEndCrown.crownLater), 1)
        XCTAssertEqual(WristEndCrown.direction(ofCrownDelta: -WristEndCrown.crownLater), -1)
        XCTAssertEqual(WristEndCrown.direction(ofCrownDelta: 3 * WristEndCrown.crownLater), 1)
        XCTAssertEqual(WristEndCrown.direction(ofCrownDelta: 0), 0)
    }

    /// Refused: the page snaps back to the phone's end and does not resend.
    /// Applied: the snapshot carries it and nothing more goes. Through the
    /// real overlay, either order of settle/show.
    func testRefusedSnapsBackAppliedDoesNotResend() {
        let eventID = UUID()
        let s = Self.at(10, 0), e = Self.at(11, 0)
        let base = Self.occ(eventID, id: "b", s, e)
        func day(_ snapEnd: Date, _ pending: [WristPendingCommand]) -> (Day, Set<UUID>) {
            let snap = WristSnapshot(generatedAt: Self.utcStart, types: [], occurrences: [Self.occ(eventID, id: "b", s, snapEnd)], receipts: [], takesRangeEdits: true)
            let o = WristStateReducer.overlaid(snap, pending: pending, now: Self.at(6, 0))
            return (Day(occurrences: o.occurrences), o.pendingEventIDs)
        }
        for settleFirst in [false, true] {
            var session = WristEndCrownSession()
            let (d0, _) = day(e, [])
            let key = d0.key(of: base.id)
            _ = d0.show(&session, selected: key)
            _ = session.turn(crownDelta: 2 * WristEndCrown.crownLater)
            guard let send = session.takeUnsent(now: d0.now) else { return XCTFail("send") }
            XCTAssertEqual(send.end, Self.at(11, 30))
            let cmd = WristCommand(id: UUID(), issuedAt: Self.at(6, 0), kind: .setRange(eventID: eventID, rangeStart: s, start: send.start, end: send.end))
            let pending = [WristPendingCommand(command: cmd, sentAt: Self.at(6, 0))]
            let (d1, ids1) = day(e, pending)
            _ = d1.show(&session, selected: key)
            session.settle(pendingEventIDs: ids1)
            XCTAssertEqual(session.shownEnd, Self.at(11, 30), "pending shows the send")
            var refused = session
            let after = WristStateReducer.acknowledge(pending, receipt: WristReceipt(id: cmd.id, outcome: .rejected, reason: "x"), repliedAt: nil, now: Self.at(6, 0))
            let (d2, ids2) = day(e, after)
            if settleFirst { refused.settle(pendingEventIDs: ids2); _ = d2.show(&refused, selected: key) }
            else { _ = d2.show(&refused, selected: key); refused.settle(pendingEventIDs: ids2) }
            XCTAssertEqual(refused.shownEnd, e, "refused edit snaps back (settleFirst=\(settleFirst))")
            XCTAssertNil(refused.takeUnsent(now: d2.now), "and is not resent")

            var applied = session
            let (d3, ids3) = day(Self.at(11, 30), [])
            _ = d3.show(&applied, selected: key)
            applied.settle(pendingEventIDs: ids3)
            XCTAssertEqual(applied.shownEnd, Self.at(11, 30))
            XCTAssertNil(applied.takeUnsent(now: d3.now))
            _ = applied.turn(crownDelta: WristEndCrown.crownLater)
            XCTAssertEqual(applied.shownEnd, Self.at(11, 45), "counts on from the applied end")
        }
    }

    /// Selection moves to another event mid-turn: the unsent turn is never
    /// sent for the new subject; the page shows the new subject's own end.
    func testSelectionChangeMidTurnNeverAppliesTheTurnToTheOtherEvent() {
        let a = Self.occ(Self.at(10, 0), Self.at(11, 0))
        let b = Self.occ(Self.at(13, 0), Self.at(14, 0))
        let day = Day(occurrences: [a, b])
        var session = WristEndCrownSession()
        _ = day.show(&session, selected: day.key(of: a.id))
        _ = session.turn(crownDelta: 3 * WristEndCrown.crownLater)
        _ = day.show(&session, selected: day.key(of: b.id))
        XCTAssertEqual(session.shownEnd, Self.at(14, 0))
        let send = session.takeUnsent(now: day.now)
        XCTAssertNil(send, "A's turn must not go to B: \(String(describing: send))")
        // Positive control: a turn on B itself does go, to B.
        _ = session.turn(crownDelta: WristEndCrown.crownLater)
        XCTAssertEqual(session.takeUnsent(now: day.now)?.occurrence.eventID, b.eventID)
    }

    /// The selected event vanishes mid-turn: selection resolves to the
    /// running session (or none); nothing of the turn is sent for it.
    func testSubjectVanishesMidTurn() {
        let a = Self.occ(Self.at(10, 0), Self.at(11, 0))
        let r = Self.occ(Self.at(5, 30), Self.at(7, 0))
        var day = Day(occurrences: [a, r], running: r)
        var session = WristEndCrownSession()
        let key = day.key(of: a.id)
        _ = day.show(&session, selected: key)
        _ = session.turn(crownDelta: -2 * WristEndCrown.crownLater)
        day.occurrences = [r]
        _ = day.show(&session, selected: key)
        XCTAssertEqual(session.shownEnd, Self.at(7, 0), "falls back to the running session")
        XCTAssertNil(session.takeUnsent(now: day.now))
        day.running = nil
        day.occurrences = []
        XCTAssertFalse(day.show(&session, selected: key))
        XCTAssertNil(session.shownEnd)
        XCTAssertNil(session.takeUnsent(now: day.now))
    }

    /// Two ranges of one event; the phone reorders them mid-turn (an earlier
    /// range is added). The motion key "event#ordinal" then names the other
    /// range: the turn made on the 14:00 range must not be sent as an edit of
    /// the 10:00 range.
    func testMultiRangeReorderMidTurnDoesNotMoveTheTurnToAnotherRange() {
        let eventID = UUID()
        let r1 = Self.occ(eventID, id: "r1", Self.at(10, 0), Self.at(11, 0))
        let r2 = Self.occ(eventID, id: "r2", Self.at(14, 0), Self.at(15, 0))
        var day = Day(occurrences: [r1, r2])
        var session = WristEndCrownSession()
        let key = day.key(of: r2.id)
        _ = day.show(&session, selected: key)
        _ = session.turn(crownDelta: WristEndCrown.crownLater) // 15:15 on the 14:00 range
        XCTAssertEqual(session.shownEnd, Self.at(15, 15))
        // The phone adds an 08:00 range to the same event.
        day.occurrences = [Self.occ(eventID, id: "r0", Self.at(8, 0), Self.at(9, 0)), r1, r2]
        _ = day.show(&session, selected: key)
        if let send = session.takeUnsent(now: day.now) {
            XCTAssertTrue(WristTiming.sameInstant(send.occurrence.start, Self.at(14, 0)),
                          "turn made on 14:00–15:00 sent as \(send.occurrence.start)…→\(send.end): another range of the event")
        }
    }

    /// The same reorder through the view's path (selection held as event +
    /// range start): the subject stays the 14:00 range and the turn goes to
    /// it, as turned.
    func testMultiRangeReorderMidTurnKeepsTheTurnOnItsRangeThroughTheViewsSelection() {
        let eventID = UUID()
        let r1 = Self.occ(eventID, id: "r1", Self.at(10, 0), Self.at(11, 0))
        let r2 = Self.occ(eventID, id: "r2", Self.at(14, 0), Self.at(15, 0))
        var day = Day(occurrences: [r1, r2])
        var session = WristEndCrownSession()
        let selection = WristEventSubject.Selection(r2)
        _ = day.show(&session, selection: selection)
        _ = session.turn(crownDelta: WristEndCrown.crownLater)
        day.occurrences = [Self.occ(eventID, id: "r0", Self.at(8, 0), Self.at(9, 0)), r1, r2]
        XCTAssertFalse(day.show(&session, selection: selection), "the turn is not dropped")
        XCTAssertEqual(session.shownEnd, Self.at(15, 15))
        let send = session.takeUnsent(now: day.now)
        XCTAssertEqual(send?.occurrence.start, Self.at(14, 0))
        XCTAssertEqual(send?.end, Self.at(15, 15))
    }

    /// A later turn not yet sent; the phone then moves the end past it
    /// (+15 on the phone). Sending the kept time would end the event EARLIER
    /// than it now does — the turn's direction flipped. Same for an earlier
    /// turn the phone undercuts.
    func testKeptTurnNeverFlipsDirectionWhenThePhoneMovesTheEndPastIt() {
        let eventID = UUID()
        let s = Self.at(10, 0)
        var day = Day(occurrences: [Self.occ(eventID, id: "x", s, Self.at(11, 0))])
        var session = WristEndCrownSession()
        let key = day.key(of: "x")
        _ = day.show(&session, selected: key)
        _ = session.turn(crownDelta: WristEndCrown.crownLater) // later: 11:15
        day.occurrences = [Self.occ(eventID, id: "x", s, Self.at(11, 30))]
        _ = day.show(&session, selected: key)
        if let send = session.takeUnsent(now: day.now) {
            XCTAssertGreaterThanOrEqual(send.end, Self.at(11, 30), "a later turn sent as \(send.end), shortening 11:30")
        }

        var down = WristEndCrownSession()
        day.occurrences = [Self.occ(eventID, id: "x", s, Self.at(12, 0))]
        _ = day.show(&down, selected: key)
        _ = down.turn(crownDelta: -WristEndCrown.crownLater) // earlier: 11:45
        day.occurrences = [Self.occ(eventID, id: "x", s, Self.at(11, 0))]
        _ = day.show(&down, selected: key)
        if let send = down.takeUnsent(now: day.now) {
            XCTAssertLessThanOrEqual(send.end, Self.at(11, 0), "an earlier turn sent as \(send.end), lengthening 11:00")
        }
    }

    /// The running session's turn is kept when the same block becomes the
    /// selected subject (same event, same key) — positive control for the
    /// drop rule — and Finish lets an unsent turn go.
    func testSameSubjectAcrossSourcesKeepsTheTurnFinishDropsIt() {
        let r = Self.occ(Self.at(5, 30), Self.at(7, 0))
        let day = Day(occurrences: [r], now: Self.at(6, 0), running: r)
        var session = WristEndCrownSession()
        _ = day.show(&session, selected: nil)
        _ = session.turn(crownDelta: WristEndCrown.crownLater)
        let turned = session.shownEnd
        XCTAssertEqual(turned, Self.at(7, 15))
        XCTAssertFalse(day.show(&session, selected: day.key(of: r.id)))
        XCTAssertEqual(session.shownEnd, turned)
        session.discardUnsent()
        XCTAssertNil(session.takeUnsent(now: day.now))
    }

    /// Random sequences of turns, sends and day changes: whatever is sent is
    /// for the subject shown, starts at its start, is kept by the phone,
    /// at least the minimum long and within the day.
    func testRandomSequencesOnlySendWhatThePhoneKeeps() {
        var rng = LCG(state: 99)
        for _ in 0..<300 {
            let ids = (0..<3).map { _ in UUID() }
            func random() -> [WristOccurrence] {
                ids.compactMap { id -> WristOccurrence? in
                    guard rng.next() % 6 != 0 else { return nil }
                    let s = Self.at(0, Int(rng.next() % (20 * 60)))
                    return Self.occ(id, id: id.uuidString, s, s.addingTimeInterval(Double(5 + rng.next() % 200) * 60))
                }
            }
            var day = Day(occurrences: random())
            var session = WristEndCrownSession()
            var selected: String? = day.blocks.first?.motionKey
            _ = day.show(&session, selected: selected)
            for _ in 0..<25 {
                switch rng.next() % 6 {
                case 0, 1, 2: _ = session.turn(crownDelta: rng.next() % 2 == 0 ? 1 : -1)
                case 3:
                    let shownOcc = session.occurrence
                    if let send = session.takeUnsent(now: day.now) {
                        XCTAssertEqual(send.occurrence.eventID, shownOcc?.eventID)
                        XCTAssertEqual(send.start, send.occurrence.start)
                        let edges = WristEventSubject.neighbourEdges(of: session.key ?? "", in: day.blocks).filter { $0 > Self.utcStart && $0 <= Self.utcEnd }
                        XCTAssertTrue(Self.keeps(start: send.start, end: send.occurrence.end, stop: send.end, edges: edges),
                                      "\(send.occurrence.start)…\(send.occurrence.end) → \(send.end)")
                        XCTAssertGreaterThanOrEqual(send.end.timeIntervalSince(send.start), 15 * 60 - 0.001)
                        XCTAssertLessThanOrEqual(send.end, Self.utcEnd)
                    }
                case 4:
                    day.occurrences = random()
                    _ = day.show(&session, selected: selected)
                default:
                    selected = day.blocks.randomElement(using: &rng)?.motionKey
                    _ = day.show(&session, selected: selected)
                }
            }
        }
    }
}
