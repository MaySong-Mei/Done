//
//  TimelineEventContentView.swift
//  Done
//
//  Created by Codex on 3/10/26.
//

import SwiftUI

struct TimelineEventContentView: View {
    let entry: TimeEntry
    let displayStart: Date
    let displayEnd: Date
    let height: CGFloat
    let width: CGFloat
    let showsLabels: Bool
    let type: TimelineEventType
    let cornerRadius: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsLabels {
                Text(entry.templateName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(labelColor)
                    .lineLimit(1)

                if height > 40 {
                    Text(formatTimeRange(start: displayStart, end: displayEnd))
                        .font(.caption2)
                        .foregroundColor(labelColor.opacity(0.8))
                }
            }
        }
        .padding(8)
        .frame(width: max(1, width), height: height, alignment: .topLeading)
        .background(eventBackground)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(hex: entry.colorHex) ?? .blue, lineWidth: type == .ongoing ? 0.8 : 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var eventBackground: some View {
        let base = Color(hex: entry.colorHex) ?? .blue
        switch type {
        case .completed, .empty:
            base
        case .ongoing, .draft:
            ActiveStripeFill(color: base)
        }
    }

    private var labelColor: Color {
        let base = Color(hex: entry.colorHex) ?? .blue
        return (type == .ongoing || type == .draft) ? base : .white
    }

    private func formatTimeRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)
        return "\(startStr) - \(endStr)"
    }
}

private struct ActiveStripeFill: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 8
            let lineWidth: CGFloat = 1
            let stripeColor = color.opacity(0.35)

            context.stroke(
                Path { path in
                    var x: CGFloat = -size.height
                    while x < size.width + size.height {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                        x += spacing
                    }
                },
                with: .color(stripeColor),
                lineWidth: lineWidth
            )
        }
    }
}
