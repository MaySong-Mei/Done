//
//  AddToCalendarView.swift
//  Done
//
//  Created by Shiqi Liu on 1/14/26.
//

import SwiftUI

/// 功能： Lets the user pick a date and time window to add or update a calendar event.
struct AddToCalendarView: View {
    let event: Event
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @State private var startTime: Date
    @State private var endTime: Date

    init(event: Event) {
        self.event = event
        let now = Date()
        let baseRange = event.primaryTimeRange
        let baseStart = baseRange?.start ?? now
        let baseEnd = baseRange?.end ?? Calendar.current.date(byAdding: .hour, value: 1, to: baseStart) ?? baseStart
        _startTime = State(initialValue: baseStart)
        _endTime = State(initialValue: baseEnd)
    }

    var body: some View {
        NavigationStack {
            settingsPage("Add to Calendar") {
                settingsCard {
                    Text(event.title)
                        .font(.headline)
                }

                settingsCard("Start") {
                    DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                }

                settingsCard("End") {
                    DatePicker("End", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        let range = Event.TimeRange(start: startTime, end: endTime)
                        var calEvent = event
                        calEvent.id = UUID()
                        calEvent.timeRanges = [range]
                        store.addCalendarEvent(calEvent)
                        dismiss()
                    }
                }
            }
        }
    }
}
