//
//  TimeEntriesView.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI

struct TimeEntriesView: View {
    @StateObject private var dataManager = DataManager.shared
    @State private var selectedDateRange = DateRange.today

    enum DateRange: String, CaseIterable {
        case today = "Today"
        case week = "This Week"
        case month = "This Month"
        case all = "All Time"

        var dates: (start: Date, end: Date) {
            let calendar = Calendar.current
            let now = Date()

            switch self {
            case .today:
                let start = calendar.startOfDay(for: now)
                let end = calendar.date(byAdding: .day, value: 1, to: start)!
                return (start, end)
            case .week:
                let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
                let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
                return (start, end)
            case .month:
                let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
                let end = calendar.date(byAdding: .month, value: 1, to: start)!
                return (start, end)
            case .all:
                return (Date.distantPast, Date.distantFuture)
            }
        }
    }

    var filteredEntries: [TimeEntry] {
        let (start, end) = selectedDateRange.dates
        return dataManager.getEntriesForDateRange(start: start, end: end)
    }

    var totalDuration: TimeInterval {
        filteredEntries.compactMap { $0.duration }.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Date Range", selection: $selectedDateRange) {
                    ForEach(DateRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if !filteredEntries.isEmpty {
                    HStack {
                        Text("Total Time:")
                            .font(.headline)
                        Spacer()
                        Text(totalDuration.formatAsHoursMinutes())
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                }

                List {
                    ForEach(groupedEntries, id: \.date) { group in
                        Section(header: Text(formatDate(group.date))) {
                            ForEach(group.entries) { entry in
                                TimeEntryRow(entry: entry)
                            }
                            .onDelete { offsets in
                                offsets.forEach { dataManager.deleteTimeEntry(group.entries[$0]) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Time Entries")
        }
    }

    private var groupedEntries: [(date: Date, entries: [TimeEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredEntries) { entry in
            calendar.startOfDay(for: entry.startTime)
        }
        return grouped.sorted { $0.key > $1.key }.map { (date: $0.key, entries: $0.value) }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

}

struct TimeEntryRow: View {
    let entry: TimeEntry

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: entry.colorHex) ?? .blue)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.templateName)
                    .font(.headline)

                HStack {
                    Text(formatTime(entry.startTime))
                    if let endTime = entry.endTime {
                        Text("-")
                        Text(formatTime(endTime))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.durationString)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if entry.syncedToCalendar {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    TimeEntriesView()
}
