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
            HStack(spacing: 6) {
                Image(systemName: isCompleted ? "checkmark.square" : "square")
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeOut(duration: 0.3), value: isCompleted)
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
                HStack(spacing: 4) {
                    ForEach(event.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 32)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cardColor.opacity(0.45), lineWidth: 2.5)
                .offset(x: -2, y: 2)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
