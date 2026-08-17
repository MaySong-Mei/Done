import SwiftUI
import UIKit
import Combine
import QuartzCore

/// How long one device orientation must hold before `OrientationManager`
/// publishes it. See `orientationDwellDecision` for the rule itself.
///
/// 0.25 s. The number is a judgement call, not a measurement, and the
/// bounds it was picked between are: long enough that the settling wobble
/// at the end of a deliberate rotation (and a `.landscapeLeft` sample
/// thrown off mid-rotation *back* to portrait) reverts before it can
/// publish; short enough to stay under the 0.4 s enter animation this
/// manager itself runs, so the gate is never slower than the transition it
/// gates, and well under the 0.6 s day-offset unfreeze in `ContentView`.
/// It has NOT been tuned against real device traces — gh#172.
let orientationDwellSeconds: CFTimeInterval = 0.25

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
///   - dwell: how long a candidate must hold. `<= 0` publishes at once.
///
/// Repeated observations of the SAME candidate do not restart its clock —
/// `pending.since` is carried through unchanged — so a stream of
/// notifications during one continuous rotation cannot push the deadline
/// forward indefinitely. A DIFFERENT candidate can only be `published`
/// itself (the state is one bit), which drops the pending one outright.
func orientationDwellDecision(
    published: Bool,
    pending: OrientationDwellCandidate?,
    candidate: Bool,
    now: CFTimeInterval,
    dwell: CFTimeInterval
) -> OrientationDwellDecision {
    guard candidate != published else { return .idle }
    let since = (pending?.landscape == candidate) ? (pending?.since ?? now) : now
    let elapsed = max(0, now - since)
    guard elapsed < dwell else { return .publish(candidate) }
    return .hold(
        OrientationDwellCandidate(landscape: candidate, since: since),
        after: dwell - elapsed
    )
}

/// Landscape/portrait as read from **gravity**
/// (`UIDevice.orientationDidChangeNotification`), filtered so only
/// orientations that have held for `orientationDwellSeconds` are published.
///
/// **Why gravity and not `UIWindowScene.interfaceOrientation`.** The app is
/// portrait-locked except while focus mode is active: `AppDelegate`
/// answers `focusOrientationMask(allowsLandscape:)`, whose closed form is
/// plain `.portrait` — landscape is absent from the mask, not merely
/// deprioritised — and the gate's only writer sets it from `focusActive`,
/// which is in turn derived from `isLandscape`. Sourcing `isLandscape`
/// from the interface orientation would therefore close that loop on
/// itself: the lock suppresses the very signal that is supposed to open
/// the lock, the fixed point from a portrait start is "stay portrait", and
/// landscape auto-focus becomes unreachable. Gravity is the only reading
/// that survives the lock, so it is load-bearing as the bootstrap. It is
/// also the semantic the user was promised — the setting reads "Auto-enter
/// focus mode on rotation". Do not "fix" this to `interfaceOrientation`.
///
/// **Why a dwell.** Gravity fires on small tilts and on the settling wobble
/// at the end of a deliberate rotation, so a raw subscription sees values
/// the user never meant — including a `.landscapeLeft` sample thrown off in
/// the middle of a rotation *back* to portrait. Hysteresis is what a noisy
/// sensor calls for; the noise is filtered here, once, rather than worked
/// around by each subscriber.
///
/// **The first reading is not exempt.** The dwell applies uniformly,
/// including at launch and when the app launches already rotated. Nothing
/// is rendered wrongly in the meantime: the seed value `false` agrees with
/// what the portrait lock is already showing, and no interface rotation can
/// happen before this manager publishes, because the lock only opens as a
/// consequence of that publish. A launch-time accelerometer sample (phone
/// coming out of a pocket, lifted off a table) is also the least
/// trustworthy one there is, so exempting it would exempt the noisiest
/// reading. The cost is that a genuinely-landscape launch enters focus
/// 0.25 s in.
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

    private var cancellable: AnyCancellable?

    /// The candidate waiting out the dwell. `nil` when the device agrees
    /// with `isLandscape`. Written only from `orientationDwellDecision`'s
    /// verdict, never computed here — the carry-through rule that stops the
    /// window re-arming lives in the pure function.
    private var pending: OrientationDwellCandidate?

    /// Wake-up nudge for the pending candidate. Only a nudge — the deadline
    /// lives in `pending.since`, so a task that fires early or late simply
    /// re-runs the decision and re-arms if needed. The task is re-created
    /// on every observation, but it is never re-armed against a *fresh*
    /// stamp: `orientationDwellDecision` carries `since` through, so the
    /// window shrinks and cannot be pushed forward indefinitely.
    private var dwellTask: Task<Void, Never>?

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        cancellable = NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .compactMap { _ in UIDevice.current.orientation }
            .filter { $0 != .unknown && $0 != .faceUp && $0 != .faceDown }
            .receive(on: RunLoop.main)
            .sink { [weak self] orientation in
                self?.observe(orientation.isLandscape)
            }
    }

    /// The impure shell around `orientationDwellDecision`: it supplies the
    /// clock, keeps `pending`, and owns the timer. All of the judgement
    /// lives in the pure function.
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
            dwell: orientationDwellSeconds
        )
        switch decision {
        case .idle:
            // Either a duplicate, or a transient that reverted before it
            // earned the right to publish. Either way: nothing goes out.
            pending = nil
            dwellTask?.cancel()
            dwellTask = nil
        case let .hold(next, after):
            pending = next
            dwellTask?.cancel()
            dwellTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, after) * 1_000_000_000))
                guard !Task.isCancelled, let self, let pending = self.pending else { return }
                self.observe(pending.landscape)
            }
        case let .publish(landscape):
            pending = nil
            dwellTask?.cancel()
            dwellTask = nil
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
}
