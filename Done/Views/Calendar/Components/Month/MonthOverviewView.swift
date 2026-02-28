//
//  MonthOverviewView.swift
//  Done
//
//  Month overview pager and grid for the highest-level calendar zoom mode.
//

import SwiftUI

struct MonthOverviewEventSummary: Identifiable {
    let id: String
    let title: String
    let color: Color
    let isAllDay: Bool
}

struct MonthOverviewDaySummary {
    let items: [MonthOverviewEventSummary]
    let hiddenCount: Int

    static let empty = MonthOverviewDaySummary(items: [], hiddenCount: 0)
}

func calendarMonthDaySummary(
    occurrences: [CalendarLayout.EventOccurrence],
    allDayOccurrences: [CalendarLayout.EventOccurrence],
    maxVisibleCount: Int = 3
) -> MonthOverviewDaySummary {
    struct SummaryDescriptor {
        let id: String
        let title: String
        let start: Date
        let color: Color
        let isAllDay: Bool
    }

    let allDescriptors = allDayOccurrences.map { occurrence in
        SummaryDescriptor(
            id: occurrence.id,
            title: occurrence.event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Event" : occurrence.event.title,
            start: occurrence.range.start,
            color: CalendarLayout.eventColor(for: occurrence.event),
            isAllDay: true
        )
    } + occurrences.map { occurrence in
        SummaryDescriptor(
            id: occurrence.id,
            title: occurrence.event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Event" : occurrence.event.title,
            start: occurrence.range.start,
            color: CalendarLayout.eventColor(for: occurrence.event),
            isAllDay: false
        )
    }

    let sorted = allDescriptors.sorted { lhs, rhs in
        if lhs.isAllDay != rhs.isAllDay {
            return lhs.isAllDay && !rhs.isAllDay
        }
        let startDelta = lhs.start.timeIntervalSince(rhs.start)
        if abs(startDelta) > 0.5 {
            return startDelta < 0
        }
        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    let visibleCount = max(0, maxVisibleCount)
    let items = sorted.prefix(visibleCount).map { descriptor in
        MonthOverviewEventSummary(
            id: descriptor.id,
            title: descriptor.title,
            color: descriptor.color,
            isAllDay: descriptor.isAllDay
        )
    }

    return MonthOverviewDaySummary(
        items: items,
        hiddenCount: max(0, sorted.count - items.count)
    )
}

struct CalendarMonthLegendBar: View {
    let selectedDayOffset: Int
    var referenceDate: Date = Date()
    var calendar: Calendar = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                calendarMonthOverlayTitle(
                    selectedDayOffset: selectedDayOffset,
                    referenceDate: referenceDate,
                    calendar: calendar
                )
            )
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)

            HStack(spacing: 0) {
                ForEach(Array(calendarMonthWeekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { entry in
                    Text(entry.element.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

struct MonthOverviewPagerView: View {
    let selectedDayOffset: Int
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let allDayOccurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let onSelectDay: (Int) -> Void
    let onMonthPageChanged: (Int) -> Void
    var referenceDate: Date = Date()
    var calendar: Calendar = .current

    @State private var visibleMonthOffsets: ClosedRange<Int> = -3...3
    @State private var scrollPositionMonthOffset: Int?
    @State private var isSynchronizingFromSelection: Bool = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(visibleMonthOffsets), id: \.self) { monthOffset in
                        MonthOverviewPageView(
                            monthOffset: monthOffset,
                            selectedDayOffset: selectedDayOffset,
                            occurrencesForOffset: occurrencesForOffset,
                            allDayOccurrencesForOffset: allDayOccurrencesForOffset,
                            onSelectDay: onSelectDay,
                            referenceDate: referenceDate,
                            calendar: calendar
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(monthOffset)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollPositionMonthOffset)
            .onAppear {
                synchronizeToSelection()
            }
            .onChange(of: selectedDayOffset) { _, _ in
                synchronizeToSelection()
            }
            .onChange(of: scrollPositionMonthOffset) { _, newValue in
                guard let newValue else { return }
                expandVisibleMonthOffsetsIfNeeded(around: newValue)
                if isSynchronizingFromSelection {
                    isSynchronizingFromSelection = false
                    return
                }
                let currentMonthOffset = calendarMonthOffset(
                    selectedDayOffset: selectedDayOffset,
                    referenceDate: referenceDate,
                    calendar: calendar
                )
                guard newValue != currentMonthOffset else { return }
                onMonthPageChanged(newValue - currentMonthOffset)
            }
        }
    }

    private func synchronizeToSelection() {
        let monthOffset = calendarMonthOffset(
            selectedDayOffset: selectedDayOffset,
            referenceDate: referenceDate,
            calendar: calendar
        )
        expandVisibleMonthOffsetsIfNeeded(around: monthOffset)
        guard scrollPositionMonthOffset != monthOffset else { return }
        isSynchronizingFromSelection = true
        scrollPositionMonthOffset = monthOffset
    }

    private func expandVisibleMonthOffsetsIfNeeded(around monthOffset: Int) {
        var lower = visibleMonthOffsets.lowerBound
        var upper = visibleMonthOffsets.upperBound

        if monthOffset <= lower + 1 {
            lower -= 3
        }
        if monthOffset >= upper - 1 {
            upper += 3
        }

        guard lower != visibleMonthOffsets.lowerBound || upper != visibleMonthOffsets.upperBound else { return }
        visibleMonthOffsets = lower...upper
    }
}

struct MonthOverviewPageView: View {
    let monthOffset: Int
    let selectedDayOffset: Int
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let allDayOccurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let onSelectDay: (Int) -> Void
    var referenceDate: Date = Date()
    var calendar: Calendar = .current

    private let gridSpacing: CGFloat = 6

    private var monthStart: Date {
        let baseMonthStart = calendarMonthStartDate(
            containing: calendar.startOfDay(for: referenceDate),
            calendar: calendar
        )
        return calendar.date(byAdding: .month, value: monthOffset, to: baseMonthStart) ?? baseMonthStart
    }

    private var monthDates: [Date] {
        calendarMonthGridDates(forMonthContaining: monthStart, calendar: calendar)
    }

    private var selectedDate: Date {
        calendarDateForSelectedDayOffset(
            selectedDayOffset,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 7)
    }

    var body: some View {
        GeometryReader { proxy in
            let cellHeight = max(78, floor((proxy.size.height - gridSpacing * 5) / 6))

            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(monthDates, id: \.self) { date in
                    let dayStart = calendar.startOfDay(for: date)
                    let today = calendar.startOfDay(for: referenceDate)
                    let dayOffset = calendar.dateComponents([.day], from: today, to: dayStart).day ?? 0
                    let summary = calendarMonthDaySummary(
                        occurrences: occurrencesForOffset(dayOffset),
                        allDayOccurrences: allDayOccurrencesForOffset(dayOffset)
                    )

                    MonthDayCellView(
                        date: dayStart,
                        isInDisplayedMonth: calendar.isDate(dayStart, equalTo: monthStart, toGranularity: .month),
                        isToday: calendar.isDate(dayStart, inSameDayAs: today),
                        isSelected: calendar.isDate(dayStart, inSameDayAs: selectedDate),
                        summary: summary,
                        onTap: {
                            onSelectDay(dayOffset)
                        }
                    )
                    .frame(height: cellHeight, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct MonthDayCellView: View {
    let date: Date
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let summary: MonthOverviewDaySummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Self.dayFormatter.string(from: date))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(dayNumberColor)
                        .frame(width: 28, height: 28)
                        .background(dayNumberBackground)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.items) { item in
                        monthSummaryPill(item)
                    }
                    if summary.hiddenCount > 0 {
                        Text("+\(summary.hiddenCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cellBackground)
            .overlay(cellBorder)
            .opacity(isInDisplayedMonth ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    private var dayNumberColor: Color {
        if isSelected {
            return .primary
        }
        return isInDisplayedMonth ? .primary : .secondary
    }

    @ViewBuilder
    private var dayNumberBackground: some View {
        if isSelected {
            Circle()
                .fill(Color.accentColor.opacity(0.28))
        } else if isToday {
            Circle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5)
        }
    }

    private var cellBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.08) : Color.white.opacity(0.02))
    }

    private var cellBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isSelected ? Color.accentColor.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 1)
    }

    func monthSummaryPill(_ item: MonthOverviewEventSummary) -> some View {
        HStack(spacing: 4) {
            if item.isAllDay {
                Image(systemName: "calendar")
                    .font(.system(size: 8, weight: .bold))
            }

            Text(item.title)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(item.color.opacity(isInDisplayedMonth ? 0.95 : 0.7))
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(item.color.opacity(isInDisplayedMonth ? 0.22 : 0.12))
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
}
