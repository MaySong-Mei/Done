//
//  CalendarLogRecordCommitDebounceQATests.swift
//  DoneTests
//
//  gh#219 — INDEPENDENT QA (not the implementer). Verifies the note-typing
//  log-record commit debounce from the outside: the durability of every
//  lifecycle flush edge, the positive controls that prove the debounce really
//  coalesces while discrete taps stay immediate, the max-wait ceiling, and the
//  view-level wiring that decides WHICH onChange coalesces and WHICH lifecycle
//  edge flushes.
//
//  Two instruments, deliberately separated:
//
//    * BEHAVIOURAL (the mechanism): boots real EventStores at a shared storage
//      location — the EventStoreDurabilityTests process-death idiom — and
//      asserts what reaches disk. These kill the store-level mutants
//      (flush no-ops, debounce disabled, discrete tap coalesced, max-wait
//      dropped).
//
//    * SOURCE-WIRING INVENTORY (the plumbing): the five lifecycle flush edges
//      and the coalesced-flag routing live in SwiftUI view bodies that XCTest
//      cannot drive without a UI host. Following the Spike201EmitSiteInventory
//      precedent in SpikeHarnessTests.swift, these pin the SOURCE: they prove
//      each edge's flush call and each coalesced:true site exists exactly where
//      G3/G4/G5/G6 require, so deleting an edge or coalescing a discrete field
//      turns a test red. Declared as the weaker instrument it is — it proves
//      the call is written, not that it is reached at runtime.
//

import XCTest
@testable import Done

