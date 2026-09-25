//
//  AuthRefreshTerminalQATests.swift
//  DoneTests
//
//  INDEPENDENT QA on the gh#234 terminal-refresh fix. Written by a party
//  that did not write the production code and did not modify it.
//
//  These tests are deliberately DISJOINT from `AuthRefreshTerminalTests`:
//  they cover what that file leaves unpinned rather than restating it.
//  Four things drove the list.
//
//  1. WIRING. `AuthRefreshTerminalTests` drives `forceRefreshToken()`
//     exclusively. The production hot path is `refreshTokenIfNeeded()` —
//     every `SupabaseSyncService` request calls it first — and nothing
//     drives it through the real catch. A previous probe on this codebase
//     had BOTH of its call sites deleted and all eight of its tests stayed
//     green; an entry point with no test is that failure mode waiting.
//
//  2. THE DEFECT'S OWN SHAPE. gh#234 is "202 requests, 0 successes, no
//     exit". The commit claims the storm "ends by construction" once the
//     session is cleared. Nothing measured that. `testTheStormStopsAfterA
//     TerminalClear` measures it, with a KEEP-fixture positive control that
//     shows the same loop really does fire N requests when the session
//     survives — otherwise a zero-call assertion would pass against a stub
//     that was never reachable in the first place.
//
//  3. NON-DISCRIMINATING ASSERTIONS. `testConcurrentRefreshesShareOneRequest
//     AndTouchNoSyncBookkeeping` asserts `callCount == 1` against a TERMINAL
//     fixture. One call is also what you get with the `refreshTask` dedup
//     deleted, because the first response clears the session and the other
//     two waiters exit at `guard session != nil`. The assertion therefore
//     cannot tell dedup from clearing. The version here uses a KEEP fixture,
//     where only dedup can produce one call, and carries a sequential
//     positive control that produces three.
//
//  4. RELAY LOSS. The one user-visible string this commit changes OUTSIDE
//     the gh#234 flow (a non-JSON auth error during sign-in now reads
//     "Authentication failed (HTTP n)" instead of "Invalid response") lives
//     only in a prose report. A prior round lost an out-of-scope behaviour
//     change exactly that way. It is pinned here.
//
//  No test reaches the network: the transport seam is injected and the base
//  URL is `https://stub.invalid`. Fixtures are string literals derived from
//  the envelope observed in gh#234.
//

import XCTest
@testable import Done

// MARK: - Fixtures

