import XCTest
@testable import Done

final class LLMUsageStoreTests: XCTestCase {
    private var directory: URL!
    private var store: LLMUsageStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMUsageStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = LLMUsageStore(directoryURL: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
        super.tearDown()
    }

    func testRecordAggregatesIntoSameDayModelPurposeBucket() {
        let now = Date()
        store.record(model: "deepseek-chat", purpose: "report", inputTokens: 100, cachedInputTokens: 10, outputTokens: 5, date: now)
        store.record(model: "deepseek-chat", purpose: "report", inputTokens: 200, cachedInputTokens: 0, outputTokens: 15, date: now)

        let buckets = store.allBuckets()
        XCTAssertEqual(buckets.count, 1)
        let bucket = buckets[0]
        XCTAssertEqual(bucket.requests, 2)
        XCTAssertEqual(bucket.inputTokens, 300)
        XCTAssertEqual(bucket.cachedInputTokens, 10)
        XCTAssertEqual(bucket.outputTokens, 20)
        XCTAssertEqual(bucket.totalTokens, 330)
    }

    func testDistinctPurposesAndModelsGetDistinctBuckets() {
        let now = Date()
        store.record(model: "deepseek-chat", purpose: "report", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: now)
        store.record(model: "deepseek-chat", purpose: "chat", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: now)
        store.record(model: "gpt-4o", purpose: "chat", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: now)
        // Untagged requests fall into "other".
        store.record(model: "gpt-4o", purpose: nil, inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: now)

        let buckets = store.allBuckets()
        XCTAssertEqual(buckets.count, 4)
        XCTAssertTrue(buckets.contains { $0.purpose == "other" && $0.model == "gpt-4o" })
    }

    func testPersistenceRoundTripsThroughNewInstance() {
        store.record(model: "deepseek-chat", purpose: "skill", inputTokens: 42, cachedInputTokens: 7, outputTokens: 3)

        let reloaded = LLMUsageStore(directoryURL: directory)
        let buckets = reloaded.allBuckets()
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].inputTokens, 42)
        XCTAssertEqual(buckets[0].cachedInputTokens, 7)
        XCTAssertEqual(buckets[0].outputTokens, 3)
    }

    func testRecordPrunesBucketsPastRetention() {
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -120, to: now)!
        store.record(model: "deepseek-chat", purpose: "report", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: old)
        // The prune runs against the newest record's date.
        store.record(model: "deepseek-chat", purpose: "report", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: now)

        let buckets = store.allBuckets()
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].requests, 1)
    }

    func testRecordFailureCountsSeparatelyWithZeroTokens() {
        let now = Date()
        store.record(model: "deepseek-chat", purpose: "report", inputTokens: 100, cachedInputTokens: 0, outputTokens: 10, date: now)
        store.recordFailure(model: "deepseek-chat", purpose: "report", date: now)
        store.recordFailure(model: "deepseek-chat", purpose: "report", date: now)

        let buckets = store.allBuckets()
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].requests, 1)
        XCTAssertEqual(buckets[0].failedRequests, 2)
        XCTAssertEqual(buckets[0].totalTokens, 110)
    }

    // Ledger files written before `failedRequests` existed must keep loading
    // (missing field → 0), not drop the whole history.
    func testLegacyFileWithoutFailedRequestsStillDecodes() throws {
        let legacy = """
        [{"day": "2026-07-10", "model": "deepseek-chat", "purpose": "report",
          "requests": 5, "inputTokens": 100, "cachedInputTokens": 20, "outputTokens": 30}]
        """
        try legacy.data(using: .utf8)!.write(to: directory.appendingPathComponent("llm-usage.json"))

        let reloaded = LLMUsageStore(directoryURL: directory)
        let buckets = reloaded.allBuckets()
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].requests, 5)
        XCTAssertEqual(buckets[0].failedRequests, 0)
    }

    func testClearAllEmptiesStoreAndDisk() {
        store.record(model: "deepseek-chat", purpose: "report", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0)
        store.clearAll()
        XCTAssertTrue(store.allBuckets().isEmpty)
        XCTAssertTrue(LLMUsageStore(directoryURL: directory).allBuckets().isEmpty)
    }

    func testDayKeysWindowMatchesRecordedDays() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let lastWeek = calendar.date(byAdding: .day, value: -8, to: now)!
        store.record(model: "m", purpose: "p", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: now)
        store.record(model: "m", purpose: "p", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: yesterday)
        store.record(model: "m", purpose: "p", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, date: lastWeek)

        let todayKeys = store.dayKeys(back: 0)
        let weekKeys = store.dayKeys(back: 6)
        let buckets = store.allBuckets()
        XCTAssertEqual(buckets.filter { todayKeys.contains($0.day) }.count, 1)
        XCTAssertEqual(buckets.filter { weekKeys.contains($0.day) }.count, 2)
    }
}
