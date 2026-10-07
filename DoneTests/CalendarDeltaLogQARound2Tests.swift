//
//  CalendarDeltaLogQARound2Tests.swift
//  DoneTests
//
//  INDEPENDENT QA, ROUND 2, for gh#235 (`fix/calendar-events-delta-log-235`).
//
//  Round 1's QA file holds the four load-bearing claims (exactness,
//  idempotence, no data loss, consumer equivalence). This file exists for the
//  round-2 repairs, and deliberately does NOT re-assert what
//  `CalendarDeltaLogRound2Tests` already asserts. It covers the three places
//  the implementer's own round-2 tests cannot fail:
//
//   * THE SEAM'S MODE. Every existing seam test discards the new second
//     parameter with `_`, and `ResidentTierOneCore.noteSlot(_:mode:)` is only
//     ever called directly in tests. So the wire from `CommitReceipt.mode`
//     through `EventStore.persist` to the resident counters — the whole point
//     of B5, because #111's daily report reads that counter as write VOLUME —
//     has no test between it and a hard-coded `.checkpoint`.
//   * THE TELEMETRY'S ARITHMETIC. `onDiskBytes`, `bytes` and `logBytes` are
//     asserted against the LOG FILE's own bytes, summed record by record,
//     rather than against each other. `encodeMs` is asserted against the
//     checkpoint `encodeMs` it replaces on the SAME store — which is the unit
//     the whole ticket is priced in, and the only comparison the device A/B
//     will actually make.
//   * THE KILL SWITCH AS A ROLLBACK. Not "it writes a checkpoint" but "the
//     bytes it writes are the bytes the pre-gh#235 path wrote", built from an
//     independent encode, with no log file left anywhere and every seam
//     notification carrying `.checkpoint`.
//
//  Plus three shapes the round-2 fixes make newly reachable: a duplicated
//  base that the fallback checkpoint does NOT repair, an `.io` refusal that
//  must move not one byte, and a torn tail landing exactly on the boundary
//  scan's window edge.
//

import XCTest
@testable import Done

