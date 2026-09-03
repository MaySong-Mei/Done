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

/// Seam over `UIDevice`'s reference-counted
/// `begin/endGeneratingDeviceOrientationNotifications` pair (gh#219).
///
/// Exists so tests can count begin/end transitions on an object they
/// construct instead of mutating the process-global reference count on the
/// real `UIDevice` — which the test host's own app shares, and which reads
/// back only as a single `isGenerating…` bit, not as a pairing.
@MainActor
protocol OrientationNotificationGenerating {
    func beginGeneratingOrientationNotifications()
    func endGeneratingOrientationNotifications()
}

/// The production generator: the real `UIDevice`. Default for every
/// `OrientationManager` construction that does not inject a counter.
struct DeviceOrientationNotificationGenerator: OrientationNotificationGenerating {
    /// `nonisolated` because the type inherits `@MainActor` from the
    /// protocol conformance, and a default-argument expression —
    /// `OrientationManager.init`'s — is evaluated in a nonisolated context.
    /// The struct is empty; only the two methods below touch UIKit.
    nonisolated init() {}

    func beginGeneratingOrientationNotifications() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    func endGeneratingOrientationNotifications() {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
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
/// (`DoneApp.swift:778-779`). Note the full disjunction, which `DoneApp`
/// spells across two computed properties (`autoFocusTrigger` at `:770`,
/// `focusActive` at `:774`) rather than one expression:
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
/// **A third rig has now measured all three builds, and the cost that comes
/// back is king's.** Same commanded 150 ms transient, single stimulus so no
/// anchor was needed, motion counted over the whole clip — its own estimator,
/// so these frame counts are comparable within this rig and not against round
/// 3's. King `7b70001`: **46 frames, 695.0 ms** median (n=5; 683.3, 686.7,
/// 695.0, 703.3, 735.0). `c7d3255`: **45.5 frames, 716.6 ms** (n=6; 705.0,
/// 706.7, 713.3, 720.0, 740.0, 775.0). The dwell `6372c93`: **0 frames,
/// 0.0 ms**, 3/3.
///
/// Two things land there. **King reproduces the recorded flash** — 46 frames /
/// 695.0 ms against the 44 / 710 above, with 695.0 sitting inside the two-rig
/// band the fixture already carries (675–710 ms), so nothing in that test
/// moves. Until this round the 44 / 710 had no rig behind it but the one that
/// produced it. And **`c7d3255` is +21.6 ms and −0.5 frames against king,
/// inside king's own per-run spread of 683.3–735.0 ms** — so the restored
/// flash is *king's* flash and not something worse. That closes the one open
/// worry about removing the dwell: the cost that comes back is the cost that
/// was always there.
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
/// on king against ~292–300 ms on the dwell builds. Read that as one rig's
/// medians: the 0.1 ms is transcription, not resolution, and what reproduces
/// across rigs is the ~250 ms *difference* and not either absolute. See
/// "Rig notes" at the end of this comment.
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
/// **"Returns to king parity" is now a number, and the number carries its
/// gap.** A second rig drove a 2-sample wobble from landscape at a **100 ms**
/// gap — estimator: luma 50 % crossing with hysteresis, n=3 each — and read
/// the wrong-state window at king **235.0 ms** (196.7, 235.0, 251.7),
/// `c7d3255` **248.3 ms = 1.06× king** (243.3, 248.3, 263.3), the dwell
/// `6372c93` **615.0 ms = 2.62× king** (601.7, 615.0, 616.7). `c7d3255`'s
/// median falls inside king's own per-run range, which is exactly what
/// "parity" was asserting. **Neither multiplier may be requoted without "at a
/// 100 ms gap"** — the parenthetical above is why: a ratio here divides a
/// window the gap helps set, so it is a reading of one stimulus and not a
/// property of the build.
///
/// **And note what that rig does not reconcile.** Its dwell − king is
/// **380.0 ms**, 130 ms more than the dwell's own 250 ms. The
/// difference-not-ratio argument assumes the render and transition offsets
/// cancel between builds, and in a 2-sample wobble they plainly do not: the
/// 0.4 s `withAnimation` in `observe` is interrupted at a different point on
/// each build — ~100 ms in on king, ~350 ms in on the dwell, far enough
/// through that the return trip travels nearly the whole distance. That is the
/// likeliest reading of the 130 ms, and this rig did not test it. So **+250 ms
/// stands as the claim for gh#178's own window** — an uninterrupted teardown
/// and re-entry — and the wobble is recorded as the harsher separate case, not
/// as a correction to it.
///
/// This rig's absolutes also do not match the earlier two, which read king's
/// window at 83.4 ms and 102 ms: same direction, different instrument. That is
/// the whole reason the ratio is quoted with its conditions and the absolutes
/// are not carried anywhere.
///
/// **gh#174** — focus entered but the interface never rotates — is untouched
/// by anything here, and **its repro is now disputed.** Two rigs, both
/// recorded, neither preferred:
///
/// - gh#172 **round-2 QA**, on its own simulator (configuration not recorded),
///   reached it with a rapid rotation pair and reproduced it on
///   `king-of-rubbish-bin` @ `7b70001` at sample gaps **≤ 200 ms**, with
///   300 ms recovering. That is the reading this comment stated as fact until
///   now, and it is where "the title says cold launch, the repro is broader"
///   came from.
/// - An **independent rig** — iPhone 16 Pro / iOS 26.4 simulator on Xcode
///   26.4, driving the **absolute** `Device > Orientation` items through the
///   Accessibility API with `AXEnabled` asserted on every press, and scoring
///   **by screenshot rather than by a classifier** — ran the same pair
///   (`LL:G, P:G, LL`) at G = 100 / 150 / 200 / 300 ms, 2 runs each:
///   **8/8 correct rotated landscape focus on king `7b70001`, and 8/8 on
///   `c7d3255`**. The failure did not appear at all, on either build.
///
/// What separates them is instrumentation, not conclusion: absolute menu items
/// versus whatever the earlier rig drove, a per-press `AXEnabled` assertion,
/// and a screenshot instead of a classifier. **Nothing here decides between
/// them.** This slice does not need it to — the bar was `c7d3255` no worse than
/// king, and 8/8 against 8/8 clears it, while the earlier reading was never
/// build-specific either. What failed to reproduce is the **pre-existing**
/// defect, on king as much as here. gh#174 stays open, is launch-specific on
/// neither reading, and is caused and fixed by nothing in this file. Before
/// adding a third reading, read the wedge hazard in "Rig notes" below: it
/// manufactures this exact symptom.
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
///
/// # Rig notes
///
/// Every simulator timing above was driven through the Simulator's
/// `Device > Orientation` menu, and that instrument has traps that return
/// clean-looking wrong answers. Each of these cost a rig a false finding, so
/// they are recorded with the numbers rather than left in a QA thread.
///
/// - **The simulator wedges cumulatively.** After enough orientation churn the
///   *guest* stops honouring device orientation at all, and the symptom reads
///   exactly as "landscape focus is broken". It is not the app: QA confirmed
///   Safari had stopped rotating too. It cannot self-recover, because pressing
///   an already-selected radio item emits no notification — only
///   `shutdown`/`boot` clears it. This can manufacture a convincing false
///   result in **either** direction, which is the standing hazard over the
///   gh#174 dispute above.
/// - **A trailing press with no hold after it is silently lost.** The driving
///   process exits immediately after the final press: the menu checkmark
///   moves, `axerr=0`, `enabled=true`, and the guest still never rotates.
///   The symptom is precisely "focus never exits". Always follow the last
///   press with a hold.
/// - **Leftover manual focus rewrites the next run's start state.** Three runs
///   began at portrait-focus luma instead of calendar because an earlier
///   manual-focus test had not been exited — `manualFocusActive` survives
///   rotation on purpose (see `observe(_:)`), and being in-memory only, a
///   relaunch is what clears it.
/// - **`simctl io recordVideo` is innocent**, and was the first suspect every
///   time the guest stopped rotating. Refuted by controlled trial: 10/10
///   presses honoured without recording, 10/10 with it running. It was the
///   wedge.
/// - **Absolutes do not transfer between estimators; only the A/B does.** The
///   rigs above disagree on king's own absolutes — king's wrong-state window
///   at 83.4, 102 and 235.0 ms — while agreeing on every comparison drawn
///   from them. Any figure in this file quoted without a spread is one rig's
///   median. Read the differences, not the values.
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
    ///
    /// `private(set)` on purpose: entering and leaving focus are session
    /// operations with their own presentation rules, not a flag to poke.
    /// Two rounds of this fix were spent trying to make a call site's
    /// `withAnimation` carry the overlay's entrance, so the methods below
    /// carry the answer instead of every future call site rediscovering
    /// it.
    @Published private(set) var manualFocusActive = false

    private var orientationCancellable: AnyCancellable?

    /// Whether `init` was allowed to wire anything at all — the stored form
    /// of the `observeNotifications` parameter, consulted by
    /// `syncOrientationGeneration()` so the `false` seam keeps its full
    /// contract ("must not touch the device at all") even when a caller
    /// drives `enterManualFocus()` or `landscapeFocusSettingChanged(_:)`
    /// afterwards, which the `observe(_:)`-by-hand tests do.
    private let observesNotifications: Bool

    private let notificationGenerator: OrientationNotificationGenerating

    /// Last value forwarded by `landscapeFocusSettingChanged(_:)` (seeded by
    /// `init`). Mirrors the `AppSettingsKeys.landscapeFocusMode` default —
    /// this class deliberately does not read `UserDefaults` itself, so tests
    /// stay hermetic; `DoneApp` owns the forwarding.
    private var landscapeFocusSettingEnabled: Bool

    /// Whether this manager currently holds one reference on the device's
    /// orientation-notification generation count. `syncOrientationGeneration()`
    /// is the only writer, and its change guard is what keeps begin/end
    /// strictly alternating — `UIDevice`'s count is reference-counted, so an
    /// unpaired begin is a leak and an unpaired end steals someone else's.
    private(set) var isGeneratingOrientationNotifications = false

    /// - Parameter observeNotifications: `false` skips the live subscription
    ///   and makes device-notification generation unreachable, so a test can
    ///   drive `observe(_:)` by hand without a real device notification
    ///   landing in the middle of it and moving the published bit under the
    ///   assertion. (Unreachable on the simulator the suite runs on, where
    ///   the real sensor read is `.unknown` and the `compactMap` drops it —
    ///   but the tests should not depend on that being true forever.)
    ///
    ///   **The seam is not an excuse to leave the wiring untested, and for a
    ///   while it was one.** Every construction in `DoneTests` passed `false`,
    ///   so the generation gating and the subscription below had no coverage
    ///   at all and only a manual pass verified them.
    ///   `OrientationDwellTests`' "The live subscriptions" section builds the
    ///   default init instead. Anything added here needs a test there.
    ///
    ///   There is still no `deinit`, so a manager destroyed while
    ///   `isGeneratingOrientationNotifications` leaks that one reference
    ///   count. That is deliberate: production builds exactly one manager for
    ///   the app's lifetime (`DoneApp.swift:640`), and balancing it would mean
    ///   touching a `@MainActor` UIKit API from a nonisolated `deinit`. Since
    ///   gh#219 a default construction no longer begins generation at all —
    ///   demand does (see `landscapeFocusEnabled` below) — so the old
    ///   "every default build leaks one begin" note is gone with the begin,
    ///   and tests that create demand inject a counter stub instead of
    ///   touching the real device.
    ///
    /// - Parameter landscapeFocusEnabled: the
    ///   `AppSettingsKeys.landscapeFocusMode` value at construction time —
    ///   `DoneApp` reads it out of `UserDefaults` because a `@StateObject`
    ///   initial-value expression cannot see its `@AppStorage` sibling.
    ///   Defaults `false` to mirror the setting's own default; later changes
    ///   arrive via `landscapeFocusSettingChanged(_:)`.
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
    ///   site, before `init` runs and therefore before any
    ///   `beginGeneratingOrientationNotifications()` — which since gh#219
    ///   does not even happen at `init`, but on demand, arbitrarily later; per
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
    ///   Production never passes it: `DoneApp.swift:640` is the app's only
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
    /// - Parameter notificationGenerator: the begin/end pair itself, real
    ///   `UIDevice` by default. Tests inject a counter; see
    ///   `OrientationNotificationGenerating`.
    init(
        observeNotifications: Bool = true,
        landscapeFocusEnabled: Bool = false,
        deviceOrientation: @escaping @Sendable () -> UIDeviceOrientation = { UIDevice.current.orientation },
        notificationGenerator: OrientationNotificationGenerating = DeviceOrientationNotificationGenerator()
    ) {
        self.observesNotifications = observeNotifications
        self.notificationGenerator = notificationGenerator
        self.landscapeFocusSettingEnabled = landscapeFocusEnabled
        guard observeNotifications else { return }
        // The subscription is unconditional (a subscriber to a notification
        // nobody posts costs nothing); only GENERATION — the accelerometer
        // work gh#219 is about — is on demand. If some other party's begin
        // keeps notifications flowing while this manager's demand is off, the
        // pipeline behaves exactly as always-on king did, which is the point:
        // the gate removes a battery cost, not a code path.
        syncOrientationGeneration()
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

    /// `DoneApp` forwards every change of the
    /// `AppSettingsKeys.landscapeFocusMode` default here (its `@AppStorage`
    /// `onChange` fires for the settings toggle and for a synced-settings
    /// write alike — both land in `UserDefaults.standard` under the same
    /// key).
    func landscapeFocusSettingChanged(_ enabled: Bool) {
        landscapeFocusSettingEnabled = enabled
        syncOrientationGeneration()
    }

    /// gh#219: generation demand. The decided shape is "setting ON, or a
    /// focus session currently active"; a focus session is
    /// `(isLandscape && setting) || manualFocusActive`, whose first disjunct
    /// already requires the setting, so the whole condition reduces
    /// algebraically to the two terms below. Deliberately NOT a function of
    /// `isLandscape`: with the setting on, gravity is the bootstrap that
    /// opens auto-focus at all (see the header comment), so the sensor must
    /// already be running while the app sits portrait.
    private var orientationGenerationDemand: Bool {
        observesNotifications && (landscapeFocusSettingEnabled || manualFocusActive)
    }

    /// Begin/end at demand transitions, exactly paired.
    ///
    /// On the end transition the published bit is reset through
    /// `observe(false)` — with the sensor off there is no evidence of
    /// landscape, and false is the value the portrait-locked interface now
    /// renders. Keeping a stale `true` instead breaks two real readers the
    /// next samples can no longer correct (generation is off): re-enabling
    /// the setting would open auto-focus instantly on the stale bit — a
    /// flash always-on king cannot produce, because its bit is always live —
    /// and `ContentView`'s day-offset freeze (`isDayOffsetFrozen`) would
    /// stay frozen forever, where king's unfreezing portrait sample always
    /// eventually arrives. The reset goes through `observe(_:)` so the
    /// single-writer, change-guard and animation invariants on `isLandscape`
    /// hold; when the bit is already false it is a no-op. Both end
    /// transitions happen with the focus overlay already gone or going
    /// (setting toggled off, or manual exit), so the animated flip is the
    /// same shape a real portrait sample would have produced there.
    private func syncOrientationGeneration() {
        let demand = orientationGenerationDemand
        guard demand != isGeneratingOrientationNotifications else { return }
        isGeneratingOrientationNotifications = demand
        if demand {
            notificationGenerator.beginGeneratingOrientationNotifications()
        } else {
            notificationGenerator.endGeneratingOrientationNotifications()
            observe(false)
        }
    }

    /// Enter user-driven focus.
    ///
    /// Deliberately NOT wrapped in `withAnimation`, and that is a measured
    /// decision rather than an omission: two rounds tried to make the flip
    /// of this flag animate the overlay's appearance and both shipped a
    /// one-frame cut. Instrumented, a `withAnimation` here animated the
    /// overlay's insertion 0 times out of 5 launches. The entrance belongs
    /// to the surface that appears — `FocusModeView` fades itself in from
    /// `onAppear`.
    ///
    /// Also the moment generation demand can switch on (gh#219): with the
    /// landscape-focus setting off the sensor is idle until this tap, and the
    /// begin below is what makes the pose readable at all. The gh#174 repair
    /// loop's gate-open pose read happens a main-queue turn later and may
    /// still catch `.unknown` (sensor spin-up is physical); that degrades to
    /// "no repair" by `focusGateOpenRepairAction`'s own `.unknown → nil`
    /// rule, and the first real sample — which now always arrives AFTER the
    /// gate is open, because the begin and the gate-opening flag write share
    /// this call — is a fresh device-orientation event UIKit consumes
    /// against the already-open mask, rotating a landscape-held device
    /// through its normal path. See the `.unknown` paragraph on
    /// `focusGateOpenRepairAction` (`DoneApp.swift`) for the full ordering
    /// argument.
    func enterManualFocus() {
        manualFocusActive = true
        syncOrientationGeneration()
    }

    /// Leave user-driven focus. Un-animated, and unlike entry that is what
    /// it should be: this is called from the swipe-dismiss completion, by
    /// which point the surface has already sprung off-screen under the
    /// user's own momentum. Fading the branch out on top of that would
    /// keep the outgoing view alive — its `TimelineView` keeps ticking —
    /// long enough to re-render the settled offset back on screen
    /// mid-fade.
    ///
    /// With the landscape-focus setting off this is also the end of
    /// generation demand (gh#219): the end call and the `observe(false)`
    /// reset ride `syncOrientationGeneration()`. With the setting on, demand
    /// holds and nothing here changes.
    func endManualFocus() {
        manualFocusActive = false
        syncOrientationGeneration()
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
