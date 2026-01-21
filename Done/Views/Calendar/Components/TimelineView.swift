//
//  TimelineView.swift
//  Done
//
//  Renders the timeline: a fixed time axis + a paged day view.
//  Owns paging state (`selectedDayOffset`) and composes `TimelineDayView`.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// Displays the hourly timeline and lets the user page through a range of days (view mode).
struct TimelineView: View {
    let events: [Event]
    @Binding var selectedDayOffset: Int

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let eventHorizontalInset: CGFloat = 12
    private let dayRange = -30...30

    private let headerHeight: CGFloat = 0
    private let labelBarHeight: CGFloat = 0

    var body: some View {
        let timelineHeight = headerHeight + (CGFloat(25) * hourHeight)
        let totalHeight = labelBarHeight + timelineHeight

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)

            VStack(spacing: 6) {
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
                                style: .view
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

    /// Translates an integer day offset into an absolute date relative to today.
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

/// Shows the static hour labels that sit beside the paged timeline.
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
        "\(hour)"
    }
}
