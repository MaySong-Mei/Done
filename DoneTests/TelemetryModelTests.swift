//
//  TelemetryModelTests.swift
//  DoneTests
//
//  gh#273 — the chassis's pure half (TelemetryModel.swift), pinned by
//  hand-computed fixtures. Every expectation is stated from the design
//  (00-telemetry-chassis-design.md §4, §7, §8; 01-wire-contract.md), not
//  read off the implementation; each test names the mutant it kills.
//

import XCTest
@testable import Done

// MARK: - Fixtures

enum TelemetryFixtures {
    static let uid = "11111111-2222-4333-8444-555555555555"
    static let otherUID = "99999999-2222-4333-8444-555555555555"
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func run(
        id: UUID = UUID(),
        spikeID: String = FixObservationRegistry.residentDailySpikeID,
        scenarioID: String = FixObservationRegistry.residentDailyScenarioID,
        startedAt: Date = t0,
        endedAt: Date? = t0.addingTimeInterval(60),
        appBuild: String = "12",
        osVersion: String = "26.0",
        buildConfiguration: String? = "release",
        metrics: [String: SpikeMetricValue] = [:],
        note: String? = nil,
        abortReason: SpikeAbortReason? = nil,
        ownerUID: String? = uid,
        kind: TelemetryRecordKind? = .dailyRollup,
        revision: Int? = 1,
        dayKey: String? = "2026-09-21",
        dayTZOffsetMin: Int? = -420,
        coActiveSpikeIDs: [String]? = nil,
        variantID: String? = nil
    ) -> SpikeRun {
        var run = SpikeRun(
            id: id, spikeID: spikeID, scenarioID: scenarioID, variantID: variantID,
            startedAt: startedAt, endedAt: endedAt,
            appVersion: "0.5.0", appBuild: appBuild, appCommit: nil,
            deviceModel: "iPhone17,2", osVersion: osVersion,
            timeZoneIdentifier: "America/Los_Angeles", localeIdentifier: "zh_CN",
            buildConfiguration: buildConfiguration, coActiveSpikeIDs: coActiveSpikeIDs,
            metrics: metrics, note: note, outcome: .completed, abortReason: abortReason
        )
        run.ownerUID = ownerUID
        run.kind = kind
        run.revision = revision
        run.dayKey = dayKey
        run.dayTZOffsetMin = dayTZOffsetMin
        // `installID` is left nil: the store stamps it on append, the wire
        // builder falls back to the current install.
        return run
    }

    static func wireRow(_ run: SpikeRun, userID: String = uid, now: Date = t0) -> [String: Any] {
        TelemetryWire.row(for: run, userID: userID, installID: UUID(), now: now) { _ in ("1970-01-01", 0) }
    }
}

// MARK: - Claim key and day key (§4.2, B·F15/F16/F17)

final class TelemetryClaimKeyTests: XCTestCase {

    /// Mutant: dropping any one component from `==` makes the
    /// corresponding "differs" assertion pass as equal.
    func testClaimKeyIsFullEqualityIncludingNilOwner() {
        let base = TelemetryClaimKey(buildConfiguration: "release", appBuild: "10", osVersion: "26.0", ownerUID: "a")
        XCTAssertEqual(base, TelemetryClaimKey(buildConfiguration: "release", appBuild: "10", osVersion: "26.0", ownerUID: "a"))
        XCTAssertNotEqual(base, TelemetryClaimKey(buildConfiguration: "debug", appBuild: "10", osVersion: "26.0", ownerUID: "a"), "configuration")
        XCTAssertNotEqual(base, TelemetryClaimKey(buildConfiguration: "release", appBuild: "11", osVersion: "26.0", ownerUID: "a"), "build")
        XCTAssertNotEqual(base, TelemetryClaimKey(buildConfiguration: "release", appBuild: "10", osVersion: "26.1", ownerUID: "a"), "OS")
        XCTAssertNotEqual(base, TelemetryClaimKey(buildConfiguration: "release", appBuild: "10", osVersion: "26.0", ownerUID: "b"), "owner")
        XCTAssertNotEqual(base, TelemetryClaimKey(buildConfiguration: "release", appBuild: "10", osVersion: "26.0", ownerUID: nil),
                          "the signed-out partition never claims an account's record")
        XCTAssertEqual(TelemetryClaimKey(buildConfiguration: nil, appBuild: "10", osVersion: "26.0", ownerUID: nil),
                       TelemetryClaimKey(buildConfiguration: nil, appBuild: "10", osVersion: "26.0", ownerUID: nil),
                       "nil == nil: a pre-stamp record is adopted only by a pre-stamp process")
    }

    func testClaimKeyFromARunReadsTheRecordsOwnStamp() {
        let run = TelemetryFixtures.run(appBuild: "10", osVersion: "26.0", buildConfiguration: "release", ownerUID: "a")
        XCTAssertEqual(TelemetryClaimKey(run: run),
                       TelemetryClaimKey(buildConfiguration: "release", appBuild: "10", osVersion: "26.0", ownerUID: "a"))
    }

