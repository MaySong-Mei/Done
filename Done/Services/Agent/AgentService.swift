//
//  AgentService.swift
//  Done
//

import Foundation
import Combine
import SwiftUI

final class AgentService: ObservableObject {
    @Published var conversations: [AgentConversation] = []
    @Published var currentConversationID: UUID?
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing: Bool = false

    weak var eventStore: EventStore?

    private let maxToolRounds = 5
    private let conversationsStorageKey = "agentConversations"
    private let legacyMessagesKey = "agentChatMessages"

    init() {
        loadConversations()
    }

    // MARK: - Computed

    var currentConversation: AgentConversation? {
        conversations.first { $0.id == currentConversationID }
    }

    // MARK: - Public API

    func sendMessage(_ text: String) {
        ensureCurrentConversation()

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        syncMessagesToConversation()

        isProcessing = true
        let loadingMessage = ChatMessage(role: .assistant, content: "", isLoading: true)
        messages.append(loadingMessage)

        Task {
            await processConversation()
        }
    }

    func createNewConversation() {
        let conversation = AgentConversation()
        conversations.insert(conversation, at: 0)
        currentConversationID = conversation.id
        messages = []
        saveConversations()
    }

    func switchToConversation(_ id: UUID) {
        guard let conv = conversations.first(where: { $0.id == id }) else { return }
        currentConversationID = conv.id
        messages = conv.messages
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentConversationID == id {
            if let first = conversations.first {
                switchToConversation(first.id)
            } else {
                createNewConversation()
            }
        }
        saveConversations()
    }

    func clearHistory() {
        guard let idx = conversations.firstIndex(where: { $0.id == currentConversationID }) else { return }
        conversations[idx].messages.removeAll()
        conversations[idx].involvedEventIDs.removeAll()
        conversations[idx].involvedEventNames.removeAll()
        conversations[idx].updatedAt = Date()
        messages = []
        saveConversations()
    }

    // MARK: - Conversation Loop

    private func processConversation() async {
        guard let store = eventStore else {
            removeLoadingMessage()
            appendAssistantMessage("Error: EventStore not available.")
            isProcessing = false
            return
        }

        let provider: (any LLMProvider)?
        do {
            provider = try buildProvider()
        } catch {
            removeLoadingMessage()
            appendAssistantMessage("Error: \(error.localizedDescription)")
            isProcessing = false
            return
        }

        guard let provider else {
            removeLoadingMessage()
            appendAssistantMessage("Error: Could not create LLM provider.")
            isProcessing = false
            return
        }

        var roundsRemaining = maxToolRounds
        let isFirstAssistantResponse = !messages.contains { $0.role == .assistant && !$0.isLoading }

        while roundsRemaining > 0 {
            let request = LLMRequest(
                messages: buildLLMMessages(),
                tools: AgentTool.allDefinitions,
                systemPrompt: buildSystemPrompt(store: store)
            )

            let response: LLMResponse
            do {
                response = try await provider.send(request)
            } catch {
                removeLoadingMessage()
                appendAssistantMessage("Error: \(error.localizedDescription)")
                isProcessing = false
                return
            }

            if !response.toolCalls.isEmpty {
                removeLoadingMessage()

                if let text = response.content, !text.isEmpty {
                    appendAssistantMessage(text)
                }

                for toolCall in response.toolCalls {
                    var toolCallMsg = ChatMessage(
                        role: .toolCall,
                        content: toolCall.arguments,
                        toolName: toolCall.name,
                        toolCallId: toolCall.id
                    )

                    let result = AgentToolRunner.execute(
                        toolName: toolCall.name,
                        arguments: toolCall.arguments,
                        store: store
                    )

                    // Extract event IDs from tool calls
                    let eventIDs = extractEventIDs(
                        toolName: toolCall.name,
                        arguments: toolCall.arguments,
                        result: result
                    )
                    if !eventIDs.isEmpty {
                        toolCallMsg.referencedEventIDs = eventIDs
                        trackEventIDs(eventIDs, store: store)
                    }

                    messages.append(toolCallMsg)

                    let toolResultMsg = ChatMessage(
                        role: .toolResult,
                        content: result,
                        toolName: toolCall.name,
                        toolCallId: toolCall.id
                    )
                    messages.append(toolResultMsg)
                }

                syncMessagesToConversation()

                let loadingMessage = ChatMessage(role: .assistant, content: "", isLoading: true)
                messages.append(loadingMessage)

                roundsRemaining -= 1
                continue
            }

            // No tool calls - final response
            removeLoadingMessage()
            if let text = response.content, !text.isEmpty {
                appendAssistantMessage(text)
            }
            break
        }

        isProcessing = false
        syncMessagesToConversation()

        // Generate title after first assistant response
        if isFirstAssistantResponse {
            await generateTitle()
        }
    }

