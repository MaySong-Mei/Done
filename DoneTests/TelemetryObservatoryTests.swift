//
//  TelemetryObservatoryTests.swift
//  DoneTests
//
//  gh#273 §16 — "the observatory IS data collection": the TestFlight
//  default (on, a real consent moment, the distant-past watermark at upload
//  time, never against the user's own "off", withdrawn by a definite App
//  Store answer), the distribution answer, the backfill loop (batches until
//  drained), and the observatory's read of this account's cloud rows
//  (stable paging, the 60-day window, merge, fallback, distinct days).
//  Every absence is paired with a positive control.
//

import StoreKit
import XCTest
@testable import Done

/// A JSONL line as a build before the chassis wrote it — no `revision`,
/// `kind`, `ownerUID` or `installID` — written past the store, which would
/// stamp all four.
private func writeLegacyLine(_ run: SpikeRun, location: SpikeRunStorageLocation) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(run)
    let text = String(decoding: data, as: UTF8.self)
    data.append(0x0A)
    try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
    let url = location.directory.appendingPathComponent("\(run.spikeID).jsonl")
    if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } else {
        try data.write(to: url)
    }
    return text
}

/// A small rig every class here shares: a scratch pool, a scratch defaults
/// suite, account A's fake server, and a clock.
@MainActor
private final class ObservatoryRig {
    let uid = TelemetryFixtures.uid
    let location = SpikeRunStorageLocation.ephemeral(id: UUID())
    let suiteName = "TelemetryObservatoryTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let server: SyncFakeServer
    var clock = TelemetryFixtures.t0
    var detectorCalls = 0

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        server = SyncFakeServer(userId: TelemetryFixtures.uid)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        defaults.removePersistentDomain(forName: suiteName)
        SpikeRunStore.ownerProvider = nil
    }

    /// `isTestFlight` false is a definite App Store answer; `distribution`
    /// overrides it.
    func uploader(isTestFlight: Bool = false, distribution: TelemetryDistribution? = nil,
                  cloudReader: TelemetryCloudReading? = nil,
                  signedIn: Bool = true, attached: Bool = true) -> TelemetryUploader {
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.now = { [unowned self] in self.clock }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        let answer = distribution ?? (isTestFlight ? .testFlight : .appStore)
        deps.distribution = { [unowned self] in
            self.detectorCalls += 1
            return answer
        }
        let uploader = TelemetryUploader(dependencies: deps)
        if attached {
            uploader.attach(TelemetryUploader.Attachment(
                gateway: server, isBlockedByBuild: { false },
                currentUserID: { [uid] in signedIn ? uid : nil }, isSignedIn: { signedIn },
                cloudReader: cloudReader
            ))
        }
        return uploader
    }

    var switchOn: Bool { defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled) }
    var onByDefault: Bool { TelemetryConsentStore.isEnabledByDefault(defaults) }
    var upserts: [SyncFakeServer.Request] { server.requests(.telemetryUpsert) }

    @discardableResult
    func seed(_ count: Int, kind: TelemetryRecordKind, ageMinutes: Double = 0) -> [SpikeRun] {
        (0..<count).map { index in
            let started = clock.addingTimeInterval(-(ageMinutes + Double(index)) * 60)
            let isDaily = kind == .dailyRollup
            let run = TelemetryFixtures.run(
                spikeID: isDaily ? FixObservationRegistry.residentDailySpikeID : FixObservationRegistry.effortPathFixID,
                scenarioID: isDaily ? FixObservationRegistry.residentDailyScenarioID : FixObservationRegistry.windowScenarioID,
                startedAt: started, endedAt: started.addingTimeInterval(30), kind: kind, revision: nil
            )
            XCTAssertTrue(SpikeRunStore.finishRun(run, location: location), "seed must land")
            return run
        }
    }
}

// MARK: - TestFlight default (§16 rule 2)

