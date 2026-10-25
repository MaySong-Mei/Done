//
//  WristCommandApplier.swift
//  Done
//
//  Turns a `WristCommand` into the same store mutations focus mode's quick
//  actions perform (`DoneApp.startTracking` / `applyEndTime` /
//  `applyEndTimeDelta`): start creates one single-range event of the type;
//  finish and extend rewrite range 0's end, grid-snapped and clamped to a
//  15-minute minimum, and are refused for recurring events.
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

        case .finish(let eventID, let at):
            return setEnd(of: eventID, command: command, store: store) { _ in at }

        case .extend(let eventID, let by):
            return setEnd(of: eventID, command: command, store: store) { range in
                range.end.addingTimeInterval(by)
            }
        }
    }

    /// The end focus mode would store: snapped to the 15-minute grid, never
    /// earlier than `start + minimumDuration`.
    static func adjustedEnd(start: Date, requested: Date) -> Date {
        max(calendarSnapDateToMinuteGrid(requested), start.addingTimeInterval(minimumDuration))
    }

    private static func setEnd(
        of eventID: UUID, command: WristCommand, store: EventStore,
        requested: (Event.TimeRange) -> Date
    ) -> WristReceipt {
        guard let event = store.findCalendarEvent(id: eventID) else {
            return rejected(command, "not found")
        }
        guard focusQuickActionAllowedForEvent(event) else {
            return rejected(command, "recurring")
        }
        guard let first = event.timeRanges.first else {
            return rejected(command, "no range")
        }
        var updated = event
        updated.timeRanges[0].end = adjustedEnd(start: first.start, requested: requested(first))
        if updated.timeRanges[0].end != first.end {
            store.updateCalendarEvent(updated)
        }
        return WristReceipt(id: command.id, outcome: .applied, reason: nil)
    }

    private static func rejected(_ command: WristCommand, _ reason: String) -> WristReceipt {
        WristReceipt(id: command.id, outcome: .rejected, reason: reason)
    }
}
