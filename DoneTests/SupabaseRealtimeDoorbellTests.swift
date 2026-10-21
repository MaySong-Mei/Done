//
//  SupabaseRealtimeDoorbellTests.swift
//  DoneTests
//
//  Pins the doorbell's wire shapes and its reconnect decisions against
//  Docs/sync/01-realtime-protocol-notes.md, through a scripted socket. No
//  test reaches the network.
//
//  What a fake can and cannot prove: it proves the client SENDS what the
//  protocol says and REACTS to what the protocol says the server sends.
//  It cannot prove the server's actual reply strings — the notes mark the
//  RLS-refused `reason` and the heartbeat reply as 未载明, and no test
//  below depends on either.
//
//  The red line, same as gh#234's refresh classifier: an UNKNOWN join
//  error backs off and retries; only the documented do-not-retry codes
//  stop the loop. The mutation that flips that default is caught by
//  `testUnknownJoinErrorBacksOffRatherThanGivingUp`.
//

import XCTest
@testable import Done

// MARK: - Fakes

@MainActor
private final class FakeRealtimeSocket: RealtimeSocket {
    private(set) var sent: [String] = []
    private(set) var closed = false
    private var inbound: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    /// Thrown by every send: a connection that never came up (the TLS
    /// error a `wss` URL meets on a plain-HTTP port surfaces here).
    var sendError: Error?

    func send(text: String) async throws {
        if closed { throw URLError(.networkConnectionLost) }
        if let sendError { throw sendError }
        sent.append(text)
    }

    func receiveText() async throws -> String {
        if closed { throw URLError(.networkConnectionLost) }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: URLError(.cancelled))
        waiter = nil
    }

    // Test side.

    func deliver(_ text: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: text)
        } else {
            inbound.append(text)
        }
    }

    /// The server went away: the pending receive fails.
    func dropConnection() {
        closed = true
        waiter?.resume(throwing: URLError(.networkConnectionLost))
        waiter = nil
    }

    var sentFrames: [[String: Any]] { sent.compactMap(json) }
}

