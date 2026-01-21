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

        private weak var longPress: UILongPressGestureRecognizer?
        private weak var tapRecognizer: UITapGestureRecognizer?
        private weak var scrollView: UIScrollView?
        private weak var referenceView: UIView?

        private var startPoint: CGPoint = .zero

        init(
            shouldBegin: @escaping () -> Bool,
            onTap: @escaping () -> Void,
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGSize) -> Void,
            onEnded: @escaping (CGSize, CGPoint) -> Void
        ) {
            self.shouldBegin = shouldBegin
            self.onTap = onTap
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(longPress: UILongPressGestureRecognizer, tap: UITapGestureRecognizer, in view: UIView) {
            self.longPress = longPress
            self.tapRecognizer = tap

            if scrollView == nil {
                scrollView = view.findSuperview(of: UIScrollView.self)
            }
            if let scrollView {
                scrollView.panGestureRecognizer.require(toFail: longPress)
            }
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }

            let ref = referenceView ?? view.window ?? scrollView ?? view
            referenceView = ref

            let location = recognizer.location(in: ref)
            let windowLocation = recognizer.location(in: view.window ?? ref)

            switch recognizer.state {
            case .began:
                guard shouldBegin() else {
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                    return
                }
                startPoint = location
                onBegan()

            case .changed:
                let t = CGSize(width: location.x - startPoint.x, height: location.y - startPoint.y)
                onChanged(t)

            case .ended, .cancelled, .failed:
                let t = CGSize(width: location.x - startPoint.x, height: location.y - startPoint.y)
                onEnded(t, windowLocation)
                referenceView = nil

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
    }

    let minimumPressDuration: TimeInterval
    let shouldBegin: () -> Bool
    let onTap: () -> Void
    let onPanBegan: () -> Void
    let onPanChanged: (CGSize) -> Void
    let onPanEnded: (CGSize, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldBegin: shouldBegin,
            onTap: onTap,
            onBegan: onPanBegan,
            onChanged: onPanChanged,
            onEnded: onPanEnded
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
        longPress.allowableMovement = 1000
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.require(toFail: longPress)

        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)
        context.coordinator.attach(longPress: longPress, tap: tap, in: view)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onTap = onTap
        context.coordinator.onBegan = onPanBegan
        context.coordinator.onChanged = onPanChanged
        context.coordinator.onEnded = onPanEnded
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
