//
//  MessageBubbleView.swift
//  Done
//

import SwiftUI

struct MessageBubbleView: View {
    @EnvironmentObject var store: EventStore
    let message: ChatMessage
    var onEventTap: ((UUID) -> Void)?

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            if message.isLoading {
                typingIndicator
            } else {
                assistantBubble
            }
        case .toolCall:
            toolCallIndicator
        case .toolResult:
            EmptyView()
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(message.content)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var assistantBubble: some View {
        HStack {
            RichTextView(content: message.content)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 60)
        }
    }

    private var toolCallIndicator: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(toolDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let eventIDs = message.referencedEventIDs, !eventIDs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(eventIDs, id: \.self) { eventID in
                            Button {
                                onEventTap?(eventID)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "link")
                                        .font(.system(size: 9))
                                    Text(eventName(for: eventID))
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer()
        }
    }

    private var typingIndicator: some View {
        HStack {
            TypingDotsView()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 60)
        }
    }

    private func eventName(for id: UUID) -> String {
        if let event = store.events.first(where: { $0.id == id }) {
            return event.title
        }
        if let event = store.rawCalendarEvents.first(where: { $0.id == id }) {
            return event.title
        }
        return "Event"
    }

    private var toolDisplayName: String {
        guard let name = message.toolName else { return "Tool" }
        switch name {
        case "createTodo": return "Creating todo..."
        case "createCalendarEvent": return "Creating event..."
        case "listTodos": return "Listing todos..."
        case "listCalendarEvents": return "Listing events..."
        case "updateTodo": return "Updating todo..."
        case "completeTodo": return "Completing todo..."
        case "deleteTodo": return "Requesting todo deletion..."
        case "deleteCalendarEvent": return "Requesting event deletion..."
        case "getScheduleForDate": return "Checking schedule..."
        case "getUserData": return "Fetching user data..."
        default: return name
        }
    }
}

// MARK: - Pending Destructive Action (gh#135)

/// The Confirm/Cancel card for a staged agent deletion. Observes the
/// registry itself (its owner `AgentService` does not republish nested
/// changes) and renders nothing while no action is pending. Both chat
/// surfaces (`AgentChatView`, `CalendarEventChatView`) append this section
/// after their message list.
///
/// The tap callbacks carry the nonce of the action THIS card rendered —
/// never a re-read of the registry at tap time — so a tap consented to one
/// card can only ever act on that card's staging. An expired action renders
/// a disarmed state (evaluated at render; no timer — every tap outcome is
/// registry-guarded regardless).
struct PendingDestructiveActionSection: View {
    @ObservedObject var registry: AgentPendingActionRegistry
    var onConfirm: (UUID) -> Void
    var onCancel: (UUID) -> Void

    var body: some View {
        if let action = registry.pending {
            card(for: action, expired: action.isExpired(at: Date()))
        }
    }

    private func card(for action: AgentPendingDestructiveAction, expired: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                    Text(kindLabel(for: action.kind))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(expired ? Color.secondary : Color.red)

                Text(action.displayTitle.isEmpty ? "Untitled" : action.displayTitle)
                    .font(.system(size: 14, weight: .medium))

                if let time = action.displayTime {
                    Text(time)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if let note = action.recurrenceScopeNote {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(expired ? Color.secondary : Color.orange)
                }

                if expired {
                    Text("Expired — request the deletion again.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button(action: { onCancel(action.nonce) }) {
                        Text("Dismiss")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                } else {
                    HStack(spacing: 10) {
                        Button(role: .destructive, action: { onConfirm(action.nonce) }) {
                            Text("Confirm delete")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button(action: { onCancel(action.nonce) }) {
                            Text("Cancel")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 40)
        }
    }

    private func kindLabel(for kind: AgentPendingDestructiveAction.Kind) -> String {
        switch kind {
        case .deleteTodo: return "Delete this todo?"
        case .deleteCalendarEvent: return "Delete this event?"
        }
    }
}

// MARK: - Typing Dots Animation

private struct TypingDotsView: View {
    @State private var phase: Int = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .offset(y: phase == index ? -4 : 0)
            }
        }
        .onAppear {
            timer?.invalidate()
            // Stagger the three dots by cycling `phase` on a repeating timer.
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.4)) {
                    phase = (phase + 1) % 3
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}
