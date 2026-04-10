//
//  TimelineEditMapping.swift
//  Done
//
//  Shared edit-state mapping model used by timeline axis markers.
//

import SwiftUI

let calendarTimelineBaseVisibleHours = 24
let calendarTimelineMaximumBoundaryExtensionHours = 12

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

    var hasAnyExtension: Bool {
        leadingHours > 0 || trailingHours > 0
    }

    static let none = TimelineBoundaryExtensionState(
        leadingHours: 0,
        trailingHours: 0,
        source: nil
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
