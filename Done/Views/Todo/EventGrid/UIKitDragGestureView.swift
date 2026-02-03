//
//  UIKitDragGestureView.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI
import UIKit

struct UIKitDragGestureView: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = 0.3
    var shouldBegin: () -> Bool = { true }
    var onPanBegan: () -> Void = {}
    var onPanChanged: (CGSize, CGPoint) -> Void = { _, _ in }
    var onPanEnded: (CGSize, CGPoint) -> Void = { _, _ in }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let gesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        gesture.minimumPressDuration = minimumPressDuration
        gesture.cancelsTouchesInView = false
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onBegan = onPanBegan
        context.coordinator.onChanged = onPanChanged
        context.coordinator.onEnded = onPanEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldBegin: shouldBegin,
            onBegan: onPanBegan,
            onChanged: onPanChanged,
            onEnded: onPanEnded
        )
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: () -> Bool
        var onBegan: () -> Void
        var onChanged: (CGSize, CGPoint) -> Void
        var onEnded: (CGSize, CGPoint) -> Void
        private var startPoint: CGPoint = .zero

        init(
            shouldBegin: @escaping () -> Bool,
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGSize, CGPoint) -> Void,
            onEnded: @escaping (CGSize, CGPoint) -> Void
        ) {
            self.shouldBegin = shouldBegin
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handleGesture(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
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
                onChanged(t, stablePoint)

            case .ended, .cancelled:
                let t = CGSize(width: stablePoint.x - startPoint.x, height: stablePoint.y - startPoint.y)
                onEnded(t, stablePoint)

            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}
