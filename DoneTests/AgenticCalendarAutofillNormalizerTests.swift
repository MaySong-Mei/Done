import XCTest
@testable import Done

final class AgenticCalendarAutofillNormalizerTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    func testExplicitTypeHintExtractionPreservesInterruptSeedType() {
        XCTAssertEqual(
            calendarExplicitTypeHint(
                from: """
                Call vendor
                type use Urgent
                """
            ),
            "Urgent"
        )
    }

    func testResolvedAutofillTypeTitlePreservesExplicitTypeOutsideTemplateLibrary() {
        let resolved = calendarResolvedAutofillTypeTitle(
            aiSuggestedTypeTitle: "Work",
            explicitTypeHint: "Urgent",
            availableTypes: ["Study", "Work"],
            defaultType: "Study"
        )

        XCTAssertEqual(resolved.typeTitle, "Urgent")
        XCTAssertFalse(resolved.shouldWarnAboutFallback)
    }

    func testResolvedAutofillTypeTitleFallsBackForUnexpectedOutOfLibraryAISuggestion() {
        let resolved = calendarResolvedAutofillTypeTitle(
            aiSuggestedTypeTitle: "Personal",
            explicitTypeHint: nil,
            availableTypes: ["Study", "Work"],
            defaultType: "Study"
        )

        XCTAssertEqual(resolved.typeTitle, "Study")
        XCTAssertTrue(resolved.shouldWarnAboutFallback)
    }

    func testDragCreateLocksTimeRange() {
        let dragRange = Event.TimeRange(
            start: date(2026, 2, 24, 9, 0),
            end: date(2026, 2, 24, 10, 0)
        )
        let pending = PendingEventCreation(
            date: dragRange.start,
            timeRange: dragRange,
            source: .dragCreate,
            anchorVisibleDate: dragRange.start
        )
        let context = AgenticCalendarContext(visibleDate: dragRange.start, nearbyEventsSummary: "")
        let input = sampleResult(start: date(2026, 2, 25, 13, 7), end: date(2026, 2, 25, 15, 7))

        let output = AgenticCalendarAutofillNormalizer.normalize(input, pendingCreate: pending, context: context, calendar: calendar)

        XCTAssertEqual(output.startTime, dragRange.start)
        XCTAssertEqual(output.endTime, dragRange.end)
        XCTAssertFalse(output.isAllDay)
    }

    func testQuickAddOutOfRangeDateFallsBackToPendingRange() {
        let pendingRange = Event.TimeRange(
            start: date(2026, 2, 24, 14, 0),
            end: date(2026, 2, 24, 15, 0)
        )
        let pending = PendingEventCreation(
            date: pendingRange.start,
            timeRange: pendingRange,
            source: .quickAdd,
            anchorVisibleDate: date(2026, 2, 24, 0, 0)
        )
        let context = AgenticCalendarContext(visibleDate: date(2026, 2, 24, 0, 0), nearbyEventsSummary: "", now: date(2026, 2, 24, 12, 0), timeZoneIdentifier: "UTC")
        let input = sampleResult(start: date(2026, 3, 20, 9, 0), end: date(2026, 3, 20, 10, 0))

        let output = AgenticCalendarAutofillNormalizer.normalize(input, pendingCreate: pending, context: context, calendar: calendar)

        XCTAssertEqual(output.startTime, pendingRange.start)
        XCTAssertEqual(output.endTime, pendingRange.end)
        XCTAssertTrue(output.warnings.contains { $0.contains("too far") })
    }

    func testInvalidDurationIsRepairedAndRoundedToQuarterHour() {
        let pendingRange = Event.TimeRange(start: date(2026, 2, 24, 8, 0), end: date(2026, 2, 24, 9, 0))
        let pending = PendingEventCreation(
            date: pendingRange.start,
            timeRange: pendingRange,
            source: .quickAdd,
            anchorVisibleDate: pendingRange.start
        )
        let context = AgenticCalendarContext(visibleDate: pendingRange.start, nearbyEventsSummary: "")
        let input = sampleResult(start: date(2026, 2, 24, 10, 7), end: date(2026, 2, 24, 10, 3))

        let output = AgenticCalendarAutofillNormalizer.normalize(input, pendingCreate: pending, context: context, calendar: calendar)

        XCTAssertEqual(calendar.component(.minute, from: output.startTime) % 15, 0)
        XCTAssertEqual(calendar.component(.minute, from: output.endTime) % 15, 0)
        XCTAssertGreaterThan(output.endTime, output.startTime)
    }

    func testQuickAddAllowsCrossDayWithinSevenDays() {
        let pendingRange = Event.TimeRange(
            start: date(2026, 2, 24, 14, 0),
            end: date(2026, 2, 24, 15, 0)
        )
        let pending = PendingEventCreation(
            date: pendingRange.start,
            timeRange: pendingRange,
            source: .quickAdd,
            anchorVisibleDate: date(2026, 2, 24, 0, 0)
        )
        let context = AgenticCalendarContext(
            visibleDate: date(2026, 2, 24, 0, 0),
            nearbyEventsSummary: "",
            now: date(2026, 2, 24, 8, 0),
            timeZoneIdentifier: "UTC"
        )
        let input = sampleResult(
            start: date(2026, 2, 27, 11, 2),
            end: date(2026, 2, 27, 12, 3)
        )

        let output = AgenticCalendarAutofillNormalizer.normalize(
            input,
            pendingCreate: pending,
            context: context,
            calendar: calendar
        )

        XCTAssertEqual(calendar.component(.day, from: output.startTime), 27)
        XCTAssertEqual(calendar.component(.minute, from: output.startTime) % 15, 0)
        XCTAssertFalse(output.warnings.contains { $0.contains("too far") })
    }

    private func sampleResult(start: Date, end: Date) -> AgenticCalendarAutofillResult {
        AgenticCalendarAutofillResult(
            title: "测试事件",
            typeTitle: "Study",
            note: "note",
            location: "",
            startTime: start,
            endTime: end,
            isAllDay: false,
            repeatUnit: .none,
            repeatInterval: 1,
            repeatEndType: .none,
            repeatEndDate: nil,
            repeatEndCount: nil,
            confidence: 0.7,
            warnings: [],
            usedVision: false,
            providerName: "openai",
            providerModel: "gpt-4o"
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

@MainActor
final class CalendarAgenticCreateCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: EventStore!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "CalendarAgenticCreateCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        store = EventStore(defaults: defaults)
    }

    override func tearDown() async throws {
        if let defaultsSuiteName, let defaults {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        store = nil
        defaults = nil
        defaultsSuiteName = nil
        try await super.tearDown()
    }

    func testSubmitOptimisticCreateKeepsPlaceholderTimeWhenAutofillCompletes() async throws {
        let finalRange = Event.TimeRange(
            start: date(2026, 3, 2, 11, 0),
            end: date(2026, 3, 2, 12, 0)
        )
        let service = StubAutofillService(
            mode: .success(sampleResult(title: "AI Final Title", type: "Work", range: finalRange)),
            delayNanoseconds: 120_000_000
        )
        let coordinator = CalendarAgenticCreateCoordinator(
            intakeService: service,
            assetStore: AgenticIntakeAssetStore()
        )
        let pending = makePendingQuickAdd()
        let context = AgenticCalendarContext(visibleDate: pending.anchorVisibleDate, nearbyEventsSummary: "")

        let placeholder = coordinator.submitOptimisticCreate(
            rawText: "跟产品开会讨论需求",
            selectedImages: [],
            pendingCreate: pending,
            calendarContext: context,
            availableTypes: ["Work", "Study"],
            uiWarnings: [],
            store: store
        )

        XCTAssertEqual(store.rawCalendarEvents.count, 1)
        XCTAssertEqual(placeholder.agenticIntake?.processingPhase, .analyzing)
        XCTAssertEqual(store.rawCalendarEvents.first?.agenticIntake?.processingPhase, .analyzing)
        XCTAssertEqual(store.rawCalendarEvents.first?.title, "跟产品开会讨论需求")

        try await waitUntil {
            self.store.rawCalendarEvents.first?.agenticIntake?.processingPhase == .completed
        }

        let updated = try XCTUnwrap(store.rawCalendarEvents.first)
        XCTAssertEqual(updated.title, "跟产品开会讨论需求")
        XCTAssertEqual(updated.type, "Work")
        XCTAssertEqual(updated.primaryTimeRange?.start, pending.timeRange.start)
        XCTAssertEqual(updated.primaryTimeRange?.end, pending.timeRange.end)
        XCTAssertEqual(updated.agenticIntake?.processingPhase, .completed)
        XCTAssertNotNil(updated.agenticIntake?.providerMetadata)
        XCTAssertNil(coordinator.banner)
    }

    func testFailureKeepsPlaceholderAndMarksFailed() async throws {
        let service = StubAutofillService(
            mode: .failure(NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Mock failure"])),
            delayNanoseconds: 20_000_000
        )
        let coordinator = CalendarAgenticCreateCoordinator(
            intakeService: service,
            assetStore: AgenticIntakeAssetStore()
        )
        let pending = makePendingQuickAdd()
        let context = AgenticCalendarContext(visibleDate: pending.anchorVisibleDate, nearbyEventsSummary: "")

        let placeholder = coordinator.submitOptimisticCreate(
            rawText: "写测试",
            selectedImages: [],
            pendingCreate: pending,
            calendarContext: context,
            availableTypes: ["Study"],
            uiWarnings: [],
            store: store
        )

        XCTAssertEqual(placeholder.agenticIntake?.processingPhase, .analyzing)

        try await waitUntil {
            self.store.rawCalendarEvents.first?.agenticIntake?.processingPhase == .failed
        }

        let updated = try XCTUnwrap(store.rawCalendarEvents.first)
        XCTAssertEqual(updated.id, placeholder.id)
        XCTAssertEqual(updated.agenticIntake?.processingPhase, .failed)
        XCTAssertEqual(updated.agenticIntake?.failureMessage, "Mock failure")

        guard case .failed(let eventID, let message)? = coordinator.banner else {
            return XCTFail("Expected failed banner")
        }
        XCTAssertEqual(eventID, placeholder.id)
        XCTAssertEqual(message, "Mock failure")
    }

    func testAttachedInterruptPlaceholderRemainsInterruptAfterAutofillCompletes() async throws {
        let parentRange = Event.TimeRange(
            start: date(2026, 3, 2, 10, 0),
            end: date(2026, 3, 2, 12, 0)
        )
        let parent = Event(
            title: "Parent",
            note: "",
            location: "",
            timeRanges: [parentRange],
            type: "Work"
        )
        store.addCalendarEvent(parent)

        let interruptRange = Event.TimeRange(
            start: date(2026, 3, 2, 10, 30),
            end: date(2026, 3, 2, 11, 0)
        )
        let service = StubAutofillService(
            mode: .success(sampleResult(title: "AI Interrupt", type: "Urgent", range: interruptRange)),
            delayNanoseconds: 60_000_000
        )
        let coordinator = CalendarAgenticCreateCoordinator(
            intakeService: service,
            assetStore: AgenticIntakeAssetStore()
        )
        let pending = PendingEventCreation(
            date: interruptRange.start,
            timeRange: interruptRange,
            source: .dragCreate,
            anchorVisibleDate: date(2026, 3, 2, 0, 0)
        )
        let context = AgenticCalendarContext(
            visibleDate: pending.anchorVisibleDate,
            nearbyEventsSummary: ""
        )

        let placeholder = coordinator.submitOptimisticCreate(
            rawText: "Call vendor\ntype use Urgent",
            selectedImages: [],
            pendingCreate: pending,
            calendarContext: context,
            availableTypes: ["Work", "Study"],
            uiWarnings: [],
            store: store
        )
        XCTAssertTrue(
            store.attachInterrupt(
                to: placeholder.id,
                parentEvent: parent,
                occurrenceDate: parentRange.start,
                createdAt: interruptRange.start,
                seedTypeTitle: "Urgent"
            )
        )

        let attached = try XCTUnwrap(store.findCalendarEvent(id: placeholder.id))
        XCTAssertEqual(attached.displayKind, .interrupt)
        XCTAssertEqual(attached.interruptRelation?.state, .embedded)
        XCTAssertEqual(attached.type, "Urgent")

        try await waitUntil {
            self.store.findCalendarEvent(id: placeholder.id)?.agenticIntake?.processingPhase == .completed
        }

        let updated = try XCTUnwrap(store.findCalendarEvent(id: placeholder.id))
        XCTAssertEqual(updated.displayKind, .interrupt)
        XCTAssertEqual(updated.interruptRelation?.state, .embedded)
        // The optimistic placeholder title ("Call vendor") is preserved
        // after autofill completes — the user-provided title takes
        // precedence over the LLM-suggested one.
        XCTAssertEqual(updated.title, "Call vendor")
        XCTAssertEqual(updated.type, "Urgent")

        let occurrence = CalendarEventOccurrenceContext(
            eventID: parent.id,
            occurrenceDate: parentRange.start,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineLongPress
        )
        let interruptRefs = store.logRecord(for: occurrence)?
            .timelineItems
            .compactMap { $0.interruptReferenceValue } ?? []
        XCTAssertEqual(interruptRefs.map(\.childEventID), [placeholder.id])
    }

    private func makePendingQuickAdd() -> PendingEventCreation {
        let range = Event.TimeRange(
            start: date(2026, 3, 1, 9, 0),
            end: date(2026, 3, 1, 10, 0)
        )
        return PendingEventCreation(
            date: range.start,
            timeRange: range,
            source: .quickAdd,
            anchorVisibleDate: date(2026, 3, 1, 0, 0)
        )
    }

    private func sampleResult(title: String, type: String, range: Event.TimeRange) -> AgenticCalendarAutofillResult {
        AgenticCalendarAutofillResult(
            title: title,
            typeTitle: type,
            note: "AI note",
            location: "Desk",
            startTime: range.start,
            endTime: range.end,
            isAllDay: false,
            repeatUnit: .none,
            repeatInterval: 1,
            repeatEndType: .none,
            repeatEndDate: nil,
            repeatEndCount: nil,
            confidence: 0.9,
            warnings: [],
            usedVision: false,
            providerName: "openai",
            providerModel: "gpt-4o"
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition")
                return
            }
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }
}

private final class StubAutofillService: AgenticCalendarAutofillGenerating {
    enum Mode {
        case success(AgenticCalendarAutofillResult)
        case failure(Error)
    }

    let mode: Mode
    let delayNanoseconds: UInt64

    init(mode: Mode, delayNanoseconds: UInt64) {
        self.mode = mode
        self.delayNanoseconds = delayNanoseconds
    }

    func generateAutofill(
        rawText: String,
        selectedImages: [AgenticInputImage],
        pendingCreate: PendingEventCreation,
        calendarContext: AgenticCalendarContext,
        availableTypes: [String]
    ) async throws -> AgenticCalendarAutofillResult {
        _ = rawText
        _ = selectedImages
        _ = pendingCreate
        _ = calendarContext
        _ = availableTypes
        try await Task.sleep(nanoseconds: delayNanoseconds)
        switch mode {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
final class CalendarEventLogStoreTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var store: EventStore!
    private let calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "CalendarEventLogStoreTests-\(UUID().uuidString)"
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

    func testPrefilledDraftFallsBackToLegacyFeedback() {
        let event = makeEvent(
            title: "Focus Block",
            type: "Work",
            start: date(2026, 3, 1, 9, 0),
            end: date(2026, 3, 1, 10, 0),
            suggestedTemplateID: .deepWork
        )
        store.addCalendarEvent(event)

        let occurrence = makeOccurrence(eventID: event.id, date: event.primaryTimeRange?.start ?? date(2026, 3, 1, 9, 0))
        store.upsertFeedbackRecord(for: occurrence) { record in
            record.effort = 4
            record.emotions = [CalendarEmotionTag.focused.rawValue]
            record.behaviors = [CalendarBehaviorTag.deepWork.rawValue]
            record.selfNote = "Shipped the parser"
            record.logs = [CalendarEventLogEntry(text: "Started 10 min late", source: "legacy")]
        }

        let draft = store.prefilledDraft(for: occurrence)

        XCTAssertEqual(draft.suggestedTemplateID, .deepWork)
        XCTAssertEqual(draft.actualDurationMinutes, 60)
        XCTAssertEqual(draft.note, "Shipped the parser")
        XCTAssertEqual(draft.effort, 4)
        XCTAssertEqual(draft.emotions, [CalendarEmotionTag.focused.rawValue])
        XCTAssertEqual(draft.behaviors, [CalendarBehaviorTag.deepWork.rawValue])
        XCTAssertEqual(draft.timelineNotes.map(\.text), ["Started 10 min late"])
    }

    func testStructuredLogPersistsToDefaultsAndSupportsTimelineDeletion() throws {
        let start = date(2026, 3, 2, 7, 0)
        let end = date(2026, 3, 2, 8, 0)
        let event = makeEvent(
            title: "Morning Run",
            type: "Exercise",
            start: start,
            end: end,
            suggestedTemplateID: .workout
        )
        store.addCalendarEvent(event)

        let occurrence = makeOccurrence(eventID: event.id, date: start)
        store.upsertLogRecord(for: occurrence) { record in
            record.selectedTemplateID = EventLogTemplateID.workout.rawValue
            record.completionStatus = .completed
            record.actualDurationMinutes = 55
            record.summary = "Easy recovery run"
            record.note = "Kept the pace relaxed"
            record.effort = 3
            record.templateAnswers = [
                "activityKind": .string("run"),
                "intensity": .int(3)
            ]
        }
        store.appendTimelineNote("Cooldown walk", source: "test", for: occurrence)
        store.upsertLogRecord(for: occurrence) { record in
            record.timelineItems.append(
                .interruptRef(
                    EventLogInterruptReference(
                        childEventID: UUID(),
                        createdAt: date(2026, 3, 2, 7, 20)
                    )
                )
            )
            record.timelineItems.sort { $0.createdAt > $1.createdAt }
        }

        let persistedData = try XCTUnwrap(defaults.data(forKey: "calendarEventLogRecords"))
        let persistedRecords = try JSONDecoder().decode([CalendarEventLogRecord].self, from: persistedData)
        let persisted = try XCTUnwrap(persistedRecords.first)

        XCTAssertEqual(persisted.selectedTemplateID, EventLogTemplateID.workout.rawValue)
        XCTAssertEqual(persisted.completionStatus, .completed)
        XCTAssertEqual(persisted.actualDurationMinutes, 55)
        XCTAssertEqual(persisted.summary, "Easy recovery run")
        XCTAssertEqual(persisted.templateAnswers["activityKind"], .string("run"))
        XCTAssertEqual(persisted.timelineNotes.count, 1)

        let noteID = try XCTUnwrap(store.logRecord(for: occurrence)?.timelineNotes.first?.id)
        store.deleteTimelineNote(noteID, for: occurrence)

        XCTAssertEqual(store.logRecord(for: occurrence)?.timelineNotes.count, 0)
        XCTAssertEqual(store.logRecord(for: occurrence)?.timelineItems.compactMap { $0.interruptReferenceValue }.count, 1)
    }

    func testUpdateTimelineNotePreservesMetadataAndLeavesInterruptItemsUntouched() throws {
        let start = date(2026, 3, 5, 9, 0)
        let end = date(2026, 3, 5, 10, 0)
        let event = makeEvent(
            title: "Deep Work",
            type: "Work",
            start: start,
            end: end,
            suggestedTemplateID: .deepWork
        )
        store.addCalendarEvent(event)

        let occurrence = makeOccurrence(eventID: event.id, date: start)
        let note = EventLogTimelineNote(
            id: UUID(),
            text: "Outline parser work",
            createdAt: date(2026, 3, 5, 9, 12),
            source: "detailTimeline"
        )
        let interrupt = EventLogInterruptReference(
            id: UUID(),
            childEventID: UUID(),
            createdAt: date(2026, 3, 5, 9, 18)
        )

        store.upsertLogRecord(for: occurrence) { record in
            record.timelineItems = [
                .note(note),
                .interruptRef(interrupt)
            ]
            record.timelineItems.sort { $0.createdAt > $1.createdAt }
        }

        let originalUpdatedAt = try XCTUnwrap(store.logRecord(for: occurrence)?.updatedAt)
        store.updateTimelineNote(note.id, text: "Outline parser and ship review", for: occurrence)

        let updatedRecord = try XCTUnwrap(store.logRecord(for: occurrence))
        let updatedNote = try XCTUnwrap(updatedRecord.timelineItems.compactMap(\.noteValue).first)
        let interruptRefs = updatedRecord.timelineItems.compactMap { $0.interruptReferenceValue }

        XCTAssertEqual(updatedNote.id, note.id)
        XCTAssertEqual(updatedNote.text, "Outline parser and ship review")
        XCTAssertEqual(updatedNote.createdAt, note.createdAt)
        XCTAssertEqual(updatedNote.source, note.source)
        XCTAssertEqual(interruptRefs.count, 1)
        XCTAssertEqual(interruptRefs.first?.id, interrupt.id)
        XCTAssertGreaterThan(updatedRecord.updatedAt, originalUpdatedAt)
    }

    func testRecurringOccurrenceLogsAreScopedByDayAndPrunedForFollowingDeletes() {
        let seriesStart = date(2026, 3, 1, 7, 0)
        let seriesEnd = date(2026, 3, 1, 8, 0)
        let series = Event(
            title: "Daily Run",
            timeRanges: [Event.TimeRange(start: seriesStart, end: seriesEnd)],
            repeatUnit: .day,
            repeatInterval: 1,
            type: "Exercise",
            suggestedLogTemplateID: EventLogTemplateID.workout.rawValue
        )
        store.addCalendarEvent(series)

        let march2 = date(2026, 3, 2, 7, 0)
        let march4 = date(2026, 3, 4, 7, 0)
        let firstOccurrence = makeOccurrence(eventID: series.id, date: march2)
        let secondOccurrence = makeOccurrence(eventID: series.id, date: march4)

        store.appendTimelineNote("Easy miles", source: "test", for: firstOccurrence)
        store.appendTimelineNote("Intervals", source: "test", for: secondOccurrence)

        XCTAssertNotEqual(store.logRecord(for: firstOccurrence)?.id, store.logRecord(for: secondOccurrence)?.id)

        store.deleteRecurringCalendarEvent(
            seriesEvent: series,
            occurrenceDate: date(2026, 3, 3, 7, 0),
            scope: .following
        )

        XCTAssertNotNil(store.logRecord(for: firstOccurrence))
        XCTAssertNil(store.logRecord(for: secondOccurrence))
    }

    private func makeEvent(
        title: String,
        type: String,
        start: Date,
        end: Date,
        suggestedTemplateID: EventLogTemplateID
    ) -> Event {
        Event(
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: type,
            suggestedLogTemplateID: suggestedTemplateID.rawValue
        )
    }

    private func makeOccurrence(eventID: UUID, date: Date) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: date,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }
}
