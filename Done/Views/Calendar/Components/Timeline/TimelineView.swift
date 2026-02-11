//
//  TimelineView.swift
//  Done
//
//  Timeline 视图：包含容器、日视图、样式定义
//

import SwiftUI
import UIKit
import Combine

// MARK: - Shared Drag State

// Extracted for regression tests: keep boundary dragging unsnapped when snapping would cross day.
func calendarPreviewOffsetSeconds(
    rawOffsetSeconds: TimeInterval,
    range: Event.TimeRange,
    snapIntervalSeconds: TimeInterval = 15 * 60,
    calendar: Calendar = .current
) -> TimeInterval {
    calendarPreviewOffsetSeconds(
        rawOffsetSeconds: rawOffsetSeconds,
        range: range,
        isHorizontalAutoScrolling: false,
        snapIntervalSeconds: snapIntervalSeconds,
        calendar: calendar
    )
}

// Extracted for regression tests: during horizontal auto-scroll, disable timeslot snapping.
func calendarPreviewOffsetSeconds(
    rawOffsetSeconds: TimeInterval,
    range: Event.TimeRange,
    isHorizontalAutoScrolling: Bool,
    snapIntervalSeconds: TimeInterval = 15 * 60,
    calendar: Calendar = .current
) -> TimeInterval {
    if isHorizontalAutoScrolling {
        return rawOffsetSeconds
    }
    guard snapIntervalSeconds > 0 else { return rawOffsetSeconds }
    let snappedSeconds = (rawOffsetSeconds / snapIntervalSeconds).rounded() * snapIntervalSeconds

    let originalStartDay = calendar.startOfDay(for: range.start)
    let originalEndDay = calendar.startOfDay(for: range.end)
    let unsnappedStartDay = calendar.startOfDay(for: range.start.addingTimeInterval(rawOffsetSeconds))
    let unsnappedEndDay = calendar.startOfDay(for: range.end.addingTimeInterval(rawOffsetSeconds))
    let snappedStartDay = calendar.startOfDay(for: range.start.addingTimeInterval(snappedSeconds))
    let snappedEndDay = calendar.startOfDay(for: range.end.addingTimeInterval(snappedSeconds))

    // If snapping would shift day boundary differently from finger position, keep unsnapped.
    if unsnappedStartDay != snappedStartDay || unsnappedEndDay != snappedEndDay {
        return rawOffsetSeconds
    }

    let snappedStartShift = calendar.dateComponents([.day], from: originalStartDay, to: snappedStartDay).day ?? 0
    let unsnappedStartShift = calendar.dateComponents([.day], from: originalStartDay, to: unsnappedStartDay).day ?? 0
    let snappedEndShift = calendar.dateComponents([.day], from: originalEndDay, to: snappedEndDay).day ?? 0
    let unsnappedEndShift = calendar.dateComponents([.day], from: originalEndDay, to: unsnappedEndDay).day ?? 0
    if snappedStartShift != unsnappedStartShift || snappedEndShift != unsnappedEndShift {
        return rawOffsetSeconds
    }

    return snappedSeconds
}

// Extracted for regression tests: avoid lazy recycling while interactive drag is enabled.
func calendarShouldUseLazyTimelineColumns(mode: PageMode) -> Bool {
    mode != .edit
}

// Extracted for regression tests: true only while there is an active move-drag.
func calendarIsMoveDragActive(
    draggingEventID: UUID?,
    dragMode: EventDragMode
) -> Bool {
    draggingEventID != nil && dragMode == .move
}

// Extracted for regression tests: suppress general horizontal slot snapping while
// move-drag is active. Auto-scroll stop snap is handled separately.
func calendarShouldRunGeneralHorizontalSlotSnap(
    isMoveDragActive: Bool
) -> Bool {
    !isMoveDragActive
}

// Extracted for regression tests: auto-scroll-stop snap should run whenever pending
// and not currently restoring, regardless of temporary snap-disable flags.
func calendarShouldConsumePendingAutoStopSnap(
    pendingSnapAfterAutoScrollStop: Bool,
    isRestoringScroll: Bool
) -> Bool {
    pendingSnapAfterAutoScrollStop && !isRestoringScroll
}

// Extracted for regression tests: disable horizontal day-slot snap while edge auto-scroll drag is active.
func calendarShouldDisableHorizontalScrollSnap(
    isHorizontalEdgeDragging: Bool,
    isHorizontalAutoScrolling: Bool
) -> Bool {
    isHorizontalEdgeDragging || isHorizontalAutoScrolling
}

