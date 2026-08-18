import SwiftUI
import QuartzCore

struct FocusModeView: View {
    let events: [Event]
    /// Available type templates surfaced in the empty-state's
    /// "Start tracking" row. Empty list hides the section entirely.
    var templates: [EventTypeTemplate] = []
    /// Invoked when the user requests to leave focus mode. Triggered by
    /// a deliberate swipe-down gesture (or by rotation back to portrait
    /// at the OrientationManager level when applicable). We deliberately
    /// avoid tap-to-exit because focus mode is a now-workspace where
    /// chips, the protagonist, and quick action buttons all want their
    /// own tap targets.
    var onExit: () -> Void = {}
    /// Whether `onExit` actually ends the focus session. Rotation-driven
    /// focus is held open by the device's orientation, which `onExit`
    /// does not touch — committing a swipe there would fling the surface
    /// off-screen and leave it stranded with the overlay still mounted.
    /// The host passes `false` while that path owns the session and the
    /// swipe bails out instead.
    var canExitBySwipe: Bool = true
    /// Adjust the current event's end time by the given delta.
    var onExtendCurrent: (Event, TimeInterval) -> Void = { _, _ in }
    /// End the current event at the given date (typically `now`).
    var onEndCurrent: (Event, Date) -> Void = { _, _ in }
    /// Append a focus-mode timeline note to the current event. Caller
    /// constructs the occurrence context and stamps the createdAt.
    var onAddNoteToCurrent: (CalendarLayout.EventOccurrence, String) -> Void = { _, _ in }
    /// Quick-record: start a new event of the given type at the given
    /// start, with the given end and title. The view passes computed
    /// values so the caller doesn't decide defaults — preview adjustments
    /// flow through here intact, and the quick path passes its own
    /// snapped defaults.
    var onStartTracking: (_ template: EventTypeTemplate, _ title: String, _ start: Date, _ end: Date) -> Void = { _, _, _, _ in }

    @AppStorage(AppSettingsKeys.focusConfirmBeforeTracking) private var confirmBeforeTracking = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var dragOffsetY: CGFloat = 0
    /// 0 the moment the surface mounts, driven to 1 by `onAppear`, so the
    /// focus surface fades itself up over whatever was on screen.
    ///
    /// The entrance is owned here rather than declared as a `.transition`
    /// on the host's `if`, because a transition only runs when the update
    /// that flips that branch happens to carry an animation — and in this
    /// app it doesn't. Instrumented over repeated launches, a
    /// `withAnimation` around the flag write drove the insertion 0 times
    /// out of 5; this fades 5 out of 5, and 3 out of 3 when driven by an
    /// actual tap on the header's Focus button. Nothing outside this view
    /// has to cooperate for it to work.
    @State private var entryProgress: Double = 0
    /// Non-nil when the user tapped a type pill while
    /// `confirmBeforeTracking` is on — holds the chosen template so the
    /// preview surface can render. Cleared by Cancel or by Confirm
    /// (which fires `onStartTracking` and lets the view auto-flip into
    /// the inhabiting state when the new event resolves).
    @State private var pendingProposalTemplate: EventTypeTemplate?
    /// Identifies the swipe-dismiss that is currently flying off-screen,
    /// `nil` when none is. It is an identity and not a flag because a
    /// caught commit can be followed by another one before the first
    /// animation reports back: only the completion whose id still
    /// matches may fire `onExit`.
    @State private var pendingDismissID: UUID?
    /// Latched once a touch has travelled far enough down to count as a
    /// drag, and held for the rest of that gesture. The gesture
    /// recognizes at zero distance — that is what lets a finger catch a
    /// dismissal in flight — so `onEnded` needs this to tell a drag from
    /// a tap. Latched rather than re-derived per update because a drag
    /// that goes 40pt down and then back to 10pt is still the same drag:
    /// re-testing the distance would drop the surface out from under the
    /// finger on the way back up and freeze it at the far point.
    @State private var isTrackingDrag = false
    /// `startLocation` of the gesture `isTrackingDrag` belongs to. Set on
    /// the first update of a gesture and cleared by `onEnded`, so it is
    /// `nil` between gestures that ended — and deliberately *not* nil
    /// after one the system cancelled, which is exactly the case it
    /// exists to detect. It is what tells a fresh touch from a continuing
    /// one, because `onEnded` is not delivered on a cancellation and both
    /// the latch and the offset can survive into the next touch. See
    /// `beginGestureIfNew`.
    @State private var latchedGestureStart: CGPoint?
    /// What the surface is doing that a tracked write would have to
    /// interrupt, `nil` when it is at rest and a bare write is right.
    ///
    /// Three writers, and all three are writers: `settleSurfaceHome`
    /// records what it is settling; every tracked update either latches
    /// `.smoothing` for the rest of its gesture or clears the record; and
    /// both gesture boundaries (`beginGestureIfNew`, `onEnded`) end the
    /// `.smoothing` latch, which belongs to one gesture and must not
    /// outlive it.
    ///
    /// How they end it depends on what they have to put in its place. A
    /// boundary that settles overwrites the latch with the settle's own
    /// record, and settles *first* rather than dropping it in advance —
    /// the latch is what tells that settle where the surface is. A
    /// boundary with nothing to settle re-labels it as `.settling`
    /// instead of dropping it, because a model already at rest does not
    /// mean nothing is in flight: see `focusCancelledGestureRecord`. The
    /// commit does neither and drops it to `nil`, deliberately — nothing
    /// describes the fly-off, see the `defer` in `onEnded`.
    /// See `trackSurface`.
    @State private var surfaceMotion: FocusSurfaceMotion?
    /// Whether the app has been fully backgrounded since the last time it
    /// became active. The backstop in `applyForegroundDismissRecovery`
    /// needs a *round trip*, not merely a return to `.active`: pulling
    /// down Control Center over a dismissal in flight passes through
    /// `.inactive` while the animation keeps running perfectly well.
    @State private var wasBackgrounded = false

    /// The curve focus arrives on. Same 0.4s ease the rotation path uses
    /// for its own change, so entering by tapping the header button and
    /// entering by turning the device look alike.
    private let entryFade: Animation = .easeInOut(duration: 0.4)
    /// How long after `range.end` an event is still resolved as the
    /// focus session's "current" event. Without this, an event silently
    /// drops out the moment its scheduled end passes — the user has no
    /// chance to see "Xm over" or to act (extend, mark complete) from
    /// the same surface they'd been working on. The window matches what
    /// a user typically takes to look up at the screen and react.
    private let overrunGraceWindow: TimeInterval = 5 * 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let allToday = CalendarLayout.occurrencesForDate(events, date: now)
            let current = focusCurrentOccurrence(
                in: allToday,
                now: now,
                overrunGrace: overrunGraceWindow
            )

