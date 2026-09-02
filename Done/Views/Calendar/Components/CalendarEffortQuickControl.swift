//
//  CalendarEffortQuickControl.swift
//  Done
//
//  Split out of CalendarEventDetailView.effortQuickSection (gh#162 R1,
//  closing out #163/#164 for this one control): owns the effort scrubber's
//  in-flight drag preview itself, so a per-step preview write invalidates
//  only this leaf's body, not CalendarEventDetailView's.
//
//  Created by Claude for gh#162 round 3 (2026-08-24).
//

import SwiftUI

/// `dragValue ?? stored`: whether the live drag preview or the durably
/// stored value wins. Pulled out as a pure top-level function, same reason
/// `calendarEffortDragShouldCommit` (CalendarEventDetailView.swift) is --
/// gh#162 round 4 independent QA found `liveEffort` (this function's only
/// call site) completely unprotected when it was a bare computed property:
/// a mutant that made it always return `stored`, ignoring `dragValue`
/// entirely, passed the full suite. The failure mode is total and silent,
/// not cosmetic: the scrubber's commit path reads this same precedence
/// (GlassCardView.swift's `onCommit?(value)` reads the Binding's `get:`,
/// which is this), so under that mutant `commitDrag` always hands
/// `calendarEffortDragShouldCommit` the pre-drag stored value compared
/// against itself, which always declines -- no effort drag would ever
/// persist again, with every test green. See
/// CalendarEffortLiveValuePrecedenceTests for the two mutations this is
/// pinned against. What this does NOT close: whether `liveEffort` below
/// actually CALLS this function, as opposed to reimplementing the same
/// logic inline -- that composition lives inside `body`'s dependency
/// graph and is unreachable the same way the wiring gaps in
/// CalendarEffortScrubberCommitTests.swift's body-composition section are.
func calendarEffortLiveValue(dragValue: Int?, stored: Int?) -> Int? {
    dragValue ?? stored
}

/// The effort descriptor text + scrubber pair. `storedEffort`/`tint` cross
/// in as plain values, never a `@Binding` into the caller's own `@State` --
/// a value can't let a preview mutation propagate back up mid-gesture the
/// way a binding could. `onCommit` is the only way anything durable leaves
/// this view; the caller (`CalendarEventDetailView.commitEffortDrag`) does
/// the store-value comparison and the actual write, unchanged from before
/// this split except that it no longer also owns the preview.
struct CalendarEffortQuickControl: View {
    let storedEffort: Int?
    let tint: Color
    let onCommit: (Int) -> Void

    /// Live preview for an in-flight drag -- the same role
    /// `CalendarEventDetailView.effortDragValue` played before this split
    /// (gh#162 R1). `nil` means no drag is active, so the descriptor and
    /// the scrubber's binding both read `storedEffort`. `private`, not
    /// relaxed for tests: `@State` on a `View` struct that's never
    /// installed in a live SwiftUI hierarchy doesn't durably hold a write
    /// across separate calls, so a direct-construction test reading this
    /// back would be vacuous -- same reasoning as the gh#162 W3 gap
    /// `CalendarEffortScrubberCommitTests.swift` documents. The
    /// backgrounding flush that used to read this state's parent-owned
    /// equivalent is now this view's own `.onChange(of: scenePhase)`
    /// below; the route-change reset that used to zero it by hand is now
    /// `.id(route.id)` at this view's call site
    /// (`CalendarEventDetailView.effortQuickSection`), which tears this
    /// whole view down and rebuilds it with fresh `@State` instead.
    @State private var dragValue: Int?

    @Environment(\.scenePhase) private var scenePhase

