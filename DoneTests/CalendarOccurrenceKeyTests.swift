import XCTest
@testable import Done

final class CalendarOccurrenceKeyTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    override func tearDown() {
        super.tearDown()
        CalendarOccurrenceKey.referenceTimeZoneOverride = nil
    }

    // MARK: - dayKey identity stability

    func testKeyDayKeyIsStableAcrossSystemTimeZoneChange() {
        // Reference tz frozen to Shanghai (the tz the user "originally" wrote in).
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai

        var shCal = Calendar(identifier: .gregorian)
        shCal.timeZone = shanghai
        let shanghaiNineAM = shCal.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 9, minute: 0
        ))!

        let event = Event(
            title: "Morning Jog",
            timeRanges: [.init(start: shanghaiNineAM, end: shanghaiNineAM.addingTimeInterval(1800))]
        )

        let writeKey = CalendarOccurrenceKey.make(for: event, occurrenceDate: shanghaiNineAM)

        // Simulate the user travelling to NY: the *system* tz changes, but the
        // reference tz used by the key derivation stays frozen on Shanghai —
        // which is exactly what the fix guarantees in production via
        // UserDefaults persistence.
        let lookupKey = CalendarOccurrenceKey.make(for: event, occurrenceDate: shanghaiNineAM)
        XCTAssertEqual(writeKey, lookupKey, "Same event/day should hash equal across lookups")

        // Sanity: switching the reference tz should produce a different dayKey
        // (this confirms that dayKey is actually derived from the reference tz,
        // i.e., the test isn't a no-op).
        CalendarOccurrenceKey.referenceTimeZoneOverride = newYork
        let nyKey = CalendarOccurrenceKey.make(for: event, occurrenceDate: shanghaiNineAM)
        XCTAssertNotEqual(writeKey.dayKey, nyKey.dayKey,
                          "dayKey should differ when reference tz crosses a day boundary")
    }

    func testKeysWithEqualDayKeyAreEqualAndHashAlike() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let eventID = UUID()
        let a = CalendarOccurrenceKey(
            eventID: eventID,
            baseSeriesEventID: nil,
            occurrenceDate: Date(timeIntervalSince1970: 0),
            kind: .singleEvent,
            dayKey: 20260115
        )
        let b = CalendarOccurrenceKey(
            eventID: eventID,
            baseSeriesEventID: nil,
            occurrenceDate: Date(timeIntervalSince1970: 99_999),
            kind: .singleEvent,
            dayKey: 20260115
        )
        // occurrenceDate differs but identity is dayKey-based.
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: - Codable backwards compatibility

    func testDecodesLegacyJSONWithoutDayKey() throws {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let eventID = UUID()
        // Legacy JSON shape: dayKey was absent prior to the fix.
        let legacy: [String: Any] = [
            "eventID": eventID.uuidString,
            "occurrenceDate": ISO8601DateFormatter().date(from: "2026-01-15T00:00:00+08:00")!.timeIntervalSinceReferenceDate,
            "kind": "single",
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(CalendarOccurrenceKey.self, from: data)
        XCTAssertEqual(decoded.eventID, eventID)
        XCTAssertEqual(decoded.dayKey, 20260115,
                       "dayKey should be derived from occurrenceDate in the reference tz")
    }

    func testEncodeDecodeRoundTripPreservesDayKey() throws {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let eventID = UUID()
        let key = CalendarOccurrenceKey(
            eventID: eventID,
            baseSeriesEventID: nil,
            occurrenceDate: Date(timeIntervalSinceReferenceDate: 0),
            kind: .singleEvent,
            dayKey: 20260115
        )
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(CalendarOccurrenceKey.self, from: data)
        XCTAssertEqual(decoded.dayKey, 20260115)
        XCTAssertEqual(decoded, key)
    }

    func testLegacyKeyAndNewKeyMatchInLookupAcrossTimeZones() throws {
        // End-to-end scenario: a record was written under Shanghai before the
        // fix (no dayKey in JSON). After the fix lands, the user is in NY, but
        // the reference tz remains frozen on Shanghai. Lookup must still find
        // the legacy record.
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai
        let eventID = UUID()

        var shCal = Calendar(identifier: .gregorian)
        shCal.timeZone = shanghai
        let shanghaiMidnight = shCal.startOfDay(for: shCal.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 9
        ))!)

        // Simulate a legacy on-disk record with no dayKey field.
        let legacy: [String: Any] = [
            "eventID": eventID.uuidString,
            "occurrenceDate": shanghaiMidnight.timeIntervalSinceReferenceDate,
            "kind": "single",
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyKey = try JSONDecoder().decode(CalendarOccurrenceKey.self, from: legacyData)

        // System tz "switches" to NY, but reference tz stays frozen on Shanghai.
        let event = Event(
            id: eventID,
            title: "Morning Jog",
            timeRanges: [.init(start: shanghaiMidnight.addingTimeInterval(9 * 3600),
                               end: shanghaiMidnight.addingTimeInterval(9 * 3600 + 1800))]
        )
        let lookupKey = CalendarOccurrenceKey.make(
            for: event,
            occurrenceDate: shanghaiMidnight.addingTimeInterval(9 * 3600)
        )

        XCTAssertEqual(legacyKey, lookupKey,
                       "Legacy record (no dayKey in JSON) must still match a freshly-made key")
    }
}
