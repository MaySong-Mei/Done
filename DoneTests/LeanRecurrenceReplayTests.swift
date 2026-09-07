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

    /// gh#222 HEALED — the walker opens a duration-adaptive look-back.
    ///
    /// `walker_misses_cross_midnight_witness` (Lean) shows why the look-back
    /// is REQUIRED: a 23:00→01:00 daily occurrence anchored the day before
    /// the window overlaps it while its anchor sits below
    /// `dayOf(windowStart)`. The fix walks from
    /// `startOfDay(windowStart − duration)` (the gh#209 probe-span
    /// arithmetic, `probe_span_exhaustive`), so the spill is now minted and
    /// the post-filter keeps it.
    func testReportWalkerCatchesCrossMidnightAnchors() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day0 = 1_779_840_000
        let day1 = day0 + 86_400
        let day2 = day1 + 86_400
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
        XCTAssertEqual(occs.count, 2, "day-0 spill AND day-1's own occurrence")
        XCTAssertNotNil(occs.first {
            Int($0.range.start.timeIntervalSince1970) == day0 + 82_800
        }, "the pre-window anchor's spill occurrence is minted")
        XCTAssertNotNil(occs.first {
            Int($0.range.start.timeIntervalSince1970) == day1 + 82_800
        })
    }

    /// gh#222 at the aggregate level: the spill hour lands in the day's
    /// report bucket — dailyTotals reads 2 h (00:00–01:00 spill +
    /// 23:00–24:00), where the pre-fix walker read 1 h.
    func testReportBuildCountsCrossMidnightSpill() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day0 = 1_779_840_000
        let day1 = day0 + 86_400
        let day2 = day1 + 86_400
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
        let stats = ReportStatsBuilder.build(
            events: [series],
            start: Date(timeIntervalSince1970: TimeInterval(day1)),
            end: Date(timeIntervalSince1970: TimeInterval(day2)),
            calendar: cal
        )
        let hours = stats.dailyTotals.first {
            Int($0.date.timeIntervalSince1970) == day1
        }?.hours
        XCTAssertEqual(hours ?? -1, 2.0, accuracy: 1e-9,
                       "the post-midnight spill hour must count")
    }

    /// gh#222, duration-adaptive reach: a 30 h primary anchored the day
    /// before the window still spills in and is caught — one look-back day
    /// would not have sufficed for multi-day primaries.
    func testReportWalkerLongPrimaryLookback() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day0 = 1_779_840_000
        let day1 = day0 + 86_400
        let day2 = day1 + 86_400
        let day3 = day2 + 86_400
        let seriesStart = Date(timeIntervalSince1970: TimeInterval(day0 + 32_400))
        let series = Event(
            id: UUID(),
            title: "ThirtyHourSeries",
            timeRanges: [Event.TimeRange(
                start: seriesStart,
                end: seriesStart.addingTimeInterval(108_000)
            )],
            repeatUnit: .day,
            type: "Study"
        )
        let occs = ReportStatsBuilder.expandOccurrences(
            events: [series],
            windowStart: Date(timeIntervalSince1970: TimeInterval(day2)),
            windowEnd: Date(timeIntervalSince1970: TimeInterval(day3)),
            calendar: cal
        )
        XCTAssertNotNil(occs.first {
            Int($0.range.start.timeIntervalSince1970) == day1 + 32_400
        }, "the day-1 anchor's 30h occurrence spills into day 2 and must be minted")
        XCTAssertNotNil(occs.first {
            Int($0.range.start.timeIntervalSince1970) == day2 + 32_400
        })
        XCTAssertEqual(occs.count, 2, "day-0's occurrence ends before the window and stays filtered")
    }
}
