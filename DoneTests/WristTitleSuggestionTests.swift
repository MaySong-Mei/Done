import XCTest
@testable import Done

/// Names offered on the watch for a new block: what the phone learns from
/// history, how the watch ranks it for a drawn range, and the start
/// command's optional title across phone and watch versions.
@MainActor
final class WristTitleSuggestionTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// 2026-03-10 10:00 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 10))!
    }

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: dayOffset, to: now)!)
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start)!
    }

    private func event(_ title: String, _ type: String, _ start: Date, minutes: Int) -> Event {
        Event(title: title, timeRanges: [.init(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))], type: type)
    }

    private func types(_ titles: String...) -> [WristType] {
        titles.map { WristType(id: UUID(), title: $0, colorHex: "#0A84FF") }
    }

    private func hint(_ title: String, weight: Double = 10, at minute: Int, concentration: Int = 95, minutes: Int) -> WristTitleHint {
        WristTitleHint(title: title, weight: weight, startMinute: minute, concentration: concentration, minutes: minutes)
    }

    private func rank(_ hints: [WristTitleHint], from: (Int, Int), to: (Int, Int)) -> [String] {
        WristTitleRanking.rank(hints, start: at(0, from.0, from.1), end: at(0, to.0, to.1), calendar: calendar, limit: 10)
    }

    // MARK: Ranking (watch)

    private var work: [WristTitleHint] {
        [
            hint("Review", at: 14 * 60, minutes: 60),
            hint("Deep work", at: 9 * 60, minutes: 150),
            hint("Standup", at: 9 * 60, minutes: 15),
        ]
    }

    func testShortMorningBlockIsTheStandup() {
        XCTAssertEqual(rank(work, from: (9, 0), to: (9, 15)).first, "Standup")
    }

    func testLongMorningBlockIsDeepWork() {
        XCTAssertEqual(rank(work, from: (9, 0), to: (12, 0)).first, "Deep work")
    }

    func testAfternoonHourIsTheReview() {
        XCTAssertEqual(rank(work, from: (14, 0), to: (15, 0)).first, "Review")
        XCTAssertEqual(rank(work, from: (13, 30), to: (14, 45)).first, "Review")
    }

    /// The control for the three above: with time and length uninformative
    /// (nobody's shape matches), the most used name leads.
    func testWithoutAContextMatchTheMostUsedLeads() {
        let hints = [
            hint("Rare", weight: 2, at: 9 * 60, minutes: 30),
            hint("Often", weight: 20, at: 9 * 60, minutes: 30),
        ]
        XCTAssertEqual(rank(hints, from: (9, 0), to: (9, 30)), ["Often", "Rare"])
    }

    func testAGoodFitBeatsAFewMoreUses() {
        let hints = [
            hint("Evening run", weight: 6, at: 19 * 60, minutes: 45),
            hint("Morning run", weight: 4, at: 7 * 60, minutes: 45),
        ]
        XCTAssertEqual(rank(hints, from: (7, 0), to: (7, 45)).first, "Morning run")
        XCTAssertEqual(rank(hints, from: (19, 0), to: (19, 45)).first, "Evening run")
    }

    func testStartTimeWrapsAroundMidnight() {
        let hints = [
            hint("Noon thing", at: 12 * 60, minutes: 60),
            hint("Late reading", at: 23 * 60 + 45, minutes: 60),
        ]
        XCTAssertEqual(rank(hints, from: (0, 15), to: (1, 15)).first, "Late reading")
    }

    func testAnAnyTimeNameIsNotPunishedForTheHour() {
        // "Email" happens any time (low concentration); "Lunch" is always noon.
        let hints = [
            hint("Lunch", weight: 10, at: 12 * 60, concentration: 98, minutes: 30),
            hint("Email", weight: 10, at: 12 * 60, concentration: 5, minutes: 30),
        ]
        XCTAssertEqual(rank(hints, from: (16, 0), to: (16, 30)).first, "Email")
        let lunchAtNoon = WristTitleRanking.score(hints[0], minute: 12 * 60, length: 30)
        let emailAtNoon = WristTitleRanking.score(hints[1], minute: 12 * 60, length: 30)
        XCTAssertEqual(lunchAtNoon, emailAtNoon, accuracy: 1e-9, "on its own hour a regular name loses nothing")
    }

    func testLimitAndStableTies() {
        let hints = (0..<6).map { hint("N\($0)", at: 9 * 60, minutes: 30) }
        XCTAssertEqual(
            WristTitleRanking.rank(hints, start: at(0, 9), end: at(0, 9, 30), calendar: calendar),
            ["N0", "N1", "N2"]
        )
        XCTAssertEqual(WristTitleRanking.shownCount, 3)
        XCTAssertTrue(WristTitleRanking.rank([], start: at(0, 9), end: at(0, 10), calendar: calendar).isEmpty)
    }

    // MARK: Context

    private func item(_ id: String, _ title: String, _ type: String, _ from: (Int, Int), _ to: (Int, Int), day: Int = 0) -> WristTitleTimeline.Item {
        WristTitleTimeline.Item(id: id, start: at(day, from.0, from.1), end: at(day, to.0, to.1), title: title, type: type)
    }

    func testNeighborsAreWithinTheGapAndAllowAnOverrun() {
        let timeline = WristTitleTimeline([
            item("gym", "Gym", "Sport", (10, 0), (11, 30)),
            item("late", "Meeting", "Work", (11, 0), (12, 10)),
            item("far", "Errand", "Life", (13, 31), (14, 0)),
            item("near", "Call", "Work", (13, 30), (13, 45)),
        ])
        XCTAssertEqual(timeline.previous(start: at(0, 12), excluding: nil)?.id, "late", "ran ten minutes into the block")
        XCTAssertEqual(timeline.previous(start: at(0, 12), excluding: "late")?.id, "gym", "ended thirty minutes before")
        XCTAssertNil(timeline.previous(start: at(0, 12, 1), excluding: "late"), "thirty-one minutes is a gap")
        XCTAssertEqual(timeline.next(start: at(0, 12), end: at(0, 13), excluding: nil)?.id, "near")
        XCTAssertNil(timeline.next(start: at(0, 12), end: at(0, 12, 59), excluding: nil))
    }

    func testMinutesIntoDayCountFromTheFirstRecordAfterTheTurn() {
        let timeline = WristTitleTimeline([
            item("night", "Reading", "Life", (1, 0), (2, 0)),
            item("wake", "Breakfast", "Life", (7, 30), (8, 0)),
        ])
        XCTAssertEqual(timeline.minutesIntoDay(start: at(0, 12, 30), excluding: nil, calendar: calendar), 300)
        XCTAssertEqual(timeline.minutesIntoDay(start: at(0, 7, 30), excluding: "wake", calendar: calendar), 0, "the first record itself")
        XCTAssertEqual(timeline.minutesIntoDay(start: at(0, 2, 30), excluding: nil, calendar: calendar), 90,
                       "before the turn the day is yesterday's, and the night's reading opened it")
    }

    func testTableNamesByTitleThenType() {
        let table = WristTitleTable(typeOrder: ["Work", "Sport"], hints: ["Sport": [hint("Gym", at: 600, minutes: 90)]])
        XCTAssertEqual(table.ref(title: "gym ", type: "Sport"), 2)
        XCTAssertEqual(table.ref(title: "Tennis", type: "Sport"), 1)
        XCTAssertEqual(table.ref(title: "", type: "work"), 0)
        XCTAssertNil(table.ref(title: "Nap", type: "Life"))
        let context = WristTitleTimeline([item("x", "Nap", "Life", (11, 0), (12, 0))])
            .context(start: at(0, 12), end: at(0, 13), table: table, calendar: calendar)
        XCTAssertEqual(context.previous, .unknown)
        XCTAssertEqual(context.next, .nothing)
        XCTAssertEqual(context.weekday, 3)
    }

    /// Same clock, same length: only what came before tells them apart.
    func testWhatCameBeforeDecides() {
        let gym = 5
        let hints = [
            hint("Tea", at: 18 * 60, minutes: 20).with(previous: [WristTitleTable.nothing, 80]),
            hint("Shower", at: 18 * 60, minutes: 20).with(previous: [gym, 90]),
        ]
        func first(_ previous: WristTitleContext.Neighbor) -> String? {
            WristTitleRanking.rank(hints, start: at(0, 18), end: at(0, 18, 20), calendar: calendar,
                                   context: WristTitleContext(previous: previous)).first
        }
        XCTAssertEqual(first(.ref(gym)), "Shower")
        XCTAssertEqual(first(.nothing), "Tea")
        XCTAssertEqual(first(.unknown), "Tea", "no evidence: the first listed of a tie")
    }

    func testWeekdayAndTimeIntoTheDayDecide() {
        let review = hint("Review", at: 14 * 60, minutes: 60).with(weekdays: [0, 34, 0, 33, 0, 33, 0])
        let planning = hint("Planning", at: 14 * 60, minutes: 60).with(weekdays: [0, 0, 50, 0, 50, 0, 0])
        func first(weekday: Int) -> String? {
            WristTitleRanking.rank([review, planning], start: at(0, 14), end: at(0, 15), calendar: calendar,
                                   context: WristTitleContext(weekday: weekday)).first
        }
        XCTAssertEqual(first(weekday: 2), "Review")
        XCTAssertEqual(first(weekday: 3), "Planning")

        var lunch = hint("Lunch", at: 12 * 60, concentration: 60, minutes: 50)
        lunch.intoDay = 300; lunch.intoDaySpread = 20
        var snack = hint("Snack", at: 12 * 60, concentration: 60, minutes: 50)
        snack.intoDay = 150; snack.intoDaySpread = 20
        func first(intoDay: Int) -> String? {
            WristTitleRanking.rank([snack, lunch], start: at(0, 12), end: at(0, 12, 50), calendar: calendar,
                                   context: WristTitleContext(minutesIntoDay: intoDay)).first
        }
        XCTAssertEqual(first(intoDay: 300), "Lunch", "woke at seven")
        XCTAssertEqual(first(intoDay: 150), "Snack", "woke at half past nine")
    }

    /// A hint from a phone without context, or a context the watch cannot
    /// read, ranks exactly as time and length alone.
    func testMissingContextChangesNothing() {
        let plain = hint("Standup", at: 540, minutes: 15)
        let rich = plain.with(weekdays: [0, 20, 20, 20, 20, 20, 0], previous: [3, 70])
        let full = WristTitleContext(weekday: 2, previous: .ref(3), next: .nothing, minutesIntoDay: 90)
        let base = WristTitleRanking.score(plain, minute: 540, length: 15)
        XCTAssertEqual(WristTitleRanking.score(plain, minute: 540, length: 15, context: full), base)
        XCTAssertEqual(WristTitleRanking.score(rich, minute: 540, length: 15, context: .none), base)
        XCTAssertEqual(WristTitleRanking.score(rich, minute: 540, length: 15, context: full, cues: []), base)
        XCTAssertNotEqual(WristTitleRanking.score(rich, minute: 540, length: 15, context: full), base)
    }

    func testHintsWithoutContextDecode() throws {
        let old = #"{"t":"Standup","w":3,"s":540,"c":90,"m":15}"#
        let decoded = try WristWire.decode(WristTitleHint.self, from: Data(old.utf8))
        XCTAssertNil(decoded.weekdays)
        XCTAssertNil(decoded.previous)
        XCTAssertNil(decoded.intoDay)
        let odd = #"{"t":"Standup","w":3,"s":540,"c":90,"m":15,"d":[1,2],"p":"x"}"#
        let lenient = try WristWire.decode(WristTitleHint.self, from: Data(odd.utf8))
        XCTAssertNil(lenient.weekdays, "a weekday list that is not seven long is ignored")
        XCTAssertNil(lenient.previous)
    }

    func testLearnsNeighborsWeekdaysAndTimeIntoTheDay() throws {
        var events: [Event] = []
        for d in 1...10 {
            let weekend = [0, 6].contains(calendar.component(.weekday, from: at(-d, 0)) - 1)
            events.append(event("Breakfast", "Life", at(-d, 7), minutes: 30))
            if weekend {
                events.append(event("Gym", "Sport", at(-d, 9), minutes: 90))
                events.append(event("Shower", "Life", at(-d, 10, 40), minutes: 20))
            } else {
                events.append(event("Shower", "Life", at(-d, 7, 30), minutes: 15))
            }
        }
        let list = types("Life", "Sport")
        let hints = WristSnapshotBuilder.titleHints(events: events, types: list, now: now, calendar: calendar)
        let table = WristTitleTable(typeOrder: list.map(\.title), hints: hints)
        let shower = try XCTUnwrap(hints["Life"]?.first { $0.title == "Shower" })
        let previous = try XCTUnwrap(shower.previous)
        let gym = try XCTUnwrap(table.ref(title: "Gym", type: "Sport"))
        let breakfast = try XCTUnwrap(table.ref(title: "Breakfast", type: "Life"))
        XCTAssertEqual(Set(stride(from: 0, to: previous.count, by: 2).map { previous[$0] }), [gym, breakfast])
        XCTAssertEqual(previous.enumerated().filter { $0.offset.isMultiple(of: 2) == false }.map(\.element).reduce(0, +), 100, accuracy: 1)
        let weekdays = try XCTUnwrap(shower.weekdays)
        XCTAssertEqual(weekdays.reduce(0, +), 100, accuracy: 1)
        XCTAssertEqual(weekdays[0] + weekdays[6], 40, accuracy: 3, "four weekend days of ten")
        let breakfastHint = try XCTUnwrap(hints["Life"]?.first { $0.title == "Breakfast" })
        XCTAssertEqual(breakfastHint.intoDay, 0, "breakfast opens the day")
        XCTAssertEqual(breakfastHint.previous, [WristTitleTable.nothing, 100])
        XCTAssertNotNil(hints["Sport"]?.first?.next, "the gym is followed by the shower")
    }

    /// The watch numbers names in the order the hints arrive; the phone must
    /// learn neighbors in that same order. Zeta outweighs Alpha before
    /// rounding, but both go out as the same weight and so sort by title.
    func testNeighborsPointAtTheNameTheWatchSees() throws {
        let events = [
            event("Zeta", "Work", at(0, 8), minutes: 60),
            event("After", "Life", at(0, 9), minutes: 30),
            event("Alpha", "Work", at(-1, 8), minutes: 60),
        ]
        let list = types("Work", "Life")
        let hints = WristSnapshotBuilder.titleHints(events: events, types: list, now: now, calendar: calendar)
        XCTAssertEqual(hints["Work"]?.map(\.title), ["Alpha", "Zeta"], "precondition: a tie on the wire")
        let table = WristTitleTable(typeOrder: list.map(\.title), hints: hints)
        let after = try XCTUnwrap(hints["Life"]?.first { $0.title == "After" })
        XCTAssertEqual(after.previous?.first, table.ref(title: "Zeta", type: "Work"))
    }

    /// A daily series is learned per occurrence: it ages like hand-entered
    /// events and is a neighbor, as it is on the watch's timeline.
    func testASeriesIsLearnedPerOccurrenceAndAsANeighbor() throws {
        var standup = event("Standup", "Work", at(-20, 9), minutes: 15)
        standup.repeatUnit = .day
        standup.repeatInterval = 1
        var events = [standup]
        for d in 1...5 { events.append(event("Deep work", "Work", at(-d, 9, 15), minutes: 105)) }
        let list = types("Work")
        let hints = try XCTUnwrap(WristSnapshotBuilder.titleHints(events: events, types: list, now: now, calendar: calendar)["Work"])
        let table = WristTitleTable(typeOrder: list.map(\.title), hints: ["Work": hints])
        let deep = try XCTUnwrap(hints.first { $0.title == "Deep work" })
        XCTAssertEqual(deep.previous?.first, table.ref(title: "Standup", type: "Work"), "the series ends right before it")
        let standupHint = try XCTUnwrap(hints.first { $0.title == "Standup" })
        XCTAssertGreaterThan(standupHint.weight, deep.weight, "twenty-one daily uses outweigh five")

        var ended = standup
        ended.repeatEndType = .onDate
        ended.repeatEndDate = at(-200, 12)
        ended.timeRanges = [.init(start: at(-400, 9), end: at(-400, 9, 15))]
        let old = WristSnapshotBuilder.titleHints(events: [ended], types: list, now: now, calendar: calendar)
        XCTAssertNil(old["Work"]?.first { $0.title == "Standup" }, "a series that ended long ago teaches nothing")
    }

    // MARK: Learning (phone)

    func testHintsSkipEmptyAndTypeNamedTitlesAndUnlistedTypes() {
        let events = [
            event("", "Work", at(-1, 9), minutes: 30),
            event("  work ", "Work", at(-1, 10), minutes: 30),
            event("Standup", "Work", at(-1, 9), minutes: 15),
            event("Swim", "Sport", at(-1, 7), minutes: 45),
        ]
        let hints = WristSnapshotBuilder.titleHints(events: events, types: types("Work"), now: now, calendar: calendar)
        XCTAssertEqual(Array(hints.keys), ["Work"])
        XCTAssertEqual(hints["Work"]?.map(\.title), ["Standup"])
    }

    func testSpellingsFoldTogetherShownAsTheLatest() {
        let events = [
            event("standup", "Work", at(-5, 9), minutes: 15),
            event("Standup", "Work", at(-1, 9), minutes: 15),
            event("STANDUP", "Work", at(-3, 9), minutes: 15),
        ]
        let hints = WristSnapshotBuilder.titleHints(events: events, types: types("Work"), now: now, calendar: calendar)["Work"]
        XCTAssertEqual(hints?.count, 1)
        XCTAssertEqual(hints?.first?.title, "Standup")
    }

    func testFeaturesWeightMeanStartConcentrationAndMedianLength() throws {
        var events: [Event] = []
        // Today counts one, thirty days ago a half.
        events.append(event("Standup", "Work", at(0, 9), minutes: 15))
        events.append(event("Standup", "Work", at(-30, 9), minutes: 15))
        // Starts around midnight average to midnight, not noon.
        events.append(event("Reading", "Work", at(-1, 23, 30), minutes: 60))
        events.append(event("Reading", "Work", at(-2, 0, 30), minutes: 40))
        events.append(event("Reading", "Work", at(-2, 23, 50), minutes: 90))
        let hints = try XCTUnwrap(WristSnapshotBuilder.titleHints(events: events, types: types("Work"), now: now, calendar: calendar)["Work"])
        let standup = try XCTUnwrap(hints.first { $0.title == "Standup" })
        XCTAssertEqual(standup.weight, 1.5, accuracy: 0.05)
        XCTAssertEqual(standup.startMinute, 9 * 60)
        XCTAssertEqual(standup.concentration, 100)
        XCTAssertEqual(standup.minutes, 15)
        let reading = try XCTUnwrap(hints.first { $0.title == "Reading" })
        let fromMidnight = min(reading.startMinute, 1440 - reading.startMinute)
        XCTAssertLessThan(fromMidnight, 30, "circular mean near midnight, got \(reading.startMinute)")
        XCTAssertGreaterThan(reading.concentration, 90)
        XCTAssertEqual(reading.minutes, 60, "weighted median length")
    }

    func testOldFutureAllDayAndRunningEventsDoNotCount() {
        var timer = event("Timer", "Work", at(0, 9), minutes: 30)
        timer.timerStartedAt = at(0, 9)
        let events = [
            event("Ancient", "Work", at(-121, 9), minutes: 30),
            event("Planned", "Work", at(1, 9), minutes: 30),
            Event(title: "Holiday", timeRanges: [.init(start: at(-1, 0), end: at(0, 0))], isAllDay: true, type: "Work"),
            timer,
            event("Kept", "Work", at(-119, 9), minutes: 30),
        ]
        let hints = WristSnapshotBuilder.titleHints(events: events, types: types("Work"), now: now, calendar: calendar)
        XCTAssertEqual(hints["Work"]?.map(\.title), ["Kept"])
    }

    func testCapsPerTypeMostUsedFirst() {
        var events: [Event] = []
        for n in 0..<9 {
            for k in 0...n { events.append(event("Name\(n)", "Work", at(-k - 1, 9), minutes: 30)) }
        }
        let hints = WristSnapshotBuilder.titleHints(events: events, types: types("Work"), now: now, calendar: calendar)["Work"]
        XCTAssertEqual(hints?.count, WristSnapshotBuilder.maxTitlesPerType)
        XCTAssertEqual(hints?.first?.title, "Name8")
        XCTAssertEqual(hints?.map(\.weight), hints?.map(\.weight).sorted(by: >))
    }

    func testFiguresHoldStillThroughTheDay() {
        let events = [event("Standup", "Work", at(-3, 9), minutes: 15)]
        let morning = WristSnapshotBuilder.titleHints(events: events, types: types("Work"), now: at(0, 0, 5), calendar: calendar)
        let evening = WristSnapshotBuilder.titleHints(events: events, types: types("Work"), now: at(0, 23, 55), calendar: calendar)
        XCTAssertEqual(morning, evening, "a push later in the day must not differ only by decay")
    }

    func testSnapshotCarriesHintsForTheStartGridTypes() {
        let templates = [EventTypeTemplate(title: "Work", colorHex: "#0A84FF"), EventTypeTemplate(title: "Sport", colorHex: "#30D158")]
        let snapshot = WristSnapshotBuilder.snapshot(
            events: [event("Standup", "Work", at(-1, 9), minutes: 15), event("Swim", "Sport", at(-1, 7), minutes: 45)],
            templates: templates, now: now, calendar: calendar, language: nil, receipts: [], colorHex: { _ in "#000000" }
        )
        XCTAssertEqual(snapshot.titleHints["Work"]?.map(\.title), ["Standup"])
        XCTAssertEqual(snapshot.titleHints["Sport"]?.map(\.title), ["Swim"])
    }

    // MARK: Wire

    /// The command's shape before the title, as an older phone decodes it.
    private struct LegacyCommand: Codable, Equatable {
        enum Kind: Codable, Equatable {
            case start(eventID: UUID, typeTitle: String, start: Date, end: Date)
            case finish(eventID: UUID, rangeStart: Date?, at: Date)
            case extend(eventID: UUID, rangeStart: Date?, by: TimeInterval)
        }

        var id: UUID
        var issuedAt: Date
        var kind: Kind
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnOlderPhoneDecodesATitledStart() throws {
        let eventID = UUID()
        let command = WristCommand(
            id: UUID(), issuedAt: t0,
            kind: .start(eventID: eventID, typeTitle: "Work", start: t0, end: t0 + 900, title: "Standup")
        )
        let legacy = try WristWire.decode(LegacyCommand.self, from: try WristWire.encode(command))
        XCTAssertEqual(legacy.id, command.id)
        XCTAssertEqual(legacy.kind, .start(eventID: eventID, typeTitle: "Work", start: t0, end: t0 + 900))
    }

    func testAStartFromAnOlderWatchDecodesWithoutATitle() throws {
        let eventID = UUID()
        let legacy = LegacyCommand(id: UUID(), issuedAt: t0, kind: .start(eventID: eventID, typeTitle: "Work", start: t0, end: t0 + 900))
        let decoded = try WristWire.decode(WristCommand.self, from: try WristWire.encode(legacy))
        XCTAssertEqual(decoded.kind, .start(eventID: eventID, typeTitle: "Work", start: t0, end: t0 + 900, title: nil))
    }

    func testTitledStartRoundTripsAndUntitledOmitsTheKey() throws {
        let titled = WristCommand(id: UUID(), issuedAt: t0, kind: .start(eventID: UUID(), typeTitle: "Work", start: t0, end: t0 + 900, title: "Standup"))
        XCTAssertEqual(try WristWire.decode(WristCommand.self, from: try WristWire.encode(titled)), titled)
        let untitled = WristCommand(id: UUID(), issuedAt: t0, kind: .start(eventID: UUID(), typeTitle: "Work", start: t0, end: t0 + 900))
        let json = try XCTUnwrap(String(data: try WristWire.encode(untitled), encoding: .utf8))
        XCTAssertFalse(json.contains("\"title\""), json)
    }

    func testSnapshotWithoutHintsDecodesEmptyAndHintsRoundTrip() throws {
        let bare = #"{"version":1,"generatedAt":1800000000,"types":[],"occurrences":[],"receipts":[]}"#
        XCTAssertEqual(try WristWire.decode(WristSnapshot.self, from: Data(bare.utf8)).titleHints, [:])
        let garbled = #"{"version":1,"generatedAt":1800000000,"types":[],"occurrences":[],"receipts":[],"titleHints":[1,2]}"#
        XCTAssertEqual(try WristWire.decode(WristSnapshot.self, from: Data(garbled.utf8)).titleHints, [:],
                       "a malformed hints field costs the hints, not the snapshot")
        let snapshot = WristSnapshot(generatedAt: t0, types: [], occurrences: [], receipts: [],
                                     titleHints: ["Work": [hint("Standup", weight: 2.5, at: 540, minutes: 15)]])
        let decoded = try WristWire.decode(WristSnapshot.self, from: try WristWire.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        var other = snapshot
        other.titleHints = [:]
        XCTAssertFalse(snapshot.hasSameContent(as: other), "a change of hints is pushed")
        let json = try XCTUnwrap(String(data: try WristWire.encode(other), encoding: .utf8))
        XCTAssertFalse(json.contains("titleHints"), "no hints, no key: \(json)")
    }

    func testPendingStartShowsThePickedName() {
        let snapshot = WristSnapshot(generatedAt: t0, types: types("Work"), occurrences: [], receipts: [])
        let titled = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: t0, kind: .start(eventID: UUID(), typeTitle: "Work", start: t0, end: t0 + 900, title: " Standup ")
        ))
        let plain = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: t0, kind: .start(eventID: UUID(), typeTitle: "Work", start: t0 + 900, end: t0 + 1800)
        ))
        let shown = WristStateReducer.overlaid(snapshot, pending: [titled, plain], now: t0).occurrences
        XCTAssertEqual(shown.map(\.title), ["Standup", "Work"])
        XCTAssertEqual(shown.map(\.type), ["Work", "Work"])
    }

    // MARK: Size

    /// Over budget the hints shrink to the names alone before anything
    /// else gives: without them the watch skips naming altogether.
    func testFittingShrinksHintsBeforeStats() throws {
        let names = (0..<6).map { "A name long enough to cost something \($0)" }
        let hints = Dictionary(uniqueKeysWithValues: (0..<8).map { t in
            ("Type\(t)", names.map {
                hint($0, at: 540, minutes: 30).with(weekdays: [10, 20, 20, 20, 20, 10, 0], previous: [0, 60, 3, 30, 5, 10])
            })
        })
        var base = WristSnapshot(generatedAt: t0, types: [], occurrences: [], receipts: [], titleHints: hints)
        let hintBytes = try WristWire.encode(base).count
        var bare = base
        bare.titleHints = WristBridge.compactHints(hints, perType: WristSnapshotBuilder.maxTitlesPerType)
        let bareBytes = try WristWire.encode(bare).count
        print("WristTitles: 8 types × 6 long names = \(hintBytes)B, names alone \(bareBytes)B")
        XCTAssertLessThan(bareBytes, 4_000)
        XCTAssertLessThan(bareBytes, hintBytes)
        base.stats = CategoryStatsBuilder.payload(
            events: [event("Standup", "Type0", at(-1, 9), minutes: 15)], now: now, calendar: calendar,
            colorHex: { _ in "#123456" }
        )
        XCTAssertNotNil(base.stats)

        // Pad with occurrences until the full snapshot is just over budget
        // while the one with the names alone fits.
        var padded = base
        var n = 0
        while try WristWire.encode(padded).count <= WristBridge.byteBudget {
            padded.occurrences.append(WristOccurrence(
                id: "o\(n)", eventID: UUID(), title: "Occurrence \(n)", type: "Type0", colorHex: "#123456",
                start: t0 + TimeInterval(n * 60), end: t0 + TimeInterval(n * 60 + 30), isInterrupt: false, quickActionsEnabled: true
            ))
            n += 1
        }
        let fitted = try XCTUnwrap(WristBridge.fitting(padded, latestStats: nil, now: t0))
        XCTAssertEqual(fitted.0.titleHints.mapValues { $0.map(\.title) }, hints.mapValues { $0.map(\.title) }, "every name still goes")
        XCTAssertNil(fitted.0.titleHints["Type0"]?.first?.previous, "without its context")
        XCTAssertNotNil(fitted.0.stats, "the stats stayed")
        XCTAssertEqual(fitted.0.occurrences.count, padded.occurrences.count, "nothing else was given up")
        let roomy = try XCTUnwrap(WristBridge.fitting(base, latestStats: nil, now: t0))
        XCTAssertEqual(roomy.0.titleHints, hints, "under budget the hints ride along whole")

        // Even the last step, as many occurrences as fit, keeps the few.
        var crowded = padded
        crowded.occurrences += (0..<400).map { k in
            WristOccurrence(id: "x\(k)", eventID: UUID(), title: "Crowd \(k)", type: "Type1", colorHex: "#123456",
                            start: t0 + TimeInterval(k * 60), end: t0 + TimeInterval(k * 60 + 30), isInterrupt: false, quickActionsEnabled: true)
        }
        let last = try XCTUnwrap(WristBridge.fitting(crowded, latestStats: nil, now: t0))
        XCTAssertLessThan(last.0.occurrences.count, crowded.occurrences.count, "precondition: the last step")
        XCTAssertEqual(last.0.titleHints["Type0"]?.map(\.title), Array(names.prefix(WristTitleRanking.shownCount)))
    }
}

private extension WristTitleHint {
    func with(weekdays: [Int]? = nil, previous: [Int]? = nil) -> WristTitleHint {
        var copy = self
        if let weekdays { copy.weekdays = weekdays }
        if let previous { copy.previous = previous }
        return copy
    }
}
