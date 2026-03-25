import XCTest
@testable import Done

final class CloudMCPTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    func testApplySyncBatchBuildsProjectionAndSupportsReadQueries() throws {
        let userID = UUID()
        let syncToken = CloudMCPTokenRecord(
            userID: userID,
            label: "iPhone sync",
            rawToken: "sync-token",
            scope: .syncWrite
        )
        let readToken = CloudMCPTokenRecord(
            userID: userID,
            label: "ChatGPT",
            rawToken: "read-token",
            scope: .mcpRead
        )
        let start = date(2026, 3, 24, 9, 0)
        let end = date(2026, 3, 24, 10, 0)
        let event = Event(
            title: "Deep Work",
            note: "Client roadmap planning",
            location: "Office",
            timeRanges: [Event.TimeRange(start: start, end: end)],
            tags: ["focus"],
            type: "Work"
        )
        let occurrenceKey = CalendarOccurrenceKey.make(for: event, occurrenceDate: start, calendar: calendar)
        let timelineNote = EventLogTimelineNote(
            text: "Blocked by design question",
            createdAt: date(2026, 3, 24, 9, 25),
            source: "manual"
        )
        let interruptReference = EventLogInterruptReference(
            childEventID: UUID(),
            createdAt: date(2026, 3, 24, 9, 40)
        )
        let logRecord = CalendarEventLogRecord(
            id: occurrenceKey,
            eventID: event.id,
            baseSeriesEventID: occurrenceKey.baseSeriesEventID,
            occurrenceDate: calendar.startOfDay(for: start),
            selectedTemplateID: EventLogTemplateID.deepWork.rawValue,
            completionStatus: .completed,
            actualDurationMinutes: 60,
            summary: "Focused sprint",
            note: "Budget review prep",
            templateAnswers: ["energy": .int(4)],
            timelineItems: [
                .note(timelineNote),
                .interruptRef(interruptReference),
            ],
            createdAt: date(2026, 3, 24, 10, 5),
            updatedAt: date(2026, 3, 24, 10, 10)
        )

        var server = makeServer(syncToken: syncToken, readToken: readToken)
        let batch = CloudMCPSyncBatch(
            schemaVersion: 1,
            sentAt: date(2026, 3, 24, 10, 15),
            envelopes: [
                try CloudMCPSyncEnvelope.upsertEvent(
                    event,
                    userID: userID,
                    deviceID: UUID(),
                    schemaVersion: 1,
                    sentAt: date(2026, 3, 24, 10, 15),
                    updatedAt: date(2026, 3, 24, 10, 15)
                ),
                try CloudMCPSyncEnvelope.upsertOccurrenceLog(
                    logRecord,
                    userID: userID,
                    deviceID: UUID(),
                    schemaVersion: 1,
                    sentAt: date(2026, 3, 24, 10, 15),
                    updatedAt: logRecord.updatedAt
                ),
            ]
        )

        let syncResult = try server.applySyncBatch(
            batch,
            rawToken: syncToken.rawToken,
            receivedAt: date(2026, 3, 24, 10, 16)
        )
        XCTAssertEqual(syncResult.appliedCount, 2)
        XCTAssertEqual(syncResult.eventCount, 1)
        XCTAssertEqual(syncResult.occurrenceLogCount, 1)

