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

    // MARK: 3. Running session

    /// For every minute of a run: no stop other than the end it has is at or
    /// before now, and what is sent up to a minute later still ends after
    /// the real time it is sent at.
    func testRunningSessionCanNeverBeEndedByTheCrown() {
        let s = Self.at(10, 0)
        for minute in 0..<180 {
            let now = s.addingTimeInterval(Double(minute) * 60 + 20)
            let e = s.addingTimeInterval(4 * 3600)
            guard let c = config(s, e, running: true, now: now) else { return }
            var crown = WristEndCrown(c)
            for stop in crown.stops where stop != e {
                XCTAssertGreaterThan(stop, now, "stop \(stop) at or before now \(now)")
            }
            while crown.turn(-1) == .moved {}
            let real = now.addingTimeInterval(59)
            if let span = crown.takeUnsent(now: real) {
                XCTAssertGreaterThan(span.end, real, "sent an end already past at \(real)")
                XCTAssertTrue(Self.keeps(start: s, end: e, stop: span.end, edges: []))
            }
        }
        // Positive control: a non-running event may be shortened into the past.
        guard let past = config(s, s.addingTimeInterval(4 * 3600), now: Self.at(13, 0)) else { return }
        var p = WristEndCrown(past)
        while p.turn(-1) == .moved {}
        XCTAssertLessThan(p.target, Self.at(13, 0))
    }

    // MARK: 3b. Running floor — first quarter mark at least 2 minutes ahead (spec change 10-29)

    /// Independent: the first 15-minute mark at or after now + 2 min.
    private static func expectedRunningFloor(_ now: Date) -> Date {
        let t = now.addingTimeInterval(120).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / q).rounded(.up) * q)
    }

    private func runningLowest(now: Date, start: Date = at(20, 0), end: Date = at(23, 0)) -> Date? {
        guard let c = config(start, end, running: true, now: now) else { return nil }
        var crown = WristEndCrown(c)
        while crown.turn(-1) == .moved {}
        return crown.target
    }

    /// The spec's examples and the 2-minute boundary on both sides.
    func testRunningFloorIsTheFirstMarkTwoMinutesAhead() {
        XCTAssertEqual(runningLowest(now: Self.at(21, 26)), Self.at(21, 30), "spec: 21:26 → 21:30")
        XCTAssertEqual(runningLowest(now: Self.at(21, 29)), Self.at(21, 45), "spec: 21:29 → 21:45")
        XCTAssertEqual(runningLowest(now: Self.at(21, 28)), Self.at(21, 30), "exactly 2 min ahead is allowed")
        XCTAssertEqual(runningLowest(now: Self.at(21, 28).addingTimeInterval(1)), Self.at(21, 45), "1 s under 2 min is not")
        XCTAssertEqual(runningLowest(now: Self.at(21, 27).addingTimeInterval(59)), Self.at(21, 30))
        XCTAssertEqual(runningLowest(now: Self.at(21, 30)), Self.at(21, 45), "on a mark: the mark itself is 0 min ahead")
        XCTAssertEqual(runningLowest(now: Self.at(21, 13)), Self.at(21, 15))
        // Positive control: a non-running event still goes down to start + 15.
        guard let c = config(Self.at(20, 0), Self.at(23, 0), now: Self.at(21, 26)) else { return }
        var idle = WristEndCrown(c)
        while idle.turn(-1) == .moved {}
        XCTAssertEqual(idle.target, Self.at(20, 15))
    }

    /// Every 10 s over two hours: the lowest stop is the independent floor;
    /// no stop other than the end it has is under it; the minimum length
    /// still holds for a session that just started.
    func testRunningFloorSweep() {
        var checked = 0
        for tick in 0..<(2 * 360) {
            let now = Self.at(20, 0).addingTimeInterval(Double(tick) * 10)
            let floor = Self.expectedRunningFloor(now)
            guard let c = config(Self.at(20, 0), Self.at(23, 0), running: true, now: now) else { return }
            let crown = WristEndCrown(c)
            let want = max(floor, Self.at(20, 15))
            XCTAssertEqual(crown.stops.first(where: { $0 != Self.at(23, 0) }), want, "now \(now)")
            for stop in crown.stops where stop != Self.at(23, 0) {
                XCTAssertGreaterThanOrEqual(stop.timeIntervalSince(now), 120 - 0.001)
            }
            checked += 1
        }
        XCTAssertEqual(checked, 720)
        // Just started at 21:20, now 21:21: the minimum (21:35) is above the
        // 21:30 mark and ahead of now; the phone keeps it (its snap to 21:30
        // is lifted back to start + 15).
        XCTAssertEqual(runningLowest(now: Self.at(21, 21), start: Self.at(21, 20)), Self.at(21, 35))
        XCTAssertEqual(Self.phoneStores(start: Self.at(21, 20), oldEnd: Self.at(23, 0), requested: Self.at(21, 35), edges: []), Self.at(21, 35))
        // Off-grid start 21:13, now 21:14: floor mark 21:30 ≥ 21:28 and kept by the phone.
        XCTAssertEqual(runningLowest(now: Self.at(21, 14), start: Self.at(21, 13)), Self.at(21, 30))
    }

    /// At send the chosen end is rechecked against the real clock: no longer
    /// 2 minutes ahead → the next mark that is; still ahead → as chosen.
    func testRunningSendRechecksTheRealClock() {
        guard let c = config(Self.at(20, 0), Self.at(23, 0), running: true, now: Self.at(21, 26)) else { return }
        var crown = WristEndCrown(c)
        while crown.turn(-1) == .moved {}
        XCTAssertEqual(crown.target, Self.at(21, 30))
        var onTime = crown
        XCTAssertEqual(onTime.takeUnsent(now: Self.at(21, 28))?.end, Self.at(21, 30), "exactly 2 min ahead at send: kept")
        var late = crown
        XCTAssertEqual(late.takeUnsent(now: Self.at(21, 28).addingTimeInterval(30))?.end, Self.at(21, 45), "21:30 is 90 s ahead: lifts")
        var later = crown
        XCTAssertEqual(later.takeUnsent(now: Self.at(21, 44))?.end, Self.at(22, 0))

        // A lengthening turn of a session about to end, sent late: still never ends it.
        guard let s = config(Self.at(20, 0), Self.at(21, 30), running: true, now: Self.at(21, 26)) else { return }
        var ending = WristEndCrown(s)
        XCTAssertEqual(ending.turn(1), .moved)
        XCTAssertEqual(ending.target, Self.at(21, 45))
        let real = Self.at(21, 44)
        let sent = ending.takeUnsent(now: real)
        XCTAssertNotNil(sent)
        if let sent {
            XCTAssertGreaterThanOrEqual(sent.end.timeIntervalSince(real), 120, "sent \(sent.end) at \(real)")
            XCTAssertEqual(sent.end, Self.at(22, 0))
        }
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