@MainActor
final class TelemetryTestFlightDefaultTests: XCTestCase {
    private var rig: ObservatoryRig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryRig()
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    /// A TestFlight install the user has not ruled on switches on — the
    /// stored consent is the real moment (review P1-1), the watermark at
    /// upload time the distant past: account-stamped history from long
    /// before any consent goes up ("补传"). What §16 does NOT adopt stays
    /// home — a line older than the chassis (no revision, no owner) and a
    /// signed-out record (owner nil). The owned record is the positive
    /// control that the backfill really ran.
    func testATestFlightInstallSwitchesOnAndBackfillsOwnedHistoryButNotLegacyOrSignedOutRecords() async throws {
        let day: TimeInterval = 86_400
        let owned = TelemetryFixtures.run(startedAt: rig.clock - 30 * day, endedAt: rig.clock - 30 * day + 60, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(owned, location: rig.location))
        let signedOut = TelemetryFixtures.run(startedAt: rig.clock - 20 * day, endedAt: rig.clock - 20 * day + 60,
                                              ownerUID: nil, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(signedOut, owner: .explicit(nil), location: rig.location))
        let legacy = TelemetryFixtures.run(startedAt: rig.clock - 40 * day, endedAt: rig.clock - 40 * day + 60,
                                           ownerUID: nil, kind: nil, revision: nil, dayKey: nil, dayTZOffsetMin: nil)
        let legacyLine = try writeLegacyLine(legacy, location: rig.location)
        XCTAssertFalse(legacyLine.contains("\"revision\""), "rig: the legacy line carries no revision")
        XCTAssertFalse(legacyLine.contains("\"ownerUID\""), "rig: nor an owner")
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: owned.spikeID, location: rig.location).count, 3, "liveness: all three on disk")

        let uploader = rig.uploader(isTestFlight: true)
        let switchedOn = await uploader.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(switchedOn)
        XCTAssertTrue(rig.switchOn)
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), rig.clock,
                       "the stored consent is the real moment, never the distant past — the backfill is the watermark rule's")
        XCTAssertTrue(rig.onByDefault, "and it is marked as the default's")
        XCTAssertFalse(rig.defaults.bool(forKey: AppSettingsKeys.telemetryNoteUploadsEnabled), "the note never comes on by default")
        XCTAssertFalse(TelemetryConsentStore.userHasDecided(rig.defaults), "the default is not the user's decision")

        await uploader.drain()
        XCTAssertEqual(uploader.lastOutcome, .uploaded(rows: 1))
        XCTAssertNotNil(rig.server.telemetryRow(runID: owned.id), "positive control: 30-day-old owned history went up")
        XCTAssertNil(rig.server.telemetryRow(runID: legacy.id), "a line older than the chassis is never adopted")
        XCTAssertNil(rig.server.telemetryRow(runID: signedOut.id), "a signed-out record never leaves the device")
        XCTAssertEqual(rig.server.telemetryRowCount(), 1)
    }

    /// Not TestFlight (the App Store, Xcode, or StoreKit could not answer):
    /// nothing changes and nothing is sent.
    func testAnInstallThatIsNotTestFlightStaysOff() async {
        rig.seed(3, kind: .window)
        let uploader = rig.uploader(isTestFlight: false)
        let switchedOn = await uploader.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(switchedOn)
        XCTAssertEqual(rig.detectorCalls, 1, "liveness: the detector was asked")
        XCTAssertFalse(rig.switchOn)
        XCTAssertNil(TelemetryConsentStore.consentAt(rig.defaults))
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .switchOff)
        XCTAssertTrue(rig.upserts.isEmpty)
    }

    /// The user turned it off on Fix Watch; a later version on TestFlight
    /// never turns it back on — the detector is asked (its answer sets every
    /// consent's watermark), its answer never switches a decided user.
    /// Positive control first: untouched defaults DO get the default.
    func testAUserWhoTurnedItOffIsNeverTurnedBackOnByTheDefault() async {
        let first = rig.uploader(isTestFlight: true)
        let defaulted = await first.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(defaulted, "positive control: an untouched TestFlight install gets the default")

        // The toggle binding writes the value, then runs the edge.
        rig.defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetrySwitchEdge.apply(from: true, to: false, defaults: rig.defaults, now: rig.clock, uploader: first)
        XCTAssertTrue(TelemetryConsentStore.userHasDecided(rig.defaults))
        XCTAssertFalse(rig.onByDefault, "the user's flip makes the switch theirs")

        let callsBefore = rig.detectorCalls
        let upgraded = rig.uploader(isTestFlight: true)
        let again = await upgraded.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(again)
        XCTAssertEqual(rig.detectorCalls, callsBefore + 1,
                       "asked (TestFlight sets every consent's watermark) — but the answer never switches a decided user on")
        XCTAssertFalse(rig.switchOn)
        let outcome = await upgraded.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .switchOff)
    }

    /// The watermark rule itself (decision 2026-10-27 ①).
    func testTheWatermarkIsTheDistantPastInTestFlightAndTheConsentMomentElsewhere() {
        let consent = rig.clock.addingTimeInterval(0.4)
        XCTAssertEqual(TelemetryDefaultPolicy.watermark(consentAt: consent, isTestFlight: true), .distantPast)
        XCTAssertEqual(TelemetryDefaultPolicy.watermark(consentAt: consent, isTestFlight: false), consent)
    }

    /// Decision ①: in TestFlight EVERY consent backfills. A user who turned
    /// it ON themselves (a decided user — the default does not touch them)
    /// keeps their moment as recorded, and the upload still reaches back
    /// past it. This is the one case the stored-consent rewrite of the
    /// default cannot cover, so it is the test that pins the TestFlight
    /// watermark at upload time. Positive control: the flip is a decision.
    func testInTestFlightAUserWhoTurnedItOnThemselvesStillBackfillsTheirHistory() async {
        let day: TimeInterval = 86_400
        let before = TelemetryFixtures.run(startedAt: rig.clock - 10 * day, endedAt: rig.clock - 10 * day + 60, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(before, location: rig.location))
        let chosen = rig.clock.addingTimeInterval(0.5)
        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetrySwitchEdge.apply(from: false, to: true, defaults: rig.defaults, now: chosen, uploader: nil)
        XCTAssertTrue(TelemetryConsentStore.userHasDecided(rig.defaults), "positive control: the flip is a decision")

        let uploader = rig.uploader(isTestFlight: true)
        let defaulted = await uploader.applyTestFlightDefaultIfNeeded()   // what activate() runs
        XCTAssertFalse(defaulted, "a decided user is not switched by the default")
        XCTAssertEqual(uploader.isTestFlightInstall, true)
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), chosen, "the user's own moment is kept as recorded")
        await uploader.drain()
        XCTAssertNotNil(rig.server.telemetryRow(runID: before.id),
                        "history from before the user's own ON went up: in TestFlight every consent backfills")
        XCTAssertEqual(uploader.lastOutcome, .uploaded(rows: 1), "and the batch was started without waiting for another trigger")
    }

    /// The App Store keeps the consent moment as the watermark: the same
    /// manual ON, on an install that is not TestFlight, leaves the earlier
    /// history home and sends only what came after.
    func testOnTheAppStoreAManualOnSendsOnlyWhatCameAfterIt() async {
        let day: TimeInterval = 86_400
        let before = TelemetryFixtures.run(startedAt: rig.clock - 10 * day, endedAt: rig.clock - 10 * day + 60, revision: nil)
        let chosen = rig.clock.addingTimeInterval(0.5)
        let after = TelemetryFixtures.run(startedAt: chosen.addingTimeInterval(60), endedAt: chosen.addingTimeInterval(90), revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(before, location: rig.location))
        XCTAssertTrue(SpikeRunStore.finishRun(after, location: rig.location))
        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetrySwitchEdge.apply(from: false, to: true, defaults: rig.defaults, now: chosen, uploader: nil)

        let uploader = rig.uploader(isTestFlight: false)
        _ = await uploader.applyTestFlightDefaultIfNeeded()
        XCTAssertEqual(uploader.isTestFlightInstall, false)
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .uploaded(rows: 1))
        XCTAssertNotNil(rig.server.telemetryRow(runID: after.id), "positive control: what came after the ON went up")
        XCTAssertNil(rig.server.telemetryRow(runID: before.id), "history before the consent moment stays home")
    }

    /// Decision ①, the user's own phone: build 17 left the switch ON with a
    /// consent moment and no decided bit. That ON is the user's own answer
    /// (review P1-1): on the first TestFlight run of this version the stored
    /// moment is left exactly as it was, the switch is not marked as the
    /// default's (an App Store build must never withdraw it), and
    /// account-stamped history from BEFORE that moment goes up.
    func testABuild17SwitchOnUpgradesToABackfillOfOwnedHistory() async {
        let day: TimeInterval = 86_400
        let before = TelemetryFixtures.run(startedAt: rig.clock - 30 * day, endedAt: rig.clock - 30 * day + 60, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(before, location: rig.location))
        let moment = rig.clock.addingTimeInterval(-600.3)
        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(rig.defaults, at: moment)
        XCTAssertNil(rig.defaults.object(forKey: AppSettingsKeys.telemetryUserDecided), "rig: build 17 wrote no decided bit")
        XCTAssertTrue(TelemetryConsentStore.userHasDecided(rig.defaults), "its stored ON is still the user's answer")

        let uploader = rig.uploader(isTestFlight: true)
        let defaulted = await uploader.applyTestFlightDefaultIfNeeded()   // what activate() runs at launch
        XCTAssertFalse(defaulted)
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), moment, "the user's real moment is not rewritten")
        XCTAssertFalse(rig.onByDefault)
        await uploader.drain()
        XCTAssertNotNil(rig.server.telemetryRow(runID: before.id), "30-day-old owned history went up after the upgrade")
        XCTAssertEqual(uploader.lastOutcome, .uploaded(rows: 1))
    }

    /// Phones that already ran build 17: a stored switch is the user's own
    /// answer either way (the key is unregistered — only the user wrote it),
    /// so the default leaves both alone. The ON one backfills through the
    /// watermark rule, with its stored moment untouched.
    func testBuild17StateIsReadAsTheUsersOwnAnswer() async {
        rig.defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        let leftOff = rig.uploader(isTestFlight: true)
        let defaultedOff = await leftOff.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(defaultedOff, "a stored OFF from build 17 is a decision")
        XCTAssertFalse(rig.switchOn)

        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(rig.defaults, at: rig.clock.addingTimeInterval(-600))
        let turnedOn = rig.uploader(isTestFlight: true)
        let defaultedOn = await turnedOn.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(defaultedOn, "build 17's manual ON is a decision too")
        XCTAssertTrue(rig.switchOn)
        XCTAssertFalse(rig.onByDefault)
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), rig.clock.addingTimeInterval(-600))
    }

    /// The decided bit and the by-default bit are the previous owner's:
    /// swept by the erase, never registered defaults (a registered value
    /// would survive the sweep).
    func testTheDecidedAndByDefaultBitsAreSweptByTheEraseAndNeverRegistered() async {
        for key in [AppSettingsKeys.telemetryUserDecided, AppSettingsKeys.telemetryEnabledByDefault] {
            XCTAssertTrue(AppSettingsKeys.resettableUserDefaultsKeys.contains(key), key)
            XCTAssertNil(AppSettingsKeys.launchRegisteredDefaults[key], key)
        }
        let uploader = rig.uploader(isTestFlight: true)
        _ = await uploader.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(rig.onByDefault, "liveness")
        AppSettingsKeys.removeResettableKeys(from: rig.defaults)
        XCTAssertNil(rig.defaults.object(forKey: AppSettingsKeys.telemetryEnabledByDefault))

        TelemetryConsentStore.recordDecision(rig.defaults)
        XCTAssertTrue(TelemetryConsentStore.userHasDecided(rig.defaults), "liveness")
        AppSettingsKeys.removeResettableKeys(from: rig.defaults)
        XCTAssertNil(rig.defaults.object(forKey: AppSettingsKeys.telemetryUserDecided))
        XCTAssertFalse(TelemetryConsentStore.userHasDecided(rig.defaults), "an erased phone is undecided again")
    }

    /// Review P1-1: a TestFlight install the default turned on, then the App
    /// Store build installed over it (or its backup restored onto a new
    /// phone). The App Store launch sends NOTHING — not in the batch that
    /// runs before StoreKit answers, not after — and the definite answer
    /// takes the default back. Back on TestFlight the default returns with
    /// the first moment kept, and what the App Store launch held back goes
    /// up (positive control: there WAS something to send).
    func testAnAppStoreLaunchOverATestFlightDefaultSendsNothingAndSwitchesItOff() async {
        let day: TimeInterval = 86_400
        let history = TelemetryFixtures.run(startedAt: rig.clock - 30 * day, endedAt: rig.clock - 30 * day + 60, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(history, location: rig.location))

        // Launch 1, TestFlight: on by default, history backfilled.
        let testFlight = rig.uploader(isTestFlight: true)
        let defaulted = await testFlight.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(defaulted)
        await testFlight.drain()
        XCTAssertNotNil(rig.server.telemetryRow(runID: history.id), "rig: launch 1 backfilled in TestFlight")
        let firstConsent = TelemetryConsentStore.consentAt(rig.defaults)
        XCTAssertEqual(firstConsent, rig.clock)

        // Between launches: a record from before the consent moment that
        // finished late, and one from after it.
        rig.clock += 3600
        let olderThanConsent = TelemetryFixtures.run(startedAt: rig.clock - 10 * day, endedAt: rig.clock - 10 * day + 60, revision: nil)
        let afterConsent = TelemetryFixtures.run(startedAt: rig.clock - 60, endedAt: rig.clock, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(olderThanConsent, location: rig.location))
        XCTAssertTrue(SpikeRunStore.finishRun(afterConsent, location: rig.location))
        let requestsBefore = rig.upserts.count

        // Launch 2, the App Store build over it.
        let appStore = rig.uploader(isTestFlight: false)
        let early = await appStore.uploadNow(trigger: .launch)   // the launch batch, before StoreKit answers
        XCTAssertEqual(early, .defaultNotConfirmed)
        let stillOn = await appStore.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(stillOn)
        XCTAssertFalse(rig.switchOn, "the definite App Store answer switched the default off")
        XCTAssertNil(rig.defaults.object(forKey: AppSettingsKeys.telemetryUploadsEnabled),
                     "removed, not written false — a stored false would read as the user's own OFF")
        XCTAssertFalse(rig.onByDefault)
        let late = await appStore.uploadNow(trigger: .launch)
        XCTAssertEqual(late, .switchOff)
        XCTAssertEqual(rig.upserts.count, requestsBefore, "the App Store launch sent nothing")
        XCTAssertNil(rig.server.telemetryRow(runID: afterConsent.id))
        XCTAssertNil(rig.server.telemetryRow(runID: olderThanConsent.id))

        // Launch 3, TestFlight again.
        let back = rig.uploader(isTestFlight: true)
        let again = await back.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(again, "withdrawn means never ruled, so TestFlight defaults again")
        XCTAssertEqual(TelemetryConsentStore.consentAt(rig.defaults), firstConsent, "a stored moment is kept, not overwritten")
        await back.drain()
        XCTAssertNotNil(rig.server.telemetryRow(runID: afterConsent.id), "positive control: launch 2 had something to send")
        XCTAssertNotNil(rig.server.telemetryRow(runID: olderThanConsent.id))
    }

    /// StoreKit could not say. A fresh install is not switched on; a switch
    /// the default already turned on is neither withdrawn (an offline
    /// TestFlight launch must not flip it) nor allowed to send.
    func testAnUnknownAnswerNeitherTurnsTheDefaultOnNorWithdrawsItAndSendsNothing() async {
        let unknown = TelemetryDistribution.unknown(reason: "SKErrorDomain#0")
        let fresh = rig.uploader(distribution: unknown)
        let defaulted = await fresh.applyTestFlightDefaultIfNeeded()
        XCTAssertFalse(defaulted)
        XCTAssertFalse(rig.switchOn)
        XCTAssertNil(TelemetryConsentStore.consentAt(rig.defaults))

        let testFlight = rig.uploader(isTestFlight: true)
        let on = await testFlight.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(on, "positive control: TestFlight does turn it on")
        await testFlight.drain()
        rig.seed(2, kind: .window)
        let requestsBefore = rig.upserts.count

        let offline = rig.uploader(distribution: unknown)
        _ = await offline.applyTestFlightDefaultIfNeeded()
        XCTAssertTrue(rig.switchOn, "not withdrawn on an unknown answer")
        XCTAssertTrue(rig.onByDefault)
        let outcome = await offline.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .defaultNotConfirmed)
        XCTAssertEqual(rig.upserts.count, requestsBefore, "and nothing was sent")

        let next = rig.uploader(isTestFlight: true)
        _ = await next.applyTestFlightDefaultIfNeeded()
        await next.drain()
        XCTAssertEqual(next.lastOutcome, .uploaded(rows: 2), "positive control: the held-back records were pending")
    }

    /// Review P1-2: a build carrying a provisioning profile (Xcode, devicectl,
    /// ad hoc) is development whatever StoreKit would say — and StoreKit is
    /// not asked. Without one, StoreKit's verified environment decides; an
    /// unverified transaction or an error is unknown.
    func testTheDistributionAnswer() async {
        var storeKitCalls = 0
        let sandbox = TelemetryDistributionDetector.StoreKitAnswer.verified(environment: AppStore.Environment.sandbox.rawValue)
        let provisioned = await TelemetryDistributionDetector.classify(hasProvisioningProfile: true) {
            storeKitCalls += 1
            return sandbox
        }
        XCTAssertEqual(provisioned, .development)
        XCTAssertEqual(storeKitCalls, 0, "a provisioned build never asks StoreKit")

        let testFlight = await TelemetryDistributionDetector.classify(hasProvisioningProfile: false) {
            storeKitCalls += 1
            return sandbox
        }
        XCTAssertEqual(testFlight, .testFlight, "positive control: the same sandbox answer without a profile")
        XCTAssertEqual(storeKitCalls, 1)

        func answer(_ storeKit: TelemetryDistributionDetector.StoreKitAnswer) async -> TelemetryDistribution {
            await TelemetryDistributionDetector.classify(hasProvisioningProfile: false) { storeKit }
        }
        let production = await answer(.verified(environment: AppStore.Environment.production.rawValue))
        let xcode = await answer(.verified(environment: AppStore.Environment.xcode.rawValue))
        let unverified = await answer(.unverified)
        let failed = await answer(.failed(reason: "SKErrorDomain#0"))
        XCTAssertEqual(production, .appStore)
        XCTAssertEqual(xcode, .development)
        XCTAssertEqual(unverified, .unknown(reason: "unverified"))
        XCTAssertEqual(failed, .unknown(reason: "SKErrorDomain#0"))
    }

    /// The uploader on those answers: a provisioned build (StoreKit saying
    /// sandbox) and a StoreKit error both leave the switch off. Positive
    /// control: the unprovisioned sandbox answer turns it on.
    func testAProvisionedBuildOrAStoreKitErrorIsNotTestFlightAndGetsNoDefault() async {
        for (provisioned, storeKit, expected) in [
            (true, TelemetryDistributionDetector.StoreKitAnswer.verified(environment: AppStore.Environment.sandbox.rawValue),
             TelemetryDistribution.development),
            (false, .failed(reason: "SKErrorDomain#0"), .unknown(reason: "SKErrorDomain#0")),
            (false, .verified(environment: AppStore.Environment.sandbox.rawValue), .testFlight),
        ] {
            let suite = "TelemetryObservatoryTests-dist-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var deps = TelemetryUploader.Dependencies()
            deps.defaults = defaults
            deps.location = rig.location
            deps.launchDelay = 0
            deps.makeKeepAlive = { nil }
            deps.distribution = {
                await TelemetryDistributionDetector.classify(hasProvisioningProfile: provisioned) { storeKit }
            }
            let uploader = TelemetryUploader(dependencies: deps)
            let defaulted = await uploader.applyTestFlightDefaultIfNeeded()
            XCTAssertEqual(uploader.distribution, expected)
            XCTAssertEqual(defaulted, expected == .testFlight, "\(expected)")
            XCTAssertEqual(defaults.bool(forKey: AppSettingsKeys.telemetryUploadsEnabled), expected == .testFlight, "\(expected)")
            await uploader.drain()
        }
    }

    /// The answer is on the device's trail, whatever it is — one line per
    /// launch (the uploader asks once).
    func testEachLaunchWritesItsEnvironmentToTheTrailOnce() async {
        let reason = "trail-\(UUID().uuidString)"
        let uploader = rig.uploader(distribution: .unknown(reason: reason))
        _ = await uploader.applyTestFlightDefaultIfNeeded()
        _ = await uploader.applyTestFlightDefaultIfNeeded()
        let lines = DiagnosticTrail.combinedText().split(separator: "\n").filter { $0.contains(reason) }
        XCTAssertEqual(lines.count, 1, "one line per launch")
        XCTAssertTrue(lines.first?.contains("Telemetry environment=unknown(\(reason))") == true, "\(lines)")
        XCTAssertEqual(TelemetryDistribution.development.traceLabel, "development")
        XCTAssertEqual(TelemetryDistribution.testFlight.traceLabel, "testflight")
        XCTAssertEqual(TelemetryDistribution.appStore.traceLabel, "appstore")
    }
}

