//
//  TimelineHeaderBar.swift
//  Done
//
//  Shared bar that displays the current date/range label and the range picker.
//  Only shown in edit mode so the timeline content can stay height-stable.
//

import SwiftUI

struct TimelineHeaderBar: View {
    let isEditing: Bool
    @Binding var rangeMode: CalendarPageView.RangeMode
    let selectedDayOffset: Int

    private let calendar = Calendar.current

    var body: some View {
        if isEditing {
            HStack {
                Picker("Range", selection: $rangeMode) {
                    Text("Day").tag(CalendarPageView.RangeMode.day)
                    Text("3-Day").tag(CalendarPageView.RangeMode.threeDay)
                    Text("Week").tag(CalendarPageView.RangeMode.week)
                }
                .pickerStyle(.segmented)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
