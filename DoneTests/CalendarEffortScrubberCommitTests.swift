//
//  CalendarEffortScrubberCommitTests.swift
//  DoneTests
//
//  gh#162: the effort scrubber used to route every intermediate drag value
//  through CalendarEventDetailView's binding setter, which called
//  applyQuickEffort -> store.upsertLogRecord on each step -- two whole-array
//  synchronous persists plus a store-wide @Published republish, while the
//  finger was still moving.
//
//  Round 2 (this revision) responds to independent review + QA's mutation
//  pass on round 1, AND to a real bug this round's own first attempt at W2
//  introduced and its own test caught: two mutants that changed lines in
//  CalendarEventDetailView survived because nothing in this file exercised
//  those lines at all, one mutant on the live-tracking dedup guard survived
//  because the test helper recorded a final value rather than a write
//  count, one mutant on handleEnded's release-snap line survived because
//  every test released at the same x as its last change, and -- caught
//  live, not by mutation testing -- a first W2 design that had BOTH
//  handleEnded and the GestureState-reset path call onCommit, coordinated
//  by an @State flag, actually double-committed on every ordinary release
//  because that flag's write in one callback wasn't visible when a
//  separately-dispatched callback read it. See handleDragActiveChanged's
//  doc comment in GlassCardView.swift for the fix (a single call site,
//  not a coordinated pair) and testNormalReleaseDoesNotDoubleCommitWhenGestureStateResets
//  below for the regression test. Four layers are pinned here now, matching
//  the four places gh#162's fix and its round-2 hardening touch:
//
//  1. CalendarEffortScrubberGestureTests drives the scrubber's own
//     onChanged/onEnded handlers directly (DragGesture.Value has no public
//     initializer, so the gesture closures were refactored to take a plain
//     CGFloat location -- see handleChanged/handleEnded in GlassCardView.swift
//     -- specifically so a test can call them without simulating touches).
//     This pins that onChanged never reaches onCommit, that handleEnded
//     ALONE (without the paired GestureState-reset call) never commits
//     either -- only the reset does -- that a release/tap ending WITH that
//     paired call reaches onCommit exactly once, that the value-changed
//     dedup guard skips a write (not just that the final value looks
//     right), and that a release at a different x than the last change
//     snaps to the release location.
//
//  2. CalendarEffortScrubberCancellationTests drives handleDragActiveChanged
//     directly -- the pure decision behind CalendarEffortScrubber's
//     @GestureState-based cancellation handling (gh#162 W2), and (since
//     round 2's redesign) the ONLY place onCommit fires at all, cancelled
//     or not. Its real trigger, .onChange(of: isDragActive), needs a live
//     gesture recognizer to actually cancel a gesture mid-drag, which a
//     plain XCTest can't simulate -- so this pins the DECISION (cancel
//     commits the last live value exactly once; a normal end commits
//     exactly once too, from this single call site, structurally unable to
//     double) and leaves the reset mechanism's reliability itself
//     documented as reasoned from Apple's @GestureState contract plus this
//     codebase's own FocusModeView precedent, not device-measured here.
//
//  3. CalendarEffortDragCommitDecisionTests drives
//     calendarEffortDragShouldCommit directly -- the pure decision pulled
//     out of CalendarEventDetailView.commitEffortDrag specifically because
//     commitEffortDrag itself reads quickEffortValue, which reads through
//     @EnvironmentObject var store, and constructing CalendarEventDetailView
//     in a test to call it crashes on that access (gh#162 W1). This is also
//     what keeps a duplicate onCommit call from reaching the store twice
//     for the same final value: once the first call's write lands, a
//     second call carrying the identical value reads that back and
//     declines.
//
//  4. gh#162 W3 (the route-change reset discarding a stale effort preview)
//     has NO automated test here -- a declared gap, not an oversight. A
//     first attempt constructed CalendarEventDetailView directly, wrote
//     its @State effortDragValue, called resetTimelineInteractionState(),
//     and asserted the property was nil afterward. It passed even with
//     the production reset line deleted (QA's mutant M6 survived): @State
//     on a View struct that was never installed in a live SwiftUI
//     hierarchy doesn't durably hold a write across separate calls, so
//     the setup write never took effect and the assertion was checking an
//     untouched initial value the whole time. See the full diagnosis and
//     the generalized warning ("any test that sets up by writing @State on
//     a freshly constructed View struct is vacuous") where the deleted
//     test used to live, just above CalendarEffortDurableWriteTests below.
//     The production line stays -- it's cheap insurance -- covered by
//     design review, not by this suite.
//
//  5. CalendarEffortDurableWriteTests exercises the real store primitive
//     (store.upsertLogRecord, the same call applyQuickEffort makes) against
//     real DurableEventStorage, using the onSlotCommitted seam
//     EventStoreDeletionOrderingTests already established. It pins the OLD
//     per-step cost (one commit pair per step) against the FIXED single
//     commit's cost and content.
//
//  ======================================================================
//  ROUND 3 -- independent review returned MERGE WITH FIXES; separately, a
//  falsifiable check reverted effortQuickSection's binding setter from
//  `effortDragValue = $0` back to `applyQuickEffort($0)` -- the exact
//  pre-fix per-step-write bug this whole file exists to prevent -- and
//  reran the four test classes above. All 15 tests stayed green. None of
//  them touch that line: 1-3 drive CalendarEffortScrubber or the pure
//  decision function directly with this file's own Box, never
//  CalendarEventDetailView's real wiring; 5 drives the store primitive
//  directly, no view involved at all. That binding setter -- the one line
//  that actually decides per-step-write vs. once-at-release in production
//  -- had zero coverage.
//  ======================================================================
//
//  This round does two things, in CalendarEventDetailView.swift and the
//  new Calendar/Components/CalendarEffortQuickControl.swift:
//
//  * Splits effortQuickSection's content into its own leaf view,
//    CalendarEffortQuickControl -- the extraction #163/#164 already asked
//    for on performance grounds (a per-step preview write was
//    invalidating CalendarEventDetailView's whole body, not just this
//    control), and which also happens to be what makes the binding wiring
//    reachable from a test at all: the leaf exposes its setter/commit
//    wiring as plain methods (handleLiveValueChanged, commitDrag) the same
//    way CalendarEffortScrubber already exposes
//    handleChanged/handleEnded/handleDragActiveChanged. See
//    CalendarEffortQuickControlWiringTests, item 6 below.
//
//  * Fixes a second bug independent review found by reading the code, not
//    by measuring: effortQuickSection computed
//    `let liveEffort = effortDragValue ?? quickEffortValue` ONCE per body
//    pass and captured that into the scrubber's Binding getter closure.
//    SwiftUI coalesces consecutive @State writes delivered within one
//    render cycle rather than forcing a render between them, so two touch
//    samples landing in the same cycle both read the SAME frozen
//    snapshot through that closure -- unlike this file's own Box helper,
//    which reads live on every call. That silently defeated
//    CalendarEffortScrubber.handleChanged's own value-changed dedup guard
//    (W5, above) in exactly the condition it matters most: a busy render
//    cycle. CalendarEffortQuickControl.liveEffort is a computed `var`
//    instead of a captured `let`, so it re-reads live; see its doc
//    comment in the leaf's own file.
//
//  6. CalendarEffortQuickControlWiringTests drives
//     CalendarEffortQuickControl's handleLiveValueChanged and commitDrag
//     directly -- the methods its `body` wires the scrubber's Binding
//     `set:` and `onCommit:` to. This closes the specific gap the
//     round-3 revert exploited: handleLiveValueChanged must never itself
//     reach onCommit. It does NOT close an adjacent gap the same kind of
//     revert could still hit: whether `body` truly calls these named
//     methods, versus some other inline closure reimplementing different
//     logic, is still unverified by any test here, for the same reason
//     gh#162 W1/W3 above are -- swift-snapshot-testing IS linked to the
//     DoneTests target (Done.xcodeproj's packageProductDependencies), but
//     no test file imports it and no view-hosting harness has ever been
//     built on top of it, so there is nothing here to construct
//     CalendarEffortQuickControl inside a live hierarchy and drive a real
//     gesture through it. Referencing `set:`/`onCommit:` by name from
//     `body` (rather than reimplementing their logic inline in a
//     trailing closure) is what's left standing in THAT gap -- but this
//     claim does NOT generalize to every value `body` reads: see ROUND 4
//     below for where it broke.
//  ======================================================================
//  ROUND 4 -- independent QA + reviewer ran in parallel against a688986;
//  every finding went through an adversarial verifier before being
//  reported. One finding is corrected here rather than left standing:
//  item 6's closing claim above ("a behavior change has to touch a
//  method these tests exercise directly") was written as if it covered
//  everything `body` reads, but it only ever covered the two things it
//  names -- the Binding's `set:` and `onCommit:`. `liveEffort` (the
//  Binding's `get:`) was never one of those two, and QA's mutant proved
//  it: making `liveEffort` always return `storedEffort`, ignoring
//  `dragValue` entirely, passed the full suite. See
//  CalendarEffortLiveValuePrecedenceTests below for the fix
//  (calendarEffortLiveValue, a pure function `liveEffort` now defers to)
//  and the body-composition section (after the commit-decision layer)
//  for the full, corrected list of what remains unreachable without a
//  view-hosting harness this repo doesn't link.
//

