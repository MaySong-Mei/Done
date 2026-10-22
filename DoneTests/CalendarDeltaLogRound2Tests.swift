//
//  CalendarDeltaLogRound2Tests.swift
//  DoneTests
//
//  gh#235 round 2. One test per defect the two independent `against` passes
//  found, each written so that REVERTING its fix turns it red — the fix is
//  the only thing standing between the assertion and a failure.
//
//  Kept in its own file rather than folded into `CalendarDeltaLogTests` so
//  the round-2 population is greppable: these are the cases round 1 shipped
//  green without.
//

import XCTest
@testable import Done

@MainActor
final class CalendarDeltaLogRound2Tests: XCTestCase {
    private var location: EventStorageLocation!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDeltaLogRound2Tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        location = .isolated(name: suiteName)
        EventStorageLocation.destroy(location)
    }

    override func tearDown() {
        // Several tests here deliberately leave a file unreadable or
        // immutable; restore both so the teardown can actually delete the
        // directory (and so a failure never leaks state into the next test).
        if let log = try? logURL() {
            try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o644],
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
    private func snapshotsDirectory() throws -> URL {
        try directory().appendingPathComponent("snapshots", isDirectory: true)
    }

    private func records(at url: URL) throws -> [CalendarDeltaRecord] {
        let data = (try? Data(contentsOf: url)) ?? Data()
        guard !data.isEmpty else { return [] }
        var segments = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        segments.removeLast()
        return try segments.filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(CalendarDeltaRecord.self, from: Data($0.utf8))
        }
    }

    private func readRows(_ storage: DurableEventStorage) -> [Event]? {
        guard case .loaded(let envelope, _) = storage.read(.calendarEvents, as: Event.self) else {
            return nil
        }
        return envelope.rows
    }

    // MARK: - A-F1: the duplicate-id guard must cover the BASE, not just the input

    /// The real shape, through a real store.
    ///
    /// `deleteCalendarEvent` removes by id (`removeAll { $0.id == id }`), so
    /// deleting a DUPLICATED id takes both rows out in one save: the array
    /// handed to `commit` is perfectly duplicate-free and round 1's
    /// input-only scan (G19) waved it through. The fold that replays that
    /// record at the next launch then hits `duplicateBaseID`, quarantines the
    /// log and FREEZES the slot — which presents as an empty calendar to the
    /// three export gates.
    func testDeletingADuplicatedIDOverADuplicatedBaseDoesNotFreezeTheNextLaunch() throws {
        // A base with two rows under one id, exactly as a cloud overwrite can
        // leave it (`rawCalendarEvents` is never deduped — see
        // `EventStore.calendarEvent(id:)`'s doc).
        let seeded = [event(0), event(1), event(1, title: "the duplicate body")]
        let storage = makeStorage()
        _ = try storage.commit(seeded, to: .calendarEvents, intent: .destructive)

        let store = makeStore()
        XCTAssertEqual(store.rawCalendarEvents.count, 3, "the fixture needs the duplicate to survive load")
        let victim = try XCTUnwrap(store.rawCalendarEvents.first { $0.id == event(1).id })
        store.deleteCalendarEvent(victim)

        XCTAssertEqual(store.storage.calendarDeltaLogRecordCount, 0,
                       "a delete over a duplicated base must land as a CHECKPOINT: "
                       + "a delta record on top of it folds to two copies of one body")

        let cold = makeStore()
        XCTAssertFalse(cold.isSlotFrozen(.calendarEvents),
                       "the next launch must not be frozen — a frozen calendar is an EMPTY one "
                       + "to diffSync, the DR snapshot and the asset sweep")
        XCTAssertEqual(cold.rawCalendarEvents.map(\.id), [event(0).id],
                       "both duplicate rows leave, the survivor stays")
    }

    /// The same guard at the storage layer, where the reason string is
    /// visible: the fallback must be attributed to the BASE, not to the input
    /// (whose own scan finds nothing here).
    func testABaseThatAlreadyHoldsADuplicateIDRefusesTheDeltaPath() throws {
        let storage = makeStorage()
        _ = try storage.commit([event(0), event(1), event(1, title: "dup")],
                               to: .calendarEvents, intent: .destructive)

        // A fresh instance, so the base is installed by `read` rather than by
        // the commit above — the duplicate scan has to happen at BOTH install
        // sites, and this is the one a real relaunch uses.
        let cold = makeStorage()
        _ = readRows(cold)

        let receipt = try cold.commit([event(0)], to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint)
        XCTAssertEqual(receipt.reason, "duplicateBaseID")
    }

    // MARK: - A-F2: an unreadable log is not an empty log

    /// The one silent-shortening path round 1 had left. A log that EXISTS and
    /// will not read must freeze the slot — not present as `[]`, which
    /// `diffSync` mirrors as cloud DELETEs and `BackupSnapshotService` writes
    /// into the DR document.
    func testALogThatExistsButCannotBeReadFreezesInsteadOfServingAShortArray() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        var edited = events(4)
        edited[0].title = "in the log, not in the checkpoint"
        let delta = try storage.commit(edited, to: .calendarEvents)
        XCTAssertEqual(delta.mode, .delta, "the fixture needs a live log")

        // Primary perfectly readable; the LOG is not.
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: try logURL().path)

        let cold = makeStorage()
        let read = cold.read(.calendarEvents, as: Event.self)
        guard case .unreadable(let fault) = read else {
            return XCTFail("an unreadable log must not be served as an empty one; got \(read)")
        }
        XCTAssertTrue(cold.isFrozen(.calendarEvents),
                      "the freeze IS the export gate: BackupSnapshotService and "
                      + "SupabaseSyncService both ask `isSlotFrozen`")
        guard case .ioError = fault else {
            return XCTFail("a log we could not READ is `.ioError` — not one byte may be moved "
                           + "for it, exactly as for an unreadable primary; got \(fault)")
        }

        // And it is transient in the way that matters: permission restored,
        // the next launch serves the folded state with nothing lost.
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: try logURL().path)
        let healed = makeStorage()
        XCTAssertEqual(readRows(healed)?.map(\.title).first, "in the log, not in the checkpoint")
    }

    /// An ABSENT log is still an empty log, not a fault. The A-F2 split must
    /// not turn a store that has never logged into a frozen one.
    func testAnAbsentLogIsStillAnEmptyLogAndNeverAFault() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(3), to: .calendarEvents, intent: .destructive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path))

        let cold = makeStorage()
        XCTAssertEqual(readRows(cold)?.count, 3)
        XCTAssertFalse(cold.isFrozen(.calendarEvents))
    }

    // MARK: - A-F3: a heal that cannot read must not truncate

    /// The load-bearing contract, pinned where it is observable.
    ///
    /// Round 1 found the boundary with `(try? Data(contentsOf:)) ?? Data()`,
    /// so a read FAILURE answered "no newline anywhere" — and the heal then
    /// truncated the ENTIRE log to zero while trailing it as a routine torn
    /// tail. "I scanned and found no boundary" and "I could not scan" have to
    /// be different answers; on any file that reads normally the difference
    /// is invisible, so it is asserted here directly.
    func testTheBoundaryScanThrowsRatherThanAnsweringZeroWhenItCannotRead() throws {
        _ = makeStorage()
        let log = CalendarDeltaLog(fileURL: try logURL())
        // A pipe is a handle that cannot seek, so every scan step fails the
        // way a damaged file's would. The WRITE end is closed first, on
        // purpose: with it open a read would block forever instead of
        // failing, and a hang is not an assertion — the reverted
        // implementation has to come back with a wrong ANSWER, promptly, for
        // this to be a falsification rather than a timeout.
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        XCTAssertThrowsError(try log.lastRecordBoundary(in: pipe.fileHandleForReading, before: 4096),
                             "answering 0 here means 'truncate the whole log'")
    }

    /// The boundary scan walks backwards in 64 KB windows, so a torn tail
    /// bigger than one window is the case a single-window implementation gets
    /// wrong. The complete record before it must survive untouched.
    func testATornTailLargerThanOneScanWindowStillKeepsEveryCompleteRecord() throws {
        _ = makeStorage()
        let log = CalendarDeltaLog(fileURL: try logURL())
        let digest = CalendarDeltaFold.orderDigest(events(2).map(\.id))
        let first = CalendarDeltaRecord(base: 1, seq: 2, order: nil, orderDigest: digest,
                                        count: 2, changed: [event(0)], dominoLastPush: nil)
        XCTAssertNotNil(log.append(first))

        // 200 KB of un-terminated garbage: a kill partway through a very large
        // record, three scan windows deep.
        let handle = try FileHandle(forUpdating: try logURL())
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: "x", count: 200_000).utf8))
        try handle.close()

        let second = CalendarDeltaRecord(base: 1, seq: 3, order: nil, orderDigest: digest,
                                         count: 2, changed: [event(1)], dominoLastPush: nil)
        XCTAssertNotNil(log.append(second))
        XCTAssertEqual(try XCTUnwrap(log.loadRecords()).map(\.seq), [2, 3],
                       "the torn tail goes, both complete records stay")
    }

    /// The short-write derivation, copied out of the comment and into a
    /// fixture (this repo's rule: load-bearing properties live in tests, not
    /// in prose). A prefix of a record can never end in a newline, because
    /// the only newline in a payload is the terminator appended last — so a
    /// partial write is always dropped as a torn tail and never mistaken for
    /// a complete record.
    func testAnUnterminatedTailIsNeverServedAsARecord() throws {
        _ = makeStorage()
        let log = CalendarDeltaLog(fileURL: try logURL())
        let digest = CalendarDeltaFold.orderDigest(events(1).map(\.id))
        let record = CalendarDeltaRecord(base: 1, seq: 2, order: nil, orderDigest: digest,
                                         count: 1, changed: [event(0, title: "a\nb")],
                                         dominoLastPush: nil)
        let payload = try XCTUnwrap(log.encode(record))
        XCTAssertFalse(payload.contains(0x0A),
                       "a raw newline inside an encoded record would break the framing — "
                       + "JSON escapes them, and the whole torn-tail rule rests on that")

        // Every proper prefix, written alone, must read back as nothing.
        for cut in [1, payload.count / 3, payload.count / 2, payload.count - 1] {
            try Data(payload.prefix(cut)).write(to: try logURL())
            XCTAssertEqual(log.loadRecords()?.count, 0,
                           "a \(cut)-byte prefix is a torn tail, never a record")
            XCTAssertNil(log.fault, "a torn tail is not corruption")
        }
    }

    // MARK: - A-F4: the shrink snapshot's log half must be a COPY

    /// The log is appended IN PLACE, so a hardlinked "pre-shrink" snapshot
    /// keeps growing — it ends up encoding the very deletion it exists to
    /// undo. A copy freezes it.
    func testTheShrinkSnapshotsLogHalfIsFrozenAtSnapshotTime() throws {
        let storage = makeStorage()
        var rows = events(120)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "before the shrink"
        _ = try storage.commit(rows, to: .calendarEvents)        // log: 1 record

        let shrunk = Array(rows.prefix(20))                       // >50% shrink
        _ = try storage.commit(shrunk, to: .calendarEvents)       // log: 2 records
        var after = shrunk
        after[1].title = "after the shrink"
        _ = try storage.commit(after, to: .calendarEvents)        // log: 3 records

        let entries = try FileManager.default.contentsOfDirectory(atPath: try snapshotsDirectory().path)
        let name = try XCTUnwrap(entries.first { $0.hasSuffix(".log") }, "saw \(entries)")
        let snapshot = try records(at: try snapshotsDirectory().appendingPathComponent(name))

        let liveSeqs = try records(at: try logURL()).map(\.seq)
        XCTAssertEqual(snapshot.map(\.seq), [2],
                       "the snapshot must hold the log AS IT WAS before the shrink; a hardlink "
                       + "would have grown it to \(liveSeqs)")
        XCTAssertFalse(snapshot.contains { $0.count == shrunk.count },
                       "a snapshot that contains the shrink record replays TO the shrink")

        // The whole point: checkpoint + snapshot log replays to the pre-shrink
        // array, which is what a recovery is reached for.
        let checkpointName = try XCTUnwrap(entries.first { $0.hasSuffix(".json") })
        let bytes = try Data(contentsOf: try snapshotsDirectory().appendingPathComponent(checkpointName))
        let newline = try XCTUnwrap(bytes.firstIndex(of: 0x0A))
        let header = try JSONDecoder().decode(SlotEnvelopeHeader.self, from: bytes[bytes.startIndex..<newline])
        let base = try JSONDecoder().decode([Event].self, from: bytes[(newline + 1)...])
        switch CalendarDeltaFold.fold(base: base, baseSeq: header.seq, baseStamp: nil, records: snapshot) {
        case .failure(let fault):
            XCTFail("the recovery pair must fold: \(fault)")
        case .success(let folded):
            XCTAssertEqual(folded.rows.count, 120, "the snapshot is the PRE-shrink state or it is useless")
            XCTAssertEqual(folded.rows[0].title, "before the shrink")
        }
    }

    // MARK: - A-F5: a clear that failed must stop the delta path

    /// A checkpoint whose `clear` fails leaves records on the OLD base in the
    /// file. Appending the new base into it makes `plan` quarantine the whole
    /// log — one session of edits — so the delta path must stay refused until
    /// a clear succeeds.
    func testACheckpointWhoseClearFailedRefusesToKeepAppending() throws {
        let storage = makeStorage()
        var rows = events(6)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "delta one"
        XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)

        // `unlink` fails with EPERM on an immutable file, while the directory
        // stays perfectly writable — so the checkpoint's rename still lands
        // and only the clear is refused.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: try logURL().path)
        rows[1].title = "the checkpoint"
        let checkpoint = try storage.commit(rows, to: .calendarEvents, intent: .checkpointOnly)
        XCTAssertEqual(checkpoint.mode, .checkpoint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path),
                      "this rig needs the clear to actually fail")
        XCTAssertFalse(storage.calendarDeltaLogIsEmpty,
                       "a log still on the disk is not an empty log")

        rows[2].title = "after the failed clear"
        let next = try storage.commit(rows, to: .calendarEvents)
        XCTAssertEqual(next.mode, .checkpoint,
                       "appending here mixes two bases into one file, which `plan` quarantines whole")
        XCTAssertEqual(next.reason, "logNotCleared")

        // The end state is the one that matters: nothing quarantined, nothing
        // lost, the stale log discarded by generation.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: try logURL().path)
        let cold = makeStorage()
        XCTAssertFalse(cold.isFrozen(.calendarEvents))
        XCTAssertEqual(readRows(cold)?.map(\.title).prefix(3).map { $0 },
                       ["delta one", "the checkpoint", "after the failed clear"])
    }

    /// And it heals: once the file can be deleted, the next checkpoint clears
    /// it and the delta path comes back. A latch with no exit would turn one
    /// transient EPERM into a permanent whole-array-per-save regression.
    func testTheDeltaPathReturnsOnceTheLogCanFinallyBeCleared() throws {
        let storage = makeStorage()
        var rows = events(6)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "delta"
        _ = try storage.commit(rows, to: .calendarEvents)

        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: try logURL().path)
        rows[1].title = "blocked checkpoint"
        _ = try storage.commit(rows, to: .calendarEvents, intent: .checkpointOnly)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: try logURL().path)

        rows[2].title = "clearing checkpoint"
        _ = try storage.commit(rows, to: .calendarEvents, intent: .checkpointOnly)
        XCTAssertTrue(storage.calendarDeltaLogIsEmpty)

        rows[3].title = "delta again"
        XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)
    }

    // MARK: - B1: `read` never answers `.unreadable` with the slot unfrozen

    /// A foreign row type on `.calendarEvents` with a live log. Round 1's
    /// `guard let rows = folded.rows as? [Row] else { return nil }` was the
    /// ONE exit from `read` that left the slot unfrozen — so `adopt` handed
    /// an EMPTY, UNFROZEN calendar to `diffSync` (cloud DELETEs), the DR
    /// snapshot and the orphan-asset sweep.
    func testAFoldTheCallerCannotReceiveFreezesInsteadOfReturningAnEmptyCalendar() throws {
        struct ForeignRow: Codable, Equatable { var id: UUID? }

        let storage = makeStorage()
        // An EMPTY checkpoint, so the primary decodes as ANY row type while
        // the log still adds real `Event` bodies on top of it.
        _ = try storage.commit([Event](), to: .calendarEvents, intent: .destructive)
        let delta = try storage.commit([event(0)], to: .calendarEvents)
        XCTAssertEqual(delta.mode, .delta, "the fixture needs a live log")

        let cold = makeStorage()
        let read = cold.read(.calendarEvents, as: ForeignRow.self)
        guard case .unreadable = read else {
            return XCTFail("a fold this caller cannot take must not be served; got \(read)")
        }
        XCTAssertTrue(cold.isFrozen(.calendarEvents),
                      "`EventStore.adopt` documents `read` never returning `.unreadable` "
                      + "without raising; three export gates read that invariant")
    }

    // MARK: - B2: the launch number must name what it measures

    /// `foldMs` is the FOLD. On the expected steady state — an empty log at a
    /// normal cold start — it is zero however long the 2 MB primary took to
    /// read and decode. Round 1 labelled the whole `adopt` `foldMs`, which
    /// reported the entire slot decode as the new mechanism's price on
    /// exactly the launches where the new mechanism did nothing.
    func testFoldMsMeasuresTheFoldAndNotTheWholeSlotRead() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(3000), to: .calendarEvents, intent: .destructive)
        XCTAssertTrue(storage.calendarDeltaLogIsEmpty)

        let cold = makeStorage()
        XCTAssertEqual(readRows(cold)?.count, 3000)
        XCTAssertEqual(cold.calendarDeltaLogFoldMs, 0,
                       "3000 rows take real milliseconds to read and decode; none of them are the fold")
    }

    /// Both numbers reach the device trail under their own names, because the
    /// device A/B greps for them.
    func testTheLoadLineCarriesTheReadAndTheFoldSeparately() {
        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        let store = makeStore()
        store.addCalendarEvent(event(0))
        _ = makeStore()

        let text = DiagnosticTrail.combinedText()
        XCTAssertTrue(text.contains("calendarReadMs="),
                      "the whole-slot read needs its own name or `foldMs` keeps absorbing it")
        XCTAssertTrue(text.contains("foldMs="))
    }

    // MARK: - B3/B4: the delta receipt's numbers are measured, not asserted

    /// `onDiskBytes` is read BACK from the log after the append (the delta
    /// path's twin of the checkpoint path's `stat`-backed short-write
    /// refusal), so it is the file's true length — not a second copy of
    /// `bytes`, which is what round 1 reported under the same field name that
    /// means "confirmed on disk" one path over.
    func testTheDeltaReceiptReportsTheLogsRealSizeNotTheRecordsSize() throws {
        let storage = makeStorage()
        var rows = events(8)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)

        var receipt: CommitReceipt?
        for index in 0..<3 {
            rows[index].title = "edit-\(index)"
            receipt = try storage.commit(rows, to: .calendarEvents)
        }
        let last = try XCTUnwrap(receipt)
        XCTAssertEqual(last.mode, .delta)

        let onDisk = try Data(contentsOf: try logURL()).count
        XCTAssertEqual(last.onDiskBytes, onDisk,
                       "`onDiskBytes` means 'read back from the disk' on the checkpoint path; "
                       + "it has to mean the same here")
        XCTAssertEqual(last.logBytes, onDisk)
        XCTAssertGreaterThan(last.onDiskBytes, last.bytes,
                             "three records are on the disk, not one — the two fields are "
                             + "different facts and must not be the same number")
    }

    /// `encodeMs` is the field the whole ticket is priced in: a delta row's
    /// against a checkpoint row's `encodeMs=48-70`. Round 1 reported a
    /// hard-coded 0 while encoding the record TWICE, which made the
    /// comparison unanswerable.
    ///
    /// The bound is one-sided on purpose — encoding 400 events cannot take
    /// less than a millisecond on any machine this runs on, and CPU
    /// contention can only push it up.
    func testTheDeltaReceiptMeasuresItsOwnEncode() throws {
        let storage = makeStorage()
        var rows = events(2000)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        for index in 0..<400 { rows[index].title = "bulk-edit-\(index)" }

        let receipt = try storage.commit(rows, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .delta, "400 of 2000 rows stays inside both byte bounds")
        XCTAssertEqual(receipt.changedRowCount, 400)
        XCTAssertGreaterThanOrEqual(receipt.encodeMs, 1,
                                    "a 400-row delta encode is not free; a 0 here is a constant, "
                                    + "not a measurement")
    }

    // MARK: - B7: the runtime kill switch

    /// Default ON: an absent key must not read as `false`.
    func testTheKillSwitchDefaultsToOn() throws {
        XCTAssertNil(defaults.object(forKey: DurableEventStorage.calendarDeltaLogEnabledKey))
        let storage = makeStorage()
        var rows = events(5)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "edited"
        XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)
    }

    /// OFF is a COMPLETE return to the pre-gh#235 path — every save a
    /// whole-array checkpoint — and it takes effect on the next save, with no
    /// relaunch, which is the only property that makes it a field rollback.
    func testFlippingTheKillSwitchOffReturnsEveryCommitToTheWholeArrayPath() throws {
        let storage = makeStorage()
        var rows = events(5)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "delta while on"
        XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)
        XCTAssertFalse(storage.calendarDeltaLogIsEmpty)

        defaults.set(false, forKey: DurableEventStorage.calendarDeltaLogEnabledKey)
        rows[1].title = "checkpoint while off"
        let receipt = try storage.commit(rows, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint, "no relaunch: the very next save takes the flip")
        XCTAssertEqual(receipt.reason, "killSwitch")
        XCTAssertTrue(storage.calendarDeltaLogIsEmpty,
                      "OFF folds and clears whatever the log held — a half state would be worse "
                      + "than either mode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path))

        // Nothing lost across the flip, read from bytes by a fresh instance.
        let cold = makeStorage()
        XCTAssertEqual(readRows(cold)?.map(\.title).prefix(2).map { $0 },
                       ["delta while on", "checkpoint while off"])

        // And ON again is live too.
        defaults.set(true, forKey: DurableEventStorage.calendarDeltaLogEnabledKey)
        rows[2].title = "delta again"
        XCTAssertEqual(try cold.commit(rows, to: .calendarEvents).mode, .delta)
    }

    // MARK: - B8: one shrink, one snapshot

    /// A delta attempt takes the pre-shrink snapshot before it appends. When
    /// the append then FAILS, the checkpoint that follows must not take a
    /// second snapshot of the same shrink — three kept generations would lose
    /// two to one bulk delete.
    func testAnAppendFailureDuringAShrinkBurnsOnlyOneSnapshotGeneration() throws {
        let storage = makeStorage()
        var rows = events(120)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "creates the log"
        XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)

        // O_RDWR on a read-only file fails, so the append is genuinely
        // attempted and genuinely refused (the directory stays writable, so
        // the checkpoint fallback still lands).
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: try logURL().path)

        let receipt = try storage.commit(Array(rows.prefix(20)), to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint)
        XCTAssertEqual(receipt.reason, "appendFailed")

        let entries = try FileManager.default.contentsOfDirectory(atPath: try snapshotsDirectory().path)
        let prefix = "\(StorageSlot.calendarEvents.rawValue)-shrink-"
        let stamps = Set(entries.filter { $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).split(separator: ".").dropLast().joined(separator: ".") })
        XCTAssertEqual(stamps.count, 1,
                       "one shrink is one snapshot generation, whichever path ended up writing it; "
                       + "saw \(entries.sorted())")
    }

    // MARK: - Acceptance gap 2: a log tail proves a generation on its own

    /// With the primary gone and the log alive, round 1's reconcile `continue`d
    /// on the unreadable header and left `committedSeq` at the manifest's
    /// stale value — so an abandoned restore marker's `committedSeq == base`
    /// staleness test read "this slot never moved" and the replay overwrote
    /// `.destructive`-ly, clearing the log. The recoverable part destroyed by
    /// the recovery.
    func testTheLogsTailProvesACommittedGenerationWithoutAReadableHeader() throws {
        let storage = makeStorage()
        var rows = events(5)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)   // seq 1
        rows[0].title = "a"
        _ = try storage.commit(rows, to: .calendarEvents)                          // seq 2
        rows[1].title = "b"
        _ = try storage.commit(rows, to: .calendarEvents)                          // seq 3
        XCTAssertEqual(try records(at: try logURL()).last?.seq, 3)

        // The primary is gone; the log is not.
        try FileManager.default.removeItem(at: try primaryURL())

        let cold = makeStorage()
        XCTAssertEqual(cold.committedSeq(.calendarEvents), 3,
                       "a delta append IS a commit, and the log's tail is its durable proof — "
                       + "a stale seq here is what lets an abandoned marker overwrite it")
    }

    /// The other half of that change: a slot that was genuinely never written
    /// must still be seedable. A log is proof of a commit precisely because
    /// only a commit writes one.
    func testAFreshSlotWithNoLogIsStillFresh() {
        let storage = makeStorage()
        guard case .fresh = storage.read(.calendarEvents, as: Event.self) else {
            return XCTFail("a directory with no primary, no backup and no log is fresh")
        }
        XCTAssertEqual(storage.committedSeq(.calendarEvents), 0)
    }
}
