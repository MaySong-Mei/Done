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

/// Wrapper for pending event creation to make it Identifiable for sheet presentation.
struct PendingEventCreation: Identifiable {
    let id = UUID()
    let date: Date
    let timeRange: Event.TimeRange
}

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
    @State private var occurrencesCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
    @State private var dayRange: ClosedRange<Int> = CalendarLayout.defaultDayRange
    @State private var selectedEventForEdit: Event? = nil
    @State private var pendingCreateTimeRange: PendingEventCreation? = nil
    private let dayRangeExpansionStep: Int = 30
    private let dayRangeExpansionThreshold: Int = 14
    private let dayRangeExpansionBuffer: Int = 14
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
        .sheet(item: $selectedEventForEdit) { event in
            EditEventView(event: event)
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingCreateTimeRange) { pending in
            CreateEventWithTimeRangeView(timeRange: pending.timeRange)
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            headerSubtitle = CalendarSubtitleStore.randomSubtitle()
            expandDayRangeToInclude(calendarState.selectedDayOffset)
            rebuildOccurrencesCache()
        }
        .onChange(of: store.events) { _ in
            rebuildOccurrencesCache()
        }
        .onChange(of: calendarState.selectedDayOffset) { newValue in
            expandDayRangeIfNeeded(for: newValue)
        }
        .onChange(of: dayRange) { _ in
            rebuildOccurrencesCache()
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
        // Only render the active mode to reduce CPU/memory usage.
        // Use transition for smooth mode switching animation.
        let rebuildKey = composition.timelineRebuildKey
        let activeMode = composition.activeTimelineMode

        timelineLayer(
            for: activeMode,
            range: composition.timelineRange,
            rebuildKey: rebuildKey
        )
        .id(activeMode) // Force view identity change for transition
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }

    @ViewBuilder
    func timelineLayer(
        for mode: PageMode,
        range: RangeMode,
        rebuildKey: String
    ) -> some View {
        TimelineContainerView(
            occurrencesForOffset: { occurrencesCache[$0] ?? [] },
            selectedDayOffset: $calendarState.selectedDayOffset,
            mode: mode,
            range: range,
            dayRange: dayRange,
            previewCreation: pendingCreateTimeRange,
            onEventTap: { event in selectedEventForEdit = event },
            onEventDragEnded: { event, draggedRange, offset in
                handleEventDrag(event: event, draggedRange: draggedRange, offset: offset, rangeMode: range)
            },
            onEventResizeEnded: { event, draggedRange, dragMode, yOffset in
                handleEventResize(event: event, draggedRange: draggedRange, dragMode: dragMode, yOffset: yOffset)
            },
            onCreateEvent: { date, timeRange in
                handleCreateEvent(on: date, timeRange: timeRange)
            }
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
        // Animation is handled by .animation() modifiers on views
        // Using withAnimation here would cause double animation
        pageState = transition.state
    }

    func rebuildOccurrencesCache() {
        occurrencesCache = CalendarLayout.occurrencesByOffset(
            store.events,
            dayRange: dayRange
        )
    }

    func expandDayRangeIfNeeded(for offset: Int) {
        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound
        var newLower = lower
        var newUpper = upper
        if offset - lower < dayRangeExpansionThreshold {
            newLower = lower - dayRangeExpansionStep
        }
        if upper - offset < dayRangeExpansionThreshold {
            newUpper = upper + dayRangeExpansionStep
        }
        if newLower != lower || newUpper != upper {
            dayRange = newLower...newUpper
        }
    }

    func expandDayRangeToInclude(_ offset: Int) {
        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound
        var newLower = lower
        var newUpper = upper
        if offset < lower {
            newLower = offset - dayRangeExpansionBuffer
        }
        if offset > upper {
            newUpper = offset + dayRangeExpansionBuffer
        }
        if newLower != lower || newUpper != upper {
            dayRange = newLower...newUpper
        }
    }

    func handleEventDrag(event: Event, draggedRange: Event.TimeRange, offset: DragOffset, rangeMode: RangeMode) {
        let hourHeight: CGFloat = 56
        let headerHeight: CGFloat = 0
        let labelWidth: CGFloat = 36
        let daySpacing: CGFloat = 12

        // Calculate day width based on range mode and screen size
        let screenWidth = UIScreen.main.bounds.width
        let contentWidth = screenWidth - labelWidth
        let daysCount: Int
        switch rangeMode {
        case .day: daysCount = 1
        case .threeDay: daysCount = 3
        case .week: daysCount = 7
        }
        let dayWidth = daysCount == 1
            ? contentWidth
            : (contentWidth - daySpacing * CGFloat(daysCount - 1)) / CGFloat(daysCount)

        // Calculate day offset from X movement
        let dayOffsetFromDrag: Int
        if daysCount == 1 {
            // For single day view, use threshold-based day change
            let threshold = contentWidth * 0.3
            if offset.x > threshold {
                dayOffsetFromDrag = 1
            } else if offset.x < -threshold {
                dayOffsetFromDrag = -1
            } else {
                dayOffsetFromDrag = 0
            }
        } else {
            // For multi-day view, calculate based on day width
            dayOffsetFromDrag = Int(round(offset.x / (dayWidth + daySpacing)))
        }

        // Use the dragged range to determine original position
        let originalDate = Calendar.current.startOfDay(for: draggedRange.start)

        // Calculate target date
        let targetDate = Calendar.current.date(
            byAdding: .day,
            value: dayOffsetFromDrag,
            to: originalDate
        ) ?? originalDate

        // Calculate current Y position of the dragged range
        let currentY = CalendarLayout.yOffset(
            for: draggedRange,
            on: originalDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight
        )

        // Calculate new Y position
        let newY = currentY + offset.y

        // Convert to new start time on the target date
        let newStart = CalendarLayout.timeFromYOffset(
            yOffset: newY,
            on: targetDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight
        )

        // Preserve duration of the dragged range
        let duration = draggedRange.end.timeIntervalSince(draggedRange.start)
        let newEnd = newStart.addingTimeInterval(duration)
        let newRange = Event.TimeRange(start: newStart, end: newEnd)

        // Update only the dragged range, preserve other ranges
        var updated = event
        var ranges = updated.timeRanges
        if let index = ranges.firstIndex(where: { $0.start == draggedRange.start && $0.end == draggedRange.end }) {
            ranges[index] = newRange
        } else {
            // Fallback: if not found in timeRanges, check if it matches startTime/endTime
            ranges = [newRange]
        }
        ranges.sort { $0.start < $1.start }
        updated.timeRanges = ranges
        updated.startTime = ranges.first?.start
        updated.endTime = ranges.first?.end
        store.update(updated)
    }

    func handleEventResize(event: Event, draggedRange: Event.TimeRange, dragMode: EventDragMode, yOffset: CGFloat) {
        let hourHeight: CGFloat = 56
        let headerHeight: CGFloat = 0

        let originalDate = Calendar.current.startOfDay(for: draggedRange.start)

        // Calculate current Y positions
        let startY = CalendarLayout.yOffset(
            for: draggedRange,
            on: originalDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight
        )
        let endY = startY + CalendarLayout.eventHeight(
            for: draggedRange,
            on: originalDate,
            minimumHeight: hourHeight / 2,
            hourHeight: hourHeight
        )

        // Apply offset based on drag mode
        let newStartY: CGFloat
        let newEndY: CGFloat
        switch dragMode {
        case .resizeTop:
            newStartY = startY + yOffset
            newEndY = endY // Keep end fixed
        case .resizeBottom:
            newStartY = startY // Keep start fixed
            newEndY = endY + yOffset
        case .move:
            return // Should not happen, but exit gracefully
        }

        // Convert back to times with snapping
        let newStart = CalendarLayout.timeFromYOffset(
            yOffset: newStartY,
            on: originalDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            snapMinutes: 15
        )
        let newEnd = CalendarLayout.timeFromYOffset(
            yOffset: newEndY,
            on: originalDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            snapMinutes: 15
        )

        // Ensure minimum duration (15 minutes), clamp instead of rejecting
        // Always anchor the fixed edge from the original range to avoid Y→time snap drift
        let minDuration: TimeInterval = 30 * 60
        let newRange: Event.TimeRange
        switch dragMode {
        case .resizeTop:
            let fixedEnd = draggedRange.end
            let clampedStart = min(newStart, fixedEnd.addingTimeInterval(-minDuration))
            newRange = Event.TimeRange(start: clampedStart, end: fixedEnd)
        case .resizeBottom:
            let fixedStart = draggedRange.start
            let clampedEnd = max(newEnd, fixedStart.addingTimeInterval(minDuration))
            newRange = Event.TimeRange(start: fixedStart, end: clampedEnd)
        case .move:
            return
        }

        // Update the event
        var updated = event
        var ranges = updated.timeRanges
        if let index = ranges.firstIndex(where: { $0.start == draggedRange.start && $0.end == draggedRange.end }) {
            ranges[index] = newRange
        } else {
            ranges = [newRange]
        }
        ranges.sort { $0.start < $1.start }
        updated.timeRanges = ranges
        updated.startTime = ranges.first?.start
        updated.endTime = ranges.first?.end
        store.update(updated)
    }

    func handleCreateEvent(on date: Date, timeRange: Event.TimeRange) {
        // Open create sheet - event will only be added when user saves
        // Preview will stay visible until sheet is dismissed
        pendingCreateTimeRange = PendingEventCreation(date: date, timeRange: timeRange)
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

}
