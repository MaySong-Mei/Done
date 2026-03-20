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
    let source: AgenticCreateSource
    let anchorVisibleDate: Date
}

private struct PendingInterruptComposerPresentation: Identifiable {
    let id = UUID()
    let anchorPoint: CGPoint
    let parentEvent: Event
    let occurrence: CalendarEventOccurrenceContext
    let parentRange: Event.TimeRange
    let occupiedRanges: [Event.TimeRange]
}

func calendarInterruptShouldUseAgenticCreate(
    isEnabled: Bool,
    title: String,
    type: String
) -> Bool {
    guard isEnabled else { return false }
    return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func calendarInterruptAgenticRawText(
    title: String,
    type: String
) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = trimmedTitle.isEmpty ? "Interrupt" : trimmedTitle

    guard !trimmedType.isEmpty else {
        return resolvedTitle
    }

    return """
    \(resolvedTitle)
    type use \(trimmedType)
    """
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
    case .day:
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
    case .day:
        return true
    case .threeDay, .week, .month:
        return storedVisibility
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
    case .month:
        return CalendarLegendFormatters.yearOnly.string(
            from: calendarMonthStartDate(containing: center, calendar: calendar)
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
    static let yearOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    static let fullMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"
        return formatter
    }()

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
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @StateObject private var agenticCreateCoordinator = CalendarAgenticCreateCoordinator()

    @State private var occurrencesCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
    @State private var allDayOccurrencesCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
    @State private var dayRange: ClosedRange<Int> = CalendarLayout.defaultDayRange
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
    @State private var timerRefreshCancellable: AnyCancellable?
    @State private var focusedEventID: UUID? = nil
    @State private var focusedOccurrenceID: String? = nil
    @State private var resizeGraceState: CalendarResizeGraceState? = nil
    @State private var resizeGraceOccurrenceContext: CalendarEventOccurrenceContext? = nil
    @State private var resizeGraceFadeTask: Task<Void, Never>? = nil
    @State private var resizeGraceExpiryTask: Task<Void, Never>? = nil
    @State private var isShowingAgent: Bool = false
    @State private var showSearchPlaceholderAlert: Bool = false
    @State private var timelineVerticalScrollY: CGFloat = 0
    @State private var headerCapsulesVisible: Bool = true
    @State private var legendCenteredOffsetContinuous: CGFloat = 0
    @State private var legendIsInteracting: Bool = false
    @State private var hasAppearedOnce: Bool = false
    @State private var needsScrollToNow: Bool = true
    @State private var verticalScrollPosition: ScrollPosition = .init(point: .zero)

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
    private let headerCapsuleHideThreshold: CGFloat = 64
    private let headerCapsuleShowThreshold: CGFloat = 52
    private let floatingMenuActivationDelay: TimeInterval = calendarEventExpressMenuAdditionalHoldDuration()
    private let resizeGraceDuration: TimeInterval = 2.5
    private let resizeGraceFadeDuration: TimeInterval = 0.35

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
            Group {
                if calendarAgenticCreateEnabled {
                    CalendarAgenticCreateView(pendingCreate: pending) { event in
                        handleCreatedEvent(event)
                    }
                    .environmentObject(store)
                    .environmentObject(agenticCreateCoordinator)
                } else {
                    CreateCalendarEventView(
                        timeRange: pending.timeRange,
                        onCreated: { event in
                            handleCreatedEvent(event)
                        }
                    )
                    .environmentObject(store)
                }
            }
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
            if !hasAppearedOnce {
                hasAppearedOnce = true
                calendarState.selectedDayOffset = 0
                timelineVerticalScrollY = 0
                legendCenteredOffsetContinuous = CGFloat(calendarState.selectedDayOffset)
            }
            expandDayRangeToInclude(calendarState.selectedDayOffset)
            rebuildOccurrencesCache()
            updateTimerRefresh()
            headerCapsulesVisible = true
            legendIsInteracting = false
        }
        .onChange(of: store.calendarEvents) { _ in
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
        .onChange(of: focusedEventID) { newValue in
            calendarState.isEventFocused = newValue != nil
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
            if calendarState.rangeMode == .month {
                expandDayRangeForMonthContext(around: newValue)
            } else {
                expandDayRangeIfNeeded(for: newValue)
            }
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
        .onChange(of: calendarState.rangeMode) { newValue in
            if newValue == .month {
                resetFloatingMenuState()
                cancelResizeGrace(reason: "calendar.rangeMode.month")
                clearFocus(reason: "calendar.rangeMode.month")
                headerCapsulesVisible = true
                timelineVerticalScrollY = 0
                expandDayRangeForMonthContext(around: calendarState.selectedDayOffset)
            }
        }
        .onChange(of: dayRange) { _ in
            rebuildOccurrencesCache()
        }
        .onDisappear {
            resetFloatingMenuState()
            pendingInterruptComposer = nil
            cancelResizeGrace(reason: "calendar.page.disappear")
        }
    }
}

