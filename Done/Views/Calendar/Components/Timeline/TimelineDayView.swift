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

/// 功能： Defines styling options for timeline grids and event blocks.
struct TimelineStyle {
    /// 功能： Distinguishes view-only versus edit styling.
    enum Variant {
        case view
        case edit
    }

    let variant: Variant
    let gridDashed: Bool
    let gridColor: Color

    static let edit = TimelineStyle(
        variant: .edit,
        gridDashed: false,
        gridColor: Color.secondary.opacity(0.2)
    )

    static let view = TimelineStyle(
        variant: .view,
        gridDashed: true,
        gridColor: Color.secondary.opacity(0.35)
    )
}

/// 功能： Hosts the hour grid for a single date and overlays positioned event blocks.
struct TimelineDayView: View {
    let date: Date
    let occurrences: [CalendarLayout.EventOccurrence]
    let contentWidth: CGFloat
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let eventHorizontalInset: CGFloat
    let showEventText: Bool
    let style: TimelineStyle
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, DragOffset) -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            grid

            ForEach(occurrences) { occurrence in
                eventBlock(for: occurrence)
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
        // Use a stable, unique id so variant changes rebuild while keeping distinct pages/columns.
        .id("\(style.variant)-\(date.timeIntervalSince1970)")
    }

    /// 功能： Displays the date header plus horizontal separators for each hour slot.
    private var grid: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: contentWidth, height: headerHeight, alignment: .center)

            ForEach(0...24, id: \.self) { _ in
                if style.gridDashed {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundColor(style.gridColor)
                        .frame(width: contentWidth, height: 1)
                        .padding(.top, 6)
                        .frame(height: hourHeight, alignment: .top)
                } else {
                    Rectangle()
                        .fill(style.gridColor)
                        .frame(width: contentWidth, height: 1)
                        .padding(.top, 6)
                        .frame(height: hourHeight, alignment: .top)
                }
            }
        }
    }
}

private extension TimelineDayView {
    func eventBlock(for occurrence: CalendarLayout.EventOccurrence) -> some View {
        let event = occurrence.event
        let clippedRange = clippedTimeRange(for: occurrence.range)
        return EventBlock(
            event: event,
            displayRange: clippedRange,
            color: CalendarLayout.eventColor(for: event),
            showText: showEventText,
            style: style.variant == .edit ? .edit : .preview,
            onTap: onEventTap != nil ? { onEventTap?(event) } : nil,
            onDragEnded: onEventDragEnded != nil ? { offset in
                onEventDragEnded?(event, offset)
            } : nil
        )
    }

    func clippedTimeRange(for range: Event.TimeRange) -> Event.TimeRange {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let clippedStart = max(range.start, dayStart)
        let clippedEnd = min(range.end, dayEnd)
        return Event.TimeRange(start: clippedStart, end: clippedEnd)
    }
}
