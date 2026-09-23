//
//  SkillAnalysisCapsTests.swift
//  DoneTests
//
//  gh#219: cost caps and failure semantics for the launch-time skill
//  analysis sweep. Every test constructs its own SkillInsightStore on a
//  unique UserDefaults suite and injects a mock provider through the
//  service's providerFactory seam — nothing here touches the resident app's
//  stores or the real provider config.
//

import XCTest
@testable import Done

/// LLMProvider mock. `closeGate()` makes sends suspend until `openGate()`,
/// so tests can hold a sweep mid-send deterministically (no timing sleeps).
private final class GatedMockProvider: LLMProvider, @unchecked Sendable {
    enum Mode { case succeed, fail }

    private let lock = NSLock()
    private var _sendCount = 0
    private var _mode: Mode
    private var gateOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(mode: Mode) { _mode = mode }

    var sendCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _sendCount
    }

    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }

    func closeGate() {
        lock.lock(); gateOpen = false; lock.unlock()
    }

    func openGate() {
        lock.lock()
        gateOpen = true
        let resumed = waiters
        waiters = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        lock.lock()
        _sendCount += 1
        let open = gateOpen
        lock.unlock()
        if !open {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if gateOpen {
                    lock.unlock()
                    c.resume()
                } else {
                    waiters.append(c)
                    lock.unlock()
                }
            }
        }
        switch mode {
        case .succeed:
            return LLMResponse(
                content: #"[{"skill": "Testing", "points": 0.5, "reasoning": "Mock reasoning."}]"#,
                toolCalls: []
            )
        case .fail:
            throw LLMError.invalidResponse
        }
    }
}

/// Counts `set(_:forKey:)` calls per key so tests can assert how many times
/// the analyzed-id set was actually persisted.
private final class WriteCountingDefaults: UserDefaults {
    private let countLock = NSLock()
    private var setCounts: [String: Int] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        countLock.lock()
        setCounts[defaultName, default: 0] += 1
        countLock.unlock()
        super.set(value, forKey: defaultName)
    }

    func writes(forKey key: String) -> Int {
        countLock.lock(); defer { countLock.unlock() }
        return setCounts[key] ?? 0
    }
}

@MainActor
final class SkillAnalysisCapsTests: XCTestCase {
    private static let analyzedKey = "skillAnalyzedEventIds"

    private var suiteName: String!
    private var defaults: WriteCountingDefaults!
    private var store: SkillInsightStore!

    override func setUp() {
        super.setUp()
        suiteName = "SkillAnalysisCapsTests-\(UUID().uuidString)"
        defaults = WriteCountingDefaults(suiteName: suiteName)
        store = SkillInsightStore(defaults: defaults)
    }

