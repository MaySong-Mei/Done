//
//  ConversationHistoryView.swift
//  Done
//

import SwiftUI

struct ConversationHistoryView: View {
    @ObservedObject var agentService: AgentService
    var onSelect: () -> Void

    private var sortedConversations: [AgentConversation] {
        agentService.conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationList
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var header: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Button {
                agentService.createNewConversation()
                onSelect()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(sortedConversations) { conversation in
                    ConversationRowView(
                        conversation: conversation,
                        isSelected: conversation.id == agentService.currentConversationID
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        agentService.switchToConversation(conversation.id)
                        onSelect()
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            agentService.deleteConversation(conversation.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            agentService.deleteConversation(conversation.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
