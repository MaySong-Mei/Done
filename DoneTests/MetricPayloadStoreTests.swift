import XCTest
@testable import Done

/// `MetricPayloadStore` (gh#219) bounds the MetricKit payload pile that the
/// old write site grew without limit in iCloud-backed Documents. Everything
/// here runs against a fresh temp directory pair and a private UserDefaults
/// suite — nothing touches the store's production locations.
final class MetricPayloadStoreTests: XCTestCase {
    private var root: URL!
    private var newDir: URL!
    private var legacyDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var logLines: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricPayloadStoreTests-\(UUID().uuidString)", isDirectory: true)
        newDir = root.appendingPathComponent("new", isDirectory: true)
        legacyDir = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "MetricPayloadStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        logLines = []
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeStore(
        maxTotalBytes: Int = 2 * 1024 * 1024,
        maxFileCount: Int = 40
    ) -> MetricPayloadStore {
        MetricPayloadStore(
            directory: newDir,
            legacyDirectory: legacyDir,
            caps: .init(maxTotalBytes: maxTotalBytes, maxFileCount: maxFileCount),
            defaults: defaults,
            log: { [weak self] in self?.logLines.append($0) }
        )
    }

    /// `now` values with unambiguous ordering, spaced a full minute apart so
    /// filename stamps differ too.
    private func date(_ minutes: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
    }

    private func payload(_ seed: String, bytes: Int) -> Data {
        Data((seed + String(repeating: "x", count: max(0, bytes - seed.utf8.count))).utf8)
    }

    private func fileNames(in dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private func plantLegacyFile(_ name: String, bytes: Int, age: Date) throws {
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let url = legacyDir.appendingPathComponent(name)
        try payload(name, bytes: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: age], ofItemAtPath: url.path)
    }

    // MARK: - Writing

    func testPersistWritesPayloadBytesReadableFromDisk() throws {
        let store = makeStore()
        let data = Data(#"{"kind":"metric","scrollHitchTimeRatio":0.03}"#.utf8)

        let url = try XCTUnwrap(store.persist(data, kind: "metric", now: date(0)))

        XCTAssertEqual(try Data(contentsOf: url), data, "payload must land byte-identical")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("metric-"), "kind prefixes the filename")
        XCTAssertEqual(url.deletingLastPathComponent().path, newDir.path)
    }

    func testSameSecondPayloadsGetDistinctFilesInsteadOfOverwriting() {
        // The old write site keyed files on a second-granularity stamp, so two
        // payloads in one delivery batch could silently overwrite each other.
        let store = makeStore()
        store.persist(payload("first", bytes: 50), kind: "diagnostic", now: date(0))
        store.persist(payload("second", bytes: 50), kind: "diagnostic", now: date(0))

        XCTAssertEqual(fileNames(in: newDir).count, 2, "same-stamp collision must not overwrite")
    }

    // MARK: - Caps (boundary-exact)

    func testByteCapAtExactlyCapKeepsEverything() {
        // 4 files × 250 bytes == cap exactly: at-cap is legal, nothing evicts.
        let store = makeStore(maxTotalBytes: 1000, maxFileCount: 40)
        for i in 0..<4 {
            store.persist(payload("p\(i)", bytes: 250), kind: "metric", now: date(i))
        }
        XCTAssertEqual(fileNames(in: newDir).count, 4)
    }

    func testByteCapOneFileOverEvictsOldestOnly() throws {
        let store = makeStore(maxTotalBytes: 1000, maxFileCount: 40)
        var urls: [URL] = []
        for i in 0..<4 {
            urls.append(try XCTUnwrap(store.persist(payload("p\(i)", bytes: 250), kind: "metric", now: date(i))))
        }
        // A 5th 250-byte file pushes the total to 1250: exactly one file must
        // go, and it must be the oldest.
        let fifth = try XCTUnwrap(store.persist(payload("p4", bytes: 250), kind: "metric", now: date(4)))

        let names = fileNames(in: newDir)
        XCTAssertEqual(names.count, 4, "one byte-cap violation evicts exactly one file")
        XCTAssertFalse(names.contains(urls[0].lastPathComponent), "the oldest file is the victim")
        XCTAssertTrue(names.contains(urls[1].lastPathComponent))
        XCTAssertTrue(names.contains(urls[2].lastPathComponent))
        XCTAssertTrue(names.contains(urls[3].lastPathComponent))
        XCTAssertTrue(names.contains(fifth.lastPathComponent), "the just-written newest file survives")
        var total = 0
        for name in names {
            total += try Data(contentsOf: newDir.appendingPathComponent(name)).count
        }
        XCTAssertEqual(total, 1000, "retained bytes are back at the cap")
    }

    func testCountCapAtExactlyCapKeepsEverythingAndOneMoreEvictsOldest() throws {
        let store = makeStore(maxTotalBytes: 1_000_000, maxFileCount: 3)
        var urls: [URL] = []
        for i in 0..<3 {
            urls.append(try XCTUnwrap(store.persist(payload("p\(i)", bytes: 10), kind: "metric", now: date(i))))
        }
        XCTAssertEqual(fileNames(in: newDir).count, 3, "at-cap is legal")

        let fourth = try XCTUnwrap(store.persist(payload("p3", bytes: 10), kind: "metric", now: date(3)))

        let names = fileNames(in: newDir)
        XCTAssertEqual(names.count, 3, "count cap holds after a 4th write")
        XCTAssertFalse(names.contains(urls[0].lastPathComponent), "the oldest file is the one evicted")
        XCTAssertTrue(names.contains(urls[1].lastPathComponent))
        XCTAssertTrue(names.contains(urls[2].lastPathComponent))
        XCTAssertTrue(names.contains(fourth.lastPathComponent), "the just-written newest file survives")
    }

