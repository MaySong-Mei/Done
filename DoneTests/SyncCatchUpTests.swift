//
//  SyncCatchUpTests.swift
//  DoneTests
//
//  Design §6.6 (v1.6) replayed over `SyncFakeServer`: the epoch check on
//  every page, the reset at the chain boundary, the catch-up pre-rules,
//  rule-4 re-uploads, the one recovery prompt (ancestry first, the ledger
//  when ancestry is unknown), the write-back's lease and keep-both, the
//  write gate, the tripwire, the feed-unavailable fallback and the upgrade
//  path. One or two virtual devices, each an `EventStore` + engine +
//  puller over its own storage, defaults and shelf; one server.
//
//  Every expected hash is taken through the pusher's projection
//  (`service.eventToRow`), never through anything the applier computed.
//

import XCTest
@testable import Done

@MainActor
final class SyncCatchUpTests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let uid = "55555555-5555-5555-5555-555555555555"
    private var server: SyncFakeServer!
    private var devices: [Device] = []

    final class Device {
        let name: String
        let suite: String
        let defaults: UserDefaults
        let store: EventStore
        let service: SupabaseSyncService
        let puller: SyncPuller
        let shelf: ConflictShelf
        let shelfDirectory: URL

        init(name: String, suite: String, defaults: UserDefaults, store: EventStore, service: SupabaseSyncService,
             puller: SyncPuller, shelf: ConflictShelf, shelfDirectory: URL) {
            self.name = name
            self.suite = suite
            self.defaults = defaults
            self.store = store
            self.service = service
            self.puller = puller
            self.shelf = shelf
            self.shelfDirectory = shelfDirectory
        }
    }

    override func setUp() {
        super.setUp()
        server = SyncFakeServer(userId: uid)
    }

    override func tearDown() {
        for device in devices {
            device.puller.endSession()
            try? FileManager.default.removeItem(at: device.shelfDirectory)
            TestStorage.tearDown(device.suite)
        }
        devices = []
        server = nil
        super.tearDown()
    }

    // MARK: - Devices

    /// A device over the shared server. `shelfDirectory` / `suite` let a
    /// relaunch reuse an earlier device's disk. Only the foreground test
    /// lets the puller observe the real foreground notification: the test
    /// host may receive one mid-run, and every other test must not get a
    /// chain it did not trigger.
    private func makeDevice(_ name: String, suite: String? = nil, shelfDirectory: URL? = nil,
                            observesForeground: Bool = false) -> Device {
        let suiteName = suite ?? "SyncCatchUpTests-\(name)-\(UUID().uuidString)"
        let location: EventStorageLocation
        if suite == nil {
            location = TestStorage.reset(suiteName)
        } else {
            location = EventStorageLocation.isolated(name: suiteName)
        }
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        let service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: defaults, scheduler: SyncManualScheduler())
        service.attachStores(eventStore: store, eventTypeStore: nil, skillStore: nil, preferenceStore: nil)
        let directory = shelfDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncCatchUpTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        let shelf = ConflictShelf(directory: directory)
        let puller = service.installInbound(shelf: shelf)
        puller.observesForeground = observesForeground
        puller.headFlag = SyncHeadFlag()
        puller.beginSession(autoPull: false)
        let device = Device(name: name, suite: suiteName, defaults: defaults, store: store, service: service,
                            puller: puller, shelf: shelf, shelfDirectory: directory)
        devices.append(device)
        return device
    }

    // MARK: - Fixtures

    private func makeEvent(_ title: String, note: String) -> Event {
        Event(title: title, note: note,
              timeRanges: [.init(start: Self.t0, end: Self.t0.addingTimeInterval(1800))],
              createdAt: Self.t0)
    }

    @discardableResult
    private func create(_ device: Device, _ title: String, note: String) -> Event {
        let event = makeEvent(title, note: note)
        device.store.addCalendarEvent(event)
        return local(device, event)!
    }

    private func local(_ device: Device, _ event: Event) -> Event? {
        device.store.rawCalendarEvents.first { $0.id == event.id }
    }

    private func localNote(_ device: Device, _ event: Event) -> String? {
        local(device, event)?.note
    }

    private func edit(_ device: Device, _ event: Event, note: String) {
        var copy = local(device, event)!
        copy.note = note
        device.store.updateCalendarEvent(copy)
    }

    private func flush(_ device: Device) async {
        await device.service.syncEvents(device.store.rawCalendarEvents, kind: "calendar")
    }

    private func pull(_ device: Device, reason: String = "test") async {
        await device.puller.pullToHead(reason: reason)
    }

    private func entry(_ device: Device, _ event: Event) -> SyncBaselineEntry? {
        device.service.baseline.entry(table: "calendar_events", id: event.id.uuidString)
    }

    private func serverNote(_ event: Event) -> String? {
        server.row(table: "events", key: event.id.uuidString)?.data["note"] as? String
    }

    private func serverVid(_ event: Event) -> String? {
        server.versionId(table: "events", key: event.id.uuidString)
    }

    private func agentEdit(_ event: Event, note: String) throws {
        try server.agentWrite(table: "events", key: event.id.uuidString, data: ["note": note])
    }

    private func shelfLines(_ device: Device, _ event: Event, reason: String? = nil) -> [ConflictShelfEntry] {
        device.shelf.entries().filter { $0.id == event.id.uuidString && (reason == nil || $0.reason == reason) }
    }

    private func trailCount(_ needle: String) -> Int {
        DiagnosticTrail.combinedText().components(separatedBy: needle).count - 1
    }

    /// X created on A, pushed, pulled to head on every device given: every
    /// device clean at X@1 under epoch e0.
    private func seedX(on a: Device, also others: [Device] = []) async -> Event {
        let x = create(a, "X", note: "c0")
        await flush(a)
        await pull(a)
        for device in others { await pull(device) }
        return x
    }

    // MARK: - One-row tables stay out of the prompt (sim QA round 2 #3)

    /// A catch-up shelves the device's own unconfirmed edit of X and of the
    /// three one-row tables. Only X is offered, counted and listed; the
    /// one-row lines stay on the shelf unmarked. A line for one of them
    /// already marked offered by an earlier build is not counted either.
    /// The "one-row tables still counted" mutant offers four.
    func testOneRowTablesAreNeitherOfferedNorCounted_killsSingletonsCounted() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let singletons = [SyncBaselineStore.settingsTable, "agent_preferences", "agent_conversations"]
        XCTAssertTrue(a.shelf.append(ConflictShelfEntry(uid: uid, table: "calendar_events", id: x.id.uuidString, seq: 7,
                                                        reason: .catchup, row: ["title": "X"], localClean: false, catchup: true)))
        for table in singletons {
            XCTAssertTrue(SupabaseSyncService.isSingletonTable(table), "fixture: \(table) is a one-row table")
            XCTAssertTrue(a.shelf.append(ConflictShelfEntry(uid: uid, table: table, id: uid, seq: 8,
                                                            reason: .catchup, row: ["user_id": uid], localClean: false, catchup: true)))
        }

        let prompt = try XCTUnwrap(await a.puller.recovery.computeOffers())

        XCTAssertEqual(prompt.count, 1)
        XCTAssertEqual(prompt.items.map(\.table), ["calendar_events"])
        XCTAssertFalse(prompt.items.contains { $0.title == uid }, "no row titled with the user UUID")
        XCTAssertEqual(a.service.pendingPromptCount, 1)
        for table in singletons {
            let line = try XCTUnwrap(a.shelf.entries().first { $0.table == table })
            XCTAssertFalse(line.offered, "\(table): kept on the shelf, not offered")
        }

        // A one-row line an earlier build already marked offered.
        XCTAssertTrue(a.shelf.append(ConflictShelfEntry(uid: uid, table: "agent_preferences", id: uid, seq: 9,
                                                        reason: .catchup, row: ["user_id": uid], localClean: false,
                                                        catchup: true, offered: true)))
        a.puller.recovery.refreshBadge()
        XCTAssertEqual(a.service.pendingPromptCount, 1)
        XCTAssertEqual(a.puller.recovery.buildPrompt().items.map(\.table), ["calendar_events"])
    }

    // MARK: - hiddenAfterRestore (§6.6 测试, model `hiddenAfterRestore`)

    /// A pushed c_a after the dump; the restore lost it; an agent edited
    /// the restored row. A's catch-up adopts the agent's version, shelves
    /// c_a, and the prompt offers it: `is_ancestor(v_a, v_agent)` is false.
    func testHiddenAfterRestore_shelvesTheLostVersionAndOffersIt() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        XCTAssertEqual(serverNote(x), "c_a")
        let vA = try XCTUnwrap(entry(a, x)?.vid)
        let promptsBefore = trailCount("sync.restore.prompt ")
        let epochChangesBefore = trailCount("sync.epoch.changed ")
        let resetsBefore = trailCount("sync.reset reason=epoch")

        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")

        await pull(a)

        XCTAssertEqual(localNote(a, x), "c_agent", "server authoritative: the restored timeline's version is adopted")
        let lines = shelfLines(a, x, reason: "catchup")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.row["note"] as? String, "c_a", "the lost version is on the shelf, whole")
        XCTAssertEqual(lines.first?.localVid, vA)
        XCTAssertEqual(lines.first?.localClean, true)
        XCTAssertEqual(lines.first?.offered, true)
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1)
        XCTAssertEqual(a.service.pendingPromptCount, 1)
        XCTAssertTrue(a.service.hasUndecidedOffers)
        XCTAssertEqual(trailCount("sync.restore.prompt ") - promptsBefore, 1)
        XCTAssertEqual(trailCount("sync.epoch.changed ") - epochChangesBefore, 1)
        XCTAssertEqual(trailCount("sync.reset reason=epoch") - resetsBefore, 1)
        XCTAssertGreaterThan(trailCount("sync.catchup.shelved table=calendar_events id=\(x.id.uuidString)"), 0)
        XCTAssertEqual(entry(a, x)?.stale, false)
        XCTAssertEqual(a.service.cursor.epoch, server.epochString)
    }

    /// The same, with the version log unable to answer (the 90-day
    /// cleanup): the ledger decides — the copy is clean and its seq is past
    /// the kept_max the restore recorded. The "no ledger" mutant hides it.
    func testHiddenAfterRestore_unknownAncestryFallsBackToTheLedger_killsNoLedger() async throws {
        server.ancestryUnknownWhen = { _, _, _, _ in true }
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        XCTAssertEqual(entry(a, x)?.seq, 2)

        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")
        let unknownBefore = trailCount("sync.ancestry unknown=")

        await pull(a)

        XCTAssertEqual(a.service.cursor.kmin, 1, "the ledger's only record kept everything up to X@1")
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.offered, true,
                       "clean copy at seq 2 > kmin 1: pushed after the kept number and lost")
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1)
        XCTAssertGreaterThan(trailCount("sync.ancestry unknown=") - unknownBefore, 0)
    }

    // MARK: - rollbackRestore

    /// During a rollback an agent edits X (new seq, same version id); after
    /// re-enabling, A adopts it (its own copy is the row's ancestor: not
    /// offered). Then the pre-rollback dump is restored: the agent's
    /// version lands on the shelf — nowhere else, but not lost.
    func testRollbackRestore_agentVersionSurvivesOnTheShelf() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        let v0 = try XCTUnwrap(serverVid(x))

        server.rollbackTriggers()
        try agentEdit(x, note: "c_agent")
        XCTAssertEqual(serverVid(x), v0, "rollback: the stamp-only trigger keeps the version id")
        XCTAssertEqual(server.seq(table: "events", key: x.id.uuidString), 2, "and takes a new seq")
        server.reenable()
        server.unpause()

        await pull(a)
        XCTAssertEqual(localNote(a, x), "c_agent")
        XCTAssertNil(a.service.recoveryPrompt, "the local copy is the live row's own version: an ancestor, not offered")

        server.restoreFromDump(dump)
        server.unpause()
        await pull(a)

        XCTAssertEqual(localNote(a, x), "c0")
        XCTAssertTrue(a.shelf.entries().contains { $0.row["note"] as? String == "c_agent" },
                      "the agent's version is on the shelf")
        XCTAssertNil(a.service.recoveryPrompt)
    }

    // MARK: - t1: rollback + re-enable between two restores (ledger min)

    /// Two ledger records after the device's epoch: the restore (kept 1)
    /// and the re-enable (kept 3). The copy at seq 2 is lost only against
    /// the MIN; reading the last record hides it.
    func testT1_ledgerMinOverRecordsAfterTheOldEpoch_killsLedgerLast() async throws {
        server.ancestryUnknownWhen = { _, _, _, _ in true }
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        XCTAssertEqual(entry(a, x)?.seq, 2)

        server.restoreFromDump(dump)
        server.rollbackTriggers()
        try agentEdit(x, note: "c_agent")
        server.reenable()
        server.unpause()
        XCTAssertEqual(server.restores.map(\.keptMax), [1, 3])

        await pull(a)

        XCTAssertEqual(a.service.cursor.kmin, 1)
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.offered, true)
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1)
    }

    // MARK: - anchorGap: the first reset's chain abandoned while paused

    /// The first reset (kmin 1) is followed by a chain the paused bit
    /// abandons, so the entries stay stale; the next epoch step's records
    /// alone give 3. Carrying min(1, 3) across the two resets is what
    /// keeps the copy at seq 2 offered.
    func testAnchorGap_kminCarriesAcrossResets_killsNoMinCarry() async throws {
        server.ancestryUnknownWhen = { _, _, _, _ in true }
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)

        server.restoreFromDump(dump)
        XCTAssertTrue(server.paused)
        await pull(a)
        XCTAssertEqual(a.service.cursor.kmin, 1, "first reset: the only record")
        XCTAssertTrue(a.service.baseline.hasStaleEntries, "paused: the chain was abandoned, nothing caught up")
        XCTAssertEqual(localNote(a, x), "c_a", "nothing applied under paused")
        XCTAssertGreaterThan(trailCount("sync.paused"), 0)

        server.rollbackTriggers()
        try agentEdit(x, note: "c_agent")
        server.reenable()
        server.unpause()
        XCTAssertEqual(server.restores.map(\.keptMax), [1, 3])

        await pull(a)

        XCTAssertEqual(a.service.cursor.kmin, 1, "min(previous 1, fresh 3)")
        XCTAssertEqual(localNote(a, x), "c_agent")
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.offered, true)
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1)
    }

    // MARK: - t2 / keep both

    /// Both devices held c_a; the restore lost it; an agent edited the
    /// restored row. A writes c_a back: the overwritten agent version is
    /// shelved on A first, so after B pulls c_a it is still somewhere.
    func testWriteBack_keepsTheOverwrittenLiveVersion_killsNoKeepBoth() async throws {
        let a = makeDevice("A")
        let b = makeDevice("B")
        let x = await seedX(on: a, also: [b])
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        await pull(b)
        XCTAssertEqual(localNote(b, x), "c_a")

        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")
        await pull(a)
        await pull(b)
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1)
        XCTAssertEqual(b.service.recoveryPrompt?.count, 1)

        let result = await a.puller.recovery.accept()

        XCTAssertEqual(result, SyncRecoveryWriteBack(accepted: 1, leaseFailed: 0))
        XCTAssertEqual(serverNote(x), "c_a")
        XCTAssertEqual(localNote(a, x), "c_a", "the written-back version is applied locally")
        XCTAssertNil(a.service.recoveryPrompt)
        XCTAssertFalse(a.service.hasUndecidedOffers)
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.resolution, "accepted")
        XCTAssertGreaterThan(trailCount("sync.restore.accept k=1 m=0"), 0)
        let restoredFrom = server.versions(table: "events", key: x.id.uuidString).last?.restoredFromVersionId
        XCTAssertNotNil(restoredFrom, "the write-back names the copy it restored")

        await pull(b)
        XCTAssertEqual(localNote(b, x), "c_a")
        let everywhere = [a, b].flatMap { $0.shelf.entries() }
        XCTAssertTrue(everywhere.contains { $0.row["note"] as? String == "c_agent" && $0.reason == "restore_overwritten" },
                      "keep both: the agent's version, overwritten by the write-back, is on A's shelf")
    }

    // MARK: - doubleAccept: the second write-back's lease fails

    /// A's copy c_a (confirmed) and B's copy c_b (never pushed) both lost;
    /// A writes back first; B caught up again in between (its baseline
    /// moved to A's write) and still writes on its original lease — 0
    /// rows, lease failed, A's version stays. Refreshing the lease would
    /// let B overwrite A.
    func testDoubleAccept_secondWriteBackFailsItsLease_killsUnconditionalWriteBack() async throws {
        let a = makeDevice("A")
        let b = makeDevice("B")
        let x = await seedX(on: a, also: [b])
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        edit(b, x, note: "c_b")

        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")
        await pull(a)
        await pull(b)
        XCTAssertEqual(localNote(b, x), "c_agent", "B's unpushed edit lost to the restored timeline")
        XCTAssertEqual(shelfLines(b, x, reason: "catchup").first?.localClean, false, "B's own unconfirmed edit")
        XCTAssertEqual(b.service.recoveryPrompt?.count, 1)

        let first = await a.puller.recovery.accept()
        XCTAssertEqual(first.accepted, 1)
        XCTAssertEqual(serverNote(x), "c_a")

        // B catches up with A's write-back before deciding (稍后, days later).
        b.puller.recovery.later()
        await pull(b)
        XCTAssertEqual(localNote(b, x), "c_a")
        XCTAssertEqual(b.service.pendingPromptCount, 1, "the badge survives the catch-up")

        let second = await b.puller.recovery.accept()

        XCTAssertEqual(second, SyncRecoveryWriteBack(accepted: 0, leaseFailed: 1))
        XCTAssertEqual(serverNote(x), "c_a", "the lease was never refreshed: B does not overwrite A")
        XCTAssertEqual(shelfLines(b, x, reason: "catchup").first?.resolution, "lease_failed")
        XCTAssertEqual(shelfLines(b, x, reason: "catchup").first?.row["note"] as? String, "c_b", "c_b stays on B's shelf")
        XCTAssertGreaterThan(trailCount("sync.restore.lease_failed table=calendar_events id=\(x.id.uuidString)"), 0)
        XCTAssertGreaterThan(trailCount("sync.restore.accept k=0 m=1"), 0)
    }

    // MARK: - γ: v2 lands first, v3 is offered and written back on top

    func testGammaShape_laterVersionOfferedAfterTheEarlierOneLands() async throws {
        let a = makeDevice("A")
        let b = makeDevice("B")
        let x = await seedX(on: a, also: [b])
        let dump = server.dump()
        edit(a, x, note: "v2")
        await flush(a)
        await pull(b)
        edit(b, x, note: "v3")
        await flush(b)
        XCTAssertEqual(serverNote(x), "v3")

        server.restoreFromDump(dump)
        server.unpause()
        await pull(a)
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1)
        _ = await a.puller.recovery.accept()
        XCTAssertEqual(serverNote(x), "v2")

        await pull(b)

        XCTAssertEqual(localNote(b, x), "v2")
        XCTAssertEqual(b.service.recoveryPrompt?.count, 1, "v3 is not an ancestor of the live v2: offered")
        let result = await b.puller.recovery.accept()
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(serverNote(x), "v3")
        XCTAssertTrue(b.shelf.entries().contains { $0.reason == "restore_overwritten" && $0.row["note"] as? String == "v2" })
    }

    // MARK: - The write gate

    /// A PATCH built under the old epoch is held, the server is restored,
    /// the PATCH is released: the gate refuses it (`sync_epoch_stale`), the
    /// `?` stays, the chain resets and the edit goes out on the new epoch.
    /// Without the header the PATCH lands blind on the restored row.
    func testWriteGate_inFlightPatchAfterEpochChangeIsRefused_killsNoHeader() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        edit(a, x, note: "c_a")

        server.holdWhen = { verb, _ in verb == .patch }
        let flushTask = Task { await self.flush(a) }
        try await syncEventually("PATCH held") { self.server.heldCount == 1 }
        server.restoreFromDump(dump)
        server.unpause()
        // The refusal asks the puller for a chain; park that chain's pull so
        // the state right after the refusal can be read.
        server.holdWhen = { verb, _ in verb == .pull }
        server.releaseAll()
        await flushTask.value

        XCTAssertEqual(server.requests(.patch).last?.epochHeader, dump.epoch.uuidString, "the request carried the old epoch")
        XCTAssertEqual(serverNote(x), "c0", "refused by the gate: no blind overwrite")
        XCTAssertEqual(entry(a, x), .unknown(seq: 1), "the `?` the send wrote stays")
        XCTAssertGreaterThan(trailCount("sync.push.gate_rejected reason=stale"), 0)
        XCTAssertEqual(server.versions(table: "events", key: x.id.uuidString).count, 1, "the refused write minted no version")

        try await syncEventually("the gate-triggered chain parked") { self.server.heldCount == 1 }
        server.holdWhen = nil
        server.releaseAll()
        await pull(a)
        XCTAssertEqual(localNote(a, x), "c_a", "the restored row is the version the edit started from: kept")
        XCTAssertGreaterThan(trailCount("sync.catchup.kept_origin table=calendar_events id=\(x.id.uuidString)"), 0)
        XCTAssertEqual(serverNote(x), "c_a", "the flush the head owed carried the edit under the new epoch")
        XCTAssertEqual(server.requests(.patch).last?.epochHeader, server.epochString)
    }

    /// `paused` alone: the device's PATCH is refused with `sync_paused` and
    /// flagged for the next head; a header-less (service_role) write is
    /// refused too — except during a rollback, where it lands with a new
    /// seq and the same version id.
    func testPaused_clientWriteRefused_agentWriteRefusedUnlessRollingBack() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let v0 = try XCTUnwrap(serverVid(x))
        server.pause()

        edit(a, x, note: "c_a")
        await flush(a)
        XCTAssertEqual(serverNote(x), "c0")
        XCTAssertGreaterThan(trailCount("sync.push.gate_rejected reason=paused"), 0)
        XCTAssertTrue(a.service.needsFlush.contains("calendar_events"))
        XCTAssertEqual(entry(a, x), .unknown(seq: 1))
        XCTAssertTrue(a.service.rejected.isEmpty, "the sixth class is not a rejection")

        XCTAssertThrowsError(try agentEdit(x, note: "agent-while-paused"))
        XCTAssertEqual(serverNote(x), "c0")

        server.rollbackTriggers()
        try agentEdit(x, note: "agent-in-rollback")
        XCTAssertEqual(serverNote(x), "agent-in-rollback")
        XCTAssertEqual(server.seq(table: "events", key: x.id.uuidString), 2, "took a new seq")
        XCTAssertEqual(serverVid(x), v0, "kept its version id")
    }

    // MARK: - Re-upload after a restore (rule 4) with the baseline's parent

    func testRowsCreatedAfterTheDumpAreReuploadedWithTheirParentVersion() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        let y = create(a, "Y", note: "d0")
        await flush(a)
        await pull(a)
        let vY = try XCTUnwrap(entry(a, y)?.vid)

        server.restoreFromDump(dump)
        server.unpause()
        XCTAssertNil(server.row(table: "events", key: y.id.uuidString))

        await pull(a)

        XCTAssertEqual(serverNote(y), "d0", "re-uploaded at head")
        XCTAssertEqual(server.versions(table: "events", key: y.id.uuidString).last?.parentVersionId, vY,
                       "the POST named the version the baseline held")
        XCTAssertEqual(server.requests(.insert).last?.epochHeader, server.epochString)
        XCTAssertEqual(entry(a, y)?.stale, false)
        XCTAssertNotNil(entry(a, y)?.seq)
        XCTAssertEqual(localNote(a, x), "c0")
        XCTAssertNil(a.service.recoveryPrompt)
        XCTAssertGreaterThan(trailCount("sync.catchup.reupload table=calendar_events id=\(y.id.uuidString)"), 0)
        XCTAssertTrue(a.service.reuploadParents.isEmpty)
    }

    /// Rule 3's second half: a row the device deleted (tombstone not yet
    /// sent) that the restored server no longer holds becomes a dead-row
    /// insert, so a peer's later re-upload meets a tombstone.
    func testDeletedRowMissingFromTheRestoreIsInsertedDead() async throws {
        let a = makeDevice("A")
        _ = await seedX(on: a)
        let dump = server.dump()
        let y = create(a, "Y", note: "d0")
        await flush(a)
        await pull(a)
        a.store.deleteCalendarEvent(local(a, y)!)
        XCTAssertNil(local(a, y))

        server.restoreFromDump(dump)
        server.unpause()
        await pull(a)

        XCTAssertTrue(server.isTombstoned(table: "events", key: y.id.uuidString))
        XCTAssertNil(entry(a, y))
        XCTAssertGreaterThan(trailCount("sync.catchup.dead_insert table=calendar_events id=\(y.id.uuidString)"), 0)
    }

    /// Rule 3's first half: a pending local delete meets the restored
    /// row's new version — the incoming version is shelved, the row stays
    /// absent, and the tombstone goes out.
    func testPendingDeleteWinsOverTheRestoredTimeline() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        a.store.deleteCalendarEvent(local(a, x)!)

        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")
        await pull(a)

        XCTAssertNil(local(a, x))
        XCTAssertEqual(shelfLines(a, x, reason: "pending_delete").first?.row["note"] as? String, "c_agent")
        await flush(a)
        XCTAssertTrue(server.isTombstoned(table: "events", key: x.id.uuidString))
    }

    // MARK: - restoreEditRestore: origin fast-forward through the version log

    func testEditOnTopOfAWriteBackSurvivesASecondRestoreByAncestry() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")
        await pull(a)
        _ = await a.puller.recovery.accept()
        XCTAssertEqual(serverNote(x), "c_a")
        XCTAssertEqual(localNote(a, x), "c_a")

        edit(a, x, note: "c_a2")
        server.restoreFromDump(dump)
        server.unpause()
        await pull(a)

        XCTAssertEqual(localNote(a, x), "c_a2", "the restored row is an ancestor of the edit's origin: kept")
        XCTAssertGreaterThan(trailCount("sync.catchup.kept_origin table=calendar_events id=\(x.id.uuidString)"), 0)
        XCTAssertNil(a.service.recoveryPrompt)
        await flush(a)
        XCTAssertEqual(serverNote(x), "c_a2")
    }

    // MARK: - Three hops: the copy is an ancestor, not offered

    func testThreeHopChain_copyIsAnAncestorOverThreeHops_notOffered() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        edit(a, x, note: "c1")
        await flush(a)
        await pull(a)
        let dump = server.dump()
        server.restoreFromDump(dump)
        server.unpause()
        for note in ["h1", "h2", "h3"] { try agentEdit(x, note: note) }

        await pull(a)

        XCTAssertEqual(localNote(a, x), "h3")
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").count, 1, "server authoritative: the copy is shelved")
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.offered, false, "three hops up reaches the copy")
        XCTAssertNil(a.service.recoveryPrompt)
    }

    // MARK: - A lagging device adopts the pre-dump edit, nothing offered

    func testLaggingDeviceAdoptsThePreDumpEditWithoutAnOffer() async throws {
        let a = makeDevice("A")
        let b = makeDevice("B")
        let x = await seedX(on: a, also: [b])
        edit(a, x, note: "c_a")
        await flush(a)
        let dump = server.dump()
        edit(a, x, note: "c_a2")
        await flush(a)

        server.restoreFromDump(dump)
        server.unpause()
        await pull(b)

        XCTAssertEqual(localNote(b, x), "c_a")
        XCTAssertNil(b.service.recoveryPrompt, "B's copy c0 is the ancestor of c_a")
        XCTAssertEqual(b.service.pendingPromptCount, 0)
    }

    // MARK: - v1.5 leftovers

    /// An online device whose first page after the restore is empty
    /// still reads the epoch after it.
    func testEmptyPageIsFollowedByTheEpochRead() async throws {
        let a = makeDevice("A")
        _ = await seedX(on: a)
        let dump = server.dump()
        let before = trailCount("sync.epoch.changed ")
        server.restoreFromDump(dump)
        server.unpause()

        await pull(a)

        XCTAssertEqual(trailCount("sync.epoch.changed ") - before, 1)
        XCTAssertEqual(a.service.cursor.epoch, server.epochString)
        XCTAssertEqual(a.service.cursor.value, 1)
    }

    /// A page fetched before the restore and delivered after it: the epoch
    /// read behind it sees the change, the page is not applied and the
    /// cursor is not written by it.
    func testHeldOldChainPageIsNotAppliedAfterTheReset() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        try agentEdit(x, note: "c1")

        let orphansBefore = trailCount("sync.push.orphan")
        server.holdResponseWhen = { verb, _ in verb == .pull }
        let chain = Task { await self.pull(a) }
        try await syncEventually("page parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        server.restoreFromDump(dump)
        server.unpause()
        server.releaseAllResponses()
        await chain.value

        XCTAssertEqual(localNote(a, x), "c0", "the parked page carried c1@2 and was never applied")
        XCTAssertEqual(a.service.cursor.value, 1)
        XCTAssertTrue(a.shelf.entries().isEmpty)
        XCTAssertEqual(trailCount("sync.push.orphan") - orphansBefore, 0)
    }

    /// S11 for the reset: the cursor key landed, a table key did not. The
    /// next launch finds the table under the old epoch, re-marks it stale
    /// and drops the cursor.
    func testTableKeyLostAfterTheResetIsRemarkedStaleAtLoad() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let key = "syncHashes.\(uid).calendar_events"
        let beforeReset = a.defaults.object(forKey: key)
        SyncCatchUp.reset(engine: a.service, newEpoch: "e-next", ledger: [])
        XCTAssertEqual(entry(a, x)?.stale, true)

        a.defaults.set(beforeReset, forKey: key)
        let relaunched = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: a.defaults)

        XCTAssertEqual(relaunched.baseline.entry(table: "calendar_events", id: x.id.uuidString)?.stale, true)
        XCTAssertNil(relaunched.cursor.value)
        XCTAssertEqual(relaunched.cursor.epoch, "e-next")
        XCTAssertEqual(relaunched.baseline.epoch(of: "calendar_events"), "e-next")
    }

    // MARK: - Upgrade path

    func testPreV16BaselineShapesStillReadAndGainTheMarkerOnReset() throws {
        let suite = "SyncCatchUpTests-upgrade-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(["A": "abc@3", "B": "def"]), forKey: "syncHashes.\(uid).calendar_events")
        defaults.set("p@2#1", forKey: "syncHashes.\(uid).agent_preferences")
        defaults.set("{\"cursor\":3,\"gen\":{\"agent_preferences\":1}}", forKey: "syncHashes.\(uid).cursor")

        let baseline = SyncBaselineStore(defaults: defaults, userId: uid)
        let cursor = SyncCursorStore(defaults: defaults, userId: uid)
        XCTAssertEqual(baseline.entry(table: "calendar_events", id: "A"), SyncBaselineEntry(hash: "abc", seq: 3))
        XCTAssertEqual(baseline.entry(table: "calendar_events", id: "B"), SyncBaselineEntry(hash: "def", seq: nil))
        XCTAssertNil(baseline.entry(table: "calendar_events", id: "A")?.vid)
        XCTAssertEqual(cursor.value, 3)
        XCTAssertNil(cursor.epoch, "no epoch yet: the first read records it and resets nothing")
        XCTAssertTrue(cursor.validate(against: baseline).isEmpty)

        cursor.reset(newEpoch: "e1", kmin: 7, baseline: baseline)

        let reloaded = SyncBaselineStore(defaults: defaults, userId: uid)
        XCTAssertEqual(reloaded.entry(table: "calendar_events", id: "A"), SyncBaselineEntry(hash: "abc", seq: 3, stale: true))
        XCTAssertEqual(reloaded.entry(table: "calendar_events", id: "B"), SyncBaselineEntry(hash: "def", seq: nil, stale: true))
        XCTAssertEqual(reloaded.entry(table: "agent_preferences", id: uid), SyncBaselineEntry(hash: "p", seq: 2, stale: true))
        XCTAssertEqual(reloaded.epoch(of: "calendar_events"), "e1")
        let reloadedCursor = SyncCursorStore(defaults: defaults, userId: uid)
        XCTAssertNil(reloadedCursor.value)
        XCTAssertEqual(reloadedCursor.epoch, "e1")
        XCTAssertEqual(reloadedCursor.kmin, 7)
        XCTAssertTrue(reloadedCursor.validate(against: reloaded).isEmpty)
    }

    func testEntryEncodingRoundTripsVersionIdAndMarker() {
        let vid = "5b0f0a1e-9f5c-4c2d-8e7a-3a1f2c4d5e6f"
        let entry = SyncBaselineEntry(hash: "abc", seq: 9, vid: vid, stale: true)
        XCTAssertEqual(entry.encoded, "~abc@9#\(vid)")
        let decoded = SyncBaselineEntry(encoded: entry.encoded)
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded?.vid, vid)
        XCTAssertEqual(SyncBaselineEntry(encoded: "?@5")?.encoded, "?@5")
        XCTAssertEqual(SyncBaselineEntry(encoded: "~?#\(vid)")?.stale, true)
        XCTAssertEqual(SyncBaselineStore.splitGeneration("abc@9#\(vid)#4").gen, 4, "a version id is never read as a generation")
        XCTAssertEqual(SyncBaselineStore.splitGeneration("abc@9#\(vid)#4").value, "abc@9#\(vid)")
    }

    // MARK: - Feed unavailable (migration 015 not applied)

    /// The domino head gate (design §6 domino 段, §10.5): the engine is the
    /// gate's single writer. Work asked for while a session runs pulls
    /// first and runs when that chain ends at head; a session whose feed is
    /// missing hands the gate back to "no engine" (work runs at once); the
    /// session's end does the same.
    func testHeadGateFollowsTheEngine_runningAtHeadFeedMissingAndEnded_killsNoChainEnded() async throws {
        let a = makeDevice("A")
        let flag = try XCTUnwrap(a.puller.headFlag)
        XCTAssertTrue(flag.engineRunning, "a session that pulls is an engine")
        XCTAssertFalse(flag.isAtHead, "nothing has reached head yet")
        var ran = 0
        flag.runWhenAtHead { ran += 1 }
        XCTAssertEqual(ran, 0, "with an engine the work waits for a chain to end at head")

        await a.puller.pullToHead()

        XCTAssertTrue(flag.isAtHead)
        XCTAssertEqual(ran, 1, "the chain the gate asked for ended at head and released the work once")

        server.feedUnavailable = true
        a.puller.foregroundDidReturn()
        await a.puller.pullToHead()
        XCTAssertTrue(a.puller.feedUnavailable)
        XCTAssertFalse(flag.engineRunning, "a missing feed is no engine: domino runs as before sync")
        flag.runWhenAtHead { ran += 1 }
        XCTAssertEqual(ran, 2, "without an engine the work runs at once")

        server.feedUnavailable = false
        a.puller.foregroundDidReturn()
        await a.puller.pullToHead()
        XCTAssertTrue(flag.engineRunning, "the probe that found the feed again is an engine again")
        XCTAssertTrue(flag.isAtHead)

        a.puller.endSession()
        XCTAssertFalse(flag.engineRunning)
        XCTAssertNil(flag.pullNow)
    }

    func testFeedUnavailableOpensI1AndUploadsStillGoOut() async throws {
        server.feedUnavailable = true
        let a = makeDevice("A")
        let x = create(a, "X", note: "c0")
        XCTAssertFalse(a.service.inboundAtHead, "a puller session starts off head")

        await pull(a)

        XCTAssertTrue(a.puller.feedUnavailable)
        XCTAssertTrue(a.service.inboundAtHead, "the seat belt: today's uploads are not held")
        XCTAssertGreaterThan(trailCount("sync.feed.unavailable"), 0)
        await flush(a)
        XCTAssertEqual(serverNote(x), "c0")
        XCTAssertEqual(server.requests(.pull).count, 1, "no retry until the next session")
        await pull(a)
        XCTAssertEqual(server.requests(.pull).count, 1)
    }

    // MARK: - The tripwire logs and counts, nothing more

    func testTripwire_rewoundCounterIsLoggedAndThePromptStillShows() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        let y = create(a, "Y", note: "d0")
        await flush(a)
        await pull(a)
        XCTAssertEqual(a.service.observedMaxSeq, 2)

        // A hand restore: the counter and the epoch row come back from the dump.
        server.bypassRestore(dump)
        XCTAssertEqual(server.seqCounter, 1)
        let resetsBefore = trailCount("sync.reset reason=epoch")
        edit(a, x, note: "c_a")
        await flush(a)

        XCTAssertEqual(serverNote(x), "c_a")
        XCTAssertEqual(server.seq(table: "events", key: x.id.uuidString), 2, "the server handed out 2 again")
        XCTAssertEqual(a.service.rewindAlerts, 1)
        XCTAssertGreaterThan(trailCount("sync.cursor.rewind table=events seq=2 watermark=2"), 0)
        XCTAssertEqual(trailCount("sync.reset reason=epoch") - resetsBefore, 0, "no reset from the tripwire")
        XCTAssertNil(a.service.recoveryPrompt)

        // The R3 step closes the window; the catch-up then re-uploads Y.
        server.restoreWithEpochStep()
        server.unpause()
        await pull(a)
        XCTAssertEqual(serverNote(y), "d0")
        XCTAssertEqual(trailCount("sync.reset reason=epoch") - resetsBefore, 1)
    }

    // MARK: - Badge, later, discard, relaunch

    func testLaterKeepsTheBadgeAcrossARelaunchAndDiscardClearsIt() async throws {
        let a = makeDevice("A")
        let x = await seedX(on: a)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")
        await pull(a)
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1)
        let items = try XCTUnwrap(a.service.recoveryPrompt?.items)
        XCTAssertEqual(items.first?.title, "X")
        XCTAssertEqual(items.first?.serverHasRow, true)

        a.puller.recovery.later()
        XCTAssertNil(a.service.recoveryPrompt)
        XCTAssertEqual(a.service.pendingPromptCount, 1)
        XCTAssertTrue(a.service.hasUndecidedOffers)

        a.puller.endSession()
        let relaunched = makeDevice("A2", suite: a.suite, shelfDirectory: a.shelfDirectory)
        let promptsBefore = trailCount("sync.restore.prompt ")
        await pull(relaunched)
        XCTAssertNil(relaunched.service.recoveryPrompt, "a relaunch does not repeat the alert")
        XCTAssertEqual(relaunched.service.pendingPromptCount, 1, "the badge stays")
        XCTAssertEqual(trailCount("sync.restore.prompt ") - promptsBefore, 0)

        XCTAssertEqual(relaunched.puller.recovery.discard(), 1)
        XCTAssertEqual(relaunched.service.pendingPromptCount, 0)
        XCTAssertFalse(relaunched.service.hasUndecidedOffers)
        XCTAssertEqual(shelfLines(relaunched, x, reason: "catchup").first?.resolution, "discarded")
        XCTAssertGreaterThan(trailCount("sync.restore.discard n=1"), 0)
    }

    /// The seat belt's launch order (QA 5d): a device with offline edits
    /// flushes first — held by I1 — and only then probes the feed. Finding
    /// none releases the held tables right there, as today's build sends
    /// them on launch; nothing waits for the next edit.
    func testFeedUnavailable_launchUploadHeldByI1GoesOutOnTheProbe_killsNoFlushOnFallback() async throws {
        server.feedUnavailable = true
        let a = makeDevice("A")
        let x = create(a, "X", note: "offline")
        await flush(a)
        XCTAssertNil(server.row(table: "events", key: x.id.uuidString), "held by I1 before the first pull")
        XCTAssertTrue(a.service.needsFlush.contains("calendar_events"))

        await pull(a)

        XCTAssertEqual(serverNote(x), "offline", "the probe found no feed and released the launch upload")
        XCTAssertTrue(a.service.needsFlush.isEmpty)
        XCTAssertTrue(a.service.inboundAtHead)
        XCTAssertEqual(server.requests(.upsert).count, 1, "king's shape while the feed is missing")
        XCTAssertEqual(server.requests(.pull).count, 1)
    }

    /// QA S7 (#8): rows whose upload failed while the feed was unavailable
    /// went out only with the next local edit, though the re-probe had
    /// reached head. A failed table is owed to the next chain at head.
    func testFeedUnavailable_aFailedUploadIsResentWhenTheReprobeReachesHead_killsNoFlagOnFailure() async throws {
        server.feedUnavailable = true
        let a = makeDevice("A")
        let x = create(a, "X", note: "c0")
        await pull(a)
        server.failWhen = { verb, _ in verb == .insert || verb == .upsert ? URLError(.timedOut) : nil }
        await flush(a)
        XCTAssertNil(server.row(table: "events", key: x.id.uuidString), "fixture: the upload failed")
        server.failWhen = nil

        // 015 is applied; the app comes to the foreground: one fresh probe.
        server.feedUnavailable = false
        a.puller.foregroundDidReturn()
        await a.puller.pullToHead()

        XCTAssertFalse(a.puller.feedUnavailable)
        XCTAssertEqual(serverNote(x), "c0", "sent at head, with no new edit")
        XCTAssertEqual(entry(a, x)?.isUnknown, false)
    }

    /// QA S7 (#9): a failed upload left no trail line, only os_log. One
    /// line per table per flush, with the failure's code.
    func testAFailedFlushWritesOneTrailLinePerTable_killsNoFailureLine() async throws {
        let a = makeDevice("A")
        await pull(a)
        create(a, "X", note: "x")
        create(a, "Y", note: "y")
        server.failWhen = { verb, _ in verb == .insert ? URLError(.timedOut) : nil }
        let needle = "sync.push.failed table=calendar_events code=url-1001 n=2"
        let before = trailCount(needle)

        await flush(a)

        XCTAssertEqual(trailCount(needle) - before, 1, "one line for the table, not one per row")
    }

    /// Foreground on a server where the feed was missing: one fresh probe
    /// (migration 015 may have been applied since), then the ordinary chain.
    func testForegroundReprobesAFeedFoundMissing() async throws {
        server.feedUnavailable = true
        let a = makeDevice("A", observesForeground: true)
        let x = create(a, "X", note: "c0")
        await pull(a)
        XCTAssertTrue(a.puller.feedUnavailable)
        await flush(a)
        XCTAssertEqual(server.requests(.pull).count, 1)
        let reprobesBefore = trailCount("sync.feed.reprobe")

        server.feedUnavailable = false
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await syncEventually("the reprobe chain applied X") { a.service.cursor.value == 1 }

        XCTAssertFalse(a.puller.feedUnavailable)
        XCTAssertEqual(trailCount("sync.feed.reprobe") - reprobesBefore, 1)
        XCTAssertEqual(server.requests(.pull).count, 2)
        XCTAssertEqual(a.service.cursor.epoch, server.epochString)
        XCTAssertEqual(server.seq(table: "events", key: x.id.uuidString), 1)
    }

    /// 丢弃 drops only the offered lines (QA QM4): a catch-up line the
    /// ancestry cleared — the copy is the live row's ancestor three hops
    /// up — stays on the shelf undecided.
    func testDiscardLeavesUnofferedCatchUpLinesAlone_killsDiscardUnoffered() async throws {
        let a = makeDevice("A")
        let x = create(a, "X", note: "c0")
        let y = create(a, "Y", note: "d0")
        await flush(a)
        await pull(a)
        edit(a, y, note: "d1")
        await flush(a)
        await pull(a)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)

        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")
        for note in ["h1", "h2", "h3"] {
            try server.agentWrite(table: "events", key: y.id.uuidString, data: ["note": note])
        }
        await pull(a)

        XCTAssertEqual(localNote(a, x), "c_agent")
        XCTAssertEqual(localNote(a, y), "h3")
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.offered, true, "c_a was lost: offered")
        XCTAssertEqual(shelfLines(a, y, reason: "catchup").first?.offered, false, "d1 is h3's ancestor: not offered")
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1)

        XCTAssertEqual(a.puller.recovery.discard(), 1, "only the offered line")

        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.resolution, "discarded")
        XCTAssertNil(shelfLines(a, y, reason: "catchup").first?.resolution, "never offered, never decided")
        XCTAssertEqual(a.service.pendingPromptCount, 0)
        XCTAssertNil(a.service.recoveryPrompt)
    }

    /// No ledger record later than the device's epoch (QA QM5: a restore
    /// that bypassed the script changes the epoch without writing one),
    /// ancestry unknown, and the live row's seq not below the copy's: the
    /// ledger says nothing was lost, so nothing is offered. kmin is ∞
    /// here — reading it as 0 would offer every clean copy.
    func testNoLedgerRecordAfterTheOldEpoch_kminIsInfinite_notOffered_killsKminZero() async throws {
        server.ancestryUnknownWhen = { _, _, _, _ in true }
        let a = makeDevice("A")
        let x = await seedX(on: a)
        edit(a, x, note: "c_a")
        await flush(a)
        XCTAssertEqual(entry(a, x)?.seq, 2)

        server.rewind(toSeq: 1)
        XCTAssertTrue(server.restores.isEmpty, "a hand restore: a new epoch, no ledger record")
        try agentEdit(x, note: "c_agent")
        XCTAssertEqual(server.seq(table: "events", key: x.id.uuidString), 2, "the counter handed out 2 again")

        await pull(a)

        XCTAssertNil(a.service.cursor.kmin, "no record after the old epoch: kmin is ∞")
        XCTAssertEqual(localNote(a, x), "c_agent")
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.row["note"] as? String, "c_a")
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.offered, false)
        XCTAssertNil(a.service.recoveryPrompt)
        XCTAssertEqual(a.service.pendingPromptCount, 0)
    }

    /// A reset under e1 applied a page (X shelved under e1) and a second
    /// epoch change came before head (QA 小洞 2). At head every catch-up
    /// line not yet judged is judged — e1's as well as e2's.
    func testCatchUpLinesFromAnEarlierResetAreJudgedAtHead_killsEpochFilter() async throws {
        let a = makeDevice("A")
        a.puller.pageLimit = 1
        // X must take seq 1 and Y seq 2: posted in two flushes, not one
        // chunk (a chunk is ordered by id, so one flush would make it a
        // coin toss which row comes first on the restored timeline).
        let x = create(a, "X", note: "c0")
        await flush(a)
        await pull(a)
        let y = create(a, "Y", note: "d0")
        await flush(a)
        await pull(a)
        XCTAssertEqual(server.seq(table: "events", key: x.id.uuidString), 1)
        XCTAssertEqual(server.seq(table: "events", key: y.id.uuidString), 2)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        edit(a, y, note: "d_a")
        await flush(a)

        server.restoreFromDump(dump)
        server.unpause()
        let firstEpoch = server.epochString
        // Park the epoch read that follows the reset chain's second page:
        // the first page (X@1) is applied and shelved by then, and the pull
        // that fetched the second asked for the rows after seq 1.
        server.holdWhen = { verb, _ in
            verb == .epoch
                && self.server.requests(.pull).last?.baseSeq == 1
                && !self.shelfLines(a, x, reason: "catchup").isEmpty
        }
        let chain = Task { await self.pull(a) }
        try await syncEventually("the read after the second page parked") { self.server.heldCount == 1 }
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.epoch, firstEpoch, "X was shelved under the first reset")
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.offered, false)
        XCTAssertTrue(shelfLines(a, y, reason: "catchup").isEmpty, "Y's page is not applied yet")

        server.restoreWithEpochStep()
        server.unpause()
        server.holdWhen = nil
        server.releaseAll()
        await chain.value

        XCTAssertNotEqual(a.service.cursor.epoch, firstEpoch)
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.offered, true, "the earlier reset's line was judged too")
        XCTAssertEqual(shelfLines(a, y, reason: "catchup").first?.offered, true)
        XCTAssertEqual(a.service.recoveryPrompt?.count, 2)
    }

    // MARK: - The badge is the way back; the warning's discard is real (QA S4, S5)

    /// A restore lost A's c_a, an agent edited the restored row: one offer.
    /// Returns X with the prompt dismissed by 稍后 and the badge at 1.
    private func offerOneAndLater(_ a: Device) async throws -> Event {
        let x = await seedX(on: a)
        let dump = server.dump()
        edit(a, x, note: "c_a")
        await flush(a)
        server.restoreFromDump(dump)
        server.unpause()
        try agentEdit(x, note: "c_agent")
        await pull(a)
        XCTAssertEqual(a.service.recoveryPrompt?.count, 1, "fixture: one offer")
        a.puller.recovery.later()
        XCTAssertNil(a.service.recoveryPrompt)
        XCTAssertEqual(a.service.pendingPromptCount, 1, "fixture: the badge")
        return x
    }

    /// QA S4: after 稍后 the badge was the only trace of the offer, and
    /// tapping it did nothing. It brings the same prompt back over the same
    /// line, and the write-back from there lands.
    func testTheBadgeBringsThePromptBackAfterLater_killsBadgeDoesNothing() async throws {
        let a = makeDevice("A")
        let x = try await offerOneAndLater(a)
        let promptsBefore = trailCount("sync.restore.prompt ")

        let again = a.puller.recovery.presentAgain()

        let shown = try XCTUnwrap(a.service.recoveryPrompt, "the prompt is up again")
        XCTAssertEqual(again, shown)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.items.map(\.rowId), [x.id.uuidString], "the same offered line")
        XCTAssertEqual(trailCount("sync.restore.prompt ") - promptsBefore, 0, "nothing judged again")

        let result = await a.puller.recovery.accept()
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(serverNote(x), "c_a", "written back")
        XCTAssertEqual(a.service.pendingPromptCount, 0)
        XCTAssertNil(a.puller.recovery.presentAgain(), "nothing undecided: nothing shown")
        XCTAssertNil(a.service.recoveryPrompt)
    }

    /// QA S5: 「仍要退出并丢弃」 signed out and kept the offers; the same
    /// account signing back in showed the badge again. The discard runs
    /// before the sign-out, so it does not.
    func testSignOutAndDiscardLeavesNoBadgeForTheSameAccount_killsNoDiscard() async throws {
        let a = makeDevice("A")
        let x = try await offerOneAndLater(a)

        a.service.discardUndecidedOffersBeforeLeaving()
        // The sign-out (`$session → nil`), then the same account again.
        a.puller.endSession()
        a.service.endSession()
        a.service.beginSession(userId: uid)
        a.puller.beginSession(autoPull: false)
        await pull(a)

        XCTAssertEqual(a.service.pendingPromptCount, 0, "no badge")
        XCTAssertFalse(a.service.hasUndecidedOffers)
        XCTAssertEqual(shelfLines(a, x, reason: "catchup").first?.resolution, "discarded")
        XCTAssertGreaterThan(trailCount("sync.restore.discard n=1"), 0)
    }

    // MARK: - Adopting this device's data starts syncing at once (QA S6)

    /// QA S6: after 「把本机数据用于这个账号」 there was no pull and no upload
    /// for 70 s, nor after a background / foreground round, until a relaunch.
    /// The adopt starts the puller and its first chain to head uploads
    /// every row in one POST.
    func testAdoptStartsThePullerAndUploadsEveryRow_killsAdoptWithoutStart() async throws {
        let a = makeDevice("A")
        let events = (0..<3).map { create(a, "E\($0)", note: "n\($0)") }
        // A sign-in as `uid` on a device whose data belongs to another account.
        a.puller.endSession()
        a.service.endSession()
        let other = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        SyncOwnerGuard.setOwner(other, a.defaults)
        a.defaults.set("x", forKey: "\(SyncBaselineStore.keyPrefix)\(other).calendar_events")
        a.service.beginSession(userId: uid)
        XCTAssertEqual(a.service.ownerState, .blocked(owner: other, session: uid), "fixture: blocked")
        a.puller.beginSession(autoPull: false)
        XCTAssertFalse(a.puller.active, "fixture: the puller refused the session")
        await flush(a)
        XCTAssertTrue(server.requests.isEmpty, "fixture: nothing goes out while blocked")

        a.service.adoptLocalDataForCurrentAccount()
        XCTAssertTrue(a.puller.active, "the puller runs now")
        await a.puller.pullToHead()

        XCTAssertFalse(server.requests(.pull).isEmpty, "it pulled")
        let inserts = server.requests(.insert, table: "events")
        XCTAssertEqual(inserts.count, 1)
        XCTAssertEqual(inserts.first?.keys.count, 3, "every row, in one POST")
        for (index, event) in events.enumerated() {
            XCTAssertEqual(serverNote(event), "n\(index)")
        }
    }

    // MARK: - A server without migration 015 (QA S7)

    /// QA S7: on a server without 015 every events POST carried
    /// `domino_anchor` and came back 400 `PGRST204`, so the main table never
    /// uploaded. With the feed found missing, the 015 columns stay off the
    /// wire: one POST, every row lands, and the rows read clean afterwards
    /// — a row the server inserted without a `seq` landed all the same.
    func testPre015_wholeTableUploadLandsWithoutThe015Columns_killsSendAnchorAnyway_killsSeqlessRowLeftDirty() async throws {
        server.pre015 = true
        let a = makeDevice("A")
        let events = (0..<11).map { create(a, "E\($0)", note: "n\($0)") }
        await pull(a)
        XCTAssertTrue(a.puller.feedUnavailable, "fixture: the probe found no feed")

        await flush(a)

        for (index, event) in events.enumerated() {
            XCTAssertEqual(serverNote(event), "n\(index)", "every row landed")
        }
        let inserts = server.requests(.upsert, table: "events")
        XCTAssertEqual(inserts.count, 1, "one upsert, accepted the first time")
        let sent = try XCTUnwrap(inserts.first?.body as? [[String: Any]])
        XCTAssertEqual(sent.count, 11)
        XCTAssertTrue(sent.allSatisfy { $0["domino_anchor"] == nil }, "no 015 column on the wire")
        XCTAssertTrue(events.allSatisfy { entry(a, $0)?.isUnknown == false }, "the baseline holds what landed")

        let before = server.requests.count
        await flush(a)
        XCTAssertEqual(server.requests.count, before, "the rows read clean: nothing is sent again")
    }

    /// A server with the feed but without one 015 column (an earlier 015):
    /// the device cannot know until the server names it. The `PGRST204`
    /// names `domino_anchor`; the request goes out once more without it,
    /// and every later write of the session leaves it off.
    func testServerMissingOne015Column_isResentOnceWithoutIt_killsNoResend() async throws {
        server.lacksColumns = ["domino_anchor"]
        let a = makeDevice("A")
        await pull(a)
        XCTAssertFalse(a.puller.feedUnavailable, "fixture: the feed is there")
        let withheldBefore = trailCount("sync.push.column_withheld table=events column=domino_anchor")
        let x = create(a, "X", note: "c0")

        await flush(a)

        XCTAssertEqual(serverNote(x), "c0")
        XCTAssertEqual(server.requests(.insert, table: "events").count, 2, "refused once, resent once without the column")
        XCTAssertEqual(trailCount("sync.push.column_withheld table=events column=domino_anchor") - withheldBefore, 1)
        XCTAssertNotNil(entry(a, x)?.seq)
        XCTAssertEqual(entry(a, x)?.isUnknown, false)

        edit(a, x, note: "c1")
        await flush(a)
        XCTAssertEqual(serverNote(x), "c1")
        XCTAssertEqual(server.requests(.patch, table: "events").count, 1, "the PATCH leaves it off from the start")
        let before = server.requests.count
        await flush(a)
        XCTAssertEqual(server.requests.count, before)
    }

    /// QA S7's side effect: user_settings was POSTed every 5 s. The row was
    /// already on the server, so the ignore-duplicates POST came back
    /// without it and the `?` it wrote kept the row dirty; each send's
    /// baseline write posted `didChangeNotification`, and the 5 s sink sent
    /// it again. (Without the feed that loop is gone with king's upsert; on
    /// a 015 server it still opens when another device created the row
    /// since this one's last pull.) Each turn is one `syncSettings()` with
    /// nothing changed; the second and third must send nothing.
    func testSettingsRowCreatedElsewhereSinceThePullIsNotResentUnchanged_killsSettingsLoop() async throws {
        let a = makeDevice("A")
        // One synced key: an empty blob hashes to no keys, and no keys
        // never read dirty — the loop needs something to send.
        a.defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await pull(a)
        _ = server.seed(table: "user_settings", rows: [["user_id": uid, "settings": ["seeded": true]]])

        for _ in 0..<3 { await a.service.syncSettings() }

        XCTAssertEqual(server.requests(.insert, table: "user_settings").count, 1, "the same payload is not POSTed again while its echo is owed")
        XCTAssertTrue(server.requests(.patch, table: "user_settings").isEmpty)
    }

    /// Without 015 the settings row goes out in king's upsert: an existing
    /// row is overwritten once, and the row reads clean afterwards.
    func testPre015_settingsAlreadyOnTheServerIsOverwrittenOnceAndReadsClean() async throws {
        server.pre015 = true
        _ = server.seed(table: "user_settings", rows: [["user_id": uid, "settings": ["seeded": true]]])
        let a = makeDevice("A")
        a.defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await pull(a)

        for _ in 0..<3 { await a.service.syncSettings() }

        XCTAssertEqual(server.requests(.upsert, table: "user_settings").count, 1)
        XCTAssertTrue(server.requests(.insert, table: "user_settings").isEmpty)
        let settings = server.row(table: "user_settings", key: uid)?.data["settings"] as? [String: Any]
        XCTAssertNil(settings?["seeded"], "the device's blob replaced the server's")
    }

    /// A settings row the server did not have lands once and reads clean.
    func testPre015_newSettingsRowLandsOnceAndReadsClean() async throws {
        server.pre015 = true
        let a = makeDevice("A")
        a.defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await pull(a)

        for _ in 0..<3 { await a.service.syncSettings() }

        XCTAssertEqual(server.requests(.upsert, table: "user_settings").count, 1)
        XCTAssertNotNil(server.row(table: "user_settings", key: uid))
    }

    // MARK: - Without 015 the outbound path is king's; with 015 it is not (decision 2026-10-21)

    /// The probe that found this (`06-probe…`): on a server without 015 an
    /// edit of an existing row never arrived — the ignore-duplicates POST
    /// left the row as it was. King's merge-duplicates upsert updates it.
    func testPre015_editOfAnExistingRowReachesTheServer_killsFallbackIgnoreDuplicates() async throws {
        server.pre015 = true
        let a = makeDevice("A")
        let x = create(a, "X", note: "c0")
        await pull(a)
        await flush(a)
        XCTAssertEqual(serverNote(x), "c0")

        edit(a, x, note: "c1")
        await flush(a)

        XCTAssertEqual(serverNote(x), "c1", "the edit reached the server")
        XCTAssertEqual(server.requests(.upsert, table: "events").count, 2)
        XCTAssertTrue(server.requests(.insert).isEmpty)
        XCTAssertTrue(server.requests(.patch).isEmpty)
        XCTAssertEqual(entry(a, x)?.isUnknown, false)
        let before = server.requests.count
        await flush(a)
        XCTAssertEqual(server.requests.count, before, "clean after the upsert")
    }

    /// …and a delete never arrived: the tombstone PATCH names `deleted_at`,
    /// which a server without 015 does not have. King's physical DELETE.
    func testPre015_deleteRemovesTheRowFromTheServer_killsFallbackNoDelete() async throws {
        server.pre015 = true
        let a = makeDevice("A")
        let x = create(a, "X", note: "c0")
        let y = create(a, "Y", note: "d0")
        await pull(a)
        await flush(a)

        a.store.deleteCalendarEvent(local(a, x)!)
        await flush(a)

        XCTAssertNil(server.row(table: "events", key: x.id.uuidString), "gone from the server, physically")
        XCTAssertEqual(serverNote(y), "d0")
        XCTAssertEqual(server.requests(.delete, table: "events").map(\.keys), [[x.id.uuidString]])
        XCTAssertTrue(server.requests(.tombstone).isEmpty)
        XCTAssertNil(entry(a, x), "the baseline lets go of it")
    }

    /// 015 applied, the re-probe reaches head: the same table goes back to
    /// the conditional PATCH and the tombstone PATCH.
    func testWhen015ArrivesTheSameTableReturnsToTheConditionalShapes_killsMergeAfter015() async throws {
        server.pre015 = true
        let a = makeDevice("A")
        let x = create(a, "X", note: "c0")
        let y = create(a, "Y", note: "d0")
        await pull(a)
        await flush(a)
        XCTAssertEqual(server.requests(.upsert, table: "events").count, 1, "fixture: king's shape")
        XCTAssertTrue(a.service.outboundFallback)

        server.pre015 = false
        a.puller.foregroundDidReturn()
        await a.puller.pullToHead()
        XCTAssertFalse(a.puller.feedUnavailable)
        XCTAssertFalse(a.service.outboundFallback)
        XCTAssertNotNil(entry(a, x)?.seq, "the pull gave the row its seq")
        let upserts = server.requests(.upsert).count

        edit(a, x, note: "c1")
        a.store.deleteCalendarEvent(local(a, y)!)
        await flush(a)

        XCTAssertEqual(serverNote(x), "c1")
        XCTAssertTrue(server.isTombstoned(table: "events", key: y.id.uuidString))
        XCTAssertEqual(server.requests(.patch, table: "events").count, 1, "a conditional PATCH")
        XCTAssertEqual(server.requests(.tombstone, table: "events").count, 1, "a tombstone PATCH")
        XCTAssertEqual(server.requests(.upsert).count, upserts, "no merge upsert once 015 is there")
        XCTAssertTrue(server.requests(.delete).isEmpty)
    }

    // MARK: - The gate's classification is by message, not code

    func testGateMessagesClassifyAsTheSixthClass() {
        let stale = SupabaseREST.requestError(table: "events", method: "PATCH", status: 400,
                                              body: Data("{\"code\":\"P0001\",\"message\":\"sync_epoch_stale\"}".utf8))
        XCTAssertEqual(SyncWriteFailure.classify(stale).kind, .epochStale)
        let paused = SupabaseREST.requestError(table: "events", method: "POST", status: 400,
                                               body: Data("{\"code\":\"P0001\",\"message\":\"sync_paused\"}".utf8))
        XCTAssertEqual(SyncWriteFailure.classify(paused).kind, .paused)
        let other = SupabaseREST.requestError(table: "events", method: "POST", status: 400,
                                              body: Data("{\"code\":\"P0001\",\"message\":\"something else\"}".utf8))
        XCTAssertEqual(SyncWriteFailure.classify(other).kind, .retryable)
        XCTAssertEqual(SupabaseREST.decodeEpochRow([["epoch": "e", "paused": false, "restores": [["epoch": "e", "kept_max": 4]]]]),
                       SyncEpochRow(epoch: "e", paused: false, restores: [SyncRestoreRecord(epoch: "e", keptMax: 4, dumpEpoch: nil)]))
        XCTAssertEqual(try SupabaseREST.decodeAncestry(Data("true".utf8)), true)
        XCTAssertEqual(try SupabaseREST.decodeAncestry(Data("false".utf8)), false)
        XCTAssertNil(try SupabaseREST.decodeAncestry(Data("null".utf8)))
    }
}