import XCTest
import SwiftUI
@testable import Done

// MARK: - Gesture layer

@MainActor
final class CalendarEffortScrubberGestureTests: XCTestCase {
    /// Reference-type backing for a two-way Binding, so a test can read what
    /// the scrubber wrote after each call. Counts SET calls, not just the
    /// final value (gh#162 W5) -- reading back `value` alone can't tell a
    /// dedup guard that correctly skipped a redundant write from one that's
    /// simply writing the same value repeatedly, and QA's mutant on
    /// handleChanged's `guard nextValue != value` survived against a
    /// value-only Box for exactly that reason. That guard is the only thing
    /// standing between a 120Hz drag and a `@State` write (and this view's
    /// body re-invoking) on every single delivered touch sample.
    private final class Box {
        var value: Int?
        private(set) var setCount = 0
        init(_ value: Int?) { self.value = value }
        func set(_ newValue: Int?) {
            value = newValue
            setCount += 1
        }
    }

    private func makeBinding(_ box: Box) -> Binding<Int?> {
        Binding(get: { box.value }, set: box.set)
    }

    /// A real gesture end is TWO signals, not one: `.onEnded` (handleEnded)
    /// snaps `value` to the release position, and the `@GestureState` reset
    /// that always follows it (handleDragActiveChanged, simulated here) is
    /// what actually fires `onCommit` (gh#162 W2 round 2 -- handleEnded no
    /// longer commits on its own; see handleDragActiveChanged's doc comment
    /// in GlassCardView.swift for why). Every test below that wants a
    /// commit after a release goes through this, matching production's real
    /// sequence rather than calling handleEnded in isolation.
    private func release(_ scrubber: CalendarEffortScrubber, locationX: CGFloat, trackWidth: CGFloat) {
        scrubber.handleEnded(locationX: locationX, trackWidth: trackWidth)
        scrubber.handleDragActiveChanged(wasActive: true, isActive: false)
    }

