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
    let dayRange: ClosedRange<Int>
    let isActive: Bool
    @State private var previewEvent: Event?

    var body: some View {
        content
            .sheet(item: $previewEvent) { event in
                TimelineEventPlaceholderView(event: event)
            }
            .onChange(of: mode) { newMode in
                if newMode == .edit {
                    previewEvent = nil
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch (mode, range) {
        case (.edit, .day):
            TimelineEditView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                dayRange: dayRange,
                isActive: isActive
            )
        case (.preview, .day):
            TimelineView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                dayRange: dayRange,
                isActive: isActive,
                onPreviewEvent: { previewEvent = $0 }
            )
        case (.edit, .threeDay):
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 3,
                mode: .edit,
                showEventText: true,
                dayRange: dayRange,
                isActive: isActive
            )
        case (.preview, .threeDay):
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 3,
                mode: .preview,
                showEventText: true,
                dayRange: dayRange,
                isActive: isActive,
                onPreviewEvent: { previewEvent = $0 }
            )
        case (.edit, .week):
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 7,
                mode: .edit,
                showEventText: false,
                dayRange: dayRange,
                isActive: isActive
            )
        case (.preview, .week):
            TimelineMultiDayView(
                occurrencesForOffset: occurrencesForOffset,
                selectedDayOffset: $selectedDayOffset,
                daysCount: 7,
                mode: .preview,
                showEventText: false,
                dayRange: dayRange,
                isActive: isActive,
                onPreviewEvent: { previewEvent = $0 }
            )
        }
    }
}
