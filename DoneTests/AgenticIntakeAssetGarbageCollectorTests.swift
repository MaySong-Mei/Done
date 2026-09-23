//
//  AgenticIntakeAssetGarbageCollectorTests.swift
//  DoneTests
//
//  The sweep exists to clean up after a killed delete (issue #145 A), and it
//  is the one piece of that fix that can itself destroy a photo. So the tests
//  are written from the refusals outward: referenced files, young files and a
//  missing directory are what it must NEVER touch.
//
//  Age is exercised by moving `now` forward rather than by back-dating files:
//  the collector reads whichever of creation/modification is NEWER, and a test
//  that depends on `setAttributes` winning against the filesystem would be
//  testing the wrong thing.
//

import XCTest
@testable import Done

/// A `FileManager` whose directory listing always answers "empty" — the
/// listing a concurrent writer invalidates the instant it is returned. The
/// sweep must not be able to act on it destructively; nothing in the current
/// implementation asks it anything, which is the point.
private nonisolated final class StaleListingFileManager: FileManager {
    override func contentsOfDirectory(atPath path: String) throws -> [String] { [] }
}

final class AgenticIntakeAssetGarbageCollectorTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetGCTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
        baseDirectory = nil
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, bytes: Int = 8) throws {
        let url = baseDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent(relativePath).path)
    }

    private func collector(minimumAge: TimeInterval = 24 * 3600) -> AgenticIntakeAssetGarbageCollector {
        AgenticIntakeAssetGarbageCollector(baseDirectoryURL: baseDirectory, minimumAge: minimumAge)
    }

    /// The whole point: a file left behind by a killed delete goes away, and
    /// nothing else does.
    func testDeletesOnlyUnreferencedFilesThatAreOldEnough() throws {
        try write("event-a/kept.jpg")
        try write("event-b/orphan.jpg", bytes: 32)
        let tomorrow = Date().addingTimeInterval(48 * 3600)

        let outcome = collector().sweep(
            referencedRelativePaths: ["event-a/kept.jpg"], now: tomorrow
        )

        XCTAssertEqual(outcome.deletedRelativePaths, ["event-b/orphan.jpg"])
        XCTAssertEqual(outcome.keptReferenced, 1)
        XCTAssertEqual(outcome.scannedFiles, 2)
        XCTAssertEqual(outcome.reclaimedBytes, 32)
        XCTAssertTrue(exists("event-a/kept.jpg"))
        XCTAssertFalse(exists("event-b/orphan.jpg"))
    }

    /// A photo is written to disk seconds before the row that references it is
    /// committed — and may sit in an unsubmitted composer for far longer. The
    /// age guard is what makes that race unreachable.
    func testNeverTouchesAFileYoungerThanTheSafetyAge() throws {
        try write("event-c/in-flight.jpg")

        let outcome = collector().sweep(referencedRelativePaths: [], now: Date())

        XCTAssertTrue(outcome.deletedRelativePaths.isEmpty)
        XCTAssertEqual(outcome.keptTooYoung, 1)
        XCTAssertTrue(exists("event-c/in-flight.jpg"))
    }

    /// A referenced file is kept however old it is — age is a second gate on
    /// top of "nothing points at this", never a reason on its own.
    func testAgeAloneNeverDeletesAReferencedFile() throws {
        try write("event-d/ancient.jpg")
        let farFuture = Date().addingTimeInterval(365 * 24 * 3600)

        let outcome = collector().sweep(
            referencedRelativePaths: ["event-d/ancient.jpg"], now: farFuture
        )

        XCTAssertTrue(outcome.deletedRelativePaths.isEmpty)
        XCTAssertEqual(outcome.keptReferenced, 1)
        XCTAssertTrue(exists("event-d/ancient.jpg"))
    }

    /// An emptied event directory is litter too — but only when this sweep is
    /// what emptied it. A directory that arrived empty belongs to an import in
    /// progress.
    func testRemovesADirectoryItEmptiedAndKeepsOneItDidNot() throws {
        try write("event-e/orphan.jpg")
        try write("event-f/kept.jpg")
        let emptyDirectory = baseDirectory.appendingPathComponent("event-g", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        let tomorrow = Date().addingTimeInterval(48 * 3600)

        _ = collector().sweep(referencedRelativePaths: ["event-f/kept.jpg"], now: tomorrow)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: baseDirectory.appendingPathComponent("event-e").path))
        XCTAssertTrue(exists("event-f/kept.jpg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyDirectory.path),
                      "an empty directory this sweep did not empty is an import in progress")
    }

    /// Emptying a directory and removing it used to be two operations with a
    /// gap in between: `contentsOfDirectory` answered "empty", and the removal
    /// that followed was RECURSIVE. The sweep runs detached while
    /// `AgenticIntakeAssetStore.saveImages` writes into these very per-event
    /// directories on the main actor, so a photo that landed inside the gap
    /// went with the directory — past the reference guard AND past the age
    /// guard, which is the irreversible loss issue #145 exists to forbid.
    ///
    /// Modelled with a listing that is stale, because that is what any listing
    /// is by the time the next line runs with a concurrent writer. `rmdir(2)`
    /// never consults one: it fails with `ENOTEMPTY` and the file stays.
    func testAStaleEmptyListingCannotTakeALiveFileWithTheDirectory() throws {
        try write("event-h/orphan.jpg")
        try write("event-h/live.jpg")
        let tomorrow = Date().addingTimeInterval(48 * 3600)
        let racing = AgenticIntakeAssetGarbageCollector(
            baseDirectoryURL: baseDirectory,
            fileManager: StaleListingFileManager(),
            minimumAge: 24 * 3600
        )

        let outcome = racing.sweep(referencedRelativePaths: ["event-h/live.jpg"], now: tomorrow)

        XCTAssertEqual(outcome.deletedRelativePaths, ["event-h/orphan.jpg"])
        XCTAssertTrue(exists("event-h/live.jpg"),
                      "the directory removal must not be able to reach a file the guards kept")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: baseDirectory.appendingPathComponent("event-h").path))
    }

    /// Fresh install: no directory at all. Not an error, and nothing to report.
    func testMissingDirectoryIsANoOp() {
        let outcome = collector().sweep(referencedRelativePaths: [], now: Date())

        XCTAssertEqual(outcome, AgenticIntakeAssetGarbageCollector.Outcome())
    }

    /// The sweep only ever belongs to the real app. `DoneTests` runs inside the
    /// host app's container and the asset directory is NOT redirected under
    /// XCTest, so every test location must refuse it.
    func testOnlyProductionOwnsTheSharedAssetDirectory() {
        XCTAssertFalse(EventStorageLocation.isolated(name: "x").ownsSharedAssetDirectory)
        XCTAssertFalse(EventStorageLocation.ephemeral(id: UUID()).ownsSharedAssetDirectory)
        // Under XCTest even `.production` refuses, which is the case that
        // protects the dogfood user while this very suite runs.
        XCTAssertFalse(EventStorageLocation.production.ownsSharedAssetDirectory)
    }
}
