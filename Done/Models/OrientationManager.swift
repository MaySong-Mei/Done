import SwiftUI
import UIKit
import Combine

/// The one landscape/portrait bit a `UIDeviceOrientation` sample carries, or
/// `nil` for the samples that carry none.
///
/// `.faceUp`, `.faceDown` and `.unknown` say nothing about which way the user
/// is holding the device, so they are dropped rather than coerced (Apple's
/// `isLandscape` reports `false` for all three, which would read as a portrait
/// sample). `.portraitUpsideDown` is portrait.
///
/// `@unknown default` maps to `nil` as well, and that is a real behaviour
/// difference from `king-of-rubbish-bin` rather than a refactor. King filtered
/// with `{ $0 != .unknown && $0 != .faceUp && $0 != .faceDown }`, which lets an
/// Apple-added case through to `update`, whose `default:` publishes it as
/// **portrait**; here it is dropped. Unreachable on today's SDK — the seven
/// cases above are exhaustive — and the safer of the two once it stops being
/// unreachable, but it belongs on the list of ways this file differs from king.
///
/// **This is the filter.** Not a tidy-up on the way to one — see "What
/// actually filters the noise" on `OrientationManager`. Hardware measurement
/// found the only sub-250 ms orientation churn on the `.faceUp` channel, which
/// means this function is what stops it: the `compactMap` in `init` drops those
/// samples before anything downstream sees them. Coercing them to `false`
/// would turn a phone set down on a table into a portrait sample.
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

