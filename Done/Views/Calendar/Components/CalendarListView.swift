//
//  CalendarListView.swift
//  Done
//
//  Agenda-style list view mode for the calendar tab.
//

import SwiftUI

struct CalendarListView: View {
    @EnvironmentObject var store: EventStore
    @State private var dayRange: ClosedRange<Int> = -30...30
    @State private var isExpanding = false
    @State private var scrollAnchor: Date?
    @State private var selectedEventDetailRoute: CalendarEventDetailRoute? = nil

    private let calendar = Calendar.current
    private let dayRangeExpansionStep: Int = 30
    private let dayRangeExpansionThreshold: Int = 14

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(datesWithEvents(), id: \.self) { date in
                    Section {
                        let events = eventsForDate(date)
                        ForEach(events) { event in
                            Button {
                                let occurrenceDate = event.primaryTimeRange?.start ?? date
                                let occurrence = CalendarEventOccurrenceContext(
                                    eventID: event.id,
                                    occurrenceDate: occurrenceDate,
                                    occurrenceID: nil,
                                    isAllDay: event.isAllDay,
                                    source: .timelineTap
                                )
                                selectedEventDetailRoute = CalendarEventDetailRoute(occurrence: occurrence)
                            } label: {
                                CalendarListEventRow(event: event)
                            }
                            .tint(.primary)
                        }
                    } header: {
                        CalendarListDateHeader(date: date, isToday: calendar.isDateInToday(date))
                    }
                    .id(date)
                    .onAppear {
                        checkAndExpandRange(for: date, scrollProxy: proxy)
                    }
                }
            }
            .listStyle(.plain)
            .navigationDestination(item: $selectedEventDetailRoute) { route in
                CalendarEventDetailView(route: route)
                    .environmentObject(store)
            }
            .onAppear {
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
        return (dayRange.lowerBound...dayRange.upperBound).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today)
        }
    }

    private func datesWithEvents() -> [Date] {
        generateDateRange().filter { !eventsForDate($0).isEmpty }
    }

    private func checkAndExpandRange(for date: Date, scrollProxy: ScrollViewProxy) {
        guard !isExpanding else { return }
        let today = calendar.startOfDay(for: Date())
        guard let dayOffset = calendar.dateComponents([.day], from: today, to: date).day else { return }

        var newLower = dayRange.lowerBound
        var newUpper = dayRange.upperBound

        if dayOffset - dayRange.lowerBound < dayRangeExpansionThreshold {
            newLower = dayRange.lowerBound - dayRangeExpansionStep
        }
        if dayRange.upperBound - dayOffset < dayRangeExpansionThreshold {
            newUpper = dayRange.upperBound + dayRangeExpansionStep
        }

        if newLower != dayRange.lowerBound || newUpper != dayRange.upperBound {
            isExpanding = true
            scrollAnchor = date
            dayRange = newLower...newUpper
            DispatchQueue.main.async {
                if let anchor = scrollAnchor {
                    scrollProxy.scrollTo(anchor, anchor: .top)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isExpanding = false
                    scrollAnchor = nil
                }
            }
        }
    }

    private func eventsForDate(_ date: Date) -> [Event] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        return store.calendarEvents
            .filter { event in
                guard !event.timeRanges.isEmpty else { return false }
                return event.timeRanges.contains { $0.start < dayEnd && $0.end > dayStart }
            }
            .sorted { a, b in
                guard let aStart = a.timeRanges.first?.start,
                      let bStart = b.timeRanges.first?.start else { return false }
                return aStart < bStart
            }
    }
}

// MARK: - Date Header

struct CalendarListDateHeader: View {
    let date: Date
    let isToday: Bool

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return formatter
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(dateFormatter.string(from: date))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isToday ? .blue : .primary)

            if isToday {
                Text(L(.today))
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

// MARK: - Event Row

struct CalendarListEventRow: View {
    let event: Event

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return formatter
    }

    private var eventColor: Color {
        EventTypeTemplateStore.color(for: event.type)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let timeRange = event.timeRanges.first {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeFormatter.string(from: timeRange.start))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(timeFormatter.string(from: timeRange.end))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 62, alignment: .trailing)
            }

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(eventColor)
                .frame(width: 4)

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

                if let images = event.agenticIntake?.images, !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(images) { ref in
                                CalendarListImageThumbnail(imageRef: ref)
                            }
                        }
                    }
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

            if event.priority > 0 {
                Text(String(repeating: "!", count: event.priority))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Image Thumbnail

private struct CalendarListImageThumbnail: View {
    let imageRef: AgenticIntakeImageRef
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            if image == nil {
                image = AgenticIntakeAssetStore().loadImage(for: imageRef)
            }
        }
    }
}
