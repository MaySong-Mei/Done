//
//  LocalDataEraseEpoch.swift
//  Done
//
//  The one thing "erase all local data" cannot do by deleting files: stop a
//  write that was already in flight when the user tapped it.
//
//  Three paths in this app start a long network operation, await it, and then
//  write user content to a backed-up directory. None of them re-checks on the
//  way back whether the data it is about to write still belongs to anyone:
//
//    • `ReportGenerationService.generate` — awaits an LLM round trip (tens of
//      seconds), then `store.save(report)`, which RECREATES
//      `Documents/Reports/` and lands a prose narrative of the just-erased
//      events, plus their `statsSnapshot`.
//    • `ImageBackupCoordinator.downloadMissing` — computes its pending list
//      up front, then loops, awaiting one download per image and
//      `createDirectory` + `write` for each. Mid-erase, the remaining
//      iterations put the photographs back.
//    • `LLMProvider`'s usage accounting — folds a request that began before
//      the erase into a (day, model, purpose) bucket afterwards.
//
//  Deleting harder does not fix any of them; the write happens after the
//  delete. What fixes them is for the operation to carry a token taken when
//  it STARTED and refuse to write if an erase has begun since.
//
//  In-process on purpose, and deliberately NOT persisted. An in-flight task
//  dies with the process, so a relaunch has nothing stale to catch — and
//  every operation a new process starts is legitimately post-erase. A
//  persisted epoch would refuse those forever.
//
//  Monotonic rather than a boolean: "an erase is happening" has no honest
//  false edge (the writer resuming later has no way to know a second erase
//  has since begun), while "the count changed" does.
//

import Foundation

/// Counts "erase all local data" runs in this process, so an operation that
/// began before one can decline to write after it.
///
/// `nonisolated` because the writers are not all on the main actor:
/// `LLMUsageStore` folds buckets under its own `NSLock` from whatever thread
/// a URLSession continuation resumes on.
nonisolated enum LocalDataEraseEpoch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter = 0

    /// Take this when a long-running operation STARTS — before the first
    /// `await`, not after it. A token taken after the await is the bug.
    static func capture() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }

    /// Call as the FIRST statement of an erase, before any purge runs.
    ///
    /// First, not last: the point is to catch work that is already in flight,
    /// and that work's continuation can resume at any suspension point the
    /// erase itself reaches. Bumping at the end would leave the whole
    /// duration of the erase uncovered.
    static func bump() {
        lock.lock()
        counter += 1
        lock.unlock()
    }

    /// True when an erase has begun since `token` was captured, i.e. the
    /// caller is about to write data that may no longer belong to anyone.
    static func isStale(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != counter
    }

    /// Test seam. `capture()`/`bump()` are process-global, so a test that
    /// bumps leaves every later-running test holding a stale token — which
    /// would show up as unrelated flakes in whatever order the suite happens
    /// to run in. Tests bracket with this instead.
    static func withIsolatedEpoch<T>(_ body: () throws -> T) rethrows -> T {
        let saved = snapshot()
        defer { restore(saved) }
        return try body()
    }

    /// The async form, for the writers whose refusal can only be witnessed by
    /// awaiting them (`ImageBackupCoordinator.downloadMissing`).
    static func withIsolatedEpoch<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        let saved = snapshot()
        defer { restore(saved) }
        return try await body()
    }

    private static func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }

    private static func restore(_ value: Int) {
        lock.lock()
        counter = value
        lock.unlock()
    }
}
