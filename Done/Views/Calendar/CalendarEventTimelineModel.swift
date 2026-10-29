//
//  CalendarEventTimelineModel.swift
//  Done
//
//  The event detail's timeline math — live/manual mode, progress <-> date,
//  note snapping, drag resolution — and the interrupt items it draws.
//  Pure, shared by the phone's detail and the Mac inspector (moved verbatim
//  from CalendarEventDetailView.swift).
//

import SwiftUI

let calendarEventTimelineIdleAutoResumeInterval: TimeInterval = 30

enum CalendarEventTimelineMode: Equatable {
    case live
    case manual
}

enum CalendarEventTimelineFeedback: Equatable {
    case none
    case selection
    case noteSnap
    case resumeLive
}

struct CalendarEventTimelineResolvedState: Equatable {
    var mode: CalendarEventTimelineMode
    var displayProgress: CGFloat
    var snapshotDate: Date
}

struct CalendarEventTimelineDragResolution: Equatable {
    var mode: CalendarEventTimelineMode
    var progress: CGFloat
    var snapshotDate: Date
    var isSnappedToNote: Bool
    var selectedMinute: Int
    var feedback: CalendarEventTimelineFeedback
}

func calendarEventTimelineProgress(
    for snapshotDate: Date,
    range: Event.TimeRange
) -> CGFloat {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0 else { return 0 }
    let raw = snapshotDate.timeIntervalSince(range.start) / duration
    return CGFloat(min(max(raw, 0), 1))
}

func calendarEventTimelineSnapshotDate(
    for progress: CGFloat,
    range: Event.TimeRange
) -> Date {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0 else { return range.start }
    let clamped = min(max(progress, 0), 1)
    return range.start.addingTimeInterval(duration * Double(clamped))
}

func calendarEventTimelineTrackMinute(
    progress: CGFloat,
    range: Event.TimeRange
) -> Int {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0 else { return 0 }
    let clamped = min(max(progress, 0), 1)
    return Int(duration * Double(clamped) / 60)
}

func calendarEventTimelineLiveProgress(
    now: Date,
    range: Event.TimeRange
) -> CGFloat {
    calendarEventTimelineProgress(for: now, range: range)
}

func calendarEventTimelineTrackNotes(
    from notes: [EventLogTimelineNote],
    range: Event.TimeRange
) -> [EventLogTimelineNote] {
    notes
}

func calendarEventTimelineCanResumeLive(
    progress: CGFloat,
    now: Date,
    range: Event.TimeRange,
    tolerance: TimeInterval = 60
) -> Bool {
    guard now >= range.start && now <= range.end else { return false }
    let manualDate = calendarEventTimelineSnapshotDate(for: progress, range: range)
    return abs(manualDate.timeIntervalSince(now)) <= tolerance
}

func calendarEventTimelineShouldAutoResumeLive(
    mode: CalendarEventTimelineMode,
    lastInteractionAt: Date?,
    now: Date,
    idleTimeout: TimeInterval = calendarEventTimelineIdleAutoResumeInterval
) -> Bool {
    guard mode == .manual,
          idleTimeout > 0,
          let lastInteractionAt else {
        return false
    }
    return now.timeIntervalSince(lastInteractionAt) >= idleTimeout
}

func calendarEventTimelineResolvedState(
    mode: CalendarEventTimelineMode,
    manualProgress: CGFloat,
    now: Date,
    range: Event.TimeRange
) -> CalendarEventTimelineResolvedState {
    switch mode {
    case .live:
        return CalendarEventTimelineResolvedState(
            mode: .live,
            displayProgress: calendarEventTimelineLiveProgress(now: now, range: range),
            snapshotDate: now
        )
    case .manual:
        let progress = min(max(manualProgress, 0), 1)
        return CalendarEventTimelineResolvedState(
            mode: .manual,
            displayProgress: progress,
            snapshotDate: calendarEventTimelineSnapshotDate(for: progress, range: range)
        )
    }
}

func calendarEventTimelineSnapProgress(
    rawProgress: CGFloat,
    notes: [EventLogTimelineNote],
    range: Event.TimeRange,
    snapWindow: TimeInterval = 2 * 60
) -> CGFloat? {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0 else { return nil }

    let clampedRaw = min(max(rawProgress, 0), 1)
    let snapWindowProgress = CGFloat(snapWindow / duration)
    var closest: (progress: CGFloat, distance: CGFloat)?

    for note in calendarEventTimelineTrackNotes(from: notes, range: range) {
        let noteProgress = calendarEventTimelineProgress(for: note.createdAt, range: range)
        let distance = abs(noteProgress - clampedRaw)
        guard distance <= snapWindowProgress else { continue }

        if closest == nil || distance < closest!.distance {
            closest = (noteProgress, distance)
        }
    }

    return closest?.progress
}

