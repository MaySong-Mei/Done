//
//  EventBlockEdit.swift
//  Done
//
//  Editable event block styling for the timeline.
//

import SwiftUI

/// 功能： Renders an editable event block in the timeline grid.
struct EventBlockEdit: View {
    let event: Event
    let color: Color
    let showText: Bool

    var body: some View {
        content
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

    @ViewBuilder
    private var content: some View {
        if showText {
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
        } else {
            Color.clear
        }
    }

    private func timeRangeLabel(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }
}
