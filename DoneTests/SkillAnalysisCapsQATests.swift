//
//  SkillAnalysisCapsQATests.swift
//  DoneTests
//
//  Independent adversarial QA for gh#219 (fix/skill-analysis-caps).
//  Attack surfaces: poison-event starvation of the capped sweep, paid-but-
//  unparseable answers, sweep/single-path interleaving at await points,
//  cancellation flush arithmetic, and the coalesced ledger write counts.
//
//  Witness tests (named *Witness*) pin CURRENT behavior that the QA report
//  flags as an undisclosed consequence of the fix — they are expected to
//  pass, and their assertions are the repro for the report finding.
//

import XCTest
@testable import Done

/// LLMProvider mock scripted per request:
/// - a prompt containing `poisonMarker` throws (permanent send failure),
/// - `successContent` (nil allowed) is returned otherwise,
/// - the send whose 1-based sequence number equals `blockAtSendNumber`
///   suspends until `openGate()` — after incrementing the count, so tests
///   can wait deterministically for "Nth send is now in flight".
private final class ScriptedQAProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _sendCount = 0
    private var _sentPrompts: [String] = []
    private var gateOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var poisonMarker: String?
    /// Content of a successful response. `.some(nil)` means "send succeeds,
    /// response has nil content"; default is one valid insight element.
    var successContent: String?? = #"[{"skill": "QA Skill", "points": 0.5, "reasoning": "qa"}]"#
    var blockAtSendNumber: Int?

    var sendCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _sendCount
    }

    var sentPrompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _sentPrompts
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
        let prompt = request.messages.first?.content ?? ""
        lock.lock()
        _sendCount += 1
        let myNumber = _sendCount
        _sentPrompts.append(prompt)
        let mustWait = (blockAtSendNumber == myNumber) && !gateOpen
        lock.unlock()

        if mustWait {
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

        if let marker = poisonMarker, prompt.contains(marker) {
            throw LLMError.invalidResponse
        }
        return LLMResponse(content: successContent ?? nil, toolCalls: [])
    }
}

/// Counts `set(_:forKey:)` per key so ledger-write arithmetic is assertable.
private final class QAWriteCountingDefaults: UserDefaults {
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
final class SkillAnalysisCapsQATests: XCTestCase {
    private static let analyzedKey = "skillAnalyzedEventIds"
    private static let insightsKey = "skillInsights"

    private var suiteName: String!
    private var defaults: QAWriteCountingDefaults!
    private var store: SkillInsightStore!

    override func setUp() {
        super.setUp()
        suiteName = "SkillAnalysisCapsQATests-\(UUID().uuidString)"
        defaults = QAWriteCountingDefaults(suiteName: suiteName)
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

    private func makeService(provider: ScriptedQAProvider) -> SkillAnalysisService {
        SkillAnalysisService(insightStore: store, providerFactory: { provider })
    }

    /// Eligible for the sweep: 30 min long, ended 30 min ago.
    private func makePastEvent(title: String) -> Event {
        let start = Date().addingTimeInterval(-3600)
        return Event(
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(1800))],
            type: "Work"
        )
    }

