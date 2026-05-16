//
//  EventBlock.swift
//  Done
//
//  Unified event block component for timeline display.
//

import SwiftUI
import UIKit

private let resizeMinHeight: CGFloat = 32

enum CalendarResizeHandleEdge {
    case top
    case bottom
}

struct CalendarResizeHandlePlacement: Equatable {
    let centerX: CGFloat
    let width: CGFloat
    let availableWidth: CGFloat
}

let calendarHorizontalAutoScrollEdgeInsetDefault: CGFloat = 32
let calendarVerticalAutoScrollEdgeInsetDefault: CGFloat = 192
let calendarMaxAutoScrollSpeedDefault: CGFloat = 1200
let calendarAutoScrollCurveExponent: CGFloat = 1.5

/// Determines the drag mode based on touch position within an event block.
/// Resize only triggers when touching near the handle capsule (vertically AND horizontally).
func calendarResolveDragMode(
    locationX: CGFloat,
    locationY: CGFloat,
    viewWidth: CGFloat,
    viewHeight: CGFloat,
    edgeThreshold: CGFloat,
    canResizeTop: Bool,
    canResizeBottom: Bool,
    topHandlePlacement: CalendarResizeHandlePlacement? = nil,
    bottomHandlePlacement: CalendarResizeHandlePlacement? = nil
) -> EventDragMode {
    // Block too small for resize — move only
    guard viewHeight >= resizeMinHeight else { return .move }

    let scaledThreshold = min(edgeThreshold, max(8, viewHeight * 0.2))
    let inTopEdge = locationY < scaledThreshold && canResizeTop
    let inBottomEdge = locationY > viewHeight - scaledThreshold && canResizeBottom
    guard inTopEdge || inBottomEdge else { return .move }

    // Handle capsule: centered, width = min(viewWidth * 0.4, 36).
    // Expand hit zone by 12pt on each side for comfortable tapping.
    let placement = inTopEdge ? topHandlePlacement : bottomHandlePlacement
    let handleWidth = placement?.width ?? min(viewWidth * 0.4, 36)
    let handleMargin: CGFloat = 12
    let centerX = placement?.centerX ?? (viewWidth / 2)
    let hitLeft = centerX - handleWidth / 2 - handleMargin
    let hitRight = centerX + handleWidth / 2 + handleMargin
    guard locationX >= hitLeft && locationX <= hitRight else { return .move }

    return inTopEdge ? .resizeTop : .resizeBottom
}

// Extracted for regression tests: computes edge auto-scroll velocity for one axis.
/// Minimum distance from viewport edge where auto-scroll reaches max speed.
/// Keeps the finger away from the system gesture zones (notification center
/// at top, home indicator at bottom).
let calendarAutoScrollSafeMargin: CGFloat = 80

func calendarAutoScrollVelocity(
    locationInViewport: CGFloat,
    viewportLength: CGFloat,
    currentOffset: CGFloat,
    minOffset: CGFloat,
    maxOffset: CGFloat,
    edgeInset: CGFloat,
    maxSpeed: CGFloat
) -> CGFloat {
    guard viewportLength > 0 else { return 0 }

    let effectiveInset = min(max(edgeInset, 0), viewportLength * 0.48)
    guard effectiveInset > 0 else { return 0 }

    var velocity: CGFloat = 0
    // Past the safe margin → max speed immediately so the user never
    // needs to push into the system gesture zone (notification center /
    // home indicator).
    if locationInViewport < calendarAutoScrollSafeMargin {
        velocity = -maxSpeed
    } else if locationInViewport > viewportLength - calendarAutoScrollSafeMargin {
        velocity = maxSpeed
    } else if locationInViewport < effectiveInset {
        let progress = min(1, max(0, (effectiveInset - locationInViewport) / effectiveInset))
        let scaledProgress = CGFloat(pow(Double(progress), Double(calendarAutoScrollCurveExponent)))
        velocity = -maxSpeed * scaledProgress
    } else if locationInViewport > viewportLength - effectiveInset {
        let progress = min(1, max(0, (locationInViewport - (viewportLength - effectiveInset)) / effectiveInset))
        let scaledProgress = CGFloat(pow(Double(progress), Double(calendarAutoScrollCurveExponent)))
        velocity = maxSpeed * scaledProgress
    }

    // When content fits entirely in the viewport (maxOffset ≈ minOffset),
    // still allow velocity so boundary extension can open and grow the
    // scrollable content.  The scroll view will clamp naturally.
    if maxOffset - minOffset > 1 {
        let atMin = currentOffset <= minOffset + 0.5
        let atMax = currentOffset >= maxOffset - 0.5
        if (atMin && velocity < 0) || (atMax && velocity > 0) {
            return 0
        }
    }

    return velocity
}

// Extracted for regression tests: continuous horizontal auto-scroll delta.
func calendarHorizontalAutoScrollDelta(
    velocityX: CGFloat,
    deltaTime: CFTimeInterval
) -> CGFloat {
    velocityX * CGFloat(max(deltaTime, 0))
}

// Extracted for regression tests: drag X/Y should compose finger delta with
// explicit auto-scroll compensation only (never implicit scroll offset jumps).
func calendarComposedDragOffset(
    fingerDelta: DragOffset,
    autoScrollCompensation: DragOffset
) -> DragOffset {
    DragOffset(
        x: fingerDelta.x + autoScrollCompensation.x,
        y: fingerDelta.y + autoScrollCompensation.y
    )
}

// Extracted for regression tests: single-day boundary paging should add the
// committed page turns on top of the finger's local X within the current page,
// instead of double-counting the first crossed page like auto-scroll compensation.
func calendarBoundaryPagedHorizontalDragOffset(
    localOffsetX: CGFloat,
    pageCount: Int,
    dayStep: CGFloat
) -> CGFloat {
    guard dayStep > 0 else { return localOffsetX }
    return CGFloat(pageCount) * dayStep + localOffsetX
}

// Extracted for regression tests: multi-day move drag can follow the finger
// horizontally, but single-day paging keeps the source block pinned in-column.
func calendarMoveOffsetX(
    rawOffsetX: CGFloat,
    dayColumnStep: CGFloat,
    suppressSnap: Bool
) -> CGFloat {
    guard dayColumnStep > 0 else { return 0 }
    guard !suppressSnap else { return rawOffsetX }
    let snappedDayOffset = calendarDayOffsetFromHorizontalDrag(
        offsetX: rawOffsetX,
        dayColumnStep: dayColumnStep
    )
    return CGFloat(snappedDayOffset) * dayColumnStep
}

// Extracted for regression tests: edge-zone detection for auto-scroll.
func calendarIsInAutoScrollEdgeZone(
    locationInViewport: CGFloat,
    viewportLength: CGFloat,
    edgeInset: CGFloat
) -> Bool {
    guard viewportLength > 0 else { return false }
    let effectiveInset = min(max(edgeInset, 0), viewportLength * 0.48)
    guard effectiveInset > 0 else { return false }
    return locationInViewport < effectiveInset || locationInViewport > viewportLength - effectiveInset
}

// Extracted for regression tests: resolve edge-zone paging direction for single-day mode.
func calendarHorizontalBoundaryPageDirection(
    locationInViewport: CGFloat,
    viewportLength: CGFloat,
    edgeInset: CGFloat
) -> Int {
    guard viewportLength > 0 else { return 0 }
    let effectiveInset = min(max(edgeInset, 0), viewportLength * 0.48)
    guard effectiveInset > 0 else { return 0 }
    if locationInViewport < effectiveInset { return -1 }
    if locationInViewport > viewportLength - effectiveInset { return 1 }
    return 0
}

// Extracted for regression tests: resolve drag offset at gesture source so the
// shared drag preview follows the same live finger delta as the active block.
func calendarResolvedDragOffset(
    rawOffset: DragOffset,
    dragMode: EventDragMode,
    dayColumnStep: CGFloat,
    suppressHorizontalSnap: Bool
) -> DragOffset {
    guard dragMode == .move else {
        return DragOffset(x: 0, y: rawOffset.y)
    }

    let resolvedX = calendarMoveOffsetX(
        rawOffsetX: rawOffset.x,
        dayColumnStep: dayColumnStep,
        suppressSnap: suppressHorizontalSnap
    )
    return DragOffset(x: resolvedX, y: rawOffset.y)
}

// Extracted for regression tests: clamp move drag to the currently visible
// extended timeline window so the event cannot be dragged past the live bounds.
func calendarClampedMoveDragOffsetY(
    rawOffsetY: CGFloat,
    dragMode: EventDragMode,
    verticalDragBounds: ClosedRange<CGFloat>
) -> CGFloat {
    guard dragMode == .move else { return rawOffsetY }
    return min(max(rawOffsetY, verticalDragBounds.lowerBound), verticalDragBounds.upperBound)
}

/// Event block style configuration
struct EventBlockStyle: Equatable {
    let showTimeRange: Bool

    var fillOpacity: Double { 0.4 }
    var strokeOpacity: Double { 0.7 }
    var strokeWidth: CGFloat { 1.2 }

    static let edit = EventBlockStyle(showTimeRange: true)
    static let preview = EventBlockStyle(showTimeRange: false)
}

enum EventBlockInterruptVisualMode: Equatable {
    case none
    case embeddedMoat
}

func calendarInterruptVisualMode(
    isInterruptEvent: Bool,
    relationState: EventInterruptRelationState?,
    isCurrentlyEmbedded: Bool,
    hasParentColor: Bool
) -> EventBlockInterruptVisualMode {
    guard isInterruptEvent else { return .none }
    if isCurrentlyEmbedded && hasParentColor {
        return .embeddedMoat
    }
    return .none
}

func calendarInterruptMoatWidthHorizontal(
    availableWidth: CGFloat,
    availableHeight: CGFloat
) -> CGFloat {
    3
}

func calendarInterruptMoatWidthVertical(
    availableWidth: CGFloat,
    availableHeight: CGFloat
) -> CGFloat {
    2
}

struct CalendarInterruptOverlayGeometry: Equatable {
    let width: CGFloat
    let xOffset: CGFloat
}

func calendarInterruptOverlayGeometry(parentWidth: CGFloat) -> CalendarInterruptOverlayGeometry {
    guard parentWidth > 0 else {
        return CalendarInterruptOverlayGeometry(width: 0, xOffset: 0)
    }
    let leadingInset: CGFloat = 8
    let width = max(0, parentWidth - leadingInset)
    let xOffset = min(leadingInset, parentWidth)
    return CalendarInterruptOverlayGeometry(width: width, xOffset: xOffset)
}

func calendarInterruptChildOverlayGeometry(parentWidth: CGFloat) -> CalendarInterruptOverlayGeometry {
    calendarInterruptOverlayGeometry(parentWidth: parentWidth)
}

func calendarInterruptCutoutGeometry(
    parentWidth: CGFloat,
    moatWidth: CGFloat
) -> CalendarInterruptOverlayGeometry {
    let childOverlay = calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
    let xOffset = max(0, childOverlay.xOffset - moatWidth)
    return CalendarInterruptOverlayGeometry(
        width: max(0, parentWidth - xOffset),
        xOffset: xOffset
    )
}

struct CalendarInterruptCompoundCutoutGeometry: Equatable {
    let rect: CGRect
    let hasTopLobe: Bool
    let hasBottomLobe: Bool
}

struct CalendarInterruptParentVisibleSegment: Equatable {
    let yStart: CGFloat
    let yEnd: CGFloat
    let width: CGFloat
}

struct CalendarInterruptParentCompoundGeometry: Equatable {
    let cutouts: [CalendarInterruptCompoundCutoutGeometry]
    let spineRect: CGRect
    let visibleSegments: [CalendarInterruptParentVisibleSegment]
    let contentRects: [CGRect]

    var isStandaloneSpine: Bool {
        cutouts.count == 1 && !cutouts[0].hasTopLobe && !cutouts[0].hasBottomLobe
    }
}

struct CalendarEventTextLayout: Equatable {
    let contentRect: CGRect
    let titleLineLimit: Int
    let showsTimeRange: Bool
    let verticalCenter: Bool
    let isWeekMode: Bool
    let isThreeDayMode: Bool
}

func calendarInterruptMergedRanges(
    parentRange: Event.TimeRange,
    childRanges: [Event.TimeRange]
) -> [Event.TimeRange] {
    let clipped = childRanges.compactMap { childRange -> Event.TimeRange? in
        let start = max(parentRange.start, childRange.start)
        let end = min(parentRange.end, childRange.end)
        guard end > start else { return nil }
        return Event.TimeRange(start: start, end: end)
    }
    .sorted { lhs, rhs in
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }

    guard !clipped.isEmpty else { return [] }
    var merged: [Event.TimeRange] = [clipped[0]]
    for range in clipped.dropFirst() {
        let lastIndex = merged.index(before: merged.endIndex)
        if range.start <= merged[lastIndex].end {
            merged[lastIndex].end = max(merged[lastIndex].end, range.end)
        } else {
            merged.append(range)
        }
    }
    return merged
}

