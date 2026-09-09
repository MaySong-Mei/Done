//
//  CalendarDragRenderMemoTests.swift
//  DoneTests
//
//  Independent QA for gh#181 — the drag-render memo on CalendarDayLayerView.
//
//  The fix decouples "refresh the dragged block's frame" (renderLiveDragFrame
//  keeps nulling `cachedStructureKey`) from "invalidate the structure caches"
//  by memoizing the two drag-INVARIANT render inputs across one drag session:
//    • the `InterruptContext` (3 passes over occurrences), and
//    • the move-mode `stableSlots` (a full cluster DFS + layout).
//  The load-bearing claim is that render output is BYTE-IDENTICAL whether a
//  frame reused the memo or rebuilt from scratch. These tests prove that claim
//  three ways and pin the guardrail invariants against mutation:
//
//    1. OUTPUT EQUALITY — driven through the REAL render(_:) path with a real
//       promoted move session (so the memo actually engages). Proven by:
//         (a) the in-code #if DEBUG audit (render recomputes the memoized
//             values fresh for the first 8 reuse frames and asserts byte
//             equality) — a live runtime tripwire that fires during this
//             harnessed drag, and
//         (b) renderedFrames (the observable layer geometry) being identical
//             across reuse frames, and
//         (c) the pure-function + structureKey-gate argument below.
//    2. POSITIVE CONTROL — the LIVE overlap `slots` (never memoized) still
//       re-columns a neighbour when the dragged event moves into overlap,
//       while `dragMemoRebuilds == 1` proves the invariant part stayed frozen.
//    3. GATE MECHANISM — structureKey moves iff occurrences move (not on the
//       per-frame drag fields), and overlapLayout is a deterministic pure
//       function, so equal-key ⟹ equal-input ⟹ equal-output.
//
//  The harness drives `handleEventGesture(_:)` (a private @objc action) via
//  `perform(_:with:)` with a coordinate/state-overriding mock recognizer —
//  the only in-process way to set up a real `activeEventSession` (its backing
//  state is private-set), which the memo gate requires.
//
//  Run:
//    xcodebuild test -scheme Done \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:DoneTests/CalendarDragRenderMemoTests

import XCTest
import UIKit
@testable import Done

@MainActor
final class CalendarDragRenderMemoTests: XCTestCase {

    // MARK: - Signal capture (SpikeProbe is nil under XCTest; we own it here)

    private var savedOnSignal: ((SpikeSignal) -> Void)?
    private var captured: [SpikeSignal] = []

    override func setUp() {
        super.setUp()
        savedOnSignal = SpikeProbe.onSignal
        captured = []
        SpikeProbe.onSignal = { [weak self] signal in
            self?.captured.append(signal)
        }
    }

    override func tearDown() {
        SpikeProbe.onSignal = savedOnSignal
        savedOnSignal = nil
        captured = []
        super.tearDown()
    }

    private func rebuildCount() -> Int {
        captured.filter { $0 == .counter(Spike181SignalID.dragMemoRebuild) }.count
    }
    private func reuseCount() -> Int {
        captured.filter { $0 == .counter(Spike181SignalID.dragMemoReuse) }.count
    }

    // MARK: - Mock gesture recognizer

