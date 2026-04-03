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
    static let isEnabled: Bool = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment["CALENDAR_DEBUG_LOGGING"]
        return env == "1" || env?.lowercased() == "true"
        #else
        return false
        #endif
    }()
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

func calendarDebugLog(
    _ event: String,
    fields: @autoclosure () -> [String: String] = [:]
) {
    #if DEBUG
    guard CalendarDebugTrace.isEnabled else { return }
    CalendarDebugTrace.log(event: event, fields: fields())
    #else
    _ = event
    _ = fields
    #endif
}

func calendarDebugDayString(_ date: Date) -> String {
    CalendarDebugTrace.dayString(from: date)
}

func calendarDebugInstantString(_ date: Date) -> String {
    CalendarDebugTrace.timestampFormatter.string(from: date)
}

// MARK: - Shared Drag State

struct TimelineHorizontalScrollProgress: Equatable {
    var centeredDayOffsetContinuous: CGFloat
    var isInteracting: Bool
}

// Extracted for regression tests: keep boundary dragging unsnapped when snapping would cross day.
func calendarPreviewOffsetSeconds(
    rawOffsetSeconds: TimeInterval,
    range: Event.TimeRange,
    snapIntervalSeconds: TimeInterval = 15 * 60,
    calendar: Calendar = .current
) -> TimeInterval {
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

// Extracted for regression tests: true only while there is an active move-drag.
func calendarIsMoveDragActive(
    draggingEventID: UUID?,
    dragMode: EventDragMode
) -> Bool {
    draggingEventID != nil && dragMode == .move
}

// Extracted for regression tests: boundary-extension reflow should not animate
// while a move-drag is actively crossing day boundaries.
func calendarShouldAnimateTimelineBoundaryExtension(
    isMoveDragActive: Bool,
    isCreationDragActive: Bool,
    reduceMotion: Bool
) -> Bool {
    !reduceMotion && !isMoveDragActive && !isCreationDragActive
}

// Extracted for regression tests: when leading boundary extension toggles during
// drag-create, shift the stored gesture Y so the same finger anchor resolves to
// the same absolute time instead of being reinterpreted against a new visibleStart.
func calendarAdjustedCreationDragYForLeadingBoundaryExtensionChange(
    _ y: CGFloat,
    previousLeadingHours: Int,
    currentLeadingHours: Int,
    hourHeight: CGFloat
) -> CGFloat {
    guard y.isFinite, hourHeight.isFinite, hourHeight > 0 else { return y }
    let hourDelta = currentLeadingHours - previousLeadingHours
    guard hourDelta != 0 else { return y }
    return y + CGFloat(hourDelta) * hourHeight
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

// Extracted for regression tests: while move-drag is active, ignore selected-day
// updates from transient geometry resets, but allow updates during horizontal
// auto-scroll so the date legend can track the moving viewport.
func calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
    isMoveDragActive: Bool,
    isHorizontalEdgeDragging: Bool = false,
    isHorizontalAutoScrolling: Bool
) -> Bool {
    isMoveDragActive && !isHorizontalEdgeDragging && !isHorizontalAutoScrolling
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

// Extracted for regression tests: map horizontal content offset to a continuous
// centered-day offset so header legends can follow scroll progress.
func calendarContinuousCenteredDayOffset(
    contentOffsetX: CGFloat,
    step: CGFloat,
    leadingRange: ClosedRange<Int>,
    daysCount: Int,
    centeredRange: ClosedRange<Int>
) -> CGFloat {
    guard step > 0 else { return CGFloat(centeredRange.lowerBound) }
    let rawLeading = CGFloat(leadingRange.lowerBound) + contentOffsetX / step
    let rawCentered = rawLeading + CGFloat(calendarCenterSlotIndex(daysCount: daysCount))
    let minCentered = CGFloat(centeredRange.lowerBound)
    let maxCentered = CGFloat(centeredRange.upperBound)
    return min(max(rawCentered, minCentered), maxCentered)
}

// Extracted for regression tests: ignore layout-driven scroll resets when the user
// is not actively paging and no edge/auto drag is driving horizontal motion.
func calendarShouldAdoptScrollDrivenDayOffset(
    isScrollInteracting: Bool,
    isHorizontalEdgeDragging: Bool = false,
    isHorizontalAutoScrolling: Bool = false
) -> Bool {
    isScrollInteracting || isHorizontalEdgeDragging || isHorizontalAutoScrolling
}

// Extracted for regression tests: require explicit drag movement after long-press before creating.
func calendarShouldActivateCreationAfterLongPress(
    dragDeltaY: CGFloat,
    threshold: CGFloat = 18
) -> Bool {
    abs(dragDeltaY) >= max(0, threshold)
}

// Extracted for regression tests: once an event is focused, focus visuals stay active
// until focus is explicitly cleared.
func calendarIsFocusVisualContextActive(
    focusedEventID: UUID?,
    visibleEventIDs: Set<UUID>,
    draggingEventID: UUID? = nil,
    isMoveDragActive: Bool = false
) -> Bool {
    focusedEventID != nil
}

// Extracted for regression tests: once focus context is active, only the
// focused event should remain interactive.
func calendarShouldAllowEventInteraction(
    focusedEventID: UUID?,
    candidateEventID: UUID,
    isFocusContextActive: Bool
) -> Bool {
    guard isFocusContextActive, let focusedEventID else { return true }
    return focusedEventID == candidateEventID
}

// Extracted for regression tests: provide headroom above earliest visible slot.
func calendarTimelineTopInset(hourHeight: CGFloat) -> CGFloat {
    max(14, round(hourHeight * 0.28))
}

// Extracted for regression tests: provide breathing space below midnight.
func calendarTimelineBottomInset(hourHeight: CGFloat) -> CGFloat {
    max(20, round(hourHeight * 0.40))
}

// Extracted for regression tests: now-indicator is rendered only on today's column.
func calendarShouldShowNowIndicator(
    for day: Date,
    now: Date = Date(),
    calendar: Calendar = .current
) -> Bool {
    calendar.isDate(day, inSameDayAs: now)
}

// Extracted for regression tests: clamp current-time pointer to the 24h lane.
func calendarNowIndicatorYOffset(
    now: Date,
    day: Date,
    headerHeight: CGFloat,
    hourHeight: CGFloat,
    calendar: Calendar = .current
) -> CGFloat {
    let dayStart = calendar.startOfDay(for: day)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
    let clampedNow = min(max(now, dayStart), dayEnd)
    let secondsSinceStart = max(0, clampedNow.timeIntervalSince(dayStart))
    let y = headerHeight + CGFloat(secondsSinceStart / 3600) * hourHeight
    return min(max(headerHeight, y), headerHeight + CGFloat(calendarTimelineBaseVisibleHours) * hourHeight)
}

// Extracted for regression tests: map hour height to legend/grid granularity.
func calendarLegendSlotMinutes(forHourHeight hourHeight: CGFloat) -> Int {
    if hourHeight >= 76 {
        return 30
    }
    return 60
}

// Extracted for regression tests: hide overlapping hour legend when current-time label collides.
func calendarShouldHideLegendHourLabel(
    legendTotalMinutes: Int,
    nowTotalMinutes: CGFloat,
    hourHeight: CGFloat,
    collisionThresholdPoints: CGFloat = 10
) -> Bool {
    guard hourHeight > 0 else { return false }

    let legendY = CGFloat(legendTotalMinutes) * hourHeight / 60
    let nowY = nowTotalMinutes * hourHeight / 60
    return abs(nowY - legendY) <= max(0, collisionThresholdPoints)
}

// Extracted for regression tests: determine pinch direction from magnification scale.
// Returns -1 for zoom in (narrower time range), +1 for zoom out (wider time range), 0 for neutral.
func calendarPinchDirectionFromScale(
    scale: CGFloat,
    threshold: CGFloat = 0.04
) -> Int {
    guard scale.isFinite, scale > 0 else { return 0 }

    let effectiveThreshold = max(0, threshold)
    if scale >= (1 + effectiveThreshold) {
        return -1
    }
    if scale <= (1 - effectiveThreshold) {
        return 1
    }
    return 0
}

// Extracted for regression tests: apply live pinch scale to timeline hour height with boundary clamp.
func calendarTimelineHourHeightAfterPinchScale(
    initialHourHeight: CGFloat,
    scale: CGFloat,
    minHourHeight: CGFloat = calendarTimelineHourHeightMin,
    maxHourHeight: CGFloat = calendarTimelineHourHeightMax
) -> CGFloat {
    guard initialHourHeight.isFinite, scale.isFinite, scale > 0 else {
        return min(max(initialHourHeight, minHourHeight), maxHourHeight)
    }

    let proposed = initialHourHeight * scale
    return min(max(proposed, minHourHeight), maxHourHeight)
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
        overshoot = (scale - 1) - effectiveThreshold
    } else {
        overshoot = (1 - scale) - effectiveThreshold
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
    return step < 0 ? (1 + delta) : (1 - delta)
}

/// Observable object for sharing drag state across all event blocks (for cross-day sync)
final class EventDragState: ObservableObject {
    @Published var draggingEventID: UUID? = nil
    @Published var draggingOccurrenceID: String? = nil
    @Published var draggingEvent: Event? = nil
    @Published var draggingOriginalRange: Event.TimeRange? = nil
    @Published var currentTouchPointGlobal: CGPoint? = nil
    @Published var dragOffset: DragOffset = .zero
    @Published var dragMode: EventDragMode = .move
    @Published var isHorizontalEdgeDragging: Bool = false
    @Published var isHorizontalAutoScrolling: Bool = false
    var dayColumnStep: CGFloat = 0

    /// Computed preview range based on current drag offset
    func previewRange(hourHeight: CGFloat) -> Event.TimeRange? {
        calendarResolvedDragEditRange(
            draggingOriginalRange: draggingOriginalRange,
            dragOffset: dragOffset,
            dragMode: dragMode,
            hourHeight: hourHeight,
            dayColumnStep: dayColumnStep
        )
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

// Extracted for regression tests: resolve the currently dragged occurrence to its live range
// so dependent UI, such as interrupt parent geometry, can render the same preview in realtime.
func calendarResolvedLiveOccurrenceRange(
    occurrenceID: String,
    occurrenceRange: Event.TimeRange,
    draggingOccurrenceID: String?,
    draggingOriginalRange: Event.TimeRange?,
    dragOffset: DragOffset,
    dragMode: EventDragMode,
    hourHeight: CGFloat,
    dayColumnStep: CGFloat = 0
) -> Event.TimeRange {
    guard occurrenceID == draggingOccurrenceID else {
        return occurrenceRange
    }

    return calendarResolvedDragEditRange(
        draggingOriginalRange: draggingOriginalRange ?? occurrenceRange,
        dragOffset: dragOffset,
        dragMode: dragMode,
        hourHeight: hourHeight,
        dayColumnStep: dayColumnStep
    ) ?? occurrenceRange
}

// Extracted for regression tests: keep actively move-dragged interrupt children on
// normal block geometry so leaving the embedded parent does not tear down the gesture.
func calendarShouldUseEmbeddedInterruptOverlay(
    interruptIsCurrentlyEmbedded: Bool,
    isActiveDraggedOccurrence: Bool,
    dragMode: EventDragMode
) -> Bool {
    guard interruptIsCurrentlyEmbedded else { return false }
    return !(isActiveDraggedOccurrence && dragMode == .move)
}

// Extracted for regression tests: preserve the original embedded child frame while
// an interrupt child is being actively move-dragged so the preview does not jump.
func calendarShouldUseInterruptDragSourceFrame(
    isInterruptEvent: Bool,
    relationState: EventInterruptRelationState?,
    isActiveDraggedOccurrence: Bool,
    dragMode: EventDragMode
) -> Bool {
    isInterruptEvent
        && relationState == .embedded
        && isActiveDraggedOccurrence
        && dragMode == .move
}

private func calendarCurrentTimeIndicatorColor() -> Color {
    Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : UIColor(white: 0.22, alpha: 1)
    })
}

private func calendarLegendForegroundColor(for backgroundColor: Color) -> Color {
    Color(UIColor { traits in
        let resolvedColor = UIColor(backgroundColor).resolvedColor(with: traits)
        guard let luminance = calendarRelativeLuminance(of: resolvedColor) else {
            return .white
        }
        return luminance > 0.58 ? UIColor(white: 0.12, alpha: 1) : .white
    })
}

private func calendarRelativeLuminance(of color: UIColor) -> CGFloat? {
    var white: CGFloat = 0
    var alpha: CGFloat = 0
    if color.getWhite(&white, alpha: &alpha) {
        return calendarLinearizedSRGBComponent(white)
    }

    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
        let resolvedRed = calendarLinearizedSRGBComponent(red)
        let resolvedGreen = calendarLinearizedSRGBComponent(green)
        let resolvedBlue = calendarLinearizedSRGBComponent(blue)
        return 0.2126 * resolvedRed + 0.7152 * resolvedGreen + 0.0722 * resolvedBlue
    }

    return nil
}

private func calendarLinearizedSRGBComponent(_ value: CGFloat) -> CGFloat {
    if value <= 0.04045 {
        return value / 12.92
    }
    return pow((value + 0.055) / 1.055, 2.4)
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
        gridDashed: false,
        gridColor: Color.secondary.opacity(0.15)
    )
}

