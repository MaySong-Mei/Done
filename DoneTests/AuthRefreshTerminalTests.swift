//
//  AuthRefreshTerminalTests.swift
//  DoneTests
//
//  gh#234. A refresh token entered a permanently dead state
//  (`refresh_token_already_used`); the app retried it 202 times over 2.5
//  hours, never told the user, and offered no way out — `isSignedIn` stayed
//  true, so `AccountView` never showed the sign-in page.
//
//  THE RED LINE these tests defend: the default is to KEEP the session.
//  An unknown code, a parse failure, a `URLError`, a 429, any 5xx — all keep
//  it. Misclassifying a transient failure as terminal signs users out on
//  flaky wifi, which is worse than the bug being fixed. Terminal
//  classification is a positive allowlist under an exact status, never
//  "if not transient then terminal".
//
//  Every clearing/keeping test below drives the REAL `forceRefreshToken()`
//  through the REAL catch via an injected transport, and asserts on BOTH
//  halves of the clear (`session` and the persisted key) — a classifier unit
//  test cannot make the catch-site wiring load-bearing. An earlier round
//  learned this the hard way: both call sites of an instrumentation hook
//  were deleted and all eight of its tests stayed green.
//
//  No test here reaches the network: the transport seam is injected and the
//  base URL is `https://stub.invalid`. Every fixture body is a string
//  literal derived from the envelope OBSERVED in gh#234:
//      HTTP/2 400
//      x-sb-error-code: validation_failed
//      {"code":400,"error_code":"validation_failed","msg":"Refresh token is not valid"}
//

import XCTest
@testable import Done

// MARK: - Fixtures (file scope: no actor isolation to reason about)

private func stubResponse(
    _ status: Int,
    _ body: String,
    headers: [String: String] = [:]
) -> (Data, URLResponse) {
    let url = URL(string: "https://stub.invalid/auth/v1/token")!
    let http = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/2",
        headerFields: headers
    )!
    return (Data(body.utf8), http)
}

private func errorBody(code: String?, msg: String = "boom", status: Int = 400) -> String {
    if let code {
        return #"{"code":\#(status),"error_code":"\#(code)","msg":"\#(msg)"}"#
    }
    return #"{"code":\#(status),"msg":"\#(msg)"}"#
}

