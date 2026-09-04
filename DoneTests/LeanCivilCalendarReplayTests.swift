import XCTest
@testable import Done

/// Replays the Lean-model differential fixtures (`verification/fixtures.json`,
/// regenerate with `cd verification && lake exe fixturegen`) against the real
/// `Event` civil-calendar functions. The expectations were computed by the
/// SAME definitions the Lean theorems are proved about, over real tzdata
/// midnight tables sourced from python zoneinfo — a third implementation
/// independent of both this app and the model. gh#220.
///
/// Two expectation channels per fixture: `expectedModel` (what the proved
/// model says) and `expectedFoundation` (what Foundation actually does).
/// They differ only on the pinned midnight-less-day divergences
/// (America/Santiago — days that START at 01:00 because DST jumps at
/// midnight), where `Event.endOfDay`'s `startOfDay + 1 day − 1s` recipe
/// overshoots one hour into the next civil day. This test asserts
/// Foundation's ACTUAL behavior — so a Foundation/tzdata change that moves
/// any pin fails loudly — and separately asserts that pinned divergences
/// stay divergent, so a silently-healed pin is flagged for README cleanup.
final class LeanCivilCalendarReplayTests: XCTestCase {

    private struct Fixture: Decodable {
        let zone: String
        let label: String
        let kind: String
        let args: [Int]
        let expectedModel: Int?
        let expectedFoundation: Int?
        let expected2Model: Int?
        let expected2Foundation: Int?
        let diverges: Bool
    }