    /// Overrides the three things `handleEventGesture(_:)` reads: `state`,
    /// `view`, and `location(in:)`. We drive the action directly through
    /// `perform(_:with:)`, so no real UIKit gesture machinery runs.
    private final class MockLongPress: UILongPressGestureRecognizer {
        var mockState: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { mockState }
            set { mockState = newValue }
        }
        weak var mockView: UIView?
        override var view: UIView? { mockView }
        var pointInView: CGPoint = .zero
        var pointInWindow: CGPoint = .zero
        override func location(in view: UIView?) -> CGPoint {
            view == nil ? pointInWindow : pointInView
        }
    }

    // MARK: - Model / occurrence builders

    private var day: Date { Calendar.current.startOfDay(for: Date()) }

    private func makeOccurrence(
        id: String,
        startHour: Double,
        durationMinutes: Double = 60
    ) -> CalendarLayout.EventOccurrence {
        let start = day.addingTimeInterval(startHour * 3600)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(durationMinutes * 60))
        return CalendarLayout.EventOccurrence(
            id: id,
            event: Event(title: id, timeRanges: [range], type: "Study"),
            range: range
        )
    }

    private func makeModel(
        _ occurrences: [CalendarLayout.EventOccurrence]
    ) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: day,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: 16,
            hourHeight: 56,
            eventHorizontalInset: 8,
            leadingExtendedHours: 0,
            trailingExtendedHours: 0,
            drawableLeadingHours: 0,
            drawableTrailingHours: 0,
            useImperativeDayLayerModel: false,
            showEventText: true,
            isWeekMode: false,
            isThreeDayMode: false,
            titleFontSizeSetting: 13,
            showTimeBelowTitle: true,
            multiTypeEnabled: false,
            nearFutureHorizonDays: 7,
            isPinchActive: false,
            frozenSlotMinutes: nil
        )
    }

    private func makeHost(
        _ occurrences: [CalendarLayout.EventOccurrence]
    ) -> DayLayerHostView {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        host.apply(makeModel(occurrences))
        host.layoutIfNeeded()
        return host
    }

    private var eventAreaWidth: CGFloat { 360 - 8 * 2 } // contentWidth − inset*2

    // MARK: - Drive a real promoted MOVE drag

    /// Begins a long-press on `occurrenceID` and promotes it to a move drag by
    /// moving the finger `dyWindow` points down. Returns the mock recognizer so
    /// the caller can keep driving `.changed` / `.ended`.
    @discardableResult
    private func promoteMoveDrag(
        on host: DayLayerHostView,
        occurrenceID: String,
        dyWindow: CGFloat = 20
    ) -> MockLongPress {
        let controller = host.gestureController
        guard let rf = host.renderedFrames[occurrenceID] else {
            XCTFail("no rendered frame for \(occurrenceID) — apply/layout must run first")
            return MockLongPress()
        }
        let center = CGPoint(x: rf.frame.midX, y: rf.frame.midY)

        let g = MockLongPress()
        g.mockView = host
        g.pointInView = center
        g.pointInWindow = center

        // .began — lands on the block, mode resolves to .move (centre touch).
        g.mockState = .began
        controller.perform(NSSelectorFromString("handleEventGesture:"), with: g)

        // .changed — cross the 8pt promotion threshold straight down.
        g.mockState = .changed
        g.pointInWindow = CGPoint(x: center.x, y: center.y + dyWindow)
        controller.perform(NSSelectorFromString("handleEventGesture:"), with: g)

        XCTAssertNotNil(
            controller.activeEventSession,
            "drag did not promote — activeEventSession is nil (mode=\(controller.activeEventSession?.mode as Any))"
        )
        XCTAssertEqual(controller.activeEventSession?.occurrenceID, occurrenceID)
        XCTAssertEqual(controller.activeEventSession?.mode, .move)
        return g
    }

    private func moveDrag(_ g: MockLongPress, on host: DayLayerHostView, toWindowDy dy: CGFloat) {
        g.mockState = .changed
        g.pointInWindow = CGPoint(x: g.pointInView.x, y: g.pointInView.y + dy)
        host.gestureController.perform(NSSelectorFromString("handleEventGesture:"), with: g)
    }

    private func endDrag(_ g: MockLongPress, on host: DayLayerHostView) {
        g.mockState = .ended
        host.gestureController.perform(NSSelectorFromString("handleEventGesture:"), with: g)
    }

    /// Compare two renderedFrames dictionaries by the observable geometry
    /// (frame + overlap slot) for every id. This is the "layer geometry" the
    /// day view actually paints from.
    private func assertRenderedFramesByteIdentical(
        _ a: [String: DayLayerHostView.RenderedEventFrame],
        _ b: [String: DayLayerHostView.RenderedEventFrame],
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Set(a.keys), Set(b.keys), "\(message): id set differs", file: file, line: line)
        for (id, ra) in a {
            guard let rb = b[id] else { continue }
            XCTAssertEqual(ra.frame, rb.frame, "\(message): frame差 for \(id)", file: file, line: line)
            XCTAssertEqual(ra.slot, rb.slot, "\(message): slot差 for \(id)", file: file, line: line)
            XCTAssertEqual(ra.isEmbeddedChild, rb.isEmbeddedChild, "\(message): embedded差 for \(id)", file: file, line: line)
        }
    }

    // MARK: - 1. OUTPUT EQUALITY (real render path, memo engaged)

    // NOTE on counter semantics (confirmed empirically): render(_:) emits
    // EXACTLY ONE Spike181 counter per render. A non-drag render (initial
    // apply, static repaint) has no session, so `dragMemoReusable` is false
    // and it emits `dragMemoRebuild` — correct, there is no memo to reuse when
    // not dragging. So to measure the DRAG-PERIOD shape the task specifies
    // ("rebuild == distinct structureKeys ≈ 1, reuse == frames − 1") we reset
    // the capture buffer at the drag's first frame and count from there.

    /// The load-bearing test. Drive a real promoted move drag, then generate
    /// many extra full render frames the way edge-autoscroll does
    /// (`renderLiveDragFrame()` each tick). Assert:
    ///   • exactly ONE rebuild across the whole stable-structureKey session,
    ///     with the rest reuses (the harness "log" the task requires),
    ///   • the observable layer geometry is byte-identical across reuse frames,
    ///   • completing >8 reuse frames means the in-code #if DEBUG audit
    ///     (fresh-recompute == memo, asserted) ran and passed — the runtime
    ///     byte-equality tripwire.
    func testMemoReuseFramesAreByteIdenticalAndCountedOnce() {
        // Two statically-overlapping events so both interrupt-context and a
        // non-trivial equalSplit stableSlots are exercised.
        let a = makeOccurrence(id: "A", startHour: 9, durationMinutes: 90)   // 9:00–10:30
        let b = makeOccurrence(id: "B", startHour: 9.5, durationMinutes: 90) // 9:30–11:00
        let host = makeHost([a, b])

        captured.removeAll() // discard the initial static-apply render's counter
        let g = promoteMoveDrag(on: host, occurrenceID: "A") // first drag frame: 1 rebuild

        // Snapshot after promotion, then run 15 more identical drag frames.
        let firstReuse = host.renderedFrames
        for _ in 0..<15 { host.renderLiveDragFrame() }
        let lastReuse = host.renderedFrames
        _ = g

        // Nothing changed between these frames (no finger movement), and the
        // #if DEBUG audit re-derived the memo fresh for the first 8 of them.
        assertRenderedFramesByteIdentical(
            firstReuse, lastReuse,
            "reuse frames diverged — memo is not byte-stable across the session"
        )

        // Exactly one rebuild for the whole session (structureKey never moved);
        // everything else reused. This is the healthy shape gh#181 describes.
        XCTAssertEqual(rebuildCount(), 1, "expected exactly one rebuild for a stable-key drag session")
        XCTAssertEqual(reuseCount(), 15, "the 15 extra frames must all be reuses")
    }

    /// The memo must survive the exact edge-autoscroll shape it exists for:
    /// `renderLiveDragFrame()` nulls `cachedStructureKey` every frame. Prove
    /// that null-out does NOT cost a rebuild — only the very first frame does.
    func testAutoscrollNullingStructureKeyDoesNotForceRebuild() {
        let a = makeOccurrence(id: "A", startHour: 9)
        let host = makeHost([a])
        captured.removeAll() // count only the drag period
        _ = promoteMoveDrag(on: host, occurrenceID: "A") // 1 rebuild (first frame)

        for _ in 0..<40 { host.renderLiveDragFrame() } // 40 "autoscroll ticks"
        XCTAssertEqual(rebuildCount(), 1,
                       "renderLiveDragFrame's cachedStructureKey null-out must not discard the drag memo — only the first frame rebuilds")
        XCTAssertEqual(reuseCount(), 40, "all 40 autoscroll ticks must reuse the memo")
    }

    // MARK: - 2. POSITIVE CONTROL (the live part still moves)

    /// The memo freezes ONLY the drag-invariant inputs. The LIVE overlap
    /// `slots` (fed the finger-tracked range) is recomputed every frame and
    /// must still re-column a neighbour when the dragged event moves into
    /// overlap — otherwise the fix would have frozen something it must not.
    /// Simultaneously `dragMemoRebuilds` stays 1, proving the invariant part
    /// really was reused throughout.
    func testLiveSlotsStillRecolumnNeighbourWhileMemoStaysFrozen() {
        // A and B far apart → no static overlap → both full width to start.
        let a = makeOccurrence(id: "A", startHour: 8)   // 8:00–9:00
        let b = makeOccurrence(id: "B", startHour: 13)  // 13:00–14:00
        let host = makeHost([a, b])

        captured.removeAll() // count only the drag period
        // Promote with a small move so A stays ~8:00 (B still full width).
        let g = promoteMoveDrag(on: host, occurrenceID: "A", dyWindow: 20)
        let bWidthBefore = host.renderedFrames["B"]!.frame.width
        XCTAssertEqual(bWidthBefore, eventAreaWidth, accuracy: 1.0,
                       "B should be full width before A overlaps it")

        // Drag A down ~5h (5 * hourHeight = 280pt) so its LIVE range overlaps B.
        moveDrag(g, on: host, toWindowDy: 5 * 56)
        let bWidthAfter = host.renderedFrames["B"]!.frame.width

        XCTAssertLessThan(bWidthAfter, bWidthBefore * 0.75,
                          "the live overlap slots did NOT recolumn B — the memo froze something it must not")

        // The invariant part was reused the whole time: occurrence identity
        // never changed, so exactly one rebuild.
        XCTAssertEqual(rebuildCount(), 1,
                       "structureKey never changed, so the invariant memo must have been reused (1 rebuild)")
    }

    /// Pure-function witness for the same claim, independent of the render
    /// path: overlapLayout genuinely produces different slots when the ranges
    /// overlap vs not — so a frozen `slots` WOULD be wrong. (The fix never
    /// freezes `slots`; this pins that the difference is real.)
    func testOverlapLayoutSlotsDependOnRangesThatChangeUnderTheFinger() {
        let start = day.addingTimeInterval(8 * 3600)
        let aApart = CalendarLayout.EventOccurrence(
            id: "A", event: Event(title: "A", timeRanges: [], type: "x"),
            range: Event.TimeRange(start: start, end: start.addingTimeInterval(3600)))
        let b = CalendarLayout.EventOccurrence(
            id: "B", event: Event(title: "B", timeRanges: [], type: "x"),
            range: Event.TimeRange(start: start.addingTimeInterval(5 * 3600),
                                   end: start.addingTimeInterval(6 * 3600)))
        let aOver = CalendarLayout.EventOccurrence(
            id: "A", event: aApart.event,
            range: Event.TimeRange(start: start.addingTimeInterval(5 * 3600),
                                   end: start.addingTimeInterval(6 * 3600)))
        let vs = day, ve = day.addingTimeInterval(24 * 3600)
        let apart = CalendarLayout.overlapLayout(for: [aApart, b], visibleStart: vs, visibleEnd: ve, mode: .equalSplit)
        let over = CalendarLayout.overlapLayout(for: [aOver, b], visibleStart: vs, visibleEnd: ve, mode: .equalSplit)
        XCTAssertEqual(apart["B"]?.widthFraction, 1.0, "B alone → full")
        XCTAssertEqual(over["B"]?.widthFraction, 0.5, "B overlapped → half")
        XCTAssertNotEqual(apart["B"], over["B"])
    }

    // MARK: - 3. GATE MECHANISM (structureKey is the right invariant)

    /// The memo key is `structureKey`. It must NOT move on the per-frame drag
    /// fields (or the memo would needlessly rebuild every frame — no fix), and
    /// it MUST move when occurrences change (or a stale layout would be reused
    /// — mutant #1). Both halves proven here at the type level.
    func testStructureKeyIsInvariantToDragFieldsButMovesWithOccurrences() {
        let a = makeOccurrence(id: "A", startHour: 9)
        let b = makeOccurrence(id: "B", startHour: 10)
        let base = makeModel([a, b])

        // Drag-only / per-frame fields must NOT change the key.
        var dragScaled = base
        dragScaled.hourHeight = 999
        dragScaled.drawableLeadingHours = 7
        dragScaled.drawableTrailingHours = 7
        dragScaled.dragPreviewDayStep = 42
        dragScaled.isPinchActive = true
        XCTAssertEqual(base.structureKey, dragScaled.structureKey,
                       "per-frame drag/scale fields must be OUTSIDE structureKey")

        // Removing an occurrence MUST change the key (mutant #1's premise).
        let removed = makeModel([a])
        XCTAssertNotEqual(base.structureKey, removed.structureKey,
                          "dropping an occurrence must move the key so the memo invalidates")

        // Adding one MUST change the key.
        let added = makeModel([a, b, makeOccurrence(id: "C", startHour: 11)])
        XCTAssertNotEqual(base.structureKey, added.structureKey)

        // Moving an occurrence's range MUST change the key.
        let movedB = makeModel([a, makeOccurrence(id: "B", startHour: 15)])
        XCTAssertNotEqual(base.structureKey, movedB.structureKey)
    }

    /// The memoized computations are deterministic pure functions of their
    /// inputs — the premise that makes "reuse == recompute" true. Same inputs,
    /// twice, byte-identical output.
    func testOverlapLayoutIsDeterministic() {
        let occs = [
            makeOccurrence(id: "A", startHour: 9, durationMinutes: 120),
            makeOccurrence(id: "B", startHour: 9.5, durationMinutes: 60),
            makeOccurrence(id: "C", startHour: 10, durationMinutes: 90),
        ]
        let vs = day, ve = day.addingTimeInterval(24 * 3600)
        let first = CalendarLayout.overlapLayout(for: occs, visibleStart: vs, visibleEnd: ve, mode: .equalSplit)
        let second = CalendarLayout.overlapLayout(for: occs, visibleStart: vs, visibleEnd: ve, mode: .equalSplit)
        XCTAssertEqual(first, second, "overlapLayout must be a deterministic pure function")
    }

    // MARK: - Mutation targets (documented so a mutation shows RED here)

    /// MUTANT #1 (memo survives a structureKey change): drop the
    /// `cachedDragStableKey == model.structureKey` clause from the reuse gate.
    /// Then a mid-session occurrence change reuses a STALE `stableSlots`, so
    /// the dragged block keeps its old (split) column instead of widening.
    ///
    /// Correct code: after B is removed mid-drag, A is alone → its column is
    /// full width. A stale memo would keep A at half width → this test RED.
    func testDraggedBlockColumnRebuildsWhenOccurrencesChangeMidDrag() {
        let a = makeOccurrence(id: "A", startHour: 9, durationMinutes: 90)   // overlaps B
        let b = makeOccurrence(id: "B", startHour: 9.5, durationMinutes: 90)
        let host = makeHost([a, b])
        captured.removeAll() // count only the drag period
        _ = promoteMoveDrag(on: host, occurrenceID: "A") // rebuild #1 for {A,B}

        // While A overlaps B, A's move-mode column comes from stableSlots →
        // half width.
        let widthWithB = host.renderedFrames["A"]!.frame.width
        XCTAssertEqual(widthWithB, eventAreaWidth * 0.5, accuracy: 2.0,
                       "A should be half width while it statically overlaps B")

        // Remove B mid-session (structureKey changes) and render again.
        host.apply(makeModel([a]))
        host.renderLiveDragFrame()
        let widthAlone = host.renderedFrames["A"]!.frame.width

        // Correct code rebuilt stableSlots for {A} alone → full width.
        XCTAssertEqual(widthAlone, eventAreaWidth, accuracy: 2.0,
                       "A must widen to full when B leaves — a stale memo would keep it half")
        // The structureKey change forced at least one more rebuild.
        XCTAssertGreaterThanOrEqual(rebuildCount(), 2,
                                    "the mid-session occurrence change must cost a rebuild")
    }

    /// MUTANT #2 (memo leaks into a non-drag render): remove the
    /// `activeSession != nil` gate clause AND neuter the clears. Then a render
    /// on the drag path AFTER the session ended reuses the stale memo (and
    /// trips the in-code `assert(overlapMode == .equalSplit)`). Correct code
    /// clears the memo at finalize, so a post-end render REBUILDS.
    func testPostSessionRenderRebuildsAndDoesNotReuse() {
        let a = makeOccurrence(id: "A", startHour: 9)
        let host = makeHost([a])
        let g = promoteMoveDrag(on: host, occurrenceID: "A")
        for _ in 0..<5 { host.renderLiveDragFrame() }
        XCTAssertGreaterThanOrEqual(reuseCount(), 5)

        // End the session (finalizeTouchInteraction clears the memo).
        endDrag(g, on: host)
        XCTAssertNil(host.gestureController.activeEventSession)

        // A stray drag-path render now that the session is over must REBUILD,
        // never reuse — the memo belongs to the session that just ended.
        captured.removeAll()
        host.renderLiveDragFrame()
        XCTAssertEqual(reuseCount(), 0,
                       "a render after the session ended must NOT reuse the ended session's memo")
        XCTAssertEqual(rebuildCount(), 1,
                       "the post-session render must rebuild (activeSession == nil)")
    }

    /// MUTANT #3 (rebuild counter not wired to the memo): make the emit always
    /// send `dragMemoRebuild`. Then a stable-key session shows rebuilds ==
    /// frames and reuses == 0, so `testMemoReuseFramesAreByteIdenticalAndCountedOnce`
    /// and this both go RED. This one pins the harness "log" itself.
    func testReuseIsObservedNotJustRebuild() {
        let a = makeOccurrence(id: "A", startHour: 9)
        let host = makeHost([a])
        captured.removeAll() // count only the drag period
        _ = promoteMoveDrag(on: host, occurrenceID: "A")
        for _ in 0..<10 { host.renderLiveDragFrame() }
        // If the counter were hard-wired to rebuild, reuseCount() would be 0.
        XCTAssertEqual(reuseCount(), 10, "reuse frames must be observable, not only rebuilds")
        XCTAssertEqual(rebuildCount(), 1)
    }
}