private extension CalendarPageView {
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
                                initialJumpTarget: .meta,
                                autoOpenComposer: false
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
                                initialJumpTarget: .log,
                                autoOpenComposer: true
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
        let showsOverlayBackground = calendarState.rangeMode != .day
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
    func monthOverviewContent(metrics: CalendarPageMetrics, topOverlayInset: CGFloat) -> some View {
        MonthOverviewPagerView(
            selectedDayOffset: calendarState.selectedDayOffset,
            occurrencesForOffset: { occurrencesCache[$0] ?? [] },
            allDayOccurrencesForOffset: { allDayOccurrencesCache[$0] ?? [] },
            onSelectDay: { dayOffset in
                clearFocus(reason: "month.selectDay")
                calendarState.selectedDayOffset = dayOffset
                calendarState.rangeMode = .threeDay
            },
            onMonthPageChanged: { deltaMonths in
                handleMonthPageChange(deltaMonths)
            }
        )
        .padding(.top, topOverlayInset)
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.bottom, max(24, metrics.safeAreaBottom + 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    func agenticBannerView(_ banner: CalendarAgenticBannerState) -> some View {
        HStack(spacing: 8) {
            bannerLeadingIcon(banner)

            Text(agenticBannerTitle(banner))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let action = agenticBannerAction(banner) {
                Button(action.title) {
                    action.handler()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                agenticCreateCoordinator.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(agenticBannerStrokeColor(banner).opacity(0.35), lineWidth: 1)
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
        case .moved:
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
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
        case .moved:
            return "事件已移动"
        case .failed:
            return "AI 完善失败，事件已保留"
        }
    }

    func agenticBannerStrokeColor(_ banner: CalendarAgenticBannerState) -> Color {
        switch banner {
        case .analyzing:
            return .accentColor
        case .moved:
            return .blue
        case .failed:
            return .orange
        }
    }

    func agenticBannerAction(_ banner: CalendarAgenticBannerState) -> (title: String, handler: () -> Void)? {
        switch banner {
        case .analyzing:
            return nil
        case .moved(let eventID, _):
            return ("Go", { jumpToCalendarEvent(id: eventID) })
        case .failed(let eventID, _):
            return ("Edit", { openCalendarEventEditor(id: eventID) })
        }
    }

    func jumpToCalendarEvent(id: UUID) {
        guard let event = store.calendarEvents.first(where: { $0.id == id }) else { return }
        cancelResizeGrace(reason: "banner.jumpToEvent")
        handleCreatedEvent(event)
        agenticCreateCoordinator.dismissBanner()
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
        let selectedDate = visibleDate
        let leftCapsuleTitle = calendarLegendTitle(
            selectedDayOffset: calendarState.selectedDayOffset,
            rangeMode: calendarState.rangeMode
        )

        return AppleCalendarHeaderView(
            selectedDate: selectedDate,
            rangeMode: calendarState.rangeMode,
            leftCapsuleTitle: leftCapsuleTitle,
            isCapsulesVisible: isCapsulesVisible,
            isActionCapsuleVisible: isActionCapsulesVisible,
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
                pendingCreateTimeRange = PendingEventCreation(
                    date: range.start,
                    timeRange: range,
                    source: .quickAdd,
                    anchorVisibleDate: visibleDate
                )
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
        .overlay {
            if let banner = agenticCreateCoordinator.banner {
                agenticBannerView(banner)
                    .padding(.horizontal, metrics.horizontalPadding)
                    .transition(.opacity)
                    .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.18), value: agenticCreateCoordinator.banner?.id)
            }
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
            if abs(scrollY - timelineVerticalScrollY) > 0.5 {
                cancelResizeGrace(reason: "timeline.verticalScroll")
            }
            timelineVerticalScrollY = scrollY
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
        // Position in the scroll content = topOverlayInset + time offset
        return topOverlayInset + hoursFraction * hourHeight
    }

    @ViewBuilder
    func timelineLayer(rebuildKey: String) -> some View {
        let timelineHourHeightBinding = Binding<CGFloat>(
            get: { calendarState.timelineHourHeight },
            set: { calendarState.setTimelineHourHeight($0) }
        )

        TimelinePagerView(
            occurrencesForOffset: { occurrencesCache[$0] ?? [] },
            allDayOccurrencesForOffset: { allDayOccurrencesCache[$0] ?? [] },
            selectedDayOffset: $calendarState.selectedDayOffset,
            rangeMode: $calendarState.rangeMode,
            hourHeight: timelineHourHeightBinding,
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
            liveInterruptSession: liveInterruptSession
        )
        // Rebuild when range changes to avoid stale TabView pages across layouts.
        .id(rebuildKey)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            initialJumpTarget: .meta,
            autoOpenComposer: false
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
            headerHeight: 0,
            hourHeight: hourHeight
        )
        let endY = startY + CalendarLayout.eventHeight(
            for: draggedRange,
            on: originalDate,
            minimumHeight: 0,
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
            headerHeight: 0,
            hourHeight: hourHeight,
            snapMinutes: 15
        )
        let newEnd = CalendarLayout.timeFromYOffset(
            yOffset: newEndY,
            on: originalDate,
            headerHeight: 0,
            hourHeight: hourHeight,
            snapMinutes: 15
        )

        // Anchor the fixed edge from the original range to avoid Y→time snap drift
        let newRange: Event.TimeRange
        switch dragMode {
        case .resizeTop:
            let fixedEnd = draggedRange.end
            newRange = Event.TimeRange(start: min(newStart, fixedEnd), end: fixedEnd)
        case .resizeBottom:
            let fixedStart = draggedRange.start
            newRange = Event.TimeRange(start: fixedStart, end: max(newEnd, fixedStart))
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
        pendingCreateTimeRange = PendingEventCreation(
            date: date,
            timeRange: timeRange,
            source: .dragCreate,
            anchorVisibleDate: visibleDate
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
        if let created = createInterruptWithAgenticAutofill(
            parentEvent: parentEvent,
            occurrence: occurrence,
            title: title,
            type: type,
            timeRange: timeRange
        ) {
            return created
        }

        guard let created = store.createInterrupt(
            parentEvent: parentEvent,
            occurrenceDate: occurrence.occurrenceDate,
            title: title,
            type: type,
            timeRange: timeRange
        ) else {
            return nil
        }
        reviewInterruptTypeIfNeeded(event: created, typedType: type)
        return created
    }

    func createInterruptWithAgenticAutofill(
        parentEvent: Event,
        occurrence: CalendarEventOccurrenceContext,
        title: String,
        type: String,
        timeRange: Event.TimeRange
    ) -> Event? {
        guard calendarInterruptShouldUseAgenticCreate(
            isEnabled: calendarAgenticCreateEnabled,
            title: title,
            type: type
        ) else {
            return nil
        }

        let pendingCreate = PendingEventCreation(
            date: timeRange.start,
            timeRange: timeRange,
            source: .dragCreate,
            anchorVisibleDate: visibleDate
        )
        let rawText = calendarInterruptAgenticRawText(title: title, type: type)
        let context = AgenticCalendarContext(
            visibleDate: pendingCreate.anchorVisibleDate,
            nearbyEventsSummary: buildInterruptNearbyEventsSummary(
                anchorVisibleDate: pendingCreate.anchorVisibleDate
            )
        )
        let placeholder = agenticCreateCoordinator.submitOptimisticCreate(
            rawText: rawText,
            selectedImages: [],
            pendingCreate: pendingCreate,
            calendarContext: context,
            availableTypes: interruptAvailableTypes(),
            uiWarnings: [],
            agentRuntime: agentRuntime,
            store: store
        )

        guard store.attachInterrupt(
            to: placeholder.id,
            parentEvent: parentEvent,
            occurrenceDate: occurrence.occurrenceDate,
            createdAt: timeRange.start,
            seedTypeTitle: type
        ) else {
            store.deleteCalendarEvent(placeholder)
            return nil
        }

        return store.findCalendarEvent(id: placeholder.id) ?? placeholder
    }

    func interruptAvailableTypes() -> [String] {
        EventTypeTemplateStore().templates.map(\.title)
    }

    func buildInterruptNearbyEventsSummary(
        anchorVisibleDate: Date
    ) -> String {
        let calendar = Calendar.current
        let anchorDay = calendar.startOfDay(for: anchorVisibleDate)
        let start = calendar.date(byAdding: .day, value: -1, to: anchorDay) ?? anchorDay
        let end = calendar.date(byAdding: .day, value: 2, to: anchorDay) ?? anchorDay

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        return store.calendarEvents
            .compactMap { event -> String? in
                guard let range = event.effectiveTimeRanges.first else { return nil }
                guard range.end > start && range.start < end else { return nil }
                return "- \(event.title): \(formatter.string(from: range.start)) → \(formatter.string(from: range.end)) [\(event.type)]"
            }
            .prefix(12)
            .joined(separator: "\n")
    }

    func handleCreatedEvent(_ event: Event) {
        guard let preferredRange = event.effectiveTimeRanges.first else { return }
        cancelResizeGrace(reason: "calendar.create.completed")
        let offset = dayOffset(for: preferredRange.start)
        expandDayRangeToInclude(offset)
        calendarState.selectedDayOffset = offset
        let occurrenceID = calendarResolvedFocusedOccurrenceID(
            event: event,
            preferredRange: preferredRange
        )
        setFocus(
            event: event,
            occurrenceID: occurrenceID,
            reason: "calendar.create.completed"
        )
    }

    func reviewInterruptTypeIfNeeded(event: Event, typedType: String) {
        let trimmedType = typedType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedType.isEmpty else { return }
        let context = AgentDecisionContext(
            domain: .calendar,
            operationID: UUID(),
            sourceScreen: "CalendarInterruptComposer",
            conversationID: nil,
            relatedEventIDs: [event.id],
            payloadSummary: "Review explicit interrupt event type",
            metadata: [
                "candidateType": trimmedType,
                "eventKind": "calendar",
                "source": "interrupt"
            ]
        )
        Task { @MainActor in
            await agentRuntime.operationCenter.maybeHandleMissingEventTypeTemplate(
                for: event.id,
                isCalendarEvent: true,
                proposedType: trimmedType,
                store: store,
                context: context
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
