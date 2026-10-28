import XCTest
@testable import Done

/// Settings → Apple Watch: the overlap rules, the type filter and the wire
/// compatibility of the settings. Every expected number below is worked out
/// by hand from the fixture's clock times, not read back from the code.
/// Fixed UTC calendar; "now" is noon of the fixture day.
@MainActor
final class WristStatsSettingsTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// 2026-03-10 12:00 UTC.
    private var now: Date { at(12) }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute))!
    }

    private func event(_ type: String, _ start: Date, _ end: Date) -> Event {
        Event(title: type, timeRanges: [.init(start: start, end: end)], isAllDay: false, type: type)
    }

    private func payload(_ events: [Event]) -> CategoryStatsPayload {
        CategoryStatsBuilder.payload(events: events, now: now, calendar: calendar, colorHex: { "#\($0)" })
    }

    private func today(
        _ payload: CategoryStatsPayload, _ overlap: WristOverlapRule, settings: WristStatsSettings = .standard
    ) -> WristStatsFigures {
        WristStatsFigures.of(payload.markingLeftOut(settings), period: .today, asOf: now, overlap: overlap)
    }

    private func hours(_ figures: WristStatsFigures) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: figures.categories.map { ($0.name, $0.hours) })
    }

    // MARK: Overlap rules

    /// A 10:00–11:00 and B 10:30–11:30. Wall clock 10:00–11:30 = 1.5h, of
    /// which 10:30–11:00 is shared.
    /// split:       A = 0.5 + 0.25 = 0.75, B = 0.25 + 0.5 = 0.75 → 1.5
    /// full:        A = 1, B = 1 → 2, against 1.5 logged
    /// latestStart: B started later and takes 10:30–11:00 → A 0.5, B 1 → 1.5
    func testStaggeredPair() {
        let p = payload([event("A", at(10), at(11)), event("B", at(10, 30), at(11, 30))])

        let split = today(p, .split)
        XCTAssertEqual(hours(split), ["A": 0.75, "B": 0.75])
        XCTAssertEqual(split.totalHours, 1.5)
        XCTAssertEqual(split.loggedHours, 1.5)

        let full = today(p, .full)
        XCTAssertEqual(hours(full), ["A": 1, "B": 1])
        XCTAssertEqual(full.totalHours, 2, "the rows can add up to more than the time that passed")
        XCTAssertEqual(full.loggedHours, 1.5, "the clock row's time is wall clock under every rule")

        let latest = today(p, .latestStart)
        XCTAssertEqual(hours(latest), ["A": 0.5, "B": 1])
        XCTAssertEqual(latest.totalHours, 1.5)

        for figures in [split, full, latest] {
            XCTAssertEqual(figures.elapsedHours, 12)
            XCTAssertEqual(figures.unloggedHours, 10.5, "12h elapsed, 1.5h of it covered, whatever the rule")
        }
    }

    /// Work 9–12 with a Meeting 10–11 inside it.
    /// split:       Work 1 + 0.5 + 1 = 2.5, Meeting 0.5
    /// full:        Work 3, Meeting 1
    /// latestStart: Meeting started later → Work 2, Meeting 1
    func testNestedMeetingInsideWork() {
        let p = payload([event("Work", at(9), at(12)), event("Meeting", at(10), at(11))])
        XCTAssertEqual(hours(today(p, .split)), ["Work": 2.5, "Meeting": 0.5])
        XCTAssertEqual(hours(today(p, .full)), ["Work": 3, "Meeting": 1])
        XCTAssertEqual(hours(today(p, .latestStart)), ["Work": 2, "Meeting": 1])
    }

    /// Long 10–12 and Short 10–11 start together: the shorter takes the
    /// shared hour. Long 1 (11–12), Short 1.
    func testATieOnStartGoesToTheShorter() {
        let p = payload([event("Long", at(10), at(12)), event("Short", at(10), at(11))])
        XCTAssertEqual(hours(today(p, .latestStart)), ["Long": 1, "Short": 1])
    }

    /// Two Work events 10–11 and 10:30–11:30: one type, counted once in
    /// full — 1.5h, the time Work was on, not 2h.
    func testFullCountsATypeOnceWhereItsOwnEventsOverlap() {
        let p = payload([event("Work", at(10), at(11)), event("Work", at(10, 30), at(11, 30))])
        XCTAssertEqual(hours(today(p, .full)), ["Work": 1.5])
        XCTAssertEqual(hours(today(p, .split)), ["Work": 1.5])
        XCTAssertEqual(hours(today(p, .latestStart)), ["Work": 1.5])
    }

    /// The winner leads the slice's category list: A (index 0) and B
    /// (index 1) share 10:30–11:00 and B, started later, is listed first.
    /// Swapping the start times makes A the winner and the list plain
    /// index order.
    func testThePhoneListsTheWinnerFirst() throws {
        let p = payload([event("A", at(10), at(11)), event("B", at(10, 30), at(11, 30))])
        XCTAssertEqual(p.winners, true)
        XCTAssertEqual(try XCTUnwrap(p.categories).map(\.name), ["A", "B"])
        let slices = try XCTUnwrap(p.days?.first { $0.slices?.isEmpty == false }?.slices)
        XCTAssertEqual(slices.map(\.categoryIndices), [[0], [1, 0], [1]])
        XCTAssertEqual(slices.map(\.counts), [[1], [1, 1], [1]])

        let swapped = payload([event("A", at(10, 30), at(11, 30)), event("B", at(10), at(11))])
        let shared = try XCTUnwrap(swapped.days?.first { $0.slices?.isEmpty == false }?.slices?[1])
        XCTAssertEqual(shared.categoryIndices, [0, 1])
        XCTAssertEqual(hours(today(swapped, .latestStart)), ["A": 1, "B": 0.5])
    }

    /// A payload from a phone before the winners: latest-start cannot tell
    /// who won, and splits rather than guess.
    func testLatestStartWithoutWinnersFallsBackToSplit() {
        var p = payload([event("A", at(10), at(11)), event("B", at(10, 30), at(11, 30))])
        p.winners = nil
        XCTAssertEqual(hours(today(p, .latestStart)), ["A": 0.75, "B": 0.75])
    }

    /// Work 9–12, Meeting 10–11, Call 10:15–10:45, Call left out. Call
    /// would have won 10:15–10:45; who comes next is not written, so that
    /// half hour splits between Work and Meeting. Meeting still wins
    /// 10:00–10:15 and 10:45–11:00.
    /// Work = 1 + 0.25 + 1 = 2.25, Meeting = 0.25 + 0.25 + 0.25 = 0.75.
    func testALeftOutWinnerSplitsWhatItWouldHaveWon() {
        let p = payload([event("Work", at(9), at(12)), event("Meeting", at(10), at(11)),
                         event("Call", at(10, 15), at(10, 45))])
        let figures = today(p, .latestStart, settings: WristStatsSettings(excludedTypes: ["Call"]))
        XCTAssertEqual(hours(figures), ["Work": 2.25, "Meeting": 0.75])
        XCTAssertEqual(figures.loggedHours, 3)
    }

    // MARK: The widget is untouched

    /// The default watch figures are the widget's own arithmetic: the same
    /// categories and hours as `CategoryStats.hours`, for every period.
    func testSplitIsTheWidgetsNumbers() {
        let p = payload([
            event("A", at(10), at(11)), event("B", at(10, 30), at(11, 30)), event("C", at(10, 40), at(11, 10)),
            event("Work", at(7), at(9, 20)),
        ])
        for period in WristStatsPeriod.allCases {
            let span = period.span(asOf: now, calendar: calendar)
            let widget = CategoryStats.ranked(CategoryStats.hours(in: p, span: span, asOf: now), colors: CategoryStats.colors(in: p))
            let watch = WristStatsFigures.of(p, period: period, asOf: now)
            XCTAssertEqual(watch.categories, widget, "\(period)")
            XCTAssertEqual(watch.loggedHours, watch.totalHours, accuracy: 1e-9)
        }
        // And the widget's own summary of this payload, worked by hand:
        // 10:30–10:40 A,B; 10:40–11:00 A,B,C; 11:00–11:10 B,C.
        // A = 0.5 + 1/12 + 1/9, B = 1/12 + 1/9 + 1/12 + 1/3, C = 1/9 + 1/12.
        let summary = CategoryStats.summary(of: p, period: .today, asOf: now)
        let byName = Dictionary(uniqueKeysWithValues: summary.categories.map { ($0.name, $0.hours) })
        XCTAssertEqual(byName["A"]!, 0.5 + 1.0 / 12 + 1.0 / 9, accuracy: 1e-9)
        XCTAssertEqual(byName["B"]!, 1.0 / 12 + 1.0 / 9 + 1.0 / 12 + 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(byName["C"]!, 1.0 / 9 + 1.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(byName["Work"]!, 7.0 / 3, accuracy: 1e-9)
    }

    /// A payload written before the winners is not reused day by day — it
    /// is rebuilt once — and the result is the full build.
    func testAPayloadWithoutWinnersIsRebuiltWhole() {
        let events = [event("A", at(10), at(11)), event("B", at(10, 30), at(11, 30))]
        let full = payload(events)
        var old = full
        old.winners = nil
        old.days = full.days?.map { day in
            var copy = day
            copy.slices = day.slices?.map { var s = $0; s.categoryIndices?.sort(); return s }
            return copy
        }
        let coverage = CategoryStatsBuilder.coverage(now: now, calendar: calendar)
        let allDays = CategoryStats.days(from: coverage.start, to: coverage.end, calendar: calendar).count
        XCTAssertEqual(CategoryStatsBuilder.daysToBuild(now: now, calendar: calendar, reusing: full), 0,
                       "positive control: a payload with the order is reused whole")
        XCTAssertEqual(CategoryStatsBuilder.daysToBuild(now: now, calendar: calendar, reusing: old), allDays)
        let rebuilt = CategoryStatsBuilder.payload(events: events, now: now, calendar: calendar,
                                                   colorHex: { "#\($0)" }, reusing: old)
        XCTAssertEqual(rebuilt.withoutWriteStamp, full.withoutWriteStamp)
    }

    // MARK: Types left out

    /// Sleep 0–7 and Reading 6:30–7:30, Sleep left out, at noon.
    /// Reading has 6:30–7:00 to itself once Sleep does not compete: 1h.
    /// Sleep alone 0–6:30 = 6.5h leaves the period: elapsed 12 − 6.5 = 5.5,
    /// logged 1, unlogged 4.5. Sleep is no row.
    func testALeftOutTypeCountsNowhere() {
        let p = payload([event("Sleep", at(0), at(7)), event("Reading", at(6, 30), at(7, 30))])
        let settings = WristStatsSettings(excludedTypes: ["sleep"])
        for rule in WristOverlapRule.allCases {
            let figures = today(p, rule, settings: settings)
            XCTAssertEqual(hours(figures), ["Reading": 1], "\(rule)")
            XCTAssertEqual(figures.elapsedHours, 5.5, "\(rule)")
            XCTAssertEqual(figures.loggedHours, 1, "\(rule)")
            XCTAssertEqual(figures.unloggedHours, 4.5, "\(rule)")
        }
        // Positive control: counted, Sleep 6.5 + 0.25, Reading 0.25 + 0.5.
        let all = today(p, .split)
        XCTAssertEqual(hours(all), ["Sleep": 6.75, "Reading": 0.75])
        XCTAssertEqual(all.elapsedHours, 12)
    }

    func testBackgroundTypesFollowThePayloadsList() {
        var p = payload([event("Sleep", at(0), at(7)), event("Work", at(9), at(10))])
        let settings = WristStatsSettings(excludesBackground: true)
        XCTAssertEqual(hours(today(p, .split, settings: settings)), ["Sleep": 7, "Work": 1],
                       "a payload with no background list cannot leave any out")
        p.backgroundCategories = ["sleep"]
        let figures = today(p, .split, settings: settings)
        XCTAssertEqual(hours(figures), ["Work": 1])
        XCTAssertEqual(figures.elapsedHours, 5)
        XCTAssertEqual(hours(today(p, .split)), ["Sleep": 7, "Work": 1], "the switch off: Sleep counts")
    }

    /// The today page's clock row reads the marked payload with no rule:
    /// the same share as the stats page under any rule.
    func testTheClockRowIgnoresTheRuleButNotTheFilter() {
        let p = payload([event("Sleep", at(0), at(7)), event("A", at(10), at(11)), event("B", at(10, 30), at(11, 30))])
        let settings = WristStatsSettings(excludedTypes: ["Sleep"])
        let marked = p.markingLeftOut(settings)
        let clock = WristStatsFigures.of(marked, period: .today, asOf: now)
        for rule in WristOverlapRule.allCases {
            let page = WristStatsFigures.of(marked, period: .today, asOf: now, overlap: rule)
            XCTAssertEqual(page.loggedHours, clock.loggedHours)
            XCTAssertEqual(page.elapsedHours, clock.elapsedHours)
        }
        XCTAssertEqual(clock.loggedHours, 1.5)
        XCTAssertEqual(clock.elapsedHours, 5)
    }

    // MARK: Wire

    func testASnapshotFromAPhoneWithoutTheSettingsReadsAsStandard() throws {
        let old = #"{"version":1,"generatedAt":1773100800,"types":[],"occurrences":[],"receipts":[]}"#
        let snapshot = try WristWire.decode(WristSnapshot.self, from: Data(old.utf8))
        XCTAssertEqual(snapshot.statsSettings, .standard)
        XCTAssertEqual(snapshot.statsSettings.overlap, .split)
        XCTAssertEqual(snapshot.statsSettings.defaultPeriod, .today)
        XCTAssertTrue(snapshot.statsSettings.excludedTypes.isEmpty)
        XCTAssertFalse(snapshot.statsSettings.excludesBackground)
    }

    func testSettingsRoundTripAndUnknownValuesFallBack() throws {
        let settings = WristStatsSettings(overlap: .latestStart, excludedTypes: ["Sleep"],
                                          excludesBackground: true, defaultPeriod: .sevenDays)
        let snapshot = WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [], statsSettings: settings)
        let decoded = try WristWire.decode(WristSnapshot.self, from: WristWire.encode(snapshot))
        XCTAssertEqual(decoded.statsSettings, settings)

        let newer = #"{"overlap":"weighted","defaultPeriod":"year","excludesBackground":true}"#
        let read = try JSONDecoder().decode(WristStatsSettings.self, from: Data(newer.utf8))
        XCTAssertEqual(read, WristStatsSettings(excludesBackground: true), "unknown rule and period read as the defaults")
        XCTAssertEqual(WristStatsSettings.decode("not json"), .standard)
        XCTAssertEqual(WristStatsSettings.decode(settings.encoded), settings)
    }

    func testChangingASettingIsNewContentForThePush() {
        let base = WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [])
        var changed = base
        changed.statsSettings.overlap = .full
        XCTAssertTrue(base.hasSameContent(as: base))
        XCTAssertFalse(base.hasSameContent(as: changed))
    }

    func testBuilderCarriesTheSettings() {
        let settings = WristStatsSettings(overlap: .full)
        let snapshot = WristSnapshotBuilder.snapshot(
            events: [], templates: [], now: now, calendar: calendar, language: nil, receipts: [],
            statsSettings: settings, colorHex: { _ in "#000000" }
        )
        XCTAssertEqual(snapshot.statsSettings, settings)
    }
}