    /// A full-width sweep on a 100pt / 5-step track. Expected values are
    /// nearestValue's own formula worked out longhand for each x, not read
    /// back from the SUT -- a broken nearestValue (e.g. an off-by-one in the
    /// step math) would fail this even though every write still lands
    /// somewhere.
    ///
    /// x=0: progress 0.00, round(0.00)=0 -> step 1
    /// x=10: progress 0.10, round(0.40)=0 -> step 1
    /// x=20: progress 0.20, round(0.80)=1 -> step 2
    /// x=30: progress 0.30, round(1.20)=1 -> step 2
    /// x=40: progress 0.40, round(1.60)=2 -> step 3
    /// x=50: progress 0.50, round(2.00)=2 -> step 3
    /// x=60: progress 0.60, round(2.40)=2 -> step 3
    /// x=70: progress 0.70, round(2.80)=3 -> step 4
    /// x=80: progress 0.80, round(3.20)=3 -> step 4
    /// x=90: progress 0.90, round(3.60)=4 -> step 5
    /// x=100: progress 1.00, round(4.00)=4 -> step 5
    func testDragSweepUpdatesValueLiveButNeverCommits() {
        let box = Box(nil)
        var commits: [Int] = []
        let scrubber = CalendarEffortScrubber(
            value: makeBinding(box),
            onCommit: { commits.append($0) }
        )

        var observed: [Int] = []
        for x in stride(from: CGFloat(0), through: 100, by: 10) {
            scrubber.handleChanged(locationX: x, trackWidth: 100)
            observed.append(box.value ?? -1)
        }

        XCTAssertEqual(observed, [1, 1, 2, 2, 3, 3, 3, 4, 4, 5, 5])
        XCTAssertTrue(commits.isEmpty, "onChanged must never reach onCommit -- that IS the bug this issue reports")
    }

    /// The dedup guard that's the only thing between a 120Hz drag and 120
    /// `@State` writes (and body re-invocations) a second: five x samples
    /// that all snap to the SAME step must write `value` exactly once, not
    /// once per sample (gh#162 W5). Reading back only the final value can't
    /// distinguish "wrote once" from "wrote five times, landing on the same
    /// number" -- `setCount` can.
    func testHandleChangedSkipsRedundantWritesWithinTheSameStep() {
        let box = Box(nil)
        let scrubber = CalendarEffortScrubber(value: makeBinding(box))

        // x=0,2,4,8,12 on a 100pt/5-step track all round to step 1: the
        // largest, x=12, is progress 0.12, round(0.12*4)=round(0.48)=0 -> 1.
        for x: CGFloat in [0, 2, 4, 8, 12] {
            scrubber.handleChanged(locationX: x, trackWidth: 100)
        }

        XCTAssertEqual(box.value, 1)
        XCTAssertEqual(box.setCount, 1, "five touches inside the same snapped step must write @State once, not five times")
    }

    /// Same sweep as above, then one release. Exactly one commit, carrying
    /// the value the finger was actually on at release -- not the first
    /// value, not a stale value, not zero commits.
    func testReleaseAfterSweepCommitsExactlyOnceWithFinalValue() {
        let box = Box(nil)
        var commits: [Int] = []
        let scrubber = CalendarEffortScrubber(
            value: makeBinding(box),
            onCommit: { commits.append($0) }
        )

        for x in stride(from: CGFloat(0), through: 100, by: 10) {
            scrubber.handleChanged(locationX: x, trackWidth: 100)
        }
        release(scrubber, locationX: 100, trackWidth: 100)

        XCTAssertEqual(commits, [5])
        XCTAssertEqual(box.value, 5)
    }

