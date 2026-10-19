//
//  ConflictShelfTests.swift
//  DoneTests
//
//  The conflict shelf (design §6.1, §6.3): append-only JSON lines,
//  deduplicated by (uid, table, id, seq); a failed append is reported so
//  the caller refuses the page; a durable flush; a wipe the erase calls.
//

import XCTest
@testable import Done

@MainActor
final class ConflictShelfTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConflictShelfTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratch {
            // Undo a read-only chmod before removing.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
            // A shelf file a test replaced with a link: unlink takes the
            // link itself and never touches what it points to.
            let shelfFile = scratch.appendingPathComponent(ConflictShelf.filename).path
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: shelfFile)) != nil {
                unlink(shelfFile)
            }
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        super.tearDown()
    }

    private func entry(id: String = "E1", seq: Int64 = 6, table: String = "events",
                       reason: ConflictShelfReason = .conflict,
                       row: [String: Any] = ["title": "remote c2"]) -> ConflictShelfEntry {
        ConflictShelfEntry(uid: "U1", table: table, id: id, seq: seq, reason: reason, row: row)
    }

    private func lineCount(_ shelf: ConflictShelf) -> Int {
        guard let data = try? Data(contentsOf: shelf.fileURL) else { return 0 }
        return data.split(separator: 0x0A).count
    }

    func testAppendWritesOneJsonLineWithTheWholeRow() throws {
        let shelf = ConflictShelf(directory: scratch)
        XCTAssertTrue(shelf.append(entry(row: ["title": "remote c2", "nested": ["a": 1]])))
        let read = shelf.entries()
        XCTAssertEqual(read.count, 1)
        let e = try XCTUnwrap(read.first)
        XCTAssertEqual(e.uid, "U1")
        XCTAssertEqual(e.table, "events")
        XCTAssertEqual(e.id, "E1")
        XCTAssertEqual(e.seq, 6)
        XCTAssertEqual(e.reason, "conflict")
        XCTAssertEqual(e.row["title"] as? String, "remote c2")
        XCTAssertEqual((e.row["nested"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual(lineCount(shelf), 1)
        XCTAssertEqual(shelf.fileURL.deletingLastPathComponent().standardizedFileURL,
                       scratch.standardizedFileURL)
    }

    /// The same (uid, table, id, seq) twice — a re-pulled page — is one
    /// line, and the second append still reports success. Positive control:
    /// each component changed is a new line.
    func testDedupeByUidTableIdSeq() {
        let shelf = ConflictShelf(directory: scratch)
        XCTAssertTrue(shelf.append(entry()))
        XCTAssertTrue(shelf.append(entry(row: ["title": "same key, other bytes"])), "already there = on the shelf")
        XCTAssertEqual(lineCount(shelf), 1)

        XCTAssertTrue(shelf.append(entry(seq: 7)))
        XCTAssertTrue(shelf.append(entry(id: "E2")))
        XCTAssertTrue(shelf.append(entry(table: "event_logs")))
        XCTAssertTrue(shelf.append(ConflictShelfEntry(uid: "U2", table: "events", id: "E1", seq: 6,
                                                      reason: .conflict, row: [:])))
        XCTAssertEqual(lineCount(shelf), 5)
    }

    /// Dedupe holds across instances and process restarts: the keys come
    /// from the file, not from memory.
    func testDedupeSurvivesANewInstanceAndAnotherWriter() {
        let first = ConflictShelf(directory: scratch)
        XCTAssertTrue(first.append(entry()))
        let second = ConflictShelf(directory: scratch)
        XCTAssertTrue(second.append(entry()))
        XCTAssertEqual(lineCount(second), 1)
        XCTAssertTrue(second.append(entry(seq: 9)))
        XCTAssertTrue(first.append(entry(seq: 9)), "first must see second's line")
        XCTAssertEqual(lineCount(first), 2)
    }

    func testAppendFailsUnderTheDevNullFallback() {
        let shelf = ConflictShelf(directory: URL(fileURLWithPath: "/dev/null").appendingPathComponent("Sync"))
        XCTAssertFalse(shelf.append(entry()), "the caller refuses the page")
        XCTAssertFalse(shelf.hasUnflushedAppends)
    }

    func testAppendFailsOnAReadOnlyDirectory() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let shelf = ConflictShelf(directory: scratch)
        // Positive control: the same directory accepts an append while writable.
        XCTAssertTrue(shelf.append(entry(seq: 1)))
        try FileManager.default.removeItem(at: shelf.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.path)
        XCTAssertFalse(shelf.append(entry(seq: 2)))
    }

    func testAppendFailsForARowThatIsNotJson() {
        let shelf = ConflictShelf(directory: scratch)
        XCTAssertFalse(shelf.append(entry(row: ["when": Date()])))
        XCTAssertEqual(lineCount(shelf), 0)
    }

    /// An append after an erase began is refused (design §6.4 isStale).
    func testAppendRefusesAStaleEraseToken() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let shelf = ConflictShelf(directory: scratch)
            let token = LocalDataEraseEpoch.capture()
            XCTAssertTrue(shelf.append(entry(seq: 1), eraseToken: token), "control: a fresh token writes")
            LocalDataEraseEpoch.bump()
            XCTAssertFalse(shelf.append(entry(seq: 2), eraseToken: token))
            XCTAssertEqual(lineCount(shelf), 1)
        }
    }

    func testFlushDurablyRunsOncePerBatch() {
        let shelf = ConflictShelf(directory: scratch)
        XCTAssertTrue(shelf.flushDurably(), "nothing pending")
        XCTAssertTrue(shelf.append(entry()))
        XCTAssertTrue(shelf.hasUnflushedAppends)
        XCTAssertTrue(shelf.flushDurably(), "F_FULLFSYNC on the shelf file")
        XCTAssertFalse(shelf.hasUnflushedAppends)
        XCTAssertTrue(shelf.append(entry()), "a deduped append writes nothing")
        XCTAssertFalse(shelf.hasUnflushedAppends, "so it owes no flush")
    }

    /// The production sync call is `F_FULLFSYNC`, not plain `fsync` and not
    /// a no-op: on a character device the kernel refuses `F_FULLFSYNC` with
    /// ENODEV where `fsync` and a no-op both report success. The control
    /// line keeps the descriptor honest.
    func testSystemFullSyncIsFFullFsync() throws {
        let fd = open("/dev/null", O_WRONLY)
        guard fd >= 0 else { return XCTFail("fixture liveness: /dev/null did not open") }
        defer { close(fd) }
        XCTAssertEqual(fsync(fd), 0, "control: plain fsync succeeds on this descriptor")
        errno = 0
        let result = ConflictShelf.systemFullSync(fd)
        let code = errno
        XCTAssertEqual(result, -1, "F_FULLFSYNC is refused on a character device")
        XCTAssertEqual(code, ENODEV)
    }

    /// A shelf built without an injected sync must flush with
    /// `systemFullSync`, not a stand-in that reports success. The shelf
    /// file is a link to a character device, where `F_FULLFSYNC` is refused
    /// and a no-op or plain `fsync` succeeds. The control shelf injects a
    /// success on the same fixture: the open, the append and the flush all
    /// work there, so the default shelf's failure can only come from its
    /// sync call.
    func testDefaultInitFlushesWithFFullFsync() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent(ConflictShelf.filename)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/null")

        let control = ConflictShelf(directory: scratch, fullSync: { _ in 0 })
        XCTAssertTrue(control.append(entry(seq: 7)), "control: the append lands on the character device")
        XCTAssertTrue(control.hasUnflushedAppends, "control: the append owes a flush")
        XCTAssertTrue(control.flushDurably(), "control: an injected success flushes")
        XCTAssertFalse(control.hasUnflushedAppends, "control: the flushed batch is settled")

        let shelf = ConflictShelf(directory: scratch)
        XCTAssertTrue(shelf.append(entry()))
        XCTAssertTrue(shelf.hasUnflushedAppends)
        XCTAssertFalse(shelf.flushDurably(), "the default sync must be F_FULLFSYNC, which a character device refuses")
        XCTAssertTrue(shelf.hasUnflushedAppends, "a refused sync keeps the batch owed")
    }

    func testWipeRemovesTheShelfAndDedupeStartsOver() {
        let shelf = ConflictShelf(directory: scratch)
        XCTAssertTrue(shelf.append(entry()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelf.fileURL.path), "liveness")
        shelf.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelf.fileURL.path))
        XCTAssertTrue(shelf.entries().isEmpty)
        XCTAssertTrue(shelf.append(entry()), "the same key is new again after a wipe")
        XCTAssertEqual(lineCount(shelf), 1)
    }

    /// The erase's entry point empties the production shelf — which, under
    /// XCTest, is the redirected test-host directory, never the device's.
    func testStaticWipeEmptiesTheRedirectedProductionShelf() {
        let production = ConflictShelf.productionDirectory
        XCTAssertEqual(production.lastPathComponent, ConflictShelf.testHostDirectoryName)
        XCTAssertNotEqual(ConflictShelf.testHostDirectoryName, ConflictShelf.productionDirectoryName)
        let shelf = ConflictShelf(directory: production)
        XCTAssertTrue(shelf.append(entry(id: "static-wipe-\(UUID().uuidString)")))
        XCTAssertFalse(shelf.entries().isEmpty, "liveness")
        ConflictShelf.wipe()
        XCTAssertTrue(ConflictShelf(directory: production).entries().isEmpty)
    }

    // MARK: - A short write

    /// The only copy of the losing version must not be reported as shelved
    /// when only part of its line reached the file. A file-size limit just
    /// above the current size, and below the next line's own length (the
    /// kernel may check the limit against the descriptor's offset rather
    /// than the end of the file), makes the next write come back short or
    /// EFBIG: the append reports failure, cuts the partial line off, and
    /// the next append lands as a clean line.
    func testShortWriteIsRefusedAndCutBackOff() throws {
        let shelf = ConflictShelf(directory: scratch)
        XCTAssertTrue(shelf.append(entry(seq: 1)), "control: a normal append writes")
        let sizeBefore = try fileSize(shelf)
        let room: rlim_t = 4
        let limit = rlim_t(sizeBefore) + room
        let torn = entry(seq: 2, row: ["title": String(repeating: "x", count: Int(limit))])
        let tornLength = try XCTUnwrap(torn.jsonLine()).count
        XCTAssertGreaterThan(rlim_t(tornLength), limit, "the limit must cut the line, wherever it is measured from")

        var saved = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &saved), 0)
        let savedHandler = signal(SIGXFSZ, SIG_IGN)
        var limited = saved
        limited.rlim_cur = limit
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &limited), 0)
        let appended = shelf.append(torn)
        var restore = saved
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &restore), 0)
        signal(SIGXFSZ, savedHandler)

        XCTAssertFalse(appended, "a short write must be reported as a failure — the caller refuses the page")
        XCTAssertEqual(try fileSize(shelf), sizeBefore, "the partial line is cut back off")
        XCTAssertEqual(shelf.entries().map(\.seq), [1])

        XCTAssertTrue(shelf.append(torn), "the retry lands once the limit is lifted")
        XCTAssertEqual(shelf.entries().map(\.seq), [1, 2])
        XCTAssertEqual(lineCount(shelf), 2, "every line on disk parses")
    }

    private func fileSize(_ shelf: ConflictShelf) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: shelf.fileURL.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value
    }

    // MARK: - Another instance wipes

    /// The dedupe cache must notice a wipe by another instance even when the
    /// rewritten file has exactly the length it remembers.
    func testDedupeCacheSeesAForeignWipeAndSameLengthRewrite() throws {
        let a = ConflictShelf(directory: scratch)
        let e1 = entry(id: "E1")
        let e2 = entry(id: "E2")
        XCTAssertEqual(try XCTUnwrap(e1.jsonLine()).count, try XCTUnwrap(e2.jsonLine()).count,
                       "the two lines must be the same length for the size to match")
        XCTAssertTrue(a.append(e1))

        let b = ConflictShelf(directory: scratch)
        b.wipe()
        XCTAssertTrue(b.append(e2))

        XCTAssertTrue(a.append(e1))
        XCTAssertEqual(Set(a.entries().map(\.id)), ["E1", "E2"], "E1 must actually be on disk")
        XCTAssertEqual(lineCount(a), 2)
    }

    /// A flush after another instance wiped the shelf owes nothing: the
    /// erase took the bytes. It must not report failure forever.
    func testFlushAfterAForeignWipeOwesNothing() {
        let shelf = ConflictShelf(directory: scratch)
        XCTAssertTrue(shelf.append(entry()))
        XCTAssertTrue(shelf.hasUnflushedAppends)
        ConflictShelf(directory: scratch).wipe()
        XCTAssertTrue(shelf.flushDurably())
        XCTAssertFalse(shelf.hasUnflushedAppends)
        XCTAssertTrue(shelf.flushDurably())

        XCTAssertTrue(shelf.append(entry()), "the wiped key is new again")
        XCTAssertTrue(shelf.hasUnflushedAppends)
        XCTAssertTrue(shelf.flushDurably())
        XCTAssertEqual(lineCount(shelf), 1)
    }

    /// A flush that cannot open the file for a reason other than its absence
    /// keeps the batch owed.
    func testFlushThatCannotOpenAnExistingFileKeepsTheBatchOwed() throws {
        let shelf = ConflictShelf(directory: scratch)
        XCTAssertTrue(shelf.append(entry()))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shelf.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: shelf.fileURL.path) }
        let probe = open(shelf.fileURL.path, O_RDONLY)
        if probe >= 0 {
            close(probe)
            throw XCTSkip("this process can read a mode-000 file, so the open cannot be made to fail")
        }
        XCTAssertFalse(shelf.flushDurably())
        XCTAssertTrue(shelf.hasUnflushedAppends)
    }

    // MARK: - The durability call

    /// Records each sync call's (device, inode); `result` is what it returns.
    private final class SyncRecorder {
        var calls: [(device: Int64, inode: UInt64)] = []
        var result: Int32 = 0

        var fullSync: ConflictShelf.FullSync {
            { [unowned self] fd in
                var info = stat()
                if fstat(fd, &info) == 0 {
                    calls.append((Int64(info.st_dev), UInt64(info.st_ino)))
                }
                return result
            }
        }

        func calls(on url: URL) throws -> Int {
            var info = stat()
            guard stat(url.path, &info) == 0 else {
                XCTFail("no file at \(url.path)")
                return -1
            }
            return calls.filter { $0.device == Int64(info.st_dev) && $0.inode == UInt64(info.st_ino) }.count
        }
    }

    /// One sync call on the shelf file per batch, none when nothing is owed.
    func testFlushDurablySyncsTheShelfFileOncePerBatch() throws {
        let recorder = SyncRecorder()
        let shelf = ConflictShelf(directory: scratch, fullSync: recorder.fullSync)
        XCTAssertTrue(shelf.flushDurably())
        XCTAssertTrue(recorder.calls.isEmpty, "nothing pending, no sync")

        XCTAssertTrue(shelf.append(entry(seq: 1)))
        XCTAssertTrue(shelf.append(entry(seq: 2)))
        XCTAssertTrue(shelf.flushDurably())
        XCTAssertEqual(try recorder.calls(on: shelf.fileURL), 1, "one per batch, on the shelf file")

        XCTAssertTrue(shelf.flushDurably())
        XCTAssertEqual(try recorder.calls(on: shelf.fileURL), 1, "a flushed batch is not synced again")

        XCTAssertTrue(shelf.append(entry(seq: 3)))
        XCTAssertTrue(shelf.flushDurably())
        XCTAssertEqual(try recorder.calls(on: shelf.fileURL), 2)
    }

    /// A failed sync is reported and the batch stays owed until a sync
    /// succeeds.
    func testFailedSyncIsReportedAndKeepsTheBatchOwed() throws {
        let recorder = SyncRecorder()
        recorder.result = -1
        let shelf = ConflictShelf(directory: scratch, fullSync: recorder.fullSync)
        XCTAssertTrue(shelf.append(entry()))
        XCTAssertFalse(shelf.flushDurably(), "the caller holds the winner's PATCH back")
        XCTAssertTrue(shelf.hasUnflushedAppends)
        XCTAssertEqual(try recorder.calls(on: shelf.fileURL), 1)

        recorder.result = 0
        XCTAssertTrue(shelf.flushDurably())
        XCTAssertFalse(shelf.hasUnflushedAppends)
        XCTAssertEqual(try recorder.calls(on: shelf.fileURL), 2)
    }
}
