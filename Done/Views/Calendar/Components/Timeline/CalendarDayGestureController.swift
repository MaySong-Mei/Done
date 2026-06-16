//
//  CalendarDayGestureController.swift
//  Done
//
//  Drives move / resize / drag-to-create / edge-auto-scroll / boundary-
//  paging / absorption / tap-deselect on a persistent `DayLayerHostView`.
//  Extracted from `CalendarDayLayerView.swift` (#69) — no behavior change.
//
//  This file contains:
//    - `CalendarDayGestureController: NSObject, UIGestureRecognizerDelegate`
//      — the UIKit-state home for live drag state machines (S4).
//    - `TracingLongPressGesture: UILongPressGestureRecognizer` — long-press
//      recognizer with an explicit `isDragPromoted` flag so a
//      `touchesCancelled` after promotion can be absorbed (G-30).
//

import SwiftUI

// MARK: - Gesture controller (S4)

/// Drives move / resize / drag-to-create / edge-auto-scroll / boundary-paging
/// / absorption-drop-targeting / tap-deselect on a persistent `DayLayerHostView`.
///
/// This is the UIKit-state home the spec demands (05 section 7, 06 G-79..81):
/// the live drag offset, the decided drag mode, the captured scroll-view refs,
/// and the accumulated auto-scroll compensation all live here as plain fields
/// — never in `@Published` — so a SwiftUI content rebuild cannot destroy them
/// mid-drag and per-frame writes never invalidate the host body. Only the
/// COARSE fields (`draggingEventID`, `currentDropTargetEventID`, `dragMode`,
/// edge flags, touch point) mirror back into the observed `EventDragState`.
///
/// The pure logic (mode resolution, promotion gate, snap math, auto-scroll
/// curve + compensation, boundary-page offset, drag→time mapping, terminal
/// state, adjacent snap) is REUSED verbatim from the shared free functions —
/// the SwiftUI `EventBlockDragGesture.Coordinator` and `CreationDragGesture`
/// call the same ones, so there is one source of truth and no parity drift.
final class CalendarDayGestureController: NSObject, UIGestureRecognizerDelegate {

    private weak var host: DayLayerHostView?
    var callbacks = DayLayerHostView.Callbacks()

    // Recognizers (G-1, G-46). Event drag uses the 0.35s manipulation hold;
    // create uses the 0.5s wired duration; tap is the empty-space deselect.
    private var eventGesture: TracingLongPressGesture?
    private var createGesture: UILongPressGestureRecognizer?
    private var tapGesture: UITapGestureRecognizer?

    init(host: DayLayerHostView) {
        self.host = host
    }

