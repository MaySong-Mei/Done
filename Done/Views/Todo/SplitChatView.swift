//
//  SplitChatView.swift
//  Done
//

import SwiftUI

struct SplitChatView: View {
    let event: Event
    let onApply: ([SplitService.SubTask]) -> Void

    @StateObject private var splitService = SplitService()
    @State private var inputText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                eventHeader
                Divider()
                messageList
                if !splitService.currentSubtasks.isEmpty {
                    subtasksPreview
                }
                Divider()
                inputBar
            }
            .navigationTitle(L(.splitTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            splitService.startSplit(event: event)
        }
    }

    // MARK: - Event Header

    private var eventHeader: some View {
        HStack(spacing: 8) {
            if !event.type.isEmpty {
                Text(event.type)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(EventTypeTemplateStore.color(for: event.type).opacity(0.2))
                    .foregroundStyle(EventTypeTemplateStore.color(for: event.type))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Text(event.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleMessages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: splitService.messages.count) {
                if let last = visibleMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var visibleMessages: [ChatMessage] {
        // Hide the initial auto-generated user prompt, show everything else
        let msgs = splitService.messages.filter { $0.role != .toolResult }
        if let first = msgs.first, first.role == .user {
            return Array(msgs.dropFirst())
        }
        return msgs
    }

    // MARK: - Subtasks Preview

    private var subtasksPreview: some View {
        let typeColor = EventTypeTemplateStore.color(for: event.type)

        return VStack(alignment: .leading, spacing: 8) {
            Text(L(.subTasks))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Proportion bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(splitService.currentSubtasks) { subtask in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(typeColor.opacity(0.6))
                            .frame(width: max(8, geo.size.width * subtask.portion - 2))
                    }
                }
            }
            .frame(height: 8)

            // Labels
            ForEach(splitService.currentSubtasks) { subtask in
                HStack(spacing: 6) {
                    Circle()
                        .fill(typeColor.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(subtask.title)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(subtask.portion * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField(L(.adjustSubtasksPlaceholder), text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Color.accentColor : Color(.systemGray4))
                }
                .disabled(!canSend)
            }

            Button {
                onApply(splitService.currentSubtasks)
                dismiss()
            } label: {
                Text(String(format: L(.applySplitFormat), splitService.currentSubtasks.count))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(canApply ? Color.accentColor : Color(.systemGray4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!canApply)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !splitService.isProcessing
    }

    private var canApply: Bool {
        !splitService.currentSubtasks.isEmpty && !splitService.isProcessing
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        splitService.sendMessage(text)
    }
}
