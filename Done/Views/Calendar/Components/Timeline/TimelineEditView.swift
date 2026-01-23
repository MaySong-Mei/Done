//
//  TimelineEditView.swift
//  Done
//
//  Editable timeline variant: no date header, solid grid, 04:00 labels.
//

import SwiftUI

struct TimelineEditView: View {
    let events: [Event]
    @Binding var selectedDayOffset: Int

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let eventHorizontalInset: CGFloat = 12
    private let dayRange = -30...30

    private let headerHeight: CGFloat = 0
    private let labelBarHeight: CGFloat = 18

    var body: some View {
        let timelineHeight = headerHeight + (CGFloat(25) * hourHeight)
        let totalHeight = labelBarHeight + timelineHeight

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)

            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: labelWidth, height: 1)
                    Text(slotLabel(for: selectedDayOffset))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: contentWidth, alignment: .center)
                }
                .allowsHitTesting(false)

                HStack(spacing: 0) {
                    TimeAxisView(
                        headerHeight: headerHeight,
                        hourHeight: hourHeight
                    )
                    .frame(width: labelWidth, alignment: .trailing)

                    TabView(selection: $selectedDayOffset) {
                        ForEach(dayRange, id: \.self) { offset in
                            let date = date(for: offset)
                            TimelineDayView(
                                date: date,
                                events: events,
                                contentWidth: contentWidth,
                                headerHeight: headerHeight,
                                hourHeight: hourHeight,
                                eventHorizontalInset: eventHorizontalInset,
                                style: .edit
                            )
                            .frame(width: contentWidth, height: timelineHeight, alignment: .top)
                            .tag(offset)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
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
