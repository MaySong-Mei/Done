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
        typeWeights: [String: Double]? = nil,
        kind: Event.Kind = .event,
        isDone: Bool = false
    ) -> Event {
        Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            isDone: isDone,
            type: type,
            kind: kind,
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

    func testPromptEventsChronologyWindowAndBudget() {
        var late = event(type: "work", start: date(2026, 6, 3, 14), end: date(2026, 6, 3, 16))
        late.title = "写周报"
        var early = event(type: "gym", start: date(2026, 6, 3, 7), end: date(2026, 6, 3, 8))
        early.title = "晨跑"
        early.note = "腿有点酸\n但完成了"
        let outside = event(type: "gym", start: date(2026, 5, 1, 7), end: date(2026, 5, 1, 8))

        let block = ReportStatsBuilder.promptEvents(
            events: [late, early, outside],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 2000
        ).text
        let lines = block.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2) // window filters the May event out
        XCTAssertTrue(lines[0].contains("晨跑"))            // chronological
        XCTAssertTrue(lines[0].contains("腿有点酸 但完成了")) // note flattened to one line
        XCTAssertTrue(lines[1].contains("写周报"))
        XCTAssertTrue(lines[0].contains("[gym]"))

        // Budget exhaustion drops the tail and says so — never silently.
        let tiny = ReportStatsBuilder.promptEvents(
            events: [late, early],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 20
        ).text
        XCTAssertTrue(tiny.contains("omitted"))

        // Zero budget (the on-device tier) produces no block at all.
        XCTAssertEqual(ReportStatsBuilder.promptEvents(
            events: [late], start: date(2026, 6, 2), end: date(2026, 6, 9),
            calendar: calendar, budget: 0
        ).text, "")
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

    // MARK: - In-the-event records → sub-lines

    // Builds the log record the way the app does, so the builder's
    // `CalendarOccurrenceKey.make`-based match lands on this occurrence.
    private func logRecord(
        for event: Event,
        completionStatus: EventLogCompletionStatus? = nil,
        durationMinutes: Int? = nil,
        effort: Int? = nil,
        emotions: [String] = [],
        behaviors: [String] = [],
        summary: String = "",
        note: String = "",
        selectedTemplateID: String? = nil,
        templateAnswers: [String: EventLogAnswerValue] = [:],
        timelineItems: [EventLogTimelineItem] = []
    ) -> CalendarEventLogRecord {
        let anchor = event.primaryTimeRange?.start ?? Date()
        return CalendarEventLogRecord(
            id: CalendarOccurrenceKey.make(for: event, occurrenceDate: anchor),
            eventID: event.id,
            baseSeriesEventID: event.recurrenceParentId ?? (event.isRecurringSeries ? event.id : nil),
            occurrenceDate: anchor,
            selectedTemplateID: selectedTemplateID,
            completionStatus: completionStatus,
            actualDurationMinutes: durationMinutes,
            summary: summary,
            note: note,
            effort: effort,
            emotions: emotions,
            behaviors: behaviors,
            templateAnswers: templateAnswers,
            timelineItems: timelineItems
        )
    }

    private func feedbackRecord(
        for event: Event,
        effort: Int? = nil,
        emotions: [String] = [],
        behaviors: [String] = [],
        selfNote: String = "",
        logs: [CalendarEventLogEntry] = []
    ) -> CalendarEventFeedbackRecord {
        let anchor = event.primaryTimeRange?.start ?? Date()
        return CalendarEventFeedbackRecord(
            id: CalendarOccurrenceKey.make(for: event, occurrenceDate: anchor),
            eventID: event.id,
            baseSeriesEventID: event.recurrenceParentId ?? (event.isRecurringSeries ? event.id : nil),
            occurrenceDate: anchor,
            effort: effort,
            emotions: emotions,
            behaviors: behaviors,
            selfNote: selfNote,
            logs: logs
        )
    }

    func testPromptEventsLogRecordProducesSubLines() {
        var e = event(type: "work", start: date(2026, 6, 3, 9), end: date(2026, 6, 3, 12))
        e.title = "写报告系统"
        let log = logRecord(
            for: e,
            completionStatus: .completed,
            durationMinutes: 55,
            effort: 4,
            emotions: ["focused", "tired"],
            summary: "打通了记录序列化",
            note: "还差\n测试",
            selectedTemplateID: EventLogTemplateID.deepWork.rawValue,
            templateAnswers: ["focusQuality": .int(4), "outcome": .string("shipped")],
            timelineItems: [
                .note(EventLogTimelineNote(
                    text: "卡在 key 匹配",
                    source: "test",
                    images: [AgenticIntakeImageRef(relativePath: "img/1.jpg", pixelWidth: 100, pixelHeight: 100, fileSizeBytes: 1000)]
                ))
            ]
        )
        let block = ReportStatsBuilder.promptEvents(
            events: [e],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 2000,
            logRecords: [log]
        ).text
        XCTAssertTrue(block.contains("EVENT"))
        // LOG sub-line carries status / duration / effort / emotions / text.
        XCTAssertTrue(block.contains("  LOG completed 55min effort 4/5 [focused,tired]"))
        XCTAssertTrue(block.contains("打通了记录序列化 — 还差 测试")) // summary — note, flattened
        // Template answers: rating shown n/5, option id translated to its title.
        XCTAssertTrue(block.contains("Focus Quality=4/5"))
        XCTAssertTrue(block.contains("Outcome=Shipped"))
        // Timeline note text with a photo marker (image body never sent).
        XCTAssertTrue(block.contains("NOTE 卡在 key 匹配 [photo]"))
    }

    func testPromptEventsFeedbackProducesFeltSubLine() {
        var e = event(type: "gym", start: date(2026, 6, 4, 7), end: date(2026, 6, 4, 8))
        e.title = "晨跑"
        let feedback = feedbackRecord(
            for: e,
            effort: 3,
            emotions: ["stressed"],
            selfNote: "腿很沉\n但坚持了",
            logs: [CalendarEventLogEntry(text: "配速慢了点", source: "test")]
        )
        let block = ReportStatsBuilder.promptEvents(
            events: [e],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 2000,
            feedbackRecords: [feedback]
        ).text
        XCTAssertTrue(block.contains("  FELT effort 3/5 [stressed] — 腿很沉 但坚持了"))
        XCTAssertTrue(block.contains("  NOTE 配速慢了点"))
    }

    func testPromptEventsOccurrenceWithoutRecordHasNoSubLines() {
        var e = event(type: "work", start: date(2026, 6, 3, 9), end: date(2026, 6, 3, 12))
        e.title = "无记录事件"
        let block = ReportStatsBuilder.promptEvents(
            events: [e],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 2000
        ).text
        let lines = block.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1)            // header only
        XCTAssertTrue(lines[0].hasPrefix("EVENT"))
        XCTAssertFalse(block.contains("LOG"))
        XCTAssertFalse(block.contains("FELT"))
    }

    func testPromptEventsRecordedRecurringOccurrenceEscapesCollapse() {
        // Align the key's reference tz with the test's UTC calendar so the
        // recurring occurrence's dayKey matches the record we build.
        CalendarOccurrenceKey.referenceTimeZoneOverride = TimeZone(identifier: "UTC")
        defer { CalendarOccurrenceKey.referenceTimeZoneOverride = nil }

        // Daily 09:00–10:00 series over the window; a record on ONE day.
        var series = Event(
            title: "每日站会",
            timeRanges: [Event.TimeRange(start: date(2026, 6, 2, 9), end: date(2026, 6, 2, 10))],
            repeatUnit: .day,
            type: "work"
        )
        series.title = "每日站会"
        XCTAssertTrue(series.isRecurringSeries)

        // Record attached to the Jun 4 occurrence.
        let recordedDay = date(2026, 6, 4, 9)
        let log = CalendarEventLogRecord(
            id: CalendarOccurrenceKey.make(for: series, occurrenceDate: recordedDay),
            eventID: series.id,
            baseSeriesEventID: series.id,
            occurrenceDate: recordedDay,
            summary: "定了排期",
            effort: 3
        )

        let block = ReportStatsBuilder.promptEvents(
            events: [series],
            start: date(2026, 6, 2),
            end: date(2026, 6, 6),   // Jun 2,3,4,5 → 4 occurrences, 1 recorded
            calendar: calendar,
            budget: 4000,
            logRecords: [log]
        ).text
        // The recorded occurrence surfaces on its own with the LOG sub-line…
        XCTAssertTrue(block.contains("  LOG effort 3/5 定了排期"))
        // …and is NOT swept into the collapse count (3 recordless, not 4).
        XCTAssertTrue(block.contains("(recurring, ×3 this period)"))
        XCTAssertFalse(block.contains("(recurring, ×4 this period)"))
    }

    // MARK: - Photo attachment (vision path)

    private func imageRef(_ path: String) -> AgenticIntakeImageRef {
        AgenticIntakeImageRef(relativePath: path, pixelWidth: 10, pixelHeight: 10, fileSizeBytes: 1)
    }

    func testPromptEventsAttachedPhotosGetIndexedMarkersInTimeOrder() {
        let img1 = imageRef("a/1.jpg")
        let img2 = imageRef("b/2.jpg")

        // Two record-bearing occurrences, each with one attachable photo.
        var early = event(type: "meal", start: date(2026, 6, 3, 8), end: date(2026, 6, 3, 9))
        early.title = "早餐"
        let earlyLog = logRecord(for: early, timelineItems: [
            .note(EventLogTimelineNote(text: "燕麦", source: "test", images: [img1]))
        ])
        var late = event(type: "meal", start: date(2026, 6, 3, 12), end: date(2026, 6, 3, 13))
        late.title = "午餐"
        let lateLog = logRecord(for: late, timelineItems: [
            .note(EventLogTimelineNote(text: "沙拉", source: "test", images: [img2]))
        ])

        // Events passed out of order to prove the serializer sorts by time.
        let block = ReportStatsBuilder.promptEvents(
            events: [late, early],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 4000,
            logRecords: [lateLog, earlyLog],
            attachableImageIDs: [img1.id, img2.id]
        )
        // Markers numbered in occurrence time order.
        XCTAssertTrue(block.text.contains("NOTE 燕麦 [photo #1]"))
        XCTAssertTrue(block.text.contains("NOTE 沙拉 [photo #2]"))
        // Refs collected in the same order → array position k-1 is [photo #k].
        XCTAssertEqual(block.attachedImageRefs.map { $0.id }, [img1.id, img2.id])
    }

    func testPromptEventsPhotosBeyondCapFallBackToPlainMarker() {
        // 13 attachable photos on one note; the cap is 12 → the first 12 are
        // numbered and attached, the 13th keeps a plain, index-less marker and
        // never enters the array.
        let refs = (0..<13).map { imageRef("c/\($0).jpg") }
        var e = event(type: "trip", start: date(2026, 6, 3, 9), end: date(2026, 6, 3, 12))
        e.title = "出游"
        let log = logRecord(for: e, timelineItems: [
            .note(EventLogTimelineNote(text: "风景", source: "test", images: refs))
        ])
        let block = ReportStatsBuilder.promptEvents(
            events: [e],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 8000,
            logRecords: [log],
            attachableImageIDs: Set(refs.map { $0.id })
        )
        XCTAssertEqual(block.attachedImageRefs.count, ReportTuning.maxReportPhotos)
        XCTAssertEqual(block.attachedImageRefs.map { $0.id }, refs.prefix(12).map { $0.id })
        XCTAssertTrue(block.text.contains("[photo #12]"))
        XCTAssertFalse(block.text.contains("[photo #13]"))
        // The 13th folds into a single trailing plain marker ("[photo]" is not
        // a substring of any "[photo #k]", so this matches only the overflow).
        XCTAssertTrue(block.text.contains("[photo]"))
    }

    func testPromptEventsNoAttachKeepsIndexlessMarkersAndEmptyRefs() {
        // Empty attachableImageIDs (the default) = the pre-vision behaviour:
        // nothing travels and the marker stays index-less.
        let img = imageRef("d/1.jpg")
        var e = event(type: "meal", start: date(2026, 6, 3, 8), end: date(2026, 6, 3, 9))
        e.title = "早餐"
        let log = logRecord(for: e, timelineItems: [
            .note(EventLogTimelineNote(text: "燕麦", source: "test", images: [img]))
        ])
        let block = ReportStatsBuilder.promptEvents(
            events: [e],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 4000,
            logRecords: [log]
        )
        XCTAssertTrue(block.attachedImageRefs.isEmpty)
        XCTAssertTrue(block.text.contains("NOTE 燕麦 [photo]"))
        XCTAssertFalse(block.text.contains("#1"))
    }

    // MARK: - Memory: prior-report selection

    // A stored report over `[start, end)`.  The stats snapshot is a throwaway
    // (selection only reads period + createdAt + kind), reused across reports.
    private func makeReport(
        start: Date,
        end: Date,
        createdAt: Date,
        prose: String = "prior prose",
        userNote: String? = nil,
        stats: ReportStats? = nil
    ) -> Report {
        let snapshot = stats ?? ReportStatsBuilder.build(
            events: [event(type: "work", start: date(2026, 6, 3, 9), end: date(2026, 6, 3, 12))],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar
        )
        return Report(
            id: UUID(),
            createdAt: createdAt,
            periodStart: start,
            periodEnd: end,
            prose: prose,
            statsSnapshot: snapshot,
            providerModel: "test-model",
            comparedToPreviousWindow: false,
            userNote: userNote,
            schemaVersion: Report.currentSchemaVersion
        )
    }

    func testSelectPriorReportsPrefersAdjacentPeriodOverRecentRegeneration() {
        // A months-old window regenerated just now (newest createdAt) must not
        // outrank the period that actually precedes this report — memory wants
        // period adjacency, createdAt only breaks ties.
        let adjacent = makeReport(
            start: date(2026, 6, 22), end: date(2026, 6, 29),
            createdAt: date(2026, 6, 29, 8)
        )
        let oldRegenerated = makeReport(
            start: date(2026, 3, 2), end: date(2026, 3, 9),
            createdAt: date(2026, 7, 1, 12) // regenerated much later
        )
        let picked = ReportGenerationService.selectPriorReports(
            from: [oldRegenerated, adjacent],
            start: date(2026, 6, 29),
            end: date(2026, 7, 6),
            calendar: calendar
        )
        XCTAssertEqual(picked.first?.periodStart, date(2026, 6, 22))
    }

    func testSelectPriorReportsSameKindEarlierNewestTwo() {
        // Current window: a 7-day (weekly) window opening Jun 8.
        let start = date(2026, 6, 8)
        let end = date(2026, 6, 15)

        // Three weekly reports that closed on/before the window opens, newest
        // first by createdAt: A (ends exactly at start), B, then C.
        let weeklyA = makeReport(start: date(2026, 6, 1), end: date(2026, 6, 8), createdAt: date(2026, 6, 15))
        let weeklyB = makeReport(start: date(2026, 5, 25), end: date(2026, 6, 1), createdAt: date(2026, 6, 8))
        let weeklyC = makeReport(start: date(2026, 5, 18), end: date(2026, 5, 25), createdAt: date(2026, 6, 1))
        // A daily report over the day before — different kind, excluded.
        let daily = makeReport(start: date(2026, 6, 7), end: date(2026, 6, 8), createdAt: date(2026, 6, 14))
        // A same-period regeneration — periodEnd == end > start, excluded.
        let sameWindow = makeReport(start: date(2026, 6, 8), end: date(2026, 6, 15), createdAt: date(2026, 6, 16))
        // A weekly ending AFTER the window opens — not strictly earlier, excluded.
        let overlapping = makeReport(start: date(2026, 6, 9), end: date(2026, 6, 16), createdAt: date(2026, 6, 16))

        let selected = ReportGenerationService.selectPriorReports(
            from: [weeklyC, weeklyA, daily, sameWindow, overlapping, weeklyB],
            start: start,
            end: end,
            calendar: calendar
        )

        // Newest two same-kind, earlier reports, newest first: A then B.
        XCTAssertEqual(selected.map { $0.id }, [weeklyA.id, weeklyB.id])
        XCTAssertFalse(selected.contains { $0.id == weeklyC.id })      // beyond the newest-2 cap
        XCTAssertFalse(selected.contains { $0.id == daily.id })         // different kind
        XCTAssertFalse(selected.contains { $0.id == sameWindow.id })    // same-period regen
        XCTAssertFalse(selected.contains { $0.id == overlapping.id })   // ends after start
    }

    // MARK: - Memory: PRIOR DATA spine (includeCategories:false)

    func testPromptTextSpineDropsCategoriesKeepsRelationAndWhen() {
        // Four recorded days where "work" rises 1→4h while "gym" falls 4→1h,
        // each type on all four days: yields a RELATION pair and WHEN lines for
        // both, plus CATEGORY lines in the full serialization.
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

        // Full serialization carries CATEGORY, RELATION, and WHEN.
        let full = stats.promptText(budget: 4000)
        XCTAssertTrue(full.contains("CATEGORY"))
        XCTAssertTrue(full.contains("RELATION"))
        XCTAssertTrue(full.contains("WHEN"))

        // The spine drops CATEGORY entirely but keeps the cross-window material
        // (RELATION / WHEN) that this window's own DATA can't re-express.
        let spine = stats.promptText(budget: 4000, includeChanges: true, includeCategories: false)
        XCTAssertFalse(spine.contains("CATEGORY"))
        XCTAssertTrue(spine.contains("WINDOW"))
        XCTAssertTrue(spine.contains("RELATION"))
        XCTAssertTrue(spine.contains("WHEN"))
    }

    // MARK: - Memory: block assembly + truncation priority

    func testMemoryBlockUserNotesSurviveWhileProseIsCut() {
        // Two prior reports, each with a short note and a long, distinctive prose
        // body.  Distinct CJK fill so the prose marker can't collide with the
        // fence, headers, or notes.
        let proseA = String(repeating: "阿", count: 400)
        let proseB = String(repeating: "波", count: 400)
        let reportA = makeReport(
            start: date(2026, 6, 1), end: date(2026, 6, 8), createdAt: date(2026, 6, 8),
            prose: proseA, userNote: "记得少排会议"
        )
        let reportB = makeReport(
            start: date(2026, 5, 25), end: date(2026, 6, 1), createdAt: date(2026, 6, 1),
            prose: proseB, userNote: "多睡觉"
        )

        // A tight budget can't hold the long prose, so it must be cut — but both
        // USER NOTES survive (the product red line) and the cut is announced.
        let tight = ReportGenerationService.memoryBlock(priorReports: [reportA, reportB], budget: 400, calendar: calendar)
        XCTAssertTrue(tight.contains("记得少排会议"))
        XCTAssertTrue(tight.contains("多睡觉"))
        XCTAssertFalse(tight.contains("阿阿阿"))
        XCTAssertFalse(tight.contains("波波波"))
        XCTAssertTrue(tight.contains("omitted"))     // truncation never silent

        // A generous budget keeps the prose — proves the block isn't always cutting.
        let roomy = ReportGenerationService.memoryBlock(priorReports: [reportA, reportB], budget: 5000, calendar: calendar)
        XCTAssertTrue(roomy.contains("阿阿阿"))
        XCTAssertTrue(roomy.contains("波波波"))
        XCTAssertTrue(roomy.contains("USER NOTES"))
        XCTAssertTrue(roomy.contains("PRIOR REPORTS"))

        // No prior reports (or the AFM budget-0 tier) → no memory at all.
        XCTAssertEqual(ReportGenerationService.memoryBlock(priorReports: [], budget: 5000, calendar: calendar), "")
        XCTAssertEqual(ReportGenerationService.memoryBlock(priorReports: [reportA], budget: 0, calendar: calendar), "")
    }

    // MARK: - Backfill awareness (edit-awareness trigger)

    func testBackfilledSinceCountsOnlyLateCreatedInWindow() {
        let after = date(2026, 6, 10, 12)   // the spine report's createdAt

        // Created AFTER `after`, inside the window → counts (2h gross overlap).
        var late = event(type: "work", start: date(2026, 6, 4, 9), end: date(2026, 6, 4, 11))
        late.createdAt = date(2026, 6, 12, 8)

        // Created BEFORE `after`, inside the window → excluded (it was already
        // there when the spine report was written).
        var early = event(type: "work", start: date(2026, 6, 5, 9), end: date(2026, 6, 5, 12))
        early.createdAt = date(2026, 6, 6, 8)

        // Created after `after` but OUTSIDE the window → excluded.
        var outside = event(type: "work", start: date(2026, 6, 20, 9), end: date(2026, 6, 20, 12))
        outside.createdAt = date(2026, 6, 12, 8)

        let result = ReportStatsBuilder.backfilledSince(
            events: [late, early, outside],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            after: after,
            calendar: calendar
        )
        XCTAssertEqual(result.occurrences, 1)              // only `late`
        XCTAssertEqual(result.hours, 2, accuracy: 0.001)   // gross overlap
    }

    func testBackfilledSinceIsGrossAndClampsToWindow() {
        let after = date(2026, 6, 1)

        // A multi-type weighted event fully inside: gross hours ignore the weight
        // split (backfill is a trigger, not a displayed number) → the full 4h.
        var weighted = event(
            type: "work", start: date(2026, 6, 3, 9), end: date(2026, 6, 3, 13),
            additionalTypes: ["study"], typeWeights: ["work": 3, "study": 1]
        )
        weighted.createdAt = date(2026, 6, 5)

        // An occurrence straddling the window's start: only the in-window overlap
        // (2h of the 4h) is counted.
        var straddling = event(type: "gym", start: date(2026, 6, 1, 22), end: date(2026, 6, 2, 2))
        straddling.createdAt = date(2026, 6, 5)

        let result = ReportStatsBuilder.backfilledSince(
            events: [weighted, straddling],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            after: after,
            calendar: calendar
        )
        XCTAssertEqual(result.occurrences, 2)
        XCTAssertEqual(result.hours, 6, accuracy: 0.001)   // 4h (unsplit) + 2h (clamped)
    }

    func testShouldMentionBackfillGatesAndThresholds() {
        // A spine whose FROZEN snapshot was thin (a single-event window).
        let thinStats = ReportStatsBuilder.build(
            events: [event(type: "work", start: date(2026, 6, 3, 9), end: date(2026, 6, 3, 12))],
            start: date(2026, 6, 2), end: date(2026, 6, 9), calendar: calendar
        )
        XCTAssertTrue(thinStats.window.isThin)
        let thinSpine = makeReport(
            start: date(2026, 6, 2), end: date(2026, 6, 9),
            createdAt: date(2026, 6, 9), stats: thinStats
        )

        // A spine whose frozen snapshot was NOT thin (two events on each of six
        // days clears both thin floors).
        var fullEvents: [Event] = []
        for offset in 0..<6 {
            for h in [9, 14] {
                fullEvents.append(event(
                    type: "work",
                    start: date(2026, 6, 2 + offset, h),
                    end: date(2026, 6, 2 + offset, h + 2)
                ))
            }
        }
        let fullStats = ReportStatsBuilder.build(
            events: fullEvents, start: date(2026, 6, 2), end: date(2026, 6, 9), calendar: calendar
        )
        XCTAssertFalse(fullStats.window.isThin)
        let fullSpine = makeReport(
            start: date(2026, 6, 2), end: date(2026, 6, 9),
            createdAt: date(2026, 6, 9), stats: fullStats
        )

        let overHours = (hours: 1.5, occurrences: 1)       // clears the hours floor
        let overCount = (hours: 0.0, occurrences: 2)       // clears the occurrences floor
        let underBoth = (hours: 0.5, occurrences: 1)       // under both floors

        // Thin spine + complete window + enough backfill (either floor) → fires.
        XCTAssertTrue(ReportGenerationService.shouldMentionBackfill(spine: thinSpine, isPartial: false, backfill: overHours))
        XCTAssertTrue(ReportGenerationService.shouldMentionBackfill(spine: thinSpine, isPartial: false, backfill: overCount))
        // Under both floors → no.
        XCTAssertFalse(ReportGenerationService.shouldMentionBackfill(spine: thinSpine, isPartial: false, backfill: underBoth))
        // Partial window → no, even with plenty of backfill.
        XCTAssertFalse(ReportGenerationService.shouldMentionBackfill(spine: thinSpine, isPartial: true, backfill: overHours))
        // Spine snapshot was NOT thin → no (backfilling a full ledger isn't warm).
        XCTAssertFalse(ReportGenerationService.shouldMentionBackfill(spine: fullSpine, isPartial: false, backfill: overHours))
    }

    func testSelectPriorReportsDedupesRegeneratedPeriods() {
        // Two regenerations of week A share a period; only the newest survives,
        // and the genuinely preceding week keeps its memory slot.
        let weekAv1 = makeReport(start: date(2026, 6, 22), end: date(2026, 6, 29), createdAt: date(2026, 6, 29, 8))
        let weekAv2 = makeReport(start: date(2026, 6, 22), end: date(2026, 6, 29), createdAt: date(2026, 7, 2, 10))
        let weekBefore = makeReport(start: date(2026, 6, 15), end: date(2026, 6, 22), createdAt: date(2026, 6, 22, 9))
        let picked = ReportGenerationService.selectPriorReports(
            from: [weekAv1, weekAv2, weekBefore],
            start: date(2026, 6, 29), end: date(2026, 7, 6), calendar: calendar
        )
        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(picked[0].createdAt, date(2026, 7, 2, 10))
        XCTAssertEqual(picked[1].periodStart, date(2026, 6, 15))
    }

    func testSpineHonorsSpineComparisonDecision() {
        // A spine whose own report suppressed comparisons (empty baseline) must
        // not have its fabricated CHANGE lines resurrected into PRIOR DATA; a
        // spine that genuinely compared keeps them.
        var suppressed = makeReport(start: date(2026, 6, 1), end: date(2026, 6, 8), createdAt: date(2026, 6, 8))
        suppressed.comparedToPreviousWindow = false
        let blocked = ReportGenerationService.memoryBlock(
            priorReports: [suppressed], budget: 5000, calendar: calendar
        )
        XCTAssertFalse(blocked.contains("CHANGE "))

        var compared = suppressed
        compared.comparedToPreviousWindow = true
        let allowed = ReportGenerationService.memoryBlock(
            priorReports: [compared], budget: 5000, calendar: calendar
        )
        XCTAssertTrue(allowed.contains("CHANGE "))
    }

    func testMemoryBlockBackfillHintPlacementAndConstraints() {
        let report = makeReport(
            start: date(2026, 6, 1), end: date(2026, 6, 8), createdAt: date(2026, 6, 8),
            prose: "prior prose", userNote: "少排会议"
        )

        // priorWindowFuller: true → the hint line is present, AFTER USER NOTES and
        // BEFORE PRIOR DATA.
        let withHint = ReportGenerationService.memoryBlock(
            priorReports: [report], budget: 5000, calendar: calendar, priorWindowFuller: true
        )
        XCTAssertTrue(withHint.contains("PRIOR WINDOW UPDATE"))
        // Anchor on the section HEADERS, not bare substrings: the fence itself
        // mentions "USER NOTES" and "PRIOR DATA", so those alone would match the
        // fence instead of the sections whose order we are asserting.
        guard let notesRange = withHint.range(of: "USER NOTES (this person's own words"),
              let hintRange = withHint.range(of: "PRIOR WINDOW UPDATE"),
              let dataRange = withHint.range(of: "PRIOR DATA (frozen when") else {
            return XCTFail("memory block missing USER NOTES / hint / PRIOR DATA")
        }
        XCTAssertTrue(notesRange.lowerBound < hintRange.lowerBound)  // after USER NOTES
        XCTAssertTrue(hintRange.lowerBound < dataRange.lowerBound)   // before PRIOR DATA

        // The hint carries the spine's [period label] anchor (dates are period
        // identification, not figures); outside that label it names no number,
        // no `→`, and none of the forbidden edit words — asserted literally.
        let hintLine = withHint
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("PRIOR WINDOW UPDATE") } ?? ""
        XCTAssertFalse(hintLine.contains("→"))
        for banned in ["edit", "add", "delet"] {
            XCTAssertFalse(hintLine.lowercased().contains(banned), "hint must not contain \"\(banned)\"")
        }
        XCTAssertTrue(hintLine.contains("["), "hint should carry a [period label] anchor")
        let afterLabel = hintLine.components(separatedBy: "]").dropFirst().joined(separator: "]")
        XCTAssertFalse(afterLabel.isEmpty)
        XCTAssertNil(afterLabel.rangeOfCharacter(from: .decimalDigits), "hint outside the label must contain no digits")

        // priorWindowFuller: false (the default) → no hint line at all.
        let noHint = ReportGenerationService.memoryBlock(
            priorReports: [report], budget: 5000, calendar: calendar
        )
        XCTAssertFalse(noHint.contains("PRIOR WINDOW UPDATE"))
    }

    // MARK: - Todo lines are tasks, not time records

    func testPromptEventsTodoLinesMarkedAsTaskNotEvent() {
        // Chronological: an open todo (Jun 3), a done todo (Jun 4), then a plain
        // event (Jun 5).  Titles set distinctly so lines are unambiguous.
        var openTodo = event(type: "chores", start: date(2026, 6, 3, 9), end: date(2026, 6, 3, 10),
                             kind: .todo, isDone: false)
        openTodo.title = "报税"
        var doneTodo = event(type: "chores", start: date(2026, 6, 4, 9), end: date(2026, 6, 4, 10),
                             kind: .todo, isDone: true)
        doneTodo.title = "交房租"
        var plainEvent = event(type: "work", start: date(2026, 6, 5, 9), end: date(2026, 6, 5, 12))
        plainEvent.title = "开会"

        let block = ReportStatsBuilder.promptEvents(
            events: [openTodo, doneTodo, plainEvent],
            start: date(2026, 6, 2),
            end: date(2026, 6, 9),
            calendar: calendar,
            budget: 2000
        ).text
        let lines = block.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)

        // Open todo: TODO prefix + (open), never EVENT.
        XCTAssertTrue(lines[0].hasPrefix("TODO"))
        XCTAssertTrue(lines[0].contains("(open)"))
        XCTAssertFalse(lines[0].contains("(done)"))
        XCTAssertFalse(lines[0].contains("EVENT"))
        XCTAssertTrue(lines[0].contains("报税"))
        XCTAssertTrue(lines[0].contains("[chores]"))   // time range still emitted

        // Done todo: TODO prefix + (done).
        XCTAssertTrue(lines[1].hasPrefix("TODO"))
        XCTAssertTrue(lines[1].contains("(done)"))
        XCTAssertFalse(lines[1].contains("(open)"))
        XCTAssertTrue(lines[1].contains("交房租"))

        // Plain event unchanged: EVENT prefix, no completion marker.
        XCTAssertTrue(lines[2].hasPrefix("EVENT"))
        XCTAssertFalse(lines[2].contains("(open)"))
        XCTAssertFalse(lines[2].contains("(done)"))
        XCTAssertTrue(lines[2].contains("开会"))
    }

    // MARK: - Partial-window progress phrase

    func testPartialProgressReportsDayNumberWeekdayAndPosition() {
        let start = date(2026, 6, 2)   // Tuesday
        let end = date(2026, 6, 9)     // 7-day window

        // Day 1 (Jun 2, a Tuesday) — early in the period.
        let d1 = ReportGenerationService.partialProgress(
            createdAt: date(2026, 6, 2, 15), start: start, end: end, calendar: calendar
        )
        XCTAssertTrue(d1.contains("day 1 of 7"))
        XCTAssertTrue(d1.contains("Tuesday"))
        XCTAssertTrue(d1.contains("early in the period"))

        // Middle day (Jun 5, a Friday) — mid-period.
        let d4 = ReportGenerationService.partialProgress(
            createdAt: date(2026, 6, 5, 10), start: start, end: end, calendar: calendar
        )
        XCTAssertTrue(d4.contains("day 4 of 7"))
        XCTAssertTrue(d4.contains("Friday"))
        XCTAssertTrue(d4.contains("mid-period"))

        // Last day (Jun 8, a Monday) — final day of the window.
        let d7 = ReportGenerationService.partialProgress(
            createdAt: date(2026, 6, 8, 23), start: start, end: end, calendar: calendar
        )
        XCTAssertTrue(d7.contains("day 7 of 7"))
        XCTAssertTrue(d7.contains("Monday"))
        XCTAssertTrue(d7.contains("final day"))
    }

    // MARK: - Overlap sharing (#116 parity with the Analysis charts)

    func testOverlappingEventsShareHoursInTotalsAndCategories() {
        // Two fully-overlapping 2h events: each category credits half, and the
        // day total equals union coverage (2h, not 4h) — the same accounting
        // AnalysisOverlapSharingTests pins for the charts.
        let events = [
            event(type: "work", start: date(2026, 6, 1, 8), end: date(2026, 6, 1, 10)),
            event(type: "study", start: date(2026, 6, 1, 8), end: date(2026, 6, 1, 10)),
        ]
        let stats = ReportStatsBuilder.build(
            events: events, start: date(2026, 6, 1), end: date(2026, 6, 2), calendar: calendar
        )

        XCTAssertEqual(stats.perTypeHours.first { $0.type == "work" }?.hours ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(stats.perTypeHours.first { $0.type == "study" }?.hours ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(stats.dailyTotals.reduce(0) { $0 + $1.hours }, 2.0, accuracy: 0.0001)
    }

    func testPartialOverlapSharesOnlyTheSharedWindow() {
        // a 8–10, b 9–11: 8–9 a alone, 9–10 half each, 10–11 b alone.
        let events = [
            event(type: "a", start: date(2026, 6, 1, 8), end: date(2026, 6, 1, 10)),
            event(type: "b", start: date(2026, 6, 1, 9), end: date(2026, 6, 1, 11)),
        ]
        let stats = ReportStatsBuilder.build(
            events: events, start: date(2026, 6, 1), end: date(2026, 6, 2), calendar: calendar
        )

        XCTAssertEqual(stats.perTypeHours.first { $0.type == "a" }?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(stats.perTypeHours.first { $0.type == "b" }?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(stats.dailyTotals.reduce(0) { $0 + $1.hours }, 3.0, accuracy: 0.0001)
    }

    func testEmbeddedInterruptChildStaysNetNotOverlapShared() {
        // The parent excludes its embedded child's window (NET) before the
        // overlap pass, so the pair never reads as an overlap: parent 1.5h,
        // child 0.5h, total conserved at 2h.
        let parent = event(type: "work", start: date(2026, 6, 1, 8), end: date(2026, 6, 1, 10))
        let child = Event(
            title: "break",
            timeRanges: [Event.TimeRange(start: date(2026, 6, 1, 9), end: date(2026, 6, 1, 9, 30))],
            type: "break",
            interruptRelation: EventInterruptRelation(
                parentEventID: parent.id,
                occurrenceDate: date(2026, 6, 1, 9)
            )
        )
        let stats = ReportStatsBuilder.build(
            events: [parent, child], start: date(2026, 6, 1), end: date(2026, 6, 2), calendar: calendar
        )

        XCTAssertEqual(stats.perTypeHours.first { $0.type == "work" }?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(stats.perTypeHours.first { $0.type == "break" }?.hours ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(stats.dailyTotals.reduce(0) { $0 + $1.hours }, 2.0, accuracy: 0.0001)
    }

    func testSessionDailyStaysRawUnderOverlap() {
        // sessionDaily deliberately keeps each occurrence's full net hours —
        // co-occurrence is the correlation signal, so parallel events must
        // both read as fully present (the #116 decision documented on
        // weightedSessionDaily).
        let events = [
            event(type: "work", start: date(2026, 6, 1, 8), end: date(2026, 6, 1, 10)),
            event(type: "study", start: date(2026, 6, 1, 8), end: date(2026, 6, 1, 10)),
        ]
        let stats = ReportStatsBuilder.build(
            events: events, start: date(2026, 6, 1), end: date(2026, 6, 2), calendar: calendar
        )

        XCTAssertEqual(stats.sessionDaily.first { $0.type == "work" }?.hours ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertEqual(stats.sessionDaily.first { $0.type == "study" }?.hours ?? 0, 2.0, accuracy: 0.0001)
    }

    func testPreviousWindowBaselineIsAlsoOverlapShared() {
        // The comparison baseline must use the same accounting as the current
        // window, or every delta across an overlap-heavy stretch is fabricated.
        let events = [
            // Previous window: two fully-overlapping 2h events → work shares 1h.
            event(type: "work", start: date(2026, 5, 31, 8), end: date(2026, 5, 31, 10)),
            event(type: "study", start: date(2026, 5, 31, 8), end: date(2026, 5, 31, 10)),
            // Current window: one solo 1h work event.
            event(type: "work", start: date(2026, 6, 1, 8), end: date(2026, 6, 1, 9)),
        ]
        let stats = ReportStatsBuilder.build(
            events: events, start: date(2026, 6, 1), end: date(2026, 6, 2), calendar: calendar
        )

        let work = stats.perTypeHours.first { $0.type == "work" }
        XCTAssertEqual(work?.previousHours ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(work?.deltaHours ?? 0, 0.0, accuracy: 0.0001)
    }

    // MARK: - Todo stack stagnation line (activation loop)

    private func datelessTodo(_ title: String, createdAt: Date) -> Event {
        Event(
            title: title,
            createdAt: createdAt,
            type: "Wanna",
            kind: .todo
        )
    }

    func testTodoStackLineCountsWaitingCards() {
        let asOf = date(2026, 7, 29, 12)
        let events = [
            datelessTodo("learn guitar", createdAt: date(2026, 7, 17)),   // 12 days
            datelessTodo("buy plants", createdAt: date(2026, 7, 20)),     // 9 days
            datelessTodo("read a paper", createdAt: date(2026, 7, 28)),   // 1 day
            // Scheduled todo — on the canvas, not in the stack.
            event(type: "walk", start: date(2026, 7, 29, 9), end: date(2026, 7, 29, 10), kind: .todo),
        ]
        let line = ReportStatsBuilder.todoStackLine(events: events, asOf: asOf)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("count=3"), line!)
        XCTAssertTrue(line!.contains("waitingOver7d=2"), line!)
        XCTAssertTrue(line!.contains("oldestDays=12"), line!)
        XCTAssertTrue(line!.contains("oldest=\"learn guitar\""), line!)
    }

    func testTodoStackLineStraightensQuotesInTitle() {
        let asOf = date(2026, 7, 29, 12)
        let events = [datelessTodo("learn \"swift\" fast", createdAt: date(2026, 7, 17))]
        let line = ReportStatsBuilder.todoStackLine(events: events, asOf: asOf)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("oldest=\"learn 'swift' fast\""), line!)
    }

    func testTodoStackLineNilWhenStackEmpty() {
        let asOf = date(2026, 7, 29, 12)
        // A done dateless todo and an absorbed one are NOT in the stack.
        var done = datelessTodo("done want", createdAt: date(2026, 7, 1))
        done.isDone = true
        var absorbed = datelessTodo("absorbed want", createdAt: date(2026, 7, 1))
        absorbed.absorbedIntoEventID = UUID()
        let scheduled = event(type: "walk", start: date(2026, 7, 29, 9), end: date(2026, 7, 29, 10), kind: .todo)

        XCTAssertNil(ReportStatsBuilder.todoStackLine(events: [], asOf: asOf))
        XCTAssertNil(ReportStatsBuilder.todoStackLine(events: [done, absorbed, scheduled], asOf: asOf))
    }
}