    func installGestures(on view: DayLayerHostView) {
        let event = TracingLongPressGesture(target: self, action: #selector(handleEventGesture(_:)))
        event.minimumPressDuration = calendarEventManipulationLongPressDuration // 0.35
        event.delegate = self
        view.addGestureRecognizer(event)
        eventGesture = event

        let create = UILongPressGestureRecognizer(target: self, action: #selector(handleCreateGesture(_:)))
        create.minimumPressDuration = 0.5 // wired value (G-46)
        create.delegate = self
        view.addGestureRecognizer(create)
        createGesture = create

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        tapGesture = tap
    }

    deinit {
        // Terminal recovery (G-32): synthesize a `.cancelled` if a drag was
        // mid-flight so the host never sees a nil `onDragEnded`.
        if calendarDragGestureNeedsTerminalRecovery(
            hasActiveGesture: activeGesture != nil,
            isDragging: eventSession != nil,
            hasMovedAfterLongPress: hasMovedAfterLongPress,
            hasPromotedManipulation: hasPromotedManipulation,
            dragOffset: liveResolvedOffset,
            isHorizontalEdgeDragging: mirroredEdgeDragging,
            isHorizontalAutoScrolling: mirroredAutoScrolling
        ) {
            if let session = eventSession {
                callbacks.onEventLongPressResolved?(
                    CalendarEventLongPressResolution(
                        event: session.event,
                        occurrenceID: session.occurrenceID,
                        actionDate: session.originalRange.start,
                        dragMode: session.mode,
                        terminalState: .cancelled,
                        didMove: hasMovedAfterLongPress,
                        touchPointGlobal: lastLocationInWindow
                    )
                )
            }
            calendarResetSharedEventDragStateIfPresent()
        }
        stopAutoScroll()
        restoreScrollPanGestures()
    }

    /// Window-detach teardown (blocker #1): invalidate BOTH `CADisplayLink`s
    /// (move/resize auto-scroll + creation auto-scroll) — each retains `self`
    /// as its `target:`, so an unstopped link outliving the view detach would
    /// keep this controller (and the host) alive past `deinit`. Also cleanly
    /// terminate any in-flight drag (synthesizing a `.cancelled` resolution so
    /// the host never sees a dropped `onDragEnded`) and reset creation state.
    /// Idempotent and crash-safe: `stopAutoScroll`/`stopCreationAutoScroll`
    /// invalidate-then-nil their link, so a second call is a no-op (no
    /// double-invalidate).
    func cancelActiveInteractionsOnDetach() {
        // 1. Kill both display links first so no further ticks fire mid-teardown.
        stopAutoScroll()
        stopCreationAutoScroll()

        // 2. Cleanly resolve ANY in-flight session — promoted (a live
        //    move/resize) OR merely STAGED (an unpromoted long-press that has
        //    already fired `onEventLongPressBegan`, raising focus / the
        //    express menu at the TimelineView level). Both the normal gesture
        //    terminal (the `.ended/.cancelled/.failed` handler) and `deinit`
        //    fire `onEventLongPressResolved` for the unpromoted case to clear
        //    that staged host state; if we resolved only promoted sessions
        //    here, a detach-while-staged (column recycled, so `deinit` may
        //    never run) would strand the host's focus/menu state forever.
        //    Mirror `deinit`'s `.cancelled` / `didMove: hasMovedAfterLongPress`
        //    form (`hasMovedAfterLongPress` is false for a staged press) and
        //    only reset the SHARED drag scratchpad for a promoted drag (a
        //    staged press never wrote it — `syncSharedDragStateForBegin` runs
        //    only on promotion).
        if let session = eventSession {
            let resolution = CalendarEventLongPressResolution(
                event: session.event,
                occurrenceID: session.occurrenceID,
                actionDate: session.originalRange.start,
                dragMode: session.mode,
                terminalState: .cancelled,
                didMove: hasMovedAfterLongPress,
                touchPointGlobal: lastLocationInWindow
            )
            // Re-entrancy (finding #4): unlike `deinit` (which runs at dealloc,
            // outside any view-update pass), this runs synchronously inside
            // `didMoveToWindow`, which is typically invoked DURING a SwiftUI-
            // driven view-hierarchy mutation. Firing the resolution here would
            // mutate TimelineView's focus / express-menu @State mid-update
            // ("Modifying state during view update" hazard). Defer it one
            // runloop tick so the write lands after the current update settles.
            // We capture the resolution closure by VALUE (not via `self`), so
            // the callback still fires even if this controller / host is torn
            // down before the tick — closing the dropped-resolution gap the
            // task flagged. Resetting the SHARED scratchpad (a promoted-only
            // concern) likewise rides the tick.
            let resolved = callbacks.onEventLongPressResolved
            let dragStateToReset = hasPromotedManipulation ? callbacks.dragState : nil
            DispatchQueue.main.async {
                resolved?(resolution)
                if let dragStateToReset {
                    calendarResetSharedEventDragState(dragStateToReset)
                }
            }
        }
        eventSession = nil
        finalizeTouchInteraction()

        // 3. Reset any in-flight drag-to-create.
        if isCreating || isLongPressingCreation {
            resetCreationState()
        }
    }

    // MARK: Active session exposed to the renderer

    /// Identity + base range + mode of the actively dragged occurrence, read
    /// by the host to render the live preview block. Set ONLY after the drag
    /// promotes past 8pt (G-13); nil during a staged long-press or no drag.
    struct EventSession {
        let event: Event
        let occurrenceID: String
        let originalRange: Event.TimeRange
        var mode: EventDragMode
    }
    private(set) var eventSession: EventSession?
    /// Exposed to the renderer only once promoted (so the static block doesn't
    /// jump before the 8pt threshold).
    var activeEventSession: EventSession? { hasPromotedManipulation ? eventSession : nil }
    /// The resolved (snapped / clamped) live offset for the current frame.
    private(set) var liveResolvedOffset: DragOffset = .zero

    // MARK: Plain UIKit drag state (mirrors EventBlock.Coordinator fields)

    private weak var activeGesture: UILongPressGestureRecognizer?
    private var initialPointInWindow: CGPoint = .zero
    private var lastLocationInWindow: CGPoint = .zero
    private var autoScrollCompensationX: CGFloat = 0
    private var autoScrollCompensationY: CGFloat = 0
    private weak var horizontalScrollView: UIScrollView?
    private weak var verticalScrollView: UIScrollView?
    private var autoScrollVelocityX: CGFloat = 0
    private var autoScrollVelocityY: CGFloat = 0
    private var autoScrollDisplayLink: CADisplayLink?
    private var isHorizontalSnapSuppressed = false
    private var hasMovedAfterLongPress = false
    private var hasPromotedManipulation = false
    private var currentMode: EventDragMode = .move
    private var lastSnappedStep = 0
    private var verticalDragBounds: ClosedRange<CGFloat> = -.infinity ... .infinity
    private var lastHorizontalBoundaryPageTimestamp: CFTimeInterval = 0
    private let horizontalBoundaryPageMinimumInterval: CFTimeInterval = 0.8
    private var horizontalBoundaryPageCount = 0
    private var horizontalBoundaryPageOriginX: CGFloat = 0
    private var disabledScrollGestures: [(gesture: UIGestureRecognizer, wasEnabled: Bool)] = []
    private var savedCanCancelContentTouches: [(scrollView: UIScrollView, wasEnabled: Bool)] = []
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private var mirroredEdgeDragging = false
    private var mirroredAutoScrolling = false

    // Floating cross-day drag chip (move-only). A single window-space UIView
    // that follows the finger; snaps its X to the day-column under the finger
    // while horizontal snap is NOT suppressed, free-follows the finger while it
    // is (edge / auto-scroll). Rendered above all columns so it never clips.
    private var dragChip: UIView?
    private var chipGrabOffset: CGSize = .zero      // finger→block-center at promotion (window space)
    private var chipSourceSize: CGSize = .zero
    private var chipSourceImage: UIImage?           // source-width snapshot, restored in free mode
    private var lastSnappedColumnCenterX: CGFloat?  // avoid re-springing every frame
    private(set) var isChipActive = false
    // #53A experimental: drop the floating chip entirely and rely on the
    // in-grid synth-preview projections (source + every sibling the live
    // range touches) as the sole visual feedback. Uniform N-column logic,
    // no chip-vs-projection split. Flip to `true` to re-enable the chip.
    private let chipEnabled = false
    // Weak handle so the fan-out list can survive host recycle without
    // retain cycles.
    private struct WeakHostRef {
        weak var host: DayLayerHostView?
    }
    // The hosts currently showing an in-grid drag preview / foreign drag
    // signal for the active session. ONE source-day target (the column under
    // the finger) plus zero or more SIBLINGS that share a cross-midnight
    // window with the dragged event (#53 sub-bug A — mirror of
    // `creationPreviewByDay`'s per-day fan-out for drag-to-create at
    // TimelineView.swift:2504-2533). Cleared on day-change / end / cancel,
    // and re-built every drag frame so a column the live range LEAVES is
    // cleared (not frozen on its last clip), and a column the live range
    // newly ENTERS is painted.
    private var lastPreviewHosts: [WeakHostRef] = []
    // #53A: chip-as-finger-tracking-projection refresh throttle. Snapshot
    // (UIGraphicsImageRenderer over a CALayer tree) is expensive; refresh only
    // when the underlying preview's visual fingerprint changes (range +
    // hourHeight + slot). `lastChipSnapSize` caches the snap dimensions so the
    // chip can apply them every frame for animation continuity without
    // re-snapshotting.
    private var lastChipSnapFingerprint: String?
    private var lastChipSnapSize: CGSize?

    // Creation drag state (mirrors CreationDragGesture consumer @State).
    private var isCreating = false
    private var isLongPressingCreation = false
    private var creationStartY: CGFloat = 0
    private var creationCurrentY: CGFloat = 0
    private var lastTickMinutes = -1
    private var lastSnappedStartEdge: Date?
    private var lastSnappedEndEdge: Date?
    private var creationAutoScrollLink: CADisplayLink?
    private let creationActivationThreshold: CGFloat = 18
    private let adjacentEventSnapThresholdPt: CGFloat = 8
    private let createHaptic = UIImpactFeedbackGenerator(style: .light)
    private let snapHaptic = UISelectionFeedbackGenerator()

    private var usesHorizontalBoundaryPaging: Bool {
        guard let m = host?.liveModel else { return false }
        return m.dayColumnStep <= 0 && m.dragPreviewDayStep > 0
    }
    private var dayColumnStep: CGFloat { host?.liveModel?.dayColumnStep ?? 0 }
    private var dragPreviewDayStep: CGFloat { host?.liveModel?.dragPreviewDayStep ?? 0 }

    private func calendarResetSharedEventDragStateIfPresent() {
        if let dragState = callbacks.dragState {
            calendarResetSharedEventDragState(dragState)
        }
    }

    // MARK: Hit testing

    /// Returns the occurrence under `pointInView` honoring the same
    /// fall-through inset as the SwiftUI hit area (G-3/4/5): a touch in the
    /// top/bottom edge band of a block falls through to drag-to-create.
    /// Topmost (deepest z) wins.
    private func eventOccurrence(at pointInView: CGPoint) -> DayLayerHostView.RenderedEventFrame? {
        guard let host else { return nil }
        var best: (frame: DayLayerHostView.RenderedEventFrame, z: CGFloat)?
        for (id, rf) in host.renderedFrames {
            // Cross-midnight sibling-paint frames (id suffix `#preview`) are
            // visual-only; gesture ownership stays with the source host's
            // active session (#53 sub-bug A). Excluding them from hit-test
            // means a touch over a sibling preview falls through to
            // drag-create on empty canvas instead of starting a second drag.
            if id.hasSuffix("#preview") { continue }
            let frame = rf.frame
            guard frame.contains(pointInView) else { continue }
            // Fall-through edge inset (smoothstep) — only blocks without
            // visible resize handles use the 6pt band; focused/grace blocks
            // keep their full edge so handles stay hittable.
            let showsHandles = host.liveModel.map { model in
                calendarEventShowsResizeHandles(
                    focusedEventID: model.focusedEventID,
                    focusedOccurrenceID: model.focusedOccurrenceID,
                    graceResizeEventID: model.graceResizeEventID,
                    graceResizeOccurrenceID: model.graceResizeOccurrenceID,
                    eventID: rf.occurrence.event.id,
                    occurrenceID: rf.occurrence.id
                )
            } ?? false
            let inset = showsHandles ? 0 : calendarFallThroughEdgeInsetPublic(maxInset: 6, height: frame.height)
            if inset > 0 {
                let band = frame.insetBy(dx: 0, dy: inset)
                if !band.contains(pointInView) { continue }
            }
            let z = CGFloat(rf.slot.zIndex) + (rf.isEmbeddedChild ? 1000 : 0)
            if best == nil || z > best!.z {
                best = (rf, z)
            }
        }
        return best?.frame
    }

    // MARK: Delegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Event drag: coexist only AFTER promotion so nothing cancels an
        // active drag, but stay exclusive before (G-34). Create gesture is
        // exclusive (G-46).
        if gestureRecognizer === eventGesture {
            return hasPromotedManipulation
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let host, let view = gestureRecognizer.view else { return true }
        let point = gestureRecognizer.location(in: view)
        let hit = eventOccurrence(at: point)
        // Route the touch: event gesture begins only over a block; the
        // create / tap gestures begin only on empty canvas (mirrors the
        // SwiftUI layering where the creation layer sits beneath events and
        // the fall-through inset hands edge-band touches to it).
        if gestureRecognizer === eventGesture {
            // Suppress during pinch (G-2/71) and require an interaction-allowed
            // block (focus gating, G-81).
            if host.liveModel?.isPinchActive == true { return false }
            return hit != nil && isInteractionAllowed(for: hit!)
        }
        if gestureRecognizer === createGesture {
            return hit == nil && callbacks.onCreateEvent != nil
        }
        if gestureRecognizer === tapGesture {
            // Tap handles BOTH cases (see handleTap): over a block → onEventTap
            // (open detail); empty canvas → onNonEventTap. Gating this to
            // `hit == nil` dead-ended the event-tap branch, so tapping an event
            // opened nothing. A quick tap and the 0.35s event long-press are
            // mutually exclusive by timing, so beginning over a block is safe.
            return true
        }
        return true
    }

    private func isInteractionAllowed(for hit: DayLayerHostView.RenderedEventFrame) -> Bool {
        guard let model = host?.liveModel else { return true }
        return calendarShouldAllowEventInteraction(
            focusedEventID: model.focusedEventID,
            candidateEventID: hit.occurrence.event.id,
            isFocusContextActive: model.isFocusContextActive
        )
    }

    // MARK: Tap (G-53, G-63)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let host, let view = gesture.view else { return }
        let point = gesture.location(in: view)
        if let hit = eventOccurrence(at: point) {
            callbacks.onEventTap?(hit.occurrence.event, hit.occurrence.range.start)
        } else {
            callbacks.onNonEventTap?()
        }
        _ = host
    }

    // MARK: Event move / resize (G-6..G-34)

    @objc private func handleEventGesture(_ gesture: UILongPressGestureRecognizer) {
        guard let host, let view = gesture.view else { return }
        let location = gesture.location(in: view)

        switch gesture.state {
        case .began:
            guard let hit = eventOccurrence(at: location) else { return }
            initialPointInWindow = gesture.location(in: nil)
            lastLocationInWindow = initialPointInWindow
            activeGesture = gesture
            let targets = findScrollTargets(startingAt: view)
            horizontalScrollView = targets.horizontal
            verticalScrollView = targets.vertical
            autoScrollCompensationX = 0
            autoScrollCompensationY = 0
            autoScrollVelocityX = 0
            autoScrollVelocityY = 0
            isHorizontalSnapSuppressed = false
            hasMovedAfterLongPress = false
            hasPromotedManipulation = false
            lastSnappedStep = 0
            lastHorizontalBoundaryPageTimestamp = 0
            horizontalBoundaryPageCount = 0
            horizontalBoundaryPageOriginX = initialPointInWindow.x
            liveResolvedOffset = .zero

            // Mode decided ONCE from view-local touch position (G-8, G-85).
            let frame = hit.frame
            let localX = location.x - frame.minX
            let localY = location.y - frame.minY
            let canResizeTop = canResizeTop(for: hit)
            let canResizeBottom = canResizeBottom(for: hit)
            currentMode = calendarResolveDragMode(
                locationX: localX,
                locationY: localY,
                viewWidth: frame.width,
                viewHeight: frame.height,
                edgeThreshold: 10,
                canResizeTop: canResizeTop,
                canResizeBottom: canResizeBottom
            )
            verticalDragBounds = computedVerticalDragBounds(for: hit)
            eventSession = EventSession(
                event: hit.occurrence.event,
                occurrenceID: hit.occurrence.id,
                originalRange: hit.occurrence.range,
                mode: currentMode
            )

            let frameInWindow = view.convert(frame, to: nil)
            callbacks.onEventLongPressBegan?(
                CalendarEventLongPressBegan(
                    event: hit.occurrence.event,
                    occurrenceID: hit.occurrence.id,
                    actionDate: hit.occurrence.range.start,
                    dragMode: currentMode,
                    touchPointGlobal: initialPointInWindow,
                    eventFrameGlobal: frameInWindow
                )
            )
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        case .changed:
            guard let session = eventSession else { return }
            let raw = gesture.location(in: nil)
            lastLocationInWindow = raw
            let dx = raw.x - initialPointInWindow.x
            let dy = raw.y - initialPointInWindow.y
            let crossed = hypot(dx, dy) > 8

            if !hasPromotedManipulation {
                guard calendarShouldPromoteLongPressToManipulation(
                    dragMode: currentMode,
                    movementExceededThreshold: crossed
                ) else {
                    stopAutoScroll()
                    return
                }
                hasMovedAfterLongPress = true
                hasPromotedManipulation = true
                (gesture as? TracingLongPressGesture)?.isDragPromoted = true
                disableScrollPanGesturesForDrag()
                // Snapshot the rendered source block at promotion. ALWAYS
                // captured, even in chip-less mode — the autoscroll chip
                // (#53A) spawns lazily on edge auto-scroll using these
                // stored fields. In `chipEnabled` mode the chip is also
                // spawned right here at promotion as the always-on visual.
                if currentMode == .move,
                   let snap = host.snapshotDraggedOccurrence(session.occurrenceID) {
                    chipSourceSize = snap.windowRect.size
                    chipSourceImage = snap.image
                    chipGrabOffset = CGSize(
                        width: initialPointInWindow.x - snap.windowRect.midX,
                        height: initialPointInWindow.y - snap.windowRect.midY
                    )
                    if chipEnabled, dragChip == nil, let window = host.window {
                        let chip = UIImageView(image: snap.image)
                        chip.frame = snap.windowRect
                        chip.contentMode = .scaleToFill
                        chip.layer.shadowColor = UIColor.black.cgColor
                        chip.layer.shadowOpacity = 0.22
                        chip.layer.shadowRadius = 8
                        chip.layer.shadowOffset = CGSize(width: 0, height: 3)
                        chip.alpha = 0.97
                        chip.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
                        window.addSubview(chip)
                        dragChip = chip
                        isChipActive = true
                        lastSnappedColumnCenterX = nil
                        host.renderLiveDragFrame()
                        updateChipPosition()
                    }
                }
                // Callback order matches the SwiftUI path (G-15):
                // onManipulationPromotion (resets menu + sets focus, reading
                // the touch point) FIRST, then onDragBegan's equivalent
                // (syncSharedDragStateForBegin writes the coarse identity).
                callbacks.dragState?.currentTouchPointGlobal = raw
                if let frame = host.renderedFrames[session.occurrenceID]?.frame {
                    callbacks.onEventManipulationPromotion?(
                        session.event, session.occurrenceID, session.originalRange.start,
                        currentMode, raw, view.convert(frame, to: nil)
                    )
                }
                syncSharedDragStateForBegin(session: session)
                updateAutoScrollVelocity()
                updateDragOffset(using: gesture)
                return
            }

            if hasMovedAfterLongPress {
                updateAutoScrollVelocity()
            } else {
                stopAutoScroll()
            }
            updateDragOffset(using: gesture)

        case .ended, .cancelled, .failed:
            guard let terminal = calendarDragTerminalState(for: gesture.state),
                  let session = eventSession else { return }
            if hasPromotedManipulation {
                let forward = calendarShouldForwardDrop(for: terminal)
                updateDragOffset(using: gesture)
                // Cross-day commit (chip path): the dragged event lands in the
                // column the finger is over (absolute), regardless of free vs
                // snapped chip X. Translate the source→target day gap into the
                // existing dayStep-based X offset that `handleEventDrag` rounds.
                // Resolved BEFORE finalize (which clears the gesture state).
                //
                // FIX 2: this absolute `dayColumnUnderFinger` override is only
                // valid in MULTI-DAY CONTINUOUS mode (`dayColumnStep > 0`, i.e.
                // multiple columns visible at once). In single-day/boundary-
                // paging mode the pager PAGE-TURNS: the gesture-owning host has
                // been re-modeled to the NEW date, so `srcDate == col.date` →
                // dayOffset 0 → the page-turn would be discarded and the event
                // would snap back to the original day. There `liveResolvedOffset`
                // already bakes in the committed day via `horizontalBoundaryPageCount`
                // (see `calendarBoundaryPagedHorizontalDragOffset`), so leave it
                // untouched.
                var finalOffset = liveResolvedOffset
                // FIX 2 (now chip-independent, #53A): the dayColumnUnderFinger
                // override fires for any multi-day-continuous move drop,
                // not only when the floating chip was up. Without it, after
                // an autoscroll the snap-quantized `liveResolvedOffset.x`
                // can be 1 column short of where the finger actually
                // landed; reading the column under finger directly avoids
                // that drift.
                if currentMode == .move, !usesHorizontalBoundaryPaging,
                   let col = dayColumnUnderFinger(), let srcDate = host.liveModel?.date {
                    let cal = Calendar.current
                    let dayOffset = cal.dateComponents(
                        [.day], from: cal.startOfDay(for: srcDate), to: cal.startOfDay(for: col.date)
                    ).day ?? 0
                    finalOffset.x = CGFloat(dayOffset) * dragPreviewDayStep
                    finalOffset.y = liveResolvedOffset.y
                }
                let mode = currentMode
                let didMove = hasMovedAfterLongPress
                // Defer preview clear (and skip the immediate STEP 5 paint
                // below) for committing move releases. See `finalizeTouchInteraction`.
                let isCommittingMoveRelease = forward && didMove && mode == .move
                finalizeTouchInteraction(deferPreviewClear: isCommittingMoveRelease)
                if forward && didMove {
                    switch mode {
                    case .move:
                        callbacks.onEventDragEnded?(
                            session.event, session.occurrenceID, session.originalRange,
                            finalOffset, dragPreviewDayStep
                        )
                    case .resizeTop:
                        callbacks.onEventResizeEnded?(
                            session.event, session.occurrenceID, session.originalRange,
                            session.originalRange.start, .resizeTop, finalOffset.y
                        )
                    case .resizeBottom:
                        callbacks.onEventResizeEnded?(
                            session.event, session.occurrenceID, session.originalRange,
                            session.originalRange.start, .resizeBottom, finalOffset.y
                        )
                    }
                }
                callbacks.onEventLongPressResolved?(
                    CalendarEventLongPressResolution(
                        event: session.event, occurrenceID: session.occurrenceID,
                        actionDate: session.originalRange.start, dragMode: mode,
                        terminalState: terminal, didMove: didMove,
                        touchPointGlobal: lastLocationInWindow
                    )
                )
                // Clear the observed scratchpad (G-28 onDragTerminal consumer).
                calendarResetSharedEventDragStateIfPresent()
                eventSession = nil
                // For committing move releases, skip the immediate paint: the
                // layer tree's last drag frame (preview at finger + source
                // hidden) is the correct visual to persist until SwiftUI's
                // next render lands the committed range. Painting here with
                // the still-stale model would flash the source at its OLD
                // canvas position. (#55 release flicker; see
                // `finalizeTouchInteraction(deferPreviewClear:)`)
                if !isCommittingMoveRelease {
                    host.renderLiveDragFrame()
                }
                return
            }
            // Pure long-press (no move past 8pt): resolve without commit (G-29).
            let mode = currentMode
            finalizeTouchInteraction()
            callbacks.onEventLongPressResolved?(
                CalendarEventLongPressResolution(
                    event: session.event, occurrenceID: session.occurrenceID,
                    actionDate: session.originalRange.start, dragMode: mode,
                    terminalState: terminal, didMove: false,
                    touchPointGlobal: lastLocationInWindow
                )
            )
            eventSession = nil

        default:
            break
        }
    }

    private func syncSharedDragStateForBegin(session: EventSession) {
        guard let dragState = callbacks.dragState else { return }
        dragState.draggingEventID = session.event.id
        dragState.draggingOccurrenceID = session.occurrenceID
        dragState.draggingEvent = session.event
        dragState.draggingOriginalRange = session.originalRange
        dragState.draggingRenderDayStart = host?.liveModel.map { Calendar.current.startOfDay(for: $0.date) }
        dragState.currentTouchPointGlobal = lastLocationInWindow
        dragState.dragMode = session.mode
        dragState.dayColumnStep = dragPreviewDayStep
        dragState.isHorizontalEdgeDragging = false
        dragState.isHorizontalAutoScrolling = false
        // dragState.dragOffset is initialized here; `applyDragOffset` mirrors
        // the per-frame resolved value going forward so SwiftUI consumers
        // (axis time-label pills, boundary extension) can track the live
        // drag. Spec 05 §7's perf hazard is COARSE publishing
        // (@Published / ObservableObject); EventDragState is @Observable so
        // per-frame writes invalidate only views that read this property at
        // body scope — same shape as the SwiftUI EventBlock path
        // (EventBlock.swift:1712). (#53 sub-bug B)
        dragState.dragOffset = .zero
    }

    // MARK: Drag offset math (G-16..G-22) — reuses the shared free funcs

    private func updateDragOffset(using gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: nil)
        lastLocationInWindow = location
        // Mirror the live touch point so the absorption hit-test (run at body
        // level for the SwiftUI host AND here for the drop target) tracks it.
        callbacks.dragState?.currentTouchPointGlobal = location

        let resolvedFingerDeltaX: CGFloat = {
            guard currentMode == .move, usesHorizontalBoundaryPaging, dragPreviewDayStep > 0 else {
                return location.x - initialPointInWindow.x
            }
            let localOffsetX = location.x - horizontalBoundaryPageOriginX
            return calendarBoundaryPagedHorizontalDragOffset(
                localOffsetX: localOffsetX,
                pageCount: horizontalBoundaryPageCount,
                dayStep: dragPreviewDayStep
            )
        }()
        let fingerDelta = DragOffset(
            x: resolvedFingerDeltaX,
            y: location.y - initialPointInWindow.y
        )
        let composed = calendarComposedDragOffset(
            fingerDelta: fingerDelta,
            autoScrollCompensation: DragOffset(x: autoScrollCompensationX, y: autoScrollCompensationY)
        )
        applyDragOffset(composed)
    }