func calendarInterruptParentCompoundGeometry(
    parentRange: Event.TimeRange,
    childRanges: [Event.TimeRange],
    parentWidth: CGFloat,
    parentHeight: CGFloat,
    horizontalGap: CGFloat,
    verticalGap: CGFloat
) -> CalendarInterruptParentCompoundGeometry {
    guard parentWidth > 0, parentHeight > 0 else {
        return CalendarInterruptParentCompoundGeometry(
            cutouts: [],
            spineRect: .zero,
            visibleSegments: [],
            contentRects: []
        )
    }

    let mergedRanges = calendarInterruptMergedRanges(
        parentRange: parentRange,
        childRanges: childRanges
    )
    let totalDuration = max(parentRange.end.timeIntervalSince(parentRange.start), 1)
    let cutoutGeometry = calendarInterruptCutoutGeometry(
        parentWidth: parentWidth,
        moatWidth: horizontalGap
    )

    let rawRects = mergedRanges.compactMap { range -> CGRect? in
        let topProgress = range.start.timeIntervalSince(parentRange.start) / totalDuration
        let segmentProgress = range.end.timeIntervalSince(range.start) / totalDuration
        let rawTop = parentHeight * CGFloat(topProgress) - verticalGap
        let top = max(0, rawTop)
        let rawHeight = parentHeight * CGFloat(segmentProgress) + verticalGap * 2
        let height = min(
            max(verticalGap * 2 + 2, rawHeight),
            max(0, parentHeight - top)
        )
        guard height > 0 else { return nil }
        return CGRect(
            x: cutoutGeometry.xOffset,
            y: top,
            width: cutoutGeometry.width,
            height: height
        )
    }
    .sorted { lhs, rhs in
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        return lhs.maxY < rhs.maxY
    }

    let mergedRects: [CGRect] = rawRects.reduce(into: []) { partialResult, rect in
        guard let last = partialResult.last else {
            partialResult.append(rect)
            return
        }
        if rect.minY <= last.maxY {
            let mergedRect = CGRect(
                x: last.minX,
                y: last.minY,
                width: last.width,
                height: max(last.maxY, rect.maxY) - last.minY
            )
            partialResult[partialResult.count - 1] = mergedRect
        } else {
            partialResult.append(rect)
        }
    }

    let cutouts = mergedRects.map { rect in
        CalendarInterruptCompoundCutoutGeometry(
            rect: rect,
            hasTopLobe: rect.minY > 0.5,
            hasBottomLobe: rect.maxY < parentHeight - 0.5
        )
    }

    let fullWidth = parentWidth
    let spineWidth = max(0, cutoutGeometry.xOffset)
    var visibleSegments: [CalendarInterruptParentVisibleSegment] = []
    var currentY: CGFloat = 0

    for rect in mergedRects {
        if rect.minY > currentY + 0.5 {
            visibleSegments.append(
                CalendarInterruptParentVisibleSegment(
                    yStart: currentY,
                    yEnd: rect.minY,
                    width: fullWidth
                )
            )
        }
        if rect.maxY > rect.minY + 0.5 {
            visibleSegments.append(
                CalendarInterruptParentVisibleSegment(
                    yStart: rect.minY,
                    yEnd: rect.maxY,
                    width: spineWidth
                )
            )
        }
        currentY = rect.maxY
    }

    if currentY < parentHeight - 0.5 {
        visibleSegments.append(
            CalendarInterruptParentVisibleSegment(
                yStart: currentY,
                yEnd: parentHeight,
                width: fullWidth
            )
        )
    }

    if visibleSegments.isEmpty {
        visibleSegments = [
            CalendarInterruptParentVisibleSegment(
                yStart: 0,
                yEnd: parentHeight,
                width: fullWidth
            )
        ]
    }

    let normalizedVisibleSegments: [CalendarInterruptParentVisibleSegment] = visibleSegments.reduce(into: []) { partialResult, segment in
        guard segment.yEnd > segment.yStart else { return }
        guard let last = partialResult.last else {
            partialResult.append(segment)
            return
        }
        if abs(last.width - segment.width) < 0.5,
           abs(last.yEnd - segment.yStart) < 0.5 {
            partialResult[partialResult.count - 1] = CalendarInterruptParentVisibleSegment(
                yStart: last.yStart,
                yEnd: segment.yEnd,
                width: last.width
            )
        } else {
            partialResult.append(segment)
        }
    }

    let contentRects = normalizedVisibleSegments.map {
        CGRect(
            x: 0,
            y: $0.yStart,
            width: $0.width,
            height: $0.yEnd - $0.yStart
        )
    }

    return CalendarInterruptParentCompoundGeometry(
        cutouts: cutouts,
        spineRect: CGRect(
            x: 0,
            y: 0,
            width: max(0, cutoutGeometry.xOffset),
            height: parentHeight
        ),
        visibleSegments: normalizedVisibleSegments,
        contentRects: contentRects
    )
}

/// Augments a base compound geometry's visible segments with stack-peek
/// cover bands. Cover ranges (absolute dates) are projected to the parent's
/// y axis and intersected with each existing segment; intersections shrink
/// to `peekStripWidth` so text won't render where a higher-depth sibling is
/// painted on top. Cutouts and spineRect are passed through unchanged so
/// the parent's silhouette (used for shape clipping and hit-testing) is
/// unaffected — only the text-fitting `contentRects` reflect the covers.
///
/// Returns nil only when neither covers nor base geometry contribute
/// anything (no rect to measure against).
func calendarStackPeekTextGeometry(
    baseGeometry: CalendarInterruptParentCompoundGeometry?,
    eventRange: Event.TimeRange,
    coverRanges: [Event.TimeRange],
    parentWidth: CGFloat,
    parentHeight: CGFloat,
    peekStripWidth: CGFloat
) -> CalendarInterruptParentCompoundGeometry? {
    guard parentWidth > 0, parentHeight > 0 else { return baseGeometry }
    if coverRanges.isEmpty { return baseGeometry }

    let totalDuration = max(eventRange.end.timeIntervalSince(eventRange.start), 1)

    // Project covers to y-bands clipped to [0, parentHeight].
    let coverBands: [(yStart: CGFloat, yEnd: CGFloat)] = coverRanges.compactMap { range in
        let startProgress = max(0, range.start.timeIntervalSince(eventRange.start)) / totalDuration
        let endProgressRaw = range.end.timeIntervalSince(eventRange.start) / totalDuration
        let endProgress = min(1, endProgressRaw)
        guard endProgress > startProgress else { return nil }
        let yStart = parentHeight * CGFloat(startProgress)
        let yEnd = parentHeight * CGFloat(endProgress)
        guard yEnd > yStart + 0.5 else { return nil }
        return (yStart, yEnd)
    }
    .sorted { $0.yStart < $1.yStart }

    if coverBands.isEmpty { return baseGeometry }

    // Start from base visible segments, or a single full-rect segment if no
    // base. The full-rect fallback matches the convention used at the end
    // of `calendarInterruptParentCompoundGeometry` for empty-cutout cases.
    let baseSegments: [CalendarInterruptParentVisibleSegment] = baseGeometry?.visibleSegments ?? [
        CalendarInterruptParentVisibleSegment(yStart: 0, yEnd: parentHeight, width: parentWidth)
    ]
    let clampedStripWidth = max(0, min(peekStripWidth, parentWidth))

    var newSegments: [CalendarInterruptParentVisibleSegment] = []
    for segment in baseSegments {
        // Cover bands intersected with this segment's y span
        let intersections: [(CGFloat, CGFloat)] = coverBands.compactMap { band in
            let yStart = max(band.yStart, segment.yStart)
            let yEnd = min(band.yEnd, segment.yEnd)
            return yEnd > yStart + 0.5 ? (yStart, yEnd) : nil
        }
        if intersections.isEmpty {
            newSegments.append(segment)
            continue
        }
        var cursor = segment.yStart
        for (bandStart, bandEnd) in intersections {
            if bandStart > cursor + 0.5 {
                newSegments.append(CalendarInterruptParentVisibleSegment(
                    yStart: cursor,
                    yEnd: bandStart,
                    width: segment.width
                ))
            }
            // Cover band: width drops to min of current and strip width.
            // For an interrupt-parent spine (already narrow), this is a
            // no-op when the spine is already smaller than the strip.
            newSegments.append(CalendarInterruptParentVisibleSegment(
                yStart: bandStart,
                yEnd: bandEnd,
                width: min(segment.width, clampedStripWidth)
            ))
            cursor = bandEnd
        }
        if cursor < segment.yEnd - 0.5 {
            newSegments.append(CalendarInterruptParentVisibleSegment(
                yStart: cursor,
                yEnd: segment.yEnd,
                width: segment.width
            ))
        }
    }

    // Merge adjacent segments with identical width to keep the list compact.
    let merged: [CalendarInterruptParentVisibleSegment] = newSegments.reduce(into: []) { acc, seg in
        guard seg.yEnd > seg.yStart else { return }
        guard let last = acc.last else { acc.append(seg); return }
        if abs(last.width - seg.width) < 0.5,
           abs(last.yEnd - seg.yStart) < 0.5 {
            acc[acc.count - 1] = CalendarInterruptParentVisibleSegment(
                yStart: last.yStart,
                yEnd: seg.yEnd,
                width: last.width
            )
        } else {
            acc.append(seg)
        }
    }

    let contentRects = merged.map { seg in
        CGRect(x: 0, y: seg.yStart, width: seg.width, height: seg.yEnd - seg.yStart)
    }

    return CalendarInterruptParentCompoundGeometry(
        cutouts: baseGeometry?.cutouts ?? [],
        spineRect: baseGeometry?.spineRect ?? .zero,
        visibleSegments: merged,
        contentRects: contentRects
    )
}

/// Default title font size when the user has not set one. Matches the
/// historical hard-coded value so existing users see no visual change.
let calendarEventTitleFontSizeDefault: CGFloat = 12

/// Time-range font size paired with a given title font size. Keeps the
/// historical 12->8 (or 12->7 in week mode) ratio, with a hard floor at
/// 7pt so the time line stays legible at small title sizes.
func calendarEventTimeFontSize(forTitleFontSize titleFontSize: CGFloat, isWeekMode: Bool) -> CGFloat {
    let ratio: CGFloat = isWeekMode ? (7.0 / 12.0) : (8.0 / 12.0)
    return max(7, (titleFontSize * ratio).rounded())
}

/// Insets used inside an event block to position the title/time stack
/// inside the block's outer rectangle. Shared by `EventBlock` (real
/// events) and the drag-to-create / cross-day-drag preview blocks in
/// `TimelineView` so all four render paths stay pixel-aligned.
struct CalendarEventBlockInsets {
    let leading: CGFloat
    let trailing: CGFloat
    let vertical: CGFloat
}

func calendarEventBlockInsets(isWeekMode: Bool, isThreeDayMode: Bool) -> CalendarEventBlockInsets {
    let compact = isWeekMode || isThreeDayMode
    return CalendarEventBlockInsets(
        leading: compact ? 6 : 12,
        trailing: compact ? 4 : 8,
        vertical: compact ? 4 : 8
    )
}

/// Vertical spacing between title and the row beneath it (multi-type
/// subtitle or time range) inside an event block. Shared by the real
/// block and all preview render paths. Tight by design — title and
/// time should read as one unit, not two stacked rows.
func calendarEventBlockTitleSpacing(isWeekMode: Bool, isThreeDayMode: Bool) -> CGFloat {
    let compact = isWeekMode || isThreeDayMode
    return compact ? 1 : 2
}

func calendarEventTextLayout(
    in bounds: CGRect,
    title: String,
    requireTitleFit: Bool,
    styleShowTimeRange: Bool,
    isWeekMode: Bool = false,
    isThreeDayMode: Bool = false,
    baseFontSize: CGFloat = calendarEventTitleFontSizeDefault,
    showTimeBelowTitle: Bool = false
) -> CalendarEventTextLayout? {
    guard bounds.width >= 28, bounds.height >= 16 else {
        return nil
    }

    let insets = calendarEventBlockInsets(isWeekMode: isWeekMode, isThreeDayMode: isThreeDayMode)
    let leftInset = insets.leading
    let rightInset = insets.trailing
    let verticalInset = insets.vertical
    let titleFontHeight = UIFont.systemFont(ofSize: baseFontSize, weight: .semibold).lineHeight
    let needsCenter = bounds.height < verticalInset * 2 + titleFontHeight
    let contentRect = CGRect(
        x: bounds.minX + leftInset,
        y: needsCenter ? bounds.minY : bounds.minY + verticalInset,
        width: bounds.width - leftInset - rightInset,
        height: needsCenter ? bounds.height : bounds.height - verticalInset * 2
    )
    guard contentRect.width > 0, contentRect.height > 0 else {
        return nil
    }

    let titleLineLimit: Int = {
        if bounds.width < 48 {
            return bounds.height >= 40 ? 3 : (bounds.height >= 28 ? 2 : 1)
        }
        return 2
    }()
    let titleFontSize: CGFloat = baseFontSize
    let timeFontSize = calendarEventTimeFontSize(forTitleFontSize: titleFontSize, isWeekMode: isWeekMode)
    let spacing = calendarEventBlockTitleSpacing(isWeekMode: isWeekMode, isThreeDayMode: isThreeDayMode)
    // When `showTimeBelowTitle` is on, drop the legacy 88x42 hard gate
    // and let `titleFits(showsTime: true)` decide — this lets shorter
    // blocks display the time row whenever it geometrically fits beneath
    // the title. The 48pt width floor keeps "Mon" / single-letter
    // truncation ugliness away. When off, preserve historical behavior.
    // When the user opts in via `showTimeBelowTitle`, we override the
    // style-level `showTimeRange` gate. The historical model only flipped
    // that flag on for the focused event (`.edit` style); unfocused
    // events used `.preview` and never showed time. The setting is the
    // user explicitly asking to see time on every event, so style is
    // bypassed and only geometry decides. When the setting is off,
    // legacy behavior is preserved.
    var showsTimeRange: Bool = {
        if showTimeBelowTitle {
            let timeFontHeight = UIFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium).lineHeight
            let minHeightForTime = (needsCenter ? 0 : verticalInset * 2) + titleFontHeight + spacing + timeFontHeight
            return bounds.width >= 48 && bounds.height >= minHeightForTime
        }
        guard styleShowTimeRange else { return false }
        return bounds.width >= 88 && bounds.height >= 42
    }()

    func titleFits(showsTime: Bool) -> Bool {
        let titleFont = UIFont.systemFont(ofSize: titleFontSize, weight: .semibold)
        let timeHeight = showsTime
            ? (UIFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium).lineHeight + spacing)
            : 0
        let availableTitleHeight = contentRect.height - timeHeight
        guard availableTitleHeight >= titleFont.lineHeight else {
            return false
        }
        let titleBounds = (title as NSString).boundingRect(
            with: CGSize(width: contentRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont],
            context: nil
        )
        let allowedTitleHeight = min(
            availableTitleHeight,
            titleFont.lineHeight * CGFloat(titleLineLimit)
        )
        return titleBounds.height <= allowedTitleHeight + 0.5
    }

    // Drop the time row whenever including it would force the title to
    // clip. This runs in two cases:
    //   1. The interrupt-parent fallback path (`requireTitleFit`) — used
    //      when picking which lobe of a cutout block holds the text.
    //   2. The user-opt-in `showTimeBelowTitle` setting — better to read
    //      the full title than to fit a time at the cost of a clipped
    //      title.
    // Legacy non-opt-in renders skip this check entirely so historical
    // 88x42-gated layouts keep their original look.
    if (requireTitleFit || showTimeBelowTitle) && showsTimeRange && !titleFits(showsTime: true) {
        showsTimeRange = false
    }

    if requireTitleFit {
        guard titleFits(showsTime: showsTimeRange) else {
            return nil
        }
    }

    return CalendarEventTextLayout(
        contentRect: contentRect,
        titleLineLimit: titleLineLimit,
        showsTimeRange: showsTimeRange,
        verticalCenter: needsCenter,
        isWeekMode: isWeekMode,
        isThreeDayMode: isThreeDayMode
    )
}

