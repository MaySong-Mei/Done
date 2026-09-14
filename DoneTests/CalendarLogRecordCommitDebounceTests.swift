//
//  CalendarLogRecordCommitDebounceTests.swift
//  DoneTests
//
//  gh#219 (note-typing log-record commit debounce). The reported cost: while
//  a reflection note is being typed, every keystroke funnelled through
//  `upsertLogRecord` re-encoded the WHOLE `calendarEventLogRecords` array and
//  fsync'd it on the MainActor — work that grows linearly with log history.
//
//  The fix defers ONLY the on-disk commit of the two note `onChange` sites
//  (`coalesced: true`), mirroring gh#138's `CalendarComposerDraftCadence`
//  (400 ms trailing debounce + 2.0 s max-wait). The seven discrete taps
//  (effort / completion / emotions / behaviors / template / images) stay
//  synchronous (`coalesced: false`), one commit per tap.
//
//  These fixtures pin the crash-window / flush-completeness reasoning that
//  would otherwise rot in a comment (doc-comment-rot lesson): the in-memory
//  mutation is never deferred, the disk commit IS, and every lifecycle edge
//  flushes it — a fresh store booted at the same location (standing in for a
//  process death + relaunch, the EventStoreDurabilityTests idiom) sees the
//  last typed note only because the flush ran.
//

import XCTest
@testable import Done

