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
        // before the delta edit on purpose: `noteCalendarGeneration` advances
        // the in-memory manifest on an append but never writes it out, so
        // this is exactly the value the NEXT launch reads back — and exactly
        // the value the replay's `== base` test compares against.
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
}