            GeometryReader { geo in
                let isPortrait = geo.size.height > geo.size.width

                ZStack {
                    Color(.systemBackground)
                        .ignoresSafeArea()

                    if let occ = current {
                        FocusModeEventView(
                            event: occ.event,
                            range: occ.range,
                            now: now,
                            allOccurrences: allToday,
                            isPortrait: isPortrait,
                            quickActionsEnabled: focusQuickActionAllowedForEvent(occ.event),
                            onExtend: { delta in onExtendCurrent(occ.event, delta) },
                            onEndNow: { onEndCurrent(occ.event, now) },
                            onAddNote: { text in onAddNoteToCurrent(occ, text) }
                        )
                        // Identity per occurrence: when the protagonist
                        // rolls over (back-to-back events), the old view
                        // must UNMOUNT — its onDisappear commits a pending
                        // note draft against the occurrence it was typed in.
                        // Without this the view updates in place and the
                        // draft's eventual commit lands on the successor.
                        .id(occ.id)
                        .transition(focusEnterTransition(color: CalendarLayout.eventColor(for: occ.event)))
                    } else if let pending = pendingProposalTemplate {
                        FocusPreCreateView(
                            template: pending,
                            now: now,
                            proposedStart: calendarSnapDateToMinuteGrid(now),
                            allOccurrences: allToday,
                            isPortrait: isPortrait,
                            onConfirm: { title, start, end in
                                onStartTracking(pending, title, start, end)
                                pendingProposalTemplate = nil
                            },
                            onCancel: {
                                pendingProposalTemplate = nil
                            }
                        )
                        .transition(.opacity)
                    } else {
                        FocusModeClockView(
                            now: now,
                            allOccurrences: allToday,
                            isPortrait: isPortrait,
                            templates: templates,
                            onStartTracking: handleClockTrackingTap
                        )
                        .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.85), value: current?.id)
                .animation(.easeOut(duration: 0.22), value: pendingProposalTemplate?.id)
                // The gate can close while a dismissal is still flying
                // off-screen: rotating into landscape with landscape-focus
                // on makes `onExit` unable to end the session, and the
                // surface would be left sitting past the bottom edge with
                // the overlay still mounted and swallowing touches.
                // Sampling `canExitBySwipe` once at commit can't see that,
                // and re-reading it inside the animation completion is
                // inert — the completion closes over the view value, so
                // the `let` it reads is the one captured at commit time.
                // `@State` (`pendingDismissID`, `dragOffsetY`) reads
                // through its box and IS live, which is why the recovery
                // has to be driven from the gate moving.
                //
                // Strictly the in-flight case, which is why this goes
                // through `catchPendingDismiss` and its
                // `pendingDismissID != nil` guard rather than settling
                // unconditionally: the gate also closes while the user is
                // simply mid-drag with a finger down and nothing
                // committed. Springing the offset home there would drop
                // the surface out from under a stationary finger, and the
                // next `onChanged` would write the same offset straight
                // back — a jitter under a finger that never moved.
                //
                // Known sliver, left alone: if the completion fires and
                // `onExit` returns without the host unmounting us, the id
                // is already nil and this does nothing, leaving the
                // surface parked at `exitTravel` where it cannot be
                // hit-tested. It needs the completion to win a race with
                // this handler inside one frame — the ordinary rotation
                // ordering is covered, and QA caught it 4 for 4. The
                // recovery would have to settle unconditionally, which is
                // the shape that jittered under a stationary finger, so
                // it would need a finger-down guard. One exists, and an
                // earlier version of this comment asserted the opposite:
                // `@GestureState` + `.updating` is reset by SwiftUI when
                // a gesture ends *or is cancelled*, which is the case
                // `latchedGestureStart` deliberately cannot cover, and
                // the repo already uses it in `WannaCardView` and
                // `ReminderPanelView`. Left unbuilt because the hazard is
                // unreached, not because the belt is unavailable.
                .onChange(of: canExitBySwipe) { _, canExit in
                    guard !canExit else { return }
                    catchPendingDismiss()
                }
                // `onExit` has exactly one caller — the completion of the
                // animation that flies the surface off-screen — and no
                // backstop. A completion that never runs leaves the model
                // at `exitTravel`, the surface entirely off-screen and so
                // unhittable, and nothing else writes it: a focus session
                // the user cannot end. Returning from a full background
                // trip is the one moment we can tell that happened,
                // because a completion that was going to run has by then.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        wasBackgrounded = true
                    } else if phase == .active {
                        applyForegroundDismissRecovery()
                    }
                }
                .foregroundStyle(Color(.label))
                .offset(y: max(0, dragOffsetY))
                .opacity(entryProgress)
                .onAppear {
                    withAnimation(entryFade) { entryProgress = 1 }
                }
                .simultaneousGesture(
                    // Recognizes at zero distance so that putting a finger
                    // down is itself an event: a dismissal already in
                    // flight has to be catchable, and the 20pt gate this
                    // used to carry meant a finger could land on the
                    // moving surface without the gesture firing at all —
                    // focus then exited from behind it. Travel is gated in
                    // `onChanged` instead.
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            beginGestureIfNew(startLocation: value.startLocation)
                            catchPendingDismiss()
                            // Suppress while preview is up — the picker
                            // owns vertical drags, and accumulating a
                            // dragOffsetY on top would shove the whole
                            // view down underneath it. The user backs
                            // out of preview via Cancel, then can
                            // swipe-down from the clock view.
                            guard pendingProposalTemplate == nil else { return }
                            guard focusDragShouldTrack(
                                isTracking: isTrackingDrag,
                                translationY: value.translation.height,
                                activationDistance: FocusSurfaceMetrics.dragActivationDistance
                            ) else { return }
                            isTrackingDrag = true
                            // Only track downward translation; ignore upward
                            // so users can't accidentally pull from the
                            // bottom and bounce.
                            trackSurface(to: max(0, value.translation.height))
                        }
                        .onEnded { value in
                            let wasTrackingDrag = isTrackingDrag
                            isTrackingDrag = false
                            latchedGestureStart = nil
                            // The handoff latch belongs to the gesture
                            // that just ended and cannot outlive it — but
                            // it is also the only record of where the
                            // *presentation* got to, and a settle starts
                            // from the presentation, not from the model.
                            // So it is dropped on the way out rather than
                            // on the way in, and by then every branch has
                            // put something better in its place: the ones
                            // that settle or re-label record a `.settling`
                            // over the top, which this leaves alone; the
                            // commit deliberately leaves the fly-off
                            // described by nothing, which is what this
                            // makes true; and a tap decides nothing, so
                            // whatever is left is stale.
                            defer {
                                if surfaceMotion?.isSmoothing == true {
                                    surfaceMotion = nil
                                }
                            }
                            guard pendingProposalTemplate == nil else {
                                // The one write site that used to snap.
                                // The `dragOffsetY != 0` guard is what
                                // does the work here. On the path this
                                // was written for — a dismissal caught by
                                // the type-pill tap that raises the
                                // preview — the catch has already sprung
                                // the *model* home, so `dragOffsetY` is 0
                                // and this is a no-op: right, because the
                                // settle that catch started is the one
                                // that should finish, and what used to
                                // happen here was an unanimated reset
                                // cutting it short. It settles for real
                                // only when the preview goes up over a
                                // surface genuinely off its rest position
                                // with nothing already bringing it home.
                                //
                                // Nothing to settle is not nothing in
                                // flight, though, and without the `else`
                                // the `defer` above drops the only record
                                // of it — the same loss
                                // `beginGestureIfNew` was fixed for, with
                                // the same 20-238pt backwards step on the
                                // next gesture. Reaching it here takes a
                                // second finger raising the preview while
                                // the first is mid-drag with the model
                                // upward-clamped, which is exotic; the
                                // fix is the same rule either way, and
                                // `.settling` is not a latch, so the
                                // `defer` leaves it alone.
                                if dragOffsetY != 0 {
                                    settleSurfaceHome()
                                } else {
                                    surfaceMotion = focusCancelledGestureRecord(
                                        motion: surfaceMotion,
                                        modelOffset: dragOffsetY,
                                        spring: FocusSurfaceMetrics.settleSpring,
                                        now: CACurrentMediaTime()
                                    )
                                }
                                return
                            }
                            // A touch that never became a drag — a tap on
                            // the protagonist, a chip flick — decides
                            // nothing.
                            guard wasTrackingDrag else { return }
                            let released = value.velocity.height
                            if focusDismissCommits(
                                projectedTranslationY: value.predictedEndTranslation.height,
                                surfaceHeight: geo.size.height,
                                canExitBySwipe: canExitBySwipe
                            ) {
                                // Commit: the same tracked offset carries on
                                // off-screen, and only once it is gone do we
                                // tear the overlay down — the dismissal is
                                // the finger's motion continuing, not a cut.
                                // Nothing resets the offset afterwards; the
                                // view is unmounted by then, and writing to
                                // it would render the surface back at rest
                                // for a frame before the teardown lands.
                                let id = UUID()
                                pendingDismissID = id
                                // Travel the long edge rather than the
                                // current height: leaving focus forces the
                                // app back to portrait, and a surface sent
                                // just past a landscape height would be
                                // re-laid-out onto the screen again while
                                // the overlay is still fading out.
                                let exitTravel = max(geo.size.width, geo.size.height)
                                let remaining = max(exitTravel - dragOffsetY, 1)
                                // Deliberately *not* guarded the way the
                                // settle's injection is. A smoothed
                                // gesture leaves a spring in flight that
                                // already carries the finger's motion, so
                                // adding `released` on top double-counts
                                // it here exactly as it would there — but
                                // the two cases are not symmetric in what
                                // the double-count costs.
                                //
                                // A settle has to land on rest and be
                                // described afterwards: too much velocity
                                // overshoots a target the user is looking
                                // at, and the record that the next
                                // gesture gates on is wrong by the same
                                // amount. This lands off-screen, where
                                // there is nothing to see past the
                                // target — and ζ = 1 on its own would
                                // not say so. `dismissSpring` has
                                // bounce 0, but a critically damped
                                // flight still overshoots when it is
                                // launched faster than ω_n times the
                                // travel it has left, which here is
                                // 2π/0.35 × 754pt ≈ 13500pt/s for a
                                // 120pt drag on an 874pt surface: an
                                // order of magnitude past any finger,
                                // and sub-point for a good way past
                                // that. It is also described to nobody:
                                // no record is written for the
                                // fly-off — the `defer` clears this
                                // gesture's latch and nothing replaces it
                                // — and a catch settles from the model by
                                // design. The whole error is
                                // "leaves somewhat faster than the finger
                                // asked for", in the direction it is
                                // already going.
                                //
                                // So it is left alone rather than
                                // corrected, because correcting it would
                                // change a fly-off QA has signed off on
                                // to buy nothing. If the dismissal ever
                                // grows a record, this has to be revisited
                                // with it.
                                withAnimation(
                                    .interpolatingSpring(
                                        FocusSurfaceMetrics.dismissSpring,
                                        initialVelocity: released / remaining
                                    ),
                                    completionCriteria: .logicallyComplete
                                ) {
                                    dragOffsetY = exitTravel
                                } completion: {
                                    guard pendingDismissID == id else { return }
                                    pendingDismissID = nil
                                    onExit()
                                }
                            } else {
                                settleSurfaceHome(releaseVelocity: released)
                            }
                        }
                )
            }
        }
    }

    /// Note the gesture this update belongs to, and clean up after the
    /// previous one if it never reported an end.
    ///
    /// `onEnded` is not delivered when the system cancels a gesture — an
    /// incoming call banner, a Face ID prompt — so `isTrackingDrag` and
    /// `dragOffsetY` can both survive into the next touch. The stranded
    /// latch is the dangerous one: `onEnded`'s `guard`, whose whole job
    /// is "a tap decides nothing", would pass for a tap, and an 8pt tap
    /// released at ~900pt/s projects ~233pt — past the gate. Focus would
    /// exit on what the user did as a tap. (The old `minimumDistance: 20`
    /// made that unreachable because a tap produced no gesture at all;
    /// recognizing at zero distance is what reopened it.) A stranded
    /// offset is milder — the surface just sits parked off its rest
    /// position with nothing to bring it home — but it is fixed here too.
    ///
    /// Gestures are told apart by `startLocation`, which is fixed for the
    /// life of a gesture. `onEnded` clears the record, so this comparison
    /// only does real work after a cancellation, where two consecutive
    /// touches would have to land on bit-identical coordinates to be
    /// mistaken for one.
    private func beginGestureIfNew(startLocation: CGPoint) {
        guard focusDragIsNewGesture(
            latchedStart: latchedGestureStart,
            updateStart: startLocation
        ) else { return }
        latchedGestureStart = startLocation
        isTrackingDrag = false
        // A dismissal in flight is not stranded — `catchPendingDismiss`
        // runs straight after this and owns that case.
        guard pendingDismissID == nil, dragOffsetY != 0 else {
            // `.smoothing` is a per-gesture latch and the gesture that
            // set it is over, so this touch must not read it *as a
            // latch*. On a cancellation this is the only place that
            // hears about it — `onEnded`, which ends it on every other
            // path, is not delivered.
            //
            // Dropping it to `nil`, which is what this branch used to
            // do, loses the same thing the branch below was fixed for
            // losing. The model is at 0 here, but a spring can still be
            // in flight carrying the surface down to it: drag past the
            // deadband, bring the finger back above where it started —
            // `max(0, translation)` clamps the model — and the last
            // tracked write aimed a smoothed spring at 0 from wherever
            // the surface had got to. So it is re-labelled rather than
            // dropped, and `focusCancelledGestureRecord` is where that
            // rule and what it costs to get wrong are written down.
            //
            // The re-label needs `toward == 0`, which it gets from
            // `dragOffsetY == 0`. The other half of the guard therefore
            // has to be shown never to arrive holding a `.smoothing`
            // record, and it is: `.smoothing` is written only by
            // `trackSurface`, and `onChanged` runs `catchPendingDismiss`
            // before ever reaching it, which nils `pendingDismissID`. So
            // no latch is established while a dismissal is outstanding.
            // Nor does one survive the commit that starts a dismissal:
            // `onEnded`'s `defer` drops it at closure exit, which is
            // after `pendingDismissID` is assigned but inside the same
            // invocation, so nothing runs in between to observe the
            // pair.
            // `testFocusUpwardClampedCancellationKeepsThePresentation`
            // pins the re-label; the `pendingDismissID` half is an
            // argument about this file, with no test behind it.
            surfaceMotion = focusCancelledGestureRecord(
                motion: surfaceMotion,
                modelOffset: dragOffsetY,
                spring: FocusSurfaceMetrics.settleSpring,
                now: CACurrentMediaTime()
            )
            return
        }
        // The latch is dropped *by* the settle, not before it: the same
        // ordering `onEnded` gets from its `defer`, for the same reason.
        // It is the only record of where the *presentation* got to, and
        // a settle starts from the presentation. `settleSurfaceHome`
        // overwrites `surfaceMotion` unconditionally, so it is the drop.
        //
        // Clearing it first is what round 6 shipped, and it left this
        // path — the one `onEnded` does not cover — recording the model
        // for exactly the gestures the record exists to describe. See
        // `testFocusCancelledGestureSettlesFromThePresentationNotTheModel`
        // for how far apart the two readings are and what it costs.
        settleSurfaceHome()
    }

    /// Follow the finger.
    ///
    /// The bare write is what makes the surface track exactly, and is
    /// right whenever the surface is at rest. It is wrong while an
    /// animation is in flight: an unanimated write removes the animation
    /// and jumps straight to the new value. Catching a dismissal and then
    /// dragging measured a 148pt backwards jump in a single frame on
    /// exactly that — the catch springs the *model* home while the
    /// *presentation* is still 170pt down the screen, and the first
    /// tracked write snapped the two together.
    ///
    /// So every tracked update asks `focusSurfaceHandoff` where the
    /// surface actually is, and hands off through an interpolating spring
    /// when a bare write would pull it backwards past the finger.
    /// Interpolating springs are additive: this update's travel is added
    /// to the motion already in flight rather than replacing it, so the
    /// surface converges on the finger instead of teleporting to it.
    ///
    /// The first tracked update of a gesture is the one that decides:
    /// whichever way it goes it writes the answer back, and the rest of
    /// the gesture reads it. Latched, because going rigid partway would
    /// only move the jump to the frame it happened on.
    ///
    /// The cost is a tracking lag, and there are two numbers for it
    /// because there are two things being described.
    ///
    /// **What the device does.** The steady lag is 0.060s × v — 17pt at
    /// 300pt/s, 61pt at 1000pt/s. This is the measured one and it is no
    /// longer in dispute. QA settled it in round 10 with a control that
    /// removes the confound the earlier rounds could not: one monotonic
    /// script per run, gesture 1 a bare 1:1 write from rest to anchor the
    /// alignment, gesture 2 arriving 40ms later so it is spring-routed.
    /// Anchoring on a known-1:1 window is what separates a fixed clock
    /// error from a lag time-constant. Five runs normalise to 63.1 / 61.1
    /// / 60.5pt per 1000pt/s — mean 61.6 — with the 1:1 anchor residual at
    /// −0.07 / +0.09 / +0.02pt, so any clock error is ≤ 2×10⁻⁴s, worth
    /// ≤ 0.2pt at 1000pt/s. Plateaus flat to ±1pt over 15-79 consecutive
    /// frames, and a different protocol reproduced it independently: P4's
    /// 1000pt/s re-swipe trailed 61.54pt.
    ///
    /// **What this spring does.** Driven through `focusSurfaceHandoff`
    /// itself against a finger moving at a constant v, the surface trails
    /// by 82.2pt at 100ms and 110.2pt once the lag stops growing, for
    /// v = 1000pt/s at 60Hz. The continuous-time lag of this spring
    /// following a ramp is 2ζ/ω_n · v, or 0.1019s × v, and the plateau
    /// sits *above* it by half a frame of finger travel — 8.3pt at 60Hz,
    /// 4.2pt at 120, to within 10⁻³pt at 60Hz — because the record aims at
    /// where the finger was when it was stamped and it is the *next*
    /// update that reads it. (An earlier pair of figures here, 73.5 and
    /// 93.5, came from a fixture that stepped toward the current finger
    /// instead: a whole frame of travel out, and it made 0.1019s × v look
    /// like an upper bound.)
    ///
    /// These are both right and they are not about the same thing. 110.19
    /// and 101.86 are statements about the model — exact, reproducible,
    /// and bit-identical to an explicit simulation of additive
    /// interpolating springs, which a reviewer verified. They are *not*
    /// predictions of the screen, and earlier versions of this comment
    /// used them as though they were: 61 was written up as "26-45% under
    /// every steady reading of this spring", as if being under the model
    /// made it wrong. It is 1.8× under, and the device is the thing being
    /// described.
    ///
    /// The gap is scoped, and the scope is the interesting part. A *lone*
    /// settle matches the solver to 1-2pt on the device — 99.94 against
    /// 99.17, 85.70 against 87.42 — and the round-10 catch traces came in
    /// at 41.88 / 49.14 / 64.97 / 69.21 against the solver's shape. The
    /// over-prediction appears only once a tracking chain is composed on
    /// top of a settle, which is exactly the regime this function creates
    /// and exactly the regime `focusTrackedLagPerFrame` measures. So the
    /// solver stays the thing the *gate* is built on — `focusSurfaceHandoff`
    /// decides about a settle, where the model is accurate to a point or
    /// two — and stops being the thing the *lag* is quoted from.
    /// `testFocusTrackingLagIsTheSpringsOwn` pins both, and says which is
    /// which. Closing the lag rather than re-modelling it is gh#175.
    ///
    /// (Two earlier versions of this comment tried to put a decay time
    /// on the lag and neither survives. "0.01pt within ~317ms" was not
    /// derivable from the pinned constants; the correction that replaced
    /// it — "61 × 1.667 × e^(−12.566t) = 0.01 gives 734ms, and 317ms
    /// leaves ~1.1pt" — is two different formulas in one sentence. With
    /// the 1/√(1−ζ²) gain 317ms leaves 1.89pt and the threshold is at
    /// 734ms; without it, 1.14pt and 694ms. Neither is load-bearing. The
    /// 61 they rest on is no longer disputed, but it is a *steady-state*
    /// figure and carries no decay law with it, so neither reconstruction
    /// gets any better for that.)
    ///
    /// The lag is a fair price on a catch, where the alternative is a
    /// 148-324pt teleport, and a bad one on an ordinary swipe — which is
    /// why where the settle has got to, and not merely how long ago it
    /// started, is what opens the window.
    ///
    /// Every smoothed update also advances the record of where the
    /// *presentation* is, because from here on the model does not
    /// describe it: the surface is behind the finger by the lag above,
    /// and the settle this gesture ends with starts from the surface.
    /// Solved through the record, a spring-routed 120pt swipe at
    /// 1000pt/s ends 77.0pt behind the finger.
    private func trackSurface(to offset: CGFloat) {
        let handoff = focusSurfaceHandoff(
            motion: surfaceMotion,
            trackedOffset: offset,
            spring: FocusSurfaceMetrics.settleSpring,
            visibilityMargin: FocusSurfaceMetrics.handoffMargin,
            renderPhase: FocusSurfaceMetrics.handoffPhase,
            now: CACurrentMediaTime()
        )
        surfaceMotion = handoff.motion
        guard handoff.animate else {
            dragOffsetY = offset
            return
        }
        withAnimation(.interpolatingSpring(FocusSurfaceMetrics.settleSpring)) {
            dragOffsetY = offset
        }
    }

    /// Spring the surface back to rest, and record what the presentation
    /// will be doing so a drag arriving while it is still moving hands
    /// off through `trackSurface` instead of snapping.
    ///
    /// Two things go into the record and both matter. Where the surface
    /// *is*, which is not `dragOffsetY` unless nothing was in flight; and
    /// how fast it is moving, because a settle that leaves at 1500pt/s
    /// *downward* — every flick whose projection misses the commit gate,
    /// and under a closed gate every swipe at any speed — is still
    /// essentially where it started 80ms later, while a step response
    /// from rest says it is 40% of the way back. (It goes *further* out
    /// first, peaking 22% past its start at 33ms, and 80ms is where it
    /// crosses back. The two readings differ by 40pt on a 100pt settle,
    /// and the sign of the error flips inside that window, which is why
    /// no fixed correction would do.
    /// `testFocusPresentedStateCarriesTheReleaseVelocity` pins it.)
    ///
    /// Neither error is safe in one direction. Reading high keeps the
    /// handoff armed longer than needed, and over-arming is what round 4
    /// shipped: 61pt of trailing lag on an ordinary re-swipe. Reading low
    /// writes bare through a real backwards pop, which is what round 5
    /// shipped: 54pt up the screen in a single frame under a closed gate,
    /// against a settle moving 11.7pt per frame. The constraint is
    /// two-sided, so the answer is not to pick an error direction but to
    /// ask the spring, which `focusSettlePlan` does.
    ///
    /// `releaseVelocity` is the finger's, in points per second, positive
    /// downward. Whether it is injected at all depends on what was
    /// already in flight — see `focusSettlePlan`.
    private func settleSurfaceHome(releaseVelocity: CGFloat = 0) {
        let plan = focusSettlePlan(
            motion: surfaceMotion,
            modelOffset: dragOffsetY,
            releaseVelocity: releaseVelocity,
            spring: FocusSurfaceMetrics.settleSpring,
            now: CACurrentMediaTime()
        )
        withAnimation(
            .interpolatingSpring(
                FocusSurfaceMetrics.settleSpring,
                initialVelocity: plan.initialVelocity
            )
        ) {
            dragOffsetY = 0
        }
        surfaceMotion = plan.motion
    }

    /// Recover a dismissal whose completion never reported back. Inert
    /// unless the app actually went to the background and came back with
    /// one still outstanding — see the `scenePhase` handler in `body`.
    /// Honouring the commit is the faithful reading (the user swiped to
    /// leave), except under the closed gate, where `onExit` cannot end
    /// the session and would leave the surface off-screen exactly as the
    /// dropped completion did.
    private func applyForegroundDismissRecovery() {
        let recovery = focusDismissRecoveryOnForeground(
            hasPendingDismiss: pendingDismissID != nil,
            canExitBySwipe: canExitBySwipe,
            returnedFromBackground: wasBackgrounded
        )
        wasBackgrounded = false
        switch recovery {
        case .none:
            break
        case .exit:
            pendingDismissID = nil
            onExit()
        case .settle:
            cancelDismissAndSettle()
        }
    }

    /// Give up on a dismissal that is still flying off-screen and bring
    /// the surface home. Guarded on there actually being one so that an
    /// ordinary touch doesn't start a spring that fights the finger.
    private func catchPendingDismiss() {
        guard pendingDismissID != nil else { return }
        cancelDismissAndSettle()
    }

    /// Revoke whatever dismissal is outstanding and put the surface back
    /// at rest. Clearing the id is what stops the in-flight animation's
    /// completion from firing `onExit` after the fact; the spring is
    /// interpolating, so it picks the surface up at its current speed
    /// rather than from a standstill.
    ///
    /// The `dragOffsetY` write is guarded on the surface being off its
    /// rest position. An unconditional reset here is the shape that
    /// previously raced the teardown of a successful exit and painted a
    /// full-opacity ghost frame — this one can only run when the surface
    /// is somewhere it shouldn't be and is staying mounted.
    private func cancelDismissAndSettle() {
        pendingDismissID = nil
        guard dragOffsetY != 0 else { return }
        settleSurfaceHome()
    }

    /// Bridge between the idle clock's type-pill tap and the actual
    /// event creation. With the toggle off (default) we skip the preview
    /// and go straight to creation. With it on we surface the preview
    /// and wait for confirm. Either way, the call into
    /// `onStartTracking` is the single creation point.
    private func handleClockTrackingTap(_ template: EventTypeTemplate) {
        // Raising the preview over a surface that is on its way out would
        // leave the dismissal to complete underneath it.
        catchPendingDismiss()
        if confirmBeforeTracking {
            pendingProposalTemplate = template
        } else {
            let now = Date()
            let start = calendarSnapDateToMinuteGrid(now)
            let end = start.addingTimeInterval(30 * 60)
            onStartTracking(template, template.title, start, end)
        }
    }
}

