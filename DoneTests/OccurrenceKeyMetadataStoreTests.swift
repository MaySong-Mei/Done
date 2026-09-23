//
//  OccurrenceKeyMetadataStoreTests.swift
//  DoneTests
//
//  The acceptance net for the second half of issue #144: the frozen reference
//  time zone in durable metadata.
//
//  The bug has a very specific shape and it is NOT "a value went missing".
//  `dayKey` is the identity field of every occurrence record, derived in a
//  deliberately frozen zone so that identity survives the user travelling.
//  Lose the scalar and the next launch freezes a NEW zone — so records already
//  on disk keep their stored `dayKey` while newly derived keys disagree with
//  them, and nothing anywhere reports a problem. Every test here is some
//  version of "the second launch must not decide a different answer".
//

import XCTest
@testable import Done

@MainActor
final class OccurrenceKeyMetadataStoreTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private var directory: URL!
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OccurrenceKeyMetadataStoreTests-\(UUID().uuidString)",
                                    isDirectory: true)
        // The tests that STAGE a file (a corrupt one, an unknown identifier)
        // write before any store has had a chance to create the directory.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "OccurrenceKeyMetadataStoreTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suiteName, let suite { suite.removePersistentDomain(forName: suiteName) }
        directory = nil
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A fresh store over the same directory — the relaunch simulation. `in:`
    /// is the zone the DEVICE is in at that launch, which is the variable the
    /// whole feature exists to be independent of.
    private func makeStore(in zone: TimeZone, legacy: UserDefaults? = nil)
    -> OccurrenceKeyMetadataStore {
        OccurrenceKeyMetadataStore(directory: directory,
                                   legacyDefaults: legacy,
                                   currentTimeZone: { zone })
    }

    private var fileURL: URL {
        directory.appendingPathComponent(OccurrenceKeyMetadataStore.referenceTimeZoneFilename)
    }
    private var backupURL: URL {
        directory.appendingPathComponent("referenceTimeZone.bak")
    }
    private var witnessURL: URL {
        directory.appendingPathComponent("referenceTimeZone.committed")
    }

    /// `dayKey`'s derivation, against an explicit zone rather than the shared
    /// singleton — the point being that two launches must agree.
    private func dayKey(_ date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 1970) * 10_000 + (c.month ?? 1) * 100 + (c.day ?? 1)
    }

    private func seedLegacy(_ identifier: String) {
        suite.set(identifier, forKey: CalendarOccurrenceKey.referenceTimeZoneDefaultsKey)
    }

    // MARK: - Establish, then survive travel

    func testFirstAccessFreezesTheCurrentZoneAndPersistsItImmediately() {
        let store = makeStore(in: shanghai)
        XCTAssertEqual(store.referenceTimeZone.identifier, shanghai.identifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "write-on-first-access is preserved — it is durable now, not queued in cfprefsd")
    }

    /// THE regression. Launch in Shanghai, fly to New York, relaunch: the
    /// frozen zone must still be Shanghai.
    func testAnEstablishedZoneSurvivesARelaunchAfterTravel() {
        let beforeTravel = makeStore(in: shanghai)
        XCTAssertEqual(beforeTravel.referenceTimeZone.identifier, shanghai.identifier)

        let afterTravel = makeStore(in: newYork)
        XCTAssertEqual(afterTravel.referenceTimeZone.identifier, shanghai.identifier,
                       "the device moved; the reference zone must not")
        XCTAssertFalse(afterTravel.isFrozen)
    }

    /// The same fact stated as the consequence that actually hurts: one instant
    /// must land on the same calendar day before and after the flight, or the
    /// feedback and log records written yesterday stop being found.
    func testDayKeysAgreeAcrossARelaunchInADifferentZone() {
        // 2026-01-15 08:00 in Shanghai is still 2026-01-14 in New York, so a
        // re-freeze would visibly move this occurrence to the previous day.
        var shanghaiCalendar = Calendar(identifier: .gregorian)
        shanghaiCalendar.timeZone = shanghai
        let instant = shanghaiCalendar.date(
            from: DateComponents(year: 2026, month: 1, day: 15, hour: 8, minute: 0)
        )!

        let written = dayKey(instant, in: makeStore(in: shanghai).referenceTimeZone)
        let readBack = dayKey(instant, in: makeStore(in: newYork).referenceTimeZone)

        XCTAssertEqual(written, 20260115, "fixture guard")
        XCTAssertEqual(readBack, written)
        XCTAssertNotEqual(dayKey(instant, in: newYork), written,
                          "fixture guard: the two zones really do disagree about this instant")
    }

    // MARK: - Migration

    func testTheLegacyIdentifierMigratesAndTheKeySurvives() {
        seedLegacy(shanghai.identifier)

        let store = makeStore(in: newYork, legacy: suite)
        XCTAssertEqual(store.referenceTimeZone.identifier, shanghai.identifier,
                       "the value the user's records were written under wins over the device's")
        XCTAssertEqual(suite.string(forKey: CalendarOccurrenceKey.referenceTimeZoneDefaultsKey),
                       shanghai.identifier,
                       "the legacy key is the rollback net and must never be rewritten or deleted")

        // And it is a file now.
        suite.removeObject(forKey: CalendarOccurrenceKey.referenceTimeZoneDefaultsKey)
        XCTAssertEqual(makeStore(in: newYork, legacy: suite).referenceTimeZone.identifier,
                       shanghai.identifier)
    }

    /// Killed between the legacy read and the commit: the next launch must do
    /// the same thing again rather than freezing the zone it is now in.
    func testMigrationIsReEntrant() {
        seedLegacy(shanghai.identifier)
        XCTAssertEqual(makeStore(in: newYork, legacy: suite).referenceTimeZone.identifier,
                       shanghai.identifier)

        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: witnessURL)

        XCTAssertEqual(makeStore(in: newYork, legacy: suite).referenceTimeZone.identifier,
                       shanghai.identifier)
    }

    // MARK: - A lost scalar must not re-freeze

    /// The file is unreadable and the legacy key is still there: serve the
    /// legacy answer, and above all do NOT write the device's current zone over
    /// a file that may be perfectly good and merely unreadable right now (a
    /// launch before first unlock is enough to produce this).
    func testAnUnreadableFileServesTheLegacyZoneWithoutReFreezing() throws {
        seedLegacy(shanghai.identifier)
        _ = makeStore(in: shanghai, legacy: suite).referenceTimeZone
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)

        let afterTravel = makeStore(in: newYork, legacy: suite)
        XCTAssertEqual(afterTravel.referenceTimeZone.identifier, shanghai.identifier)
        XCTAssertTrue(afterTravel.isFrozen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "the corrupt file was quarantined; nothing may have written New York in its place")

        // A third launch, back in Shanghai, proves the same thing from the
        // other side: had New York been committed, this would now serve it.
        XCTAssertEqual(makeStore(in: shanghai, legacy: suite).referenceTimeZone.identifier,
                       shanghai.identifier)
    }

    /// Both copies gone out of band and no legacy key left to consult. There is
    /// no honest answer, so the store serves the device's zone for this session
    /// — and still refuses to write it down, because writing is what makes a
    /// recoverable situation permanent.
    func testALostFileServesTheCurrentZoneButNeverCommitsIt() {
        _ = makeStore(in: shanghai).referenceTimeZone
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: witnessURL.path), "fixture guard")

        let afterTravel = makeStore(in: newYork)
        XCTAssertTrue(afterTravel.isFrozen,
                      "written-and-lost is not the same question as never-written")
        XCTAssertEqual(afterTravel.referenceTimeZone.identifier, newYork.identifier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "THE regression: a lost scalar must not silently re-freeze a different zone")
    }

    /// An identifier this system does not know is readable but meaningless.
    /// Serve something so `dayKey` keeps working; commit nothing.
    func testAnUnknownStoredIdentifierIsServedOverButNotOverwritten() throws {
        try Data("\"Mars/Olympus_Mons\"".utf8).write(to: fileURL)

        let store = makeStore(in: newYork)
        XCTAssertEqual(store.referenceTimeZone.identifier, newYork.identifier)
        XCTAssertNil(store.establishedIdentifier)
        XCTAssertTrue(store.suppressesSettingsUpload)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("\"Mars/Olympus_Mons\"".utf8),
                       "the file is readable, so it is not ours to replace on a hunch")
    }

    // MARK: - The non-establishing reader

    /// `SyncedSettings.currentSnapshot()` runs on every settings upload and
    /// every local snapshot. If reading the key froze a zone, a device that had
    /// not yet drawn a calendar would freeze — and then broadcast — whatever
    /// zone it happened to be in at sync time.
    func testReadingForSyncDoesNotFreezeAZone() {
        let store = makeStore(in: newYork)
        XCTAssertNil(store.establishedIdentifier)
        XCTAssertFalse(store.suppressesSettingsUpload,
                       "nothing established is not a fault; the key is simply omitted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // The calendar renders; NOW it freezes.
        XCTAssertEqual(store.referenceTimeZone.identifier, newYork.identifier)
        XCTAssertEqual(store.establishedIdentifier, newYork.identifier)
    }

    // MARK: - Restore

    func testARestoreMayOverwriteAnEstablishedZone() {
        let store = makeStore(in: shanghai)
        XCTAssertEqual(store.referenceTimeZone.identifier, shanghai.identifier)

        XCTAssertTrue(store.applyRestoredIdentifier(newYork.identifier))
        XCTAssertEqual(store.referenceTimeZone.identifier, newYork.identifier)
        XCTAssertEqual(makeStore(in: shanghai).referenceTimeZone.identifier, newYork.identifier,
                       "cross-device agreement on dayKey is the reason this key is synced at all")
    }

    func testARestoreIsTheWayBackFromAnUnreadableFile() throws {
        _ = makeStore(in: shanghai).referenceTimeZone
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)

        let frozen = makeStore(in: newYork)
        XCTAssertTrue(frozen.isFrozen, "fixture guard")

        XCTAssertTrue(frozen.applyRestoredIdentifier(shanghai.identifier))
        XCTAssertFalse(frozen.isFrozen)
        XCTAssertEqual(makeStore(in: newYork).referenceTimeZone.identifier, shanghai.identifier)
    }

    /// A snapshot that does not carry the key says NOTHING about the frozen
    /// zone (an older snapshot, a peer that never uploaded it). Honouring that
    /// absence as a clear would let the next access freeze wherever the device
    /// is, while every restored record keeps a `dayKey` derived under the old
    /// zone — the loss this file exists to prevent, arriving as a restore.
    func testARestoreWithoutTheKeyDoesNotClearAnEstablishedZone() {
        let store = makeStore(in: shanghai)
        XCTAssertEqual(store.referenceTimeZone.identifier, shanghai.identifier)

        XCTAssertFalse(store.applyRestoredIdentifier(nil))
        XCTAssertEqual(store.referenceTimeZone.identifier, shanghai.identifier)
        XCTAssertEqual(makeStore(in: newYork).referenceTimeZone.identifier, shanghai.identifier)
    }

    // MARK: - The SyncedSettings bridge

    func testTheSettingsBlobCarriesTheFileBackedIdentifier() {
        let store = makeStore(in: shanghai)
        OccurrenceKeyMetadataStore.register(store, for: suite)
        _ = store.referenceTimeZone

        // Deliberately disagreeing with the (never-rewritten) legacy key, to
        // prove which one the blob is reading from.
        seedLegacy(newYork.identifier)

        let blob = SyncedSettings.currentSnapshot(suite)
        XCTAssertEqual(blob[CalendarOccurrenceKey.referenceTimeZoneDefaultsKey] as? String,
                       shanghai.identifier)
    }

    func testApplyingASettingsBlobWritesThroughToTheFile() {
        let store = makeStore(in: shanghai)
        OccurrenceKeyMetadataStore.register(store, for: suite)
        _ = store.referenceTimeZone

        SyncedSettings.apply(
            [CalendarOccurrenceKey.referenceTimeZoneDefaultsKey: newYork.identifier],
            resolution: .keepCloud,
            to: suite
        )

        XCTAssertEqual(store.referenceTimeZone.identifier, newYork.identifier)
        XCTAssertEqual(makeStore(in: shanghai).referenceTimeZone.identifier, newYork.identifier)
        XCTAssertNil(suite.string(forKey: CalendarOccurrenceKey.referenceTimeZoneDefaultsKey),
                     "two writable copies of one fact is the bug this migration removes")
    }

    func testReplacingSettingsWithoutTheKeyLeavesTheZoneStanding() {
        let store = makeStore(in: shanghai)
        OccurrenceKeyMetadataStore.register(store, for: suite)
        _ = store.referenceTimeZone

        SyncedSettings.replace(with: ["meDisplayName": "someone"], to: suite)

        XCTAssertEqual(store.referenceTimeZone.identifier, shanghai.identifier)
    }

    /// `user_settings` is one row upserted WHOLE. While the local zone is a
    /// guess, uploading it would broadcast the guess and omitting the key would
    /// delete the cloud's copy of the answer — so the blob waits.
    func testAnUnreadableZoneSuppressesTheWholeSettingsUpload() throws {
        _ = makeStore(in: shanghai).referenceTimeZone
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)

        let frozen = makeStore(in: newYork)
        OccurrenceKeyMetadataStore.register(frozen, for: suite)
        _ = frozen.referenceTimeZone

        XCTAssertTrue(SyncedSettings.hasUnreadableBridgedOwner(suite))
        XCTAssertTrue(SupabaseSyncService.settingsExportSuppressed(suite))
    }

    /// A readable file holding an identifier this OS does not know reaches the
    /// same place by a different road: `isFrozen` is FALSE — nothing failed to
    /// read — yet `establishedIdentifier` is nil, so the key silently drops out
    /// of the blob. Any gate written against `isFrozen` misses this entirely.
    func testAnUnknownStoredIdentifierAlsoHoldsTheSettingsBlobBack() throws {
        try Data("\"Mars/Olympus_Mons\"".utf8).write(to: fileURL)

        let store = makeStore(in: newYork)
        OccurrenceKeyMetadataStore.register(store, for: suite)

        XCTAssertFalse(store.isFrozen, "the file read perfectly well; its CONTENT is the problem")
        XCTAssertNil(store.establishedIdentifier)
        XCTAssertNil(SyncedSettings.currentSnapshot(suite)[
            CalendarOccurrenceKey.referenceTimeZoneDefaultsKey
        ], "which is exactly the hole")
        XCTAssertTrue(SyncedSettings.hasUnreadableBridgedOwner(suite))
    }

    // MARK: - The local DR snapshot

    /// The asymmetry this closes. `settingsExportSuppressed` holds the whole
    /// `user_settings` blob back while the zone is a guess, but the LOCAL
    /// snapshot — the other copy, the one that survives a lost account — was
    /// gated on the event slots, the catalog and the chat file only. So the
    /// snapshot with the key MISSING would overwrite the snapshot that had it,
    /// which is the same "stale beats holed" rule failing on the copy the user
    /// can actually reach offline.
    func testTheLocalBackupSnapshotIsNotOverwrittenWhileTheZoneIsUnreadable() throws {
        let storageName = "OccurrenceKeyMetadataStoreTests-\(UUID().uuidString)"
        let location = TestStorage.reset(storageName)
        defer { TestStorage.tearDown(storageName) }

        let storeDefaults = UserDefaults(suiteName: storageName)!
        let eventStore = EventStore(defaults: storeDefaults,
                                    storage: location,
                                    seedsSampleDataIfEmpty: false)
        XCTAssertFalse(eventStore.hasFrozenSlot, "fixture guard: the slots are healthy")

        _ = makeStore(in: shanghai).referenceTimeZone
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)
        let frozen = makeStore(in: newYork)
        OccurrenceKeyMetadataStore.register(frozen, for: suite)
        XCTAssertTrue(frozen.isFrozen, "fixture guard")

        // A scratch file rather than the app's real Documents snapshot: with
        // the dirty check (gh#219), the control write below could otherwise
        // be legitimately skipped against byte-equal leftovers a previous
        // run of this very test left on disk.
        let snapshotURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-snapshot-zone-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let before = try? Data(contentsOf: snapshotURL)

        // Held in locals: `BackupSnapshotService` keeps them `weak`, so an
        // argument built inline would be gone before the snapshot is written.
        let types = EventTypeTemplateStore(defaults: storeDefaults)
        let skills = SkillInsightStore(defaults: storeDefaults)
        let prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AgentPrefs-\(UUID().uuidString)", isDirectory: true))

        let reporter = SyncStatusReporter()
        let service = BackupSnapshotService()
        service.statusReporter = reporter
        // The seam: `.standard` would reach the app's own shared zone store,
        // which no test may put into a specific state.
        service.settingsDefaults = suite
        service.snapshotFileURLOverride = snapshotURL
        service.attach(eventStore: eventStore, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)

        // Called directly rather than by posting `didEnterBackground`: this is
        // a host-app test bundle, so that notification would also drive the
        // running app's own snapshot writer.
        service.writeSnapshotSync(reason: "didEnterBackground")

        XCTAssertEqual(try? Data(contentsOf: snapshotURL), before,
                       "the previous snapshot still carries the frozen zone; this one would not")
        XCTAssertNotNil(reporter.snapshot.lastError, "and the skip must be reported, not silent")

        // The control, so the skip cannot be passing for some unrelated reason:
        // the restore is the way back, and the very next write goes through.
        XCTAssertTrue(frozen.applyRestoredIdentifier(shanghai.identifier))
        service.writeSnapshotSync(reason: "didEnterBackground")
        XCTAssertNotEqual(try? Data(contentsOf: snapshotURL), before,
                          "and once the zone is knowable again the snapshot resumes")

        let document = try JSONSerialization.jsonObject(
            with: Data(contentsOf: snapshotURL)) as? [String: Any]
        let settings = document?["settings"] as? [String: Any]
        XCTAssertEqual(settings?[CalendarOccurrenceKey.referenceTimeZoneDefaultsKey] as? String,
                       shanghai.identifier,
                       "carrying the key it was holding out for")
    }

    // MARK: - The wipe (the local way out)

    /// Before `wipe()` existed, `.unusable` had exactly one exit — a cloud
    /// restore whose settings blob happened to carry the key — while "Reset
    /// all local data" wiped every OTHER durable store around it. One corrupt
    /// read of this once-written scalar (there is no `.bak` yet: the value is
    /// committed once and never rewritten) therefore suppressed every settings
    /// upload and every local DR snapshot FOREVER, with no local recovery.
    func testAWipeEndsTheUnusableStateAndItsSuppression() throws {
        _ = makeStore(in: shanghai).referenceTimeZone
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)

        let frozen = makeStore(in: newYork)
        XCTAssertTrue(frozen.isFrozen, "fixture guard")
        XCTAssertTrue(frozen.suppressesSettingsUpload, "fixture guard")

        frozen.wipe()

        XCTAssertFalse(frozen.isFrozen)
        XCTAssertFalse(frozen.suppressesSettingsUpload,
                       "the reset must end the suppression, not leave it standing")
        XCTAssertEqual(frozen.referenceTimeZone.identifier, newYork.identifier,
                       "the re-frozen zone is the device's current one — every record the old "
                       + "zone anchored was just erased with the rest of the local data")

        // The relaunch: re-frozen means ESTABLISHED, not `.lostAfterCommit` —
        // `AtomicValueFile.wipe()` keeps the commit witness, so an emptied-and-
        // abandoned directory would read straight back into the unusable state
        // the wipe exists to end.
        let next = makeStore(in: newYork)
        XCTAssertFalse(next.isFrozen)
        XCTAssertEqual(next.referenceTimeZone.identifier, newYork.identifier)
        XCTAssertFalse(next.suppressesSettingsUpload)
    }

    /// The reset flow purges the legacy key AFTER wiping the store. A kill in
    /// between must not have the next launch re-migrate exactly the zone the
    /// user asked to erase — the wipe's own re-commit is what makes the legacy
    /// key dead data again.
    func testAWipeIsNotUndoneByTheLegacyKeyStillBeingThere() {
        seedLegacy(shanghai.identifier)
        let store = makeStore(in: newYork, legacy: suite)
        XCTAssertEqual(store.referenceTimeZone.identifier, shanghai.identifier, "fixture guard")

        store.wipe()

        let next = makeStore(in: newYork, legacy: suite)
        XCTAssertEqual(next.referenceTimeZone.identifier, newYork.identifier,
                       "the primary the wipe committed wins; legacy stays dead data")
    }

    // MARK: - Telling the user

    /// The suppression above is silent by construction — it protects the cloud
    /// and the DR snapshot by NOT doing things. The banner is the only place
    /// the user can learn it is happening, and the banner's input must be the
    /// SAME predicate the exporters gate on: `isFrozen` alone would miss the
    /// readable-but-unknown-identifier case, which suppresses identically.
    func testProbeAnUnusableZoneStoreRaisesTheStorageFaultBanner() throws {
        let storageName = "OccurrenceKeyMetadataStoreTests-\(UUID().uuidString)"
        let location = TestStorage.reset(storageName)
        defer { TestStorage.tearDown(storageName) }
        let storeDefaults = UserDefaults(suiteName: storageName)!
        let eventStore = EventStore(defaults: storeDefaults,
                                    storage: location,
                                    seedsSampleDataIfEmpty: false)
        let types = EventTypeTemplateStore(defaults: storeDefaults)
        let conversations = AgentConversationRepository(
            directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("Conversations-\(UUID().uuidString)", isDirectory: true),
            legacyDefaults: nil)

        let healthy = makeStore(in: shanghai)
        XCTAssertFalse(
            StorageFaultBannerState(store: eventStore, eventTypeStore: types,
                                    conversations: conversations,
                                    occurrenceKeyMetadata: healthy).isDegraded,
            "fixture guard: nothing else is degraded, so the assertions below can only "
            + "be about the zone store")

        // Road one: the unreadable file.
        _ = healthy.referenceTimeZone
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)
        let frozen = makeStore(in: newYork)
        XCTAssertTrue(frozen.isFrozen, "fixture guard")
        let banner = StorageFaultBannerState(store: eventStore, eventTypeStore: types,
                                             conversations: conversations,
                                             occurrenceKeyMetadata: frozen)
        XCTAssertTrue(banner.isDegraded,
                      "a suppression that stops the offline backup updating must reach the USER")
        XCTAssertTrue(banner.isUnreadable,
                      "and it is the \"could not be read, restore\" wording — the restore is "
                      + "one of the two exits")

        // Road two: a readable file holding an identifier this OS does not
        // know. `isFrozen` is FALSE here, which is why the banner keys off the
        // suppression predicate and not the freeze.
        frozen.wipe()
        try Data("\"Mars/Olympus_Mons\"".utf8).write(to: fileURL)
        let unknowable = makeStore(in: newYork)
        XCTAssertFalse(unknowable.isFrozen, "fixture guard: nothing failed to READ")
        XCTAssertTrue(
            StorageFaultBannerState(store: eventStore, eventTypeStore: types,
                                    conversations: conversations,
                                    occurrenceKeyMetadata: unknowable).isDegraded,
            "a gate written against isFrozen would miss this entirely")
    }
}
