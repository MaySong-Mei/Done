//
//  CalendarPageView.swift
//  Done
//
//  Calendar page with Apple-style header and focused event editing.
//

import SwiftUI
import Combine
import UIKit

enum PendingEventCreationCompletionNavigation: Equatable {
    case focusCreatedEvent
    case stayOnAnchorVisibleDate
}

/// Wrapper for pending event creation to make it Identifiable for sheet presentation.
struct PendingEventCreation: Identifiable {
    let id = UUID()
    let date: Date
    let timeRange: Event.TimeRange
    let source: AgenticCreateSource
    let anchorVisibleDate: Date
    let completionNavigation: PendingEventCreationCompletionNavigation

    init(
        date: Date,
        timeRange: Event.TimeRange,
        source: AgenticCreateSource,
        anchorVisibleDate: Date,
        completionNavigation: PendingEventCreationCompletionNavigation = .focusCreatedEvent
    ) {
        self.date = date
        self.timeRange = timeRange
        self.source = source
        self.anchorVisibleDate = anchorVisibleDate
        self.completionNavigation = completionNavigation
    }
}

private struct PendingInterruptComposerPresentation: Identifiable {
    let id = UUID()
    let anchorPoint: CGPoint
    let parentEvent: Event
    let occurrence: CalendarEventOccurrenceContext
    let parentRange: Event.TimeRange
    let occupiedRanges: [Event.TimeRange]
}

/// Dedup key for `applyDynamicPinchMinIfNeeded`. The function is pure given
/// these four inputs, so identical inputs guarantee identical output and can
/// safely skip the work — important because the function is called from the
/// vertical scroll handler, which fires every frame.
fileprivate struct DynamicPinchMinInputs: Equatable {
    let viewport: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let hourHeight: CGFloat
}

/// Equatable wrapper that short-circuits SwiftUI body re-evaluation of its
/// content subtree while the timeline is vertically scrolling.  Mirrors the
/// `DayColumnGate` pattern used for horizontal scrolling.
///
/// Theory: during a vertical scroll, no consumer of the wrapped subtree
/// actually depends on per-frame state changes — the header's date doesn't
/// change (vertical scroll doesn't change the selected day in 99% of cases),
/// and `TimelinePagerView`'s rendered content stays the same (the ScrollView
/// slides the pre-rendered 24-hour content; the view tree doesn't need to
/// re-evaluate).  Freezing the subtree while the scroll is in `interacting`
/// or `decelerating` phases skips a full body re-eval per scroll frame.
/// When the scroll settles, `==` returns false and SwiftUI runs one catch-up
/// evaluation.
///
/// Safe under the same assumption as `DayColumnGate`: the user can't
/// simultaneously scroll vertically and mutate data through this subtree.
fileprivate struct VerticalScrollGate<Content: View>: View, Equatable {
    let isScrolling: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }

    static func == (lhs: VerticalScrollGate, rhs: VerticalScrollGate) -> Bool {
        // Both sides scrolling → freeze.  Otherwise allow re-eval so settle
        // catches up to current state.
        lhs.isScrolling && rhs.isScrolling
    }
}

func calendarPendingEventCreationCompletionNavigation(
    source: AgenticCreateSource,
    anchorVisibleDate: Date,
    timeRange: Event.TimeRange,
    calendar: Calendar = .current
) -> PendingEventCreationCompletionNavigation {
    guard source == .dragCreate else { return .focusCreatedEvent }

    let anchorDay = calendar.startOfDay(for: anchorVisibleDate)
    let startDay = calendar.startOfDay(for: timeRange.start)
    let endDay = calendar.startOfDay(for: timeRange.end)

    guard !calendar.isDate(startDay, inSameDayAs: anchorDay),
          calendar.isDate(startDay, inSameDayAs: endDay) else {
        return .focusCreatedEvent
    }

    let dayDelta = calendar.dateComponents([.day], from: anchorDay, to: startDay).day ?? 0
    guard abs(dayDelta) == 1 else { return .focusCreatedEvent }
    return .stayOnAnchorVisibleDate
}

// Extracted for regression tests: resolve the final moved range using the same Y-snap rule as drag preview.
func calendarDroppedRangeFromDrag(
    draggedRange: Event.TimeRange,
    dayOffsetFromDrag: Int,
    offsetY: CGFloat,
    hourHeight: CGFloat,
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
        snapIntervalSeconds: snapIntervalSeconds,
        calendar: calendar
    )

    return Event.TimeRange(
        start: dayShiftedRange.start.addingTimeInterval(displayOffsetSeconds),
        end: dayShiftedRange.end.addingTimeInterval(displayOffsetSeconds)
    )
}

func calendarResizedRangeFromDrag(
    draggedRange: Event.TimeRange,
    dragMode: EventDragMode,
    offsetY: CGFloat,
    hourHeight: CGFloat,
    calendar: Calendar = .current
) -> Event.TimeRange {
    guard dragMode == .resizeTop || dragMode == .resizeBottom else { return draggedRange }
    return calendarResolvedDragEditRange(
        draggingOriginalRange: draggedRange,
        dragOffset: DragOffset(x: 0, y: offsetY),
        dragMode: dragMode,
        hourHeight: hourHeight,
        calendar: calendar
    ) ?? draggedRange
}