/// The constants the focus surface's motion is defined by.
///
/// They live out here rather than as `private let`s on the view because
/// the free functions below are what use them and the tests are the
/// second reader, and a test that declares its own
/// `Spring(duration: 0.4, bounce: 0.2)` beside a comment claiming to pin
/// the view's is not pinning anything: the view's copy could be changed
/// to any other spring and all 15 handoff tests would still pass while
/// the admit window moved by 40% and every number in the comments here
/// became wrong. `visibilityMargin: 20` and a hard-coded first-tracked
/// offset of 21 were duplicated the same way. One declaration, two
/// readers.
enum FocusSurfaceMetrics {
    /// Springs, not fixed durations: they take the release velocity as
    /// their initial velocity so the surface keeps the finger's motion,
    /// and being interpolating they blend with whatever is already in
    /// flight rather than restarting from a standstill.
    static let dismissSpring = Spring(duration: 0.35, bounce: 0)
    static let settleSpring = Spring(duration: 0.4, bounce: 0.2)
    /// Downward travel before the surface starts following the finger,
    /// preserving the feel of the `minimumDistance: 20` the gesture used
    /// to be gated on. Keeps taps and the clock view's sideways chip
    /// flicks from nudging it.
    static let dragActivationDistance: CGFloat = 20
    /// How far a bare write may drag the surface *backwards past the
    /// finger* before it has to go through a spring instead.
    ///
    /// The quantity this bounds is `presented - trackedOffset`. A bare
    /// write puts the surface exactly where the finger is, so what the
    /// eye catches is the single-frame step from wherever the settle had
    /// got to. When the settle is ahead of the finger the surface steps
    /// *down* — with the gesture, the same direction every ordinary drag
    /// already steps when the 20pt activation deadband releases and the
    /// surface jumps from rest onto the finger. When the settle is behind
    /// the finger the surface steps *up*, against the gesture, and that
    /// is the teleport. So the gate is on the backwards component only,
    /// and 20pt is the scale the design already treats as beneath notice.
    ///
    /// It does not bound the forward step and is not meant to. The settle
    /// overshoots past rest, so the presented offset genuinely goes
    /// negative — `.offset(y: max(0, dragOffsetY))` clamps the
    /// animation's endpoints, not its interpolation, and QA measured
    /// −13.12pt on a catch-and-hold. A finger arriving at 29.30pt while
    /// the surface sits at −10.56pt therefore takes a 39.86pt step *with*
    /// the gesture, which is what QA measured and judged noticeable but
    /// not a lurch. It is the deadband's own step plus the overshoot, and
    /// the signed comparison lets it through deliberately. An earlier
    /// version of this doc claimed a 21pt bound on it; there is none.
    ///
    /// A fixed *time* window cannot do this job. Where a settle has got
    /// to is a percentage of what it is settling, not an absolute: for
    /// `settleSpring` (ζ = 0.8, ω_n = 15.708) a step response from rest
    /// is +1.02% of the displacement at 0.25s, −1.24% at 0.30s, and
    /// −1.52% at the overshoot peak (t = 0.333s). On a 300pt settle those
    /// are 3.06pt, −3.73pt and −4.55pt; on an iPad, where `exitTravel`
    /// reaches 1366pt, they are 13.9pt, −17.0pt and −20.7pt. (An earlier
    /// version of this comment gave the iPad figures as 17pt and 21pt for
    /// the *first* and last; 17pt is the 0.30s number, not the 0.25s
    /// one.) Gating on where the surface actually is makes the bound
    /// absolute on every screen — this number, whatever the surface.
    static let handoffMargin: CGFloat = 20
    /// How much older than the guard's own clock the frame the eye last
    /// saw is.
    ///
    /// `handoffMargin` bounds `presented - trackedOffset` solved at the
    /// instant the decision is made. That is a *model-space* quantity, and
    /// the step a person sees is not it: what the eye compares is the last
    /// frame the settle was on with the first frame the bare write is on,
    /// and the settle's model clock and the screen's are not in phase. So
    /// the gate is asked at `now - handoffPhase` as well as at `now`, and
    /// bounds the larger — see `focusSurfaceHandoff`.
    ///
    /// Two terms, and only the first is derivable here:
    ///
    ///   * One refresh interval, unavoidable. The frame the write lands on
    ///     is the successor of the frame the settle was last seen on, so
    ///     the two samples the eye differences are a frame apart however
    ///     fast the pipeline is.
    ///   * The settle animation's own start-to-photon offset. `recordedAt`
    ///     is stamped by `CACurrentMediaTime()` inside the gesture
    ///     handler, while the animation's first *moving pixel* is a commit,
    ///     a composite and a scan-out later. The model clock starts at the
    ///     stamp; the screen clock starts at the photon, and the screen
    ///     therefore runs behind. `testFocusSwipeTrainAt1000ptPerSecondSitsOnTheGateItself`
    ///     already named this offset and called it sub-frame; QA's round-10
    ///     traces put it at about a frame.
    ///
    /// So one frame is derived and the second is measured, out of a
    /// backward step of 41.58-43.24pt on decisions the old gate scored at
    /// or under 20 — see `testFocusHandoffBoundsTheRenderedStepNotTheModelStep`,
    /// which reproduces the whole band. 60Hz is the conservative end of it:
    /// at 120Hz the refresh term halves while the pipeline term does not,
    /// so a phase quoted in seconds at 60Hz over-states a ProMotion screen
    /// rather than under-stating it, and over-stating costs a spring
    /// handoff where a bare write would have done, not a teleport.
    ///
    /// It is deliberately *not* folded into `handoffMargin` as a smaller
    /// number. What it corrects for is `|v_settle| x phase`, and the
    /// settle's speed at the gate runs from 0 to 78pt/frame across the
    /// cases QA has traced; a constant would be the same
    /// "absolute bound on a quantity that is a percentage" mistake rounds 4
    /// and 5 each shipped once. Asking the solver twice costs one more
    /// evaluation and is exact at every speed, including zero — an
    /// 800ms-old settle has stopped, the two samples agree, and the gate is
    /// unchanged.
    static let handoffPhase: CFTimeInterval = 2 / 60.0
}

