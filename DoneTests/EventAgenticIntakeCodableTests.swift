import XCTest
@testable import Done

final class EventAgenticIntakeCodableTests: XCTestCase {
    func testDecodesLegacyEventWithoutLocationOrAgenticIntake() throws {
        let original = Event(title: "Legacy", note: "note")
        let encoded = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "location")
        json.removeValue(forKey: "agenticIntake")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Event.self, from: legacyData)
        XCTAssertEqual(decoded.title, "Legacy")
        XCTAssertEqual(decoded.note, "note")
        XCTAssertEqual(decoded.location, "")
        XCTAssertNil(decoded.agenticIntake)
    }

    func testRoundTripPersistsLocationAndAgenticIntake() throws {
        let intake = AgenticIntakeRecord(
            rawText: "开会讨论路线图",
            images: [AgenticIntakeImageRef(relativePath: "abc/img.jpg", pixelWidth: 100, pixelHeight: 80, fileSizeBytes: 2048)],
            source: .quickAdd,
            providerMetadata: AgenticProviderMetadata(provider: "openai", model: "gpt-4o", usedVision: true),
            warnings: ["vision ok"],
            processingPhase: .failed,
            failureMessage: "Network timeout"
        )
        let event = Event(
            title: "Roadmap Sync",
            note: "AI generated",
            location: "Meeting Room A",
            timeRanges: [Event.TimeRange(start: Date(), end: Date().addingTimeInterval(3600))],
            agenticIntake: intake
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)

        XCTAssertEqual(decoded.location, "Meeting Room A")
        XCTAssertEqual(decoded.agenticIntake?.rawText, "开会讨论路线图")
        XCTAssertEqual(decoded.agenticIntake?.images.count, 1)
        XCTAssertEqual(decoded.agenticIntake?.providerMetadata?.provider, "openai")
        XCTAssertEqual(decoded.agenticIntake?.providerMetadata?.usedVision, true)
        XCTAssertEqual(decoded.agenticIntake?.processingPhase, .failed)
        XCTAssertEqual(decoded.agenticIntake?.failureMessage, "Network timeout")
    }

    func testLegacyAgenticIntakeDefaultsProcessingPhaseToCompleted() throws {
        let intake = AgenticIntakeRecord(
            rawText: "legacy intake",
            source: .quickAdd
        )
        let event = Event(
            title: "Legacy Intake Event",
            timeRanges: [Event.TimeRange(start: Date(), end: Date().addingTimeInterval(1800))],
            agenticIntake: intake
        )

        let encoded = try JSONEncoder().encode(event)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var intakeJSON = try XCTUnwrap(json["agenticIntake"] as? [String: Any])
        intakeJSON.removeValue(forKey: "processingPhase")
        intakeJSON.removeValue(forKey: "processingUpdatedAt")
        intakeJSON.removeValue(forKey: "failureMessage")
        json["agenticIntake"] = intakeJSON
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Event.self, from: legacyData)
        XCTAssertEqual(decoded.agenticIntake?.processingPhase, .completed)
        XCTAssertNil(decoded.agenticIntake?.failureMessage)
    }

    func testRoundTripPersistsSuggestedLogTemplateMetadata() throws {
        let updatedAt = Date(timeIntervalSince1970: 123_456)
        let event = Event(
            title: "Run",
            note: "Track intervals",
            suggestedLogTemplateID: EventLogTemplateID.workout.rawValue,
            suggestedLogTemplateConfidence: 0.81,
            suggestedLogTemplateUpdatedAt: updatedAt,
            suggestedLogTemplateSource: .agent
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)

        XCTAssertEqual(decoded.suggestedLogTemplateID, EventLogTemplateID.workout.rawValue)
        XCTAssertEqual(try XCTUnwrap(decoded.suggestedLogTemplateConfidence), 0.81, accuracy: 0.0001)
        XCTAssertEqual(decoded.suggestedLogTemplateUpdatedAt, updatedAt)
        XCTAssertEqual(decoded.suggestedLogTemplateSource, .agent)
    }
}

final class SkillAnalysisServiceTests: XCTestCase {
    func testSkipsAgenticAnalyzingEvent() {
        XCTAssertTrue(skillAnalysisShouldSkipForAgenticProcessing(makeEvent(processingPhase: .analyzing)))
    }

    func testSkipsAgenticFailedEvent() {
        XCTAssertTrue(skillAnalysisShouldSkipForAgenticProcessing(makeEvent(processingPhase: .failed)))
    }

    func testCompletedAgenticEventDoesNotSkip() {
        XCTAssertFalse(skillAnalysisShouldSkipForAgenticProcessing(makeEvent(processingPhase: .completed)))
    }