func calendarInterruptParentTextLayout(
    geometry: CalendarInterruptParentCompoundGeometry,
    title: String,
    styleShowTimeRange: Bool,
    isWeekMode: Bool = false,
    isThreeDayMode: Bool = false,
    baseFontSize: CGFloat = calendarEventTitleFontSizeDefault,
    showTimeBelowTitle: Bool = false
) -> CalendarEventTextLayout? {
    if let preferredTopLayout = geometry.contentRects
        .sorted(by: { $0.minY < $1.minY })
        .compactMap({
            calendarEventTextLayout(
                in: $0,
                title: title,
                requireTitleFit: true,
                styleShowTimeRange: styleShowTimeRange,
                isWeekMode: isWeekMode,
                isThreeDayMode: isThreeDayMode,
                baseFontSize: baseFontSize,
                showTimeBelowTitle: showTimeBelowTitle
            )
        })
        .first {
        return preferredTopLayout
    }

    return geometry.contentRects
        .sorted { lhs, rhs in
            let lhsArea = lhs.width * lhs.height
            let rhsArea = rhs.width * rhs.height
            if abs(lhsArea - rhsArea) > 0.5 {
                return lhsArea > rhsArea
            }
            if abs(lhs.minY - rhs.minY) > 0.5 {
                return lhs.minY < rhs.minY
            }
            return lhs.width > rhs.width
        }
        .compactMap {
            calendarEventTextLayout(
                in: $0,
                title: title,
                requireTitleFit: false,
                styleShowTimeRange: styleShowTimeRange,
                isWeekMode: isWeekMode,
                isThreeDayMode: isThreeDayMode,
                baseFontSize: baseFontSize,
                showTimeBelowTitle: showTimeBelowTitle
            )
        }
        .first
}

func calendarResizeHandlePlacement(
    viewWidth: CGFloat,
    compoundGeometry: CalendarInterruptParentCompoundGeometry?,
    edge: CalendarResizeHandleEdge
) -> CalendarResizeHandlePlacement {
    let segmentWidth = max(
        0,
        min(
            viewWidth,
            {
                switch edge {
                case .top:
                    compoundGeometry?.visibleSegments.first?.width ?? viewWidth
                case .bottom:
                    compoundGeometry?.visibleSegments.last?.width ?? viewWidth
                }
            }()
        )
    )
    let availableWidth = max(4, segmentWidth)
    let baseHandleWidth = min(viewWidth * 0.4, 36)
    let width = min(baseHandleWidth, max(4, availableWidth - 4))
    return CalendarResizeHandlePlacement(
        centerX: availableWidth / 2,
        width: width,
        availableWidth: availableWidth
    )
}

private func calendarRoundedClosedPolygonPath(
    points: [CGPoint],
    cornerRadius: CGFloat
) -> Path {
    guard points.count >= 3 else { return Path() }

    let effectiveCornerRadius = max(0, cornerRadius)
    var path = Path()

    for index in points.indices {
        let previous = points[(index - 1 + points.count) % points.count]
        let current = points[index]
        let next = points[(index + 1) % points.count]

        let vectorToPrevious = CGVector(
            dx: previous.x - current.x,
            dy: previous.y - current.y
        )
        let vectorToNext = CGVector(
            dx: next.x - current.x,
            dy: next.y - current.y
        )
        let previousLength = hypot(vectorToPrevious.dx, vectorToPrevious.dy)
        let nextLength = hypot(vectorToNext.dx, vectorToNext.dy)
        guard previousLength > 0.001, nextLength > 0.001 else { continue }

        let radius = min(
            effectiveCornerRadius,
            previousLength / 2,
            nextLength / 2
        )
        let entryPoint = CGPoint(
            x: current.x + vectorToPrevious.dx / previousLength * radius,
            y: current.y + vectorToPrevious.dy / previousLength * radius
        )
        let exitPoint = CGPoint(
            x: current.x + vectorToNext.dx / nextLength * radius,
            y: current.y + vectorToNext.dy / nextLength * radius
        )

        if index == 0 {
            path.move(to: entryPoint)
        } else {
            path.addLine(to: entryPoint)
        }

        if radius > 0 {
            path.addQuadCurve(to: exitPoint, control: current)
        } else {
            path.addLine(to: current)
        }
    }

    path.closeSubpath()
    return path
}

// Extracted for regression tests: edit style, explicit handle state,
// or a live long-press edit gesture can expose resize handles.
func calendarShouldShowResizeHandles(
    style: EventBlockStyle,
    showsResizeHandles: Bool,
    isLongPressing: Bool = false
) -> Bool {
    style == .edit || showsResizeHandles || isLongPressing
}

/// Drag offset containing both X and Y components.
struct DragOffset: Equatable {
    var x: CGFloat
    var y: CGFloat

    static let zero = DragOffset(x: 0, y: 0)
}

/// Type of drag operation on event block
enum EventDragMode: Equatable {
    case move       // Drag from middle - move entire event
    case resizeTop  // Drag from top edge - adjust start time
    case resizeBottom // Drag from bottom edge - adjust end time
}

enum EventDragTerminalState: Equatable {
    case completed
    case cancelled
}

func calendarDragTerminalState(
    for gestureState: UIGestureRecognizer.State
) -> EventDragTerminalState? {
    switch gestureState {
    case .ended:
        return .completed
    case .cancelled, .failed:
        return .cancelled
    default:
        return nil
    }
}

func calendarShouldForwardDrop(
    for terminalState: EventDragTerminalState
) -> Bool {
    terminalState == .completed
}

func calendarResetSharedEventDragState(_ dragState: EventDragState) {
    dragState.draggingEventID = nil
    dragState.draggingOccurrenceID = nil
    dragState.draggingEvent = nil
    dragState.draggingOriginalRange = nil
    dragState.draggingRenderDayStart = nil
    dragState.currentTouchPointGlobal = nil
    dragState.dragOffset = .zero
    dragState.dragMode = .move
    dragState.isHorizontalEdgeDragging = false
    dragState.isHorizontalAutoScrolling = false
}

/// Smoothstep curve mapping rendered block height (pt) to the actual
/// fall-through inset to apply per edge. The S-curve has plateaus at
/// both ends:
///
/// - Below `calendarFallThroughCollapseHeight` → 0 (no fall-through; small
///   or pinched-out blocks keep their full hit area).
/// - Above `calendarFallThroughFullHeight` → `maxInset` (full 6pt band
///   on each edge, the original behavior for comfortably-sized blocks).
/// - In between, eased so the small end collapses sharply away from the
///   plateau while the large end approaches the plateau gently.
private let calendarFallThroughCollapseHeight: CGFloat = 12
private let calendarFallThroughFullHeight: CGFloat = 32

private func calendarFallThroughEdgeInset(maxInset: CGFloat, height: CGFloat) -> CGFloat {
    guard maxInset > 0 else { return 0 }
    let lo = calendarFallThroughCollapseHeight
    let hi = calendarFallThroughFullHeight
    if height <= lo { return 0 }
    if height >= hi { return maxInset }
    let t = (height - lo) / (hi - lo)
    let ease = t * t * (3 - 2 * t)
    return maxInset * ease
}

func calendarExtendedHitAreaContains(
    point: CGPoint,
    bounds: CGRect,
    verticalExtension: CGFloat,
    verticalEdgeInset: CGFloat = 0,
    excludedHitRects: [CGRect]
) -> Bool {
    let expandedBounds = bounds.insetBy(dx: 0, dy: -verticalExtension)
    guard expandedBounds.contains(point) else { return false }

    // Inward inset on the *original* bounds: shrinks the hit area at the
    // top and bottom edges so a touch in the inset band falls through to
    // the day column beneath, where drag-to-create lives. Without this,
    // pressing right under (or above) an event grabs the event for a
    // move drag and the creation gesture never gets a chance.
    let effectiveInset = calendarFallThroughEdgeInset(
        maxInset: verticalEdgeInset,
        height: bounds.height
    )
    if effectiveInset > 0 {
        let insetBounds = bounds.insetBy(dx: 0, dy: effectiveInset)
        if !insetBounds.contains(point) { return false }
    }

    return !excludedHitRects.contains { $0.contains(point) }
}

func calendarDragGestureNeedsTerminalRecovery(
    hasActiveGesture: Bool,
    isDragging: Bool,
    hasMovedAfterLongPress: Bool,
    hasPromotedManipulation: Bool,
    dragOffset: DragOffset,
    isHorizontalEdgeDragging: Bool,
    isHorizontalAutoScrolling: Bool
) -> Bool {
    hasActiveGesture
        || isDragging
        || hasMovedAfterLongPress
        || hasPromotedManipulation
        || dragOffset != .zero
        || isHorizontalEdgeDragging
        || isHorizontalAutoScrolling
}

func calendarShouldRenderCompoundInterruptParentShape(
    isCompoundParentEvent: Bool,
    isInDragState: Bool,
    dragMode: EventDragMode
) -> Bool {
    _ = isInDragState
    _ = dragMode
    return isCompoundParentEvent
}

/// UIView subclass that extends its touch area vertically for edge resize detection.
class ExtendedHitAreaView: UIView {
    var verticalExtension: CGFloat = 0
    var verticalEdgeInset: CGFloat = 0
    var excludedHitRects: [CGRect] = []

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        calendarExtendedHitAreaContains(
            point: point,
            bounds: bounds,
            verticalExtension: verticalExtension,
            verticalEdgeInset: verticalEdgeInset,
            excludedHitRects: excludedHitRects
        )
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Return self so the touch's view is THIS view, not a SwiftUI
        // content view underneath.  When SwiftUI re-renders content
        // during drag, the original touch view can get replaced, and
        // UIKit cancels the touch.  By being the touch owner, the
        // gesture survives content rebuilds.
        if self.point(inside: point, with: event) {
            return self
        }
        return nil
    }
}

let calendarEventManipulationLongPressDuration: TimeInterval = 0.35
let calendarEventExpressMenuLongPressDuration: TimeInterval = 1.0

func calendarEventExpressMenuAdditionalHoldDuration(
    manipulationLongPressDuration: TimeInterval = calendarEventManipulationLongPressDuration,
    expressMenuLongPressDuration: TimeInterval = calendarEventExpressMenuLongPressDuration
) -> TimeInterval {
    max(0, expressMenuLongPressDuration - manipulationLongPressDuration)
}

