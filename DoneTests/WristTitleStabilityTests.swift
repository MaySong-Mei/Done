import XCTest
@testable import Done

/// Synthetic histories the watch's name ranking is measured on: the same
/// events on every run.
enum WristTitleHistory {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    static var today: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))! }
    static let types = ["Work", "Life", "Sport"].map { WristType(id: UUID(), title: $0, colorHex: "#0A84FF") }

    /// SplitMix64.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
        mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
    }

    /// Weekdays: breakfast on waking (06:00–10:00), standup then deep work,
    /// lunch about five hours after waking, review (Mon/Wed/Fri) or
    /// planning (Tue/Thu) after lunch, email at four, a run and a shower
    /// on Tue/Thu evenings where Mon/Wed/Fri have tea, dinner. Weekends:
    /// gym, shower and brunch, or tidying up, some Saturday deep work,
    /// dinner. Every event may be skipped, starts and lengths wander, and
    /// errands land anywhere.
    static func routine(days: Int = 56) -> [Event] {
        var rng = Random(state: 20_261_026)
        var events: [Event] = []
        for offset in 1...days {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let weekday = calendar.component(.weekday, from: day)
            func at(_ minutes: Int) -> Date { day.addingTimeInterval(TimeInterval(minutes * 60)) }
            /// Adds a block and returns its end (in minutes of the day) for
            /// whatever follows it, even when the block itself was skipped.
            @discardableResult
            func add(_ title: String, _ type: String, _ start: Int, _ minutes: Int, skip: Double = 0.08) -> Int {
                let start = start + rng.int(-4...4) * 5
                let length = max(10, Int((Double(minutes) * (0.8 + rng.unit() * 0.45) / 5).rounded()) * 5)
                if !rng.chance(skip) {
                    events.append(Event(title: title, timeRanges: [.init(start: at(start), end: at(start + length))], type: type))
                }
                return start + length + rng.int(0...2) * 5
            }
            let wake = 360 + rng.int(0...16) * 15
            if (2...6).contains(weekday) {
                add("Breakfast", "Life", wake, 25)
                let standupEnd = add("Standup", "Work", max(570, wake + 45), 15)
                add("Deep work", "Work", standupEnd, 150)
                let lunchEnd = add("Lunch", "Life", wake + 300, 50)
                add([2, 4, 6].contains(weekday) ? "Review" : "Planning", "Work", lunchEnd, 60)
                if rng.chance(0.7) { add("Email", "Work", 960, 30) }
                if weekday == 3 || weekday == 5 {
                    let runEnd = add("Run", "Sport", 1080, 45)
                    add("Shower", "Life", runEnd, 20)
                } else if rng.chance(0.6) {
                    add("Tea", "Life", 1110, 20)
                }
                add("Dinner", "Life", 1170, 60)
            } else {
                add("Breakfast", "Life", wake, 25, skip: 0.5)
                if rng.chance(0.75) {
                    let gymEnd = add("Gym", "Sport", wake + 60, 90)
                    let showerEnd = add("Shower", "Life", gymEnd, 20)
                    add("Brunch", "Life", showerEnd, 60)
                } else {
                    add("Tidy up", "Life", wake + 120, 20)
                    add("Brunch", "Life", wake + 180, 60)
                }
                if weekday == 7, rng.chance(0.3) { add("Deep work", "Work", 840, 120) }
                add("Dinner", "Life", 1140, 60)
            }
            if rng.chance(0.25) { add("Errand", "Life", rng.int(40...72) * 15, 30, skip: 0) }
        }
        return events
    }

    /// The routine's shape, lived less tidily: wake times over five hours,
    /// a weekday off now and then, starts that wander half an hour, a fifth
    /// of everything unlogged, names renamed partway (deep work became
    /// "Focus", "Stand-up" became "Standup") or written two ways ("Lunch
    /// break"), and a dozen names per type — more than the watch is sent.
    static func messy(days: Int = 84, seed: UInt64 = 20_261_027) -> [Event] {
        var rng = Random(state: seed)
        var events: [Event] = []
        for offset in 1...days {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let weekday = calendar.component(.weekday, from: day)
            let renamedSince = offset <= 42
            func at(_ minutes: Int) -> Date { day.addingTimeInterval(TimeInterval(minutes * 60)) }
            @discardableResult
            func add(_ title: String, _ type: String, _ start: Int, _ minutes: Int, skip: Double = 0.2) -> Int {
                let start = start + rng.int(-6...6) * 5
                let stretch = rng.chance(0.1) ? 0.5 + rng.unit() * 1.5 : 0.75 + rng.unit() * 0.55
                let length = max(10, Int((Double(minutes) * stretch / 5).rounded()) * 5)
                if !rng.chance(skip) {
                    events.append(Event(title: title, timeRanges: [.init(start: at(start), end: at(start + length))], type: type))
                }
                return start + length + rng.int(0...3) * 5
            }
            let wake = 330 + rng.int(0...22) * 15
            let workday = (2...6).contains(weekday) && !rng.chance(0.12)
            if workday {
                add(rng.chance(0.3) ? "Coffee" : "Breakfast", "Life", wake, 25)
                let standupEnd = add(renamedSince ? "Standup" : "Stand-up", "Work", max(570, wake + 45), 15)
                var focusEnd = add(renamedSince ? "Focus" : "Deep work", "Work", standupEnd, 150)
                if rng.chance(0.4) { focusEnd = add("Code review", "Work", focusEnd, 45) }
                let lunchEnd = add(rng.chance(0.3) ? "Lunch break" : "Lunch", "Life", max(focusEnd, wake + 300), 50)
                switch weekday {
                case 2: add("Planning", "Work", lunchEnd, 60)
                case 3:
                    add("1:1", "Work", 840, 30)
                    add("Writing", "Work", 900, 90)
                case 4:
                    add("Review", "Work", lunchEnd, 60)
                    add("Team meeting", "Work", 900, 60)
                case 5: add("Planning", "Work", lunchEnd, 60)
                default:
                    let reviewEnd = add("Review", "Work", lunchEnd, 60)
                    add("Admin", "Work", reviewEnd, 45)
                }
                if rng.chance(0.7) { add("Email", "Work", 960, 30) }
                if weekday == 3 || weekday == 5 {
                    let runEnd = add("Run", "Sport", 1080, 45)
                    add("Shower", "Life", runEnd, 20)
                } else if weekday == 2, rng.chance(0.5) {
                    let yogaEnd = add("Yoga", "Sport", 1110, 60)
                    add("Shower", "Life", yogaEnd, 20)
                } else if rng.chance(0.6) {
                    add("Tea", "Life", 1110, 20)
                }
                if rng.chance(0.5) { add("Cooking", "Life", 1125, 40) }
                add("Dinner", "Life", 1170, 60)
                if rng.chance(0.4) { add("Read", "Life", 1290, 30) }
            } else {
                add("Breakfast", "Life", wake, 25, skip: 0.5)
                if rng.chance(0.65) {
                    let gymEnd = add("Gym", "Sport", wake + 60, 90)
                    let showerEnd = add("Shower", "Life", gymEnd, 20)
                    add("Brunch", "Life", showerEnd, 60)
                } else {
                    add("Tidy up", "Life", wake + 120, 20)
                    add("Brunch", "Life", wake + 180, 60)
                }
                if rng.chance(0.5) { add("Groceries", "Life", 900, 45) }
                if rng.chance(0.4) { add("Walk", "Sport", 960, 40) }
                if rng.chance(0.25) { add("Nap", "Life", 870, 30) }
                if weekday == 7, rng.chance(0.3) { add(renamedSince ? "Focus" : "Deep work", "Work", 840, 120) }
                add("Dinner", "Life", 1140, 60)
            }
            if rng.chance(0.3) { add("Errand", "Life", rng.int(40...72) * 15, 30, skip: 0) }
            if rng.chance(0.15) { add("Swim", "Sport", rng.int(28...76) * 15, 45, skip: 0) }
        }
        return events
    }
}