    func testNonAgenticEventDoesNotSkip() {
        let now = Date()
        let event = Event(
            title: "Normal Event",
            timeRanges: [Event.TimeRange(start: now.addingTimeInterval(-1800), end: now)],
            type: "Work"
        )
        XCTAssertFalse(skillAnalysisShouldSkipForAgenticProcessing(event))
    }

    private func makeEvent(processingPhase: AgenticIntakeProcessingPhase) -> Event {
        let now = Date()
        let intake = AgenticIntakeRecord(
            rawText: "placeholder",
            source: .quickAdd,
            processingPhase: processingPhase,
            failureMessage: processingPhase == .failed ? "no key" : nil
        )
        return Event(
            title: "Test Event",
            note: "",
            timeRanges: [Event.TimeRange(start: now.addingTimeInterval(-1800), end: now)],
            type: "Work",
            agenticIntake: intake
        )
    }
}

@MainActor
final class AgentDecisionCenterTests: XCTestCase {
    private var preferenceStore: AgentPreferenceStore!
    private var decisionCenter: AgentDecisionCenter!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        preferenceStore = AgentPreferenceStore(directoryURL: tempDir)
        decisionCenter = AgentDecisionCenter(preferenceStore: preferenceStore)
    }

    override func tearDown() {
        decisionCenter = nil
        preferenceStore = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testSerializesDecisionQueue() async throws {
        let request1 = makeRequest(id: UUID(), candidateType: "Reading")
        let request2 = makeRequest(id: UUID(), candidateType: "Deep Work")

        let task1 = Task { await self.decisionCenter.submit(request1) }
        let task2 = Task { await self.decisionCenter.submit(request2) }

        try await waitUntil { self.decisionCenter.currentDecision?.id == request1.id }
        XCTAssertEqual(decisionCenter.pendingCount, 1)

        decisionCenter.resolveCurrent(with: .selected(optionID: AgentOperationCenter.OptionID.createTemplate))
        let result1 = await task1.value
        XCTAssertFalse(result1.wasDefaulted)

        try await waitUntil { self.decisionCenter.currentDecision?.id == request2.id }
        decisionCenter.dismissCurrent()
        let result2 = await task2.value
        XCTAssertTrue(result2.wasDefaulted)
        if case .applyOption(let optionID) = result2.effectiveOutcome {
            XCTAssertEqual(optionID, AgentOperationCenter.OptionID.keepTypeOnly)
        } else {
            XCTFail("Expected default keep_type_only outcome")
        }
    }

    func testTimeoutUsesDefaultPolicy() async {
        let request = AgentDecisionRequest(
            kind: .missingEventTypeTemplate,
            title: "Create template?",
            message: "Missing template",
            options: [
                AgentDecisionOption(id: AgentOperationCenter.OptionID.createTemplate, title: "Create", isRecommended: true),
                AgentDecisionOption(id: AgentOperationCenter.OptionID.keepTypeOnly, title: "Keep", isRecommended: false)
            ],
            recommendedOptionID: AgentOperationCenter.OptionID.createTemplate,
            otherwiseEnabled: true,
            defaultPolicy: .applyOption(AgentOperationCenter.OptionID.keepTypeOnly),
            timeout: 0.05,
            context: AgentDecisionContext(domain: .calendar, operationID: UUID(), sourceScreen: "Test", payloadSummary: "Timeout")
        )

        let resolution = await decisionCenter.submit(request)

        XCTAssertTrue(resolution.wasDefaulted)
        if case .applyOption(let optionID) = resolution.effectiveOutcome {
            XCTAssertEqual(optionID, AgentOperationCenter.OptionID.keepTypeOnly)
        } else {
            XCTFail("Expected default keep_type_only")
        }
    }

    private func makeRequest(id: UUID, candidateType: String) -> AgentDecisionRequest {
        AgentDecisionRequest(
            id: id,
            kind: .missingEventTypeTemplate,
            title: "Create template?",
            message: "Missing event type template",
            options: [
                AgentDecisionOption(id: AgentOperationCenter.OptionID.createTemplate, title: "Create", isRecommended: true),
                AgentDecisionOption(id: AgentOperationCenter.OptionID.keepTypeOnly, title: "Keep", isRecommended: false)
            ],
            recommendedOptionID: AgentOperationCenter.OptionID.createTemplate,
            otherwiseEnabled: true,
            defaultPolicy: .applyOption(AgentOperationCenter.OptionID.keepTypeOnly),
            timeout: 5,
            context: AgentDecisionContext(
                domain: .calendar,
                operationID: UUID(),
                sourceScreen: "Test",
                payloadSummary: "Queue test",
                metadata: ["candidateType": candidateType]
            )
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition")
                return
            }
        }
    }
}

