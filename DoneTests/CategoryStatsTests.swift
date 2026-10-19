import XCTest
@testable import Done

// MARK: - Periods

/// The widget's periods are the Analysis tab's: `AnalysisViewModel.dateRange`
/// and `daysInRange` delegate to `CategoryStats.range` / `CategoryStats.days`,
/// so these pin the shared function against hand-written calendars, and the
/// delegation separately.
final class CategoryStatsPeriodTests: XCTestCase {
    private func calendar(_ zone: String = "UTC", firstWeekday: Int = 1) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        cal.firstWeekday = firstWeekday
        cal.minimumDaysInFirstWeek = 1
        return cal
    }

    private func date(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    @MainActor
    func testWeekStartsOnTheCalendarsOwnFirstWeekday() {
        // Wednesday 21 October 2026.
        let sunday = calendar(firstWeekday: 1), monday = calendar(firstWeekday: 2)
        let sundayWeek = CategoryStats.range(of: .week, containing: date(sunday, 2026, 10, 21, 15), calendar: sunday)
        XCTAssertEqual(sundayWeek.start, date(sunday, 2026, 10, 18))
        XCTAssertEqual(sundayWeek.end, date(sunday, 2026, 10, 25))
        let mondayWeek = CategoryStats.range(of: .week, containing: date(monday, 2026, 10, 21, 15), calendar: monday)
        XCTAssertEqual(mondayWeek.start, date(monday, 2026, 10, 19))
        XCTAssertEqual(mondayWeek.end, date(monday, 2026, 10, 26))
        // On the first weekday itself, the week is the one it opens.
        let onSunday = CategoryStats.range(of: .week, containing: date(sunday, 2026, 10, 18, 0, 1), calendar: sunday)
        XCTAssertEqual(onSunday.start, date(sunday, 2026, 10, 18))
        let sundayUnderMonday = CategoryStats.range(of: .week, containing: date(monday, 2026, 10, 18, 23), calendar: monday)
        XCTAssertEqual(sundayUnderMonday.start, date(monday, 2026, 10, 12),
                       "a Sunday closes the Monday-first week")
    }

    @MainActor
    func testWeeksCrossingAMonthAndAYear() {
        let sunday = calendar(firstWeekday: 1), monday = calendar(firstWeekday: 2)
        let september = CategoryStats.range(of: .week, containing: date(sunday, 2026, 9, 30, 12), calendar: sunday)
        XCTAssertEqual(september.start, date(sunday, 2026, 9, 27))
        XCTAssertEqual(september.end, date(sunday, 2026, 10, 4))
        let newYear = CategoryStats.range(of: .week, containing: date(monday, 2026, 12, 31, 12), calendar: monday)
        XCTAssertEqual(newYear.start, date(monday, 2026, 12, 28))
        XCTAssertEqual(newYear.end, date(monday, 2027, 1, 4))
        XCTAssertEqual(CategoryStats.days(from: newYear.start, to: newYear.end, calendar: monday).count, 7)
    }

    @MainActor
    func testMonthStartsAndLengths() {
        let cal = calendar()
        let october = CategoryStats.range(of: .month, containing: date(cal, 2026, 10, 31, 23, 59), calendar: cal)
        XCTAssertEqual(october.start, date(cal, 2026, 10, 1))
        XCTAssertEqual(october.end, date(cal, 2026, 11, 1))
        let leap = CategoryStats.range(of: .month, containing: date(cal, 2028, 2, 15), calendar: cal)
        XCTAssertEqual(leap.start, date(cal, 2028, 2, 1))
        XCTAssertEqual(CategoryStats.days(from: leap.start, to: leap.end, calendar: cal).count, 29)
        let first = CategoryStats.range(of: .month, containing: date(cal, 2026, 11, 1), calendar: cal)
        XCTAssertEqual(first.start, date(cal, 2026, 11, 1), "midnight on the 1st is the month it opens")
    }

    @MainActor
    func testTodayIsTheCivilDayAcrossDaylightSaving() {
        let la = calendar("America/Los_Angeles")
        let fallBack = CategoryStats.range(of: .today, containing: date(la, 2026, 11, 1, 12), calendar: la)
        XCTAssertEqual(fallBack.end.timeIntervalSince(fallBack.start), 25 * 3600)
        let springForward = CategoryStats.range(of: .today, containing: date(la, 2026, 3, 8, 12), calendar: la)
        XCTAssertEqual(springForward.end.timeIntervalSince(springForward.start), 23 * 3600)
        let week = CategoryStats.range(of: .week, containing: date(la, 2026, 11, 3), calendar: la)
        let days = CategoryStats.days(from: week.start, to: week.end, calendar: la)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(Set(days.map { la.startOfDay(for: $0) }).count, 7, "seven distinct civil days")
    }

    /// The tab and the widget take one definition of each period: the view
    /// model's range and day walk ARE the shared ones, for every period,
    /// offset and week start.
    @MainActor
    func testAnalysisDelegatesItsRangeAndDays() {
        for firstWeekday in [1, 2] {
            let cal = calendar("Europe/Berlin", firstWeekday: firstWeekday)
            for anchor in [date(cal, 2026, 3, 29, 12), date(cal, 2026, 10, 31, 23), date(cal, 2026, 12, 31, 1)] {
                for (period, analysis) in [(CategoryStatsPeriod.today, AnalysisPeriod.day), (.week, .week), (.month, .month)] {
                    for offset in [-1, 0, 2] {
                        let vm = AnalysisViewModel(initialPeriod: analysis, calendar: cal)
                        vm.offset = offset
                        vm.periodAnchor = { anchor }
                        let shared = CategoryStats.range(of: period, containing: anchor, offset: offset, calendar: cal)
                        XCTAssertEqual(vm.dateRange.start, shared.start)
                        XCTAssertEqual(vm.dateRange.end, shared.end)
                        XCTAssertEqual(vm.daysInRange(), CategoryStats.days(from: shared.start, to: shared.end, calendar: cal))
                    }
                }
            }
        }
    }
}