    func testEvictionIsOldestFirstByModificationDateNotByName() throws {
        // Names sort against ages here (z… is oldest, a… is newest), so a
        // rotation that ordered by filename — or evicted newest-first — picks
        // different victims than one ordering by age.
        let store = makeStore(maxTotalBytes: 1_000_000, maxFileCount: 2)
        let oldButLastAlphabetically = try XCTUnwrap(
            store.persist(payload("old", bytes: 10), kind: "z-kind", now: date(0)))
        let middle = try XCTUnwrap(
            store.persist(payload("mid", bytes: 10), kind: "m-kind", now: date(1)))
        let newestButFirstAlphabetically = try XCTUnwrap(
            store.persist(payload("new", bytes: 10), kind: "a-kind", now: date(2)))

        let names = fileNames(in: newDir)
        XCTAssertEqual(names.count, 2)
        XCTAssertFalse(names.contains(oldButLastAlphabetically.lastPathComponent), "oldest evicted first")
        XCTAssertTrue(names.contains(middle.lastPathComponent))
        XCTAssertTrue(names.contains(newestButFirstAlphabetically.lastPathComponent))
    }

    func testProductionCapsAreTwoMegabytesAndFortyFiles() {
        // The caps gh#219 decided on. A cap silently widened (or a rotation
        // reading different defaults) shows up here, not on a user's quota.
        let caps = MetricPayloadStore.Caps()
        XCTAssertEqual(caps.maxTotalBytes, 2 * 1024 * 1024)
        XCTAssertEqual(caps.maxFileCount, 40)
    }

    // MARK: - Legacy migration

    func testMigrationMovesNewestLegacyFilesDeletesRestAndRemovesLegacyDir() throws {
        // The byte cap admits 250 bytes; legacy holds 4×100. The two newest
        // fit, the two oldest must be deleted, and the legacy directory
        // itself must be gone afterwards. (Byte cap chosen so the fresh
        // 10-byte write that triggers migration also fits — this test pins
        // migration's selection, not post-write rotation.)
        try plantLegacyFile("legacy-newest.json", bytes: 100, age: date(40))
        try plantLegacyFile("legacy-second.json", bytes: 100, age: date(30))
        try plantLegacyFile("legacy-third.json", bytes: 100, age: date(20))
        try plantLegacyFile("legacy-oldest.json", bytes: 100, age: date(10))
        let store = makeStore(maxTotalBytes: 250, maxFileCount: 10)

        // Migration runs at the write site: the first persist triggers it.
        store.persist(payload("fresh", bytes: 10), kind: "metric", now: date(50))

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.path),
                       "legacy Documents/Diagnostics analogue is deleted wholesale")
        let names = fileNames(in: newDir)
        XCTAssertTrue(names.contains("legacy-newest.json"), "newest legacy file migrated")
        XCTAssertTrue(names.contains("legacy-second.json"), "second-newest legacy file migrated")
        XCTAssertFalse(names.contains("legacy-third.json"), "over-cap legacy file deleted, not moved")
        XCTAssertFalse(names.contains("legacy-oldest.json"), "oldest legacy file deleted, not moved")
        // Migrated content survives the move byte-identical.
        let moved = try Data(contentsOf: newDir.appendingPathComponent("legacy-newest.json"))
        XCTAssertTrue(String(decoding: moved, as: UTF8.self).hasPrefix("legacy-newest.json"))
        XCTAssertTrue(defaults.bool(forKey: store.migrationFlagKey), "migration is flagged as done")
        XCTAssertEqual(names.count, 3, "fresh write + the two migrated files, nothing else")
    }

    func testSecondMigrationRunIsANoOpEvenIfLegacyDirReappears() throws {
        try plantLegacyFile("legacy-a.json", bytes: 10, age: date(0))
        let store = makeStore()
        store.persist(payload("first", bytes: 10), kind: "metric", now: date(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.path))

        // A legacy directory materializing after the flag is set (impossible
        // in production — the writing code is gone — but exactly what a
        // re-running migration would chew through) must be left alone.
        try plantLegacyFile("planted-after-flag.json", bytes: 10, age: date(2))
        store.persist(payload("second", bytes: 10), kind: "metric", now: date(3))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyDir.appendingPathComponent("planted-after-flag.json").path),
            "flagged migration must not run again")
        XCTAssertFalse(fileNames(in: newDir).contains("planted-after-flag.json"))
    }

    func testMigrationWithoutLegacyDirStillSetsFlagAndWrites() {
        let store = makeStore()
        store.persist(payload("fresh", bytes: 10), kind: "metric", now: date(0))
        XCTAssertTrue(defaults.bool(forKey: store.migrationFlagKey))
        XCTAssertEqual(fileNames(in: newDir).count, 1)
    }

    // MARK: - Never throws into the MetricKit callback

    func testPersistIntoImpossibleLocationReturnsNilAndLogsInsteadOfThrowing() throws {
        // Occupy the store's directory path with a regular FILE so
        // createDirectory (and the write) must fail.
        try payload("roadblock", bytes: 10).write(to: newDir)

        let store = makeStore()
        // `persist` is non-throwing by signature; this call compiling without
        // `try` is itself part of the pin. The behavioral half: it returns
        // nil and the failure reaches the log sink.
        let result = store.persist(payload("doomed", bytes: 10), kind: "metric", now: date(0))

        XCTAssertNil(result)
        XCTAssertTrue(logLines.contains { $0.contains("failed to persist") },
                      "swallowed errors must surface in the log, got: \(logLines)")
    }
}