    /// Every OTHER test in this file releases at the same x as its last
    /// `handleChanged` call, which leaves handleEnded's own
    /// `if finalValue != value { value = finalValue }` line dead -- `value`
    /// already equals `finalValue` going in, from the preceding onChanged.
    /// A real release can land at a different x than the last delivered
    /// onChanged sample (the touch-up event isn't guaranteed to coincide
    /// with the previous move sample), so this drags to step 1 then
    /// releases at step 5 without an intervening onChanged (gh#162 W6).
    func testReleaseAtADifferentXThanTheLastChangeSnapsToTheReleaseValue() {
        let box = Box(nil)
        var commits: [Int] = []
        let scrubber = CalendarEffortScrubber(
            value: makeBinding(box),
            onCommit: { commits.append($0) }
        )

        scrubber.handleChanged(locationX: 10, trackWidth: 100) // -> step 1
        release(scrubber, locationX: 90, trackWidth: 100)       // -> step 5, no onChanged in between

        XCTAssertEqual(box.value, 5, "release must snap to the RELEASE location, not the last onChanged sample")
        XCTAssertEqual(commits, [5])
    }

    /// minimumDistance: 0 means a plain tap drives onChanged then onEnded at
    /// the SAME location. Must commit exactly once -- not zero (if onEnded
    /// were ever skipped for a zero-distance gesture) and not two (if
    /// onChanged also committed).
    func testTapCommitsExactlyOnce() {
        let box = Box(nil)
        var commits: [Int] = []
        let scrubber = CalendarEffortScrubber(
            value: makeBinding(box),
            onCommit: { commits.append($0) }
        )

        scrubber.handleChanged(locationX: 50, trackWidth: 100)
        release(scrubber, locationX: 50, trackWidth: 100)

        // x=50 on a 100pt/5-step track: progress 0.50, round(0.50*4)+1 = 3.
        XCTAssertEqual(commits, [3])
        XCTAssertEqual(box.value, 3)
    }

    /// Pins the new (round 2) contract directly: `handleEnded` alone -- the
    /// old, pre-round-2 single commit trigger -- must NOT commit anymore.
    /// Only the paired `handleDragActiveChanged` reset does. A regression
    /// back to committing from `handleEnded` would reintroduce the exact
    /// double-commit `testNormalReleaseDoesNotDoubleCommitWhenGestureStateResets`
    /// (CalendarEffortScrubberCancellationTests) polices from the other
    /// side.
    func testHandleEndedAloneDoesNotCommitUntilThePairedResetFires() {
        let box = Box(nil)
        var commits: [Int] = []
        let scrubber = CalendarEffortScrubber(
            value: makeBinding(box),
            onCommit: { commits.append($0) }
        )

        scrubber.handleChanged(locationX: 90, trackWidth: 100)
        scrubber.handleEnded(locationX: 90, trackWidth: 100)

        XCTAssertTrue(commits.isEmpty, "handleEnded alone must not commit -- only the paired GestureState reset does (gh#162 W2 round 2)")
        XCTAssertEqual(box.value, 5, "handleEnded must still snap value, independent of committing")
    }

    /// CalendarEventLogSheet's call site (GlassCardView.swift caller in
    /// CalendarEventLogSheet.swift:267) passes no onCommit -- it binds
    /// straight to local @State and does no store work, so every step is
    /// already cheap. Confirms that call site's contract is untouched: value
    /// still updates on every step, and a nil onCommit is a silent no-op
    /// rather than a crash.
    func testMissingOnCommitLeavesLiveUpdatesUnaffected() {
        let box = Box(2)
        let scrubber = CalendarEffortScrubber(value: makeBinding(box))

        scrubber.handleChanged(locationX: 90, trackWidth: 100)
        XCTAssertEqual(box.value, 5)

        release(scrubber, locationX: 90, trackWidth: 100)
        XCTAssertEqual(box.value, 5)
    }
}

// MARK: - Gesture-cancellation layer (gh#162 W2)

@MainActor
final class CalendarEffortScrubberCancellationTests: XCTestCase {
    private final class Box {
        var value: Int?
        init(_ value: Int?) { self.value = value }
    }

