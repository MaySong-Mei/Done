//
//  TimelineEditMapping.swift
//  Done
//
//  Shared edit-state mapping model used by timeline axis markers.
//

import SwiftUI

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
}

func calendarEventBlockScale(
    isMoveDragging: Bool,
    isFocused: Bool,
    isDimmedByFocus: Bool
) -> CGFloat {
    _ = isDimmedByFocus
    if isMoveDragging {
        return 1.02
    }
    if isFocused {
        return 1.01
    }
    return 1
}

func calendarResolvedDragEditRange(
    draggingOriginalRange: Event.TimeRange?,
    dragOffset: DragOffset,
    dragMode: EventDragMode,
    hourHeight: CGFloat,
    isHorizontalEdgeDragging: Bool = false,
    isHorizontalAutoScrolling: Bool = false,
    snapIntervalSeconds: TimeInterval = 15 * 60,
    calendar: Calendar = .current
) -> Event.TimeRange? {
    guard let range = draggingOriginalRange else { return nil }
    guard hourHeight > 0 else { return range }

    switch dragMode {
    case .move:
        let rawOffsetSeconds = TimeInterval(dragOffset.y / hourHeight * 3600)
        let disableTimeslotSnap = calendarShouldDisableTimeslotSnap(
            isHorizontalEdgeDragging: isHorizontalEdgeDragging,
            isHorizontalAutoScrolling: isHorizontalAutoScrolling
        )
        let resolvedOffsetSeconds = calendarPreviewOffsetSeconds(
            rawOffsetSeconds: rawOffsetSeconds,
            range: range,
            isHorizontalAutoScrolling: disableTimeslotSnap,
            snapIntervalSeconds: snapIntervalSeconds,
            calendar: calendar
        )
        return Event.TimeRange(
            start: range.start.addingTimeInterval(resolvedOffsetSeconds),
            end: range.end.addingTimeInterval(resolvedOffsetSeconds)
        )

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
    collapseThreshold: CGFloat = 20,
    calendar: Calendar = .current
) -> TimelineAxisMarkerPresentation? {
    guard let mappingState else { return nil }
    guard hourHeight > 0 else { return nil }

    let dayStart = calendar.startOfDay(for: mappingState.anchorDate)
    let minY = headerHeight
    let maxY = headerHeight + CGFloat(24) * hourHeight

    let startY = clamp(
        headerHeight + CGFloat(mappingState.range.start.timeIntervalSince(dayStart) / 3600) * hourHeight,
        minY,
        maxY
    )
    let endY = clamp(
        headerHeight + CGFloat(mappingState.range.end.timeIntervalSince(dayStart) / 3600) * hourHeight,
        minY,
        maxY
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

private let calendarAxisMarkerFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
}()
