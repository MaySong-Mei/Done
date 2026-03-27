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
            let event = EventLogTemplateAdvisor().applySuggestion(to: form.toEvent())
            store.addCalendarEvent(event)
            onCreated?(event)
        }
    }
}

struct EditCalendarEventView: View {
    let event: Event
    var occurrenceDate: Date? = nil
    var recurrenceScope: Event.RecurrenceEditScope? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @State private var showDeleteConfirmation = false

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
            agenticIntake: event.agenticIntake,
            onDeleteRequest: {
                showDeleteConfirmation = true
            }
        ) { form in
            let advisor = EventLogTemplateAdvisor()
            if event.isRecurringSeries, let scope = recurrenceScope, let occDate = occurrenceDate {
                store.applyRecurringEdit(
                    seriesEvent: event,
                    occurrenceDate: occDate,
                    scope: scope
                ) { instance in
                    instance = form.apply(to: instance)
                    if instance.agenticIntake?.processingPhase == .failed {
                        instance.agenticIntake?.processingPhase = .completed
                        instance.agenticIntake?.failureMessage = nil
                    }
                    instance = advisor.applySuggestion(to: instance)
                }
            } else {
                var updated = form.apply(to: event)
                if updated.agenticIntake?.processingPhase == .failed {
                    updated.agenticIntake?.processingPhase = .completed
                    updated.agenticIntake?.failureMessage = nil
                }
                store.updateCalendarEvent(advisor.applySuggestion(to: updated))
            }
        }
        .alert("Delete Event", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteEvent()
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }
}

private extension EditCalendarEventView {
    var resolvedRecurringDeleteScope: Event.RecurrenceEditScope {
        guard event.isRecurringSeries,
              recurrenceScope != nil,
              occurrenceDate != nil
        else {
            return .all
        }
        return recurrenceScope ?? .all
    }

    var deleteConfirmationMessage: String {
        guard event.isRecurringSeries else {
            return "This event will be permanently deleted."
        }

        switch resolvedRecurringDeleteScope {
        case .single:
            return "This occurrence will be deleted."
        case .following:
            return "This and future occurrences will be deleted."
        case .all:
            return "All events in this series will be deleted."
        }
    }

    func deleteEvent() {
        if event.isRecurringSeries {
            if let scope = recurrenceScope, let occurrenceDate {
                store.deleteRecurringCalendarEvent(
                    seriesEvent: event,
                    occurrenceDate: occurrenceDate,
                    scope: scope
                )
            } else {
                store.deleteRecurringCalendarEvent(
                    seriesEvent: event,
                    occurrenceDate: event.primaryTimeRange?.start ?? Date(),
                    scope: .all
                )
            }
        } else {
            store.deleteCalendarEvent(event)
        }
        dismiss()
    }
}