// MARK: - Helpers (previously computed inside TimelineContainerView)

func timelineDaysCount(for rangeMode: RangeMode) -> Int {
    switch rangeMode {
    case .day: return 1
    case .threeDay: return 3
    case .week: return 7
    case .month: return 7
    }
}

func timelineShowEventText(for rangeMode: RangeMode) -> Bool {
    switch rangeMode {
    case .day, .threeDay: return true
    case .week: return true
    case .month: return false
    }
}

func calendarTimelineResolvedCenteredDayOffset(
    requestedDayOffset: Int,
    centeredRange: ClosedRange<Int>,
    deferOutOfRangeSelection: Bool = true
) -> Int? {
    if deferOutOfRangeSelection && !centeredRange.contains(requestedDayOffset) {
        return nil
    }
    return clamp(requestedDayOffset, to: centeredRange)
}

@available(iOS 17.0, *)
private extension View {
    @ViewBuilder
    func calendarApplyPersistentHorizontalSlotSnap(enabled: Bool) -> some View {
        if enabled {
            self.scrollTargetBehavior(.viewAligned(limitBehavior: .automatic))
        } else {
            self
        }
    }
}

// MARK: - Timeline Pager (ScrollView)

struct TimelinePagerView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(AppSettingsLocale.timeFormatKey) private var timeFormatRaw = AppTimeFormat.twentyFour.rawValue
    @ObservedObject var dragState: EventDragState
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    var allDayOccurrencesForOffset: ((Int) -> [CalendarLayout.EventOccurrence])? = nil
    @Binding var selectedDayOffset: Int
    @Binding var rangeMode: RangeMode
    @Binding var hourHeight: CGFloat
    var isDayOffsetFrozen: Bool = false
    let daysCount: Int
    let mode: PageMode
    let showEventText: Bool
    let dayRange: ClosedRange<Int>
    var previewCreation: PendingEventCreation? = nil
    var focusedEventID: UUID? = nil
    var focusedOccurrenceID: String? = nil
    var previewHandleEventID: UUID? = nil
    var previewHandleOccurrenceID: String? = nil
    var previewHandleOpacity: Double = 1
    var graceResizeEventID: UUID? = nil
    var graceResizeOccurrenceID: String? = nil
    var graceResizeHandleOpacity: Double = 1
    var onEventTap: ((Event, Date) -> Void)? = nil
    var onEventLongPressBegan: ((CalendarEventLongPressBegan) -> Void)? = nil
    var onEventManipulationPromotion: ((Event, String?, Date, EventDragMode, CGPoint, CGRect) -> Void)? = nil
    var onEventLongPressResolved: ((CalendarEventLongPressResolution) -> Void)? = nil
    var onEventDragEnded: ((Event, String?, Event.TimeRange, DragOffset, CGFloat) -> Void)? = nil
    var onEventResizeEnded: ((Event, String?, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)? = nil
    var onCreateEvent: ((Date, Event.TimeRange) -> Void)? = nil
    var onNonEventTap: (() -> Void)? = nil
    var onHourHeightCommit: (() -> Void)? = nil
    var onHorizontalScrollProgress: ((TimelineHorizontalScrollProgress) -> Void)? = nil
    var onBoundaryExtensionStateChange: ((TimelineBoundaryExtensionState) -> Void)? = nil
    var onVisibleTimelineFrameChange: ((CGRect) -> Void)? = nil
    var boundaryExtensionStateOverride: TimelineBoundaryExtensionState? = nil
    var liveInterruptSession: CalendarInterruptLiveSession? = nil

    // Layout Constants
    private let labelWidth: CGFloat = 26
    private let daySpacing: CGFloat = 0
    private var eventHorizontalInset: CGFloat { isSingleDay ? 8 : 4 }
    private let scrollHorizontalPadding: CGFloat = 0
    private let timelineEdgePadding: CGFloat = 2
    private var headerHeight: CGFloat { calendarTimelineTopInset(hourHeight: hourHeight) }

    // All-day layout
    private let allDayPillHeight: CGFloat = 28
    private let allDaySectionPadding: CGFloat = 4

    // Computed
    private var isSingleDay: Bool { daysCount == 1 }
    private var showDayLabel: Bool { false }
    private var labelBarHeight: CGFloat { 0 }
    private var labelBarSpacing: CGFloat { 0 }
    private var timelineBottomInset: CGFloat { calendarTimelineBottomInset(hourHeight: hourHeight) }
    private var slotMinutes: Int { calendarLegendSlotMinutes(forHourHeight: hourHeight) }
    private var slotHeight: CGFloat { hourHeight * CGFloat(slotMinutes) / 60 }
    private var editMappingState: TimelineEditMappingState? {
        calendarResolveEditMappingState(
            creation: resolvedCreationEditMapping,
            drag: resolvedDragEditMapping,
            focused: resolvedFocusedEditMapping
        )
    }
    private var boundaryExtensionMappingState: TimelineEditMappingState? {
        calendarResolveBoundaryExtensionMappingState(
            creation: resolvedCreationEditMapping,
            drag: resolvedDragEditMapping
        )
    }
    private var rawBoundaryExtensionHours: (leading: Int, trailing: Int) {
        calendarTimelineBoundaryExtensionHours(mappingState: boundaryExtensionMappingState)
    }
    private var rawBoundaryExtensionState: TimelineBoundaryExtensionState {
        TimelineBoundaryExtensionState(
            leadingHours: rawBoundaryExtensionHours.leading,
            trailingHours: rawBoundaryExtensionHours.trailing,
            source: boundaryExtensionMappingState?.source
        )
    }
    private var effectiveBoundaryExtensionState: TimelineBoundaryExtensionState {
        boundaryExtensionStateOverride ?? rawBoundaryExtensionState
    }
    private var boundaryExtensionHours: (leading: Int, trailing: Int) {
        (
            leading: effectiveBoundaryExtensionState.leadingHours,
            trailing: effectiveBoundaryExtensionState.trailingHours
        )
    }
    private var slotCount: Int {
        max(
            1,
            Int(
                CGFloat(
                    calendarTimelineTotalVisibleHours(
                        leadingExtendedHours: boundaryExtensionHours.leading,
                        trailingExtendedHours: boundaryExtensionHours.trailing
                    ) * 60
                ) / CGFloat(slotMinutes)
            ) + 1
        )
    }
    private var timelineHeight: CGFloat { headerHeight + CGFloat(slotCount) * slotHeight + timelineBottomInset }
    private var maxAllDayCount: Int {
        guard let provider = allDayOccurrencesForOffset else { return 0 }
        var maxCount = 0
        for offset in dayRange {
            let count = provider(offset).count
            if count > maxCount { maxCount = count }
        }
        return maxCount
    }
    private var allDayHeight: CGFloat {
        let count = maxAllDayCount
        guard count > 0 else { return 0 }
        return CGFloat(count) * allDayPillHeight + allDaySectionPadding * 2
    }
    private var totalHeight: CGFloat { labelBarHeight + allDayHeight + timelineHeight }
    private var boundaryExtensionAnimation: Animation? {
        let isMoveDragActive = calendarIsMoveDragActive(
            draggingEventID: dragState.draggingEventID,
            dragMode: dragState.dragMode
        )
        let isCreationDragActive = !creationPreviewByDay.isEmpty
        guard calendarShouldAnimateTimelineBoundaryExtension(
            isMoveDragActive: isMoveDragActive,
            isCreationDragActive: isCreationDragActive,
            reduceMotion: accessibilityReduceMotion
        ) else {
            return nil
        }
        return .interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.12)
    }

    // Scroll State
    @State private var hasScrolledToInitial = false
    @State private var isRestoringScroll = true
    @State private var pendingScrollTarget: Int? = nil
    @State private var isUserScrollUpdating = false
    @State private var latestHorizontalContentOffsetX: CGFloat = 0
    @State private var previousHorizontalAutoScrolling: Bool = false
    @State private var pendingSnapAfterAutoScrollStop: Bool = false
    @State private var lastHorizontalScrollDebugTimestamp: CFTimeInterval = 0
    @State private var horizontalScrollIsInteracting = false

    // Drag State (shared across all day views for cross-day event sync)
    @State private var isRangePinchActive = false
    @State private var rangePinchReferenceScale: CGFloat = 1
    @State private var rangePinchInitialHourHeight: CGFloat = calendarTimelineHourHeightDefault
    @State private var rangePinchBoundaryProgress: CGFloat = 0
    @State private var rangePinchBoundaryStep: Int = 0
    @State private var rangePinchBoundaryLatched = false
    @State private var rangePinchBoundaryHaptic = UIImpactFeedbackGenerator(style: .soft)
    @State private var temporalStretchLastStepIndex: Int = 0
    @State private var temporalStretchLastSlotMinutes: Int = 60
    @State private var temporalStretchHitLowerBound = false
    @State private var temporalStretchHitUpperBound = false
    @State private var temporalStretchStepHaptic = UISelectionFeedbackGenerator()
    @State private var temporalStretchMilestoneHaptic = UIImpactFeedbackGenerator(style: .soft)
    @State private var temporalStretchBoundaryHaptic = UIImpactFeedbackGenerator(style: .rigid)
    @State private var creationPreviewByDay: [Int: Event.TimeRange] = [:]

    private var resolvedCreationEditMapping: (date: Date, range: Event.TimeRange)? {
        calendarResolvedCreationEditMapping(
            creationPreviewByDay: creationPreviewByDay,
            selectedDayOffset: selectedDayOffset,
            pendingCreate: previewCreation
        )
    }

    private var resolvedDragEditMapping: (source: TimelineEditMappingSource, date: Date, range: Event.TimeRange)? {
        guard dragState.draggingEventID != nil else { return nil }
        guard let range = calendarResolvedDragEditRange(
            draggingOriginalRange: dragState.draggingOriginalRange,
            dragOffset: dragState.dragOffset,
            dragMode: dragState.dragMode,
            hourHeight: hourHeight
        ) else { return nil }

        let source: TimelineEditMappingSource
        switch dragState.dragMode {
        case .move:
            source = .moveDrag
        case .resizeTop:
            source = .resizeTop
        case .resizeBottom:
            source = .resizeBottom
        }
        let anchorDate = calendarResolvedDragAnchorDate(
            draggingOriginalRange: dragState.draggingOriginalRange,
            dragOffset: dragState.dragOffset,
            dragMode: dragState.dragMode,
            dayColumnStep: dragState.dayColumnStep
        ) ?? range.start
        return (source, anchorDate, range)
    }

    private var resolvedFocusedEditMapping: (date: Date, range: Event.TimeRange)? {
        let visibleOffsets = Array(
            visibleOffsetsRange(centeredRange: centeredOffsetsRange())
        )
        return calendarResolvedFocusedEditRange(
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
            visibleOffsets: visibleOffsets,
            occurrencesForOffset: occurrencesForOffset
        )
    }

    private var editMappingPresentation: TimelineAxisMarkerPresentation? {
        guard var presentation = calendarResolveAxisMarkerPresentation(
            mappingState: editMappingState,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: boundaryExtensionHours.leading,
            trailingExtendedHours: boundaryExtensionHours.trailing
        ) else { return nil }

        // Use the event's theme color from drag state, focused state, or creation
        if let draggingEvent = dragState.draggingEvent {
            presentation.color = CalendarLayout.eventColor(for: draggingEvent)
        } else if let focusedEventID {
            let visibleOffsets = Array(visibleOffsetsRange(centeredRange: centeredOffsetsRange()))
            for offset in visibleOffsets {
                if let match = occurrencesForOffset(offset).first(where: { $0.event.id == focusedEventID }) {
                    presentation.color = CalendarLayout.eventColor(for: match.event)
                    break
                }
            }
        } else if editMappingState?.source == .creation {
            presentation.color = calendarCurrentTimeIndicatorColor()
        }

        return presentation
    }

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
            .animation(boundaryExtensionAnimation, value: effectiveBoundaryExtensionState)
        }
        .frame(height: totalHeight, alignment: .top)
        .onAppear {
            onBoundaryExtensionStateChange?(rawBoundaryExtensionState)
        }
        .onChange(of: rawBoundaryExtensionState) { _, newValue in
            onBoundaryExtensionStateChange?(newValue)
        }
    }

    // MARK: - Time Axis

    @ViewBuilder
    private func timeAxis(labelRowHeight: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            if showDayLabel {
                VStack(spacing: labelBarSpacing) {
                    Color.clear.frame(height: labelRowHeight + allDayHeight)
                    TimeAxisLabels(
                        anchorDate: dayDate(forOffset: selectedDayOffset),
                        headerHeight: headerHeight,
                        hourHeight: hourHeight,
                        slotMinutes: slotMinutes,
                        leadingExtendedHours: boundaryExtensionHours.leading,
                        trailingExtendedHours: boundaryExtensionHours.trailing,
                        mode: mode,
                        editMappingPresentation: editMappingPresentation
                    )
                    .frame(height: timelineHeight, alignment: .top)
                }
            } else {
                VStack(spacing: 0) {
                    if allDayHeight > 0 {
                        Color.clear.frame(height: allDayHeight)
                    }
                    TimeAxisLabels(
                        anchorDate: dayDate(forOffset: selectedDayOffset),
                        headerHeight: headerHeight,
                        hourHeight: hourHeight,
                        slotMinutes: slotMinutes,
                        leadingExtendedHours: boundaryExtensionHours.leading,
                        trailingExtendedHours: boundaryExtensionHours.trailing,
                        mode: mode,
                        editMappingPresentation: editMappingPresentation
                    )
                    .frame(height: timelineHeight, alignment: .top)
                }
            }

        }
    }

    private let rangePinchBoundaryThreshold: CGFloat = 0.04
    private let rangePinchSaturationOvershoot: CGFloat = 0.28
    private let rangePinchBoundaryFollowFactor: CGFloat = 0.35

    private var rangePinchVisualScale: CGFloat {
        1
    }

    private var rangePinchVisualScaleY: CGFloat {
        calendarPinchBoundaryVisualScale(
            step: rangePinchBoundaryStep,
            resistanceProgress: rangePinchBoundaryProgress,
            maxVisualDelta: 0.035
        )
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
            rangePinchInitialHourHeight = hourHeight
            rangePinchBoundaryProgress = 0
            rangePinchBoundaryStep = 0
            rangePinchBoundaryLatched = false
            temporalStretchLastStepIndex = temporalStretchStepIndex(for: hourHeight)
            temporalStretchLastSlotMinutes = slotMinutes
            temporalStretchHitLowerBound = hourHeight <= calendarTimelineHourHeightMin + temporalStretchBoundaryEpsilon
            temporalStretchHitUpperBound = hourHeight >= calendarTimelineHourHeightMax - temporalStretchBoundaryEpsilon
            temporalStretchStepHaptic.prepare()
            temporalStretchMilestoneHaptic.prepare()
            temporalStretchBoundaryHaptic.prepare()
            rangePinchBoundaryHaptic.prepare()
        }

        let referenceScale = max(0.01, rangePinchReferenceScale)
        let effectiveScale = safeScale / referenceScale
        let previousHourHeight = hourHeight
        let nextHourHeight = calendarTimelineHourHeightAfterPinchScale(
            initialHourHeight: rangePinchInitialHourHeight,
            scale: effectiveScale
        )
        if abs(nextHourHeight - previousHourHeight) > 0.0001 {
            updateTemporalStretchHaptics(
                previousHourHeight: previousHourHeight,
                newHourHeight: nextHourHeight
            )
            hourHeight = nextHourHeight
        }

        let step = calendarPinchDirectionFromScale(
            scale: effectiveScale,
            threshold: rangePinchBoundaryThreshold
        )
        let proposedHourHeight = rangePinchInitialHourHeight * effectiveScale
        let pushingPastUpperBound = step < 0
            && proposedHourHeight > calendarTimelineHourHeightMax + 0.0001
            && nextHourHeight >= calendarTimelineHourHeightMax - 0.0001
        let pushingPastLowerBound = step > 0
            && proposedHourHeight < calendarTimelineHourHeightMin - 0.0001
            && nextHourHeight <= calendarTimelineHourHeightMin + 0.0001

        guard step != 0, pushingPastUpperBound || pushingPastLowerBound else {
            updateRangePinchBoundaryProgress(toward: 0)
            rangePinchBoundaryStep = 0
            rangePinchBoundaryLatched = false
            return
        }

        if rangePinchBoundaryStep != step {
            rangePinchBoundaryLatched = false
        }
        rangePinchBoundaryStep = step
        let resistanceProgress = calendarPinchBoundaryResistanceProgress(
            scale: effectiveScale,
            step: step,
            threshold: rangePinchBoundaryThreshold,
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
        guard isRangePinchActive else { return }

        isRangePinchActive = false
        rangePinchReferenceScale = 1
        rangePinchInitialHourHeight = hourHeight
        rangePinchBoundaryLatched = false
        rangePinchBoundaryStep = 0
        onHourHeightCommit?()

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
        let visibleOffsets = visibleOffsetsRange(centeredRange: centeredRange)
        let visibleEventIDs = Set(
            visibleOffsets
                .flatMap { occurrencesForOffset($0).map { $0.event.id } }
        )
        let isMoveDragActive = calendarIsMoveDragActive(
            draggingEventID: dragState.draggingEventID,
            dragMode: dragState.dragMode
        )
        let isFocusContextActive = calendarIsFocusVisualContextActive(
            focusedEventID: focusedEventID,
            visibleEventIDs: visibleEventIDs,
            draggingEventID: dragState.draggingEventID,
            isMoveDragActive: isMoveDragActive
        )
        let step = dayFrameWidth + spacing
        let isHorizontalSlotSnapDisabled = isMoveDragActive && calendarShouldDisableHorizontalScrollSnap(
            isHorizontalEdgeDragging: dragState.isHorizontalEdgeDragging,
            isHorizontalAutoScrolling: dragState.isHorizontalAutoScrolling
        )
        ScrollViewReader { scrollProxy in
            let emitHorizontalScrollProgress: (CGFloat) -> Void = { contentOffsetX in
                let centeredDayOffsetContinuous = calendarContinuousCenteredDayOffset(
                    contentOffsetX: contentOffsetX,
                    step: step,
                    leadingRange: leadingRange,
                    daysCount: daysCount,
                    centeredRange: centeredRange
                )
                onHorizontalScrollProgress?(
                    TimelineHorizontalScrollProgress(
                        centeredDayOffsetContinuous: centeredDayOffsetContinuous,
                        isInteracting: horizontalScrollIsInteracting
                    )
                )
            }

            let restoreScrollToSelectedDayOffset: (_ animated: Bool) -> Void = { animated in
                guard step > 0 else { return }
                guard let clampedCentered = calendarTimelineResolvedCenteredDayOffset(
                    requestedDayOffset: selectedDayOffset,
                    centeredRange: centeredRange
                ) else {
                    return
                }
                let clampedLeading = calendarLeadingDayOffsetFromCentered(
                    centeredDayOffset: clampedCentered,
                    daysCount: daysCount,
                    leadingRange: leadingRange
                )
                pendingScrollTarget = clampedLeading
                isRestoringScroll = true
                if animated {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo(clampedLeading, anchor: .leading)
                    }
                } else {
                    scrollProxy.scrollTo(clampedLeading, anchor: .leading)
                }
                emitHorizontalScrollProgress(latestHorizontalContentOffsetX)
            }

            let snapToNearestDaySlot: () -> Void = {
                guard step > 0, !isDayOffsetFrozen else { return }
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
                let visibleDate = dayDate(forOffset: centered)
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
                LazyHStack(spacing: spacing) {
                    dayColumns(
                        dayWidth: dayWidth,
                        dayFrameWidth: dayFrameWidth,
                        labelRowHeight: labelRowHeight,
                        isFocusContextActive: isFocusContextActive
                    )
                }
                .scrollTargetLayout()
                .padding(.horizontal, scrollHorizontalPadding)
            }
            .calendarApplyPersistentHorizontalSlotSnap(enabled: true)
            .scrollDisabled(isRangePinchActive)
            .scrollIndicators(.hidden)
            .onAppear {
                guard !hasScrolledToInitial else { return }
                hasScrolledToInitial = true
                previousHorizontalAutoScrolling = dragState.isHorizontalAutoScrolling
                horizontalScrollIsInteracting = false
                guard let clampedCentered = calendarTimelineResolvedCenteredDayOffset(
                    requestedDayOffset: selectedDayOffset,
                    centeredRange: centeredRange
                ) else {
                    return
                }
                if clampedCentered != selectedDayOffset { selectedDayOffset = clampedCentered }
                let clampedLeading = calendarLeadingDayOffsetFromCentered(
                    centeredDayOffset: clampedCentered,
                    daysCount: daysCount,
                    leadingRange: leadingRange
                )
                pendingScrollTarget = clampedLeading
                isRestoringScroll = true
                let visibleDate = dayDate(forOffset: clampedCentered)
                calendarDebugLog(
                    "timeline.onAppear",
                    fields: [
                        "selectedDayOffset": "\(clampedCentered)",
                        "visibleDate": calendarDebugDayString(visibleDate),
                        "leadingOffset": "\(clampedLeading)",
                        "daysCount": "\(daysCount)",
                        "step": String(format: "%.2f", step)
                    ]
                )
                // Defer to next run loop so LazyHStack layout is finalized
                DispatchQueue.main.async {
                    scrollProxy.scrollTo(clampedLeading, anchor: .leading)
                }
                emitHorizontalScrollProgress(latestHorizontalContentOffsetX)
            }
            .onChange(of: selectedDayOffset) { _, newValue in
                if isUserScrollUpdating {
                    isUserScrollUpdating = false
                    return
                }
                guard let clampedCentered = calendarTimelineResolvedCenteredDayOffset(
                    requestedDayOffset: newValue,
                    centeredRange: centeredRange
                ) else {
                    return
                }
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
                let visibleDate = dayDate(forOffset: clampedCentered)
                calendarDebugLog(
                    "timeline.selectedDayOffsetChanged",
                    fields: [
                        "newOffset": "\(newValue)",
                        "clampedOffset": "\(clampedCentered)",
                        "visibleDate": calendarDebugDayString(visibleDate),
                        "leadingOffset": "\(clampedLeading)"
                    ]
                )
                if accessibilityReduceMotion {
                    scrollProxy.scrollTo(clampedLeading, anchor: .leading)
                } else {
                    withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.9, blendDuration: 0.12)) {
                        scrollProxy.scrollTo(clampedLeading, anchor: .leading)
                    }
                }
            }
            .onChange(of: dayRange) {
                guard let resolvedCentered = calendarTimelineResolvedCenteredDayOffset(
                    requestedDayOffset: selectedDayOffset,
                    centeredRange: centeredRange,
                    deferOutOfRangeSelection: isDayOffsetFrozen
                ) else {
                    return
                }
                if !isDayOffsetFrozen, resolvedCentered != selectedDayOffset {
                    selectedDayOffset = resolvedCentered
                }
                let clampedLeading = calendarLeadingDayOffsetFromCentered(
                    centeredDayOffset: resolvedCentered,
                    daysCount: daysCount,
                    leadingRange: leadingRange
                )
                pendingScrollTarget = clampedLeading
                isRestoringScroll = true
                scrollProxy.scrollTo(clampedLeading, anchor: .leading)
            }
            .onChange(of: isDayOffsetFrozen) { _, isFrozen in
                guard !isFrozen else { return }
                restoreScrollToSelectedDayOffset(true)
            }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
                guard step > 0 else { return }
                latestHorizontalContentOffsetX = newValue.contentOffset.x
                emitHorizontalScrollProgress(newValue.contentOffset.x)
                let isMoveDragActiveNow = calendarIsMoveDragActive(
                    draggingEventID: dragState.draggingEventID,
                    dragMode: dragState.dragMode
                )
                let freezeSelectedDayOffset = calendarShouldFreezeSelectedDayOffsetDuringMoveDrag(
                    isMoveDragActive: isMoveDragActiveNow,
                    isHorizontalEdgeDragging: dragState.isHorizontalEdgeDragging,
                    isHorizontalAutoScrolling: dragState.isHorizontalAutoScrolling
                )
                let shouldAdoptScrollDrivenSelection = calendarShouldAdoptScrollDrivenDayOffset(
                    isScrollInteracting: horizontalScrollIsInteracting,
                    isHorizontalEdgeDragging: dragState.isHorizontalEdgeDragging,
                    isHorizontalAutoScrolling: dragState.isHorizontalAutoScrolling
                )
                let candidateLeading = calendarNearestLeadingDayOffset(
                    contentOffsetX: newValue.contentOffset.x,
                    step: step,
                    leadingRange: leadingRange
                )
                let candidateCentered = calendarCenteredDayOffsetFromLeading(
                    leadingDayOffset: candidateLeading,
                    daysCount: daysCount,
                    centeredRange: centeredRange
                )
                let now = CACurrentMediaTime()
                if now - lastHorizontalScrollDebugTimestamp >= 0.12 {
                    lastHorizontalScrollDebugTimestamp = now
                    let visibleDate = dayDate(forOffset: selectedDayOffset)
                    calendarDebugLog(
                        "timeline.scrollGeometry",
                        fields: [
                            "contentOffsetX": String(format: "%.2f", newValue.contentOffset.x),
                            "selectedDayOffset": "\(selectedDayOffset)",
                            "visibleDate": calendarDebugDayString(visibleDate),
                            "isRestoring": "\(isRestoringScroll)",
                            "pendingTarget": pendingScrollTarget.map(String.init) ?? "nil",
                            "moveDragActive": "\(isMoveDragActiveNow)",
                            "freezeSelectedDayOffset": "\(freezeSelectedDayOffset)",
                            "isHorizontalEdgeDragging": "\(dragState.isHorizontalEdgeDragging)",
                            "isHorizontalAutoScrolling": "\(dragState.isHorizontalAutoScrolling)",
                            "draggingEventID": dragState.draggingEventID?.uuidString ?? "nil",
                            "candidateLeadingOffset": "\(candidateLeading)",
                            "candidateCenteredOffset": "\(candidateCentered)"
                        ]
                    )
                }
                if isRestoringScroll {
                    guard let target = pendingScrollTarget else {
                        isRestoringScroll = false
                        return
                    }
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
                            "draggingEventID": dragState.draggingEventID?.uuidString ?? "nil",
                            "isHorizontalEdgeDragging": "\(dragState.isHorizontalEdgeDragging)",
                            "isHorizontalAutoScrolling": "\(dragState.isHorizontalAutoScrolling)",
                            "selectedDayOffset": "\(selectedDayOffset)",
                            "visibleDate": calendarDebugDayString(
                                dayDate(forOffset: selectedDayOffset)
                            )
                        ]
                    )
                    return
                }
                guard shouldAdoptScrollDrivenSelection else {
                    calendarDebugLog(
                        "timeline.selectedDayOffset.skipNonInteractiveGeometryUpdate",
                        fields: [
                            "contentOffsetX": String(format: "%.2f", newValue.contentOffset.x),
                            "selectedDayOffset": "\(selectedDayOffset)",
                            "candidateCenteredOffset": "\(candidateCentered)",
                            "isInteracting": "\(horizontalScrollIsInteracting)",
                            "isHorizontalEdgeDragging": "\(dragState.isHorizontalEdgeDragging)",
                            "isHorizontalAutoScrolling": "\(dragState.isHorizontalAutoScrolling)"
                        ]
                    )
                    consumePendingAutoStopSnapIfPossible()
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
                if !isDayOffsetFrozen, selectedDayOffset != centered {
                    isUserScrollUpdating = true
                    selectedDayOffset = centered
                }
                consumePendingAutoStopSnapIfPossible()
            }
            .onScrollPhaseChange { _, newPhase in
                let isInteractingPhase = (newPhase == .interacting || newPhase == .decelerating)
                if horizontalScrollIsInteracting != isInteractingPhase {
                    horizontalScrollIsInteracting = isInteractingPhase
                    emitHorizontalScrollProgress(latestHorizontalContentOffsetX)
                }
                let isMoveDragActiveNow = calendarIsMoveDragActive(
                    draggingEventID: dragState.draggingEventID,
                    dragMode: dragState.dragMode
                )
                if newPhase == .interacting, isRestoringScroll {
                    calendarDebugLog(
                        "timeline.restoring.cancelledByInteraction",
                        fields: [
                            "pendingTarget": pendingScrollTarget.map(String.init) ?? "nil",
                            "contentOffsetX": String(format: "%.2f", latestHorizontalContentOffsetX),
                            "selectedDayOffset": "\(selectedDayOffset)",
                            "moveDragActive": "\(isMoveDragActiveNow)"
                        ]
                    )
                    isRestoringScroll = false
                    pendingScrollTarget = nil
                }
                let isHorizontalSlotSnapDisabledNow = isMoveDragActiveNow && calendarShouldDisableHorizontalScrollSnap(
                    isHorizontalEdgeDragging: dragState.isHorizontalEdgeDragging,
                    isHorizontalAutoScrolling: dragState.isHorizontalAutoScrolling
                )
                let visibleDate = dayDate(forOffset: selectedDayOffset)
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
            .onChange(of: isHorizontalSlotSnapDisabled) { _, isDisabled in
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
            .onChange(of: dragState.draggingEventID) { _, newValue in
                // New drag sessions must start from a clean auto-scroll transition state.
                previousHorizontalAutoScrolling = dragState.isHorizontalAutoScrolling
                pendingSnapAfterAutoScrollStop = false
                if newValue != nil {
                    creationPreviewByDay.removeAll()
                }
                calendarDebugLog(
                    "timeline.dragSession.changed",
                    fields: [
                        "draggingEventID": dragState.draggingEventID?.uuidString ?? "nil",
                        "draggingOccurrenceID": dragState.draggingOccurrenceID ?? "nil",
                        "dragMode": String(describing: dragState.dragMode),
                        "daysCount": "\(daysCount)",
                        "rangeMode": String(describing: rangeMode),
                        "selectedDayOffset": "\(selectedDayOffset)",
                        "isHorizontalAutoScrolling": "\(dragState.isHorizontalAutoScrolling)",
                        "isHorizontalEdgeDragging": "\(dragState.isHorizontalEdgeDragging)"
                    ]
                )
            }
            .onChange(of: dragState.isHorizontalAutoScrolling) { _, isAutoScrolling in
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
    private func dayColumns(
        dayWidth: CGFloat,
        dayFrameWidth: CGFloat,
        labelRowHeight: CGFloat,
        isFocusContextActive: Bool
    ) -> some View {
        ForEach(dayRange, id: \.self) { offset in
            dayColumn(
                offset: offset,
                width: dayWidth,
                labelRowHeight: labelRowHeight,
                isFocusContextActive: isFocusContextActive
            )
                .frame(width: dayFrameWidth)
                .id(offset)
        }
    }

    // MARK: - Day Column

    @ViewBuilder
    private func allDaySection(
        offset: Int,
        width: CGFloat,
        date: Date,
        isFocusContextActive: Bool
    ) -> some View {
        if allDayHeight > 0 {
            let allDayOccurrences = allDayOccurrencesForOffset?(offset) ?? []
            VStack(spacing: 2) {
                ForEach(allDayOccurrences) { occurrence in
                    let color = CalendarLayout.eventColor(for: occurrence.event)
                    let isInteractionAllowed = calendarShouldAllowEventInteraction(
                        focusedEventID: focusedEventID,
                        candidateEventID: occurrence.event.id,
                        isFocusContextActive: isFocusContextActive
                    )
                    Button {
                        onEventTap?(occurrence.event, date)
                    } label: {
                        HStack(spacing: 4) {
                            Text(occurrence.event.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .frame(height: allDayPillHeight - 4)
                        .background(color, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(isInteractionAllowed)
                }
            }
            .padding(.vertical, allDaySectionPadding)
            .frame(width: width, height: allDayHeight, alignment: .top)
        }
    }

    @ViewBuilder
    private func dayColumn(
        offset: Int,
        width: CGFloat,
        labelRowHeight: CGFloat,
        isFocusContextActive: Bool
    ) -> some View {
        let date = dayDate(forOffset: offset)
        let columnStep: CGFloat = isSingleDay ? 0 : width + daySpacing
        let previewDayStep: CGFloat = width + daySpacing

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

                allDaySection(
                    offset: offset,
                    width: width,
                    date: date,
                    isFocusContextActive: isFocusContextActive
                )

                buildTimelineDayView(
                    for: offset, date: date, dayWidth: width,
                    dayColumnStep: columnStep, dragPreviewDayStep: previewDayStep,
                    previewRange: previewRange,
                    isFocusContextActive: isFocusContextActive
                )
            }
        } else {
            VStack(spacing: 0) {
                allDaySection(
                    offset: offset,
                    width: width,
                    date: date,
                    isFocusContextActive: isFocusContextActive
                )

                buildTimelineDayView(
                    for: offset, date: date, dayWidth: width,
                    dayColumnStep: columnStep, dragPreviewDayStep: previewDayStep,
                    previewRange: previewRange,
                    isFocusContextActive: isFocusContextActive
                )
            }
        }
    }

    private func buildTimelineDayView(
        for offset: Int,
        date: Date,
        dayWidth: CGFloat,
        dayColumnStep: CGFloat,
        dragPreviewDayStep: CGFloat,
        previewRange: Event.TimeRange?,
        isFocusContextActive: Bool
    ) -> some View {
        TimelineDayView(
            date: date,
            occurrences: CalendarLayout.timelineVisibleOccurrences(
                forDayOffset: offset,
                leadingExtendedHours: boundaryExtensionHours.leading,
                trailingExtendedHours: boundaryExtensionHours.trailing,
                occurrencesForOffset: occurrencesForOffset
            ),
            contentWidth: dayWidth,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            slotMinutes: slotMinutes,
            eventHorizontalInset: eventHorizontalInset,
            showEventText: showEventText,
            isWeekMode: rangeMode == .week,
            isThreeDayMode: rangeMode == .threeDay,
            isPinchActive: isRangePinchActive,
            style: .view,
            dayColumnStep: dayColumnStep,
            dragPreviewDayStep: dragPreviewDayStep,
            previewTimeRange: previewRange,
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
            previewHandleEventID: previewHandleEventID,
            previewHandleOccurrenceID: previewHandleOccurrenceID,
            previewHandleOpacity: previewHandleOpacity,
            graceResizeEventID: graceResizeEventID,
            graceResizeOccurrenceID: graceResizeOccurrenceID,
            graceResizeHandleOpacity: graceResizeHandleOpacity,
            leadingExtendedHours: boundaryExtensionHours.leading,
            trailingExtendedHours: boundaryExtensionHours.trailing,
            isFocusContextActive: isFocusContextActive,
            onEventTap: onEventTap,
            onEventLongPressBegan: onEventLongPressBegan,
            onEventManipulationPromotion: onEventManipulationPromotion,
            onEventLongPressResolved: onEventLongPressResolved,
            onEventDragEnded: onEventDragEnded,
            onEventResizeEnded: onEventResizeEnded,
            onCreateEvent: onCreateEvent != nil ? { range in onCreateEvent?(date, range) } : nil,
            onCreationPreviewChanged: { day, range in
                updateCreationPreviewMapping(day: day, range: range)
            },
            onNonEventTap: onNonEventTap,
            liveInterruptSession: liveInterruptSession,
            dragState: dragState
        )
        .frame(width: dayWidth, height: timelineHeight, alignment: .top)
        .background {
            if daysCount == 1, offset == selectedDayOffset, let onVisibleTimelineFrameChange {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            onVisibleTimelineFrameChange(proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, newValue in
                            onVisibleTimelineFrameChange(newValue)
                        }
                }
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

    private func visibleOffsetsRange(centeredRange: ClosedRange<Int>) -> ClosedRange<Int> {
        let centered = clamp(selectedDayOffset, to: centeredRange)
        let centerIndex = calendarCenterSlotIndex(daysCount: daysCount)
        let lower = centered - centerIndex
        let upper = lower + daysCount - 1
        return lower...upper
    }

    private func dayDate(forOffset offset: Int, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    private func updateCreationPreviewMapping(day: Date, range: Event.TimeRange?) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayStart = calendar.startOfDay(for: day)
        let offset = calendar.dateComponents([.day], from: today, to: dayStart).day ?? 0

        guard let range else {
            creationPreviewByDay.removeValue(forKey: offset)
            return
        }
        creationPreviewByDay = [offset: range]
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
        let date = dayDate(forOffset: offset)
        let day = Calendar.current.component(.day, from: date)
        let weekdayIndex = Calendar.current.component(.weekday, from: date) - 1
        let symbols = Calendar.current.shortWeekdaySymbols
        let letter = symbols.indices.contains(weekdayIndex) ? String(symbols[weekdayIndex].prefix(1)) : ""
        return "\(day)\(letter)"
    }
}

// MARK: - Time Axis Labels

private struct TimeAxisLabels: View {
    let anchorDate: Date
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let slotMinutes: Int
    let leadingExtendedHours: Int
    let trailingExtendedHours: Int
    let mode: PageMode
    var editMappingPresentation: TimelineAxisMarkerPresentation? = nil

    private var slotHeight: CGFloat {
        hourHeight * CGFloat(slotMinutes) / 60
    }

    private var slotCount: Int {
        max(
            1,
            Int(
                CGFloat(
                    calendarTimelineTotalVisibleHours(
                        leadingExtendedHours: leadingExtendedHours,
                        trailingExtendedHours: trailingExtendedHours
                    ) * 60
                ) / CGFloat(slotMinutes)
            ) + 1
        )
    }

    private var boundaryDayHintPlacements: (
        leading: TimelineBoundaryDayHintPlacement?,
        trailing: TimelineBoundaryDayHintPlacement?
    ) {
        calendarTimelineBoundaryDayHintPlacements(
            anchorDate: anchorDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
    }

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                    ForEach(0..<slotCount, id: \.self) { index in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 1)
                            .overlay(alignment: .trailing) {
                                Text(label(forSlot: index, now: now))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.trailing, 2)
                                    .offset(y: -2)
                            }
                            .frame(height: slotHeight, alignment: .top)
                    }
                }

                Text(currentTimeText(for: now))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundColor(calendarCurrentTimeIndicatorColor())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 2)
                    .offset(y: currentTimeLegendYOffset(for: now))
                    .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.5)

                if let editMappingPresentation {
                    axisMarkers(presentation: editMappingPresentation)
                }

                if let leadingHint = boundaryDayHintPlacements.leading {
                    boundaryDayHintRow(placement: leadingHint)
                }

                if let trailingHint = boundaryDayHintPlacements.trailing {
                    boundaryDayHintRow(placement: trailingHint)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func axisMarkers(presentation: TimelineAxisMarkerPresentation) -> some View {
        if presentation.isCollapsed {
            // Show two separate labels spread apart to avoid the wide collapsed
            // text ("14:45 - 15:15") overflowing the narrow axis column.
            let midY = (presentation.startY + presentation.endY) / 2
            let markerHeight: CGFloat = 16
            let halfSpread = markerHeight / 2 + 1
            axisMarkerRow(text: presentation.startText, y: midY - halfSpread, color: presentation.color)
                .zIndex(2)
            axisMarkerRow(text: presentation.endText, y: midY + halfSpread, color: presentation.color)
                .zIndex(2)
        } else {
            axisMarkerRow(text: presentation.startText, y: presentation.startY, color: presentation.color)
                .zIndex(2)
            axisMarkerRow(text: presentation.endText, y: presentation.endY, color: presentation.color)
                .zIndex(2)
        }
    }

    private func axisMarkerRow(text: String, y: CGFloat, color: Color? = nil) -> some View {
        let markerColor = color ?? Color.accentColor
        let clampedY = clamp(
            y,
            headerHeight,
            headerHeight
                + CGFloat(
                    calendarTimelineTotalVisibleHours(
                        leadingExtendedHours: leadingExtendedHours,
                        trailingExtendedHours: trailingExtendedHours
                    )
                ) * hourHeight
        )
        let markerHeight: CGFloat = 16

        return Text(text)
            .font(.system(size: 8, weight: .semibold).monospacedDigit())
            .foregroundStyle(calendarLegendForegroundColor(for: markerColor))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(markerColor)
            )
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 8)
        .offset(x: 10, y: clampedY - markerHeight / 2)
        .shadow(color: markerColor.opacity(0.25), radius: 2, x: 0, y: 1)
    }

    private func boundaryDayHintRow(placement: TimelineBoundaryDayHintPlacement) -> some View {
        let totalVisibleHours = calendarTimelineTotalVisibleHours(
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
        let rowHeight: CGFloat = 26
        let clampedY = clamp(
            placement.originY,
            headerHeight,
            headerHeight + CGFloat(totalVisibleHours) * hourHeight - rowHeight
        )
        let weekday = Self.boundaryDayHintWeekdayFormatter.string(from: placement.date).uppercased()
        let day = Self.boundaryDayHintDayFormatter.string(from: placement.date)

        return VStack(spacing: -1) {
            Text(weekday)
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(.secondary.opacity(0.85))
            Text(day)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.95))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.08), lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 1)
        .offset(y: clampedY)
    }

    private func label(forSlot index: Int, now: Date) -> String {
        let totalMinutes = -leadingExtendedHours * 60 + index * slotMinutes
        let normalizedTotalMinutes = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        let hour24 = normalizedTotalMinutes / 60
        let minute = normalizedTotalMinutes % 60

        guard minute == 0 else { return "" }
        if calendarShouldHideLegendHourLabel(
            legendTotalMinutes: normalizedTotalMinutes,
            nowTotalMinutes: totalMinutesSinceMidnight(for: now),
            hourHeight: hourHeight
        ) {
            return ""
        }
        if AppTimeFormat.current.is24 {
            return String(format: "%d:00", hour24)
        } else {
            let meridiem = hour24 < 12 ? "am" : "pm"
            let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
            return "\(hour12) \(meridiem)"
        }
    }

    private static var currentTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mma"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return formatter
    }

    private static let boundaryDayHintWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private static let boundaryDayHintDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter
    }()

    private func currentTimeText(for now: Date) -> String {
        Self.currentTimeFormatter.string(from: now).lowercased()
    }

    private func currentTimeLegendYOffset(for now: Date) -> CGFloat {
        let pointerY = calendarTimelineYPosition(
            for: now,
            containing: now,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
        let labelHeight: CGFloat = 12
        return min(
            max(headerHeight, pointerY - labelHeight / 2),
            headerHeight
                + CGFloat(
                    calendarTimelineTotalVisibleHours(
                        leadingExtendedHours: leadingExtendedHours,
                        trailingExtendedHours: trailingExtendedHours
                    )
                ) * hourHeight
                - labelHeight
        )
    }

    private func totalMinutesSinceMidnight(for date: Date) -> CGFloat {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
            + CGFloat(components.second ?? 0) / 60
    }
}

