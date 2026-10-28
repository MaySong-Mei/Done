//
//  AgentPreferencesTokenFreeSyncTests.swift
//  DoneTests
//
//  The agent_preferences row without its token-inference columns
//  (`SupabaseSyncService.agentPreferencesTokenColumns`): never sent, not
//  even as null; ignored inbound and by a restore; one token-free
//  projection wherever the row is hashed, so an empty device still adopts
//  the account's rules (gh#257 QA-5); and the upgrade from a baseline an
//  older build hashed WITH the columns, pull-first and push-first.
//
//  Devices are an EventStore + engine + puller + preference store over
//  their own storage and one `SyncFakeServer`. A row "an older build
//  pushed" is built here, column by column, the way that build sent it —
//  never through the engine's own legacy hash, which is what is under test.
//

import XCTest
@testable import Done

@MainActor
final class AgentPreferencesTokenFreeSyncTests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let uid = "7a7a7a7a-0000-4000-8000-0000000000a1"
    private var server: SyncFakeServer!
    private var devices: [Device] = []
    private var scratch: [URL] = []

    final class Device {
        let suite: String
        let defaults: UserDefaults
        let store: EventStore
        let prefs: AgentPreferenceStore
        let service: SupabaseSyncService
        let puller: SyncPuller
        let shelf: ConflictShelf

        init(suite: String, defaults: UserDefaults, store: EventStore, prefs: AgentPreferenceStore,
             service: SupabaseSyncService, puller: SyncPuller, shelf: ConflictShelf) {
            self.suite = suite
            self.defaults = defaults
            self.store = store
            self.prefs = prefs
            self.service = service
            self.puller = puller
            self.shelf = shelf
        }
    }

    override func setUp() {
        super.setUp()
        server = SyncFakeServer(userId: uid)
    }

    override func tearDown() {
        for device in devices {
            device.puller.endSession()
            TestStorage.tearDown(device.suite)
        }
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        devices = []
        scratch = []
        server = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func scratchDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPrefsTokenFree-\(name)-\(UUID().uuidString)", isDirectory: true)
        scratch.append(url)
        return url
    }

    /// `localTokens` is the token state the device holds, as the upgrade
    /// transition reads it.
    private func makeDevice(rules: [AgentPreferenceRule] = [], decisions: [AgentDecisionRecord] = [],
                            localTokens: TokenInferenceRepository.Snapshot = ([], [], [])) -> Device {
        let suite = "AgentPrefsTokenFree-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        let prefs = AgentPreferenceStore(directoryURL: scratchDirectory("prefs"))
        if !rules.isEmpty || !decisions.isEmpty {
            XCTAssertTrue(prefs.applyRestore(rules: rules, decisionHistory: decisions,
                                             strategy: .cloudOverwritesLocal, resolution: .keepCloud), "fixture")
        }
        let service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: defaults,
                                          scheduler: SyncManualScheduler())
        service.legacyTokenState = { localTokens }
        service.attachStores(eventStore: store, eventTypeStore: nil, skillStore: nil, preferenceStore: prefs)
        let shelf = ConflictShelf(directory: scratchDirectory("shelf"))
        let puller = service.installInbound(shelf: shelf)
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()
        puller.beginSession(autoPull: false)
        let device = Device(suite: suite, defaults: defaults, store: store, prefs: prefs,
                            service: service, puller: puller, shelf: shelf)
        devices.append(device)
        return device
    }

    private func rule(_ value: String) -> AgentPreferenceRule {
        AgentPreferenceRule(scope: .eventTypeMapping,
                            triggerPattern: .init(kind: .exactEventTypeTitle, value: value),
                            preferredAction: .init(kind: .keepTypeOnly, value: nil),
                            source: .explicitSelection, lastUsedAt: Self.t0)
    }

    private func decision(_ summary: String) -> AgentDecisionRecord {
        AgentDecisionRecord(
            requestSnapshot: AgentDecisionRequest(
                kind: .missingEventTypeTemplate, title: "Create template?", message: summary, options: [],
                context: AgentDecisionContext(domain: .calendar, operationID: UUID(), sourceScreen: "test",
                                              payloadSummary: summary, metadata: [:])),
            resultKind: .selected, resolvedAt: Self.t0, appliedActionSummary: summary, wasDefaulted: false)
    }

    /// A token state no other fixture shares: its ids carry `label`.
    private func tokens(_ label: String) -> TokenInferenceRepository.Snapshot {
        let dynamic = TokenDynamicHypothesisRecord(
            id: "dynamic-\(label)", category: .state, statement: "statement \(label)", confidence: 0.5, weight: 0.5,
            windowStart: Self.t0, windowEnd: Self.t0.addingTimeInterval(86_400), relatedOccurrenceKeys: [],
            rationale: "rationale \(label)", derivedFromIDs: [], status: .active, updatedAt: Self.t0)
        let meta = TokenMetaHypothesisRecord(
            kind: .inputSparse, confidence: 0.4, windowStart: Self.t0, windowEnd: Self.t0.addingTimeInterval(86_400),
            rationale: "meta \(label)", status: .active, updatedAt: Self.t0)
        return ([dynamic], [meta], [])
    }

    /// A slice as an older build sent it (`encodeJSONOrNull`): the JSON of
    /// the array, or null when empty.
    private func wire<T: Encodable>(_ value: [T]) throws -> Any {
        guard !value.isEmpty else { return NSNull() }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    /// The row an older build pushed: today's columns plus the three token
    /// columns.
    private func olderBuildRow(_ service: SupabaseSyncService, rules: [AgentPreferenceRule],
                               decisions: [AgentDecisionRecord] = [],
                               tokens: TokenInferenceRepository.Snapshot) throws -> [String: Any] {
        var row = service.agentPreferencesRow(rules: rules, decisionHistory: decisions)
        row["token_dynamic_hypotheses"] = try wire(tokens.dynamic)
        row["token_meta_hypotheses"] = try wire(tokens.meta)
        row["token_projections"] = try wire(tokens.projections)
        return row
    }

    private func tokenFreeHash(_ device: Device, _ rules: [AgentPreferenceRule],
                               _ decisions: [AgentDecisionRecord] = []) -> String {
        SupabaseSyncService.rowHash(device.service.agentPreferencesRow(rules: rules, decisionHistory: decisions))
    }

    private func entry(_ device: Device) -> SyncBaselineEntry? {
        device.service.baseline.entry(table: "agent_preferences", id: uid)
    }

    /// Every request that touched the preferences table: the pulls read the
    /// feed (`sync_changes`), so these are writes.
    private func preferenceWrites() -> [SyncFakeServer.Request] {
        server.requests.filter { $0.table == "agent_preferences" }
    }

    private func serverColumn(_ column: String) -> Any? {
        server.row(table: "agent_preferences", key: uid)?.data[column]
    }

    private func canonical(_ value: Any?) -> String {
        guard let value else { return "absent" }
        if value is NSNull { return "null" }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The device's own token state where it lives: the shared repository's
    /// three keys in the host's defaults, and its memory.
    private func ownTokenState() -> [String] {
        let keys = ["tokenInferenceDynamicHypotheses.v2", "tokenInferenceMetaHypotheses.v2",
                    TokenInferenceRepository.projectionKey]
        let snapshot = TokenInferenceRepository.shared.snapshot()
        return keys.map { UserDefaults.standard.data(forKey: $0)?.base64EncodedString() ?? "absent" }
            + [snapshot.dynamic.map(\.id).joined(separator: ","),
               snapshot.meta.map(\.id).joined(separator: ","),
               snapshot.projections.map(\.id).joined(separator: ",")]
    }

    private func trailCount(_ needle: String) -> Int {
        DiagnosticTrail.combinedText().components(separatedBy: needle).count - 1
    }

    /// A device an older build left in step with the server's row: the
    /// server holds `rules` with `serverTokens`, the device holds `rules`,
    /// and its baseline is the hash of the server row WITH the token
    /// columns at the row's seq — what that build wrote. The cursor and
    /// epoch come from a real pull.
    private func olderBuildSyncedDevice(rules: [AgentPreferenceRule], serverTokens: TokenInferenceRepository.Snapshot,
                                        localTokens: TokenInferenceRepository.Snapshot) async throws -> (Device, Int64) {
        let device = makeDevice(rules: rules, localTokens: localTokens)
        let row = try olderBuildRow(device.service, rules: rules, tokens: serverTokens)
        let seq = try XCTUnwrap(server.seed(table: "agent_preferences", rows: [row])[uid])
        await device.puller.pullToHead()
        var synced = try XCTUnwrap(entry(device), "fixture: the pull wrote a baseline")
        XCTAssertEqual(synced.seq, seq, "fixture")
        synced.hash = SupabaseSyncService.rowHash(row)
        XCTAssertNotEqual(synced.hash, tokenFreeHash(device, rules), "fixture: the legacy hash is not the token-free one")
        device.service.baseline.setEntry(synced, table: "agent_preferences", id: uid)
        device.service.baseline.persist()
        XCTAssertTrue(device.shelf.entries().isEmpty, "fixture")
        XCTAssertTrue(preferenceWrites().isEmpty, "fixture")
        return (device, seq)
    }

    // MARK: - (i) Outbound

    /// The row has exactly today's columns: no token key, not even null.
    func testTheOutboundRowCarriesNoTokenColumnNotEvenNull() {
        let device = makeDevice(rules: [rule("gym")], localTokens: tokens("local"))
        let row = device.service.agentPreferencesToRow(device.prefs)
        XCTAssertEqual(row.keys.sorted(), ["decision_history", "rules", "synced_at", "updated_at", "user_id"])
        for column in SupabaseSyncService.agentPreferencesTokenColumns {
            XCTAssertNil(row[column], "\(column) absent, not null")
        }
        let adapter = AgentPreferencesSyncAdapter(engine: device.service, store: device.prefs)
        XCTAssertEqual(adapter.localRow().keys.sorted(), row.keys.sorted(), "the applier's local row is the same projection")
        XCTAssertEqual(adapter.emptyRow()?.keys.sorted(), row.keys.sorted(), "and so is the empty row (gh#257)")
    }

    /// A first upload (insert) and a later edit (conditional PATCH) both go
    /// out without the token columns; the server keeps the ones an older
    /// build wrote, byte for byte; each push leaves its trail line.
    func testPushesCarryNoTokenColumnAndLeaveTheServersColumnsAsTheyWere() async throws {
        let fresh = makeDevice(rules: [rule("gym")])
        let pushLinesBefore = trailCount("sync.push.agent_preferences ")
        await fresh.puller.pullToHead()
        await fresh.service.syncAgentPreferences(fresh.prefs)
        let insert = try XCTUnwrap(server.requests(.insert, table: "agent_preferences").first)
        let insertBody = try XCTUnwrap((insert.body as? [[String: Any]])?.first)
        for column in SupabaseSyncService.agentPreferencesTokenColumns {
            XCTAssertNil(insertBody[column], "insert: \(column) absent, not null")
        }
        XCTAssertEqual(trailCount("sync.push.agent_preferences "), pushLinesBefore + 1)
        XCTAssertGreaterThan(trailCount("columns=decision_history,rules,synced_at,updated_at,user_id"), 0)

        // An older build overwrites the row, token columns included.
        let older = try olderBuildRow(fresh.service, rules: [rule("gym")], tokens: tokens("older-\(UUID())"))
        server.writeDirectly(table: "agent_preferences", key: uid, data: older)
        await fresh.puller.pullToHead()
        let tokenColumnsBefore = SupabaseSyncService.agentPreferencesTokenColumns.map { canonical(serverColumn($0)) }
        XCTAssertFalse(tokenColumnsBefore.contains("absent"), "fixture: the server holds token columns")

        // This device edits its rules: a PATCH.
        fresh.prefs.recordDecision(decision("edit"))
        await fresh.service.syncAgentPreferences(fresh.prefs)
        let patch = try XCTUnwrap(server.requests(.patch, table: "agent_preferences").last)
        let patchBody = try XCTUnwrap(patch.body as? [String: Any])
        for column in SupabaseSyncService.agentPreferencesTokenColumns {
            XCTAssertNil(patchBody[column], "patch: \(column) absent, not null")
        }
        XCTAssertEqual((serverColumn("decision_history") as? [Any])?.count, 1, "the edit landed")
        XCTAssertEqual(SupabaseSyncService.agentPreferencesTokenColumns.map { canonical(serverColumn($0)) }, tokenColumnsBefore,
                       "columns not sent are left as they were")
        XCTAssertEqual(trailCount("sync.push.agent_preferences "), pushLinesBefore + 2)
    }

    // MARK: - (ii) An older build's token-only change

    /// A peer on an older build changes only its token columns: no shelf
    /// line, nothing applied to this device's token state, no push back,
    /// rules untouched, and the ignored columns are on the trail.
    func testAnOlderPeersTokenOnlyChangeIsNoChange() async throws {
        let mine = [rule("gym")]
        let device = makeDevice(rules: mine, localTokens: tokens("local"))
        let first = try olderBuildRow(device.service, rules: mine, tokens: tokens("server"))
        server.seed(table: "agent_preferences", rows: [first])
        await device.puller.pullToHead()
        XCTAssertEqual(entry(device)?.hash, tokenFreeHash(device, mine), "fixture: in step, token-free")
        let ownTokensBefore = ownTokenState()
        let peerTokens = tokens("peer-\(UUID())")
        let s1 = server.writeDirectly(table: "agent_preferences", key: uid,
                                      data: try olderBuildRow(device.service, rules: mine, tokens: peerTokens))
        let ignoredLine = "sync.apply.ignored_columns table=agent_preferences seq=\(s1) columns=token_dynamic_hypotheses,token_meta_hypotheses\n"
        let ignoredBefore = trailCount(ignoredLine)

        await device.puller.pullToHead()

        XCTAssertTrue(device.shelf.entries().isEmpty, "no shelf line")
        XCTAssertEqual(device.prefs.rules.map(\.id), mine.map(\.id), "rules untouched")
        XCTAssertEqual(entry(device), SyncBaselineEntry(hash: tokenFreeHash(device, mine), seq: s1),
                       "the peer's version is the baseline's, read as the same rules")
        XCTAssertEqual(ownTokenState(), ownTokensBefore, "nothing written to this device's token state")
        XCTAssertFalse(TokenInferenceRepository.shared.snapshot().dynamic.contains { $0.id == peerTokens.dynamic[0].id })
        XCTAssertEqual(trailCount(ignoredLine), ignoredBefore + 1, "the ignored columns are on the trail")

        await device.service.syncAgentPreferences(device.prefs)
        XCTAssertTrue(preferenceWrites().isEmpty, "no push back")
    }

    // MARK: - (iii) The upgrade from a token-hashed baseline

    /// Pull first: the device is in step under the old hash and a peer
    /// changes the rules. The entry is explained by the device's own rules
    /// and token state, re-hashed, and the peer's rules are adopted — the
    /// mutant that reads the legacy hash as it is shelves them and keeps
    /// the old rules.
    func testUpgradePullFirst_aPeersRulesChangeIsAdoptedNotShelved_killsLegacyBaseReadAsAnEdit() async throws {
        let mine = [rule("gym")]
        let synced = tokens("synced")
        let (device, _) = try await olderBuildSyncedDevice(rules: mine, serverTokens: synced, localTokens: synced)
        let theirs = [rule("gym"), rule("swim")]
        let s1 = server.writeDirectly(table: "agent_preferences", key: uid,
                                      data: try olderBuildRow(device.service, rules: theirs, tokens: tokens("peer")))
        let ownTokensBefore = ownTokenState()

        await device.puller.pullToHead()

        XCTAssertEqual(device.prefs.rules.map(\.id), theirs.map(\.id), "adopted")
        XCTAssertTrue(device.shelf.entries().isEmpty, "no shelf line")
        XCTAssertEqual(entry(device), SyncBaselineEntry(hash: tokenFreeHash(device, theirs), seq: s1))
        XCTAssertEqual(ownTokenState(), ownTokensBefore)
        await device.service.syncAgentPreferences(device.prefs)
        XCTAssertTrue(preferenceWrites().isEmpty, "nothing pushed: clean")
    }

    /// Pull first, and the device's token state moved since its baseline
    /// was written, so nothing can explain the entry: a peer change that
    /// touches only the tokens is still no conflict (the token-free
    /// projections match).
    func testUpgradePullFirst_unexplainedEntry_aTokenOnlyChangeIsStillNoConflict() async throws {
        let mine = [rule("gym")]
        let (device, _) = try await olderBuildSyncedDevice(rules: mine, serverTokens: tokens("synced"),
                                                           localTokens: tokens("moved-since"))
        let s1 = server.writeDirectly(table: "agent_preferences", key: uid,
                                      data: try olderBuildRow(device.service, rules: mine, tokens: tokens("peer")))

        await device.puller.pullToHead()

        XCTAssertTrue(device.shelf.entries().isEmpty)
        XCTAssertEqual(device.prefs.rules.map(\.id), mine.map(\.id))
        XCTAssertEqual(entry(device), SyncBaselineEntry(hash: tokenFreeHash(device, mine), seq: s1))
    }

    /// The residual case, pinned: nothing explains the entry AND the peer
    /// changed the rules. The table cannot tell whose rules moved, so it is
    /// the §6 conflict it always was — the local rules kept, the peer's row
    /// on the shelf. Nothing is overwritten in either direction.
    func testUpgradePullFirst_unexplainedEntryAndAPeerRulesChange_isAConflictThatLosesNothing() async throws {
        let mine = [rule("gym")]
        let (device, _) = try await olderBuildSyncedDevice(rules: mine, serverTokens: tokens("synced"),
                                                           localTokens: tokens("moved-since"))
        let theirs = [rule("swim")]
        let s1 = server.writeDirectly(table: "agent_preferences", key: uid,
                                      data: try olderBuildRow(device.service, rules: theirs, tokens: tokens("peer")))
        let missesBefore = trailCount("sync.baseline.token_free table=agent_preferences matched=none")

        await device.puller.pullToHead()

        XCTAssertEqual(device.prefs.rules.map(\.id), mine.map(\.id), "local kept")
        let shelved = try XCTUnwrap(device.shelf.entries().first { $0.table == "agent_preferences" })
        XCTAssertEqual(shelved.seq, s1)
        XCTAssertEqual((shelved.row["rules"] as? [[String: Any]])?.count, 1, "the peer's rules are on the shelf")
        XCTAssertEqual(trailCount("sync.baseline.token_free table=agent_preferences matched=none"), missesBefore + 1,
                       "the miss is on the trail")
    }

    /// Push first: the device is in step under the old hash. Its flush
    /// re-hashes the entry (same seq) and sends nothing; a peer's rules
    /// change that follows is adopted, not shelved.
    func testUpgradePushFirst_inStep_sendsNothingAndThenAdoptsThePeer() async throws {
        let mine = [rule("gym")]
        let synced = tokens("synced")
        let (device, s0) = try await olderBuildSyncedDevice(rules: mine, serverTokens: synced, localTokens: synced)
        let matchedBefore = trailCount("sync.baseline.token_free table=agent_preferences matched=local seq=\(s0)")

        await device.service.syncAgentPreferences(device.prefs)

        XCTAssertTrue(preferenceWrites().isEmpty, "nothing sent")
        XCTAssertEqual(entry(device), SyncBaselineEntry(hash: tokenFreeHash(device, mine), seq: s0), "same version, re-hashed")
        XCTAssertEqual(SyncBaselineStore(defaults: device.defaults, userId: uid).entry(table: "agent_preferences", id: uid),
                       entry(device), "and persisted")
        XCTAssertEqual(trailCount("sync.baseline.token_free table=agent_preferences matched=local seq=\(s0)"), matchedBefore + 1)

        let theirs = [rule("gym"), rule("swim")]
        server.writeDirectly(table: "agent_preferences", key: uid,
                             data: try olderBuildRow(device.service, rules: theirs, tokens: tokens("peer")))
        await device.puller.pullToHead()
        XCTAssertEqual(device.prefs.rules.map(\.id), theirs.map(\.id))
        XCTAssertTrue(device.shelf.entries().isEmpty)
    }

    /// Push first, nothing explains the entry (the token state moved): one
    /// small token-free push on the entry's seq. It changes no rule on the
    /// server, leaves the token columns as they were, shelves nothing, and
    /// the next flush sends nothing.
    func testUpgradePushFirst_unexplainedEntry_onePushThatOverwritesNothing() async throws {
        let mine = [rule("gym")]
        let synced = tokens("synced")
        let (device, s0) = try await olderBuildSyncedDevice(rules: mine, serverTokens: synced,
                                                            localTokens: tokens("moved-since"))
        let rulesBefore = canonical(serverColumn("rules"))
        let tokenColumnsBefore = SupabaseSyncService.agentPreferencesTokenColumns.map { canonical(serverColumn($0)) }

        await device.service.syncAgentPreferences(device.prefs)
        await device.puller.pullToHead()

        let writes = preferenceWrites()
        XCTAssertEqual(writes.count, 1, "one push")
        XCTAssertEqual(writes.first?.verb, .patch)
        XCTAssertEqual(writes.first?.baseSeq, s0, "conditional on the version the entry names")
        XCTAssertEqual(canonical(serverColumn("rules")), rulesBefore, "no rule changed on the server")
        XCTAssertEqual(SupabaseSyncService.agentPreferencesTokenColumns.map { canonical(serverColumn($0)) }, tokenColumnsBefore)
        XCTAssertTrue(device.shelf.entries().isEmpty)
        XCTAssertEqual(device.prefs.rules.map(\.id), mine.map(\.id))

        await device.service.syncAgentPreferences(device.prefs)
        XCTAssertEqual(preferenceWrites().count, 1, "the next flush sends nothing")
    }

    // MARK: - (iv) gh#257 QA-5

    /// A fresh device with nothing and no baseline signs in to an account
    /// whose row an older build wrote: the account's rules are adopted and
    /// nothing is pushed over them.
    func testAFreshEmptyDeviceAdoptsTheAccountsRulesAndPushesNothing() async throws {
        let device = makeDevice(localTokens: tokens("this-device"))
        let account = [rule("gym"), rule("swim")]
        let row = try olderBuildRow(device.service, rules: account, decisions: [decision("account")], tokens: tokens("account"))
        let seq = try XCTUnwrap(server.seed(table: "agent_preferences", rows: [row])[uid])
        XCTAssertNil(entry(device), "fixture: no baseline")

        await device.puller.pullToHead()
        await device.service.syncAgentPreferences(device.prefs)

        XCTAssertEqual(device.prefs.rules.map(\.id), account.map(\.id))
        XCTAssertEqual(device.prefs.decisionHistory.count, 1)
        XCTAssertTrue(device.shelf.entries().isEmpty)
        XCTAssertTrue(preferenceWrites().isEmpty, "the empty row is not pushed over the account's")
        XCTAssertEqual(server.seq(table: "agent_preferences", key: uid), seq)
        XCTAssertEqual((serverColumn("rules") as? [Any])?.count, 2)
    }

    // MARK: - (v) Restore

    /// "Restore from Cloud" over a row an older build wrote: the rules and
    /// the history land, the token state does not, and the restored row
    /// reads clean in the token-free projection.
    func testARestoreAppliesRulesAndHistoryButNotTheTokenState() async throws {
        let suite = "AgentPrefsTokenFree-restore-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defer { TestStorage.tearDown(suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        let prefs = AgentPreferenceStore(directoryURL: scratchDirectory("restore-prefs"))
        let types = EventTypeTemplateStore(defaults: defaults)
        let skills = SkillInsightStore(defaults: defaults)
        let service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
        service.attachStores(eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)

        let cloudRules = [rule("cloud")]
        let cloudDecision = decision("cloud")
        let cloudTokens = tokens("cloud-\(UUID())")
        let seq = try XCTUnwrap(server.seed(table: "agent_preferences", rows: [
            try olderBuildRow(service, rules: cloudRules, decisions: [cloudDecision], tokens: cloudTokens),
        ])[uid])
        let start = Self.t0
        server.seed(table: "events", rows: [service.eventToRow(
            Event(title: "cloud", timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))]), kind: "calendar")])
        let ownTokensBefore = ownTokenState()
        let ignoredBefore = trailCount("restore.ignored_columns table=agent_preferences")

        let coordinator = RestoreCoordinator()
        coordinator.configure(syncService: service, eventStore: store, eventTypeStore: types,
                              skillStore: skills, preferenceStore: prefs)
        await coordinator.startFetch()
        await coordinator.prepareMerge()
        guard case .mergeReview = coordinator.phase else {
            return XCTFail("fixture: the cloud event leaves something to review")
        }
        await coordinator.applyMerge(resolution: .keepCloud)
        guard case .finished = coordinator.phase else { return XCTFail("restore finished") }

        XCTAssertEqual(prefs.rules.map(\.id), cloudRules.map(\.id), "rules restored")
        XCTAssertEqual(prefs.decisionHistory.map(\.id), [cloudDecision.id], "history restored")
        XCTAssertEqual(ownTokenState(), ownTokensBefore, "the token state is not restored")
        XCTAssertFalse(TokenInferenceRepository.shared.snapshot().dynamic.contains { $0.id == cloudTokens.dynamic[0].id })
        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid),
                       SyncBaselineEntry(hash: SupabaseSyncService.rowHash(service.agentPreferencesToRow(prefs)), seq: seq),
                       "the restored row reads clean in the token-free projection")
        XCTAssertEqual(trailCount("restore.ignored_columns table=agent_preferences"), ignoredBefore + 1)
    }
}
