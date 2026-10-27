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

    /// Hints go first when the snapshot is over budget: stats outrank them.
    func testFittingDropsHintsBeforeStats() throws {
        let names = (0..<6).map { "A name long enough to cost something \($0)" }
        let hints = Dictionary(uniqueKeysWithValues: (0..<8).map { t in
            ("Type\(t)", names.map { hint($0, at: 540, minutes: 30) })
        })
        var base = WristSnapshot(generatedAt: t0, types: [], occurrences: [], receipts: [], titleHints: hints)
        let hintBytes = try WristWire.encode(base).count
        print("WristTitles: 8 types × 6 long names = \(hintBytes)B")
        XCTAssertLessThan(hintBytes, 4_000)
        // Stats the ladder can only keep at the hint-free step: the shorter
        // reaches are rebuilt from `latestStats`, which is nil here.
        base.stats = CategoryStatsBuilder.payload(
            events: [event("Standup", "Type0", at(-1, 9), minutes: 15)], now: now, calendar: calendar,
            colorHex: { _ in "#123456" }
        )
        XCTAssertNotNil(base.stats)

        // Pad with occurrences until the full snapshot is just over budget
        // while the one without hints fits.
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
        XCTAssertEqual(fitted.0.titleHints, [:])
        XCTAssertNotNil(fitted.0.stats, "the hints went, the stats stayed")
        XCTAssertEqual(fitted.0.occurrences.count, padded.occurrences.count, "nothing else was given up")
        let roomy = try XCTUnwrap(WristBridge.fitting(base, latestStats: nil, now: t0))
        XCTAssertEqual(roomy.0.titleHints, hints, "under budget the hints ride along")
    }
}