/// UIKit-based long press drag gesture for event blocks.
/// Detects drag position to determine move vs resize operations.
struct EventBlockDragGesture: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = calendarEventManipulationLongPressDuration
    var edgeThreshold: CGFloat = 10 // Points from inside edge to trigger resize
    var outerEdgeThreshold: CGFloat = 0 // Points outside event block to trigger resize
    /// Inward inset at the top and bottom of the block. Touches landing in
    /// this band are passed through to the layer below (the day column's
    /// drag-to-create gesture). Caller should set this to 0 for blocks
    /// with visible resize handles, since handles must remain hittable at
    /// the very edge.
    var verticalEdgeInset: CGFloat = 0
    var snapSize: CGFloat // Points per 15-minute snap interval (must be set from hourHeight / 4)
    var horizontalAutoScrollEdgeInset: CGFloat = calendarHorizontalAutoScrollEdgeInsetDefault
    var verticalAutoScrollEdgeInset: CGFloat = calendarVerticalAutoScrollEdgeInsetDefault
    var maxAutoScrollSpeed: CGFloat = calendarMaxAutoScrollSpeedDefault // pt/s
    var horizontalAutoScrollUnitStep: CGFloat = 0
    var usesHorizontalBoundaryPaging: Bool = false
    /// Allowed Y offset range (points). Clamps the drag so the event
    /// cannot exceed the extended timeline boundaries.
    var verticalDragBounds: ClosedRange<CGFloat> = -.infinity ... .infinity
    var excludedHitRects: [CGRect] = []
    var topResizeHandlePlacement: CalendarResizeHandlePlacement? = nil
    var bottomResizeHandlePlacement: CalendarResizeHandlePlacement? = nil
    var canMove: Bool = true
    var canResizeTop: Bool = true
    var canResizeBottom: Bool = true
    var debugEventID: String = ""
    var debugOccurrenceID: String = ""
    var onLongPressBegan: ((EventDragMode, CGPoint, CGRect) -> Void)?
    var onManipulationPromotion: ((EventDragMode, CGPoint, CGRect) -> Void)?
    var onDragBegan: ((EventDragMode) -> Void)?
    var onDragTouchChanged: ((CGPoint) -> Void)?
    var onDragChanged: ((DragOffset) -> Void)?
    var onDragEnded: ((EventDragMode, DragOffset) -> Void)?
    var onDragTerminal: ((EventDragMode, DragOffset, EventDragTerminalState) -> Void)?
    var onLongPressResolved: ((EventDragMode, EventDragTerminalState, Bool, CGPoint) -> Void)?
    var onHorizontalBoundaryPageRequest: ((Int) -> Bool)? = nil
    @Binding var isDragging: Bool
    @Binding var isHorizontalEdgeDragging: Bool
    @Binding var isHorizontalAutoScrolling: Bool
    @Binding var dragOffset: DragOffset
    @Binding var dragMode: EventDragMode

    /// Subclass that logs when the gesture is cancelled and captures
    /// the call stack so we can identify the cancellation source.
    private class TracingLongPressGesture: UILongPressGestureRecognizer {
        override var state: UIGestureRecognizer.State {
            didSet {
                if state == .cancelled {
                    let symbols = Thread.callStackSymbols.prefix(8).joined(separator: "\n  ")
                    dragMovementLog("GESTURE_CANCELLED stack:\n  \(symbols)")
                }
            }
        }
        /// Set by the coordinator when drag is actively promoted so we
        /// can absorb touch cancellations from SwiftUI view rebuilds.
        var isDragPromoted = false

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            DragSessionMonitor.shared.recordTouchCancel()
            if isDragPromoted {
                dragMovementLog("TOUCH_CANCEL_ABSORBED", severity: .warn)
                return
            }
            dragMovementLog("TOUCH_CANCEL_FORWARDED state=\(self.state.rawValue)", severity: .error)
            super.touchesCancelled(touches, with: event)
        }
    }

    func makeUIView(context: Context) -> ExtendedHitAreaView {
        let mon = DragSessionMonitor.shared
        mon.recordMakeUIView()
        if mon.activeEventID != nil {
            dragMovementLog("MAKE_UI_VIEW id=\(debugEventID.prefix(8)) DURING_ACTIVE_DRAG(\(mon.activeEventID?.prefix(8) ?? "?"))", severity: .error)
        }
        let view = ExtendedHitAreaView()
        view.backgroundColor = .clear
        view.verticalExtension = outerEdgeThreshold
        view.verticalEdgeInset = verticalEdgeInset

        let gesture = TracingLongPressGesture(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        gesture.minimumPressDuration = minimumPressDuration
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)

        return view
    }

    func updateUIView(_ uiView: ExtendedHitAreaView, context: Context) {
        uiView.verticalExtension = outerEdgeThreshold
        uiView.verticalEdgeInset = verticalEdgeInset
        uiView.excludedHitRects = excludedHitRects
        // CRITICAL: Update parent reference so bindings work correctly
        context.coordinator.parent = self
        context.coordinator.onLongPressBegan = onLongPressBegan
        context.coordinator.onManipulationPromotion = onManipulationPromotion
        context.coordinator.onDragBegan = onDragBegan
        context.coordinator.onDragTouchChanged = onDragTouchChanged
        context.coordinator.onDragChanged = onDragChanged
        // Don't nil out onDragEnded while a drag is in progress —
        // after boundary page the source EventBlock may be re-evaluated
        // with isInteractionAllowed=false, but the coordinator still
        // needs the end callback to commit the move.
        if onDragEnded != nil || !context.coordinator.isDragInProgress {
            context.coordinator.onDragEnded = onDragEnded
        }
        context.coordinator.onDragTerminal = onDragTerminal
        context.coordinator.onLongPressResolved = onLongPressResolved
        context.coordinator.edgeThreshold = edgeThreshold
        context.coordinator.snapSize = snapSize
        context.coordinator.horizontalAutoScrollEdgeInset = horizontalAutoScrollEdgeInset
        context.coordinator.verticalAutoScrollEdgeInset = verticalAutoScrollEdgeInset
        context.coordinator.maxAutoScrollSpeed = maxAutoScrollSpeed
        context.coordinator.horizontalAutoScrollUnitStep = horizontalAutoScrollUnitStep
        context.coordinator.verticalDragBounds = verticalDragBounds
        context.coordinator.usesHorizontalBoundaryPaging = usesHorizontalBoundaryPaging
        context.coordinator.topResizeHandlePlacement = topResizeHandlePlacement
        context.coordinator.bottomResizeHandlePlacement = bottomResizeHandlePlacement
        context.coordinator.canMove = canMove
        context.coordinator.canResizeTop = canResizeTop
        context.coordinator.canResizeBottom = canResizeBottom
        context.coordinator.onHorizontalBoundaryPageRequest = onHorizontalBoundaryPageRequest
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: EventBlockDragGesture
        var onLongPressBegan: ((EventDragMode, CGPoint, CGRect) -> Void)?
        var onManipulationPromotion: ((EventDragMode, CGPoint, CGRect) -> Void)?
        var onDragBegan: ((EventDragMode) -> Void)?
        var onDragTouchChanged: ((CGPoint) -> Void)?
        var onDragChanged: ((DragOffset) -> Void)?
        var onDragEnded: ((EventDragMode, DragOffset) -> Void)?
        var onDragTerminal: ((EventDragMode, DragOffset, EventDragTerminalState) -> Void)?
        var onLongPressResolved: ((EventDragMode, EventDragTerminalState, Bool, CGPoint) -> Void)?
        var edgeThreshold: CGFloat = 20
        var snapSize: CGFloat = 0
        var horizontalAutoScrollEdgeInset: CGFloat = calendarHorizontalAutoScrollEdgeInsetDefault
        var verticalAutoScrollEdgeInset: CGFloat = calendarVerticalAutoScrollEdgeInsetDefault
        var maxAutoScrollSpeed: CGFloat = calendarMaxAutoScrollSpeedDefault
        var horizontalAutoScrollUnitStep: CGFloat = 0
        var usesHorizontalBoundaryPaging: Bool = false
        var verticalDragBounds: ClosedRange<CGFloat> = -.infinity ... .infinity
        var topResizeHandlePlacement: CalendarResizeHandlePlacement?
        var bottomResizeHandlePlacement: CalendarResizeHandlePlacement?
        var canMove: Bool = true
        var canResizeTop: Bool = true
        var canResizeBottom: Bool = true
        var onHorizontalBoundaryPageRequest: ((Int) -> Bool)?
        private var initialPointInWindow: CGPoint = .zero
        private var lastLocationInWindow: CGPoint = .zero
        private var autoScrollCompensationX: CGFloat = 0
        private var autoScrollCompensationY: CGFloat = 0
        private weak var horizontalScrollView: UIScrollView?
        private weak var verticalScrollView: UIScrollView?
        private weak var activeGesture: UILongPressGestureRecognizer?
        /// Whether a drag gesture is currently in progress (active gesture exists).
        var isDragInProgress: Bool { activeGesture != nil }
        private var autoScrollVelocityX: CGFloat = 0
        private var autoScrollVelocityY: CGFloat = 0
        private var autoScrollDisplayLink: CADisplayLink?
        private var isHorizontalSnapSuppressed: Bool = false
        private var disabledScrollGestures: [(gesture: UIGestureRecognizer, wasEnabled: Bool)] = []
        private var hasMovedAfterLongPress: Bool = false
        private var hasPromotedManipulation = false
        private var currentMode: EventDragMode = .move
        private var lastSnappedStep: Int = 0
        private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        private var lastChangedLogTimestamp: CFTimeInterval = 0
        private var lastDragMovementLogTimestamp: CFTimeInterval = 0
        private var lastLoggedHorizontalAutoScrolling: Bool = false
        private var lastHorizontalBoundaryPageTimestamp: CFTimeInterval = 0
        private let horizontalBoundaryPageMinimumInterval: CFTimeInterval = 0.8
        private var horizontalBoundaryPageCount: Int = 0
        private var horizontalBoundaryPageOriginX: CGFloat = 0

        /// Returns the gesture view's frame in window coordinates (live UIKit value).
        private var viewFrameInWindow: CGRect {
            guard let view = activeGesture?.view else { return .zero }
            return view.convert(view.bounds, to: nil)
        }

        init(_ parent: EventBlockDragGesture) {
            self.parent = parent
            self.onLongPressBegan = parent.onLongPressBegan
            self.onManipulationPromotion = parent.onManipulationPromotion
            self.onDragBegan = parent.onDragBegan
            self.onDragTouchChanged = parent.onDragTouchChanged
            self.onDragChanged = parent.onDragChanged
            self.onDragEnded = parent.onDragEnded
            self.onDragTerminal = parent.onDragTerminal
            self.onLongPressResolved = parent.onLongPressResolved
            self.edgeThreshold = parent.edgeThreshold
            self.snapSize = parent.snapSize
            self.horizontalAutoScrollEdgeInset = parent.horizontalAutoScrollEdgeInset
            self.verticalAutoScrollEdgeInset = parent.verticalAutoScrollEdgeInset
            self.maxAutoScrollSpeed = parent.maxAutoScrollSpeed
            self.horizontalAutoScrollUnitStep = parent.horizontalAutoScrollUnitStep
            self.verticalDragBounds = parent.verticalDragBounds
            self.usesHorizontalBoundaryPaging = parent.usesHorizontalBoundaryPaging
            self.topResizeHandlePlacement = parent.topResizeHandlePlacement
            self.bottomResizeHandlePlacement = parent.bottomResizeHandlePlacement
            self.canMove = parent.canMove
            self.canResizeTop = parent.canResizeTop
            self.canResizeBottom = parent.canResizeBottom
            self.onHorizontalBoundaryPageRequest = parent.onHorizontalBoundaryPageRequest
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let viewHeight = view.bounds.height

            switch gesture.state {
            case .began:
                initialPointInWindow = gesture.location(in: nil)
                lastLocationInWindow = initialPointInWindow
                activeGesture = gesture
                let scrollTargets = findScrollTargets(startingAt: view)
                horizontalScrollView = scrollTargets.horizontal
                verticalScrollView = scrollTargets.vertical
                autoScrollCompensationX = 0
                autoScrollCompensationY = 0
                autoScrollVelocityX = 0
                autoScrollVelocityY = 0
                isHorizontalSnapSuppressed = false
                hasMovedAfterLongPress = false
                hasPromotedManipulation = false
                lastSnappedStep = 0
                lastLoggedHorizontalAutoScrolling = false
                lastHorizontalBoundaryPageTimestamp = 0
                horizontalBoundaryPageCount = 0
                horizontalBoundaryPageOriginX = initialPointInWindow.x

                currentMode = calendarResolveDragMode(
                    locationX: location.x,
                    locationY: location.y,
                    viewWidth: view.bounds.width,
                    viewHeight: viewHeight,
                    edgeThreshold: edgeThreshold,
                    canResizeTop: canResizeTop,
                    canResizeBottom: canResizeBottom,
                    topHandlePlacement: topResizeHandlePlacement,
                    bottomHandlePlacement: bottomResizeHandlePlacement
                )

                onLongPressBegan?(currentMode, initialPointInWindow, viewFrameInWindow)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                DragSessionMonitor.shared.beginSession(eventID: parent.debugEventID)
                // `?? 0.0` (not `?? 0`) so the literal stays a Double under
                // SE-0307 CGFloat ↔ Double interop — otherwise the result
                // can be inferred as Int and trigger a runtime "%lld vs
                // %.1f" format-string warning inside Foundation.
                dragMovementLog("DRAG_BEGIN id=\(parent.debugEventID.prefix(8)) mode=\(currentMode) fingerY=\(String(format:"%.1f",initialPointInWindow.y)) vScrollY=\(String(format:"%.1f",verticalScrollView?.contentOffset.y ?? 0.0))")
                calendarDebugLog(
                    "event.drag.begin",
                    fields: [
                        "eventID": parent.debugEventID,
                        "occurrenceID": debugOccurrenceKey,
                        "mode": String(describing: currentMode),
                        "touchInViewX": format(location.x),
                        "touchInViewY": format(location.y),
                        "initialWindowX": format(initialPointInWindow.x),
                        "initialWindowY": format(initialPointInWindow.y),
                        "horizontalOffsetX": format(horizontalScrollView?.contentOffset.x ?? 0),
                        "verticalOffsetY": format(verticalScrollView?.contentOffset.y ?? 0)
                    ]
                )

            case .changed:
                let rawLocationInWindow = gesture.location(in: nil)
                lastLocationInWindow = rawLocationInWindow
                let rawDeltaX = rawLocationInWindow.x - initialPointInWindow.x
                let rawDeltaY = rawLocationInWindow.y - initialPointInWindow.y
                let hasCrossedMovementThreshold = hypot(rawDeltaX, rawDeltaY) > 8

                if !hasPromotedManipulation {
                    guard calendarShouldPromoteLongPressToManipulation(
                        dragMode: currentMode,
                        canMove: canMove,
                        movementExceededThreshold: hasCrossedMovementThreshold
                    ) else {
                        stopAutoScroll(reason: "stagedLongPressAwaitingPromotion")
                        return
                    }

                    hasMovedAfterLongPress = true
                    hasPromotedManipulation = true
                    if let g = activeGesture as? TracingLongPressGesture {
                        g.isDragPromoted = true
                    }
                    disableScrollPanGesturesForDrag()
                    parent.dragMode = currentMode
                    parent.isHorizontalEdgeDragging = false
                    parent.isHorizontalAutoScrolling = false
                    parent.isDragging = true
                    onManipulationPromotion?(currentMode, lastLocationInWindow, viewFrameInWindow)
                    onDragBegan?(currentMode)
                    updateAutoScrollVelocity()
                    // Compute and apply offset immediately so the first frame
                    // already reflects the finger position (no zero-frame lag).
                    updateDragOffset(using: gesture)
                    return
                }

                if hasMovedAfterLongPress {
                    // Update edge/auto-scroll state first so this frame's drag offset
                    // is rendered with the correct (possibly unsnapped) boundary behavior.
                    updateAutoScrollVelocity()
                } else {
                    stopAutoScroll(reason: "changedWithoutMovement")
                }
                updateDragOffset(using: gesture)
                let now = CACurrentMediaTime()
                if now - lastChangedLogTimestamp >= 0.08 {
                    lastChangedLogTimestamp = now
                    calendarDebugLog(
                        "event.drag.changed",
                        fields: [
                            "eventID": parent.debugEventID,
                            "occurrenceID": debugOccurrenceKey,
                            "mode": String(describing: currentMode),
                            "fingerX": format(rawLocationInWindow.x),
                            "fingerY": format(rawLocationInWindow.y),
                            "deltaX": format(rawDeltaX),
                            "deltaY": format(rawDeltaY),
                            "resolvedOffsetX": format(parent.dragOffset.x),
                            "resolvedOffsetY": format(parent.dragOffset.y),
                            "isEdgeDragging": "\(parent.isHorizontalEdgeDragging)",
                            "isHorizontalAutoScrolling": "\(parent.isHorizontalAutoScrolling)",
                            "velocityX": format(autoScrollVelocityX),
                            "velocityY": format(autoScrollVelocityY)
                        ]
                    )
                }

            case .ended, .cancelled, .failed:
                let gestureState = gesture.state
                guard let terminalState = calendarDragTerminalState(for: gestureState) else {
                    return
                }
                if hasPromotedManipulation {
                    let shouldForwardDrop = calendarShouldForwardDrop(for: terminalState)
                    updateDragOffset(using: gesture)
                    let finalOffset = parent.dragOffset
                    let viewStillInWindow = gesture.view?.window != nil
                    let scrollPanEnabled = verticalScrollView?.panGestureRecognizer.isEnabled ?? true
                    let vDecelerating = verticalScrollView?.isDecelerating ?? false
                    let vDragging = verticalScrollView?.isDragging ?? false
                    let vTracking = verticalScrollView?.isTracking ?? false
                    let gestureViewFrame = gesture.view.map { $0.convert($0.bounds, to: nil) } ?? .zero
                    // Count active gesture recognizers on ancestor views
                    var ancestorGestureInfo = ""
                    var current: UIView? = gesture.view?.superview
                    while let v = current {
                        let activeGRs = (v.gestureRecognizers ?? []).filter {
                            $0.state == .began || $0.state == .changed
                        }
                        if !activeGRs.isEmpty {
                            ancestorGestureInfo += " [\(type(of: v)):\(activeGRs.count)active]"
                        }
                        current = v.superview
                    }
                    let mon = DragSessionMonitor.shared
                    let sev: DragAnomalySeverity = gestureState == .cancelled ? .error : .info
                    dragMovementLog("DRAG_END id=\(parent.debugEventID.prefix(8)) state=\(gestureState.rawValue) offY=\(String(format:"%.1f",finalOffset.y)) compY=\(String(format:"%.1f",autoScrollCompensationY)) viewFrame=\(String(format:"%.0f,%.0f,%.0f,%.0f",gestureViewFrame.minX,gestureViewFrame.minY,gestureViewFrame.width,gestureViewFrame.height)) session=[touchCancels=\(mon.touchCancelCount) makeUIViews=\(mon.makeUIViewCount) frameChanges=\(mon.frameChangeCount)]", severity: sev)
                    DragSessionMonitor.shared.endSession()
                    let mode = currentMode
                    let hadMovedAfterLongPress = hasMovedAfterLongPress
                    finalizeTouchInteraction()
                    calendarDebugLog(
                        "event.drag.end",
                        fields: [
                            "eventID": parent.debugEventID,
                            "occurrenceID": debugOccurrenceKey,
                            "mode": String(describing: mode),
                            "finalOffsetX": format(finalOffset.x),
                            "finalOffsetY": format(finalOffset.y),
                            "state": String(describing: gestureState),
                            "terminalState": String(describing: terminalState),
                            "shouldForwardDrop": "\(shouldForwardDrop)",
                            "hadMovedAfterLongPress": "\(hadMovedAfterLongPress)"
                        ]
                    )
                    if shouldForwardDrop && hadMovedAfterLongPress {
                        onDragEnded?(mode, finalOffset)
                    }
                    onLongPressResolved?(mode, terminalState, hadMovedAfterLongPress, lastLocationInWindow)
                    onDragTerminal?(mode, finalOffset, terminalState)
                    return
                }

                let mode = currentMode
                finalizeTouchInteraction()
                calendarDebugLog(
                    "event.longPress.end",
                    fields: [
                        "eventID": parent.debugEventID,
                        "occurrenceID": debugOccurrenceKey,
                        "mode": String(describing: mode),
                        "state": String(describing: gestureState),
                        "terminalState": String(describing: terminalState)
                    ]
                )
                onLongPressResolved?(mode, terminalState, false, lastLocationInWindow)

            default:
                break
            }
        }

        deinit {
            let shouldRecoverTerminalState = calendarDragGestureNeedsTerminalRecovery(
                hasActiveGesture: activeGesture != nil,
                isDragging: parent.isDragging,
                hasMovedAfterLongPress: hasMovedAfterLongPress,
                hasPromotedManipulation: hasPromotedManipulation,
                dragOffset: parent.dragOffset,
                isHorizontalEdgeDragging: parent.isHorizontalEdgeDragging,
                isHorizontalAutoScrolling: parent.isHorizontalAutoScrolling
            )
            if shouldRecoverTerminalState {
                dragMovementLog("DEINIT_RECOVER id=\(parent.debugEventID.prefix(8)) offY=\(String(format:"%.1f",parent.dragOffset.y))", severity: .error)
                let mode = currentMode
                let finalOffset = parent.dragOffset
                let didMove = hasMovedAfterLongPress
                onLongPressResolved?(mode, .cancelled, didMove, lastLocationInWindow)
                onDragTerminal?(mode, finalOffset, .cancelled)
                parent.isDragging = false
                parent.isHorizontalEdgeDragging = false
                parent.isHorizontalAutoScrolling = false
                parent.dragOffset = .zero
            }
            stopAutoScroll(reason: "coordinatorDeinit")
            restoreScrollPanGestures()
        }

        private func finalizeTouchInteraction() {
            stopAutoScroll(reason: "gestureEnded")
            if let g = activeGesture as? TracingLongPressGesture {
                g.isDragPromoted = false
            }
            restoreScrollPanGestures()
            activeGesture = nil
            horizontalScrollView = nil
            verticalScrollView = nil
            hasMovedAfterLongPress = false
            hasPromotedManipulation = false
            isHorizontalSnapSuppressed = false
            parent.isDragging = false
            parent.isHorizontalEdgeDragging = false
            parent.isHorizontalAutoScrolling = false
            parent.dragOffset = .zero
            autoScrollCompensationX = 0
            autoScrollCompensationY = 0
            lastHorizontalBoundaryPageTimestamp = 0
            horizontalBoundaryPageCount = 0
            horizontalBoundaryPageOriginX = 0
        }

        // Keep drag offset stable in window coordinates, then add scroll compensation
        // so auto-scrolling still advances the dragged time while finger stays near edge.
        private func updateDragOffset(using gesture: UILongPressGestureRecognizer) {
            let locationInWindow = gesture.location(in: nil)
            lastLocationInWindow = locationInWindow
            onDragTouchChanged?(locationInWindow)

            let resolvedFingerDeltaX: CGFloat = {
                guard currentMode == .move,
                      usesHorizontalBoundaryPaging,
                      horizontalAutoScrollUnitStep > 0 else {
                    return locationInWindow.x - initialPointInWindow.x
                }
                let localOffsetX = locationInWindow.x - horizontalBoundaryPageOriginX
                return calendarBoundaryPagedHorizontalDragOffset(
                    localOffsetX: localOffsetX,
                    pageCount: horizontalBoundaryPageCount,
                    dayStep: horizontalAutoScrollUnitStep
                )
            }()
            let fingerDelta = DragOffset(
                x: resolvedFingerDeltaX,
                y: locationInWindow.y - initialPointInWindow.y
            )
            let offset = calendarComposedDragOffset(
                fingerDelta: fingerDelta,
                autoScrollCompensation: DragOffset(
                    x: autoScrollCompensationX,
                    y: autoScrollCompensationY
                )
            )
            applyDragOffset(offset)
        }

        private func applyDragOffset(_ offset: DragOffset) {
            let suppressHorizontalSnap = isHorizontalSnapSuppressed || autoScrollVelocityX != 0
            var resolved = calendarResolvedDragOffset(
                rawOffset: offset,
                dragMode: currentMode,
                dayColumnStep: horizontalAutoScrollUnitStep,
                suppressHorizontalSnap: suppressHorizontalSnap
            )
            resolved.y = calendarClampedMoveDragOffsetY(
                rawOffsetY: resolved.y,
                dragMode: currentMode,
                verticalDragBounds: verticalDragBounds
            )

            // Haptic on each 15-minute snap boundary crossed
            if snapSize > 0 {
                let currentStep = Int((resolved.y / snapSize).rounded())
                if currentStep != lastSnappedStep {
                    lastSnappedStep = currentStep
                    impactFeedback.impactOccurred()
                }
            }

            guard parent.dragOffset != resolved else { return }
            parent.dragOffset = resolved
            onDragChanged?(resolved)

            let now = CACurrentMediaTime()
            if now - lastDragMovementLogTimestamp >= 0.15 {
                lastDragMovementLogTimestamp = now
                // `?? 0.0` (not `?? 0`) so the literal stays a Double under
                // SE-0307 CGFloat ↔ Double interop — otherwise `vOff` can
                // be inferred as Int and trigger a runtime "%lld vs %.1f"
                // format-string warning inside Foundation.
                let vOff = verticalScrollView?.contentOffset.y ?? 0.0
                dragMovementLog("DRAG_MOVE id=\(parent.debugEventID.prefix(8)) fingerY=\(String(format:"%.1f",lastLocationInWindow.y)) offX=\(String(format:"%.1f",resolved.x)) offY=\(String(format:"%.1f",resolved.y)) compY=\(String(format:"%.1f",autoScrollCompensationY)) vScrollY=\(String(format:"%.1f",vOff)) vVel=\(String(format:"%.1f",autoScrollVelocityY)) edge=\(parent.isHorizontalEdgeDragging)")
            }
        }

        private enum ScrollAxis {
            case horizontal
            case vertical
        }

        private func updateAutoScrollVelocity() {
            guard hasMovedAfterLongPress else {
                stopAutoScroll(reason: "moveGateFalse")
                isHorizontalSnapSuppressed = false
                parent.isHorizontalEdgeDragging = false
                parent.isHorizontalAutoScrolling = false
                return
            }

            let horizontalEdgeActive = isInHorizontalAutoScrollEdgeZone()
            if currentMode == .move, usesHorizontalBoundaryPaging {
                autoScrollVelocityX = 0
                handleHorizontalBoundaryPagingIfNeeded(horizontalEdgeActive: horizontalEdgeActive)
            } else {
                autoScrollVelocityX = currentMode == .move
                    ? autoScrollVelocity(for: horizontalScrollView, axis: .horizontal)
                    : 0
            }
            autoScrollVelocityY = autoScrollVelocity(for: verticalScrollView, axis: .vertical)

            // Keep the display link alive while the finger sits in the
            // horizontal edge zone during boundary paging — velocities are
            // zero but the tick is needed so handleHorizontalBoundaryPaging
            // fires repeatedly for continuous day-by-day paging.
            let needsBoundaryPagingTick = usesHorizontalBoundaryPaging && horizontalEdgeActive
            if autoScrollVelocityX == 0 && autoScrollVelocityY == 0 && !needsBoundaryPagingTick {
                stopAutoScroll(reason: "zeroVelocity")
            } else {
                startAutoScroll()
            }
            let isAutoScrolling = autoScrollVelocityX != 0
            // Runtime suppression: only while edge-zone or horizontal auto-scroll is active.
            isHorizontalSnapSuppressed = horizontalEdgeActive || isAutoScrolling
            parent.isHorizontalEdgeDragging = isHorizontalSnapSuppressed
            parent.isHorizontalAutoScrolling = isAutoScrolling
            if isAutoScrolling != lastLoggedHorizontalAutoScrolling {
                lastLoggedHorizontalAutoScrolling = isAutoScrolling
                calendarDebugLog(
                    "event.horizontalAutoScroll.state",
                    fields: [
                        "eventID": parent.debugEventID,
                        "occurrenceID": debugOccurrenceKey,
                        "isAutoScrolling": "\(isAutoScrolling)",
                        "velocityX": format(autoScrollVelocityX),
                        "velocityY": format(autoScrollVelocityY),
                        "isEdgeDragging": "\(parent.isHorizontalEdgeDragging)"
                    ]
                )
            }
        }

        private func handleHorizontalBoundaryPagingIfNeeded(horizontalEdgeActive: Bool) {
            guard horizontalEdgeActive,
                  horizontalAutoScrollUnitStep > 0,
                  let onHorizontalBoundaryPageRequest else {
                return
            }
            let direction = horizontalBoundaryPageDirection()
            guard direction != 0 else { return }
            let now = CACurrentMediaTime()
            guard now - lastHorizontalBoundaryPageTimestamp >= horizontalBoundaryPageMinimumInterval else {
                return
            }
            guard onHorizontalBoundaryPageRequest(direction) else { return }
            lastHorizontalBoundaryPageTimestamp = now
            horizontalBoundaryPageCount += direction
            horizontalBoundaryPageOriginX = lastLocationInWindow.x
            // Immediately recompute drag offset with the new page count
            // so dragState.dragOffset reflects the new day.  Without
            // this, the preview stays in the old day until the finger
            // moves again (which may never happen if stationary at edge).
            if let gesture = activeGesture {
                updateDragOffset(using: gesture)
            }
            calendarDebugLog(
                "event.horizontalBoundaryPage",
                fields: [
                    "eventID": parent.debugEventID,
                    "occurrenceID": debugOccurrenceKey,
                    "direction": "\(direction)",
                    "pageCount": "\(horizontalBoundaryPageCount)",
                    "originX": format(horizontalBoundaryPageOriginX)
                ]
            )
        }

        private func startAutoScroll() {
            guard autoScrollDisplayLink == nil else { return }
            dragMovementLog("AUTOSCROLL_START id=\(parent.debugEventID.prefix(8)) vX=\(String(format:"%.1f",autoScrollVelocityX)) vY=\(String(format:"%.1f",autoScrollVelocityY))")
            let link = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            autoScrollDisplayLink = link
            calendarDebugLog(
                "event.horizontalAutoScroll.start",
                fields: [
                    "eventID": parent.debugEventID,
                    "occurrenceID": debugOccurrenceKey,
                    "velocityX": format(autoScrollVelocityX),
                    "velocityY": format(autoScrollVelocityY),
                    "isEdgeDragging": "\(parent.isHorizontalEdgeDragging)"
                ]
            )
        }

        private func stopAutoScroll(reason: String) {
            let wasAutoScrolling = autoScrollDisplayLink != nil || autoScrollVelocityX != 0 || autoScrollVelocityY != 0
            if wasAutoScrolling {
                dragMovementLog("AUTOSCROLL_STOP id=\(parent.debugEventID.prefix(8)) reason=\(reason) compY=\(String(format:"%.1f",autoScrollCompensationY))")
            }
            // isDragPromoted stays true until finalizeTouchInteraction
            autoScrollDisplayLink?.invalidate()
            autoScrollDisplayLink = nil
            autoScrollVelocityX = 0
            autoScrollVelocityY = 0
            parent.isHorizontalAutoScrolling = false
            if wasAutoScrolling {
                calendarDebugLog(
                    "event.horizontalAutoScroll.stop",
                    fields: [
                        "eventID": parent.debugEventID,
                        "occurrenceID": debugOccurrenceKey,
                        "reason": reason,
                        "compensationX": format(autoScrollCompensationX),
                        "compensationY": format(autoScrollCompensationY),
                        "horizontalOffsetX": format(horizontalScrollView?.contentOffset.x ?? 0),
                        "verticalOffsetY": format(verticalScrollView?.contentOffset.y ?? 0)
                    ]
                )
            }
        }

        @objc private func handleAutoScrollTick(_ displayLink: CADisplayLink) {
            guard autoScrollVelocityX != 0 || autoScrollVelocityY != 0 else {
                stopAutoScroll(reason: "tickNoVelocity")
                return
            }

            let dt = max(displayLink.targetTimestamp - displayLink.timestamp, 0)
            let deltaX = calendarHorizontalAutoScrollDelta(
                velocityX: autoScrollVelocityX,
                deltaTime: dt
            )
            let delta = CGPoint(
                x: deltaX,
                y: autoScrollVelocityY * CGFloat(dt)
            )

            if let sharedScrollView = horizontalScrollView, sharedScrollView === verticalScrollView {
                let applied = applyAutoScroll(
                    on: sharedScrollView,
                    delta: delta
                )
                autoScrollCompensationX += applied.x
                autoScrollCompensationY += applied.y
            } else {
                if let scrollView = horizontalScrollView {
                    let applied = applyAutoScroll(
                        on: scrollView,
                        delta: CGPoint(x: delta.x, y: 0)
                    )
                    autoScrollCompensationX += applied.x
                }
                if let scrollView = verticalScrollView {
                    let applied = applyAutoScroll(on: scrollView, delta: CGPoint(x: 0, y: delta.y))
                    autoScrollCompensationY += applied.y
                }
            }

            if let gesture = activeGesture {
                lastLocationInWindow = gesture.location(in: nil)
            }
            updateAutoScrollVelocity()
            if let gesture = activeGesture {
                updateDragOffset(using: gesture)
            }
        }

        private func autoScrollVelocity(for scrollView: UIScrollView?, axis: ScrollAxis) -> CGFloat {
            guard let scrollView else { return 0 }

            let minOffset: CGFloat
            let maxOffset: CGFloat
            let boundsSize: CGFloat
            let pointerLocationInViewport: CGFloat
            let edgeInset: CGFloat

            switch axis {
            case .horizontal:
                minOffset = -scrollView.adjustedContentInset.left
                maxOffset = max(minOffset, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
                boundsSize = scrollView.bounds.width
                pointerLocationInViewport = locationInViewport(for: scrollView, axis: .horizontal)
                edgeInset = horizontalAutoScrollEdgeInset
            case .vertical:
                minOffset = -scrollView.adjustedContentInset.top
                maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
                boundsSize = scrollView.bounds.height
                pointerLocationInViewport = locationInViewport(for: scrollView, axis: .vertical)
                edgeInset = verticalAutoScrollEdgeInset
            }

            let currentOffset: CGFloat = axis == .horizontal ? scrollView.contentOffset.x : scrollView.contentOffset.y
            return calendarAutoScrollVelocity(
                locationInViewport: pointerLocationInViewport,
                viewportLength: boundsSize,
                currentOffset: currentOffset,
                minOffset: minOffset,
                maxOffset: maxOffset,
                edgeInset: edgeInset,
                maxSpeed: maxAutoScrollSpeed
            )
        }

        private func locationInViewport(for scrollView: UIScrollView, axis: ScrollAxis) -> CGFloat {
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            switch axis {
            case .horizontal:
                return lastLocationInWindow.x - frameInWindow.minX
            case .vertical:
                return lastLocationInWindow.y - frameInWindow.minY
            }
        }

        private func isInHorizontalAutoScrollEdgeZone() -> Bool {
            guard currentMode == .move, let horizontalScrollView else { return false }
            let location = locationInViewport(for: horizontalScrollView, axis: .horizontal)
            return calendarIsInAutoScrollEdgeZone(
                locationInViewport: location,
                viewportLength: horizontalScrollView.bounds.width,
                edgeInset: horizontalAutoScrollEdgeInset
            )
        }

        private func horizontalBoundaryPageDirection() -> Int {
            guard let horizontalScrollView else { return 0 }
            let location = locationInViewport(for: horizontalScrollView, axis: .horizontal)
            return calendarHorizontalBoundaryPageDirection(
                locationInViewport: location,
                viewportLength: horizontalScrollView.bounds.width,
                edgeInset: horizontalAutoScrollEdgeInset
            )
        }

        private var savedCanCancelContentTouches: [(scrollView: UIScrollView, wasEnabled: Bool)] = []

        private func disableScrollPanGesturesForDrag() {
            guard disabledScrollGestures.isEmpty else { return }
            // Walk the ENTIRE ancestor chain and disable canCancelContentTouches
            // on every UIScrollView found — not just the two we track for auto-scroll.
            var current: UIView? = activeGesture?.view?.superview
            var seen = Set<ObjectIdentifier>()
            while let v = current {
                if let scrollView = v as? UIScrollView {
                    let svId = ObjectIdentifier(scrollView)
                    if !seen.contains(svId) {
                        seen.insert(svId)
                        savedCanCancelContentTouches.append((scrollView: scrollView, wasEnabled: scrollView.canCancelContentTouches))
                        scrollView.canCancelContentTouches = false
                        for gesture in scrollView.gestureRecognizers ?? [] {
                            disabledScrollGestures.append((gesture: gesture, wasEnabled: gesture.isEnabled))
                            gesture.isEnabled = false
                        }
                    }
                }
                current = v.superview
            }
        }

        private func restoreScrollPanGestures() {
            for entry in savedCanCancelContentTouches {
                entry.scrollView.canCancelContentTouches = entry.wasEnabled
            }
            savedCanCancelContentTouches.removeAll()
            guard !disabledScrollGestures.isEmpty else { return }
            for entry in disabledScrollGestures {
                entry.gesture.isEnabled = entry.wasEnabled
            }
            disabledScrollGestures.removeAll()
        }

        private func applyAutoScroll(
            on scrollView: UIScrollView,
            delta: CGPoint
        ) -> CGPoint {
            let minOffsetX = -scrollView.adjustedContentInset.left
            let maxOffsetX = max(minOffsetX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
            let minOffsetY = -scrollView.adjustedContentInset.top
            let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)

            let currentOffset = scrollView.contentOffset
            let proposedX = scrollView.contentOffset.x + delta.x
            let proposedY = scrollView.contentOffset.y + delta.y
            let clampedX = min(max(proposedX, minOffsetX), maxOffsetX)
            let clampedY = min(max(proposedY, minOffsetY), maxOffsetY)

            let xChanged = abs(clampedX - currentOffset.x) > .ulpOfOne
            let yChanged = abs(clampedY - currentOffset.y) > .ulpOfOne
            guard xChanged || yChanged else {
                return .zero
            }

            let applied = CGPoint(x: clampedX - currentOffset.x, y: clampedY - currentOffset.y)
            let targetOffset = CGPoint(x: clampedX, y: clampedY)
            scrollView.setContentOffset(targetOffset, animated: false)
            return applied
        }

        private func findScrollTargets(startingAt view: UIView) -> (horizontal: UIScrollView?, vertical: UIScrollView?) {
            var current: UIView? = view.superview
            var bestHorizontal: UIScrollView?
            var bestVertical: UIScrollView?

            while let candidate = current {
                if let scrollView = candidate as? UIScrollView, scrollView.isScrollEnabled {
                    let horizontalRange = scrollView.contentSize.width - scrollView.bounds.width
                    if bestHorizontal == nil && horizontalRange > 1 {
                        bestHorizontal = scrollView
                    }

                    let verticalRange = scrollView.contentSize.height - scrollView.bounds.height
                    if bestVertical == nil && verticalRange > 1 {
                        bestVertical = scrollView
                    }

                    if bestHorizontal != nil && bestVertical != nil {
                        break
                    }
                }
                current = candidate.superview
            }

            return (bestHorizontal, bestVertical)
        }

        private var debugOccurrenceKey: String {
            if parent.debugOccurrenceID.isEmpty {
                return "none"
            }
            return parent.debugOccurrenceID
        }

        private func format(_ value: CGFloat) -> String {
            String(format: "%.2f", value)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Once promoted to manipulation, allow coexistence so no
            // other recognizer can cancel the active drag.
            hasPromotedManipulation
        }
    }
}