/// A sleep the test owns. Every request is recorded; nothing resumes until
/// the test says so, so a fake that "sleeps zero" cannot spin the heartbeat
/// loop hot and hide an interval bug. Cancellation is per sleeper, like
/// `Task.sleep`: cancelling the heartbeat task must not wake the loop's
/// backoff sleep (a blanket cancel-all did exactly that and killed the loop).
@MainActor
private final class ManualSleeper {
    private(set) var requested: [TimeInterval] = []
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]

    func sleep(_ interval: TimeInterval) async throws {
        requested.append(interval)
        // Like Task.sleep: an already-cancelled task never parks.
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// Wake every sleeper (a timer firing).
    func fire() {
        let waiters = pending.values
        pending = [:]
        waiters.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class Harness {
    let sleeper = ManualSleeper()
    private(set) var sockets: [FakeRealtimeSocket] = []
    private(set) var refreshCount = 0
    /// Handed to every socket the factory makes from now on.
    var socketSendError: Error?
    var credentials: SupabaseRealtimeDoorbell.Credentials? = .init(userId: "u-1", accessToken: "jwt-1")
    var states: [SupabaseRealtimeDoorbell.State] = []
    var changes: [RealtimeChange] = []
    /// The doorbell under test. Implicitly unwrapped only because the
    /// dependency closures reference the harness, which must exist first.
    private(set) var doorbell: SupabaseRealtimeDoorbell!
    let heartbeatInterval: TimeInterval

    /// The loop's backoff sleeps. The heartbeat task arms its own sleep the
    /// moment a socket opens (before the join reply), so the raw request
    /// list always interleaves heartbeat intervals with these.
    var backoffs: [TimeInterval] { sleeper.requested.filter { $0 != heartbeatInterval } }

    init(heartbeatInterval: TimeInterval = 20) {
        self.heartbeatInterval = heartbeatInterval
        let url = URL(string: "wss://stub.invalid/realtime/v1/websocket?apikey=k&vsn=1.0.0")!
        // Weak, not unowned: a test ends while the doorbell's loop task may
        // still be parked on a fake sleep or receive. A lingering task that
        // outlives its harness must park idle, never crash the test host.
        let deps = SupabaseRealtimeDoorbell.Dependencies(
            socketFactory: { [weak self] _ in
                let socket = FakeRealtimeSocket()
                socket.sendError = self?.socketSendError
                self?.sockets.append(socket)
                return socket
            },
            credentials: { [weak self] in self?.credentials },
            refreshAccessToken: { [weak self] in
                guard let self else { return }
                self.refreshCount += 1
                self.credentials = .init(userId: "u-1", accessToken: "jwt-\(self.refreshCount + 1)")
            },
            sleep: { [weak self] interval in
                guard let self else { throw CancellationError() }
                try await self.sleeper.sleep(interval)
            },
            heartbeatInterval: heartbeatInterval
        )
        doorbell = SupabaseRealtimeDoorbell(socketURL: url, dependencies: deps)
        doorbell.onStateChange = { [weak self] in self?.states.append($0) }
        doorbell.onChange = { [weak self] in self?.changes.append($0) }
    }

    deinit {
        // Stop the loop with the harness. `stop()` is main-actor work and a
        // deinit is not; hand it the doorbell reference, not `self`.
        let doorbell = self.doorbell
        Task { @MainActor in doorbell?.stop() }
    }

    var socket: FakeRealtimeSocket { sockets.last! }
    var joinFrame: [String: Any]? { socket.sentFrames.first }
    var joinRef: String { joinFrame?["ref"] as? String ?? "" }

    func startAndJoin() async throws {
        doorbell.start()
        try await eventually("join frame sent") { self.sockets.count == 1 && self.socket.sent.count == 1 }
        socket.deliver(Server.replyOK(ref: joinRef, topic: "realtime:user:u-1"))
        try await eventually("joined") { self.doorbell.state == .joined }
    }
}

private enum Server {
    static func replyOK(ref: String, topic: String) -> String {
        #"{"topic":"\#(topic)","event":"phx_reply","ref":"\#(ref)","payload":{"status":"ok","response":{"postgres_changes":[]}}}"#
    }
    static func replyError(ref: String, reason: String) -> String {
        #"{"topic":"realtime:user:u-1","event":"phx_reply","ref":"\#(ref)","payload":{"status":"error","response":{"reason":"\#(reason)"}}}"#
    }
    static func change(table: String, seq: Int, withMeta: Bool = true) -> String {
        let meta = withMeta ? #""meta":{"id":"006554ce-0000-0000-0000-000000000000","replayed":false},"# : ""
        return #"{"topic":"realtime:user:u-1","event":"broadcast","ref":null,"payload":{"event":"change","type":"broadcast",\#(meta)"payload":{"table":"\#(table)","seq":\#(seq)}}}"#
    }
    static func otherBroadcast() -> String {
        #"{"topic":"realtime:user:u-1","event":"broadcast","ref":null,"payload":{"event":"message","type":"broadcast","payload":{"hello":"world"}}}"#
    }
    static func systemError(_ message: String) -> String {
        #"{"topic":"realtime:user:u-1","event":"system","ref":null,"payload":{"message":"\#(message)","status":"error","extension":"system","channel":"realtime:user:u-1"}}"#
    }
    static func heartbeatReply(ref: String) -> String {
        #"{"topic":"phoenix","event":"phx_reply","ref":"\#(ref)","payload":{"status":"ok","response":{}}}"#
    }
    static let close = #"{"topic":"realtime:user:u-1","event":"phx_close","ref":"1","join_ref":"1","payload":{}}"#
    static let error = #"{"topic":"realtime:user:u-1","event":"phx_error","ref":"1","join_ref":"1","payload":{}}"#
}

private func json(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private struct EventuallyTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for: \(what)" }
}

@MainActor
private func eventually(_ what: String, timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw EventuallyTimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Wire (pure)

@MainActor
final class RealtimeWireTests: XCTestCase {
    func testSocketURLCarriesAPIKeyAndProtocolVersion() {
        let url = RealtimeWire.socketURL(projectURL: "https://abc.supabase.co", apiKey: "sb_publishable_x")
        XCTAssertEqual(url?.absoluteString, "wss://abc.supabase.co/realtime/v1/websocket?apikey=sb_publishable_x&vsn=1.0.0")
    }

    /// QA S1: the local stack is plain HTTP; `wss` there fails every
    /// attempt with a TLS error. The scheme follows the project URL's.
    func testSocketSchemeFollowsTheProjectURL_killsAlwaysWss() {
        let local = RealtimeWire.socketURL(projectURL: "http://127.0.0.1:54321", apiKey: "k")
        XCTAssertEqual(local?.absoluteString, "ws://127.0.0.1:54321/realtime/v1/websocket?apikey=k&vsn=1.0.0")
        let staging = RealtimeWire.socketURL(projectURL: "https://staging.example.co", apiKey: "k")
        XCTAssertEqual(staging?.scheme, "wss")
    }

    func testJoinFrameIsAPrivateChannelJoinCarryingTheUserJWT() throws {
        let frame = try XCTUnwrap(json(RealtimeWire.joinFrame(topic: "realtime:user:u-1", ref: "7", accessToken: "jwt")))
        XCTAssertEqual(frame["event"] as? String, "phx_join")
        XCTAssertEqual(frame["topic"] as? String, "realtime:user:u-1")
        XCTAssertEqual(frame["ref"] as? String, "7")
        XCTAssertEqual(frame["join_ref"] as? String, "7", "join_ref is the join's own ref")
        let payload = try XCTUnwrap(frame["payload"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "jwt")
        let config = try XCTUnwrap(payload["config"] as? [String: Any])
        XCTAssertEqual(config["private"] as? Bool, true, "a DB broadcast only reaches private channels")
        XCTAssertEqual((config["postgres_changes"] as? [Any])?.count, 0)
        XCTAssertEqual((config["presence"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((config["broadcast"] as? [String: Any])?["self"] as? Bool, false)
    }

    func testHeartbeatGoesToThePhoenixTopicNotTheChannel() throws {
        let frame = try XCTUnwrap(json(RealtimeWire.heartbeatFrame(ref: "3")))
        XCTAssertEqual(frame["topic"] as? String, "phoenix")
        XCTAssertEqual(frame["event"] as? String, "heartbeat")
        XCTAssertEqual(frame["ref"] as? String, "3")
        XCTAssertNil(frame["join_ref"])
        XCTAssertEqual((frame["payload"] as? [String: Any])?.isEmpty, true)
    }

    func testAccessTokenFrameNamesTheJoinItRefreshes() throws {
        let frame = try XCTUnwrap(json(RealtimeWire.accessTokenFrame(
            topic: "realtime:user:u-1", ref: "9", joinRef: "1", accessToken: "jwt-2")))
        XCTAssertEqual(frame["event"] as? String, "access_token")
        XCTAssertEqual(frame["join_ref"] as? String, "1")
        XCTAssertEqual((frame["payload"] as? [String: Any])?["access_token"] as? String, "jwt-2")
    }

    func testDecodeChangeHintWithAndWithoutMeta() {
        let withMeta = RealtimeWire.decode(Server.change(table: "events", seq: 42))
        let noMeta = RealtimeWire.decode(Server.change(table: "event_logs", seq: 43, withMeta: false))
        guard case .change(let a)? = withMeta, case .change(let b)? = noMeta else {
            return XCTFail("both should decode as change: \(String(describing: withMeta)) / \(String(describing: noMeta))")
        }
        XCTAssertEqual(a, RealtimeChange(payload: ["table": "events", "seq": 42]))
        XCTAssertEqual(b.table, "event_logs"); XCTAssertEqual(b.seq, 43)
    }

    func testHintWithoutSeqIsNotAChange() {
        let text = #"{"topic":"realtime:user:u-1","event":"broadcast","payload":{"event":"change","type":"broadcast","payload":{"table":"events"}}}"#
        XCTAssertEqual(RealtimeWire.decode(text), .broadcast(event: "change"),
                       "a half-formed locator is dropped, not delivered as a change")
    }

    func testDecodeReplyAndSystemAndCloseFrames() {
        XCTAssertEqual(RealtimeWire.decode(Server.replyOK(ref: "1", topic: "t")), .reply(ref: "1", ok: true, reason: nil))
        XCTAssertEqual(RealtimeWire.decode(Server.replyError(ref: "1", reason: "Unauthorized: nope")),
                       .reply(ref: "1", ok: false, reason: "Unauthorized: nope"))
        XCTAssertEqual(RealtimeWire.decode(Server.systemError("Token has expired")), .system(ok: false, message: "Token has expired"))
        XCTAssertEqual(RealtimeWire.decode(Server.close), .close)
        XCTAssertEqual(RealtimeWire.decode(Server.error), .error)
        XCTAssertNil(RealtimeWire.decode("not json"))
    }
}

// MARK: - Policy (pure)

@MainActor
final class RealtimeJoinPolicyTests: XCTestCase {
    func testDocumentedCodesMapToTheirDocumentedAction() {
        XCTAssertEqual(RealtimeJoinPolicy.action(forJoinReason: "InvalidJWTExpiration: Token has expired 300 seconds ago"), .refreshTokenAndRejoin)
        for code in ["MalformedJWT", "JwtSignatureError", "Unauthorized", "TopicNameRequired",
                     "TenantNotFound", "RealtimeDisabledForTenant", "RealtimeDisabledForConfiguration"] {
            XCTAssertEqual(RealtimeJoinPolicy.action(forJoinReason: "\(code): x"), .giveUp, code)
        }
        for code in ["ConnectionRateLimitReached", "ClientJoinRateLimitReached", "ChannelRateLimitReached",
                     "InitializingProjectConnection", "DatabaseLackOfConnections", "RealtimeRestarting"] {
            XCTAssertEqual(RealtimeJoinPolicy.action(forJoinReason: "\(code): x"), .backoff, code)
        }
    }

    func testUnknownJoinErrorBacksOffRatherThanGivingUp() {
        // The red line. A code the docs do not name — or no reason at all —
        // must never sign the doorbell off; the loop keeps trying with backoff.
        XCTAssertEqual(RealtimeJoinPolicy.action(forJoinReason: "SomethingNew: ?"), .backoff)
        XCTAssertEqual(RealtimeJoinPolicy.action(forJoinReason: "Unknown Error on Channel"), .backoff)
        XCTAssertEqual(RealtimeJoinPolicy.action(forJoinReason: nil), .backoff)
    }

    func testSystemErrorMessagesAreMatchedOnText() {
        XCTAssertEqual(RealtimeJoinPolicy.action(forSystemErrorMessage: "Token has expired"), .refreshTokenAndRejoin)
        XCTAssertEqual(RealtimeJoinPolicy.action(forSystemErrorMessage: "Fields `role` and `exp` are required in JWT"), .giveUp)
        XCTAssertEqual(RealtimeJoinPolicy.action(forSystemErrorMessage: "Too many messages per second"), .backoff)
        XCTAssertEqual(RealtimeJoinPolicy.action(forSystemErrorMessage: "Server requested disconnect"), .backoff)
    }

    func testBackoffLadderIsCappedAtItsLastRung() {
        XCTAssertEqual((0..<6).map(RealtimeJoinPolicy.backoffDelay(attempt:)), [1, 2, 5, 10, 10, 10])
        XCTAssertEqual(RealtimeJoinPolicy.backoffDelay(attempt: -1), 1)
    }

    func testDefaultHeartbeatIsUnderTheDocumentedConnectionTimeout() {
        // The protocol notes: "at least every 25 seconds to avoid a connection
        // timeout". The default must sit under that with room for a late
        // timer; the exact value is the implementation's to choose.
        let documentedTimeout: TimeInterval = 25
        XCTAssertLessThan(SupabaseRealtimeDoorbell.Dependencies.defaultHeartbeatInterval, documentedTimeout)
        XCTAssertGreaterThan(SupabaseRealtimeDoorbell.Dependencies.defaultHeartbeatInterval, 5,
                             "a heartbeat every few seconds is a battery bug, not safety")
    }
}

// MARK: - Doorbell (scripted socket)

@MainActor
final class SupabaseRealtimeDoorbellTests: XCTestCase {
    func testStartJoinsThePrivateUserChannelWithTheSessionJWT() async throws {
        let h = Harness()
        try await h.startAndJoin()
        let join = try XCTUnwrap(h.joinFrame)
        XCTAssertEqual(join["event"] as? String, "phx_join")
        XCTAssertEqual(join["topic"] as? String, "realtime:user:u-1")
        let payload = try XCTUnwrap(join["payload"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "jwt-1")
        XCTAssertEqual((payload["config"] as? [String: Any])?["private"] as? Bool, true)
        XCTAssertEqual(h.states, [.connecting, .joined])
    }

    /// QA S1: the doorbell failed 13 times in 100 s and the trail had no
    /// line for it. A connection that fails before the join is written to
    /// the trail with its code, once per attempt.
    func testAConnectionThatFailsBeforeTheJoinIsWrittenToTheTrail_killsNoTrailLine() async throws {
        let h = Harness()
        h.socketSendError = URLError(.secureConnectionFailed)
        let needle = "sync.doorbell.connect_failed code=url-1200"
        let before = DiagnosticTrail.combinedText().components(separatedBy: needle).count - 1

        h.doorbell.start()
        try await eventually("backoff after the failed connection") { h.backoffs.count == 1 }

        let after = DiagnosticTrail.combinedText().components(separatedBy: needle).count - 1
        XCTAssertEqual(after - before, 1)
        XCTAssertEqual(h.doorbell.state, .backoff(attempt: 0, delay: 1))
    }

    func testNoSessionMeansIdleWithNoSocketAndNoRetry() async throws {
        let h = Harness()
        h.credentials = nil
        h.doorbell.start()
        try await eventually("loop parks") { !h.doorbell.isRunning }
        XCTAssertEqual(h.sockets.count, 0)
        XCTAssertEqual(h.sleeper.requested, [])
        XCTAssertEqual(h.doorbell.state, .idle)
    }

    func testHeartbeatIsSentOnThePhoenixTopicEveryInterval() async throws {
        let h = Harness(heartbeatInterval: 17)
        try await h.startAndJoin()
        try await eventually("first heartbeat armed") { h.sleeper.requested == [17] }
        h.sleeper.fire()
        try await eventually("heartbeat sent") { h.socket.sent.count == 2 }
        let hb = try XCTUnwrap(h.socket.sentFrames.last)
        XCTAssertEqual(hb["topic"] as? String, "phoenix")
        XCTAssertEqual(hb["event"] as? String, "heartbeat")
        XCTAssertNotEqual(hb["ref"] as? String, h.joinRef, "every frame gets a fresh ref")
        try await eventually("re-armed") { h.sleeper.requested == [17, 17] }
    }

    func testChangeHintsAreForwardedAndOtherBroadcastsAreNot() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.socket.deliver(Server.otherBroadcast())
        h.socket.deliver(Server.change(table: "events", seq: 101))
        h.socket.deliver(Server.change(table: "event_logs", seq: 102, withMeta: false))
        try await eventually("two changes") { h.changes.count == 2 }
        XCTAssertEqual(h.changes.map(\.table), ["events", "event_logs"])
        XCTAssertEqual(h.changes.map(\.seq), [101, 102])
        XCTAssertEqual(h.doorbell.state, .joined, "a stray broadcast does not disturb the channel")
    }

    func testExpiredJWTOnJoinRefreshesOnceAndRejoinsWithTheNewTokenWithoutBackoff() async throws {
        let h = Harness()
        h.doorbell.start()
        try await eventually("join sent") { h.sockets.count == 1 && h.socket.sent.count == 1 }
        h.socket.deliver(Server.replyError(ref: h.joinRef, reason: "InvalidJWTExpiration: Token has expired 300 seconds ago"))
        try await eventually("second socket joins") { h.sockets.count == 2 && h.socket.sent.count == 1 }
        XCTAssertEqual(h.refreshCount, 1)
        XCTAssertEqual(h.backoffs, [], "a refresh-and-rejoin is immediate, not a backoff")
        let payload = try XCTUnwrap(h.joinFrame?["payload"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "jwt-2", "the rejoin carries the refreshed token")
        XCTAssertTrue(h.sockets[0].closed, "the refused socket is closed, not leaked")
    }

    func testSecondConsecutiveExpiryBacksOffInsteadOfRefreshingAgain() async throws {
        let h = Harness()
        h.doorbell.start()
        try await eventually("join sent") { h.sockets.count == 1 && h.socket.sent.count == 1 }
        h.socket.deliver(Server.replyError(ref: h.joinRef, reason: "InvalidJWTExpiration: x"))
        try await eventually("rejoin") { h.sockets.count == 2 && h.socket.sent.count == 1 }
        h.socket.deliver(Server.replyError(ref: h.joinRef, reason: "InvalidJWTExpiration: x"))
        try await eventually("backoff") { h.backoffs == [1] }
        XCTAssertEqual(h.refreshCount, 1, "the refresh did not help; hammering it would be the gh#234 storm")
        XCTAssertEqual(h.doorbell.state, .backoff(attempt: 0, delay: 1))
    }

    func testDocumentedDoNotRetryCodeStopsTheLoop() async throws {
        let h = Harness()
        h.doorbell.start()
        try await eventually("join sent") { h.sockets.count == 1 && h.socket.sent.count == 1 }
        h.socket.deliver(Server.replyError(ref: h.joinRef, reason: "Unauthorized: no policy allows this topic"))
        try await eventually("stopped") { !h.doorbell.isRunning }
        XCTAssertEqual(h.doorbell.state, .stopped(reason: "Unauthorized: no policy allows this topic"))
        XCTAssertEqual(h.sockets.count, 1)
        XCTAssertEqual(h.refreshCount, 0)
        XCTAssertEqual(h.backoffs, [])
    }

    func testUnknownJoinErrorRetriesWithTheBackoffLadder() async throws {
        let h = Harness()
        h.doorbell.start()
        for (attempt, expected) in [1.0, 2.0, 5.0, 10.0, 10.0].enumerated() {
            try await eventually("join \(attempt) sent") { h.sockets.count == attempt + 1 && h.socket.sent.count == 1 }
            h.socket.deliver(Server.replyError(ref: h.joinRef, reason: "SomethingTheDocsDoNotName: ?"))
            try await eventually("backoff \(attempt)") { h.backoffs.count == attempt + 1 }
            XCTAssertEqual(h.backoffs.last, expected)
            XCTAssertEqual(h.doorbell.state, .backoff(attempt: attempt, delay: expected))
            h.sleeper.fire()
        }
        XCTAssertTrue(h.doorbell.isRunning, "an unknown code never signs the doorbell off")
    }

    func testTokenExpiredSystemErrorFollowedByCloseRefreshesAndRejoins() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.socket.deliver(Server.systemError("Token has expired"))
        h.socket.deliver(Server.close)
        try await eventually("rejoin on new socket") { h.sockets.count == 2 && h.socket.sent.count == 1 }
        XCTAssertEqual(h.refreshCount, 1)
        XCTAssertEqual(h.backoffs, [], "no backoff rung between expiry and rejoin")
        XCTAssertEqual((h.joinFrame?["payload"] as? [String: Any])?["access_token"] as? String, "jwt-2")
    }

    func testExpiryAfterASuccessfulJoinRefreshesAgainRatherThanBackingOff() async throws {
        // The "refresh once per cycle" guard must reset on a successful join:
        // a session that joined at 9:00 and expires at 10:00 is a new cycle,
        // not a second consecutive failure. Without the reset the second
        // expiry of the day would back off forever instead of refreshing.
        let h = Harness()
        try await h.startAndJoin()
        h.socket.deliver(Server.systemError("Token has expired"))
        h.socket.deliver(Server.close)
        try await eventually("first rejoin") { h.sockets.count == 2 && h.socket.sent.count == 1 }
        XCTAssertEqual(h.refreshCount, 1)
        h.socket.deliver(Server.replyOK(ref: h.joinRef, topic: "realtime:user:u-1"))
        try await eventually("joined again") { h.doorbell.state == .joined }

        h.socket.deliver(Server.systemError("Token has expired"))
        h.socket.deliver(Server.close)
        try await eventually("second rejoin") { h.sockets.count == 3 && h.socket.sent.count == 1 }
        XCTAssertEqual(h.refreshCount, 2, "a fresh cycle gets its own refresh")
        XCTAssertEqual(h.backoffs, [], "and no backoff rung was taken")
        XCTAssertEqual((h.joinFrame?["payload"] as? [String: Any])?["access_token"] as? String, "jwt-3")
    }

    func testConnectionLossAfterJoinReconnectsFromTheFirstRung() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.socket.dropConnection()
        try await eventually("backoff after loss") { h.doorbell.state == .backoff(attempt: 0, delay: 1) }
        h.sleeper.fire()
        try await eventually("reconnected") { h.sockets.count == 2 && h.socket.sent.count == 1 }
        h.socket.deliver(Server.replyOK(ref: h.joinRef, topic: "realtime:user:u-1"))
        try await eventually("joined again") { h.doorbell.state == .joined }
        XCTAssertEqual(h.states, [.connecting, .joined, .backoff(attempt: 0, delay: 1), .connecting, .joined])
    }

    func testPhxErrorAfterJoinAlsoReconnectsFromTheFirstRung() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.socket.deliver(Server.error)
        try await eventually("backoff") { h.doorbell.state == .backoff(attempt: 0, delay: 1) }
    }

    func testRotatedSessionIsHandedToTheOpenChannelWithoutRejoining() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.credentials = .init(userId: "u-1", accessToken: "jwt-rotated")
        h.doorbell.credentialsDidChange()
        try await eventually("access_token frame") { h.socket.sent.count == 2 }
        let frame = try XCTUnwrap(h.socket.sentFrames.last)
        XCTAssertEqual(frame["event"] as? String, "access_token")
        XCTAssertEqual(frame["join_ref"] as? String, h.joinRef, "the refresh names the join it belongs to")
        XCTAssertEqual((frame["payload"] as? [String: Any])?["access_token"] as? String, "jwt-rotated")
        XCTAssertEqual(h.sockets.count, 1, "no rejoin")
        XCTAssertEqual(h.doorbell.state, .joined)
        // And the heartbeat tick does not push it a second time.
        h.sleeper.fire()
        try await eventually("heartbeat") { h.socket.sent.count == 3 }
        XCTAssertEqual(h.socket.sentFrames.last?["event"] as? String, "heartbeat")
    }

    func testRotatedSessionIsPushedOnTheNextHeartbeatIfNobodyToldUs() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.credentials = .init(userId: "u-1", accessToken: "jwt-rotated")
        h.sleeper.fire()
        try await eventually("heartbeat + access_token") { h.socket.sent.count == 3 }
        XCTAssertEqual(h.socket.sentFrames.map { $0["event"] as? String }, ["phx_join", "heartbeat", "access_token"])
    }

    func testDifferentUserRestartsAsThatUser() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.credentials = .init(userId: "u-2", accessToken: "jwt-u2")
        h.doorbell.credentialsDidChange()
        try await eventually("new socket for u-2") { h.sockets.count == 2 && h.socket.sent.count == 1 }
        XCTAssertTrue(h.sockets[0].closed)
        XCTAssertEqual(h.joinFrame?["topic"] as? String, "realtime:user:u-2")
    }

    func testSignOutParksIdleAndSignInStartsAgain() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.credentials = nil
        h.doorbell.credentialsDidChange()
        try await eventually("parked") { !h.doorbell.isRunning && h.doorbell.state == .idle }
        XCTAssertTrue(h.sockets[0].closed)
        h.credentials = .init(userId: "u-1", accessToken: "jwt-9")
        h.doorbell.credentialsDidChange()
        try await eventually("rejoined") { h.sockets.count == 2 && h.socket.sent.count == 1 }
    }

    func testStopClosesTheSocketAndNothingIsSentAfterwards() async throws {
        let h = Harness()
        try await h.startAndJoin()
        h.doorbell.stop()
        XCTAssertTrue(h.socket.closed)
        XCTAssertEqual(h.doorbell.state, .idle)
        XCTAssertFalse(h.doorbell.isRunning)
        h.sleeper.fire()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(h.socket.sent.count, 1, "no heartbeat after stop")
        XCTAssertEqual(h.sockets.count, 1, "no reconnect after stop")
    }

    // MARK: Heartbeat replies (design §6.5 M5, sim QA round 2 #4)

    func testAJoinIsWrittenToTheTrail() async throws {
        let before = trailCount("sync.doorbell.joined")
        let h = Harness()
        try await h.startAndJoin()
        XCTAssertEqual(trailCount("sync.doorbell.joined") - before, 1)
    }

    /// A paused server keeps the socket open and answers nothing. One
    /// unanswered heartbeat is tolerated; the second in a row closes the
    /// socket and the loop reconnects from the first rung. The "heartbeat
    /// replies are not checked" mutant stays joined on the dead socket.
    func testTwoUnansweredHeartbeatsInARowReconnect_killsRepliesNotChecked() async throws {
        let h = Harness()
        try await h.startAndJoin()
        let before = trailCount("sync.doorbell.reconnect reason=heartbeat")

        h.sleeper.fire()
        try await eventually("heartbeat 1 sent") { h.socket.sent.count == 2 }
        try await eventually("re-armed") { h.sleeper.requested.count == 2 }
        h.sleeper.fire()
        try await eventually("heartbeat 2 sent") { h.socket.sent.count == 3 }
        try await eventually("re-armed") { h.sleeper.requested.count == 3 }
        XCTAssertEqual(h.doorbell.state, .joined, "one miss is not a loss")
        XCTAssertFalse(h.socket.closed)

        h.sleeper.fire()
        try await eventually("backoff after the second miss") { h.doorbell.state == .backoff(attempt: 0, delay: 1) }
        XCTAssertTrue(h.sockets[0].closed)
        XCTAssertEqual(trailCount("sync.doorbell.reconnect reason=heartbeat") - before, 1)
        h.sleeper.fire()
        try await eventually("reconnected") { h.sockets.count == 2 && h.socket.sent.count == 1 }
    }

    /// Positive control: every heartbeat answered — the channel stays on
    /// the same socket however many intervals pass.
    func testAnsweredHeartbeatsKeepTheChannel() async throws {
        let h = Harness()
        try await h.startAndJoin()
        for n in 1...4 {
            h.sleeper.fire()
            try await eventually("heartbeat \(n) sent") { h.socket.sent.count == n + 1 }
            let ref = try XCTUnwrap(h.socket.sentFrames.last?["ref"] as? String)
            h.socket.deliver(Server.heartbeatReply(ref: ref))
            try await eventually("re-armed \(n)") { h.sleeper.requested.count == n + 1 }
        }
        XCTAssertEqual(h.doorbell.state, .joined)
        XCTAssertEqual(h.sockets.count, 1)
        XCTAssertFalse(h.socket.closed)
    }
}

// MARK: - The doorbell inside the puller (sim QA round 2)

/// A puller over `SyncFakeServer` whose doorbell is the scripted one above,
/// plus a second engine that writes to the same server as another device.
@MainActor
private final class PullerRig {
    let uid = "66666666-6666-6666-6666-666666666666"
    let server: SyncFakeServer
    let h = Harness()
    let scheduler = SyncManualScheduler()
    let service: SupabaseSyncService
    let puller: SyncPuller
    private var suites: [String]
    private let shelfDirectory: URL
    private var other: (store: EventStore, service: SupabaseSyncService)?

    init(feedUnavailable: Bool = false) {
        server = SyncFakeServer(userId: uid)
        server.feedUnavailable = feedUnavailable
        let suite = "PullerRig-A-\(UUID().uuidString)"
        suites = [suite]
        let defaults = UserDefaults(suiteName: suite)!
        let store = EventStore(defaults: defaults, storage: TestStorage.reset(suite), seedsSampleDataIfEmpty: false)
        self.store = store
        service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: defaults, scheduler: scheduler)
        service.attachStores(eventStore: store, eventTypeStore: nil, skillStore: nil, preferenceStore: nil)
        shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PullerRig-\(UUID().uuidString)", isDirectory: true)
        puller = service.installInbound(shelf: ConflictShelf(directory: shelfDirectory), doorbell: h.doorbell)
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()
        puller.beginSession(autoPull: false)
    }

    /// Kept alive with the rig: the applier's target.
    let store: EventStore

    func tearDown() {
        puller.endSession()
        try? FileManager.default.removeItem(at: shelfDirectory)
        suites.forEach(TestStorage.tearDown)
    }

    /// The join frame the doorbell sent on its newest socket.
    var joinRef: String { h.joinRef }

    func deliverJoinReply(ok: Bool, reason: String = "") {
        if ok {
            h.socket.deliver(Server.replyOK(ref: h.joinRef, topic: "realtime:user:u-1"))
        } else {
            h.socket.deliver(Server.replyError(ref: h.joinRef, reason: reason))
        }
    }

    func waitForJoinSent(sockets: Int) async throws {
        try await eventually("join \(sockets) sent") { self.h.sockets.count == sockets && self.h.socket.sent.count >= 1 }
    }

    /// Another device creates an event and uploads it.
    @discardableResult
    func otherDeviceCreates(_ title: String) async -> Int64 {
        if other == nil {
            let suite = "PullerRig-B-\(UUID().uuidString)"
            suites.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            let store = EventStore(defaults: defaults, storage: TestStorage.reset(suite), seedsSampleDataIfEmpty: false)
            let service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: defaults, scheduler: SyncManualScheduler())
            service.attachStores(eventStore: store, eventTypeStore: nil, skillStore: nil, preferenceStore: nil)
            other = (store, service)
        }
        let (store, service) = other!
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let event = Event(title: title, timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))], createdAt: start)
        store.addCalendarEvent(event)
        await service.syncEvents(store.rawCalendarEvents, kind: "calendar")
        return server.seq(table: "events", key: event.id.uuidString) ?? 0
    }
}

