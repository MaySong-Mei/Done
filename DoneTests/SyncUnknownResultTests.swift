//
//  SyncUnknownResultTests.swift
//  DoneTests
//
//  Survey S4 / gaps G10 and G23: a write that was sent but whose result is
//  unknown leaves the `?` marker in the baseline, so the row is re-verified
//  instead of reading clean, and a local delete of such a row still sends
//  its tombstone PATCH.
//

import XCTest
@testable import Done

@MainActor
final class SyncUnknownResultTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!
    private let uid = "44444444-4444-4444-4444-444444444444"

    override func setUp() {
        super.setUp()
        suiteName = "SyncUnknownResultTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeEvent(_ title: String, note: String = "") -> Event {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Event(title: title, note: note,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
    }

    private func entry(_ event: Event) -> SyncBaselineEntry? {
        service.baseline.entry(table: "calendar_events", id: event.id.uuidString)
    }

    /// The answer was lost after the request left: the transport error a
    /// dropped connection surfaces.
    private let lostAnswer = URLError(.networkConnectionLost)

    private func hash(_ event: Event) -> String {
        SupabaseSyncService.rowHash(service.eventToRow(event, kind: "calendar"))
    }

    private func edited(_ event: Event, note: String) -> Event {
        var copy = event
        copy.note = note
        return copy
    }

    private func serverNote(_ event: Event) -> String? {
        server.row(table: "events", key: event.id.uuidString)?.data["note"] as? String
    }

    /// What the inbound applier writes when a pull delivers the row: the
    /// pull's `(h_in, seq)`. The applier is another stream's; its write is
    /// all an outbound outcome can meet, so it is written here directly.
    private func pullWrites(_ event: Event, hash: String, seq: Int64) {
        service.baseline.setEntry(SyncBaselineEntry(hash: hash, seq: seq), table: "calendar_events", id: event.id.uuidString)
    }

    private func makePrefs() -> AgentPreferenceStore {
        AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SyncUnknownResultTests-prefs-\(UUID().uuidString)", isDirectory: true))
    }

    private func prefsEntry() -> SyncBaselineEntry? {
        service.baseline.entry(table: "agent_preferences", id: uid)
    }

    // MARK: Send-time marker and compare-and-set (design §6 结果未知的写)

    /// Review BLOCKER arithmetic: the PATCH commits, the doorbell's pull
    /// applies the echo long before the transport gives up, and the timeout
    /// arrives last. A failure that wrote `?@sentSeq` would move the entry
    /// back under the echo and every later edit would go out on a seq the
    /// server left behind, answer `[]`, read as identical and never upload.
    func testS4_echoBeforeFailure_patchTimeoutAfterThePullLeavesThePullsBaseline_killsFailureWritesMarker() async throws {
        let c0 = makeEvent("X", note: "c0")
        await service.syncEvents([c0], kind: "calendar")
        let s0 = try XCTUnwrap(entry(c0)?.seq)
        let c1 = edited(c0, note: "c1")
        server.holdResponseWhen = { verb, _ in verb == .patch }
        let flush = Task { await self.service.syncEvents([c1], kind: "calendar") }
        try await syncEventually("PATCH committed, answer parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        XCTAssertEqual(entry(c0), .unknown(seq: s0), "marked when the request was built")
        let s5 = try XCTUnwrap(server.seq(table: "events", key: c0.id.uuidString))
        XCTAssertGreaterThan(s5, s0, "the PATCH committed")

        pullWrites(c0, hash: hash(c1), seq: s5)
        server.releaseResponse(failing: URLError(.timedOut))
        await flush.value

        XCTAssertEqual(entry(c0), SyncBaselineEntry(hash: hash(c1), seq: s5), "a thrown error writes nothing; `?` never moves seq back")
        XCTAssertTrue(service.pendingVerify.isEmpty)
        let patches = server.requests(.patch).count
        await service.syncEvents([c1], kind: "calendar")
        XCTAssertEqual(server.requests(.patch).count, patches, "c1 is clean")

        let c2 = edited(c0, note: "c2")
        await service.syncEvents([c2], kind: "calendar")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s5)
        XCTAssertEqual(serverNote(c0), "c2", "the next edit uploads")
    }

    /// The POST version of the same order: the insert commits, the echo
    /// gives the row its seq, the timeout arrives last.
    func testS4_echoBeforeFailure_postTimeoutAfterTheEchoKeepsTheSeq_killsFailureWritesMarker() async throws {
        let z = makeEvent("Z", note: "z0")
        server.holdResponseWhen = { verb, _ in verb == .insert }
        let flush = Task { await self.service.syncEvents([z], kind: "calendar") }
        try await syncEventually("POST committed, answer parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        XCTAssertEqual(entry(z), .unknown(seq: nil), "a POST's row has no seq: the bare `?`")
        let sz = try XCTUnwrap(server.seq(table: "events", key: z.id.uuidString))

        pullWrites(z, hash: hash(z), seq: sz)
        server.releaseResponse(failing: URLError(.timedOut))
        await flush.value

        XCTAssertEqual(entry(z), SyncBaselineEntry(hash: hash(z), seq: sz))
        XCTAssertTrue(service.awaitingEcho.isEmpty)
        let z1 = edited(z, note: "z1")
        await service.syncEvents([z1], kind: "calendar")
        XCTAssertEqual(server.requests(.insert).count, 1, "never POSTed again into an echo that will not come")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, sz)
        XCTAssertEqual(serverNote(z), "z1")
        XCTAssertEqual(service.orphansAfterHeadPull(), [])
    }

    /// The window marking at failure time could not close: the user puts
    /// c0 back after the PATCH left and before its echo. With the marker
    /// written at send, c0 reads dirty in that window — which is what the
    /// applier's three-way compare needs to shelve c1 and keep c0.
    func testS4_revertAfterSendBeforeEcho_theRevertedValueReadsDirtyAndReachesTheServer_killsMarkOnlyOnFailure() async throws {
        let c0 = makeEvent("X", note: "c0")
        await service.syncEvents([c0], kind: "calendar")
        let s0 = try XCTUnwrap(entry(c0)?.seq)
        let c1 = edited(c0, note: "c1")
        server.holdResponseWhen = { verb, _ in verb == .patch }
        let flush = Task { await self.service.syncEvents([c1], kind: "calendar") }
        try await syncEventually("PATCH committed, answer parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        let s5 = try XCTUnwrap(server.seq(table: "events", key: c0.id.uuidString))

        // The user puts c0 back while the answer is out.
        XCTAssertEqual(service.syncStateForEvent(c0, kind: "calendar"), .pending, "c0 must not read clean against the old baseline")
        XCTAssertNotEqual(entry(c0)?.hash, hash(c0))
        XCTAssertEqual(entry(c0)?.seq, s0)

        // The echo X@s5 (c1) meets a dirty c0: the applier shelves c1 and
        // writes base := (h_in, s5). The late answer then finds the entry
        // moved and writes nothing.
        pullWrites(c0, hash: hash(c1), seq: s5)
        server.releaseResponse()
        await flush.value
        XCTAssertEqual(entry(c0), SyncBaselineEntry(hash: hash(c1), seq: s5))

        await service.syncEvents([c0], kind: "calendar")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s5)
        XCTAssertEqual(serverNote(c0), "c0", "the user's last intent is on the server")
    }

    /// The carry-over from the Lean model: a `[row]` answer that arrives
    /// after a pull wrote a NEWER version must not overwrite it — written
    /// unconditionally it moves seq back and marks this device's c1 clean
    /// against a server that holds c2.
    func testS4_lateRowAnswerAfterAPullMovedTheEntryWritesNothing_killsUnconditionalResultWrite() async throws {
        let c0 = makeEvent("X", note: "c0")
        await service.syncEvents([c0], kind: "calendar")
        let c1 = edited(c0, note: "c1")
        server.holdResponseWhen = { verb, _ in verb == .patch }
        let flush = Task { await self.service.syncEvents([c1], kind: "calendar") }
        try await syncEventually("PATCH committed, answer parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        let s5 = try XCTUnwrap(server.seq(table: "events", key: c0.id.uuidString))

        // Another device writes c2@s6 and the pull applies it.
        let s6 = server.writeDirectly(table: "events", key: c0.id.uuidString, data: ["note": "c2"])
        XCTAssertGreaterThan(s6, s5)
        let c2 = edited(c0, note: "c2")
        pullWrites(c0, hash: hash(c2), seq: s6)

        server.releaseResponse()
        await flush.value

        XCTAssertEqual(entry(c0), SyncBaselineEntry(hash: hash(c2), seq: s6), "the late [row]@s5 must not overwrite the newer baseline")
        let c3 = edited(c0, note: "c3")
        await service.syncEvents([c3], kind: "calendar")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s6)
        XCTAssertEqual(serverNote(c0), "c3")
    }

    /// The POST answer's compare-and-set: the echo already brought a newer
    /// version of the new row (another device edited it right after the
    /// insert), so the insert's late answer is older news.
    func testS4_latePostAnswerAfterTheEchoBroughtANewerVersionWritesNothing_killsUnconditionalResultWrite() async throws {
        let z = makeEvent("Z", note: "z0")
        server.holdResponseWhen = { verb, _ in verb == .insert }
        let flush = Task { await self.service.syncEvents([z], kind: "calendar") }
        try await syncEventually("POST committed, answer parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        let sz2 = server.writeDirectly(table: "events", key: z.id.uuidString, data: ["note": "z2"])
        let z2 = edited(z, note: "z2")
        pullWrites(z, hash: hash(z2), seq: sz2)

        server.releaseResponse()
        await flush.value

        XCTAssertEqual(entry(z), SyncBaselineEntry(hash: hash(z2), seq: sz2))
        XCTAssertTrue(service.awaitingEcho.isEmpty)
    }

    /// The settings row's compare-and-set: a pull rewrote the settings
    /// baseline while the PATCH was out, so the PATCH's late answer is older
    /// news and writes nothing. Written anyway, it would move the row's seq
    /// back under the pull and the next settings write would go out on a
    /// seq the server left behind.
    func testS4_lateSettingsAnswerAfterAPullMovedTheSettingsBaselineWritesNothing_killsSettingsAnswerUnconditional() async throws {
        let banner = AppSettingsKeys.showTimerBanner
        defaults.set(true, forKey: banner)
        await service.syncSettings()
        XCTAssertNotNil(service.baseline.settings?.seq)
        defaults.set(false, forKey: banner)
        server.holdResponseWhen = { verb, table in verb == .patch && table == "user_settings" }
        let flush = Task { await self.service.syncSettings() }
        try await syncEventually("settings PATCH committed, answer parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        guard case .versioned(_, let marked, _)? = service.baseline.settings else { return XCTFail("versioned expected") }
        XCTAssertEqual(marked[banner], SyncBaselineEntry.unknownHash, "rig: the send's marker is in place while the answer is out")
        let answered = try XCTUnwrap(server.seq(table: "user_settings", key: uid))

        // Another device writes the row again and the pull applies it.
        let later = server.writeDirectly(table: "user_settings", key: uid, data: ["note": "another device"])
        XCTAssertGreaterThan(later, answered)
        var pulledKeys = marked
        pulledKeys[banner] = "pu11ed0000000000"
        let pulled = SyncSettingsBaseline.versioned(seq: later, keys: pulledKeys, zone: nil)
        service.baseline.setSettings(pulled)

        server.releaseResponse()
        await flush.value

        XCTAssertEqual(service.baseline.settings, pulled, "the late answer must not overwrite the pull's newer settings baseline")
        await service.syncSettings()
        XCTAssertEqual(server.requests(.patch, table: "user_settings").last?.baseSeq, later, "the next write goes out on the pulled seq")
        XCTAssertEqual(service.baseline.settings?.seq, server.seq(table: "user_settings", key: uid), "and lands")
    }

    /// The settings row's echo-before-failure: the PATCH commits, the pull
    /// applies the echo while the answer is out, and the timeout arrives
    /// last. The failure writes nothing; writing the send's marker back
    /// would move the settings seq under the pull and every later settings
    /// write would go out on a seq the server left behind.
    func testS4_echoBeforeFailure_settingsPatchTimeoutAfterThePullLeavesThePullsBaseline_killsSettingsFailureWritesMarker() async throws {
        let banner = AppSettingsKeys.showTimerBanner
        defaults.set(true, forKey: banner)
        await service.syncSettings()
        let sent = try XCTUnwrap(service.baseline.settings?.seq)
        defaults.set(false, forKey: banner)
        server.holdResponseWhen = { verb, table in verb == .patch && table == "user_settings" }
        let flush = Task { await self.service.syncSettings() }
        try await syncEventually("settings PATCH committed, answer parked") { self.server.heldResponseCount == 1 }
        server.holdResponseWhen = nil
        guard case .versioned(let markedSeq, let marked, _)? = service.baseline.settings else { return XCTFail("versioned expected") }
        XCTAssertEqual(markedSeq, sent, "rig: marked at the sent seq")
        XCTAssertEqual(marked[banner], SyncBaselineEntry.unknownHash, "rig: the send's marker is in place while the answer is out")
        let answered = try XCTUnwrap(server.seq(table: "user_settings", key: uid))
        XCTAssertGreaterThan(answered, sent, "the PATCH committed")

        // Another device writes the row again and the pull applies it.
        let later = server.writeDirectly(table: "user_settings", key: uid, data: ["note": "another device"])
        XCTAssertGreaterThan(later, answered)
        var pulledKeys = marked
        pulledKeys[banner] = "pu11ed0000000000"
        let pulled = SyncSettingsBaseline.versioned(seq: later, keys: pulledKeys, zone: nil)
        service.baseline.setSettings(pulled)

        server.releaseResponse(failing: URLError(.timedOut))
        await flush.value

        XCTAssertEqual(service.baseline.settings, pulled, "a thrown error writes nothing; the settings seq never moves back under the pull")
        await service.syncSettings()
        XCTAssertEqual(server.requests(.patch, table: "user_settings").last?.baseSeq, later, "the next write goes out on the pulled seq")
        XCTAssertEqual(service.baseline.settings?.seq, server.seq(table: "user_settings", key: uid), "and lands")
    }

    /// Design §8.2's "same MainActor tick, no suspension point": the flush
    /// takes its snapshot and writes its markers without yielding, so a pull
    /// queued right behind the flush's start can only land after the marker
    /// and replace it. A suspension between the snapshot and the marker lets
    /// the pull land first; the marker built from the stale snapshot then
    /// moves seq back under the pull, and the edit goes out again and again
    /// on a seq the server left behind and never uploads (gap G1).
    func testS4_aPullQueuedBehindTheFlushStartLandsOnTheMarkerNeverUnderIt_killsSuspensionBeforeMark() async throws {
        let c0 = makeEvent("X", note: "c0")
        await service.syncEvents([c0], kind: "calendar")
        let s1 = try XCTUnwrap(entry(c0)?.seq)
        let s2 = server.writeDirectly(table: "events", key: c0.id.uuidString, data: ["note": "c2"])
        let c1 = edited(c0, note: "c1"), c2 = edited(c0, note: "c2")

        let flush = Task { await self.service.syncEvents([c1], kind: "calendar") }
        let pull = Task { self.pullWrites(c0, hash: self.hash(c2), seq: s2) }
        await pull.value
        await flush.value

        XCTAssertEqual(server.requests(.patch).first?.baseSeq, s1, "rig: the flush took its snapshot before the pull ran")
        XCTAssertEqual(entry(c0), SyncBaselineEntry(hash: hash(c2), seq: s2), "the pull's baseline stands; no marker lands under it")
        service.resolvePendingVerifyAtHead(seen: [], pullIssue: service.pullIssueCounter() + 1)
        await service.syncEvents([c1], kind: "calendar")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s2)
        XCTAssertEqual(serverNote(c0), "c1", "the edit reaches the server")
    }

    /// The single-row twin: a scalar row's flush reads its baseline before
    /// `pushSingleton` and writes the marker inside it, in the same tick. A
    /// suspension between the two lets a queued pull land first; the `?`
    /// built from the stale seq then lands under the pull, and the row goes
    /// out on a seq the server left behind until a confirmation reads it
    /// clean without ever uploading it.
    func testS4_aPullQueuedBehindAScalarRowFlushStartLandsOnTheMarkerNeverUnderIt_killsSingletonSuspensionBeforeMark() async throws {
        let prefs = makePrefs()
        await service.syncAgentPreferences(prefs)
        let s0 = try XCTUnwrap(prefsEntry()?.seq)
        // Force a dirty row without touching the store: a stale baseline hash.
        service.baseline.setEntry(SyncBaselineEntry(hash: "0ld3nc0d1ng00000", seq: s0), table: "agent_preferences", id: uid)
        let s2 = server.writeDirectly(table: "agent_preferences", key: uid, data: ["rules": ["another device's rule"]])
        XCTAssertGreaterThan(s2, s0)
        let pulled = SyncBaselineEntry(hash: "pu11ed0000000000", seq: s2)

        let flush = Task { await self.service.syncAgentPreferences(prefs) }
        let pull = Task { self.service.baseline.setEntry(pulled, table: "agent_preferences", id: self.uid) }
        await pull.value
        await flush.value

        XCTAssertEqual(server.requests(.patch, table: "agent_preferences").first?.baseSeq, s0, "rig: the flush took its snapshot before the pull ran")
        XCTAssertEqual(prefsEntry(), pulled, "the pull's baseline stands; no marker lands under it")
        service.resolvePendingVerifyAtHead(seen: [], pullIssue: service.pullIssueCounter() + 1)
        await service.syncAgentPreferences(prefs)
        XCTAssertEqual(server.requests(.patch, table: "agent_preferences").last?.baseSeq, s2, "the next write goes out on the pulled seq")
        let landed = try XCTUnwrap(server.seq(table: "agent_preferences", key: uid))
        XCTAssertGreaterThan(landed, s2)
        XCTAssertEqual(prefsEntry(), SyncBaselineEntry(hash: SupabaseSyncService.rowHash(service.agentPreferencesToRow(prefs)), seq: landed),
                       "the local row reaches the server")
    }

    /// The marker reaches the disk before any request leaves, in one write
    /// for the table, carrying the table's generation unchanged: the first
    /// request (the tombstone) is parked before it runs and the stored value
    /// already holds every row's `?`.
    func testS4_everyRowOfTheFlushIsMarkedOnDiskInOneWriteBeforeTheFirstRequestLeaves_killsMarkPerRequest() async throws {
        let suite = "SyncUnknownResultTests-count-\(UUID().uuidString)"
        let counting = try XCTUnwrap(WriteCountingDefaults(suiteName: suite))
        defer { counting.removePersistentDomain(forName: suite) }
        let svc = SupabaseSyncService(gateway: server, userId: uid, defaults: counting)
        let a = makeEvent("a", note: "a0"), gone = makeEvent("gone")
        await svc.syncEvents([a, gone], kind: "calendar")
        let sa = try XCTUnwrap(svc.baseline.entry(table: "calendar_events", id: a.id.uuidString)?.seq)
        let sg = try XCTUnwrap(svc.baseline.entry(table: "calendar_events", id: gone.id.uuidString)?.seq)
        svc.baseline.advanceGeneration(tables: ["calendar_events"])
        svc.baseline.persist()
        let generation = SyncBaselineStore(defaults: counting, userId: uid).generation(of: "calendar_events")
        XCTAssertNotEqual(generation, 0)
        let tableKey = SyncBaselineStore.key(userId: uid, table: "calendar_events")
        counting.writes = [:]
        let b = makeEvent("b, new")
        server.holdWhen = { _, _ in true }
        let flush = Task { await svc.syncEvents([edited(a, note: "a1"), b], kind: "calendar") }
        try await syncEventually("first request parked before it runs") { self.server.heldCount == 1 }
        server.holdWhen = nil

        XCTAssertEqual(server.requests.last?.verb, .tombstone, "the first request of the flush")
        XCTAssertEqual(counting.writes[tableKey], 1, "one write for the table before any request left")
        let onDisk = SyncBaselineStore(defaults: counting, userId: uid)
        XCTAssertEqual(onDisk.entry(table: "calendar_events", id: gone.id.uuidString), .unknown(seq: sg))
        XCTAssertEqual(onDisk.entry(table: "calendar_events", id: a.id.uuidString), .unknown(seq: sa))
        XCTAssertEqual(onDisk.entry(table: "calendar_events", id: b.id.uuidString), .unknown(seq: nil))
        XCTAssertEqual(onDisk.generation(of: "calendar_events"), generation, "the table keeps its generation")

        server.releaseAll()
        await flush.value
        XCTAssertNil(svc.baseline.entry(table: "calendar_events", id: gone.id.uuidString))
        XCTAssertEqual(svc.baseline.entry(table: "calendar_events", id: b.id.uuidString)?.hash,
                       SupabaseSyncService.rowHash(svc.eventToRow(b, kind: "calendar")))
    }

    /// The settings row's marker is on disk before its request leaves: the
    /// PATCH is parked before it runs and the stored settings baseline
    /// already holds the changed key's `?`. A relaunch while the request
    /// is out still reads the row dirty.
    func testS4_settingsMarkerIsOnDiskBeforeTheRequestLeaves_killsSingletonMarkerNotPersisted() async throws {
        let banner = AppSettingsKeys.showTimerBanner
        defaults.set(true, forKey: banner)
        await service.syncSettings()
        let s0 = try XCTUnwrap(service.baseline.settings?.seq)
        defaults.set(false, forKey: banner)
        server.holdWhen = { _, table in table == "user_settings" }
        let flush = Task { await self.service.syncSettings() }
        try await syncEventually("settings request parked before it runs") { self.server.heldCount == 1 }
        server.holdWhen = nil
        XCTAssertEqual(server.requests(.patch, table: "user_settings").count, 1, "rig: the PATCH is the parked request")
        XCTAssertEqual(server.seq(table: "user_settings", key: uid), s0, "rig: parked before it ran")

        let onDisk = SyncBaselineStore(defaults: defaults, userId: uid)
        guard case .versioned(let seq, let keys, _)? = onDisk.settings else {
            server.releaseAll()
            await flush.value
            return XCTFail("a versioned settings baseline on disk expected")
        }
        XCTAssertEqual(seq, s0)
        XCTAssertEqual(keys[banner], SyncBaselineEntry.unknownHash, "the changed key's marker is on disk before the request leaves")

        server.releaseAll()
        await flush.value
        XCTAssertNotEqual(service.baseline.settings?.seq, s0, "rig: the released PATCH landed")
    }

    /// The scalar row's marker is on disk before its request leaves.
    func testS4_scalarRowMarkerIsOnDiskBeforeTheRequestLeaves_killsSingletonMarkerNotPersisted() async throws {
        let prefs = makePrefs()
        await service.syncAgentPreferences(prefs)
        let s0 = try XCTUnwrap(prefsEntry()?.seq)
        // Dirty in memory only: what is on disk is the clean entry.
        service.baseline.setEntry(SyncBaselineEntry(hash: "0ld3nc0d1ng00000", seq: s0), table: "agent_preferences", id: uid)
        server.holdWhen = { _, table in table == "agent_preferences" }
        let flush = Task { await self.service.syncAgentPreferences(prefs) }
        try await syncEventually("scalar request parked before it runs") { self.server.heldCount == 1 }
        server.holdWhen = nil
        XCTAssertEqual(server.requests(.patch, table: "agent_preferences").count, 1, "rig: the PATCH is the parked request")
        XCTAssertEqual(server.seq(table: "agent_preferences", key: uid), s0, "rig: parked before it ran")

        XCTAssertEqual(SyncBaselineStore(defaults: defaults, userId: uid).entry(table: "agent_preferences", id: uid), .unknown(seq: s0),
                       "the marker is on disk before the request leaves")

        server.releaseAll()
        await flush.value
    }

    /// Pending-verify's "same" is a compare-and-set against the `?@sentSeq`
    /// too: an entry rewritten at the same seq by anything else (a restore
    /// replay, a pull) is not overwritten with the sent hash.
    func testS4_pendingVerifyConfirmsOnlyAnEntryStillHoldingTheSendsMarker_killsConfirmBySeqAlone() async throws {
        let c1 = makeEvent("X", note: "c1")
        let seeded = server.seed(table: "events", rows: [service.eventToRow(c1, kind: "calendar")])
        let s0 = try XCTUnwrap(seeded[c1.id.uuidString])
        service.baseline.setEntry(SyncBaselineEntry(hash: "0ld3nc0d1ng00000", seq: s0), table: "calendar_events", id: c1.id.uuidString)
        service.pullIssueCounter = { 3 }
        await service.syncEvents([c1], kind: "calendar")
        let key = SyncBaselineKey(table: "calendar_events", id: c1.id.uuidString)
        XCTAssertEqual(service.pendingVerify[key]?.sentSeq, s0, "identical content: []")

        pullWrites(c1, hash: "c10ud0000000000", seq: s0)
        service.resolvePendingVerifyAtHead(seen: [], pullIssue: 4)

        XCTAssertFalse(service.pendingVerify.contains(key))
        XCTAssertEqual(entry(c1), SyncBaselineEntry(hash: "c10ud0000000000", seq: s0), "not the send's marker any more: nothing written")

        // Positive control: the same sequence with the marker still in place confirms.
        let d = makeEvent("Y", note: "d")
        let dSeq = try XCTUnwrap(server.seed(table: "events", rows: [service.eventToRow(d, kind: "calendar")])[d.id.uuidString])
        service.baseline.setEntry(SyncBaselineEntry(hash: "0ld3nc0d1ng00000", seq: dSeq), table: "calendar_events", id: d.id.uuidString)
        await service.syncEvents([c1, d], kind: "calendar")
        service.resolvePendingVerifyAtHead(seen: [], pullIssue: 5)
        XCTAssertEqual(entry(d), SyncBaselineEntry(hash: hash(d), seq: dSeq))
    }

    // MARK: G23 — the delete that never went out

    func testG23_newRowWhosePostAnswerWasLostIsDeletedLocally_theTombstoneStillGoesOut_killsAwaitingEchoDeleteDropped() async throws {
        let e = makeEvent("posted, answer lost")
        server.dropResponseWhen = { verb, _ in verb == .insert ? self.lostAnswer : nil }
        await service.syncEvents([e], kind: "calendar")
        server.dropResponseWhen = nil
        XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString), "the POST landed; only its answer was lost")

        await service.syncEvents([], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).count, 1, "the local delete must reach the server")
        XCTAssertEqual(server.requests(.tombstone).first?.keys, [e.id.uuidString])
        XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString), "other devices see the delete")
        XCTAssertNil(entry(e), "a 2xx tombstone clears the entry")
    }

    /// The echo-wait path of G23 when the first tombstone does not get
    /// out: the delete is owed until a tombstone lands, so the `?` entry
    /// must outlive the awaitingEcho sweep and the failed request.
    func testG23_echoWaitRowDeletedLocallyWhoseFirstTombstoneNeverLeft_isResentOnTheNextFlush_killsSweepDropsBaselineKey() async throws {
        let e = makeEvent("gone before its echo, offline")
        server.seed(table: "events", rows: [service.eventToRow(e, kind: "calendar")])
        await service.syncEvents([e], kind: "calendar")
        let key = SyncBaselineKey(table: "calendar_events", id: e.id.uuidString)
        XCTAssertEqual(service.awaitingEcho, [key], "the POST answered []: the row is in the echo wait")
        XCTAssertEqual(entry(e), .unknown(seq: nil))

        server.failWhen = { verb, _ in verb == .tombstone ? URLError(.notConnectedToInternet) : nil }
        await service.syncEvents([], kind: "calendar")
        server.failWhen = nil

        XCTAssertEqual(server.requests(.tombstone).count, 1)
        XCTAssertFalse(server.isTombstoned(table: "events", key: e.id.uuidString), "the request never left")
        XCTAssertTrue(service.awaitingEcho.isEmpty, "the echo bookkeeping lets go of a row that left the local array")
        XCTAssertEqual(entry(e), .unknown(seq: nil), "the delete is still owed; the mutant dropped the entry in the sweep")
        XCTAssertEqual(SyncBaselineStore(defaults: defaults, userId: uid).entry(table: "calendar_events", id: e.id.uuidString),
                       .unknown(seq: nil), "persisted: a relaunch still owes the delete")

        await service.syncEvents([], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).map(\.keys), [[e.id.uuidString], [e.id.uuidString]], "resent on the next flush")
        XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString), "other devices see the delete")
        XCTAssertNil(entry(e))
    }

    func testPostAnswerLostLeavesTheMarkerWithNoSeqAndTheNextFlushPostsAgainIntoTheEchoWait() async throws {
        let e = makeEvent("posted twice")
        server.dropResponseWhen = { verb, _ in verb == .insert ? self.lostAnswer : nil }
        await service.syncEvents([e], kind: "calendar")
        server.dropResponseWhen = nil
        XCTAssertEqual(entry(e), .unknown(seq: nil))
        XCTAssertEqual(SyncBaselineStore(defaults: defaults, userId: uid).entry(table: "calendar_events", id: e.id.uuidString),
                       .unknown(seq: nil), "persisted: a relaunch still owes the verification")

        await service.syncEvents([e], kind: "calendar")

        XCTAssertEqual(server.requests(.insert).count, 2, "seq unknown: ignore-duplicates POST again")
        XCTAssertEqual(service.awaitingEcho, [SyncBaselineKey(table: "calendar_events", id: e.id.uuidString)],
                       "the row was already there, so the second POST answered [] and the echo settles it")
        XCTAssertEqual(entry(e), .unknown(seq: nil))
    }

    // MARK: G10 — the edit put back after a lost PATCH answer

    func testG10_patchLandedAnswerLostThenUserPutsTheOldValueBack_theOldValueReachesTheServer_killsBaselineUntouched() async throws {
        let c0 = makeEvent("X", note: "c0")
        await service.syncEvents([c0], kind: "calendar")
        let s0 = try XCTUnwrap(entry(c0)?.seq)
        var c1 = c0
        c1.note = "c1"
        server.dropResponseWhen = { verb, _ in verb == .patch ? self.lostAnswer : nil }
        await service.syncEvents([c1], kind: "calendar")
        server.dropResponseWhen = nil
        let s5 = try XCTUnwrap(server.seq(table: "events", key: c0.id.uuidString))
        XCTAssertGreaterThan(s5, s0, "the PATCH committed")
        XCTAssertEqual(entry(c0), .unknown(seq: s0), "result unknown: `?`, seq kept")

        // The user puts c0 back (an undo writes the old bytes back).
        await service.syncEvents([c0], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).count, 2, "the mutant reads c0 as clean here and sends nothing")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s0)
        let key = SyncBaselineKey(table: "calendar_events", id: c0.id.uuidString)
        XCTAssertTrue(service.pendingVerify.contains(key), "seq=eq.s0 against s5 → []")

        // The pull delivers X@s5 (c1, this device's own lost write). The
        // applier's dirty branch: c1 to the shelf, base := (h_in, s5).
        let c1Hash = SupabaseSyncService.rowHash(service.eventToRow(c1, kind: "calendar"))
        service.baseline.setEntry(SyncBaselineEntry(hash: c1Hash, seq: s5), table: "calendar_events", id: c0.id.uuidString)
        service.resolvePendingVerifyAtHead(seen: [key], pullIssue: 1)

        await service.syncEvents([c0], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s5)
        XCTAssertEqual(server.row(table: "events", key: c0.id.uuidString)?.data["note"] as? String, "c0",
                       "the user's last intent is on the server")
    }

    /// The marker is written at SEND time, whatever the outcome: a request
    /// that never left keeps it too (design §6 结果未知的写, "抛错……什么都不写:
    /// `?` 留着"), and the next flush sends again on the same seq.
    func testPatchThatNeverLeftTheDeviceKeepsTheSendMarkerAndIsResent() async throws {
        let e = makeEvent("X", note: "c0")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        var edited = e
        edited.note = "c1"
        server.failWhen = { verb, _ in verb == .patch ? URLError(.notConnectedToInternet) : nil }

        await service.syncEvents([edited], kind: "calendar")

        XCTAssertEqual(entry(e), .unknown(seq: s0))
        server.failWhen = nil
        await service.syncEvents([edited], kind: "calendar")
        XCTAssertEqual(server.row(table: "events", key: e.id.uuidString)?.data["note"] as? String, "c1")
    }

    func testHttpStatusWritesNothingMoreThanTheSendMarker() async throws {
        let e = makeEvent("X", note: "c0")
        await service.syncEvents([e], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        var edited = e
        edited.note = "c1"
        server.failWhen = { verb, _ in
            verb == .patch ? SupabaseREST.SyncError.requestFailed(table: "events", method: "PATCH", status: 503, code: nil) : nil
        }

        await service.syncEvents([edited], kind: "calendar")

        XCTAssertEqual(entry(e), .unknown(seq: s0), "a 503 writes nothing; the send's `?` stays and seq does not move")
    }

    // MARK: Tombstones whose answer was lost

    func testTombstoneAnswerLostThenRowStaysDeleted_theTombstoneIsResentAndClears() async throws {
        let gone = makeEvent("gone"), keep = makeEvent("keep")
        await service.syncEvents([gone, keep], kind: "calendar")
        let s0 = try XCTUnwrap(entry(gone)?.seq)
        server.dropResponseWhen = { verb, _ in verb == .tombstone ? self.lostAnswer : nil }

        await service.syncEvents([keep], kind: "calendar")
        server.dropResponseWhen = nil

        XCTAssertTrue(server.isTombstoned(table: "events", key: gone.id.uuidString), "it landed")
        XCTAssertEqual(entry(gone), .unknown(seq: s0))

        await service.syncEvents([keep], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).count, 2)
        XCTAssertNil(entry(gone), "the resend's 2xx (empty body: already dead) clears it")
    }

    /// Survey S4's restored-tombstone case. The server holds the tombstone; the restored
    /// row reads dirty and goes out on its old seq, which the tombstone
    /// moved, so the PATCH answers [] and the pull that follows brings the
    /// tombstone back. Whether the undo survives that is S2 / #140 (pending
    /// user decision); this pins only that the row is not silently clean.
    func testTombstoneAnswerLostThenRowRestoredLocally_readsDirtyAndIsReverified_killsBaselineUntouched() async throws {
        let e = makeEvent("merged away"), keep = makeEvent("keep")
        await service.syncEvents([e, keep], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        server.dropResponseWhen = { verb, _ in verb == .tombstone ? self.lostAnswer : nil }
        await service.syncEvents([keep], kind: "calendar")
        server.dropResponseWhen = nil
        let patchesBefore = server.requests(.patch).count

        // Undo: the same bytes come back.
        await service.syncEvents([e, keep], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).count, patchesBefore + 1, "the mutant reads the restored row as clean and sends nothing")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s0)
        XCTAssertTrue(service.pendingVerify.contains(SyncBaselineKey(table: "calendar_events", id: e.id.uuidString)))
        XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString), "a PATCH never clears a tombstone (I6)")
    }

    // MARK: Single-row tables

    func testSettingsPatchAnswerLostMarksTheChangedKeysSoPuttingThemBackIsStillSent() async throws {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await service.syncSettings()
        let s0 = try XCTUnwrap(service.baseline.settings?.seq)
        guard case .versioned(_, let keysBefore, _)? = service.baseline.settings else { return XCTFail("versioned expected") }
        defaults.set(false, forKey: AppSettingsKeys.showTimerBanner)
        server.dropResponseWhen = { verb, table in verb == .patch && table == "user_settings" ? self.lostAnswer : nil }

        await service.syncSettings()
        server.dropResponseWhen = nil

        guard case .versioned(let seq, let keys, _)? = service.baseline.settings else { return XCTFail("versioned expected") }
        XCTAssertEqual(seq, s0)
        XCTAssertEqual(keys[AppSettingsKeys.showTimerBanner], SyncBaselineEntry.unknownHash)
        XCTAssertEqual(keys.filter { $0.key != AppSettingsKeys.showTimerBanner }, keysBefore.filter { $0.key != AppSettingsKeys.showTimerBanner },
                       "only the key the write changed is marked")

        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        let patchesBefore = server.requests(.patch, table: "user_settings").count
        await service.syncSettings()
        XCTAssertEqual(server.requests(.patch, table: "user_settings").count, patchesBefore + 1, "the old value put back is still sent")
    }

    func testScalarTablePatchAnswerLostLeavesTheMarkerAtTheKnownSeq() async throws {
        let prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SyncUnknownResultTests-prefs-\(UUID().uuidString)", isDirectory: true))
        await service.syncAgentPreferences(prefs)
        let s0 = try XCTUnwrap(service.baseline.entry(table: "agent_preferences", id: uid)?.seq)
        // Force a dirty row without touching the store: a stale baseline hash.
        service.baseline.setEntry(SyncBaselineEntry(hash: "0ld3nc0d1ng00000", seq: s0), table: "agent_preferences", id: uid)
        server.dropResponseWhen = { verb, table in verb == .patch && table == "agent_preferences" ? self.lostAnswer : nil }

        await service.syncAgentPreferences(prefs)

        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid), .unknown(seq: s0))
    }
}

/// Counts writes per key, to show the send-time marker costs one write per
/// table and lands before the first request.
private final class WriteCountingDefaults: UserDefaults {
    nonisolated(unsafe) var writes: [String: Int] = [:]

    nonisolated override func set(_ value: Any?, forKey defaultName: String) {
        writes[defaultName, default: 0] += 1
        super.set(value, forKey: defaultName)
    }
}
