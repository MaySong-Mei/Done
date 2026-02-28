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

func calendarShouldRestoreFocusAfterQuickMenuDragResume(
    didMove: Bool,
    quickMenuWasPresented: Bool,
    hasDeferredGraceOccurrence: Bool
) -> Bool {
    didMove && (quickMenuWasPresented || hasDeferredGraceOccurrence)
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
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @StateObject private var agenticCreateCoordinator = CalendarAgenticCreateCoordinator()

    @State private var occurrencesCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
    @State private var allDayOccurrencesCache: [Int: [CalendarLayout.EventOccurrence]] = [:]
    @State private var dayRange: ClosedRange<Int> = CalendarLayout.defaultDayRange
    @State private var selectedEventDetailRoute: CalendarEventDetailRoute? = nil
    @State private var selectedEventChatOccurrence: CalendarEventOccurrenceContext? = nil
    @State private var quickActionMenuState: CalendarQuickActionMenuState? = nil
    @State private var pendingQuickDeleteOccurrence: CalendarEventOccurrenceContext? = nil
    @State private var pendingQuickDeleteScope: Event.RecurrenceEditScope? = nil
    @State private var showQuickDeleteRecurrenceScopeDialog: Bool = false
    @State private var showQuickDeleteConfirmation: Bool = false
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
    @State private var resizeGraceState: CalendarResizeGraceState? = nil
    @State private var resizeGraceOccurrenceContext: CalendarEventOccurrenceContext? = nil
    @State private var resizeGraceFadeTask: Task<Void, Never>? = nil
    @State private var resizeGraceExpiryTask: Task<Void, Never>? = nil
    @State private var deferredResizeGraceAfterQuickMenu: CalendarEventOccurrenceContext? = nil
    @State private var isShowingAgent: Bool = false
    @State private var showSearchPlaceholderAlert: Bool = false
    @State private var timelineVerticalScrollY: CGFloat = 0
    @State private var headerCapsulesVisible: Bool = true
    @State private var legendCenteredOffsetContinuous: CGFloat = 0
    @State private var legendIsInteracting: Bool = false

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
            let baseTopOverlayInset = calendarTopOverlayInset(
                safeAreaTop: metrics.safeAreaTop,
                isCapsuleVisible: headerCapsulesVisible,
                legendBandHeight: topOverlayLegendBandHeight,
                overlayGap: topOverlayGap,
                capsuleExpandedHeight: topOverlayCapsuleExpandedHeight
            )
            let topOverlayInset = baseTopOverlayInset

            ZStack(alignment: .top) {
                timelineScroll(
                    metrics: metrics,
                    topOverlayInset: topOverlayInset
                )
                .animation(.spring(duration: 0.35, bounce: 0.15), value: calendarState.rangeMode)

                topOverlay(metrics: metrics)

                if let quickActionMenuState {
                    quickActionMenuOverlay(quickActionMenuState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .confirmationDialog(
            "Delete Recurring Event",
            isPresented: $showQuickDeleteRecurrenceScopeDialog,
            titleVisibility: .visible
        ) {
            Button("This Event") {
                pendingQuickDeleteScope = .single
                showQuickDeleteConfirmation = true
            }
            Button("This & Future Events") {
                pendingQuickDeleteScope = .following
                showQuickDeleteConfirmation = true
            }
            Button("All Events") {
                pendingQuickDeleteScope = .all
                showQuickDeleteConfirmation = true
            }
            Button("Cancel", role: .cancel) {
                clearQuickDeleteState()
            }
        }
        .alert("Delete Event", isPresented: $showQuickDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                performQuickDelete()
            }
        } message: {
            Text(quickDeleteConfirmationMessage)
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
            calendarState.selectedDayOffset = 0
            expandDayRangeToInclude(calendarState.selectedDayOffset)
            rebuildOccurrencesCache()
            updateTimerRefresh()
            timelineVerticalScrollY = 0
            headerCapsulesVisible = true
            legendCenteredOffsetContinuous = CGFloat(calendarState.selectedDayOffset)
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
        .onDisappear {
            cancelResizeGrace(reason: "calendar.page.disappear")
        }
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

    func agenticBannerSubtitle(_ banner: CalendarAgenticBannerState) -> String? {
        switch banner {
        case .analyzing:
            return nil
        case .moved(_, let destination):
            return "已移动到 \(agenticBannerDateTimeString(destination))"
        case .failed(_, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(90))
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

    func agenticBannerDateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
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

    func dismissQuickActionMenu(reason: CalendarQuickActionDismissReason = .programmatic) {
        let deferredOccurrence = deferredResizeGraceAfterQuickMenu
        withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16)) {
            quickActionMenuState = nil
        }

        switch reason {
        case .passiveDismiss:
            deferredResizeGraceAfterQuickMenu = nil
            if let deferredOccurrence {
                beginResizeGrace(for: deferredOccurrence, trigger: .quickMenuDismiss)
            }
        case .actionOpenDetail, .actionChat, .actionDelete, .dragResume, .programmatic:
            deferredResizeGraceAfterQuickMenu = nil
        }
    }

    func quickActionMenuOverlay(_ state: CalendarQuickActionMenuState) -> some View {
        let event = calendarResolvedEventForOccurrenceContext(state.occurrence, in: store.calendarEvents)
        return CalendarEventQuickActionMenuView(
            state: state,
            eventTitle: event?.title ?? "Event",
            onLog: {
                dismissQuickActionMenu(reason: .actionOpenDetail)
                openDetailFromQuickAction(state.occurrence, target: .log, autoOpenComposer: true, source: .quickActionLog)
            },
            onRate: {
                dismissQuickActionMenu(reason: .actionOpenDetail)
                openDetailFromQuickAction(state.occurrence, target: .selfEval, autoOpenComposer: true, source: .quickActionRate)
            },
            onChat: {
                var occurrence = state.occurrence
                occurrence.source = .quickActionChat
                cancelResizeGrace(reason: "quickAction.chat")
                dismissQuickActionMenu(reason: .actionChat)
                clearFocus(reason: "quickAction.chat")
                selectedEventChatOccurrence = occurrence
            },
            onDelete: {
                cancelResizeGrace(reason: "quickAction.delete")
                dismissQuickActionMenu(reason: .actionDelete)
                beginQuickDelete(for: state.occurrence)
            },
            onDismiss: {
                dismissQuickActionMenu(reason: .passiveDismiss)
            }
        )
        .transition(
            accessibilityReduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.98))
        )
    }

    func openDetailFromQuickAction(
        _ occurrence: CalendarEventOccurrenceContext,
        target: CalendarEventDetailJumpTarget,
        autoOpenComposer: Bool,
        source: CalendarEventOccurrenceContext.Source
    ) {
        var updated = occurrence
        updated.source = source
        cancelResizeGrace(reason: "quickAction.openDetail")
        clearFocus(reason: "quickAction.openDetail")
        selectedEventDetailRoute = CalendarEventDetailRoute(
            occurrence: updated,
            initialJumpTarget: target,
            autoOpenComposer: autoOpenComposer
        )
    }

    func beginQuickDelete(for occurrence: CalendarEventOccurrenceContext) {
        cancelResizeGrace(reason: "quickDelete.begin")
        clearFocus(reason: "quickDelete.begin")
        pendingQuickDeleteOccurrence = occurrence
        pendingQuickDeleteScope = nil

        guard let event = calendarResolvedEventForOccurrenceContext(occurrence, in: store.calendarEvents) else {
            clearQuickDeleteState()
            return
        }

        if event.isRecurringSeries {
            showQuickDeleteRecurrenceScopeDialog = true
        } else {
            showQuickDeleteConfirmation = true
        }
    }

    var quickDeleteConfirmationMessage: String {
        guard let occurrence = pendingQuickDeleteOccurrence,
              let event = calendarResolvedEventForOccurrenceContext(occurrence, in: store.calendarEvents)
        else {
            return "This event will be permanently deleted."
        }

        guard event.isRecurringSeries else {
            return "This event will be permanently deleted."
        }

        switch pendingQuickDeleteScope ?? .all {
        case .single:
            return "This occurrence will be deleted."
        case .following:
            return "This and future occurrences will be deleted."
        case .all:
            return "All events in this series will be deleted."
        }
    }

    func performQuickDelete() {
        defer { clearQuickDeleteState() }
        guard let occurrence = pendingQuickDeleteOccurrence,
              let event = calendarResolvedEventForOccurrenceContext(occurrence, in: store.calendarEvents)
        else { return }

        cancelResizeGrace(reason: "quickDelete.perform")
        if event.isRecurringSeries {
            store.deleteRecurringCalendarEvent(
                seriesEvent: event,
                occurrenceDate: occurrence.occurrenceDate,
                scope: pendingQuickDeleteScope ?? .all
            )
        } else {
            store.deleteCalendarEvent(event)
        }
    }

    func clearQuickDeleteState() {
        pendingQuickDeleteOccurrence = nil
        pendingQuickDeleteScope = nil
        showQuickDeleteRecurrenceScopeDialog = false
        showQuickDeleteConfirmation = false
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

    func effectiveResizeGraceState(
        for eventID: UUID,
        occurrenceID: String?
    ) -> CalendarResizeGraceState? {
        guard let resizeGraceState else { return nil }
        guard resizeGraceState.eventID == eventID else { return nil }
        if let occurrenceID {
            return resizeGraceState.occurrenceID == occurrenceID ? resizeGraceState : nil
        }
        return resizeGraceState.occurrenceID == nil ? resizeGraceState : nil
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
            // Match TimelineContainerView layout exactly:
            // Timeline gets (screenWidth - horizontalPadding) due to trailing negative padding,
            // then subtracts labelWidth + timelineEdgePadding*2.
            let labelWidth: CGFloat = 32
            let timelineEdgePadding: CGFloat = 6
            let daySpacing: CGFloat = 0
            let daysCount = visibleCount
            let dayAreaWidth = max(0, proxy.size.width - metrics.horizontalPadding - labelWidth - timelineEdgePadding * 2)
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
            graceResizeEventID: resizeGraceState?.eventID,
            graceResizeOccurrenceID: resizeGraceState?.occurrenceID,
            graceResizeHandleOpacity: resizeGraceState?.handleOpacity ?? 1,
            onEventTap: { event, date in
                cancelResizeGrace(reason: "timeline.tap")
                dismissQuickActionMenu(reason: .actionOpenDetail)
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
            },
            onEventLongPressBegan: { event, occurrenceID, actionDate, dragMode in
                cancelResizeGrace(reason: "timeline.longPressBegan")
                dismissQuickActionMenu(reason: .programmatic)
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
            onEventLongPressResolved: { resolution in
                if resolution.didMove {
                    let shouldRestoreFocus = calendarShouldRestoreFocusAfterQuickMenuDragResume(
                        didMove: resolution.didMove,
                        quickMenuWasPresented: quickActionMenuState != nil,
                        hasDeferredGraceOccurrence: deferredResizeGraceAfterQuickMenu != nil
                    )
                    dismissQuickActionMenu(reason: .dragResume)
                    deferredResizeGraceAfterQuickMenu = nil
                    if shouldRestoreFocus {
                        setFocus(
                            event: resolution.event,
                            occurrenceID: resolution.occurrenceID,
                            reason: "timeline.longPressResolved.dragResume"
                        )
                    }
                    return
                }
                guard resolution.terminalState == .completed else {
                    clearFocus(reason: "timeline.longPressResolved.cancelled")
                    deferredResizeGraceAfterQuickMenu = nil
                    return
                }
                guard quickActionMenuState == nil else { return }
                cancelResizeGrace(reason: "timeline.quickMenu.open")
                let occurrence = makeOccurrenceContext(
                    event: resolution.event,
                    actionDate: resolution.actionDate,
                    occurrenceID: resolution.occurrenceID,
                    isAllDay: false,
                    source: .timelineLongPress
                )
                deferredResizeGraceAfterQuickMenu = occurrence
                clearFocus(reason: "timeline.longPressResolved.quickMenu")
                withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    quickActionMenuState = CalendarQuickActionMenuState(
                        occurrence: occurrence,
                        touchPointGlobal: resolution.touchPointGlobal
                    )
                }
            },
            onEventDragEnded: { event, occurrenceID, draggedRange, offset, dayColumnStep, dayContentWidth in
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
                cancelResizeGrace(reason: "timeline.nonEventTap")
                dismissQuickActionMenu(reason: .passiveDismiss)
                clearFocus()
            },
            onHourHeightCommit: {
                calendarState.commitTimelineHourHeight()
            },
            onHorizontalScrollProgress: { progress in
                if progress.isInteracting {
                    cancelResizeGrace(reason: "timeline.horizontalScroll")
                }
                handleTimelineHorizontalScrollProgress(progress)
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
        updated.startTime = ranges.first?.start
        updated.endTime = ranges.first?.end
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
