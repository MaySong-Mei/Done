import XCTest
@testable import Done

final class AgenticCalendarAutofillNormalizerTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

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

    func testSubmitOptimisticCreateImmediatelyAddsPlaceholderThenCompletes() async throws {
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

        XCTAssertEqual(store.calendarEvents.count, 1)
        XCTAssertEqual(placeholder.agenticIntake?.processingPhase, .analyzing)
        XCTAssertEqual(store.calendarEvents.first?.agenticIntake?.processingPhase, .analyzing)
        XCTAssertEqual(store.calendarEvents.first?.title, "跟产品开会讨论需求")

        try await waitUntil {
            self.store.calendarEvents.first?.agenticIntake?.processingPhase == .completed
        }

        let updated = try XCTUnwrap(store.calendarEvents.first)
        XCTAssertEqual(updated.title, "AI Final Title")
        XCTAssertEqual(updated.type, "Work")
        XCTAssertEqual(updated.agenticIntake?.processingPhase, .completed)
        XCTAssertNotNil(updated.agenticIntake?.providerMetadata)
        XCTAssertEqual(coordinator.banner, .moved(eventID: updated.id, destination: finalRange.start))
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
            self.store.calendarEvents.first?.agenticIntake?.processingPhase == .failed
        }

        let updated = try XCTUnwrap(store.calendarEvents.first)
        XCTAssertEqual(updated.id, placeholder.id)
        XCTAssertEqual(updated.agenticIntake?.processingPhase, .failed)
        XCTAssertEqual(updated.agenticIntake?.failureMessage, "Mock failure")

        guard case .failed(let eventID, let message)? = coordinator.banner else {
            return XCTFail("Expected failed banner")
        }
        XCTAssertEqual(eventID, placeholder.id)
        XCTAssertEqual(message, "Mock failure")
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
