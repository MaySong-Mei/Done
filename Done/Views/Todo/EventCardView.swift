//
//  EventCardView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventCardView: View {
    let event: Event
    let availableHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if event.priority > 0 {
                    Text(String(repeating: "!", count: event.priority))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                }
                Text(event.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
            }
            if let deadline = event.deadline {
                Text(remainingText(until: deadline))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(event.note)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: max(0, availableHeight - 24), alignment: .topLeading)
        .clipped()
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardColor.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(cardColor.opacity(0.4), lineWidth: 1)
        )
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
