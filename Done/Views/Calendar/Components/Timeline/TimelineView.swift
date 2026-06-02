//
//  TimelineView.swift
//  Done
//
//  Timeline 视图：包含容器、日视图、样式定义
//

import SwiftUI
import UIKit
import os
import UniformTypeIdentifiers

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
            logger.info("file=\(fileURL.path, privacy: .public)")
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

// MARK: - Drag Anomaly Detection System

private let _dragLogPath = "/tmp/scroll_bug.log"

/// Severity levels for anomaly detection
enum DragAnomalySeverity: String {
    case info = "INFO"       // Normal lifecycle events
    case warn = "WARN"       // Unexpected but non-fatal
    case error = "ERROR"     // Bug detected — drag killed or state corrupted
}

/// Tracks drag session state for anomaly detection
final class DragSessionMonitor {
    static let shared = DragSessionMonitor()

    private(set) var activeEventID: String?
    private(set) var dragStartTime: CFTimeInterval = 0
    private(set) var lastOffsetY: CGFloat = 0
    private(set) var lastFrameHeight: CGFloat = 0
    private(set) var lastFrameWidth: CGFloat = 0
    private(set) var lastSlotWidth: CGFloat = 0
    private(set) var frameChangeCount: Int = 0
    private(set) var touchCancelCount: Int = 0
    private(set) var makeUIViewCount: Int = 0

    func beginSession(eventID: String) {
        activeEventID = eventID
        dragStartTime = CACurrentMediaTime()
        lastOffsetY = 0
        lastFrameHeight = 0
        lastFrameWidth = 0
        lastSlotWidth = 0
        frameChangeCount = 0
        touchCancelCount = 0
        makeUIViewCount = 0
    }

    func endSession() {
        activeEventID = nil
    }

    /// Returns anomaly description if frame changed unexpectedly, nil otherwise
    func checkFrame(eventID: String, height: CGFloat, width: CGFloat, slotW: CGFloat) -> String? {
        guard eventID.hasPrefix(activeEventID?.prefix(8) ?? "---") else { return nil }
        var anomalies: [String] = []

        if lastFrameHeight > 0 && abs(height - lastFrameHeight) > 20 {
            anomalies.append("HEIGHT_JUMP \(String(format:"%.0f",lastFrameHeight))→\(String(format:"%.0f",height))")
            frameChangeCount += 1
        }
        if lastFrameWidth > 0 && abs(width - lastFrameWidth) > 5 {
            anomalies.append("WIDTH_JUMP \(String(format:"%.0f",lastFrameWidth))→\(String(format:"%.0f",width))")
            frameChangeCount += 1
        }
        if lastSlotWidth > 0 && abs(slotW - lastSlotWidth) > 0.01 {
            anomalies.append("SLOT_JUMP \(String(format:"%.2f",lastSlotWidth))→\(String(format:"%.2f",slotW))")
        }

        lastFrameHeight = height
        lastFrameWidth = width
        lastSlotWidth = slotW
        return anomalies.isEmpty ? nil : anomalies.joined(separator: " ")
    }

    func recordTouchCancel() { touchCancelCount += 1 }
    func recordMakeUIView() { makeUIViewCount += 1 }
}

func dragMovementLog(_ message: String, severity: DragAnomalySeverity = .info) {
    #if DEBUG
    let ts = String(format: "%.3f", CACurrentMediaTime())
    let line = "[\(ts)] [\(severity.rawValue)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: _dragLogPath),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: _dragLogPath)) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: _dragLogPath))
        }
    }
    #endif
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

// Extracted for regression tests: render gating — only fully render day columns
// within a buffer around the visible center.  Days outside the buffer become
// lightweight placeholders (Color.clear) so that the HStack stays stable (no
// LazyHStack recycling that kills gesture coordinators) while avoiding the cost
// of rendering 60+ full day columns.
func calendarShouldRenderFullDayColumn(
    offset: Int,
    renderCenter: Int,
    renderBuffer: Int,
    dragSourceDayOffset: Int?
) -> Bool {
    if abs(offset - renderCenter) <= renderBuffer { return true }
    // Safety guard: never replace the drag source day with a placeholder —
    // the UIViewRepresentable gesture coordinator must stay alive.
    if let sourceDayOffset = dragSourceDayOffset, offset == sourceDayOffset { return true }
    return false
}

// Extracted for regression tests: compute the day offset of the drag source
// event so the render gating guard can keep it alive during drag.
func calendarDragSourceDayOffset(
    draggingOriginalRange: Event.TimeRange?,
    reference: Date = Date(),
    calendar: Calendar = .current
) -> Int? {
    guard let range = draggingOriginalRange else { return nil }
    let today = calendar.startOfDay(for: reference)
    let eventDay = calendar.startOfDay(for: range.start)
    return calendar.dateComponents([.day], from: today, to: eventDay).day
}

/// Equatable gate controlled solely by scroll state.
/// - Scrolling: `==` uses (offset, shouldRender) → blocks body re-eval
/// - Not scrolling: `==` returns false → all updates propagate
///
/// Safe because the user's interaction pattern guarantees scroll and
/// data changes are mutually exclusive.
private struct DayColumnGate<Content: View>: View, Equatable {
    let offset: Int
    let shouldRender: Bool
    let isScrolling: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if shouldRender {
            content()
        } else {
            Color.clear
        }
    }

    static func == (lhs: DayColumnGate, rhs: DayColumnGate) -> Bool {
        guard lhs.isScrolling && rhs.isScrolling else { return false }
        return lhs.offset == rhs.offset && lhs.shouldRender == rhs.shouldRender
    }
}

// Extracted for regression tests: compute the render buffer size based on the
// number of visible day columns.  Must be large enough that all visible days
// plus at least 2 days of buffer on each side are rendered.
func calendarRenderBuffer(daysCount: Int) -> Int {
    max(daysCount / 2 + 4, 7)
}

