//
//  SyncUndoHold.swift
//  Done
//
//  Design §10.6 (A), §6 冲突行基线 (d): a row that merge or smart split
//  deleted is not sent as a tombstone while its undo prompt is up. The
//  outbound debounce (2 s) is shorter than the prompt (merge 4 s, split
//  6 s), so without this the tombstone has landed by the time the user taps
//  Undo, and the server (I6: a tombstone is not undone by an ordinary
//  write) never takes the row back — the other device never sees it, this
//  one logs an orphan on every flush. Held here, the id stays in the
//  baseline and out of the flush's `deletedIds`; Undo releases it and the
//  row comes back clean against its old baseline, a no-op on the wire; the
//  timer releases it and the next flush sends the tombstone as usual.
//
//  In memory only: a process that dies inside the window restarts with no
//  hold, and the tombstone goes out then — the undo prompt died with it.
//  The window runs on the engine's `SyncScheduler`, so a test decides when
//  it ends. Covers today's two undo UIs; a later undo UI that bypasses
//  this reopens the fork (#140 is where those go).
//

import Foundation

@MainActor
final class SyncUndoHold {
    private let scheduler: SyncScheduler
    /// Row ids (as the baseline keys them: `UUID.uuidString`) whose
    /// tombstone is held back.
    private(set) var heldIds: Set<String> = []
    private var timers: [String: SyncScheduledWork] = [:]
    /// Called when a window ends with the ids it released, so the engine
    /// can send the tombstone now rather than with the next edit.
    var onExpire: ((Set<String>) -> Void)?

    init(scheduler: SyncScheduler) {
        self.scheduler = scheduler
    }

    /// Hold the tombstone of each row for `window` seconds — the lifetime
    /// of the undo prompt that can bring it back.
    func hold(_ ids: [UUID], for window: TimeInterval) {
        for id in ids {
            let key = id.uuidString
            timers[key]?.cancel()
            heldIds.insert(key)
            timers[key] = scheduler.schedule(after: window) { [weak self] in
                guard let self else { return }
                self.timers[key] = nil
                guard self.heldIds.remove(key) != nil else { return }
                DiagnosticTrail.record("Sync", "sync.undo.expired id=\(key)")
                self.onExpire?([key])
            }
        }
        DiagnosticTrail.record("Sync", "sync.undo.hold count=\(ids.count) window=\(Int(window))")
    }

    /// The undo: the rows are back in the array with their baselines
    /// untouched, so nothing is owed.
    func release(_ ids: [UUID]) {
        for id in ids {
            let key = id.uuidString
            timers[key]?.cancel()
            timers[key] = nil
            heldIds.remove(key)
        }
        DiagnosticTrail.record("Sync", "sync.undo.released count=\(ids.count)")
    }

    func isHeld(_ id: String) -> Bool {
        heldIds.contains(id)
    }
}
