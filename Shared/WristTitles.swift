//
//  WristTitles.swift
//  Shared (Done + DoneWatch)
//
//  Names the watch offers for a new block so nobody has to type on the
//  wrist. The phone learns them from history (`WristSnapshotBuilder.titleHints`)
//  and sends, per type on the start grid, a few names with when they usually
//  start and how long they usually last. The watch ranks those against the
//  block being named (`WristTitleRanking.rank`): a short morning block of
//  Work reads as the standup, a long one as deep work.
//

import Foundation

/// One name the user gave events of a type, with the shape of those events.
/// Short keys: up to a few dozen of these ride every snapshot.
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

    private enum CodingKeys: String, CodingKey {
        case title = "t", weight = "w", startMinute = "s", concentration = "c", minutes = "m"
    }

    init(title: String, weight: Double, startMinute: Int, concentration: Int, minutes: Int) {
        self.title = title
        self.weight = weight
        self.startMinute = startMinute
        self.concentration = concentration
        self.minutes = minutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute) ?? 0
        concentration = try c.decodeIfPresent(Int.self, forKey: .concentration) ?? 0
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 60
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
    /// Neither cue alone can bury a name the user picks all the time.
    static let startFloor = 0.15
    static let lengthFloor = 0.1

    /// The type's names, best first for a block from `start` to `end`.
    static func rank(
        _ hints: [WristTitleHint], start: Date, end: Date, calendar: Calendar, limit: Int = shownCount
    ) -> [String] {
        let components = calendar.dateComponents([.hour, .minute], from: start)
        let minute = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        let length = max(1, end.timeIntervalSince(start) / 60)
        return hints.enumerated()
            .map { (offset: $0.offset, title: $0.element.title, score: score($0.element, minute: minute, length: length)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .prefix(limit)
            .map(\.title)
    }

    static func score(_ hint: WristTitleHint, minute: Double, length: Double) -> Double {
        let gap = abs(minute - Double(hint.startMinute)).truncatingRemainder(dividingBy: 1440)
        let circularGap = min(gap, 1440 - gap)
        let near = gaussian(circularGap / startToleranceMinutes)
        let concentration = min(1, max(0, Double(hint.concentration) / 100))
        let startFit = startFloor + (1 - startFloor) * ((1 - concentration) + concentration * near)
        let ratio = log(length / Double(max(1, hint.minutes)))
        let lengthFit = lengthFloor + (1 - lengthFloor) * gaussian(ratio / lengthTolerance)
        return max(0, hint.weight) * startFit * lengthFit
    }

    private static func gaussian(_ z: Double) -> Double {
        exp(-z * z / 2)
    }
}