    override func tearDown() {
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeService(provider: GatedMockProvider) -> SkillAnalysisService {
        SkillAnalysisService(insightStore: store, providerFactory: { provider })
    }

    /// An event that passes every sweep eligibility check: ≥ 15 min long and
    /// already ended (started 60 min ago, ran 30 min).
    private func makePastEvent(title: String = "Practice") -> Event {
        let start = Date().addingTimeInterval(-3600)
        return Event(
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(1800))],
            type: "Work"
        )
    }

    private struct TimedOut: Error {}

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TimedOut() }
            await Task.yield()
        }
    }

    // MARK: - Failure semantics

    func testFailedSendDoesNotMarkAnalyzedAndIsRetriedByNextSweep() async {
        let provider = GatedMockProvider(mode: .fail)
        let service = makeService(provider: provider)
        let event = makePastEvent()

        await service.analyzePastEvents([event])

        XCTAssertEqual(provider.sendCount, 1)
        XCTAssertFalse(
            store.isAnalyzed(event.id),
            "a thrown provider.send must NOT mark the event analyzed"
        )
        XCTAssertTrue(store.insights.isEmpty)
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 0,
            "an all-failure sweep has nothing to persist"
        )

        // A later launch's sweep retries the same event and succeeds.
        provider.mode = .succeed
        await service.analyzePastEvents([event])

        XCTAssertEqual(provider.sendCount, 2, "the failed event must be retried by a later sweep")
        XCTAssertTrue(store.isAnalyzed(event.id))
        XCTAssertEqual(store.insights.count, 1)
    }

    // MARK: - Per-launch cap

    func testSweepCapsProviderCallsAtCapAndRemainderDrainsNextSweep() async {
        XCTAssertEqual(SkillAnalysisService.perLaunchAnalysisCap, 10)

        let provider = GatedMockProvider(mode: .succeed)
        let service = makeService(provider: provider)
        let events = (0..<11).map { makePastEvent(title: "E\($0)") }

        await service.analyzePastEvents(events)

        XCTAssertEqual(provider.sendCount, 10, "cap: at most 10 provider calls per sweep")
        XCTAssertEqual(events.filter { store.isAnalyzed($0.id) }.count, 10)
        XCTAssertFalse(store.isAnalyzed(events[10].id), "the 11th event waits for a future launch")

        // Next launch: the remainder drains, already-analyzed events cost nothing.
        await service.analyzePastEvents(events)

        XCTAssertEqual(provider.sendCount, 11)
        XCTAssertTrue(store.isAnalyzed(events[10].id))
    }

    // MARK: - Re-entry guard

    func testConcurrentSweepCallIsNoOpWhileFirstSweepRuns() async throws {
        let provider = GatedMockProvider(mode: .succeed)
        provider.closeGate()
        let service = makeService(provider: provider)
        let events = (0..<11).map { makePastEvent(title: "E\($0)") }

        let first = Task { await service.analyzePastEvents(events) }
        try await waitUntil { provider.sendCount >= 1 }

        // First sweep is suspended inside its first provider send. A second
        // call now must return immediately without spending anything.
        let second = Task { await service.analyzePastEvents(events) }
        for _ in 0..<25 { await Task.yield() }

        provider.openGate()
        await first.value
        await second.value

        XCTAssertEqual(
            provider.sendCount, 10,
            "two concurrent sweep calls must spend at most one sweep's cap"
        )
    }

    // MARK: - Coalesced persistence

    func testSweepPersistsAnalyzedIdSetOncePerBatchNotPerEvent() async {
        let provider = GatedMockProvider(mode: .succeed)
        let service = makeService(provider: provider)
        let events = (0..<5).map { makePastEvent(title: "E\($0)") }

        await service.analyzePastEvents(events)

        XCTAssertEqual(provider.sendCount, 5)
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 1,
            "one persisted analyzed-id write per sweep, not one per event"
        )
        // The single write carried all five marks to the suite.
        let persisted = defaults.array(forKey: Self.analyzedKey) as? [String] ?? []
        XCTAssertEqual(Set(persisted), Set(events.map(\.id.uuidString)))
    }

    func testSingleEventPathStillPersistsImmediately() async {
        let provider = GatedMockProvider(mode: .succeed)
        let service = makeService(provider: provider)
        let event = makePastEvent()

        await service.analyzeEvent(event)

        XCTAssertEqual(provider.sendCount, 1)
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 1,
            "the record-completed path (one event per user action) persists its mark immediately"
        )
        let persisted = defaults.array(forKey: Self.analyzedKey) as? [String] ?? []
        XCTAssertEqual(persisted, [event.id.uuidString])
    }

    // MARK: - Cancellation

    func testCancellationStopsSweepBetweenEventsAndFlushesEarnedMarks() async throws {
        let provider = GatedMockProvider(mode: .succeed)
        provider.closeGate()
        let service = makeService(provider: provider)
        let events = (0..<11).map { makePastEvent(title: "E\($0)") }

        let sweep = Task { await service.analyzePastEvents(events) }
        try await waitUntil { provider.sendCount >= 1 }

        sweep.cancel()
        provider.openGate()
        await sweep.value

        // The in-flight send completed (its response was already owed) and
        // earned its mark; the loop observed cancellation before the next
        // event and stopped, flushing what it had.
        XCTAssertEqual(provider.sendCount, 1, "no further provider calls after cancellation")
        XCTAssertTrue(store.isAnalyzed(events[0].id))
        XCTAssertFalse(store.isAnalyzed(events[1].id))
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 1,
            "a cancelled sweep still flushes the marks it earned"
        )
    }
}
