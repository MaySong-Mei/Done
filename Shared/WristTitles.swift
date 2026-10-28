//
//  WristTitles.swift
//  Shared (Done + DoneWatch)
//
//  Names the watch offers for a new block so nobody has to type on the
//  wrist. The phone learns them from history (`WristSnapshotBuilder.titleHints`)
//  and sends, per type on the start grid, a few names with the shape of the
//  events that carried them: when they start (clock and weekday), how long
//  they last, what comes right before and after them, and how long into the
//  day they happen. The watch ranks those against the block being named
//  (`WristTitleRanking.rank`), with the context read off its own timeline
//  (`WristTitleTimeline`): a short morning block of Work reads as the
//  standup, a long one as deep work, the block right after the gym as the
//  shower.
//
//  Phone and watch must describe a block's surroundings the same way, so
//  both read them through `WristTitleTimeline` and name neighbors through
//  `WristTitleTable`.
//

import Foundation

/// One name the user gave events of a type, with the shape of those events.
/// Short keys: up to a few dozen of these ride every snapshot. Every context
/// field is optional — a phone that predates it, or a name with no usable
/// history for it, leaves it out and the watch ranks without it.
nonisolated struct WristTitleHint: Codable, Hashable, Sendable {
    var title: String
    /// Recency-weighted number of uses: a use today counts one, older uses
    /// fade by half every `WristTitleRanking.halfLifeDays`.
    var weight: Double
    /// Mean start, minutes after local midnight (a circular mean, so 23:30
    /// and 00:30 average to midnight, not noon).
    var startMinute: Int
    /// How tightly the starts gather around `startMinute`, 0…100: 100 is
    /// always the same time, near 0 is any time of day. Scales how much the
    /// time of day matters when ranking.
    var concentration: Int
    /// Typical (weighted median) length in minutes.
    var minutes: Int
    /// Share of uses per weekday in percent, Sunday first (the calendar's
    /// weekday minus one).
    var weekdays: [Int]?
    /// What ended just before it, as flat pairs: a `WristTitleTable` index
    /// (or `WristTitleTable.nothing`) then its share in percent, commonest
    /// first. Shares of neighbors the table cannot name are left out.
    var previous: [Int]?
    /// What started just after it, in the same form.
    var next: [Int]?
    /// Typical minutes from the day's first record to its start
    /// (`WristTitleTimeline.minutesIntoDay`), and how far uses stray from
    /// that (a median absolute deviation).
    var intoDay: Int?
    var intoDaySpread: Int?

    private enum CodingKeys: String, CodingKey {
        case title = "t", weight = "w", startMinute = "s", concentration = "c", minutes = "m"
        case weekdays = "d", previous = "p", next = "n", intoDay = "f", intoDaySpread = "fs"
    }

    init(
        title: String, weight: Double, startMinute: Int, concentration: Int, minutes: Int,
        weekdays: [Int]? = nil, previous: [Int]? = nil, next: [Int]? = nil,
        intoDay: Int? = nil, intoDaySpread: Int? = nil
    ) {
        self.title = title
        self.weight = weight
        self.startMinute = startMinute
        self.concentration = concentration
        self.minutes = minutes
        self.weekdays = weekdays
        self.previous = previous
        self.next = next
        self.intoDay = intoDay
        self.intoDaySpread = intoDaySpread
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute) ?? 0
        concentration = try c.decodeIfPresent(Int.self, forKey: .concentration) ?? 0
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 60
        weekdays = (try? c.decodeIfPresent([Int].self, forKey: .weekdays)).flatMap { $0 }.flatMap { $0.count == 7 ? $0 : nil }
        previous = (try? c.decodeIfPresent([Int].self, forKey: .previous)).flatMap { $0 }
        next = (try? c.decodeIfPresent([Int].self, forKey: .next)).flatMap { $0 }
        intoDay = (try? c.decodeIfPresent(Int.self, forKey: .intoDay)).flatMap { $0 }
        intoDaySpread = (try? c.decodeIfPresent(Int.self, forKey: .intoDaySpread)).flatMap { $0 }
    }
}