struct TimelineBoundaryDayHintPlacement: Equatable {
    let date: Date
    let originY: CGFloat
    let isTrailingEdge: Bool
}

func calendarTimelineBoundaryDayHintPlacements(
    anchorDate: Date,
    headerHeight: CGFloat,
    hourHeight: CGFloat,
    leadingExtendedHours: Int,
    trailingExtendedHours: Int,
    hintInset: CGFloat = 8,
    calendar: Calendar = .current
) -> (
    leading: TimelineBoundaryDayHintPlacement?,
    trailing: TimelineBoundaryDayHintPlacement?
) {
    guard hourHeight.isFinite, hourHeight > 0 else {
        return (nil, nil)
    }

    let leadingPlacement: TimelineBoundaryDayHintPlacement? = {
        guard leadingExtendedHours > 0 else { return nil }
        let date = calendar.date(byAdding: .day, value: -1, to: anchorDate) ?? anchorDate
        return TimelineBoundaryDayHintPlacement(
            date: calendar.startOfDay(for: date),
            originY: headerHeight + hintInset,
            isTrailingEdge: false
        )
    }()

    let trailingPlacement: TimelineBoundaryDayHintPlacement? = {
        guard trailingExtendedHours > 0 else { return nil }
        let date = calendar.date(byAdding: .day, value: 1, to: anchorDate) ?? anchorDate
        return TimelineBoundaryDayHintPlacement(
            date: calendar.startOfDay(for: date),
            originY: headerHeight
                + CGFloat(max(0, leadingExtendedHours + calendarTimelineBaseVisibleHours)) * hourHeight
                + hintInset,
            isTrailingEdge: true
        )
    }()

    return (leadingPlacement, trailingPlacement)
}

