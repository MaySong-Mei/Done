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
}
