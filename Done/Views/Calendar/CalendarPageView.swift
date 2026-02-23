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

private struct ActiveCrossSurfaceDrag {
    var event: Event
    var locationInWindow: CGPoint
    var translation: CGSize
}

struct CollapsedTodoMarkerLane: Equatable {
    let dayOffset: Int
    let colorKeys: [String]
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

func calendarLegendTrackOffsets(
    anchor: Int,
    visibleCount: Int,
    overscan: Int = 1
) -> [Int] {
    let safeVisibleCount = max(1, visibleCount)
    let safeOverscan = max(0, overscan)
    let centerIndex = calendarCenterSlotIndex(daysCount: safeVisibleCount)
    let trailingCount = max(0, safeVisibleCount - centerIndex - 1)
    let start = -(centerIndex + safeOverscan)
    let end = trailingCount + safeOverscan
    return Array(start...end).map { anchor + $0 }
}

func calendarLegendTrackTranslation(
    fraction: CGFloat,
    dayStep: CGFloat
) -> CGFloat {
    guard dayStep > 0 else { return 0 }
    let normalizedFraction = clamp(fraction, 0, 1)
    return -(normalizedFraction * dayStep)
}

func calendarNextHeaderCapsuleVisibility(
    scrollY: CGFloat,
    currentlyVisible: Bool,
    hideThreshold: CGFloat = 64,
    showThreshold: CGFloat = 52
) -> Bool {
    let normalizedScrollY = scrollY.isFinite ? max(0, scrollY) : 0
    let normalizedHideThreshold = hideThreshold.isFinite ? max(0, hideThreshold) : 64
    let normalizedShowThreshold = showThreshold.isFinite ? max(0, showThreshold) : 52
    let effectiveShowThreshold = min(normalizedShowThreshold, normalizedHideThreshold)

    if currentlyVisible, normalizedScrollY >= normalizedHideThreshold {
        return false
    }
    if !currentlyVisible, normalizedScrollY <= effectiveShowThreshold {
        return true
    }
    return currentlyVisible
}

func calendarCapsuleVisibleHeight(
    isVisible: Bool,
    expandedHeight: CGFloat = 52
) -> CGFloat {
    let normalizedExpandedHeight = expandedHeight.isFinite ? max(0, expandedHeight) : 52
    return isVisible ? normalizedExpandedHeight : 0
}

func calendarTopOverlayInset(
    safeAreaTop: CGFloat,
    isCapsuleVisible: Bool,
    legendBandHeight: CGFloat = 34,
    overlayGap: CGFloat = 6,
    capsuleExpandedHeight: CGFloat = 52
) -> CGFloat {
    let normalizedSafeAreaTop = safeAreaTop.isFinite ? max(0, safeAreaTop) : 0
    let normalizedLegendBandHeight = legendBandHeight.isFinite ? max(0, legendBandHeight) : 0
    let normalizedOverlayGap = overlayGap.isFinite ? max(0, overlayGap) : 0
    let capsuleVisibleHeight = calendarCapsuleVisibleHeight(
        isVisible: isCapsuleVisible,
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

func calendarShouldRevealTodoPanel(
    pullDistance: CGFloat,
    threshold: CGFloat = 96
) -> Bool {
    let normalizedPull = pullDistance.isFinite ? max(0, pullDistance) : 0
    let normalizedThreshold = threshold.isFinite ? max(0, threshold) : 96
    return normalizedPull >= normalizedThreshold
}

func calendarTodoRevealExpandedHeight(
    visibleContentHeight: CGFloat,
    fraction: CGFloat = 0.5
) -> CGFloat {
    let normalizedVisibleContentHeight = visibleContentHeight.isFinite ? max(0, visibleContentHeight) : 0
    let normalizedFraction = fraction.isFinite ? max(0, fraction) : 0.5
    return max(0, normalizedVisibleContentHeight * normalizedFraction)
}

func calendarTodoDrawerHalfPageCapHeight(
    visibleContentHeight: CGFloat,
    fraction: CGFloat = 0.5
) -> CGFloat {
    calendarTodoRevealExpandedHeight(
        visibleContentHeight: visibleContentHeight,
        fraction: fraction
    )
}

func calendarTodoDrawerBlockHeight(
    durationMinutes: Int,
    timelineHourHeight: CGFloat,
    compression: CGFloat = 0.32,
    minBlockHeight: CGFloat = 18,
    maxBlockHeight: CGFloat = 88
) -> CGFloat {
    let safeMinutes = max(1, durationMinutes)
    let safeHourHeight = timelineHourHeight.isFinite ? max(CGFloat(1), timelineHourHeight) : 56
    let safeCompression = compression.isFinite ? max(CGFloat(0), compression) : 0.32
    let safeMin = minBlockHeight.isFinite ? max(CGFloat(0), minBlockHeight) : 18
    let safeMax = maxBlockHeight.isFinite ? max(safeMin, maxBlockHeight) : max(safeMin, 88)
    let compressedHourHeight = safeHourHeight * safeCompression
    let rawHeight = CGFloat(safeMinutes) / 60 * compressedHourHeight
    return clamp(rawHeight, safeMin, safeMax)
}

func calendarTodoDrawerContentHeight(
    slotDurationMinutes: [[Int]],
    timelineHourHeight: CGFloat,
    slotHeaderHeight: CGFloat = 22,
    slotVerticalPadding: CGFloat = 8,
    slotInnerSpacing: CGFloat = 6,
    rowSpacing: CGFloat = 6,
    emptyLaneHeight: CGFloat = 20
) -> CGFloat {
    let safeSlotHeaderHeight = slotHeaderHeight.isFinite ? max(0, slotHeaderHeight) : 22
    let safeSlotVerticalPadding = slotVerticalPadding.isFinite ? max(0, slotVerticalPadding) : 8
    let safeSlotInnerSpacing = slotInnerSpacing.isFinite ? max(0, slotInnerSpacing) : 6
    let safeRowSpacing = rowSpacing.isFinite ? max(0, rowSpacing) : 6
    let safeEmptyLaneHeight = emptyLaneHeight.isFinite ? max(0, emptyLaneHeight) : 20

    let laneHeights: [CGFloat] = slotDurationMinutes.map { durations in
        let bodyHeight: CGFloat
        if durations.isEmpty {
            bodyHeight = safeEmptyLaneHeight
        } else {
            let blockHeights = durations.map {
                calendarTodoDrawerBlockHeight(
                    durationMinutes: $0,
                    timelineHourHeight: timelineHourHeight
                )
            }
            bodyHeight = blockHeights.reduce(0, +) + safeRowSpacing * CGFloat(max(0, blockHeights.count - 1))
        }
        return safeSlotVerticalPadding * 2 + safeSlotHeaderHeight + safeSlotInnerSpacing + bodyHeight
    }

    return laneHeights.max() ?? (safeSlotVerticalPadding * 2 + safeSlotHeaderHeight + safeSlotInnerSpacing + safeEmptyLaneHeight)
}

func calendarTodoDrawerTargetExpandedHeight(
    contentHeight: CGFloat,
    halfPageCapHeight: CGFloat,
    minimumHeight: CGFloat = 96
) -> CGFloat {
    let safeContentHeight = contentHeight.isFinite ? max(0, contentHeight) : 0
    let safeHalfPageCapHeight = halfPageCapHeight.isFinite ? max(0, halfPageCapHeight) : 0
    let safeMinimumHeight = minimumHeight.isFinite ? max(0, minimumHeight) : 96
    return max(safeMinimumHeight, min(safeContentHeight, safeHalfPageCapHeight))
}

func calendarShouldShowCollapsedTodoMarkers(
    isDrawerPresented: Bool,
    hasViewedDrawer: Bool,
    hasVisibleTodos: Bool
) -> Bool {
    !isDrawerPresented && hasViewedDrawer && hasVisibleTodos
}

func calendarCollapsedTodoMarkersForVisibleDates(
    visibleDayOffsets: [Int],
    plannedEventsByDayOffset: [Int: [Event]],
    maxMarkersPerLane: Int = 4
) -> [CollapsedTodoMarkerLane] {
    let safeMaxMarkersPerLane = max(1, maxMarkersPerLane)
    return visibleDayOffsets.map { dayOffset in
        let events = plannedEventsByDayOffset[dayOffset] ?? []
        let colors = events.prefix(safeMaxMarkersPerLane).map(\.type)
        return CollapsedTodoMarkerLane(dayOffset: dayOffset, colorKeys: colors)
    }
}

func calendarTodoMarkerTapTargetSelectedDayOffset(
    tappedDayOffset: Int,
    dayRange: ClosedRange<Int>? = nil
) -> Int {
    guard let dayRange else { return tappedDayOffset }
    return clamp(tappedDayOffset, to: dayRange)
}

func calendarTodoRevealInteractiveHeight(
    pullDistance: CGFloat,
    threshold: CGFloat = 96,
    maxHeight: CGFloat
) -> CGFloat {
    let normalizedPullDistance = pullDistance.isFinite ? max(0, pullDistance) : 0
    let normalizedThreshold = threshold.isFinite ? max(0, threshold) : 96
    let normalizedMaxHeight = maxHeight.isFinite ? max(0, maxHeight) : 0
    guard normalizedPullDistance >= normalizedThreshold else { return 0 }
    return min(normalizedMaxHeight, normalizedPullDistance - normalizedThreshold)
}

func calendarTodoRevealDisplayHeight(
    isPresented: Bool,
    expandedHeight: CGFloat,
    interactiveHeight: CGFloat,
    panelDragY: CGFloat
) -> CGFloat {
    let normalizedExpandedHeight = expandedHeight.isFinite ? max(0, expandedHeight) : 0
    let normalizedInteractiveHeight = interactiveHeight.isFinite ? max(0, interactiveHeight) : 0
    let normalizedPanelDragY = panelDragY.isFinite ? panelDragY : 0

    if isPresented {
        return max(0, normalizedExpandedHeight + min(0, normalizedPanelDragY))
    }
    return normalizedInteractiveHeight
}

func calendarShouldCloseTodoPanel(
    translationY: CGFloat,
    threshold: CGFloat = 72
) -> Bool {
    let normalizedThreshold = threshold.isFinite ? max(0, threshold) : 72
    let upwardDistance = max(0, -translationY)
    return upwardDistance >= normalizedThreshold
}

func calendarResolveTodoDurationFromCreationDrag(
    dragDeltaY: CGFloat,
    hourHeight: CGFloat,
    minimumMinutes: Int = 15,
    stepMinutes: Int = 15
) -> Int {
    let safeHourHeight = hourHeight.isFinite ? max(hourHeight, 1) : 56
    let safeMinimum = max(1, minimumMinutes)
    let safeStep = max(1, stepMinutes)
    let rawMinutes = Int((abs(dragDeltaY) / safeHourHeight * 60).rounded())
    let snappedMinutes = max(safeMinimum, ((rawMinutes + safeStep / 2) / safeStep) * safeStep)
    return snappedMinutes
}

func calendarMapTimelineDropToStartDate(
    dropLocation: CGPoint,
    geometry: TimelineDropGeometry,
    referenceDate: Date = Date(),
    calendar: Calendar = .current,
    snapMinutes: Int = 15
) -> Date? {
    let contentFrame = geometry.dropContentGlobalFrame
    guard contentFrame.contains(dropLocation) else { return nil }
    guard geometry.daysCount > 0 else { return nil }
    let daySpacing = geometry.daysCount == 1 ? 0 : max(0, geometry.daySpacing)
    let dayStep = max(1, geometry.dayWidth + daySpacing)

    let localX = dropLocation.x - contentFrame.minX
    let rawIndex = Int(floor(localX / dayStep))
    let dayIndex = clamp(rawIndex, to: 0...max(0, geometry.daysCount - 1))
    let dayOffset = geometry.leadingDayOffset + dayIndex

    let localY = dropLocation.y - contentFrame.minY
    let slotY = max(0, localY - geometry.headerHeight)
    let minutesFloat = slotY / max(1, geometry.hourHeight) * 60
    let safeSnap = max(1, snapMinutes)
    var snappedMinutes = Int((minutesFloat / CGFloat(safeSnap)).rounded()) * safeSnap
    snappedMinutes = clamp(snappedMinutes, to: 0...(24 * 60 - safeSnap))

    let dayDate = calendar.date(
        byAdding: .day,
        value: dayOffset,
        to: calendar.startOfDay(for: referenceDate)
    ) ?? referenceDate
    return calendar.date(
        byAdding: .minute,
        value: snappedMinutes,
        to: calendar.startOfDay(for: dayDate)
    )
}

func calendarShouldConsumeCalendarDropCommit(
    suppressedEventID: UUID?,
    incomingEventID: UUID
) -> Bool {
    suppressedEventID == incomingEventID
}

func calendarResolvedSafeAreaInset(proxyInset: CGFloat, windowInset: CGFloat) -> CGFloat {
    let normalizedProxyInset = proxyInset.isFinite ? max(0, proxyInset) : 0
    let normalizedWindowInset = windowInset.isFinite ? max(0, windowInset) : 0
    return max(normalizedProxyInset, normalizedWindowInset)
}

func calendarShouldOpenEventCardOnTap(
    focusedEventID: UUID?,
    tappedEventID: UUID
) -> Bool {
    guard let focusedEventID else { return false }
    return focusedEventID == tappedEventID
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

func calendarResolvedFocusedOccurrenceID(
    event: Event,
    preferredRange: Event.TimeRange,
    calendar: Calendar = .current
) -> String? {
    guard event.effectiveTimeRanges.contains(where: {
        calendarRangesApproximatelyEqual(lhs: $0, rhs: preferredRange)
    }) else {
        return nil
    }
    return calendarOccurrenceIDForRange(
        event: event,
        range: preferredRange,
        calendar: calendar
    )
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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

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
    @State private var headerCapsulesVisible: Bool = true
    @State private var legendCenteredOffsetContinuous: CGFloat = 0
    @State private var legendIsInteracting: Bool = false
    @State private var isTodoRevealPresented: Bool = false
    @State private var todoRevealPullDistance: CGFloat = 0
    @State private var todoRevealPeakPullDistance: CGFloat = 0
    @State private var todoRevealPanelDragY: CGFloat = 0
    @State private var hasViewedTodoDrawerThisSession: Bool = false
    @State private var isTimelineVerticalPullInteracting: Bool = false
    @State private var isTodoRevealCollapseAnimating: Bool = false
    @State private var timelineDropGeometry: TimelineDropGeometry? = nil
    @State private var activeCrossSurfaceDrag: ActiveCrossSurfaceDrag? = nil
    @State private var pendingTransferUndo: TodoCalendarTransferUndoToken? = nil
    @State private var transferUndoDismissWorkItem: DispatchWorkItem?
    @State private var suppressNextCalendarDropCommitEventID: UUID? = nil
    @State private var todoRevealPanelFrame: CGRect = .zero
    @State private var todoRevealSlotFrames: [Int: CGRect] = [:]
    @State private var selectedPlannedTodoForEdit: Event? = nil

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
    private let headerCapsuleHideThreshold: CGFloat = 64
    private let headerCapsuleShowThreshold: CGFloat = 52
    private let todoRevealOpenThreshold: CGFloat = 96
    private let todoRevealCloseThreshold: CGFloat = 72
    private let todoDrawerCloseZoneHeight: CGFloat = 52
    private let todoDrawerCloseZoneSlopBottom: CGFloat = 8
    private let todoRevealExpandedFraction: CGFloat = 0.5
    private let todoRevealSpacingFromLegend: CGFloat = 8

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
            let baseTopOverlayInset = calendarTopOverlayInset(
                safeAreaTop: metrics.safeAreaTop,
                isCapsuleVisible: headerCapsulesVisible,
                legendBandHeight: topOverlayLegendBandHeight,
                overlayGap: topOverlayGap,
                capsuleExpandedHeight: topOverlayCapsuleExpandedHeight
            )
            let todoSlots = todoRevealSlots
            let visibleTodoDayOffsets = todoSlots.map(\.id)
            let plannedEventsByDayOffset = Dictionary(uniqueKeysWithValues: todoSlots.map { ($0.id, $0.events) })
            let collapsedTodoMarkerLanes = calendarCollapsedTodoMarkersForVisibleDates(
                visibleDayOffsets: visibleTodoDayOffsets,
                plannedEventsByDayOffset: plannedEventsByDayOffset
            )
            let hasVisibleCollapsedTodoMarkers = collapsedTodoMarkerLanes.contains { !$0.colorKeys.isEmpty }
            let shouldShowCollapsedTodoMarkers = calendarState.isTodoRevealExperimentEnabled && calendarShouldShowCollapsedTodoMarkers(
                isDrawerPresented: isTodoRevealPresented,
                hasViewedDrawer: hasViewedTodoDrawerThisSession,
                hasVisibleTodos: hasVisibleCollapsedTodoMarkers
            )
            let visibleContentHeight = metrics.containerSize.height - baseTopOverlayInset - metrics.safeAreaBottom
            let todoDrawerHalfPageCapHeight = calendarTodoDrawerHalfPageCapHeight(
                visibleContentHeight: visibleContentHeight,
                fraction: todoRevealExpandedFraction
            )
            let todoDrawerContentHeight = calendarTodoDrawerContentHeight(
                slotDurationMinutes: todoSlots.map { slot in
                    slot.events.map { max(15, $0.todoPlannedDurationMinutes ?? 60) }
                },
                timelineHourHeight: calendarState.timelineHourHeight
            )
            let todoRevealExpandedSheetHeight = calendarTodoDrawerTargetExpandedHeight(
                contentHeight: todoDrawerContentHeight,
                halfPageCapHeight: todoDrawerHalfPageCapHeight
            )
            let todoRevealInteractiveSheetHeight = calendarState.isTodoRevealExperimentEnabled
                ? calendarTodoRevealInteractiveHeight(
                    pullDistance: todoRevealPullDistance,
                    threshold: todoRevealOpenThreshold,
                    maxHeight: todoRevealExpandedSheetHeight
                )
                : 0
            let todoRevealDisplayHeight = calendarState.isTodoRevealExperimentEnabled
                ? calendarTodoRevealDisplayHeight(
                    isPresented: isTodoRevealPresented,
                    expandedHeight: todoRevealExpandedSheetHeight,
                    interactiveHeight: todoRevealInteractiveSheetHeight,
                    panelDragY: todoRevealPanelDragY
                )
                : 0
            let topOverlayInset = baseTopOverlayInset

            ZStack(alignment: .top) {
                timelineScroll(
                    metrics: metrics,
                    topOverlayInset: topOverlayInset,
                    todoRevealDisplayHeight: todoRevealDisplayHeight,
                    todoRevealSlots: todoSlots,
                    todoRevealContentHeight: todoDrawerContentHeight,
                    collapsedTodoMarkerLanes: collapsedTodoMarkerLanes,
                    shouldShowCollapsedTodoMarkers: shouldShowCollapsedTodoMarkers
                )

                topOverlay(metrics: metrics)

                floatingTodoDragPreview
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
        .sheet(item: $selectedPlannedTodoForEdit) { event in
            EditEventView(event: event, isCalendarEvent: false)
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
            headerCapsulesVisible = true
            legendCenteredOffsetContinuous = CGFloat(calendarState.selectedDayOffset)
            legendIsInteracting = false
            isTodoRevealPresented = false
            todoRevealPullDistance = 0
            todoRevealPeakPullDistance = 0
            todoRevealPanelDragY = 0
            hasViewedTodoDrawerThisSession = false
            isTimelineVerticalPullInteracting = false
            isTodoRevealCollapseAnimating = false
            suppressNextCalendarDropCommitEventID = nil
            timelineDropGeometry = nil
            activeCrossSurfaceDrag = nil
            pendingTransferUndo = nil
            todoRevealPanelFrame = .zero
            todoRevealSlotFrames = [:]
            selectedPlannedTodoForEdit = nil
        }
        .onChange(of: store.calendarEvents) { _ in
            rebuildOccurrencesCache()
            updateTimerRefresh()
            if let focusedEventID,
               !store.calendarEvents.contains(where: { $0.id == focusedEventID }) {
                clearFocus(reason: "calendarEvents.changed.focusedEventRemoved")
            }
        }
        .onChange(of: focusedEventID) { newValue in
            calendarDebugLog(
                "calendar.focus.event.changed",
                fields: [
                    "focusedEventID": newValue?.uuidString ?? "nil",
                    "focusedOccurrenceID": focusedOccurrenceID ?? "nil"
                ]
            )
        }
        .onChange(of: focusedOccurrenceID) { newValue in
            calendarDebugLog(
                "calendar.focus.occurrence.changed",
                fields: [
                    "focusedEventID": focusedEventID?.uuidString ?? "nil",
                    "focusedOccurrenceID": newValue ?? "nil"
                ]
            )
        }
        .onChange(of: calendarState.selectedDayOffset) { newValue in
            if !legendIsInteracting {
                legendCenteredOffsetContinuous = CGFloat(newValue)
            }
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
        .overlay(alignment: .bottom) {
            if pendingTransferUndo != nil {
                Button {
                    guard let token = pendingTransferUndo else { return }
                    transferUndoDismissWorkItem?.cancel()
                    transferUndoDismissWorkItem = nil
                    store.undoTodoCalendarTransfer(token)
                    withAnimation(.easeOut(duration: 0.18)) {
                        pendingTransferUndo = nil
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: pendingTransferUndo != nil)
    }
}

private extension CalendarPageView {
    @ViewBuilder
    func topOverlay(metrics: CalendarPageMetrics) -> some View {
        let overlayHeight = calendarTopOverlayInset(
            safeAreaTop: metrics.safeAreaTop,
            isCapsuleVisible: headerCapsulesVisible,
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
                dateLegendBar(metrics: metrics)
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
    @ViewBuilder
    func todoDrawerInlineSection(
        displayHeight: CGFloat,
        slots: [TodoRevealDateSlot],
        contentHeight: CGFloat
    ) -> some View {
        let visibleHeight = displayHeight.isFinite ? max(0, displayHeight) : 0
        let closeGesture = DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard isTodoRevealPresented, !isTodoRevealCollapseAnimating else { return }
                let translation = value.translation.height
                // Close gesture only responds to upward drags; downward drags should not
                // collapse the drawer or interfere with the drawer's own rebound behavior.
                guard translation < 0 else {
                    todoRevealPanelDragY = 0
                    return
                }
                todoRevealPanelDragY = min(0, translation)
            }
            .onEnded { value in
                guard isTodoRevealPresented, !isTodoRevealCollapseAnimating else { return }
                guard value.translation.height < 0 else {
                    withAnimation(accessibilityReduceMotion ? .none : .interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                        todoRevealPanelDragY = 0
                    }
                    return
                }
                let shouldClose = calendarShouldCloseTodoPanel(
                    translationY: value.translation.height,
                    threshold: todoRevealCloseThreshold
                )
                if shouldClose {
                    if accessibilityReduceMotion {
                        withAnimation(.none) {
                            isTodoRevealPresented = false
                            isTodoRevealCollapseAnimating = false
                            todoRevealPullDistance = 0
                            todoRevealPeakPullDistance = 0
                            todoRevealPanelDragY = 0
                        }
                        activeCrossSurfaceDrag = nil
                    } else {
                        isTodoRevealCollapseAnimating = true
                        let collapseDistance = max(1, visibleHeight)
                        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.9, blendDuration: 0.1)) {
                            todoRevealPanelDragY = -collapseDistance
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                            guard isTodoRevealCollapseAnimating else { return }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                isTodoRevealPresented = false
                                isTodoRevealCollapseAnimating = false
                                todoRevealPullDistance = 0
                                todoRevealPeakPullDistance = 0
                                todoRevealPanelDragY = 0
                            }
                            activeCrossSurfaceDrag = nil
                        }
                    }
                } else {
                    withAnimation(accessibilityReduceMotion ? .none : .interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                        todoRevealPanelDragY = 0
                    }
                }
            }
        if visibleHeight > 0 {
            CalendarTodoRevealView(
            slots: slots,
            visibleHeight: visibleHeight,
            contentHeight: contentHeight,
            hourHeight: calendarState.timelineHourHeight,
            onCreatePlannedTodo: { date, durationMinutes in
                _ = store.createPlannedTodo(
                    listID: nil,
                    title: "Planned Todo",
                    plannedDate: date,
                    durationMinutes: durationMinutes
                )
            },
            onMovePlannedTodoInPanel: { eventID, targetDate, targetOrder in
                movePlannedTodoInReveal(
                    eventID: eventID,
                    targetDate: targetDate,
                    targetOrder: targetOrder
                )
            },
            onCardDragBegan: { event, location in
                activeCrossSurfaceDrag = ActiveCrossSurfaceDrag(
                    event: event,
                    locationInWindow: location,
                    translation: .zero
                )
            },
            onCardDragChanged: { event, translation, location in
                activeCrossSurfaceDrag = ActiveCrossSurfaceDrag(
                    event: event,
                    locationInWindow: location,
                    translation: translation
                )
            },
            onCardDragEnded: { event, _, location in
                handleTodoCardDropToTimeline(event: event, locationInWindow: location)
                activeCrossSurfaceDrag = nil
            },
            onCardDragCancelled: { _, _, _ in
                activeCrossSurfaceDrag = nil
            },
            onCardTap: { event in
                clearFocus(reason: "todoDrawer.cardTap.editTodo")
                selectedPlannedTodoForEdit = event
            },
            onPanelFrameChanged: { frame in
                todoRevealPanelFrame = frame
            },
            onSlotFrameChanged: { date, frame in
                todoRevealSlotFrames[dayOffset(for: date)] = frame
            }
        )
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: visibleHeight, alignment: .top)
        .clipped()
        .allowsHitTesting(isTodoRevealPresented)
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                CalendarTodoDrawerDivider()
                Color.clear
                    .frame(
                        maxWidth: .infinity,
                        minHeight: todoDrawerCloseZoneHeight,
                        maxHeight: todoDrawerCloseZoneHeight,
                        alignment: .top
                    )
                    .padding(.bottom, todoDrawerCloseZoneSlopBottom)
                    .contentShape(Rectangle())
                    .highPriorityGesture(closeGesture)
            }
        }
        }
    }

    @ViewBuilder
    var floatingTodoDragPreview: some View {
        if let activeCrossSurfaceDrag {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
                .overlay(
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeCrossSurfaceDrag.event.title.isEmpty ? "Untitled Todo" : activeCrossSurfaceDrag.event.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(max(15, activeCrossSurfaceDrag.event.todoPlannedDurationMinutes ?? 60))m")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                )
                .frame(width: 176, height: 56)
                .position(x: activeCrossSurfaceDrag.locationInWindow.x, y: activeCrossSurfaceDrag.locationInWindow.y)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
                .allowsHitTesting(false)
                .zIndex(20)
        }
    }

    var todoRevealSlots: [TodoRevealDateSlot] {
        let visibleDates = calendarVisibleDatesForRange(
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode
        )
        return visibleDates.map { date in
            let normalizedDate = Calendar.current.startOfDay(for: date)
            let offset = dayOffset(for: normalizedDate)
            return TodoRevealDateSlot(
                id: offset,
                date: normalizedDate,
                events: store.plannedTodoEvents(on: normalizedDate, listID: nil)
            )
        }
    }

    func enqueueTransferUndo(_ token: TodoCalendarTransferUndoToken?) {
        guard let token else { return }
        transferUndoDismissWorkItem?.cancel()
        pendingTransferUndo = token

        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) {
                pendingTransferUndo = nil
            }
        }
        transferUndoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func movePlannedTodoInReveal(
        eventID: UUID,
        targetDate: Date,
        targetOrder: Int?
    ) {
        guard var event = store.activeEvents.first(where: { $0.id == eventID }) else { return }
        let sourceDate = event.todoPlannedDate.map { Calendar.current.startOfDay(for: $0) }
        let normalizedTargetDate = Calendar.current.startOfDay(for: targetDate)

        event.todoPlannedDate = normalizedTargetDate
        store.update(event)

        let targetEvents = store.plannedTodoEvents(on: normalizedTargetDate, listID: event.listID)
        var orderedIDs = targetEvents.map(\.id).filter { $0 != eventID }
        let insertIndex = min(max(targetOrder ?? 0, 0), orderedIDs.count)
        orderedIDs.insert(eventID, at: insertIndex)
        store.reorderPlannedTodo(on: normalizedTargetDate, listID: event.listID, orderedIDs: orderedIDs)

        if let sourceDate, sourceDate != normalizedTargetDate {
            let sourceIDs = store.plannedTodoEvents(on: sourceDate, listID: event.listID).map(\.id)
            store.reorderPlannedTodo(on: sourceDate, listID: event.listID, orderedIDs: sourceIDs)
        }
    }

    func handleTodoCardDropToTimeline(event: Event, locationInWindow: CGPoint) {
        guard let geometry = timelineDropGeometry else { return }
        guard let dropStart = calendarMapTimelineDropToStartDate(
            dropLocation: locationInWindow,
            geometry: geometry,
            referenceDate: Date()
        ) else { return }
        let token = store.moveTodoEventToCalendar(eventID: event.id, droppedStart: dropStart)
        enqueueTransferUndo(token)
    }

    func todoRevealTargetDate(for locationInWindow: CGPoint) -> Date? {
        let slot = todoRevealSlotFrames.first { _, frame in
            frame.contains(locationInWindow)
        }
        guard let offset = slot?.key else { return nil }
        return dateForLegendDayOffset(offset)
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
            isCapsulesVisible: headerCapsulesVisible,
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
                isVisible: headerCapsulesVisible
            ),
            alignment: .top
        )
    }

    @ViewBuilder
    func dateLegendBar(metrics: CalendarPageMetrics) -> some View {
        let visibleDates = calendarVisibleDatesForRange(
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode
        )
        let visibleCount = max(1, visibleDates.count)
        let centeredOffsetContinuous = effectiveLegendCenteredOffsetContinuous
        let anchor = Int(floor(centeredOffsetContinuous))
        let fraction = centeredOffsetContinuous - floor(centeredOffsetContinuous)
        let overscan = 1
        let trackOffsets = calendarLegendTrackOffsets(
            anchor: anchor,
            visibleCount: visibleCount,
            overscan: overscan
        )
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width - metrics.horizontalPadding * 2)
            let labelWidth: CGFloat = 32
            let timelineEdgePadding: CGFloat = 6
            let daySpacing: CGFloat = 12
            let daysCount = visibleCount
            let dayAreaWidth = max(0, totalWidth - timelineEdgePadding * 2 - labelWidth)
            let spacing = daysCount == 1 ? CGFloat(0) : daySpacing
            let dayWidth = daysCount == 1
                ? dayAreaWidth
                : max(0, (dayAreaWidth - spacing * CGFloat(daysCount - 1)) / CGFloat(daysCount))
            let dayStep = dayWidth + spacing
            let baseTrackOffsetX = -CGFloat(overscan) * dayStep
            let interactionTrackOffsetX = calendarLegendTrackTranslation(
                fraction: fraction,
                dayStep: dayStep
            )

            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 30)
                ZStack(alignment: .leading) {
                    HStack(spacing: spacing) {
                        ForEach(trackOffsets, id: \.self) { dayOffset in
                            let date = dateForLegendDayOffset(dayOffset)
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
                            .frame(width: dayWidth, height: 30)
                        }
                    }
                    .offset(x: baseTrackOffsetX + interactionTrackOffsetX)
                }
                .frame(width: dayAreaWidth, height: 30, alignment: .leading)
                .clipped()
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