    /// Ineligible: only 10 minutes long.
    private func makeShortEvent(title: String) -> Event {
        let start = Date().addingTimeInterval(-3600)
        return Event(
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(600))],
            type: "Work"
        )
    }

    /// Ineligible: has not ended yet.
    private func makeFutureEvent(title: String) -> Event {
        let start = Date().addingTimeInterval(3600)
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

    // MARK: - Cap counts attempts, not successes

    func testElevenPermanentSendFailuresStillStopAtTheCap() async {
        let provider = ScriptedQAProvider()
        provider.poisonMarker = "POISON"
        let service = makeService(provider: provider)
        let events = (0..<11).map { makePastEvent(title: "POISON-\($0)") }

        await service.analyzePastEvents(events)

        XCTAssertEqual(
            provider.sendCount, 10,
            "failed sends are still paid attempts and must consume cap slots"
        )
        XCTAssertTrue(events.allSatisfy { !store.isAnalyzed($0.id) })
        XCTAssertEqual(defaults.writes(forKey: Self.analyzedKey), 0)
    }

    // MARK: - Poison-head starvation (report finding: undisclosed livelock)

    func testPoisonHeadStarvesBacklogAcrossThreeLaunchesWitness() async {
        // 10 events whose send fails deterministically every time (e.g. a
        // provider-side 4xx that a given prompt always triggers) sit ahead
        // of 3 healthy events in store order. Because a failed send is never
        // marked analyzed AND consumes a cap slot, every launch replays the
        // same 10 poison sends and the healthy backlog is never reached.
        let provider = ScriptedQAProvider()
        provider.poisonMarker = "POISON"
        let poison = (0..<10).map { makePastEvent(title: "POISON-\($0)") }
        let good = (0..<3).map { makePastEvent(title: "GOOD-\($0)") }
        let events = poison + good

        for launch in 0..<3 {
            // Fresh service per launch, same store — ContentView's shape.
            let service = makeService(provider: provider)
            await service.analyzePastEvents(events)
            XCTAssertEqual(
                provider.sendCount, (launch + 1) * 10,
                "each launch spends the full cap on the same poison head"
            )
        }

        XCTAssertTrue(
            provider.sentPrompts.allSatisfy { $0.contains("POISON") },
            "every one of the 30 paid attempts went to a poison event"
        )
        XCTAssertTrue(
            good.allSatisfy { !store.isAnalyzed($0.id) },
            "healthy events behind the poison head are starved indefinitely"
        )
        XCTAssertTrue(store.insights.isEmpty)
    }

    // MARK: - Paid answer that cannot be parsed

    func testSuccessfulSendWithUnparseableContentIsMarkedAndNeverRetried() async {
        let provider = ScriptedQAProvider()
        provider.successContent = "Sorry, I cannot produce JSON for that."
        let service = makeService(provider: provider)
        let event = makePastEvent(title: "E0")

        await service.analyzePastEvents([event])

        XCTAssertEqual(provider.sendCount, 1)
        XCTAssertTrue(
            store.isAnalyzed(event.id),
            "a paid answer marks the event even when no insight can be parsed"
        )
        XCTAssertTrue(store.insights.isEmpty, "the paid answer yields no insight")

        await service.analyzePastEvents([event])
        XCTAssertEqual(provider.sendCount, 1, "an unparseable paid answer is never retried")
    }

    func testSuccessfulSendWithNilContentIsMarkedAndNeverRetried() async {
        let provider = ScriptedQAProvider()
        provider.successContent = .some(nil)
        let service = makeService(provider: provider)
        let event = makePastEvent(title: "E0")

        await service.analyzePastEvents([event])

        XCTAssertEqual(provider.sendCount, 1)
        XCTAssertTrue(store.isAnalyzed(event.id))
        XCTAssertTrue(store.insights.isEmpty)

        await service.analyzePastEvents([event])
        XCTAssertEqual(provider.sendCount, 1)
    }

    // MARK: - Interleaving at await points

    func testRecordCompletedCallbackForInFlightSweepEventDoesNotDoubleSend() async throws {
        let provider = ScriptedQAProvider()
        provider.blockAtSendNumber = 1
        let service = makeService(provider: provider)
        let e0 = makePastEvent(title: "E0")
        let e1 = makePastEvent(title: "E1")

        let sweep = Task { await service.analyzePastEvents([e0, e1]) }
        try await waitUntil { provider.sendCount >= 1 }

        // The record-completed callback fires for e0 while the sweep's send
        // for e0 is suspended. inFlightEventIds must exclude it.
        let dup = Task { await service.analyzeEvent(e0) }
        for _ in 0..<25 { await Task.yield() }
        XCTAssertEqual(provider.sendCount, 1, "no duplicate send for an in-flight event")

        provider.openGate()
        await dup.value
        await sweep.value

        XCTAssertEqual(provider.sendCount, 2, "e0 once (sweep) + e1 once")
        XCTAssertTrue(store.isAnalyzed(e0.id))
        XCTAssertTrue(store.isAnalyzed(e1.id))
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 1,
            "the deduped single-event call must not add a ledger write"
        )
    }

    func testSweepSkipsInFlightSingleEventWithoutSpendingACapSlot() async throws {
        let provider = ScriptedQAProvider()
        provider.blockAtSendNumber = 1
        let service = makeService(provider: provider)
        let events = (0..<12).map { makePastEvent(title: "E\($0)") }

        // e0 goes in flight via the record-completed path and stays there.
        let single = Task { await service.analyzeEvent(events[0]) }
        try await waitUntil { provider.sendCount >= 1 }

        // The sweep runs to completion while e0 is still in flight: it must
        // skip e0 WITHOUT counting it against the cap, so sends go to
        // e1...e10 (10 attempts) and e11 is the one left for next launch.
        await service.analyzePastEvents(events)

        XCTAssertEqual(provider.sendCount, 11, "1 in-flight single + 10 sweep attempts")
        XCTAssertTrue(store.isAnalyzed(events[10].id), "the 11th event got the last cap slot")
        XCTAssertFalse(store.isAnalyzed(events[11].id), "the 12th waits for a future launch")
        XCTAssertFalse(
            provider.sentPrompts.dropFirst().contains { $0.contains("Activity title: E0\n") },
            "the sweep never re-sent the in-flight event"
        )

        provider.openGate()
        await single.value
        XCTAssertTrue(store.isAnalyzed(events[0].id))
        XCTAssertEqual(provider.sendCount, 11)
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 2,
            "one sweep flush + one immediate single-path save"
        )
    }

    // MARK: - Cancellation arithmetic

    func testCancelWithFourthSendInFlightFlushesTheCompletedPrefixOnce() async throws {
        let provider = ScriptedQAProvider()
        provider.blockAtSendNumber = 4
        let service = makeService(provider: provider)
        let events = (0..<8).map { makePastEvent(title: "E\($0)") }

        let sweep = Task { await service.analyzePastEvents(events) }
        try await waitUntil { provider.sendCount >= 4 }

        sweep.cancel()
        provider.openGate()
        await sweep.value

        // Three sends completed before the cancel, the in-flight fourth was
        // already owed and completes; the loop then observes cancellation.
        XCTAssertEqual(provider.sendCount, 4)
        for i in 0..<4 {
            XCTAssertTrue(store.isAnalyzed(events[i].id), "completed prefix E\(i) must be marked")
        }
        for i in 4..<8 {
            XCTAssertFalse(store.isAnalyzed(events[i].id), "E\(i) must remain unmarked")
        }
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 1,
            "a cancelled sweep flushes its earned prefix exactly once"
        )
        let persisted = Set(defaults.array(forKey: Self.analyzedKey) as? [String] ?? [])
        XCTAssertEqual(persisted, Set(events.prefix(4).map(\.id.uuidString)))
    }

    func testCancelBeforeSweepStartsSendsAndWritesNothing() async {
        let provider = ScriptedQAProvider()
        let service = makeService(provider: provider)
        let events = (0..<5).map { makePastEvent(title: "E\($0)") }

        // Both the test and the service are MainActor-bound: cancelling
        // before the first await means the sweep body observes cancellation
        // at its first loop check, before any send.
        let sweep = Task { await service.analyzePastEvents(events) }
        sweep.cancel()
        await sweep.value

        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertTrue(events.allSatisfy { !store.isAnalyzed($0.id) })
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 0,
            "a sweep cancelled before any work writes nothing"
        )
    }

    // MARK: - Ledger write arithmetic

    func testCapBoundaryTenSuccessesWriteLedgerOnce() async {
        let provider = ScriptedQAProvider()
        let service = makeService(provider: provider)
        let events = (0..<10).map { makePastEvent(title: "E\($0)") }

        await service.analyzePastEvents(events)

        XCTAssertEqual(provider.sendCount, 10)
        XCTAssertEqual(defaults.writes(forKey: Self.analyzedKey), 1)
        let persisted = Set(defaults.array(forKey: Self.analyzedKey) as? [String] ?? [])
        XCTAssertEqual(persisted, Set(events.map(\.id.uuidString)))
    }

    func testMixedFailuresFlushPersistsOnlySuccesses() async {
        let provider = ScriptedQAProvider()
        provider.poisonMarker = "POISON"
        let service = makeService(provider: provider)
        let events = [
            makePastEvent(title: "E0"),
            makePastEvent(title: "POISON-1"),
            makePastEvent(title: "E2"),
            makePastEvent(title: "POISON-3"),
            makePastEvent(title: "E4"),
        ]

        await service.analyzePastEvents(events)

        XCTAssertEqual(provider.sendCount, 5, "failures still count as attempts")
        XCTAssertEqual(defaults.writes(forKey: Self.analyzedKey), 1)
        let persisted = Set(defaults.array(forKey: Self.analyzedKey) as? [String] ?? [])
        XCTAssertEqual(
            persisted,
            Set([events[0], events[2], events[4]].map(\.id.uuidString)),
            "only successful sends are in the flushed ledger"
        )
    }

    func testSweepWithNothingEligibleWritesNothing() async {
        let provider = ScriptedQAProvider()
        let service = makeService(provider: provider)
        let events = (0..<3).map { makeShortEvent(title: "S\($0)") }
            + (0..<2).map { makeFutureEvent(title: "F\($0)") }

        await service.analyzePastEvents(events)

        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(
            defaults.writes(forKey: Self.analyzedKey), 0,
            "an all-ineligible sweep must not touch the ledger"
        )
    }

    // MARK: - Crash window between insight save and ledger flush

    func testCrashBeforeFlushDuplicatesInsightOnNextLaunchWitness() async throws {
        // Insights persist per-insight (add -> save, immediately durable)
        // but sweep marks persist only at flush. A process death mid-sweep
        // therefore keeps the paid insight AND forgets the mark, so the
        // next launch re-sends the same event and stores a second copy of
        // its insight (double skill points). The old mark-first order could
        // not duplicate; the fix trades that for retry-ability. Pinned here
        // so the trade is on the record.
        let provider1 = ScriptedQAProvider()
        provider1.blockAtSendNumber = 2
        let service1 = makeService(provider: provider1)
        let e0 = makePastEvent(title: "E0")
        let e1 = makePastEvent(title: "E1")

        let sweep1 = Task { await service1.analyzePastEvents([e0, e1]) }
        try await waitUntil { provider1.sendCount >= 2 }

        // Mid-sweep durable state: e0's insight persisted, ledger not.
        XCTAssertEqual(defaults.writes(forKey: Self.analyzedKey), 0)
        let midInsights = (try? JSONDecoder().decode(
            [SkillInsight].self,
            from: defaults.data(forKey: Self.insightsKey) ?? Data()
        )) ?? []
        XCTAssertEqual(midInsights.filter { $0.eventTitle == "E0" }.count, 1)

        // "Crash": next launch reloads from the same defaults before the
        // suspended sweep ever flushed.
        let store2 = SkillInsightStore(defaults: defaults)
        XCTAssertFalse(store2.isAnalyzed(e0.id), "the mark died with the process")
        let provider2 = ScriptedQAProvider()
        let service2 = SkillAnalysisService(insightStore: store2, providerFactory: { provider2 })

        await service2.analyzePastEvents([e0, e1])

        XCTAssertEqual(provider2.sendCount, 2, "e0 is re-sent (paid twice)")
        XCTAssertEqual(
            store2.insights.filter { $0.eventTitle == "E0" }.count, 2,
            "the re-analysis stores a second insight for the same event"
        )

        // Tidy up the suspended first sweep.
        provider1.openGate()
        await sweep1.value
    }
}
