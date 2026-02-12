//
//  DailyAgendaView.swift
//  Done
//
//  Daily agenda view showing events grouped by date
//

import SwiftUI

struct DailyAgendaView: View {
    @EnvironmentObject var store: EventStore
    @State private var selectedDate = Date()
    @State private var visibleDates: [Date] = []

    private let calendar = Calendar.current
    private let daysToShow = 60 // Show 30 days before and after

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(generateDateRange(), id: \.self) { date in
                    Section {
                        let events = eventsForDate(date)
                        if events.isEmpty {
                            Text("No events")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(events) { event in
                                AgendaEventRow(event: event)
                            }
                        }
                    } header: {
                        DateHeaderView(date: date, isToday: calendar.isDateInToday(date))
                    }
                    .id(date)
                }
            }
            .listStyle(.plain)
            .onAppear {
                // Scroll to today on appear
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation {
                        proxy.scrollTo(calendar.startOfDay(for: Date()), anchor: .top)
                    }
                }
            }
        }
    }

    private func generateDateRange() -> [Date] {
        let today = calendar.startOfDay(for: Date())
        var dates: [Date] = []

        // Generate dates from 30 days ago to 30 days in the future
        for offset in -30...30 {
            if let date = calendar.date(byAdding: .day, value: offset, to: today) {
                dates.append(date)
            }
        }

        return dates
    }

    private func eventsForDate(_ date: Date) -> [Event] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Get calendar events from the calendarEvents list
        let filteredEvents = store.calendarEvents.filter { event in
            guard !event.timeRanges.isEmpty else { return false }

            // Check if any time range intersects this day
            return event.timeRanges.contains { range in
                range.start < dayEnd && range.end > dayStart
            }
        }

        // Sort by start time
        return filteredEvents.sorted { a, b in
            guard let aStart = a.timeRanges.first?.start,
                  let bStart = b.timeRanges.first?.start else {
                return false
            }
            return aStart < bStart
        }
    }
}

struct DateHeaderView: View {
    let date: Date
    let isToday: Bool

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(dateFormatter.string(from: date))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isToday ? .blue : .primary)

            if isToday {
                Text("Today")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct AgendaEventRow: View {
    let event: Event

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private var eventColor: Color {
        EventTypeTemplateStore.color(for: event.type)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Time indicator
            if let timeRange = event.timeRanges.first {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeFormatter.string(from: timeRange.start))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(timeFormatter.string(from: timeRange.end))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 50, alignment: .trailing)
            }

            // Color indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 4)

            // Event details
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)

                if !event.note.isEmpty {
                    Text(event.note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !event.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(event.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            Spacer()

            // Priority indicator
            if event.priority > 0 {
                Text(String(repeating: "!", count: event.priority))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
    }
}
