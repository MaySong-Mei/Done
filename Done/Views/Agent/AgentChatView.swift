//
//  AgentChatView.swift
//  Done
//

import SwiftUI

struct AgentChatView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var agentRuntime: AgentRuntime
    @StateObject private var agentService = AgentService()
    @State private var inputText = ""
    @State private var isShowingSettings = false
    @State private var isShowingSidebar = false
    @State private var editingTodoEvent: Event?
    @State private var editingCalendarEvent: Event?

    var body: some View {
        ZStack(alignment: .leading) {
            // Main chat
            VStack(spacing: 0) {
                messageList
                inputBar
            }

            // Dimming overlay
            if isShowingSidebar {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isShowingSidebar = false
                        }
                    }
            }

            // Sidebar drawer
            if isShowingSidebar {
                ConversationHistoryView(agentService: agentService) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isShowingSidebar = false
                    }
                }
                .frame(width: 280)
                .shadow(color: .black.opacity(0.15), radius: 10, x: 2, y: 0)
                .transition(.move(edge: .leading))
            }
        }
        .navigationTitle(agentService.currentConversation?.displayTitle ?? "Agent")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isShowingSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    agentService.createNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                AgentSettingsView(showsDoneButton: true)
            }
        }
        .sheet(item: $editingTodoEvent) { event in
            EditEventView(event: event)
                .environmentObject(store)
        }
        .sheet(item: $editingCalendarEvent) { event in
            EditCalendarEventView(event: event)
                .environmentObject(store)
        }
        .onAppear {
            agentService.eventStore = store
            agentService.agentRuntime = agentRuntime
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleMessages) { message in
                        MessageBubbleView(message: message) { eventID in
                            if let event = store.calendarEvents.first(where: { $0.id == eventID }) {
                                editingCalendarEvent = event
                            } else if let event = store.events.first(where: { $0.id == eventID }) {
                                editingTodoEvent = event
                            }
                        }
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: agentService.messages.count) {
                if let last = visibleMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var visibleMessages: [ChatMessage] {
        agentService.messages.filter { $0.role != .toolResult }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message...", text: $inputText, axis: .vertical)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agentService.isProcessing
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        agentService.sendMessage(text)
    }
}