        let fetchedEvent = try server.getCalendarEvent(
            id: event.id,
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 24, 10, 17)
        )
        XCTAssertEqual(fetchedEvent?.title, "Deep Work")
        XCTAssertEqual(fetchedEvent?.location, "Office")
        XCTAssertEqual(fetchedEvent?.note, "Client roadmap planning")

        let occurrences = try server.listCalendarOccurrences(
            in: DateInterval(
                start: date(2026, 3, 24, 0, 0),
                end: date(2026, 3, 25, 0, 0)
            ),
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 24, 10, 18)
        )
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertTrue(occurrences[0].hasLog)
        XCTAssertEqual(occurrences[0].start, start)

        let fetchedLog = try server.getOccurrenceLog(
            eventID: event.id,
            occurrenceDate: start,
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 24, 10, 19)
        )
        XCTAssertEqual(fetchedLog?.summary, "Focused sprint")
        XCTAssertEqual(fetchedLog?.note, "Budget review prep")
        XCTAssertEqual(fetchedLog?.timelineItems.count, 2)
        XCTAssertEqual(fetchedLog?.timelineItems.compactMap(\.noteValue).first?.text, "Blocked by design question")
    }

    func testRecurringSeriesExpandsAcrossWindowAndMarksLoggedOccurrence() throws {
        let userID = UUID()
        let syncToken = CloudMCPTokenRecord(
            userID: userID,
            label: "iPhone sync",
            rawToken: "sync-recur",
            scope: .syncWrite
        )
        let readToken = CloudMCPTokenRecord(
            userID: userID,
            label: "ChatGPT",
            rawToken: "read-recur",
            scope: .mcpRead
        )
        let firstStart = date(2026, 3, 24, 8, 0)
        let recurringEvent = Event(
            title: "Workout",
            note: "Morning routine",
            location: "Gym",
            timeRanges: [Event.TimeRange(start: firstStart, end: date(2026, 3, 24, 9, 0))],
            repeatUnit: .day,
            repeatInterval: 1,
            repeatEndType: .afterCount,
            repeatEndCount: 3,
            tags: ["health"],
            type: "Health"
        )
        let secondOccurrenceDay = date(2026, 3, 25, 0, 0)
        let secondOccurrenceKey = CalendarOccurrenceKey.make(
            for: recurringEvent,
            occurrenceDate: secondOccurrenceDay,
            calendar: calendar
        )
        let secondLog = CalendarEventLogRecord(
            id: secondOccurrenceKey,
            eventID: recurringEvent.id,
            baseSeriesEventID: secondOccurrenceKey.baseSeriesEventID,
            occurrenceDate: secondOccurrenceDay,
            summary: "Felt good",
            note: "",
            timelineItems: [],
            createdAt: date(2026, 3, 25, 9, 5),
            updatedAt: date(2026, 3, 25, 9, 10)
        )

        var server = makeServer(syncToken: syncToken, readToken: readToken)
        _ = try server.applySyncBatch(
            CloudMCPSyncBatch(
                schemaVersion: 1,
                sentAt: date(2026, 3, 24, 9, 30),
                envelopes: [
                    try CloudMCPSyncEnvelope.upsertEvent(
                        recurringEvent,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 24, 9, 30),
                        updatedAt: date(2026, 3, 24, 9, 30)
                    ),
                    try CloudMCPSyncEnvelope.upsertOccurrenceLog(
                        secondLog,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 25, 9, 10),
                        updatedAt: secondLog.updatedAt
                    ),
                ]
            ),
            rawToken: syncToken.rawToken,
            receivedAt: date(2026, 3, 25, 9, 11)
        )

        let occurrences = try server.listCalendarOccurrences(
            in: DateInterval(
                start: date(2026, 3, 24, 0, 0),
                end: date(2026, 3, 27, 0, 0)
            ),
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 25, 9, 12)
        )

        XCTAssertEqual(occurrences.count, 3)
        XCTAssertEqual(occurrences.map { calendar.component(.day, from: $0.occurrenceDate) }, [24, 25, 26])
        XCTAssertEqual(occurrences.filter(\.hasLog).map { calendar.component(.day, from: $0.occurrenceDate) }, [25])
    }

    func testSearchTimelineNotesAndEventTextReturnExpectedHits() throws {
        let userID = UUID()
        let syncToken = CloudMCPTokenRecord(
            userID: userID,
            label: "iPhone sync",
            rawToken: "sync-search",
            scope: .syncWrite
        )
        let readToken = CloudMCPTokenRecord(
            userID: userID,
            label: "ChatGPT",
            rawToken: "read-search",
            scope: .mcpRead
        )
        let event = Event(
            title: "Planning",
            note: "Quarterly budget draft",
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 24, 14, 0), end: date(2026, 3, 24, 15, 0))],
            tags: ["finance"],
            type: "Work"
        )
        let occurrenceKey = CalendarOccurrenceKey.make(for: event, occurrenceDate: date(2026, 3, 24, 14, 0), calendar: calendar)
        let logRecord = CalendarEventLogRecord(
            id: occurrenceKey,
            eventID: event.id,
            baseSeriesEventID: occurrenceKey.baseSeriesEventID,
            occurrenceDate: date(2026, 3, 24, 0, 0),
            summary: "Budget checkpoint",
            note: "Need revised forecast",
            timelineItems: [
                .note(
                    EventLogTimelineNote(
                        text: "Waiting on blocked vendor number",
                        createdAt: date(2026, 3, 24, 14, 22),
                        source: "manual"
                    )
                ),
            ],
            createdAt: date(2026, 3, 24, 15, 1),
            updatedAt: date(2026, 3, 24, 15, 3)
        )

        var server = makeServer(syncToken: syncToken, readToken: readToken)
        _ = try server.applySyncBatch(
            CloudMCPSyncBatch(
                schemaVersion: 1,
                sentAt: date(2026, 3, 24, 15, 5),
                envelopes: [
                    try CloudMCPSyncEnvelope.upsertEvent(
                        event,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 24, 15, 5),
                        updatedAt: date(2026, 3, 24, 15, 5)
                    ),
                    try CloudMCPSyncEnvelope.upsertOccurrenceLog(
                        logRecord,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 24, 15, 5),
                        updatedAt: logRecord.updatedAt
                    ),
                ]
            ),
            rawToken: syncToken.rawToken,
            receivedAt: date(2026, 3, 24, 15, 6)
        )

        let timelineHits = try server.searchTimelineNotes(
            matching: "blocked vendor",
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 24, 15, 7)
        )
        XCTAssertEqual(timelineHits.count, 1)
        XCTAssertEqual(timelineHits.first?.eventTitle, "Planning")
        XCTAssertEqual(timelineHits.first?.note.text, "Waiting on blocked vendor number")

        let textHits = try server.searchEventText(
            matching: "budget",
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 24, 15, 8)
        )
        XCTAssertTrue(textHits.contains(where: { $0.field == .eventNote && $0.text == "Quarterly budget draft" }))
        XCTAssertTrue(textHits.contains(where: { $0.field == .logSummary && $0.text == "Budget checkpoint" }))
    }

    func testOlderUpsertsAreIgnoredAndDeleteTombstonePreventsResurrection() throws {
        let userID = UUID()
        let syncToken = CloudMCPTokenRecord(
            userID: userID,
            label: "iPhone sync",
            rawToken: "sync-order",
            scope: .syncWrite
        )
        let readToken = CloudMCPTokenRecord(
            userID: userID,
            label: "ChatGPT",
            rawToken: "read-order",
            scope: .mcpRead
        )
        let eventID = UUID()
        let olderEvent = Event(
            id: eventID,
            title: "Old Title",
            note: "",
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 26, 9, 0), end: date(2026, 3, 26, 10, 0))],
            type: "Work"
        )
        let newerEvent = Event(
            id: eventID,
            title: "New Title",
            note: "",
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 26, 9, 0), end: date(2026, 3, 26, 10, 0))],
            type: "Work"
        )

        var server = makeServer(syncToken: syncToken, readToken: readToken)
        _ = try server.applySyncBatch(
            CloudMCPSyncBatch(
                schemaVersion: 1,
                sentAt: date(2026, 3, 26, 9, 0),
                envelopes: [
                    try CloudMCPSyncEnvelope.upsertEvent(
                        newerEvent,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 26, 9, 5),
                        updatedAt: date(2026, 3, 26, 9, 5)
                    ),
                    try CloudMCPSyncEnvelope.upsertEvent(
                        newerEvent,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 26, 9, 5),
                        updatedAt: date(2026, 3, 26, 9, 5)
                    ),
                    try CloudMCPSyncEnvelope.upsertEvent(
                        olderEvent,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 26, 9, 1),
                        updatedAt: date(2026, 3, 26, 9, 1)
                    ),
                ]
            ),
            rawToken: syncToken.rawToken,
            receivedAt: date(2026, 3, 26, 9, 6)
        )

        let fetchedAfterUpserts = try server.getCalendarEvent(
            id: eventID,
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 26, 9, 7)
        )
        XCTAssertEqual(fetchedAfterUpserts?.title, "New Title")

        _ = try server.applySyncBatch(
            CloudMCPSyncBatch(
                schemaVersion: 1,
                sentAt: date(2026, 3, 26, 9, 8),
                envelopes: [
                    try CloudMCPSyncEnvelope.deleteEvent(
                        eventID: eventID,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 26, 9, 8),
                        updatedAt: date(2026, 3, 26, 9, 8)
                    ),
                    try CloudMCPSyncEnvelope.upsertEvent(
                        olderEvent,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 26, 9, 1),
                        updatedAt: date(2026, 3, 26, 9, 1)
                    ),
                ]
            ),
            rawToken: syncToken.rawToken,
            receivedAt: date(2026, 3, 26, 9, 9)
        )

        let fetchedAfterDelete = try server.getCalendarEvent(
            id: eventID,
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 26, 9, 10)
        )
        XCTAssertNil(fetchedAfterDelete)
    }

    func testTokenScopesAreSeparatedAndRevocationStopsAccess() throws {
        let userID = UUID()
        let syncToken = CloudMCPTokenRecord(
            userID: userID,
            label: "iPhone sync",
            rawToken: "sync-auth",
            scope: .syncWrite
        )
        let readToken = CloudMCPTokenRecord(
            userID: userID,
            label: "ChatGPT",
            rawToken: "read-auth",
            scope: .mcpRead
        )
        var server = makeServer(syncToken: syncToken, readToken: readToken)

        XCTAssertThrowsError(
            try server.listCalendarOccurrences(
                in: DateInterval(start: date(2026, 3, 24, 0, 0), end: date(2026, 3, 25, 0, 0)),
                rawToken: syncToken.rawToken,
                calendar: calendar,
                requestedAt: date(2026, 3, 24, 8, 0)
            )
        ) { error in
            XCTAssertEqual(error as? CloudMCPServerError, .unauthorized)
        }

        XCTAssertThrowsError(
            try server.applySyncBatch(
                CloudMCPSyncBatch(schemaVersion: 1, sentAt: date(2026, 3, 24, 8, 1), envelopes: []),
                rawToken: readToken.rawToken,
                receivedAt: date(2026, 3, 24, 8, 1)
            )
        ) { error in
            XCTAssertEqual(error as? CloudMCPServerError, .unauthorized)
        }

        XCTAssertTrue(server.revokeToken(rawToken: readToken.rawToken, at: date(2026, 3, 24, 8, 2)))

        XCTAssertThrowsError(
            try server.getScheduleForDate(
                date(2026, 3, 24, 0, 0),
                rawToken: readToken.rawToken,
                calendar: calendar,
                requestedAt: date(2026, 3, 24, 8, 3)
            )
        ) { error in
            XCTAssertEqual(error as? CloudMCPServerError, .unauthorized)
        }

        XCTAssertEqual(server.auditEntries.filter { !$0.succeeded }.count, 3)
    }

    func testGetScheduleForDateSeparatesAllDayAndTimedOccurrences() throws {
        let userID = UUID()
        let syncToken = CloudMCPTokenRecord(
            userID: userID,
            label: "iPhone sync",
            rawToken: "sync-schedule",
            scope: .syncWrite
        )
        let readToken = CloudMCPTokenRecord(
            userID: userID,
            label: "ChatGPT",
            rawToken: "read-schedule",
            scope: .mcpRead
        )
        let allDay = Event(
            title: "Offsite",
            note: "",
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 30, 0, 0), end: date(2026, 3, 31, 0, 0))],
            isAllDay: true,
            type: "Travel"
        )
        let timed = Event(
            title: "Standup",
            note: "",
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 30, 9, 0), end: date(2026, 3, 30, 9, 30))],
            type: "Work"
        )

        var server = makeServer(syncToken: syncToken, readToken: readToken)
        _ = try server.applySyncBatch(
            CloudMCPSyncBatch(
                schemaVersion: 1,
                sentAt: date(2026, 3, 30, 10, 0),
                envelopes: [
                    try CloudMCPSyncEnvelope.upsertEvent(
                        allDay,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 30, 10, 0),
                        updatedAt: date(2026, 3, 30, 10, 0)
                    ),
                    try CloudMCPSyncEnvelope.upsertEvent(
                        timed,
                        userID: userID,
                        deviceID: UUID(),
                        schemaVersion: 1,
                        sentAt: date(2026, 3, 30, 10, 0),
                        updatedAt: date(2026, 3, 30, 10, 0)
                    ),
                ]
            ),
            rawToken: syncToken.rawToken,
            receivedAt: date(2026, 3, 30, 10, 1)
        )

        let schedule = try server.getScheduleForDate(
            date(2026, 3, 30, 0, 0),
            rawToken: readToken.rawToken,
            calendar: calendar,
            requestedAt: date(2026, 3, 30, 10, 2)
        )

        XCTAssertEqual(schedule.allDayOccurrences.count, 1)
        XCTAssertEqual(schedule.timedOccurrences.count, 1)
        XCTAssertEqual(schedule.allDayOccurrences.first?.title, "Offsite")
        XCTAssertEqual(schedule.timedOccurrences.first?.title, "Standup")
    }

    private func makeServer(
        syncToken: CloudMCPTokenRecord,
        readToken: CloudMCPTokenRecord
    ) -> CloudMCPInMemoryServer {
        var server = CloudMCPInMemoryServer(
            config: CloudMCPServerConfig(schemaVersion: 1)
        )
        server.registerToken(syncToken)
        server.registerToken(readToken)
        return server
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

@MainActor
final class CloudMCPEventStoreBridgeTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var store: EventStore!
    private var calendar: Calendar!

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "CloudMCPEventStoreBridgeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        store = EventStore(defaults: defaults)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    override func tearDown() async throws {
        if let defaultsSuiteName, let defaults {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        store = nil
        defaults = nil
        defaultsSuiteName = nil
        calendar = nil
        try await super.tearDown()
    }

    func testFullSnapshotFromEventStoreIncludesEventsAndLogs() throws {
        let event = Event(
            title: "Review",
            note: "Review cloud sync design",
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 28, 11, 0), end: date(2026, 3, 28, 12, 0))],
            type: "Work"
        )
        store.addCalendarEvent(event)

        let occurrence = CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: date(2026, 3, 28, 11, 0),
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
        store.appendTimelineNote(
            "Captured follow-up",
            createdAt: date(2026, 3, 28, 11, 20),
            source: "manual",
            for: occurrence
        )

        let batch = try CloudMCPSyncBatch.fullSnapshot(
            from: store,
            userID: UUID(),
            deviceID: UUID(),
            schemaVersion: 1,
            sentAt: date(2026, 3, 28, 12, 30)
        )

        XCTAssertEqual(batch.envelopes.count, 2)
        XCTAssertTrue(batch.envelopes.contains(where: {
            $0.entityType == .calendarEvent && $0.payload?.calendarEventValue?.id == event.id
        }))
        XCTAssertTrue(batch.envelopes.contains(where: {
            guard $0.entityType == .occurrenceLog else { return false }
            return $0.payload?.occurrenceLogValue?.timelineItems.compactMap(\.noteValue).first?.text == "Captured follow-up"
        }))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
