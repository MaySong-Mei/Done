//
//  WristCommandApplier.swift
//  Done
//
//  Turns a `WristCommand` into the same store mutations focus mode's quick
//  actions perform (`DoneApp.startTracking` / `applyEndTime` /
//  `applyEndTimeDelta`): start creates one single-range event of the type;
//  finish and extend rewrite one range's end, grid-snapped and clamped to a
//  15-minute minimum, and are refused for recurring events and running
//  timers. Unlike focus mode, the range edited is the one the command names
//  (`rangeStart`), so a multi-range event's other ranges are left alone.
//

import Foundation

enum WristCommandApplier {
    static let minimumDuration: TimeInterval = 15 * 60

    @discardableResult
    static func apply(_ command: WristCommand, to store: EventStore) -> WristReceipt {
        switch command.kind {
        case .start(let eventID, let typeTitle, let start, let end):
            if store.findCalendarEvent(id: eventID) != nil {
                return WristReceipt(id: command.id, outcome: .duplicate, reason: nil)
            }
            let title = typeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return rejected(command, "empty type") }
            guard end > start else { return rejected(command, "invalid range") }
            store.addCalendarEvent(
                Event(
                    id: eventID,
                    title: title,
                    timeRanges: [Event.TimeRange(start: start, end: end)],
                    type: title
                )
            )
            return WristReceipt(id: command.id, outcome: .applied, reason: nil)

        case .finish(let eventID, let rangeStart, let at):
            return setEnd(of: eventID, rangeStart: rangeStart, command: command, store: store) { _ in at }

        case .extend(let eventID, let rangeStart, let by):
            return setEnd(of: eventID, rangeStart: rangeStart, command: command, store: store) { range in
                range.end.addingTimeInterval(by)
            }
        }
    }

    /// The end focus mode would store: snapped to the 15-minute grid, never
    /// earlier than `start + minimumDuration`.
    static func adjustedEnd(start: Date, requested: Date) -> Date {
        max(calendarSnapDateToMinuteGrid(requested), start.addingTimeInterval(minimumDuration))
    }

    /// Which range a command edits: the one starting at `rangeStart`, else
    /// the only range. A multi-range event without a named range is refused
    /// rather than guessed.
    static func rangeIndex(in event: Event, rangeStart: Date?) -> Int? {
        if let rangeStart, let named = event.timeRanges.firstIndex(where: { $0.start == rangeStart }) {
            return named
        }
        return event.timeRanges.count == 1 ? 0 : nil
    }

    private static func setEnd(
        of eventID: UUID, rangeStart: Date?, command: WristCommand, store: EventStore,
        requested: (Event.TimeRange) -> Date
    ) -> WristReceipt {
        guard let event = store.findCalendarEvent(id: eventID) else {
            return rejected(command, "not found")
        }
        guard focusQuickActionAllowedForEvent(event) else {
            return rejected(command, "recurring")
        }
        guard event.timerStartedAt == nil else {
            return rejected(command, "timer")
        }
        guard let index = rangeIndex(in: event, rangeStart: rangeStart) else {
            return rejected(command, event.timeRanges.isEmpty ? "no range" : "range not found")
        }
        let range = event.timeRanges[index]
        var updated = event
        updated.timeRanges[index].end = adjustedEnd(start: range.start, requested: requested(range))
        if updated.timeRanges[index].end != range.end {
            store.updateCalendarEvent(updated)
        }
        return WristReceipt(id: command.id, outcome: .applied, reason: nil)
    }

    private static func rejected(_ command: WristCommand, _ reason: String) -> WristReceipt {
        WristReceipt(id: command.id, outcome: .rejected, reason: reason)
    }
}
