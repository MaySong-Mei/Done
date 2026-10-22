//
//  CalendarDeltaLogQARound5Tests.swift
//  DoneTests
//
//  gh#235 round 5 — INDEPENDENT QA.
//
//  WHAT ROUND 5 CLAIMS
//  -------------------
//  Round 4 taught every successful `loadRecords()` to note the log's tail into
//  the IN-MEMORY manifest, and placed that note one step ahead of the one pass
//  whose job is to make `manifest.json` DURABLE. The reconcile asked
//  `provenSeq > record.seq` / `!record.everCommitted` of a record the note had
//  already advanced, so both were false, the slot `continue`d, `changed`
//  stayed false, and `writeManifest()` plus its forensic line were skipped.
//  Round 5 splits the two questions: `durable` (the record as `manifest.json`
//  says it) decides WHETHER to write, `record` (the in-memory one) is WHAT is
//  written.
//
//  HOW THIS FILE IS INDEPENDENT OF THE IMPLEMENTER'S OWN PINS
//  ----------------------------------------------------------
//  Its own epoch, its own UUID namespace, its own raw byte decoders, and — the
//  part that matters — its own fixture SHAPE on both sides of the seam:
//
//    * the WRITE side is the product API (`EventStore.addCalendarEvent` /
//      `flushCalendarDeltaCheckpoint`), not `DurableEventStorage.commit`. The
//      property has to hold for logs the app actually writes, not only for
//      ones a storage fixture wrote.
//    * the READ side is a BARE `DurableEventStorage`, constructed and then
//      immediately interrogated. `init` runs exactly `readManifest()` and
//      `reconcileManifestWithPrimaryHeaders()`, so any byte that appears in
//      `manifest.json` during that launch is attributable to the reconcile and
//      to nothing else.
//    * every fixture below first DELETES every artifact except the calendar's
//      own. Under the round-4 behaviour a sibling slot whose header outruns a
//      vanished manifest would set `changed` on its own account, and
//      `writeManifest()` writes the WHOLE in-memory manifest — carrying the
//      note-advanced calendar record out to disk as a side effect and turning
//      these probes green for the wrong reason. Leaving the calendar alone in
//      the directory is what makes a green here mean the reconcile wrote it.
//
//  FALSIFICATION
//  -------------
//  Four mutants were built and run, and each test below records what it did
//  under them:
//
//    M1  `durable` read from `manifest.slots` instead of the pre-loop snapshot
//        — i.e. round-4 behaviour restored. KILLED, on their own assertions, by
//        3 of the 5 below plus the implementer's two round-5 pins. A 4th (the
//        idempotence control) goes red on its PRECONDITION, which is not a kill
//        and is not counted as one.
//    M2  `if changed { writeManifest() }` -> unconditional `writeManifest()`.
//        KILLED by exactly ONE of the 136 gh#235 tests: the idempotence control
//        below. Nothing else in the family notices a perf-motivated branch
//        growing a manifest write on every launch.
//    M3  `record.seq = max(record.seq, provenSeq)` -> plain assignment.
//        SURVIVES all 136 gh#235 tests, and is EQUIVALENT rather than
//        uncovered: inside this pass `provenSeq >= tail` and `record.seq ==
//        max(durable.seq, tail)`, and the branch is only entered when
//        `durable.seq < provenSeq`, so `record.seq <= provenSeq` always and the
//        `max` can never choose the left operand. It is a guard against a
//        future caller, not against today's.
//    M4  the snapshot moved to the top of the loop BODY (still ahead of the
//        log read). SURVIVES, also equivalent today — which is what the code's
//        own comment claims for it ("so REORDERING that read cannot re-open the
//        gap"), so the comment is honest about being future-proofing.
//

import XCTest
@testable import Done

