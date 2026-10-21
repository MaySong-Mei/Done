//
//  SupabaseRealtimeDoorbell.swift
//  Done
//
//  The doorbell half of decision D1 in Docs/sync/00-realtime-sync-design.md:
//  one PRIVATE Realtime channel per signed-in user, carrying only locators
//  (`{table, id, seq, device_id, deleted}`) that the sync engine turns into
//  a cursor pull. Nothing that arrives here is the truth. A missed message
//  costs nothing, because the next pull reads from the cursor regardless —
//  so this class is allowed to be simple: connect, join, forward, reconnect.
//
//  Raw `URLSessionWebSocketTask` + Phoenix protocol v1.0.0; no SDK, the
//  same posture as `SupabaseREST` and `AuthService`. Wire shapes and the
//  error table follow Docs/sync/01-realtime-protocol-notes.md. Where those
//  notes mark something "未载明" the code does not depend on it.
//
//  What is deliberately NOT here: coalescing, pulling, applying, echo
//  filtering by device_id. Those belong to the engine that owns the cursor.
//

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Realtime"
)

// MARK: - Transport seam

/// What the doorbell needs from a websocket. `URLSessionRealtimeSocket` is
/// the production conformance; tests hand in a scripted fake, which is the
/// only way the join / heartbeat / reconnect behaviour can be pinned
/// without a server.
protocol RealtimeSocket: AnyObject {
    func send(text: String) async throws
    /// The next text frame. Throws once the connection is closed or lost.
    func receiveText() async throws -> String
    func close()
}

final class URLSessionRealtimeSocket: RealtimeSocket {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data(let data):
                // vsn=1.0.0 is text-only. A binary frame is a protocol
                // surprise; decode it as UTF-8 if it is one, else skip it.
                if let text = String(data: data, encoding: .utf8) { return text }
            @unknown default:
                continue
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Locator

/// The hint a database trigger broadcasts (migration 015): the table and
/// the highest `seq` one statement wrote. Never a row, never an id — the
/// engine pulls `> cursor` through RLS, so the hint only says "ring".
nonisolated struct RealtimeChange: Equatable, Sendable {
    let table: String
    let seq: Int64

    /// Fails closed: a hint without `table` or a numeric `seq` is not
    /// something the engine could act on, so it is dropped rather than
    /// delivered half-formed.
    init?(payload: [String: Any]) {
        guard let table = payload["table"] as? String,
              let seq = payload["seq"] as? NSNumber
        else { return nil }
        self.table = table
        self.seq = seq.int64Value
    }
}

// MARK: - Wire (pure)

/// Phoenix v1.0.0 frames exactly as the protocol notes record them. Pure —
/// no I/O, no state — so every shape is pinned by a test that needs no
/// socket.
nonisolated enum RealtimeWire {
    static let protocolVersion = "1.0.0"
    /// Heartbeats go to the `phoenix` topic, not the channel's.
    static let heartbeatTopic = "phoenix"
    /// The `event` argument migration 015 passes to `realtime.send`.
    static let changeEvent = "change"

    static func socketURL(projectURL: String, apiKey: String) -> URL? {
        guard var components = URLComponents(string: projectURL) else { return nil }
        components.scheme = "wss"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "vsn", value: protocolVersion),
        ]
        return components.url
    }

    /// `realtime:user:<uid>` — the topic migration 015's trigger sends to
    /// and the `realtime.messages` policy lets exactly that user read.
    static func topic(userId: String) -> String {
        "realtime:user:\(userId)"
    }

    /// `access_token` MUST be the user's JWT. The publishable key only
    /// identifies the project in the URL; the server silently ignores
    /// `sb_*` tokens here, and a private channel then refuses the join.
    static func joinFrame(topic: String, ref: String, accessToken: String) -> String {
        encode([
            "topic": topic,
            "event": "phx_join",
            "ref": ref,
            "join_ref": ref,
            "payload": [
                "config": [
                    "broadcast": ["ack": false, "self": false],
                    "presence": ["enabled": false],
                    "postgres_changes": [] as [Any],
                    "private": true,
                ] as [String: Any],
                "access_token": accessToken,
            ] as [String: Any],
        ])
    }

    static func heartbeatFrame(ref: String) -> String {
        encode([
            "topic": heartbeatTopic,
            "event": "heartbeat",
            "ref": ref,
            "payload": [:] as [String: Any],
        ])
    }

    /// In-band JWT rotation on an open channel. No reply on success; on
    /// failure the server sends a `system` error and closes the channel.
    static func accessTokenFrame(topic: String, ref: String, joinRef: String, accessToken: String) -> String {
        encode([
            "topic": topic,
            "event": "access_token",
            "ref": ref,
            "join_ref": joinRef,
            "payload": ["access_token": accessToken],
        ])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    enum ServerMessage: Equatable {
        /// `phx_reply`. `reason` is `"<ErrorCode>: <message>"` on error.
        case reply(ref: String?, ok: Bool, reason: String?)
        /// A `broadcast` whose inner event is `change` with a valid locator.
        case change(RealtimeChange)
        /// Any other `broadcast` (not ours; ignored).
        case broadcast(event: String)
        /// `system`. Channel-level errors are always followed by `phx_close`.
        case system(ok: Bool, message: String)
        case close
        case error
        case unknown(event: String)
    }

    static func decode(_ text: String) -> ServerMessage? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String
        else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch event {
        case "phx_reply":
            let status = payload["status"] as? String
            let response = payload["response"] as? [String: Any]
            return .reply(ref: object["ref"] as? String,
                          ok: status == "ok",
                          reason: response?["reason"] as? String)
        case "broadcast":
            let inner = payload["event"] as? String ?? ""
            if inner == changeEvent,
               let change = RealtimeChange(payload: payload["payload"] as? [String: Any] ?? [:]) {
                return .change(change)
            }
            return .broadcast(event: inner)
        case "system":
            return .system(ok: (payload["status"] as? String) == "ok",
                           message: payload["message"] as? String ?? "")
        case "phx_close":
            return .close
        case "phx_error":
            return .error
        default:
            return .unknown(event: event)
        }
    }
}

