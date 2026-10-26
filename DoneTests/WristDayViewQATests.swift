import XCTest
@testable import Done

/// Independent QA for the watch's Today/Stats pages (a2bbf84): weekOnly
/// equivalence, day-layout properties, snapshot size. Fixed seeds throughout.
@MainActor
final class WristDayViewQATests: XCTestCase {

    // MARK: - RNG

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func calendar(_ zone: String, firstWeekday: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        cal.firstWeekday = firstWeekday
        cal.minimumDaysInFirstWeek = 1
        return cal
    }

    private let types = ["Work", "Gym", "Read", "Meet", "Chores"]

    /// Random events over [anchor-45d, anchor+45d], several per day, some
    /// overlapping, some across midnight, some interrupts.
    private func events(around anchor: Date, calendar: Calendar, rng: inout SplitMix) -> [Event] {
        var result: [Event] = []
        let first = calendar.date(byAdding: .day, value: -45, to: calendar.startOfDay(for: anchor))!
        for d in 0..<90 {
            guard let day = calendar.date(byAdding: .day, value: d, to: first) else { continue }
            let count = Int.random(in: 0...4, using: &rng)
            for i in 0..<count {
                let startMin = Int.random(in: 0..<(24 * 60), using: &rng) / 15 * 15
                let length = Int.random(in: 1...16, using: &rng) * 15
                let start = day.addingTimeInterval(TimeInterval(startMin * 60))
                let end = start.addingTimeInterval(TimeInterval(length * 60))
                let parent = Event(title: "E\(d)-\(i)", timeRanges: [.init(start: start, end: end)],
                                   type: types[Int.random(in: 0..<types.count, using: &rng)])
                result.append(parent)
                if Int.random(in: 0..<5, using: &rng) == 0, length >= 30 {
                    let s = start.addingTimeInterval(600)
                    result.append(Event(title: "I\(d)-\(i)", timeRanges: [.init(start: s, end: s + 600)],
                                        type: "Break", displayKind: .interrupt,
                                        interruptRelation: EventInterruptRelation(parentEventID: parent.id, occurrenceDate: s)))
                }
            }
        }
        return result
    }

    // MARK: - C1 / C2: weekOnly equivalence

    private struct Scenario { var zone: String; var firstWeekday: Int; var year: Int; var month: Int }

