import XCTest
@testable import Done

/// The widget's numbers ARE the Analysis tab's: for fixture calendars full of
/// the shapes the tab's accounting has rules for — overlaps, embedded and
/// detached interrupts, recurring series (one cross-midnight, one with an
/// interrupt carved from it), cross-midnight and multi-range events, empty
/// and literally-"Other" types, a running timer, a daylight-saving day — the
/// hours the widget reads back out of the written slices at an instant equal
/// `AnalysisViewModel.typeAllocations` pinned to that instant, to 1e-9 h,
/// for every period, at instants mid-event, exactly on boundaries, before the
/// payload's coverage and after it.
///
/// The payload goes through JSON first: what is compared is what the widget
/// would decode, not the builder's in-memory value.
///
/// The two controls at the end make a zero difference mean something: the
/// same comparison against a payload whose builder did not carve interrupts,
/// and against one that credits overlaps in full, must come out far from
/// zero.
@MainActor
final class CategoryStatsEquivalenceTests: XCTestCase {

    private struct Fixture {
        let name: String
        let calendar: Calendar
        let writtenAt: Date
        let events: [Event]
        /// Days whose every boundary gets an instant.
        let keyDays: [Date]
    }

    private static func calendar(_ zone: String, firstWeekday: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        cal.firstWeekday = firstWeekday
        cal.minimumDaysInFirstWeek = 1
        return cal
    }

    private static func ev(_ type: String, _ start: Date, _ end: Date, title: String? = nil) -> Event {
        Event(title: title ?? type, timeRanges: [.init(start: start, end: end)], type: type)
    }