// MARK: - Policy (pure)

/// The documented error table, as decisions. Same red line as the auth
/// refresh classifier (gh#234): the DEFAULT is to keep trying with backoff.
/// Giving up is a positive allowlist of codes the docs say "do not retry";
/// an unknown code never signs the doorbell off.
nonisolated enum RealtimeJoinPolicy {
    enum Action: Equatable {
        case refreshTokenAndRejoin
        case backoff
        case giveUp
    }

    static func action(forJoinReason reason: String?) -> Action {
        let code = reason?
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch code {
        case "InvalidJWTExpiration":
            return .refreshTokenAndRejoin
        case "MalformedJWT", "JwtSignatureError", "Unauthorized",
             "TopicNameRequired", "TenantNotFound",
             "RealtimeDisabledForTenant", "RealtimeDisabledForConfiguration":
            return .giveUp
        default:
            // Rate limit, database, RealtimeRestarting, and anything the
            // docs have not named.
            return .backoff
        }
    }

    /// Channel-level `system` errors are matched on `message`, not a code.
    static func action(forSystemErrorMessage message: String) -> Action {
        if message.localizedCaseInsensitiveContains("token has expired") {
            return .refreshTokenAndRejoin
        }
        if message.localizedCaseInsensitiveContains("required in jwt") {
            return .giveUp
        }
        return .backoff
    }

    /// The JS SDK's ladder, capped at its last rung.
    static let backoffDelays: [TimeInterval] = [1, 2, 5, 10]

    static func backoffDelay(attempt: Int) -> TimeInterval {
        backoffDelays[min(max(attempt, 0), backoffDelays.count - 1)]
    }
}

// MARK: - Doorbell

@MainActor
final class SupabaseRealtimeDoorbell {
    struct Credentials: Equatable {
        let userId: String
        let accessToken: String
    }

    enum State: Equatable {
        /// Not running, or running with no session to join as.
        case idle
        case connecting
        case joined
        case backoff(attempt: Int, delay: TimeInterval)
        /// A documented do-not-retry condition. `start()` is the only exit.
        case stopped(reason: String)
    }

