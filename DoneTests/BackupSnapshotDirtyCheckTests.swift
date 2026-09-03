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

    // MARK: - The waste, pinned (NEGATIVE CONTROL)

    /// TODAY's behavior, asserted on purpose: two triggers against a healthy,
    /// completely unchanged store produce two full writes, bytes churning
    /// only because `createdAt` moved. This test exists so the dirty check
    /// has something observable to flip — without it, a guard that never
    /// fires and a guard that works are indistinguishable.
    func testASecondWriteWithNothingChangedRewritesTheWholeFileToday() throws {
        let service = makeService()

        service.writeSnapshotSync(reason: "storeChange")
        XCTAssertEqual(service.snapshotWritesPerformed, 1,
                       "fixture guard: the first write lands")
        let firstBytes = try Data(contentsOf: snapshotURL)

        letCreatedAtTick()
        service.writeSnapshotSync(reason: "didEnterBackground")

        XCTAssertEqual(service.snapshotWritesPerformed, 2,
                       "pinning today's waste: an unchanged store is rewritten in full")
        XCTAssertNotEqual(try Data(contentsOf: snapshotURL), firstBytes,
                          "and the bytes churn even though no user data moved — createdAt alone differs")
    }
}
