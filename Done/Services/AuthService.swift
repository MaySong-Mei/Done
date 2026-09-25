import Foundation
import AuthenticationServices
import Combine
import CryptoKit
import SafariServices
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Auth"
)

// MARK: - Auth State

struct AuthUser: Codable, Equatable {
    let id: String          // Supabase user UUID
    let email: String?
    let createdAt: String?
}

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let user: AuthUser
}

// MARK: - Auth Service

/// The one network seam `postAuth` goes through. Injected so the refresh
/// classifier (gh#234) can be driven end-to-end — through the REAL
/// `forceRefreshToken()` / `refreshTokenIfNeeded()` and the REAL catch — by
/// a test that hands back a fixture response. A unit test of the pure
/// classifier cannot make the catch-site wiring load-bearing. (The reason
/// given for that when this seam was added — "an earlier round deleted both
/// call sites of an instrumentation hook and all eight of its tests stayed
/// green" — is RECOUNTED, not checked: there is no artefact on this branch
/// to verify it against. The argument stands without it; a pure-function
/// test genuinely cannot observe whether anything calls the function.)
///
/// Deliberately scoped to `postAuth` alone; the three `rest/v1` helpers in
/// this file keep calling `URLSession.shared` directly.
typealias AuthTransport = (URLRequest) async throws -> (Data, URLResponse)