    /// Hand-computed: 2026-09-21 00:00 in Los Angeles is PDT (UTC−7 → −420
    /// min); the same instant in Tokyo is 16:00 on the same day, and
    /// Tokyo's midnight of that day is a different instant. The key follows
    /// the calendar handed in, never the process zone.
    func testDayKeyFollowsTheCalendarHandedIn() throws {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))

        let laMidnight = try XCTUnwrap(la.date(from: DateComponents(year: 2026, month: 9, day: 21)))
        let laKey = TelemetryClaimKey.dayKey(forDayStart: laMidnight, calendar: la)
        XCTAssertEqual(laKey.dayKey, "2026-09-21")
        XCTAssertEqual(laKey.tzOffsetMin, -420)

        // The same instant, read in Tokyo, is still the 21st (16:00) — but
        // Tokyo's offset, not LA's.
        let sameInstantTokyo = TelemetryClaimKey.dayKey(forDayStart: laMidnight, calendar: tokyo)
        XCTAssertEqual(sameInstantTokyo.dayKey, "2026-09-21")
        XCTAssertEqual(sameInstantTokyo.tzOffsetMin, 540)

        // Winter: PST is −480.
        let winter = try XCTUnwrap(la.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        XCTAssertEqual(TelemetryClaimKey.dayKey(forDayStart: winter, calendar: la).tzOffsetMin, -480)
    }
}

// MARK: - Cursor (§7.2, B·F9/F36)

final class UploadCursorTests: XCTestCase {

    func testPendingIsStrictlyAboveTheAcknowledgedRevisionAndNilRevisionNeverPends() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var cursor = UploadCursor()
        cursor.acknowledge(ids: [(a, 3), (b, 1)])
        let records = [
            TelemetryFixtures.run(id: a, revision: 3),   // equal → not pending
            TelemetryFixtures.run(id: a, revision: 4),   // above → pending
            TelemetryFixtures.run(id: b, revision: 1),   // equal → not pending
            TelemetryFixtures.run(id: c, revision: 1),   // unknown id → pending
            TelemetryFixtures.run(id: d, revision: nil), // pre-chassis line → never
        ]
        let pending = cursor.pending(records, id: \.id, revision: \.revision)
        XCTAssertEqual(pending.map(\.id), [a, c])
        XCTAssertEqual(pending.first?.revision, 4)
    }

    /// Test 3's last clause: a late answer to an older batch must not move
    /// the cursor backwards. Mutant: `uploaded[id] = revision` without the
    /// `max` → the second assertion reads 2.
    func testAcknowledgeNeverRegresses() {
        let id = UUID()
        var cursor = UploadCursor()
        cursor.acknowledge(ids: [(id, 7)])
        cursor.acknowledge(ids: [(id, 2)])
        XCTAssertEqual(cursor.uploaded[id], 7)
        cursor.acknowledge(ids: [(id, 8)])
        XCTAssertEqual(cursor.uploaded[id], 8)
    }

    /// Review P1-2: a quarantined `(id, revision)` is not pending; the same
    /// id at a higher revision is; a cursor file from before `quarantined`
    /// existed still decodes (empty quarantine).
    func testAQuarantinedRevisionIsNotPendingButItsSuccessorIs() throws {
        let id = UUID()
        var cursor = UploadCursor()
        cursor.quarantine(id: id, revision: 2)
        let records = [TelemetryFixtures.run(id: id, revision: 2), TelemetryFixtures.run(id: id, revision: 3)]
        XCTAssertEqual(cursor.pending(records, id: \.id, revision: \.revision).map { $0.revision }, [3])
        cursor.acknowledge(ids: [(id, 3)])
        XCTAssertTrue(cursor.pending(records, id: \.id, revision: \.revision).isEmpty)

        let data = try JSONEncoder().encode(cursor)
        XCTAssertEqual(try JSONDecoder().decode(UploadCursor.self, from: data), cursor)
        let legacy = Data(#"{"uploaded":{"\#(id.uuidString)":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(UploadCursor.self, from: legacy)
        XCTAssertEqual(decoded.uploaded[id], 1)
        XCTAssertTrue(decoded.quarantined.isEmpty, "a pre-quarantine cursor file loads with nothing parked")
    }

    /// Review P2-6: `totalAcknowledged` counts rows, survives the round
    /// trip, defaults to 0 for a pre-existing file, and `prune` keeps only
    /// the ids given — without touching the count.
    func testTotalAcknowledgedIsMonotonicAndPruneKeepsOnlyKnownIDs() throws {
        let live = UUID(), gone = UUID()
        var cursor = UploadCursor()
        cursor.acknowledge(ids: [(live, 1), (gone, 2)])
        cursor.acknowledge(ids: [(live, 2)])
        XCTAssertEqual(cursor.totalAcknowledged, 3, "three rows acknowledged, two distinct ids")
        cursor.quarantine(id: gone, revision: 3)
        cursor.prune(keeping: [live])
        XCTAssertEqual(cursor.uploaded, [live: 2])
        XCTAssertTrue(cursor.quarantined.isEmpty)
        XCTAssertEqual(cursor.totalAcknowledged, 3, "pruning never lowers the cumulative count")
        let data = try JSONEncoder().encode(cursor)
        XCTAssertEqual(try JSONDecoder().decode(UploadCursor.self, from: data), cursor)
        let legacy = try JSONDecoder().decode(UploadCursor.self, from: Data(#"{"uploaded":{}}"#.utf8))
        XCTAssertEqual(legacy.totalAcknowledged, 0)
    }

    func testCursorRoundTripsThroughJSONKeyedByUUIDString() throws {
        let id = UUID()
        let cursor = UploadCursor(uploaded: [id: 5])
        let data = try JSONEncoder().encode(cursor)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let uploaded = try XCTUnwrap(json["uploaded"] as? [String: Int])
        XCTAssertEqual(uploaded[id.uuidString], 5, "a human-readable object, not Swift's alternating array")
        XCTAssertEqual(try JSONDecoder().decode(UploadCursor.self, from: data), cursor)
    }

    /// Design §7.2: a corrupt cursor is an EMPTY cursor — everything
    /// pending, idempotent upsert absorbs it — never "all uploaded" and
    /// never a crash. Positive control: a valid file reads back its entry.
    func testACorruptOrMissingCursorFileReadsAsEmpty() throws {
        let location = SpikeRunStorageLocation.ephemeral(id: UUID())
        defer { try? FileManager.default.removeItem(at: location.directory) }
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: location), UploadCursor(), "missing")

        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: SpikeRunStore.uploadCursorURL(location: location))
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: location), UploadCursor(), "corrupt")

        let id = UUID()
        XCTAssertTrue(SpikeRunStore.saveUploadCursor(UploadCursor(uploaded: [id: 2]), location: location))
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: location).uploaded[id], 2, "positive control")
        let values = try SpikeRunStore.uploadCursorURL(location: location).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "device-local bookkeeping, not backed up (§14)")
    }
}

