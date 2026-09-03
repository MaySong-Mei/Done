//
//  ImageBackupCoordinatorTests.swift
//  DoneTests
//
//  gh#219 — durable upload idempotence. Every test drives the coordinator
//  through `attach()`, the production entry point, over an injected
//  UserDefaults suite + isolated asset directory + scripted storage mock.
//  A "relaunch" is a fresh coordinator instance over the same suite: the
//  in-memory state dies, the suite (≈ the device's defaults) survives.
//
//  The lifecycle under test (gh#142 rule — persist "already done" only
//  where a wrong skip self-heals):
//    durable marker ⇐ ONLY a confirmed remote outcome (2xx, 409, or a
//    successful restore download). Never on attempt, never before the
//    local file read, never on failure — those stay in the in-memory
//    per-session set, whose process reset is the deliberate retry channel.
//
//  Markers are keyed by the CLOUD OBJECT pair `"eventID/imageID"`, not by
//  imageID alone — see ImageBackupQAProbeTests for the shared-imageID
//  aliasing regression that forced the pair key.
//

import XCTest
import Combine
@testable import Done

@MainActor
final class ImageBackupCoordinatorTests: XCTestCase {

    // MARK: - Scripted storage mock

    final class MockStorage: ImageStorageServicing {
        enum Outcome {
            case uploadedNew        // 2xx — bytes written this call
            case alreadyInCloud     // 409 — object already at this path
            case error(Error)       // 5xx / network / etc.
        }
        /// Mocks run the live upload path even in DEBUG builds.
        var uploadsDisabled = false
        var outcomes: [UUID: Outcome] = [:]
        /// When true, `upload` parks on a continuation after recording the
        /// POST, so a test can change the world mid-flight (e.g. switch the
        /// signed-in user) before letting the "server" answer.
        var gateUploads = false
        private(set) var parkedUpload: CheckedContinuation<Void, Never>?
        func releaseParkedUpload() {
            parkedUpload?.resume()
            parkedUpload = nil
        }
        /// Every byte-carrying POST that reached the storage layer, in order.
        private(set) var uploadedImageIDs: [UUID] = []
        private(set) var uploadedPaths: [String] = []

        func storagePath(userID: String, eventID: UUID, imageID: UUID) -> String {
            "\(userID)/\(eventID.uuidString)/\(imageID.uuidString).jpg"
        }
        func upload(path: String, data: Data) async throws -> Bool {
            let stem = String(path.split(separator: "/").last!.dropLast(4))
            let imageID = UUID(uuidString: stem)!
            uploadedImageIDs.append(imageID)
            uploadedPaths.append(path)
            if gateUploads {
                await withCheckedContinuation { parkedUpload = $0 }
            }
            switch outcomes[imageID] ?? .uploadedNew {
            case .uploadedNew: return true
            case .alreadyInCloud: return false
            case .error(let error): throw error
            }
        }
        func download(path: String) async throws -> Data? { nil }
        func uploadAvatar(userID: String, data: Data) async throws -> Bool { true }
        func downloadAvatar(userID: String) async throws -> Data? { nil }
        func deleteAvatar(userID: String) async {}
    }

    /// Counts writes to the durable-marker key so the "one coalesced write
    /// per scan, not one per image" contract is a test, not a comment.
    final class SpyDefaults: UserDefaults {
        var confirmedKeyWrites = 0
        override func set(_ value: Any?, forKey defaultName: String) {
            if defaultName.hasPrefix("imageBackup.confirmedUploadedObjects.") {
                confirmedKeyWrites += 1
            }
            super.set(value, forKey: defaultName)
        }
    }

    // MARK: - Rig

