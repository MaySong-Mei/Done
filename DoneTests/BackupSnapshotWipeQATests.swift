//
//  BackupSnapshotWipeQATests.swift
//  DoneTests
//
//  Independent adversarial QA for the gh#258 wipe. The branch's four
//  witnesses cover the happy path (attached service, armed debounce, the
//  wiring's presence and position). These attack the directions they do not:
//
//  1. The `else` branch — `wipe()` on a service that was never `attach`ed.
//     The branch has no test that enters it at all, and it is the branch a
//     settings screen reached before `ContentView`'s attach would take.
//  2. Act 2 in isolation — `lastWrittenComponentsDigest = nil`. Deleting that
//     line leaves all four branch witnesses green (none of them writes again
//     after the wipe), yet it makes the NEXT genuine write skip against a
//     digest describing a file that no longer exists.
//  3. The file DOES come back — the deletion is a point-in-time property, not
//     an invariant. The next `didEnterBackground` rewrites the snapshot from
//     the emptied stores. What must hold forever is the privacy property, not
//     the absence property, so that is what is pinned here.
//  4. The ordering claim, reproduced rather than accepted: `wipe()` called
//     BEFORE the store erasures really does let the debounce recreate the
//     file — and the recreated file's CONTENT is what says how bad that is.
//  5. The environment injection, as a source guard. Deleting
//     `.environmentObject(backupSnapshotService)` from `ContentView` leaves
//     the whole suite green and crashes the app the moment Data & Privacy is
//     opened (a missing `@EnvironmentObject` is a `fatalError`, not a nil).
//     Nothing else in the tree can see that.
//

import XCTest
@testable import Done

