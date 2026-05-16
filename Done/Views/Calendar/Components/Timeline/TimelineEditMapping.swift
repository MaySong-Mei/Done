//
//  TimelineEditMapping.swift
//  Done
//
//  Shared edit-state mapping model used by timeline axis markers.
//

import SwiftUI

let calendarTimelineBaseVisibleHours = 24
let calendarTimelineMaximumBoundaryExtensionHours = 12

// Reference-type holder for the live hourHeight value.  Threaded down to
// EventBlock so that deep callers can read the current value without
// hourHeight becoming a stored property whose changes invalidate the View
// struct.  Mutating `value` does NOT trigger SwiftUI re-evaluation; callers
// that need to redraw on hourHeight changes must observe the SwiftUI state
// channel (calendarState.timelineHourHeight) separately.
//
// In practice EventBlock reads `value` only inside drag/resize math, which
// runs while isDragging is true.  Pinch and drag are mutually exclusive
// gestures (two-finger vs single-finger long-press), so reads happen with
// a stable, pinch-ended value.
final class CalendarHourHeightSource {
    var value: CGFloat
    init(_ initialValue: CGFloat = 56) {
        self.value = initialValue
    }
}

enum TimelineEditMappingSource: Equatable {
    case focused
    case moveDrag
    case resizeTop
    case resizeBottom
    case creation
}

struct TimelineEditMappingState: Equatable {
    let source: TimelineEditMappingSource
    let anchorDate: Date
    let range: Event.TimeRange
}

struct TimelineAxisMarkerPresentation: Equatable {
    let startY: CGFloat
    let endY: CGFloat
    let startText: String
    let endText: String
    let collapsedText: String?
    let isCollapsed: Bool
    var color: Color?
}

struct TimelineBoundaryExtensionState: Equatable {
    let leadingHours: Int
    let trailingHours: Int
    let source: TimelineEditMappingSource?
    /// Which day column triggered the extension, expressed as an offset
    /// from the pager's selected day (e.g. 0 = center/selected day,
    /// -1 = one day earlier, +1 = one day later). Used by the date
    /// marker to align with the correct column in 3-day/week mode.
    var anchorDayOffset: Int? = nil

    var hasAnyExtension: Bool {
        leadingHours > 0 || trailingHours > 0
    }

    static let none = TimelineBoundaryExtensionState(
        leadingHours: 0,
        trailingHours: 0,
        source: nil,
        anchorDayOffset: nil
    )
}

func calendarTimelineTotalVisibleHours(
    leadingExtendedHours: Int = 0,
    trailingExtendedHours: Int = 0
) -> Int {
    calendarTimelineBaseVisibleHours + max(0, leadingExtendedHours) + max(0, trailingExtendedHours)
}

func calendarTimelineVisibleStart(
    containing date: Date,
    leadingExtendedHours: Int = 0,
    calendar: Calendar = .current
) -> Date {
    let dayStart = calendar.startOfDay(for: date)
    return dayStart.addingTimeInterval(TimeInterval(-max(0, leadingExtendedHours) * 3600))
}

func calendarTimelineVisibleEnd(
    containing date: Date,
    trailingExtendedHours: Int = 0,
    calendar: Calendar = .current
) -> Date {
    let dayStart = calendar.startOfDay(for: date)
    return dayStart.addingTimeInterval(
        TimeInterval((calendarTimelineBaseVisibleHours + max(0, trailingExtendedHours)) * 3600)
    )
}

// Height of the event area (excluding header / bottom inset) = total visible
// hours × hourHeight.  Surfaces the "container height" concept so callers can
// express event positions as fractions of this height (set up for percent-of-
// parent layout that decouples per-event re-evaluation from hourHeight writes).
func calendarTimelineContentHeight(
    hourHeight: CGFloat,
    leadingExtendedHours: Int = 0,
    trailingExtendedHours: Int = 0
) -> CGFloat {
    let totalVisibleHours = calendarTimelineTotalVisibleHours(
        leadingExtendedHours: leadingExtendedHours,
        trailingExtendedHours: trailingExtendedHours
    )
    return CGFloat(totalVisibleHours) * hourHeight
}

