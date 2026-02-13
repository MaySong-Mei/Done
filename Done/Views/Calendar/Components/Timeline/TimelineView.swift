//
//  TimelineView.swift
//  Done
//
//  Timeline 视图：包含容器、日视图、样式定义
//

import SwiftUI
import UIKit
import Combine
import os

private enum CalendarDebugTrace {
    static let queue = DispatchQueue(label: "done.calendar.debug.trace")
    static var didStartSession = false
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Done",
        category: "CalendarInteraction"
    )
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func log(event: String, fields: [String: String]) {
        queue.async {
            let timestamp = timestampFormatter.string(from: Date())
            let sortedFields = fields
                .map { key, value in "\(key)=\(value)" }
                .sorted()
                .joined(separator: " ")
            let line = "[CALDBG] \(timestamp) \(event)\(sortedFields.isEmpty ? "" : " \(sortedFields)")"
            print(line)
            logger.debug("\(line, privacy: .public)")
            appendToFile(line: line)
        }
    }

    static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func appendToFile(line: String) {
        guard let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("calendar-debug.log") else { return }

        if !didStartSession {
            didStartSession = true
            let banner = "\n[CALDBG] ===== New Session \(timestampFormatter.string(from: Date())) =====\n"
            if let bannerData = banner.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path),
                   let handle = try? FileHandle(forWritingTo: fileURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: bannerData)
                    try? handle.close()
                } else {
                    try? bannerData.write(to: fileURL, options: .atomic)
                }
            }
            print("[CALDBG] file=\(fileURL.path)")
        }

        guard let data = "\(line)\n".data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

func calendarDebugLog(_ event: String, fields: [String: String] = [:]) {
#if DEBUG
    CalendarDebugTrace.log(event: event, fields: fields)
#endif
}

func calendarDebugDayString(_ date: Date) -> String {
    CalendarDebugTrace.dayString(from: date)
}

func calendarDebugInstantString(_ date: Date) -> String {
    CalendarDebugTrace.timestampFormatter.string(from: date)
}

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

// Extracted for quick tuning: keep strong step-snap for normal scroll and avoid
// runtime behavior toggles while dragging.
func calendarShouldEnablePersistentHorizontalSlotSnap(
    isMoveDragActive: Bool,
    isHorizontalSlotSnapDisabled: Bool
) -> Bool {
    _ = isMoveDragActive
    _ = isHorizontalSlotSnapDisabled
    // Keep persistent day-slot stepping always enabled to avoid runtime
    // scroll behavior reconfiguration during drag sessions.
    return true
}