    private static func loadFixtures() throws -> [Fixture] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("verification/fixtures.json")
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    private func calendar(for zone: String) throws -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: zone), "unknown zone \(zone)")
        return cal
    }

    /// Returns (primary, secondary) actuals — secondary is the minted END for
    /// recurrence fixtures, nil for the scalar kinds.
    private func run(_ f: Fixture, in cal: Calendar) -> (Int?, Int?) {
        switch f.kind {
        case "endOfDay":
            return (Int(Event.endOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                calendar: cal
            ).timeIntervalSince1970), nil)
        case "allDayCivilEnd":
            return (Int(Event.allDayCivilEnd(
                anchoredAt: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                rawDuration: TimeInterval(f.args[1]),
                calendar: cal
            ).timeIntervalSince1970), nil)
        case "healedEnd":
            return (Event.legacyAllDayStraddleHealedEnd(
                start: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                end: Date(timeIntervalSince1970: TimeInterval(f.args[1])),
                calendar: cal
            ).map { Int($0.timeIntervalSince1970) }, nil)
        case "recurrenceOccurrence":
            // args: [unit, interval, seriesStart, raw, isAllDay, endType,
            //        endValue, suppressProbe, probeInstant]
            let seriesStart = Date(timeIntervalSince1970: TimeInterval(f.args[2]))
            let raw = TimeInterval(f.args[3])
            var series = Event(
                id: UUID(),
                title: "LeanRecurFixture",
                timeRanges: [Event.TimeRange(
                    start: seriesStart,
                    end: seriesStart.addingTimeInterval(raw)
                )],
                repeatUnit: f.args[0] == 1 ? .day : .week,
                isAllDay: f.args[4] == 1,
                repeatInterval: f.args[1],
                repeatEndType: f.args[5] == 1 ? .onDate : (f.args[5] == 2 ? .afterCount : .none),
                repeatEndDate: f.args[5] == 1
                    ? Date(timeIntervalSince1970: TimeInterval(f.args[6])) : nil,
                repeatEndCount: f.args[5] == 2 ? f.args[6] : nil,
                type: "Study"
            )
            let probe = Date(timeIntervalSince1970: TimeInterval(f.args[8]))
            if f.args[7] == 1 {
                series.appendRecurrenceException(onDay: probe, calendar: cal)
            }
            let range = CalendarLayout.recurrenceOccurrence(
                for: series, on: probe, calendar: cal
            )
            return (range.map { Int($0.start.timeIntervalSince1970) },
                    range.map { Int($0.end.timeIntervalSince1970) })
        case "dailyTotal":
            // args: [windowStart, windowEnd, dayStart, nEvents, s₁, e₁, …]
            var events: [Event] = []
            for i in 0..<f.args[3] {
                let s = TimeInterval(f.args[4 + 2 * i])
                let e = TimeInterval(f.args[5 + 2 * i])
                events.append(Event(
                    id: UUID(),
                    title: "E\(i)",
                    timeRanges: [Event.TimeRange(
                        start: Date(timeIntervalSince1970: s),
                        end: Date(timeIntervalSince1970: e)
                    )],
                    type: "Study"
                ))
            }
            let stats = ReportStatsBuilder.build(
                events: events,
                start: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                end: Date(timeIntervalSince1970: TimeInterval(f.args[1])),
                calendar: cal
            )
            let hours = stats.dailyTotals.first {
                Int($0.date.timeIntervalSince1970) == f.args[2]
            }?.hours ?? -1
            return (Int((hours * 3600).rounded()), nil)
        case "typeShare":
            // args: [windowStart, windowEnd, dayStart, typeIdx, s₀, e₀, s₁, e₁]
            let names = ["Study", "Play"]
            var events: [Event] = []
            for i in 0..<2 {
                let s = TimeInterval(f.args[4 + 2 * i])
                let e = TimeInterval(f.args[5 + 2 * i])
                events.append(Event(
                    id: UUID(),
                    title: "E\(i)",
                    timeRanges: [Event.TimeRange(
                        start: Date(timeIntervalSince1970: s),
                        end: Date(timeIntervalSince1970: e)
                    )],
                    type: names[i]
                ))
            }
            let stats = ReportStatsBuilder.build(
                events: events,
                start: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                end: Date(timeIntervalSince1970: TimeInterval(f.args[1])),
                calendar: cal
            )
            let hours = stats.perTypeHours.first {
                $0.type == names[f.args[3]]
            }?.hours ?? -1
            return (Int((hours * 3600).rounded()), nil)
        default:
            XCTFail("unknown fixture kind \(f.kind)")
            return (nil, nil)
        }
    }

    func testFixturesReplayAgainstFoundation() throws {
        let fixtures = try Self.loadFixtures()
        XCTAssertGreaterThanOrEqual(fixtures.count, 53, "fixture file truncated?")
        for f in fixtures {
            let actual = run(f, in: try calendar(for: f.zone))
            XCTAssertEqual(actual.0, f.expectedFoundation, "\(f.zone) — \(f.label)")
            if f.kind == "recurrenceOccurrence" {
                XCTAssertEqual(actual.1, f.expected2Foundation, "\(f.zone) — \(f.label) [end]")
            }
            if f.diverges {
                XCTAssertTrue(
                    f.expectedModel != f.expectedFoundation
                        || f.expected2Model != f.expected2Foundation,
                    "\(f.label): pin no longer divergent — Foundation now agrees; retire the pin"
                )
            } else {
                XCTAssertEqual(
                    f.expectedModel, f.expectedFoundation,
                    "\(f.label): non-divergent fixture carries mismatched expectations"
                )
                XCTAssertEqual(
                    f.expected2Model, f.expected2Foundation,
                    "\(f.label): non-divergent fixture carries mismatched end expectations"
                )
            }
        }
    }

    /// THEOREM 5's Foundation shadow (`healed_never_rematches`): every heal
    /// that fires must produce an end that can never match the signature
    /// again — replayed here against Foundation for every fixture outcome.
    func testHealIsIdempotentOnAllFixtureOutcomes() throws {
        for f in try Self.loadFixtures() where f.kind == "healedEnd" {
            guard let healed = f.expectedFoundation else { continue }
            let again = Event.legacyAllDayStraddleHealedEnd(
                start: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                end: Date(timeIntervalSince1970: TimeInterval(healed)),
                calendar: try calendar(for: f.zone)
            )
            XCTAssertNil(again, "\(f.label): healed end re-matched the signature")
        }
    }
}
