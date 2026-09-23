import XCTest
@testable import Done

/// Adversarial QA pins for `MetricPayloadStore` (gh#219) — boundary, burst,
/// and failure-path behavior the implementation branch's own tests do not
/// reach. Where a test pins behavior QA considers a defect, the comment says
/// so explicitly; the test still asserts what the code DOES, so the suite is
/// green and the report carries the judgment.
final class MetricPayloadStoreQATests: XCTestCase {
    private var root: URL!
    private var newDir: URL!
    private var legacyDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var logLines: [String] = []
    private let logLock = NSLock()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricPayloadStoreQATests-\(UUID().uuidString)", isDirectory: true)
        newDir = root.appendingPathComponent("new", isDirectory: true)
        legacyDir = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "MetricPayloadStoreQATests-\(UUID().uuidString)"
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
            log: { [weak self] line in
                guard let self else { return }
                self.logLock.lock()
                self.logLines.append(line)
                self.logLock.unlock()
            }
        )
    }

    private func date(_ minutes: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
    }

    private func payload(_ seed: String, bytes: Int) -> Data {
        Data((seed + String(repeating: "x", count: max(0, bytes - seed.utf8.count))).utf8)
    }

    private func fileNames(in dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private func plant(_ name: String, in dir: URL, bytes: Int, age: Date) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try payload(name, bytes: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: age], ofItemAtPath: url.path)
    }

    // MARK: - Rotation boundaries the branch suite does not reach

    /// DEFECT FIXED (QA round 1): one payload larger than the byte cap used
    /// to make rotation's newest-first prefix empty — evicting EVERY older
    /// forensic file — while `persist` returned the just-deleted file's URL,
    /// which the DoneApp call site then logged as "persisted". An over-cap-
    /// alone payload is now a write FAILURE: nil return, honest log line,
    /// nothing written, existing files untouched. A mutant that hands the
    /// oversized payload back to prefix rotation dies on every assertion
    /// below.
    func testOversizedSinglePayloadIsRejectedAndLeavesExistingFilesUntouched() throws {
        let store = makeStore(maxTotalBytes: 1000, maxFileCount: 40)
        for i in 0..<3 {
            store.persist(payload("small\(i)", bytes: 100), kind: "metric", now: date(i))
        }
        let before = fileNames(in: newDir)
        XCTAssertEqual(before.count, 3, "precondition: three retained files")

        let result = store.persist(payload("huge", bytes: 1200), kind: "diagnostic", now: date(10))

        XCTAssertNil(result, "an over-cap-alone payload is a write failure, not a success URL")
        XCTAssertEqual(fileNames(in: newDir), before,
                       "existing forensic files survive the rejected write untouched")
        logLock.lock()
        let lines = logLines
        logLock.unlock()
        XCTAssertTrue(lines.contains { $0.contains("rejected") && $0.contains("1200") },
                      "the rejection surfaces honestly in the log, got: \(lines)")
    }

    /// Same-second burst (two payloads in one MetricKit delivery batch with
    /// identical stamps) under eviction pressure: ages tie, so the filename
    /// tiebreak decides. Pinned so the order is deterministic and visible:
    /// because '.' sorts after '-', the base-named file (written FIRST)
    /// counts as newest, and the "-2" suffixed file (written second) is the
    /// eviction victim before "-3" (written third). Age-equivalent per the
    /// store's contract; determinism is the load-bearing property.
    func testSameSecondBurstEvictionTiebreakIsDeterministic() {
        let store = makeStore(maxTotalBytes: 1_000_000, maxFileCount: 2)
        let t = date(0)
        store.persist(payload("first", bytes: 10), kind: "diagnostic", now: t)
        store.persist(payload("second", bytes: 10), kind: "diagnostic", now: t)
        store.persist(payload("third", bytes: 10), kind: "diagnostic", now: t)

        let names = fileNames(in: newDir)
        XCTAssertEqual(names, ["diagnostic-2001-01-01T00-00-00Z.json",
                               "diagnostic-2001-01-01T00-00-00Z-3.json"],
                       "deterministic tiebreak: base name outranks suffixes, -3 outranks -2")
    }

    /// Byte-cap accounting must count files ALREADY in the store when
    /// migration runs (flag cleared but store populated — the wiped-defaults
    /// re-run). A migration that starts its byte ledger at zero would admit
    /// legacy files past the cap.
    func testMigrationCountsExistingStoreFilesAgainstTheCaps() throws {
        try plant("existing-a.json", in: newDir, bytes: 100, age: date(10))
        try plant("existing-b.json", in: newDir, bytes: 100, age: date(11))
        try plant("legacy-new.json", in: legacyDir, bytes: 100, age: date(2))
        try plant("legacy-old.json", in: legacyDir, bytes: 100, age: date(1))
        let store = makeStore(maxTotalBytes: 350, maxFileCount: 10)

        store.persist(payload("fresh", bytes: 10), kind: "metric", now: date(20))

        let names = fileNames(in: newDir)
        XCTAssertTrue(names.contains("existing-a.json"))
        XCTAssertTrue(names.contains("existing-b.json"))
        XCTAssertTrue(names.contains("legacy-new.json"),
                      "200 existing + 100 = 300 ≤ 350: newest legacy file fits")
        XCTAssertFalse(names.contains("legacy-old.json"),
                       "300 + 100 = 400 > 350: older legacy file must be deleted, not admitted")
        XCTAssertEqual(names.count, 4, "existing pair + one migrated + the fresh write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.path))
    }

    /// Sharper variant of the ledger pin: existing store files OLDER than the
    /// legacy candidates. The store's documented rule is that migration only
    /// admits into "whatever room the caps leave" — store residents are
    /// senior to legacy files regardless of age. A migration that starts its
    /// ledger at zero admits the newer legacy file and then the post-write
    /// rotation evicts the older RESIDENT instead — a different survivor set.
    /// (With residents newer than legacy, rotation masks the difference,
    /// which is why the previous test alone cannot kill that mutant.)
    func testMigrationLedgerSeniorityResidentsOlderThanLegacy() throws {
        try plant("resident-a.json", in: newDir, bytes: 100, age: date(1))
        try plant("resident-b.json", in: newDir, bytes: 100, age: date(2))
        try plant("legacy-newer.json", in: legacyDir, bytes: 100, age: date(10))
        let store = makeStore(maxTotalBytes: 250, maxFileCount: 10)

        store.persist(payload("fresh", bytes: 10), kind: "metric", now: date(20))

        let names = fileNames(in: newDir)
        XCTAssertTrue(names.contains("resident-a.json"),
                      "residents are senior: the old resident is not sacrificed for a newer legacy file")
        XCTAssertTrue(names.contains("resident-b.json"))
        XCTAssertFalse(names.contains("legacy-newer.json"),
                       "no room under the cap for the legacy file, so it is deleted, not admitted")
        XCTAssertEqual(names.count, 3, "two residents + the fresh write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.path))
    }

    // MARK: - Migration failure paths

    /// DEFECT FIXED (QA round 1): the migration flag used to be set in a
    /// `defer` — unconditionally, even when migration THREW — so a transient
    /// first-attempt failure (the roadblock here stands in for disk-full,
    /// which correlates exactly with having the huge legacy pile) stranded
    /// the legacy Documents pile forever: the unbounded iCloud-backed pile
    /// gh#219 exists to remove. The flag is now set on success only; a
    /// failed migration leaves it clear and retries at the next write. A
    /// mutant that restores the defer-set flag dies on both halves below.
    func testFailedMigrationLeavesFlagClearAndRetriesOnALaterWrite() throws {
        try plant("legacy-stranded.json", in: legacyDir, bytes: 10, age: date(0))
        // Occupy the store's directory path with a regular file so
        // createDirectory fails inside migration (and the write after it).
        try payload("roadblock", bytes: 10).write(to: newDir)
        let store = makeStore()

        let firstResult = store.persist(payload("doomed", bytes: 10), kind: "metric", now: date(1))
        XCTAssertNil(firstResult, "write site also fails while the roadblock stands")
        XCTAssertFalse(defaults.bool(forKey: store.migrationFlagKey),
                       "a migration that moved nothing must NOT be stamped done")
        logLock.lock()
        let firstLines = logLines
        logLock.unlock()
        XCTAssertTrue(firstLines.contains { $0.contains("migration failed") },
                      "each failed attempt surfaces in the log, got: \(firstLines)")

        // The obstacle clears (disk space recovered, say): the next write
        // retries the migration, rescues the legacy pile, and sets the flag.
        try FileManager.default.removeItem(at: newDir)
        let secondResult = store.persist(payload("fine-now", bytes: 10), kind: "metric", now: date(2))
        XCTAssertNotNil(secondResult, "store recovers for new writes")
        XCTAssertTrue(fileNames(in: newDir).contains("legacy-stranded.json"),
                      "the retried migration rescues the legacy pile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.path),
                       "legacy directory is gone after the successful retry")
        XCTAssertTrue(defaults.bool(forKey: store.migrationFlagKey),
                      "the successful retry is what sets the flag")
    }

    /// QUIRK FIXED (QA round 1): a filename collision between the new store
    /// and the legacy pile used to be treated like a cap violation — ending
    /// admission for EVERY older legacy file, even ones with room and unique
    /// names. A collision is now its own case: the store's resident wins,
    /// only the colliding legacy copy is dropped, and admission continues —
    /// the older unique file with room migrates. Only reachable when
    /// migration runs against a populated store (flag cleared / defaults
    /// wiped or a failed-migration retry).
    func testLegacyNameCollisionSkipsColliderAndKeepsAdmittingOlderFiles() throws {
        // The two colliding copies get DIFFERENT sizes so the survivor's
        // identity is checkable: resident 100 bytes, legacy copy 150.
        try plant("collide.json", in: newDir, bytes: 100, age: date(10))
        try plant("collide.json", in: legacyDir, bytes: 150, age: date(2))
        try plant("older-unique.json", in: legacyDir, bytes: 100, age: date(1))
        let store = makeStore(maxTotalBytes: 10_000, maxFileCount: 10)

        store.persist(payload("fresh", bytes: 10), kind: "metric", now: date(20))

        let names = fileNames(in: newDir)
        XCTAssertTrue(names.contains("collide.json"), "the store's own copy survives")
        let survivor = try Data(contentsOf: newDir.appendingPathComponent("collide.json"))
        XCTAssertEqual(survivor.count, 100,
                       "the RESIDENT copy (100B) survives a collision, never overwritten by the legacy copy (150B)")
        XCTAssertTrue(names.contains("older-unique.json"),
                      "a collision is not a cap violation: the older unique file with room migrates")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.path))
        XCTAssertTrue(defaults.bool(forKey: store.migrationFlagKey))
    }

    /// Foreign content in the legacy directory: subdirectories are invisible
    /// to the file-by-file pass (regular-file filter) but the wholesale
    /// `removeItem(legacyDirectory)` at the end destroys them recursively.
    /// Pinned deliberately: Documents is not user-visible in this app (no
    /// UIFileSharingEnabled), so nothing but the app can have planted them —
    /// but the deletion is silent and total, worth a pin.
    func testMigrationDestroysForeignSubdirectoriesWholesale() throws {
        try plant("legit.json", in: legacyDir, bytes: 10, age: date(1))
        let foreign = legacyDir.appendingPathComponent("foreign-subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try payload("keepme", bytes: 10).write(to: foreign.appendingPathComponent("keepme.txt"))
        let store = makeStore()

        store.persist(payload("fresh", bytes: 10), kind: "metric", now: date(5))

        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.path),
                       "foreign subdirectory is deleted with the legacy dir, contents and all")
        XCTAssertTrue(fileNames(in: newDir).contains("legit.json"))
    }

    // MARK: - Callback-context safety

    /// The production store must sit strictly BELOW DiagnosticTrail's
    /// directory, never AT it: rotation deletes the oldest regular files in
    /// its own directory wholesale, and `trail.log` / `trail.1.log` live one
    /// level up. This pins the containment relationship the store's header
    /// stakes its safety argument on.
    func testStandardStoreDirectoryIsStrictlyBelowDiagnosticTrailDirectory() {
        let store = MetricPayloadStore.standard()
        let trailDir = DiagnosticTrail.liveURL.deletingLastPathComponent()

        XCTAssertEqual(store.directory.deletingLastPathComponent().standardizedFileURL.path,
                       trailDir.standardizedFileURL.path,
                       "store dir must be a direct child of the trail's Diagnostics dir")
        XCTAssertEqual(store.directory.lastPathComponent, "MetricKit")
        XCTAssertNotEqual(store.directory.standardizedFileURL.path,
                          trailDir.standardizedFileURL.path,
                          "rotation directory must never BE the trail directory")
        XCTAssertTrue(store.legacyDirectory.path.hasSuffix("Documents/Diagnostics"),
                      "legacy pile is the old Documents write site")
    }

    /// MetricKit delivers on its own background serial queue, but nothing
    /// stops a future second call site: concurrent persists must neither
    /// crash nor overshoot the caps. (NSLock + explicit stamps make this
    /// hold today; this is the regression tripwire.)
    func testConcurrentPersistsHoldTheCountCap() {
        let store = makeStore(maxTotalBytes: 1_000_000, maxFileCount: 10)
        DispatchQueue.concurrentPerform(iterations: 32) { i in
            store.persist(payload("c\(i)", bytes: 20), kind: "metric", now: date(i))
        }
        XCTAssertEqual(fileNames(in: newDir).count, 10,
                       "count cap holds under concurrent writers")
    }
}
