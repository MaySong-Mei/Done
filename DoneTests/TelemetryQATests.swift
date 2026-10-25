//
//  TelemetryQATests.swift
//  DoneTests
//
//  gh#273 — independent QA: tests added because a mutant of the chassis
//  survived the suite as shipped. Each test names the mutant it was written
//  against and carries its own positive control, so a green run means the
//  instrument saw the thing it claims to forbid.
//

import UIKit
import XCTest
@testable import Done

@MainActor
final class TelemetryQATests: XCTestCase {
    private let uid = TelemetryFixtures.uid
    private var location: SpikeRunStorageLocation!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var clock = TelemetryFixtures.t0
    private var retained: [AnyObject] = []

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        suiteName = "TelemetryQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.register(defaults: AppSettingsKeys.launchRegisteredDefaults)
        clock = TelemetryFixtures.t0
    }

    override func tearDown() {
        TelemetryHTTPStub.uninstall()
        SpikeRunStore.ownerProvider = nil
        try? FileManager.default.removeItem(at: location.directory)
        defaults.removePersistentDomain(forName: suiteName)
        retained = []
        super.tearDown()
    }

    private func makeUploader() -> TelemetryUploader {
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.now = { [unowned self] in self.clock }
        deps.launchDelay = 0
        deps.makeBackgroundAssertion = { nil }
        return TelemetryUploader(dependencies: deps)
    }

    /// The app's real gateway over the URLProtocol stub, with an injected,
    /// unrefreshable session (same shape as TelemetryUploaderTests).
    private func realGateway() -> SupabaseREST {
        let json = #"{"access_token":"at-qa","refresh_token":"","user_id":"\#(uid)","email":"qa@example.com"}"#
        let auth = AuthService(
            url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
            sessionStore: InMemorySessionStore(),
            transport: { request in
                XCTFail("no auth request may go out; got \(request.url?.absoluteString ?? "?")")
                throw URLError(.notConnectedToInternet)
            },
            launchEnvironment: ["SYNC_DEBUG_SESSION": json], syncEnvironment: .local
        )
        XCTAssertTrue(auth.isSignedIn, "rig: the injected session must be live")
        retained.append(auth)
        return SupabaseREST(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", authService: auth)
    }

    private func attach(_ uploader: TelemetryUploader, gateway: SupabaseREST) {
        uploader.attach(TelemetryUploader.Attachment(
            gateway: gateway,
            isBlockedByBuild: { false },
            currentUserID: { [uid] in uid },
            isSignedIn: { true }
        ))
    }

    private func turnOn() {
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: clock.addingTimeInterval(-3600))
    }

    private func seedDaily() -> SpikeRun {
        let run = TelemetryFixtures.run(startedAt: clock, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(run, location: location), "seed must land")
        return run
    }

    private func telemetryRequests() -> [TelemetryHTTPStub.Captured] {
        TelemetryHTTPStub.all.filter { $0.request.url?.path.hasSuffix("/spike_runs") == true }
    }

    // MARK: - Mutant: `upsertRows` sent with `isWrite: true`

    /// Wire contract §1: a telemetry upsert carries no `X-Sync-Epoch`. The
    /// shipped suite asserts that header is absent on a gateway whose epoch
    /// is nil — where a mutant that routes the upsert through the write path
    /// (`isWrite: true`) still sends no header, because there is none to
    /// send. Here the gateway HOLDS an epoch: a sync write on the same
    /// gateway carries it (positive control), the telemetry upsert still
    /// must not.
    func testTelemetryUpsertCarriesNoSyncEpochEvenWhenTheGatewayHoldsOne() async throws {
        TelemetryHTTPStub.install()
        TelemetryHTTPStub.reset()
        let gateway = realGateway()
        gateway.writeEpoch = "epoch-qa-\(UUID().uuidString)"

        // Positive control: the sync engine's own write path stamps the epoch.
        try await gateway.upsertMerging(table: "todo_lists", keyColumn: "id", rows: [["id": UUID().uuidString, "title": "qa"]])
        let syncWrite = try XCTUnwrap(TelemetryHTTPStub.all.last, "the control request reached the stub")
        XCTAssertTrue(syncWrite.request.url?.path.hasSuffix("/todo_lists") == true)
        XCTAssertEqual(syncWrite.request.value(forHTTPHeaderField: SupabaseREST.epochHeaderField), gateway.writeEpoch,
                       "positive control: a sync write on this gateway carries the epoch header")

        let uploader = makeUploader()
        attach(uploader, gateway: gateway)
        turnOn()
        seedDaily()
        let outcome = await uploader.uploadNow(trigger: .launch)
        XCTAssertEqual(outcome, .uploaded(rows: 1))
        let telemetry = try XCTUnwrap(telemetryRequests().last, "the telemetry request reached the stub")
        XCTAssertEqual(telemetry.request.url?.absoluteString, "https://stub.invalid/rest/v1/spike_runs?on_conflict=user_id,run_id")
        XCTAssertNil(telemetry.request.value(forHTTPHeaderField: SupabaseREST.epochHeaderField),
                     "wire §1: the telemetry table is outside the 015 epoch gate even when the gateway holds an epoch")
        XCTAssertEqual(telemetry.request.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=minimal")
    }
}
