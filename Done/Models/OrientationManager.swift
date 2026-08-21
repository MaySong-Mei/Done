import SwiftUI
import UIKit
import Combine
import QuartzCore

/// How long a device orientation must hold before `OrientationManager`
/// publishes it — **one value per direction**. See `orientationDwellDecision`
/// for the rule that consumes it and `orientationDwellPolicy` for the shipped
/// numbers and why they differ.
struct OrientationDwellPolicy: Equatable {
    /// Dwell for a landscape candidate, i.e. for ENTERING the landscape
    /// state. This is the direction the filter exists for.
    var enter: CFTimeInterval
    /// Dwell for a portrait candidate, i.e. for LEAVING it. `<= 0` publishes
    /// on arrival.
    var exit: CFTimeInterval

    /// The dwell that applies to `candidate`.
    ///
    /// `orientationDwellDecision` only reaches this past its agreement guard,
    /// where `candidate != published` holds; the state is one bit, so
    /// `candidate == true` is exactly "entering landscape" and `false` is
    /// exactly "leaving it". Direction is resolved here, in the pure layer —
    /// the shell hands over a policy and never branches on direction itself.
    func dwell(for candidate: Bool) -> CFTimeInterval {
        candidate ? enter : exit
    }
}

/// The shipped policy: **0.25 s entering landscape, 0 leaving it.**
///
/// **Why asymmetric.** Round 1 of gh#172 dwelled 0.25 s in both directions.
/// Device QA measured that (A/B against `king-of-rubbish-bin` @ `7b70001`,
/// same rig, build provenance asserted per install) at **+390–400 ms on the
/// exit path**: 642 / 652 / 668 / 676 ms from rotation start to the calendar
/// being fully visible, against king's 253 / 273 ms. The mechanism is
/// serialisation, not the dwell's own duration. The dwell runs *concurrently*
/// with the ~300 ms system rotation animation (measured 295–328 ms) and lands
/// just **after** it, so the 0.4 s focus-overlay fade — which on king overlaps
/// or precedes the rotation — is pushed entirely behind it. Matched frames at
/// ~45% through the rotation: king carries the calendar, round 1 carries a
/// fully opaque focus overlay that only begins fading 0–6 ms after the
/// rotation ends. QA's reading: not a hang, but "the app didn't notice I
/// rotated".
///
/// The exit direction is also the direction hysteresis buys least. Leaving
/// landscape is already protected downstream — the publish closes
/// `FocusOrientationGate.allowsLandscape` and forces portrait — and a
/// spurious portrait sample that did get through self-corrects, because the
/// device is still physically landscape and the next sample re-enters through
/// the full 0.25 s window. (Self-corrects, but not for free: that re-entry is
/// the wrong-state window measured below.) gh#171's reported shape (a
/// spurious `.landscapeLeft` arriving while an exit is in flight) is an
/// *entering* candidate, so it keeps the full dwell. So exit pays the most
/// and gains the least: exit returns to publish-on-arrival, which is king's
/// behaviour on that path exactly.
///
/// **The asymmetry did what it was predicted to do.** Same rig, re-measured
/// against king with the anchor moved onto the first frame of the rotation
/// response, metric = rotation start → calendar fully visible: king 295.9 ms
/// mean (296.7 / 291.7 / 295.0 / 300.0), this policy **301.7 ms** (291.7 /
/// 296.7 / 316.6) — **Δ +5.8 ms**, inside the ±12 ms run-to-run spread. The
/// same rig re-measured round 1 at 590.0 ms, reproducing its own +294 ms
/// regression, which is what makes the null result on this build meaningful
/// rather than an instrument that cannot see anything. Fade start relative to
/// the anchor: king +246.7…261.7 ms, this build +250.0…268.3 ms, round 1
/// +345.0…356.7 ms — round 1's fade began *after* the rotation ended, this
/// one begins at king's moment. **The enter path is deliberately unchanged
/// and still costs ~+261 ms over king** (first visible response: king
/// 175.6 ms, this build 436.7 ms); that is the dwell, and it is the price the
/// unverified premise above is buying.
///
/// **The accepted cost of `exit: 0`, now measured.** A spurious portrait
/// sample while genuinely landscape is not filtered: it exits focus at once,
/// and because the device is still physically landscape, the correcting
/// landscape sample must then serve the full `enter` window before focus
/// comes back. For that whole interval the app shows the *wrong* state — the
/// calendar, not focus.
///
/// An earlier version of this comment claimed the hole was "no worse than
/// king". **That was wrong, and QA measured it.** Same rig, identical
/// commanded 2-sample wobble out of landscape, metric = how long the
/// calendar is on screen before focus returns:
///
///     king `7b70001`      102 ms
///     round 1 `830f4ff`   270 ms
///     round 2 (shipped)   327 ms   ← the longest of the three, +225 ms
///
/// Review predicted this as "the wrong-state window becomes Δ + 0.25 s"
/// before it was measured; 102 + 250 = 352 against 327 observed, which is
/// agreement at this instrument's resolution. **This slice makes the
/// wrong-state window roughly 3× king's.** It is the first thing to
/// reconsider if the premise below is ever confirmed on the exit direction
/// specifically — and note that filtering the exit is what round 1 did, and
/// round 1 cost +294 ms on the exit path.
///
/// **Why that is not merely cosmetic — gh#178.** A half-typed focus note is
/// destroyed when `focusActive` flips: no warning, nothing persisted. That
/// is **not a regression from this slice** — king loses the draft
/// identically, 5/5 across every gap QA tested — and fixing it is out of
/// scope here. What this slice changes is the size of the window in which a
/// user is typing into a view that is about to be torn down, and it widens
/// that window by about 3×. Widening it silently is not acceptable, so it is
/// recorded here, at the policy that causes it. See gh#178.
///
/// One escape hatch review hoped for was **not observed**. The idea: if the
/// correcting sample lands inside SwiftUI's 0.4 s removal transition, the
/// transition reverses and the `@State` draft survives. QA could not reach
/// that on this rig in any range available — commanded gaps of 16–300 ms all
/// arrived as effective device-sample gaps of ~300–370 ms, which *is* inside
/// 400 ms, and king still did not preserve the draft. Treat transition
/// reversal as unobserved, not as a fallback.
///
/// **What bounds `enter`.** The ~300 ms system rotation animation, which the
/// dwell runs concurrently with. An earlier version of this comment claimed
/// the bound was this manager's own 0.4 s enter animation and `ContentView`'s
/// 0.6 s day-offset unfreeze. That argument is wrong and was called out by QA
/// and review independently: the 0.4 s animation *begins at* the publish and
/// the 600 ms unfreeze `Task` is *created by* it, so both are strictly
/// downstream — sequential, not racing — and **no value of the dwell can make
/// either bind.** The test that encoded that rationalisation as a constraint
/// has been deleted; with no mechanism connecting the quantities it would have
/// passed forever and proved nothing.
///
/// `enter: 0.25` remains a judgement call, not a measurement — see "Why a
/// dwell" on `OrientationManager` for why the noise it filters is itself
/// unverified. It costs the enter path ~250 ms against king by construction.
/// If that is judged too expensive, `enter` is the free parameter and 0.15 s
/// is the next stop, but lowering it trades away transient rejection and there
/// is no measurement of transient duration to price that trade — gh#172.
let orientationDwellPolicy = OrientationDwellPolicy(enter: 0.25, exit: 0)