/// Whether the names the watch offers hold still when nothing that should
/// matter has changed: the phone's clock moving on, the same data pushed
/// again, a drawn range a little off, a neighbor not logged yet. Measured
/// over held-out events of the synthetic histories, against how often the
/// first name and the shown three change; the floors keep it from sliding
/// back, and a deliberately jumpy ranking is the control that the
/// measurement can fail.
@MainActor
final class WristTitleStabilityTests: XCTestCase {
    private typealias Random = WristTitleHistory.Random
    private let calendar = WristTitleHistory.calendar
    private let types = WristTitleHistory.types
    private let evaluatedDays = 21

    /// A held-out event with what the watch would know when it is drawn.
    private struct Query {
        var event: Event
        var range: (start: Date, end: Date)
        /// Every other record: a day being filled in afterwards.
        var timeline: [Event]
        /// What was learned: records that started before it.
        var history: [Event]
    }

    private func queries(_ events: [Event]) -> [Query] {
        let cutoff = calendar.date(byAdding: .day, value: -evaluatedDays, to: WristTitleHistory.today)!
        return events.filter { $0.primaryTimeRange!.start >= cutoff }.map { event in
            let range = event.primaryTimeRange!
            let others = events.filter { $0.id != event.id }
            return Query(event: event, range: (range.start, range.end), timeline: others,
                         history: others.filter { $0.primaryTimeRange!.start < range.start })
        }
    }

