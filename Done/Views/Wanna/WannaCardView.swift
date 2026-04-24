//
//  WannaCardView.swift
//  Done
//
//  Single card for a wanna item — swipe to reveal actions, long press for batch.
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

    @State private var swipeOffset: CGFloat = 0
    @State private var settled: Bool = false
    @GestureState private var dragOffset: CGFloat = 0

    private let swipeThreshold: CGFloat = 70
    private let actionRevealWidth: CGFloat = 110

    private var eventColor: Color {
        EventTypeTemplateStore.color(for: event.type)
    }

    private var currentOffset: CGFloat {
        let base = settled ? -actionRevealWidth : 0
        return base + dragOffset
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Action buttons behind the card
            HStack(spacing: 0) {
                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        settled = false
                        swipeOffset = 0
                    }
                    if isScheduled {
                        onRecallFromCalendar()
                    } else {
                        onPushToCalendar()
                    }
                } label: {
                    Image(systemName: isScheduled ? "calendar.badge.minus" : "calendar.badge.plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(eventColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        settled = false
                        swipeOffset = 0
                    }
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .frame(width: actionRevealWidth)
            .opacity(currentOffset < -10 ? 1 : 0)

            // Main card
            cardContent
                .offset(x: min(0, currentOffset))
                .gesture(swipeGesture)
        }
        .clipped()
    }

    // MARK: - Card Content

    private var cardContent: some View {
        HStack(spacing: 12) {
            // Batch select or completion checkbox
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

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 4, height: 40)

            // Content
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
            .updating($dragOffset) { value, state, _ in
                let horizontal = value.translation.width
                // Only allow left swipe
                if horizontal < 0 {
                    state = horizontal
                } else if settled {
                    state = min(horizontal, actionRevealWidth)
                }
            }
            .onEnded { value in
                let horizontal = value.translation.width
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if settled {
                        // If already open, close on right swipe
                        if horizontal > 30 {
                            settled = false
                        }
                    } else {
                        // Open if swiped past threshold
                        if horizontal < -swipeThreshold {
                            settled = true
                        }
                    }
                }
            }
    }

    // MARK: - Helpers

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