// MARK: - Display arithmetic and status

final class CategoryStatsMathTests: XCTestCase {

    // MARK: percents

    @MainActor
    func testPercentsSumToExactlyOneHundred() {
        XCTAssertEqual(CategoryStats.percents([1, 1, 1]), [34, 33, 33])
        XCTAssertEqual(CategoryStats.percents([2, 1]), [67, 33])
        XCTAssertEqual(CategoryStats.percents([0.5, 0.5]), [50, 50])
        XCTAssertEqual(CategoryStats.percents([0, 0]), [0, 0], "nothing to share")
        XCTAssertEqual(CategoryStats.percents([]), [])
        XCTAssertEqual(CategoryStats.percents([3]), [100])
    }

    /// Seeded random vectors: every one sums to 100 and no entry is more than
    /// a point off its exact share. The control is the naive rounding the
    /// largest-remainder method replaces, which must miss 100 on some of the
    /// same vectors — otherwise these vectors could not tell the two apart.
    @MainActor
    func testRandomVectorsSumToOneHundredWhereNaiveRoundingDoesNot() {
        var rng = SplitMix(seed: 0xC47)
        var naiveMisses = 0
        for _ in 0..<2000 {
            let count = Int(rng.next() % 7) + 1
            let values = (0..<count).map { _ in Double(rng.next() % 10_000) / 100 }
            let total = values.reduce(0, +)
            guard total > 0 else { continue }
            let rounded = CategoryStats.percents(values)
            XCTAssertEqual(rounded.reduce(0, +), 100, "\(values)")
            for (value, percent) in zip(values, rounded) {
                XCTAssertLessThan(abs(Double(percent) - value / total * 100), 1, "\(values)")
            }
            if values.map({ Int(($0 / total * 100).rounded()) }).reduce(0, +) != 100 { naiveMisses += 1 }
        }
        XCTAssertGreaterThan(naiveMisses, 100, "control: plain rounding misses 100 on these vectors")
    }

    @MainActor
    func testTimeThatRoundsToNothingReadsLessThanOnePercent() {
        let rows = CategoryStats.breakdown([
            CategoryHours(name: "Work", hours: 100),
            CategoryHours(name: "Tea", hours: 0.2),
        ], maxRows: 3)
        XCTAssertEqual(rows.map(\.percent), [100, 0])
        XCTAssertEqual(rows.map(\.percentText), ["100%", "<1%"])
        let zero = CategoryStatsRow(kind: .category(rank: 0), name: "x", hours: 0, share: 0, percent: 0)
        XCTAssertEqual(zero.percentText, "0%", "no time is not \"<1%\"")
    }

    // MARK: breakdown

