//
//  LLMUsageStore.swift
//  Done
//
//  Local ledger of LLM API usage, fed by the providers from the usage block
//  each API response already carries — real billed figures, not client-side
//  estimates.  Born out of the 2026-07 cost incident (62.7M tokens in 30 days,
//  ~95% of it an auto-triggered loop nobody could see): the Developer settings
//  page reads this store so runaway spend shows up in-app the day it starts,
//  not on next month's bill.
//
//  Aggregation, not a log: one bucket per (local day, model, purpose), so the
//  file stays a few KB no matter how long the app runs.  `purpose` is the
//  coarse caller tag threaded through `LLMRequest.purpose` ("report", "chat",
//  "token-inference", …); requests without one land in "other".
//
//  Thread-safe: providers record from arbitrary async contexts, the settings
//  UI reads on the main actor — every entry point takes `lock`.  Pure
//  Foundation, local-only; usage never syncs anywhere.
//

import Foundation

/// All requests on one local calendar day for one (model, purpose) pair.
struct LLMUsageBucket: Codable, Hashable {
    /// Local day the requests landed on, formatted `yyyy-MM-dd`.
    var day: String
    var model: String
    var purpose: String
    var requests: Int
    /// Billed (cache-miss) input tokens.  For Anthropic this includes
    /// cache-creation tokens; for OpenAI/DeepSeek it is prompt minus hits.
    var inputTokens: Int
    /// Cache-hit input tokens (billed at the provider's discounted rate).
    var cachedInputTokens: Int
    var outputTokens: Int

    var totalTokens: Int { inputTokens + cachedInputTokens + outputTokens }
}

final class LLMUsageStore {
    static let shared = LLMUsageStore()
    /// Posted (on the main queue) after every mutation so the Developer page
    /// can live-update while requests land.
    static let didChange = Notification.Name("LLMUsageStoreDidChange")

    /// Buckets older than this are pruned on record — enough history for a
    /// "last 30 days" view with headroom, small enough to never matter.
    private let retentionDays = 90

    private let lock = NSLock()
    private var buckets: [String: LLMUsageBucket]
    private let fileURL: URL
    private let dayFormatter: DateFormatter

    /// - Parameter directoryURL: override the storage location (tests);
    ///   defaults to `Documents/DeveloperStats`.
    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        let directory = directoryURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DeveloperStats", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("llm-usage.json")

        // Fixed-format local-day key; formatter is guarded by `lock` like the
        // rest of the mutable state (DateFormatter is not thread-safe).
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LLMUsageBucket].self, from: data) {
            buckets = Dictionary(
                decoded.map { ("\($0.day)|\($0.model)|\($0.purpose)", $0) },
                uniquingKeysWith: { $1 }
            )
        } else {
            buckets = [:]
        }
    }

    // MARK: - API

    /// Folds one API round-trip into its (today, model, purpose) bucket and
    /// persists.  Zero-token calls still count the request (a failed decode of
    /// the usage block shouldn't hide that a request happened).
    func record(
        model: String,
        purpose: String?,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        date: Date = Date()
    ) {
        lock.lock()
        let day = dayFormatter.string(from: date)
        let purposeKey = purpose ?? "other"
        let key = "\(day)|\(model)|\(purposeKey)"
        var bucket = buckets[key] ?? LLMUsageBucket(
            day: day, model: model, purpose: purposeKey,
            requests: 0, inputTokens: 0, cachedInputTokens: 0, outputTokens: 0
        )
        bucket.requests += 1
        bucket.inputTokens += max(0, inputTokens)
        bucket.cachedInputTokens += max(0, cachedInputTokens)
        bucket.outputTokens += max(0, outputTokens)
        buckets[key] = bucket
        pruneLocked(now: date)
        persistLocked()
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    func allBuckets() -> [LLMUsageBucket] {
        lock.lock()
        defer { lock.unlock() }
        return Array(buckets.values)
    }

    func clearAll() {
        lock.lock()
        buckets = [:]
        persistLocked()
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// The `yyyy-MM-dd` keys for today back through `daysBack` days ago —
    /// the filter the usage page uses to window buckets.
    func dayKeys(back daysBack: Int, from date: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var keys: Set<String> = []
        for offset in 0...max(0, daysBack) {
            if let day = calendar.date(byAdding: .day, value: -offset, to: date) {
                keys.insert(dayFormatter.string(from: day))
            }
        }
        return keys
    }

    // MARK: - Private (call with `lock` held)

    private func pruneLocked(now: Date) {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        // String compare works because the day key is zero-padded ISO order.
        let cutoff = dayFormatter.string(from: cutoffDate)
        buckets = buckets.filter { $0.value.day >= cutoff }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(Array(buckets.values).sorted { $0.day > $1.day }) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
