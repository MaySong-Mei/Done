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
        completionNavigation: PendingEventCreationCompletionNavigation = .focusCreatedEvent,
        resumesComposerDraft: Bool = false
    ) {
        self.date = date
        self.timeRange = timeRange
        self.source = source
        self.anchorVisibleDate = anchorVisibleDate
        self.completionNavigation = completionNavigation
        self.resumesComposerDraft = resumesComposerDraft
    }

    /// True only for the draft-banner entry: the one composer session that
    /// explicitly resumes the kill-rescue draft. Plain drag-create/quick-add
    /// sessions never auto-fill from it — a stale draft's folded-away fields
    /// (note, people, repeat) silently riding into an unrelated new event is
    /// worse than making the user tap the banner.
    let resumesComposerDraft: Bool
}

/// Prefilled values for turning a `Reminder` into a calendar event. Carries the
/// (optionally AI-generated) fields into the `CreateCalendarEventView` sheet.
struct ReminderSchedulePrefill: Identifiable {
    let id = UUID()
    let timeRange: Event.TimeRange
    let title: String
    let typeTitle: String
    let note: String
    let location: String
    let agenticIntake: AgenticIntakeRecord?
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
    let resolved = calendarResolvedDragEditRange(
        draggingOriginalRange: draggedRange,
        dragOffset: DragOffset(x: 0, y: offsetY),
        dragMode: dragMode,
        hourHeight: hourHeight,
        calendar: calendar
    ) ?? draggedRange

