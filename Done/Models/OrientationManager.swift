import SwiftUI
import UIKit
import Combine

@MainActor
final class OrientationManager: ObservableObject {
    @Published var isLandscape = false
    @Published var rotation: Angle = .zero
    /// When true, focus mode is requested manually (via the header button)
    /// independent of the auto-on-rotation setting. Cleared automatically
    /// whenever the device returns to portrait, so the exit affordance is
    /// simply "rotate back." Setting this also forces the app's UI
    /// orientation to landscape via `FocusOrientationLock`.
    @Published var manualFocusActive = false {
        didSet {
            guard oldValue != manualFocusActive else { return }
            FocusOrientationLock.allowsLandscape = manualFocusActive
            FocusOrientationLock.applyOrientationChange(
                target: manualFocusActive ? .landscape : .portrait
            )
        }
    }

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
            if !landscape {
                manualFocusActive = false
            }
        }
    }
}
