//
//  EventGridSheets.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

struct CreateEventView: View {
    @EnvironmentObject private var store: EventStore

    var body: some View {
        EventFormView(
            navigationTitle: "New Event",
            initialTitle: "",
            initialTypeTitle: "Study",
            initialNote: "",
            initialPriority: 0,
            initialTags: [],
            initialTimeRanges: [],
            initialDeadline: nil,
            initialGridWidth: 8,
            initialGridHeight: 8
        ) { form in
            let event = Event(
                title: form.title,
                note: form.note,
                startTime: form.timeRanges.first?.start,
                endTime: form.timeRanges.first?.end,
                timeRanges: form.timeRanges,
                deadline: form.deadline,
                gridWidth: form.gridWidth,
                gridHeight: form.gridHeight,
                priority: form.priority,
                tags: form.tags,
                type: form.typeTitle
            )
            store.addWithAutoPlacement(event)
        }
    }
}

struct EditEventView: View {
    let event: Event
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
            initialGridWidth: event.gridWidth,
            initialGridHeight: event.gridHeight
        ) { form in
            var updated = event
            updated.title = form.title
            updated.type = form.typeTitle
            updated.note = form.note
            updated.priority = form.priority
            updated.tags = form.tags
            updated.timeRanges = form.timeRanges
            updated.startTime = form.timeRanges.first?.start
            updated.endTime = form.timeRanges.first?.end
            updated.deadline = form.deadline
            updated.gridWidth = form.gridWidth
            updated.gridHeight = form.gridHeight
            store.update(updated)
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