@MainActor
final class CalendarDeltaLogQARound2Tests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDeltaLogQARound2Tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        if let dir = try? location.directoryURL() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            let log = dir.appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
            try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o644],
                                                   ofItemAtPath: log.path)
        }
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func event(_ index: Int, title: String? = nil) -> Event {
        let start = Self.epoch.addingTimeInterval(Double(index) * 3600)
        return Event(
            id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!,
            title: title ?? "r2-\(index)",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
            createdAt: Self.epoch,
            type: "Study"
        )
    }

    private func events(_ count: Int) -> [Event] { (0..<count).map { event($0) } }

    /// The storage under test always reads its kill switch from the suite's
    /// own defaults, never from `.standard` — a test that flipped the device
    /// domain would be a live-fire exercise on the machine running it.
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

    private func readRows(_ storage: DurableEventStorage,
                          file: StaticString = #filePath, line: UInt = #line) -> [Event]? {
        switch storage.read(.calendarEvents, as: Event.self) {
        case .loaded(let envelope, _): return envelope.rows
        case let other:
            XCTFail("expected .loaded, got \(other)", file: file, line: line); return nil
        }
    }

    /// The log's segments as BYTES, decoded by this file rather than by the
    /// class under test: the byte arithmetic below is only evidence if the
    /// lengths come from the file itself.
    private func logSegmentByteCounts() throws -> [Int] {
        let data = (try? Data(contentsOf: try logURL())) ?? Data()
        guard !data.isEmpty else { return [] }
        var counts: [Int] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            counts.append(data.distance(from: start, to: newline))
            start = data.index(after: newline)
        }
        return counts
    }

    /// The rows half of a slot file — everything after the header line.
    private func rowBytes(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        return Data(data[(newline + 1)...])
    }

    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - B5: the mode has to survive the wire, not just the enum

    /// POSITIVE CONTROL + the B5 falsifier in one.
    ///
    /// `EventStore.persist` forwards `receipt.mode` to `onSlotCommitted`.
    /// Nothing else in the suite looks at that argument: every other
    /// registration binds it as `_`, and `noteSlot(_:mode:)` is only ever
    /// called with a literal. So a `persist` that passed a CONSTANT
    /// `.checkpoint` — which is exactly round 1's behaviour expressed in the
    /// new signature, and exactly what makes #111's daily line report a 460x
    /// byte cut as a flat count — would be invisible.
    func testTheSeamCarriesTheModeTheCommitActuallyUsed() {
        let store = makeStore()
        var seen: [CommitMode] = []
        store.onSlotCommitted = { slot, mode in
            if slot == .calendarEvents { seen.append(mode) }
        }

        // 1. The first save has no base yet, so it is a checkpoint.
        store.addCalendarEvent(event(0))
        XCTAssertEqual(seen, [.checkpoint], "the base-establishing save is a whole-array write")

        // 2. Ordinary edits are deltas.
        store.addCalendarEvent(event(1))
        guard var edited = store.rawCalendarEvents.first else {
            return XCTFail("the fixture needs a row to edit")
        }
        edited.title = "edited"
        store.updateCalendarEvent(edited)
        XCTAssertEqual(store.storage.calendarDeltaLogRecordCount, 2,
                       "the fixture needs two real appends")
        XCTAssertEqual(seen, [.checkpoint, .delta, .delta],
                       "a ~2 KB append must not reach the seam wearing a 2 MB checkpoint's label")

        // 3. The background edge folds them back, and says so.
        store.flushCalendarDeltaCheckpoint()
        XCTAssertEqual(seen, [.checkpoint, .delta, .delta, .checkpoint])
    }

    /// The consumer end of the same wire, through the counters #111 actually
    /// reports. Two independent mutations are covered: a constant mode in
    /// `persist`, and a `noteSlot` that forgets to split.
    ///
    /// The arithmetic the daily line depends on is stated as arithmetic:
    /// deltas = total − checkpoints.
    func testTheResidentCountersSplitByWhatTheStoreActuallyWrote() {
        let store = makeStore()
        var core = ResidentTierOneCore()
        store.onSlotCommitted = { slot, mode in core.noteSlot(slot, mode: mode) }

        store.addCalendarEvent(event(0))                       // checkpoint (no base)
        for index in 1...4 { store.addCalendarEvent(event(index)) }   // 4 deltas
        store.flushCalendarDeltaCheckpoint()                   // checkpoint

        XCTAssertEqual(store.storage.calendarDeltaLogRecordCount, 0,
                       "the flush must actually have folded")
        XCTAssertEqual(core.counters.slotWritesCalendarEvents, 6,
                       "the TOTAL keeps its old meaning: every calendar commit, either shape")
        XCTAssertEqual(core.counters.slotWritesCalendarCheckpoints, 2,
                       "two whole-array writes happened: the base and the fold-back")
        XCTAssertEqual(core.counters.slotWritesCalendarEvents
                       - core.counters.slotWritesCalendarCheckpoints, 4,
                       "deltas = total − checkpoints is the subtraction the daily line does")
    }

    // MARK: - B3/B4: the receipt's byte fields against the log's own bytes

    /// Each delta receipt is checked against the FILE, record by record:
    ///   * `bytes` is the encoded record's length, terminator excluded;
    ///   * `onDiskBytes` and `logBytes` are the log's length after the append,
    ///     which must equal Σ(bytes + 1) over every record written so far;
    ///   * the two are different numbers from the second append onward, so a
    ///     `onDiskBytes: payload.count` copy (round 1) cannot pass.
    func testTheDeltaReceiptsByteFieldsAreTheLogFilesOwnArithmetic() throws {
        let storage = makeStorage()
        var rows = events(12)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)

        var runningTotal = 0
        for index in 0..<5 {
            rows[index].title = "arith-\(index)"
            let receipt = try storage.commit(rows, to: .calendarEvents)
            XCTAssertEqual(receipt.mode, .delta, "append \(index)")

            let segments = try logSegmentByteCounts()
            // A `guard` rather than a bare subscript: under a mutation that
            // disables the delta path entirely this array is EMPTY, and an
            // out-of-range crash takes the whole test process down with it —
            // which hides every other result in the run.
            guard segments.count == index + 1 else {
                return XCTFail("one complete record per append; saw \(segments.count) after append \(index)")
            }
            XCTAssertEqual(receipt.bytes, segments[index],
                           "`bytes` is THIS record's encoded length, terminator excluded")

            runningTotal += receipt.bytes + 1
            let fileSize = try Data(contentsOf: try logURL()).count
            XCTAssertEqual(fileSize, runningTotal,
                           "Σ(record + newline) is the whole file; anything else means a "
                           + "record was written twice or a terminator went missing")
            XCTAssertEqual(receipt.onDiskBytes, fileSize,
                           "`onDiskBytes` means 'read back from the disk' on the checkpoint "
                           + "path and must mean the same here")
            XCTAssertEqual(receipt.logBytes, fileSize)
            if index > 0 {
                XCTAssertNotEqual(receipt.onDiskBytes, receipt.bytes,
                                  "after the first append these are different facts; equal "
                                  + "numbers are the round-1 copy")
            }
        }
    }

    /// `writeMs` and `syncMs` are two disjoint slices of one bracket, so their
    /// sum can never exceed the wall time the caller measured around the whole
    /// commit. (A `writeMs` that still contained the fsync would break this
    /// the moment an fsync costs anything at all.)
    func testTheDeltaReceiptsMillisecondsDoNotDoubleCountEachOther() throws {
        let storage = makeStorage()
        var rows = events(400)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)

        rows[0].title = "timed"
        let start = Date()
        let receipt = try storage.commit(rows, to: .calendarEvents)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000) + 1   // +1 for truncation

        XCTAssertEqual(receipt.mode, .delta)
        XCTAssertGreaterThanOrEqual(receipt.writeMs, 0)
        XCTAssertGreaterThanOrEqual(receipt.syncMs, 0)
        XCTAssertLessThanOrEqual(receipt.writeMs + receipt.syncMs + receipt.encodeMs
                                 + receipt.diffMs, elapsedMs,
                                 "the four measured slices are disjoint parts of one commit")
    }

    /// The ticket's unit of account, measured on ONE store so the two numbers
    /// are comparable: a whole-array `encodeMs` against the `encodeMs` of the
    /// delta that replaces it. The device A/B reads exactly this pair.
    ///
    /// The bound is one-sided and structural — the delta encodes one changed
    /// row, the checkpoint encodes 3000 — so CPU contention can only widen it.
    func testADeltasEncodeIsCheaperThanTheCheckpointItReplaces() throws {
        let storage = makeStorage()
        var rows = events(3000)
        let checkpoint = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        XCTAssertEqual(checkpoint.mode, .checkpoint)
        XCTAssertGreaterThanOrEqual(checkpoint.encodeMs, 1,
                                    "3000 rows do not encode in zero milliseconds; if this ever "
                                    + "goes red the comparison below has lost its scale")

        rows[7].title = "one changed row"
        let delta = try storage.commit(rows, to: .calendarEvents)
        XCTAssertEqual(delta.mode, .delta)
        XCTAssertEqual(delta.changedRowCount, 1)
        XCTAssertLessThan(delta.encodeMs, checkpoint.encodeMs,
                          "encodeMs is what gh#235 is priced in — a delta that encodes one row "
                          + "must measure less than the whole array it replaced")
        XCTAssertLessThan(delta.bytes, checkpoint.bytes / 100,
                          "and the bytes are the reason")
    }

    // MARK: - B2: two numbers, two names, one of them provably not the other

    /// The launch line's arithmetic. On the expected steady state — a cold
    /// start with an empty log — `foldMs` is ZERO while `calendarReadMs`
    /// measures a real 3000-row decode. Round 1 had one number doing both
    /// jobs, so it reported the whole slot decode as gh#235's cost on exactly
    /// the launches where gh#235 did nothing.
    ///
    /// Both tokens are read out of `DiagnosticTrail`, because the device A/B
    /// greps the trail rather than calling an accessor.
    func testTheLaunchLineSeparatesTheSlotReadFromTheFoldNumerically() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(3000), to: .calendarEvents, intent: .destructive)

        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        let store = makeStore()
        XCTAssertEqual(store.rawCalendarEvents.count, 3000)
        XCTAssertTrue(store.storage.calendarDeltaLogIsEmpty, "this is the steady state")

        let line = try XCTUnwrap(DiagnosticTrail.combinedText()
            .components(separatedBy: "\n").last { $0.contains("load: calendar=") },
                                 "the launch line has to reach the trail to be grepped")
        let readMs = try XCTUnwrap(Self.number(named: "calendarReadMs", in: line))
        let foldMs = try XCTUnwrap(Self.number(named: "foldMs", in: line))

        XCTAssertGreaterThanOrEqual(readMs, 1,
                                    "reading and decoding 3000 rows is not free; a zero here "
                                    + "means the number stopped measuring the slot read")
        XCTAssertEqual(foldMs, 0,
                       "not one of those milliseconds was spent folding — there was nothing "
                       + "to fold")
        XCTAssertLessThan(foldMs, readMs,
                          "the two must be different numbers or the A/B cannot attribute a "
                          + "slow launch to gh#235")
    }

    /// And the other side of it: with a log actually standing on the
    /// checkpoint, `foldMs` is the fold's own bracket and `calendarReadMs`
    /// still contains it. Zero-vs-zero is not evidence, so this asserts the
    /// containment rather than a magnitude.
    func testTheFoldNumberIsBracketedInsideTheReadNumber() throws {
        let storage = makeStorage()
        var rows = events(1200)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        for index in 0..<6 {
            rows[index].title = "delta-\(index)"
            XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)
        }

        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        let store = makeStore()
        XCTAssertEqual(store.rawCalendarEvents.prefix(6).map(\.title),
                       (0..<6).map { "delta-\($0)" })

        let line = try XCTUnwrap(DiagnosticTrail.combinedText()
            .components(separatedBy: "\n").last { $0.contains("load: calendar=") })
        let readMs = try XCTUnwrap(Self.number(named: "calendarReadMs", in: line))
        let foldMs = try XCTUnwrap(Self.number(named: "foldMs", in: line))
        XCTAssertLessThanOrEqual(foldMs, readMs,
                                 "the fold happens INSIDE the slot read; it can never measure "
                                 + "more than the bracket that contains it")
        XCTAssertEqual(foldMs, store.storage.calendarDeltaLogFoldMs,
                       "the trail's number and the accessor's are the same measurement")
    }

    private static func number(named key: String, in line: String) -> Int? {
        guard let range = line.range(of: key + "=") else { return nil }
        let rest = line[range.upperBound...].prefix { $0.isNumber }
        return Int(rest)
    }

    // MARK: - B7: the kill switch as a rollback, not as a branch

    /// OFF must be the pre-gh#235 path, judged by its BYTES rather than by
    /// its `mode` field: every save's row payload is byte-identical to an
    /// independent whole-array encode, no log file is ever created, and every
    /// seam notification says `.checkpoint`.
    func testTheKillSwitchOffWritesExactlyWhatTheWholeArrayPathWould() throws {
        defaults.set(false, forKey: DurableEventStorage.calendarDeltaLogEnabledKey)

        let store = makeStore()
        var modes: [CommitMode] = []
        store.onSlotCommitted = { slot, mode in
            if slot == .calendarEvents { modes.append(mode) }
        }

        for index in 0..<5 {
            store.addCalendarEvent(event(index))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path),
                           "OFF must not create the log at all (save \(index))")

            // The reference is built here, not read from the store: a
            // whole-array encode of exactly what the caller holds.
            // Same configuration as the store's own row encoder — `.sortedKeys`
            // and Foundation's default date strategy — and built here so the
            // reference does not come from the object under test.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let expected = try encoder.encode(store.rawCalendarEvents)
            XCTAssertEqual(try rowBytes(of: try primaryURL()), expected,
                           "OFF is a rollback: the slot file holds the whole array, byte for byte")
        }
        XCTAssertEqual(modes, Array(repeating: CommitMode.checkpoint, count: 5))
        XCTAssertEqual(store.storage.calendarDeltaLogRecordCount, 0)

        // The B9 disclosure's other half: `.bak` is hardlinked from the primary
        // before every rename, so "every save is a checkpoint" also restores
        // the pre-gh#235 BACKUP cadence — one edit behind rather than one
        // checkpoint behind. A rollback that left recovery granularity where
        // gh#235 put it would not be a rollback.
        let backup = try directory().appendingPathComponent(StorageSlot.calendarEvents.backupFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try rowBytes(of: backup),
                       try encoder.encode(Array(store.rawCalendarEvents.dropLast())),
                       "the backup holds the array as of the save before this one")

        // And a cold reader agrees with memory.
        let cold = makeStore()
        XCTAssertEqual(cold.rawCalendarEvents.map(\.id), store.rawCalendarEvents.map(\.id))
    }

    /// A flip mid-session, in BOTH directions, with a cold read after each —
    /// the shape a field rollback actually takes. Nothing may be lost at
    /// either transition, and the log must be gone while OFF.
    func testFlippingTheSwitchInBothDirectionsLosesNothingAtEitherEdge() throws {
        let storage = makeStorage()
        var rows = events(10)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)

        var expected = rows
        for (index, flag) in [true, true, false, false, true, true].enumerated() {
            defaults.set(flag, forKey: DurableEventStorage.calendarDeltaLogEnabledKey)
            rows[index].title = "flip-\(index)-\(flag)"
            expected = rows
            let receipt = try storage.commit(rows, to: .calendarEvents)
            XCTAssertEqual(receipt.mode, flag ? .delta : .checkpoint, "step \(index)")
            if !flag {
                XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path),
                               "an OFF save folds and clears the log; a half state is worse "
                               + "than either mode")
            }
            let cold = makeStorage()
            XCTAssertEqual(readRows(cold)?.map(\.title), expected.map(\.title),
                           "cold read after step \(index)")
        }
    }

    // MARK: - A-F1: what the fallback checkpoint does NOT repair

    /// The fallback is data-SAFE, not a repair: a checkpoint preserves the
    /// duplicated base byte for byte, so the base it re-installs is still
    /// duplicated and the delta path stays off for good. That is the correct
    /// trade (RED LINE 2 beats throughput), but it is a standing whole-array
    /// cost, and it is written down here rather than in a comment because the
    /// comment at the guard claims the fallback "re-establishes a clean base".
    func testADuplicatedBaseIsPreservedNotRepairedAndTheDeltaPathStaysOff() throws {
        let storage = makeStorage()
        let duplicated = [event(0), event(1), event(1, title: "the duplicate body")]
        _ = try storage.commit(duplicated, to: .calendarEvents, intent: .destructive)

        var rows = duplicated
        for index in 0..<3 {
            rows[0].title = "edit-\(index)"
            let receipt = try storage.commit(rows, to: .calendarEvents)
            XCTAssertEqual(receipt.mode, .checkpoint, "save \(index)")
            XCTAssertEqual(receipt.reason, "duplicateBaseID",
                           "and the trail says WHY every save costs the whole array")
        }

        // RED LINE 2: the duplicate is still there, both bodies intact.
        let cold = makeStorage()
        let served = try XCTUnwrap(readRows(cold))
        guard served.count == 3 else {
            return XCTFail("a checkpoint preserves duplicates byte for byte; saw \(served.count)")
        }
        XCTAssertEqual(served.map(\.id), duplicated.map(\.id))
        XCTAssertEqual(served[2].title, "the duplicate body")
        XCTAssertFalse(cold.isFrozen(.calendarEvents))
    }

    /// A-F5's THIRD consequence, which nothing else covers: while the latch
    /// stands, the byte-digest skip must be refused.
    ///
    /// The retry mechanism is "the background edge keeps producing
    /// checkpoints". A background flush of an UNCHANGED array has the same
    /// digest as the checkpoint whose clear just failed, so without the
    /// latch in `logStandsOnCheckpoint` it is skipped — no write, no clear
    /// retried, and the stale log sits on the disk with the delta path
    /// disabled until the user happens to edit something.
    func testWhileAClearIsOutstandingAnIdenticalSaveIsNotSkipped() throws {
        let storage = makeStorage()
        var rows = events(6)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "a delta to leave behind"
        XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)

        // `unlink` fails with EPERM on an immutable file while the directory
        // stays writable, so the checkpoint lands and only the clear is refused.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: try logURL().path)
        let blocked = try storage.commit(rows, to: .calendarEvents, intent: .checkpointOnly)
        XCTAssertFalse(blocked.skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path),
                      "this rig needs the clear to actually fail")
        XCTAssertFalse(storage.calendarDeltaLogIsEmpty)

        // The file can be removed again — but nothing has CHANGED, so the only
        // thing that can retry the clear is a save of the identical array.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: try logURL().path)
        let retry = try storage.commit(rows, to: .calendarEvents, intent: .checkpointOnly)
        XCTAssertFalse(retry.skipped,
                       "an identical payload is NOT evidence the disk is in the right state "
                       + "while a log the writer could not delete still stands beside it")
        XCTAssertEqual(retry.mode, .checkpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path),
                       "the retry is the whole point of refusing the skip")
        XCTAssertTrue(storage.calendarDeltaLogIsEmpty)

        // And the delta path is live again, with nothing lost.
        rows[1].title = "back on the delta path"
        XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)
        let cold = makeStorage()
        XCTAssertEqual(readRows(cold)?.prefix(2).map(\.title),
                       ["a delta to leave behind", "back on the delta path"])
    }

    // MARK: - A-F2: `.io` moves not one byte

    /// The posture, asserted as a posture: an unreadable log is left exactly
    /// where it was, at exactly the size it was, and nothing lands in
    /// `quarantine/`. `.decode` is the branch that may move bytes; `.io` is
    /// not, because the file may be perfectly good.
    func testAnUnreadableLogIsFrozenWithoutMovingAByte() throws {
        let storage = makeStorage()
        var rows = events(4)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "only in the log"
        XCTAssertEqual(try storage.commit(rows, to: .calendarEvents).mode, .delta)

        let before = try Data(contentsOf: try logURL())
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: try logURL().path)

        let cold = makeStorage()
        guard case .unreadable(.ioError) = cold.read(.calendarEvents, as: Event.self) else {
            return XCTFail("an unreadable log is `.ioError`, never an empty log")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: try logURL().path)
        XCTAssertEqual(try Data(contentsOf: try logURL()), before,
                       "not one byte may be moved for a file that merely would not read once")
        let quarantined = (try? FileManager.default
            .contentsOfDirectory(atPath: try quarantineDirectory().path)) ?? []
        XCTAssertTrue(quarantined.isEmpty,
                      "`.io` must not quarantine — that is the `.decode` branch's job; saw \(quarantined)")

        // And the edit is still there once the permission is back.
        let healed = makeStorage()
        XCTAssertEqual(readRows(healed)?.first?.title, "only in the log")
    }

    // MARK: - A-F3: the window edge

    /// The backwards scan walks in 64 KB windows. A torn tail whose length
    /// lands exactly on a window boundary is where an off-by-one in the loop
    /// shows up — and an off-by-one here truncates a COMPLETE record.
    func testATornTailEndingExactlyOnAWindowBoundaryKeepsEveryCompleteRecord() throws {
        _ = makeStorage()
        let log = CalendarDeltaLog(fileURL: try logURL())
        let digest = CalendarDeltaFold.orderDigest(events(2).map(\.id))
        let first = CalendarDeltaRecord(base: 1, seq: 2, order: nil, orderDigest: digest,
                                        count: 2, changed: [event(0, title: "survivor")],
                                        dominoLastPush: nil)
        XCTAssertNotNil(log.append(first))

        // Exactly one window of un-terminated garbage, so the boundary sits on
        // the seam between the first scan window and the second.
        let handle = try FileHandle(forUpdating: try logURL())
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: "x", count: 64 * 1024).utf8))
        try handle.close()

        let second = CalendarDeltaRecord(base: 1, seq: 3, order: nil, orderDigest: digest,
                                         count: 2, changed: [event(1)], dominoLastPush: nil)
        XCTAssertNotNil(log.append(second))
        let records = try XCTUnwrap(log.loadRecords())
        XCTAssertEqual(records.map(\.seq), [2, 3])
        XCTAssertEqual(records.first?.changed.first?.title, "survivor",
                       "the complete record before the tear is not the tear")
    }

    // MARK: - No data loss, with the round-2 paths in the mix

    /// The round-1 witness re-run over the surfaces round 2 added: kill-switch
    /// flips, forced background checkpoints, bulk deletes that trip the shrink
    /// guard, and no-op saves — interleaved pseudo-randomly, with a COLD read
    /// after every single step compared against an array this test maintains
    /// itself.
    ///
    /// Seeded, so a failure is reproducible from the test name alone.
    func testARandomSequenceAcrossKillSwitchFlipsAndCheckpointsNeverLosesARow() throws {
        var rng = SplitMix64(seed: 0x2352)
        let storage = makeStorage()
        var expected = events(40)
        _ = try storage.commit(expected, to: .calendarEvents, intent: .destructive)
        var nextID = 40

        for step in 0..<60 {
            switch Int.random(in: 0..<7, using: &rng) {
            case 0:
                var row = expected[Int.random(in: 0..<expected.count, using: &rng)]
                row.title = "s\(step)"
                expected = expected.map { $0.id == row.id ? row : $0 }
            case 1:
                expected.append(event(nextID, title: "added-\(step)"))
                nextID += 1
            case 2 where expected.count > 6:
                expected.remove(at: Int.random(in: 0..<expected.count, using: &rng))
            case 3 where expected.count > 6:
                expected.swapAt(0, expected.count - 1)
            case 4:
                defaults.set(Bool.random(using: &rng),
                             forKey: DurableEventStorage.calendarDeltaLogEnabledKey)
            case 5 where expected.count > 20:
                expected = Array(expected.prefix(5))        // a >50% shrink
            default:
                break                                        // a no-op save
            }

            let intent: WriteIntent = Int.random(in: 0..<8, using: &rng) == 0
                ? .checkpointOnly : .normal
            _ = try storage.commit(expected, to: .calendarEvents, intent: intent)

            let cold = makeStorage()
            guard let served = readRows(cold) else { return XCTFail("cold read failed at step \(step)") }
            XCTAssertEqual(served.map(\.id), expected.map(\.id), "ORDER at step \(step)")
            XCTAssertEqual(served.map(\.title), expected.map(\.title), "BODIES at step \(step)")
            XCTAssertFalse(cold.isFrozen(.calendarEvents), "frozen at step \(step)")
        }
    }
}