/// Projected travel past which a swipe commits to leaving focus. Scales
/// with the surface, the way the reminder panel's close-drag scales with
/// its own height, and never falls under the 120pt the previous
/// raw-distance gate demanded so a short landscape surface doesn't become
/// a hair trigger. Reading `predictedEndTranslation` makes any given
/// number looser than it was — 120 projected commits on a 60pt drag
/// flicked at 400pt/s — and leaving a full-screen surface should cost
/// more than the brisk downward swipe people use to dismiss a keyboard.
///
/// Pure / testable. No UI side effects.
func focusDismissProjection(surfaceHeight: CGFloat) -> CGFloat {
    max(120, surfaceHeight * 0.2)
}

/// Whether the surface should be following the finger this update.
///
/// Latched: `isTracking` alone is enough once the activation distance has
/// been passed, so a drag that reverses stays the same drag and the
/// surface keeps tracking back up instead of freezing at its far point.
/// The distance test only ever decides the *first* update of a gesture,
/// which is what keeps taps and the clock view's sideways chip flicks
/// from nudging anything.
///
/// Pure / testable. No UI side effects.
func focusDragShouldTrack(
    isTracking: Bool,
    translationY: CGFloat,
    activationDistance: CGFloat
) -> Bool {
    isTracking || translationY > activationDistance
}

