import XCTest
@testable import Done

/// Behavior pins for the two expansion findings the gh#220 slice-1 Lean
/// model surfaced (`verification/CivilCalendar/Recurrence.lean`). Both pin
/// Foundation's ACTUAL behavior so any Foundation/tzdata change trips
/// loudly; neither is a fix — the findings are recorded on the campaign
/// issue and the fixes belong to their own issues.
final class LeanRecurrenceReplayTests: XCTestCase {

    /// gh#223 HEALED — the mint clamps into its anchor day.
    ///
    /// America/Nuuk jumps DST at 23:00 local, so civil 2026-03-28 runs 23h
    /// and wall `[23:00, 24:00)` does not exist. Pre-fix,
    /// `dateByCombining`'s `.nextTime` resolution sent a 23:30 series' mint
    /// to the NEXT day's 23:30 — the Mar 28 and Mar 29 anchors minted
    /// byte-identical ranges (double render, double count). The mint now
    /// clamps to the anchor day's last second, the two anchors mint
    /// DISTINCT ranges, and the gh#209 probe-span premise holds for
    /// Foundation again.
    func testNuukEndOfDayGapSeriesMintsClampAndStayDistinct() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Nuuk"))
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
        XCTAssertEqual(Int(r28.start.timeIntervalSince1970), 1_774_745_999,
                       "the mint clamps to the shortened day's last second")
        XCTAssertEqual(Int(r29.start.timeIntervalSince1970), 1_774_830_600,
                       "the next anchor keeps its own true 23:30")
        XCTAssertNotEqual(r28.start, r29.start, "the double-mint stays dead")
    }

    /// gh#223 HEALED — gap-anchored counting no longer runs long.
    ///
    /// A daily afterCount-2 series anchored ON Santiago's midnight-less day
    /// (civil 2026-09-06 starts at 01:00) used to match a THIRD day: the
    /// 23h first step counted as zero, so every index came up one short.
    /// Noon-anchored distance restores the count: days one and two match,
    /// day three is refused.
    func testGapAnchoredAfterCountNoLongerRunsLong() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let seriesStart = Date(timeIntervalSince1970: 1_788_669_000)
        let series = Event(
            id: UUID(),
            title: "GapAnchoredCounted",
            timeRanges: [Event.TimeRange(
                start: seriesStart,
                end: seriesStart.addingTimeInterval(3600)
            )],
            repeatUnit: .day,
            repeatInterval: 1,
            repeatEndType: .afterCount,
            repeatEndCount: 2,
            type: "Study"
        )
        let sep7 = Date(timeIntervalSince1970: 1_788_793_200)
        let sep8 = Date(timeIntervalSince1970: 1_788_879_600)
        XCTAssertNotNil(
            CalendarLayout.recurrenceOccurrence(for: series, on: sep7, calendar: cal),
            "index 1 of 2 — still inside the count"
        )
        XCTAssertNil(
            CalendarLayout.recurrenceOccurrence(for: series, on: sep8, calendar: cal),
            "index 2 — the count is spent; pre-fix this day ran long"
        )
    }

    /// gh#223 accepted collateral — the one modern frame where noon itself
    /// is gapped. Africa/Khartoum 2000-01-15 jumps +02:00→+03:00 at 12:00,
    /// so `civilComponentDistance`'s from-side noon resolves to 13:00 and
    /// every distance FROM that day counts one short: a daily interval-2
    /// series anchored there phantom-matches the NEXT day (distance reads
    /// 0) and wrongly rejects the day after (reads 1). Bounded exposure —
    /// one Sudanese civil day in 2000, in an app whose data starts 2026 —
    /// pinned so the doc comment's bounded claim cannot rot into a
    /// universal one. If this pin ever breaks, either tzdata moved or the
    /// distance derivation changed: re-run the QA noon-gap scan.
    func testKhartoumNoonGapAcceptedCollateral() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "Africa/Khartoum"))
        let jan15Start = Date(timeIntervalSince1970: 947_887_200)
        let series = Event(
            id: UUID(),
            title: "KhartoumAnchor",
            timeRanges: [Event.TimeRange(
                start: jan15Start.addingTimeInterval(3600),
                end: jan15Start.addingTimeInterval(7200)
            )],
            repeatUnit: .day,
            repeatInterval: 2,
            type: "Study"
        )
        let jan16 = Date(timeIntervalSince1970: 947_970_000 + 43_200)
        let jan17 = Date(timeIntervalSince1970: 948_056_400 + 43_200)
        XCTAssertNotNil(
            CalendarLayout.recurrenceOccurrence(for: series, on: jan16, calendar: cal),
            "accepted collateral: the gapped noon makes Jan 16 phantom-match at distance 0"
        )
        XCTAssertNil(
            CalendarLayout.recurrenceOccurrence(for: series, on: jan17, calendar: cal),
            "accepted collateral: true parity day Jan 17 is wrongly rejected at distance 1"
        )
    }

    /// gh#224 slice-2 pin — the series-tail membership ASYMMETRY.
    ///
    /// `occurrencesForDate`'s recurring branch appends the expanded
    /// occurrence on its ANCHOR day only (no overlap test), so a
    /// cross-midnight series occurrence's tail is NOT a member of the next
    /// day's own list — unlike a plain event with the identical range,
    /// which fans out through the half-open membership test
    /// (`memberDay_iff` in the Lean model). Compensation is PARTIAL: the
    /// widget window starts yesterday and the report walker looks back
    /// (gh#222), but the canvas pulls `offset − 1` ONLY while a leading
    /// boundary extension is open (`timelineCandidateDayOffsets` gates on
    /// `leadingExtendedHours > 0`) — the steady-state next-day column,
    /// FocusMode's current-occurrence probe, and the Analysis per-day
    /// aggregation do NOT compensate: filed as gh#225. This pin exists so
    /// the next consumer of `occurrencesForDate` reads it before trusting
    /// the list alone. If it fails because the recurring branch learned
    /// the overlap test (gh#225's second fix shape), retire it and audit
    /// the compensations into redundancies.
    func testSeriesTailMembershipAsymmetryPin() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day0 = 1_779_840_000
        let day1 = day0 + 86_400
        let start = Date(timeIntervalSince1970: TimeInterval(day0 + 82_800))
        let seriesID = UUID()
        let series = Event(
            id: seriesID,
            title: "CrossMidnightSeries",
            timeRanges: [Event.TimeRange(
                start: start, end: start.addingTimeInterval(7_200))],
            repeatUnit: .day,
            type: "Study"
        )
        let plainID = UUID()
        let plain = Event(
            id: plainID,
            title: "CrossMidnightPlain",
            timeRanges: [Event.TimeRange(
                start: start, end: start.addingTimeInterval(7_200))],
            type: "Study"
        )
        let nextDay = Date(timeIntervalSince1970: TimeInterval(day1 + 43_200))
        let occs = CalendarLayout.occurrencesForDate(
            [series, plain], date: nextDay, calendar: cal)
        XCTAssertTrue(occs.contains { $0.event.id == plainID },
                      "the plain event's tail IS a member of the next day")
        // day 1's own anchor mints its own occurrence — the day-0 TAIL is
        // what must be absent; distinguish by the minted range's start.
        let day0AnchorTailPresent = occs.contains {
            $0.event.id == seriesID
                && Int($0.range.start.timeIntervalSince1970) == day0 + 82_800
        }
        XCTAssertFalse(day0AnchorTailPresent,
                       "the asymmetry healed — retire this pin and audit the compensations")
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
