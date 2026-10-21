//
//  SupabaseEnvironmentTests.swift
//  DoneTests
//
//  The environment selection (design D8 as revised 2026-10-21) and the
//  three DEBUG seams the simulator rig needs (design §8.4): the upload
//  gate that blocks production only, the injected session, and the
//  offline switch. Nothing here reaches the network: every URL is
//  `stub.invalid`, every transport is a stub that fails the test if it is
//  called, and the REST client is driven without a session so a request
//  that passes the offline check stops at "not signed in".
//

import XCTest
import Combine
@testable import Done

@MainActor
final class SupabaseEnvironmentTests: XCTestCase {

    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SupabaseEnvironmentTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - The selection table

    /// Every override at once, pointing at `local`: only a DEBUG build
    /// listens.
    private func allOverrides(_ value: String = "local") -> (env: [String: String], args: [String], defaults: UserDefaults) {
        suite.set(value, forKey: SupabaseEnvironment.defaultsKey)
        return (["SYNC_ENV": value], ["SYNC_ENV=\(value)"], suite)
    }

    func testAStagingBuildIsStagingWhateverTheLaunchSays() {
        let o = allOverrides()
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .staging, environment: o.env, arguments: o.args, defaults: o.defaults), .staging)
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .staging, environment: [:], arguments: [], defaults: nil), .staging)
    }

    func testAReleaseBuildIsProductionWhateverTheLaunchSays() {
        let o = allOverrides()
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .release, environment: o.env, arguments: o.args, defaults: o.defaults), .production)
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .release, environment: [:], arguments: [], defaults: nil), .production)
    }

    func testADebugBuildDefaultsToProduction() {
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .debug, environment: [:], arguments: [], defaults: suite), .production)
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .debug, environment: ["OTHER": "local"], arguments: ["-local"], defaults: nil), .production)
    }

    func testTheLaunchVariableSelectsEachOfTheThree() {
        for expected in SupabaseEnvironment.allCases {
            XCTAssertEqual(
                SupabaseEnvironment.resolve(build: .debug, environment: ["SYNC_ENV": expected.rawValue], arguments: [], defaults: suite),
                expected, expected.rawValue)
        }
    }

    func testTheLaunchArgumentSelects() {
        XCTAssertEqual(
            SupabaseEnvironment.resolve(build: .debug, environment: [:], arguments: ["-AppleLanguages", "(en)", "SYNC_ENV=staging"], defaults: suite),
            .staging)
    }

    func testTheDefaultsKeySelects() {
        suite.set("local", forKey: "syncEnvironment")
        XCTAssertEqual(SupabaseEnvironment.defaultsKey, "syncEnvironment")
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .debug, environment: [:], arguments: [], defaults: suite), .local)
    }

    func testTheVariableOutranksTheArgumentWhichOutranksTheDefaultsKey() {
        suite.set("local", forKey: SupabaseEnvironment.defaultsKey)
        XCTAssertEqual(
            SupabaseEnvironment.resolve(build: .debug, environment: ["SYNC_ENV": "production"], arguments: ["SYNC_ENV=staging"], defaults: suite),
            .production)
        XCTAssertEqual(
            SupabaseEnvironment.resolve(build: .debug, environment: [:], arguments: ["SYNC_ENV=staging"], defaults: suite),
            .staging)
        XCTAssertEqual(
            SupabaseEnvironment.resolve(build: .debug, environment: [:], arguments: [], defaults: suite),
            .local)
    }

    func testAnUnknownValueFallsBackToTheDefault() {
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .debug, environment: ["SYNC_ENV": "prod"], arguments: [], defaults: suite), .production)
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .debug, environment: [:], arguments: ["SYNC_ENV=localhost"], defaults: suite), .production)
        suite.set("bogus", forKey: SupabaseEnvironment.defaultsKey)
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .debug, environment: [:], arguments: [], defaults: suite), .production)
        // Unknown means absent, not "stop looking": a lower source still counts.
        suite.set("local", forKey: SupabaseEnvironment.defaultsKey)
        XCTAssertEqual(SupabaseEnvironment.resolve(build: .debug, environment: ["SYNC_ENV": "bogus"], arguments: [], defaults: suite), .local)
    }

    /// The live wiring, as far as a DEBUG test process can see it: this
    /// binary is a DEBUG build, nothing in the test runner's launch asks
    /// for another project, so the process-wide choice is production and
    /// the config the four clients read forwards to it.
    func testThisProcessIsADebugBuildPointedAtProduction() {
        XCTAssertEqual(SupabaseEnvironment.build, .debug)
        XCTAssertNil(ProcessInfo.processInfo.environment["SYNC_ENV"], "the test runner must not steer the environment")
        XCTAssertEqual(SupabaseEnvironment.current, .production)
        XCTAssertEqual(SupabaseSyncConfig.url, SupabaseEnvironment.current.url)
        XCTAssertEqual(SupabaseSyncConfig.publishableKey, SupabaseEnvironment.current.publishableKey)
    }

    func testTheThreeProjectsAreDistinctAndTheKeysArePublishable() {
        XCTAssertTrue(SupabaseEnvironment.production.url.contains("uqnvtzblppjblwgbpqhf"))
        XCTAssertTrue(SupabaseEnvironment.staging.url.contains("gpxpvczmrezgzycypmsk"))
        XCTAssertEqual(SupabaseEnvironment.local.url, "http://127.0.0.1:54321")
        XCTAssertEqual(Set(SupabaseEnvironment.allCases.map(\.url)).count, 3)
        XCTAssertEqual(Set(SupabaseEnvironment.allCases.map(\.publishableKey)).count, 3)
        for environment in SupabaseEnvironment.allCases {
            XCTAssertTrue(environment.publishableKey.hasPrefix("sb_publishable_"), environment.rawValue)
            XCTAssertFalse(environment.displayName.isEmpty)
        }
    }

    /// The developer switch is deliberately not swept by "reset all local
    /// data" (the reason is on its declaration); this pins that it is a
    /// decision, not an omission the erase census would flag.
    func testTheDefaultsKeyIsExemptFromTheEraseByDecision() {
        XCTAssertFalse(AppSettingsKeys.resettableUserDefaultsKeys.contains(SupabaseEnvironment.defaultsKey))
    }

    // MARK: - The upload gate: DEBUG × environment × master switch

    func testInDebugTheBuildBlocksUploadsOnProductionOnly() {
        XCTAssertTrue(SupabaseSyncService.debugBlocksUploads, "these tests run as a DEBUG build")
        for environment in SupabaseEnvironment.allCases {
            for switchOn in [false, true] {
                suite.set(switchOn, forKey: AppSettingsKeys.syncUploadsEnabled)
                let service = SupabaseSyncService(
                    gateway: SyncFakeServer(userId: "u"), userId: "u", defaults: suite, environment: environment)
                let expected = environment == .production ? false : switchOn
                XCTAssertEqual(service.canUpload, expected, "\(environment.rawValue) switch=\(switchOn)")
                XCTAssertEqual(service.uploadsBlockedByBuild, environment == .production, environment.rawValue)
            }
        }
    }

    // MARK: - Session injection

    private func sessionJSON(refreshToken: String = "r-1", expiresIn: TimeInterval = 3600, userId: String = "11111111-2222-4333-8444-555555555555") -> String {
        let expiresAt = Date().addingTimeInterval(expiresIn).timeIntervalSince1970
        return #"{"access_token":"at-1","refresh_token":"\#(refreshToken)","user_id":"\#(userId)","email":"rig@example.com","expires_at":\#(expiresAt)}"#
    }

    /// Fails the test if any request goes out.
    private func noTransport() -> AuthTransport {
        { request in
            XCTFail("no request may go out; got \(request.url?.absoluteString ?? "?")")
            throw URLError(.notConnectedToInternet)
        }
    }

    private func makeAuth(
        store: InMemorySessionStore = InMemorySessionStore(),
        transport: AuthTransport? = nil,
        launch: [String: String],
        environment: SupabaseEnvironment
    ) -> AuthService {
        AuthService(
            url: "https://stub.invalid",
            projectAPIKey: "test-publishable-key",
            defaults: suite,
            sessionStore: store,
            transport: transport ?? noTransport(),
            launchEnvironment: launch,
            syncEnvironment: environment)
    }

    func testAnInjectedSessionSignsInOnTheLocalStackAndTurnsTheMasterSwitchOn() throws {
        let store = InMemorySessionStore()
        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        let auth = makeAuth(store: store, launch: ["SYNC_DEBUG_SESSION": sessionJSON()], environment: .local)

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.userId, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(auth.accessToken, "at-1")
        XCTAssertEqual(auth.session?.refreshToken, "r-1")
        XCTAssertEqual(auth.session?.user.email, "rig@example.com")
        XCTAssertEqual(try XCTUnwrap(auth.session?.expiresAt).timeIntervalSinceNow, 3600, accuracy: 5)
        XCTAssertTrue(suite.bool(forKey: AppSettingsKeys.syncUploadsEnabled), "D9: an interactive sign-in turns the master switch on")
        // Persisted through the real path: the store holds the session.
        let stored = try JSONDecoder().decode(AuthSession.self, from: try XCTUnwrap(store.stored))
        XCTAssertEqual(stored, try XCTUnwrap(auth.session))
        // Published: a subscriber sees it on `$session`.
        var published: [AuthSession?] = []
        let sub = auth.$session.sink { published.append($0) }
        defer { sub.cancel() }
        XCTAssertEqual(published.last??.accessToken, "at-1")
    }

    func testAnInjectedSessionSignsInOnStaging() {
        let auth = makeAuth(launch: ["SYNC_DEBUG_SESSION": sessionJSON()], environment: .staging)
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertTrue(suite.bool(forKey: AppSettingsKeys.syncUploadsEnabled))
    }

    func testTheInjectionIsIgnoredOnProduction() {
        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        let store = InMemorySessionStore()
        let auth = makeAuth(store: store, launch: ["SYNC_DEBUG_SESSION": sessionJSON()], environment: .production)
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(store.stored)
        XCTAssertFalse(suite.bool(forKey: AppSettingsKeys.syncUploadsEnabled))
    }

    func testTheInjectionIsIgnoredWhenAbsentOrNotASession() {
        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        let bad: [[String: String]] = [
            [:],
            ["SYNC_DEBUG_SESSION": ""],
            ["SYNC_DEBUG_SESSION": "not json"],
            ["SYNC_DEBUG_SESSION": "[1,2,3]"],
            ["SYNC_DEBUG_SESSION": #"{"access_token":"","user_id":"u"}"#],
            ["SYNC_DEBUG_SESSION": #"{"access_token":"at","user_id":""}"#],
            ["SYNC_DEBUG_SESSION": #"{"refresh_token":"r","user_id":"u"}"#],
            ["SYNC_DEBUG_SESSION": #"{"access_token":"at","user_id":"u","expires_at":"yesterday"}"#],
            ["SYNC_DEBUG_SESSION": #"{"access_token":"at","user_id":"u","expires_at":true}"#],
        ]
        for launch in bad {
            let store = InMemorySessionStore()
            let auth = makeAuth(store: store, launch: launch, environment: .local)
            XCTAssertFalse(auth.isSignedIn, "\(launch)")
            XCTAssertNil(store.stored, "\(launch)")
            XCTAssertFalse(suite.bool(forKey: AppSettingsKeys.syncUploadsEnabled), "\(launch)")
        }
    }

    func testAnInjectedSessionTakesAnISODateAndDefaultsTheExpiryToAnHour() throws {
        let iso = makeAuth(launch: ["SYNC_DEBUG_SESSION": #"{"access_token":"at","user_id":"u","expires_at":"2031-01-02T03:04:05Z"}"#], environment: .local)
        XCTAssertEqual(iso.session?.expiresAt, ISO8601DateFormatter().date(from: "2031-01-02T03:04:05Z"))
        let bare = makeAuth(launch: ["SYNC_DEBUG_SESSION": #"{"access_token":"at","user_id":"u"}"#], environment: .local)
        XCTAssertEqual(try XCTUnwrap(bare.session?.expiresAt).timeIntervalSinceNow, 3600, accuracy: 5)
        XCTAssertEqual(bare.session?.refreshToken, "")
        XCTAssertNil(bare.session?.user.email)
    }

    /// An empty refresh token means "never refresh": both refresh entry
    /// points return without a request even though the token is inside
    /// the five-minute window, and the session stays.
    func testAnInjectedSessionWithoutARefreshTokenIsNeverRefreshed() async {
        let auth = makeAuth(launch: ["SYNC_DEBUG_SESSION": sessionJSON(refreshToken: "", expiresIn: 60)], environment: .local)
        XCTAssertTrue(auth.isSignedIn)
        await auth.refreshTokenIfNeeded()
        await auth.forceRefreshToken()
        XCTAssertEqual(auth.accessToken, "at-1")
        XCTAssertTrue(auth.isSignedIn)
    }

    /// The positive control for the guard above: the same injected session
    /// WITH a refresh token refreshes through the ordinary path.
    func testAnInjectedSessionWithARefreshTokenRefreshesNormally() async throws {
        var calls = 0
        let transport: AuthTransport = { request in
            calls += 1
            XCTAssertTrue(request.url?.absoluteString.contains("grant_type=refresh_token") == true)
            let body = #"{"access_token":"at-2","refresh_token":"r-2","expires_in":3600,"user":{"id":"u","email":null}}"#
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!
            return (Data(body.utf8), http)
        }
        let auth = makeAuth(transport: transport, launch: ["SYNC_DEBUG_SESSION": sessionJSON(refreshToken: "r-1", expiresIn: 60)], environment: .local)
        await auth.refreshTokenIfNeeded()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(auth.accessToken, "at-2")
    }

    /// The injected session is a real one afterwards: a relaunch with the
    /// same store and no variable restores it the ordinary way.
    func testAnInjectedSessionSurvivesARelaunchWithoutTheVariable() {
        let store = InMemorySessionStore()
        _ = makeAuth(store: store, launch: ["SYNC_DEBUG_SESSION": sessionJSON()], environment: .local)
        let relaunched = makeAuth(store: store, launch: [:], environment: .local)
        XCTAssertEqual(relaunched.accessToken, "at-1")
    }

    // MARK: - D9: the master switch defaults ON, signing in turns it on, OFF stops both directions

    /// An unset key reads ON once the launch defaults are registered; an
    /// explicit OFF is kept (no migration write). The "default is not ON"
    /// mutant reads OFF.
    func testTheMasterSwitchDefaultsOnAndAnExplicitOffStands_killsDefaultNotOn() {
        XCTAssertNil(suite.object(forKey: AppSettingsKeys.syncUploadsEnabled), "fixture: unset")
        AppSettingsKeys.registerLaunchDefaults(in: suite)
        XCTAssertTrue(suite.bool(forKey: AppSettingsKeys.syncUploadsEnabled))
        XCTAssertNil(suite.persistentDomain(forName: suiteName)?[AppSettingsKeys.syncUploadsEnabled],
                     "registration writes nothing to disk")
        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        AppSettingsKeys.registerLaunchDefaults(in: suite)
        XCTAssertFalse(suite.bool(forKey: AppSettingsKeys.syncUploadsEnabled), "the user's OFF stands")
    }

    /// The app registered it at launch (DoneTests runs inside the host app,
    /// whose `DoneApp.init` ran before any test).
    func testTheAppRegistersTheMasterSwitchOnAtLaunch() {
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[AppSettingsKeys.syncUploadsEnabled] as? Bool, true)
    }

    /// An interactive sign-in turns the switch on, and does so BEFORE the
    /// session publishes: the engine's session sink reads the switch at
    /// that moment. The "sign-in does not turn it on" mutant leaves it OFF.
    func testAnAppleSignInTurnsTheMasterSwitchOnBeforeTheSessionPublishes_killsSignInLeavesItOff() async throws {
        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        let transport: AuthTransport = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("grant_type=id_token") == true)
            let body = #"{"access_token":"at-apple","refresh_token":"r-apple","expires_in":3600,"user":{"id":"u-apple","email":null}}"#
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!
            return (Data(body.utf8), http)
        }
        let auth = makeAuth(transport: transport, launch: [:], environment: .local)
        XCTAssertFalse(auth.isSignedIn, "fixture: signed out")
        var switchWhenPublished: [Bool] = []
        let sub = auth.$session.dropFirst().sink { [suite] session in
            if session != nil { switchWhenPublished.append(suite!.bool(forKey: AppSettingsKeys.syncUploadsEnabled)) }
        }
        defer { sub.cancel() }

        await auth.signInWithApple(idToken: "id-token", nonce: "nonce")

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertTrue(suite.bool(forKey: AppSettingsKeys.syncUploadsEnabled))
        XCTAssertEqual(switchWhenPublished, [true], "the switch was already ON when the session published")
    }

    /// Positive control: a refresh never turns a user's OFF back on.
    func testARefreshLeavesAnOffSwitchOff() async {
        let transport: AuthTransport = { request in
            let body = #"{"access_token":"at-2","refresh_token":"r-2","expires_in":3600,"user":{"id":"u","email":null}}"#
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!
            return (Data(body.utf8), http)
        }
        let auth = makeAuth(transport: transport, launch: ["SYNC_DEBUG_SESSION": sessionJSON(refreshToken: "r-1", expiresIn: 60)], environment: .local)
        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        await auth.forceRefreshToken()
        XCTAssertEqual(auth.accessToken, "at-2", "fixture: the refresh ran")
        XCTAssertFalse(suite.bool(forKey: AppSettingsKeys.syncUploadsEnabled))
    }

    /// D9 gates both directions: with the switch off, a signed-in session
    /// starts no puller and sends no request; on starts it; off stops it
    /// again. The "the sink starts the puller regardless" mutant has it
    /// active with the switch off.
    func testWithTheMasterSwitchOffTheSessionNeitherPullsNorPushes_killsPullerIgnoresTheSwitch() async throws {
        let uid = "11111111-2222-4333-8444-555555555555"
        let auth = makeAuth(launch: ["SYNC_DEBUG_SESSION": sessionJSON(userId: uid)], environment: .local)
        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        let server = SyncFakeServer(userId: uid)
        let storeSuite = suiteName + "-store"
        defer { TestStorage.tearDown(storeSuite) }
        let store = EventStore(defaults: suite, storage: TestStorage.reset(storeSuite), seedsSampleDataIfEmpty: false)
        let types = EventTypeTemplateStore(defaults: suite)
        let skills = SkillInsightStore(defaults: suite)
        let prefsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("D9-prefs-\(UUID().uuidString)", isDirectory: true)
        let shelfDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("D9-shelf-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: prefsDirectory)
            try? FileManager.default.removeItem(at: shelfDirectory)
        }
        let prefs = AgentPreferenceStore(directoryURL: prefsDirectory)
        let service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: suite,
                                          scheduler: SyncManualScheduler(), environment: .local)
        service.attachStores(eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)
        let puller = service.installInbound(shelf: ConflictShelf(directory: shelfDirectory))
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()

        service.attach(authService: auth, eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)

        XCTAssertTrue(auth.isSignedIn, "fixture: a session is there")
        XCTAssertFalse(service.canUpload)
        XCTAssertFalse(puller.active, "switch off: no puller")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(server.requests.count, 0, "switch off: not one request")

        suite.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        service.userDidEnableUploads()
        XCTAssertTrue(puller.active, "switch on: the puller runs")

        suite.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        service.userDidDisableUploads()
        XCTAssertFalse(puller.active, "switch off again: the puller stops")
        puller.endSession()
    }

    /// The account card: with the switch off it says sync is off, not
    /// "Connected" (sim QA round 2: "Connected" over an empty calendar).
    func testTheAccountCardSaysSyncIsOffWhenTheSwitchIsOff() {
        XCTAssertEqual(AccountSyncStatus.resolve(masterSwitchOn: false, ownerAllowsSync: true), .syncOff)
        XCTAssertEqual(AccountSyncStatus.resolve(masterSwitchOn: false, ownerAllowsSync: false), .syncOff)
        XCTAssertEqual(AccountSyncStatus.resolve(masterSwitchOn: true, ownerAllowsSync: true), .connected)
        XCTAssertEqual(AccountSyncStatus.resolve(masterSwitchOn: true, ownerAllowsSync: false), .stopped)
        XCTAssertEqual(LKey.syncOffLabel.text(for: .english), "Sync is off")
        XCTAssertEqual(LKey.syncOffLabel.text(for: .chinese), "同步已关闭")
    }

    /// The settings copy says both directions, in both languages.
    func testTheSwitchCopySaysBothDirections() {
        let en = LKey.uploadToCloudHint.text(for: .english)
        XCTAssertTrue(en.contains("neither uploads nor downloads"), en)
        XCTAssertFalse(en.contains("only reads"), en)
        let zh = LKey.uploadToCloudHint.text(for: .chinese)
        XCTAssertTrue(zh.contains("既不上传也不下载"), zh)
        XCTAssertFalse(zh.contains("仅读取"), zh)
    }

    // MARK: - The offline switch

    private func withOfflineFile<T>(_ body: (_ path: String) async throws -> T) async rethrows -> T {
        let path = NSTemporaryDirectory() + "SupabaseEnvironmentTests-offline-\(UUID().uuidString)"
        let previous = SyncOfflineSwitch.filePath
        SyncOfflineSwitch.filePath = path
        defer {
            SyncOfflineSwitch.filePath = previous
            try? FileManager.default.removeItem(atPath: path)
        }
        return try await body(path)
    }

    private func touch(_ path: String) {
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
    }

    private func assertNotConnected<T>(_ op: () async throws -> T, _ label: String) async {
        do {
            _ = try await op()
            XCTFail("\(label): went out")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet, label)
        } catch {
            XCTFail("\(label): \(error)")
        }
    }

    /// With no session the request stops at the token step, so "the
    /// request proceeded" is observable without a network.
    private func assertProceedsToTheTokenStep<T>(_ op: () async throws -> T, _ label: String) async {
        do {
            _ = try await op()
            XCTFail("\(label): a request with no session cannot succeed")
        } catch SupabaseREST.SyncError.notSignedIn {
            // expected
        } catch {
            XCTFail("\(label): \(error)")
        }
    }

    func testTheOfflineFileStopsEveryRestRequestBeforeItGoesOutAndRemovingItReopens() async {
        let rest = SupabaseREST(url: "https://stub.invalid", projectAPIKey: "k", authService: nil as AuthService?)
        await withOfflineFile { path in
            touch(path)
            await assertNotConnected({ try await rest.fetchSyncEpoch() }, "send while offline")
            await assertNotConnected({ try await rest.fetchAll(table: "events", userId: "u") }, "fetchAll while offline")
            await assertNotConnected({ try await rest.pullChanges(sinceSeq: 0, pageLimit: 10) }, "pull while offline")

            try? FileManager.default.removeItem(atPath: path)
            await assertProceedsToTheTokenStep({ try await rest.fetchSyncEpoch() }, "send after rm")
            await assertProceedsToTheTokenStep({ try await rest.fetchAll(table: "events", userId: "u") }, "fetchAll after rm")

            // Checked on every request: back offline without a relaunch.
            touch(path)
            await assertNotConnected({ try await rest.fetchSyncEpoch() }, "send offline again")
        }
    }

    func testAnUnarmedSwitchIsOpen() async {
        let rest = SupabaseREST(url: "https://stub.invalid", projectAPIKey: "k", authService: nil as AuthService?)
        let previous = SyncOfflineSwitch.filePath
        SyncOfflineSwitch.filePath = nil
        defer { SyncOfflineSwitch.filePath = previous }
        await assertProceedsToTheTokenStep({ try await rest.fetchSyncEpoch() }, "unarmed")
    }

    /// The doorbell's LIVE dependencies, with only the socket and the sleep
    /// replaced: while the file exists no socket is ever made and the loop
    /// backs off; once it is gone the next attempt opens one.
    func testTheOfflineFileKeepsTheDoorbellFromConnectingUntilItIsRemoved() async throws {
        let auth = makeAuth(launch: ["SYNC_DEBUG_SESSION": sessionJSON()], environment: .local)
        XCTAssertTrue(auth.isSignedIn)
        let sockets = Counter()
        let sleeper = GateSleeper()
        var deps = SupabaseRealtimeDoorbell.Dependencies.live(authService: auth)
        deps.socketFactory = { _ in
            sockets.count += 1
            return ParkedSocket()
        }
        deps.sleep = { _ in try await sleeper.sleep() }
        let doorbell = SupabaseRealtimeDoorbell(
            socketURL: URL(string: "wss://stub.invalid/realtime/v1/websocket?apikey=k&vsn=1.0.0")!,
            dependencies: deps)
        defer {
            doorbell.stop()
            sleeper.cancelAll()
        }

        await withOfflineFile { path in
            touch(path)
            let backedOff = expectation(description: "backoff")
            doorbell.onStateChange = { state in
                if case .backoff = state { backedOff.fulfill() }
            }
            doorbell.start()
            await fulfillment(of: [backedOff], timeout: 5)
            XCTAssertEqual(sockets.count, 0, "no socket may be made while offline")

            try? FileManager.default.removeItem(atPath: path)
            let connected = expectation(description: "socket made")
            sockets.onIncrement = { connected.fulfill() }
            sleeper.releaseAll()
            await fulfillment(of: [connected], timeout: 5)
            XCTAssertEqual(sockets.count, 1)
        }
    }
}

// MARK: - Doubles

@MainActor
private final class Counter {
    var count = 0 { didSet { onIncrement?() } }
    var onIncrement: (() -> Void)?
}

/// A socket that accepts frames and never answers; `close()` fails the
/// pending receive, like a dropped connection.
private final class ParkedSocket: RealtimeSocket {
    private var waiter: CheckedContinuation<String, Error>?
    func send(text: String) async throws {}
    func receiveText() async throws -> String {
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() {
        waiter?.resume(throwing: URLError(.cancelled))
        waiter = nil
    }
}

/// A sleep the test owns: nothing resumes until the test says so.
@MainActor
private final class GateSleeper {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    func sleep() async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func releaseAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
    func cancelAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