    /// Defers to `calendarEffortLiveValue` (gh#162 R4 / X1 -- see that
    /// function's doc comment for why the precedence itself had to move
    /// out to be testable at all). Read fresh on every access -- a
    /// computed property, not a value captured once into a `body`-local
    /// `let` (gh#162 R2). The pre-split code did exactly that
    /// (`let liveEffort = effortDragValue ?? quickEffortValue` inside
    /// `body`), and a `Binding` getter closure that captures a `let`
    /// returns that SAME frozen value for every read until the next
    /// render -- SwiftUI coalesces consecutive `@State` writes delivered
    /// within one render cycle rather than forcing a render between them,
    /// so `CalendarEffortScrubber.handleChanged`'s own
    /// `guard nextValue != value` dedup guard -- the one thing standing
    /// between a fast drag and a write (and a re-render) on every
    /// delivered touch sample -- was comparing against stale data whenever
    /// two step-crossing samples landed inside one render cycle. A
    /// computed `var` re-reads `dragValue` through its `@State` box (a
    /// `nonmutating set`-backed reference shared across every access to
    /// this same view value) on every call, so a write from one gesture
    /// callback is visible to the very next read with no render required
    /// in between.
    private var liveEffort: Int? { calendarEffortLiveValue(dragValue: dragValue, stored: storedEffort) }

    var body: some View {
        let descriptor = liveEffort.map(calendarHumanEffortDescriptor(for:))

        AdaptivePanelPair(spacing: 12, horizontalThreshold: 380) {
            VStack(alignment: .leading, spacing: 8) {
                if let descriptor {
                    Text(descriptor.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(descriptor.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } secondary: {
            CalendarEffortScrubber(
                value: Binding(get: { liveEffort }, set: handleLiveValueChanged),
                tint: tint,
                onCommit: commitDrag
            )
        }
        // Relocated from CalendarEventDetailView's own scenePhase handler
        // (gh#162 W2/R1): a backgrounding mid-drag never reaches the
        // scrubber's onEnded (the touch is cancelled, not ended), and now
        // that the preview lives here, this is the only place left that
        // can still see it to flush it -- the caller has nothing to read
        // anymore. Redundant with CalendarEffortScrubber's own
        // @GestureState reset (handleDragActiveChanged), which also
        // catches a cancellation, but that needs a live view update to
        // observe -- this stays as a second backstop for a suspension
        // that outruns it. Guarded on dragValue itself: nil here means
        // either no drag was active or handleDragActiveChanged already
        // flushed it, and committing nil isn't representable (onCommit is
        // non-optional Int) or meaningful.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, let pendingEffort = dragValue else { return }
            commitDrag(pendingEffort)
        }
    }

    /// The scrubber's live-value setter -- writes the preview to local
    /// `@State` ONLY, never touches `onCommit`. Not `private`: this is
    /// exactly the wiring gh#162 R3 found completely untested at the
    /// pre-split call site -- reverting production's binding setter back
    /// to routing every step through a commit (the pre-fix bug) left all
    /// existing tests green, because nothing exercised that line. A test
    /// can't read `dragValue` back after calling this (see this view's
    /// own `dragValue` doc comment), but it CAN assert the thing that
    /// actually matters: this call must never invoke `onCommit`.
    func handleLiveValueChanged(_ newValue: Int?) {
        dragValue = newValue
    }

    /// The single durable-write trigger this view has -- wired to
    /// `CalendarEffortScrubber.onCommit` (fires once per gesture; see that
    /// view's own doc comment in GlassCardView.swift) and to the
    /// scenePhase flush above. Clears the local preview, then hands off to
    /// `onCommit` -- the caller's `commitEffortDrag`, which does the
    /// store-value comparison and the actual write. Not `private`: same
    /// reason as `handleLiveValueChanged` above -- a test can pin that
    /// this calls through exactly once, even though it can't observe the
    /// `dragValue = nil` half of what this does.
    func commitDrag(_ finalValue: Int) {
        dragValue = nil
        // gh#201 measurement seam, bracketing the ONE synchronous durable
        // write a gesture performs (`commitEffortDrag` → `applyQuickEffort`
        // → `upsertLogRecord`). Brackets, not a single mark: the question
        // is how long the main thread is held in there, so the ordering of
        // these two emits around the call IS the measurement.
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0))
        onCommit(finalValue)
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0))
    }
}
