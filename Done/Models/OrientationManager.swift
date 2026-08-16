import SwiftUI
import UIKit
import Combine

@MainActor
final class OrientationManager: ObservableObject {
    @Published var isLandscape = false
    @Published var rotation: Angle = .zero
    /// User-driven focus state, decoupled from device orientation. Tapping
    /// the focus button enters focus mode in whatever orientation the
    /// device is currently in. Persists until an explicit dismiss
    /// (swipe-down on the focus overlay or another tap on the focus
    /// button) — rotation alone does not clear it, because UIDevice
    /// .portrait notifications fire on small device tilts and would
    /// otherwise drop manual focus mid-session. Orientation lock side
    /// effects live with the focus presentation logic in DoneApp.
    ///
    /// `private(set)` on purpose: entering and leaving focus are session
    /// operations with their own presentation rules, not a flag to poke.
    /// Two rounds of this fix were spent trying to make a call site's
    /// `withAnimation` carry the overlay's entrance, so the methods below
    /// carry the answer instead of every future call site rediscovering
    /// it.
    @Published private(set) var manualFocusActive = false

    private var cancellable: AnyCancellable?

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        cancellable = NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .compactMap { _ in UIDevice.current.orientation }
            .filter { $0 != .unknown && $0 != .faceUp && $0 != .faceDown }
            .receive(on: RunLoop.main)
            .sink { [weak self] orientation in
                self?.update(orientation)
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
    func enterManualFocus() {
        manualFocusActive = true
    }

    /// Leave user-driven focus. Un-animated, and unlike entry that is what
    /// it should be: this is called from the swipe-dismiss completion, by
    /// which point the surface has already sprung off-screen under the
    /// user's own momentum. Fading the branch out on top of that would
    /// keep the outgoing view alive — its `TimelineView` keeps ticking —
    /// long enough to re-render the settled offset back on screen
    /// mid-fade.
    func endManualFocus() {
        manualFocusActive = false
    }

    private func update(_ orientation: UIDeviceOrientation) {
        let landscape: Bool
        let angle: Angle
        switch orientation {
        case .landscapeLeft:
            landscape = true
            angle = .degrees(-90)
        case .landscapeRight:
            landscape = true
            angle = .degrees(90)
        default:
            landscape = false
            angle = .zero
        }
        withAnimation(.easeInOut(duration: 0.4)) {
            isLandscape = landscape
            rotation = angle
            // Intentionally NOT clearing `manualFocusActive` here. Manual
            // entry persists until the user explicitly dismisses (swipe-down
            // on the focus overlay or tapping the focus button again). The
            // auto-on-rotation path is independent: it's gated on
            // `isLandscape && landscapeFocusModeEnabled` in the focus
            // overlay's predicate, so rotating to portrait collapses the
            // auto path naturally. Auto-clearing here re-coupled the two
            // paths and made manual focus inadvertently die when a user
            // briefly tilted the device.
        }
    }
}