// MARK: - Backfill loop (§16 rule 2)

@MainActor
final class TelemetryBackfillLoopTests: XCTestCase {
    private var rig: ObservatoryRig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryRig()
        rig.defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(rig.defaults, at: .distantPast)
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    private func bodySizes() -> [Int] {
        rig.upserts.map { ($0.body as? [[String: Any]])?.count ?? -1 }
    }

    /// 120 records of history, ONE trigger: 4 requests (32+32+32+24), the
    /// cursor covers all of them, and the next trigger sends nothing.
    func testOneTriggerSendsBatchesUntilNothingIsPending() async {
        rig.seed(120, kind: .window)
        let uploader = rig.uploader()
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .uploaded(rows: 120), "the trigger reports everything it moved")
        XCTAssertEqual(bodySizes(), [32, 32, 32, 24])
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: rig.location).uploaded.count, 120)
        XCTAssertEqual(rig.server.telemetryRowCount(), 120)
        XCTAssertEqual(uploader.lastBatchCount, 120, "the status line counts the trigger, not its last batch")

        let again = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(again, .nothingPending)
        XCTAssertEqual(rig.upserts.count, 4, "zero requests on the next trigger")
    }

    /// Any failure stops the loop; the next trigger picks up where it left.
    func testALoopStopsAtTheFirstFailureAndTheNextTriggerResumes() async {
        rig.seed(120, kind: .window)
        let uploader = rig.uploader()
        let server = rig.server
        server.failWhen = { verb, table in
            guard verb == .telemetryUpsert, server.requests(.telemetryUpsert).count == 2 else { return nil }
            return SupabaseREST.SyncError.requestFailed(table: table, method: "POST", status: 500, code: nil)
        }
        let stopped = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(stopped, .failed(kind: .retryable, code: "http500"), "the failure is the news")
        XCTAssertEqual(rig.upserts.count, 2, "one batch landed, the second failed, no third was tried")
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: rig.location).uploaded.count, 32)
        XCTAssertEqual(uploader.lastBatchCount, 32)

        server.failWhen = nil
        let resumed = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(resumed, .uploaded(rows: 88))
        XCTAssertEqual(rig.upserts.count, 5)
        XCTAssertEqual(SpikeRunStore.loadUploadCursor(location: rig.location).uploaded.count, 120)
    }

    /// The daily throttle is judged once, at the trigger: an edge allowed to
    /// send dailies sends all 40, not only the first batch's 32. (Judged per
    /// batch, the first batch's daily would shut the gate on the rest.)
    func testAnEdgeAllowedDailiesSendsAllOfThemAcrossBatches() async {
        rig.seed(40, kind: .dailyRollup)
        let uploader = rig.uploader()
        let outcome = await uploader.uploadNow(trigger: .backgroundEdge)
        XCTAssertEqual(outcome, .uploaded(rows: 40))
        XCTAssertEqual(bodySizes(), [32, 8])
    }
}

