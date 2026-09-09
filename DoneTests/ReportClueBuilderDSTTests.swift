import XCTest
@testable import Done

/// DST-frame regressions for the gh#227 clue-battery window fixes. The
/// existing `ReportClueBuilderTests` run entirely in UTC, so the two live
/// bugs the Lean model (`verification/CivilCalendar/ClueWindows.lean`)
/// surfaced were invisible to the suite by construction. These run in
/// America/Los_Angeles across real transitions. Each was counter-checked:
/// reverting its fix reddens it (the scenario genuinely separates the
/// buggy and fixed builders, not the builder's own output).
final class ReportClueBuilderDSTTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func event(type: String, start: Date, durationHours: Double) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(
                start: start, end: start.addingTimeInterval(durationHours * 3600))],
            type: type
        )
    }

    /// R1 — the daily clamped history cell must not spill past its own civil
    /// midnight on a 25h fall-back "today". `elapsed` is measured on the 25h
    /// day (here 89_400s ≈ 24h50m); applied without a `min(..., nextMidnight)`
    /// guard to a normal 24h history midnight it reaches 01:00 of the NEXT
    /// civil day, so each history cell double-claims the next day's first
    /// hour. With a 00:00–01:00 session every day, the unguarded baseline
    /// reads 2h/day while today reads 1h -> a fabricated "down" deviation.
    /// The guard restores 1h/day -> today == typical -> no clue.
    /// Counter-checked: reverting the `min` guard reddens this.
    func testDailyClampedCellDoesNotSpillOnFallBackDay() {
        let cal = self.cal
        let today = cal.startOfDay(for: cal.date(from: DateComponents(
            year: 2026, month: 11, day: 1))!)   // LA fall-back: 25h day
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let asOf = today.addingTimeInterval(89_400)   // 24h50m in -> isPartial, spill grabs 0.83h

        var events: [Event] = []
        for back in 0...28 {
            let d = cal.startOfDay(for: cal.date(byAdding: .day, value: -back, to: today)!)
            events.append(event(type: "Study", start: d, durationHours: 1))
        }

        let emission = ReportClueBuilder.build(
            events: events, logRecords: [],
            start: today, end: tomorrow, asOf: asOf,
            calendar: cal, priorFingerprints: []
        )
        let studyDeviation = emission.candidates.contains {
            $0.kind == .deviation && $0.type == "Study"
        }
        XCTAssertFalse(studyDeviation,
            "the clamped cell spilled past midnight and fabricated a deviation (gh#227 R1)")
    }

    /// R3 — the absence gate's elapsed-day count must be CIVIL, not
    /// `Int(elapsed/86400)`. Across a spring-forward the fixed divisor
    /// truncated three civil days (255_600s) to 2. The gate is
    /// `rate * elapsedFullDays >= 2`; with a habitual type at rate 0.7,
    /// buggy `0.7*2 = 1.4 < 2` suppresses a due absence while civil
    /// `0.7*3 = 2.1 >= 2` fires it. (A rate-1.0 type clears the gate under
    /// both -- the earlier draft's blind spot; the Work filler pins rate
    /// into the discriminating band.) Counter-checked: reverting to
    /// `Int(elapsed/86400)` reddens this.
    func testAbsenceGateCountsCivilDaysAcrossSpringForward() {
        let cal = self.cal
        let start = cal.startOfDay(for: cal.date(from: DateComponents(
            year: 2026, month: 3, day: 8))!)   // LA spring-forward: 23h day 0
        let end = cal.date(byAdding: .day, value: 7, to: start)!
        let asOf = cal.startOfDay(for: cal.date(byAdding: .day, value: 3, to: start)!)

        var events: [Event] = []
        for back in 1...20 {
            let d = cal.startOfDay(for: cal.date(byAdding: .day, value: -back, to: start)!)
            events.append(event(type: "Work", start: d.addingTimeInterval(9 * 3600), durationHours: 1))
            if back <= 14 {
                events.append(event(type: "Gym", start: d.addingTimeInterval(18 * 3600), durationHours: 1))
            }
        }
        events.append(event(type: "Work", start: start.addingTimeInterval(9 * 3600), durationHours: 1))

        let emission = ReportClueBuilder.build(
            events: events, logRecords: [],
            start: start, end: end, asOf: asOf,
            calendar: cal, priorFingerprints: []
        )
        let gymAbsence = emission.candidates.contains {
            $0.kind == .absence && $0.type == "Gym"
        }
        XCTAssertTrue(gymAbsence,
            "the spring-forward week's third civil day was lost to Int(elapsed/86400), suppressing a due absence clue (gh#227 R3)")
    }
    /// The :379 emergence gap heal (raw dateComponents -> civilComponentDistance,
    /// gh#223's helper the report never adopted). It changes output only on a
    /// midnight-less anchor day: America/Santiago 2026-09-06 springs forward AT
    /// 00:00, so its civil day starts 01:00. A "Study" last seen that day and
    /// reappearing exactly 14 civil days later is a "return after 14" emergence;
    /// raw dateComponents from the 01:00 anchor reads 13 (the 23h first step
    /// counts short) and suppresses it at the 14-day gate. Counter-checked:
    /// reverting to raw dateComponents reddens this (gh#227).
    func testEmergenceGapHealCountsCivilDaysFromMidnightlessAnchor() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        let windowStart = c.startOfDay(for: c.date(from: DateComponents(
            year: 2026, month: 9, day: 20))!)
        let end = c.date(byAdding: .day, value: 1, to: windowStart)!
        let lastSeenDay = c.startOfDay(for: c.date(from: DateComponents(
            year: 2026, month: 9, day: 6))!)   // midnight-less day (starts 01:00)

        let events = [
            // reappears today
            event(type: "Study", start: windowStart.addingTimeInterval(9 * 3600), durationHours: 1),
            // last seen exactly 14 civil days ago, on the midnight-less day
            event(type: "Study", start: lastSeenDay.addingTimeInterval(9 * 3600), durationHours: 1),
        ]
        let emission = ReportClueBuilder.build(
            events: events, logRecords: [],
            start: windowStart, end: end, asOf: end,
            calendar: c, priorFingerprints: []
        )
        let studyReturn = emission.candidates.contains {
            $0.kind == .emergence && $0.type == "Study" && $0.direction == "return"
        }
        XCTAssertTrue(studyReturn,
            "raw dateComponents undercounted the gap from a midnight-less anchor and suppressed a due emergence clue (gh#227 :379)")
    }
}
