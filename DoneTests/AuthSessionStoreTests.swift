import XCTest
import Security
@testable import Done

// gh#249: the session moved from `UserDefaults` into the Keychain. Every
// test here is about one of the four data-preservation gates the issue
// named — migration, read failure, write failure, clearing — and the one
// rule they all obey: the storage layer is never the reason a user is
// signed out (gh#234's red line, applied to persistence).

// MARK: - Doubles

/// A store that can be told to fail each operation independently, and to
/// "succeed" at a write while storing nothing. Counters make "nothing was
/// deleted" an assertion rather than an absence.
@MainActor
private final class ScriptedSessionStore: AuthSessionStore {
    var stored: Data?
    var loadError: Error?
    var saveError: Error?
    var deleteError: Error?
    /// `save` returns normally and keeps nothing — the store that lies.
    var savesSilentlyLose = false
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    struct Failure: Error {}

    func load() throws -> Data? {
        loadCount += 1
        if let loadError { throw loadError }
        return stored
    }

    func save(_ data: Data) throws {
        saveCount += 1
        if let saveError { throw saveError }
        if !savesSilentlyLose { stored = data }
    }

    func delete() throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        stored = nil
    }
}

private final class ScriptedTransport {
    var responses: [(Data, URLResponse)] = []
    private(set) var calls = 0

    func call(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        guard !responses.isEmpty else { throw URLError(.cancelled) }
        return responses.removeFirst()
    }
}

private func refreshSuccess(refreshToken: String, userId: String = "u1") -> (Data, URLResponse) {
    let body = #"{"access_token":"AT-\#(refreshToken)","refresh_token":"\#(refreshToken)","expires_in":3600,"user":{"id":"\#(userId)","email":null}}"#
    let http = HTTPURLResponse(
        url: URL(string: "https://stub.invalid/auth/v1/token")!,
        statusCode: 200, httpVersion: "HTTP/2", headerFields: [:]
    )!
    return (Data(body.utf8), http)
}

private func refreshTerminal() -> (Data, URLResponse) {
    let body = #"{"code":400,"error_code":"refresh_token_already_used","msg":"boom"}"#
    let http = HTTPURLResponse(
        url: URL(string: "https://stub.invalid/auth/v1/token")!,
        statusCode: 400, httpVersion: "HTTP/2", headerFields: [:]
    )!
    return (Data(body.utf8), http)
}

@MainActor
private func sessionBytes(refreshToken: String, userId: String = "u1") -> Data {
    let session = AuthSession(
        accessToken: "AT-\(refreshToken)",
        refreshToken: refreshToken,
        expiresAt: Date(timeIntervalSinceNow: 3600),
        user: AuthUser(id: userId, email: nil, createdAt: nil)
    )
    return try! JSONEncoder().encode(session)
}

// MARK: - AuthService against the seam

@MainActor
final class AuthSessionStoreTests: XCTestCase {

    private var suiteName = ""
    private var suite: UserDefaults!
    private var store: ScriptedSessionStore!
    private var transport: ScriptedTransport!

