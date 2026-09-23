//
//  CalendarDeltaLogQARound3Tests.swift
//  DoneTests
//
//  gh#235 round 3 — INDEPENDENT QA. Written without reusing
//  `CalendarDeltaLogRound3Tests`' fixtures: the rig is rebuilt here from the
//  product API (`EventStore`) rather than from `DurableEventStorage`, the
//  seqs are captured by this file, and the bytes are read by this file's own
//  raw decoders.
//
//  THE INVARIANT UNDER TEST
//  ------------------------
//      `commit` never UNLINKS a calendar delta log whose records this
//      process has not read.
//
//  Why it is not obvious: round 2 established the read-side posture — a log
//  that EXISTS but will not read is `.io`, "not one byte moves", freeze and
//  let the next launch recover (A-F2). `EventStore.load()` calls
//  `replayPendingRestoreIfNeeded()` ABOVE `adopt(.calendarEvents, …)`, so a
//  restore replay is the one commit in the app that runs before `read` has
//  established readability — and it commits `.destructive`, which clears the
//  log. Its staleness test (`committedSeq(slot) == base`) reads exactly the
//  seq an unreadable log leaves un-advanced, so it concludes "this slot never
//  moved" and overwrites it.
//
//  WHY THE POSITIVE CONTROL IS FIRST
//  ---------------------------------
//  Every assertion below is of the form "the destruction did NOT happen".
//  All of them pass trivially if the marker this file writes is not a marker
//  the replay would ever act on — a mis-shaped payload is discarded as
//  unreadable, and the log survives for the wrong reason. So the first test
//  proves the rig can destroy: the same mirror, the same `recordPendingWork`
//  call, a matching base, and the marker's array DOES win the slot.
//
//  "New store over the same directory" is the process-death idiom, as in the
//  sibling suites: no in-memory state crosses it, so an assertion after one
//  is an assertion about bytes on disk.
//

import XCTest
@testable import Done