@MainActor
final class AgentPreferenceStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: AgentPreferenceStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = AgentPreferenceStore(directoryURL: tempDir)
    }

    override func tearDown() {
        store = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testRecordsExplicitSelectionsAndPersistsRules() throws {
        let record = AgentDecisionRecord(
            requestSnapshot: makeDecisionRequest(candidateType: "Reading"),
            resultKind: .selected,
            selectedOptionID: AgentOperationCenter.OptionID.createTemplate,
            appliedActionSummary: "Created template",
            wasDefaulted: false
        )
        store.recordDecision(record)
        store.recordDecision(record)

        XCTAssertEqual(store.decisionHistory.count, 2)
        XCTAssertEqual(store.listRules().count, 1)
        XCTAssertTrue(store.prefersCreateTemplateRecommendation(for: EventTypeTemplateStore.normalizedTitle("Reading")))

        let decisionsURL = tempDir.appendingPathComponent("decision_records.json")
        let rulesURL = tempDir.appendingPathComponent("preference_rules.json")
        let decisionsData = try Data(contentsOf: decisionsURL)
        let rulesData = try Data(contentsOf: rulesURL)
        let decodedDecisions = try JSONDecoder().decode([AgentDecisionRecord].self, from: decisionsData)
        let decodedRules = try JSONDecoder().decode([AgentPreferenceRule].self, from: rulesData)
        XCTAssertEqual(decodedDecisions.count, 2)
        XCTAssertEqual(decodedRules.count, 1)
    }

    func testDefaultedDecisionDoesNotCreateLearnedRule() {
        let record = AgentDecisionRecord(
            requestSnapshot: makeDecisionRequest(candidateType: "Reading"),
            resultKind: .dismissed,
            appliedActionSummary: "Default keep",
            wasDefaulted: true
        )
        store.recordDecision(record)

        XCTAssertEqual(store.decisionHistory.count, 1)
        XCTAssertTrue(store.listRules().isEmpty)
    }

    func testOtherwiseDecisionCreatesCustomRuleAndClearWorks() {
        let record = AgentDecisionRecord(
            requestSnapshot: makeDecisionRequest(candidateType: "Reading"),
            resultKind: .otherwise,
            otherwiseText: "Use Study, don't create a new template",
            appliedActionSummary: "Otherwise",
            wasDefaulted: false
        )
        store.recordDecision(record)

        XCTAssertEqual(store.listRules().count, 1)
        XCTAssertEqual(store.listRules().first?.preferredAction.kind, .customInstruction)

        store.clearRules()
        XCTAssertTrue(store.listRules().isEmpty)

        store.clearDecisionHistory()
        XCTAssertTrue(store.decisionHistory.isEmpty)
    }

    private func makeDecisionRequest(candidateType: String) -> AgentDecisionRequest {
        AgentDecisionRequest(
            kind: .missingEventTypeTemplate,
            title: "Create template?",
            message: "Missing template",
            options: [],
            recommendedOptionID: nil,
            otherwiseEnabled: true,
            defaultPolicy: .noOpContinue,
            timeout: nil,
            context: AgentDecisionContext(
                domain: .calendar,
                operationID: UUID(),
                sourceScreen: "Test",
                payloadSummary: "Preference test",
                metadata: ["candidateType": candidateType]
            )
        )
    }
}

@MainActor
final class AgentEventClassificationAdvisorTests: XCTestCase {
    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var templateStore: EventTypeTemplateStore!
    private var preferenceStore: AgentPreferenceStore!
    private var tempDir: URL!
    private let advisor = AgentEventClassificationAdvisor()

    override func setUp() {
        super.setUp()
        defaultsSuite = "AgentEventClassificationAdvisorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        defaults.removePersistentDomain(forName: defaultsSuite)
        templateStore = EventTypeTemplateStore(defaults: defaults)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        preferenceStore = AgentPreferenceStore(directoryURL: tempDir)
    }

