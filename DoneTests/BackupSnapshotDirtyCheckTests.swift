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

    // MARK: - Wipe (gh#258)
    //
    // Lives in this file because the fixture it needs is here — the URL
    // override plus an isolated `settingsDefaults`, without which a writer
    // test touches the host app's real snapshot.

    /// "Erase all local data" must take `Documents/backup-snapshot.json`
    /// with it. Measured RED before the fix (file present, with the event
    /// title in plaintext).
    ///
    /// The file is a comprehensive plaintext JSON of every slot plus event
    /// types, skills, conversations and settings, and
    /// `BackupSnapshotService`'s own doc says it is "automatically included
    /// in iOS Device Backup (and thus iCloud Backup)". The wipe is otherwise
    /// careful about exactly this — it writes empty envelopes instead of
    /// deleting files so legacy migration cannot re-run, and
    /// `purgeAuxiliaryCopies` takes the `.bak` and quarantine copies with it
    /// (`testWipeRemovesThePreWipePlaintextCopies`). This one file is missed.
    func testEraseAllLocalDataDeletesThePlaintextSnapshot() throws {
        let service = makeService()
        store.addCalendarEvent(fixtureEvent("secret dinner"))
        service.writeSnapshotSync(reason: "didEnterBackground")

        // Liveness, both halves: the file exists AND the title is really in
        // it. Without the second assertion "the file was deleted" would also
        // be satisfied by a snapshot that never captured anything.
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "liveness: a snapshot must exist before the wipe")
        let before = try String(contentsOf: snapshotURL, encoding: .utf8)
        XCTAssertTrue(before.contains("secret dinner"),
                      "liveness: the plaintext really is in the snapshot")

        store.clearAllLocalData()
        service.wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path),
                       "erase all local data must take the plaintext snapshot with it")
    }

    /// The half of `wipe()` the deletion test cannot see: the 30 s
    /// store-change debounce is ALREADY ARMED by the caller's own wipe (the
    /// five `@Published` arrays all just emitted), so without rebuilding the
    /// subscriptions the file comes back about half a minute after the user
    /// asked for it to be gone.
    ///
    /// A `.debounce` is a publisher, not a `Task`: there is nothing to
    /// cancel. Tearing the pipeline down and re-subscribing is what discards
    /// the in-flight one, and `attach`'s `dropFirst(5)` then swallows the
    /// emissions the now-empty stores send on subscribe.
    ///
    /// Driven through the `storeChangeDebounce` seam so this takes
    /// milliseconds; `testADebouncedChangeDoesRewriteWithoutTheWipe` is the
    /// positive control, without which "no file appeared" would also be what
    /// a debounce that never fires at all looks like.
    func testTheWipeDiscardsAnArmedDebounceSoTheFileStaysGone() async throws {
        let service = makeService()
        service.storeChangeDebounce = 0.05
        service.attach(eventStore: store, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)

        store.addCalendarEvent(fixtureEvent("secret dinner"))
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "liveness: a snapshot must exist before the wipe")

        store.clearAllLocalData()
        service.wipe()

        // Well past the (shortened) debounce the wipe itself armed.
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path),
                       "an armed debounce must not recreate the snapshot after a wipe")
    }

    /// Positive control for the test above: the same seam, the same window,
    /// no wipe — the debounce really does fire and really does write.
    func testADebouncedChangeDoesRewriteWithoutTheWipe() async throws {
        let service = makeService()
        service.storeChangeDebounce = 0.05
        service.attach(eventStore: store, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)

        store.addCalendarEvent(fixtureEvent("kept dinner"))
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "liveness: the store-change debounce must write on its own")
        let text = try String(contentsOf: snapshotURL, encoding: .utf8)
        XCTAssertTrue(text.contains("kept dinner"),
                      "and the write must be the real payload")
    }

    /// The WIRING, which neither test above can reach: `resetAllLocalData`
    /// lives in a SwiftUI view, so nothing in this target can drive it.
    ///
    /// Without this, deleting the `backupSnapshotService.wipe()` call from
    /// `AgentSettingsView` leaves every test in this file green while the
    /// user's plaintext snapshot survives the erase again — the gh#234 probe
    /// shipped with exactly that hole (both of its call sites could be
    /// deleted with all eight of its tests passing).
    ///
    /// A source guard, using the `StoreLookupScanGuardTests` /
    /// `Spike201EmitSiteInventoryTests` idiom: `#filePath` is this file's
    /// location at COMPILE time, so two directories up is the checkout the
    /// binary was built from.
    ///
    /// It also pins the POSITION, not just the presence. `wipe()` rebuilds
    /// the trigger subscriptions, and that rebuild's `dropFirst(5)` must
    /// swallow POST-wipe emissions — so the call has to come after the store
    /// erasures, and `MeAvatarStore.delete()` is the last of those.
    func testResetAllLocalDataCallsTheSnapshotWipeLast() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Done/Views/Agent/AgentSettingsView.swift"),
            encoding: .utf8
        )

        guard let fnStart = source.range(of: "private func resetAllLocalData() {") else {
            return XCTFail("resetAllLocalData has been renamed — re-point this guard")
        }
        // Up to the next declaration at the same indentation.
        let rest = source[fnStart.upperBound...]
        guard let fnEnd = rest.range(of: "\n    }\n") else {
            return XCTFail("could not find the end of resetAllLocalData")
        }
        let body = String(rest[..<fnEnd.lowerBound])

        guard let callIndex = body.range(of: "backupSnapshotService.wipe()") else {
            return XCTFail(
                "resetAllLocalData must tell BackupSnapshotService to wipe — "
                + "without it the plaintext Documents/backup-snapshot.json "
                + "survives 'erase all local data' (gh#258)"
            )
        }
        guard let avatarIndex = body.range(of: "MeAvatarStore.delete()") else {
            return XCTFail("MeAvatarStore.delete() moved — re-derive the ordering anchor")
        }
        XCTAssertTrue(callIndex.lowerBound > avatarIndex.lowerBound,
                      "the snapshot wipe must come AFTER the store erasures: its "
                      + "re-attach swallows the emissions they produce")
    }

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
