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

/// The default gate: a flag the engine maintains. Everything is in memory
/// and false at launch, which is the state the pre-sync app runs in.
@MainActor
final class SyncHeadFlag: SyncHeadGate {
    /// The one the app wires (`DoneApp`); the engine sets its fields.
    static let shared = SyncHeadFlag()

    /// Set true by the engine while it pulls for a session, false on
    /// sign-out and when the feed is unavailable (design §7 Phase 1 (7)).
    /// Turning it off releases any waiting work at once: with no engine
    /// the domino behaves as it always did.
    var engineRunning = false {
        didSet {
            if !engineRunning {
                isAtHead = false
                drain()
            }
        }
    }

    /// I1's flag as the engine last reported it: the last page was short
    /// and no page has been refused since.
    private(set) var isAtHead = false

    /// The engine's "start a pull chain now" hook (no-op while one is in
    /// flight). When set, every request pulls first — 每次 tick 前先拉 —
    /// and runs when that chain ends at head; when nil, a request runs at
    /// once if the session is at head and otherwise waits for the next
    /// `chainEnded(atHead: true)`.
    var pullNow: (() -> Void)?

    private var pending: (@MainActor () -> Void)?

    init() {}

    /// The engine calls this at the end of every pull chain, with I1's
    /// verdict. At head, waiting work runs once.
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
