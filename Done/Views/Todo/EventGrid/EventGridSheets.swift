//
//  EventGridSheets.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

struct CreateEventView: View {
    var timeRange: Event.TimeRange? = nil
    var isCalendarEvent: Bool = false
    var listID: UUID? = nil
    @EnvironmentObject private var store: EventStore

    var body: some View {
        EventFormView(
            navigationTitle: "New Event",
            initialTitle: "",
            initialTypeTitle: "Study",
            initialNote: "",
            initialPriority: 0,
            initialTags: [],
            initialTimeRanges: timeRange.map { [$0] } ?? [],
            initialDeadline: nil
        ) { form in
            var form = form
            form.listID = listID
            if isCalendarEvent {
                store.addCalendarEvent(form.toEvent())
            } else if timeRange != nil {
                store.add(form.toEvent())
            } else {
                store.addWithAutoPlacement(form.toEvent())
            }
        }
    }
}

struct EditEventView: View {
    let event: Event
    var isCalendarEvent: Bool = false
    @EnvironmentObject private var store: EventStore

    var body: some View {
        EventFormView(
            navigationTitle: "Edit Event",
            initialTitle: event.title,
            initialTypeTitle: event.type,
            initialNote: event.note,
            initialPriority: event.priority,
            initialTags: event.tags,
            initialTimeRanges: event.effectiveTimeRanges,
            initialDeadline: event.deadline
        ) { form in
            if isCalendarEvent {
                store.updateCalendarEvent(form.apply(to: event))
            } else {
                store.update(form.apply(to: event))
            }
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