/// An orientation that disagrees with the published one and is waiting out
/// the dwell, plus the `CACurrentMediaTime()` at which it was FIRST seen.
struct OrientationDwellCandidate: Equatable {
    var landscape: Bool
    var since: CFTimeInterval
}

/// The dwell filter's verdict for a single observation.
enum OrientationDwellDecision: Equatable {
    /// The observation agrees with what subscribers already see. Publish
    /// nothing, and drop any candidate that was waiting. This case is both
    /// the duplicate suppression and the transient kill — a tilt that
    /// reverts inside the dwell window lands here and never reaches a
    /// subscriber.
    case idle
    /// `candidate` disagrees with the published value but has not held long
    /// enough yet. Keep it and re-examine it in `after` seconds.
    case hold(OrientationDwellCandidate, after: CFTimeInterval)
    /// The dwell is satisfied — publish this value now.
    case publish(Bool)
}

/// The one landscape/portrait bit a `UIDeviceOrientation` sample carries, or
/// `nil` for the samples that carry none.
///
/// `.faceUp`, `.faceDown` and `.unknown` say nothing about which way the user
/// is holding the device, so they are dropped rather than coerced (Apple's
/// `isLandscape` reports `false` for all three, which would read as a portrait
/// sample). `.portraitUpsideDown` is portrait.
///
/// Extracted so the mapping is reachable from a test at all — the production
/// path has exactly one call site, the subscription in `OrientationManager.init`.
/// Delivery *through* that subscription is covered too, but only by stubbing
/// the sensor read: `UIDevice.current.orientation` is `.unknown` forever on
/// the simulator the suite runs on and cannot be set. See the
/// `deviceOrientation` parameter on `OrientationManager.init`.
func orientationLandscapeSample(_ orientation: UIDeviceOrientation) -> Bool? {
    switch orientation {
    case .portrait, .portraitUpsideDown:
        return false
    case .landscapeLeft, .landscapeRight:
        return true
    case .unknown, .faceUp, .faceDown:
        return nil
    @unknown default:
        return nil
    }
}