    private func applyDragOffset(_ offset: DragOffset) {
        let suppressHorizontalSnap = isHorizontalSnapSuppressed || autoScrollVelocityX != 0
        var resolved = calendarResolvedDragOffset(
            rawOffset: offset,
            dragMode: currentMode,
            dayColumnStep: dragPreviewDayStep,
            suppressHorizontalSnap: suppressHorizontalSnap
        )
        resolved.y = calendarClampedMoveDragOffsetY(
            rawOffsetY: resolved.y,
            dragMode: currentMode,
            verticalDragBounds: verticalDragBounds
        )

        // Per-15-min snap haptic (G-21).
        if let hourHeight = host?.liveModel?.hourHeight, hourHeight > 0 {
            let snapSize = hourHeight / 4
            if snapSize > 0 {
                let step = Int((resolved.y / snapSize).rounded())
                if step != lastSnappedStep {
                    lastSnappedStep = step
                    impactFeedback.impactOccurred()
                }
            }
        }

        // Keep the floating chip glued to the finger every frame (the chip reads
        // the live finger position, not `liveResolvedOffset`), so run it even
        // when the resolved offset is unchanged (free-follow within snap grid).
        updateInGridPreview()
        updateChipPosition()

        guard resolved != liveResolvedOffset else { return }
        liveResolvedOffset = resolved
        // #53 sub-bug B: mirror the resolved offset onto `dragState.dragOffset`
        // (@Observable). SwiftUI consumers — the axis time-label pills
        // (TimelineView's `editMappingPresentation` →
        // `resolvedDragEditMapping`) and boundary-extension math — read this
        // every frame to track the live drag time. Without the mirror they
        // froze at zero (the original CALayer rewrite assumed the per-frame
        // CALayer-internal `liveResolvedOffset` was enough; it isn't for
        // SwiftUI siblings). The earlier comment cited spec 05 §7 as a perf
        // hazard, but §7 actually forbids COARSE publishing (Combine
        // @Published / ObservableObject); EventDragState is @Observable, so
        // per-frame writes invalidate ONLY views that read `dragOffset` at
        // body scope — same cost shape as the SwiftUI EventBlock path already
        // pays. Mirrors EventBlock.swift:1712 in shape.
        callbacks.dragState?.dragOffset = resolved
        updateAbsorptionDropTarget()
        host?.renderLiveDragFrame()
    }

