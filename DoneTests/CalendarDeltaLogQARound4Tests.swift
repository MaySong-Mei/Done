//
//  CalendarDeltaLogQARound4Tests.swift
//  DoneTests
//
//  gh#235 round 4 — INDEPENDENT QA. The probe below is rebuilt here rather
//  than taken from `CalendarDeltaLogRound3Tests`' round-4 section: its own
//  epoch, its own UUID namespace, its own raw byte decoders, and — for the
//  central one — its own call SHAPE, because the shape is the defect.
//
//  THE DEFECT ROUND 4 CLOSES
//  -------------------------
//  Round 3 latched "this process has never read the calendar delta log" and
//  taught `commit` to refuse a `.destructive` checkpoint while the latch
//  stands. Three sites released that latch, and one of them runs INSIDE the
//  commit it is supposed to refuse:
//
//      EventStore.persist  ->  storage.commit(rows, to: slot,
//                                             dominoLastPush: dominoStampToCommit(...), ...)
//
//  Swift evaluates the argument before the call, `dominoStampToCommit` calls
//  `storage.persistedDominoStamp()`, and that function's cold path reads the
//  whole delta log. So a log that was unreadable at `DurableEventStorage.init`
//  (first-unlock protection class, transient EIO) and readable a millisecond
//  later released the latch from inside the restore replay's own commit — and
//  `clearCalendarLog` then UNLINKED it.
//
//  TWO INDEPENDENT FACTS HAVE TO HOLD, AND THEY FAIL SEPARATELY
//  ------------------------------------------------------------
//    * the read must MOVE the generation `committedSeq` answers from, or the
//      next staleness question is still answered from the checkpoint header;
//    * the read must NOT release the latch, because it keeps one `Date` and
//      drops every row body — nothing it read is anywhere a user could get
//      back.
//
//  The first is asserted by exactly one assertion in each probe below, and it
//  is load-bearing: without it the remaining assertions go green the moment
//  ANYTHING re-latches — including a mutation that stops the probe reading the
//  log at all. `testQAControlTheHealAloneDoesNotMoveTheSeq` is the positive
//  control that makes it a statement about the probe rather than about the
//  chmod.
//

import XCTest
@testable import Done