    /// Minutes from the day's first instant: absolute, so a daylight-saving
    /// day's events land where the arithmetic says.
    private static func t(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
        day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    /// One day's worth of every per-day shape.
    private static func dayPattern(_ day: Date) -> [Event] {
        let parent = ev("Work", t(day, 13), t(day, 15), title: "Parent")
        return [
            ev("Work", t(day, 9), t(day, 11)),
            ev("Study", t(day, 10), t(day, 12)),
            ev("Work", t(day, 10, 30), t(day, 11, 30)),
            parent,
            Event(title: "Embedded", timeRanges: [.init(start: t(day, 13, 30), end: t(day, 14))], type: "Break",
                  interruptRelation: EventInterruptRelation(parentEventID: parent.id, occurrenceDate: t(day, 13, 30))),
            Event(title: "Detached", timeRanges: [.init(start: t(day, 14, 15), end: t(day, 14, 45))], type: "Call",
                  interruptRelation: EventInterruptRelation(parentEventID: parent.id, occurrenceDate: t(day, 14, 15),
                                                            state: .detached)),
            ev("", t(day, 16), t(day, 17)),
            ev("Other", t(day, 16, 30), t(day, 17, 30)),
            Event(title: "Two ranges", timeRanges: [.init(start: t(day, 19), end: t(day, 19, 30)),
                                                    .init(start: t(day, 20), end: t(day, 20, 45))], type: "Read"),
            ev("Sleep", t(day, 23), t(day, 31, 30)),
        ]
    }

    /// Series, an interrupt carved out of one series occurrence, an all-day
    /// event and an absorbed todo (both of which the tab leaves out).
    private static func sharedShapes(anchor: Date, calendar: Calendar) -> [Event] {
        let seriesDay = calendar.date(byAdding: .day, value: -10, to: anchor)!
        let exercise = Event(title: "Run", timeRanges: [.init(start: t(seriesDay, 7), end: t(seriesDay, 8))],
                             repeatUnit: .day, type: "Exercise")
        let weekly = Event(title: "Sync", timeRanges: [.init(start: t(seriesDay, 11), end: t(seriesDay, 12, 30))],
                           repeatUnit: .week, type: "Meeting")
        let night = Event(title: "Night", timeRanges: [.init(start: t(seriesDay, 22, 30), end: t(seriesDay, 24, 30))],
                          repeatUnit: .day, type: "Shift")
        let phone = Event(title: "Phone", timeRanges: [.init(start: t(anchor, 7, 20), end: t(anchor, 7, 35))],
                          type: "Call",
                          interruptRelation: EventInterruptRelation(parentEventID: exercise.id,
                                                                    occurrenceDate: t(anchor, 7, 20)))
        var allDay = ev("Holiday", anchor, calendar.date(byAdding: .day, value: 1, to: anchor)!.addingTimeInterval(-1))
        allDay.isAllDay = true
        var absorbed = ev("Absorbed", t(anchor, 9), t(anchor, 12))
        absorbed.kind = .todo
        absorbed.absorbedIntoEventID = UUID()
        return [exercise, weekly, night, phone, allDay, absorbed]
    }

    private static var fixtures: [Fixture] {
        var result: [Fixture] = []

        // Los Angeles, Sunday-first. Written Tuesday 3 November 2026; the
        // week and the month both open on Sunday the 1st, the 25-hour
        // fall-back day, and a sleep from the 31st runs into it.
        do {
            let cal = calendar("America/Los_Angeles", firstWeekday: 1)
            let day = { (d: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: m, day: d))! }
            let dst = day(1, 11), written = day(3, 11)
            var events = sharedShapes(anchor: written, calendar: cal)
            for d in [day(31, 10), dst, day(2, 11), written, day(4, 11), day(9, 11), day(12, 11), day(20, 10)] {
                events += dayPattern(d)
            }
            events.append(ev("Night owl", t(dst, 0, 30), t(dst, 3, 30)))
            result.append(Fixture(name: "LA fall-back", calendar: cal, writtenAt: t(written, 14, 20), events: events,
                                  keyDays: [dst, written, day(4, 11), day(9, 11)]))
        }

        // Berlin, Monday-first. Written Tuesday 31 March 2026: the week
        // (30 March - 5 April) crosses into April, the month began on the
        // 1st, the clocks went forward on Sunday the 29th. A timer has been
        // running since 09:40.
        do {
            let cal = calendar("Europe/Berlin", firstWeekday: 2)
            let day = { (d: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: m, day: d))! }
            let written = day(31, 3), spring = day(29, 3)
            var events = sharedShapes(anchor: written, calendar: cal)
            for d in [day(2, 3), spring, day(30, 3), written, day(1, 4), day(2, 4), day(6, 4), day(10, 4)] {
                events += dayPattern(d)
            }
            events.append(ev("Night owl", t(spring, 0, 30), t(spring, 3, 30)))
            let timerStart = t(written, 9, 40)
            events.append(Event(title: "Timer", timeRanges: [.init(start: timerStart, end: timerStart)],
                                type: "Deep Work", timerStartedAt: timerStart))
            result.append(Fixture(name: "Berlin spring, timer", calendar: cal, writtenAt: t(written, 10, 5),
                                  events: events, keyDays: [spring, written, day(1, 4), day(6, 4)]))
        }

