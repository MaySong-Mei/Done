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

/// 功能： Displays the hourly timeline and lets the user page through days in preview mode.
struct TimelineView: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let dayRange: ClosedRange<Int>
    let isActive: Bool
    var onPreviewEvent: (Event) -> Void = { _ in }

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let eventHorizontalInset: CGFloat = 0
    private let headerHeight: CGFloat = 0
    private let labelBarHeight: CGFloat = 0

    var body: some View {
        let timelineHeight = headerHeight + (CGFloat(25) * hourHeight)
        let totalHeight = labelBarHeight + timelineHeight

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)

            ZStack(alignment: .topLeading) {
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
                                    occurrences: occurrencesForOffset(offset),
                                    contentWidth: contentWidth,
                                    headerHeight: headerHeight,
                                    hourHeight: hourHeight,
                                    eventHorizontalInset: eventHorizontalInset,
                                    showEventText: true,
                                    style: .view
                                )
                                .frame(width: contentWidth, height: timelineHeight, alignment: .top)
                                .tag(offset)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }

                TimelinePreviewGestureLayerDay(
                    occurrences: occurrencesForOffset(selectedDayOffset),
                    size: proxy.size,
                    labelWidth: labelWidth,
                    timelineTopInset: 0,
                    hourHeight: hourHeight,
                    headerHeight: headerHeight,
                    eventHorizontalInset: eventHorizontalInset,
                    dayOffset: selectedDayOffset,
                    isActive: isActive,
                    onPreviewEvent: onPreviewEvent
                )
            }
        }
        .frame(height: totalHeight, alignment: .top)
    }

    /// 功能： Translates an integer day offset into an absolute date relative to today.
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

/// 功能： Shows the static hour labels that sit beside the paged timeline.
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
