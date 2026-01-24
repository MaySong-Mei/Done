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
    /// 功能： Defines edit or preview timeline behavior.
    enum Mode {
        case preview
        case edit
    }

    /// 功能： Defines the day range the timeline should display.
    enum Range {
        case day
        case threeDay
        case week
    }

    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let mode: Mode
    let range: Range

    var body: some View {
        switch (mode, range) {
        case (.edit, .day):
            TimelineEditView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset
            )
        case (.preview, .day):
            TimelineView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset
            )
        case (.edit, .threeDay):
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 3,
                mode: .edit
            )
        case (.preview, .threeDay):
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 3,
                mode: .preview
            )
        case (.edit, .week):
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 7,
                mode: .edit
            )
        case (.preview, .week):
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 7,
                mode: .preview
            )
        }
    }
}
