//
//  WannaCardView.swift
//  Done
//
//  Single card for a wanna item — swipe to compress and reveal actions.
//

import SwiftUI

struct WannaCardView: View {
    let event: Event
    var isScheduled: Bool = false
    var isSelected: Bool = false
    var isBatchMode: Bool = false
    var onComplete: () -> Void
    var onPushToCalendar: () -> Void
    var onRecallFromCalendar: () -> Void
    var onDelete: () -> Void
    var onToggleSelect: (() -> Void)?

    @State private var revealFraction: CGFloat = 0
    @GestureState private var dragDelta: CGFloat = 0

    private let actionWidth: CGFloat = 116
    private let swipeThreshold: CGFloat = 50

    private var eventColor: Color {
        EventTypeTemplateStore.color(for: event.type)
    }

    /// How many points the actions area currently occupies.
    private var revealedWidth: CGFloat {
        let raw = revealFraction * actionWidth + dragDelta
        return min(max(raw, 0), actionWidth)
    }

    private var isRevealed: Bool { revealFraction > 0.5 }

    var body: some View {
        HStack(spacing: 8) {
            // Card compresses to fill remaining space
            cardContent
                .gesture(swipeGesture)

            // Action buttons — revealed by compression
            if revealedWidth > 4 {
                HStack(spacing: 4) {
                    Button {
                        closeAndRun {
                            if isScheduled { onRecallFromCalendar() } else { onPushToCalendar() }
                        }
                    } label: {
                        Image(systemName: isScheduled ? "calendar.badge.minus" : "calendar.badge.plus")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(eventColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        closeAndRun { onDelete() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: revealedWidth)
                .opacity(revealedWidth / actionWidth)
            }
        }
    }

    // MARK: - Helpers

    private func closeAndRun(_ action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            revealFraction = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { action() }
    }

    // MARK: - Card Content

    private var cardContent: some View {
        HStack(spacing: 12) {
            if isBatchMode {
                Button {
                    onToggleSelect?()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        onComplete()
                    }
                } label: {
                    Image(systemName: isScheduled ? "circle.inset.filled" : "circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(isScheduled ? eventColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if isScheduled {
                        Image(systemName: "calendar")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(eventColor.opacity(0.7))
                    }
                }

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.6) :
                    eventColor.opacity(isScheduled ? 0.5 : 0.25),
                    lineWidth: isSelected ? 2 : (isScheduled ? 1.5 : 1)
                )
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    // MARK: - Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($dragDelta) { value, state, _ in
                let h = value.translation.width
                if isRevealed {
                    // Already open: allow right drag to close
                    state = max(h, -20)
                } else {
                    // Closed: only left drag to open (negative = compress)
                    state = min(h, 0)
                }
            }
            .onEnded { value in
                let h = value.translation.width
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if isRevealed {
                        revealFraction = h > 30 ? 0 : 1
                    } else {
                        revealFraction = h < -swipeThreshold ? 1 : 0
                    }
                }
            }
    }

    // MARK: - Deadline

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