@MainActor
final class BackupSnapshotWipeQATests: XCTestCase {
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
        suiteName = "BackupSnapshotWipeQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        snapshotURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-snapshot-wipe-qa-\(UUID().uuidString).json")

        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AgentPrefsWipeQA-\(UUID().uuidString)", isDirectory: true))
    }

    override func tearDown() {
        // A read-only file would otherwise survive into the next run's sweep.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: snapshotURL.path)
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

    /// Attached, like the app. The two seams keep the writer off the host
    /// app's real snapshot and off its real settings.
    private func makeAttachedService() -> BackupSnapshotService {
        let service = makeDetachedService()
        service.attach(eventStore: store, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)
        return service
    }

    /// Deliberately NOT attached — the `else` branch of `wipe()`.
    private func makeDetachedService() -> BackupSnapshotService {
        let service = BackupSnapshotService()
        service.settingsDefaults = defaults
        service.snapshotFileURLOverride = snapshotURL
        return service
    }

    // MARK: - 1. The `else` branch

    /// `wipe()` on a service that was never attached. `writeSnapshotSync`
    /// returns early without its stores, so the file has to be planted by
    /// hand — which is also the honest shape of the production case this
    /// covers: a snapshot left by a PREVIOUS launch, and a settings screen
    /// reached before `ContentView`'s `attach` ran.
    ///
    /// Liveness in two halves, like the branch's own deletion witness: the
    /// file is there, and the plaintext really is in it. Without the second,
    /// "deleted" would also be satisfied by an empty file.
    func testWipeDeletesTheSnapshotWhenTheServiceWasNeverAttached() throws {
        try #"{"version":1,"events":[{"title":"secret dinner"}]}"#
            .data(using: .utf8)!
            .write(to: snapshotURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "liveness: the planted snapshot must exist before the wipe")
        XCTAssertTrue(try String(contentsOf: snapshotURL, encoding: .utf8)
            .contains("secret dinner"),
                      "liveness: the plaintext really is in the planted snapshot")

        let service = makeDetachedService()
        service.wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path),
                       "an un-attached service must still take the file: the else "
                       + "branch is the one a pre-attach settings screen reaches")
    }

    /// Nothing on disk at all, nothing attached — the first-launch shape.
    /// "A missing file is success, not an error" must mean no crash AND no
    /// damage: the service still writes when it is next asked to.
    func testWipeOverNothingAtAllLeavesTheServiceAbleToWrite() throws {
        let service = makeDetachedService()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path),
                       "liveness: this test's premise is that there is no file")

        service.wipe()
        service.wipe()   // and again — idempotent

        service.attach(eventStore: store, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)
        store.addCalendarEvent(fixtureEvent("after the wipe"))
        service.writeSnapshotSync(reason: "didEnterBackground")

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "a wipe over nothing must not leave the writer broken")
    }

    // MARK: - 2. Act 2 on its own — the digest

    /// The one act of `wipe()` that no branch witness can see. All four of
    /// them stop at "the file is gone"; none writes again afterwards, so
    /// deleting `lastWrittenComponentsDigest = nil` leaves them all green.
    ///
    /// What it costs: the digest still describes the deleted file, so the
    /// NEXT write of that same content is skipped as "unchanged" and the
    /// snapshot stays missing — the DR copy silently gone until the stores
    /// happen to change. UNCHANGED content on purpose: that is the only
    /// state in which the stale digest can match and the skip can fire.
    func testTheWipeDoesNotLeaveTheDigestBlockingTheNextGenuineWrite() throws {
        let service = makeAttachedService()
        store.addCalendarEvent(fixtureEvent("dinner"))
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "liveness: a snapshot must exist before the wipe")
        let writesBefore = service.snapshotWritesPerformed

        service.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path),
                       "liveness: the wipe must have taken the file")

        // Same stores, same content as the digest describes.
        service.writeSnapshotSync(reason: "didEnterBackground")

        XCTAssertEqual(service.snapshotWritesPerformed, writesBefore + 1,
                       "the wipe must forget the digest: it describes a file that "
                       + "no longer exists, so the next write must not skip against it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "and the snapshot must actually be back on disk")
    }

    // MARK: - 3. The deletion is point-in-time; the privacy property is not

    /// After the erase the user is still in the app, and leaving it posts
    /// `didEnterBackground` — which writes the snapshot again. So "the file
    /// is gone" is true at the moment of the wipe and not after it.
    ///
    /// That is acceptable only because of what the rewritten file CONTAINS,
    /// which is what this pins. The liveness half proves the test is looking
    /// at a real rewrite (the file came back) rather than at an absence it
    /// would have gotten for free.
    func testTheSnapshotRewrittenAfterTheEraseCarriesNoneOfTheErasedPlaintext() throws {
        let service = makeAttachedService()
        store.addCalendarEvent(fixtureEvent("secret dinner"))
        store.addList(TodoList(title: "secret list", colorName: "green"))
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertTrue(try String(contentsOf: snapshotURL, encoding: .utf8)
            .contains("secret dinner"),
                      "liveness: the plaintext really is in the pre-erase snapshot")

        store.clearAllLocalData()
        service.wipe()

        // The backgrounding the user's next app switch produces.
        service.writeSnapshotSync(reason: "didEnterBackground")

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "liveness: the file really does come back — this test is "
                      + "about its contents, not about an absence")
        let after = try String(contentsOf: snapshotURL, encoding: .utf8)
        XCTAssertFalse(after.contains("secret dinner"),
                       "the post-erase snapshot must carry no erased event title")
        XCTAssertFalse(after.contains("secret list"),
                       "nor any erased list title")
    }

    // MARK: - 4. The ordering claim, reproduced

    /// The branch claims the call's position is load-bearing: called before
    /// the store erasures, `attach`'s `dropFirst(5)` swallows the PRE-wipe
    /// emissions and the erasures' own emissions flow through to a write
    /// ~30 s later. Reproduced here through the `storeChangeDebounce` seam
    /// instead of taken on trust.
    ///
    /// It reproduces — and the recreated file's CONTENT is the part the claim
    /// does not state: the write happens from the already-emptied stores, so
    /// what comes back is a snapshot with the erased plaintext absent. The
    /// position is load-bearing for "no file", not for "no plaintext".
    /// `testTheWipeDiscardsAnArmedDebounceSoTheFileStaysGone` is the
    /// correct-order control for this one.
    func testWipeCalledBeforeTheStoreErasuresLetsTheArmedDebounceRecreateTheFile() async throws {
        let service = makeDetachedService()
        service.storeChangeDebounce = 0.05
        service.attach(eventStore: store, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)

        store.addCalendarEvent(fixtureEvent("secret dinner"))
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "liveness: a snapshot must exist before the wipe")

        // THE WRONG ORDER: wipe first, erase after.
        service.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path),
                       "liveness: the wipe did delete the file, before the debounce ran")
        store.clearAllLocalData()

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "the position claim reproduces: wiped first, the erasures' own "
                      + "emissions reach the debounce and recreate the file")
        XCTAssertFalse(try String(contentsOf: snapshotURL, encoding: .utf8)
            .contains("secret dinner"),
                       "and this is the limit of the claim: the recreated file is "
                       + "written from the emptied stores, so it carries no erased "
                       + "plaintext — the cost is a file, not a leak")
    }

    // MARK: - 5. The environment injection, as a source guard

    /// `@EnvironmentObject` is resolved at `body` evaluation and a missing one
    /// is a `fatalError`, not a nil — so deleting
    /// `.environmentObject(backupSnapshotService)` from `ContentView` does not
    /// disable the wipe, it crashes the app the moment Data & Privacy is
    /// opened. No test in this target renders that view, and the branch's own
    /// source guard reads `AgentSettingsView` only, so that mutation survives
    /// the entire suite. This is the half that sees it.
    ///
    /// Same `#filePath` idiom as `testResetAllLocalDataCallsTheSnapshotWipeLast`
    /// and `StoreLookupScanGuardTests`: `#filePath` is this file's location at
    /// COMPILE time, so one directory up is the checkout that was built.
    func testContentViewInjectsTheBackupSnapshotServiceIntoTheEnvironment() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
        let contentView = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(contentView.contains(".environmentObject(backupSnapshotService)"),
                      "ContentView must inject BackupSnapshotService into the "
                      + "environment: DataPrivacySettingsView reads it as an "
                      + "@EnvironmentObject, and a missing one is a fatalError at "
                      + "body evaluation — the settings screen would crash, not "
                      + "silently skip the wipe (gh#258)")

        let settings = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Done/Views/Agent/AgentSettingsView.swift"),
            encoding: .utf8
        )
        // The pairing is what makes the guard above meaningful rather than a
        // string that happens to be present: the consumer is why the producer
        // has to exist.
        XCTAssertTrue(
            settings.contains("@EnvironmentObject private var backupSnapshotService: BackupSnapshotService"),
            "…and DataPrivacySettingsView must be the consumer that requires it; "
            + "if this declaration moved to @StateObject or an init parameter, "
            + "re-derive the guard above"
        )
    }

    // MARK: - 6. A file the OS does not want deleted

    /// A read-only snapshot. `unlink` is governed by the DIRECTORY's
    /// permissions, not the file's, so this must still succeed — and the
    /// liveness half proves the test really did make the file unwritable,
    /// so a green result is not "the chmod silently did nothing".
    func testAReadOnlySnapshotFileIsStillDeleted() throws {
        try #"{"version":1,"events":[{"title":"secret dinner"}]}"#
            .data(using: .utf8)!
            .write(to: snapshotURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: snapshotURL.path)
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: snapshotURL.path),
                       "liveness: the chmod must really have made the file read-only")

        makeDetachedService().wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path),
                       "a read-only snapshot is still the user's plaintext: the "
                       + "wipe must take it")
    }
}