// Extracted for regression tests: while move-drag is active, ignore selected-day
// updates from transient geometry resets.
func calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
    isMoveDragActive: Bool,
    isHorizontalAutoScrolling: Bool
) -> Bool {
    _ = isHorizontalAutoScrolling
    return isMoveDragActive
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

// Extracted for regression tests: center slot index for an N-day viewport.
func calendarCenterSlotIndex(daysCount: Int) -> Int {
    max(0, daysCount / 2)
}

// Extracted for regression tests: valid centered-day offsets for the given day window.
func calendarCenteredDayOffsetRange(
    dayRange: ClosedRange<Int>,
    daysCount: Int
) -> ClosedRange<Int> {
    let centerIndex = calendarCenterSlotIndex(daysCount: daysCount)
    let trailingCount = max(0, daysCount - centerIndex - 1)
    let lower = dayRange.lowerBound + centerIndex
    let upper = dayRange.upperBound - trailingCount
    return lower <= upper ? lower...upper : dayRange.lowerBound...dayRange.lowerBound
}

// Extracted for regression tests: map centered selected day to leading scroll day.
func calendarLeadingDayOffsetFromCentered(
    centeredDayOffset: Int,
    daysCount: Int,
    leadingRange: ClosedRange<Int>
) -> Int {
    let centerIndex = calendarCenterSlotIndex(daysCount: daysCount)
    return clamp(centeredDayOffset - centerIndex, to: leadingRange)
}

// Extracted for regression tests: map leading scroll day to centered selected day.
func calendarCenteredDayOffsetFromLeading(
    leadingDayOffset: Int,
    daysCount: Int,
    centeredRange: ClosedRange<Int>
) -> Int {
    let centerIndex = calendarCenterSlotIndex(daysCount: daysCount)
    return clamp(leadingDayOffset + centerIndex, to: centeredRange)
}

// Extracted for regression tests: disable timeslot snap while horizontal boundary drag is active.
func calendarShouldDisableTimeslotSnap(
    isHorizontalEdgeDragging: Bool,
    isHorizontalAutoScrolling: Bool
) -> Bool {
    isHorizontalEdgeDragging || isHorizontalAutoScrolling
}

// Extracted for regression tests: map hour height to legend/grid granularity.
func calendarLegendSlotMinutes(forHourHeight hourHeight: CGFloat) -> Int {
    if hourHeight >= 76 {
        return 30
    }
    if hourHeight <= 44 {
        return 120
    }
    return 60
}

// Extracted for regression tests: velocity for temporal stretch driven by legend drag distance.
func calendarTemporalStretchVelocity(
    dragDeltaY: CGFloat,
    deadZone: CGFloat = 10,
    saturationDistance: CGFloat = 220,
    maxSpeed: CGFloat = 48
) -> CGFloat {
    guard maxSpeed > 0 else { return 0 }

    let effectiveDeadZone = max(0, deadZone)
    let effectiveSaturation = max(effectiveDeadZone + 1, saturationDistance)
    let absoluteDistance = abs(dragDeltaY)
    guard absoluteDistance > effectiveDeadZone else { return 0 }

    let normalized = min(
        1,
        (absoluteDistance - effectiveDeadZone) / (effectiveSaturation - effectiveDeadZone)
    )
    let speed = normalized * maxSpeed

    // Upward drag expands (positive speed), downward drag shrinks (negative speed).
    return dragDeltaY < 0 ? speed : -speed
}

// Extracted for regression tests: integrate one temporal stretch tick and clamp to valid bounds.
func calendarTemporalStretchHourHeightAfterTick(
    currentHourHeight: CGFloat,
    dragDeltaY: CGFloat,
    deltaTime: CFTimeInterval,
    minHourHeight: CGFloat = calendarTimelineHourHeightMin,
    maxHourHeight: CGFloat = calendarTimelineHourHeightMax,
    deadZone: CGFloat = 10,
    saturationDistance: CGFloat = 220,
    maxSpeed: CGFloat = 48
) -> CGFloat {
    let clampedCurrent = min(max(currentHourHeight, minHourHeight), maxHourHeight)
    guard deltaTime > 0 else { return clampedCurrent }

    let velocity = calendarTemporalStretchVelocity(
        dragDeltaY: dragDeltaY,
        deadZone: deadZone,
        saturationDistance: saturationDistance,
        maxSpeed: maxSpeed
    )
    guard velocity != 0 else { return clampedCurrent }

    let proposed = clampedCurrent + velocity * CGFloat(deltaTime)
    return min(max(proposed, minHourHeight), maxHourHeight)
}

// Extracted for regression tests: determine pinch intent from magnification scale.
// Returns -1 for pinch in (fewer days), +1 for pinch out (more days), 0 for no step.
func calendarRangeModeStepFromPinchScale(
    scale: CGFloat,
    threshold: CGFloat = 0.12
) -> Int {
    guard scale.isFinite, scale > 0 else { return 0 }

    let effectiveThreshold = max(0, threshold)
    if scale <= (1 - effectiveThreshold) {
        return -1
    }
    if scale >= (1 + effectiveThreshold) {
        return 1
    }
    return 0
}

// Extracted for regression tests: apply one pinch step to day-range mode with boundary clamp.
func calendarRangeModeAfterPinchStep(
    current: RangeMode,
    step: Int
) -> RangeMode {
    guard step != 0 else { return current }

    switch (current, step) {
    case (.day, let s) where s < 0:
        return .day
    case (.day, _):
        return .threeDay
    case (.threeDay, let s) where s < 0:
        return .day
    case (.threeDay, _):
        return .week
    case (.week, let s) where s > 0:
        return .week
    case (.week, _):
        return .threeDay
    }
}

// Extracted for regression tests: boundary overscale progress when pinch keeps pushing past limits.
func calendarPinchBoundaryResistanceProgress(
    scale: CGFloat,
    step: Int,
    threshold: CGFloat = 0.12,
    saturationOvershoot: CGFloat = 0.28
) -> CGFloat {
    guard scale.isFinite, scale > 0, step != 0 else { return 0 }

    let effectiveThreshold = max(0, threshold)
    let effectiveSaturation = max(0.01, saturationOvershoot)
    let overshoot: CGFloat
    if step < 0 {
        overshoot = (1 - scale) - effectiveThreshold
    } else {
        overshoot = (scale - 1) - effectiveThreshold
    }

    guard overshoot > 0 else { return 0 }
    let normalized = min(1, overshoot / effectiveSaturation)
    // Smoothstep gives gentler onset/release so boundary elasticity feels less abrupt.
    return normalized * normalized * (3 - 2 * normalized)
}

// Extracted for regression tests: visual scale used by pinch boundary resistance feedback.
func calendarPinchBoundaryVisualScale(
    step: Int,
    resistanceProgress: CGFloat,
    maxVisualDelta: CGFloat = 0.05
) -> CGFloat {
    guard step != 0 else { return 1 }
    let progress = clamp(resistanceProgress, 0, 1)
    let eased = sin(progress * .pi / 2)
    let delta = max(0, maxVisualDelta) * eased
    return step < 0 ? (1 - delta) : (1 + delta)
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
    @Binding var rangeMode: RangeMode
    @Binding var hourHeight: CGFloat
    let mode: PageMode
    let dayRange: ClosedRange<Int>
    var previewCreation: PendingEventCreation? = nil
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset, CGFloat) -> Void)? = nil
    var onEventResizeEnded: ((Event, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)? = nil
    var onCreateEvent: ((Date, Event.TimeRange) -> Void)? = nil
    var onHourHeightCommit: (() -> Void)? = nil

    var body: some View {
        TimelinePagerView(
            occurrencesForOffset: occurrencesForOffset,
            selectedDayOffset: $selectedDayOffset,
            rangeMode: $rangeMode,
            hourHeight: $hourHeight,
            daysCount: daysCount,
            mode: mode,
            showEventText: showEventText,
            dayRange: dayRange,
            previewCreation: previewCreation,
            onEventTap: onEventTap,
            onEventDragEnded: onEventDragEnded,
            onEventResizeEnded: onEventResizeEnded,
            onCreateEvent: onCreateEvent,
            onHourHeightCommit: onHourHeightCommit
        )
    }

    private var daysCount: Int {
        switch rangeMode {
        case .day: return 1
        case .threeDay: return 3
        case .week: return 7
        }
    }

    private var showEventText: Bool {
        switch rangeMode {
        case .day, .threeDay: return true
        case .week: return false
        }
    }
}