private func trailCount(_ needle: String) -> Int {
    DiagnosticTrail.combinedText().components(separatedBy: needle).count - 1
}

@MainActor
final class SyncPullerDoorbellTests: XCTestCase {
    // MARK: Bug 1 — a doorbell that gave up before 015 comes back

    /// The 014 stack refuses the join as `Unauthorized`; the doorbell
    /// gives up and says so in the trail. 015 arrives; the foreground
    /// re-probe starts the doorbell again, at once — not at the next
    /// relaunch. The "re-probe does not restart" mutant leaves it stopped
    /// while the chain is still parked.
    func testTheForegroundReprobeRestartsADoorbellThatGaveUp_killsReprobeDoesNotRestart() async throws {
        let rig = PullerRig(feedUnavailable: true)
        defer { rig.tearDown() }
        let gaveUpBefore = trailCount("sync.doorbell.gave_up code=Unauthorized")
        try await rig.waitForJoinSent(sockets: 1)
        rig.deliverJoinReply(ok: false, reason: "Unauthorized: You do not have permissions to read from this Channel topic: user:x")
        try await eventually("gave up") { rig.h.doorbell.isStopped }
        XCTAssertEqual(trailCount("sync.doorbell.gave_up code=Unauthorized") - gaveUpBefore, 1, "giving up is in the trail")
        await rig.puller.pullToHead()
        XCTAssertTrue(rig.puller.feedUnavailable, "fixture: the probe found no feed")
        XCTAssertFalse(rig.h.doorbell.isRunning, "fixture: nothing has restarted it yet")

        rig.server.feedUnavailable = false
        rig.server.holdWhen = { verb, _ in verb == .pull }
        let restartsBefore = trailCount("sync.doorbell.restart reason=reprobe")
        rig.puller.foregroundDidReturn()

        XCTAssertTrue(rig.h.doorbell.isRunning, "the re-probe itself restarts the doorbell, before any chain reaches head")
        XCTAssertEqual(trailCount("sync.doorbell.restart reason=reprobe") - restartsBefore, 1)
        try await rig.waitForJoinSent(sockets: 2)
        rig.deliverJoinReply(ok: true)
        try await eventually("joined after 015") { rig.h.doorbell.state == .joined }

        rig.server.holdWhen = nil
        rig.server.releaseAll()
        await rig.puller.pullToHead()
        XCTAssertFalse(rig.puller.feedUnavailable)
    }