    private func makeBinding(_ box: Box) -> Binding<Int?> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }

    /// The scenario W2 is about: a touch lands on the scrubber (onChanged
    /// fires, `value` updates) and then the enclosing ScrollView's pan
    /// recognizer wins arbitration -- SwiftUI cancels the DragGesture,
    /// `.onEnded` never fires, and the only thing left standing is
    /// `@GestureState`'s automatic reset, exercised here via
    /// `handleDragActiveChanged` directly (its real trigger,
    /// `.onChange(of: isDragActive)`, needs a live gesture recognizer and
    /// isn't reachable from a plain XCTest -- see the file header). Must
    /// still commit: an abandoned drag must not leave the descriptor
    /// showing a value the store never received.
    func testCancelledDragAfterPartialSweepStillCommitsLastLiveValue() {
        let box = Box(nil)
        var commits: [Int] = []
        let scrubber = CalendarEffortScrubber(
            value: makeBinding(box),
            onCommit: { commits.append($0) }
        )

        scrubber.handleChanged(locationX: 40, trackWidth: 100) // -> step 3
        // The gesture never reaches handleEnded -- the ScrollView above it
        // wins arbitration instead. Simulates the ONE thing SwiftUI still
        // guarantees in that case: the GestureState reset.
        scrubber.handleDragActiveChanged(wasActive: true, isActive: false)

        XCTAssertEqual(commits, [3], "a cancelled drag must still commit the last live value, not strand it")
        XCTAssertEqual(box.value, 3)
    }

    /// A normal release must not double-commit. Round 2's FIRST attempt at
    /// this had `handleEnded` fire `onCommit` directly and relied on a
    /// `didCommitAtGestureEnd` @State flag here to stop the GestureState
    /// reset that follows EVERY gesture end (cancelled or not) from firing
    /// a second, duplicate commit -- this exact test caught that design
    /// failing: the flag set inside `handleEnded` wasn't visible by the
    /// time this method read it, and commits came back `[5, 5]`.
    ///
    /// The fix removed the coordination problem instead of patching it:
    /// `handleEnded` no longer calls `onCommit` at all (see its doc
    /// comment and `handleDragActiveChanged`'s in GlassCardView.swift) --
    /// `handleDragActiveChanged` is the ONLY call site, so there is
    /// nothing left to double. This test now exercises that directly:
    /// `handleEnded` merely snaps `value`, and the one commit comes from
    /// the reset alone.
    func testNormalReleaseDoesNotDoubleCommitWhenGestureStateResets() {
        let box = Box(nil)
        var commits: [Int] = []
        let scrubber = CalendarEffortScrubber(
            value: makeBinding(box),
            onCommit: { commits.append($0) }
        )

        scrubber.handleChanged(locationX: 90, trackWidth: 100)
        scrubber.handleEnded(locationX: 90, trackWidth: 100)
        // The GestureState reset SwiftUI performs after every gesture end
        // (not just a cancellation) -- simulated directly.
        scrubber.handleDragActiveChanged(wasActive: true, isActive: false)

        XCTAssertEqual(commits, [5], "exactly one commit, from the single call site -- there is no second path left to fire twice")
    }

    /// A gesture that never delivered a single onChanged before being
    /// cancelled (the recognizer failed before ever beginning) has nothing
    /// new to commit. `value` still reads whatever it was pre-gesture --
    /// nil here, an unset effort -- and committing nil isn't representable
    /// (onCommit is non-optional Int, gh#162 W7) or meaningful, so this must
    /// be a silent no-op, not a fabricated value.
    func testCancellationBeforeAnyChangeWithNoExistingValueCommitsNothing() {
        let box = Box(nil)
        var commits: [Int] = []
        let scrubber = CalendarEffortScrubber(
            value: makeBinding(box),
            onCommit: { commits.append($0) }
        )

        scrubber.handleDragActiveChanged(wasActive: true, isActive: false)

        XCTAssertTrue(commits.isEmpty)
    }
}

// MARK: - Commit-decision layer (gh#162 W1)

final class CalendarEffortDragCommitDecisionTests: XCTestCase {
    /// The property that keeps `commitEffortDrag` from reaching the store
    /// more than once for a single gesture even if `onCommit` somehow fired
    /// twice: after the first call's write lands, the store's own value
    /// equals what was just written, so a second call carrying the
    /// identical final value reads that back and declines.
    func testDeclinesARepeatedCallAfterTheFirstCommitLands() {
        XCTAssertTrue(calendarEffortDragShouldCommit(finalValue: 4, currentStoreValue: nil))
        // Simulates the store now holding what the first call just wrote.
        XCTAssertFalse(calendarEffortDragShouldCommit(finalValue: 4, currentStoreValue: 4))
    }

    func testCommitsWhenFinalValueDiffersFromTheStore() {
        XCTAssertTrue(calendarEffortDragShouldCommit(finalValue: 3, currentStoreValue: nil))
        XCTAssertTrue(calendarEffortDragShouldCommit(finalValue: 3, currentStoreValue: 2))
    }

    func testDeclinesWhenFinalValueAlreadyMatchesTheStore() {
        XCTAssertFalse(calendarEffortDragShouldCommit(finalValue: 3, currentStoreValue: 3))
    }
}

