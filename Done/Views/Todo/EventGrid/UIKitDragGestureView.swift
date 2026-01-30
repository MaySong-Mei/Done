//
//  UIKitDragGestureView.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI
import UIKit

struct UIKitDragGestureView: UIViewRepresentable {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: () -> Bool
        var onTap: () -> Void
        var onBegan: () -> Void
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize, CGPoint) -> Void
        var onBeganLocation: ((CGPoint) -> Void)?
        var onChangedLocation: ((CGPoint) -> Void)?
        var onEndedLocation: ((CGPoint) -> Void)?
        var allowsSimultaneous: Bool = false
        var attachToScrollView: Bool = false
        var disableScrollWhileActive: Bool = false

        private weak var longPress: UILongPressGestureRecognizer?
        private weak var tapRecognizer: UITapGestureRecognizer?
        private weak var scrollView: UIScrollView?
        private weak var hostView: UIView?
        private weak var gestureView: UIView?
        private var wasScrollEnabled: Bool?
        private var isEnabled: Bool = true

        private var startPoint: CGPoint = .zero

        init(
            shouldBegin: @escaping () -> Bool,
            onTap: @escaping () -> Void,
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGSize) -> Void,
            onEnded: @escaping (CGSize, CGPoint) -> Void,
            onBeganLocation: ((CGPoint) -> Void)? = nil,
            onChangedLocation: ((CGPoint) -> Void)? = nil,
            onEndedLocation: ((CGPoint) -> Void)? = nil
        ) {
            self.shouldBegin = shouldBegin
            self.onTap = onTap
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onBeganLocation = onBeganLocation
            self.onChangedLocation = onChangedLocation
            self.onEndedLocation = onEndedLocation
        }

        func attach(
            longPress: UILongPressGestureRecognizer,
            tap: UITapGestureRecognizer,
            in view: UIView,
            requireScrollFailure: Bool,
            attachToScrollView: Bool,
            allowsSimultaneous: Bool,
            disableScrollWhileActive: Bool
        ) {
            self.longPress = longPress
            self.tapRecognizer = tap
            self.hostView = view
            self.attachToScrollView = attachToScrollView
            self.allowsSimultaneous = allowsSimultaneous
            self.disableScrollWhileActive = disableScrollWhileActive

            if scrollView == nil {
                scrollView = view.findSuperview(of: UIScrollView.self)
            }

            let targetView: UIView
            if attachToScrollView, let scrollView {
                targetView = scrollView
                hostView?.isUserInteractionEnabled = false
            } else {
                targetView = view
                hostView?.isUserInteractionEnabled = true
            }

            if gestureView !== targetView {
                if let old = gestureView {
                    if let longPress = self.longPress {
                        old.removeGestureRecognizer(longPress)
                    }
                    if let tap = self.tapRecognizer {
                        old.removeGestureRecognizer(tap)
                    }
                }
                gestureView = targetView
                targetView.addGestureRecognizer(longPress)
                targetView.addGestureRecognizer(tap)
            }

            if requireScrollFailure, let scrollView {
                scrollView.panGestureRecognizer.require(toFail: longPress)
            }
        }

        func reattach(
            in view: UIView,
            requireScrollFailure: Bool,
            attachToScrollView: Bool,
            allowsSimultaneous: Bool,
            disableScrollWhileActive: Bool
        ) {
            guard let longPress, let tapRecognizer else { return }
            attach(
                longPress: longPress,
                tap: tapRecognizer,
                in: view,
                requireScrollFailure: requireScrollFailure,
                attachToScrollView: attachToScrollView,
                allowsSimultaneous: allowsSimultaneous,
                disableScrollWhileActive: disableScrollWhileActive
            )
        }

        func setEnabled(_ enabled: Bool) {
            isEnabled = enabled
            longPress?.isEnabled = enabled
            tapRecognizer?.isEnabled = enabled
            if !enabled, disableScrollWhileActive, let scrollView {
                scrollView.isScrollEnabled = wasScrollEnabled ?? true
                wasScrollEnabled = nil
            }
        }

        func detach() {
            if let gestureView {
                if let longPress {
                    gestureView.removeGestureRecognizer(longPress)
                }
                if let tapRecognizer {
                    gestureView.removeGestureRecognizer(tapRecognizer)
                }
            }
            if disableScrollWhileActive, let scrollView {
                scrollView.isScrollEnabled = wasScrollEnabled ?? true
            }
            wasScrollEnabled = nil
            gestureView = nil
            hostView = nil
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let gestureView = recognizer.view else { return }

            // Use window coordinates for translation to avoid feedback loop
            // (the view moves during drag, which shifts local coordinates)
            let stablePoint = recognizer.location(in: gestureView.window ?? gestureView)
            let location = resolveLocation(from: recognizer, in: gestureView)
            let windowLocation = stablePoint

            switch recognizer.state {
            case .began:
                guard shouldBegin() else {
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                    return
                }
                if disableScrollWhileActive, let scrollView {
                    wasScrollEnabled = scrollView.isScrollEnabled
                    scrollView.isScrollEnabled = false
                }
                startPoint = stablePoint
                onBegan()
                onBeganLocation?(location)

            case .changed:
                let t = CGSize(width: stablePoint.x - startPoint.x, height: stablePoint.y - startPoint.y)
                onChanged(t)
                onChangedLocation?(location)

            case .ended, .cancelled, .failed:
                let t = CGSize(width: stablePoint.x - startPoint.x, height: stablePoint.y - startPoint.y)
                onEnded(t, windowLocation)
                onEndedLocation?(location)
                if disableScrollWhileActive, let scrollView {
                    scrollView.isScrollEnabled = wasScrollEnabled ?? true
                    wasScrollEnabled = nil
                }

            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended {
                onTap()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            shouldBegin()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            allowsSimultaneous
        }

        private func resolveLocation(from recognizer: UILongPressGestureRecognizer, in gestureView: UIView) -> CGPoint {
            let locationInGesture = recognizer.location(in: gestureView)
            guard let hostView, gestureView !== hostView else {
                return locationInGesture
            }
            return hostView.convert(locationInGesture, from: gestureView)
        }
    }

    let minimumPressDuration: TimeInterval
    let shouldBegin: () -> Bool
    let onTap: () -> Void
    let onPanBegan: () -> Void
    let onPanChanged: (CGSize) -> Void
    let onPanEnded: (CGSize, CGPoint) -> Void
    var onPanBeganLocation: ((CGPoint) -> Void)? = nil
    var onPanChangedLocation: ((CGPoint) -> Void)? = nil
    var onPanEndedLocation: ((CGPoint) -> Void)? = nil
    var requiresScrollFailure: Bool = true
    var allowableMovement: CGFloat = 1000
    var attachToScrollView: Bool = false
    var allowsSimultaneous: Bool = false
    var disableScrollWhileActive: Bool = false
    var isEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldBegin: shouldBegin,
            onTap: onTap,
            onBegan: onPanBegan,
            onChanged: onPanChanged,
            onEnded: onPanEnded,
            onBeganLocation: onPanBeganLocation,
            onChangedLocation: onPanChangedLocation,
            onEndedLocation: onPanEndedLocation
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        longPress.minimumPressDuration = minimumPressDuration
        longPress.allowableMovement = allowableMovement
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.require(toFail: longPress)

        context.coordinator.attach(
            longPress: longPress,
            tap: tap,
            in: view,
            requireScrollFailure: requiresScrollFailure,
            attachToScrollView: attachToScrollView,
            allowsSimultaneous: allowsSimultaneous,
            disableScrollWhileActive: disableScrollWhileActive
        )
        context.coordinator.setEnabled(isEnabled)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onTap = onTap
        context.coordinator.onBegan = onPanBegan
        context.coordinator.onChanged = onPanChanged
        context.coordinator.onEnded = onPanEnded
        context.coordinator.onBeganLocation = onPanBeganLocation
        context.coordinator.onChangedLocation = onPanChangedLocation
        context.coordinator.onEndedLocation = onPanEndedLocation
        context.coordinator.attachToScrollView = attachToScrollView
        context.coordinator.allowsSimultaneous = allowsSimultaneous
        context.coordinator.disableScrollWhileActive = disableScrollWhileActive
        context.coordinator.reattach(
            in: uiView,
            requireScrollFailure: requiresScrollFailure,
            attachToScrollView: attachToScrollView,
            allowsSimultaneous: allowsSimultaneous,
            disableScrollWhileActive: disableScrollWhileActive
        )
        context.coordinator.setEnabled(isEnabled)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

private extension UIView {
    func findSuperview<T: UIView>(of type: T.Type) -> T? {
        var current = superview
        while let view = current {
            if let match = view as? T {
                return match
            }
            current = view.superview
        }
        return nil
    }
}