private func qaResponse(
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

private func qaErrorBody(code: String?, status: Int = 400, msg: String = "boom") -> String {
    if let code {
        return #"{"code":\#(status),"error_code":"\#(code)","msg":"\#(msg)"}"#
    }
    return #"{"code":\#(status),"msg":"\#(msg)"}"#
}

private func qaSuccessBody(refreshToken: String, userId: String = "u1") -> String {
    #"{"access_token":"AT-\#(refreshToken)","refresh_token":"\#(refreshToken)","expires_in":3600,"user":{"id":"\#(userId)","email":null}}"#
}

/// Counting transport double. `AuthService` is `@MainActor`, so every call
/// lands on the main actor and the counter needs no synchronisation.
private final class QACountingTransport {
    var handler: (URLRequest) async throws -> (Data, URLResponse) = { _ in
        XCTFail("transport called with no handler installed")
        return qaResponse(500, "")
    }
    private(set) var callCount = 0

    func call(_ request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        return try await handler(request)
    }

    func always(_ response: (Data, URLResponse)) {
        handler = { _ in response }
    }

    /// Refresh grants get `refresh`; any other grant (i.e. a sign-in) gets
    /// `other`. Lets a test stage a sign-in failure before a refresh failure.
    func split(refresh: (Data, URLResponse), other: (Data, URLResponse)) {
        handler = { request in
            request.url?.absoluteString.contains("grant_type=refresh_token") == true ? refresh : other
        }
    }
}

@MainActor
final class AuthRefreshTerminalQATests: XCTestCase {

    private var suiteName = ""
    private var suite: UserDefaults!
    private static let sessionKey = "supabaseAuthSession"

    override func setUp() {
        super.setUp()
        suiteName = "AuthRefreshTerminalQATests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        DiagnosticTrail.clear()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        DiagnosticTrail.clear()
        super.tearDown()
    }

    /// `expiresIn` is a signed offset from now: negative seeds an already
    /// expired token (what `refreshTokenIfNeeded` acts on), a large positive
    /// one seeds a token the same guard must leave alone.
    @discardableResult
    private func seedSession(
        refreshToken: String = "S1",
        userId: String = "u1",
        expiresIn: TimeInterval = -60
    ) -> AuthSession {
        let session = AuthSession(
            accessToken: "AT-\(refreshToken)",
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSinceNow: expiresIn),
            user: AuthUser(id: userId, email: nil, createdAt: nil)
        )
        suite.set(try! JSONEncoder().encode(session), forKey: Self.sessionKey)
        return session
    }

    private func makeAuth(_ stub: QACountingTransport) -> AuthService {
        AuthService(
            url: "https://stub.invalid",
            projectAPIKey: "test-publishable-key",
            defaults: suite,
            transport: { [stub] request in try await stub.call(request) }
        )
    }

    private func trailMessages() -> [String] {
        DiagnosticTrail.combinedText()
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: " Auth ") else { return nil }
                return String(line[range.upperBound...])
            }
    }

    // MARK: - 1. The OTHER entry point (wiring)

    /// `refreshTokenIfNeeded()` is what every sync request calls. It reaches
    /// the classifier only through `performTokenRefresh`, and nothing in the
    /// implementer's suite drives it. `callCount == 1` is the positive
    /// control: it proves the call actually reached the transport rather than
    /// bailing at the expiry guard, which would make the clear assertions
    /// vacuous.
    func testRefreshTokenIfNeededAlsoClearsOnATerminalCode() async {
        seedSession()
        let stub = QACountingTransport()
        stub.always(qaResponse(400, qaErrorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)

        await auth.refreshTokenIfNeeded()

        XCTAssertEqual(stub.callCount, 1, "liveness: the request must have been made")
        XCTAssertNil(auth.session, "the sync hot path must clear too, not just forceRefreshToken()")
        XCTAssertNil(suite.data(forKey: Self.sessionKey))
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.needsReauthentication)
        XCTAssertNil(auth.errorMessage)
    }

    func testRefreshTokenIfNeededKeepsTheSessionOnARateLimit() async {
        seedSession()
        let stub = QACountingTransport()
        stub.always(qaResponse(429, qaErrorBody(code: "over_request_rate_limit", status: 429)))
        let auth = makeAuth(stub)

        await auth.refreshTokenIfNeeded()

        XCTAssertEqual(stub.callCount, 1, "liveness: the request must have been made")
        XCTAssertEqual(auth.session?.refreshToken, "S1")
        XCTAssertNotNil(suite.data(forKey: Self.sessionKey))
        XCTAssertFalse(auth.needsReauthentication)
    }

    /// The negative control that gives the two `callCount == 1` assertions
    /// above their meaning: with a fresh token the same call makes NO request
    /// at all, so "1" is a fact about this path and not about the stub.
    func testRefreshTokenIfNeededMakesNoRequestWhileTheTokenIsFresh() async {
        seedSession(expiresIn: 3600)
        let stub = QACountingTransport()
        stub.always(qaResponse(400, qaErrorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)

        await auth.refreshTokenIfNeeded()

        XCTAssertEqual(stub.callCount, 0)
        XCTAssertEqual(auth.session?.refreshToken, "S1")
    }

    // MARK: - 2. The defect itself: does the storm actually stop?

    /// gh#234 is 202 requests with 0 successes over 2.5 hours. The commit
    /// message claims the terminal storm "ends by construction" once the
    /// session is cleared — every later refresh exits at `guard let session`
    /// with zero network. That claim is the whole reason a backoff/breaker
    /// was left out of scope, and nothing measured it.
    ///
    /// The KEEP half is the positive control: the identical 20-call loop
    /// fires 20 requests when the session survives, so `1` below is the clear
    /// stopping the storm and not an unreachable stub.
    func testTheStormStopsAfterATerminalClearButNotBefore() async {
        // Terminal.
        seedSession()
        let terminalStub = QACountingTransport()
        terminalStub.always(qaResponse(400, qaErrorBody(code: "refresh_token_already_used")))
        let terminalAuth = makeAuth(terminalStub)
        for _ in 0..<10 {
            await terminalAuth.forceRefreshToken()
            await terminalAuth.refreshTokenIfNeeded()
        }
        XCTAssertNil(terminalAuth.session)
        XCTAssertEqual(terminalStub.callCount, 1,
                       "after a terminal clear every later refresh must exit before the network")

        // Positive control: same loop, KEEP verdict.
        suite.removePersistentDomain(forName: suiteName)
        seedSession()
        let keepStub = QACountingTransport()
        keepStub.always(qaResponse(429, qaErrorBody(code: "over_request_rate_limit", status: 429)))
        let keepAuth = makeAuth(keepStub)
        for _ in 0..<10 {
            await keepAuth.forceRefreshToken()
            await keepAuth.refreshTokenIfNeeded()
        }
        XCTAssertNotNil(keepAuth.session)
        XCTAssertEqual(keepStub.callCount, 20,
                       "liveness: the loop really does drive 20 requests when the session survives")
    }

    // MARK: - 3. Dedup, measured where only dedup can explain the number

    /// Three concurrent refreshes must share ONE in-flight request. The
    /// implementer's version of this asserts the same number against a
    /// terminal fixture, where deleting the dedup still yields one call
    /// (waiters 2 and 3 exit at `guard session != nil` because waiter 1
    /// already cleared). Under a KEEP verdict the session is still there for
    /// every waiter, so `1` can only come from `refreshTask`.
    func testConcurrentRefreshesShareOneRequestWhenTheSessionSurvives() async {
        seedSession()
        let stub = QACountingTransport()
        stub.always(qaResponse(429, qaErrorBody(code: "over_request_rate_limit", status: 429)))
        let auth = makeAuth(stub)

        let a = Task { await auth.forceRefreshToken() }
        let b = Task { await auth.forceRefreshToken() }
        let c = Task { await auth.forceRefreshToken() }
        await a.value
        await b.value
        await c.value

        XCTAssertEqual(stub.callCount, 1, "N waiters must share the one in-flight refresh")
        XCTAssertEqual(auth.session?.refreshToken, "S1")

        // Positive control: the same three refreshes SEQUENTIALLY are three
        // requests, so the assertion above is about overlap, not about a
        // session that stopped being refreshable.
        let sequentialStub = QACountingTransport()
        sequentialStub.always(qaResponse(429, qaErrorBody(code: "over_request_rate_limit", status: 429)))
        suite.removePersistentDomain(forName: suiteName)
        seedSession()
        let sequentialAuth = makeAuth(sequentialStub)
        await sequentialAuth.forceRefreshToken()
        await sequentialAuth.forceRefreshToken()
        await sequentialAuth.forceRefreshToken()
        XCTAssertEqual(sequentialStub.callCount, 3)
    }

    // MARK: - 4. The header is captured per-request, never inherited

    /// `lastAuthFailureHeaderCode` is cross-call mutable state on the
    /// service, set by `postAuth` and consumed by the refresh catch. The
    /// sign-in paths set it and never consume it, so a failed sign-in leaves
    /// a value behind. What keeps that value from being attributed to a LATER
    /// refresh failure is that `postAuth` assigns unconditionally — including
    /// assigning nil when the later response has no header. Turning that into
    /// `if let h = … { lastAuthFailureHeaderCode = h }` would make the trail
    /// report a header disagreement that never happened, on the exact path
    /// (non-JSON body) where the field is the only evidence there is.
    func testAHeaderLeftBehindByAFailedSignInIsNotAttributedToALaterRefresh() async {
        seedSession()
        let stub = QACountingTransport()
        stub.split(
            // The refresh: non-JSON body, NO header.
            refresh: qaResponse(400, "<html>gateway</html>"),
            // The sign-in that ran first: a terminal code in the header.
            other: qaResponse(400, "<html>gateway</html>",
                              headers: ["x-sb-error-code": "refresh_token_already_used"])
        )
        let auth = makeAuth(stub)

        await auth.signInWithApple(idToken: "t", nonce: "n")   // leaves a header behind
        await auth.forceRefreshToken()

        let line = trailMessages().first { $0.hasPrefix("refresh status=") }
        XCTAssertEqual(
            line,
            "refresh status=400 code=unrecognized codeLen=0 codeShape=other hdr=absent decision=kept action=kept"
        )
        XCTAssertEqual(auth.session?.refreshToken, "S1")
        XCTAssertFalse(auth.needsReauthentication)
    }

    /// Positive control for the assertion above: when the refresh response
    /// itself carries the header, `hdr` is NOT `absent`. Without this, a
    /// `hdr=absent` that came from the field being hardcoded would pass.
    func testAHeaderOnTheRefreshResponseItselfIsRecordedAsADisagreement() async {
        seedSession()
        let stub = QACountingTransport()
        stub.always(qaResponse(400, "<html>gateway</html>",
                               headers: ["x-sb-error-code": "refresh_token_already_used"]))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        let line = trailMessages().first { $0.hasPrefix("refresh status=") }
        XCTAssertEqual(
            line,
            "refresh status=400 code=unrecognized codeLen=0 codeShape=other hdr=differ decision=kept action=kept"
        )
        XCTAssertEqual(auth.session?.refreshToken, "S1",
                       "a terminal code in the header alone must never sign the device out")
        XCTAssertNotNil(suite.data(forKey: Self.sessionKey))
    }

    // MARK: - 5. The out-of-scope user-visible string (relay loss)

    /// The single user-visible string this commit changes outside the gh#234
    /// flow, named in the implementer's report and otherwise unpinned: a
    /// non-JSON 4xx/5xx during sign-in used to render "Invalid response" and
    /// now renders the status. Pinned so a later reorder of `postAuth` cannot
    /// revert it silently, and so the status/code never grow into the string.
    func testANonJsonServerErrorDuringSignInNowNamesTheStatus() async {
        let stub = QACountingTransport()
        stub.always(qaResponse(500, "<html><title>502 Bad Gateway</title></html>"))
        let auth = makeAuth(stub)

        await auth.signInWithApple(idToken: "t", nonce: "n")

        XCTAssertEqual(auth.errorMessage, "Authentication failed (HTTP 500)")
    }

    /// And when the body DOES parse, the sentence is the server's message
    /// alone — the machine fields stay out of it.
    func testASignInErrorMessageNeverCarriesTheStatusOrTheCode() async {
        let stub = QACountingTransport()
        stub.always(qaResponse(
            400,
            #"{"code":400,"error_code":"validation_failed","msg":"Refresh token is not valid"}"#
        ))
        let auth = makeAuth(stub)

        await auth.signInWithApple(idToken: "t", nonce: "n")

        XCTAssertEqual(auth.errorMessage, "Refresh token is not valid")
        XCTAssertFalse(auth.errorMessage?.contains("400") ?? true)
        XCTAssertFalse(auth.errorMessage?.contains("validation_failed") ?? true)
    }

    // MARK: - 6. A 2xx the parser rejects is not a classification event

    /// `parseSessionResponse` throws `.invalidResponse` for a 200 whose JSON
    /// parses but lacks the session fields — a distinct throw site from the
    /// unparseable-body case the implementer covers, and one that reaches the
    /// same catch. It must not clear.
    func testA200MissingSessionFieldsKeepsTheSession() async {
        seedSession()
        let stub = QACountingTransport()
        stub.always(qaResponse(200, #"{"ok":true,"user":{"id":"u1"}}"#))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        XCTAssertEqual(stub.callCount, 1, "liveness: the request must have been made")
        XCTAssertEqual(auth.session?.refreshToken, "S1")
        XCTAssertNotNil(suite.data(forKey: Self.sessionKey))
        XCTAssertFalse(auth.needsReauthentication)
    }

    // MARK: - 7. Reset, driven from a real clear and shown to be targeted

    /// The implementer's resettable-keys test hand-writes the flag it then
    /// looks for. This drives the flag through the real terminal clear, and
    /// asserts the sweep is a named-key removal rather than a domain wipe —
    /// a wipe would also take the sync bookkeeping that a terminal clear is
    /// required to leave alone.
    func testResetRemovesAFlagSetByARealTerminalClearAndNothingElse() async {
        seedSession()
        suite.set("hash-a", forKey: "syncHashes.u1.calendar_events")
        suite.set(true, forKey: "confirmedUploads.u1.images")
        let stub = QACountingTransport()
        stub.always(qaResponse(400, qaErrorBody(code: "session_not_found")))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()
        XCTAssertTrue(auth.needsReauthentication, "liveness: the flag must have been set for real")

        AppSettingsKeys.removeResettableKeys(from: suite)

        XCTAssertNil(suite.object(forKey: AuthService.needsReauthKey))
        XCTAssertEqual(suite.string(forKey: "syncHashes.u1.calendar_events"), "hash-a",
                       "the reset sweep removes named keys; it must not nuke the domain")
        XCTAssertNotNil(suite.object(forKey: "confirmedUploads.u1.images"))
    }

    /// Separately: the terminal clear itself leaves the upload bookkeeping
    /// alone. The implementer covers `syncHashes.*` and
    /// `hasOfferedAutoRestore.*`; `confirmedUploads.*` is named in the same
    /// argument and was not asserted.
    func testTerminalClearLeavesConfirmedUploadBookkeepingIntact() async {
        seedSession()
        suite.set(["a", "b"], forKey: "confirmedUploads.u1.images")
        let stub = QACountingTransport()
        stub.always(qaResponse(400, qaErrorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()

        XCTAssertNil(auth.session, "liveness: the clear must have happened")
        XCTAssertEqual(suite.stringArray(forKey: "confirmedUploads.u1.images"), ["a", "b"])
    }

    // MARK: - 8. The explanation exists in BOTH languages, really translated

    /// The `en`/`zh` switches have no `default:`, so the compiler proves a
    /// case EXISTS — it cannot prove the `zh` arm was translated rather than
    /// copy-pasted from `en`. This is the only check on that.
    func testTheReAuthSentenceIsTranslatedNotCopied() {
        func hasCJK(_ s: String) -> Bool {
            s.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
        }

        // Positive control: the predicate discriminates on a known-good pair.
        XCTAssertFalse(hasCJK(LKey.signOut.text(for: .english)))
        XCTAssertTrue(hasCJK(LKey.signOut.text(for: .chinese)))

        for key in [LKey.sessionEndedNeedsReauth, LKey.meSessionEnded] {
            let en = key.text(for: .english)
            let zh = key.text(for: .chinese)
            XCTAssertFalse(en.isEmpty)
            XCTAssertFalse(zh.isEmpty)
            XCTAssertNotEqual(en, zh, "\(key): the zh arm looks copied from en")
            XCTAssertTrue(hasCJK(zh), "\(key): the zh arm carries no Chinese")
            XCTAssertFalse(hasCJK(en), "\(key): the en arm carries Chinese")
        }

        // And the Me-row sentence must differ from the never-signed-in one,
        // which is the whole point of the row change.
        XCTAssertNotEqual(LKey.meSessionEnded.text(for: .english),
                          LKey.meSignInToSync.text(for: .english))
        XCTAssertNotEqual(LKey.meSessionEnded.text(for: .chinese),
                          LKey.meSignInToSync.text(for: .chinese))
    }

    // MARK: - 9. View wiring (structural, and declared as such)

    /// Weaker than a behavioural test and stated as such: `AccountView` and
    /// the Me-tab row are SwiftUI bodies with no seam this target can render.
    /// The brief left them to a manual simulator check, which leaves the G12
    /// wiring with no automated witness at all. This pins the three things
    /// that make the flag reach the user: the card is read off
    /// `needsReauthentication` (not `errorMessage`, which dies with the
    /// process), it is placed BEFORE the sign-in section, and the Me row
    /// reads the same flag.
    private func source(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testTheReAuthCardIsWiredToTheFlagAndSitsAboveTheSignInSection() {
        let account = source("Done/Views/Agent/AccountView.swift")
        XCTAssertFalse(account.isEmpty, "liveness: AccountView.swift must be readable")
        // Positive control: the search really can come up empty.
        XCTAssertNil(account.range(of: "needsReauthenticationXYZ"))

        XCTAssertNotNil(account.range(of: "authService.needsReauthentication"),
                        "the card must read the PERSISTED flag")
        XCTAssertNotNil(account.range(of: "sessionEndedNeedsReauth"),
                        "the card must render the app-authored localized sentence")

        guard let card = account.range(of: "sessionEndedCard"),
              let signIn = account.range(of: "signInSection") else {
            return XCTFail("AccountView no longer names sessionEndedCard / signInSection")
        }
        XCTAssertLessThan(card.lowerBound, signIn.lowerBound,
                          "the explanation must appear above the sign-in buttons")

        let me = source("Done/Views/Agent/AgentSettingsView.swift")
        XCTAssertFalse(me.isEmpty, "liveness: AgentSettingsView.swift must be readable")
        XCTAssertNotNil(me.range(of: "authService.needsReauthentication"),
                        "the Me row must read the same flag, not a second source of truth")
        XCTAssertNotNil(me.range(of: "meSessionEnded"))
    }

    /// The export promise and the trail convention comment are the two
    /// honesty edits G10 required in this same commit; neither is
    /// machine-checkable except as text. A projected auth error code is
    /// neither a count nor a row ID, so the old sentence would be false.
    func testTheExportPromiseCoversTheNewlyRecordedAuthCodes() {
        let dev = source("Done/Views/Agent/DeveloperSettingsView.swift")
        XCTAssertFalse(dev.isEmpty, "liveness: DeveloperSettingsView.swift must be readable")
        XCTAssertNil(dev.range(of: "Counts and IDs only"),
                     "the superseded promise must not survive alongside the auth codes")
        XCTAssertNotNil(dev.range(of: "auth error codes"),
                        "the promise must name what the trail now carries")
        XCTAssertNotNil(dev.range(of: "never titles, notes, addresses, or credentials"))
    }
}