func calendarEventTimelineResolveDrag(
    rawProgress: CGFloat,
    range: Event.TimeRange,
    notes: [EventLogTimelineNote],
    now: Date,
    currentMode: CalendarEventTimelineMode,
    wasSnappedToNote: Bool,
    previousSelectedMinute: Int,
    noteSnapWindow: TimeInterval = 2 * 60,
    liveResumeTolerance: TimeInterval = 60
) -> CalendarEventTimelineDragResolution {
    let clampedRaw = min(max(rawProgress, 0), 1)
    let snappedProgress = calendarEventTimelineSnapProgress(
        rawProgress: clampedRaw,
        notes: notes,
        range: range,
        snapWindow: noteSnapWindow
    )
    let manualProgress = snappedProgress ?? clampedRaw

    if calendarEventTimelineCanResumeLive(
        progress: manualProgress,
        now: now,
        range: range,
        tolerance: liveResumeTolerance
    ) {
        let liveProgress = calendarEventTimelineLiveProgress(now: now, range: range)
        return CalendarEventTimelineDragResolution(
            mode: .live,
            progress: liveProgress,
            snapshotDate: now,
            isSnappedToNote: false,
            selectedMinute: calendarEventTimelineTrackMinute(progress: liveProgress, range: range),
            feedback: currentMode == .manual ? .resumeLive : .none
        )
    }

    let didSnapToNote = snappedProgress != nil
    let selectedMinute = calendarEventTimelineTrackMinute(progress: manualProgress, range: range)
    let feedback: CalendarEventTimelineFeedback
    if didSnapToNote && !wasSnappedToNote {
        feedback = .noteSnap
    } else if !didSnapToNote && selectedMinute != previousSelectedMinute {
        feedback = .selection
    } else {
        feedback = .none
    }

    return CalendarEventTimelineDragResolution(
        mode: .manual,
        progress: manualProgress,
        snapshotDate: calendarEventTimelineSnapshotDate(for: manualProgress, range: range),
        isSnappedToNote: didSnapToNote,
        selectedMinute: selectedMinute,
        feedback: feedback
    )
}

struct CalendarResolvedParallelTimelineItem: Identifiable {
    let childEvent: Event
    let childRange: Event.TimeRange
    let clippedRange: Event.TimeRange?
    var id: UUID { childEvent.id }
}

struct CalendarResolvedInterruptTimelineItem: Identifiable {
    let reference: EventLogInterruptReference
    let childEvent: Event
    let childRange: Event.TimeRange
    let clippedRange: Event.TimeRange?
    let overflowsLeading: Bool
    let overflowsTrailing: Bool

    var id: UUID { reference.id }
}

/// A note "near the play head": within 5% of the event's span, at least a
/// minute.
func calendarEventTimelineNoteIsNear(_ note: EventLogTimelineNote, at selectedDate: Date,
                                     range: Event.TimeRange) -> Bool {
    let totalDuration = range.end.timeIntervalSince(range.start)
    let windowSeconds = max(totalDuration * 0.05, 60)
    return abs(note.createdAt.timeIntervalSince(selectedDate)) <= windowSeconds
}

/// An interrupt "near the play head": the head is inside it, or within two
/// minutes of either edge.
func calendarEventTimelineInterruptIsNear(_ item: CalendarResolvedInterruptTimelineItem,
                                          at selectedDate: Date) -> Bool {
    let childRange = item.childRange
    return selectedDate >= childRange.start && selectedDate <= childRange.end
        || abs(childRange.start.timeIntervalSince(selectedDate)) <= 120
        || abs(childRange.end.timeIntervalSince(selectedDate)) <= 120
}

extension EventStore {
    func resolvedInterruptTimelineItems(
        for occurrence: CalendarEventOccurrenceContext,
        range: Event.TimeRange
    ) -> [CalendarResolvedInterruptTimelineItem] {
        (logRecord(for: occurrence)?.timelineItems ?? [])
            .compactMap(\.interruptReferenceValue)
            .compactMap { reference in
                guard let childEvent = findCalendarEvent(id: reference.childEventID),
                      let childRange = childEvent.primaryTimeRange else {
                    return nil
                }
                let clippedStart = max(range.start, childRange.start)
                let clippedEnd = min(range.end, childRange.end)
                let clippedRange = clippedEnd > clippedStart
                    ? Event.TimeRange(start: clippedStart, end: clippedEnd)
                    : nil
                return CalendarResolvedInterruptTimelineItem(
                    reference: reference,
                    childEvent: childEvent,
                    childRange: childRange,
                    clippedRange: clippedRange,
                    overflowsLeading: childRange.start < range.start,
                    overflowsTrailing: childRange.end > range.end
                )
            }
            .sorted { lhs, rhs in
                if lhs.childRange.start != rhs.childRange.start {
                    return lhs.childRange.start < rhs.childRange.start
                }
                return lhs.childEvent.id.uuidString < rhs.childEvent.id.uuidString
            }
    }

    func resolvedParallelTimelineItems(
        for currentEvent: Event,
        range: Event.TimeRange
    ) -> [CalendarResolvedParallelTimelineItem] {
        // canvasRenderableCalendarEvents: an absorbed `.todo` belongs
        // inside its parent event visually — it must not render as a
        // "parallel timeline item" beside that same parent (the worst
        // visual: a child appearing next to itself).  Filter matches
        // the main canvas's absorbed-filter.
        // renderPrimaryTimeRange: the overlap test runs against the slot the
        // canvas actually draws — a traveled detached instance's raw range
        // sits a frame away and would add/miss a parallel bar the timeline
        // doesn't show (gh#187).
        return canvasRenderableCalendarEvents.compactMap { candidate in
            guard candidate.id != currentEvent.id,
                  !candidate.isInterrupt,
                  let candidateRange = candidate.renderPrimaryTimeRange(calendar: .current),
                  candidateRange.end > range.start,
                  candidateRange.start < range.end else { return nil }
            // Skip interrupts of this event
            if let rel = candidate.interruptRelation, rel.parentEventID == currentEvent.id { return nil }
            let clippedStart = max(range.start, candidateRange.start)
            let clippedEnd = min(range.end, candidateRange.end)
            return CalendarResolvedParallelTimelineItem(
                childEvent: candidate,
                childRange: candidateRange,
                clippedRange: Event.TimeRange(start: clippedStart, end: clippedEnd)
            )
        }
        .sorted { $0.childRange.start < $1.childRange.start }
    }
}
