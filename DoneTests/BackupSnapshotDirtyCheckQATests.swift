//
//  BackupSnapshotDirtyCheckQATests.swift
//  DoneTests
//
//  Independent adversarial QA for the gh#219 dirty check. These tests attack
//  the directions the branch's own tests do not cover:
//
//  1. FALSE-CLEAN per bucket — a skipped backup that was needed is lost
//     disaster recovery. The branch tests mutate exactly one bucket
//     (`calendarEvents`); a digest that silently dropped any OTHER bucket
//     would pass that suite. Here every mutable bucket is changed in turn and
//     each change must produce a write. (Conversations and the avatar are
//     process-wide singletons with no test seam — a test cannot mutate them
//     without touching the host app's real data — so their coverage rests on
//     the structural argument that the payload is assembled from the same
//     bytes the digest hashes.)
//
//  2. Relaunch over a CHANGED store — the branch's relaunch test only proves
//     an UNCHANGED store is skipped. The catastrophic direction (disk is
//     stale after a crash, first trigger must write) had no test: a mutant
//     that seeds the digest whenever a disk file merely EXISTS would have
//     survived the branch suite.
//
//  3. Corrupt / truncated / wrong-shape disk snapshot at seed time — must
//     write and heal, never crash, never skip.
//
//  4. Frozen-slot gate interaction — the gate sits BEFORE the dirty check;
//     a frozen interlude must neither write nor poison the digest, and the
//     digest must still be armed afterwards.
//

import XCTest
@testable import Done

