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
        TestStorage.reset(defaultsSuiteName)
        store = EventStore(defaults: defaults, storage: .isolated(name: defaultsSuiteName))
    }

    override func tearDown() {
        if let defaultsSuiteName {
            TestStorage.tearDown(defaultsSuiteName)
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

    // gh#182: before this fix, most local-scoring entry points never wired
    // the real setting value through this predicate (or an equivalent
    // inline check) — they either hardcoded `true` or skipped the
    // enablement check entirely. The interrupt/parallel composer post-save
    // sites call `inferTypeIfNeeded` directly, the exact method under test
    // here. `isSuggestionEnabled: false` was never exercised by any
    // existing test. Same fixture shape as
    // `testLocalSuggestionUpdatesTypeAndLogTemplate` (which proves this
    // exact scenario WOULD mutate the type when enabled) but flipped to
    // disabled, so the "no mutation" outcome is a real negative, not an
    // absence of matching evidence.
    func testSuggestionDisabledSkipsPostSaveInference() async {
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
            isSuggestionEnabled: false,
            store: store
        )

        // Same historical data that flips this to "Work" when enabled
        // (see testLocalSuggestionUpdatesTypeAndLogTemplate) — with the
        // setting off, the saved type must survive untouched.
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.type, "Study")
    }

    // gh#182: `calendarShouldRunPostSaveTypeSuggestion` is the single gate
    // every local-scoring type-inference entry point routes its enablement
    // through (the LLM autofill path is a separate mechanism — see
    // `calendarReminderScheduleAutofillTypeTitle` — and does not call this).
    // The while-typing sites call it directly (CalendarEventFormView's
    // `allowsAutomaticTypeSelection` guard is the same boolean algebra;
    // CalendarEventDetailView's and CalendarInterruptComposer's while-typing
    // sites call it literally), and the post-save sites reach it through
    // `inferTypeIfNeeded` above. Pinning all 4 boolean combinations here
    // protects every one of those call sites' shared decision logic in one
    // place, per the project's single-source-predicate convention.
    func testShouldRunPostSaveTypeSuggestionRequiresEnabledAndNotExplicit() {
        XCTAssertTrue(calendarShouldRunPostSaveTypeSuggestion(
            isEnabled: true,
            didExplicitlySelectType: false
        ))
        XCTAssertFalse(calendarShouldRunPostSaveTypeSuggestion(
            isEnabled: false,
            didExplicitlySelectType: false
        ))
        XCTAssertFalse(calendarShouldRunPostSaveTypeSuggestion(
            isEnabled: true,
            didExplicitlySelectType: true
        ))
        XCTAssertFalse(calendarShouldRunPostSaveTypeSuggestion(
            isEnabled: false,
            didExplicitlySelectType: true
        ))
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
