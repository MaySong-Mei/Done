//
//  CalendarPageMetrics.swift
//  Done
//
//  Layout metrics shared by CalendarPage composition and interactions.
//

import SwiftUI

struct CalendarPageMetrics {
    let containerSize: CGSize
    let safeAreaTop: CGFloat

    let horizontalPadding: CGFloat = 16
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

    let timelineTopFadeHoldHeight: CGFloat = 24
    let timelineTopFeatherHeight: CGFloat = 48
    let timelineBottomHoldHeight: CGFloat = 12
    let timelineBottomFeatherHeight: CGFloat = 24

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
}
