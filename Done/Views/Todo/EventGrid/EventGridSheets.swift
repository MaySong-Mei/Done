//
//  EventGridSheets.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

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
            initialDeadline: event.deadline,
            onSave: { form in
                if isCalendarEvent {
                    store.updateCalendarEvent(form.apply(to: event))
                } else {
                    store.update(form.apply(to: event))
                }
            },
            onDelete: {
                if isCalendarEvent {
                    store.deleteCalendarEvent(event)
                } else {
                    store.delete(event)
                }
            }
        )
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.tertiary)
                .symbolEffect(.breathe.pulse, options: .repeating)
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