// MARK: - Cloud paging (§16 rule 3)

/// Serves `rows` on or after the asked day in the view's order (`day_key`
/// desc, `run_id` asc), one `limit`/`offset` page at a time; `beforePage`
/// lets a test change the table between pages, the way another device's
/// upload would. Records what each call asked for.
@MainActor
private final class FakeCloudReader: TelemetryCloudReading {
    var rows: [[String: Any]] = []
    var calls: [(limit: Int, offset: Int)] = []
    var sinceDayKeys: [String] = []
    var spikeIDs: [[String]] = []
    var beforePage: ((Int) -> Void)?
    var error: Error?

    static func row(day: String, id: Int, revision: Int = 1) -> [String: Any] {
        ["run_id": String(format: "00000000-0000-4000-8000-%012d", id), "day_key": day, "revision": revision]
    }

    func fetchMySpikeRunsPage(spikeIDs: [String], sinceDayKey: String, limit: Int, offset: Int) async throws -> [[String: Any]] {
        beforePage?(calls.count)
        calls.append((limit, offset))
        sinceDayKeys.append(sinceDayKey)
        self.spikeIDs.append(spikeIDs)
        if let error { throw error }
        // A malformed rig row fails the test that wrote it; it never crashes
        // the test process (QA: a forced cast here took every test down).
        var keyed: [(day: String, id: String, row: [String: Any])] = []
        for row in rows {
            guard let day = row["day_key"] as? String, let id = row["run_id"] as? String else {
                XCTFail("rig: every fake cloud row needs a day_key and a run_id string: \(row)")
                continue
            }
            if day >= sinceDayKey { keyed.append((day, id, row)) }
        }
        let ordered = keyed.sorted { $0.day != $1.day ? $0.day > $1.day : $0.id < $1.id }.map(\.row)
        return Array(ordered.dropFirst(offset).prefix(limit))
    }
}

