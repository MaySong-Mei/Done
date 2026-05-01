import SwiftUI
import UIKit
import Combine

@MainActor
final class OrientationManager: ObservableObject {
    @Published var isLandscape = false
    @Published var rotation: Angle = .zero
    /// User-driven focus state, decoupled from device orientation. Tapping
    /// the focus button enters focus mode in whatever orientation the
    /// device is currently in. Cleared on physical rotation back to
    /// portrait so "rotate to exit" still works for the common case.
    /// Orientation lock side effects live with the focus presentation
    /// logic in DoneApp, not here.
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
            if !landscape {
                manualFocusActive = false
            }
        }
    }
}