struct CalendarInterruptParentCompoundShape: Shape {
    let cornerRadius: CGFloat
    let visibleSegments: [CalendarInterruptParentVisibleSegment]

    func path(in rect: CGRect) -> Path {
        guard let firstSegment = visibleSegments.first else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)
        }

        var points: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX + firstSegment.width, y: rect.minY)
        ]

        for (index, segment) in visibleSegments.enumerated() {
            points.append(
                CGPoint(
                    x: rect.minX + segment.width,
                    y: rect.minY + segment.yEnd
                )
            )

            if index < visibleSegments.count - 1 {
                let next = visibleSegments[index + 1]
                if abs(next.width - segment.width) > 0.5 {
                    points.append(
                        CGPoint(
                            x: rect.minX + next.width,
                            y: rect.minY + segment.yEnd
                        )
                    )
                }
            }
        }

        points.append(CGPoint(x: rect.minX, y: rect.maxY))
        return calendarRoundedClosedPolygonPath(
            points: points,
            cornerRadius: cornerRadius
        )
    }
}

struct CalendarEventBlockInteractionShape: Shape {
    let compoundShape: CalendarInterruptParentCompoundShape?
    let cornerRadius: CGFloat
    /// Inward inset at the top and bottom of the block. Pairs with the
    /// matching inset on `ExtendedHitAreaView`: the UIView one closes the
    /// long-press capture, this one closes the SwiftUI tap-gesture capture
    /// (`onTapGesture` uses the contentShape for hit-testing). With only
    /// the UIView fix in place, SwiftUI still claims edge-band touches via
    /// the tap gesture and blocks fall-through to the day column's
    /// creation layer.
    var verticalEdgeInset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Same smoothstep curve as the UIView side — small / pinched-out
        // blocks fully drop their inset, large blocks get the full edge
        // band, eased in between. Lockstep with the UIView is enforced
        // by both sides routing through `calendarFallThroughEdgeInset`.
        let cappedInset = calendarFallThroughEdgeInset(
            maxInset: verticalEdgeInset,
            height: rect.height
        )
        let hitRect = cappedInset > 0 ? rect.insetBy(dx: 0, dy: cappedInset) : rect
        if let compoundShape {
            return compoundShape.path(in: hitRect)
        }
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: hitRect)
    }
}

