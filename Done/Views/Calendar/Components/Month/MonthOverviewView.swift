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
        VStack(alignment: .leading, spacing: 0) {
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
            .minimumScaleFactor(0.78)

            Spacer(minLength: 12)

            HStack(spacing: 0) {
                ForEach(Array(calendarMonthWeekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { entry in
                    Text(entry.element.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2)
        }
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MonthOverviewPagerView: View {
    let selectedDayOffset: Int
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let allDayOccurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let topContentInset: CGFloat
    let onSelectDay: (Int) -> Void
    let onMonthPageChanged: (Int) -> Void
    var referenceDate: Date = Date()
    var calendar: Calendar = .current

    @State private var visibleMonthOffsets: ClosedRange<Int> = -3...3
    @State private var scrollPositionMonthOffset: Int?
    @State private var isSynchronizingFromSelection: Bool = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleMonthOffsets), id: \.self) { monthOffset in
                        MonthOverviewPageView(
                            monthOffset: monthOffset,
                            selectedDayOffset: selectedDayOffset,
                            occurrencesForOffset: occurrencesForOffset,
                            allDayOccurrencesForOffset: allDayOccurrencesForOffset,
                            topContentInset: topContentInset,
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
    let topContentInset: CGFloat
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

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 7)
    }

    var body: some View {
        GeometryReader { proxy in
            let reservedTopInset = max(0, topContentInset)
            let availableGridHeight = max(0, proxy.size.height - reservedTopInset)
            let cellHeight = max(78, floor((availableGridHeight - gridSpacing * 5) / 6))

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
                        summary: summary,
                        onTap: {
                            onSelectDay(dayOffset)
                        }
                    )
                    .frame(height: cellHeight, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .offset(y: reservedTopInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct MonthDayCellView: View {
    let date: Date
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let summary: MonthOverviewDaySummary
    let onTap: () -> Void

    @AppStorage(AppSettingsKeys.holidaysShowSolarTerms) private var showSolarTerms = true
    @AppStorage(AppSettingsKeys.holidaysShowGregorianHolidays) private var showGregorianHolidays = true

    private var annotations: [CalendarAnnotation] {
        guard showSolarTerms || showGregorianHolidays else { return [] }
        return CalendarAnnotations.annotations(on: date)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text(Self.dayFormatter.string(from: date))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(dayNumberColor)
                    .frame(width: 28, height: 28)
                    .background(dayNumberBackground)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(annotations) { annotation in
                        annotationLabel(annotation)
                    }
                    ForEach(summary.items) { item in
                        monthSummaryPill(item)
                    }
                    if summary.hiddenCount > 0 {
                        Text("+\(summary.hiddenCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(cellBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(cellBorder)
            .opacity(isInDisplayedMonth ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    private var dayNumberColor: Color {
        isInDisplayedMonth ? .primary : .secondary
    }

    @ViewBuilder
    private var dayNumberBackground: some View {
        if isToday {
            Circle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5)
        }
    }

    private var cellBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.02))
    }

    private var cellBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
    }

    /// Lightweight date annotation (solar term / holiday). Styled as plain
    /// colored text — no filled pill — to read as a passive marker rather
    /// than a tappable event.
    func annotationLabel(_ annotation: CalendarAnnotation) -> some View {
        Text(annotation.title)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(annotationColor(annotation).opacity(isInDisplayedMonth ? 0.95 : 0.6))
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func annotationColor(_ annotation: CalendarAnnotation) -> Color {
        switch annotation.kind {
        case .solarTerm: return .green
        case .holiday: return .red
        }
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
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(item.color.opacity(isInDisplayedMonth ? 0.95 : 0.7))
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 14)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(item.color.opacity(isInDisplayedMonth ? 0.22 : 0.12))
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
}