// MARK: - Creation Drag Gesture (UIKit)

/// UIKit-based long press drag gesture for creating events.
/// Reports absolute Y positions instead of offsets.
private struct CreationDragGesture: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = 0.25
    var isAutoScrollEnabled = false
    var verticalAutoScrollEdgeInset: CGFloat = calendarVerticalAutoScrollEdgeInsetDefault
    var maxAutoScrollSpeed: CGFloat = calendarMaxAutoScrollSpeedDefault
    var onTap: (() -> Void)?
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

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapGesture.delegate = context.coordinator
        view.addGestureRecognizer(tapGesture)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        context.coordinator.verticalAutoScrollEdgeInset = verticalAutoScrollEdgeInset
        context.coordinator.maxAutoScrollSpeed = maxAutoScrollSpeed
        context.coordinator.setAutoScrollEnabled(isAutoScrollEnabled)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CreationDragGesture
        var onTap: (() -> Void)?
        var onBegan: ((CGFloat) -> Void)?
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat) -> Void)?
        var onCancelled: (() -> Void)?
        var isAutoScrollEnabled = false
        var verticalAutoScrollEdgeInset: CGFloat = calendarVerticalAutoScrollEdgeInsetDefault
        var maxAutoScrollSpeed: CGFloat = calendarMaxAutoScrollSpeedDefault
        private weak var activeGesture: UILongPressGestureRecognizer?
        private weak var verticalScrollView: UIScrollView?
        private var autoScrollVelocityY: CGFloat = 0
        private var autoScrollDisplayLink: CADisplayLink?

        init(_ parent: CreationDragGesture) {
            self.parent = parent
            self.onTap = parent.onTap
            self.onBegan = parent.onBegan
            self.onChanged = parent.onChanged
            self.onEnded = parent.onEnded
            self.onCancelled = parent.onCancelled
            self.isAutoScrollEnabled = parent.isAutoScrollEnabled
            self.verticalAutoScrollEdgeInset = parent.verticalAutoScrollEdgeInset
            self.maxAutoScrollSpeed = parent.maxAutoScrollSpeed
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                activeGesture = gesture
                verticalScrollView = findVerticalScrollTarget(startingAt: view)
                autoScrollVelocityY = 0
                onBegan?(location.y)
            case .changed:
                onChanged?(location.y)
                updateAutoScrollVelocity()
            case .ended:
                stopAutoScroll()
                activeGesture = nil
                verticalScrollView = nil
                onEnded?(location.y)
            case .cancelled, .failed:
                stopAutoScroll()
                activeGesture = nil
                verticalScrollView = nil
                onCancelled?()
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onTap?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        deinit {
            stopAutoScroll()
        }

        func setAutoScrollEnabled(_ enabled: Bool) {
            guard isAutoScrollEnabled != enabled else { return }
            isAutoScrollEnabled = enabled
            if enabled {
                updateAutoScrollVelocity()
            } else {
                stopAutoScroll()
            }
        }

        private func updateAutoScrollVelocity() {
            guard isAutoScrollEnabled else {
                stopAutoScroll()
                return
            }

            autoScrollVelocityY = autoScrollVelocity(for: verticalScrollView)
            if autoScrollVelocityY == 0 {
                stopAutoScroll()
            } else {
                startAutoScroll()
            }
        }

        private func startAutoScroll() {
            guard autoScrollDisplayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            autoScrollDisplayLink = link
        }

        private func stopAutoScroll() {
            autoScrollDisplayLink?.invalidate()
            autoScrollDisplayLink = nil
            autoScrollVelocityY = 0
        }

        @objc private func handleAutoScrollTick(_ displayLink: CADisplayLink) {
            guard autoScrollVelocityY != 0 else {
                stopAutoScroll()
                return
            }
            guard let verticalScrollView else {
                stopAutoScroll()
                return
            }

            let deltaTime = max(displayLink.targetTimestamp - displayLink.timestamp, 0)
            let appliedDeltaY = applyVerticalAutoScroll(
                on: verticalScrollView,
                deltaY: autoScrollVelocityY * CGFloat(deltaTime)
            )

            if abs(appliedDeltaY) > .ulpOfOne,
               let gesture = activeGesture,
               let view = gesture.view {
                onChanged?(gesture.location(in: view).y)
            }

            updateAutoScrollVelocity()
        }

        private func autoScrollVelocity(for scrollView: UIScrollView?) -> CGFloat {
            guard let scrollView,
                  let locationInWindow = activeGesture?.location(in: nil) else {
                return 0
            }

            let minOffsetY = -scrollView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            let pointerLocationInViewport = locationInWindow.y - frameInWindow.minY
            return calendarAutoScrollVelocity(
                locationInViewport: pointerLocationInViewport,
                viewportLength: scrollView.bounds.height,
                currentOffset: scrollView.contentOffset.y,
                minOffset: minOffsetY,
                maxOffset: maxOffsetY,
                edgeInset: verticalAutoScrollEdgeInset,
                maxSpeed: maxAutoScrollSpeed
            )
        }

        private func applyVerticalAutoScroll(
            on scrollView: UIScrollView,
            deltaY: CGFloat
        ) -> CGFloat {
            let minOffsetY = -scrollView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let currentOffsetY = scrollView.contentOffset.y
            let proposedOffsetY = currentOffsetY + deltaY
            let clampedOffsetY = min(max(proposedOffsetY, minOffsetY), maxOffsetY)
            guard abs(clampedOffsetY - currentOffsetY) > .ulpOfOne else { return 0 }
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: clampedOffsetY),
                animated: false
            )
            return clampedOffsetY - currentOffsetY
        }

        private func findVerticalScrollTarget(startingAt view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView,
                   scrollView.isScrollEnabled,
                   scrollView.contentSize.height - scrollView.bounds.height > 1 {
                    return scrollView
                }
                current = candidate.superview
            }
            return nil
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
    var isWeekMode: Bool = false
    var isThreeDayMode: Bool = false
    var isPinchActive: Bool = false
    let style: TimelineStyle
    var dayColumnStep: CGFloat = 0
    var dragPreviewDayStep: CGFloat = 0
    var previewTimeRange: Event.TimeRange? = nil
    var focusedEventID: UUID? = nil
    var focusedOccurrenceID: String? = nil
    var previewHandleEventID: UUID? = nil
    var previewHandleOccurrenceID: String? = nil
    var previewHandleOpacity: Double = 1
    var graceResizeEventID: UUID? = nil
    var graceResizeOccurrenceID: String? = nil
    var graceResizeHandleOpacity: Double = 1
    var leadingExtendedHours: Int = 0
    var trailingExtendedHours: Int = 0
    var isFocusContextActive: Bool = false
    var onEventTap: ((Event, Date) -> Void)? = nil
    var onEventLongPressBegan: ((CalendarEventLongPressBegan) -> Void)? = nil
    var onEventManipulationPromotion: ((Event, String?, Date, EventDragMode, CGPoint, CGRect) -> Void)? = nil
    var onEventLongPressResolved: ((CalendarEventLongPressResolution) -> Void)? = nil
    var onEventDragEnded: ((Event, String?, Event.TimeRange, DragOffset, CGFloat) -> Void)? = nil
    var onEventResizeEnded: ((Event, String?, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)? = nil
    var onCreateEvent: ((Event.TimeRange) -> Void)? = nil
    var onCreationPreviewChanged: ((Date, Event.TimeRange?) -> Void)? = nil
    var onNonEventTap: (() -> Void)? = nil
    var liveInterruptSession: CalendarInterruptLiveSession? = nil

    // Shared drag state for cross-day event sync
    @ObservedObject var dragState: EventDragState

    // Creation drag state
    @State private var isCreating = false
    @State private var isLongPressingCreation = false
    @State private var creationStartY: CGFloat = 0
    @State private var creationCurrentY: CGFloat = 0
    @State private var lastTickMinutes: Int = -1

    private struct DraggedOccurrenceRenderHealth: Equatable {
        let draggingEventID: UUID?
        let draggingOccurrenceID: String?
        let dragMode: EventDragMode
        let hasOccurrenceInDay: Bool
        let renderedInDay: Bool
        let hasCrossDayPreview: Bool
    }

    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    private let snapMinutes: Int = 15
    private let creationActivationThreshold: CGFloat = 18

    private var slotHeight: CGFloat { hourHeight * CGFloat(slotMinutes) / 60 }
    private var slotCount: Int {
        max(
            1,
            Int(
                CGFloat(
                    calendarTimelineTotalVisibleHours(
                        leadingExtendedHours: leadingExtendedHours,
                        trailingExtendedHours: trailingExtendedHours
                    ) * 60
                ) / CGFloat(slotMinutes)
            ) + 1
        )
    }
    private var timelineBottomInset: CGFloat { calendarTimelineBottomInset(hourHeight: hourHeight) }
    private var visibleStart: Date {
        calendarTimelineVisibleStart(
            containing: date,
            leadingExtendedHours: leadingExtendedHours
        )
    }
    private var visibleEnd: Date {
        calendarTimelineVisibleEnd(
            containing: date,
            trailingExtendedHours: trailingExtendedHours
        )
    }

    private var isCreateEnabled: Bool {
        onCreateEvent != nil
            && focusedEventID == nil
            && graceResizeEventID == nil
            && previewHandleEventID == nil
    }

    // Show preview if dragging OR if there's a pending creation for this day
    private var activePreviewRange: Event.TimeRange? {
        if isCreating {
            return creationPreviewRange
        }
        return previewTimeRange
    }

    /// Snapshot used to detect when the actively dragged occurrence unexpectedly
    /// disappears from this day column's render tree.
    private var draggedOccurrenceRenderHealth: DraggedOccurrenceRenderHealth {
        guard let draggingOccurrenceID = dragState.draggingOccurrenceID else {
            return DraggedOccurrenceRenderHealth(
                draggingEventID: dragState.draggingEventID,
                draggingOccurrenceID: nil,
                dragMode: dragState.dragMode,
                hasOccurrenceInDay: false,
                renderedInDay: false,
                hasCrossDayPreview: false
            )
        }

        let matchingOccurrence = occurrences.first { $0.id == draggingOccurrenceID }
        let hasOccurrenceInDay = matchingOccurrence != nil
        let renderedInDay = matchingOccurrence.flatMap { adjustedRange(for: $0) } != nil
        let hasCrossDayPreview = dragPreviewInfo != nil

        return DraggedOccurrenceRenderHealth(
            draggingEventID: dragState.draggingEventID,
            draggingOccurrenceID: draggingOccurrenceID,
            dragMode: dragState.dragMode,
            hasOccurrenceInDay: hasOccurrenceInDay,
            renderedInDay: renderedInDay,
            hasCrossDayPreview: hasCrossDayPreview
        )
    }

    /// Check if we need to show a drag preview for an event being dragged from another day
    /// Returns (event, clipped range for this day) if preview should be shown
    private var dragPreviewInfo: (event: Event, range: Event.TimeRange)? {
        guard let event = dragState.draggingEvent,
              let draggingOccurrenceID = dragState.draggingOccurrenceID,
              let previewRange = dragState.previewRange(hourHeight: hourHeight),
              dragState.dragMode == .move else { return nil }

        // Check if preview range intersects this day
        guard previewRange.end > visibleStart && previewRange.start < visibleEnd else { return nil }

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
        let clippedStart = max(previewRange.start, visibleStart)
        let clippedEnd = min(previewRange.end, visibleEnd)
        let clippedRange = Event.TimeRange(start: clippedStart, end: clippedEnd)

        return (event, clippedRange)
    }

    /// Calculate the adjusted display range for an occurrence during drag
    /// Returns the new clipped range for this day, or nil if the event no longer intersects this day
    private func adjustedRange(for occurrence: CalendarLayout.EventOccurrence) -> Event.TimeRange? {
        return calendarAdjustedOccurrenceRange(
            occurrenceID: occurrence.id,
            occurrenceRange: occurrence.range,
            draggingOccurrenceID: dragState.draggingOccurrenceID,
            dragMode: dragState.dragMode,
            previewRange: dragState.previewRange(hourHeight: hourHeight),
            dayStart: visibleStart,
            dayEnd: visibleEnd
        )
    }

    var body: some View {
        // Explicitly subscribe to dragState changes to ensure SwiftUI tracks them
        let draggingID = dragState.draggingEventID
        let _ = dragState.dragOffset  // Force subscription for reactive updates
        let currentMode = dragState.dragMode
        let renderHealth = draggedOccurrenceRenderHealth

        ZStack(alignment: .topLeading) {
            extensionRegionBackdrop
            grid

            // Creation gesture layer (below events so event gestures take priority)
            if isCreateEnabled {
                creationGestureLayer
            } else if onNonEventTap != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onNonEventTap?()
                    }
            }

            // Existing events (above gesture layer, their gestures take priority)
            let visibleOccurrences = occurrences.compactMap { occurrence in
                adjustedRange(for: occurrence).map { displayRange in
                    CalendarLayout.EventOccurrence(
                        id: occurrence.id,
                        event: occurrence.event,
                        range: displayRange
                    )
                }
            }
            // Pre-build parent lookup: anchorEventID → parent occurrence
            let interruptParentLookup: [UUID: CalendarLayout.EventOccurrence] = {
                var lookup: [UUID: CalendarLayout.EventOccurrence] = [:]
                for occ in visibleOccurrences where !occ.event.isInterrupt {
                    lookup[interruptAnchorEventID(for: occ.event)] = occ
                }
                return lookup
            }()

            // Pre-build children lookup: parentEventID → [child occurrence]
            let interruptChildrenLookup: [UUID: [CalendarLayout.EventOccurrence]] = {
                var lookup: [UUID: [CalendarLayout.EventOccurrence]] = [:]
                for occ in visibleOccurrences {
                    guard let relation = occ.event.interruptRelation,
                          relation.state == .embedded else { continue }
                    lookup[relation.parentEventID, default: []].append(occ)
                }
                return lookup
            }()

            // Pre-compute embedded state for all interrupt occurrences
            let embeddedInterruptIDs: Set<String> = {
                var ids = Set<String>()
                for occ in visibleOccurrences {
                    guard occ.event.isInterrupt,
                          let relation = occ.event.interruptRelation,
                          relation.state == .embedded,
                          let parentOcc = interruptParentLookup[relation.parentEventID],
                          let parentRange = adjustedRange(for: parentOcc) else { continue }
                    let liveRange = liveOccurrenceRange(for: occ)
                    if liveRange.end > parentRange.start && liveRange.start < parentRange.end {
                        ids.insert(occ.id)
                    }
                }
                return ids
            }()

            // Exclude interrupt children from overlap layout when they should be embedded
            let overlapCandidates = visibleOccurrences.filter { occurrence in
                guard occurrence.event.isInterrupt,
                      occurrence.event.interruptRelation != nil else {
                    return true
                }
                if embeddedInterruptIDs.contains(occurrence.id) {
                    return false
                }
                if isActiveDraggedOccurrence(
                    occurrenceID: occurrence.id,
                    draggingOccurrenceID: dragState.draggingOccurrenceID,
                    dragMode: currentMode
                ) {
                    return false
                }
                return true
            }
            let overlapSlots = CalendarLayout.overlapLayout(
                for: overlapCandidates,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd
            )

            ForEach(occurrences) { occurrence in
                // Calculate adjusted range for drag (dynamically re-clips to this day)
                if let displayRange = adjustedRange(for: occurrence) {
                    let slot = overlapSlots[occurrence.id] ?? .default
                    let eventAreaWidth = contentWidth - eventHorizontalInset * 2
                    let isDraggedOccurrence = isActiveDraggedOccurrence(
                        occurrenceID: occurrence.id,
                        draggingOccurrenceID: dragState.draggingOccurrenceID,
                        dragMode: currentMode
                    )
                    let shouldUseEmbeddedInterruptOverlay = calendarShouldUseEmbeddedInterruptOverlay(
                        interruptIsCurrentlyEmbedded: embeddedInterruptIDs.contains(occurrence.id),
                        isActiveDraggedOccurrence: isDraggedOccurrence,
                        dragMode: currentMode
                    )
                    let shouldUseInterruptDragSourceFrame = calendarShouldUseInterruptDragSourceFrame(
                        isInterruptEvent: occurrence.event.isInterrupt,
                        relationState: occurrence.event.interruptRelation?.state,
                        isActiveDraggedOccurrence: isDraggedOccurrence,
                        dragMode: currentMode
                    )
                    let interruptParentSlotContext: (occurrence: CalendarLayout.EventOccurrence, slot: CalendarLayout.EventOverlapSlot)? = {
                        guard let relation = occurrence.event.interruptRelation,
                              let parentOccurrence = interruptParentLookup[relation.parentEventID],
                              let parentSlot = overlapSlots[parentOccurrence.id] else {
                            return nil
                        }
                        return (parentOccurrence, parentSlot)
                    }()
                    let draggedInterruptSourceGeometry: CalendarInterruptOverlayGeometry? = {
                        guard shouldUseInterruptDragSourceFrame,
                              let parentSlotContext = interruptParentSlotContext else {
                            return nil
                        }
                        let parentWidth = eventAreaWidth * parentSlotContext.slot.widthFraction
                        return calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
                    }()
                    let embeddedOverlayGeometry: CalendarInterruptOverlayGeometry? = {
                        guard shouldUseEmbeddedInterruptOverlay,
                              let parentSlotContext = interruptParentSlotContext else {
                            return nil
                        }
                        let parentWidth = eventAreaWidth * parentSlotContext.slot.widthFraction
                        return calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
                    }()
                    let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
                    let blockWidth = draggedInterruptSourceGeometry?.width
                        ?? embeddedOverlayGeometry?.width
                        ?? (eventAreaWidth * slot.widthFraction - overlapGap)
                    let blockX: CGFloat = {
                        if let draggedInterruptSourceGeometry,
                           let parentSlotContext = interruptParentSlotContext {
                            let parentX = eventHorizontalInset + eventAreaWidth * parentSlotContext.slot.xOffsetFraction
                            return parentX + draggedInterruptSourceGeometry.xOffset
                        }
                        guard let embeddedOverlayGeometry,
                              let parentSlotContext = interruptParentSlotContext else {
                            return eventHorizontalInset + eventAreaWidth * slot.xOffsetFraction
                        }
                        let parentX = eventHorizontalInset + eventAreaWidth * parentSlotContext.slot.xOffsetFraction
                        return parentX + embeddedOverlayGeometry.xOffset
                    }()

                    // Precompute interrupt-related values using lookups
                    let embeddedForBlock = shouldUseEmbeddedInterruptOverlay
                    let childRangesForBlock: [Event.TimeRange] = {
                        guard !occurrence.event.isInterrupt,
                              let children = interruptChildrenLookup[interruptAnchorEventID(for: occurrence.event)],
                              let parentRange = adjustedRange(for: occurrence) else {
                            return []
                        }
                        return children.compactMap { child in
                            let liveRange = liveOccurrenceRange(for: child)
                            guard liveRange.end > parentRange.start,
                                  liveRange.start < parentRange.end else { return nil }
                            return liveRange
                        }
                    }()
                    let parentColorForBlock: Color? = {
                        guard let relation = occurrence.event.interruptRelation,
                              let parentOcc = interruptParentLookup[relation.parentEventID] else {
                            return nil
                        }
                        return CalendarLayout.eventColor(for: parentOcc.event)
                    }()

                    eventBlock(
                        for: occurrence,
                        adjustedRange: displayRange,
                        isEmbeddedInterrupt: embeddedForBlock,
                        embeddedChildRanges: childRangesForBlock,
                        parentColor: parentColorForBlock
                    )
                        .frame(
                            width: max(0, blockWidth),
                            height: max(
                                0,
                                timelineEventHeight(
                                    for: displayRange,
                                    minimumHeight: 0
                                ) - 3
                            ),
                            alignment: .top
                        )
                        .offset(
                            x: blockX,
                            y: timelineYOffset(for: displayRange) + 1.5
                        )
                        .zIndex({
                            let base: Double
                            if occurrence.event.id == focusedEventID {
                                base = 3
                            } else if previewHandleEventID == occurrence.event.id
                                        && (previewHandleOccurrenceID == nil || previewHandleOccurrenceID == occurrence.id) {
                                base = 2.5
                            } else if graceResizeEventID == occurrence.event.id
                                        && (graceResizeOccurrenceID == nil || graceResizeOccurrenceID == occurrence.id) {
                                base = 2
                            } else {
                                base = 0
                            }
                            let interruptBoost = occurrence.event.interruptRelation?.state == .embedded ? 0.35 : 0
                            return base + slot.zIndex + interruptBoost
                        }())
                }
            }

            // Drag preview for cross-day events (shows new day coverage during drag)
            // Use captured values to ensure reactive updates
            if draggingID != nil && currentMode == .move {
                if let (event, previewRange) = dragPreviewInfo {
                    if event.isInterrupt,
                       let relation = event.interruptRelation,
                       let parentOcc = occurrences.first(where: { candidate in
                           !candidate.event.isInterrupt
                           && interruptAnchorEventID(for: candidate.event) == relation.parentEventID
                       }),
                       let parentSlot = overlapSlots[parentOcc.id] {
                        let eventAreaWidth = contentWidth - eventHorizontalInset * 2
                        let parentWidth = eventAreaWidth * parentSlot.widthFraction
                        let parentX = eventHorizontalInset + eventAreaWidth * parentSlot.xOffsetFraction
                        let childGeo = calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
                        interruptDragPreview(
                            for: event,
                            range: previewRange,
                            blockWidth: childGeo.width,
                            blockX: parentX + childGeo.xOffset,
                            parentRange: parentOcc.range,
                            parentWidth: parentWidth,
                            parentX: parentX
                        )
                    } else {
                        dragPreview(for: event, range: previewRange)
                    }
                }
            }

            // Creation preview (topmost, no hit testing)
            // Shows during drag OR while form sheet is open
            if let previewRange = activePreviewRange {
                creationPreview(for: previewRange)
                    .zIndex(5)
            }

            // Live interrupt block (growing hatched rectangle)
            if let session = liveInterruptSession,
               Calendar.current.isDate(session.startedAt, inSameDayAs: date) {
                let parentOccurrenceID = occurrences.first { $0.event.id == session.parentEventID }?.id
                let parentSlot = parentOccurrenceID.flatMap { overlapSlots[$0] } ?? .default
                let eventAreaWidth = contentWidth - eventHorizontalInset * 2
                let parentWidth = eventAreaWidth * parentSlot.widthFraction
                let parentX = eventHorizontalInset + eventAreaWidth * parentSlot.xOffsetFraction
                let childGeometry = calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
                liveInterruptBlock(
                    session: session,
                    blockWidth: childGeometry.width,
                    blockX: parentX + childGeometry.xOffset
                )
                    .zIndex(4)
            }

            nowIndicator
                .zIndex(100)
        }
        .id("\(style.variant)-\(date.timeIntervalSince1970)")
        .onChange(of: renderHealth) { oldValue, newValue in
            guard newValue.dragMode == .move,
                  let draggingOccurrenceID = newValue.draggingOccurrenceID else { return }

            if newValue.hasOccurrenceInDay && !newValue.renderedInDay {
                calendarDebugLog(
                    "timeline.drag.render.missingActiveOccurrence",
                    fields: [
                        "date": calendarDebugDayString(date),
                        "draggingEventID": newValue.draggingEventID?.uuidString ?? "nil",
                        "draggingOccurrenceID": draggingOccurrenceID,
                        "hasOccurrenceInDay": "\(newValue.hasOccurrenceInDay)",
                        "renderedInDay": "\(newValue.renderedInDay)",
                        "hasCrossDayPreview": "\(newValue.hasCrossDayPreview)"
                    ]
                )
            } else if oldValue.hasOccurrenceInDay && !oldValue.renderedInDay
                        && newValue.hasOccurrenceInDay && newValue.renderedInDay {
                calendarDebugLog(
                    "timeline.drag.render.recoveredActiveOccurrence",
                    fields: [
                        "date": calendarDebugDayString(date),
                        "draggingEventID": newValue.draggingEventID?.uuidString ?? "nil",
                        "draggingOccurrenceID": draggingOccurrenceID,
                        "hasCrossDayPreview": "\(newValue.hasCrossDayPreview)"
                    ]
                )
            }
        }
        .onChange(of: creationPreviewRange) { _, newValue in
            onCreationPreviewChanged?(date, newValue)
        }
        .onChange(of: leadingExtendedHours) { oldValue, newValue in
            guard isCreating else { return }
            creationStartY = calendarAdjustedCreationDragYForLeadingBoundaryExtensionChange(
                creationStartY,
                previousLeadingHours: oldValue,
                currentLeadingHours: newValue,
                hourHeight: hourHeight
            )
            creationCurrentY = calendarAdjustedCreationDragYForLeadingBoundaryExtensionChange(
                creationCurrentY,
                previousLeadingHours: oldValue,
                currentLeadingHours: newValue,
                hourHeight: hourHeight
            )
        }
        .onDisappear {
            onCreationPreviewChanged?(date, nil)
        }
    }

    // MARK: - Creation Gesture

    private var creationGestureLayer: some View {
        CreationDragGesture(
            minimumPressDuration: 0.5,
            isAutoScrollEnabled: isCreating,
            onTap: {
                onNonEventTap?()
            },
            onBegan: { y in
                isLongPressingCreation = true
                isCreating = false
                creationStartY = y
                creationCurrentY = y
                lastTickMinutes = -1
                hapticFeedback.impactOccurred()
            },
            onChanged: { y in
                guard isLongPressingCreation else { return }
                creationCurrentY = y
                if !isCreating {
                    let deltaY = y - creationStartY
                    if calendarShouldActivateCreationAfterLongPress(
                        dragDeltaY: deltaY,
                        threshold: creationActivationThreshold
                    ) {
                        isCreating = true
                        lastTickMinutes = currentSnappedMinutes(for: y)
                        hapticFeedback.impactOccurred()
                    }
                    return
                }
                checkHapticTick()
            },
            onEnded: { _ in
                if isCreating, let range = creationPreviewRange {
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
                isLongPressingCreation = false
                lastTickMinutes = -1
            },
            onCancelled: {
                isCreating = false
                isLongPressingCreation = false
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
        let y = timelineYOffset(for: range)
        let isZeroDuration = range.end.timeIntervalSince(range.start) < 1
        let height = timelineEventHeight(
            for: range,
            minimumHeight: 0
        )

        let creationColor = calendarCurrentTimeIndicatorColor()
        return RoundedRectangle(cornerRadius: isZeroDuration ? 2 : 10, style: .continuous)
            .fill(creationColor.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: isZeroDuration ? 2 : 10, style: .continuous)
                    .stroke(creationColor.opacity(0.6), lineWidth: 2)
            )
            .overlay(
                Group {
                    if height >= 24 {
                        VStack(alignment: .leading, spacing: isWeekMode ? 1 : 2) {
                            Text(L(.newEvent))
                                .font(.system(size: isWeekMode ? 8 : (isThreeDayMode ? 10 : 12), weight: .semibold))
                            Text(timeRangeText(for: range))
                                .font(.system(size: isWeekMode ? 7 : 8, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(isWeekMode ? 4 : 8)
                    }
                },
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
        calendarTimelineDateFromYPosition(
            y,
            containing: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours,
            snapMinutes: snapMinutes
        )
    }

    private func currentSnappedMinutes(for y: CGFloat) -> Int {
        let time = timeFromY(y)
        return Int(round(time.timeIntervalSince(visibleStart) / 60))
    }

    private func checkHapticTick() {
        let currentMinutes = currentSnappedMinutes(for: creationCurrentY)
        if currentMinutes != lastTickMinutes {
            lastTickMinutes = currentMinutes
            hapticFeedback.impactOccurred()
        }
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mma"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return formatter
    }

    private func timeRangeText(for range: Event.TimeRange) -> String {
        "\(Self.timeFormatter.string(from: range.start)) - \(Self.timeFormatter.string(from: range.end))"
    }

    /// Preview block for an event being dragged into this day from another day
    private func dragPreview(for event: Event, range: Event.TimeRange) -> some View {
        dragPreview(
            for: event,
            range: range,
            blockWidth: contentWidth - eventHorizontalInset * 2,
            blockX: eventHorizontalInset
        )
    }

    private func dragPreview(for event: Event, range: Event.TimeRange, blockWidth: CGFloat, blockX: CGFloat) -> some View {
        let color = CalendarLayout.eventColor(for: event)
        let cornerRadius: CGFloat = event.isInterrupt ? 5 : 10
        let height = timelineEventHeight(
            for: range,
            minimumHeight: 0
        )
        let y = timelineYOffset(for: range)

        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
                width: max(0, blockWidth),
                height: height
            )
            .offset(x: blockX, y: y)
            .scaleEffect(
                calendarEventBlockScale(
                    isMoveDragging: true,
                    isFocused: false,
                    isDimmedByFocus: false
                )
            )
            .shadow(radius: 8)
            .allowsHitTesting(false)
    }

    /// Dedicated preview for an interrupt event being dragged back to its parent's day.
    /// Shows the interrupt embedded inside the parent with proper positioning.
    @ViewBuilder
    private func interruptDragPreview(
        for event: Event,
        range: Event.TimeRange,
        blockWidth: CGFloat,
        blockX: CGFloat,
        parentRange: Event.TimeRange,
        parentWidth: CGFloat,
        parentX: CGFloat
    ) -> some View {
        let color = CalendarLayout.eventColor(for: event)
        let childHeight = timelineEventHeight(
            for: range,
            minimumHeight: 0
        )
        let childY = timelineYOffset(for: range) + 1.5

        ZStack(alignment: .topLeading) {
            Color.clear

            // Interrupt child preview (embedded in parent)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
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
                .frame(width: max(0, blockWidth), height: childHeight)
                .offset(x: blockX, y: childY)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func liveInterruptBlock(
        session: CalendarInterruptLiveSession,
        blockWidth: CGFloat,
        blockX: CGFloat
    ) -> some View {
        let interruptColor = EventTypeTemplateStore.color(for: session.typeTitle)

        Group {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                let range = Event.TimeRange(start: session.startedAt, end: now)
                let blockHeight = max(4, timelineEventHeight(for: range, minimumHeight: 0) - 3)
                let blockY = timelineYOffset(for: range) + 1.5

                ZStack(alignment: .topLeading) {
                    Color.clear

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(interruptColor.opacity(0.12))
                        .overlay {
                            DiagonalHatchingPattern(spacing: 6, lineWidth: 1)
                                .stroke(interruptColor.opacity(0.35), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(interruptColor.opacity(0.4), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if blockHeight >= 20 {
                                Text(session.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(interruptColor)
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .padding(.top, 3)
                            }
                        }
                        .frame(width: blockWidth, height: blockHeight)
                        .offset(x: blockX, y: blockY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var nowIndicator: some View {
        Group {
            if calendarShouldShowNowIndicator(for: date) {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = context.date
                    let indicatorColor = calendarCurrentTimeIndicatorColor()
                    let y = nowIndicatorYOffset(for: now)
                    let lineHeight: CGFloat = 1.5
                    let dotSize: CGFloat = 7

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(indicatorColor.opacity(0.92))
                            .frame(width: contentWidth - eventHorizontalInset * 2, height: lineHeight)
                            .offset(x: eventHorizontalInset, y: y - lineHeight / 2)
                        Circle()
                            .fill(indicatorColor)
                            .frame(width: dotSize, height: dotSize)
                            .offset(x: eventHorizontalInset - dotSize / 2, y: y - dotSize / 2)
                    }
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static var nowTimeFormatter: DateFormatter {
        let f = DateFormatter()
        if AppTimeFormat.current.is24 {
            f.dateFormat = "H:mm"
        } else {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mma"
            f.amSymbol = "am"
            f.pmSymbol = "pm"
        }
        return f
    }

    private func nowIndicatorYOffset(for now: Date) -> CGFloat {
        calendarTimelineYPosition(
            for: now,
            containing: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
    }

    private func timelineYOffset(for range: Event.TimeRange) -> CGFloat {
        calendarTimelineYPosition(
            for: range.start,
            containing: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
    }

    private func timelineEventHeight(
        for range: Event.TimeRange,
        minimumHeight: CGFloat
    ) -> CGFloat {
        let start = max(range.start, visibleStart)
        let end = min(range.end, visibleEnd)
        let seconds = max(0, end.timeIntervalSince(start))
        return max(minimumHeight, CGFloat(seconds / 3600) * hourHeight)
    }

    private var grid: some View {
        let lineWidth = max(0, contentWidth - eventHorizontalInset * 2)

        let isHalfHourGrid = slotMinutes == 30

        return VStack(spacing: 0) {
            Color.clear.frame(width: contentWidth, height: headerHeight, alignment: .center)
            ForEach(0..<slotCount, id: \.self) { index in
                let isSubHourLine = isHalfHourGrid && index % 2 != 0
                if style.gridDashed {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundColor(style.gridColor)
                        .frame(width: lineWidth, height: 1)
                        .frame(width: contentWidth, height: slotHeight, alignment: .top)
                } else if isSubHourLine {
                    Path { path in
                        path.move(to: .zero)
                        path.addLine(to: CGPoint(x: lineWidth, y: 0))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                    .foregroundColor(style.gridColor)
                    .frame(width: lineWidth, height: 1)
                    .frame(width: contentWidth, height: slotHeight, alignment: .top)
                } else {
                    Rectangle()
                        .fill(style.gridColor)
                        .frame(width: lineWidth, height: 1)
                        .frame(width: contentWidth, height: slotHeight, alignment: .top)
                }
            }
            Color.clear.frame(width: contentWidth, height: timelineBottomInset)
        }
    }

    private func interruptAnchorEventID(for event: Event) -> UUID {
        event.recurrenceParentId ?? event.id
    }

    private func interruptParentColor(for event: Event) -> Color? {
        guard let relation = event.interruptRelation else { return nil }
        return occurrences.first(where: { candidate in
            interruptAnchorEventID(for: candidate.event) == relation.parentEventID
        }).map { match in
            CalendarLayout.eventColor(for: match.event)
        }
    }

    private func interruptParentOccurrence(for event: Event) -> CalendarLayout.EventOccurrence? {
        guard let relation = event.interruptRelation else { return nil }
        return occurrences.first(where: { candidate in
            !candidate.event.isInterrupt && interruptAnchorEventID(for: candidate.event) == relation.parentEventID
        })
    }

    private func liveOccurrenceRange(
        for occurrence: CalendarLayout.EventOccurrence
    ) -> Event.TimeRange {
        calendarResolvedLiveOccurrenceRange(
            occurrenceID: occurrence.id,
            occurrenceRange: occurrence.range,
            draggingOccurrenceID: dragState.draggingOccurrenceID,
            draggingOriginalRange: dragState.draggingOriginalRange,
            dragOffset: dragState.dragOffset,
            dragMode: dragState.dragMode,
            hourHeight: hourHeight,
            dayColumnStep: dragState.dayColumnStep
        )
    }

    private func interruptIsCurrentlyEmbedded(
        for occurrence: CalendarLayout.EventOccurrence
    ) -> Bool {
        guard let relation = occurrence.event.interruptRelation,
              relation.state == .embedded,
              let parentOccurrence = interruptParentOccurrence(for: occurrence.event),
              let parentRange = adjustedRange(for: parentOccurrence) else {
            return false
        }

        let liveRange = liveOccurrenceRange(for: occurrence)
        return liveRange.end > parentRange.start && liveRange.start < parentRange.end
    }

    private func interruptEmbeddedChildRanges(
        for occurrence: CalendarLayout.EventOccurrence
    ) -> [Event.TimeRange] {
        guard !occurrence.event.isInterrupt,
              let parentRange = adjustedRange(for: occurrence) else {
            return []
        }
        let anchorID = interruptAnchorEventID(for: occurrence.event)
        return occurrences.compactMap { candidate in
            guard let relation = candidate.event.interruptRelation,
                  relation.parentEventID == anchorID,
                  relation.state == .embedded else {
                return nil
            }
            let liveRange = liveOccurrenceRange(for: candidate)
            guard liveRange.end > parentRange.start,
                  liveRange.start < parentRange.end else {
                return nil
            }
            return liveRange
        }
    }

    private func eventBlock(
        for occurrence: CalendarLayout.EventOccurrence,
        adjustedRange: Event.TimeRange,
        isEmbeddedInterrupt: Bool = false,
        embeddedChildRanges: [Event.TimeRange] = [],
        parentColor: Color? = nil
    ) -> some View {
        let event = occurrence.event
        let originalRange = occurrence.range
        let actionDate = occurrence.range.start
        let isEventFocused = focusedEventID == event.id
            && (focusedOccurrenceID == nil || focusedOccurrenceID == occurrence.id)
        let isPreviewHandleTarget = previewHandleEventID == event.id
            && (previewHandleOccurrenceID == nil || previewHandleOccurrenceID == occurrence.id)
        let isGraceResizeTarget = graceResizeEventID == event.id
            && (graceResizeOccurrenceID == nil || graceResizeOccurrenceID == occurrence.id)
        let blockStyle: EventBlockStyle = isEventFocused ? .edit : .preview
        let isInteractionAllowed = calendarShouldAllowEventInteraction(
            focusedEventID: focusedEventID,
            candidateEventID: event.id,
            isFocusContextActive: isFocusContextActive
        )
        let showsResizeHandles = isEventFocused || isPreviewHandleTarget || isGraceResizeTarget
        let resolvedHandleOpacity: Double = isEventFocused
            ? 1
            : (isPreviewHandleTarget ? previewHandleOpacity : graceResizeHandleOpacity)
        let canMove = isPreviewHandleTarget || !isGraceResizeTarget

        // Keep handles available while the adjusted range remains inside the
        // temporary extended viewport.
        let startsBeforeVisibleRange = adjustedRange.start <= visibleStart
        let endsAfterVisibleRange = adjustedRange.end >= visibleEnd

        return EventBlock(
            event: event,
            occurrenceID: occurrence.id,
            dragSourceRange: originalRange,
            displayRange: adjustedRange,
            color: event.agenticIntake?.processingPhase == .analyzing
                ? calendarCurrentTimeIndicatorColor()
                : CalendarLayout.eventColor(for: event),
            showText: showEventText,
            isWeekMode: isWeekMode,
            isThreeDayMode: isThreeDayMode,
            style: blockStyle,
            hourHeight: hourHeight,
            dayColumnStep: dayColumnStep,
            dragPreviewDayStep: dragPreviewDayStep,
            showsResizeHandles: showsResizeHandles,
            resizeHandleOpacity: resolvedHandleOpacity,
            canMove: canMove,
            isFocused: isEventFocused,
            isFocusContextActive: isFocusContextActive,
            onTap: (!isPinchActive && onEventTap != nil) ? { onEventTap?(event, actionDate) } : nil,
            onLongPressBegan: (!isPinchActive && onEventLongPressBegan != nil) ? { dragMode, touchPointGlobal, eventFrameGlobal in
                onEventLongPressBegan?(
                    CalendarEventLongPressBegan(
                        event: event,
                        occurrenceID: occurrence.id,
                        actionDate: actionDate,
                        dragMode: dragMode,
                        touchPointGlobal: touchPointGlobal,
                        eventFrameGlobal: eventFrameGlobal
                    )
                )
            } : nil,
            onManipulationPromotion: (onEventManipulationPromotion != nil && isInteractionAllowed) ? { dragMode, touchPointGlobal, eventFrameGlobal in
                onEventManipulationPromotion?(
                    event,
                    occurrence.id,
                    actionDate,
                    dragMode,
                    touchPointGlobal,
                    eventFrameGlobal
                )
            } : nil,
            onLongPressResolved: onEventLongPressResolved != nil ? { dragMode, terminalState, didMove, touchPointGlobal in
                onEventLongPressResolved?(
                    CalendarEventLongPressResolution(
                        event: event,
                        occurrenceID: occurrence.id,
                        actionDate: actionDate,
                        dragMode: dragMode,
                        terminalState: terminalState,
                        didMove: didMove,
                        touchPointGlobal: touchPointGlobal
                    )
                )
            } : nil,
            onDragEnded: (onEventDragEnded != nil && isInteractionAllowed && !isGraceResizeTarget) ? { offset in
                calendarDebugLog(
                    "calendar.timeline.event.dragEndForward",
                    fields: [
                        "eventID": event.id.uuidString,
                        "occurrenceID": occurrence.id,
                        "offsetX": String(format: "%.2f", offset.x),
                        "offsetY": String(format: "%.2f", offset.y),
                        "focusedEventID": focusedEventID?.uuidString ?? "nil",
                        "focusedOccurrenceID": focusedOccurrenceID ?? "nil",
                        "isEventFocused": "\(isEventFocused)",
                        "style": blockStyle == .edit ? "edit" : "preview"
                    ]
                )
                onEventDragEnded?(event, occurrence.id, originalRange, offset, dragPreviewDayStep)
            } : nil,
            onResizeTopEnded: (onEventResizeEnded != nil && isInteractionAllowed) ? { yOffset in
                onEventResizeEnded?(event, occurrence.id, originalRange, actionDate, .resizeTop, yOffset)
            } : nil,
            onResizeBottomEnded: (onEventResizeEnded != nil && isInteractionAllowed) ? { yOffset in
                onEventResizeEnded?(event, occurrence.id, originalRange, actionDate, .resizeBottom, yOffset)
            } : nil,
            // Disable resize handles for cross-day boundaries
            canResizeTop: !startsBeforeVisibleRange,
            canResizeBottom: !endsAfterVisibleRange,
            isTimerActive: event.timerStartedAt != nil,
            agenticProcessingPhase: event.agenticIntake?.processingPhase,
            interruptState: event.interruptRelation?.state,
            interruptParentColor: parentColor,
            interruptIsCurrentlyEmbedded: isEmbeddedInterrupt,
            interruptEmbeddedChildRanges: embeddedChildRanges,
            // Cross-day drag sync
            dragState: dragState
        )
    }

    @ViewBuilder
    private var extensionRegionBackdrop: some View {
        let tint = Color.secondary.opacity(0.05)
        let separator = Color.secondary.opacity(0.12)
        let leadingHeight = CGFloat(max(0, leadingExtendedHours)) * hourHeight
        let trailingHeight = CGFloat(max(0, trailingExtendedHours)) * hourHeight
        let baseStartY = headerHeight + leadingHeight
        let baseEndY = baseStartY + CGFloat(calendarTimelineBaseVisibleHours) * hourHeight

        ZStack(alignment: .topLeading) {
            if leadingHeight > 0 {
                Rectangle()
                    .fill(tint)
                    .frame(width: contentWidth, height: leadingHeight)
                    .offset(y: headerHeight)

                Rectangle()
                    .fill(separator)
                    .frame(width: contentWidth, height: 1)
                    .offset(y: baseStartY)
            }

            if trailingHeight > 0 {
                Rectangle()
                    .fill(tint)
                    .frame(width: contentWidth, height: trailingHeight)
                    .offset(y: baseEndY)

                Rectangle()
                    .fill(separator)
                    .frame(width: contentWidth, height: 1)
                    .offset(y: baseEndY)
            }
        }
        .allowsHitTesting(false)
    }

}