    // MARK: Floating cross-day drag chip (move-only)

    /// #53A autoscroll chip: in chip-less mode, spawn a temporary chip the
    /// moment edge auto-scroll (or in-edge dragging) suppresses horizontal
    /// snap, and despawn the moment it stops. The chip is the SOLE visual
    /// during autoscroll — the in-grid projection is intentionally cleared
    /// (`updateInGridPreview` snap-suppressed guard) to avoid the per-tick
    /// 15-min snap flicker. The chip follows the finger 1:1 (no snap), so
    /// the user sees a smooth lift-off representation of what they're
    /// dragging while the time grid scrolls under them.
    private func ensureAutoscrollChipIfNeeded() {
        // chipEnabled mode manages its own chip at promotion + drop — skip.
        guard !chipEnabled else { return }
        // Need a promotion + move drag + a captured source snapshot.
        guard hasPromotedManipulation, currentMode == .move,
              let host, let image = chipSourceImage,
              chipSourceSize.width > 0, chipSourceSize.height > 0 else {
            return
        }
        // Todos are excluded from `overlapCandidates` (so they don't squeeze
        // peer events) AND from the in-grid `#preview` projection
        // (`updateInGridPreview` early-returns for `.todo`). The source block
        // is still hidden via `chipHidesSource` for the dragged occurrence,
        // so without the chip the todo has NO visible representation during
        // a drag. Force the chip on for the whole todo drag so it stands in
        // for the hidden source — matching the design comment at
        // `updateInGridPreview` ("the floating chip alone represents it").
        let draggedIsTodo = eventSession?.event.kind == .todo
        let needsChip = isHorizontalSnapSuppressed || draggedIsTodo
        if needsChip, dragChip == nil, let window = host.window {
            let chip = UIImageView(image: image)
            chip.bounds.size = chipSourceSize
            chip.contentMode = .scaleToFill
            chip.layer.shadowColor = UIColor.black.cgColor
            chip.layer.shadowOpacity = 0.22
            chip.layer.shadowRadius = 8
            chip.layer.shadowOffset = CGSize(width: 0, height: 3)
            chip.alpha = 0.97
            chip.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
            let f = lastLocationInWindow
            chip.center = CGPoint(
                x: f.x - chipGrabOffset.width,
                y: f.y - chipGrabOffset.height
            )
            window.addSubview(chip)
            dragChip = chip
            isChipActive = true
        } else if !needsChip, dragChip != nil {
            dragChip?.removeFromSuperview()
            dragChip = nil
            isChipActive = false
            lastSnappedColumnCenterX = nil
            lastChipSnapFingerprint = nil
            lastChipSnapSize = nil
        }
    }