// MARK: - Server guard (§9.2) — the rule the fake server and SQL share

final class TelemetryServerModelTests: XCTestCase {
    func testOnlyAHigherRevisionApplies() {
        XCTAssertTrue(TelemetryServerModel.apply(existing: nil, incoming: 1), "insert")
        XCTAssertTrue(TelemetryServerModel.apply(existing: 7, incoming: 8))
        XCTAssertFalse(TelemetryServerModel.apply(existing: 7, incoming: 7), "same revision twice → one row, unchanged")
        XCTAssertFalse(TelemetryServerModel.apply(existing: 7, incoming: 5), "7 then 5 → row stays 7")
    }
}

// MARK: - Consent (§8.2) and batch selection (§7.1)

final class TelemetryConsentAndBatchTests: XCTestCase {
    private let t = TelemetryFixtures.t0

    /// Mutant (test 6's named one): remove `$0.startedAt >= consentAt` →
    /// `before` is kept and the first assertion fails.
    func testConsentFilterKeepsOnlyRecordsAtOrAfterTheWatermarkForTheCurrentOwner() {
        let before = TelemetryFixtures.run(startedAt: t.addingTimeInterval(-1))
        let at = TelemetryFixtures.run(startedAt: t)
        let after = TelemetryFixtures.run(startedAt: t.addingTimeInterval(1))
        let other = TelemetryFixtures.run(startedAt: t.addingTimeInterval(2), ownerUID: TelemetryFixtures.otherUID)
        let signedOut = TelemetryFixtures.run(startedAt: t.addingTimeInterval(3), ownerUID: nil)
        let kept = TelemetryConsent.filter([before, at, after, other, signedOut], consentAt: t, currentOwner: TelemetryFixtures.uid)
        XCTAssertEqual(kept.map(\.id), [at.id, after.id])
        XCTAssertTrue(TelemetryConsent.filter([at, after], consentAt: nil, currentOwner: TelemetryFixtures.uid).isEmpty, "no consent → nothing")
        XCTAssertTrue(TelemetryConsent.filter([signedOut], consentAt: t, currentOwner: nil).isEmpty,
                      "no account → nothing; nil must not equal nil here")
    }

    /// Device bug, build 17 — the store keeps whole seconds, consent does
    /// not. A record minted 0.3 s AFTER a consent at t+0.4 is written by the
    /// real store and read back at t: it must still pass. Mutant: compare
    /// against the raw `consentAt` → the record is dropped and this fails.
    func testTheWatermarkIsComparedAtTheStoresWholeSecondGranularity() throws {
        let location = SpikeRunStorageLocation.ephemeral(id: UUID())
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let consentAt = t.addingTimeInterval(0.4)
        let mintedAfter = TelemetryFixtures.run(startedAt: t.addingTimeInterval(0.7), revision: nil)
        let secondBefore = TelemetryFixtures.run(startedAt: t.addingTimeInterval(-0.6), revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(mintedAfter, location: location))
        XCTAssertTrue(SpikeRunStore.finishRun(secondBefore, location: location))
        let onDisk = SpikeRunStore.loadRuns(spikeID: mintedAfter.spikeID, location: location)
        let readBack = try XCTUnwrap(onDisk.first { $0.id == mintedAfter.id })
        XCTAssertEqual(readBack.startedAt, t, "liveness: the store really does drop the fraction")
        XCTAssertLessThan(readBack.startedAt, consentAt, "so the raw comparison would have rejected it")

        let kept = TelemetryConsent.filter(onDisk, consentAt: consentAt, currentOwner: TelemetryFixtures.uid)
        XCTAssertEqual(kept.map(\.id), [mintedAfter.id], "minted after consent → consented; the second before → not")
    }