/// Decide what a freshly observed orientation should do to the published
/// state, given whatever candidate was already standing.
///
/// Pure / testable. No UI side effects and no clock read of its own: `now`
/// and `pending.since` are `CFTimeInterval`s from `CACurrentMediaTime()`,
/// which is monotonic. A wall clock (`Date()`) would let a timezone change,
/// an NTP step, or the user editing the system clock distort the window.
///
/// - Parameters:
///   - published: the value subscribers currently see.
///   - pending: the candidate already waiting, or `nil` if none is.
///   - candidate: the orientation just observed.
///   - now: the observation's timestamp.
///   - policy: the per-direction dwell. A direction whose dwell is `<= 0`
///     publishes at once.
///
/// - Precondition (a **shell invariant**, not enforced or checked here):
///   `pending`, when non-`nil`, disagrees with `published`.
///   `OrientationManager` maintains it — it stores only the candidate this
///   function hands back and clears it on `.idle` and `.publish` — but this
///   function is `internal` and independently callable, and it does not
///   verify the claim. Under the invariant, a candidate that differs from
///   `pending` must equal `published`, so it returns `.idle` at the guard and
///   drops `pending` outright; that is *why* "a different candidate discards
///   the pending one" holds in production, and it is a property of the caller
///   rather than of this function. A direct caller that breaks it —
///   `published: true, pending: (true, t), candidate: false` — gets
///   `.hold(false, since: now)`, not `.idle`.
///
/// Repeated observations of the SAME candidate do not restart its clock:
/// `pending.since` is carried through unchanged, so a stream of notifications
/// during one continuous rotation cannot push the deadline forward
/// indefinitely.
///
/// **Rapid alternation has no ceiling, deliberately.** Advancing needs the
/// full dwell uninterrupted and any single contrary sample resets the
/// candidate to nothing, so an alternating stream can starve the publish for
/// as long as it lasts. That is bounded in practice rather than in code,
/// because `UIDevice.orientationDidChangeNotification` is edge-triggered:
/// sustaining alternation requires the user to keep physically rotating, and
/// the instant they stop the stream stops, the last candidate runs its window
/// out on the wake-up task, and it publishes once. A ceiling ("commit after
/// 2× dwell of majority disagreement") was considered and rejected: it would
/// fire *during* precisely the burst this filter exists to swallow,
/// reintroducing the flicker king shows. Pinned by
/// `testAlternatingStreamStarvesThePublishUntilTheStreamStops` — as a
/// property of this function, which is all a test can pin.
///
/// **That the swallowing is a real-world benefit is unverified** and the
/// evidence once cited for it has been withdrawn; see "The alternation
/// benefit is unverified" on `OrientationManager`. The argument above is
/// structural and rests only on the stream being edge-triggered, which is
/// documented behaviour. It says what this filter *would* do to a dense
/// burst — not that anything produces one.
///
/// The swallowing is also asymmetric like everything else here, and the
/// asymmetry is the expensive half: a burst that begins while already
/// landscape publishes one immediate exit (`exit: 0`) and only then swallows
/// the rest, so the app sits in the wrong state for `enter` seconds. That
/// cost is measured — see `orientationDwellPolicy`.
func orientationDwellDecision(
    published: Bool,
    pending: OrientationDwellCandidate?,
    candidate: Bool,
    now: CFTimeInterval,
    policy: OrientationDwellPolicy
) -> OrientationDwellDecision {
    guard candidate != published else { return .idle }
    let dwell = policy.dwell(for: candidate)
    let since = (pending?.landscape == candidate) ? (pending?.since ?? now) : now
    let elapsed = max(0, now - since)
    guard elapsed < dwell else { return .publish(candidate) }
    return .hold(
        OrientationDwellCandidate(landscape: candidate, since: since),
        after: dwell - elapsed
    )
}

