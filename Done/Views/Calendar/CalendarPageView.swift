//
//  CalendarPageView.swift
//  Done
//
//  Calendar page with a three-state header (expanded / normal / hidden).
//  Uses iOS 17+ scroll APIs (onScrollGeometryChange + scrollTargetBehavior).
//  Composition: CalendarHeaderView -> GlassCardView (header), CalendarTimelineView
//  (timeline + TimelineDayView/CalendarEventBlockView), TimelineMaskView for
//  edge fading, layout math in Metrics.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// Hosts the calendar tab layout and handles shared spacing metrics.
struct CalendarPageView: View {
    @EnvironmentObject private var store: EventStore

    enum HeaderState: Equatable {
        case expanded
        case normal
        case hidden
    }

    @State private var headerState: HeaderState = .normal
    @State private var scrollGeometry: ScrollGeometry = .init(
        contentOffset: .zero,
        contentSize: .zero,
        contentInsets: .init(),
        containerSize: .zero
    )

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(containerSize: proxy.size, safeAreaTop: proxy.safeAreaInsets.top)

            ZStack(alignment: .top) {
                timelineScroll(metrics: metrics)

                headerCard(metrics: metrics)
            }
            .ignoresSafeArea(edges: [.top, .bottom])
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private extension CalendarPageView {
    // MARK: - Layout Metrics

    struct Metrics {
        let containerSize: CGSize
        let safeAreaTop: CGFloat

        let horizontalPadding: CGFloat = 16
        let headerToTimelineSpacing: CGFloat = 8

        var normalHeaderHeight: CGFloat {
            max(120, containerSize.height * 0.12)
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
        let expandedCollapseDistance: CGFloat = 20

        let timelineTopFadeHoldHeight: CGFloat = 24
        let timelineTopFeatherHeight: CGFloat = 48
        let timelineBottomHoldHeight: CGFloat = 12
        let timelineBottomFeatherHeight: CGFloat = 24

        var timelineTopPadding: CGFloat {
            safeAreaTop + normalHeaderHeight + headerToTimelineSpacing
        }

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

    // MARK: - Header

    func headerCard(metrics: Metrics) -> some View {
        let y = scrollGeometry.contentOffset.y
        let hideProgress = hideProgress(for: y, metrics: metrics)
        let mode: CalendarHeaderView.Mode = (headerState == .expanded) ? .expanded : .normal

        let headerHeight: CGFloat = {
            switch headerState {
            case .expanded:
                return metrics.expandedHeaderHeight
            case .normal, .hidden:
                return lerp(metrics.normalHeaderHeight, 0, hideProgress)
            }
        }()

        let topInset = metrics.safeAreaTop * (1 - hideProgress)
        // When expanded, lift the header upward by the extra height so its top edge stays fixed.
        let expansionLift = headerState == .expanded
            ? (metrics.expandedHeaderHeight - metrics.normalHeaderHeight)
            : 0

        return CalendarHeaderView(
            mode: mode,
            onTodayTapped: {},
            onAddTapped: {},
            onSearchTapped: {},
            onFilterTapped: {}
        )
        .frame(height: max(0, headerHeight))
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, max(0, topInset))
        .offset(y: -expansionLift/2)
        .opacity(lerp(1, 0, hideProgress))
        .scaleEffect(lerp(1, 0.98, hideProgress), anchor: .top)
        .animation(.snappy(duration: 0.22), value: headerState)
    }

    // MARK: - Timeline Scroll

    func timelineScroll(metrics: Metrics) -> some View {
        return ScrollView {
            CalendarTimelineView(events: store.events)
                .padding(.top, metrics.timelineTopPadding)
                .padding(.horizontal, metrics.horizontalPadding)
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
            scrollGeometry = newValue
            updateHeaderState(for: newValue.contentOffset.y, metrics: metrics)
        }
        .scrollTargetBehavior(
            SnapTopRangeScrollBehavior(height: metrics.hideSnapDistance, threshold: metrics.hideThreshold)
        )
        .mask {
            TimelineMaskView(
                top: metrics.topMaskConfig,
                bottom: metrics.bottomMaskConfig
            )
        }
    }

    // MARK: - State Updates

    func updateHeaderState(for scrollY: CGFloat, metrics: Metrics) {
        if headerState == .expanded {
            if scrollY > metrics.expandedCollapseDistance {
                withAnimation(.snappy(duration: 0.22)) {
                    headerState = .normal
                }
            }
            return
        }

        if scrollY < -metrics.expandPullDistance {
            withAnimation(.snappy(duration: 0.22)) {
                headerState = .expanded
            }
            return
        }

        let cutoff = metrics.hideSnapDistance * clamp(metrics.hideThreshold, 0, 1)
        let newState: HeaderState = (scrollY >= cutoff) ? .hidden : .normal
        if newState != headerState {
            headerState = newState
        }
    }

    // MARK: - Helpers

    func hideProgress(for scrollY: CGFloat, metrics: Metrics) -> CGFloat {
        guard headerState != .expanded else { return 0 }

        let y = max(0, scrollY)
        let end = max(metrics.hideSnapDistance, 1)
        let start = clamp(metrics.hideStartDistance, 0, end)
        let t = (y - start) / max(end - start, 1)
        return clamp(t, 0, 1)
    }

    func clamp(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        min(max(x, a), b)
    }

    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * clamp(t, 0, 1)
    }
}

// MARK: - Top-Range Snap Behavior (iOS 17+)

@available(iOS 17.0, *)
private struct SnapTopRangeScrollBehavior: ScrollTargetBehavior {
    /// The range [0, height] participates in snapping.
    let height: CGFloat

    /// 0..1 of `height` at which we snap forward.
    let threshold: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: ScrollTargetBehaviorContext) {
        let y = target.rect.minY

        // Only snap when we are within the top header range.
        guard y >= 0, y <= height else {
            return
        }

        let t = clamp(threshold, 0, 1)
        let cutoff = height * t
        target.rect.origin.y = (y >= cutoff) ? height : 0
    }

    private func clamp(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        min(max(x, a), b)
    }
}
