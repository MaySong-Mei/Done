import XCTest
@testable import Done

/// How well the watch's name ranking guesses, measured rather than argued:
/// a synthetic routine with noise, each recent event held out in turn and
/// named from what came before it, once per set of cues. The floors keep a
/// cue from silently stopping to help; the shuffled run is the control that
/// the measurement itself can fail.
@MainActor
final class WristTitleBacktestTests: XCTestCase {
    private let calendar = WristTitleHistory.calendar
    private var today: Date { WristTitleHistory.today }
    private let evaluatedDays = 21
    private let types = WristTitleHistory.types

    private typealias Random = WristTitleHistory.Random

    private func history() -> [Event] { WristTitleHistory.routine() }

    private struct Score {
        var top1 = 0
        var top3 = 0
        var total = 0
        var chance = 0.0
        /// Held-out names among the ones offered at all: no ranking can
        /// beat this.
        var offered = 0
        var misses: [String: Int] = [:]
        var top1Rate: Double { Double(top1) / Double(max(1, total)) }
        var top3Rate: Double { Double(top3) / Double(max(1, total)) }
        var chanceRate: Double { chance / Double(max(1, total)) }
    }

    private static let variants: [(String, WristTitleRanking.Cues)] = [
        ("time+length", []),
        ("+weekday", [.weekday]),
        ("+neighbors", [.neighbors]),
        ("+into day", [.intoDay]),
        ("all", .all),
    ]

    /// Each event of the last `evaluatedDays` days, named from the history
    /// strictly before it (as of its start) with its own day's other
    /// records as context — someone filling in the day on the watch.
    private func backtest(_ events: [Event]) -> [String: Score] {
        let cutoff = calendar.date(byAdding: .day, value: -evaluatedDays, to: today)!
        var scores: [String: Score] = [:]
        let held = events.filter { $0.primaryTimeRange!.start >= cutoff }
        for event in held {
            let range = event.primaryTimeRange!
            let others = events.filter { $0.id != event.id }
            let hints = WristSnapshotBuilder.titleHints(
                events: others.filter { $0.primaryTimeRange!.start < range.start }, types: types,
                now: range.start, calendar: calendar
            )
            guard let offered = hints[event.type], !offered.isEmpty else { continue }
            let table = WristTitleTable(typeOrder: types.map(\.title), hints: hints)
            let timeline = WristTitleTimeline(others.map {
                WristTitleTimeline.Item(id: $0.id.uuidString, start: $0.primaryTimeRange!.start,
                                        end: $0.primaryTimeRange!.end, title: $0.title, type: $0.type)
            })
            let context = timeline.context(start: range.start, end: range.end, table: table, calendar: calendar)
            for (label, cues) in Self.variants {
                let ranked = WristTitleRanking.rank(
                    offered, start: range.start, end: range.end, calendar: calendar,
                    context: context, cues: cues, limit: 3
                )
                var score = scores[label] ?? Score()
                score.total += 1
                score.chance += 1 / Double(offered.count)
                if offered.contains(where: { $0.title == event.title }) { score.offered += 1 }
                if ranked.first == event.title { score.top1 += 1 } else {
                    score.misses["\(event.title)→\(ranked.first ?? "-")", default: 0] += 1
                }
                if ranked.contains(event.title) { score.top3 += 1 }
                scores[label] = score
            }
        }
        return scores
    }

    private func report(_ title: String, _ scores: [String: Score]) {
        let all = scores["all"] ?? Score()
        print("WristTitleBacktest \(title): n=\(all.total), offered \(String(format: "%.3f", Double(all.offered) / Double(max(1, all.total)))), chance top-1 \(String(format: "%.2f", all.chanceRate))")
        for (label, _) in Self.variants {
            guard let s = scores[label] else { continue }
            print(String(format: "WristTitleBacktest %@ %-12@ top-1 %.3f  top-3 %.3f", title, label, s.top1Rate, s.top3Rate)
                  + " misses " + s.misses.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        }
    }

    func testEachCueEarnsItsPlace() throws {
        let scores = backtest(history())
        report("routine", scores)
        let base = try XCTUnwrap(scores["time+length"])
        let all = try XCTUnwrap(scores["all"])
        XCTAssertGreaterThan(base.total, 120, "enough held-out events to mean something")
        // Floors a little under the measured figures (see the printed table):
        // context is worth about twelve points of top-1 here, and the top
        // three come within a held-out name or so of the names offered at all.
        let ceiling = Double(all.offered) / Double(all.total)
        XCTAssertGreaterThanOrEqual(base.top1Rate, 0.70)
        XCTAssertGreaterThanOrEqual(all.top1Rate, 0.88)
        XCTAssertGreaterThanOrEqual(all.top3Rate, ceiling - 0.02)
        XCTAssertGreaterThanOrEqual(all.top1Rate, base.top1Rate + 0.08, "context beats clock and length alone")
        for label in ["+weekday", "+neighbors", "+into day"] {
            let s = try XCTUnwrap(scores[label])
            XCTAssertGreaterThan(s.top1Rate, base.top1Rate, "\(label) adds something on its own")
            XCTAssertGreaterThanOrEqual(all.top1Rate, s.top1Rate, "together no worse than \(label) alone")
        }
    }

    /// Positive control: the same history with every event's name shuffled
    /// among the events of its type. Nothing is left to learn, so no set of
    /// cues may beat a guess by much — if it did, the backtest would be
    /// leaking the answer.
    func testShuffledNamesScoreNearChance() throws {
        var events = history()
        var rng = Random(state: 7)
        for type in types.map(\.title) {
            let indices = events.indices.filter { events[$0].type == type }
            var titles = indices.map { events[$0].title }
            for i in stride(from: titles.count - 1, to: 0, by: -1) {
                titles.swapAt(i, rng.int(0...i))
            }
            for (i, index) in indices.enumerated() { events[index].title = titles[i] }
        }
        let scores = backtest(events)
        report("shuffled", scores)
        for (label, _) in Self.variants {
            let s = try XCTUnwrap(scores[label])
            XCTAssertLessThan(s.top1Rate, s.chanceRate + 0.15, "\(label) on shuffled names")
        }
    }
}