// Fraction of the visible content window where `date` sits, clamped to [0, 1].
// Equivalent to `(date − visibleStart) / totalVisibleSeconds`.
func calendarTimelineYFraction(
    for date: Date,
    containing anchorDate: Date,
    leadingExtendedHours: Int = 0,
    trailingExtendedHours: Int = 0,
    calendar: Calendar = .current
) -> CGFloat {
    let visibleStart = calendarTimelineVisibleStart(
        containing: anchorDate,
        leadingExtendedHours: leadingExtendedHours,
        calendar: calendar
    )
    let totalVisibleHours = calendarTimelineTotalVisibleHours(
        leadingExtendedHours: leadingExtendedHours,
        trailingExtendedHours: trailingExtendedHours
    )
    let totalSeconds = TimeInterval(totalVisibleHours * 3600)
    guard totalSeconds > 0 else { return 0 }
    let raw = CGFloat(date.timeIntervalSince(visibleStart) / totalSeconds)
    return min(max(0, raw), 1)
}

// Fraction of the visible content window represented by `seconds`.  Not
// clamped to ≤ 1: dragged blocks may legitimately project beyond the visible
// window during a drag, and the caller decides what to do with the overshoot.
func calendarTimelineDurationFraction(
    seconds: TimeInterval,
    leadingExtendedHours: Int = 0,
    trailingExtendedHours: Int = 0
) -> CGFloat {
    let totalVisibleHours = calendarTimelineTotalVisibleHours(
        leadingExtendedHours: leadingExtendedHours,
        trailingExtendedHours: trailingExtendedHours
    )
    let totalSeconds = TimeInterval(totalVisibleHours * 3600)
    guard totalSeconds > 0 else { return 0 }
    return CGFloat(max(0, seconds) / totalSeconds)
}

func calendarTimelineBoundaryExtensionHours(
    mappingState: TimelineEditMappingState?,
    maxExtensionHours: Int = calendarTimelineMaximumBoundaryExtensionHours,
    calendar: Calendar = .current
) -> (leading: Int, trailing: Int) {
    guard let mappingState else { return (0, 0) }
    let dayStart = calendar.startOfDay(for: mappingState.anchorDate)
    let baseVisibleEnd = dayStart.addingTimeInterval(TimeInterval(calendarTimelineBaseVisibleHours * 3600))
    let clampedMaxHours = max(0, maxExtensionHours)

    // During an active drag/resize, trigger the extension 2 hours
    // BEFORE the event actually crosses the boundary. This gives the
    // user anticipatory feedback and prevents the "stuck at the edge"
    // problem for cross-day events starting far from midnight.
    let anticipation: TimeInterval
    switch mappingState.source {
    case .moveDrag, .resizeTop, .resizeBottom:
        anticipation = TimeInterval(2 * 3600)
    default:
        anticipation = 0
    }

    let hasLeadingBoundaryCrossing = mappingState.range.start < dayStart + anticipation
    let hasTrailingBoundaryCrossing = mappingState.range.end > baseVisibleEnd - anticipation

    return (
        hasLeadingBoundaryCrossing ? clampedMaxHours : 0,
        hasTrailingBoundaryCrossing ? clampedMaxHours : 0
    )
}

func calendarTimelineYPosition(
    for date: Date,
    containing anchorDate: Date,
    headerHeight: CGFloat,
    hourHeight: CGFloat,
    leadingExtendedHours: Int = 0,
    trailingExtendedHours: Int = 0,
    calendar: Calendar = .current
) -> CGFloat {
    let visibleStart = calendarTimelineVisibleStart(
        containing: anchorDate,
        leadingExtendedHours: leadingExtendedHours,
        calendar: calendar
    )
    let totalVisibleHours = calendarTimelineTotalVisibleHours(
        leadingExtendedHours: leadingExtendedHours,
        trailingExtendedHours: trailingExtendedHours
    )
    let minY = headerHeight
    let maxY = headerHeight + CGFloat(totalVisibleHours) * hourHeight
    let y = headerHeight + CGFloat(date.timeIntervalSince(visibleStart) / 3600) * hourHeight
    return clamp(y, minY, maxY)
}