/// Landscape/portrait as read from **gravity**
/// (`UIDevice.orientationDidChangeNotification`), published on arrival in both
/// directions.
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
/// # Why there is no dwell
///
/// gh#172 shipped a hysteresis filter here — an orientation had to hold
/// 0.25 s before it was published — and then removed it, because the premise
/// it was bought on was measured on hardware and is false.
///
/// The premise was that gravity fires spuriously: on small tilts, and on the
/// settling wobble at the end of a deliberate rotation. It was inherited
/// verbatim from an older comment and never checked. Everything built on it
/// was built on that.
///
/// **The measurement.** An `os_log` probe at the raw notification, inside the
/// `compactMap` in `init` below — the probe point the falsifier specified,
/// chosen because a dwell's own wake-up task re-entered `observe` and made one
/// rotation log twice, and because `compactMap` has already dropped the flat
/// samples further down. iPhone 15 Pro Max, iOS 26.6, 313.2 s, 36 raw
/// notifications, across deliberate rotations with 3 s holds, ~9 s of
/// sub-threshold tilting at 20–30°, and rotating while walking.
///
/// The samples themselves live in
/// `testHardwareProbeShowsNoLandscapeSampleShorterThanTheRemovedDwell`
/// (`OrientationDwellTests.swift`), as a fixture, so the arithmetic below is
/// re-derived by the suite rather than restated here and left to rot. The
/// conclusion: **the shortest-lived landscape sample in the whole run was
/// 0.788 s — `0.788/0.25 = 3.15×` the dwell, one division of two figures in
/// this file — and the dwell would have suppressed none of the ten landscape
/// samples.** It was spending a quarter second on every rotation to reject
/// something that never arrived.
///
/// **Sub-dwell churn does exist — the hypothesis was not crazy.** The probe
/// caught `faceUp → portrait` in 0.197 s and `portrait → faceUp` in 0.160 s,
/// both far inside 0.25 s, and during the tilt phase the device produced seven
/// `portrait`/`faceUp` samples in ~9 s — six alternations — and no landscape
/// value at all.
///
/// **But what makes that churn harmless is not the dwell.** It is:
///
/// 1. `orientationLandscapeSample` mapping the flat samples to `nil`, which the
///    `compactMap` drops before `observe` is ever called; and
/// 2. the `candidate != isLandscape` guard in `observe`, which makes the
///    repeated `portrait` either side of them a no-op.
///
/// Both survive this change. **Neither is the dwell.** Every measured event
/// that a reader might reach for the dwell to explain is already handled by one
/// of those two, one layer earlier and for free.
///
/// # What the dwell did fix — the standing counter-argument
///
/// One real defect goes back with it, and this paragraph exists so that whoever
/// next sees a rotation flash finds it here instead of rediscovering it.
///
/// **gh#172 round-3 QA (simulator, commanded transient; dwell builds
/// `c02fee9` and `ea3f605` against king `7b70001`)** measured a **150 ms
/// transient** orientation producing **0 motion frames** with the dwell in
/// place and **44 frames / 710 ms of full-screen flash** without it. Round 2's
/// QA measured **675 ms** for the same thing on its own rig; both readings are
/// recorded rather than averaged, because the 35 ms spread is the honest
/// uncertainty on the figure. That flash is user-visible and it is not
/// cosmetic. Removing the dwell restores it — *if such a transient ever
/// occurs.* The numbers are a fixture, not a comment —
/// `testTheRotationFlashCounterArgumentIsRecordedWithItsRig` — for the same
/// reason the probe is one: this is the figure a reader will act on.
///
/// **Note the rig, because it is the whole rebuttal.** Like every timing in
/// this slice's history except the probe above, it is simulator-derived; no
/// hardware has been in that loop. The transient was **commanded** from the
/// Simulator's `Device > Orientation`, not sensed — so the measurement
/// establishes what the app *renders* when a 150 ms transient arrives, and says
/// nothing whatever about whether gravity *emits* one. That is not a quibble
/// about rig quality: a commanded transient is an input the experimenter chose,
/// and the open question is precisely whether the sensor ever chooses it. Only
/// the probe can answer that, and it is the one measurement here that ran on a
/// device.
///
/// The hardware says it does not. The shortest landscape sample in 313.2 s was
/// **788 ms, 5.25× that 150 ms transient**, and the only sub-250 ms events in
/// the entire run were on the `.faceUp` channel, which cannot reach the filter
/// at all.
///
/// **The condition under which this reopens** is therefore specific, and it is
/// not "someone saw a flash": it is a raw-notification capture, on hardware, in
/// which two *filter-reaching* samples (L or P, not flat) contradict each other
/// inside ~250 ms. That is one `os_log` line in the `compactMap` below and the
/// fixture test to compare against. Reproduce that and the trade is live again
/// — and note it would then be worth re-deriving from scratch rather than
/// restoring, because the shipped dwell was asymmetric (0.25 s entering, 0
/// leaving) and cost the enter path ~250 ms against `king-of-rubbish-bin` on
/// every single rotation, which is what an anchor-free A/B put at D = 43.8 ms
/// on king against ~292–300 ms on the dwell builds.
///
/// # Consequences of the removal
///
/// **gh#178** — a half-typed focus note is destroyed when `focusActive` flips,
/// with no warning and nothing persisted — is unchanged as *damage* and
/// improved as *recovery*. Publishing on arrival in both directions is king's
/// behaviour exactly, so the post-teardown window in which focus takes time to
/// come back returns to king parity: the flat ~250 ms the dwell added to that
/// window is undone. Fixing gh#178 itself remains out of scope; it is
/// mentioned here because this file owned the wait that made it worse.
///
/// (A ratio is the wrong shape for that figure and this slice retracted one
/// twice. What the dwell added is a **difference** — the render and transition
/// offsets sit on both endpoints and cancel in a subtraction, not in a
/// quotient — so it is +250 ms regardless of the window it lands on. See
/// `6372c93`: "quote the +250 ms, never a ratio".)
///
/// **gh#174** — focus entered but the interface never rotates — is untouched.
/// Its title says cold launch; **the repro is broader.** QA reached it with a
/// rapid rotation pair, and reproduced it on `king-of-rubbish-bin` @ `7b70001`
/// at sample gaps ≤ 200 ms, with 300 ms recovering. Neither launch-specific nor
/// caused by anything here, and not fixed here.
///
/// **gh#171** loses something, and it is recorded here because nothing else
/// records it. Its symptom 2 — a spurious `.landscapeLeft` revoking a focus
/// dismissal already in flight — was an *entering* candidate, so the removed
/// dwell held it for the full 0.25 s. That dwell was **the only upstream
/// mitigation this repo ever claimed for symptom 2**, and it is now gone. That
/// is deliberate, for a reason stronger than scope: **the probe falsifies the
/// mechanism symptom 2 rests on.** gh#171 argues from a citation into *this
/// file* — the old `:11-18`, which said these notifications fire on slight
/// tilts — and defers the upstream fix to gh#172. The tilt phase was run to
/// test exactly that: ~9 s at 20–30°, seven samples, six alternations, and
/// **zero landscape values**. Gravity did not emit the sample symptom 2 needs.
/// The citation now points at text saying the opposite, and this paragraph is
/// the bridge; anyone reopening symptom 2 needs a raw-notification capture
/// first, on the terms above. The **animation-completion** fix gh#171 itself
/// recommends is untouched by any of this and remains the live proposal.
@MainActor
final class OrientationManager: ObservableObject {
    /// Whether the device is being held landscape.
    ///
    /// `private(set)`: `observe(_:)` is the only writer, and its change guard
    /// is the thing that keeps a repeated sample inert — an outside assignment
    /// would be able to publish one.
    ///
    /// Assigned only when the value actually changes, so an orientation
    /// notification that resolves to the same bit publishes nothing. Every
    /// assignment invalidates `DoneApp`, `ContentView` (the root view),
    /// `CalendarPageView` and `TodoStackDrawer` inside a 0.4 s animation
    /// transaction; suppressing the no-op ones is a correctness/hygiene fix,
    /// and it is half of why the measured `portrait`/`faceUp` churn is
    /// harmless. `king-of-rubbish-bin` assigns unconditionally and does fire
    /// those. The render cost of the redundant invalidations was never
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

