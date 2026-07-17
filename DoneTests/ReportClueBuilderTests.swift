import XCTest
@testable import Done

/// The daily clue battery (Slice A): typical-day deviation with elapsed
/// clamping, plan-vs-actual overrun, emergence, habitual absence, recording
/// streak — plus code-side selection (tier/effect ranking, novelty
/// suppression, per-family caps) and the daily-thin redefinition.
final class ReportClueBuilderTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    private func event(type: String, start: Date, end: Date) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: type
        )
    }

    /// One `type` event per day over the `days` leading up to (excluding)
    /// `windowStart`, each `hours` long starting at `hour`.
    private func history(
        type: String, days: Int, before windowStart: Date,
        hour: Int, durationHours: Double
    ) -> [Event] {
        (1...days).map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: windowStart)!
            let start = day.addingTimeInterval(TimeInterval(hour) * 3600)
            return event(type: type, start: start, end: start.addingTimeInterval(durationHours * 3600))
        }
    }

    private func build(
        events: [Event],
        logRecords: [CalendarEventLogRecord] = [],
        start: Date, end: Date, asOf: Date,
        priorFingerprints: Set<String> = []
    ) -> ReportClueBuilder.Emission {
        ReportClueBuilder.build(
            events: events, logRecords: logRecords,
            start: start, end: end, asOf: asOf,
            calendar: calendar, priorFingerprints: priorFingerprints
        )
    }

    // Window under test: 2026-06-29 (a Monday), full lookback of daily records.
    private var day: Date { date(2026, 6, 29) }
    private var dayAfter: Date { date(2026, 6, 30) }

    // MARK: - Deviation

    func testDeviationFiresAgainstTypicalDayBaseline() {
        // 28 days × 1.5h of 学习, today 3h → relative 0.5, stable baseline.
        var events = history(type: "学习", days: 28, before: day, hour: 8, durationHours: 1.5)
        events.append(event(type: "学习", start: date(2026, 6, 29, 8), end: date(2026, 6, 29, 11)))
        let emission = build(events: events, start: day, end: dayAfter, asOf: dayAfter)

        let clue = emission.candidates.first { $0.kind == .deviation && $0.type == "学习" }
        XCTAssertNotNil(clue)
        XCTAssertEqual(clue?.direction, "up")
        XCTAssertEqual(clue?.tier, .medium)
        XCTAssertTrue(clue?.line.contains("3.0h") == true)
        XCTAssertTrue(clue?.line.contains("1.5h typical") == true)
    }

    func testDeviationBaselineIsElapsedClamped() {
        // History: 1h every morning (8–9) plus 2h every evening (20–22).
        // Today so far (asOf noon): the same 1h morning session.  Without the
        // clamp the baseline reads 3h and today reads "down" — a fabricated
        // deviation about evening hours that simply haven't happened yet.
        var events = history(type: "学习", days: 28, before: day, hour: 8, durationHours: 1)
        events += history(type: "学习", days: 28, before: day, hour: 20, durationHours: 2)
        events.append(event(type: "学习", start: date(2026, 6, 29, 8), end: date(2026, 6, 29, 9)))
        let emission = build(
            events: events, start: day, end: dayAfter, asOf: date(2026, 6, 29, 12)
        )

        XCTAssertFalse(emission.candidates.contains { $0.kind == .deviation && $0.type == "学习" })
    }

    func testDeviationRespectsNoiseFloor() {
        // 0.2h vs 0.4h is a 50% swing of nothing — below the 1h floor.
        var events = history(type: "摸鱼", days: 28, before: day, hour: 8, durationHours: 0.2)
        events.append(event(type: "摸鱼", start: date(2026, 6, 29, 8), end: date(2026, 6, 29, 8, 24)))
        let emission = build(events: events, start: day, end: dayAfter, asOf: dayAfter)

        XCTAssertFalse(emission.candidates.contains { $0.kind == .deviation && $0.type == "摸鱼" })
    }

    // MARK: - Overrun

    func testOverrunFiresFromLoggedActualDuration() {
        let planned = event(type: "会议", start: date(2026, 6, 29, 9), end: date(2026, 6, 29, 10))
        let log = CalendarEventLogRecord(
            id: CalendarOccurrenceKey.make(for: planned, occurrenceDate: date(2026, 6, 29, 9)),
            eventID: planned.id,
            baseSeriesEventID: nil,
            occurrenceDate: date(2026, 6, 29, 9),
            selectedTemplateID: nil,
            completionStatus: .completed,
            actualDurationMinutes: 120,
            summary: "",
            note: "",
            effort: nil,
            emotions: [],
            behaviors: [],
            templateAnswers: [:],
            timelineItems: []
        )
        let emission = build(
            events: [planned], logRecords: [log],
            start: day, end: dayAfter, asOf: dayAfter
        )

        let clue = emission.candidates.first { $0.kind == .overrun }
        XCTAssertNotNil(clue)
        XCTAssertEqual(clue?.direction, "over")
        XCTAssertEqual(clue?.tier, .medium)   // n == 1 caps at medium
        XCTAssertTrue(clue?.line.contains("+60min") == true)
    }

    // MARK: - Emergence

    func testEmergenceFirstAndReturn() {
        // 骑行 never seen before today → first; 冥想 last seen 20 days ago → return.
        var events: [Event] = [
            event(type: "骑行", start: date(2026, 6, 29, 7), end: date(2026, 6, 29, 8)),
            event(type: "冥想", start: date(2026, 6, 29, 21), end: date(2026, 6, 29, 22)),
        ]
        let twentyBack = calendar.date(byAdding: .day, value: -20, to: day)!
        events.append(event(
            type: "冥想",
            start: twentyBack.addingTimeInterval(8 * 3600),
            end: twentyBack.addingTimeInterval(9 * 3600)
        ))
        // Background records so the days count as recorded.
        events += history(type: "工作", days: 28, before: day, hour: 10, durationHours: 2)
        let emission = build(events: events, start: day, end: dayAfter, asOf: dayAfter)

        let first = emission.candidates.first { $0.kind == .emergence && $0.type == "骑行" }
        XCTAssertEqual(first?.direction, "first")
        let back = emission.candidates.first { $0.kind == .emergence && $0.type == "冥想" }
        XCTAssertEqual(back?.direction, "return")
        XCTAssertTrue(back?.line.contains("20 days") == true)
    }

    // MARK: - Absence

    func testAbsenceOfHabitualCategory() {
        // 运动 on all 28 recorded days, none today (today still recorded via 工作).
        var events = history(type: "运动", days: 28, before: day, hour: 8, durationHours: 1)
        events += history(type: "工作", days: 28, before: day, hour: 10, durationHours: 2)
        events.append(event(type: "工作", start: date(2026, 6, 29, 10), end: date(2026, 6, 29, 12)))
        let emission = build(events: events, start: day, end: dayAfter, asOf: dayAfter)

        let clue = emission.candidates.first { $0.kind == .absence && $0.type == "运动" }
        XCTAssertNotNil(clue)
        XCTAssertEqual(clue?.tier, .high)   // 28/28 recorded days
        XCTAssertTrue(clue?.line.contains("28 of 28") == true)
    }

    func testAbsenceNotClaimedWhenScheduledLaterToday() {
        // 运动 usually in the morning; today's session sits tonight, after the
        // asOf cutoff — "none today" would be false, so no absence clue.
        var events = history(type: "运动", days: 28, before: day, hour: 8, durationHours: 1)
        events += history(type: "工作", days: 28, before: day, hour: 10, durationHours: 2)
        events.append(event(type: "工作", start: date(2026, 6, 29, 10), end: date(2026, 6, 29, 12)))
        events.append(event(type: "运动", start: date(2026, 6, 29, 21), end: date(2026, 6, 29, 22)))
        let emission = build(
            events: events, start: day, end: dayAfter, asOf: date(2026, 6, 29, 15)
        )

        XCTAssertFalse(emission.candidates.contains { $0.kind == .absence && $0.type == "运动" })
    }

    // MARK: - Streak

    func testStreakMilestoneFiresOnTheDayItIsReached() {
        // 6 consecutive recorded days + today recorded = 7, a milestone.
        var events = history(type: "工作", days: 6, before: day, hour: 10, durationHours: 2)
        events.append(event(type: "工作", start: date(2026, 6, 29, 10), end: date(2026, 6, 29, 12)))
        let emission = build(events: events, start: day, end: dayAfter, asOf: dayAfter)

        let clue = emission.candidates.first { $0.kind == .streak }
        XCTAssertEqual(clue?.direction, "milestone-7")
        XCTAssertTrue(clue?.line.contains("7 days in a row") == true)
    }

    func testStreakBreakOnlyOnCompleteWindow() {
        // 5 recorded days then an empty today.
        let events = history(type: "工作", days: 5, before: day, hour: 10, durationHours: 2)

        // Mid-day: saying "the run ended" about a day still underway is
        // fabrication — no break clue.
        let partial = build(events: events, start: day, end: dayAfter, asOf: date(2026, 6, 29, 9))
        XCTAssertFalse(partial.candidates.contains { $0.kind == .streak })

        // Complete window: the break is a fact.
        let complete = build(events: events, start: day, end: dayAfter, asOf: dayAfter)
        let clue = complete.candidates.first { $0.kind == .streak }
        XCTAssertEqual(clue?.direction, "break")
    }

    // MARK: - Selection

    func testNoveltySuppressionDropsAlreadyToldClues() {
        var events = history(type: "学习", days: 28, before: day, hour: 8, durationHours: 1.5)
        events.append(event(type: "学习", start: date(2026, 6, 29, 8), end: date(2026, 6, 29, 11)))

        let firstRun = build(events: events, start: day, end: dayAfter, asOf: dayAfter)
        let told = Set(firstRun.selected.map(\.fingerprint))
        XCTAssertFalse(told.isEmpty)

        let secondRun = build(
            events: events, start: day, end: dayAfter, asOf: dayAfter,
            priorFingerprints: told
        )
        XCTAssertGreaterThan(secondRun.noveltySuppressedCount, 0)
        XCTAssertFalse(secondRun.selected.contains { told.contains($0.fingerprint) })
    }

    func testSelectionCapsPerFamilyAndTotal() {
        // Six habitual categories all absent today → six absence candidates,
        // but at most clueMaxPerKind survive selection.
        var events: [Event] = []
        for type in ["a", "b", "c", "d", "e", "f"] {
            events += history(type: type, days: 28, before: day, hour: 8, durationHours: 1)
        }
        events.append(event(type: "工作", start: date(2026, 6, 29, 10), end: date(2026, 6, 29, 12)))
        let emission = build(events: events, start: day, end: dayAfter, asOf: dayAfter)

        XCTAssertGreaterThanOrEqual(emission.candidates.filter { $0.kind == .absence }.count, 6)
        XCTAssertLessThanOrEqual(
            emission.selected.filter { $0.kind == .absence }.count,
            ReportTuning.clueMaxPerKind
        )
        XCTAssertLessThanOrEqual(emission.selected.count, ReportTuning.clueMaxSelected)
    }

    func testNonDailyWindowSkipsBattery() {
        let events = history(type: "工作", days: 28, before: day, hour: 10, durationHours: 2)
        let emission = build(
            events: events,
            start: date(2026, 6, 22), end: dayAfter, asOf: dayAfter
        )
        XCTAssertTrue(emission.candidates.isEmpty)
        XCTAssertTrue(emission.selected.isEmpty)
    }

    // MARK: - Daily thin redefinition + CLUE serialization

    func testDailyWindowWithRecordsIsNotThin() {
        // Old rule (recordedDays < 4) marked every daily window sparse; the
        // kind-aware rule only calls an EMPTY day thin.
        let recorded = ReportStatsBuilder.build(
            events: [event(type: "工作", start: date(2026, 6, 29, 10), end: date(2026, 6, 29, 12))],
            start: day, end: dayAfter, calendar: calendar
        )
        XCTAssertFalse(recorded.window.isThin)

        let empty = ReportStatsBuilder.build(
            events: [], start: day, end: dayAfter, calendar: calendar
        )
        XCTAssertTrue(empty.window.isThin)
    }

    func testPromptTextEmitsClueLinesAheadOfCategories() {
        let stats = ReportStatsBuilder.build(
            events: [event(type: "工作", start: date(2026, 6, 29, 10), end: date(2026, 6, 29, 12))],
            start: day, end: dayAfter, calendar: calendar
        )
        let clue = ReportClue(
            kind: .deviation, type: "工作", direction: "up",
            tier: .high, effect: 0.7,
            line: "CLUE deviation 工作: 4.0h today vs 1.5h typical (median of 12 recorded days) up [high]"
        )
        let text = stats.promptText(budget: 2000, clues: [clue])
        let clueIndex = text.range(of: "CLUE deviation")!.lowerBound
        let categoryIndex = text.range(of: "CATEGORY 工作")!.lowerBound
        XCTAssertLessThan(clueIndex, categoryIndex)
    }

    // MARK: - Lookback cost smoke

    // The panel flagged the trailing-window aggregation cost as a
    // measure-before-tuning item.  Simulator numbers overstate a phone, but
    // the magnitude is what matters: 28-day lookback over a busy log must be
    // milliseconds, not seconds (it runs on every generation, off-main).
    func testLookbackPerformanceSmoke() {
        var events: [Event] = []
        for (index, type) in ["工作", "学习", "运动", "阅读", "杂务", "冥想"].enumerated() {
            events += history(type: type, days: 28, before: day, hour: 7 + index * 2, durationHours: 1.5)
        }
        events.append(event(type: "工作", start: date(2026, 6, 29, 10), end: date(2026, 6, 29, 12)))
        measure {
            _ = build(events: events, start: day, end: dayAfter, asOf: date(2026, 6, 29, 15))
        }
    }

    // MARK: - Store schema v2

    func testStoreReadsV1AndV2Reports() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportClueBuilderTests-\(UUID().uuidString)", isDirectory: true)
        let store = ReportStore(directoryURL: dir)

        let stats = ReportStatsBuilder.build(events: [], start: day, end: dayAfter, calendar: calendar)
        let v1 = Report(
            id: UUID(), createdAt: day, periodStart: day, periodEnd: dayAfter,
            prose: "old", statsSnapshot: stats, providerModel: "m",
            comparedToPreviousWindow: nil, userNote: nil,
            clues: nil, candidateFingerprints: nil, noveltySuppressedCount: nil,
            historyStart: nil, ownerRating: nil,
            schemaVersion: 1
        )
        try store.save(v1)
        var v2 = v1
        v2.id = UUID()
        v2.prose = "new"
        v2.clues = [ReportClue(kind: .streak, type: "", direction: "milestone-7", tier: .medium, effect: 7, line: "CLUE streak: 7 days in a row with records [medium]")]
        v2.ownerRating = 4
        v2.schemaVersion = Report.currentSchemaVersion
        try store.save(v2)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains { $0.prose == "old" })
        XCTAssertEqual(loaded.first { $0.prose == "new" }?.ownerRating, 4)
        XCTAssertEqual(loaded.first { $0.prose == "new" }?.clues?.first?.fingerprint, "streak||milestone-7")
    }
}
