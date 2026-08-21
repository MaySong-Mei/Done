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
    /// **A record describes a single spring, and the one case where two
    /// are in the air at once is the catch.** A gesture leaves nothing in
    /// flight, so the commit's `.dismissing` starts from a standstill, and
    /// an ordinary settle is started over a surface that is already still;
    /// those records are exact. A catch settles *over* a live fly-off, and
    /// a composite of unlike springs is not a single flight, so the
    /// `.settling` it writes is a model rather than a reading — the only
    /// approximate record this file produces.
    ///
    /// Round 14 avoided that by stopping the fly-off with a bare write,
    /// which bought exactness and cost a rendered step on every touch that
    /// landed on a moving surface. The deadband buys the step back and pays
    /// for it here; `focusSpringFlight` has the size of it and why it is a
    /// prediction. See `FocusSurfaceMotion.dismissing`.
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
    /// True while a touch is on the surface. `@GestureState` rather than
    /// `@State` for the one property that distinguishes it: **SwiftUI
    /// resets it when the gesture ends *or is cancelled*, and a
    /// cancellation is precisely the case `onEnded` cannot see.**
    ///
    /// **A demonstrated fix, against a control. Round 19 said the opposite
    /// and was wrong on every clause; this is the retraction.** Round 18
    /// shipped this against a strand it never attributed, round 19 reported
    /// the belt indistinguishable from its absence, and both readings were
    /// rig artefacts. Driven against `b96b6ad` — this file without the belt
    /// — in portrait manual focus, finger stepped down to a commanded
    /// offset and held 1.6s, **HOME pressed with the touch still down**,
    /// the lift delivered to SpringBoard 1.4s later, the app then
    /// foregrounded with `simctl launch` and no touch at all:
    ///
    ///                60pt   101pt   160pt   total
    ///     b96b6ad    2/2    5/5     2/2     9/9 stranded, 0 recovered
    ///     this build 2/2    6/6     2/2     10/10 recovered, 0 stranded
    ///
    /// Same PID before and after in every trial. `Start tracking` was still
    /// in the accessibility tree in all nine parent trials, so **nothing
    /// committed** and what is parked is `focusSurfaceIsStranded` exactly.
    /// It is a park and not a slow settle: the parent sat at **101pt at +4,
    /// +9, +19 and +39s**, four samples of one number. All three offsets are
    /// sub-gate (174.8), which is the reachable half of the hazard — above
    /// the gate `applyForegroundDismissRecovery` has its own backstop, and
    /// that is the likeliest reading of round 19's 219.67pt "recovery" on
    /// the parent: it never established that focus was still up with nothing
    /// committed, and an honoured commit also reads 0.00pt.
    ///
    /// **Attribution is the diff, not an inference.** The whole non-comment
    /// change between the two builds is this property, its `.updating`, the
    /// `.onChange` below, `settleStrandedSurface`, and the three free
    /// functions plus one struct they call; every other line of the 613-line
    /// diff is a comment. **Not run:** landscape, where
    /// `canExitBySwipe == false`.
    ///
    /// **What a rig has to do to measure any of this, because two rounds of
    /// measurement were void for want of it.** Focus is a zIndex-2 overlay
    /// in a `ZStack` that leaves `ContentView` mounted underneath, so `idb
    /// ui describe-all` lists `Tab Bar`, `More`, `Create` and `Reminders`
    /// **while focus is up**. No label-presence gate separates the two pages
    /// — not "the tab bar is absent", and not round 19's `grep -q '"Note"'`,
    /// which passes on the detail page. The gate has to be **optical**: a
    /// dual correlator (2-D luminance and 1-D saturation profile against a
    /// two-layer focus-over-calendar model, margin ≥ 3, the two agreeing
    /// within 12pt), re-validated before every trial — at rest 0pt at margin
    /// 435, a commanded 100pt hold 100pt at margin 199 — and **refusing**
    /// the calendar (margin 1.9) and SpringBoard (margin 1.0).
    ///
    /// **Every train-sourced number in this file is void, including ones
    /// this file has argued from.** A swipe train leaves focus on its
    /// *first* swipe and measures the calendar underneath from then on: 23
    /// trains driven, 23 exited, **0 measured the focus surface**. 140pt at
    /// 0.08s exits on swipe 1; so do 6-swipe trains at 100, 80, 60, 40 and
    /// 30pt, with gaps out to 0.5s, whether or not the start point repeats.
    /// The sites are marked `TRAIN-VOID` below.
    ///
    /// Read in `body` only by the `.onChange` that drives the recovery, so
    /// the reset is the event and the flag is only the carrier.
    @GestureState private var isFingerDown = false

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
                // is already nil and this does nothing, leaving the surface
                // parked at `exitTravel` where it cannot be hit-tested. It
                // needs the completion to win a race with this handler
                // inside one frame; the ordinary rotation ordering is
                // covered, 4 for 4. Closing it needs an unconditional
                // settle plus a finger-down guard — `isFingerDown` exists
                // but is deliberately not wired here, which still needs the
                // `pendingDismissID` guard for the jitter above.
                .onChange(of: canExitBySwipe) { _, canExit in
                    guard !canExit else { return }
                    catchPendingDismiss()
                }
                // `onExit`'s only caller is the fly-off animation's
                // completion. A completion that never runs leaves the model
                // at `exitTravel` — the surface off-screen, unhittable,
                // nothing else writing it, a focus session the user cannot
                // end. Returning from a full background trip is the one
                // moment we can tell that happened, because a completion
                // that was going to run has by then.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        wasBackgrounded = true
                    } else if phase == .active {
                        applyForegroundDismissRecovery()
                    }
                }
                // The finger has left the surface. Ordinarily `onEnded` has
                // already decided what that means and this declines; it
                // does the work only when `onEnded` never ran, which is a
                // cancellation. See `settleStrandedSurface`.
                //
                // The edge is read from *both* values, and that is **tidy
                // and not load-bearing** — the round that added it claimed
                // the second. `onChange(of:)` without `initial:` fires only
                // when `oldValue != newValue`, and for a `Bool` that makes
                // `isDown == false` imply `wasDown == true`. The predicate
                // is therefore identical to `guard !isDown` here, and its
                // one discriminating input, `(false, false)`, cannot be
                // delivered. See `focusFingerLeftTheSurface`.
                .onChange(of: isFingerDown) { wasDown, isDown in
                    guard focusFingerLeftTheSurface(wasDown: wasDown, isDown: isDown) else { return }
                    settleStrandedSurface()
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
                    // `onChanged` instead, which is a different thing from
                    // gating *recognition*: the catch needs the frame the
                    // finger lands on, and only the tracked write needs
                    // 20pt of it.
                    DragGesture(minimumDistance: 0)
                        // Carries nothing but "a touch is on the surface".
                        // What is load-bearing is the *reset*: SwiftUI
                        // clears a `@GestureState` when the gesture ends
                        // **or is cancelled**, and the cancellation is the
                        // event `onEnded` is never delivered for and
                        // `latchedGestureStart` can only detect after the
                        // fact, from the next touch, if that touch lands
                        // somewhere else.
                        .updating($isFingerDown) { _, state, _ in
                            state = true
                        }
                        .onChanged { value in
                            beginGestureIfNew(startLocation: value.startLocation)
                            // Any touch on a surface that is flying
                            // off-screen revokes the dismissal and springs
                            // it home, whether or not it ever becomes a
                            // drag. Guarded internally on there being one,
                            // so an ordinary touch starts no spring.
                            //
                            // This runs *before* the deadband rather than
                            // behind it, and the ordering is the whole of
                            // the catch. A surface flying off-screen has
                            // to answer a finger on the frame the finger
                            // lands, because 20pt later it is gone; but
                            // answering by *tracking* is what round 14
                            // did, and a tracked write is bare, so a
                            // stray touch that never moved rendered a
                            // −5…−67pt step and a tap on the type pill
                            // started no event. Answering by settling is
                            // continuous in position and velocity — the
                            // interpolating spring picks the surface up at
                            // the speed it is already going — so the frame
                            // the finger lands on shows no step at all.
                            //
                            // What it does not do is stop the revocation: a
                            // stray touch still cancels a committed exit.
                            // Only the visible consequence changes, from a
                            // bare step to a spring. Filed separately.
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
                            if !isTrackingDrag {
                                isTrackingDrag = true
                                // Read before the write below, because the
                                // write is what retires the flight this
                                // reads: afterwards there is nothing left
                                // to ask where the surface was.
                                //
                                // `pendingDismissID` is nil here on every
                                // path — the catch above cleared it — so
                                // the record this reads after an
                                // interception is the `.settling` that
                                // catch started, never a live
                                // `.dismissing`. That is the reason the
                                // deadband and the anchor are not in
                                // tension: the deadband decides when
                                // tracking starts, the anchor decides what
                                // it starts from.
                                //
                                // It is *not* the reason the answer is
                                // right. The read is at `now -
                                // renderPhase`, and the catch may be zero,
                                // one or two frames old — zero because a
                                // finger already moving when it lands can
                                // deliver its first `onChanged` with 20pt
                                // of translation on it. In all three the
                                // glass is still showing the fly-off and
                                // the settle record does not cover the
                                // question; it answers by chaining to the
                                // `.dismissing` it replaced. See
                                // `FocusSurfaceMotion.settling`.
                                //
                                // **Read here, on the frame the write
                                // below lands, and not a frame earlier.**
                                // The whole of the cancellation is that
                                // `anchor == presented(t_write - phase)`,
                                // so the rendered step is `translation`
                                // and nothing else. Latching at touch-down
                                // instead — appealing, because the anchor
                                // would then be "where the surface was
                                // when the finger landed" — puts the
                                // surface's own travel across the deadband
                                // into the step with the sign of that
                                // travel. Solved on this file's fixtures:
                                // **-255.90pt** backward on a catch on 874
                                // and -449.53 on 1366, and up to
                                // **+91.72pt** more over-delivery per
                                // swipe where the settle runs home. Worse
                                // than round 14 or 15 in both directions
                                // at once, and `precededBy` does not save
                                // it: it makes the read correct for the
                                // instant asked about, and the defect is
                                // the instant.
                                trackingAnchor = focusSurfacePresentedState(
                                    motion: surfaceMotion,
                                    modelOffset: dragOffsetY,
                                    spring: FocusSurfaceMetrics.settleSpring,
                                    now: CACurrentMediaTime() - FocusSurfaceMetrics.renderPhase
                                ).offset
                            }
                            // 1:1 from where the surface actually is. The
                            // upward clamp is on the *sum*, not on the
                            // translation: from rest the anchor is 0 and
                            // this is the same expression it always was,
                            // and from a catch it is what lets the finger
                            // push a surface it grabbed mid-flight back up
                            // toward home instead of pinning it.
                            //
                            // The downward clamp is a recovery guarantee
                            // rather than a feel choice, and it is new:
                            // a bare tracked write with no upper bound can
                            // put the surface entirely past the bottom
                            // edge, and a cancellation there strands it
                            // where no touch can reach it. See
                            // `FocusSurfaceMetrics.minimumHittableStrip`.
                            trackSurface(
                                to: focusTrackedOffset(
                                    anchor: trackingAnchor,
                                    translationY: value.translation.height,
                                    surfaceHeight: geo.size.height
                                )
                            )
                        }
                        .onEnded { value in
                            let wasTrackingDrag = isTrackingDrag
                            // Read before the reset three lines down, not
                            // after: the commit gate below is a statement
                            // about where the *surface* will end up, and
                            // the surface is `anchor + translation`. Left
                            // where the reset had already run it would be
                            // the old finger-only gate with extra words.
                            let anchorAtRelease = trackingAnchor
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
                                // Nothing needs re-labelling on the way
                                // past: tracked writes are bare, so a model
                                // at 0 with no record really is a surface
                                // at rest.
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
                                trackingAnchor: anchorAtRelease,
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
                                // The fly-off describes itself, and the
                                // record and the animation are computed
                                // from one place so they cannot disagree.
                                // It used to be described by nothing, and
                                // a catch therefore settled from the
                                // model — `exitTravel` — which reads
                                // 57-488pt below where the surface
                                // actually is. As a gate input that
                                // over-read was deliberate and safe: it
                                // kept the handoff armed. As the *anchor*
                                // it is a several hundred point shove down
                                // the screen on the one gesture this whole
                                // mechanism exists for. See `trackSurface`.
                                //
                                // Why the velocity is not injected the way
                                // the settle's is: the gesture that just
                                // ended tracked bare, so there is no
                                // spring in flight to double-count.
                                // `released` is the whole of the surface's
                                // velocity, not an addition to something
                                // already moving, which is exactly what
                                // `focusSettlePlan` tests for with
                                // `motion == nil` before it injects. The
                                // two are the same rule; only this site
                                // can prove its precondition statically.
                                let plan = focusDismissPlan(
                                    modelOffset: dragOffsetY,
                                    exitTravel: exitTravel,
                                    releaseVelocity: released,
                                    spring: FocusSurfaceMetrics.dismissSpring,
                                    now: CACurrentMediaTime()
                                )
                                surfaceMotion = plan.motion
                                withAnimation(
                                    .interpolatingSpring(
                                        FocusSurfaceMetrics.dismissSpring,
                                        initialVelocity: plan.initialVelocity
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
    /// **Cancellation during a fly-off, which is what the deadband closed.**
    /// Round 14's waiver let the touch-down frame itself write bare, so a
    /// cancellation there left `dragOffsetY` several hundred points down
    /// with no record, no pending id and the latch still set — and both
    /// recovery paths guarded on `pendingDismissID != nil`. The touch-down
    /// frame settles instead of tracking now, so a cancellation there
    /// leaves an animation already running home.
    ///
    /// The bare-tracking state used to be enterable without the finger
    /// travelling 20pt: after a cancellation the latch survived, a next
    /// touch on a bit-identical `startLocation` made `focusDragIsNewGesture`
    /// decline, `isTrackingDrag` stayed set, and the write was `anchor + 0`
    /// — after a catch, a jump of several hundred points, and on a rig
    /// replaying one swipe spec it is every run rather than a needle.
    /// `focusFingerLeftPlan` clears the latch on every finger-leave.
    ///
    /// What is left besides is the ordinary stranded offset above: cancel
    /// *after* the deadband and the surface parks until the next touch,
    /// which this function settles. The half of it that had no recovery at
    /// all — a surface stranded entirely past the bottom edge, where no
    /// touch can reach this function — is closed by the clamp on the
    /// tracked write, `FocusSurfaceMetrics.minimumHittableStrip`.
    ///
    /// **The unconditional clear also opened something, and it is not
    /// closed.** Gestures are told apart by `startLocation`, which is fixed
    /// for the life of a gesture — so before round 18 this function could
    /// only fire on a gesture's *first* update, and the rounds that wrote
    /// that were right. There are now two clear sites, and one of them runs
    /// off a view update rather than off the gesture. If a gesture G2's
    /// first `onChanged` is delivered before G1's `@GestureState` reset has
    /// been flushed, the flush nils G2's own latch and G2's *second*
    /// `onChanged` re-enters here mid-gesture: `isTrackingDrag` cleared,
    /// `trackingAnchor` re-read from the presentation, and the next tracked
    /// write `anchor + 2 × translation` instead of `anchor + translation`,
    /// plus a settle under a finger that is still down.
    ///
    /// **`focusFingerLeftTheSurface` does not narrow it, and round 19 said
    /// three times that it did.** At its only call site that predicate is
    /// `!isDown` exactly — see its own doc — so the hole is open precisely
    /// as round 18 left it. The coalesced shape fires no `.onChange` in
    /// either build; the non-coalesced one, two separate deliveries, still
    /// re-enters here. It is left open and named rather than papered over
    /// because the fix needs gesture identity the view does not have.
    ///
    /// **Unmeasured, and the measurement that used to be cited here was
    /// void.** Round 18's "15 trains / 90 swipes, 0 strands" is
    /// `TRAIN-VOID`: the train left focus on swipe 1 and swipes 2-6 were
    /// dragging the calendar. Nothing has looked for this.
    private func beginGestureIfNew(startLocation: CGPoint) {
        guard focusDragIsNewGesture(
            latchedStart: latchedGestureStart,
            updateStart: startLocation
        ) else { return }
        latchedGestureStart = startLocation
        isTrackingDrag = false
        // Reset with the latch it belongs to. `onEnded` clears both and is
        // the only other site that clears either; a cancelled gesture
        // reaches neither, and leaving the anchor set while clearing the
        // tracking flag would have the next gesture re-latch the flag and
        // inherit the old anchor — a jump of the whole anchor on the frame
        // it starts tracking. Unreachable today because the flag is
        // cleared here and the anchor is re-read whenever it is, so this
        // is redundancy against the two ever being separated again.
        trackingAnchor = 0
        // Nothing for *this* function to bring home: either the surface is
        // already at rest, or a dismissal is in flight and `onChanged`'s
        // unconditional `catchPendingDismiss` is about to settle it on
        // this same frame. Settling here as well would start a second
        // spring toward the same target, and the ordering is what makes
        // the guard safe rather than merely lucky — this runs first and
        // declines, the catch runs next and does the work.
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
    /// model's step but `dragOffsetY - presented(t - phase)`, established
    /// directly by logging the frame each bare write lands on against the
    /// finger's position on it — the rendered ramp reproduces it to
    /// 0.005-0.02pt rms across 40+ traces. The phase is an integer number
    /// of frames (`60 * elapsed` lands on an integer, |err| < 0.01 frame,
    /// because touch delivery and animation sampling share the 60Hz grid),
    /// and **no single integer fits**: the same protocol forces 2 in some
    /// runs and 3 in others, and the post-hold protocol forces 4, with an
    /// empty intersection in all three builds measured. A threshold cannot
    /// be positioned against a quantity whose own definition moves by
    /// 9-13pt per frame of uncertainty, which is why thirteen rounds of
    /// moving the constant never converged.
    ///
    /// **Why re-anchoring gets out of it.** For the old form that step is
    /// `translation - presented(t - phase)` and for this one it is
    /// `anchor + translation - presented(t - phase)`. The old form carries
    /// the whole `presented - tracked` gap — 85pt on a re-swipe, up to
    /// 874pt on a catch — with the phase entering as an error in
    /// *predicting* it, and one frame of phase error is 9-13pt, precisely
    /// enough to flip a 20pt threshold. That is round 13's failure: the
    /// gate certified ≤ 20pt and the surface rendered 25.57-28.87pt.
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
    /// **Why the spring had to go rather than be tuned around —
    /// `TRAIN-VOID`, and the decision is shipped anyway.** The routed path
    /// inherits a tracking lag (0.060s * v on the device, 17pt at 300pt/s
    /// and 61pt at 1000), and what condemned it was a rapid train: swipes
    /// 1 and 3 reaching 100.4-103.7pt while 2 and 4 reached 68.2-70.8.
    /// Those readings were taken past swipe 1 of a train, so they are the
    /// calendar and not this surface. The lag itself is a property of the
    /// routing and stands; the train figures do not, and nothing in this
    /// round re-opens gh#175 on the strength of them. Nothing here routes.
    ///
    /// **What it costs, deliberately.** The offset is no longer the
    /// finger's translation, so a drag that takes hold of a moving surface
    /// carries on from where that surface is rather than from rest, and a
    /// re-swipe dismisses from further down. That is a design change
    /// against device-verified behaviour and it is the reason gh#175 was
    /// filed separately rather than done inline.
    ///
    /// **On the same rapid train, priced.** The routed path under-delivered
    /// — every other swipe reached two thirds of its travel. This one
    /// delivers all of its travel and starts it from wherever the previous
    /// settle has got to, so the *absolute* peak is `residual + travel`
    /// and it compounds: each swipe releases from further down, so the next
    /// settle has further to come. Four 100pt swipes at 667pt/s on an
    /// 874pt surface, solved on this file's own springs:
    ///
    ///     gap 300ms:  100.0 / 100.1 / 100.1 / 100.1
    ///     gap 150ms:  100.0 / 142.1 / 154.6 / 158.2
    ///     gap 100ms:  100.0 / 175.5 / 219.2 / 244.4
    ///      gap 50ms:  100.0 / 204.0 / 297.3 / 381.0
    ///
    /// The response to the finger is 1:1 and the rendered step is exactly
    /// the translation at every one of those gaps — what moves is where
    /// the swipe starts, not how much of it arrives. **The number is a
    /// function of the gap, so a train measurement that does not pin the
    /// gap cannot tell two builds apart**: the same build reads 100.1 and
    /// 244.4 on swipe 4 at 300ms and 100ms.
    ///
    /// **"The builds do not differ on this path, established by replay" was
    /// `TRAIN-VOID` and is withdrawn.** The replay against the round-14
    /// binary agreed at every pinned gap, and every one of those readings
    /// was taken past swipe 1 of a train. It established nothing about
    /// either build's focus surface. Also deleted with it: two rounds of
    /// struck-out explanations for a historical disagreement the replay was
    /// supposed to have settled.
    ///
    /// The byte-identity argument stands and is independent of all of it:
    /// rounds 14, 15 and 16 execute identical code here, because under a
    /// closed gate nothing commits, so the deadband waiver round 15 removed
    /// was `pendingDismissID != nil` and false throughout, the moved
    /// `catchPendingDismiss` is a no-op, `focusDismissPlan` is unreached
    /// and `focusDismissCommits` returns at its first guard.
    ///
    /// **The table above is a model, and it has never been checked against
    /// anything.** The one comparison this file carried — a percentage band
    /// on swipes 2-4 at a 150ms gap — was `TRAIN-VOID`, and round 19 had
    /// already deleted the six raw readings it was derived from while
    /// keeping the derived number, so it could not be re-checked either.
    /// Both are gone. Treat the table as the shape of the dependence on the
    /// gap, which is what it is used for here, and not as a prediction
    /// anything has confirmed.
    ///
    /// Whether the drift is acceptable is a product decision and not one
    /// this file can make, but the option space is small and each corner
    /// is a defect some round has already shipped: a **step** (write the
    /// translation bare from rest — the surface jumps back by the residual,
    /// which is round 13's 25.57-28.87pt and round 14's -5.03…-67.00), a
    /// **sub-unity response** (bleed the anchor out over the drag — at a
    /// 65pt residual the surface answers the first points of finger travel
    /// at 0.5:1 or worse, which is the routed path's failure in a new
    /// costume), or this **drift**. There is no fourth corner: the surface
    /// is somewhere when the finger lands, and the three are what you can
    /// do about it.
    ///
    /// The commit gate is *not* unaffected. `focusDismissCommits` read
    /// `predictedEndTranslation` alone, which equalled the projected offset
    /// only while the anchor was 0; a surface caught 736pt down then needed
    /// a further 174.8pt of projection to leave and could not be dismissed
    /// by a slow drag at all (2/2 on device). The gate reads
    /// `anchor + predictedEndTranslation` now, byte-identical from rest
    /// (`testFocusDismissGateIsByteIdenticalFromRest`), and it changes what
    /// a release *after a catch* decides in two ways named in
    /// `focusDismissCommits` — consequences to measure, not a claim of
    /// correctness.
    ///
    /// What a catch does *not* do any more is pin the surface: it settles
    /// home under a finger that only touched it, and the deadband is what
    /// makes that possible. The anchor is not "where the surface got to by
    /// the time the finger had travelled 20pt" — it is what the *glass* was
    /// showing `renderPhase` before the finger crossed 20pt, which for a
    /// fast flick is a frame or two of the pre-catch fly-off and for a slow
    /// drag is the settle. The record carries both so that read can be
    /// answered; see `FocusSurfaceMotion.settling`'s `precededBy` and
    /// `focusDragShouldTrack`.
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
    /// Neither error is safe in one direction: reading high over-arms the
    /// handoff (round 4, 61pt of trailing lag on a re-swipe) and reading low
    /// writes bare through a real backwards pop (round 5, 54pt up the screen
    /// in one frame). The constraint is two-sided, so the answer is not to
    /// pick an error direction but to ask the spring, which
    /// `focusSettlePlan` does.
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

    /// Bring home a surface that a gesture left parked with nothing
    /// carrying it, and drop whatever that gesture latched. Driven by
    /// `isFingerDown` falling, which is the one signal this view gets for a
    /// gesture the system **cancelled**.
    ///
    /// Both halves of what it does — always clear the latch, settle only a
    /// strand — are `focusFingerLeftPlan`, which is where they are pinned.
    /// The unconditional clear is the half with teeth: it is the only
    /// reason a replayed swipe spec, which produces bit-identical
    /// `startLocation`s by construction, cannot be mistaken for a
    /// continuation of the gesture that was cancelled.
    ///
    /// **`onEnded` cannot produce a strand**, which is why a separate site
    /// exists. Its commit records `.dismissing`, its settle records
    /// `.settling`, and its preview branch settles whenever the model is
    /// off rest. The only branch that returns without writing anything is
    /// `guard wasTrackingDrag`, and that one is safe by a case split. Round
    /// 19's two-bullet version contradicted itself between the bullets
    /// ("neither settles", then "which settles anything off rest"). There
    /// are three cases and two of them settle:
    ///
    ///   * `focusDragIsNewGesture` **false**: `isTrackingDrag` was never
    ///     cleared, so `wasTrackingDrag` is true, this guard does not
    ///     return, and the release commits or settles like any other.
    ///   * **True, with a dismissal outstanding**: `beginGestureIfNew` runs
    ///     its body and then returns at `pendingDismissID == nil`, settling
    ///     nothing — and `catchPendingDismiss`, on the next line of
    ///     `onChanged`, settles. Model 0.
    ///   * **True, with none outstanding**: `catchPendingDismiss` returns at
    ///     its own guard, and `beginGestureIfNew` settles if the model is
    ///     off rest and does nothing if it is already 0. Model 0 either way.
    ///
    /// Only the third case's second half — the ordinary tap on a surface
    /// already at rest — is the "neither settles" that wording generalised
    /// from.
    ///
    /// A parked non-zero model with a *nil* record is therefore left by
    /// exactly one writer — `trackSurface`, which is bare by construction —
    /// and only when nobody came back for it. See `focusSurfaceIsStranded`.
    ///
    /// **Ordering: this assumes `onEnded` runs first, and nothing in this
    /// file can establish it.** `.onChange` is a view-update callback and
    /// `onEnded` is an event-delivery callback in the same turn, so SwiftUI
    /// should flush this second. Both branches have now been observed
    /// behaving as the forward ordering predicts — the commit branch by 6
    /// fly-offs with 0 settle-then-commit dips, the settle branch by the
    /// overshoot measurement below — which is evidence and not proof. What
    /// each would cost if the order were reversed:
    ///
    ///   * **Commit branch: safe.** `isTrackingDrag` and `trackingAnchor`
    ///     are deliberately *not* cleared here, so `onEnded` still reads
    ///     `anchor + projected` and still commits. It costs one
    ///     `.dismissing` stamped from a model of 0, which matters only to a
    ///     catch inside the next three frames.
    ///   * **Settle branch: would cost the velocity inheritance.** This
    ///     settle stamps `.settling` and writes the model to 0, and
    ///     `focusSettlePlan` injects a release velocity only when
    ///     `motion == nil && modelOffset > 0`. Both terms would then be
    ///     false, so a sub-gate release would come home on a step response
    ///     from rest and lose exactly what #128 and #129 exist to
    ///     establish. Pinned as arithmetic by
    ///     `testFocusSettlePlanUnderReversedOrderingLosesTheReleaseVelocity`.
    ///
    /// **The forward ordering is now measured, on the branch that would
    /// have paid.** Filmed sub-gate releases, peak rendered offset against
    /// commanded travel: 60pt released at ~50pt/s peaks at 60 (**+0**),
    /// at ~400pt/s at 62 (**+2**), at ~600pt/s at 64 (**+4**); 50pt at
    /// ~830pt/s peaks at 55 (**+5**). A settle from rest cannot overshoot
    /// its own start — `x(0) = travel` with `v(0) = 0` is the maximum of
    /// that response — so *any* positive overshoot is the injection
    /// happening, and the ~50pt/s row is the control that shows the
    /// instrument reads 0 when there is nothing to inherit. The parent
    /// build matches at every comparable point (+2, +3), which is the other
    /// half of it: the belt does not touch this branch.
    ///
    /// **A fix is not available, and this is why — not "the two orderings
    /// are indistinguishable", which is false.** Two discriminators exist
    /// already: `focusSettlePlan`'s own guard (forward ordering always
    /// presents `motion == nil && modelOffset > 0`, reversed always
    /// presents `.settling` with the model at 0), and `releaseVelocity != 0`,
    /// which is true at exactly one of the five settle call sites. What
    /// cannot be done is act on them. Under the reversed ordering the model
    /// is already 0, so `onEnded`'s `withAnimation { dragOffsetY = 0 }`
    /// carries no model change — and `interpolatingSpring` takes its
    /// initial velocity as a *fraction of the model's change per second*,
    /// so there is no normalised number that expresses any velocity at all
    /// through it. That is `focusSettlePlan`'s own argument for the
    /// `modelOffset > 0` term, applied one level up. The release velocity
    /// is unexpressible there, not merely discarded, and widening the guard
    /// would buy an over-stated `.settling` record and nothing on screen.
    ///
    /// One cost that is real and is not the velocity: under the reversed
    /// ordering `surfaceMotion` is re-stamped at a later `now` from a model
    /// of 0, which is a stale anchor for any catch inside the next
    /// `renderPhase`.
    private func settleStrandedSurface() {
        let plan = focusFingerLeftPlan(
            motion: surfaceMotion,
            modelOffset: dragOffsetY,
            hasPendingDismiss: pendingDismissID != nil
        )
        if plan.clearsLatch {
            latchedGestureStart = nil
        }
        if plan.settlesHome {
            settleSurfaceHome()
        }
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
/// They live out here rather than as `private let`s on the view because a
/// test that declares its own `Spring(duration: 0.4, bounce: 0.2)` beside a
/// comment claiming to pin the view's pins nothing: the view's copy could
/// change to any other spring and all 15 handoff tests would still pass
/// while the admit window moved 40%. One declaration, two readers.
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
    /// How much of the surface a *tracked* write must leave on screen.
    ///
    /// Not a feel constant — a recovery one, and the only thing standing
    /// between a cancelled drag and a focus session that cannot be ended.
    /// A tracked write is bare, so a gesture the system cancels after the
    /// deadband (call banner, Face ID) leaves `dragOffsetY` wherever the
    /// last one put it with no record and no pending id. Every recovery
    /// path either needs a touch to land on the surface
    /// (`beginGestureIfNew`) or is guarded on `pendingDismissID != nil`
    /// (the rotation handler and the foreground backstop), so a surface
    /// stranded entirely past the bottom edge has none: it cannot be
    /// hit-tested, so no touch produces an `onChanged`, and nothing else
    /// writes the offset.
    ///
    /// Round 13 needed 874pt of finger travel to reach that and it was
    /// judged unreachable. Under gh#175's anchor it is one ordinary catch,
    /// because the write is `anchor + translation` and the anchor is not
    /// where the finger landed. **"140pt of drag on top of a catch at 736"
    /// is not the configuration and is not available** — from a grab at
    /// 736 on an 874pt screen the finger has 138pt left, and 736 + 138 is
    /// 874 exactly. What reaches it is the catch settle carrying the
    /// surface *past* the grab point on the fly-off's inherited velocity:
    /// probed, a commit at 120pt released at 800pt/s caught 0.040s later
    /// is grabbed at 257.84, the deadband is crossed on frame 5 with the
    /// anchor by then at **335.79**, and the finger has **616.16pt** left
    /// to the bottom edge. The unclamped write is **951.95** — 97.95 past
    /// this ceiling, 77.95 past the screen. On 1366 it is 1502.72. See
    /// `focusDismissPlan` for the full arithmetic and
    /// `testFocusTrackedWriteAlwaysLeavesAHittableStrip` for the fixture.
    ///
    /// Clamping the write costs a surface that stops 20pt short of leaving
    /// under a very long slow finger. It does not touch the fly-off: the
    /// commit writes `exitTravel` directly, not through `trackSurface`.
    ///
    /// **Not verified on the device: BLOCKED.** Engaging the 854 ceiling
    /// needs an anchor of at least 464 for a 390pt finger, which is not
    /// reachable from rest, and the largest clean hold the rig has managed
    /// is 823.32pt. Round 18's "390 and 396 leave the surface edge in the
    /// same place" is withdrawn — it agreed to "25px in their own frame
    /// space", which has the same smell as the 50.00pt cap this file struck
    /// out of `trackSurface`.
    ///
    /// **What it buys is a guarantee about the write, not an invariant
    /// about the surface, and one round's wording claimed the second.**
    /// The ceiling is `geo.size.height - 20` for the height *current at
    /// the write*. Cancel a drag at 700 in portrait — 854 ceiling, passes —
    /// then rotate to landscape, where `h` is 402, and the surface sits at
    /// 700 with nothing on screen to touch. `settleStrandedSurface` does
    /// not close that, whatever round 18 said: a rotation **while the
    /// finger is still down** produces no `@GestureState` reset, so the
    /// belt never runs. What closes it is the re-clamp on the next tracked
    /// write, at the new height, and `onEnded`. A re-clamp when the size
    /// itself changes would make this an invariant of the surface; nothing
    /// does that today.
    ///
    /// Distinct from `dragActivationDistance` despite the shared value.
    /// That one is a distance the finger travels; this one is a height of
    /// surface, and the two answer to nothing in common. This file has
    /// been burned by one declaration serving two meanings.
    static let minimumHittableStrip: CGFloat = 20
    /// How much older than this view's own clock the frame on the glass is.
    ///
    /// Read at exactly one site — the anchor `trackSurface` latches at the
    /// first tracked update of a gesture — and nothing branches on it.
    ///
    /// **Why a phase constant survived gh#175, which was filed to remove
    /// it.** The re-anchor removes the *gate*, not the phase. `trackSurface`
    /// carries the algebra; the consequence for this constant is that the
    /// anchor is read on the **glass** clock, which leaves `translation`
    /// plus or minus one frame of the surface's own motion, where the model
    /// clock would leave a systematically backwards `phase * v_settle`
    /// reaching -209pt on a catch. So a wrong value here cannot bare-write
    /// something that should have been routed — there is nothing left to
    /// route — and the two frames of measured spread buy one frame of
    /// settle travel, which is by construction the step the eye is already
    /// watching the surface take. Not worth tuning again.
    ///
    /// The measurement is round 13's, unchanged: **2.48-2.75 frames**, two
    /// independent readings on an optically calibrated rig (the Simulator
    /// window is **not** point-accurate — 0.9641 host points per device
    /// point, and every figure predating that calibration is suspect).
    /// Frame indices are the honest clock: simctl's recorder jitters PTS by
    /// up to a frame, so nothing here is derived from a recorded timestamp.
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
/// There is no dismissal waiver, and the round that added one is why the
/// absence is documented rather than merely absent. Round 14 let a
/// dismissal in flight skip the deadband, reasoning that a surface flying
/// off-screen cannot be tapped so any touch on one is an interception.
/// The premise is right and the conclusion did not follow: *catching* has
/// to happen on the frame the finger lands, but catching is not tracking,
/// and the view catches unconditionally in `onChanged` before this
/// function is consulted. Waiving the deadband as well made the first
/// tracked write land on the touch-down frame, and a tracked write is
/// bare — so a stray touch that never moved, and a tap on the type pill,
/// each rendered a step and revoked a committed exit. Device: 8/8
/// interceptions, −5.03…−67.00pt.
///
/// With the waiver gone a touch decides nothing until it has travelled, on
/// a flying surface exactly as on a still one, and the surface it is
/// deciding about is already settling home by then. **What that bought, and
/// on which input:** a **stationary** stray touch intercepting a fly-off,
/// 4/4 intercepted, 4/4 focus retained, **max backward step 0.00pt in all
/// 4**, ghost frames 0 in 6 fly-offs, against −5.03…−67.00 for the waiver.
///
/// The **moving**-finger interception is a different input and this file
/// has quoted one at the other. It is also unmeasured: the −10.4…−13.1pt
/// backward step reported in 5 of 15 runs was `TRAIN-VOID`, so the
/// stale-anchor band `focusSpringFlight` predicts (−41…−12) has no device
/// reading against it in either direction. What is fixed is the case a
/// touch that never moved used to render at all.
///
/// Pure / testable. No UI side effects.
func focusDragShouldTrack(
    isTracking: Bool,
    translationY: CGFloat,
    activationDistance: CGFloat
) -> Bool {
    isTracking || translationY > activationDistance
}

/// Where a tracked write puts the surface: 1:1 from wherever it already
/// was, bounded at both ends.
///
/// The upward bound is old and is on the *sum* rather than the
/// translation, which is what lets a finger push a surface it grabbed
/// mid-flight back up toward home instead of pinning it there.
///
/// The downward bound is new and is not about feel. See
/// `FocusSurfaceMetrics.minimumHittableStrip` for the hazard; the shape
/// here is only that the two bounds have to be applied in an order that
/// cannot produce a negative offset, because a surface height smaller than
/// the strip — a degenerate first layout pass — would otherwise put the
/// ceiling below the floor and write the model somewhere
/// `.offset(y: max(0, dragOffsetY))` renders as rest while
/// `dragOffsetY != 0` still reads as "off its rest position".
///
/// Pure / testable. No UI side effects.
func focusTrackedOffset(
    anchor: CGFloat,
    translationY: CGFloat,
    surfaceHeight: CGFloat,
    strip: CGFloat = FocusSurfaceMetrics.minimumHittableStrip
) -> CGFloat {
    let ceiling = max(0, surfaceHeight - strip)
    return min(max(0, anchor + translationY), ceiling)
}

/// Whether this update belongs to a gesture the view has not seen yet, and
/// so whether anything the previous gesture latched has to be thrown away
/// before this touch is allowed to decide anything.
///
/// `startLocation` is fixed for the life of a `DragGesture`, and the view
/// clears its record whenever a finger leaves — in `onEnded`, and in
/// `settleStrandedSurface` for the cancellation `onEnded` is not delivered
/// for. Two separate touches landing on bit-identical coordinates would be
/// missed; nothing else is, and with both clear sites wired the record is
/// expected to be nil at every touch-down. The blind spot is documented
/// rather than removed because it is the failure mode if the
/// `@GestureState` reset the belt rests on ever stops being delivered —
/// and on a rig replaying one swipe spec, bit-identical coordinates are
/// not a needle but every run.
///
/// The second clear site also means this can now return `true` *inside* a
/// gesture, which it could not before round 18. See `beginGestureIfNew`,
/// which is where that costs something.
///
/// Pure / testable. No UI side effects.
func focusDragIsNewGesture(latchedStart: CGPoint?, updateStart: CGPoint) -> Bool {
    latchedStart != updateStart
}

/// Whether the surface is parked somewhere it should not be with nothing
/// bringing it home.
///
/// Three terms, and each one is doing work.
///
///   * **`motion == nil` means nothing is in flight.** Every animated
///     write in this file stamps a record in the same update — the settle
///     a `.settling`, the commit a `.dismissing` — and the only writer
///     that leaves a nil record is `trackSurface`, which is bare by
///     construction. So a nil record is not "we don't know", it is "the
///     last thing that touched the model was a finger".
///   * **`modelOffset != 0`** — the surface is off its rest position. With
///     the term above, off its rest position and *staying* there.
///   * **`hasPendingDismiss` is false.** A committed fly-off has a
///     `.dismissing` record, so this is redundant against today's code;
///     it is here because "a dismissal is outstanding" has its own two
///     recovery paths (the rotation handler and the foreground backstop)
///     and this one must not race them.
///
/// The caller is `settleStrandedSurface`, invoked when the finger leaves —
/// which is what makes the predicate safe. Mid-drag the first two terms
/// are true on every frame and settling would fight the finger.
///
/// **What reaches it, commandably.** A cancellation with the finger still
/// down — HOME pressed mid-drag, the lift then delivered to SpringBoard —
/// parks the surface at whatever the last tracked write left, and nothing
/// else in this view comes back for it. Measured against the build without
/// the belt: **9/9 stranded at 60, 101 and 160pt**, still at exactly 101 at
/// +4, +9, +19 and +39s, with nothing committed. That is this predicate's
/// input, and `isFingerDown` carries the whole measurement.
///
/// **What reached it before, and could not be attributed.** Round 17's QA
/// left the surface at **441.0** and **657.7pt** on an 874pt screen, 1.8s
/// after release, in two of six 140pt runs — `TRAIN-VOID`, so those two
/// numbers are readings of the calendar and are kept only because two
/// rounds of arithmetic were built on them. Both candidate causes still die
/// on that arithmetic, whatever the readings were of:
///
///   * **Not the clamp.** A saturated write is exactly `854.00` on every
///     run, and these are two different numbers, both below it.
///   * **Not a fly-off.** The commit writes `exitTravel`, which on that
///     device is 874 — one value, fully off-screen.
///
/// The third — "some release settled and simply stopped short" — dies on
/// the **clock**, not on velocity arithmetic, and this is the argument that
/// carries the predicate generally rather than at one offset. A settle
/// records `.settling` and is over: swept across every startable offset and
/// release velocity on both surfaces this app runs, the worst is **2.9pt
/// from home at 0.5s on 874 and 4.9pt on 1366**, and under 0.005pt by 1.0s.
/// Nothing that reads as a settle can be a surface holding 101pt at +39s.
/// That is the whole discriminator, and it is
/// `testFocusSettleIsHomeLongBeforeAStrandIsCalled`.
///
/// Two rounds argued it from velocity instead — "174.8 is the largest
/// model a sub-gate release can leave on 874" — and that is false by a
/// factor of **2.52** (440 against a gate of 174.8), which is the ratio
/// `testFocusSubGateReleaseCanLeaveTheModelFarAboveTheGate` asserts. Round
/// 19 wrote 2.7× here and fixtured 2.52; the number lives in the test now.
/// The gate reads the *projection*; an **upward** release has
/// `predictedEndTranslation < translation`, so the model at release exceeds
/// it, and the test drives that through the file's own projection band
/// rather than through two unrelated literals.
///
/// **Why a release goes undelivered in a train — corrected, because the
/// control it rested on was `TRAIN-VOID`.** The claim was "a single 140pt
/// swipe does not exit (0/2), but the second swipe of a train starts on a
/// 17.3-20.0pt residual that halves the projection it must find". The
/// residual was read at the second swipe's touch-down, by which point the
/// train had already left focus, and a single 140pt swipe at 0.08s **does**
/// exit — 23 trains driven, 23 exited, all on swipe 1. So the conclusion
/// stands and its reason does not: a 6 × 140pt train with zero commits
/// cannot be constructed because the *first* swipe commits, not because the
/// second one is cheaper. The anchor arithmetic in
/// `testFocusTrainAnchorMoreThanHalvesTheProjectionNeededToExit` is true of
/// the gate and is no longer evidence about a train.
///
/// Pinned by `testFocusStrandedSurfaceIsTheOneStateOnEndedCannotProduce`.
///
/// Pure / testable. No UI side effects.
func focusSurfaceIsStranded(
    motion: FocusSurfaceMotion?,
    modelOffset: CGFloat,
    hasPendingDismiss: Bool
) -> Bool {
    guard !hasPendingDismiss, modelOffset != 0 else { return false }
    return motion == nil
}

/// Whether a change in "a touch is on the surface" is the finger actually
/// leaving it.
///
/// **A name for a condition, not a narrowing, and the round that added it
/// claimed a narrowing three times over.** Its only reader is the
/// `.onChange(of: isFingerDown)` in `body`, and `onChange(of:)` with
/// `initial` defaulted to `false` runs its action only when
/// `oldValue != newValue`. For a `Bool` that means `isDown == false`
/// implies `wasDown == true`, so at that site this function returns
/// exactly what `!isDown` returns. The one input that separates them,
/// `(false, false)`, is undeliverable.
///
/// So the coalescing case it was written for is not narrowed by it either.
/// If a gesture's `@GestureState` reset and the next gesture's first update
/// land in one view update, the value never changes and `.onChange` is not
/// called at all — round 18's `guard !down` declined for that same reason.
/// What is left open is the *non*-coalesced interleaving, two deliveries,
/// which this cannot touch and which `beginGestureIfNew` names. Kept
/// because the truth table is worth stating once, not because it does
/// anything.
///
/// Pure / testable. No UI side effects.
func focusFingerLeftTheSurface(wasDown: Bool, isDown: Bool) -> Bool {
    wasDown && !isDown
}

/// Everything the view does when a finger leaves the surface.
///
/// Two independent decisions, a struct rather than a `Bool` so that the
/// *unconditional* one is visible in the type. Round 18 shipped the latch
/// clear as a bare statement above a `guard`, with sixty lines of prose as
/// the only record that it runs even when the settle declines.
///
///   * `clearsLatch` is **always true**. No touch arriving after a finger
///     has left is a continuation of the gesture that left, so nothing
///     that gesture latched may outlive it — including a cancellation
///     *before* the deadband, where the model is still 0, `settlesHome` is
///     false, and the latch would otherwise survive to be matched against
///     a replayed swipe's bit-identical `startLocation`.
///   * `settlesHome` is the strand predicate and nothing else.
///
/// **What the fixture can and cannot reach.** `clearsLatch` is a literal,
/// so no input distinguishes it — but the regression it exists to catch
/// does: fold the clear back behind the settle guard and every row where
/// `settlesHome` is false starts returning `false`, which is five of the
/// seven rows the test drives. What no unit test reaches is the *wiring* in
/// `settleStrandedSurface`, where `plan.clearsLatch` has to be read outside
/// the `settlesHome` branch, and that is where a regression would land.
///
/// Pure / testable. No UI side effects.
struct FocusFingerLeftPlan: Equatable {
    var clearsLatch: Bool
    var settlesHome: Bool
}

func focusFingerLeftPlan(
    motion: FocusSurfaceMotion?,
    modelOffset: CGFloat,
    hasPendingDismiss: Bool
) -> FocusFingerLeftPlan {
    FocusFingerLeftPlan(
        clearsLatch: true,
        settlesHome: focusSurfaceIsStranded(
            motion: motion,
            modelOffset: modelOffset,
            hasPendingDismiss: hasPendingDismiss
        )
    )
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
    ///
    /// **`precededBy` is what the glass was showing before `recordedAt`,
    /// and the anchor is the reason it has to be kept.** The anchor asks
    /// `focusSurfacePresentedState` about `now - renderPhase` — three
    /// frames in the past — so for the first three frames of any record
    /// the question is about a time the record does not cover. Answering
    /// it from `from.offset`, which is what the clamp in
    /// `focusSpringFlight` does on its own, is right only while the
    /// surface was standing still before the record started.
    ///
    /// A catch is exactly the case where it was not. The touch-down frame
    /// stamps a `.settling` over a fly-off travelling at up to 83pt per
    /// frame, so a finger that crosses the 20pt deadband within three
    /// frames of landing — an ordinary flick, faster than ~400pt/s, and
    /// the natural gesture when chasing a surface that is fleeing —
    /// anchors on where it *grabbed* the surface while the glass is still
    /// showing the fly-off one to three frames earlier. Measured against
    /// this file's own fixture that is 163.86pt of rendered step at one
    /// frame and 82.84 at two on an 874pt screen, 270.45 and 136.73 on
    /// 1366, at the assumed phase — deterministic, not a phase band, so no
    /// tuning of `renderPhase` touches it. Chaining the record the catch
    /// replaced drives all four to exactly 0, and what is left is the
    /// one-frame term every other path already carries.
    ///
    /// Only one level is kept, via `withoutPredecessor`. The window that can
    /// consult it is `renderPhase` wide — three frames — and reaching two
    /// levels inside it needs two settles started *less* than 50ms apart
    /// with no tracked write between them. No path produces that, and here
    /// are all five `settleSurfaceHome` call sites; two rounds running have
    /// edited the bullets and the number in opposite directions, so grep
    /// before changing either:
    ///
    ///   * `cancelDismissAndSettle`, reached from the touch-down catch,
    ///     the rotation handler and the foreground backstop — guarded on
    ///     `pendingDismissID != nil`, which the catch clears.
    ///   * `beginGestureIfNew` — guarded on `pendingDismissID == nil` *and*
    ///     `dragOffsetY != 0`, which the catch writes to 0.
    ///   * `onEnded`'s preview branch — guarded on `dragOffsetY != 0`.
    ///   * `onEnded`'s `settleSurfaceHome(releaseVelocity:)`, which is
    ///     guarded by **neither** of those. Its guard is `wasTrackingDrag`,
    ///     and that is what makes it safe, for a third reason: a gesture
    ///     that tracked wrote through `trackSurface`, `trackSurface` nils
    ///     the record, so `motion` is nil at that site and the record it
    ///     stamps has no predecessor at all. A two-deep read would have
    ///     cost up to ~170pt, so the omission mattered.
    ///   * `settleStrandedSurface`. It cannot chain at all, by construction
    ///     rather than by argument: its guard `focusSurfaceIsStranded`
    ///     requires `motion == nil`, so `focusSettlePlan`'s
    ///     `precededBy: motion?.withoutPredecessor` is nil there for the
    ///     same reason the record is the strand signature.
    ///
    /// One level also bounds what the box retains. Do *not* reach for the
    /// other shape that suggests itself — moving `recordedAt` back to the
    /// glass clock answers the same three frames and mis-dates the flight
    /// forward for every frame after them.
    indirect case settling(
        from: FocusSurfaceState,
        recordedAt: CFTimeInterval,
        precededBy: FocusSurfaceMotion? = nil
    )
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
    /// really running on. It is also the one flight a second spring is
    /// ever started over: `focusSurfacePresentedState` is exact for a
    /// composite of *same*-spring flights — indistinguishable from one
    /// flight solved from the composite state, a property of the linear
    /// ODE — and that exactness is lost the moment two different springs
    /// are in the air, which is precisely a catch. See `focusSpringFlight`
    /// for what it costs and `focusDragShouldTrack` for why the round that
    /// avoided it was worse.
    case dismissing(
        from: FocusSurfaceState,
        toward: CGFloat,
        spring: Spring,
        recordedAt: CFTimeInterval
    )

    /// This record with whatever it was itself chained to dropped — what a
    /// *new* record stores as its predecessor.
    ///
    /// The chain is one deep on purpose. See `settling`'s `precededBy`,
    /// which enumerates the five settle sites and shows that no two of them
    /// can stamp inside one `renderPhase` window.
    var withoutPredecessor: FocusSurfaceMotion {
        switch self {
        case let .settling(from, recordedAt, _):
            return .settling(from: from, recordedAt: recordedAt)
        case .dismissing:
            return self
        }
    }
}

/// Where the focus surface's *presentation* is, and how fast it is going.
///
/// Not the model. `dragOffsetY` is written the instant a gesture or a
/// commit decides something and the presentation is wherever the
/// animation on it has reached; the two agree only when nothing is in
/// flight. A commit puts the model at `exitTravel` while the surface is
/// still on screen, and a catch puts the model at rest while the surface
/// is still several hundred points down it.
struct FocusSurfaceState: Equatable {
    /// Presented offset, signed and measured from rest. Genuinely
    /// negative while a settle is past rest: the spring overshoots by
    /// 1.52% of what it settled, and `.offset(y: max(0, dragOffsetY))`
    /// clamps the animation's endpoints, not its interpolation. QA's
    /// −13.12pt overshoot is that clamp behaving as described, not a
    /// missing one.
    ///
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
    // **This clamp is not what answers a read from before `recordedAt`,
    // and a previous version of this comment said it was.** The anchor
    // asks about `now - renderPhase`, which is before `recordedAt` for the
    // first three frames of every record, and the answer the clamp gives
    // there is `from.offset` — the record's starting state. That is right
    // only while the surface was *standing still* before the record
    // started, and the round that wrote it down claimed that held "very
    // nearly always". It does not hold for the one record this whole
    // mechanism exists for: the `.settling` a catch stamps starts from a
    // surface moving at up to 83pt per frame, so for the first three
    // frames the clamp returned where the finger grabbed it while the
    // glass was still showing the fly-off — 163.86pt of rendered step at
    // one frame, on an 874pt screen, with the phase constant exactly
    // right.
    //
    // What answers it now is `FocusSurfaceMotion.settling`'s `precededBy`,
    // resolved in `focusSurfacePresentedState` before this function is
    // reached. This clamp is back to what it was written as: a guard
    // against a clock reading backwards, and the terminal answer at the
    // end of a chain, where the record really is the oldest thing known
    // and its `from` really was a standstill.
    //
    // Two residues survive that, both bounded, and both erring *with* the
    // gesture rather than against it — the direction
    // `dragActivationDistance` already spends 20pt on:
    //
    //   * A record stamped at a release is preceded by the finger's own
    //     approach rather than by a standstill, and the finger is not a
    //     flight for a predecessor to chain to. So for one phase the
    //     answer reads up to three frames of release velocity below the
    //     glass — 60pt at 1200pt/s. It needs the surface re-grabbed within
    //     50ms of letting go of it.
    //   * A settle started *over* a live fly-off composes two different
    //     springs, and a composite of unlike springs is not a single
    //     flight. It is the price of the deadband: the catch under a finger
    //     settles over the fly-off rather than stopping it with a bare
    //     write, so the composite is on the finger's own path. The callers:
    //
    //       - `onChanged`'s unconditional catch — the only one with a
    //         finger on the surface, and the reason the other three matter
    //         less than they read, because it fires first on any touch.
    //       - `.onChange(of: canExitBySwipe)` — rotating into landscape
    //         while a dismissal is in flight. A real composite; the finger
    //         is free the instant it fires.
    //       - the foreground restore, after a full background trip. No
    //         finger.
    //       - `handleClockTrackingTap`. Defensive only: the pill lives
    //         inside this gesture's hit region, so the touch-down catch
    //         above has already run by the time the tap action does.
    //
    //     Size, and it is *not* bounded by one frame of the surface's own
    //     motion the way the phase term is — this is the one term in the
    //     anchor that the pass criterion does not cover. Measured, not
    //     approximated: the single flight this file solves, differenced
    //     against the two interpolating springs added, over this file's
    //     own fixture (commit at 120pt released at 800pt/s, caught
    //     50-170ms later). τ is the read instant's distance past the
    //     catch, which is `k - 3` frames when the finger crosses the
    //     deadband on frame k.
    //
    //       874pt screen: 1.11-2.08pt at one frame, 3.60-7.16 at two,
    //       9.33-20.88 at four, 14.61-41.76 at eight. On 1366:
    //       1.86-3.43, 6.04-11.81, 15.65-34.45, 24.55-69.02.
    //
    //     Do not approximate it as `½ Δa τ²`: the term is not a
    //     leading-order one by the time it peaks, and that approximation
    //     understated the eight-frame band by 27%. Swept over every catch
    //     instant with at least 20pt of surface still visible rather than
    //     only the fixture window, the global maximum is 45.31pt on 874 and
    //     74.78 on 1366, at **τ = 11** frames past a catch 30ms after the
    //     commit (deadband crossed on frame k = 14). Past that both flights
    //     converge on the same rest and it decays.
    //
    //     The deadband does *not* keep this read near the small end — it
    //     pushes it towards the large one, because τ is the time the finger
    //     spends crossing 20pt and a slow deliberate drag spends more
    //     frames doing that than a flick.
    //
    //     It has not been verified on the device — it rests on SwiftUI
    //     composing two live interpolating springs additively, which
    //     cannot be established statically. Treat the figures as the
    //     prediction to falsify, not as a measurement.
    //
    //     What it does to the anchor's total. At the assumed phase the
    //     single-flight model reads 0 by construction and the truth is this
    //     term, so the honest worst case is the two terms summed: 96.20pt
    //     on 874 and 150.43 on 1366, against 94.25 and 148.45 for the
    //     one-frame term alone — low by 2.1% and 1.3%, which is a different
    //     quantity from the 27% above and has been conflated with it once.
    //
    //     **94.25 and 148.45 are the fixture's worst, not the mechanism's**,
    //     and QA measures against these numbers. That sweep holds the commit
    //     at 120pt and the release at 800pt/s; sweeping the release velocity
    //     too, the one-frame term reaches **104pt on 874** (commit ~0,
    //     release 5000pt/s) and **154 on 1366**, and 98 at an ordinary
    //     3000pt/s flick. The pass criterion is the one-frame bound itself,
    //     not any of these figures.
    //
    // **What the device says about the model above: nothing yet, and one
    // round said "confirmed".** The backward-step prediction is the one
    // that matters, and the only reading offered against it — −10.4…−13.1pt
    // in 5 of 15 moving-finger interceptions — was `TRAIN-VOID`. The
    // *stationary* stray touch, which is a different input and renders
    // **0.00pt backward in 4 of 4**, is not evidence about this band and
    // this file has quoted the two at each other before. Treat the figures
    // above as the prediction to falsify.
    //
    // What would settle the residual is instrumentation, not more reps:
    // log the anchor and the frame index at the one `@State` write that
    // sets it. The optical correlator is needed only for the phase, which
    // is the term with almost none of the variance.
    //
    // What closed the old hazard here was not this clamp but the gate going
    // away: there is no decision left to be wrong, so there is no window
    // left to run out of.
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
    case let .settling(from, recordedAt, precededBy):
        // Before this record existed the glass was showing whatever it
        // replaced, and on a catch that is a fly-off moving at up to 83pt
        // per frame. Resolving it there instead of flattening to
        // `from.offset` is the whole of what `precededBy` is for — see the
        // case's own doc for the size of what flattening rendered.
        //
        // `modelOffset` rides along and is never consulted: the recursion
        // only happens when there *is* a predecessor, and the `nil` arm is
        // the only reader of the model.
        if now < recordedAt, let precededBy {
            return focusSurfacePresentedState(
                motion: precededBy,
                modelOffset: modelOffset,
                spring: spring,
                now: now
            )
        }
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
    //
    // **The guard is also the ordering detector, which is why nothing
    // extra is wired for one.** Under the forward ordering `onEnded`'s
    // settle always arrives with `motion == nil && modelOffset > 0`:
    // `trackSurface` nils the record and `wasTrackingDrag` implies a
    // tracked write. Under a reversed one it always arrives with
    // `.settling` and a model of 0. So this line already tells the two
    // apart and answers by withholding. (A second, free discriminator
    // exists — `releaseVelocity != 0` is true at exactly one of the five
    // `settleSurfaceHome` call sites — and is equally unusable, for the
    // reason immediately above: through a zero-length model change no
    // normalised velocity reaches the animation. See
    // `settleStrandedSurface`; pinned by
    // `testFocusSettlePlanUnderReversedOrderingLosesTheReleaseVelocity`.)
    let injected: CGFloat = motion == nil && modelOffset > 0 ? releaseVelocity : 0
    let travelled = modelOffset > 0 ? modelOffset : 1
    return (
        initialVelocity: Double(-injected / travelled),
        motion: .settling(
            from: FocusSurfaceState(
                offset: presented.offset,
                velocity: presented.velocity + injected
            ),
            recordedAt: now,
            // What the glass will still be showing for `renderPhase` after
            // this record is stamped. On a catch that is the fly-off, and
            // the anchor reads it; everywhere else `motion` is nil and this
            // is nil with it, which is every ordinary settle from rest.
            // Chained one deep — see `FocusSurfaceMotion.settling`.
            precededBy: motion?.withoutPredecessor
        )
    )
}

/// What a committed dismissal has to hand `interpolatingSpring` as its
/// initial velocity, and what the flight it is about to perform should be
/// recorded as. The commit-side twin of `focusSettlePlan`, and it exists
/// as a function for the same reason: the record and the animation have to
/// be computed from one expression or they drift apart, and this pair
/// already had.
///
/// **The normalisation, which is where the drift was.**
/// `interpolatingSpring` reads `initialVelocity` as a fraction of the
/// model's own change per second, and the model's change here is
/// `exitTravel − modelOffset`. Divide by exactly that and the animation
/// receives `releaseVelocity` points per second, which is what the record
/// claims. The previous form divided by `max(exitTravel − modelOffset, 1)`
/// and claimed `released` unconditionally, so the claim was true only
/// while the change exceeded 1pt.
///
/// **What the branch is, and what it is not.** The old form was wrong
/// wherever it was exercised — with the floor active the animation was
/// handed `released × (exitTravel − modelOffset)`, so for `released = 600`
/// through a 34pt overshoot it received −20,400pt/s *upward* while the
/// record asserted +600 downward — and the branch delivers exactly what it
/// records at every input. That much is verified.
///
/// The argument for *reaching* those inputs was wrong and is withdrawn.
/// **The anchor is not where the finger landed**, so "the finger is inside
/// `[a, h]`, therefore `a + translation ≤ h`, therefore you cannot drag
/// past the bottom edge" does not follow. `a` is the presented offset read
/// `renderPhase` before the finger crossed the deadband, and the settle a
/// catch starts inherits the fly-off's downward velocity: it carries the
/// surface *further down than the grab point* before coming home.
///
/// **How far is swept, not quoted**, in
/// `testFocusCatchSettleOvershootIsWorseThanItsFixture`, which asserts both
/// the fixture's value and the swept worst case and prints them, so there
/// is one place to read the number and it cannot go stale. QA filmed the
/// mechanism happening (`P3_stray60_1`, frames 19→23) at a correlator
/// margin of 1.0-1.1x — below the rig's own rejection threshold, so
/// illustrative and not scored.
///
/// A finger that grabs the surface and then reaches the bottom edge is
/// worth `h − grab` of translation on top of that larger anchor, and the
/// unclamped write reaches **951.95 on an 874pt screen — 77.95 past the
/// bottom edge** — and **1502.72 on 1366**. Both at a *mid* catch: +0.040s
/// after the commit, deadband crossed on frame 5, grab 257.84, anchor
/// 335.79, 616.16pt of finger.
///
/// The other half stands. `exitTravel` is not inset by the safe area —
/// `DoneApp` applies `.ignoresSafeArea()` to `FocusModeView` itself, so
/// the `GeometryReader` reports the full window and there is no inset gap
/// to exceed.
///
/// So `change ≥ 20` on every path that reaches here, and `change ≤ 0` is
/// unreachable — **but by the clamp on the tracked write
/// (`minimumHittableStrip`) alone, never "implicitly as well".** Strike the
/// clamp and the arithmetic above is what is left: a surface stranded at
/// 951.95 on an 874pt screen, unhittable, focus unendable — the hazard
/// `minimumHittableStrip` was added for, which that constant's own doc
/// already called reachable while this paragraph said it was not. (A bare
/// `:906` stood where that symbol name is now and had rotted into the
/// middle of `settleSurfaceHome`. Line numbers do not survive a round in
/// this file; cite the symbol.)
///
/// The branch stays anyway, mirroring the settle's, because it makes the
/// record and the animation agree by construction rather than by a
/// reachability argument — and this file has now had six consecutive rounds
/// in which the reachability argument was the part that was wrong.
/// `exitTravel` is left alone: widening it to
/// `max(width, height, modelOffset + 1)` would also close the arithmetic,
/// by moving where the surface lands on the one path QA has signed off on
/// 10/10.
///
/// Pure / testable. No UI side effects.
func focusDismissPlan(
    modelOffset: CGFloat,
    exitTravel: CGFloat,
    releaseVelocity: CGFloat,
    spring: Spring,
    now: CFTimeInterval
) -> (initialVelocity: Double, motion: FocusSurfaceMotion) {
    let change = exitTravel - modelOffset
    let delivered: CGFloat = change > 0 ? releaseVelocity : 0
    return (
        initialVelocity: change > 0 ? Double(releaseVelocity / change) : 0,
        motion: .dismissing(
            from: FocusSurfaceState(offset: modelOffset, velocity: delivered),
            toward: exitTravel,
            spring: spring,
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
/// commits runs −200pt/s → 201.5, ~0 → 172.5, +200 → 142.5, +400 → 98.5.
/// The `~0` row is the ease-out release two paragraphs below, which retains
/// a trace of *downward* velocity; no rig commands exactly zero, and the
/// zero-velocity commit point is the 172.5-178.5 bracket, not the 172.5.
/// What moves across that bisection is the projection, so a release still
/// moving downward commits short and one still moving upward commits long,
/// which is the sign of every step of it. (Those readings were taken from
/// rest, where the anchor is 0 and the projected offset and the projected
/// translation are the same number. The gate reads the *offset* — see
/// below, where this paragraph used to contradict the one three below it
/// inside the same doc comment.)
///
/// **The projection horizon τ, which is a band and not the 0.147s this
/// file quoted.** Solve each bisection point against the gate — at the
/// commit boundary `d + τ·v == 174.8` — and the three non-degenerate rows
/// give τ = **0.1335 / 0.1615 / 0.19075s**, a 43% spread. `0.147` was the
/// chord `(201.5 − 142.5) / 400` across the middle two, disclaimed in the
/// same sentence that introduced it and then used as arithmetic anyway,
/// including in a test. Anything that needs a horizon must sweep the band;
/// `testFocusSubGateReleaseCanLeaveTheModelFarAboveTheGate` does.
///
/// Re-confirmed at this build by holding the finger still at a commanded
/// distance and lifting: **575 → exits 2/2, 441 → 2/2, 140 → 2/2, 100 →
/// 1/2.** 100 read 0/2 a round earlier, and the boundary is where it should
/// be loose: hold-and-lift keeps the approach ramp, which this file already
/// says two paragraphs down, so the projection at 100 straddles the gate.
/// The tracked response is 1:1 — **n=162 filmed 10pt steps, mean 10.0000,
/// sd 0.0000, min = max = 10**, and 11/11 static holds from 25 to 165pt
/// exact to 0pt — so the commanded distance and the delivered one are the
/// same number and the bracket above is about the gate and nothing else.
/// A tap from rest moves the surface **0.000pt, 4/4**, with 0 non-zero
/// frames in 42: the recovery does not trip on a touch that never travels.
///
/// The 874 is settled by bracketing zero velocity from both sides, because
/// no rig can command exactly zero: an ease-out release, which retains a
/// trace of downward velocity, commits at 172.5, and an approach from
/// above, which retains a trace of upward velocity, at 178.5. 174.8 lies
/// inside that bracket and the 120 floor does not, so `geo.size.height` is
/// 874 and no third explanation is needed.
///
/// The 125-130pt reading three rounds argued from was the rig measuring
/// its own approach ramp: **a held finger produces no new touch samples, so
/// UIKit's estimator keeps whatever velocity it arrived with**, and
/// `predictedEndTranslation` goes on projecting past `translation` however
/// long the finger is held. Nothing is tuned against it, and it is why the
/// hold-and-lift table above sits loose at its boundary.
///
/// Whatever the number, it bounds nothing under a closed gate.
/// `canExitBySwipe == false` — rotation-driven focus, the configuration
/// gh#129's own repro is taken in — returns `false` here at every distance,
/// so no re-swipe distance is out of reach and the commit gate mitigates
/// nothing. Device: 150 and 174pt re-swipes reach peaks of 150.00 and
/// 174.00, settle to 0.00, and leave focus intact.
///
/// **The stranded-commit sighting, and where it went.** Round 12 saw one
/// run in twelve park about 170pt down; round 17 reported 441.0 and 657.7;
/// round 18 reported 0 in 15 trains / 90 swipes and called it gone. All
/// three counts were taken past swipe 1 of a train and are `TRAIN-VOID`.
/// **The park itself is real and is now commandable**: 9/9 against the
/// build without the belt, by cancelling the gesture with the finger down
/// rather than by swiping repeatedly. It is not this function's defect and
/// never was — nothing committed in any of the nine, and the release that
/// would have committed was never delivered. See `focusSurfaceIsStranded`.
///
/// One rig lesson survives the counts and is worth more than they were: 3
/// of 47 traces ended non-zero and looked perfectly stable, and all three
/// were rejected on correlator margin (cost 57.7 / 116.3 / 58.3 at margin
/// 1.00, against 0.02-0.22 at margin 4-350). The app had left focus and the
/// continuing drag was scrolling the calendar underneath. **A rig without a
/// margin check would have reported a 3/47 strand rate here** — and the
/// rounds that dropped the margin check reported train readings as focus
/// readings for two rounds running.
///
/// **What the gate is a statement about.** The projected *offset*, not the
/// projected translation — `trackingAnchor + projectedTranslationY`, which
/// is where the surface would go if the finger carried on as it is going.
/// That is `trackSurface`'s expression only while the clamp is slack:
/// the tracked write is `min(anchor + translation, h − 20)`, so once the
/// surface is pinned at the ceiling the gate reads a projection the
/// surface cannot reach. It reads *high* there, which commits a drag that
/// is already 20pt from the bottom edge — the intended answer, and the
/// reason this is a note rather than a defect. Reading the translation alone
/// was right for as long as the two were the same number, which was every
/// release until gh#175 gave the anchor a non-zero value. Afterwards a
/// surface caught 736pt down an 874pt screen had 138pt of itself left
/// showing and still needed a *further* 174.8pt of projection to leave:
/// confirmed 2/2 on device, where only a flick could clear it and a slow
/// drag could not dismiss the surface at all.
///
/// From rest this is byte-identical, and not by luck: `trackingAnchor` is
/// latched from `focusSurfacePresentedState` at the first tracked update, a
/// surface at rest has no record and no offset, so the anchor is 0 and
/// `0 + projected` is the expression that was already here. Every commit
/// QA has measured is that case. It also reads correctly in the direction
/// that worried the round that added it: a surface caught at 736 and pushed
/// back up to rest projects `736 − 736 = 0` and settles, while one released
/// still 400pt down commits — the rule an uncaught 400pt drag from rest has
/// always obeyed.
///
/// **Two consequences of that rule which nobody decided, named here
/// because they are reachable.** Neither is obviously wrong, but both
/// change what a user has to do, both were arrived at rather than chosen,
/// and they are outstanding product decisions. **They no longer
/// have the same evidentiary standing as each other**, and one round said
/// both were confirmed. What buys them is the late-catch dismissal, which
/// does work and is now measured rather than asserted: **8/8 caught** at
/// 0.15, 0.20 and 0.24s after the commit, focus retained, backward step
/// **0pt**, peaks 653-761. Out of window at 0.28s it misses 1/1 — the
/// overlay has unmounted by then and the touch reaches the tab bar
/// underneath, which is the expected answer and not a defect.
///
///   * **Aborting an exit now costs a hold. CONFIRMED against this
///     build.** A user who lands on a fly-off to abort it, lets it settle
///     under the finger, then drifts 21pt down and lifts, releases against
///     an anchor of 475.5 (probed: 874pt surface, caught 170ms after the
///     commit, finger crossing the deadband eight frames later). Gate
///     input 496.5 against 174.8, so focus exits. Under the previous form
///     the same drift projected 21-60pt and did not commit. Aborting is
///     now "catch it and keep the finger inside 20pt", not "catch it".
///     Device, at this build: a 25-30pt drift after a catch, lifted with
///     no velocity, exits **6/6**; the identical drift from rest exits
///     **0/6**. The control is what makes it a mechanism and not a rig
///     bias, and it is the reason this one survived a round that
///     overturned its sibling.
///   * **The second swipe of a train is cheaper than the first.
///     WITHDRAWN to arithmetic; the measurement was `TRAIN-VOID`.** The
///     residual "read directly at the second swipe's touch-down",
///     17.3-20.0pt, was read after the train had left focus, and its
///     control — single swipe 0/2 against six-swipe train 6/6 — is dead
///     twice over: a single 140pt swipe at 0.08s exits, and the train's
///     exit is swipe 1's. What stands is the gate arithmetic, which needs
///     no device reading: a 20pt anchor more than halves the projection a
///     swipe must find beyond its own translation, 34.8pt from rest
///     against 14.8pt, on 874 at 140pt of finger
///     (`testFocusTrainAnchorMoreThanHalvesTheProjectionNeededToExit`).
///     Whether any real residual is 20pt is unmeasured.
///
/// Pure / testable. No UI side effects.
func focusDismissCommits(
    trackingAnchor: CGFloat,
    projectedTranslationY: CGFloat,
    surfaceHeight: CGFloat,
    canExitBySwipe: Bool
) -> Bool {
    guard canExitBySwipe else { return false }
    let projectedOffset = trackingAnchor + projectedTranslationY
    return projectedOffset > focusDismissProjection(surfaceHeight: surfaceHeight)
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
