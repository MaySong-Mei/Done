//
//  LocalDataEraseEpoch.swift
//  Done
//
//  The one thing "erase all local data" cannot do by deleting files: stop a
//  write that was already in flight when the user tapped it.
//
//  Several paths in this app start a long network operation, await it, and
//  then write user content to a backed-up directory. None of them re-checked
//  on the way back whether the data it was about to write still belonged to
//  anyone. This header said "three paths" and named three; round-2 review
//  enumerated independently and found six, which is the whole problem with
//  counting writers in prose — the count is maintained by whoever last
//  happened to look. The ones gated today:
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
//    • `SkillAnalysisService` — a launch-time sweep, one paid call per past
//      event, then model prose into the just-cleared skill store and the
//      user's event UUIDs back into `skillAnalyzedEventIds`.
//    • `TokenInferenceEngine` — up to four round trips off a store sink,
//      then all three keys `TokenInferenceRepository.clearAll()` removes,
//      including a projection carrying `reasoningSummary`.
//    • `ImageBackupCoordinator`'s avatar pair — `downloadAvatarIfMissing`
//      writes the user's face back to `Documents/`, and the erase CREATES
//      its precondition (`MeAvatarStore.delete()` is what makes its
//      `hasImage` guard pass); `syncAvatarIfNeeded` re-creates the
//      per-account `lastSyncedAvatarVersion.<id>` key.
//    • `SpikeRunStore` — a manual spike run armed before the erase and
//      closed after it. Here the token rides on the record value itself
//      (`SpikeRun.eraseEpoch`) and the store's one append path refuses a
//      value born before the erase. That gates VALUES, not writers: a writer
//      that keeps pre-erase state in memory and builds a fresh `SpikeRun`
//      from it after the erase passes the check. The resident observer's
//      auto-window close and daily record are built that way and rely on
//      `ResidentObservationCenter.forgetAfterErase` instead; a new writer of
//      that shape needs its own forget, or a token taken when it started.
//
//  ⚠️ Nothing makes the next one fail on arrival. This is the write-side
//  twin of the gap `resetAllLocalData` admits for the purge list: a writer
//  that reaches an erasable store after a suspension point is not forced to
//  carry a token, so this list is maintained by hand and by review. gh#266's
//  registry has to cover both sides, or the next writer added to this app
//  joins the list silently.
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
//  That holds because of this app's transport, not because of tasks in
//  general — a premise worth naming, since the obvious fix for "a restore
//  spends minutes downloading photos" would break it. Verified at the time
//  of writing: every request goes through `URLSession.shared` (no
//  `URLSession(configuration:)` call site), `Info.plist` declares no
//  `UIBackgroundModes`, and there is no `BGTaskScheduler`, `@SceneStorage`
//  or `NSUserActivity` restoration. The one `beginBackgroundTask` (the
//  widget's category-stats build at a lifecycle flush) only keeps a running
//  process alive a little longer; it relaunches nothing.
//  Add a background `URLSessionConfiguration` and the OS relaunches the app
//  with a finished download in hand — at which point this epoch MUST
//  persist.
//
//  Monotonic rather than a boolean: "an erase is happening" has no honest
//  false edge (the writer resuming later has no way to know a second erase
//  has since begun), while "the count changed" does.
//

import Foundation

/// Counts "erase all local data" runs in this process, so an operation that
/// began before one can decline to write after it.
///
/// `nonisolated` so a nonisolated consumer can reach it without a hop, and
/// locked rather than actor-isolated so the choice does not have to be
/// revisited when one appears.
///
/// What it is NOT: this comment used to claim the writers are not all on the
/// main actor, with `LLMUsageStore` resuming "on whatever thread". Round-2
/// review checked the build settings and that is false —
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set for both Done
/// configurations, so `LLMUsageStore`, the `LLMProvider` file-scope helpers
/// and `ReportGenerationService` are all MainActor-isolated and the
/// continuation resumes there.
///
/// ⚠️ That makes MainActor isolation LOAD-BEARING for every gate's
/// correctness, which is worth stating because it is invisible: each
/// gate→write pair below contains no suspension point, so the window
/// between "not stale" and the bytes landing is zero instructions. Make any
/// gated writer `nonisolated` and the window becomes real — a background
/// thread passes the gate, the erase removes the directory, and the write
/// recreates it. That is gh#261 verbatim. `NSLock` here protects the counter
/// itself; it does not protect a gate→write pair that spans a suspension.
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
    ///
    /// `#if DEBUG` because `restore(_:)` moves the counter BACKWARDS, which
    /// is the one thing this type's correctness forbids: a production caller
    /// would make `isStale` answer "fresh" for a token that really did
    /// predate an erase, and the writer would then write. Nothing in `Done/`
    /// calls it, and this keeps it that way rather than relying on that
    /// staying true. Release builds do not have it to call.
    #if DEBUG
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
    #endif
}