/// Landscape/portrait as read from **gravity**
/// (`UIDevice.orientationDidChangeNotification`), filtered by
/// `orientationDwellPolicy` so an orientation is published only once it has
/// held long enough in the direction it is heading.
///
/// **Why gravity and not `UIWindowScene.interfaceOrientation`.** The app is
/// portrait-locked except while focus mode is active: `AppDelegate` answers
/// `focusOrientationMask(allowsLandscape:)`, whose closed form is plain
/// `.portrait` — landscape is absent from the mask, not merely deprioritised
/// — and the gate's only writer is `syncOrientationLock(focusActive:)`
/// (`DoneApp.swift:305-312`). Note the full disjunction:
///
///     focusActive == (isLandscape && landscapeFocusModeEnabled) || manualFocusActive
///
/// Sourcing `isLandscape` from the interface orientation closes the FIRST
/// disjunct on itself — the lock suppresses the very signal that is supposed
/// to open the lock, the fixed point from a portrait start is "stay portrait",
/// and landscape auto-focus becomes unreachable.
///
/// `manualFocusActive` is the one term that breaks that recurrence, and it is
/// stated here on purpose: a reader who finds it will otherwise conclude this
/// comment is wrong and make the swap anyway. A manual focus entry opens the
/// gate without consulting `isLandscape`, so *after* a manual tap the
/// interface can rotate and an `interfaceOrientation` source would appear to
/// work. That is the only bootstrap that survives the swap — from a cold
/// portrait start with no manual tap, auto-rotation into focus would be dead.
/// Gravity is the only reading that survives the lock unconditionally, so it
/// is load-bearing as the bootstrap. It is also the semantic the user was
/// promised — the setting reads "Auto-enter focus mode on rotation". Do not
/// "fix" this to `interfaceOrientation`.
///
/// **Why a dwell.** *The noise this filters is hypothesised, not measured.*
/// The claim that gravity fires on small tilts and on the settling wobble at
/// the end of a deliberate rotation was inherited verbatim from the old
/// `manualFocusActive` comment — the same comment whose conclusion this file
/// discards as untrustworthy. Promoting its unverified assertion to the
/// foundation of a new mechanism is exactly the move that needed flagging, so:
/// it has never been checked against hardware.
///
/// What QA could check points the other way. A standalone probe app
/// subscribed to the raw stream and logged **6 deliberate rotations →
/// exactly 6 notifications**: no duplicates, no settling wobble, no spurious
/// flips, and re-setting an orientation the device already holds emits
/// nothing at all. Read that last observation carefully — "re-set an
/// orientation the device already holds" is only expressible where
/// orientation is a discrete, externally-set value, i.e. on a **simulator**.
/// And a simulator cannot settle this premise even in principle: there is no
/// accelerometer, so neither a sub-threshold tilt nor a rotation while
/// walking can be expressed at all. The probe therefore establishes that the
/// stream is clean in the one environment where the noise is impossible by
/// construction. That is weak evidence, and it is the only evidence there is.
///
/// **What would settle it:** one `os_log` line at the top of `observe(_:at:)`,
/// on real hardware, capturing (a) a deliberate rotation, (b) a sub-threshold
/// tilt that should not flip, and (c) a rotation while walking. **If (a)
/// yields exactly one event on hardware — which is what the simulator probe
/// already suggests — then this filter is spending `enter` seconds of
/// latency on every rotation, plus the wrong-state window measured on
/// `orientationDwellPolicy`, to suppress a defect that does not occur, and
/// the correct response is to delete it rather than tune it.** Until that
/// trace exists, treat the premise as open — gh#172.
///
/// **The alternation benefit is unverified.** An earlier version of this
/// comment cited a synthesised L/P/L/P/L burst over 480 ms producing one
/// clean entry here against three flickering transitions on king, and
/// presented it as the measured payoff — "the conditional: where noise
/// exists, this filter demonstrably suppresses it". That claim is withdrawn,
/// for two independent reasons:
///
/// - **The evidence is gone.** It was captured through a key-delivery path
///   into the simulator that no longer functions. It cannot be re-run or
///   re-checked, and nothing that survives corroborates it.
/// - **The input could not be reproduced.** QA could not deliver sub-dwell
///   alternation to the app at all on the from-landscape path: commanded
///   sample gaps of 16 ms through 300 ms all arrived as effective
///   device-sample gaps of **~300–370 ms**, never inside the 0.25 s window
///   this filter is supposed to swallow. Bursts commanded from *portrait*
///   showed zero visible change and one clean entry — but samples that far
///   apart produce the same shape on an unfiltered build, so that
///   discriminates nothing.
///
/// King's own numbers make the withdrawn claim doubtful rather than merely
/// unsupported: a commanded 4-sample burst at 110 ms and at 190 ms spacing
/// produced **one** transition on king, while 390 ms and 490 ms spacing
/// produced **all four**. Whatever that harness delivers, it is not the dense
/// stream the "three flickering transitions" figure describes.
///
/// **What would settle this one:** a rig that can deliver device-orientation
/// samples at sub-dwell spacing on the from-landscape path — or hardware,
/// where the spacing is whatever the user's hands produce.
///
/// **The first reading is not exempt.** The dwell applies uniformly,
/// including when the app launches already rotated. *At launch specifically*
/// nothing is rendered wrongly in the meantime: the seed value `false` agrees
/// with what the portrait lock is already showing, and before the first
/// publish the gate has never been opened, so UIKit cannot rotate the
/// interface. That argument is scoped to launch and does **not** generalise.
/// `manualFocusActive` is a second, independent opener
/// (`CalendarPageView.swift:2740-2742`, the focus button, reachable in
/// portrait): tap focus in portrait and then rotate, and UIKit rotates the
/// interface immediately without consulting this manager — the timeline
/// relayouts with `calendarState.isDayOffsetFrozen` still `false`, and only
/// `enter` seconds later does `ContentView` publish and capture
/// `savedDayOffsetBeforeLandscape`, i.e. **after** the relayout.
///
/// What keeps that safe is not the gate; it is that the relayout cannot move
/// `selectedDayOffset`. The only scroll-derived write of it is guarded by
/// `calendarShouldAdoptScrollDrivenDayOffset`, which requires an active user
/// interaction (scroll drag, horizontal edge drag, or auto-scroll), and the
/// focus overlay covers the timeline, so none can be in flight. Review could
/// find no path where the late capture corrupts the offset and QA measured the
/// restored day identical to king. **That is the real dependency: if a future
/// change ever lets a layout pass adopt a scroll-driven offset without an
/// active user interaction, this becomes a live bug.**
///
/// A launch-time accelerometer sample (phone coming out of a pocket, lifted
/// off a table) is also plausibly the least trustworthy one there is, so
/// exempting it would exempt the noisiest reading — but that too rests on the
/// unverified premise above. The cost is that a genuinely-landscape launch
/// enters focus `enter` seconds in.
///
/// Separately, gh#174 records the stuck shape where focus is entered but the
/// interface never rotates. **Its title says cold launch; the repro is
/// broader.** QA also reached it with a rapid rotation pair, and reproduced
/// it on `king-of-rubbish-bin` @ `7b70001` at sample gaps ≤ 200 ms (300 ms
/// recovers). So it is neither launch-specific nor caused by this slice —
/// present on king and here alike — and this slice does not fix it.
@MainActor
final class OrientationManager: ObservableObject {
    /// Whether the device is being *held* landscape, after the dwell.
    /// `private(set)`: the dwell filter is the only writer, and an outside
    /// assignment would desynchronise it from `pending`.
    ///
    /// Assigned only when the value actually changes, so an orientation
    /// notification that resolves to the same bit publishes nothing. Every
    /// assignment invalidates `DoneApp`, `ContentView` (the root view),
    /// `CalendarPageView` and `TodoStackDrawer` inside a 0.4 s animation
    /// transaction; suppressing the no-op ones is a correctness/hygiene
    /// fix. The render cost of the redundant invalidations was never
    /// measured, so this is not claimed as a performance win.
    @Published private(set) var isLandscape = false

