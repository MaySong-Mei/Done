//
//  CarryTouchRouter.swift
//  Done
//
//  Created by Codex on 3/10/26.
//

import Combine
import UIKit

@MainActor
final class CarryTouchRouter: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    let objectWillChange = ObservableObjectPublisher()
    var onCarryCancelled: (() -> Void)?
    weak var verticalScrollView: UIScrollView?
    weak var horizontalScrollView: UIScrollView?

    private(set) var activeCarryTouchID: ObjectIdentifier?
    private var pendingCarryPoint: CGPoint?
    private var touchLocations: [ObjectIdentifier: CGPoint] = [:]
    private var isCarryActive = false
    private let maxCaptureDistance: CGFloat = 60

    func beginCarry(at point: CGPoint) {
        isCarryActive = true
        pendingCarryPoint = point
        selectActiveTouchIfNeeded()
    }

    func updateCarry(at point: CGPoint) {
        pendingCarryPoint = point
        selectActiveTouchIfNeeded()
    }

    func endCarry() {
        isCarryActive = false
        activeCarryTouchID = nil
        pendingCarryPoint = nil
    }

    func updateScrollViews(vertical: UIScrollView?, horizontal: UIScrollView?) {
        if let vertical {
            verticalScrollView = vertical
        }
        if let horizontal {
            horizontalScrollView = horizontal
        }
    }

    func scroll(verticalBy: CGFloat, horizontalBy: CGFloat) {
        if verticalBy != 0, let scrollView = verticalScrollView {
            let newOffset = CGPoint(
                x: scrollView.contentOffset.x,
                y: scrollView.contentOffset.y + verticalBy
            )
            scrollView.setContentOffset(clampedOffset(newOffset, in: scrollView), animated: false)
        }

        if horizontalBy != 0, let scrollView = horizontalScrollView {
            let newOffset = CGPoint(
                x: scrollView.contentOffset.x + horizontalBy,
                y: scrollView.contentOffset.y
            )
            scrollView.setContentOffset(clampedOffset(newOffset, in: scrollView), animated: false)
        }
    }

    func updateTouches(_ touches: Set<UITouch>, in view: UIView) {
        let container = view.window ?? view
        for touch in touches {
            let id = ObjectIdentifier(touch)
            touchLocations[id] = touch.location(in: container)
        }
        selectActiveTouchIfNeeded()
    }

    func removeTouches(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            touchLocations[id] = nil
            if activeCarryTouchID == id {
                activeCarryTouchID = nil
                if isCarryActive, cancelled {
                    endCarry()
                    onCarryCancelled?()
                }
            }
        }
    }

    func shouldAllowPan(for touch: UITouch) -> Bool {
        guard isCarryActive, let activeID = activeCarryTouchID else { return true }
        return ObjectIdentifier(touch) != activeID
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private func selectActiveTouchIfNeeded() {
        guard isCarryActive, activeCarryTouchID == nil, let anchor = pendingCarryPoint else { return }
        guard !touchLocations.isEmpty else { return }

        if touchLocations.count == 1, let only = touchLocations.keys.first {
            activeCarryTouchID = only
            return
        }

        var bestID: ObjectIdentifier?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (id, location) in touchLocations {
            let dx = location.x - anchor.x
            let dy = location.y - anchor.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance < bestDistance {
                bestDistance = distance
                bestID = id
            }
        }

        if let bestID, bestDistance <= maxCaptureDistance {
            activeCarryTouchID = bestID
        }
    }

    private func clampedOffset(_ proposed: CGPoint, in scrollView: UIScrollView) -> CGPoint {
        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        let maxX = max(
            minX,
            scrollView.contentSize.width - scrollView.bounds.width + inset.right
        )
        let minY = -inset.top
        let maxY = max(
            minY,
            scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        )

        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }
}

final class TouchCaptureGestureRecognizer: UIGestureRecognizer {
    weak var router: CarryTouchRouter?
    private var activeTouchIDs: Set<ObjectIdentifier> = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            activeTouchIDs.insert(ObjectIdentifier(touch))
        }
        if let view {
            router?.updateTouches(touches, in: view)
        }
        state = activeTouchIDs.count == touches.count ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let view {
            router?.updateTouches(touches, in: view)
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            activeTouchIDs.remove(ObjectIdentifier(touch))
        }
        router?.removeTouches(touches, cancelled: false)
        state = activeTouchIDs.isEmpty ? .ended : .changed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            activeTouchIDs.remove(ObjectIdentifier(touch))
        }
        router?.removeTouches(touches, cancelled: true)
        state = activeTouchIDs.isEmpty ? .cancelled : .changed
    }

    override func reset() {
        activeTouchIDs.removeAll()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

final class CarryPanGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var router: CarryTouchRouter?
    weak var originalDelegate: UIGestureRecognizerDelegate?

    init(router: CarryTouchRouter?, originalDelegate: UIGestureRecognizerDelegate?) {
        self.router = router
        self.originalDelegate = originalDelegate
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if router?.shouldAllowPan(for: touch) == false {
            return false
        }
        return originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        originalDelegate?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: otherGestureRecognizer) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: otherGestureRecognizer) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: otherGestureRecognizer) ?? false
    }
}
