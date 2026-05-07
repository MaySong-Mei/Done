import XCTest
@testable import Done

@MainActor
final class TimeZoneScheduleTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    override func tearDown() {
        super.tearDown()
        CalendarOccurrenceKey.referenceTimeZoneOverride = nil
    }

    // MARK: - Event Codable backwards compatibility

    func testEventDecodesWithoutTimeZoneIdentifier() throws {
        let original = Event(title: "Legacy", note: "no tz tag")
        let encoded = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "timeZoneIdentifier")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Event.self, from: legacyData)
        XCTAssertNil(decoded.timeZoneIdentifier,
                     "Legacy events without the field must decode with nil")
    }

    func testEventRoundTripsTimeZoneIdentifier() throws {
        let event = Event(title: "Travel", timeZoneIdentifier: "Asia/Shanghai")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        XCTAssertEqual(decoded.timeZoneIdentifier, "Asia/Shanghai")
    }

    func testEffectiveTimeZoneFallsBackToReferenceWhenNil() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let event = Event(title: "Legacy")
        XCTAssertNil(event.timeZoneIdentifier)
        XCTAssertEqual(event.effectiveTimeZone, shanghai)
    }

    func testEffectiveTimeZoneUsesIdentifierWhenSet() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let event = Event(title: "Travel", timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(event.effectiveTimeZone, newYork)
    }

    func testEffectiveTimeZoneFallsBackWhenIdentifierUnknown() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let event = Event(title: "Garbage", timeZoneIdentifier: "Mars/Olympus_Mons")
        XCTAssertEqual(event.effectiveTimeZone, shanghai,
                       "Unknown identifiers must fall back to the reference tz")
    }

    // MARK: - Schedule lookup

    func testEmptyScheduleReturnsReferenceTimeZone() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let schedule: [TimeZoneScheduleEntry] = []
        XCTAssertEqual(schedule.timeZone(coveringInstant: Date()), shanghai)
    }

    func testScheduleReturnsLatestNonFutureEntry() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let entries: [TimeZoneScheduleEntry] = [
            TimeZoneScheduleEntry(
                startDate: makeDate(2026, 1, 1, in: shanghai),
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            TimeZoneScheduleEntry(
                startDate: makeDate(2026, 2, 1, in: newYork),
                timeZoneIdentifier: "America/New_York"
            ),
        ]

        XCTAssertEqual(
            entries.timeZone(coveringInstant: makeDate(2026, 1, 15, in: shanghai)),
            shanghai
        )
        XCTAssertEqual(
            entries.timeZone(coveringInstant: makeDate(2026, 2, 15, in: newYork)),
            newYork
        )
    }

    func testScheduleEntriesBeforeFirstStartFallBackToReference() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let entries: [TimeZoneScheduleEntry] = [
            TimeZoneScheduleEntry(
                startDate: makeDate(2026, 6, 1, in: shanghai),
                timeZoneIdentifier: "America/New_York"
            ),
        ]
        XCTAssertEqual(
            entries.timeZone(coveringInstant: makeDate(2026, 1, 15, in: shanghai)),
            shanghai,
            "Instants before the earliest entry get the reference tz, not the entry's tz"
        )
    }

    // MARK: - EventStore integration

    func testEventStoreUpsertAndLookup() throws {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let defaults = try makeEphemeralDefaults()
        let store = EventStore(defaults: defaults)

        let entry = TimeZoneScheduleEntry(
            startDate: makeDate(2026, 1, 1, in: shanghai),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        store.upsertTimeZoneScheduleEntry(entry)

        XCTAssertEqual(store.timeZoneSchedule.count, 1)
        XCTAssertEqual(
            store.defaultTimeZone(forEventStart: makeDate(2026, 3, 1, in: shanghai)),
            shanghai
        )

        // Same-day duplicates collapse to the last write.
        let replacement = TimeZoneScheduleEntry(
            startDate: makeDate(2026, 1, 1, in: shanghai),
            timeZoneIdentifier: "America/New_York"
        )
        store.upsertTimeZoneScheduleEntry(replacement)

        XCTAssertEqual(store.timeZoneSchedule.count, 1,
                       "Same-day entries must collapse, not stack")
        XCTAssertEqual(
            store.defaultTimeZone(forEventStart: makeDate(2026, 3, 1, in: shanghai)),
            newYork
        )
    }

    func testEventStorePersistsScheduleAcrossInstances() throws {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let defaults = try makeEphemeralDefaults()
        let store = EventStore(defaults: defaults)
        store.upsertTimeZoneScheduleEntry(
            TimeZoneScheduleEntry(
                startDate: makeDate(2026, 1, 1, in: shanghai),
                timeZoneIdentifier: "Asia/Shanghai",
                note: "Home"
            )
        )

        let reloaded = EventStore(defaults: defaults)
        XCTAssertEqual(reloaded.timeZoneSchedule.count, 1)
        XCTAssertEqual(reloaded.timeZoneSchedule.first?.note, "Home")
    }

    // MARK: - Helpers

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, in tz: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func makeEphemeralDefaults() throws -> UserDefaults {
        let suite = "TimeZoneScheduleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
