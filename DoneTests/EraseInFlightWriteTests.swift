//
//  EraseInFlightWriteTests.swift
//  DoneTests
//
//  Two things the erase could not do by deleting harder, and the test-host
//  seams that stop the suite itself from being the destructive agent.
//
//  PART 1 — in-flight writes (`LocalDataEraseEpoch`). An operation that
//  started before "erase all local data" and finishes after it writes user
//  content into a directory the erase just emptied. Three such paths; each
//  gets a refusal test with a positive control, because "nothing was written"
//  is a claim that an inert fixture satisfies for free.
//
//  PART 2 — the test host. `DoneTests` runs inside Done.app, in Done.app's
//  container. Several purge-capable stores resolved container-wide paths with
//  no XCTest redirect, so running this suite on a dogfood device destroyed
//  that user's own data. The witnesses here are shaped to prove it from the
//  outside: plant a sentinel at the PRODUCTION path, run the purge, assert
//  the sentinel survived. Each one fails on the pre-fix code.
//

import XCTest
import UIKit
@testable import Done

@MainActor
final class EraseInFlightWriteTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("EraseInFlightWriteTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// `ImageBackupCoordinator.init`'s `assetStore` default resolves the
    /// container-wide shared asset directory. Nothing here writes through it,
    /// but a test that constructs one is one edit away from doing so, so the
    /// rig hands it a scratch directory instead.
    private func makeCoordinator(defaults: UserDefaults) -> ImageBackupCoordinator {
        ImageBackupCoordinator(
            defaults: defaults,
            assetStore: AgenticIntakeAssetStore(
                baseDirectoryURL: scratch.appendingPathComponent("assets", isDirectory: true))
        )
    }

    // MARK: - Part 1a: the epoch primitive

    /// The contract in one test, including the direction that matters most:
    /// a token taken AFTER the bump is fresh. Without that half, "always
    /// stale" would pass every refusal test in this file and quietly disable
    /// report generation, image restore and usage accounting for the rest of
    /// the process.
    func testTheEpochGoesStaleOnBumpAndFreshTokensStayFresh() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let before = LocalDataEraseEpoch.capture()
            XCTAssertFalse(LocalDataEraseEpoch.isStale(before),
                           "a token with no erase in between must be fresh")

            LocalDataEraseEpoch.bump()
            XCTAssertTrue(LocalDataEraseEpoch.isStale(before),
                          "an erase happened after this token was taken")

            let after = LocalDataEraseEpoch.capture()
            XCTAssertFalse(LocalDataEraseEpoch.isStale(after),
                           "a token taken after the erase is NOT stale — otherwise the app "
                           + "never writes anything again")

            LocalDataEraseEpoch.bump()
            XCTAssertTrue(LocalDataEraseEpoch.isStale(after),
                          "and a second erase invalidates it in turn")
        }
    }

    /// The seam this file's other tests depend on. A leaked bump would make
    /// every later-running test in the whole suite hold a stale token, which
    /// surfaces as flakes that depend on test ordering.
    func testTheIsolationSeamRestoresTheEpochSoOtherTestsAreUnaffected() {
        let outer = LocalDataEraseEpoch.capture()
        LocalDataEraseEpoch.withIsolatedEpoch {
            LocalDataEraseEpoch.bump()
            LocalDataEraseEpoch.bump()
            XCTAssertTrue(LocalDataEraseEpoch.isStale(outer), "liveness: it really did bump")
        }
        XCTAssertFalse(LocalDataEraseEpoch.isStale(outer),
                       "the seam must restore the counter — a leak makes every subsequent "
                       + "test in the suite hold a stale token")
    }

    /// Pins the ONE ordering rule the primitive has: the erase bumps before
    /// it purges, not after. Bumping last would leave the entire duration of
    /// the erase uncovered — which is exactly the window the three writers
    /// resume in.
    ///
    /// Source-level because `resetAllLocalData` is a private method on a
    /// SwiftUI view with no test entry point. `#filePath` is this file's
    /// location at COMPILE time, so two directories up is the checkout the
    /// binary was built from (the `BackupSnapshotDirtyCheckTests` idiom).
    func testTheEraseBumpsTheEpochBeforeItPurgesAnything() throws {
        let body = try Self.eraseBody()
        guard let bump = body.range(of: "LocalDataEraseEpoch.bump()") else {
            return XCTFail(
                "resetAllLocalData must bump the erase epoch — without it an in-flight "
                + "report, image download or usage record writes user data back into the "
                + "directories this function just emptied"
            )
        }
        guard let firstPurge = body.range(of: "store.clearAllLocalData()") else {
            return XCTFail("store.clearAllLocalData() moved — re-derive the ordering anchor")
        }
        XCTAssertTrue(bump.lowerBound < firstPurge.lowerBound,
                      "the bump must come BEFORE the first purge: a writer's continuation can "
                      + "resume at any suspension point the erase itself reaches, so bumping "
                      + "afterwards leaves the whole erase uncovered")
    }

    /// Reads `resetAllLocalData`'s body out of the checkout.
    ///
    /// Throws a plain error, never `XCTSkip`, when an anchor moves: XCTest
    /// reports a thrown `XCTSkip` as a SKIP and anything else as a failure,
    /// and a guard that cannot find what it guards is a guard that is not
    /// running. It must go red, not quiet.
    private struct AnchorMoved: Error, CustomStringConvertible {
        let description: String
    }

    private static func eraseBody() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/Views/Agent/AgentSettingsView.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "private func resetAllLocalData() {") else {
            throw AnchorMoved(description: "resetAllLocalData has been renamed — re-point this guard")
        }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }\n") else {
            throw AnchorMoved(description: "could not find the end of resetAllLocalData")
        }
        return String(rest[..<end.lowerBound])
    }

    // MARK: - Part 1b: the report that outlived the erase

    /// The worst of the three. `Documents/Reports/` holds an LLM-written
    /// narrative of the user's events plus the frozen `statsSnapshot` and any
    /// `userNote` — their own words — and `ReportStore.save` recreates the
    /// directory it writes into. So an erase during a provider call (tens of
    /// seconds) was followed by the directory coming back with a description
    /// of the erased data in it.
    ///
    /// Drives `saveIfStillWanted` rather than `generate()` deliberately:
    /// `generate()` builds its provider from `UserDefaults.standard`, which
    /// under XCTest is the dogfood user's own API key, and the test would
    /// issue a real billed request against it.
    func testAReportGeneratedAcrossAnEraseIsNotWritten() throws {
        let dir = scratch.appendingPathComponent("Reports", isDirectory: true)
        let service = ReportGenerationService(store: ReportStore(directoryURL: dir))
        let note = "ERASED-MID-GENERATION-\(UUID().uuidString)"
        let report = Self.makeReport(userNote: note)

        try LocalDataEraseEpoch.withIsolatedEpoch {
            let token = LocalDataEraseEpoch.capture()
            LocalDataEraseEpoch.bump()          // the user taps "erase all local data"

            XCTAssertThrowsError(try service.saveIfStillWanted(report, eraseEpoch: token)) { error in
                guard case ReportGenerationError.erasedDuringGeneration = error else {
                    return XCTFail("expected .erasedDuringGeneration, got \(error)")
                }
            }
            XCTAssertFalse(exists(dir),
                           "the directory the erase removed must NOT be recreated")
            XCTAssertTrue(ReportStore(directoryURL: dir).loadAll().isEmpty,
                          "and nothing must be readable back")
        }

        // POSITIVE CONTROL. Same service, same report, no erase — it must
        // land, in plaintext, note and all. Without this the assertions above
        // are satisfied by a save path that never worked.
        try LocalDataEraseEpoch.withIsolatedEpoch {
            let token = LocalDataEraseEpoch.capture()
            try service.saveIfStillWanted(report, eraseEpoch: token)
            let file = dir.appendingPathComponent("\(report.id.uuidString).json")
            XCTAssertTrue(exists(file), "positive control: with no erase the report must save")
            let bytes = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
            XCTAssertTrue(bytes.contains(note),
                          "positive control: and the user's own words must really be the thing "
                          + "that the refusal above kept off disk")
        }
    }

    // MARK: - Part 1c: the usage ledger

    /// Smallest of the three — counters, not content — but the same race, and
    /// the discriminator has to be the token. A bucket folded by an in-flight
    /// request and one folded by the user's next legitimate action a minute
    /// later are identical on disk, so "refuse after an erase" would break
    /// accounting permanently.
    ///
    /// `LLMProvider`'s record helpers are file-private, so this drives the
    /// rule they apply (`isStale` → skip) against the store itself.
    func testTheUsageLedgerDistinguishesAPreEraseRequestFromAPostEraseOne() throws {
        let dir = scratch.appendingPathComponent("DeveloperStats", isDirectory: true)
        let store = LLMUsageStore(directoryURL: dir)

        LocalDataEraseEpoch.withIsolatedEpoch {
            let inFlight = LocalDataEraseEpoch.capture()
            store.record(model: "m", purpose: "report",
                         inputTokens: 1, cachedInputTokens: 0, outputTokens: 1)
            XCTAssertEqual(store.allBuckets().count, 1, "liveness: recording works at all")

            // The erase: clearAll() is what `resetAllLocalData` calls.
            LocalDataEraseEpoch.bump()
            store.clearAll()
            XCTAssertTrue(store.allBuckets().isEmpty, "liveness: the ledger really is empty")

            // The pre-erase request comes back. The provider's helpers drop it.
            if !LocalDataEraseEpoch.isStale(inFlight) {
                store.record(model: "m", purpose: "report",
                             inputTokens: 9, cachedInputTokens: 0, outputTokens: 9)
            }
            XCTAssertTrue(store.allBuckets().isEmpty,
                          "a request that predates the erase must not refill the ledger")

            // POSITIVE CONTROL: the user's next real request must still count.
            let fresh = LocalDataEraseEpoch.capture()
            if !LocalDataEraseEpoch.isStale(fresh) {
                store.record(model: "m", purpose: "chat",
                             inputTokens: 2, cachedInputTokens: 0, outputTokens: 2)
            }
            XCTAssertEqual(store.allBuckets().count, 1,
                           "positive control: post-erase activity must still be accounted — "
                           + "otherwise the rule is 'never record again'")
        }
    }

    // MARK: - Part 1d: the confirmed-upload markers

    /// `imageBackup.confirmedUploadedObjects.<userID>` is a never-pruned list
    /// of `<eventID>/<imageID>` pairs — the user's own event ids — in
    /// `UserDefaults.standard`, and therefore in device and iCloud backup. It
    /// survived the erase outright: the by-name sweep does not cover per-user
    /// keys, and the erase's prefix scan knew about
    /// `lastSyncedAvatarVersion.` and `hasOfferedAutoRestore.` only.
    ///
    /// Every user id goes, not just the signed-in one: a device that has
    /// hosted two accounts has two keys, and "erase all local data" means the
    /// local data.
    func testForgettingConfirmedUploadsTakesEveryUsersMarkersAndTheLegacyFormat() throws {
        let suiteName = "EraseInFlightWriteTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let liveA = ImageBackupCoordinator.confirmedUploadsKeyPrefix + "user-A"
        let liveB = ImageBackupCoordinator.confirmedUploadsKeyPrefix + "user-B"
        let legacy = ImageBackupCoordinator.legacyConfirmedUploadsKeyPrefix + "user-A"
        let bystander = "imageBackup.somethingElse"
        suite.set(["E1/I1", "E2/I2"], forKey: liveA)
        suite.set(["E3/I3"], forKey: liveB)
        suite.set(["I4"], forKey: legacy)
        suite.set(["keep me"], forKey: bystander)

        let coordinator = makeCoordinator(defaults: suite)
        XCTAssertNotNil(suite.stringArray(forKey: liveA), "liveness: the key is really set")

        coordinator.forgetConfirmedUploads()

        XCTAssertNil(suite.stringArray(forKey: liveA), "the signed-in user's markers must go")
        XCTAssertNil(suite.stringArray(forKey: liveB),
                     "and the other account's — this is 'erase all LOCAL data', not "
                     + "'erase this session's share of it'")
        XCTAssertNil(suite.stringArray(forKey: legacy), "including the abandoned format")
        XCTAssertEqual(suite.stringArray(forKey: bystander), ["keep me"],
                       "positive control: the sweep is prefix-scoped, not a domain wipe")
    }

    /// The `forgetReauthenticationNotice` rule, applied here. The coordinator
    /// holds the same set in memory behind a dirty flag, so deleting the key
    /// behind its back would last exactly until the next flush wrote the
    /// whole set straight back.
    ///
    /// ⚠️ The first version of this test seeded the key with `suite.set` and
    /// then called the flush. It was green against a mutant that dropped the
    /// in-memory clear — because a coordinator that never LOADED the key has
    /// nothing in memory and `confirmedUploadsDirty == false`, so the flush
    /// returns at its own guard and the mutant is invisible. The fixture had
    /// taken a shortcut around the branch the test is named after.
    ///
    /// So the dirty state is now produced the way production produces it:
    /// `downloadMissing` confirms image 1, the erase lands during image 2.
    /// That is also the only shape in which the post-loop flush decision is
    /// observable at all — with nothing confirmed, flushing and not flushing
    /// look identical.
    func testAnEraseMidRestoreNeitherFlushesNorRetainsThePreEraseConfirmations() async throws {
        let rig = try makeRestoreRig()
        defer { rig.tearDown() }

        try await LocalDataEraseEpoch.withIsolatedEpoch {
            // Image 1 completes in full — downloaded, written, CONFIRMED (so
            // the coordinator is now dirty). The erase lands during image 2.
            rig.mock.onDownload = { n in if n == 2 { LocalDataEraseEpoch.bump() } }
            await rig.coordinator.downloadMissing(forEvents: [rig.event])

            XCTAssertTrue(
                self.exists(rig.assetDir.appendingPathComponent(rig.refs[0].relativePath)),
                "liveness: image 1 was written before the erase — that is what makes the "
                + "coordinator dirty, and it is the state the assertions below are about")
            XCTAssertFalse(
                self.exists(rig.assetDir.appendingPathComponent(rig.refs[1].relativePath)),
                "image 2 finished downloading after the erase and must not be written")

            XCTAssertNil(rig.markers(),
                         "image 1's confirmation must NOT be flushed: it is an event id, and "
                         + "the erase had just removed this key")

            // And the in-memory set must be gone too, or the next flush —
            // from any later scan — writes it back.
            rig.coordinator.flushConfirmedUploadsIfDirty()
            XCTAssertNil(rig.markers(),
                         "a later flush must not resurrect it either: the in-memory set and "
                         + "its dirty flag have to be cleared, not just the key")
        }
    }

    /// The 404 path is what earns the loop's pre-download gate. A cloud object
    /// that is missing `continue`s without reaching the write gate, so with
    /// only that gate the loop runs to the end and fetches every remaining
    /// image over the network after the erase.
    ///
    /// Written because mutating the pre-download gate away left the whole
    /// suite green: the other restore tests all use an image that comes back,
    /// and for those the write gate's `break` ends the loop anyway.
    func testAnEraseStopsTheRestoreLoopEvenWhenTheCloudObjectsAreMissing() async throws {
        let rig = try makeRestoreRig()
        defer { rig.tearDown() }

        try await LocalDataEraseEpoch.withIsolatedEpoch {
            rig.mock.payload = nil      // every object 404s
            rig.mock.onDownload = { n in if n == 1 { LocalDataEraseEpoch.bump() } }
            await rig.coordinator.downloadMissing(forEvents: [rig.event])

            XCTAssertEqual(rig.mock.downloadedPaths.count, 1,
                           "the loop must stop at the erase. With only the write gate, a 404 "
                           + "`continue`s past it and all 3 are fetched")
        }

        // POSITIVE CONTROL: with no erase, all three ARE attempted — so the
        // count above is the gate working, not the loop failing to start.
        try await LocalDataEraseEpoch.withIsolatedEpoch {
            rig.mock.onDownload = nil
            await rig.coordinator.downloadMissing(forEvents: [rig.event])
            XCTAssertEqual(rig.mock.downloadedPaths.count, 4,
                           "positive control: the remaining three must be attempted")
        }
    }

    /// The upload scan files the same confirmations and has the same coalesced
    /// flush at the end, so it has the same race. Found by reading the diff —
    /// no mutant pointed at it, because nothing was testing it.
    ///
    /// The upload is parked mid-flight and the erase fired while it is parked:
    /// that is "the user taps erase while a photo is being uploaded".
    func testAnEraseDuringAnUploadScanDoesNotFileTheConfirmation() async throws {
        let rig = try makeRestoreRig(uploadsEnabled: true)
        defer { rig.tearDown() }
        // The scan reads events off the store, not a parameter.
        rig.store.events = [rig.event]
        // Local bytes must exist or the scan has nothing to upload.
        for ref in rig.refs {
            let url = rig.assetDir.appendingPathComponent(ref.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        }

        try await LocalDataEraseEpoch.withIsolatedEpoch {
            rig.mock.onUpload = { n in if n == 2 { LocalDataEraseEpoch.bump() } }
            await rig.coordinator.scanAndUpload(reason: "test")

            XCTAssertGreaterThan(rig.mock.uploadedPaths.count, 1,
                                 "liveness: the scan must really have uploaded, or the "
                                 + "absence below proves nothing")
            XCTAssertNil(rig.markers(),
                         "a scan interrupted by the erase must not file its confirmations: "
                         + "they are the user's event ids, in a backed-up key the erase "
                         + "had just removed")
        }

        // POSITIVE CONTROL: the same scan with no erase DOES file them.
        try await LocalDataEraseEpoch.withIsolatedEpoch {
            rig.mock.onUpload = nil
            await rig.coordinator.scanAndUpload(reason: "test-control")
            XCTAssertEqual(rig.markers()?.count, rig.refs.count,
                           "positive control: with no erase every confirmation must land — "
                           + "otherwise the absence above is a broken scan")
        }
    }

    // MARK: - Part 1e: the photographs the restore put back

    /// A scriptable storage mock. `onDownload`/`onUpload` fire BEFORE the
    /// call answers, which is the only place a test can stand inside the
    /// coordinator's loop — it is how "the user taps erase while image 2 of 3
    /// is in flight" gets expressed. A `nil` payload is a 404.
    private final class ScriptedStorage: ImageStorageServicing {
        /// False so a DEBUG test run exercises the live upload path.
        var uploadsDisabled = false
        var payload: Data? = Data([0xFF, 0xD8, 0xFF, 0xD9])
        var onDownload: ((Int) -> Void)?
        var onUpload: ((Int) -> Void)?
        private(set) var downloadedPaths: [String] = []
        private(set) var uploadedPaths: [String] = []

        func storagePath(userID: String, eventID: UUID, imageID: UUID) -> String {
            "\(userID)/\(eventID.uuidString)/\(imageID.uuidString).jpg"
        }
        func upload(path: String, data: Data) async throws -> Bool {
            uploadedPaths.append(path)
            onUpload?(uploadedPaths.count)
            return true
        }
        func download(path: String) async throws -> Data? {
            downloadedPaths.append(path)
            onDownload?(downloadedPaths.count)
            return payload
        }
        func uploadAvatar(userID: String, data: Data) async throws -> Bool { true }
        func downloadAvatar(userID: String) async throws -> Data? { nil }
        func deleteAvatar(userID: String) async {}
    }

    /// Everything the restore/scan tests need, in one place. `auth` is held
    /// here because the coordinator keeps it WEAKLY (production retains it
    /// via `@StateObject`) — a temporary would deallocate and every
    /// `guard let userID` would silently no-op the test.
    private struct RestoreRig {
        let coordinator: ImageBackupCoordinator
        let mock: ScriptedStorage
        let auth: AuthService
        let store: EventStore
        let suite: UserDefaults
        let suiteName: String
        let assetDir: URL
        let event: Event
        let refs: [AgenticIntakeImageRef]
        let userID: String

        func markers() -> [String]? {
            suite.stringArray(
                forKey: ImageBackupCoordinator.confirmedUploadsKeyPrefix + userID)
        }
        func tearDown() {
            suite.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: suiteName + ".auth")?
                .removePersistentDomain(forName: suiteName + ".auth")
        }
    }

    private func makeRestoreRig(uploadsEnabled: Bool = false) throws -> RestoreRig {
        let suiteName = "EraseInFlightWriteTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.set(uploadsEnabled, forKey: AppSettingsKeys.syncUploadsEnabled)
        let assetDir = scratch.appendingPathComponent("assets-\(UUID().uuidString)",
                                                      isDirectory: true)
        let mock = ScriptedStorage()
        let coordinator = ImageBackupCoordinator(
            defaults: suite,
            assetStore: AgenticIntakeAssetStore(baseDirectoryURL: assetDir),
            storageServiceFactory: { _ in mock }
        )
        let userID = "user-restore"
        let auth = try Self.makeAuth(userID: userID, suiteName: suiteName + ".auth")
        let store = EventStore(defaults: suite,
                               storage: .ephemeral(id: UUID()),
                               seedsSampleDataIfEmpty: false)
        coordinator.attach(eventStore: store, authService: auth)

        let eventID = UUID()
        let refs = (0..<3).map { _ in Self.makeImageRef(eventID: eventID) }
        let event = Event(
            id: eventID,
            title: "restored photo event",
            timeRanges: [Event.TimeRange(start: Date(), end: Date().addingTimeInterval(3600))],
            agenticIntake: AgenticIntakeRecord(rawText: "x", images: refs, source: .quickAdd)
        )
        return RestoreRig(coordinator: coordinator, mock: mock, auth: auth, store: store,
                          suite: suite, suiteName: suiteName, assetDir: assetDir,
                          event: event, refs: refs, userID: userID)
    }

    /// The widest window of the three. `downloadMissing` computes its pending
    /// list from the PRE-erase store, then spends one `await` per image —
    /// minutes, for a real restore — and each iteration does
    /// `createDirectory` + `write`. So an erase landing mid-restore had the
    /// remaining iterations recreate `AgenticIntakeAssets/`, which
    /// `resetAllLocalData` had just removed wholesale, and put the user's
    /// photographs back into it one at a time.
    ///
    /// The erase is fired from inside the mock's FIRST download: the earliest
    /// moment it can land, with the pending list already computed and nothing
    /// yet on disk.
    func testAnEraseMidRestoreStopsTheRemainingPhotographsFromBeingWrittenBack() async throws {
        let rig = try makeRestoreRig()
        defer { rig.tearDown() }

        for ref in rig.refs {
            XCTAssertFalse(exists(rig.assetDir.appendingPathComponent(ref.relativePath)),
                           "liveness: the local file must be missing, or it is not pending")
        }

        try await LocalDataEraseEpoch.withIsolatedEpoch {
            rig.mock.onDownload = { n in if n == 1 { LocalDataEraseEpoch.bump() } }
            await rig.coordinator.downloadMissing(forEvents: [rig.event])

            XCTAssertEqual(rig.mock.downloadedPaths.count, 1,
                           "the loop must stop at the erase, not keep fetching")
            for (index, ref) in rig.refs.enumerated() {
                XCTAssertFalse(
                    self.exists(rig.assetDir.appendingPathComponent(ref.relativePath)),
                    "image \(index + 1) must not be on disk: the first was fetched before "
                    + "the erase but written after it, and the rest were never fetched"
                )
            }
            XCTAssertNil(rig.markers(),
                         "and the confirmation markers — the user's event ids — must not be "
                         + "flushed back after the erase removed them")
        }

        // POSITIVE CONTROL. Same coordinator, same refs, no erase: all three
        // must land, with bytes. Without this, every assertion above is
        // satisfied by a download path that never worked.
        try await LocalDataEraseEpoch.withIsolatedEpoch {
            rig.mock.onDownload = nil
            await rig.coordinator.downloadMissing(forEvents: [rig.event])

            XCTAssertEqual(rig.mock.downloadedPaths.count, 4,
                           "positive control: the remaining three must now be fetched")
            for (index, ref) in rig.refs.enumerated() {
                let url = rig.assetDir.appendingPathComponent(ref.relativePath)
                XCTAssertTrue(self.exists(url),
                              "positive control: image \(index + 1) must land with no erase")
                XCTAssertEqual(try Data(contentsOf: url), rig.mock.payload,
                               "positive control: and carry the downloaded bytes")
            }
            XCTAssertEqual(
                Set(rig.markers() ?? []),
                Set(rig.refs.map { "\(rig.event.id.uuidString)/\($0.id.uuidString)" }),
                "positive control: and the markers must be flushed — so their ABSENCE above "
                + "is the refusal working, not the flush being broken"
            )
        }
    }

    /// The coordinator holds `AuthService` weakly (production retains it via
    /// `@StateObject`), so the caller keeps the returned service alive for the
    /// test's duration — a temporary would deallocate and the `guard let
    /// userID` would silently no-op the whole scan.
    private static func makeAuth(userID: String, suiteName: String) throws -> AuthService {
        let authSuite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        authSuite.removePersistentDomain(forName: suiteName)
        let session = AuthSession(
            accessToken: "test-token",
            refreshToken: "test-refresh",
            expiresAt: .distantFuture,
            user: AuthUser(id: userID, email: nil, createdAt: nil)
        )
        authSuite.set(try JSONEncoder().encode(session), forKey: "supabaseAuthSession")
        return AuthService(defaults: authSuite)
    }

    private static func makeImageRef(eventID: UUID) -> AgenticIntakeImageRef {
        let id = UUID()
        return AgenticIntakeImageRef(
            id: id,
            relativePath: "\(eventID.uuidString)/\(id.uuidString).jpg",
            pixelWidth: 10, pixelHeight: 10, fileSizeBytes: 4
        )
    }

    // MARK: - Part 2: the suite must not be the destructive agent

    /// `DiagnosticTrail` was the worst case of this class. `clear()` is wired
    /// into the erase, `EventStore.clearAllLocalData` calls it as its LAST
    /// statement, ~20 test call sites reach that, and five test files call
    /// `clear()` directly — against a container-wide path with no redirect.
    ///
    /// And it is the one file with no second copy: the trail exists to answer
    /// "did the write the app reported before it died actually survive?",
    /// which is answered by comparing a DEAD process's last lines against
    /// this one's first. iOS will not let a third-party app read the system
    /// log store back (see the file header), so a destroyed trail is gone.
    /// The suite was silently erasing the record of the bug a run might be
    /// investigating.
    ///
    /// Shaped as a sentinel at the PRODUCTION path so it fails on the pre-fix
    /// code, and written only when nothing is there — on a real device the
    /// branch that runs is the second one, which asserts the existing bytes
    /// are untouched.
    func testTheDiagnosticTrailIsRedirectedSoTheSuiteCannotDestroyTheRealOne() throws {
        XCTAssertTrue(EventStorageLocation.isRunningUnderXCTest,
                      "this whole file's premise — if this is false the seams are inert")

        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let production = base.appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("trail.log")

        XCTAssertFalse(DiagnosticTrail.liveURL.path.hasPrefix(production.deletingLastPathComponent().path + "/"),
                       "under XCTest the trail must not resolve into the production directory")
        XCTAssertTrue(DiagnosticTrail.liveURL.path.contains("Diagnostics-TestHost"),
                      "and it must resolve into the redirected one")

        let planted = !exists(production)
        if planted {
            try FileManager.default.createDirectory(
                at: production.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("SENTINEL\n".utf8).write(to: production)
        }
        let before = try Data(contentsOf: production)
        defer {
            if planted { try? FileManager.default.removeItem(at: production) }
        }

        // The destructive act, through both production entry points.
        DiagnosticTrail.record("Test", "seam witness")
        DiagnosticTrail.clear()

        XCTAssertEqual(try Data(contentsOf: production), before,
                       "the real trail must survive a test-host clear() untouched")

        // POSITIVE CONTROL: clear() is not a no-op — it really does empty the
        // redirected files, so the survival above is the redirect working
        // rather than clear() being broken.
        DiagnosticTrail.record("Test", "positive control")
        XCTAssertGreaterThan(DiagnosticTrail.retainedByteCount, 0,
                             "positive control: the redirected trail accepts writes")
        DiagnosticTrail.clear()
        XCTAssertEqual(DiagnosticTrail.retainedByteCount, 0,
                       "positive control: and clear() really empties it")
    }

    /// Same shape for the avatar. `MeAvatarStore.delete()` sits in
    /// `resetAllLocalData()` and resolved `Documents/me-avatar.jpg` — one path
    /// for the whole container. The file is an image the user chose and may
    /// no longer hold the original of.
    func testTheMeAvatarIsRedirectedSoTheSuiteCannotDeleteTheRealOne() throws {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let production = documents.appendingPathComponent("me-avatar.jpg")

        XCTAssertEqual(MeAvatarStore.fileName, "me-avatar-test-host.jpg",
                       "under XCTest the avatar must resolve to the test-host name")
        XCTAssertNotEqual(MeAvatarStore.url, production,
                          "and therefore not to the production path")

        let planted = !exists(production)
        if planted { try Data("SENTINEL".utf8).write(to: production) }
        let before = try Data(contentsOf: production)
        defer {
            if planted { try? FileManager.default.removeItem(at: production) }
        }

        MeAvatarStore.delete()

        XCTAssertEqual(try Data(contentsOf: production), before,
                       "the real avatar must survive a test-host delete()")

        // POSITIVE CONTROL: delete() is live against the redirected slot.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        XCTAssertTrue(MeAvatarStore.save(image),
                      "positive control: the redirected slot accepts a save")
        XCTAssertTrue(MeAvatarStore.hasImage)
        MeAvatarStore.delete()
        XCTAssertFalse(MeAvatarStore.hasImage,
                       "positive control: and delete() really removes it")
    }

    // MARK: - The key both censuses could not see

    /// `calendar.timeline.hourHeight` — the timeline zoom as the user last
    /// pinched it — spent its whole life outside the erase. It was a bare
    /// string literal on a `private let` inside `CalendarViewState`, so a
    /// path scan could not see it and an `AppSettingsKeys` scan could not
    /// either; one of the two censuses written for this branch actively
    /// CERTIFIED it as covered. That is the finding that retired them.
    ///
    /// Drives the production loop (`removeResettableKeys`) rather than
    /// asserting the array's contents, so adding a name to the list without
    /// it actually being swept would still fail here.
    func testTheEraseSweepsTheTimelineZoomTheUserSet() throws {
        let suiteName = "EraseInFlightWriteTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        // `CalendarViewState` is the writer; drive it rather than setting the
        // key by hand, so a rename on either side shows up here.
        let state = CalendarViewState(defaults: suite)
        state.setTimelineHourHeight(123)
        state.commitTimelineHourHeight()
        XCTAssertNotNil(suite.object(forKey: AppSettingsKeys.calendarTimelineHourHeight),
                        "liveness: the zoom is really on disk under that key")

        // The positive control rides along: `agentAPIKey` was swept before
        // this change, so a green here cannot mean "the loop did nothing".
        suite.set("sk-positive-control", forKey: AppSettingsKeys.agentAPIKey)
        let bystander = "EraseInFlightWriteTests.bystander"
        suite.set("keep me", forKey: bystander)

        AppSettingsKeys.removeResettableKeys(from: suite)

        XCTAssertNil(suite.object(forKey: AppSettingsKeys.calendarTimelineHourHeight),
                     "the user's timeline zoom must be swept by 'erase all local data'")
        XCTAssertNil(suite.string(forKey: AppSettingsKeys.agentAPIKey),
                     "positive control: the loop really ran")
        XCTAssertEqual(suite.string(forKey: bystander), "keep me",
                       "positive control: and it is by-name, not a domain wipe")

        XCTAssertEqual(CalendarViewState(defaults: suite).timelineHourHeight,
                       Self.clampedDefaultHourHeight,
                       "a fresh state over the swept suite must come back at the default")
    }

    private static var clampedDefaultHourHeight: CGFloat {
        min(max(calendarTimelineHourHeightDefault,
                calendarTimelineHourHeightMin), calendarTimelineHourHeightMax)
    }

    // MARK: - Fixture

    private static func makeReport(userNote: String) -> Report {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let stats = ReportStatsBuilder.build(
            events: [], start: start, end: start.addingTimeInterval(7 * 86_400),
            calendar: calendar)
        return Report(
            id: UUID(), createdAt: start,
            periodStart: start, periodEnd: start.addingTimeInterval(7 * 86_400),
            prose: "erase-race witness prose", statsSnapshot: stats,
            providerModel: "test-model", comparedToPreviousWindow: false,
            userNote: userNote, schemaVersion: Report.currentSchemaVersion
        )
    }
}