    func testC1WeekOnlySummaryEqualsFullSummaryEveryDayOfTheMonth() {
        let scenarios = [
            Scenario(zone: "America/Los_Angeles", firstWeekday: 1, year: 2026, month: 3),  // DST spring 03-08
            Scenario(zone: "America/Los_Angeles", firstWeekday: 2, year: 2026, month: 3),
            Scenario(zone: "America/Los_Angeles", firstWeekday: 1, year: 2026, month: 11), // DST fall 11-01
            Scenario(zone: "America/Los_Angeles", firstWeekday: 2, year: 2026, month: 11),
            Scenario(zone: "America/Los_Angeles", firstWeekday: 1, year: 2026, month: 10),
            Scenario(zone: "Asia/Tokyo", firstWeekday: 2, year: 2026, month: 2),
            Scenario(zone: "UTC", firstWeekday: 7, year: 2026, month: 8),
        ]
        var comparisons = 0, mismatches = 0, nils = 0, nonTrivial = 0
        var rng = SplitMix(state: 0xDA7)
        for s in scenarios {
            let cal = calendar(s.zone, firstWeekday: s.firstWeekday)
            let monthStart = cal.date(from: DateComponents(year: s.year, month: s.month, day: 1))!
            let evs = events(around: monthStart.addingTimeInterval(15 * 86_400), calendar: cal, rng: &rng)
            let days = cal.range(of: .day, in: .month, for: monthStart)!.count
            for d in 0..<days {
                let dayStart = cal.date(byAdding: .day, value: d, to: monthStart)!
                for minute in [1, 9 * 60 + 7, 23 * 60 + 58] {
                    let now = dayStart.addingTimeInterval(TimeInterval(minute * 60))
                    let full = CategoryStatsBuilder.payload(events: evs, now: now, calendar: cal, colorHex: { "#\($0)" })
                    guard let trimmed = WristSnapshotBuilder.weekOnly(full, now: now) else {
                        nils += 1; XCTFail("nil at \(now) \(s)"); continue
                    }
                    for period in [CategoryStatsPeriod.today, .week] {
                        for basis in [CategoryStatsBasis.logged, .elapsed] {
                            // The phone's instant and later instants the watch may read at.
                            for later in [0.0, 3600.0, 21_600.0] as [TimeInterval] {
                                let asOf = now.addingTimeInterval(later)
                                guard asOf < (full.coverageEnd ?? .distantPast) else { continue }
                                comparisons += 1
                                let a = CategoryStats.summary(of: trimmed, period: period, asOf: asOf, basis: basis)
                                let b = CategoryStats.summary(of: full, period: period, asOf: asOf, basis: basis)
                                if b.totalHours > 0 { nonTrivial += 1 }
                                if a != b {
                                    mismatches += 1
                                    if mismatches <= 5 {
                                        XCTFail("C1 \(s.zone) fw\(s.firstWeekday) now=\(now) asOf=\(asOf) \(period) \(basis): trimmed \(a.status) \(a.totalHours) vs full \(b.status) \(b.totalHours)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        print("QA-C1 comparisons=\(comparisons) nonTrivial=\(nonTrivial) mismatches=\(mismatches) nils=\(nils)")
        XCTAssertEqual(mismatches, 0)
        XCTAssertGreaterThan(nonTrivial, comparisons / 2, "positive control: most comparisons carry hours")
    }

    /// C2 probe: a watch clock a few minutes behind the phone, across the
    /// week boundary. The full payload still covers the previous day; the
    /// trimmed one does not.
    func testC2WatchClockSlightlyBehindPhoneAtWeekStart() {
        let cal = calendar("America/Los_Angeles", firstWeekday: 1)
        // Sunday 2026-10-18 00:01 local, mid-month so the full payload reaches back to 10-01.
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 0, minute: 1))!
        let saturday = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 20))!
        let evs = [Event(title: "x", timeRanges: [.init(start: saturday, end: saturday + 3600)], type: "Work")]
        let full = CategoryStatsBuilder.payload(events: evs, now: now, calendar: cal, colorHex: { _ in nil })
        let trimmed = WristSnapshotBuilder.weekOnly(full, now: now)!
        let asOf = now.addingTimeInterval(-120)   // watch 2 min behind
        let a = CategoryStats.summary(of: trimmed, period: .today, asOf: asOf, basis: .elapsed)
        let b = CategoryStats.summary(of: full, period: .today, asOf: asOf, basis: .elapsed)
        print("QA-C2 skew: trimmed=\(a.status) \(a.totalHours) full=\(b.status) \(b.totalHours)")
        XCTAssertEqual(b.status, .ok)
        XCTAssertNotEqual(a.status, .stale, "trimmed payload reads stale under 2 min of clock skew where the full one is ok")
    }

    func testC2NilOnlyWhenPayloadCannotCoverThisWeek() {
        let cal = calendar("America/Los_Angeles", firstWeekday: 2)
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let full = CategoryStatsBuilder.payload(events: [], now: now, calendar: cal, colorHex: { _ in nil })
        XCTAssertNotNil(WristSnapshotBuilder.weekOnly(full, now: now), "an empty-but-valid payload is kept")
        var late = full; late.coverageStart = cal.date(byAdding: .day, value: 1, to: CategoryStats.range(of: .week, containing: now, calendar: cal).start)
        XCTAssertNil(WristSnapshotBuilder.weekOnly(late, now: now))
        var ended = full; ended.coverageEnd = now
        XCTAssertNil(WristSnapshotBuilder.weekOnly(ended, now: now))
        // Trimmed at the phone's instant is never stale where full is ok.
        let trimmed = WristSnapshotBuilder.weekOnly(full, now: now)!
        for p in [CategoryStatsPeriod.today, .week] {
            XCTAssertEqual(CategoryStats.status(of: trimmed, period: p, asOf: now, basis: .elapsed),
                           CategoryStats.status(of: full, period: p, asOf: now, basis: .elapsed))
        }
    }

    // MARK: - C3 / C4: layout properties

    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)   // 2026-03-10 00:00 UTC
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    private func occ(_ id: Int, start: Date, end: Date, interrupt: Bool = false, open: Bool = false) -> WristOccurrence {
        WristOccurrence(id: "o\(id)", eventID: UUID(), title: "o\(id)", type: "t", colorHex: "#000000",
                        start: start, end: end, isInterrupt: interrupt, quickActionsEnabled: true, isOpenEnded: open)
    }

    private func randomDay(_ rng: inout SplitMix) -> [WristOccurrence] {
        let n = Int.random(in: 1...14, using: &rng)
        return (0..<n).map { i in
            // Quarter-hour grid so exact ties and touching blocks are common.
            let s = Int.random(in: -8...100, using: &rng) * 900
            let l = Int.random(in: 1...12, using: &rng) * 900
            return occ(i, start: dayStart.addingTimeInterval(TimeInterval(s)),
                       end: dayStart.addingTimeInterval(TimeInterval(s + l)),
                       interrupt: Int.random(in: 0..<6, using: &rng) == 0)
        }
    }

    private func layout(_ o: [WristOccurrence], now: Date? = nil, dismissed: [WristDismissal] = []) -> [WristDayBlock] {
        WristDayLayout.blocks(o, dismissed: dismissed, dayStart: dayStart, dayEnd: dayEnd,
                              now: now ?? dayStart.addingTimeInterval(15 * 3600), currentID: nil)
    }

    func testC3LayoutPropertiesOver600RandomDays() {
        var rng = SplitMix(state: 0xC3)
        var overlapViolations = 0, laneCountViolations = 0, laneRange = 0, schedules = 0, blocksSeen = 0, multiLane = 0
        for _ in 0..<600 {
            schedules += 1
            let blocks = layout(randomDay(&rng)).filter { !$0.occurrence.isInterrupt }
            blocksSeen += blocks.count
            for b in blocks where !(0..<b.lanes).contains(b.lane) { laneRange += 1 }
            for (i, a) in blocks.enumerated() {
                for b in blocks[(i + 1)...] where a.lane == b.lane && a.start < b.end && b.start < a.end {
                    overlapViolations += 1
                }
            }
            // Independent clustering: start-sorted sweep, touching does not join.
            let sorted = blocks.sorted { $0.start < $1.start }
            var clusters: [[WristDayBlock]] = []
            var end = Date.distantPast
            for b in sorted {
                if clusters.isEmpty || b.start >= end { clusters.append([b]); end = b.end }
                else { clusters[clusters.count - 1].append(b); end = max(end, b.end) }
            }
            for c in clusters {
                var events: [(Date, Int)] = []
                for b in c { events.append((b.start, 1)); events.append((b.end, -1)) }
                events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }   // ends before starts at a tie
                var cur = 0, peak = 0
                for e in events { cur += e.1; peak = max(peak, cur) }
                if peak > 1 { multiLane += 1 }
                for b in c where b.lanes != peak { laneCountViolations += 1 }
            }
        }
        print("QA-C3 schedules=\(schedules) blocks=\(blocksSeen) multiLaneClusters=\(multiLane) overlap=\(overlapViolations) lanes!=peak=\(laneCountViolations) laneOutOfRange=\(laneRange)")
        XCTAssertEqual(overlapViolations, 0)
        XCTAssertEqual(laneCountViolations, 0)
        XCTAssertEqual(laneRange, 0)
        XCTAssertGreaterThan(multiLane, 300, "positive control: overlaps actually occur")
    }

    func testC3TouchingBlocksAreSeparateClusters() {
        let a = occ(1, start: dayStart.addingTimeInterval(3600), end: dayStart.addingTimeInterval(7200))
        let b = occ(2, start: dayStart.addingTimeInterval(7200), end: dayStart.addingTimeInterval(10800))
        let c = occ(3, start: dayStart.addingTimeInterval(9000), end: dayStart.addingTimeInterval(9900))
        let blocks = Dictionary(uniqueKeysWithValues: layout([c, b, a]).map { ($0.id, $0) })
        XCTAssertEqual(blocks["o1"]?.lanes, 1, "A touches B end-to-start: not in B's cluster")
        XCTAssertEqual(blocks["o2"]?.lanes, 2)
        XCTAssertEqual(blocks["o3"]?.lanes, 2)
    }

    func testC3OutputIsIndependentOfInputOrder() {
        var rng = SplitMix(state: 0xD3)
        var laneDiffs = 0, orderDiffs = 0, trials = 0
        var example = ""
        for _ in 0..<500 {
            let day = randomDay(&rng)
            let base = layout(day)
            for _ in 0..<4 {
                trials += 1
                let other = layout(day.shuffled(using: &rng))
                let m1 = Dictionary(uniqueKeysWithValues: base.map { ($0.id, [$0.lane, $0.lanes]) })
                let m2 = Dictionary(uniqueKeysWithValues: other.map { ($0.id, [$0.lane, $0.lanes]) })
                if m1 != m2 {
                    laneDiffs += 1
                    if example.isEmpty {
                        example = base.filter { m1[$0.id] != m2[$0.id] }
                            .map { "\($0.id) [\($0.start.timeIntervalSince(dayStart)),\($0.end.timeIntervalSince(dayStart))) \(m1[$0.id]!)->\(m2[$0.id]!)" }
                            .joined(separator: "; ")
                    }
                }
                if base.map(\.id) != other.map(\.id) { orderDiffs += 1 }
            }
        }
        print("QA-C3 order trials=\(trials) laneAssignmentDiffs=\(laneDiffs) drawOrderDiffs=\(orderDiffs) example: \(example)")
        XCTAssertEqual(laneDiffs, 0, "lane assignment depends on input order: \(example)")
        XCTAssertEqual(orderDiffs, 0, "draw order depends on input order")
    }

    func testC4OpenEndedAndDismissalClamps() {
        var rng = SplitMix(state: 0xC4)
        var violations = 0, drawnOpen = 0, dismissedChecked = 0
        for _ in 0..<1000 {
            let s = dayStart.addingTimeInterval(TimeInterval(Int.random(in: -20...30, using: &rng) * 3600))
            let now = dayStart.addingTimeInterval(TimeInterval(Int.random(in: -10...40, using: &rng) * 3600 + 17))
            let o = occ(1, start: s, end: .distantFuture, open: true)
            for b in layout([o], now: now) {
                drawnOpen += 1
                if b.end > min(now, dayEnd) || b.end > dayEnd || b.start < dayStart || b.end <= b.start { violations += 1 }
            }
            // A finished-here session: phone's end = clamped tap.
            let start = dayStart.addingTimeInterval(TimeInterval(Int.random(in: 0...20, using: &rng) * 3600))
            let tap = start.addingTimeInterval(TimeInterval(Int.random(in: -3...5, using: &rng) * 600))
            let end = WristTiming.clampedEnd(start: start, requested: tap)
            let f = occ(2, start: start, end: end)
            let dismissal = WristDismissal(eventID: f.eventID, rangeStart: start, tappedAt: tap)
            for b in layout([f], dismissed: dismissal.applies(to: f) ? [dismissal] : []) {
                dismissedChecked += 1
                if b.end < b.start || (dismissal.applies(to: f) && b.end > max(tap, start)) { violations += 1 }
            }
        }
        print("QA-C4 open drawn=\(drawnOpen) dismissed drawn=\(dismissedChecked) violations=\(violations)")
        XCTAssertEqual(violations, 0)
        XCTAssertGreaterThan(drawnOpen, 100)
        // Tap before start: block never extends before its start (it is dropped or zero-height).
        let a = occ(3, start: dayStart.addingTimeInterval(3600), end: dayStart.addingTimeInterval(7200))
        let early = WristDismissal(eventID: a.eventID, rangeStart: a.start, tappedAt: a.start.addingTimeInterval(-600))
        XCTAssertTrue(WristDayLayout.blocks([a], dismissed: [early], dayStart: dayStart, dayEnd: dayEnd,
                                            now: dayEnd, currentID: nil).allSatisfy { $0.end >= $0.start })
    }

    // MARK: - C5: snapshot size

    func testC5HeavySnapshotSize() throws {
        let cal = calendar("America/Los_Angeles", firstWeekday: 1)
        // Late in the month: the full payload covers 1st → window end.
        for (label, now) in [
            ("2026-10-31 22:00", cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 22))!),
            ("2026-11-01 09:00 (DST, week from 10-25)", cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!),
        ] {
            for perDay in [10, 25, 60] {
                var evs: [Event] = []
                let first = cal.date(byAdding: .day, value: -35, to: cal.startOfDay(for: now))!
                for d in 0..<45 {
                    let day = cal.date(byAdding: .day, value: d, to: first)!
                    for i in 0..<perDay {
                        let start = day.addingTimeInterval(TimeInterval((i * 23 * 60 / perDay) * 60))
                        let len = TimeInterval((20 + (i * 37 + d) % 100) * 60)
                        let parent = Event(title: "A fairly long event title \(d)-\(i)", timeRanges: [.init(start: start, end: start + len)],
                                           type: "Type\((i + d) % 12)")
                        evs.append(parent)
                        if i % 4 == 0 {
                            let s = start + 300
                            evs.append(Event(title: "Interrupt \(d)-\(i)", timeRanges: [.init(start: s, end: s + 600)],
                                             type: "Break", displayKind: .interrupt,
                                             interruptRelation: EventInterruptRelation(parentEventID: parent.id, occurrenceDate: s)))
                        }
                    }
                }
                let payload = CategoryStatsBuilder.payload(events: evs, now: now, calendar: cal, colorHex: { _ in "#123456" })
                let receipts: [WristReceipt] = []
                let snap = WristSnapshotBuilder.snapshot(
                    events: evs, templates: (0..<12).map { EventTypeTemplate(title: "Type\($0)", colorHex: "#112233") },
                    now: now, calendar: cal, language: "en", receipts: receipts, stats: payload, colorHex: { _ in "#123456" })
                let withStats = try WristWire.encode(snap).count
                var noStats = snap; noStats.stats = nil
                let without = try WristWire.encode(noStats).count
                var fullStats = snap; fullStats.stats = payload
                let untrimmed = try WristWire.encode(fullStats).count
                print("QA-C5 \(label) perDay=\(perDay): snapshot=\(withStats)B (no stats \(without)B, stats part \(withStats - without)B; untrimmed month would be \(untrimmed)B) occurrences=\(snap.occurrences.count) days=\(snap.stats?.days?.count ?? -1)/\(payload.days?.count ?? -1)")
                XCTAssertNotNil(snap.stats)
                let weekStart = CategoryStats.range(of: .week, containing: now, calendar: cal).start
                XCTAssertEqual(snap.stats?.coverageStart, max(payload.coverageStart!, cal.date(byAdding: .day, value: -1, to: weekStart)!),
                               "the snapshot carries the week-trimmed payload (one day of margin, where the payload has it)")
                // Flipped by the coordinator after this round: the adopted
                // contract is that what the bridge SENDS fits the budget at
                // any density, stepping stats down before anything else.
                let fitted = try XCTUnwrap(WristBridge.fitting(snap, latestStats: payload, now: now))
                print("QA-C5 sent: \(fitted.1.count)B stats=\(fitted.0.stats == nil ? "none" : "\(fitted.0.stats?.days?.count ?? 0) days")")
                XCTAssertLessThanOrEqual(fitted.1.count, WristBridge.byteBudget, "\(label) perDay=\(perDay)")
                if perDay <= 25 { XCTAssertNotNil(fitted.0.stats, "at 25 a day the watch still gets stats") }
            }
        }
    }
}
