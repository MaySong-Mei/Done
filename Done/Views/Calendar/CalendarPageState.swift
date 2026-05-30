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

// MARK: - Page Metrics

struct CalendarPageMetrics {
    let containerSize: CGSize
    let safeAreaTop: CGFloat
    let safeAreaBottom: CGFloat

    let horizontalPadding: CGFloat = 8

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