    private func items(_ events: [Event]) -> [WristTitleTimeline.Item] {
        events.map {
            WristTitleTimeline.Item(id: $0.id.uuidString, start: $0.primaryTimeRange!.start,
                                    end: $0.primaryTimeRange!.end, title: $0.title, type: $0.type)
        }
    }

    typealias Ranker = (_ hints: [WristTitleHint], _ start: Date, _ end: Date, _ context: WristTitleContext) -> [String]

    private var shipped: Ranker {
        { [calendar] hints, start, end, context in
            WristTitleRanking.rank(hints, start: start, end: end, calendar: calendar, context: context)
        }
    }

    private func names(
        _ hints: [String: [WristTitleHint]], type: String, start: Date, end: Date,
        timeline: [Event], ranker: Ranker
    ) -> [String] {
        guard let offered = hints[type], !offered.isEmpty else { return [] }
        let table = WristTitleTable(typeOrder: types.map(\.title), hints: hints)
        let context = WristTitleTimeline(items(timeline))
            .context(start: start, end: end, table: table, calendar: calendar)
        return ranker(offered, start, end, context)
    }

    private func hints(_ history: [Event], now: Date) -> [String: [WristTitleHint]] {
        WristSnapshotBuilder.titleHints(events: history, types: types, now: now, calendar: calendar)
    }

    /// How often a change that should not matter moves the names.
    struct Churn {
        var cases = 0
        var firstChanged = 0
        var topChanged = 0
        /// The first name was the held-out one, and no longer is.
        var lost = 0
        var firstRate: Double { Double(firstChanged) / Double(max(1, cases)) }
        var topRate: Double { Double(topChanged) / Double(max(1, cases)) }
        var lostRate: Double { Double(lost) / Double(max(1, cases)) }

        mutating func add(_ base: [String], _ other: [String], truth: String) {
            cases += 1
            if base.first != other.first { firstChanged += 1 }
            if base != other { topChanged += 1 }
            if base.first == truth, other.first != truth { lost += 1 }
        }
    }

    struct Accuracy {
        var total = 0
        var top1 = 0
        var top3 = 0
        var offered = 0
        var top1Rate: Double { Double(top1) / Double(max(1, total)) }
        var top3Rate: Double { Double(top3) / Double(max(1, total)) }
        var offeredRate: Double { Double(offered) / Double(max(1, total)) }

        mutating func add(_ ranked: [String], truth: String, offered names: [String]) {
            total += 1
            if ranked.first == truth { top1 += 1 }
            if ranked.contains(truth) { top3 += 1 }
            if names.contains(truth) { offered += 1 }
        }
    }

    struct Measurement {
        var churn: [String: Churn] = [:]
        var accuracy: [String: Accuracy] = [:]
    }

    static let churnRows = [
        "now +5 min", "now +1 h", "now +6 h", "now +1 day", "now +3 days",
        "same data, reordered", "+1 use, other type", "+1 use, same type",
        "start ±5 min", "start ±15 min", "length ±15 min",
        "previous not logged", "next not logged", "drawn live",
    ]

