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
            Form {
                Section("Event") {
                    Text(event.title)
                        .font(.headline)
                }
                Section("Start") {
                    DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                }
                Section("End") {
                    DatePicker("End", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                }
            }
            .navigationTitle("Add to Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        // endTime is already constrained to be >= startTime by the DatePicker
                        var updated = event
                        var ranges = updated.timeRanges
                        ranges.append(Event.TimeRange(start: startTime, end: endTime))
                        ranges.sort { $0.start < $1.start }
                        updated.timeRanges = ranges
                        updated.startTime = ranges.first?.start
                        updated.endTime = ranges.first?.end
                        store.update(updated)
                        dismiss()
                    }
                }
            }
        }
    }
}
