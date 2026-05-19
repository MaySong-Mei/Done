//
//  TabBarSlideHider.swift
//  Done
//
//  Drives a slide-down / slide-up animation on the underlying UITabBar by
//  bypassing SwiftUI's `.toolbar(.hidden, for: .tabBar)` (which cross-fades).
//  Attach via `.slideHideTabBar(_:)` on a view that lives inside a `TabView`.
//  The probe walks the key-window view hierarchy to find a UITabBar and
//  animates its frame off the bottom edge.
//

import SwiftUI
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "TabBar"
)

struct TabBarSlideHider: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> ProbeViewController {
        ProbeViewController()
    }

    func updateUIViewController(_ vc: ProbeViewController, context: Context) {
        vc.update(isHidden: isHidden)
    }

    final class ProbeViewController: UIViewController {
        private var lastApplied: Bool?
        private var pendingHidden: Bool?
        private weak var managedTabBar: UITabBar?
        private var originalFrame: CGRect?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let pendingHidden {
                self.pendingHidden = nil
                lastApplied = pendingHidden
                DispatchQueue.main.async { [weak self] in
                    self?.apply(isHidden: pendingHidden, animated: false)
                }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // If we leave the hierarchy while the tab bar is slid off-screen,
            // restore it so the next visible tab doesn't inherit a phantom
            // missing tab bar.
            if lastApplied == true, let tabBar = managedTabBar, let baseFrame = originalFrame {
                tabBar.layer.removeAllAnimations()
                var f = tabBar.frame
                f.origin.y = baseFrame.origin.y
                tabBar.frame = f
                tabBar.isHidden = false
            }
        }

        func update(isHidden: Bool) {
            guard lastApplied != isHidden else { return }
            let wasFirstApply = (lastApplied == nil)
            lastApplied = isHidden
            if view.window == nil {
                pendingHidden = isHidden
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.apply(isHidden: isHidden, animated: !wasFirstApply)
            }
        }

        // MARK: - Tab bar discovery

        private func resolveTabBar() -> UITabBar? {
            if let cached = managedTabBar, cached.window != nil { return cached }

            // 1. Try parent UITabBarController via responder chain
            if let tbc = self.tabBarController {
                managedTabBar = tbc.tabBar
                return tbc.tabBar
            }

            // 2. Walk the key window's view hierarchy looking for any UITabBar
            let scenes = UIApplication.shared.connectedScenes
            for scene in scenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows where window.isKeyWindow {
                    if let bar = findTabBar(in: window) {
                        managedTabBar = bar
                        return bar
                    }
                }
            }
            return nil
        }

        private func findTabBar(in view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar { return bar }
            for sub in view.subviews {
                if let found = findTabBar(in: sub) { return found }
            }
            return nil
        }

        // MARK: - Animation

        private func apply(isHidden: Bool, animated: Bool) {
            guard let tabBar = resolveTabBar(), let superview = tabBar.superview else {
                logger.warning("could not resolve UITabBar (isHidden=\(isHidden, privacy: .public))")
                return
            }

            if originalFrame == nil || tabBar.frame.origin.y < superview.bounds.height - tabBar.bounds.height * 1.5 {
                originalFrame = tabBar.frame
            }
            guard let baseFrame = originalFrame else { return }

            let hiddenY = superview.bounds.height + 4
            let targetY = isHidden ? hiddenY : baseFrame.origin.y

            tabBar.layer.removeAllAnimations()
            tabBar.isHidden = false

            if !animated {
                var f = tabBar.frame
                f.origin.y = targetY
                tabBar.frame = f
                return
            }

            // When showing, the frame may have been reset by a layout pass
            // back to baseFrame.origin.y, so the animation would be a no-op
            // (and look like a flash-in). Snap to the off-screen position
            // first, then animate up.
            if !isHidden {
                var start = tabBar.frame
                start.origin.y = hiddenY
                tabBar.frame = start
                tabBar.layoutIfNeeded()
            }

            UIView.animate(
                withDuration: 0.34,
                delay: 0,
                usingSpringWithDamping: 0.88,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: {
                    var f = tabBar.frame
                    f.origin.y = targetY
                    tabBar.frame = f
                },
                completion: nil
            )
        }
    }
}

extension View {
    /// Slides the host UITabBar down/up rather than cross-fading it.
    func slideHideTabBar(_ isHidden: Bool) -> some View {
        background(
            TabBarSlideHider(isHidden: isHidden)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .opacity(0)
        )
    }
}
