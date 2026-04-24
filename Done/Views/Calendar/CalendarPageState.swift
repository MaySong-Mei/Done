//
//  CalendarPageState.swift
//  Done
//
//  日历页面的状态管理：类型定义、状态机、组合器、布局指标
//

import SwiftUI
import Combine

// MARK: - Math Utilities

func clamp(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
    min(max(x, a), b)
}

func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * clamp(t, 0, 1)
}

// MARK: - Page Types

enum PageMode {
    case preview
    case edit
}

enum RangeMode {
    case day
    case threeDay
    case week
    case month
    case stream
}

enum HeaderVisibility: Equatable {
    case visible
    case hidden
}

enum CalendarHeaderMode {
    case normal
    case expanded
}

struct CalendarPageState: Equatable {
    var pageMode: PageMode
    var headerVisibility: HeaderVisibility
    var pullToggleReady: Bool

    static var initial: CalendarPageState {
        CalendarPageState(pageMode: .preview, headerVisibility: .visible, pullToggleReady: true)
    }
}

// MARK: - Page Metrics

struct CalendarPageMetrics {
    let containerSize: CGSize
    let safeAreaTop: CGFloat
    let safeAreaBottom: CGFloat

    let horizontalPadding: CGFloat = 8
    let headerToTimelineSpacing: CGFloat = 8

    var normalHeaderHeight: CGFloat {
        max(100, containerSize.height * 0.1)
    }

    var expandedHeaderHeight: CGFloat {
        normalHeaderHeight + 64
    }

    var hideSnapDistance: CGFloat {
        normalHeaderHeight
    }

    let hideThreshold: CGFloat = 0.55
    let hideStartDistance: CGFloat = 12
    let expandPullDistance: CGFloat = 72

    // Keep the edge fade style but reduce clipping pressure near top/bottom slots.
    let timelineTopFadeHoldHeight: CGFloat = 8
    let timelineTopFeatherHeight: CGFloat = 14
    let timelineBottomHoldHeight: CGFloat = 8
    let timelineBottomFeatherHeight: CGFloat = 12

    var topMaskConfig: EdgeFadeConfig {
        EdgeFadeConfig(
            holdHeight: timelineTopFadeHoldHeight,
            featherHeight: timelineTopFeatherHeight
        )
    }

    var bottomMaskConfig: EdgeFadeConfig {
        EdgeFadeConfig(
            holdHeight: timelineBottomHoldHeight,
            featherHeight: timelineBottomFeatherHeight
        )
    }

    // Extra scroll room so late-night slots (11pm-midnight) can be moved above the tab bar.
    var timelineBottomScrollPadding: CGFloat {
        max(56, safeAreaBottom + 28)
    }
}

// MARK: - State Machine

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

        // 滚回顶部时重置切换就绪标志
        if scrollY >= 0 {
            next.pullToggleReady = true
        }

        // 下拉超过阈值时切换 edit/preview 模式
        if scrollY <= -metrics.expandPullDistance, state.pullToggleReady {
            next.pageMode = (state.pageMode == .edit) ? .preview : .edit
            next.headerVisibility = .visible
            next.pullToggleReady = false
            shouldAnimate = true
            return Transition(state: next, shouldAnimate: shouldAnimate)
        }

        // 根据滚动位置控制 header 显隐
        let cutoff = metrics.hideSnapDistance * clamp(metrics.hideThreshold, 0, 1)
        let targetVisibility: HeaderVisibility = (scrollY >= cutoff) ? .hidden : .visible

        if targetVisibility != state.headerVisibility {
            next.headerVisibility = targetVisibility
            shouldAnimate = true
        }

        return Transition(state: next, shouldAnimate: shouldAnimate)
    }
}

// MARK: - Composer

struct CalendarHeaderPresentation {
    let height: CGFloat
    let topInset: CGFloat
    let opacity: CGFloat
    let scale: CGFloat
}

struct CalendarPageComposition {
    let headerMode: CalendarHeaderMode
    let headerPresentation: CalendarHeaderPresentation
    let activeTimelineMode: PageMode
    let timelineRange: RangeMode
    let timelineRebuildKey: String
    let timelineTopPadding: CGFloat
}

struct CalendarPageComposer {
    static func compose(
        state: CalendarPageState,
        rangeMode: RangeMode,
        scrollY: CGFloat,
        metrics: CalendarPageMetrics
    ) -> CalendarPageComposition {
        let headerMode: CalendarHeaderMode = (state.pageMode == .edit) ? .expanded : .normal
        let hideProgress = Self.hideProgress(
            state: state,
            headerMode: headerMode,
            scrollY: scrollY,
            metrics: metrics
        )

        let headerHeight: CGFloat
        if state.headerVisibility == .visible, headerMode == .expanded {
            headerHeight = metrics.expandedHeaderHeight
        } else {
            headerHeight = lerp(metrics.normalHeaderHeight, 0, hideProgress)
        }

        let topInset = metrics.safeAreaTop * (1 - hideProgress)
        let presentation = CalendarHeaderPresentation(
            height: max(0, headerHeight),
            topInset: max(0, topInset),
            opacity: lerp(1, 0, hideProgress),
            scale: lerp(1, 0.98, hideProgress)
        )

        let timelineTopPadding = metrics.safeAreaTop + headerHeight + metrics.headerToTimelineSpacing

        return CalendarPageComposition(
            headerMode: headerMode,
            headerPresentation: presentation,
            activeTimelineMode: state.pageMode,
            timelineRange: rangeMode,
            timelineRebuildKey: "timeline-\(rangeMode)",
            timelineTopPadding: timelineTopPadding
        )
    }

    private static func hideProgress(
        state: CalendarPageState,
        headerMode: CalendarHeaderMode,
        scrollY: CGFloat,
        metrics: CalendarPageMetrics
    ) -> CGFloat {
        if state.headerVisibility == .visible, headerMode == .expanded {
            return 0
        }

        let y = max(0, scrollY)
        let end = max(metrics.hideSnapDistance, 1)
        let start = clamp(metrics.hideStartDistance, 0, end)
        let t = (y - start) / max(end - start, 1)
        return clamp(t, 0, 1)
    }
}