private func successBody(refreshToken: String, userId: String = "u1") -> String {
    #"""
    {"access_token":"AT-\#(refreshToken)","refresh_token":"\#(refreshToken)","expires_in":3600,"user":{"id":"\#(userId)","email":null}}
    """#
}

/// The transport seam's test double. Not `Sendable` and does not need to be:
/// `AuthService` is `@MainActor`, so every call lands on the main actor.
private final class StubTransport {
    var handler: (URLRequest) async throws -> (Data, URLResponse) = { _ in
        XCTFail("transport called with no handler installed")
        return stubResponse(500, "")
    }
    private(set) var callCount = 0
    private(set) var paths: [String] = []

    func call(_ request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        paths.append(request.url?.absoluteString ?? "")
        return try await handler(request)
    }

    /// Answers refresh grants from a script (last entry repeats forever) and
    /// any other grant with a fresh session.
    func scriptRefreshes(_ script: [(Data, URLResponse)]) {
        var index = 0
        handler = { request in
            guard request.url?.absoluteString.contains("grant_type=refresh_token") == true else {
                return stubResponse(200, successBody(refreshToken: "signed-in"))
            }
            let entry = script[min(index, script.count - 1)]
            index += 1
            return entry
        }
    }

    func always(_ response: (Data, URLResponse)) {
        handler = { _ in response }
    }
}

@MainActor
final class AuthRefreshTerminalTests: XCTestCase {

    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AuthRefreshTerminalTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        DiagnosticTrail.clear()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        DiagnosticTrail.clear()
        super.tearDown()
    }

    private static let sessionKey = "supabaseAuthSession"

    @discardableResult
    private func seedSession(refreshToken: String = "S1", userId: String = "u1") -> AuthSession {
        let session = AuthSession(
            accessToken: "AT-\(refreshToken)",
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSinceNow: -60),   // already expired
            user: AuthUser(id: userId, email: nil, createdAt: nil)
        )
        suite.set(try! JSONEncoder().encode(session), forKey: Self.sessionKey)
        return session
    }

    private func makeAuth(_ stub: StubTransport) -> AuthService {
        AuthService(
            url: "https://stub.invalid",
            projectAPIKey: "test-publishable-key",
            defaults: suite,
            transport: { [stub] request in try await stub.call(request) }
        )
    }

    // MARK: - The classifier (pure)

    func testTerminalRequiresStatus400AndAnAllowlistedCode() {
        for code in AuthService.terminalRefreshCodes {
            XCTAssertEqual(
                AuthService.refreshOutcome(status: 400, bodyCode: code),
                .terminal(code),
                "\(code) under 400 is the whole point of the fix"
            )
        }
    }

    /// Every row here is a KEEP. Each one independently kills a different
    /// way of loosening the gate.
    func testEverythingElseKeepsTheSession() {
        let keepRows: [(Int, String?)] = [
            // The only code OBSERVED on this project — GoTrue's generic 400
            // bucket for a malformed body. Terminal here would sign out every
            // user on a build with a request-shaping bug.
            (400, "validation_failed"),
            (400, nil),
            (400, "totally_unknown"),
            // A terminal code under an unobserved status: kept, deliberately.
            (401, "refresh_token_already_used"),
            (403, "session_expired"),
            (500, "refresh_token_already_used"),
            (502, "session_not_found"),
            // The retry storm gh#234 describes makes 429 reachable, and a 429
            // body carries an `error_code` too — so status must be load-bearing.
            (429, "refresh_token_already_used"),
            (429, "over_request_rate_limit"),
            (503, nil),
            (200, "refresh_token_already_used"),
        ]
        for (status, code) in keepRows {
            XCTAssertEqual(
                AuthService.refreshOutcome(status: status, bodyCode: code),
                .keep,
                "(\(status), \(code ?? "nil")) must KEEP the session"
            )
        }
    }

    func testTerminalCodeSetIsExactlyTheFourWithoutValidationFailed() {
        XCTAssertEqual(AuthService.terminalRefreshCodes, [
            "refresh_token_already_used",
            "refresh_token_not_found",
            "session_expired",
            "session_not_found",
        ])
        XCTAssertFalse(AuthService.terminalRefreshCodes.contains("validation_failed"))
    }

    func testRecordableCodeVocabularyIsClosed() {
        XCTAssertEqual(AuthService.recordableAuthCodes, [
            "refresh_token_already_used",
            "refresh_token_not_found",
            "session_expired",
            "session_not_found",
            "validation_failed",
            "over_request_rate_limit",
        ])
    }

    // MARK: - End to end: the four terminal codes clear, both halves

    func testEachTerminalCodeClearsBothHalvesOfTheSession() async {
        for code in AuthService.terminalRefreshCodes.sorted() {
            suite.removePersistentDomain(forName: suiteName)
            seedSession()
            let stub = StubTransport()
            stub.always(stubResponse(400, errorBody(code: code)))
            let auth = makeAuth(stub)

            await auth.forceRefreshToken()

            XCTAssertNil(auth.session, "\(code): in-memory session must be gone")
            XCTAssertNil(suite.data(forKey: Self.sessionKey),
                         "\(code): persisted session must be gone or relaunch resumes the loop")
            XCTAssertFalse(auth.isSignedIn, "\(code): isSignedIn gates the sign-in UI")
            XCTAssertTrue(auth.needsReauthentication, "\(code): the user needs an explanation")
            XCTAssertNil(auth.errorMessage,
                         "\(code): the server's message must never reach the UI")
        }
    }

    func testAFreshServiceOnTheSameSuiteComesBackSignedOutAndExplained() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(400, errorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        // The process dies; the user opens Settings → Account much later.
        let relaunched = AuthService(url: "https://stub.invalid", defaults: suite,
                                     transport: { _ in throw URLError(.cancelled) })
        XCTAssertFalse(relaunched.isSignedIn)
        XCTAssertTrue(relaunched.needsReauthentication)
    }

    // MARK: - End to end: the KEEP half

    private func assertSessionSurvives(
        _ install: (StubTransport) -> Void,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        suite.removePersistentDomain(forName: suiteName)
        seedSession()
        let stub = StubTransport()
        install(stub)
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        XCTAssertEqual(auth.session?.refreshToken, "S1", "\(label): session must survive",
                       file: file, line: line)
        XCTAssertNotNil(suite.data(forKey: Self.sessionKey), "\(label): persisted session must survive",
                        file: file, line: line)
        XCTAssertFalse(auth.needsReauthentication, "\(label): no re-auth banner for a transient failure",
                       file: file, line: line)
    }

    func testTheObservedValidationFailedEnvelopeKeepsTheSession() async {
        await assertSessionSurvives({ stub in
            stub.always(stubResponse(
                400,
                #"{"code":400,"error_code":"validation_failed","msg":"Refresh token is not valid"}"#,
                headers: ["x-sb-error-code": "validation_failed"]
            ))
        }, "observed 400 validation_failed envelope")
    }

    func testRateLimitAndServerErrorsKeepTheSession() async {
        await assertSessionSurvives({ stub in
            stub.always(stubResponse(429, errorBody(code: "over_request_rate_limit", status: 429)))
        }, "429 over_request_rate_limit")

        await assertSessionSurvives({ stub in
            stub.always(stubResponse(503, "<html><head><title>502 Bad Gateway</title></head></html>"))
        }, "503 HTML proxy page")

        await assertSessionSurvives({ stub in
            stub.always(stubResponse(500, errorBody(code: "refresh_token_already_used", status: 500)))
        }, "500 carrying a terminal code")

        await assertSessionSurvives({ stub in
            stub.always(stubResponse(401, errorBody(code: "refresh_token_already_used", status: 401)))
        }, "401 carrying a terminal code")

        await assertSessionSurvives({ stub in
            stub.always(stubResponse(400, errorBody(code: "brand_new_code_nobody_has_seen")))
        }, "400 with an unknown code")
    }

    /// Network transients are a DIFFERENT Swift type from `AuthError`. The
    /// typed match is what keeps them out of the clear — `if !(error is
    /// URLError)` would be the forbidden inversion.
    func testNetworkTransientsAndCancellationKeepTheSession() async {
        await assertSessionSurvives({ stub in
            stub.handler = { _ in throw URLError(.notConnectedToInternet) }
        }, "URLError.notConnectedToInternet")

        await assertSessionSurvives({ stub in
            stub.handler = { _ in throw URLError(.timedOut) }
        }, "URLError.timedOut")

        await assertSessionSurvives({ stub in
            stub.handler = { _ in throw CancellationError() }
        }, "CancellationError")
    }

    /// A 2xx whose body does not parse is `.invalidResponse` — no status to
    /// classify, and certainly not a terminal.
    func testUnparseableSuccessBodyKeepsTheSession() async {
        await assertSessionSurvives({ stub in
            stub.always(stubResponse(200, "not json at all"))
        }, "200 with an unparseable body")
    }

    /// The header is corroboration, never a decision. A non-JSON 400 is the
    /// one path where the body is least trustworthy (proxy / error page), so
    /// moving an irreversible sign-out onto a single header there is exactly
    /// the wrong trade.
    func testTerminalCodeInTheHeaderAloneDoesNotClearTheSession() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(
            400,
            "<html>not json</html>",
            headers: ["x-sb-error-code": "refresh_token_already_used"]
        ))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        XCTAssertEqual(auth.session?.refreshToken, "S1")
        XCTAssertNotNil(suite.data(forKey: Self.sessionKey))
        XCTAssertTrue(trailMessages().contains { $0.contains("decision=kept") })
    }

    // MARK: - Status is read before the body is parsed (G2)

    /// Under the old ordering the parse guard threw `.invalidResponse` before
    /// anything read the status, so a 5xx HTML page and a mangled 400 envelope
    /// were the same event. Both still KEEP; the difference is that the status
    /// survives into the trail and into the user-visible sign-in message.
    func testStatusSurvivesAnUnparseableErrorBody() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(500, "<html>Bad Gateway</html>"))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        let line = trailMessages().first { $0.hasPrefix("refresh status=") }
        XCTAssertEqual(line, "refresh status=500 code=unrecognized codeLen=0 codeShape=other hdr=absent decision=kept action=kept")
    }

    func testAuthFailureDescriptionIsTheServerMessageAlone() async {
        // Direct: status and code are machine fields and never concatenated in.
        let error = AuthService.AuthError.authFailure(
            status: 400, code: "validation_failed", message: "Refresh token is not valid"
        )
        XCTAssertEqual(error.localizedDescription, "Refresh token is not valid")

        // End to end through the one surface that renders it: sign-in.
        let stub = StubTransport()
        stub.always(stubResponse(
            400,
            #"{"code":400,"error_code":"validation_failed","msg":"Refresh token is not valid"}"#
        ))
        let auth = makeAuth(stub)
        await auth.signInWithApple(idToken: "t", nonce: "n")
        XCTAssertEqual(auth.errorMessage, "Refresh token is not valid")
    }

    // MARK: - Compare and clear / compare and install (G7)

    /// A refresh for S1 can still be in flight after the user signed out and
    /// back in as S2 — possibly as a DIFFERENT user.
    private func runInFlightSwap(
        refreshOutcome: (Data, URLResponse)
    ) async -> AuthService {
        seedSession(refreshToken: "S1")
        let stub = StubTransport()
        let entered = expectation(description: "refresh reached the transport")
        var release: CheckedContinuation<Void, Never>?
        stub.handler = { request in
            if request.url?.absoluteString.contains("grant_type=refresh_token") == true {
                entered.fulfill()
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    release = c
                }
                return refreshOutcome
            }
            return stubResponse(200, successBody(refreshToken: "S2", userId: "u2"))
        }
        let auth = makeAuth(stub)

        let refreshing = Task { await auth.forceRefreshToken() }
        await fulfillment(of: [entered], timeout: 5)

        // The user signs in again while S1's refresh hangs.
        await auth.signInWithApple(idToken: "t", nonce: "n")
        XCTAssertEqual(auth.session?.refreshToken, "S2")

        release?.resume()
        await refreshing.value
        return auth
    }

    func testTerminalForAnOldSessionDoesNotClearTheCurrentOne() async {
        let auth = await runInFlightSwap(
            refreshOutcome: stubResponse(400, errorBody(code: "refresh_token_already_used"))
        )
        XCTAssertEqual(auth.session?.refreshToken, "S2",
                       "a terminal verdict about S1 must not sign S2 out")
        XCTAssertEqual(auth.session?.user.id, "u2")
        XCTAssertNotNil(suite.data(forKey: Self.sessionKey))
        XCTAssertFalse(auth.needsReauthentication)
        XCTAssertTrue(trailMessages().contains { $0.contains("decision=terminal action=stale") })
    }

    func testSuccessForAnOldSessionDoesNotOverwriteTheCurrentOne() async {
        let auth = await runInFlightSwap(
            refreshOutcome: stubResponse(200, successBody(refreshToken: "S1-PRIME", userId: "u1"))
        )
        XCTAssertEqual(auth.session?.refreshToken, "S2",
                       "a stale success must not replace the newer session")
        XCTAssertEqual(auth.session?.user.id, "u2",
                       "…least of all with a different user's session")
    }

    // MARK: - The explanation flag (G12)

    func testSignInClearsTheReAuthFlag() async {
        suite.set(true, forKey: AuthService.needsReauthKey)
        let stub = StubTransport()
        stub.always(stubResponse(200, successBody(refreshToken: "S9")))
        let auth = makeAuth(stub)
        XCTAssertTrue(auth.needsReauthentication)

        await auth.signInWithApple(idToken: "t", nonce: "n")

        XCTAssertFalse(auth.needsReauthentication)
        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
    }

    func testUserInitiatedSignOutLeavesNoReAuthBanner() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(400, errorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)
        await auth.forceRefreshToken()
        XCTAssertTrue(auth.needsReauthentication)

        auth.signOut()

        XCTAssertFalse(auth.needsReauthentication)
        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
        XCTAssertNil(suite.data(forKey: Self.sessionKey))
    }

    func testResetAllLocalDataRemovesTheReAuthFlag() {
        suite.set(true, forKey: AuthService.needsReauthKey)
        AppSettingsKeys.removeResettableKeys(from: suite)
        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
    }

    /// The named-key sweep writes behind the live `AuthService`'s back, so
    /// removing the key is NOT the same act as telling its owner: the
    /// `@Published` flag the re-auth card and the orange Me row read stayed
    /// true, and both survived "Reset all local data" until the next launch.
    func testTheSweepAloneLeavesTheBannerLiveInMemory() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(400, errorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)
        await auth.forceRefreshToken()
        XCTAssertTrue(auth.needsReauthentication, "liveness: a real terminal clear set the flag")

        AppSettingsKeys.removeResettableKeys(from: suite)

        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
        XCTAssertTrue(auth.needsReauthentication,
                      "the witness: the sweep cannot reach the published copy the banner reads")

        auth.forgetReauthenticationNotice()

        XCTAssertFalse(auth.needsReauthentication)
        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
    }

    /// …and the notice is dropped whole: a `forgetReauthenticationNotice()`
    /// that only nils the in-memory copy would leave the flag on disk and the
    /// banner would come back on the next launch.
    func testForgettingTheNoticeClearsBothHalves() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(400, errorBody(code: "session_not_found")))
        let auth = makeAuth(stub)
        await auth.forceRefreshToken()
        XCTAssertTrue(auth.needsReauthentication)
        XCTAssertEqual(suite.object(forKey: AuthService.needsReauthKey) as? Bool, true)

        auth.forgetReauthenticationNotice()

        XCTAssertFalse(auth.needsReauthentication)
        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
        // A fresh instance over the same suite is the relaunch.
        let relaunched = makeAuth(StubTransport())
        XCTAssertFalse(relaunched.needsReauthentication)
    }

    // MARK: - Classification lives only in the refresh catch (G15)

    /// `postAuth` has three callers. A clear placed there would sign a valid
    /// session out when a re-auth or multi-account sign-in attempt returned a
    /// terminal code.
    func testASignInFailureNeverClearsAnExistingSession() async {
        seedSession(refreshToken: "GOOD")
        let stub = StubTransport()
        stub.always(stubResponse(400, errorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)

        await auth.signInWithApple(idToken: "t", nonce: "n")

        XCTAssertEqual(auth.session?.refreshToken, "GOOD")
        XCTAssertNotNil(suite.data(forKey: Self.sessionKey))
        XCTAssertFalse(auth.needsReauthentication)
    }

    // MARK: - Fallout of a terminal clear (G16)

    func testConcurrentRefreshesShareOneRequestAndTouchNoSyncBookkeeping() async {
        seedSession()
        suite.set("hash-a", forKey: "syncHashes.u1.calendar_events")
        suite.set("hash-b", forKey: "syncHashes.u1.user_settings")
        suite.set(true, forKey: "hasOfferedAutoRestore.u1")
        let before = persistedKeys(matching: { $0.hasPrefix("syncHashes.") || $0.hasPrefix("hasOfferedAutoRestore.") })

        let stub = StubTransport()
        stub.always(stubResponse(400, errorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)

        let a = Task { await auth.forceRefreshToken() }
        let b = Task { await auth.forceRefreshToken() }
        let c = Task { await auth.forceRefreshToken() }
        await a.value
        await b.value
        await c.value

        XCTAssertEqual(stub.callCount, 1, "N waiters must share the one in-flight refresh")
        XCTAssertNil(auth.session)
        XCTAssertEqual(
            persistedKeys(matching: { $0.hasPrefix("syncHashes.") || $0.hasPrefix("hasOfferedAutoRestore.") }),
            before,
            "a sign-out must not reset a store or advance a hash baseline"
        )
    }

    private func persistedKeys(matching predicate: (String) -> Bool) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in suite.dictionaryRepresentation() where predicate(key) {
            out[key] = String(describing: value)
        }
        return out
    }

    // MARK: - The trail is a projection, not a redaction (G8)

    private func trailMessages() -> [String] {
        DiagnosticTrail.combinedText()
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: " Auth ") else { return nil }
                return String(line[range.upperBound...])
            }
    }

    /// The load-bearing privacy test. The body carries an unrecognized
    /// six-character code and a long free-text `msg` containing two
    /// credential shapes; the produced line must be byte-for-byte this, with
    /// no fragment of either reaching the file.
    func testTrailLineIsAnExactProjectionAndCarriesNoServerBytes() async {
        let secret = "dk_" + String(repeating: "a1b2c3d4", count: 8)   // 64 hex
        let msg = "The refresh grant failed while validating the credential "
            + secret + " and the service key sb_secret_x which the caller presented; "
            + "retrying with the same material will not help because the family was revoked."
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(400, #"{"code":400,"error_code":"K7P2MQ","msg":"\#(msg)"}"#))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        let lines = trailMessages().filter { $0.hasPrefix("refresh status=") }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(
            lines.first,
            "refresh status=400 code=unrecognized codeLen=6 codeShape=other hdr=absent decision=kept action=kept"
        )

        let text = DiagnosticTrail.combinedText()
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("sb_secret"))
        XCTAssertFalse(text.contains("refresh grant failed"))
        // No fragment of the unrecognized code, down to two characters.
        let code = Array("K7P2MQ")
        for start in 0..<(code.count - 1) {
            for end in (start + 2)...code.count {
                XCTAssertFalse(text.contains(String(code[start..<end])),
                               "trail leaked a fragment of the server's error_code")
            }
        }
    }

    func testTrailLineStaysUnderTheByteBudget() {
        // The worst case, COMPUTED from the vocabularies rather than named,
        // because naming it got it wrong: the previous fixture used
        // `over_request_rate_limit` (23) while calling it "the longest
        // recordable code", when `refresh_token_already_used` (26) is longer
        // and is itself a terminal member. Same for the action token —
        // `installed` (9) is longer than `cleared` (7).
        let longestCode = AuthService.recordableAuthCodes.max { $0.count < $1.count }
        XCTAssertEqual(longestCode, "refresh_token_already_used",
                       "the budget fixture must track the vocabulary, not a remembered member")
        let longestDecision = AuthService.RefreshTrailDecision.allCases.max { $0.rawValue.count < $1.rawValue.count }
        let longestAction = AuthService.RefreshTrailAction.allCases.max { $0.rawValue.count < $1.rawValue.count }
        guard let longestCode, let longestDecision, let longestAction else {
            return XCTFail("empty vocabulary")
        }
        let line = AuthService.refreshTrailLine(
            status: 400,
            rawCode: longestCode,
            headerCode: "something_else_entirely",
            decision: longestDecision,
            action: longestAction
        ) + " after=4096"
        XCTAssertLessThanOrEqual(line.utf8.count, 160, line)

        // The other direction of "worst": an unbounded code. It projects to a
        // fixed 12-character token, so only `codeLen` grows — 1 KB of garbage
        // still fits, and none of it reaches the line.
        let absurd = String(repeating: "x", count: 1024)
        let projected = AuthService.refreshTrailLine(
            status: 400,
            rawCode: absurd,
            headerCode: absurd,
            decision: .kept,
            action: .kept
        ) + " after=4096"
        XCTAssertLessThanOrEqual(projected.utf8.count, 160, projected)
        XCTAssertFalse(projected.contains("x"), projected)
    }

    func testHeaderRelationIsThreeValuedAndNeverDecides() {
        XCTAssertEqual(AuthService.authHeaderRelation(header: nil, body: "x"), "absent")
        XCTAssertEqual(AuthService.authHeaderRelation(header: "x", body: "x"), "match")
        XCTAssertEqual(AuthService.authHeaderRelation(header: "x", body: "y"), "differ")
        XCTAssertEqual(AuthService.authHeaderRelation(header: "x", body: nil), "differ")
    }

    // MARK: - Transitions, not requests (G9)

    func testAStormOfIdenticalFailuresDoesNotFillTheTrail() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(400, errorBody(code: "validation_failed")))
        let auth = makeAuth(stub)

        for _ in 0..<202 {
            await auth.forceRefreshToken()
        }

        XCTAssertEqual(stub.callCount, 202, "the storm itself is not what this test bounds")
        let authLines = trailMessages()
        XCTAssertGreaterThanOrEqual(authLines.count, 2, "liveness: something must be recorded")
        XCTAssertLessThanOrEqual(authLines.count, 10,
                                 "202 identical failures must not evict the history that localises them")
    }

    func testEveryChangeOfKindGetsItsOwnLineInOrder() async {
        seedSession()
        let stub = StubTransport()
        var script: [(Data, URLResponse)] = [stubResponse(200, successBody(refreshToken: "S2"))]
        script.append(contentsOf: Array(repeating: stubResponse(400, errorBody(code: "validation_failed")), count: 5))
        script.append(stubResponse(429, errorBody(code: "over_request_rate_limit", status: 429)))
        script.append(stubResponse(200, successBody(refreshToken: "S3")))
        stub.scriptRefreshes(script)
        let auth = makeAuth(stub)

        for _ in 0..<8 {
            await auth.forceRefreshToken()
        }

        let full = trailMessages().filter { $0.hasPrefix("refresh status=") }
        let rollups = trailMessages().filter { $0.hasPrefix("refresh repeat ") }
        // `guard` rather than a non-fatal XCTAssertEqual followed by
        // `full[3]`: a mutation that collapses these transitions leaves the
        // array short, and the subscript then TRAPS. The run reports
        // "Executed 2 tests" instead of failures, so a mutation sweep against
        // this file reads back the wrong answer.
        guard full.count == 4 else {
            return XCTFail("success → A → B → success is four transitions, got \(full.count):\n\(full.joined(separator: "\n"))")
        }
        XCTAssertTrue(full[0].contains("status=200 code=ok"))
        XCTAssertTrue(full[1].contains("status=400 code=validation_failed"))
        XCTAssertTrue(full[2].contains("status=429 code=over_request_rate_limit"))
        XCTAssertTrue(full[2].contains("after=4"), "the suppressed count is flushed into the next transition")
        XCTAssertTrue(full[3].contains("status=200 code=ok"))
        XCTAssertLessThanOrEqual(rollups.count, 3)
    }

    /// The compare-and-install discard is the safety mechanism that stops a
    /// slow refresh for an OLD session installing what may be a DIFFERENT
    /// user's session over the current one. It is the one mechanism nobody
    /// asks for, so its trail line is the only evidence it ever fired.
    ///
    /// `decision=ok action=stale` shares (status, code, terminal) with the
    /// ordinary `decision=ok action=installed` that precedes it. With
    /// `action` outside the transition key it was folded into
    /// `refresh repeat n=1` and the trail said nothing had happened.
    /// Deleting `action` from `RefreshDecisionKey` turns this red.
    func testADiscardedStaleResultIsNeverFoldedIntoTheSuccessBeforeIt() async {
        seedSession()                                   // S1
        let stub = StubTransport()
        let entered = expectation(description: "the second refresh reached the transport")
        var release: CheckedContinuation<Void, Never>?
        var refreshCount = 0
        stub.handler = { request in
            guard request.url?.absoluteString.contains("grant_type=refresh_token") == true else {
                // The sign-in that swaps the session out from under the
                // in-flight refresh.
                return stubResponse(200, successBody(refreshToken: "S3", userId: "u3"))
            }
            refreshCount += 1
            if refreshCount == 1 {
                return stubResponse(200, successBody(refreshToken: "S2"))
            }
            entered.fulfill()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                release = c
            }
            return stubResponse(200, successBody(refreshToken: "S2-PRIME"))
        }
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()                  // ok / installed
        XCTAssertEqual(auth.session?.refreshToken, "S2", "liveness: the first refresh must install")

        let refreshing = Task { await auth.forceRefreshToken() }
        await fulfillment(of: [entered], timeout: 5)
        await auth.signInWithApple(idToken: "t", nonce: "n")
        release?.resume()
        await refreshing.value

        XCTAssertEqual(auth.session?.refreshToken, "S3",
                       "a stale success must not replace the newer session")
        let lines = trailMessages().filter { $0.hasPrefix("refresh status=") }
        XCTAssertTrue(lines.contains { $0.contains("decision=ok action=installed") },
                      "\(trailMessages())")
        XCTAssertTrue(lines.contains { $0.contains("decision=ok action=stale") },
                      "the discard is a different event from the install before it:\n\(trailMessages())")
        XCTAssertFalse(trailMessages().contains { $0.hasPrefix("refresh repeat") },
                       "nothing here is a repeat:\n\(trailMessages())")
    }

    /// The terminal/stale → terminal/cleared pair is the case the deleted
    /// `action != .cleared` special case existed for: identical status,
    /// identical code, identical `terminal`, and only the action differs. The
    /// key now carries the action, so the special case is gone — and this is
    /// the test that goes red if the action is taken back out of it.
    func testTheClearingLineSurvivesAnIdenticalStaleLineBeforeIt() async {
        seedSession()                                   // S1
        let terminal = stubResponse(400, errorBody(code: "refresh_token_already_used"))
        let stub = StubTransport()
        let entered = expectation(description: "S1's refresh reached the transport")
        var release: CheckedContinuation<Void, Never>?
        var hangNextRefresh = true
        stub.handler = { request in
            guard request.url?.absoluteString.contains("grant_type=refresh_token") == true else {
                return stubResponse(200, successBody(refreshToken: "S2", userId: "u2"))
            }
            if hangNextRefresh {
                hangNextRefresh = false
                entered.fulfill()
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    release = c
                }
            }
            return terminal
        }
        let auth = makeAuth(stub)

        let refreshing = Task { await auth.forceRefreshToken() }
        await fulfillment(of: [entered], timeout: 5)
        await auth.signInWithApple(idToken: "t", nonce: "n")
        release?.resume()
        await refreshing.value

        XCTAssertEqual(auth.session?.refreshToken, "S2",
                       "a terminal verdict about S1 must not sign S2 out")
        XCTAssertTrue(trailMessages().contains { $0.contains("decision=terminal action=stale") },
                      "liveness: the discarded verdict must be on the trail first:\n\(trailMessages())")

        // Now S2's own refresh hits the same terminal code.
        await auth.forceRefreshToken()

        XCTAssertNil(auth.session)
        XCTAssertTrue(auth.needsReauthentication)
        XCTAssertTrue(trailMessages().contains { $0.contains("decision=terminal action=cleared") },
                      "the line that records the sign-out must never be folded into a repeat count:\n\(trailMessages())")
    }

    /// The header lookup is case-insensitive per `HTTPURLResponse`; every
    /// other fixture in this file spells it lowercase, so nothing pinned it.
    func testTheErrorCodeHeaderIsFoundUnderAnyCasing() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(
            400,
            errorBody(code: "validation_failed"),
            headers: ["X-SB-Error-Code": "validation_failed"]
        ))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        XCTAssertTrue(trailMessages().contains { $0.contains("hdr=match") },
                      "a differently-cased header must still be found:\n\(trailMessages())")
        XCTAssertNotNil(auth.session, "liveness: validation_failed still KEEPS the session")
    }

    /// The os_log line in `performTokenRefresh`'s catch used to interpolate
    /// `error.localizedDescription`, which for `.authFailure` IS the server's
    /// `msg` — the exact free text the trail refuses to carry.
    func testTheRefreshFailureLogTokenCarriesNoServerBytes() {
        let secret = "sb_secret_9BxQ2tK7fL and dk_deadbeefdeadbeef"
        let leaky = AuthService.AuthError.authFailure(
            status: 400,
            code: "K7P2MQ",
            message: "Refresh token \(secret) is not valid"
        )
        XCTAssertEqual(leaky.localizedDescription.contains(secret), true,
                       "liveness: localizedDescription really is the server's msg")

        let token = AuthService.refreshFailureLogToken(leaky)
        XCTAssertEqual(token, "authFailure status=400 code=unrecognized")
        XCTAssertFalse(token.contains("sb_secret"))
        XCTAssertFalse(token.contains("dk_"))
        XCTAssertFalse(token.contains("K7P2MQ"))

        XCTAssertEqual(
            AuthService.refreshFailureLogToken(
                AuthService.AuthError.authFailure(status: 400, code: "refresh_token_already_used", message: "x")
            ),
            "authFailure status=400 code=refresh_token_already_used"
        )
        XCTAssertEqual(AuthService.refreshFailureLogToken(AuthService.AuthError.invalidResponse), "invalidResponse")
        XCTAssertEqual(AuthService.refreshFailureLogToken(AuthService.AuthError.invalidURL), "invalidURL")
        XCTAssertEqual(
            AuthService.refreshFailureLogToken(AuthService.AuthError.serverError("Not signed in")),
            "serverError"
        )
        XCTAssertEqual(AuthService.refreshFailureLogToken(CancellationError()), "cancelled")
        XCTAssertEqual(
            AuthService.refreshFailureLogToken(URLError(.notConnectedToInternet)),
            "urlError code=\(URLError.Code.notConnectedToInternet.rawValue)"
        )
    }

    /// The clearing line is the one the reader needs most; it is never folded
    /// into a repeat count.
    func testTheClearingLineIsNeverSuppressed() async {
        seedSession()
        let stub = StubTransport()
        stub.always(stubResponse(400, errorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        XCTAssertTrue(trailMessages().contains {
            $0 == "refresh status=400 code=refresh_token_already_used codeLen=26 codeShape=lower_snake hdr=absent decision=terminal action=cleared"
        }, "\(trailMessages())")
    }

    // MARK: - The persisted session model must not move (G11)

    /// `loadSession()` is `try? decode` and silently leaves the session nil on
    /// failure, so any shape change signs out the entire installed base on
    /// upgrade — and the suite stays green because every other test seeds
    /// through the CURRENT encoder. This fixture is a byte literal.
    func testPreFixSessionBytesStillDecode() {
        let json = #"""
        {"accessToken":"a","refreshToken":"r","expiresAt":760000000.0,"user":{"id":"u","email":null,"createdAt":null}}
        """#
        suite.set(Data(json.utf8), forKey: Self.sessionKey)

        let auth = AuthService(url: "https://stub.invalid", defaults: suite,
                               transport: { _ in throw URLError(.cancelled) })

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.session?.refreshToken, "r")
        XCTAssertEqual(auth.userId, "u")
    }

    // MARK: - Clearing the trail clears the shared copy too (G10)

    func testClearAlsoRemovesTheShareReadyExport() {
        DiagnosticTrail.record("Auth", "refresh status=400 code=validation_failed")
        XCTAssertNotNil(DiagnosticTrail.exportFile())
        XCTAssertTrue(FileManager.default.fileExists(atPath: DiagnosticTrail.exportURL.path))

        DiagnosticTrail.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: DiagnosticTrail.exportURL.path),
                       "\"Clear Trail\" told the user the record was gone")
    }

    // MARK: - Source guards
    //
    // Weaker than a behavioural test and declared as such (the
    // `StoreLookupScanGuardTests` idiom). They pin two things no runtime
    // assertion can: that the trail-building code contains no expression
    // capable of interpolating a server byte, and that `.authFailure` is
    // thrown from exactly one site.

    private var authServiceSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Done/Services/AuthService.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static let bannedInTrailCode = [
        "localizedDescription", "\\(error", "msg", "error_description",
        "String(describing:", "debugDescription",
    ]

    private func offenders(in line: String) -> [String] {
        Self.bannedInTrailCode.filter { line.contains($0) }
    }

    func testNoTrailBuildingCodeCanInterpolateAServerByte() {
        let source = authServiceSource
        XCTAssertFalse(source.isEmpty, "liveness: the source file must be readable at \(#filePath)")

        // Positive control: the matcher must recognize the exact mistake.
        XCTAssertFalse(offenders(in: #"DiagnosticTrail.record("Auth", "\(error.localizedDescription)")"#).isEmpty)

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        let recordSites = code.filter { $0.contains("DiagnosticTrail.record") }
        XCTAssertGreaterThanOrEqual(recordSites.count, 1, "liveness: the scan must reach real call sites")
        for site in recordSites {
            XCTAssertEqual(offenders(in: site), [], "trail call site: \(site)")
        }

        // The whole region that builds the line, comments excluded.
        guard let start = lines.firstIndex(where: { $0.contains("// MARK: - Refresh trail") }),
              let end = lines.firstIndex(where: { $0.contains("// MARK: - Permanent MCP URL") }),
              start < end
        else { return XCTFail("liveness: could not delimit the trail region") }
        for line in lines[start..<end] where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            XCTAssertEqual(offenders(in: line), [], "trail region: \(line)")
        }
    }

    func testAuthFailureIsThrownFromExactlyOneSite() {
        let sites = authServiceSource
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { $0.contains("throw AuthError.authFailure") }
        XCTAssertEqual(sites.count, 1,
                       "the enriched error must come from the one `status >= 400` branch of postAuth")
    }
}