@MainActor
final class CalendarDeltaLogQARound4Tests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDeltaLogQARound4Tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        // Every probe here makes the log unreadable at some point; restore the
        // mode defensively or a failure leaks a file the next teardown cannot
        // delete.
        if let dir = try? location.directoryURL() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            let log = dir.appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: log.path)
        }
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    // MARK: - Fixtures (this file's own)

    private static let epoch = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func event(_ index: Int, title: String? = nil) -> Event {
        let start = Self.epoch.addingTimeInterval(Double(index) * 3600)
        return Event(
            id: UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", index))!,
            title: title ?? "qa4-\(index)",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
            createdAt: Self.epoch
        )
    }

    private func makeStorage() -> DurableEventStorage {
        DurableEventStorage(location: location, legacyDefaults: nil, flagDefaults: defaults)
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private func directory() throws -> URL { try location.directoryURL() }
    private func primaryURL() throws -> URL {
        try directory().appendingPathComponent(StorageSlot.calendarEvents.filename)
    }
    private func logURL() throws -> URL {
        try directory().appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
    }

    /// The checkpoint header's generation, decoded from the raw bytes by this
    /// file — never asked of the class the defect lived in.
    private func headerSeqOnDisk() throws -> UInt64 {
        let data = try Data(contentsOf: try primaryURL())
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        let object = try JSONSerialization.jsonObject(with: data[data.startIndex..<newline])
        return try XCTUnwrap((object as? [String: Any])?["seq"] as? NSNumber).uint64Value
    }

    private func recordSeqsOnDisk() throws -> [UInt64] {
        let data = try Data(contentsOf: try logURL())
        var segments = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        segments.removeLast()
        return try segments.filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(CalendarDeltaRecord.self, from: Data($0.utf8)).seq
        }
    }

    private func logExists() throws -> Bool {
        FileManager.default.fileExists(atPath: try logURL().path)
    }

    /// `stat`, not `open`: a `chmod 000` file can be sized but not read.
    private func logByteSize() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: try logURL().path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }

    private func setLogReadable(_ readable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o644 : 0o000],
                                              ofItemAtPath: try logURL().path)
    }

    /// checkpoint + ONE delta edit on top of it, then the log made unreadable.
    /// Returns the two raw numbers the probes reason from, read while the file
    /// is still openable.
    @discardableResult
    private func seedCheckpointPlusOneUnreadableDelta() throws -> (headerSeq: UInt64, logBytes: Int) {
        let storage = makeStorage()
        _ = try storage.commit((0..<4).map { event($0) }, to: .calendarEvents, intent: .destructive)
        var edited = (0..<4).map { event($0) }
        edited[0].title = "in the log, not in the checkpoint"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta,
                       "the fixture needs a LIVE delta log, or there is nothing to destroy")

        let headerSeq = try headerSeqOnDisk()
        XCTAssertEqual(try recordSeqsOnDisk(), [headerSeq + 1],
                       "and it must stand exactly one generation ahead of the checkpoint, or the "
                       + "replay would judge the marker stale without any of this mattering")
        let bytes = try logByteSize()
        try setLogReadable(false)
        return (headerSeq, bytes)
    }

    // MARK: - 0. Positive control

    /// THE SEQ ASSERTION IS ABOUT THE PROBE, NOT ABOUT THE chmod.
    ///
    /// Same fixture, same heal, and the probe simply not called: the seq must
    /// STAY stale. Without this, `committedSeq == headerSeq + 1` in the probes
    /// below could be something `makeStorage()` or `setLogReadable(true)` did
    /// on its own, and the sharp assertion would be measuring the rig.
    func testQAControlTheHealAloneDoesNotMoveTheSeq() throws {
        let seeded = try seedCheckpointPlusOneUnreadableDelta()

        let cold = makeStorage()
        XCTAssertEqual(cold.committedSeq(.calendarEvents), seeded.headerSeq,
                       "the reconcile could not open the log, so the seq the restore replay's "
                       + "`committedSeq(slot) == base` test reads is the checkpoint header's")

        try setLogReadable(true)
        XCTAssertEqual(cold.committedSeq(.calendarEvents), seeded.headerSeq,
                       "healing the file changes nothing by itself — only a READ can move the "
                       + "generation, which is what makes the probes' seq assertion a statement "
                       + "about `persistedDominoStamp`")
    }

    // MARK: - 1. The probe, rebuilt

    /// The blocking defect, at the layer that can be pinned.
    ///
    /// chmod 000 -> build the storage (latch, stale seq) -> chmod 644 (the
    /// `.io` heals inside the window) -> `persistedDominoStamp()` -> a
    /// `.destructive` commit. Before round 4 this commit did NOT throw, the
    /// log was unlinked, and the primary header advanced a generation — so
    /// even bytes that had somehow survived would be discarded by
    /// `CalendarDeltaFold.plan` at the next launch.
    func testTheDominoProbeMovesTheStalenessSeqAndStillRefusesToUnlinkTheLog() throws {
        let seeded = try seedCheckpointPlusOneUnreadableDelta()

        let cold = makeStorage()
        XCTAssertEqual(cold.committedSeq(.calendarEvents), seeded.headerSeq,
                       "the stale answer the replay would act on")

        try setLogReadable(true)
        _ = cold.persistedDominoStamp()

        // THE SHARP ONE. Everything below it is of the form "the destruction
        // did not happen", and all of it passes for the wrong reason the
        // moment something merely re-latches — a probe that stopped reading
        // the log at all included. This is the only assertion that says the
        // read HAPPENED and left the staleness question answerable.
        XCTAssertEqual(cold.committedSeq(.calendarEvents), seeded.headerSeq + 1,
                       "a read that released nothing must still move the seq `committedSeq == base` "
                       + "reads — this is the assertion that distinguishes 'the probe read and "
                       + "kept its hands off the latch' from 'the probe never read'")

        XCTAssertThrowsError(try cold.commit([event(9)], to: .calendarEvents,
                                             intent: .destructive)) {
            guard case StorageError.calendarLogGenerationUnproven = $0 else {
                return XCTFail("expected the round-3 refusal, got \($0)")
            }
        }
        XCTAssertTrue(try logExists(),
                      "the only copy of the un-checkpointed edit is still on disk, under its own name")
        XCTAssertEqual(try logByteSize(), seeded.logBytes, "whole, not truncated")
        XCTAssertEqual(try recordSeqsOnDisk(), [seeded.headerSeq + 1])
        XCTAssertEqual(try headerSeqOnDisk(), seeded.headerSeq,
                       "and nothing newer landed on the log's base, so `plan` will FOLD rather "
                       + "than `.discardLog` by generation")
    }

    /// THE CALL SHAPE IS THE DEFECT, so this probe reproduces the shape rather
    /// than the sequence: `EventStore.persist` passes the stamp as an ARGUMENT
    /// to `storage.commit`, and Swift evaluates arguments before the call. One
    /// expression, the read and the commit inseparable — the form in which
    /// round 3's refusal was a no-op.
    func testTheRefusalHoldsWhenTheProbeIsEvaluatedAsAnArgumentToTheCommitItself() throws {
        let seeded = try seedCheckpointPlusOneUnreadableDelta()

        let cold = makeStorage()
        // The staleness question, asked and answered BEFORE the commit — the
        // ordering `EventStore.replayPendingRestoreIfNeeded` has (`guard
        // needsReplay(slot)` sits one statement above `persist`).
        XCTAssertEqual(cold.committedSeq(.calendarEvents), seeded.headerSeq)
        try setLogReadable(true)

        XCTAssertThrowsError(
            try cold.commit([event(9)], to: .calendarEvents,
                            dominoLastPush: cold.persistedDominoStamp(),
                            intent: .destructive)
        ) {
            guard case StorageError.calendarLogGenerationUnproven = $0 else {
                return XCTFail("expected the round-3 refusal, got \($0)")
            }
        }
        XCTAssertTrue(try logExists(),
                      "the argument evaluation read the log; it must not have bought the call "
                      + "the right to delete it")
        XCTAssertEqual(try logByteSize(), seeded.logBytes)
        XCTAssertEqual(try headerSeqOnDisk(), seeded.headerSeq)
        // And the read inside the argument list still proved the generation.
        XCTAssertEqual(cold.committedSeq(.calendarEvents), seeded.headerSeq + 1,
                       "the sharp assertion, in the shape the app actually uses")
    }

    /// The latch is not "forever": a read that KEEPS the records releases it,
    /// on the same healed file, in the same process that was just refused.
    /// Without this pair the round-4 fix could be "never release" — which
    /// would strand every delta log on disk and silently retire the 461x
    /// saving the whole branch exists for.
    func testAServingReadReleasesTheLatchTheProbeDidNot() throws {
        let seeded = try seedCheckpointPlusOneUnreadableDelta()

        let cold = makeStorage()
        try setLogReadable(true)
        _ = cold.persistedDominoStamp()
        XCTAssertThrowsError(try cold.commit([event(9)], to: .calendarEvents, intent: .destructive))

        guard case .loaded(let envelope, _) = cold.read(.calendarEvents, as: Event.self) else {
            return XCTFail("a healed log must read")
        }
        XCTAssertEqual(envelope.rows.first?.title, "in the log, not in the checkpoint",
                       "the fold SERVES the un-checkpointed edit — which is the reason this read "
                       + "may license the clear")
        XCTAssertNoThrow(try cold.commit((0..<2).map { event($0) }, to: .calendarEvents,
                                         intent: .destructive))
        XCTAssertFalse(try logExists(),
                       "a log whose records this process is serving IS cleared by its checkpoint")
        XCTAssertGreaterThan(try headerSeqOnDisk(), seeded.headerSeq)
    }

    // MARK: - 2. End to end, through the product API

    /// The consequence, stated where a user would feel it: the interrupted
    /// restore's marker is still on disk, the calendar edit is still in the
    /// log, and the launch that can finally read the log folds the edit in and
    /// does NOT let the abandoned marker's array win.
    ///
    /// Built from `EventStore` only — no `DurableEventStorage` fixture — so it
    /// holds the outcome rather than the mechanism.
    ///
    /// SCOPE, so a green here is not read as more than it is: this is a
    /// CONTAINMENT test on the behaviour AROUND the round-4 defect, not a
    /// reproduction of it. It passes with that defect present. The log stays
    /// unreadable for the whole interrupted launch here, and the defect
    /// needed the `.io` to HEAL between `DurableEventStorage.init` and
    /// `replayPendingRestoreIfNeeded` for `persistedDominoStamp` to release
    /// the latch mid-replay. The reproduction is
    /// `testTheRefusalHoldsWhenTheProbeIsEvaluatedAsAnArgumentToTheCommitItself`.
    func testTheInterruptedRestoreLaunchLeavesTheEditRecoverableEndToEnd() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "checkpointed"))
        store.flushCalendarDeltaCheckpoint()

        let baseSeqs = Dictionary(uniqueKeysWithValues: Self.restoreSlots.map {
            ($0.rawValue, store.storage.committedSeq($0))
        })

        store.addCalendarEvent(event(1, title: "in the log, not in the checkpoint"))
        XCTAssertEqual(try recordSeqsOnDisk().count, 1, "the fixture needs a live log")
        let headerSeq = try headerSeqOnDisk()
        let logBytes = try logByteSize()

        let marker = RestoreMarkerMirror(events: [], calendarEvents: [event(9, title: "abandoned restore")],
                                         logs: [], feedback: [], todoLists: [], baseSeqs: baseSeqs)
        _ = try store.storage.recordPendingWork(kind: "restore",
                                                payload: JSONEncoder().encode(marker))
        try setLogReadable(false)

        let interrupted = makeStore()
        XCTAssertTrue(try logExists(), "the unread log survives the replay")
        XCTAssertEqual(try logByteSize(), logBytes, "in place and whole")
        XCTAssertEqual(try headerSeqOnDisk(), headerSeq,
                       "and no checkpoint landed on top of its base generation")
        XCTAssertFalse(interrupted.storage.pendingWork(kind: "restore").isEmpty,
                       "the repair is kept — a refused replay keeps its marker")

        try setLogReadable(true)
        let healed = makeStore()
        XCTAssertFalse(healed.isSlotFrozen(.calendarEvents))
        XCTAssertTrue(healed.rawCalendarEvents.contains { $0.title == "in the log, not in the checkpoint" },
                      "the un-checkpointed edit survives to the launch that can read it")
        XCTAssertFalse(healed.rawCalendarEvents.contains { $0.title == "abandoned restore" },
                       "and the abandoned marker does not win a slot that moved on")
    }

    /// Mirrors `EventStore.RestoreRedoPayload` (private), the same idiom the
    /// sibling suites use. The end-to-end test above is its own faithfulness
    /// check in one direction (a marker the replay ignores would leave the log
    /// alone for the wrong reason), so the control below closes the other.
    private struct RestoreMarkerMirror: Codable {
        var events: [Event]
        var calendarEvents: [Event]
        var logs: [CalendarEventLogRecord]
        var feedback: [CalendarEventFeedbackRecord]
        var todoLists: [TodoList]
        var baseSeqs: [String: UInt64]
    }

    private static let restoreSlots: [StorageSlot] = [
        .events, .calendarEvents, .calendarEventLogRecords,
        .calendarEventFeedbackRecords, .todoLists,
    ]

    /// THE RIG CAN DESTROY. Same mirror, same `recordPendingWork`, a matching
    /// base and a readable slot: the marker's array DOES overwrite the user's
    /// row. Without it every negative assertion above could be a mis-shaped
    /// payload being discarded as unreadable.
    func testQAControlAnAbandonedMarkerWithAMatchingBaseDoesOverwriteTheSlot() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "the user's own row"))
        store.flushCalendarDeltaCheckpoint()

        let marker = RestoreMarkerMirror(
            events: [], calendarEvents: [event(9, title: "abandoned restore")],
            logs: [], feedback: [], todoLists: [],
            baseSeqs: Dictionary(uniqueKeysWithValues: Self.restoreSlots.map {
                ($0.rawValue, store.storage.committedSeq($0))
            }))
        _ = try store.storage.recordPendingWork(kind: "restore",
                                                payload: JSONEncoder().encode(marker))

        let cold = makeStore()
        XCTAssertEqual(cold.rawCalendarEvents.map(\.title), ["abandoned restore"],
                       "the marker this file writes must be one the replay acts on, or every "
                       + "negative assertion in this suite is vacuous")
    }

    // MARK: - 3. RED LINE 6 — the read trail names one file

    /// `deltaRecords=`/`deltaBytes=` describe ONE file. `read` resolves the
    /// calendar's log before the other slots are read and the counters are not
    /// per-slot state, so without a `slot == .calendarEvents` guard every slot
    /// read AFTER the calendar carried the calendar's numbers under its own
    /// name — a device reader counting `deltaRecords=` saw one delta log per
    /// slot instead of one per store, and red line 6 is the only basis the
    /// on-device A/B has for judging the 461x claim.
    func testTheDeltaCountersAppearOnTheCalendarsReadLineAndNowhereElse() throws {
        let storage = makeStorage()
        // Other slots need primaries of their own or they take `.fresh` and
        // never print a "read primary" line — which would make the negative
        // assertion below vacuously true.
        _ = try storage.commit([TodoList](), to: .todoLists, intent: .destructive)
        _ = try storage.commit([CalendarEventLogRecord](), to: .calendarEventLogRecords,
                               intent: .destructive)
        _ = try storage.commit([CalendarEventFeedbackRecord](), to: .calendarEventFeedbackRecords,
                               intent: .destructive)
        _ = try storage.commit((0..<2).map { event($0) }, to: .calendarEvents, intent: .destructive)
        var edited = (0..<2).map { event($0) }
        edited[0].title = "in the log"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta,
                       "a live log, or there are no counters to misattribute")

        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        _ = makeStore()

        let readLines = DiagnosticTrail.combinedText()
            .components(separatedBy: "\n")
            .filter { $0.contains("read primary seq=") }
        let foreign = readLines.filter { !$0.contains("slot=\(StorageSlot.calendarEvents.rawValue)") }

        XCTAssertGreaterThanOrEqual(foreign.count, 2,
                                    "non-vacuity: the rig must produce read lines for slots other "
                                    + "than the calendar, got \(readLines)")
        XCTAssertTrue(readLines.contains { $0.contains("slot=\(StorageSlot.calendarEvents.rawValue)")
                                           && $0.contains("deltaRecords=") },
                      "liveness: the slot that HAS the log still carries the fields — without this "
                      + "the test would also pass with the counters deleted outright")
        XCTAssertEqual(foreign.filter { $0.contains("deltaRecords=") || $0.contains("deltaBytes=") }, [],
                       "and no other slot may carry them: they name one file, not one read")
    }
}
