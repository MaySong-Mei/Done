//
//  TabBarSlideHider.swift
//  Done
//
//  Drives concealment animations on the underlying UITabBar by bypassing
//  SwiftUI's `.toolbar(.hidden, for: .tabBar)` (which cross-fades). Attach
//  via `.concealTabBar(_:)` on a view that lives inside a `TabView`. The
//  probe walks the key-window view hierarchy to find a UITabBar and
//  animates it: slid off the bottom edge (hidden — event focus), or
//  uniformly scaled down a notch in place (shrunken — the Todo drawer
//  cedes the bottom edge without making the bar vanish).
//

import SwiftUI
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "TabBar"
)

/// How the host UITabBar should yield the bottom edge.
enum TabBarConcealment: Equatable {
    /// Fully visible, docked.
    case visible
    /// Uniformly scaled down a notch, still docked — present, but ceding
    /// attention to an overlay (Todo drawer).
    case shrunken
    /// Slid off the bottom edge entirely — event focus.
    case hidden
}

struct TabBarSlideHider: UIViewControllerRepresentable {
    let concealment: TabBarConcealment

    func makeUIViewController(context: Context) -> ProbeViewController {
        ProbeViewController()
    }

    func updateUIViewController(_ vc: ProbeViewController, context: Context) {
        vc.update(concealment: concealment)
    }

    final class ProbeViewController: UIViewController {
        private var lastApplied: TabBarConcealment?
        private var pending: TabBarConcealment?
        private weak var managedTabBar: UITabBar?
        private var originalFrame: CGRect?

        /// The shrunken state's uniform scale. Small enough to read as
        /// "stepped back", large enough that the labels stay legible.
        private static let shrunkenScale: CGFloat = 0.85

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let pending {
                self.pending = nil
                lastApplied = pending
                DispatchQueue.main.async { [weak self] in
                    self?.apply(pending, from: nil, animated: false)
                }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // If we leave the hierarchy while the tab bar is concealed,
            // restore it so the next visible tab doesn't inherit a phantom
            // shrunken/missing tab bar.
            if lastApplied != .visible, let tabBar = managedTabBar, let baseFrame = originalFrame {
                tabBar.layer.removeAllAnimations()
                tabBar.transform = .identity
                var f = tabBar.frame
                f.origin.y = baseFrame.origin.y
                tabBar.frame = f
                tabBar.isHidden = false
            }
        }

        func update(concealment: TabBarConcealment) {
            guard lastApplied != concealment else { return }
            let from = lastApplied
            let wasFirstApply = (lastApplied == nil)
            lastApplied = concealment
            if view.window == nil {
                pending = concealment
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.apply(concealment, from: from, animated: !wasFirstApply)
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

        /// All position math runs on `center` — `frame` is undefined while
        /// a non-identity transform (the shrunken state) is applied.
        private func apply(_ concealment: TabBarConcealment, from: TabBarConcealment?, animated: Bool) {
            guard let tabBar = resolveTabBar(), let superview = tabBar.superview else {
                logger.warning("could not resolve UITabBar (concealment=\(String(describing: concealment), privacy: .public))")
                return
            }

            if originalFrame == nil
                || (tabBar.transform.isIdentity
                    && tabBar.frame.origin.y < superview.bounds.height - tabBar.bounds.height * 1.5) {
                originalFrame = tabBar.transform.isIdentity ? tabBar.frame : originalFrame
            }
            guard let baseFrame = originalFrame else { return }

            let baseCenterY = baseFrame.midY
            let hiddenCenterY = superview.bounds.height + 4 + baseFrame.height / 2
            let targetCenterY = (concealment == .hidden) ? hiddenCenterY : baseCenterY
            // Scale around the center, nudged down so the shrunken bar keeps
            // roughly the same breathing room to the bottom edge.
            let targetTransform: CGAffineTransform = (concealment == .shrunken)
                ? CGAffineTransform(translationX: 0, y: baseFrame.height * (1 - Self.shrunkenScale) / 2)
                    .scaledBy(x: Self.shrunkenScale, y: Self.shrunkenScale)
                : .identity

            tabBar.layer.removeAllAnimations()
            tabBar.isHidden = false

            if !animated {
                tabBar.transform = targetTransform
                tabBar.center.y = targetCenterY
                return
            }

            // When emerging from hidden, a layout pass may already have
            // reset the bar to its base position — the animation would be a
            // no-op that reads as a flash-in. Snap back off-screen first,
            // then animate up.
            if from == .hidden, concealment != .hidden {
                tabBar.transform = .identity
                tabBar.center.y = hiddenCenterY
                tabBar.layoutIfNeeded()
            }

            UIView.animate(
                withDuration: 0.34,
                delay: 0,
                usingSpringWithDamping: 0.88,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: {
                    tabBar.transform = targetTransform
                    tabBar.center.y = targetCenterY
                },
                completion: nil
            )
        }
    }
}

extension View {
    /// Drives the host UITabBar's concealment: slid off (hidden), uniformly
    /// shrunk in place (shrunken), or restored (visible). Animated as a
    /// slide/scale rather than SwiftUI's toolbar cross-fade.
    func concealTabBar(_ concealment: TabBarConcealment) -> some View {
        background(
            TabBarSlideHider(concealment: concealment)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .opacity(0)
        )
    }
}