    @ViewBuilder
    func collapsedTodoMarkerRow(
        metrics: CalendarPageMetrics,
        lanes: [CollapsedTodoMarkerLane]
    ) -> some View {
        if !lanes.isEmpty {
            CalendarTodoCollapsedMarkerRow(
                lanes: lanes,
                horizontalPadding: metrics.horizontalPadding,
                onLaneTap: { tappedDayOffset in
                    clearFocus(reason: "todoDrawer.markerTap.open")
                    let targetOffset = calendarTodoMarkerTapTargetSelectedDayOffset(
                        tappedDayOffset: tappedDayOffset,
                        dayRange: dayRange
                    )
                    expandDayRangeToInclude(targetOffset)
                    if calendarState.selectedDayOffset != targetOffset {
                        calendarState.selectedDayOffset = targetOffset
                    }
                    withAnimation(accessibilityReduceMotion ? .none : .interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.1)) {
                        isTodoRevealPresented = true
                        hasViewedTodoDrawerThisSession = true
                        todoRevealPullDistance = 0
                        todoRevealPeakPullDistance = 0
                        todoRevealPanelDragY = 0
                    }
                }
            )
            .padding(.top, -4)
        }
    }

    var effectiveLegendCenteredOffsetContinuous: CGFloat {
        let fallback = CGFloat(calendarState.selectedDayOffset)
        guard legendCenteredOffsetContinuous.isFinite else { return fallback }
        return legendCenteredOffsetContinuous
    }

    func dateForLegendDayOffset(_ dayOffset: Int) -> Date {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: dayOffset, to: startOfToday) ?? startOfToday
    }

    func handleTimelineHorizontalScrollProgress(_ progress: TimelineHorizontalScrollProgress) {
        guard progress.centeredDayOffsetContinuous.isFinite else { return }
        let wasInteracting = legendIsInteracting
        legendIsInteracting = progress.isInteracting
        if progress.isInteracting {
            legendCenteredOffsetContinuous = progress.centeredDayOffsetContinuous
            return
        }
        if wasInteracting, !accessibilityReduceMotion {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.1)) {
                legendCenteredOffsetContinuous = progress.centeredDayOffsetContinuous
            }
        } else {
            legendCenteredOffsetContinuous = progress.centeredDayOffsetContinuous
        }
    }

    func timelineScroll(
        metrics: CalendarPageMetrics,
        topOverlayInset: CGFloat,
        todoRevealDisplayHeight: CGFloat,
        todoRevealSlots: [TodoRevealDateSlot],
        todoRevealContentHeight: CGFloat,
        collapsedTodoMarkerLanes: [CollapsedTodoMarkerLane],
        shouldShowCollapsedTodoMarkers: Bool
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if shouldShowCollapsedTodoMarkers {
                    collapsedTodoMarkerRow(
                        metrics: metrics,
                        lanes: collapsedTodoMarkerLanes
                    )
                }
                if calendarState.isTodoRevealExperimentEnabled, todoRevealDisplayHeight > 0 {
                    todoDrawerInlineSection(
                        displayHeight: todoRevealDisplayHeight,
                        slots: todoRevealSlots,
                        contentHeight: todoRevealContentHeight
                    )
                    .padding(.top, shouldShowCollapsedTodoMarkers ? 0 : todoRevealSpacingFromLegend)
                }
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
            let scrollY = newValue.contentOffset.y
            timelineVerticalScrollY = scrollY
            if calendarState.isTodoRevealExperimentEnabled {
                let pullDistance = max(0, -scrollY)
                if isTodoRevealPresented || isTodoRevealCollapseAnimating {
                    todoRevealPullDistance = 0
                    todoRevealPeakPullDistance = 0
                } else if isTimelineVerticalPullInteracting {
                    todoRevealPullDistance = pullDistance
                    todoRevealPeakPullDistance = max(todoRevealPeakPullDistance, pullDistance)
                } else {
                    // Prevent collapsed drawer ghost rendering caused by geometry churn
                    // during layout/close animations when the user is not actively pulling.
                    todoRevealPullDistance = 0
                }
            }
            let nextCapsuleVisibility = calendarNextHeaderCapsuleVisibility(
                scrollY: scrollY,
                currentlyVisible: headerCapsulesVisible,
                hideThreshold: headerCapsuleHideThreshold,
                showThreshold: headerCapsuleShowThreshold
            )
            guard nextCapsuleVisibility != headerCapsulesVisible else { return }
            if accessibilityReduceMotion {
                headerCapsulesVisible = nextCapsuleVisibility
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    headerCapsulesVisible = nextCapsuleVisibility
                }
            }
        }
        .onScrollPhaseChange { _, newPhase in
            isTimelineVerticalPullInteracting = (newPhase == .interacting)
            let isInteracting = (newPhase == .interacting || newPhase == .decelerating)
            guard !isInteracting else { return }
            if calendarState.isTodoRevealExperimentEnabled,
               !isTodoRevealPresented,
               calendarShouldRevealTodoPanel(
                pullDistance: max(todoRevealPullDistance, todoRevealPeakPullDistance),
                threshold: todoRevealOpenThreshold
               ) {
                withAnimation(accessibilityReduceMotion ? .none : .interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.1)) {
                    isTodoRevealPresented = true
                    hasViewedTodoDrawerThisSession = true
                    todoRevealPanelDragY = 0
                }
            }
            todoRevealPullDistance = 0
            todoRevealPeakPullDistance = 0
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
                if let lockedEventID = focusedEventID, lockedEventID != event.id {
                    calendarDebugLog(
                        "calendar.page.onEventTap.ignoredWhileFocused",
                        fields: [
                            "tappedEventID": event.id.uuidString,
                            "lockedEventID": lockedEventID.uuidString,
                            "focusedOccurrenceID": focusedOccurrenceID ?? "nil",
                            "date": calendarDebugDayString(date)
                        ]
                    )
                    return
                }
                guard calendarShouldOpenEventCardOnTap(
                    focusedEventID: focusedEventID,
                    tappedEventID: event.id
                ) else {
                    calendarDebugLog(
                        "calendar.page.onEventTap.suppressedInReadMode",
                        fields: [
                            "eventID": event.id.uuidString,
                            "focusedEventID": focusedEventID?.uuidString ?? "nil",
                            "focusedOccurrenceID": focusedOccurrenceID ?? "nil",
                            "date": calendarDebugDayString(date)
                        ]
                    )
                    return
                }
                if event.isRecurringSeries {
                    pendingRecurrenceEdit = (event, date)
                    showRecurrenceScopeDialog = true
                } else {
                    selectedEventForEdit = event
                }
            },
            onEventLongPressBegan: { event, occurrenceID, actionDate, dragMode in
                calendarDebugLog(
                    "calendar.page.onEventLongPressBegan",
                    fields: [
                        "eventID": event.id.uuidString,
                        "occurrenceID": occurrenceID ?? "nil",
                        "actionDate": calendarDebugDayString(actionDate),
                        "dragMode": String(describing: dragMode),
                        "previousFocusedEventID": focusedEventID?.uuidString ?? "nil",
                        "previousFocusedOccurrenceID": focusedOccurrenceID ?? "nil"
                    ]
                )
                setFocus(
                    event: event,
                    occurrenceID: occurrenceID,
                    reason: "timeline.longPressBegan.\(String(describing: dragMode))"
                )
            },
            onEventDragEnded: { event, occurrenceID, draggedRange, offset, dayColumnStep, dayContentWidth in
                if calendarShouldConsumeCalendarDropCommit(
                    suppressedEventID: suppressNextCalendarDropCommitEventID,
                    incomingEventID: event.id
                ) {
                    suppressNextCalendarDropCommitEventID = nil
                    calendarDebugLog(
                        "calendar.handleEventDrag.suppressedByTodoPushback",
                        fields: [
                            "eventID": event.id.uuidString,
                            "occurrenceID": occurrenceID ?? "nil"
                        ]
                    )
                    return
                }
                handleEventDrag(
                    event: event,
                    occurrenceID: occurrenceID,
                    draggedRange: draggedRange,
                    offset: offset,
                    dayColumnStep: dayColumnStep,
                    timelineContentWidth: dayContentWidth,
                    rangeMode: calendarState.rangeMode
                )
            },
            onEventDragTerminal: { event, _, _, _, windowLocation, terminalState in
                guard terminalState == .completed else { return }
                guard isTodoRevealPresented else { return }
                guard let targetDate = todoRevealTargetDate(for: windowLocation) else { return }

                let token = store.moveCalendarEventToTodo(
                    eventID: event.id,
                    targetDate: targetDate,
                    targetOrder: nil
                )
                guard token != nil else { return }
                suppressNextCalendarDropCommitEventID = event.id
                enqueueTransferUndo(token)
                clearFocus(reason: "timeline.dragTerminal.pushBackToTodo")
            },
            onEventResizeEnded: { event, occurrenceID, draggedRange, actionDate, dragMode, yOffset in
                handleEventResize(
                    event: event,
                    occurrenceID: occurrenceID,
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
            },
            onHorizontalScrollProgress: { progress in
                handleTimelineHorizontalScrollProgress(progress)
            },
            onTimelineDropGeometryChanged: { geometry in
                timelineDropGeometry = geometry
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

    func clearFocus(reason: String = "unspecified") {
        calendarDebugLog(
            "calendar.focus.clear",
            fields: [
                "reason": reason,
                "previousEventID": focusedEventID?.uuidString ?? "nil",
                "previousOccurrenceID": focusedOccurrenceID ?? "nil"
            ]
        )
        focusedEventID = nil
        focusedOccurrenceID = nil
    }

    func setFocus(event: Event, occurrenceID: String?, reason: String = "unspecified") {
        calendarDebugLog(
            "calendar.focus.set",
            fields: [
                "reason": reason,
                "eventID": event.id.uuidString,
                "occurrenceID": occurrenceID ?? "nil",
                "previousEventID": focusedEventID?.uuidString ?? "nil",
                "previousOccurrenceID": focusedOccurrenceID ?? "nil"
            ]
        )
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
        timelineContentWidth: CGFloat,
        rangeMode: RangeMode
    ) {
        let hourHeight = calendarState.timelineHourHeight
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
                "dayColumnStep": String(format: "%.2f", dayColumnStep),
                "timelineContentWidth": String(format: "%.2f", timelineContentWidth),
                "focusedEventID": focusedEventID?.uuidString ?? "nil",
                "focusedOccurrenceID": focusedOccurrenceID ?? "nil"
            ]
        )

        // Use the actual timeline content width from layout to avoid screen-based drift.
        let contentWidth = max(1, timelineContentWidth)
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
                setFocus(
                    event: movedException,
                    occurrenceID: focusedOccurrenceID,
                    reason: "handleEventDrag.recurring.exceptionResolved"
                )
            } else {
                let fallbackOccurrenceID = calendarOccurrenceIDForRange(
                    event: event,
                    range: newRange,
                    occurrenceDate: draggedRange.start,
                    calendar: calendar
                )
                setFocus(
                    event: event,
                    occurrenceID: fallbackOccurrenceID,
                    reason: "handleEventDrag.recurring.fallback"
                )
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
        let focusedOccurrenceID = calendarResolvedFocusedOccurrenceID(
            event: updated,
            preferredRange: newRange
        )
        setFocus(
            event: updated,
            occurrenceID: focusedOccurrenceID,
            reason: "handleEventDrag.commit"
        )
    }

    func handleEventResize(
        event: Event,
        occurrenceID: String?,
        draggedRange: Event.TimeRange,
        actionDate: Date,
        dragMode: EventDragMode,
        yOffset: CGFloat
    ) {
        let hourHeight = calendarState.timelineHourHeight
        let headerHeight: CGFloat = 0

        // Use actionDate (the day where user performed the resize) instead of draggedRange.start
        let originalDate = Calendar.current.startOfDay(for: actionDate)
        calendarDebugLog(
            "calendar.handleEventResize.begin",
            fields: [
                "eventID": event.id.uuidString,
                "occurrenceID": occurrenceID ?? "nil",
                "dragMode": String(describing: dragMode),
                "draggedStart": calendarDebugInstantString(draggedRange.start),
                "draggedEnd": calendarDebugInstantString(draggedRange.end),
                "yOffset": String(format: "%.2f", yOffset),
                "focusedEventID": focusedEventID?.uuidString ?? "nil",
                "focusedOccurrenceID": focusedOccurrenceID ?? "nil"
            ]
        )

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
        calendarDebugLog(
            "calendar.handleEventResize.computed",
            fields: [
                "eventID": event.id.uuidString,
                "occurrenceID": occurrenceID ?? "nil",
                "newStart": calendarDebugInstantString(newRange.start),
                "newEnd": calendarDebugInstantString(newRange.end)
            ]
        )

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
            let calendar = Calendar.current
            let occurrenceDay = calendar.startOfDay(for: draggedRange.start)
            let movedException = store.calendarEvents.last { candidate in
                candidate.recurrenceParentId == event.id
                    && candidate.recurrenceInstanceDate.map { calendar.isDate($0, inSameDayAs: occurrenceDay) } == true
                    && candidate.effectiveTimeRanges.contains {
                        calendarRangesApproximatelyEqual(lhs: $0, rhs: newRange)
                    }
            }
            let focusedEvent = movedException ?? event
            let focusedOccurrenceID = calendarResolvedFocusedOccurrenceID(
                event: focusedEvent,
                preferredRange: newRange
            )
            setFocus(
                event: focusedEvent,
                occurrenceID: focusedOccurrenceID,
                reason: "handleEventResize.recurring.commit"
            )
            calendarDebugLog(
                "calendar.handleEventResize.commitRecurring",
                fields: [
                    "eventID": event.id.uuidString,
                    "focusedEventID": focusedEvent.id.uuidString,
                    "focusedOccurrenceID": focusedOccurrenceID ?? "nil"
                ]
            )
            return
        }

        // Update the event
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
        store.updateCalendarEvent(updated)
        let focusedOccurrenceID = calendarResolvedFocusedOccurrenceID(
            event: updated,
            preferredRange: newRange
        )
        setFocus(
            event: updated,
            occurrenceID: focusedOccurrenceID,
            reason: "handleEventResize.commit"
        )
        calendarDebugLog(
            "calendar.handleEventResize.commit",
            fields: [
                "eventID": event.id.uuidString,
                "occurrenceID": occurrenceID ?? "nil",
                "timeRangesCount": "\(updated.timeRanges.count)",
                "focusedOccurrenceID": focusedOccurrenceID ?? "nil"
            ]
        )
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