    // `calendarResolvedDragEditRange` allows zero / sub-minimum durations
    // mid-drag (so the crossing point is freely passable for the live flip).
    // The 15-min floor is enforced ONLY here at commit: if the committed span
    // is too short, expand it away from the ANCHOR edge (the non-dragged edge),
    // so the edge the finger released on settles to the minimum span.
    let minDuration: TimeInterval = 15 * 60
    guard resolved.end.timeIntervalSince(resolved.start) < minDuration else { return resolved }
    // After a flip the dragged edge may be either side, so derive the anchor
    // from the original (pre-drag) range: resizeBottom anchors on start,
    // resizeTop anchors on end.
    switch dragMode {
    case .resizeBottom:
        // Anchor is the start edge (never moves in resizeBottom). If the dragged
        // end flipped ABOVE the anchor, the floored block sits above it; else below.
        let anchor = draggedRange.start
        return resolved.start < anchor
            ? Event.TimeRange(start: anchor.addingTimeInterval(-minDuration), end: anchor)
            : Event.TimeRange(start: anchor, end: anchor.addingTimeInterval(minDuration))
    case .resizeTop:
        // Anchor is the end edge (never moves in resizeTop). If the dragged start
        // flipped BELOW the anchor, the floored block sits below it; else above.
        let anchor = draggedRange.end
        return resolved.end > anchor
            ? Event.TimeRange(start: anchor, end: anchor.addingTimeInterval(minDuration))
            : Event.TimeRange(start: anchor.addingTimeInterval(-minDuration), end: anchor)
    case .move:
        return resolved
    }
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
    clampToExtension: Bool = true,
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
    // Spec 07 Phase 1: when imperative path requests no-clamp, finger Y is
    // taken raw — the finger may sit physically above the timeline frame or
    // far below the ±12h substrate, and the day-switch needs that true day.
    let mappingY = clampToExtension ? min(max(headerHeight, localY), maxLocalY) : localY
    let resolvedDate = calendarTimelineDateFromYPosition(
        mappingY,
        containing: selectedDate,
        headerHeight: headerHeight,
        hourHeight: hourHeight,
        leadingExtendedHours: boundaryExtensionState.leadingHours,
        trailingExtendedHours: boundaryExtensionState.trailingHours,
        snapMinutes: 1,
        clampToExtension: clampToExtension,
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
    let leadingHoursChanged = newState.leadingHours != previousState.leadingHours

    // Symmetric scroll compensation: previously gated on `leadingHoursIncreased`
    // only (open extension during drag → compensate). The CLOSE direction
    // (extension N → 0, dragEnd dismiss path) was left uncompensated, so the
    // now-time indicator visibly slid 12h*hourHeight as `leading` animated to
    // zero — the user-observed "now-time refresh" after the bounce was
    // unhooked. Apply the same column-local-time-preserving adjustment in
    // both directions; the underlying math
    // (`calendarAdjustedVerticalScrollOffsetForLeadingTimelineExtension`) is
    // already symmetric (`currentOffsetY + delta*hourHeight`). (#53 single-day)
    guard leadingHoursChanged else { return nil }

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
        // Latch each side once triggered and keep it for the rest of the drag
        // (per-side, OR of current + raw). We do NOT drop a side mid-drag even
        // when the other gets triggered: collapsing a side mid-drag would shift
        // scroll and detach the dragged event from the finger. The abandoned
        // side is instead faded to transparent (per-side fade) and only
        // collapses on release. (#55)
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

/// Height of the app's key window — the same basis the put-back peek's
/// GeometryReader uses (`.global` maxY resolves to the window, not the
/// physical screen). The put-back commit zone and absorb-cession check
/// MUST measure from this, not `UIScreen.main.bounds.height`: on an iPad
/// in Split View / Slide Over the window is shorter than the screen, so
/// a screen-based zone would sit below the highlight the user sees and
/// break the "highlighted zone == commit zone" WYSIWYG contract.
func calendarKeyWindowHeight() -> CGFloat {
    let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = windowScenes.flatMap(\.windows)
    let keyWindow = windows.first(where: \.isKeyWindow) ?? windows.first
    return keyWindow?.bounds.height ?? UIScreen.main.bounds.height
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
    @EnvironmentObject private var calendarFocusState: CalendarFocusState
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
    /// #55: visual y-offset applied to TimelineView content during the
    /// boundary-extension OPEN animation. Cancels the layout jump caused
    /// by `leading` snapping to 12 in logical state while scroll catches
    /// up over 0.28s. Computed each animator tick as `scrollY - targetY`
    /// (negative during animation, 0 at end), so events stay glued to the
    /// finger position visually:
    ///   event_viewport_y = layout_y + dragOffset.y + visualOffset - scrollY
    ///                    = layout_y + dragOffset.y + (scrollY - targetY) - scrollY
    ///                    = layout_y + dragOffset.y - targetY
    /// which equals the pre-open position + finger delta.
    @State private var boundaryExtensionVisualYOffset: CGFloat = 0
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
    /// Cold-start rescue entry for a composer session that died with the
    /// process (see CalendarComposerDraft). Refreshed on appear and after the
    /// create sheet dismisses — a user who believes the event "was created"
    /// won't reopen the composer on their own, so the draft must surface here.
    @State private var composerDraftBanner: CalendarComposerDraft? = nil
    @Environment(\.scenePhase) private var scenePhase
    // Reminder pull-down panel state.
    @State private var isReminderPanelOpen: Bool = false
    @State private var schedulingReminderID: UUID? = nil
    @State private var pendingReminderSchedule: ReminderSchedulePrefill? = nil
    @State private var pendingInterruptComposer: PendingInterruptComposerPresentation? = nil
    @State private var liveInterruptSession: CalendarInterruptLiveSession? = nil
    @State private var isShowingDatePicker: Bool = false
    @State private var datePickerSelection: Date = Date()
    @State private var datePickerDetent: PresentationDetent = .medium
    @State private var timerRefreshCancellable: AnyCancellable?
    @State private var focusedEventID: UUID? = nil
    @State private var focusedOccurrenceID: String? = nil
    /// Spec 07 §4a / §5 row S4 — `docs/calayer-rewrite/07-day-layer-imperative.md`.
    /// Optional handle to the imperative day-layer coordinator. S4 declares this
    /// slot so the channel migration `.onChange` handlers can route writes
    /// through it; the actual instantiation lands in S5. While nil (S4), every
    /// `dayLayerCoordinator?.setX(...)` call below is a no-op, leaving the
    /// SwiftUI struct field path into `CalendarDayLayerView(...)` as the sole
    /// channel — flag-OFF and flag-ON are byte-identical to king.
    @State private var dayLayerCoordinator: DayLayerCoordinator? = nil
    /// Spec 07 §5 S5.6 — output delegate adapter for the imperative day-layer
    /// coordinator. Reference-typed so the coordinator can hold it weakly
    /// (its delegate slot is `AnyObject`); SwiftUI `View` structs can't be
    /// the delegate directly. Closures are wired during `body` setup +
    /// pager-level `.onAppear` so every host-emitted gesture/output fires
    /// the same handler the SwiftUI representable path used to fire. Always
    /// allocated — flag-OFF leaves it inert (coordinator never installs it).
    @State private var dayLayerDelegateAdapter = DayLayerCoordinatorDelegateAdapter()
    @State private var resizeGraceState: CalendarResizeGraceState? = nil
    @State private var resizeGraceOccurrenceContext: CalendarEventOccurrenceContext? = nil
    @State private var resizeGraceFadeTask: Task<Void, Never>? = nil
    @State private var resizeGraceExpiryTask: Task<Void, Never>? = nil
    @State private var isShowingAgent: Bool = false
    @State private var isShowingSearch: Bool = false
    @State private var isShowingTodoStack: Bool = false
    /// Held for a beat after a put-back drop so the peek can show the
    /// landed card before retracting (see TodoPutBackPeek.flashTodo).
    @State private var todoPutBackFlash: Event?
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
    /// UIScrollView-backed scroll proxy (issue #57). Always allocated;
    /// only routed-to when `useUIScrollViewTimeline` flag is ON.
    @StateObject private var timelineScrollProxy = TimelineScrollProxy()
    /// Spec-07 was rolled back (#119, archive/imperative-day-layer-refactor,
    /// Discussion #103): hard-coded false so stale persisted flags can never
    /// re-activate the half-removed render path. Gated code kept for now.
    private let useUIScrollViewTimeline = false
    private let useImperativeDayLayer = false

    /// True when the single-day 48h-constant coordinate model is active. The
    /// day-layer renders a constant 12h + 24h + 12h window; band visibility is
    /// the host `contentInset`, never `contentSize`. Requires the UIScrollView
    /// host. Single source of truth for the pin / contentH / inset forks.
    private var usesImperativeDayLayerModel: Bool {
        useUIScrollViewTimeline && useImperativeDayLayer && calendarState.rangeMode == .day
    }

    /// All-day band height used by the imperative pin path. Derived from the
    /// SAME `maxAllDayCountCache` the pager is fed (`maxAllDayCountOverride`),
    /// so it equals `TimelinePagerView.allDayHeight` by construction — the pin
    /// predicate, the inset reservation, and the pager's in-scroll suppression
    /// all agree even if `allDayOccurrencesCache` holds stale out-of-range
    /// entries (where the dayRange-scoped `timelineAllDayHeight` could differ).
    private var pinnedAllDayHeight: CGFloat {
        guard maxAllDayCountCache > 0 else { return 0 }
        return CGFloat(maxAllDayCountCache) * timelineAllDayPillHeight
            + timelineAllDaySectionPadding * 2
    }

    /// True when the all-day pill row is pinned to the scroll frame top (so the
    /// negative leading `contentInset` can hide the band without scrolling the
    /// pills off). Only when there are all-day events to pin. Keyed off the
    /// same source as the pager's `pinsAllDayExternally`.
    private var pinsAllDayRow: Bool {
        usesImperativeDayLayerModel && pinnedAllDayHeight > 0
    }

    /// Unified scroll-to entrypoint that forks on the issue-#57 flag.
    /// Every existing `verticalScrollPosition.scrollTo(point: CGPoint(...))`
    /// callsite routes through here so the flag-ON path also moves when
    /// snap-to-now / pinch focal / follow-event swap / boundary-page
    /// compensations fire. The proxy's `scrollTo(y:animated:)` already
    /// wraps non-animated writes in a `CATransaction { setDisableActions
    /// (true) }`, so outer SwiftUI `Transaction.disablesAnimations` contexts
    /// remain meaningful on the flag-OFF path (they no-op on UIKit).
    fileprivate func scrollVerticallyTo(y: CGFloat, animated: Bool = false) {
        if useUIScrollViewTimeline {
            // SwiftUI's `withAnimation { … verticalScrollPosition.scrollTo }`
            // would otherwise hard-snap on flag-ON because `UIScrollView`
            // doesn't observe SwiftUI `Transaction`s — callers that want
            // a spring/scroll animation must opt in explicitly via
            // `animated: true` (deep-review C1). Used by jumpToNowFromHeader
            // + month range-mode day jump; everything else snaps.
            timelineScrollProxy.scrollTo(y: y, animated: animated)
        } else {
            verticalScrollPosition.scrollTo(point: CGPoint(x: 0, y: y))
        }
    }

    /// Close-path co-commit (issue #57). Drives the boundary-extension
    /// state to `.none` and the matching scroll compensation in ONE
    /// `CATransaction`, so the user never sees a frame where contentSize
    /// has shrunk but contentOffset hasn't compensated. Replaces the
    /// `timelineCollapseDim` opacity-dip workaround on the flag-ON path.
    /// Caller is responsible for the existing guard
    /// (`timelineRawBoundaryExtensionState.source == nil`) and any
    /// pre-collapse fade animation; this method only owns the atomic
    /// shrink+scroll write.
    /// Atomic boundary-extension state transition for the issue-#57 flag-ON
    /// path. Supports both FULL close (`.none`) and PARTIAL close (one side
    /// goes to 0 while the other stays open) — the latter is what
    /// `collapseTimelineBoundaryExtensionsIfNeeded` produces on scroll-tick
    /// auto-collapse and was previously missing the co-commit wiring,
    /// causing the user-visible cross-midnight flash even with the flag
    /// ON (memory `feedback_calayer_parity_multi_state_gates` —
    /// multi-state-OR-port silently dropped a branch).
    ///
    /// Caller passes only the SwiftUI fade reset they want — close paths
    /// that fully close zero both; partial-close paths leave the surviving
    /// side's fade progress alone.
    /// Legacy (UIScrollView, non-imperative) close-path: the contentSize +
    /// contentOffset atomic co-commit used to hide the 1-frame mismatch when
    /// the band collapses. Imperative single-day NEVER reaches this — its
    /// callers fork upstream to `handleImperativeBandStateChange` (band
    /// visibility is `contentInset`, not contentSize; see spec 07 §5 S2).
    ///
    /// S7 deletion gate: this function + `TimelineScrollProxy.coCommit` +
    /// `applyCloseLeadingTransientCompensation` all become dead code once the
    /// flag default flips ON and the legacy fallback is removed.
    private func applyCloseBandStateAtomicCoCommit(
        targetState newState: TimelineBoundaryExtensionState,
        resetLeadingFade: Bool,
        resetTrailingFade: Bool,
        callSite: String = #function
    ) {
        let previousState = timelineBoundaryExtensionState
        guard previousState != newState else { return }
        // Spec 07 §5 S2: imperative callers fork upstream, so this is now
        // unreachable on the imperative path. Assert in debug; on release we
        // still defend by redirecting to the inset path so any future caller
        // added without the upstream fork doesn't write contentSize into a
        // 48h-constant substrate.
        assert(!usesImperativeDayLayerModel, "applyCloseBandStateAtomicCoCommit reached on imperative path — caller missing spec-07 S2 fork")
        if usesImperativeDayLayerModel {
            handleImperativeBandStateChange(newState)
            return
        }
        print("⭐️[#57.coCommit.close] site=\(callSite) from=(\(previousState.leadingHours),\(previousState.trailingHours)) to=(\(newState.leadingHours),\(newState.trailingHours)) scrollY=\(String(format: "%.1f", timelineScrollProxy.currentOffsetY)) installed=\(timelineScrollProxy.isInstalled) animator=\(boundaryExtensionScrollAnimator != nil) sameDayReb=\(sameDayRebounceAnimator != nil) visualY=\(String(format: "%.1f", boundaryExtensionVisualYOffset))")
        // Proxy-not-wired fallback (deep-review C6): if the scroll view
        // hasn't installed yet (cold start, mid-dismantle, flag flicker),
        // a coCommit silently no-ops on the offset write — but our SwiftUI
        // state mutation would still apply the new band hours, causing
        // the next `updateUIView` to shrink contentSize with no
        // compensating offset → visible jump. Fall back to the flag-OFF
        // path's transactional collapse instead.
        guard timelineScrollProxy.isInstalled else {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) {
                applyTimelineBoundaryExtensionState(newState)
                if resetLeadingFade { timelineLeadingFadeProgress = 0 }
                if resetTrailingFade { timelineTrailingFadeProgress = 0 }
            }
            return
        }
        // Cancel any in-flight scroll animator + pending compensation
        // task BEFORE we mutate state and co-commit — mirrors the
        // flag-OFF `applyTimelineBoundaryExtensionState`'s reentry guard
        // (step-2 review C1). The 0.3s both-sides fade path could still
        // have a 0.28s open-during-drag spring writing scrollTo ticks;
        // without this cancel they fight the co-commit's offset write.
        pendingBoundaryExtensionScrollTask?.cancel()
        pendingBoundaryExtensionScrollTask = nil
        if boundaryExtensionScrollAnimator != nil {
            boundaryExtensionScrollAnimator?.cancel(reason: "coCommitClose reentry")
            boundaryExtensionScrollAnimator = nil
            boundaryExtensionVisualYOffset = 0
        }
        // Compute the destination contentH via the SAME canonical formula
        // `timelineScrollUIKit` feeds into `updateUIView` (deep-review C3).
        let hourHeight = calendarState.timelineHourHeight
        let topOverlayInset = lastTimelineTopOverlayInset
        let newContentH = calendarTimelineHostContentHeight(
            headerHeight: calendarTimelineTopInset(hourHeight: hourHeight),
            allDayHeight: timelineAllDayHeight,
            hourHeight: hourHeight,
            effectiveSlotMinutes: calendarLegendSlotMinutes(forHourHeight: hourHeight),
            leadingExtendedHours: newState.leadingHours,
            trailingExtendedHours: newState.trailingHours,
            timelineBottomInset: calendarTimelineBottomInset(hourHeight: hourHeight),
            topOverlayInset: topOverlayInset,
            timelineBottomScrollPadding: lastTimelineBottomScrollPadding
        )
        let targetY = calendarResolvedVerticalScrollOffsetForBoundaryExtensionChange(
            currentOffsetY: timelineScrollProxy.currentOffsetY,
            previousState: previousState,
            newState: newState,
            hourHeight: hourHeight
        ) ?? timelineScrollProxy.currentOffsetY
        // SwiftUI state mutation MUST be inside `disablesAnimations` —
        // TimelineView attaches an `.animation(_:value:)` to
        // `leadingExtendedHours` / `trailingExtendedHours` that defaults
        // to a ~0.28s spring outside drag. Without the suppression, the
        // day-layer frame springs over 0.28s AFTER our atomic
        // CATransaction has already snapped contentSize + offset — visible
        // as the "1-frame flash" the close-path PR was supposed to fix.
        // (Mirrors the flag-OFF path's outer
        // `withTransaction(disablesAnimations: true)` wrapping.)
        var swiftUITx = Transaction()
        swiftUITx.disablesAnimations = true
        withTransaction(swiftUITx) {
            timelineBoundaryExtensionState = newState
            if resetLeadingFade { timelineLeadingFadeProgress = 0 }
            if resetTrailingFade { timelineTrailingFadeProgress = 0 }
        }
        // UIScrollView atomic write — separate from the SwiftUI transaction
        // because the disablesAnimations flag only affects SwiftUI animation
        // contexts; UIScrollView/CALayer get their own
        // `CATransaction.setDisableActions(true)` inside `coCommit`.
        //
        // LEADING-collapse stale-Model compensation: on a leading close,
        // the day-layer's KVO `contentOffset` observer + the
        // `layoutIfNeeded` fired inside `coCommit` BOTH re-render against
        // the OLD `leadingExtendedHours` Model field (SwiftUI's body
        // re-eval hasn't propagated yet). Events render at OLD absoluteY
        // (= NEW absoluteY + bandClose*hourHeight) against the NEW
        // compensated offset, so they appear shifted DOWN by
        // `bandClose*hourHeight` for one frame, then snap back UP on
        // the next SwiftUI tick — the user-reported "events flash down
        // then up by ~322pt" bug.
        //
        // Fix: translate the hosted content view UP by the same band
        // amount inside the SAME CATransaction as `coCommit`, then clear
        // the transform on the next runloop tick (after SwiftUI's tick
        // has rendered against the new Model). The earlier
        // `DispatchQueue.main.async` deferral of `coCommit` itself (in
        // commit 1e41081) produced the OPPOSITE artifact (events flashed
        // UP first) because Model was new but offset still old — that
        // path was reverted. This compensation keeps the offset write
        // atomic AND papers over the SwiftUI-Model lag at the same time.
        //
        // Trailing collapses (no leading-hours change) pass `deltaY = 0`
        // and the compensation is a no-op (the chopped trailing band sits
        // BELOW the viewport so absoluteY values are unchanged).
        let leadingHoursClosed = previousState.leadingHours - newState.leadingHours
        let compensationDeltaY = CGFloat(max(0, leadingHoursClosed)) * hourHeight
        timelineScrollProxy.coCommit(
            contentHeight: newContentH,
            offsetY: targetY,
            transientHostYCompensation: compensationDeltaY
        )
    }
    @State private var timelineBoundaryExtensionState: TimelineBoundaryExtensionState = .none
    @State private var timelineRawBoundaryExtensionState: TimelineBoundaryExtensionState = .none
    @State private var timelineScrollViewportHeight: CGFloat = 0
    /// Latest `topOverlayInset` seen by the scroll handler. Stashed so
    /// `handleTimelineBoundaryExtensionStateChange` (a callback that doesn't
    /// receive it) can compute boundary-extension visibility for the
    /// fade-out-only-when-scrolled-away guard. (#55 follow-on)
    @State private var lastTimelineTopOverlayInset: CGFloat = 0
    /// Latched `metrics.timelineBottomScrollPadding` so the close-path
    /// `applyCloseBandStateAtomicCoCommit` can compute contentH via the
    /// canonical formula without needing `metrics` plumbed through every
    /// boundary-extension handler. Refreshed inside `timelineScrollUIKit`
    /// + `timelineScrollSwiftUI` on each evaluation.
    @State private var lastTimelineBottomScrollPadding: CGFloat = 0
    /// Pinch-frozen slot density mirrored out of `TimelinePagerView` so the
    /// UIScrollView path's `contentH` math can use the SAME `effectiveSlot`
    /// the SwiftUI tree uses during a pinch. nil outside pinch.
    /// `TimelinePagerView` fires `onFrozenSlotMinutesChange` only on
    /// transitions (begin / end), so this write does NOT happen every
    /// pinch frame — preserving the deep-review B1 "no per-frame body
    /// re-eval" property (deep-review C2).
    @State private var rangePinchFrozenSlotMinutes: Int? = nil
    @State private var lastDynamicPinchMinInputs: DynamicPinchMinInputs? = nil
    /// Vertical-scroll phase flag.  When true, `VerticalScrollGate` short-
    /// circuits header and TimelinePagerView body re-evaluation, mirroring the
    /// horizontal `DayColumnGate` pattern.  Updated from `.onScrollPhaseChange`
    /// on the timeline's outer ScrollView.
    @State private var isVerticallyScrolling: Bool = false
    @State private var timelineVisibleDayFrameGlobal: CGRect = .zero
    @State private var pendingBoundaryExtensionScrollTask: Task<Void, Never>? = nil
    /// Spring animator for the proactive boundary-extension OPEN transition
    /// during drag. CADisplayLink-paced, runs scrollTo 60×/sec over ~0.28s in
    /// lockstep with `.animation(_:value:leading)` so the canvas unfolds
    /// smoothly instead of snapping. (#55)
    @State private var boundaryExtensionScrollAnimator: BoundaryExtensionScrollAnimator? = nil
    /// Single-overshoot scroll rebounce after a cross-midnight commit
    /// follows the event to the new day. CADisplayLink-driven, ~0.4s, one
    /// damped half-sine peak. Decouples cleanly from the open animator —
    /// they never overlap because follow only fires on commit (drag is
    /// already done). (#55 follow-event-across-midnight)
    @State private var crossDayRebounceAnimator: CalendarRebounceAnimator? = nil
    /// Drives the same-day abandon settle (extension used but NOT crossed):
    /// elastically scrolls the extension band off-screen, then collapses it —
    /// reuses the cross-midnight rebounce curve so the feel matches. Distinct
    /// slot from `crossDayRebounceAnimator` (the two never run together, but a
    /// shared slot would muddle cancellation semantics). (#55 same-day rebounce)
    @State private var sameDayRebounceAnimator: CalendarRebounceAnimator? = nil
    /// Timestamp of the last follow-event-across-midnight re-anchor. Used by
    /// `handleTimelineBoundaryExtensionStateChange` to suppress the 150ms
    /// delayed dismiss path on small-viewport days — that path would
    /// collapse the post-follow extension (mirrored leading↔trailing) right
    /// after follow-event set it, causing a visible 322pt scroll clamp +
    /// content-shift flash. (#55 follow-event-across-midnight)
    @State private var crossDayFollowEventAt: Date? = nil
    /// When true, the day-column horizontal swipe animation triggered by
    /// `selectedDayOffset` changes is skipped — the day swap in the middle
    /// of a follow-event two-phase animation must be a content-equivalent
    /// rename (math holds), not a visible horizontal slide. Set true right
    /// before the atomic swap, cleared at phase 2 onComplete.
    /// (#55 follow-event-across-midnight)
    @State private var suppressDayColumnHorizontalAnimation: Bool = false
    /// Set at follow-event entry to the target host-day offset. The header
    /// reads this as a preferred override over `selectedDayOffset` until
    /// the animator completes — without it, the brief window between
    /// drag-end (drag-driven header date drops out: `draggingEventID=nil`)
    /// and the boundary-tick swap (selectedDayOffset still old) would
    /// flash the header back to the original day. Cleared at follow-event
    /// completion. (#55 follow-event header continuity)
    @State private var pendingFollowEventDayOverride: Int? = nil
    /// 0 = extension bands fully visible, 1 = fully transparent. Driven by
    /// the follow-event rebounce post-swap: the previous day's remnant
    /// (the mirrored extension band) fades out in lockstep with being
    /// pushed out of the viewport, so the final silent collapse removes
    /// content that's already invisible. (#55 follow-on)
    /// Band-fade opacity, controlled INDEPENDENTLY per side (0 = solid,
    /// 1 = transparent). The leading (top) and trailing (bottom) extension
    /// bands dissolve separately — abandoning one must not fade the other.
    @State private var timelineLeadingFadeProgress: CGFloat = 0
    @State private var timelineTrailingFadeProgress: CGFloat = 0
    /// Whole-timeline opacity, briefly dipped to cover the same-day collapse's
    /// single-frame layout flash (the pre/post visible content is identical, so
    /// a quick fade-out → instant collapse-while-dim → fade-in hides the jump
    /// without trying to co-commit contentSize+scroll). 1 = normal. (#55)
    @State private var timelineCollapseDim: Double = 1
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
        .overlay(alignment: .bottom) {
            composerDraftBannerView
        }
        .onAppear {
            refreshComposerDraftBanner()
        }
        // Foreground return after a long suspension: the draft may have
        // crossed its expiry while the banner sat on screen — re-resolve so
        // a dead draft doesn't advertise a rescue it can no longer deliver.
        // Skipped while a create sheet is up: the open form legitimately
        // wrote a draft on departure, and resolving it here would flash a
        // "resume" pill during the sheet's dismissal after a normal Done.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, pendingCreateTimeRange == nil, pendingReminderSchedule == nil {
                refreshComposerDraftBanner()
            }
        }
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
            L(.editRecurringEvent),
            isPresented: $showRecurrenceScopeDialog,
            titleVisibility: .visible
        ) {
            Button(L(.thisEvent)) {
                recurrenceEditScope = .single
                selectedEventForEdit = pendingRecurrenceEdit?.event
            }
            Button(L(.thisAndFuture)) {
                recurrenceEditScope = .following
                selectedEventForEdit = pendingRecurrenceEdit?.event
            }
            Button(L(.allEvents)) {
                recurrenceEditScope = .all
                selectedEventForEdit = pendingRecurrenceEdit?.event
            }
            Button(L(.cancel), role: .cancel) {
                clearRecurrenceEditContext()
            }
        }
        .alert(L(.deleteEvent), isPresented: $showLongPressDeleteConfirm) {
            Button(L(.cancel), role: .cancel) {
                floatingMenuAnchor = nil
                floatingMenuInteractive = false
            }
            Button(L(.delete), role: .destructive) {
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
                Text(L(.deleteConfirmSingle))
            } else {
                Text(L(.deleteConfirmAll))
            }
        }
        .sheet(item: $pendingCreateTimeRange, onDismiss: {
            // After (not during) dismissal: the form's onDisappear has run by
            // now, so a normally-ended session reads back as no draft and the
            // banner stays hidden. Refreshing on the item→nil change instead
            // would race that clear and flash a stale banner.
            refreshComposerDraftBanner()
        }) { pending in
            CreateCalendarEventView(
                timeRange: pending.timeRange,
                resumesDraft: pending.resumesComposerDraft,
                isTypeSuggestionEnabled: calendarAgenticCreateEnabled,
                onCreated: { event in
                    handleCreatedEvent(event, pendingCreate: pending)
                }
            )
            .environmentObject(store)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingReminderSchedule, onDismiss: {
            refreshComposerDraftBanner()
        }) { prefill in
            CreateCalendarEventView(
                timeRange: prefill.timeRange,
                initialTitle: prefill.title,
                initialTypeTitle: prefill.typeTitle,
                initialNote: prefill.note,
                initialLocation: prefill.location,
                preloadedAgenticIntake: prefill.agenticIntake,
                isTypeSuggestionEnabled: calendarAgenticCreateEnabled
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
                }
            )
            .presentationDetents([.medium, .large], selection: $datePickerDetent)
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $isShowingSearch) {
            // Event/log opens push from INSIDE CalendarSearchView (its own
            // navigationDestination). Routing them through
            // `selectedEventDetailRoute` here made the detail push a sibling
            // of the search push, which replaced it — back from the detail
            // then skipped the results list and landed on the calendar.
            CalendarSearchView(
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
        .overlay(TodoPutBackPeek(dragState: timelineDragState, flashTodo: todoPutBackFlash))
        .overlay(todoStackDrawerOverlay)
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
        .onChange(of: store.rawCalendarEvents) {
            rebuildOccurrencesCache()
            updateTimerRefresh()
            // Clear focus when the focused event leaves the canvas — not just
            // when it's deleted.  Absorbed `.todo`s stay in `rawCalendarEvents`
            // (live as children inside their parent) but are filtered out of
            // `canvasRenderableCalendarEvents`, so a raw-only check left other
            // blocks dimmed via `isDimmedByFocus` after absorb until the user
            // tapped empty space.  Canvas focus is a canvas-visibility concept;
            // check against the same filter the canvas reads.
            if let focusedEventID,
               !store.canvasRenderableCalendarEvents.contains(where: { $0.id == focusedEventID }) {
                clearFocus(reason: "calendarEvents.changed.focusedEventCanvasInvisible")
            }
            if let graceOccurrence = resizeGraceOccurrenceContext,
               calendarResolvedEventForOccurrenceContext(graceOccurrence, in: store.rawCalendarEvents) == nil {
                cancelResizeGrace(reason: "calendarEvents.changed.graceTargetRemoved")
            }
        }
        .onChange(of: focusedEventID) { _, newValue in
            calendarFocusState.isEventFocused = newValue != nil
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
        .modifier(CalendarPageS4FocusChannelModifier(
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
            coordinator: dayLayerCoordinator
        ))
        .modifier(CalendarPageS4GraceChannelModifier(
            resizeGraceState: resizeGraceState,
            coordinator: dayLayerCoordinator
        ))
        .modifier(CalendarPageS4PinchChannelModifier(
            hourHeight: calendarState.timelineHourHeight,
            frozenSlotMinutes: rangePinchFrozenSlotMinutes,
            coordinator: dayLayerCoordinator
        ))
        .modifier(CalendarPageS4ModeChannelModifier(
            rangeMode: calendarState.rangeMode,
            coordinator: dayLayerCoordinator
        ))
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
            if boundaryExtensionShouldClearOnRangeModeChange(
                newMode: newValue,
                currentExtensionState: timelineBoundaryExtensionState
            ) {
                clearTimelineBoundaryExtensionState()
            }
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
    /// Todo stack drawer — a custom overlay, NOT a system sheet: the
    /// drag-out slice needs the canvas visible and hittable behind the
    /// drawer while a card is being dragged onto it. Hosted out of the
    /// main modifier chain to keep the body expression type-checkable.
    @ViewBuilder
    var todoStackDrawerOverlay: some View {
        if isShowingTodoStack {
            TodoStackDrawer(
                isPresented: $isShowingTodoStack,
                resolveDrop: todoStackDropPreview(at:excluding:),
                commitDrop: commitTodoStackDrop(todoID:at:)
            )
        }
    }

    /// Maps a global (window) point to a Todo-stack drop target. v1 maps
    /// the DAY view only — multi-day column frames are unreliable while
    /// buffer columns fight over `timelineVisibleDayFrameGlobal` (#65);
    /// other range modes return nil and the drag cancels.
    ///
    /// Y→time reuses the same mapping the drag/header paths use
    /// (`calendarTimelineDateFromYPosition`, 15-min snap). A drop whose
    /// snapped time sits INSIDE a plain event's range reads as
    /// point-in-block (day-view blocks span the full width) and becomes
    /// an absorption; the latest-starting match approximates the
    /// innermost block. Recurring series are excluded — their seed
    /// ranges don't describe today's occurrence.
    func todoStackDropPreview(at globalPoint: CGPoint, excluding todoID: UUID) -> TodoStackDropPreview? {
        guard calendarState.rangeMode == .day else { return nil }
        let frame = timelineVisibleDayFrameGlobal
        guard frame.width > 0, frame.height > 0 else { return nil }
        let hourHeight = calendarState.timelineHourHeight
        guard hourHeight.isFinite, hourHeight > 0 else { return nil }
        // #65: buffer columns overwrite the reported frame's X — it can
        // belong to a column parked thousands of points off-screen. Every
        // column shares the same VERTICAL geometry though, so trust Y and
        // gate X against the page-derived day area instead (the column
        // width right of the hour-axis gutter).
        let pageWidth = capturedPageGeometry.size.width
        guard pageWidth > 0 else { return nil }
        let dayAreaMinX = max(0, pageWidth - frame.width)
        guard globalPoint.x >= dayAreaMinX, globalPoint.x <= pageWidth else { return nil }

        let headerHeight = timelineHeaderHeight
        let localY = globalPoint.y - frame.minY
        let totalVisibleMinutes = calendarTimelineTotalVisibleHours(
            leadingExtendedHours: timelineBoundaryExtensionState.leadingHours,
            trailingExtendedHours: timelineBoundaryExtensionState.trailingHours
        ) * 60
        let maxLocalY = headerHeight + CGFloat(max(0, totalVisibleMinutes)) / 60 * hourHeight
        guard localY >= headerHeight, localY <= maxLocalY else { return nil }

        let selectedDate = calendarDateForSelectedDayOffset(calendarState.selectedDayOffset)
        let start = calendarTimelineDateFromYPosition(
            localY,
            containing: selectedDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: timelineBoundaryExtensionState.leadingHours,
            trailingExtendedHours: timelineBoundaryExtensionState.trailingHours,
            snapMinutes: 15
        )

        let parent = store.rawCalendarEvents
            .filter { candidate in
                candidate.kind == .event
                    && candidate.id != todoID
                    && candidate.absorbedIntoEventID == nil
                    && !candidate.isRecurringSeries
                    && candidate.timeRanges.contains { $0.start <= start && start < $0.end }
            }
            .max { lhs, rhs in
                (lhs.timeRanges.first?.start ?? .distantPast) < (rhs.timeRanges.first?.start ?? .distantPast)
            }

        return TodoStackDropPreview(
            start: start,
            absorbParentID: parent?.id,
            absorbParentTitle: parent?.title
        )
    }

    /// Commits a stack-card drop: writes the snapped 1h range FIRST, then
    /// absorbs when the drop landed inside an event — same order as
    /// `handleEventDrag`, so a later absorption release re-surfaces the
    /// todo at the spot the user dropped it, not dateless.
    func commitTodoStackDrop(todoID: UUID, at globalPoint: CGPoint) -> Bool {
        guard let preview = todoStackDropPreview(at: globalPoint, excluding: todoID),
              var todo = store.rawCalendarEvents.first(where: { $0.id == todoID })
        else { return false }
        todo.timeRanges = [Event.TimeRange(
            start: preview.start,
            end: preview.start.addingTimeInterval(3600)
        )]
        store.updateCalendarEvent(todo)
        if let parentID = preview.absorbParentID {
            store.absorbTodoIntoEvent(todoID: todoID, parentEventID: parentID)
        }
        return true
    }

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
        // The reminder panel occupies real space below the header; the timeline
        // reflows beneath it (never covered). When closed, height is 0 and the
        // timeline sits right under the header.
        let reminderPanelMaxHeight = metrics.containerSize.height * 0.5
        let reminderRevealHeight = isReminderPanelOpen
            ? ReminderPanelView.openHeight(
                count: store.visibleReminders.count,
                maxHeight: reminderPanelMaxHeight
            )
            : 0
        let contentTopInset = topOverlayInset + reminderRevealHeight

        ZStack(alignment: .top) {
            Group {
                if calendarState.rangeMode == .month {
                    monthOverviewContent(
                        metrics: metrics,
                        topOverlayInset: contentTopInset
                    )
                } else if calendarState.rangeMode == .stream {
                    listContent()
                } else {
                    timelineScroll(
                        metrics: metrics,
                        topOverlayInset: contentTopInset
                    )
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: calendarState.rangeMode)

            // Reminder panel sits below the header in z-order (header stays on
            // top) and fills the reflowed gap above the timeline.
            ReminderPanelView(
                isOpen: $isReminderPanelOpen,
                height: reminderRevealHeight,
                maxHeight: reminderPanelMaxHeight,
                horizontalPadding: metrics.horizontalPadding,
                schedulingReminderID: schedulingReminderID,
                onAddToSchedule: scheduleReminder
            )
            .padding(.top, topOverlayInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .zIndex(4)

            topOverlay(
                metrics: metrics,
                topOverlayCapsulesVisible: topOverlayCapsulesVisible,
                topOverlayActionCapsulesVisible: topOverlayActionCapsulesVisible
            )
            .zIndex(5)

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
                        // canvasRenderableCalendarEvents: same absorbed-
                        // filter the main canvas uses, so an absorbed
                        // `.todo` doesn't render as an independent block
                        // on the generated share card.
                        let dayOccurrences = CalendarLayout.occurrencesForDate(
                            store.canvasRenderableCalendarEvents,
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

            // Merge-target hint during absorb drag. Gate on `draggingEventID`
            // (flips only at drag start/end) so the page body isn't re-read
            // each tick; the bubble reads the per-frame touch/target fields
            // internally and is the only view that re-renders per tick.
            if timelineDragState.draggingEventID != nil {
                CalendarAbsorbMergeBubble(dragState: timelineDragState)
                    .allowsHitTesting(false)
                    .zIndex(101)
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
                // Header is intentionally OUTSIDE `VerticalScrollGate` —
                // the gate freezes its subtree's body re-evaluation while
                // the user is vertically scrolling (which is fine for the
                // heavy timeline content), but the header date label needs
                // to reactively follow `timelineVerticalScrollY` during
                // scroll in extended view (leading=12 / trailing=12 spans
                // multiple days; the visible day flips as the user crosses
                // a 12h*hourHeight scroll threshold). (#55 follow-on)
                header(
                    metrics: metrics,
                    isCapsulesVisible: topOverlayCapsulesVisible,
                    isActionCapsulesVisible: topOverlayActionCapsulesVisible
                )
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
        guard var event = calendarResolvedEventForOccurrenceContext(occurrence, in: store.rawCalendarEvents) else {
            return
        }

        // If the search hit is an absorbed `.todo`, redirect focus to
        // the parent event: the absorbed item is filtered out of
        // `canvasRenderableCalendarEvents`, so the canvas has no
        // block bearing its id to focus on (silent no-op). The parent
        // event's block is what visually represents the absorbed
        // child — focus there, the user lands on the right place
        // and can open the parent's detail to see the absorbed
        // todo listed inside.
        var resolvedOccurrenceDate = occurrence.occurrenceDate
        var providedOccurrenceID: String? = occurrence.occurrenceID
        if let parentID = event.absorbedIntoEventID,
           let parent = store.rawCalendarEvents.first(where: { $0.id == parentID }) {
            event = parent
            if let parentStart = parent.primaryTimeRange?.start {
                resolvedOccurrenceDate = Calendar.current.startOfDay(for: parentStart)
            }
            providedOccurrenceID = nil  // recompute below against the parent's range
        }

        cancelResizeGrace(reason: "search.jumpToCalendar")
        resetFloatingMenuState()
        pendingInterruptComposer = nil

        let offset = dayOffset(for: resolvedOccurrenceDate)
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
            occurrenceDate: resolvedOccurrenceDate
        ).map {
            calendarOccurrenceIDForRange(
                event: event,
                range: $0,
                occurrenceDate: resolvedOccurrenceDate
            )
        } ?? providedOccurrenceID

        setFocus(
            event: event,
            occurrenceID: occurrenceID,
            reason: "search.jumpToCalendar"
        )
    }

    func openCalendarEventEditor(id: UUID) {
        guard let event = store.rawCalendarEvents.first(where: { $0.id == id }) else { return }
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
        return store.rawCalendarEvents.last { candidate in
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
    /// The date the header capsule currently represents (tracks scroll + drag).
    var currentHeaderDisplayDate: Date {
        // Follow-event override: forcefully pin to the override day. The
        // default scroll-derived computation would map viewport-top to a
        // time on the OLD day (e.g. yesterday 12:00 at scrollY=0 when
        // leading=12 post-swap), and `startOfDay` would resolve to
        // yesterday — defeating the override. Pin instead so the header
        // shows the new day uninterrupted across drag-end → boundary-tick
        // → animator completion. (#55 follow-event header continuity)
        if let override = pendingFollowEventDayOverride {
            let date = calendarDateForSelectedDayOffset(override)
            return Calendar.current.startOfDay(for: date)
        }
        return calendarResolvedHeaderDisplayDate(
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
    }

    /// The date's solar-term / holiday annotation names, joined for display
    /// in the header capsule subtitle (single-day modes only). Empty string
    /// when there are no enabled annotations.
    var currentDayAnnotationSubtitle: String {
        guard calendarState.rangeMode == .day || calendarState.rangeMode == .stream else { return "" }
        let annotations = CalendarAnnotations.annotations(on: currentHeaderDisplayDate)
        return annotations.map(\.title).joined(separator: " · ")
    }

    func header(
        metrics: CalendarPageMetrics,
        isCapsulesVisible: Bool,
        isActionCapsulesVisible: Bool
    ) -> some View {
        // See `currentHeaderDisplayDate` — same follow-event override.
        let headerDisplayDate: Date = {
            if let override = pendingFollowEventDayOverride {
                let date = calendarDateForSelectedDayOffset(override)
                return Calendar.current.startOfDay(for: date)
            }
            return calendarResolvedHeaderDisplayDate(
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
        }()
        let effectiveDayOffset = pendingFollowEventDayOverride ?? calendarState.selectedDayOffset
        let leftCapsuleTitle = calendarResolvedHeaderCapsuleTitle(
            selectedDayOffset: effectiveDayOffset,
            rangeMode: calendarState.rangeMode,
            headerDisplayDate: headerDisplayDate
        )

        return AppleCalendarHeaderView(
            selectedDate: headerDisplayDate,
            rangeMode: calendarState.rangeMode,
            leftCapsuleTitle: leftCapsuleTitle,
            leftCapsuleSubtitle: currentDayAnnotationSubtitle,
            isCapsulesVisible: isCapsulesVisible,
            isActionCapsuleVisible: isActionCapsulesVisible,
            leftCapsuleSlowTransition: crossDayRebounceAnimator != nil,
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
            onTodoTap: {
                clearFocus()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isShowingTodoStack = true
                }
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
        // canvasRenderableCalendarEvents: same absorbed-filter the main
        // canvas uses.  Without it, absorbed `.todo` items render as
        // independent sibling blocks on the exported daily share card.
        let occurrences = CalendarLayout.occurrencesForDate(store.canvasRenderableCalendarEvents, date: shareDate)
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
                    Text(L(.shareDay))
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

    /// Fade the extension band IN (pure opacity — contentH is untouched).
    /// Seeded transparent first (on the next runloop tick so SwiftUI doesn't
    /// collapse the set-then-animate into a no-op), then eased to solid.
    /// Guards the race where the drag leaves the zone before the async fires.
    private func fadeInBoundaryExtension() {
        // Seed both transparent and fade both in — only the side that actually
        // opened has a band (the other's fade is ignored by the mask).
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            timelineLeadingFadeProgress = 1
            timelineTrailingFadeProgress = 1
        }
        DispatchQueue.main.async { [self] in
            guard timelineRawBoundaryExtensionState.hasAnyExtension else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                timelineLeadingFadeProgress = 0
                timelineTrailingFadeProgress = 0
            }
        }
    }

    /// DURING-DRAG, FINGER-DRIVEN dissolve for an abandoned-but-still-open
    /// extension. While dragging (move OR resize) with the intent (`raw`) OUT
    /// of the trigger zone, the band's opacity tracks how far the dragged edge
    /// has pulled BACK across the boundary into the day — solid while still
    /// crossing, dissolving once the edge is `abandonFadeStartHours` into the
    /// day, fully transparent by `+ abandonFadeRangeHours`. This responds to the
    /// drag itself (not the scroll), so it works even when the scroll doesn't
    /// move. A separate gate collapses the contentH only once the band is fully
    /// off the viewport edge (exact comp → no jump). Called on every drag-offset
    /// change, scroll tick, and zone change. (#55 follow-on)
    private func refreshAbandonedExtension(topOverlayInset: CGFloat) {
        // Settle-window guard — during the post-follow-event window the
        // rebounce animator drives the fade directly; refreshing here would
        // churn it. (See §4e + invariant 4 of the state-interaction map.)
        if let stamp = crossDayFollowEventAt,
           Date().timeIntervalSince(stamp) < crossDayFollowSettleWindow {
            return
        }
        // `draggingOriginalRange` non-nil is a precondition of the helper's
        // signature; the matching early-returns inside the helper handle the
        // other gates (`appliedState.hasAnyExtension`, `rawState.source != nil
        // && !hasAnyExtension`, `hourHeight > 0`).
        guard let original = timelineDragState.draggingOriginalRange else { return }
        let input = AbandonedFadeInputs(
            rawState: timelineRawBoundaryExtensionState,
            appliedState: timelineBoundaryExtensionState,
            dragOriginalRange: original,
            dragOffsetY: timelineDragState.dragOffset.y,
            hourHeight: calendarState.timelineHourHeight,
            extensionOriginY: topOverlayInset + timelineAllDayHeight + timelineHeaderHeight,
            scrollY: timelineVerticalScrollY,
            viewportHeight: timelineScrollViewportHeight,
            baseVisibleHours: calendarTimelineBaseVisibleHours
        )
        let curves = computeAbandonedFadeCurves(input)

        // Write-coalescing gate stays at the call site (it's a state-write
        // concern, not part of the curve math). Each side writes only when
        // the curve helper produced a value AND it differs from the current
        // state by > 0.001.
        var fadeTx = Transaction()
        fadeTx.disablesAnimations = true
        if let f = curves.leading, abs(timelineLeadingFadeProgress - f) > 0.001 {
            withTransaction(fadeTx) { timelineLeadingFadeProgress = f }
        }
        if let f = curves.trailing, abs(timelineTrailingFadeProgress - f) > 0.001 {
            withTransaction(fadeTx) { timelineTrailingFadeProgress = f }
        }
        // NB: still NO collapse here. Both stages are pure opacity (no contentH/
        // scroll write → no auto-recenter, no detach). The contentH collapse
        // waits for release. (#55 follow-on)
    }

    // MARK: - Spec 07 imperative band (inset-driven open/close)

    /// Resting band insets for a band state in the 48h model — mirrors the
    /// formula in `timelineScrollUIKit` so an animated transition lands exactly
    /// on the value `updateUIView` would otherwise snap to.
    private func imperativeBandInsetTargets(
        for state: TimelineBoundaryExtensionState, hourHeight: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat) {
        let maxBand = CGFloat(calendarTimelineMaximumBoundaryExtensionHours)
        let header = calendarTimelineTopInset(hourHeight: hourHeight)
        let top = pinnedAllDayHeight - header - (maxBand - CGFloat(state.leadingHours)) * hourHeight
        let bottom = -(maxBand - CGFloat(state.trailingHours)) * hourHeight
        return (top, bottom)
    }

    /// Spec 07 §2A/§D: band open/close on the 48h substrate. The day-layer
    /// already renders the constant 48h geometry, so open/close is PURELY a
    /// `contentInset` reveal/rebounce plus the existing mask fade — none of the
    /// original contentSize co-commit / offset-compensation / off-screen-scroll
    /// machinery applies (no contentSize change ⇒ no race). Band state here
    /// drives ONLY the inset + fade (+ later, occurrence supply); it never
    /// changes the render, which is always 48h.
    private func handleImperativeBandStateChange(_ newState: TimelineBoundaryExtensionState) {
        guard calendarState.rangeMode == .day else { return }
        timelineRawBoundaryExtensionState = newState
        let retained = calendarRetainedTimelineBoundaryExtensionState(
            currentState: timelineBoundaryExtensionState,
            rawState: newState
        )
        let wasOpen = timelineBoundaryExtensionState.hasAnyExtension
        let hourHeight = calendarState.timelineHourHeight

        if newState.source != nil {
            // ACTIVE DRAG: keep the band revealed for the whole drag (retained);
            // fade follows the raw intent — solid while crossing, finger-driven
            // dissolve when abandoned. Never collapse mid-drag.
            timelineBoundaryExtensionState = retained
            guard retained.hasAnyExtension else { return }
            let (t, b) = imperativeBandInsetTargets(for: retained, hourHeight: hourHeight)
            timelineScrollProxy.setBandInset(top: t, bottom: b, animated: true)
            if newState.hasAnyExtension {
                if !wasOpen {
                    fadeInBoundaryExtension()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if newState.leadingHours > 0 { timelineLeadingFadeProgress = 0 }
                        if newState.trailingHours > 0 { timelineTrailingFadeProgress = 0 }
                    }
                }
            } else {
                refreshAbandonedExtension(topOverlayInset: lastTimelineTopOverlayInset)
            }
        } else {
            // RELEASE: rebounce the band closed (inset spring) + fade out, then
            // settle state. Set state .none immediately so the RESTING inset
            // equals the animation target (no post-spring snap-back). The render
            // is unchanged either way (always 48h), so dropping the state here
            // is invisible.
            guard timelineBoundaryExtensionState.hasAnyExtension else { return }
            withAnimation(.easeIn(duration: 0.28)) {
                timelineLeadingFadeProgress = 1
                timelineTrailingFadeProgress = 1
            }
            timelineBoundaryExtensionState = .none
            let (t, b) = imperativeBandInsetTargets(for: .none, hourHeight: hourHeight)
            timelineScrollProxy.setBandInset(top: t, bottom: b, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                // Re-engaged during the rebounce → leave the fade for the new drag.
                guard timelineRawBoundaryExtensionState.source == nil else { return }
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) {
                    timelineRawBoundaryExtensionState = .none
                    timelineLeadingFadeProgress = 0
                    timelineTrailingFadeProgress = 0
                }
            }
        }
    }

    func handleTimelineBoundaryExtensionStateChange(_ newState: TimelineBoundaryExtensionState) {
        // Spec 07: in the 48h-constant model band open/close is a contentInset
        // animation (constant contentSize), so route to the simplified
        // inset-driven path instead of the contentSize co-commit machinery
        // below (which would fight the 48h-constant host).
        if usesImperativeDayLayerModel {
            handleImperativeBandStateChange(newState)
            return
        }
        // Extended view is only supported in day view — multi-day
        // columns are too narrow for meaningful extended interaction.
        guard calendarState.rangeMode == .day else {
            if boundaryExtensionShouldClearOnRangeModeChange(
                newMode: calendarState.rangeMode,
                currentExtensionState: timelineBoundaryExtensionState
            ) {
                clearTimelineBoundaryExtensionState()
            }
            return
        }
        timelineRawBoundaryExtensionState = newState
        let retainedState = calendarRetainedTimelineBoundaryExtensionState(
            currentState: timelineBoundaryExtensionState,
            rawState: newState
        )

        let followGuardActive: Bool = {
            guard let stamp = crossDayFollowEventAt else { return false }
            return Date().timeIntervalSince(stamp) < crossDayFollowSettleWindow
        }()

        let wasOpen = timelineBoundaryExtensionState.hasAnyExtension
        applyTimelineBoundaryExtensionState(retainedState)

        // Pure-opacity intent tracking. contentH follows the RETAINED state
        // (kept open for the whole drag — we never collapse mid-drag, which
        // would force a scroll re-compensation and the visible misalignment).
        // The band's OPACITY follows the RAW (intent) state: enter the zone →
        // fade the band IN, leave it → fade OUT (band goes transparent, canvas
        // height untouched). The actual collapse waits for release (handled by
        // the dismiss / scroll-driven paths below + in
        // `collapseTimelineBoundaryExtensionsIfNeeded`). (#55 follow-on)
        if newState.source != nil, retainedState.hasAnyExtension, !followGuardActive {
            if newState.hasAnyExtension {
                // In the zone (intent to cross) → keep the band solid.
                if !wasOpen {
                    fadeInBoundaryExtension()
                } else {
                    // Re-engaging: make SOLID only the side(s) currently being
                    // crossed (per `newState`). Leave the other side at its
                    // current fade — if it was abandoned earlier, it stays
                    // dissolved instead of snapping back to solid. (#55)
                    withAnimation(.easeOut(duration: 0.2)) {
                        if newState.leadingHours > 0 { timelineLeadingFadeProgress = 0 }
                        if newState.trailingHours > 0 { timelineTrailingFadeProgress = 0 }
                    }
                }
            } else {
                // Left the zone → the finger-driven dissolve (also re-run on
                // every drag-offset change + scroll tick) handles the fade and
                // the off-screen collapse. (#55 follow-on)
                refreshAbandonedExtension(topOverlayInset: lastTimelineTopOverlayInset)
            }
        }

        // When the drag source clears (finger lifted) near max
        // pinch, the extension can't be scrolled away naturally
        // (scroll range too small). Route the dismiss through
        // `applyTimelineBoundaryExtensionState(.none)` so the scroll
        // position is compensated alongside the leading/trailing
        // collapse (matches what the open path does during drag, just
        // running in reverse). The previous `clearTimelineBoundaryExtensionState`
        // bypassed scroll compensation, so when the canvas height
        // shrank from extended → base, ScrollView clamped contentOffset
        // back into range out-of-sync with the leading-driven content
        // shift — the user-observed "canvas slides up then snaps
        // back" bounce. (#53 single-day regression)
        // Suppress the 150ms small-day dismiss when follow-event-across-
        // midnight just ran. Follow-event intentionally leaves the mirrored
        // extension open as the post-commit settled state; the original
        // dismiss path (designed for small-day post-drag cleanup) would
        // collapse it and flash the canvas. The guard window covers the
        // dispatch delay + a margin. (#55 follow-event-across-midnight)
        if newState.source == nil, retainedState.hasAnyExtension, !followGuardActive {
            let hourHeight = calendarState.timelineHourHeight
            let baseContentHeight = CGFloat(calendarTimelineBaseVisibleHours) * hourHeight
            let scrollableRange = baseContentHeight - timelineScrollViewportHeight
            if scrollableRange < hourHeight * 2 {
                let leading = timelineBoundaryExtensionState.leadingHours
                let trailing = timelineBoundaryExtensionState.trailingHours
                let singleSide = (leading > 0) != (trailing > 0)
                if singleSide {
                    // Abandon-release, ONE side open: "弹性收回基准日" — settle
                    // back to the base day with the same elastic rebounce as the
                    // cross-midnight follow. We REBOUNCE-SCROLL the extension band
                    // off the viewport edge (0:00→top for leading, 24:00→bottom
                    // for trailing) — content stays a fixed size during the scroll
                    // (band is still present), so there's no contentH/scroll
                    // co-commit jump — then collapse it once it's off-screen.
                    // (#55 same-day rebounce)
                    sameDayRebounceAnimator?.cancel()
                    let preStart = timelineVerticalScrollY
                    let fadeLeading = leading > 0
                    let settlePost: CGFloat = fadeLeading
                        ? CGFloat(leading) * hourHeight
                        : max(0, baseContentHeight - timelineScrollViewportHeight)
                    sameDayRebounceAnimator = CalendarRebounceAnimator(
                        duration: 1.1,
                        onTick: { [self] value in
                            guard timelineRawBoundaryExtensionState.source == nil else {
                                // Re-engaged mid-settle → abort, restore solid.
                                sameDayRebounceAnimator?.cancel()
                                sameDayRebounceAnimator = nil
                                var tx = Transaction(); tx.disablesAnimations = true
                                withTransaction(tx) {
                                    timelineLeadingFadeProgress = 0
                                    timelineTrailingFadeProgress = 0
                                }
                                return
                            }
                            // Inverted "release-from-stretch": progress 0→1 with a
                            // single overshoot past 1. Scroll preStart→settlePost;
                            // the band fades FRONT-LOADED so it dissolves while
                            // still on-screen instead of snapping off the edge.
                            let progress = 1 - value
                            let frac = min(1, max(0, progress))
                            let inv = 1 - frac
                            let fade = 1 - inv * inv
                            let y = max(0, preStart + (settlePost - preStart) * progress)
                            var tx = Transaction(); tx.disablesAnimations = true
                            withTransaction(tx) {
                                scrollVerticallyTo(y: y)
                                if fadeLeading {
                                    timelineLeadingFadeProgress = max(timelineLeadingFadeProgress, fade)
                                } else {
                                    timelineTrailingFadeProgress = max(timelineTrailingFadeProgress, fade)
                                }
                            }
                        },
                        onComplete: { [self] in
                            sameDayRebounceAnimator = nil
                            // Re-engaged on the completion frame → don't collapse
                            // out from under a now-active drag; keep the band
                            // solid and bail (mirrors onTick's guard). (#55)
                            guard timelineRawBoundaryExtensionState.source == nil else {
                                var tx = Transaction(); tx.disablesAnimations = true
                                withTransaction(tx) {
                                    timelineLeadingFadeProgress = 0
                                    timelineTrailingFadeProgress = 0
                                }
                                return
                            }
                            // The band is off-screen and the displayed content
                            // (base day from 0:00) is IDENTICAL before and after
                            // the collapse — only the 1-frame contentSize+scroll
                            // co-commit flashes.
                            // Flag-ON path (issue #57): one atomic CATransaction
                            // shrinks contentSize + scrolls the offset
                            // simultaneously — no 1-frame mismatch to cover.
                            // Flag-OFF path: keep the brief opacity dip workaround
                            // (fade to 0, collapse while invisible, fade back).
                            if useUIScrollViewTimeline {
                                // (Outer guard at line :2937 already verified
                                // `source == nil` for this completion frame;
                                // no need to re-check.)
                                // Spec 07 §5 S2: imperative skips the
                                // contentSize co-commit machinery — band
                                // visibility is `contentInset`, not size.
                                if usesImperativeDayLayerModel {
                                    handleImperativeBandStateChange(.none)
                                } else {
                                    applyCloseBandStateAtomicCoCommit(
                                        targetState: .none,
                                        resetLeadingFade: true,
                                        resetTrailingFade: true
                                    )
                                }
                            } else {
                                if useUIScrollViewTimeline {
                                    print("🚨[#57.dim.UNREACHABLE] dim fade fired on flag-ON path — fork broken at single-side rebounce close")
                                }
                                withAnimation(.easeIn(duration: 0.09)) { timelineCollapseDim = 0 }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [self] in
                                    // Re-engaged during the dim window → restore, skip.
                                    guard timelineRawBoundaryExtensionState.source == nil else {
                                        withAnimation(.easeOut(duration: 0.14)) { timelineCollapseDim = 1 }
                                        return
                                    }
                                    var tx = Transaction(); tx.disablesAnimations = true
                                    withTransaction(tx) {
                                        applyTimelineBoundaryExtensionState(.none)
                                        timelineLeadingFadeProgress = 0
                                        timelineTrailingFadeProgress = 0
                                    }
                                    withAnimation(.easeOut(duration: 0.14)) { timelineCollapseDim = 1 }
                                }
                            }
                        }
                    )
                } else {
                    // Both sides open (or none): can't settle both edges off at
                    // once — keep the fade-out-then-instant-collapse. FADE the
                    // band out first (visible dissolve), THEN collapse. The fade
                    // runs while not scrolling, so VerticalScrollGate isn't frozen
                    // and the mask re-renders. (#55 follow-on)
                    withAnimation(.easeIn(duration: 0.3)) {
                        timelineLeadingFadeProgress = 1
                        timelineTrailingFadeProgress = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                        guard timelineRawBoundaryExtensionState.source == nil else {
                            // Re-engaged before the fade finished — restore solid.
                            withAnimation(.easeOut(duration: 0.2)) {
                                timelineLeadingFadeProgress = 0
                                timelineTrailingFadeProgress = 0
                            }
                            return
                        }
                        // Collapse animation-free in lockstep with the scroll snap.
                        // Band is already invisible from the fade, so the collapse
                        // removes nothing visible. (#53 single-day follow-on)
                        // Flag-ON (issue #57): atomic co-commit (contentSize +
                        // contentOffset in one CATransaction). Flag-OFF: SwiftUI
                        // transaction (1-frame mismatch hidden by the
                        // already-invisible band).
                        if useUIScrollViewTimeline {
                            // Spec 07 §5 S2: imperative skips the contentSize
                            // co-commit machinery — band visibility is
                            // `contentInset`, not size.
                            if usesImperativeDayLayerModel {
                                handleImperativeBandStateChange(.none)
                            } else {
                                applyCloseBandStateAtomicCoCommit(
                                    targetState: .none,
                                    resetLeadingFade: true,
                                    resetTrailingFade: true
                                )
                            }
                        } else {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                applyTimelineBoundaryExtensionState(.none)
                                timelineLeadingFadeProgress = 0
                                timelineTrailingFadeProgress = 0
                            }
                        }
                    }
                }
            }
        }
    }

    func applyTimelineBoundaryExtensionState(_ newState: TimelineBoundaryExtensionState) {
        let previousState = timelineBoundaryExtensionState
        guard previousState != newState else { return }
        // Spec 07: this path mutates contentSize (growing-canvas model) and
        // must never run on the constant-48h imperative substrate. All current
        // callers are gated upstream; this entry guard redirects any future
        // ungated caller to the inset-driven imperative band path.
        if usesImperativeDayLayerModel {
            handleImperativeBandStateChange(newState)
            return
        }
        if useUIScrollViewTimeline {
            print("🚨[#57.applyState.UNWIRED] from=(\(previousState.leadingHours),\(previousState.trailingHours)) to=(\(newState.leadingHours),\(newState.trailingHours)) source=\(String(describing: newState.source as Any))")
        }

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
        if boundaryExtensionScrollAnimator != nil {
            boundaryExtensionScrollAnimator?.cancel(reason: "applyState reentry")
            boundaryExtensionScrollAnimator = nil
            boundaryExtensionVisualYOffset = 0
        }
        let targetPoint = CGPoint(x: 0, y: targetY)

        // Spring-animate scroll when opening the extension during drag
        // (#55): SwiftUI ScrollPosition.scrollTo snaps in one frame on iOS
        // 26 regardless of ambient animation, so we feed it 60 interpolated
        // targets/sec from a CADisplayLink. The `.animation(_:value:)`
        // modifier on `leading` springs over the same 0.28s duration, so
        // both canvas height and scroll position move on the same time
        // axis and the dragged event stays glued to its visible window
        // position as the canvas unfolds above it.
        if leadingOpened, newState.source == .moveDrag || newState.source == .resizeTop {
            let startY = timelineVerticalScrollY
            let delta = targetY - startY
            // Seed the visual offset to -delta so the first rendered frame
            // shows pre-open positions (cancels the leading-snap layout jump).
            boundaryExtensionVisualYOffset = -delta
            boundaryExtensionScrollAnimator = BoundaryExtensionScrollAnimator(
                onTick: { progress in
                    let y = startY + delta * progress
                    // offset = scrollY - targetY: at progress=0 → -delta, at progress=1 → 0.
                    // Keeps events glued to their pre-open visible position throughout the spring.
                    let offset = y - targetY
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scrollVerticallyTo(y: y)
                        boundaryExtensionVisualYOffset = offset
                    }
                },
                onComplete: {
                    boundaryExtensionVisualYOffset = 0
                    boundaryExtensionScrollAnimator = nil
                }
            )
            return
        }

        if calendarShouldApplyBoundaryExtensionScrollCompensationImmediately(source: newState.source) {
            pendingBoundaryExtensionScrollTask = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollVerticallyTo(y: targetPoint.y)
            }
            return
        }
        pendingBoundaryExtensionScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollVerticallyTo(y: targetPoint.y)
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
        // Spec 07: imperative substrate — auto-collapse is an inset rebounce to
        // the collapsed state, NOT a contentSize co-commit. Reset fade only on
        // sides that actually collapsed this tick.
        if usesImperativeDayLayerModel {
            let hourHeight = calendarState.timelineHourHeight
            let leadingCollapsed = timelineBoundaryExtensionState.leadingHours > 0
                && collapsedState.leadingHours == 0
            let trailingCollapsed = timelineBoundaryExtensionState.trailingHours > 0
                && collapsedState.trailingHours == 0
            timelineBoundaryExtensionState = collapsedState
            let (t, b) = imperativeBandInsetTargets(for: collapsedState, hourHeight: hourHeight)
            timelineScrollProxy.setBandInset(top: t, bottom: b, animated: true)
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) {
                if leadingCollapsed { timelineLeadingFadeProgress = 0 }
                if trailingCollapsed { timelineTrailingFadeProgress = 0 }
            }
            return
        }
        // Issue #57 (deep follow-up): when the UIScrollView path is ON,
        // route the auto-collapse through the same atomic co-commit as the
        // drag-release close paths. Without this, EVERY scroll tick that
        // crosses the band's outer edge fires
        // `applyTimelineBoundaryExtensionState` (flag-OFF path) → SwiftUI
        // contentSize shrinks → contentOffset doesn't co-commit → 1-frame
        // flash. This was the third close-path entry the prior reviews
        // didn't catch (memory `feedback_calayer_parity_multi_state_gates`).
        // Reset fade ONLY on sides that actually collapsed in this tick.
        if useUIScrollViewTimeline {
            // Spec 07 §5 S2: imperative skips the contentSize co-commit
            // machinery — band visibility is `contentInset`, not size.
            // Note: `handleImperativeBandStateChange(collapsedState)` with
            // `source == nil` currently routes through the unconditional
            // full-close release branch (sets state to `.none`) — byte-
            // identical to today's defensive-redirect behavior. A future
            // slice can teach the imperative path partial-side close if
            // visual A/B surfaces a regression.
            if usesImperativeDayLayerModel {
                handleImperativeBandStateChange(collapsedState)
            } else {
                applyCloseBandStateAtomicCoCommit(
                    targetState: collapsedState,
                    resetLeadingFade: timelineBoundaryExtensionState.leadingHours > 0
                        && collapsedState.leadingHours == 0,
                    resetTrailingFade: timelineBoundaryExtensionState.trailingHours > 0
                        && collapsedState.trailingHours == 0
                )
            }
            return
        }
        // Mirror the drag-end dismiss path's `disablesAnimations` guard
        // (see 2580-2591). `applyTimelineBoundaryExtensionState` now snaps
        // scroll via `disablesAnimations = true` on the inner scrollTo
        // transaction in BOTH directions (since
        // `calendarResolvedVerticalScrollOffsetForBoundaryExtensionChange`
        // became symmetric in #53). The outer
        // `withAnimation(.easeOut(0.25))` here used to wrap a path that
        // never compensated scroll, so leading and scroll could each have
        // their own animations — but post-PR, scroll snaps while
        // `leading` springs via TimelineView's `.animation(_:value:)`
        // modifier (returns ~0.28s spring outside drag). The two get
        // out-of-sync, content drifts ~0.28s. Suppress the leading
        // spring with the same transaction so leading + scroll snap in
        // lockstep, matching the drag-end dismiss flow.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            applyTimelineBoundaryExtensionState(collapsedState)
        }
    }

    func clearTimelineBoundaryExtensionState(callSite: String = #function) {
        if useUIScrollViewTimeline && timelineBoundaryExtensionState.hasAnyExtension {
            print("🚨[#57.clearState.UNWIRED] site=\(callSite) from=(\(timelineBoundaryExtensionState.leadingHours),\(timelineBoundaryExtensionState.trailingHours))")
        }
        // Idempotent guard: when nothing is actually open (state + raw
        // already `.none` and no animator/task in flight), the writes
        // below would resolve against already-default state. Skipping
        // outright makes `boundaryExtensionShouldClearOnRangeModeChange
        // == false` a true no-op at the proactive `.onChange(of:
        // rangeMode)` call site — see `Docs/calendar-page-state-map.md`
        // §4c.
        guard timelineBoundaryExtensionState != .none
            || timelineRawBoundaryExtensionState != .none
            || pendingBoundaryExtensionScrollTask != nil
            || boundaryExtensionScrollAnimator != nil
            || sameDayRebounceAnimator != nil
        else { return }
        pendingBoundaryExtensionScrollTask?.cancel()
        pendingBoundaryExtensionScrollTask = nil
        boundaryExtensionScrollAnimator?.cancel(reason: "clearState")
        boundaryExtensionScrollAnimator = nil
        sameDayRebounceAnimator?.cancel()
        sameDayRebounceAnimator = nil
        boundaryExtensionVisualYOffset = 0
        // Restore the abandon-collapse opacity dip + per-side fades so a
        // teardown landing mid-animation (leave day mode / change day / detail
        // route) can't strand the timeline dim or faded. (#55)
        timelineCollapseDim = 1
        timelineLeadingFadeProgress = 0
        timelineTrailingFadeProgress = 0
        timelineRawBoundaryExtensionState = .none
        timelineBoundaryExtensionState = .none
    }

    /// If the persisted hourHeight is below the current viewport's pinch
    /// fit min (e.g. because it was saved with an older calculation), bump
    /// it up.  Called when viewport state becomes available so the user
    /// immediately sees the "whole day fits" view as the smallest state.
    func applyDynamicPinchMinIfNeeded(topOverlayInset: CGFloat, bottomInset: CGFloat) {
        guard timelineScrollViewportHeight > 0 else { return }
        // Dedup: caller now only invokes this on viewport-height change (see
        // onScrollGeometryChange), but the same viewport "establish" can fire
        // multiple times with identical values during initial layout — the
        // dedup keeps repeat invocations idempotent (if bumped,
        // hourHeight == dynamicMin and the next check is a no-op).
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

    @ViewBuilder
    func timelineScroll(metrics: CalendarPageMetrics, topOverlayInset: CGFloat) -> some View {
        if useUIScrollViewTimeline {
            timelineScrollUIKit(metrics: metrics, topOverlayInset: topOverlayInset)
        } else {
            timelineScrollSwiftUI(metrics: metrics, topOverlayInset: topOverlayInset)
        }
    }

    /// SwiftUI path: original ScrollView host. Active when
    /// `useUIScrollViewTimeline` is OFF (default). Unchanged from before
    /// PR #89 except the body is now reached through the fork above.
    private func timelineScrollSwiftUI(metrics: CalendarPageMetrics, topOverlayInset: CGFloat) -> some View {
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
                    .opacity(timelineCollapseDim)
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
                scrollVerticallyTo(y: targetY)
            }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
            // Body extracted to `handleTimelineUIScrollChange` so the
            // UIScrollView path (`timelineScrollUIKit`'s `onScrollChange`
            // callback) reuses the exact same sequence — gate thresholds,
            // ordering, and nuance comments (cancelResizeGrace gate,
            // updateReminderPanelForScroll, applyDynamicPinchMinIfNeeded,
            // refreshAbandonedExtension, collapseTimelineBoundaryExtensionsIfNeeded)
            // all live in one place. (deep-review N5)
            handleTimelineUIScrollChange(
                offsetY: newValue.contentOffset.y,
                viewportHeight: newValue.visibleRect.height,
                topOverlayInset: topOverlayInset,
                metrics: metrics
            )
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
        // FINGER-DRIVEN dissolve: re-run on every drag-offset change so an
        // abandoned-but-open extension fades as the dragged event/edge pulls
        // back into the day — even when the scroll never moves. (#55 follow-on)
        .onChange(of: timelineDragState.dragOffset.y) { _, _ in
            refreshAbandonedExtension(topOverlayInset: lastTimelineTopOverlayInset)
        }
        .mask {
            TimelineMaskView(
                top: metrics.topMaskConfig,
                bottom: metrics.bottomMaskConfig
            )
        }
    }

    /// UIKit path: `UIScrollView`-backed host (issue #57). Active when
    /// `useUIScrollViewTimeline` is ON. `contentHeight` is computed from
    /// the SAME slot-aware formula `TimelinePagerView.timelineHeight`
    /// uses, so PR-#2-step-2's `coCommit` call can shrink the band
    /// without a SwiftUI re-eval racing it. Lifecycle modifiers
    /// (`.task`, `.onChange`, `.mask`) live outside the host so they
    /// apply uniformly across both paths.
    private func timelineScrollUIKit(metrics: CalendarPageMetrics, topOverlayInset: CGFloat) -> some View {
        let hourHeight = calendarState.timelineHourHeight
        // During a pinch, TimelinePagerView freezes slotMinutes at gesture
        // start (see `rangePinchFrozenSlotMinutes` there) so the legend / grid
        // don't flicker as hourHeight crosses the 76pt threshold.  Mirror that
        // freeze here via the `onFrozenSlotMinutesChange` callback so contentH
        // is computed from the SAME `effectiveSlot` the SwiftUI tree lays out
        // against — otherwise UIScrollView ends with stale scrollable space at
        // the bottom mid-pinch (deep-review C2).  Outside pinch the local
        // @State is nil → the live formula applies.
        let effectiveSlot = rangePinchFrozenSlotMinutes ?? calendarLegendSlotMinutes(forHourHeight: hourHeight)
        let bottomPad = metrics.timelineBottomScrollPadding
        if abs(lastTimelineBottomScrollPadding - bottomPad) > 0.5 {
            DispatchQueue.main.async {
                lastTimelineBottomScrollPadding = bottomPad
            }
        }
        // Spec 07: in the 48h-constant model the band hours are pinned to 12/12
        // (constant `contentSize`) and the all-day row is pinned out of the
        // scroll, so the scrolled content reserves no all-day band. Band
        // visibility is the `contentInset` below, not this height.
        let imperative = usesImperativeDayLayerModel
        let contentLeadingHours = imperative
            ? calendarTimelineMaximumBoundaryExtensionHours
            : timelineBoundaryExtensionState.leadingHours
        let contentTrailingHours = imperative
            ? calendarTimelineMaximumBoundaryExtensionHours
            : timelineBoundaryExtensionState.trailingHours
        let contentH = calendarTimelineHostContentHeight(
            headerHeight: calendarTimelineTopInset(hourHeight: hourHeight),
            allDayHeight: imperative ? 0 : timelineAllDayHeight,
            hourHeight: hourHeight,
            effectiveSlotMinutes: effectiveSlot,
            leadingExtendedHours: contentLeadingHours,
            trailingExtendedHours: contentTrailingHours,
            timelineBottomInset: calendarTimelineBottomInset(hourHeight: hourHeight),
            topOverlayInset: topOverlayInset,
            timelineBottomScrollPadding: bottomPad
        )
        // Band visibility = contentInset (spec 07 §2A), driven by the REAL band
        // state: each side's inset relaxes from "hidden" (closed) toward 0 as it
        // opens. Closed leading = `pinnedAllDayHeight - 12h` (band hidden, 0:00
        // just below the pinned pills); fully open leading = `pinnedAllDayHeight`
        // (12h band revealed). Trailing symmetric (no all-day term). The handler
        // animates the transition via `proxy.setBandInset`; this is the RESTING
        // value `updateUIView` snaps to (and tracks hourHeight pinch).
        let maxBand = CGFloat(calendarTimelineMaximumBoundaryExtensionHours)
        // The band is revealed (inset relaxed) ONLY while a drag is actively
        // crossing a boundary — `timelineRawBoundaryExtensionState.source` is the
        // LIVE drag-mapping signal (nil at rest). Keying the RESTING inset off
        // this (not the retained `timelineBoundaryExtensionState`, which can stay
        // open after a settle/rebounce) guarantees the inset clamps closed at
        // rest on every SwiftUI re-eval — so a refresh can never re-expose the
        // bands. During the drag the transition is animated by the handler's
        // `setBandInset`; this resting value lands on the same target.
        let bandDragActive = timelineRawBoundaryExtensionState.source != nil
        let openLeading: CGFloat = bandDragActive
            ? CGFloat(timelineBoundaryExtensionState.leadingHours) : 0
        let openTrailing: CGFloat = bandDragActive
            ? CGFloat(timelineBoundaryExtensionState.trailingHours) : 0
        // The leading band sits in content coords BELOW the `headerHeight`
        // headroom and ABOVE 0:00, so hiding it requires clamping past BOTH the
        // 12h band AND that headroom — otherwise the band's bottom tail leaks
        // above 0:00 (the reported "extra 12h shown by default"). Trailing has
        // no headroom term (the day ends at 24:00 with only scroll padding
        // below, already covered by the −12h).
        let bandHeader = calendarTimelineTopInset(hourHeight: hourHeight)
        let bandInsetTop: CGFloat = imperative
            ? pinnedAllDayHeight - bandHeader - (maxBand - openLeading) * hourHeight
            : 0
        let bandInsetBottom: CGFloat = imperative
            ? -(maxBand - openTrailing) * hourHeight
            : 0
        return TimelineScrollHost(
            proxy: timelineScrollProxy,
            contentHeight: contentH,
            bandContentInsetTop: bandInsetTop,
            bandContentInsetBottom: bandInsetBottom,
            onScrollChange: { offsetY, viewportHeight in
                handleTimelineUIScrollChange(
                    offsetY: offsetY,
                    viewportHeight: viewportHeight,
                    topOverlayInset: topOverlayInset,
                    metrics: metrics
                )
            },
            onPhaseChange: { isScrolling in
                // Bridge UIScrollView phase → `isVerticallyScrolling` so
                // `VerticalScrollGate` short-circuits the heavy
                // `TimelinePagerView` subtree during scroll, matching the
                // SwiftUI path's `.onScrollPhaseChange` discipline
                // (deep-review B2).
                if isVerticallyScrolling != isScrolling {
                    isVerticallyScrolling = isScrolling
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                timelineLayer(
                    rebuildKey: "timeline-\(calendarState.rangeMode)-effortOpacity\(effortOpacityEnabled)",
                    topOverlayInset: topOverlayInset,
                    bottomInset: pinchBottomInset(metrics: metrics)
                )
                    .padding(.trailing, -metrics.horizontalPadding)
                    .geometryGroup()
                    .opacity(timelineCollapseDim)
            }
            .padding(.top, topOverlayInset)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.bottom, metrics.timelineBottomScrollPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Spec 07 §4d (pulled early): pin the all-day pill row to the scroll
        // FRAME top so the negative leading `contentInset` can hide the 12h
        // band without scrolling the pills off. Frame-relative overlay on the
        // host → outside the scrolled content. The in-scroll all-day band is
        // suppressed inside `TimelinePagerView` (`pinsAllDayExternally`), so
        // there is no duplicate row and no duplicate hit area.
        .overlay(alignment: .top) {
            if pinsAllDayRow {
                pinnedAllDayRow(topOverlayInset: topOverlayInset)
                    .padding(.horizontal, metrics.horizontalPadding)
            }
        }
        .onAppear {
            // UIKit path cold-start scroll-to-now (issue #57 bug 2).
            // The earlier polling-from-.task path failed when the
            // proxy's `viewportHeight` (only populated by
            // `scrollViewDidScroll`) was still 0 at the polling tick —
            // the guard `contentSize > targetY + viewportHeight` then
            // raced first-layout in some cold paths and silently
            // bailed (`guard ready else { return }`) so the offset
            // stayed at 0:00 and the user had to manual-scroll.
            //
            // Cleaner mechanism: register a one-shot callback on the
            // proxy. `TimelineScrollHost.ContainerView.layoutSubviews`
            // fires it AFTER the first layout pass that has BOTH
            // `scrollView.bounds.height > 0` AND
            // `scrollView.contentSize.height > 0` — no polling, no
            // viewport-height dependency, no `.task` lifecycle
            // ambiguity. The callback is held while needsScrollToNow
            // is still true; we capture the computation closure
            // pointwise so a topOverlayInset / hourHeight change
            // between install and fire is reflected.
            if needsScrollToNow {
                timelineScrollProxy.setOnFirstLayoutReady { [weak timelineScrollProxy] in
                    guard needsScrollToNow else { return }
                    let hourHeight = calendarState.timelineHourHeight
                    let targetY = currentTimeScrollOffset(
                        topOverlayInset: topOverlayInset,
                        hourHeight: hourHeight
                    )
                    needsScrollToNow = false
                    timelineScrollProxy?.scrollTo(y: targetY, animated: false)
                }
            }
            // Spec 07 §5 S5.1: instantiate the imperative day-layer
            // coordinator the moment the UIScrollView + content host are
            // wired. Required: the coordinator owns the new
            // `DayLayerHostView` subtree directly (no `UIViewRepresentable`
            // cord) and lives inside the scroll view's content view, so it
            // can't be constructed at struct-init time — the scroll view
            // doesn't exist yet. The install callback fires exactly once
            // per `TimelineScrollHost.makeUIView`; the matching uninstall
            // callback below tears the coordinator down on
            // `dismantleUIView` so a tab-switch / range-mode flip / flag
            // flip rebuilds cleanly without leaking a host pinned to a
            // dead scroll view.
            //
            // The setter is keyed off `dayLayerCoordinator` rather than the
            // flag — so even on flag-OFF cold start the registration is
            // armed for a later flag-ON flip without a re-onAppear.
            timelineScrollProxy.setOnScrollViewInstalled { [weak timelineScrollProxy] scrollView, hostContentView in
                _ = timelineScrollProxy  // capture-only; not used inside.
                let coordinator: DayLayerCoordinator
                if let existing = dayLayerCoordinator {
                    coordinator = existing
                } else {
                    coordinator = DayLayerCoordinator(
                        container: hostContentView,
                        scrollView: scrollView,
                        dragState: timelineDragState
                    )
                    dayLayerCoordinator = coordinator
                }
                // Spec 07 §5 S5.6: wire the output delegate before any host
                // is attached so the very first gesture (e.g. tap on cold
                // start) routes through. The page-level handlers are bound
                // here; `TimelinePagerView` binds its two pager-scoped
                // handlers (creation-preview-mapping + horizontal-boundary-
                // page) onto the same adapter from its own `.onAppear`.
                wireDayLayerDelegateAdapter()
                coordinator.setOutputDelegate(dayLayerDelegateAdapter)
                // Spec 07 §5 S5.3: cord-cut. The SwiftUI `buildDayLayerView`
                // returns `Color.clear` when `usesImperativeDayLayerModel`,
                // and the coordinator's host fills the slot. Sized to the
                // hostContentView's bounds with autoresizing flexible (the
                // host content view is the SwiftUI tree's frame, which
                // tracks the scroll's `contentLayoutGuide`). Day-N anchor
                // date is today.
                if usesImperativeDayLayerModel {
                    let today = Calendar.current.startOfDay(for: Date())
                    coordinator.addHost(
                        dayOffset: 0,
                        date: today,
                        frame: hostContentView.bounds
                    )
                }
            }
            timelineScrollProxy.setOnScrollViewUninstalled {
                // Drop the coordinator with the host. The coordinator owns
                // the new `DayLayerHostView` subview that was added inside
                // hostContentView; removeHost detaches it before the
                // scroll view tears down.
                dayLayerCoordinator?.removeHost(dayOffset: 0)
                dayLayerCoordinator = nil
            }
        }
        // Spec 07 §5 S5.3: live A/B for flag flips. The install/uninstall
        // callbacks above fire only on real scroll-view make/dismantle
        // (cold start, tab re-entry, range-mode rebuild). When the flag
        // alone flips mid-session the proxy stays installed; we still
        // need to add/remove the coordinator's host so the imperative
        // path engages. The coordinator already exists (the install
        // callback armed it on cold start) so `addHost` reuses it.
        .onChange(of: usesImperativeDayLayerModel) { _, isImperative in
            guard let coordinator = dayLayerCoordinator else { return }
            if isImperative {
                let today = Calendar.current.startOfDay(for: Date())
                let bounds = timelineScrollProxy.contentSize
                coordinator.addHost(
                    dayOffset: 0,
                    date: today,
                    frame: CGRect(origin: .zero, size: bounds)
                )
            } else {
                coordinator.removeHost(dayOffset: 0)
            }
        }
        .onChange(of: timelineDragState.dragOffset.y) { _, _ in
            refreshAbandonedExtension(topOverlayInset: lastTimelineTopOverlayInset)
        }
        .mask {
            TimelineMaskView(
                top: metrics.topMaskConfig,
                bottom: metrics.bottomMaskConfig
            )
        }
    }

    /// Unified scroll-geometry handler shared by both render paths
    /// (deep-review N5).  SwiftUI's `.onScrollGeometryChange` and
    /// `TimelineScrollHost`'s `onScrollChange` callback both delegate
    /// here — the body is identical and was previously duplicated.
    /// All the nuance gates live here:
    ///  - `updateReminderPanelForScroll`: reminders panel pull-to-reveal
    ///  - 0.5pt viewport-height gate → `applyDynamicPinchMinIfNeeded`
    ///    (rotation / viewport establish; sub-pt deltas would fight
    ///    a live pinch and drive a re-entrant geometry storm)
    ///  - 2pt offsetY gate → `cancelResizeGrace` + `timelineVerticalScrollY`
    ///    write (the @State propagates to TimelinePagerView; sub-2pt
    ///    deltas drove ~60 body invalidations/sec of scroll)
    ///  - `refreshAbandonedExtension` + `collapseTimelineBoundaryExtensionsIfNeeded`
    ///    (boundary-extension dissolve/collapse follows scroll real-time)
    ///  - `headerCapsulesVisible` latched on
    private func handleTimelineUIScrollChange(
        offsetY: CGFloat,
        viewportHeight: CGFloat,
        topOverlayInset: CGFloat,
        metrics: CalendarPageMetrics
    ) {
        updateReminderPanelForScroll(offsetY)
        if abs(viewportHeight - timelineScrollViewportHeight) > 0.5 {
            timelineScrollViewportHeight = viewportHeight
            applyDynamicPinchMinIfNeeded(
                topOverlayInset: topOverlayInset,
                bottomInset: pinchBottomInset(metrics: metrics)
            )
        }
        if abs(offsetY - timelineVerticalScrollY) >= 2 {
            cancelResizeGrace(reason: "timeline.verticalScroll")
            timelineVerticalScrollY = offsetY
        }
        lastTimelineTopOverlayInset = topOverlayInset
        refreshAbandonedExtension(topOverlayInset: topOverlayInset)
        collapseTimelineBoundaryExtensionsIfNeeded(topOverlayInset: topOverlayInset)
        if !headerCapsulesVisible {
            headerCapsulesVisible = true
        }
    }

    /// Compute the vertical content offset that centers the current time on screen.
    func currentTimeScrollOffset(topOverlayInset: CGFloat, hourHeight: CGFloat) -> CGFloat {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let secondsSinceStart = now.timeIntervalSince(startOfDay)
        let hoursFraction = CGFloat(secondsSinceStart / 3600)
        // Spec 07 §2A: in the 48h-constant model 0:00 sits 12h DOWN in content
        // coords (the always-present leading band is above it), so the
        // current-time target shifts down by the same 12h.
        let bandLeadingOffset = usesImperativeDayLayerModel
            ? CGFloat(calendarTimelineMaximumBoundaryExtensionHours) * hourHeight
            : 0
        let rawOffset = topOverlayInset + bandLeadingOffset + hoursFraction * hourHeight
        // Nudge upward so current time lands ~30% from the top of the
        // viewport instead of flush at the top edge.
        let viewportNudge = timelineScrollViewportHeight * 0.3
        return max(0, rawOffset - viewportNudge)
    }

    /// Spec 07 §4d (pulled early): the all-day pill row pinned to the scroll
    /// FRAME top in the 48h-constant single-day model. Renders the SAME pills
    /// as `TimelinePagerView.allDaySection` for the selected day, reusing the
    /// page's caches + tap handler (zero duplicated state). The in-scroll row
    /// is suppressed via `pinsAllDayExternally`, so this is the only all-day
    /// hit area. Offset down by `topOverlayInset` to sit where the in-scroll
    /// row used to.
    @ViewBuilder
    private func pinnedAllDayRow(topOverlayInset: CGFloat) -> some View {
        let offset = calendarState.selectedDayOffset
        let date = calendarDateForSelectedDayOffset(offset, calendar: .current)
        let occurrences = allDayOccurrencesCache[offset] ?? []
        let focusActive = focusedEventID != nil
        VStack(spacing: 2) {
            ForEach(occurrences) { occurrence in
                let color = CalendarLayout.eventColor(for: occurrence.event)
                let isInteractionAllowed = calendarShouldAllowEventInteraction(
                    focusedEventID: focusedEventID,
                    candidateEventID: occurrence.event.id,
                    isFocusContextActive: focusActive
                )
                Button {
                    handleTimelineEventTap(occurrence.event, date)
                } label: {
                    HStack(spacing: 4) {
                        Text(occurrence.event.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .frame(height: timelineAllDayPillHeight - 4)
                    .background(color, in: Capsule())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(isInteractionAllowed)
            }
        }
        .padding(.vertical, timelineAllDaySectionPadding)
        // Frame to the reserved band height (max across the range) so 0:00 sits
        // flush below the reserved gap even when the selected day has fewer
        // all-day events than the range max — mirrors `allDaySection`.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: pinnedAllDayHeight, alignment: .top)
        .padding(.top, topOverlayInset)
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
            boundaryExtensionVisualYOffset: boundaryExtensionVisualYOffset,
            suppressDayColumnHorizontalAnimation: suppressDayColumnHorizontalAnimation,
            useImperativeDayLayerModel: usesImperativeDayLayerModel,
            leadingFadeProgress: timelineLeadingFadeProgress,
            trailingFadeProgress: timelineTrailingFadeProgress,
            isDayOffsetFrozen: calendarState.isDayOffsetFrozen,
            daysCount: timelineDaysCount(for: calendarState.rangeMode),
            mode: .preview,
            showEventText: timelineShowEventText(for: calendarState.rangeMode),
            dayRange: dayRange,
            previewCreation: pendingCreateTimeRange,
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
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
                scrollVerticallyTo(y: newScrollY)
            },
            onFrozenSlotMinutesChange: { frozen in
                // Fires only on pinch begin / end (TimelinePagerView
                // gates this on oldValue != newValue), so the @State
                // write here is also a transition — `timelineScrollUIKit`
                // re-evaluates twice per pinch, not per frame. The
                // UIScrollView path uses this to keep contentH's
                // `effectiveSlot` in lockstep with the SwiftUI tree's
                // (deep-review C2).
                if rangePinchFrozenSlotMinutes != frozen {
                    rangePinchFrozenSlotMinutes = frozen
                }
            },
            boundaryExtensionStateOverride: timelineBoundaryExtensionState,
            dayLayerCoordinator: dayLayerCoordinator,
            dayLayerDelegateAdapter: dayLayerDelegateAdapter
        )
        // Rebuild when range changes to avoid stale TabView pages across layouts.
        .id(rebuildKey)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Timeline Callback Methods (extracted from timelineLayer)

    /// Spec 07 §5 S5.6: bind every page-level handler to the imperative
    /// day-layer's output adapter so the coordinator-routed host callbacks
    /// fan out to the same code paths the SwiftUI representable's closure
    /// arguments used to. Pager-scoped handlers (`onCreationPreviewChanged`,
    /// `onHorizontalBoundaryPageRequest`) belong to `TimelinePagerView`'s
    /// state and are wired separately from its own `.onAppear`. Calling this
    /// repeatedly is safe — every assignment overwrites the previous closure
    /// without leaking observers (`@State` adapter has a stable identity).
    func wireDayLayerDelegateAdapter() {
        dayLayerDelegateAdapter.onEventTap = handleTimelineEventTap
        dayLayerDelegateAdapter.onLongPressBegan = handleTimelineLongPressBegan
        dayLayerDelegateAdapter.onManipulationPromotion = handleTimelineManipulationPromotion
        dayLayerDelegateAdapter.onLongPressResolved = handleTimelineLongPressResolved
        dayLayerDelegateAdapter.onDragEnded = handleTimelineEventDragEnded
        dayLayerDelegateAdapter.onResizeEnded = handleTimelineEventResizeEnded
        dayLayerDelegateAdapter.onCreateEvent = handleTimelineCreateEvent
        dayLayerDelegateAdapter.onNonEventTap = handleTimelineNonEventTap
        dayLayerDelegateAdapter.onVisibleTimelineFrameChange = handleVisibleTimelineFrameChange
    }

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
        // A new long-press starts a fresh edit session — drop any lingering
        // grace from a previous one so the new gesture controls bar visibility.
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
        // Put-back fork: a stack-eligible todo released inside the bottom
        // peek zone unschedules instead of moving. Same zone the peek
        // highlighted (TodoPutBackPeekMetrics — shared geometry), same
        // store write as the detail page. The shared drag state still
        // holds the release point here: the layer controller resets it
        // only after this callback returns.
        let putBackWindowHeight = timelineDragState.dragWindowHeight > 0
            ? timelineDragState.dragWindowHeight
            : calendarKeyWindowHeight()
        if event.canReturnToStack,
           let touch = timelineDragState.currentTouchPointGlobal,
           TodoPutBackPeekMetrics.isInZone(touchY: touch.y, screenHeight: putBackWindowHeight) {
            store.putTodoBackToStack(todoID: event.id)
            // The drag's edit-mode focus points at an event that just left
            // the canvas; nothing downstream clears it (the move path's
            // focus lifecycle assumes the occurrence survives), so every
            // other block would stay focus-dimmed until the next tap.
            clearFocus(reason: "todoPutBack")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            todoPutBackFlash = event
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                if todoPutBackFlash?.id == event.id { todoPutBackFlash = nil }
            }
            return
        }
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
                scrollVerticallyTo(y: currentTimeScrollOffset(topOverlayInset: topOverlayInset, hourHeight: calendarState.timelineHourHeight))
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
                scrollVerticallyTo(y: targetY, animated: true)
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
        guard shouldAllowMidnightShift(
            draggingEventID: timelineDragState.draggingEventID,
            resizeGrace: resizeGraceState,
            liveInterrupt: liveInterruptSession
        ) else {
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
        let allEvents = store.canvasRenderableCalendarEvents
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
        let allEvents = store.canvasRenderableCalendarEvents
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
        let allEvents = store.canvasRenderableCalendarEvents
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
            let allEvents = store.canvasRenderableCalendarEvents
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
            let allEvents = store.canvasRenderableCalendarEvents
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

        // Absorption-on-drop: when a `.todo` ends a drag with its new
        // time overlapping an `.event`'s range, treat the drop as an
        // absorption gesture rather than a pure time-move. Displacement
        // threshold guards against accidental "pick up + drop in
        // place" auto-absorbs — a real drag intent has at least
        // ~10pt of motion in x or y.
        //
        // We still commit the time-move FIRST. Without it, the todo
        // stays at its pre-drag time in the data — so if the user
        // later releases the absorption, the todo re-appears at its
        // original spot, not where the user "moved it to" visually.
        // Commit time, THEN absorb. (For recurring series, falls
        // through to the existing applyRecurringEdit path; absorption
        // is only attempted on the non-recurring side.)
        if event.kind == .todo,
           !event.isRecurringSeries,
           abs(offset.x) > 10 || abs(offset.y) > 10 {
            // Prefer the spatial-hit parent the highlight pointed at
            // during drag (the day renderer writes it to dragState via
            // its drag handler). Falls back to time-only match for code
            // paths that bypass the visual drag.
            let parent: Event? = {
                if let id = timelineDragState.currentDropTargetEventID,
                   let resolved = store.rawCalendarEvents.first(where: { $0.id == id }) {
                    return resolved
                }
                return store.rawCalendarEvents.first { candidate in
                    candidate.kind == .event
                        && candidate.id != event.id
                        && candidate.absorbedIntoEventID == nil
                        && candidate.timeRanges.contains { range in
                            range.start < newRange.end && newRange.start < range.end
                        }
                }
            }()
            if let parent = parent {
                calendarDebugLog(
                    "calendar.handleEventDrag.absorbed",
                    fields: [
                        "todoID": event.id.uuidString,
                        "parentEventID": parent.id.uuidString
                    ]
                )
                // Commit the new time first.
                var updated = event
                let existingRanges = updated.timeRanges.isEmpty ? updated.effectiveTimeRanges : updated.timeRanges
                updated.timeRanges = calendarUpdatedRangesAfterDrop(
                    existingRanges: existingRanges,
                    draggedRange: draggedRange,
                    droppedRange: newRange,
                    occurrenceID: occurrenceID
                )
                store.updateCalendarEvent(updated)
                // Then absorb.
                store.absorbTodoIntoEvent(todoID: event.id, parentEventID: parent.id)
                return
            }
        }

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
        // Pseudo-vertical follow (#55): when a single-day extended-view drag
        // commits the event onto a NEW host day (its start crossed midnight),
        // re-anchor the view to the new day in lockstep with mirroring the
        // extension state — so the user follows the event vertically without
        // the canvas appearing to move. Reuses the same visualOffset rationale
        // as the OPEN animator: with leading=12 on `today`, visibleStart is
        // `yesterday 12:00`; on `yesterday` with trailing=12, visibleStart is
        // `yesterday 00:00`. Both windows cover the same content slice when
        // scrollY shifts by 12h*hourHeight. Wrap all writes in
        // `disablesAnimations` so the horizontal day-snap and the scroll
        // adjustment land in the same render pass — no horizontal slide, no
        // vertical jump.
        // Finger-based day-switch: decide by where the FINGER is at release, not
        // the event head — so an event whose head crossed midnight but whose
        // finger is still on the current day does NOT switch. Verified on-device
        // (real touchY is valid at commit; the earlier synthetic-drag failure was
        // a CGEvent test artifact where touchY read 0).
        followEventAcrossMidnightIfNeeded(
            committedRange: newRange,
            fingerDay: calendarCurrentMoveDragFingerDay()
        )
        restartResizeGrace(
            for: committedOccurrenceContext(
                event: updated,
                preferredRange: newRange,
                occurrenceDate: newRange.start
            ),
            trigger: .moveCommit
        )
    }

    /// The startOfDay under the dragging FINGER right now, or nil if the
    /// move-drag touch state isn't resolvable. The cross-midnight follow uses
    /// this (not the event head) to decide the day-switch, so a long event
    /// whose top crossed midnight but whose finger is still on the current-day
    /// portion does NOT switch. Valid at move-commit time — `onDragTerminal`
    /// (which clears the shared drag state) fires AFTER `onDragEnded`.
    /// The boundary-extension hours the finger Y→time mapping must use. On the
    /// imperative path the timeline is RENDERED with the constant 12/12
    /// coordinate window (0:00 at headerHeight+12h), so a finger's screen Y maps
    /// to time via 12/12 — NOT the real band state (which would put 0:00 12h too
    /// high and skew the finger time ~12h late, picking the WRONG day for the
    /// cross-midnight switch). Off-imperative, the render uses the real band.
    private var fingerMappingBandState: TimelineBoundaryExtensionState {
        guard usesImperativeDayLayerModel else { return timelineBoundaryExtensionState }
        return TimelineBoundaryExtensionState(
            leadingHours: calendarTimelineMaximumBoundaryExtensionHours,
            trailingHours: calendarTimelineMaximumBoundaryExtensionHours,
            source: timelineBoundaryExtensionState.source,
            anchorDayOffset: timelineBoundaryExtensionState.anchorDayOffset
        )
    }

    private func calendarCurrentMoveDragFingerDay() -> Date? {
        calendarResolvedTouchDrivenHeaderDisplayDate(
            draggingEventID: timelineDragState.draggingEventID,
            dragMode: timelineDragState.dragMode,
            dragTouchPointGlobal: timelineDragState.currentTouchPointGlobal,
            timelineFrameGlobal: timelineVisibleDayFrameGlobal,
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode,
            headerHeight: timelineHeaderHeight,
            hourHeight: calendarState.timelineHourHeight,
            boundaryExtensionState: fingerMappingBandState,
            // Spec 07 Phase 1: imperative path — finger maps raw past the
            // ±12h substrate so day-switch sees the finger's true day.
            clampToExtension: !usesImperativeDayLayerModel
        )
    }

    /// Re-anchor `selectedDayOffset` + mirror extension when a drag-commit
    /// moves the event's start onto a different day. See #55 design notes.
    private func followEventAcrossMidnightIfNeeded(
        committedRange: Event.TimeRange,
        fingerDay: Date? = nil
    ) {
        // Spec 07: the cross-midnight "view follows event" day-switch IS wanted
        // on the imperative path too — only the growing-contentSize machinery
        // below (mirroredExtension=24, crossDayRebounceAnimator scroll,
        // applyTimelineBoundaryExtensionState(.none) co-commit) fights the
        // constant-48h substrate. So both paths share the day-resolution guards;
        // the imperative path then forks to a contentInset-substrate day-switch
        // (below, after the dayDelta guard) instead of the mirror/animator.
        guard calendarState.rangeMode == .day else {
            return
        }
        guard timelineBoundaryExtensionState.hasAnyExtension else {
            return
        }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let originalDayOffset = calendarState.selectedDayOffset
        // Finger-based decision (move-commit passes the finger day); falls back
        // to the event head when nil (resize, or unresolvable touch state).
        let anchorDay = fingerDay ?? calendar.startOfDay(for: committedRange.start)
        guard let newHostDayOffset = calendar.dateComponents([.day], from: todayStart, to: anchorDay).day else {
            return
        }
        guard newHostDayOffset != originalDayOffset else {
            return
        }
        let dayDelta = newHostDayOffset - originalDayOffset
        // Only handle adjacent-day jumps; larger jumps shouldn't be reachable
        // from a single drag with ≤12h boundary extension, but if they ever
        // are, fall back to the existing collapse-and-snap behavior.
        guard abs(dayDelta) == 1 else {
            return
        }

        // Spec 07 imperative fork: the canvas is a CONSTANT 48h (no mirror /
        // co-commit needed). Re-anchor the day and let the band inset close on
        // the new day's substrate. The event is already committed by the caller
        // and now lives in-bounds on `newHostDayOffset`.
        if usesImperativeDayLayerModel {
            pendingFollowEventDayOverride = newHostDayOffset
            crossDayFollowEventAt = Date()   // arm the settle-window guard first
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            suppressDayColumnHorizontalAnimation = true
            // Seamless day-swap (NO teleport): the canvas is a constant 48h, so
            // swapping the selected day re-anchors 0:00 — the SAME content (the
            // band the event was just dropped into) shifts by one whole day
            // (`baseVisibleHours`). Compensate the scroll offset by exactly that
            // so the event stays under the user and the day flows beneath it,
            // rather than jumping to its new in-day slot. (Co-commit-free: only
            // contentOffset moves, contentSize is constant.)
            let hourHeight = calendarState.timelineHourHeight
            let dayShift = CGFloat(dayDelta) * CGFloat(calendarTimelineBaseVisibleHours) * hourHeight
            let targetOffsetY = max(0, timelineScrollProxy.currentOffsetY - dayShift)
            // NOTE: transient-compensation + post-swap spring (Task 1) were
            // tried here and broke the swap visually — reverted to the approved
            // ac79d5b offset-compensated swap. Re-attempt smoothness once the
            // real-device touch/offset values are confirmed via the logs.
            var swapTx = Transaction(); swapTx.disablesAnimations = true
            withTransaction(swapTx) {
                calendarState.selectedDayOffset = newHostDayOffset
                scrollVerticallyTo(y: targetOffsetY)
            }
            // Close the band on the NEW day: the event is in-bounds there, so the
            // extension state goes .none and the inset springs back to 0. Reuses
            // the imperative release-close (animated inset + fade) — replaces the
            // entire crossDayRebounceAnimator + co-commit block below.
            handleImperativeBandStateChange(.none)
            // Settle-window cleanup. Keep >= the 0.5s band-close spring so the
            // header override doesn't clear (and flicker back) mid-close.
            DispatchQueue.main.asyncAfter(deadline: .now() + crossDayFollowSettleWindow) { [self] in
                suppressDayColumnHorizontalAnimation = false
                pendingFollowEventDayOverride = nil
            }
            return
        }

        // Set the header day-override immediately so the brief drag-end →
        // boundary-tick window doesn't flash the header back to the
        // original day. The header reads this in preference to
        // `selectedDayOffset` until the animator clears it.
        pendingFollowEventDayOverride = newHostDayOffset
        let hourHeight = calendarState.timelineHourHeight
        // FULL-DAY mirror (24h, not the 12h drag-extension max): the post-swap
        // canvas must contain *everything* the pre-swap canvas showed, or the
        // swap visibly discards content. With a 12h mirror the shared window
        // is only 24h tall — at small hourHeight the viewport is TALLER than
        // that, so up to 12h of the old day vanished in one frame (the
        // "previous day's slot disappears instantly" bug). With a 24h mirror
        // the pre canvas (36h) is a strict subset of the post canvas (48h):
        // nothing is discarded at any zoom. The destination day scrolls in
        // solid; only the old day (the mirrored band) fades out.
        let mirroredHours = calendarTimelineBaseVisibleHours
        let mirroredExtension: TimelineBoundaryExtensionState
        let scrollDelta: CGFloat
        if dayDelta < 0 {
            // Was on today + leading 12h (yesterday's late hours above).
            // After the jump, anchor=yesterday and ALL of today mirrors to
            // trailing=24. Canvas start moves from (today − leading) to
            // yesterday 00:00 → same instant sits `leading*hh` lower.
            mirroredExtension = TimelineBoundaryExtensionState(
                leadingHours: 0,
                trailingHours: mirroredHours,
                source: nil,
                anchorDayOffset: newHostDayOffset
            )
            scrollDelta = CGFloat(timelineBoundaryExtensionState.leadingHours) * hourHeight
        } else {
            // Was on today + trailing 12h (tomorrow's first hours below);
            // after jumping to tomorrow, ALL of today mirrors to leading=24.
            // Canvas start is today 00:00 in BOTH coordinate systems →
            // the swap is a pure rename, zero scroll delta.
            mirroredExtension = TimelineBoundaryExtensionState(
                leadingHours: mirroredHours,
                trailingHours: 0,
                source: nil,
                anchorDayOffset: newHostDayOffset
            )
            scrollDelta = 0
        }
        let targetScrollY = max(0, timelineVerticalScrollY + scrollDelta)
        calendarDebugLog(
            "calendar.followEventAcrossMidnight",
            fields: [
                "originalDayOffset": "\(originalDayOffset)",
                "newHostDayOffset": "\(newHostDayOffset)",
                "dayDelta": "\(dayDelta)",
                "scrollPre": String(format: "%.2f", timelineVerticalScrollY),
                "scrollDelta": String(format: "%.2f", scrollDelta),
                "scrollTarget": String(format: "%.2f", targetScrollY)
            ]
        )
        // IMMEDIATE atomic re-anchor + single-spring settle (full-day-mirror
        // revision). Because the post-swap canvas (48h) strictly contains the
        // pre-swap canvas (36h), ANY pre-swap scrollY maps to a valid
        // post-swap scrollY = preStart + scrollDelta showing identical
        // content — so the swap fires on the first animator tick, with no
        // pre-phase and no content discarded at any zoom level. Validity:
        //   UP   (dayDelta<0): swapPost = K + 12h*hh ≤ postMaxScroll because
        //        preMaxScroll + 12h*hh = postMaxScroll exactly.
        //   DOWN (dayDelta>0): swapPost = K (pure rename) < postMaxScroll.
        //
        // Then ONE spring continues the autoscroll's vertical momentum from
        // swapPost to the settle position (new day's 00:00 just below the
        // floating header). In lockstep with that scroll, the mirrored band
        // (the ENTIRE old day) fades out front-loaded so it's nearly gone by
        // the time it slides off the edge. The destination day stays solid
        // and just scrolls in. At completion the band is invisible, so
        // `applyTimelineBoundaryExtensionState(.none)` (which compensates
        // scrollY for the leading-collapse case) closes silently.
        //
        //   UP:   settlePost = 0           (old day = trailing 24h band)
        //   DOWN: settlePost = 24h*hh      (old day = leading 24h band)
        // (#55 follow-event-across-midnight)
        let preStart = timelineVerticalScrollY
        let swapPost: CGFloat = preStart + scrollDelta
        let settlePost: CGFloat = dayDelta < 0 ? 0 : CGFloat(mirroredHours) * hourHeight
        crossDayFollowEventAt = Date()
        let prepareHaptic = UINotificationFeedbackGenerator()
        prepareHaptic.prepare()
        prepareHaptic.notificationOccurred(.success)
        crossDayRebounceAnimator?.cancel()
        // A canceled predecessor never runs its onComplete, so its fade
        // could be stuck mid-ramp — the new run would start with a
        // pre-faded band. Reset before the new animator.
        if timelineLeadingFadeProgress != 0 || timelineTrailingFadeProgress != 0 {
            var fadeResetTx = Transaction()
            fadeResetTx.disablesAnimations = true
            withTransaction(fadeResetTx) {
                timelineLeadingFadeProgress = 0
                timelineTrailingFadeProgress = 0
            }
        }
        // Pre-set the horizontal-swipe suppression so the upcoming
        // selectedDayOffset write doesn't trigger the day-column
        // horizontal slide animation. Cleared at onComplete.
        suppressDayColumnHorizontalAnimation = true
        // Atomic swap NOW — synchronously, with the compensating scrollTo
        // in the SAME transaction, so the first frame after the state
        // change renders the new canvas at the exact equivalence offset.
        // (Doing this inside the animator's first tick rendered a frame
        // with the new canvas at the old offset — the spring had already
        // advanced ~70ms — a visible content jump in the UP direction.)
        var swapTx = Transaction()
        swapTx.disablesAnimations = true
        withTransaction(swapTx) {
            calendarState.selectedDayOffset = newHostDayOffset
            timelineBoundaryExtensionState = mirroredExtension
            timelineRawBoundaryExtensionState = .none
            scrollVerticallyTo(y: swapPost)
        }
        crossDayFollowEventAt = Date()
        // CalendarRebounceAnimator's inverted curve gives a 0→1 progress
        // with a single elastic overshoot — the "autoscroll kept going and
        // settled" feel for the swapPost → settlePost scroll.
        crossDayRebounceAnimator = CalendarRebounceAnimator(
            duration: 1.1,
            onTick: { value in
                // CalendarRebounceAnimator emits a "release from stretch"
                // curve that goes 1 → 0 with overshoot past 0. Invert to
                // get a "progress" curve 0 → 1 with overshoot past 1.
                let progress = 1 - value
                let frac = min(1, max(0, progress))
                let y = swapPost + (settlePost - swapPost) * progress
                // Old day (the mirrored band) fades out FRONT-LOADED
                // (`1-(1-frac)²`, ease-out): it dissolves smoothly while
                // it's still large in the viewport, so it's nearly gone by
                // the time it scrolls off the edge — a gradual "慢慢消失"
                // instead of a snap at the end. The destination day is NOT
                // touched (it stays solid and just scrolls in). Monotonic
                // ratchet so the spring's overshoot past 1 can't flash the
                // band back. (#55 follow-on)
                let inv = 1 - frac
                // The mirror is a single side; drive both fades together (the
                // absent side is ignored by the mask). Monotonic ratchet.
                let fade = max(timelineLeadingFadeProgress, 1 - inv * inv)
                if fade != timelineLeadingFadeProgress || fade != timelineTrailingFadeProgress {
                    var fadeTx = Transaction()
                    fadeTx.disablesAnimations = true
                    withTransaction(fadeTx) {
                        timelineLeadingFadeProgress = fade
                        timelineTrailingFadeProgress = fade
                    }
                }
                let clampedY = max(0, y)
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    scrollVerticallyTo(y: clampedY)
                }
            },
            onComplete: {
                // The band is already faded to ~0 by the front-loaded ramp,
                // so collapsing it here removes already-invisible content.
                // Route close through applyTimelineBoundaryExtensionState
                // which compensates scrollY for the leading collapse case.
                var fadeResetTx = Transaction()
                fadeResetTx.disablesAnimations = true
                applyTimelineBoundaryExtensionState(.none)
                withTransaction(fadeResetTx) {
                    timelineLeadingFadeProgress = 0
                    timelineTrailingFadeProgress = 0
                }
                crossDayRebounceAnimator = nil
                suppressDayColumnHorizontalAnimation = false
                pendingFollowEventDayOverride = nil
            }
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
            // Same cross-midnight follow as the non-recurring resize-top
            // path (#55). Only fires when extension is open + host day
            // actually changed (function-internal guards).
            if dragMode == .resizeTop {
                followEventAcrossMidnightIfNeeded(committedRange: resolvedRange)
            }
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
        // Unify the cross-midnight follow with move: resize-top moves the
        // event's start, which can cross midnight in extended view and
        // change the host day. resize-bottom only moves the end, so the
        // host day is unchanged → no follow needed there. (#55 follow-event
        // unify across drag-move + drag-resize)
        if dragMode == .resizeTop {
            followEventAcrossMidnightIfNeeded(committedRange: newRange)
        }
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
        return store.rawCalendarEvents.compactMap { candidate in
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

    /// Open the reminder panel when the timeline is over-scrolled down past the
    /// top, and collapse it when the timeline is scrolled back up. The state
    /// write is deferred off the scroll-geometry callback: mutating it inline
    /// changes the timeline's top inset, which re-enters layout during the same
    /// update and trips a "modifying state during view update" crash.
    private func updateReminderPanelForScroll(_ scrollY: CGFloat) {
        if !isReminderPanelOpen {
            guard scrollY < -70 else { return }
            DispatchQueue.main.async {
                guard !isReminderPanelOpen else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                    isReminderPanelOpen = true
                }
            }
        } else {
            guard scrollY > 60 else { return }
            DispatchQueue.main.async {
                guard isReminderPanelOpen else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                    isReminderPanelOpen = false
                }
            }
        }
    }

    /// Turn a reminder into a calendar event: ask the AI to expand the reminder
    /// text into title/type/time/note, then present the create sheet prefilled.
    /// Falls back to a plain title-only prefill when AI is disabled or fails.
    func scheduleReminder(_ reminder: Reminder) {
        guard schedulingReminderID == nil else { return }
        schedulingReminderID = reminder.id

        // Default slot: the next top of the hour, one hour long.
        let calendar = Calendar.current
        let now = Date()
        let nextHour = calendar.nextDate(
            after: now,
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
        let baseRange = Event.TimeRange(start: nextHour, end: nextHour.addingTimeInterval(3600))
        let defaultType = EventTypeTemplateStore().templates.first?.title ?? "Study"

        let trimmedNote = reminder.note.trimmingCharacters(in: .whitespacesAndNewlines)

        func presentFallback() {
            pendingReminderSchedule = ReminderSchedulePrefill(
                timeRange: baseRange,
                title: reminder.title,
                typeTitle: defaultType,
                note: trimmedNote,
                location: "",
                agenticIntake: nil
            )
        }

        guard calendarAgenticCreateEnabled else {
            schedulingReminderID = nil
            presentFallback()
            return
        }

        let rawText = trimmedNote.isEmpty ? reminder.title : "\(reminder.title)\n\(trimmedNote)"

        Task { @MainActor in
            defer { schedulingReminderID = nil }
            do {
                let availableTypes = EventTypeTemplateStore().templates.map(\.title)
                let pendingCreate = PendingEventCreation(
                    date: now,
                    timeRange: baseRange,
                    source: .quickAdd,
                    anchorVisibleDate: now
                )
                let context = AgenticCalendarContext(
                    visibleDate: now,
                    nearbyEventsSummary: ""
                )
                let result = try await AgenticCalendarIntakeService().generateAutofill(
                    rawText: rawText,
                    selectedImages: [],
                    pendingCreate: pendingCreate,
                    calendarContext: context,
                    availableTypes: availableTypes
                )
                let intake = AgenticIntakeRecord(
                    rawText: reminder.title,
                    images: [],
                    source: .quickAdd,
                    providerMetadata: AgenticProviderMetadata(
                        provider: result.providerName,
                        model: result.providerModel,
                        usedVision: result.usedVision
                    ),
                    warnings: result.warnings,
                    createdAt: now,
                    processingPhase: .completed,
                    processingUpdatedAt: now
                )
                pendingReminderSchedule = ReminderSchedulePrefill(
                    timeRange: Event.TimeRange(start: result.startTime, end: result.endTime),
                    title: result.title.isEmpty ? reminder.title : result.title,
                    typeTitle: result.typeTitle.isEmpty ? defaultType : result.typeTitle,
                    note: result.note,
                    location: result.location,
                    agenticIntake: intake
                )
            } catch {
                presentFallback()
            }
        }
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

// MARK: - Spec 07 §5 row S4 — Day-Layer Coordinator Channel Modifiers
//
// S5 channel-coverage verification (spec §5 S5 hard gate).
//
//   Grepped 2026-06-19 against this branch (feat/timeline-imperative-day-layer-s5).
//   Every S4-migrated channel has BOTH the coordinator setter AND the
//   SwiftUI struct-field path wired — flag-OFF still uses the
//   representable, flag-ON uses the coordinator-driven host.
//
//   Channel              Coordinator setter call site         SwiftUI field path
//   ─────────────────    ──────────────────────────────────   ────────────────────────────
//   focus                CPV:5648 (focusedEventID)            TimelineView:2762 (legacy)
//                        CPV:5651 (focusedOccurrenceID)       TimelineView:2763
//   grace                CPV:5663 (resizeGraceState)          TimelineView:2764..2766
//   pinch.hourHeight     CPV:5686 (hourHeight)                TimelineView:2751
//   pinch.frozenSlot     CPV:5689 (frozenSlotMinutes)         TimelineView:2758
//   pinch.isActive       TimelineView:1769 (isRangePinchActive)  TimelineView:2757
//   mode                 CPV:5701 (rangeMode)                 TimelineView:2759 / 2760
//   recentlyAbsorbed     TimelineView:1746 (calayerRAP)       TimelineView:2768
//   creationPreview      TimelineView:1756 (creationPreview)  TimelineView:2761
//   settings.font        TimelineView:1774 (calayerTFSS)      TimelineView:2761 (font)
//   settings.timeBelow   TimelineView:1779 (calayerSTBT)      TimelineView:2762
//   settings.multiType   TimelineView:1784 (calayerMTE)       TimelineView:2755
//   settings.horizon     TimelineView:1789 (nFHD)             TimelineView:2756
//   dragPreviewDayStep   TimelineView:1722/1725 (onAppear+δ)  TimelineView:2760
//   dragState mirror     coordinator init/hostCallbacks       TimelineView:2769
//
// Each channel migration in S4 adds one `.onChange`-bearing modifier to the
// `CalendarPageView` body so the (currently nil) `DayLayerCoordinator` will
// see SwiftUI state changes once S5 instantiates it. Extracted into
// `ViewModifier`s rather than inline `.onChange`s to keep the page body
// type-checker complexity under control — adding 11 `.onChange`s inline
// blows past Swift's type-checking budget for that builder.

private struct CalendarPageS4FocusChannelModifier: ViewModifier {
    let focusedEventID: UUID?
    let focusedOccurrenceID: String?
    let coordinator: DayLayerCoordinator?

    func body(content: Content) -> some View {
        content
            .onChange(of: focusedEventID) { _, newValue in
                coordinator?.setFocus(eventID: newValue, occurrenceID: focusedOccurrenceID)
            }
            .onChange(of: focusedOccurrenceID) { _, newValue in
                coordinator?.setFocus(eventID: focusedEventID, occurrenceID: newValue)
            }
    }
}

private struct CalendarPageS4GraceChannelModifier: ViewModifier {
    let resizeGraceState: CalendarResizeGraceState?
    let coordinator: DayLayerCoordinator?

    func body(content: Content) -> some View {
        content
            .onChange(of: resizeGraceState) { _, newValue in
                coordinator?.setGraceResize(
                    eventID: newValue?.eventID,
                    occurrenceID: newValue?.occurrenceID,
                    opacity: newValue?.handleOpacity ?? 1
                )
            }
    }
}

/// Spec 07 §5 row S4 — pinch channel (3 setters: hourHeight, frozenSlotMinutes,
/// isPinchActive). This modifier covers the two pieces of pinch state owned by
/// `CalendarPageView` (`calendarState.timelineHourHeight` — a @Published on
/// the calendar state — and `rangePinchFrozenSlotMinutes`). The third
/// (isRangePinchActive) lives in `TimelinePagerView` and is wired via an
/// .onChange there.
private struct CalendarPageS4PinchChannelModifier: ViewModifier {
    let hourHeight: CGFloat
    let frozenSlotMinutes: Int?
    let coordinator: DayLayerCoordinator?

    func body(content: Content) -> some View {
        content
            .onChange(of: hourHeight) { _, newValue in
                coordinator?.setHourHeight(newValue)
            }
            .onChange(of: frozenSlotMinutes) { _, newValue in
                coordinator?.setFrozenSlotMinutes(newValue)
            }
    }
}

private struct CalendarPageS4ModeChannelModifier: ViewModifier {
    let rangeMode: RangeMode
    let coordinator: DayLayerCoordinator?

    func body(content: Content) -> some View {
        content
            .onChange(of: rangeMode) { _, newValue in
                coordinator?.setMode(newValue)
            }
    }
}

// MARK: - Date Picker Sheet

private struct DateSelectorSheet: View {
    @Binding var selection: Date
    @Binding var detent: PresentationDetent
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let allDayOccurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    var onConfirm: (Date) -> Void

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

    private var selectionYear: Int {
        Calendar.current.component(.year, from: selection)
    }

    /// Centered on the shown year so repeated jumps keep extending the reach.
    private var yearMenuRange: [Int] {
        Array((selectionYear - 10)...(selectionYear + 10))
    }

    /// Move `selection` to the same month/day in `year`, clamping the day for
    /// shorter months (Feb 29 → Feb 28). The month pager follows via its
    /// `selectedDayOffset` sync.
    private func jumpToYear(_ year: Int) {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: selection)
        components.year = year
        let firstOfMonth = calendar.date(
            from: DateComponents(year: year, month: components.month, day: 1)
        ) ?? selection
        let maxDay = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
        components.day = min(components.day ?? 1, maxDay)
        selection = calendar.date(from: components) ?? selection
    }

    var body: some View {
        Group {
            if detent == .large {
                largeDetentContent
            } else {
                // Custom compact picker: the system graphical DatePicker's
                // header (leading title, trailing chevrons) can't be
                // restyled, and the design wants a centered larger title
                // with the chevrons in the corners. Tapping a day confirms
                // directly.
                CompactMonthPickerView(
                    selection: $selection,
                    onConfirm: onConfirm
                )
                .padding(.horizontal, 16)
                .padding(.top, 26)
                .padding(.bottom, 20)
                .frame(maxHeight: .infinity, alignment: .top)
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
                    // Year jump: a menu picker (was a plain dismiss button —
                    // tapping the year closed the whole sheet with no way to
                    // actually change the year).
                    Menu {
                        Picker("", selection: Binding(
                            get: { selectionYear },
                            set: { jumpToYear($0) }
                        )) {
                            ForEach(yearMenuRange, id: \.self) { year in
                                Text(verbatim: String(year)).tag(year)
                            }
                        }
                    } label: {
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

/// Medium-detent month picker with a centered title and corner chevrons —
/// replaces the system graphical DatePicker whose header layout is fixed.
/// Tapping a day calls `onConfirm` immediately.
private struct CompactMonthPickerView: View {
    @Binding var selection: Date
    var onConfirm: (Date) -> Void

    @State private var displayedMonth: Date
    /// Tap the centered title to swap the day grid for month/year wheels —
    /// preserves the system graphical picker's tap-to-edit affordance.
    @State private var isShowingMonthYearWheel = false

    private let calendar = Calendar.current

    init(selection: Binding<Date>, onConfirm: @escaping (Date) -> Void) {
        _selection = selection
        self.onConfirm = onConfirm
        _displayedMonth = State(
            initialValue: calendarMonthStartDate(containing: selection.wrappedValue)
        )
    }

    private var localizedMonthYearTemplate: String {
        DateFormatter.dateFormat(
            fromTemplate: "yyyyMMMM", options: 0, locale: AppLanguage.current.locale
        ) ?? "MMMM yyyy"
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = localizedMonthYearTemplate
        return formatter.string(from: displayedMonth)
    }

    /// Wheel order follows the locale's natural date order ("2026年7月" puts
    /// the year wheel first; "July 2026" the month wheel first).
    private var yearWheelLeadsMonth: Bool {
        let format = localizedMonthYearTemplate
        guard let yearIndex = format.firstIndex(of: "y"),
              let monthIndex = format.firstIndex(of: "M") else { return false }
        return yearIndex < monthIndex
    }

    private var displayedMonthComponent: Binding<Int> {
        Binding(
            get: { calendar.component(.month, from: displayedMonth) },
            set: { setDisplayedMonth(month: $0, year: calendar.component(.year, from: displayedMonth)) }
        )
    }

    private var displayedYearComponent: Binding<Int> {
        Binding(
            get: { calendar.component(.year, from: displayedMonth) },
            set: { setDisplayedMonth(month: calendar.component(.month, from: displayedMonth), year: $0) }
        )
    }

    private func setDisplayedMonth(month: Int, year: Int) {
        displayedMonth = calendar.date(
            from: DateComponents(year: year, month: month, day: 1)
        ) ?? displayedMonth
    }

    /// Weeks of the displayed month; trailing all-outside-month rows trimmed
    /// so short months don't drag an empty sixth row.
    private var weeks: [[Date]] {
        let dates = calendarMonthGridDates(forMonthContaining: displayedMonth, calendar: calendar)
        return stride(from: 0, to: dates.count, by: 7)
            .map { Array(dates[$0..<min($0 + 7, dates.count)]) }
            .filter { row in
                row.contains { calendar.isDate($0, equalTo: displayedMonth, toGranularity: .month) }
            }
    }

    var body: some View {
        // Week rows flex (min 40pt) so the grid spreads over the sheet's
        // height instead of piling at the top and leaving a dead band below.
        VStack(spacing: 8) {
            header
            if isShowingMonthYearWheel {
                monthYearWheel
                Spacer(minLength: 0)
            } else {
                weekdayRow
                ForEach(weeks, id: \.first) { week in
                    HStack(spacing: 0) {
                        ForEach(week, id: \.self) { date in
                            dayCell(date)
                        }
                    }
                    .frame(minHeight: 40, maxHeight: .infinity)
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isShowingMonthYearWheel.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(monthTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .rotationEffect(.degrees(isShowingMonthYearWheel ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isShowingMonthYearWheel {
                HStack {
                    monthChevron("chevron.left", delta: -1)
                    Spacer()
                    monthChevron("chevron.right", delta: 1)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var monthYearWheel: some View {
        let monthSymbols: [String] = {
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.current.locale
            return formatter.standaloneMonthSymbols ?? formatter.monthSymbols ?? []
        }()
        let monthWheel = Picker("", selection: displayedMonthComponent) {
            ForEach(1...12, id: \.self) { month in
                Text(monthSymbols.indices.contains(month - 1) ? monthSymbols[month - 1] : "\(month)")
                    .tag(month)
            }
        }
        .pickerStyle(.wheel)
        let yearWheel = Picker("", selection: displayedYearComponent) {
            ForEach(1970...2100, id: \.self) { year in
                Text(verbatim: String(year)).tag(year)
            }
        }
        .pickerStyle(.wheel)

        return HStack(spacing: 0) {
            if yearWheelLeadsMonth {
                yearWheel
                monthWheel
            } else {
                monthWheel
                yearWheel
            }
        }
        .frame(height: 216)
    }

    private func monthChevron(_ systemName: String, delta: Int) -> some View {
        Button {
            displayedMonth = calendar.date(
                byAdding: .month, value: delta, to: displayedMonth
            ) ?? displayedMonth
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(calendarMonthWeekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { entry in
                Text(entry.element.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        // Breathe: on top of the stack's 8pt spacing this gives the weekday
        // band ~16pt of air above and below.
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        if calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month) {
            let isSelected = calendar.isDate(date, inSameDayAs: selection)
            let isToday = calendar.isDateInToday(date)
            Button {
                selection = date
                onConfirm(date)
            } label: {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .white : (isToday ? Color.accentColor : .primary))
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(isSelected ? Color.accentColor : .clear)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// Performance diagnostics available in git history: cd9d9e3

/// Transient hint shown while a `.todo` is being dragged for absorption.
/// The finger occludes the highlighted target event, so this bubble floats
/// above the touch point and names the event the todo will merge into.
///
/// Reads the per-frame `@Observable` fields (`currentTouchPointGlobal`,
/// `currentDropTargetEventID`) inside ITS OWN body so only the bubble
/// re-renders each drag tick — the parent page passes `dragState` without
/// reading those fields, keeping per-tick invalidation off the page body.
struct CalendarAbsorbMergeBubble: View {
    let dragState: EventDragState
    @EnvironmentObject private var store: EventStore

    var body: some View {
        if let targetID = dragState.currentDropTargetEventID,
           let touch = dragState.currentTouchPointGlobal,
           let target = store.rawCalendarEvents.first(where: { $0.id == targetID }) {
            let title = target.title.isEmpty ? "Untitled" : target.title
            GeometryReader { proxy in
                let position = absorbBubbleCenter(anchor: touch, containerSize: proxy.size)
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.caption2.weight(.bold))
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: 220)
                .foregroundStyle(.primary)
                .background {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                        }
                }
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
                .position(x: position.x, y: position.y)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// Center the bubble horizontally on the finger and lift it above so it
    /// clears the fingertip. Clamp to screen; flip below if too near the top.
    private func absorbBubbleCenter(anchor: CGPoint, containerSize: CGSize) -> CGPoint {
        let margin: CGFloat = 12
        let liftAboveFinger: CGFloat = 56
        let halfWidth: CGFloat = 110
        var x = anchor.x
        var y = anchor.y - liftAboveFinger
        x = max(margin + halfWidth, min(x, containerSize.width - margin - halfWidth))
        if y < margin + 20 {
            y = anchor.y + liftAboveFinger
        }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Composer draft rescue banner

private extension CalendarPageView {
    func refreshComposerDraftBanner() {
        withAnimation(.easeOut(duration: 0.25)) {
            composerDraftBanner = CalendarComposerDraftStore.loadFresh()
        }
    }

    @ViewBuilder
    var composerDraftBannerView: some View {
        if let draft = composerDraftBanner {
            HStack(spacing: 12) {
                Button {
                    // Re-resolve at tap time: the banner's cached copy may
                    // have expired while on screen; opening a "resume" sheet
                    // that comes up empty would be worse than no banner.
                    guard let fresh = CalendarComposerDraftStore.loadFresh() else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            composerDraftBanner = nil
                        }
                        return
                    }
                    composerDraftBanner = nil
                    pendingCreateTimeRange = PendingEventCreation(
                        date: fresh.startTime,
                        timeRange: Event.TimeRange(start: fresh.startTime, end: fresh.endTime),
                        source: .quickAdd,
                        anchorVisibleDate: visibleDate,
                        resumesComposerDraft: true
                    )
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L(.composerDraftResume))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(draft.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                Button {
                    CalendarComposerDraftStore.clear()
                    withAnimation(.easeOut(duration: 0.2)) {
                        composerDraftBanner = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L(.composerDraftDiscard))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.bottom, 96)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
