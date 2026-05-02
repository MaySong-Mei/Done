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
    @Published var manualFocusActive = false

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