    /// Every perturbation for every held-out event of `events`.
    func measure(_ events: [Event], ranker: Ranker? = nil) -> Measurement {
        let ranker = ranker ?? shipped
        var m = Measurement()
        var rng = Random(state: 99)
        let minute: TimeInterval = 60
        for q in queries(events) {
            let type = q.event.type
            let truth = q.event.title
            let baseHints = hints(q.history, now: q.range.start)
            guard let offered = baseHints[type], !offered.isEmpty else { continue }
            func ranked(_ hints: [String: [WristTitleHint]], start: Date? = nil, end: Date? = nil, timeline: [Event]? = nil) -> [String] {
                names(hints, type: type, start: start ?? q.range.start, end: end ?? q.range.end,
                      timeline: timeline ?? q.timeline, ranker: ranker)
            }
            let base = ranked(baseHints)
            func churn(_ label: String, _ other: [String]) { m.churn[label, default: Churn()].add(base, other, truth: truth) }

            m.accuracy["full", default: Accuracy()].add(base, truth: truth, offered: offered.map(\.title))
            let before = q.timeline.filter { $0.primaryTimeRange!.start < q.range.start }
            let live = ranked(baseHints, timeline: before)
            m.accuracy["drawn live", default: Accuracy()].add(live, truth: truth, offered: offered.map(\.title))
            churn("drawn live", live)

            for (label, dt) in [("now +5 min", 5 * minute), ("now +1 h", 3600), ("now +6 h", 6 * 3600),
                                ("now +1 day", 86_400), ("now +3 days", 3 * 86_400)] {
                churn(label, ranked(hints(q.history, now: q.range.start.addingTimeInterval(dt))))
            }
            var shuffled = q.history
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) { shuffled.swapAt(i, rng.int(0...i)) }
            churn("same data, reordered", ranked(hints(shuffled, now: q.range.start)))

            // One more record learned, a few days back at a free-ish moment.
            func extra(sameType: Bool) -> Event? {
                let pool = q.history.filter { ($0.type == type) == sameType && $0.title != truth }
                guard !pool.isEmpty else { return nil }
                let model = rng.pick(pool)
                let r = model.primaryTimeRange!
                let shift = TimeInterval(rng.int(2...6) * 86_400)
                guard r.start.addingTimeInterval(shift) < q.range.start else { return nil }
                return Event(title: model.title, timeRanges: [.init(start: r.start.addingTimeInterval(shift),
                                                                    end: r.end.addingTimeInterval(shift))], type: model.type)
            }
            for (label, same) in [("+1 use, other type", false), ("+1 use, same type", true)] {
                if let added = extra(sameType: same) {
                    churn(label, ranked(hints(q.history + [added], now: q.range.start)))
                }
            }

            for shift in [-5.0, 5] {
                churn("start ±5 min", ranked(baseHints, start: q.range.start + shift * minute, end: q.range.end + shift * minute))
            }
            for shift in [-15.0, 15] {
                churn("start ±15 min", ranked(baseHints, start: q.range.start + shift * minute, end: q.range.end + shift * minute))
            }
            for stretch in [-15.0, 15] where q.range.end.timeIntervalSince(q.range.start) + stretch * minute >= 10 * minute {
                churn("length ±15 min", ranked(baseHints, end: q.range.end + stretch * minute))
            }

            let timeline = WristTitleTimeline(items(q.timeline))
            if let previous = timeline.previous(start: q.range.start, excluding: nil) {
                churn("previous not logged", ranked(baseHints, timeline: q.timeline.filter { $0.id.uuidString != previous.id }))
            }
            if let next = timeline.next(start: q.range.start, end: q.range.end, excluding: nil) {
                churn("next not logged", ranked(baseHints, timeline: q.timeline.filter { $0.id.uuidString != next.id }))
            }
        }
        return m
    }

    private func report(_ label: String, _ m: Measurement) {
        for row in ["full", "drawn live"] {
            guard let a = m.accuracy[row] else { continue }
            print(String(format: "WristTitleStability %@ accuracy %-11@ n=%d top-1 %.3f top-3 %.3f offered %.3f",
                         label, row, a.total, a.top1Rate, a.top3Rate, a.offeredRate))
        }
        for row in Self.churnRows {
            guard let c = m.churn[row] else { continue }
            print(String(format: "WristTitleStability %@ churn %-22@ n=%4d first %.3f top-3 %.3f lost %.3f",
                         label, row, c.cases, c.firstRate, c.topRate, c.lostRate))
        }
    }

    private func ranker(_ model: WristTitleRanking.NeighborModel) -> Ranker {
        { [calendar] hints, start, end, context in
            WristTitleRanking.rank(hints, start: start, end: end, calendar: calendar, context: context, neighbors: model)
        }
    }

    /// Ceilings on how often the first name may change, and floors on how
    /// often it is right, a little past the figures printed by the tests
    /// below; the names of the floors a measurement breaks.
    struct Floors {
        var firstChange: [String: Double]
        var top1Full: Double
        var top1Live: Double

        func broken(by m: Measurement) -> [String] {
            var broken: [String] = []
            for (row, ceiling) in firstChange.sorted(by: { $0.key < $1.key }) where (m.churn[row]?.firstRate ?? 1) > ceiling {
                broken.append(row)
            }
            if (m.accuracy["full"]?.top1Rate ?? 0) < top1Full { broken.append("top-1 full") }
            if (m.accuracy["drawn live"]?.top1Rate ?? 0) < top1Live { broken.append("top-1 drawn live") }
            return broken
        }
    }

    /// Nothing about the block or its day changed, so nothing may move.
    private static let stillRows = ["now +5 min", "now +1 h", "now +6 h", "now +1 day", "same data, reordered"]

    private static let routineFloors = Floors(
        firstChange: Dictionary(uniqueKeysWithValues: stillRows.map { ($0, 0.0) }).merging([
            "start ±5 min": 0.01, "start ±15 min": 0.04, "length ±15 min": 0.04,
            "previous not logged": 0.15, "next not logged": 0.03, "drawn live": 0.02,
        ]) { $1 },
        top1Full: 0.90, top1Live: 0.90
    )

    private static let messyFloors = Floors(
        firstChange: Dictionary(uniqueKeysWithValues: stillRows.map { ($0, 0.0) }).merging([
            "start ±5 min": 0.05, "start ±15 min": 0.10, "length ±15 min": 0.15,
            "previous not logged": 0.22, "next not logged": 0.15, "drawn live": 0.07,
        ]) { $1 },
        top1Full: 0.62, top1Live: 0.61
    )

    func testRoutineHoldsStill() {
        let m = measure(WristTitleHistory.routine())
        report("routine", m)
        XCTAssertEqual(Self.routineFloors.broken(by: m), [])
    }

    func testMessyHoldsStill() {
        let m = measure(WristTitleHistory.messy())
        report("messy", m)
        XCTAssertEqual(Self.messyFloors.broken(by: m), [])
    }

    /// Positive control: neighbors as the ranking took them before it was
    /// measured — "nothing adjacent" at its word, at full context strength —
    /// on the same history must break the floors, or they guard nothing.
    func testLiteralNeighborsBreakTheFloors() {
        let m = measure(WristTitleHistory.routine(), ranker: ranker(.literal))
        report("routine literal", m)
        let broken = Self.routineFloors.broken(by: m)
        XCTAssertTrue(broken.contains("drawn live"), "\(broken)")
        XCTAssertTrue(broken.contains("next not logged"), "\(broken)")
        XCTAssertTrue(broken.contains("top-1 drawn live"), "\(broken)")
        XCTAssertFalse(broken.contains { Self.stillRows.contains($0) }, "the clock never moved them: \(broken)")
    }
}

