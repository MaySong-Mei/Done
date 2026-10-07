//
//  CalendarDeltaLogQATests.swift
//  DoneTests
//
//  INDEPENDENT QA for gh#235 (`fix/calendar-events-delta-log-235`).
//
//  Written against the SPEC, not against the implementation's own test file.
//  Every expected value here is derived in this file — the random-sequence
//  witness maintains its own array and never asks the store what it should
//  have written, the per-property witness proves its own exhaustiveness with
//  `Mirror` arithmetic rather than a hand-maintained count in a comment, and
//  the byte-freeze witness builds its reference from a SECOND store that was
//  never allowed onto the delta path at all.
//
//  The four load-bearing claims this file is here to hold down:
//
//   1. EXACTNESS. `fold(checkpoint, log)` equals, element for element and in
//      order, the array a pure whole-array write path would have written —
//      under an arbitrary interleaving of creates, deletes, body edits,
//      reorders, bulk edits, forced checkpoints and no-op saves.
//   2. IDEMPOTENCE. Replaying a log over a base that already incorporates it
//      is a fixed point (the second net under the rename/clear crash window).
//   3. NO DATA LOSS. The regression gh#219's QA pass caught on the
//      conversation twin — an append that failed, followed by a successful
//      write of something ELSE, losing the failed write's rows permanently,
//      with the degraded flag silently cleared — must be unreachable here.
//      This is the heaviest item: `.calendarEvents` is the primary user data.
//   4. CONSUMER EQUIVALENCE. Everything downstream of `rawCalendarEvents`,
//      the freeze predicate the three export gates share, the `onSlotCommitted`
//      telemetry seam, the Domino stamp and `committedSeq` behave exactly as
//      they did on the whole-array path.
//
//  "New store over the same directory" is the process-death idiom throughout:
//  no in-memory state survives it, so an assertion after one is an assertion
//  about bytes on disk.
//

import XCTest
@testable import Done

