//
//  EventCardView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventCardView: View {
    let event: Event
    var isCompleted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleText
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeOut(duration: 0.3), value: isCompleted)
            if let deadline = event.deadline {
                Text(remainingText(until: deadline))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
            }
            if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(event.note)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            if !event.tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(event.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(cardColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 32)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.systemBackground))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(cardColor.opacity(0.2))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(cardColor.opacity(0.7), lineWidth: 1.2)
        )
    }

    private var titleText: Text {
        let checkbox = Text(Image(systemName: isCompleted ? "checkmark.square" : "square"))
            .font(.system(size: 15))
            .foregroundColor(.primary)
        let title = Text(event.title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.primary)
        if event.priority > 0 {
            let priority = Text(String(repeating: "!", count: event.priority))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.red)
            return checkbox + Text(" ") + priority + Text(" ") + title
        }
        return checkbox + Text(" ") + title
    }

    private var cardColor: Color { EventTypeTemplateStore.color(for: event.type) }

    private func remainingText(until deadline: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let isOverdue = deadline < now
        let components = calendar.dateComponents(
            [.day, .hour, .minute],
            from: isOverdue ? deadline : now,
            to: isOverdue ? now : deadline
        )
        let days = components.day ?? 0
        let hours = components.hour ?? 0
        let minutes = components.minute ?? 0
        let prefix = isOverdue ? "Overdue" : "Remaining"
        let parts = [
            days > 0 ? "\(days)d" : nil,
            hours > 0 ? "\(hours)h" : nil,
            minutes > 0 ? "\(minutes)m" : nil
        ].compactMap { $0 }
        if parts.isEmpty {
            return "\(prefix) 0m"
        }
        return "\(prefix) \(parts.joined(separator: " "))"
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let w = min(ideal.width, maxWidth)
            if x + w > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += w + spacing
            rowHeight = max(rowHeight, ideal.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let w = min(ideal.width, maxWidth)
            let h = ideal.height
            if x + w > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(width: w, height: h))
            x += w + spacing
            rowHeight = max(rowHeight, h)
        }
    }
}