    /// The doorbell gives up AFTER the re-probe (it was still connecting
    /// when the user came back): the first chain to reach head with the
    /// feed back starts it. The "head does not restart" mutant leaves it
    /// stopped.
    func testTheFirstHeadAfterTheFeedReturnsRestartsADoorbellThatGaveUp_killsHeadDoesNotRestart() async throws {
        let rig = PullerRig(feedUnavailable: true)
        defer { rig.tearDown() }
        try await rig.waitForJoinSent(sockets: 1)
        await rig.puller.pullToHead()
        XCTAssertTrue(rig.puller.feedUnavailable, "fixture: the probe found no feed")

        rig.server.feedUnavailable = false
        rig.server.holdWhen = { verb, _ in verb == .pull }
        rig.puller.foregroundDidReturn()
        XCTAssertFalse(rig.h.doorbell.isStopped, "fixture: still connecting at the re-probe, nothing to restart")
        try await eventually("chain parked") { rig.server.heldCount == 1 }

        rig.deliverJoinReply(ok: false, reason: "Unauthorized: no policy")
        try await eventually("gave up") { rig.h.doorbell.isStopped }
        let restartsBefore = trailCount("sync.doorbell.restart reason=feed_back")

        rig.server.holdWhen = nil
        rig.server.releaseAll()
        await rig.puller.pullToHead()

        XCTAssertFalse(rig.puller.feedUnavailable)
        XCTAssertTrue(rig.h.doorbell.isRunning, "the feed is back at head: the doorbell is started again")
        XCTAssertEqual(trailCount("sync.doorbell.restart reason=feed_back") - restartsBefore, 1)
        try await rig.waitForJoinSent(sockets: 2)
    }

