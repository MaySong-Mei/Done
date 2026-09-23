//
//  CalendarDeltaLogTests.swift
//  DoneTests
//
//  gh#235. The calendar delta log's two load-bearing properties, its failure
//  ladder, and the generation rules that keep the restore marker and the
//  Domino stamp honest.
//
//  The precedent (`ConversationDeltaLog`, gh#219) proved exactness and
//  idempotence for records that carry a FULL order every time. This log
//  inherits the order when it did not change, which is a different shape and
//  a different proof — so both properties are re-established here from
//  scratch rather than by reference.
//

import XCTest
@testable import Done

@MainActor
final class CalendarDeltaLogTests: XCTestCase {
    private var location: EventStorageLocation!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDeltaLogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        location = .isolated(name: suiteName)
        EventStorageLocation.destroy(location)
    }

    override func tearDown() {
        EventStorageLocation.destroy(location)
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Fixed instants, never `Date()`: an `Event` round-trips through JSON in
    /// every one of these tests, and a wall-clock date invites a
    /// precision-shaped flake that looks like a fold bug.
    private static let epoch = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func event(_ index: Int, title: String? = nil, note: String = "") -> Event {
        let start = Self.epoch.addingTimeInterval(Double(index) * 3600)
        return Event(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            title: title ?? "event-\(index)",
            note: note,
            timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
            createdAt: Self.epoch
        )
    }

    private func events(_ count: Int) -> [Event] { (0..<count).map { event($0) } }

    private func makeStorage() -> DurableEventStorage {
        DurableEventStorage(location: location, legacyDefaults: nil)
    }

    private func makeStore(seeds: Bool = false) -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: seeds)
    }

    private func directory() throws -> URL { try location.directoryURL() }
    private func primaryURL() throws -> URL {
        try directory().appendingPathComponent(StorageSlot.calendarEvents.filename)
    }
    private func logURL() throws -> URL {
        try directory().appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
    }
    private func logRecords() throws -> [CalendarDeltaRecord] {
        let data = (try? Data(contentsOf: try logURL())) ?? Data()
        guard !data.isEmpty else { return [] }
        var segments = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        segments.removeLast()
        return try segments.filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(CalendarDeltaRecord.self, from: Data($0.utf8))
        }
    }

    private func loadedRows(_ read: SlotRead<Event>, file: StaticString = #filePath,
                            line: UInt = #line) -> [Event]? {
        guard case .loaded(let envelope, _) = read else {
            XCTFail("expected .loaded, got \(read)", file: file, line: line)
            return nil
        }
        return envelope.rows
    }

    private func loadedEnvelope(_ read: SlotRead<Event>, file: StaticString = #filePath,
                                line: UInt = #line) -> SlotEnvelope<Event>? {
        guard case .loaded(let envelope, _) = read else {
            XCTFail("expected .loaded, got \(read)", file: file, line: line)
            return nil
        }
        return envelope
    }

    private func foldedRows(base: [Event], records: [CalendarDeltaRecord], baseSeq: UInt64 = 7,
                            file: StaticString = #filePath, line: UInt = #line) -> [Event]? {
        switch CalendarDeltaFold.fold(base: base, baseSeq: baseSeq, baseStamp: nil, records: records) {
        case .success(let folded): return folded.rows
        case .failure(let fault):
            XCTFail("fold refused: \(fault)", file: file, line: line)
            return nil
        }
    }

    /// Build the record chain a run of whole-array writes WOULD have produced,
    /// exactly the way `DurableEventStorage` builds it: each delta is diffed
    /// against the last PERSISTED array, never against the caller's previous
    /// in-memory value.
    private func chain(base: [Event], steps: [[Event]], baseSeq: UInt64 = 7,
                       stamps: [Date?] = []) -> [CalendarDeltaRecord] {
        var persisted = base
        var records: [CalendarDeltaRecord] = []
        var stamp: Date?
        for (index, next) in steps.enumerated() {
            let incoming = index < stamps.count ? stamps[index] : nil
            guard let record = CalendarDeltaFold.delta(
                from: persisted, to: next,
                base: baseSeq, seq: baseSeq + UInt64(records.count + 1),
                dominoLastPush: incoming, persistedStamp: stamp
            ) else { continue }
            if let incoming { stamp = incoming }
            records.append(record)
            persisted = next
        }
        return records
    }

    // MARK: - Property 1: the fold equals the whole-array write (RED LINE 3)

    /// Every shape a calendar edit takes, in one chain: a body edit, a create,
    /// a delete, a reorder, and an edit of a row created mid-chain.
    func testFoldReproducesWhatTheWholeArrayWriteWouldHaveWritten() {
        let base = events(6)

        var s1 = base
        s1[2].title = "renamed"                                     // body only

        var s2 = s1
        s2.append(event(99, title: "created"))                      // membership

        var s3 = s2
        s3.removeAll { $0.id == base[0].id }                        // membership

        var s4 = s3
        s4.swapAt(0, 3)                                             // pure reorder

        var s5 = s4
        s5[s5.firstIndex { $0.title == "created" }!].note = "edited" // mid-chain row

        let steps = [s1, s2, s3, s4, s5]
        let records = chain(base: base, steps: steps)
        XCTAssertEqual(records.count, steps.count, "every step here changes something")

        switch CalendarDeltaFold.fold(base: base, baseSeq: 7, baseStamp: nil, records: records) {
        case .failure(let fault):
            XCTFail("fold refused a well-formed chain: \(fault)")
        case .success(let folded):
            XCTAssertEqual(folded.rows, s5, "the fold must equal the array the whole-array write would have written")
            XCTAssertEqual(folded.rows.map(\.id), s5.map(\.id), "order, not just membership")
            XCTAssertEqual(folded.seq, 7 + UInt64(steps.count))
        }
    }

    /// The common device case, and the whole reason `order` is optional: a
    /// drag/resize/tick chain must write no id list at all.
    func testBodyOnlyEditsOmitTheOrderList() {
        let base = events(5)
        var s1 = base; s1[1].title = "a"
        var s2 = s1;   s2[4].note = "b"
        let records = chain(base: base, steps: [s1, s2])

        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.order == nil },
                      "a body-only edit must inherit the order, not restate 4164 UUIDs")
        XCTAssertTrue(records.allSatisfy { $0.changed.count == 1 })
        XCTAssertEqual(foldedRows(base: base, records: records), s2)
    }

    func testMembershipChangesWriteTheOrderList() {
        let base = events(3)
        var s1 = base; s1.append(event(9))
        var s2 = s1;   s2.swapAt(0, 1)
        let records = chain(base: base, steps: [s1, s2])

        XCTAssertEqual(records.map { $0.order != nil }, [true, true])
        XCTAssertEqual(records[1].changed, [], "a pure reorder changes no body")
        XCTAssertEqual(foldedRows(base: base, records: records), s2)
    }

    // MARK: - Property 2: idempotence (RED LINE 3)

    /// The crash-safety argument for checkpoint ordering: replaying a batch of
    /// deltas over a checkpoint that already incorporates them is a fixed
    /// point. Re-proven here because inheritance of `order` is a shape the
    /// precedent never had.
    func testFoldingOverACheckpointThatAlreadyIncludesTheDeltasIsAFixedPoint() {
        let base = events(4)
        var s1 = base; s1[0].title = "x"
        var s2 = s1;   s2.append(event(8))
        var s3 = s2;   s3[1].note = "y"
        let records = chain(base: base, steps: [s1, s2, s3])

        guard let once = try? CalendarDeltaFold.fold(base: base, baseSeq: 7, baseStamp: nil,
                                                     records: records).get() else {
            return XCTFail("first fold refused")
        }
        // The kill-after-rename-before-clear shape, at the fold level: the new
        // checkpoint IS `once.rows`, and the stale log is replayed onto it.
        guard let twice = try? CalendarDeltaFold.fold(base: once.rows, baseSeq: 7, baseStamp: nil,
                                                      records: records).get() else {
            return XCTFail("replay refused")
        }
        XCTAssertEqual(twice.rows, once.rows)
        XCTAssertEqual(twice.rows, s3)
    }

    // MARK: - The fold refuses rather than shortens (G6)

    func testAnUnresolvableIDFaultsInsteadOfBeingDroppedSilently() {
        let base = events(3)
        let ghost = UUID()
        let record = CalendarDeltaRecord(
            base: 7, seq: 8,
            order: base.map(\.id) + [ghost],
            orderDigest: CalendarDeltaFold.orderDigest(base.map(\.id) + [ghost]),
            count: 4, changed: [], dominoLastPush: nil
        )
        switch CalendarDeltaFold.fold(base: base, baseSeq: 7, baseStamp: nil, records: [record]) {
        case .success(let folded):
            XCTFail("a compactMap would have produced \(folded.rows.count) rows and called it history")
        case .failure(let fault):
            XCTAssertEqual(fault, .danglingID(ghost))
        }
    }

    func testADriftedInheritedOrderFaults() {
        let base = events(3)
        // Inherits `order` (nil) but claims the digest of a DIFFERENT order.
        // Without `orderDigest` this shape folds silently to the wrong array.
        let record = CalendarDeltaRecord(
            base: 7, seq: 8, order: nil,
            orderDigest: CalendarDeltaFold.orderDigest(base.map(\.id).reversed()),
            count: 3, changed: [], dominoLastPush: nil
        )
        XCTAssertEqual(
            CalendarDeltaFold.fold(base: base, baseSeq: 7, baseStamp: nil, records: [record]).failure,
            .orderDrift
        )
    }

    func testAWrongCountFaults() {
        let base = events(3)
        let record = CalendarDeltaRecord(
            base: 7, seq: 8, order: nil,
            orderDigest: CalendarDeltaFold.orderDigest(base.map(\.id)),
            count: 99, changed: [], dominoLastPush: nil
        )
        XCTAssertEqual(
            CalendarDeltaFold.fold(base: base, baseSeq: 7, baseStamp: nil, records: [record]).failure,
            .countMismatch(expected: 99, folded: 3)
        )
    }

    func testAMissingGenerationFaults() {
        let base = events(2)
        let digest = CalendarDeltaFold.orderDigest(base.map(\.id))
        let records = [
            CalendarDeltaRecord(base: 7, seq: 8, order: nil, orderDigest: digest, count: 2,
                                changed: [event(0, title: "a")], dominoLastPush: nil),
            // seq 9 is missing — a record was lost from the middle, which an
            // append-only file cannot do by itself.
            CalendarDeltaRecord(base: 7, seq: 10, order: nil, orderDigest: digest, count: 2,
                                changed: [event(1, title: "b")], dominoLastPush: nil),
        ]
        XCTAssertEqual(
            CalendarDeltaFold.fold(base: base, baseSeq: 7, baseStamp: nil, records: records).failure,
            .seqGap(expected: 9, found: 10)
        )
    }

    func testADuplicatedIDInTheBaseFaultsRatherThanCollapsing() {
        let base = [event(0), event(1), event(0)]
        let record = CalendarDeltaRecord(
            base: 7, seq: 8, order: nil,
            orderDigest: CalendarDeltaFold.orderDigest(base.map(\.id)),
            count: 3, changed: [], dominoLastPush: nil
        )
        XCTAssertEqual(
            CalendarDeltaFold.fold(base: base, baseSeq: 7, baseStamp: nil, records: [record]).failure,
            .duplicateBaseID(base[0].id)
        )
    }

    // MARK: - The generation three-way (G7)

    func testPlanDiscardsALogOlderThanTheCheckpoint() {
        let records = chain(base: events(2), steps: [events(3)], baseSeq: 7)
        // The checkpoint moved to 9 — i.e. a checkpoint landed and the clear
        // did not. Nothing needs replaying, and nothing is a fault.
        XCTAssertEqual(CalendarDeltaFold.plan(checkpointSeq: 9, records: records),
                       .discardLog("checkpoint seq=9 already absorbed a log based on 7"))
    }

    func testPlanQuarantinesALogAheadOfItsCheckpoint() {
        let records = chain(base: events(2), steps: [events(3)], baseSeq: 7)
        guard case .quarantine = CalendarDeltaFold.plan(checkpointSeq: 3, records: records) else {
            return XCTFail("a checkpoint that went BACKWARDS under a log must not be folded onto")
        }
    }

    func testPlanQuarantinesAnUnknownRecordVersion() {
        let record = CalendarDeltaRecord(
            base: 7, seq: 8, order: nil, orderDigest: "", count: 0, changed: [],
            dominoLastPush: nil, v: CalendarDeltaRecord.currentVersion + 1
        )
        guard case .quarantine = CalendarDeltaFold.plan(checkpointSeq: 7, records: [record]) else {
            return XCTFail("an older reader must refuse a shape it does not know, not mis-fold it")
        }
    }

    func testPlanFoldsWhenTheGenerationsLineUp() {
        let records = chain(base: events(2), steps: [events(3)], baseSeq: 7)
        XCTAssertEqual(CalendarDeltaFold.plan(checkpointSeq: 7, records: records), .fold)
    }

    // MARK: - The order digest

    func testOrderDigestDistinguishesPermutations() {
        let ids = (0..<4).map { event($0).id }
        XCTAssertNotEqual(CalendarDeltaFold.orderDigest(ids),
                          CalendarDeltaFold.orderDigest(ids.reversed()),
                          "a reorder must not hash to the same value as the original")
        XCTAssertEqual(CalendarDeltaFold.orderDigest(ids), CalendarDeltaFold.orderDigest(ids))
        XCTAssertNotEqual(CalendarDeltaFold.orderDigest(ids),
                          CalendarDeltaFold.orderDigest(Array(ids.dropLast())))
    }

    // MARK: - The empty delta

    func testAnUnchangedArrayProducesNoRecord() {
        let rows = events(3)
        XCTAssertNil(CalendarDeltaFold.delta(from: rows, to: rows, base: 7, seq: 8,
                                             dominoLastPush: nil, persistedStamp: nil))
    }

    /// The stamp is part of the write even when no row moved: a lost stamp
    /// re-applies the whole elapsed Domino delta on the next launch.
    func testAMovedDominoStampAloneStillProducesARecord() {
        let rows = events(3)
        let later = Self.epoch.addingTimeInterval(86_400)
        let record = CalendarDeltaFold.delta(from: rows, to: rows, base: 7, seq: 8,
                                             dominoLastPush: later, persistedStamp: Self.epoch)
        XCTAssertEqual(record?.dominoLastPush, later)
        XCTAssertEqual(record?.changed, [])
        XCTAssertNil(record?.order)
    }

    func testFoldTakesTheLatestDominoStampAndNeverGoesBackwards() {
        let base = events(2)
        let t1 = Self.epoch.addingTimeInterval(3600)
        let t2 = Self.epoch.addingTimeInterval(7200)
        var s1 = base; s1[0].title = "a"
        var s2 = s1;   s2[1].title = "b"
        let records = chain(base: base, steps: [s1, s2], stamps: [t2, t1])
        // The second record carries an OLDER stamp than the first; `max` is
        // the rule, so the fold must keep the later one.
        let folded = try? CalendarDeltaFold.fold(base: base, baseSeq: 7, baseStamp: nil,
                                                 records: records).get()
        XCTAssertEqual(folded?.dominoLastPush, t2)
    }

    // MARK: - Append crash safety

    func testAppendDropsATornTailAndKeepsEveryCompleteRecord() throws {
        _ = makeStorage()   // creates the directory
        let log = CalendarDeltaLog(fileURL: try logURL())
        let digest = CalendarDeltaFold.orderDigest(events(2).map(\.id))
        let first = CalendarDeltaRecord(base: 1, seq: 2, order: nil, orderDigest: digest,
                                        count: 2, changed: [event(0, title: "a")], dominoLastPush: nil)
        XCTAssertNotNil(log.append(first))

        // A kill mid-append: bytes with no terminating newline.
        var torn = try Data(contentsOf: try logURL())
        torn.append(contentsOf: Array("{\"v\":1,\"base\":1,\"seq\":3,\"cou".utf8))
        try torn.write(to: try logURL())

        XCTAssertEqual(log.loadRecords()?.count, 1, "the torn tail is dropped, the complete record is not")
        XCTAssertNil(log.fault, "a torn tail is not corruption")

        let second = CalendarDeltaRecord(base: 1, seq: 3, order: nil, orderDigest: digest,
                                         count: 2, changed: [event(1, title: "b")], dominoLastPush: nil)
        XCTAssertNotNil(log.append(second), "an append after a crash starts from a clean boundary")
        let records = try XCTUnwrap(log.loadRecords())
        XCTAssertEqual(records.map(\.seq), [2, 3])
    }

    func testACompleteButUndecodableRecordFaultsInsteadOfBeingSkipped() throws {
        _ = makeStorage()
        let log = CalendarDeltaLog(fileURL: try logURL())
        try Data("{\"not\":\"a record\"}\n".utf8).write(to: try logURL())
        XCTAssertNil(log.loadRecords(), "a COMPLETE segment that will not decode is corruption")
        XCTAssertNotNil(log.fault)
    }

    // MARK: - Storage integration

    func testAnOrdinaryCalendarEditLandsAsADeltaAndSurvivesARestart() throws {
        let a = makeStorage()
        let base = events(40)
        let seed = try a.commit(base, to: .calendarEvents)
        XCTAssertEqual(seed.mode, .checkpoint, "the first write has no base to diff against")
        _ = a.read(.calendarEvents, as: Event.self)

        var next = base
        next[7].title = "moved"
        let receipt = try a.commit(next, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .delta)
        XCTAssertEqual(receipt.changedRowCount, 1)
        XCTAssertEqual(receipt.rowCount, 40, "the receipt's count is the FOLDED count, never the delta's")
        XCTAssertEqual(receipt.encodeMs, 0, "the 2 MB re-encode is the thing being removed")
        XCTAssertLessThan(receipt.bytes, seed.bytes / 4)

        let b = makeStorage()
        XCTAssertEqual(loadedRows(b.read(.calendarEvents, as: Event.self)), next)
    }

    /// G1, the highest-risk invariant in the change: an append is a real write
    /// and must advance the generation, ACROSS launches. If it does not, an
    /// abandoned restore marker stays "fresh" forever and eventually replays a
    /// weeks-old payload over everything the user did since.
    func testAnAppendAdvancesCommittedSeqAndItSurvivesTheProcess() throws {
        let a = makeStorage()
        let base = events(30)
        try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)
        let seedSeq = a.committedSeq(.calendarEvents)

        var next = base
        next[0].title = "edited"
        let receipt = try a.commit(next, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .delta)
        XCTAssertEqual(a.committedSeq(.calendarEvents), seedSeq + 1)

        // The manifest was deliberately NOT rewritten for the append; the
        // durable evidence is the log, and the next launch rebuilds from it.
        let b = makeStorage()
        XCTAssertEqual(b.committedSeq(.calendarEvents), seedSeq + 1,
                       "the generation an append minted must survive the process")

        // And a checkpoint afterwards must still mint something strictly newer.
        var third = next
        third.append(event(77))
        _ = try b.commit(third, to: .calendarEvents, intent: .checkpointOnly)
        XCTAssertGreaterThan(b.committedSeq(.calendarEvents), seedSeq + 1)
    }

    /// G2. A Domino push writes the moved rows and the stamp in one act; the
    /// delta must keep them in one act too, and the cold header read must fold
    /// the log in or the restore replay commits a stale stamp.
    func testTheDominoStampRidesInTheDeltaAndIsVisibleToTheColdReader() throws {
        let a = makeStorage()
        let base = events(20)
        let t0 = Self.epoch
        try a.commit(base, to: .calendarEvents, dominoLastPush: t0)
        _ = a.read(.calendarEvents, as: Event.self)

        let t1 = Self.epoch.addingTimeInterval(86_400)
        var pushed = base
        pushed[3].title = "pushed"
        let receipt = try a.commit(pushed, to: .calendarEvents, dominoLastPush: t1)
        XCTAssertEqual(receipt.mode, .delta)
        XCTAssertEqual(try logRecords().last?.dominoLastPush, t1)

        // Cold path: a brand new instance that has read nothing yet. This is
        // the restore replay's shape exactly.
        let b = makeStorage()
        XCTAssertEqual(b.persistedDominoStamp(), t1,
                       "reading the header alone would hand back the pre-push stamp")

        // And the folded envelope reports it too, so `adopt` needs no change.
        let c = makeStorage()
        XCTAssertEqual(loadedEnvelope(c.read(.calendarEvents, as: Event.self))?.header.dominoLastPush, t1)
    }

    /// P3. A kill between the checkpoint's `rename` and the log's `clear`.
    func testAStaleLogLeftOverAFreshCheckpointIsDiscarded() throws {
        let a = makeStorage()
        let base = events(20)
        try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)
        var next = base
        next[1].title = "delta"
        try a.commit(next, to: .calendarEvents)
        let stale = try Data(contentsOf: try logURL())
        XCTAssertFalse(stale.isEmpty)

        // The checkpoint lands...
        var third = next
        third[2].title = "checkpointed"
        try a.commit(third, to: .calendarEvents, intent: .checkpointOnly)
        // ...and the clear is what the kill interrupts.
        try stale.write(to: try logURL())

        let b = makeStorage()
        XCTAssertEqual(loadedRows(b.read(.calendarEvents, as: Event.self)), third,
                       "the stale log must be discarded by generation, not replayed")
        XCTAssertFalse(b.isFrozen(.calendarEvents), "a stale log is a known window, not corruption")
    }

    /// P8. The base vanished and the log did not. Folding onto `[]` would hand
    /// `EventStore` an empty array with `isSeedable` true — six demo rows over
    /// the last trace of the store.
    func testALogWithNoCheckpointAtAllRefusesToLookFresh() throws {
        let a = makeStorage()
        let base = events(20)
        try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)
        var next = base
        next[0].title = "unsaved work"
        try a.commit(next, to: .calendarEvents)

        try FileManager.default.removeItem(at: try primaryURL())
        let backup = try directory().appendingPathComponent(StorageSlot.calendarEvents.backupFilename)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.removeItem(at: try directory().appendingPathComponent("manifest.json"))

        let b = makeStorage()
        guard case .unreadable(let fault) = b.read(.calendarEvents, as: Event.self) else {
            return XCTFail("a live log is evidence the slot was committed; .fresh must be unreachable")
        }
        XCTAssertEqual(fault, .lostAfterManifest)
        XCTAssertTrue(b.isFrozen(.calendarEvents))
    }

    /// P7, the one place this change deliberately TIGHTENS existing behaviour.
    func testACorruptPrimaryWithALiveLogFreezesInsteadOfSilentlyPromotingTheBackup() throws {
        let a = makeStorage()
        let base = events(20)
        try a.commit(base, to: .calendarEvents)          // becomes the .bak
        _ = a.read(.calendarEvents, as: Event.self)
        var second = base
        second.append(event(50))
        try a.commit(second, to: .calendarEvents, intent: .checkpointOnly)
        _ = a.read(.calendarEvents, as: Event.self)
        var third = second
        third[0].title = "the edit only the log knows"
        try a.commit(third, to: .calendarEvents)
        XCTAssertEqual(try logRecords().count, 1)

        try Data("not json".utf8).write(to: try primaryURL())

        let b = makeStorage()
        guard case .unreadable = b.read(.calendarEvents, as: Event.self) else {
            return XCTFail("promoting the backup here silently drops a whole generation of edits")
        }
        XCTAssertTrue(b.isFrozen(.calendarEvents))
        // The exit: the log is in quarantine, so the NEXT launch reads clean
        // and the user is not frozen forever.
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            atPath: try directory().appendingPathComponent("quarantine").path
        )
        XCTAssertTrue(quarantined.contains { $0.hasSuffix(".log") }, "the deltas are kept for support")
    }

    /// G9. The sweep runs in `init`, before any read, and deletes silently.
    func testTheStartupSweepKeepsTheDeltaLog() throws {
        let a = makeStorage()
        let base = events(20)
        try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)
        var next = base
        next[0].title = "survives a cold launch"
        try a.commit(next, to: .calendarEvents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path))

        _ = makeStorage()   // its init sweeps
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path),
                      "an unlisted log would be deleted on every cold launch, silently")
    }

    /// G19. `byID` collapses a duplicated id; a checkpoint preserves it.
    func testDuplicateIDsFallBackToACheckpoint() throws {
        let a = makeStorage()
        let base = events(20)
        try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)

        var next = base
        next.append(base[0])            // same id twice
        let receipt = try a.commit(next, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint)
        XCTAssertEqual(receipt.reason, "duplicateID")
        XCTAssertEqual(loadedRows(makeStorage().read(.calendarEvents, as: Event.self))?.count, 21,
                       "a checkpoint keeps both rows byte for byte")
    }

    /// G20. One oversize delta is judged BEFORE the cumulative bound, and no
    /// record is ever evicted to make room.
    func testASingleOversizeDeltaBecomesACheckpoint() throws {
        let a = makeStorage()
        let base = events(400)
        try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)

        var next = base
        for index in next.indices { next[index].note = String(repeating: "x", count: 400) }
        let receipt = try a.commit(next, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint)
        XCTAssertEqual(receipt.reason, "single")
        XCTAssertEqual(try logRecords().count, 0, "the log is dropped, never trimmed")
        XCTAssertEqual(loadedRows(makeStorage().read(.calendarEvents, as: Event.self)), next)
    }

    /// The threshold arithmetic, as a fixture rather than as a comment
    /// (#128/#129: load-bearing numbers written in prose rot).
    func testCompactionThresholdArithmetic() {
        // The dogfood device's measured store: 4164 rows / 2_042_172 B. A
        // quarter of it is still under the ceiling, so the ceiling does not
        // bind there — which is the number that matters, and is exactly the
        // kind of claim that would have been wrong in a comment.
        XCTAssertEqual(DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 2_042_172),
                       510_543)
        XCTAssertEqual(DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 4_000_000),
                       512 * 1024, "the ceiling binds above ~2 MB")
        XCTAssertEqual(DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 5_000),
                       64 * 1024, "a new user's tiny store is lifted to the floor")
        XCTAssertEqual(DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 800_000),
                       200_000, "in between it is a quarter of the store")
        XCTAssertEqual(DurableEventStorage.calendarSingleDeltaCeiling(checkpointBytes: 2_042_172),
                       1_021_086)
        XCTAssertGreaterThan(
            DurableEventStorage.calendarSingleDeltaCeiling(checkpointBytes: 2_042_172),
            DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 2_042_172),
            "the single-record ceiling must not be the binding bound in the common case"
        )
    }

    /// The cumulative bound, and the proof that it cannot thrash: the log
    /// resets to zero, so a big checkpoint never forces a checkpoint per save.
    func testTheLogCheckpointsItselfOnceItCrossesTheByteBound() throws {
        let a = makeStorage()
        let base = events(300)
        let seed = try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)

        var checkpoints = 0
        var deltas = 0
        var rows = base
        for step in 0..<400 {
            rows[step % rows.count].note = "n\(step)"
            let receipt = try a.commit(rows, to: .calendarEvents)
            if receipt.mode == .delta { deltas += 1 } else { checkpoints += 1 }
        }
        XCTAssertGreaterThan(deltas, checkpoints * 4,
                             "deltas must dominate; a checkpoint per save would be worse than before")
        XCTAssertGreaterThan(checkpoints, 0, "the bound must actually bind")
        XCTAssertEqual(loadedRows(makeStorage().read(.calendarEvents, as: Event.self)), rows)
        XCTAssertGreaterThan(seed.bytes, 0)
    }

    /// P4's first rung. An append that cannot land must fall back to a whole
    /// array checkpoint, not fail the save.
    func testAnAppendThatCannotLandFallsBackToACheckpoint() throws {
        let a = makeStorage()
        let base = events(20)
        try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)

        // A directory where the log file wants to be: `append` cannot open it.
        try FileManager.default.createDirectory(at: try logURL(), withIntermediateDirectories: true)

        var next = base
        next[0].title = "must not be lost"
        let receipt = try a.commit(next, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint)
        XCTAssertEqual(receipt.reason, "appendFailed")

        // The fallback checkpoint's own `clear()` already unlinked the
        // obstruction; this is only here so the reopen below starts clean
        // whichever way that went.
        try? FileManager.default.removeItem(at: try logURL())
        XCTAssertEqual(loadedRows(makeStorage().read(.calendarEvents, as: Event.self)), next,
                       "never lose an event: the fallback rung is what makes that true")
    }

    /// G10. Wipe, then create. The next launch must not purge the log the new
    /// event lives in.
    func testAWipedCheckpointWithLiveDeltasIsNotTreatedAsWiped() throws {
        let a = makeStorage()
        try a.commit(events(20), to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)
        try a.commit([Event](), to: .calendarEvents, wiped: true, intent: .destructive)
        a.purgeAuxiliaryCopies(for: .calendarEvents)

        let created = [event(1, title: "after the wipe")]
        let receipt = try a.commit(created, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .delta, "a wiped checkpoint is still a base")

        let b = makeStorage()
        let envelope = try XCTUnwrap(loadedEnvelope(b.read(.calendarEvents, as: Event.self)))
        XCTAssertEqual(envelope.rows, created)
        XCTAssertFalse(envelope.header.wiped,
                       "left true, `adopt` purges the log the new event lives in, every launch")

        // And the direct call is guarded too.
        b.purgeAuxiliaryCopies(for: .calendarEvents)
        XCTAssertEqual(try logRecords().count, 1)
    }

    /// A wipe itself must take every byte of plaintext with it.
    func testAWipeRemovesTheLog() throws {
        let a = makeStorage()
        let base = events(20)
        try a.commit(base, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)
        var next = base
        next[0].note = "private"
        try a.commit(next, to: .calendarEvents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path))

        try a.commit([Event](), to: .calendarEvents, wiped: true, intent: .destructive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path))
    }

    // MARK: - Store-level wiring

    func testSaveCalendarEventsRoundTripsThroughTheLogAndBack() {
        let a = makeStore()
        for index in 0..<30 { a.addCalendarEvent(event(index)) }
        a.flushCalendarDeltaCheckpoint()
        let before = a.rawCalendarEvents

        let b = makeStore()
        XCTAssertEqual(b.rawCalendarEvents.map(\.id), before.map(\.id))
        var edited = before[4]
        edited.title = "renamed in place"
        b.updateCalendarEvent(edited)
        XCTAssertFalse(b.persistenceDegraded)

        let c = makeStore()
        XCTAssertEqual(c.rawCalendarEvents.map(\.title), b.rawCalendarEvents.map(\.title))
        XCTAssertEqual(c.rawCalendarEvents.count, 30)
    }

    /// The background edge is required, not an optimisation: it is what keeps
    /// the launch fold free in the normal case and bounds the downgrade window.
    func testTheBackgroundEdgeFoldsTheLogBackIntoTheCheckpoint() throws {
        let a = makeStore()
        for index in 0..<20 { a.addCalendarEvent(event(index)) }
        XCTAssertGreaterThan(a.storage.calendarDeltaLogRecordCount, 0)

        a.flushCalendarDeltaCheckpoint()
        XCTAssertTrue(a.storage.calendarDeltaLogIsEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path))
        XCTAssertEqual(makeStore().rawCalendarEvents.count, 20)
    }

    /// G18. `onSlotCommitted` fires once per append — the resident's write
    /// counter must not flatline — and never for a no-op.
    func testEverySuccessfulAppendPostsExactlyOneSlotCommit() {
        let store = makeStore()
        store.addCalendarEvent(event(0))
        var commits = 0
        store.onSlotCommitted = { slot, _ in if slot == .calendarEvents { commits += 1 } }

        for index in 1...5 { store.addCalendarEvent(event(index)) }
        XCTAssertEqual(commits, 5, "one per user edit, whichever mode it landed in")

        // An identical re-save performs no I/O and must post nothing.
        _ = store.saveCalendarEvents(refreshInterrupts: false)
        XCTAssertEqual(commits, 5)
    }

    // MARK: - The measurement (gh#235's whole point)

    /// The fixture-scale version of the device claim: the same N edits, the
    /// old whole-array way versus the delta way. Asserted as an ORDER OF
    /// MAGNITUDE, not a fixed number, so it stays a regression detector rather
    /// than a brittle measurement.
    func testDeltaWritesOrdersOfMagnitudeFewerBytesThanTheWholeArrayPath() throws {
        let rowCount = 600
        let edits = 50

        // Baseline: today's path, forced by `.checkpointOnly` on every save.
        let a = makeStorage()
        var rows = events(rowCount)
        try a.commit(rows, to: .calendarEvents)
        _ = a.read(.calendarEvents, as: Event.self)
        var wholeArrayBytes = 0
        var wholeArrayEncodeMs = 0
        for step in 0..<edits {
            rows[step % rowCount].title = "edit-\(step)"
            let receipt = try a.commit(rows, to: .calendarEvents, intent: .checkpointOnly)
            wholeArrayBytes += receipt.bytes
            wholeArrayEncodeMs += receipt.encodeMs
        }

        EventStorageLocation.destroy(location)
        let b = makeStorage()
        var deltaRows = events(rowCount)
        try b.commit(deltaRows, to: .calendarEvents)
        _ = b.read(.calendarEvents, as: Event.self)
        var deltaBytes = 0
        var deltaEncodeMs = 0
        for step in 0..<edits {
            deltaRows[step % rowCount].title = "edit-\(step)"
            let receipt = try b.commit(deltaRows, to: .calendarEvents)
            deltaBytes += receipt.bytes
            deltaEncodeMs += receipt.encodeMs
        }

        XCTAssertEqual(deltaRows, rows)
        XCTAssertLessThan(deltaBytes * 20, wholeArrayBytes,
                          "delta=\(deltaBytes)B whole=\(wholeArrayBytes)B over \(edits) edits on \(rowCount) rows")
        XCTAssertLessThanOrEqual(deltaEncodeMs, wholeArrayEncodeMs)
        XCTAssertEqual(loadedRows(makeStorage().read(.calendarEvents, as: Event.self)), deltaRows)
    }
}

// MARK: - Result sugar (test-local)

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
