//
//  TimelineContainerView.swift
//  Done
//
//  Switchboard for timeline rendering. Picks edit/preview variants and
//  (future) day/3-day/week layouts based on config.
//

import SwiftUI

/// 功能： Switches between timeline variants based on mode and range.
struct TimelineContainerView: View {
    /// Type alias for PageMode from CalendarPageTypes.
    typealias Mode = PageMode

    /// Type alias for RangeMode from CalendarPageTypes.
    typealias Range = RangeMode

    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let mode: Mode
    let range: Range
    let dayRange: ClosedRange<Int>

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch range {
        case .day:
            TimelineSingleDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                mode: mode,
                dayRange: dayRange
            )
        case .threeDay:
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 3,
                mode: mode,
                showEventText: true,
                dayRange: dayRange
            )
        case .week:
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 7,
                mode: mode,
                showEventText: false,
                dayRange: dayRange
            )
        }
    }
}