@MainActor
final class TelemetryCloudPagerTests: XCTestCase {

    private func ids(_ rows: [[String: Any]]) -> [String] { rows.compactMap { $0["run_id"] as? String } }

    /// Two pages of three, and between them another device uploads a row
    /// for an OLDER day than page one ended on: every row after it shifts
    /// down, so page two starts with page one's last row. Nothing that
    /// existed when the walk began is lost, and nothing comes back twice.
    func testTwoPagesWithARowPushedAcrossTheBoundaryLoseNothingAndRepeatNothing() async throws {
        let reader = FakeCloudReader()
        let originals = (1...5).map { FakeCloudReader.row(day: "2026-10-0\($0)", id: $0) }
        reader.rows = originals
        reader.beforePage = { [unowned reader] page in
            if page == 1 { reader.rows.append(FakeCloudReader.row(day: "2026-10-04", id: 9)) }
        }
        let fetched = try await TelemetryCloudPager.fetchAll(from: reader, spikeIDs: ["resident-daily"],
                                                             sinceDayKey: "2026-01-01", pageSize: 3)
        let got = ids(fetched)
        for id in ids(originals) {
            XCTAssertEqual(got.filter { $0 == id }.count, 1, "\(id) exactly once")
        }
        XCTAssertEqual(got.count, Set(got).count, "no repeats in the result")
        XCTAssertEqual(reader.calls.map(\.offset), [0, 3, 6], "a full page asks for the next; the empty one ends it")
        XCTAssertEqual(reader.calls.map(\.limit), [3, 3, 3])
    }

    /// A page shorter than the limit is the last; a row seen twice keeps
    /// its higher revision. Page one is full (three rows), so page two is
    /// asked for; between them the page's last row is updated (revision 2)
    /// and a new head row pushes it onto page two, which comes back with
    /// just that one row — short, so the walk ends there.
    func testAShortPageEndsTheWalkAndARepeatKeepsTheHigherRevision() async throws {
        let reader = FakeCloudReader()
        reader.rows = [FakeCloudReader.row(day: "2026-10-05", id: 1), FakeCloudReader.row(day: "2026-10-04", id: 2),
                       FakeCloudReader.row(day: "2026-10-03", id: 3)]
        reader.beforePage = { [unowned reader] page in
            if page == 1 {
                reader.rows[2]["revision"] = 2
                reader.rows.append(FakeCloudReader.row(day: "2026-10-06", id: 4))
            }
        }
        let fetched = try await TelemetryCloudPager.fetchAll(from: reader, spikeIDs: ["resident-daily"],
                                                             sinceDayKey: "2026-01-01", pageSize: 3)
        XCTAssertEqual(reader.calls.map(\.offset), [0, 3], "page two came back short (1 < 3) and ended the walk")
        XCTAssertEqual(reader.sinceDayKeys, ["2026-01-01", "2026-01-01"], "every page asks for the same window")
        let row3 = try XCTUnwrap(fetched.first { ($0["run_id"] as? String)?.hasSuffix("000000000003") == true })
        XCTAssertEqual((row3["revision"] as? NSNumber)?.intValue, 2, "the repeat with the higher revision wins")
        XCTAssertEqual(ids(fetched).count, Set(ids(fetched)).count)
    }