/// Names a neighbor compactly: the snapshot's types in their order, then
/// each type's hint titles in that same order, compared without case or
/// accents. A neighbor is its title when the table has it, else its type.
nonisolated struct WristTitleTable: Sendable {
    /// "Nothing adjacent": the block followed (or preceded) a gap.
    static let nothing = -1

    private(set) var keys: [String] = []
    private var index: [String: Int] = [:]

    init(typeOrder: [String], hints: [String: [WristTitleHint]]) {
        for key in typeOrder.map(Self.fold) + typeOrder.flatMap({ (hints[$0] ?? []).map { Self.fold($0.title) } }) {
            if index[key] == nil { index[key] = keys.count }
            keys.append(key)
        }
    }

    func ref(title: String, type: String) -> Int? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, let i = index[Self.fold(title)] { return i }
        return index[Self.fold(type)]
    }

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// What surrounds a block. Nil fields are unknown and do not count either
/// way when ranking.
nonisolated struct WristTitleContext: Equatable, Sendable {
    enum Neighbor: Equatable, Sendable {
        /// Nothing within `WristTitleTimeline.adjacencyGap`.
        case nothing
        /// A neighbor the table names.
        case ref(Int)
        /// A neighbor the table cannot name: no evidence either way.
        case unknown
    }

    /// The calendar's weekday, 1 (Sunday) … 7.
    var weekday: Int?
    var previous: Neighbor?
    var next: Neighbor?
    var minutesIntoDay: Int?

    static let none = WristTitleContext()

    /// The table value a neighbor is learned under; nil for one that is not.
    static func learned(_ neighbor: Neighbor?) -> Int? {
        switch neighbor {
        case .nothing: return WristTitleTable.nothing
        case .ref(let i): return i
        case .unknown, nil: return nil
        }
    }
}