// MARK: - Body-composition layer (gh#162 W3 / R1 / R4) -- NO AUTOMATED TEST, DECLARED GAPS
//
// This section used to describe a single mechanism: `effortDragValue = nil`
// inside `resetTimelineInteractionState()` (CalendarEventDetailView.swift),
// discarding a stale in-flight effort preview on `onChange(of: route.id)`
// so it couldn't bleed onto the next occurrence. gh#162 round 1 DELETED
// that mechanism -- `effortDragValue` no longer exists as a property
// anywhere; it survives only as a name in a historical comment at
// CalendarEventDetailView.swift:609. What replaced it, and why this
// section is now about four gaps instead of one, below.
//
// Round 1 split effortQuickSection's content into its own leaf view,
// CalendarEffortQuickControl (Calendar/Components/CalendarEffortQuickControl.swift),
// which owns the drag preview as its own `@State private var dragValue`.
// The route-change reset moved with it, but changed SHAPE: instead of a
// hand-maintained `effortDragValue = nil` line, effortQuickSection tags
// the leaf `.id(route.id)` at its call site -- a route change tears the
// whole leaf down and rebuilds it with fresh `@State`, closing the bug
// class structurally (any @State this leaf grows later is reset by
// construction, not by remembering to add it to a list) rather than by a
// line this file could theoretically test the way `resetTimelineInteractionState()`'s
// eleven unconditional assignments never could (no comparable inputs to
// pull out as a pure function, unlike `calendarEffortDragShouldCommit`,
// gh#162 W1 above).
//
// Diagnostic precedent worth keeping, because it generalizes past this
// one property: an early attempt at testing the OLD mechanism constructed
// `CalendarEventDetailView` directly, wrote `view.effortDragValue = 4`,
// called `resetTimelineInteractionState()`, and asserted the property was
// `nil` afterward. It passed -- including against a mutant that deleted
// the production reset line entirely. Diagnosis: `@State` on a `View`
// struct that was never installed in a live SwiftUI hierarchy does not
// durably hold a write across separate calls -- there is no view identity
// for SwiftUI to key the storage to, so the test was reading an untouched
// initial value the whole time. ANY test that sets up by writing `@State`
// on a freshly constructed View struct -- not routed through a `@Binding`
// closure into externally-owned storage, the way this file's `Box`
// pattern is -- is vacuous, and it will read as correct in review. (The
// exact same failure mode independently sank a `didCommitAtGestureEnd`
// @State flag in `CalendarEffortScrubber`, round 2 -- see
// `handleDragActiveChanged`'s doc comment in GlassCardView.swift.)
//
// swift-snapshot-testing IS linked to the DoneTests target (Done.xcodeproj's
// packageProductDependencies), but no test file imports it and no
// view-hosting harness has ever been built on top of it -- linking the
// product was someone else's decision, not evidence a harness is coming;
// building one wasn't in scope for this fix.
//
// The confirmed set, adversarially verified (independent review + a
// fresh mutation pass against a688986, each survivor confirmed by an
// adversarial verifier that tried and failed to refute it) -- all of
// them share the same root cause: each lives inside a `body`/modifier
// chain that only does anything under a real view-identity change or a
// real environment change reaching a LIVE hierarchy, not reachable by
// constructing a View struct directly and calling a method the way every
// OTHER layer in this file is tested:
//
// - M4 -- CalendarEffortQuickControl's `.id(route.id)` tag at its call
//   site (CalendarEventDetailView.effortQuickSection) -- deleting it
//   (letting a stale preview from the PREVIOUS occurrence bleed onto the
//   next, the exact bug this mechanism exists to prevent) is unreachable
//   from a direct-construction test: nothing here renders
//   effortQuickSection or changes `route.id` under a live view.
// - M3 -- effortQuickSection's `onCommit: commitEffortDrag` wiring into
//   CalendarEffortQuickControl's initializer -- a mutant that swaps this
//   for a no-op closure passes everything here, for the same reason
//   commitEffortDrag's own body does (gh#162 W1's original point,
//   unchanged): nothing constructs CalendarEventDetailView directly
//   (crashes on the @EnvironmentObject access) to exercise its real
//   wiring.
// - M5 -- CalendarEffortQuickControl's `.onChange(of: scenePhase)`
//   backgrounding flush -- neutering the guard or the `commitDrag` call
//   inside it is unreachable the same way CalendarEffortScrubber's own
//   `.onChange(of: isDragActive)` is (see that view's doc comment in
//   GlassCardView.swift): it needs a live environment change to fire,
//   which a plain XCTest can't simulate.
// - X1's composition residue -- `liveEffort`'s COMPOSITION: gh#162 R4
//   pulled the `dragValue`-vs-`storedEffort` precedence out as
//   `calendarEffortLiveValue(dragValue:stored:)`
//   (CalendarEffortLiveValuePrecedenceTests, below) precisely because the
//   precedence ITSELF had zero protection as a bare computed property --
//   a mutant that made `liveEffort` always return `storedEffort` passed
//   the full suite that existed before this round, and its failure mode
//   is total: the scrubber's commit path reads this same precedence
//   (`GlassCardView.swift`'s `onCommit?(value)` reads the Binding's
//   `get:`, which is `liveEffort`), so under that mutant every commit
//   compares the pre-drag stored value against itself, always declines,
//   and the whole control goes silently dead -- with every test green.
//   What THAT fix does not close: whether `liveEffort`'s one-line body
//   actually CALLS `calendarEffortLiveValue`, as opposed to
//   reimplementing the same `??` inline -- same class of gap as the two
//   items above, for the same reason.
//
// `calendarEffortDragShouldCommit` (W1) and `calendarEffortLiveValue`
// (R4) are what a real seam looks like when one exists: a genuine
// decision with comparable inputs, pulled out as a pure function and
// tested directly. Both close the DECISION. Neither closes, and neither
// COULD close without a linked hosting harness, whether the `body` that
// depends on the decision actually calls the function that makes it.

// MARK: - Durable-write layer