    func testBackgroundEdgeCarriesEventsAlwaysAndTheDailyOnlyPastFifteenMinutes() {
        let daily = TelemetryFixtures.run(startedAt: t, kind: .dailyRollup)
        let window = TelemetryFixtures.run(spikeID: FixObservationRegistry.effortPathFixID,
                                           scenarioID: FixObservationRegistry.windowScenarioID,
                                           startedAt: t.addingTimeInterval(10), kind: .window)
        let pending = [daily, window]
        let fourteen = t.addingTimeInterval(14 * 60)
        let fifteen = t.addingTimeInterval(15 * 60)

        XCTAssertEqual(TelemetryTrigger.selectBatch(pending, trigger: .backgroundEdge, lastDailyUploadAt: t, now: fourteen).map(\.id),
                       [window.id], "14 min since the last daily → events only")
        XCTAssertEqual(TelemetryTrigger.selectBatch(pending, trigger: .backgroundEdge, lastDailyUploadAt: t, now: fifteen).map(\.id),
                       [window.id, daily.id], "15 min → the daily rides along, after the events")
        XCTAssertEqual(TelemetryTrigger.selectBatch(pending, trigger: .backgroundEdge, lastDailyUploadAt: nil, now: t).map(\.id),
                       [window.id, daily.id], "never uploaded a daily → allowed")
        for trigger in [TelemetryTrigger.launch, .dayRollover, .deckOpen] {
            XCTAssertEqual(TelemetryTrigger.selectBatch(pending, trigger: trigger, lastDailyUploadAt: t, now: t).map(\.id),
                           [window.id, daily.id], "\(trigger) carries everything regardless of the throttle")
        }
    }

    /// Lean decision d: `metricKitDaily` is neither an event nor the daily
    /// rollup — a background edge never carries it, gate open or not, and
    /// it ranks with the dailies (`startedAt` decides between the two).
    /// Decision c: the gate is `>=` — 900 s rides, 899 s waits.
    func testMetricKitDailyNeverRidesTheEdgeAndRanksWithTheDailies() {
        let metricKit = TelemetryFixtures.run(startedAt: t.addingTimeInterval(-7200), kind: .metricKitDaily)
        let daily = TelemetryFixtures.run(startedAt: t.addingTimeInterval(-3600), kind: .dailyRollup)
        let window = TelemetryFixtures.run(startedAt: t, kind: .window)
        let gateOpen = TelemetryTrigger.selectBatch([metricKit, daily, window], trigger: .backgroundEdge, lastDailyUploadAt: nil, now: t)
        XCTAssertEqual(gateOpen.map(\.id), [window.id, daily.id], "gate open: the rollup rides, MetricKit never")
        let gateShut = TelemetryTrigger.selectBatch([metricKit, daily, window], trigger: .backgroundEdge,
                                                    lastDailyUploadAt: t.addingTimeInterval(-899), now: t)
        XCTAssertEqual(gateShut.map(\.id), [window.id], "899 s: the rollup waits")
        let gateEdge = TelemetryTrigger.selectBatch([metricKit, daily, window], trigger: .backgroundEdge,
                                                    lastDailyUploadAt: t.addingTimeInterval(-900), now: t)
        XCTAssertEqual(gateEdge.map(\.id), [window.id, daily.id], "900 s exactly: >= rides")
        let launch = TelemetryTrigger.selectBatch([daily, metricKit, window], trigger: .launch, lastDailyUploadAt: nil, now: t)
        XCTAssertEqual(launch.map(\.id), [window.id, metricKit.id, daily.id], "launch: events, then both daily kinds by startedAt")
        XCTAssertFalse(TelemetryRecordKind.metricKitDaily.isEventRecord)
        XCTAssertFalse(TelemetryRecordKind.dailyRollup.isEventRecord)
        for kind in [TelemetryRecordKind.window, .verdictSnapshot, .manualRun] {
            XCTAssertTrue(kind.isEventRecord, "\(kind)")
        }
    }