/// Manages Supabase Auth via REST API. No external SDK dependency.
///
/// Sign-in paths: Apple (`grant_type=id_token`) and Google (OAuth PKCE).
/// There is no email/password path — a previous version of this line claimed
/// one "for testing" and no `grant_type=password` request has ever existed in
/// this target. `postAuth` has exactly three callers: those two and
/// `performTokenRefresh`.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var session: AuthSession?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// True when this device's session was cleared because the server said
    /// the refresh token is permanently dead (gh#234) — as opposed to the
    /// user signing out. PERSISTED, because the terminal refresh typically
    /// fires during a background sync and the process is dead long before
    /// the user next opens Settings → Account; an in-memory `errorMessage`
    /// would leave them with an unexplained sign-in page, which is the
    /// "无从判断" the issue names.
    @Published private(set) var needsReauthentication: Bool

    var isSignedIn: Bool { session != nil }
    var userId: String? { session?.user.id }
    var accessToken: String? { session?.accessToken }

    private let supabaseURL: String
    /// Project API key — used ONLY for the `apikey` HTTP header (which
    /// identifies the Supabase project). `Authorization: Bearer <jwt>`
    /// uses the per-user session JWT, NOT this key.
    ///
    /// Defaults to `SupabaseSyncConfig.publishableKey` — the modern
    /// publishable key, public by design. (Its predecessor was a
    /// hardcoded service_role JWT that leaked through this public
    /// repo; incident and rotation checklist in gh#232.)
    private let projectAPIKey: String
    private let sessionKey = "supabaseAuthSession"
    /// `UserDefaults` key for `needsReauthentication`. `nonisolated` so the
    /// non-isolated reset sweep in `AppSettingsKeys` can name it.
    nonisolated static let needsReauthKey = "authNeedsReauthentication"
    private let defaults: UserDefaults
    private let transport: AuthTransport

    init(
        url: String = SupabaseSyncConfig.url,
        projectAPIKey: String = SupabaseSyncConfig.publishableKey,
        defaults: UserDefaults = .standard,
        transport: @escaping AuthTransport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.supabaseURL = url
        self.projectAPIKey = projectAPIKey
        self.defaults = defaults
        self.transport = transport
        self.needsReauthentication = defaults.bool(forKey: AuthService.needsReauthKey)
        loadSession()
    }

    // MARK: - Apple Sign In

    /// Call this with the result of ASAuthorizationController.
    func signInWithApple(
        idToken: String,
        nonce: String
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let body: [String: Any] = [
                "provider": "apple",
                "id_token": idToken,
                "nonce": nonce,
            ]
            let result = try await postAuth(
                path: "/auth/v1/token?grant_type=id_token",
                body: body
            )
            let session = try parseSessionResponse(result.json)
            installSession(session)
            logger.info("Apple Sign In succeeded as \(session.user.id, privacy: .private)")
        } catch {
            // `errorMessage` keeps the server's sentence on purpose: it is
            // the only thing that tells the user WHY sign-in failed, and it
            // goes to this user's own screen. The unified log does not get
            // it — `log collect` hands that to whoever is debugging, which
            // is the same audience as the exported trail, so it gets the
            // same closed-vocabulary projection. Same rule, all three
            // `postAuth` catches.
            errorMessage = error.localizedDescription
            logger.error("Apple Sign In failed: \(AuthService.refreshFailureLogToken(error), privacy: .public)")
        }
    }

    // MARK: - Google Sign In (via Supabase OAuth PKCE)

    private static let callbackScheme = "com.example.done"
    private static let redirectURI = "\(callbackScheme)://auth/callback"

    func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil

        let codeVerifier = AuthService.randomNonce(length: 64)
        let codeChallenge = AuthService.sha256(codeVerifier)

        var components = URLComponents(string: "\(supabaseURL)/auth/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "flow_type", value: "pkce"),
        ]
        guard let authURL = components.url else {
            isLoading = false
            errorMessage = "Failed to build Google auth URL"
            return
        }

        do {
            let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callback: .customScheme(Self.callbackScheme)
                ) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: AuthError.invalidResponse)
                    }
                }
                session.prefersEphemeralWebBrowserSession = false
                session.presentationContextProvider = GoogleSignInPresenter.shared

                // Must retain the session until completion
                GoogleSignInPresenter.shared.currentSession = session
                session.start()
            }

            // Extract auth code from callback URL
            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            else {
                isLoading = false
                errorMessage = "No authorization code received"
                return
            }

            // Exchange code for session via PKCE
            let body: [String: Any] = [
                "auth_code": code,
                "code_verifier": codeVerifier,
            ]
            let result = try await postAuth(
                path: "/auth/v1/token?grant_type=pkce",
                body: body
            )
            let session = try parseSessionResponse(result.json)
            installSession(session)
            isLoading = false
            logger.info("Google Sign In succeeded as \(session.user.email ?? session.user.id, privacy: .private)")
        } catch {
            isLoading = false
            let nsError = error as NSError
            // ASWebAuthenticationSessionError.canceledLogin
            if nsError.domain == ASWebAuthenticationSessionErrorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                return // user cancelled, no error message
            }
            // See the Apple catch: the sentence goes to the user, the token
            // goes to the log.
            errorMessage = error.localizedDescription
            logger.error("Google Sign In failed: \(AuthService.refreshFailureLogToken(error), privacy: .public)")
        }
    }

    // MARK: - Token Refresh

    /// Shared in-flight refresh task so concurrent callers don't all fire
    /// their own `grant_type=refresh_token` request with the SAME (about to
    /// be rotated) refresh token — Supabase rotates on use, so only the
    /// first wins; the rest would 400 and produce spurious log noise.
    /// Sharing one task across callers means: first caller starts the
    /// refresh, all callers await its completion, all read the new
    /// `accessToken` afterwards.
    ///
    /// `AuthService` is `@MainActor`, so the read-check-assign sequence on
    /// this property is atomic w.r.t. concurrent callers — no lock needed.
    /// The defensive re-check inside `performTokenRefresh` exists purely as
    /// a belt-and-suspenders if this class ever loses its MainActor isolation.
    private var refreshTask: Task<Void, Never>?

    func refreshTokenIfNeeded() async {
        guard let session else { return }
        // Refresh if within 5 minutes of expiry
        guard session.expiresAt.timeIntervalSinceNow < 300 else { return }

        // If a refresh is already in flight, just wait for it. The
        // post-await read of `accessToken` will see the new token.
        if let inflight = refreshTask {
            await inflight.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performTokenRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Force a refresh even when the cached `expiresAt` says we're still
    /// good. Used by `SupabaseREST` after a 401 — the server disagreed
    /// with our clock-based judgment about the token's freshness.
    /// Same in-flight dedup as `refreshTokenIfNeeded`.
    func forceRefreshToken() async {
        guard session != nil else { return }
        if let inflight = refreshTask {
            await inflight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performTokenRefresh(force: true)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performTokenRefresh(force: Bool = false) async {
        guard let sent = session else { return }
        let session = sent
        if !force {
            // Re-check after potential micro-race on `refreshTask` assignment:
            // if another caller beat us into the network and the session was
            // refreshed in between, exit early without making a redundant call.
            //
            // Force path skips this because the caller observed the server
            // *reject* a token our clock thought was still fresh — clock
            // skew, revocation, or a key rotation on the server. The
            // belt-and-suspenders re-check would silently no-op the force
            // request and keep the bad token cached.
            guard session.expiresAt.timeIntervalSinceNow < 300 else { return }
        }
        do {
            let body: [String: Any] = [
                "refresh_token": session.refreshToken,
            ]
            let result = try await postAuth(
                path: "/auth/v1/token?grant_type=refresh_token",
                body: body
            )
            let newSession = try parseSessionResponse(result.json)
            // Compare-and-install. A refresh for S1 can still be in flight
            // (URLSession's default timeout is 60s) after the user signed out
            // and back in as S2 — installing S1' then would overwrite S2,
            // possibly with a DIFFERENT user's session.
            if self.session?.refreshToken == sent.refreshToken {
                installSession(newSession)
                logger.info("Token refreshed")
                recordRefreshDecision(status: result.status,
                                      rawCode: nil,
                                      headerCode: nil,
                                      decision: .ok,
                                      action: .installed)
            } else {
                logger.info("Token refresh result discarded — the session changed while the request was in flight")
                recordRefreshDecision(status: result.status,
                                      rawCode: nil,
                                      headerCode: nil,
                                      decision: .ok,
                                      action: .stale)
            }
        } catch {
            // NOT `error.localizedDescription`: for `.authFailure` that IS the
            // server's `msg`, the one unbounded-content field in the envelope.
            // The trail refuses to carry it (see "Refresh trail" below) and
            // the unified log is no more private than the trail — `.public`
            // or not, `log collect` hands it to whoever is debugging. Same
            // projection, same closed vocabulary.
            logger.error("Token refresh failed: \(AuthService.refreshFailureLogToken(error), privacy: .public)")
            let headerCode = takeLastAuthFailureHeaderCode()
            // THE RED LINE: the default is to KEEP the session. Only a typed
            // `.authFailure` — i.e. the server answered with an HTTP status —
            // is even eligible. `URLError` (flaky wifi, airplane mode),
            // `CancellationError`, `.invalidResponse` (a 2xx whose body did
            // not parse) and `.serverError` are not this case and fall
            // straight through with the session intact.
            guard case let AuthError.authFailure(status, bodyCode, _) = error else { return }

            let outcome = AuthService.refreshOutcome(status: status, bodyCode: bodyCode)
            var action = RefreshTrailAction.kept
            if case .terminal = outcome {
                // Compare-and-clear, same reason as compare-and-install above:
                // never sign out a session this request was not made with.
                if self.session?.refreshToken == sent.refreshToken {
                    clearSession(reason: .terminalRefresh)
                    action = .cleared
                } else {
                    action = .stale
                }
            }
            // Deliberately NOT `errorMessage = ...`: the server's `msg` is the
            // one unbounded-content field in the envelope and `AccountView`
            // renders `errorMessage` verbatim. The user-facing sentence for
            // this branch is app-authored and localized (`needsReauthentication`).
            recordRefreshDecision(status: status,
                                  rawCode: bodyCode,
                                  headerCode: headerCode,
                                  decision: action == .kept ? .kept : .terminal,
                                  action: action)
        }
    }

    // MARK: - Terminal-refresh classification (gh#234)

    /// What to do with the local session after a failed refresh grant.
    nonisolated enum RefreshOutcome: Equatable {
        /// The refresh token is permanently dead; retrying can never succeed.
        case terminal(String)
        /// Everything else. Keep the session and let the next attempt run.
        case keep
    }

    /// `error_code` values on a 400 refresh grant that mean the token is
    /// permanently dead. A positive allowlist, never "if not transient then
    /// terminal".
    ///
    /// - `refresh_token_already_used` — OBSERVED on this project (gh#234's
    ///   GoTrue edge_logs, 202 occurrences).
    /// - `refresh_token_not_found`, `session_expired`, `session_not_found` —
    ///   DOCUMENTED in Supabase's auth error-code registry, NOT observed
    ///   here. They are included because none of the four has a transient
    ///   cause: a false terminal costs exactly one re-sign-in and destroys no
    ///   persisted data, while a miss is gh#234's unbounded silent death.
    ///
    /// `validation_failed` is deliberately NOT a member. It is GoTrue's
    /// generic 400 bucket for a malformed body, so a client bug that
    /// malformed the refresh request would sign out every user on that build.
    /// It is not observed here either: a previous version of this line called
    /// it "the only code OBSERVED first-hand (see the envelope in gh#234)",
    /// and gh#234 contains no such envelope — the only code the issue
    /// records is `refresh_token_already_used` (400, count 202), which is the
    /// first member above. The `validation_failed` fixtures in the tests are
    /// an INVENTED keep-case, chosen because it is a real documented GoTrue
    /// code that must never be terminal; they are not a transcript.
    nonisolated static let terminalRefreshCodes: Set<String> = [
        "refresh_token_already_used",
        "refresh_token_not_found",
        "session_expired",
        "session_not_found",
    ]

    /// Pure, and the ONLY thing that decides whether a session is cleared.
    ///
    /// Terminal requires BOTH conditions. `status == 400` is the only status
    /// OBSERVED on this endpoint's error envelope; a terminal code under any
    /// other status is unobserved and therefore kept — that fails safe, and
    /// the trail line records `status=<n> code=<name> decision=kept` so the
    /// gate can be widened later ON EVIDENCE. The status is load-bearing and
    /// not decoration: a 429 `over_request_rate_limit` carries an
    /// `error_code` too, and gh#234's retry storm is exactly what makes 429
    /// reachable.
    nonisolated static func refreshOutcome(status: Int, bodyCode: String?) -> RefreshOutcome {
        guard status == 400,
              let bodyCode,
              terminalRefreshCodes.contains(bodyCode)
        else { return .keep }
        return .terminal(bodyCode)
    }

    // MARK: - Refresh trail (gh#234)
    //
    // `DiagnosticTrail` is a file the user EXPORTS and hands to a stranger,
    // so the line below is built by PROJECTION, never by redaction. Every
    // field is either an integer the app computed or a token chosen from a
    // vocabulary compiled into this binary. No byte of any server response
    // reaches the line — not `msg`, not `error_description`, not an
    // unrecognized `error_code`, not a prefix or hash of one, not the
    // request URL, not `localizedDescription`.
    //
    // Redaction was tried in an earlier round and is unsound in principle as
    // well as in practice: that redactor let `dk_<64 hex>` MCP keys,
    // `sb_secret_…`, opaque refresh tokens and this app's own 6-character
    // connect codes through every length- and delimiter-shaped heuristic.
    // A 6-character credential defeats the whole class of rule. A closed
    // vocabulary has no heuristic to get wrong.

    /// Codes the trail may NAME. Everything else projects to `unrecognized`.
    /// The two non-terminal members are here because "which non-terminal code
    /// kept coming back" is the question this trail exists to answer.
    nonisolated static let recordableAuthCodes: Set<String> =
        terminalRefreshCodes.union(["validation_failed", "over_request_rate_limit"])

    nonisolated enum RefreshTrailDecision: String, CaseIterable {
        case terminal, kept, ok
    }

    nonisolated enum RefreshTrailAction: String, CaseIterable {
        /// Terminal, and this session was the one the request was made with.
        case cleared
        /// Session left alone.
        case kept
        /// The session changed while the request was in flight, so the
        /// result — success or terminal — was discarded.
        case stale
        /// A refreshed session replaced the one the request was made with.
        case installed

        /// Whether this action names an ACT that happened and cannot be
        /// undone, as opposed to a state the line merely observes.
        ///
        /// A repeat count is a lossless summary of an observation: "still
        /// failing, 8 more times" loses nothing. It is a LOSSY summary of an
        /// act: "signed the user out, then a repeat" does not say the user
        /// signed back in and was signed out again, and that is precisely
        /// the question gh#234's reader has — did signing in again help? So
        /// a line whose action names an irreversible act is never folded,
        /// however identical its neighbours look.
        ///
        /// The `switch` is exhaustive with NO `default` on purpose: adding a
        /// case to this enum is a compile error here, so whoever adds the
        /// next action has to answer this question. That is the difference
        /// between this and the `action != .cleared` conjunct it replaces —
        /// a conjunct at the call site has to be re-audited by hand, and the
        /// two rounds of history in `recordRefreshDecision` below are what
        /// re-auditing by hand costs.
        var namesAnIrreversibleAct: Bool {
            switch self {
            case .cleared:
                // The session is gone and the user has been ejected. Every
                // one of those is its own event, never a repeat of the last.
                return true
            case .kept, .stale, .installed:
                // Observations and recoverable transitions. Two `installed`
                // in a row really do mean "it refreshed twice".
                return false
            }
        }
    }

    nonisolated static func projectedAuthCode(_ raw: String?) -> String {
        guard let raw, recordableAuthCodes.contains(raw) else { return "unrecognized" }
        return raw
    }

    /// Shape of the raw code as an app-authored token. Carries "did this look
    /// like an error code at all" without carrying any of its characters.
    nonisolated static func authCodeShape(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "other" }
        let isLowerSnake = raw.allSatisfy { ch in
            ("a"..."z").contains(ch) || ("0"..."9").contains(ch) || ch == "_"
        }
        return isLowerSnake ? "lower_snake" : "other"
    }

    /// Three-valued corroboration only. The `x-sb-error-code` header NEVER
    /// influences the decision: on the one path where the body has no code
    /// (a proxy error page) the body is least trustworthy, and moving an
    /// irreversible sign-out onto a single header there is exactly the wrong
    /// trade. Recorded so a future disagreement between header and body is
    /// visible without another instrumented build.
    nonisolated static func authHeaderRelation(header: String?, body: String?) -> String {
        guard let header else { return "absent" }
        return header == body ? "match" : "differ"
    }

    /// A failed `postAuth` projected onto app-authored tokens, for `os_log`.
    /// Same rule as `refreshTrailLine`: no byte of a server response leaves
    /// the process. `AuthError.serverError`'s payload is app-authored, but it
    /// is dropped anyway — this is a classification, not a message.
    ///
    /// The name says `refresh` because that is the catch it was written for;
    /// it is called from all three `postAuth` catches (Apple, Google,
    /// refresh), which is where the same leak lived. It is a pure function of
    /// the error and has nothing refresh-specific in it. Renaming it is a
    /// follow-up, not a no-op: a QA source guard matches the call site by
    /// this literal.
    nonisolated static func refreshFailureLogToken(_ error: Error) -> String {
        switch error {
        case let AuthError.authFailure(status, code, _):
            return "authFailure status=\(status) code=\(projectedAuthCode(code))"
        case AuthError.invalidResponse:
            return "invalidResponse"
        case AuthError.invalidURL:
            return "invalidURL"
        case AuthError.serverError:
            return "serverError"
        case is CancellationError:
            return "cancelled"
        case let urlError as URLError:
            return "urlError code=\(urlError.code.rawValue)"
        default:
            return "other"
        }
    }

    /// The whole line, as a pure function of app-authored values.
    nonisolated static func refreshTrailLine(
        status: Int,
        rawCode: String?,
        headerCode: String?,
        decision: RefreshTrailDecision,
        action: RefreshTrailAction
    ) -> String {
        let token = decision == .ok ? "ok" : projectedAuthCode(rawCode)
        return "refresh status=\(status)"
            + " code=\(token)"
            + " codeLen=\(rawCode?.count ?? 0)"
            + " codeShape=\(authCodeShape(rawCode))"
            + " hdr=\(authHeaderRelation(header: headerCode, body: rawCode))"
            + " decision=\(decision.rawValue)"
            + " action=\(action.rawValue)"
    }

    /// Exactly the fields the line is keyed on — `action` included, so two
    /// lines collapse only when they really are the same line.
    ///
    /// `action` belongs here and NOT only in a call-site special case: with
    /// it out of the key, a compare-and-install discard (`decision=ok
    /// action=stale` — the mechanism that stops a slow refresh for an OLD
    /// session installing what may be a DIFFERENT user's session over the
    /// current one) carried the same key as the ordinary `installed` line
    /// before it and was folded away as `refresh repeat n=1`. The one safety
    /// mechanism nobody asks for was the one with no forensic trace.
    ///
    /// This key does NOT subsume `RefreshTrailAction.namesAnIrreversibleAct`,
    /// and a previous round's claim that it does was measured false. The two
    /// answer different questions: the key asks "is this the same LINE as the
    /// last one?", the predicate asks "even if it is, is it the same EVENT?".
    /// Two sign-outs produce byte-identical keys and are still two sign-outs.
    ///
    /// Pinned by `testADiscardedStaleResultIsNeverFoldedIntoTheSuccessBeforeIt`
    /// (installed → stale) and `testTheClearingLineSurvivesAnIdenticalStaleLineBeforeIt`
    /// (terminal/stale → terminal/cleared). Deleting `action` from this
    /// struct turns both red; the event property has its own pins, listed on
    /// `namesAnIrreversibleAct`'s call site below.
    private struct RefreshDecisionKey: Equatable {
        let status: Int
        let code: String
        let terminal: Bool
        let action: RefreshTrailAction
    }

    /// Record TRANSITIONS, not requests.
    ///
    /// Arithmetic, recomputed against what `DiagnosticTrail.record` actually
    /// writes rather than against the message alone (an earlier version of
    /// this comment said "~120 B" and undercounted by about a third, because
    /// it forgot the timestamp/session/category prefix the file carries):
    /// the message is 92–127 B and the prefix + newline adds a fixed 42 B, so
    /// a line on disk is 134–169 B. `DiagnosticTrail.rotateAtBytes` is
    /// 192 KB ⇒ 1,163–1,467 lines. One line PER REQUEST — which is what this
    /// function exists to avoid — would burn through that in ~14 h at
    /// gh#234's average rate (202 failures in ~2.5 h) and ~2 h at its peak
    /// (16 requests in 96 s). Both are inside one poisoning episode, and FIFO
    /// rotation drops the OLDEST end first, which is precisely the
    /// last-success / first-failure pair that localises the poisoning. Every
    /// repeat also costs a synchronous stat + write on the MainActor inside
    /// the amplifier gh#234 describes. An integer increment costs nothing.
    /// Do not "fix" that by moving the write off the main thread instead —
    /// that trades away the durability the trail exists for.
    ///
    /// Both halves of that arithmetic are pinned, not just asserted here:
    /// `testTrailLineStaysUnderTheByteBudget` bounds the message and
    /// `testTheOnDiskTrailLineIsTheSizeTheBudgetAssumes` bounds the whole
    /// written line, prefix included.
    private var lastRefreshDecision: RefreshDecisionKey?
    private var suppressedRepeats = 0

    private func recordRefreshDecision(
        status: Int,
        rawCode: String?,
        headerCode: String?,
        decision: RefreshTrailDecision,
        action: RefreshTrailAction
    ) {
        let key = RefreshDecisionKey(
            status: status,
            code: decision == .ok ? "ok" : AuthService.projectedAuthCode(rawCode),
            terminal: decision == .terminal,
            action: action
        )
        // TWO different jobs, and both rounds of defect in this function came
        // from confusing them. `key` decides whether this is the same LINE as
        // the last one. `namesAnIrreversibleAct` decides whether, even so, it
        // is the same EVENT — a second sign-out is byte-identical to the
        // first in all four key fields (status 400, same code, terminal,
        // cleared) and sign-in records nothing in between, so without this
        // conjunct gh#234's own loop (poisoned token clears the session, the
        // user signs back in, the new session hits the same code) reads as
        // "one sign-out, then a repeat" on exactly the question the reader
        // came with.
        //
        // Pinned by `testTheClearingLineIsNeverSuppressed` (two real clears,
        // two lines) and QA's `testASecondSignOutIsStillItsOwnLine`. Deleting
        // either conjunct turns tests red; measured, both directions.
        if !action.namesAnIrreversibleAct, key == lastRefreshDecision {
            suppressedRepeats += 1
            // Powers of two: enough to read the order of magnitude off the
            // trail, bounded at log2(n) lines however long the storm runs.
            if suppressedRepeats & (suppressedRepeats - 1) == 0 {
                DiagnosticTrail.record("Auth", "refresh repeat n=\(suppressedRepeats)")
            }
            return
        }
        var line = AuthService.refreshTrailLine(
            status: status,
            rawCode: rawCode,
            headerCode: headerCode,
            decision: decision,
            action: action
        )
        if suppressedRepeats > 0 { line += " after=\(suppressedRepeats)" }
        suppressedRepeats = 0
        lastRefreshDecision = key
        DiagnosticTrail.record("Auth", line)
    }

    // MARK: - Permanent MCP URL

    /// Generates a permanent API key and returns the full MCP URL with it embedded.
    func generatePermanentMCPURL() async throws -> URL {
        guard let userId else { throw AuthError.serverError("Not signed in") }

        let keyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let key = "dk_" + keyBytes.map { String(format: "%02x", $0) }.joined()

        let hash = SHA256.hash(data: Data(key.utf8))
        let keyHash = hash.map { String(format: "%02x", $0) }.joined()

        let body: [String: Any] = [
            "user_id": userId,
            "key_hash": keyHash,
            "label": "Claude / MCP connector",
        ]

        guard let url = URL(string: "\(supabaseURL)/rest/v1/api_keys") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(projectAPIKey, forHTTPHeaderField: "apikey")
        // User-JWT auth (#28): RLS enforces auth.uid() = user_id on all three
        // tables (api_keys / mcp_connect_codes / snapshots — INSERT policies
        // verified in migrations 002/004/005). Earlier this header passed
        // the bundled project key (which decoded to service_role and
        // bypassed RLS). Token is fetched lazily; if expired refresh first.
        await refreshTokenIfNeeded()
        guard let token = session?.accessToken, !token.isEmpty else {
            throw AuthError.serverError("Not signed in")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.serverError("Failed to create API key (HTTP \(code))")
        }

        // Build via URLComponents so the server-returned token is percent-
        // encoded instead of force-unwrapping a URL(string:) that traps on
        // illegal characters.
        guard var components = URLComponents(string: "\(supabaseURL)/functions/v1/mcp") else {
            throw AuthError.serverError("Invalid MCP URL")
        }
        components.queryItems = [URLQueryItem(name: "token", value: key)]
        guard let url = components.url else {
            throw AuthError.serverError("Invalid MCP URL")
        }
        return url
    }

    // MARK: - MCP Connect Code

    /// Generates a 6-char code for linking AI OAuth sessions (valid 5 min).
    func generateMCPConnectCode() async throws -> String {
        guard let userId else { throw AuthError.serverError("Not signed in") }

        let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<6).map { _ in charset[Int.random(in: 0..<charset.count)] })

        let expiresAt = Date().addingTimeInterval(5 * 60)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let body: [String: Any] = [
            "code": code,
            "user_id": userId,
            "expires_at": isoFormatter.string(from: expiresAt),
        ]

        guard let url = URL(string: "\(supabaseURL)/rest/v1/mcp_connect_codes") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(projectAPIKey, forHTTPHeaderField: "apikey")
        // User-JWT auth (#28): RLS enforces auth.uid() = user_id on all three
        // tables (api_keys / mcp_connect_codes / snapshots — INSERT policies
        // verified in migrations 002/004/005). Earlier this header passed
        // the bundled project key (which decoded to service_role and
        // bypassed RLS). Token is fetched lazily; if expired refresh first.
        await refreshTokenIfNeeded()
        guard let token = session?.accessToken, !token.isEmpty else {
            throw AuthError.serverError("Not signed in")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.serverError("Failed to create connect code (HTTP \(code))")
        }
        return code
    }

    // MARK: - AI Snapshot

    /// Creates a 5-minute single-use token and returns the snapshot URL.
    func generateSnapshotURL() async throws -> URL {
        guard let userId else {
            throw AuthError.serverError("Not signed in")
        }

        let snapshotToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let expiresAt = Date().addingTimeInterval(5 * 60)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let body: [String: Any] = [
            "token": snapshotToken,
            "user_id": userId,
            "expires_at": isoFormatter.string(from: expiresAt),
        ]

        guard let url = URL(string: "\(supabaseURL)/rest/v1/snapshots") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(projectAPIKey, forHTTPHeaderField: "apikey")
        // User-JWT auth (#28): RLS enforces auth.uid() = user_id on all three
        // tables (api_keys / mcp_connect_codes / snapshots — INSERT policies
        // verified in migrations 002/004/005). Earlier this header passed
        // the bundled project key (which decoded to service_role and
        // bypassed RLS). Token is fetched lazily; if expired refresh first.
        await refreshTokenIfNeeded()
        guard let token = session?.accessToken, !token.isEmpty else {
            throw AuthError.serverError("Not signed in")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.serverError("Failed to create snapshot (HTTP \(code))")
        }

        guard var components = URLComponents(string: "\(supabaseURL)/functions/v1/snapshot") else {
            throw AuthError.serverError("Invalid snapshot URL")
        }
        components.queryItems = [URLQueryItem(name: "token", value: snapshotToken)]
        guard let url = components.url else {
            throw AuthError.serverError("Invalid snapshot URL")
        }
        return url
    }

    // MARK: - Sign Out

    func signOut() {
        clearSession(reason: .userInitiated)
        logger.info("Signed out")
    }

    // MARK: - Session lifecycle
    //
    // THREE sites assign `session`, and the count matters because two of the
    // doc comments below claim to be "the ONE place":
    //
    //   - `clearSession(reason:)` — the only `session = nil`, and the only
    //     place the persisted key is removed. "The ONE place a session is
    //     cleared" is exact.
    //   - `installSession(_:)` — the only place a session obtained from the
    //     SERVER is adopted. "The ONE place a session is installed" is meant
    //     in that sense and only that sense.
    //   - `loadSession()` — `session = saved`, restoring from `UserDefaults`
    //     at init. It is a third writer. It does not persist, does not touch
    //     the re-auth flag, and adopts nothing new, which is why it is not an
    //     install; it is still an assignment, and a reader counting writers
    //     will find three.

    enum SessionClearReason {
        /// The user pressed Sign Out.
        case userInitiated
        /// The server said this refresh token is permanently dead (gh#234).
        case terminalRefresh
    }

    /// The ONE place a session is cleared. Both halves are load-bearing and
    /// half-clearing either way reproduces a defect:
    ///
    /// - `session = nil` without removing the key: the relaunched app
    ///   restores the poisoned token from `UserDefaults` and the failure loop
    ///   resumes after the user was told to sign in again.
    /// - removing the key without nilling `session`: `isSignedIn` stays true,
    ///   so `AccountView` keeps showing the signed-in section and the sign-in
    ///   UI never appears — gh#234's original "no exit" symptom.
    ///
    /// Note it does NOT go through `saveSession()`: that has a
    /// `guard let session else { return }`, so persisting a nil session
    /// through it is a silent no-op.
    private func clearSession(reason: SessionClearReason) {
        session = nil
        defaults.removeObject(forKey: sessionKey)
        switch reason {
        case .terminalRefresh:
            defaults.set(true, forKey: AuthService.needsReauthKey)
            needsReauthentication = true
        case .userInitiated:
            defaults.removeObject(forKey: AuthService.needsReauthKey)
            needsReauthentication = false
        }
    }

    /// Drops the re-auth notice: the persisted flag AND the `@Published`
    /// copy the banner reads.
    ///
    /// "Reset all local data" sweeps `authNeedsReauthentication` out of
    /// `UserDefaults` by name (`AppSettingsKeys.removeResettableKeys`), which
    /// is behind this object's back — `needsReauthentication` stayed true in
    /// memory, so the warning card and the orange Me-tab row survived the
    /// wipe until the next launch. Removing the key is not the same act as
    /// telling its owner.
    func forgetReauthenticationNotice() {
        defaults.removeObject(forKey: AuthService.needsReauthKey)
        needsReauthentication = false
    }

    /// The ONE place a session is installed — both sign-in paths and the
    /// refresh success path. Any successful authentication answers the
    /// question the re-auth banner asks, so the flag clears here rather than
    /// at three separate sites where the fourth would be forgotten.
    private func installSession(_ newSession: AuthSession) {
        session = newSession
        saveSession()
        defaults.removeObject(forKey: AuthService.needsReauthKey)
        needsReauthentication = false
    }

    // MARK: - Nonce generation for Apple Sign In

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            for random in randoms {
                guard remainingLength > 0 else { break }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    private func saveSession() {
        guard let session else { return }
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: sessionKey)
        }
    }

    private func loadSession() {
        guard let data = defaults.data(forKey: sessionKey),
              let saved = try? JSONDecoder().decode(AuthSession.self, from: data)
        else { return }
        session = saved
    }

    // MARK: - HTTP Helpers

    /// The `x-sb-error-code` of the most recent `postAuth` response, and
    /// nothing else.
    ///
    /// WHAT MAKES THIS SAFE — the earlier comment here got it wrong twice and
    /// both errors are worth naming, because the value is cross-call mutable
    /// state whose only reader is a different function.
    ///
    /// It is NOT "consumed by the very next catch": `postAuth` has three
    /// callers and only `performTokenRefresh` ever calls `take…`. Both
    /// sign-in catches leave whatever they set behind.
    ///
    /// It is NOT the single-read `take…` either. Nil-ing on read keeps a
    /// server byte from lingering in memory, which is worth doing, but it
    /// cannot stop a *stale* value being read — the reader would have to know
    /// it was stale.
    ///
    /// What actually makes it safe is the ONE write that matters: at the
    /// single `status >= 400` site in `postAuth`, on the statement before the
    /// `throw`, this is assigned UNCONDITIONALLY — including nil when the
    /// header is absent. `.authFailure` is thrown from nowhere else, so
    /// whenever one reaches a catch this property holds that response's
    /// header or nil. A predecessor's value cannot survive into it, and a
    /// response with no header reads as no header rather than as the last one
    /// that had one. That is the whole argument, and it is pinned rather than
    /// asserted here: `hdr=absent` after a failed sign-in whose response DID
    /// carry the header, and `hdr=differ`/`hdr=match` when the refresh
    /// response carries one itself.
    ///
    /// Two `postAuth` calls can be in flight at once, so the window between
    /// that assignment and the catch matters: there is no `await` on it and
    /// this class is `@MainActor`, so no other task can run there.
    ///
    /// The entry clear in `postAuth` and the nil-on-read in `take…` are
    /// HYGIENE, not part of that argument — they bound how long a server byte
    /// sits in memory. Neither is load-bearing and neither is pinned; if one
    /// is ever removed, the attribution argument above is unaffected.
    ///
    /// It lives here rather than on the error because the header must stay
    /// out of anything a caller could render: `AuthError` is user-visible
    /// through `errorDescription`, and this value is a server byte.
    private var lastAuthFailureHeaderCode: String?

    private func takeLastAuthFailureHeaderCode() -> String? {
        defer { lastAuthFailureHeaderCode = nil }
        return lastAuthFailureHeaderCode
    }

    /// Status is read BEFORE the body is parsed.
    ///
    /// The old order threw `.invalidResponse` from the parse guard, so a 502
    /// HTML proxy page and a 400 terminal envelope whose body a proxy had
    /// mangled were indistinguishable and the status was lost. Both still
    /// KEEP the session (no code ⇒ no terminal); the difference is that the
    /// trail can now name which one happened.
    private func postAuth(
        path: String,
        body: [String: Any]
    ) async throws -> (json: [String: Any], status: Int) {
        guard let url = URL(string: "\(supabaseURL)\(path)") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(projectAPIKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Hygiene, not correctness (see the property): bounds how long a
        // server byte from a PREVIOUS call sits in memory. Correct
        // attribution comes from the unconditional assignment below.
        lastAuthFailureHeaderCode = nil

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        let status = http.statusCode
        // Double-optional: `jsonObject(with:)` throws AND the cast can fail.
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if status >= 400 {
            let msg = json?["error_description"] as? String
                ?? json?["msg"] as? String
                ?? json?["message"] as? String
                ?? "Authentication failed (HTTP \(status))"
            // `value(forHTTPHeaderField:)` is case-insensitive (documented
            // since iOS 13), so the spelling below is a convention and not a
            // claim about the wire. NO casing has been observed: gh#234's
            // forensics are edge_logs rows, not response headers, and this
            // header is absent from Supabase's public error-code registry —
            // so the name may well never match anything. That is survivable
            // precisely because the header NEVER decides (see
            // `authHeaderRelation`); an absent header records `hdr=absent`
            // and changes nothing. Case-insensitivity is pinned by
            // `testTheErrorCodeHeaderIsFoundUnderAnyCasing`, which sends
            // `X-SB-Error-Code`.
            lastAuthFailureHeaderCode = http.value(forHTTPHeaderField: "x-sb-error-code")
            throw AuthError.authFailure(
                status: status,
                code: json?["error_code"] as? String,
                message: msg
            )
        }
        // `.invalidResponse` is now reserved for a 2xx whose body did not parse.
        guard let json else { throw AuthError.invalidResponse }
        return (json, status)
    }

    private func parseSessionResponse(_ json: [String: Any]) throws -> AuthSession {
        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int,
              let userDict = json["user"] as? [String: Any],
              let userId = userDict["id"] as? String
        else {
            throw AuthError.invalidResponse
        }
        let user = AuthUser(
            id: userId,
            email: userDict["email"] as? String,
            createdAt: userDict["created_at"] as? String
        )
        return AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            user: user
        )
    }

    enum AuthError: Error, LocalizedError {
        case invalidURL
        case invalidResponse
        /// A local give-up with nothing to classify — "Not signed in", a URL
        /// that would not build, a non-auth REST call that failed. Left
        /// byte-identical so the 13 existing construction sites need not
        /// invent an HTTP status; the first `status: 400` typed there by
        /// reflex would hand the classifier a fake terminal.
        case serverError(String)
        /// The auth server answered with a status. Thrown from exactly ONE
        /// site — the `status >= 400` branch of `postAuth` — and the only
        /// error the refresh classifier will act on.
        case authFailure(status: Int, code: String?, message: String)

        /// `authFailure` returns the message ALONE. Status and code are
        /// machine fields for the classifier and the trail; concatenating
        /// them here would change what the user reads, because this string is
        /// rendered verbatim.
        ///
        /// The count, checked rather than remembered: THREE sites in
        /// `AccountView` render an `AuthError`'s `errorDescription` — the
        /// sign-in error row (`authService.errorMessage`, fed by the Apple
        /// and Google catches above) and the two URL buttons, which catch
        /// `.serverError`/`.invalidURL` out of `generatePermanentMCPURL()`
        /// and `generateSnapshotURL()`. An `.authFailure` specifically can
        /// reach only the first, since `postAuth` is its one thrower and the
        /// refresh catch deliberately does not set `errorMessage`.
        /// (An earlier version of this line said "four sign-in error
        /// surfaces". There are not four, and two of the three are not
        /// sign-in surfaces.)
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .invalidResponse: return "Invalid response"
            case .serverError(let msg): return msg
            case .authFailure(_, _, let message): return message
            }
        }
    }
}

// MARK: - ASWebAuthenticationSession Presentation

private final class GoogleSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    static let shared = GoogleSignInPresenter()
    var currentSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow })
        else {
            return ASPresentationAnchor()
        }
        return window
    }
}
