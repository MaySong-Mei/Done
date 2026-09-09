import XCTest
@testable import Done

@MainActor
final class CalendarEventTypeInferenceServiceTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var store: EventStore!
    private let calendar = Calendar(identifier: .gregorian)
    /// Suites for the non-seeding stores the gh#37 store-cache tests build, so
    /// they start from a KNOWN-empty corpus (the shared `store` above seeds
    /// sample events on load, which would place stray matches).
    private var extraSuites: [String] = []

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "CalendarEventTypeInferenceServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        TestStorage.reset(defaultsSuiteName)
        store = EventStore(defaults: defaults, storage: .isolated(name: defaultsSuiteName))
    }

    override func tearDown() {
        for suite in extraSuites {
            TestStorage.tearDown(suite)
        }
        extraSuites = []
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

    // MARK: - gh#37 store-cache contracts
    //
    // The suite above pins the PURE scorer. These pin the STORE CACHE the
    // five while-typing/post-save call sites now share — a different thing.
    // A stale-type bug (G1) or a lost self-exclusion (G2) would leave every
    // pure-function test green and only show up through the cache, which is
    // exactly why they live here and drive `store.calendarTypeSuggestion(...)`.
    //
    // They build their OWN non-seeding store: the shared `store` seeds sample
    // events on load ("Team Standup"/Work, "Lunch Run"/Exercise, …), which
    // would place stray matches under the exact titles these tests probe.

    private func makeEmptyStore(_ label: String) -> (store: EventStore, defaults: UserDefaults) {
        let suite = "CETIS-\(label)-\(UUID().uuidString)"
        extraSuites.append(suite)
        TestStorage.reset(suite)
        let suiteDefaults = UserDefaults(suiteName: suite)!
        let emptyStore = EventStore(
            defaults: suiteDefaults,
            storage: .isolated(name: suite),
            seedsSampleDataIfEmpty: false
        )
        return (emptyStore, suiteDefaults)
    }

    @discardableResult
    private func seed(_ store: EventStore, title: String, note: String = "", type: String) -> Event {
        let event = Event(
            title: title,
            note: note,
            location: "",
            timeRanges: [Event.TimeRange(start: date(2026, 3, 1, 9, 0), end: date(2026, 3, 1, 10, 0))],
            type: type
        )
        store.addCalendarEvent(event)
        return event
    }

    /// The cache's entire reason to exist: normalize once per corpus change,
    /// not once per keystroke. A correctness assertion cannot see this — the
    /// answer is identical whether the corpus rebuilds every call or never —
    /// so it is pinned by the build counter, the way gh#213 pins its index.
    func testCorpusRebuildsOncePerRevisionNotPerPass() {
        let (store, _) = makeEmptyStore("rebuild")
        seed(store, title: "Client meeting", type: "Work")
        seed(store, title: "Morning run", type: "Exercise")

        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 0)

        // Two passes, no store write between them: one build, one reuse.
        _ = store.calendarTypeSuggestion(rawText: "meeting", availableTypes: ["Study", "Work"])
        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 1)
        _ = store.calendarTypeSuggestion(rawText: "meet", availableTypes: ["Study", "Work"])
        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 1,
                       "a keystroke that wrote nothing to the store must reuse the corpus")

        // A store write bumps searchCorpusRevision; the next pass rebuilds.
        seed(store, title: "Standup", type: "Work")
        _ = store.calendarTypeSuggestion(rawText: "standup", availableTypes: ["Study", "Work"])
        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 2)
    }

    /// gh#37 G1 THROUGH THE CACHE. Same cached corpus (build count does not
    /// move), a different `availableTypes` on the second pass, a different
    /// answer — proving the entry stores the RAW type and resolves against
    /// the CURRENT library every pass. If a resolved type were ever baked
    /// into the revision-keyed corpus, pass B would still miss "Exercise"
    /// because no store write happened to rebuild it. This is the check the
    /// pure-function `testHistoricalSuggestionIgnoresTypesOutsideCurrentTemplateLibrary`
    /// structurally cannot make.
    func testAvailableTypeLibraryChangeReflectedWithoutCorpusRebuild() {
        let (store, _) = makeEmptyStore("librarychange")
        seed(store, title: "Neighborhood walk", type: "Exercise")

        // Warm the corpus with a library that does NOT contain "Exercise".
        let passA = store.calendarTypeSuggestion(
            rawText: "Neighborhood walk",
            availableTypes: ["Study", "Work"]
        )
        XCTAssertNil(passA, "Exercise is not in the library, so nothing should be suggested")
        let buildsAfterA = store.typeSuggestionCorpusBuildCount

        // Widen the library (simulating an EventTypeTemplateStore.add, which
        // does NOT bump searchCorpusRevision) and ask again. No store write
        // happened, so the corpus is reused — yet the answer must change.
        let passB = store.calendarTypeSuggestion(
            rawText: "Neighborhood walk",
            availableTypes: ["Study", "Work", "Exercise"]
        )
        XCTAssertEqual(passB?.typeTitle, "Exercise")
        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, buildsAfterA,
                       "the answer changed with the library while the SAME cached corpus was reused")
    }

    /// gh#37 G2 THROUGH THE CACHE. The shared corpus includes the just-saved
    /// event (its write rebuilt the corpus). Without exclusion an event
    /// matches its own identical title back to itself (0.99); the post-save
    /// path passes its own id to `excludingEventID` to prevent exactly that.
    func testPostSaveSelfMatchExcludedThroughCache() {
        let (store, _) = makeEmptyStore("selfmatch")
        let event = seed(store, title: "Standup", type: "Work")

        let withoutExclusion = store.calendarTypeSuggestion(
            rawText: "Standup",
            availableTypes: ["Study", "Work"]
        )
        XCTAssertEqual(withoutExclusion?.typeTitle, "Work",
                       "the identical-title row matches itself when not excluded")

        let withExclusion = store.calendarTypeSuggestion(
            rawText: "Standup",
            availableTypes: ["Study", "Work"],
            excludingEventID: event.id
        )
        XCTAssertNil(withExclusion,
                     "excluding the only row removes the self-match; no other source places 'Standup'")
    }

    // MARK: - gh#37 G5 verification hook

    func testDiagnosticsLineCarriesEveryG5Field() {
        let types = ["Study", "Work"]
        let line = CalendarTypeSuggestionDiagnostics.line(
            events: 2690,
            corpus: 2600,
            cacheHit: true,
            availableTypes: types,
            elapsedUs: 42
        )
        XCTAssertTrue(line.contains("events=2690"), line)
        XCTAssertTrue(line.contains("corpus=2600"), line)
        XCTAssertTrue(line.contains("cacheHit=true"), line)
        XCTAssertTrue(line.contains("elapsedUs=42"), line)
        XCTAssertTrue(
            line.contains("availableTypesGen=\(CalendarTypeSuggestionDiagnostics.availableTypesGeneration(types))"),
            line
        )
    }

    func testAvailableTypesGenerationIsDeterministicAndOrderSensitive() {
        let gen = CalendarTypeSuggestionDiagnostics.availableTypesGeneration(["Study", "Work"])
        XCTAssertEqual(gen, CalendarTypeSuggestionDiagnostics.availableTypesGeneration(["Study", "Work"]),
                       "same library must fingerprint identically across calls")
        XCTAssertNotEqual(gen, CalendarTypeSuggestionDiagnostics.availableTypesGeneration(["Work", "Study"]),
                          "resolution returns the first normalize-equal title, so a reorder is a real change")
        XCTAssertNotEqual(gen, CalendarTypeSuggestionDiagnostics.availableTypesGeneration(["Study", "Work", "Exercise"]),
                          "adding a type must change the generation")
    }

    func testDiagnosticsGateOffByDefaultAndTogglesWithFlag() {
        let (_, suiteDefaults) = makeEmptyStore("gate")
        XCTAssertFalse(CalendarTypeSuggestionDiagnostics.isEnabled(suiteDefaults))
        suiteDefaults.set(true, forKey: CalendarTypeSuggestionDiagnostics.enabledDefaultsKey)
        XCTAssertTrue(CalendarTypeSuggestionDiagnostics.isEnabled(suiteDefaults))
    }

    /// The sink actually receives the line when armed, and is silent when not
    /// — the DraftSlot trail is tested the same way (gh#185).
    func testEnabledPassWritesTrailLineAndDisabledDoesNot() {
        let (store, suiteDefaults) = makeEmptyStore("trail")
        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        seed(store, title: "Client meeting", type: "Work")

        // Gate off (default): no line for our category.
        _ = store.calendarTypeSuggestion(rawText: "meeting", availableTypes: ["Study", "Work"])
        XCTAssertFalse(
            DiagnosticTrail.combinedText().contains(CalendarTypeSuggestionDiagnostics.trailCategory),
            "a disabled pass must write nothing"
        )

        // Gate on: a pass line lands.
        suiteDefaults.set(true, forKey: CalendarTypeSuggestionDiagnostics.enabledDefaultsKey)
        _ = store.calendarTypeSuggestion(rawText: "meeting", availableTypes: ["Study", "Work"])
        XCTAssertTrue(
            DiagnosticTrail.combinedText().contains(CalendarTypeSuggestionDiagnostics.trailCategory),
            "an armed pass must append one line to the trail"
        )
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
