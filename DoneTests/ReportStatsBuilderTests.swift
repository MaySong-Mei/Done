import XCTest
@testable import Done

final class ReportStatsBuilderTests: XCTestCase {

    // UTC keeps day-boundary arithmetic exact and independent of the host
    // locale — the builder is timezone-agnostic (callers pass their calendar).
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    private func event(
        type: String,
        start: Date,
        end: Date,
        additionalTypes: [String]? = nil,
        typeWeights: [String: Double]? = nil
    ) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: type,
            additionalTypes: additionalTypes,
            typeWeights: typeWeights
        )
    }

    // MARK: - Cross-midnight attribution

    func testSessionDailyAttributesCrossMidnightToDominantDay() {
        // 23:00 Jun 2 → 07:00 Jun 3: 1h on day 2, 7h on day 3 → whole 8h lands
        // on Jun 3, while dailyTotals splits it 1h / 7h.
        let e = event(type: "sleep", start: date(2026, 6, 2, 23), end: date(2026, 6, 3, 7))
        let stats = ReportStatsBuilder.build(
            events: [e],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )

        let session = stats.sessionDaily.first { $0.type == "sleep" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.date, date(2026, 6, 3))
        XCTAssertEqual(session?.hours ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(stats.sessionDaily.filter { $0.type == "sleep" }.count, 1)

        let day2Total = stats.dailyTotals.first { $0.date == date(2026, 6, 2) }?.hours ?? 0
        let day3Total = stats.dailyTotals.first { $0.date == date(2026, 6, 3) }?.hours ?? 0
        XCTAssertEqual(day2Total, 1, accuracy: 0.001)
        XCTAssertEqual(day3Total, 7, accuracy: 0.001)
    }

    // MARK: - Weight distribution

    func testMultiTypeHoursSplitByWeights() {
        // 4h event, weights 3:1 → 3h to "work", 1h to "study".
        let e = event(
            type: "work",
            start: date(2026, 6, 2, 9),
            end: date(2026, 6, 2, 13),
            additionalTypes: ["study"],
            typeWeights: ["work": 3, "study": 1]
        )
        let stats = ReportStatsBuilder.build(
            events: [e],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        let work = stats.perTypeHours.first { $0.type == "work" }?.hours ?? 0
        let study = stats.perTypeHours.first { $0.type == "study" }?.hours ?? 0
        XCTAssertEqual(work, 3, accuracy: 0.001)
        XCTAssertEqual(study, 1, accuracy: 0.001)
    }

    func testMultiTypeNilWeightsSplitsEqually() {
        let e = event(
            type: "a",
            start: date(2026, 6, 2, 9),
            end: date(2026, 6, 2, 13),
            additionalTypes: ["b"]
        )
        let stats = ReportStatsBuilder.build(
            events: [e],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        XCTAssertEqual(stats.perTypeHours.first { $0.type == "a" }?.hours ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(stats.perTypeHours.first { $0.type == "b" }?.hours ?? 0, 2, accuracy: 0.001)
    }

    // MARK: - Window filtering + previous-window baseline

    func testWindowFilteringAndPreviousBaseline() {
        // Two identical 2h events: one in the previous window, one in the
        // current window.  The builder must slice them apart from one array.
        let previous = event(type: "gym", start: date(2026, 5, 27, 8), end: date(2026, 5, 27, 10))
        let current = event(type: "gym", start: date(2026, 6, 3, 8), end: date(2026, 6, 3, 10))
        let outside = event(type: "gym", start: date(2026, 4, 1, 8), end: date(2026, 4, 1, 10))

        let stats = ReportStatsBuilder.build(
            events: [previous, current, outside],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        let gym = stats.perTypeHours.first { $0.type == "gym" }
        XCTAssertEqual(gym?.hours ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(gym?.previousHours ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(gym?.deltaHours ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(stats.window.eventCount, 1) // only the in-window event counts
    }

    // MARK: - Confidence thresholds

    func testDeltaTierNoiseFloorAndThinCap() {
        // 0.5h vs 0h — below the noise floor → low.
        let low = ReportStatsBuilder.build(
            events: [event(type: "x", start: date(2026, 6, 3, 8), end: date(2026, 6, 3, 8, 30))],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        XCTAssertEqual(low.perTypeHours.first { $0.type == "x" }?.tier, .low)
        // A single-event window is thin, so even a big new category is capped at
        // medium rather than high.
        XCTAssertTrue(low.window.isThin)
    }

    func testPairRelationTierMatchesThresholds() {
        // Directly exercise the centralized threshold table.
        let high = ReportConfidenceInput(overlapDays: 6, consistency: 1.0, effectSize: 0.7)
        XCTAssertEqual(high.tier, .high)

        let mediumByConsistency = ReportConfidenceInput(overlapDays: 6, consistency: 0, effectSize: 0.7)
        XCTAssertEqual(mediumByConsistency.tier, .medium) // strong but flips → not high

        let medium = ReportConfidenceInput(overlapDays: 3, consistency: 0, effectSize: 0.45)
        XCTAssertEqual(medium.tier, .medium)

        let low = ReportConfidenceInput(overlapDays: 2, consistency: 0, effectSize: 0.3)
        XCTAssertEqual(low.tier, .low)
    }

    // MARK: - Pair correlation on recorded days only

    func testPairCorrelationIgnoresUnrecordedDays() {
        // Four recorded days where "work" rises 1→4h while "gym" falls 4→1h:
        // a perfect r = -1.  The three untracked days at the window's tail must
        // not enter the vectors — their (0, 0) points would flip the sign into
        // a spurious positive co-absence correlation.
        var events: [Event] = []
        for (offset, hours) in [1, 2, 3, 4].enumerated() {
            events.append(event(
                type: "work",
                start: date(2026, 6, 2 + offset, 9),
                end: date(2026, 6, 2 + offset, 9 + hours)
            ))
            events.append(event(
                type: "gym",
                start: date(2026, 6, 2 + offset, 18),
                end: date(2026, 6, 2 + offset, 18 + (5 - hours))
            ))
        }
        let stats = ReportStatsBuilder.build(
            events: events,
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        let pair = stats.typePairRelations.first {
            ($0.typeA == "work" && $0.typeB == "gym") || ($0.typeA == "gym" && $0.typeB == "work")
        }
        XCTAssertNotNil(pair)
        XCTAssertEqual(pair?.correlation ?? 0, -1, accuracy: 0.001)
        XCTAssertEqual(pair?.confidence.overlapDays, 4)
    }

    // MARK: - promptText gating

    func testPromptTextDropsLowTierAndRespectsBudget() {
        // A 1h category sits below the delta noise floor (2h), so its delta is
        // low-tier and must not surface as a CHANGE line.
        let stats = ReportStatsBuilder.build(
            events: [event(type: "reading", start: date(2026, 6, 3, 20), end: date(2026, 6, 3, 21))],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        let text = stats.promptText(budget: 2000)
        XCTAssertTrue(text.contains("WINDOW"))
        XCTAssertTrue(text.contains("CATEGORY reading"))
        XCTAssertFalse(text.contains("CHANGE"))

        // A tiny budget truncates to (at most) the window frame.
        let tiny = stats.promptText(budget: 12)
        XCTAssertTrue(tiny.count <= text.count)
    }

    func testPromptTextPartialAndSparseGates() {
        let stats = ReportStatsBuilder.build(
            events: [event(type: "reading", start: date(2026, 6, 3, 20), end: date(2026, 6, 3, 21))],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        // In-progress windows drop every previous-window comparison.
        let partial = stats.promptText(budget: 2000, includeChanges: false)
        XCTAssertFalse(partial.contains("prev="))
        XCTAssertFalse(partial.contains("CHANGE"))
        XCTAssertTrue(partial.contains("CATEGORY reading: 1.0h"))
        // One recorded day (< 3) suppresses time-of-day percent lines even
        // though the occurrence has segment data.
        XCTAssertFalse(partial.contains("WHEN"))
        XCTAssertFalse(stats.promptText(budget: 2000).contains("WHEN"))
    }

    func testComparisonsRequireCompletedWindowAndPreviousData() {
        // A completed window whose PREVIOUS window is untracked must not
        // compare — prev=0 for every category would narrate fabricated
        // "up by Xh vs previous window" increases (0-tracked ≠ 0-happened).
        let current = event(type: "work", start: date(2026, 6, 3, 9), end: date(2026, 6, 3, 12))
        let noBaseline = ReportStatsBuilder.build(
            events: [current],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        XCTAssertFalse(ReportGenerationService.includeComparisons(stats: noBaseline, isPartial: false))

        let previous = event(type: "work", start: date(2026, 5, 27, 9), end: date(2026, 5, 27, 11))
        let withBaseline = ReportStatsBuilder.build(
            events: [current, previous],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        XCTAssertTrue(ReportGenerationService.includeComparisons(stats: withBaseline, isPartial: false))
        // An in-progress window never compares, baseline or not.
        XCTAssertFalse(ReportGenerationService.includeComparisons(stats: withBaseline, isPartial: true))
    }

    func testTimeOfDaySharesArePerCategoryGated() {
        // "work" appears on 4 distinct days, "reading" on only 1 — even though
        // the window has plenty of recorded days, reading's single-session
        // "morning=100%" share must not survive into the stats.
        var events: [Event] = []
        for offset in 0..<4 {
            events.append(event(
                type: "work",
                start: date(2026, 6, 2 + offset, 9),
                end: date(2026, 6, 2 + offset, 12)
            ))
        }
        events.append(event(type: "reading", start: date(2026, 6, 3, 8), end: date(2026, 6, 3, 9)))

        let stats = ReportStatsBuilder.build(
            events: events,
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        XCTAssertTrue(stats.timeOfDayShares.contains { $0.type == "work" })
        XCTAssertFalse(stats.timeOfDayShares.contains { $0.type == "reading" })
        XCTAssertFalse(stats.promptText(budget: 2000).contains("WHEN reading"))
        XCTAssertTrue(stats.promptText(budget: 2000).contains("WHEN work"))
    }
}
