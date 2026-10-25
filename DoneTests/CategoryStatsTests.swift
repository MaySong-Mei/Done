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

    /// Each period moves by its offset, against hand-written calendars: the
    /// Analysis tab's previous and next arrows walk days, weeks and months
    /// through this function, and the delegation test below compares it only
    /// with itself.
    @MainActor
    func testEachPeriodMovesByItsOffset() {
        let la = calendar("America/Los_Angeles")
        let fallBack = date(la, 2026, 11, 1, 12)
        let yesterday = CategoryStats.range(of: .today, containing: fallBack, offset: -1, calendar: la)
        XCTAssertEqual(yesterday.start, date(la, 2026, 10, 31))
        XCTAssertEqual(yesterday.end, date(la, 2026, 11, 1))
        let twoOn = CategoryStats.range(of: .today, containing: fallBack, offset: 2, calendar: la)
        XCTAssertEqual(twoOn.start, date(la, 2026, 11, 3))
        XCTAssertEqual(twoOn.end, date(la, 2026, 11, 4))
        let lastWeek = CategoryStats.range(of: .week, containing: fallBack, offset: -1, calendar: la)
        XCTAssertEqual(lastWeek.start, date(la, 2026, 10, 25))
        XCTAssertEqual(lastWeek.end, date(la, 2026, 11, 1))
        let nextMonth = CategoryStats.range(of: .month, containing: fallBack, offset: 1, calendar: la)
        XCTAssertEqual(nextMonth.start, date(la, 2026, 12, 1))
        XCTAssertEqual(nextMonth.end, date(la, 2027, 1, 1))
    }

    /// The elapsed span is the Analysis tab's: `Event.elapsedWindowCut` over
    /// the period, in hours — from nothing at the first instant to the whole
    /// period, a daylight-saving day's 25 hours included.
    @MainActor
    func testTheElapsedSpanIsTheTabsCut() {
        let la = calendar("America/Los_Angeles")
        for instant in [date(la, 2026, 11, 1), date(la, 2026, 11, 1, 0, 30), date(la, 2026, 11, 1, 23, 59),
                        date(la, 2026, 11, 4, 9), date(la, 2026, 11, 30, 23)] {
            for period in CategoryStatsPeriod.allCases {
                let range = CategoryStats.range(of: period, containing: instant, calendar: la)
                let tab = Event.elapsedWindowCut(windowStart: range.start, windowEnd: range.end, asOf: instant)
                    .timeIntervalSince(range.start) / 3600
                XCTAssertEqual(CategoryStats.elapsedHours(of: period, asOf: instant, calendar: la), tab, "\(period) \(instant)")
            }
        }
        XCTAssertEqual(CategoryStats.elapsedHours(of: .today, asOf: date(la, 2026, 11, 1), calendar: la), 0)
        XCTAssertEqual(CategoryStats.elapsedHours(of: .today, asOf: date(la, 2026, 11, 1, 23, 59), calendar: la),
                       24 + 59.0 / 60, accuracy: 1e-9, "the fall-back day has an hour more")
        XCTAssertEqual(CategoryStats.elapsedCut(windowStart: date(la, 2026, 11, 2), windowEnd: date(la, 2026, 11, 3),
                                                asOf: date(la, 2026, 11, 1)), date(la, 2026, 11, 2))
        XCTAssertEqual(CategoryStats.elapsedCut(windowStart: date(la, 2026, 11, 2), windowEnd: date(la, 2026, 11, 3),
                                                asOf: date(la, 2026, 11, 5)), date(la, 2026, 11, 3))
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
        let one = CategoryStatsRow(kind: .category(rank: 0), name: "x", hours: 1, share: 0.012, percent: 1)
        XCTAssertEqual(one.percentText, "1%", "a point is a point: only time that rounds to nothing reads \"<1%\"")
        let two = CategoryStatsRow(kind: .unlogged, name: "", hours: 2, share: 0.02, percent: 2)
        XCTAssertEqual(two.percentText, "2%")
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

    /// The small face's cap: four categories are four rows; a fifth folds the
    /// fourth and fifth into one count row behind three leaders.
    @MainActor
    func testTheSmallFaceListsFourAndFoldsTheFifth() {
        let cap = CategoryStatsLayout.rowCap(.small)
        let four = CategoryStats.breakdown(Array(five.prefix(4)), maxRows: cap)
        XCTAssertEqual(four.map(\.name), ["Deep Work", "Meetings", "Exercise", "Reading"])
        XCTAssertFalse(four.contains { $0.isRemainder })
        XCTAssertEqual(four.map(\.percent).reduce(0, +), 100)

        let folded = CategoryStats.breakdown(five, maxRows: cap)
        XCTAssertEqual(folded.prefix(3).map(\.name), ["Deep Work", "Meetings", "Exercise"])
        XCTAssertEqual(folded.map(\.kind).last, .remainder(count: 2))
        XCTAssertEqual(folded.last?.hours ?? 0, 3, accuracy: 1e-12)
        XCTAssertEqual(folded.map(\.percent).reduce(0, +), 100)
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

// MARK: - The elapsed basis and the background list

final class CategoryStatsBasisTests: XCTestCase {
    private let five: [CategoryHours] = [
        CategoryHours(name: "Deep Work", colorHex: "#111111", hours: 13.6),
        CategoryHours(name: "Meetings", colorHex: "#222222", hours: 8.1),
        CategoryHours(name: "Exercise", colorHex: "#333333", hours: 3.25),
        CategoryHours(name: "Reading", colorHex: "#444444", hours: 2),
        CategoryHours(name: "Chores", colorHex: "#555555", hours: 1),
    ]

    /// The unlogged row is the last row of every face and is counted in its
    /// cap; the shares are of the elapsed span; with it the rows sum to 100.
    /// 62 hours in, 27.95 logged: Deep Work 21.9%, Meetings 13.1%, the rest
    /// 10.1% (or, on the lock screen, left out), unlogged 54.9%.
    @MainActor
    func testTheUnloggedRowTakesTheLastRowOfEveryCap() {
        let unlogged = 62 - five.reduce(0) { $0 + $1.hours }
        let small = CategoryStats.breakdown(five, maxRows: CategoryStatsLayout.rowCap(.small), unlogged: unlogged)
        XCTAssertEqual(small.map(\.kind), [.category(rank: 0), .category(rank: 1), .remainder(count: 3), .unlogged])
        XCTAssertEqual(small.map(\.percent), [22, 13, 10, 55])
        let medium = CategoryStats.breakdown(five, maxRows: CategoryStatsLayout.rowCap(.medium), unlogged: unlogged)
        XCTAssertEqual(medium.map(\.kind), [.category(rank: 0), .category(rank: 1), .category(rank: 2),
                                            .remainder(count: 2), .unlogged])
        let lock = CategoryStats.breakdown(five, maxRows: CategoryStatsLayout.rowCap(.rectangular),
                                           includeRemainder: false, unlogged: unlogged)
        XCTAssertEqual(lock.map(\.kind), [.category(rank: 0), .unlogged])
        XCTAssertEqual(lock.map(\.percent), [22, 55], "rounded with the categories it leaves out")
        for rows in [small, medium] {
            XCTAssertEqual(rows.map(\.percent).reduce(0, +), 100)
            XCTAssertEqual(rows.map(\.share).reduce(0, +), 1, accuracy: 1e-12)
            XCTAssertEqual(rows.last?.hours ?? 0, unlogged, accuracy: 1e-12)
            XCTAssertEqual(rows[0].share, 13.6 / 62, accuracy: 1e-12, "a share of the elapsed span")
        }
        let three = CategoryStats.breakdown(Array(five.prefix(3)), maxRows: CategoryStatsLayout.rowCap(.small), unlogged: 10)
        XCTAssertEqual(three.map(\.kind), [.category(rank: 0), .category(rank: 1), .category(rank: 2), .unlogged],
                       "three categories and the unlogged row fill the small face's four")
    }

    /// Nothing logged: one row, "Unlogged 100%". Logged to the minute: the
    /// unlogged row stays, at 0%. Nothing elapsed: no rows at all.
    @MainActor
    func testTheEdgesOfTheElapsedBasis() {
        let nothing = CategoryStats.breakdown([], maxRows: 4, unlogged: 14)
        XCTAssertEqual(nothing.map(\.kind), [.unlogged])
        XCTAssertEqual(nothing.first?.percent, 100)
        XCTAssertEqual(nothing.first?.share, 1)
        let full = CategoryStats.breakdown(Array(five.prefix(2)), maxRows: 4, unlogged: 0)
        XCTAssertEqual(full.map(\.kind), [.category(rank: 0), .category(rank: 1), .unlogged])
        XCTAssertEqual(full.last?.percentText, "0%")
        XCTAssertEqual(full.map(\.percent).reduce(0, +), 100)
        XCTAssertTrue(CategoryStats.breakdown([], maxRows: 4, unlogged: 0).isEmpty)
        XCTAssertTrue(CategoryStats.breakdown([], maxRows: 4).isEmpty, "the logged basis has no unlogged row")
        XCTAssertEqual(CategoryStats.breakdown(five, maxRows: 1, unlogged: 5).map(\.kind), [.unlogged],
                       "one row is the unlogged one")
    }

    /// Seeded random vectors: with the unlogged row, every face that keeps a
    /// remainder sums to exactly 100, and no row is more than a point off its
    /// exact share of the elapsed span.
    @MainActor
    func testRandomElapsedRowsSumToOneHundred() {
        var rng = SplitMix(seed: 0xE1A)
        var checked = 0
        for _ in 0..<1500 {
            let count = Int(rng.next() % 8)
            let categories = (0..<count).map { CategoryHours(name: "C\($0)", hours: Double(rng.next() % 5_000) / 100 + 0.01) }
            let unlogged = Double(rng.next() % 10_000) / 100
            let total = categories.reduce(0) { $0 + $1.hours } + unlogged
            guard total > 0 else { continue }
            for cap in 3...6 {
                let rows = CategoryStats.breakdown(CategoryStats.ranked(Dictionary(uniqueKeysWithValues:
                    categories.map { ($0.name, $0.hours) })), maxRows: cap, unlogged: unlogged)
                XCTAssertEqual(rows.map(\.percent).reduce(0, +), 100, "\(categories) \(unlogged) cap \(cap)")
                XCTAssertEqual(rows.last?.kind, .unlogged)
                XCTAssertLessThanOrEqual(rows.count, cap)
                for row in rows {
                    XCTAssertLessThan(abs(Double(row.percent) - row.hours / total * 100), 1)
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 5000)
    }

    /// A face that leaves categories out — the lock screen's ring and
    /// rectangle — shows each row's own share rounded to the nearest point.
    /// Rounded together with the hidden rest, the leader of 66.4% beside a
    /// hidden 16.3% and 17.3% unlogged took the point the others were owed
    /// and read 67%, and an A of 33.4% beside a hidden B of 33.3% read 34%.
    @MainActor
    func testAFaceThatLeavesRowsOutShowsEachRowsNearestPercent() {
        func elapsed(_ hours: [Double], unlogged: Double) -> CategoryStatsSummary {
            let categories = hours.enumerated().map { CategoryHours(name: "C\($0)", hours: $1) }
            return CategoryStatsSummary(period: .today, basis: .elapsed, status: .ok, categories: categories,
                                        totalHours: hours.reduce(0, +), elapsedHours: hours.reduce(0, +) + unlogged)
        }
        let leads = elapsed([66.4, 16.3], unlogged: 17.3)
        XCTAssertEqual(CategoryStatsLayout.ringLeader(leads)?.percentText, "66%")
        XCTAssertEqual(CategoryStatsLayout.ringLeader(leads)?.share ?? 0, 0.664, accuracy: 1e-12)
        XCTAssertEqual(CategoryStats.breakdown(leads.categories, maxRows: CategoryStatsLayout.rowCap(.rectangular),
                                               includeRemainder: false, unlogged: leads.unloggedHours).map(\.percent),
                       [66, 17])
        let thirds = elapsed([33.4, 33.3], unlogged: 33.3)
        XCTAssertEqual(CategoryStatsLayout.ringLeader(thirds)?.percentText, "33%")
        XCTAssertEqual(CategoryStats.breakdown(thirds.categories, maxRows: CategoryStatsLayout.rowCap(.rectangular),
                                               includeRemainder: false, unlogged: thirds.unloggedHours).map(\.percent),
                       [33, 33])
        // Rows that account for all the time still round together to 100.
        let small = CategoryStats.breakdown(thirds.categories, maxRows: CategoryStatsLayout.rowCap(.small),
                                            unlogged: thirds.unloggedHours)
        XCTAssertEqual(small.map(\.percent), [34, 33, 33])
    }

    /// Seeded random vectors, both bases, every cap a face uses and a few
    /// more: when the rows drawn leave categories out, each row's percent is
    /// its share rounded to the nearest point; otherwise they sum to 100.
    /// Rounding the left-out rows with the rest would miss on some of these
    /// (counted, as the positive control).
    @MainActor
    func testRandomLeftOutRowsAreEachTheirNearestPoint() {
        var rng = SplitMix(seed: 0x5EA)
        var hidden = 0, wouldMiss = 0, whole = 0
        for _ in 0..<1500 {
            let count = 1 + Int(rng.next() % 7)
            let categories = CategoryStats.ranked(Dictionary(uniqueKeysWithValues: (0..<count).map {
                ("C\($0)", Double(rng.next() % 5_000) / 100 + 0.01)
            }))
            let unlogged: Double? = rng.next() % 2 == 0 ? nil : Double(rng.next() % 10_000) / 100
            let total = categories.reduce(0) { $0 + $1.hours } + (unlogged ?? 0)
            for cap in 1...6 {
                for includeRemainder in [false, true] {
                    let rows = CategoryStats.breakdown(categories, maxRows: cap, includeRemainder: includeRemainder,
                                                       unlogged: unlogged)
                    guard !rows.isEmpty else { continue }
                    let accounted = rows.reduce(0) { sum, row in
                        switch row.kind {
                        case .category: return sum + 1
                        case .remainder(let count): return sum + count
                        case .unlogged: return sum
                        }
                    }
                    if accounted < categories.count {
                        for row in rows {
                            XCTAssertEqual(row.percent, Int((row.hours / total * 100).rounded()),
                                           "\(categories.map(\.hours)) \(String(describing: unlogged)) cap \(cap)")
                        }
                        let together = CategoryStats.percents(rows.map(\.hours) + [total - rows.reduce(0) { $0 + $1.hours }])
                        if zip(rows, together).contains(where: { $0.percent != $1 }) { wouldMiss += 1 }
                        hidden += 1
                    } else {
                        XCTAssertEqual(rows.map(\.percent).reduce(0, +), 100)
                        whole += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(hidden, 1000)
        XCTAssertGreaterThan(whole, 1000)
        XCTAssertGreaterThan(wouldMiss, 0, "positive control: rounding with the rest differs somewhere")
        print("left-out rows: \(hidden) breakdowns, \(wouldMiss) of which rounding with the rest would change; "
              + "\(whole) whole breakdowns")
    }

    // MARK: summaries

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

    @MainActor
    private func payload(background: [String]?) throws -> CategoryStatsPayload {
        var payload = try JSONDecoder().decode(CategoryStatsPayload.self, from: Data(CategoryStatsFixtures.roundOnePayload.utf8))
        payload.backgroundCategories = background
        return payload
    }

    /// The elapsed basis's summary carries the span: ok from the first
    /// moment after the period starts, logged or not; empty only at that
    /// first instant. The hours are the same either way.
    @MainActor
    func testTheElapsedSummary() throws {
        let p = try payload(background: nil)
        let midMorning = CategoryStats.summary(of: p, period: .today, asOf: at(0, 10.5), basis: .elapsed)
        XCTAssertEqual(midMorning.status, .ok)
        XCTAssertEqual(midMorning.elapsedHours, 10.5, accuracy: 1e-12)
        XCTAssertEqual(midMorning.totalHours, 2.5, accuracy: 1e-12)
        XCTAssertEqual(midMorning.unloggedHours ?? -1, 8, accuracy: 1e-12)
        let logged = CategoryStats.summary(of: p, period: .today, asOf: at(0, 10.5))
        XCTAssertEqual(logged.categories, midMorning.categories)
        XCTAssertNil(logged.unloggedHours)
        XCTAssertEqual(logged.elapsedHours, 0)

        let early = CategoryStats.summary(of: p, period: .today, asOf: at(0, 7), basis: .elapsed)
        XCTAssertEqual(early.status, .ok, "seven hours elapsed, nothing logged: all of it unlogged")
        XCTAssertEqual(early.categories, [])
        XCTAssertEqual(CategoryStats.breakdown(early.categories, maxRows: 4, unlogged: early.unloggedHours)
            .map(\.percent), [100])
        XCTAssertEqual(CategoryStats.summary(of: p, period: .today, asOf: at(0, 7)).status, .empty,
                       "the logged basis has nothing to show")
        XCTAssertEqual(CategoryStats.summary(of: p, period: .today, asOf: at(0, 0), basis: .elapsed).status, .empty,
                       "nothing has elapsed at the period's first instant")
        let week = CategoryStats.summary(of: p, period: .week, asOf: at(1, 9.5), basis: .elapsed)
        XCTAssertEqual(week.elapsedHours, 33.5, accuracy: 1e-12)
        XCTAssertEqual(CategoryStats.summary(of: p, options: CategoryStatsOptions(period: .week, basis: .elapsed),
                                             asOf: at(1, 9.5)), week)
    }

    /// With the list, the background categories are left out of the total
    /// and the percents, and their part of a slice they shared stays out —
    /// Work keeps its half of the hour it split with Sleep, nothing more.
    /// Matched without regard to case. Every logged hour background: empty.
    @MainActor
    func testTheExclusionLeavesOutTheBackgroundAndHandsNothingOn() throws {
        let p = try payload(background: ["sleep"])
        let all = CategoryStats.summary(of: p, period: .today, asOf: at(0, 12))
        XCTAssertEqual(all.categories.map(\.name), ["Sleep", "Work"], "off by default")
        XCTAssertEqual(all.totalHours, 4, accuracy: 1e-12)
        let active = CategoryStats.summary(of: p, period: .today, asOf: at(0, 12), excludingBackground: true)
        XCTAssertEqual(active.status, .ok)
        XCTAssertEqual(active.categories.map(\.name), ["Work"])
        XCTAssertEqual(active.totalHours, 1.5, accuracy: 1e-12, "half of 10-11 and all of 11-12; not the whole shared hour")
        XCTAssertEqual(CategoryStats.breakdown(active.categories, maxRows: 4).map(\.percent), [100])

        XCTAssertEqual(CategoryStats.summary(of: p, period: .today, asOf: at(0, 10), excludingBackground: true).status,
                       .empty, "only Sleep by ten: every logged hour is background")
        let both = try payload(background: ["sleep", "work"])
        XCTAssertEqual(CategoryStats.status(of: both, period: .today, asOf: at(0, 12), excludingBackground: true), .empty)

        let elapsed = CategoryStats.summary(of: p, period: .today, asOf: at(0, 12), basis: .elapsed,
                                            excludingBackground: true)
        XCTAssertEqual(elapsed.categories.map(\.name), ["Sleep", "Work"], "the elapsed basis keeps everything")
        XCTAssertEqual(elapsed.totalHours, 4, accuracy: 1e-12)
    }

    /// A payload as round one wrote it, from before the list existed,
    /// decodes and reads as it always did; with the option on it asks for a
    /// refresh rather than guess which hours to leave out.
    @MainActor
    func testAPayloadFromBeforeTheBackgroundListStillReads() throws {
        let p = try payload(background: nil)
        XCTAssertNil(p.backgroundCategories)
        XCTAssertEqual(p.categories?.compactMap(\.name), ["Sleep", "Work"])
        let off = CategoryStats.summary(of: p, period: .today, asOf: at(0, 12))
        XCTAssertEqual(off.status, .ok)
        XCTAssertEqual(off.totalHours, 4, accuracy: 1e-12)
        XCTAssertEqual(CategoryStats.summary(of: p, period: .today, asOf: at(0, 12), excludingBackground: true).status,
                       .stale)
        XCTAssertEqual(CategoryStats.summary(of: p, period: .today, asOf: at(0, 12), basis: .elapsed,
                                             excludingBackground: true).status, .ok)
        // Round-tripped through the current encoder, the list is all it gains.
        let again = try JSONDecoder().decode(CategoryStatsPayload.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(again, p)
    }

    /// The matching rule is the Me tab's own (`MeBackgroundTypes`, now in
    /// the file both targets compile): trimmed, lowercased, empty pieces
    /// dropped, and the setting's default list when the user never set one.
    @MainActor
    func testTheListIsParsedTheMeTabsWay() {
        XCTAssertEqual(MeBackgroundTypes.parse(" Sleep , REST , ,commute ,"), ["sleep", "rest", "commute"])
        XCTAssertTrue(MeBackgroundTypes.contains("Sleep", in: ["sleep"]))
        XCTAssertFalse(MeBackgroundTypes.contains("Sleepy", in: ["sleep"]))
        XCTAssertTrue(MeBackgroundTypes.parse(AppSettingsKeys.meBackgroundTypesDefault).isSuperset(of: ["sleep", "睡眠", "通勤"]))
    }
}

/// Fixtures more than one suite reads.
enum CategoryStatsFixtures {
    /// A payload exactly as round one's encoder wrote it (no background
    /// list): Monday 19 October 2026 UTC, Sleep 08-10 alone, 10-11 shared
    /// with Work, Work 11-12. Dates are seconds since 2001.
    static let roundOnePayload = """
    {"version":1,"writtenAt":814089600,"coverageStart":813456000,"coverageEnd":815270400,\
    "calendar":{"identifier":"gregorian","timeZone":"UTC","firstWeekday":2,"minimumDaysInFirstWeek":1},\
    "categories":[{"name":"Sleep","colorHex":"#5E5CE6"},{"name":"Work","colorHex":"#FF9F0A"}],\
    "days":[{"d":814060800,"s":[{"s":814089600,"e":814096800,"n":1,"c":[0],"k":[1]},\
    {"s":814096800,"e":814100400,"n":2,"c":[0,1],"k":[1,1]},\
    {"s":814100400,"e":814104000,"n":1,"c":[1],"k":[1]}]}]}
    """
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