/// Renders an event block in the timeline grid.
struct EventBlock: View {
    let event: Event
    var occurrenceID: String? = nil
    var dragSourceRange: Event.TimeRange? = nil
    var renderDayStart: Date = Date()
    let displayRange: Event.TimeRange?
    let color: Color
    /// Whether to show the small top-right corner indicator marking this
    /// event as carrying secondary types (experimental multi-type events
    /// feature). The indicator is a single fixed mono color that adapts
    /// to light/dark mode — the actual list of secondary type names is
    /// surfaced via the subtitle inside `content()`. False for ordinary
    /// single-type events.
    var showsMultiTypeIndicator: Bool = false
    let showText: Bool
    var isWeekMode: Bool = false
    var isThreeDayMode: Bool = false
    let style: EventBlockStyle
    // Reference-type holder for hourHeight; mutating its `.value` does not
    // invalidate this view, so pinch-driven hourHeight writes no longer
    // re-evaluate EventBlock.body.  Read at drag/resize time only.
    let liveHourHeight: CalendarHourHeightBox
    var dayColumnStep: CGFloat = 0
    var dragPreviewDayStep: CGFloat = 0
    var showsResizeHandles: Bool = false
    var resizeHandleOpacity: Double = 1
    var canMove: Bool = true
    var isFocused: Bool = false
    var isFocusContextActive: Bool = false
    var onTap: (() -> Void)? = nil
    var onLongPressBegan: ((EventDragMode, CGPoint, CGRect) -> Void)? = nil
    var onManipulationPromotion: ((EventDragMode, CGPoint, CGRect) -> Void)? = nil
    var onLongPressResolved: ((EventDragMode, EventDragTerminalState, Bool, CGPoint) -> Void)? = nil
    var onDragEnded: ((DragOffset) -> Void)? = nil
    var onResizeTopEnded: ((CGFloat) -> Void)? = nil    // Y offset for top edge
    var onResizeBottomEnded: ((CGFloat) -> Void)? = nil // Y offset for bottom edge
    var onHorizontalBoundaryPageRequest: ((Int) -> Bool)? = nil
    var canResizeTop: Bool = true
    var canResizeBottom: Bool = true
    var verticalDragBounds: ClosedRange<CGFloat> = -.infinity ... .infinity
    var isTimerActive: Bool = false
    var agenticProcessingPhase: AgenticIntakeProcessingPhase? = nil
    var interruptState: EventInterruptRelationState? = nil
    var interruptParentColor: Color? = nil
    var interruptIsCurrentlyEmbedded: Bool = false
    var interruptEmbeddedChildRanges: [Event.TimeRange] = []
    /// Time-range that maps 1:1 onto the rendered parent block's vertical
    /// span when a parent crosses the day boundary. The block is sliced to
    /// the day, but `displayRange` keeps the full multi-day extent for
    /// time-label correctness. Without a slice-aware range here, the
    /// compound cutouts compute progress against the full duration but
    /// project onto the sliced height, dropping notches in the wrong place
    /// (or on a day where no child even appears).
    var interruptCompoundParentRange: Event.TimeRange? = nil
    /// Time intervals (absolute dates, clipped to this occurrence's visible
    /// window) during which a higher-depth stack-peek sibling visually
    /// covers part of this block. The block converts each range to a y-band
    /// in its rendered height and treats the band like an extra cutout when
    /// computing the visible region for text — but unlike a real cutout, it
    /// does not reshape the block's silhouette (the parent rect stays
    /// rectangular; the overlay sits on top via z-order).
    var stackPeekCoverRanges: [Event.TimeRange] = []
    /// Horizontal offset (in points) at which a higher-depth sibling sits
    /// relative to this block's left edge. The visible region under a cover
    /// band shrinks to this width (the peek strip on the left). Zero
    /// disables the peek-band shrinkage.
    var stackPeekStripWidth: CGFloat = 0

