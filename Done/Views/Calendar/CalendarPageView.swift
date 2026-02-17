//
//  CalendarPageView.swift
//  Done
//
//  Calendar page with Apple-style header and focused event editing.
//

import SwiftUI
import Combine
import UIKit

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

func calendarVisibleDatesForRange(
    selectedDayOffset: Int,
    rangeMode: RangeMode,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> [Date] {
    let today = calendar.startOfDay(for: referenceDate)
    let center = calendar.date(byAdding: .day, value: selectedDayOffset, to: today) ?? today

    let offsets: [Int]
    switch rangeMode {
    case .day:
        offsets = [0]
    case .threeDay:
        offsets = [-1, 0, 1]
    case .week:
        offsets = [-3, -2, -1, 0, 1, 2, 3]
    }

    return offsets.compactMap { offset in
        calendar.date(byAdding: .day, value: offset, to: center)
    }
}

func calendarLegendTitle(
    selectedDayOffset: Int,
    rangeMode: RangeMode,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> String {
    let dates = calendarVisibleDatesForRange(
        selectedDayOffset: selectedDayOffset,
        rangeMode: rangeMode,
        referenceDate: referenceDate,
        calendar: calendar
    )
    let centerIndex = dates.count / 2
    guard dates.indices.contains(centerIndex) else {
        return CalendarLegendFormatters.monthDayWeekday.string(from: referenceDate)
    }
    let center = dates[centerIndex]

    switch rangeMode {
    case .day:
        return CalendarLegendFormatters.monthDayWeekday.string(from: center)
    case .threeDay:
        guard let start = dates.first, let end = dates.last else {
            return CalendarLegendFormatters.monthDayWeekday.string(from: center)
        }
        let startMonth = CalendarLegendFormatters.shortMonth.string(from: start)
        let endMonth = CalendarLegendFormatters.shortMonth.string(from: end)
        let startDay = calendar.component(.day, from: start)
        let endDay = calendar.component(.day, from: end)
        let startWeekday = CalendarLegendFormatters.shortWeekday.string(from: start)
        let endWeekday = CalendarLegendFormatters.shortWeekday.string(from: end)
        let dateRange = startMonth == endMonth
            ? "\(startMonth) \(startDay)-\(endDay)"
            : "\(startMonth) \(startDay)-\(endMonth) \(endDay)"
        return "\(dateRange), \(startWeekday)-\(endWeekday)"
    case .week:
        guard let start = dates.first, let end = dates.last else {
            return CalendarLegendFormatters.monthDayWeekday.string(from: center)
        }
        let startMonth = CalendarLegendFormatters.shortMonth.string(from: start)
        let endMonth = CalendarLegendFormatters.shortMonth.string(from: end)
        let startDay = calendar.component(.day, from: start)
        let endDay = calendar.component(.day, from: end)
        let week = calendar.component(.weekOfYear, from: center)
        let dateRange = startMonth == endMonth
            ? "\(startMonth) \(startDay)-\(endDay)"
            : "\(startMonth) \(startDay)-\(endMonth) \(endDay)"
        return "\(dateRange), Week \(week)"
    }
}

func calendarHeaderCollapseProgress(
    scrollY: CGFloat,
    start: CGFloat = 8,
    end: CGFloat = 88
) -> CGFloat {
    let normalizedScrollY = scrollY.isFinite ? max(0, scrollY) : 0
    let normalizedStart = start.isFinite ? start : 8
    let normalizedEnd = end.isFinite ? end : 88
    let clampedStart = max(0, min(normalizedStart, normalizedEnd))
    let clampedEnd = max(clampedStart + 1, normalizedEnd)
    return clamp((normalizedScrollY - clampedStart) / (clampedEnd - clampedStart), 0, 1)
}

func calendarCapsuleVisibleHeight(
    collapseProgress: CGFloat,
    expandedHeight: CGFloat = 52
) -> CGFloat {
    let normalizedExpandedHeight = expandedHeight.isFinite ? max(0, expandedHeight) : 52
    let normalizedCollapseProgress = collapseProgress.isFinite ? collapseProgress : 0
    let progress = clamp(normalizedCollapseProgress, 0, 1)
    return lerp(normalizedExpandedHeight, 0, progress)
}

func calendarTopOverlayInset(
    safeAreaTop: CGFloat,
    collapseProgress: CGFloat,
    legendBandHeight: CGFloat = 34,
    overlayGap: CGFloat = 6,
    capsuleExpandedHeight: CGFloat = 52
) -> CGFloat {
    let normalizedSafeAreaTop = safeAreaTop.isFinite ? max(0, safeAreaTop) : 0
    let normalizedLegendBandHeight = legendBandHeight.isFinite ? max(0, legendBandHeight) : 0
    let normalizedOverlayGap = overlayGap.isFinite ? max(0, overlayGap) : 0
    let capsuleVisibleHeight = calendarCapsuleVisibleHeight(
        collapseProgress: collapseProgress,
        expandedHeight: capsuleExpandedHeight
    )

    let inset = normalizedSafeAreaTop + normalizedLegendBandHeight + capsuleVisibleHeight + normalizedOverlayGap
    return inset.isFinite ? inset : normalizedSafeAreaTop + normalizedLegendBandHeight + normalizedOverlayGap
}

func calendarOverlayFadeMaskStart(totalHeight: CGFloat, fadeHeight: CGFloat) -> CGFloat {
    let normalizedTotalHeight = totalHeight.isFinite ? max(0, totalHeight) : 0
    let normalizedFadeHeight = fadeHeight.isFinite ? max(0, fadeHeight) : 0
    guard normalizedTotalHeight > 0 else { return 1 }
    guard normalizedFadeHeight > 0 else { return 1 }
    let start = (normalizedTotalHeight - normalizedFadeHeight) / normalizedTotalHeight
    return clamp(start, 0, 1)
}

func calendarResolvedSafeAreaInset(proxyInset: CGFloat, windowInset: CGFloat) -> CGFloat {
    let normalizedProxyInset = proxyInset.isFinite ? max(0, proxyInset) : 0
    let normalizedWindowInset = windowInset.isFinite ? max(0, windowInset) : 0
    return max(normalizedProxyInset, normalizedWindowInset)
}

func calendarOccurrenceIDForRange(
    event: Event,
    range: Event.TimeRange,
    occurrenceDate: Date? = nil,
    calendar: Calendar = .current
) -> String {
    if event.isRecurringSeries {
        let anchorDate = occurrenceDate ?? range.start
        let dayTimestamp = Int(calendar.startOfDay(for: anchorDate).timeIntervalSince1970)
        return "\(event.id.uuidString)-recur-\(dayTimestamp)"
    }
    if event.timerStartedAt != nil {
        return "\(event.id.uuidString)-timer"
    }
    return "\(event.id.uuidString)-\(range.start.timeIntervalSince1970)-\(range.end.timeIntervalSince1970)"
}

func calendarRangesApproximatelyEqual(
    lhs: Event.TimeRange,
    rhs: Event.TimeRange,
    tolerance: TimeInterval = 0.5
) -> Bool {
    abs(lhs.start.timeIntervalSince(rhs.start)) <= tolerance
        && abs(lhs.end.timeIntervalSince(rhs.end)) <= tolerance
}

private func calendarWindowSafeAreaInsets() -> UIEdgeInsets {
    let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = windowScenes.flatMap(\.windows)
    let keyWindow = windows.first(where: \.isKeyWindow) ?? windows.first
    return keyWindow?.safeAreaInsets ?? .zero
}

private func calendarRangeHintFromOccurrenceID(_ occurrenceID: String?) -> Event.TimeRange? {
    guard let occurrenceID else { return nil }
    let parts = occurrenceID.split(separator: "-")
    guard parts.count >= 2 else { return nil }
    guard let startTimestamp = Double(parts[parts.count - 2]),
          let endTimestamp = Double(parts[parts.count - 1]) else { return nil }
    let start = Date(timeIntervalSince1970: startTimestamp)
    let end = Date(timeIntervalSince1970: endTimestamp)
    guard end >= start else { return nil }
    return Event.TimeRange(start: start, end: end)
}

func calendarUpdatedRangesAfterDrop(
    existingRanges: [Event.TimeRange],
    draggedRange: Event.TimeRange,
    droppedRange: Event.TimeRange,
    occurrenceID: String?
) -> [Event.TimeRange] {
    guard !existingRanges.isEmpty else { return [droppedRange] }
    var ranges = existingRanges

    var targetIndex = ranges.firstIndex { range in
        range.start == draggedRange.start && range.end == draggedRange.end
    }

    if targetIndex == nil, let hintedRange = calendarRangeHintFromOccurrenceID(occurrenceID) {
        targetIndex = ranges.firstIndex { range in
            abs(range.start.timeIntervalSince(hintedRange.start)) < 0.5
                && abs(range.end.timeIntervalSince(hintedRange.end)) < 0.5
        }
    }

    if targetIndex == nil {
        targetIndex = ranges.enumerated().min(by: { lhs, rhs in
            let lhsDistance = abs(lhs.element.start.timeIntervalSince(draggedRange.start))
                + abs(lhs.element.end.timeIntervalSince(draggedRange.end))
            let rhsDistance = abs(rhs.element.start.timeIntervalSince(draggedRange.start))
                + abs(rhs.element.end.timeIntervalSince(draggedRange.end))
            return lhsDistance < rhsDistance
        })?.offset
    }

    if let targetIndex {
        ranges[targetIndex] = droppedRange
    } else {
        ranges.append(droppedRange)
    }

    return ranges.sorted { $0.start < $1.start }
}

private enum CalendarLegendFormatters {
    static let shortMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    static let shortWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    static let monthDayWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, EEEE"
        return formatter
    }()
}

/// 功能： Hosts the calendar page layout and binds state/composition to views.
struct CalendarPageView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var calendarState: CalendarViewState

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
    @State private var focusedEventID: UUID? = nil
    @State private var focusedOccurrenceID: String? = nil
    @State private var isShowingAgent: Bool = false
    @State private var showSearchPlaceholderAlert: Bool = false
    @State private var timelineVerticalScrollY: CGFloat = 0
    @State private var headerCollapseProgress: CGFloat = 0

    private let dayRangeExpansionStep: Int = 30
    private let dayRangeExpansionThreshold: Int = 14
    private let dayRangeExpansionBuffer: Int = 14
    private let topOverlayGap: CGFloat = 6
    private let topOverlayLegendBandHeight: CGFloat = 34
    private let topOverlayCapsuleExpandedHeight: CGFloat = 52
    private let topOverlayBottomFadeHeight: CGFloat = 12
    private let topOverlayMaterialOpacity: CGFloat = 0.82
    private let dateLegendBarBottomPadding: CGFloat = 4
    private let dateLegendVerticalNudge: CGFloat = -6

    var body: some View {
        GeometryReader { proxy in
            let windowSafeAreaInsets = calendarWindowSafeAreaInsets()
            let safeAreaTop = calendarResolvedSafeAreaInset(
                proxyInset: proxy.safeAreaInsets.top,
                windowInset: windowSafeAreaInsets.top
            )
            let safeAreaBottom = calendarResolvedSafeAreaInset(
                proxyInset: proxy.safeAreaInsets.bottom,
                windowInset: windowSafeAreaInsets.bottom
            )
            let metrics = CalendarPageMetrics(
                containerSize: proxy.size,
                safeAreaTop: safeAreaTop,
                safeAreaBottom: safeAreaBottom
            )
            let topOverlayInset = calendarTopOverlayInset(
                safeAreaTop: metrics.safeAreaTop,
                collapseProgress: headerCollapseProgress,
                legendBandHeight: topOverlayLegendBandHeight,
                overlayGap: topOverlayGap,
                capsuleExpandedHeight: topOverlayCapsuleExpandedHeight
            )

            ZStack(alignment: .top) {
                timelineScroll(
                    metrics: metrics,
                    topOverlayInset: topOverlayInset
                )

                topOverlay(metrics: metrics)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
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
                let dayOffset = dayOffset(for: selectedDate)
                expandDayRangeToInclude(dayOffset)
                isShowingDatePicker = false
                calendarState.selectedDayOffset = dayOffset
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("Search", isPresented: $showSearchPlaceholderAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Search will be available in a future update.")
        }
        .sheet(isPresented: $isShowingAgent) {
            NavigationStack {
                AgentChatView()
                    .environmentObject(store)
            }
        }
        .onAppear {
            calendarState.selectedDayOffset = 0
            expandDayRangeToInclude(calendarState.selectedDayOffset)
            rebuildOccurrencesCache()
            updateTimerRefresh()
            timelineVerticalScrollY = 0
            headerCollapseProgress = 0
        }
        .onChange(of: store.calendarEvents) { _ in
            rebuildOccurrencesCache()
            updateTimerRefresh()
            if let focusedEventID,
               !store.calendarEvents.contains(where: { $0.id == focusedEventID }) {
                clearFocus()
            }
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
    @ViewBuilder
    func topOverlay(metrics: CalendarPageMetrics) -> some View {
        let overlayHeight = calendarTopOverlayInset(
            safeAreaTop: metrics.safeAreaTop,
            collapseProgress: headerCollapseProgress,
            legendBandHeight: topOverlayLegendBandHeight,
            overlayGap: topOverlayGap,
            capsuleExpandedHeight: topOverlayCapsuleExpandedHeight
        ) + dateLegendBarBottomPadding
        let fadeStart = calendarOverlayFadeMaskStart(
            totalHeight: overlayHeight,
            fadeHeight: topOverlayBottomFadeHeight
        )

        VStack(spacing: 0) {
            if calendarState.rangeMode == .day {
                header(metrics: metrics)
                dayCenteredLegendBar(metrics: metrics)
            } else {
                header(metrics: metrics)
                dateLegendBar(metrics: metrics)
                    .offset(y: dateLegendVerticalNudge)
            }
        }
        .padding(.top, metrics.safeAreaTop + topOverlayGap)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(topOverlayMaterialOpacity)
                .frame(maxWidth: .infinity)
                .frame(height: overlayHeight, alignment: .top)
                .mask(alignment: .top) {
                    if fadeStart >= 1 {
                        Rectangle().fill(Color.black)
                    } else {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: fadeStart),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
        }
    }
}

private extension CalendarPageView {
    func header(metrics: CalendarPageMetrics) -> some View {
        let selectedDate = visibleDate
        let leftCapsuleTitle = calendarLegendTitle(
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode
        )

        return AppleCalendarHeaderView(
            selectedDate: selectedDate,
            rangeMode: calendarState.rangeMode,
            leftCapsuleTitle: leftCapsuleTitle,
            collapseProgress: headerCollapseProgress,
            onMonthTap: {
                clearFocus()
                datePickerSelection = selectedDate
                isShowingDatePicker = true
            },
            onSelectRangeMode: { mode in
                clearFocus()
                calendarState.rangeMode = mode
            },
            onAgentTap: {
                clearFocus()
                isShowingAgent = true
            },
            onSearchTap: {
                clearFocus()
                showSearchPlaceholderAlert = true
            },
            onAddTap: {
                clearFocus()
                let range = defaultQuickAddTimeRange()
                pendingCreateTimeRange = PendingEventCreation(date: range.start, timeRange: range)
            }
        )
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(
            height: calendarCapsuleVisibleHeight(
                collapseProgress: headerCollapseProgress
            ),
            alignment: .top
        )
    }

    @ViewBuilder
    func dayCenteredLegendBar(metrics: CalendarPageMetrics) -> some View {
        let visibleDates = calendarVisibleDatesForRange(
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode
        )
        let date = visibleDates.first ?? visibleDate

        VStack(spacing: 2) {
            Text(Self.dateLegendWeekdayFormatter.string(from: date).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(Self.dateLegendDayFormatter.string(from: date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
        .padding(.bottom, dateLegendBarBottomPadding)
        .contentShape(Rectangle())
        .onTapGesture {
            clearFocus()
        }
    }

    @ViewBuilder
    func dateLegendBar(metrics: CalendarPageMetrics) -> some View {
        let visibleDates = calendarVisibleDatesForRange(
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode
        )
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width - metrics.horizontalPadding * 2)
            let labelWidth: CGFloat = 32
            let timelineEdgePadding: CGFloat = 6
            let daySpacing: CGFloat = 12
            let daysCount = max(1, visibleDates.count)
            let dayAreaWidth = max(0, totalWidth - timelineEdgePadding * 2 - labelWidth)
            let spacing = daysCount == 1 ? CGFloat(0) : daySpacing
            let dayWidth = daysCount == 1
                ? dayAreaWidth
                : max(0, (dayAreaWidth - spacing * CGFloat(daysCount - 1)) / CGFloat(daysCount))

            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 30)
                HStack(spacing: spacing) {
                    ForEach(Array(visibleDates.enumerated()), id: \.offset) { entry in
                        let date = entry.element
                        VStack(spacing: 2) {
                            Text(Self.dateLegendWeekdayFormatter.string(from: date).uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(Self.dateLegendDayFormatter.string(from: date))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(width: dayWidth, height: 30)
                    }
                }
            }
            .padding(.horizontal, metrics.horizontalPadding + timelineEdgePadding)
            .frame(width: proxy.size.width, height: 30, alignment: .leading)
        }
        .frame(height: 30)
        .padding(.bottom, dateLegendBarBottomPadding)
        .contentShape(Rectangle())
        .onTapGesture {
            clearFocus()
        }
    }

    func timelineScroll(metrics: CalendarPageMetrics, topOverlayInset: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                timelineLayer(rebuildKey: "timeline-\(calendarState.rangeMode)")
                    // Keep leading alignment with the page rhythm, but let the
                    // timeline content consume the trailing page inset.
                    .padding(.trailing, -metrics.horizontalPadding)
            }
            .padding(.top, topOverlayInset)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.bottom, metrics.timelineBottomScrollPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
            timelineVerticalScrollY = newValue.contentOffset.y
            headerCollapseProgress = calendarHeaderCollapseProgress(scrollY: newValue.contentOffset.y)
        }
        .mask {
            TimelineMaskView(
                top: metrics.topMaskConfig,
                bottom: metrics.bottomMaskConfig
            )
        }
    }

    @ViewBuilder
    func timelineLayer(rebuildKey: String) -> some View {
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
            mode: .preview,
            dayRange: dayRange,
            previewCreation: pendingCreateTimeRange,
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
            onEventTap: { event, date in
                if event.isRecurringSeries {
                    pendingRecurrenceEdit = (event, date)
                    showRecurrenceScopeDialog = true
                } else {
                    selectedEventForEdit = event
                }
            },
            onEventLongPressBegan: { event, occurrenceID, _, _ in
                setFocus(event: event, occurrenceID: occurrenceID)
            },
            onEventDragEnded: { event, occurrenceID, draggedRange, offset, dayColumnStep in
                handleEventDrag(
                    event: event,
                    occurrenceID: occurrenceID,
                    draggedRange: draggedRange,
                    offset: offset,
                    dayColumnStep: dayColumnStep,
                    rangeMode: calendarState.rangeMode
                )
            },
            onEventResizeEnded: { event, draggedRange, actionDate, dragMode, yOffset in
                handleEventResize(
                    event: event,
                    draggedRange: draggedRange,
                    actionDate: actionDate,
                    dragMode: dragMode,
                    yOffset: yOffset
                )
            },
            onCreateEvent: { date, timeRange in
                handleCreateEvent(on: date, timeRange: timeRange)
            },
            onNonEventTap: {
                clearFocus()
            },
            onHourHeightCommit: {
                calendarState.commitTimelineHourHeight()
            }
        )
        // Rebuild when range changes to avoid stale TabView pages across layouts.
        .id(rebuildKey)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var visibleDate: Date {
        Calendar.current.date(
            byAdding: .day,
            value: calendarState.selectedDayOffset,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
    }

    func dayOffset(for date: Date) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        let target = Calendar.current.startOfDay(for: date)
        return Calendar.current.dateComponents([.day], from: today, to: target).day ?? 0
    }

    func clearFocus() {
        focusedEventID = nil
        focusedOccurrenceID = nil
    }

    func setFocus(event: Event, occurrenceID: String?) {
        focusedEventID = event.id
        focusedOccurrenceID = occurrenceID
    }

    func defaultQuickAddTimeRange() -> Event.TimeRange {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: visibleDate)
        let now = Date()

        let timeSource = calendar.isDate(selectedDay, inSameDayAs: now)
            ? now
            : calendar.date(
                bySettingHour: calendar.component(.hour, from: now),
                minute: calendar.component(.minute, from: now),
                second: 0,
                of: selectedDay
            ) ?? selectedDay

        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timeSource)
        let minute = components.minute ?? 0
        let remainder = minute % 15
        if remainder != 0 {
            components.minute = minute + (15 - remainder)
        }
        components.second = 0

        let start = calendar.date(from: components) ?? timeSource
        let end = start.addingTimeInterval(3600)
        return Event.TimeRange(start: start, end: end)
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
        occurrenceID: String?,
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
                "occurrenceID": occurrenceID ?? "nil",
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
            let calendar = Calendar.current
            let occurrenceDay = calendar.startOfDay(for: draggedRange.start)
            let movedException = store.calendarEvents.last { candidate in
                candidate.recurrenceParentId == event.id
                    && candidate.recurrenceInstanceDate.map { calendar.isDate($0, inSameDayAs: occurrenceDay) } == true
                    && candidate.effectiveTimeRanges.contains {
                        calendarRangesApproximatelyEqual(lhs: $0, rhs: newRange)
                    }
            }
            if let movedException {
                let focusedRange = movedException.effectiveTimeRanges.first ?? newRange
                let focusedOccurrenceID = movedException.effectiveTimeRanges.contains {
                    calendarRangesApproximatelyEqual(lhs: $0, rhs: focusedRange)
                } ? calendarOccurrenceIDForRange(
                    event: movedException,
                    range: focusedRange,
                    calendar: calendar
                ) : nil
                setFocus(event: movedException, occurrenceID: focusedOccurrenceID)
            } else {
                let fallbackOccurrenceID = calendarOccurrenceIDForRange(
                    event: event,
                    range: newRange,
                    occurrenceDate: draggedRange.start,
                    calendar: calendar
                )
                setFocus(event: event, occurrenceID: fallbackOccurrenceID)
            }
            return
        }

        // Update only the dragged range, preserve other ranges
        var updated = event
        let existingRanges = updated.timeRanges.isEmpty ? updated.effectiveTimeRanges : updated.timeRanges
        let ranges = calendarUpdatedRangesAfterDrop(
            existingRanges: existingRanges,
            draggedRange: draggedRange,
            droppedRange: newRange,
            occurrenceID: occurrenceID
        )
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
        let focusedOccurrenceID = updated.effectiveTimeRanges.contains {
            calendarRangesApproximatelyEqual(lhs: $0, rhs: newRange)
        } ? calendarOccurrenceIDForRange(
            event: updated,
            range: newRange
        ) : nil
        setFocus(event: updated, occurrenceID: focusedOccurrenceID)
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
        let existingRanges = updated.timeRanges.isEmpty ? updated.effectiveTimeRanges : updated.timeRanges
        let ranges = calendarUpdatedRangesAfterDrop(
            existingRanges: existingRanges,
            draggedRange: draggedRange,
            droppedRange: newRange,
            occurrenceID: nil
        )
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

    static let dateLegendWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    static let dateLegendDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
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