// Extracted for regression tests: trigger immediate slot snap when horizontal auto-scroll just stopped.
func calendarShouldSnapImmediatelyAfterHorizontalAutoScrollStop(
    previousIsHorizontalAutoScrolling: Bool,
    currentIsHorizontalAutoScrolling: Bool
) -> Bool {
    previousIsHorizontalAutoScrolling && !currentIsHorizontalAutoScrolling
}

// Extracted for regression tests: quantize horizontal content offset to nearest leading day offset.
func calendarNearestLeadingDayOffset(
    contentOffsetX: CGFloat,
    step: CGFloat,
    leadingRange: ClosedRange<Int>
) -> Int {
    guard step > 0 else { return leadingRange.lowerBound }
    let rawIndex = contentOffsetX / step
    let index = Int(rawIndex.rounded())
    let offset = leadingRange.lowerBound + index
    return clamp(offset, to: leadingRange)
}

// Extracted for regression tests: disable timeslot snap while horizontal boundary drag is active.
func calendarShouldDisableTimeslotSnap(
    isHorizontalEdgeDragging: Bool,
    isHorizontalAutoScrolling: Bool
) -> Bool {
    isHorizontalEdgeDragging || isHorizontalAutoScrolling
}

/// Observable object for sharing drag state across all event blocks (for cross-day sync)
final class EventDragState: ObservableObject {
    @Published var draggingEventID: UUID? = nil
    @Published var draggingOccurrenceID: String? = nil
    @Published var draggingEvent: Event? = nil
    @Published var draggingOriginalRange: Event.TimeRange? = nil
    @Published var dragOffset: DragOffset = .zero
    @Published var dragMode: EventDragMode = .move
    @Published var isHorizontalEdgeDragging: Bool = false
    @Published var isHorizontalAutoScrolling: Bool = false

    /// Computed preview range based on current drag offset
    func previewRange(hourHeight: CGFloat) -> Event.TimeRange? {
        guard let range = draggingOriginalRange, dragMode == .move else { return nil }

        guard hourHeight > 0 else { return range }
        let rawOffsetSeconds = TimeInterval(dragOffset.y / hourHeight * 3600)
        let isMoveDragActive = calendarIsMoveDragActive(
            draggingEventID: draggingEventID,
            dragMode: dragMode
        )
        let disableTimeslotSnap = isMoveDragActive && calendarShouldDisableTimeslotSnap(
            isHorizontalEdgeDragging: isHorizontalEdgeDragging,
            isHorizontalAutoScrolling: isHorizontalAutoScrolling
        )
        let displayOffsetSeconds = calendarPreviewOffsetSeconds(
            rawOffsetSeconds: rawOffsetSeconds,
            range: range,
            isHorizontalAutoScrolling: disableTimeslotSnap
        )
        let newStart = range.start.addingTimeInterval(displayOffsetSeconds)
        let newEnd = range.end.addingTimeInterval(displayOffsetSeconds)
        return Event.TimeRange(start: newStart, end: newEnd)
    }
}

// Extracted for regression tests: only the dragged occurrence should follow drag state.
func isActiveDraggedOccurrence(
    occurrenceID: String?,
    draggingOccurrenceID: String?,
    dragMode: EventDragMode
) -> Bool {
    guard let occurrenceID else { return false }
    return draggingOccurrenceID == occurrenceID && dragMode == .move
}

// Extracted for regression tests: keep dragged occurrence renderable when preview leaves this day.
func calendarAdjustedOccurrenceRange(
    occurrenceID: String,
    occurrenceRange: Event.TimeRange,
    draggingOccurrenceID: String?,
    dragMode: EventDragMode,
    previewRange: Event.TimeRange?,
    dayStart: Date,
    dayEnd: Date
) -> Event.TimeRange? {
    guard isActiveDraggedOccurrence(
        occurrenceID: occurrenceID,
        draggingOccurrenceID: draggingOccurrenceID,
        dragMode: dragMode
    ), let previewRange else {
        return occurrenceRange
    }

    if previewRange.end > dayStart && previewRange.start < dayEnd {
        let clippedStart = max(previewRange.start, dayStart)
        let clippedEnd = min(previewRange.end, dayEnd)
        return Event.TimeRange(start: clippedStart, end: clippedEnd)
    }

    // Keep the source block alive near day edges so long-press drag is not cancelled
    // when snapped preview crosses to an adjacent day.
    let pinnedDuration: TimeInterval = 15 * 60
    if previewRange.start >= dayEnd {
        return Event.TimeRange(
            start: dayEnd.addingTimeInterval(-pinnedDuration),
            end: dayEnd
        )
    }
    if previewRange.end <= dayStart {
        return Event.TimeRange(
            start: dayStart,
            end: dayStart.addingTimeInterval(pinnedDuration)
        )
    }

    return occurrenceRange
}

