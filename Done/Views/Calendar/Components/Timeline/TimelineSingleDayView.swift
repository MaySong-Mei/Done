//
//  TimelineSingleDayView.swift
//  Done
//
//  Single-day paged timeline. Supports preview and edit modes.
//

import SwiftUI

/// Single-day timeline with TabView paging.
struct TimelineSingleDayView: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let mode: PageMode
    let dayRange: ClosedRange<Int>
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, CGFloat) -> Void)? = nil

    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let eventHorizontalInset: CGFloat = 0
    private let headerHeight: CGFloat = 0

    private var showDayLabel: Bool { mode == .edit }
    private var labelBarHeight: CGFloat { showDayLabel ? 18 : 0 }
    private var labelBarSpacing: CGFloat { showDayLabel ? 6 : 0 }

    var body: some View {
        let timelineHeight = headerHeight + (CGFloat(25) * hourHeight)
        let totalHeight = labelBarHeight + timelineHeight

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)
            let labelRowHeight = max(0, labelBarHeight - labelBarSpacing)

            HStack(spacing: 0) {
                timeAxis(labelRowHeight: labelRowHeight, timelineHeight: timelineHeight)
                    .frame(width: labelWidth, alignment: .trailing)

                TabView(selection: $selectedDayOffset) {
                    ForEach(dayRange, id: \.self) { offset in
                        dayPage(
                            offset: offset,
                            contentWidth: contentWidth,
                            labelRowHeight: labelRowHeight,
                            timelineHeight: timelineHeight
                        )
                        .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .frame(height: totalHeight, alignment: .top)
    }

    @ViewBuilder
    private func timeAxis(labelRowHeight: CGFloat, timelineHeight: CGFloat) -> some View {
        if showDayLabel {
            VStack(spacing: labelBarSpacing) {
                Color.clear.frame(height: labelRowHeight)
                TimeAxisView(headerHeight: headerHeight, hourHeight: hourHeight, mode: mode)
                    .frame(height: timelineHeight, alignment: .top)
            }
        } else {
            TimeAxisView(headerHeight: headerHeight, hourHeight: hourHeight, mode: mode)
        }
    }

    @ViewBuilder
    private func dayPage(
        offset: Int,
        contentWidth: CGFloat,
        labelRowHeight: CGFloat,
        timelineHeight: CGFloat
    ) -> some View {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()

        if showDayLabel {
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
                    style: mode == .edit ? .edit : .view,
                    onEventTap: mode == .edit ? onEventTap : nil,
                    onEventDragEnded: mode == .edit ? onEventDragEnded : nil
                )
                .frame(width: contentWidth, height: timelineHeight, alignment: .top)
            }
        } else {
            VStack(spacing: 0) {
                TimelineDayView(
                    date: date,
                    occurrences: occurrencesForOffset(offset),
                    contentWidth: contentWidth,
                    headerHeight: headerHeight,
                    hourHeight: hourHeight,
                    eventHorizontalInset: eventHorizontalInset,
                    showEventText: true,
                    style: mode == .edit ? .edit : .view,
                    onEventTap: mode == .edit ? onEventTap : nil,
                    onEventDragEnded: mode == .edit ? onEventDragEnded : nil
                )
                .frame(width: contentWidth, height: timelineHeight, alignment: .top)
            }
        }
    }

    private func slotLabel(for offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let day = Calendar.current.component(.day, from: date)
        let weekdayIndex = Calendar.current.component(.weekday, from: date) - 1
        let symbols = Calendar.current.shortWeekdaySymbols
        let letter = symbols.indices.contains(weekdayIndex) ? String(symbols[weekdayIndex].prefix(1)) : ""
        return "\(day)\(letter)"
    }
}

/// Static hour labels beside the timeline.
private struct TimeAxisView: View {
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let mode: PageMode

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headerHeight)

            ForEach(0...24, id: \.self) { hour in
                Text(timeLabel(for: hour))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }

    private func timeLabel(for hour: Int) -> String {
        mode == .edit ? String(format: "%02d:00", hour) : "\(hour)"
    }
}
