//
//  EventTypeCatalogTests.swift
//  DoneTests
//
//  The acceptance net for issue #143: event-type templates and the
//  deleted-type color history off `UserDefaults` and onto files.
//
//  The shape of the bug being fenced off is not "a save was slow". It is that
//  `load()` collapsed three very different situations — never written, written
//  and empty, written and UNREADABLE — into one answer: the built-in four.
//  That answer then leaves the device: `diffSync` is a mirror, so four
//  fallback rows uploaded DELETE every real type in the cloud, and the local
//  DR snapshot is rewritten from the same array on the next backgrounding.
//  Several tests below exist only to pin "must not be the built-in four".
//

import XCTest
import Combine
@testable import Done

@MainActor
final class EventTypeCatalogTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EventTypeCatalogTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "EventTypeCatalogTests-\(UUID().uuidString)"
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

    /// A fresh catalog over the same directory — the relaunch simulation.
    private func makeCatalog(legacy: UserDefaults? = nil) -> EventTypeCatalog {
        EventTypeCatalog(directory: directory, legacyDefaults: legacy)
    }

    private var templatesURL: URL {
        directory.appendingPathComponent(EventTypeCatalog.templatesFilename)
    }
    private var templatesBackupURL: URL {
        directory.appendingPathComponent("templates.bak")
    }
    private var templatesWitnessURL: URL {
        directory.appendingPathComponent("templates.committed")
    }
    private var historyURL: URL {
        directory.appendingPathComponent(EventTypeCatalog.colorHistoryFilename)
    }
    private var historyBackupURL: URL {
        directory.appendingPathComponent("colorHistory.bak")
    }

    private func template(_ title: String, _ hex: String) -> EventTypeTemplate {
        EventTypeTemplate(title: title, colorHex: hex)
    }

    /// A catalog whose templates file is shredded and whose backup is gone —
    /// i.e. genuinely unreadable, not merely recoverable.
    ///
    /// One commit, so there is no `.bak`: that is the NORMAL state right after
    /// the legacy migration and again right after "reset all local data",
    /// because `commit()` only hardlinks a backup when a primary is already
    /// there. The color history is left healthy.
    private func makeFrozenCatalog() throws -> EventTypeCatalog {
        let seeded = makeCatalog()
        XCTAssertTrue(seeded.setTemplates([template("Reading", "#112233")]))
        try Data("shredded".utf8).write(to: templatesURL)
        try? FileManager.default.removeItem(at: templatesBackupURL)
        let frozen = makeCatalog()
        XCTAssertTrue(frozen.isFrozen, "fixture guard")
        return frozen
    }

    /// The mirror image: the templates file is perfectly readable and only the
    /// color history is shredded.
    private func makeFrozenHistoryCatalog() throws -> EventTypeCatalog {
        let seeded = makeCatalog()
        XCTAssertTrue(seeded.setTemplates([template("Reading", "#112233")]))
        XCTAssertTrue(seeded.setColorHistory(["Gone": "#ABCDEF"]))
        try Data("shredded".utf8).write(to: historyURL)
        try? FileManager.default.removeItem(at: historyBackupURL)
        let frozen = makeCatalog()
        XCTAssertTrue(frozen.isColorHistoryFrozen, "fixture guard")
        return frozen
    }

    // MARK: - The edit cycle survives a relaunch

    func testCreateRecolorRenameReorderRemoveAllSurviveARelaunch() {
        let a = EventTypeTemplateStore(catalog: makeCatalog())
        XCTAssertEqual(a.templates, EventTypeCatalog.fallbackTemplates,
                       "fixture guard: a never-written catalog serves the built-ins")

        a.add("Reading", colorHex: "#112233")                              // create
        a.update(from: "Reading", to: "Reading", colorHex: "#445566")      // recolor
        a.update(from: "Study", to: "Deep Study", colorHex: "#34C759")     // rename
        a.move(from: IndexSet(integer: 0), to: 3)                          // reorder
        a.remove(title: "Sleep")                                           // remove

        let expected = a.templates
        XCTAssertTrue(expected.contains { $0.title == "Reading" && $0.colorHex == "#445566" })
        XCTAssertTrue(expected.contains { $0.title == "Deep Study" })
        XCTAssertFalse(expected.contains { $0.title == "Sleep" })
        XCTAssertNotEqual(expected.map(\.title), EventTypeCatalog.fallbackTemplates.map(\.title))

        // The relaunch: a brand-new catalog reading the same directory. This
        // is what `UserDefaults` could not promise — `set` returns once the
        // bytes reach cfprefsd, which batches, so a swipe-kill seconds later
        // took the edit with it.
        let b = EventTypeTemplateStore(catalog: makeCatalog())
        XCTAssertEqual(b.templates, expected)
    }

    func testADeletedTypesColorSurvivesARelaunch() {
        let a = EventTypeTemplateStore(catalog: makeCatalog())
        a.add("Reading", colorHex: "#112233")
        a.remove(title: "Reading")
        XCTAssertEqual(a.colorHistory["Reading"], "#112233")

        let b = makeCatalog()
        XCTAssertEqual(b.colorHistory["Reading"], "#112233",
                       "the history is why a re-created type comes back its old color")
    }

    // MARK: - Migration

    func testMigrationAdoptsTheLegacyBlobAndLeavesItExactlyWhereItWas() throws {
        let rows = [template("Reading", "#112233"), template("Writing", "#445566")]
        let raw = try JSONEncoder().encode(rows)
        suite.set(raw, forKey: EventTypeTemplateStore.storageKey)
        suite.set(["Gone": "#ABCDEF"], forKey: EventTypeTemplateStore.colorHistoryKey)

        let catalog = makeCatalog(legacy: suite)
        XCTAssertEqual(catalog.templates, rows)
        XCTAssertEqual(catalog.colorHistory, ["Gone": "#ABCDEF"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: templatesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))

        // The rollback safety net. Downgrading the binary must land the user
        // back on the migration-time snapshot, not on nothing — so the legacy
        // keys are never deleted and never rewritten.
        XCTAssertEqual(suite.data(forKey: EventTypeTemplateStore.storageKey), raw)
        XCTAssertEqual(suite.dictionary(forKey: EventTypeTemplateStore.colorHistoryKey) as? [String: String],
                       ["Gone": "#ABCDEF"])

        catalog.setTemplates([template("Only", "#000000")])
        catalog.setColorHistory(["New": "#FFFFFF"])
        XCTAssertEqual(suite.data(forKey: EventTypeTemplateStore.storageKey), raw,
                       "an edit after the migration must not touch the legacy blob either")
        XCTAssertEqual(suite.dictionary(forKey: EventTypeTemplateStore.colorHistoryKey) as? [String: String],
                       ["Gone": "#ABCDEF"])

        let relaunched = makeCatalog(legacy: suite)
        XCTAssertEqual(relaunched.templates.map(\.title), ["Only"],
                       "once a file exists the legacy key is dead data and is never consulted again")
    }

    /// The oldest builds stored a bare `[String]`. The funnel has to accept
    /// BOTH shapes: taking only the current one would freeze every user who
    /// never edited a type since that format changed.
    func testTheLegacyStringArrayShapeMigratesToo() throws {
        suite.set(try JSONEncoder().encode(["Study", "Reading"]),
                  forKey: EventTypeTemplateStore.storageKey)

        let catalog = makeCatalog(legacy: suite)
        XCTAssertEqual(catalog.templates.map(\.title), ["Study", "Reading"])
        XCTAssertEqual(catalog.templates[0].colorHex, "#34C759", "a seed title keeps its seed color")
        XCTAssertEqual(catalog.templates[1].colorHex, EventTypeTemplateStore.fallbackColorHex)
    }

    func testAnEmptyLegacyBlobIsAFreshStoreNotDamage() throws {
        suite.set(try JSONEncoder().encode([EventTypeTemplate]()),
                  forKey: EventTypeTemplateStore.storageKey)

        let catalog = makeCatalog(legacy: suite)
        XCTAssertFalse(catalog.isFrozen)
        XCTAssertEqual(catalog.templates, EventTypeCatalog.fallbackTemplates)
    }

    func testUndecodableLegacyBytesFreezeRatherThanSeedingTheBuiltInFour() {
        suite.set(Data("not json at all".utf8), forKey: EventTypeTemplateStore.storageKey)

        let catalog = makeCatalog(legacy: suite)
        XCTAssertTrue(catalog.isFrozen)
        XCTAssertNotEqual(catalog.templates, EventTypeCatalog.fallbackTemplates,
                          "a fallback served over damaged data is uploaded as if the user chose it")
        XCTAssertTrue(catalog.templates.isEmpty)
        XCTAssertFalse(catalog.setTemplates([template("X", "#000000")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: templatesURL.path),
                       "and nothing was written over the damage")
    }

    // MARK: - A damaged primary

    func testACorruptPrimaryFreezesInsteadOfServingTheBuiltInFour() throws {
        let frozen = try makeFrozenCatalog()

        XCTAssertNotEqual(frozen.templates, EventTypeCatalog.fallbackTemplates)
        XCTAssertTrue(frozen.templates.isEmpty)
        XCTAssertFalse(frozen.setTemplates([template("Anything", "#000000")]),
                       "a frozen catalog's array is not a faithful copy of the file")
        XCTAssertTrue(frozen.setColorHistory(["Anything": "#000000"]),
                      "the OTHER file is readable, and its refusal would buy nothing: the one "
                      + "caller that writes both checks the removal actually took")
        XCTAssertTrue(frozen.isDegraded, "and the user gets the banner")
    }

    func testAShreddedPrimaryIsRecoveredFromTheBackupWithoutFreezing() throws {
        let a = makeCatalog()
        a.setTemplates([template("Reading", "#112233")])
        a.setTemplates([template("Reading", "#112233"), template("Writing", "#445566")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: templatesBackupURL.path),
                      "fixture guard: the second commit hardlinks the first as .bak")

        try Data("shredded".utf8).write(to: templatesURL)

        let b = makeCatalog()
        XCTAssertFalse(b.isFrozen)
        XCTAssertEqual(b.templates.map(\.title), ["Reading"],
                       "last-known-good, not the built-in four")

        // And the recovery is written back under the primary name, so the next
        // launch is an ordinary one rather than another rescue.
        let c = makeCatalog()
        XCTAssertEqual(c.templates.map(\.title), ["Reading"])
        XCTAssertFalse(c.isFrozen)
    }

    // MARK: - The freeze has to outlive the process that raised it

    /// `read()` QUARANTINES a corrupt primary — it moves the file out of the
    /// directory. Without a durable trace the freeze would therefore last
    /// exactly one process lifetime: the next launch finds an empty directory,
    /// calls it a first run, serves the built-in four, stops suppressing the
    /// sync sinks, and `diffSync` (a mirror) DELETEs every real type in the
    /// cloud while the DR snapshot is rewritten from the same four rows. Both
    /// surviving copies, gone — verbatim the failure the freeze exists to
    /// prevent, one relaunch later.
    func testProbe_TheFreezeSurvivesARelaunchAndDoesNotBecomeTheBuiltInFour() throws {
        let launch1 = try makeFrozenCatalog()
        XCTAssertTrue(launch1.isTemplatesFrozen, "fixture guard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: templatesURL.path),
                       "fixture guard: the corrupt primary was moved into quarantine/, so the "
                       + "directory now looks byte-for-byte like a never-written store")

        let launch2 = makeCatalog(legacy: suite)
        XCTAssertTrue(launch2.isTemplatesFrozen)
        XCTAssertTrue(launch2.templates.isEmpty)
        XCTAssertNotEqual(launch2.templates, EventTypeCatalog.fallbackTemplates)
        XCTAssertFalse(launch2.setTemplates([template("Anything", "#000000")]))
        XCTAssertTrue(
            SupabaseSyncService.eventTypeExportSuppressed(of: EventTypeTemplateStore(catalog: launch2)),
            "and the export stays suppressed, which is the half that reaches the cloud")

        let launch3 = makeCatalog(legacy: suite)
        XCTAssertTrue(launch3.isTemplatesFrozen, "not a one-relaunch reprieve either")
    }

    /// The quieter variant, and the worse one: with the legacy blob still in
    /// place (it is deliberately never deleted — it is the rollback net), the
    /// relaunch after a freeze would RE-MIGRATE it. The user silently gets the
    /// migration-time snapshot back, every type edit since is rolled back, no
    /// banner, and the unsuppressed sink mirrors the rollback into the cloud as
    /// a delete. It looks legitimate, which is why it has to be impossible
    /// rather than merely unlikely.
    func testProbe_AFreezeDoesNotSilentlyRevertToTheMigrationTimeSnapshot() throws {
        let legacyBlob = try JSONEncoder().encode([template("Reading", "#112233")])
        suite.set(legacyBlob, forKey: EventTypeTemplateStore.storageKey)

        let launch0 = makeCatalog(legacy: suite)
        XCTAssertEqual(launch0.templates.map(\.title), ["Reading"], "fixture guard: migrated")
        XCTAssertTrue(launch0.setTemplates(launch0.templates + [template("Writing", "#445566")]))

        // No `.bak`: the store that has only ever committed once, the commit
        // killed between `removeItem(backupURL)` and `linkItem`, or plain
        // out-of-band loss.
        try? FileManager.default.removeItem(at: templatesBackupURL)
        try Data("shredded".utf8).write(to: templatesURL)

        let launch1 = makeCatalog(legacy: suite)
        XCTAssertTrue(launch1.isTemplatesFrozen, "fixture guard")

        let launch2 = makeCatalog(legacy: suite)
        XCTAssertTrue(launch2.isTemplatesFrozen)
        XCTAssertNotEqual(launch2.templates.map(\.title), ["Reading"],
                          "re-migration is only legal over a store that was provably never written")
        XCTAssertTrue(launch2.templates.isEmpty)
        XCTAssertEqual(suite.data(forKey: EventTypeTemplateStore.storageKey), legacyBlob,
                       "and the legacy blob is still sitting there untouched for a downgrade")
    }

    /// The witness covers what the quarantine trace cannot: nobody moved these
    /// files, they simply are not there any more.
    func testBothCopiesVanishingOutOfBandFreezeRatherThanLookFresh() throws {
        let seeded = makeCatalog()
        XCTAssertTrue(seeded.setTemplates([template("Reading", "#112233")]))

        try FileManager.default.removeItem(at: templatesURL)
        try? FileManager.default.removeItem(at: templatesBackupURL)

        let relaunched = makeCatalog(legacy: suite)
        XCTAssertTrue(relaunched.isTemplatesFrozen)
        XCTAssertTrue(relaunched.templates.isEmpty)
    }

    /// And the quarantine trace covers what the witness cannot: a store
    /// committed by a build that predates the witness, corrupted before this
    /// build ever got to read it successfully.
    func testAStoreCommittedByAnOlderBuildStillRemembersItsFreeze() throws {
        let seeded = makeCatalog()
        XCTAssertTrue(seeded.setTemplates([template("Reading", "#112233")]))
        try FileManager.default.removeItem(at: templatesWitnessURL)

        try Data("shredded".utf8).write(to: templatesURL)
        try? FileManager.default.removeItem(at: templatesBackupURL)

        let launch1 = makeCatalog(legacy: suite)
        XCTAssertTrue(launch1.isTemplatesFrozen, "fixture guard")

        let launch2 = makeCatalog(legacy: suite)
        XCTAssertTrue(launch2.isTemplatesFrozen,
                      "launch 1 left the corrupt primary in quarantine/; that is the proof")
    }

    /// "Reset all local data" is not one syscall. `wipe()` deletes every copy —
    /// INCLUDING the `quarantine/` trace, which for a store committed by a
    /// pre-witness build and corrupted before this build ever read it is the
    /// only proof it was ever written — and only then does the commit that
    /// writes the built-in four (and a witness with it) run. A kill in between
    /// left a directory with zero proof while the legacy blob was still sitting
    /// in `UserDefaults`, because `AgentSettingsView` clears it only AFTER
    /// `resetToDefaults()` returns. The next launch called that a first run and
    /// re-migrated the very blob the user had just asked to erase.
    func testProbe_AResetKilledBeforeItsCommitDoesNotReMigrateTheLegacyBlob() throws {
        let legacyBlob = try JSONEncoder().encode([template("Reading", "#112233")])
        suite.set(legacyBlob, forKey: EventTypeTemplateStore.storageKey)

        // An older build committed the store and left no witness behind, then
        // it was corrupted before this build managed one successful read.
        let seeded = makeCatalog()
        XCTAssertTrue(seeded.setTemplates([template("Reading", "#112233"),
                                           template("Writing", "#445566")]))
        try FileManager.default.removeItem(at: templatesWitnessURL)
        try Data("shredded".utf8).write(to: templatesURL)
        try? FileManager.default.removeItem(at: templatesBackupURL)

        let launch1 = makeCatalog(legacy: suite)
        XCTAssertTrue(launch1.isTemplatesFrozen, "fixture guard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: templatesWitnessURL.path),
                       "fixture guard: still no witness — the freeze rests entirely on the "
                       + "quarantine trace, which is exactly what a wipe deletes")

        // The user resets, and the process dies between the wipe and the commit
        // that follows it. `wipe()` is pure filesystem work, so a second file
        // object over the same path is a faithful stand-in for the catalog's
        // own — and stopping there IS the kill.
        AtomicValueFile<[EventTypeTemplate]>(
            directory: directory, filename: EventTypeCatalog.templatesFilename
        ).wipe()

        let launch2 = makeCatalog(legacy: suite)
        XCTAssertNotEqual(launch2.templates.map(\.title), ["Reading"],
                          "seeding from the legacy blob is legal over a store that was provably "
                          + "never written, and this directory is not one")
        XCTAssertTrue(launch2.templates.isEmpty)
        XCTAssertTrue(launch2.isTemplatesFrozen,
                      "written-then-lost, which is what it is, reads as .lostAfterCommit")
    }

    /// The same hole reached through the other leg: nothing was quarantined
    /// either, because the primary was never even decoded. A build that hits a
    /// transient read failure (a launch before the first unlock, say) raises
    /// `.ioError` and deliberately moves nothing — so for a store an older
    /// build committed, the primary file IS the only proof, and `wipe()`
    /// deletes it.
    func testProbe_AWipeLeavesProofBehindEvenForAPrimaryNothingHasReadYet() throws {
        let legacyBlob = try JSONEncoder().encode([template("Reading", "#112233")])
        suite.set(legacyBlob, forKey: EventTypeTemplateStore.storageKey)

        let seeded = makeCatalog()
        XCTAssertTrue(seeded.setTemplates([template("Writing", "#445566")]))
        try FileManager.default.removeItem(at: templatesWitnessURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: templatesURL.path),
                      "fixture guard: a healthy primary, and no witness anywhere")

        // A file object that has never read a byte — the process that reset was
        // the one whose read failed — wiped, and then killed.
        AtomicValueFile<[EventTypeTemplate]>(
            directory: directory, filename: EventTypeCatalog.templatesFilename
        ).wipe()

        let launch = makeCatalog(legacy: suite)
        XCTAssertNotEqual(launch.templates.map(\.title), ["Reading"],
                          "the erased store came back as the pre-migration snapshot")
        XCTAssertTrue(launch.templates.isEmpty)
        XCTAssertTrue(launch.isTemplatesFrozen)
    }

    /// And the guard is a guard, not an unconditional stamp: a store that
    /// genuinely never held anything must stay seedable after a wipe, or the
    /// first "reset all local data" a new user ever taps would freeze a catalog
    /// that has nothing wrong with it.
    func testAWipeOfANeverWrittenStoreLeavesItFresh() {
        AtomicValueFile<[EventTypeTemplate]>(
            directory: directory, filename: EventTypeCatalog.templatesFilename
        ).wipe()

        let launch = makeCatalog(legacy: suite)
        XCTAssertFalse(launch.isTemplatesFrozen)
        XCTAssertEqual(launch.templates, EventTypeCatalog.fallbackTemplates)
    }

    // MARK: - Two files, two freeze scopes

    /// The migration funnel argues the opposite blast radius in as many words —
    /// "this map is a nicety (it re-colors a re-created type), so dropping one
    /// unreadable entry beats refusing every template edit" — and a single
    /// OR'd `isFrozen` made a shredded history file do exactly what that
    /// comment forbids.
    func testProbe_ACorruptColorHistoryDoesNotFreezeTemplateEditing() throws {
        let catalog = try makeFrozenHistoryCatalog()

        XCTAssertEqual(catalog.templates.map(\.title), ["Reading"],
                       "the templates file is perfectly readable and loads")
        XCTAssertFalse(catalog.isTemplatesFrozen)
        XCTAssertTrue(catalog.isColorHistoryFrozen)

        XCTAssertTrue(
            catalog.setTemplates([template("Reading", "#112233"), template("Writing", "#445566")]),
            "create / rename / recolor / reorder / delete must not be locked out over a "
            + "lost color-memory map")
        XCTAssertEqual(makeCatalog().templates.map(\.title), ["Reading", "Writing"],
                       "and the edit reaches the file")

        XCTAssertFalse(catalog.setColorHistory(["Gone": "#000000"]),
                       "its own file still refuses — that one IS unreadable")

        let store = EventTypeTemplateStore(catalog: catalog)
        XCTAssertFalse(SupabaseSyncService.eventTypeExportSuppressed(of: store),
                       "and the templates mirror keeps running; it is a different file")
        XCTAssertTrue(store.isCatalogDegraded, "the banner still shows — something IS unreadable")
        XCTAssertTrue(store.isCatalogFrozen,
                      "and the DR document stays all-or-nothing, because it carries the history "
                      + "too (inside the settings blob)")
    }

    /// Why a frozen templates file does not need to reach into
    /// `setColorHistory`: the one caller that writes both checks that the
    /// removal actually took. Exercised through the single state where a
    /// frozen catalog still SHOWS templates — the directory is unavailable, so
    /// `read()` serves the legacy content and freezes in the same breath.
    func testARemovalTheFileRefusedDoesNotRememberAColorAsIfItHappened() throws {
        suite.set(try JSONEncoder().encode([template("Reading", "#112233")]),
                  forKey: EventTypeTemplateStore.storageKey)
        let catalog = EventTypeCatalog(
            directory: URL(fileURLWithPath: "/dev/null").appendingPathComponent("EventTypes"),
            legacyDefaults: suite
        )
        XCTAssertTrue(catalog.isTemplatesFrozen, "fixture guard")
        XCTAssertEqual(catalog.templates.map(\.title), ["Reading"],
                       "fixture guard: legacy still serves the user their content")

        let store = EventTypeTemplateStore(catalog: catalog)
        store.remove(title: "Reading")

        XCTAssertEqual(store.templates.map(\.title), ["Reading"], "the refusal is mirrored back")
        XCTAssertTrue(catalog.colorHistory.isEmpty,
                      "a color remembered for a type that was never removed is how the history "
                      + "fills up with entries for live templates")
    }

    // MARK: - The freeze triad

    func testAFrozenCatalogIsNotMirroredToTheCloud() throws {
        let frozen = try makeFrozenCatalog()
        let store = EventTypeTemplateStore(catalog: frozen)

        XCTAssertTrue(SupabaseSyncService.eventTypeExportSuppressed(of: store),
                      "diffSync is a mirror — uploading an unreadable catalog DELETEs the "
                      + "user's real cloud types")

        // Its OWN directory. A second catalog over the frozen one's directory
        // is not a healthy control — it is the relaunch, and it stays frozen
        // (which is the point of `testProbe_TheFreezeSurvives…`).
        let healthy = EventTypeTemplateStore(catalog: EventTypeCatalog(
            directory: directory.appendingPathComponent("healthy", isDirectory: true),
            legacyDefaults: nil
        ))
        XCTAssertFalse(SupabaseSyncService.eventTypeExportSuppressed(of: healthy))
    }

    func testTheLocalBackupSnapshotIsNotOverwrittenWhileTheCatalogIsFrozen() throws {
        let storageName = "EventTypeCatalogTests-\(UUID().uuidString)"
        let location = TestStorage.reset(storageName)
        defer { TestStorage.tearDown(storageName) }

        let eventStore = EventStore(defaults: UserDefaults(suiteName: storageName)!,
                                    storage: location,
                                    seedsSampleDataIfEmpty: false)
        XCTAssertFalse(eventStore.hasFrozenSlot, "fixture guard: the slots are healthy")

        let frozen = try makeFrozenCatalog()
        let types = EventTypeTemplateStore(catalog: frozen)
        let skills = SkillInsightStore(defaults: UserDefaults(suiteName: storageName)!)
        let prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AgentPrefs-\(UUID().uuidString)", isDirectory: true))

        let snapshotURL = try BackupSnapshotService.snapshotURL()
        let before = try? Data(contentsOf: snapshotURL)

        let reporter = SyncStatusReporter()
        let service = BackupSnapshotService()
        service.statusReporter = reporter
        service.attach(eventStore: eventStore, eventTypeStore: types,
                       skillStore: skills, preferenceStore: prefs)

        // Called directly rather than by posting `didEnterBackground`: this is
        // a host-app test bundle, so that notification would also drive the
        // running app's own snapshot writer.
        service.writeSnapshotSync(reason: "didEnterBackground")

        XCTAssertEqual(try? Data(contentsOf: snapshotURL), before,
                       "one frozen member poisons the whole document — a snapshot with the "
                       + "types emptied out strips the color off every event on restore")
        XCTAssertNotNil(reporter.snapshot.lastError, "and the skip must be reported, not silent")
    }

    func testOnlyAnExplicitClearUnfreezes() throws {
        let frozen = try makeFrozenCatalog()
        XCTAssertFalse(frozen.setTemplates([template("Nope", "#000000")]))

        // The restore path: the user has looked at the cloud copy and said
        // "use that". Nothing automatic may reach this.
        frozen.clearFault()
        XCTAssertFalse(frozen.isFrozen)
        XCTAssertTrue(frozen.setTemplates([template("Restored", "#112233")]))
        XCTAssertEqual(makeCatalog().templates.map(\.title), ["Restored"])
    }

    func testAFrozenCatalogIsStillErasable() throws {
        let frozen = try makeFrozenCatalog()

        // The user asked for the data to be gone, and a file we could not READ
        // is one we can still empty.
        frozen.wipeToDefaults()
        XCTAssertFalse(frozen.isFrozen)
        XCTAssertEqual(frozen.templates, EventTypeCatalog.fallbackTemplates)
        XCTAssertTrue(frozen.colorHistory.isEmpty)

        let relaunched = makeCatalog()
        XCTAssertFalse(relaunched.isFrozen)
        XCTAssertEqual(relaunched.templates, EventTypeCatalog.fallbackTemplates,
                       "and after a reset the built-ins are WRITTEN, not merely served")
    }

    func testARefusedEditDoesNotLingerInTheUI() throws {
        let store = EventTypeTemplateStore(catalog: try makeFrozenCatalog())
        XCTAssertTrue(store.isCatalogDegraded)

        store.add("Reading", colorHex: "#112233")
        XCTAssertFalse(store.templates.contains { $0.title == "Reading" },
                       "showing an edit the file will never receive is how the user learns "
                       + "about the fault by losing work")
    }

    // MARK: - One truth, many mirrors

    func testTwoStoresOverOneCatalogDoNotDrift() {
        let catalog = makeCatalog()
        let a = EventTypeTemplateStore(catalog: catalog)
        let b = EventTypeTemplateStore(catalog: catalog)

        a.add("Reading", colorHex: "#112233")
        XCTAssertEqual(b.templates, a.templates,
                       "six views each hold their own store; before this they diverged the "
                       + "moment one of them saved")

        b.remove(title: "Reading")
        XCTAssertEqual(a.templates, b.templates)
    }

    func testTheStaticReadersAgreeWithTheLiveStore() {
        let store = EventTypeTemplateStore(defaults: suite)

        store.add("Reading", colorHex: "#112233")
        XCTAssertEqual(EventTypeTemplateStore.colorHex(for: "Reading", defaults: suite), "#112233")

        store.update(from: "Reading", to: "Reading", colorHex: "#445566")
        XCTAssertEqual(EventTypeTemplateStore.colorHex(for: "Reading", defaults: suite), "#445566",
                       "the static reader used to answer from the legacy key, so a recolor "
                       + "showed on the canvas and not in the widget (or the other way round)")
        XCTAssertEqual(ColorHex.fromColor(EventTypeTemplateStore.color(for: "Reading", defaults: suite)),
                       "#445566")

        store.remove(title: "Reading")
        XCTAssertEqual(EventTypeTemplateStore.colorHex(for: "Reading", defaults: suite), "#445566",
                       "a removed type still renders its historical color")

        XCTAssertEqual(EventTypeTemplateStore.colorHex(for: "Never Existed", defaults: suite),
                       EventTypeTemplateStore.fallbackColorHex)
    }

    func testStaticReadersDegradeDeterministicallyUnderAFreeze() throws {
        let frozen = try makeFrozenCatalog()
        // The statics resolve through the registry, so exercise them via the
        // catalog's own ladder rather than the shared one.
        XCTAssertTrue(frozen.templates.isEmpty)
        XCTAssertNil(frozen.colorHistory["Reading"])

        let store = EventTypeTemplateStore(catalog: frozen)
        XCTAssertEqual(store.colorHex(for: "Study"), "#34C759",
                       "colors degrade to the deterministic default; nothing gets uploaded")
    }

    // MARK: - SyncedSettings bridging

    func testColorHistoryIsSyncedThroughTheCatalogNotUserDefaults() {
        let store = EventTypeTemplateStore(defaults: suite)
        store.add("Reading", colorHex: "#112233")
        store.remove(title: "Reading")

        let snapshot = SyncedSettings.currentSnapshot(suite)
        XCTAssertEqual(snapshot[EventTypeTemplateStore.colorHistoryKey] as? [String: String],
                       ["Reading": "#112233"],
                       "the key stays on the wire; only where this side reads it changed")
        XCTAssertNil(suite.object(forKey: EventTypeTemplateStore.colorHistoryKey),
                     "two writable copies of one fact is the bug being removed")

        SyncedSettings.apply([EventTypeTemplateStore.colorHistoryKey: ["Cloud": "#ABCDEF"]],
                             resolution: .keepCloud, to: suite)
        XCTAssertEqual(EventTypeCatalog.forDefaults(suite).colorHistory, ["Cloud": "#ABCDEF"])
        XCTAssertNil(suite.object(forKey: EventTypeTemplateStore.colorHistoryKey))

        SyncedSettings.replace(with: [:], to: suite)
        XCTAssertTrue(EventTypeCatalog.forDefaults(suite).colorHistory.isEmpty,
                      "cloudOverwritesLocal means exactly the cloud snapshot, bridged keys included")
    }

    /// `user_settings` is ONE row per user and `syncSettings` upserts the whole
    /// blob — there is no per-key diff — so a key the blob does not carry is a
    /// key the cloud loses. A frozen history file reads as empty, `bridgedValue`
    /// omits it, and the next unrelated settings write (any
    /// `UserDefaults.didChangeNotification`, 5 s later) would erase the cloud's
    /// copy at precisely the moment the cloud was one of the two surviving
    /// copies. Unreadable is not empty.
    func testProbe_AFrozenColorHistoryIsNotReportedToSyncAsAbsent() throws {
        let frozen = try makeFrozenHistoryCatalog()
        EventTypeCatalog.register(frozen, for: suite)

        XCTAssertNil(SyncedSettings.currentSnapshot(suite)[EventTypeTemplateStore.colorHistoryKey],
                     "fixture guard: an unreadable file has nothing to report, and the blob "
                     + "cannot say 'do not touch this key'")
        XCTAssertTrue(SyncedSettings.hasUnreadableBridgedOwner(suite))
        XCTAssertTrue(SupabaseSyncService.settingsExportSuppressed(suite),
                      "so the upload is suppressed instead — a stale cloud blob beats a "
                      + "truncated one")

        let healthyName = "EventTypeCatalogTests-healthy-\(UUID().uuidString)"
        let healthySuite = UserDefaults(suiteName: healthyName)!
        defer { healthySuite.removePersistentDomain(forName: healthyName) }
        XCTAssertFalse(SupabaseSyncService.settingsExportSuppressed(healthySuite),
                       "and a catalog that is merely EMPTY still uploads normally")
    }

    func testKeepLocalDoesNotOverwriteAnExistingColorHistory() {
        let store = EventTypeTemplateStore(defaults: suite)
        store.add("Reading", colorHex: "#112233")
        store.remove(title: "Reading")

        SyncedSettings.apply([EventTypeTemplateStore.colorHistoryKey: ["Cloud": "#ABCDEF"]],
                             resolution: .keepLocal, to: suite)
        XCTAssertEqual(EventTypeCatalog.forDefaults(suite).colorHistory, ["Reading": "#112233"])
    }

    // MARK: - Restore is the only unfreeze, and only for what it carries

    /// The unfreeze rides on the user having accepted the cloud copy — so it
    /// may only cover the halves the cloud copy CONTAINS. A merge of a snapshot
    /// with no `eventTypes` (an older snapshot, or a peer that never uploaded
    /// its types) says nothing about the user's types: `applyRestore`
    /// short-circuits, nothing is written, and an unconditional unfreeze leaves
    /// a writably EMPTY catalog standing over the quarantined file — where the
    /// next ordinary edit commits `[] + edit` and the now-unsuppressed sink
    /// mirrors that up.
    func testProbe_AMergeRestoreWithNoTypesDoesNotUnfreezeIntoAnEmptyCatalog() throws {
        let frozen = try makeFrozenCatalog()
        let store = EventTypeTemplateStore(catalog: frozen)

        let typeless = RestoreSnapshot.empty
        XCTAssertTrue(typeless.eventTypes.isEmpty, "fixture guard")
        let unfreeze = RestoreCoordinator.catalogUnfreeze(for: typeless)
        XCTAssertFalse(unfreeze.templates)
        XCTAssertFalse(unfreeze.colorHistory)

        // The coordinator's own sequence, minus the network.
        store.clearCatalogFault(templates: unfreeze.templates, colorHistory: unfreeze.colorHistory)
        XCTAssertEqual(store.applyRestore(templates: typeless.eventTypes,
                                          strategy: .merge, resolution: .keepLocal), 0)

        XCTAssertTrue(frozen.isTemplatesFrozen,
                      "nothing replaced the quarantined file, so nothing earned the unfreeze")
        XCTAssertTrue(frozen.templates.isEmpty)
        XCTAssertFalse(frozen.setTemplates([template("Anything", "#000000")]))

        // A restore that DOES carry types is exactly the user-confirmed path
        // the freeze leaves open.
        var withTypes = RestoreSnapshot.empty
        withTypes.eventTypes = [template("Cloud", "#ABCDEF")]
        withTypes.settings = [EventTypeTemplateStore.colorHistoryKey: ["Gone": "#123456"]]
        let second = RestoreCoordinator.catalogUnfreeze(for: withTypes)
        XCTAssertTrue(second.templates)
        XCTAssertTrue(second.colorHistory)

        store.clearCatalogFault(templates: second.templates, colorHistory: second.colorHistory)
        XCTAssertEqual(store.applyRestore(templates: withTypes.eventTypes,
                                          strategy: .merge, resolution: .keepLocal), 1)
        XCTAssertEqual(makeCatalog().templates.map(\.title), ["Cloud"],
                       "and this one reaches the file")
    }

    /// A `cloudOverwritesLocal` whose cloud side has no types falls back to the
    /// built-in four — which a frozen catalog must still refuse, or the
    /// fallback four end up committed over the user's quarantined types after
    /// all, by the one path that was supposed to rescue them.
    func testAnOverwriteRestoreWithNoTypesDoesNotCommitTheBuiltInFour() throws {
        let frozen = try makeFrozenCatalog()
        let store = EventTypeTemplateStore(catalog: frozen)

        let typeless = RestoreSnapshot.empty
        let unfreeze = RestoreCoordinator.catalogUnfreeze(for: typeless)
        store.clearCatalogFault(templates: unfreeze.templates, colorHistory: unfreeze.colorHistory)

        XCTAssertEqual(store.applyRestore(templates: typeless.eventTypes,
                                          strategy: .cloudOverwritesLocal, resolution: .keepLocal), 0,
                       "and the summary must not claim four types landed")
        XCTAssertTrue(frozen.isTemplatesFrozen)
        XCTAssertNotEqual(frozen.templates, EventTypeCatalog.fallbackTemplates)
    }

    // MARK: - Isolation

    /// Every test location must stay off the real catalog. `DoneTests` is a
    /// host-app bundle, so a store that resolved to the production directory
    /// would be editing the dogfood user's own event types while the app is
    /// running.
    func testATestSuiteNeverResolvesToTheSharedCatalog() {
        XCTAssertFalse(EventTypeCatalog.forDefaults(suite) === EventTypeCatalog.shared)
        XCTAssertTrue(EventTypeCatalog.forDefaults(suite) === EventTypeCatalog.forDefaults(suite),
                      "and the same suite keeps the same catalog, or a store and the static "
                      + "readers would answer from two different files")
        XCTAssertTrue(EventTypeCatalog.forDefaults(.standard) === EventTypeCatalog.shared)
    }
}
