//
//  TimelineContainerView.swift
//  Done
//
//  Switchboard for timeline rendering. Picks day count based on range mode.
//

import SwiftUI

/// Switches between timeline variants based on mode and range.
struct TimelineContainerView: View {
    typealias Mode = PageMode
    typealias Range = RangeMode

    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let mode: Mode
    let range: Range
    let dayRange: ClosedRange<Int>
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, DragOffset) -> Void)? = nil

    var body: some View {
        TimelineView(
            occurrencesForOffset: occurrencesForOffset,
            selectedDayOffset: $selectedDayOffset,
            daysCount: daysCount,
            mode: mode,
            showEventText: showEventText,
            dayRange: dayRange,
            onEventTap: onEventTap,
            onEventDragEnded: onEventDragEnded
        )
    }

    private var daysCount: Int {
        switch range {
        case .day: return 1
        case .threeDay: return 3
        case .week: return 7
        }
    }

    private var showEventText: Bool {
        switch range {
        case .day, .threeDay: return true
        case .week: return false
        }
    }
}
