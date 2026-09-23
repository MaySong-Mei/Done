//
//  ImageBackupQAProbeTests.swift
//  DoneTests
//
//  Adopted from QA's adversarial probe for gh#219 (qa/image-backup-219 @
//  a5af3bc, same file name). QA's original demonstrated the BLOCKING
//  finding live: with the durable marker keyed by imageID alone, one
//  imageID confirmed under event E1's cloud path suppressed the upload of
//  the SAME imageID under event E2's path on every launch, forever — and
//  restore downloads by the live event's id, so E2's photo 404'd on any
//  fresh device once E1 was deleted. This adapted copy asserts the FIXED
//  invariant: every (event, imageRef) surface pair gets its own cloud
//  object. Reverting the re-key (marker back to imageID-only) must make
//  this test fail at the launch-A assertion.
//
//  Production flows that put ONE imageID under TWO event ids:
//    - Event.swift ~1803 (`.single` detach: `var instance = series;
//      instance.id = UUID()` — agenticIntake carried by the value copy)
//    - Event.swift ~1879 (`.following` split, same shape)
//    - AddToCalendarView.swift:58 (`var calEvent = event; calEvent.id =
//      UUID()` — todo copied onto the calendar with its intake)
//

import XCTest
import Combine
@testable import Done

@MainActor
final class ImageBackupQAProbeTests: XCTestCase {

    final class MockStorage: ImageStorageServicing {
        var uploadsDisabled = false
        /// Paths for which `download` returns bytes (the scripted cloud).
        var cloudObjects: [String: Data] = [:]
        private(set) var uploadedPaths: [String] = []
        private(set) var downloadRequestedPaths: [String] = []

        func storagePath(userID: String, eventID: UUID, imageID: UUID) -> String {
            "\(userID)/\(eventID.uuidString)/\(imageID.uuidString).jpg"
        }
        func upload(path: String, data: Data) async throws -> Bool {
            uploadedPaths.append(path)
            if cloudObjects[path] != nil { return false }  // 409
            cloudObjects[path] = data                       // 2xx
            return true
        }
        func download(path: String) async throws -> Data? {
            downloadRequestedPaths.append(path)
            return cloudObjects[path]                       // nil = 404
        }
        func uploadAvatar(userID: String, data: Data) async throws -> Bool { true }
        func downloadAvatar(userID: String) async throws -> Data? { nil }
        func deleteAvatar(userID: String) async {}
    }

    private var suiteName = ""
    private var suite: UserDefaults!
    private var storageLocation: EventStorageLocation!
    private var assetDir: URL!
    private var extraSuites: [String] = []
    private var liveAuthServices: [AuthService] = []

    override func setUp() {
        super.setUp()
        suiteName = "ImageBackupQAProbeTests-\(UUID().uuidString)"
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

    private func makeAuth(userID: String) -> AuthService {
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

    private func makeCoordinator(mock: MockStorage) -> ImageBackupCoordinator {
        ImageBackupCoordinator(
            defaults: suite,
            assetStore: AgenticIntakeAssetStore(baseDirectoryURL: assetDir),
            storageServiceFactory: { _ in mock }
        )
    }

    private func drainScans(_ coordinator: ImageBackupCoordinator, atLeast n: Int,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 where coordinator.completedScanCount < n {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(coordinator.completedScanCount, n,
                                    "attach-driven scan never completed", file: file, line: line)
    }

    /// One imageID under two event ids — the shape `.single`/`.following`
    /// materialization and Add-to-Calendar produce. The durable marker is
    /// keyed by the `(eventID, imageID)` pair that names the cloud object,
    /// so launch A must upload BOTH events' paths (restore downloads by the
    /// LIVE event's id — `downloadMissing` builds the path from
    /// `p.eventID`). The user then deletes E1, keeping the detached copy
    /// E2; a relaunch re-POSTs nothing (E2's pair marker is durable), and a
    /// fresh-device restore finds E2's photo at E2's own path.
    ///
    /// Mutation gate (the gh#219 QA blocker): re-key the marker back to
    /// imageID-only → launch A confirms under E1's path only, E2's object
    /// is never uploaded on ANY launch, and the restore 404s — the
    /// launch-A assertion below dies first.
    func testQAProbe_SharedImageIDAcrossTwoEvents_EachEventPathGetsItsOwnCloudObject() async throws {
        let e1 = UUID()
        let e2 = UUID()
        let imageID = UUID()
        // As detach produces: same ref value (same id, same relativePath
        // rooted at the ORIGINAL event's directory) on both events.
        let ref = AgenticIntakeImageRef(
            id: imageID,
            relativePath: "\(e1.uuidString)/\(imageID.uuidString).jpg",
            pixelWidth: 10, pixelHeight: 10, fileSizeBytes: 3
        )
        let fileURL = assetDir.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: fileURL)

        func event(_ id: UUID) -> Event {
            Event(
                id: id,
                title: "photo event",
                timeRanges: [Event.TimeRange(start: Date(), end: Date().addingTimeInterval(3600))],
                agenticIntake: AgenticIntakeRecord(rawText: "x", images: [ref], source: .quickAdd)
            )
        }
        let e1Path = "user-a/\(e1.uuidString)/\(imageID.uuidString).jpg"
        let e2Path = "user-a/\(e2.uuidString)/\(imageID.uuidString).jpg"

        // Launch A: both events present. Every (event, imageID) pair gets
        // its own cloud object — one POST each, none doubled.
        let mockA = MockStorage()
        let storeA = makeEventStore()
        storeA.events = [event(e1), event(e2)]
        var coordinatorA: ImageBackupCoordinator? = makeCoordinator(mock: mockA)
        coordinatorA!.attach(eventStore: storeA, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinatorA!, atLeast: 1)
        XCTAssertEqual(Set(mockA.uploadedPaths), [e1Path, e2Path],
                       "each event id names its own cloud object; per-imageID dedup " +
                       "would suppress the second path — the gh#219 QA blocker")
        XCTAssertEqual(mockA.uploadedPaths.count, 2, "exactly one POST per pair")
        let cloud = mockA.cloudObjects  // what the real bucket now holds

        // E1 is deleted; the detached copy E2 survives. Process death.
        coordinatorA = nil

        // Launch B: only E2 remains. Its pair marker is durable, so a cold
        // relaunch re-POSTs nothing.
        let mockB = MockStorage()
        mockB.cloudObjects = cloud
        let storeB = makeEventStore()
        storeB.events = [event(e2)]
        let coordinatorB = makeCoordinator(mock: mockB)
        coordinatorB.attach(eventStore: storeB, authService: makeAuth(userID: "user-a"))
        await drainScans(coordinatorB, atLeast: 1)
        XCTAssertEqual(mockB.uploadedPaths, [],
                       "E2's object was confirmed under E2's OWN pair in launch A — " +
                       "no re-POST on relaunch")

        // The user-visible stake: fresh device (no local file), restore
        // runs, and the photo comes back from E2's own path.
        try? FileManager.default.removeItem(at: fileURL)
        await coordinatorB.downloadMissing(forEvents: [event(e2)])
        XCTAssertEqual(mockB.downloadRequestedPaths, [e2Path],
                       "restore keys the download by the LIVE event's id")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "the photo must be reachable at the surviving event's path")
    }
}
