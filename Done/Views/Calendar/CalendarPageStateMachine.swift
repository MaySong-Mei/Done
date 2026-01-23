//
//  CalendarPageStateMachine.swift
//  Done
//
//  Pure state transitions for CalendarPage scroll interactions.
//

import SwiftUI

struct CalendarPageStateMachine {
    struct Transition {
        let state: CalendarPageState
        let shouldAnimate: Bool
    }

    static func transition(
        from state: CalendarPageState,
        scrollY: CGFloat,
        metrics: CalendarPageMetrics
    ) -> Transition {
        var next = state
        var shouldAnimate = false

        if scrollY >= 0 {
            next.pullToggleReady = true
        }

        if scrollY <= -metrics.expandPullDistance, state.pullToggleReady {
            next.pageMode = (state.pageMode == .edit) ? .preview : .edit
            next.headerVisibility = .visible
            next.pullToggleReady = false
            shouldAnimate = true
            return Transition(state: next, shouldAnimate: shouldAnimate)
        }

        let cutoff = metrics.hideSnapDistance * clamp(metrics.hideThreshold, 0, 1)
        let targetVisibility: HeaderVisibility = (scrollY >= cutoff) ? .hidden : .visible
        if targetVisibility != state.headerVisibility {
            next.headerVisibility = targetVisibility
            shouldAnimate = true
        }

        return Transition(state: next, shouldAnimate: shouldAnimate)
    }

    private static func clamp(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        min(max(x, a), b)
    }
}