// MARK: - Timeline Style

struct TimelineStyle {
    enum Variant {
        case view
        case edit
    }

    let variant: Variant
    let gridDashed: Bool
    let gridColor: Color

    static let edit = TimelineStyle(
        variant: .edit,
        gridDashed: false,
        gridColor: Color.secondary.opacity(0.2)
    )

    static let view = TimelineStyle(
        variant: .view,
        gridDashed: true,
        gridColor: Color.secondary.opacity(0.35)
    )
}

// MARK: - Timeline Container (Public Entry Point)

struct TimelineContainerView: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let mode: PageMode
    let range: RangeMode
    let dayRange: ClosedRange<Int>
    var previewCreation: PendingEventCreation? = nil
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset, CGFloat) -> Void)? = nil
    var onEventResizeEnded: ((Event, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)? = nil
    var onCreateEvent: ((Date, Event.TimeRange) -> Void)? = nil

    var body: some View {
        TimelinePagerView(
            occurrencesForOffset: occurrencesForOffset,
            selectedDayOffset: $selectedDayOffset,
            daysCount: daysCount,
            mode: mode,
            showEventText: showEventText,
            dayRange: dayRange,
            previewCreation: previewCreation,
            onEventTap: onEventTap,
            onEventDragEnded: onEventDragEnded,
            onEventResizeEnded: onEventResizeEnded,
            onCreateEvent: onCreateEvent
        )
    }

    private var daysCount: Int {
        switch range {
        case .day: return 1
        case .threeDay: return 3
        case .week: return 7
        }
    }

    private var showEventText: Bool {
        switch range {
        case .day, .threeDay: return true
        case .week: return false
        }
    }
}

// MARK: - Timeline Pager (ScrollView)

