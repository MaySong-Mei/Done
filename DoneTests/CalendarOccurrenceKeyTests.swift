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

    // MARK: - System-tz pre-normalization regression

    /// Reproduces the production "note disappears after travel" bug that the
    /// initial dayKey fix only partially addressed. Callers like
    /// `handleTimelineEventTap` pass an `occurrenceDate` that is already
    /// `Calendar.current.startOfDay(eventInstant)` — i.e. midnight in the
    /// *system* tz, not the event's real start instant. After travel, that
    /// midnight lands on a different calendar day in the reference tz than
    /// the original write did, so the lookup misses.
    ///
    /// `make()` must defend against this: for non-recurring events it should
    /// derive the day anchor from `event`'s own start instant, treating the
    /// supplied `occurrenceDate` as a hint at best.
    func testLookupKeyMatchesWriteKeyWhenCallerNormalizesInSystemTimeZone() {
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

        // Write happened while the user was in Shanghai. Caller passed the
        // event's actual start instant.
        let writeKey = CalendarOccurrenceKey.make(for: event, occurrenceDate: shanghaiNineAM)

        // After travel to NY, a timeline-tap caller computes
        // `Calendar.current.startOfDay(event.start)` and passes THAT. In NY
        // the event lands on the previous calendar day, so the caller hands
        // `make()` a Date that points at NY midnight of the wrong day.
        var nyCal = Calendar(identifier: .gregorian)
        nyCal.timeZone = newYork
        let nySystemStartOfDay = nyCal.startOfDay(for: shanghaiNineAM)

        let lookupKey = CalendarOccurrenceKey.make(for: event, occurrenceDate: nySystemStartOfDay)

        XCTAssertEqual(writeKey, lookupKey,
                       "Lookup must match write even when the caller pre-normalized in the system tz")
        XCTAssertEqual(lookupKey.dayKey, 20260115,
                       "dayKey must stay anchored to the event's Shanghai day")
    }

    // MARK: - End-to-end through EventStore APIs

    /// Drives the full production write/read path: `appendTimelineNote` →
    /// `upsertLogRecord` → `make()` → on-disk record, then `logRecord(for:)`
    /// → `calendarOccurrenceKey(for:)` → `make()` → array lookup. The two
    /// occurrence contexts model the same event tapped under two different
    /// system tzs (Shanghai write, NY read). If the note-disappearance bug
    /// still reproduces, this test must fail.
    @MainActor
    func testTimelineNotePersistsAcrossSystemTimeZoneChange() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai

        let suiteName = "tz-bug-repro-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not build test UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EventStore(defaults: defaults)

        var shCal = Calendar(identifier: .gregorian)
        shCal.timeZone = shanghai
        let shanghaiNineAM = shCal.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 9, minute: 0
        ))!
        let event = Event(
            title: "Morning Jog",
            timeRanges: [.init(start: shanghaiNineAM, end: shanghaiNineAM.addingTimeInterval(1800))]
        )
        store.addCalendarEvent(event)

        // Write: user is in Shanghai. The timeline-tap caller produces
        // `Calendar.current.startOfDay(eventStart)` in Shanghai system tz.
        let writeOccurrenceDate = shCal.startOfDay(for: shanghaiNineAM)
        let writeContext = CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: writeOccurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
        store.appendTimelineNote(
            "field test note",
            createdAt: shanghaiNineAM.addingTimeInterval(300),
            source: "test",
            for: writeContext
        )

        XCTAssertEqual(store.calendarEventLogRecords.count, 1,
                       "write should have produced exactly one log record")
        XCTAssertEqual(store.logRecord(for: writeContext)?.timelineItems.compactMap { $0.noteValue?.text }.first,
                       "field test note",
                       "fresh lookup with the same context should obviously find the note")

        // Read: user has travelled to NY. Same event, same UTC start instant.
        // The tap caller now produces `Calendar.current.startOfDay(eventStart)`
        // in NY system tz — a different Date than the write.
        var nyCal = Calendar(identifier: .gregorian)
        nyCal.timeZone = newYork
        let readOccurrenceDate = nyCal.startOfDay(for: shanghaiNineAM)
        XCTAssertNotEqual(writeOccurrenceDate, readOccurrenceDate,
                          "guard: the two contexts must differ on the wire, otherwise the test is a no-op")

        let readContext = CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: readOccurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
        let readRecord = store.logRecord(for: readContext)
        XCTAssertNotNil(readRecord,
                        "note must be found when read context's occurrenceDate is NY-normalized")
        XCTAssertEqual(readRecord?.timelineItems.compactMap { $0.noteValue?.text }.first,
                       "field test note",
                       "note text must round-trip across the simulated system tz change")
    }

    /// Real production reproduction caught by device logs: a single-event
    /// log record was written under a different system tz than the device
    /// is in today (the user was in Asia when the note was logged, NY now),
    /// so the stored `dayKey` is off-by-one from what either PR #9 or the
    /// fixed `make()` would now compute in NY. Single events have exactly
    /// one occurrence, so equality must ignore `dayKey` and the legacy
    /// record must still resolve.
    @MainActor
    func testSingleEventEqualityIgnoresDayKeyForLegacyRecords() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = newYork
        let eventID = UUID()
        let writeKey = CalendarOccurrenceKey(
            eventID: eventID,
            baseSeriesEventID: nil,
            occurrenceDate: Date(timeIntervalSinceReferenceDate: 0),
            kind: .singleEvent,
            dayKey: 20260430 // legacy: written in Asia for an event NY sees as May 1
        )
        let lookupKey = CalendarOccurrenceKey(
            eventID: eventID,
            baseSeriesEventID: nil,
            occurrenceDate: Date(timeIntervalSinceReferenceDate: 100),
            kind: .singleEvent,
            dayKey: 20260501 // canonical: what make() now produces in NY
        )
        XCTAssertEqual(writeKey, lookupKey,
                       "single-event identity must not depend on dayKey")
        XCTAssertEqual(writeKey.hashValue, lookupKey.hashValue,
                       "hash must agree with == for Dictionary/Set semantics")
    }

    func testRecurringSeriesEqualityStillRequiresDayKey() {
        CalendarOccurrenceKey.referenceTimeZoneOverride = newYork
        let seriesID = UUID()
        let monday = CalendarOccurrenceKey(
            eventID: seriesID,
            baseSeriesEventID: seriesID,
            occurrenceDate: Date(timeIntervalSinceReferenceDate: 0),
            kind: .seriesOccurrence,
            dayKey: 20260427
        )
        let tuesday = CalendarOccurrenceKey(
            eventID: seriesID,
            baseSeriesEventID: seriesID,
            occurrenceDate: Date(timeIntervalSinceReferenceDate: 86400),
            kind: .seriesOccurrence,
            dayKey: 20260428
        )
        XCTAssertNotEqual(monday, tuesday,
                          "different occurrences of the same series must remain distinct")
        XCTAssertNotEqual(monday.hashValue, tuesday.hashValue,
                          "hash must distinguish recurring occurrences")
    }

    /// Mirrors the user's actual production state: the device already has
    /// a log record on disk that was written by PR #9 era code (i.e.,
    /// `make()` ran against `Calendar.current.startOfDay(eventStart)` in
    /// the write-time system tz). After installing the fix, the lookup
    /// must still resolve to that legacy record so existing notes do not
    /// appear stranded.
    @MainActor
    func testLegacyOnDiskRecordRemainsFindableAfterFix() throws {
        CalendarOccurrenceKey.referenceTimeZoneOverride = shanghai

        let suiteName = "tz-bug-legacy-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not build test UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Synthesise an Event and a legacy log record exactly as PR #9 era
        // code would have laid it down on disk, then write them straight to
        // UserDefaults so the store has to hydrate from JSON like in prod.
        var shCal = Calendar(identifier: .gregorian)
        shCal.timeZone = shanghai
        let shanghaiNineAM = shCal.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 9, minute: 0
        ))!
        let event = Event(
            title: "Morning Jog",
            timeRanges: [.init(start: shanghaiNineAM, end: shanghaiNineAM.addingTimeInterval(1800))]
        )

        // PR #9 era key: derived from `Calendar.current.startOfDay(eventStart)`
        // computed in the write-time system tz (Shanghai here).
        let legacyOccurrenceDate = shCal.startOfDay(for: shanghaiNineAM)
        let legacyDayKey = CalendarOccurrenceKey.dayKey(from: legacyOccurrenceDate)
        let legacyKey = CalendarOccurrenceKey(
            eventID: event.id,
            baseSeriesEventID: nil,
            occurrenceDate: legacyOccurrenceDate,
            kind: .singleEvent,
            dayKey: legacyDayKey
        )
        let legacyRecord = CalendarEventLogRecord(
            id: legacyKey,
            eventID: event.id,
            baseSeriesEventID: nil,
            occurrenceDate: legacyOccurrenceDate,
            suggestedTemplateID: nil,
            createdAt: shanghaiNineAM,
            updatedAt: shanghaiNineAM
        )
        var seedRecord = legacyRecord
        seedRecord.timelineItems = [
            .note(EventLogTimelineNote(
                text: "legacy testflight note",
                createdAt: shanghaiNineAM,
                source: "testflight"
            ))
        ]

        let eventsData = try JSONEncoder().encode([event])
        defaults.set(eventsData, forKey: "calendarEvents")
        let logsData = try JSONEncoder().encode([seedRecord])
        defaults.set(logsData, forKey: "calendarEventLogRecords")

        // Boot a fresh EventStore against that pre-seeded disk state. Now
        // simulate the user opening this event under a different system tz.
        let store = EventStore(defaults: defaults)
        XCTAssertEqual(store.calendarEventLogRecords.count, 1,
                       "guard: legacy record must have been loaded from defaults")
        XCTAssertTrue(store.rawCalendarEvents.contains(where: { $0.id == event.id }),
                      "guard: seeded event must be loaded from defaults")

        var nyCal = Calendar(identifier: .gregorian)
        nyCal.timeZone = newYork
        let nyOccurrenceDate = nyCal.startOfDay(for: shanghaiNineAM)
        let readContext = CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: nyOccurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )

        let found = store.logRecord(for: readContext)
        XCTAssertNotNil(found,
                        "legacy on-disk record must be findable after installing the fix")
        XCTAssertEqual(found?.timelineItems.compactMap { $0.noteValue?.text }.first,
                       "legacy testflight note",
                       "legacy note text must survive into post-fix rendering")
    }
}
