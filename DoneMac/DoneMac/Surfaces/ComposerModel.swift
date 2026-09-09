//
//  ComposerModel.swift
//  DoneMac
//
//  Draft state for create/edit. Its own @Observable island: keystrokes
//  invalidate composer views only — the canvas never reads a draft field
//  (budget assertion 5, the anti-#201 shape). Saves are seeded from
//  renderTimeRanges: an untouched time field round-trips bit-identical
//  (the Event.swift write-side rule's passthrough case).
//

import SwiftUI

@MainActor
@Observable
final class ComposerModel {
    var title: String = ""
    var kind: Event.Kind = .event
    var start: Date = .now
    var end: Date = .now
    private(set) var editingEventID: UUID?
    /// The seeded ranges captured when the composer opened; the save
    /// compares against these so untouched times pass through verbatim.
    @ObservationIgnored private var seedRanges: [Event.TimeRange] = []
    @ObservationIgnored private let store: MacEventStore
    @ObservationIgnored private let calendar: Calendar

    init(store: MacEventStore, calendar: Calendar) {
        self.store = store
        self.calendar = calendar
    }

    func openForCreate(day: DayKey, now: Date) {
        editingEventID = nil
        seedRanges = []
        title = ""
        kind = .event
        let dayStart = day.startOfDay(calendar: calendar) ?? calendar.startOfDay(for: now)
        start = dayStart.addingTimeInterval(9 * 3600)
        end = dayStart.addingTimeInterval(10 * 3600)
    }

    func openForEdit(eventID: UUID) -> Bool {
        guard let event = store.calendarEvents.first(where: { $0.id == eventID }) else { return false }
        editingEventID = event.id
        seedRanges = event.renderTimeRanges(calendar: calendar)
        title = event.title
        kind = event.kind
        if let first = seedRanges.first {
            start = first.start
            end = first.end
        } else {
            start = .now
            end = .now
        }
        return true
    }

    func save(now: Date) {
        if let editingEventID {
            guard var event = store.calendarEvents.first(where: { $0.id == editingEventID }) else { return }
            event.title = title
            event.kind = kind
            if let first = seedRanges.first {
                let edited = Event.TimeRange(start: start, end: max(end, start))
                if edited != first {
                    var ranges = seedRanges
                    ranges[0] = edited
                    event.timeRanges = ranges
                } else {
                    // Untouched: bit-identical passthrough of the SEEDED
                    // projection, never a re-derived instant.
                    event.timeRanges = seedRanges
                }
            } else if kind == .event {
                event.timeRanges = [Event.TimeRange(start: start, end: max(end, start))]
            }
            store.replaceCalendarEvent(event, now: now)
        } else {
            let event = Event(
                id: UUID(), title: title,
                timeRanges: [Event.TimeRange(start: start, end: max(end, start))],
                kind: kind
            )
            store.addCalendarEvent(event, now: now)
        }
    }

    func delete(now: Date) {
        guard let editingEventID else { return }
        store.removeCalendarEvent(id: editingEventID, now: now)
    }

    /// Unschedule a todo back to the stack: ranges drop, deadline and
    /// every other field survive (the shared putTodoBackToStack shape).
    func returnToStack(now: Date) {
        guard let editingEventID,
              var event = store.calendarEvents.first(where: { $0.id == editingEventID }),
              event.kind == .todo else { return }
        event.timeRanges = []
        store.replaceCalendarEvent(event, now: now)
    }
}
