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
    private let timeAxisWidth: CGFloat = 36

    var body: some View {
        if isEditing {
            HStack(alignment: .top, spacing: 0) {
                // Reserve space for the time axis so the date aligns with the grid below.
                Color.clear
                    .frame(width: timeAxisWidth, height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    Text(rangeLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Picker("Range", selection: $rangeMode) {
                        Text("Day").tag(CalendarPageView.RangeMode.day)
                        Text("3-Day").tag(CalendarPageView.RangeMode.threeDay)
                        Text("Week").tag(CalendarPageView.RangeMode.week)
                    }
                    .pickerStyle(.segmented)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var rangeLabel: String {
        switch rangeMode {
        case .day:
            return dayFormatter.string(from: date(for: selectedDayOffset))
        case .threeDay:
            let start = date(for: selectedDayOffset)
            let end = date(for: selectedDayOffset + 2)
            return "\(shortFormatter.string(from: start)) – \(shortFormatter.string(from: end))"
        case .week:
            let start = date(for: selectedDayOffset)
            let end = date(for: selectedDayOffset + 6)
            return "\(shortFormatter.string(from: start)) – \(shortFormatter.string(from: end))"
        }
    }

    private func date(for offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }
}

private let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM:dd:yyyy"
    return formatter
}()

private let shortFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM:dd"
    return formatter
}()