/// The timed records around a moment, as both sides see them: the phone's
/// events while learning, the watch's occurrences while ranking.
nonisolated struct WristTitleTimeline: Sendable {
    struct Item: Sendable {
        var id: String
        var start: Date
        var end: Date
        var title: String
        var type: String
    }

    /// A neighbor ends at most this long before the block starts (or
    /// starts at most this long after it ends). Blocks snap to a 15-minute
    /// grid; one grid step plus one more covers a short unlogged change-over
    /// (walk to the meeting, towel off) without linking events that a real
    /// stretch of unlogged time separates.
    static let adjacencyGap: TimeInterval = 30 * 60
    /// Records overlap a little in practice (a meeting that ran over): an
    /// event ending this far into the block still came before it.
    static let overlapSlack: TimeInterval = 15 * 60
    /// The day, for "into the day", turns at this hour rather than midnight,
    /// so a late night still belongs to the evening before.
    static let dayTurnHour = 3
    /// How far back a neighbor's start may lie.
    private static let lookBack: TimeInterval = 18 * 3600

    let items: [Item]

    init(_ items: [Item]) {
        self.items = items.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    init(occurrences: [WristOccurrence]) {
        self.init(occurrences.filter { !$0.isOpenEnded }.map {
            Item(id: $0.id, start: $0.start, end: $0.end, title: $0.title, type: $0.type)
        })
    }

    /// The context of a block from `start` to `end`, leaving out the record
    /// `excluding` (the block itself, when it is already on the timeline).
    func context(
        start: Date, end: Date, excluding: String? = nil, table: WristTitleTable, calendar: Calendar
    ) -> WristTitleContext {
        func neighbor(_ item: Item?) -> WristTitleContext.Neighbor {
            guard let item else { return .nothing }
            return table.ref(title: item.title, type: item.type).map { .ref($0) } ?? .unknown
        }
        return WristTitleContext(
            weekday: calendar.component(.weekday, from: start),
            previous: neighbor(previous(start: start, excluding: excluding)),
            next: neighbor(next(start: start, end: end, excluding: excluding)),
            minutesIntoDay: minutesIntoDay(start: start, excluding: excluding, calendar: calendar)
        )
    }

    /// The record that ended last within the gap before `start`.
    func previous(start: Date, excluding: String?) -> Item? {
        var best: Item?
        var i = firstIndex(atOrAfter: start) - 1
        while i >= 0, items[i].start >= start.addingTimeInterval(-Self.lookBack) {
            let item = items[i]
            i -= 1
            guard item.id != excluding,
                  item.end >= start.addingTimeInterval(-Self.adjacencyGap),
                  item.end <= start.addingTimeInterval(Self.overlapSlack) else { continue }
            if best == nil || item.end > best!.end { best = item }
        }
        return best
    }

    /// The record that starts first within the gap after `end`.
    func next(start: Date, end: Date, excluding: String?) -> Item? {
        var i = firstIndex(atOrAfter: max(start.addingTimeInterval(1), end.addingTimeInterval(-Self.overlapSlack)))
        while i < items.count, items[i].start <= end.addingTimeInterval(Self.adjacencyGap) {
            if items[i].id != excluding { return items[i] }
            i += 1
        }
        return nil
    }

    /// Minutes from the day's first record to `start` — near enough the
    /// time since waking. Zero for the first record itself.
    func minutesIntoDay(start: Date, excluding: String?, calendar: Calendar) -> Int {
        var dayStart = calendar.startOfDay(for: start).addingTimeInterval(TimeInterval(Self.dayTurnHour * 3600))
        if dayStart > start { dayStart = dayStart.addingTimeInterval(-86_400) }
        var i = firstIndex(atOrAfter: dayStart)
        while i < items.count, items[i].start < start {
            if items[i].id != excluding {
                return Int(start.timeIntervalSince(items[i].start) / 60)
            }
            i += 1
        }
        return 0
    }

    private func firstIndex(atOrAfter date: Date) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].start < date { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

nonisolated enum WristTitleRanking {
    /// Names the drag-to-create picker shows above "just <type>".
    static let shownCount = 3
    static let halfLifeDays: Double = 30
    /// How far off the usual start still reads as "about then".
    static let startToleranceMinutes: Double = 90
    /// How far off the usual length (as a ratio, on a log scale) still reads
    /// as "about that long": twice or half as long scores about 0.6.
    static let lengthTolerance = log(2.0)
    /// The narrowest "into the day" spread taken at its word.
    static let intoDayToleranceMinutes: Double = 45
    /// Neither cue alone can bury a name the user picks all the time.
    static let startFloor = 0.15
    static let lengthFloor = 0.1
    static let intoDayFloor = 0.15
    /// Pseudo-uses spread evenly over the values of a categorical cue
    /// (weekday, neighbors), so a name seen twice is not ruled out by what
    /// those two uses happened not to show.
    static let smoothing = 1.0
    /// The share a neighbor is assumed to have when nothing is known about
    /// it — roughly one of a handful of usual neighbors.
    static let neighborPrior = 1.0 / 6
    /// The cues are not independent — what comes before a block and how far
    /// into the day it is both echo the clock — so each context factor is
    /// softened rather than multiplied in at full strength.
    static let contextTempering = 0.7

    /// How much what is right before and after a block counts. The phone
    /// learns neighbors from a history that is filled in; the watch sees a
    /// day still being logged — a block drawn from now has nothing after it
    /// yet, and the one before may not be entered — so "nothing adjacent"
    /// on the watch is weak evidence, and a missing or extra neighbor must
    /// not swing the order on its own. Measured in
    /// `WristTitleStabilityTests`.
    struct NeighborModel: Sendable {
        /// Power the neighbor factors are softened by.
        var tempering: Double
        /// Chance that "nothing before" means only "not logged (yet)".
        var unloggedBefore: Double
        /// The same for "nothing after".
        var unloggedAfter: Double

        static let standard = NeighborModel(tempering: 0.35, unloggedBefore: 0.5, unloggedAfter: 1)
        /// "Nothing" taken at its word and neighbors at full context
        /// strength: the model before it was measured, kept as the control
        /// the stability floors must catch.
        static let literal = NeighborModel(tempering: contextTempering, unloggedBefore: 0, unloggedAfter: 0)
    }

    /// Which cues take part — all of them, except to measure what each adds.
    struct Cues: OptionSet, Sendable {
        let rawValue: Int
        static let weekday = Cues(rawValue: 1)
        static let neighbors = Cues(rawValue: 2)
        static let intoDay = Cues(rawValue: 4)
        static let all: Cues = [.weekday, .neighbors, .intoDay]
    }

    /// The type's names, best first for a block from `start` to `end` in
    /// `context`.
    static func rank(
        _ hints: [WristTitleHint], start: Date, end: Date, calendar: Calendar,
        context: WristTitleContext = .none, cues: Cues = .all, limit: Int = shownCount,
        neighbors model: NeighborModel = .standard
    ) -> [String] {
        let components = calendar.dateComponents([.hour, .minute], from: start)
        let minute = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        let length = max(1, end.timeIntervalSince(start) / 60)
        return hints.enumerated()
            .map { (offset: $0.offset, title: $0.element.title,
                    score: score($0.element, minute: minute, length: length, context: context, cues: cues, neighbors: model)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .prefix(limit)
            .map(\.title)
    }

    /// The recency weight times one factor per cue. Each factor is a
    /// smoothed likelihood of what the context shows given this name; a cue
    /// the context or the hint lacks contributes nothing (a factor of one).
    static func score(
        _ hint: WristTitleHint, minute: Double, length: Double,
        context: WristTitleContext = .none, cues: Cues = .all, neighbors model: NeighborModel = .standard
    ) -> Double {
        let gap = abs(minute - Double(hint.startMinute)).truncatingRemainder(dividingBy: 1440)
        let circularGap = min(gap, 1440 - gap)
        let near = gaussian(circularGap / startToleranceMinutes)
        let concentration = min(1, max(0, Double(hint.concentration) / 100))
        let startFit = startFloor + (1 - startFloor) * ((1 - concentration) + concentration * near)
        let ratio = log(length / Double(max(1, hint.minutes)))
        let lengthFit = lengthFloor + (1 - lengthFloor) * gaussian(ratio / lengthTolerance)
        var score = max(0, hint.weight) * startFit * lengthFit
        if cues.contains(.weekday) {
            score *= pow(weekdayFit(hint, context.weekday), contextTempering)
        }
        if cues.contains(.neighbors) {
            score *= pow(neighborFit(hint.previous, context.previous, weight: hint.weight, unlogged: model.unloggedBefore), model.tempering)
            score *= pow(neighborFit(hint.next, context.next, weight: hint.weight, unlogged: model.unloggedAfter), model.tempering)
        }
        if cues.contains(.intoDay), let into = context.minutesIntoDay, let typical = hint.intoDay {
            let tolerance = max(intoDayToleranceMinutes, Double(hint.intoDaySpread ?? 0) * 1.5)
            score *= pow(intoDayFloor + (1 - intoDayFloor) * gaussian(Double(into - typical) / tolerance), contextTempering)
        }
        return score
    }

    /// Relative to a name seen evenly on every weekday.
    private static func weekdayFit(_ hint: WristTitleHint, _ weekday: Int?) -> Double {
        guard let weekday, (1...7).contains(weekday), let shares = hint.weekdays else { return 1 }
        let n = max(0, hint.weight)
        let share = Double(shares[weekday - 1]) / 100
        return (share * n + smoothing / 7) / (n + smoothing) * 7
    }

    /// Relative to `neighborPrior`. A neighbor the hint does not list gets
    /// a quarter of the share the listed ones leave over. "Nothing" is only
    /// what was seen with probability `unlogged` of a neighbor simply not
    /// being on the timeline yet.
    private static func neighborFit(_ pairs: [Int]?, _ neighbor: WristTitleContext.Neighbor?, weight: Double, unlogged: Double) -> Double {
        guard let pairs, let value = WristTitleContext.learned(neighbor) else { return 1 }
        var listed = 0.0
        var share: Double?
        var i = 0
        while i + 1 < pairs.count {
            let pct = Double(pairs[i + 1]) / 100
            listed += pct
            if pairs[i] == value { share = pct }
            i += 2
        }
        let observed = share ?? max(0, 1 - listed) / 4
        let n = max(0, weight)
        let p = (observed * n + smoothing * neighborPrior) / (n + smoothing)
        if value == WristTitleTable.nothing {
            return (p + unlogged * (1 - p)) / (neighborPrior + unlogged * (1 - neighborPrior))
        }
        return p / neighborPrior
    }

    private static func gaussian(_ z: Double) -> Double {
        exp(-z * z / 2)
    }
}