@MainActor
final class CalendarLogRecordCommitDebounceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarLogRecordCommitDebounceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private func seed(_ store: EventStore) -> Event {
        let event = Event(
            title: "Deep Work",
            timeRanges: [.init(start: Date(), end: Date().addingTimeInterval(3600))],
            type: "Study"
        )
        store.addCalendarEvent(event)
        return event
    }

    private func occurrence(_ eventID: UUID, on date: Date) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: date,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    private func logCommits(_ commits: [String]) -> Int {
        commits.filter { $0 == StorageSlot.calendarEventLogRecords.rawValue }.count
    }

    // MARK: - In-memory is never deferred (G1)

    /// The mutate closure runs on the tap's own turn even when the commit is
    /// coalesced, so the note text is readable immediately. Dies if the fix
    /// ever moves the mutation itself behind the debounce.
    func testCoalescedWriteUpdatesInMemoryRecordImmediately() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "hel" }
        // No flush, no wait — the in-memory record must already carry it.
        XCTAssertEqual(try XCTUnwrap(store.logRecord(for: ctx)).note, "hel")
    }

    // MARK: - Write-through / deferral cadence (G2)

    /// The first coalesced write of a session (nil `lastPersistAt`) writes
    /// through immediately, so there is always an early durable copy — the
    /// gh#138 first-change rule. Dies if the first keystroke is deferred.
    func testFirstCoalescedWriteWritesThroughImmediately() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "H" }

        XCTAssertEqual(logCommits(commits), 1, "first coalesced write of a session lands now")
    }

    /// After the first write-through, further coalesced keystrokes inside the
    /// window are NOT committed per keystroke — the whole point of the fix.
    /// Positive control for every "then flush" test below.
    func testSubsequentCoalescedWritesDeferTheCommit() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "H" } // write-through

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "He" }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "Hel" }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "Hell" }

        XCTAssertEqual(
            logCommits(commits), 0,
            "keystrokes inside the debounce window must not each re-fsync the array"
        )
        // ...but the text is live in memory the whole time.
        XCTAssertEqual(try XCTUnwrap(store.logRecord(for: ctx)).note, "Hell")
    }

    // MARK: - Flush completeness = durability (G3/G4/G9)

    /// The crash-window property, expressed the EventStoreDurabilityTests way:
    /// type N coalesced chars, run the lifecycle-edge flush, then boot a fresh
    /// store at the same location (the process died and relaunched). It must
    /// see the LAST typed note. Dies if `flushPendingLogRecordCommit` stops
    /// committing, or if the debounce ever deferred the in-memory write too.
    func testFlushLandsTheDeferredNoteToDiskForAFreshStore() throws {
        let a = makeStore()
        let event = seed(a)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        for text in ["H", "He", "Hel", "Hell", "Hello"] {
            a.upsertLogRecord(for: ctx, coalesced: true) { $0.note = text }
        }
        // Stand-in for scenePhase != .active / onDisappear / pre-dismiss.
        a.flushPendingLogRecordCommit()

        let b = makeStore()
        XCTAssertEqual(
            b.logRecord(for: ctx)?.note, "Hello",
            "a store built from the same files after the flush sees the final note"
        )
    }

    /// The negative control for the test above: WITHOUT the flush, a burst of
    /// deferred keystrokes (after the initial write-through) leaves only the
    /// first char on disk. This is exactly the loss the lifecycle flushes
    /// exist to prevent, and it proves the flush in the test above is doing
    /// real work rather than riding a commit that would have happened anyway.
    func testWithoutFlushOnlyTheWriteThroughReachesDisk() throws {
        let a = makeStore()
        let event = seed(a)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        a.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "H" }   // write-through
        a.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "He" }  // deferred
        a.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "Hel" } // deferred

        let b = makeStore()
        XCTAssertEqual(
            b.logRecord(for: ctx)?.note, "H",
            "the deferred tail is durable only after a flush; the write-through 'H' is what survives"
        )
    }

    /// `flushPendingLogRecordCommit` is a no-op when nothing is pending, so
    /// every lifecycle edge can call it unconditionally without a spurious
    /// commit (mirrors flushCalendarEventColorDepthMirror's empty guard).
    func testFlushIsNoOpWhenNothingPending() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx) { $0.effort = 3 } // discrete, commits + clears

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.flushPendingLogRecordCommit()

        XCTAssertEqual(logCommits(commits), 0, "no pending coalesced work → no commit")
    }

    // MARK: - Discrete taps stay immediate and exactly-once (G5/G7)

    /// A discrete tap (`coalesced: false`) commits the log-record slot exactly
    /// once, on its own turn — the gh#201 `logRecordSlotWrites == 1` per tap
    /// invariant. Dies if a discrete field is ever routed through the debounce.
    func testDiscreteTapCommitsImmediatelyAndExactlyOnce() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: false) { $0.effort = 4 }

        XCTAssertEqual(logCommits(commits), 1, "one discrete tap = one log-record commit")
    }

    /// A discrete tap arriving while a note commit is pending must absorb it:
    /// the whole array (note text included) rides the discrete tap's single
    /// commit, and NO orphan debounce fires a redundant second commit
    /// afterward. This is what makes the discrete-tap count stay exactly 1
    /// even in the presence of a coalesced note.
    func testDiscreteTapAbsorbsPendingNoteWithoutOrphanCommit() async throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "draft" } // write-through
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "draft2" } // deferred (armed)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: false) { $0.effort = 2 } // discrete → absorbs

        XCTAssertEqual(logCommits(commits), 1, "the discrete tap commits once, carrying the pending note")

        // Wait well past the debounce window: the absorbed task must not fire.
        try await Task.sleep(for: CalendarComposerDraftCadence.debounce * 3)
        XCTAssertEqual(logCommits(commits), 1, "no orphan debounce fires after the discrete tap cancelled it")

        // The one commit carried both values, and a fresh store confirms it.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.logRecord(for: ctx)?.note, "draft2")
        XCTAssertEqual(reloaded.logRecord(for: ctx)?.effort, 2)
    }

    // MARK: - The debounce actually arms (G2 arming)

    /// The ARMING of the debounce task, reachable no other way: after the
    /// initial write-through, a deferred keystroke must land ON ITS OWN once
    /// the trailing window elapses, with nothing calling the flush. Delete the
    /// `Task { … sleep … commit }` block (keeping the pending flag + cancel)
    /// and this is the only fixture that goes red — the note would then sit
    /// unwritten until a lifecycle edge fired.
    ///
    /// Presence-based and reads the window off the shared constant, so
    /// widening it cannot turn this into a race (the timing-flake lesson).
    func testDeferredNoteLandsOnItsOwnAfterTheDebounceWindow() async throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "a" } // write-through

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "ab" } // deferred, arms task
        XCTAssertEqual(logCommits(commits), 0, "positive control: still pending inside the window")

        try await Task.sleep(for: CalendarComposerDraftCadence.debounce * 4)

        XCTAssertEqual(logCommits(commits), 1, "the debounce lands the deferred note on its own")
        XCTAssertEqual(try XCTUnwrap(store.logRecord(for: ctx)).note, "ab")
    }
}
