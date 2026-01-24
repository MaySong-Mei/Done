//
//  TimelineEditView.swift
//  Done
//
//  Editable timeline variant: no date header, solid grid, 04:00 labels.
//

import SwiftUI

/// 功能： Displays the hourly timeline in edit mode with solid grid styling.
struct TimelineEditView: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let dayRange: ClosedRange<Int>

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let eventHorizontalInset: CGFloat = 0
    private let headerHeight: CGFloat = 0
    private let labelBarHeight: CGFloat = 18
    private let labelBarSpacing: CGFloat = 6

    var body: some View {
        let timelineHeight = headerHeight + (CGFloat(25) * hourHeight)
        let totalHeight = labelBarHeight + timelineHeight

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)
            let labelRowHeight = max(0, labelBarHeight - labelBarSpacing)

            HStack(spacing: 0) {
                VStack(spacing: labelBarSpacing) {
                    Color.clear
                        .frame(height: labelRowHeight)
                    TimeAxisView(
                        headerHeight: headerHeight,
                        hourHeight: hourHeight
                    )
                    .frame(height: timelineHeight, alignment: .top)
                }
                .frame(width: labelWidth, alignment: .trailing)

                TabView(selection: $selectedDayOffset) {
                    ForEach(dayRange, id: \.self) { offset in
                        let date = date(for: offset)
                        VStack(spacing: labelBarSpacing) {
                            Text(slotLabel(for: offset))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: contentWidth, height: labelRowHeight, alignment: .center)
                                .allowsHitTesting(false)

                            TimelineDayView(
                                date: date,
                                occurrences: occurrencesForOffset(offset),
                                contentWidth: contentWidth,
                                headerHeight: headerHeight,
                                hourHeight: hourHeight,
                                eventHorizontalInset: eventHorizontalInset,
                                showEventText: true,
                                style: .edit
                            )
                            .frame(width: contentWidth, height: timelineHeight, alignment: .top)
                        }
                        .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .frame(height: totalHeight, alignment: .top)
    }

    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }

    private func slotLabel(for offset: Int) -> String {
        let date = date(for: offset)
        let day = calendar.component(.day, from: date)
        let weekdayIndex = calendar.component(.weekday, from: date) - 1
        let symbols = calendar.shortWeekdaySymbols
        let letter = symbols.indices.contains(weekdayIndex) ? symbols[weekdayIndex].prefix(1) : ""
        return "\(day)\(letter)"
    }
}

private struct TimeAxisView: View {
    let headerHeight: CGFloat
    let hourHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: headerHeight)

            ForEach(0...24, id: \.self) { hour in
                Text(timeLabel(for: hour))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }

    private func timeLabel(for hour: Int) -> String {
        String(format: "%02d:00", hour)
    }
}
