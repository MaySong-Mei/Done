//
//  BackupSnapshotDirtyCheckTests.swift
//  DoneTests
//
//  gh#219 (write-amplification class): `writeSnapshotSync` rebuilds and
//  rewrites the ENTIRE backup document — twelve top-level collections, the
//  whole chat history, a base64 avatar — on every `didEnterBackground` and
//  every 30s-quiet store change, with no payload guard of any kind. Every
//  sibling write path has one (`DurableEventStorage.lastCommittedDigest`,
//  the widget's `lastWrittenSnapshotHash`, Supabase's `rowHash`); this file
//  is where the backup snapshot gets its own.
//
//  The known trap, inherited from `rowHashIgnoredKeys`: the payload carries
//  `createdAt: ISO8601(Date())`, so a naive byte-level digest never matches
//  and a guard built on one would be dead code that looks alive.
//

import XCTest
@testable import Done

@MainActor
final class BackupSnapshotDirtyCheckTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var snapshotURL: URL!

    // Held as properties: `BackupSnapshotService` keeps its stores `weak`,
    // so locals built inline would be gone before the snapshot is written.
    private var store: EventStore!
    private var types: EventTypeTemplateStore!
    private var skills: SkillInsightStore!
    private var prefs: AgentPreferenceStore!

    override func setUp() {
        super.setUp()
        suiteName = "BackupSnapshotDirtyCheckTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        snapshotURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-snapshot-dirty-\(UUID().uuidString).json")

        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        store.addCalendarEvent(fixtureEvent("Dentist"))
        store.addList(TodoList(title: "Groceries", colorName: "green"))
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AgentPrefs-\(UUID().uuidString)", isDirectory: true))
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
        // The seam: `.standard` would read the app's own shared settings,
        // which no test may depend on. The URL override keeps the writer off
        // the host app's real snapshot file.
        service.settingsDefaults = defaults
        service.snapshotFileURLOverride = snapshotURL
        service.attach(eventStore: store, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)
        return service
    }

    /// Lets the wall clock tick far enough that a rebuilt payload's
    /// `createdAt` (millisecond-resolution ISO8601) cannot collide with the
    /// previous one — so "file bytes unchanged" can only mean "not rewritten",
    /// and "file rewritten" is guaranteed to show up as changed bytes.
    private func letCreatedAtTick() { usleep(5_000) }

    // MARK: - The dirty check

    /// The negative control from the first commit, flipped: the same two
    /// triggers against the same unchanged store now produce ONE write. (The
    /// first commit pinned today's behavior — two full writes, bytes churning
    /// on `createdAt` alone — so this flip is the guard's observable effect,
    /// not a guard that never fires.)
    func testASecondWriteWithNothingChangedIsSkipped() throws {
        let service = makeService()

        service.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "fixture guard: the first write lands")
        let firstBytes = try Data(contentsOf: snapshotURL)

        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")

        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "an unchanged store must not be re-serialized and rewritten")
        XCTAssertEqual(try Data(contentsOf: snapshotURL), firstBytes,
                       "the file is byte-identical — not even createdAt churned")
    }

    /// The guard must see depth, not shape: same number of events, same
    /// titles, same everything except one time-range end buried two levels
    /// down (event → timeRanges[0] → end). An overbroad digest — counts,
    /// top-level fields — would call this clean and eat a real edit.
    func testAChangeToOneNestedFieldStillWrites() throws {
        let service = makeService()
        service.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(service.snapshotWritesPerformed, 1)

        var moved = store.rawCalendarEvents[0]
        moved.timeRanges[0].end = moved.timeRanges[0].end.addingTimeInterval(900)
        store.updateCalendarEvent(moved)

        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(service.snapshotWritesPerformed, 2,
                       "a 15-minute extension two levels deep is real content")

        // And the guard re-arms on the new content rather than staying dirty.
        letCreatedAtTick()
        service.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(service.snapshotWritesPerformed, 2)
    }

    /// The `rowHashIgnoredKeys` trap, pinned from the other side: the payload
    /// really does carry a fresh `createdAt` on every build (fixture guard
    /// below), and that stamp alone must never count as dirty.
    func testTheCreatedAtStampAloneNeverDirties() throws {
        let service = makeService()
        service.writeSnapshotSync(reason: "storeChange")

        let document = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: snapshotURL)) as? [String: Any])
        XCTAssertNotNil(document["createdAt"],
                        "fixture guard: the field the digest must ignore is really in the payload")

        for _ in 0..<3 {
            letCreatedAtTick()
            service.writeSnapshotSync(reason: "didEnterBackground")
        }
        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "three later triggers, three fresh would-be createdAt values, zero writes")
    }

    /// Relaunch: a brand-new service instance has an empty in-memory digest,
    /// and the disk file's `createdAt` can never match a rebuilt payload's.
    /// The seed must come from the snapshot itself — parsed, stamp stripped —
    /// because a persisted marker could desync; the file cannot (gh#142).
    func testARelaunchOverAnUnchangedStoreWritesNothing() throws {
        let first = makeService()
        first.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(first.snapshotWritesPerformed, 1)
        let firstBytes = try Data(contentsOf: snapshotURL)

        letCreatedAtTick()
        let relaunched = makeService()
        relaunched.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertEqual(relaunched.snapshotWritesPerformed, 0,
                       "the disk file already says all of this; a relaunch adds nothing")
        XCTAssertEqual(try Data(contentsOf: snapshotURL), firstBytes)

        // The seed must not wedge the service clean: real changes still land.
        store.addCalendarEvent(fixtureEvent("Post-relaunch"))
        letCreatedAtTick()
        relaunched.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(relaunched.snapshotWritesPerformed, 1,
                       "and the relaunched service is not stuck clean")
    }
}