    struct Dependencies {
        var socketFactory: @MainActor (URL) -> RealtimeSocket
        var credentials: @MainActor () -> Credentials?
        /// Asked once per expiry before rejoining. Production: the
        /// `AuthService` force refresh, whose terminal classification
        /// (gh#234) is what eventually makes `credentials()` return nil.
        var refreshAccessToken: @MainActor () async -> Void
        var sleep: @MainActor (TimeInterval) async throws -> Void
        var heartbeatInterval: TimeInterval
        /// Asked before every connection attempt, before a socket exists.
        /// A throw is "no network": the loop backs off as it would after a
        /// lost socket and asks again on the next attempt. Production wires
        /// the harness's offline switch here (DEBUG only); the default
        /// never throws.
        var preflight: @MainActor () throws -> Void = {}

        /// Under the documented 25 s connection timeout, with margin for a
        /// late timer on a busy main thread.
        static let defaultHeartbeatInterval: TimeInterval = 20

        static func live(authService: AuthService) -> Dependencies {
            Dependencies(
                socketFactory: { URLSessionRealtimeSocket(url: $0) },
                credentials: { [weak authService] in
                    guard let session = authService?.session else { return nil }
                    return Credentials(userId: session.user.id, accessToken: session.accessToken)
                },
                refreshAccessToken: { [weak authService] in
                    await authService?.forceRefreshToken()
                },
                sleep: { try await Task.sleep(for: .seconds($0)) },
                heartbeatInterval: defaultHeartbeatInterval,
                preflight: {
                    #if DEBUG
                    try SyncOfflineSwitch.checkOnline()
                    #endif
                }
            )
        }
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Every locator the channel delivers, including this device's own
    /// echoes — the engine filters by `deviceId`.
    var onChange: ((RealtimeChange) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let socketURL: URL
    private let deps: Dependencies
    private var loop: Task<Void, Never>?
    private var socket: RealtimeSocket?
    private var nextRef = 0
    private var joinRef: String?
    private var joinedTopic: String?
    private var joinedToken: String?

    init(socketURL: URL, dependencies: Dependencies) {
        self.socketURL = socketURL
        self.deps = dependencies
    }

    convenience init?(projectURL: String = SupabaseSyncConfig.url,
                      apiKey: String = SupabaseSyncConfig.publishableKey,
                      authService: AuthService) {
        guard let url = RealtimeWire.socketURL(projectURL: projectURL, apiKey: apiKey) else { return nil }
        self.init(socketURL: url, dependencies: .live(authService: authService))
    }

    var isRunning: Bool { loop != nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.close()
        socket = nil
        joinRef = nil
        joinedTopic = nil
        joinedToken = nil
        state = .idle
    }

    /// Call whenever the auth session changes. A rotated token on the same
    /// user is handed to the open channel in band (no rejoin); a different
    /// user, or no session, restarts the loop so it joins as whoever is
    /// signed in now — or parks idle.
    func credentialsDidChange() {
        let fresh = deps.credentials()
        if let fresh, let socket, state == .joined,
           let joinedTopic, joinedTopic == RealtimeWire.topic(userId: fresh.userId) {
            if fresh.accessToken != joinedToken {
                Task { try? await self.pushAccessToken(fresh.accessToken, over: socket) }
            }
            return
        }
        let wasRunning = loop != nil
        stop()
        if wasRunning || fresh != nil { start() }
    }

    // MARK: Loop

    private enum Outcome {
        /// Joined, then the connection went away: not our fault, retry soon.
        case lostAfterJoin
        case refreshTokenAndRejoin
        case giveUp(reason: String)
        case backoff
    }

    private func run() async {
        var attempt = 0
        var refreshedThisCycle = false
        while !Task.isCancelled {
            guard let credentials = deps.credentials() else {
                // No session: nothing to join as. `credentialsDidChange()`
                // restarts us on sign-in.
                state = .idle
                loop = nil
                return
            }
            state = .connecting
            let (outcome, joined) = await connectAndServe(credentials)
            if Task.isCancelled { return }
            if joined {
                // A successful join ends the cycle: the next expiry — hours
                // later — gets its own refresh, and the ladder restarts.
                attempt = 0
                refreshedThisCycle = false
            }

            switch outcome {
            case .lostAfterJoin:
                break
            case .refreshTokenAndRejoin:
                if !refreshedThisCycle {
                    refreshedThisCycle = true
                    await deps.refreshAccessToken()
                    continue
                }
                // The refresh did not help (or the session is gone): fall
                // through to backoff instead of a tight refresh loop.
            case .giveUp(let reason):
                logger.error("Realtime: giving up — \(reason, privacy: .public)")
                state = .stopped(reason: reason)
                loop = nil
                return
            case .backoff:
                break
            }

            let delay = RealtimeJoinPolicy.backoffDelay(attempt: attempt)
            state = .backoff(attempt: attempt, delay: delay)
            attempt += 1
            do {
                try await deps.sleep(delay)
            } catch {
                return  // cancelled
            }
        }
    }

    private func allocateRef() -> String {
        nextRef += 1
        return String(nextRef)
    }

    private func pushAccessToken(_ token: String, over socket: RealtimeSocket) async throws {
        guard let joinRef, let joinedTopic else { return }
        try await socket.send(text: RealtimeWire.accessTokenFrame(
            topic: joinedTopic, ref: allocateRef(), joinRef: joinRef, accessToken: token
        ))
        joinedToken = token
    }

    /// Returns the outcome and whether the channel was ever joined on this
    /// connection — the loop's cycle boundary.
    private func connectAndServe(_ credentials: Credentials) async -> (Outcome, joined: Bool) {
        do {
            try deps.preflight()
        } catch {
            logger.notice("Realtime: not connecting — \(String(describing: error), privacy: .public)")
            return (.backoff, false)
        }
        let socket = deps.socketFactory(socketURL)
        self.socket = socket
        defer {
            socket.close()
            if self.socket === socket { self.socket = nil }
        }

        let topic = RealtimeWire.topic(userId: credentials.userId)
        let ref = allocateRef()
        joinRef = ref
        joinedTopic = topic
        joinedToken = credentials.accessToken

        do {
            try await socket.send(text: RealtimeWire.joinFrame(
                topic: topic, ref: ref, accessToken: credentials.accessToken
            ))
        } catch {
            return (.backoff, false)
        }

        // Heartbeat rides its own task so a slow receive never starves it.
        // It also carries the proactive token handoff: if the session
        // rotated since the join, the channel learns before the old JWT
        // expires and disconnects us.
        let heartbeat = Task { [deps] in
            while !Task.isCancelled {
                try await deps.sleep(deps.heartbeatInterval)
                try await socket.send(text: RealtimeWire.heartbeatFrame(ref: self.allocateRef()))
                if let fresh = deps.credentials()?.accessToken, fresh != self.joinedToken {
                    try await self.pushAccessToken(fresh, over: socket)
                }
            }
        }
        defer { heartbeat.cancel() }

        var joined = false
        var lastSystemError: String?
        do {
            while !Task.isCancelled {
                let text = try await socket.receiveText()
                guard let message = RealtimeWire.decode(text) else { continue }
                switch message {
                case .reply(let replyRef, let ok, let reason) where replyRef == ref:
                    if ok {
                        joined = true
                        state = .joined
                        logger.info("Realtime: joined \(topic, privacy: .public)")
                    } else {
                        logger.notice("Realtime: join refused — \(reason ?? "no reason", privacy: .public)")
                        switch RealtimeJoinPolicy.action(forJoinReason: reason) {
                        case .refreshTokenAndRejoin: return (.refreshTokenAndRejoin, joined)
                        case .giveUp: return (.giveUp(reason: reason ?? "join refused"), joined)
                        case .backoff: return (.backoff, joined)
                        }
                    }
                case .reply:
                    break  // heartbeat / access_token acks carry no decision
                case .change(let change):
                    onChange?(change)
                case .broadcast, .unknown:
                    break
                case .system(let ok, let systemMessage):
                    if !ok { lastSystemError = systemMessage }
                case .close, .error:
                    if let lastSystemError {
                        switch RealtimeJoinPolicy.action(forSystemErrorMessage: lastSystemError) {
                        case .refreshTokenAndRejoin: return (.refreshTokenAndRejoin, joined)
                        case .giveUp: return (.giveUp(reason: lastSystemError), joined)
                        case .backoff: return (.backoff, joined)
                        }
                    }
                    return (joined ? .lostAfterJoin : .backoff, joined)
                }
            }
            return (.backoff, joined)
        } catch {
            if Task.isCancelled { return (.backoff, joined) }
            return (joined ? .lostAfterJoin : .backoff, joined)
        }
    }
}