    /// User-driven focus state, decoupled from device orientation. Tapping
    /// the focus button enters focus mode in whatever orientation the
    /// device is currently in. Persists until an explicit dismiss
    /// (swipe-down on the focus overlay or another tap on the focus
    /// button) — rotation alone does not clear it. Orientation lock side
    /// effects live with the focus presentation logic in DoneApp.
    @Published var manualFocusActive = false

    private var orientationCancellable: AnyCancellable?
    private var foregroundCancellable: AnyCancellable?

    /// The candidate waiting out the dwell. `nil` when the device agrees
    /// with `isLandscape`. Written only from `orientationDwellDecision`'s
    /// verdict, never computed here — the carry-through rule that stops the
    /// window re-arming lives in the pure function.
    private var pending: OrientationDwellCandidate?

    /// The pending candidate's wake-up. **Not a nudge — it is the sole
    /// hold→publish trigger in the steady state.**
    /// `UIDevice.orientationDidChangeNotification` is edge-triggered: once
    /// the user stops rotating, no further notification arrives. So an
    /// ordinary rotation is exactly one notification → `.hold` → *nothing* →
    /// this task fires → `.publish`. **There is no state that escapes
    /// `.hold` without it.** Never make re-arming conditional (e.g. "the app
    /// is inactive, the next notification will catch it") — there is no next
    /// notification, and the feature would silently stop working.
    ///
    /// Its *timing precision*, separately, does not matter, and that part is
    /// verified: the deadline lives in `pending.since`, so a task that fires
    /// early or late merely re-runs the decision and re-arms. The clock
    /// mismatch is benign in direction — `Task.sleep` measures on the
    /// continuous clock, which advances while the device sleeps, whereas
    /// `CACurrentMediaTime()` does not, so the task can only fire EARLY
    /// relative to the stamps, never late. The dwell can therefore never fail
    /// to expire; at worst it needs one extra round trip. See
    /// `restampPendingForResume(at:)` for the resume case that direction
    /// creates.
    private var dwellTask: Task<Void, Never>?