    override func setUp() {
        super.setUp()
        suiteName = "AuthSessionStoreTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        store = ScriptedSessionStore()
        transport = ScriptedTransport()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func seedLegacy(_ bytes: Data) {
        suite.set(bytes, forKey: AuthService.sessionDefaultsKey)
    }

    private var legacyCopy: Data? { suite.data(forKey: AuthService.sessionDefaultsKey) }

    private func makeAuth() -> AuthService {
        AuthService(
            url: "https://stub.invalid",
            projectAPIKey: "test-publishable-key",
            defaults: suite,
            sessionStore: store,
            transport: { [transport] request in try await transport!.call(request) }
        )
    }

    // MARK: Gate (a) — migration

    func testAnInstalledUsersSessionIsCarriedIntoTheStoreAndTheLegacyCopyRemoved() {
        let bytes = sessionBytes(refreshToken: "S1")
        seedLegacy(bytes)

        let auth = makeAuth()

        XCTAssertEqual(auth.session?.refreshToken, "S1", "the installed user stays signed in")
        XCTAssertEqual(store.stored, bytes, "the store now holds the very bytes the legacy copy held")
        XCTAssertNil(legacyCopy, "the legacy copy is gone once the store verifiably holds the session")
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testTheLegacyCopyStaysWhenTheStoreCannotReadTheWriteBack() {
        let bytes = sessionBytes(refreshToken: "S1")
        seedLegacy(bytes)
        store.savesSilentlyLose = true

        let auth = makeAuth()

        XCTAssertEqual(auth.session?.refreshToken, "S1", "signed in regardless")
        XCTAssertGreaterThan(store.saveCount, 0, "liveness: a migration write was attempted")
        XCTAssertNil(store.stored, "the lying store kept nothing")
        XCTAssertEqual(legacyCopy, bytes,
                       "a write that 'succeeded' but cannot be read back must not cost the only copy")
    }

    func testARelaunchAfterMigrationReadsTheStoreWithNoLegacyCopyAnywhere() {
        seedLegacy(sessionBytes(refreshToken: "S1"))
        _ = makeAuth()
        XCTAssertNil(legacyCopy, "precondition: migration completed")

        let relaunched = makeAuth()

        XCTAssertEqual(relaunched.session?.refreshToken, "S1")
        XCTAssertNil(legacyCopy)
    }

    func testTheStoreWinsOverAStaleLegacyCopyWhichIsThenRemoved() {
        let stored = sessionBytes(refreshToken: "S2")
        store.stored = stored
        seedLegacy(sessionBytes(refreshToken: "S1"))

        let auth = makeAuth()

        XCTAssertEqual(auth.session?.refreshToken, "S2",
                       "the store is authoritative; the legacy copy is what an interrupted migration left")
        XCTAssertNil(legacyCopy)
        XCTAssertEqual(store.stored, stored, "the store item is untouched")
        XCTAssertEqual(store.saveCount, 0, "nothing needed writing")
    }

    // MARK: Gate (b) — read failure is not sign-out

    func testAReadFailureFallsBackToTheLegacyCopyAndKeepsIt() {
        let bytes = sessionBytes(refreshToken: "S1")
        seedLegacy(bytes)
        store.loadError = ScriptedSessionStore.Failure()

        let auth = makeAuth()

        XCTAssertEqual(auth.session?.refreshToken, "S1", "the legacy copy is the fallback")
        XCTAssertFalse(auth.needsReauthentication, "a read failure is not a terminal refresh")
        XCTAssertEqual(legacyCopy, bytes,
                       "the store cannot be read back, so the legacy copy must survive as the fallback")
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testAReadFailureWithNoLegacyCopyClearsNothing() {
        store.stored = sessionBytes(refreshToken: "S1")   // present, but unreadable
        store.loadError = ScriptedSessionStore.Failure()

        let auth = makeAuth()

        XCTAssertNil(auth.session, "nothing could be loaded")
        XCTAssertEqual(store.deleteCount, 0, "an unreadable store is never treated as signed-out")
        XCTAssertEqual(store.saveCount, 0, "and nothing is overwritten")
        XCTAssertNotNil(store.stored, "the item is still there for the next launch")
        XCTAssertFalse(auth.needsReauthentication)
        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
    }

    func testCorruptStoreBytesFallBackToTheLegacyCopyAndAreRepaired() {
        let bytes = sessionBytes(refreshToken: "S1")
        store.stored = Data("not json".utf8)
        seedLegacy(bytes)

        let auth = makeAuth()

        XCTAssertEqual(auth.session?.refreshToken, "S1")
        XCTAssertEqual(store.stored, bytes, "the legacy copy repaired the store")
        XCTAssertNil(legacyCopy)
    }

    func testCorruptStoreBytesWithNoLegacyCopyClearNothing() {
        store.stored = Data("not json".utf8)

        let auth = makeAuth()

        XCTAssertNil(auth.session)
        XCTAssertEqual(store.deleteCount, 0)
        XCTAssertFalse(auth.needsReauthentication)
    }

    // MARK: Gate (c) — write failure keeps the in-memory session

    func testAWriteFailureKeepsTheInMemorySessionAndTheNextSaveRetries() async {
        let legacy = sessionBytes(refreshToken: "S1")
        seedLegacy(legacy)
        store.saveError = ScriptedSessionStore.Failure()

        let auth = makeAuth()
        XCTAssertEqual(auth.session?.refreshToken, "S1")
        XCTAssertEqual(legacyCopy, legacy, "migration could not complete; the legacy copy stays")

        // A refresh succeeds on the server while the store still refuses.
        transport.responses = [refreshSuccess(refreshToken: "S2")]
        await auth.forceRefreshToken()

        XCTAssertEqual(transport.calls, 1, "liveness: the refresh was made")
        XCTAssertEqual(auth.session?.refreshToken, "S2",
                       "the new session is adopted in memory even though it could not be persisted")
        XCTAssertNil(store.stored)
        XCTAssertFalse(auth.needsReauthentication, "a write failure is not a clear")
        XCTAssertEqual(store.deleteCount, 0)

        // The store recovers; the next save is the retry.
        store.saveError = nil
        transport.responses = [refreshSuccess(refreshToken: "S3")]
        await auth.forceRefreshToken()

        XCTAssertEqual(auth.session?.refreshToken, "S3")
        let persisted = store.stored.flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
        XCTAssertEqual(persisted?.refreshToken, "S3",
                       "the first save after recovery persists the live session")
        XCTAssertNil(legacyCopy, "and only now is the legacy copy released")
    }

    // MARK: Gate (d) — clearing is one write point and deletes both

    func testSignOutDeletesTheStoreItemTheLegacyKeyAndTheMemoryCopy() {
        seedLegacy(sessionBytes(refreshToken: "S1"))
        let auth = makeAuth()
        XCTAssertNotNil(store.stored, "precondition: migrated")
        // A legacy copy that reappeared (an interrupted migration on a later
        // launch) must go too.
        seedLegacy(sessionBytes(refreshToken: "S1"))

        auth.signOut()

        XCTAssertNil(auth.session)
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(store.stored, "the store item is deleted")
        XCTAssertEqual(store.deleteCount, 1)
        XCTAssertNil(legacyCopy, "the legacy key is removed")
        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
    }

    func testATerminalRefreshDeletesTheStoreItemToo() async {
        seedLegacy(sessionBytes(refreshToken: "S1"))
        let auth = makeAuth()
        transport.responses = [refreshTerminal()]

        await auth.forceRefreshToken()

        XCTAssertNil(auth.session)
        XCTAssertNil(store.stored)
        XCTAssertNil(legacyCopy)
        XCTAssertTrue(auth.needsReauthentication)
    }

    func testAStoreDeleteFailureStillEndsTheInMemorySessionAndTheLegacyKey() {
        seedLegacy(sessionBytes(refreshToken: "S1"))
        let auth = makeAuth()
        store.deleteError = ScriptedSessionStore.Failure()

        auth.signOut()

        XCTAssertNil(auth.session, "the in-memory half of the clear never depends on the store")
        XCTAssertNil(legacyCopy)
        XCTAssertEqual(store.deleteCount, 1, "liveness: the delete was attempted")
    }

    func testTheResetSweepRemovesTheLegacySessionKey() {
        seedLegacy(sessionBytes(refreshToken: "S1"))
        XCTAssertNotNil(legacyCopy)

        AppSettingsKeys.removeResettableKeys(from: suite)

        XCTAssertNil(legacyCopy, "an interrupted migration's copy must not survive a reset")
    }

    /// The reset flow is a SwiftUI view's private method, so its wiring is
    /// pinned by text, the same way gh#234 pinned `forgetReauthenticationNotice`.
    /// Two facts: the flow signs out through `AuthService.signOut()` after the
    /// sweep, and the store delete has exactly one non-comment site in
    /// `AuthService` — the single write point the issue requires to survive
    /// the move.
    func testTheResetFlowSignsOutThroughTheSingleWritePoint() {
        let settings = source("Done/Services/LocalDataEraser.swift")
        XCTAssertFalse(settings.isEmpty, "liveness: LocalDataEraser.swift must be readable")
        XCTAssertNil(settings.range(of: "authService.signOutXYZ()"), "control: the search can come up empty")

        guard let reset = settings.range(of: "func resetAllLocalData(keepingSession: Bool) {") else {
            return XCTFail("resetAllLocalData() was renamed; this guard must be revisited")
        }
        let body = String(settings[reset.upperBound...])
        guard let sweep = body.range(of: "AppSettingsKeys.removeResettableKeys") else {
            return XCTFail("resetAllLocalData() no longer runs the named-key sweep")
        }
        guard let signOut = body.range(of: "authService.signOut()") else {
            return XCTFail("the sweep cannot reach the Keychain or the live session; without signOut() "
                           + "a reset comes back signed in as the account whose data it just erased")
        }
        XCTAssertLessThan(sweep.lowerBound, signOut.lowerBound)

        let service = source("Done/Services/AuthService.swift")
        XCTAssertFalse(service.isEmpty, "liveness: AuthService.swift must be readable")
        let codeLines = service.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        XCTAssertEqual(codeLines.filter { $0.contains("session = nil") }.count, 1,
                       "clearSession(reason:) is the only `session = nil`")
        XCTAssertEqual(codeLines.filter { $0.contains("sessionStore.delete()") }.count, 1,
                       "clearSession(reason:) is the only store delete")
    }

    private func source(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - The real Keychain (hosted in Done.app on the simulator)

/// Each test uses its own `service` so nothing here touches the host app's
/// real session item, and `tearDown` deletes what the test wrote.
/// The demo seed (design §7 Phase 1; sim QA S0 / S5): no demo events on a
/// device that has, or has had, a session — they would upload into the
/// account.
@MainActor
final class AuthDemoSeedTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let injection = [AuthService.injectedSessionVariable: #"{"access_token":"t","user_id":"u-1"}"#]

    override func setUp() {
        super.setUp()
        suiteName = "AuthDemoSeedTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func seeds(_ store: AuthSessionStore, environment: [String: String] = [:],
                       on syncEnvironment: SupabaseEnvironment = .local) -> Bool {
        AuthService.seedsSampleData(sessionStore: store, defaults: defaults,
                                    launchEnvironment: environment, syncEnvironment: syncEnvironment)
    }

    func testADeviceThatNeverHadASessionSeeds() {
        XCTAssertTrue(seeds(InMemorySessionStore()))
    }

    func testAPersistedSessionMeansNoSeed_killsSeedWithSession() {
        XCTAssertFalse(seeds(InMemorySessionStore(stored: Data("{}".utf8))))
    }

    func testALegacySessionMeansNoSeed() {
        defaults.set(Data("{}".utf8), forKey: AuthService.sessionDefaultsKey)
        XCTAssertFalse(seeds(InMemorySessionStore()))
    }

    func testAnInjectedSessionMeansNoSeedExceptOnProductionWhereItIsIgnored() {
        XCTAssertFalse(seeds(InMemorySessionStore(), environment: injection, on: .local))
        XCTAssertTrue(seeds(InMemorySessionStore(), environment: injection, on: .production),
                      "production ignores the injection, as AuthService does")
    }

    /// QA S5: erase, relaunch, sign in again — ten more demo rows in the
    /// account. A device that has held a session does not seed after the
    /// erase signed it out and swept the defaults.
    func testADeviceThatHadASessionDoesNotSeedAfterTheErase_killsForgetsItHadOne() {
        let auth = AuthService(url: "http://127.0.0.1:9", projectAPIKey: "k", defaults: defaults,
                               sessionStore: InMemorySessionStore(), launchEnvironment: injection, syncEnvironment: .local)
        XCTAssertTrue(auth.isSignedIn, "fixture: the injected session was installed")
        auth.signOut()
        AppSettingsKeys.removeResettableKeys(from: defaults)
        XCTAssertFalse(seeds(InMemorySessionStore()))
    }

    func testTheMarkIsExemptFromTheEraseByDecision() {
        XCTAssertFalse(AppSettingsKeys.resettableUserDefaultsKeys.contains(AuthService.everSignedInKey))
    }
}

@MainActor
final class KeychainSessionStoreTests: XCTestCase {

    private var store: KeychainSessionStore!

    override func setUp() {
        super.setUp()
        store = KeychainSessionStore(service: "KeychainSessionStoreTests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? store.delete()
        super.tearDown()
    }

    func testRoundTripOverwriteAndDelete() throws {
        XCTAssertNil(try store.load(), "a fresh service has no item")

        try store.save(Data("one".utf8))
        XCTAssertEqual(try store.load(), Data("one".utf8))

        try store.save(Data("two".utf8))
        XCTAssertEqual(try store.load(), Data("two".utf8), "save overwrites in place")

        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.delete(), "deleting an absent item is not an error")
    }

    /// The attribute is the whole point of gh#249: `ThisDeviceOnly` is what
    /// keeps the token out of backups. Read it back from the item itself.
    func testTheItemIsAfterFirstUnlockThisDeviceOnly() throws {
        try store.save(Data("bytes".utf8))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: store.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = result as? [String: Any]
        XCTAssertEqual(attributes?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testAuthServiceMigratesIntoTheRealKeychainAndSignOutRemovesIt() throws {
        let suiteName = "KeychainSessionStoreTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let bytes = sessionBytes(refreshToken: "K1")
        suite.set(bytes, forKey: AuthService.sessionDefaultsKey)

        let auth = AuthService(url: "https://stub.invalid", defaults: suite, sessionStore: store,
                               transport: { _ in throw URLError(.cancelled) })
        XCTAssertEqual(auth.session?.refreshToken, "K1")
        XCTAssertEqual(try store.load(), bytes, "migrated into the Keychain")
        XCTAssertNil(suite.data(forKey: AuthService.sessionDefaultsKey))

        let relaunched = AuthService(url: "https://stub.invalid", defaults: suite, sessionStore: store,
                                     transport: { _ in throw URLError(.cancelled) })
        XCTAssertEqual(relaunched.session?.refreshToken, "K1", "a relaunch reads the Keychain")

        relaunched.signOut()
        XCTAssertNil(try store.load(), "sign-out deleted the Keychain item")
    }
}