func calendarTimelineDateFromYPosition(
    _ y: CGFloat,
    containing anchorDate: Date,
    headerHeight: CGFloat,
    hourHeight: CGFloat,
    leadingExtendedHours: Int = 0,
    trailingExtendedHours: Int = 0,
    snapMinutes: Int = 15,
    maxBoundaryExtensionHours: Int = calendarTimelineMaximumBoundaryExtensionHours,
    calendar: Calendar = .current
) -> Date {
    guard hourHeight > 0 else {
        return calendarTimelineVisibleStart(
            containing: anchorDate,
            leadingExtendedHours: leadingExtendedHours,
            calendar: calendar
        )
    }

    let effectiveSnapMinutes = max(1, snapMinutes)
    let visibleStart = calendarTimelineVisibleStart(
        containing: anchorDate,
        leadingExtendedHours: leadingExtendedHours,
        calendar: calendar
    )
    let visibleEnd = calendarTimelineVisibleEnd(
        containing: anchorDate,
        trailingExtendedHours: trailingExtendedHours,
        calendar: calendar
    )
    let minimumBoundaryStart = calendarTimelineVisibleStart(
        containing: anchorDate,
        leadingExtendedHours: maxBoundaryExtensionHours,
        calendar: calendar
    )
    let maximumBoundaryEnd = calendarTimelineVisibleEnd(
        containing: anchorDate,
        trailingExtendedHours: maxBoundaryExtensionHours,
        calendar: calendar
    )
    let allowedStart = min(visibleStart, minimumBoundaryStart)
    let allowedEnd = max(visibleEnd, maximumBoundaryEnd)

    let totalMinutes = (y - headerHeight) / hourHeight * 60
    let snappedMinutes = round(totalMinutes / Double(effectiveSnapMinutes)) * Double(effectiveSnapMinutes)
    let resolvedDate = visibleStart.addingTimeInterval(snappedMinutes * 60)

    if resolvedDate < allowedStart {
        return allowedStart
    }
    if resolvedDate > allowedEnd {
        return allowedEnd
    }
    return resolvedDate
}

func calendarEventBlockScale(
    isMoveDragging: Bool,
    isFocused: Bool,
    isDimmedByFocus: Bool
) -> CGFloat {
    _ = isDimmedByFocus
    return 1
}

/// Snap an absolute date to the nearest minute-grid mark. Round-to-nearest
/// matches the calendar's drag/resize convention so events created or
/// edited from any surface (timeline drag, focus mode quick actions, etc.)
/// land on the same 15-minute boundaries. The 15-min grid is the app's
/// core time-discretization philosophy — surfaces that mutate event
/// boundaries should honor it without exception. (Notes and other
/// instantaneous markers are deliberately *not* snapped.)
func calendarSnapDateToMinuteGrid(_ date: Date, granularityMinutes: Int = 15) -> Date {
    let granularitySeconds = TimeInterval(max(1, granularityMinutes) * 60)
    let interval = date.timeIntervalSinceReferenceDate
    let snapped = (interval / granularitySeconds).rounded() * granularitySeconds
    return Date(timeIntervalSinceReferenceDate: snapped)
}

/// Magnetic snap of a creation candidate time to the nearest neighbor event edge.
///
/// `candidateTime` is the post-grid-snap value (e.g. rounded to 15-min) and
/// `rawTime` is the unrounded mapping of the touch's Y. We test the magnetic
/// threshold against `rawTime` so a 15-min round doesn't push the candidate
/// out of the magnetic zone before we get to look at it.
///
/// Returns the time to use plus an optional flag identifying *which* neighbor
/// edge was snapped to (nil when no snap engaged). The flag is used by the
/// caller to drive haptic feedback only on snap transitions.
func calendarApplyAdjacentEventSnap(
    candidateTime: Date,
    rawTime: Date,
    neighborEdges: [Date],
    thresholdSeconds: TimeInterval
) -> (snappedTime: Date, snappedEdge: Date?) {
    guard thresholdSeconds > 0 else { return (candidateTime, nil) }
    var bestEdge: Date?
    var bestDist = thresholdSeconds
    for edge in neighborEdges {
        let dist = abs(edge.timeIntervalSince(rawTime))
        if dist <= bestDist {
            bestDist = dist
            bestEdge = edge
        }
    }
    if let edge = bestEdge {
        return (edge, edge)
    }
    return (candidateTime, nil)
}