    /// - Parameter observeNotifications: `false` skips both live
    ///   subscriptions and device-notification generation. Shell tests drive
    ///   `observe(_:at:)` by hand with an injected clock; with the real stream
    ///   connected, a device notification landing mid-test would call
    ///   `observe` with the real `CACurrentMediaTime()` against an injected
    ///   `at: 1_000` and flake the assertion. That was merely latent while
    ///   every such test was fully synchronous — the moment one `await`s, it
    ///   is not.
    ///
    ///   **The seam is not an excuse to leave the wiring untested, and for a
    ///   while it was one.** Every construction in `DoneTests` passed
    ///   `false`, so the three lines below — the generation call and both
    ///   subscriptions — had no coverage at all and only a manual device pass
    ///   verified them. `OrientationDwellTests`' "The live subscriptions"
    ///   section now builds the default init instead, and handles the hazard
    ///   by keeping every injected stamp within milliseconds of the real
    ///   clock and never suspending. Anything added here needs a test there.
    ///
    /// - Parameter deviceOrientation: the sensor read, and the one part of
    ///   the pipeline below a test cannot exercise. On the simulator the test
    ///   suite runs on, `UIDevice.current.orientation` is `.unknown`
    ///   (rawValue 0) permanently — the app is portrait-locked, there is no
    ///   accelerometer to move it, and assigning it by KVC is ignored — so a
    ///   real read maps to `nil`, the `compactMap` correctly drops it, and
    ///   delivery leaves no trace to assert on. Injecting *only* this read
    ///   leaves the notification name, `NotificationCenter.default`,
    ///   `orientationLandscapeSample`, the hop to the main run loop and the
    ///   sink itself all under test. Production never passes it.
    init(
        observeNotifications: Bool = true,
        deviceOrientation: @escaping @Sendable () -> UIDeviceOrientation = { UIDevice.current.orientation }
    ) {
        guard observeNotifications else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationCancellable = NotificationCenter.default
            .publisher(for: UIDevice.orientationDidChangeNotification)
            .compactMap { _ in orientationLandscapeSample(deviceOrientation()) }
            .receive(on: RunLoop.main)
            .sink { [weak self] landscape in
                self?.observe(landscape)
            }
        foregroundCancellable = NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.restampPendingForResume()
            }
    }

    /// The impure shell around `orientationDwellDecision`: it supplies the
    /// clock, keeps `pending`, and owns the timer. All of the judgement —
    /// including which direction gets which dwell — lives in the pure
    /// function and its policy.
    ///
    /// `at:` defaults to the monotonic clock and is only passed explicitly
    /// by tests, so the shell's wiring can be driven without waiting on
    /// real time.
    func observe(_ candidate: Bool, at now: CFTimeInterval = CACurrentMediaTime()) {
        let decision = orientationDwellDecision(
            published: isLandscape,
            pending: pending,
            candidate: candidate,
            now: now,
            policy: orientationDwellPolicy
        )
        switch decision {
        case .idle:
            // Either a duplicate, or a transient that reverted before it
            // earned the right to publish. Either way: nothing goes out.
            pending = nil
            cancelDwellTask()
        case let .hold(next, after):
            pending = next
            armDwellTask(after: after)
        case let .publish(landscape):
            pending = nil
            cancelDwellTask()
            withAnimation(.easeInOut(duration: 0.4)) {
                isLandscape = landscape
                // Intentionally NOT clearing `manualFocusActive` here.
                // Manual entry persists until the user explicitly dismisses
                // (swipe-down on the focus overlay or tapping the focus
                // button again). The auto-on-rotation path is independent:
                // it's gated on `isLandscape && landscapeFocusModeEnabled`
                // in the focus overlay's predicate, so rotating to portrait
                // collapses the auto path naturally. Auto-clearing here
                // re-coupled the two paths and made manual focus die when a
                // user briefly tilted the device.
            }
        }
    }

    /// `willEnterForeground`: give whatever candidate was waiting a **fresh
    /// full window**, and re-arm. Takes no device sample.
    ///
    /// The window was stamped against `CACurrentMediaTime()`, which stops
    /// advancing while the device sleeps, while `dwellTask`'s `Task.sleep`
    /// runs on the continuous clock, which does not. So across a sleep the
    /// task fires and re-arms against an essentially unchanged media clock,
    /// and the app resumes with a candidate still standing whose stamp may be
    /// arbitrarily old and whose underlying device state may be hours stale.
    /// Re-stamping costs a genuinely-pending rotation one more window and
    /// removes the stale publish.
    ///
    /// Two alternatives were rejected:
    ///
    /// - *Re-read `UIDevice.current.orientation` on resume.* The device is
    ///   very often `.faceUp`/`.faceDown` on a table when the app comes back,
    ///   which carries no landscape/portrait bit at all
    ///   (`orientationLandscapeSample` returns `nil`), and it is the least
    ///   trustworthy sample there is for the same reason a launch sample is.
    /// - *Clear `pending` on resume.* Holed: if the device is STILL in the
    ///   pending orientation, UIKit posts nothing on resume — its
    ///   last-reported value already matches — so clearing would lose a
    ///   genuine rotation permanently, with no notification left to recover
    ///   it. The edge-triggered stream is what makes the naive variant unsafe.
    ///
    /// `at:` is injected by tests only.
    func restampPendingForResume(at now: CFTimeInterval = CACurrentMediaTime()) {
        guard let waiting = pending else { return }
        let restamped = OrientationDwellCandidate(landscape: waiting.landscape, since: now)
        pending = restamped
        armDwellTask(after: orientationDwellPolicy.dwell(for: restamped.landscape))
    }

    private func armDwellTask(after: CFTimeInterval) {
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, after) * 1_000_000_000))
            guard !Task.isCancelled, let self, let pending = self.pending else { return }
            self.observe(pending.landscape)
        }
    }

    private func cancelDwellTask() {
        dwellTask?.cancel()
        dwellTask = nil
    }
}