    /// The production request: the view, release rows, the two observatory
    /// spikes, the window's first day (review P1-3), the stable order,
    /// limit/offset — a read with no epoch header.
    func testTheRESTReadAsksForReleaseRowsInTheWindowInTheStableOrderWithNoEpoch() async throws {
        let suite = "TelemetryCloudPagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let json = #"{"access_token":"at-1","refresh_token":"","user_id":"\#(TelemetryFixtures.uid)"}"#
        let auth = AuthService(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
                               sessionStore: InMemorySessionStore(),
                               transport: { _ in throw URLError(.notConnectedToInternet) },
                               launchEnvironment: ["SYNC_DEBUG_SESSION": json], syncEnvironment: .local)
        XCTAssertTrue(auth.isSignedIn, "rig: injected session")
        TelemetryHTTPStub.install()
        TelemetryHTTPStub.reset(status: 200)
        defer { TelemetryHTTPStub.uninstall() }
        let rest = SupabaseREST(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", authService: auth)
        rest.writeEpoch = "epoch-must-not-be-sent"

        let rows = try await rest.fetchMySpikeRunsPage(spikeIDs: [FixObservationRegistry.residentDailySpikeID,
                                                                   FixObservationRegistry.effortPathFixID],
                                                        sinceDayKey: "2026-07-23", limit: 500, offset: 1000)
        XCTAssertTrue(rows.isEmpty)
        let request = try XCTUnwrap(TelemetryHTTPStub.all.first?.request)
        XCTAssertEqual(TelemetryHTTPStub.all.count, 1)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://stub.invalid/rest/v1/v_my_spike_runs?select=*&build_configuration=eq.release"
                       + "&spike_id=in.(resident-daily,fix-effort-path)&day_key=gte.2026-07-23"
                       + "&order=day_key.desc,run_id.asc&limit=500&offset=1000")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Sync-Epoch"), "a read carries no epoch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
    }
}

// MARK: - Merge and fallback (§16 rule 3)

@MainActor
final class TelemetryObservatoryMergeTests: XCTestCase {
    private var rig: ObservatoryRig!

    override func setUp() {
        super.setUp()
        rig = ObservatoryRig()
    }

    override func tearDown() {
        rig.tearDown()
        rig = nil
        super.tearDown()
    }

