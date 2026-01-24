//
//  TimelinePreviewView.swift
//  Done
//
//  Simple read-only timeline list for view mode. Groups events by day and
//  shows lightweight rows without the editable grid.
//

import SwiftUI

/// 功能： Presents a lightweight, read-only list of events grouped by day.
struct TimelinePreviewView: View {
    let events: [Event]

    private var grouped: [(day: Date, events: [Event])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: events) { event in
            calendar.startOfDay(for: event.startTime ?? Date())
        }
        return groups.keys.sorted().map { day in
            (day, groups[day] ?? [])
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(grouped, id: \.day) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(dateLabel(group.day))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    ForEach(group.events) { event in
                        HStack {
                            Text(timeLabel(event))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(event.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func timeLabel(_ event: Event) -> String {
        guard let start = event.startTime else { return "All day" }
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        if let end = event.endTime {
            return "\(formatter.string(from: start))–\(formatter.string(from: end))"
        }
        return formatter.string(from: start)
    }
}
