//
//  CalendarEventSheets.swift
//  Done
//
//  Sheet views for creating and editing calendar events
//

import SwiftUI

struct CreateCalendarEventView: View {
    var timeRange: Event.TimeRange
    @EnvironmentObject private var store: EventStore

    var body: some View {
        CalendarEventFormView(
            navigationTitle: "New Event",
            initialTitle: "",
            initialTypeTitle: "Study",
            initialNote: "",
            initialStartTime: timeRange.start,
            initialEndTime: timeRange.end
        ) { form in
            store.addCalendarEvent(form.toEvent())
        }
    }
}

struct EditCalendarEventView: View {
    let event: Event
    @EnvironmentObject private var store: EventStore

    var body: some View {
        CalendarEventFormView(
            navigationTitle: "Edit Event",
            initialTitle: event.title,
            initialTypeTitle: event.type,
            initialNote: event.note,
            initialStartTime: event.timeRanges.first?.start ?? Date(),
            initialEndTime: event.timeRanges.first?.end ?? Date().addingTimeInterval(3600)
        ) { form in
            store.updateCalendarEvent(form.apply(to: event))
        }
    }
}