private struct TimelinePagerView: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let daysCount: Int
    let mode: PageMode
    let showEventText: Bool
    let dayRange: ClosedRange<Int>
    var previewCreation: PendingEventCreation? = nil
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset, CGFloat) -> Void)? = nil
    var onEventResizeEnded: ((Event, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)? = nil
    var onCreateEvent: ((Date, Event.TimeRange) -> Void)? = nil

    // Layout Constants
    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let daySpacing: CGFloat = 12
    private let eventHorizontalInset: CGFloat = 0
    private let scrollHorizontalPadding: CGFloat = 8
    private let headerHeight: CGFloat = 0

    // Computed
    private var isSingleDay: Bool { daysCount == 1 }
    private var showDayLabel: Bool { mode == .edit }
    private var labelBarHeight: CGFloat { showDayLabel ? 18 : 0 }
    private var labelBarSpacing: CGFloat { showDayLabel ? 6 : 0 }
    private var timelineHeight: CGFloat { headerHeight + CGFloat(25) * hourHeight }
    private var totalHeight: CGFloat { labelBarHeight + timelineHeight }

    // Scroll State
    @State private var hasScrolledToInitial = false
    @State private var isRestoringScroll = true
    @State private var pendingScrollTarget: Int? = nil
    @State private var isUserScrollUpdating = false
    @State private var latestHorizontalContentOffsetX: CGFloat = 0
    @State private var previousHorizontalAutoScrolling: Bool = false
    @State private var pendingSnapAfterAutoScrollStop: Bool = false

    // Drag State (shared across all day views for cross-day event sync)
    @StateObject private var dragState = EventDragState()

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width - labelWidth)
            let contentWidth = max(0, availableWidth - scrollHorizontalPadding * 2)
            let dayWidth = isSingleDay
                ? contentWidth
                : max(0, (contentWidth - daySpacing * CGFloat(daysCount - 1)) / CGFloat(daysCount))
            let dayFrameWidth = isSingleDay ? availableWidth : dayWidth
            let labelRowHeight = max(0, labelBarHeight - labelBarSpacing)
            let effectiveSpacing = isSingleDay ? CGFloat(0) : daySpacing

            HStack(spacing: 0) {
                timeAxis(labelRowHeight: labelRowHeight)
                    .frame(width: labelWidth, alignment: .trailing)

                scrollContent(dayWidth: dayWidth, dayFrameWidth: dayFrameWidth, labelRowHeight: labelRowHeight, spacing: effectiveSpacing)
            }
        }
        .frame(height: totalHeight, alignment: .top)
    }

    // MARK: - Time Axis

    @ViewBuilder
    private func timeAxis(labelRowHeight: CGFloat) -> some View {
        if showDayLabel {
            VStack(spacing: labelBarSpacing) {
                Color.clear.frame(height: labelRowHeight)
                TimeAxisLabels(headerHeight: headerHeight, hourHeight: hourHeight, mode: mode)
                    .frame(height: timelineHeight, alignment: .top)
            }
        } else {
            TimeAxisLabels(headerHeight: headerHeight, hourHeight: hourHeight, mode: mode)
        }
    }

    // MARK: - Scroll Content (Unified for Single/Multi Day)

    @ViewBuilder
    private func scrollContent(dayWidth: CGFloat, dayFrameWidth: CGFloat, labelRowHeight: CGFloat, spacing: CGFloat) -> some View {
        let leadingRange = leadingOffsetsRange()
        let step = dayFrameWidth + spacing
        let isMoveDragActive = calendarIsMoveDragActive(
            draggingEventID: dragState.draggingEventID,
            dragMode: dragState.dragMode
        )
        let isHorizontalSlotSnapDisabled = isMoveDragActive && calendarShouldDisableHorizontalScrollSnap(
            isHorizontalEdgeDragging: dragState.isHorizontalEdgeDragging,
            isHorizontalAutoScrolling: dragState.isHorizontalAutoScrolling
        )

        ScrollViewReader { scrollProxy in
            let snapToNearestDaySlot: () -> Void = {
                guard step > 0 else { return }
                let clamped = calendarNearestLeadingDayOffset(
                    contentOffsetX: latestHorizontalContentOffsetX,
                    step: step,
                    leadingRange: leadingRange
                )
                pendingScrollTarget = clamped
                isRestoringScroll = true
                if selectedDayOffset != clamped {
                    selectedDayOffset = clamped
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo(clamped, anchor: .leading)
                }
            }

            let consumePendingAutoStopSnapIfPossible: () -> Void = {
                guard calendarShouldConsumePendingAutoStopSnap(
                    pendingSnapAfterAutoScrollStop: pendingSnapAfterAutoScrollStop,
                    isRestoringScroll: isRestoringScroll
                ) else { return }
                pendingSnapAfterAutoScrollStop = false
                snapToNearestDaySlot()
            }

            ScrollView(.horizontal) {
                Group {
                    if calendarShouldUseLazyTimelineColumns(mode: mode) {
                        LazyHStack(spacing: spacing) {
                            dayColumns(dayWidth: dayWidth, dayFrameWidth: dayFrameWidth, labelRowHeight: labelRowHeight)
                        }
                        .scrollTargetLayout()
                    } else {
                        HStack(spacing: spacing) {
                            dayColumns(dayWidth: dayWidth, dayFrameWidth: dayFrameWidth, labelRowHeight: labelRowHeight)
                        }
                        .scrollTargetLayout()
                    }
                }
                .padding(.horizontal, isSingleDay ? 0 : scrollHorizontalPadding)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                guard !hasScrolledToInitial else { return }
                hasScrolledToInitial = true
                previousHorizontalAutoScrolling = dragState.isHorizontalAutoScrolling
                let clamped = clamp(selectedDayOffset, to: leadingRange)
                if clamped != selectedDayOffset { selectedDayOffset = clamped }
                pendingScrollTarget = clamped
                isRestoringScroll = true
                // Defer to next run loop so LazyHStack layout is finalized
                DispatchQueue.main.async {
                    scrollProxy.scrollTo(clamped, anchor: .leading)
                }
            }
            .onChange(of: selectedDayOffset) { newValue in
                if isUserScrollUpdating {
                    isUserScrollUpdating = false
                    return
                }
                let clamped = clamp(newValue, to: leadingRange)
                pendingScrollTarget = clamped
                isRestoringScroll = true
                scrollProxy.scrollTo(clamped, anchor: .leading)
            }
            .onChange(of: dayRange) { _ in
                let clamped = clamp(selectedDayOffset, to: leadingRange)
                if clamped != selectedDayOffset { selectedDayOffset = clamped }
                pendingScrollTarget = clamped
                isRestoringScroll = true
                scrollProxy.scrollTo(clamped, anchor: .leading)
            }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
                guard step > 0 else { return }
                latestHorizontalContentOffsetX = newValue.contentOffset.x
                if isRestoringScroll {
                    guard let target = pendingScrollTarget else { return }
                    let targetIndex = target - leadingRange.lowerBound
                    let targetX = CGFloat(targetIndex) * step
                    if abs(newValue.contentOffset.x - targetX) > step * 0.5 { return }
                    isRestoringScroll = false
                    pendingScrollTarget = nil
                }
                let clamped = calendarNearestLeadingDayOffset(
                    contentOffsetX: newValue.contentOffset.x,
                    step: step,
                    leadingRange: leadingRange
                )
                if selectedDayOffset != clamped {
                    isUserScrollUpdating = true
                    selectedDayOffset = clamped
                }
                consumePendingAutoStopSnapIfPossible()
            }
            .onScrollPhaseChange { _, newPhase in
                guard newPhase == .idle else { return }
                guard step > 0 else { return }
                guard !isRestoringScroll else { return }
                consumePendingAutoStopSnapIfPossible()
                guard !isRestoringScroll else { return }
                guard !isHorizontalSlotSnapDisabled else { return }
                guard calendarShouldRunGeneralHorizontalSlotSnap(isMoveDragActive: isMoveDragActive) else { return }
                snapToNearestDaySlot()
            }
            .onChange(of: isHorizontalSlotSnapDisabled) { isDisabled in
                guard !isDisabled else { return }
                consumePendingAutoStopSnapIfPossible()
                guard step > 0 else { return }
                guard !isRestoringScroll else { return }
                guard calendarShouldRunGeneralHorizontalSlotSnap(isMoveDragActive: isMoveDragActive) else { return }
                snapToNearestDaySlot()
            }
            .onChange(of: dragState.isHorizontalAutoScrolling) { isAutoScrolling in
                let shouldSnap = calendarShouldSnapImmediatelyAfterHorizontalAutoScrollStop(
                    previousIsHorizontalAutoScrolling: previousHorizontalAutoScrolling,
                    currentIsHorizontalAutoScrolling: isAutoScrolling
                )
                previousHorizontalAutoScrolling = isAutoScrolling
                guard shouldSnap else { return }
                pendingSnapAfterAutoScrollStop = true
                consumePendingAutoStopSnapIfPossible()
            }
        }
    }

    @ViewBuilder
    private func dayColumns(dayWidth: CGFloat, dayFrameWidth: CGFloat, labelRowHeight: CGFloat) -> some View {
        ForEach(dayRange, id: \.self) { offset in
            dayColumn(offset: offset, width: dayWidth, labelRowHeight: labelRowHeight)
                .frame(width: dayFrameWidth)
                .id(offset)
        }
    }

    // MARK: - Day Column

    @ViewBuilder
    private func dayColumn(offset: Int, width: CGFloat, labelRowHeight: CGFloat) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        let date = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
        let columnStep: CGFloat = isSingleDay ? 0 : width + daySpacing

        // Check if preview should be shown on this day
        let previewRange: Event.TimeRange? = {
            guard let preview = previewCreation else { return nil }
            let previewDay = Calendar.current.startOfDay(for: preview.date)
            return previewDay == date ? preview.timeRange : nil
        }()

        let isToday = offset == 0

        let todayBackground = isToday ? Color.gray.opacity(0.1) : Color.clear

        if showDayLabel {
            VStack(spacing: labelBarSpacing) {
                Text(slotLabel(for: offset))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: labelRowHeight, alignment: .center)
                    .allowsHitTesting(false)

                TimelineDayView(
                    date: date,
                    occurrences: occurrencesForOffset(offset),
                    contentWidth: width,
                    headerHeight: headerHeight,
                    hourHeight: hourHeight,
                    eventHorizontalInset: eventHorizontalInset,
                    showEventText: showEventText,
                    style: mode == .edit ? .edit : .view,
                    dayColumnStep: columnStep,
                    previewTimeRange: previewRange,
                    onEventTap: mode == .edit ? onEventTap : nil,
                    onEventDragEnded: mode == .edit ? onEventDragEnded : nil,
                    onEventResizeEnded: mode == .edit ? onEventResizeEnded : nil,
                    onCreateEvent: mode == .edit ? { range in onCreateEvent?(date, range) } : nil,
                    dragState: dragState
                )
                .frame(width: width, height: timelineHeight, alignment: .top)
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(todayBackground)
                        .frame(height: CGFloat(24) * hourHeight)
                }
            }
        } else {
            TimelineDayView(
                date: date,
                occurrences: occurrencesForOffset(offset),
                contentWidth: width,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                eventHorizontalInset: eventHorizontalInset,
                showEventText: showEventText,
                style: mode == .edit ? .edit : .view,
                dayColumnStep: columnStep,
                previewTimeRange: previewRange,
                onEventTap: mode == .edit ? onEventTap : nil,
                onEventDragEnded: mode == .edit ? onEventDragEnded : nil,
                onEventResizeEnded: mode == .edit ? onEventResizeEnded : nil,
                onCreateEvent: mode == .edit ? { range in onCreateEvent?(date, range) } : nil,
                dragState: dragState
            )
            .frame(width: width, height: timelineHeight, alignment: .top)
            .background(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(todayBackground)
                    .frame(height: CGFloat(24) * hourHeight)
            }
        }
    }

    // MARK: - Helpers

    private func leadingOffsetsRange() -> ClosedRange<Int> {
        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound - (daysCount - 1)
        return lower <= upper ? lower...upper : lower...lower
    }

    private func slotLabel(for offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let day = Calendar.current.component(.day, from: date)
        let weekdayIndex = Calendar.current.component(.weekday, from: date) - 1
        let symbols = Calendar.current.shortWeekdaySymbols
        let letter = symbols.indices.contains(weekdayIndex) ? String(symbols[weekdayIndex].prefix(1)) : ""
        return "\(day)\(letter)"
    }
}