@MainActor
final class CalendarDeltaLogQARound5Tests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDeltaLogQARound5Tests-\(UUID().uuidString)"
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

    // MARK: - Fixtures (this file's own)

    private static let epoch = Date(timeIntervalSinceReferenceDate: 820_000_000)

    private func event(_ index: Int, title: String? = nil) -> Event {
        let start = Self.epoch.addingTimeInterval(Double(index) * 3600)
        return Event(
            id: UUID(uuidString: String(format: "50000000-0000-0000-0000-%012d", index))!,
            title: title ?? "qa5-\(index)",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
            createdAt: Self.epoch
        )
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    /// A launch that can do nothing BUT reconcile — see the file header.
    private func coldLaunch() -> DurableEventStorage {
        DurableEventStorage(location: location, legacyDefaults: nil, flagDefaults: defaults)
    }

    private func directory() throws -> URL { try location.directoryURL() }
    private func primaryURL() throws -> URL {
        try directory().appendingPathComponent(StorageSlot.calendarEvents.filename)
    }
    private func logURL() throws -> URL {
        try directory().appendingPathComponent(StorageSlot.calendarEvents.deltaFilename)
    }
    private func manifestURL() throws -> URL {
        try directory().appendingPathComponent("manifest.json")
    }

    // MARK: - Raw readers (never the class under test)

    /// The whole slot record, not just its seq: `everCommitted` is the half the
    /// durability consequence hangs on. `nil` distinguishes "no manifest file
    /// at all" from "a manifest that records nothing for this slot" — both are
    /// states these probes start from deliberately.
    private func rawManifestRecord() throws -> StorageManifest.SlotRecord? {
        guard let data = try? Data(contentsOf: try manifestURL()) else { return nil }
        return try JSONDecoder().decode(StorageManifest.self, from: data)
            .slots[StorageSlot.calendarEvents.rawValue]
    }

    private func manifestExists() throws -> Bool {
        FileManager.default.fileExists(atPath: try manifestURL().path)
    }

    /// The checkpoint header's generation, decoded here from the first line of
    /// the primary rather than asked of `DurableEventStorage`.
    private func rawHeaderSeq() throws -> UInt64 {
        let data = try Data(contentsOf: try primaryURL())
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        let object = try JSONSerialization.jsonObject(with: data[data.startIndex..<newline])
        return try XCTUnwrap((object as? [String: Any])?["seq"] as? NSNumber).uint64Value
    }

    private func rawRecordSeqs() throws -> [UInt64] {
        let data = try Data(contentsOf: try logURL())
        var segments = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        segments.removeLast()
        return try segments.filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(CalendarDeltaRecord.self, from: Data($0.utf8)).seq
        }
    }

    /// A sentinel `mtime`, far enough in the past that no clock skew can
    /// produce it. `writeManifest` writes a temp file and `rename`s it over the
    /// target, so ANY rewrite replaces the inode and with it this stamp — which
    /// makes "was the file rewritten at all?" answerable without diffing bytes
    /// that may legitimately be identical.
    private static let mtimeSentinel = Date(timeIntervalSince1970: 400_000_000)

    private func stampManifestMtime() throws {
        try FileManager.default.setAttributes([.modificationDate: Self.mtimeSentinel],
                                              ofItemAtPath: try manifestURL().path)
    }

    private func manifestMtime() throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: try manifestURL().path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    /// Everything the app wrote except the calendar's own artifacts. See the
    /// file header for why a sibling slot left standing would make these probes
    /// pass for the wrong reason.
    private func keepOnlyCalendarArtifacts(manifest keepManifest: Bool) throws {
        let fm = FileManager.default
        var keep: Set<String> = [StorageSlot.calendarEvents.filename,
                                 StorageSlot.calendarEvents.deltaFilename]
        if keepManifest { keep.insert("manifest.json") }
        for entry in try fm.contentsOfDirectory(atPath: try directory().path) where !keep.contains(entry) {
            try fm.removeItem(at: try directory().appendingPathComponent(entry))
        }
    }

    /// checkpoint + ONE delta append on top of it, written through the product
    /// API. Returns the checkpoint's generation; the log stands at that plus
    /// one and `manifest.json` still says the checkpoint's, because an append
    /// is in-memory-only by design.
    @discardableResult
    private func logOneGenerationAheadOfTheManifest() throws -> UInt64 {
        let store = makeStore()
        store.addCalendarEvent(event(0, title: "checkpointed"))
        store.flushCalendarDeltaCheckpoint()
        store.addCalendarEvent(event(1, title: "only in the log"))

        let headerSeq = try rawHeaderSeq()
        XCTAssertEqual(try rawRecordSeqs(), [headerSeq + 1],
                       "fixture: the log must stand exactly one generation past the checkpoint")
        XCTAssertEqual(try rawManifestRecord()?.seq, headerSeq,
                       "fixture: and manifest.json must still say the checkpoint's generation — "
                       + "without this gap every assertion below holds for free")
        return headerSeq
    }

    // MARK: - 1. The pre-emption is released

    /// ROUND 5 ① — the reconcile's own `writeManifest` and its forensic line
    /// are both back.
    ///
    /// Two separate facts, asserted separately on purpose:
    ///
    ///   * `manifest.json` ON DISK now carries the generation only the log's
    ///     tail proved. The in-memory `committedSeq` answer is NOT evidence
    ///     for this — `noteCalendarLogRead` alone produces it, and does so
    ///     under the round-4 behaviour too. It is asserted anyway, as the
    ///     equivalence check that round 5 did not move it.
    ///   * the trail line naming both numbers. It is the only record that THIS
    ///     pass, rather than some later commit, is what caught the file up —
    ///     and it is the assertion a "just call `writeManifest()`
    ///     unconditionally" fix would still fail to make honest.
    ///
    /// MUTATION: with `durable` read from `manifest.slots` instead of the
    /// pre-loop snapshot, this fails on the on-disk seq and on the trail line.
    func testQAThePreEmptionIsReleasedTheTailReachesManifestJsonWithItsForensicLine() throws {
        let headerSeq = try logOneGenerationAheadOfTheManifest()
        try keepOnlyCalendarArtifacts(manifest: true)

        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        let cold = coldLaunch()

        XCTAssertEqual(cold.committedSeq(.calendarEvents), headerSeq + 1,
                       "equivalence with round 4: the in-memory generation is still the tail")
        XCTAssertEqual(try rawManifestRecord()?.seq, headerSeq + 1,
                       "ROUND 5 ①: and the DURABLE manifest now carries it too")
        XCTAssertEqual(try rawManifestRecord()?.everCommitted, true)
        XCTAssertTrue(DiagnosticTrail.combinedText()
                        .contains("slot=calendarEvents manifest seq \(headerSeq) "
                                  + "behind durable generation \(headerSeq + 1); reconciled"),
                      "ROUND 5 ①: with the forensic line, naming the generation it came FROM — "
                      + "which is the half that proves the reconcile is what wrote the file")
    }

    /// The falsifier for the cheap fix. A pass that wrote `manifest.json`
    /// unconditionally would satisfy the probe above and would also rewrite a
    /// manifest that is already current, on every launch, forever — turning a
    /// once-per-gap repair into a per-launch write.
    ///
    /// Run as a SEQUENCE rather than as two independent fixtures: the second
    /// launch's input is exactly the first launch's output, so this also pins
    /// that the repair CONVERGES.
    ///
    /// MUTATIONS, both measured. Under the round-4 mutation this test fails on
    /// its own PRECONDITION, so it is not an independent falsifier for ① — its
    /// job is the other mutant. Under `if changed { writeManifest() }` replaced
    /// by an unconditional `writeManifest()` it is, as of this round, the ONLY
    /// failing test in the tree: every other gh#235 probe, the implementer's
    /// two round-5 pins included, stays green while a perf-motivated branch
    /// grows a manifest write on every launch forever.
    func testQAControlAManifestThatIsAlreadyCurrentIsNotRewrittenAgain() throws {
        let headerSeq = try logOneGenerationAheadOfTheManifest()
        try keepOnlyCalendarArtifacts(manifest: true)

        _ = coldLaunch()
        XCTAssertEqual(try rawManifestRecord()?.seq, headerSeq + 1,
                       "precondition: the first launch did the repair")

        try stampManifestMtime()
        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        let second = coldLaunch()

        XCTAssertEqual(second.committedSeq(.calendarEvents), headerSeq + 1)
        XCTAssertEqual(try manifestMtime(), Self.mtimeSentinel,
                       "the second launch finds nothing to do and must not rewrite the file: "
                       + "`writeManifest` renames a temp over the target, so any rewrite would "
                       + "have replaced this stamp")
        XCTAssertFalse(DiagnosticTrail.combinedText().contains("behind durable generation"),
                       "and must emit no forensic line, because nothing was behind")
    }

    // MARK: - 2. What the durable write is FOR

    /// The consequence that makes ① durability rather than tidiness, carried
    /// one launch further than the record itself.
    ///
    /// `everCommitted` on disk is the only thing that tells a launch which has
    /// lost primary, backup AND log apart from a genuinely fresh install. In
    /// the corner where the LOG is the only surviving proof the slot was ever
    /// committed, round 4 stopped that proof being written down at all — so the
    /// NEXT loss presented as `.fresh`: seedable, demo rows over the last trace
    /// of a real store.
    ///
    /// Two launches, because one is not the claim: launch A has only the log,
    /// launch B has only what launch A wrote down.
    ///
    /// MUTATION: launch A writes no manifest at all and the `XCTUnwrap` fails
    /// there, which is where the measurement stops. That launch B would then
    /// read `.fresh` is not measured HERE — it is what the control below,
    /// which starts from exactly that state, says.
    func testQATheLogOnlyProofOfCommitSurvivesIntoALaunchThatAlsoLosesTheLog() throws {
        try logOneGenerationAheadOfTheManifest()
        let tailSeq = try XCTUnwrap(try rawRecordSeqs().last)

        // The log is now the ONLY artifact in the directory: no primary, no
        // backup, no manifest, no sibling slot. Anything that appears in
        // `manifest.json` after this was put there by the reconcile, reasoning
        // from the log's tail and from nothing else.
        try keepOnlyCalendarArtifacts(manifest: false)
        try FileManager.default.removeItem(at: try primaryURL())
        XCTAssertFalse(try manifestExists(), "fixture: no manifest to start from")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: try directory().path),
                       [StorageSlot.calendarEvents.deltaFilename],
                       "fixture: the log, alone")

        let launchA = coldLaunch()
        let written = try XCTUnwrap(try rawManifestRecord(),
                                    "ROUND 5 ①: the reconcile must write the proof DOWN — under "
                                    + "round 4 there is no manifest.json here at all")
        XCTAssertTrue(written.everCommitted)
        XCTAssertEqual(written.seq, tailSeq, "at the generation the log's tail proved, not zero")
        guard case .unreadable(.lostAfterManifest) = launchA.read(.calendarEvents, as: Event.self) else {
            return XCTFail("round 2's half, which must not have moved: a live log beside a "
                           + "vanished primary is `.lostAfterManifest`")
        }

        // Launch B: the log is gone too. `manifest.json` is now the only thing
        // in the world that remembers this slot ever held anything.
        try FileManager.default.removeItem(at: try logURL())
        guard case .unreadable(.lostAfterManifest) = coldLaunch().read(.calendarEvents, as: Event.self) else {
            return XCTFail("ROUND 5 ①: a slot that lost every artifact AFTER the reconcile "
                           + "recorded it must freeze, not present as fresh and seedable")
        }
    }

    /// The control that stops the test above being vacuous: it is launch A's
    /// durable write, and nothing else, that separates `.lostAfterManifest`
    /// from `.fresh`. Same fixture, same deletions, launch A simply never
    /// happens.
    ///
    /// MUTATION: green under both behaviours (measured), which is the point of
    /// a control — and it is the measurement that licenses the sentence above
    /// about what launch B reads when launch A wrote nothing.
    func testQAControlWithoutThatReconcilePassTheSameSlotPresentsAsFreshAndSeedable() throws {
        try logOneGenerationAheadOfTheManifest()

        try keepOnlyCalendarArtifacts(manifest: false)
        try FileManager.default.removeItem(at: try primaryURL())
        try FileManager.default.removeItem(at: try logURL())

        guard case .fresh = coldLaunch().read(.calendarEvents, as: Event.self) else {
            return XCTFail("with nothing on disk and nothing ever written down, the slot IS "
                           + "fresh — this is what the durable write above buys protection from")
        }
    }

    // MARK: - 3. Non-regression on the path round 4 never touched

    /// The reconcile's original job — catching the manifest up to a PRIMARY
    /// HEADER, with no delta log anywhere near it — is the half round 4 left
    /// alone and round 5 must not have broken while splitting the variable.
    ///
    /// Asserted on a slot that is NOT `.calendarEvents` and that `allCases`
    /// visits AFTER it, so the calendar's mid-loop `noteCalendarGeneration`
    /// has already run when this slot's record is judged.
    ///
    /// MUTATION: unaffected — `durable` and `record` are the same value for a
    /// slot no note ever touches, which is exactly what this test says.
    func testQAASiblingSlotsHeaderStillCatchesTheManifestUpAfterTheCalendarsNote() throws {
        try logOneGenerationAheadOfTheManifest()

        // A sibling slot with a real primary, and a manifest that has never
        // heard of it — the "died in the gap between the rename and the
        // manifest write" shape the reconcile exists for.
        let storage = coldLaunch()
        let receipt = try storage.commit([event(7, title: "sibling")], to: .reminders,
                                         intent: .destructive)
        XCTAssertGreaterThan(receipt.seq, 0)
        try FileManager.default.removeItem(at: try manifestURL())

        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        let cold = coldLaunch()

        XCTAssertEqual(cold.committedSeq(.reminders), receipt.seq,
                       "the sibling's generation is rebuilt from its own header")
        let data = try Data(contentsOf: try manifestURL())
        let record = try XCTUnwrap(try JSONDecoder().decode(StorageManifest.self, from: data)
                                    .slots[StorageSlot.reminders.rawValue])
        XCTAssertEqual(record.seq, receipt.seq, "and written back to manifest.json")
        XCTAssertTrue(record.everCommitted)
    }
}
