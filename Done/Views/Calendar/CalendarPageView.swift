//
//  CalendarPageView.swift
//  Done
//
//  Calendar page with a three-state header (expanded / normal / hidden).
//  Uses iOS 17+ scroll APIs (onScrollGeometryChange + scrollTargetBehavior).
//  Composition: CalendarHeaderView -> GlassCardView (header),
//  TimelineContainerView (switches edit/preview + range), TimelineMaskView for
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

    enum PageMode {
        case preview
        case edit
    }

    enum RangeMode {
        case day
        case threeDay
        case week
    }

    @State private var headerState: HeaderState = .normal
    @State private var scrollGeometry: ScrollGeometry = .init(
        contentOffset: .zero,
        contentSize: .zero,
        contentInsets: .init(),
        containerSize: .zero
    )
    @State private var pageMode: PageMode = .preview
    @State private var rangeMode: RangeMode = .day
    @State private var selectedDayOffset: Int = 0
    @State private var pullToggleReady: Bool = true
    // 这里的功能是：当 header 处于 expanded 状态时，用户向上滚动超过一定距离后收起 header。
    // 当 header 处于 normal / hidden 状态时，用户向下拉超过一定距离后展开 header。
    // 该交互与 scrollView 的滚动行为解耦，不影响 scrollView 的滚动逻辑。
    // toggle ready的含义是：用户必须先回到顶部（scrollY >= 0）才能再次触发展开/收起切换。

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
        .offset(y: -expansionLift)
        .opacity(lerp(1, 0, hideProgress))
        .scaleEffect(lerp(1, 0.98, hideProgress), anchor: .top)
        .animation(.snappy(duration: 0.22), value: headerState)
    }

    // MARK: - Timeline Scroll

    func timelineScroll(metrics: Metrics) -> some View {
        return ScrollView {
            timelineContent(metrics: metrics)
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

    @ViewBuilder
    func timelineContent(metrics: Metrics) -> some View {
        TimelineContainerView(
            events: store.events,
            selectedDayOffset: $selectedDayOffset,
            mode: pageMode == .edit ? .edit : .preview,
            range: rangeMode == .day ? .day : (rangeMode == .threeDay ? .threeDay : .week)
        )
        // Force a fresh subtree when mode/range changes to avoid stale content.
        .id("\(pageMode)-\(rangeMode)")
    }

    // MARK: - State Updates

    func updateHeaderState(for scrollY: CGFloat, metrics: Metrics) {
        if scrollY >= 0 {
            pullToggleReady = true
        }

        // 顶端下拉手势：超过阈值即作为“开关”在 edit / preview 间切换。
        // 保持其它逻辑不变（正常的隐藏/收起规则仍生效）。
        if scrollY <= -metrics.expandPullDistance, pullToggleReady, headerState != .hidden {
            withAnimation(.snappy(duration: 0.22)) {
                pageMode = (pageMode == .edit) ? .preview : .edit
                headerState = (pageMode == .edit) ? .expanded : .normal
            }
            pullToggleReady = false
            return
        }

        if headerState == .expanded {
            if scrollY > metrics.expandedCollapseDistance {
                withAnimation(.snappy(duration: 0.22)) {
                    headerState = .normal
                }
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
