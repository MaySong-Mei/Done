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

/// Observable object for sharing drag state across all event blocks (for cross-day sync)
final class EventDragState: ObservableObject {
    @Published var draggingEventID: UUID? = nil
    @Published var draggingEvent: Event? = nil
    @Published var draggingOriginalRange: Event.TimeRange? = nil
    @Published var dragOffset: DragOffset = .zero
    @Published var dragMode: EventDragMode = .move

    /// Computed preview range based on current drag offset
    func previewRange(hourHeight: CGFloat) -> Event.TimeRange? {
        guard let range = draggingOriginalRange, dragMode == .move else { return nil }
        let offsetSeconds = TimeInterval(dragOffset.y / hourHeight * 3600)
        let snappedSeconds = (offsetSeconds / 900).rounded() * 900 // 15-min snap
        let newStart = range.start.addingTimeInterval(snappedSeconds)
        let newEnd = range.end.addingTimeInterval(snappedSeconds)
        return Event.TimeRange(start: newStart, end: newEnd)
    }
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
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset) -> Void)? = nil
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
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset) -> Void)? = nil
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

        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(dayRange, id: \.self) { offset in
                        dayColumn(offset: offset, width: dayWidth, labelRowHeight: labelRowHeight)
                            .frame(width: dayFrameWidth)
                            .id(offset)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, isSingleDay ? 0 : scrollHorizontalPadding)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .onAppear {
                guard !hasScrolledToInitial else { return }
                hasScrolledToInitial = true
                let clamped = clamp(selectedDayOffset, to: leadingRange)
                if clamped != selectedDayOffset { selectedDayOffset = clamped }
                pendingScrollTarget = clamped
                isRestoringScroll = true
                scrollProxy.scrollTo(clamped, anchor: .leading)
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
                if isRestoringScroll {
                    guard let target = pendingScrollTarget else { return }
                    let targetIndex = target - leadingRange.lowerBound
                    let targetX = CGFloat(targetIndex) * step
                    if abs(newValue.contentOffset.x - targetX) > step * 0.5 { return }
                    isRestoringScroll = false
                    pendingScrollTarget = nil
                }
                let rawIndex = newValue.contentOffset.x / step
                let index = Int(rawIndex.rounded(.towardZero))
                let offset = leadingRange.lowerBound + index
                let clamped = clamp(offset, to: leadingRange)
                if selectedDayOffset != clamped {
                    isUserScrollUpdating = true
                    selectedDayOffset = clamped
                }
            }
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
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset) -> Void)? = nil
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
              let previewRange = dragState.previewRange(hourHeight: hourHeight),
              dragState.dragMode == .move else { return nil }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Check if preview range intersects this day
        guard previewRange.end > dayStart && previewRange.start < dayEnd else { return nil }

        // Check if this day already has an occurrence for this event (don't double-show)
        let hasExistingOccurrence = occurrences.contains { $0.event.id == event.id }
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
        // If this event is not being dragged, return original range
        guard dragState.draggingEventID == occurrence.event.id,
              dragState.dragMode == .move,
              let fullPreviewRange = dragState.previewRange(hourHeight: hourHeight) else {
            return occurrence.range
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Check if the new range intersects this day
        guard fullPreviewRange.end > dayStart && fullPreviewRange.start < dayEnd else {
            return nil // Event no longer covers this day
        }

        // Clip to this day's boundaries
        let clippedStart = max(fullPreviewRange.start, dayStart)
        let clippedEnd = min(fullPreviewRange.end, dayEnd)
        return Event.TimeRange(start: clippedStart, end: clippedEnd)
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
                                minimumHeight: hourHeight / 2,
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
            displayRange: adjustedRange,
            color: CalendarLayout.eventColor(for: event),
            showText: showEventText,
            style: style.variant == .edit ? .edit : .preview,
            hourHeight: hourHeight,
            dayColumnStep: dayColumnStep,
            onTap: onEventTap != nil ? { onEventTap?(event) } : nil,
            onDragEnded: onEventDragEnded != nil ? { offset in
                onEventDragEnded?(event, originalRange, offset)
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
            // Cross-day drag sync
            dragState: dragState
        )
    }

}
