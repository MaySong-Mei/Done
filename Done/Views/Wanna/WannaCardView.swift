//
//  WannaCardView.swift
//  Done
//
//  Single card for a wanna item — swipe or tap to complete, push, or delete.
//

import SwiftUI

struct WannaCardView: View {
    let event: Event
    var onComplete: () -> Void
    var onPushToCalendar: () -> Void
    var onDelete: () -> Void

    private var eventColor: Color {
        EventTypeTemplateStore.color(for: event.type)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Completion checkbox
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    onComplete()
                }
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 4, height: 40)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(event.note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !event.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(event.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(eventColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if event.tags.count > 3 {
                            Text("+\(event.tags.count - 3)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if let deadline = event.deadline {
                    deadlineLabel(deadline)
                }
            }

            Spacer(minLength: 0)

            // Push to calendar
            Button {
                onPushToCalendar()
            } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(eventColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func deadlineLabel(_ deadline: Date) -> some View {
        let isOverdue = deadline < Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.day, .hour],
            from: isOverdue ? deadline : Date(),
            to: isOverdue ? Date() : deadline
        )
        let days = components.day ?? 0
        let hours = components.hour ?? 0
        let text = isOverdue
            ? "Overdue \(days)d \(hours)h"
            : "Due in \(days)d \(hours)h"

        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isOverdue ? .red : .orange)
    }
}