    /// A row as the server stores it (the wire row, through JSON, with
    /// PostgREST's `+00:00` / microsecond timestamps) reads back as the
    /// record it came from — every field the evaluator or the merge uses.
    func testAViewRowReadsBackAsTheRecordItCameFrom() throws {
        let install = UUID()
        var run = TelemetryFixtures.run(
            metrics: ["tapCount": .number(4), "tapLagBuckets": .string("0 1 2 3 4 5 6 7"), "wContaminated": .bool(true)],
            abortReason: .manualRunTookOver, revision: 7, coActiveSpikeIDs: ["spike-195-detail-perf"], variantID: "B"
        )
        run.installID = install
        var row = TelemetryWire.row(for: run, userID: rig.uid, installID: install, now: rig.clock) { _ in ("2000-01-01", 0) }
        row = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: row)) as? [String: Any])
        row["started_at"] = "2026-09-21T14:13:20+00:00"
        row["ended_at"] = "2026-09-21T14:14:20.000000+00:00"

        let back = try XCTUnwrap(TelemetryWire.run(fromRow: row))
        XCTAssertEqual(back.id, run.id)
        XCTAssertEqual(back.spikeID, run.spikeID)
        XCTAssertEqual(back.scenarioID, run.scenarioID)
        XCTAssertEqual(back.startedAt, run.startedAt)
        XCTAssertEqual(back.endedAt, run.endedAt)
        XCTAssertEqual(back.appBuild, "12")
        XCTAssertEqual(back.buildConfiguration, "release")
        XCTAssertEqual(back.metrics, run.metrics, "number, fixed-format string and bool all survive")
        XCTAssertEqual(back.kind, .dailyRollup)
        XCTAssertEqual(back.revision, 7)
        XCTAssertEqual(back.dayKey, "2026-09-21")
        XCTAssertEqual(back.dayTZOffsetMin, -420)
        XCTAssertEqual(back.ownerUID, rig.uid, "the owner is the row's user")
        XCTAssertEqual(back.installID, install)
        XCTAssertEqual(back.abortReason, .manualRunTookOver)
        XCTAssertEqual(back.variantID, "B")
        XCTAssertEqual(back.coActiveSpikeIDs, ["spike-195-detail-perf"])

        row["started_at"] = nil
        XCTAssertNil(TelemetryWire.run(fromRow: row), "an unreadable row is left out, not guessed at")
    }

    /// A record as the cloud hands it back: through the wire row, JSON and
    /// `run(fromRow:)` — the same path the deck's records take (so it has no
    /// zone or locale, which the wire does not carry).
    private func viaCloud(_ run: SpikeRun, revision: Int) throws -> SpikeRun {
        var copy = run
        copy.revision = revision
        let row = TelemetryWire.row(for: copy, userID: rig.uid, installID: copy.installID ?? UUID(), now: rig.clock) { _ in
            ("2026-09-21", 0)
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: row)) as? [String: Any])
        return try XCTUnwrap(TelemetryWire.run(fromRow: json))
    }

    /// One record per run id: the higher revision wins; a tie goes to the
    /// local copy (it carries zone and locale the wire does not); records
    /// only one side has are all kept.
    func testTheMergeKeepsOneRecordPerRunIDAndTheHigherRevision() throws {
        let shared = UUID(), tied = UUID()
        let localOld = TelemetryFixtures.run(id: shared, revision: 3)
        let cloudNew = try viaCloud(localOld, revision: 5)
        let localTie = TelemetryFixtures.run(id: tied, revision: 2)
        let cloudTie = try viaCloud(localTie, revision: 2)
        XCTAssertEqual(cloudTie.timeZoneIdentifier, "", "rig: the cloud copy has no zone")
        let localOnly = TelemetryFixtures.run(startedAt: rig.clock.addingTimeInterval(10), revision: 1)
        let cloudOnly = try viaCloud(TelemetryFixtures.run(startedAt: rig.clock.addingTimeInterval(20)), revision: 1)

        let merged = TelemetryObservatoryMerge.merge(local: [localOld, localTie, localOnly], cloud: [cloudNew, cloudTie, cloudOnly])
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.first { $0.id == shared }?.revision, 5, "the cloud's newer revision wins")
        XCTAssertEqual(merged.first { $0.id == tied }?.timeZoneIdentifier, "America/Los_Angeles", "a tie keeps the local copy")
        XCTAssertNotNil(merged.first { $0.id == localOnly.id })
        XCTAssertNotNil(merged.first { $0.id == cloudOnly.id })
    }

    private func releaseDaily(install: UUID?, revision: Int = 1, startedAt: Date, dayKey: String = "2026-09-21") -> SpikeRun {
        var run = TelemetryFixtures.run(startedAt: startedAt, metrics: ResidentCounterSet().metrics, revision: revision,
                                        dayKey: dayKey)
        run.installID = install
        return run
    }

    /// Before every window in this class: `rig.clock` is 2026-09-21 in
    /// Los Angeles, so the window starts 2026-07-23.
    private let since = "2026-07-23"
    private var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func meTabDays(_ verdicts: [FixVerdict]) -> Int? {
        verdicts.first { $0.entryID == FixObservationRegistry.meTabGateFixID }?.releaseDayCount
    }

    /// No cloud (offline / signed out / failed) or an empty one: the deck is
    /// this device's and says "this device only". With cloud rows: merged,
    /// the release days are the account's total, and the source names the
    /// installs — the local one plus another phone's.
    func testTheDeckFallsBackToThisDeviceWithoutACloudAndCountsTheAccountsDevicesWithOne() throws {
        let local = UUID(), otherPhone = UUID()
        let mine = releaseDaily(install: local, revision: 3, startedAt: rig.clock)
        let staleCopy = try viaCloud(mine, revision: 2)          // this phone's day, an older upload of it
        let theirs = try viaCloud(releaseDaily(install: otherPhone, startedAt: rig.clock.addingTimeInterval(-86_400),
                                               dayKey: "2026-09-20"), revision: 1)

        let offline = FixWatchAttention.observatory(localDailies: [mine], localWindows: [], cloud: nil, localInstall: local,
                                                    sinceDayKey: since)
        XCTAssertEqual(offline.source, .localOnly)
        XCTAssertEqual(meTabDays(offline.verdicts), 1)
        XCTAssertEqual(offline.verdicts, FixWatchAttention.evaluate(dailies: [mine], windows: []),
                       "the fallback is exactly this device's evaluation")

        let empty = FixWatchAttention.observatory(localDailies: [mine], localWindows: [], cloud: [], localInstall: local,
                                                  sinceDayKey: since)
        XCTAssertEqual(empty.source, .localOnly, "an empty cloud is not a source")

        let cloud = FixWatchAttention.observatory(localDailies: [mine], localWindows: [], cloud: [staleCopy, theirs],
                                                  localInstall: local, sinceDayKey: since)
        XCTAssertEqual(cloud.source, .cloud(devices: 2))
        XCTAssertEqual(meTabDays(cloud.verdicts), 2, "this phone's day once (not twice) plus the other phone's")
        XCTAssertEqual(FixWatchSource.localOnly.label, L(.fixWatchSourceLocal))
        XCTAssertTrue(FixWatchSource.cloud(devices: 2).label.contains("2"))
    }

    /// The uploader asks the cloud only when it can, and every "cannot" is
    /// nil — the deck's fallback signal: not attached, no reader, signed
    /// out, or a failed read. Positive control: a readable cloud decodes.
    func testTheCloudReadIsNilWheneverThereIsNoCloudToAsk() async {
        let unattached = rig.uploader(attached: false)
        let notAttached = await unattached.fetchObservatoryCloudRuns(sinceDayKey: since)
        XCTAssertNil(notAttached)

        let noReader = await rig.uploader(cloudReader: nil).fetchObservatoryCloudRuns(sinceDayKey: since)
        XCTAssertNil(noReader)

        let reader = FakeCloudReader()
        let run = TelemetryFixtures.run(revision: 1)
        reader.rows = [TelemetryWire.row(for: run, userID: rig.uid, installID: UUID(), now: rig.clock) { _ in ("2026-09-21", 0) }]
        let signedOut = await rig.uploader(cloudReader: reader, signedIn: false).fetchObservatoryCloudRuns(sinceDayKey: since)
        XCTAssertNil(signedOut)
        XCTAssertTrue(reader.calls.isEmpty, "signed out: the cloud is not even asked")

        reader.error = URLError(.notConnectedToInternet)
        let offline = await rig.uploader(cloudReader: reader).fetchObservatoryCloudRuns(sinceDayKey: since)
        XCTAssertNil(offline, "a failed read falls back")

        reader.error = nil
        let readable = await rig.uploader(cloudReader: reader).fetchObservatoryCloudRuns(sinceDayKey: since)
        XCTAssertEqual(readable?.map(\.id), [run.id], "positive control: the row decodes")
    }

    /// Review P1-3: the window is 60 days back from today on the DEVICE
    /// calendar. One instant, two zones: 2026-09-21 16:00Z is still the 21st
    /// in Los Angeles and already the 22nd in Tokyo.
    func testTheWindowStartsSixtyDaysBackOnTheDeviceCalendar() {
        XCTAssertEqual(FixWatchAttention.observatorySinceDayKey(now: rig.clock, calendar: losAngeles), "2026-07-23")
        let instant = Date(timeIntervalSince1970: 1_790_006_400)   // 2026-09-21T16:00:00Z
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(FixWatchAttention.observatorySinceDayKey(now: instant, calendar: losAngeles), "2026-07-23")
        XCTAssertEqual(FixWatchAttention.observatorySinceDayKey(now: instant, calendar: tokyo), "2026-07-24")
    }

    /// Review P1-3: the deck reads ONE window from both halves. The cloud
    /// is asked from its first day (for the two observatory spikes), and
    /// this device's records older than it are left out of the merge —
    /// the first day itself is in. Release days: the boundary day here plus
    /// the other phone's day; the two older days on either side do not count.
    func testTheDeckReadsTheSameWindowFromTheCloudAndThisDevice() async throws {
        let local = UUID(), otherPhone = UUID()
        let boundary = releaseDaily(install: local, startedAt: rig.clock - 60 * 86_400, dayKey: "2026-07-23")
        let tooOld = releaseDaily(install: local, startedAt: rig.clock - 61 * 86_400, dayKey: "2026-07-22")
        let reader = FakeCloudReader()
        for (day, install) in [("2026-09-20", otherPhone), ("2026-07-01", otherPhone)] {
            let run = releaseDaily(install: install, startedAt: rig.clock, dayKey: day)
            reader.rows.append(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject:
                TelemetryWire.row(for: run, userID: rig.uid, installID: install, now: rig.clock) { _ in (day, 0) })) as? [String: Any]))
        }
        let uploader = rig.uploader(cloudReader: reader)

        let read = await FixWatchAttention.loadObservatory(
            local: (dailies: [boundary, tooOld], windows: []),
            readCloud: { await uploader.fetchObservatoryCloudRuns(sinceDayKey: $0) },
            now: rig.clock, calendar: losAngeles, localInstall: local)
        XCTAssertEqual(reader.sinceDayKeys, ["2026-07-23"], "the cloud was asked from the window's first day")
        XCTAssertEqual(reader.spikeIDs.first, [FixObservationRegistry.residentDailySpikeID, FixObservationRegistry.effortPathFixID])
        XCTAssertEqual(read.source, .cloud(devices: 2))
        XCTAssertEqual(meTabDays(read.verdicts), 2, "2026-07-23 here and 2026-09-20 on the other phone")
    }

    /// QA (M8b): the deck's read without a cloud. A read answering nil
    /// (offline, signed out, a failed request), one that throws, and one
    /// answering nothing all leave the deck exactly this device's: the same
    /// verdicts, "this device only", never an empty deck. Positive control:
    /// a readable cloud is merged.
    func testWithoutACloudTheDeckIsExactlyThisDevicesAndNeverEmpty() async throws {
        let local = UUID()
        let mine = releaseDaily(install: local, startedAt: rig.clock)
        let records = (dailies: [mine], windows: [SpikeRun]())
        let expected = FixWatchAttention.evaluate(dailies: [mine], windows: [])
        XCTAssertEqual(meTabDays(expected), 1, "rig: this device has a release day")
        struct ReadFailed: Error {}
        let reads: [(label: String, read: (String) async throws -> [SpikeRun]?)] = [
            ("nil", { _ in nil }),
            ("throws", { _ in throw ReadFailed() }),
            ("empty", { _ in [] }),
        ]
        for (label, read) in reads {
            let deck = await FixWatchAttention.loadObservatory(local: records, readCloud: read, now: rig.clock,
                                                               calendar: losAngeles, localInstall: local)
            XCTAssertEqual(deck.source, .localOnly, label)
            XCTAssertEqual(deck.verdicts, expected, label)
            XCTAssertEqual(deck.verdicts.count, 3, "\(label): never an empty deck")
            XCTAssertEqual(meTabDays(deck.verdicts), 1, label)
        }
        let theirs = try viaCloud(releaseDaily(install: UUID(), startedAt: rig.clock - 86_400, dayKey: "2026-09-20"), revision: 1)
        let merged = await FixWatchAttention.loadObservatory(local: records, readCloud: { _ in [theirs] }, now: rig.clock,
                                                             calendar: losAngeles, localInstall: local)
        XCTAssertEqual(merged.source, .cloud(devices: 2), "positive control: a readable cloud is merged")
        XCTAssertEqual(meTabDays(merged.verdicts), 2)
    }

    /// Review P1-3: "Release 天数" counts DAYS. One day on two phones is one
    /// day; a day re-minted on this phone (two records, one day key) is one
    /// day; a second day makes two.
    func testReleaseDaysCountDistinctDaysNotRecords() throws {
        let local = UUID(), otherPhone = UUID()
        let mine = releaseDaily(install: local, startedAt: rig.clock, dayKey: "2026-09-21")
        let reminted = releaseDaily(install: local, startedAt: rig.clock + 600, dayKey: "2026-09-21")
        let theirsSameDay = try viaCloud(releaseDaily(install: otherPhone, startedAt: rig.clock, dayKey: "2026-09-21"), revision: 1)
        XCTAssertEqual(theirsSameDay.dayKey, "2026-09-21", "rig: the cloud copy keeps its day")

        let oneDay = FixWatchAttention.observatory(localDailies: [mine, reminted], localWindows: [], cloud: [theirsSameDay],
                                                   localInstall: local, sinceDayKey: since)
        XCTAssertEqual(oneDay.source, .cloud(devices: 2), "liveness: both phones' records are in")
        XCTAssertEqual(meTabDays(oneDay.verdicts), 1, "three records, two phones, one day")

        let nextDay = try viaCloud(releaseDaily(install: otherPhone, startedAt: rig.clock - 86_400, dayKey: "2026-09-20"), revision: 1)
        let twoDays = FixWatchAttention.observatory(localDailies: [mine, reminted], localWindows: [],
                                                    cloud: [theirsSameDay, nextDay], localInstall: local, sinceDayKey: since)
        XCTAssertEqual(meTabDays(twoDays.verdicts), 2)
        XCTAssertEqual(FixWatchVerdictEvaluator.evaluateTouchDelivery(dailies: [mine, reminted]).releaseDayCount, 1,
                       "the same rule on this device alone")
    }
}