@MainActor
final class BackupSnapshotDirtyCheckQATests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var snapshotURL: URL!

    // Held as properties: `BackupSnapshotService` keeps its stores `weak`.
    private var store: EventStore!
    private var types: EventTypeTemplateStore!
    private var skills: SkillInsightStore!
    private var prefs: AgentPreferenceStore!

    override func setUp() {
        super.setUp()
        suiteName = "BackupSnapshotDirtyCheckQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        snapshotURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-snapshot-qa-\(UUID().uuidString).json")

        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        store.addCalendarEvent(fixtureEvent("Dentist"))
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AgentPrefsQA-\(UUID().uuidString)", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: snapshotURL)
        TestStorage.tearDown(suiteName)
        store = nil
        types = nil
        skills = nil
        prefs = nil
        defaults = nil
        location = nil
        snapshotURL = nil
        suiteName = nil
        super.tearDown()
    }

    private func fixtureEvent(_ title: String) -> Event {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return Event(title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    private func makeService() -> BackupSnapshotService {
        let service = BackupSnapshotService()
        service.settingsDefaults = defaults
        service.snapshotFileURLOverride = snapshotURL
        service.attach(eventStore: store, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)
        return service
    }

    private func letCreatedAtTick() { usleep(5_000) }

    // MARK: - 1. Every mutable bucket must dirty the digest

    /// One service, a write, then one bucket mutated at a time — each must
    /// produce exactly one more write. A digest that dropped any of these
    /// buckets (or hashed something upstream of them) fails at that step.
    func testEveryMutableBucketDirtiesTheDigest() throws {
        let service = makeService()
        service.writeSnapshotSync(reason: "storeChange")
        var expected = 1
        XCTAssertEqual(service.snapshotWritesPerformed, expected, "fixture guard: first write lands")

        func expectWrite(_ bucket: String, _ mutate: () -> Void) {
            mutate()
            letCreatedAtTick()
            service.writeSnapshotSync(reason: "didEnterBackground")
            expected += 1
            XCTAssertEqual(service.snapshotWritesPerformed, expected,
                           "a change to '\(bucket)' must dirty the snapshot — a miss here is silent loss of disaster recovery")
        }

        expectWrite("events (wanna)") {
            self.store.add(self.fixtureEvent("Wanna item"))
        }
        expectWrite("todoLists") {
            self.store.addList(TodoList(title: "QA list", colorName: "green"))
        }
        expectWrite("logs") {
            let event = self.store.rawCalendarEvents[0]
            let day = event.timeRanges[0].start
            self.store.calendarEventLogRecords.append(CalendarEventLogRecord(
                id: CalendarOccurrenceKey(
                    eventID: event.id,
                    baseSeriesEventID: nil,
                    occurrenceDate: day,
                    kind: .singleEvent,
                    dayKey: CalendarOccurrenceKey.dayKey(from: day)),
                eventID: event.id,
                baseSeriesEventID: nil,
                occurrenceDate: day))
        }
        expectWrite("eventTypes") {
            self.types.add("QA Type", colorHex: "#123456")
        }
        expectWrite("skills") {
            self.skills.add(SkillInsight(skillName: "Patience", points: 1,
                                         date: Date(timeIntervalSince1970: 1_800_000_000),
                                         eventTitle: "Dentist", reasoning: "QA"))
        }
        expectWrite("agentDecisionHistory (and agentRules)") {
            self.prefs.recordDecision(AgentDecisionRecord(
                requestSnapshot: AgentDecisionRequest(
                    kind: .missingEventTypeTemplate,
                    title: "Create template?",
                    message: "QA",
                    options: [],
                    context: AgentDecisionContext(
                        domain: .calendar,
                        operationID: UUID(),
                        sourceScreen: "QA",
                        payloadSummary: "QA",
                        metadata: [:])),
                resultKind: .selected,
                selectedOptionID: AgentOperationCenter.OptionID.createTemplate,
                appliedActionSummary: "QA",
                wasDefaulted: false))
        }
        expectWrite("settings") {
            self.defaults.set(true, forKey: AppSettingsKeys.rememberLastTab)
        }

        // Control: after all that churn, an untouched store still skips —
        // the writes above were digest transitions, not a guard that
        // stopped guarding.
        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, expected,
                       "control: no further mutation, no further write")
    }

    // MARK: - 2. Relaunch over a CHANGED store must write

    /// The catastrophic inverse of the branch's relaunch test: the disk file
    /// is STALE (store changed after the last write — the crash-before-
    /// backgrounding shape). The first trigger of the new launch must write.
    /// A seed that adopts the current digest whenever a disk file merely
    /// exists — instead of comparing content — passes every branch test and
    /// fails only here.
    func testARelaunchOverAChangedStoreStillWrites() throws {
        let first = makeService()
        first.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(first.snapshotWritesPerformed, 1)
        let staleBytes = try Data(contentsOf: snapshotURL)

        // The "crash": content changes, but no trigger fires on the old
        // instance. Disk is now stale.
        store.addCalendarEvent(fixtureEvent("Added after the last write"))

        letCreatedAtTick()
        let relaunched = makeService()
        relaunched.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(relaunched.snapshotWritesPerformed, 1,
                       "disk is stale; skipping here would silently lose the new event from disaster recovery")
        XCTAssertNotEqual(try Data(contentsOf: snapshotURL), staleBytes,
                          "the file must actually carry the new content")
    }

    // MARK: - 3. Corrupt disk snapshot at seed time

    /// A truncated file (killed mid-write on a pre-atomic build, disk-full
    /// artifact, external meddling) must read as "disk holds nothing
    /// current": write and heal, never crash, never skip.
    func testATruncatedDiskSnapshotIsHealedByTheFirstWrite() throws {
        try Data(#"{"version": 1, "events": [{"ti"#.utf8).write(to: snapshotURL)

        let service = makeService()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "unparseable disk bytes must not suppress the write")

        let healed = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: snapshotURL)) as? [String: Any])
        XCTAssertNotNil(healed["calendarEvents"], "the healed file is a real snapshot again")
    }

    /// Valid JSON, wrong shape (a top-level array): the `as? [String: Any]`
    /// cast fails, the seed reads nil, the write proceeds.
    func testAWrongShapeDiskSnapshotIsHealedByTheFirstWrite() throws {
        try Data("[]".utf8).write(to: snapshotURL)

        let service = makeService()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "a JSON array is not a snapshot; the write must proceed")
    }

    /// An EMPTY file — zero bytes, the classic disk-full leftover.
    func testAnEmptyDiskSnapshotIsHealedByTheFirstWrite() throws {
        try Data().write(to: snapshotURL)

        let service = makeService()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 1)
    }

    // MARK: - 4. Frozen-slot gate interaction

    /// The gate sits BEFORE the dirty check. A frozen interlude must not
    /// write (that is the gate's own contract, already pinned elsewhere) —
    /// but it must ALSO not corrupt the dirty state in either direction:
    /// the digest stays armed on the pre-freeze content, so an unfrozen
    /// store with that same content still skips, and changed content still
    /// writes.
    func testAFrozenInterludeNeitherWritesNorPoisonsTheDigest() throws {
        let service = makeService()
        service.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(service.snapshotWritesPerformed, 1)
        let bytesBeforeFreeze = try Data(contentsOf: snapshotURL)

        // Freeze: shred the calendar slot's primary on disk, remove its
        // backup, and build a store that fails to read it. Same fixture
        // shape as EventStoreDurabilityTests.
        let dir = try location.directoryURL()
        try Data("shredded".utf8).write(
            to: dir.appendingPathComponent(StorageSlot.calendarEvents.filename))
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(StorageSlot.calendarEvents.backupFilename))
        let frozenStore = EventStore(defaults: defaults, storage: location,
                                     seedsSampleDataIfEmpty: false)
        XCTAssertTrue(frozenStore.isSlotFrozen(.calendarEvents), "fixture guard")

        service.attach(eventStore: frozenStore, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)
        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "the frozen gate must fire before the dirty check ever runs")
        XCTAssertEqual(try Data(contentsOf: snapshotURL), bytesBeforeFreeze,
                       "a stale-but-complete snapshot beats a fresh one with a hole")

        // Back on the healthy store with IDENTICAL content: the digest from
        // before the freeze is still armed, so this skips.
        service.attach(eventStore: store, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)
        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "same content as the armed digest — the frozen interlude must not have dirtied it")

        // And real change after the interlude still lands.
        store.addCalendarEvent(fixtureEvent("After the thaw"))
        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 2,
                       "the guard is still a guard, not a wedge")
    }

    // MARK: - Sharp edge, pinned deliberately

    /// EXTERNAL deletion of the snapshot mid-run is NOT healed until content
    /// changes (or relaunch): the steady-state skip trusts the in-memory
    /// digest and never re-checks the disk. This pins the branch's actual
    /// behavior so the trade-off is a decision, not an accident. Nothing in
    /// the app deletes this file today, so the exposure is external actors
    /// only — if a "Reset local data" path ever starts deleting it, this
    /// test is the tripwire that forces the heal-on-skip discussion.
    func testExternalDeletionMidRunIsNotHealedUntilContentChanges() throws {
        let service = makeService()
        service.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(service.snapshotWritesPerformed, 1)

        try FileManager.default.removeItem(at: snapshotURL)

        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "TODAY's contract: the skip does not stat the disk, so the deleted file stays gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))

        // The way back: any real change rewrites the file.
        store.addCalendarEvent(fixtureEvent("Heals the hole"))
        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
    }
}
