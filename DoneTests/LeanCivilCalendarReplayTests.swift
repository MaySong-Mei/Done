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

    private func run(_ f: Fixture, in cal: Calendar) -> Int? {
        switch f.kind {
        case "endOfDay":
            return Int(Event.endOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                calendar: cal
            ).timeIntervalSince1970)
        case "allDayCivilEnd":
            return Int(Event.allDayCivilEnd(
                anchoredAt: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                rawDuration: TimeInterval(f.args[1]),
                calendar: cal
            ).timeIntervalSince1970)
        case "healedEnd":
            return Event.legacyAllDayStraddleHealedEnd(
                start: Date(timeIntervalSince1970: TimeInterval(f.args[0])),
                end: Date(timeIntervalSince1970: TimeInterval(f.args[1])),
                calendar: cal
            ).map { Int($0.timeIntervalSince1970) }
        default:
            XCTFail("unknown fixture kind \(f.kind)")
            return nil
        }
    }

    func testFixturesReplayAgainstFoundation() throws {
        let fixtures = try Self.loadFixtures()
        XCTAssertGreaterThanOrEqual(fixtures.count, 25, "fixture file truncated?")
        for f in fixtures {
            let actual = run(f, in: try calendar(for: f.zone))
            XCTAssertEqual(actual, f.expectedFoundation, "\(f.zone) — \(f.label)")
            if f.diverges {
                XCTAssertNotEqual(
                    f.expectedModel, f.expectedFoundation,
                    "\(f.label): pin no longer divergent — Foundation now agrees; retire the pin"
                )
            } else {
                XCTAssertEqual(
                    f.expectedModel, f.expectedFoundation,
                    "\(f.label): non-divergent fixture carries mismatched expectations"
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
