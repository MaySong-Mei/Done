//
//  CalendarSearchView.swift
//  Done
//

import SwiftUI

struct CalendarSearchView: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    var onSelectEvent: (Event, Date) -> Void

    private var filteredEvents: [Event] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        return store.calendarEvents.filter { event in
            event.title.lowercased().contains(lowered)
            || event.note.lowercased().contains(lowered)
            || event.location.lowercased().contains(lowered)
            || event.tags.contains(where: { $0.lowercased().contains(lowered) })
            || event.type.lowercased().contains(lowered)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(
                    "Search Events",
                    systemImage: "magnifyingglass",
                    description: Text("Search by title, note, location, or tag")
                )
                .padding(.top, 60)
            } else if filteredEvents.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 60)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredEvents) { event in
                        Button {
                            let date = event.primaryTimeRange?.start ?? event.createdAt
                            onSelectEvent(event, date)
                        } label: {
                            eventCard(event)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .background(Color.clear)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                searchHeader
                searchField
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .onAppear {
            isSearchFocused = true
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Search")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Title, note, location, tag...", text: $query)
                .font(.system(size: 15))
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private func eventCard(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.title)
                .font(.headline)

            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(CalendarLayout.eventColor(for: event))
                    .frame(width: 10, height: 10)
                Text(event.type.isEmpty ? "Calendar Event" : event.type)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let range = event.primaryTimeRange {
                Label {
                    Text(timeDescription(range: range, event: event))
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.subheadline)

                let minutes = Int(range.end.timeIntervalSince(range.start) / 60)
                let durationLabel = minutes >= 60
                    ? (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(minutes % 60)m")
                    : "\(minutes)m"

                Label {
                    Text(durationLabel)
                } icon: {
                    Image(systemName: "hourglass")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if !event.location.isEmpty {
                Label {
                    Text(event.location)
                } icon: {
                    Image(systemName: "mappin")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func timeDescription(range: Event.TimeRange, event: Event) -> String {
        if event.isAllDay {
            return "\(Self.dateFormatter.string(from: range.start)) • All-day"
        }
        return "\(Self.dateFormatter.string(from: range.start)) • \(Self.timeFormatter.string(from: range.start)) - \(Self.timeFormatter.string(from: range.end))"
    }
}
