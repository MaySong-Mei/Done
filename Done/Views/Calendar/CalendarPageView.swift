//
//  CalendarPageView.swift
//  Done
//
//  Calendar page composed from a state machine and composition resolver.
//  Uses iOS 17+ scroll APIs (onScrollGeometryChange + scrollTargetBehavior).
//  Composition: CalendarHeaderView -> GlassCardView (header),
//  TimelineContainerView (switches edit/preview + range), TimelineMaskView for
//  edge fading, layout math in CalendarPageMetrics.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// 功能： Hosts the calendar page layout and binds state/composition to views.
struct CalendarPageView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var calendarState: CalendarViewState

    @State private var pageState: CalendarPageState = .initial
    @State private var scrollGeometry: ScrollGeometry = .init(
        contentOffset: .zero,
        contentSize: .zero,
        contentInsets: .init(),
        containerSize: .zero
    )
    @State private var headerSubtitle: String = ""
    // 这里的功能是：scrollY 超过阈值时隐藏 header（headerVisibility）。
    // 顶端下拉超过阈值时切换 edit/preview（影响 header mode）。
    // 该交互与 scrollView 的滚动行为解耦，不影响 scrollView 的滚动逻辑。
    // toggle ready 的含义是：用户必须先回到顶部（scrollY >= 0）才能再次触发切换。

    var body: some View {
        GeometryReader { proxy in
            let metrics = CalendarPageMetrics(containerSize: proxy.size, safeAreaTop: proxy.safeAreaInsets.top)
            let composition = CalendarPageComposer.compose(
                state: pageState,
                rangeMode: calendarState.rangeMode,
                scrollY: scrollGeometry.contentOffset.y,
                metrics: metrics
            )

            ZStack(alignment: .top) {
                timelineScroll(metrics: metrics, composition: composition)

                headerCard(metrics: metrics, composition: composition)
            }
            .ignoresSafeArea(edges: [.top, .bottom])
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            headerSubtitle = CalendarSubtitleStore.randomSubtitle()
        }
    }
}

private extension CalendarPageView {
    // MARK: - Header

    func headerCard(metrics: CalendarPageMetrics, composition: CalendarPageComposition) -> some View {
        let presentation = composition.headerPresentation
        return CalendarHeaderView(
            title: headerTitle,
            subtitle: headerSubtitle,
            mode: composition.headerMode,
            onTodayTapped: {},
            onAddTapped: {},
            onSearchTapped: {},
            onFilterTapped: {}
        )
        .frame(height: presentation.height)
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, presentation.topInset)
        .opacity(presentation.opacity)
        .scaleEffect(presentation.scale, anchor: .top)
        .animation(.snappy(duration: 0.22), value: pageState.headerVisibility)
        .animation(.snappy(duration: 0.22), value: pageState.pageMode)
    }

    // MARK: - Timeline Scroll

    func timelineScroll(metrics: CalendarPageMetrics, composition: CalendarPageComposition) -> some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                timelineHeaderBar(isEditing: composition.activeTimelineMode == .edit)
                timelineContent(composition: composition)
            }
            .padding(.top, composition.timelineTopPadding)
            .padding(.horizontal, metrics.horizontalPadding)
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
            scrollGeometry = newValue
            handleScroll(newValue.contentOffset.y, metrics: metrics)
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
    func timelineContent(composition: CalendarPageComposition) -> some View {
        // Keep preview/edit timelines alive in a shared container so mode switches
        // cross-fade instead of rebuilding/relayout-ing the scroll content. This
        // prevents jumps when the user pulls to toggle modes.
        let rebuildKey = composition.timelineRebuildKey
        ZStack {
            timelineLayer(for: .preview, range: composition.timelineRange, rebuildKey: rebuildKey)
                .opacity(composition.activeTimelineMode == .preview ? 1 : 0)
                .allowsHitTesting(composition.activeTimelineMode == .preview)

            timelineLayer(for: .edit, range: composition.timelineRange, rebuildKey: rebuildKey)
                .opacity(composition.activeTimelineMode == .edit ? 1 : 0)
                .allowsHitTesting(composition.activeTimelineMode == .edit)
        }
        .animation(.snappy(duration: 0.22), value: pageState.pageMode)
        .animation(.snappy(duration: 0.22), value: calendarState.rangeMode)
    }

    @ViewBuilder
    func timelineLayer(
        for mode: TimelineContainerView.Mode,
        range: TimelineContainerView.Range,
        rebuildKey: String
    ) -> some View {
        TimelineContainerView(
            events: store.events,
            selectedDayOffset: $calendarState.selectedDayOffset,
            mode: mode,
            range: range
        )
        // Rebuild when range changes to avoid stale TabView pages across layouts.
        .id(rebuildKey)
    }

    @ViewBuilder
    func timelineHeaderBar(isEditing: Bool) -> some View {
        TimelineHeaderBar(
            isEditing: isEditing,
            rangeMode: $calendarState.rangeMode,
            selectedDayOffset: calendarState.selectedDayOffset
        )
        .animation(.snappy(duration: 0.22), value: pageState.pageMode)
    }

    // MARK: - Header Content

    var headerTitle: String {
        title(for: calendarState.rangeMode, offset: calendarState.selectedDayOffset)
    }

    private func title(for range: RangeMode, offset: Int) -> String {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()

        switch range {
        case .day:
            return Self.dayTitleFormatter.string(from: start)
        case .threeDay:
            let end = calendar.date(byAdding: .day, value: 2, to: start) ?? start
            let letters = weekdayLetters(from: start, days: 3, calendar: calendar)
            return "\(Self.rangeFormatter.string(from: start))-\(Self.rangeFormatter.string(from: end)), \(letters)"
        case .week:
            let week = calendar.component(.weekOfYear, from: start)
            let year = calendar.component(.yearForWeekOfYear, from: start)
            return "\(year) Week \(week)"
        }
    }

    private func weekdayLetters(from start: Date, days: Int, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")

        var letters: [String] = []
        for offset in 0..<days {
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            letters.append(formatter.string(from: date).uppercased())
        }
        return letters.joined()
    }

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    // MARK: - State Updates

    func handleScroll(_ scrollY: CGFloat, metrics: CalendarPageMetrics) {
        let transition = CalendarPageStateMachine.transition(
            from: pageState,
            scrollY: scrollY,
            metrics: metrics
        )
        guard transition.state != pageState else { return }
        if transition.shouldAnimate {
            withAnimation(.snappy(duration: 0.22)) {
                pageState = transition.state
            }
        } else {
            pageState = transition.state
        }
    }
}

// MARK: - Top-Range Snap Behavior (iOS 17+)

@available(iOS 17.0, *)
/// 功能： Implements snap-to-top behavior within the header range for iOS 17+ scroll views.
private struct SnapTopRangeScrollBehavior: ScrollTargetBehavior {
    /// 功能： Defines the range [0, height] that participates in snapping.
    let height: CGFloat

    /// 功能： Defines the 0..1 fraction of `height` at which we snap forward.
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