@MainActor
final class CalendarLogRecordCommitDebounceQATests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarLogRecordCommitDebounceQATests-\(UUID().uuidString)"
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

    /// Count of `.calendarEventLogRecords` commits in an onSlotCommitted trace.
    private func logCommits(_ commits: [String]) -> Int {
        commits.filter { $0 == StorageSlot.calendarEventLogRecords.rawValue }.count
    }

    // ------------------------------------------------------------------
    // MARK: - BEHAVIOURAL: durability across every flush edge (G3/G4/G9)
    // ------------------------------------------------------------------

    /// THE load-bearing durability fixture. All five view flush edges
    /// (detail scenePhase, detail onDisappear, log-sheet scenePhase,
    /// log-sheet onDisappear, log-sheet Cancel pre-dismiss) converge on the
    /// SAME store call — `flushPendingLogRecordCommit()`. This exercises that
    /// shared mechanism the way the process would at any of those edges: type
    /// a burst of coalesced chars, flush, then boot a FRESH store at the same
    /// files (a process death + relaunch) and require it sees the final note.
    ///
    /// Kills the "flush stops committing" mutant: with `flushPendingLogRecordCommit`
    /// a no-op, the fresh store would see only the write-through prefix, not
    /// "Hello, world".
    func testFlushAtLifecycleEdgeLandsFinalNoteForFreshStore() throws {
        let a = makeStore()
        let event = seed(a)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        // A realistic keystroke burst — each a distinct payload so no
        // identical-digest skip masks a real deferral.
        for text in ["H", "He", "Hel", "Hell", "Hello", "Hello,", "Hello, w", "Hello, world"] {
            a.upsertLogRecord(for: ctx, coalesced: true) { $0.note = text }
        }
        // The one call every lifecycle edge makes.
        a.flushPendingLogRecordCommit()

        let reborn = makeStore()
        XCTAssertEqual(
            reborn.logRecord(for: ctx)?.note, "Hello, world",
            "a store rebuilt from the same files after the edge flush must see the LAST typed note"
        )
    }

    /// The negative control that gives the fixture above its teeth: WITHOUT
    /// the flush, the deferred tail never reaches disk — only the session's
    /// first-change write-through survives. Proves the flush in the test above
    /// is doing real work, not riding a commit that would have happened anyway.
    /// Also the direct statement of the gh#138 data-loss hole this branch must
    /// not reopen.
    func testWithoutAnyFlushOnlyTheWriteThroughSurvives() throws {
        let a = makeStore()
        let event = seed(a)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        a.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "H" }    // first change -> write-through
        a.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "He" }   // deferred
        a.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "Hel" }  // deferred
        // No flush: simulate a kill with no lifecycle edge having fired.

        let reborn = makeStore()
        XCTAssertEqual(
            reborn.logRecord(for: ctx)?.note, "H",
            "without a flush only the write-through 'H' is durable; the deferred tail is the loss the edges prevent"
        )
    }

    /// The in-memory model is NEVER deferred (G1): even a coalesced write makes
    /// the note readable on the tap's own turn, before any flush or wait.
    /// Kills a mutant that pushes the `mutate` closure itself behind the debounce.
    func testCoalescedWriteIsLiveInMemoryImmediately() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "typed just now" }
        XCTAssertEqual(
            try XCTUnwrap(store.logRecord(for: ctx)).note, "typed just now",
            "the in-memory record must carry the note with no flush and no wait"
        )
    }

    // ------------------------------------------------------------------
    // MARK: - BEHAVIOURAL: positive control — debounce merges (G1 disk side)
    // ------------------------------------------------------------------

    /// PROOF THE DEBOUNCE COALESCES. After the session's first write-through,
    /// a burst of further keystrokes inside the window produces ZERO disk
    /// commits — the whole point of gh#219. Kills the "debounce disabled,
    /// every keystroke still commits" mutant, which turns this count into 3.
    func testContinuousTypingInsideWindowCommitsZeroTimes() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "H" } // write-through (arms clock)

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "He" }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "Hel" }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "Hell" }

        XCTAssertEqual(
            logCommits(commits), 0,
            "keystrokes inside the debounce window must not each re-fsync the whole array"
        )
        XCTAssertEqual(
            try XCTUnwrap(store.logRecord(for: ctx)).note, "Hell",
            "…while the text is nonetheless live in memory the entire time"
        )
    }

    // ------------------------------------------------------------------
    // MARK: - BEHAVIOURAL: positive control — discrete taps stay immediate (G5/G7)
    // ------------------------------------------------------------------

    /// PROOF DISCRETE TAPS STAY IMMEDIATE and one-commit-per-tap (the gh#201
    /// `logRecordSlotWrites == 1 per tap` attribution invariant, read at the
    /// `onSlotCommitted` layer that feeds SpikeModel). TWO consecutive discrete
    /// taps commit TWICE — one each, synchronously.
    ///
    /// Two taps (not one) on purpose: the FIRST write of a fresh session writes
    /// through even on the coalesced path (nil `lastPersistAt`), so a single-tap
    /// count of 1 would not distinguish "discrete commits now" from "coalesced
    /// happened to write through first". The SECOND tap lands inside the window,
    /// where only a genuinely-immediate discrete path still commits. Kills the
    /// "discrete tap routed through the debounce" mutant (which yields 1, the
    /// deferred second tap absent).
    func testTwoDiscreteTapsCommitTwiceImmediately() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: false) { $0.effort = 4 }
        store.upsertLogRecord(for: ctx, coalesced: false) { $0.effort = 5 }

        XCTAssertEqual(
            logCommits(commits), 2,
            "two discrete taps = two immediate log-record commits (one per tap), no deferral"
        )
    }

    /// A discrete tap arriving while a coalesced note is pending must ABSORB it:
    /// the whole array (note included) rides the discrete tap's single commit,
    /// and NO orphan debounce fires afterward. This is what keeps the per-tap
    /// count exactly 1 even in the presence of a live coalesced note.
    func testDiscreteTapAbsorbsPendingNoteWithNoOrphanCommit() async throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "draft" }  // write-through
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "draft2" } // deferred, armed

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: false) { $0.effort = 2 }     // discrete -> absorbs

        XCTAssertEqual(logCommits(commits), 1, "the discrete tap commits once, carrying the pending note")

        try await Task.sleep(for: CalendarComposerDraftCadence.debounce * 3)
        XCTAssertEqual(logCommits(commits), 1, "no orphan debounce fires after the discrete tap cancelled it")

        let reborn = makeStore()
        XCTAssertEqual(reborn.logRecord(for: ctx)?.note, "draft2")
        XCTAssertEqual(reborn.logRecord(for: ctx)?.effort, 2)
    }

    /// `flushPendingLogRecordCommit` is a no-op when nothing is pending, so a
    /// lifecycle edge that fires after a discrete tap already committed does
    /// not emit a spurious second commit (mirrors the colorDepth mirror's
    /// empty guard).
    func testFlushIsNoOpWhenNothingPending() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: false) { $0.effort = 3 } // commits + clears pending

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.flushPendingLogRecordCommit()

        XCTAssertEqual(logCommits(commits), 0, "nothing pending -> flush commits nothing")
    }

    // ------------------------------------------------------------------
    // MARK: - BEHAVIOURAL: the max-wait ceiling (G2)
    // ------------------------------------------------------------------

    /// PROOF THE 2.0 s MAX-WAIT CEILING FIRES. A pure trailing debounce never
    /// lands while the user keeps typing; the ceiling forces a write-through
    /// once `maxWait` has elapsed since the last commit. Here: an initial
    /// write-through stamps the clock, we let more than `maxWait` pass, then a
    /// single coalesced write must land SYNCHRONOUSLY (write-through), not
    /// schedule a 400 ms task.
    ///
    /// Kills the "max-wait removed, only the silence window remains" mutant:
    /// with the ceiling gone the post-ceiling write debounces (0 immediate
    /// commits) instead of writing through. The assertion runs with no await
    /// between the write and the check, so a scheduled debounce task cannot
    /// have fired — the count is deterministic.
    func testContinuousTypingWritesThroughOnceMaxWaitElapses() async throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "a" } // write-through, stamps lastPersistAt

        // Let the ceiling elapse. Generous margin over the 2.0 s ceiling so a
        // widened ceiling would surface as a real red, not a flake, and the
        // sleep-at-least guarantee keeps elapsed strictly above it.
        try await Task.sleep(for: .seconds(CalendarComposerDraftCadence.maxWait + 0.4))

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "ab" } // must write through (elapsed >= maxWait)

        XCTAssertEqual(
            logCommits(commits), 1,
            "a coalesced write past the max-wait ceiling must write through synchronously, not defer"
        )
    }

    /// The first coalesced write of a session (nil `lastPersistAt`) writes
    /// through immediately, so there is always an early durable copy — the
    /// gh#138 first-change rule and the reason `testWithoutAnyFlush…` sees "H".
    func testFirstCoalescedWriteOfASessionWritesThrough() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "H" }

        XCTAssertEqual(logCommits(commits), 1, "first coalesced write of a session lands now")
    }

    /// The debounce task ARMS and lands the deferred note ON ITS OWN once the
    /// trailing window elapses, with nothing calling a flush. Reads the window
    /// off the shared constant so widening it cannot turn this into a race.
    func testDeferredNoteLandsOnItsOwnAfterTheWindow() async throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "a" } // write-through

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx, coalesced: true) { $0.note = "ab" } // deferred, arms task
        XCTAssertEqual(logCommits(commits), 0, "positive control: still pending inside the window")

        try await Task.sleep(for: CalendarComposerDraftCadence.debounce * 4)

        XCTAssertEqual(logCommits(commits), 1, "the trailing debounce lands the deferred note by itself")
        XCTAssertEqual(try XCTUnwrap(store.logRecord(for: ctx)).note, "ab")
    }

    // ------------------------------------------------------------------
    // MARK: - SOURCE-WIRING INVENTORY: the five flush edges (G3/G4)
    // ------------------------------------------------------------------
    //
    // XCTest cannot drive SwiftUI scenePhase / onDisappear / button taps, so
    // per the Spike201EmitSiteInventory precedent these pin the SOURCE of each
    // flush edge. Deleting an edge's flush call turns its own test red — that
    // is the "remove a flush edge -> a fixture goes red" kill for the edges
    // that only exist in view code.

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Source with `//` comment lines removed and all runs of whitespace
    /// collapsed to single spaces — so a signature match keys on real code, not
    /// a doc comment (doc-comment-rot lesson) and survives reformatting.
    private func collapsedCode(_ src: String) -> String {
        let noComments = src
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return noComments
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Balanced `{ … }` block that follows the first occurrence of `marker`
    /// (comments stripped first so a brace in a comment can't skew the count).
    /// Returns nil if the marker or a balanced block is not found.
    private func balancedBlock(after marker: String, in src: String) -> String? {
        let noComments = src
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let markerRange = noComments.range(of: marker) else { return nil }
        guard let open = noComments.range(of: "{", range: markerRange.upperBound..<noComments.endIndex) else {
            return nil
        }
        var depth = 0
        var i = open.lowerBound
        while i < noComments.endIndex {
            let ch = noComments[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(noComments[open.upperBound..<i])
                }
            }
            i = noComments.index(after: i)
        }
        return nil
    }

    private let detailPath = "Done/Views/Calendar/CalendarEventDetailView.swift"
    private let logSheetPath = "Done/Views/Calendar/CalendarEventLogSheet.swift"

    /// EDGE 1 — CalendarEventDetailView scenePhase != .active flushes the note.
    func testDetailViewScenePhaseFlushEdgeIsWired() throws {
        let block = try XCTUnwrap(
            balancedBlock(after: ".onChange(of: scenePhase)", in: source(detailPath)),
            "detail view must have a scenePhase onChange"
        )
        XCTAssertTrue(block.contains("phase != .active"), "scenePhase flush must be gated on leaving .active")
        XCTAssertTrue(
            block.contains("store.flushPendingLogRecordCommit()"),
            "detail scenePhase edge must flush the pending note commit before suspension (G3)"
        )
    }

    /// EDGE 2 — CalendarEventDetailView onDisappear flushes the note on teardown.
    func testDetailViewOnDisappearFlushEdgeIsWired() throws {
        let block = try XCTUnwrap(
            balancedBlock(after: ".onDisappear", in: source(detailPath)),
            "detail view must have an onDisappear"
        )
        XCTAssertTrue(
            block.contains("store.flushPendingLogRecordCommit()"),
            "detail onDisappear edge must flush the pending note commit on teardown (G3)"
        )
    }

    /// EDGE 3 — CalendarEventLogSheet editor scenePhase != .active flushes.
    /// This observer did NOT exist before this branch — it is the reopened
    /// gh#138 foreground-kill hole G4 closes.
    func testLogSheetScenePhaseFlushEdgeIsWired() throws {
        let src = try source(logSheetPath)
        XCTAssertTrue(
            src.contains("@Environment(\\.scenePhase)"),
            "log-sheet editor must observe scenePhase (it had none before — G4)"
        )
        let block = try XCTUnwrap(
            balancedBlock(after: ".onChange(of: scenePhase)", in: src),
            "log-sheet editor must have a scenePhase onChange"
        )
        XCTAssertTrue(block.contains("phase != .active"), "log-sheet scenePhase flush must be gated on leaving .active")
        XCTAssertTrue(
            block.contains("store.flushPendingLogRecordCommit()"),
            "log-sheet scenePhase edge must flush the pending note commit (G4)"
        )
    }

    /// EDGE 4 — CalendarEventLogSheet editor onDisappear flushes on teardown.
    func testLogSheetOnDisappearFlushEdgeIsWired() throws {
        let block = try XCTUnwrap(
            balancedBlock(after: ".onDisappear", in: source(logSheetPath)),
            "log-sheet editor must have an onDisappear"
        )
        XCTAssertTrue(
            block.contains("store.flushPendingLogRecordCommit()"),
            "log-sheet onDisappear edge must flush the pending note commit (G4)"
        )
    }

    /// EDGE 5 — CalendarEventLogSheet Cancel button flushes BEFORE dismiss().
    /// The flush call must immediately precede the dismiss so a leave cannot
    /// race the pending note out of existence. The save()-path dismiss() (which
    /// commits synchronously itself) is not preceded by a flush, so this
    /// flush-then-dismiss pair is unique.
    func testLogSheetCancelPreDismissFlushEdgeIsWired() throws {
        let collapsed = collapsedCode(try source(logSheetPath))
        let occurrences = collapsed.components(separatedBy: "store.flushPendingLogRecordCommit() dismiss()").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "the Cancel button must flush the pending note immediately before dismiss() exactly once (G4)"
        )
    }

    // ------------------------------------------------------------------
    // MARK: - SOURCE-WIRING INVENTORY: only the note coalesces (G5/G6)
    // ------------------------------------------------------------------

    /// G5/G6 in the detail view: the free-text note onChange is the ONLY caller
    /// that passes `coalesced: true`; the template-pick and template-answer
    /// onChanges commit immediately. Kills the "a discrete field was routed
    /// through the debounce" mutant, which introduces a second `coalesced: true`.
    func testDetailViewOnlyNoteOnChangeCoalesces() throws {
        let src = try source(detailPath)
        let collapsed = collapsedCode(src)

        XCTAssertEqual(
            collapsed.components(separatedBy: "coalesced: true").count - 1, 1,
            "exactly one detail-view site may coalesce (the free-text note); any more violates G5"
        )
        let noteBlock = try XCTUnwrap(
            balancedBlock(after: ".onChange(of: detailNoteText)", in: src),
            "detail view must have a detailNoteText onChange"
        )
        XCTAssertTrue(
            noteBlock.contains("saveDetailNoteAndTemplate(coalesced: true)"),
            "the note onChange is the site that must coalesce"
        )
        // The two discrete onChanges must NOT coalesce.
        for marker in [".onChange(of: detailSelectedTemplateID)", ".onChange(of: detailTemplateAnswers.count)"] {
            let block = try XCTUnwrap(balancedBlock(after: marker, in: src), "missing \(marker)")
            XCTAssertFalse(
                block.contains("coalesced: true"),
                "\(marker) is a discrete pick and must commit immediately (G5)"
            )
        }
    }

    /// G5/G6 in the log sheet: `note` is the ONLY onChange that passes
    /// `coalesced: true`; the six discrete fields (completionStatus, effort,
    /// emotionIDs, behaviorIDs, selectedTemplateID, existingImages) commit
    /// immediately through the shared `save()`. Kills the "discrete field
    /// coalesced" mutant (which adds a second `coalesced: true`).
    func testLogSheetOnlyNoteOnChangeCoalesces() throws {
        let src = try source(logSheetPath)
        let collapsed = collapsedCode(src)

        XCTAssertEqual(
            collapsed.components(separatedBy: "coalesced: true").count - 1, 1,
            "exactly one log-sheet site may coalesce (the note); any more violates G5/G6"
        )
        let noteBlock = try XCTUnwrap(
            balancedBlock(after: ".onChange(of: note)", in: src),
            "log sheet must have a note onChange"
        )
        XCTAssertTrue(
            noteBlock.contains("save(coalesced: true)"),
            "the note onChange is the site that must coalesce"
        )
        for marker in [
            ".onChange(of: completionStatus)",
            ".onChange(of: effort)",
            ".onChange(of: emotionIDs)",
            ".onChange(of: behaviorIDs)",
            ".onChange(of: selectedTemplateID)",
            ".onChange(of: existingImages.count)",
        ] {
            let block = try XCTUnwrap(balancedBlock(after: marker, in: src), "missing \(marker)")
            XCTAssertFalse(
                block.contains("coalesced: true"),
                "\(marker) is a discrete tap and must stay immediate (G5/G6)"
            )
        }
    }
}
