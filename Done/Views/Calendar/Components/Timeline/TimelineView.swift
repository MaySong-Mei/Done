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

// Extracted for regression tests: boundary-extension reflow does not animate
// during drag. SwiftUI animating `leading` would interpolate event canvas
// rows over the spring, fighting our CADisplayLink animator that drives
// scroll + `.offset` together in lockstep (#55). The visual "unfold" comes
// entirely from the offset modifier, not from animating `leading` itself.
// Outside drag, the spring is fine because no animator path is engaged.
//
// Same suppression applies during the follow-event-across-midnight re-
// anchor (#55): when the atomic swap flips `leading` (0↔12), SwiftUI's
// `.animation(boundaryExtensionAnimation, value: leading)` would
// interpolate every event's canvas y over 0.28s while our
// CADisplayLink already snapped scrollY in lockstep with the swap →
// events visibly drift for 0.28s. Forward direction surfaces this
// because it flips `leading` (visibleStart shifts 12h); backward flips
// `trailing` (visibleStart unchanged) so events stay put.
func calendarShouldAnimateTimelineBoundaryExtension(
    isMoveDragActive: Bool,
    isCreationDragActive: Bool,
    reduceMotion: Bool,
    isFollowEventActive: Bool = false
) -> Bool {
    !reduceMotion && !isMoveDragActive && !isCreationDragActive && !isFollowEventActive
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
// Used by the day renderer to skip drag-preview computation (which reads
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
    /// Written by `CalendarDayLayerView` (it has overlapSlots + spatial info);
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
    // Visual-fidelity inputs the CALayer day view needs to match `EventBlock`'s
    // text gates + multi-type indicator. Mirror the same `@AppStorage` sources
    // `EventBlock` reads.
    @AppStorage(AppSettingsKeys.calendarEventFontSize) private var calayerTitleFontSizeSetting: Double = Double(calendarEventTitleFontSizeDefault)
    @AppStorage(AppSettingsKeys.calendarEventShowTimeBelowTitle) private var calayerShowTimeBelowTitle: Bool = true
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var calayerMultiTypeEnabled = false
    // CALayer chrome: future-zone tint + horizon line span.
    @AppStorage(AppSettingsKeys.nearFutureHorizonDays) private var nearFutureHorizonDays: Int = EventZone.defaultHorizonDays
    // CALayer-backed axis port (`TimeAxisLayerHost`) replacing the SwiftUI
    // `TimeAxisLabels` tree. Default ON after on-device A/B parity sign-off
    // (idle / pinch / scroll / drag / cross-midnight). See
    // `TimeAxisLayerView.swift` (issue #60).
    @AppStorage(AppSettingsKeys.calendarUseCALayerAxisMarkers) private var useCALayerAxisMarkers = true
    var dragState: EventDragState
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    var allDayOccurrencesForOffset: ((Int) -> [CalendarLayout.EventOccurrence])? = nil
    /// Pre-computed max all-day count across the visible day range, supplied
    /// by the parent.  Avoids a per-body iteration of the entire dayRange.
    var maxAllDayCountOverride: Int? = nil
    @Binding var selectedDayOffset: Int
    @Binding var rangeMode: RangeMode
    @Binding var hourHeight: CGFloat
    /// #55: visual y-offset applied to timeline content during OPEN animation
    /// so events stay glued to finger while scroll catches up. Default 0.
    var boundaryExtensionVisualYOffset: CGFloat = 0
    /// #55: when true, skip the day-column horizontal swipe animation when
    /// `selectedDayOffset` changes. Used by follow-event-across-midnight so
    /// its math-equivalent atomic swap is invisible (no horizontal slide).
    var suppressDayColumnHorizontalAnimation: Bool = false
    /// Spec 07: when true (caller passes `useUIScrollViewTimeline &&
    /// useImperativeDayLayer`), single-day mode renders the day-layer with a
    /// 48h-CONSTANT coordinate window (12h leading + 24h + 12h trailing) so
    /// band open/close never changes `contentSize`. The all-day row is pinned
    /// to the scroll frame top by the host, so the in-scroll all-day band is
    /// suppressed here. Default false ⇒ flag-OFF tree is byte-identical.
    var useImperativeDayLayerModel: Bool = false
    /// #55 follow-on: per-side opacity multiplier (applied via `.mask`) on the
    /// extension bands. 0 = solid, 1 = transparent. Leading (top) and trailing
    /// (bottom) are independent so one can dissolve without touching the other.
    var leadingFadeProgress: CGFloat = 0
    var trailingFadeProgress: CGFloat = 0
    var isDayOffsetFrozen: Bool = false
    let daysCount: Int
    let mode: PageMode
    let showEventText: Bool
    let dayRange: ClosedRange<Int>
    var previewCreation: PendingEventCreation? = nil
    var focusedEventID: UUID? = nil
    var focusedOccurrenceID: String? = nil
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
    /// Fires on every TRANSITION of the pinch-frozen slot density (nil
    /// when no pinch in progress, non-nil during a pinch). Lets the
    /// parent's UIScrollView contentH math use the SAME `effectiveSlot`
    /// as the SwiftUI tree during a pinch — without this the host
    /// computes contentH from the LIVE slotMinutes while the timeline
    /// is laid out using the FROZEN slotMinutes, leaving up to ~35pt of
    /// stale scrollable space at the bottom when a pinch crosses the
    /// hourHeight=76 threshold (deep-review C2).  Mutation sites are
    /// gated on `oldValue != newValue` so this doesn't fire on every
    /// pinch frame.
    var onFrozenSlotMinutesChange: ((Int?) -> Void)? = nil
    var boundaryExtensionStateOverride: TimelineBoundaryExtensionState? = nil

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
            // Real all-day height (NOT effective): even when the row is pinned
            // out of the scroll, the pinned overlay still occupies the same
            // viewport space, so the pinch floor must keep reserving it or the
            // early-morning hours render behind the pinned pills at max pinch.
            allDayHeight: allDayHeight,
            safetyFloor: calendarTimelineHourHeightMin
        )
    }
    // `editMappingState` / `editMappingPresentation` moved into
    // `TimelineAxisDragOverlay` (the body of `timeAxis()`'s sub-view). Both
    // read `dragState.dragOffset` transitively, so keeping them as
    // body-scope computeds here would re-register the per-frame body
    // dependency that #77 deletes. (#77)

    /// Computes the boundary-extension mapping state from the current drag /
    /// creation source. Reads `resolvedDragEditMapping` (which reads
    /// `dragState.dragOffset`); to avoid registering body-scope dependencies
    /// on `dragOffset`, this MUST be called only from `.onChange` handlers /
    /// modifier closures, never from body. Body-scope readers use the
    /// `@State`-latched `cachedRawBoundaryExtensionState` via the
    /// `rawBoundaryExtensionState` computed below. (#77)
    private func computeBoundaryExtensionMappingState() -> TimelineEditMappingState? {
        calendarResolveBoundaryExtensionMappingState(
            creation: resolvedCreationEditMapping,
            drag: resolvedDragEditMapping
        )
    }

    /// Computes the raw boundary extension hours from the current drag /
    /// creation source. Reads `dragState.dragOffset` transitively; MUST be
    /// called only from `.onChange` handlers / modifier closures, never from
    /// body. Body-scope readers use `cachedRawBoundaryExtensionState`. (#77)
    private func computeRawBoundaryExtensionHours(
        mappingState: TimelineEditMappingState?
    ) -> (leading: Int, trailing: Int) {
        var result = calendarTimelineBoundaryExtensionHours(mappingState: mappingState)

        // Cross-day event fix: when the scroll has hit the top boundary
        // (can't go further up) and the user is actively dragging upward,
        // proactively open the leading extension even though the event
        // range hasn't technically crossed midnight. Without this, events
        // starting late at night (e.g. 23:00) can never reach midnight by
        // finger drag alone (23h × hourHeight is physically unreachable)
        // and the vertical autoscroll is stuck at y=0 with nowhere to go.
        //
        // Trigger gate tightened: previously `< hourHeight * 2` (within 2
        // hours of top) — too generous, the extension fired even when the
        // user was still mid-column. Now only when scroll is at the top
        // boundary (`< 1pt`), so the extension only opens when the user
        // is literally at the edge and out of room to scroll. (#53
        // single-day follow-on)
        //
        // The trigger predicate used to read `dragState.dragOffset.y` here
        // directly. That read made `TimelineView.body` an observer of
        // dragOffset (the chain `rawBoundaryExtensionHours` → … →
        // `boundaryExtensionHours.leading` is reached from body), so every
        // drag-frame write to dragOffset invalidated body. Reading the
        // pre-computed latch instead breaks that dependency edge — the
        // latch is updated by an `.onChange(of: dragState.dragOffset.y)`
        // handler whose body-scope is just the modifier closure, not
        // `TimelineView.body`. (#75)
        if let state = mappingState,
           state.source == .moveDrag || state.source == .resizeTop,
           result.leading == 0,
           proactiveLeadingExtensionLatch {
            result.leading = calendarTimelineMaximumBoundaryExtensionHours
        }

        return result
    }

    /// Recomputes the proactive leading-extension latch (see
    /// `proactiveLeadingExtensionLatch`'s doc-comment). Called by the
    /// `dragOffset.y` and `verticalScrollY` onChange handlers in body. The
    /// guards (active drag, dragOffset.y < -hourHeight, scroll pinned at
    /// top) mirror exactly the predicate that used to live inside
    /// `rawBoundaryExtensionHours` — moved out so body stops observing
    /// `dragState.dragOffset`. (#75)
    private func updateProactiveLeadingExtensionLatch(dragOffsetY: CGFloat) {
        let isDraggingActive = dragState.draggingEventID != nil
        let isUpwardPastHourThreshold = hourHeight > 0 && dragOffsetY < -hourHeight
        let isScrollPinnedAtTop = verticalScrollY < 1
        let shouldLatch = isDraggingActive
            && isUpwardPastHourThreshold
            && isScrollPinnedAtTop
        if proactiveLeadingExtensionLatch != shouldLatch {
            proactiveLeadingExtensionLatch = shouldLatch
        }
    }

    /// Body-scope reader for the raw boundary extension state. Returns the
    /// `@State`-latched cached value so body does NOT observe `dragOffset`
    /// transitively. Refreshed via `refreshCachedRawBoundaryExtensionState()`
    /// from `.onChange` handlers that watch every input the underlying compute
    /// reads. (#77)
    private var rawBoundaryExtensionState: TimelineBoundaryExtensionState {
        cachedRawBoundaryExtensionState
    }

    /// Pure compute: produces the raw boundary extension state from the
    /// current drag / creation source. Called ONLY from `.onChange` handlers
    /// (via `refreshCachedRawBoundaryExtensionState`); the body-scope reader
    /// reads the cache. (#77)
    private func computeRawBoundaryExtensionState() -> TimelineBoundaryExtensionState {
        let mappingState = computeBoundaryExtensionMappingState()
        let hours = computeRawBoundaryExtensionHours(mappingState: mappingState)
        let anchorOffset: Int? = {
            guard let date = mappingState?.anchorDate else { return nil }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let anchor = calendar.startOfDay(for: date)
            return calendar.dateComponents([.day], from: today, to: anchor).day
        }()
        return TimelineBoundaryExtensionState(
            leadingHours: hours.leading,
            trailingHours: hours.trailing,
            source: mappingState?.source,
            anchorDayOffset: anchorOffset
        )
    }

    /// Recompute the cached raw boundary extension state. Writes the new
    /// value only when it differs from the cache, so body re-evals at most
    /// once per actual transition (not per drag frame). (#77)
    private func refreshCachedRawBoundaryExtensionState() {
        let next = computeRawBoundaryExtensionState()
        if next != cachedRawBoundaryExtensionState {
            cachedRawBoundaryExtensionState = next
        }
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

    // MARK: Spec 07 — 48h-constant single-day window

    /// True when this pager should render the single-day 48h-constant band
    /// window (spec 07 §2A). Off in multi-day and when the flag is off.
    private var shouldUseExtendedBandWindow: Bool {
        useImperativeDayLayerModel && isSingleDay
    }

    /// The leading/trailing extension hours fed to RENDER-GEOMETRY derivations
    /// (slot count / frame height / day-layer Y math / axis labels). In the
    /// 48h-constant model these are pinned to 12/12 regardless of the real
    /// band open/close state — band visibility is the host's `contentInset`,
    /// not a content-size change. NOTE: occurrence SUPPLY
    /// (`occurrenceExtensionHoursForDrag`) deliberately keeps reading the REAL
    /// `boundaryExtensionHours` — the 48h occurrence window is a later slice
    /// (S1); S0 only changes geometry, so the band region stays empty and the
    /// band-hidden hit-test concern (spec 07 §7f) does not yet apply.
    private var renderBoundaryExtensionHours: (leading: Int, trailing: Int) {
        shouldUseExtendedBandWindow
            ? (leading: calendarTimelineMaximumBoundaryExtensionHours,
               trailing: calendarTimelineMaximumBoundaryExtensionHours)
            : boundaryExtensionHours
    }

    /// The window the day-layer DRAWS into (grid/labels/event clipping), kept
    /// separate from the coordinate hours. At rest = the real band (empty bands
    /// when closed). DURING a drag (`rawBoundaryExtensionState.source != nil`)
    /// = the FULL coordinate window, so the live-dragged event renders into the
    /// band without being clipped: the dragged event moves per-FRAME but the
    /// band/drawable state is EDGE-triggered and lags, so a downward cross-
    /// midnight drag would otherwise clip the block at 24:00 ("doesn't render
    /// live"). Identity off-path (renderBoundaryExtensionHours==boundaryHours).
    private var drawableExtensionHours: (leading: Int, trailing: Int) {
        // During a drag, key off the LATCHED (effective/override) band state, NOT
        // the raw per-frame state: a >24h event sits in BOTH anticipation zones,
        // so `raw` flips leading/trailing 12↔0 every frame, which would re-toggle
        // `drawable*` → per-frame `setBandInset` animation + a band-state
        // write↔re-read SwiftUI loop → host re-layout → the day-layer detaches
        // and `didMoveToWindow(nil)` CANCELS the in-flight drag (the grab→release
        // cycle). The latched state opens a side once on first crossing and holds
        // it for the drag, so `drawable*` stops oscillating. Off-path identity
        // (renderBoundaryExtensionHours == boundaryExtensionHours).
        guard rawBoundaryExtensionState.source != nil else { return boundaryExtensionHours }
        return (
            leading: effectiveBoundaryExtensionState.leadingHours > 0
                ? renderBoundaryExtensionHours.leading : boundaryExtensionHours.leading,
            trailing: effectiveBoundaryExtensionState.trailingHours > 0
                ? renderBoundaryExtensionHours.trailing : boundaryExtensionHours.trailing
        )
    }

    /// True when the all-day pill row is pinned to the scroll frame top by the
    /// host (spec 07 §4d, pulled early). Only when there are all-day events to
    /// pin — with none, the content top is already the leading band and the
    /// negative leading inset alone is correct (reviewer decision).
    private var pinsAllDayExternally: Bool {
        shouldUseExtendedBandWindow && allDayHeight > 0
    }

    /// All-day height as seen by the IN-SCROLL layout. Zero when the row is
    /// pinned externally, so the scrolled content no longer reserves the band
    /// and the day-layer's 0:00 anchor agrees with the host `contentInset`.
    private var effectiveAllDayHeight: CGFloat {
        pinsAllDayExternally ? 0 : allDayHeight
    }
    private var slotCount: Int {
        max(
            1,
            Int(
                CGFloat(
                    calendarTimelineTotalVisibleHours(
                        leadingExtendedHours: renderBoundaryExtensionHours.leading,
                        trailingExtendedHours: renderBoundaryExtensionHours.trailing
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
    private var totalHeight: CGFloat { effectiveAllDayHeight + timelineHeight }
    private var boundaryExtensionAnimation: Animation? {
        let isMoveDragActive = calendarIsMoveDragActive(
            draggingEventID: dragState.draggingEventID,
            dragMode: dragState.dragMode
        )
        let isCreationDragActive = !creationPreviewByDay.isEmpty
        guard calendarShouldAnimateTimelineBoundaryExtension(
            isMoveDragActive: isMoveDragActive,
            isCreationDragActive: isCreationDragActive,
            reduceMotion: accessibilityReduceMotion,
            isFollowEventActive: suppressDayColumnHorizontalAnimation
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

    /// Imperative latch for the #53 single-day proactive leading-extension
    /// trigger. The condition (scroll-pinned-at-top + finger dragging upward)
    /// used to be evaluated inside `rawBoundaryExtensionHours` by reading
    /// `dragState.dragOffset.y` directly. That made `TimelineView.body` an
    /// observer of `dragOffset`, so every drag-frame write to dragOffset
    /// invalidated body — the dominant residual SwiftUI cost on the CALayer
    /// renderer's drag path (#75 / #74's "Body-scope reader audit").
    ///
    /// The latch is set/cleared by an `.onChange(of: dragState.dragOffset.y)`
    /// handler scoped to the body modifier chain. The handler observes
    /// dragOffset there (which is fine — that observation does NOT register a
    /// body-level dependency), and `rawBoundaryExtensionHours` reads the
    /// latch instead. The result: drag-frame writes invalidate only the
    /// onChange site, not body. Cleared on drag end via the existing
    /// `dragState.draggingEventID` onChange.
    @State private var proactiveLeadingExtensionLatch: Bool = false

    /// Cached raw boundary-extension state (#77). Body reads this via
    /// `rawBoundaryExtensionState`; refreshed from `.onChange` handlers
    /// (`refreshCachedRawBoundaryExtensionState`) that watch every input
    /// the underlying compute reads (drag offset / drag session fields /
    /// hourHeight / proactive latch / creation source). Body re-evals only
    /// when this value actually changes — at most a couple of times per
    /// drag (when the mapped range crosses the midnight predicate) — not
    /// per drag frame. This breaks the `boundaryExtensionHours →
    /// boundaryExtensionMappingState → resolvedDragEditMapping →
    /// dragState.dragOffset` body-dependency edge that #76's latch did not
    /// reach.
    @State private var cachedRawBoundaryExtensionState: TimelineBoundaryExtensionState = .none

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

    /// Absorption-pulse trigger set: parents that were recently absorbed into,
    /// fed into every `CalendarDayLayerView` (drives spec 04 §4). Maintained at
    /// the pager level because the CALayer day view is injected here and we
    /// want a single owning set across all visible day columns.
    @State private var calayerRecentlyAbsorbedParents: Set<UUID> = []
    @EnvironmentObject private var calayerEventStore: EventStore

    private var resolvedCreationEditMapping: (date: Date, range: Event.TimeRange)? {
        calendarResolvedCreationEditMapping(
            creationPreviewByDay: creationPreviewByDay,
            selectedDayOffset: selectedDayOffset,
            pendingCreate: previewCreation
        )
    }

    private var resolvedDragEditMapping: (source: TimelineEditMappingSource, date: Date, range: Event.TimeRange)? {
        calendarResolvedDragEditMapping(
            draggingEventID: dragState.draggingEventID,
            draggingOriginalRange: dragState.draggingOriginalRange,
            dragOffset: dragState.dragOffset,
            dragMode: dragState.dragMode,
            dayColumnStep: dragState.dayColumnStep,
            hourHeight: hourHeight
        )
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
            // #55: visual offset cancels the leading-snap canvas-row jump so
            // dragged events stay glued to the finger. Driven by the
            // CADisplayLink animator in CalendarPageView, animates from
            // -delta → 0 over 0.28s in lockstep with scrollTo. Idle = 0.
            .offset(y: boundaryExtensionVisualYOffset)
            .animation(boundaryExtensionAnimation, value: boundaryExtensionHours.leading)
            .animation(boundaryExtensionAnimation, value: boundaryExtensionHours.trailing)
        }
        .frame(height: totalHeight, alignment: .top)
        .onAppear {
            // #77: seed the cached raw boundary state from the live compute so
            // first-render reads (`rawBoundaryExtensionState`, `boundaryExtensionHours`,
            // etc.) see the correct value rather than `.none` until the first
            // dragOffset change. Initial cache value `.none` is correct when no
            // drag / creation is active (the common case at appear), but if the
            // pager is re-shown mid-flow the live compute might already be
            // non-none.
            refreshCachedRawBoundaryExtensionState()
            onBoundaryExtensionStateChange?(rawBoundaryExtensionState)
        }
        .onChange(of: rawBoundaryExtensionState) { _, newValue in
            onBoundaryExtensionStateChange?(newValue)
        }
        .onReceive(calayerEventStore.calendarTodoAbsorbed) { parentID in
            // Mark the parent as recently-absorbed-into for the §4 pulse,
            // auto-clearing after the ~1.5s window so a later absorption into
            // the same parent re-fires.
            calayerRecentlyAbsorbedParents.insert(parentID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                calayerRecentlyAbsorbedParents.remove(parentID)
            }
        }
    }

    // MARK: - Time Axis

    /// Pre-resolves the focused-event tint color for `TimelineAxisDragOverlay`.
    /// Walks visible occurrences to find the focused event and returns its
    /// theme color. Reads `focusedEventID` + visible offsets + occurrencesForOffset
    /// from body scope — none of those depend on `dragState.dragOffset`, so
    /// these reads don't reintroduce a per-frame body dependency. (#77)
    private var resolvedFocusedEventColor: Color? {
        guard let focusedEventID else { return nil }
        let visibleOffsets = Array(visibleOffsetsRange(centeredRange: centeredOffsetsRange()))
        for offset in visibleOffsets {
            if let match = occurrencesForOffset(offset).first(where: { $0.event.id == focusedEventID }) {
                return CalendarLayout.eventColor(for: match.event)
            }
        }
        return nil
    }

    @ViewBuilder
    private func timeAxis() -> some View {
        // #77: extracted into a sub-view so the parent body no longer reads
        // `editMappingPresentation` (which transitively reads
        // `dragState.dragOffset` via `resolvedDragEditMapping`). The sub-view's
        // body still re-evaluates per drag frame — that compute can't be
        // elided, only relocated — but the parent's no longer does.
        TimelineAxisDragOverlay(
            useCALayerAxisMarkers: useCALayerAxisMarkers,
            allDayHeight: effectiveAllDayHeight,
            timelineHeight: timelineHeight,
            anchorDate: dayDate(forOffset: selectedDayOffset),
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            effectiveSlotMinutes: effectiveSlotMinutes,
            leadingExtendedHours: renderBoundaryExtensionHours.leading,
            trailingExtendedHours: renderBoundaryExtensionHours.trailing,
            drawableLeadingHours: drawableExtensionHours.leading,
            drawableTrailingHours: drawableExtensionHours.trailing,
            mode: mode,
            leadingFadeProgress: leadingFadeProgress,
            trailingFadeProgress: trailingFadeProgress,
            isSingleDay: isSingleDay,
            dragState: dragState,
            resolvedCreationEditMapping: resolvedCreationEditMapping,
            resolvedFocusedEditMapping: resolvedFocusedEditMapping,
            hasFocusedEvent: focusedEventID != nil,
            focusedEventColor: resolvedFocusedEventColor
        )
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
            let frozen = slotMinutes
            if rangePinchFrozenSlotMinutes != frozen {
                rangePinchFrozenSlotMinutes = frozen
                onFrozenSlotMinutesChange?(frozen)
            }
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
        if rangePinchFrozenSlotMinutes != nil {
            withAnimation(.easeInOut(duration: 0.3)) {
                rangePinchFrozenSlotMinutes = nil
            }
            onFrozenSlotMinutesChange?(nil)
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
                // #77: selectedDayOffset feeds resolvedCreationEditMapping →
                // boundary state. Refresh the cache so creation drags that
                // span a day pivot stay in sync.
                refreshCachedRawBoundaryExtensionState()
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
                if accessibilityReduceMotion || suppressDayColumnHorizontalAnimation {
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
                    // #77: refresh the cache BEFORE reading
                    // `boundaryExtensionHours` so the frozen snapshot reflects
                    // the new drag's starting state, not the previous drag's
                    // residue. The cache compute reads the live drag fields,
                    // so calling refresh here picks up whatever the new drag
                    // started from.
                    refreshCachedRawBoundaryExtensionState()
                    frozenOccurrenceExtensionLeading = boundaryExtensionHours.leading
                    frozenOccurrenceExtensionTrailing = boundaryExtensionHours.trailing
                }
                // Clear the proactive leading-extension latch when a drag
                // session ends or hands off, so a re-engaged drag starts
                // from a clean state. (#75)
                if newValue == nil {
                    proactiveLeadingExtensionLatch = false
                }
                // New drag sessions must start from a clean auto-scroll transition state.
                previousHorizontalAutoScrolling = dragState.isHorizontalAutoScrolling
                pendingSnapAfterAutoScrollStop = false
                if newValue != nil {
                    creationPreviewByDay.removeAll()
                }
                // #77: drag end / re-engage needs a cache refresh so the
                // boundary state collapses back to none (or re-opens for a
                // fresh drag) without waiting on a subsequent dragOffset
                // write.
                refreshCachedRawBoundaryExtensionState()
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
            .onChange(of: dragState.dragOffset) { _, newOffset in
                // Mirror of the #53 single-day proactive leading-extension
                // condition that USED to live inside `rawBoundaryExtensionHours`.
                // Moving the dragOffset.y read out here keeps `TimelineView.body`
                // from observing dragOffset directly, which would invalidate
                // body on every drag frame. The handler is a modifier closure —
                // its dragOffset observation does NOT register a body-level
                // dependency. (#75)
                updateProactiveLeadingExtensionLatch(dragOffsetY: newOffset.y)
                // Refresh the cached raw boundary extension state. The compute
                // reads `resolvedDragEditMapping` (which reads `dragOffset`);
                // doing it here keeps the read inside an onChange closure
                // instead of body. Cache writes only on actual transitions, so
                // body re-evals a couple of times per drag (predicate
                // boundary crossings) rather than every frame. (#77)
                refreshCachedRawBoundaryExtensionState()
            }
            // #77 — every input the boundary-state compute reads (besides
            // dragOffset, handled above; and proactive latch, handled by its
            // own onChange below) must trigger a cache refresh so body stays
            // in sync. These all change at discrete moments (drag begin/end,
            // mode flip, day step, hourHeight, creation drag), not per frame.
            .onChange(of: dragState.dragMode) { _, _ in
                refreshCachedRawBoundaryExtensionState()
            }
            .onChange(of: dragState.dayColumnStep) { _, _ in
                refreshCachedRawBoundaryExtensionState()
            }
            .onChange(of: hourHeight) { _, _ in
                refreshCachedRawBoundaryExtensionState()
            }
            .onChange(of: proactiveLeadingExtensionLatch) { _, _ in
                refreshCachedRawBoundaryExtensionState()
            }
            .onChange(of: creationPreviewByDay) { _, _ in
                refreshCachedRawBoundaryExtensionState()
            }
            .onChange(of: previewCreation?.id) { _, _ in
                refreshCachedRawBoundaryExtensionState()
            }
            .onChange(of: verticalScrollY) { _, _ in
                // If the scroll moves away from the top boundary while the
                // latch is set, clear it. `verticalScrollY` is a prop, so a
                // change here implies a parent re-init (body has already
                // re-evaluated anyway). This onChange is just to keep the
                // latch in sync with the scroll-pinned-at-top guard. (#75)
                updateProactiveLeadingExtensionLatch(dragOffsetY: dragState.dragOffset.y)
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
        if effectiveAllDayHeight > 0 {
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
            .frame(width: width, height: effectiveAllDayHeight, alignment: .top)
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

            buildDayLayerView(
                for: offset, date: date, dayWidth: width,
                dayColumnStep: columnStep, dragPreviewDayStep: previewDayStep,
                previewRange: previewRange,
                isFocusContextActive: isFocusContextActive,
                onHorizontalBoundaryPageRequest: onHorizontalBoundaryPageRequest
            )
        }
    }

    @ViewBuilder
    private func buildDayLayerView(
        for offset: Int,
        date: Date,
        dayWidth: CGFloat,
        dayColumnStep: CGFloat,
        dragPreviewDayStep: CGFloat,
        previewRange: Event.TimeRange?,
        isFocusContextActive: Bool,
        onHorizontalBoundaryPageRequest: ((Int) -> Bool)?
    ) -> some View {
        let dayOccurrences = CalendarLayout.timelineVisibleOccurrences(
            forDayOffset: offset,
            leadingExtendedHours: occurrenceExtensionHoursForDrag.leading,
            trailingExtendedHours: occurrenceExtensionHoursForDrag.trailing,
            occurrencesForOffset: occurrencesForOffset
        )

        // Full per-event visual fidelity + grid / chrome, pinch repaint, and
        // native UIKit gestures (move / resize / drag-to-create / edge-auto-
        // scroll / boundary-paging / absorption / tap / focus).
        CalendarDayLayerView(
            date: date,
            occurrences: dayOccurrences,
            contentWidth: dayWidth,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            eventHorizontalInset: eventHorizontalInset,
            leadingExtendedHours: renderBoundaryExtensionHours.leading,
            trailingExtendedHours: renderBoundaryExtensionHours.trailing,
            drawableLeadingHours: drawableExtensionHours.leading,
            drawableTrailingHours: drawableExtensionHours.trailing,
            useImperativeDayLayerModel: shouldUseExtendedBandWindow,
            showEventText: showEventText,
            isWeekMode: rangeMode == .week,
            isThreeDayMode: rangeMode == .threeDay,
            titleFontSizeSetting: calayerTitleFontSizeSetting,
            showTimeBelowTitle: calayerShowTimeBelowTitle,
            multiTypeEnabled: calayerMultiTypeEnabled,
            nearFutureHorizonDays: nearFutureHorizonDays,
            isPinchActive: isRangePinchActive,
            frozenSlotMinutes: rangePinchFrozenSlotMinutes,
            dayColumnStep: dayColumnStep,
            dragPreviewDayStep: dragPreviewDayStep,
            creationPreviewRange: previewRange,
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
            graceResizeEventID: graceResizeEventID,
            graceResizeOccurrenceID: graceResizeOccurrenceID,
            graceResizeHandleOpacity: graceResizeHandleOpacity,
            isFocusContextActive: isFocusContextActive,
            recentlyAbsorbedEventIDs: calayerRecentlyAbsorbedParents,
            dragState: dragState,
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
            onVisibleTimelineFrameChange: onVisibleTimelineFrameChange
        )
        .frame(width: dayWidth, height: timelineHeight, alignment: .top)
        .mask { extensionFadeMask() }
    }

    /// Alpha mask for the follow-event band fade: header + base 24h fully
    /// opaque, the extension band(s) at `1 - extensionFadeProgress`. The
    /// day-boundary hour line sits exactly on the band↔base seam and mask
    /// anti-aliasing would sample the 1pt line at ~50% alpha — so the base
    /// segment overhangs 2pt into each band side to keep the midnight line
    /// fully opaque while the band fades.
    @ViewBuilder
    private func extensionFadeMask() -> some View {
        // Spec 07: in the 48h-constant model the band content is ALWAYS present
        // (geometry uses `renderBoundaryExtensionHours` = 12/12), so the mask
        // must carve the fade region over it — otherwise there is no band frame
        // between header-white and base-white and the band edges read hard. On
        // the non-imperative path this == `boundaryExtensionHours`, unchanged.
        let leading = renderBoundaryExtensionHours.leading
        let trailing = renderBoundaryExtensionHours.trailing
        let boundaryBuffer: CGFloat = 2
        let leadingBuf: CGFloat = leading > 0 ? boundaryBuffer : 0
        let trailingBuf: CGFloat = trailing > 0 ? boundaryBuffer : 0
        VStack(spacing: 0) {
            Color.white.frame(height: headerHeight)
            if leading > 0 {
                Color.white
                    .frame(height: max(0, CGFloat(leading) * hourHeight - leadingBuf))
                    .opacity(1 - leadingFadeProgress)
            }
            Color.white.frame(
                height: CGFloat(calendarTimelineBaseVisibleHours) * hourHeight
                    + leadingBuf + trailingBuf
            )
            if trailing > 0 {
                Color.white
                    .frame(height: max(0, CGFloat(trailing) * hourHeight - trailingBuf))
                    .opacity(1 - trailingFadeProgress)
            }
            Color.white
        }
        // Fill the masked view's FULL width (not a fixed column width):
        // the time-axis labels are right-aligned and intrinsically wider
        // than the 26pt label column, so a leading-anchored fixed-width
        // mask clipped their right-side glyphs. maxWidth: .infinity makes
        // the white columns span whatever the masked bounds are — correct
        // for both the day columns and the axis. (#55 follow-on)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        if range.start < prevDayEnd {
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

// MARK: - Time Axis Drag Overlay

/// Sub-view that owns the per-drag-frame `editMappingPresentation` compute
/// + axis rendering. Extracted from `TimelinePagerView.timeAxis()` so that
/// `TimelinePagerView.body` no longer reads `dragState.dragOffset`
/// transitively (the read happens INSIDE this sub-view's body, which
/// re-evaluates per frame; the parent's does NOT).
///
/// Together with the `cachedRawBoundaryExtensionState` latch on the parent,
/// this is the structural completion of the #75 → #76 → #77 arc: with both
/// landed, the parent's `body` observes only discrete drag-session
/// transitions (`draggingEventID`, `dragMode`, …) instead of every drag-frame
/// `dragOffset` write. The per-frame cost survives — but it's bounded to this
/// small sub-view's body, not the entire `TimelinePagerView` body. (#77)
private struct TimelineAxisDragOverlay: View {
    // Static axis chrome inputs (mirror of `timeAxis()`'s call into
    // TimeAxisLayerHost / TimeAxisLabels).
    let useCALayerAxisMarkers: Bool
    let allDayHeight: CGFloat
    let timelineHeight: CGFloat
    let anchorDate: Date
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let effectiveSlotMinutes: Int
    let leadingExtendedHours: Int
    let trailingExtendedHours: Int
    /// Spec 07: REAL band window for which hour labels to DRAW (band regions
    /// render empty when closed); separate from the 12/12 coordinate hours.
    var drawableLeadingHours: Int = -1
    var drawableTrailingHours: Int = -1
    let mode: PageMode
    let leadingFadeProgress: CGFloat
    let trailingFadeProgress: CGFloat
    let isSingleDay: Bool

    // Mapping inputs. `dragState` is read for `dragOffset` etc. inside this
    // sub-view's body — that's the whole point of the extraction. The
    // creation / focused mappings are precomputed by the parent (they don't
    // depend on `dragOffset` so the parent computing them doesn't register
    // a parent-body dep).
    let dragState: EventDragState
    let resolvedCreationEditMapping: (date: Date, range: Event.TimeRange)?
    let resolvedFocusedEditMapping: (date: Date, range: Event.TimeRange)?
    /// Whether a focused event is currently selected — gates the focused-event
    /// color tint inside `editMappingPresentation`. Precomputed by parent.
    let hasFocusedEvent: Bool
    /// Pre-resolved focused-event tint color. Parent walks visible occurrences
    /// to find the focused event's theme color, so the sub-view doesn't have
    /// to take `occurrencesForOffset` + visible-offsets as input (which would
    /// pull in more parent state).
    let focusedEventColor: Color?

    private var resolvedDragEditMapping: (source: TimelineEditMappingSource, date: Date, range: Event.TimeRange)? {
        calendarResolvedDragEditMapping(
            draggingEventID: dragState.draggingEventID,
            draggingOriginalRange: dragState.draggingOriginalRange,
            dragOffset: dragState.dragOffset,
            dragMode: dragState.dragMode,
            dayColumnStep: dragState.dayColumnStep,
            hourHeight: hourHeight
        )
    }

    private var editMappingState: TimelineEditMappingState? {
        calendarResolveEditMappingState(
            creation: resolvedCreationEditMapping,
            drag: resolvedDragEditMapping,
            focused: resolvedFocusedEditMapping
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
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        ) else { return nil }

        // Use the event's theme color from drag state, focused state, or creation
        if let draggingEvent = dragState.draggingEvent {
            presentation.color = CalendarLayout.eventColor(for: draggingEvent)
        } else if hasFocusedEvent, let focusedEventColor {
            presentation.color = focusedEventColor
        } else if editMappingState?.source == .creation {
            presentation.color = calendarCurrentTimeIndicatorColor()
        }

        return presentation
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if allDayHeight > 0 {
                    Color.clear.frame(height: allDayHeight)
                }
                if useCALayerAxisMarkers {
                    TimeAxisLayerHost(
                        anchorDate: anchorDate,
                        headerHeight: headerHeight,
                        hourHeight: hourHeight,
                        slotMinutes: effectiveSlotMinutes,
                        leadingExtendedHours: leadingExtendedHours,
                        trailingExtendedHours: trailingExtendedHours,
                        drawableLeadingHours: drawableLeadingHours >= 0 ? drawableLeadingHours : leadingExtendedHours,
                        drawableTrailingHours: drawableTrailingHours >= 0 ? drawableTrailingHours : trailingExtendedHours,
                        mode: mode,
                        editMappingPresentation: editMappingPresentation,
                        leadingFadeProgress: leadingFadeProgress,
                        trailingFadeProgress: trailingFadeProgress,
                        isSingleDay: isSingleDay
                    )
                    .id(effectiveSlotMinutes)
                    .transition(.opacity)
                    .frame(height: timelineHeight, alignment: .top)
                } else {
                    TimeAxisLabels(
                        anchorDate: anchorDate,
                        headerHeight: headerHeight,
                        hourHeight: hourHeight,
                        slotMinutes: effectiveSlotMinutes,
                        leadingExtendedHours: leadingExtendedHours,
                        trailingExtendedHours: trailingExtendedHours,
                        drawableLeadingHours: drawableLeadingHours >= 0 ? drawableLeadingHours : leadingExtendedHours,
                        drawableTrailingHours: drawableTrailingHours >= 0 ? drawableTrailingHours : trailingExtendedHours,
                        mode: mode,
                        editMappingPresentation: editMappingPresentation,
                        leadingFadeProgress: leadingFadeProgress,
                        trailingFadeProgress: trailingFadeProgress,
                        isSingleDay: isSingleDay
                    )
                    .id(effectiveSlotMinutes)
                    .transition(.opacity)
                    .frame(height: timelineHeight, alignment: .top)
                }
            }
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
    /// Spec 07: REAL band window for which hour labels to draw (band regions
    /// empty when closed); separate from the 12/12 coordinate hours.
    var drawableLeadingHours: Int = -1
    var drawableTrailingHours: Int = -1
    let mode: PageMode
    var editMappingPresentation: TimelineAxisMarkerPresentation? = nil
    /// #55 follow-on: per-side band-fade opacity (0 = solid, 1 = transparent),
    /// applied ONLY to the hour-label column — axis markers + current-time
    /// legend stay fully opaque. Leading/trailing independent.
    var leadingFadeProgress: CGFloat = 0
    var trailingFadeProgress: CGFloat = 0
    /// Single-day-only: gates the current-time legend Text + the hour-label
    /// collision-hide. In single-day view, `anchorDate` is the displayed day;
    /// on non-today pages the now-line itself is already suppressed in the
    /// day column (CALayer `showsNow` check), but the axis kept showing the
    /// now-legend AND hiding the colliding hour label — leaving the user
    /// with a missing hour label and a stray "now" Text on yesterday /
    /// tomorrow. Multi-day shares one axis across N day columns where
    /// today is usually visible somewhere, so it keeps the legend on
    /// unconditionally (default false here preserves that).
    var isSingleDay: Bool = false

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
            // Single-day axis only shows the now-legend (and only hides the
            // colliding hour label) when this page IS today. Multi-day
            // always shows it — the legend points at today's row in the
            // shared 24h axis and today is usually within the visible
            // column range. Re-evaluated each tick so a midnight crossover
            // flips the gate naturally.
            let showsCurrentTime = !isSingleDay
                || Calendar.current.isDate(anchorDate, inSameDayAs: now)
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                    ForEach(0..<slotCount, id: \.self) { index in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 1)
                            .overlay(alignment: .trailing) {
                                // Hour label always renders its text; the
                                // collision-yield to the now-legend is an
                                // OPACITY (not an empty string) so a page
                                // switch can cross-fade the label back in
                                // sync with the legend fading out.
                                Text(label(forSlot: index))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.trailing, 2)
                                    .offset(y: -2)
                                    .opacity(hourLabelOpacity(
                                        forSlot: index, now: now,
                                        showsCurrentTime: showsCurrentTime
                                    ))
                            }
                            .frame(height: slotHeight, alignment: .top)
                    }
                }
                // Fade ONLY the hour labels with the leaving band. Markers +
                // now-legend (later ZStack children) are intentionally outside
                // this mask, so they stay fully opaque. (#55 follow-on)
                //
                // `alignment: .trailing` — the hour labels are right-aligned
                // `.fixedSize(horizontal: true)` Texts that bleed LEFT past
                // the 26pt axis column. A center-aligned mask sized to the
                // column clips that overflow even at full opacity (resting
                // state), dropping the leftmost glyph of e.g. "23:00".
                // Trailing-align an over-wide mask so the leftward bleed
                // stays inside it; no rightward extension into the day
                // column. (Single-day exposed this — column hugs the
                // screen edge with no slack.)
                .mask(alignment: .trailing) { bandFadeMask() }

                if showsCurrentTime {
                    Text(currentTimeText(for: now))
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundColor(calendarCurrentTimeIndicatorColor())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, 2)
                        .offset(y: currentTimeLegendYOffset(for: now))
                        .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.5)
                        .transition(.opacity)
                }

                if let editMappingPresentation {
                    axisMarkers(presentation: editMappingPresentation)
                }

            }
            // Soft cross-fade between "this page is today" and "this page
            // isn't" — the now-legend Text appears/disappears via
            // `.transition(.opacity)` and the yielding hour label flips its
            // opacity. Scoped to `showsCurrentTime` so the 1-Hz tick of
            // the parent TimelineView doesn't trigger spurious animations
            // (the value is stable for ~24h between midnight crossovers).
            .animation(.easeInOut(duration: 0.22), value: showsCurrentTime)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Alpha mask for the hour-label column during the follow-event band fade.
    /// header + base 24h opaque, extension band(s) at `1 - extensionFadeProgress`.
    /// Unlike the day-column mask (which protects a 1pt midnight LINE with a 2pt
    /// overhang), the axis carries a ~12pt-tall hour LABEL centred on the
    /// boundary line, so the base segment overhangs a half-label-height (8pt)
    /// into each band — keeping the midnight "0:00" label fully opaque while
    /// the band's interior hours fade. When `extensionFadeProgress == 0` the
    /// whole mask is opaque white → no effect (the resting state).
    @ViewBuilder
    private func bandFadeMask() -> some View {
        let buffer: CGFloat = 8
        let leadingBuf: CGFloat = leadingExtendedHours > 0 ? buffer : 0
        let trailingBuf: CGFloat = trailingExtendedHours > 0 ? buffer : 0
        // Explicit width overhangs the 26pt axis column so the right-aligned
        // hour labels' leftward overflow (`.fixedSize(horizontal: true)`)
        // stays inside the mask. Paired with `.mask(alignment: .trailing)`
        // at the call site, the overhang is purely leftward. Generous
        // enough for any 9pt-semibold hour text (~24pt natural width).
        let maskWidth: CGFloat = 80
        VStack(spacing: 0) {
            Color.white.frame(height: headerHeight)
            if leadingExtendedHours > 0 {
                Color.white
                    .frame(height: max(0, CGFloat(leadingExtendedHours) * hourHeight - leadingBuf))
                    .opacity(1 - leadingFadeProgress)
            }
            Color.white.frame(
                height: CGFloat(calendarTimelineBaseVisibleHours) * hourHeight
                    + leadingBuf + trailingBuf
            )
            if trailingExtendedHours > 0 {
                Color.white
                    .frame(height: max(0, CGFloat(trailingExtendedHours) * hourHeight - trailingBuf))
                    .opacity(1 - trailingFadeProgress)
            }
            Color.white
        }
        .frame(width: maskWidth, alignment: .topTrailing)
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
        // Wrap-around pair for a cross-midnight live range (#53 B follow-on).
        // Draws the SAME start/end texts at the OTHER day's column-anchored Y
        // positions, so the user gets a consistent pill pair whether scrolled
        // to the source-half view (column bottom) or the sibling-half view
        // (column top). Single-day events have nil wrapped fields → no-op.
        if let wrappedStartY = presentation.wrappedStartY,
           let wrappedEndY = presentation.wrappedEndY {
            axisMarkerRow(text: presentation.startText, y: wrappedStartY, color: presentation.color)
                .zIndex(2)
            axisMarkerRow(text: presentation.endText, y: wrappedEndY, color: presentation.color)
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

    private func label(forSlot index: Int) -> String {
        let totalMinutes = -leadingExtendedHours * 60 + index * slotMinutes
        // Spec 07: empty (no label) outside the REAL day window so band regions
        // stay empty when closed; positions unchanged. Identity when drawable
        // == coordinate hours (the -1 sentinel falls back to coordinate).
        let dL = drawableLeadingHours >= 0 ? drawableLeadingHours : leadingExtendedHours
        let dT = drawableTrailingHours >= 0 ? drawableTrailingHours : trailingExtendedHours
        if totalMinutes < -dL * 60 || totalMinutes > (calendarTimelineBaseVisibleHours + dT) * 60 {
            return ""
        }
        let normalizedTotalMinutes = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        let hour24 = normalizedTotalMinutes / 60
        let minute = normalizedTotalMinutes % 60

        guard minute == 0 else { return "" }
        if AppTimeFormat.current.is24 {
            return String(format: "%d:00", hour24)
        } else {
            let meridiem = hour24 < 12 ? "am" : "pm"
            let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
            return "\(hour12) \(meridiem)"
        }
    }

    /// Hour-label opacity: 1 unless the slot collides with the now-legend
    /// AND the now-legend is actually rendered (`showsCurrentTime`). On a
    /// page where the legend doesn't render there's nothing to yield to,
    /// so the colliding label stays visible. Driving the yield via opacity
    /// (vs. an empty string) lets a same-frame change to `showsCurrentTime`
    /// cross-fade the label back in step with the legend fading out.
    /// (#55: REAL signed offset for collision — a leading/trailing
    /// extension label sharing hour-of-day with `now` doesn't physically
    /// overlap on screen and stays visible.)
    private func hourLabelOpacity(forSlot index: Int, now: Date, showsCurrentTime: Bool) -> Double {
        guard showsCurrentTime else { return 1 }
        let totalMinutes = -leadingExtendedHours * 60 + index * slotMinutes
        let normalizedTotalMinutes = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        let minute = normalizedTotalMinutes % 60
        guard minute == 0 else { return 1 }
        return calendarShouldHideLegendHourLabel(
            legendTotalMinutes: totalMinutes,
            nowTotalMinutes: totalMinutesSinceMidnight(for: now),
            hourHeight: hourHeight
        ) ? 0 : 1
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
