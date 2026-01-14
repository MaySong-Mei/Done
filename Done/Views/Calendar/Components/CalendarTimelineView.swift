//
//  CalendarTimelineView.swift
//  Done
//
//  Renders the timeline: a fixed time axis + a paged day view.
//  Owns paging state (`selectedDayOffset`) and composes `TimelineDayView`.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// Displays the hourly timeline and lets the user page through a range of days.
struct CalendarTimelineView: View {
    let events: [Event]

    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let headerHeight: CGFloat = 32
    private let eventHorizontalInset: CGFloat = 10
    private let dayRange = -30...30

    @State private var selectedDayOffset = 0

    var body: some View {
        let contentHeight = headerHeight + (CGFloat(25) * hourHeight)

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)

            HStack(spacing: 0) {
                TimeAxisView(headerHeight: headerHeight, hourHeight: hourHeight)
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
                            eventHorizontalInset: eventHorizontalInset
                        )
                        .frame(width: contentWidth, height: contentHeight, alignment: .top)
                        .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .padding(.leading, 8)
            }
        }
        .frame(height: contentHeight, alignment: .top)
    }

    /// Translates an integer day offset into an absolute date relative to today.
    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
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
                Text(String(format: "%02d:00", hour))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }
}