    /// Lean decision g: ties (same rank, same `startedAt`) keep input order —
    /// pinned by an explicit index, not by trusting the sort.
    func testTiesKeepInputOrder() {
        let a = TelemetryFixtures.run(startedAt: t, kind: .window)
        let b = TelemetryFixtures.run(startedAt: t, kind: .manualRun)
        let c = TelemetryFixtures.run(startedAt: t, kind: .dailyRollup)
        let d = TelemetryFixtures.run(startedAt: t, kind: .metricKitDaily)
        let e = TelemetryFixtures.run(startedAt: t, kind: .verdictSnapshot)
        XCTAssertEqual(TelemetryTrigger.selectBatch([c, a, d, b, e], trigger: .launch, lastDailyUploadAt: nil, now: t).map(\.id),
                       [a.id, b.id, e.id, c.id, d.id])
        XCTAssertEqual(TelemetryTrigger.selectBatch([e, b, a, d, c], trigger: .launch, lastDailyUploadAt: nil, now: t).map(\.id),
                       [e.id, b.id, a.id, d.id, c.id])
    }

    func testBatchOrderIsEventsThenDailiesEachByStartAndCutAtTheLimit() {
        let d1 = TelemetryFixtures.run(startedAt: t.addingTimeInterval(5), kind: .dailyRollup)
        let d2 = TelemetryFixtures.run(startedAt: t.addingTimeInterval(1), kind: .dailyRollup)
        let w1 = TelemetryFixtures.run(startedAt: t.addingTimeInterval(9), kind: .window)
        let m1 = TelemetryFixtures.run(startedAt: t.addingTimeInterval(3), kind: .manualRun)
        let batch = TelemetryTrigger.selectBatch([d1, w1, d2, m1], trigger: .launch, lastDailyUploadAt: nil, now: t)
        XCTAssertEqual(batch.map(\.id), [m1.id, w1.id, d2.id, d1.id])
        XCTAssertEqual(TelemetryTrigger.selectBatch([d1, w1, d2, m1], trigger: .launch, lastDailyUploadAt: nil, now: t, limit: 2).map(\.id),
                       [m1.id, w1.id])
        XCTAssertEqual(TelemetryTrigger.batchLimit, 32, "wire contract §5")
    }

    func testKindIsInferredForLinesWrittenBeforeTheField() {
        XCTAssertEqual(TelemetryRecordKind.inferred(spikeID: FixObservationRegistry.residentDailySpikeID,
                                                    scenarioID: FixObservationRegistry.residentDailyScenarioID), .dailyRollup)
        XCTAssertEqual(TelemetryRecordKind.inferred(spikeID: FixObservationRegistry.effortPathFixID,
                                                    scenarioID: FixObservationRegistry.windowScenarioID), .window)
        XCTAssertEqual(TelemetryRecordKind.inferred(spikeID: "spike-201-effort-tap", scenarioID: "default"), .manualRun)
        XCTAssertEqual(TelemetryRecordKind.dailyRollup.rawValue, "daily_rollup")
        XCTAssertEqual(TelemetryRecordKind.manualRun.rawValue, "manual_run")
        XCTAssertEqual(TelemetryRecordKind.verdictSnapshot.rawValue, "verdict_snapshot")
        XCTAssertEqual(TelemetryRecordKind.metricKitDaily.rawValue, "metrickit_daily")
        XCTAssertEqual(TelemetryRecordKind.window.rawValue, "window")
    }
}

// MARK: - Abort reason (B·F24)