    private let five: [CategoryHours] = [
        CategoryHours(name: "Deep Work", colorHex: "#111111", hours: 13.6),
        CategoryHours(name: "Meetings", colorHex: "#222222", hours: 8.1),
        CategoryHours(name: "Exercise", colorHex: "#333333", hours: 3.25),
        CategoryHours(name: "Reading", colorHex: "#444444", hours: 2),
        CategoryHours(name: "Chores", colorHex: "#555555", hours: 1),
    ]

    @MainActor
    func testEveryCategoryGetsARowWhenTheyFit() {
        let rows = CategoryStats.breakdown(Array(five.prefix(3)), maxRows: 3)
        XCTAssertEqual(rows.map(\.name), ["Deep Work", "Meetings", "Exercise"])
        XCTAssertEqual(rows.map(\.kind), [.category(rank: 0), .category(rank: 1), .category(rank: 2)])
        XCTAssertEqual(rows.map(\.percent).reduce(0, +), 100)
        XCTAssertEqual(rows.map(\.colorHex), ["#111111", "#222222", "#333333"])
    }

    @MainActor
    func testMoreThanFitBecomesLeadersPlusOneRemainderRow() {
        let rows = CategoryStats.breakdown(five, maxRows: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.prefix(2).map(\.name), ["Deep Work", "Meetings"])
        XCTAssertEqual(rows[2].kind, .remainder(count: 3))
        XCTAssertTrue(rows[2].isRemainder)
        XCTAssertEqual(rows[2].name, "", "the remainder carries no name a category could share")
        XCTAssertNil(rows[2].colorHex)
        XCTAssertEqual(rows[2].hours, 6.25, accuracy: 1e-12)
        XCTAssertEqual(rows.map(\.percent).reduce(0, +), 100)
        XCTAssertEqual(rows.map(\.share).reduce(0, +), 1, accuracy: 1e-12)

        let medium = CategoryStats.breakdown(five, maxRows: 5)
        XCTAssertEqual(medium.count, 5)
        XCTAssertFalse(medium.contains { $0.isRemainder }, "five fit in five")
        let six = five + [CategoryHours(name: "Errands", hours: 0.5)]
        let mediumSix = CategoryStats.breakdown(six, maxRows: 5)
        XCTAssertEqual(mediumSix.map(\.kind).last, .remainder(count: 2))
        XCTAssertEqual(mediumSix.count, 5)
    }

    /// A real category named "Other" — the Analysis bucket for untyped time
    /// is literally that — stays a category with its own rank and colour; the
    /// remainder is a different kind of row.
    @MainActor
    func testACategoryNamedOtherIsNeverTheRemainder() {
        let withOther = [CategoryHours(name: "Other", colorHex: "#999999", hours: 20)] + five
        let rows = CategoryStats.breakdown(withOther, maxRows: 3)
        XCTAssertEqual(rows[0].name, "Other")
        XCTAssertEqual(rows[0].kind, .category(rank: 0))
        XCTAssertEqual(rows[0].colorHex, "#999999")
        XCTAssertEqual(rows.filter(\.isRemainder).count, 1)
        XCTAssertEqual(rows[2].kind, .remainder(count: 4))
    }

    @MainActor
    func testLeadersOnlyFacesRoundAgainstTheWholePeriod() {
        let rows = CategoryStats.breakdown(five, maxRows: 2, includeRemainder: false)
        XCTAssertEqual(rows.map(\.name), ["Deep Work", "Meetings"])
        XCTAssertFalse(rows.contains { $0.isRemainder })
        // 13.6 / 27.95 = 48.66%, 8.1 / 27.95 = 28.98%: their own shares, not
        // stretched to fill 100.
        XCTAssertEqual(rows.map(\.percent), [49, 29])
        let single = CategoryStats.breakdown(five, maxRows: 1)
        XCTAssertEqual(single.map(\.name), ["Deep Work"], "one row has no room for a remainder")
        XCTAssertEqual(single.first?.percent, 49)
    }

    @MainActor
    func testZeroAndBrokenValuesNeverReachARow() {
        let rows = CategoryStats.breakdown([
            CategoryHours(name: "A", hours: 2), CategoryHours(name: "B", hours: 0),
            CategoryHours(name: "C", hours: .nan), CategoryHours(name: "D", hours: -1),
        ], maxRows: 3)
        XCTAssertEqual(rows.map(\.name), ["A"])
        XCTAssertEqual(rows.first?.percent, 100)
        XCTAssertTrue(CategoryStats.breakdown([], maxRows: 3).isEmpty)
        XCTAssertTrue(CategoryStats.breakdown(five, maxRows: 0).isEmpty)
    }

