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
//     drives it through the real catch. The argument for covering it does
//     not need the anecdote this header used to give as fact ("a previous
//     probe on this codebase had BOTH of its call sites deleted and all
//     eight of its tests stayed green"): that claim is RECOUNTED and I
//     could not find its referent. The nearest artefact in history,
//     `f8aa731 probe(auth): record the shape of auth failure bodies before
//     throwing (gh#234 R0)`, is NOT an ancestor of this branch
//     (`git merge-base --is-ancestor f8aa731 HEAD` exits 1), so it cannot
//     be what the sentence meant here. The argument stands without it: a
//     test that never calls an entry point cannot observe whether anything
//     else does either.
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
//  URL is `https://stub.invalid`.
//
//  PROVENANCE OF THE FIXTURES. An earlier version of this header said they
//  were "derived from the envelope observed in gh#234". That is a FALSE
//  CITATION and I verified it against the issue myself rather than adopt
//  the implementer's correction: gh#234 contains no HTTP envelope, no
//  `x-sb-error-code` header, no `validation_failed`, and no "Refresh token
//  is not valid". What it records is GoTrue `edge_logs`/`auth_logs` rows —
//      error_code = refresh_token_already_used
//      grant_type = refresh_token
//      status     = 400
//      count      = 202   (2026-09-22T00:35:15Z → 03:10:40Z)
//  — and that code, under that status, is the ONLY observed fixture below.
//  Everything else is CONSTRUCTED and says so: the
//  `{"code":…,"error_code":…,"msg":…}` body shape is GoTrue's documented
//  envelope, `validation_failed` is a documented code chosen as a
//  must-never-be-terminal keep-case. `x-sb-error-code` is not in gh#234 and
//  not in Supabase's public registry, but it is not unobserved: a probe
//  against this project's own auth endpoint answered
//  `x-sb-error-code: validation_failed`. It accompanies the CODED errors
//  this endpoint raises and is NOT promised on every error response, so its
//  absence carries no information. Only its CASING here is a convention, and
//  even that is harmless because the header never decides anything
//  (`authHeaderRelation`).
//

import XCTest
import Combine
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

    /// Answers refresh grants from a script (the last entry repeats forever)
    /// and any other grant with a fresh session. Needed to drive several
    /// DIFFERENT transitions in one test, which is what separates a
    /// per-episode repeat count from a cumulative one.
    func scriptRefreshes(_ script: [(Data, URLResponse)]) {
        var index = 0
        handler = { request in
            guard request.url?.absoluteString.contains("grant_type=refresh_token") == true else {
                return qaResponse(200, qaSuccessBody(refreshToken: "signed-in"))
            }
            let entry = script[min(index, script.count - 1)]
            index += 1
            return entry
        }
    }
}

