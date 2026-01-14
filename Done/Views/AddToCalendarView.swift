//
//  AddToCalendarView.swift
//  Done
//
//  Created by Shiqi Liu on 1/14/26.
//

import SwiftUI

struct AddToCalendarView: View {
    let event: Event
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @State private var selectedDate: Date
    @State private var startTime: Date
    @State private var endTime: Date

    init(event: Event) {
        self.event = event
        let now = Date()
        let baseStart = event.startTime ?? now
        let baseEnd = event.endTime ?? Calendar.current.date(byAdding: .hour, value: 1, to: baseStart) ?? baseStart
        _selectedDate = State(initialValue: Calendar.current.startOfDay(for: baseStart))
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
                Section("Date") {
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                }
                Section("Time") {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
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
                        let calendar = Calendar.current
                        let combinedStart = combine(day: selectedDate, time: startTime, calendar: calendar)
                        let combinedEnd = combine(day: selectedDate, time: endTime, calendar: calendar)
                        let finalEnd = combinedEnd <= combinedStart
                            ? calendar.date(byAdding: .hour, value: 1, to: combinedStart) ?? combinedStart
                            : combinedEnd

                        var updated = event
                        updated.startTime = combinedStart
                        updated.endTime = finalEnd
                        store.update(updated)
                        dismiss()
                    }
                }
            }
        }
    }

    private func combine(day: Date, time: Date, calendar: Calendar) -> Date {
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: time)
        var combined = DateComponents()
        combined.year = dayComponents.year
        combined.month = dayComponents.month
        combined.day = dayComponents.day
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute
        combined.second = timeComponents.second
        return calendar.date(from: combined) ?? day
    }
}