    /// Positive control: a session whose feed never went missing does not
    /// restart a doorbell at head — giving up stays giving up there.
    func testAHeadWithoutAMissingFeedLeavesAStoppedDoorbellAlone() async throws {
        let rig = PullerRig()
        defer { rig.tearDown() }
        try await rig.waitForJoinSent(sockets: 1)
        rig.deliverJoinReply(ok: false, reason: "TenantNotFound: x")
        try await eventually("gave up") { rig.h.doorbell.isStopped }
        await rig.puller.pullToHead()
        XCTAssertTrue(rig.h.doorbell.isStopped)
        XCTAssertEqual(rig.h.sockets.count, 1)
    }

    // MARK: #4 — a poll that finds what the doorbell did not ring

    private func joinedRig() async throws -> PullerRig {
        let rig = PullerRig()
        try await rig.waitForJoinSent(sockets: 1)
        rig.deliverJoinReply(ok: true)
        try await eventually("joined") { rig.h.doorbell.state == .joined }
        await rig.puller.pullToHead()
        return rig
    }

    /// The doorbell says joined, another device writes, no frame arrives:
    /// the poll applies the row, and once the grace period passes without
    /// a frame announcing it, one `sync.doorbell.missed` line. A second
    /// stall on the same connection writes no second line. The "missed is
    /// not recorded" mutant writes none.
    func testAPollThatAppliesAnUnannouncedRowWhileJoinedIsAMissedRing_killsMissedNotRecorded() async throws {
        let rig = try await joinedRig()
        defer { rig.tearDown() }
        let seq = await rig.otherDeviceCreates("written while the doorbell slept")
        XCTAssertGreaterThan(seq, 0, "fixture: the other device's write landed")
        let before = trailCount("sync.doorbell.missed ")
        let exactLine = "sync.doorbell.missed rows=1 max_seq=\(seq)"
        let exactBefore = trailCount(exactLine)

        await rig.puller.pullToHead(reason: "poll")
        XCTAssertEqual(trailCount("sync.doorbell.missed ") - before, 0, "not before the grace period")
        rig.scheduler.advance(by: SyncPuller.missedRingGrace)

        XCTAssertEqual(trailCount(exactLine) - exactBefore, 1, "the line names the rows and the highest seq")
        XCTAssertEqual(trailCount("sync.doorbell.missed ") - before, 1)

        await rig.otherDeviceCreates("and again")
        await rig.puller.pullToHead(reason: "poll")
        rig.scheduler.advance(by: SyncPuller.missedRingGrace)
        XCTAssertEqual(trailCount("sync.doorbell.missed ") - before, 1, "one line per joined connection")
    }