@MainActor
final class CalendarDeltaLogQARound3Tests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDeltaLogQARound3Tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        // Every test here makes something unreadable at some point. Restore
        // the modes defensively or a failure leaks a file the next test's
        // teardown cannot delete.
        if let dir = try? location.directoryURL() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            let log = dir.appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: log.path)
            let quarantine = dir.appendingPathComponent("quarantine", isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: quarantine.path)) ?? [] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: quarantine.appendingPathComponent(name).path)
            }
        }
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSinceReferenceDate: 760_000_000)

    private func event(_ index: Int, title: String? = nil) -> Event {
        let start = Self.epoch.addingTimeInterval(Double(index) * 3600)
        return Event(
            id: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index))!,
            title: title ?? "qa3-\(index)",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
            createdAt: Self.epoch
        )
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private func makeStorage() -> DurableEventStorage {
        DurableEventStorage(location: location, legacyDefaults: nil, flagDefaults: defaults)
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

    private func logExists() throws -> Bool {
        FileManager.default.fileExists(atPath: try logURL().path)
    }

    /// `stat`, not `open` — a `chmod 000` file can be sized but not read.
    private func logByteSize() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: try logURL().path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }

    private func quarantinedLogNames() throws -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: try quarantineDirectory().path)) ?? []
        return names.filter { $0.contains("deltalog") }.sorted()
    }

    /// The primary envelope header's generation, decoded here rather than
    /// asked of the class under test.
    private func headerSeqOnDisk() throws -> UInt64 {
        let data = try Data(contentsOf: try primaryURL())
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        let object = try JSONSerialization.jsonObject(with: data[data.startIndex..<newline])
        return try XCTUnwrap((object as? [String: Any])?["seq"] as? NSNumber).uint64Value
    }

    private func recordSeqsOnDisk(at url: URL? = nil) throws -> [UInt64] {
        let data = try Data(contentsOf: url ?? (try logURL()))
        var segments = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        segments.removeLast()
        return try segments.filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(CalendarDeltaRecord.self, from: Data($0.utf8)).seq
        }
    }

    private func setLogReadable(_ readable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o644 : 0o000],
                                              ofItemAtPath: try logURL().path)
    }

    // MARK: - The restore marker, mirrored

    /// Mirrors `EventStore.RestoreRedoPayload` (private). Same idiom as
    /// `CalendarDeltaLogQATests` and `EventStoreDurabilityTests`; the positive
    /// control below is what proves the mirror is still faithful.
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

    private func currentSeqs(_ store: EventStore) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: Self.restoreSlots.map {
            ($0.rawValue, store.storage.committedSeq($0))
        })
    }

    @discardableResult
    private func writeMarker(_ store: EventStore, calendar: [Event],
                             baseSeqs: [String: UInt64]) throws -> URL {
        let marker = RestoreMarkerMirror(events: [], calendarEvents: calendar,
                                         logs: [], feedback: [], todoLists: [],
                                         baseSeqs: baseSeqs)
        return try store.storage.recordPendingWork(kind: "restore",
                                                   payload: JSONEncoder().encode(marker))
    }

    // MARK: - 0. Positive control

    /// THE RIG CAN DESTROY. Same mirror, same `recordPendingWork`, a base that
    /// still matches, and a readable slot: the abandoned marker's array
    /// overwrites the user's row at the next launch. Without this, every
    /// "the log survived" below could be a mis-shaped payload being discarded.
    func testPositiveControlAnAbandonedMarkerWithAMatchingBaseDoesOverwriteTheSlot() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "the user's own row"))
        store.flushCalendarDeltaCheckpoint()

        try writeMarker(store, calendar: [event(9, title: "the abandoned restore")],
                        baseSeqs: currentSeqs(store))

        let cold = makeStore()
        XCTAssertEqual(cold.rawCalendarEvents.map(\.title), ["the abandoned restore"],
                       "the marker this file writes must be one the replay actually acts on, "
                       + "or every negative assertion in this suite is vacuous")
        XCTAssertTrue(cold.storage.pendingWork(kind: "restore").isEmpty,
                      "a replay that fully landed clears its marker")
    }

    // MARK: - 1. The blocking invariant

    /// The defect, end to end, built from the product API.
    ///
    /// Shape: checkpoint → marker naming THAT generation → one delta edit on
    /// top of it → the log made unreadable → relaunch. Before the round-3
    /// fix, the replay judged the slot un-moved (the reconcile could not read
    /// the tail, so `committedSeq` stayed at the header's value), wrote the
    /// marker's array as a `.destructive` checkpoint, and the clear inside
    /// that checkpoint unlinked the log — the only copy of the user's
    /// un-checkpointed edit — with no freeze and no banner, before `read` had
    /// run at all.
    ///
    /// Two separate things have to hold, and only the first is about the
    /// FILE:
    ///   * the bytes are still there, in place and whole;
    ///   * no checkpoint landed on top of the log's base generation — a
    ///     landed one carries a newer seq, and `CalendarDeltaFold.plan`
    ///     discards a log whose base is older, so the bytes would survive and
    ///     the EDITS would not.
    func testARestoreReplayDoesNotUnlinkALogItCouldNotReadAndTheEditsStillFold() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "checkpointed"))
        store.flushCalendarDeltaCheckpoint()

        // Captured BEFORE the delta edit on purpose. An append advances the
        // in-memory manifest and never writes it out, so this is the value
        // the next launch reads back — and the value the replay's `== base`
        // test compares against.
        let markerSeqs = currentSeqs(store)

        store.addCalendarEvent(event(1, title: "only in the log"))
        XCTAssertGreaterThan(store.storage.calendarDeltaLogRecordCount, 0,
                             "the fixture needs a live log")

        // Sharpness, from the raw bytes: the log stands exactly one
        // generation ahead of anything durable. Without that gap the replay
        // would judge the marker stale by itself and the defect could not
        // fire, so a green run would mean nothing.
        let headerSeq = try headerSeqOnDisk()
        XCTAssertEqual(markerSeqs[StorageSlot.calendarEvents.rawValue], headerSeq,
                       "the marker must name the generation the next launch reads back")
        XCTAssertEqual(try recordSeqsOnDisk(), [headerSeq + 1],
                       "and the log must hold the generation that is NOT durable")
        let logBytes = try logByteSize()

        let decoy = event(9, title: "from the abandoned restore marker")
        try writeMarker(store, calendar: [decoy], baseSeqs: markerSeqs)
        try setLogReadable(false)

        let interrupted = makeStore()

        XCTAssertTrue(try logExists(),
                      "a restore replay unlinked a delta log this process had never read")
        XCTAssertEqual(try quarantinedLogNames(), [],
                       "and it must survive IN PLACE: moving a merely-unreadable-right-now file "
                       + "converts a transient failure into a permanent loss")
        XCTAssertEqual(try logByteSize(), logBytes, "whole, not truncated")
        XCTAssertEqual(try headerSeqOnDisk(), headerSeq,
                       "no checkpoint may land on top of the log's base — otherwise the bytes "
                       + "survive and the fold discards them by generation")
        XCTAssertFalse(interrupted.storage.pendingWork(kind: "restore").isEmpty,
                       "a refused replay keeps its marker; dropping it would turn a repairable "
                       + "half restore into a permanent one")
        XCTAssertTrue(interrupted.isSlotFrozen(.calendarEvents),
                      "and `read` still freezes the slot (A-F2), which closes the export gates")
        XCTAssertTrue(interrupted.rawCalendarEvents.isEmpty,
                      "a frozen slot presents as empty rather than as a shortened history")

        // The `.io` posture's whole point: the condition clears.
        try setLogReadable(true)
        let healed = makeStore()
        XCTAssertFalse(healed.isSlotFrozen(.calendarEvents))
        XCTAssertEqual(healed.rawCalendarEvents.map(\.title), ["checkpointed", "only in the log"],
                       "the un-checkpointed edit must reach the launch that can read it")
        XCTAssertFalse(healed.rawCalendarEvents.contains { $0.id == decoy.id },
                       "and the abandoned marker must not win a slot that moved on")
    }

    /// The same invariant one layer down, and on an intent the `EventStore`
    /// replay never uses. `.normal` is the ordinary drag/resize/tick save: it
    /// is refused too, before the encode and before the rename, so a caller
    /// that is NOT the restore replay cannot walk into the same destruction.
    ///
    /// Also pins the refusal's scope: it is a latch about THIS PROCESS, not a
    /// verdict on the file. A launch that can read the log commits normally
    /// and its checkpoint clears the log exactly as it did before round 3.
    func testAnOrdinaryCommitIsAlsoRefusedWhileTheGenerationIsUnprovenAndReleasesWhenItIsNot() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "checkpointed"))
        store.flushCalendarDeltaCheckpoint()
        store.addCalendarEvent(event(1, title: "only in the log"))
        XCTAssertGreaterThan(store.storage.calendarDeltaLogRecordCount, 0)
        let headerSeq = try headerSeqOnDisk()
        let logBytes = try logByteSize()
        try setLogReadable(false)

        let cold = makeStorage()
        XCTAssertThrowsError(try cold.commit([event(0), event(1)], to: .calendarEvents)) {
            guard case StorageError.calendarLogGenerationUnproven = $0 else {
                return XCTFail("expected the round-3 refusal, got \($0)")
            }
        }
        XCTAssertEqual(try headerSeqOnDisk(), headerSeq, "refused before the rename")
        XCTAssertTrue(try logExists())
        XCTAssertEqual(try logByteSize(), logBytes)
        XCTAssertEqual(try quarantinedLogNames(), [])

        try setLogReadable(true)
        let healed = makeStorage()
        guard case .loaded = healed.read(.calendarEvents, as: Event.self) else {
            return XCTFail("a readable log must read")
        }
        XCTAssertNoThrow(try healed.commit([event(0)], to: .calendarEvents, intent: .destructive))
        XCTAssertFalse(try logExists(),
                       "a log this process HAS read is still cleared by its checkpoint")
        XCTAssertEqual(try quarantinedLogNames(), [],
                       "and cleared means DELETED, not quarantined — the round-3 branch must not "
                       + "have turned every ordinary checkpoint into a quarantine hop")
    }

    // MARK: - 2. The destructive primitive, and the one exception

    /// `wiped` is the deliberate carve-out in `commit`, so a wipe is the only
    /// commit that reaches the clear while the generation is unproven — which
    /// makes it the only place the second layer is observable.
    ///
    /// Asserted harder than "a file is there": the quarantined copy must be
    /// the log's own BYTES. A quarantine that landed an empty or truncated
    /// file would satisfy a existence/count assertion and still have lost the
    /// records.
    func testAWipeMovesTheUnreadLogAsideWithItsBytesIntactAndThenSweepsIt() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "checkpointed"))
        store.flushCalendarDeltaCheckpoint()
        store.addCalendarEvent(event(1, title: "plaintext an erase must not leave behind"))
        XCTAssertGreaterThan(store.storage.calendarDeltaLogRecordCount, 0)
        let recordSeqs = try recordSeqsOnDisk()
        let logContents = try Data(contentsOf: try logURL())
        try setLogReadable(false)

        let cold = makeStorage()
        XCTAssertNoThrow(try cold.commit([Event](), to: .calendarEvents,
                                         wiped: true, intent: .destructive),
                         "a wipe is the user asking for exactly these bytes to go; it is not refused")
        XCTAssertFalse(try logExists(), "the live path is clear")

        let quarantined = try quarantinedLogNames()
        XCTAssertEqual(quarantined.count, 1,
                       "the clear an unproven generation reaches MOVES the file rather than "
                       + "unlinking it — the invariant has no wipe carve-out")
        let moved = try quarantineDirectory().appendingPathComponent(try XCTUnwrap(quarantined.first))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path)
        XCTAssertEqual(try Data(contentsOf: moved), logContents,
                       "and it moved the BYTES: a quarantine that landed an empty file would pass "
                       + "a count assertion and still have destroyed the records")
        XCTAssertEqual(try recordSeqsOnDisk(at: moved), recordSeqs)

        cold.purgeAuxiliaryCopies(for: .calendarEvents)
        XCTAssertEqual(try quarantinedLogNames(), [],
                       "event plaintext surviving an erase would not be an erase")
    }

    /// The product-level half of the same statement: `clearAllLocalData`
    /// writes the wipe and sweeps in the same breath, so the quarantine hop
    /// is invisible from outside and nothing is left behind.
    func testEraseAllLocalDataLeavesNoTraceOfAnUnreadableLog() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "checkpointed"))
        store.flushCalendarDeltaCheckpoint()
        store.addCalendarEvent(event(1, title: "plaintext an erase must not leave behind"))
        try setLogReadable(false)

        let erasing = makeStore()
        erasing.clearAllLocalData()

        XCTAssertFalse(try logExists())
        XCTAssertEqual(try quarantinedLogNames(), [])
        XCTAssertTrue(erasing.rawCalendarEvents.isEmpty)

        let cold = makeStore()
        XCTAssertTrue(cold.rawCalendarEvents.isEmpty, "and it stays erased across a launch")
        XCTAssertFalse(cold.isSlotFrozen(.calendarEvents),
                       "an erased slot is not a frozen one — the log is gone, so nothing re-freezes")
    }

    // MARK: - 3. Round-2 guarantees round 3 must not have bought its latch by weakening

    /// The reconcile still proves a generation from a log it CAN read. This
    /// is the mechanism that expires an abandoned marker without any of the
    /// round-3 machinery, and the round-3 rewrite of that function is exactly
    /// where it could have been dropped.
    func testAReadableLogStillAdvancesCommittedSeqPastTheHeader() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "checkpointed"))
        store.flushCalendarDeltaCheckpoint()
        store.addCalendarEvent(event(1, title: "only in the log"))

        let cold = makeStorage()
        XCTAssertEqual(cold.committedSeq(.calendarEvents), try headerSeqOnDisk() + 1)
    }

    /// An absent log is not an unknown generation. The latch must not fire on
    /// the overwhelmingly common shape — no log at all — or every ordinary
    /// launch would refuse its first calendar write.
    func testAStoreWithNoLogAtAllIsNeverRefused() throws {
        let storage = makeStorage()
        XCTAssertNoThrow(try storage.commit([event(0)], to: .calendarEvents, intent: .destructive))
        XCTAssertFalse(try logExists())

        let cold = makeStorage()
        XCTAssertNoThrow(try cold.commit([event(0), event(1)], to: .calendarEvents,
                                         intent: .destructive))
    }

    // MARK: - 4. ②a / ②b — the two one-line corrections
    //
    // SOURCE SCANS, declared weaker than behavioural tests in the
    // `StoreLookupScanGuardTests` idiom, and used here for the reason that
    // file states: the property is real and the behavioural route is closed.
    //
    // ②a's failing branch has no fixture. `CalendarDeltaLog.append` opens its
    // own `FileHandle` with no injection seam, and `FileHandle.synchronize()`
    // is a plain `fsync(2)` — which, on every file type this process can put
    // at that path, either succeeds or is unreachable before the call (a FIFO
    // fails the `lseek` first; `/dev/null` fsyncs successfully — measured,
    // not assumed). So the posture is pinned at the source, and the honest
    // statement of what that buys is: it catches the revert, not a wrong
    // catch body.

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static let deltaLogPath = "Done/Services/Storage/CalendarDeltaLog.swift"
    private static let storagePath = "Done/Services/Storage/DurableEventStorage.swift"

    /// ②a. A failing `fsync` on the append path must leave a trail line.
    ///
    /// `try?` dropped the error while `syncMs` went on being measured AROUND
    /// it, so a failing `fsync` entered the receipt and the device trail
    /// wearing the shape of a measured SUCCESS — on `syncMs`, one of the
    /// three fields the on-device A/B reads (RED LINE 6). It was also the
    /// only silent failure left in that file.
    func testTheDeltaAppendsFsyncFailureIsTrailedRatherThanSwallowed() throws {
        let swallowing = try NSRegularExpression(pattern: #"try\?\s*\w+\.synchronize\(\)"#)
        func swallowCount(_ text: String) -> Int {
            swallowing.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }

        // LIVENESS: the scanner can see the shape it is looking for. Without
        // this, a typo in the pattern reads as a clean file.
        XCTAssertEqual(swallowCount("            try? handle.synchronize()\n"), 1,
                       "positive control: the pattern must recognize the swallowing spelling")

        let log = try source(Self.deltaLogPath)
        let storage = try source(Self.storagePath)
        XCTAssertGreaterThan(log.count, 10_000, "liveness: the scan reached the real file")

        XCTAssertEqual(swallowCount(log), 0,
                       "\(Self.deltaLogPath): a swallowed fsync here is measured by `syncMs` and "
                       + "reported as a success it never was")

        // `DurableEventStorage` has two sites that PREDATE gh#235 — the
        // Domino heartbeat and the pending-work marker (both present at the
        // branch's merge-base). Neither is bracketed by a measurement, so
        // neither can make a receipt or the device A/B lie, which is what
        // ②a is about; they are untrailed all the same, and that is recorded
        // rather than asserted away. The count is pinned so a THIRD one
        // cannot be added silently.
        XCTAssertEqual(swallowCount(storage), 2,
                       "\(Self.storagePath): the two pre-gh#235 swallowed fsyncs "
                       + "(`writeDominoHeartbeat`, `recordPendingWork`) are the whole allowlist — "
                       + "a new one, or one of these fixed, must be looked at deliberately")

        // Both MEASURED fsync sites say the same thing, so one grep finds
        // both — the property the round-3 comment claims for its wording.
        let wording = "fsync failed (continuing)"
        XCTAssertTrue(log.contains(wording),
                      "the delta append's fsync must trail with the checkpoint path's wording")
        XCTAssertTrue(storage.contains(wording),
                      "liveness: the checkpoint path's line is the one being matched")
    }

    /// ②b (RED LINE 7). The `duplicateBaseID` fallback is data-SAFE, not a
    /// repair: a checkpoint writes the array it was HANDED and re-installs it
    /// through a rescan, so a surviving duplicate re-sets the flag and the
    /// delta path stays closed. The behaviour is pinned first, the corrected
    /// comment second.
    func testTheDuplicateBaseFallbackIsNotARepairAndTheCommentNoLongerClaimsItIs() throws {
        let storage = makeStorage()
        var rows = [event(0), event(1)]
        rows.append(event(1, title: "a second row with the same id"))
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)

        // Three consecutive ORDINARY saves. Each is eligible for the delta
        // path on every ground but the duplicate; each must fall back.
        for pass in 0..<3 {
            rows[0].title = "edit \(pass)"
            let receipt = try storage.commit(rows, to: .calendarEvents)
            XCTAssertEqual(receipt.mode, .checkpoint, "save \(pass) took the delta path")
            XCTAssertEqual(receipt.reason, "duplicateBaseID", "save \(pass) fell back for another reason")
        }
        XCTAssertEqual(rows.count, 3, "and the duplicate is still there — nothing repaired it")
        XCTAssertFalse(try logExists(), "a permanently-checkpointing store never opens a log")

        // RED LINE 7. The false half is gone AS A CLAIM. It survives exactly
        // once, quoted inside the correction that names it false — which is
        // the right way to retire a load-bearing comment, and is why this is
        // an occurrence count rather than a `contains == false`.
        let text = try source(Self.storagePath)
        XCTAssertTrue(text.contains("duplicateBaseID"),
                      "liveness: the scan reached the guard this is about")
        XCTAssertEqual(text.components(separatedBy: "re-establishes a clean base").count - 1, 1,
                       "the old claim may appear only where the correction quotes it")
        XCTAssertTrue(text.contains("This used to read")
                      && text.contains("The second half was false"),
                      "…and the one occurrence must BE that correction")
        XCTAssertTrue(text.contains("data-SAFE, not a\n        // repair"),
                      "RED LINE 7: the comment has to state what actually happens — a rescan in "
                      + "`installPersistedCalendarRows` re-sets the flag, so the fallback is not "
                      + "a repair")
        XCTAssertTrue(text.contains("EVERY save is a") && text.contains("~2 MB encode plus write"),
                      "and the standing cost the fallback carries, which is the part that was "
                      + "under-estimated")
    }

    // MARK: - 5. WITNESS — the other branch of the same stale seq (open gap)
    //
    // NOT a regression test for a fix. This records, reproducibly, a gap the
    // round-3 fix leaves open, so the decision about it is taken on evidence
    // rather than re-derived later. Update it WITH the fix, not around it.
    //
    // The blocking defect round 3 closed was: the restore replay's staleness
    // test, `committedSeq(slot) == base`, read a seq that an unreadable log
    // had left un-advanced, concluded "this slot never moved", and destroyed
    // the log. Round 3 latched the fact that the seq may be stale
    // (`calendarLogGenerationUnproven`) and taught `commit` to refuse on it.
    //
    // `replayPendingRestoreIfNeeded` was NOT taught anything. It still reads
    // that same seq — and its OTHER branch, `!=`, concludes the opposite:
    // "this slot moved on, the marker no longer speaks for it". That branch
    // costs no user bytes (the local calendar is intact and its deltas fold
    // at the next launch), but the four slots that DID replay set `wrote =
    // true`, so the marker is cleared and the interrupted restore's calendar
    // half is discarded permanently — after ONE launch that merely could not
    // read a file.
    //
    // The control is `CalendarDeltaLogQATests`'
    // `testAMarkerWrittenAfterDeltaEditsStillRepairsAnInterruptedRestore`:
    // identical fixture with a READABLE log, and there the restore lands.

    func testWITNESSOneUnreadableLaunchDiscardsAnInterruptedRestoresCalendarHalf() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "checkpointed"))
        store.flushCalendarDeltaCheckpoint()
        store.addCalendarEvent(event(1, title: "only in the log"))
        XCTAssertGreaterThan(store.storage.calendarDeltaLogRecordCount, 0)

        // Written AFTER the delta edits, so the base names the FOLDED
        // generation — the shape the control test says must still repair.
        let headerSeq = try headerSeqOnDisk()
        let seqs = currentSeqs(store)
        XCTAssertEqual(seqs[StorageSlot.calendarEvents.rawValue], headerSeq + 1,
                       "the marker's base must stand on the log's tail, or this is a different case")
        try writeMarker(store, calendar: [event(9, title: "restored")], baseSeqs: seqs)

        try setLogReadable(false)
        let interrupted = makeStore()
        XCTAssertTrue(interrupted.isSlotFrozen(.calendarEvents))
        XCTAssertTrue(try logExists(), "round 3 holds: the log itself is not destroyed")

        // CURRENT BEHAVIOUR, witnessed rather than endorsed. The replay judged
        // the calendar slot "moved on" from a seq it had just failed to prove,
        // skipped it, replayed the other four, and cleared the marker on the
        // strength of those four.
        XCTAssertTrue(interrupted.storage.pendingWork(kind: "restore").isEmpty,
                      "WITNESS: if this goes green-to-red, the gap was closed — keep the marker "
                      + "while the calendar's generation is unproven and delete this test")

        try setLogReadable(true)
        let healed = makeStore()
        XCTAssertFalse(healed.isSlotFrozen(.calendarEvents))
        XCTAssertEqual(healed.rawCalendarEvents.map(\.title), ["checkpointed", "only in the log"],
                       "no user bytes are lost — the deltas fold as round 3 guarantees")
        XCTAssertFalse(healed.rawCalendarEvents.contains { $0.title == "restored" },
                       "WITNESS: and the interrupted restore is gone for good. The control "
                       + "(`testAMarkerWrittenAfterDeltaEditsStillRepairsAnInterruptedRestore`, "
                       + "same fixture, readable log) lands `restored` here")
        XCTAssertTrue(healed.storage.pendingWork(kind: "restore").isEmpty)
    }
}