func calendarVisibleDatesForRange(
    selectedDayOffset: Int,
    rangeMode: RangeMode,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> [Date] {
    let center = calendarDateForSelectedDayOffset(
        selectedDayOffset,
        referenceDate: referenceDate,
        calendar: calendar
    )

    let offsets: [Int]
    switch rangeMode {
    case .day:
        offsets = [0]
    case .threeDay:
        offsets = [-1, 0, 1]
    case .week:
        offsets = [-3, -2, -1, 0, 1, 2, 3]
    case .month:
        return calendarMonthGridDates(
            selectedDayOffset: selectedDayOffset,
            referenceDate: referenceDate,
            calendar: calendar
        )
    case .stream:
        offsets = [0]
    }

    return offsets.compactMap { offset in
        calendar.date(byAdding: .day, value: offset, to: center)
    }
}

func calendarDateForSelectedDayOffset(
    _ selectedDayOffset: Int,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> Date {
    let today = calendar.startOfDay(for: referenceDate)
    return calendar.date(byAdding: .day, value: selectedDayOffset, to: today) ?? today
}

func calendarMonthStartDate(
    containing date: Date,
    calendar: Calendar = .current
) -> Date {
    let components = calendar.dateComponents([.year, .month], from: date)
    return calendar.date(from: components) ?? calendar.startOfDay(for: date)
}

func calendarMonthGridDates(
    selectedDayOffset: Int,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> [Date] {
    let anchorDate = calendarDateForSelectedDayOffset(
        selectedDayOffset,
        referenceDate: referenceDate,
        calendar: calendar
    )
    return calendarMonthGridDates(forMonthContaining: anchorDate, calendar: calendar)
}

func calendarMonthGridDates(
    forMonthContaining date: Date,
    calendar: Calendar = .current
) -> [Date] {
    let monthStart = calendarMonthStartDate(containing: date, calendar: calendar)
    let weekday = calendar.component(.weekday, from: monthStart)
    let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
    let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart

    return (0..<42).compactMap { offset in
        calendar.date(byAdding: .day, value: offset, to: gridStart)
    }
}

func calendarMonthOffset(
    selectedDayOffset: Int,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> Int {
    let todayMonthStart = calendarMonthStartDate(containing: calendar.startOfDay(for: referenceDate), calendar: calendar)
    let selectedMonthStart = calendarMonthStartDate(
        containing: calendarDateForSelectedDayOffset(
            selectedDayOffset,
            referenceDate: referenceDate,
            calendar: calendar
        ),
        calendar: calendar
    )
    return calendar.dateComponents([.month], from: todayMonthStart, to: selectedMonthStart).month ?? 0
}

func calendarShiftSelectedDayOffsetByMonth(
    selectedDayOffset: Int,
    deltaMonths: Int,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> Int {
    guard deltaMonths != 0 else { return selectedDayOffset }

    let today = calendar.startOfDay(for: referenceDate)
    let selectedDate = calendarDateForSelectedDayOffset(
        selectedDayOffset,
        referenceDate: referenceDate,
        calendar: calendar
    )
    let day = calendar.component(.day, from: selectedDate)
    let selectedMonthStart = calendarMonthStartDate(containing: selectedDate, calendar: calendar)
    let targetMonthStart = calendar.date(byAdding: .month, value: deltaMonths, to: selectedMonthStart) ?? selectedMonthStart
    let maxDay = calendar.range(of: .day, in: .month, for: targetMonthStart)?.count ?? day
    let targetDay = min(day, maxDay)
    let targetComponents = calendar.dateComponents([.year, .month], from: targetMonthStart)
    let targetDate = calendar.date(from: DateComponents(
        year: targetComponents.year,
        month: targetComponents.month,
        day: targetDay
    )) ?? targetMonthStart

    return calendar.dateComponents([.day], from: today, to: targetDate).day ?? selectedDayOffset
}

func calendarMonthOverlayTitle(
    selectedDayOffset: Int,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> String {
    let monthStart = calendarMonthStartDate(
        containing: calendarDateForSelectedDayOffset(
            selectedDayOffset,
            referenceDate: referenceDate,
            calendar: calendar
        ),
        calendar: calendar
    )
    return CalendarLegendFormatters.fullMonth.string(from: monthStart)
}

func calendarMonthWeekdaySymbols(
    calendar: Calendar = .current
) -> [String] {
    let formatter = DateFormatter()
    let baseSymbols = formatter.veryShortStandaloneWeekdaySymbols ?? formatter.veryShortWeekdaySymbols ?? []
    guard baseSymbols.count == 7 else { return [] }
    let prefix = max(0, min(6, calendar.firstWeekday - 1))
    return Array(baseSymbols[prefix...]) + Array(baseSymbols[..<prefix])
}

func calendarTopOverlayLegendBandHeight(
    for rangeMode: RangeMode
) -> CGFloat {
    switch rangeMode {
    case .month:
        return 92
    case .day, .stream:
        return 0
    case .threeDay, .week:
        return 34
    }
}

func calendarTopOverlayCapsulesVisible(
    rangeMode: RangeMode,
    storedVisibility: Bool
) -> Bool {
    switch rangeMode {
    case .day, .stream:
        return true
    case .threeDay, .week, .month:
        return storedVisibility
    }
}

// Extracted for regression tests: compute the max all-day occurrence count
// across a cache dictionary.  Used by CalendarPageView to maintain a cached
// value that is passed down to TimelinePagerView, avoiding per-body iteration.
func calendarMaxAllDayCount(
    in cache: [Int: [CalendarLayout.EventOccurrence]]
) -> Int {
    var maxCount = 0
    for (_, occurrences) in cache {
        if occurrences.count > maxCount { maxCount = occurrences.count }
    }
    return maxCount
}

func calendarExpandedDayRange(
    currentRange: ClosedRange<Int>,
    selectedDayOffset: Int,
    expansionStep: Int = 30,
    expansionThreshold: Int = 14,
    inclusionBuffer: Int = 14
) -> ClosedRange<Int> {
    var newLower = currentRange.lowerBound
    var newUpper = currentRange.upperBound

    if selectedDayOffset < newLower {
        newLower = selectedDayOffset - inclusionBuffer
    }
    if selectedDayOffset > newUpper {
        newUpper = selectedDayOffset + inclusionBuffer
    }
    if selectedDayOffset - newLower < expansionThreshold {
        newLower -= expansionStep
    }
    if newUpper - selectedDayOffset < expansionThreshold {
        newUpper += expansionStep
    }

    return newLower...newUpper
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
    case .month:
        return CalendarLegendFormatters.yearOnly.string(
            from: calendarMonthStartDate(containing: center, calendar: calendar)
        )
    case .stream:
        return CalendarLegendFormatters.monthDayWeekday.string(from: center)
    }
}

func calendarResolvedHeaderDisplayDate(
    selectedDayOffset: Int,
    rangeMode: RangeMode,
    currentScrollY: CGFloat,
    headerHeight: CGFloat,
    hourHeight: CGFloat,
    boundaryExtensionState: TimelineBoundaryExtensionState,
    draggingEventID: UUID? = nil,
    dragMode: EventDragMode = .move,
    dragTouchPointGlobal: CGPoint? = nil,
    timelineFrameGlobal: CGRect = .zero,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> Date {
    if let dragDisplayDate = calendarResolvedTouchDrivenHeaderDisplayDate(
        draggingEventID: draggingEventID,
        dragMode: dragMode,
        dragTouchPointGlobal: dragTouchPointGlobal,
        timelineFrameGlobal: timelineFrameGlobal,
        selectedDayOffset: selectedDayOffset,
        rangeMode: rangeMode,
        headerHeight: headerHeight,
        hourHeight: hourHeight,
        boundaryExtensionState: boundaryExtensionState,
        referenceDate: referenceDate,
        calendar: calendar
    ) {
        return dragDisplayDate
    }

    let selectedDate = calendarDateForSelectedDayOffset(
        selectedDayOffset,
        referenceDate: referenceDate,
        calendar: calendar
    )
    guard rangeMode == .day else { return selectedDate }

    let normalizedScrollY = currentScrollY.isFinite ? max(0, currentScrollY) : 0
    guard hourHeight.isFinite, hourHeight > 0 else { return selectedDate }

    let totalVisibleMinutes = calendarTimelineTotalVisibleHours(
        leadingExtendedHours: boundaryExtensionState.leadingHours,
        trailingExtendedHours: boundaryExtensionState.trailingHours
    )
        * 60
    let maxLocalY = headerHeight + CGFloat(max(0, totalVisibleMinutes - 1)) / 60 * hourHeight
    let localY = min(max(headerHeight, normalizedScrollY + headerHeight), maxLocalY)
    let resolvedDate = calendarTimelineDateFromYPosition(
        localY,
        containing: selectedDate,
        headerHeight: headerHeight,
        hourHeight: hourHeight,
        leadingExtendedHours: boundaryExtensionState.leadingHours,
        trailingExtendedHours: boundaryExtensionState.trailingHours,
        snapMinutes: 1,
        calendar: calendar
    )
    return calendar.startOfDay(for: resolvedDate)
}

func calendarResolvedTouchDrivenHeaderDisplayDate(
    draggingEventID: UUID?,
    dragMode: EventDragMode,
    dragTouchPointGlobal: CGPoint?,
    timelineFrameGlobal: CGRect,
    selectedDayOffset: Int,
    rangeMode: RangeMode,
    headerHeight: CGFloat,
    hourHeight: CGFloat,
    boundaryExtensionState: TimelineBoundaryExtensionState,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> Date? {
    guard rangeMode == .day else { return nil }
    guard calendarIsMoveDragActive(
        draggingEventID: draggingEventID,
        dragMode: dragMode
    ) else {
        return nil
    }
    guard let dragTouchPointGlobal else { return nil }
    guard dragTouchPointGlobal.y.isFinite,
          timelineFrameGlobal.minY.isFinite,
          timelineFrameGlobal.height.isFinite,
          timelineFrameGlobal.height > 0,
          headerHeight.isFinite,
          hourHeight.isFinite,
          hourHeight > 0 else {
        return nil
    }

    let selectedDate = calendarDateForSelectedDayOffset(
        selectedDayOffset,
        referenceDate: referenceDate,
        calendar: calendar
    )
    let totalVisibleMinutes = calendarTimelineTotalVisibleHours(
        leadingExtendedHours: boundaryExtensionState.leadingHours,
        trailingExtendedHours: boundaryExtensionState.trailingHours
    ) * 60
    let maxLocalY = headerHeight + CGFloat(max(0, totalVisibleMinutes - 1)) / 60 * hourHeight
    let localY = dragTouchPointGlobal.y - timelineFrameGlobal.minY
    let clampedLocalY = min(max(headerHeight, localY), maxLocalY)
    let resolvedDate = calendarTimelineDateFromYPosition(
        clampedLocalY,
        containing: selectedDate,
        headerHeight: headerHeight,
        hourHeight: hourHeight,
        leadingExtendedHours: boundaryExtensionState.leadingHours,
        trailingExtendedHours: boundaryExtensionState.trailingHours,
        snapMinutes: 1,
        calendar: calendar
    )
    return calendar.startOfDay(for: resolvedDate)
}

func calendarResolvedHeaderCapsuleTitle(
    selectedDayOffset: Int,
    rangeMode: RangeMode,
    headerDisplayDate: Date,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> String {
    switch rangeMode {
    case .day, .stream:
        return CalendarLegendFormatters.monthDayWeekday.string(from: headerDisplayDate)
    case .threeDay, .week, .month:
        return calendarLegendTitle(
            selectedDayOffset: selectedDayOffset,
            rangeMode: rangeMode,
            referenceDate: referenceDate,
            calendar: calendar
        )
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

func calendarAdjustedVerticalScrollOffsetForLeadingTimelineExtension(
    currentOffsetY: CGFloat,
    previousLeadingHours: Int,
    currentLeadingHours: Int,
    hourHeight: CGFloat
) -> CGFloat {
    let normalizedOffsetY = currentOffsetY.isFinite ? max(0, currentOffsetY) : 0
    guard hourHeight.isFinite, hourHeight > 0 else { return normalizedOffsetY }

    let deltaLeadingHours = currentLeadingHours - previousLeadingHours
    guard deltaLeadingHours != 0 else { return normalizedOffsetY }
    let targetOffsetY = normalizedOffsetY + CGFloat(deltaLeadingHours) * hourHeight
    return max(0, targetOffsetY)
}

func calendarResolvedVerticalScrollOffsetForBoundaryExtensionChange(
    currentOffsetY: CGFloat,
    previousState: TimelineBoundaryExtensionState,
    newState: TimelineBoundaryExtensionState,
    recoveryBaselineY: CGFloat? = nil,
    needsRecovery: Bool = false,
    hourHeight: CGFloat
) -> CGFloat? {
    let normalizedCurrentOffsetY = currentOffsetY.isFinite ? max(0, currentOffsetY) : 0
    let leadingHoursIncreased = newState.leadingHours > previousState.leadingHours

    guard leadingHoursIncreased else { return nil }

    let leadingAdjustedOffsetY = calendarAdjustedVerticalScrollOffsetForLeadingTimelineExtension(
        currentOffsetY: normalizedCurrentOffsetY,
        previousLeadingHours: previousState.leadingHours,
        currentLeadingHours: newState.leadingHours,
        hourHeight: hourHeight
    )
    return abs(leadingAdjustedOffsetY - normalizedCurrentOffsetY) > 0.5
        ? leadingAdjustedOffsetY
        : nil
}

func calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(
    source: TimelineEditMappingSource?
) -> Bool {
    // Apply immediately for all active edit sources so the viewport
    // compensates in the same frame as the extension change.
    // Only .focused uses deferred compensation (the expand animation
    // needs the scroll to settle after the spring).
    source != .focused
}

func calendarRetainedTimelineBoundaryExtensionState(
    currentState: TimelineBoundaryExtensionState,
    rawState: TimelineBoundaryExtensionState,
    maxExtensionHours: Int = calendarTimelineMaximumBoundaryExtensionHours
) -> TimelineBoundaryExtensionState {
    let clampedExtensionHours = max(0, maxExtensionHours)

    if let source = rawState.source {
        return TimelineBoundaryExtensionState(
            leadingHours: (currentState.leadingHours > 0 || rawState.leadingHours > 0) ? clampedExtensionHours : 0,
            trailingHours: (currentState.trailingHours > 0 || rawState.trailingHours > 0) ? clampedExtensionHours : 0,
            source: source,
            anchorDayOffset: rawState.anchorDayOffset ?? currentState.anchorDayOffset
        )
    }

    guard currentState.hasAnyExtension else { return .none }

    return TimelineBoundaryExtensionState(
        leadingHours: currentState.leadingHours,
        trailingHours: currentState.trailingHours,
        source: nil,
        anchorDayOffset: currentState.anchorDayOffset
    )
}

func calendarShouldRetainTimelineBoundaryExtensionOnSelectedDayOffsetChange(
    currentState: TimelineBoundaryExtensionState,
    rawState: TimelineBoundaryExtensionState
) -> Bool {
    if rawState.source != nil {
        return true
    }
    return currentState.hasAnyExtension
}

func calendarTimelineBoundaryExtensionVisibility(
    currentOffsetY: CGFloat,
    viewportHeight: CGFloat,
    contentTopInset: CGFloat,
    allDayHeight: CGFloat,
    headerHeight: CGFloat,
    hourHeight: CGFloat,
    state: TimelineBoundaryExtensionState
) -> (leadingVisible: Bool, trailingVisible: Bool) {
    let normalizedOffsetY = currentOffsetY.isFinite ? max(0, currentOffsetY) : 0
    let normalizedViewportHeight = viewportHeight.isFinite ? max(0, viewportHeight) : 0
    guard normalizedViewportHeight > 0, hourHeight.isFinite, hourHeight > 0 else {
        return (state.leadingHours > 0, state.trailingHours > 0)
    }

    let visibleTop = normalizedOffsetY
    let visibleBottom = normalizedOffsetY + normalizedViewportHeight
    let extensionOriginY = contentTopInset + allDayHeight + headerHeight
    // Minimum visible height for an extension region to be
    // considered "visible".  At max pinch the extension region
    // might be technically visible but too small to be useful —
    // dismiss it automatically with a fade.
    let minVisibleHeight = hourHeight * 2

    let leadingVisible: Bool = {
        guard state.leadingHours > 0 else { return false }
        let regionTop = extensionOriginY
        let regionBottom = regionTop + CGFloat(state.leadingHours) * hourHeight
        let overlap = min(regionBottom, visibleBottom) - max(regionTop, visibleTop)
        return overlap >= minVisibleHeight
    }()

    let trailingVisible: Bool = {
        guard state.trailingHours > 0 else { return false }
        let regionTop = extensionOriginY
            + CGFloat(state.leadingHours + calendarTimelineBaseVisibleHours) * hourHeight
        let regionBottom = regionTop + CGFloat(state.trailingHours) * hourHeight
        let overlap = min(regionBottom, visibleBottom) - max(regionTop, visibleTop)
        return overlap >= minVisibleHeight
    }()

    return (leadingVisible, trailingVisible)
}

func calendarCollapsedTimelineBoundaryExtensionState(
    currentState: TimelineBoundaryExtensionState,
    leadingVisible: Bool,
    trailingVisible: Bool
) -> TimelineBoundaryExtensionState {
    let nextLeadingHours = leadingVisible ? currentState.leadingHours : 0
    let nextTrailingHours = trailingVisible ? currentState.trailingHours : 0

    guard nextLeadingHours > 0 || nextTrailingHours > 0 else {
        return .none
    }

    return TimelineBoundaryExtensionState(
        leadingHours: nextLeadingHours,
        trailingHours: nextTrailingHours,
        source: currentState.source,
        anchorDayOffset: currentState.anchorDayOffset
    )
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

func calendarWindowSafeAreaInsets() -> UIEdgeInsets {
    let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = windowScenes.flatMap(\.windows)
    let keyWindow = windows.first(where: \.isKeyWindow) ?? windows.first
    return keyWindow?.safeAreaInsets ?? .zero
}

nonisolated struct CalendarPageGeometryValues: Equatable, Sendable {
    var size: CGSize
    var safeAreaTop: CGFloat
    var safeAreaBottom: CGFloat
}

private func calendarPageGeometryChanged(
    _ lhs: CalendarPageGeometryValues,
    _ rhs: CalendarPageGeometryValues,
    tolerance: CGFloat
) -> Bool {
    abs(lhs.size.width - rhs.size.width) > tolerance
        || abs(lhs.size.height - rhs.size.height) > tolerance
        || abs(lhs.safeAreaTop - rhs.safeAreaTop) > tolerance
        || abs(lhs.safeAreaBottom - rhs.safeAreaBottom) > tolerance
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
    private static var appLocale: Locale {
        let lang = UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey) ?? "en"
        return Locale(identifier: lang == "zh" ? "zh_CN" : "en_US")
    }

    static var yearOnly: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateFormat = "yyyy"
        return formatter
    }

    static var fullMonth: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateFormat = "LLLL"
        return formatter
    }

    static var shortMonth: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateFormat = "MMM"
        return formatter
    }

    static var shortWeekday: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateFormat = "EEE"
        return formatter
    }

    static var monthDayWeekday: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return formatter
    }
}

/// 功能： Hosts the calendar page layout and binds state/composition to views.
struct CalendarPageView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var calendarState: CalendarViewState
    @EnvironmentObject private var orientationManager: OrientationManager
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(AppSettingsKeys.calendarAgenticCreateEnabled) private var calendarAgenticCreateEnabled = true
    /// Read so the calendar page rebuilds when the user toggles
    /// effort-based opacity in settings.  The actual opacity formula
    /// lives in `Event.colorOpacityMultiplier` and reads UserDefaults
    /// directly; this @AppStorage exists purely for SwiftUI reactivity.
    @AppStorage(AppSettingsKeys.effortOpacityEnabled) private var effortOpacityEnabled = true
    @AppStorage(AppSettingsKeys.calendarAutoReturnToToday) private var autoReturnToToday = false
    @StateObject private var agenticCreateCoordinator = CalendarAgenticCreateCoordinator()
    private let typeInferenceService = CalendarEventTypeInferenceService()

    @State private var occurrencesCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
    @State private var allDayOccurrencesCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
    @State private var maxAllDayCountCache: Int = 0
    @State private var dayRange: ClosedRange<Int> = CalendarLayout.defaultDayRange
    // Stable reference-type holder, kept in sync with
    // `calendarState.timelineHourHeight` via `.onAppear` / `.onChange` in
    // `timelineLayer`.  Passed down to EventBlock so its struct identity
    // does not change on pinch.
    @State private var liveHourHeight = CalendarHourHeightBox()
    @State private var selectedEventDetailRoute: CalendarEventDetailRoute? = nil
    @State private var selectedEventChatOccurrence: CalendarEventOccurrenceContext? = nil
    @State private var selectedEventForEdit: Event? = nil
    @State private var floatingMenuAnchor: CalendarEventLongPressBegan? = nil
    @State private var floatingMenuOccurrence: CalendarEventOccurrenceContext? = nil
    @State private var floatingMenuInteractive: Bool = false
    @State private var floatingMenuActivationTask: Task<Void, Never>? = nil
    @State private var floatingMenuActivationToken: UUID? = nil
    @State private var showLongPressDeleteConfirm: Bool = false
    @State private var pendingRecurrenceEdit: (event: Event, date: Date)? = nil
    @State private var recurrenceEditScope: Event.RecurrenceEditScope? = nil
    @State private var showRecurrenceScopeDialog: Bool = false
    @State private var pendingCreateTimeRange: PendingEventCreation? = nil
    @State private var pendingInterruptComposer: PendingInterruptComposerPresentation? = nil
    @State private var liveInterruptSession: CalendarInterruptLiveSession? = nil
    @State private var isShowingDatePicker: Bool = false
    @State private var datePickerSelection: Date = Date()
    @State private var datePickerDetent: PresentationDetent = .medium
    @State private var timerRefreshCancellable: AnyCancellable?
    @State private var focusedEventID: UUID? = nil
    @State private var focusedOccurrenceID: String? = nil
    @State private var resizeGraceState: CalendarResizeGraceState? = nil
    @State private var resizeGraceOccurrenceContext: CalendarEventOccurrenceContext? = nil
    @State private var resizeGraceFadeTask: Task<Void, Never>? = nil
    @State private var resizeGraceExpiryTask: Task<Void, Never>? = nil
    @State private var isShowingAgent: Bool = false
    @State private var isShowingSearch: Bool = false
    @State private var isShowingShare: Bool = false
    @State private var eventShareContext: CalendarEventShareContext? = nil
    @AppStorage(AppSettingsKeys.meDisplayName) private var shareDisplayName: String = ""
    @AppStorage(AppSettingsKeys.meAvatarHue) private var shareAvatarHue: Double = -1
    @AppStorage(AppSettingsKeys.calendarShareStyle) private var shareStyleRaw: String = CalendarDailyShareStyle.calendar.rawValue
    @State private var timelineVerticalScrollY: CGFloat = 0
    @State private var headerCapsulesVisible: Bool = true
    @State private var legendCenteredOffsetContinuous: CGFloat = 0
    @State private var legendIsInteracting: Bool = false
    @State private var hasAppearedOnce: Bool = false
    @State private var needsScrollToNow: Bool = true
    @State private var timelineDragState = EventDragState()
    @State private var verticalScrollPosition: ScrollPosition = .init(point: .zero)
    @State private var timelineBoundaryExtensionState: TimelineBoundaryExtensionState = .none
    @State private var timelineRawBoundaryExtensionState: TimelineBoundaryExtensionState = .none
    @State private var timelineScrollViewportHeight: CGFloat = 0
    @State private var lastDynamicPinchMinInputs: DynamicPinchMinInputs? = nil
    /// Vertical-scroll phase flag.  When true, `VerticalScrollGate` short-
    /// circuits header and TimelinePagerView body re-evaluation, mirroring the
    /// horizontal `DayColumnGate` pattern.  Updated from `.onScrollPhaseChange`
    /// on the timeline's outer ScrollView.
    @State private var isVerticallyScrolling: Bool = false
    @State private var timelineVisibleDayFrameGlobal: CGRect = .zero
    @State private var pendingBoundaryExtensionScrollTask: Task<Void, Never>? = nil
    @State private var progressiveCacheTask: Task<Void, Never>? = nil
    /// Captured page geometry, written by `.onGeometryChange` on the body root.
    /// Reading geometry through @State (instead of a top-level GeometryReader
    /// closure that wraps the entire body) prevents transition-driven proxy
    /// jitter from invalidating the whole subtree every frame.  Initial value
    /// is `.zero` — `calendarResolvedSafeAreaInset` falls back to window insets
    /// and `pageContent` fills `.infinity`, so a single frame of zero metrics
    /// has no visible effect.
    @State private var capturedPageGeometry = CalendarPageGeometryValues(
        size: .zero,
        safeAreaTop: 0,
        safeAreaBottom: 0
    )

    /// Wall-clock start-of-day captured at the previous midnight check.  Used
    /// by the midnight handler to decide whether the day has rolled over.
    /// Initialised eagerly to "today" at view construction; the very first
    /// `.onAppear` therefore sees `daysCrossed == 0` and is a no-op.
    @State private var midnightLastKnownStartOfDay: Date = Calendar.current.startOfDay(for: Date())
    /// Days crossed since the last applied shift but not yet applied because a
    /// drag, resize-grace, or live-interrupt session was active.  Accumulates
    /// across multiple midnight crossings if the user holds a long gesture.
    @State private var midnightPendingDaysCrossed: Int = 0

    private let dayRangeExpansionStep: Int = 30
    private let dayRangeExpansionThreshold: Int = 14
    private let dayRangeExpansionBuffer: Int = 14
    private let topOverlayGap: CGFloat = 6
    private let topOverlayCapsuleExpandedHeight: CGFloat = 52
    private let topOverlayBottomFadeHeight: CGFloat = 12
    private let topOverlayGlassHorizontalBleed: CGFloat = 64
    private let topOverlayGlassTopOverflow: CGFloat = 24
    private let topOverlayGlassBottomCornerRadius: CGFloat = 30
    private let topOverlayGlassTintOpacity: CGFloat = 0.05
    private let dateLegendBarBottomPadding: CGFloat = 4
    private let dateLegendVerticalNudge: CGFloat = -6
    private let floatingMenuActivationDelay: TimeInterval = calendarEventExpressMenuAdditionalHoldDuration()
    private let resizeGraceDuration: TimeInterval = 2.5
    private let resizeGraceFadeDuration: TimeInterval = 0.35
    private let timelineAllDayPillHeight: CGFloat = 28
    private let timelineAllDaySectionPadding: CGFloat = 4

    var body: some View {
        pageBodyContent
            .onGeometryChange(for: CalendarPageGeometryValues.self) { proxy in
                CalendarPageGeometryValues(
                    size: proxy.size,
                    safeAreaTop: proxy.safeAreaInsets.top,
                    safeAreaBottom: proxy.safeAreaInsets.bottom
                )
            } action: { newValue in
                if calendarPageGeometryChanged(capturedPageGeometry, newValue, tolerance: 0.5) {
                    capturedPageGeometry = newValue
                }
            }
            .ignoresSafeArea(edges: [.top, .bottom])
        .navigationDestination(item: $selectedEventDetailRoute) { route in
            CalendarEventDetailView(route: route)
                .environmentObject(store)
        }
        .navigationDestination(item: $selectedEventChatOccurrence) { occurrence in
            CalendarEventChatView(occurrence: occurrence)
                .environmentObject(store)
        }
        .sheet(item: $selectedEventForEdit, onDismiss: {
            clearRecurrenceEditContext()
        }) { event in
            let recurrenceContext = pendingRecurrenceEdit?.event.id == event.id ? pendingRecurrenceEdit : nil
            EditCalendarEventView(
                event: event,
                occurrenceDate: recurrenceContext?.date,
                recurrenceScope: recurrenceContext == nil ? nil : recurrenceEditScope
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
                clearRecurrenceEditContext()
            }
        }
        .alert("Delete Event", isPresented: $showLongPressDeleteConfirm) {
            Button("Cancel", role: .cancel) {
                floatingMenuAnchor = nil
                floatingMenuInteractive = false
            }
            Button("Delete", role: .destructive) {
                if let anchor = floatingMenuAnchor {
                    let event = anchor.event
                    if event.isRecurringSeries, let occurrence = floatingMenuOccurrence {
                        store.deleteRecurringCalendarEvent(
                            seriesEvent: event,
                            occurrenceDate: occurrence.occurrenceDate,
                            scope: .single
                        )
                    } else {
                        store.deleteCalendarEvent(event)
                    }
                }
                floatingMenuAnchor = nil
                floatingMenuInteractive = false
            }
        } message: {
            if floatingMenuAnchor?.event.isRecurringSeries == true {
                Text("This occurrence will be deleted.")
            } else {
                Text("This event will be permanently deleted.")
            }
        }
        .sheet(item: $pendingCreateTimeRange) { pending in
            CreateCalendarEventView(
                timeRange: pending.timeRange,
                isTypeSuggestionEnabled: calendarAgenticCreateEnabled,
                onCreated: { event in
                    handleCreatedEvent(event, pendingCreate: pending)
                }
            )
            .environmentObject(store)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingDatePicker) {
            DateSelectorSheet(
                selection: $datePickerSelection,
                detent: $datePickerDetent,
                occurrencesForOffset: { occurrencesCache[$0] ?? [] },
                allDayOccurrencesForOffset: { allDayOccurrencesCache[$0] ?? [] },
                onConfirm: { selectedDate in
                    applyDatePickerSelection(selectedDate)
                    datePickerDetent = .medium
                    isShowingDatePicker = false
                },
                onDismiss: {
                    datePickerDetent = .medium
                    isShowingDatePicker = false
                }
            )
            .presentationDetents([.medium, .large], selection: $datePickerDetent)
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $isShowingSearch) {
            CalendarSearchView(
                onOpenEvent: { occurrence in
                    selectedEventDetailRoute = CalendarEventDetailRoute(occurrence: occurrence)
                },
                onOpenOccurrenceLog: { occurrence in
                    selectedEventDetailRoute = CalendarEventDetailRoute(
                        occurrence: occurrence,
                        initialJumpTarget: .log
                    )
                },
                onJumpToCalendar: { occurrence in
                    jumpToSearchOccurrence(occurrence)
                }
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $isShowingAgent) {
            NavigationStack {
                AgentChatView()
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $isShowingShare) {
            calendarShareSheetContent
        }
        .sheet(item: $eventShareContext) { context in
            CalendarEventShareSheet(context: context) {
                eventShareContext = nil
            }
            .environmentObject(store)
            .presentationDetents([.large])
        }
        .onAppear {
            if !hasAppearedOnce {
                hasAppearedOnce = true
                calendarState.selectedDayOffset = 0
                timelineVerticalScrollY = 0
                legendCenteredOffsetContinuous = CGFloat(calendarState.selectedDayOffset)
            } else if autoReturnToToday && calendarState.selectedDayOffset != 0 {
                calendarState.selectedDayOffset = 0
                legendCenteredOffsetContinuous = 0
            }
            expandDayRangeToInclude(calendarState.selectedDayOffset)
            rebuildOccurrencesCache()
            updateTimerRefresh()
            headerCapsulesVisible = true
            legendIsInteracting = false
            handleClockMaybeChanged(reason: "onAppear")
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            handleClockMaybeChanged(reason: "NSCalendarDayChanged")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Backstop: NSCalendarDayChanged is not guaranteed to fire when
            // the app was backgrounded across midnight.
            handleClockMaybeChanged(reason: "didBecomeActive")
        }
        .onChange(of: store.calendarEvents) {
            rebuildOccurrencesCache()
            updateTimerRefresh()
            if let focusedEventID,
               !store.calendarEvents.contains(where: { $0.id == focusedEventID }) {
                clearFocus(reason: "calendarEvents.changed.focusedEventRemoved")
            }
            if let graceOccurrence = resizeGraceOccurrenceContext,
               calendarResolvedEventForOccurrenceContext(graceOccurrence, in: store.calendarEvents) == nil {
                cancelResizeGrace(reason: "calendarEvents.changed.graceTargetRemoved")
            }
        }
        .onChange(of: focusedEventID) { _, newValue in
            calendarState.isEventFocused = newValue != nil
            calendarDebugLog(
                "calendar.focus.event.changed",
                fields: [
                    "focusedEventID": newValue?.uuidString ?? "nil",
                    "focusedOccurrenceID": focusedOccurrenceID ?? "nil"
                ]
            )
        }
        .onChange(of: focusedOccurrenceID) { _, newValue in
            calendarDebugLog(
                "calendar.focus.occurrence.changed",
                fields: [
                    "focusedEventID": focusedEventID?.uuidString ?? "nil",
                    "focusedOccurrenceID": newValue ?? "nil"
                ]
            )
        }
        .onChange(of: calendarState.selectedDayOffset) { oldValue, newValue in
            if !legendIsInteracting && timelineDragState.draggingEventID == nil {
                let isJump = abs(newValue - oldValue) > 1
                if accessibilityReduceMotion || isJump {
                    // Jump or reduced motion: snap directly, no animation.
                    // Avoids legend items colliding during rapid multi-day transitions.
                    legendCenteredOffsetContinuous = CGFloat(newValue)
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        legendCenteredOffsetContinuous = CGFloat(newValue)
                    }
                }
            }
            if !calendarShouldRetainTimelineBoundaryExtensionOnSelectedDayOffsetChange(
                currentState: timelineBoundaryExtensionState,
                rawState: timelineRawBoundaryExtensionState
            ) {
                clearTimelineBoundaryExtensionState()
            }
            if calendarState.rangeMode == .month {
                expandDayRangeForMonthContext(around: newValue)
            } else if !legendIsInteracting {
                expandDayRangeIfNeeded(for: newValue)
            }
            rebuildOccurrencesCacheForVisibleDays()
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
        .onChange(of: calendarState.rangeMode) { _, newValue in
            calendarState.persistRangeMode()
            clearTimelineBoundaryExtensionState()
            if newValue == .month {
                resetFloatingMenuState()
                cancelResizeGrace(reason: "calendar.rangeMode.month")
                clearFocus(reason: "calendar.rangeMode.month")
                headerCapsulesVisible = true
                timelineVerticalScrollY = 0
                expandDayRangeForMonthContext(around: calendarState.selectedDayOffset)
            } else if newValue == .stream {
                resetFloatingMenuState()
                cancelResizeGrace(reason: "calendar.rangeMode.stream")
                clearFocus(reason: "calendar.rangeMode.stream")
                headerCapsulesVisible = true
            }
        }
        .onChange(of: selectedEventDetailRoute) { _, newValue in
            if newValue != nil {
                clearTimelineBoundaryExtensionState()
            }
        }
        .onChange(of: dayRange) { oldRange, newRange in
            rebuildOccurrencesCacheIncremental(oldRange: oldRange, newRange: newRange)
        }
        .onChange(of: timelineDragState.draggingEventID) { _, newValue in
            if newValue == nil {
                tryApplyPendingMidnightShift(reason: "drag.ended")
            }
        }
        .onChange(of: resizeGraceState == nil) { _, isClear in
            if isClear {
                tryApplyPendingMidnightShift(reason: "resizeGrace.cleared")
            }
        }
        .onChange(of: liveInterruptSession == nil) { _, isClear in
            if isClear {
                tryApplyPendingMidnightShift(reason: "liveInterrupt.cleared")
            }
        }
        .onChange(of: legendIsInteracting) { _, isInteracting in
            if !isInteracting, calendarState.rangeMode != .month {
                expandDayRangeIfNeeded(for: calendarState.selectedDayOffset)
            }
        }
        .onDisappear {
            resetFloatingMenuState()
            pendingInterruptComposer = nil
            cancelResizeGrace(reason: "calendar.page.disappear")
            clearTimelineBoundaryExtensionState()
        }
    }
}

private extension CalendarPageView {
    @ViewBuilder
    var pageBodyContent: some View {
        let windowSafeAreaInsets = calendarWindowSafeAreaInsets()
        let safeAreaTop = calendarResolvedSafeAreaInset(
            proxyInset: capturedPageGeometry.safeAreaTop,
            windowInset: windowSafeAreaInsets.top
        )
        let safeAreaBottom = calendarResolvedSafeAreaInset(
            proxyInset: capturedPageGeometry.safeAreaBottom,
            windowInset: windowSafeAreaInsets.bottom
        )
        let metrics = CalendarPageMetrics(
            containerSize: capturedPageGeometry.size,
            safeAreaTop: safeAreaTop,
            safeAreaBottom: safeAreaBottom
        )
        let topOverlayCapsulesVisible = calendarTopOverlayCapsulesVisible(
            rangeMode: calendarState.rangeMode,
            storedVisibility: headerCapsulesVisible
        )
        let topOverlayActionCapsulesVisible = headerCapsulesVisible
        let legendBandHeight = calendarTopOverlayLegendBandHeight(for: calendarState.rangeMode)
        let topOverlayInset = calendarTopOverlayInset(
            safeAreaTop: metrics.safeAreaTop,
            isCapsuleVisible: topOverlayCapsulesVisible,
            legendBandHeight: legendBandHeight,
            overlayGap: topOverlayGap,
            capsuleExpandedHeight: topOverlayCapsuleExpandedHeight
        )

        pageContent(
            metrics: metrics,
            topOverlayInset: topOverlayInset,
            topOverlayCapsulesVisible: topOverlayCapsulesVisible,
            topOverlayActionCapsulesVisible: topOverlayActionCapsulesVisible
        )
        .geometryGroup()
        .overlay(alignment: .bottom) {
            if let banner = agenticCreateCoordinator.banner {
                GlassEffectContainer {
                    agenticBannerView(banner)
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, metrics.safeAreaBottom + 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(accessibilityReduceMotion ? nil : .spring(duration: 0.3), value: agenticCreateCoordinator.banner?.id)
            }
        }
    }

    @ViewBuilder
    func pageContent(
        metrics: CalendarPageMetrics,
        topOverlayInset: CGFloat,
        topOverlayCapsulesVisible: Bool,
        topOverlayActionCapsulesVisible: Bool
    ) -> some View {
        ZStack(alignment: .top) {
            Group {
                if calendarState.rangeMode == .month {
                    monthOverviewContent(
                        metrics: metrics,
                        topOverlayInset: topOverlayInset
                    )
                } else if calendarState.rangeMode == .stream {
                    listContent()
                } else {
                    timelineScroll(
                        metrics: metrics,
                        topOverlayInset: topOverlayInset
                    )
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: calendarState.rangeMode)

            topOverlay(
                metrics: metrics,
                topOverlayCapsulesVisible: topOverlayCapsulesVisible,
                topOverlayActionCapsulesVisible: topOverlayActionCapsulesVisible
            )

            if let anchor = floatingMenuAnchor {
                CalendarEventFloatingMenu(
                    anchorPoint: anchor.touchPointGlobal,
                    onViewDetails: {
                        if let occurrence = floatingMenuOccurrence {
                            selectedEventDetailRoute = CalendarEventDetailRoute(
                                occurrence: occurrence,
                                initialJumpTarget: .meta
                            )
                        }
                    },
                    onInterrupt: liveInterruptSession == nil ? {
                        if let occurrence = floatingMenuOccurrence {
                            presentInterruptComposer(
                                anchor: anchor,
                                occurrence: occurrence
                            )
                        }
                    } : nil,
                    onLogEvent: {
                        if let occurrence = floatingMenuOccurrence {
                            selectedEventDetailRoute = CalendarEventDetailRoute(
                                occurrence: occurrence,
                                initialJumpTarget: .log
                            )
                        }
                    },
                    onEdit: {
                        let event = anchor.event
                        if event.isRecurringSeries, let occurrence = floatingMenuOccurrence {
                            pendingRecurrenceEdit = (event: event, date: occurrence.occurrenceDate)
                            showRecurrenceScopeDialog = true
                        } else {
                            selectedEventForEdit = event
                        }
                    },
                    onShare: {
                        guard let occurrenceContext = floatingMenuOccurrence else { return }
                        let dayOccurrences = CalendarLayout.occurrencesForDate(
                            store.calendarEvents,
                            date: occurrenceContext.occurrenceDate
                        )
                        guard let resolved = dayOccurrences.first(where: {
                            $0.event.id == occurrenceContext.eventID
                        }) else { return }
                        eventShareContext = CalendarEventShareContext(
                            event: resolved.event,
                            range: resolved.range,
                            date: occurrenceContext.occurrenceDate
                        )
                    },
                    onDelete: {
                        showLongPressDeleteConfirm = true
                    },
                    onDismiss: {
                        hideFloatingMenu()
                    }
                )
                .allowsHitTesting(floatingMenuInteractive)
                .zIndex(100)
            }

            if let pendingInterruptComposer {
                CalendarInterruptComposer(
                    anchorPoint: pendingInterruptComposer.anchorPoint,
                    parentRange: pendingInterruptComposer.parentRange,
                    occupiedRanges: pendingInterruptComposer.occupiedRanges,
                    parentTypeTitle: pendingInterruptComposer.parentEvent.type,
                    onCreate: { title, type, range in
                        handleInterruptCreated(
                            parentEvent: pendingInterruptComposer.parentEvent,
                            occurrence: pendingInterruptComposer.occurrence,
                            title: title,
                            type: type,
                            timeRange: range
                        )
                    },
                    onStartLive: { title, type in
                        startLiveInterrupt(
                            parentEvent: pendingInterruptComposer.parentEvent,
                            occurrence: pendingInterruptComposer.occurrence,
                            title: title,
                            type: type
                        )
                    },
                    onDismiss: {
                        self.pendingInterruptComposer = nil
                    }
                )
                .zIndex(110)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            if let liveInterruptSession {
                CalendarInterruptLiveBar(
                    session: liveInterruptSession,
                    onStop: {
                        stopLiveInterrupt()
                    },
                    onCancel: {
                        cancelLiveInterrupt()
                    }
                )
                .padding(.top, topOverlayInset + 10)
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(120)
            }
        }
    }

    @ViewBuilder
    func topOverlay(
        metrics: CalendarPageMetrics,
        topOverlayCapsulesVisible: Bool,
        topOverlayActionCapsulesVisible: Bool
    ) -> some View {
        let showsDateLegend = calendarState.rangeMode == .threeDay || calendarState.rangeMode == .week
        let showsOverlayBackground = calendarState.rangeMode != .day && calendarState.rangeMode != .stream
        let legendBandHeight = calendarTopOverlayLegendBandHeight(for: calendarState.rangeMode)
        let overlayHeight = calendarTopOverlayInset(
            safeAreaTop: metrics.safeAreaTop,
            isCapsuleVisible: topOverlayCapsulesVisible,
            legendBandHeight: legendBandHeight,
            overlayGap: topOverlayGap,
            capsuleExpandedHeight: topOverlayCapsuleExpandedHeight
        ) + (showsOverlayBackground ? dateLegendBarBottomPadding : 0)
        let glassSurfaceHeight = overlayHeight + topOverlayGlassTopOverflow
        let fadeStart = calendarOverlayFadeMaskStart(
            totalHeight: glassSurfaceHeight,
            fadeHeight: topOverlayBottomFadeHeight
        )

        VStack(spacing: 0) {
            if calendarState.rangeMode == .month {
                header(
                    metrics: metrics,
                    isCapsulesVisible: topOverlayCapsulesVisible,
                    isActionCapsulesVisible: topOverlayActionCapsulesVisible
                )
                monthLegendBar(metrics: metrics)
            } else {
                VerticalScrollGate(isScrolling: isVerticallyScrolling) {
                    header(
                        metrics: metrics,
                        isCapsulesVisible: topOverlayCapsulesVisible,
                        isActionCapsulesVisible: topOverlayActionCapsulesVisible
                    )
                }
                if showsDateLegend {
                    dateLegendBar(metrics: metrics)
                        .offset(y: dateLegendVerticalNudge)
                }
            }
        }
        .padding(.top, metrics.safeAreaTop + topOverlayGap)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(alignment: .top) {
            if showsOverlayBackground {
                topOverlayGlassSurface(
                    height: overlayHeight,
                    width: metrics.containerSize.width
                )
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

    func topOverlayGlassSurface(height: CGFloat, width: CGFloat) -> some View {
        let panelShape = UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 0,
                bottomLeading: topOverlayGlassBottomCornerRadius,
                bottomTrailing: topOverlayGlassBottomCornerRadius,
                topTrailing: 0
            ),
            style: .continuous
        )
        let expandedWidth = max(1, width + topOverlayGlassHorizontalBleed * 2)
        let expandedHeight = max(1, height + topOverlayGlassTopOverflow)

        return Color.clear
            .glassEffect(
                .clear.tint(Color.white.opacity(topOverlayGlassTintOpacity)),
                in: panelShape
            )
            .backgroundExtensionEffect()
            .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
            .offset(y: -topOverlayGlassTopOverflow)
    }
}

private extension CalendarPageView {
    @ViewBuilder
    func listContent() -> some View {
        CalendarListView()
            .environmentObject(store)
    }

    func monthOverviewContent(metrics: CalendarPageMetrics, topOverlayInset: CGFloat) -> some View {
        return MonthOverviewPagerView(
            selectedDayOffset: calendarState.selectedDayOffset,
            occurrencesForOffset: { occurrencesCache[$0] ?? [] },
            allDayOccurrencesForOffset: { allDayOccurrencesCache[$0] ?? [] },
            topContentInset: topOverlayInset,
            onSelectDay: { dayOffset in
                clearFocus(reason: "month.selectDay")
                calendarState.selectedDayOffset = dayOffset
                calendarState.rangeMode = .threeDay
            },
            onMonthPageChanged: { deltaMonths in
                handleMonthPageChange(deltaMonths)
            }
        )
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.bottom, max(24, metrics.safeAreaBottom + 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    func agenticBannerView(_ banner: CalendarAgenticBannerState) -> some View {
        HStack(spacing: 8) {
            bannerLeadingIcon(banner)

            Text(agenticBannerTitle(banner))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let action = agenticBannerAction(banner) {
                if let systemImage = action.systemImage {
                    Button {
                        action.handler()
                    } label: {
                        Image(systemName: systemImage)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action.title) {
                        action.handler()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            Button {
                agenticCreateCoordinator.dismissBanner()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 16, weight: .semibold))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(
            .regular.tint(agenticBannerStrokeColor(banner).opacity(0.08)),
            in: Capsule()
        )
    }

    @ViewBuilder
    func bannerLeadingIcon(_ banner: CalendarAgenticBannerState) -> some View {
        switch banner {
        case .analyzing:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 18, height: 18)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)
        }
    }

    func agenticBannerTitle(_ banner: CalendarAgenticBannerState) -> String {
        switch banner {
        case .analyzing:
            return "AI 正在完善事件…"
        case .failed:
            return "AI 完善失败，事件已保留"
        }
    }

    func agenticBannerStrokeColor(_ banner: CalendarAgenticBannerState) -> Color {
        switch banner {
        case .analyzing:
            return .accentColor
        case .failed:
            return .orange
        }
    }

    func agenticBannerAction(_ banner: CalendarAgenticBannerState) -> (title: String, systemImage: String?, handler: () -> Void)? {
        switch banner {
        case .analyzing:
            return nil
        case .failed(let eventID, _):
            return ("Edit", "pencil", { openCalendarEventEditor(id: eventID) })
        }
    }

    func jumpToSearchOccurrence(_ occurrence: CalendarEventOccurrenceContext) {
        guard let event = calendarResolvedEventForOccurrenceContext(occurrence, in: store.calendarEvents) else {
            return
        }

        cancelResizeGrace(reason: "search.jumpToCalendar")
        resetFloatingMenuState()
        pendingInterruptComposer = nil

        let offset = dayOffset(for: occurrence.occurrenceDate)
        if calendarState.rangeMode == .month {
            expandDayRangeForMonthContext(around: offset)
            calendarState.selectedDayOffset = offset
            calendarState.rangeMode = .threeDay
        } else {
            expandDayRangeToInclude(offset)
            calendarState.selectedDayOffset = offset
        }

        let occurrenceID = calendarOccurrenceDisplayRange(
            event: event,
            occurrenceDate: occurrence.occurrenceDate
        ).map {
            calendarOccurrenceIDForRange(
                event: event,
                range: $0,
                occurrenceDate: occurrence.occurrenceDate
            )
        } ?? occurrence.occurrenceID

        setFocus(
            event: event,
            occurrenceID: occurrenceID,
            reason: "search.jumpToCalendar"
        )
    }

    func openCalendarEventEditor(id: UUID) {
        guard let event = store.calendarEvents.first(where: { $0.id == id }) else { return }
        cancelResizeGrace(reason: "banner.openEditor")
        selectedEventForEdit = event
        agenticCreateCoordinator.dismissBanner()
    }

    func clearRecurrenceEditContext() {
        pendingRecurrenceEdit = nil
        recurrenceEditScope = nil
    }

    func makeOccurrenceContext(
        event: Event,
        actionDate: Date,
        occurrenceID: String?,
        isAllDay: Bool,
        source: CalendarEventOccurrenceContext.Source
    ) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: actionDate,
            occurrenceID: occurrenceID,
            isAllDay: isAllDay,
            source: source
        )
    }

    func committedOccurrenceContext(
        event: Event,
        preferredRange: Event.TimeRange,
        occurrenceDate: Date
    ) -> CalendarEventOccurrenceContext {
        let resolvedOccurrenceID = calendarResolvedFocusedOccurrenceID(
            event: event,
            preferredRange: preferredRange
        ) ?? calendarOccurrenceIDForRange(
            event: event,
            range: preferredRange,
            occurrenceDate: occurrenceDate
        )

        return makeOccurrenceContext(
            event: event,
            actionDate: occurrenceDate,
            occurrenceID: resolvedOccurrenceID,
            isAllDay: event.isAllDay,
            source: .timelineLongPress
        )
    }

    /// Find the recurring exception event that was just created by `applyRecurringEdit`.
    private func findRecurringException(
        for event: Event,
        draggedRange: Event.TimeRange,
        newRange: Event.TimeRange
    ) -> Event? {
        let calendar = Calendar.current
        let occurrenceDay = calendar.startOfDay(for: draggedRange.start)
        return store.calendarEvents.last { candidate in
            candidate.recurrenceParentId == event.id
                && candidate.recurrenceInstanceDate.map { calendar.isDate($0, inSameDayAs: occurrenceDay) } == true
                && candidate.effectiveTimeRanges.contains {
                    calendarRangesApproximatelyEqual(lhs: $0, rhs: newRange)
                }
        }
    }

    func beginResizeGrace(
        for occurrence: CalendarEventOccurrenceContext,
        trigger: CalendarResizeGraceTrigger
    ) {
        clearFocus(reason: "resizeGrace.begin.\(trigger.rawValue)")
        resizeGraceFadeTask?.cancel()
        resizeGraceFadeTask = nil
        resizeGraceExpiryTask?.cancel()
        resizeGraceExpiryTask = nil

        let now = Date()
        let deadline = now.addingTimeInterval(resizeGraceDuration)
        let fadeStartAt = deadline.addingTimeInterval(-resizeGraceFadeDuration)
        resizeGraceOccurrenceContext = occurrence
        resizeGraceState = CalendarResizeGraceState(
            eventID: occurrence.eventID,
            occurrenceID: occurrence.occurrenceID,
            startedAt: now,
            deadline: deadline,
            fadeStartAt: fadeStartAt,
            handleOpacity: 1,
            trigger: trigger
        )
        scheduleResizeGraceFade()
        scheduleResizeGraceExpiry()
    }

    func restartResizeGrace(
        for occurrence: CalendarEventOccurrenceContext,
        trigger: CalendarResizeGraceTrigger
    ) {
        beginResizeGrace(for: occurrence, trigger: trigger)
    }

    func cancelResizeGrace(reason: String) {
        guard resizeGraceState != nil || resizeGraceOccurrenceContext != nil else { return }
        calendarDebugLog(
            "calendar.resizeGrace.cancel",
            fields: [
                "reason": reason,
                "eventID": resizeGraceState?.eventID.uuidString ?? resizeGraceOccurrenceContext?.eventID.uuidString ?? "nil",
                "occurrenceID": resizeGraceState?.occurrenceID ?? resizeGraceOccurrenceContext?.occurrenceID ?? "nil"
            ]
        )
        resizeGraceFadeTask?.cancel()
        resizeGraceFadeTask = nil
        resizeGraceExpiryTask?.cancel()
        resizeGraceExpiryTask = nil
        resizeGraceState = nil
        resizeGraceOccurrenceContext = nil
    }

    func scheduleResizeGraceFade() {
        guard resizeGraceState != nil else { return }
        resizeGraceFadeTask?.cancel()
        resizeGraceFadeTask = Task { @MainActor in
            let fadeDelay = max(0, resizeGraceDuration - resizeGraceFadeDuration)
            try? await Task.sleep(nanoseconds: UInt64(fadeDelay * 1_000_000_000))
            guard !Task.isCancelled, resizeGraceState != nil else { return }
            withAnimation(.linear(duration: resizeGraceFadeDuration)) {
                resizeGraceState?.handleOpacity = 0
            }
        }
    }

    func scheduleResizeGraceExpiry() {
        guard resizeGraceState != nil else { return }
        resizeGraceExpiryTask?.cancel()
        resizeGraceExpiryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(resizeGraceDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            resizeGraceState = nil
            resizeGraceOccurrenceContext = nil
            resizeGraceFadeTask?.cancel()
            resizeGraceFadeTask = nil
            resizeGraceExpiryTask = nil
        }
    }

}

private extension CalendarPageView {
    func header(
        metrics: CalendarPageMetrics,
        isCapsulesVisible: Bool,
        isActionCapsulesVisible: Bool
    ) -> some View {
        let headerDisplayDate = calendarResolvedHeaderDisplayDate(
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode,
            currentScrollY: timelineVerticalScrollY,
            headerHeight: timelineHeaderHeight,
            hourHeight: calendarState.timelineHourHeight,
            boundaryExtensionState: timelineBoundaryExtensionState,
            draggingEventID: timelineDragState.draggingEventID,
            dragMode: timelineDragState.dragMode,
            dragTouchPointGlobal: timelineDragState.currentTouchPointGlobal,
            timelineFrameGlobal: timelineVisibleDayFrameGlobal
        )
        let leftCapsuleTitle = calendarResolvedHeaderCapsuleTitle(
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode,
            headerDisplayDate: headerDisplayDate
        )

        return AppleCalendarHeaderView(
            selectedDate: headerDisplayDate,
            rangeMode: calendarState.rangeMode,
            leftCapsuleTitle: leftCapsuleTitle,
            isCapsulesVisible: isCapsulesVisible,
            isActionCapsuleVisible: isActionCapsulesVisible,
            onMonthTap: {
                clearFocus()
                presentDatePicker(for: headerDisplayDate)
            },
            onMonthLongPress: {
                jumpToNowFromHeader(metrics: metrics, isCapsulesVisible: isCapsulesVisible)
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
                isShowingSearch = true
            },
            onAddTap: {
                clearFocus()
                let range = defaultQuickAddTimeRange()
                pendingCreateTimeRange = PendingEventCreation(
                    date: range.start,
                    timeRange: range,
                    source: .quickAdd,
                    anchorVisibleDate: visibleDate
                )
            },
            onFocusTap: {
                clearFocus()
                orientationManager.manualFocusActive = true
            },
            onShareTap: {
                clearFocus()
                isShowingShare = true
            }
        )
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(
            height: calendarCapsuleVisibleHeight(
                isVisible: isCapsulesVisible
            ),
            alignment: .top
        )
    }

    @ViewBuilder
    private var calendarShareSheetContent: some View {
        let shareDate = calendarDateForSelectedDayOffset(calendarState.selectedDayOffset)
        let occurrences = CalendarLayout.occurrencesForDate(store.calendarEvents, date: shareDate)
        let selectedStyle = CalendarDailyShareStyle(rawValue: shareStyleRaw) ?? .calendar
        let resolvedAvatarHue: Double? = shareAvatarHue >= 0 ? shareAvatarHue : nil
        let card = CalendarDailyShareCard(
            date: shareDate,
            occurrences: occurrences,
            style: selectedStyle,
            displayName: shareDisplayName,
            avatarHue: resolvedAvatarHue
        )
        NavigationStack {
            VStack(spacing: 0) {
                // Custom top bar — matches the New Event sheet (ultraThinMaterial
                // capsule) so all sheet headers in the app feel consistent.
                ZStack {
                    Text("Share day")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    HStack {
                        Spacer()
                        Button {
                            isShowingShare = false
                        } label: {
                            Text(L(.done))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .contentShape(Capsule())
                                .background(Color.black.opacity(0.001), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                GeometryReader { proxy in
                let topInset: CGFloat = 12
                let pickerEstimate: CGFloat = 78
                let shareEstimate: CGFloat = 48
                let minSpacing: CGFloat = 14
                let bottomInset: CGFloat = 12
                let reserved = topInset + pickerEstimate + minSpacing + shareEstimate + bottomInset
                let cardHeightBudget = max(0, proxy.size.height - reserved)
                let cardWidthBudget = max(0, proxy.size.width - 24)
                let scaleByHeight = cardHeightBudget / CalendarDailyShareCard.cardSize.height
                let scaleByWidth = cardWidthBudget / CalendarDailyShareCard.cardSize.width
                let previewScale = min(scaleByHeight, scaleByWidth, 0.92)

                VStack(spacing: 0) {
                    card
                        .scaleEffect(previewScale)
                        .frame(
                            width: CalendarDailyShareCard.cardSize.width * previewScale,
                            height: CalendarDailyShareCard.cardSize.height * previewScale
                        )
                        .shadow(color: Color.black.opacity(0.15), radius: 18, x: 0, y: 6)
                        .padding(.top, topInset)

                    calendarShareStylePicker(
                        shareDate: shareDate,
                        occurrences: occurrences,
                        displayName: shareDisplayName,
                        avatarHue: resolvedAvatarHue
                    )
                    .padding(.top, 14)

                    Spacer(minLength: minSpacing)

                    if let image = calendarDailyShareCardRender(card) {
                        let item = CalendarDailyShareItem(image: image)
                        ShareLink(
                            item: item,
                            preview: SharePreview("Today on Done", image: item)
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Share")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity)
                            .frame(height: shareEstimate)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .padding(.bottom, bottomInset)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func calendarShareStylePicker(
        shareDate: Date,
        occurrences: [CalendarLayout.EventOccurrence],
        displayName: String,
        avatarHue: Double?
    ) -> some View {
        let swatchWidth: CGFloat = 84
        let swatchHeight: CGFloat = 52
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(CalendarDailyShareStyle.allCases) { style in
                    let isSelected = shareStyleRaw == style.rawValue
                    Button {
                        shareStyleRaw = style.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            style.swatch()
                                .frame(width: swatchWidth, height: swatchHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                            lineWidth: isSelected ? 2 : 1
                                        )
                                )
                            Text(style.displayLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
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
            // Match TimelineContainerView layout exactly:
            // Timeline gets (screenWidth - horizontalPadding) due to trailing negative padding,
            // then subtracts labelWidth + timelineEdgePadding*2.
            let labelWidth: CGFloat = 32
            let timelineEdgePadding: CGFloat = 6
            let daysCount = visibleCount
            let dayAreaWidth = max(0, proxy.size.width - metrics.horizontalPadding - labelWidth - timelineEdgePadding * 2)
            let dayWidth = daysCount == 1
                ? dayAreaWidth
                : max(0, dayAreaWidth / CGFloat(daysCount))
            let dayStep = dayWidth
            let baseTrackOffsetX = -CGFloat(overscan) * dayStep
            let interactionTrackOffsetX = calendarLegendTrackTranslation(
                fraction: fraction,
                dayStep: dayStep
            )

            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 30)
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
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
            .padding(.leading, metrics.horizontalPadding + timelineEdgePadding)
            .padding(.trailing, timelineEdgePadding)
            .frame(width: proxy.size.width, height: 30, alignment: .leading)
        }
        .frame(height: 30)
        .overlay(alignment: .top) {
            boundaryExtensionLegendIndicators(metrics: metrics)
        }
        .padding(.bottom, dateLegendBarBottomPadding)
        .contentShape(Rectangle())
        .onTapGesture {
            clearFocus()
        }
    }

    func monthLegendBar(metrics: CalendarPageMetrics) -> some View {
        CalendarMonthLegendBar(selectedDayOffset: calendarState.selectedDayOffset)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(
                height: calendarTopOverlayLegendBandHeight(for: .month),
                alignment: .bottom
            )
            .padding(.bottom, dateLegendBarBottomPadding)
    }

    var effectiveLegendCenteredOffsetContinuous: CGFloat {
        let fallback = CGFloat(calendarState.selectedDayOffset)
        guard legendCenteredOffsetContinuous.isFinite else { return fallback }
        return legendCenteredOffsetContinuous
    }

    private var timelineHeaderHeight: CGFloat {
        calendarTimelineTopInset(hourHeight: calendarState.timelineHourHeight)
    }

    private var timelineAllDayHeight: CGFloat {
        let maxCount = dayRange.reduce(0) { partialResult, offset in
            max(partialResult, allDayOccurrencesCache[offset]?.count ?? 0)
        }
        guard maxCount > 0 else { return 0 }
        return CGFloat(maxCount) * timelineAllDayPillHeight + timelineAllDaySectionPadding * 2
    }

    func dateForLegendDayOffset(_ dayOffset: Int) -> Date {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: dayOffset, to: startOfToday) ?? startOfToday
    }

    @ViewBuilder
    func boundaryExtensionLegendIndicators(metrics: CalendarPageMetrics) -> some View {
        let hasLeadingExtension = timelineBoundaryExtensionState.leadingHours > 0
        let hasTrailingExtension = timelineBoundaryExtensionState.trailingHours > 0
        let hasAny = hasLeadingExtension || hasTrailingExtension
        let isSingleDay = calendarState.rangeMode == .day
        let anchorOffset = timelineBoundaryExtensionState.anchorDayOffset
            ?? calendarState.selectedDayOffset

        // Only show the date legend pill in single-day mode — in multi-day
        // views the pill floats over all columns and misleads the user about
        // which day the extension belongs to. Column headers already provide
        // enough date context in 3-day/week mode.
        if isSingleDay {
            HStack(spacing: 0) {
                if hasLeadingExtension {
                    boundaryExtensionLegendIndicator(
                        date: dateForLegendDayOffset(anchorOffset - 1),
                        isTrailingEdge: false
                    )
                }
                Spacer(minLength: 0)
                if hasTrailingExtension {
                    boundaryExtensionLegendIndicator(
                        date: dateForLegendDayOffset(anchorOffset + 1),
                        isTrailingEdge: true
                    )
                }
            }
            .padding(.horizontal, metrics.horizontalPadding + 40)
            .offset(y: -14)
            .opacity(hasAny ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: hasAny)
            .allowsHitTesting(false)
        }
    }

    func boundaryExtensionLegendIndicator(date: Date, isTrailingEdge: Bool) -> some View {
        HStack(spacing: 4) {
            if isTrailingEdge {
                Text(Self.dateLegendDayFormatter.string(from: date))
                Text(Self.dateLegendWeekdayFormatter.string(from: date).uppercased())
                    .foregroundStyle(.secondary)
            } else {
                Text(Self.dateLegendWeekdayFormatter.string(from: date).uppercased())
                    .foregroundStyle(.secondary)
                Text(Self.dateLegendDayFormatter.string(from: date))
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.001), in: Capsule())
        .glassEffect(.regular, in: Capsule())
    }

    func handleTimelineHorizontalScrollProgress(_ progress: TimelineHorizontalScrollProgress) {
        guard progress.centeredDayOffsetContinuous.isFinite else { return }
        let wasInteracting = legendIsInteracting
        legendIsInteracting = progress.isInteracting
        let shouldAnimate = !progress.isInteracting && wasInteracting && !accessibilityReduceMotion
        let apply = {
            legendCenteredOffsetContinuous = progress.centeredDayOffsetContinuous
        }
        if shouldAnimate {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.1), apply)
        } else {
            apply()
        }
    }

    func handleTimelineBoundaryExtensionStateChange(_ newState: TimelineBoundaryExtensionState) {
        // Extended view is only supported in day view — multi-day
        // columns are too narrow for meaningful extended interaction.
        guard calendarState.rangeMode == .day else {
            if timelineBoundaryExtensionState != .none {
                clearTimelineBoundaryExtensionState()
            }
            return
        }
        timelineRawBoundaryExtensionState = newState
        let retainedState = calendarRetainedTimelineBoundaryExtensionState(
            currentState: timelineBoundaryExtensionState,
            rawState: newState
        )
        applyTimelineBoundaryExtensionState(retainedState)

        // When the drag source clears (finger lifted) near max
        // pinch, the extension can't be scrolled away naturally
        // (scroll range too small).  Dismiss directly with fade.
        if newState.source == nil, retainedState.hasAnyExtension {
            let hourHeight = calendarState.timelineHourHeight
            let baseContentHeight = CGFloat(calendarTimelineBaseVisibleHours) * hourHeight
            let scrollableRange = baseContentHeight - timelineScrollViewportHeight
            if scrollableRange < hourHeight * 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                    guard timelineRawBoundaryExtensionState.source == nil else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        clearTimelineBoundaryExtensionState()
                    }
                }
            }
        }
    }

    func applyTimelineBoundaryExtensionState(_ newState: TimelineBoundaryExtensionState) {
        let previousState = timelineBoundaryExtensionState
        guard previousState != newState else { return }

        // Haptic when the extended view first opens — the double-pulse
        // .warning notification feel is distinct from the single-tap
        // .light impact used for 15-minute snap boundaries during drag.
        let leadingOpened = previousState.leadingHours == 0 && newState.leadingHours > 0
        let trailingOpened = previousState.trailingHours == 0 && newState.trailingHours > 0
        if leadingOpened || trailingOpened {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        let targetY = calendarResolvedVerticalScrollOffsetForBoundaryExtensionChange(
            currentOffsetY: timelineVerticalScrollY,
            previousState: previousState,
            newState: newState,
            hourHeight: calendarState.timelineHourHeight
        )

        timelineBoundaryExtensionState = newState

        guard let targetY else { return }

        pendingBoundaryExtensionScrollTask?.cancel()
        let targetPoint = CGPoint(x: 0, y: targetY)
        if calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: newState.source) {
            pendingBoundaryExtensionScrollTask = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                verticalScrollPosition.scrollTo(point: targetPoint)
            }
            return
        }
        pendingBoundaryExtensionScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                verticalScrollPosition.scrollTo(point: targetPoint)
            }
        }
    }

    func collapseTimelineBoundaryExtensionsIfNeeded(topOverlayInset: CGFloat) {
        guard timelineRawBoundaryExtensionState.source == nil else { return }
        guard timelineBoundaryExtensionState.hasAnyExtension else { return }

        let visibility = calendarTimelineBoundaryExtensionVisibility(
            currentOffsetY: timelineVerticalScrollY,
            viewportHeight: timelineScrollViewportHeight,
            contentTopInset: topOverlayInset,
            allDayHeight: timelineAllDayHeight,
            headerHeight: timelineHeaderHeight,
            hourHeight: calendarState.timelineHourHeight,
            state: timelineBoundaryExtensionState
        )
        let collapsedState = calendarCollapsedTimelineBoundaryExtensionState(
            currentState: timelineBoundaryExtensionState,
            leadingVisible: visibility.leadingVisible,
            trailingVisible: visibility.trailingVisible
        )
        guard collapsedState != timelineBoundaryExtensionState else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            applyTimelineBoundaryExtensionState(collapsedState)
        }
    }

    func clearTimelineBoundaryExtensionState() {
        pendingBoundaryExtensionScrollTask?.cancel()
        pendingBoundaryExtensionScrollTask = nil
        timelineRawBoundaryExtensionState = .none
        timelineBoundaryExtensionState = .none
    }

    /// If the persisted hourHeight is below the current viewport's pinch
    /// fit min (e.g. because it was saved with an older calculation), bump
    /// it up.  Called when viewport state becomes available so the user
    /// immediately sees the "whole day fits" view as the smallest state.
    func applyDynamicPinchMinIfNeeded(topOverlayInset: CGFloat, bottomInset: CGFloat) {
        guard timelineScrollViewportHeight > 0 else { return }
        // Dedup: with identical inputs the calc is pure and the mutation is
        // idempotent (if bumped, hourHeight == dynamicMin and the next check
        // is a no-op).  Without this gate the function ran on every vertical
        // scroll frame even though only rotation / inset / hourHeight changes
        // can produce a different result.
        let inputs = DynamicPinchMinInputs(
            viewport: timelineScrollViewportHeight,
            topInset: topOverlayInset,
            bottomInset: bottomInset,
            hourHeight: calendarState.timelineHourHeight
        )
        if lastDynamicPinchMinInputs == inputs { return }
        lastDynamicPinchMinInputs = inputs
        let dynamicMin = calendarPinchEffectiveMinHourHeight(
            viewportHeight: timelineScrollViewportHeight,
            contentTopInset: topOverlayInset,
            contentBottomInset: bottomInset,
            allDayHeight: 0  // safe lower bound; using 0 means we under-correct rather than over-correct
        )
        if calendarState.timelineHourHeight < dynamicMin {
            calendarState.setTimelineHourHeight(dynamicMin)
            calendarState.commitTimelineHourHeight()
        }
    }

    /// Effective unavailable space below the timeline for the pinch fit
    /// calculation.  metrics.safeAreaBottom only covers the home indicator
    /// (~34 pt); the iOS tab bar adds another ~49 pt above it, plus a
    /// small comfort margin so 24:00 sits clearly above the tab bar.
    private func pinchBottomInset(metrics: CalendarPageMetrics) -> CGFloat {
        metrics.safeAreaBottom + 49 + 16
    }

    func timelineScroll(metrics: CalendarPageMetrics, topOverlayInset: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                timelineLayer(
                    // Include effortOpacityEnabled in the rebuild key so the
                    // entire timeline force-rebuilds when the user toggles
                    // effort-based opacity in settings — the new opacity
                    // values then propagate through every event block.
                    rebuildKey: "timeline-\(calendarState.rangeMode)-effortOpacity\(effortOpacityEnabled)",
                    topOverlayInset: topOverlayInset,
                    bottomInset: pinchBottomInset(metrics: metrics)
                )
                    // Keep leading alignment with the page rhythm, but let the
                    // timeline content consume the trailing page inset.
                    .padding(.trailing, -metrics.horizontalPadding)
                    .geometryGroup()
            }
            .padding(.top, topOverlayInset)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.bottom, metrics.timelineBottomScrollPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($verticalScrollPosition)
        .task {
            if needsScrollToNow {
                needsScrollToNow = false
                // Yield to let ScrollView complete initial layout before setting position.
                try? await Task.sleep(for: .milliseconds(50))
                let targetY = currentTimeScrollOffset(
                    topOverlayInset: topOverlayInset,
                    hourHeight: calendarState.timelineHourHeight
                )
                verticalScrollPosition.scrollTo(point: CGPoint(x: 0, y: targetY))
            }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
            let scrollY = newValue.contentOffset.y
            // Viewport height almost never changes during a scroll — gate the
            // write so we don't invalidate every @State consumer (header,
            // TimelinePagerView's effectiveMinHourHeight, currentTimeScrollOffset)
            // every frame.
            let newViewportHeight = newValue.visibleRect.height
            if abs(newViewportHeight - timelineScrollViewportHeight) > 0.5 {
                timelineScrollViewportHeight = newViewportHeight
            }
            // Gate the scrollY write at 2pt: this @State is read by
            // `calendarResolvedHeaderDisplayDate` and propagated to
            // TimelinePagerView (`verticalScrollY` prop), so every write
            // re-evaluates the header subtree and re-inits TimelinePagerView.
            // Sub-2pt deltas are below user perception but at 60fps they
            // produced ~60 body invalidations per second of scroll.  The same
            // threshold gates `cancelResizeGrace` since "real" scrolling is
            // ≥2pt anyway; sub-pixel layout settle shouldn't dismiss the
            // grace handle.
            if abs(scrollY - timelineVerticalScrollY) >= 2 {
                cancelResizeGrace(reason: "timeline.verticalScroll")
                timelineVerticalScrollY = scrollY
            }
            collapseTimelineBoundaryExtensionsIfNeeded(topOverlayInset: topOverlayInset)
            // Once viewport is established, bump persisted hourHeight up
            // to the current "whole day fits" point if it's smaller.
            // Must use the SAME bottom inset as the pinch handler so the
            // auto-correct converges to the same value pinch will produce.
            applyDynamicPinchMinIfNeeded(
                topOverlayInset: topOverlayInset,
                bottomInset: pinchBottomInset(metrics: metrics)
            )
            // Keep header capsules always visible — don't hide on scroll.
            if !headerCapsulesVisible {
                headerCapsulesVisible = true
            }
        }
        .onScrollPhaseChange { _, newPhase in
            // Track phase so `VerticalScrollGate` can freeze its subtree body
            // re-evaluation while the user is actively scrolling.  Treat both
            // `.interacting` and `.decelerating` as "scrolling" — settle
            // (.idle) is when we want the catch-up re-eval to fire.
            let isScrollingNow = (newPhase == .interacting || newPhase == .decelerating)
            if isVerticallyScrolling != isScrollingNow {
                isVerticallyScrolling = isScrollingNow
            }
        }
        .mask {
            TimelineMaskView(
                top: metrics.topMaskConfig,
                bottom: metrics.bottomMaskConfig
            )
        }
    }

    /// Compute the vertical content offset that centers the current time on screen.
    func currentTimeScrollOffset(topOverlayInset: CGFloat, hourHeight: CGFloat) -> CGFloat {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let secondsSinceStart = now.timeIntervalSince(startOfDay)
        let hoursFraction = CGFloat(secondsSinceStart / 3600)
        let rawOffset = topOverlayInset + hoursFraction * hourHeight
        // Nudge upward so current time lands ~30% from the top of the
        // viewport instead of flush at the top edge.
        let viewportNudge = timelineScrollViewportHeight * 0.3
        return max(0, rawOffset - viewportNudge)
    }

    @ViewBuilder
    func timelineLayer(rebuildKey: String, topOverlayInset: CGFloat, bottomInset: CGFloat) -> some View {
        let timelineHourHeightBinding = Binding<CGFloat>(
            get: { calendarState.timelineHourHeight },
            set: { calendarState.setTimelineHourHeight($0) }
        )

        VerticalScrollGate(isScrolling: isVerticallyScrolling) {
            TimelinePagerView(
            dragState: timelineDragState,
            occurrencesForOffset: { occurrencesCache[$0] ?? [] },
            allDayOccurrencesForOffset: { allDayOccurrencesCache[$0] ?? [] },
            maxAllDayCountOverride: maxAllDayCountCache,
            selectedDayOffset: $calendarState.selectedDayOffset,
            rangeMode: $calendarState.rangeMode,
            hourHeight: timelineHourHeightBinding,
            liveHourHeight: liveHourHeight,
            isDayOffsetFrozen: calendarState.isDayOffsetFrozen,
            daysCount: timelineDaysCount(for: calendarState.rangeMode),
            mode: .preview,
            showEventText: timelineShowEventText(for: calendarState.rangeMode),
            dayRange: dayRange,
            previewCreation: pendingCreateTimeRange,
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
            previewHandleEventID: nil,
            previewHandleOccurrenceID: nil,
            previewHandleOpacity: 1,
            graceResizeEventID: resizeGraceState?.eventID,
            graceResizeOccurrenceID: resizeGraceState?.occurrenceID,
            graceResizeHandleOpacity: resizeGraceState?.handleOpacity ?? 1,
            onEventTap: handleTimelineEventTap,
            onEventLongPressBegan: handleTimelineLongPressBegan,
            onEventManipulationPromotion: handleTimelineManipulationPromotion,
            onEventLongPressResolved: handleTimelineLongPressResolved,
            onEventDragEnded: handleTimelineEventDragEnded,
            onEventResizeEnded: handleTimelineEventResizeEnded,
            onCreateEvent: handleTimelineCreateEvent,
            onNonEventTap: handleTimelineNonEventTap,
            onHourHeightCommit: handleTimelineHourHeightCommit,
            onHorizontalScrollProgress: handleTimelineHorizontalScroll,
            onBoundaryExtensionStateChange: handleTimelineBoundaryExtensionStateChange,
            onVisibleTimelineFrameChange: handleVisibleTimelineFrameChange,
            verticalScrollY: timelineVerticalScrollY,
            verticalViewportHeight: timelineScrollViewportHeight,
            verticalContentTopInset: topOverlayInset,
            verticalContentBottomInset: bottomInset,
            onPinchScrollAdjust: { newScrollY in
                // The pinch handler already wraps this call in a
                // disablesAnimations transaction so hourHeight + scroll
                // are batched into one render pass.
                verticalScrollPosition.scrollTo(point: CGPoint(x: 0, y: newScrollY))
            },
            boundaryExtensionStateOverride: timelineBoundaryExtensionState,
            liveInterruptSession: liveInterruptSession
        )
        // Rebuild when range changes to avoid stale TabView pages across layouts.
        .id(rebuildKey)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Mirror `calendarState.timelineHourHeight` into the ref-type holder
        // so EventBlock's deep reads (drag/resize math) always see the
        // current value.  `.onAppear` seeds it, `.onChange` catches every
        // later write regardless of which code path produced it.
        .onAppear {
            liveHourHeight.value = calendarState.timelineHourHeight
        }
        .onChange(of: calendarState.timelineHourHeight) { _, newValue in
            liveHourHeight.value = newValue
        }
    }

    // MARK: - Timeline Callback Methods (extracted from timelineLayer)

    func handleTimelineEventTap(_ event: Event, _ date: Date) {
        resetFloatingMenuState()
        pendingInterruptComposer = nil
        cancelResizeGrace(reason: "timeline.tap")
        clearFocus(reason: "timeline.tap.openDetail")
        let source: CalendarEventOccurrenceContext.Source = event.isAllDay ? .allDayTap : .timelineTap
        selectedEventDetailRoute = CalendarEventDetailRoute(
            occurrence: makeOccurrenceContext(
                event: event,
                actionDate: date,
                occurrenceID: nil,
                isAllDay: event.isAllDay,
                source: source
            ),
            initialJumpTarget: .meta
        )
    }

    func handleTimelineManipulationPromotion(_ event: Event, _ occurrenceID: String?, _ actionDate: Date, _ dragMode: EventDragMode, _ touchPointGlobal: CGPoint, _ eventFrameGlobal: CGRect) {
        resetFloatingMenuState()
        pendingInterruptComposer = nil
        if dragMode == .move {
            cancelResizeGrace(reason: "timeline.manipulationPromotion.move")
        }
        setFocus(
            event: event,
            occurrenceID: occurrenceID,
            reason: "timeline.manipulationPromotion.\(String(describing: dragMode))"
        )
    }

    func handleVisibleTimelineFrameChange(_ frame: CGRect) {
        guard frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return
        }
        guard timelineVisibleDayFrameGlobal != frame else { return }
        timelineVisibleDayFrameGlobal = frame
    }

    func handleTimelineLongPressBegan(_ began: CalendarEventLongPressBegan) {
        // Cancel any lingering resize grace so canMove is true for the new gesture.
        cancelResizeGrace(reason: "timeline.longPressBegan.newGesture")
        let occurrence = makeOccurrenceContext(
            event: began.event,
            actionDate: began.actionDate,
            occurrenceID: began.occurrenceID,
            isAllDay: false,
            source: .timelineLongPress
        )
        // Enter edit mode immediately at the manipulation threshold, then
        // show the express menu only after the longer hold completes.
        scheduleFloatingMenuActivation(anchor: began, occurrence: occurrence)
    }

    func handleTimelineLongPressResolved(_ resolution: CalendarEventLongPressResolution) {
        cancelPendingFloatingMenuActivation()
        if resolution.didMove {
            // Drag happened — menu already dismissed in manipulationPromotion
            hideFloatingMenu()
            if resolution.terminalState == .cancelled {
                clearFocus(reason: "timeline.manipulation.cancelled")
            }
            return
        }
        guard resolution.terminalState == .completed else {
            hideFloatingMenu()
            clearFocus(reason: "timeline.longPressResolved.cancelled")
            return
        }
        // Finger lifted without moving — activate resize grace and make menu interactive.
        if let occurrence = floatingMenuOccurrence {
            beginResizeGrace(for: occurrence, trigger: .longPressRelease)
        }
        floatingMenuInteractive = floatingMenuAnchor != nil
    }

    func handleTimelineEventDragEnded(_ event: Event, _ occurrenceID: String?, _ draggedRange: Event.TimeRange, _ offset: DragOffset, _ dayColumnStep: CGFloat) {
        handleEventDrag(
            event: event,
            occurrenceID: occurrenceID,
            draggedRange: draggedRange,
            offset: offset,
            dayColumnStep: dayColumnStep,
            rangeMode: calendarState.rangeMode
        )
    }

    func handleTimelineEventResizeEnded(_ event: Event, _ occurrenceID: String?, _ draggedRange: Event.TimeRange, _ actionDate: Date, _ dragMode: EventDragMode, _ yOffset: CGFloat) {
        handleEventResize(
            event: event,
            occurrenceID: occurrenceID,
            draggedRange: draggedRange,
            actionDate: actionDate,
            dragMode: dragMode,
            yOffset: yOffset
        )
    }

    func handleTimelineCreateEvent(_ date: Date, _ timeRange: Event.TimeRange) {
        handleCreateEvent(on: date, timeRange: timeRange)
    }

    func handleTimelineNonEventTap() {
        resetFloatingMenuState()
        pendingInterruptComposer = nil
        cancelResizeGrace(reason: "timeline.nonEventTap")
        clearFocus()
    }

    func handleTimelineHourHeightCommit() {
        calendarState.commitTimelineHourHeight()
    }

    func handleTimelineHorizontalScroll(_ progress: TimelineHorizontalScrollProgress) {
        if progress.isInteracting {
            resetFloatingMenuState()
            pendingInterruptComposer = nil
            cancelResizeGrace(reason: "timeline.horizontalScroll")
        }
        handleTimelineHorizontalScrollProgress(progress)
    }

    func scheduleFloatingMenuActivation(
        anchor: CalendarEventLongPressBegan,
        occurrence: CalendarEventOccurrenceContext
    ) {
        resetFloatingMenuState()
        floatingMenuOccurrence = occurrence

        guard floatingMenuActivationDelay > 0 else {
            floatingMenuAnchor = anchor
            return
        }

        let activationToken = UUID()
        floatingMenuActivationToken = activationToken
        floatingMenuActivationTask = Task { @MainActor in
            let delay = UInt64(floatingMenuActivationDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, floatingMenuActivationToken == activationToken else { return }
            floatingMenuActivationToken = nil
            floatingMenuActivationTask = nil
            floatingMenuAnchor = anchor
        }
    }

    func cancelPendingFloatingMenuActivation() {
        floatingMenuActivationTask?.cancel()
        floatingMenuActivationTask = nil
        floatingMenuActivationToken = nil
    }

    func hideFloatingMenu() {
        guard !showLongPressDeleteConfirm else {
            floatingMenuInteractive = false
            return
        }
        floatingMenuAnchor = nil
        floatingMenuInteractive = false
    }

    func resetFloatingMenuState() {
        cancelPendingFloatingMenuActivation()
        hideFloatingMenu()
    }

    func presentInterruptComposer(
        anchor: CalendarEventLongPressBegan,
        occurrence: CalendarEventOccurrenceContext
    ) {
        guard let parentRange = calendarOccurrenceDisplayRange(
            event: anchor.event,
            occurrenceDate: occurrence.occurrenceDate
        ) else {
            return
        }
        pendingInterruptComposer = PendingInterruptComposerPresentation(
            anchorPoint: anchor.touchPointGlobal,
            parentEvent: anchor.event,
            occurrence: occurrence,
            parentRange: parentRange,
            occupiedRanges: interruptEmbeddedChildRanges(
                parentEvent: anchor.event,
                occurrenceDate: occurrence.occurrenceDate
            )
        )
    }

    func handleInterruptCreated(
        parentEvent: Event,
        occurrence: CalendarEventOccurrenceContext,
        title: String,
        type: String,
        timeRange: Event.TimeRange
    ) {
        pendingInterruptComposer = nil
        guard let created = createInterruptEvent(
            parentEvent: parentEvent,
            occurrence: occurrence,
            title: title,
            type: type,
            timeRange: timeRange
        ) else { return }
        handleCreatedEvent(created)
    }

    func startLiveInterrupt(
        parentEvent: Event,
        occurrence: CalendarEventOccurrenceContext,
        title: String,
        type: String
    ) {
        pendingInterruptComposer = nil
        liveInterruptSession = CalendarInterruptLiveSession(
            parentOccurrence: occurrence,
            parentEventID: parentEvent.id,
            parentEventSnapshot: parentEvent,
            title: title,
            typeTitle: type,
            startedAt: Date()
        )
    }

    func stopLiveInterrupt() {
        guard let session = liveInterruptSession else {
            liveInterruptSession = nil
            return
        }
        let parentEvent = store.findCalendarEvent(id: session.parentEventID) ?? session.parentEventSnapshot
        let range = Event.TimeRange(start: session.startedAt, end: Date())
        liveInterruptSession = nil
        guard let created = createInterruptEvent(
            parentEvent: parentEvent,
            occurrence: session.parentOccurrence,
            title: session.title,
            type: session.typeTitle,
            timeRange: range
        ) else { return }
        handleCreatedEvent(created)
    }

    func cancelLiveInterrupt() {
        liveInterruptSession = nil
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

    func presentDatePicker(for date: Date) {
        datePickerSelection = date
        datePickerDetent = .medium
        isShowingDatePicker = true
    }

    func jumpToNowFromHeader(metrics: CalendarPageMetrics, isCapsulesVisible: Bool) {
        clearFocus(reason: "header.longPress.now")
        clearTimelineBoundaryExtensionState()
        let todayOffset = 0
        expandDayRangeToInclude(todayOffset)

        if accessibilityReduceMotion {
            calendarState.selectedDayOffset = todayOffset
            legendCenteredOffsetContinuous = CGFloat(todayOffset)
            if calendarState.rangeMode != .month {
                let topOverlayInset = calendarTopOverlayInset(
                    safeAreaTop: metrics.safeAreaTop,
                    isCapsuleVisible: isCapsulesVisible,
                    legendBandHeight: calendarTopOverlayLegendBandHeight(for: calendarState.rangeMode),
                    overlayGap: topOverlayGap,
                    capsuleExpandedHeight: topOverlayCapsuleExpandedHeight
                )
                verticalScrollPosition.scrollTo(point: CGPoint(
                    x: 0,
                    y: currentTimeScrollOffset(topOverlayInset: topOverlayInset, hourHeight: calendarState.timelineHourHeight)
                ))
            }
            return
        }

        // Diagonal movement: horizontal (day offset) and vertical
        // (time scroll) animate together in one animation block.
        let animation: Animation = .spring(duration: 0.5, bounce: 0.06)
        if calendarState.rangeMode == .month {
            withAnimation(animation) {
                calendarState.selectedDayOffset = todayOffset
            }
        } else {
            let topOverlayInset = calendarTopOverlayInset(
                safeAreaTop: metrics.safeAreaTop,
                isCapsuleVisible: isCapsulesVisible,
                legendBandHeight: calendarTopOverlayLegendBandHeight(for: calendarState.rangeMode),
                overlayGap: topOverlayGap,
                capsuleExpandedHeight: topOverlayCapsuleExpandedHeight
            )
            let targetY = currentTimeScrollOffset(
                topOverlayInset: topOverlayInset,
                hourHeight: calendarState.timelineHourHeight
            )
            withAnimation(animation) {
                calendarState.selectedDayOffset = todayOffset
                verticalScrollPosition.scrollTo(point: CGPoint(x: 0, y: targetY))
            }
        }
    }

    func applyDatePickerSelection(_ selectedDate: Date) {
        let offset = dayOffset(for: selectedDate)
        if calendarState.rangeMode == .month {
            expandDayRangeForMonthContext(around: offset)
        } else {
            expandDayRangeToInclude(offset)
        }
        calendarState.selectedDayOffset = offset
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

    /// Detects a wall-clock day-crossing and either applies the resulting
    /// offset shift immediately or defers it until active gestures clear.
    /// Safe to call repeatedly; a no-op when nothing has changed.
    private func handleClockMaybeChanged(reason: String) {
        let now = Date()
        let days = CalendarMidnightHandler.daysCrossed(
            from: midnightLastKnownStartOfDay,
            to: now
        )
        guard days != 0 else { return }
        midnightLastKnownStartOfDay = Calendar.current.startOfDay(for: now)
        midnightPendingDaysCrossed += days
        calendarDebugLog(
            "calendar.midnight.detected",
            fields: [
                "daysCrossed": "\(days)",
                "pending": "\(midnightPendingDaysCrossed)",
                "reason": reason
            ]
        )
        tryApplyPendingMidnightShift(reason: reason)
    }

    /// Applies a deferred midnight offset shift if no active gesture would
    /// be desynchronised by it.  Drag, resize-grace, and the live interrupt
    /// session all capture frame-of-reference state at gesture begin; shifting
    /// the offset mid-gesture would land drops one day off.
    private func tryApplyPendingMidnightShift(reason: String) {
        guard midnightPendingDaysCrossed != 0 else { return }
        guard timelineDragState.draggingEventID == nil,
              resizeGraceState == nil,
              liveInterruptSession == nil else {
            calendarDebugLog(
                "calendar.midnight.shift.deferred",
                fields: [
                    "pending": "\(midnightPendingDaysCrossed)",
                    "reason": reason,
                    "draggingEventID": timelineDragState.draggingEventID?.uuidString ?? "nil",
                    "resizeGraceActive": "\(resizeGraceState != nil)",
                    "liveInterruptActive": "\(liveInterruptSession != nil)"
                ]
            )
            return
        }
        let n = midnightPendingDaysCrossed
        midnightPendingDaysCrossed = 0
        calendarState.selectedDayOffset -= n
        legendCenteredOffsetContinuous = CGFloat(calendarState.selectedDayOffset)
        rebuildOccurrencesCache()
        calendarDebugLog(
            "calendar.midnight.shift.applied",
            fields: [
                "daysCrossed": "\(n)",
                "newSelectedDayOffset": "\(calendarState.selectedDayOffset)",
                "reason": reason
            ]
        )
    }

    func rebuildOccurrencesCache() {
        let allEvents = store.calendarEvents
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let center = calendarState.selectedDayOffset

        // Phase 1 — synchronously compute the visible window so the UI
        // has data for the columns that are on screen right now.
        let urgentRange = max(dayRange.lowerBound, center - 7)...min(dayRange.upperBound, center + 7)
        var newCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
        var newAllDay: [Int: [CalendarLayout.EventOccurrence]] = [:]
        for offset in urgentRange {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            newCache[offset] = CalendarLayout.occurrencesForDate(allEvents, date: day, calendar: calendar)
            newAllDay[offset] = CalendarLayout.allDayOccurrencesForDate(allEvents, date: day, calendar: calendar)
        }
        occurrencesCache = newCache
        allDayOccurrencesCache = newAllDay
        recomputeMaxAllDayCountCache()

        // Phase 2 — progressively fill the rest of dayRange outward from
        // center so each batch yields back to the run-loop.
        let remaining = dayRange.filter { !urgentRange.contains($0) }
        scheduleProgressiveCacheLoad(offsets: remaining, center: center)
    }

    /// Recompute the cached max all-day count.  Called whenever
    /// `allDayOccurrencesCache` is mutated.  This avoids per-frame iteration
    /// of the entire dayRange in TimelinePagerView's body.
    private func recomputeMaxAllDayCountCache() {
        let maxCount = calendarMaxAllDayCount(in: allDayOccurrencesCache)
        if maxAllDayCountCache != maxCount {
            maxAllDayCountCache = maxCount
        }
    }

    /// Incremental cache rebuild: only compute occurrences for offsets that
    /// were added when dayRange expanded, instead of rebuilding everything.
    ///
    /// IMPORTANT: This is only safe because dayRange is monotonically
    /// expanding — `calendarExpandedDayRange`, `expandDayRangeForMonthContext`,
    /// and `expandDayRangeToInclude` all only widen the range, never shrink
    /// it.  Because of this invariant, the previously-cached max stays valid;
    /// we only need to recompute when a NEW day's all-day count exceeds the
    /// current max.  If dayRange ever starts shrinking, this incremental
    /// update strategy must be revisited.
    private func rebuildOccurrencesCacheIncremental(
        oldRange: ClosedRange<Int>,
        newRange: ClosedRange<Int>
    ) {
        let allEvents = store.calendarEvents
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let center = calendarState.selectedDayOffset

        // Synchronously compute only the days near the current selection
        // so the visible columns are ready immediately.
        let urgentRange = (center - 7)...(center + 7)
        var didUpdateAllDayCache = false
        for offset in newRange {
            guard !oldRange.contains(offset) else { continue }
            guard urgentRange.contains(offset) else { continue }
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            occurrencesCache[offset] = CalendarLayout.occurrencesForDate(allEvents, date: day, calendar: calendar)
            let allDay = CalendarLayout.allDayOccurrencesForDate(allEvents, date: day, calendar: calendar)
            allDayOccurrencesCache[offset] = allDay
            if allDay.count > maxAllDayCountCache {
                didUpdateAllDayCache = true
            }
        }
        if didUpdateAllDayCache {
            recomputeMaxAllDayCountCache()
        }

        // Progressively fill the remaining expanded days.
        let remaining = newRange.filter { !oldRange.contains($0) && !urgentRange.contains($0) }
        if !remaining.isEmpty {
            scheduleProgressiveCacheLoad(offsets: Array(remaining), center: center)
        }
    }

    func updateTimerRefresh() {
        if store.activeTimerCalendarEvent != nil {
            // Only start if not already running
            guard timerRefreshCancellable == nil else { return }
            // Tick every 30s rather than every 1s.  Each tick rebuilds
            // occurrencesCache, which invalidates the entire CalendarPageView
            // body — that propagates through TimelinePagerView, the header,
            // and every consumer of the cache closure.  At 1Hz this monopolised
            // the main thread enough to cost scroll smoothness whenever a
            // timer was running, and 24/7 idle CPU besides.  Timer events
            // are an infrequently-used feature, so 30s discrete growth is an
            // acceptable trade for ~30× less idle work; the minimum-visible
            // range in `CalendarLayout.occurrencesForDate` keeps the block
            // visible from the moment the timer starts.  Pair this constant
            // with `calendarTimerMinimumVisibleDuration` over there.
            timerRefreshCancellable = Timer.publish(every: 30.0, on: .main, in: .common)
                .autoconnect()
                .sink { [self] _ in
                    rebuildOccurrencesCacheForTimerEvent()
                }
        } else {
            timerRefreshCancellable?.cancel()
            timerRefreshCancellable = nil
        }
    }

    /// Rebuild cache only for the day(s) that contain the active timer event,
    /// instead of ±2 days around the selection.  When a timer spans midnight
    /// (started yesterday, still running today), both days are refreshed so
    /// the growing timer block updates on the current day too.
    private func rebuildOccurrencesCacheForTimerEvent() {
        guard let timerEvent = store.activeTimerCalendarEvent,
              let timerStart = timerEvent.timerStartedAt else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let timerDay = calendar.startOfDay(for: timerStart)
        let timerOffset = calendar.dateComponents([.day], from: today, to: timerDay).day ?? 0
        let allEvents = store.calendarEvents
        let day = calendar.date(byAdding: .day, value: timerOffset, to: today)!
        occurrencesCache[timerOffset] = CalendarLayout.occurrencesForDate(allEvents, date: day, calendar: calendar)
        // Timer range is timerStart → now.  If the timer started on a
        // different day, today's cache also needs refreshing.
        if timerOffset != 0 {
            occurrencesCache[0] = CalendarLayout.occurrencesForDate(allEvents, date: today, calendar: calendar)
        }
    }

    private func rebuildOccurrencesCacheForVisibleDays() {
        let current = calendarState.selectedDayOffset
        let visibleRange = (current - 2)...(current + 2)
        var didAdd = false
        for offset in visibleRange {
            guard occurrencesCache[offset] == nil else { continue }
            let allEvents = store.calendarEvents
            let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
            withAnimation(.easeIn(duration: 0.25)) {
                occurrencesCache[offset] = CalendarLayout.occurrencesForDate(allEvents, date: day)
                allDayOccurrencesCache[offset] = CalendarLayout.allDayOccurrencesForDate(allEvents, date: day)
            }
            didAdd = true
        }
        if didAdd {
            recomputeMaxAllDayCountCache()
        }
    }

    func expandDayRangeIfNeeded(for offset: Int) {
        let expandedRange = calendarExpandedDayRange(
            currentRange: dayRange,
            selectedDayOffset: offset,
            expansionStep: dayRangeExpansionStep,
            expansionThreshold: dayRangeExpansionThreshold,
            inclusionBuffer: dayRangeExpansionBuffer
        )
        if expandedRange != dayRange {
            dayRange = expandedRange
        }
    }

    /// Progressively loads occurrences for the given offsets, sorted by
    /// distance from `center` so the nearest days fill first.  Each batch
    /// yields back to the main run-loop so scrolling stays fluid.
    private func scheduleProgressiveCacheLoad(offsets: [Int], center: Int) {
        progressiveCacheTask?.cancel()
        let sorted = offsets.sorted { abs($0 - center) < abs($1 - center) }
        progressiveCacheTask = Task { @MainActor in
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let allEvents = store.calendarEvents
            let batchSize = 5
            var didUpdateAllDayCache = false
            for batch in stride(from: 0, to: sorted.count, by: batchSize) {
                guard !Task.isCancelled else { return }
                let end = min(batch + batchSize, sorted.count)
                withAnimation(.easeIn(duration: 0.25)) {
                    for offset in sorted[batch..<end] {
                        guard occurrencesCache[offset] == nil else { continue }
                        let day = calendar.date(byAdding: .day, value: offset, to: today)!
                        occurrencesCache[offset] = CalendarLayout.occurrencesForDate(allEvents, date: day, calendar: calendar)
                        let allDay = CalendarLayout.allDayOccurrencesForDate(allEvents, date: day, calendar: calendar)
                        allDayOccurrencesCache[offset] = allDay
                        if allDay.count > maxAllDayCountCache {
                            didUpdateAllDayCache = true
                        }
                    }
                }
                // Yield after each batch so the run-loop can service scroll
                // events and render frames between batches.
                await Task.yield()
            }
            if didUpdateAllDayCache {
                recomputeMaxAllDayCountCache()
            }
        }
    }

    func expandDayRangeForMonthContext(around offset: Int) {
        let calendar = Calendar.current
        let anchorDate = calendarDateForSelectedDayOffset(offset, calendar: calendar)
        let anchorMonthStart = calendarMonthStartDate(containing: anchorDate, calendar: calendar)

        var newLower = dayRange.lowerBound
        var newUpper = dayRange.upperBound

        for delta in -1...1 {
            let monthDate = calendar.date(byAdding: .month, value: delta, to: anchorMonthStart) ?? anchorMonthStart
            let gridDates = calendarMonthGridDates(forMonthContaining: monthDate, calendar: calendar)
            guard let first = gridDates.first, let last = gridDates.last else { continue }
            let firstOffset = dayOffset(for: first)
            let lastOffset = dayOffset(for: last)
            if firstOffset < newLower {
                newLower = firstOffset - dayRangeExpansionBuffer
            }
            if lastOffset > newUpper {
                newUpper = lastOffset + dayRangeExpansionBuffer
            }
        }

        if newLower != dayRange.lowerBound || newUpper != dayRange.upperBound {
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

    func handleMonthPageChange(_ deltaMonths: Int) {
        guard deltaMonths != 0 else { return }
        let shiftedOffset = calendarShiftSelectedDayOffsetByMonth(
            selectedDayOffset: calendarState.selectedDayOffset,
            deltaMonths: deltaMonths
        )
        expandDayRangeForMonthContext(around: shiftedOffset)
        calendarState.selectedDayOffset = shiftedOffset
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
        calendarDebugLog(
            "calendar.handleEventDrag.begin",
            fields: [
                "eventID": event.id.uuidString,
                "selectedDayOffset": "\(calendarState.selectedDayOffset)",
                "rangeMode": String(describing: rangeMode),
                "occurrenceID": occurrenceID ?? "nil",
                "draggedStart": calendarDebugInstantString(draggedRange.start),
                "draggedEnd": calendarDebugInstantString(draggedRange.end),
                "offsetX": String(format: "%.2f", offset.x),
                "offsetY": String(format: "%.2f", offset.y),
                "dayColumnStep": String(format: "%.2f", dayColumnStep),
                "focusedEventID": focusedEventID?.uuidString ?? "nil",
                "focusedOccurrenceID": focusedOccurrenceID ?? "nil"
            ]
        )

        guard rangeMode != .month else { return }
        let dayOffsetFromDrag = dayColumnStep > 0
            ? Int((offset.x / dayColumnStep).rounded())
            : 0

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
            let movedException = findRecurringException(for: event, draggedRange: draggedRange, newRange: newRange)
            if let movedException {
                let resolvedRange = movedException.effectiveTimeRanges.first(where: {
                    calendarRangesApproximatelyEqual(lhs: $0, rhs: newRange)
                }) ?? movedException.effectiveTimeRanges.first ?? newRange
                restartResizeGrace(
                    for: committedOccurrenceContext(
                        event: movedException,
                        preferredRange: resolvedRange,
                        occurrenceDate: resolvedRange.start
                    ),
                    trigger: .moveCommit
                )
            } else {
                restartResizeGrace(
                    for: committedOccurrenceContext(
                        event: event,
                        preferredRange: newRange,
                        occurrenceDate: draggedRange.start
                    ),
                    trigger: .moveCommit
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
        calendarDebugLog(
            "calendar.handleEventDrag.commit",
            fields: [
                "eventID": event.id.uuidString,
                "updatedFirstStart": updated.primaryTimeRange.map { calendarDebugInstantString($0.start) } ?? "nil",
                "updatedFirstEnd": updated.primaryTimeRange.map { calendarDebugInstantString($0.end) } ?? "nil",
                "timeRangesCount": "\(updated.timeRanges.count)"
            ]
        )
        store.updateCalendarEvent(updated)
        restartResizeGrace(
            for: committedOccurrenceContext(
                event: updated,
                preferredRange: newRange,
                occurrenceDate: newRange.start
            ),
            trigger: .moveCommit
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
        let newRange = calendarResizedRangeFromDrag(
            draggedRange: draggedRange,
            dragMode: dragMode,
            offsetY: yOffset,
            hourHeight: hourHeight
        )
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
            }
            let movedException = findRecurringException(for: event, draggedRange: draggedRange, newRange: newRange)
            let resolvedEvent = movedException ?? event
            let resolvedRange = resolvedEvent.effectiveTimeRanges.first(where: {
                calendarRangesApproximatelyEqual(lhs: $0, rhs: newRange)
            }) ?? resolvedEvent.effectiveTimeRanges.first ?? newRange
            restartResizeGrace(
                for: committedOccurrenceContext(
                    event: resolvedEvent,
                    preferredRange: resolvedRange,
                    occurrenceDate: actionDate
                ),
                trigger: .resizeCommit
            )
            calendarDebugLog(
                "calendar.handleEventResize.commitRecurring",
                fields: [
                    "eventID": event.id.uuidString,
                    "resolvedEventID": resolvedEvent.id.uuidString
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
        store.updateCalendarEvent(updated)
        restartResizeGrace(
            for: committedOccurrenceContext(
                event: updated,
                preferredRange: newRange,
                occurrenceDate: actionDate
            ),
            trigger: .resizeCommit
        )
        calendarDebugLog(
            "calendar.handleEventResize.commit",
            fields: [
                "eventID": event.id.uuidString,
                "occurrenceID": occurrenceID ?? "nil",
                "timeRangesCount": "\(updated.timeRanges.count)"
            ]
        )
    }

    func handleCreateEvent(on date: Date, timeRange: Event.TimeRange) {
        // Open create sheet - event will only be added when user saves
        // Preview will stay visible until sheet is dismissed
        let anchorVisibleDate = visibleDate
        pendingCreateTimeRange = PendingEventCreation(
            date: date,
            timeRange: timeRange,
            source: .dragCreate,
            anchorVisibleDate: anchorVisibleDate,
            completionNavigation: calendarPendingEventCreationCompletionNavigation(
                source: .dragCreate,
                anchorVisibleDate: anchorVisibleDate,
                timeRange: timeRange
            )
        )
    }

    func interruptEmbeddedChildRanges(
        parentEvent: Event,
        occurrenceDate: Date
    ) -> [Event.TimeRange] {
        let occurrenceKey = CalendarOccurrenceKey.make(
            for: parentEvent,
            occurrenceDate: occurrenceDate
        )
        let calendar = Calendar.current
        return store.calendarEvents.compactMap { candidate in
            guard let relation = candidate.interruptRelation,
                  relation.state == .embedded,
                  relation.parentEventID == occurrenceKey.eventID,
                  calendar.isDate(relation.occurrenceDate, inSameDayAs: occurrenceKey.occurrenceDate),
                  let range = candidate.primaryTimeRange else {
                return nil
            }
            return range
        }
    }

    func createInterruptEvent(
        parentEvent: Event,
        occurrence: CalendarEventOccurrenceContext,
        title: String,
        type: String,
        timeRange: Event.TimeRange
    ) -> Event? {
        guard let created = store.createInterrupt(
            parentEvent: parentEvent,
            occurrenceDate: occurrence.occurrenceDate,
            title: title,
            type: type,
            timeRange: timeRange
        ) else {
            return nil
        }
        inferInterruptTypeIfNeeded(event: created, typedType: type, timeRange: timeRange)
        return created
    }

    func handleCreatedEvent(_ event: Event, pendingCreate: PendingEventCreation? = nil) {
        guard let preferredRange = event.effectiveTimeRanges.first else { return }
        cancelResizeGrace(reason: "calendar.create.completed")
        let offset = dayOffset(for: preferredRange.start)
        expandDayRangeToInclude(offset)

        switch pendingCreate?.completionNavigation ?? .focusCreatedEvent {
        case .focusCreatedEvent:
            calendarState.selectedDayOffset = offset
            let occurrenceID = calendarResolvedFocusedOccurrenceID(
                event: event,
                preferredRange: preferredRange
            )
            let context = CalendarEventOccurrenceContext(
                eventID: event.id,
                occurrenceDate: preferredRange.start,
                occurrenceID: occurrenceID,
                isAllDay: event.isAllDay,
                source: .timelineLongPress
            )
            restartResizeGrace(for: context, trigger: .createCommit)
        case .stayOnAnchorVisibleDate:
            break
        }
    }

    func inferInterruptTypeIfNeeded(event: Event, typedType: String, timeRange: Event.TimeRange) {
        let form = CalendarEventFormData(
            title: event.title,
            typeTitle: event.type,
            note: event.note,
            location: event.location,
            startTime: timeRange.start,
            endTime: timeRange.end,
            isAllDay: false,
            repeatUnit: .none,
            repeatInterval: 1,
            repeatEndType: .none,
            repeatEndDate: nil,
            repeatEndCount: nil,
            didExplicitlySelectType: false
        )
        Task { @MainActor in
            await typeInferenceService.inferTypeIfNeeded(
                for: event,
                savedForm: form,
                isSuggestionEnabled: calendarAgenticCreateEnabled,
                store: store
            )
        }
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

private struct DateSelectorSheet: View {
    @Binding var selection: Date
    @Binding var detent: PresentationDetent
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let allDayOccurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    var onConfirm: (Date) -> Void
    var onDismiss: () -> Void

    private let monthHeaderHeight: CGFloat = 132

    private var yearTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: selection)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter.string(from: selection)
    }

    private var selectedDayOffset: Int {
        let today = Calendar.current.startOfDay(for: Date())
        let target = Calendar.current.startOfDay(for: selection)
        return Calendar.current.dateComponents([.day], from: today, to: target).day ?? 0
    }

    var body: some View {
        Group {
            if detent == .large {
                largeDetentContent
            } else {
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
        .animation(.easeInOut(duration: 0.18), value: detent == .large)
    }

    private var largeDetentContent: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                MonthOverviewPagerView(
                    selectedDayOffset: selectedDayOffset,
                    occurrencesForOffset: occurrencesForOffset,
                    allDayOccurrencesForOffset: allDayOccurrencesForOffset,
                    topContentInset: monthHeaderHeight,
                    onSelectDay: { dayOffset in
                        selection = calendarDateForSelectedDayOffset(dayOffset)
                        onConfirm(selection)
                    },
                    onMonthPageChanged: { deltaMonths in
                        let shiftedOffset = calendarShiftSelectedDayOffsetByMonth(
                            selectedDayOffset: selectedDayOffset,
                            deltaMonths: deltaMonths
                        )
                        selection = calendarDateForSelectedDayOffset(shiftedOffset)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 0) {
                    Button(action: onDismiss) {
                        HStack(spacing: 6) {
                            Text(yearTitle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .contentShape(Capsule())
                        .background(Color.black.opacity(0.001), in: Capsule())
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)

                    Text(monthTitle)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 12)

                    HStack(spacing: 0) {
                        ForEach(Array(calendarMonthWeekdaySymbols(calendar: .current).enumerated()), id: \.offset) { entry in
                            Text(entry.element.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .frame(width: proxy.size.width, height: monthHeaderHeight, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

// Performance diagnostics available in git history: cd9d9e3