/// Whether this update belongs to a gesture the view has not seen yet, and
/// so whether anything the previous gesture latched has to be thrown away
/// before this touch is allowed to decide anything.
///
/// `startLocation` is fixed for the life of a `DragGesture`, and the view
/// clears its record in `onEnded`, so a non-nil record means the last
/// gesture ended without `onEnded` — the system cancelled it. Two separate
/// touches landing on bit-identical coordinates would be missed; nothing
/// else is.
///
/// Pure / testable. No UI side effects.
func focusDragIsNewGesture(latchedStart: CGPoint?, updateStart: CGPoint) -> Bool {
    latchedStart != updateStart
}

/// What the focus surface is doing that a tracked write would interrupt.
///
/// Timestamps are `CACurrentMediaTime()`, not `Date()`: this is a
/// freshness stamp measured against itself, and wall-clock time is not
/// monotonic. A time correction, a network time update or the user
/// changing the clock in Settings steps `Date()` — backwards by Δ, and
/// the record stays live for Δ longer than the motion it describes;
/// forwards, and it expires the instant it is written. The same shape is
/// stamped the same way in `CalendarDayLayerView.noteHandleReleaseShrink`.
enum FocusSurfaceMotion: Equatable {
    /// A settle is running. `from` is where the *presentation* was when
    /// it started and how fast it was moving; `recordedAt` is when.
    case settling(from: FocusSurfaceState, recordedAt: CFTimeInterval)
    /// This gesture's tracked writes are being handed off through a
    /// spring, and stay that way until it ends. `from` is the
    /// presentation as of `stampedAt` and `toward` is the model value it
    /// was aimed at then, which is everything the next update needs to
    /// advance it.
    case smoothing(from: FocusSurfaceState, toward: CGFloat, stampedAt: CFTimeInterval)