func calendarResolvedDragEditRange(
    draggingOriginalRange: Event.TimeRange?,
    dragOffset: DragOffset,
    dragMode: EventDragMode,
    hourHeight: CGFloat,
    dayColumnStep: CGFloat = 0,
    snapIntervalSeconds: TimeInterval = 15 * 60,
    calendar: Calendar = .current
) -> Event.TimeRange? {
    guard let range = draggingOriginalRange else { return nil }
    guard hourHeight > 0 else { return range }

    switch dragMode {
    case .move:
        let rawOffsetSeconds = TimeInterval(dragOffset.y / hourHeight * 3600)
        let resolvedOffsetSeconds = calendarPreviewOffsetSeconds(
            rawOffsetSeconds: rawOffsetSeconds,
            range: range,
            snapIntervalSeconds: snapIntervalSeconds,
            calendar: calendar
        )
        var newStart = range.start.addingTimeInterval(resolvedOffsetSeconds)
        var newEnd = range.end.addingTimeInterval(resolvedOffsetSeconds)

        let dayOffset = calendarDayOffsetFromHorizontalDrag(
            offsetX: dragOffset.x,
            dayColumnStep: dayColumnStep
        )
        if dayOffset != 0 {
            newStart = calendar.date(byAdding: .day, value: dayOffset, to: newStart) ?? newStart
            newEnd = calendar.date(byAdding: .day, value: dayOffset, to: newEnd) ?? newEnd
        }

        return Event.TimeRange(start: newStart, end: newEnd)

    case .resizeTop:
        let snapSize = hourHeight / 4
        guard snapSize > 0 else { return range }
        let snappedYOffset = (dragOffset.y / snapSize).rounded() * snapSize
        let offsetSeconds = TimeInterval(snappedYOffset / hourHeight * 3600)
        let newStart = range.start.addingTimeInterval(offsetSeconds)
        guard newStart < range.end else { return range }
        return Event.TimeRange(start: newStart, end: range.end)

    case .resizeBottom:
        let snapSize = hourHeight / 4
        guard snapSize > 0 else { return range }
        let snappedYOffset = (dragOffset.y / snapSize).rounded() * snapSize
        let offsetSeconds = TimeInterval(snappedYOffset / hourHeight * 3600)
        let newEnd = range.end.addingTimeInterval(offsetSeconds)
        guard newEnd > range.start else { return range }
        return Event.TimeRange(start: range.start, end: newEnd)
    }
}

func calendarDayOffsetFromHorizontalDrag(
    offsetX: CGFloat,
    dayColumnStep: CGFloat
) -> Int {
    guard dayColumnStep > 0 else { return 0 }
    return Int((offsetX / dayColumnStep).rounded())
}


func calendarResolvedFocusedEditRange(
    focusedEventID: UUID?,
    focusedOccurrenceID: String?,
    visibleOffsets: [Int],
    occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence],
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> (date: Date, range: Event.TimeRange)? {
    guard let focusedEventID else { return nil }

    let baseDate = calendar.startOfDay(for: referenceDate)
    let orderedOffsets = visibleOffsets.sorted()

    if let focusedOccurrenceID {
        for offset in orderedOffsets {
            for occurrence in occurrencesForOffset(offset)
            where occurrence.event.id == focusedEventID && occurrence.id == focusedOccurrenceID {
                let date = calendar.date(byAdding: .day, value: offset, to: baseDate) ?? baseDate
                return (date, occurrence.range)
            }
        }
    }

    for offset in orderedOffsets {
        if let occurrence = occurrencesForOffset(offset).first(where: { $0.event.id == focusedEventID }) {
            let date = calendar.date(byAdding: .day, value: offset, to: baseDate) ?? baseDate
            return (date, occurrence.range)
        }
    }

    return nil
}

func calendarResolveEditMappingState(
    creation: (date: Date, range: Event.TimeRange)?,
    drag: (source: TimelineEditMappingSource, date: Date, range: Event.TimeRange)?,
    focused: (date: Date, range: Event.TimeRange)?
) -> TimelineEditMappingState? {
    if let creation {
        return TimelineEditMappingState(
            source: .creation,
            anchorDate: creation.date,
            range: creation.range
        )
    }

    if let drag {
        return TimelineEditMappingState(
            source: drag.source,
            anchorDate: drag.date,
            range: drag.range
        )
    }

    if let focused {
        return TimelineEditMappingState(
            source: .focused,
            anchorDate: focused.date,
            range: focused.range
        )
    }

    return nil
}