    private var suiteName = ""
    private var suite: UserDefaults!
    private var storageLocation: EventStorageLocation!
    private var assetDir: URL!
    private var extraSuites: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "ImageBackupCoordinatorTests-\(UUID().uuidString)"
        storageLocation = TestStorage.reset(suiteName)
        suite = UserDefaults(suiteName: suiteName)!
        suite.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        assetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try? FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
        extraSuites = []
        liveAuthServices = []
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        for name in extraSuites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        try? FileManager.default.removeItem(at: assetDir)
        liveAuthServices = []
        super.tearDown()
    }

    /// The coordinator holds `AuthService` weakly (production retains it
    /// via @StateObject), so every service made here is ALSO retained in
    /// `liveAuthServices` for the rest of the test — passing a temporary
    /// would let it deallocate before the attach-driven scan runs and the
    /// scan would silently no-op on `guard let userID`.
    private var liveAuthServices: [AuthService] = []

    private func makeAuth(userID: String) -> AuthService {
        // Dedicated suite per (test, user) so fabricating user B's session
        // can't disturb the coordinator's suite mid-test.
        let name = "\(suiteName).auth.\(userID)"
        extraSuites.append(name)
        let authSuite = UserDefaults(suiteName: name)!
        authSuite.removePersistentDomain(forName: name)
        let session = AuthSession(
            accessToken: "test-token",
            refreshToken: "test-refresh",
            expiresAt: .distantFuture,
            user: AuthUser(id: userID, email: nil, createdAt: nil)
        )
        authSuite.set(try! JSONEncoder().encode(session), forKey: "supabaseAuthSession")
        let service = AuthService(defaults: authSuite)
        liveAuthServices.append(service)
        return service
    }

    private func makeEventStore() -> EventStore {
        EventStore(defaults: suite,
                   storage: storageLocation,
                   seedsSampleDataIfEmpty: false)
    }

    private func makeCoordinator(mock: MockStorage,
                                 defaults: UserDefaults? = nil) -> ImageBackupCoordinator {
        ImageBackupCoordinator(
            defaults: defaults ?? suite,
            assetStore: AgenticIntakeAssetStore(baseDirectoryURL: assetDir),
            storageServiceFactory: { _ in mock }
        )
    }

    private func makeImageRef(eventID: UUID) -> AgenticIntakeImageRef {
        let id = UUID()
        return AgenticIntakeImageRef(
            id: id,
            relativePath: "\(eventID.uuidString)/\(id.uuidString).jpg",
            pixelWidth: 10, pixelHeight: 10, fileSizeBytes: 3
        )
    }

    private func writeLocalFile(for ref: AgenticIntakeImageRef) throws {
        let url = assetDir.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
    }

    private func makeEvent(eventID: UUID, refs: [AgenticIntakeImageRef]) -> Event {
        Event(
            id: eventID,
            title: "photo event",
            timeRanges: [Event.TimeRange(start: Date(), end: Date().addingTimeInterval(3600))],
            agenticIntake: AgenticIntakeRecord(rawText: "x", images: refs, source: .quickAdd)
        )
    }

    /// `attach()` kicks off its initial scan fire-and-forget on the main
    /// actor; yielding lets it run to completion (the mock never really
    /// suspends). Asserts rather than hangs when the scan never lands.
    private func drainScans(_ coordinator: ImageBackupCoordinator, atLeast n: Int,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 where coordinator.completedScanCount < n {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(coordinator.completedScanCount, n,
                                    "attach-driven scan never completed", file: file, line: line)
    }

    private func persistedMarkers(userID: String, in defaults: UserDefaults? = nil) -> Set<String> {
        Set((defaults ?? suite).stringArray(
            forKey: "imageBackup.confirmedUploadedObjects.\(userID)") ?? [])
    }

    /// The expected persisted-marker element for one cloud object —
    /// hand-rolled here (not shared with the coordinator's private helper)
    /// so a format regression in either side is visible.
    private func pair(_ eventID: UUID, _ ref: AgenticIntakeImageRef) -> String {
        "\(eventID.uuidString)/\(ref.id.uuidString)"
    }

    // MARK: - Tests

    /// gh#219's measured symptom: every cold launch re-read and re-POSTed
    /// every already-backed-up image, eating tens of MB of cellular for
    /// guaranteed 409s. Both 2xx and 409 are confirmed remote outcomes, so
    /// a relaunch must produce ZERO re-POSTs.
    /// Mutation gate: revert the marker persistence (don't flush, or don't
    /// load) → launch B re-POSTs → this dies.
    func testRelaunchThroughAttachDoesNotRePostConfirmedUploads() async throws {
        let eventID = UUID()
        let ref1 = makeImageRef(eventID: eventID)
        let ref2 = makeImageRef(eventID: eventID)
        try writeLocalFile(for: ref1)
        try writeLocalFile(for: ref2)
        let event = makeEvent(eventID: eventID, refs: [ref1, ref2])

        let mockA = MockStorage()
        mockA.outcomes[ref2.id] = .alreadyInCloud  // server already has it → 409
        let storeA = makeEventStore()
        storeA.events = [event]
        var coordinatorA: ImageBackupCoordinator? = makeCoordinator(mock: mockA)
        coordinatorA!.attach(eventStore: storeA, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinatorA!, atLeast: 1)
        XCTAssertEqual(mockA.uploadedImageIDs.count, 2, "launch A uploads both images once")
        XCTAssertEqual(Set(mockA.uploadedImageIDs), [ref1.id, ref2.id])

        // Process death. Only the suite and the asset files survive.
        coordinatorA = nil

        let mockB = MockStorage()
        let storeB = makeEventStore()
        storeB.events = [event]
        let coordinatorB = makeCoordinator(mock: mockB)
        coordinatorB.attach(eventStore: storeB, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinatorB, atLeast: 1)
        XCTAssertEqual(mockB.uploadedImageIDs, [],
                       "cold relaunch must not re-POST images the server confirmed (2xx or 409)")
    }

    /// gh#142 rule: a persisted marker for an upload that actually FAILED
    /// would mean the image is never backed up — not self-healing. So a
    /// 5xx leaves no durable marker, the same session retries on the next
    /// scan (failure clears the in-memory attempt), and the next launch
    /// retries too.
    /// Mutation gate: move the confirmed-marker insert before the upload
    /// outcome → launch B skips the never-uploaded image → this dies.
    func testFailedUploadLeavesNoMarkerAndRetries() async throws {
        let eventID = UUID()
        let ref = makeImageRef(eventID: eventID)
        try writeLocalFile(for: ref)
        let event = makeEvent(eventID: eventID, refs: [ref])

        let mockA = MockStorage()
        mockA.outcomes[ref.id] = .error(SupabaseImageStorageService.Error.httpFailure(status: 500))
        let storeA = makeEventStore()
        storeA.events = [event]
        var coordinatorA: ImageBackupCoordinator? = makeCoordinator(mock: mockA)
        coordinatorA!.attach(eventStore: storeA, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinatorA!, atLeast: 1)
        XCTAssertEqual(mockA.uploadedImageIDs, [ref.id], "the upload was attempted")
        XCTAssertEqual(persistedMarkers(userID: "user-a"), [],
                       "a failed upload must not leave a durable marker")

        // Same session, next scan: retried (in-memory attempt was cleared).
        await coordinatorA!.scanAndUpload(reason: "test-retry")
        XCTAssertEqual(mockA.uploadedImageIDs, [ref.id, ref.id],
                       "failure is retried within the session on the next scan")

        coordinatorA = nil

        // Next launch: retried, and this time the 2xx confirms it.
        let mockB = MockStorage()
        let storeB = makeEventStore()
        storeB.events = [event]
        let coordinatorB = makeCoordinator(mock: mockB)
        coordinatorB.attach(eventStore: storeB, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinatorB, atLeast: 1)
        XCTAssertEqual(mockB.uploadedImageIDs, [ref.id], "relaunch retries the failed upload")
        XCTAssertEqual(persistedMarkers(userID: "user-a"), [pair(eventID, ref)],
                       "the marker appears only after the confirmed 2xx")
    }

    /// The shipped defect: the ID was inserted into the suppression set
    /// BEFORE the local file read, and the missing-file return never
    /// removed it — so a once-missing file was only ever retried by the
    /// accident of process death. The durable marker must never cover a
    /// missing file (no remote outcome happened), which keeps that retry —
    /// now by design: next launch re-reads, and once the file
    /// materializes, uploads it.
    func testMissingLocalFileLeavesNoMarkerAndRetriesNextLaunch() async throws {
        let eventID = UUID()
        let refPresent = makeImageRef(eventID: eventID)
        let refMissing = makeImageRef(eventID: eventID)
        try writeLocalFile(for: refPresent)  // refMissing: no file on disk
        let event = makeEvent(eventID: eventID, refs: [refPresent, refMissing])

        let mockA = MockStorage()
        let storeA = makeEventStore()
        storeA.events = [event]
        var coordinatorA: ImageBackupCoordinator? = makeCoordinator(mock: mockA)
        coordinatorA!.attach(eventStore: storeA, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinatorA!, atLeast: 1)
        XCTAssertEqual(mockA.uploadedImageIDs, [refPresent.id],
                       "only the readable file goes over the wire")
        XCTAssertEqual(persistedMarkers(userID: "user-a"), [pair(eventID, refPresent)],
                       "a missing local file must not get a durable marker")

        // Same session: suppressed (no per-scan disk thrash / status spam).
        await coordinatorA!.scanAndUpload(reason: "test-again")
        XCTAssertEqual(mockA.uploadedImageIDs, [refPresent.id])

        coordinatorA = nil

        // The file materializes before the next launch (e.g. a restore
        // landed it). The relaunch — the deliberate retry — uploads it.
        try writeLocalFile(for: refMissing)
        let mockB = MockStorage()
        let storeB = makeEventStore()
        storeB.events = [event]
        let coordinatorB = makeCoordinator(mock: mockB)
        coordinatorB.attach(eventStore: storeB, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinatorB, atLeast: 1)
        XCTAssertEqual(mockB.uploadedImageIDs, [refMissing.id],
                       "next launch retries the once-missing file and only it")
        XCTAssertEqual(persistedMarkers(userID: "user-a"),
                       [pair(eventID, refPresent), pair(eventID, refMissing)])
    }

    /// `authService.$session` re-emits on EVERY attach (each attach
    /// re-subscribes, and a fresh subscription replays the current value).
    /// Clearing the durable set on that emission would wipe it every
    /// launch and silently turn the fix into a no-op that still passes a
    /// naive relaunch test. So: same user id → set survives; genuinely
    /// different user id → that user's own (empty) set is consulted, and
    /// the old user's persisted markers are neither read nor destroyed.
    /// Mutation gate: clear/reload-destroy on every attach → the re-attach
    /// step or the switch-back step dies.
    func testMarkersSurviveReattachAndAreKeyedByUser() async throws {
        let eventID = UUID()
        let ref = makeImageRef(eventID: eventID)
        try writeLocalFile(for: ref)
        let event = makeEvent(eventID: eventID, refs: [ref])

        let mock = MockStorage()
        let store = makeEventStore()
        store.events = [event]
        let coordinator = makeCoordinator(mock: mock)

        coordinator.attach(eventStore: store, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinator, atLeast: 1)
        XCTAssertEqual(mock.uploadedImageIDs, [ref.id])

        // Re-attach, same user, fresh AuthService instance (the replayed
        // emission): no re-POST, marker intact.
        coordinator.attach(eventStore: store, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinator, atLeast: 2)
        XCTAssertEqual(mock.uploadedImageIDs, [ref.id],
                       "re-attach with the same user must not re-POST")
        XCTAssertEqual(persistedMarkers(userID: "user-a"), [pair(eventID, ref)],
                       "re-attach with the same user must not clear the persisted set")

        // Different user: their set is separate, so the image uploads
        // again — under THEIR path prefix.
        coordinator.attach(eventStore: store, authService: makeAuth(userID: "user-b"))
        await drainScans(coordinator, atLeast: 3)
        XCTAssertEqual(mock.uploadedImageIDs, [ref.id, ref.id],
                       "another user's markers must not suppress this user's backup")
        XCTAssertEqual(mock.uploadedPaths.last.map { $0.hasPrefix("user-b/") }, true)
        XCTAssertEqual(persistedMarkers(userID: "user-a"), [pair(eventID, ref)],
                       "switching users must not destroy the previous user's markers")

        // And back: user-a's own persisted set is consulted again.
        coordinator.attach(eventStore: store, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinator, atLeast: 4)
        XCTAssertEqual(mock.uploadedImageIDs, [ref.id, ref.id],
                       "returning to a user re-reads their persisted set — no re-POST")
        XCTAssertEqual(persistedMarkers(userID: "user-b"), [pair(eventID, ref)])
    }

    /// The storage contract from the design round: ONE UserDefaults key,
    /// ONE coalesced write per scan completion — not one write per image.
    func testMarkersFlushInOneWritePerScan() async throws {
        let eventID = UUID()
        let refs = (0..<3).map { _ in makeImageRef(eventID: eventID) }
        for ref in refs { try writeLocalFile(for: ref) }
        let event = makeEvent(eventID: eventID, refs: refs)

        let spyName = "\(suiteName).spy"
        extraSuites.append(spyName)
        let spy = SpyDefaults(suiteName: spyName)!
        spy.removePersistentDomain(forName: spyName)
        spy.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)

        let mock = MockStorage()
        let store = makeEventStore()
        store.events = [event]
        let coordinator = makeCoordinator(mock: mock, defaults: spy)
        coordinator.attach(eventStore: store, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinator, atLeast: 1)
        XCTAssertEqual(mock.uploadedImageIDs.count, 3)
        XCTAssertEqual(spy.confirmedKeyWrites, 1,
                       "three confirmations in one scan coalesce into one write")
        XCTAssertEqual(persistedMarkers(userID: "user-a", in: spy),
                       Set(refs.map { pair(eventID, $0) }))

        // A scan that confirms nothing new writes nothing.
        await coordinator.scanAndUpload(reason: "test-idle")
        XCTAssertEqual(spy.confirmedKeyWrites, 1, "an idle scan must not rewrite the key")
    }

    /// A scan captures its user id at entry. If the signed-in user
    /// switches to a DIFFERENT user while an upload is over the wire, the
    /// durable set loaded in memory belongs to the new user — filing the
    /// stale outcome into it would flush a marker under the wrong
    /// identity: a wrong-skip whose cloud never gets the image, exactly
    /// the non-self-healing marker gh#142 forbids. The stale outcome is
    /// dropped instead, which self-heals as a single cheap 409 re-confirm
    /// in the original user's next session.
    ///
    /// Determinism: user-b's own attach-scan is made a provable no-op by
    /// flipping the upload toggle OFF for the rest of the switch window
    /// (whether the re-entry guard drops that scan or it runs the
    /// disabled path, it can neither POST nor confirm) — so the ONLY way
    /// `ref` can reach user-b's key is by mis-filing user-a's outcome.
    func testUserSwitchMidUploadDropsTheStaleOutcome() async throws {
        let eventID = UUID()
        let ref = makeImageRef(eventID: eventID)
        try writeLocalFile(for: ref)
        let event = makeEvent(eventID: eventID, refs: [ref])

        let mock = MockStorage()
        mock.gateUploads = true
        let store = makeEventStore()
        store.events = [event]
        let coordinator = makeCoordinator(mock: mock)
        coordinator.attach(eventStore: store, authService: makeAuth(userID: "user-a"))

        // Wait for user-a's upload to be in flight (recorded, then parked).
        for _ in 0..<10_000 where mock.uploadedImageIDs.isEmpty { await Task.yield() }
        XCTAssertEqual(mock.uploadedPaths, ["user-a/\(eventID.uuidString)/\(ref.id.uuidString).jpg"])

        // user-b signs in while the POST is over the wire; no scan user-b
        // owns may upload from here on.
        coordinator.attach(eventStore: store, authService: makeAuth(userID: "user-b"))
        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        mock.gateUploads = false
        mock.releaseParkedUpload()
        await drainScans(coordinator, atLeast: 1)  // user-a's scan runs to completion
        for _ in 0..<200 { await Task.yield() }    // let user-b's no-op scan land too

        XCTAssertEqual(mock.uploadedPaths.count, 1,
                       "no bytes ever went over the wire for user-b")
        XCTAssertEqual(persistedMarkers(userID: "user-b"), [],
                       "user-a's stale outcome must not be filed under user-b")
        XCTAssertEqual(persistedMarkers(userID: "user-a"), [],
                       "user-a's set was already swapped out; the drop is deliberate")

        // Dropping is the self-healing side: user-a's next session simply
        // re-confirms via a cheap 409 — no bytes lost, no wrong skip.
        suite.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        let mock2 = MockStorage()
        mock2.outcomes[ref.id] = .alreadyInCloud
        let coordinator2 = makeCoordinator(mock: mock2)
        coordinator2.attach(eventStore: store, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinator2, atLeast: 1)
        XCTAssertEqual(mock2.uploadedImageIDs, [ref.id], "the dropped mark costs one re-confirm")
        XCTAssertEqual(persistedMarkers(userID: "user-a"), [pair(eventID, ref)])
    }
}