        // UTC, Sunday-first. Written late on Saturday 31 October 2026: the
        // next morning is a new month AND a new week — read after the
        // boundary, from slices that were still plans when they were
        // written.
        do {
            let cal = calendar("UTC", firstWeekday: 1)
            let day = { (d: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: m, day: d))! }
            let written = day(31, 10)
            var events = sharedShapes(anchor: written, calendar: cal)
            for d in [day(25, 10), day(30, 10), written, day(1, 11), day(2, 11), day(6, 11)] {
                events += dayPattern(d)
            }
            result.append(Fixture(name: "UTC month turn", calendar: cal, writtenAt: t(written, 22), events: events,
                                  keyDays: [written, day(1, 11), day(2, 11)]))
        }
        return result
    }

    // MARK: harness

    private func makeStore(_ events: [Event]) -> EventStore {
        let suiteName = "CategoryStatsEquivalence-\(UUID().uuidString)"
        let store = EventStore(defaults: UserDefaults(suiteName: suiteName)!,
                               storage: .ephemeral(id: UUID()),
                               seedsSampleDataIfEmpty: false)
        store.rawCalendarEvents = events
        return store
    }

    private func writtenPayload(_ events: [Event], fixture: Fixture) throws -> CategoryStatsPayload {
        let built = CategoryStatsBuilder.payload(events: events, now: fixture.writtenAt,
                                                 calendar: fixture.calendar, colorHex: { _ in nil })
        return try JSONDecoder().decode(CategoryStatsPayload.self, from: JSONEncoder().encode(built))
    }

    private static func analysisPeriod(_ period: CategoryStatsPeriod) -> AnalysisPeriod {
        switch period {
        case .today: return .day
        case .week: return .week
        case .month: return .month
        }
    }

    private func analysisHours(_ store: EventStore, period: CategoryStatsPeriod, at instant: Date,
                               calendar: Calendar) -> [String: Double] {
        let vm = AnalysisViewModel(initialPeriod: Self.analysisPeriod(period), calendar: calendar)
        vm.now = { instant }
        vm.periodAnchor = { instant }
        return Dictionary(vm.typeAllocations(store: store).map { ($0.type, $0.hours) }, uniquingKeysWith: +)
    }

    private static func maxDifference(_ a: [String: Double], _ b: [String: Double]) -> Double {
        Set(a.keys).union(b.keys).map { abs((a[$0] ?? 0) - (b[$0] ?? 0)) }.max() ?? 0
    }

    /// Every boundary on the key days, a second either side of a few, the
    /// middle of each event; midnight and noon of every day the payload
    /// covers; the write instant; and the edges of the coverage.
    private func instants(_ fixture: Fixture, payload: CategoryStatsPayload) -> [Date] {
        let minutes = [0, 1, 7 * 60, 7 * 60 + 20, 7 * 60 + 27, 7 * 60 + 35, 8 * 60, 9 * 60, 10 * 60, 10 * 60 + 15,
                       10 * 60 + 30, 10 * 60 + 45, 11 * 60, 11 * 60 + 30, 12 * 60, 12 * 60 + 15, 13 * 60, 13 * 60 + 30,
                       13 * 60 + 45, 14 * 60, 14 * 60 + 15, 14 * 60 + 30, 14 * 60 + 45, 15 * 60, 16 * 60,
                       16 * 60 + 45, 17 * 60 + 30, 19 * 60 + 10, 20 * 60 + 30, 22 * 60 + 30, 23 * 60, 23 * 60 + 59]
        var result: [Date] = []
        for day in fixture.keyDays {
            for minute in minutes { result.append(day.addingTimeInterval(TimeInterval(minute * 60))) }
            for boundary in [9 * 60, 13 * 60 + 30, 14 * 60, 16 * 60 + 30] {
                result.append(day.addingTimeInterval(TimeInterval(boundary * 60) - 1))
                result.append(day.addingTimeInterval(TimeInterval(boundary * 60) + 1))
            }
        }
        let start = payload.coverageStart!, end = payload.coverageEnd!
        for day in CategoryStats.days(from: start, to: end, calendar: fixture.calendar) {
            let dayStart = fixture.calendar.startOfDay(for: day)
            result += [dayStart, dayStart.addingTimeInterval(12 * 3600)]
        }
        result += [fixture.writtenAt, fixture.writtenAt.addingTimeInterval(-1), fixture.writtenAt.addingTimeInterval(1),
                   start.addingTimeInterval(-3600), end.addingTimeInterval(-1), end, end.addingTimeInterval(86_400)]
        return result
    }

    // MARK: the test

    func testWidgetHoursEqualTheAnalysisTabAtEveryInstant() throws {
        for fixture in Self.fixtures {
            let store = makeStore(fixture.events)
            let payload = try writtenPayload(store.canvasRenderableCalendarEvents, fixture: fixture)
            XCTAssertEqual(payload.calendar?.timeZone, fixture.calendar.timeZone.identifier)

            var compared = 0, nonZero = 0, stale = 0
            for instant in instants(fixture, payload: payload) {
                for period in CategoryStatsPeriod.allCases {
                    let status = CategoryStats.status(of: payload, period: period, asOf: instant)
                    let range = CategoryStats.range(of: period, containing: instant, calendar: fixture.calendar)
                    let outside = instant >= payload.coverageEnd! || range.start < payload.coverageStart!
                    XCTAssertEqual(status == .stale, outside, "\(fixture.name) \(period) at \(instant)")
                    guard status != .stale else { stale += 1; continue }

                    let widget = CategoryStats.hours(in: payload, period: period, asOf: instant)
                    let analysis = analysisHours(store, period: period, at: instant, calendar: fixture.calendar)
                    let difference = Self.maxDifference(widget, analysis)
                    XCTAssertLessThanOrEqual(difference, 1e-9,
                                             "\(fixture.name) \(period) at \(instant): widget \(widget) vs tab \(analysis)")
                    XCTAssertEqual(status == .ok, analysis.values.reduce(0, +) > 0,
                                   "\(fixture.name) \(period) at \(instant): status \(status)")
                    compared += 1
                    if analysis.values.contains(where: { $0 > 0 }) { nonZero += 1 }
                }
            }
            // Not vacuous: most comparisons have time in them, and the edges
            // of the coverage were actually reached.
            XCTAssertGreaterThan(compared, 300, fixture.name)
            XCTAssertGreaterThan(nonZero, 250, fixture.name)
            XCTAssertGreaterThan(stale, 3, fixture.name)
        }
    }

    /// The fixtures contain what the comparison is meant to catch: at the
    /// end of the written day every category the pattern uses has time, and
    /// — where no timer runs over it — the carved interrupt has exactly its
    /// half hour.
    func testTheFixturesExerciseEveryRule() throws {
        for fixture in Self.fixtures {
            let store = makeStore(fixture.events)
            let endOfWritten = fixture.calendar.date(byAdding: .day, value: 1,
                                                     to: fixture.calendar.startOfDay(for: fixture.writtenAt))! - 1
            let today = analysisHours(store, period: .today, at: endOfWritten, calendar: fixture.calendar)
            for category in ["Work", "Study", "Break", "Call", "Other", "Read", "Sleep", "Exercise", "Shift"] {
                XCTAssertGreaterThan(today[category] ?? 0, 0, "\(fixture.name): \(category)")
            }
            if !fixture.events.contains(where: { $0.timerStartedAt != nil }) {
                XCTAssertEqual(today["Break"] ?? 0, 0.5, accuracy: 1e-9, "\(fixture.name): carved child")
            }
            XCTAssertNil(today["Holiday"], "all-day is left out")
            XCTAssertNil(today["Absorbed"], "absorbed todos are left out")
            XCTAssertNil(today[""], "untyped time is \"Other\"")
        }
    }

    /// A timer still running when the payload is written keeps counting at
    /// every later entry, as the tab — reading its clock then — would count
    /// it, whatever the wall clock said while the build ran. The fixture is
    /// years ahead of any clock this suite runs on, so a build that drew the
    /// timer to the wall clock would end it before it began.
    func testARunningTimerCountsUpToEachEntrysInstant() throws {
        let cal = Self.calendar("UTC", firstWeekday: 2)
        let day = cal.date(from: DateComponents(year: 2031, month: 5, day: 14))!
        let started = Self.t(day, 9)
        let timer = Event(title: "Timer", timeRanges: [.init(start: started, end: started)], type: "Deep Work",
                          timerStartedAt: started)
        let fixture = Fixture(name: "future timer", calendar: cal, writtenAt: Self.t(day, 9, 30),
                              events: [timer, Self.ev("Work", Self.t(day, 8), Self.t(day, 9))], keyDays: [day])
        let store = makeStore(fixture.events)
        let payload = try writtenPayload(store.canvasRenderableCalendarEvents, fixture: fixture)
        for hour in [10, 12, 17] {
            let instant = Self.t(day, hour)
            let widget = CategoryStats.hours(in: payload, period: .today, asOf: instant)
            XCTAssertEqual(widget["Deep Work"] ?? 0, Double(hour - 9), accuracy: 1e-9, "at \(hour):00")
            XCTAssertLessThanOrEqual(Self.maxDifference(widget, analysisHours(store, period: .today, at: instant,
                                                                                calendar: cal)), 1e-9)
        }
    }

    /// The exclusion is the Me tab's: with the list on, the widget's week is
    /// `ProfileHubAggregates.activeWeekHours` at the same instant — for the
    /// setting's default list, for a list naming the "Other" bucket in
    /// another case, and for one that leaves out most of the pattern. The
    /// control: with the list off, the totals differ wherever a background
    /// category has time.
    func testTheExcludedWeekIsTheMeTabsActiveHours() throws {
        let skills = SkillInsightStore(defaults: UserDefaults(suiteName: "CategoryStatsMe-\(UUID().uuidString)")!)
        for fixture in Self.fixtures {
            let store = makeStore(fixture.events)
            let built = try writtenPayload(store.canvasRenderableCalendarEvents, fixture: fixture)
            for raw in [AppSettingsKeys.meBackgroundTypesDefault, "WORK, other", "Study,Read,Sleep,Shift,Call,Exercise"] {
                let background = MeBackgroundTypes.parse(raw)
                var payload = built
                payload.backgroundCategories = background.sorted()
                var compared = 0, excludedSomething = 0
                for instant in instants(fixture, payload: payload) {
                    guard CategoryStats.status(of: payload, period: .week, asOf: instant) != .stale else { continue }
                    let vm = AnalysisViewModel(initialPeriod: .week, calendar: fixture.calendar)
                    vm.now = { instant }
                    vm.periodAnchor = { instant }
                    let me = ProfileHubAggregates.compute(
                        store: store, skillStore: skills, weekViewModel: vm, backgroundTypes: background,
                        visible: true, calendar: fixture.calendar, now: instant
                    ).activeWeekHours
                    let widget = CategoryStats.summary(of: payload, period: .week, asOf: instant, excludingBackground: true)
                    XCTAssertEqual(widget.status == .ok ? widget.totalHours : 0, me, accuracy: 1e-9,
                                   "\(fixture.name) \(raw) at \(instant)")
                    let everything = CategoryStats.summary(of: payload, period: .week, asOf: instant).totalHours
                    if everything - me > 1e-6 { excludedSomething += 1 }
                    compared += 1
                }
                XCTAssertGreaterThan(compared, 100, "\(fixture.name) \(raw)")
                XCTAssertGreaterThan(excludedSomething, 50, "\(fixture.name) \(raw): control, the list leaves time out")
            }
        }
    }

    /// The elapsed basis is the record rate: 100% less the unlogged row's
    /// share, before rounding, is `AnalysisViewModel.recordRate` for the same
    /// period at the same instant, to 1e-9 points — every period, every
    /// instant the payload can answer. The control: a share of the whole
    /// period instead of the elapsed part disagrees wherever the period is
    /// still running.
    func testTheElapsedBasisIsTheRecordRate() throws {
        for fixture in Self.fixtures {
            let store = makeStore(fixture.events)
            let payload = try writtenPayload(store.canvasRenderableCalendarEvents, fixture: fixture)
            var compared = 0, nonZero = 0, controlMisses = 0
            for instant in instants(fixture, payload: payload) {
                for period in CategoryStatsPeriod.allCases {
                    let summary = CategoryStats.summary(of: payload, period: period, asOf: instant, basis: .elapsed)
                    guard summary.status == .ok else { continue }
                    let rows = CategoryStats.breakdown(summary.categories, maxRows: CategoryStatsLayout.rowCap(.small),
                                                       unlogged: summary.unloggedHours)
                    let unlogged = try XCTUnwrap(rows.last)
                    XCTAssertEqual(unlogged.kind, .unlogged)
                    let vm = AnalysisViewModel(initialPeriod: Self.analysisPeriod(period), calendar: fixture.calendar)
                    vm.now = { instant }
                    vm.periodAnchor = { instant }
                    let rate = vm.recordRate(store: store)
                    XCTAssertEqual((1 - unlogged.share) * 100, rate, accuracy: 1e-9,
                                   "\(fixture.name) \(period) at \(instant)")
                    let range = CategoryStats.range(of: period, containing: instant, calendar: fixture.calendar)
                    let whole = range.end.timeIntervalSince(range.start) / 3600
                    if abs(summary.totalHours / whole * 100 - rate) > 1e-6 { controlMisses += 1 }
                    compared += 1
                    if rate > 0 { nonZero += 1 }
                }
            }
            XCTAssertGreaterThan(compared, 300, fixture.name)
            XCTAssertGreaterThan(nonZero, 250, fixture.name)
            XCTAssertGreaterThan(controlMisses, 250, "\(fixture.name): control, the whole period is another number")
        }
    }

    // MARK: reuse

    /// A payload built on another one's days — built from the same events in
    /// the same calendar at another instant — is the payload a full build
    /// makes, byte for byte: a day later, two and six days later, across a
    /// month and week boundary, across the fall-back day, and backwards.
    /// Only the days the other one lacks are built. The control: built on a
    /// payload from other events, it is not the full build, so the days
    /// really are taken from the one given.
    func testAPayloadBuiltOnAnotherOnesDaysIsTheFullBuild() throws {
        var extended = 0
        for fixture in Self.fixtures {
            let events = makeStore(fixture.events).canvasRenderableCalendarEvents
            func build(_ now: Date, reusing previous: CategoryStatsPayload? = nil, _ from: [Event]? = nil) -> CategoryStatsPayload {
                CategoryStatsBuilder.payload(events: from ?? events, now: now, calendar: fixture.calendar,
                                             colorHex: { "#\($0.count)" }, reusing: previous)
            }
            let base = fixture.writtenAt
            for days in [1, 2, 6, -1, 8] {
                let later = base.addingTimeInterval(TimeInterval(days) * 86_400)
                let previous = build(base)
                let full = build(later)
                XCTAssertEqual(build(later, reusing: previous), full, "\(fixture.name) \(days) days on")
                let coverage = CategoryStatsBuilder.coverage(now: later, calendar: fixture.calendar)
                let before = CategoryStatsBuilder.coverage(now: base, calendar: fixture.calendar)
                let fresh = CategoryStats.days(from: coverage.start, to: coverage.end, calendar: fixture.calendar)
                    .filter { $0 < before.start || $0 >= before.end }.count
                XCTAssertEqual(CategoryStatsBuilder.daysToBuild(now: later, calendar: fixture.calendar, reusing: previous),
                               fresh, "\(fixture.name) \(days) days on")
                if days == 1 { XCTAssertEqual(fresh, 1, "\(fixture.name): a new day builds one day") }
                extended += 1
            }
            let other = build(base, reusing: nil, [Self.ev("Elsewhere", Self.t(fixture.keyDays[0], 9), Self.t(fixture.keyDays[0], 10))])
            XCTAssertNotEqual(build(base.addingTimeInterval(86_400), reusing: other), build(base.addingTimeInterval(86_400)),
                              "\(fixture.name): control")
            var otherFrame = fixture.calendar
            otherFrame.firstWeekday = fixture.calendar.firstWeekday == 1 ? 2 : 1
            XCTAssertEqual(CategoryStatsBuilder.daysToBuild(now: base, calendar: otherFrame, reusing: build(base)),
                           CategoryStats.days(from: CategoryStatsBuilder.coverage(now: base, calendar: otherFrame).start,
                                              to: CategoryStatsBuilder.coverage(now: base, calendar: otherFrame).end,
                                              calendar: otherFrame).count,
                           "\(fixture.name): a payload cut in another calendar is not reused")
        }
        XCTAssertEqual(extended, 15)
    }

    // MARK: controls

    /// A builder that skipped the interrupt carving — fed the same events
    /// with every embedded relation made detached, which the carving ignores
    /// — must disagree with the tab on each key day: by a quarter hour where
    /// the interrupt's half hour is shared with its parent alone, by ten
    /// minutes where the running timer is a third party to it.
    func testControlUncarvedSlicesDisagree() throws {
        for fixture in Self.fixtures {
            let store = makeStore(fixture.events)
            let uncarved = store.canvasRenderableCalendarEvents.map { event -> Event in
                var copy = event
                if copy.interruptRelation?.state == .embedded { copy.interruptRelation?.state = .detached }
                return copy
            }
            let payload = try writtenPayload(uncarved, fixture: fixture)
            for day in fixture.keyDays {
                let instant = day.addingTimeInterval(15 * 3600)
                guard CategoryStats.status(of: payload, period: .today, asOf: instant) != .stale else { continue }
                let difference = Self.maxDifference(
                    CategoryStats.hours(in: payload, period: .today, asOf: instant),
                    analysisHours(store, period: .today, at: instant, calendar: fixture.calendar)
                )
                XCTAssertGreaterThanOrEqual(difference, 0.16, "\(fixture.name) \(day): uncarved went unnoticed")
            }
        }
    }

    /// Slices that credit every covering occurrence the whole slice instead
    /// of 1/n must disagree by at least half an hour on each key day.
    func testControlUnsharedOverlapsDisagree() throws {
        for fixture in Self.fixtures {
            let store = makeStore(fixture.events)
            var payload = try writtenPayload(store.canvasRenderableCalendarEvents, fixture: fixture)
            for d in payload.days!.indices {
                for s in payload.days![d].slices!.indices { payload.days![d].slices![s].n = 1 }
            }
            for day in fixture.keyDays {
                let instant = day.addingTimeInterval(15 * 3600)
                guard CategoryStats.status(of: payload, period: .today, asOf: instant) != .stale else { continue }
                let difference = Self.maxDifference(
                    CategoryStats.hours(in: payload, period: .today, asOf: instant),
                    analysisHours(store, period: .today, at: instant, calendar: fixture.calendar)
                )
                XCTAssertGreaterThanOrEqual(difference, 0.5, "\(fixture.name) \(day): full credit went unnoticed")
            }
        }
    }

    // MARK: the payload's own shape

    /// Coverage is this week's and this month's earlier start to the end of
    /// the occurrence window; days are civil days of the calendar; slices
    /// never overlap within a day, and adjacent ones never credit the same.
    func testPayloadShape() throws {
        for fixture in Self.fixtures {
            let store = makeStore(fixture.events)
            let payload = try writtenPayload(store.canvasRenderableCalendarEvents, fixture: fixture)
            let cal = fixture.calendar
            let week = CategoryStats.range(of: .week, containing: fixture.writtenAt, calendar: cal)
            let month = CategoryStats.range(of: .month, containing: fixture.writtenAt, calendar: cal)
            let threeDays = WristStatsPeriod.threeDays.span(asOf: fixture.writtenAt, calendar: cal)
            XCTAssertEqual(payload.coverageStart, min(week.start, month.start, threeDays.start), fixture.name)
            XCTAssertEqual(payload.coverageEnd, WidgetSnapshotBuilder.window(now: fixture.writtenAt, calendar: cal).end)
            XCTAssertEqual(payload.version, CategoryStatsPayload.currentVersion)
            XCTAssertEqual(payload.writtenAt, fixture.writtenAt)
            XCTAssertEqual(payload.categories?.compactMap(\.name), payload.categories?.compactMap(\.name).sorted(),
                           "category order is by name, so event order cannot churn the bytes")
            for day in payload.days! {
                XCTAssertEqual(day.start, cal.startOfDay(for: day.start!))
                let dayEnd = cal.date(byAdding: .day, value: 1, to: day.start!)!
                for (a, b) in zip(day.slices!, day.slices!.dropFirst()) {
                    XCTAssertLessThanOrEqual(a.end!, b.start!)
                    XCTAssertFalse(a.end == b.start && a.n == b.n && a.categoryIndices == b.categoryIndices
                                   && a.counts == b.counts, "unmerged twins")
                }
                for slice in day.slices! {
                    XCTAssertGreaterThanOrEqual(slice.start!, day.start!)
                    XCTAssertLessThanOrEqual(slice.end!, dayEnd)
                    XCTAssertEqual(slice.counts!.reduce(0, +), slice.n!)
                }
            }
        }
    }

    /// Reordering the store's events changes nothing the widget can see.
    func testEventOrderDoesNotChangeThePayload() throws {
        let fixture = Self.fixtures[0]
        let a = CategoryStatsBuilder.payload(events: fixture.events, now: fixture.writtenAt,
                                             calendar: fixture.calendar, colorHex: { _ in nil })
        let b = CategoryStatsBuilder.payload(events: fixture.events.reversed(), now: fixture.writtenAt,
                                             calendar: fixture.calendar, colorHex: { _ in nil })
        XCTAssertEqual(a, b)
    }
}