    // MARK: - Event ID Extraction

    private func extractEventIDs(toolName: String, arguments: String, result: String) -> [UUID] {
        var ids: [UUID] = []

        switch toolName {
        case "createTodo", "createCalendarEvent":
            // Parse id from result JSON
            if let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let idStr = json["id"] as? String,
               let uuid = UUID(uuidString: idStr) {
                ids.append(uuid)
            }
        case "updateTodo", "completeTodo", "deleteTodo", "deleteCalendarEvent":
            // Parse id from arguments JSON
            if let data = arguments.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let idStr = json["id"] as? String,
               let uuid = UUID(uuidString: idStr) {
                ids.append(uuid)
            }
        default:
            break
        }

        return ids
    }

    private func trackEventIDs(_ ids: [UUID], store: EventStore) {
        guard let idx = conversations.firstIndex(where: { $0.id == currentConversationID }) else { return }

        for id in ids {
            conversations[idx].involvedEventIDs.insert(id)

            // Look up event name
            if let event = store.events.first(where: { $0.id == id }) {
                conversations[idx].involvedEventNames[id] = event.title
            } else if let event = store.calendarEvents.first(where: { $0.id == id }) {
                conversations[idx].involvedEventNames[id] = event.title
            }
        }
    }

    // MARK: - Title Generation

    private func generateTitle() async {
        guard let idx = conversations.firstIndex(where: { $0.id == currentConversationID }),
              conversations[idx].title == nil else { return }

        let userMessages = messages
            .filter { $0.role == .user || ($0.role == .assistant && !$0.isLoading) }
            .prefix(4)
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content.prefix(200))" }
            .joined(separator: "\n")

        guard !userMessages.isEmpty else { return }