    /// Positive control: the frame arrives within the grace period (the
    /// ordinary race between the 60 s poll and a slow frame) — no line.
    func testAFrameWithinTheGracePeriodIsNoMissedRing() async throws {
        let rig = try await joinedRig()
        defer { rig.tearDown() }
        let seq = await rig.otherDeviceCreates("announced late")
        let before = trailCount("sync.doorbell.missed ")
        await rig.puller.pullToHead(reason: "poll")
        rig.h.socket.deliver(Server.change(table: "events", seq: Int(seq)))
        try await eventually("frame seen") { rig.puller.lastAnnouncedSeq >= seq }
        rig.scheduler.advance(by: SyncPuller.missedRingGrace)
        XCTAssertEqual(trailCount("sync.doorbell.missed ") - before, 0)
    }

    /// Positive control: a doorbell that is not joined has nothing to miss.
    func testAPollWhileTheDoorbellIsNotJoinedIsNoMissedRing() async throws {
        let rig = PullerRig()
        defer { rig.tearDown() }
        try await rig.waitForJoinSent(sockets: 1)
        await rig.otherDeviceCreates("while connecting")
        let before = trailCount("sync.doorbell.missed ")
        await rig.puller.pullToHead(reason: "poll")
        rig.scheduler.advance(by: SyncPuller.missedRingGrace)
        XCTAssertEqual(trailCount("sync.doorbell.missed ") - before, 0)
    }

    func testTheGiveUpTrailCodeIsTheReasonsLeadingCode() {
        XCTAssertEqual(RealtimeJoinPolicy.trailCode(ofReason: "Unauthorized: x: y"), "Unauthorized")
        XCTAssertEqual(RealtimeJoinPolicy.trailCode(ofReason: "sub claim required in JWT"), "system")
        XCTAssertEqual(RealtimeJoinPolicy.trailCode(ofReason: nil), "system")
    }
}
