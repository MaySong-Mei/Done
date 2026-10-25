import XCTest
@testable import Done

/// Empirical shadows of `verification/CivilCalendar/OverlapCore.lean`
/// (gh#224 slice 3) against the real `CalendarLayout.overlapLayout`. The
/// Lean module proves the recursion's skeleton laws in exact arithmetic;
/// these tests hold the float implementation to them (1e-3, the suite's
/// standing tolerance), plus the two whole-pipeline properties the model
/// deliberately leaves empirical: shuffle invariance and id totality.
final class LeanOverlapShadowTests: XCTestCase {

    private let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Deterministic LCG — no wall clock, no system RNG.
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private let day0 = 1_779_840_000

    private func occ(_ id: String, startSec: Int, durSec: Int) -> CalendarLayout.EventOccurrence {
        let start = Date(timeIntervalSince1970: TimeInterval(day0 + startSec))
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(TimeInterval(durSec)))
        let event = Event(
            id: UUID(),
            title: id,
            timeRanges: [range],
            type: "Study"
        )
        return CalendarLayout.EventOccurrence(id: id, event: event, range: range)
    }

    private var dayDate: Date { Date(timeIntervalSince1970: TimeInterval(day0 + 43_200)) }

    /// THEOREM 51's shadow (containment): across seeded random clusters,
    /// every slot stays inside the unit column.
    func testSlotsStayInsideTheUnitColumn() {
        var rng = LCG(state: 0x224_5303)
        for trial in 0..<30 {
            var occs: [CalendarLayout.EventOccurrence] = []
            let n = 2 + rng.next(7)
            for i in 0..<n {
                let start = rng.next(20 * 3600)
                let dur = 900 + rng.next(6 * 3600)
                occs.append(occ("t\(trial)-\(i)", startSec: start, durSec: dur))
            }
            let layout = CalendarLayout.overlapLayout(for: occs, on: dayDate, calendar: utc)
            for (id, slot) in layout {
                XCTAssertGreaterThanOrEqual(slot.xOffsetFraction, -0.0001, "\(id) x")
                XCTAssertGreaterThan(slot.widthFraction, 0, "\(id) w")
                XCTAssertLessThanOrEqual(slot.xOffsetFraction + slot.widthFraction, 1.0001,
                                         "trial \(trial), \(id): slot leaks the column")
            }
            // THEOREM 50's totality shadow: every input id got a slot.
            XCTAssertEqual(layout.count, n, "trial \(trial): an occurrence vanished")
        }
    }

    /// THEOREM 50's shadow (termination + dyadic width): a 6-deep
    /// forced-peek nest bottoms out at depth 5 with width exactly 2⁻⁵ —
    /// the recursion halts within the cluster size and never thins a slot
    /// past the dyadic floor.
    func testForcedPeekNestDepthAndWidthBounds() {
        // Same start, durations halving steeply: every level's ratio ≥ 2
        // forces stack-peek all the way down.
        let durations = [43_200, 21_600, 10_800, 5_400, 2_700, 1_350]
        let occs = durations.enumerated().map { occ("nest\($0.offset)", startSec: 3600, durSec: $0.element) }
        let layout = CalendarLayout.overlapLayout(for: occs, on: dayDate, calendar: utc)
        XCTAssertEqual(layout.count, durations.count)
        let maxDepth = layout.values.map(\.depth).max() ?? -1
        XCTAssertEqual(maxDepth, durations.count - 1,
                       "the recursion depth is the cluster size minus one, exactly")
        let minWidth = layout.values.map(\.widthFraction).min() ?? -1
        XCTAssertEqual(minWidth, pow(0.5, Double(durations.count - 1)), accuracy: 0.001,
                       "the deepest strip width is exactly 2^-(n-1)")
    }

    /// THEOREM 52's shadow (equal-split partition): three equal peers tile
    /// the column — widths a third each, starts at 0, 1/3, 2/3, no gap.
    func testEqualPeersTileTheColumn() {
        let occs = (0..<3).map { occ("peer\($0)", startSec: 7200, durSec: 3600) }
        let layout = CalendarLayout.overlapLayout(for: occs, on: dayDate, calendar: utc)
        let slots = layout.values.sorted { $0.xOffsetFraction < $1.xOffsetFraction }
        XCTAssertEqual(slots.count, 3)
        for (i, slot) in slots.enumerated() {
            XCTAssertEqual(slot.xOffsetFraction, Double(i) / 3.0, accuracy: 0.001)
            XCTAssertEqual(slot.widthFraction, 1.0 / 3.0, accuracy: 0.001)
        }
    }

    /// THEOREM 53's shadow (determinism under unique ids): the layout is a
    /// pure function of the SET — five deterministic shuffles of a mixed
    /// cluster produce byte-identical slot maps.
    func testLayoutIsShuffleInvariant() {
        let base = [
            occ("a", startSec: 3600, durSec: 14_400),
            occ("b", startSec: 3600, durSec: 7_200),
            occ("c", startSec: 5400, durSec: 3_600),
            occ("d", startSec: 9000, durSec: 10_800),
            occ("e", startSec: 12_600, durSec: 1_800),
            occ("f", startSec: 3600, durSec: 14_400),
            occ("g", startSec: 20_000, durSec: 900),
        ]
        let reference = CalendarLayout.overlapLayout(for: base, on: dayDate, calendar: utc)
        var rng = LCG(state: 0x224_5304)
        for round in 0..<5 {
            var shuffled = base
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                shuffled.swapAt(i, rng.next(i + 1))
            }
            let layout = CalendarLayout.overlapLayout(for: shuffled, on: dayDate, calendar: utc)
            XCTAssertEqual(layout.count, reference.count)
            for (id, slot) in reference {
                let other = layout[id]
                XCTAssertEqual(other?.xOffsetFraction ?? -1, slot.xOffsetFraction,
                               accuracy: 1e-9, "round \(round), \(id) x moved under shuffle")
                XCTAssertEqual(other?.widthFraction ?? -1, slot.widthFraction,
                               accuracy: 1e-9, "round \(round), \(id) w moved under shuffle")
                XCTAssertEqual(other?.depth ?? -1, slot.depth,
                               "round \(round), \(id) depth moved under shuffle")
            }
        }
    }
}