    /// Position the floating chip each frame. Y follows the finger continuously
    /// (preserving the grab offset). X free-follows the finger while horizontal
    /// snap is suppressed (edge / auto-scroll), otherwise snaps to the center of
    /// the day-column under the finger.
    private func updateChipPosition() {
        ensureAutoscrollChipIfNeeded()
        guard let chip = dragChip else { return }
        // The chip is the dragged event's ONE always-visible representation for
        // the whole drag — it must never be hidden, or the event vanishes when
        // the in-grid preview path hiccups (the "event disappears" bug). In snap
        // mode it snaps to the column center (sitting in the reflowed gap); in
        // free/auto-scroll it follows the finger.
        //
        // #53 sub-bug A: chip mirrors the in-grid projection on the column
        // under the finger — same `configure` render path via
        // `snapshotPreviewBlock`, just anchored to the finger instead of the
        // time grid. So chip's WIDTH + HEIGHT + bitmap all refresh whenever
        // the underlying preview changes (range, hourHeight, slot). For a
        // cross-multi-day move, finger over column A → chip = A's clip; finger
        // over column B → chip = B's clip. Uniform N-column logic — no
        // overnight special case. Snapshot fingerprint throttles the
        // UIGraphicsImageRenderer call to actual visual changes.
        chip.isHidden = false
        let finger = lastLocationInWindow
        let centerY = finger.y - chipGrabOffset.height
        let centerX: CGFloat
        var targetWidth = chipSourceSize.width
        var targetHeight = chipSourceSize.height
        if isHorizontalSnapSuppressed {
            // FREE: follow finger at source size; restore the source-size
            // snapshot if a prior snap morph had swapped in a smaller one.
            if let iv = chip as? UIImageView, iv.image !== chipSourceImage {
                iv.image = chipSourceImage
            }
            // Invalidate the snap fingerprint so the next snap-mode frame
            // re-renders + replaces the source-image fallback above.
            lastChipSnapFingerprint = nil
            var x = finger.x - chipGrabOffset.width
            if let w = chip.window {
                let half = chipSourceSize.width / 2
                x = min(max(x, w.bounds.minX + half), w.bounds.maxX - half)
            }
            centerX = x
            lastSnappedColumnCenterX = nil
        } else if let col = dayColumnUnderFinger() {
            if let geo = col.host.previewChipGeometryInWindow() {
                centerX = geo.centerX
                // Refresh chip's bitmap + bounds from the projection on this
                // column. The fingerprint throttles re-snapshotting (which
                // renders a fresh CALayer tree to UIImage) to actual visual
                // changes: range, hourHeight, slot widthFraction.
                let snapFP = col.host.chipSnapFingerprint()
                if snapFP != nil, snapFP != lastChipSnapFingerprint,
                   let snap = col.host.snapshotPreviewBlock() {
                    if let iv = chip as? UIImageView {
                        iv.image = snap.image
                    }
                    lastChipSnapSize = snap.size
                    lastChipSnapFingerprint = snapFP
                }
                // Prefer the live snap size (so chip mirrors the projection
                // dimensions); fall back to the geo-derived width if the snap
                // is briefly unavailable between drag-preview updates.
                if let snapSize = lastChipSnapSize {
                    targetWidth = snapSize.width
                    targetHeight = snapSize.height
                } else {
                    targetWidth = geo.width
                }
            } else {
                centerX = col.windowCenterX
            }
        } else {
            centerX = chip.center.x
        }
        // Snap mode: spring when target X, width, OR height changes; free
        // mode: set directly (1:1 finger-follow, no animation).
        let widthChanged = abs(chip.bounds.size.width - targetWidth) > 0.5
        let heightChanged = abs(chip.bounds.size.height - targetHeight) > 0.5
        if !isHorizontalSnapSuppressed,
           lastSnappedColumnCenterX != centerX || widthChanged || heightChanged {
            lastSnappedColumnCenterX = centerX
            UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.85,
                           initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                chip.bounds.size = CGSize(width: targetWidth, height: targetHeight)
                chip.center = CGPoint(x: centerX, y: centerY)
            }
        } else {
            chip.bounds.size = CGSize(width: targetWidth, height: targetHeight)
            chip.center = CGPoint(x: centerX, y: centerY)
        }
    }

    /// The day-column host whose window-space bounds contain the finger X (or
    /// the nearest one if the finger is past all columns), plus its center X and
    /// date. Walks the window subtree so it finds every visible day-column.
    private func dayColumnUnderFinger() -> (host: DayLayerHostView, windowCenterX: CGFloat, date: Date)? {
        let hosts = allDayHosts()
        guard !hosts.isEmpty else { return nil }
        let fingerX = lastLocationInWindow.x
        var best: (h: DayLayerHostView, rect: CGRect)?
        for h in hosts {
            guard h.liveModel != nil else { continue }
            let r = h.convert(h.bounds, to: nil)
            if r.minX <= fingerX, fingerX <= r.maxX { best = (h, r); break }
            if best == nil || abs(r.midX - fingerX) < abs(best!.rect.midX - fingerX) { best = (h, r) }
        }
        guard let chosen = best, let date = chosen.h.liveModel?.date else { return nil }
        return (chosen.h, chosen.rect.midX, date)
    }

    /// All `DayLayerHostView` instances currently in the window subtree (the
    /// visible day columns). Used by the cross-midnight sibling-paint fan-out
    /// to push a `foreignDragSession` onto every sibling whose day window the
    /// dragged event's range intersects (#53 sub-bug A).
    private func allDayHosts() -> [DayLayerHostView] {
        guard let host, let window = host.window else { return [] }
        var hosts: [DayLayerHostView] = []
        func walk(_ v: UIView) {
            if let h = v as? DayLayerHostView { hosts.append(h) }
            v.subviews.forEach(walk)
        }
        walk(window)
        return hosts
    }

    // MARK: In-grid drag preview (move + cross-midnight sibling fan-out)

    /// While a move drag is settled (NOT auto-scrolling), push a real-time
    /// preview occurrence onto the day-column under the finger: the dragged
    /// event slots into THAT day's timeline at the dragged time (Y → time,
    /// day = the absolute target column), so neighbors reflow around it. The
    /// floating chip is hidden in this mode (see `updateChipPosition`).
    ///
    /// Cross-midnight (#53 sub-bug A): the live range can span multiple day
    /// columns. We split the (move-shifted-and-clipped OR resize-folded) range
    /// across every visible day-host it touches and push a `foreignDragSession`
    /// + clipped preview to each NON-source host. Mirror of drag-create's
    /// per-day mapping at `TimelineView.swift:updateCreationPreviewMapping`.
    /// Rebuilt every drag frame so a column the live range LEAVES is cleared
    /// (not frozen on its last clip), and a column the live range newly ENTERS
    /// is painted.
    private func updateInGridPreview() {
        guard let host, hasPromotedManipulation, let session = eventSession,
              let srcDate = host.liveModel?.date else {
            clearInGridPreview(); return
        }
        // Only move + resize participate in the in-grid preview path.
        switch currentMode {
        case .move:
            // Hand off to the autoscroll chip (`ensureAutoscrollChipIfNeeded`)
            // whenever horizontal snap is suppressed — edge zone or
            // active edge-autoscroll. The chip follows the finger 1:1 with
            // no snap; the in-grid would flicker per tick as each new
            // 15-min slot snaps under finger. Clear all in-grid previews
            // so the chip is the sole visual until autoscroll ends.
            guard !isHorizontalSnapSuppressed else {
                clearInGridPreview(); return
            }
        case .resizeTop, .resizeBottom:
            // Resize stays in the source column; no horizontal-snap
            // distinction. Resize doesn't drive an autoscroll chip — the
            // resized block follows the live range via `liveAdjustedOccurrence`
            // on the source and via the synth preview on siblings.
            break
        }
        // FIX 5: a dragged todo deliberately does NOT participate in overlap
        // (it's excluded from `overlapCandidates` via `draggedTodoOccurrenceID`),
        // so it must never squeeze peers. Pushing a `#preview` occurrence into
        // the target day's overlap would reintroduce exactly that squeeze, so a
        // dragged todo gets no in-grid preview — the floating chip alone
        // represents it. (Same predicate the overlap exclusion uses.)
        if session.event.kind == .todo {
            clearInGridPreview(); return
        }

        let cal = Calendar.current
        let hourHeight = host.liveModel?.hourHeight ?? 0

        // 1) Compute the live-adjusted range (move: shifted, resize: folded).
        //    Move: keep the existing two-step shape (vertical via the helper,
        //    horizontal day-delta from the column under the finger), so the
        //    target column is still authoritative for the dropped day.
        //    Resize: the helper folds the dragged edge into the range and
        //    handles the natural flip when edges cross.
        let liveRange: Event.TimeRange
        switch currentMode {
        case .move:
            guard let col = dayColumnUnderFinger() else {
                clearInGridPreview(); return
            }
            let timeRange = calendarResolvedDragEditRange(
                draggingOriginalRange: session.originalRange,
                dragOffset: DragOffset(x: 0, y: liveResolvedOffset.y),
                dragMode: .move,
                hourHeight: hourHeight,
                dayColumnStep: 0
            ) ?? session.originalRange
            let dayDelta = cal.dateComponents(
                [.day], from: cal.startOfDay(for: srcDate), to: cal.startOfDay(for: col.date)
            ).day ?? 0
            let shiftedStart = cal.date(byAdding: .day, value: dayDelta, to: timeRange.start) ?? timeRange.start
            let shiftedEnd = cal.date(byAdding: .day, value: dayDelta, to: timeRange.end) ?? timeRange.end
            liveRange = Event.TimeRange(start: shiftedStart, end: shiftedEnd)
        case .resizeTop, .resizeBottom:
            liveRange = calendarResolvedDragEditRange(
                draggingOriginalRange: session.originalRange,
                dragOffset: DragOffset(x: 0, y: liveResolvedOffset.y),
                dragMode: currentMode,
                hourHeight: hourHeight,
                dayColumnStep: 0
            ) ?? session.originalRange
        }

        // 2) Per-day push decision. Shared id (`#preview`) across hosts so
        //    the sibling-paint render branch + source
        //    `previewChipGeometryInWindow` keep their existing keying.
        //    Returns nil when the live range doesn't touch this day at all.
        //
        //    #53A follow-on: the preview carries the FULL live range, NOT
        //    the day-clipped portion. This makes the in-block time text
        //    show the unified event duration (e.g. "23:30 - 02:30") on
        //    every column the cross-midnight event touches, instead of
        //    each half showing its own partial slice and looking like two
        //    separate events. `verticalFrame` clips visually via
        //    `calendarTimelineYFraction`'s `min(max(0, raw), 1)` clamp +
        //    `max(visibleStart, range.start)` / `min(visibleEnd, range.end)`
        //    — same shape static cross-midnight blocks already follow
        //    (their `occurrence.range` is also the full unclipped range).
        let previewID = session.occurrenceID + "#preview"
        func clippedPreview(forDay dayStart: Date) -> CalendarLayout.EventOccurrence? {
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            guard liveRange.end > dayStart, liveRange.start < dayEnd else { return nil }
            return CalendarLayout.EventOccurrence(
                id: previewID, event: session.event, range: liveRange
            )
        }

        // 3) Resolve the SOURCE host for this drag. For move that's the column
        //    under the finger (drop target); for resize it's the
        //    gesture-owning host (the source day, which keeps its
        //    `liveAdjustedOccurrence` flow).
        let sourceHost: DayLayerHostView
        let sourceDayStart: Date
        switch currentMode {
        case .move:
            guard let col = dayColumnUnderFinger() else {
                clearInGridPreview(); return
            }
            sourceHost = col.host
            sourceDayStart = cal.startOfDay(for: col.date)
        case .resizeTop, .resizeBottom:
            sourceHost = host
            sourceDayStart = cal.startOfDay(for: srcDate)
        }

        // 4) Apply the source-column preview. Move's in-grid preview path
        //    pushes the clipped live range to the column under the finger.
        //    Resize source stays nil — its source-host block is already
        //    painted via `liveAdjustedOccurrence`, and pushing a preview
        //    here would drop the dragged occurrence from `overlapCandidates`
        //    (filtered when a preview for the same event id is present +
        //    dragged on this host) which would blank the resized block.
        //
        //    For a CROSS-COLUMN move (finger crossed to a host that is NOT
        //    the gesture-owning `host`), the new source has NO local
        //    `activeEventSession` (gestures live on whichever host
        //    promoted), so without a foreign-session push its paint gate
        //    stays CLOSED and the synth preview block visually disappears
        //    (#53A: chip-less cross-column bug). Set the foreign session
        //    BEFORE applying the preview so the gate is open by the time
        //    the apply-triggered render runs (no 1-frame flicker).
        let foreignSession = DayLayerHostView.ForeignDragSession(
            occurrenceID: session.occurrenceID,
            event: session.event,
            mode: currentMode
        )
        var newHosts: [DayLayerHostView] = []
        switch currentMode {
        case .move:
            let sourcePreview = clippedPreview(forDay: sourceDayStart)
                ?? CalendarLayout.EventOccurrence(
                    id: previewID, event: session.event, range: liveRange
                )
            if sourceHost !== host {
                sourceHost.setForeignDragSession(foreignSession)
            }
            sourceHost.applyDragPreview(sourcePreview)
            newHosts.append(sourceHost)
        case .resizeTop, .resizeBottom:
            // Source resize: no preview push — leave its existing render flow
            // (overlap candidates, `liveAdjustedOccurrence`) untouched.
            break
        }

        // 5) Fan out to SIBLING hosts whose day window the live range
        //    intersects. Each sibling receives the foreign-drag signal + a
        //    clipped preview, so the cross-midnight half tracks the live
        //    drag in lockstep with the source. The source-host's local
        //    `activeEventSession` remains the truth — only NON-source hosts
        //    receive the foreign session.
        // Fan-out skip rules (#53 sub-bug A):
        //  • `sourceHost` already got its push above (move: drop target;
        //    resize: no preview push, but its render flow paints via
        //    `liveAdjustedOccurrence`).
        //  • Skip the gesture-owning `host` if it is NOT also the source
        //    host. `host` already has the LOCAL `activeEventSession`, so its
        //    render flow handles the dragged occurrence via
        //    `liveAdjustedOccurrence` (clipping to its day window) and its
        //    `overlapCandidates` dedup already drops the dragged occurrence
        //    when a preview for the same event id is present. Pushing a
        //    foreign preview onto a host that has the local session would
        //    confuse those gates AND interfere with the source's stable
        //    overlap slot.
        //
        // A SIBLING is any other day host that has the dragged event's
        // SAME-ID static occurrence (cross-midnight twin) AND/OR whose day
        // window the LIVE range touches:
        //  • Same-id twin (cross-midnight original) → push the foreign
        //    session so `chipHidesSource` hides its frozen static block
        //    (the bug — sibling was visibly decoupled from the dragged
        //    chip). Whether it ALSO paints a preview depends on whether
        //    the live range still touches its day.
        //  • Live-range intersection (cross-midnight at the new position)
        //    → push the foreign session + clipped preview so the sibling
        //    paints the cross-midnight half at the live position.
        var anySiblingPushed = false
        for sibling in allDayHosts() {
            // Skip the source host (already pushed above with the right
            // ordering: foreign session before applyDragPreview).
            //
            // The gesture-owning `host` is NOT skipped here — when the
            // finger has moved AWAY from its original column (the source
            // is now elsewhere), the original column becomes a sibling
            // whose half of the live range still needs an in-grid
            // projection. Its local `activeEventSession` covers
            // `chipHidesSource` (static block stays hidden) and the paint
            // gate, but only IF `dragPreviewOccurrence` is non-nil — and
            // that requires applyDragPreview pushed here. (#53 sub-bug A
            // follow-on: "forward cross-day, previous-day part doesn't
            // render".) We do skip the FOREIGN-session push for the
            // gesture-owning host though, to keep one session source of
            // truth per host.
            if sibling === sourceHost { continue }
            guard let siblingDate = sibling.liveModel?.date else { continue }
            let siblingDayStart = cal.startOfDay(for: siblingDate)
            let hasSameIDStatic = sibling.liveModel?.occurrences.contains(where: {
                $0.id == session.occurrenceID
            }) ?? false
            let preview = clippedPreview(forDay: siblingDayStart)
            // Push only if there IS something to coordinate on this sibling:
            // either it has the same-id static twin that needs to hide, or
            // the live range now touches its day window (or both).
            guard hasSameIDStatic || preview != nil else { continue }
            // The gesture-owning `host` already has the LOCAL
            // activeEventSession — pushing the foreign session on top would
            // duplicate the drag-identity signal. Skip the foreign push for
            // it, but still apply the preview clip below so its synth
            // preview is non-nil and its paint gate fires.
            if sibling !== host {
                sibling.setForeignDragSession(foreignSession)
            }
            // Preview is OPTIONAL on the sibling. Hosts whose live range
            // newly LEAVES (cross-midnight collapsed to single-day) still
            // need the static block hidden — push nil to clear any prior
            // preview while keeping the foreign session active so
            // `chipHidesSource` still hides the static twin.
            sibling.applyDragPreview(preview)
            newHosts.append(sibling)
            anySiblingPushed = true
        }

        // Cross-midnight signal to the source host: when the live range spans
        // more than one day, the chip (one window-space bitmap) cannot
        // represent both halves at once. Tell the source to ALSO paint its
        // clipped portion in-grid, so source + sibling(s) jointly form the
        // visible representation. Reset to false when the drag collapses back
        // to single-day so the chip resumes being the sole source visual.
        sourceHost.setPaintSourceClipInGrid(anySiblingPushed)

        // 6) Clear hosts that previously received a preview but are no longer
        //    in the fan-out (the finger left a column, or the live range
        //    receded from a cross-midnight sibling). This is what makes a
        //    column the live range LEAVES clear (rather than freezing on its
        //    last clip — explicit user requirement).
        let kept = Set(newHosts.map { ObjectIdentifier($0) })
        for ref in lastPreviewHosts {
            guard let h = ref.host, !kept.contains(ObjectIdentifier(h)) else { continue }
            h.applyDragPreview(nil)
            h.setForeignDragSession(nil)
            h.setPaintSourceClipInGrid(false)
        }
        lastPreviewHosts = newHosts.map { WeakHostRef(host: $0) }
    }

    private func clearInGridPreview() {
        for ref in lastPreviewHosts {
            guard let h = ref.host else { continue }
            h.applyDragPreview(nil)
            h.setForeignDragSession(nil)
            h.setPaintSourceClipInGrid(false)
        }
        lastPreviewHosts.removeAll()
    }

    // MARK: Absorption drop-targeting (G-57..G-62)

    /// Spatial hit-test of the live touch point against rendered event frames;
    /// mirrors the chosen parent's id coarsely into `currentDropTargetEventID`.
    private func updateAbsorptionDropTarget() {
        guard let host, let dragState = callbacks.dragState,
              let session = eventSession,
              session.event.kind == .todo, !session.event.isRecurringSeries,
              !mirroredAutoScrolling, !mirroredEdgeDragging else {
            return
        }
        // FIX 4: hit-test the day column UNDER THE FINGER, not just the source
        // host. Dragging a todo over an event on a DIFFERENT day's column must
        // still find an absorb target. Resolve that column's host and hit-test
        // its `renderedFrames` in ITS OWN coordinate space (convert the window
        // touch point into the target host). When the finger is over the source
        // column, `dayColumnUnderFinger()` returns the source host → identical
        // same-day behavior. Falls back to the source host if unresolved.
        let targetHost = dayColumnUnderFinger()?.host ?? host
        let touchInView = targetHost.convert(lastLocationInWindow, from: nil)
        var best: (id: UUID, depth: Int)?
        for (id, rf) in targetHost.renderedFrames {
            let occ = rf.occurrence
            guard occ.event.kind == .event, occ.event.id != session.event.id,
                  occ.event.absorbedIntoEventID == nil,
                  id != session.occurrenceID else { continue }
            guard rf.frame.contains(touchInView) else { continue }
            let depth = rf.slot.depth + (rf.isEmbeddedChild ? 1 : 0)
            if best == nil || depth > best!.depth {
                best = (occ.event.id, depth)
            }
        }
        // Only-clear-if-we-still-own (G-59): write non-nil unconditionally;
        // clear only if the current target was the one we'd set.
        if let id = best?.id {
            dragState.currentDropTargetEventID = id
        } else if dragState.currentDropTargetEventID != nil {
            dragState.currentDropTargetEventID = nil
        }
    }

    // MARK: Edge auto-scroll (G-35..G-41) — reuses the shared curve

    private enum ScrollAxis { case horizontal, vertical }

    private func updateAutoScrollVelocity() {
        guard hasMovedAfterLongPress else {
            stopAutoScroll()
            isHorizontalSnapSuppressed = false
            mirrorEdgeFlags(edge: false, auto: false)
            return
        }
        let horizontalEdgeActive = isInHorizontalAutoScrollEdgeZone()
        if currentMode == .move, usesHorizontalBoundaryPaging {
            autoScrollVelocityX = 0
            handleHorizontalBoundaryPagingIfNeeded(horizontalEdgeActive: horizontalEdgeActive)
        } else {
            autoScrollVelocityX = currentMode == .move
                ? autoScrollVelocity(for: horizontalScrollView, axis: .horizontal)
                : 0
        }
        autoScrollVelocityY = autoScrollVelocity(for: verticalScrollView, axis: .vertical)

        let needsBoundaryPagingTick = usesHorizontalBoundaryPaging && horizontalEdgeActive
        if autoScrollVelocityX == 0 && autoScrollVelocityY == 0 && !needsBoundaryPagingTick {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
        let isAutoScrolling = autoScrollVelocityX != 0
        isHorizontalSnapSuppressed = horizontalEdgeActive || isAutoScrolling
        mirrorEdgeFlags(edge: isHorizontalSnapSuppressed, auto: isAutoScrolling)
    }

    private func mirrorEdgeFlags(edge: Bool, auto: Bool) {
        mirroredEdgeDragging = edge
        mirroredAutoScrolling = auto
        callbacks.dragState?.isHorizontalEdgeDragging = edge
        callbacks.dragState?.isHorizontalAutoScrolling = auto
    }

    private func handleHorizontalBoundaryPagingIfNeeded(horizontalEdgeActive: Bool) {
        guard horizontalEdgeActive, dragPreviewDayStep > 0,
              let request = callbacks.onHorizontalBoundaryPageRequest else { return }
        let direction = horizontalBoundaryPageDirection()
        guard direction != 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastHorizontalBoundaryPageTimestamp >= horizontalBoundaryPageMinimumInterval else { return }
        guard request(direction) else { return }
        lastHorizontalBoundaryPageTimestamp = now
        horizontalBoundaryPageCount += direction
        horizontalBoundaryPageOriginX = lastLocationInWindow.x
        if let gesture = activeGesture { updateDragOffset(using: gesture) }
    }

    private func startAutoScroll() {
        guard autoScrollDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        autoScrollDisplayLink = link
    }

    private func stopAutoScroll() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        autoScrollVelocityX = 0
        autoScrollVelocityY = 0
        mirroredAutoScrolling = false
        callbacks.dragState?.isHorizontalAutoScrolling = false
    }

    @objc private func handleAutoScrollTick(_ link: CADisplayLink) {
        guard autoScrollVelocityX != 0 || autoScrollVelocityY != 0 else {
            stopAutoScroll()
            return
        }
        let dt = max(link.targetTimestamp - link.timestamp, 0)
        let delta = CGPoint(
            x: calendarHorizontalAutoScrollDelta(velocityX: autoScrollVelocityX, deltaTime: dt),
            y: autoScrollVelocityY * CGFloat(dt)
        )
        // Same-scrollview special case (G-39): one combined apply if the
        // horizontal & vertical targets are the same object.
        if let shared = horizontalScrollView, shared === verticalScrollView {
            let applied = applyAutoScroll(on: shared, delta: delta)
            autoScrollCompensationX += applied.x
            autoScrollCompensationY += applied.y
        } else {
            if let sv = horizontalScrollView {
                autoScrollCompensationX += applyAutoScroll(on: sv, delta: CGPoint(x: delta.x, y: 0)).x
            }
            if let sv = verticalScrollView {
                autoScrollCompensationY += applyAutoScroll(on: sv, delta: CGPoint(x: 0, y: delta.y)).y
            }
        }
        if let gesture = activeGesture { lastLocationInWindow = gesture.location(in: nil) }
        updateAutoScrollVelocity()
        if let gesture = activeGesture { updateDragOffset(using: gesture) }
        // A stationary finger over a scrolling pager still needs the chip + snap
        // target refreshed each tick (columns slide under the finger).
        updateInGridPreview()
        updateChipPosition()
    }

    private func autoScrollVelocity(for scrollView: UIScrollView?, axis: ScrollAxis) -> CGFloat {
        guard let scrollView else { return 0 }
        let minOffset: CGFloat
        let maxOffset: CGFloat
        let boundsSize: CGFloat
        let loc: CGFloat
        let edgeInset: CGFloat
        switch axis {
        case .horizontal:
            minOffset = -scrollView.adjustedContentInset.left
            maxOffset = max(minOffset, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
            boundsSize = scrollView.bounds.width
            loc = locationInViewport(for: scrollView, axis: .horizontal)
            edgeInset = calendarHorizontalAutoScrollEdgeInsetDefault
        case .vertical:
            minOffset = -scrollView.adjustedContentInset.top
            maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            boundsSize = scrollView.bounds.height
            loc = locationInViewport(for: scrollView, axis: .vertical)
            edgeInset = calendarVerticalAutoScrollEdgeInsetDefault
        }
        let currentOffset = axis == .horizontal ? scrollView.contentOffset.x : scrollView.contentOffset.y
        return calendarAutoScrollVelocity(
            locationInViewport: loc, viewportLength: boundsSize, currentOffset: currentOffset,
            minOffset: minOffset, maxOffset: maxOffset, edgeInset: edgeInset,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
    }

    private func locationInViewport(for scrollView: UIScrollView, axis: ScrollAxis) -> CGFloat {
        let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
        return axis == .horizontal
            ? lastLocationInWindow.x - frameInWindow.minX
            : lastLocationInWindow.y - frameInWindow.minY
    }

    private func isInHorizontalAutoScrollEdgeZone() -> Bool {
        guard currentMode == .move, let sv = horizontalScrollView else { return false }
        return calendarIsInAutoScrollEdgeZone(
            locationInViewport: locationInViewport(for: sv, axis: .horizontal),
            viewportLength: sv.bounds.width,
            edgeInset: calendarHorizontalAutoScrollEdgeInsetDefault
        )
    }

    private func horizontalBoundaryPageDirection() -> Int {
        guard let sv = horizontalScrollView else { return 0 }
        return calendarHorizontalBoundaryPageDirection(
            locationInViewport: locationInViewport(for: sv, axis: .horizontal),
            viewportLength: sv.bounds.width,
            edgeInset: calendarHorizontalAutoScrollEdgeInsetDefault
        )
    }

    private func applyAutoScroll(on scrollView: UIScrollView, delta: CGPoint) -> CGPoint {
        let minX = -scrollView.adjustedContentInset.left
        let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let current = scrollView.contentOffset
        let clampedX = min(max(current.x + delta.x, minX), maxX)
        let clampedY = min(max(current.y + delta.y, minY), maxY)
        guard abs(clampedX - current.x) > .ulpOfOne || abs(clampedY - current.y) > .ulpOfOne else { return .zero }
        scrollView.setContentOffset(CGPoint(x: clampedX, y: clampedY), animated: false)
        return CGPoint(x: clampedX - current.x, y: clampedY - current.y)
    }

    private func findScrollTargets(startingAt view: UIView) -> (horizontal: UIScrollView?, vertical: UIScrollView?) {
        var current: UIView? = view.superview
        var h: UIScrollView?
        var v: UIScrollView?
        while let candidate = current {
            if let sv = candidate as? UIScrollView, sv.isScrollEnabled {
                if h == nil && sv.contentSize.width - sv.bounds.width > 1 { h = sv }
                if v == nil && sv.contentSize.height - sv.bounds.height > 1 { v = sv }
                if h != nil && v != nil { break }
            }
            current = candidate.superview
        }
        return (h, v)
    }

    // MARK: Scroll-gesture suppression during drag (G-33)

    private func disableScrollPanGesturesForDrag() {
        guard disabledScrollGestures.isEmpty else { return }
        var current: UIView? = activeGesture?.view?.superview
        var seen = Set<ObjectIdentifier>()
        while let v = current {
            if let sv = v as? UIScrollView {
                let id = ObjectIdentifier(sv)
                if !seen.contains(id) {
                    seen.insert(id)
                    savedCanCancelContentTouches.append((sv, sv.canCancelContentTouches))
                    sv.canCancelContentTouches = false
                    for g in sv.gestureRecognizers ?? [] {
                        disabledScrollGestures.append((g, g.isEnabled))
                        g.isEnabled = false
                    }
                }
            }
            current = v.superview
        }
    }

    private func restoreScrollPanGestures() {
        for entry in savedCanCancelContentTouches {
            entry.scrollView.canCancelContentTouches = entry.wasEnabled
        }
        savedCanCancelContentTouches.removeAll()
        for entry in disabledScrollGestures {
            entry.gesture.isEnabled = entry.wasEnabled
        }
        disabledScrollGestures.removeAll()
    }

    private func finalizeTouchInteraction(deferPreviewClear: Bool = false) {
        stopAutoScroll()
        (activeGesture as? TracingLongPressGesture)?.isDragPromoted = false
        restoreScrollPanGestures()
        activeGesture = nil
        horizontalScrollView = nil
        verticalScrollView = nil
        hasMovedAfterLongPress = false
        hasPromotedManipulation = false
        isHorizontalSnapSuppressed = false
        liveResolvedOffset = .zero
        autoScrollCompensationX = 0
        autoScrollCompensationY = 0
        lastHorizontalBoundaryPageTimestamp = 0
        horizontalBoundaryPageCount = 0
        horizontalBoundaryPageOriginX = 0
        mirrorEdgeFlags(edge: false, auto: false)
        // Tear down the floating drag chip (if any). The source block's opacity
        // restores on the next normal render once the session clears.
        dragChip?.removeFromSuperview()
        dragChip = nil
        isChipActive = false
        lastSnappedColumnCenterX = nil
        lastChipSnapFingerprint = nil
        lastChipSnapSize = nil
        // Move-commit release defers the preview clear so the layer tree's
        // last drag frame (preview at finger, source opacity 0) persists
        // until SwiftUI re-renders with the committed range. Then render()'s
        // synthesizedPreview dedup against the new model occurrence removes
        // the preview layer atomically with the source layer appearing at
        // its new position. Without this defer, the immediate clear paints
        // a 1-frame "source at OLD position, opacity 1" flicker because
        // `activeEventSession` already turned nil (hasPromotedManipulation
        // flips false earlier in this method) but model still has the old
        // occurrence range. (#55 release flicker)
        if !deferPreviewClear {
            clearInGridPreview()
        }
    }

    // MARK: Per-hit capability + bounds

    private func canResizeTop(for hit: DayLayerHostView.RenderedEventFrame) -> Bool {
        guard let model = host?.liveModel else { return true }
        let visibleStart = calendarTimelineVisibleStart(
            containing: model.date, leadingExtendedHours: model.leadingExtendedHours
        )
        return hit.occurrence.range.start >= visibleStart
    }

    private func canResizeBottom(for hit: DayLayerHostView.RenderedEventFrame) -> Bool {
        guard let model = host?.liveModel else { return true }
        let visibleEnd = calendarTimelineVisibleEnd(
            containing: model.date, trailingExtendedHours: model.trailingExtendedHours
        )
        return hit.occurrence.range.end <= visibleEnd
    }

    private func computedVerticalDragBounds(for hit: DayLayerHostView.RenderedEventFrame) -> ClosedRange<CGFloat> {
        guard let model = host?.liveModel, model.hourHeight > 0 else { return -.infinity ... .infinity }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: model.date)
        let maxBoundaryStart = dayStart.addingTimeInterval(
            TimeInterval(-calendarTimelineMaximumBoundaryExtensionHours * 3600)
        )
        let maxBoundaryEnd = dayStart.addingTimeInterval(
            TimeInterval((calendarTimelineBaseVisibleHours + calendarTimelineMaximumBoundaryExtensionHours) * 3600)
        )
        let range = hit.occurrence.range
        let dur = range.end.timeIntervalSince(range.start)
        let minY = CGFloat(maxBoundaryStart.timeIntervalSince(range.start) / 3600) * model.hourHeight
        let maxY = CGFloat((maxBoundaryEnd.timeIntervalSince(range.start) - dur) / 3600) * model.hourHeight
        return minY ... max(minY, maxY)
    }

    // MARK: Drag-to-create (G-46..G-56)

    @objc private func handleCreateGesture(_ gesture: UILongPressGestureRecognizer) {
        guard let host, let view = gesture.view else { return }
        let y = gesture.location(in: view).y

        switch gesture.state {
        case .began:
            verticalScrollView = findScrollTargets(startingAt: view).vertical
            isLongPressingCreation = true
            isCreating = false
            creationStartY = y
            creationCurrentY = y
            lastTickMinutes = -1
            lastSnappedStartEdge = nil
            lastSnappedEndEdge = nil
            snapHaptic.prepare()
            createHaptic.impactOccurred()

        case .changed:
            guard isLongPressingCreation else { return }
            creationCurrentY = y
            if !isCreating {
                if calendarShouldActivateCreationAfterLongPress(
                    dragDeltaY: y - creationStartY,
                    threshold: creationActivationThreshold
                ) {
                    isCreating = true
                    lastTickMinutes = currentSnappedMinutes(for: y)
                    createHaptic.impactOccurred()
                    startCreationAutoScroll()
                }
                pushCreationPreview()
                return
            }
            checkCreationHapticTick()
            checkAdjacentSnapHaptic()
            pushCreationPreview()
            updateCreationAutoScrollVelocity()

        case .ended:
            stopCreationAutoScroll()
            if isCreating, let range = creationPreviewRange() {
                let minDuration: TimeInterval = 15 * 60
                let finalRange = range.end.timeIntervalSince(range.start) < minDuration
                    ? Event.TimeRange(start: range.start, end: range.start.addingTimeInterval(minDuration))
                    : range
                callbacks.onCreateEvent?(finalRange)
            }
            resetCreationState()

        case .cancelled, .failed:
            stopCreationAutoScroll()
            resetCreationState()

        default:
            break
        }
        _ = host
    }

    private func resetCreationState() {
        isCreating = false
        isLongPressingCreation = false
        lastTickMinutes = -1
        lastSnappedStartEdge = nil
        lastSnappedEndEdge = nil
        verticalScrollView = nil
        // Clear the live preview mapping.
        if let date = host?.liveModel?.date {
            callbacks.onCreationPreviewChanged?(date, nil)
        }
    }

    private func pushCreationPreview() {
        guard let date = host?.liveModel?.date else { return }
        callbacks.onCreationPreviewChanged?(date, isCreating ? creationPreviewRange() : nil)
    }

    private func creationPreviewRange() -> Event.TimeRange? {
        guard isCreating else { return nil }
        let startTime = timeFromYWithAdjacentSnap(creationStartY).snappedTime
        let endTime = timeFromYWithAdjacentSnap(creationCurrentY).snappedTime
        return startTime < endTime
            ? Event.TimeRange(start: startTime, end: endTime)
            : Event.TimeRange(start: endTime, end: startTime)
    }

    private func timeFromYWithAdjacentSnap(_ y: CGFloat) -> (snappedTime: Date, snappedEdge: Date?) {
        guard let host, let model = host.liveModel else {
            return (host?.dateFromY(y, snapMinutes: 15) ?? Date(), nil)
        }
        let candidate = host.dateFromY(y, snapMinutes: 15)
        guard model.hourHeight > 0 else { return (candidate, nil) }
        let raw = calendarTimelineDateFromYPosition(
            y, containing: model.date, headerHeight: model.headerHeight, hourHeight: model.hourHeight,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours, snapMinutes: 1
        )
        let thresholdSeconds = TimeInterval(adjacentEventSnapThresholdPt / model.hourHeight * 3600)
        return calendarApplyAdjacentEventSnap(
            candidateTime: candidate, rawTime: raw,
            neighborEdges: neighborEventEdges(), thresholdSeconds: thresholdSeconds
        )
    }

    private func neighborEventEdges() -> [Date] {
        guard let host else { return [] }
        var edges: [Date] = []
        for (_, rf) in host.renderedFrames {
            edges.append(rf.occurrence.range.start)
            edges.append(rf.occurrence.range.end)
        }
        return edges
    }

    private func currentSnappedMinutes(for y: CGFloat) -> Int {
        guard let model = host?.liveModel else { return 0 }
        let time = host?.dateFromY(y, snapMinutes: 15) ?? model.date
        let visibleStart = calendarTimelineVisibleStart(
            containing: model.date, leadingExtendedHours: model.leadingExtendedHours
        )
        return Int((time.timeIntervalSince(visibleStart) / 60).rounded())
    }

    private func checkCreationHapticTick() {
        let minutes = currentSnappedMinutes(for: creationCurrentY)
        if minutes != lastTickMinutes {
            lastTickMinutes = minutes
            createHaptic.impactOccurred()
        }
    }

    private func checkAdjacentSnapHaptic() {
        let startEdge = timeFromYWithAdjacentSnap(creationStartY).snappedEdge
        let endEdge = timeFromYWithAdjacentSnap(creationCurrentY).snappedEdge
        if startEdge != lastSnappedStartEdge {
            if startEdge != nil { snapHaptic.selectionChanged() }
            lastSnappedStartEdge = startEdge
        }
        if endEdge != lastSnappedEndEdge {
            if endEdge != nil { snapHaptic.selectionChanged() }
            lastSnappedEndEdge = endEdge
        }
    }

    // Creation auto-scroll (G-54): vertical-only, identical curve.
    private func startCreationAutoScroll() {
        guard creationAutoScrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleCreationAutoScrollTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        creationAutoScrollLink = link
    }

    private func stopCreationAutoScroll() {
        creationAutoScrollLink?.invalidate()
        creationAutoScrollLink = nil
    }

    private func updateCreationAutoScrollVelocity() {
        guard isCreating, let sv = verticalScrollView else {
            stopCreationAutoScroll()
            return
        }
        let velocity = creationVerticalVelocity(for: sv)
        if velocity == 0 { stopCreationAutoScroll() } else { startCreationAutoScroll() }
    }

    @objc private func handleCreationAutoScrollTick(_ link: CADisplayLink) {
        guard let sv = verticalScrollView else { stopCreationAutoScroll(); return }
        let velocity = creationVerticalVelocity(for: sv)
        guard velocity != 0 else { stopCreationAutoScroll(); return }
        let dt = max(link.targetTimestamp - link.timestamp, 0)
        let delta = velocity * CGFloat(dt)
        _ = applyAutoScroll(on: sv, delta: CGPoint(x: 0, y: delta))
        // Extend the preview as the content scrolls under a stationary finger.
        if let gesture = createGesture, let view = gesture.view {
            creationCurrentY = gesture.location(in: view).y
        }
        if isCreating { checkCreationHapticTick(); pushCreationPreview() }
    }

    private func creationVerticalVelocity(for scrollView: UIScrollView) -> CGFloat {
        guard let gesture = createGesture else { return 0 }
        let loc = gesture.location(in: nil).y - scrollView.convert(scrollView.bounds, to: nil).minY
        let minOffset = -scrollView.adjustedContentInset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        return calendarAutoScrollVelocity(
            locationInViewport: loc, viewportLength: scrollView.bounds.height,
            currentOffset: scrollView.contentOffset.y, minOffset: minOffset, maxOffset: maxOffset,
            edgeInset: calendarVerticalAutoScrollEdgeInsetDefault, maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
    }
}

/// Long-press subclass that swallows touch-cancels once a drag has promoted,
/// so a SwiftUI content rebuild mid-drag cannot cancel the active gesture
/// (G-30). Mirrors `EventBlockDragGesture.TracingLongPressGesture`.
final class TracingLongPressGesture: UILongPressGestureRecognizer {
    var isDragPromoted = false

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if isDragPromoted { return }  // absorb (G-30)
        super.touchesCancelled(touches, with: event)
    }
}

