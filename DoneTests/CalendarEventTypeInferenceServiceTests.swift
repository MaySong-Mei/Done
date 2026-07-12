import XCTest
@testable import Done

@MainActor
final class CalendarEventTypeInferenceServiceTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var store: EventStore!
    private let calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "CalendarEventTypeInferenceServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        store = EventStore(defaults: defaults)
    }

    override func tearDown() {
        if let defaultsSuiteName, let defaults {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        store = nil
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testLocalSuggestionUpdatesTypeAndLogTemplate() async {
        let service = CalendarEventTypeInferenceService(defaults: defaults)
        let historical = EventLogTemplateAdvisor(defaults: defaults).applySuggestion(
            to: Event(
                title: "Client meeting",
                note: "Discuss roadmap",
                location: "",
                timeRanges: [Event.TimeRange(start: date(2026, 2, 28, 9, 0), end: date(2026, 2, 28, 10, 0))],
                type: "Work"
            )
        )
        store.addCalendarEvent(historical)
        let event = EventLogTemplateAdvisor(defaults: defaults).applySuggestion(
            to: Event(
                title: "Client meeting",
                note: "Discuss roadmap",
                location: "",
                timeRanges: [Event.TimeRange(start: date(2026, 3, 1, 9, 0), end: date(2026, 3, 1, 10, 0))],
                type: "Study"
            )
        )
        store.addCalendarEvent(event)

        await service.inferTypeIfNeeded(
            for: event,
            savedForm: makeForm(
                title: "Client meeting",
                note: "Discuss roadmap",
                typeTitle: "Study",
                didExplicitlySelectType: false
            ),
            isSuggestionEnabled: true,
            store: store
        )

        let updated = try! XCTUnwrap(store.findCalendarEvent(id: event.id))
        XCTAssertEqual(updated.type, "Work")
        XCTAssertEqual(updated.suggestedLogTemplateID, EventLogTemplateID.meeting.rawValue)
    }

    func testExplicitTypeSelectionSkipsInference() async {
        let service = CalendarEventTypeInferenceService(defaults: defaults)
        let event = Event(
            title: "Morning run",
            note: "",
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 1, 7, 0), end: date(2026, 3, 1, 8, 0))],
            type: "Exercise"
        )
        store.addCalendarEvent(event)

        await service.inferTypeIfNeeded(
            for: event,
            savedForm: makeForm(
                title: "Morning run",
                note: "",
                typeTitle: "Exercise",
                didExplicitlySelectType: true
            ),
            isSuggestionEnabled: true,
            store: store
        )

        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.type, "Exercise")
    }

    // Local-only since the LLM fallback was removed: text neither the
    // historical nor the keyword path can place leaves the event's type
    // exactly as saved.
    func testLocalMissLeavesTypeUnchanged() async {
        let service = CalendarEventTypeInferenceService(defaults: defaults)
        let event = Event(
            title: "Inbox cleanup",
            note: "Sort pending messages",
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 1, 15, 0), end: date(2026, 3, 1, 16, 0))],
            type: "Study"
        )
        store.addCalendarEvent(event)

        await service.inferTypeIfNeeded(
            for: event,
            savedForm: makeForm(
                title: "Inbox cleanup",
                note: "Sort pending messages",
                typeTitle: "Study",
                didExplicitlySelectType: false
            ),
            isSuggestionEnabled: true,
            store: store
        )

        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.type, "Study")
    }

    func testPreferredLocalSuggestionUsesHistoricalEventMatch() {
        let suggestion = calendarPreferredLocalTypeSuggestion(
            rawText: "Inbox cleanup tomorrow",
            availableTypes: ["Study", "Work", "Exercise"],
            historicalEvents: [
                Event(
                    title: "Inbox cleanup",
                    note: "Sort pending messages",
                    location: "",
                    timeRanges: [Event.TimeRange(start: date(2026, 2, 25, 15, 0), end: date(2026, 2, 25, 16, 0))],
                    type: "Work"
                )
            ]
        )

        XCTAssertEqual(suggestion?.typeTitle, "Work")
        XCTAssertEqual(suggestion?.source, .local)
    }

    func testPreferredLocalSuggestionMatchesPartialHistoricalTitlePrefix() {
        let suggestion = calendarPreferredLocalTypeSuggestion(
            rawText: "Client mee",
            availableTypes: ["Study", "Work", "Exercise"],
            historicalEvents: [
                Event(
                    title: "Client meeting",
                    note: "Discuss roadmap",
                    location: "",
                    timeRanges: [Event.TimeRange(start: date(2026, 2, 25, 15, 0), end: date(2026, 2, 25, 16, 0))],
                    type: "Work"
                )
            ]
        )

        XCTAssertEqual(suggestion?.typeTitle, "Work")
    }

    func testPreferredLocalSuggestionMatchesPartialKeywordPrefix() {
        let suggestion = calendarPreferredLocalTypeSuggestion(
            rawText: "mee",
            availableTypes: ["Study", "Work", "Exercise"],
            historicalEvents: []
        )

        XCTAssertEqual(suggestion?.typeTitle, "Work")
    }

    func testHistoricalSuggestionIgnoresTypesOutsideCurrentTemplateLibrary() {
        let suggestion = calendarPreferredLocalTypeSuggestion(
            rawText: "Neighborhood walk",
            availableTypes: ["Study", "Work", "Exercise"],
            historicalEvents: [
                Event(
                    title: "Neighborhood walk",
                    note: "",
                    location: "",
                    timeRanges: [Event.TimeRange(start: date(2026, 2, 24, 18, 0), end: date(2026, 2, 24, 18, 30))],
                    type: "Personal"
                )
            ]
        )

        // The historical event's type ("Personal") is unavailable, so
        // it's not echoed back. Content-based inference may still match
        // an available type (e.g. "walk" → "Exercise"). Either nil or
        // a match from the available set is acceptable — just not
        // "Personal".
        if let suggestion {
            XCTAssertNotEqual(suggestion.typeTitle, "Personal")
            XCTAssertTrue(["Study", "Work", "Exercise"].contains(suggestion.typeTitle))
        }
    }

    private func makeForm(
        title: String,
        note: String,
        typeTitle: String,
        didExplicitlySelectType: Bool
    ) -> CalendarEventFormData {
        CalendarEventFormData(
            title: title,
            typeTitle: typeTitle,
            note: note,
            location: "",
            startTime: date(2026, 3, 1, 9, 0),
            endTime: date(2026, 3, 1, 10, 0),
            isAllDay: false,
            repeatUnit: .none,
            repeatInterval: 1,
            repeatEndType: .none,
            repeatEndDate: nil,
            repeatEndCount: nil,
            didExplicitlySelectType: didExplicitlySelectType,
            agenticIntake: nil
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }
}
