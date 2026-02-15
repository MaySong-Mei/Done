//
//  SplitService.swift
//  Done
//

import Foundation
import Combine

final class SplitService: ObservableObject {
    struct SubTask: Identifiable {
        let id = UUID()
        var title: String
        var portion: Double // 0-1, sum should equal 1
    }

    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published private(set) var currentSubtasks: [SubTask] = []

    private var event: Event?

    // MARK: - Public API

    func startSplit(event: Event) {
        self.event = event
        let prompt = buildInitialPrompt(event: event)
        let userMessage = ChatMessage(role: .user, content: prompt)
        messages.append(userMessage)

        isProcessing = true
        messages.append(ChatMessage(role: .assistant, content: "", isLoading: true))

        Task {
            await callLLM()
        }
    }

    func sendMessage(_ text: String) {
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)

        isProcessing = true
        messages.append(ChatMessage(role: .assistant, content: "", isLoading: true))

        Task {
            await callLLM()
        }
    }

    // MARK: - LLM Call

    private func callLLM() async {
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

        let request = LLMRequest(
            messages: buildLLMMessages(),
            tools: [],
            systemPrompt: buildSystemPrompt()
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

        removeLoadingMessage()
        if let text = response.content, !text.isEmpty {
            appendAssistantMessage(text)
            parseSubtasks(from: text)
        }
        isProcessing = false
    }

    // MARK: - Parsing

    private func parseSubtasks(from text: String) {
        // Look for ```json ... ``` block
        guard let jsonStart = text.range(of: "```json"),
              let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) else {
            return
        }

        let jsonString = String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        var parsed: [SubTask] = []
        for item in array {
            guard let title = item["title"] as? String,
                  let portion = item["portion"] as? Double else { continue }
            parsed.append(SubTask(title: title, portion: portion))
        }

        guard !parsed.isEmpty else { return }

        // Normalize portions to sum to 1
        let total = parsed.reduce(0.0) { $0 + $1.portion }
        if total > 0 && abs(total - 1.0) > 0.001 {
            parsed = parsed.map { SubTask(title: $0.title, portion: $0.portion / total) }
        }

        currentSubtasks = parsed
    }

    // MARK: - Message Building

    private func buildSystemPrompt() -> String {
        let eventTitle = event?.title ?? "Unknown"
        let eventType = event?.type ?? ""
        let eventNote = event?.note ?? ""
        let eventTags = event?.tags.joined(separator: ", ") ?? ""

        var context = "Task: \(eventTitle)"
        if !eventType.isEmpty { context += "\nType: \(eventType)" }
        if !eventNote.isEmpty { context += "\nNote: \(eventNote)" }
        if !eventTags.isEmpty { context += "\nTags: \(eventTags)" }

        return """
        You are a task decomposition assistant for the "Done" productivity app. Your job is to help users break down tasks into smaller, actionable subtasks.

        The user wants to split the following task:
        \(context)

        Rules:
        - Suggest 2-5 subtasks that together cover the original task completely.
        - Each subtask gets a "portion" (0-1) representing its relative effort/size. All portions must sum to 1.0.
        - Every response MUST include a complete JSON subtask list in a ```json code block.
        - The JSON format is: [{"title": "...", "portion": 0.4}, {"title": "...", "portion": 0.6}]
        - Before the JSON block, briefly explain your reasoning in natural language.
        - If the user asks you to adjust, provide the updated full subtask list.
        - Respond in the same language the user uses. If the original task title is in Chinese, respond in Chinese.
        """
    }

    private func buildInitialPrompt(event: Event) -> String {
        "Please break down this task into subtasks: \"\(event.title)\""
    }

    private func buildLLMMessages() -> [LLMMessage] {
        messages.filter { !$0.isLoading }.map { msg in
            switch msg.role {
            case .user:
                return LLMMessage(role: .user, content: msg.content)
            case .assistant:
                return LLMMessage(role: .assistant, content: msg.content)
            default:
                return LLMMessage(role: .user, content: msg.content)
            }
        }
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
    }

    private func removeLoadingMessage() {
        messages.removeAll { $0.isLoading }
    }
}