// MARK: - The DEBUG launch-variable seam (QA)

@MainActor
final class TelemetryFakeTestFlightTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func code(_ relativePath: String) throws -> String {
        EraseWiringScan.strippingComments(
            try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8))
    }

    /// `1` plays TestFlight, `0` the App Store; unset or anything else asks
    /// the real detector.
    func testTheLaunchVariableReadsOneAndZeroAndNothingElse() {
        let key = TelemetryFakeTestFlight.launchVariable
        XCTAssertEqual(key, "TELEMETRY_FAKE_TESTFLIGHT")
        XCTAssertEqual(TelemetryFakeTestFlight.value(in: [key: "1"]), true)
        XCTAssertEqual(TelemetryFakeTestFlight.value(in: [key: "0"]), false)
        XCTAssertNil(TelemetryFakeTestFlight.value(in: [key: "yes"]))
        XCTAssertNil(TelemetryFakeTestFlight.value(in: [:]))
    }

    /// The injection point: `live(isTestFlight:)` answers what it was given;
    /// without it, `live()` answers what the production detector answers.
    func testLiveTakesTheInjectedAnswerAndOtherwiseAsksTheDetector() async {
        let testFlight = await TelemetryUploader.live(isTestFlight: true).dependencies.distribution()
        let appStore = await TelemetryUploader.live(isTestFlight: false).dependencies.distribution()
        XCTAssertEqual(testFlight, .testFlight)
        XCTAssertEqual(appStore, .appStore)
        let real = await TelemetryUploader.live().dependencies.distribution()
        let detector = await TelemetryDistributionDetector.live()
        XCTAssertEqual(real, detector, "no injection: the production detector's answer")
        XCTAssertNotEqual(real, .testFlight, "rig: this simulator test host is not a TestFlight install")
    }

    /// A release build cannot read the variable: the seam's file is one
    /// `#if DEBUG` block from its first line of code to its last, DoneApp
    /// names the seam only inside an `#if DEBUG` branch (liveness: it does
    /// name it), and the uploader never names it at all.
    func testOnlyADebugBuildCanReadTheVariable() throws {
        let seam = try code("Done/Services/TelemetryFakeTestFlight.swift").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(seam.hasPrefix("#if DEBUG"), "the seam's first line of code opens a DEBUG block")
        XCTAssertTrue(seam.hasSuffix("#endif"), "and its last closes it")
        XCTAssertEqual(seam.components(separatedBy: "#endif").count - 1, 1, "one block")
        XCTAssertFalse(seam.contains("#else"), "with no non-DEBUG branch")

        var stack: [Bool] = []   // per open #if: are we in its DEBUG branch?
        var mentions = 0
        for line in try code("Done/DoneApp.swift").components(separatedBy: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#if ") {
                stack.append(text == "#if DEBUG")
            } else if text.hasPrefix("#else") || text.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1] = false }
            } else if text.hasPrefix("#endif") {
                _ = stack.popLast()
            } else if text.contains("TelemetryFakeTestFlight") {
                mentions += 1
                XCTAssertTrue(stack.contains(true), "DoneApp names the seam outside #if DEBUG: \(text)")
            }
        }
        XCTAssertGreaterThan(mentions, 0, "liveness: DoneApp passes the launch variable")

        let uploader = try code("Done/Services/TelemetryUploader.swift")
        XCTAssertFalse(uploader.contains("TelemetryFakeTestFlight"))
        XCTAssertFalse(uploader.contains("TELEMETRY_FAKE_TESTFLIGHT"))
    }
}
