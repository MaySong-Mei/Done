//
//  CalendarPageComposer.swift
//  Done
//
//  Resolves CalendarPage state into concrete composition choices.
//

import SwiftUI

struct CalendarHeaderPresentation {
    let height: CGFloat
    let topInset: CGFloat
    let opacity: CGFloat
    let scale: CGFloat
}

struct CalendarPageComposition {
    let headerMode: CalendarHeaderView.Mode
    let headerPresentation: CalendarHeaderPresentation
    let activeTimelineMode: TimelineContainerView.Mode
    let timelineRange: TimelineContainerView.Range
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
        let headerMode: CalendarHeaderView.Mode = (state.pageMode == .edit) ? .expanded : .normal
        let hideProgress = hideProgress(
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

        let timelineMode: TimelineContainerView.Mode = (state.pageMode == .edit) ? .edit : .preview
        let timelineRange: TimelineContainerView.Range = {
            switch rangeMode {
            case .day:
                return .day
            case .threeDay:
                return .threeDay
            case .week:
                return .week
            }
        }()

        let timelineTopPadding = metrics.safeAreaTop + headerHeight + metrics.headerToTimelineSpacing

        return CalendarPageComposition(
            headerMode: headerMode,
            headerPresentation: presentation,
            activeTimelineMode: timelineMode,
            timelineRange: timelineRange,
            timelineRebuildKey: "timeline-\(rangeMode)",
            timelineTopPadding: timelineTopPadding
        )
    }

    private static func hideProgress(
        state: CalendarPageState,
        headerMode: CalendarHeaderView.Mode,
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

    private static func clamp(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        min(max(x, a), b)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * clamp(t, 0, 1)
    }
}
