//
//  CalendarDeltaLogRound3Tests.swift
//  DoneTests
//
//  gh#235 round 3. The blocking defect the durability lens found after round
//  2 had already established the read-side posture: a log that EXISTS but
//  will not read is `.io`, "not one byte moves", freeze and let the next
//  launch recover (A-F2).
//
//  There is one commit in the app that runs BEFORE `read` establishes that
//  readability — `EventStore.load()` calls `replayPendingRestoreIfNeeded()`
//  above `adopt(.calendarEvents, …)` — and it commits `.destructive`, which
//  clears the log. Its staleness test (`committedSeq(slot) == base`) reads
//  the very seq that an unreadable log left un-advanced. So the branch's own
//  new code deleted recoverable user edits, with no freeze and no banner.
//
//  The invariant these tests hold down:
//
//      `commit` never UNLINKS a calendar delta log whose records this
//      process has not read.
//

import XCTest
@testable import Done

@MainActor
final class CalendarDeltaLogRound3Tests: XCTestCase {
    private var location: EventStorageLocation!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDeltaLogRound3Tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        location = .isolated(name: suiteName)
        EventStorageLocation.destroy(location)
    }

    override func tearDown() {
        // Every test here leaves the log unreadable at some point; restore the
        // mode so the teardown can delete the directory and a failure cannot
        // leak an undeletable file into the next test.
        if let log = try? logURL() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: log.path)
        }
        EventStorageLocation.destroy(location)
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func event(_ index: Int, title: String? = nil) -> Event {
        let start = Self.epoch.addingTimeInterval(Double(index) * 3600)
        return Event(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            title: title ?? "event-\(index)",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
            createdAt: Self.epoch
        )
    }

    private func events(_ count: Int) -> [Event] { (0..<count).map { event($0) } }

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
    private func quarantineDirectory() throws -> URL {
        try directory().appendingPathComponent("quarantine", isDirectory: true)
    }
    private func manifestURL() throws -> URL {
        try directory().appendingPathComponent("manifest.json")
    }

    /// What `manifest.json` SAYS about `.calendarEvents`, decoded from the raw
    /// bytes. `nil` means there is no manifest file at all — which is a state
    /// one of the round-5 pins below deliberately starts from, and is not the
    /// same as a manifest that records nothing for this slot.
    private func manifestRecordOnDisk() throws -> StorageManifest.SlotRecord? {
        guard let data = try? Data(contentsOf: try manifestURL()) else { return nil }
        return try JSONDecoder().decode(StorageManifest.self, from: data)
            .slots[StorageSlot.calendarEvents.rawValue]
    }

    /// Delta-log record seqs, read from the RAW file rather than through the
    /// code under test — the fixture's sharpness must not be asserted with
    /// the same reader the defect lived in.
    private func rawRecordSeqs() throws -> [UInt64] {
        let data = try Data(contentsOf: try logURL())
        var segments = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        segments.removeLast()
        return try segments.filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(CalendarDeltaRecord.self, from: Data($0.utf8)).seq
        }
    }

    /// The primary checkpoint's header generation, likewise read raw.
    private func rawHeaderSeq() throws -> UInt64 {
        let data = try Data(contentsOf: try primaryURL())
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        let object = try JSONSerialization.jsonObject(with: data[data.startIndex..<newline])
        let seq = try XCTUnwrap((object as? [String: Any])?["seq"] as? NSNumber)
        return seq.uint64Value
    }

    private func quarantinedLogNames() throws -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: try quarantineDirectory().path)) ?? []
        return names.filter { $0.contains("deltalog") }
    }

    private func setLogReadable(_ readable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o644 : 0o000],
                                              ofItemAtPath: try logURL().path)
    }

    /// Mirrors `EventStore.RestoreRedoPayload`, deliberately as a separate
    /// declaration (same reason `EventStoreDurabilityTests` keeps its own).
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

    private func seqs(_ storage: DurableEventStorage) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: Self.restoreSlots.map { ($0.rawValue, storage.committedSeq($0)) })
    }

    /// The state the defect needs, built once: a checkpoint, one delta edit on
    /// top of it, an abandoned restore marker naming the CHECKPOINT's
    /// generation, and a log nothing can read.
    ///
    /// Returns the marker's `calendarEvents` payload (so a test can assert it
    /// did not win) plus the two numbers that have to hold still across the
    /// interrupted launch — read here, while the file is still readable,
    /// because a `chmod 000` file can be `stat`ed but not opened.
    @discardableResult
    private func seedUnreadableLogUnderAnAbandonedMarker() throws
    -> (markerRows: [Event], headerSeq: UInt64, logBytes: Int) {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)

        // The seqs a restore marker written RIGHT NOW would carry. Taken
        // before the delta edit on purpose: the append that follows advances
        // `committedSeq` in memory only (`noteCalendarGeneration` writes no
        // file), so the marker names the CHECKPOINT's generation while the log
        // stands one past it — which is the gap the replay's `== base` test
        // walks into. It stays the value the NEXT launch reads back because
        // this fixture leaves the log UNREADABLE: a launch that could read it
        // would take the tail through `reconcileManifestWithPrimaryHeaders`
        // (which also writes it to `manifest.json`), and the marker would be
        // stale on its own.
        let markerSeqs = seqs(storage)

        var edited = events(4)
        edited[0].title = "in the log, not in the checkpoint"
        let delta = try storage.commit(edited, to: .calendarEvents)
        XCTAssertEqual(delta.mode, .delta, "the fixture needs a live log")

        // Sharpness, from the raw bytes: the log stands on a generation the
        // durable manifest/header has never recorded. Without this gap the
        // replay would judge the marker stale on its own and the defect could
        // not fire at all.
        let headerSeq = try rawHeaderSeq()
        XCTAssertEqual(markerSeqs[StorageSlot.calendarEvents.rawValue], headerSeq,
                       "the marker must name the generation the next launch will read back")
        XCTAssertEqual(try rawRecordSeqs(), [headerSeq + 1],
                       "and the log must stand one generation ahead of it")

        let logBytes = try Data(contentsOf: try logURL()).count
        try setLogReadable(false)

        let markerRows = [event(9, title: "from the abandoned restore marker")]
        let marker = RestoreMarkerMirror(events: [], calendarEvents: markerRows,
                                         logs: [], feedback: [], todoLists: [],
                                         baseSeqs: markerSeqs)
        _ = try makeStorage().recordPendingWork(kind: "restore",
                                                payload: JSONEncoder().encode(marker))
        return (markerRows, headerSeq, logBytes)
    }

    private func logByteSize() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: try logURL().path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }

    // MARK: - The blocking defect

    /// The whole shape, through a real `EventStore` launch.
    ///
    /// Before the fix: the replay saw `committedSeq == base` (the reconcile
    /// could not read the log, so the seq never advanced), wrote the marker's
    /// array as a `.destructive` checkpoint, and `clearCalendarLog` unlinked
    /// the log — destroying the only copy of the user's un-checkpointed edit,
    /// with no freeze and no banner, before `read` had run at all.
    func testARestoreReplayNeverDestroysADeltaLogThisProcessCouldNotRead() throws {
        let seeded = try seedUnreadableLogUnderAnAbandonedMarker()

        let interrupted = makeStore()

        // 1. The bytes are still there, under their own name. Not unlinked,
        //    and not moved aside either: a file that is merely
        //    unreadable-right-now is the one case where moving it turns a
        //    transient failure into a permanent loss.
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path),
                      "the log must survive a restore replay that never managed to read it")
        XCTAssertEqual(try quarantinedLogNames(), [],
                       "and it must survive IN PLACE — quarantining it here would strand the "
                       + "edits in a support folder instead of folding them at the next launch")
        XCTAssertEqual(try logByteSize(), seeded.logBytes,
                       "whole, not truncated: `.io` means not one byte moves")

        // 2. The marker's array did not land, so nothing newer sits on top of
        //    the log's base generation. This is the half that makes the next
        //    launch able to FOLD the edits rather than merely able to find
        //    their bytes: a landed checkpoint would carry a newer seq, and
        //    `CalendarDeltaFold.plan` discards a log whose base is older
        //    (`.discardLog`, by generation) — so the bytes would survive and
        //    the edits would not.
        XCTAssertEqual(try rawHeaderSeq(), seeded.headerSeq,
                       "the checkpoint must not have advanced past the log's base")

        // 3. The repair is not thrown away: a replay that could not write
        //    keeps its marker.
        XCTAssertFalse(interrupted.storage.pendingWork(kind: "restore").isEmpty,
                       "a refused replay must keep its marker — it is the only thing that makes "
                       + "the interrupted restore repairable")
        XCTAssertTrue(interrupted.isSlotFrozen(.calendarEvents),
                      "and `read` still freezes the slot, which is what closes the export gates")

        // 4. The condition clears — the whole point of the `.io` posture — and
        //    the next launch folds the edits in. The marker is now correctly
        //    judged stale on this slot, because the reconcile can finally read
        //    the tail, so its array does NOT overwrite them.
        try setLogReadable(true)
        let healed = makeStore()
        XCTAssertFalse(healed.isSlotFrozen(.calendarEvents))
        XCTAssertEqual(healed.rawCalendarEvents.map(\.title),
                       ["in the log, not in the checkpoint", "event-1", "event-2", "event-3"],
                       "the un-checkpointed edit survives to the launch that can read it")
        XCTAssertFalse(healed.rawCalendarEvents.contains { $0.id == seeded.markerRows[0].id },
                       "and the abandoned marker's array does not win a slot that moved on")
    }

    /// The same invariant at the layer that enforces it, where the refusal is
    /// nameable. `commit` is the choke point on purpose: the restore replay is
    /// only one of its callers, and the two internal ones (legacy migration,
    /// backup promotion) are invisible to any `EventStore`-level branch.
    func testACommitIsRefusedWhileTheLogsGenerationIsUnproven() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        var edited = events(4)
        edited[0].title = "in the log, not in the checkpoint"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta)
        try setLogReadable(false)

        let headerBefore = try rawHeaderSeq()
        let cold = makeStorage()
        XCTAssertThrowsError(try cold.commit([event(9)], to: .calendarEvents, intent: .destructive)) {
            guard case StorageError.calendarLogGenerationUnproven = $0 else {
                return XCTFail("expected the round-3 refusal, got \($0)")
            }
        }
        XCTAssertEqual(try rawHeaderSeq(), headerBefore,
                       "refused BEFORE the encode and the rename — the primary is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path))

        // And it is a latch about THIS PROCESS, not a permanent verdict on the
        // file: a launch that can read the log commits normally.
        try setLogReadable(true)
        let healed = makeStorage()
        guard case .loaded = healed.read(.calendarEvents, as: Event.self) else {
            return XCTFail("a readable log must read")
        }
        XCTAssertNoThrow(try healed.commit(events(2), to: .calendarEvents, intent: .destructive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path),
                       "a log this process HAS read is cleared by its checkpoint, exactly as before")
    }

    /// The destructive primitive's own half of the invariant, and the one
    /// place it is observable: `wiped` is the deliberate exception to the
    /// `commit` refusal above, so a wipe is the only commit that reaches
    /// `clearCalendarLog` while the generation is unproven. It QUARANTINES
    /// rather than unlinks — the invariant is "never unlink an unread log",
    /// with no carve-out to remember — and the erase is still complete
    /// because `purgeAuxiliaryCopies` sweeps `quarantine/` for this slot in
    /// the same breath (`EventStore.clearAllLocalData` calls it right after
    /// each slot's write).
    ///
    /// The window this opens, stated rather than hoped away: a kill BETWEEN
    /// the wipe's write and its purge leaves the log in `quarantine/` instead
    /// of gone. It closes itself — `purgeAuxiliaryCopies` is idempotent and
    /// re-runs on every launch that reads a wiped envelope, which is how an
    /// interrupted wipe already finishes.
    func testAWipeStillErasesAnUnreadableLogCompletely() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        var edited = events(4)
        edited[0].title = "plaintext an erase must not leave behind"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta)
        try setLogReadable(false)

        let cold = makeStorage()
        // `wiped: true` is the deliberate exception to the refusal above: the
        // user asked for exactly these bytes to go.
        XCTAssertNoThrow(try cold.commit([Event](), to: .calendarEvents,
                                         wiped: true, intent: .destructive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path),
                       "a wipe is not refused by the round-3 guard")
        XCTAssertEqual(try quarantinedLogNames().count, 1,
                       "the clear that an unproven generation reaches MOVES the file; `commit` "
                       + "unlinking a log it never read is the invariant, wipe included")

        cold.purgeAuxiliaryCopies(for: .calendarEvents)
        XCTAssertEqual(try quarantinedLogNames(), [],
                       "and the quarantine hop leaves nothing behind: event plaintext surviving "
                       + "an erase would not be an erase")
    }

    /// The reconcile's own contract, stated where the round-2 fix put it: a
    /// log it CAN read still advances `committedSeq` past the header, which is
    /// what makes an abandoned marker stale by itself. Round 3 must not have
    /// bought its latch by weakening that.
    func testAReadableLogStillAdvancesTheCommittedSeqPastTheHeader() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        var edited = events(4)
        edited[0].title = "tail"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta)

        let cold = makeStorage()
        XCTAssertEqual(cold.committedSeq(.calendarEvents), try rawHeaderSeq() + 1,
                       "the log's tail is the second artifact that proves a committed generation")
    }

    // MARK: - Round 4: a read that keeps nothing

    /// gh#235 round 4. Round 3's latch is released by a successful read of the
    /// log — and the three reads are not equivalent. `persistedDominoStamp`
    /// opens the whole file, keeps ONE `Date` out of it and drops every row
    /// body; the records it "saw" are nowhere a user could get them back from.
    ///
    /// Worse, it is where it is: `EventStore.persist` passes
    /// `dominoStampToCommit(for:wiped:)` as an ARGUMENT to `storage.commit`,
    /// Swift evaluates arguments before the call, and the one cold caller of
    /// `persistedDominoStamp` is the restore replay — which asked
    /// `committedSeq(slot) == base` one statement earlier and got its answer
    /// from the seq an unreadable log had left un-advanced. So an `.io` that
    /// healed in the window between `DurableEventStorage.init` and
    /// `replayPendingRestoreIfNeeded` released the latch from INSIDE the
    /// commit the latch existed to refuse: the marker's `.destructive`
    /// checkpoint landed and `clearCalendarLog` unlinked the log. Measured
    /// before the fix, on this exact fixture: no throw, no log file, header
    /// seq 1 → 3 (so even bytes that had survived would be discarded by
    /// generation at the next `CalendarDeltaFold.plan`).
    ///
    /// Two halves, and the seq assertion is the sharp one — without it this
    /// test goes green the moment something merely re-latches, which is the
    /// wrong reason:
    ///
    ///   1. the read DID prove the generation (every read does now), so the
    ///      staleness test is right the next time anyone asks;
    ///   2. and it did NOT prove the records are safe to destroy, so the
    ///      round-3 refusal still stands and the bytes are still there.
    func testTheDominoStampProbeProvesTheGenerationWithoutReleasingTheLatch() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        var edited = events(4)
        edited[0].title = "in the log, not in the checkpoint"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta)

        // Raw, as the rest of this file does: the fixture's sharpness is not
        // asserted with the reader the defect lived in.
        let headerSeq = try rawHeaderSeq()
        XCTAssertEqual(try rawRecordSeqs(), [headerSeq + 1],
                       "the fixture needs the log standing one generation ahead of the checkpoint")

        try setLogReadable(false)
        let cold = makeStorage()
        XCTAssertEqual(cold.committedSeq(.calendarEvents), headerSeq,
                       "the reconcile could not read the log, so the seq the replay's `== base` "
                       + "test reads is the checkpoint header's — this is the stale answer")

        // The window: the `.io` heals between `init` and the replay.
        try setLogReadable(true)
        _ = cold.persistedDominoStamp()

        // 1. THE SHARP ONE. Every read proves the generation, including a
        //    probe that keeps nothing — so the next `committedSeq == base`
        //    question is answered from the log's tail, not the header.
        XCTAssertEqual(cold.committedSeq(.calendarEvents), headerSeq + 1,
                       "a read that released nothing must still move the seq the staleness test "
                       + "reads; without this assertion the three below go green as soon as "
                       + "anything re-latches, for the wrong reason")

        // 2. And the refusal stands, because this read kept no rows.
        XCTAssertThrowsError(try cold.commit([event(9)], to: .calendarEvents,
                                             intent: .destructive)) {
            guard case StorageError.calendarLogGenerationUnproven = $0 else {
                return XCTFail("expected the round-3 refusal, got \($0)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path),
                      "the un-checkpointed edit is still on disk, under its own name")
        XCTAssertEqual(try rawRecordSeqs(), [headerSeq + 1],
                       "whole, not truncated")
        XCTAssertEqual(try rawHeaderSeq(), headerSeq,
                       "and nothing newer landed on top of the log's base, so `plan` will FOLD "
                       + "these records rather than discard them by generation")
    }

    /// The other half of the same seam, so the fix cannot be "latch forever".
    /// A read that KEEPS the records — `read`'s fold — releases the latch on
    /// the same healed file, and the edits are served.
    func testTheFoldingReadStillReleasesTheLatchOnTheSameHealedLog() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        var edited = events(4)
        edited[0].title = "in the log, not in the checkpoint"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta)

        try setLogReadable(false)
        let cold = makeStorage()
        try setLogReadable(true)
        _ = cold.persistedDominoStamp()

        guard case .loaded(let envelope, _) = cold.read(.calendarEvents, as: Event.self) else {
            return XCTFail("a healed log must read")
        }
        XCTAssertEqual(envelope.rows.map(\.title).first, "in the log, not in the checkpoint",
                       "the fold serves the un-checkpointed edit")
        XCTAssertNoThrow(try cold.commit(events(2), to: .calendarEvents, intent: .destructive),
                         "and once the records are in the served array the refusal lifts")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path),
                       "a log whose records this process is SERVING is cleared by its checkpoint")
    }

    // MARK: - Round 4: the read trail names one file, not every slot

    /// RED LINE 6 — the telemetry must not lie, because it is the only thing
    /// the on-device A/B judges the 461x saving from.
    ///
    /// `deltaRecords=`/`deltaBytes=` describe ONE file. `read` resolves the
    /// calendar's log before the other slots are read, and the counters are
    /// not per-slot state, so with the ternary keyed on the counters ALONE
    /// every slot read after the calendar printed the CALENDAR's numbers
    /// under its own name: a device reader counting `deltaRecords=` saw one
    /// delta log per store multiplied by the number of slots. Replaces the
    /// round-3 QA witness that recorded the defect.
    func testTheReadTrailAttributesTheDeltaCountersToTheCalendarAlone() throws {
        let storage = makeStorage()
        // The later slots need primaries of their own, or they take the
        // `.fresh` path and never print a "read primary" line at all — and
        // the negative assertion below would hold vacuously.
        _ = try storage.commit([TodoList](), to: .todoLists, intent: .destructive)
        _ = try storage.commit([CalendarEventLogRecord](), to: .calendarEventLogRecords,
                               intent: .destructive)
        _ = try storage.commit(events(2), to: .calendarEvents, intent: .destructive)
        var edited = events(2)
        edited[0].title = "in the log"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta,
                       "the fixture needs a live log, or there are no counters to misattribute")

        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        _ = makeStore()

        let readLines = DiagnosticTrail.combinedText()
            .components(separatedBy: "\n")
            .filter { $0.contains("read primary seq=") }
        let foreign = readLines.filter { !$0.contains("slot=calendarEvents") }

        XCTAssertFalse(foreign.isEmpty,
                       "the rig must produce read lines for slots OTHER than the calendar, or "
                       + "the attribution assertion below proves nothing")
        XCTAssertTrue(readLines.contains { $0.contains("slot=calendarEvents")
                                           && $0.contains("deltaRecords=") },
                      "liveness: the slot that HAS the log must still carry the fields — without "
                      + "this the test would also pass with the counters deleted outright")
        XCTAssertEqual(foreign.filter { $0.contains("deltaRecords=") }, [],
                       "and no other slot may carry them: they name one file, not one read")
    }

    // MARK: - Round 5: who puts the manifest on disk

    /// gh#235 round 5. Round 4 made every successful read note the log's tail
    /// into the IN-MEMORY manifest, and put that note one step ahead of
    /// `reconcileManifestWithPrimaryHeaders`' own read of the record it is
    /// about to update. The reconcile asks `provenSeq > record.seq` and
    /// `!record.everCommitted` to decide whether `manifest.json` needs
    /// writing; the note had already made both false, so the slot was skipped,
    /// `changed` stayed false and `writeManifest()` was never reached — the
    /// durable manifest silently stopped being written by the one pass whose
    /// job that is. The independent QA pass caught it as a witness; this is
    /// the positive form that replaces those witnesses.
    ///
    /// Round 5 splits the two questions: `durable` (the record as it came off
    /// disk) decides whether to write, `record` (the in-memory one) is what
    /// gets written. So the tail reaches `manifest.json` AND is never walked
    /// backwards.
    func testTheReconcileWritesTheLogsTailThroughToTheDurableManifest() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        var edited = events(4)
        edited[0].title = "in the log, not in the checkpoint"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta)

        // Sharpness, raw: the append is in-memory-only by design, so the
        // durable manifest is one generation behind the log. Without that gap
        // the assertion after the cold launch would hold for free.
        let headerSeq = try rawHeaderSeq()
        XCTAssertEqual(try rawRecordSeqs(), [headerSeq + 1],
                       "the fixture needs the log standing one generation ahead of the checkpoint")
        XCTAssertEqual(try manifestRecordOnDisk()?.seq, headerSeq,
                       "and manifest.json standing at the checkpoint's, not the log's")

        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        let cold = makeStorage()

        XCTAssertEqual(cold.committedSeq(.calendarEvents), headerSeq + 1,
                       "the in-memory answer — which `noteCalendarLogRead` alone already gave, "
                       + "which is why this assertion cannot be the only one here")
        XCTAssertEqual(try manifestRecordOnDisk()?.seq, headerSeq + 1,
                       "and the DURABLE one: the reconcile still writes manifest.json for a "
                       + "generation the log's tail proved")
        XCTAssertTrue(DiagnosticTrail.combinedText()
                        .contains("manifest seq \(headerSeq) behind durable generation \(headerSeq + 1)"),
                      "with the forensic line naming both numbers — it is the only record that "
                      + "this pass, rather than some later commit, is what caught the file up")
    }

    /// The consequence the write above carries, and the reason it is a
    /// durability fix rather than tidiness: `everCommitted` is what makes a
    /// slot whose files have ALL vanished present as `.lostAfterManifest`
    /// (freeze plus banner) instead of `.fresh` (seedable — demo rows over the
    /// last trace of a real store). In the corner where the LOG is the only
    /// surviving proof the slot was ever committed, round 4 stopped that proof
    /// being written down at all.
    func testALogOnlyProofOfCommitIsWrittenThroughToTheDurableManifest() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        var edited = events(4)
        edited[0].title = "in the log, not in the checkpoint"
        XCTAssertEqual(try storage.commit(edited, to: .calendarEvents).mode, .delta)
        let tailSeq = try XCTUnwrap(try rawRecordSeqs().last)

        // The state `everMissing` exists for: primary, backup and manifest all
        // gone, the log the only artifact that remembers the slot committed.
        try FileManager.default.removeItem(at: try primaryURL())
        try? FileManager.default.removeItem(at: try directory()
            .appendingPathComponent(StorageSlot.calendarEvents.backupFilename))
        try FileManager.default.removeItem(at: try manifestURL())
        XCTAssertNil(try manifestRecordOnDisk(),
                     "the fixture starts from no manifest at all, or the backfill has nothing "
                     + "to backfill and the assertion below is vacuous")

        let cold = makeStorage()
        guard case .unreadable(.lostAfterManifest) = cold.read(.calendarEvents, as: Event.self) else {
            return XCTFail("a live log beside a vanished primary is `.lostAfterManifest` — "
                           + "round 2's half, which must not have moved")
        }

        let record = try XCTUnwrap(try manifestRecordOnDisk(),
                                   "the reconcile must have written manifest.json back")
        XCTAssertTrue(record.everCommitted,
                      "and written the proof DOWN: a LATER launch that also loses the log has "
                      + "only this to tell `.lostAfterManifest` from `.fresh`")
        XCTAssertEqual(record.seq, tailSeq,
                       "at the generation the log's tail proved, not zero")
    }
}