        do {
            let provider = try buildProvider()
            let request = LLMRequest(
                messages: [
                    LLMMessage(role: .user, content: "Summarize this conversation in 3-6 words as a title. Reply with ONLY the title, no quotes or punctuation:\n\n\(userMessages)")
                ],
                tools: [],
                systemPrompt: "You generate short conversation titles. Respond with only the title text, nothing else."
            )
            let response = try await provider.send(request)
            if let title = response.content?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                if let currentIdx = conversations.firstIndex(where: { $0.id == currentConversationID }) {
                    conversations[currentIdx].title = title
                    saveConversations()
                }
            }
        } catch {
            // Silently fail - title generation is non-critical
        }
    }

    // MARK: - Message Building

    private func buildSystemPrompt(store: EventStore) -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        let activeTodoCount = store.activeEvents.count
        let completedTodoCount = store.completedCount
        let calendarEventCount = store.calendarEvents.count

        return """
        You are a helpful AI assistant and personal productivity coach for the "Done" productivity app. You help users manage their todos and calendar events, and provide behavioral insights.

        Current time: \(formatter.string(from: now))

        Current stats:
        - Active todos: \(activeTodoCount)
        - Completed todos: \(completedTodoCount)
        - Calendar events: \(calendarEventCount)

        Guidelines:
        - Use the provided tools to create, read, update, and delete todos and calendar events.
        - When the user wants to create an event with a specific time, use createCalendarEvent.
        - When the user wants to create a task without a specific time, use createTodo.
        - Always confirm what you've done after performing an action.
        - Be concise and helpful.
        - For dates, use ISO8601 format (yyyy-MM-dd'T'HH:mm:ss) when calling tools.
        - If the user mentions a relative time (like "tomorrow 3pm"), calculate the actual date/time based on the current time.
        - Respond in the same language the user uses.

        Behavioral analysis:
        - When the user asks about their habits, patterns, productivity, personality, or wants advice on scheduling, use the getUserData tool to fetch their raw data.
        - Analyze the data yourself to provide personalized insights: chronotype, peak hours, work-life balance, consistency, energy patterns, etc.
        - Be warm, insightful, and specific. Back up observations with actual data.
        - Don't just list numbers — interpret them into meaningful insights and actionable suggestions.
        """
    }

    private func buildLLMMessages() -> [LLMMessage] {
        var llmMessages: [LLMMessage] = []

        var i = 0
        let filtered = messages.filter { !$0.isLoading }

        while i < filtered.count {
            let msg = filtered[i]

            switch msg.role {
            case .user:
                llmMessages.append(LLMMessage(role: .user, content: msg.content))

            case .assistant:
                var toolCalls: [LLMToolCall] = []
                var j = i + 1
                while j < filtered.count && filtered[j].role == .toolCall {
                    let tc = filtered[j]
                    toolCalls.append(LLMToolCall(
                        id: tc.toolCallId ?? UUID().uuidString,
                        name: tc.toolName ?? "",
                        arguments: tc.content
                    ))
                    j += 1
                }

                if !toolCalls.isEmpty {
                    llmMessages.append(LLMMessage(
                        role: .assistant,
                        content: msg.content,
                        toolCalls: toolCalls
                    ))
                } else {
                    llmMessages.append(LLMMessage(role: .assistant, content: msg.content))
                }

            case .toolCall:
                if llmMessages.last?.role != .assistant || llmMessages.last?.toolCalls == nil {
                    llmMessages.append(LLMMessage(
                        role: .assistant,
                        content: "",
                        toolCalls: [LLMToolCall(
                            id: msg.toolCallId ?? UUID().uuidString,
                            name: msg.toolName ?? "",
                            arguments: msg.content
                        )]
                    ))
                }

            case .toolResult:
                llmMessages.append(LLMMessage(
                    role: .tool,
                    content: msg.content,
                    toolCallId: msg.toolCallId
                ))
            }

            i += 1
        }

        return llmMessages
    }

    // MARK: - Provider

    private func buildProvider() throws -> any LLMProvider {
        let providerType = UserDefaults.standard.string(forKey: "agentProvider") ?? "claude"
        let apiKey = UserDefaults.standard.string(forKey: "agentAPIKey") ?? ""

        guard !apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        switch providerType {
        case "openai":
            return OpenAIProvider(apiKey: apiKey)
        case "deepseek":
            return DeepSeekProvider(apiKey: apiKey)
        default:
            return ClaudeProvider(apiKey: apiKey)
        }
    }

    // MARK: - Helpers

    private func ensureCurrentConversation() {
        if currentConversationID == nil || conversations.isEmpty {
            createNewConversation()
        }
    }

    private func appendAssistantMessage(_ text: String) {
        messages.append(ChatMessage(role: .assistant, content: text))
        syncMessagesToConversation()
    }

    private func removeLoadingMessage() {
        messages.removeAll { $0.isLoading }
    }

    private func syncMessagesToConversation() {
        guard let idx = conversations.firstIndex(where: { $0.id == currentConversationID }) else { return }
        conversations[idx].messages = messages.filter { !$0.isLoading }
        conversations[idx].updatedAt = Date()
        saveConversations()
    }

    // MARK: - Persistence

    private func loadConversations() {
        // Try new format first
        if let data = UserDefaults.standard.data(forKey: conversationsStorageKey) {
            do {
                conversations = try JSONDecoder().decode([AgentConversation].self, from: data)
                // Remove stale loading messages from all conversations
                for i in conversations.indices {
                    conversations[i].messages.removeAll { $0.isLoading }
                }
                if let first = conversations.first {
                    currentConversationID = first.id
                    messages = first.messages
                }
                return
            } catch {
                // Fall through to migration
            }
        }

        // Migrate from legacy format
        if let data = UserDefaults.standard.data(forKey: legacyMessagesKey) {
            do {
                var oldMessages = try JSONDecoder().decode([ChatMessage].self, from: data)
                oldMessages.removeAll { $0.isLoading }
                if !oldMessages.isEmpty {
                    let conversation = AgentConversation(messages: oldMessages)
                    conversations = [conversation]
                    currentConversationID = conversation.id
                    messages = oldMessages
                    saveConversations()
                    UserDefaults.standard.removeObject(forKey: legacyMessagesKey)
                    return
                }
            } catch {
                // Ignore
            }
        }

        // Empty state
        conversations = []
    }

    private func saveConversations() {
        do {
            let data = try JSONEncoder().encode(conversations)
            UserDefaults.standard.set(data, forKey: conversationsStorageKey)
        } catch {
            // silently fail
        }
    }
}