    // External drag state for cross-day sync (when another occurrence of this event is being dragged)
    var dragState: EventDragState

    @State private var isFailedBadgeVisible = false
    @State private var isLongPressing = false
    @State private var isDragging = false
    @State private var isHorizontalEdgeDragging = false
    @State private var isHorizontalAutoScrolling = false
    @State private var dragOffset: DragOffset = .zero
    @State private var dragMode: EventDragMode = .move

    @AppStorage(AppSettingsKeys.calendarEventFontSize) private var titleFontSizeSetting: Double = Double(calendarEventTitleFontSizeDefault)
    @AppStorage(AppSettingsKeys.calendarEventShowTimeBelowTitle) private var showTimeBelowTitleSetting: Bool = true

    private var resolvedTitleFontSize: CGFloat {
        let raw = CGFloat(titleFontSizeSetting)
        return min(max(raw, 9), 16)
    }

    private var isPrimaryDragProjection: Bool {
        if isDragging {
            return true
        }
        guard dragState.draggingEventID == event.id,
              isActiveDraggedOccurrence(
                occurrenceID: occurrenceID,
                draggingOccurrenceID: dragState.draggingOccurrenceID,
                dragMode: dragState.dragMode
              ) else {
            return false
        }
        let primaryRenderDayStart = calendarResolvedPrimaryDragRenderDayStart(
            sourceDayStart: dragState.draggingRenderDayStart ?? dragState.draggingOriginalRange.map {
                Calendar.current.startOfDay(for: $0.start)
            },
            dragOffset: dragState.dragOffset,
            dayStep: dragPreviewDayStep,
            usesHorizontalBoundaryPaging: dayColumnStep <= 0 && dragPreviewDayStep > 0
        )
        if let primaryRenderDayStart {
            return Calendar.current.isDate(primaryRenderDayStart, inSameDayAs: renderDayStart)
        }
        return false
    }

    /// Whether this block should follow external drag (same event being dragged elsewhere)
    private var isFollowingExternalDrag: Bool {
        !isDragging
            && isPrimaryDragProjection
            && dragState.draggingEventID == event.id
            && isActiveDraggedOccurrence(
                occurrenceID: occurrenceID,
                draggingOccurrenceID: dragState.draggingOccurrenceID,
                dragMode: dragState.dragMode
            )
    }

    /// Effective offset to apply (either local drag or external sync)
    private var effectiveDragOffset: DragOffset {
        if isDragging {
            return dragOffset
        } else if isFollowingExternalDrag {
            return dragState.dragOffset
        }
        return .zero
    }

    /// Whether block is visually in drag state (long press, dragging, or synced)
    private var isInDragState: Bool {
        isLongPressing || isDragging || isFollowingExternalDrag
    }

    private var isDimmedByFocus: Bool {
        isFocusContextActive && !isFocused
    }

    private var currentDragMode: EventDragMode {
        if isDragging || isLongPressing {
            return dragMode
        }
        return dragState.dragMode
    }

    private var isAgenticAnalyzing: Bool {
        switch agenticProcessingPhase {
        case .queued, .analyzing:
            return true
        default:
            return false
        }
    }

    private var isAgenticFailed: Bool {
        agenticProcessingPhase == .failed
    }

    private var displayTitle: String {
        isAgenticFailed && isFailedBadgeVisible ? "⚠️ \(event.title)" : event.title
    }

    /// Subtitle shown beneath the title when the event carries secondary
    /// types. Lists all of the event's types, primary first, separated
    /// by middle dots. Reads from `event.effectiveTypes` so the order
    /// matches the canonical record (primary first, then extras in
    /// declared order). Only invoked from `content()` when
    /// `showsMultiTypeIndicator` is true, so this never renders for
    /// ordinary single-type events.
    private var multiTypeSubtitleText: String {
        let allTypes = event.effectiveTypes.filter { !$0.isEmpty }
        guard allTypes.count >= 2 else { return "" }
        return allTypes.joined(separator: " · ")
    }

    private var isInterruptEvent: Bool {
        event.isInterrupt
    }

    private var resolvedInterruptState: EventInterruptRelationState? {
        interruptState ?? event.interruptRelation?.state
    }

    private var interruptCornerRadius: CGFloat {
        isInterruptEvent ? 5 : 6
    }


    private var resolvedInterruptVisualMode: EventBlockInterruptVisualMode {
        calendarInterruptVisualMode(
            isInterruptEvent: isInterruptEvent,
            relationState: resolvedInterruptState,
            isCurrentlyEmbedded: interruptIsCurrentlyEmbedded,
            hasParentColor: interruptParentColor != nil
        )
    }

    private var isCompoundParentEvent: Bool {
        !interruptEmbeddedChildRanges.isEmpty
    }