    @MainActor
    func testRankingIsByHoursThenName() {
        let ranked = CategoryStats.ranked(["b": 1, "a": 1, "c": 3, "z": 0])
        XCTAssertEqual(ranked.map(\.name), ["c", "a", "b"])
    }

    // MARK: reading a payload

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        return cal
    }

    /// Monday 19 October 2026, UTC.
    private var monday: Date { utc.date(from: DateComponents(year: 2026, month: 10, day: 19))! }

    private func at(_ day: Int, _ hour: Double) -> Date {
        monday.addingTimeInterval(TimeInterval(day) * 86_400 + hour * 3600)
    }

    /// A hand-written payload: 9-10 A alone, 10-11 A and B half each, 11-12
    /// two A and one B (A two thirds), all on Monday; Tuesday 9-10 B alone.
    private func payload(coverageStart: Date? = nil, coverageEnd: Date? = nil) -> CategoryStatsPayload {
        CategoryStatsPayload(
            version: 1, writtenAt: at(0, 8),
            coverageStart: coverageStart ?? at(-7, 0), coverageEnd: coverageEnd ?? at(14, 0),
            calendar: CategoryStatsPayload.frame(of: utc),
            categories: [.init(name: "A", colorHex: "#FF0000"), .init(name: "B", colorHex: nil)],
            days: [
                .init(start: at(0, 0), slices: [
                    .init(start: at(0, 9), end: at(0, 10), n: 1, categoryIndices: [0], counts: [1]),
                    .init(start: at(0, 10), end: at(0, 11), n: 2, categoryIndices: [0, 1], counts: [1, 1]),
                    .init(start: at(0, 11), end: at(0, 12), n: 3, categoryIndices: [0, 1], counts: [2, 1]),
                ]),
                .init(start: at(1, 0), slices: [
                    .init(start: at(1, 9), end: at(1, 10), n: 1, categoryIndices: [1], counts: [1]),
                ]),
            ]
        )
    }

    @MainActor
    func testHoursAreTheSlicesCutAtTheInstant() {
        let p = payload()
        XCTAssertEqual(CategoryStats.hours(in: p, period: .today, asOf: at(0, 8)), [:], "before anything")
        let midSecond = CategoryStats.hours(in: p, period: .today, asOf: at(0, 10.5))
        XCTAssertEqual(midSecond["A"] ?? 0, 1.25, accuracy: 1e-12)
        XCTAssertEqual(midSecond["B"] ?? 0, 0.25, accuracy: 1e-12)
        let end = CategoryStats.hours(in: p, period: .today, asOf: at(0, 20))
        XCTAssertEqual(end["A"] ?? 0, 1 + 0.5 + 2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(end["B"] ?? 0, 0.5 + 1.0 / 3, accuracy: 1e-12)
        // Tuesday's "today" is Tuesday only; the week holds both days.
        XCTAssertEqual(CategoryStats.hours(in: p, period: .today, asOf: at(1, 23)), ["B": 1])
        let week = CategoryStats.hours(in: p, period: .week, asOf: at(1, 9.5))
        XCTAssertEqual(week["B"] ?? 0, 0.5 + 1.0 / 3 + 0.5, accuracy: 1e-12)
        // A week later the same slices are last week's.
        XCTAssertEqual(CategoryStats.hours(in: p, period: .week, asOf: at(7, 12)), [:])
    }

    @MainActor
    func testUnusableSlicesAreSkippedNotTrusted() {
        var p = payload()
        p.days?[0].slices? += [
            .init(start: at(0, 13), end: at(0, 14), n: 0, categoryIndices: [0], counts: [1]),
            .init(start: at(0, 15), end: at(0, 14), n: 1, categoryIndices: [0], counts: [1]),
            .init(start: at(0, 16), end: at(0, 17), n: 1, categoryIndices: [7], counts: [1]),
            .init(start: at(0, 18), end: at(0, 19), n: 1, categoryIndices: [0], counts: nil),
            .init(start: nil, end: at(0, 19), n: 1, categoryIndices: [0], counts: [1]),
        ]
        let hours = CategoryStats.hours(in: p, period: .today, asOf: at(0, 23))
        XCTAssertEqual(hours["A"] ?? 0, 1 + 0.5 + 2.0 / 3, accuracy: 1e-12)
    }

    @MainActor
    func testThePayloadsOwnCalendarCutsThePeriod() {
        // The same instants read under a calendar whose week starts on Sunday:
        // Sunday the 25th is then the first day of a new week. The payload says
        // Monday, and Monday is what the widget must use.
        var p = payload()
        p.days?.append(.init(start: at(6, 0), slices: [
            .init(start: at(6, 9), end: at(6, 10), n: 1, categoryIndices: [0], counts: [1]),
        ]))
        let sundayWeek = CategoryStats.hours(in: p, period: .week, asOf: at(6, 12))
        XCTAssertEqual(sundayWeek["A"] ?? 0, 1 + 0.5 + 2.0 / 3 + 1, accuracy: 1e-12,
                       "Monday-first: Sunday closes the week that began on the 19th")
    }

    @MainActor
    func testPayloadRoundTripsThroughJSON() throws {
        let p = payload()
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(CategoryStatsPayload.self, from: data), p)
        // A payload missing everything optional still decodes, to no data.
        let empty = try JSONDecoder().decode(CategoryStatsPayload.self, from: Data("{}".utf8))
        XCTAssertEqual(CategoryStats.status(of: empty, period: .week, asOf: at(0, 9)), .noData)
    }

    // MARK: status

    @MainActor
    func testStatusTransitions() {
        let p = payload()
        XCTAssertEqual(CategoryStats.status(of: nil, period: .week, asOf: at(0, 9)), .noData)
        XCTAssertEqual(CategoryStats.status(of: p, period: .today, asOf: at(0, 8)), .empty,
                       "readable, nothing elapsed yet")
        XCTAssertEqual(CategoryStats.status(of: p, period: .today, asOf: at(0, 9.5)), .ok)
        XCTAssertEqual(CategoryStats.status(of: p, period: .today, asOf: at(2, 12)), .empty,
                       "a later day with nothing in it")
        XCTAssertEqual(CategoryStats.status(of: p, period: .week, asOf: at(14, 0) - 1), .empty)
        XCTAssertEqual(CategoryStats.status(of: p, period: .week, asOf: at(14, 0)), .stale,
                       "the payload ends here")
        XCTAssertEqual(CategoryStats.status(of: p, period: .week, asOf: at(-8, 12)), .stale,
                       "before the coverage")
        let lateCoverage = payload(coverageStart: at(0, 0))
        XCTAssertEqual(CategoryStats.status(of: lateCoverage, period: .today, asOf: at(0, 9.5)), .ok)
        XCTAssertEqual(CategoryStats.status(of: lateCoverage, period: .month, asOf: at(0, 9.5)), .stale,
                       "October began before the payload does")
        var newer = p
        newer.version = CategoryStatsPayload.currentVersion + 1
        XCTAssertEqual(CategoryStats.status(of: newer, period: .today, asOf: at(0, 9.5)), .noData,
                       "a format from a newer build is not guessed at")
        var noCoverage = p
        noCoverage.coverageEnd = nil
        XCTAssertEqual(CategoryStats.status(of: noCoverage, period: .today, asOf: at(0, 9.5)), .noData)
    }

    @MainActor
    func testSummaryCarriesRankedCategoriesWithTheirColours() {
        let summary = CategoryStats.summary(of: payload(), period: .today, asOf: at(0, 20))
        XCTAssertEqual(summary.status, .ok)
        XCTAssertEqual(summary.categories.map(\.name), ["A", "B"])
        XCTAssertEqual(summary.categories.map(\.colorHex), ["#FF0000", nil])
        XCTAssertEqual(summary.totalHours, 3, accuracy: 1e-12)
        let empty = CategoryStats.summary(of: payload(), period: .today, asOf: at(0, 8))
        XCTAssertEqual(empty.status, .empty)
        XCTAssertEqual(empty.categories, [])
    }

    /// The rollover entry (`WidgetTimelineSchedule.entryDates`' last) belongs
    /// to the NEXT day: "today" restarts from nothing, the week keeps going.
    @MainActor
    func testTheRolloverEntryReadsTheNextDay() throws {
        let p = payload()
        let rollover = try XCTUnwrap(WidgetTimelineSchedule.entryDates(events: [], now: at(0, 20), calendar: utc).last)
        XCTAssertEqual(rollover, at(1, 0))
        XCTAssertEqual(CategoryStats.summary(of: p, period: .today, asOf: rollover).status, .empty)
        XCTAssertEqual(CategoryStats.summary(of: p, period: .week, asOf: rollover).totalHours, 3, accuracy: 1e-12)
    }
}

/// Deterministic generator for the property tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