    /// Whether this is the per-gesture handoff latch, which both gesture
    /// boundaries have to end — by settling over it, by re-labelling it
    /// (`focusCancelledGestureRecord`), or by dropping it. Asked rather
    /// than compared because the case now carries the presentation with
    /// it.
    var isSmoothing: Bool {
        if case .smoothing = self { return true }
        return false
    }
}

/// Where the focus surface's *presentation* is, and how fast it is going.
///
/// Not the model. `dragOffsetY` is written the instant a gesture or a
/// commit decides something and the presentation is wherever the
/// animation on it has reached; the two agree only when nothing is in
/// flight. A commit puts the model at `exitTravel` while the surface is
/// still on screen, and a smoothed gesture leaves the model on the finger
/// while the surface trails it by the tracking lag — solved through the
/// record, 77.0pt at the end of a spring-routed 120pt swipe at 1000pt/s.
/// That 77.0 is the model's figure. The device's own tracking law is
/// 0.060s × v and the model over-predicts this regime by about 1.8×, so
/// read it as what the record says, not as what QA will find on the glass;
/// `trackSurface` has the scoping.
struct FocusSurfaceState: Equatable {
    /// Presented offset, signed and measured from rest. Genuinely
    /// negative while a settle is past rest: the spring overshoots by
    /// 1.52% of what it settled, and `.offset(y: max(0, dragOffsetY))`
    /// clamps the animation's endpoints, not its interpolation.
    ///
    /// Two device readings of this quantity were once filed together as
    /// one dispute, on the reasoning that they missed in *opposite*
    /// directions and that this was the signature of an instrument
    /// problem rather than a model problem. That inference is dead: round
    /// 10 settled the other one — the tracking lag — as a real
    /// model/device divergence, measured with a 1:1 alignment anchor and
    /// reproduced by a second protocol (see `trackSurface`). One reading
    /// being sound removes the only argument that the pair shared a cause,
    /// and the reading below stands or falls on its own evidence.
    ///
    /// A logged pair put the surface 116pt behind the finger at the end
    /// of a 120pt swipe at 1000pt/s — a presented offset of 3.77pt,
    /// climbing home at 306pt/s. Run through the real handoff that
    /// gesture ends at 43.0pt travelling *downward*: 77pt behind the
    /// finger and still chasing it, where the log has it 116pt behind and
    /// climbing away. `dragOffsetY` grows downward, so a surface trailing
    /// this swipe is above the finger on screen in *both* readings; what
    /// separates them is the sign of the velocity.
    /// That forward run is the whole of the claim, and
    /// `testFocusSmoothedSwipeDoesNotEndAtTheLoggedTrackingGap` pins it.
    ///
    /// Three rounds tried to strengthen it into "no state of this
    /// surface reaches that pair" — a velocity ceiling, then a joint
    /// bound on the pair — and each was wrong. The last back-solved
    /// `.offset` alone and reproduced 3.77pt with the velocity sign
    /// *inverted*, and the homeward speed it called out of reach is
    /// beaten by an ordinary upward flick, whose release velocity a
    /// settle from rest injects into itself. Whether some other gesture
    /// could reach the pair is not known, and nothing here needs it to
    /// be.
    ///
    /// What *does* fit 3.77pt is an undisturbed settle — the surface not
    /// being pulled toward the finger at all, which is what
    /// `pendingProposalTemplate != nil` and an upward-clamped
    /// `max(0, translation)` both produce — or two logged numbers from
    /// different frames.
    ///
    /// The measurement that would settle it is still the one named in
    /// round 6 and still untaken: `dragOffsetY`, the presented offset and
    /// `value.translation.height` logged together on a *single* frame of a
    /// spring-routed drag. What has changed is that it no longer has a
    /// second reading riding on it — the tracking lag was settled
    /// separately, and settled *against* the solver, so "one measurement
    /// settles both" is no longer true and this one is on its own.
    /// Nothing here needs it to be correct; the record is exact against
    /// the animation either way. It decides only whether these two figures
    /// describe this surface.
    var offset: CGFloat
    /// Points per second, positive downward. Zero when nothing is in
    /// flight — a bare write leaves the value where it put it and the
    /// animation system carries no velocity for it, which is exactly why
    /// a settle after a bare gesture has to be handed the finger's.
    var velocity: CGFloat
}

/// Advance a spring flight: where a surface that was at `from` is once it
/// has been converging on `toward` for `elapsed` seconds.
///
/// `Spring.value` and `Spring.velocity` are Apple's own solver for the
/// same spring the animation runs on, so this is the response itself and
/// not an approximation of it. Two rounds were spent on approximations —
/// an absolute point bound on a quantity that is a percentage, then an
/// unsigned velocity-blind envelope — and each one shipped a defect at
/// the edge it was blind to. There is no envelope here to be blind with.
///
/// It is also the only form that is safe to hand an arbitrary spring.
/// The envelope was `d · e^(−ζω_n t) / √(1−ζ²)`, an upper bound only
/// while ζ < 1: at ζ = 1 the true response is `d(1 + ω_n t)e^(−ω_n t)`,
/// which *exceeds* `d · e^(−ω_n t)`, so passing `dismissSpring`
/// (bounce 0, ζ = 1) would have turned the bound into an under-estimate
/// with nothing to say so. The solver has no such edge.
private func focusSpringFlight(
    from: FocusSurfaceState,
    toward: CGFloat,
    spring: Spring,
    elapsed: CFTimeInterval
) -> FocusSurfaceState {
    // Clamped, so a clock that somehow reads backwards cannot resolve to
    // a point the flight was never at.
    let time = max(0, elapsed)
    return FocusSurfaceState(
        offset: spring.value(
            fromValue: from.offset,
            toValue: toward,
            initialVelocity: from.velocity,
            time: time
        ),
        velocity: spring.velocity(
            fromValue: from.offset,
            toValue: toward,
            initialVelocity: from.velocity,
            time: time
        )
    )
}

