//
//  SyncHeadGate.swift
//  Done
//
//  The domino's ordering rule (design §6 domino 段, §10.5): the push runs
//  only after this session has pulled to head, and each tick pulls first.
//  Without it a device coming to the foreground pushes the rows it holds
//  (another device's push, with that device's anchor) before it has pulled
//  that device's result — same instant, different bytes — and every parked
//  todo becomes a conflict row (one shelf line per todo per foreground).
//
//  The engine (the puller, in `Done/Services/Sync/`) owns the answer; this
//  file only defines the question and the default flag it sets. The app
//  hands the domino one of these; a test hands in its own.
//
//  CONTRACT for the engine that drives `SyncHeadFlag`, in this order:
//
//    1. Set `engineRunning = true` when it starts pulling for a session,
//       BEFORE reporting any chain. The flag forgets any head it was told
//       about while off (false → true zeroes `isAtHead`), so a new session
//       never inherits the previous one's verdict.
//    2. Call `chainStarted()` at the start of EVERY pull chain (doorbell,
//       foreground, poll, `.joined`) and `chainEnded(atHead:)` at its end
//       with I1's verdict. Between the two the session is off head and a
//       request waits — this is how an in-flight chain is visible to the
//       gate when no `pullNow` hook is set ("若有在途拉取链…先等它跑完").
//    3. Optionally set `pullNow` so every request pulls first.
//    4. Set `engineRunning = false` on sign-out and when the feed is
//       unavailable (design §7 Phase 1 (7)). This DRAINS any waiting work at
//       once — on purpose: with no engine the domino behaves as the pre-sync
//       app did, so the push that was waiting for head runs at that moment
//       (the one time it runs on a sign-out / feed-down transition).
//
//  The engine's own I1 flag (`SupabaseSyncService.inboundAtHead`, read by
//  the flush gate) and this flag describe the same fact; the engine is the
//  single writer of both and must keep them in step (reported here as the
//  seam the engine line closes).
//

import Foundation

/// What the domino asks before it runs.
@MainActor
protocol SyncHeadGate: AnyObject {
    /// Run `work` once this session is at head. With no engine running
    /// (signed out, feed unavailable — the pre-sync app) that is now; with
    /// one, after the next pull chain ends at head. Only the latest request
    /// is kept while waiting: one catch-up push covers every tick that
    /// queued behind the same pull.
    func runWhenAtHead(_ work: @escaping @MainActor () -> Void)
}

/// The default gate: a flag the engine maintains per the contract in the
/// file header. Everything is in memory and false at launch, which is the
/// state the pre-sync app runs in.
@MainActor
final class SyncHeadFlag: SyncHeadGate {
    /// The one the app wires (`DoneApp`); the engine sets its fields.
    static let shared = SyncHeadFlag()

    /// True while an engine pulls for a session (contract step 1 / 4). Any
    /// transition zeroes `isAtHead`; turning it off also releases waiting
    /// work at once (contract step 4). Re-setting the same value is a no-op.
    var engineRunning = false {
        didSet {
            guard engineRunning != oldValue else { return }
            isAtHead = false
            if !engineRunning { drain() }
        }
    }

    /// I1's flag as the engine last reported it: the last chain ended with a
    /// short page and nothing has started since.
    private(set) var isAtHead = false

    /// The engine's "start a pull chain now" hook (no-op while one is in
    /// flight). When set, every request pulls first — 每次 tick 前先拉 —
    /// and runs when that chain ends at head; when nil, a request runs at
    /// once if the session is at head and otherwise waits for the next
    /// `chainEnded(atHead: true)`.
    var pullNow: (() -> Void)?

    private var pending: (@MainActor () -> Void)?

    init() {}

    /// Contract step 2: a pull chain is in flight, so the session is off
    /// head until it ends. A request made now waits for `chainEnded(atHead:
    /// true)`.
    func chainStarted() {
        isAtHead = false
    }

    /// Contract step 2: the end of every pull chain, with I1's verdict. A
    /// chain that stopped short of head (a long page, a refused page) takes
    /// the session off head; at head, waiting work runs once.
    func chainEnded(atHead: Bool) {
        isAtHead = atHead
        if atHead { drain() }
    }

    func runWhenAtHead(_ work: @escaping @MainActor () -> Void) {
        guard engineRunning else {
            work()
            return
        }
        pending = work
        if let pullNow {
            pullNow()
        } else if isAtHead {
            drain()
        }
    }

    private func drain() {
        guard let work = pending else { return }
        pending = nil
        work()
    }
}
