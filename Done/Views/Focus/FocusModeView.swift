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
    /// What animation is currently carrying the surface, `nil` when none
    /// is and the presentation is therefore the model exactly.
    ///
    /// Three writers. `settleSurfaceHome` records what it is settling; the
    /// commit records the fly-off; and every tracked update clears it,
    /// because a tracked update writes bare and a bare write removes
    /// whatever animation was on the value. There is no longer a
    /// per-gesture latch here — `.smoothing` and the two gesture
    /// boundaries that had to end it went with the handoff (gh#175).
    ///
    /// The invariant that buys the anchor its exactness: **every record
    /// describes a single spring, and no two are ever in the air at once.**
    /// A gesture leaves nothing in flight, so the commit's `.dismissing`
    /// starts from a standstill; a catch stops the `.dismissing` with a
    /// bare write before anything else animates; and a settle is only ever
    /// started over a surface that is already still. The two paths that
    /// deliberately settle *over* a live fly-off — the preview branch and
    /// the foreground restore — are the exceptions, and neither is
    /// followed by a finger, which is where it matters. See
    /// `FocusSurfaceMotion.dismissing`.
    @State private var surfaceMotion: FocusSurfaceMotion?
    /// Where the surface was when this gesture first took hold of it —
    /// the presented offset, on the glass clock, latched once at the first
    /// tracked update and held for the rest of the gesture.
    ///
    /// Zero whenever the surface was at rest, which is every ordinary
    /// drag, and the tracked write is then byte-for-byte what it always
    /// was. See `trackSurface`.
    @State private var trackingAnchor: CGFloat = 0
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
                            // Suppress while preview is up — the picker
                            // owns vertical drags, and accumulating a
                            // dragOffsetY on top would shove the whole
                            // view down underneath it. The user backs
                            // out of preview via Cancel, then can
                            // swipe-down from the clock view.
                            //
                            // This is now the only path that can leave a
                            // dismissal outstanding without tracking it,
                            // which is why the catch moved in here: while
                            // one is in flight the deadband is waived, so
                            // every other route reaches the tracked write
                            // on this very frame.
                            guard pendingProposalTemplate == nil else {
                                catchPendingDismiss()
                                return
                            }
                            guard focusDragShouldTrack(
                                isTracking: isTrackingDrag,
                                isDismissing: pendingDismissID != nil,
                                translationY: value.translation.height,
                                activationDistance: FocusSurfaceMetrics.dragActivationDistance
                            ) else { return }
                            if !isTrackingDrag {
                                isTrackingDrag = true
                                // Read before the write below, because the
                                // write is what retires the flight this
                                // reads: afterwards there is nothing left
                                // to ask where the surface was.
                                trackingAnchor = focusSurfacePresentedState(
                                    motion: surfaceMotion,
                                    modelOffset: dragOffsetY,
                                    spring: FocusSurfaceMetrics.settleSpring,
                                    now: CACurrentMediaTime() - FocusSurfaceMetrics.renderPhase
                                ).offset
                                // The tracked write owns the surface from
                                // here, so whatever dismissal it just
                                // interrupted stops being one. Clearing
                                // the id is what keeps that animation's
                                // completion from firing `onExit` behind
                                // the finger; the bare write below is what
                                // stops the animation itself.
                                pendingDismissID = nil
                            }
                            // 1:1 from where the surface actually is. The
                            // upward clamp is on the *sum*, not on the
                            // translation: from rest the anchor is 0 and
                            // this is the same expression it always was,
                            // and from a catch it is what lets the finger
                            // push a surface it grabbed mid-flight back up
                            // toward home instead of pinning it.
                            trackSurface(to: max(0, trackingAnchor + value.translation.height))
                        }
                        .onEnded { value in
                            let wasTrackingDrag = isTrackingDrag
                            isTrackingDrag = false
                            latchedGestureStart = nil
                            trackingAnchor = 0
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
                                // The `else` that used to sit here
                                // re-labelled a stranded `.smoothing`
                                // latch as `.settling`, because a model at
                                // 0 did not mean nothing was in flight.
                                // Tracked writes are bare now: the last
                                // one removed whatever animation it landed
                                // on and cleared the record in the same
                                // breath, so a model at 0 with no record
                                // really is a surface at rest, and there
                                // is nothing left to re-label.
                                if dragOffsetY != 0 {
                                    settleSurfaceHome()
                                }
                                return
                            }
                            // A touch that never became a drag — a tap on
                            // the protagonist, a chip flick — decides
                            // nothing.
                            guard wasTrackingDrag else { return }
                            let released = value.velocity.height
                            // What decides here is the *projection*, not
                            // the travel, and the difference is tens of
                            // points: bisected on device the same gate
                            // fires at 201.5 / 172.5 / 142.5 / 98.5pt of
                            // commanded distance for releases at −200 / 0 /
                            // +200 / +400pt/s. Which also means a rig that
                            // holds the finger still and then lifts is not
                            // producing a stationary release — no new touch
                            // samples means the estimator keeps the
                            // approach ramp. See `focusDismissCommits`.
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
                                // The fly-off describes itself now. It
                                // used to be described by nothing, and a
                                // catch therefore settled from the model —
                                // `exitTravel` — which reads 57-488pt
                                // below where the surface actually is. As
                                // a gate input that over-read was
                                // deliberate and safe: it kept the handoff
                                // armed. As the *anchor* it is a several
                                // hundred point shove down the screen on
                                // the one gesture this whole mechanism
                                // exists for. See `trackSurface`.
                                //
                                // It is exact rather than modelled. The
                                // gesture that just ended tracked bare, so
                                // nothing is in flight and the
                                // presentation is `dragOffsetY` with no
                                // animation velocity; the spring below is
                                // handed `released / remaining`, which
                                // `interpolatingSpring` normalises against
                                // a change of `remaining`, so the velocity
                                // it really receives is `released` points
                                // per second. Both halves of the record
                                // are therefore read off, not estimated.
                                surfaceMotion = .dismissing(
                                    from: FocusSurfaceState(
                                        offset: dragOffsetY,
                                        velocity: released
                                    ),
                                    toward: exitTravel,
                                    spring: FocusSurfaceMetrics.dismissSpring,
                                    recordedAt: CACurrentMediaTime()
                                )
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
        // Nothing to bring home: either the surface is already at rest,
        // or a dismissal is in flight and the first `onChanged` is about
        // to take it over on this same frame — the deadband is waived
        // while one is outstanding, so the tracked write below runs
        // immediately and settling here would only start a second spring
        // for it to remove.
        //
        // This branch used to re-label a stranded `.smoothing` latch as
        // `.settling`, because a model at 0 did not imply a surface at
        // rest: an upward-clamped drag left a spring still flying down to
        // it. Bare tracked writes removed that case — the write that
        // clamped the model to 0 also removed the animation — so there is
        // no longer anything here to preserve.
        guard pendingDismissID == nil, dragOffsetY != 0 else {
            return
        }
        // A gesture that was cancelled mid-drag leaves the surface parked
        // off its rest position with nothing bringing it home, so this
        // touch settles it first and then tracks from wherever that settle
        // has got to. `settleSurfaceHome` reads the presentation, which
        // here is the model exactly: the cancelled gesture's last write
        // was bare.
        settleSurfaceHome()
    }

    /// Follow the finger, 1:1, from wherever the surface already is.
    ///
    /// `offset` is `anchor + translation`, where the anchor is the
    /// presented offset latched at the first tracked update of the
    /// gesture. That is the whole of gh#175, and everything below is why
    /// the thing it replaced could not be made to work.
    ///
    /// **What it replaced.** A tracked write used to be
    /// `dragOffsetY = translation`: an absolute number derived from the
    /// finger, with no relationship to where the surface was. When the two
    /// disagreed — a dismissal caught in flight, a re-swipe onto a settle
    /// — a bare write closed the gap in one frame, and QA measured that at
    /// 148pt. So a gate decided per gesture whether to write bare or hand
    /// off through a spring, and the quantity it bounded was
    /// `presented - trackedOffset` at the decision instant.
    ///
    /// **Why the gate could not be tuned.** What the eye sees is not the
    /// model's step but `trackedOffset - presented(t - phase)`, and QA
    /// established that relation directly, logging the frame each bare
    /// write lands on together with the finger's position on it: the
    /// rendered ramp reproduces it to 0.005-0.02pt rms across 40+ traces.
    /// Two things came out of that. The phase is an integer number of
    /// frames — `60 * elapsed` lands on an integer in every clean run,
    /// |err| < 0.01 frame, because touch delivery and animation sampling
    /// share the 60Hz grid. And **no single integer fits**: the same
    /// protocol forces 2 in some runs and 3 in others, and the post-hold
    /// protocol forces 4. The intersection is empty in all three builds
    /// that were measured. A threshold cannot be positioned against a
    /// quantity whose own definition moves by 9-13pt per frame of
    /// uncertainty, which is why thirteen rounds of moving the constant
    /// never converged.
    ///
    /// **Why re-anchoring gets out of it, shown rather than asserted.**
    /// Substitute the new write into QA's own measured relation. The step
    /// the eye sees is
    ///
    ///     dragOffsetY - presented(t - phase)
    ///
    /// which for the old form is `translation - presented(t - phase)` and
    /// for this one is
    ///
    ///     anchor + translation - presented(t - phase)
    ///
    /// The old form carries the whole `presented - tracked` gap, which is
    /// 85pt on a re-swipe and up to 874pt on a catch, and the phase enters
    /// as an error in *predicting* that gap; one frame of phase error is
    /// worth 9-13pt of prediction error, which is precisely enough to flip
    /// a 20pt threshold. That is the failure round 13 measured: the gate
    /// certified <= 20pt and the surface rendered 25.57-28.87pt.
    ///
    /// In the new form the anchor is itself a reading of `presented`, so
    /// **the gap term cancels algebraically**, and what is left is
    /// `translation` plus the difference between two evaluations of the
    /// same flight. There is no threshold left for a phase error to flip,
    /// because there is no decision left to make: every tracked write is
    /// bare, on every path, always.
    ///
    /// The phase does not vanish, and `FocusSurfaceMetrics.renderPhase`
    /// says what it costs and why the anchor is read on the glass clock
    /// rather than this view's. Read there `anchor - presented(t - phase)`
    /// is zero to within one frame of the surface's own motion, whatever
    /// the settle is doing; read on the model clock it would be a
    /// systematically backwards `phase * v_settle`, which reaches -209pt
    /// on a catch and would have been a worse defect than the one being
    /// removed.
    ///
    /// **Why the spring had to go rather than be tuned around.** The
    /// routed path inherits a tracking lag — 0.060s * v on the device, 17pt
    /// at 300pt/s and 61pt at 1000 — and QA judged what that does to a
    /// rapid train unshippable: four 100pt swipes at 667pt/s with 80ms
    /// gaps, and swipes 1 and 3 reach 100.4-103.7pt while 2 and 4 reach
    /// 68.2-70.8, the surface never returning home between them (troughs
    /// 22.3-40.4). Identical at two frames of phase and at three. Every
    /// other swipe of a fast train delivering two thirds of its travel is
    /// a non-response, not a lag, and it got worse the more the gate
    /// routed. Nothing here routes.
    ///
    /// **What it costs, deliberately.** The offset is no longer the
    /// finger's translation, so a surface caught halfway out stays caught
    /// halfway out and a re-swipe dismisses from further down. That is a
    /// design change against device-verified behaviour and it is the
    /// reason gh#175 was filed separately rather than done inline. The
    /// commit gate is unaffected: `focusDismissCommits` reads
    /// `predictedEndTranslation`, which is the finger's, and never the
    /// offset.
    ///
    /// An ordinary drag from rest is unchanged, byte for byte. Nothing is
    /// in flight, so `focusSurfacePresentedState` returns the model, the
    /// model is 0, the anchor is 0, and `max(0, 0 + translation)` is the
    /// expression that was already there.
    private func trackSurface(to offset: CGFloat) {
        // This is how the in-flight animation is retired, and it is the
        // only mechanism needed: an unanimated write to a value carrying
        // an animation removes the animation and takes the value. The
        // settle cannot fight the finger afterwards because it no longer
        // exists.
        //
        // It is also why the anchor is read in `onChanged` *before* this
        // runs. Afterwards there is nothing left to ask.
        //
        // The record goes with it. It described a flight that has just
        // been removed, and leaving it would tell the next reader the
        // surface is somewhere it is not — the same class of error as the
        // `exitTravel` fiction this round removed from the fly-off, in the
        // opposite direction.
        surfaceMotion = nil
        dragOffsetY = offset
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
    /// How much older than this view's own clock the frame on the glass is.
    ///
    /// Read at exactly one site — the anchor `trackSurface` latches at the
    /// first tracked update of a gesture — and nothing branches on it.
    ///
    /// **Why a phase constant survived gh#175, which was filed to remove
    /// it.** The re-anchor removes the *gate*, and with it the term that
    /// made this number load-bearing. It does not remove the phase. Under
    /// `dragOffsetY = anchor + translation` the step the eye sees at the
    /// handoff is
    ///
    ///     anchor + translation - presented(t - phase)
    ///
    /// and `anchor` is the only free choice in it. Anchoring on the *model*
    /// clock (`anchor = presented(t)`) leaves `translation - phase *
    /// v_settle`: the `presented - tracked` gap cancels identically, which
    /// is the whole win, but the surface's own travel over the phase
    /// survives, always with the backwards sign. Against QA's measured
    /// phase and the settle speeds this file already records that is -0.3
    /// to -37pt on an ordinary re-swipe and -61 to -209pt on a catch —
    /// worse than the 22.17-28.87pt round 13 shipped, on the one case the
    /// mechanism exists for.
    ///
    /// Anchoring on the *glass* clock leaves `translation + (phase_used -
    /// phase_true) * v_settle` instead, which across the whole measured
    /// spread is `translation` plus or minus **one frame of the surface's
    /// own motion**. That is the change gh#175 is actually made of, and it
    /// is why the empty intersection that ended round 13 stops being a
    /// contradiction: 2, 3 and 4 no longer name three incompatible
    /// behaviours, they name a one-frame trim on a quantity with no
    /// threshold in it. A wrong value here cannot bare-write something that
    /// should have been routed, because there is nothing left to route.
    ///
    /// So it is carried at the centre of the measured range and is not
    /// worth tuning again: the two frames of spread buy one frame of settle
    /// travel, and one frame of settle travel is by construction the step
    /// the eye is already watching the surface take.
    ///
    /// The measurement is round 13's, unchanged: **2.48-2.75 frames**, two
    /// independent readings on an optically calibrated rig (the Simulator
    /// window is **not** point-accurate — 0.9641 host points per device
    /// point, and every figure in this file predating that calibration is
    /// suspect, including the round-11 band of 31.90-50.07pt whose
    /// protocol re-measures at 22.17-28.87). Frame indices are the honest
    /// clock: simctl's recorder jitters PTS by up to a frame — 4 of 64
    /// rigid-tracking frame pairs advance two finger-frames while their
    /// timestamps claim one refresh — so nothing here is derived from a
    /// recorded timestamp.
    ///
    /// 60Hz is baked in. Do *not* reach for
    /// `UIScreen.maximumFramesPerSecond`: it reports the panel's maximum,
    /// so a ProMotion screen currently running at 60Hz would halve this,
    /// which used to be the dangerous direction. It is now merely a
    /// fraction of a frame of settle travel, with the forward sign.
    static let renderPhase: CFTimeInterval = 3 / 60.0
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
/// `isDismissing` waives the deadband outright, and only there. The 20pt
/// gate exists to tell a tap from a drag on a surface that is sitting
/// still; a surface flying off-screen cannot be tapped, so any touch that
/// lands on one is an interception and the surface has to stop under the
/// finger on that very frame. Making it wait 20pt is what forces the
/// settle-then-catch-up shape the whole handoff apparatus existed to
/// paper over: the surface keeps travelling under a finger that has
/// already grabbed it, and the two have to be reconciled afterwards.
/// Stopping it immediately is what UIScrollView does with a decelerating
/// scroll, and it is why the anchor can be exact — a catch is the only
/// moment two springs would otherwise be in the air at once.
///
/// A touch that lands with nothing in flight is unaffected, which is the
/// whole of the tap and chip-flick behaviour: `isDismissing` is false
/// whenever `pendingDismissID` is nil.
///
/// Pure / testable. No UI side effects.
func focusDragShouldTrack(
    isTracking: Bool,
    isDismissing: Bool,
    translationY: CGFloat,
    activationDistance: CGFloat
) -> Bool {
    isTracking || isDismissing || translationY > activationDistance
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
    /// A committed dismissal is flying off-screen. `from` is the surface
    /// at the instant of the commit, which is the model *exactly*: under
    /// gh#175 every tracked write is bare, so a gesture leaves nothing in
    /// flight and the presentation and the model agree at the moment the
    /// commit is decided. Its velocity is the release velocity the
    /// animation was handed, and `toward` is `exitTravel`.
    ///
    /// The fly-off used to be described by nothing at all, and a catch
    /// therefore settled from `exitTravel` — a deliberate over-read, safe
    /// while the only consumer was a boolean gate that wanted to stay
    /// armed. It is not safe as an *anchor*: solved forward it puts the
    /// surface 57-488pt below where it is, and the tracked write would
    /// hurl it that far further down the screen. See `trackSurface`.
    ///
    /// This case carries its own spring because it is the one flight that
    /// is not `settleSpring`, and it has to be solved on the spring it is
    /// really running on. Nothing else may introduce a second spring:
    /// `focusSurfacePresentedState` is exact because a composite of
    /// same-spring flights is indistinguishable from one flight solved
    /// from the composite state — a property of the linear ODE, and lost
    /// the moment two different springs are in the air at once. That is
    /// why a catch under a finger now *stops* the fly-off with a bare
    /// write instead of settling over the top of it.
    case dismissing(
        from: FocusSurfaceState,
        toward: CGFloat,
        spring: Spring,
        recordedAt: CFTimeInterval
    )
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
    //
    // The clamp is now reachable by design rather than by accident, and it
    // is worth saying exactly what it answers, because the anchor asks
    // this function about `now - renderPhase` and that is *before*
    // `recordedAt` for the first three frames of every record.
    //
    // What comes back there is `from.offset` — the record's starting
    // state. That is the right answer whenever the record describes a
    // flight leaving a surface that was standing still, because the
    // surface really was there, and under gh#175 that is very nearly
    // always: tracked writes are bare, so a gesture leaves nothing in
    // flight, and both the `.dismissing` stamped at a commit and the
    // `.settling` stamped at a gesture boundary start from a stationary
    // model.
    //
    // Two residues, both bounded, and both erring *with* the gesture
    // rather than against it — the direction `dragActivationDistance`
    // already spends 20pt on:
    //
    //   * A record stamped at a release is preceded by the finger's own
    //     approach rather than by a standstill, so for one phase the
    //     answer reads up to three frames of release velocity below the
    //     glass — 60pt at 1200pt/s. It needs the surface re-grabbed within
    //     50ms of letting go of it.
    //   * A settle started *over* a live fly-off composes two different
    //     springs, and a composite of unlike springs is not a single
    //     flight; solved as one it is 3-27pt out until the faster of the
    //     two has run. Only two callers do it — the preview branch and the
    //     foreground restore — and neither has a finger on the surface.
    //     The catch under a finger deliberately does not: it stops the
    //     fly-off with a bare write, which is what keeps a single spring
    //     in the air and the anchor exact where it is actually read.
    //
    // What closed the old hazard here was not this clamp but the gate
    // going away. A bare write admitted inside the undefined window used
    // to render up to `v * phase` larger than it scored — 26.9pt at the
    // worst fixture — and the 816-configuration sweep's earliest decision
    // at +56.7ms left 6.7ms of room at three frames, which is what made a
    // fourth frame unbuyable. There is no decision left to be wrong, so
    // there is no window left to run out of.
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
    case let .dismissing(from, toward, dismissSpring, recordedAt):
        // Solved on the record's own spring, not the caller's: this is
        // the one flight that is not `settleSpring`.
        return focusSpringFlight(
            from: from,
            toward: toward,
            spring: dismissSpring,
            elapsed: now - recordedAt
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
/// caught dismissal is no longer the bare case either. The fly-off
/// records itself (`FocusSurfaceMotion.dismissing`), so the settle starts
/// from where the surface actually is and at the speed it is actually
/// going, and the injection is correctly withheld because that velocity
/// is already in the record. Reading the model instead — `exitTravel`,
/// which is what this used to do — puts the surface 57-488pt below the
/// truth. That was safe while the only consumer was a gate wanting to
/// stay armed, and is not safe now the same reading is what a tracked
/// write anchors on.
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
/// Where it fires, measured — and it reconciles with the code, which took
/// three rounds and a rebuilt rig. On an 874pt portrait surface the gate
/// is `max(120, 874 × 0.2)` = **174.8pt**, and bisected against release
/// velocity in portrait manual focus the commanded distance at which it
/// commits runs −200pt/s → 201.5, 0 → 172.5, +200 → 142.5, +400 → 98.5.
/// The gate reads `predictedEndTranslation`, so a release still moving
/// downward commits short and one still moving upward commits long, which
/// is the sign of every step of that. Near zero the local projection
/// factor is (201.5 − 142.5) / 400 = **0.147s**; it is emphatically not
/// constant — the same bisection gives 0.220s between +200 and +400 — so
/// it is a local slope and not a formula.
///
/// The 874 is settled by bracketing zero velocity from both sides, because
/// no rig can command exactly zero: an ease-out release, which retains a
/// trace of downward velocity, commits at 172.5, and an approach from
/// above, which retains a trace of upward velocity, at 178.5. 174.8 lies
/// inside that bracket and the 120 floor does not, so `geo.size.height` is
/// 874 and no third explanation is needed.
///
/// **The 125-130pt reading three rounds argued from was a rig artefact.**
/// A round-10 probe put this gate between 125 and 130 on what it recorded
/// as a stationary release, which reconciles with no device height — 125-130
/// needs an `h` between 625 and 650pt, and that is no iPhone or iPad in
/// either orientation. Two of the three candidate explanations round 12
/// wrote down are now dead: delivered translation equals commanded to
/// 0.04%, and the surface height is 874 as above. The third is the answer.
/// The release was not stationary: **a held finger produces no new touch
/// samples, so UIKit's estimator keeps whatever velocity the approach ramp
/// had**, and `predictedEndTranslation` goes on projecting tens of points
/// past `translation` however long the finger is held — which is exactly
/// why the probe found the reading independent of a 200-800ms hold and
/// read that as evidence *for* stationarity. 174.8 − 127.5 is 47pt of
/// projection, which read off the velocity bisection above is a retained
/// ramp of roughly 250-350pt/s. The tell is that it does not reproduce:
/// two re-bisections of the same protocol gave 133.5 and 147.5.
///
/// So nothing is tuned against 125-130, and a rig that ramps in and holds
/// before lifting is measuring its own ramp. A stationary release is
/// measured by bracketing, the way the 874 above was.
///
/// And whatever the number, it bounds nothing under a closed gate.
/// `canExitBySwipe == false` — rotation-driven focus, which is the
/// configuration gh#129's own repro and
/// `testFocusHandoffSpringsASettleThatIsStillMovingAwayFromHome` are both
/// taken in — returns `false` here at every distance. There is no largest
/// gate-legal drag there, so no re-swipe distance is out of reach and the
/// commit gate mitigates nothing. Confirmed on the device rather than
/// argued: driven under rotation-driven focus, 150 and 174pt re-swipes
/// reach peaks of 150.00 and 174.00, settle to 0.00 and leave focus
/// intact — neither commits nor exits.
///
/// Seen once, not reproduced, and downgraded accordingly: one commit run
/// in twelve left the surface stranded about 170pt down — shift 509px, err
/// 53.1 — neither committed nor home. It has not recurred in 24 subsequent
/// commit runs, and commit reliability is 12/12 at 170pt released at
/// 1200pt/s with per-run pre-state assertions. Recorded so it is not lost,
/// not so it is acted on.
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