/// Where the surface is right now, given what it was last known to be
/// doing and where the model has got to.
///
/// Pure / testable. No UI side effects.
func focusSurfacePresentedState(
    motion: FocusSurfaceMotion?,
    modelOffset: CGFloat,
    spring: Spring,
    now: CFTimeInterval
) -> FocusSurfaceState {
    switch motion {
    case nil:
        // Nothing in flight, so the presentation is the model — and
        // carries no animation velocity, however fast the finger that
        // wrote it was moving.
        return FocusSurfaceState(offset: modelOffset, velocity: 0)
    case let .settling(from, recordedAt):
        return focusSpringFlight(
            from: from,
            toward: 0,
            spring: spring,
            elapsed: now - recordedAt
        )
    case let .smoothing(from, toward, stampedAt):
        return focusSpringFlight(
            from: from,
            toward: toward,
            spring: spring,
            elapsed: now - stampedAt
        )
    }
}

/// What a settle has to hand `interpolatingSpring` as its initial
/// velocity, and what the presentation will be doing once it does.
///
/// The velocity rule is the whole of it. A gesture that tracked bare left
/// no animation behind: the presentation is the model and the animation
/// system holds no velocity for it, so the finger's release velocity has
/// to be injected or the surface leaves from a standstill. A gesture that
/// was smoothed left a spring in flight that is *already* moving — with
/// the finger if it had time to converge, still homeward if the gesture
/// was too short for it to turn around — and that motion is the
/// surface's own. Interpolating springs add, so injecting the finger's
/// velocity on top double-counts it when the two agree, and when they do
/// not it flings a surface that is nearly home back down the screen. A
/// caught dismissal is the bare case with no finger at all: nothing is
/// recorded for the fly-off, so the model is what the settle starts from,
/// which reads `exitTravel` and keeps the handoff armed across every
/// catch delay QA has traced.
///
/// `initialVelocity` comes back normalised the way `interpolatingSpring`
/// wants it — a fraction of the model's own change per second — while the
/// recorded state is in points per second, because that is what the
/// solver takes.
///
/// Pure / testable. No UI side effects.
func focusSettlePlan(
    motion: FocusSurfaceMotion?,
    modelOffset: CGFloat,
    releaseVelocity: CGFloat,
    spring: Spring,
    now: CFTimeInterval
) -> (initialVelocity: Double, motion: FocusSurfaceMotion) {
    let presented = focusSurfacePresentedState(
        motion: motion,
        modelOffset: modelOffset,
        spring: spring,
        now: now
    )
    // The model travels `modelOffset -> 0`, and that is the range
    // `interpolatingSpring` normalises against: what it is handed is a
    // fraction of that change per second, so the animation receives
    // `injected * modelOffset / travelled` points per second and the two
    // agree only while `travelled == modelOffset`.
    //
    // Which is why the injection is gated on there being a change at
    // all. A model already at rest has no range to normalise against —
    // it is not that the division is unsafe, it is that no normalised
    // number can express a velocity through a zero-length change, and
    // the old floor of 1 quietly papered over it: `.settling(from: (0,
    // released))` recorded a flight the animation could not perform, and
    // for `0 < modelOffset < 1` it recorded a velocity the animation
    // received only `modelOffset` of. Both over-state, so both over-arm
    // the next gesture, which is round 4's defect.
    //
    // Reachable, and not only through the preview branch and the
    // foreground backstop: drag past the deadband, flick back above the
    // start — `max(0, translation)` clamps the model to 0 — and lift
    // while still moving down.
    let injected: CGFloat = motion == nil && modelOffset > 0 ? releaseVelocity : 0
    let travelled = modelOffset > 0 ? modelOffset : 1
    return (
        initialVelocity: Double(-injected / travelled),
        motion: .settling(
            from: FocusSurfaceState(
                offset: presented.offset,
                velocity: presented.velocity + injected
            ),
            recordedAt: now
        )
    )
}

/// What a gesture boundary with nothing to settle should leave latched.
///
/// `.smoothing` is a per-gesture latch and cannot outlive the gesture
/// that set it. Dropping it to `nil` — what both callers used to do —
/// throws away the only description of a flight that may still be
/// running, because a model already at rest does not mean the surface
/// is: the last tracked write aims a spring at the model from wherever
/// the surface had got to, and an upward-clamped drag puts the model at
/// 0 while that spring is still on its way down to it. With no record
/// the next gesture's first tracked update has nothing to read, writes
/// bare over the flight, and the surface teleports backwards onto the
/// finger — 64.2pt one frame after a 150pt drag whipped back at
/// 1500pt/s, 238.4pt after a 400pt one whipped back at 4000, against the
/// 20pt `handoffMargin` is there to bound and the 54pt round 5 shipped.
///
/// So the latch is re-labelled instead: `.settling` from wherever the
/// surface has got to, stamped now. `nil` and `.settling` come back
/// unchanged — neither is a per-gesture latch and neither needs it.
///
/// The re-label is exact only where a live `.smoothing` is aimed at 0,
/// since `.settling` converges on 0 by definition and re-labelling a
/// latch aimed anywhere else would move its target. Both callers get
/// that from `dragOffsetY == 0`: `toward` and `dragOffsetY` are written
/// to the same value by the same call in `trackSurface`, and every other
/// writer of `dragOffsetY` rules a live latch out. The commit writes a
/// non-zero `exitTravel`; `settleSurfaceHome` replaces the record with a
/// `.settling` in the same breath; and its initial value is 0 with no
/// record at all. A live `.smoothing` beside a model at 0 can therefore
/// only have come from a tracked write at 0, which makes the two records
/// the same flight — same spring, same target, and the state is solved
/// out of the record being replaced. This is a change of label, not of
/// motion.
///
/// `modelOffset` is forwarded to `focusSurfacePresentedState`, which
/// consults it only for the `nil` record this returns untouched. It is
/// passed rather than assumed so the call site says what it knows.
///
/// Pure / testable. No UI side effects.
func focusCancelledGestureRecord(
    motion: FocusSurfaceMotion?,
    modelOffset: CGFloat,
    spring: Spring,
    now: CFTimeInterval
) -> FocusSurfaceMotion? {
    guard motion?.isSmoothing == true else { return motion }
    return .settling(
        from: focusSurfacePresentedState(
            motion: motion,
            modelOffset: modelOffset,
            spring: spring,
            now: now
        ),
        recordedAt: now
    )
}