private struct TodoRevealDateSlot: Identifiable, Equatable {
    let id: Int
    let date: Date
    let events: [Event]
}

private struct CalendarTodoRevealView: View {
    let slots: [TodoRevealDateSlot]
    let visibleHeight: CGFloat
    let contentHeight: CGFloat
    let hourHeight: CGFloat
    var onCreatePlannedTodo: ((Date, Int) -> Void)? = nil
    var onMovePlannedTodoInPanel: ((UUID, Date, Int?) -> Void)? = nil
    var onCardDragBegan: ((Event, CGPoint) -> Void)? = nil
    var onCardDragChanged: ((Event, CGSize, CGPoint) -> Void)? = nil
    var onCardDragEnded: ((Event, CGSize, CGPoint) -> Void)? = nil
    var onCardDragCancelled: ((Event, CGSize, CGPoint) -> Void)? = nil
    var onCardTap: ((Event) -> Void)? = nil
    var onPanelFrameChanged: ((CGRect) -> Void)? = nil
    var onSlotFrameChanged: ((Date, CGRect) -> Void)? = nil

    @State private var slotFramesByID: [Int: CGRect] = [:]
    @State private var creatingSlotID: Int? = nil
    @State private var creatingDurationMinutes: Int = 30

    private let slotHeaderHeight: CGFloat = 22
    private let slotVerticalPadding: CGFloat = 8
    private let slotInnerSpacing: CGFloat = 6
    private let rowSpacing: CGFloat = 6
    private let emptyLaneHeight: CGFloat = 20
    private let laneSpacing: CGFloat = 10

