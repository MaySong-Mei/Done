//
//  TimelineDayView.swift
//  Done
//
//  Single-day timeline page.
//  Draws the hour grid and overlays event blocks positioned by `CalendarLayout`.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// Hosts the hour grid for a single date and overlays positioned event blocks.
struct TimelineDayView: View {
    let date: Date
    let events: [Event]
    let contentWidth: CGFloat
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let eventHorizontalInset: CGFloat

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            grid

            ForEach(CalendarLayout.occurrencesForDate(events, date: date)) { occurrence in
                CalendarEventBlockView(
                    event: occurrence.event,
                    color: CalendarLayout.eventColor(for: occurrence.event)
                )
                .frame(
                    width: max(0, contentWidth - eventHorizontalInset * 2),
                    height: CalendarLayout.eventHeight(
                        for: occurrence.range,
                        on: date,
                        minimumHeight: 12,
                        hourHeight: hourHeight
                    ),
                    alignment: .top
                )
                .offset(
                    x: eventHorizontalInset,
                    y: CalendarLayout.yOffset(
                        for: occurrence.range,
                        on: date,
                        headerHeight: headerHeight,
                        hourHeight: hourHeight
                    )
                )
            }
        }
    }

    /// Displays the date header plus horizontal separators for each hour slot.
    private var grid: some View {
        VStack(spacing: 0) {
            Text(Self.dateFormatter.string(from: date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: contentWidth, height: headerHeight, alignment: .center)

            ForEach(0...24, id: \.self) { _ in
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: contentWidth, height: 1)
                    .padding(.top, 6)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }
}