/// Whether this tracked write has to be handed off through a spring, and
/// what the surface is doing once it has been made.
///
/// The surface's model value and its presented value are different things
/// while an animation is in flight, and an unanimated write to a value
/// with an animation on it removes the animation and jumps to the new
/// value. A bare write lands the surface exactly on the finger, so the
/// step it costs is `presented - trackedOffset`: negative means the
/// surface catches *down* to the finger, which is what the activation
/// deadband already does on every ordinary drag; positive means it is
/// dragged *up*, against the gesture, and that is the teleport this
/// exists to remove.
///
/// Gating on that, rather than on the age of the settle, is what tells a
/// catch from an ordinary re-swipe without either of them having to say
/// which it is. A catch follows a committed dismissal, so what is
/// settling is `exitTravel`; an ordinary swipe that did not commit leaves
/// the distance it was dragged, at most `focusDismissProjection` — one
/// fifth of the surface — and on the QA device those are 874pt and
/// 174.8pt. Both are solved, not estimated, so a swipe released still
/// moving *downward* is correctly reported as no nearer home than when
/// it started — having gone further out first — rather than as a step
/// response 40% of the way back.
///
/// Not a formal partition, and deliberately not written as one: a drag
/// released moving upward projects short and does not commit however far
/// it travelled, and while `canExitBySwipe` is false nothing commits at
/// all. Those settles are genuinely large, the surface genuinely is a
/// long way from home, and that is what they get treated as.
///
/// Subtracting `trackedOffset` is not a fudge factor and not a second
/// threshold. What the eye sees is one step, from the surface to the
/// finger, so the finger's own travel is part of the quantity being
/// bounded — a finger already past the surface has nothing to be
/// teleported over. Writing it out rather than folding it into the
/// margin is what keeps the gate tied to `dragActivationDistance`: a
/// slow finger's first tracked update lands just past that 20pt
/// deadband, so a hard-coded 41 would be numerically identical for it
/// and would silently start admitting larger up-steps the day the
/// deadband changed, while this form still bounds them at the margin. A
/// fast finger does not land there at all: at 1500pt/s a 60Hz frame
/// carries it 25pt, so its first tracked update falls anywhere from just
/// past 20 to about 45 depending on where the frame boundary lands. This
/// form loosens correctly across that whole range, which is the second
/// thing a hard-coded 41 would have got wrong.
///
/// The decision is latched for the length of a gesture: handing back to a
/// bare write partway would only move the jump to the frame it happened
/// on. It is therefore evaluated exactly once per gesture, which is why
/// the solver's phase does not have to be smoothed away — there is no
/// per-frame comparison here to flicker.
///
/// What is bounded is the step *as rendered*, which is why the settle is
/// asked twice. Every round that has had this gate bounded
/// `presented - trackedOffset` at the decision instant, and all of them
/// were bounding the wrong quantity: that is where the model says the
/// surface is, and the frame the eye is differencing against was painted
/// earlier, by `renderPhase` — see `FocusSurfaceMetrics.handoffPhase`. The
/// settle is moving 9-13pt per frame where these decisions land, so the
/// decision the old gate scored at 19.91 against a 20pt margin rendered as
/// a 44.30pt backward step, inside a measured band of 31.9-50.1. Rounds 4
/// through 10 each changed *what the decision was based on* — wall clock,
/// then a residual envelope, then the solver — and none of them changed
/// *when* it was evaluated.
///
/// The larger of the two samples is what has to clear the margin, not the
/// earlier one. Where the settle is on its way home the earlier sample is
/// the larger and the gate tightens, which is the fix. Where the settle is
/// still travelling *away* — the first 33ms of a flick released at
/// 1500pt/s, which goes further out before it comes back — the sample at
/// `now` is the larger, the eye's earlier frame was nearer the finger than
/// the model is, and bounding the model value is already the conservative
/// reading. One expression covers both because the max does; a plain shift
/// to `now - renderPhase` would quietly loosen the second case.
///
/// Only the gate reads the shifted sample. The record handed to
/// `.smoothing` stays the state at `now`, because that record is consumed
/// by `focusSpringFlight` against the same model clock it was stamped on —
/// shifting it would move the flight rather than describe it, and the
/// tracking chain would inherit the phase instead of correcting for it.
///
/// Pure / testable. No UI side effects.
func focusSurfaceHandoff(
    motion: FocusSurfaceMotion?,
    trackedOffset: CGFloat,
    spring: Spring,
    visibilityMargin: CGFloat,
    renderPhase: CFTimeInterval,
    now: CFTimeInterval
) -> (animate: Bool, motion: FocusSurfaceMotion?) {
    guard let motion else { return (false, nil) }
    let presented = focusSurfacePresentedState(
        motion: motion,
        modelOffset: trackedOffset,
        spring: spring,
        now: now
    )
    if case .settling = motion {
        let shown = focusSurfacePresentedState(
            motion: motion,
            modelOffset: trackedOffset,
            spring: spring,
            now: now - renderPhase
        )
        if max(presented.offset, shown.offset) - trackedOffset <= visibilityMargin {
            return (false, nil)
        }
    }
    return (true, .smoothing(from: presented, toward: trackedOffset, stampedAt: now))
}

/// What to do about a dismissal that is still outstanding when the app
/// comes back to the foreground.
enum FocusDismissRecovery: Equatable {
    /// Nothing to recover — the ordinary case.
    case none
    /// Honour the commit the user made before the app went away.
    case exit
    /// The gate has closed in the meantime, so `onExit` cannot end the
    /// session: bring the surface back on screen instead of leaving it
    /// parked off the bottom edge where it cannot be hit-tested.
    case settle
}

/// Decide the backstop for a swipe-dismiss whose animation completion —
/// `onExit`'s only caller — never ran. Requires a full background round
/// trip, not merely a return to `.active`: Control Center or a
/// notification pull-down passes through `.inactive` while the animation
/// is running perfectly well, and acting there would tear the overlay
/// down mid-flight.
///
/// Pure / testable. No UI side effects.
func focusDismissRecoveryOnForeground(
    hasPendingDismiss: Bool,
    canExitBySwipe: Bool,
    returnedFromBackground: Bool
) -> FocusDismissRecovery {
    guard returnedFromBackground, hasPendingDismiss else { return .none }
    return canExitBySwipe ? .exit : .settle
}

/// Whether releasing here should leave focus. Both halves matter: the
/// projection has to clear the gate, and the host has to be able to
/// actually end the session — under rotation-driven focus `onExit` only
/// clears the manual flag, so committing would fling the surface
/// off-screen and leave the overlay mounted behind it.
///
/// Where it fires, measured. On the QA device, with a *stationary*
/// release, the gate is between 125 and 130pt: 110 / 120 / 125 stay and
/// 130 / 140 / 150 / 155 / 160 / 170 commit, probed with hard resets and
/// entry assertions, and independent of a 200-800ms stationary hold. So
/// the largest drag a re-swipe can start from without committing is
/// **125pt**, not the 150-160 an earlier round recorded and the tests
/// built their worst case on. A release that is still moving commits
/// earlier again, because the gate reads `predictedEndTranslation`.
///
/// Open, one-off, deliberately not chased: one commit run in twelve left
/// the surface stranded about 170pt down — shift 509px, err 53.1 —
/// neither committed nor home. Twelve further attempts did not reproduce
/// it and no capture was taken. Recorded so it is not lost, not so it is
/// acted on.
///
/// Pure / testable. No UI side effects.
func focusDismissCommits(
    projectedTranslationY: CGFloat,
    surfaceHeight: CGFloat,
    canExitBySwipe: Bool
) -> Bool {
    guard canExitBySwipe else { return false }
    return projectedTranslationY > focusDismissProjection(surfaceHeight: surfaceHeight)
}

/// "Crossing the threshold" transition for the inhabiting view. The
/// event's color floods in from a tinted overlay while the protagonist
/// scales and fades up into place — visual + spatial cue that the event
/// has become the frame. Removal is a plain opacity fade so exiting
/// doesn't compete with the entering moment of the next session.
private func focusEnterTransition(color: Color) -> AnyTransition {
    .asymmetric(
        insertion: .modifier(
            active: FocusEnterModifier(progress: 0, color: color),
            identity: FocusEnterModifier(progress: 1, color: color)
        ),
        removal: .opacity
    )
}

private struct FocusEnterModifier: ViewModifier {
    let progress: Double
    let color: Color

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.94 + 0.06 * progress)
            .opacity(progress)
            .overlay(
                color
                    .opacity((1 - progress) * 0.45)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            )
    }
}

/// Resolve which occurrence focus mode treats as "the current event"
/// given the day's occurrences and the present moment.
///
/// Resolution precedence:
///   1. An embedded interrupt that covers `now` — when the user has
///      explicitly created a sub-event ("phone rang"), their attention
///      is on the interrupt, not the parent it overlaps. The protagonist
///      surface should follow.
///   2. Any other in-progress occurrence whose range covers `now`.
///   3. Most recently ended event within `overrunGrace` — the user has
///      briefly continued past the scheduled end and we want to keep
///      them on the same protagonist so they can decide (Extend / End /
///      let it expire).
///
/// Pure / testable. No UI side effects.
func focusCurrentOccurrence(
    in occurrences: [CalendarLayout.EventOccurrence],
    now: Date,
    overrunGrace: TimeInterval
) -> CalendarLayout.EventOccurrence? {
    let inProgress = occurrences.filter { $0.range.start <= now && $0.range.end > now }
    if let interrupt = inProgress.first(where: { occ in
        occ.event.displayKind == .interrupt
            && occ.event.interruptRelation?.state == .embedded
    }) {
        return interrupt
    }
    if let any = inProgress.first {
        return any
    }
    guard overrunGrace > 0 else { return nil }
    let cutoff = now.addingTimeInterval(-overrunGrace)
    return occurrences
        .filter { $0.range.end <= now && $0.range.end > cutoff }
        .max(by: { $0.range.end < $1.range.end })
}