@MainActor
final class CalendarDeltaLogQATests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDeltaLogQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        // Permissions are the one fixture that can outlive a failing test and
        // break the NEXT one's teardown, so they are restored defensively.
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

    // MARK: - Deterministic randomness

    /// SplitMix64. A seeded generator, not `SystemRandomNumberGenerator`: a
    /// fold-equality failure has to be reproducible from the test name alone,
    /// and a flaky witness for a durability property is worse than none.
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

    // MARK: - Fixtures

    /// Fixed instants. An `Event` round-trips through JSON in every one of
    /// these tests; a wall-clock date invites a precision-shaped flake that
    /// reads like a fold bug.
    private static let epoch = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func event(_ index: Int, title: String? = nil) -> Event {
        let start = Self.epoch.addingTimeInterval(Double(index) * 3600)
        return Event(
            id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!,
            title: title ?? "qa-\(index)",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
            createdAt: Self.epoch,
            type: "Study"
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
    private func backupURL() throws -> URL {
        try directory().appendingPathComponent(StorageSlot.calendarEvents.backupFilename)
    }
    private func logURL() throws -> URL {
        try directory().appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
    }
    private func quarantineDirectory() throws -> URL {
        try directory().appendingPathComponent("quarantine", isDirectory: true)
    }
    private func snapshotsDirectory() throws -> URL {
        try directory().appendingPathComponent("snapshots", isDirectory: true)
    }

    /// The rows half of a slot file — everything after the header line. This
    /// is what RED LINE 1 freezes; the header legitimately carries a new
    /// `seq` and `writtenAt` on every commit.
    private func rowBytes(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        return Data(data[(newline + 1)...])
    }

    private func readRows(_ storage: DurableEventStorage,
                          file: StaticString = #filePath, line: UInt = #line) -> [Event]? {
        switch storage.read(.calendarEvents, as: Event.self) {
        case .loaded(let envelope, _): return envelope.rows
        case .fresh:
            XCTFail("expected .loaded, got .fresh", file: file, line: line); return nil
        case .unreadable(let fault):
            XCTFail("expected .loaded, got .unreadable(\(fault))", file: file, line: line); return nil
        }
    }

    private func readEnvelope(_ storage: DurableEventStorage,
                              file: StaticString = #filePath,
                              line: UInt = #line) -> SlotEnvelope<Event>? {
        switch storage.read(.calendarEvents, as: Event.self) {
        case .loaded(let envelope, _): return envelope
        case let other:
            XCTFail("expected .loaded, got \(other)", file: file, line: line); return nil
        }
    }

    /// Records as they sit on disk, decoded by this file rather than by the
    /// class under test — so a reader bug cannot hide behind itself.
    private func logRecordsOnDisk() throws -> [CalendarDeltaRecord] {
        let data = (try? Data(contentsOf: try logURL())) ?? Data()
        guard !data.isEmpty else { return [] }
        var segments = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        segments.removeLast()
        return try segments.filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(CalendarDeltaRecord.self, from: Data($0.utf8))
        }
    }

    /// `XCTAssertEqual` on two `[Event]` prints two walls of text. This says
    /// WHICH index disagreed and in which direction, because a fold bug's
    /// signature (one row stale, or the order permuted) is invisible in a diff
    /// of 40 encoded events.
    private func assertSameArray(_ actual: [Event], _ expected: [Event], _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(what): row count", file: file, line: line)
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), "\(what): ORDER", file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() where pair.0 != pair.1 {
            XCTFail("\(what): row \(index) (id \(pair.0.id)) differs — "
                    + "got title=\(pair.0.title) note=\(pair.0.note) depth=\(pair.0.colorDepth), "
                    + "expected title=\(pair.1.title) note=\(pair.1.note) depth=\(pair.1.colorDepth)",
                    file: file, line: line)
        }
    }

    // MARK: - 0. Positive controls
    //
    // Everything below asserts that something did NOT happen. These two
    // assert that the rig can see something happening at all — without them
    // a green run could mean "the delta path was never entered".

    /// POSITIVE CONTROL A. The subject exists: an ordinary edit lands as a
    /// delta, writes a log file, and the rows come back from a cold reader.
    /// If this goes red, every "nothing was lost" result below is vacuous.
    func testPositiveControlAnOrdinaryEditActuallyTakesTheDeltaPath() throws {
        let storage = makeStorage()
        let base = events(6)
        let first = try storage.commit(base, to: .calendarEvents)
        XCTAssertEqual(first.mode, .checkpoint, "the first write has no base to diff against")

        var next = base
        next[3].title = "edited"
        let second = try storage.commit(next, to: .calendarEvents)
        XCTAssertEqual(second.mode, .delta, "an ordinary edit must not re-encode the whole array")
        XCTAssertEqual(second.changedRowCount, 1)
        XCTAssertLessThan(second.bytes, first.bytes / 2, "a delta that is not smaller is not a delta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path))
        XCTAssertEqual(try logRecordsOnDisk().count, 1)

        assertSameArray(readRows(makeStorage()) ?? [], next, "cold read after one delta")
    }

    /// POSITIVE CONTROL B (the harness-first requirement's simulator half).
    /// "Turning it on produces a matching log line" is a hard requirement of
    /// this branch, and the device A/B greps for exactly these tokens. A
    /// receipt that is right while the trail line is not built from it would
    /// make the device measurement unreadable, so the trail line itself is
    /// asserted, not the receipt.
    func testPositiveControlTheDeviceTrailCarriesTheModeAndTheNewCostFields() {
        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }

        let store = makeStore()
        store.addCalendarEvent(event(0))          // checkpoint (no base yet)
        store.addCalendarEvent(event(1))          // delta
        var edited = store.rawCalendarEvents[1]
        edited.title = "scrubbed"
        store.updateCalendarEvent(edited)         // delta

        let text = DiagnosticTrail.combinedText()
        XCTAssertTrue(text.contains("save calendarEvents:"), "the existing forensic line must survive")
        XCTAssertTrue(text.contains("mode=delta"),
                      "a device A/B separates the two paths with `grep mode=`; got:\n\(text.suffix(1200))")
        XCTAssertTrue(text.contains("mode=checkpoint"),
                      "`mode=` must be on BOTH paths or the grep only sees half the population")
        XCTAssertTrue(text.contains("changed="), "delta lines must carry the changed-row count")
        XCTAssertTrue(text.contains("diffMs="),
                      "diffMs is the one NEW main-thread cost; unmeasured it cannot be judged")
        XCTAssertTrue(text.contains("logBytes="))
        XCTAssertTrue(text.contains("load: calendar="), "the load-side half of the contract")
        XCTAssertTrue(text.contains("deltaRecords="))
        XCTAssertTrue(text.contains("foldMs="))
    }

    // MARK: - 1. Fold equality (RED LINE 3), derived independently

    /// EXACTNESS under an arbitrary change sequence.
    ///
    /// The expected array is maintained HERE, by applying each operation to a
    /// local copy. The store is handed that copy and never consulted about
    /// what it should contain. Then a brand-new storage instance reads the
    /// directory — so the comparison is against bytes, not against anything
    /// still in memory.
    ///
    /// The op mix is chosen to exercise every shape the record format can
    /// take: body-only edits (inherited `order`), creates and deletes and
    /// reorders (explicit `order`), bulk edits (many rows in one record),
    /// no-op saves (the empty delta), and forced checkpoints (so the chain
    /// crosses generation boundaries rather than being one long log).
    func testFoldEqualsWhatTheWholeArrayWriteWouldHaveWrittenUnderRandomChangeSequences() throws {
        for seed in [UInt64(1), 20_250_922, 0xDEAD_BEEF] {
            TestStorage.tearDown(suiteName)
            location = TestStorage.reset(suiteName)

            var rng = SplitMix64(seed: seed)
            let storage = makeStorage()

            var expected = events(24)
            var nextID = 24
            _ = try storage.commit(expected, to: .calendarEvents, intent: .destructive)

            var deltaWrites = 0
            var checkpointWrites = 0
            var log: [String] = []

            for round in 0..<60 {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0:  // create
                    var fresh = event(nextID, title: "created-\(round)")
                    fresh.note = "round \(round)"
                    nextID += 1
                    let at = Int.random(in: 0...expected.count, using: &rng)
                    expected.insert(fresh, at: at)
                    log.append("create@\(at)")
                case 1:  // delete
                    if !expected.isEmpty {
                        let at = Int.random(in: 0..<expected.count, using: &rng)
                        expected.remove(at: at)
                        log.append("delete@\(at)")
                    }
                case 2:  // reorder (pure permutation, no body change)
                    if expected.count > 2 {
                        let a = Int.random(in: 0..<expected.count, using: &rng)
                        let b = Int.random(in: 0..<expected.count, using: &rng)
                        expected.swapAt(a, b)
                        log.append("swap(\(a),\(b))")
                    }
                case 3:  // bulk body edit
                    for index in expected.indices where index % 3 == 0 {
                        expected[index].colorDepth += 0.125
                    }
                    log.append("bulk")
                case 4:  // no-op save (the empty delta)
                    log.append("noop")
                case 5:  // forced checkpoint — the background edge
                    _ = try storage.commit(expected, to: .calendarEvents, intent: .checkpointOnly)
                    checkpointWrites += 1
                    log.append("checkpoint")
                    continue
                case 6:  // move a range (a drag across several rows)
                    if expected.count > 4 {
                        let from = Int.random(in: 0..<expected.count, using: &rng)
                        let row = expected.remove(at: from)
                        let to = Int.random(in: 0...expected.count, using: &rng)
                        expected.insert(row, at: to)
                        log.append("move(\(from)->\(to))")
                    }
                default: // ordinary body edit (the dogfood case: drag/resize/tick)
                    if !expected.isEmpty {
                        let at = Int.random(in: 0..<expected.count, using: &rng)
                        expected[at].title = "edit-\(round)"
                        expected[at].isDone.toggle()
                        let shift = Double(round) * 60
                        expected[at].timeRanges = expected[at].timeRanges.map {
                            .init(start: $0.start.addingTimeInterval(shift),
                                  end: $0.end.addingTimeInterval(shift))
                        }
                        log.append("edit@\(at)")
                    }
                }

                let receipt = try storage.commit(expected, to: .calendarEvents)
                switch receipt.mode {
                case .delta where !receipt.skipped: deltaWrites += 1
                case .checkpoint where !receipt.skipped: checkpointWrites += 1
                default: break
                }
            }

            // The rig must have exercised the thing under test.
            XCTAssertGreaterThan(deltaWrites, 30,
                                 "seed \(seed): too few delta writes to be a witness (\(log.joined(separator: " ")))")

            let cold = readRows(makeStorage()) ?? []
            assertSameArray(cold, expected,
                            "seed \(seed) after \(log.count) ops [\(log.joined(separator: " "))]")
        }
    }

    /// IDEMPOTENCE, on a chain produced by the same random machinery rather
    /// than on a hand-built three-record fixture: folding a log over a base
    /// that ALREADY incorporates it must be a fixed point. This is the second
    /// net under the "killed between `rename` and `clear`" window — the first
    /// being the generation comparison, which this test deliberately bypasses
    /// by calling `fold` directly.
    func testFoldingALogOverABaseThatAlreadyContainsItIsAFixedPoint() throws {
        var rng = SplitMix64(seed: 42)
        let storage = makeStorage()
        var expected = events(12)
        let baseSeq = try storage.commit(expected, to: .calendarEvents, intent: .destructive).seq
        let checkpoint = expected

        for round in 0..<12 {
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: expected.append(event(100 + round, title: "new-\(round)"))
            case 1: if expected.count > 3 { expected.remove(at: 1) }
            case 2: if expected.count > 3 { expected.swapAt(0, expected.count - 1) }
            default: expected[0].note = "note-\(round)"
            }
            _ = try storage.commit(expected, to: .calendarEvents)
        }

        let records = try logRecordsOnDisk()
        XCTAssertFalse(records.isEmpty, "nothing to replay means nothing is being tested")

        // First fold: checkpoint ⊕ log == the array the caller last handed in.
        guard case .success(let once) = CalendarDeltaFold.fold(
            base: checkpoint, baseSeq: baseSeq, baseStamp: nil, records: records) else {
            return XCTFail("the first fold refused")
        }
        assertSameArray(once.rows, expected, "checkpoint ⊕ log")

        // Second fold: the SAME records over a base that already contains
        // them — exactly what a launch after "checkpoint renamed, log not yet
        // cleared" replays.
        guard case .success(let twice) = CalendarDeltaFold.fold(
            base: once.rows, baseSeq: baseSeq, baseStamp: nil, records: records) else {
            return XCTFail("the replay over an absorbing base refused")
        }
        assertSameArray(twice.rows, once.rows, "replay over an absorbing base")
        XCTAssertEqual(twice.seq, once.seq)
    }

    /// EXHAUSTIVENESS of the change detector, proved by arithmetic rather than
    /// by a count in a comment.
    ///
    /// `delta(from:to:)` decides "did this row change?" with `Event.==`. If a
    /// property is ever added to `Event` and excluded from that comparison —
    /// by a custom `==`, by an `Equatable` conformance narrowed for some other
    /// reason — then edits to it would produce NO record and be lost at the
    /// next launch, silently. So every stored property gets a minimal mutation
    /// and must produce a record, and the set of properties covered is checked
    /// against `Mirror` so that adding a 43rd property fails this test instead
    /// of quietly widening the hole.
    func testEveryStoredPropertyOfEventIsSeenByTheChangeDetector() {
        let base = event(0)

        var mutations: [String: (inout Event) -> Void] = [
            "id": { $0.id = UUID(uuidString: "10000000-0000-0000-0000-000000009999")! },
            "title": { $0.title += "!" },
            "note": { $0.note += "x" },
            "location": { $0.location = "here" },
            "timeRanges": { $0.timeRanges = [] },
            "deadline": { $0.deadline = Self.epoch },
            "repeatUnit": { $0.repeatUnit = .week },
            "isAllDay": { $0.isAllDay.toggle() },
            "isDone": { $0.isDone.toggle() },
            "repeatInterval": { $0.repeatInterval += 1 },
            "repeatEndType": { $0.repeatEndType = .onDate },
            "repeatEndDate": { $0.repeatEndDate = Self.epoch },
            "repeatEndCount": { $0.repeatEndCount = 3 },
            "priority": { $0.priority += 1 },
            "status": { $0.status = .archived },
            "createdAt": { $0.createdAt = Self.epoch.addingTimeInterval(1) },
            "completeAt": { $0.completeAt = Self.epoch },
            "tags": { $0.tags = ["t"] },
            "type": { $0.type = "Work" },
            "kind": { $0.kind = .todo },
            "additionalTypes": { $0.additionalTypes = ["Extra"] },
            "typeWeights": { $0.typeWeights = ["Study": 1] },
            "colorDepth": { $0.colorDepth += 0.5 },
            "recurrenceParentId": { $0.recurrenceParentId = UUID() },
            "recurrenceInstanceDate": { $0.recurrenceInstanceDate = Self.epoch },
            "recurrenceInstanceDayKey": { $0.recurrenceInstanceDayKey = 20_260_101 },
            "recurrenceExceptionDates": { $0.recurrenceExceptionDates = [Self.epoch] },
            "recurrenceExceptionDayKeys": { $0.recurrenceExceptionDayKeys = [20_260_102] },
            "timerStartedAt": { $0.timerStartedAt = Self.epoch },
            "linkedCalendarEventId": { $0.linkedCalendarEventId = UUID() },
            "linkedTodoEventId": { $0.linkedTodoEventId = UUID() },
            "listID": { $0.listID = UUID() },
            "agenticIntake": { $0.agenticIntake = AgenticIntakeRecord(rawText: "r", images: [], source: .classicFallback) },
            "suggestedLogTemplateID": { $0.suggestedLogTemplateID = "tpl" },
            "suggestedLogTemplateConfidence": { $0.suggestedLogTemplateConfidence = 0.5 },
            "suggestedLogTemplateUpdatedAt": { $0.suggestedLogTemplateUpdatedAt = Self.epoch },
            "suggestedLogTemplateSource": { $0.suggestedLogTemplateSource = .heuristic },
            "displayKind": { $0.displayKind = .interrupt },
            "interruptRelation": { $0.interruptRelation = EventInterruptRelation(parentEventID: UUID(), occurrenceDate: Self.epoch) },
            "absorbedIntoEventID": { $0.absorbedIntoEventID = UUID() },
            "wannaNotes": { $0.wannaNotes = [Event.WannaNote(text: "w")] },
            "peopleIDs": { $0.peopleIDs = [UUID()] },
        ]

        // The arithmetic. `Mirror` enumerates STORED properties only, so this
        // is the true surface of `Event.==`, and any property added without a
        // mutation here fails on the name rather than on a stale number.
        let reflected = Set(Mirror(reflecting: base).children.compactMap(\.label))
        XCTAssertEqual(Set(mutations.keys), reflected,
                       "uncovered: \(reflected.subtracting(mutations.keys).sorted()); "
                       + "stale: \(Set(mutations.keys).subtracting(reflected).sorted())")
        XCTAssertFalse(reflected.isEmpty, "Mirror produced nothing — the arithmetic would be vacuous")

        for (label, mutate) in mutations.sorted(by: { $0.key < $1.key }) {
            var changed = base
            mutate(&changed)
            XCTAssertNotEqual(changed, base, "\(label): the mutation did not change the value")

            let record = CalendarDeltaFold.delta(
                from: [base], to: [changed], base: 1, seq: 2,
                dominoLastPush: nil, persistedStamp: nil)
            guard let record else {
                XCTFail("\(label): a changed row produced NO delta record — that edit would be "
                        + "lost at the next launch, silently")
                continue
            }
            XCTAssertTrue(record.changed.contains { $0.id == changed.id },
                          "\(label): the record does not carry the changed row")
        }
        // Control: an unchanged row produces nothing, so the loop above is
        // not passing because `delta` returns a record for everything.
        XCTAssertNil(CalendarDeltaFold.delta(from: [base], to: [base], base: 1, seq: 2,
                                             dominoLastPush: nil, persistedStamp: nil))
    }

    /// Inheritance is only safe if a `nil` `order` inherits the PREVIOUS
    /// FOLDED order, not the checkpoint's. A record chain that reorders and
    /// then edits a body is the minimal witness, and it is the one an
    /// implementation that inherits from the base passes right through.
    func testAnInheritedOrderInheritsTheRunningFoldNotTheCheckpoint() {
        let base = events(4)
        var reordered = base
        reordered.swapAt(0, 3)
        var edited = reordered
        edited[1].title = "after the reorder"

        let first = CalendarDeltaFold.delta(from: base, to: reordered, base: 5, seq: 6,
                                            dominoLastPush: nil, persistedStamp: nil)
        let second = CalendarDeltaFold.delta(from: reordered, to: edited, base: 5, seq: 7,
                                             dominoLastPush: nil, persistedStamp: nil)
        XCTAssertNotNil(first?.order, "a permutation must write the order out")
        XCTAssertNil(second?.order, "a body-only edit must not pay 158 KB of UUIDs")

        guard case .success(let folded) = CalendarDeltaFold.fold(
            base: base, baseSeq: 5, baseStamp: nil,
            records: [first, second].compactMap { $0 }) else {
            return XCTFail("fold refused")
        }
        assertSameArray(folded.rows, edited, "reorder then body edit")
    }

    // MARK: - 2. Crash safety, one shape at a time

    /// A torn tail — a final segment with no terminating newline — is a write
    /// that never completed and was never confirmed to its caller. It must be
    /// dropped, the complete records before it must survive, and the NEXT
    /// append must start from a clean record boundary rather than producing a
    /// segment glued to the partial one.
    func testATornTailIsDroppedAndTheNextAppendResumesOnACleanBoundary() throws {
        let log = CalendarDeltaLog(fileURL: try logURL())
        let one = CalendarDeltaRecord(base: 1, seq: 2, order: nil,
                                      orderDigest: CalendarDeltaFold.orderDigest([]),
                                      count: 0, changed: [], dominoLastPush: nil)
        XCTAssertNotNil(log.append(one))

        // Simulate the kill: a partial record with no newline.
        let handle = try FileHandle(forUpdating: try logURL())
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"base":1,"seq":3,"cou"#.utf8))
        try handle.close()

        let survivors = try XCTUnwrap(log.loadRecords())
        XCTAssertEqual(survivors.map(\.seq), [2], "the complete record must survive the torn tail")
        XCTAssertNil(log.fault, "a torn tail is a normal crash artefact, not corruption")

        let three = CalendarDeltaRecord(base: 1, seq: 3, order: nil,
                                        orderDigest: CalendarDeltaFold.orderDigest([]),
                                        count: 0, changed: [], dominoLastPush: nil)
        XCTAssertNotNil(log.append(three))
        XCTAssertEqual(try XCTUnwrap(log.loadRecords()).map(\.seq), [2, 3],
                       "the append after a torn tail must land as its own record")
        // And on disk, by this file's own reader.
        XCTAssertEqual(try logRecordsOnDisk().map(\.seq), [2, 3])
    }

    /// The asymmetry that makes the rule above safe: a COMPLETE
    /// (newline-terminated) segment that will not decode is genuine
    /// corruption. Skipping it would present an unreadable history as a
    /// SHORTER one — and a shorter history is the one shape that gets mirrored
    /// outward by `diffSync` and the DR snapshot. So it must fault, freeze the
    /// slot, and leave the bytes in quarantine rather than in place.
    func testACompleteButUndecodableRecordFreezesTheSlotInsteadOfShorteningHistory() throws {
        let storage = makeStorage()
        let base = events(5)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)
        var next = base
        next[0].title = "landed"
        _ = try storage.commit(next, to: .calendarEvents)

        // A well-formed line that is not a record — complete, terminated, and
        // undecodable.
        let handle = try FileHandle(forUpdating: try logURL())
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"not\":\"a record\"}\n".utf8))
        try handle.close()

        let fresh = makeStorage()
        let read = fresh.read(.calendarEvents, as: Event.self)
        guard case .unreadable = read else {
            return XCTFail("a corrupt log must not serve rows; got \(read)")
        }
        XCTAssertTrue(fresh.isFrozen(.calendarEvents),
                      "the three export gates all read this predicate — an unreadable history "
                      + "must not be allowed to leave memory")

        // The unfreeze exit: the bytes are in quarantine, so the NEXT launch
        // reads a clean checkpoint instead of re-freezing forever.
        let quarantined = (try? FileManager.default.contentsOfDirectory(
            atPath: try quarantineDirectory().path)) ?? []
        XCTAssertTrue(quarantined.contains { $0.hasSuffix(".log") },
                      "the deltas must be kept for support, not deleted; saw \(quarantined)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path))

        let afterRelaunch = makeStorage()
        let rows = readRows(afterRelaunch) ?? []
        assertSameArray(rows, base, "the checkpoint the quarantine falls back to")
        XCTAssertFalse(afterRelaunch.isFrozen(.calendarEvents), "the freeze must have an exit")
    }

    /// The kill window the whole checkpoint ordering is designed around: the
    /// new checkpoint's `rename` landed, the process died before the log was
    /// cleared. The stale log must be discarded — NOT faulted; nothing is
    /// wrong — and the state must be the checkpoint's.
    func testAStaleLogSurvivingAFreshCheckpointIsDiscardedWithoutFreezing() throws {
        let storage = makeStorage()
        let base = events(8)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)
        var edited = base
        edited[2].title = "in the log"
        _ = try storage.commit(edited, to: .calendarEvents)

        // The bytes as they stand the instant before the checkpoint's rename.
        let staleLogBytes = try Data(contentsOf: try logURL())
        XCTAssertFalse(staleLogBytes.isEmpty)

        // The checkpoint lands (and clears the log, as it must).
        _ = try storage.commit(edited, to: .calendarEvents, intent: .checkpointOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path))

        // The kill: the clear never happened.
        try staleLogBytes.write(to: try logURL())

        let fresh = makeStorage()
        let rows = readRows(fresh) ?? []
        assertSameArray(rows, edited, "after a kill between rename and clear")
        XCTAssertFalse(fresh.isFrozen(.calendarEvents),
                       "this is a benign window; freezing here would banner a healthy store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path),
                       "the discarded log must be dropped, not left to be re-judged every launch")
    }

    /// The `base` three-way's third arm, from the other side: a checkpoint
    /// that went BACKWARDS under a live log (an out-of-process injection, a
    /// hand-swapped file, a restored backup) must quarantine and freeze, never
    /// serve a state that is missing the user's edits.
    func testACheckpointThatWentBackwardsUnderALiveLogFreezes() throws {
        let storage = makeStorage()
        let base = events(5)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)    // seq 1
        var second = base
        // A DIFFERENT payload, or the byte-digest skip refuses the write and
        // the generation never reaches 2 — which would leave this fixture
        // asserting against the checkpoint's own seq and prove nothing.
        second[0].title = "second checkpoint"
        _ = try storage.commit(second, to: .calendarEvents, intent: .checkpointOnly) // seq 2
        var edited = second
        edited[1].title = "logged"
        _ = try storage.commit(edited, to: .calendarEvents)                         // record base 2
        XCTAssertEqual(try logRecordsOnDisk().first?.base, 2, "the fixture must have a base to lose")

        // Forge a checkpoint with an older generation under the live log —
        // what `inject-mock-data.swift` would do if it did not delete the log.
        let primary = try primaryURL()
        let data = try Data(contentsOf: primary)
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        var header = try JSONDecoder().decode(SlotEnvelopeHeader.self,
                                              from: data[data.startIndex..<newline])
        header.seq = 1
        var forged = try JSONEncoder().encode(header)
        forged.append(0x0A)
        forged.append(contentsOf: data[(newline + 1)...])
        try forged.write(to: primary)

        let fresh = makeStorage()
        guard case .unreadable = fresh.read(.calendarEvents, as: Event.self) else {
            return XCTFail("a log standing on a generation the checkpoint never reached must freeze")
        }
        XCTAssertTrue(fresh.isFrozen(.calendarEvents))
    }

    /// An append that cannot land falls back to the whole-array checkpoint —
    /// the rung that makes "never lose an event" hold even when the log file
    /// itself is unusable.
    func testAnAppendThatCannotLandFallsBackToAWholeArrayCheckpoint() throws {
        let storage = makeStorage()
        let base = events(5)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)

        // The log path is occupied by a directory: `open(2)` for update fails.
        try FileManager.default.createDirectory(at: try logURL(), withIntermediateDirectories: false)

        var next = base
        next[4].title = "must survive anyway"
        let receipt = try storage.commit(next, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint)
        XCTAssertEqual(receipt.reason, "appendFailed")

        // `commit`'s tail clears the log on success, which removes the empty
        // directory too — so this is best-effort, not an assertion.
        try? FileManager.default.removeItem(at: try logURL())
        assertSameArray(readRows(makeStorage()) ?? [], next, "after an append failure")
    }

    // MARK: - 3. No data loss (the heaviest item)

    /// Make BOTH write paths fail at once, the way a full disk or an
    /// unwritable container does: the delta append cannot create its file and
    /// the checkpoint cannot create its temp file.
    ///
    /// Read-only-directory alone is not enough since gh#235 — an ALREADY OPEN
    /// log file keeps accepting appends through a mode-555 directory, which is
    /// correct POSIX and was the trap the implementer hit in
    /// `LegacyAllDayStraddleLoadHealTests`. So the log is removed first, which
    /// forces the append down the `createFile` branch that the directory
    /// permission does govern.
    private func blockEveryCalendarWrite() throws {
        // The LOG is made read-only rather than deleted. Deleting it would
        // also delete the records already in it, and the next append's `seq`
        // would then start at a generation the fold has no predecessor for —
        // a `seqGap` fault that is an artefact of the rig, not of the code
        // under test. Read-only keeps the append genuinely attempted and
        // genuinely refused, which is the shape gh#219's regression had.
        let log = try logURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
                      "this rig needs a live log — the fixture must have taken the delta path")
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: log.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: try directory().path)
    }

    private func unblockEveryCalendarWrite() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: try directory().path)
        let log = try logURL()
        if FileManager.default.fileExists(atPath: log.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: log.path)
        }
    }

    /// A failure scoped to the CALENDAR ALONE, with the rest of the directory
    /// perfectly writable: `rename(2)` cannot replace a non-empty directory,
    /// and a directory is not a regular file so the base signature refuses the
    /// delta path first. Every other slot keeps saving normally — which is the
    /// point, since the small slots save constantly in this app.
    private func jamCalendarPrimaryOnly() throws {
        let primary = try primaryURL()
        try? FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        try Data("occupied".utf8).write(to: primary.appendingPathComponent("occupied"))
    }

    private func unjamCalendarPrimary() throws {
        try FileManager.default.removeItem(at: try primaryURL())
    }

    /// THE regression this branch had to be designed against, reproduced on
    /// the calendar slot.
    ///
    /// On the conversation twin (gh#219) the shape was: an append fails, the
    /// caller keeps working, the NEXT write succeeds — and because the diff
    /// was taken against the last IN-MEMORY value rather than the last
    /// PERSISTED one, the failed write's rows were never in any record and
    /// were lost permanently. The whole-array path self-heals here by
    /// construction (it rewrites everything every time); a delta path does not
    /// unless it diffs against what actually reached disk.
    func testAFailedWriteFollowedByASuccessfulOneDoesNotLoseTheFailedBatch() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0))
        store.addCalendarEvent(event(1))
        XCTAssertFalse(store.persistenceDegraded)
        let before = store.rawCalendarEvents

        // Batch 1 — refused by both paths.
        try blockEveryCalendarWrite()
        store.addCalendarEvent(event(2, title: "the batch that failed"))
        XCTAssertTrue(store.persistenceDegraded, "a write the user lost must raise the banner")
        XCTAssertEqual(store.rawCalendarEvents.count, before.count + 1, "memory keeps it")

        // Batch 2 — a DIFFERENT event, written once the disk is healthy again.
        // This is the step that made the twin lose batch 1.
        try unblockEveryCalendarWrite()
        store.addCalendarEvent(event(3, title: "the batch that landed"))

        let cold = makeStore()
        XCTAssertEqual(cold.rawCalendarEvents.map(\.title).sorted(),
                       store.rawCalendarEvents.map(\.title).sorted(),
                       "the failed batch must ride along on the next successful write; "
                       + "on disk: \(cold.rawCalendarEvents.map(\.title))")
        XCTAssertTrue(cold.rawCalendarEvents.contains { $0.title == "the batch that failed" },
                      "gh#219's durability regression is back: the failed write's row is gone")
        assertSameArray(cold.rawCalendarEvents, store.rawCalendarEvents, "memory vs disk")
    }

    /// The second half of the same regression, and the half that made it
    /// SILENT: the degraded flag must not be cleared by a later write of a
    /// different slot, nor by anything short of the calendar's own bytes
    /// reaching disk.
    func testTheDegradedFlagSurvivesUntilTheCalendarItselfCatchesUp() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0))

        // Scoped to the calendar, so the other slot below genuinely succeeds.
        try jamCalendarPrimaryOnly()
        store.addCalendarEvent(event(1))
        XCTAssertTrue(store.persistenceDegraded)

        // Other slots keep saving constantly in this app. None of them is
        // evidence about the calendar.
        store.addList(TodoList(title: "unrelated", colorName: "blue"))
        XCTAssertFalse(store.writeFailedSlots.contains(.todoLists),
                       "the rig must leave the other slot writable or it proves nothing")
        XCTAssertTrue(store.persistenceDegraded,
                      "another slot's success must never clear the calendar's failure")

        try unjamCalendarPrimary()
        store.addCalendarEvent(event(2))
        XCTAssertFalse(store.persistenceDegraded, "and it must clear once the calendar lands")
        XCTAssertEqual(makeStore().rawCalendarEvents.count, 3)
    }

    /// `saveCalendarEvents() == true` is what the delete chain's photo
    /// `unlink` bets on. Exercised through the REAL four-step chain, not
    /// through `persist`: a Bool that lies here costs the user a photo with no
    /// cloud copy and no legacy fallback.
    func testARefusedDeleteKeepsThePhotosAndTheRecords() throws {
        var unlinked: [String] = []
        let store = makeStore()
        var withPhoto = event(0, title: "has a photo")
        withPhoto.agenticIntake = AgenticIntakeRecord(
            rawText: "",
            images: [AgenticIntakeImageRef(relativePath: "\(withPhoto.id.uuidString)/photo.jpg",
                                           pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1)],
            source: .classicFallback)
        store.addCalendarEvent(withPhoto)
        store.addCalendarEvent(event(1))
        store.removeAssetFiles = { refs in unlinked.append(contentsOf: refs.map(\.relativePath)) }

        try blockEveryCalendarWrite()
        store.deleteCalendarEvent(try XCTUnwrap(store.findCalendarEvent(id: withPhoto.id)))

        XCTAssertTrue(unlinked.isEmpty,
                      "the calendar commit was refused, so the event is still on disk — "
                      + "its photos must be too; unlinked \(unlinked)")
        XCTAssertTrue(store.persistenceDegraded)

        try unblockEveryCalendarWrite()
        let cold = makeStore()
        XCTAssertTrue(cold.rawCalendarEvents.contains { $0.id == withPhoto.id },
                      "a refused delete must leave the event on disk")
    }

    /// The middle state: the append succeeded but no checkpoint has been
    /// written since. `true` must mean the bytes are durable, and they must
    /// come back after process death with no background edge having run.
    func testAnAppendOnlySaveIsDurableWithoutAnyCheckpoint() {
        let store = makeStore()
        store.addCalendarEvent(event(0))
        store.addCalendarEvent(event(1))
        var edited = store.rawCalendarEvents[0]
        edited.title = "committed as a delta only"
        store.updateCalendarEvent(edited)
        XCTAssertGreaterThan(store.storage.calendarDeltaLogRecordCount, 0,
                             "the fixture must actually be in the append-only state")

        let cold = makeStore()
        XCTAssertEqual(cold.rawCalendarEvents.first?.title, "committed as a delta only")
        assertSameArray(cold.rawCalendarEvents, store.rawCalendarEvents, "append-only durability")
    }

    /// A log with no checkpoint at all is evidence the slot WAS committed, so
    /// `.fresh` — the only seedable state — must be unreachable. Folding onto
    /// `[]` would give an empty array, and `isEmpty && isSeedable` both true
    /// has six demo rows overwrite the last trace of the store.
    ///
    /// Driven through the real `seedsSampleDataIfEmpty = true` path rather
    /// than through `read`, because the three seed gates in `EventStore.load`
    /// are part of what is being asserted.
    func testALogWithNoCheckpointRefusesToLookFreshAndIsNeverSeededOver() throws {
        let storage = makeStorage()
        let base = events(4)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)
        var edited = base
        edited[0].title = "the only evidence"
        _ = try storage.commit(edited, to: .calendarEvents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path))

        // The base and every trace of it vanish; the log does not.
        try FileManager.default.removeItem(at: try primaryURL())
        try? FileManager.default.removeItem(at: try backupURL())
        try? FileManager.default.removeItem(at: try directory().appendingPathComponent("manifest.json"))

        let seeded = makeStore(seeds: true)
        XCTAssertTrue(seeded.isSlotFrozen(.calendarEvents),
                      "a surviving log proves the slot was committed — freezing is the only "
                      + "honest answer")
        XCTAssertTrue(seeded.rawCalendarEvents.isEmpty, "a frozen slot serves nothing")
        XCTAssertEqual(seeded.storage.faults[.calendarEvents], .lostAfterManifest)
        // And nothing was written over it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: try primaryURL().path),
                       "the seeder must not have written demo rows into the slot")
    }

    /// A corrupt base with a live log must NOT be silently repaired from the
    /// `.bak`: the backup is an older generation, the log's edits do not
    /// belong on it, and a promotion raises no fault and lights no banner —
    /// so the loss would be invisible while `diffSync` DELETEs the difference
    /// in the cloud.
    func testACorruptBaseWithALiveLogRefusesTheSilentBackupPromotion() throws {
        let storage = makeStorage()
        _ = try storage.commit(events(4), to: .calendarEvents, intent: .destructive)
        // A second checkpoint so a `.bak` exists at all.
        var six = events(6)
        _ = try storage.commit(six, to: .calendarEvents, intent: .checkpointOnly)
        six[0].title = "only in the log"
        _ = try storage.commit(six, to: .calendarEvents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try backupURL().path))

        try Data("not json at all\nnor here".utf8).write(to: try primaryURL())

        let fresh = makeStorage()
        switch fresh.read(.calendarEvents, as: Event.self) {
        case .loaded(let envelope, let provenance):
            XCTFail("a backup promotion under a live log served \(envelope.rows.count) rows "
                    + "from \(provenance) and dropped the log's edits silently")
        case .fresh:
            XCTFail("a store with a log and a backup is not fresh")
        case .unreadable:
            XCTAssertTrue(fresh.isFrozen(.calendarEvents))
        }
        // The evidence is kept, not deleted.
        let quarantined = (try? FileManager.default.contentsOfDirectory(
            atPath: try quarantineDirectory().path)) ?? []
        XCTAssertTrue(quarantined.contains { $0.hasSuffix(".log") }, "saw \(quarantined)")
    }

    /// The startup sweep deletes everything not on its whitelist, runs in
    /// `init` BEFORE any read, and neither raises nor trails. A log missing
    /// from that whitelist would destroy every un-checkpointed edit on every
    /// cold launch — the loudest possible bug with the quietest possible
    /// symptom.
    func testTheStartupSweepDoesNotEatTheDeltaLog() throws {
        let storage = makeStorage()
        let base = events(4)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)
        var edited = base
        edited[1].title = "swept?"
        _ = try storage.commit(edited, to: .calendarEvents)

        // A new instance runs the sweep in `init`.
        let fresh = makeStorage()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try logURL().path),
                      "the sweep ate the delta log")
        assertSameArray(readRows(fresh) ?? [], edited, "after a sweep")

        // Control: the sweep is genuinely running in this fixture.
        let debris = try directory().appendingPathComponent(".tmp-calendarEvents-debris")
        try Data("x".utf8).write(to: debris)
        _ = makeStorage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: debris.path),
                       "the sweep did not run, so the assertion above proves nothing")
    }

    /// A wipe is an erase: the log holds event PLAINTEXT (titles, notes,
    /// locations), so leaving it behind would not be one. And the reverse —
    /// creating an event AFTER a wipe — must not have that event's log
    /// deleted from under it by the next launch's wipe housekeeping.
    func testAWipeTakesTheLogAndANewEventAfterAWipeSurvivesTwoLaunches() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "secret-title-before-the-wipe"))
        store.addCalendarEvent(event(1))
        store.clearAllLocalData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path),
                       "the wipe left event plaintext in the log")
        let primaryText = String(decoding: (try? Data(contentsOf: try primaryURL())) ?? Data(),
                                 as: UTF8.self)
        XCTAssertFalse(primaryText.contains("secret-title-before-the-wipe"))

        // The reverse direction: wipe, then create.
        store.addCalendarEvent(event(2, title: "after the wipe"))
        let first = makeStore()
        XCTAssertEqual(first.rawCalendarEvents.map(\.title), ["after the wipe"],
                       "launch 1 after a post-wipe create")
        let second = makeStore()
        XCTAssertEqual(second.rawCalendarEvents.map(\.title), ["after the wipe"],
                       "launch 2 — the wiped header must no longer purge a live log")
    }

    /// The other direction of the same rule: a wipe with nothing after it
    /// stays wiped, stays seedable, and leaves no log.
    func testAWipeWithNothingAfterItStaysWipedAndSeedable() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0))
        store.clearAllLocalData()

        let cold = makeStore(seeds: false)
        XCTAssertTrue(cold.rawCalendarEvents.isEmpty)
        XCTAssertFalse(cold.isSlotFrozen(.calendarEvents))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path))
        // Seedability is what tells an intentional wipe from a never-written
        // store, and it must survive the fold.
        XCTAssertEqual(makeStore(seeds: true).rawCalendarEvents.isEmpty, false,
                       "a wiped store is still seedable")
    }

    /// A duplicated id makes `byID` collapse two rows into one, which folds to
    /// two copies of ONE body — a count that matches and contents that do not,
    /// which is exactly what exactness forbids. The writer must degrade to a
    /// checkpoint, which preserves duplicates byte for byte.
    func testADuplicatedIDDegradesToACheckpointAndKeepsBothRows() throws {
        let storage = makeStorage()
        var base = events(4)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)

        var twin = base[1]
        twin.title = "the duplicate, with a DIFFERENT body"
        base.append(twin)
        let receipt = try storage.commit(base, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint)
        XCTAssertEqual(receipt.reason, "duplicateID")
        XCTAssertEqual(try logRecordsOnDisk().count, 0)

        let cold = readRows(makeStorage()) ?? []
        assertSameArray(cold, base, "a store holding a duplicated id")
        XCTAssertEqual(cold.filter { $0.id == twin.id }.count, 2)
        XCTAssertNotEqual(cold.first { $0.id == twin.id }?.title,
                          cold.last { $0.id == twin.id }?.title,
                          "the two bodies must not have been collapsed into one")
    }

    /// One delta at or above half the checkpoint has stopped being a delta.
    /// Judged BEFORE the cumulative bound, and nothing is ever evicted to make
    /// room — "keep the newest prefix" degenerates to the empty set when one
    /// record alone exceeds the bound, which is how `MetricPayloadStore`
    /// (575483b) emptied its whole forensic store.
    func testAnOversizeSingleDeltaBecomesACheckpointAndEvictsNothing() throws {
        let storage = makeStorage()
        let base = events(40)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)

        // A small delta first, so there IS an existing record that eviction
        // could have taken.
        var small = base
        small[0].title = "small"
        _ = try storage.commit(small, to: .calendarEvents)
        XCTAssertEqual(try logRecordsOnDisk().count, 1)

        // Now touch every row — a Domino push at device scale.
        var huge = small
        for index in huge.indices {
            huge[index].note = String(repeating: "p", count: 400)
        }
        let receipt = try storage.commit(huge, to: .calendarEvents)
        XCTAssertEqual(receipt.mode, .checkpoint)
        XCTAssertEqual(receipt.reason, "single")
        XCTAssertEqual(try logRecordsOnDisk().count, 0,
                       "the log must be dropped wholesale by the checkpoint, never trimmed")
        assertSameArray(readRows(makeStorage()) ?? [], huge, "after an oversize delta")
    }

    /// The compaction bound is on the LOG's bytes, which reset after each
    /// checkpoint — so a large store can never be made to re-checkpoint on
    /// every append (`SpikeRunStore`'s R-F3 thrash). Derived here rather than
    /// read off the implementation.
    func testTheCompactionBoundIsOnTheLogAndDoesNotThrash() throws {
        // Arithmetic, derived from the stated rule: floor 64 KB, ceiling
        // 512 KB, otherwise a quarter of the checkpoint.
        XCTAssertEqual(DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 5_000),
                       65_536, "a tiny new-user store must not carry a 512 KB log")
        XCTAssertEqual(DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 1_000_000),
                       250_000)
        XCTAssertEqual(DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 2_042_172),
                       510_543, "the dogfood device's 2.04 MB store")
        XCTAssertEqual(DurableEventStorage.calendarCompactionThreshold(checkpointBytes: 8_000_000),
                       524_288, "the ceiling binds above ~2.1 MB")
        XCTAssertEqual(DurableEventStorage.calendarSingleDeltaCeiling(checkpointBytes: 2_042_172),
                       1_021_086)
        XCTAssertEqual(DurableEventStorage.calendarSingleDeltaCeiling(checkpointBytes: 1_000),
                       32_768, "the single-record floor")

        // And behaviourally: many small appends eventually checkpoint ONCE,
        // then start a fresh budget rather than checkpointing every time.
        let storage = makeStorage()
        var rows = events(30)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        var modes: [CommitMode] = []
        for round in 0..<220 {
            rows[round % rows.count].note = String(repeating: "n", count: 300) + "\(round)"
            modes.append(try storage.commit(rows, to: .calendarEvents).mode)
        }
        let checkpoints = modes.filter { $0 == .checkpoint }.count
        XCTAssertGreaterThan(checkpoints, 0, "the bound must eventually bind")
        XCTAssertLessThan(checkpoints, modes.count / 4,
                          "checkpointing this often is the thrash the log-byte bound exists "
                          + "to prevent (\(checkpoints)/\(modes.count))")
        assertSameArray(readRows(makeStorage()) ?? [], rows, "after compaction cycles")
    }

    /// COMPLETENESS (G6). An id in `order` that resolves in neither the base
    /// nor any `changed` is corruption. `compactMap` would turn it into a
    /// SHORTER array — and short is the one shape that propagates: `diffSync`
    /// DELETEs the difference in the cloud, the DR snapshot writes it down,
    /// and the asset sweep unlinks the photos of the rows it no longer sees.
    /// The count and digest guards do NOT catch this: `order` itself is
    /// intact, it is the resolution that fails.
    func testAnOrderEntryThatResolvesNowhereFaultsInsteadOfShorteningTheArray() {
        let base = events(3)
        let ghost = UUID(uuidString: "10000000-0000-0000-0000-000000009001")!
        let order = base.map(\.id) + [ghost]
        let record = CalendarDeltaRecord(
            base: 4, seq: 5, order: order,
            orderDigest: CalendarDeltaFold.orderDigest(order),
            count: order.count, changed: [], dominoLastPush: nil)

        switch CalendarDeltaFold.fold(base: base, baseSeq: 4, baseStamp: nil, records: [record]) {
        case .success(let folded):
            XCTFail("an unresolvable id produced \(folded.rows.count) rows and presented them as "
                    + "history — `compactMap` here is how an unreadable store becomes a shorter one")
        case .failure(let fault):
            XCTAssertEqual(fault, .danglingID(ghost))
        }

        // Control: the same shape WITHOUT the ghost folds fine, so the failure
        // above is the ghost and not the fixture.
        let clean = CalendarDeltaRecord(
            base: 4, seq: 5, order: base.map(\.id),
            orderDigest: CalendarDeltaFold.orderDigest(base.map(\.id)),
            count: base.count, changed: [], dominoLastPush: nil)
        guard case .success = CalendarDeltaFold.fold(base: base, baseSeq: 4, baseStamp: nil,
                                                     records: [clean]) else {
            return XCTFail("the control fixture does not fold")
        }
    }

    /// The byte-digest skip answers "are these bytes the last CHECKPOINT
    /// payload?", which stopped being the same question as "does the disk
    /// already hold this array?" the moment a log could stand on top of that
    /// checkpoint. Skipping there returns `true` — which the delete chain's
    /// photo `unlink` and gh#207's one-shot heal flag both spend — while the
    /// disk folds to something else entirely.
    func testASaveMatchingTheLastCheckpointIsNotSkippedWhileALogStandsOnIt() throws {
        let storage = makeStorage()
        let base = events(4)
        _ = try storage.commit(base, to: .calendarEvents, intent: .destructive)

        var plus = base
        plus.append(event(9, title: "lives only in the log"))
        XCTAssertEqual(try storage.commit(plus, to: .calendarEvents).mode, .delta)

        // Force the checkpoint path (where the digest skip lives) by refusing
        // the append. The payload below is byte-identical to the last
        // checkpoint's, which is precisely the trap.
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: try logURL().path)
        let receipt = try storage.commit(base, to: .calendarEvents)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: try logURL().path)

        XCTAssertFalse(receipt.skipped,
                       "the digest matched the last checkpoint, but the disk folds to the LOG — "
                       + "reporting this save as already-done is the Bool lying")
        assertSameArray(readRows(makeStorage()) ?? [], base,
                        "the save that reported success must actually be on disk")
    }

    // MARK: - 4. Consumer equivalence

    /// `onSlotCommitted` counts WRITES. It must not collapse from "one per
    /// edit" to "one per few hundred edits" — `ResidentObservationTests`
    /// records that this counter has flat-lined before — and it must not fire
    /// for a save that performed no I/O.
    func testEverySuccessfulWriteFiresExactlyOneSlotCommitAndAnEmptyOneFiresNone() {
        let store = makeStore()
        store.addCalendarEvent(event(0))
        store.addCalendarEvent(event(1))

        var commits = 0
        store.onSlotCommitted = { slot, _ in if slot == .calendarEvents { commits += 1 } }

        for index in 0..<5 {
            var edited = store.rawCalendarEvents[0]
            edited.title = "edit-\(index)"
            store.updateCalendarEvent(edited)
        }
        XCTAssertEqual(commits, 5, "the telemetry seam must still see one write per edit")

        // A save whose array is already on disk does no I/O.
        commits = 0
        _ = store.saveCalendarEvents(refreshInterrupts: false)
        XCTAssertEqual(commits, 0, "a zero-I/O save must not be counted as a write")
    }

    /// The Domino stamp rides in the SAME record as the rows it describes.
    /// Losing it while keeping the rows makes the next launch re-apply the
    /// whole elapsed delta on top of already-shifted todos: silent, permanent
    /// date corruption.
    ///
    /// Asserted with REAL elapsed time and a real second shift, not by reading
    /// the stamp back — a stamp that is right while the push is wrong would
    /// walk straight through a value assertion.
    func testADominoPushOnTheDeltaPathIsNotReappliedAfterARelaunch() {
        let horizonDays = 3
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = t0.addingTimeInterval(86_400)      // one day later
        let t2 = t1.addingTimeInterval(3_600)       // one hour after that

        let store = makeStore()
        // A checkpoint first, so the push below is forced onto the delta path.
        store.addCalendarEvent(event(0))
        var todo = event(1, title: "parked in the future")
        todo.kind = .todo
        todo.timeRanges = [.init(start: t0.addingTimeInterval(86_400 * 30),
                                 end: t0.addingTimeInterval(86_400 * 30 + 3600))]
        store.addCalendarEvent(todo)
        store.flushCalendarDeltaCheckpoint()

        store.dominoPushTodosPastHorizon(now: t0, horizonDays: horizonDays)
        store.dominoPushTodosPastHorizon(now: t1, horizonDays: horizonDays)
        let afterFirstRun = store.rawCalendarEvents.first { $0.id == todo.id }?
            .timeRanges.first?.start
        XCTAssertNotNil(afterFirstRun)
        XCTAssertGreaterThan(store.storage.calendarDeltaLogRecordCount, 0,
                             "the push must have landed as a DELTA for this test to mean anything")

        // Process death, then one more hour of elapsed time.
        let cold = makeStore()
        XCTAssertEqual(cold.rawCalendarEvents.first { $0.id == todo.id }?.timeRanges.first?.start,
                       afterFirstRun, "the shifted rows must come back exactly as shifted")
        cold.dominoPushTodosPastHorizon(now: t2, horizonDays: horizonDays)

        let afterSecondRun = cold.rawCalendarEvents.first { $0.id == todo.id }?
            .timeRanges.first?.start
        XCTAssertEqual(afterSecondRun, afterFirstRun?.addingTimeInterval(3_600),
                       "the second tick must shift by the hour that elapsed, not by the day "
                       + "before it as well — a lost stamp double-shifts, silently and forever")
    }

    /// `committedSeq` is the one question a redo marker asks: "has this slot
    /// been written since I recorded my intent?" A delta append IS a write, so
    /// it must advance the generation BOTH in this process and across a
    /// relaunch. The two halves have different mechanisms (the in-memory
    /// manifest note; the reconcile from the log's tail) and each needs its
    /// own assertion — one covers the other's absence.
    func testADeltaAppendAdvancesTheGenerationInProcessAndAcrossARelaunch() throws {
        let storage = makeStorage()
        let base = events(4)
        let checkpointSeq = try storage.commit(base, to: .calendarEvents, intent: .destructive).seq
        XCTAssertEqual(storage.committedSeq(.calendarEvents), checkpointSeq)

        var edited = base
        edited[0].title = "a"
        let firstAppend = try storage.commit(edited, to: .calendarEvents)
        XCTAssertEqual(firstAppend.mode, .delta)
        XCTAssertGreaterThan(storage.committedSeq(.calendarEvents), checkpointSeq,
                             "IN PROCESS: a marker written now must not record a stale base")
        edited[1].title = "b"
        _ = try storage.commit(edited, to: .calendarEvents)
        let inProcess = storage.committedSeq(.calendarEvents)

        let relaunched = makeStorage()
        XCTAssertEqual(relaunched.committedSeq(.calendarEvents), inProcess,
                       "ACROSS A RELAUNCH: the log's tail is as much proof of a committed "
                       + "generation as the checkpoint header is")

        // And a later checkpoint must mint ABOVE it, never reuse a generation
        // a record already spent.
        let after = try relaunched.commit(edited, to: .calendarEvents, intent: .checkpointOnly)
        XCTAssertGreaterThan(after.seq, inProcess)
    }

    // The restore marker, both directions. A marker is a standing instruction
    // to overwrite five slots, and `committedSeq(slot) == base` is the ONLY
    // thing that expires it.

    private struct RestoreMarkerMirror: Codable {
        var events: [Event]
        var calendarEvents: [Event]
        var logs: [CalendarEventLogRecord]
        var feedback: [CalendarEventFeedbackRecord]
        var todoLists: [TodoList]
        var baseSeqs: [String: UInt64]
    }

    private func currentSeqs(_ store: EventStore) -> [String: UInt64] {
        let slots: [StorageSlot] = [.events, .calendarEvents, .calendarEventLogRecords,
                                    .calendarEventFeedbackRecords, .todoLists]
        return Dictionary(uniqueKeysWithValues: slots.map {
            ($0.rawValue, store.storage.committedSeq($0))
        })
    }

    /// Direction 1 — EXPIRY. A marker written right after a checkpoint (so its
    /// base equals the header's generation), then only delta edits, must be
    /// judged stale at the next launch. If a delta append's generation is not
    /// DURABLE, the reconciled seq still equals the base and the abandoned
    /// marker replays — rolling the user back to the restore instant and
    /// destroying every edit made since.
    func testAMarkerDoesNotReplayOverEditsThatOnlyEverLandedAsDeltas() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "before the marker"))
        store.flushCalendarDeltaCheckpoint()   // base == header seq: the sharp case

        let marker = RestoreMarkerMirror(
            events: [], calendarEvents: [event(9, title: "the abandoned restore")],
            logs: [], feedback: [], todoLists: [], baseSeqs: currentSeqs(store))
        _ = try store.storage.recordPendingWork(kind: "restore",
                                                payload: JSONEncoder().encode(marker))

        // Only delta edits from here on.
        store.addCalendarEvent(event(1, title: "after the marker"))
        XCTAssertGreaterThan(store.storage.calendarDeltaLogRecordCount, 0)

        let cold = makeStore()
        XCTAssertEqual(cold.rawCalendarEvents.map(\.title),
                       ["before the marker", "after the marker"],
                       "an abandoned marker replayed over work that only lived in the log")
        XCTAssertFalse(cold.rawCalendarEvents.contains { $0.title == "the abandoned restore" })
    }

    /// Direction 2 — REPAIR. The same mechanism, from the side that fails when
    /// the IN-PROCESS generation is stale: a marker written AFTER delta edits
    /// records the folded generation, so at the next launch its base still
    /// matches and the interrupted restore is finished. A marker whose base
    /// was captured behind the log can never match again, and the repair is
    /// lost forever — the failure the "kept marker" design exists to prevent.
    func testAMarkerWrittenAfterDeltaEditsStillRepairsAnInterruptedRestore() throws {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "old"))
        store.flushCalendarDeltaCheckpoint()
        store.addCalendarEvent(event(1, title: "an edit that landed as a delta"))
        XCTAssertGreaterThan(store.storage.calendarDeltaLogRecordCount, 0)

        let marker = RestoreMarkerMirror(
            events: [], calendarEvents: [event(9, title: "restored")],
            logs: [], feedback: [], todoLists: [], baseSeqs: currentSeqs(store))
        _ = try store.storage.recordPendingWork(kind: "restore",
                                                payload: JSONEncoder().encode(marker))

        let cold = makeStore()
        XCTAssertEqual(cold.rawCalendarEvents.map(\.title), ["restored"],
                       "the marker's base was captured behind the delta log, so the interrupted "
                       + "restore could never be finished")
        XCTAssertTrue(cold.storage.pendingWork(kind: "restore").isEmpty)
    }

    /// A delta-driven bulk delete deserves the same hardlinked snapshot an
    /// atomic one gets — AND the log beside it, because the checkpoint alone
    /// is only part of the pre-shrink state. Pruning then has to count
    /// SNAPSHOTS, not files, or a checkpoint and its own log count as two
    /// generations and evict the pair before last.
    func testABulkDeleteOnTheDeltaPathSnapshotsTheCheckpointAndItsLog() throws {
        let storage = makeStorage()
        var rows = events(120)
        _ = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        rows[0].title = "something in the log"
        _ = try storage.commit(rows, to: .calendarEvents)

        rows = Array(rows.prefix(20))            // a >50% shrink
        _ = try storage.commit(rows, to: .calendarEvents)

        let snapshots = (try? FileManager.default.contentsOfDirectory(
            atPath: try snapshotsDirectory().path)) ?? []
        let prefix = "\(StorageSlot.calendarEvents.rawValue)-shrink-"
        XCTAssertTrue(snapshots.contains { $0.hasPrefix(prefix) && $0.hasSuffix(".json") },
                      "saw \(snapshots)")
        XCTAssertTrue(snapshots.contains { $0.hasPrefix(prefix) && $0.hasSuffix(".log") },
                      "the pre-shrink state is checkpoint AND log; saw \(snapshots)")
    }

    /// Pruning keeps three SNAPSHOTS. Counting filenames would keep one and a
    /// half generations once each snapshot is two files.
    func testPruningKeepsThreeSnapshotGenerationsNotThreeFiles() throws {
        let storage = makeStorage()
        for generation in 0..<5 {
            var rows = events(120)
            rows[0].title = "generation-\(generation)"
            _ = try storage.commit(rows, to: .calendarEvents, intent: .checkpointOnly)
            rows[1].title = "logged-\(generation)"
            _ = try storage.commit(rows, to: .calendarEvents)   // a record in the log
            _ = try storage.commit(Array(rows.prefix(10)), to: .calendarEvents)  // shrink
            // A distinguishable timestamp for the next generation.
            usleep(3_000)
        }

        let snapshots = (try? FileManager.default.contentsOfDirectory(
            atPath: try snapshotsDirectory().path)) ?? []
        let prefix = "\(StorageSlot.calendarEvents.rawValue)-shrink-"
        let stamps = Set(snapshots.filter { $0.hasPrefix(prefix) }.map {
            $0.dropFirst(prefix.count).split(separator: ".").dropLast().joined(separator: ".")
        })
        XCTAssertEqual(stamps.count, 3,
                       "three generations must survive, not three files; saw \(snapshots.sorted())")
        for stamp in stamps {
            XCTAssertTrue(snapshots.contains("\(prefix)\(stamp).json"),
                          "generation \(stamp) lost its checkpoint half")
        }
    }

    // MARK: - 5. RED LINE 1 — the format is frozen

    /// The row bytes a delta lifecycle ends up writing must be IDENTICAL to
    /// the row bytes a pure whole-array path would have written for the same
    /// array. This is the guard on `#220`'s Lean civil theorems and the
    /// `#152 → #212` projection lineage: delta is a write STRATEGY, not a
    /// format.
    ///
    /// The reference is built in a second, independent directory whose every
    /// commit is `.destructive`, so it never touches the delta path at all.
    func testTheCheckpointRowBytesAreIdenticalToTheWholeArrayPaths() throws {
        var rng = SplitMix64(seed: 7)
        var rows = events(30)

        let deltaSide = makeStorage()
        _ = try deltaSide.commit(rows, to: .calendarEvents, intent: .destructive)

        let referenceName = suiteName + "-reference"
        let referenceLocation = TestStorage.reset(referenceName)
        defer { TestStorage.tearDown(referenceName) }
        let reference = DurableEventStorage(location: referenceLocation, legacyDefaults: nil)
        _ = try reference.commit(rows, to: .calendarEvents, intent: .destructive)

        for round in 0..<25 {
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: rows.append(event(200 + round, title: "n-\(round)"))
            case 1: if rows.count > 4 { rows.remove(at: 2) }
            default: rows[round % rows.count].note = "note-\(round)"
            }
            _ = try deltaSide.commit(rows, to: .calendarEvents)                  // delta or checkpoint
            _ = try reference.commit(rows, to: .calendarEvents, intent: .destructive)
        }
        // Force the delta side to fold everything back into its checkpoint.
        _ = try deltaSide.commit(rows, to: .calendarEvents, intent: .checkpointOnly)

        let mine = try rowBytes(of: try primaryURL())
        let theirs = try rowBytes(of: try referenceLocation.directoryURL()
            .appendingPathComponent(StorageSlot.calendarEvents.filename))
        XCTAssertEqual(mine, theirs,
                       "the encoded rows diverged from the whole-array path "
                       + "(\(mine.count) B vs \(theirs.count) B)")

        // The header keys are frozen too — a consumer that reads the envelope
        // by hand (the manifest reconcile, the cold Domino read) must still
        // find what it expects.
        let header = try Data(contentsOf: try primaryURL())
        let newline = try XCTUnwrap(header.firstIndex(of: 0x0A))
        let decoded = try JSONDecoder().decode(SlotEnvelopeHeader.self,
                                               from: header[header.startIndex..<newline])
        XCTAssertEqual(decoded.count, rows.count, "the header's count must be the FOLDED count")
        XCTAssertEqual(decoded.schema, SlotEnvelopeHeader.currentSchema)
    }

    // MARK: - 6. The measurement's premise

    /// gh#235's whole claim, asserted as a property rather than a promise: an
    /// ordinary edit must write ORDERS OF MAGNITUDE fewer bytes, and must not
    /// have moved the cost somewhere else on the main thread.
    func testAnOrdinaryEditWritesOrdersOfMagnitudeFewerBytes() throws {
        let storage = makeStorage()
        let rows = events(400)
        let checkpoint = try storage.commit(rows, to: .calendarEvents, intent: .destructive)
        XCTAssertGreaterThan(checkpoint.bytes, 50_000, "the fixture must be big enough to matter")

        var edited = rows
        edited[200].isDone = true
        let delta = try storage.commit(edited, to: .calendarEvents)
        XCTAssertEqual(delta.mode, .delta)
        XCTAssertLessThan(delta.bytes * 50, checkpoint.bytes,
                          "\(delta.bytes) B vs \(checkpoint.bytes) B is not the win this branch claims")
        XCTAssertEqual(delta.encodeMs, 0, "the whole-array encode must not still be happening")
    }
}
