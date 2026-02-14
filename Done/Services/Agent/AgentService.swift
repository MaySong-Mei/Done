//
//  AgentService.swift
//  Done
//

import Foundation
import Combine
import SwiftUI

final class AgentService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing: Bool = false

    weak var eventStore: EventStore?

    private let maxToolRounds = 5
    private let messagesStorageKey = "agentChatMessages"

    init() {
        loadMessages()
    }

    // MARK: - Public API

    func sendMessage(_ text: String) {
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        saveMessages()

        isProcessing = true
        // Add loading placeholder
        let loadingMessage = ChatMessage(role: .assistant, content: "", isLoading: true)
        messages.append(loadingMessage)

        Task {
            await processConversation()
        }
    }

    func clearHistory() {
        messages.removeAll()
        saveMessages()
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

            // If there are tool calls, execute them
            if !response.toolCalls.isEmpty {
                removeLoadingMessage()

                // Add assistant message with tool calls indicator
                if let text = response.content, !text.isEmpty {
                    appendAssistantMessage(text)
                }

                // Execute each tool call
                for toolCall in response.toolCalls {
                    // Show tool call in chat
                    let toolCallMsg = ChatMessage(
                        role: .toolCall,
                        content: toolCall.arguments,
                        toolName: toolCall.name,
                        toolCallId: toolCall.id
                    )
                    messages.append(toolCallMsg)

                    // Execute tool
                    let result = AgentToolRunner.execute(
                        toolName: toolCall.name,
                        arguments: toolCall.arguments,
                        store: store
                    )

                    // Store tool result (hidden from UI)
                    let toolResultMsg = ChatMessage(
                        role: .toolResult,
                        content: result,
                        toolName: toolCall.name,
                        toolCallId: toolCall.id
                    )
                    messages.append(toolResultMsg)
                }

                saveMessages()

                // Add loading indicator for next round
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
        saveMessages()
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

        // Group consecutive tool calls and results
        var i = 0
        let filtered = messages.filter { !$0.isLoading }

        while i < filtered.count {
            let msg = filtered[i]

            switch msg.role {
            case .user:
                llmMessages.append(LLMMessage(role: .user, content: msg.content))

            case .assistant:
                // Check if there are tool calls following this assistant message
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
                // Tool calls are handled as part of assistant messages above
                // But if we encounter one not preceded by an assistant, wrap it
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

    private func appendAssistantMessage(_ text: String) {
        messages.append(ChatMessage(role: .assistant, content: text))
        saveMessages()
    }

    private func removeLoadingMessage() {
        messages.removeAll { $0.isLoading }
    }

    // MARK: - Persistence

    private func loadMessages() {
        guard let data = UserDefaults.standard.data(forKey: messagesStorageKey) else { return }
        do {
            messages = try JSONDecoder().decode([ChatMessage].self, from: data)
            // Remove any stale loading messages
            messages.removeAll { $0.isLoading }
        } catch {
            messages = []
        }
    }

    private func saveMessages() {
        // Don't persist loading messages
        let toSave = messages.filter { !$0.isLoading }
        do {
            let data = try JSONEncoder().encode(toSave)
            UserDefaults.standard.set(data, forKey: messagesStorageKey)
        } catch {
            // silently fail
        }
    }
}