// Extracted for regression tests: a day is "in the visible viewport" if the
// user can actually see it on screen — i.e. it falls within the daysCount
// window centered on selectedDayOffset.  Render-gated buffer days that exist
// only to keep the view tree stable are NOT in the visible viewport.
//
// Used by TimelineDayView to skip drag-preview computation (which reads
// `dragOffset` via `liveDraggedPreviewRange`) for days the user cannot see.
// Without this gate, all 11 render-gated days would track dragOffset and
// rebuild every drag frame, defeating the @Observable optimization.
func calendarIsDayInVisibleViewport(
    offset: Int,
    selectedDayOffset: Int,
    daysCount: Int
) -> Bool {
    let halfWidth = (daysCount - 1) / 2
    return abs(offset - selectedDayOffset) <= halfWidth
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
    max(8, round(hourHeight * 0.15))
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

// Extracted for regression tests: compute the largest hourHeight at which
// 24 hours fits inside the user-visible (unobscured) viewport region —
// the "whole day at once, bottom just above the tab bar" snap point.
//
// Mode-aware via `contentTopInset`: in 3-day/week mode this includes the
// day-legend bar (34px) and in month mode the month-legend bar.
//
// `contentBottomInset` is normally `safeAreaBottom` (home indicator + tab
// bar area).  Without it, the day would extend behind the tab bar at the
// "exact fit" point, making the bottom hours unreadable.
//
// Layout (from scroll content top to bottom):
//   topOverlayInset + allDayHeight + headerHeight + 24*hourHeight + bottomInset
//
// For small hourHeight (≤ ~50), headerHeight clamps to 14 and bottomInset
// to 8, giving 22px of constant timeline-chrome overhead.
func calendarPinchFitHourHeight(
    viewportHeight: CGFloat,
    contentTopInset: CGFloat,
    contentBottomInset: CGFloat,
    allDayHeight: CGFloat
) -> CGFloat {
    guard viewportHeight > 0 else { return 0 }
    let timelineChromeBudget: CGFloat = 22
    let availableForHours = viewportHeight - contentTopInset - contentBottomInset - allDayHeight - timelineChromeBudget
    guard availableForHours > 0 else { return 0 }
    // Multiply by a small factor (1.02) so the content is slightly
    // taller than the viewport at max pinch.  This guarantees a
    // minimum scrollable range, allowing autoscroll to work when
    // dragging events to the edge for boundary extension.
    return (availableForHours / 24) * 1.02
}

// Extracted for regression tests: the minimum hourHeight allowed during
// the live pinch gesture.  Equals the "exact fit" point — pinching to
// the smallest puts the bottom of the day (24:00) right above the tab
// bar / home indicator, with the entire day visible above.
//
// Mode-aware: 3-day/week mode has a slightly smaller min than day mode
// because the top legend bar (34px) takes space.
//
// `safetyFloor` kicks in only when the viewport is too small to compute
// a meaningful fit (e.g. before initial layout, or pathologically small
// viewports).
func calendarPinchEffectiveMinHourHeight(
    viewportHeight: CGFloat,
    contentTopInset: CGFloat,
    contentBottomInset: CGFloat,
    allDayHeight: CGFloat,
    safetyFloor: CGFloat = calendarTimelineHourHeightMin
) -> CGFloat {
    let fit = calendarPinchFitHourHeight(
        viewportHeight: viewportHeight,
        contentTopInset: contentTopInset,
        contentBottomInset: contentBottomInset,
        allDayHeight: allDayHeight
    )
    return max(safetyFloor, fit)
}

// Extracted for regression tests: capture the time-of-day (hours from midnight)
// at the viewport center.  Used as the pinch anchor so that zooming keeps the
// same time under the user's focus instead of letting the top of the viewport
// stay anchored.
//
// The formula matches `currentTimeScrollOffset` in CalendarPageView:
// `scrollY = topOverlayInset + hours * hourHeight`.
func calendarPinchAnchorTimeHours(
    scrollY: CGFloat,
    viewportHeight: CGFloat,
    topOverlayInset: CGFloat,
    hourHeight: CGFloat
) -> CGFloat {
    guard hourHeight > 0 else { return 0 }
    let viewportCenterY = scrollY + viewportHeight / 2
    return (viewportCenterY - topOverlayInset) / hourHeight
}

// Extracted for regression tests: compute the new scroll Y so that the given
// anchor time stays at the viewport center after the hourHeight has changed.
// Inverse of `calendarPinchAnchorTimeHours`.
func calendarPinchAdjustedScrollY(
    anchorTimeHours: CGFloat,
    viewportHeight: CGFloat,
    topOverlayInset: CGFloat,
    hourHeight: CGFloat
) -> CGFloat {
    let newCenterY = topOverlayInset + anchorTimeHours * hourHeight
    return newCenterY - viewportHeight / 2
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

/// Shared drag state across all event blocks (for cross-day sync).
/// Uses @Observable for fine-grained property tracking — only views that
/// actually read a changed property rebuild their body.  This is critical
/// for drag performance: dragOffset changes every frame, but only the
/// source day and the dragged EventBlock need to react.
@Observable
final class EventDragState {
    var draggingEventID: UUID? = nil
    var draggingOccurrenceID: String? = nil
    var draggingEvent: Event? = nil
    var draggingOriginalRange: Event.TimeRange? = nil
    var draggingRenderDayStart: Date? = nil
    var currentTouchPointGlobal: CGPoint? = nil
    var dragOffset: DragOffset = .zero
    var dragMode: EventDragMode = .move
    var isHorizontalEdgeDragging: Bool = false
    var isHorizontalAutoScrolling: Bool = false
    var dayColumnStep: CGFloat = 0
    /// Spatial-hit result during a `.todo` drag: the `.event` whose
    /// stack-peek column the dragged preview is currently sitting in.
    /// Written by TimelineDayView (it has overlapSlots + spatial info);
    /// read by `CalendarPageView.handleEventDrag` to absorb into the
    /// same event the highlight pointed at. `nil` outside a drag or
    /// when no candidate is under the dragged preview.
    var currentDropTargetEventID: UUID? = nil

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

// Extracted for regression tests: clip the live drag preview to the host day,
// but allow the primary drag projection to keep its original frame alive once
// the preview fully leaves that day so the gesture surface does not disappear.
func calendarAdjustedOccurrenceRange(
    occurrenceID: String,
    occurrenceRange: Event.TimeRange,
    draggingOccurrenceID: String?,
    draggingOriginalRange: Event.TimeRange?,
    dragMode: EventDragMode,
    previewRange: Event.TimeRange?,
    dayStart: Date,
    dayEnd: Date,
    keepOriginalWhenPreviewLeavesDay: Bool = true
) -> Event.TimeRange? {
    _ = draggingOriginalRange
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

    return keepOriginalWhenPreviewLeavesDay ? occurrenceRange : nil
}

func calendarResolvedPrimaryDragRenderDayStart(
    sourceDayStart: Date?,
    dragOffset: DragOffset,
    dayStep: CGFloat,
    usesHorizontalBoundaryPaging: Bool,
    calendar: Calendar = .current
) -> Date? {
    guard let sourceDayStart else { return nil }
    guard usesHorizontalBoundaryPaging else { return sourceDayStart }
    let dayOffset = calendarDayOffsetFromHorizontalDrag(
        offsetX: dragOffset.x,
        dayColumnStep: dayStep
    )
    return calendar.date(byAdding: .day, value: dayOffset, to: sourceDayStart) ?? sourceDayStart
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

    static let view = TimelineStyle(
        variant: .view,
        gridDashed: false,
        gridColor: Color.secondary.opacity(0.15)
    )
}

// MARK: - Helpers (previously computed inside TimelineContainerView)

func timelineDaysCount(for rangeMode: RangeMode) -> Int {
    switch rangeMode {
    case .day, .stream: return 1
    case .threeDay: return 3
    case .week: return 7
    case .month: return 7
    }
}

func timelineShowEventText(for rangeMode: RangeMode) -> Bool {
    switch rangeMode {
    case .day, .threeDay: return true
    case .week: return true
    case .month, .stream: return false
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

// MARK: - Pinch / Horizontal Scroll Coordinator

/// UIViewRepresentable that finds the parent horizontal UIScrollView at
/// runtime and attaches a UIPinchGestureRecognizer to it.  The recognizer
/// uses a **cancel-on-begin** pattern: scroll runs at full speed normally,
/// and is only interrupted at the moment a real pinch crosses its scale
/// threshold (UIPinchGestureRecognizer transitions to `.began`).
///
/// This avoids the latency of `require(toFail:)` (which would force scroll
/// to wait for pinch to fail every time the user tries to pan).  The
/// trade-off: if scroll is already moving when the user starts pinching,
/// the scroll is cancelled mid-gesture — but that's the desired behavior.
///
/// Long-press / event-drag conflict is handled via the
/// `isInteractionBlocked` closure: when an event is being long-pressed or
/// dragged, the pinch recognizer refuses to begin so it doesn't compete
/// with the in-progress event manipulation.
///
/// The recognizer itself does NOT run the pinch zoom logic — the SwiftUI
/// MagnificationGesture in TimelinePagerView still handles that.  This
/// recognizer is purely a "scroll cancellation" trigger plus a guard.
///
/// Graceful fallback: if the parent UIScrollView can't be found (e.g.
/// SwiftUI internal hierarchy changes in a future iOS), the recognizer
/// is never attached and behavior degrades to the existing
/// `.scrollDisabled(isRangePinchActive)` path with no regression.
struct PinchScrollCoordinator: UIViewRepresentable {
    /// Called from the pinch recognizer's `gestureRecognizerShouldBegin`
    /// delegate.  Return true to BLOCK pinch from starting (e.g. when an
    /// event is being long-pressed or dragged).
    var isInteractionBlocked: () -> Bool = { false }

    func makeUIView(context: Context) -> PinchScrollProbeView {
        let view = PinchScrollProbeView()
        view.coordinator = context.coordinator
        context.coordinator.isInteractionBlocked = isInteractionBlocked
        return view
    }

    func updateUIView(_ uiView: PinchScrollProbeView, context: Context) {
        // Refresh the closure on each update so it captures the latest
        // SwiftUI state.
        context.coordinator.isInteractionBlocked = isInteractionBlocked
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var pinchRecognizer: UIPinchGestureRecognizer?
        weak var attachedScrollView: UIScrollView?
        var isInteractionBlocked: () -> Bool = { false }

        func attachIfNeeded(probeView: UIView) {
            if let existing = attachedScrollView, existing.window != nil {
                return
            }
            guard let scrollView = nearestAncestorScrollView(of: probeView) else {
                return
            }

            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(handlePinch(_:))
            )
            pinch.delegate = self
            pinch.cancelsTouchesInView = false  // observe only, don't consume
            scrollView.addGestureRecognizer(pinch)

            // Limit scroll pan to single finger.  When a second finger
            // arrives mid-scroll, UIKit detects the pan has exceeded its
            // max touch count and cancels it, allowing the pinch
            // recognizer to take over — even if the first finger has
            // already scrolled significantly.
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 1

            self.pinchRecognizer = pinch
            self.attachedScrollView = scrollView
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView = attachedScrollView else { return }
            if gesture.state == .began {
                // Cancel any in-progress scroll pan so the pinch takes
                // over.  Toggling isEnabled transitions an active pan
                // into .cancelled immediately.
                let pan = scrollView.panGestureRecognizer
                if pan.state == .began || pan.state == .changed {
                    pan.isEnabled = false
                    pan.isEnabled = true
                }
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Block pinch when an event is being long-pressed or dragged
            // — the user is mid-event-manipulation and pinch should not
            // race with that.
            if gestureRecognizer === pinchRecognizer && isInteractionBlocked() {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Coexist with SwiftUI's MagnificationGesture (which handles
            // the actual zoom) and other recognizers.  We're only here
            // for the cancel-on-begin trigger.
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Never wait for other gestures to fail before starting
            // pinch recognition — we want to detect the second finger
            // as early as possible.
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Don't block other gestures from starting.
            return false
        }

        private func nearestAncestorScrollView(of view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    return scrollView
                }
                current = candidate.superview
            }
            return nil
        }
    }
}

final class PinchScrollProbeView: UIView {
    weak var coordinator: PinchScrollCoordinator.Coordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Don't intercept touches — we just need a foothold in the view
        // hierarchy to find the parent UIScrollView.
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // Defer to the next runloop so SwiftUI's full view hierarchy is
        // settled and superview chain reflects the final layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator?.attachIfNeeded(probeView: self)
        }
    }
}

// MARK: - Timeline Pager (ScrollView)

struct TimelinePagerView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(AppSettingsLocale.timeFormatKey) private var timeFormatRaw = AppTimeFormat.twentyFour.rawValue
    var dragState: EventDragState
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    var allDayOccurrencesForOffset: ((Int) -> [CalendarLayout.EventOccurrence])? = nil
    /// Pre-computed max all-day count across the visible day range, supplied
    /// by the parent.  Avoids a per-body iteration of the entire dayRange.
    var maxAllDayCountOverride: Int? = nil
    @Binding var selectedDayOffset: Int
    @Binding var rangeMode: RangeMode
    @Binding var hourHeight: CGFloat
    // Mirror of `hourHeight` plumbed as a reference, so EventBlock (and any
    // other deep callee that only needs to read the live value) can do so
    // without taking it as a per-frame-invalidating stored property.
    let liveHourHeight: CalendarHourHeightBox
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
    /// Pinch zoom maintains a focal-point anchor: the time at the viewport
    /// center stays put while hourHeight changes.  The parent owns the
    /// vertical scroll, so it must supply current scroll/viewport state and
    /// receive the adjusted Y to apply.
    var verticalScrollY: CGFloat = 0
    var verticalViewportHeight: CGFloat = 0
    var verticalContentTopInset: CGFloat = 0
    /// Bottom safe-area inset (tab bar / home indicator).  Used by the
    /// pinch min calculation so the day's 24:00 mark stays just above the
    /// tab bar at the smallest pinch instead of being hidden behind it.
    var verticalContentBottomInset: CGFloat = 0
    var onPinchScrollAdjust: ((CGFloat) -> Void)? = nil
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
    private var timelineBottomInset: CGFloat { calendarTimelineBottomInset(hourHeight: hourHeight) }
    private var slotMinutes: Int { calendarLegendSlotMinutes(forHourHeight: hourHeight) }
    /// During pinch, returns the slot density captured at gesture start so
    /// the legend / grid don't flicker as hourHeight crosses the 76pt
    /// threshold.  Outside pinch, returns the live value.
    private var effectiveSlotMinutes: Int { rangePinchFrozenSlotMinutes ?? slotMinutes }
    private var slotHeight: CGFloat { hourHeight * CGFloat(effectiveSlotMinutes) / 60 }

    /// Dynamic min hourHeight for the live pinch gesture: the value at which
    /// 24 hours exactly fits between the top overlay and the tab bar.
    /// Pinching past this point would just hide the bottom of the day
    /// behind the tab bar.
    private var effectiveMinHourHeight: CGFloat {
        calendarPinchEffectiveMinHourHeight(
            viewportHeight: verticalViewportHeight,
            contentTopInset: verticalContentTopInset,
            contentBottomInset: verticalContentBottomInset,
            allDayHeight: allDayHeight,
            safetyFloor: calendarTimelineHourHeightMin
        )
    }
    private var editMappingState: TimelineEditMappingState? {
        calendarResolveEditMappingState(
            creation: resolvedCreationEditMapping,
            drag: resolvedDragEditMapping,
            focused: resolvedFocusedEditMapping
        )
    }
    private var boundaryExtensionMappingState: TimelineEditMappingState? {
        return calendarResolveBoundaryExtensionMappingState(
            creation: resolvedCreationEditMapping,
            drag: resolvedDragEditMapping
        )
    }
    private var rawBoundaryExtensionHours: (leading: Int, trailing: Int) {
        var result = calendarTimelineBoundaryExtensionHours(mappingState: boundaryExtensionMappingState)

        // Cross-day event fix: when the scroll is already near the top
        // (can't go further up) and the user is actively dragging upward,
        // proactively open the leading extension even though the event
        // range hasn't technically crossed midnight. Without this, events
        // starting late at night (e.g. 23:00) can never reach midnight by
        // finger drag alone (23h × hourHeight is physically unreachable)
        // and the vertical autoscroll is stuck at y=0 with nowhere to go.
        if let state = boundaryExtensionMappingState,
           state.source == .moveDrag || state.source == .resizeTop,
           result.leading == 0,
           verticalScrollY < hourHeight * 2,
           dragState.dragOffset.y < -hourHeight {
            result.leading = calendarTimelineMaximumBoundaryExtensionHours
        }

        return result
    }
    private var rawBoundaryExtensionState: TimelineBoundaryExtensionState {
        let anchorOffset: Int? = {
            guard let date = boundaryExtensionMappingState?.anchorDate else { return nil }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let anchor = calendar.startOfDay(for: date)
            return calendar.dateComponents([.day], from: today, to: anchor).day
        }()
        return TimelineBoundaryExtensionState(
            leadingHours: rawBoundaryExtensionHours.leading,
            trailingHours: rawBoundaryExtensionHours.trailing,
            source: boundaryExtensionMappingState?.source,
            anchorDayOffset: anchorOffset
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
                ) / CGFloat(effectiveSlotMinutes)
            ) + 1
        )
    }
    private var timelineHeight: CGFloat { headerHeight + CGFloat(slotCount) * slotHeight + timelineBottomInset }
    private var maxAllDayCount: Int {
        if let override = maxAllDayCountOverride {
            return override
        }
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
    private var totalHeight: CGFloat { allDayHeight + timelineHeight }
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
    @State private var horizontalScrollIsInteracting = false

    /// Extension hours frozen at drag start, used for occurrences fetching.
    /// This keeps the EventBlock tree stable while the visible timeline expands.
    @State private var frozenOccurrenceExtensionLeading: Int = 0
    @State private var frozenOccurrenceExtensionTrailing: Int = 0

    private var occurrenceExtensionHoursForDrag: (leading: Int, trailing: Int) {
        let isMoveDragActive = calendarIsMoveDragActive(
            draggingEventID: dragState.draggingEventID,
            dragMode: dragState.dragMode
        )
        if isMoveDragActive {
            // Use the larger of the frozen snapshot and the current
            // boundary extension so that events in a newly-opened
            // extended region are included immediately — not only
            // after the drag ends.
            return (
                max(frozenOccurrenceExtensionLeading, boundaryExtensionHours.leading),
                max(frozenOccurrenceExtensionTrailing, boundaryExtensionHours.trailing)
            )
        }
        return boundaryExtensionHours
    }

    // Drag State (shared across all day views for cross-day event sync)
    @State private var isRangePinchActive = false
    @State private var rangePinchReferenceScale: CGFloat = 1
    @State private var rangePinchInitialHourHeight: CGFloat = calendarTimelineHourHeightDefault
    @State private var rangePinchBoundaryProgress: CGFloat = 0
    @State private var rangePinchBoundaryStep: Int = 0
    @State private var rangePinchBoundaryLatched = false
    @State private var rangePinchBoundaryHaptic = UIImpactFeedbackGenerator(style: .soft)
    /// Slot density (60 / 30 / 15 min) captured at pinch start and held
    /// for the duration of the gesture.  Without this, finger micro-motion
    /// around the hourHeight=76 threshold flips slotMinutes 60↔30 each
    /// pinch tick, doubling/halving slotCount → TimeAxisLabels VStack
    /// adds/removes children → visible jitter in the time legend and
    /// (knock-on) the now-indicator line.  Nil when no pinch in progress.
    @State private var rangePinchFrozenSlotMinutes: Int? = nil
    /// Time-of-day (hours from midnight) at the viewport center captured at
    /// pinch start.  Used to keep that time stationary as hourHeight changes.
    @State private var pinchAnchorTimeHours: CGFloat? = nil
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
            hourHeight: hourHeight,
            dayColumnStep: dragState.dayColumnStep
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

        // For move drag, use the vertical-only range (no day shift) so the
        // time marker and boundary extension track the source day column.
        let effectiveRange: Event.TimeRange
        if source == .moveDrag, let originalRange = dragState.draggingOriginalRange, hourHeight > 0 {
            let rawOffsetSeconds = TimeInterval(dragState.dragOffset.y / hourHeight * 3600)
            let snappedOffset = calendarPreviewOffsetSeconds(
                rawOffsetSeconds: rawOffsetSeconds,
                range: originalRange,
                snapIntervalSeconds: 15 * 60
            )
            effectiveRange = Event.TimeRange(
                start: originalRange.start.addingTimeInterval(snappedOffset),
                end: originalRange.end.addingTimeInterval(snappedOffset)
            )
        } else {
            effectiveRange = range
        }

        // For move drag, anchor to the source day so the time marker
        // Y aligns with the vertical-only range (no day shift mismatch).
        let anchorDate: Date
        if source == .moveDrag, let originalRange = dragState.draggingOriginalRange {
            anchorDate = Calendar.current.startOfDay(for: originalRange.start)
        } else {
            anchorDate = calendarResolvedDragAnchorDate(
                draggingOriginalRange: dragState.draggingOriginalRange,
                dragOffset: dragState.dragOffset,
                dragMode: dragState.dragMode,
                dayColumnStep: dragState.dayColumnStep
            ) ?? effectiveRange.start
        }
        return (source, anchorDate, effectiveRange)
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
        // Hide time marker during vertical auto-scroll — it reappears
        // once the user returns to normal (snapping) drag territory.
        if editMappingState?.source == .moveDrag,
           dragState.isHorizontalEdgeDragging || dragState.isHorizontalAutoScrolling {
            return nil
        }
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
            let effectiveSpacing = isSingleDay ? CGFloat(0) : daySpacing

            HStack(spacing: 0) {
                timeAxis()
                    .frame(width: labelWidth, alignment: .trailing)

                scrollContent(dayWidth: dayWidth, dayFrameWidth: dayFrameWidth, spacing: effectiveSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, timelineEdgePadding)
            .scaleEffect(x: rangePinchVisualScale, y: rangePinchVisualScaleY, anchor: .center)
            .simultaneousGesture(rangePinchGesture)
            .animation(boundaryExtensionAnimation, value: boundaryExtensionHours.leading)
            .animation(boundaryExtensionAnimation, value: boundaryExtensionHours.trailing)
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
    private func timeAxis() -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if allDayHeight > 0 {
                    Color.clear.frame(height: allDayHeight)
                }
                TimeAxisLabels(
                    anchorDate: dayDate(forOffset: selectedDayOffset),
                    headerHeight: headerHeight,
                    hourHeight: hourHeight,
                    slotMinutes: effectiveSlotMinutes,
                    leadingExtendedHours: boundaryExtensionHours.leading,
                    trailingExtendedHours: boundaryExtensionHours.trailing,
                    mode: mode,
                    editMappingPresentation: editMappingPresentation
                )
                .id(effectiveSlotMinutes)
                .transition(.opacity)
                .frame(height: timelineHeight, alignment: .top)
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
            // Freeze the slot density at gesture start so legend / grid
            // don't flicker when hourHeight micro-oscillates around the
            // 76pt threshold (60 ↔ 30 slotMinutes swap doubles slotCount).
            rangePinchFrozenSlotMinutes = slotMinutes
            // Capture the time-of-day at the viewport center as the focal
            // anchor for the duration of this pinch.  Subsequent hourHeight
            // changes will adjust scrollY to keep this time stationary.
            pinchAnchorTimeHours = calendarPinchAnchorTimeHours(
                scrollY: verticalScrollY,
                viewportHeight: verticalViewportHeight,
                topOverlayInset: verticalContentTopInset,
                hourHeight: hourHeight
            )
            temporalStretchLastStepIndex = temporalStretchStepIndex(for: hourHeight)
            temporalStretchLastSlotMinutes = slotMinutes
            temporalStretchHitLowerBound = hourHeight <= effectiveMinHourHeight + temporalStretchBoundaryEpsilon
            temporalStretchHitUpperBound = hourHeight >= calendarTimelineHourHeightMax - temporalStretchBoundaryEpsilon
            temporalStretchStepHaptic.prepare()
            temporalStretchMilestoneHaptic.prepare()
            temporalStretchBoundaryHaptic.prepare()
            rangePinchBoundaryHaptic.prepare()
        }

        let referenceScale = max(0.01, rangePinchReferenceScale)
        let effectiveScale = safeScale / referenceScale
        let previousHourHeight = hourHeight
        // Always use the current viewport's fit min as the lower bound,
        // even if the persisted hourHeight is already below it.  This
        // produces a one-time snap on the first pinch tick after rotation
        // or all-day-event removal — acceptable trade-off so the user
        // never gets stuck below the "whole day fits" point.
        let pinchMin = effectiveMinHourHeight
        let nextHourHeight = calendarTimelineHourHeightAfterPinchScale(
            initialHourHeight: rangePinchInitialHourHeight,
            scale: effectiveScale,
            minHourHeight: pinchMin
        )
        if abs(nextHourHeight - previousHourHeight) > 0.0001 {
            updateTemporalStretchHaptics(
                previousHourHeight: previousHourHeight,
                newHourHeight: nextHourHeight
            )
            // Batch hourHeight + scroll updates into ONE transaction so
            // SwiftUI applies both in the same render pass.  Without this,
            // the two state writes can land in separate frames: the
            // timeline stretches in frame N but the scroll catches up in
            // frame N+1, producing a 1-frame anchor drift on every pinch
            // tick — visible as jitter at 60fps.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hourHeight = nextHourHeight
                if let anchorTime = pinchAnchorTimeHours {
                    let adjustedY = calendarPinchAdjustedScrollY(
                        anchorTimeHours: anchorTime,
                        viewportHeight: verticalViewportHeight,
                        topOverlayInset: verticalContentTopInset,
                        hourHeight: nextHourHeight
                    )
                    onPinchScrollAdjust?(adjustedY)
                }
            }
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
            && proposedHourHeight < pinchMin - 0.0001
            && nextHourHeight <= pinchMin + 0.0001

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
        pinchAnchorTimeHours = nil
        // Release the frozen slot density so the legend can settle back to
        // the threshold-appropriate density for the final hourHeight.
        // Wrapping in withAnimation drives the `.id(effectiveSlotMinutes)`
        // identity flip on TimeAxisLabels as a crossfade rather than a
        // snap.  If the pinch didn't cross the threshold, slotMinutes is
        // unchanged and no visible animation fires.
        withAnimation(.easeInOut(duration: 0.3)) {
            rangePinchFrozenSlotMinutes = nil
        }
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
    private func scrollContent(dayWidth: CGFloat, dayFrameWidth: CGFloat, spacing: CGFloat) -> some View {
        let leadingRange = leadingOffsetsRange()
        let centeredRange = centeredOffsetsRange()
        let visibleOffsets = visibleOffsetsRange(centeredRange: centeredRange)
        let isMoveDragActive = calendarIsMoveDragActive(
            draggingEventID: dragState.draggingEventID,
            dragMode: dragState.dragMode
        )
        let isFocusContextActive = calendarIsFocusVisualContextActive(
            focusedEventID: focusedEventID,
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

            let requestHorizontalBoundaryPage: (Int) -> Bool = { direction in
                guard daysCount == 1, direction != 0 else { return false }
                let targetOffset = selectedDayOffset + direction
                let resolvedTarget = calendarTimelineResolvedCenteredDayOffset(
                    requestedDayOffset: targetOffset,
                    centeredRange: centeredRange,
                    deferOutOfRangeSelection: false
                ) ?? targetOffset
                guard resolvedTarget != selectedDayOffset else { return false }
                calendarDebugLog(
                    "timeline.horizontalBoundaryPage.request",
                    fields: [
                        "direction": "\(direction)",
                        "selectedDayOffset": "\(selectedDayOffset)",
                        "targetOffset": "\(targetOffset)",
                        "resolvedTarget": "\(resolvedTarget)"
                    ]
                )
                selectedDayOffset = resolvedTarget
                return true
            }

            ScrollView(.horizontal) {
                HStack(spacing: spacing) {
                    dayColumns(
                        dayWidth: dayWidth,
                        dayFrameWidth: dayFrameWidth,
                        isFocusContextActive: isFocusContextActive,
                        isScrolling: horizontalScrollIsInteracting,
                        onHorizontalBoundaryPageRequest: daysCount == 1 ? requestHorizontalBoundaryPage : nil
                    )
                }
                .scrollTargetLayout()
                .padding(.horizontal, scrollHorizontalPadding)
                // Inserts a UIPinchGestureRecognizer onto the underlying
                // horizontal UIScrollView.  When pinch transitions to
                // .began (real pinch confirmed), the recognizer cancels
                // any in-progress scroll pan.  Pinch is suppressed entirely
                // while an event is being long-pressed or dragged so the
                // two gestures don't race.
                .background(
                    PinchScrollCoordinator(
                        isInteractionBlocked: {
                            dragState.draggingEventID != nil
                        }
                    )
                )
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
                // Skip scroll restoration while the user is actively
                // scrolling (interacting or decelerating).  The
                // scrollTo fights with momentum and causes the view to
                // jump 1-2 months ahead/behind.
                guard !horizontalScrollIsInteracting else { return }
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
                    return
                }
                guard shouldAdoptScrollDrivenSelection else {
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
            .onChange(of: dragState.draggingEventID) { oldValue, newValue in
                if newValue != nil && oldValue == nil {
                    frozenOccurrenceExtensionLeading = boundaryExtensionHours.leading
                    frozenOccurrenceExtensionTrailing = boundaryExtensionHours.trailing
                }
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

    private var renderBuffer: Int {
        // During pinch, reduce buffer to visible columns only — each
        // rendered column must re-layout at the new hourHeight so fewer
        // columns = fewer EventBlock body evaluations per frame.
        if isRangePinchActive {
            return max(daysCount / 2, 1)
        }
        return calendarRenderBuffer(daysCount: daysCount)
    }

    private var dragSourceDayOffset: Int? {
        calendarDragSourceDayOffset(draggingOriginalRange: dragState.draggingOriginalRange)
    }

    @ViewBuilder
    private func dayColumns(
        dayWidth: CGFloat,
        dayFrameWidth: CGFloat,
        isFocusContextActive: Bool,
        isScrolling: Bool,
        onHorizontalBoundaryPageRequest: ((Int) -> Bool)?
    ) -> some View {
        let center = selectedDayOffset
        let buffer = renderBuffer
        let sourceDayOffset = dragSourceDayOffset
        let isDragAutoScrolling = dragState.isHorizontalAutoScrolling
        let isDragging = dragState.draggingEventID != nil
        // Don't gate during drag — programmatic scrollTo (boundary
        // page in day view) can set isScrolling = true, which would
        // gate the new column and prevent the drag preview from
        // rendering.
        let isPerformanceMode = (isScrolling && !isDragging) || isDragAutoScrolling
        ForEach(dayRange, id: \.self) { offset in
            let shouldRender = calendarShouldRenderFullDayColumn(
                offset: offset,
                renderCenter: center,
                renderBuffer: buffer,
                dragSourceDayOffset: sourceDayOffset
            )
            let isDragSource = isDragAutoScrolling && offset == sourceDayOffset
            let gateActive = isPerformanceMode && !isDragSource
            DayColumnGate(
                offset: offset,
                shouldRender: shouldRender,
                isScrolling: gateActive
            ) {
                dayColumn(
                    offset: offset,
                    width: dayWidth,
                    isFocusContextActive: isFocusContextActive,
                    onHorizontalBoundaryPageRequest: onHorizontalBoundaryPageRequest
                )
            }
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
        isFocusContextActive: Bool,
        onHorizontalBoundaryPageRequest: ((Int) -> Bool)?
    ) -> some View {
        let date = dayDate(forOffset: offset)
        let columnStep: CGFloat = isSingleDay ? 0 : width + daySpacing
        let previewDayStep: CGFloat = width + daySpacing

        // Check if preview should be shown on this day.
        // During drag-create, use creationPreviewByDay which includes
        // clipped ranges for cross-midnight drags.  After release
        // (form open), use previewCreation.
        let previewRange: Event.TimeRange? = {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let dayOffset = calendar.dateComponents([.day], from: today, to: date).day ?? 0
            // Live creation drag (real-time preview for all intersecting days)
            if let liveRange = creationPreviewByDay[dayOffset] {
                return liveRange
            }
            // Form-open preview (after drag ends)
            guard let preview = previewCreation else { return nil }
            let previewDay = calendar.startOfDay(for: preview.date)
            if previewDay == date {
                return preview.timeRange
            }
            // Cross-midnight form preview
            let dayStart = calendar.startOfDay(for: date)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            if preview.timeRange.end > dayStart && preview.timeRange.start < dayEnd {
                return Event.TimeRange(
                    start: max(preview.timeRange.start, dayStart),
                    end: min(preview.timeRange.end, dayEnd)
                )
            }
            return nil
        }()

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
                isFocusContextActive: isFocusContextActive,
                onHorizontalBoundaryPageRequest: onHorizontalBoundaryPageRequest
            )
        }
    }

    private func buildTimelineDayView(
        for offset: Int,
        date: Date,
        dayWidth: CGFloat,
        dayColumnStep: CGFloat,
        dragPreviewDayStep: CGFloat,
        previewRange: Event.TimeRange?,
        isFocusContextActive: Bool,
        onHorizontalBoundaryPageRequest: ((Int) -> Bool)?
    ) -> some View {
        return TimelineDayView(
            date: date,
            occurrences: CalendarLayout.timelineVisibleOccurrences(
                forDayOffset: offset,
                leadingExtendedHours: occurrenceExtensionHoursForDrag.leading,
                trailingExtendedHours: occurrenceExtensionHoursForDrag.trailing,
                occurrencesForOffset: occurrencesForOffset
            ),
            contentWidth: dayWidth,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            liveHourHeight: liveHourHeight,
            slotMinutes: effectiveSlotMinutes,
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
            onHorizontalBoundaryPageRequest: onHorizontalBoundaryPageRequest,
            liveInterruptSession: liveInterruptSession,
            isInVisibleViewport: calendarIsDayInVisibleViewport(
                offset: offset,
                selectedDayOffset: selectedDayOffset,
                daysCount: daysCount
            ),
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
            creationPreviewByDay.removeAll()
            return
        }

        // Store the range for the source day, and also for any
        // adjacent day the range crosses into (e.g. past midnight).
        var mapping: [Int: Event.TimeRange] = [offset: range]
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        if range.end > nextDayStart {
            mapping[offset + 1] = Event.TimeRange(
                start: nextDayStart,
                end: range.end
            )
        }
        let prevDayEnd = dayStart
        if range.start < prevDayEnd, offset > 0 {
            mapping[offset - 1] = Event.TimeRange(
                start: range.start,
                end: prevDayEnd
            )
        }
        creationPreviewByDay = mapping
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

        let hitsLowerBound = newHourHeight <= effectiveMinHourHeight + temporalStretchBoundaryEpsilon
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
                                    .font(.system(size: 9, weight: .semibold))
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
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
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
        .offset(x: 15, y: clampedY - markerHeight / 2)
        .shadow(color: markerColor.opacity(0.25), radius: 2, x: 0, y: 1)
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

    static let boundaryDayHintWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    static let boundaryDayHintDayFormatter: DateFormatter = {
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
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
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

// MARK: - Todo→Event Absorption Drag/Drop

/// Drop-target glue for the todo→event absorption flow. `.event`
/// blocks accept a UUID-text payload and route through `onAbsorb`.
///
/// Originally also attached `.onDrag` to `.todo` blocks for a
/// drag-from-canvas source, but that conflicted with the UIKit
/// `EventBlockDragGesture` (both are long-press) and ended up dead
/// on arrival. Absorption from the canvas side is now picker-driven
/// (todo detail → "Absorb into event…" sheet). Drops still work
/// for any other source — external app drag, future grip-handle
/// affordance, etc.
private struct TodoEventAbsorptionDragDropModifier: ViewModifier {
    let event: Event
    let onAbsorb: (UUID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if event.kind == .event {
            content.onDrop(of: [UTType.text], isTargeted: nil) { providers in
                // Reject obvious garbage synchronously so iOS doesn't
                // play the "accepted" animation on drops we can't even
                // load. (Whether the loaded text is actually a UUID is
                // still an async check — accepted here, validated when
                // `loadObject` resolves.)
                guard let provider = providers.first,
                      provider.canLoadObject(ofClass: NSString.self) else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let str = obj as? String,
                          let todoID = UUID(uuidString: str) else { return }
                    DispatchQueue.main.async {
                        onAbsorb(todoID)
                    }
                }
                return true
            }
        } else {
            content
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
    // Reference passed down to EventBlock so the deep callee can read live
    // hourHeight without re-evaluating its body on every pinch frame.
    let liveHourHeight: CalendarHourHeightBox
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
    var onHorizontalBoundaryPageRequest: ((Int) -> Bool)? = nil
    var liveInterruptSession: CalendarInterruptLiveSession? = nil
    /// Whether this day column is in the user-visible viewport (not just
    /// in the render-gating buffer).  Used to skip drag-preview computation
    /// for off-screen days, avoiding unnecessary dragOffset tracking.
    var isInVisibleViewport: Bool = true

    /// Reactive read of the experimental multi-type events flag so that
    /// toggling the Labs switch immediately updates the calendar surface
    /// (the right-edge color strips for secondary types).
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var experimentalMultiTypeEnabled = false

    // Shared drag state for cross-day event sync
    var dragState: EventDragState

    // Cached layout computations — recomputed only when occurrences
    // change (via .onChange), NOT on every body evaluation.  During
    // scroll the data doesn't change, so the body can read cached
    // results instead of recomputing visibleOccurrences, overlap
    // layout, and interrupt lookups on every frame.
    @State private var cachedVisibleOccurrences: [CalendarLayout.EventOccurrence] = []
    @State private var cachedOverlapSlots: [String: CalendarLayout.EventOverlapSlot] = [:]
    @State private var cachedInterruptParentLookup: [UUID: CalendarLayout.EventOccurrence] = [:]
    @State private var cachedInterruptChildrenLookup: [UUID: [CalendarLayout.EventOccurrence]] = [:]
    @State private var cachedEmbeddedInterruptIDs: Set<String> = []

    // Creation drag state
    @State private var isCreating = false
    @State private var isLongPressingCreation = false
    @State private var creationStartY: CGFloat = 0
    @State private var creationCurrentY: CGFloat = 0
    @State private var lastTickMinutes: Int = -1
    @State private var lastSnappedStartEdge: Date?
    @State private var lastSnappedEndEdge: Date?

    @AppStorage(AppSettingsKeys.calendarAdjacentEventSnapEnabled) private var adjacentEventSnapEnabled = true
    @AppStorage(AppSettingsKeys.calendarEventFontSize) private var titleFontSizeSetting: Double = Double(calendarEventTitleFontSizeDefault)
    @AppStorage(AppSettingsKeys.calendarEventShowTimeBelowTitle) private var showTimeBelowTitleSetting: Bool = true
    @AppStorage(AppSettingsKeys.nearFutureHorizonDays) private var nearFutureHorizonDays: Int = EventZone.defaultHorizonDays

    /// Used by the canvas-side todo→event absorption drag-and-drop. Drop
    /// handler needs to mutate `calendarEvents` via the store.
    @EnvironmentObject private var calendarEventStore: EventStore

    /// Parent ids that recently received a todo absorption (any path —
    /// drop, picker from todo side, picker from event side). Populated
    /// by `.onReceive(calendarTodoAbsorbed)`; entries auto-clear after
    /// the pulse window (~1.5s). EventBlock takes membership as a prop
    /// (`isRecentlyAbsorbedInto`) and pulses on change/appear.
    @State private var recentlyAbsorbedParents: Set<UUID> = []

    /// Cached reference to the currently-dragged `.todo` (or `nil` when
    /// not dragging or dragging an `.event`). Updated once per drag
    /// session via `.onChange(of: dragState.draggingEventID)` so the
    /// per-block `isAbsorptionDropTarget` computation skips the
    /// `calendarEvents.first(where:)` linear scan on every drag frame.
    @State private var cachedDraggedTodo: Event? = nil

    /// This day's frame in the global (window) coordinate space.
    /// Captured via a background `GeometryReader` and refreshed on
    /// layout change. Used by the finger-driven absorption spatial
    /// hit: converts `dragState.currentTouchPointGlobal` (window
    /// coords from UIKit gesture handler) into a day-local x fraction
    /// for slot comparison.
    @State private var dayFrameInGlobal: CGRect = .zero

    private var resolvedTitleFontSize: CGFloat {
        let raw = CGFloat(titleFontSizeSetting)
        return min(max(raw, 9), 16)
    }

    /// The exact `Date` HORIZON sits at — `now + nearFutureHorizonDays
    /// × 24h`, computed each body pass.  Anchors both the horizon-day
    /// horizontal line position and the partial-day tint cutoff.
    private var horizonMoment: Date {
        EventZone.horizonDate(from: nearFutureHorizonDays)
    }

    /// True when this day column contains the HORIZON moment — the
    /// horizontal horizon line + transition between "near future" and
    /// "future" tint renders on this day at the horizon time-of-day.
    private var isHorizonDay: Bool {
        Calendar.current.isDate(date, inSameDayAs: horizonMoment)
    }

    /// True when this day column sits FULLY in the future zone —
    /// strictly after the horizon day.  These days get the future tint
    /// across their entire height.  The horizon day itself is partially
    /// in the future (below the horizon line) but not "fully" — its
    /// tint is drawn as a sub-rect, see body.
    private var isFullyInFutureZone: Bool {
        let calendar = Calendar.current
        let horizonDayStart = calendar.startOfDay(for: horizonMoment)
        guard let dayAfterHorizon = calendar.date(byAdding: .day, value: 1, to: horizonDayStart) else {
            return false
        }
        return calendar.startOfDay(for: date) >= dayAfterHorizon
    }

    /// Width (in points) of the visible peek strip on the left edge of an
    /// event covered by a higher-depth sibling under stack-peek layout.
    /// Matches the existing 8pt interrupt-child overlay leading inset so
    /// peek and cutout share a visual constant. Constant for v1; revisit
    /// if/when peek needs to scale with font.
    private var stackPeekStripWidthPt: CGFloat { 8 }

    /// Tolerance (seconds) for treating two events as time-equal peers in
    /// stack-peek layout. Two events whose starts AND ends each fall
    /// within this window are laid out as equal-split peers (same depth,
    /// width divided equally) rather than stacked with peek. Drag handles
    /// and edge-grab affordances align cleanly under equal-split, so the
    /// tolerance matters for those interactions, not just for readability.
    /// 20 minutes sits in the middle of the 15-30 range that captures the
    /// "feels almost the same" cases (off-grid drag drift, quick-create on
    /// adjacent grid lines) while leaving genuine staircase (≥30 min
    /// stagger) distinctly stacked.
    private var stackPeekPeerToleranceSeconds: TimeInterval { 20 * 60 }

    /// Fractional peek width on the timeline's event canvas. Zero (and
    /// thus disables stack-peek) when the canvas hasn't been measured or
    /// is too narrow for a meaningful peek.
    private var stackPeekFraction: CGFloat {
        let area = max(0, contentWidth - eventHorizontalInset * 2)
        guard area > stackPeekStripWidthPt * 2 else { return 0 }
        return stackPeekStripWidthPt / area
    }

    private struct DraggedOccurrenceRenderHealth: Equatable {
        let draggingEventID: UUID?
        let draggingOccurrenceID: String?
        let dragMode: EventDragMode
        let hasOccurrenceInDay: Bool
        let renderedInDay: Bool
        let hasCrossDayPreview: Bool
    }

    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    private let snapHaptic = UISelectionFeedbackGenerator()
    private let snapMinutes: Int = 15
    private let creationActivationThreshold: CGFloat = 18
    private let adjacentEventSnapThresholdPt: CGFloat = 8

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
        // Avoid reading dragPreviewInfo here — it reads dragOffset via
        // liveDraggedPreviewRange, which would cause @Observable to track
        // dragOffset for every rendered day.  hasCrossDayPreview is only
        // used for debug logging and isn't worth the per-frame cost.
        let hasCrossDayPreview = false

        return DraggedOccurrenceRenderHealth(
            draggingEventID: dragState.draggingEventID,
            draggingOccurrenceID: draggingOccurrenceID,
            dragMode: dragState.dragMode,
            hasOccurrenceInDay: hasOccurrenceInDay,
            renderedInDay: renderedInDay,
            hasCrossDayPreview: hasCrossDayPreview
        )
    }

    private var dragPreviewOccurrenceInDay: CalendarLayout.EventOccurrence? {
        // IMPORTANT: this preview is what the user actually sees during a
        // move drag — the source EventBlock is rendered with opacity 0 (see
        // ForEach below), so this clipped occurrence is the visible follower
        // that tracks the finger.  Removing it for visible days breaks
        // single-day drag entirely: the source block is invisible AND no
        // preview is rendered.
        //
        // Render-gated buffer days (off-screen) skip this entirely so they
        // don't read dragOffset via liveDraggedPreviewRange and don't
        // re-render every drag frame under @Observable tracking.
        guard isInVisibleViewport else { return nil }
        guard dragState.dragMode == .move,
              let event = dragState.draggingEvent,
              let occurrenceID = dragState.draggingOccurrenceID,
              let previewRange = liveDraggedPreviewRange else {
            return nil
        }

        guard let clippedRange = calendarAdjustedOccurrenceRange(
            occurrenceID: occurrenceID,
            occurrenceRange: previewRange,
            draggingOccurrenceID: dragState.draggingOccurrenceID,
            draggingOriginalRange: dragState.draggingOriginalRange,
            dragMode: dragState.dragMode,
            previewRange: previewRange,
            dayStart: visibleStart,
            dayEnd: visibleEnd,
            keepOriginalWhenPreviewLeavesDay: false
        ) else {
            return nil
        }

        return CalendarLayout.EventOccurrence(
            id: occurrenceID,
            event: event,
            range: clippedRange
        )
    }

    /// When the live preview moves into a day that did not originally host the
    /// occurrence, synthesize a passive projection so cross-day horizontal drag
    /// still renders in the destination day.
    private var previewOnlyDraggedOccurrence: CalendarLayout.EventOccurrence? {
        guard let previewOccurrence = dragPreviewOccurrenceInDay,
              !occurrences.contains(where: { $0.id == previewOccurrence.id }) else {
            return nil
        }
        return previewOccurrence
    }

    /// Stable sentinel id for the in-progress drag-create draft; chosen so it
    /// can never collide with real occurrence ids (those are UUID-prefixed).
    static let creationDraftOccurrenceID = "__creation_draft__"

    /// Synthetic occurrence for the in-progress drag-create draft, fed into
    /// the overlap layout so sibling events reposition around it in real time.
    /// Not rendered as an EventBlock (it's not in `occurrences`); only used
    /// for layout and to slot the creationPreview view.
    private var creationDraftOccurrence: CalendarLayout.EventOccurrence? {
        guard isCreating, let range = creationPreviewRange else { return nil }
        let placeholder = Event(id: TimelineDayView.creationDraftEventID, title: "")
        return CalendarLayout.EventOccurrence(
            id: TimelineDayView.creationDraftOccurrenceID,
            event: placeholder,
            range: range
        )
    }

    /// Fixed UUID for the placeholder Event backing the creation draft, so
    /// repeated reads return identity-equal events instead of churning UUIDs
    /// every frame.
    private static let creationDraftEventID = UUID(uuidString: "00000000-0000-0000-0000-D0A6F7C0EA70")!

    private var dragPreviewInfo: CalendarLayout.EventOccurrence? {
        dragPreviewOccurrenceInDay
    }

    private var liveDraggedPreviewRange: Event.TimeRange? {
        guard dragState.draggingEventID != nil else { return nil }
        return dragState.previewRange(hourHeight: hourHeight)
    }

    private func isPrimaryDraggedProjection(
        for occurrence: CalendarLayout.EventOccurrence
    ) -> Bool {
        guard isActiveDraggedOccurrence(
            occurrenceID: occurrence.id,
            draggingOccurrenceID: dragState.draggingOccurrenceID,
            dragMode: dragState.dragMode
        ) else {
            return false
        }

        let hostDayStart = Calendar.current.startOfDay(for: date)
        let primaryRenderDayStart = calendarResolvedPrimaryDragRenderDayStart(
            sourceDayStart: dragState.draggingRenderDayStart ?? dragState.draggingOriginalRange.map {
                Calendar.current.startOfDay(for: $0.start)
            },
            dragOffset: dragState.dragOffset,
            dayStep: dragPreviewDayStep,
            usesHorizontalBoundaryPaging: dayColumnStep <= 0 && dragPreviewDayStep > 0
        )
        if let primaryRenderDayStart {
            return Calendar.current.isDate(primaryRenderDayStart, inSameDayAs: hostDayStart)
        }
        return false
    }

    private func liveLayoutRange(
        for occurrence: CalendarLayout.EventOccurrence
    ) -> Event.TimeRange? {
        // Only read liveDraggedPreviewRange (which reads dragOffset) for the
        // dragged occurrence — same pattern as adjustedRange.
        let isDraggedOcc = occurrence.id == dragState.draggingOccurrenceID
        return calendarAdjustedOccurrenceRange(
            occurrenceID: occurrence.id,
            occurrenceRange: occurrence.range,
            draggingOccurrenceID: dragState.draggingOccurrenceID,
            draggingOriginalRange: dragState.draggingOriginalRange,
            dragMode: dragState.dragMode,
            previewRange: isDraggedOcc ? liveDraggedPreviewRange : nil,
            dayStart: visibleStart,
            dayEnd: visibleEnd,
            keepOriginalWhenPreviewLeavesDay: false
        )
    }

    /// Calculate the adjusted display range for an occurrence during drag.
    /// The primary dragged block stays alive even when the live preview has
    /// left this column so the gesture surface can keep following the finger.
    private func adjustedRange(for occurrence: CalendarLayout.EventOccurrence) -> Event.TimeRange? {
        // Only read liveDraggedPreviewRange (which reads dragOffset) for the
        // dragged occurrence.  For all other occurrences, pass nil — the pure
        // function returns occurrenceRange when previewRange is nil.
        let isDraggedOcc = occurrence.id == dragState.draggingOccurrenceID
        // Keep the gesture surface alive on the SOURCE day even after
        // boundary page moves the primary projection to the destination
        // day.  Without this the EventBlock is removed → UIKit cancels
        // the gesture → shared drag state is cleared → preview vanishes.
        let isDragSourceDay = isDraggedOcc && dragState.draggingRenderDayStart.map {
            Calendar.current.isDate($0, inSameDayAs: date)
        } ?? false
        return calendarAdjustedOccurrenceRange(
            occurrenceID: occurrence.id,
            occurrenceRange: occurrence.range,
            draggingOccurrenceID: dragState.draggingOccurrenceID,
            draggingOriginalRange: dragState.draggingOriginalRange,
            dragMode: dragState.dragMode,
            previewRange: isDraggedOcc ? liveDraggedPreviewRange : nil,
            dayStart: visibleStart,
            dayEnd: visibleEnd,
            keepOriginalWhenPreviewLeavesDay: isDraggedOcc && (isPrimaryDraggedProjection(for: occurrence) || isDragSourceDay)
        )
    }

    var body: some View {
        // With @Observable, property tracking is automatic — no forced
        // subscriptions needed.  Only properties actually read in this
        // body (or its computed-property call tree) trigger rebuilds.
        let currentMode = dragState.dragMode
        let renderHealth = draggedOccurrenceRenderHealth

        ZStack(alignment: .topLeading) {
            extensionRegionBackdrop

            // Future-zone tint. Days strictly after the horizon day
            // get a full-column wash; the horizon day itself gets a
            // partial wash from the horizon time-of-day down to the
            // bottom (the line below carves out the visual boundary
            // for the part above).  Days before horizon get no tint.
            if isFullyInFutureZone {
                Rectangle()
                    .fill(Color.orange.opacity(0.04))
                    .allowsHitTesting(false)
            } else if isHorizonDay {
                let horizonY = headerHeight + max(0, horizonMoment.timeIntervalSince(visibleStart) / 3600 * hourHeight)
                Rectangle()
                    .fill(Color.orange.opacity(0.04))
                    .padding(.top, horizonY)
                    .allowsHitTesting(false)
            }

            grid

            // HORIZON moment marker.  Thin horizontal line across the
            // horizon day at the exact horizon time-of-day — visually
            // the "near future" / "future" boundary that drifts down
            // continuously as time advances (no day-jumps).
            // Color.orange.opacity(0.45) for sunset/horizon vibe.
            if isHorizonDay {
                let horizonY = headerHeight + max(0, horizonMoment.timeIntervalSince(visibleStart) / 3600 * hourHeight)
                Rectangle()
                    .fill(Color.orange.opacity(0.45))
                    .frame(height: 1.5)
                    .padding(.top, horizonY)
                    .allowsHitTesting(false)
            }

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

            // Scroll: use cached layout data (zero cost).
            // Drag: compute live overlap so events rearrange in real time
            //       around the dragged event's current position.
            // Drag-create also recomputes, with the draft event injected as a
            // synthetic occurrence so sibling events reposition around it.
            let isDragActive = dragState.draggingEventID != nil
            let creationDraft = creationDraftOccurrence
            let needsLiveLayout = isDragActive || creationDraft != nil

            let visibleOccurrences: [CalendarLayout.EventOccurrence] = {
                guard needsLiveLayout else { return cachedVisibleOccurrences }
                let previewOnlyOccurrence = previewOnlyDraggedOccurrence
                var resolved = occurrences.compactMap { occ in
                    liveLayoutRange(for: occ).map {
                        CalendarLayout.EventOccurrence(id: occ.id, event: occ.event, range: $0)
                    }
                }
                if let previewOnlyOccurrence { resolved.append(previewOnlyOccurrence) }
                if let creationDraft { resolved.append(creationDraft) }
                return resolved
            }()

            let interruptParentLookup: [UUID: CalendarLayout.EventOccurrence] = {
                guard needsLiveLayout else { return cachedInterruptParentLookup }
                var lookup: [UUID: CalendarLayout.EventOccurrence] = [:]
                for occ in visibleOccurrences where !occ.event.isInterrupt {
                    lookup[interruptAnchorEventID(for: occ.event)] = occ
                }
                return lookup
            }()

            let interruptChildrenLookup: [UUID: [CalendarLayout.EventOccurrence]] = {
                guard needsLiveLayout else { return cachedInterruptChildrenLookup }
                var lookup: [UUID: [CalendarLayout.EventOccurrence]] = [:]
                for occ in visibleOccurrences {
                    guard let rel = occ.event.interruptRelation, rel.state == .embedded else { continue }
                    lookup[rel.parentEventID, default: []].append(occ)
                }
                return lookup
            }()

            let embeddedInterruptIDs: Set<String> = {
                guard needsLiveLayout else { return cachedEmbeddedInterruptIDs }
                var ids = Set<String>()
                for occ in visibleOccurrences {
                    guard occ.event.isInterrupt,
                          let rel = occ.event.interruptRelation, rel.state == .embedded,
                          let parentOcc = interruptParentLookup[rel.parentEventID],
                          let parentRange = adjustedRange(for: parentOcc) else { continue }
                    let liveRange = liveOccurrenceRange(for: occ)
                    if liveRange.end > parentRange.start && liveRange.start < parentRange.end {
                        ids.insert(occ.id)
                    }
                }
                return ids
            }()

            // Exclude the dragged `.todo` from live overlap layout so
            // parallel events keep their original column positions
            // (e.g., two peer events stay 2-way split instead of being
            // squeezed to 3-way to make room for the dragged todo).
            // The dragged still renders — its block reads from
            // `stableOverlapSlots` which is computed off `occurrences`
            // (includes the todo at its original position).  Event-on-
            // event drags (kind=.event) keep the existing cluster
            // recompute behavior; only todo absorption is special.
            let draggedTodoOccurrenceID: String? = {
                guard let occID = dragState.draggingOccurrenceID,
                      cachedDraggedTodo != nil else { return nil }
                return occID
            }()
            let overlapCandidates = visibleOccurrences.filter { occ in
                if let draggedTodoOccurrenceID, occ.id == draggedTodoOccurrenceID {
                    return false
                }
                guard occ.event.isInterrupt, occ.event.interruptRelation != nil else { return true }
                return !embeddedInterruptIDs.contains(occ.id)
            }
            let activePeekFraction = stackPeekFraction
            let activePeerTolerance = stackPeekPeerToleranceSeconds
            let overlapSlots: [String: CalendarLayout.EventOverlapSlot] = {
                guard needsLiveLayout else { return cachedOverlapSlots }
                return CalendarLayout.overlapLayout(
                    for: overlapCandidates,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    peekFraction: activePeekFraction,
                    peerTolerance: activePeerTolerance
                )
            }()
            let stableOverlapSlots = needsLiveLayout
                ? CalendarLayout.overlapLayout(
                    for: occurrences,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    peekFraction: activePeekFraction,
                    peerTolerance: activePeerTolerance
                )
                : overlapSlots

            // During pinch, collapse the N independent EventBlock views into
            // a single Canvas that draws every visible event in one pass.
            // SwiftUI's view-tree work drops from O(N × layout-passes) to
            // O(1).  Visual is simplified (colored rect + title only) — the
            // full SwiftUI tree resumes the instant pinch ends.  Single
            // toggle at the ForEach boundary keeps transition cost bounded
            // to one tree restructure per pinch begin/end (per lessons in
            // issue #12 — many small `isPinchActive` gates create worse
            // transitions than one big swap).
            // Absorption drop-target: one body-level compute per drag
            // frame instead of M per-block scans. Matches the
            // `needsLiveLayout` / `overlapSlots` gating pattern — the
            // scan only runs when there's actually a non-recurring
            // `.todo` being dragged (recurring todos don't absorb per
            // CalendarPageView.handleEventDrag's gate, so we don't
            // paint a highlight that would lie about what release
            // does). Per-block then reduces to a single UUID
            // comparison, which keeps SwiftUI's EventBlock Equatable
            // check cheap and means non-target blocks reliably skip
            // re-render.
            //
            // Skip during horizontal auto-scroll / edge drag: the
            // target moves under the finger anyway, so highlight is
            // meaningless during that phase. Saves the O(N)
            // calendarEvents scan per day per body re-eval × auto-
            // scroll-tick rate — the worst-cost phase of a drag.
            // Highlight resumes the moment scrolling settles and the
            // user resumes finger-dragging.
            // Finger-driven spatial hit: in time-edit drag the block
            // follows the finger 1:1 in y but stays anchored in its
            // source x column — so the block's center barely moves
            // laterally and can't distinguish which parallel column the
            // user actually points at.  The finger position does.  We
            // convert `dragState.currentTouchPointGlobal` (window coords
            // from UIKit gesture handler) into a day-local x fraction
            // using the captured `dayFrameInGlobal`, then pick the
            // deepest stack-peek candidate whose slot contains that
            // fraction (deep == the one visually exposed at that x;
            // shallower siblings are obscured everywhere except their
            // leading peek strip).  Falls back to the closest slot
            // center if nothing contains, so any time-overlap-existing
            // finger position over this day yields a target.
            //
            // Skip during horizontal auto-scroll / edge drag: target
            // moves under the finger anyway during those phases.
            let dropTargetEventID: UUID? = {
                guard isDragActive,
                      !dragState.isHorizontalAutoScrolling,
                      !dragState.isHorizontalEdgeDragging,
                      let dragged = cachedDraggedTodo,
                      !dragged.isRecurringSeries,
                      liveDraggedPreviewRange != nil,
                      let touch = dragState.currentTouchPointGlobal,
                      dayFrameInGlobal.width > 0,
                      dayFrameInGlobal.height > 0,
                      touch.x >= dayFrameInGlobal.minX,
                      touch.x <= dayFrameInGlobal.maxX else { return nil }

                // True 2D hit-test against each candidate's RENDERED
                // frame: x from slot fraction × eventArea width (inside
                // the day's horizontal inset), y from event time ×
                // hourHeight relative to the day's visibleStart.  Pick
                // the topmost (deepest stack-peek depth) whose frame
                // contains the touch — same shape as standard
                // point-in-rect hit testing with z-order.
                //
                // Embedded interrupts are special: they're filtered out
                // of overlap layout (so `overlapSlots[interrupt.id]` is
                // missing and would fall back to .default = full width
                // — wrong frame), and their rendered x is anchored to
                // the PARENT's slot with an 8pt leading inset.  We
                // recreate that geometry here and give them a synthetic
                // depth one greater than the parent's so they win the
                // z-order when finger is over the interrupt block
                // (since visually they sit on top of the parent).
                let eventAreaWidth = dayFrameInGlobal.width - eventHorizontalInset * 2
                let dayContentMinX = dayFrameInGlobal.minX + eventHorizontalInset
                var bestTopmost: (id: UUID, depth: Int)? = nil
                for occ in visibleOccurrences
                    where occ.event.kind == .event
                        && occ.event.id != dragged.id
                        && occ.event.absorbedIntoEventID == nil {
                    let xStart: CGFloat
                    let xEnd: CGFloat
                    let candidateDepth: Int
                    if embeddedInterruptIDs.contains(occ.id),
                       let relation = occ.event.interruptRelation,
                       let parentOcc = interruptParentLookup[relation.parentEventID],
                       let parentSlot = overlapSlots[parentOcc.id] {
                        let parentX = dayContentMinX + eventAreaWidth * parentSlot.xOffsetFraction
                        let parentWidth = eventAreaWidth * parentSlot.widthFraction
                        let overlay = calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
                        xStart = parentX + overlay.xOffset
                        xEnd = xStart + overlay.width
                        candidateDepth = parentSlot.depth + 1
                    } else {
                        let slot = overlapSlots[occ.id] ?? .default
                        xStart = dayContentMinX + eventAreaWidth * slot.xOffsetFraction
                        xEnd = dayContentMinX + eventAreaWidth * (slot.xOffsetFraction + slot.widthFraction)
                        candidateDepth = slot.depth
                    }
                    guard touch.x >= xStart, touch.x <= xEnd else { continue }
                    // Use `occ.range` (the per-occurrence day-clipped
                    // range the renderer actually positions against,
                    // line 3999: `blockY = headerHeight + blockYFraction
                    // × contentHeight`).  `event.timeRanges` would be
                    // the SERIES SEED for a recurring `.event`, not the
                    // per-day occurrence — using it would only match
                    // when the finger happens to be over where the seed
                    // projects today, i.e., usually nowhere.  The
                    // `+ headerHeight` aligns with the same renderer
                    // formula; without it the hit rect sits up by
                    // ~14–22pt relative to the visible block.
                    let yStart = dayFrameInGlobal.minY + headerHeight + occ.range.start.timeIntervalSince(visibleStart) / 3600 * hourHeight
                    let yEnd = dayFrameInGlobal.minY + headerHeight + occ.range.end.timeIntervalSince(visibleStart) / 3600 * hourHeight
                    guard touch.y >= yStart, touch.y <= yEnd else { continue }
                    if bestTopmost == nil || candidateDepth > bestTopmost!.depth {
                        bestTopmost = (occ.event.id, candidateDepth)
                    }
                }
                return bestTopmost?.id
            }()

            // Side-channel: push the spatial-hit result into dragState so
            // `CalendarPageView.handleEventDrag` reads the SAME parent
            // the highlight pointed at. Without this the drop falls back
            // to time-only match and would absorb into a different
            // parallel event than the one the user visually targeted.
            //
            // Cross-day write race: in week / 3-day mode, multiple
            // TimelineDayViews each run this compute. When the finger
            // crosses from day A to day B, A transitions UUID_A→nil
            // and B transitions nil→UUID_B in the same frame, with
            // undefined onChange firing order. Only-clear-if-we-still-
            // own pattern: write the new UUID unconditionally (we're
            // the new owner), but only clear if `dragState`'s field
            // still holds the value we previously published (we ARE
            // the previous owner, no other day has written since).
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: dropTargetEventID, initial: false) { old, new in
                    if let new {
                        if dragState.currentDropTargetEventID != new {
                            dragState.currentDropTargetEventID = new
                        }
                    } else if let old, dragState.currentDropTargetEventID == old {
                        dragState.currentDropTargetEventID = nil
                    }
                }

            if isPinchActive {
                pinchActiveEventsCanvas(overlapSlots: overlapSlots)
            } else {
            ForEach(occurrences) { occurrence in
                if let displayRange = adjustedRange(for: occurrence) {
                    let isDraggedOccurrence = isActiveDraggedOccurrence(
                        occurrenceID: occurrence.id,
                        draggingOccurrenceID: dragState.draggingOccurrenceID,
                        dragMode: currentMode
                    )
                    let slot = {
                        let liveSlot = overlapSlots[occurrence.id] ?? .default
                        guard isDraggedOccurrence, currentMode == .move else {
                            return liveSlot
                        }
                        return stableOverlapSlots[occurrence.id] ?? liveSlot
                    }()
                    let renderedRange = (isDraggedOccurrence && currentMode == .move)
                        ? occurrence.range
                        : displayRange
                    let eventAreaWidth = contentWidth - eventHorizontalInset * 2
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
                    let parentHasOverlap = interruptParentSlotContext?.slot.widthFraction ?? slot.widthFraction < 1
                    let overlapGap: CGFloat = parentHasOverlap ? 2 : 0
                    let blockWidth = (draggedInterruptSourceGeometry?.width).map { max(0, $0 - overlapGap) }
                        ?? (embeddedOverlayGeometry?.width).map { max(0, $0 - overlapGap) }
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
                    // Slice for cross-day parents: the rendered block only
                    // covers the portion of the parent range that falls in
                    // this day's viewport. Children outside the viewport
                    // would otherwise paint phantom cutouts on a slice they
                    // don't visit, and children inside the viewport would
                    // be projected against the full multi-day duration but
                    // onto the sliced height — both wrong.
                    // `liveOccurrenceRange` (not `adjustedRange`) — the latter
                    // returns the original range during resize, which would
                    // scale cutouts with `renderedBlockHeight` instead of
                    // anchoring them to the embedded child's fixed time.
                    let compoundParentRangeForBlock: Event.TimeRange? = {
                        guard !occurrence.event.isInterrupt else { return nil }
                        let parentRange = liveOccurrenceRange(for: occurrence)
                        let clippedStart = max(parentRange.start, visibleStart)
                        let clippedEnd = min(parentRange.end, visibleEnd)
                        guard clippedEnd > clippedStart else { return parentRange }
                        return Event.TimeRange(start: clippedStart, end: clippedEnd)
                    }()
                    let childRangesForBlock: [Event.TimeRange] = {
                        guard !occurrence.event.isInterrupt,
                              let children = interruptChildrenLookup[interruptAnchorEventID(for: occurrence.event)] else {
                            return []
                        }
                        let parentRange = liveOccurrenceRange(for: occurrence)
                        return children.compactMap { child in
                            let liveRange = liveOccurrenceRange(for: child)
                            guard liveRange.end > parentRange.start,
                                  liveRange.start < parentRange.end else { return nil }
                            // Children outside this day's slice belong to
                            // another rendered slice of the same parent.
                            guard liveRange.end > visibleStart,
                                  liveRange.start < visibleEnd else { return nil }
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

                    // Vertical layout via fraction-of-container.  Dragged
                    // blocks use the raw rendered range (may project past
                    // the visible window during boundary drag); other
                    // blocks clip to [visibleStart, visibleEnd] to match
                    // the legacy `timelineEventHeight` clamp.
                    let blockHeightFraction: CGFloat = {
                        let blockSeconds: TimeInterval
                        if isDraggedOccurrence {
                            blockSeconds = max(0, renderedRange.end.timeIntervalSince(renderedRange.start))
                        } else {
                            let clippedStart = max(renderedRange.start, visibleStart)
                            let clippedEnd = min(renderedRange.end, visibleEnd)
                            blockSeconds = max(0, clippedEnd.timeIntervalSince(clippedStart))
                        }
                        return calendarTimelineDurationFraction(
                            seconds: blockSeconds,
                            leadingExtendedHours: leadingExtendedHours,
                            trailingExtendedHours: trailingExtendedHours
                        )
                    }()
                    let _blockHeight = max(0, blockHeightFraction * contentHeight - 3)
                    let blockYFraction = calendarTimelineYFraction(
                        for: renderedRange.start,
                        containing: date,
                        leadingExtendedHours: leadingExtendedHours,
                        trailingExtendedHours: trailingExtendedHours
                    )
                    let blockY = headerHeight + blockYFraction * contentHeight
                    // Anomaly detection: monitor frame/slot changes for the dragged block
                    let _ = {
                        if isDraggedOccurrence {
                            if let anomaly = DragSessionMonitor.shared.checkFrame(
                                eventID: occurrence.event.id.uuidString,
                                height: _blockHeight,
                                width: blockWidth,
                                slotW: slot.widthFraction
                            ) {
                                dragMovementLog("ANOMALY frame id=\(occurrence.id.prefix(8)) \(anomaly)", severity: .error)
                            }
                        }
                    }()
                    eventBlock(
                        for: occurrence,
                        adjustedRange: renderedRange,
                        isEmbeddedInterrupt: embeddedForBlock,
                        embeddedChildRanges: childRangesForBlock,
                        compoundParentRange: compoundParentRangeForBlock,
                        parentColor: parentColorForBlock,
                        stackPeekCoverRanges: slot.coverRanges,
                        stackPeekStripWidth: stackPeekStripWidthPt,
                        dropTargetEventID: dropTargetEventID
                    )
                        .frame(
                            width: max(0, blockWidth),
                            height: _blockHeight,
                            alignment: .top
                        )
                        .offset(
                            x: blockX,
                            y: blockY + 1.5
                        )
                        // Smoothly transition between overlap topologies
                        // when an adjacent drag re-shapes the cluster (e.g.,
                        // staircase ↔ peer ↔ containment). Disabled on the
                        // actively-dragged block so its frame stays glued to
                        // the finger; the surrounding events do the
                        // re-layout dance.
                        .animation(
                            isDraggedOccurrence ? nil : .spring(response: 0.25, dampingFraction: 0.85),
                            value: slot
                        )
                        .opacity(isDraggedOccurrence && currentMode == .move ? 0 : 1)
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
            }

            // Drag preview for cross-day events (shows new day coverage during drag)
            if dragState.draggingEventID != nil && currentMode == .move {
                if let previewOccurrence = dragPreviewInfo {
                    let previewSlot = overlapSlots[previewOccurrence.id] ?? .default
                    let eventAreaWidth = contentWidth - eventHorizontalInset * 2
                    let previewWidth = eventAreaWidth * previewSlot.widthFraction
                    let previewX = eventHorizontalInset + eventAreaWidth * previewSlot.xOffsetFraction

                    if previewOccurrence.event.isInterrupt,
                       let relation = previewOccurrence.event.interruptRelation,
                       let parentOcc = interruptParentLookup[relation.parentEventID],
                       let parentSlot = overlapSlots[parentOcc.id] {
                        let parentWidth = eventAreaWidth * parentSlot.widthFraction
                        let parentX = eventHorizontalInset + eventAreaWidth * parentSlot.xOffsetFraction
                        let childGeo = calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
                        interruptDragPreview(
                            for: previewOccurrence.event,
                            range: previewOccurrence.range,
                            blockWidth: childGeo.width,
                            blockX: parentX + childGeo.xOffset,
                            parentRange: parentOcc.range,
                            parentWidth: parentWidth,
                            parentX: parentX
                        )
                    } else {
                        dragPreview(
                            for: previewOccurrence.event,
                            range: previewOccurrence.range,
                            blockWidth: previewWidth,
                            blockX: previewX
                        )
                    }
                }
            }

            // Creation preview (topmost, no hit testing)
            // Shows during drag OR while form sheet is open
            if let previewRange = activePreviewRange {
                // During drag-create, slot the preview into its computed
                // column so it occupies the same horizontal space the sibling
                // events have just made room for.  When the form sheet is
                // open (no live drag), there's no draft in the layout so the
                // lookup falls back to full width.
                let creationSlot = overlapSlots[TimelineDayView.creationDraftOccurrenceID] ?? .default
                creationPreview(for: previewRange, slot: creationSlot)
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

            // Boundary extension day hints (e.g. "SAT 26" in extended region)
            boundaryDayHints
                .zIndex(99)

            // SwiftUI nowIndicator uses `.offset(y:)` which renders the
            // 1.5pt line at fractional sub-pixels — visible as jitter as
            // hourHeight changes per pinch frame.  During pinch the Canvas
            // path draws the line directly with identical fraction math
            // (consistent with how event blocks are drawn there).  Outside
            // pinch the SwiftUI path resumes so the 1s periodic refresh
            // can advance the line as time passes.
            if !isPinchActive {
                nowIndicator
                    .zIndex(100)
            }
        }
        .id("\(style.variant)-\(date.timeIntervalSince1970)")
        .background(
            // Capture this day's frame in the window coordinate space so
            // the finger-driven absorption hit can convert
            // `dragState.currentTouchPointGlobal` (which the UIKit
            // gesture handler writes as window coords) into a day-local
            // x fraction. Updated on appear and whenever the frame
            // shifts (scroll, resize, mode change).
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        let frame = proxy.frame(in: .global)
                        if dayFrameInGlobal != frame {
                            dayFrameInGlobal = frame
                        }
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, new in
                        if dayFrameInGlobal != new {
                            dayFrameInGlobal = new
                        }
                    }
            }
            .allowsHitTesting(false)
        )
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
        .onAppear { refreshCachedLayout() }
        .onChange(of: occurrences) { _, _ in refreshCachedLayout() }
        .onChange(of: dragState.draggingEventID) { _, _ in refreshCachedLayout() }
        .onReceive(calendarEventStore.calendarTodoAbsorbed) { parentID in
            recentlyAbsorbedParents.insert(parentID)
            // Auto-clear after the pulse window so subsequent absorptions
            // into the same parent can re-trigger. EventBlock observes
            // the prop on change AND on appear, so the timing works
            // both for "user was looking" and "user came back".
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                recentlyAbsorbedParents.remove(parentID)
            }
        }
        .onChange(of: dragState.draggingEventID) { _, newID in
            // Cache the dragged event once per drag session so the
            // per-block isAbsorptionDropTarget check doesn't rescan
            // calendarEvents per frame (perf hot path under drag).
            if let newID = newID,
               let candidate = calendarEventStore.rawCalendarEvents.first(where: { $0.id == newID }),
               candidate.kind == .todo {
                cachedDraggedTodo = candidate
            } else {
                cachedDraggedTodo = nil
                // Drag ended → clear the spatial-hit cache too.
                if dragState.currentDropTargetEventID != nil {
                    dragState.currentDropTargetEventID = nil
                }
            }
        }
        .onAppear {
            // Mount-time seed: `.onChange` above only fires on value
            // TRANSITIONS, so a TimelineDayView that scrolls into view
            // MID-DRAG (e.g., edge-scroll travelled far enough to
            // mount a new day) wouldn't pick up the in-progress drag
            // and `cachedDraggedTodo` would stay nil — breaking the
            // spatial-hit guard and silently killing the absorption
            // highlight on those newly-visible days (dogfood bug
            // 2026-05-27: highlight disappears at distance from
            // origin day).
            if cachedDraggedTodo == nil,
               let id = dragState.draggingEventID,
               let candidate = calendarEventStore.rawCalendarEvents.first(where: { $0.id == id }),
               candidate.kind == .todo {
                cachedDraggedTodo = candidate
            }
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
                lastSnappedStartEdge = nil
                lastSnappedEndEdge = nil
                snapHaptic.prepare()
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
                checkAdjacentSnapHaptic()
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
                lastSnappedStartEdge = nil
                lastSnappedEndEdge = nil
            },
            onCancelled: {
                isCreating = false
                isLongPressingCreation = false
                lastTickMinutes = -1
                lastSnappedStartEdge = nil
                lastSnappedEndEdge = nil
            }
        )
    }

    private var creationPreviewRange: Event.TimeRange? {
        guard isCreating else { return nil }

        let startTime = timeFromYWithAdjacentSnap(creationStartY).snappedTime
        let endTime = timeFromYWithAdjacentSnap(creationCurrentY).snappedTime

        // Ensure start < end
        if startTime < endTime {
            return Event.TimeRange(start: startTime, end: endTime)
        } else {
            return Event.TimeRange(start: endTime, end: startTime)
        }
    }

    /// Resolved time at `y` after applying both grid snap and (optionally)
    /// magnetic snap to neighbor event edges. Returns the matched neighbor
    /// edge so callers can drive haptic feedback on snap engage/disengage.
    private func timeFromYWithAdjacentSnap(_ y: CGFloat) -> (snappedTime: Date, snappedEdge: Date?) {
        let candidate = timeFromY(y)
        guard adjacentEventSnapEnabled, hourHeight > 0 else {
            return (candidate, nil)
        }
        let raw = calendarTimelineDateFromYPosition(
            y,
            containing: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours,
            snapMinutes: 1
        )
        let thresholdSeconds = TimeInterval(adjacentEventSnapThresholdPt / hourHeight * 3600)
        return calendarApplyAdjacentEventSnap(
            candidateTime: candidate,
            rawTime: raw,
            neighborEdges: neighborEventEdges,
            thresholdSeconds: thresholdSeconds
        )
    }

    /// All start/end timestamps of events on this day, used as magnetic
    /// targets for the creation drag.
    private var neighborEventEdges: [Date] {
        var edges: [Date] = []
        edges.reserveCapacity(occurrences.count * 2)
        for occurrence in occurrences {
            edges.append(occurrence.range.start)
            edges.append(occurrence.range.end)
        }
        return edges
    }

    /// Single source of truth for the title-over-time text stack used
    /// inside drag-to-create / drag-to-move / interrupt-drag preview
    /// blocks. Mirrors the metrics used by `EventBlock` (title font size
    /// from settings, derived time font, shared insets and spacing) so
    /// previews and real blocks stay pixel-aligned. When `availableHeight`
    /// is too small to fit both rows, drops the time row and shows the
    /// title alone.
    @ViewBuilder
    private func previewTextStack(title: String, range: Event.TimeRange, availableHeight: CGFloat) -> some View {
        let titleFontSize = resolvedTitleFontSize
        let timeFontSize = calendarEventTimeFontSize(
            forTitleFontSize: titleFontSize,
            isWeekMode: isWeekMode
        )
        let insets = calendarEventBlockInsets(
            isWeekMode: isWeekMode,
            isThreeDayMode: isThreeDayMode
        )
        let spacing = calendarEventBlockTitleSpacing(
            isWeekMode: isWeekMode,
            isThreeDayMode: isThreeDayMode
        )
        let titleLineHeight = UIFont.systemFont(ofSize: titleFontSize, weight: .semibold).lineHeight
        let timeLineHeight = UIFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium).lineHeight
        let minHeightForTitle = insets.vertical * 2 + titleLineHeight
        let minHeightForBoth = minHeightForTitle + spacing + timeLineHeight
        let showsTime = availableHeight >= minHeightForBoth

        if availableHeight >= minHeightForTitle * 0.85 {
            VStack(alignment: .leading, spacing: spacing) {
                Text(title)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .lineLimit(1)
                if showsTime {
                    Text(timeRangeText(for: range))
                        .font(.system(size: timeFontSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .padding(.vertical, insets.vertical)
        }
    }

    private func creationPreview(
        for range: Event.TimeRange,
        slot: CalendarLayout.EventOverlapSlot = .default
    ) -> some View {
        let y = timelineYOffset(for: range)
        let isZeroDuration = range.end.timeIntervalSince(range.start) < 1
        let height = timelineEventHeight(
            for: range,
            minimumHeight: 0
        )

        let eventAreaWidth = contentWidth - eventHorizontalInset * 2
        // Match the overlap gap used by real event blocks (line 3565) so the
        // draft sits cleanly against its repositioned neighbors.
        let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
        let width = max(0, eventAreaWidth * slot.widthFraction - overlapGap)
        let x = eventHorizontalInset + eventAreaWidth * slot.xOffsetFraction

        let creationColor = calendarCurrentTimeIndicatorColor()
        return RoundedRectangle(cornerRadius: isZeroDuration ? 2 : 10, style: .continuous)
            .fill(creationColor.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: isZeroDuration ? 2 : 10, style: .continuous)
                    .stroke(creationColor.opacity(0.6), lineWidth: 2)
            )
            .overlay(
                previewTextStack(title: L(.newEvent), range: range, availableHeight: height),
                alignment: .topLeading
            )
            .frame(width: width, height: height)
            .offset(x: x, y: y)
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

    /// Fires a selection haptic when either edge of the creation range newly
    /// engages (or disengages) magnetic snap to a neighbor event boundary.
    private func checkAdjacentSnapHaptic() {
        guard adjacentEventSnapEnabled else {
            if lastSnappedStartEdge != nil { lastSnappedStartEdge = nil }
            if lastSnappedEndEdge != nil { lastSnappedEndEdge = nil }
            return
        }
        let startEdge = timeFromYWithAdjacentSnap(creationStartY).snappedEdge
        let endEdge = timeFromYWithAdjacentSnap(creationCurrentY).snappedEdge
        if startEdge != lastSnappedStartEdge {
            if startEdge != nil { snapHaptic.selectionChanged() }
            lastSnappedStartEdge = startEdge
        }
        if endEdge != lastSnappedEndEdge {
            if endEdge != nil { snapHaptic.selectionChanged() }
            lastSnappedEndEdge = endEdge
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
                previewTextStack(title: event.title, range: range, availableHeight: height),
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
                    previewTextStack(title: event.title, range: range, availableHeight: childHeight),
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
                                    .font(.system(size: 9, weight: .semibold))
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

    // Canvas-based event rendering used while `isPinchActive`.  Collapses
    // the N individual EventBlock views into a single drawing pass so
    // SwiftUI layout work goes from O(N × passes) to O(1).  Renders the
    // same visual primitives as the prior lite-EventBlock spike (rounded
    // rect + stroke + title), drawn via GraphicsContext.  Fraction math
    // mirrors the ForEach path so geometry matches at pinch boundaries.
    @ViewBuilder
    private func pinchActiveEventsCanvas(
        overlapSlots: [String: CalendarLayout.EventOverlapSlot]
    ) -> some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, _ in
            let eventAreaWidth = contentWidth - eventHorizontalInset * 2

            // Now-line drawn in the same Canvas as events so it shares
            // their rendering path — no .offset/sub-pixel jitter.
            if calendarShouldShowNowIndicator(for: date) {
                let now = Date()
                let indicatorColor = calendarCurrentTimeIndicatorColor()
                let nowY = headerHeight + calendarTimelineYFraction(
                    for: now,
                    containing: date,
                    leadingExtendedHours: leadingExtendedHours,
                    trailingExtendedHours: trailingExtendedHours
                ) * contentHeight
                let lineHeight: CGFloat = 1.5
                let dotSize: CGFloat = 7
                let lineRect = CGRect(
                    x: eventHorizontalInset,
                    y: nowY - lineHeight / 2,
                    width: max(0, eventAreaWidth),
                    height: lineHeight
                )
                context.fill(Path(lineRect), with: .color(indicatorColor.opacity(0.92)))
                let dotRect = CGRect(
                    x: eventHorizontalInset - dotSize / 2,
                    y: nowY - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(ellipseIn: dotRect), with: .color(indicatorColor))
            }

            for occurrence in occurrences {
                guard let displayRange = adjustedRange(for: occurrence) else { continue }

                let slot = overlapSlots[occurrence.id] ?? .default
                let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
                let blockWidth = max(0, eventAreaWidth * slot.widthFraction - overlapGap)
                let blockX = eventHorizontalInset + eventAreaWidth * slot.xOffsetFraction

                let clippedStart = max(displayRange.start, visibleStart)
                let clippedEnd = min(displayRange.end, visibleEnd)
                let blockSeconds = max(0, clippedEnd.timeIntervalSince(clippedStart))
                let blockHeightFraction = calendarTimelineDurationFraction(
                    seconds: blockSeconds,
                    leadingExtendedHours: leadingExtendedHours,
                    trailingExtendedHours: trailingExtendedHours
                )
                let blockHeight = max(0, blockHeightFraction * contentHeight - 3)
                let blockY = headerHeight + calendarTimelineYFraction(
                    for: displayRange.start,
                    containing: date,
                    leadingExtendedHours: leadingExtendedHours,
                    trailingExtendedHours: trailingExtendedHours
                ) * contentHeight + 1.5

                guard blockWidth > 0, blockHeight > 0 else { continue }

                let blockRect = CGRect(x: blockX, y: blockY, width: blockWidth, height: blockHeight)
                let color = CalendarLayout.eventColor(for: occurrence.event)
                let cornerRadius: CGFloat = occurrence.event.isInterrupt ? 5 : 10

                let bgPath = Path(roundedRect: blockRect, cornerRadius: cornerRadius)
                context.fill(bgPath, with: .color(color.opacity(0.18)))
                context.stroke(bgPath, with: .color(color.opacity(0.55)), lineWidth: 0.5)

                // Text fade-out ramp: smoothly transitions visibility as the
                // event block shrinks past the title-fitting threshold.
                // - blockHeight ≥ 22: full opacity
                // - blockHeight 14-22: linear fade
                // - blockHeight < 14: hidden
                // Replaces the prior hard `>= 18` cutoff that snapped on/off.
                let textAlpha: CGFloat = {
                    if blockHeight >= 22 { return 1.0 }
                    if blockHeight <= 14 { return 0.0 }
                    return (blockHeight - 14) / 8.0
                }()
                if showEventText, textAlpha > 0.01 {
                    // Text rect inset matches the SwiftUI version's
                    // `.padding(.horizontal, 4).padding(.top, 2)`.
                    // `context.resolve` only accepts `Text`, so apply only
                    // Text-preserving modifiers (font, foregroundColor).
                    // Truncation is handled by `draw(_, in: rect)` clipping
                    // to the constrained rect.
                    let textRect = CGRect(
                        x: blockRect.minX + 4,
                        y: blockRect.minY + 2,
                        width: max(0, blockRect.width - 8),
                        height: max(0, blockRect.height - 4)
                    )
                    let resolved = context.resolve(
                        Text(occurrence.event.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(color)
                    )
                    if textAlpha >= 0.999 {
                        context.draw(resolved, in: textRect)
                    } else {
                        // Use drawLayer so the alpha multiplication is
                        // scoped to this draw and doesn't leak into the
                        // next event's stroke/fill.
                        context.drawLayer { layer in
                            layer.opacity = textAlpha
                            layer.draw(resolved, in: textRect)
                        }
                    }
                }
            }
        }
        .frame(
            width: contentWidth,
            height: headerHeight + contentHeight + timelineBottomInset,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
    }

    // Single source of truth for the event-area height; all vertical layout
    // helpers below derive from it.  Mirroring the horizontal pattern where
    // events position themselves via `widthFraction × eventAreaWidth`.
    private var contentHeight: CGFloat {
        calendarTimelineContentHeight(
            hourHeight: hourHeight,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
    }

    private func nowIndicatorYOffset(for now: Date) -> CGFloat {
        headerHeight + calendarTimelineYFraction(
            for: now,
            containing: date,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        ) * contentHeight
    }

    private func timelineYOffset(for range: Event.TimeRange) -> CGFloat {
        headerHeight + calendarTimelineYFraction(
            for: range.start,
            containing: date,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        ) * contentHeight
    }

    private func timelineEventHeight(
        for range: Event.TimeRange,
        minimumHeight: CGFloat
    ) -> CGFloat {
        let clippedStart = max(range.start, visibleStart)
        let clippedEnd = min(range.end, visibleEnd)
        let seconds = max(0, clippedEnd.timeIntervalSince(clippedStart))
        let fraction = calendarTimelineDurationFraction(
            seconds: seconds,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
        return max(minimumHeight, fraction * contentHeight)
    }

    /// Rebuilds all cached layout data from the current `occurrences`.
    /// Called on appear, when occurrences change, and when drag starts/ends.
    private func refreshCachedLayout() {
        let previewOnlyOccurrence = previewOnlyDraggedOccurrence
        var resolved = occurrences.compactMap { occurrence in
            liveLayoutRange(for: occurrence).map { displayRange in
                CalendarLayout.EventOccurrence(
                    id: occurrence.id,
                    event: occurrence.event,
                    range: displayRange
                )
            }
        }
        if let previewOnlyOccurrence {
            resolved.append(previewOnlyOccurrence)
        }
        cachedVisibleOccurrences = resolved

        var parentLookup: [UUID: CalendarLayout.EventOccurrence] = [:]
        for occ in resolved where !occ.event.isInterrupt {
            parentLookup[interruptAnchorEventID(for: occ.event)] = occ
        }
        cachedInterruptParentLookup = parentLookup

        var childrenLookup: [UUID: [CalendarLayout.EventOccurrence]] = [:]
        for occ in resolved {
            guard let relation = occ.event.interruptRelation,
                  relation.state == .embedded else { continue }
            childrenLookup[relation.parentEventID, default: []].append(occ)
        }
        cachedInterruptChildrenLookup = childrenLookup

        var embeddedIDs = Set<String>()
        for occ in resolved {
            guard occ.event.isInterrupt,
                  let relation = occ.event.interruptRelation,
                  relation.state == .embedded,
                  let parentOcc = parentLookup[relation.parentEventID],
                  let parentRange = adjustedRange(for: parentOcc) else { continue }
            let liveRange = liveOccurrenceRange(for: occ)
            if liveRange.end > parentRange.start && liveRange.start < parentRange.end {
                embeddedIDs.insert(occ.id)
            }
        }
        cachedEmbeddedInterruptIDs = embeddedIDs

        let overlapCandidates = resolved.filter { occurrence in
            guard occurrence.event.isInterrupt,
                  occurrence.event.interruptRelation != nil else {
                return true
            }
            if embeddedIDs.contains(occurrence.id) {
                return false
            }
            return true
        }
        cachedOverlapSlots = CalendarLayout.overlapLayout(
            for: overlapCandidates,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            peekFraction: stackPeekFraction,
            peerTolerance: stackPeekPeerToleranceSeconds
        )
    }

    private var grid: some View {
        let lineWidth = max(0, contentWidth - eventHorizontalInset * 2)
        let isHalfHourGrid = slotMinutes == 30
        let lineInsetX = (contentWidth - lineWidth) / 2
        let totalHeight = headerHeight + CGFloat(slotCount) * slotHeight + timelineBottomInset
        let resolvedGridColor = style.gridColor
        let isDashed = style.gridDashed

        return Canvas { context, _ in
            for index in 0..<slotCount {
                let y = headerHeight + CGFloat(index) * slotHeight
                let isSubHourLine = isHalfHourGrid && index % 2 != 0
                let path = Path { p in
                    p.move(to: CGPoint(x: lineInsetX, y: y))
                    p.addLine(to: CGPoint(x: lineInsetX + lineWidth, y: y))
                }
                if isDashed || isSubHourLine {
                    context.stroke(
                        path,
                        with: .color(resolvedGridColor),
                        style: StrokeStyle(
                            lineWidth: isSubHourLine ? 1.5 : 1,
                            dash: isDashed ? [4, 3] : [3, 4]
                        )
                    )
                } else {
                    context.fill(
                        Path(CGRect(x: lineInsetX, y: y, width: lineWidth, height: 1)),
                        with: .color(resolvedGridColor)
                    )
                }
            }
        }
        .frame(width: contentWidth, height: totalHeight)
        .allowsHitTesting(false)
    }

    private func interruptAnchorEventID(for event: Event) -> UUID {
        event.recurrenceParentId ?? event.id
    }

    private func liveOccurrenceRange(
        for occurrence: CalendarLayout.EventOccurrence
    ) -> Event.TimeRange {
        // Guard before reading high-frequency properties (dragOffset) so
        // that @Observable only tracks dragOffset for the dragged occurrence's
        // day, not every rendered day.
        guard occurrence.id == dragState.draggingOccurrenceID else {
            return occurrence.range
        }
        return calendarResolvedLiveOccurrenceRange(
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

    private func eventBlock(
        for occurrence: CalendarLayout.EventOccurrence,
        adjustedRange: Event.TimeRange,
        isEmbeddedInterrupt: Bool = false,
        embeddedChildRanges: [Event.TimeRange] = [],
        compoundParentRange: Event.TimeRange? = nil,
        parentColor: Color? = nil,
        stackPeekCoverRanges: [Event.TimeRange] = [],
        stackPeekStripWidth: CGFloat = 0,
        dropTargetEventID: UUID? = nil
    ) -> some View {
        let event = occurrence.event
        let originalRange = occurrence.range
        let actionDate = occurrence.range.start
        // Whether this event was recently absorbed-into. Drives the
        // EventBlock pulse animation. The set is maintained at body
        // level via `.onReceive(calendarTodoAbsorbed)` so the prop
        // is `true` on EventBlock re-appearance after a picker
        // absorption — covers the case where the user wasn't looking
        // at the canvas when the absorption happened.
        let isRecentlyAbsorbedInto = recentlyAbsorbedParents.contains(event.id)
        // Drop-target match: pure id comparison. Selection logic
        // (preview-range overlap, kind / absorbed gating) ran once at
        // body level — we just check whether THIS block was chosen.
        // Per-block cost drops to a UUID `==`, no preview read, so
        // non-target blocks don't subscribe to dragOffset.
        let isAbsorptionDropTarget: Bool = dropTargetEventID == event.id
        let isEventFocused = focusedEventID == event.id
            && (focusedOccurrenceID == nil || focusedOccurrenceID == occurrence.id)
        let isPreviewHandleTarget = previewHandleEventID == event.id
            && (previewHandleOccurrenceID == nil || previewHandleOccurrenceID == occurrence.id)
        let isGraceResizeTarget = graceResizeEventID == event.id
            && (graceResizeOccurrenceID == nil || graceResizeOccurrenceID == occurrence.id)
        let blockStyle: EventBlockStyle = isEventFocused ? .edit : .preview
        let isDraggedEvent = dragState.draggingEventID == event.id
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

        // Allow move drag to cross the base day boundary so extended view can
        // still open, but stop at the theoretical 12h extension edges.
        let computedVerticalDragBounds: ClosedRange<CGFloat> = {
            let calendar = Calendar.current
            let dayStart = calendar.startOfDay(for: date)
            let maxBoundaryStart = dayStart.addingTimeInterval(
                TimeInterval(-calendarTimelineMaximumBoundaryExtensionHours * 3600)
            )
            let maxBoundaryEnd = dayStart.addingTimeInterval(
                TimeInterval(
                    (calendarTimelineBaseVisibleHours + calendarTimelineMaximumBoundaryExtensionHours) * 3600
                )
            )
            let dur = originalRange.end.timeIntervalSince(originalRange.start)
            let minOffsetSeconds = maxBoundaryStart.timeIntervalSince(originalRange.start)
            let maxOffsetSeconds = maxBoundaryEnd.timeIntervalSince(originalRange.start) - dur
            let minY = CGFloat(minOffsetSeconds / 3600) * hourHeight
            let maxY = CGFloat(maxOffsetSeconds / 3600) * hourHeight
            let clampedUpper = max(minY, maxY)
            return minY ... clampedUpper
        }()

        // Keep handles available while the adjusted range remains inside the
        // temporary extended viewport. Use originalRange + strict inequalities
        // so an event whose endpoint sits exactly at midnight (but doesn't
        // truly extend across the day boundary) keeps its handle.
        let startsBeforeVisibleRange = originalRange.start < visibleStart
        let endsAfterVisibleRange = originalRange.end > visibleEnd

        let hasMultiTypeIndicator = experimentalMultiTypeEnabled
            && (event.additionalTypes?.isEmpty == false)

        return EventBlock(
            event: event,
            occurrenceID: occurrence.id,
            dragSourceRange: originalRange,
            renderDayStart: Calendar.current.startOfDay(for: date),
            displayRange: adjustedRange,
            color: event.agenticIntake?.processingPhase == .analyzing
                ? calendarCurrentTimeIndicatorColor()
                : CalendarLayout.eventColor(for: event),
            showsMultiTypeIndicator: hasMultiTypeIndicator,
            isRecentlyAbsorbedInto: isRecentlyAbsorbedInto,
            isAbsorptionDropTarget: isAbsorptionDropTarget,
            showText: showEventText,
            isWeekMode: isWeekMode,
            isThreeDayMode: isThreeDayMode,
            boundPeople: calendarEventStore.people(for: event.peopleIDs ?? []),
            style: blockStyle,
            liveHourHeight: liveHourHeight,
            isPinchActive: isPinchActive,
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
            // Always allow drag end for the actively dragged event —
            // isInteractionAllowed may become false after boundary page
            // (isFocusContextActive changes), but the end callback must
            // still fire to commit the move.
            onDragEnded: (onEventDragEnded != nil && (isInteractionAllowed || isDraggedEvent) && !isGraceResizeTarget) ? { offset in
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
            onHorizontalBoundaryPageRequest: onHorizontalBoundaryPageRequest,
            // Disable resize handles for cross-day boundaries
            canResizeTop: !startsBeforeVisibleRange,
            canResizeBottom: !endsAfterVisibleRange,
            verticalDragBounds: computedVerticalDragBounds,
            isTimerActive: event.timerStartedAt != nil,
            agenticProcessingPhase: event.agenticIntake?.processingPhase,
            interruptState: event.interruptRelation?.state,
            interruptParentColor: parentColor,
            interruptIsCurrentlyEmbedded: isEmbeddedInterrupt,
            interruptEmbeddedChildRanges: embeddedChildRanges,
            interruptCompoundParentRange: compoundParentRange,
            stackPeekCoverRanges: stackPeekCoverRanges,
            stackPeekStripWidth: stackPeekStripWidth,
            // Cross-day drag sync
            dragState: dragState
        )
        .modifier(TodoEventAbsorptionDragDropModifier(
            event: event,
            onAbsorb: { todoID in
                calendarEventStore.absorbTodoIntoEvent(
                    todoID: todoID,
                    parentEventID: event.id
                )
            }
        ))
    }

    @ViewBuilder
    private var boundaryDayHints: some View {
        let placements = calendarTimelineBoundaryDayHintPlacements(
            anchorDate: date,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
        let totalVisibleHours = calendarTimelineTotalVisibleHours(
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
        if let leading = placements.leading {
            boundaryDayHintBadge(
                placement: leading,
                totalVisibleHours: totalVisibleHours
            )
        }
        if let trailing = placements.trailing {
            boundaryDayHintBadge(
                placement: trailing,
                totalVisibleHours: totalVisibleHours
            )
        }
    }

    private func boundaryDayHintBadge(
        placement: TimelineBoundaryDayHintPlacement,
        totalVisibleHours: Int
    ) -> some View {
        let rowHeight: CGFloat = 26
        let clampedY = clamp(
            placement.originY,
            headerHeight,
            headerHeight + CGFloat(totalVisibleHours) * hourHeight - rowHeight
        )
        let weekday = TimeAxisLabels.boundaryDayHintWeekdayFormatter.string(from: placement.date).uppercased()
        let day = TimeAxisLabels.boundaryDayHintDayFormatter.string(from: placement.date)

        return VStack(spacing: -1) {
            Text(weekday)
                .font(.system(size: 9, weight: .bold))
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
        .frame(width: contentWidth, alignment: .trailing)
        .padding(.trailing, 8)
        .offset(y: clampedY)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var extensionRegionBackdrop: some View {
        let tint = Color.secondary.opacity(0.05)
        let separator = Color.secondary.opacity(0.12)
        let hasLeading = leadingExtendedHours > 0
        let hasTrailing = trailingExtendedHours > 0
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
