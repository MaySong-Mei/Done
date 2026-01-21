//
//  EventBlockEdit.swift
//  Done
//
//  Editable event block styling for the timeline.
//

import SwiftUI

struct EventBlockEdit: View {
    let event: Event
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            if let start = event.startTime, let end = event.endTime {
                Text(timeRangeLabel(start: start, end: end))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.8), lineWidth: 1.2)
        )
    }

    private func timeRangeLabel(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }
}