    /// - Parameter observeNotifications: `false` skips both the live
    ///   subscription and device-notification generation, so a test can drive
    ///   `observe(_:)` by hand without a real device notification landing in
    ///   the middle of it and moving the published bit under the assertion.
    ///   (Unreachable on the simulator the suite runs on, where the real sensor
    ///   read is `.unknown` and the `compactMap` drops it — but the tests
    ///   should not depend on that being true forever.)
    ///
    ///   **The seam is not an excuse to leave the wiring untested, and for a
    ///   while it was one.** Every construction in `DoneTests` passed `false`,
    ///   so the two lines below — the generation call and the subscription —
    ///   had no coverage at all and only a manual pass verified them.
    ///   `OrientationDwellTests`' "The live subscriptions" section builds the
    ///   default init instead. Anything added here needs a test there.
    ///
    ///   There is no `deinit`, so every default construction leaks one
    ///   `beginGeneratingDeviceOrientationNotifications` reference count. That
    ///   is deliberate: production builds exactly one manager for the app's
    ///   lifetime (`DoneApp.swift:232`), and balancing it would mean touching
    ///   a `@MainActor` UIKit API from a nonisolated `deinit`. Only the
    ///   generation test puts the count back; the other default builds each
    ///   leak one. That test runs before them in the observed order, so its
    ///   drain never sees the leak — harmless because that test is the only
    ///   reader of the count, not because anything balances it.
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
    ///   sink itself all under test.
    ///
    ///   **It is a closure, and that is load-bearing. Do not make it a
    ///   value.** Every neighbouring seam in this repo injects one, so
    ///   `deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation`
    ///   is the obvious tidy-up to match the house shape, and it **kills the
    ///   feature outright**. Swift evaluates a default argument at the call
    ///   site, before `init` runs and therefore before
    ///   `beginGeneratingDeviceOrientationNotifications()` below; per
    ///   `UIDevice.h:44` the property "will return UIDeviceOrientationUnknown
    ///   unless device orientation notifications are being generated". So the
    ///   frozen read is guaranteed `.unknown`, `orientationLandscapeSample`
    ///   returns `nil`, and the `compactMap` drops **every** notification for
    ///   the life of the process — silently, the only symptom being landscape
    ///   focus never arriving. Pinned by
    ///   `testTheSensorIsReadOnEveryNotificationNotOnceAtConstruction`, the
    ///   only test that can tell a per-call read from a cached one; the other
    ///   live tests stub a *constant*, which answers identically either way.
    ///
    ///   Production never passes it: `DoneApp.swift:232` is the app's only
    ///   construction, verified by grep rather than by a test, because the
    ///   default's live-ness is unobservable on a simulator where the real
    ///   read is `.unknown` whenever it happens.
    ///
    ///   **Two standing warnings sit on that default expression** — "main
    ///   actor-isolated property 'orientation' / class property 'current' can
    ///   not be referenced from a `Sendable` closure". They are **errors in the
    ///   Swift 6 language mode**, and they are this slice's: `king-of-rubbish
    ///   -bin` reads `UIDevice.current.orientation` inline in its `compactMap`,
    ///   whose transform is not `@Sendable`, so king carries neither. Making
    ///   the closure `@Sendable` is what bought the injectable seam, and these
    ///   two warnings are its price — **+2 against king**, deliberately taken.
    ///
    ///   The suite already lives by that rule and says so:
    ///   `MutableOrientationStub` in `OrientationDwellTests` is `@MainActor`
    ///   precisely so it can cross into this closure, and its read goes through
    ///   `MainActor.assumeIsolated`. **The production default does not**, which
    ///   is the whole of the delta. Do not "fix" it by dropping `@Sendable` or
    ///   by making this a value — the paragraph above is why the value form
    ///   kills the feature — and do not fix it silently in the same commit as
    ///   anything else; adopting Swift 6 here is its own slice.
    ///
    ///   One consequence worth stating while the thread rules are in view:
    ///   `deviceOrientation()` is called inside the `compactMap`, i.e. **before**
    ///   `.receive(on: RunLoop.main)`, on whatever thread posted the
    ///   notification. UIKit posts this one on main, so in practice it is fine
    ///   — and identical to king, which reads the same property at the same
    ///   point. The asymmetry is only in what happens if that ever stops being
    ///   true: the test stub **traps** on an off-main post, while production
    ///   reads across the isolation boundary and silently races.
    init(
        observeNotifications: Bool = true,
        deviceOrientation: @escaping @Sendable () -> UIDeviceOrientation = { UIDevice.current.orientation }
    ) {
        guard observeNotifications else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationCancellable = NotificationCenter.default
            .publisher(for: UIDevice.orientationDidChangeNotification)
            // Called here, once per notification. A value parameter would be
            // read before generation is on — see `deviceOrientation` above.
            // This `compactMap` is also the filter: it is what drops the flat
            // samples the hardware probe caught churning inside 200 ms.
            .compactMap { _ in orientationLandscapeSample(deviceOrientation()) }
            .receive(on: RunLoop.main)
            .sink { [weak self] landscape in
                self?.observe(landscape)
            }
    }

