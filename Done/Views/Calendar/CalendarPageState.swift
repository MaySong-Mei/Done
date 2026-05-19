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