    var body: some View {
        let clampedVisibleHeight = max(0, visibleHeight.isFinite ? visibleHeight : 0)
        ScrollView(.vertical, showsIndicators: contentHeight > visibleHeight + 12) {
            HStack(alignment: .top, spacing: laneSpacing) {
                ForEach(slots) { slot in
                    slotColumn(slot)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(
                maxWidth: .infinity,
                minHeight: max(0, visibleHeight),
                alignment: .topLeading
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: clampedVisibleHeight, alignment: .top)
        .clipped()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onPanelFrameChanged?(proxy.frame(in: .global))
                    }
                    .onChange(of: proxy.frame(in: .global)) { newValue in
                        onPanelFrameChanged?(newValue)
                    }
            }
        )
    }

    @ViewBuilder
    private func slotColumn(_ slot: TodoRevealDateSlot) -> some View {
        VStack(alignment: .leading, spacing: slotInnerSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.weekdayFormatter.string(from: slot.date).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(Self.dayFormatter.string(from: slot.date))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .frame(height: slotHeaderHeight, alignment: .topLeading)

            VStack(spacing: rowSpacing) {
                if slot.events.isEmpty {
                    Text("No Todo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: emptyLaneHeight, alignment: .leading)
                } else {
                    ForEach(Array(slot.events.enumerated()), id: \.element.id) { _, event in
                        todoCard(event: event)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if creatingSlotID == slot.id {
                Text("Duration \(creatingDurationMinutes)m")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, slotVerticalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: max(0, visibleHeight - 16),
            alignment: .topLeading
        )
        .background {
            TodoCardDragBridge(
                minimumPressDuration: 0.25,
                onBegan: { _ in
                    creatingSlotID = slot.id
                    creatingDurationMinutes = 30
                },
                onChanged: { translation, _ in
                    guard creatingSlotID == slot.id else { return }
                    creatingDurationMinutes = calendarResolveTodoDurationFromCreationDrag(
                        dragDeltaY: translation.height,
                        hourHeight: hourHeight
                    )
                },
                onEnded: { translation, _ in
                    guard creatingSlotID == slot.id else { return }
                    let minutes = calendarResolveTodoDurationFromCreationDrag(
                        dragDeltaY: translation.height,
                        hourHeight: hourHeight
                    )
                    if abs(translation.height) > 4 {
                        onCreatePlannedTodo?(slot.date, minutes)
                    }
                    creatingSlotID = nil
                },
                onCancelled: { _, _ in
                    creatingSlotID = nil
                }
            )
            .allowsHitTesting(true)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        let frame = proxy.frame(in: .global)
                        slotFramesByID[slot.id] = frame
                        onSlotFrameChanged?(slot.date, frame)
                    }
                    .onChange(of: proxy.frame(in: .global)) { newValue in
                        slotFramesByID[slot.id] = newValue
                        onSlotFrameChanged?(slot.date, newValue)
                    }
            }
        )
    }

    @ViewBuilder
    private func todoCard(event: Event) -> some View {
        let duration = max(15, event.todoPlannedDurationMinutes ?? 60)
        let cardHeight = calendarTodoDrawerBlockHeight(
            durationMinutes: duration,
            timelineHourHeight: hourHeight
        )
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(CalendarLayout.eventColor(for: event).opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(CalendarLayout.eventColor(for: event).opacity(0.42), lineWidth: 1)
            )
            .overlay {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title.isEmpty ? "Untitled Todo" : event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(duration)m")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: cardHeight)
            .contentShape(Rectangle())
            .overlay {
                TodoCardDragBridge(
                    minimumPressDuration: 0.25,
                    onTap: { _ in
                        onCardTap?(event)
                    },
                    onBegan: { location in
                        onCardDragBegan?(event, location)
                    },
                    onChanged: { translation, location in
                        onCardDragChanged?(event, translation, location)
                    },
                    onEnded: { translation, location in
                        handlePanelDropIfNeeded(
                            event: event,
                            locationInWindow: location
                        )
                        onCardDragEnded?(event, translation, location)
                    },
                    onCancelled: { translation, location in
                        onCardDragCancelled?(event, translation, location)
                    }
                )
            }
    }

    private func handlePanelDropIfNeeded(
        event: Event,
        locationInWindow: CGPoint
    ) {
        guard let target = targetSlot(for: locationInWindow) else {
            return
        }
        let order = targetOrder(
            locationInWindow: locationInWindow,
            slotFrame: target.frame,
            items: target.slot.events
        )
        onMovePlannedTodoInPanel?(event.id, target.slot.date, order)
    }

    private func targetSlot(for locationInWindow: CGPoint) -> (slot: TodoRevealDateSlot, frame: CGRect)? {
        for slot in slots {
            guard let frame = slotFramesByID[slot.id] else { continue }
            if frame.contains(locationInWindow) {
                return (slot, frame)
            }
        }
        return nil
    }

    private func targetOrder(
        locationInWindow: CGPoint,
        slotFrame: CGRect,
        items: [Event]
    ) -> Int {
        let listStartY = slotFrame.minY + slotVerticalPadding + slotHeaderHeight + slotInnerSpacing
        let relativeY = max(0, locationInWindow.y - listStartY)
        guard !items.isEmpty else { return 0 }

        var cursor: CGFloat = 0
        for (index, item) in items.enumerated() {
            let duration = max(15, item.todoPlannedDurationMinutes ?? 60)
            let height = calendarTodoDrawerBlockHeight(
                durationMinutes: duration,
                timelineHourHeight: hourHeight
            )
            let threshold = cursor + height / 2
            if relativeY < threshold {
                return index
            }
            cursor += height + rowSpacing
        }
        return items.count
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
}

private struct CalendarTodoDrawerDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
            .allowsHitTesting(false)
    }
}

private struct CalendarTodoCollapsedMarkerRow: View {
    let lanes: [CollapsedTodoMarkerLane]
    let horizontalPadding: CGFloat
    var onLaneTap: ((Int) -> Void)? = nil

    private let labelWidth: CGFloat = 32
    private let timelineEdgePadding: CGFloat = 6
    private let daySpacing: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width - horizontalPadding * 2)
            let dayCount = max(1, lanes.count)
            let dayAreaWidth = max(0, totalWidth - timelineEdgePadding * 2 - labelWidth)
            let spacing = dayCount == 1 ? CGFloat(0) : daySpacing
            let dayWidth = dayCount == 1
                ? dayAreaWidth
                : max(0, (dayAreaWidth - spacing * CGFloat(dayCount - 1)) / CGFloat(dayCount))

            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 10)
                HStack(spacing: spacing) {
                    ForEach(lanes, id: \.dayOffset) { lane in
                        Button {
                            onLaneTap?(lane.dayOffset)
                        } label: {
                            HStack(spacing: 2) {
                                ForEach(Array(lane.colorKeys.prefix(4).enumerated()), id: \.offset) { _, key in
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .fill(EventTypeTemplateStore.color(for: key).opacity(0.95))
                                        .frame(width: 8, height: 3)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(width: dayWidth, height: 10, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: dayAreaWidth, height: 10, alignment: .leading)
            }
            .padding(.horizontal, horizontalPadding + timelineEdgePadding)
            .frame(width: proxy.size.width, height: 10, alignment: .leading)
        }
        .frame(height: 10)
    }
}

private struct TodoCardDragBridge: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = 0.25
    var onTap: ((CGPoint) -> Void)? = nil
    var onBegan: ((CGPoint) -> Void)? = nil
    var onChanged: ((CGSize, CGPoint) -> Void)? = nil
    var onEnded: ((CGSize, CGPoint) -> Void)? = nil
    var onCancelled: ((CGSize, CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let gesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        gesture.minimumPressDuration = minimumPressDuration
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.require(toFail: gesture)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TodoCardDragBridge
        private var startPointInWindow: CGPoint = .zero

        init(parent: TodoCardDragBridge) {
            self.parent = parent
        }

        @objc
        func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            let locationInWindow = gesture.location(in: nil)

            switch gesture.state {
            case .began:
                startPointInWindow = locationInWindow
                parent.onBegan?(locationInWindow)
            case .changed:
                parent.onChanged?(translation(to: locationInWindow), locationInWindow)
            case .ended:
                parent.onEnded?(translation(to: locationInWindow), locationInWindow)
            case .cancelled, .failed:
                parent.onCancelled?(translation(to: locationInWindow), locationInWindow)
            default:
                break
            }
        }

        @objc
        func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let locationInWindow = gesture.location(in: nil)
            parent.onTap?(locationInWindow)
        }

        private func translation(to end: CGPoint) -> CGSize {
            CGSize(width: end.x - startPointInWindow.x, height: end.y - startPointInWindow.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}
