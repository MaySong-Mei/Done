import XCTest
@testable import Done

/// The phone's projection for the watch. Fixed UTC calendar and a fixed
/// "now" so nothing depends on the machine's zone or the run time.
@MainActor
final class WristSnapshotBuilderTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// 2026-03-10 10:00 UTC, a plain Tuesday.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 10))!
    }

    private func day(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: now)!)
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start)!
    }

    private func event(_ title: String, type: String, start: Date, end: Date, allDay: Bool = false) -> Event {
        Event(title: title, timeRanges: [.init(start: start, end: end)], isAllDay: allDay, type: type)
    }

    private func templates(_ titles: String...) -> [EventTypeTemplate] {
        titles.map { EventTypeTemplate(title: $0, colorHex: "#00\($0.count)0FF") }
    }

    private func occurrences(_ events: [Event]) -> [WristOccurrence] {
        WristSnapshotBuilder.occurrences(events: events, now: now, calendar: calendar, colorHex: { "#C-\($0)" })
    }

    // MARK: Types

    func testTypesRankByRecentUseThenCatalogOrder() {
        let catalog = templates("Admin", "Research", "Meeting", "Gym")
        let events = [
            event("a", type: "Meeting", start: day(-1, hour: 9), end: day(-1, hour: 10)),
            event("b", type: "Meeting", start: day(-3, hour: 9), end: day(-3, hour: 10)),
            event("c", type: "Gym", start: day(-2, hour: 9), end: day(-2, hour: 10)),
        ]
        let ranked = WristSnapshotBuilder.rankedTypes(events: events, templates: catalog, now: now, calendar: calendar)
        XCTAssertEqual(ranked.map(\.title), ["Meeting", "Gym", "Admin", "Research"])
        XCTAssertEqual(ranked[0].id, catalog[2].id)
        XCTAssertEqual(ranked[0].colorHex, catalog[2].colorHex)
    }

    func testUsageOlderThanTheWindowOrInTheFutureDoesNotCount() {
        let catalog = templates("Admin", "Research")
        let events = [
            event("old", type: "Research", start: day(-31, hour: 9), end: day(-31, hour: 10)),
            event("planned", type: "Research", start: day(2, hour: 9), end: day(2, hour: 10)),
        ]
        let ranked = WristSnapshotBuilder.rankedTypes(events: events, templates: catalog, now: now, calendar: calendar)
        XCTAssertEqual(ranked.map(\.title), ["Admin", "Research"], "no usage → catalog order")
        let recent = [event("r", type: "Research", start: day(-30, hour: 11), end: day(-30, hour: 12))]
        XCTAssertEqual(
            WristSnapshotBuilder.rankedTypes(events: recent, templates: catalog, now: now, calendar: calendar).first?.title,
            "Research", "the window edge counts"
        )
    }

    func testRecurringSeriesCountsAsInUseRegardlessOfItsStart() {
        let catalog = templates("Admin", "Standup")
        var series = event("daily", type: "Standup", start: day(-400, hour: 9), end: day(-400, hour: 9, minute: 15))
        series.repeatUnit = .day
        XCTAssertTrue(series.isRecurringSeries)
        let ranked = WristSnapshotBuilder.rankedTypes(events: [series], templates: catalog, now: now, calendar: calendar)
        XCTAssertEqual(ranked.first?.title, "Standup")
    }

    func testTypesAreCappedAndOnlyCatalogEntriesAppear() {
        let catalog = templates("A", "B", "C", "D", "E", "F", "G", "H", "I", "J")
        let events = [event("x", type: "NotInCatalog", start: day(0, hour: 8), end: day(0, hour: 9))]
        let ranked = WristSnapshotBuilder.rankedTypes(events: events, templates: catalog, now: now, calendar: calendar)
        XCTAssertEqual(ranked.count, WristSnapshotBuilder.maxTypes)
        XCTAssertFalse(ranked.contains { $0.title == "NotInCatalog" })
        XCTAssertTrue(WristSnapshotBuilder.rankedTypes(events: events, templates: [], now: now, calendar: calendar).isEmpty)
    }

    // MARK: Occurrences

    func testWindowIsYesterdayThroughTheDayAfterTomorrow() {
        let events = [
            event("two days ago", type: "T", start: day(-2, hour: 9), end: day(-2, hour: 10)),
            event("yesterday", type: "T", start: day(-1, hour: 9), end: day(-1, hour: 10)),
            event("today", type: "T", start: day(0, hour: 9), end: day(0, hour: 10)),
            event("tomorrow", type: "T", start: day(1, hour: 9), end: day(1, hour: 10)),
            event("in two days", type: "T", start: day(2, hour: 9), end: day(2, hour: 10)),
            event("in three days", type: "T", start: day(3, hour: 9), end: day(3, hour: 10)),
        ]
        XCTAssertEqual(occurrences(events).map(\.title), ["yesterday", "today", "tomorrow", "in two days"])
    }

    func testRunningTimerProjectsOpenEndedWithoutQuickActions() {
        var timer = event("Reading", type: "Read", start: day(0, hour: 9), end: day(0, hour: 9))
        timer.timerStartedAt = day(0, hour: 9)
        let result = occurrences([timer])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isOpenEnded)
        XCTAssertEqual(result[0].end, .distantFuture)
        XCTAssertFalse(result[0].quickActionsEnabled)
        XCTAssertEqual(WristStateReducer.current(in: result, now: now)?.eventID, timer.id, "running an hour after it started")
    }

    func testAllDayIsLeftOutAndTitlesFallBackToType() {
        let events = [
            event("Holiday", type: "Off", start: day(0, hour: 0), end: day(1, hour: 0), allDay: true),
            event("   ", type: "Gym", start: day(0, hour: 7), end: day(0, hour: 8)),
        ]
        let result = occurrences(events)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Gym")
        XCTAssertEqual(result[0].type, "Gym")
        XCTAssertEqual(result[0].colorHex, "#C-Gym", "color comes from the resolver, not the event")
        XCTAssertEqual(result[0].start, day(0, hour: 7))
        XCTAssertEqual(result[0].end, day(0, hour: 8))
    }

    func testOccurrencesAreSortedByStartAcrossDays() {
        let events = [
            event("late today", type: "T", start: day(0, hour: 22), end: day(0, hour: 23)),
            event("early tomorrow", type: "T", start: day(1, hour: 1), end: day(1, hour: 2)),
            event("early today", type: "T", start: day(0, hour: 1), end: day(0, hour: 2)),
        ]
        XCTAssertEqual(occurrences(events).map(\.title), ["early today", "late today", "early tomorrow"])
    }

    func testRecurringOccurrencesExpandAndRefuseQuickActions() {
        var series = event("Standup", type: "Meeting", start: day(-5, hour: 9), end: day(-5, hour: 9, minute: 15))
        series.repeatUnit = .day
        let result = occurrences([series])
        XCTAssertEqual(result.count, 4, "one occurrence per window day")
        XCTAssertTrue(result.allSatisfy { !$0.quickActionsEnabled })
        XCTAssertTrue(result.allSatisfy { $0.eventID == series.id })
        XCTAssertEqual(Set(result.map(\.id)).count, 4, "distinct occurrence ids")
    }

    func testEmbeddedInterruptIsFlagged() {
        let parent = event("Deep work", type: "Work", start: day(0, hour: 9), end: day(0, hour: 12))
        var interrupt = event("Phone", type: "Call", start: day(0, hour: 10), end: day(0, hour: 10, minute: 15))
        interrupt.displayKind = .interrupt
        interrupt.interruptRelation = EventInterruptRelation(parentEventID: parent.id, occurrenceDate: day(0, hour: 9))
        let result = occurrences([parent, interrupt])
        XCTAssertEqual(result.map(\.isInterrupt), [false, true])
        XCTAssertTrue(result.allSatisfy(\.quickActionsEnabled))
    }

    // MARK: Whole snapshot

    func testSnapshotCarriesClockLanguageAndReceipts() {
        let receipt = WristReceipt(id: UUID(), outcome: .applied, reason: nil)
        let snapshot = WristSnapshotBuilder.snapshot(
            events: [event("x", type: "Gym", start: day(0, hour: 7), end: day(0, hour: 8))],
            templates: templates("Gym"), now: now, calendar: calendar, language: "zh",
            receipts: [receipt], colorHex: { _ in "#123456" }
        )
        XCTAssertEqual(snapshot.version, WristSnapshot.currentVersion)
        XCTAssertEqual(snapshot.generatedAt, now)
        XCTAssertEqual(snapshot.language, "zh")
        XCTAssertEqual(snapshot.receipts, [receipt])
        XCTAssertEqual(snapshot.types.map(\.title), ["Gym"])
        XCTAssertEqual(snapshot.occurrences.map(\.title), ["x"])
    }

    // MARK: Stats for the watch

    /// The widget's own pipeline, over a fixed calendar, so the watch's
    /// numbers are the widget's numbers.
    private func widgetPayload(_ events: [Event]) -> CategoryStatsPayload {
        CategoryStatsBuilder.payload(events: events, now: now, calendar: calendar, colorHex: { "#\($0)" })
    }

    func testStatsAreTheWidgetPayloadTrimmedToTheWeek() {
        let events = [
            event("last week", type: "Old", start: day(-8, hour: 9), end: day(-8, hour: 10)),
            event("today", type: "Work", start: day(0, hour: 8), end: day(0, hour: 9, minute: 30)),
        ]
        let full = widgetPayload(events)
        let frame = full.resolvedCalendar()
        let week = CategoryStats.range(of: .week, containing: now, calendar: frame)
        let dayBefore = frame.date(byAdding: .day, value: -1, to: week.start)!
        let trimmed = try! XCTUnwrap(WristSnapshotBuilder.weekOnly(full, now: now))
        XCTAssertEqual(trimmed.coverageStart, dayBefore, "the week and one day of margin")
        let horizon = frame.date(byAdding: .day, value: 3, to: frame.startOfDay(for: now))!
        XCTAssertEqual(trimmed.coverageEnd, horizon, "through the day after tomorrow, like the occurrences")
        XCTAssertTrue((trimmed.days ?? []).allSatisfy { ($0.start ?? .distantPast) >= dayBefore && ($0.start ?? .distantFuture) < horizon })
        // Read on the last kept day, the trimmed payload still answers like the full one.
        let later = horizon.addingTimeInterval(-60)
        XCTAssertEqual(CategoryStats.summary(of: trimmed, period: .today, asOf: later),
                       CategoryStats.summary(of: full, period: .today, asOf: later))
        XCTAssertLessThan(trimmed.days?.count ?? 0, full.days?.count ?? 0, "older days are dropped")
        let todayOnly = try! XCTUnwrap(WristSnapshotBuilder.weekOnly(full, now: now, todayOnly: true))
        XCTAssertEqual(CategoryStats.summary(of: todayOnly, period: .today, asOf: now),
                       CategoryStats.summary(of: full, period: .today, asOf: now))
        if frame.startOfDay(for: now) > CategoryStats.range(of: .week, containing: now, calendar: frame).start.addingTimeInterval(86_400) {
            XCTAssertEqual(CategoryStats.summary(of: todayOnly, period: .week, asOf: now).status, .stale,
                           "the today-only fallback says the week is out of reach")
        }
        for period in [CategoryStatsPeriod.today, .week] {
            XCTAssertEqual(CategoryStats.summary(of: trimmed, period: period, asOf: now),
                           CategoryStats.summary(of: full, period: period, asOf: now),
                           "same figures as the widget for \(period)")
        }
        XCTAssertEqual(CategoryStats.summary(of: trimmed, period: .today, asOf: now).totalHours, 1.5)
        XCTAssertEqual(CategoryStats.summary(of: trimmed, period: .month, asOf: now).status, .stale,
                       "the month is out of reach and says so")
    }

    func testStatsThatDoNotReachThisWeekAreLeftOut() {
        var old = widgetPayload([event("x", type: "Work", start: day(0, hour: 8), end: day(0, hour: 9))])
        old.coverageEnd = day(-1, hour: 0)
        XCTAssertNil(WristSnapshotBuilder.weekOnly(old, now: now))
    }

    func testSnapshotEqualityIgnoresTheStatsWriteStamp() {
        let payload = widgetPayload([event("x", type: "Work", start: day(0, hour: 8), end: day(0, hour: 9))])
        var stamped = payload
        stamped.writtenAt = now.addingTimeInterval(600)
        let a = WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [], stats: payload)
        let b = WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [], stats: stamped)
        XCTAssertTrue(a.hasSameContent(as: b))
        var changed = payload
        changed.days = []
        XCTAssertFalse(a.hasSameContent(as: WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [], stats: changed)))
        XCTAssertFalse(a.hasSameContent(as: WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [])))
    }

    func testSnapshotWithoutStatsStillDecodesAndOneWithUnreadableStatsKeepsTheRest() throws {
        let plain = WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [])
        let decoded = try WristWire.decode(WristSnapshot.self, from: try WristWire.encode(plain))
        XCTAssertNil(decoded.stats)
        var object = try JSONSerialization.jsonObject(with: try WristWire.encode(plain)) as! [String: Any]
        object["stats"] = ["days": "not a list"]
        let tolerant = try WristWire.decode(WristSnapshot.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(tolerant.stats)
        XCTAssertEqual(tolerant.generatedAt, plain.generatedAt)
    }

    /// A snapshot the phone cannot send leaves the watch with nothing new;
    /// past the budget the bridge steps down until one fits.
    func testOversizedSnapshotsStepDownUntilTheyFit() throws {
        let types = ["Work", "Study", "Exercise", "Reading", "Errand"]
        var events: [Event] = []
        for d in -10...10 {
            for i in 0..<40 {
                let start = day(d, hour: 0, minute: i * 35)
                events.append(event("A fairly long event title number \(i)", type: types[i % types.count],
                                    start: start, end: start.addingTimeInterval(50 * 60)))
            }
        }
        let stats = widgetPayload(events)
        let full = WristSnapshotBuilder.snapshot(events: events, templates: [], now: now, calendar: calendar,
                                                 language: nil, receipts: [], stats: stats, colorHex: { "#\($0)" })
        XCTAssertGreaterThan(try WristWire.encode(full).count, WristBridge.byteBudget, "fixture really is too big")
        let (sent, data) = try XCTUnwrap(WristBridge.fitting(full, latestStats: stats, now: now))
        XCTAssertLessThanOrEqual(data.count, WristBridge.byteBudget)
        XCTAssertEqual(try WristWire.decode(WristSnapshot.self, from: data), sent)

        // A light calendar goes whole.
        let light = WristSnapshot(generatedAt: now, types: [], occurrences: Array(full.occurrences.prefix(5)), receipts: [], stats: full.stats)
        XCTAssertEqual(try XCTUnwrap(WristBridge.fitting(light, latestStats: stats, now: now)).0, light)
    }

    func testNarrowedKeepsYesterdayThroughTomorrow() {
        let events = (-3...3).map { d in event("d\(d)", type: "T", start: day(d, hour: 9), end: day(d, hour: 10)) }
        let snapshot = WristSnapshot(generatedAt: now, types: [], occurrences: occurrences(events), receipts: [])
        XCTAssertEqual(WristSnapshotBuilder.narrowed(snapshot, now: now, calendar: calendar).occurrences.map(\.title),
                       ["d-1", "d0", "d1"])
    }
}