    private func embeddedInterruptCardShape(cornerRadius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var blockFillOpacity: Double {
        style.fillOpacity
    }

    private var blockStrokeOpacity: Double {
        style.strokeOpacity
    }

    private var blockStrokeWidth: CGFloat {
        isInterruptEvent ? max(0.8, style.strokeWidth + 0.2) : style.strokeWidth
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return formatter
    }

    private var isDragEnabled: Bool {
        onDragEnded != nil || onResizeTopEnded != nil || onResizeBottomEnded != nil
    }

    /// 15-minute snap size in points
    private var snapSize: CGFloat { liveHourHeight.value / 4 }

    /// Drag offset snapped to 15-minute increments (only for resize modes)
    private var snappedResizeOffset: CGFloat {
        guard isDragging, dragMode != .move else { return 0 }
        return (dragOffset.y / snapSize).rounded() * snapSize
    }

    /// Adjusted height during resize drag
    private func resizeHeight(baseHeight: CGFloat) -> CGFloat {
        guard isDragging, dragMode != .move else { return baseHeight }
        let minHeight: CGFloat = 20
        switch dragMode {
        case .resizeTop:
            return max(minHeight, baseHeight - snappedResizeOffset)
        case .resizeBottom:
            return max(minHeight, baseHeight + snappedResizeOffset)
        case .move:
            return baseHeight
        }
    }

    /// Drag X offset for move mode.
    /// During auto-scroll the raw X offset (including scroll compensation)
    /// keeps the event block near the finger even as the page scrolls.
    private var moveOffsetX: CGFloat {
        let mode = currentDragMode
        guard isInDragState, mode == .move else { return 0 }
        return effectiveDragOffset.x
    }

    /// Display range adjusted by the current drag offset
    private var adjustedDisplayRange: Event.TimeRange? {
        guard let range = displayRange else { return nil }
        guard isInDragState else { return range }

        let dragBaseRange: Event.TimeRange
        switch currentDragMode {
        case .move:
            // Preserve the occurrence's full source range while moving so
            // cross-day previews render the real span in the floating block.
            dragBaseRange = dragSourceRange ?? range
        case .resizeTop, .resizeBottom:
            dragBaseRange = range
        }

        return calendarResolvedDragEditRange(
            draggingOriginalRange: dragBaseRange,
            dragOffset: effectiveDragOffset,
            dragMode: currentDragMode,
            hourHeight: liveHourHeight.value,
            dayColumnStep: currentDragMode == .move ? dragPreviewDayStep : 0
        ) ?? range
    }

    /// Y offset for the block during resizeTop drag
    private func resizeYOffset(baseHeight: CGFloat) -> CGFloat {
        guard isDragging, dragMode == .resizeTop else { return 0 }
        let minHeight = liveHourHeight.value / 2
        // Clamp so block doesn't shrink below minimum
        return min(snappedResizeOffset, baseHeight - minHeight)
    }

    private func syncSharedDragStateForBegin(mode: EventDragMode) {
        calendarDebugLog(
            "event.sharedDragState.begin",
            fields: [
                "eventID": event.id.uuidString,
                "mode": String(describing: mode)
            ]
        )
        dragState.draggingEventID = event.id
        dragState.draggingOccurrenceID = occurrenceID
        dragState.draggingEvent = event
        // Use the specific occurrence's full range when available.
        // This keeps multi-range events from switching to another range.
        dragState.draggingOriginalRange = dragSourceRange ?? event.primaryTimeRange
        dragState.draggingRenderDayStart = Calendar.current.startOfDay(for: renderDayStart)
        dragState.currentTouchPointGlobal = nil
        dragState.dragMode = mode
        dragState.dayColumnStep = dragPreviewDayStep
        dragState.isHorizontalEdgeDragging = false
        dragState.isHorizontalAutoScrolling = false
    }

    private func clearSharedDragState(reason: String) {
        calendarDebugLog(
            "event.sharedDragState.clear",
            fields: [
                "reason": reason,
                "eventID": event.id.uuidString
            ]
        )
        calendarResetSharedEventDragState(dragState)
    }

    var body: some View {
        // Rendered size is always sourced from GeometryReader: the parent
        // applies `.frame(width:height:)` to this view, and the GR reports
        // the post-modifier size.  Keeping the size out of EventBlock's
        // stored properties means pinch-driven height changes do NOT
        // change the View struct's identity — body re-evaluation skips
        // and SwiftUI re-runs only the GR's content closure with new geo.
        GeometryReader { geo in
            bodyContent(blockWidth: geo.size.width, blockHeight: geo.size.height)
        }
    }

    @ViewBuilder
    private func bodyContent(blockWidth: CGFloat, blockHeight: CGFloat) -> some View {
        let _ = 0 // ViewBuilder requires a statement before let bindings
        let baseHeight = blockHeight
        let renderedBlockHeight = resizeHeight(baseHeight: baseHeight)
            let shouldRenderCompoundParentShape = calendarShouldRenderCompoundInterruptParentShape(
                isCompoundParentEvent: isCompoundParentEvent,
                isInDragState: isInDragState,
                dragMode: currentDragMode
            )
            let needsMoat = resolvedInterruptVisualMode == .embeddedMoat
                || shouldRenderCompoundParentShape
            let horizontalMoat = needsMoat
                ? calendarInterruptMoatWidthHorizontal(
                    availableWidth: blockWidth,
                    availableHeight: renderedBlockHeight
                )
                : 0
            let verticalMoat = needsMoat
                ? calendarInterruptMoatWidthVertical(
                    availableWidth: blockWidth,
                    availableHeight: renderedBlockHeight
                )
                : 0
            let compoundGeometry: CalendarInterruptParentCompoundGeometry? = {
                guard shouldRenderCompoundParentShape,
                      let resolvedRange = adjustedDisplayRange else {
                    return nil
                }
                // Prefer the slice-aware range when supplied so multi-day
                // parents project cutouts onto the correct portion of the
                // rendered (sliced) height.
                let geometryParentRange = interruptCompoundParentRange ?? resolvedRange
                return calendarInterruptParentCompoundGeometry(
                    parentRange: geometryParentRange,
                    childRanges: interruptEmbeddedChildRanges,
                    parentWidth: blockWidth,
                    parentHeight: renderedBlockHeight,
                    horizontalGap: horizontalMoat,
                    verticalGap: verticalMoat
                )
            }()
            let compoundShape: CalendarInterruptParentCompoundShape? = {
                guard let geometry = compoundGeometry,
                      !geometry.cutouts.isEmpty else {
                    return nil
                }
                return CalendarInterruptParentCompoundShape(
                    cornerRadius: max(interruptCornerRadius, 6),
                    visibleSegments: geometry.visibleSegments
                )
            }()
            let gestureExcludedHitRects = compoundGeometry?.cutouts.map(\.rect) ?? []
            let topResizeHandlePlacement = calendarResizeHandlePlacement(
                viewWidth: blockWidth,
                compoundGeometry: compoundGeometry,
                edge: .top
            )
            let bottomResizeHandlePlacement = calendarResizeHandlePlacement(
                viewWidth: blockWidth,
                compoundGeometry: compoundGeometry,
                edge: .bottom
            )
            let usesNativeShapeMask = compoundShape != nil || resolvedInterruptVisualMode == .embeddedMoat
            // Augment the compound geometry's text-fitting view with stack-peek
            // cover bands. Cutouts on the geometry remain unchanged so the
            // shape mask, hit-test, and resize handle continue to use the
            // unaugmented `compoundGeometry`. Skip for interrupt children —
            // they render at child-overlay geometry and aren't covered.
            let textGeometry: CalendarInterruptParentCompoundGeometry? = {
                guard !isInterruptEvent,
                      !stackPeekCoverRanges.isEmpty,
                      stackPeekStripWidth > 0,
                      let resolvedRange = adjustedDisplayRange else {
                    return compoundGeometry
                }
                let geometryParentRange = interruptCompoundParentRange ?? resolvedRange
                return calendarStackPeekTextGeometry(
                    baseGeometry: compoundGeometry,
                    eventRange: geometryParentRange,
                    coverRanges: stackPeekCoverRanges,
                    parentWidth: blockWidth,
                    parentHeight: renderedBlockHeight,
                    peekStripWidth: stackPeekStripWidth
                )
            }()
            let baseVisual = content(
                availableWidth: blockWidth,
                availableHeight: renderedBlockHeight,
                compoundGeometry: textGeometry
            )
                .frame(
                    width: blockWidth,
                    height: renderedBlockHeight,
                    alignment: .topLeading
                )
                .background(
                    blockBackground(
                        usesNativeShapeMask: usesNativeShapeMask
                    )
                )
                .overlay {
                    if isTimerActive {
                        DiagonalHatchingPattern(spacing: 6, lineWidth: 1)
                            .stroke(color.opacity(0.3), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if isAgenticAnalyzing {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.05),
                                        Color.white.opacity(0.22),
                                        Color.white.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .opacity(isInDragState ? 0.08 : 0.18)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Multi-type corner: a small fixed-color triangle in
                    // the top-right corner marking this event as carrying
                    // secondary types. Uses `Color.primary` so it flips
                    // automatically between dark and light mode without
                    // needing to coordinate with the (variable) primary
                    // event-type color underneath. The mask further down
                    // clips it to the block's rounded shape, so it
                    // follows the corner radius. Conflicts with the
                    // agentic spinner overlay only while an event is
                    // actively processing — rare and mutually exclusive.
                    if showsMultiTypeIndicator {
                        MultiTypeCornerTriangle()
                            .fill(Color.primary.opacity(0.28))
                            .frame(width: 14, height: 14)
                            .allowsHitTesting(false)
                    }
                }

            baseVisual
                .mask {
                    blockVisualMask(
                        compoundShape: compoundShape,
                        embeddedChildCornerRadius: interruptCornerRadius
                    )
                }
                .overlay {
                    blockBorderOverlay(
                        compoundShape: compoundShape,
                        embeddedChildCornerRadius: interruptCornerRadius
                    )
                        .allowsHitTesting(false)
                }
                .overlay {
                    // Use opacity instead of conditional removal to keep the
                    // view tree structurally stable.  Changing the overlay
                    // structure (if → else) causes SwiftUI to tear down the
                    // sibling EventBlockDragGesture overlay mid-drag.
                    let showHandles = isDragEnabled && renderedBlockHeight >= 32 && calendarShouldShowResizeHandles(
                        style: style,
                        showsResizeHandles: showsResizeHandles,
                        isLongPressing: isLongPressing
                    )
                    let isResizingTop = isInDragState && currentDragMode == .resizeTop
                    let isResizingBottom = isInDragState && currentDragMode == .resizeBottom
                    ZStack(alignment: .topLeading) {
                        if canResizeTop {
                            let placement = topResizeHandlePlacement
                            let activeWidth = min(
                                max(placement.width, placement.availableWidth * 0.7),
                                max(placement.width, placement.availableWidth - 4)
                            )
                            Capsule()
                                .fill(color.opacity(isResizingTop ? 0.8 : 0.45 * resizeHandleOpacity))
                                .frame(width: isResizingTop ? activeWidth : placement.width, height: 3)
                                .position(
                                    x: placement.centerX,
                                    y: 5 + 1.5
                                )
                        }
                        if canResizeBottom {
                            let placement = bottomResizeHandlePlacement
                            let activeWidth = min(
                                max(placement.width, placement.availableWidth * 0.7),
                                max(placement.width, placement.availableWidth - 4)
                            )
                            Capsule()
                                .fill(color.opacity(isResizingBottom ? 0.8 : 0.45 * resizeHandleOpacity))
                                .frame(width: isResizingBottom ? activeWidth : placement.width, height: 3)
                                .position(
                                    x: placement.centerX,
                                    y: renderedBlockHeight - 5 - 1.5
                                )
                        }
                    }
                    .opacity(showHandles ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: isResizingTop)
                    .animation(.easeOut(duration: 0.2), value: isResizingBottom)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if isAgenticAnalyzing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(
                    width: blockWidth,
                    height: renderedBlockHeight
                )
                .scaleEffect(
                    calendarEventBlockScale(
                        isMoveDragging: isInDragState && currentDragMode == .move,
                        isFocused: isFocused && !(isInDragState && currentDragMode != .move),
                        isDimmedByFocus: isDimmedByFocus
                    )
                )
                .opacity(isDimmedByFocus ? 0.28 : 1.0)
                .shadow(radius: (isFocused || isInDragState) ? 3 : 0)
                // X offset follows finger during move drag; Y offset is only for resize
                // (move Y is handled by TimelineDayView's adjustedRange).
                .offset(x: currentDragMode == .move ? moveOffsetX : 0,
                        y: (isDragging && dragMode != .move ? resizeYOffset(baseHeight: baseHeight) : 0))
                .contentShape(
                    CalendarEventBlockInteractionShape(
                        compoundShape: compoundShape,
                        cornerRadius: interruptCornerRadius,
                        verticalEdgeInset: showsResizeHandles ? 0 : 6
                    )
                )
                .overlay {
                    if isDragEnabled {
                        EventBlockDragGesture(
                            verticalEdgeInset: showsResizeHandles ? 0 : 6,
                            snapSize: snapSize,
                            horizontalAutoScrollUnitStep: dragPreviewDayStep,
                            usesHorizontalBoundaryPaging: dayColumnStep <= 0 && dragPreviewDayStep > 0,
                            verticalDragBounds: verticalDragBounds,
                            excludedHitRects: gestureExcludedHitRects,
                            topResizeHandlePlacement: topResizeHandlePlacement,
                            bottomResizeHandlePlacement: bottomResizeHandlePlacement,
                            canMove: canMove,
                            canResizeTop: canResizeTop,
                            canResizeBottom: canResizeBottom,
                            debugEventID: event.id.uuidString,
                            debugOccurrenceID: occurrenceID ?? "",
                            onLongPressBegan: { mode, touchPointGlobal, viewFrameGlobal in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    isLongPressing = true
                                    dragMode = mode
                                }
                                onLongPressBegan?(mode, touchPointGlobal, viewFrameGlobal)
                            },
                            onManipulationPromotion: { mode, touchPointGlobal, viewFrameGlobal in
                                dragState.currentTouchPointGlobal = touchPointGlobal
                                onManipulationPromotion?(
                                    mode,
                                    touchPointGlobal,
                                    viewFrameGlobal
                                )
                            },
                            onDragBegan: { mode in
                                syncSharedDragStateForBegin(mode: mode)
                            },
                            onDragTouchChanged: { touchPointGlobal in
                                dragState.currentTouchPointGlobal = touchPointGlobal
                            },
                            onDragChanged: { offset in
                                // Sync immediately to shared drag state so there is
                                // no one-frame lag waiting for SwiftUI onChange.
                                dragState.dragOffset = offset
                            },
                            onDragEnded: { mode, offset in
                                switch mode {
                                case .move:
                                    onDragEnded?(offset)
                                case .resizeTop:
                                    onResizeTopEnded?(offset.y)
                                case .resizeBottom:
                                    onResizeBottomEnded?(offset.y)
                                }
                            },
                            onDragTerminal: { _, _, terminalState in
                                isLongPressing = false
                                clearSharedDragState(
                                    reason: "dragTerminal.\(String(describing: terminalState))"
                                )
                            },
                            onLongPressResolved: { mode, terminalState, didMove, touchPointGlobal in
                                isLongPressing = false
                                onLongPressResolved?(mode, terminalState, didMove, touchPointGlobal)
                            },
                            onHorizontalBoundaryPageRequest: onHorizontalBoundaryPageRequest,
                            isDragging: $isDragging,
                            isHorizontalEdgeDragging: $isHorizontalEdgeDragging,
                            isHorizontalAutoScrolling: $isHorizontalAutoScrolling,
                            dragOffset: $dragOffset,
                            dragMode: $dragMode
                        )
                    }
                }
                .onTapGesture { onTap?() }
                .animation(.easeInOut(duration: 0.15), value: isInDragState)
                .onDisappear {
                    isLongPressing = false
                }
                .onAppear {
                    if isAgenticFailed {
                        isFailedBadgeVisible = true
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            withAnimation(.easeOut(duration: 0.4)) {
                                isFailedBadgeVisible = false
                            }
                        }
                    }
                }
                .onChange(of: isAgenticFailed) { _, failed in
                    if failed {
                        isFailedBadgeVisible = true
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            withAnimation(.easeOut(duration: 0.4)) {
                                isFailedBadgeVisible = false
                            }
                        }
                    }
                }
                .onChange(of: isHorizontalEdgeDragging) { _, newValue in
                    if isDragging {
                        dragState.isHorizontalEdgeDragging = newValue
                    }
                }
                .onChange(of: isHorizontalAutoScrolling) { _, newValue in
                    if isDragging {
                        dragState.isHorizontalAutoScrolling = newValue
                    }
                }
                .onChange(of: dragMode) { _, newValue in
                    if isDragging {
                        dragState.dragMode = newValue
                    }
                }
    }

    @ViewBuilder
    private func blockBackground(
        usesNativeShapeMask: Bool
    ) -> some View {
        ZStack {
            if usesNativeShapeMask {
                Rectangle()
                    .fill(Color(.systemBackground))
                Rectangle()
                    .fill(color.opacity(blockFillOpacity))
            } else {
                RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)
                    .fill(Color(.systemBackground))
                RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)
                    .fill(color.opacity(blockFillOpacity))
            }
        }
    }

    @ViewBuilder
    private func blockVisualMask(
        compoundShape: CalendarInterruptParentCompoundShape?,
        embeddedChildCornerRadius: CGFloat
    ) -> some View {
        if let compoundShape {
            compoundShape
                .fill(Color.white)
        } else if resolvedInterruptVisualMode == .embeddedMoat {
            embeddedInterruptCardShape(cornerRadius: embeddedChildCornerRadius)
                .fill(Color.white)
        } else {
            RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)
                .fill(Color.white)
        }
    }

    @ViewBuilder
    private func blockBorderOverlay(
        compoundShape: CalendarInterruptParentCompoundShape?,
        embeddedChildCornerRadius: CGFloat
    ) -> some View {
        ZStack(alignment: .leading) {
            if let compoundShape {
                compoundShape
                    .stroke(color.opacity(blockStrokeOpacity), lineWidth: blockStrokeWidth)
            } else if resolvedInterruptVisualMode == .embeddedMoat {
                embeddedInterruptCardShape(cornerRadius: embeddedChildCornerRadius)
                    .stroke(color.opacity(blockStrokeOpacity), lineWidth: blockStrokeWidth)
            } else {
                RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)
                    .stroke(color.opacity(blockStrokeOpacity), lineWidth: blockStrokeWidth)
            }

            // Effort left bar — width scales with colorDepth (0.2–1.0); thinner in week mode.
            // Rendered as the full block shape filled with color, then masked to a
            // leading strip of `barWidth` so the top/bottom follow the block's
            // rounded corners instead of poking out past them.
            if event.colorDepth > 0 {
                let barWidth: CGFloat = isWeekMode
                    ? 1.0 + event.colorDepth * 1.5  // 1.3pt → 2.5pt in 7-day
                    : 1.5 + event.colorDepth * 2.5  // 1.7pt → 4pt otherwise
                Rectangle()
                    .fill(color)
                    .mask {
                        blockVisualMask(
                            compoundShape: compoundShape,
                            embeddedChildCornerRadius: embeddedChildCornerRadius
                        )
                    }
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: barWidth)
                    }
            }
        }
    }

    @ViewBuilder
    private func content(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        content(
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            compoundGeometry: nil
        )
    }

    @ViewBuilder
    private func content(
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        compoundGeometry: CalendarInterruptParentCompoundGeometry?
    ) -> some View {
        let titleFontSize = resolvedTitleFontSize
        let textLayout: CalendarEventTextLayout? = {
            guard showText else { return nil }
            if let compoundGeometry, !isInterruptEvent {
                return calendarInterruptParentTextLayout(
                    geometry: compoundGeometry,
                    title: displayTitle,
                    styleShowTimeRange: style.showTimeRange,
                    isWeekMode: isWeekMode,
                    isThreeDayMode: isThreeDayMode,
                    baseFontSize: titleFontSize,
                    showTimeBelowTitle: showTimeBelowTitleSetting
                )
            }
            return calendarEventTextLayout(
                in: CGRect(origin: .zero, size: CGSize(width: availableWidth, height: availableHeight)),
                title: displayTitle,
                requireTitleFit: false,
                styleShowTimeRange: style.showTimeRange,
                isWeekMode: isWeekMode,
                isThreeDayMode: isThreeDayMode,
                baseFontSize: titleFontSize,
                showTimeBelowTitle: showTimeBelowTitleSetting
            )
        }()

        if let textLayout {
            let timeFontSize = calendarEventTimeFontSize(
                forTitleFontSize: titleFontSize,
                isWeekMode: textLayout.isWeekMode
            )
            let titleSpacing = calendarEventBlockTitleSpacing(
                isWeekMode: textLayout.isWeekMode,
                isThreeDayMode: textLayout.isThreeDayMode
            )
            VStack(alignment: .leading, spacing: titleSpacing) {
                Text(displayTitle)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(textLayout.titleLineLimit)
                    .multilineTextAlignment(.leading)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Multi-type subtitle: lists all the event's types,
                // primary first. Sits directly under the title (above
                // the time range) so the type breakdown reads as a
                // continuation of the title rather than a footnote.
                // Gated via `showsMultiTypeIndicator` so the call site's
                // feature-flag check is the single source of truth.
                // Normal text color knocked down via opacity gives a
                // clean title > subtitle > time hierarchy without
                // introducing a third hue. Clipped naturally by the
                // parent contentRect frame on small blocks — short
                // events just show the corner indicator alone.
                if showsMultiTypeIndicator {
                    Text(multiTypeSubtitleText)
                        .font(.system(size: timeFontSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .opacity(0.55)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if textLayout.showsTimeRange,
                   let range = adjustedDisplayRange {
                    Text("\(Self.timeFormatter.string(from: range.start)) - \(Self.timeFormatter.string(from: range.end))")
                        .font(.system(size: timeFontSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(
                width: textLayout.contentRect.width,
                height: textLayout.contentRect.height,
                alignment: textLayout.verticalCenter ? .leading : .topLeading
            )
            .offset(
                x: textLayout.contentRect.minX,
                y: textLayout.contentRect.minY
            )
        } else {
            Color.clear
        }
    }

}

/// Right-isoceles triangle anchored to the top-right of its frame, used
/// by `EventBlock` to mark multi-type events. The right-angle vertex
/// sits at the frame's top-right; the hypotenuse runs from the top-left
/// to the bottom-right of the frame. Painted before the block's mask in
/// `EventBlock` so it inherits the rounded-corner clipping for free.
private struct MultiTypeCornerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
