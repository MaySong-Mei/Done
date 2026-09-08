//
//  DeadlineScrubCoalescer.swift
//  Done
//
//  gh#219 — commit-on-release for the todo deadline wheel.
//
//  WHY THIS EXISTS
//  ---------------
//  `CalendarEventDetailView.deadlineDateBinding.set` routed every detent of the
//  deadline `DatePicker` straight through `store.applyRecurringEdit`, and each
//  of those is a full `saveCalendarEvents` — a whole-calendar-blob encode +
//  fsync + `rename(2)`. Dragging the wheel across a week is dozens of full-blob
//  commits for one edit the user has not even released yet.
//
//  The effort scrubber already solved the same shape by committing once, on
//  release (`CalendarEventDetailView.commitEffortDrag` /
//  `calendarEffortDragShouldCommit`). A `DatePicker` gives no `.onEnded` hook,
//  so "release" is detected the way the composer-draft path detects a settled
//  keystroke burst: a trailing write a short quiet window after the last
//  change. This type is that coalescer, pulled out of the view so its
//  collapse-many-into-one contract is testable without a live render — the
//  same reason `calendarEffortDragShouldCommit` and
//  `calendarComposerDraftWriteDecision` are free functions.
//
//  DURABILITY (why a coalesce is acceptable here and was NOT for a chat message)
//  -----------------------------------------------------------------------------
//  A crash inside the quiet window loses only an unconfirmed deadline edit: the
//  wheel has not settled, nothing durable claims the new value, and the next
//  time the user touches the deadline they set it again. That is self-healing.
//  A dropped chat message is not — it is gone and cannot be re-derived — which
//  is why Target 1 makes every message durable on return (an append) and only
//  Target 2 coalesces.
//
//  The in-flight value is held here and read back by the binding's getter, so
//  the wheel stays live during the scrub (the store is not mutated per detent,
//  so a getter that read only the store would fight the wheel and snap it back).
//

import Foundation

/// Coalesces a burst of deadline-wheel detents into a single durable write.
///
/// `scrub` records the latest value and (re)arms a trailing timer; `flush`
/// performs the one write. The view also calls `flush` on disappear and on
/// backgrounding, so a settled edit is never left waiting on the timer when the
/// surface goes away — the same belt-and-braces the composer-draft path uses.
@MainActor
final class DeadlineScrubCoalescer {
    /// The pending, not-yet-persisted edit. Read by the binding getter so the
    /// wheel reflects the in-flight value rather than the last durable one.
    private(set) var pending: (id: UUID, value: Date)?

    private var task: Task<Void, Never>?
    private var persist: ((UUID, Date) -> Void)?
    private let window: Duration

    /// `window` is the quiet period after the last detent before the durable
    /// write fires. Injected so a test can make it effectively infinite and
    /// drive `flush()` synchronously, proving the collapse without leaning on
    /// wall-clock timing.
    init(window: Duration = .milliseconds(400)) {
        self.window = window
    }

    /// The in-flight value for `id`, or nil if the pending edit is for another
    /// row (or there is none). The binding getter falls back to the store.
    func value(for id: UUID) -> Date? {
        guard let pending, pending.id == id else { return nil }
        return pending.value
    }

    var hasPending: Bool { pending != nil }

    /// Record a detent. Replaces any pending value (latest wins) and re-arms the
    /// trailing timer. `persist` is captured fresh each call — the caller passes
    /// a closure over the CURRENT view render, so `flush` always writes through
    /// the freshest store/route references rather than a snapshot captured when
    /// the coalescer was first built.
    func scrub(id: UUID, to value: Date, persist: @escaping (UUID, Date) -> Void) {
        pending = (id, value)
        self.persist = persist
        task?.cancel()
        task = Task { [weak self, window] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write the pending edit exactly once, if there is one. Idempotent: a
    /// second `flush` with nothing pending is a no-op, so the timer firing after
    /// a disappear-triggered flush does nothing.
    func flush() {
        task?.cancel()
        task = nil
        guard let pending, let persist else {
            self.pending = nil
            return
        }
        self.pending = nil
        persist(pending.id, pending.value)
    }

    /// Drop a pending edit WITHOUT writing it. For the case where a later,
    /// authoritative action supersedes the in-flight scrub — clearing the
    /// deadline entirely — so the trailing timer cannot resurrect the value the
    /// user just discarded.
    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
        persist = nil
    }
}