// MARK: - Time Axis Labels

private struct TimeAxisLabels: View {
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let mode: PageMode

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headerHeight)
            ForEach(0...24, id: \.self) { hour in
                Text(mode == .edit ? String(format: "%02d:00", hour) : "\(hour)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }
}

// MARK: - Creation Drag Gesture (UIKit)

/// UIKit-based long press drag gesture for creating events.
/// Reports absolute Y positions instead of offsets.
private struct CreationDragGesture: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = 0.3
    var onBegan: ((CGFloat) -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat) -> Void)?
    var onCancelled: (() -> Void)?

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

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CreationDragGesture
        var onBegan: ((CGFloat) -> Void)?
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat) -> Void)?
        var onCancelled: (() -> Void)?

        init(_ parent: CreationDragGesture) {
            self.parent = parent
            self.onBegan = parent.onBegan
            self.onChanged = parent.onChanged
            self.onEnded = parent.onEnded
            self.onCancelled = parent.onCancelled
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                onBegan?(location.y)
            case .changed:
                onChanged?(location.y)
            case .ended:
                onEnded?(location.y)
            case .cancelled, .failed:
                onCancelled?()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

// MARK: - Timeline Day View

private struct TimelineDayView: View {
    let date: Date
    let occurrences: [CalendarLayout.EventOccurrence]
    let contentWidth: CGFloat
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let eventHorizontalInset: CGFloat
    let showEventText: Bool
    let style: TimelineStyle
    var dayColumnStep: CGFloat = 0
    var previewTimeRange: Event.TimeRange? = nil
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset, CGFloat) -> Void)? = nil
    var onEventResizeEnded: ((Event, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)? = nil
    var onCreateEvent: ((Event.TimeRange) -> Void)? = nil

    // Shared drag state for cross-day event sync
    @ObservedObject var dragState: EventDragState

    // Creation drag state
    @State private var isCreating = false
    @State private var creationStartY: CGFloat = 0
    @State private var creationCurrentY: CGFloat = 0
    @State private var lastTickMinutes: Int = -1

    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    private let snapMinutes: Int = 15

    private var isCreateEnabled: Bool { onCreateEvent != nil }

    // Show preview if dragging OR if there's a pending creation for this day
    private var activePreviewRange: Event.TimeRange? {
        if isCreating {
            return creationPreviewRange
        }
        return previewTimeRange
    }

    /// Check if we need to show a drag preview for an event being dragged from another day
    /// Returns (event, clipped range for this day) if preview should be shown
    private var dragPreviewInfo: (event: Event, range: Event.TimeRange)? {
        guard let event = dragState.draggingEvent,
              let draggingOccurrenceID = dragState.draggingOccurrenceID,
              let previewRange = dragState.previewRange(hourHeight: hourHeight),
              dragState.dragMode == .move else { return nil }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Check if preview range intersects this day
        guard previewRange.end > dayStart && previewRange.start < dayEnd else { return nil }

        // Check if this day already has an occurrence for this event (don't double-show)
        let hasExistingOccurrence = occurrences.contains {
            isActiveDraggedOccurrence(
                occurrenceID: $0.id,
                draggingOccurrenceID: draggingOccurrenceID,
                dragMode: .move
            )
        }
        if hasExistingOccurrence { return nil }

        // Clip range to this day
        let clippedStart = max(previewRange.start, dayStart)
        let clippedEnd = min(previewRange.end, dayEnd)
        let clippedRange = Event.TimeRange(start: clippedStart, end: clippedEnd)

        return (event, clippedRange)
    }

    /// Calculate the adjusted display range for an occurrence during drag
    /// Returns the new clipped range for this day, or nil if the event no longer intersects this day
    private func adjustedRange(for occurrence: CalendarLayout.EventOccurrence) -> Event.TimeRange? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return calendarAdjustedOccurrenceRange(
            occurrenceID: occurrence.id,
            occurrenceRange: occurrence.range,
            draggingOccurrenceID: dragState.draggingOccurrenceID,
            dragMode: dragState.dragMode,
            previewRange: dragState.previewRange(hourHeight: hourHeight),
            dayStart: dayStart,
            dayEnd: dayEnd
        )
    }

    var body: some View {
        // Explicitly subscribe to dragState changes to ensure SwiftUI tracks them
        let draggingID = dragState.draggingEventID
        let _ = dragState.dragOffset  // Force subscription for reactive updates
        let currentMode = dragState.dragMode

        ZStack(alignment: .topLeading) {
            grid

            // Creation gesture layer (below events so event gestures take priority)
            if isCreateEnabled {
                creationGestureLayer
            }

            // Existing events (above gesture layer, their gestures take priority)
            ForEach(occurrences) { occurrence in
                // Calculate adjusted range for drag (dynamically re-clips to this day)
                if let displayRange = adjustedRange(for: occurrence) {
                    eventBlock(for: occurrence, adjustedRange: displayRange)
                        .frame(
                            width: max(0, contentWidth - eventHorizontalInset * 2),
                            height: CalendarLayout.eventHeight(
                                for: displayRange,
                                on: date,
                                minimumHeight: occurrence.event.timerStartedAt != nil ? 0 : hourHeight / 2,
                                hourHeight: hourHeight
                            ),
                            alignment: .top
                        )
                        .offset(
                            x: eventHorizontalInset,
                            y: CalendarLayout.yOffset(
                                for: displayRange,
                                on: date,
                                headerHeight: headerHeight,
                                hourHeight: hourHeight
                            )
                        )
                }
            }

            // Drag preview for cross-day events (shows new day coverage during drag)
            // Use captured values to ensure reactive updates
            if draggingID != nil && currentMode == .move {
                if let (event, previewRange) = dragPreviewInfo {
                    dragPreview(for: event, range: previewRange)
                }
            }

            // Creation preview (topmost, no hit testing)
            // Shows during drag OR while form sheet is open
            if let previewRange = activePreviewRange {
                creationPreview(for: previewRange)
            }
        }
        .id("\(style.variant)-\(date.timeIntervalSince1970)")
    }

    // MARK: - Creation Gesture

    private var creationGestureLayer: some View {
        CreationDragGesture(
            minimumPressDuration: 0.3,
            onBegan: { y in
                isCreating = true
                creationStartY = y
                creationCurrentY = y
                lastTickMinutes = currentSnappedMinutes(for: y)
                hapticFeedback.impactOccurred()
            },
            onChanged: { y in
                creationCurrentY = y
                checkHapticTick()
            },
            onEnded: { _ in
                if let range = creationPreviewRange {
                    // Ensure minimum duration (15 minutes)
                    let minDuration: TimeInterval = 15 * 60
                    let duration = range.end.timeIntervalSince(range.start)
                    let finalRange: Event.TimeRange
                    if duration < minDuration {
                        finalRange = Event.TimeRange(
                            start: range.start,
                            end: range.start.addingTimeInterval(minDuration)
                        )
                    } else {
                        finalRange = range
                    }
                    onCreateEvent?(finalRange)
                }
                isCreating = false
                lastTickMinutes = -1
            },
            onCancelled: {
                isCreating = false
                lastTickMinutes = -1
            }
        )
    }

    private var creationPreviewRange: Event.TimeRange? {
        guard isCreating else { return nil }

        let startTime = timeFromY(creationStartY)
        let endTime = timeFromY(creationCurrentY)

        // Ensure start < end
        if startTime < endTime {
            return Event.TimeRange(start: startTime, end: endTime)
        } else {
            return Event.TimeRange(start: endTime, end: startTime)
        }
    }

    private func creationPreview(for range: Event.TimeRange) -> some View {
        let y = CalendarLayout.yOffset(
            for: range,
            on: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight
        )
        let height = CalendarLayout.eventHeight(
            for: range,
            on: date,
            minimumHeight: hourHeight / 2,
            hourHeight: hourHeight
        )

        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 2)
            )
            .overlay(
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Event")
                        .font(.system(size: 12, weight: .semibold))
                    Text(timeRangeText(for: range))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(8),
                alignment: .topLeading
            )
            .frame(
                width: max(0, contentWidth - eventHorizontalInset * 2),
                height: height
            )
            .offset(x: eventHorizontalInset, y: y)
            .allowsHitTesting(false)
    }

    private func timeFromY(_ y: CGFloat) -> Date {
        CalendarLayout.timeFromYOffset(
            yOffset: y,
            on: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            snapMinutes: snapMinutes
        )
    }

    private func currentSnappedMinutes(for y: CGFloat) -> Int {
        let time = timeFromY(y)
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func checkHapticTick() {
        let currentMinutes = currentSnappedMinutes(for: creationCurrentY)
        if currentMinutes != lastTickMinutes {
            lastTickMinutes = currentMinutes
            hapticFeedback.impactOccurred()
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func timeRangeText(for range: Event.TimeRange) -> String {
        "\(Self.timeFormatter.string(from: range.start)) - \(Self.timeFormatter.string(from: range.end))"
    }

    /// Preview block for an event being dragged into this day from another day
    private func dragPreview(for event: Event, range: Event.TimeRange) -> some View {
        let color = CalendarLayout.eventColor(for: event)
        let height = CalendarLayout.eventHeight(
            for: range,
            on: date,
            minimumHeight: hourHeight / 2,
            hourHeight: hourHeight
        )
        let y = CalendarLayout.yOffset(
            for: range,
            on: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight
        )

        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color.opacity(0.5), lineWidth: 1)
            )
            .overlay(
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(timeRangeText(for: range))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(8),
                alignment: .topLeading
            )
            .frame(
                width: max(0, contentWidth - eventHorizontalInset * 2),
                height: height
            )
            .offset(x: eventHorizontalInset, y: y)
            .scaleEffect(1.05)
            .shadow(radius: 8)
            .allowsHitTesting(false)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: contentWidth, height: headerHeight, alignment: .center)
            ForEach(0...24, id: \.self) { _ in
                if style.gridDashed {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundColor(style.gridColor)
                        .frame(width: contentWidth, height: 1)
                        .frame(height: hourHeight, alignment: .top)
                } else {
                    Rectangle()
                        .fill(style.gridColor)
                        .frame(width: contentWidth, height: 1)
                        .frame(height: hourHeight, alignment: .top)
                }
            }
        }
    }

    private func eventBlock(for occurrence: CalendarLayout.EventOccurrence, adjustedRange: Event.TimeRange) -> some View {
        let event = occurrence.event
        let originalRange = occurrence.range
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Disable resize handles for cross-day boundaries (based on ADJUSTED range during drag)
        let startsBeforeToday = adjustedRange.start <= dayStart
        let endsAfterToday = adjustedRange.end >= dayEnd

        return EventBlock(
            event: event,
            occurrenceID: occurrence.id,
            dragSourceRange: originalRange,
            displayRange: adjustedRange,
            color: CalendarLayout.eventColor(for: event),
            showText: showEventText,
            style: style.variant == .edit ? .edit : .preview,
            hourHeight: hourHeight,
            dayColumnStep: dayColumnStep,
            onTap: onEventTap != nil ? { onEventTap?(event) } : nil,
            onDragEnded: onEventDragEnded != nil ? { offset in
                onEventDragEnded?(event, originalRange, offset, dayColumnStep)
            } : nil,
            onResizeTopEnded: onEventResizeEnded != nil ? { yOffset in
                onEventResizeEnded?(event, originalRange, date, .resizeTop, yOffset)
            } : nil,
            onResizeBottomEnded: onEventResizeEnded != nil ? { yOffset in
                onEventResizeEnded?(event, originalRange, date, .resizeBottom, yOffset)
            } : nil,
            // Disable resize handles for cross-day boundaries
            canResizeTop: !startsBeforeToday,
            canResizeBottom: !endsAfterToday,
            isTimerActive: event.timerStartedAt != nil,
            // Cross-day drag sync
            dragState: dragState
        )
    }

}
