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
import Combine

/// Wrapper for pending event creation to make it Identifiable for sheet presentation.
struct PendingEventCreation: Identifiable {
    let id = UUID()
    let date: Date
    let timeRange: Event.TimeRange
}

// Extracted for regression tests: day offset calculation used by calendar drag.
func calendarDayOffsetFromDragX(
    offsetX: CGFloat,
    daysCount: Int,
    contentWidth: CGFloat,
    dayWidth: CGFloat,
    daySpacing: CGFloat
) -> Int {
    if daysCount == 1 {
        // For single day view, support multi-page moves (including auto paging).
        // Keep a dead zone to avoid accidental day changes on tiny horizontal drift.
        let pageWidth = max(contentWidth, 1)
        let deadZone = pageWidth * 0.3
        if abs(offsetX) < deadZone {
            return 0
        }
        return Int((offsetX / pageWidth).rounded())
    }

    // For multi-day view, calculate based on day width
    return Int(round(offsetX / (dayWidth + daySpacing)))
}

// Extracted for regression tests: resolve the final moved range using the same Y-snap rule as drag preview.
func calendarDroppedRangeFromDrag(
    draggedRange: Event.TimeRange,
    dayOffsetFromDrag: Int,
    offsetY: CGFloat,
    hourHeight: CGFloat,
    isHorizontalAutoScrolling: Bool = false,
    snapIntervalSeconds: TimeInterval = 15 * 60,
    calendar: Calendar = .current
) -> Event.TimeRange {
    let shiftedStart = calendar.date(byAdding: .day, value: dayOffsetFromDrag, to: draggedRange.start) ?? draggedRange.start
    let shiftedEnd = calendar.date(byAdding: .day, value: dayOffsetFromDrag, to: draggedRange.end) ?? draggedRange.end
    let dayShiftedRange = Event.TimeRange(start: shiftedStart, end: shiftedEnd)

    guard hourHeight > 0 else { return dayShiftedRange }
    let rawOffsetSeconds = TimeInterval(offsetY / hourHeight * 3600)
    let displayOffsetSeconds = calendarPreviewOffsetSeconds(
        rawOffsetSeconds: rawOffsetSeconds,
        range: dayShiftedRange,
        isHorizontalAutoScrolling: isHorizontalAutoScrolling,
        snapIntervalSeconds: snapIntervalSeconds,
        calendar: calendar
    )

    return Event.TimeRange(
        start: dayShiftedRange.start.addingTimeInterval(displayOffsetSeconds),
        end: dayShiftedRange.end.addingTimeInterval(displayOffsetSeconds)
    )
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
    @State private var allDayOccurrencesCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
    @State private var dayRange: ClosedRange<Int> = CalendarLayout.defaultDayRange
    @State private var selectedEventForEdit: Event? = nil
    @State private var pendingRecurrenceEdit: (event: Event, date: Date)? = nil
    @State private var recurrenceEditScope: Event.RecurrenceEditScope? = nil
    @State private var showRecurrenceScopeDialog: Bool = false
    @State private var pendingCreateTimeRange: PendingEventCreation? = nil
    @State private var isShowingDatePicker: Bool = false
    @State private var datePickerSelection: Date = Date()
    @State private var timerRefreshCancellable: AnyCancellable?
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
            EditCalendarEventView(
                event: event,
                occurrenceDate: pendingRecurrenceEdit?.date,
                recurrenceScope: recurrenceEditScope
            )
            .environmentObject(store)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Edit Recurring Event",
            isPresented: $showRecurrenceScopeDialog,
            titleVisibility: .visible
        ) {
            Button("This Event") {
                recurrenceEditScope = .single
                selectedEventForEdit = pendingRecurrenceEdit?.event
            }
            Button("This & Future Events") {
                recurrenceEditScope = .following
                selectedEventForEdit = pendingRecurrenceEdit?.event
            }
            Button("All Events") {
                recurrenceEditScope = .all
                selectedEventForEdit = pendingRecurrenceEdit?.event
            }
            Button("Cancel", role: .cancel) {
                pendingRecurrenceEdit = nil
            }
        }
        .sheet(item: $pendingCreateTimeRange) { pending in
            CreateCalendarEventView(timeRange: pending.timeRange)
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingDatePicker) {
            DatePickerSheet(selection: $datePickerSelection) { selectedDate in
                let today = Calendar.current.startOfDay(for: Date())
                let target = Calendar.current.startOfDay(for: selectedDate)
                let dayOffset = Calendar.current.dateComponents([.day], from: today, to: target).day ?? 0
                expandDayRangeToInclude(dayOffset)
                isShowingDatePicker = false
                // Delay setting offset to ensure dayRange propagates first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    calendarState.selectedDayOffset = dayOffset
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            headerSubtitle = CalendarSubtitleStore.randomSubtitle()
            calendarState.selectedDayOffset = 0
            expandDayRangeToInclude(calendarState.selectedDayOffset)
            rebuildOccurrencesCache()
            updateTimerRefresh()
        }
        .onChange(of: store.calendarEvents) { _ in
            rebuildOccurrencesCache()
            updateTimerRefresh()
        }
        .onChange(of: calendarState.selectedDayOffset) { newValue in
            expandDayRangeIfNeeded(for: newValue)
            let visibleDate = Calendar.current.date(
                byAdding: .day,
                value: newValue,
                to: Calendar.current.startOfDay(for: Date())
            ) ?? Date()
            calendarDebugLog(
                "calendar.selectedDayOffset.changed",
                fields: [
                    "selectedDayOffset": "\(newValue)",
                    "visibleDate": calendarDebugDayString(visibleDate),
                    "dayRangeLower": "\(dayRange.lowerBound)",
                    "dayRangeUpper": "\(dayRange.upperBound)"
                ]
            )
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
            year: headerYear,
            mode: composition.headerMode,
            onTodayTapped: {
                datePickerSelection = Calendar.current.date(
                    byAdding: .day,
                    value: calendarState.selectedDayOffset,
                    to: Calendar.current.startOfDay(for: Date())
                ) ?? Date()
                isShowingDatePicker = true
            },
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
                    // Keep leading alignment with the page rhythm, but let the
                    // timeline content consume the trailing page inset.
                    .padding(.trailing, -metrics.horizontalPadding)
            }
            .padding(.top, composition.timelineTopPadding)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func timelineLayer(
        for mode: PageMode,
        range: RangeMode,
        rebuildKey: String
    ) -> some View {
        let timelineHourHeightBinding = Binding<CGFloat>(
            get: { calendarState.timelineHourHeight },
            set: { calendarState.setTimelineHourHeight($0) }
        )

        TimelineContainerView(
            occurrencesForOffset: { occurrencesCache[$0] ?? [] },
            allDayOccurrencesForOffset: { allDayOccurrencesCache[$0] ?? [] },
            selectedDayOffset: $calendarState.selectedDayOffset,
            rangeMode: $calendarState.rangeMode,
            hourHeight: timelineHourHeightBinding,
            mode: mode,
            dayRange: dayRange,
            previewCreation: pendingCreateTimeRange,
            onEventTap: { event, date in
                if event.isRecurringSeries {
                    pendingRecurrenceEdit = (event, date)
                    showRecurrenceScopeDialog = true
                } else {
                    selectedEventForEdit = event
                }
            },
            onEventDragEnded: { event, draggedRange, offset, dayColumnStep in
                handleEventDrag(
                    event: event,
                    draggedRange: draggedRange,
                    offset: offset,
                    dayColumnStep: dayColumnStep,
                    rangeMode: range
                )
            },
            onEventResizeEnded: { event, draggedRange, actionDate, dragMode, yOffset in
                handleEventResize(event: event, draggedRange: draggedRange, actionDate: actionDate, dragMode: dragMode, yOffset: yOffset)
            },
            onCreateEvent: { date, timeRange in
                handleCreateEvent(on: date, timeRange: timeRange)
            },
            onHourHeightCommit: {
                calendarState.commitTimelineHourHeight()
            }
        )
        // Rebuild when range changes to avoid stale TabView pages across layouts.
        .id(rebuildKey)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var headerYear: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .day, value: calendarState.selectedDayOffset, to: today) ?? today
        return Self.yearFormatter.string(from: date)
    }

    private func title(for range: RangeMode, offset: Int) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let focused = calendar.date(byAdding: .day, value: offset, to: today) ?? today

        switch range {
        case .day:
            // Jan 6, Monday
            let monthDay = Self.monthDayFormatter.string(from: focused)
            let weekday = Self.fullWeekdayFormatter.string(from: focused)
            return "\(monthDay), \(weekday)"
        case .threeDay:
            // Jan 6–8, Mon–Wed (focused day is centered in 3-day viewport)
            let start = calendar.date(byAdding: .day, value: -1, to: focused) ?? focused
            let end = calendar.date(byAdding: .day, value: 1, to: focused) ?? focused
            let startDay = calendar.component(.day, from: start)
            let endDay = calendar.component(.day, from: end)
            let startMonth = Self.monthFormatter.string(from: start)
            let endMonth = Self.monthFormatter.string(from: end)
            let startWeekday = Self.shortWeekdayFormatter.string(from: start)
            let endWeekday = Self.shortWeekdayFormatter.string(from: end)

            let dateRange = startMonth == endMonth
                ? "\(startMonth) \(startDay)–\(endDay)"
                : "\(startMonth) \(startDay)–\(endMonth) \(endDay)"
            return "\(dateRange), \(startWeekday)–\(endWeekday)"
        case .week:
            // Jan 5–11, Week 2 (focused day is centered in 7-day viewport)
            let start = calendar.date(byAdding: .day, value: -3, to: focused) ?? focused
            let end = calendar.date(byAdding: .day, value: 3, to: focused) ?? focused
            let week = calendar.component(.weekOfYear, from: focused)
            let startDay = calendar.component(.day, from: start)
            let endDay = calendar.component(.day, from: end)
            let startMonth = Self.monthFormatter.string(from: start)
            let endMonth = Self.monthFormatter.string(from: end)

            let dateRange = startMonth == endMonth
                ? "\(startMonth) \(startDay)–\(endDay)"
                : "\(startMonth) \(startDay)–\(endMonth) \(endDay)"
            return "\(dateRange), Week \(week)"
        }
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    private static let shortWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let fullWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
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
            store.calendarEvents,
            dayRange: dayRange
        )
        allDayOccurrencesCache = CalendarLayout.allDayOccurrencesByOffset(
            store.calendarEvents,
            dayRange: dayRange
        )
    }

    func updateTimerRefresh() {
        if store.activeTimerCalendarEvent != nil {
            // Only start if not already running
            guard timerRefreshCancellable == nil else { return }
            timerRefreshCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
                .autoconnect()
                .sink { [self] _ in
                    rebuildOccurrencesCache()
                }
        } else {
            timerRefreshCancellable?.cancel()
            timerRefreshCancellable = nil
        }
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

    func handleEventDrag(
        event: Event,
        draggedRange: Event.TimeRange,
        offset: DragOffset,
        dayColumnStep: CGFloat,
        rangeMode: RangeMode
    ) {
        let hourHeight = calendarState.timelineHourHeight
        let labelWidth: CGFloat = 36
        let daySpacing: CGFloat = 12
        let visibleDate = Calendar.current.date(
            byAdding: .day,
            value: calendarState.selectedDayOffset,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
        calendarDebugLog(
            "calendar.handleEventDrag.begin",
            fields: [
                "eventID": event.id.uuidString,
                "selectedDayOffset": "\(calendarState.selectedDayOffset)",
                "visibleDate": calendarDebugDayString(visibleDate),
                "rangeMode": String(describing: rangeMode),
                "draggedStart": calendarDebugInstantString(draggedRange.start),
                "draggedEnd": calendarDebugInstantString(draggedRange.end),
                "offsetX": String(format: "%.2f", offset.x),
                "offsetY": String(format: "%.2f", offset.y),
                "dayColumnStep": String(format: "%.2f", dayColumnStep)
            ]
        )

        // Calculate day width based on range mode and screen size.
        // Fall back to this for single-day where dayColumnStep is intentionally 0.
        let screenWidth = UIScreen.main.bounds.width
        let contentWidth = screenWidth - labelWidth
        let daysCount: Int
        switch rangeMode {
        case .day: daysCount = 1
        case .threeDay: daysCount = 3
        case .week: daysCount = 7
        }
        let dayOffsetFromDrag: Int
        if dayColumnStep > 0 {
            dayOffsetFromDrag = Int((offset.x / dayColumnStep).rounded())
        } else {
            let dayWidth = contentWidth
            dayOffsetFromDrag = calendarDayOffsetFromDragX(
                offsetX: offset.x,
                daysCount: daysCount,
                contentWidth: contentWidth,
                dayWidth: dayWidth,
                daySpacing: daySpacing
            )
        }

        let newRange = calendarDroppedRangeFromDrag(
            draggedRange: draggedRange,
            dayOffsetFromDrag: dayOffsetFromDrag,
            offsetY: offset.y,
            hourHeight: hourHeight
        )
        calendarDebugLog(
            "calendar.handleEventDrag.computed",
            fields: [
                "eventID": event.id.uuidString,
                "dayOffsetFromDrag": "\(dayOffsetFromDrag)",
                "newStart": calendarDebugInstantString(newRange.start),
                "newEnd": calendarDebugInstantString(newRange.end)
            ]
        )

        // For recurring series events, create a single exception via applyRecurringEdit
        if event.isRecurringSeries {
            let occurrenceDate = draggedRange.start
            store.applyRecurringEdit(
                seriesEvent: event,
                occurrenceDate: occurrenceDate,
                scope: .single
            ) { instance in
                instance.timeRanges = [newRange]
                instance.startTime = newRange.start
                instance.endTime = newRange.end
            }
            calendarDebugLog(
                "calendar.handleEventDrag.commitRecurring",
                fields: [
                    "eventID": event.id.uuidString,
                    "scope": "single",
                    "newStart": calendarDebugInstantString(newRange.start),
                    "newEnd": calendarDebugInstantString(newRange.end)
                ]
            )
            return
        }

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
        calendarDebugLog(
            "calendar.handleEventDrag.commit",
            fields: [
                "eventID": event.id.uuidString,
                "updatedFirstStart": updated.startTime.map(calendarDebugInstantString) ?? "nil",
                "updatedFirstEnd": updated.endTime.map(calendarDebugInstantString) ?? "nil",
                "timeRangesCount": "\(updated.timeRanges.count)"
            ]
        )
        store.updateCalendarEvent(updated)
    }

    func handleEventResize(event: Event, draggedRange: Event.TimeRange, actionDate: Date, dragMode: EventDragMode, yOffset: CGFloat) {
        let hourHeight = calendarState.timelineHourHeight
        let headerHeight: CGFloat = 0

        // Use actionDate (the day where user performed the resize) instead of draggedRange.start
        let originalDate = Calendar.current.startOfDay(for: actionDate)

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

        // For recurring series events, create a single exception
        if event.isRecurringSeries {
            let occurrenceDate = draggedRange.start
            store.applyRecurringEdit(
                seriesEvent: event,
                occurrenceDate: occurrenceDate,
                scope: .single
            ) { instance in
                instance.timeRanges = [newRange]
                instance.startTime = newRange.start
                instance.endTime = newRange.end
            }
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
        store.updateCalendarEvent(updated)
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

// MARK: - Date Picker Sheet

private struct DatePickerSheet: View {
    @Binding var selection: Date
    var onConfirm: (Date) -> Void

    private var yearTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: selection)
    }

    var body: some View {
        NavigationStack {
            DatePicker(
                "Select Date",
                selection: $selection,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle(yearTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        onConfirm(selection)
                    }
                }
            }
        }
    }
}
