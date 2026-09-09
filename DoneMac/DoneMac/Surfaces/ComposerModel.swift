//
//  ComposerModel.swift
//  DoneMac
//
//  Draft state for create/edit. Its own @Observable island: keystrokes
//  invalidate composer views only — the canvas never reads a draft field
//  (budget assertion 5; the SwiftUI-invalidation half is verified by
//  inspection, the store/projection half by test). Round-4 save contract
//  (review F2/F3 family): saves re-read the FRESH row and assign only the
//  fields the user touched — an untouched time field is NOT written at
//  all, so a row that moved underneath (domino, sync) is never dragged
//  back to its open-time position.
//

import SwiftUI

@MainActor
@Observable
final class ComposerModel {
    var title: String = ""
    var kind: Event.Kind = .event
    var start: Date = .distantPast
    var end: Date = .distantPast
    private(set) var editingEventID: UUID?
    /// True when this composer session is naming a record a drag-create
    /// just landed; Cancel deletes the record if it is still empty
    /// (review F18 — an untouched placeholder holds no user input).
    private(set) var namingFreshCreation = false

    /// Captured at open so the save can tell touched from untouched:
    /// whatever the pickers were SEEDED with (a real range, or the
    /// dateless fallback anchor) — comparing against these is the only
    /// touched-test that works for dateless records too (round-4 QA
    /// caught the first cut silently scheduling a renamed dateless todo).
    @ObservationIgnored private var openStart: Date = .distantPast
    @ObservationIgnored private var openEnd: Date = .distantPast
    @ObservationIgnored private var seedFirst: Event.TimeRange?
    @ObservationIgnored private let store: MacEventStore
    @ObservationIgnored private let calendar: Calendar

    static let minimumEventSeconds: TimeInterval = 15 * 60

    init(store: MacEventStore, calendar: Calendar) {
        self.store = store
        self.calendar = calendar
    }

    func openForCreate(day: DayKey, now: Date) {
        editingEventID = nil
        namingFreshCreation = false
        seedFirst = nil
        title = ""
        kind = .event
        let dayStart = day.startOfDay(calendar: calendar) ?? calendar.startOfDay(for: now)
        start = dayStart.addingTimeInterval(9 * 3600)
        end = dayStart.addingTimeInterval(10 * 3600)
    }

    /// `now` seeds the pickers for a dateless record — explicit, never a
    /// wall-clock read inside the model (#219 concept 2; QA round-3 F4).
    func openForEdit(eventID: UUID, now: Date, namingFreshCreation: Bool = false) -> Bool {
        guard let event = store.calendarEvents.first(where: { $0.id == eventID }) else { return false }
        editingEventID = event.id
        self.namingFreshCreation = namingFreshCreation
        let seeds = event.renderTimeRanges(calendar: calendar)
        seedFirst = seeds.first
        title = event.title
        kind = event.kind
        if let first = seeds.first {
            start = first.start
            end = first.end
        } else {
            let anchor = calendar.startOfDay(for: now).addingTimeInterval(9 * 3600)
            start = anchor
            end = anchor.addingTimeInterval(3600)
        }
        openStart = start
        openEnd = end
        return true
    }

    /// Series templates take title-only edits on Mac until the scope+rebase
    /// machinery is ported (review F4a): time or kind writes on a template
    /// re-anchor every occurrence with no scope question asked.
    var allowsTimeEditing: Bool {
        guard let editingEventID,
              let event = store.calendarEvents.first(where: { $0.id == editingEventID }) else {
            return true
        }
        return !event.isRecurringSeries
    }

    func save(now: Date) {
        if let editingEventID {
            guard var event = store.calendarEvents.first(where: { $0.id == editingEventID }) else { return }
            event.title = title
            let timesTouched = start != openStart || end != openEnd
            if allowsTimeEditing {
                event.kind = kind
                if timesTouched {
                    let edited = clampedEditedRange()
                    var fresh = event.renderTimeRanges(calendar: calendar)
                    if fresh.isEmpty {
                        // Scheduling a dateless record: the picked times ARE
                        // the schedule, for todos too (review F6 — the only
                        // Mac path that can schedule a stack todo).
                        event.timeRanges = [edited]
                    } else {
                        fresh[0] = edited
                        event.timeRanges = fresh
                    }
                }
                // Untouched: no assignment at all — the fresh row's ranges
                // stand, whatever moved them since open.
            }
            store.replaceCalendarEvent(event, now: now)
        } else {
            let event = Event(
                id: UUID(), title: title,
                timeRanges: [clampedEditedRange()],
                kind: kind
            )
            store.addCalendarEvent(event, now: now)
            // Double-fired Save must not mint twice (QA round-3 F5).
            editingEventID = event.id
            seedFirst = event.timeRanges.first
        }
    }

    /// Cancel semantics: only a drag-created record that is STILL empty is
    /// deleted — everything else, Cancel touches nothing.
    func cancel(now: Date) {
        if namingFreshCreation,
           let editingEventID,
           let event = store.calendarEvents.first(where: { $0.id == editingEventID }),
           event.title.isEmpty,
           title.isEmpty {
            store.removeCalendarEvent(id: editingEventID, now: now)
        }
        namingFreshCreation = false
    }

    func delete(now: Date) {
        guard let editingEventID else { return }
        store.removeCalendarEvent(id: editingEventID, now: now)
    }

    /// Unschedule a todo back to the stack. Gate is the SHARED
    /// canReturnToStack (done/absorbed/recurring excluded), matching
    /// EventStore.putTodoBackToStack — review round-3 F5.
    func returnToStack(now: Date) {
        guard let editingEventID,
              var event = store.calendarEvents.first(where: { $0.id == editingEventID }),
              event.canReturnToStack else { return }
        event.timeRanges = []
        store.replaceCalendarEvent(event, now: now)
    }

    /// Same floor as the drag paths — no zero-duration mints (QA F4).
    private func clampedEditedRange() -> Event.TimeRange {
        Event.TimeRange(start: start, end: max(end, start.addingTimeInterval(Self.minimumEventSeconds)))
    }
}