    /// Publish a filtered sample, if it says anything new.
    ///
    /// The guard is the whole rule. It is not an optimisation: a repeated
    /// `portrait` between two flat samples is exactly what the hardware probe
    /// measured, and this is what makes it inert. Everything upstream of here
    /// has already happened — the flat samples were dropped by the `compactMap`
    /// in `init`, so a `candidate` reaching this line is always a real
    /// landscape/portrait reading.
    ///
    /// Called from the subscription, and directly by tests.
    func observe(_ candidate: Bool) {
        guard candidate != isLandscape else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            isLandscape = candidate
            // Intentionally NOT clearing `manualFocusActive` here.
            // Manual entry persists until the user explicitly dismisses
            // (swipe-down on the focus overlay or tapping the focus
            // button again). The auto-on-rotation path is independent:
            // it's gated on `isLandscape && landscapeFocusModeEnabled`
            // in the focus overlay's predicate, so rotating to portrait
            // collapses the auto path naturally. The reason once recorded
            // for not auto-clearing — that it "made manual focus die when
            // a user briefly tilted the device" — presupposed the spurious
            // -sample premise that the hardware probe above falsified, and is
            // withdrawn. The decoupling stands on its own: manual entry is
            // the user's and a rotation is not a dismissal of it.
        }
    }
}