@MainActor
final class CalendarEffortDurableWriteTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarEffortDurableWriteTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private func occurrence(_ eventID: UUID, on date: Date) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: date,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    /// Pins the OLD code's actual cost model as a positive control: four
    /// distinct steps -- the same count a real drag across this scrubber's
    /// 5-step track produces (see CalendarEffortScrubberGestureTests) --
    /// each independently call store.upsertLogRecord, the same call the OLD
    /// binding setter in CalendarEventDetailView.effortQuickSection made on
    /// every step before this fix. Each step is still its own durable
    /// log-record commit; that is the cost this positive control is about.
    ///
    /// gh#201 fix 3 changed the OTHER half of the pair. The colorDepth
    /// mirror those four steps each drove used to re-save the whole
    /// calendar-events array on every step, inside the tap's own turn; it
    /// now coalesces off it, so the four mirrors reach disk as ONE commit.
    /// Asserted here as `0` (nothing on this turn), with the coalescing and
    /// last-value-wins halves pinned in
    /// CalendarColorDepthMirrorTests.testRapidChangesCoalesceIntoOneCommit-
    /// CarryingTheLastValue.
    ///
    /// This test does NOT exercise CalendarEventDetailView or
    /// commitEffortDrag -- it drives store.upsertLogRecord directly, four
    /// times, to pin the store primitive's own per-call cost (gh#162 W4:
    /// an earlier revision of this comment claimed this pinned the view's
    /// OLD binding setter specifically; it never touched that view).
    func testFourIntermediateStepsEachProduceADurableLogCommit() throws {
        let store = makeStore()
        let event = Event(
            title: "Deep Work",
            timeRanges: [.init(start: Date(), end: Date().addingTimeInterval(3600))],
            type: "Study"
        )
        store.addCalendarEvent(event)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }

        for step in [1, 2, 3, 4] {
            store.upsertLogRecord(for: ctx) { $0.effort = step }
        }

        XCTAssertEqual(
            commits.filter { $0 == StorageSlot.calendarEventLogRecords.rawValue }.count, 4,
            "saveCalendarEventLogRecords() runs unconditionally on every upsertLogRecord call"
        )
        XCTAssertEqual(
            commits.filter { $0 == StorageSlot.calendarEvents.rawValue }.count, 0,
            "the colorDepth mirror no longer rides along on the tap's turn (gh#201 fix 3) -- it coalesces and commits once, off it"
        )
    }

    /// A single store.upsertLogRecord call's result, pinned longhand: one
    /// commit pair, with the log record's effort and the mirrored event's
    /// colorDepth both landing correctly.
    ///
    /// This test makes exactly one call to store.upsertLogRecord itself --
    /// it does NOT exercise commitEffortDrag or CalendarEventDetailView, so
    /// it cannot and does not pin that commitEffortDrag calls the store
    /// only once per gesture (gh#162 W4: an earlier revision of this
    /// comment claimed it pinned "commitEffortDrag's single call at gesture
    /// end" -- it would have stayed green even if commitEffortDrag called
    /// applyQuickEffort five times, since nothing here calls
    /// commitEffortDrag at all). That property is pinned instead by
    /// CalendarEffortDragCommitDecisionTests (the decision commitEffortDrag
    /// defers to) together with CalendarEffortScrubberGestureTests /
    /// CalendarEffortScrubberCancellationTests (onCommit firing at most
    /// once per gesture, cancellation included).
    func testSingleCommitAtReleaseMatchesOldPathsFinalState() throws {
        let store = makeStore()
        let event = Event(
            title: "Deep Work",
            timeRanges: [.init(start: Date(), end: Date().addingTimeInterval(3600))],
            type: "Study"
        )
        store.addCalendarEvent(event)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }

        // The intermediate values (1, 2, 3) a real drag would have passed
        // through never reach the store at all under the fix -- only this
        // one call, carrying the release value, does.
        store.upsertLogRecord(for: ctx) { $0.effort = 4 }

        // Write order as of gh#201 fix 3: upsertLogRecord commits the log
        // record and only the log record; the colorDepth mirror is queued
        // and commits when it flushes. The old order (calendarEvents first,
        // inside the same call) is what the fix removed.
        XCTAssertEqual(commits, [StorageSlot.calendarEventLogRecords.rawValue])

        store.flushCalendarEventColorDepthMirror()
        XCTAssertEqual(commits, [
            StorageSlot.calendarEventLogRecords.rawValue,
            StorageSlot.calendarEvents.rawValue
        ])

        let record = try XCTUnwrap(store.logRecord(for: ctx))
        XCTAssertEqual(record.effort, 4)

        let committedEvent = try XCTUnwrap(store.rawCalendarEvents.first { $0.id == event.id })
        // Event.colorDepth(forEffort: 4) = 4/5 = 0.8, written out longhand
        // rather than computed by calling Event.colorDepth(forEffort:) --
        // that function IS part of what's under test here.
        XCTAssertEqual(committedEvent.colorDepth, 0.8, accuracy: 0.0001)
    }
}

// MARK: - Leaf wiring layer (gh#162 R3)

