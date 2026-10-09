import XCTest
@testable import Done

//  Independent QA for the erase-completeness branch (gh#260 / #261 / #263).
//
//  The branch shipped five purge CALLS and a source guard that the calls are
//  still written in `resetAllLocalData`. A source guard proves the call site
//  exists; it proves nothing about what the callee does. Every test below is
//  a RUNTIME witness: put real bytes on disk, prove they are there (liveness),
//  run the production purge, prove they are gone — and where an absence is
//  asserted, pair it with a positive control so a vacuous "nothing was ever
//  written" cannot pass for a successful erase.
//
//  Plus the question the branch left open and filed as gh#264: can a restore
//  marker in `pending/` resurrect erased data on the next launch. Measured
//  here, both defences isolated, with a control that proves the replay
//  machinery is live.

@MainActor
final class EraseDiskWitnessQATests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("EraseDiskWitnessQATests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        super.tearDown()
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - gh#260: attached event/log photos

    /// `AgenticIntakeAssetStore().removeAllAssets()` must take the whole
    /// directory, not one event's subdirectory.
    ///
    /// Positive control: a SECOND store rooted elsewhere keeps its asset, so
    /// the absence below is `removeAllAssets` working rather than the fixture
    /// never having written anything.
    func testRemoveAllAssetsTakesEveryEventsPhotosAndOnlyItsOwnDirectory() throws {
        let base = scratch.appendingPathComponent("assets", isDirectory: true)
        let bystanderBase = scratch.appendingPathComponent("bystander-assets", isDirectory: true)
        let jpegBytes = Data(repeating: 0xAB, count: 64)
        func store(at url: URL) -> AgenticIntakeAssetStore {
            AgenticIntakeAssetStore(baseDirectoryURL: url,
                                    imageProcessor: { _ in (jpegBytes, CGSize(width: 10, height: 10)) })
        }

        let subject = store(at: base)
        let eventA = UUID(), eventB = UUID()
        let refsA = try subject.saveImages([.init(data: Data([0x01]))], for: eventA)
        let refsB = try subject.saveImages([.init(data: Data([0x02]))], for: eventB)
        let bystanderRefs = try store(at: bystanderBase)
            .saveImages([.init(data: Data([0x03]))], for: UUID())

        // Liveness: the photos really are on disk, and they really are the bytes.
        let urlA = subject.absoluteURL(for: refsA[0])
        let urlB = subject.absoluteURL(for: refsB[0])
        XCTAssertTrue(exists(urlA), "liveness: the fixture must have written event A's photo")
        XCTAssertTrue(exists(urlB), "liveness: the fixture must have written event B's photo")
        XCTAssertEqual(try Data(contentsOf: urlA), jpegBytes)

        subject.removeAllAssets()

        XCTAssertFalse(exists(urlA), "gh#260: an erase must take every attached photo")
        XCTAssertFalse(exists(urlB),
                       "gh#260: and not just the one event the single-row delete path reaches")
        XCTAssertFalse(exists(base), "the directory itself must go, not just its contents")
        // Positive control.
        XCTAssertTrue(exists(store(at: bystanderBase).absoluteURL(for: bystanderRefs[0])),
                      "positive control: removeAllAssets must not be deleting the whole container "
                      + "— if this fails the assertions above prove nothing")
    }

    // MARK: - gh#263: contact avatars, and the in-memory cache

    /// `PersonAvatarStore.removeAll()` has no injection seam — it resolves
    /// Application Support itself — so this test necessarily operates on the
    /// test host's own container. That is a finding in its own right: the
    /// production purge cannot be witnessed without touching the process's
    /// real avatar directory.
    ///
    /// Two assertions, not one. The file going away is the disk half; the
    /// `image(named:)` miss is the `NSCache` half, which is the only thing
    /// stopping a wiped avatar from rendering from memory for the rest of the
    /// process. `save` populates the cache on the way in, so without
    /// `cache.removeAllObjects()` the second assertion returns the image.
    func testPersonAvatarRemoveAllTakesTheJPEGAndTheInMemoryCache() throws {
        let image = UIImage(ciImage: .init(color: .red).cropped(
            to: CGRect(x: 0, y: 0, width: 24, height: 24)))
        guard let name = PersonAvatarStore.save(image) else {
            return XCTFail("liveness: the fixture must be able to save an avatar")
        }
        // Liveness on both halves before the purge.
        XCTAssertNotNil(PersonAvatarStore.image(named: name),
                        "liveness: the avatar must be readable before the erase")
        let appSupport = try XCTUnwrap(FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let onDisk = appSupport
            .appendingPathComponent("PersonAvatars", isDirectory: true)
            .appendingPathComponent(name)
        XCTAssertTrue(exists(onDisk), "liveness: the JPEG must really be on disk")

        PersonAvatarStore.removeAll()

        XCTAssertFalse(exists(onDisk),
                       "gh#263: photographs of other people must not survive the erase")
        XCTAssertNil(PersonAvatarStore.image(named: name),
                     "gh#263: the NSCache must be cleared too — otherwise a wiped avatar keeps "
                     + "rendering from memory for the rest of the process")
    }

    // MARK: - gh#261: reports, including the user's own writing

    func testReportStoreWipeTakesEveryReportIncludingTheUserNote() throws {
        let dir = scratch.appendingPathComponent("Reports", isDirectory: true)
        let bystanderDir = scratch.appendingPathComponent("Reports-bystander", isDirectory: true)
        let note = "QA-WITNESS-USER-NOTE-\(UUID().uuidString)"
        let subject = ReportStore(directoryURL: dir)
        let report = makeReport(userNote: note)
        try subject.save(report)
        try ReportStore(directoryURL: bystanderDir).save(makeReport(userNote: "bystander"))

        // Liveness: the note is on disk, in plaintext, under that directory.
        let file = dir.appendingPathComponent("\(report.id.uuidString).json")
        XCTAssertTrue(exists(file), "liveness: the report file must exist before the wipe")
        let bytes = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
        XCTAssertTrue(bytes.contains(note),
                      "liveness: the user's own words must really be in the file — otherwise "
                      + "their absence afterwards would prove nothing")
        XCTAssertEqual(subject.loadAll().count, 1)

        subject.wipe()

        XCTAssertFalse(exists(file), "gh#261: the report file must go")
        XCTAssertFalse(exists(dir), "gh#261: and the directory with it")
        XCTAssertTrue(ReportStore(directoryURL: dir).loadAll().isEmpty,
                      "a freshly constructed store must read nothing back")
        XCTAssertEqual(ReportStore(directoryURL: bystanderDir).loadAll().count, 1,
                       "positive control: wipe() must be scoped to its own directory")
    }

    // MARK: - gh#263: LLM usage counters

    /// `clearAll()` does NOT remove the file — it writes the emptied buckets
    /// back through `persistLocked()`. So `Documents/DeveloperStats/
    /// llm-usage.json` still EXISTS after an erase, holding `[]`. That is
    /// substantively an erase (no user-attributable bytes remain) and this
    /// test pins both halves, so a future reader is not misled by the
    /// inventory's directory-level "sweptByErase" wording.
    func testLLMUsageClearAllLeavesNoModelActivityOnDiskButKeepsTheFile() throws {
        let dir = scratch.appendingPathComponent("DeveloperStats", isDirectory: true)
        let file = dir.appendingPathComponent("llm-usage.json")
        let model = "qa-witness-model-\(UUID().uuidString)"
        let store = LLMUsageStore(directoryURL: dir)
        store.recordFailure(model: model, purpose: "qa-witness-purpose")

        // Liveness: the activity is on disk and names the model.
        XCTAssertTrue(exists(file), "liveness: the usage file must exist before clearAll()")
        let before = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
        XCTAssertTrue(before.contains(model), "liveness: the model name must really be in the file")
        XCTAssertFalse(store.allBuckets().isEmpty)

        store.clearAll()

        let after = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
        XCTAssertFalse(after.contains(model),
                       "gh#263: per-day/model activity must not survive the erase")
        XCTAssertTrue(LLMUsageStore(directoryURL: dir).allBuckets().isEmpty,
                      "a freshly constructed store must read nothing back")
        XCTAssertTrue(exists(file),
                      "characterization, not an endorsement: clearAll() REWRITES the file empty "
                      + "rather than removing it, so the path survives the erase holding `[]`")
    }

    // MARK: - gh#263: spike run records, including user-entered notes

    func testSpikeRunStoreWipeTakesRunRecordsIncludingTheirNotes() throws {
        let location = SpikeRunStorageLocation.ephemeral(id: UUID())
        let bystander = SpikeRunStorageLocation.ephemeral(id: UUID())
        let note = "QA-WITNESS-SPIKE-NOTE-\(UUID().uuidString)"
        let run = makeSpikeRun(spikeID: "qa-witness")
        XCTAssertTrue(SpikeRunStore.beginRun(run, location: location))
        XCTAssertTrue(SpikeRunStore.setNote(note, forRunID: run.id, spikeID: run.spikeID,
                                            location: location))
        XCTAssertTrue(SpikeRunStore.beginRun(makeSpikeRun(spikeID: "bystander"), location: bystander))

        // Liveness: the note is on disk in plaintext.
        let file = location.directory.appendingPathComponent("qa-witness.jsonl")
        XCTAssertTrue(exists(file), "liveness: the run file must exist before the wipe")
        let bytes = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
        XCTAssertTrue(bytes.contains(note), "liveness: the user's note must really be in the file")

        SpikeRunStore.wipe(location: location)

        XCTAssertFalse(exists(file), "gh#263: run records carrying user notes must go")
        XCTAssertFalse(exists(location.directory), "and the directory with them")
        XCTAssertTrue(SpikeRunStore.loadRuns(spikeID: "qa-witness", location: location).isEmpty)
        XCTAssertFalse(SpikeRunStore.loadRuns(spikeID: "bystander", location: bystander).isEmpty,
                       "positive control: wipe() must be scoped to the location it is given")
        SpikeRunStore.wipe(location: bystander)
    }

    // MARK: - gh#264: can `pending/` resurrect erased data?

    private struct RestoreMarkerMirror: Codable {
        var events: [Event]
        var calendarEvents: [Event]
        var logs: [CalendarEventLogRecord]
        var feedback: [CalendarEventFeedbackRecord]
        var todoLists: [TodoList]
        var baseSeqs: [String: UInt64]
    }

    private static let restoreSlots: [StorageSlot] = [
        .events, .calendarEvents, .calendarEventLogRecords,
        .calendarEventFeedbackRecords, .todoLists,
    ]

    private func seqs(_ store: EventStore) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: Self.restoreSlots.map {
            ($0.rawValue, store.storage.committedSeq($0))
        })
    }

    private func pendingEntries(_ location: EventStorageLocation) -> [String] {
        guard let dir = try? location.directoryURL()
            .appendingPathComponent("pending", isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.sorted()
    }

    /// DEFENCE 1, measured on disk: the erase deletes the markers.
    ///
    /// The branch's commit message says "`clearAllPendingWork` exists and the
    /// erase never calls it". `EventStore.clearAllLocalData` calls
    /// `storage.clearAllPendingWork(kind:)` — this reads the `pending/`
    /// directory itself rather than the API, so it answers what is actually
    /// left on disk after an erase: no marker files, and an empty directory.
    func testTheErasePurgesEveryRestoreMarkerFromPendingOnDisk() throws {
        let name = "EraseDiskWitnessQA-defence1-\(UUID().uuidString)"
        let location = TestStorage.reset(name)
        defer { TestStorage.tearDown(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        store.addCalendarEvent(event("SECRET-CAL"))
        _ = try store.storage.recordPendingWork(
            kind: "restore",
            payload: JSONEncoder().encode(RestoreMarkerMirror(
                events: [], calendarEvents: [event("SECRET-CAL")], logs: [], feedback: [],
                todoLists: [], baseSeqs: seqs(store)))
        )

        // Liveness: a marker file really is in `pending/`, and it really
        // contains the plaintext title.
        let before = pendingEntries(location)
        XCTAssertEqual(before.count, 1, "liveness: the marker must be on disk before the erase")
        let dir = try location.directoryURL().appendingPathComponent("pending", isDirectory: true)
        let markerText = try XCTUnwrap(String(
            data: try Data(contentsOf: dir.appendingPathComponent(before[0])), encoding: .utf8))
        XCTAssertTrue(markerText.contains("SECRET-CAL"),
                      "liveness: a marker carries the event PLAINTEXT, which is the whole worry")

        store.clearAllLocalData()

        XCTAssertEqual(pendingEntries(location), [],
                       "gh#264: `pending/` must hold no marker after an erase — "
                       + "clearAllLocalData does call clearAllPendingWork(kind:)")
        XCTAssertTrue(exists(dir),
                      "characterization: the empty DIRECTORY does survive. That — not plaintext — "
                      + "is the whole of what gh#264 can still be about on this path")
    }

    /// DEFENCE 2, isolated: even a marker that somehow survives the purge is
    /// rejected, because every slot's generation advanced past the marker's
    /// recorded base when the erase committed its empty envelopes.
    ///
    /// The marker is written AFTER the erase with PRE-erase bases, which is
    /// the only shape that could outlive defence 1 (a concurrent restore that
    /// recorded its intent before the erase and landed its file after it).
    func testASurvivingRestoreMarkerCannotResurrectErasedDataOnTheNextLaunch() throws {
        let name = "EraseDiskWitnessQA-defence2-\(UUID().uuidString)"
        let location = TestStorage.reset(name)
        defer { TestStorage.tearDown(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let a = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        a.addCalendarEvent(event("SECRET-CAL"))
        let preEraseSeqs = seqs(a)
        XCTAssertFalse(a.rawCalendarEvents.isEmpty, "liveness: the data must exist to be erased")

        a.clearAllLocalData()
        _ = try a.storage.recordPendingWork(
            kind: "restore",
            payload: JSONEncoder().encode(RestoreMarkerMirror(
                events: [event("SECRET-TODO", kind: .todo)],
                calendarEvents: [event("SECRET-CAL")],
                logs: [], feedback: [],
                todoLists: [TodoList(title: "SECRET-LIST", colorName: "red")],
                baseSeqs: preEraseSeqs))
        )
        XCTAssertEqual(pendingEntries(location).count, 1,
                       "liveness: the marker must be on disk for the next launch to find it")

        let b = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)

        XCTAssertTrue(b.rawCalendarEvents.isEmpty, "gh#264: erased calendar must not come back")
        XCTAssertTrue(b.events.isEmpty, "gh#264: erased todos must not come back")
        XCTAssertTrue(b.todoLists.isEmpty, "gh#264: erased lists must not come back")
    }

    /// POSITIVE CONTROL for the two tests above, and the reason gh#264 is not
    /// nothing: the replay machinery IS live. With bases captured AFTER the
    /// erase — i.e. a marker whose staleness test still passes — the next
    /// launch writes the payload straight back into the store.
    ///
    /// So the erase is safe because of two specific facts (the markers are
    /// deleted; the generations moved), not because a marker could not
    /// resurrect data. Anything that ever records a marker after the slot
    /// commits re-opens this.
    func testAMarkerWhoseBasesAreNotStaleDoesResurrectTheData() throws {
        let name = "EraseDiskWitnessQA-control-\(UUID().uuidString)"
        let location = TestStorage.reset(name)
        defer { TestStorage.tearDown(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let a = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        a.addCalendarEvent(event("SECRET-CAL"))
        a.clearAllLocalData()
        XCTAssertTrue(a.rawCalendarEvents.isEmpty)

        _ = try a.storage.recordPendingWork(
            kind: "restore",
            payload: JSONEncoder().encode(RestoreMarkerMirror(
                events: [], calendarEvents: [event("RESURRECTED")], logs: [], feedback: [],
                todoLists: [], baseSeqs: seqs(a)))
        )

        let b = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        XCTAssertEqual(b.rawCalendarEvents.map(\.title), ["RESURRECTED"],
                       "positive control: a non-stale marker IS replayed on the next launch. "
                       + "If this ever goes red the two absence assertions above are vacuous.")
    }

    // MARK: - The tripwire's reach

    /// The census scans for literals passed to `appendingPathComponent(`.
    /// That is one idiom, and it is NOT the dominant one in this tree: the
    /// usual shape here is a named constant (`static let productionDirectoryName
    /// = "EventStore"`) handed to `appendingPathComponent(name)`, or a literal
    /// handed to some OTHER path-building function (`url("manifest.json")`).
    ///
    /// Every name below is a real production on-disk location holding user
    /// data, and none of them is in the census's found set. The erase does
    /// cover each one today — this is about the INSTRUMENT's reach, not a new
    /// leak — but the instrument's promise is "a new on-disk location cannot
    /// be waved through, only classified", and through these idioms it can.
    ///
    /// Fixing the scanner should make this test fail; delete the names it has
    /// learned to see.
    func testNamedConstantPathsAreOutsideTheCensusReach() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var found = Set<String>()
        for dir in ["Done", "Shared", "DoneWidget"] {
            let root = repoRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
                found.formUnion(EraseCompletenessTripwireTests.pathComponentLiterals(in: text))
            }
        }
        XCTAssertFalse(found.isEmpty, "liveness: the scanner must find something")

        // Each entry: the on-disk name, and the production declaration that
        // proves it is real. Both halves are checked, so this cannot rot into
        // a list of names that no longer exist.
        let invisible: [(name: String, declaredAs: String, inFile: String)] = [
            ("EventStore", #"static let productionDirectoryName = "EventStore""#,
             "Done/Services/Storage/EventStorageLocation.swift"),
            ("EventStore-TestHost", #"static let testHostDirectoryName = "EventStore-TestHost""#,
             "Done/Services/Storage/EventStorageLocation.swift"),
            ("AgentChat", #"static let productionDirectoryName = "AgentChat""#,
             "Done/Services/Agent/AgentConversationRepository.swift"),
            ("conversations.json", #"static let conversationsFilename = "conversations.json""#,
             "Done/Services/Agent/AgentConversationRepository.swift"),
            ("conversations.log", #"static let logFilename = "conversations.log""#,
             "Done/Services/Agent/AgentConversationRepository.swift"),
            ("spike-runs", #"? "spike-runs-test-host" : "spike-runs""#,
             "Done/Services/SpikeRunStore.swift"),
            ("backup-snapshot.json", #"static let snapshotFilename = "backup-snapshot.json""#,
             "Done/Services/BackupSnapshotService.swift"),
            ("templates.json", #"static let templatesFilename = "templates.json""#,
             "Done/Models/EventTypeTemplateStore.swift"),
            ("colorHistory.json", #"static let colorHistoryFilename = "colorHistory.json""#,
             "Done/Models/EventTypeTemplateStore.swift"),
            ("referenceTimeZone.json",
             #"static let referenceTimeZoneFilename = "referenceTimeZone.json""#,
             "Done/Services/Storage/OccurrenceKeyMetadataStore.swift"),
            ("manifest.json", #"url("manifest.json")"#,
             "Done/Services/Storage/DurableEventStorage.swift"),
            ("domino.json", #"url("domino.json")"#,
             "Done/Services/Storage/DurableEventStorage.swift"),
        ]
        for entry in invisible {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(entry.inFile), encoding: .utf8)
            XCTAssertTrue(
                source.contains(entry.declaredAs),
                "\(entry.inFile) no longer declares \(entry.declaredAs) — this list has rotted, "
                + "re-derive it before trusting either half"
            )
            XCTAssertFalse(
                found.contains(entry.name),
                "\(entry.name) is now visible to the census — good. Remove it from this list."
            )
        }

        // The slot files are not even named by a constant: they are DERIVED,
        // so no literal exists anywhere for a literal scanner to find.
        let slotSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/Services/Storage/StorageSlot.swift"),
            encoding: .utf8)
        XCTAssertTrue(slotSource.contains(#"var filename: String { rawValue + ".json" }"#),
                      "every durable slot file name is derived from the slot's rawValue, so the "
                      + "events / people / todoLists / log files have no literal to scan for")
        for slot in StorageSlot.allCases {
            XCTAssertFalse(found.contains(slot.filename),
                           "\(slot.filename) is now visible to the census — good, update this test")
            XCTAssertFalse(found.contains(slot.backupFilename),
                           "\(slot.backupFilename) is now visible to the census")
        }
    }

    /// Keying the census on the LITERAL collapses two different directories
    /// that share a name into one disposition.
    ///
    /// `Diagnostics` is declared `sweptByErase("DiagnosticTrail.clear()")`.
    /// There are TWO `Diagnostics` directories in production: the trail's,
    /// under Application Support — which `clear()` does reach — and
    /// `MetricPayloadStore`'s `legacyDirectory` under `Documents/`, the
    /// pre-gh#219 unbounded MetricKit pile, which nothing on the erase path
    /// touches. One disposition is recorded for both.
    func testTheDiagnosticsLiteralNamesTwoDifferentDirectories() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let trail = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/Services/DiagnosticTrail.swift"),
            encoding: .utf8)
        XCTAssertTrue(trail.contains(#"base.appendingPathComponent("Diagnostics", isDirectory: true)"#),
                      "the trail's Diagnostics directory")
        let metrics = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Done/Services/Storage/MetricPayloadStore.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            metrics.contains(#"legacyDirectory: docs.appendingPathComponent("Diagnostics", isDirectory: true)"#),
            "a SECOND Diagnostics directory, under Documents/, holding raw MetricKit payload "
            + "JSON. The census sees one literal and records one disposition for both; nothing "
            + "on the erase path removes this one."
        )
        // `appSupport` for the trail, `docs` for the legacy pile: different roots.
        XCTAssertTrue(metrics.contains("let docs = FileManager.default.urls(for: .documentDirectory"),
                      "and they are rooted in different directories, so they are not the same place")
    }

    /// `appendingPathExtension` is a path-building idiom the census does not
    /// scan at all, and one production site uses it to name a file the
    /// inventory does not declare.
    func testTheRotatedDebugLogNameIsBuiltByAnUnscannedIdiom() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/Services/Agent/AgentService.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            source.contains(#"appendingPathExtension("old.log")"#),
            "AgentRuntime/agent_decision_debug.old.log is created by appendingPathExtension, "
            + "which the census does not scan. DEBUG-only like its sibling, which the inventory "
            + "DOES declare — the point is the idiom, not this file."
        )
    }

    /// The inventory declares `AgentRuntime` as `sweptByErase` via
    /// `clearRules() + clearDecisionHistory()`. Those two write `[]` through
    /// `saveJSON`; neither removes a file, let alone the directory. The
    /// content claim holds, the directory-level wording does not.
    func testTheAgentRuntimeSweepEmptiesTwoFilesAndRemovesNothing() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/Services/Agent/AgentService.swift"),
            encoding: .utf8)
        for (declaration, body) in [("func clearRules() {", "saveRules()"),
                                    ("func clearDecisionHistory() {", "saveDecisions()")] {
            let start = try XCTUnwrap(source.range(of: declaration))
            let end = try XCTUnwrap(source.range(of: "\n    }\n",
                                                 range: start.upperBound..<source.endIndex))
            let extracted = String(source[start.upperBound..<end.lowerBound])
            XCTAssertTrue(extracted.contains(body), "liveness: the extracted body must be the real one")
            XCTAssertFalse(extracted.contains("removeItem"),
                           "\(declaration) overwrites with an empty array; it removes no file. "
                           + "The AgentRuntime directory survives the erase.")
        }
    }

    // MARK: - Fixtures

    private func event(_ title: String, kind: Event.Kind = .event) -> Event {
        let start = Date().addingTimeInterval(3600)
        return Event(title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: kind)
    }

    private func makeSpikeRun(spikeID: String) -> SpikeRun {
        SpikeRun(
            id: UUID(), spikeID: spikeID, scenarioID: "sc", variantID: nil,
            startedAt: Date(), endedAt: nil,
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone99,1", osVersion: "99.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            metrics: [:], note: nil, outcome: nil, abortReason: nil
        )
    }

    private func makeReport(userNote: String) -> Report {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let stats = ReportStatsBuilder.build(
            events: [], start: start, end: start.addingTimeInterval(7 * 86_400),
            calendar: calendar)
        return Report(
            id: UUID(), createdAt: start,
            periodStart: start, periodEnd: start.addingTimeInterval(7 * 86_400),
            prose: "qa witness prose", statsSnapshot: stats,
            providerModel: "qa-model", comparedToPreviousWindow: false,
            userNote: userNote, schemaVersion: Report.currentSchemaVersion
        )
    }
}
