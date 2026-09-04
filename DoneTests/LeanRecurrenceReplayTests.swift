import XCTest
@testable import Done

/// Behavior pins for the two expansion findings the gh#220 slice-1 Lean
/// model surfaced (`verification/CivilCalendar/Recurrence.lean`). Both pin
/// Foundation's ACTUAL behavior so any Foundation/tzdata change trips
/// loudly; neither is a fix — the findings are recorded on the campaign
/// issue and the fixes belong to their own issues.
final class LeanRecurrenceReplayTests: XCTestCase {

    /// FINDING 1 — the end-of-day gap frame breaks the prose premise.
    ///
    /// `seriesOccurrenceProbeDays`' exhaustiveness proof (and the model's
    /// `probe_span_exhaustive`) rests on "an occurrence anchored on D
    /// starts inside D's civil day". America/Nuuk jumps DST at 23:00
    /// local, so civil 2026-03-28 runs 23h and wall `[23:00, 24:00)` does
    /// not exist on it. `Event.dateByCombining`'s `bySettingHour` then
    /// resolves a 23:30 series' mint to the NEXT wall 23:30 — a full day
    /// past the anchor: the Mar 28 anchor and the Mar 29 anchor mint
    /// byte-identical ranges under two different occurrence ids. Every
    /// consumer that unions anchor days (canvas day columns, the report
    /// expander when the window spans both anchors) sees the slot twice.
    func testNuukEndOfDayGapSeriesDoubleMintPin() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Nuuk"))
        // Daily 23:30 series anchored 2026-03-26 (an ordinary 24h day).
        let seriesStart = Date(timeIntervalSince1970: 1_774_575_000)
        let series = Event(
            id: UUID(),
            title: "NuukLateSeries",
            timeRanges: [Event.TimeRange(
                start: seriesStart,
                end: seriesStart.addingTimeInterval(1800)
            )],
            repeatUnit: .day,
            type: "Study"
        )
        let mar28 = Date(timeIntervalSince1970: 1_774_700_000)
        let mar29 = Date(timeIntervalSince1970: 1_774_800_000)
        let r28 = try XCTUnwrap(
            CalendarLayout.recurrenceOccurrence(for: series, on: mar28, calendar: cal)
        )
        let r29 = try XCTUnwrap(
            CalendarLayout.recurrenceOccurrence(for: series, on: mar29, calendar: cal)
        )
        // The Mar 28 anchor's mint escapes onto Mar 29 23:30…
        XCTAssertEqual(
            Int(r28.start.timeIntervalSince1970), 1_774_830_600,
            "the escape moved — recalibrate the Nuuk pins"
        )
        // …byte-identical to Mar 29's own occurrence: two ids, one slot.
        XCTAssertEqual(r28.start, r29.start)
        XCTAssertEqual(r28.end, r29.end)
    }

    /// FINDING 2 — the report walker misses cross-midnight anchors.
    ///
    /// `walker_misses_cross_midnight_witness` (Lean) shows the gap
    /// abstractly; this is the same shape against the real builder:
    /// `expandOccurrences` walks anchors from `startOfDay(windowStart)`,
    /// so a 23:00→01:00 daily occurrence anchored the day BEFORE the
    /// window never gets its anchor probed — its 00:00–01:00 spill into
    /// the window is absent from every report aggregate, even though the
    /// post-filter (`range.end > windowStart`) would have kept it. The
    /// canvas probes `offset − 1` for exactly this case
    /// (`timelineCandidateDayOffsets`); the report walker does not.
    func testReportWalkerCrossMidnightAnchorPin() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // UTC civil midnights: day0 = 1_779_840_000 (86400-aligned).
        let day0 = 1_779_840_000
        let day1 = day0 + 86_400
        let day2 = day1 + 86_400
        // Daily series 23:00 → 01:00, anchored day 0.
        let seriesStart = Date(timeIntervalSince1970: TimeInterval(day0 + 82_800))
        let series = Event(
            id: UUID(),
            title: "CrossMidnightSeries",
            timeRanges: [Event.TimeRange(
                start: seriesStart,
                end: seriesStart.addingTimeInterval(7_200)
            )],
            repeatUnit: .day,
            type: "Study"
        )
        let occs = ReportStatsBuilder.expandOccurrences(
            events: [series],
            windowStart: Date(timeIntervalSince1970: TimeInterval(day1)),
            windowEnd: Date(timeIntervalSince1970: TimeInterval(day2)),
            calendar: cal
        )
        // Day 1's own anchor is expanded…
        XCTAssertEqual(occs.count, 1, "walker coverage changed — re-read the Lean witness")
        XCTAssertEqual(
            occs.first.map { Int($0.range.start.timeIntervalSince1970) },
            day1 + 82_800
        )
        // …and the day-0 anchor's 00:00–01:00 spill into the window is the
        // documented miss: nothing in `occs` starts before the window.
        XCTAssertNil(
            occs.first(where: { $0.range.start.timeIntervalSince1970 < TimeInterval(day1) }),
            "the walker now catches pre-window anchors — retire this pin and the Lean witness note"
        )
    }
}
