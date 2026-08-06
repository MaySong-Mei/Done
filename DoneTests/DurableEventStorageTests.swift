//
//  DurableEventStorageTests.swift
//  DoneTests
//
//  These are the tests the simulator CAN settle. Durability against SIGKILL is
//  a property of the write primitive (`write(2)` + `rename(2)`), not something
//  a test can demonstrate; what a test CAN pin down is every branch of the
//  read funnel, the migration's behaviour at each interruption point, and the
//  rule that must never bend: an unreadable slot is not an empty slot.
//

import XCTest
@testable import Done

private struct Row: Codable, Equatable {
    var id: UUID
    var name: String
    var payload: String
}

private func makeRows(_ count: Int, padding: Int = 0) -> [Row] {
    (0..<count).map { i in
        Row(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
            name: "row-\(i)",
            payload: String(repeating: "x", count: padding))
    }
}

@MainActor
final class DurableEventStorageTests: XCTestCase {
    private var location: EventStorageLocation!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DurableEventStorageTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        location = .isolated(name: suiteName)
        EventStorageLocation.destroy(location)
    }

    override func tearDown() {
        EventStorageLocation.destroy(location)
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    private func makeStorage(legacy: UserDefaults? = nil) -> DurableEventStorage {
        DurableEventStorage(location: location, legacyDefaults: legacy)
    }

    private func directory() throws -> URL {
        try location.directoryURL()
    }

    private func loadedRows(_ read: SlotRead<Row>, file: StaticString = #filePath,
                            line: UInt = #line) -> [Row]? {
        guard case .loaded(let envelope, _) = read else {
            XCTFail("expected .loaded, got \(read)", file: file, line: line)
            return nil
        }
        return envelope.rows
    }

    // MARK: - The premise

    /// If this ever fails, `.production` is NOT being redirected and every
    /// test in the suite is reading and writing the real dogfood store. It is
    /// first in the file on purpose.
    func testTestHostRedirectionIsActive() throws {
        XCTAssertTrue(EventStorageLocation.isRunningUnderXCTest,
                      "XCTestConfigurationFilePath must be visible in the host app's environment")
        let production = try EventStorageLocation.production.directoryURL()
        XCTAssertEqual(production.lastPathComponent, EventStorageLocation.testHostDirectoryName)
        XCTAssertFalse(EventStorageLocation.production.migratesLegacyDefaults,
                       "the host app's own store must not migrate real UserDefaults under test")
    }

    // MARK: - Round trip and process restart

    func testCommitThenNewInstanceSeesTheRows() throws {
        let rows = makeRows(12)
        let a = makeStorage()
        let receipt = try a.commit(rows, to: .calendarEvents)
        XCTAssertEqual(receipt.seq, 1)
        XCTAssertFalse(receipt.skipped)

        // Discard `a` entirely — the same shape as the process dying and the
        // next launch constructing a fresh store against the same directory.
        let b = makeStorage()
        XCTAssertEqual(loadedRows(b.read(.calendarEvents, as: Row.self)), rows)
    }

    func testSeqAdvancesAcrossInstances() throws {
        let a = makeStorage()
        try a.commit(makeRows(3), to: .calendarEvents)
        try a.commit(makeRows(4), to: .calendarEvents)
        let b = makeStorage()
        let receipt = try b.commit(makeRows(5), to: .calendarEvents)
        XCTAssertEqual(receipt.seq, 3, "seq must survive the process via the manifest")
    }

    func testIdenticalPayloadIsSkipped() throws {
        let storage = makeStorage()
        let rows = makeRows(20)
        let first = try storage.commit(rows, to: .calendarEvents)
        let second = try storage.commit(rows, to: .calendarEvents)
        XCTAssertFalse(first.skipped)
        XCTAssertTrue(second.skipped)
        XCTAssertEqual(second.seq, first.seq, "a skipped commit must not advance seq")
        // A changed domino stamp is part of the payload, so it must NOT skip.
        let third = try storage.commit(rows, to: .calendarEvents, dominoLastPush: Date())
        XCTAssertFalse(third.skipped)
    }

    func testBackupIsCreatedOnTheSecondCommit() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(5), to: .calendarEvents)
        let backup = try directory().appendingPathComponent(StorageSlot.calendarEvents.backupFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path),
                       "nothing to back up on the first write")
        try storage.commit(makeRows(6), to: .calendarEvents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    // MARK: - Isolation

    func testIsolatedLocationsDoNotSeeEachOther() throws {
        let otherName = "DurableEventStorageTests-other-\(UUID().uuidString)"
        let other = EventStorageLocation.isolated(name: otherName)
        defer { EventStorageLocation.destroy(other) }

        try makeStorage().commit(makeRows(3), to: .calendarEvents)
        let b = DurableEventStorage(location: other, legacyDefaults: nil)
        guard case .fresh = b.read(.calendarEvents, as: Row.self) else {
            return XCTFail("a different isolated location must start fresh")
        }

        // And neither may sit inside the production directory.
        let production = try EventStorageLocation.production.directoryURL()
        let mine = try directory().path
        let theirs = try other.directoryURL().path
        XCTAssertFalse(mine.hasPrefix(production.path + "/"))
        XCTAssertFalse(theirs.hasPrefix(production.path + "/"))
    }

    func testDestroyRefusesNothingButAlsoNeverPointsAtProduction() throws {
        // `destroy(.production)` traps by design and cannot be exercised here;
        // what IS checkable is that a hostile suite name cannot escape the
        // test root by path traversal.
        for hostile in ["../../../../escape", "..", ".", "/etc/passwd", ""] {
            let url = try EventStorageLocation.isolated(name: hostile).directoryURL()
            // Whatever survives sanitising must be ONE path component sitting
            // directly under the test root — separators gone, no leading dot,
            // and standardising must be a no-op (i.e. nothing to collapse).
            XCTAssertFalse(url.lastPathComponent.contains("/"), "\(hostile)")
            XCTAssertFalse(url.lastPathComponent.hasPrefix("."), "\(hostile)")
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                           EventStorageLocation.isolatedRootName, "\(hostile)")
            XCTAssertEqual(url.standardizedFileURL.path, url.path, "\(hostile)")
        }
    }

    // MARK: - Migration

    func testLegacyBlobIsMigratedOnFirstReadAndLegacyIsLeftIntact() throws {
        let rows = makeRows(40)
        defaults.set(try JSONEncoder().encode(rows), forKey: StorageSlot.calendarEvents.rawValue)

        let storage = makeStorage(legacy: defaults)
        guard case .loaded(let envelope, let provenance) = storage.read(.calendarEvents, as: Row.self) else {
            return XCTFail("expected a migrated load")
        }
        XCTAssertEqual(provenance, .legacyMigrated)
        XCTAssertEqual(envelope.rows, rows)

        // The file now exists...
        let primary = try directory().appendingPathComponent(StorageSlot.calendarEvents.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
        // ...and the legacy key is UNTOUCHED, so downgrading the binary lands
        // the user on the migration-time snapshot rather than on nothing.
        XCTAssertNotNil(defaults.data(forKey: StorageSlot.calendarEvents.rawValue))
    }

    func testMigrationIsReentrant() throws {
        let rows = makeRows(30)
        defaults.set(try JSONEncoder().encode(rows), forKey: StorageSlot.calendarEvents.rawValue)

        _ = makeStorage(legacy: defaults).read(.calendarEvents, as: Row.self)
        let second = makeStorage(legacy: defaults)
        guard case .loaded(let envelope, let provenance) = second.read(.calendarEvents, as: Row.self) else {
            return XCTFail("expected a load")
        }
        XCTAssertEqual(provenance, .primary, "the file wins once it exists; legacy is dead data")
        XCTAssertEqual(envelope.rows, rows)
    }

    /// The absolute rule: once a file exists the legacy key is never read
    /// again — not merged, not compared for freshness. A downgrade-then-
    /// upgrade cycle that left a NEWER legacy blob must not resurrect it.
    func testFileWinsOverANewerLegacyBlob() throws {
        let storage = makeStorage(legacy: defaults)
        try storage.commit(makeRows(2), to: .calendarEvents)
        defaults.set(try JSONEncoder().encode(makeRows(99)),
                     forKey: StorageSlot.calendarEvents.rawValue)

        let next = makeStorage(legacy: defaults)
        XCTAssertEqual(loadedRows(next.read(.calendarEvents, as: Row.self))?.count, 2)
    }

    func testMigrationInterruptedAfterTempWriteStillMigrates() throws {
        let rows = makeRows(25)
        defaults.set(try JSONEncoder().encode(rows), forKey: StorageSlot.calendarEvents.rawValue)
        // Debris from a commit killed between the write and the rename.
        let debris = try directory()
        try FileManager.default.createDirectory(at: debris, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: debris.appendingPathComponent(".tmp-calendarEvents-abc"))

        let storage = makeStorage(legacy: defaults)
        XCTAssertEqual(loadedRows(storage.read(.calendarEvents, as: Row.self)), rows)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: debris.appendingPathComponent(".tmp-calendarEvents-abc").path),
            "stray temp files must be swept, and must never be read")
    }

    func testCorruptLegacyBlobFreezesAndIsQuarantinedRatherThanTreatedAsEmpty() throws {
        defaults.set(Data("not json".utf8), forKey: StorageSlot.calendarEvents.rawValue)
        let storage = makeStorage(legacy: defaults)
        guard case .unreadable(let fault) = storage.read(.calendarEvents, as: Row.self) else {
            return XCTFail("a corrupt legacy blob must not read as empty")
        }
        guard case .decodeFailed(_, let quarantined) = fault else {
            return XCTFail("expected decodeFailed, got \(fault)")
        }
        XCTAssertNotNil(quarantined)
        XCTAssertTrue(storage.isFrozen(.calendarEvents))
        XCTAssertNotNil(defaults.data(forKey: StorageSlot.calendarEvents.rawValue),
                        "legacy bytes must be left where they are")
    }

    func testMigrationRunsPerSlotIndependently() throws {
        defaults.set(try JSONEncoder().encode(makeRows(3)), forKey: StorageSlot.calendarEvents.rawValue)
        defaults.set(Data("broken".utf8), forKey: StorageSlot.people.rawValue)
        let storage = makeStorage(legacy: defaults)
        XCTAssertEqual(loadedRows(storage.read(.calendarEvents, as: Row.self))?.count, 3)
        guard case .unreadable = storage.read(.people, as: Row.self) else {
            return XCTFail("people should be frozen")
        }
        XCTAssertFalse(storage.isFrozen(.calendarEvents),
                       "one bad slot must not stop the calendar from being written")
        XCTAssertTrue(storage.isFrozen(.people))
    }

    // MARK: - Failure handling

    func testCorruptPrimaryIsQuarantinedAndBackupIsPromoted() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(7), to: .calendarEvents)   // becomes the .bak
        try storage.commit(makeRows(8), to: .calendarEvents)   // primary
        let primary = try directory().appendingPathComponent(StorageSlot.calendarEvents.filename)
        try Data("shredded".utf8).write(to: primary)

        let next = makeStorage()
        guard case .loaded(let envelope, let provenance) = next.read(.calendarEvents, as: Row.self) else {
            return XCTFail("expected recovery from backup")
        }
        XCTAssertEqual(provenance, .backup)
        XCTAssertEqual(envelope.rows.count, 7)
        XCTAssertFalse(next.isFrozen(.calendarEvents), "a recovered slot is writable")

        // The corrupt bytes were preserved, not destroyed...
        let quarantine = try directory().appendingPathComponent("quarantine")
        let entries = try FileManager.default.contentsOfDirectory(atPath: quarantine.path)
        XCTAssertEqual(entries.filter { $0.hasPrefix("calendarEvents-corrupt-") }.count, 1)
        // ...and the recovered rows were written back under the primary name.
        let after = makeStorage()
        guard case .loaded(_, let laterProvenance) = after.read(.calendarEvents, as: Row.self) else {
            return XCTFail("expected a primary load after recovery")
        }
        XCTAssertEqual(laterProvenance, .primary)
    }

    func testCorruptPrimaryWithNoBackupFreezesAndNeverReadsAsEmpty() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(9), to: .calendarEvents)
        let primary = try directory().appendingPathComponent(StorageSlot.calendarEvents.filename)
        try Data("{".utf8).write(to: primary)

        let next = makeStorage()
        guard case .unreadable(let fault) = next.read(.calendarEvents, as: Row.self) else {
            return XCTFail("must not read as empty")
        }
        if case .decodeFailed = fault {} else { XCTFail("expected decodeFailed, got \(fault)") }
        XCTAssertTrue(next.isFrozen(.calendarEvents))
    }

    /// An I/O failure is NOT a corruption. Renaming a file that is merely
    /// unreadable right now (locked device, transient EIO) would turn a
    /// recoverable moment into a permanent loss — and with the primary gone
    /// the next launch would happily migrate legacy on top of it.
    func testUnreadableFileIsNeverMovedOrDeleted() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(11), to: .calendarEvents)
        let primary = try directory().appendingPathComponent(StorageSlot.calendarEvents.filename)
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: primary.path)[.size] as? NSNumber

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: primary.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: primary.path) }
        try XCTSkipIf((try? Data(contentsOf: primary)) != nil,
                      "chmod 000 did not deny reads in this environment (running as root?)")

        let next = makeStorage()
        guard case .unreadable(let fault) = next.read(.calendarEvents, as: Row.self) else {
            return XCTFail("an unreadable file must not read as empty")
        }
        if case .ioError = fault {} else { XCTFail("expected ioError, got \(fault)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path),
                      "the file must still be there under its original name")
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: primary.path)[.size] as? NSNumber
        XCTAssertEqual(sizeBefore, sizeAfter)
        let quarantine = try directory().appendingPathComponent("quarantine")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count, 0,
                       "nothing may be quarantined on an I/O failure")
    }

    /// The manifest is the memory that turns "file missing" from "never had
    /// one" into "something ate it". Without it, a deleted store would look
    /// exactly like a first launch and get seeded with demo rows.
    func testFilesVanishingAfterACommitIsAFaultNotFreshness() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(5), to: .calendarEvents)
        try FileManager.default.removeItem(
            at: try directory().appendingPathComponent(StorageSlot.calendarEvents.filename))

        let next = makeStorage()
        guard case .unreadable(let fault) = next.read(.calendarEvents, as: Row.self) else {
            return XCTFail("a vanished slot must never present as fresh")
        }
        XCTAssertEqual(fault, .lostAfterManifest)
    }

    func testWriteIsRefusedWhenTheDirectoryCannotBeCreated() throws {
        // Occupy the location's directory path with a regular file, so the
        // directory can never be made.
        let ephemeral = EventStorageLocation.ephemeral(id: UUID())
        let dir = try ephemeral.directoryURL()
        try Data("x".utf8).write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storage = DurableEventStorage(location: ephemeral, legacyDefaults: nil)
        XCTAssertThrowsError(try storage.commit(makeRows(1), to: .calendarEvents))
        guard case .unreadable(let fault) = storage.read(.calendarEvents, as: Row.self) else {
            return XCTFail("no directory means nothing can be proven absent")
        }
        XCTAssertTrue(fault.isTransient)
        XCTAssertTrue(storage.isFrozen(.calendarEvents))
    }

    // MARK: - Wipe semantics

    func testWipedEnvelopeIsDistinguishableFromFresh() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(4), to: .calendarEvents)
        try storage.commit([Row](), to: .calendarEvents, wiped: true, intent: .destructive)

        let next = makeStorage()
        guard case .loaded(let envelope, _) = next.read(.calendarEvents, as: Row.self) else {
            return XCTFail("a wiped slot must load, not read as fresh")
        }
        XCTAssertTrue(envelope.header.wiped)
        XCTAssertTrue(envelope.rows.isEmpty)
    }

    /// The reason `clearAllLocalData` commits empty envelopes instead of
    /// deleting files: deletion would leave "no file", and "no file" is the
    /// state that re-runs migration. cfprefsd cannot be trusted to have
    /// durably removed the legacy key, so deleted data could come back.
    func testWipeCannotResurrectLegacyData() throws {
        defaults.set(try JSONEncoder().encode(makeRows(50)),
                     forKey: StorageSlot.calendarEvents.rawValue)
        let storage = makeStorage(legacy: defaults)
        _ = storage.read(.calendarEvents, as: Row.self)
        try storage.commit([Row](), to: .calendarEvents, wiped: true, intent: .destructive)
        // Simulate cfprefsd never having flushed the removal: the legacy key
        // is still there.
        XCTAssertNotNil(defaults.data(forKey: StorageSlot.calendarEvents.rawValue))

        let next = makeStorage(legacy: defaults)
        guard case .loaded(let envelope, _) = next.read(.calendarEvents, as: Row.self) else {
            return XCTFail("expected the empty envelope")
        }
        XCTAssertTrue(envelope.rows.isEmpty, "wiped data must not come back from legacy")
    }

    func testPurgeAuxiliaryCopiesRemovesPlaintextResidue() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(5), to: .calendarEvents)
        try storage.commit(makeRows(6), to: .calendarEvents)
        let backup = try directory().appendingPathComponent(StorageSlot.calendarEvents.backupFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        storage.purgeAuxiliaryCopies(for: .calendarEvents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    // MARK: - Shrink guard

    func testLargeShrinkLeavesASnapshot() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(200), to: .calendarEvents)
        try storage.commit(makeRows(3), to: .calendarEvents)   // normal intent
        let snapshots = try directory().appendingPathComponent("snapshots")
        let entries = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
        XCTAssertEqual(entries.filter { $0.hasPrefix("calendarEvents-shrink-") }.count, 1)
        // The write itself is never refused — memory and disk must not fork.
        XCTAssertEqual(loadedRows(makeStorage().read(.calendarEvents, as: Row.self))?.count, 3)
    }

    func testDestructiveShrinkDoesNotSnapshot() throws {
        let storage = makeStorage()
        try storage.commit(makeRows(200), to: .calendarEvents)
        try storage.commit([Row](), to: .calendarEvents, wiped: true, intent: .destructive)
        let snapshots = try directory().appendingPathComponent("snapshots")
        let entries = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Domino heartbeat

    func testDominoHeartbeatRoundTrips() throws {
        let storage = makeStorage()
        XCTAssertNil(storage.readDominoHeartbeat())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try storage.writeDominoHeartbeat(now)
        XCTAssertEqual(makeStorage().readDominoHeartbeat()?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDominoStampTravelsInTheCalendarEnvelope() throws {
        let storage = makeStorage()
        let stamp = Date(timeIntervalSince1970: 1_800_000_500)
        try storage.commit(makeRows(3), to: .calendarEvents, dominoLastPush: stamp)
        guard case .loaded(let envelope, _) = makeStorage().read(.calendarEvents, as: Row.self) else {
            return XCTFail("expected a load")
        }
        XCTAssertEqual(envelope.header.dominoLastPush?.timeIntervalSince1970 ?? 0,
                       stamp.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Pending work

    func testPendingWorkSurvivesAndClears() throws {
        let storage = makeStorage()
        let url = try storage.recordPendingWork(kind: "restore", payload: Data("hello".utf8))
        let found = makeStorage().pendingWork(kind: "restore")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.payload, Data("hello".utf8))
        storage.clearPendingWork(url)
        XCTAssertTrue(makeStorage().pendingWork(kind: "restore").isEmpty)
    }

    // MARK: - Scale

    /// The dogfood device carries 2690 calendar rows / 1.25 MB. Everything
    /// above is exercised at toy sizes; this one proves the same paths hold
    /// when the payload is the size that actually broke.
    func testDeviceScalePayloadRoundTripsAndRecoversFromBackup() throws {
        let rows = makeRows(2700, padding: 400)   // ~1.2 MB encoded
        let storage = makeStorage()
        let receipt = try storage.commit(rows, to: .calendarEvents)
        XCTAssertGreaterThan(receipt.bytes, 1_000_000, "must be device-scale, not toy-scale")
        // On-disk size is verified against the buffer inside `commit`; here we
        // only check the framing overhead is a header plus a newline, not a
        // second copy of the payload.
        XCTAssertGreaterThan(receipt.onDiskBytes, receipt.bytes)
        XCTAssertLessThan(receipt.onDiskBytes - receipt.bytes, 512)

        let reread = makeStorage()
        XCTAssertEqual(loadedRows(reread.read(.calendarEvents, as: Row.self))?.count, 2700)

        // Same payload again must skip rather than rewrite 1.2 MB. (The skip
        // is per-instance memory, so it is asserted on the instance that did
        // the write — a fresh instance has nothing to compare against and
        // must, correctly, write.)
        XCTAssertTrue(try storage.commit(rows, to: .calendarEvents).skipped)
        XCTAssertFalse(try reread.commit(rows, to: .calendarEvents).skipped)

        // And the corrupt-primary recovery path must work at this size too.
        try storage.commit(makeRows(2700, padding: 401), to: .calendarEvents)
        let primary = try directory().appendingPathComponent(StorageSlot.calendarEvents.filename)
        try Data("nope".utf8).write(to: primary)
        guard case .loaded(let envelope, let provenance) = makeStorage()
            .read(.calendarEvents, as: Row.self) else {
            return XCTFail("expected backup recovery at scale")
        }
        XCTAssertEqual(provenance, .backup)
        XCTAssertEqual(envelope.rows.count, 2700)
    }

    func testDeviceScaleLegacyMigration() throws {
        let rows = makeRows(2700, padding: 400)
        defaults.set(try JSONEncoder().encode(rows), forKey: StorageSlot.calendarEvents.rawValue)
        let storage = makeStorage(legacy: defaults)
        guard case .loaded(let envelope, let provenance) = storage.read(.calendarEvents, as: Row.self) else {
            return XCTFail("expected migration")
        }
        XCTAssertEqual(provenance, .legacyMigrated)
        XCTAssertEqual(envelope.rows.count, 2700)
        // Readback verification really did read the file back, so a second
        // instance must agree without touching legacy.
        XCTAssertEqual(loadedRows(makeStorage(legacy: nil).read(.calendarEvents, as: Row.self))?.count, 2700)
    }
}
