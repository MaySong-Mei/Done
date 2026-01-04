//
//  MultiTouchScrollHost.swift
//  Done
//
//  Created by Codex on 3/10/26.
//

import SwiftUI
import UIKit

struct MultiTouchScrollHost: UIViewRepresentable {
    @ObservedObject var router: CarryTouchRouter

    func makeUIView(context: Context) -> MultiTouchAttachView {
        let view = MultiTouchAttachView()
        view.isUserInteractionEnabled = false
        view.router = router
        return view
    }

    func updateUIView(_ uiView: MultiTouchAttachView, context: Context) {
        uiView.router = router
        uiView.updateAttachments()
    }
}

final class MultiTouchAttachView: UIView {
    weak var router: CarryTouchRouter? {
        didSet {
            touchRecognizer?.router = router
            touchRecognizer?.delegate = router
            for delegate in panDelegates.values {
                delegate.router = router
            }
        }
    }

    private weak var attachedSuperview: UIView?
    private var touchRecognizer: TouchCaptureGestureRecognizer?
    private var panDelegates: [ObjectIdentifier: CarryPanGestureDelegate] = [:]
    private var needsScrollViewScan = true

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateAttachments()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAttachments()
    }

    func updateAttachments() {
        guard let superview else { return }

        if attachedSuperview !== superview {
            if let attachedSuperview, let recognizer = touchRecognizer {
                attachedSuperview.removeGestureRecognizer(recognizer)
            }
            attachedSuperview = superview
            needsScrollViewScan = true
        }

        attachTouchRecognizer(to: superview)
        if needsScrollViewScan {
            attachPanDelegates(in: superview)
        }
    }

    private func attachTouchRecognizer(to view: UIView) {
        if touchRecognizer == nil {
            let recognizer = TouchCaptureGestureRecognizer()
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.router = router
            recognizer.delegate = router
            view.addGestureRecognizer(recognizer)
            touchRecognizer = recognizer
        } else {
            touchRecognizer?.router = router
        }
    }

    private func attachPanDelegates(in view: UIView) {
        let scrollViews = findScrollViews(in: view)
        if scrollViews.isEmpty {
            needsScrollViewScan = true
            return
        }
        let resolved = resolveScrollViews(from: scrollViews)
        router?.updateScrollViews(vertical: resolved.vertical, horizontal: resolved.horizontal)
        needsScrollViewScan = resolved.vertical == nil || resolved.horizontal == nil
        let currentIDs = Set(scrollViews.map { ObjectIdentifier($0) })
        panDelegates = panDelegates.filter { currentIDs.contains($0.key) }

        for scrollView in scrollViews {
            let id = ObjectIdentifier(scrollView)
            if let existing = panDelegates[id] {
                existing.router = router
                continue
            }

            let panGesture = scrollView.panGestureRecognizer
            if let wrapper = panGesture.delegate as? CarryPanGestureDelegate {
                wrapper.router = router
                panDelegates[id] = wrapper
                continue
            }

            let wrapper = CarryPanGestureDelegate(router: router, originalDelegate: panGesture.delegate)
            panGesture.delegate = wrapper
            panDelegates[id] = wrapper
        }
    }

    private func resolveScrollViews(from scrollViews: [UIScrollView]) -> (vertical: UIScrollView?, horizontal: UIScrollView?) {
        var bestVertical: UIScrollView?
        var bestHorizontal: UIScrollView?
        var bestVerticalDelta: CGFloat = 0
        var bestHorizontalDelta: CGFloat = 0
        var fallbackVertical: UIScrollView?
        var fallbackHorizontal: UIScrollView?

        for scrollView in scrollViews {
            if fallbackVertical == nil, scrollView.showsVerticalScrollIndicator {
                fallbackVertical = scrollView
            }
            if fallbackHorizontal == nil, scrollView.showsHorizontalScrollIndicator {
                fallbackHorizontal = scrollView
            }

            let verticalDelta = scrollView.contentSize.height - scrollView.bounds.height
            let horizontalDelta = scrollView.contentSize.width - scrollView.bounds.width

            if verticalDelta > bestVerticalDelta + 1 {
                bestVerticalDelta = verticalDelta
                bestVertical = scrollView
            }

            if horizontalDelta > bestHorizontalDelta + 1 {
                bestHorizontalDelta = horizontalDelta
                bestHorizontal = scrollView
            }
        }

        return (bestVertical ?? fallbackVertical, bestHorizontal ?? fallbackHorizontal)
    }

    private func findScrollViews(in view: UIView) -> [UIScrollView] {
        var results: [UIScrollView] = []
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView {
                results.append(scrollView)
            }
            results.append(contentsOf: findScrollViews(in: subview))
        }
        return results
    }
}