func calendarResolvedCreationEditMapping(
    creationPreviewByDay: [Int: Event.TimeRange],
    selectedDayOffset: Int,
    pendingCreate: PendingEventCreation?,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> (date: Date, range: Event.TimeRange)? {
    if let nearest = creationPreviewByDay.min(
        by: { abs($0.key - selectedDayOffset) < abs($1.key - selectedDayOffset) }
    ) {
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let anchorDate = calendar.date(byAdding: .day, value: nearest.key, to: referenceDay) ?? referenceDay
        return (anchorDate, nearest.value)
    }

    guard let pendingCreate, pendingCreate.source == .dragCreate else {
        return nil
    }

    return (calendar.startOfDay(for: pendingCreate.date), pendingCreate.timeRange)
}

func calendarResolveBoundaryExtensionMappingState(
    creation: (date: Date, range: Event.TimeRange)?,
    drag: (source: TimelineEditMappingSource, date: Date, range: Event.TimeRange)?
) -> TimelineEditMappingState? {
    if let creation {
        return TimelineEditMappingState(
            source: .creation,
            anchorDate: creation.date,
            range: creation.range
        )
    }

    if let drag {
        return TimelineEditMappingState(
            source: drag.source,
            anchorDate: drag.date,
            range: drag.range
        )
    }

    return nil
}

func calendarResolvedDragAnchorDate(
    draggingOriginalRange: Event.TimeRange?,
    dragOffset: DragOffset,
    dragMode: EventDragMode,
    dayColumnStep: CGFloat = 0,
    calendar: Calendar = .current
) -> Date? {
    guard let draggingOriginalRange else { return nil }
    let sourceDay = calendar.startOfDay(for: draggingOriginalRange.start)

    guard dragMode == .move, dayColumnStep > 0 else {
        return sourceDay
    }

    let dayOffset = calendarDayOffsetFromHorizontalDrag(
        offsetX: dragOffset.x,
        dayColumnStep: dayColumnStep
    )
    return calendar.date(byAdding: .day, value: dayOffset, to: sourceDay) ?? sourceDay
}

func calendarShouldCollapseAxisMarkers(
    distance: CGFloat,
    threshold: CGFloat
) -> Bool {
    guard distance.isFinite, threshold.isFinite else { return false }
    return max(0, distance) <= max(0, threshold)
}

func calendarResolveAxisMarkerPresentation(
    mappingState: TimelineEditMappingState?,
    headerHeight: CGFloat,
    hourHeight: CGFloat,
    leadingExtendedHours: Int = 0,
    trailingExtendedHours: Int = 0,
    collapseThreshold: CGFloat = 10,
    calendar: Calendar = .current
) -> TimelineAxisMarkerPresentation? {
    guard let mappingState else { return nil }
    guard hourHeight > 0 else { return nil }

    let startY = calendarTimelineYPosition(
        for: mappingState.range.start,
        containing: mappingState.anchorDate,
        headerHeight: headerHeight,
        hourHeight: hourHeight,
        leadingExtendedHours: leadingExtendedHours,
        trailingExtendedHours: trailingExtendedHours,
        calendar: calendar
    )
    let endY = calendarTimelineYPosition(
        for: mappingState.range.end,
        containing: mappingState.anchorDate,
        headerHeight: headerHeight,
        hourHeight: hourHeight,
        leadingExtendedHours: leadingExtendedHours,
        trailingExtendedHours: trailingExtendedHours,
        calendar: calendar
    )

    let startText = calendarAxisMarkerTimeText(for: mappingState.range.start)
    let endText = calendarAxisMarkerTimeText(for: mappingState.range.end)
    let markerDistance = abs(endY - startY)
    let isCollapsed = calendarShouldCollapseAxisMarkers(
        distance: markerDistance,
        threshold: collapseThreshold
    )

    return TimelineAxisMarkerPresentation(
        startY: startY,
        endY: endY,
        startText: startText,
        endText: endText,
        collapsedText: isCollapsed ? "\(startText) - \(endText)" : nil,
        isCollapsed: isCollapsed
    )
}

private func calendarAxisMarkerTimeText(for date: Date) -> String {
    calendarAxisMarkerFormatter.string(from: date)
}

private var calendarAxisMarkerFormatter: DateFormatter {
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