    override func tearDown() {
        if let defaultsSuite {
            TestStorage.tearDown(defaultsSuite)
        }
        defaultsSuite = nil
        defaults = nil
        templateStore = nil
        preferenceStore = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testPromptsForMissingValidType() {
        let evaluation = advisor.evaluate(
            candidateTypeTitle: "Reading",
            templateStore: templateStore,
            preferenceStore: preferenceStore
        )
        guard case .prompt = evaluation else {
            return XCTFail("Expected prompt")
        }
    }

    func testSkipsWhenTemplateAlreadyExists() {
        _ = templateStore.ensureTemplate(title: "Reading")
        let evaluation = advisor.evaluate(
            candidateTypeTitle: "Reading",
            templateStore: templateStore,
            preferenceStore: preferenceStore
        )
        XCTAssertEqual(evaluation, .skip(reason: "template exists"))
    }

    func testSkipsNoisyType() {
        let evaluation = advisor.evaluate(
            candidateTypeTitle: "https://example.com/a-very-long-url",
            templateStore: templateStore,
            preferenceStore: preferenceStore
        )
        guard case .skip = evaluation else {
            return XCTFail("Expected skip")
        }
    }
}

@MainActor
final class AgentOperationCenterTests: XCTestCase {
    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var eventStore: EventStore!
    private var templateStore: EventTypeTemplateStore!
    private var preferenceStore: AgentPreferenceStore!
    private var decisionCenter: AgentDecisionCenter!
    private var operationCenter: AgentOperationCenter!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        defaultsSuite = "AgentOperationCenterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        TestStorage.reset(defaultsSuite)
        eventStore = EventStore(defaults: defaults,
                                storage: .isolated(name: defaultsSuite),
                                seedsSampleDataIfEmpty: false)
        templateStore = EventTypeTemplateStore(defaults: defaults)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        preferenceStore = AgentPreferenceStore(directoryURL: tempDir)
        decisionCenter = AgentDecisionCenter(preferenceStore: preferenceStore)
        operationCenter = AgentOperationCenter(
            decisionCenter: decisionCenter,
            preferenceStore: preferenceStore,
            templateStore: templateStore,
            askBeforeCreatingTypeTemplate: { true }
        )
    }

    override func tearDown() {
        if let defaultsSuite {
            TestStorage.tearDown(defaultsSuite)
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        operationCenter = nil
        decisionCenter = nil
        preferenceStore = nil
        eventStore = nil
        templateStore = nil
        defaults = nil
        defaultsSuite = nil
        tempDir = nil
        super.tearDown()
    }

    func testCreateTemplateOptionAddsTemplate() async throws {
        let event = makeCalendarEvent(type: "Reading")
        eventStore.addCalendarEvent(event)

        let task = Task {
            await self.operationCenter.maybeHandleMissingEventTypeTemplate(
                for: event.id,
                isCalendarEvent: true,
                proposedType: "Reading",
                store: self.eventStore,
                context: self.makeContext(eventID: event.id, candidateType: "Reading")
            )
        }

        try await waitUntil { self.decisionCenter.currentDecision != nil }
        decisionCenter.resolveCurrent(with: .selected(optionID: AgentOperationCenter.OptionID.createTemplate))
        let outcome = await task.value

        XCTAssertEqual(outcome, .createdTemplate(title: "Reading"))
        XCTAssertTrue(templateStore.contains(title: "Reading"))
    }

    func testDismissDefaultsToNoTemplate() async throws {
        let event = makeCalendarEvent(type: "Reading")
        eventStore.addCalendarEvent(event)

        let task = Task {
            await self.operationCenter.maybeHandleMissingEventTypeTemplate(
                for: event.id,
                isCalendarEvent: true,
                proposedType: "Reading",
                store: self.eventStore,
                context: self.makeContext(eventID: event.id, candidateType: "Reading")
            )
        }

        try await waitUntil { self.decisionCenter.currentDecision != nil }
        decisionCenter.dismissCurrent()
        let outcome = await task.value

        XCTAssertEqual(outcome, .defaultedNoTemplate)
        XCTAssertFalse(templateStore.contains(title: "Reading"))
    }

    func testOtherwiseCanMapToExistingTemplateAndUpdateEventType() async throws {
        _ = templateStore.ensureTemplate(title: "Study")
        let event = makeCalendarEvent(type: "Reading")
        eventStore.addCalendarEvent(event)

        let task = Task {
            await self.operationCenter.maybeHandleMissingEventTypeTemplate(
                for: event.id,
                isCalendarEvent: true,
                proposedType: "Reading",
                store: self.eventStore,
                context: self.makeContext(eventID: event.id, candidateType: "Reading")
            )
        }

        try await waitUntil { self.decisionCenter.currentDecision != nil }
        decisionCenter.resolveCurrent(with: .otherwise(text: "Use Study, don't create a new template"))
        let outcome = await task.value

        XCTAssertEqual(outcome, .updatedEventType(to: "Study"))
        XCTAssertEqual(eventStore.rawCalendarEvents.first?.type, "Study")
        XCTAssertFalse(templateStore.contains(title: "Reading"))
    }

    private func makeCalendarEvent(type: String) -> Event {
        let start = Date()
        let end = start.addingTimeInterval(3600)
        return Event(
            title: "Test",
            note: "",
            location: "",
            timeRanges: [Event.TimeRange(start: start, end: end)],
            repeatUnit: .none,
            isAllDay: false,
            repeatInterval: 1,
            repeatEndType: .none,
            type: type
        )
    }

    private func makeContext(eventID: UUID, candidateType: String) -> AgentDecisionContext {
        AgentDecisionContext(
            domain: .calendar,
            operationID: UUID(),
            sourceScreen: "Test",
            relatedEventIDs: [eventID],
            payloadSummary: "Test classification",
            metadata: ["candidateType": candidateType]
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition")
                return
            }
        }
    }
}
