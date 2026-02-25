//
//  CalendarEventSheets.swift
//  Done
//
//  Sheet views for creating and editing calendar events
//

import SwiftUI

struct CreateCalendarEventView: View {
    var timeRange: Event.TimeRange
    var initialTitle: String = ""
    var initialTypeTitle: String = "Study"
    var initialNote: String = ""
    var initialLocation: String = ""
    var preloadedAgenticIntake: AgenticIntakeRecord? = nil
    var onCreated: ((Event) -> Void)? = nil
    @EnvironmentObject private var store: EventStore

    var body: some View {
        CalendarEventFormView(
            navigationTitle: "New Event",
            initialTitle: initialTitle,
            initialTypeTitle: initialTypeTitle,
            initialNote: initialNote,
            initialLocation: initialLocation,
            initialStartTime: timeRange.start,
            initialEndTime: timeRange.end,
            agenticIntake: preloadedAgenticIntake
        ) { form in
            let event = form.toEvent()
            store.addCalendarEvent(event)
            onCreated?(event)
        }
    }
}

struct EditCalendarEventView: View {
    let event: Event
    var occurrenceDate: Date? = nil
    var recurrenceScope: Event.RecurrenceEditScope? = nil
    @EnvironmentObject private var store: EventStore

    var body: some View {
        CalendarEventFormView(
            navigationTitle: "Edit Event",
            initialTitle: event.title,
            initialTypeTitle: event.type,
            initialNote: event.note,
            initialLocation: event.location,
            initialStartTime: event.timeRanges.first?.start ?? Date(),
            initialEndTime: event.timeRanges.first?.end ?? Date().addingTimeInterval(3600),
            initialIsAllDay: event.isAllDay,
            initialRepeatUnit: event.repeatUnit,
            initialRepeatInterval: event.repeatInterval,
            initialRepeatEndType: event.repeatEndType,
            initialRepeatEndDate: event.repeatEndDate,
            initialRepeatEndCount: event.repeatEndCount,
            agenticIntake: event.agenticIntake
        ) { form in
            if event.isRecurringSeries, let scope = recurrenceScope, let occDate = occurrenceDate {
                store.applyRecurringEdit(
                    seriesEvent: event,
                    occurrenceDate: occDate,
                    scope: scope
                ) { instance in
                    instance = form.apply(to: instance)
                }
            } else {
                store.updateCalendarEvent(form.apply(to: event))
            }
        }
    }
}
