//
//  TokenProjectionBatchSaveTests.swift
//  DoneTests
//
//  A bootstrap over N occurrences saves the projections array once, not
//  once per occurrence (`TokenInferenceRepository.batchingProjectionSaves`),
//  and keeps what `upsertProjection` always meant: each occurrence reads the
//  ones placed before it, a reconciled projection replaces the predicted
//  one for its occurrence, and the array stays ordered by start.
//

import XCTest
@testable import Done

/// Counts writes per key. Scoped to a throwaway suite.
private final class WriteCountingDefaults: UserDefaults {
    var writes: [String: Int] = [:]
    override func set(_ value: Any?, forKey defaultName: String) {
        writes[defaultName, default: 0] += 1
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class TokenProjectionBatchSaveTests: XCTestCase {

    private var suite = ""
    private var defaults: WriteCountingDefaults!
    private var store: EventStore!

    override func setUp() {
        super.setUp()
        suite = "TokenProjectionBatchSaveTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = WriteCountingDefaults(suiteName: suite)!
        store = EventStore(defaults: UserDefaults(suiteName: suite + "-store")!, storage: location,
                           seedsSampleDataIfEmpty: false)
    }

    override func tearDown() {
        TestStorage.tearDown(suite)
        UserDefaults().removePersistentDomain(forName: suite + "-store")
        store = nil
        defaults = nil
        super.tearDown()
    }

    private var projectionSaves: Int { defaults.writes[TokenInferenceRepository.projectionKey] ?? 0 }

    /// A daily series starting within the hour: the prediction horizon holds
    /// one upcoming occurrence per day.
    private func dailySeries() -> Event {
        let start = Date().addingTimeInterval(3600)
        let event = Event(title: "Daily", timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
                          repeatUnit: .day, repeatInterval: 1)
        store.addCalendarEvent(event)
        return event
    }

    private func skipIfTheLLMPathIsOn() throws {
        try XCTSkipIf(UserDefaults.standard.bool(forKey: AppSettingsKeys.tokenInferenceLLMEnabled),
                      "this host has the token LLM on; the bootstrap path is the one under test")
    }

    func testABootstrapOfNOccurrencesSavesTheProjectionsOnce() async throws {
        try skipIfTheLLMPathIsOn()
        let repository = TokenInferenceRepository(defaults: defaults)
        let service = TokenInferenceService(repository: repository)
        let event = dailySeries()
        let batchLines = trailCount("tokens: projections batch upserts=")

        await service.predict(event: event, store: store)

        let placed = repository.snapshot().projections
        XCTAssertGreaterThan(placed.count, 1, "fixture: a loop over more than one occurrence")
        XCTAssertEqual(projectionSaves, 1, "one save for \(placed.count) upserts")
        XCTAssertEqual(TokenInferenceRepository(defaults: defaults).snapshot().projections.map(\.id), placed.map(\.id),
                       "the one save carried every projection")
        XCTAssertEqual(trailCount("tokens: projections batch upserts="), batchLines + 1, "one trail line for the batch")
        XCTAssertTrue(DiagnosticTrail.combinedText().contains("tokens: projections batch upserts=\(placed.count) saves=1 count=\(placed.count) landed=true"))
    }

    private func trailCount(_ needle: String) -> Int {
        DiagnosticTrail.combinedText().components(separatedBy: needle).count - 1
    }

    /// Inside the batch each occurrence still starts from the one before
    /// it (`latestProjection(before:)`), so deferring the save deferred
    /// nothing a later occurrence reads; the array is ordered by start.
    func testABatchedBootstrapStillChainsEachOccurrenceOnThePreviousOne() async throws {
        try skipIfTheLLMPathIsOn()
        let repository = TokenInferenceRepository(defaults: defaults)
        let service = TokenInferenceService(repository: repository)
        let event = dailySeries()

        await service.predict(event: event, store: store)

        let placed = repository.snapshot().projections
        XCTAssertGreaterThan(placed.count, 1, "fixture")
        for (earlier, later) in zip(placed, placed.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.start, later.start, "ordered by start")
            XCTAssertEqual(later.tokenBefore, earlier.tokenAfter, accuracy: 1e-9, "\(later.start) starts where \(earlier.start) ended")
        }
    }

    /// A reconcile in its own batch replaces the predicted projection for
    /// that occurrence and saves once more.
    func testAReconciledProjectionReplacesThePredictedOneForItsOccurrence() async throws {
        try skipIfTheLLMPathIsOn()
        let repository = TokenInferenceRepository(defaults: defaults)
        let service = TokenInferenceService(repository: repository)
        let event = dailySeries()
        await service.predict(event: event, store: store)
        let predicted = repository.snapshot().projections
        let first = try XCTUnwrap(predicted.first)
        let occurrenceDay = Calendar.current.startOfDay(for: first.start)
        XCTAssertEqual(projectionSaves, 1, "fixture")

        await service.reconcile(occurrence: CalendarEventOccurrenceContext(
            eventID: event.id, occurrenceDate: occurrenceDay, occurrenceID: first.occurrenceID,
            isAllDay: false, source: .timelineTap), store: store)

        let after = repository.snapshot().projections
        XCTAssertEqual(after.count, predicted.count, "one replaced, none added")
        XCTAssertEqual(after.filter { $0.occurrenceKey == first.occurrenceKey }.map(\.phase), [.reconciled])
        XCTAssertEqual(projectionSaves, 2)
    }

    /// Positive control for the counter: an upsert outside a batch saves at
    /// once, and a batch with no upsert saves nothing.
    func testALoneUpsertSavesAtOnceAndAnEmptyBatchSavesNothing() async throws {
        try skipIfTheLLMPathIsOn()
        let repository = TokenInferenceRepository(defaults: defaults)
        let service = TokenInferenceService(repository: repository)
        await service.predict(event: dailySeries(), store: store)
        let record = try XCTUnwrap(repository.snapshot().projections.first)
        XCTAssertEqual(projectionSaves, 1, "fixture")

        repository.batchingProjectionSaves {}
        XCTAssertEqual(projectionSaves, 1)
        repository.upsertProjection(record)
        XCTAssertEqual(projectionSaves, 2)
    }
}