@available(iOS 17.0, *)
private extension View {
    @ViewBuilder
    func calendarApplyPersistentHorizontalSlotSnap(enabled: Bool) -> some View {
        if enabled {
            self.scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        } else {
            self
        }
    }
}

// MARK: - Timeline Pager (ScrollView)

private struct TimelinePagerView: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    @Binding var rangeMode: RangeMode
    @Binding var hourHeight: CGFloat
    let daysCount: Int
    let mode: PageMode
    let showEventText: Bool
    let dayRange: ClosedRange<Int>
    var previewCreation: PendingEventCreation? = nil
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset, CGFloat) -> Void)? = nil
    var onEventResizeEnded: ((Event, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)? = nil
    var onCreateEvent: ((Date, Event.TimeRange) -> Void)? = nil
    var onHourHeightCommit: (() -> Void)? = nil

    // Layout Constants
    private let labelWidth: CGFloat = 32
    private let daySpacing: CGFloat = 12
    private let eventHorizontalInset: CGFloat = 0
    private let scrollHorizontalPadding: CGFloat = 0
    private let timelineEdgePadding: CGFloat = 6
    private let headerHeight: CGFloat = 0

    // Computed
    private var isSingleDay: Bool { daysCount == 1 }
    private var showDayLabel: Bool { mode == .edit }
    private var labelBarHeight: CGFloat { showDayLabel ? 18 : 0 }
    private var labelBarSpacing: CGFloat { showDayLabel ? 6 : 0 }
    private var slotMinutes: Int { calendarLegendSlotMinutes(forHourHeight: hourHeight) }
    private var slotHeight: CGFloat { hourHeight * CGFloat(slotMinutes) / 60 }
    private var slotCount: Int { max(1, Int((24 * 60) / slotMinutes) + 1) }
    private var timelineHeight: CGFloat { headerHeight + CGFloat(slotCount) * slotHeight }
    private var totalHeight: CGFloat { labelBarHeight + timelineHeight }

    // Scroll State
    @State private var hasScrolledToInitial = false
    @State private var isRestoringScroll = true
    @State private var pendingScrollTarget: Int? = nil
    @State private var isUserScrollUpdating = false
    @State private var latestHorizontalContentOffsetX: CGFloat = 0
    @State private var previousHorizontalAutoScrolling: Bool = false
    @State private var pendingSnapAfterAutoScrollStop: Bool = false
    @State private var lastHorizontalScrollDebugTimestamp: CFTimeInterval = 0

    // Drag State (shared across all day views for cross-day event sync)
    @StateObject private var dragState = EventDragState()
    @State private var isRangePinchActive = false
    @State private var rangePinchReferenceScale: CGFloat = 1
    @State private var rangePinchBoundaryProgress: CGFloat = 0
    @State private var rangePinchBoundaryStep: Int = 0
    @State private var rangePinchBoundaryLatched = false
    @State private var rangePinchDidSwitchMode = false
    @State private var rangePinchSelectionHaptic = UISelectionFeedbackGenerator()
    @State private var rangePinchBoundaryHaptic = UIImpactFeedbackGenerator(style: .soft)
    @State private var isTemporalStretchActive = false
    @State private var temporalStretchDragDeltaY: CGFloat = 0
    @State private var temporalStretchLastStepIndex: Int = 0
    @State private var temporalStretchLastSlotMinutes: Int = 60
    @State private var temporalStretchHitLowerBound = false
    @State private var temporalStretchHitUpperBound = false
    @State private var temporalStretchStartHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var temporalStretchStepHaptic = UISelectionFeedbackGenerator()
    @State private var temporalStretchMilestoneHaptic = UIImpactFeedbackGenerator(style: .soft)
    @State private var temporalStretchBoundaryHaptic = UIImpactFeedbackGenerator(style: .rigid)

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width - labelWidth - timelineEdgePadding * 2)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, timelineEdgePadding)
            .scaleEffect(x: rangePinchVisualScale, y: rangePinchVisualScaleY, anchor: .center)
            .simultaneousGesture(rangePinchGesture)
        }
        .frame(height: totalHeight, alignment: .top)
    }

    // MARK: - Time Axis

    @ViewBuilder
    private func timeAxis(labelRowHeight: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            if showDayLabel {
                VStack(spacing: labelBarSpacing) {
                    Color.clear.frame(height: labelRowHeight)
                    TimeAxisLabels(
                        headerHeight: headerHeight,
                        hourHeight: hourHeight,
                        slotMinutes: slotMinutes,
                        mode: mode
                    )
                    .frame(height: timelineHeight, alignment: .top)
                }
            } else {
                TimeAxisLabels(
                    headerHeight: headerHeight,
                    hourHeight: hourHeight,
                    slotMinutes: slotMinutes,
                    mode: mode
                )
            }

            TemporalStretchLegendGesture(
                minimumPressDuration: 0.3,
                onBegan: {
                    isTemporalStretchActive = true
                    temporalStretchDragDeltaY = 0
                    temporalStretchLastStepIndex = temporalStretchStepIndex(for: hourHeight)
                    temporalStretchLastSlotMinutes = slotMinutes
                    temporalStretchHitLowerBound = hourHeight <= calendarTimelineHourHeightMin + temporalStretchBoundaryEpsilon
                    temporalStretchHitUpperBound = hourHeight >= calendarTimelineHourHeightMax - temporalStretchBoundaryEpsilon
                    temporalStretchStartHaptic.prepare()
                    temporalStretchStartHaptic.impactOccurred(intensity: 0.75)
                    temporalStretchStepHaptic.prepare()
                    temporalStretchMilestoneHaptic.prepare()
                    temporalStretchBoundaryHaptic.prepare()
                },
                onChanged: { deltaY in
                    temporalStretchDragDeltaY = deltaY
                },
                onTick: { deltaTime, deltaY in
                    temporalStretchDragDeltaY = deltaY
                    let previous = hourHeight
                    let next = calendarTemporalStretchHourHeightAfterTick(
                        currentHourHeight: previous,
                        dragDeltaY: deltaY,
                        deltaTime: deltaTime
                    )
                    updateTemporalStretchHaptics(previousHourHeight: previous, newHourHeight: next)
                    hourHeight = next
                },
                onEnded: {
                    temporalStretchDragDeltaY = 0
                    isTemporalStretchActive = false
                    onHourHeightCommit?()
                },
                onCancelled: {
                    temporalStretchDragDeltaY = 0
                    isTemporalStretchActive = false
                    onHourHeightCommit?()
                }
            )

            if isTemporalStretchActive {
                temporalStretchHUD
                    .padding(.trailing, 4)
                    .padding(.top, showDayLabel ? labelRowHeight + labelBarSpacing + 8 : 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isTemporalStretchActive)
    }

    private let rangePinchStepThreshold: CGFloat = 0.12
    private let rangePinchSaturationOvershoot: CGFloat = 0.28
    private let rangePinchBoundaryFollowFactor: CGFloat = 0.35

    private var rangePinchVisualScale: CGFloat {
        calendarPinchBoundaryVisualScale(
            step: rangePinchBoundaryStep,
            resistanceProgress: rangePinchBoundaryProgress
        )
    }

    private var rangePinchVisualScaleY: CGFloat {
        guard rangePinchBoundaryStep != 0 else { return 1 }
        let eased = sin(clamp(rangePinchBoundaryProgress, 0, 1) * .pi / 2)
        let delta: CGFloat = 0.018 * eased
        return rangePinchBoundaryStep < 0 ? (1 + delta) : (1 - delta)
    }

    private var rangePinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                handleRangePinchChanged(scale: value)
            }
            .onEnded { _ in
                handleRangePinchEnded()
            }
    }

    private func handleRangePinchChanged(scale rawScale: CGFloat) {
        let safeScale = max(0.01, rawScale)
        if !isRangePinchActive {
            isRangePinchActive = true
            rangePinchReferenceScale = safeScale
            rangePinchBoundaryProgress = 0
            rangePinchBoundaryStep = 0
            rangePinchBoundaryLatched = false
            rangePinchDidSwitchMode = false
            rangePinchSelectionHaptic.prepare()
            rangePinchBoundaryHaptic.prepare()
        }

        let referenceScale = max(0.01, rangePinchReferenceScale)
        let effectiveScale = safeScale / referenceScale
        let step = calendarRangeModeStepFromPinchScale(
            scale: effectiveScale,
            threshold: rangePinchStepThreshold
        )

        if rangePinchDidSwitchMode {
            updateRangePinchBoundaryProgress(toward: 0)
            rangePinchBoundaryStep = 0
            rangePinchBoundaryLatched = false
            return
        }

        guard step != 0 else {
            updateRangePinchBoundaryProgress(toward: 0)
            rangePinchBoundaryStep = 0
            rangePinchBoundaryLatched = false
            return
        }

        let nextMode = calendarRangeModeAfterPinchStep(
            current: rangeMode,
            step: step
        )
        if nextMode != rangeMode {
            rangeMode = nextMode
            rangePinchDidSwitchMode = true
            rangePinchReferenceScale = safeScale
            rangePinchBoundaryProgress = 0
            rangePinchBoundaryStep = 0
            rangePinchBoundaryLatched = false
            rangePinchSelectionHaptic.selectionChanged()
            rangePinchSelectionHaptic.prepare()
            return
        }

        if rangePinchBoundaryStep != step {
            rangePinchBoundaryLatched = false
        }
        rangePinchBoundaryStep = step
        let resistanceProgress = calendarPinchBoundaryResistanceProgress(
            scale: effectiveScale,
            step: step,
            threshold: rangePinchStepThreshold,
            saturationOvershoot: rangePinchSaturationOvershoot
        )
        updateRangePinchBoundaryProgress(toward: resistanceProgress)

        if resistanceProgress > 0, !rangePinchBoundaryLatched {
            rangePinchBoundaryLatched = true
            rangePinchBoundaryHaptic.impactOccurred(intensity: 0.65)
            rangePinchBoundaryHaptic.prepare()
        } else if resistanceProgress == 0 {
            rangePinchBoundaryLatched = false
        }
    }

    private func handleRangePinchEnded() {
        isRangePinchActive = false
        rangePinchReferenceScale = 1
        rangePinchBoundaryLatched = false
        rangePinchBoundaryStep = 0
        rangePinchDidSwitchMode = false

        if rangePinchBoundaryProgress == 0 {
            return
        }

        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
            rangePinchBoundaryProgress = 0
        }
    }

    private func updateRangePinchBoundaryProgress(toward target: CGFloat) {
        let clampedTarget = clamp(target, 0, 1)
        let next = rangePinchBoundaryProgress + (clampedTarget - rangePinchBoundaryProgress) * rangePinchBoundaryFollowFactor
        rangePinchBoundaryProgress = clamp(next, 0, 1)
    }

    // MARK: - Scroll Content (Unified for Single/Multi Day)

    @ViewBuilder
    private func scrollContent(dayWidth: CGFloat, dayFrameWidth: CGFloat, labelRowHeight: CGFloat, spacing: CGFloat) -> some View {
        let leadingRange = leadingOffsetsRange()
        let centeredRange = centeredOffsetsRange()
        let step = dayFrameWidth + spacing
        let isMoveDragActive = calendarIsMoveDragActive(
            draggingEventID: dragState.draggingEventID,
            dragMode: dragState.dragMode
        )
        let isHorizontalSlotSnapDisabled = isMoveDragActive && calendarShouldDisableHorizontalScrollSnap(
            isHorizontalEdgeDragging: dragState.isHorizontalEdgeDragging,
            isHorizontalAutoScrolling: dragState.isHorizontalAutoScrolling
        )
        let shouldEnablePersistentHorizontalSlotSnap = calendarShouldEnablePersistentHorizontalSlotSnap(
            isMoveDragActive: isMoveDragActive,
            isHorizontalSlotSnapDisabled: isHorizontalSlotSnapDisabled
        )

        ScrollViewReader { scrollProxy in
            let snapToNearestDaySlot: () -> Void = {
                guard step > 0 else { return }
                let clampedLeading = calendarNearestLeadingDayOffset(
                    contentOffsetX: latestHorizontalContentOffsetX,
                    step: step,
                    leadingRange: leadingRange
                )
                let centered = calendarCenteredDayOffsetFromLeading(
                    leadingDayOffset: clampedLeading,
                    daysCount: daysCount,
                    centeredRange: centeredRange
                )
                pendingScrollTarget = clampedLeading
                isRestoringScroll = true
                let visibleDate = Calendar.current.date(
                    byAdding: .day,
                    value: centered,
                    to: Calendar.current.startOfDay(for: Date())
                ) ?? Date()
                calendarDebugLog(
                    "timeline.snapToNearestDaySlot",
                    fields: [
                        "centeredOffset": "\(centered)",
                        "leadingOffset": "\(clampedLeading)",
                        "visibleDate": calendarDebugDayString(visibleDate),
                        "contentOffsetX": String(format: "%.2f", latestHorizontalContentOffsetX),
                        "step": String(format: "%.2f", step)
                    ]
                )
                if selectedDayOffset != centered {
                    selectedDayOffset = centered
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo(clampedLeading, anchor: .leading)
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
            .calendarApplyPersistentHorizontalSlotSnap(
                enabled: shouldEnablePersistentHorizontalSlotSnap
            )
            .scrollIndicators(.hidden)
            .onAppear {
                guard !hasScrolledToInitial else { return }
                hasScrolledToInitial = true
                previousHorizontalAutoScrolling = dragState.isHorizontalAutoScrolling
                let clampedCentered = clamp(selectedDayOffset, to: centeredRange)
                if clampedCentered != selectedDayOffset { selectedDayOffset = clampedCentered }
                let clampedLeading = calendarLeadingDayOffsetFromCentered(
                    centeredDayOffset: clampedCentered,
                    daysCount: daysCount,
                    leadingRange: leadingRange
                )
                pendingScrollTarget = clampedLeading
                isRestoringScroll = true
                let visibleDate = Calendar.current.date(
                    byAdding: .day,
                    value: clampedCentered,
                    to: Calendar.current.startOfDay(for: Date())
                ) ?? Date()
                calendarDebugLog(
                    "timeline.onAppear",
                    fields: [
                        "selectedDayOffset": "\(clampedCentered)",
                        "visibleDate": calendarDebugDayString(visibleDate),
                        "leadingOffset": "\(clampedLeading)",
                        "daysCount": "\(daysCount)",
                        "step": String(format: "%.2f", step),
                        "persistentSnapEnabled": "\(shouldEnablePersistentHorizontalSlotSnap)"
                    ]
                )
                // Defer to next run loop so LazyHStack layout is finalized
                DispatchQueue.main.async {
                    scrollProxy.scrollTo(clampedLeading, anchor: .leading)
                }
            }
            .onChange(of: selectedDayOffset) { newValue in
                if isUserScrollUpdating {
                    isUserScrollUpdating = false
                    return
                }
                let clampedCentered = clamp(newValue, to: centeredRange)
                if clampedCentered != selectedDayOffset {
                    selectedDayOffset = clampedCentered
                }
                let clampedLeading = calendarLeadingDayOffsetFromCentered(
                    centeredDayOffset: clampedCentered,
                    daysCount: daysCount,
                    leadingRange: leadingRange
                )
                pendingScrollTarget = clampedLeading
                isRestoringScroll = true
                let visibleDate = Calendar.current.date(
                    byAdding: .day,
                    value: clampedCentered,
                    to: Calendar.current.startOfDay(for: Date())
                ) ?? Date()
                calendarDebugLog(
                    "timeline.selectedDayOffsetChanged",
                    fields: [
                        "newOffset": "\(newValue)",
                        "clampedOffset": "\(clampedCentered)",
                        "visibleDate": calendarDebugDayString(visibleDate),
                        "leadingOffset": "\(clampedLeading)"
                    ]
                )
                scrollProxy.scrollTo(clampedLeading, anchor: .leading)
            }
            .onChange(of: dayRange) { _ in
                let clampedCentered = clamp(selectedDayOffset, to: centeredRange)
                if clampedCentered != selectedDayOffset { selectedDayOffset = clampedCentered }
                let clampedLeading = calendarLeadingDayOffsetFromCentered(
                    centeredDayOffset: clampedCentered,
                    daysCount: daysCount,
                    leadingRange: leadingRange
                )
                pendingScrollTarget = clampedLeading
                isRestoringScroll = true
                scrollProxy.scrollTo(clampedLeading, anchor: .leading)
            }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
                guard step > 0 else { return }
                latestHorizontalContentOffsetX = newValue.contentOffset.x
                let isMoveDragActiveNow = calendarIsMoveDragActive(
                    draggingEventID: dragState.draggingEventID,
                    dragMode: dragState.dragMode
                )
                let freezeSelectedDayOffset = calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
                    isMoveDragActive: isMoveDragActiveNow,
                    isHorizontalAutoScrolling: dragState.isHorizontalAutoScrolling
                )
                let now = CACurrentMediaTime()
                if now - lastHorizontalScrollDebugTimestamp >= 0.12 {
                    lastHorizontalScrollDebugTimestamp = now
                    let visibleDate = Calendar.current.date(
                        byAdding: .day,
                        value: selectedDayOffset,
                        to: Calendar.current.startOfDay(for: Date())
                    ) ?? Date()
                    calendarDebugLog(
                        "timeline.scrollGeometry",
                        fields: [
                            "contentOffsetX": String(format: "%.2f", newValue.contentOffset.x),
                            "selectedDayOffset": "\(selectedDayOffset)",
                            "visibleDate": calendarDebugDayString(visibleDate),
                            "isRestoring": "\(isRestoringScroll)",
                            "pendingTarget": pendingScrollTarget.map(String.init) ?? "nil",
                            "moveDragActive": "\(isMoveDragActiveNow)",
                            "freezeSelectedDayOffset": "\(freezeSelectedDayOffset)"
                        ]
                    )
                }
                if isRestoringScroll {
                    guard let target = pendingScrollTarget else { return }
                    let targetIndex = target - leadingRange.lowerBound
                    let targetX = CGFloat(targetIndex) * step
                    if abs(newValue.contentOffset.x - targetX) > step * 0.5 { return }
                    isRestoringScroll = false
                    pendingScrollTarget = nil
                }
                if freezeSelectedDayOffset {
                    calendarDebugLog(
                        "timeline.selectedDayOffset.freezeDuringMoveDrag",
                        fields: [
                            "contentOffsetX": String(format: "%.2f", newValue.contentOffset.x),
                            "isHorizontalAutoScrolling": "\(dragState.isHorizontalAutoScrolling)",
                            "selectedDayOffset": "\(selectedDayOffset)",
                            "visibleDate": calendarDebugDayString(
                                Calendar.current.date(
                                    byAdding: .day,
                                    value: selectedDayOffset,
                                    to: Calendar.current.startOfDay(for: Date())
                                ) ?? Date()
                            )
                        ]
                    )
                    return
                }
                let clampedLeading = calendarNearestLeadingDayOffset(
                    contentOffsetX: newValue.contentOffset.x,
                    step: step,
                    leadingRange: leadingRange
                )
                let centered = calendarCenteredDayOffsetFromLeading(
                    leadingDayOffset: clampedLeading,
                    daysCount: daysCount,
                    centeredRange: centeredRange
                )
                if selectedDayOffset != centered {
                    isUserScrollUpdating = true
                    selectedDayOffset = centered
                }
                consumePendingAutoStopSnapIfPossible()
            }
            .onScrollPhaseChange { _, newPhase in
                let isMoveDragActiveNow = calendarIsMoveDragActive(
                    draggingEventID: dragState.draggingEventID,
                    dragMode: dragState.dragMode
                )
                let isHorizontalSlotSnapDisabledNow = isMoveDragActiveNow && calendarShouldDisableHorizontalScrollSnap(
                    isHorizontalEdgeDragging: dragState.isHorizontalEdgeDragging,
                    isHorizontalAutoScrolling: dragState.isHorizontalAutoScrolling
                )
                let visibleDate = Calendar.current.date(
                    byAdding: .day,
                    value: selectedDayOffset,
                    to: Calendar.current.startOfDay(for: Date())
                ) ?? Date()
                calendarDebugLog(
                    "timeline.scrollPhase",
                    fields: [
                        "phase": String(describing: newPhase),
                        "selectedDayOffset": "\(selectedDayOffset)",
                        "visibleDate": calendarDebugDayString(visibleDate),
                        "isRestoring": "\(isRestoringScroll)",
                        "snapDisabled": "\(isHorizontalSlotSnapDisabledNow)",
                        "moveDragActive": "\(isMoveDragActiveNow)"
                    ]
                )
                guard newPhase == .idle else { return }
                guard step > 0 else { return }
                guard !isRestoringScroll else { return }
                consumePendingAutoStopSnapIfPossible()
                guard !isRestoringScroll else { return }
                guard !isHorizontalSlotSnapDisabledNow else { return }
                guard calendarShouldRunGeneralHorizontalSlotSnap(isMoveDragActive: isMoveDragActiveNow) else { return }
                snapToNearestDaySlot()
            }
            .onChange(of: isHorizontalSlotSnapDisabled) { isDisabled in
                guard !isDisabled else { return }
                let isMoveDragActiveNow = calendarIsMoveDragActive(
                    draggingEventID: dragState.draggingEventID,
                    dragMode: dragState.dragMode
                )
                consumePendingAutoStopSnapIfPossible()
                guard step > 0 else { return }
                guard !isRestoringScroll else { return }
                guard calendarShouldRunGeneralHorizontalSlotSnap(isMoveDragActive: isMoveDragActiveNow) else { return }
                snapToNearestDaySlot()
            }
            .onChange(of: dragState.draggingEventID) { _ in
                // New drag sessions must start from a clean auto-scroll transition state.
                previousHorizontalAutoScrolling = dragState.isHorizontalAutoScrolling
                pendingSnapAfterAutoScrollStop = false
                calendarDebugLog(
                    "timeline.dragSession.changed",
                    fields: [
                        "draggingEventID": dragState.draggingEventID?.uuidString ?? "nil",
                        "isHorizontalAutoScrolling": "\(dragState.isHorizontalAutoScrolling)"
                    ]
                )
            }
            .onChange(of: dragState.isHorizontalAutoScrolling) { isAutoScrolling in
                let shouldSnap = calendarShouldSnapImmediatelyAfterHorizontalAutoScrollStop(
                    previousIsHorizontalAutoScrolling: previousHorizontalAutoScrolling,
                    currentIsHorizontalAutoScrolling: isAutoScrolling
                )
                previousHorizontalAutoScrolling = isAutoScrolling
                calendarDebugLog(
                    "timeline.horizontalAutoScrollState",
                    fields: [
                        "isAutoScrolling": "\(isAutoScrolling)",
                        "shouldSnapAfterStop": "\(shouldSnap)",
                        "selectedDayOffset": "\(selectedDayOffset)"
                    ]
                )
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
                    slotMinutes: slotMinutes,
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
                slotMinutes: slotMinutes,
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

    private func centeredOffsetsRange() -> ClosedRange<Int> {
        calendarCenteredDayOffsetRange(dayRange: dayRange, daysCount: daysCount)
    }

    private var temporalStretchHUD: some View {
        let velocity = calendarTemporalStretchVelocity(dragDeltaY: temporalStretchDragDeltaY)
        let direction = temporalStretchDirectionLabel(forVelocity: velocity)

        return VStack(alignment: .trailing, spacing: 2) {
            Text("Temporal Stretch")
                .font(.system(size: 10, weight: .semibold))
            Text(direction)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Slot \(slotMinutes)m")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    private func temporalStretchDirectionLabel(forVelocity velocity: CGFloat) -> String {
        if velocity > 0 {
            return "Expanding"
        }
        if velocity < 0 {
            return "Shrinking"
        }
        return "Hold"
    }

    private var temporalStretchBoundaryEpsilon: CGFloat { 0.001 }
    private var temporalStretchStepSize: CGFloat { 4 }

    private func temporalStretchStepIndex(for height: CGFloat, stepSize: CGFloat? = nil) -> Int {
        let resolvedStep = stepSize ?? temporalStretchStepSize
        guard resolvedStep > 0 else { return 0 }
        return Int(floor(height / resolvedStep))
    }

    private func updateTemporalStretchHaptics(previousHourHeight: CGFloat, newHourHeight: CGFloat) {
        guard abs(newHourHeight - previousHourHeight) > 0.0001 else { return }

        let nextStepIndex = temporalStretchStepIndex(for: newHourHeight)
        if nextStepIndex != temporalStretchLastStepIndex {
            temporalStretchLastStepIndex = nextStepIndex
            temporalStretchStepHaptic.selectionChanged()
            temporalStretchStepHaptic.prepare()
        }

        let nextSlotMinutes = calendarLegendSlotMinutes(forHourHeight: newHourHeight)
        if nextSlotMinutes != temporalStretchLastSlotMinutes {
            temporalStretchLastSlotMinutes = nextSlotMinutes
            temporalStretchMilestoneHaptic.impactOccurred(intensity: 0.9)
            temporalStretchMilestoneHaptic.prepare()
        }

        let hitsLowerBound = newHourHeight <= calendarTimelineHourHeightMin + temporalStretchBoundaryEpsilon
        let hitsUpperBound = newHourHeight >= calendarTimelineHourHeightMax - temporalStretchBoundaryEpsilon

        if hitsLowerBound && !temporalStretchHitLowerBound {
            temporalStretchHitLowerBound = true
            temporalStretchBoundaryHaptic.impactOccurred(intensity: 1.0)
            temporalStretchBoundaryHaptic.prepare()
        } else if !hitsLowerBound {
            temporalStretchHitLowerBound = false
        }

        if hitsUpperBound && !temporalStretchHitUpperBound {
            temporalStretchHitUpperBound = true
            temporalStretchBoundaryHaptic.impactOccurred(intensity: 1.0)
            temporalStretchBoundaryHaptic.prepare()
        } else if !hitsUpperBound {
            temporalStretchHitUpperBound = false
        }
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
    let slotMinutes: Int
    let mode: PageMode

    private var slotHeight: CGFloat {
        hourHeight * CGFloat(slotMinutes) / 60
    }

    private var slotCount: Int {
        max(1, Int((24 * 60) / slotMinutes) + 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headerHeight)
            ForEach(0..<slotCount, id: \.self) { index in
                Text(label(forSlot: index))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 2)
                    .frame(height: slotHeight, alignment: .topTrailing)
            }
        }
    }

    private func label(forSlot index: Int) -> String {
        let totalMinutes = min(24 * 60, index * slotMinutes)
        let normalizedTotalMinutes = totalMinutes % (24 * 60)
        let hour24 = normalizedTotalMinutes / 60
        let minute = normalizedTotalMinutes % 60
        let meridiem = hour24 < 12 ? "am" : "pm"
        let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)

        if mode == .preview && slotMinutes == 60 {
            return "\(hour12) \(meridiem)"
        }
        if minute == 0 {
            return "\(hour12) \(meridiem)"
        }
        return "\(hour12):\(String(format: "%02d", minute)) \(meridiem)"
    }
}

// MARK: - Temporal Stretch Gesture (UIKit)

private struct TemporalStretchLegendGesture: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = 0.3
    var onBegan: (() -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onTick: ((CFTimeInterval, CGFloat) -> Void)?
    var onEnded: (() -> Void)?
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
        context.coordinator.onTick = onTick
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TemporalStretchLegendGesture
        var onBegan: (() -> Void)?
        var onChanged: ((CGFloat) -> Void)?
        var onTick: ((CFTimeInterval, CGFloat) -> Void)?
        var onEnded: (() -> Void)?
        var onCancelled: (() -> Void)?

        private var startY: CGFloat = 0
        private var currentDeltaY: CGFloat = 0
        private var lastTimestamp: CFTimeInterval?
        private var isActive = false
        private var displayLink: CADisplayLink?

        init(_ parent: TemporalStretchLegendGesture) {
            self.parent = parent
            self.onBegan = parent.onBegan
            self.onChanged = parent.onChanged
            self.onTick = parent.onTick
            self.onEnded = parent.onEnded
            self.onCancelled = parent.onCancelled
        }

        deinit {
            stopDisplayLink()
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                isActive = true
                startY = location.y
                currentDeltaY = 0
                lastTimestamp = nil
                startDisplayLinkIfNeeded()
                onBegan?()
                onChanged?(0)
            case .changed:
                guard isActive else { return }
                currentDeltaY = location.y - startY
                onChanged?(currentDeltaY)
            case .ended:
                guard isActive else { return }
                stopDisplayLink()
                isActive = false
                lastTimestamp = nil
                onEnded?()
            case .cancelled, .failed:
                stopDisplayLink()
                isActive = false
                lastTimestamp = nil
                onCancelled?()
            default:
                break
            }
        }

        @objc private func handleDisplayLinkTick(_ link: CADisplayLink) {
            guard isActive else { return }
            if let lastTimestamp {
                let deltaTime = link.timestamp - lastTimestamp
                onTick?(deltaTime, currentDeltaY)
            }
            lastTimestamp = link.timestamp
        }

        private func startDisplayLinkIfNeeded() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(
                target: self,
                selector: #selector(handleDisplayLinkTick(_:))
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
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
    let slotMinutes: Int
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
        let slotHeight = hourHeight * CGFloat(slotMinutes) / 60
        let slotCount = max(1, Int((24 * 60) / slotMinutes) + 1)

        return VStack(spacing: 0) {
            Color.clear.frame(width: contentWidth, height: headerHeight, alignment: .center)
            ForEach(0..<slotCount, id: \.self) { _ in
                if style.gridDashed {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundColor(style.gridColor)
                        .frame(width: contentWidth, height: 1)
                        .frame(height: slotHeight, alignment: .top)
                } else {
                    Rectangle()
                        .fill(style.gridColor)
                        .frame(width: contentWidth, height: 1)
                        .frame(height: slotHeight, alignment: .top)
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