/// Whether the names reach the watch at all. The phone sends one snapshot
/// under `WristBridge.byteBudget`; on a busy calendar something has to give,
/// and the names step on the watch is skipped for a type with none. Measured
/// over a month of evening pushes at several densities.
@MainActor
final class WristTitleDeliveryTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return cal
    }()

    private static let vocabulary = [
        "Standup", "Deep work", "Review", "Planning", "Email", "1:1 with Sam", "Code review", "Team sync",
        "Breakfast", "Lunch", "Dinner", "Shower", "Run", "Gym", "Reading", "Groceries", "Commute", "Nap",
    ]

    /// `perDay` named blocks a day over twelve types, from five weeks back
    /// to ten days ahead.
    private func events(perDay: Int, around now: Date) -> [Event] {
        var events: [Event] = []
        let first = calendar.date(byAdding: .day, value: -35, to: calendar.startOfDay(for: now))!
        for d in 0..<45 {
            let day = calendar.date(byAdding: .day, value: d, to: first)!
            for i in 0..<perDay {
                let start = day.addingTimeInterval(TimeInterval((6 * 60 + i * 17 * 60 / perDay) * 60))
                let length = TimeInterval((15 + (i * 37 + d) % 90) * 60)
                let title = Self.vocabulary[(i * 7 + d % 3) % Self.vocabulary.count]
                events.append(Event(title: title, timeRanges: [.init(start: start, end: start + length)], type: "Type\(i % 12)"))
            }
        }
        return events
    }

    struct Delivery {
        var pushes = 0
        var withNames = 0
        var namedTypes = 0
        var gridTypes = 0
        /// Grid types the phone learned names for at all.
        var learnedTypes = 0
        var statsDays = 0
        var withStats = 0
        var occurrencesKept = 0
        var occurrencesBuilt = 0
    }

    typealias Fitting = @MainActor (WristSnapshot, CategoryStatsPayload?, Date) -> (WristSnapshot, Data)?

    /// The ladder before it kept the names: whole, else the hints dropped
    /// first and the rest stepped down as now.
    private static let droppingHints: Fitting = { full, stats, now in
        if let data = try? WristWire.encode(full), data.count <= WristBridge.byteBudget { return (full, data) }
        var bare = full
        bare.titleHints = [:]
        return WristBridge.fitting(bare, latestStats: stats, now: now)
    }

    private static let densities = [5, 8, 10, 12, 15, 20, 25, 40, 60]

    func delivery(perDay: Int, fitting: Fitting = { WristBridge.fitting($0, latestStats: $1, now: $2) }) throws -> Delivery {
        var result = Delivery()
        for dayOfMonth in stride(from: 1, through: 31, by: 3) {
            let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: dayOfMonth, hour: 21))!
            let evs = events(perDay: perDay, around: now)
            let payload = CategoryStatsBuilder.payload(events: evs, now: now, calendar: calendar, colorHex: { _ in "#123456" })
            let full = WristSnapshotBuilder.snapshot(
                events: evs, templates: (0..<12).map { EventTypeTemplate(title: "Type\($0)", colorHex: "#112233") },
                now: now, calendar: calendar, language: "en", receipts: [], stats: payload, colorHex: { _ in "#123456" }
            )
            let (sent, data) = try XCTUnwrap(fitting(full, payload, now))
            XCTAssertLessThanOrEqual(data.count, WristBridge.byteBudget)
            result.pushes += 1
            if !sent.titleHints.isEmpty { result.withNames += 1 }
            result.gridTypes += sent.types.count
            result.namedTypes += sent.types.filter { !(sent.titleHints[$0.title] ?? []).isEmpty }.count
            result.learnedTypes += full.types.filter { !(full.titleHints[$0.title] ?? []).isEmpty }.count
            if let days = sent.stats?.days { result.withStats += 1; result.statsDays += days.count }
            result.occurrencesKept += sent.occurrences.count
            result.occurrencesBuilt += full.occurrences.count
        }
        return result
    }

    private func report(_ label: String, _ perDay: Int, _ d: Delivery) {
        print(String(format: "WristTitleDelivery %@ perDay=%2d pushes with names %2d/%d, types named %3d/%d (learned %d), pushes with stats %2d (avg %.1f days), occurrences %d/%d",
                     label, perDay, d.withNames, d.pushes, d.namedTypes, d.gridTypes, d.learnedTypes, d.withStats,
                     Double(d.statsDays) / Double(max(1, d.withStats)), d.occurrencesKept, d.occurrencesBuilt))
    }

    /// Every push carries names for every grid type the phone learned
    /// names for, however busy the calendar.
    func testNamesReachTheWatchAtEveryDensity() throws {
        for perDay in Self.densities {
            let d = try delivery(perDay: perDay)
            report("kept", perDay, d)
            XCTAssertEqual(d.withNames, d.pushes, "perDay=\(perDay)")
            XCTAssertEqual(d.namedTypes, d.learnedTypes, "perDay=\(perDay)")
            XCTAssertGreaterThan(d.learnedTypes, 0)
        }
    }

    /// Positive control: the ladder that dropped the names first loses them
    /// on a busy calendar, and the floor above would say so.
    func testDroppingHintsFirstLosesThemWhenBusy() throws {
        for perDay in Self.densities {
            let d = try delivery(perDay: perDay, fitting: Self.droppingHints)
            report("dropped", perDay, d)
            if perDay >= 20 { XCTAssertEqual(d.withNames, 0, "perDay=\(perDay)") }
        }
    }
}