/// CalendarEffortQuickControl (Calendar/Components/CalendarEffortQuickControl.swift)
/// is the leaf view effortQuickSection delegates to as of this round
/// (gh#162 R1). Its `body` wires CalendarEffortScrubber's `value` setter
/// to `handleLiveValueChanged` and its `onCommit` to `commitDrag` -- these
/// tests drive those two methods directly, the same reason
/// CalendarEffortScrubberGestureTests drives handleChanged/handleEnded
/// directly rather than simulating touches.
///
/// `dragValue` itself can't be read back after a call -- see that
/// property's doc comment in the leaf's own file: an unrendered View
/// struct's `@State` doesn't durably hold a write across separate calls,
/// the same failure mode the gh#162 W3 gap above documents. These tests
/// observe the one thing that IS externally visible instead: whether and
/// how `onCommit` fires.
@MainActor
final class CalendarEffortQuickControlWiringTests: XCTestCase {
    /// gh#162 R3's own regression, replayed directly one layer down: a
    /// live-value change must never itself reach `onCommit`. Reverting
    /// `handleLiveValueChanged`'s body to route through `onCommit`
    /// (mirroring the pre-fix per-step-write bug) is exactly what
    /// independent review's falsifiable check found nothing in this file
    /// catching before this test existed.
    func testLiveValueChangeNeverCallsOnCommit() {
        var commits: [Int] = []
        let control = CalendarEffortQuickControl(
            storedEffort: nil,
            tint: .accentColor,
            onCommit: { commits.append($0) }
        )

        for value in [1, 2, 3, 4, 5] {
            control.handleLiveValueChanged(value)
        }

        XCTAssertTrue(commits.isEmpty, "handleLiveValueChanged must never reach onCommit -- that IS the bug this round's falsifiable check found untested")
    }

    /// The single durable-write trigger: calling commitDrag must reach
    /// onCommit exactly once, carrying the value it was given.
    func testCommitDragCallsOnCommitExactlyOnceWithFinalValue() {
        var commits: [Int] = []
        let control = CalendarEffortQuickControl(
            storedEffort: nil,
            tint: .accentColor,
            onCommit: { commits.append($0) }
        )

        control.commitDrag(4)

        XCTAssertEqual(commits, [4])
    }

    /// A live sweep followed by a release must commit only the release --
    /// pins the two methods together the way a real gesture drives them
    /// (CalendarEffortScrubber.handleChanged repeatedly, then
    /// handleDragActiveChanged once), without needing a hosted view.
    func testSweepThenCommitProducesExactlyOneCommit() {
        var commits: [Int] = []
        let control = CalendarEffortQuickControl(
            storedEffort: nil,
            tint: .accentColor,
            onCommit: { commits.append($0) }
        )

        control.handleLiveValueChanged(2)
        control.handleLiveValueChanged(3)
        control.handleLiveValueChanged(4)
        control.commitDrag(4)

        XCTAssertEqual(commits, [4], "only the commit should reach onCommit, not each intermediate live value")
    }
}

// MARK: - Live-value precedence layer (gh#162 R4 / X1)

/// calendarEffortLiveValue(dragValue:stored:) is CalendarEffortQuickControl's
/// `liveEffort` computed property, pulled out as a pure function -- gh#162
/// round 4 independent QA found `liveEffort` completely unprotected as a
/// bare `dragValue ?? storedEffort` computed property: a mutant that made
/// it always return `storedEffort`, ignoring `dragValue`, passed the full
/// 998-test suite. The failure mode is not cosmetic: `liveEffort` is what
/// the scrubber's commit path reads (GlassCardView.swift's
/// `onCommit?(value)` reads the Binding's `get:`, which is `liveEffort`),
/// so under that mutant `commitDrag` always hands
/// `calendarEffortDragShouldCommit` the pre-drag stored value compared
/// against itself -- which always declines. No effort drag would ever
/// persist again, silently, with every test green.
///
/// These two tests are the minimum needed to pin the actual `??`
/// semantics -- one for each operand a mutant could drop:
final class CalendarEffortLiveValuePrecedenceTests: XCTestCase {
    /// Dies to a mutant that ignores `dragValue` and always returns
    /// `stored` -- gh#162 R4's own finding, replayed directly.
    func testLiveValueUsesDragValueWhenPresent() {
        XCTAssertEqual(
            calendarEffortLiveValue(dragValue: 4, stored: 2), 4,
            "a live drag preview must win over the stored value -- this is the exact line QA's mutant broke"
        )
    }

    /// Dies to a mutant that ignores `stored` and always returns
    /// `dragValue` (dropping the `??` fallback) -- with no drag active,
    /// the stored value must still show through.
    func testLiveValueFallsBackToStoredWhenDragValueIsNil() {
        XCTAssertEqual(
            calendarEffortLiveValue(dragValue: nil, stored: 3), 3,
            "with no drag active, the stored value must show through the fallback"
        )
    }

    /// Edge case both mutants above would also get right by accident if
    /// tested with this input alone -- included for completeness, not
    /// load-bearing on its own.
    func testLiveValueIsNilWhenBothAreNil() {
        XCTAssertNil(calendarEffortLiveValue(dragValue: nil, stored: nil))
    }
}