/// A one-shot rendezvous on the main actor, so a test can park one `postAuth`
/// inside its own request window and run a second one to completion there.
///
/// Both directions are needed and neither can be a `sleep`: a timing-based
/// interleave is the kind of test that passes on a fast machine and reports
/// nothing. `open` is latched, so signalling before anyone waits is safe and
/// the rig cannot deadlock if the task ordering ever changes.
@MainActor
private final class QAGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
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
    /// a value behind. Two clauses keep that value from being attributed to a
    /// LATER refresh failure: `postAuth` assigns unconditionally (including
    /// nil when the later response has no header), and it clears the field on
    /// entry.
    ///
    /// MEASURED: on the SEQUENTIAL ordering this test drives the two clauses
    /// are individually redundant — mutating either one alone leaves this
    /// test green, and only removing both reddens it. So this test does not
    /// pin the unconditional assignment; what pins it is
    /// `testAHeaderFromAConcurrentSignInIsNotAttributedToAnInFlightRefresh`,
    /// where the orderings interleave and the entry clear cannot stand in.
    /// An earlier version of this doc named the assignment as the thing this
    /// test protects. It does not. The two are kept adjacent deliberately:
    /// read them as a pair, sequential case then concurrent case.
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
    // MARK: - 10. Round 2 (repair round): what the repair itself introduced
    //
    // The repair changed `RefreshDecisionKey` from (status, code, terminal)
    // to (status, code, terminal, action) and DELETED the `action != .cleared`
    // exemption, on the argument that with the action in the key the
    // exemption is unreachable. It is not unreachable, and the test below is
    // the counterexample. Everything else here closes the two pins the repair
    // report declares structurally impossible, using this repo's
    // source-guard idiom (`StoreLookupScanGuardTests`) rather than adding a
    // production seam.

    /// Two terminal sign-outs in the same process must be two lines, never a
    /// line and a repeat count.
    ///
    /// Written as a witness for an OPEN defect and committed red. The defect
    /// is CLOSED — `RefreshTrailAction.namesAnIrreversibleAct` exempts every
    /// `.cleared` line from folding — and this test has been green since.
    /// The route below is kept because it is still exactly what the test
    /// drives; only the verdict changed.
    ///
    /// The route is gh#234's own: a poisoned refresh token clears the
    /// session, the user signs back in, and the new session's refresh hits
    /// the same terminal code. Sign-in records nothing on the trail, so the
    /// two `terminal/cleared` lines are adjacent and identical in every key
    /// field — status 400, `refresh_token_already_used`, `terminal`,
    /// `cleared`. Before the fix the second was suppressed and the trail read
    /// "one sign-out, then a repeat", which is the exact class of missing
    /// forensic trace gh#234 was filed about, on the exact question the
    /// reader has ("did signing in again help?").
    ///
    /// MEASURED, both directions:
    ///   - pre-repair semantics (action OUT of the key, `action != .cleared`
    ///     exemption present): PASSES — so this is a regression, not a
    ///     pre-existing hole.
    ///   - action IN the key AND the exemption restored: green, including
    ///     `testADiscardedStaleResultIsNeverFoldedIntoTheSuccessBeforeIt`.
    ///     The exemption is therefore reachable and load-bearing, and
    ///     deleting it was not a no-op.
    /// (Those runs reported 52/52; that total describes a tree that no longer
    /// exists. The DIRECTION of each result is what the measurement was for.)
    func testASecondSignOutIsStillItsOwnLine() async {
        seedSession(refreshToken: "S1")
        let stub = QACountingTransport()
        stub.split(refresh: qaResponse(400, qaErrorBody(code: "refresh_token_already_used")),
                   other: qaResponse(200, qaSuccessBody(refreshToken: "S2", userId: "u2")))
        let auth = makeAuth(stub)

        await auth.forceRefreshToken()          // terminal / cleared  (S1)
        XCTAssertNil(auth.session, "liveness: the first terminal really cleared")

        await auth.signInWithApple(idToken: "t", nonce: "n")
        XCTAssertEqual(auth.session?.refreshToken, "S2", "liveness: the user signed back in")

        await auth.forceRefreshToken()          // terminal / cleared  (S2)
        XCTAssertNil(auth.session, "liveness: the second terminal really cleared too")

        let cleared = trailMessages().filter { $0.contains("action=cleared") }
        XCTAssertEqual(cleared.count, 2,
                       "two sign-outs must be two lines:\n\(trailMessages().joined(separator: "\n"))")
    }

    /// F3's pin is on `refreshFailureLogToken(_:)`, not on the `os_log` call,
    /// and the report says so: reverting the logger line alone to
    /// `error.localizedDescription` would stay green, because os_log output
    /// is not observable from XCTest. It IS observable in the source, and
    /// that is the whole gap — so this closes it the way this repo already
    /// closes unrenderable wiring, with a scan plus a positive control.
    func testTheRefreshCatchLogsAProjectionAndNotTheServerMessage() {
        let src = source("Done/Services/AuthService.swift")
        XCTAssertFalse(src.isEmpty, "liveness: AuthService.swift must be readable")

        // Positive control: the predicate must recognize the pre-fix line.
        let preFix = #"logger.error("Token refresh failed: \(error.localizedDescription, privacy: .public)")"#
        XCTAssertTrue(preFix.contains("localizedDescription"),
                      "control: the matcher must flag the line this finding removed")
        XCTAssertFalse(preFix.contains("refreshFailureLogToken"))

        let code = src
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        let sites = code.filter { $0.contains("Token refresh failed") }
        XCTAssertEqual(sites.count, 1, "liveness: the scan must find the one catch-site log line")
        guard let line = sites.first else { return XCTFail("the refresh catch no longer logs at all") }

        XCTAssertTrue(line.contains("refreshFailureLogToken"),
                      "the refresh catch must log the closed-vocabulary projection: \(line)")
        XCTAssertFalse(line.contains("localizedDescription"),
                       "`localizedDescription` for `.authFailure` IS the server's msg: \(line)")
    }

    /// F5's pin is on `forgetReauthenticationNotice()`, not on the call to
    /// it, and the report says so: deleting
    /// `authService.forgetReauthenticationNotice()` from `resetAllLocalData()`
    /// would stay green. It also introduced a second, sharper risk the
    /// report names and leaves unguarded — `DataPrivacySettingsView` now has
    /// an `@EnvironmentObject AuthService`, so any presenter that does not
    /// inject one TRAPS at runtime. Both are text properties; both are
    /// pinned here.
    func testTheResetPathTellsTheAuthServiceAndEveryPresenterInjectsIt() {
        let settings = source("Done/Views/Agent/AgentSettingsView.swift")
        XCTAssertFalse(settings.isEmpty, "liveness: AgentSettingsView.swift must be readable")
        XCTAssertNil(settings.range(of: "forgetReauthenticationNoticeXYZ"),
                     "control: the search really can come up empty")

        // 1. The sweep is followed by telling the flag's owner.
        guard let reset = settings.range(of: "private func resetAllLocalData()") else {
            return XCTFail("resetAllLocalData() was renamed; this guard must be revisited")
        }
        let body = String(settings[reset.upperBound...])
        guard let sweep = body.range(of: "AppSettingsKeys.removeResettableKeys") else {
            return XCTFail("resetAllLocalData() no longer runs the named-key sweep")
        }
        guard let tell = body.range(of: "authService.forgetReauthenticationNotice()") else {
            return XCTFail("the sweep deletes authNeedsReauthentication behind the live AuthService's "
                           + "back; without this call the re-auth card and the orange Me row survive "
                           + "the wipe until relaunch")
        }
        XCTAssertLessThan(sweep.lowerBound, tell.lowerBound,
                          "the owner is told after the key is swept, not before")

        // 2. The view can see an AuthService at all.
        XCTAssertNotNil(settings.range(of: "@EnvironmentObject private var authService: AuthService"),
                        "DataPrivacySettingsView must declare the dependency it now uses")

        // 3. EVERY presenter injects one — a missing injection is a runtime
        //    trap, not a compile error.
        var presenters = 0
        for file in swiftSources(under: "Done") {
            var cursor = file.text.startIndex
            while let hit = file.text.range(of: "DataPrivacySettingsView()", range: cursor..<file.text.endIndex) {
                presenters += 1
                let tail = file.text[hit.upperBound...]
                let scope = tail.range(of: "} label:").map { String(tail[..<$0.lowerBound]) }
                    ?? String(tail.prefix(600))
                XCTAssertTrue(scope.contains(".environmentObject(authService)"),
                              "\(file.name) presents DataPrivacySettingsView without an AuthService; "
                              + "its @EnvironmentObject would trap at runtime")
                cursor = hit.upperBound
            }
        }
        XCTAssertEqual(presenters, 1,
                       "liveness: the scan must reach the one presentation site (found \(presenters))")
    }

    /// The rewritten byte-budget fixture picks its worst case with
    /// `recordableAuthCodes.max { $0.count < $1.count }` and then asserts
    /// WHICH member it picked. `recordableAuthCodes` is a `Set`, so with two
    /// members of equal maximal length `max` returns whichever the per-process
    /// hash seed put last — the fixture would flake rather than fail, and a
    /// flaky fixture is how a budget stops being checked. Today the maximum is
    /// unique; this makes the day it stops being unique a deterministic red.
    func testTheLongestRecordableCodeIsUniqueSoTheBudgetFixtureCannotFlake() {
        let codes = AuthService.recordableAuthCodes
        XCTAssertFalse(codes.isEmpty, "liveness: the vocabulary must be non-empty")
        guard let widest = codes.map(\.count).max() else { return XCTFail("empty vocabulary") }
        let tied = codes.filter { $0.count == widest }.sorted()
        XCTAssertEqual(tied, ["refresh_token_already_used"],
                       "the byte-budget fixture names its winner, so the winner must be unique")
        XCTAssertEqual(widest, 26)
    }

    /// F5's user-visible claim is that the card disappears IMMEDIATELY, not
    /// on the next launch. Reading the property back proves the value moved;
    /// it does not prove SwiftUI is told. A refactor to a computed property
    /// over `UserDefaults` would keep every value assertion green and leave
    /// the card on screen until something else redrew it.
    func testForgettingTheNoticePublishesAChangeSoTheBannerRedrawsWithoutARelaunch() async {
        seedSession()
        let stub = QACountingTransport()
        stub.always(qaResponse(400, qaErrorBody(code: "refresh_token_already_used")))
        let auth = makeAuth(stub)
        await auth.forceRefreshToken()
        XCTAssertTrue(auth.needsReauthentication, "liveness: a real terminal clear raised the banner")

        var published = 0
        let subscription = auth.objectWillChange.sink { _ in published += 1 }
        defer { subscription.cancel() }

        _ = auth.needsReauthentication
        XCTAssertEqual(published, 0, "control: a read must not publish, so the counter is not trivially non-zero")

        auth.forgetReauthenticationNotice()

        XCTAssertGreaterThanOrEqual(published, 1,
                                    "the banner's owner must be told, not just the stored value changed")
        XCTAssertFalse(auth.needsReauthentication)
    }

    /// Recursive `.swift` enumeration under a repo-relative directory, for
    /// the presenter scan above.
    private func swiftSources(under relativeDir: String) -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
        let dir = root.appendingPathComponent(relativeDir)
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(name: String, text: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                out.append((url.lastPathComponent, text))
            }
        }
        return out
    }

    // MARK: - 6. Round-3 QA: two surviving mutants this round left behind

    /// SURVIVING MUTANT, round 3, and the reason this test exists.
    ///
    /// `AuthService.swift`'s `lastAuthFailureHeaderCode` doc names the
    /// unconditional assignment at the single `status >= 400` site as "the
    /// whole argument" for why a header cannot be misattributed, and says it
    /// "is pinned rather than asserted here". Measured on the committed tree:
    /// turning that line into `if let h = … { lastAuthFailureHeaderCode = h }`
    /// left BOTH auth suites 60/60 green. So did deleting the entry clear at
    /// the top of `postAuth`, which the same doc labels hygiene. Only doing
    /// BOTH was red (1 failure, in
    /// `testAHeaderLeftBehindByAFailedSignInIsNotAttributedToALaterRefresh`).
    ///
    /// The reason the existing test cannot separate them is that it drives the
    /// two calls SEQUENTIALLY: `await signInWithApple(…)` has fully returned
    /// before `forceRefreshToken()` starts, so the refresh's own entry clear
    /// wipes the leftover before the refresh response is ever inspected, and
    /// the unconditional assignment has nothing left to do.
    ///
    /// The entry clear cannot cover the CONCURRENT ordering, and the doc
    /// comment raises exactly that case ("Two `postAuth` calls can be in
    /// flight at once"). This test builds it, deterministically:
    ///
    ///   1. the refresh enters `postAuth`, clears the field, and parks in the
    ///      transport;
    ///   2. a sign-in runs to completion INSIDE that window — it clears the
    ///      field, gets a 400 carrying `x-sb-error-code`, assigns it, and
    ///      throws into a catch that never consumes it;
    ///   3. the refresh's own response arrives with NO header.
    ///
    /// Unconditional: the refresh assigns nil and records `hdr=absent`.
    /// Conditional: the refresh skips the write and reports `hdr=differ` —
    /// a header disagreement that never happened, attributed from another
    /// request, on the non-JSON path where `hdr` is the only evidence there
    /// is. The entry clear cannot help, because the sign-in's write lands
    /// AFTER it.
    func testAHeaderFromAConcurrentSignInIsNotAttributedToAnInFlightRefresh() async {
        seedSession(refreshToken: "S1")
        let stub = QACountingTransport()
        let refreshParked = QAGate()
        let releaseRefresh = QAGate()
        var order: [String] = []

        stub.handler = { request in
            if request.url?.absoluteString.contains("grant_type=refresh_token") == true {
                await MainActor.run { order.append("refresh-request") }
                await refreshParked.open()
                await releaseRefresh.wait()
                await MainActor.run { order.append("refresh-response") }
                // Non-JSON body, NO header: nothing here can supply `hdr`.
                return qaResponse(400, "<html>gateway</html>")
            }
            await MainActor.run { order.append("signin-response") }
            return qaResponse(400, "<html>gateway</html>",
                              headers: ["x-sb-error-code": "refresh_token_already_used"])
        }
        let auth = makeAuth(stub)

        let refresh = Task { await auth.forceRefreshToken() }
        await refreshParked.wait()
        order.append("signin-start")
        await auth.signInWithApple(idToken: "t", nonce: "n")
        order.append("signin-done")
        releaseRefresh.open()
        await refresh.value

        // Liveness FIRST: if the rig did not actually interleave, everything
        // below degenerates into the sequential test that already passes.
        XCTAssertEqual(
            order,
            ["refresh-request", "signin-start", "signin-response", "signin-done", "refresh-response"],
            "the rig must land the sign-in's header write INSIDE the refresh's request window"
        )
        XCTAssertEqual(stub.callCount, 2, "liveness: both calls reached the transport")
        XCTAssertNotNil(auth.errorMessage, "liveness: the sign-in really failed")

        let line = trailMessages().first { $0.hasPrefix("refresh status=") }
        XCTAssertEqual(
            line,
            "refresh status=400 code=unrecognized codeLen=0 codeShape=other hdr=absent decision=kept action=kept",
            "a header from a concurrent sign-in must not be attributed to this refresh:\n\(trailMessages().joined(separator: "\n"))"
        )
        XCTAssertEqual(auth.session?.refreshToken, "S1",
                       "and nothing about a header may sign the device out")
    }

    /// Positive control for the test above, and the reason its `hdr=absent` is
    /// evidence rather than a tautology: under the SAME interleaving, a header
    /// on the refresh's own response is still found and still recorded. So
    /// `hdr=absent` above means "correctly reset", not "the header plumbing is
    /// dead inside a parked request".
    ///
    /// It also re-pins the red line on the concurrent path: `session_expired`
    /// is a member of `terminalRefreshCodes`, and arriving in the HEADER of a
    /// body that has no code must still KEEP the session.
    func testTheConcurrentRigStillFindsAHeaderTheRefreshResponseCarries() async {
        seedSession(refreshToken: "S1")
        let stub = QACountingTransport()
        let refreshParked = QAGate()
        let releaseRefresh = QAGate()

        stub.handler = { request in
            if request.url?.absoluteString.contains("grant_type=refresh_token") == true {
                await refreshParked.open()
                await releaseRefresh.wait()
                return qaResponse(400, "<html>gateway</html>",
                                  headers: ["x-sb-error-code": "session_expired"])
            }
            return qaResponse(400, "<html>gateway</html>",
                              headers: ["x-sb-error-code": "refresh_token_already_used"])
        }
        let auth = makeAuth(stub)

        let refresh = Task { await auth.forceRefreshToken() }
        await refreshParked.wait()
        await auth.signInWithApple(idToken: "t", nonce: "n")
        releaseRefresh.open()
        await refresh.value

        XCTAssertEqual(stub.callCount, 2, "liveness: both calls reached the transport")
        let line = trailMessages().first { $0.hasPrefix("refresh status=") }
        XCTAssertEqual(
            line,
            "refresh status=400 code=unrecognized codeLen=0 codeShape=other hdr=differ decision=kept action=kept",
            "the refresh's own header must still be found while parked:\n\(trailMessages().joined(separator: "\n"))"
        )
        XCTAssertEqual(auth.session?.refreshToken, "S1",
                       "a terminal code in the header alone must never sign the device out")
        XCTAssertFalse(auth.needsReauthentication)
    }

    /// SURVIVING MUTANT, round 3: deleting `suppressedRepeats = 0` from
    /// `recordRefreshDecision` — the reset that runs after a full line is
    /// emitted — left both auth suites 60/60 green.
    ///
    /// It is not an equivalent mutant. `after=n` is the count of failures
    /// folded into the PRECEDING episode, and `testEveryChangeOfKindGetsItsOwn
    /// LineInOrder` asserts `after=4` on the transition that flushes it — but
    /// nothing asserts that the count is then spent. Without the reset the
    /// counter is cumulative for the life of the process: every later
    /// transition re-reports the same stale `after=4`, and the next single
    /// fold resumes at 5 rather than 1, so `refresh repeat n=` skips straight
    /// to the next power of two. The trail then overstates how many times a
    /// failure repeated, which is the one number gh#234's reader is counting.
    ///
    /// Three episodes, so the flush and the spend are separate assertions:
    /// a 400 storm (one line + two folds), a 429 that flushes `after=2`, and
    /// the 400 again — whose line must carry NO `after=` at all.
    func testTheSuppressedRepeatCountIsSpentByTheLineThatFlushesIt() async {
        seedSession(refreshToken: "S1")
        let stub = QACountingTransport()
        stub.scriptRefreshes([
            qaResponse(400, qaErrorBody(code: "validation_failed")),      // new line
            qaResponse(400, qaErrorBody(code: "validation_failed")),      // fold 1
            qaResponse(400, qaErrorBody(code: "validation_failed")),      // fold 2
            qaResponse(429, qaErrorBody(code: "over_request_rate_limit", status: 429)),
            qaResponse(400, qaErrorBody(code: "validation_failed")),      // new episode
        ])
        let auth = makeAuth(stub)

        for _ in 0..<5 { await auth.forceRefreshToken() }

        XCTAssertNotNil(auth.session,
                        "liveness: every code here KEEPS the session, so all five requests fire")
        XCTAssertEqual(stub.callCount, 5, "liveness: five requests reached the transport")

        let full = trailMessages().filter { $0.hasPrefix("refresh status=") }
        guard full.count == 3 else {
            return XCTFail("400-storm → 429 → 400 is three transitions, got \(full.count):\n\(full.joined(separator: "\n"))")
        }
        XCTAssertFalse(full[0].contains("after="),
                       "the first line of an episode has nothing to flush: \(full[0])")
        XCTAssertTrue(full[1].contains("status=429"), full[1])
        XCTAssertTrue(full[1].hasSuffix(" after=2"),
                      "the two folded failures must be flushed into the next transition: \(full[1])")
        XCTAssertFalse(full[2].contains("after="),
                       "and SPENT there — a later transition must not re-report a count that belongs to an episode already closed: \(full[2])")
    }
}
