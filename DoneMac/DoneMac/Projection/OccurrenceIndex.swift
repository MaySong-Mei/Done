//
//  OccurrenceIndex.swift
//  DoneMac
//
//  Incremental dayKey → event-id index over the canvas-renderable subset
//  (#219 concept 2's cost half: a day query touches candidates, not the
//  corpus). Recurring series are a small set walked per day by the shared
//  expansion, so they live in their own bucket. Correctness is guarded by
//  a DEBUG shadow-compare against a full rebuild (plan risk #6): any
//  mismatch trips a counter and falls back to the rebuilt truth.
//

import Foundation

@MainActor
struct OccurrenceIndex {
    private(set) var daysByID: [UUID: Set<DayKey>] = [:]
    private(set) var idsByDay: [DayKey: Set<UUID>] = [:]
    private(set) var recurringIDs: Set<UUID> = []
    private let calendar: Calendar

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    static func built(from events: [Event], calendar: Calendar) -> OccurrenceIndex {
        var index = OccurrenceIndex(calendar: calendar)
        for event in events where event.isCanvasRenderable {
            index.insert(event)
        }
        return index
    }

    private mutating func insert(_ event: Event) {
        if event.isRecurringSeries {
            recurringIDs.insert(event.id)
            return
        }
        // A capped (nil) span indexes nowhere — the day query unions the
        // recurring bucket and misses it, but such an event is decoded
        // garbage the delta already reports as bulk; day models for it
        // rebuild via full invalidation, never via this index.
        guard let keys = DayKey.keys(of: event, calendar: calendar) else { return }
        daysByID[event.id] = keys
        for key in keys {
            idsByDay[key, default: []].insert(event.id)
        }
    }

    private mutating func remove(id: UUID) {
        recurringIDs.remove(id)
        guard let keys = daysByID.removeValue(forKey: id) else { return }
        for key in keys {
            idsByDay[key]?.remove(id)
            if idsByDay[key]?.isEmpty == true {
                idsByDay.removeValue(forKey: key)
            }
        }
    }

    /// Incremental maintenance: re-derive membership for exactly the
    /// changed ids. `events` is the post-commit truth array.
    mutating func apply(changedIDs: Set<UUID>, events: [Event]) {
        var present: [UUID: Event] = [:]
        for event in events where changedIDs.contains(event.id) {
            present[event.id] = event
        }
        for id in changedIDs {
            remove(id: id)
            if let event = present[id], event.isCanvasRenderable {
                insert(event)
            }
        }
    }

    /// Candidate ids for one day: indexed single events plus every
    /// recurring series (the shared expansion decides per day).
    func candidates(for key: DayKey) -> Set<UUID> {
        (idsByDay[key] ?? []).union(recurringIDs)
    }

    /// Full-rebuild comparison for the DEBUG shadow check.
    func matches(_ other: OccurrenceIndex) -> Bool {
        idsByDay == other.idsByDay && recurringIDs == other.recurringIDs
    }
}
