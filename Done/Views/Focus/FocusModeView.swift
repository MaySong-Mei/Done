import SwiftUI

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
    /// `startLocation` of the gesture `isTrackingDrag` belongs to, `nil`
    /// between gestures. It is what tells a fresh touch from a continuing
    /// one, because `onEnded` is not delivered when the system cancels a
    /// gesture and both the latch and the offset can survive into the
    /// next touch. See `beginGestureIfNew`.
    @State private var latchedGestureStart: CGPoint?
    /// When the surface is next expected to be visually at rest, `nil`
    /// while it has never moved. Read — not written — by every tracked
    /// update, to decide whether following the finger may be an
    /// unanimated write. See `trackSurface`.
    @State private var surfaceSettlesAt: Date?
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
    /// How long after a settle starts the surface is still visibly
    /// moving, and therefore how long a tracked write has to go through a
    /// spring instead of snapping. `settleSpring.settlingDuration` is
    /// 0.757s, but that measures when the maths is at rest rather than
    /// when the eye is: evaluated over a 300pt displacement the spring is
    /// within 3pt of home by 0.25s and its overshoot never exceeds 4.5pt.
    /// Past this window an unanimated write costs a jump too small to
    /// see; inside it, one costs the 148pt single-frame teleport this
    /// window exists to remove.
    private let surfaceSettleWindow: TimeInterval = 0.3
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
                            guard pendingProposalTemplate == nil else {
                                dragOffsetY = 0
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
    /// Inside the settle window the write goes through an interpolating
    /// spring, which is additive: it adds this update's travel to the
    /// motion already in flight rather than replacing it, so the surface
    /// converges on the finger instead of teleporting to it. Each such
    /// write re-arms the window, so a gesture that begins inside it stays
    /// smoothed for its whole length — going rigid partway would only
    /// move the jump to the frame it happened on. The cost is a tracking
    /// lag of order 0.1s while the spring is chasing, which decays to
    /// nothing the moment the finger slows.
    private func trackSurface(to offset: CGFloat) {
        let now = Date()
        guard focusDragNeedsAnimatedHandoff(
            surfaceSettlesAt: surfaceSettlesAt,
            now: now
        ) else {
            dragOffsetY = offset
            return
        }
        withAnimation(.interpolatingSpring(settleSpring)) {
            dragOffsetY = offset
        }
        surfaceSettlesAt = now.addingTimeInterval(surfaceSettleWindow)
    }

    /// Spring the surface back to rest, and arm the settle window so a
    /// drag arriving while it is still moving hands off through
    /// `trackSurface` instead of snapping.
    private func settleSurfaceHome(initialVelocity: Double = 0) {
        withAnimation(.interpolatingSpring(settleSpring, initialVelocity: initialVelocity)) {
            dragOffsetY = 0
        }
        surfaceSettlesAt = Date().addingTimeInterval(surfaceSettleWindow)
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

/// Whether a tracked write has to be handed off through a spring rather
/// than written bare.
///
/// The surface's model value and its presented value are different things
/// while an animation is in flight, and an unanimated write to a value
/// with an animation on it removes the animation and jumps to the new
/// value — which is a teleport of exactly the gap between the two. Inside
/// the settle window, assume there is a gap.
///
/// Pure / testable. No UI side effects.
func focusDragNeedsAnimatedHandoff(surfaceSettlesAt: Date?, now: Date) -> Bool {
    guard let settlesAt = surfaceSettlesAt else { return false }
    return now < settlesAt
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