final class SpikeAbortReasonTests: XCTestCase {
    private func decodeRun(abortReasonJSON: String) throws -> SpikeRun {
        let json = """
        {"id":"\(UUID().uuidString)","spikeID":"s","scenarioID":"sc","startedAt":"2026-09-21T10:00:00Z",
         "appVersion":"1","appBuild":"1","deviceModel":"d","osVersion":"26","timeZoneIdentifier":"UTC",
         "localeIdentifier":"en","metrics":{},"abortReason":\(abortReasonJSON)}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SpikeRun.self, from: Data(json.utf8))
    }

    /// The five literals that were on disk when the enum landed decode to
    /// their case; other text decodes to `legacyUnknown` and KEEPS it —
    /// the line is not dropped (`loadRuns` would otherwise lose it).
    func testLegacyLinesDecodeToTheirCaseOrToLegacyUnknownWithTheTextKept() throws {
        XCTAssertEqual(try decodeRun(abortReasonJSON: "\"manual #201 run took over\"").abortReason, .manualRunTookOver)
        XCTAssertEqual(try decodeRun(abortReasonJSON: "\"process ended before the scenario finished\"").abortReason, .processEnded)
        XCTAssertEqual(try decodeRun(abortReasonJSON: "\"resident deactivated\"").abortReason, .residentDeactivated)
        XCTAssertEqual(try decodeRun(abortReasonJSON: "\"stopped manually before 40 characters\"").abortReason, .stoppedBeforeTarget)
        XCTAssertEqual(try decodeRun(abortReasonJSON: "\"stopped with no effort-scrubber gesture recorded\"").abortReason, .noGestureRecorded)
        let prose = try decodeRun(abortReasonJSON: "\"the user typed this\"")
        XCTAssertEqual(prose.abortReason, .legacyUnknown("the user typed this"))
        XCTAssertNil(prose.abortReason?.wireValue, "legacy text has no wire token — it never leaves the device")
        XCTAssertNil(try decodeRun(abortReasonJSON: "null").abortReason)
    }

    func testKnownCasesRoundTripThroughTheirWireToken() throws {
        for reason in SpikeAbortReason.known {
            let data = try JSONEncoder().encode([reason])
            let back = try JSONDecoder().decode([SpikeAbortReason].self, from: data)
            XCTAssertEqual(back, [reason])
            XCTAssertTrue(SpikeAbortReason.wireValues.contains(try XCTUnwrap(reason.wireValue)))
        }
        XCTAssertEqual(SpikeAbortReason.wireValues.count, 5, "one token per known case, none for legacy")
    }
}

// MARK: - Wire row and Redactor (wire contract §2, B·F24/F37)

final class TelemetryRedactorTests: XCTestCase {
    private let allowed = TelemetryRedactor.observatoryFixedFormatStringKeys

    func testTheWhitelistIsTheObservatorysOwnFixedFormatKeys() {
        XCTAssertEqual(allowed, [
            "tapLagBuckets", "dragLagBuckets",
            "wCommitMs", "wFrameAfterCommitMs", "wLagMs", "wFrameLargestDeltasMs",
        ])
        // And those ARE the keys the writers emit as `.string`.
        var counters = ResidentCounterSet()
        counters.tapLagHistogram.admit(lagMs: 3)
        let stringKeys = counters.metrics.filter { if case .string = $0.value { return true }; return false }.keys
        XCTAssertEqual(Set(stringKeys), ResidentCounterSet.fixedFormatStringKeys)
    }

    /// Opt-out: no free text survives — not in `note`, not as an abort
    /// reason, not as an unregistered `.string` metric. Opt-in: ONLY `note`.
    func testFreeTextLeavesOnlyThroughNoteAndOnlyWhenOptedIn() throws {
        let noteSentinel = "NOTE-\(UUID().uuidString)"
        let abortSentinel = "ABORT-\(UUID().uuidString)"
        let metricSentinel = "METRIC-\(UUID().uuidString)"
        let run = TelemetryFixtures.run(
            metrics: ["freeText": .string(metricSentinel), "tapLagBuckets": .string("0 1 2 3 4 5 6 7"), "tapCount": .number(4)],
            note: noteSentinel,
            abortReason: .legacyUnknown(abortSentinel)
        )
        let raw = TelemetryFixtures.wireRow(run)

        let optOut = TelemetryRedactor.redact(row: raw, noteOptIn: false, allowedStringKeys: allowed)
        let optOutBytes = try JSONSerialization.data(withJSONObject: optOut, options: [.sortedKeys])
        let optOutText = String(decoding: optOutBytes, as: UTF8.self)
        XCTAssertFalse(optOutText.contains(noteSentinel))
        XCTAssertFalse(optOutText.contains(abortSentinel))
        XCTAssertFalse(optOutText.contains(metricSentinel))
        let metrics = try XCTUnwrap(optOut["metrics"] as? [String: Any])
        XCTAssertEqual(metrics["tapLagBuckets"] as? String, "0 1 2 3 4 5 6 7", "a whitelisted fixed-format string stays")
        XCTAssertEqual((metrics["tapCount"] as? NSNumber)?.intValue, 4)
        XCTAssertNil(metrics["freeText"])

        let optIn = TelemetryRedactor.redact(row: raw, noteOptIn: true, allowedStringKeys: allowed)
        let optInText = String(decoding: try JSONSerialization.data(withJSONObject: optIn, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertTrue(optInText.contains(noteSentinel), "positive control: the note switch is what lets a note out")
        XCTAssertFalse(optInText.contains(abortSentinel))
        XCTAssertFalse(optInText.contains(metricSentinel))
    }

    func testContextKeepsOnlyRegistryShapedValuesAndKnownAbortTokens() throws {
        let run = TelemetryFixtures.run(abortReason: .manualRunTookOver, coActiveSpikeIDs: ["spike-195-detail-perf", "has spaces"],
                                        variantID: "B")
        var raw = TelemetryFixtures.wireRow(run)
        var context = try XCTUnwrap(raw["context"] as? [String: Any])
        context["app_commit"] = "0d9efca"
        context["free"] = "prose"
        raw["context"] = context
        raw["surprise_column"] = "anything"

        let out = TelemetryRedactor.redact(row: raw, noteOptIn: false, allowedStringKeys: allowed)
        let outContext = try XCTUnwrap(out["context"] as? [String: Any])
        XCTAssertEqual(outContext["abort_reason"] as? String, "manual_run_took_over")
        XCTAssertEqual(outContext["co_active_spike_ids"] as? [String], ["spike-195-detail-perf"], "an id with a space is not an id")
        XCTAssertEqual(outContext["variant_id"] as? String, "B")
        XCTAssertEqual(outContext["app_commit"] as? String, "0d9efca")
        XCTAssertNil(outContext["free"])
        XCTAssertNil(out["surprise_column"], "an unknown column is not forwarded")

        // A token that is not one of the enum's is dropped even if upstream
        // put it under `abort_reason`.
        var forged = raw
        forged["context"] = ["abort_reason": "the user said so"]
        XCTAssertNil((TelemetryRedactor.redact(row: forged, noteOptIn: false, allowedStringKeys: allowed)["context"] as? [String: Any])?["abort_reason"])
    }

    /// Wire contract §2, every required column, snake_case, with the three
    /// local-only fields absent.
    func testWireRowCarriesTheContractColumnsAndNoneOfTheLocalOnlyOnes() throws {
        let run = TelemetryFixtures.run(metrics: ["tapCount": .number(2)], note: "n", abortReason: .processEnded)
        let row = TelemetryFixtures.wireRow(run, now: TelemetryFixtures.t0.addingTimeInterval(100))
        let required = ["user_id", "run_id", "install_id", "kind", "spike_id", "scenario_id", "day_key", "day_tz_offset_min",
                        "app_build", "app_version", "build_configuration", "device_model", "os_version", "revision",
                        "started_at", "metrics", "context", "client_updated_at"]
        for column in required {
            XCTAssertNotNil(row[column], "missing \(column)")
        }
        XCTAssertEqual(row["kind"] as? String, "daily_rollup")
        XCTAssertEqual(row["day_key"] as? String, "2026-09-21")
        XCTAssertEqual((row["day_tz_offset_min"] as? NSNumber)?.intValue, -420)
        XCTAssertEqual((row["app_build"] as? NSNumber)?.intValue, 12, "integer, from `Int(appBuild)`")
        XCTAssertEqual(row["started_at"] as? String, "2026-09-21T14:13:20.000Z")
        XCTAssertEqual(row["ended_at"] as? String, "2026-09-21T14:14:20.000Z")
        XCTAssertEqual(row["client_updated_at"] as? String, "2026-09-21T14:15:00.000Z")
        XCTAssertEqual(row["outcome"] as? String, "completed")
        XCTAssertEqual((row["context"] as? [String: Any])?["abort_reason"] as? String, "process_ended")
        XCTAssertEqual(row["run_id"] as? String, run.id.uuidString.lowercased())
        for absent in ["locale_identifier", "time_zone_identifier", "owner_uid", "localeIdentifier", "timeZoneIdentifier", "ownerUID"] {
            XCTAssertNil(row[absent], "\(absent) must not be on the wire")
        }
        let redacted = TelemetryRedactor.redact(row: row, noteOptIn: false, allowedStringKeys: allowed)
        for column in required {
            XCTAssertNotNil(redacted[column], "redaction must keep the required column \(column)")
        }
    }

    /// Review P1-2: a NOT NULL text column that fails the whitelist becomes
    /// `"unknown"` so the server can judge that row alone; nullable columns
    /// and free text are still dropped, never placeholdered.
    func testNotNullTextColumnsArePlaceholderedNotDropped() throws {
        var raw = TelemetryFixtures.wireRow(TelemetryFixtures.run(buildConfiguration: "staging", note: "prose"))
        raw["app_version"] = "1.0b1 (beta)"
        raw["device_model"] = nil
        raw["outcome"] = "whatever"
        let out = TelemetryRedactor.redact(row: raw, noteOptIn: false, allowedStringKeys: allowed)
        XCTAssertEqual(out["build_configuration"] as? String, "unknown")
        XCTAssertEqual(out["app_version"] as? String, "unknown")
        XCTAssertEqual(out["device_model"] as? String, "unknown", "a missing NOT NULL column is filled, not left out")
        XCTAssertEqual(out["os_version"] as? String, "26.0", "a valid value is untouched")
        XCTAssertNil(out["outcome"], "a nullable column that fails the whitelist is dropped")
        XCTAssertNil(out["note"], "free text is dropped, never placeholdered")
        for column in TelemetryRedactor.notNullTextColumns {
            XCTAssertNotNil(out[column], "\(column) must always be present after redaction")
        }
    }

    func testAMissingDayKeyUsesTheCallersFallback() {
        let run = TelemetryFixtures.run(dayKey: nil, dayTZOffsetMin: nil)
        let row = TelemetryWire.row(for: run, userID: TelemetryFixtures.uid, installID: UUID(), now: TelemetryFixtures.t0) { _ in
            ("2001-02-03", 60)
        }
        XCTAssertEqual(row["day_key"] as? String, "2001-02-03")
        XCTAssertEqual((row["day_tz_offset_min"] as? NSNumber)?.intValue, 60)
    }
}

// MARK: - Source scans (design §3 L0, §7.4; B·F38)

final class TelemetrySourceScanTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func codeLines(_ relativePath: String) throws -> [String] {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        return source.components(separatedBy: "\n").filter { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }

    /// The pure file is pure: no defaults, no files, no network, no UIKit,
    /// no publishing, no build-configuration branch. `Calendar` appears
    /// only as the parameter of the one day-key function.
    func testTheModelFileIsFreeOfIOAndOfADebugBranch() throws {
        let lines = try codeLines("Done/Models/TelemetryModel.swift")
        XCTAssertFalse(lines.isEmpty, "liveness")
        for banned in ["UserDefaults", "FileManager", "URLSession", "UIKit", "@Published", "#if DEBUG", "Calendar.current"] {
            XCTAssertFalse(lines.contains { $0.contains(banned) }, "TelemetryModel.swift must not mention \(banned)")
        }
        let calendarLines = lines.filter { $0.contains("Calendar") }
        XCTAssertEqual(calendarLines.count, 1, "exactly one `Calendar`: the dayKey parameter; got \(calendarLines)")
        XCTAssertTrue(calendarLines[0].contains("static func dayKey(forDayStart dayStart: Date, calendar: Calendar)"))
    }

    /// B·F38: the uploader asks `uploadsBlockedByBuild` through a closure
    /// and builds no second Debug gate of its own.
    func testTheUploaderHasNoDebugBranchAndAsksTheSyncEnginesGate() throws {
        let lines = try codeLines("Done/Services/TelemetryUploader.swift")
        XCTAssertFalse(lines.isEmpty, "liveness")
        XCTAssertFalse(lines.contains { $0.contains("#if DEBUG") })
        XCTAssertFalse(lines.contains { $0.contains("debugBlocksUploads") },
                       "the static flag is the engine's business; the uploader reads the property")
        // No positive anchor for `uploadsBlockedByBuild`: a token present in
        // some non-comment line survives deleting the guard (QA M11). The
        // gate's behaviour is pinned by TelemetryUploaderTests instead.
    }

    /// The uploader's one request path is the gateway: no URLSession of its
    /// own (B·F34 — a second HTTP path would bypass the offline switch, the
    /// token refresh and this suite's URLProtocol stub alike). Prohibition
    /// only; that it DOES send through `upsertRows` is the HTTP-stub tests'
    /// positive control, not a token to grep for.
    func testTheUploaderSendsOnlyThroughTheGateway() throws {
        let lines = try codeLines("Done/Services/TelemetryUploader.swift")
        XCTAssertFalse(lines.isEmpty, "liveness")
        XCTAssertFalse(lines.contains { $0.contains("URLSession") })
    }
}

// MARK: - Settings keys (§8.2)

final class TelemetrySettingsKeysTests: XCTestCase {
    /// The three keys are swept by the erase and NONE is registered as a
    /// launch default: a registered value survives `removeObject`, so the
    /// sweep could never truly empty them (`ResetSweepQATests`). Default
    /// OFF (#197) is the unset `bool(forKey:)` reading false.
    func testTheThreeTelemetryKeysAreResettableAndUnregisteredAndReadOffWhenUnset() {
        let keys = [AppSettingsKeys.telemetryUploadsEnabled, AppSettingsKeys.telemetryConsentAt, AppSettingsKeys.telemetryNoteUploadsEnabled]
        for key in keys {
            XCTAssertTrue(AppSettingsKeys.resettableUserDefaultsKeys.contains(key),
                          "\(key) left the erase sweep — the next account inherits the previous owner's consent")
            XCTAssertNil(AppSettingsKeys.launchRegisteredDefaults[key],
                         "\(key) must not be a registered default — the reset sweep could not empty it")
        }
        let suiteName = "TelemetrySettingsKeysTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled), "unset reads OFF")
        XCTAssertFalse(defaults.bool(forKey: AppSettingsKeys.telemetryNoteUploadsEnabled), "unset reads OFF")
        XCTAssertNil(TelemetryConsentStore.consentAt(defaults), "no consent until the OFF → ON moment writes one")
    }

    /// Review P2-9: the RULE behind the three named keys. A registered
    /// default survives `removeObject`, so a key in both lists could never
    /// be truly erased — `object(forKey:)` would keep answering the default.
    func testRegisteredDefaultsAndResettableKeysAreDisjoint() {
        let registered = Set(AppSettingsKeys.launchRegisteredDefaults.keys)
        let overlap = registered.intersection(AppSettingsKeys.resettableUserDefaultsKeys)
        XCTAssertTrue(overlap.isEmpty, "keys both registered and resettable can never be erased: \(overlap.sorted())")
        XCTAssertFalse(registered.isEmpty, "liveness: the registration table is not empty")
    }

    func testTheSweepRemovesConsentAndBothSwitches() {
        let suiteName = "TelemetrySettingsKeysTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        defaults.set(true, forKey: AppSettingsKeys.telemetryNoteUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: Date())
        XCTAssertNotNil(TelemetryConsentStore.consentAt(defaults), "seed")
        AppSettingsKeys.removeResettableKeys(from: defaults)
        XCTAssertNil(defaults.object(forKey: AppSettingsKeys.telemetryUploadsEnabled))
        XCTAssertNil(defaults.object(forKey: AppSettingsKeys.telemetryNoteUploadsEnabled))
        XCTAssertNil(defaults.object(forKey: AppSettingsKeys.telemetryConsentAt))
        XCTAssertFalse(defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled), "reads OFF after the erase")
        XCTAssertNil(TelemetryConsentStore.consentAt(defaults))
    }
}
