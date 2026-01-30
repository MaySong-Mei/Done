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
        var onBegan: () -> Void
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize, CGPoint) -> Void

        private weak var longPress: UILongPressGestureRecognizer?
        private weak var scrollView: UIScrollView?
        private var startPoint: CGPoint = .zero

        init(
            shouldBegin: @escaping () -> Bool,
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGSize) -> Void,
            onEnded: @escaping (CGSize, CGPoint) -> Void
        ) {
            self.shouldBegin = shouldBegin
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(longPress: UILongPressGestureRecognizer, in view: UIView) {
            self.longPress = longPress
            if scrollView == nil {
                scrollView = view.findSuperview(of: UIScrollView.self)
            }
            view.addGestureRecognizer(longPress)
            if let scrollView {
                scrollView.panGestureRecognizer.require(toFail: longPress)
            }
        }

        func detach(from view: UIView) {
            if let longPress {
                view.removeGestureRecognizer(longPress)
            }
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }

            // Use window coordinates for translation to avoid feedback loop
            // (the view moves during drag, which shifts local coordinates)
            let stablePoint = recognizer.location(in: view.window ?? view)

            switch recognizer.state {
            case .began:
                guard shouldBegin() else {
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                    return
                }
                startPoint = stablePoint
                onBegan()

            case .changed:
                let t = CGSize(width: stablePoint.x - startPoint.x, height: stablePoint.y - startPoint.y)
                onChanged(t)

            case .ended, .cancelled, .failed:
                let t = CGSize(width: stablePoint.x - startPoint.x, height: stablePoint.y - startPoint.y)
                onEnded(t, stablePoint)

            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            shouldBegin()
        }
    }

    let minimumPressDuration: TimeInterval
    let shouldBegin: () -> Bool
    let onPanBegan: () -> Void
    let onPanChanged: (CGSize) -> Void
    let onPanEnded: (CGSize, CGPoint) -> Void
    var allowableMovement: CGFloat = 1000

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldBegin: shouldBegin,
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
        longPress.allowableMovement = allowableMovement
        longPress.delegate = context.coordinator

        context.coordinator.attach(longPress: longPress, in: view)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onBegan = onPanBegan
        context.coordinator.onChanged = onPanChanged
        context.coordinator.onEnded = onPanEnded
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach(from: uiView)
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
