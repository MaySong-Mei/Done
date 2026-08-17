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
    /// both gesture boundaries (`beginGestureIfNew`, `onEnded`) drop a
    /// `.smoothing` latch, which belongs to one gesture and must not
    /// outlive it. See `trackSurface`.
    @State private var surfaceMotion: FocusSurfaceMotion?
    /// Whether the app has been fully backgrounded since the last time it
    /// became active. The backstop in `applyForegroundDismissRecovery`
    /// needs a *round trip*, not merely a return to `.active`: pulling
    /// down Control Center over a dismissal in flight passes through
    /// `.inactive` while the animation keeps running perfectly well.
    @State private var wasBackgrounded = false

    /// Downward travel before the surface starts following the finger,
    /// preserving the feel of the `minimumDistance: 20` the gesture used
    /// to be gated on. Keeps taps and the clock view's sideways chip
    /// flicks from nudging it.
    private let dragActivationDistance: CGFloat = 20
    /// Springs, not fixed durations: they take the release velocity as
    /// their initial velocity so the surface keeps the finger's motion,
    /// and being interpolating they blend with whatever is already in
    /// flight rather than restarting from a standstill.
    private let dismissSpring = Spring(duration: 0.35, bounce: 0)
    private let settleSpring = Spring(duration: 0.4, bounce: 0.2)
    /// How far a bare write may drag the surface *backwards past the
    /// finger* before it has to go through a spring instead.
    ///
    /// The quantity this bounds is `residual - trackedOffset`. A bare
    /// write puts the surface exactly where the finger is, so what the
    /// eye catches is the single-frame step from wherever the settle had
    /// got to. When the settle is ahead of the finger the surface steps
    /// *down*, by at most the finger's own travel — the same step every
    /// ordinary drag already takes when the 20pt activation deadband
    /// releases and the surface jumps from rest onto the finger. When the
    /// settle is behind the finger the surface steps *up*, against the
    /// gesture, and that is the teleport. So the gate is on the backwards
    /// component only, and 20pt is the scale the design already treats as
    /// beneath notice.
    ///
    /// A fixed *time* window cannot do this job. The settle's residual is
    /// a percentage of what it is settling, not an absolute: for
    /// `settleSpring` (ζ = 0.8, ω_n = 15.708) it is 1.02% of the
    /// displacement at 0.25s, 1.24% at 0.30s, and peaks at 1.52%
    /// overshoot. On a 300pt settle those first and last are the 3.1pt
    /// and 4.6pt an earlier version of this comment quoted as if they
    /// were absolutes; on an iPad, where `exitTravel` reaches 1366pt, the
    /// same percentages are 17pt and 21pt, which are not too small to
    /// see. Gating on the residual makes the bound absolute on every
    /// screen — this number, whatever the surface.
    private let surfaceHandoffMargin: CGFloat = 20
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
                // the shape that jittered, and there is no reliable
                // finger-down proxy to guard it with: `latchedGestureStart`
                // is stale-non-nil after a cancellation and
                // `isTrackingDrag` is false until the deadband releases.
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
                                activationDistance: dragActivationDistance
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
                            // that just ended. Dropped before the
                            // branches below so the one that settles can
                            // record what it is settling over the top.
                            if surfaceMotion == .smoothing { surfaceMotion = nil }
                            guard pendingProposalTemplate == nil else {
                                // The one write site that used to snap.
                                // Reachable: a dismissal is caught by the
                                // type-pill tap that raises the preview,
                                // and a touch within the settle ends
                                // here — cutting that settle short.
                                if dragOffsetY != 0 { settleSurfaceHome() }
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
                                withAnimation(
                                    .interpolatingSpring(dismissSpring, initialVelocity: released / remaining),
                                    completionCriteria: .logicallyComplete
                                ) {
                                    dragOffsetY = exitTravel
                                } completion: {
                                    guard pendingDismissID == id else { return }
                                    pendingDismissID = nil
                                    onExit()
                                }
                            } else {
                                let travelled = max(dragOffsetY, 1)
                                settleSurfaceHome(initialVelocity: -released / travelled)
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
        // `.smoothing` is a per-gesture latch and the gesture that set it
        // is over. On a cancellation this is the only place that hears
        // about it, and leaving it set would spring-route the whole of
        // the next gesture on a decision made for the dead one. Anything
        // still actually in flight re-records itself immediately below or
        // in the `catchPendingDismiss` that follows this call.
        if surfaceMotion == .smoothing { surfaceMotion = nil }
        // A dismissal in flight is not stranded — `catchPendingDismiss`
        // runs straight after this and owns that case.
        guard pendingDismissID == nil, dragOffsetY != 0 else { return }
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
    /// So every tracked update asks `focusSurfaceHandoff` how far the
    /// settle still has to run, and hands off through an interpolating
    /// spring when a bare write would pull the surface backwards past the
    /// finger. Interpolating springs are additive:
    /// this update's travel is added to the motion already in flight
    /// rather than replacing it, so the surface converges on the finger
    /// instead of teleporting to it.
    ///
    /// The first tracked update of a gesture is the one that decides:
    /// whichever way it goes it writes the answer back, and the rest of
    /// the gesture reads it. Latched, because going rigid partway would
    /// only move the jump to the frame it happened on. The
    /// cost is a tracking lag QA measured at ≈ 0.060s × velocity (17pt at
    /// 300pt/s, 61pt at 1000pt/s), decaying to 0.01pt within ~317ms once
    /// the finger stops. That is a fair price on a catch, where the
    /// alternative is a 148-324pt teleport, and a bad one on an ordinary
    /// swipe — which is why the residual, and not merely the age of the
    /// settle, is what opens the window.
    private func trackSurface(to offset: CGFloat) {
        let handoff = focusSurfaceHandoff(
            motion: surfaceMotion,
            trackedOffset: offset,
            spring: settleSpring,
            visibilityMargin: surfaceHandoffMargin,
            now: CACurrentMediaTime()
        )
        surfaceMotion = handoff.motion
        guard handoff.animate else {
            dragOffsetY = offset
            return
        }
        withAnimation(.interpolatingSpring(settleSpring)) {
            dragOffsetY = offset
        }
    }

    /// Spring the surface back to rest, and record what is being settled
    /// so a drag arriving while it is still moving hands off through
    /// `trackSurface` instead of snapping.
    ///
    /// The displacement recorded is the *model* value, which is an upper
    /// bound on what the eye sees and is tight only when the two agree.
    /// They agree for a swipe that did not commit — the finger tracked
    /// the surface there — and they do not for a caught dismissal, where
    /// the model is already at `exitTravel` while the presentation is
    /// wherever the fly-off had got to. Erring high is the safe
    /// direction: it can only keep the handoff armed longer than needed.
    private func settleSurfaceHome(initialVelocity: Double = 0) {
        let displacement = dragOffsetY
        withAnimation(.interpolatingSpring(settleSpring, initialVelocity: initialVelocity)) {
            dragOffsetY = 0
        }
        surfaceMotion = .settling(
            displacement: displacement,
            recordedAt: CACurrentMediaTime()
        )
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
    /// A settle is running. `displacement` is what the surface was
    /// travelling from when it started (an upper bound on what the eye
    /// sees — see `settleSurfaceHome`), `recordedAt` is when.
    case settling(displacement: CGFloat, recordedAt: CFTimeInterval)
    /// This gesture's tracked writes are being handed off through a
    /// spring, and stay that way until it ends.
    case smoothing
}

/// How far a settle started from `displacement` still has to travel,
/// `elapsed` seconds in.
///
/// The envelope of the spring's step response, not the response itself:
/// for a damping ratio ζ below 1 the residual is
/// `displacement · e^(−ζω_n·t) / √(1−ζ²) · |sin(ω_d·t + φ)|`, and this
/// drops the `|sin|`. That makes it an upper bound rather than an
/// estimate, which is what the caller wants — it is monotone in `elapsed`
/// (the true residual passes through zero at every half period, and a
/// gate on it would flicker), and it errs toward keeping the handoff
/// armed. `ζω_n` is read off the spring as `damping / 2m` so the two
/// cannot drift apart; for `Spring(duration: 0.4, bounce: 0.2)` that is
/// 12.566 with a `1/√(1−ζ²)` gain of 1.667.
///
/// It is also blind to the initial velocity a settle carries, which is a
/// step response's whole assumption. Every non-committing swipe hands
/// `settleSurfaceHome` a homeward release velocity, which gets it home
/// sooner than this says — so the estimate runs high on exactly the case
/// the gate must exclude, and the margins it clears them by are floors
/// rather than the real numbers. A caught dismissal settles from rest
/// (`initialVelocity` defaults to 0), where the assumption holds.
///
/// Pure / testable. No UI side effects.
func focusSettleResidualEstimate(
    displacement: CGFloat,
    elapsed: CFTimeInterval,
    spring: Spring
) -> CGFloat {
    let decayRate = spring.damping / (2 * spring.mass)
    let ratio = spring.dampingRatio
    let gain = ratio < 1 ? 1 / (1 - ratio * ratio).squareRoot() : 1
    let decay = exp(-decayRate * max(0, elapsed)) * gain
    return abs(displacement) * CGFloat(decay)
}

/// Whether this tracked write has to be handed off through a spring, and
/// what the surface is doing once it has been made.
///
/// The surface's model value and its presented value are different things
/// while an animation is in flight, and an unanimated write to a value
/// with an animation on it removes the animation and jumps to the new
/// value. A bare write lands the surface exactly on the finger, so the
/// step it costs is `residual - trackedOffset`: negative means the
/// surface catches *down* to the finger by less than the finger's own
/// travel, which is what the activation deadband already does on every
/// ordinary drag; positive means it is dragged *up*, against the gesture,
/// and that is the teleport this exists to remove.
///
/// Gating on that, rather than on the age of the settle, is what tells a
/// catch from an ordinary re-swipe without either of them having to say
/// which it is. A catch follows a committed dismissal, so the
/// displacement being settled is `exitTravel`; an ordinary swipe that did
/// not commit leaves only the distance it was dragged, and the commit
/// gate is `focusDismissProjection` — one fifth of the surface — so the
/// two are about a factor of five apart and the residual decays through
/// that factor in 128ms.
///
/// Not a formal partition, and deliberately not written as one: a drag
/// released moving upward projects short and does not commit however far
/// it travelled, and while `canExitBySwipe` is false nothing commits at
/// all. Those settles are genuinely large, the surface genuinely is a
/// long way from home, and a large residual is what they get treated as.
/// A threshold on "did this commit" would have had to special-case them.
///
/// The decision is latched for the length of a gesture: handing back to a
/// bare write partway would only move the jump to the frame it happened
/// on.
///
/// Pure / testable. No UI side effects.
func focusSurfaceHandoff(
    motion: FocusSurfaceMotion?,
    trackedOffset: CGFloat,
    spring: Spring,
    visibilityMargin: CGFloat,
    now: CFTimeInterval
) -> (animate: Bool, motion: FocusSurfaceMotion?) {
    switch motion {
    case .smoothing:
        return (true, .smoothing)
    case let .settling(displacement, recordedAt):
        let residual = focusSettleResidualEstimate(
            displacement: displacement,
            elapsed: now - recordedAt,
            spring: spring
        )
        guard residual - trackedOffset > visibilityMargin else {
            return (false, nil)
        }
        return (true, .smoothing)
    case nil:
        return (false, nil)
    }
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
